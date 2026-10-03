"""
Selkies Forge engine - runner

docker run: arguments, screen modes, and a run that fixes the usual refusals.
"""

import os
import re
import shlex
import time
import uuid

from .host import tz_name
from .paths import CPREFIX, KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS, VERSION
from .ports import alloc_ports, release_port_reservation
from .util import clamp, run, slug


def container_name_for(entry, wanted=None):
    base = CPREFIX + slug(wanted or entry["id"])[:40]
    rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=30)
    taken = set(out.split())
    if base not in taken:
        return base
    for i in range(2, 100):
        cand = "%s-%d" % (base, i)
        if cand not in taken:
            return cand
    return "%s-%s" % (base, uuid.uuid4().hex[:5])


DISPLAY_MODES = ("auto", "fit", "fixed")
RES_RE = re.compile(r"^\s*(\d{3,5})\s*[xX\u00d7]\s*(\d{3,5})\s*$")


def display_for(entry, opts):
    """('fit', None) or ('fixed', (w, h)) for this launch.

    fit    the desktop follows your browser window (Selkies resizes the screen)
    fixed  the screen stays one size and Selkies scales it into the window;
           for window managers that cannot cope with the screen changing size
           under them, so nothing can ever end up below the bottom edge
    """
    if entry.get("profile") == "kasm":
        return "fit", None
    mode = str(opts.get("display") or "auto").lower()
    if mode not in DISPLAY_MODES:
        mode = "auto"
    if mode == "auto":
        mode = entry.get("display") or "fit"
    if mode != "fixed":
        return "fit", None
    m = RES_RE.match(str(opts.get("resolution") or ""))
    w, h = (int(m.group(1)), int(m.group(2))) if m else (1920, 1080)
    return "fixed", (int(clamp(w, 800, 3840)), int(clamp(h, 600, 2160)))


def parse_display_label(txt):
    """'fixed:1920x1080' -> ('fixed', '1920x1080'); 'fit' -> ('fit', None)."""
    txt = str(txt or "")
    if txt.startswith("fixed"):
        return "fixed", (txt.split(":", 1)[1] if ":" in txt else "1920x1080")
    return ("fit" if txt == "fit" else "auto"), None


def docker_run_args(entry, name, ports, plan, opts, image, host):
    prof = entry.get("profile", "selkies")
    args = ["docker", "run", "-d", "--name", name,
            "--hostname", slug(entry["family"])[:20] or "forge",
            # Off by default: a desktop should only start when you start it.
            # "unless-stopped" made every one of them come back whenever
            # Docker (or the machine) restarted.
            "--restart", "unless-stopped" if opts.get("autostart") else "no",
            "--shm-size", "%dm" % int(plan["shm_mb"]),
            "--label", "%s.entry=%s" % (LABEL, entry["id"]),
            "--label", "%s.title=%s" % (LABEL, entry["name"]),
            "--label", "%s.family=%s" % (LABEL, entry["family"]),
            "--label", "%s.glyph=%s" % (LABEL, entry["glyph"]),
            "--label", "%s.de=%s" % (LABEL, entry["de_label"]),
            "--label", "%s.profile=%s" % (LABEL, prof),
            "--label", "%s.version=%s" % (LABEL, VERSION),
            "--label", "%s.disk=%d" % (LABEL, int(plan["disk_mb"])),
            # Restart after a crash while the forge is watching (see watchdog.py).
            "--label", "%s.heal=%s" % (LABEL, "off" if opts.get("heal") is False else "on"),
            ]
    if plan.get("memory_mb"):
        args += ["--memory", "%dm" % int(plan["memory_mb"])]
        # Pin swap to the same value so a limited desktop can't swap the host out.
        args += ["--memory-swap", "%dm" % int(plan["memory_mb"])]
    if plan.get("cpus"):
        args += ["--cpus", "%s" % plan["cpus"]]

    vol = "%sconfig-%s" % (CPREFIX, slug(name))
    args += ["--label", "%s.volume=%s" % (LABEL, vol)]
    if host.get("quota_support") and plan.get("disk_mb"):
        args += ["--storage-opt", "size=%dM" % int(plan["disk_mb"])]
    args += ["-v", "%s:/config" % vol]

    if opts.get("gpu") and os.path.exists("/dev/dri"):
        args += ["--device", "/dev/dri"]
    if opts.get("seccomp_unconfined"):
        args += ["--security-opt", "seccomp=unconfined"]

    if prof == "kasm":
        args += ["-p", "%d:%d" % (ports[0], KASM_HTTPS),
                 "-e", "VNC_PW=%s" % opts.get("password", "forge"),
                 "-e", "TZ=%s" % tz_name()]
    else:
        args += ["-p", "%d:%d" % (ports[0], SELKIES_HTTP),
                 "-p", "%d:%d" % (ports[1], SELKIES_HTTPS),
                 "-e", "PUID=%d" % os.getuid(),
                 "-e", "PGID=%d" % os.getgid(),
                 "-e", "TZ=%s" % tz_name(),
                 "-e", "TITLE=%s" % entry["name"]]
        mode, res = display_for(entry, opts)
        args += ["--label", "%s.display=%s" % (LABEL, "fixed:%dx%d" % res if res else "fit")]
        if res:
            args += ["-e", "SELKIES_MANUAL_WIDTH=%d" % res[0],
                     "-e", "SELKIES_MANUAL_HEIGHT=%d" % res[1]]
        else:
            # Xvfb's default virtual screen is 15360x8640: a full-screen
            # wallpaper alone is half a gigabyte, enough to get a 1 GB desktop
            # OOM-killed. 4K is the largest window anyone will stream.
            args += ["-e", "MAX_RES=3840x2160"]
        if opts.get("username") and opts.get("password"):
            args += ["-e", "CUSTOM_USER=%s" % opts["username"],
                     "-e", "PASSWORD=%s" % opts["password"]]
        if opts.get("locale"):
            args += ["-e", "LC_ALL=%s" % opts["locale"]]
    for kv in opts.get("env", []) or []:
        args += ["-e", kv]
    args.append(image)
    return args, vol


RUN_PORT_ERR = re.compile(r"port is already allocated|address already in use|bind for", re.I)
RUN_NAME_ERR = re.compile(r"is already in use by container|Conflict\. The container name", re.I)
RUN_QUOTA_ERR = re.compile(r"storage-opt|--storage-opt|quota", re.I)
RUN_CPU_ERR = re.compile(r"range of CPUs is from", re.I)


def docker_run_resilient(entry, cname, plan, opts, image, host, job, want_ports=None):
    """docker run, fixing the usual reasons it refuses: ports, names, quotas."""
    nports = 1 if entry["profile"] == "kasm" else 2
    ports = alloc_ports(nports, want=want_ports)
    host = dict(host)
    for attempt in range(5):
        job.check()
        args, vol = docker_run_args(entry, cname, ports, plan, opts, image, host)
        job.log("$ " + " ".join(shlex.quote(a) for a in args))
        rc, out, err = run(args, timeout=180)
        if rc == 0:
            return cname, ports, vol, out.strip()
        msg = (err.strip() or out.strip())
        job.log("docker run refused: %s" % msg.splitlines()[-1] if msg else "docker run refused",
                "err")
        run(["docker", "rm", "-f", cname], timeout=60)
        if RUN_PORT_ERR.search(msg):
            release_port_reservation(ports)
            ports = alloc_ports(nports)
            job.log("auto-fix  : that port was taken, moving to %s"
                    % ", ".join(str(p) for p in ports))
        elif RUN_NAME_ERR.search(msg):
            cname = container_name_for(entry, cname + "-%d" % (attempt + 2))
            job.log("auto-fix  : that name was taken, using %s" % cname)
        elif RUN_QUOTA_ERR.search(msg) and host.get("quota_support"):
            host["quota_support"] = False
            job.log("auto-fix  : this storage driver refused a disk quota; tracking the "
                    "budget instead of enforcing it")
        elif RUN_CPU_ERR.search(msg):
            plan["cpus"] = float(max(1, host.get("cpus", 1)))
            job.log("auto-fix  : capping CPUs at %s" % plan["cpus"])
        elif "no such image" in msg.lower() or "unable to find image" in msg.lower():
            raise RuntimeError("docker run failed: %s" % msg)
        elif attempt < 2:
            job.log("auto-fix  : retrying in a moment")
            time.sleep(3 + attempt * 3)
        else:
            release_port_reservation(ports)
            raise RuntimeError("docker run failed: %s" % msg)
    release_port_reservation(ports)
    raise RuntimeError("docker run kept failing; see the log above")
