"""
Selkies Forge engine - IPv6 for desktops

Docker's default bridge has no IPv6, and turning it on means editing daemon.json
and restarting Docker. So every desktop also joins one extra network that has
IPv6 (private addresses, translated on the way out, like Docker does for IPv4).

A desktop stays on the default bridge: its IPv4 address, route and published
ports don't change, and joining works on a running desktop without restarting it.
"""

import os
import time

from .util import run

NET = "selkies-forge"
SUBNET = "fd53:6b66:6f72::/64"
MIN_DOCKER = 28      # older Docker keeps one default gateway for IPv4 and IPv6 together
RTF_REJECT = 0x200
RECHECK = 600.0      # a machine that can't do it now may be able to later
SYNC_EVERY = 60.0

_state = {"ok": None, "reason": "", "fix": None, "at": 0.0}
_synced = {"names": None, "at": 0.0}


def _read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def default_routes(text=None):
    """Interfaces holding an IPv6 default route, from /proc/net/ipv6_route."""
    text = _read("/proc/net/ipv6_route") if text is None else text
    out = []
    for line in (text or "").splitlines():
        p = line.split()
        if len(p) < 10 or p[0] != "0" * 32 or p[1] != "00" or p[9] == "lo":
            continue
        if int(p[8], 16) & RTF_REJECT:
            continue
        if p[9] not in out:
            out.append(p[9])
    return out


def host_problem(routes=None, read=_read):
    """Why this machine shouldn't get the network: (reason, fix), or None if it's fine."""
    if read("/proc/sys/net/ipv6/conf/all/disable_ipv6") in (None, "1"):
        return "IPv6 is turned off on this machine", None
    routes = default_routes() if routes is None else routes
    if not routes:
        return "this machine has no IPv6 route to the internet", None
    # Docker turns on IPv6 forwarding for this network, and with forwarding on the
    # kernel stops listening to router advertisements on an interface set to
    # accept_ra=1. The machine would lose its own IPv6 when its route expires.
    if read("/proc/sys/net/ipv6/conf/all/forwarding") != "1":
        risky = [i for i in routes if read("/proc/sys/net/ipv6/conf/%s/accept_ra" % i) == "1"]
        if risky:
            return ("left off so this machine keeps its own IPv6 route (%s)" % ", ".join(risky),
                    "; ".join("sudo sysctl -w net.ipv6.conf.%s.accept_ra=2" % i for i in risky))
    return None


def _docker_major():
    rc, out, _ = run(["docker", "version", "--format", "{{.Server.Version}}"], timeout=20)
    try:
        return int(out.strip().split(".")[0]) if rc == 0 else 0
    except ValueError:
        return 0


def _set(ok, reason="", fix=None):
    _state.update(ok=ok, reason=reason, fix=fix, at=time.time())
    return ok


def ensure():
    """Make sure the network exists. True when desktops can join it."""
    if os.environ.get("FORGE_IPV6", "1") == "0":
        return _set(False, "turned off with FORGE_IPV6=0")
    if _state["ok"]:
        return True
    if _state["ok"] is False and time.time() - _state["at"] < RECHECK:
        return False
    rc, out, _ = run(["docker", "network", "inspect", NET, "--format", "{{.EnableIPv6}}"], timeout=20)
    if rc == 0:
        if out.strip() == "true":
            return _set(True)
        return _set(False, "a Docker network called %s exists without IPv6" % NET,
                    "docker network rm %s" % NET)
    major = _docker_major()
    if major < MIN_DOCKER:
        return _set(False, "needs Docker %d or newer" % MIN_DOCKER)
    problem = host_problem()
    if problem:
        return _set(False, problem[0], problem[1])
    rc, out, err = run(["docker", "network", "create", "--ipv6", "--subnet", SUBNET, NET], timeout=40)
    if rc != 0:
        return _set(False, "Docker refused: %s" % ((err or out).strip().splitlines() or ["unknown error"])[-1])
    return _set(True)


def attach(name):
    """Join a desktop to the network. Never raises: a desktop without IPv6 still works."""
    if not ensure():
        return False
    # the lowest gateway priority: IPv4 keeps going out through the default bridge
    rc, out, err = run(["docker", "network", "connect", "--gw-priority", "-1", NET, name], timeout=40)
    return rc == 0 or "already exists" in (err or out)


def sync(names):
    """Join any of these desktops that aren't on the network yet (a recent check is enough)."""
    names = sorted(names)
    now = time.time()
    if names == _synced["names"] and now - _synced["at"] < SYNC_EVERY:
        return []
    _synced.update(names=names, at=now)
    if not names or not ensure():
        return []
    rc, out, _ = run(["docker", "network", "inspect", NET, "--format",
                      "{{range .Containers}}{{.Name}} {{end}}"], timeout=20)
    if rc != 0:
        return []
    joined = set(out.split())
    return [n for n in names if n not in joined and attach(n)]


def status():
    """For the doctor: {ok, detail, fix}."""
    ok = ensure()
    return {"ok": ok, "detail": "desktops get IPv6 through the %s network" % NET if ok else _state["reason"],
            "fix": _state["fix"]}


def address(container):
    """A docker inspect result's IPv6 address, if it has one."""
    nets = ((container.get("NetworkSettings") or {}).get("Networks") or {})
    for net in nets.values():
        if net.get("GlobalIPv6Address"):
            return net["GlobalIPv6Address"]
    return None
