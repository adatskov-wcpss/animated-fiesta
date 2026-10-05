"""
Selkies Forge engine - burrow

Burrow publishes ports on their own HTTPS addresses behind a login. It is the
tunnel engine of Aegis × Burrow (github.com/alexd-aero/aegis-burrow), and also
ran on its own (github.com/alexd-aero/burrow). When it is on this machine, the forge offers a
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

from .paths import VERSION
from .util import jload

_CACHE = {"at": 0.0, "value": None}
_LOCK = threading.Lock()


def discovery():
    """Aegis × Burrow (Burrow as the engine under Aegis's gate), or Burrow on
    its own. Both keep the same control socket."""
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
        s.connect(os.path.realpath(self._path))      # a deep home links the socket to a short path
        self.sock = s


def call(method, path, body=None, timeout=10.0):
    sp = socket_path()
    if not sp:
        raise RuntimeError("Burrow is not installed on this machine")
    conn = _UnixConnection(sp, timeout)
    try:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"X-Burrow-Client": "selkies-forge/" + VERSION}     # shown in Burrow's Addon tab
        if data is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=headers)
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


# ------------------------------------------------------------------ the bridge
#
# Selkies Forge <-> Aegis × Burrow. Is the link up, and is it private?
#   up:      Burrow is on this machine, its control socket answers, the forge's
#            drop-in file sits in its integrations folder and is current, and
#            the forge has it as an addon
#   secured: the socket is a socket, owned by this user, mode 600, in a folder
#            only this user can enter; the drop-in can't be rewritten by others;
#            the forge's own dashboard isn't published without a login
# Each check: {"id", "label", "state": ok|warn|fail|off, "detail"}.

def _mode(path):
    try:
        st = os.stat(path)
        return st.st_mode & 0o777, st.st_uid
    except OSError:
        return None, None


def health(addons_mod=None):
    import stat as _stat
    checks = []

    def add(cid, label, state, detail=""):
        checks.append({"id": cid, "label": label, "state": state, "detail": detail})

    d = discovery()
    if not d:
        add("found", "Aegis × Burrow on this machine", "off", "not installed: add it under Addons to build the bridge")
        return {"state": "off", "checks": checks, "checked": time.time()}
    add("found", "Aegis × Burrow on this machine", "ok", "%s %s in %s" % (d.get("app") or "burrow", d.get("version") or "", d.get("home") or "?"))

    home = d.get("home") or ""
    sock = os.path.join(home, "data", "control.sock")
    mode, uid = _mode(sock)
    if mode is None:
        add("socket", "Control socket", "fail", "%s is missing: is it running?" % sock)
    else:
        is_sock = _stat.S_ISSOCK(os.stat(sock).st_mode)
        dmode, duid = _mode(os.path.dirname(os.path.realpath(sock)))   # data/, or the runtime folder it links to
        problems = []
        if not is_sock:
            problems.append("not a socket")
        if uid != os.getuid():
            problems.append("owned by another user")
        if mode & 0o077:
            problems.append("mode %o, others can connect" % mode)
        if dmode is not None and dmode & 0o077:
            problems.append("its folder is mode %o" % dmode)
        add("socket", "Control socket is private", "fail" if problems else "ok",
            "; ".join(problems) if problems else "%s · mode %o · folder %o · yours" % (sock.replace(os.path.expanduser("~"), "~"), mode, dmode or 0))
    t0 = time.time()
    st = status(max_age=0)
    if st.get("running"):
        add("answer", "Burrow answers", "ok", "%d ms · %s · %d tunnel%s" % ((time.time() - t0) * 1000, st.get("mode") or "?",
                                                                       len(st["tunnels"]), "" if len(st["tunnels"]) == 1 else "s"))
    else:
        add("answer", "Burrow answers", "fail", st.get("error") or "no answer on the control socket")

    if addons_mod is not None:
        dirs = [p for p in addons_mod._integration_dirs() if "/aegis/" in p or "/burrow/" in p]
        drop = None
        for p in dirs:
            f = os.path.join(p, "selkies-forge.json")
            if os.path.isfile(f):
                drop = f
                break
        if not drop:
            add("dropin", "The forge is registered with it", "fail", "no selkies-forge.json in its integrations folder yet")
        else:
            fm, fu = _mode(drop)
            age = time.time() - float((jload(drop, {}) or {}).get("updated") or 0)
            bad = []
            if fu != os.getuid():
                bad.append("owned by another user")
            if fm & 0o022:
                bad.append("group or others can write it (mode %o)" % fm)
            add("dropin", "The forge is registered with it", "fail" if bad else ("ok" if age < 3 * 3600 else "warn"),
                "; ".join(bad) if bad else "%s · refreshed %s ago" % (drop.replace(os.path.expanduser("~"), "~"), _ago(age)))
        recs = [r for r in addons_mod._load().values()
                if (r.get("manifest") or {}).get("integration", {}).get("dir", "").rstrip("/").endswith(("aegis/integrations", "burrow/integrations"))]
        rec = next((r for r in recs if r.get("installed")), None)
        if rec:
            add("addon", "It is an addon of this forge", "ok", "%s %s · %s" % (rec["id"], rec.get("installed_version") or "",
                                                                           "linked" if rec.get("adopted") else "installed here"))
        else:
            add("addon", "It is an addon of this forge", "warn",
                "not added yet: Addons → it is listed under Found on this machine, or use Connect in its Burrow → Selkies Forge tab")

    # the forge's own dashboard: published without a login?
    from .paths import SERVER_JSON
    srv = jload(SERVER_JSON, None) or {}
    port = int(srv.get("port") or 0)
    pub = [t for t in st.get("tunnels") or [] if port and t.get("targetPort") == port and t.get("access") == "public" and t.get("enabled")]
    if pub:
        add("exposed", "The forge's dashboard needs a login", "warn",
            "%s publishes it to anyone (no login). Fine if you meant it; switch it to Login in Burrow otherwise." % (pub[0].get("url") or "a tunnel"))
    elif port:
        add("exposed", "The forge's dashboard needs a login", "ok", "no public tunnel to port %d" % port)

    logos = {}
    if addons_mod is not None:
        import base64
        logos["forge"] = "data:image/svg+xml;base64," + base64.b64encode(addons_mod.FORGE_LOGO.encode()).decode()
        code = d.get("code") or os.path.join(home, "app")
        for rel in ("public/logos/aegis-burrow.svg", "logo.svg"):
            p = os.path.join(code, rel)
            if os.path.isfile(p) and os.path.getsize(p) < 65536:
                with open(p, "rb") as fh:
                    logos["burrow"] = "data:image/svg+xml;base64," + base64.b64encode(fh.read()).decode()
                break
    worst = "ok"
    for c in checks:
        if c["state"] == "fail":
            worst = "fail"
        elif c["state"] == "warn" and worst == "ok":
            worst = "warn"
    return {"state": worst, "checks": checks, "checked": time.time(), "logos": logos}


def _ago(s):
    s = max(0, int(s))
    return "%ds" % s if s < 60 else "%dm" % (s // 60) if s < 3600 else "%dh" % (s // 3600)
