"""
Selkies Forge engine - launch

The launch pipeline: resolve, fetch, layer, start, verify, tunnel.
"""

import time

from . import catalog
from .health import LaunchProblem, mem_pressure, pick_fix, wait_http, wait_session
from .host import docker_ok, host_info, image_present, manifest_probe
from .images import ensure_layer, get_image
from .info import public_entry
from . import events
from .jobs import Job, JobCancelled, job_put
from .paths import VERSION
from .ports import release_port_reservation
from .recipes import build_image_tag
from .registry import docker_instances
from .runner import container_name_for, display_for, docker_run_resilient
from .scheduler import slot
from .smart import plan_resources
from .store import reg_delete, reg_update
from .tunnels import tunnel_start
from .util import human_mb, run
from .webui import running_desktop_names


def launch(entry_id, plan=None, opts=None, job=None, name=None):
    """Pull or build, layer, run, verify the session, tunnel.

    Every stage that can fail for an ordinary reason (a flaky network, a port
    someone grabbed, a desktop that needs more memory or a looser syscall
    filter) is retried with a fix applied, and each fix is written to the log.

    Heavy stages wait for a scheduler slot (one build, two pulls, two boots at
    a time by default), the job can be cancelled at any point (whatever is
    running is killed and a half-made desktop is removed), and everything that
    happens is written to the event journal.
    """
    opts = dict(opts or {})
    entry = catalog.BY_ID.get(entry_id)
    if not entry:
        raise RuntimeError("unknown catalog id: %s" % entry_id)
    job = job or job_put(Job("launch", entry_id, entry["name"]))
    host = host_info(fresh=True)
    plan = dict(plan or plan_resources(entry, host))
    reserved = []
    cname = None

    try:
        # ---- 1. check this machine can run it ---------------------------
        job.set_phase("resolve", "Checking %s against this machine" % entry["name"], 0.01)
        job.log("forge %s  |  %s" % (VERSION, entry["name"]))
        job.log("host     : %s, %d cores, %s RAM free, %s disk free"
                % (host["arch"], host["cpus"], human_mb(host["mem_avail_mb"]),
                   human_mb(host["disk_free_mb"])))
        mode, res = display_for(entry, opts)
        job.log("plan     : %s RAM, %s CPU, %s shm, screen %s"
                % (human_mb(plan["memory_mb"]), plan["cpus"], human_mb(plan["shm_mb"]),
                   "fixed %dx%d, scaled to your window" % res if res
                   else "follows your browser window"))

        ok, derr = docker_ok()
        if not ok:
            raise RuntimeError("docker is not answering: %s" % derr)

        admit_memory(entry, plan, host, job, opts)

        need = 3 * 1024 if image_present(entry.get("image") or build_image_tag(entry)) \
            else int(entry["disk_mb"] * 1.3) + 1024
        if host.get("disk_free_mb") and host["disk_free_mb"] < need:
            raise RuntimeError("only %s of disk is free and this needs about %s; "
                               "free some space (docker system prune) and try again"
                               % (human_mb(host["disk_free_mb"]), human_mb(need)))

        probe_image = entry["image"] if entry["kind"] == "pull" else entry["recipe"]["image"]
        job.log("image    : %s" % probe_image)
        arches, real_dl = manifest_probe(probe_image, entry["arches"])
        if arches and host["arch"] not in arches:
            alts = [c["name"] for c in catalog.CATALOG
                    if host["arch"] in c["arches"] and c["de"] == entry["de"]][:3]
            raise RuntimeError(
                "%s has no %s build (it publishes: %s). Try: %s"
                % (probe_image, host["arch"], ", ".join(arches) or "nothing",
                   ", ".join(alts) or "another desktop"))
        if real_dl:
            job.log("download : about %s for %s" % (human_mb(real_dl), host["arch"]))

        if not host["quota_support"] and plan.get("disk_mb"):
            job.log("note     : %s on %s cannot enforce a hard disk cap, so the %s "
                    "limit is tracked, not enforced"
                    % (host.get("storage_driver"), host.get("backing_fs"),
                       human_mb(plan["disk_mb"])))

        # ---- 2. get the image, then the forge layer on top ----------------
        job.check()
        image = get_image(entry, host, job, opts)
        job.check()
        job.set_phase("layer", "Adding the forge layer", 0.80)
        run_image = ensure_layer(entry, image, job)
        job.check()

        # ---- 3 + 4. start it and make sure the desktop really came up -----
        tried = set()
        session = {}
        warning = None
        attempt = 0
        boot = slot("boot", job)
        boot.__enter__()
        while True:
            attempt += 1
            job.check()
            job.set_phase("create", "Starting the container" if attempt == 1
                          else "Starting it again (try %d)" % attempt, 0.84)
            if not cname:
                cname = container_name_for(entry, name or opts.get("name"))
            cname, reserved, vol, cid = docker_run_resilient(
                entry, cname, plan, opts, run_image, host, job,
                want_ports=reserved or opts.get("ports"))
            job.log("container: %s (%s)" % (cname, cid[:12]))
            events.record(cname, "create", "%s (try %d)" % (entry["name"], attempt),
                          entry=entry["id"], image=run_image)
            reg_update(cname, {"entry_id": entry["id"], "created": time.time(),
                               "plan": plan, "opts": {k: v for k, v in opts.items()
                                                      if k != "password"},
                               "volume": vol, "image": run_image,
                               "ports": reserved, "tunnel": None})
            try:
                job.set_phase("health", "Waiting for the desktop to come up", 0.88)
                heavy = entry.get("weight") in ("full", "heavy")
                wait_http(cname, reserved[0], entry["profile"], job,
                          timeout=int(opts.get("health_timeout", 420 if heavy else 300)))
                job.log("web      : answering on port %d" % reserved[0])
                job.set_phase("session", "Waiting for the desktop session", 0.92)
                session = wait_session(cname, entry, job, timeout=240 if heavy else 150)
                break
            except LaunchProblem as lp:
                job.log("problem  : %s" % lp, "err")
                for ln in (lp.detail or "").strip().splitlines()[-12:]:
                    job.log("  | " + ln, "err")
                if lp.kind in ("crash", "nowm") and "memory" not in tried and \
                        mem_pressure(cname) > 88:
                    lp.kind = "oom"          # it is starving, not broken
                fix = pick_fix(lp, plan, opts, host, tried) if attempt < 4 else None
                if not fix:
                    if lp.kind in ("crash", "nowm"):
                        # Leave it running: the rescue session shows the log in
                        # the desktop itself, which beats a dead container.
                        warning = (("The desktop session crashed on start, so it opened a "
                                    "rescue session that shows why. " if lp.kind == "crash" else
                                    "The desktop did not come up properly. ") + str(lp))
                        session = {"mode": "rescue" if lp.kind == "crash" else "nowm",
                                   "log": (lp.detail or "")[-1500:]}
                        break
                    raise RuntimeError("%s\n%s" % (lp, "\n".join(
                        (lp.detail or "").strip().splitlines()[-15:])))
                desc, key, apply = fix
                tried.add(key)
                apply()
                job.log("auto-fix : %s" % desc)
                events.record(cname, "recreate", "auto-fix: " + desc)
                run(["docker", "rm", "-f", cname], timeout=120)
                release_port_reservation(reserved)

        boot.__exit__(None, None, None)
        boot = None
        if session.get("wm"):
            job.log("session  : %s is running (%s, %s window%s)"
                    % (session["wm"], session.get("screen", "?"), session.get("clients", 0),
                       "" if session.get("clients") == 1 else "s"))
        elif int(session.get("clients") or 0) > 0:
            job.log("session  : up (%s window%s on screen)"
                    % (session["clients"], "" if session["clients"] == 1 else "s"))
        elif session.get("slow"):
            warning = warning or ("The web page is up but the desktop session had not "
                                  "reported in yet. Give it a minute, then reload.")
            job.log("session  : still starting, the page will catch up", "err")
        if tried:
            job.log("fixed    : %s" % ", ".join(sorted(tried)))

        # ---- 5. tunnel --------------------------------------------------
        job.check()
        tun = None
        if opts.get("tunnel", True):
            tmode = "tcp" if entry["profile"] == "kasm" else "http"
            job.set_phase("tunnel", "Opening a serveo tunnel (%s)" % tmode, 0.96)
            try:
                tun = tunnel_start(cname, reserved[0], mode=tmode,
                                   subdomain=opts.get("subdomain"))
                job.log("tunnel   : %s" % tun["url"])
                if tmode == "tcp":
                    job.log("note     : anonymous serveo TCP tunnels are capped "
                            "(~10 min, 2 connections). The local link has no limits.")
            except Exception as ex:
                job.log("tunnel failed: %s" % ex, "err")
                job.log("the desktop is still fine on its local address", "err")
        else:
            job.log("tunnel   : skipped")

        release_port_reservation(reserved)
        inst = next((i for i in docker_instances() if i["name"] == cname), None)
        result = {"name": cname, "entry_id": entry["id"], "entry": public_entry(entry),
                  "ports": reserved, "image": run_image, "plan": plan,
                  "local_url": "http://localhost:%d" % reserved[0]
                  if entry["profile"] != "kasm" else "https://localhost:%d" % reserved[0],
                  "https_url": "https://localhost:%d" % reserved[1]
                  if entry["profile"] != "kasm" else None,
                  "tunnel": tun, "instance": inst,
                  "session": session, "warning": warning, "fixes": sorted(tried),
                  "display": "fixed %dx%d" % res if res else "fit",
                  "credentials": ({"user": "kasm_user",
                                   "password": opts.get("password", "forge")}
                                  if entry["profile"] == "kasm" else
                                  ({"user": opts["username"], "password": opts["password"]}
                                   if opts.get("username") else None)),
                  "quota_enforced": bool(host.get("quota_support")),
                  }
        events.record(cname, "ready", warning or (session.get("wm") or "up"),
                      fixes=sorted(tried) or None)
        job.set_phase("ready", "Ready", 1.0)
        job.finish(result)
        return result

    except Exception as ex:
        if "boot" in locals() and boot is not None:
            boot.__exit__(None, None, None)
        release_port_reservation(reserved)
        if isinstance(ex, JobCancelled) or job.cancelled:
            # A desktop that never finished starting is of no use to anyone.
            if cname:
                run(["docker", "rm", "-f", cname], timeout=120)
                run(["docker", "volume", "rm", "-f", "forge-config-%s" % cname], timeout=60)
                reg_delete(cname)
                events.record(cname, "launch-cancelled", "cancelled during %s" % job.phase)
            job.fail("cancelled during %s; nothing was left behind" % job.phase)
            raise JobCancelled("cancelled")
        if cname:
            events.record(cname, "launch-failed", str(ex)[:500])
        job.fail(str(ex), hints=_hints_for(str(ex)))
        raise


def admit_memory(entry, plan, host, job, opts):
    """Refuse to start a desktop the machine plainly cannot hold right now.

    A limit is a cap, not a reservation, so the plan can exceed what is free
    (the desktop just runs tighter). But below the desktop's floor it would
    thrash or be OOM-killed; say so up front and name what is using memory.
    """
    free = int(host.get("mem_avail_mb") or 0)
    floor = int(entry.get("ram_min") or 0)
    if not free or not floor:
        return
    running = running_desktop_names()
    if free < floor and not opts.get("force"):
        raise RuntimeError(
            "only %s of memory is free and %s needs at least %s to start. %s"
            "Stop a desktop, or pick a lighter one (or pass force to try anyway)."
            % (human_mb(free), entry["name"], human_mb(floor),
               ("Running now: %s. " % ", ".join(n.replace("forge-", "", 1) for n in running))
               if running else ""))
    if free < plan.get("memory_mb", 0):
        job.log("note     : the %s memory cap is more than the %s free right now; it will "
                "work, but may get slow if it uses it all" % (human_mb(plan["memory_mb"]),
                                                              human_mb(free)))


def _hints_for(msg):
    m = msg.lower()
    hints = []
    if "permission denied" in m and "docker" in m:
        hints.append("your user is not in the docker group yet: "
                     "run `sudo usermod -aG docker $USER`, then log out and back in")
    if "no space left" in m or "disk is free" in m:
        hints.append("free some disk, or run `docker system prune -af` to drop old images")
    if "no arm64" in m or "no amd64" in m or "has no" in m:
        hints.append("pick an entry whose badge lists your architecture")
    if "never answered" in m:
        hints.append("heavy desktops can take a few minutes on first boot; "
                     "try again with a longer timeout, or check `docker logs`")
    if "exit code 97" in m or "session binaries" in m:
        hints.append("that desktop's packages are not available on that base; "
                     "try the same desktop on another distro")
    if "tag is gone" in m or "manifest unknown" in m:
        hints.append("the publisher removed that image; pick another entry")
    if "network" in m or "timeout" in m or "tls" in m:
        hints.append("the network dropped out several times in a row; try again in a minute")
    if "serveo" in m:
        hints.append("serveo may be rate limiting; the local URL still works")
    return hints
