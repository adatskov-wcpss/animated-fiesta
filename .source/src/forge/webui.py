"""
Selkies Forge engine - webui

The web UI's own lifecycle: how it last stopped, start-on-boot, status.
"""

import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .host import docker_ok
from .paths import (
    APPDIR,
    BOOT_JSON,
    LABEL,
    LAST_STOP_JSON,
    LIFE_JSON,
    LOGDIR,
    ROOT,
    SERVER_JSON,
    STOP_REQUEST_JSON,
    VERSION,
)
from .registry import docker_instances
from .updates import installed_payload
from .util import have, jload, jsave, pid_alive, run


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def boot_time():
    try:
        with open("/proc/stat") as fh:
            for line in fh:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def host_going_down():
    """'reboot', 'shutdown' or None, asked while we are being stopped."""
    try:
        rc, out, _ = run(["systemctl", "list-jobs", "--no-legend", "--no-pager"], timeout=4)
        jobs = out if rc == 0 else ""
        if re.search(r"\breboot\.target|kexec\.target", jobs):
            return "reboot"
        if re.search(r"\b(poweroff|halt|shutdown)\.target", jobs):
            return "shutdown"
        rc, out, _ = run(["systemctl", "is-system-running"], timeout=4)
        if out.strip() == "stopping":
            return "shutdown"
    except Exception:
        pass
    if os.path.exists("/run/nologin") and os.path.exists("/run/systemd/shutdown/scheduled"):
        return "shutdown"
    return None


def running_desktop_names():
    rc, out, _ = run(["docker", "ps", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=15)
    return sorted(out.split()) if rc == 0 else []


def _oom_hint(pid, since):
    """Best effort: did the kernel's OOM killer take this pid?"""
    for cmd in (["journalctl", "-k", "--no-pager", "-q", "--since", "@%d" % int(since)],
                ["dmesg"]):
        try:
            rc, out, _ = run(cmd, timeout=6)
        except Exception:
            continue
        if rc == 0 and re.search(r"Killed process %s\b" % pid, out):
            return True
    return False


STOP_LABELS = {
    "user": "you stopped it",
    "ctrl-c": "you stopped it with ctrl-c",
    "restart": "it was restarted",
    "update": "it restarted to install an update",
    "host-reboot": "this machine rebooted",
    "host-shutdown": "this machine shut down",
    "signal": "something sent it a stop signal",
    "service": "its systemd service was stopped",
    "error": "it hit an error and exited",
    "host-crash": "this machine crashed or lost power",
    "crash": "the web UI process died unexpectedly",
    "oom": "the system ran out of memory and killed it",
}


def analyze_life(life, now_boot=None):
    """Explain how a recorded web UI run ended."""
    if not life:
        return None
    now_boot = now_boot if now_boot is not None else boot_id()
    stopped = life.get("stopped") or {}
    boot_changed = bool(life.get("boot_id") and now_boot and life["boot_id"] != now_boot)
    out = {"pid": life.get("pid"), "started": life.get("started"),
           "last_seen": life.get("heartbeat") or life.get("started"),
           "desktops_running": life.get("desktops_running") or [],
           "boot_changed": boot_changed, "boot_time": boot_time() if boot_changed else None}
    if stopped.get("reason"):
        out.update(reason=stopped["reason"], at=stopped.get("at"),
                   detail=stopped.get("detail") or "")
        # A clean SIGTERM we could not place, followed by a new boot, was the
        # machine going down.
        if stopped["reason"] == "signal" and boot_changed:
            out["reason"] = "host-shutdown"
    elif pid_alive(life.get("pid")) and not boot_changed:
        return None                                   # still running
    elif boot_changed:
        out.update(reason="host-crash", at=life.get("heartbeat"),
                   detail="the last sign of life was its heartbeat; nothing "
                          "recorded a clean shutdown")
    else:
        oom = _oom_hint(life.get("pid"), life.get("heartbeat") or life.get("started") or 0)
        out.update(reason="oom" if oom else "crash", at=life.get("heartbeat"),
                   detail=_webui_log_tail())
    out["label"] = STOP_LABELS.get(out["reason"], out["reason"])
    out["clean"] = out["reason"] in ("user", "ctrl-c", "restart", "update", "service",
                                     "host-reboot", "host-shutdown")
    return out


def _webui_log_tail():
    try:
        with open(os.path.join(LOGDIR, "webui.log"), errors="replace") as fh:
            lines = [l.rstrip() for l in fh.readlines()[-30:]
                     if l.strip() and not l.lstrip().startswith("{")]
        tb = [l for l in lines if "Error" in l or "Traceback" in l or "Exception" in l]
        return (tb[-1] if tb else "")[:300]
    except OSError:
        return ""


def last_stop_report():
    """What the CLI and UI show about the previous run, or None."""
    info = jload(SERVER_JSON, None)
    life = jload(LIFE_JSON, None)
    up = bool(info and pid_alive(info.get("pid")))
    if up:
        rep = jload(LAST_STOP_JSON, None)
        if not rep or rep.get("dismissed") or time.time() - float(rep.get("recorded") or 0) > 7 * 86400:
            return None
    else:
        rep = analyze_life(life)
        if rep:
            prev = jload(LAST_STOP_JSON, {}) or {}
            if prev.get("dismissed") and prev.get("pid") == rep.get("pid"):
                rep["dismissed"] = True
    if not rep:
        return None
    running = set(running_desktop_names())
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=15)
    exists = set(out.split()) if rc == 0 else set()
    rep["restore"] = [n for n in rep.get("desktops_running") or []
                      if n in exists and n not in running]
    return rep


def dismiss_last_stop():
    rep = last_stop_report() or {}
    rep["dismissed"] = True
    rep.setdefault("recorded", time.time())
    jsave(LAST_STOP_JSON, rep)
    return {"ok": True}


UNIT_NAME = "selkies-forge.service"
CRON_MARK = "# selkies-forge-boot"


def _unit_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "systemd", "user", UNIT_NAME)


def _user():
    import pwd
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return os.environ.get("USER") or ""


def systemd_user_ok():
    if not have("systemctl"):
        return False
    rc, _, _ = run(["systemctl", "--user", "show-environment"], timeout=8)
    return rc == 0


def linger_on():
    if not have("loginctl"):
        return None
    rc, out, _ = run(["loginctl", "show-user", _user(), "-p", "Linger", "--value"], timeout=8)
    if rc != 0:
        return None
    return out.strip() == "yes"


def _serve_argv(port, bind, expose):
    a = [sys.executable, os.path.join(APPDIR, "engine.py"), "serve",
         "--port", str(int(port)), "--bind", bind]
    if expose:
        a.append("--tunnel")
    return a


def _crontab_lines():
    if not have("crontab"):
        return None
    rc, out, err = run(["crontab", "-l"], timeout=10)
    if rc != 0:
        return [] if "no crontab" in (err or "").lower() or not err.strip() else []
    return out.splitlines()


def _crontab_write(lines):
    p = subprocess.run(["crontab", "-"], input="\n".join(lines) + "\n", text=True,
                       capture_output=True, timeout=10)
    if p.returncode != 0:
        raise RuntimeError("crontab refused the change: %s" % (p.stderr or p.stdout).strip())


def boot_report():
    st = jload(BOOT_JSON, {}) or {}
    out = {"asked": bool(st.get("asked")), "enabled": False, "method": st.get("method"),
           "port": st.get("port"), "bind": st.get("bind"), "expose": st.get("expose")}
    try:
        if os.path.exists(_unit_path()) and have("systemctl"):
            rc, o, _ = run(["systemctl", "--user", "is-enabled", UNIT_NAME], timeout=8)
            if o.strip() == "enabled":
                out.update(enabled=True, method="systemd", linger=linger_on())
                return out
        lines = _crontab_lines() or []
        if any(CRON_MARK in l for l in lines):
            out.update(enabled=True, method="cron")
    except Exception:
        pass
    return out


def boot_enable(port=8787, bind="127.0.0.1", expose=False, try_linger=True):
    argv = _serve_argv(port, bind, expose)
    log = os.path.join(LOGDIR, "webui.log")
    res = {"ok": True}
    if os.environ.get("FORGE_BOOT_METHOD") != "cron" and systemd_user_ok():
        path = _unit_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        unit = "\n".join([
            "[Unit]",
            "Description=Selkies Forge web UI",
            "Documentation=https://github.com/adatskov-wcpss/animated-fiesta",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            "Environment=FORGE_BOOT=1",
            "Environment=FORGE_HOME=%s" % ROOT,
            "Environment=PATH=%s" % ":".join(dict.fromkeys(
                p for p in os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin").split(":")
                if p and " " not in p)),
            "ExecStart=%s" % " ".join(shlex.quote(a) for a in argv),
            "StandardOutput=append:%s" % log,
            "StandardError=append:%s" % log,
            # A crash (or the OOM killer) brings it back; a clean stop does not.
            "Restart=on-failure",
            "RestartSec=5",
            "",
            "[Install]",
            "WantedBy=default.target",
            ""])
        with open(path, "w") as fh:
            fh.write(unit)
        run(["systemctl", "--user", "daemon-reload"], timeout=20)
        rc, out, err = run(["systemctl", "--user", "enable", UNIT_NAME], timeout=20)
        if rc != 0:
            raise RuntimeError("systemctl --user enable failed: %s" % (err or out).strip())
        res["method"] = "systemd"
        lg = linger_on()
        if lg is False and try_linger:
            run(["loginctl", "enable-linger", _user()], timeout=15)
            lg = linger_on()
        res["linger"] = lg
        if lg is False:
            res["needs"] = "sudo loginctl enable-linger %s" % _user()
    elif _crontab_lines() is not None:
        lines = [l for l in (_crontab_lines() or []) if CRON_MARK not in l]
        lines.append("@reboot sleep 20; FORGE_BOOT=1 FORGE_HOME=%s %s >> %s 2>&1 %s"
                     % (shlex.quote(ROOT), " ".join(shlex.quote(a) for a in argv),
                        shlex.quote(log), CRON_MARK))
        _crontab_write(lines)
        res["method"] = "cron"
    else:
        raise RuntimeError("this machine has neither a systemd user session nor cron; "
                           "add `selkies-cli start` to your own startup instead")
    jsave(BOOT_JSON, {"asked": True, "enabled": True, "method": res["method"],
                      "port": int(port), "bind": bind, "expose": bool(expose)})
    return res


def boot_disable():
    if os.path.exists(_unit_path()):
        run(["systemctl", "--user", "disable", UNIT_NAME], timeout=20)
        try:
            os.remove(_unit_path())
        except OSError:
            pass
        run(["systemctl", "--user", "daemon-reload"], timeout=20)
    lines = _crontab_lines()
    if lines and any(CRON_MARK in l for l in lines):
        _crontab_write([l for l in lines if CRON_MARK not in l])
    st = jload(BOOT_JSON, {}) or {}
    st.update(asked=True, enabled=False)
    jsave(BOOT_JSON, st)
    return {"ok": True}


def boot_mark_asked():
    st = jload(BOOT_JSON, {}) or {}
    st["asked"] = True
    jsave(BOOT_JSON, st)
    return {"ok": True}


def request_stop(reason):
    """Tell a running web UI why it is about to be stopped (read by its signal handler)."""
    info = jload(SERVER_JSON, None) or {}
    jsave(STOP_REQUEST_JSON, {"pid": info.get("pid"), "reason": reason, "at": time.time()})
    return {"ok": True, "pid": info.get("pid")}


def webui_status():
    """Is the web UI up?  up / stale (recorded but dead or not answering) / down."""
    info = jload(SERVER_JSON, None)
    if not info or not info.get("pid"):
        return {"state": "down"}
    out = {"state": "stale", "pid": info.get("pid"), "port": info.get("port"),
           "url": info.get("url"), "bind": info.get("bind"),
           "tunnel": info.get("tunnel"), "started": info.get("started"),
           "uptime_s": int(time.time() - float(info.get("started") or time.time())),
           "log": os.path.join(LOGDIR, "webui.log")}
    if not pid_alive(info["pid"]):
        out["why"] = "its process (pid %s) is gone" % info["pid"]
        return out
    try:
        req = urllib.request.Request("http://127.0.0.1:%d/api/host" % int(info["port"]),
                                     headers={"User-Agent": "selkies-cli",
                                              "X-Forge-Token": info.get("token") or ""})
        with urllib.request.urlopen(req, timeout=4) as r:
            ok = r.status < 500
    except urllib.error.HTTPError as ex:
        ok = ex.code in (401, 403)          # token-protected, but alive
    except Exception as ex:
        ok = False
        out["why"] = "it is running but not answering (%s)" % type(ex).__name__
    if ok:
        out["state"] = "up"
        out["payload"] = info.get("payload")
        inst = installed_payload()
        out["restart_needed"] = bool(info.get("payload") and inst and info.get("payload") != inst)
    return out


def forge_status():
    items = []
    try:
        for i in docker_instances():
            t = i.get("tunnel") or {}
            items.append({"name": i["name"], "title": i["title"], "running": i["running"],
                          "status": i.get("status"), "local_url": i.get("local_url"),
                          "public_url": t.get("url") if t.get("alive") else None,
                          "autostart": i.get("autostart"), "started_at": i.get("started_at")})
    except Exception:
        pass
    ok, err = docker_ok()
    try:
        last = last_stop_report()
    except Exception:
        last = None
    return {"version": VERSION, "webui": webui_status(), "docker": ok,
            "last_stop": last, "boot": boot_report(),
            "docker_error": None if ok else err, "desktops": items,
            "running": sum(1 for i in items if i["running"]),
            "stopped": sum(1 for i in items if not i["running"])}
