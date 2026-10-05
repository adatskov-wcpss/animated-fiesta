"""
Selkies Forge engine - tunnels

serveo tunnels: open, watch, close.
"""

import os
import re
import signal
import subprocess
import time

from .paths import ANSI_RE, LOGDIR, SSH_KEY, STATE
from .store import reg_load, reg_update
from .util import ensure_dirs, have, pid_alive, run, slug


def ensure_ssh_key():
    if os.path.exists(SSH_KEY):
        return SSH_KEY
    ensure_dirs()
    rc, _, err = run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                      "selkies-forge", "-f", SSH_KEY], timeout=60)
    if rc != 0 and not os.path.exists(SSH_KEY):
        return None
    try:
        os.chmod(SSH_KEY, 0o600)
    except OSError:
        pass
    return SSH_KEY


TUNNEL_HTTP_RE = re.compile(r"https?://[A-Za-z0-9._-]+\.serveousercontent\.com")
TUNNEL_TCP_RE = re.compile(r"(?:serveo\.net|serveousercontent\.com):(\d+)")


def tunnel_logfile(name):
    return os.path.join(LOGDIR, "tunnel-%s.log" % slug(name))


def tunnel_start(name, local_port, mode="http", subdomain=None, wait=50.0, record=True, host="localhost"):
    """Open a serveo tunnel.  Returns a dict describing it, or raises.

    record=False leaves the desktop registry alone (addons keep their own
    record); stop such a tunnel with kill_tunnel(info)."""
    if not have("ssh"):
        raise RuntimeError("ssh is not installed, cannot open a tunnel")
    ensure_dirs()
    if record:
        tunnel_stop(name)
    log = tunnel_logfile(name)
    try:
        os.remove(log)
    except OSError:
        pass

    key = ensure_ssh_key()
    remote = "80" if mode == "http" else "0"
    if mode == "http" and subdomain:
        remote = "%s:80" % re.sub(r"[^a-z0-9-]", "", subdomain.lower())
    cmd = ["ssh", "-T", "-n",
           "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=%s" % os.path.join(STATE, "known_hosts"),
           "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
           "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=20"]
    # Deliberately no BatchMode and no NumberOfPasswordPrompts=0 here: serveo
    # authorises anonymous tunnels over keyboard-interactive, and both of
    # those options switch that method off, which just yields
    # "Permission denied (publickey,keyboard-interactive)".
    if key:
        cmd += ["-i", key, "-o", "IdentitiesOnly=yes"]
    cmd += ["-R", "%s:%s:%d" % (remote, host, int(local_port)), "serveo.net"]

    fh = open(log, "ab", buffering=0)
    proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, start_new_session=True)

    deadline = time.time() + wait
    url = None
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        try:
            with open(log, "r", errors="replace") as rh:
                txt = ANSI_RE.sub("", rh.read())
        except OSError:
            txt = ""
        if mode == "http":
            m = TUNNEL_HTTP_RE.search(txt)
            if m:
                url = m.group(0)
                break
        else:
            m = TUNNEL_TCP_RE.search(txt)
            if m:
                url = "https://serveousercontent.com:%s" % m.group(1)
                break
        time.sleep(0.4)

    if not url:
        try:
            with open(log, "r", errors="replace") as rh:
                tail = ANSI_RE.sub("", rh.read())[-600:].strip()
        except OSError:
            tail = ""
        try:
            proc.terminate()
        except Exception:
            pass
        raise RuntimeError("serveo did not hand back a URL. %s" % (tail or "no output"))

    info = {"url": url, "mode": mode, "pid": proc.pid, "port": int(local_port),
            "log": log, "started": time.time(), "alive": True}
    if record:
        reg_update(name, {"tunnel": info})
    return info


def kill_tunnel(info):
    """Stop a tunnel from its info dict (what tunnel_start returned)."""
    if info and info.get("pid") and pid_alive(info["pid"]):
        try:
            os.killpg(os.getpgid(int(info["pid"])), signal.SIGTERM)
        except Exception:
            try:
                os.kill(int(info["pid"]), signal.SIGTERM)
            except Exception:
                pass


def tunnel_status(name, info=None):
    if info is None:
        info = (reg_load().get(name) or {}).get("tunnel")
    if not info:
        return None
    info = dict(info)
    info["alive"] = pid_alive(info.get("pid"))
    return info


def tunnel_stop(name):
    info = (reg_load().get(name) or {}).get("tunnel")
    if info and info.get("pid") and pid_alive(info["pid"]):
        try:
            os.killpg(os.getpgid(int(info["pid"])), signal.SIGTERM)
        except Exception:
            try:
                os.kill(int(info["pid"]), signal.SIGTERM)
            except Exception:
                pass
    reg_update(name, {"tunnel": None})
    return True
