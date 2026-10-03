"""
Selkies Forge engine - cli

The engine's command line (what selkies-cli calls under the hood).
"""

import argparse
import json
import sys
import threading
import time

from . import backups, catalog, events, scheduler, space
from .watchdog import Watchdog, reconcile, recover_interrupted
from .doctor import cli_doctor
from .health import container_logs
from .host import host_info
from .info import public_entry
from .jobs import Job, all_jobs, job_put
from .launch import launch
from .lifecycle import instance_action, reconfigure, set_idle
from .paths import VERSION
from .recipes import gen_dockerfile
from .registry import docker_instances
from .server import serve
from .smart import PURPOSE_TAGS, TASTES, plan_resources, recommend
from .stats import STATS
from .updates import check_update
from .util import ensure_dirs, human
from .webui import (
    boot_disable,
    boot_enable,
    boot_mark_asked,
    boot_report,
    dismiss_last_stop,
    forge_status,
    last_stop_report,
    request_stop,
)


def cli_launch_stream(args):
    """Launch with line-oriented output the shell front end can render."""
    entry = catalog.BY_ID.get(args.id)
    if not entry:
        print("E unknown catalog id: %s" % args.id)
        return 2
    host = host_info(fresh=True)
    plan = plan_resources(entry, host)
    if args.memory:
        plan["memory_mb"] = int(args.memory)
    if args.cpus:
        plan["cpus"] = float(args.cpus)
    if args.shm:
        plan["shm_mb"] = int(args.shm)
    if args.disk:
        plan["disk_mb"] = int(args.disk)
    opts = {"tunnel": not args.no_tunnel, "name": args.name, "autostart": args.autostart,
            "gpu": args.gpu, "seccomp_unconfined": args.seccomp,
            "display": args.display, "resolution": args.resolution,
            "health_timeout": args.timeout, "force": args.force,
            "dry_run": args.dry_run}
    if args.idle_stop is not None:
        opts["idle_stop"] = args.idle_stop
    if args.user and args.password:
        opts["username"], opts["password"] = args.user, args.password
    if args.subdomain:
        opts["subdomain"] = args.subdomain

    job = job_put(Job("launch", args.id, entry["name"]))
    return stream_job(job, lambda: launch(args.id, plan, opts, job=job, name=args.name))


def stream_job(job, work_fn):
    """Run work_fn in a thread and print the job's events as lines the shell
    front end renders: P progress, L log, E error, H hint, D result JSON.
    Ctrl-C (or SIGINT from the web UI's cancel) cancels the job properly."""
    done = {"result": None, "error": None}

    def work():
        try:
            done["result"] = work_fn()
        except Exception as ex:
            done["error"] = str(ex)
            if job.status == "running":
                job.fail(str(ex))

    th = threading.Thread(target=work, daemon=True)
    th.start()

    cursor = 0
    print("P 0 start Preparing")
    sys.stdout.flush()
    interrupted = False
    while True:
        try:
            evs = job.since(cursor, timeout=2.0)
        except KeyboardInterrupt:
            # Ctrl-C cancels the launch properly: kill the pull/build, remove
            # the half-made desktop, then report like any other ending.
            if interrupted:
                raise
            interrupted = True
            job.cancel()
            continue
        for ev in evs:
            cursor = ev["seq"]
            typ, data = ev["type"], ev["data"]
            if typ == "log":
                print("L %s" % data["line"][:400])
            elif typ == "phase":
                print("P %d %s %s" % (int(data["progress"] * 100), data["phase"],
                                      data["label"]))
            elif typ == "progress":
                extra = data.get("extra") or {}
                note = ""
                if extra.get("bytes_total"):
                    note = " %s/%s" % (human(extra["bytes"]), human(extra["bytes_total"]))
                elif extra.get("packages_total"):
                    note = " %s/%s pkgs" % (extra["packages"], extra["packages_total"])
                elif extra.get("bytes"):
                    note = " %s" % human(extra["bytes"])
                print("P %d %s %s%s" % (int(data["progress"] * 100), data["phase"],
                                        data["phase"], note))
            elif typ == "error":
                print("E %s" % data["message"].replace("\n", " | "))
                for h in data.get("hints", []):
                    print("H %s" % h)
            elif typ == "done":
                print("D %s" % json.dumps(data))
        sys.stdout.flush()
        if job.status != "running" and not job.since(cursor, timeout=0.05):
            break
    th.join(timeout=30)
    return 0 if done["result"] else (130 if job.cancelled else 1)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="forge-engine", description="Selkies Forge engine")
    ap.add_argument("--version", action="version", version=VERSION)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve")
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--tunnel", action="store_true")
    p.add_argument("--quiet", action="store_true")

    sub.add_parser("host")
    sub.add_parser("status")
    p = sub.add_parser("boot")
    p.add_argument("action", choices=["status", "enable", "disable", "asked"])
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--expose", action="store_true")
    p.add_argument("--no-linger", action="store_true")
    p = sub.add_parser("stop-request")
    p.add_argument("reason")
    sub.add_parser("last-stop")
    sub.add_parser("dismiss-last-stop")
    p = sub.add_parser("restore")
    p.add_argument("names", nargs="*")
    p = sub.add_parser("check-update")
    p.add_argument("--install", action="store_true")
    p.add_argument("--max-age", type=int, default=0)
    sub.add_parser("doctor")
    sub.add_parser("instances")
    sub.add_parser("stats")

    p = sub.add_parser("list")
    p.add_argument("--quick", action="store_true")
    p.add_argument("--runnable", action="store_true")
    p.add_argument("--family")
    p.add_argument("--kind")
    p.add_argument("--format", default="json", choices=["json", "tsv"])

    p = sub.add_parser("info")
    p.add_argument("id")

    p = sub.add_parser("dockerfile")
    p.add_argument("id")

    p = sub.add_parser("smart")
    p.add_argument("--taste", default="balanced", choices=sorted(TASTES))
    p.add_argument("--purpose", default="general", choices=sorted(PURPOSE_TAGS))
    p.add_argument("--family")
    p.add_argument("--max-dl", type=int, dest="max_dl")
    p.add_argument("--no-build", action="store_true")
    p.add_argument("--limit", type=int, default=3)

    p = sub.add_parser("launch")
    p.add_argument("id")
    p.add_argument("--name")
    p.add_argument("--memory", type=int)
    p.add_argument("--cpus", type=float)
    p.add_argument("--shm", type=int)
    p.add_argument("--disk", type=int)
    p.add_argument("--no-tunnel", action="store_true")
    p.add_argument("--subdomain")
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--gpu", action="store_true")
    p.add_argument("--seccomp", action="store_true")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--autostart", action="store_true",
                   help="start this desktop again whenever Docker starts")
    p.add_argument("--force", action="store_true",
                   help="start even if the machine looks short of memory")
    p.add_argument("--display", default="auto", choices=["auto", "fit", "fixed"],
                   help="fit: follow the browser window (4K screens are scaled "
                        "from a ~1920-wide desktop); fixed: one size, scaled")
    p.add_argument("--resolution", default="1920x1080", help="size for --display fixed")
    p.add_argument("--dry-run", action="store_true",
                   help="check everything and show what would happen, without doing it")
    p.add_argument("--idle-stop", type=int, metavar="MIN",
                   help="stop it after MIN minutes with nobody watching (0: never)")

    p = sub.add_parser("jobs", help="every launch, backup and clone on this machine")
    p.add_argument("--json", action="store_true")
    sub.add_parser("recover", help="clean up after launches whose process died")

    p = sub.add_parser("idle", help="stop a desktop after MIN minutes unwatched")
    p.add_argument("name")
    p.add_argument("minutes", help="minutes, 0 for never, or default")

    p = sub.add_parser("backup", help="back up a desktop's files")
    p.add_argument("name")
    p.add_argument("--with-cache", action="store_true", help="include ~/.cache too")
    p = sub.add_parser("backups", help="list backups")
    p.add_argument("--name")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("restore-backup", help="replace a desktop's files with a backup's")
    p.add_argument("name")
    p.add_argument("file")
    p = sub.add_parser("delete-backup")
    p.add_argument("file")
    p = sub.add_parser("clone", help="a new desktop with a copy of another's files")
    p.add_argument("name", nargs="?")
    p.add_argument("--as", dest="new_name", help="name for the new desktop")
    p.add_argument("--from-backup", metavar="FILE", help="start it from a backup instead")
    p.add_argument("--tunnel", action="store_true", help="also open a public link")

    p = sub.add_parser("do")
    p.add_argument("name")
    p.add_argument("action", choices=["start", "stop", "restart", "remove",
                                      "tunnel", "untunnel", "repair"])
    p.add_argument("--purge", action="store_true")
    p.add_argument("--subdomain")

    p = sub.add_parser("retune")
    p.add_argument("name")
    p.add_argument("--memory", type=int)
    p.add_argument("--cpus", type=float)
    p.add_argument("--shm", type=int)
    p.add_argument("--disk", type=int)
    p.add_argument("--autostart", choices=["on", "off"])

    p = sub.add_parser("events", help="the event journal (crashes, heals, repairs, launches)")
    p.add_argument("--name")
    p.add_argument("--limit", type=int, default=40)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("space", help="what the forge uses on disk; --clean to free it")
    p.add_argument("--clean", action="store_true")
    p.add_argument("--all", action="store_true", help="also unused desktop images and build cache")
    p.add_argument("--volumes", action="store_true", help="also orphaned /config volumes")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("watchdog", help="watch desktops: crashes, healing, session health")
    p.add_argument("--once", action="store_true", help="one pass, print what it found")
    sub.add_parser("reconcile", help="drop records of desktops that no longer exist")
    sub.add_parser("scheduler", help="build/pull/boot slots in use")

    p = sub.add_parser("logs")
    p.add_argument("name")
    p.add_argument("--tail", type=int, default=200)

    a = ap.parse_args(argv)
    ensure_dirs()

    if a.cmd == "serve":
        serve(a.bind, a.port, a.tunnel, a.quiet)
        return 0
    if a.cmd == "check-update":
        print(json.dumps(check_update(install=a.install, max_age=a.max_age, timeout=12)))
        return 0
    if a.cmd == "status":
        print(json.dumps(forge_status()))
        return 0
    if a.cmd == "boot":
        try:
            if a.action == "enable":
                out = boot_enable(a.port, a.bind, a.expose, try_linger=not a.no_linger)
            elif a.action == "disable":
                out = boot_disable()
            elif a.action == "asked":
                out = boot_mark_asked()
            else:
                out = boot_report()
        except Exception as ex:
            out = {"ok": False, "error": str(ex)}
        print(json.dumps(out))
        return 0 if out.get("ok", True) else 1
    if a.cmd == "stop-request":
        print(json.dumps(request_stop(a.reason)))
        return 0
    if a.cmd == "last-stop":
        print(json.dumps(last_stop_report()))
        return 0
    if a.cmd == "dismiss-last-stop":
        print(json.dumps(dismiss_last_stop()))
        return 0
    if a.cmd == "restore":
        names = a.names or (last_stop_report() or {}).get("restore") or []
        done = []
        for n in names:
            try:
                instance_action(n, "start")
                done.append(n)
            except Exception as ex:
                print(json.dumps({"name": n, "error": str(ex)}), file=sys.stderr)
        dismiss_last_stop()
        print(json.dumps({"started": done}))
        return 0
    if a.cmd == "host":
        print(json.dumps(host_info(fresh=True), indent=2))
        return 0
    if a.cmd == "doctor":
        print(json.dumps(cli_doctor(), indent=2))
        return 0
    if a.cmd == "instances":
        print(json.dumps({"instances": docker_instances()}, indent=2))
        return 0
    if a.cmd == "stats":
        STATS.sample_once()
        time.sleep(1.2)
        STATS.sample_once()
        print(json.dumps({"stats": STATS.report()}, indent=2))
        return 0
    if a.cmd == "list":
        host = host_info()
        items = [public_entry(e) for e in catalog.CATALOG]
        if a.quick:
            order = {k: i for i, k in enumerate(catalog.QUICK_PICKS)}
            items = sorted([i for i in items if i["id"] in order],
                           key=lambda i: order[i["id"]])
        if a.runnable:
            items = [i for i in items if host["arch"] in i["arches"]]
        if a.family:
            items = [i for i in items if i["family"] == a.family]
        if a.kind:
            items = [i for i in items if i["kind"] == a.kind]
        if a.format == "json":
            print(json.dumps({"entries": items, "host": host}))
        else:
            for i in items:
                print("\t".join([i["id"], i["name"], i["family_label"], i["de_label"],
                                 i["kind"], i["weight"], str(i["dl_mb"]),
                                 str(i["ram_rec"]), str(i["cpu_rec"]), str(i["beauty"]),
                                 i["subtitle"], i["desc"]]))
        return 0
    if a.cmd == "info":
        e = catalog.BY_ID.get(a.id)
        if not e:
            print(json.dumps({"error": "unknown id"}))
            return 2
        out = public_entry(e)
        out["plan"] = plan_resources(e, host_info())
        print(json.dumps(out, indent=2))
        return 0
    if a.cmd == "dockerfile":
        e = catalog.BY_ID.get(a.id)
        if not e or e["kind"] != "build":
            print("# nothing to build for %s" % a.id)
            return 2
        print(gen_dockerfile(e))
        return 0
    if a.cmd == "smart":
        prefs = {"taste": a.taste, "purpose": a.purpose,
                 "allow_build": not a.no_build}
        if a.family:
            prefs["family"] = a.family
        if a.max_dl:
            prefs["max_dl_mb"] = a.max_dl
        print(json.dumps(recommend(prefs, limit=a.limit), indent=2))
        return 0
    if a.cmd == "launch":
        return cli_launch_stream(a)
    if a.cmd == "jobs":
        rows = all_jobs()
        if a.json:
            print(json.dumps({"jobs": rows}))
        else:
            for j in rows:
                print("%s  %-8s %-12s %-11s %3d%%  %s" % (
                    time.strftime("%m-%d %H:%M", time.localtime(j.get("created") or 0)),
                    j.get("kind", ""), j.get("status", ""), (j.get("phase") or "")[:11],
                    int((j.get("progress") or 0) * 100), j.get("title") or ""))
        return 0
    if a.cmd == "recover":
        print(json.dumps({"recovered": recover_interrupted()}))
        return 0
    if a.cmd == "idle":
        mins = None if a.minutes == "default" else int(a.minutes)
        try:
            print(json.dumps(set_idle(a.name, mins)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "backup":
        job = job_put(Job("backup", a.name, "Back up %s" % a.name))
        return stream_job(job, lambda: backups.backup(a.name, include_cache=a.with_cache, job=job))
    if a.cmd == "backups":
        rows = backups.list_backups(a.name)
        if a.json:
            print(json.dumps({"backups": rows}))
        else:
            for b in rows:
                print("%s  %-26s %9s  %s" % (
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(b.get("created") or 0)),
                    (b.get("name") or "")[:26], human(b.get("size") or 0), b.get("file")))
        return 0
    if a.cmd == "restore-backup":
        job = job_put(Job("restore", a.name, "Restore %s" % a.name))
        return stream_job(job, lambda: backups.restore(a.name, a.file, job=job))
    if a.cmd == "delete-backup":
        try:
            print(json.dumps(backups.delete_backup(a.file)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "clone":
        if not a.name and not a.from_backup:
            print("E name a desktop to clone, or --from-backup FILE")
            return 2
        job = job_put(Job("clone", a.name, "Clone %s" % (a.name or a.from_backup)))
        return stream_job(job, lambda: backups.clone(a.name, new_name=a.new_name, job=job,
                                                     tunnel=a.tunnel, from_backup=a.from_backup))
    if a.cmd == "do":
        try:
            print(json.dumps(instance_action(a.name, a.action,
                                             {"purge": a.purge, "subdomain": a.subdomain})))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "retune":
        try:
            auto = None if a.autostart is None else (a.autostart == "on")
            print(json.dumps(reconfigure(a.name, a.memory, a.cpus, a.shm, a.disk, auto)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "events":
        rows = events.recent(a.name, limit=a.limit)
        if a.json:
            print(json.dumps({"events": rows}))
        else:
            for r in rows:
                print("%s  %-26s %-16s %s" % (time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"])),
                                               r.get("name", "")[:26], r.get("event", ""),
                                               (r.get("detail") or "").replace("\n", " ")[:90]))
        return 0
    if a.cmd == "space":
        if a.clean:
            print(json.dumps(space.clean(everything=a.all, volumes=a.volumes, dry_run=a.dry_run)))
        else:
            print(json.dumps(space.report()))
        return 0
    if a.cmd == "watchdog":
        if a.once:
            wd = Watchdog()
            wd.tick()
            time.sleep(1)
            print(json.dumps(wd.tick()))
            return 0
        wd = Watchdog()
        try:
            while True:
                rep = wd.tick()
                if any(rep.get(k) for k in ("crashed", "healed", "rescue")):
                    print(json.dumps(rep))
                    sys.stdout.flush()
                time.sleep(wd.interval)
        except KeyboardInterrupt:
            return 0
    if a.cmd == "reconcile":
        print(json.dumps(reconcile()))
        return 0
    if a.cmd == "scheduler":
        print(json.dumps(scheduler.status()))
        return 0
    if a.cmd == "logs":
        print(container_logs(a.name, a.tail))
        return 0
    return 1
