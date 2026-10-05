"""
Selkies Forge engine - lifecycle

Start, stop, restart, remove, repair and reconfigure existing desktops.

Every action on a desktop holds that desktop's lock (inst-<name>), so a stop
from the CLI and a repair from the web UI can never run over each other, and
is written to the event journal *before* it runs: that is how the watchdog
knows a desktop that just exited was stopped on purpose, not crashed.
"""

import json
import re

from . import catalog, events
from .health import LaunchProblem, wait_healthy, wait_http, wait_session
from .host import host_info, image_present
from .images import ensure_layer
from .paths import CPREFIX, KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS
from .recipes import build_image_tag
from .registry import docker_instances
from .gpu import ENV_KEYS as GPU_ENV_KEYS, mode_from_container as gpu_mode_from_container
from .runner import FIXED_SCREEN_KEYS, OLD_SCREEN_KEYS, display_for, docker_run_args, parse_display_label
from .store import reg_delete, reg_load, reg_update
from .tunnels import tunnel_start, tunnel_stop
from .util import FileLock, _int_or_none, run, slug

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def _locked(name, kind, detail, fn):
    if not NAME_RE.match(name or ""):
        raise RuntimeError("bad container name")
    events.record(name, kind, detail)
    try:
        with FileLock("inst-" + name, timeout=900):
            return fn()
    except Exception as ex:
        events.record(name, kind + "-failed", str(ex)[:500])
        raise


def _screen_plan(labels, display, resolution):
    """(display, resolution, changes) for a reconfigure of a container with
    these labels. `changes` says whether the screen that would run differs
    from the one running now, so only a real change recreates it."""
    cur_display, cur_res = parse_display_label(labels.get("%s.display" % LABEL))
    running = (cur_display, cur_res)
    if (labels.get("%s.version" % LABEL) == "1.6.0" and cur_display == "fixed"
            and cur_res == "1920x1080"):
        # 1.6.0 forced every desktop onto a fixed 1920x1080, and the label
        # cannot tell that apart from choosing it. Treat it as automatic, so
        # the next recreate or repair goes back to the desktop's own default.
        cur_display = "auto"
    want_display = cur_display if display in (None, "") else str(display)
    want_res = cur_res if resolution in (None, "") else str(resolution)
    entry = catalog.BY_ID.get(labels.get("%s.entry" % LABEL))
    if display in (None, "") or not entry or entry.get("profile") == "kasm":
        return want_display, want_res, False
    # Compare the screens that would actually run, not the words for them:
    # "auto" on a desktop 1.6.0 forced to a fixed screen is a real change.
    mode, res = display_for(entry, {"display": want_display, "resolution": want_res})
    return want_display, want_res, (mode, "%dx%d" % res if res else None) != running


def instance_action(name, action, opts=None):
    """start | stop | restart | remove | tunnel | untunnel | repair, under the desktop's lock."""
    return _locked(name, action, "requested", lambda: _instance_action(name, action, opts))


def reconfigure(name, memory_mb=None, cpus=None, shm_mb=None, disk_mb=None,
                autostart=None, display=None, resolution=None, repair=False):
    """Change limits or screen mode, or repair; see _reconfigure."""
    detail = "repair" if repair else ", ".join(
        "%s=%s" % (k, v) for k, v in (("memory_mb", memory_mb), ("cpus", cpus), ("shm_mb", shm_mb),
                                      ("disk_mb", disk_mb), ("autostart", autostart),
                                      ("display", display), ("resolution", resolution))
        if v not in (None, ""))
    return _locked(name, "repair" if repair else "retune", detail,
                   lambda: _reconfigure(name, memory_mb, cpus, shm_mb, disk_mb, autostart,
                                        display, resolution, repair))


def _instance_action(name, action, opts=None):
    opts = opts or {}
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    if action == "start":
        rc, out, err = run(["docker", "start", name], timeout=120)
    elif action == "stop":
        tunnel_stop(name)
        rc, out, err = run(["docker", "stop", "-t", "20", name], timeout=180)
    elif action == "restart":
        tunnel_stop(name)
        rc, out, err = run(["docker", "restart", "-t", "20", name], timeout=240)
    elif action == "remove":
        tunnel_stop(name)
        run(["docker", "rm", "-f", name], timeout=180)
        if opts.get("purge"):
            vol = (reg_load().get(name) or {}).get("volume") or "%sconfig-%s" % (CPREFIX, slug(name))
            run(["docker", "volume", "rm", "-f", vol], timeout=120)
        reg_delete(name)
        return {"ok": True}
    elif action == "tunnel":
        inst = next((i for i in docker_instances() if i["name"] == name), None)
        if not inst or not inst["running"]:
            raise RuntimeError("%s is not running" % name)
        port = (inst["ports"] or {}).get(
            str(KASM_HTTPS) if inst["profile"] == "kasm" else str(SELKIES_HTTP))
        if not port:
            raise RuntimeError("no published port to tunnel")
        mode = "tcp" if inst["profile"] == "kasm" else "http"
        return {"ok": True, "tunnel": tunnel_start(name, port, mode=mode,
                                                   subdomain=opts.get("subdomain"))}
    elif action == "untunnel":
        tunnel_stop(name)
        return {"ok": True}
    elif action == "repair":
        return _reconfigure(name, repair=True)
    else:
        raise RuntimeError("unknown action %s" % action)
    if rc != 0:
        raise RuntimeError((err or out).strip() or "docker %s failed" % action)
    return {"ok": True}


def _reconfigure(name, memory_mb=None, cpus=None, shm_mb=None, disk_mb=None,
                 autostart=None, display=None, resolution=None, repair=False):
    """Change an instance's limits, its screen mode, or repair it.

    Memory, CPU and auto-start apply live. Docker cannot change /dev/shm, the
    storage budget or the environment of a running container, so those (and
    a repair, which moves it onto the newest forge layer) recreate it on the
    same ports, environment and /config volume: files survive.
    """
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    rc, out, err = run(["docker", "inspect", name], timeout=40)
    if rc != 0:
        raise RuntimeError("no such container: %s" % name)
    c = json.loads(out)[0]
    hostcfg = c.get("HostConfig") or {}
    labels = (c.get("Config") or {}).get("Labels") or {}
    cur_shm = int((hostcfg.get("ShmSize") or 0) / (1024 * 1024))
    cur_disk = _int_or_none(labels.get("%s.disk" % LABEL))
    want_display, want_res, screen_changes = _screen_plan(labels, display, resolution)
    need_recreate = ((shm_mb and int(shm_mb) != cur_shm) or
                     (disk_mb and cur_disk and int(disk_mb) != cur_disk) or
                     repair or screen_changes)

    if not need_recreate:
        args = ["docker", "update"]
        if memory_mb:
            args += ["--memory", "%dm" % int(memory_mb),
                     "--memory-swap", "%dm" % int(memory_mb)]
        if cpus:
            args += ["--cpus", str(cpus)]
        if autostart is not None:
            args += ["--restart", "unless-stopped" if autostart else "no"]
        if len(args) > 2:
            args.append(name)
            rc, out, err = run(args, timeout=90)
            if rc != 0:
                raise RuntimeError((err or out).strip())
        return {"ok": True, "recreated": False}

    entry = catalog.BY_ID.get(labels.get("%s.entry" % LABEL))
    if not entry:
        raise RuntimeError("this container was not made by the forge")
    env = {}
    for kv in ((c.get("Config") or {}).get("Env") or []):
        k, _, v = kv.partition("=")
        env[k] = v
    # Anything the user added at launch (not ours, not the image's) is carried over.
    image_env = set()
    rc_i, out_i, _ = run(["docker", "image", "inspect", "-f", "{{json .Config.Env}}",
                          (c.get("Config") or {}).get("Image") or ""], timeout=30)
    if rc_i == 0:
        try:
            image_env = set(json.loads(out_i) or [])
        except Exception:
            pass
    ports = []
    for cport in ((str(KASM_HTTPS),) if entry["profile"] == "kasm"
                  else (str(SELKIES_HTTP), str(SELKIES_HTTPS))):
        binds = ((c.get("NetworkSettings") or {}).get("Ports") or {}).get(cport + "/tcp") or \
            (hostcfg.get("PortBindings") or {}).get(cport + "/tcp") or []
        if binds:
            ports.append(int(binds[0].get("HostPort")))
    if not ports:
        raise RuntimeError("could not read the published ports")
    restart = ((hostcfg.get("RestartPolicy") or {}).get("Name") or "no")

    plan = {
        "memory_mb": int(memory_mb or (hostcfg.get("Memory") or 0) / (1024 * 1024) or 1024),
        "cpus": float(cpus or (hostcfg.get("NanoCpus") or 0) / 1e9 or 1),
        "shm_mb": int(shm_mb or cur_shm or 256),
        "disk_mb": int(disk_mb or cur_disk or 10240),
    }
    opts = {"autostart": (restart != "no") if autostart is None else bool(autostart),
            "gpu": gpu_mode_from_container(labels, hostcfg, "%s.gpu" % LABEL),
            "seccomp_unconfined": "seccomp=unconfined" in (hostcfg.get("SecurityOpt") or []),
            "heal": labels.get("%s.heal" % LABEL) != "off"}
    if env.get("CUSTOM_USER") and env.get("PASSWORD"):
        opts["username"], opts["password"] = env["CUSTOM_USER"], env["PASSWORD"]
    if env.get("VNC_PW"):
        opts["password"] = env["VNC_PW"]
    if env.get("LC_ALL"):
        opts["locale"] = env["LC_ALL"]
    ours = ("PUID", "PGID", "TZ", "TITLE", "CUSTOM_USER", "PASSWORD", "VNC_PW", "LC_ALL",
            "MAX_RES") + FIXED_SCREEN_KEYS + OLD_SCREEN_KEYS + GPU_ENV_KEYS
    opts["env"] = ["%s=%s" % (k, v) for k, v in env.items()
                   if k not in ours and "%s=%s" % (k, v) not in image_env]
    opts["display"] = want_display if want_display in ("fit", "fixed") else "auto"
    if want_res:
        opts["resolution"] = want_res
    image = (c.get("Config") or {}).get("Image")
    if repair or entry.get("profile") != "kasm":
        # Always run on the newest forge layer; a repair rebuilds it if needed.
        base = entry["image"] if entry["kind"] == "pull" else build_image_tag(entry)
        if image_present(base):
            image = ensure_layer(entry, base)
        elif repair:
            raise RuntimeError("the desktop image %s is gone from this machine; "
                               "forge this desktop again instead" % base)
    was_running = bool((c.get("State") or {}).get("Running"))

    tunnel = (reg_load().get(name) or {}).get("tunnel")
    tunnel_stop(name)
    rc, out, err = run(["docker", "rm", "-f", name], timeout=120)
    if rc != 0:
        raise RuntimeError("could not remove the old container: %s" % (err or out).strip())
    args, _vol = docker_run_args(entry, name, ports, plan, opts, image, host_info())
    rc, out, err = run(args, timeout=180)
    if rc != 0:
        raise RuntimeError("recreate failed: %s" % (err or out).strip())
    reg_update(name, {"plan": plan, "image": image})
    if not was_running and not repair:
        run(["docker", "stop", name], timeout=120)
    elif tunnel:
        try:
            wait_healthy(name, ports[0], entry["profile"], timeout=240)
            tunnel_start(name, ports[0], mode=tunnel.get("mode", "http"))
        except Exception:
            pass
    out = {"ok": True, "recreated": True, "image": image}
    if repair:
        try:
            wait_http(name, ports[0], entry["profile"], timeout=300)
            out["session"] = wait_session(name, entry, timeout=150)
        except LaunchProblem as lp:
            out["warning"] = "%s\n%s" % (lp, (lp.detail or "")[-800:])
    return out


def retune(name, memory_mb=None, cpus=None):
    """Change limits on a live container, no restart needed."""
    args = ["docker", "update"]
    if memory_mb:
        args += ["--memory", "%dm" % int(memory_mb), "--memory-swap", "%dm" % int(memory_mb)]
    if cpus:
        args += ["--cpus", str(cpus)]
    if len(args) == 2:
        raise RuntimeError("nothing to change")
    args.append(name)
    rc, out, err = run(args, timeout=90)
    if rc != 0:
        raise RuntimeError((err or out).strip())
    return {"ok": True}


def set_idle(name, minutes):
    """Stop this desktop after `minutes` with nobody watching (0: never; None:
    follow FORGE_IDLE_STOP_MIN). Takes effect at once; nothing is recreated."""
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    if run(["docker", "inspect", "-f", "{{.Name}}", name], timeout=20)[0] != 0:
        raise RuntimeError("no such container: %s" % name)
    value = None if minutes is None or minutes == "" else max(0, int(minutes))
    reg_update(name, {"idle_stop_min": value})
    events.record(name, "idle-limit", "stop after %d idle minutes" % value if value
                  else ("never stopped for being idle" if value == 0 else "the forge default"))
    return {"name": name, "idle_stop_min": value}
