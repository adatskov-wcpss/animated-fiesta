"""
Selkies Forge engine - burrow

Burrow (github.com/alexd-aero/burrow) publishes ports on their own HTTPS
addresses behind a login. When it is on this machine, the forge offers a
Burrow address for every desktop and addon next to the local and serveo ones.

The forge finds Burrow through ~/.config/burrow/burrow.json and talks to its
control socket, BURROW_HOME/data/control.sock: plain HTTP over a Unix socket
that only this user can open (Burrow's HTTPS may speak only the post-quantum
key exchange, which this Python's OpenSSL may not).
"""

import json
import os
import socket
import threading
import time

from http.client import HTTPConnection

from .util import jload

_CACHE = {"at": 0.0, "value": None}
_LOCK = threading.Lock()


def discovery():
    """Burrow on its own, or inside Aegis (github.com/alexd-aero/aegis), which
    carries Burrow as a module and the same control socket."""
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    for env, name, file in (("AEGIS_CONFIG_DIR", "aegis", "aegis.json"), ("BURROW_CONFIG_DIR", "burrow", "burrow.json")):
        d = jload(os.path.join(os.environ.get(env) or os.path.join(cfg, name), file), None)
        if d:
            return d
    return None


def socket_path():
    d = discovery() or {}
    home = d.get("home")
    if not home:
        return None
    p = os.path.join(home, "data", "control.sock")
    return p if os.path.exists(p) else None


class _UnixConnection(HTTPConnection):
    def __init__(self, path, timeout):
        HTTPConnection.__init__(self, "burrow", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def call(method, path, body=None, timeout=10.0):
    sp = socket_path()
    if not sp:
        raise RuntimeError("Burrow is not installed on this machine")
    conn = _UnixConnection(sp, timeout)
    try:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        conn.request(method, path, body=data,
                     headers={"Content-Type": "application/json"} if data is not None else {})
        r = conn.getresponse()
        out = json.loads(r.read().decode("utf-8") or "{}")
        if r.status >= 400:
            raise RuntimeError(out.get("error") or "Burrow answered HTTP %d" % r.status)
        return out
    finally:
        conn.close()


def status(max_age=3.0):
    """{"installed", "running", "mode", "pattern", "tunnels": [{port, url, access, enabled, ...}]}"""
    with _LOCK:
        if _CACHE["value"] is not None and time.time() - _CACHE["at"] < max_age:
            return _CACHE["value"]
    d = discovery()
    out = {"installed": bool(d), "running": False, "dashboard": (d or {}).get("dashboard"), "tunnels": []}
    if d:
        try:
            r = call("GET", "/tunnels", timeout=4.0)
            out.update(running=True, mode=r.get("mode"), pattern=r.get("pattern"), version=r.get("version"),
                       tunnels=[{k: t.get(k) for k in ("port", "url", "host", "access", "enabled",
                                                       "targetHost", "targetPort", "name")}
                                for t in r.get("tunnels") or []])
        except Exception as ex:
            out["error"] = str(ex)
    with _LOCK:
        _CACHE.update(at=time.time(), value=out)
    return out


def forget():
    with _LOCK:
        _CACHE.update(at=0.0, value=None)


_ADDRS = {"at": 0.0, "set": set()}


def local_addresses():
    """Every address of this machine (a tunnel to the Tailscale IP is still local)."""
    if time.time() - _ADDRS["at"] > 60:
        found = {"127.0.0.1", "localhost", "::1"}
        try:
            with os.popen("hostname -I 2>/dev/null") as fh:
                found.update(fh.read().split())
        except OSError:
            pass
        _ADDRS.update(at=time.time(), set=found)
    return _ADDRS["set"]


def tunnel_for(port, st=None):
    st = st or status()
    mine = local_addresses()
    for t in st.get("tunnels") or []:
        if t.get("targetPort") == int(port) and t.get("targetHost") in mine:
            return t
    return None


def publish(port, name, access="login", host="127.0.0.1"):
    """Give a local port its own Burrow address (login-protected unless access="public")."""
    st = status(max_age=0)
    if not st.get("running"):
        raise RuntimeError(st.get("error") or "Burrow is not running")
    have = tunnel_for(port, st)
    if have:
        return have
    try:
        t = call("POST", "/tunnels", {"port": int(port), "targetHost": host, "targetPort": int(port),
                                      "name": str(name or "")[:60], "access": access}, timeout=60.0)
    finally:
        forget()
    return t


def unpublish(port):
    t = tunnel_for(port, status(max_age=0))
    if not t:
        return {"ok": True, "removed": None}
    try:
        return call("DELETE", "/tunnels/%d" % int(t["port"]), timeout=60.0)
    finally:
        forget()
