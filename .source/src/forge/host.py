"""
Selkies Forge engine - host

What this machine is: architecture, memory, disk, Docker, image manifests.
"""

import json
import os
import shutil
import socket
import sys

from .util import cache_get, cache_put, have, run


_ARCH_MAP = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64",
             "arm64": "arm64", "armv7l": "arm", "armv6l": "arm"}


def meminfo():
    out = {"total_mb": 0, "avail_mb": 0, "swap_mb": 0}
    try:
        with open("/proc/meminfo") as fh:
            vals = {}
            for line in fh:
                k, _, v = line.partition(":")
                vals[k.strip()] = v.strip()

            def mb(key):
                try:
                    return int(vals.get(key, "0").split()[0]) // 1024
                except Exception:
                    return 0
            out["total_mb"] = mb("MemTotal")
            out["avail_mb"] = mb("MemAvailable") or mb("MemFree")
            out["swap_mb"] = mb("SwapTotal")
    except Exception:
        pass
    return out


def docker_root():
    rc, out, _ = run(["docker", "info", "--format", "{{.DockerRootDir}}"], timeout=25)
    p = out.strip()
    return p if rc == 0 and p and os.path.isdir(p) else "/var/lib/docker"


def host_info(fresh=False):
    cached = None if fresh else cache_get("host", 20)
    if cached:
        return cached

    mem = meminfo()
    try:
        load1 = os.getloadavg()[0]
    except Exception:
        load1 = 0.0
    cpus = os.cpu_count() or 1

    info = {
        "arch": _ARCH_MAP.get(os.uname().machine, os.uname().machine),
        "machine": os.uname().machine,
        "kernel": os.uname().release,
        "hostname": socket.gethostname(),
        "cpus": cpus,
        "load1": round(load1, 2),
        "cpu_free": round(max(0.0, cpus - load1), 2),
        "mem_total_mb": mem["total_mb"],
        "mem_avail_mb": mem["avail_mb"],
        "swap_mb": mem["swap_mb"],
        "docker": False,
        "docker_version": None,
        "storage_driver": None,
        "backing_fs": None,
        "quota_support": False,
        "cgroup": None,
        "disk_total_mb": 0,
        "disk_free_mb": 0,
        "docker_root": None,
        "os_pretty": None,
        "ssh": have("ssh"),
        "has_dri": os.path.exists("/dev/dri"),
        "python": "%d.%d.%d" % sys.version_info[:3],
    }

    try:
        with open("/etc/os-release") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    info["os_pretty"] = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass

    rc, out, _ = run(["docker", "version", "--format",
                      "{{.Server.Version}}|{{.Server.Arch}}"], timeout=25)
    if rc == 0 and "|" in out:
        ver, arch = out.strip().split("|", 1)
        info["docker"] = True
        info["docker_version"] = ver
        if arch.strip():
            info["arch"] = _ARCH_MAP.get(arch.strip(), arch.strip())

    rc, out, _ = run(["docker", "info", "--format",
                      "{{.Driver}}|{{.CgroupVersion}}|{{.DockerRootDir}}|{{json .DriverStatus}}"],
                     timeout=30)
    if rc == 0 and "|" in out:
        parts = out.strip().split("|", 3)
        info["storage_driver"] = parts[0]
        info["cgroup"] = parts[1] if len(parts) > 1 else None
        info["docker_root"] = parts[2] if len(parts) > 2 else None
        try:
            for k, v in json.loads(parts[3]):
                if k == "Backing Filesystem":
                    info["backing_fs"] = v
        except Exception:
            pass

    # A hard per-container disk cap only exists on xfs with project quotas,
    # or on btrfs/devicemapper.  Everywhere else the cap is advisory.
    drv = (info["storage_driver"] or "").lower()
    fs = (info["backing_fs"] or "").lower()
    info["quota_support"] = bool(
        (drv == "overlay2" and "xfs" in fs) or drv in ("btrfs", "devicemapper", "zfs"))

    root = info["docker_root"] or docker_root()
    try:
        du = shutil.disk_usage(root if os.path.isdir(root) else "/")
        info["disk_total_mb"] = du.total // (1024 * 1024)
        info["disk_free_mb"] = du.free // (1024 * 1024)
    except Exception:
        pass

    cache_put("host", info)
    return info


def docker_ok():
    rc, _, err = run(["docker", "info", "--format", "{{.ID}}"], timeout=30)
    return rc == 0, err.strip()


def image_present(image):
    rc, _, _ = run(["docker", "image", "inspect", image], timeout=30)
    return rc == 0


def image_disk_mb(image):
    rc, out, _ = run(["docker", "image", "inspect", image, "--format", "{{.Size}}"], timeout=30)
    if rc == 0 and out.strip().isdigit():
        return int(out.strip()) // (1024 * 1024)
    return 0


def manifest_probe(image, fallback_arches=None):
    """(arches, download_mb_for_this_host).  Cached for a day."""
    key = "mani:" + image
    hit = cache_get(key, 86400)
    if hit:
        return hit.get("arches") or list(fallback_arches or []), hit.get("dl_mb") or 0

    arches, dl_mb = [], 0
    rc, out, _ = run(["docker", "manifest", "inspect", "--verbose", image], timeout=60)
    if rc == 0 and out.strip():
        try:
            data = json.loads(out)
            if isinstance(data, dict):
                data = [data]
            host_arch = host_info().get("arch")
            for item in data:
                plat = ((item.get("Descriptor") or {}).get("platform") or {})
                arch = plat.get("architecture")
                if not arch or arch == "unknown" or plat.get("os") not in (None, "linux"):
                    continue
                if arch not in arches:
                    arches.append(arch)
                if arch == host_arch:
                    man = item.get("SchemaV2Manifest") or item.get("OCIManifest") or {}
                    layers = man.get("layers") or []
                    tot = sum(int(l.get("size") or 0) for l in layers)
                    if tot:
                        dl_mb = tot // (1024 * 1024)
        except Exception:
            pass

    if not arches:
        arches = list(fallback_arches or [])
    cache_put(key, {"arches": arches, "dl_mb": dl_mb})
    return arches, dl_mb


def tz_name():
    try:
        p = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in p:
            return p.split("/zoneinfo/", 1)[1]
    except Exception:
        pass
    return os.environ.get("TZ") or "Etc/UTC"


def image_id(image):
    rc, out, _ = run(["docker", "image", "inspect", "-f", "{{.Id}}", image], timeout=30)
    return out.strip() if rc == 0 else ""
