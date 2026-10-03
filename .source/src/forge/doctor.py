"""
Selkies Forge engine - doctor

Checks of this machine, for `selkies-cli doctor` and the web UI.
"""

import socket
import sys

from . import catalog
from .host import docker_ok, host_info
from .util import have, human_mb


def cli_doctor():
    host = host_info(fresh=True)
    checks = []

    def add(name, ok, detail, fix=None, severity="error"):
        checks.append({"name": name, "ok": bool(ok), "detail": detail, "fix": fix,
                       "severity": severity})

    add("python", sys.version_info >= (3, 8), "python %s" % host["python"],
        "install python 3.8 or newer")
    ok, err = docker_ok() if have("docker") else (False, "docker is not installed")
    add("docker", ok, host.get("docker_version") and
        "docker %s, %s driver" % (host["docker_version"], host["storage_driver"]) or err,
        "install docker, then add yourself to the docker group")
    add("ssh", host["ssh"], "ssh client present" if host["ssh"] else "missing",
        "install openssh-client for serveo tunnels")
    add("memory", host["mem_avail_mb"] >= 900,
        "%s free of %s" % (human_mb(host["mem_avail_mb"]), human_mb(host["mem_total_mb"])),
        "close something, or pick a feather-weight desktop")
    add("disk", host["disk_free_mb"] >= 6000,
        "%s free on %s" % (human_mb(host["disk_free_mb"]), host.get("docker_root") or "/"),
        "docker system prune -af")
    add("architecture", bool([e for e in catalog.CATALOG if host["arch"] in e["arches"]]),
        "%s, %d of %d catalog entries available"
        % (host["arch"], sum(1 for e in catalog.CATALOG if host["arch"] in e["arches"]),
           len(catalog.CATALOG)), None)
    add("disk quota", host["quota_support"],
        "hard per-container caps supported" if host["quota_support"] else
        "%s on %s: caps are advisory only" % (host.get("storage_driver"),
                                             host.get("backing_fs")),
        "use xfs with project quotas if you need hard caps", severity="info")
    net_ok = False
    try:
        socket.create_connection(("serveo.net", 22), timeout=6).close()
        net_ok = True
    except Exception:
        pass
    add("serveo", net_ok, "serveo.net:22 reachable" if net_ok else
        "cannot reach serveo.net:22", "tunnels will be unavailable; local URLs still work",
        severity="warn")
    return {"host": host, "checks": checks,
            "ok": all(c["ok"] for c in checks if c["name"] in
                      ("python", "docker", "memory", "disk"))}
