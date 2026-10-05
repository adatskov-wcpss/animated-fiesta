"""
Selkies Forge engine - server

The web UI's HTTP server and JSON/SSE API.
"""

import base64
import errno
import json
import os
import re
import signal
import sys
import threading
import time
import urllib.parse

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import addons, burrow, catalog, events, scheduler, space, updates
from .doctor import cli_doctor
from .health import container_logs
from .host import host_info
from .info import entry_info, public_entry, shots_index
from . import backups
from .jobs import Job, all_jobs, cancel_foreign, job_get, job_put, jobs_running, read_job_states
from .watchdog import PRESSURE, WATCHDOG, reconcile, recover_interrupted
from .launch import launch
from .lifecycle import instance_action, reconfigure, set_idle
from .paths import (
    WEBDIR,
    KASM_HTTPS,
    LABEL,
    LAST_STOP_JSON,
    LIFE_JSON,
    SELKIES_HTTP,
    SERVER_JSON,
    STOP_REQUEST_JSON,
    VERSION,
)
from .recipes import gen_dockerfile, gen_startwm
from .registry import docker_instances
from .smart import TASTE_BLURB, plan_resources, recommend
from .stats import STATS
from .terminal import term_get, term_open
from .tunnels import tunnel_start, tunnel_stop
from .updates import (
    _update_loop,
    check_update,
    installed_payload,
    restart_webui_detached,
    update_report,
)
from .util import _int_or_none, clamp, ensure_dirs, jload, jsave, run
from .webui import (
    analyze_life,
    boot_disable,
    boot_enable,
    boot_id,
    boot_report,
    dismiss_last_stop,
    host_going_down,
    last_stop_report,
    running_desktop_names,
)


MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml",
        ".json": "application/json", ".ico": "image/x-icon",
        ".png": "image/png", ".woff2": "font/woff2"}


class Handler(BaseHTTPRequestHandler):
    server_version = "SelkiesForge/" + VERSION
    protocol_version = "HTTP/1.1"
    loopback_only = True

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):
        if os.environ.get("FORGE_HTTP_LOG"):
            sys.stderr.write("[http] %s\n" % (fmt % args))

    LOOPBACK_HOSTS = ("localhost", "127.0.0.1", "[::1]", "::1")

    def _guard(self, post):
        """Refuse requests a web page on another site could forge.

        * Origin: browsers send it on cross-site requests; it must match the
          address the UI is served on.
        * POST bodies must be JSON: a cross-site page can only send JSON after
          a CORS preflight, which this server never approves.
        * Host: a UI listening on localhost only answers to localhost names,
          which stops DNS-rebinding pages from reading the API. A UI bound
          beyond localhost answers to any name and has no access control.
        Returns an error message, or None when the request is fine.
        """
        host = (self.headers.get("Host") or "").strip().lower()
        if host.startswith("["):
            hostname = host.split("]", 1)[0] + "]"
        else:
            hostname = host.rsplit(":", 1)[0] if ":" in host else host
        if self.loopback_only and hostname and hostname not in self.LOOPBACK_HOSTS:
            return "this web UI only answers on localhost"
        origin = self.headers.get("Origin")
        if origin is not None:
            netloc = urllib.parse.urlsplit(origin).netloc.lower() if origin != "null" else ""
            if netloc != host:
                return "cross-site request refused"
        if post:
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                return "POST requests must send Content-Type: application/json"
        return None

    def _query(self):
        if "?" not in self.path:
            return {}
        import urllib.parse as up
        return {k: v[0] for k, v in up.parse_qs(self.path.split("?", 1)[1]).items()}

    def _route(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if not n:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {"_raw": raw.decode("utf-8", "replace")}

    def _send(self, code, payload, ctype="application/json", extra=None):
        if ctype.startswith("application/json") and not isinstance(payload, (bytes, str)):
            payload = json.dumps(payload)
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _err(self, code, msg):
        self._send(code, {"error": str(msg)})

    def _sse_open(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _sse_send(self, data, event=None, eid=None):
        buf = []
        if event:
            buf.append("event: %s" % event)
        if eid is not None:
            buf.append("id: %s" % eid)
        buf.append("data: %s" % (data if isinstance(data, str) else json.dumps(data)))
        buf.append("")
        buf.append("")
        self.wfile.write("\n".join(buf).encode("utf-8"))
        self.wfile.flush()

    # -- verbs ------------------------------------------------------------
    def do_GET(self):
        route = self._route()
        if route in ("/", "/index.html"):
            return self._static("index.html")
        if route in ("/app.css", "/app.js", "/addons.js", "/term.js", "/logos.js", "/brands.js",
                     "/favicon.ico"):
            return self._static(route.lstrip("/"))
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        why = self._guard(post=False)
        if why:
            return self._err(403, why)
        try:
            return self._api_get(route)
        except Exception as ex:
            return self._err(500, ex)

    def do_POST(self):
        route = self._route()
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        why = self._guard(post=True)
        if why:
            return self._err(403, why)
        try:
            return self._api_post(route, self._body())
        except Exception as ex:
            return self._err(500, ex)

    static_cache = {}

    def _image(self, data, ctype):
        """An addon's logo or icon: never a page, and an SVG cannot run anything."""
        extra = {"Cache-Control": "public, max-age=86400",
                 "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox"}
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _static(self, name):
        data = self.static_cache.get(name)
        if data is None:
            path = os.path.join(WEBDIR, name)
            if not os.path.isfile(path):
                return self._err(404, "%s missing" % name)
            with open(path, "rb") as fh:
                data = fh.read()
        ext = os.path.splitext(name)[1]
        return self._send(200, data, MIME.get(ext, "application/octet-stream"))

    # -- API --------------------------------------------------------------
    def _api_get(self, route):
        if route == "/api/boot":
            host = host_info(fresh=True)
            return self._send(200, {
                "version": VERSION,
                "host": host,
                "catalog": [public_entry(e) for e in catalog.CATALOG],
                "families": sorted({e["family"] for e in catalog.CATALOG}),
                "family_labels": catalog.FAMILY_LABEL,
                "desktops": sorted({e["de_label"] for e in catalog.CATALOG}),
                "tastes": TASTE_BLURB,
                "quick_picks": catalog.QUICK_PICKS,
                "shots": shots_index(),
                "instances": docker_instances(),
                "counts": {"total": len(catalog.CATALOG),
                           "runnable": sum(1 for e in catalog.CATALOG
                                           if host["arch"] in e["arches"])},
            })
        if route == "/api/host":
            out = dict(host_info(fresh=True))
            out["pressure"] = dict(PRESSURE)
            return self._send(200, out)
        if route == "/api/gpu":
            from .gpu import report as gpu_report
            return self._send(200, gpu_report(fresh=True))
        if route == "/api/lifecycle":
            return self._send(200, {"last_stop": last_stop_report(), "boot": boot_report()})
        if route == "/api/update":
            return self._send(200, update_report())
        if route == "/api/doctor":
            return self._send(200, cli_doctor())
        if route == "/api/instances":
            return self._send(200, {"instances": docker_instances(), "burrow": burrow.status()})
        if route == "/api/burrow":
            return self._send(200, burrow.status(max_age=0))
        if route == "/api/bridge":
            return self._send(200, burrow.health(addons))
        if route == "/api/stats":
            return self._send(200, {"stats": STATS.report(), "host": host_info()})
        if route == "/api/jobs":
            # Every job on this machine: this web UI's, and selkies-cli's.
            return self._send(200, {"jobs": all_jobs()})
        m = re.match(r"^/api/job/([0-9a-f]+)$", route)
        if m:
            job = job_get(m.group(1))
            if job:
                return self._send(200, job.snapshot())
            st = next((j for j in read_job_states() if j.get("id") == m.group(1)), None)
            return self._send(200, dict(st, foreign=True)) if st else self._err(404, "no such job")
        if route == "/api/backups":
            return self._send(200, {"backups": backups.list_backups(self._query().get("name") or None)})
        m = re.match(r"^/api/job/([0-9a-f]+)/events$", route)
        if m:
            return self._stream_job(m.group(1))
        m = re.match(r"^/api/term/([0-9a-f]+)/stream$", route)
        if m:
            return self._stream_term(m.group(1))
        m = re.match(r"^/api/info/([A-Za-z0-9_.-]+)$", route)
        if m:
            e = catalog.BY_ID.get(m.group(1))
            if not e:
                return self._err(404, "no such entry")
            return self._send(200, entry_info(e))
        m = re.match(r"^/api/entry/([A-Za-z0-9_.-]+)$", route)
        if m:
            e = catalog.BY_ID.get(m.group(1))
            if not e:
                return self._err(404, "no such entry")
            out = public_entry(e)
            out["recipe"] = {k: v for k, v in (e.get("recipe") or {}).items()
                            if k in ("pkgs", "session", "pm", "image", "theme")}
            if e["kind"] == "build":
                out["dockerfile"] = gen_dockerfile(e)
                out["startwm"] = gen_startwm(e)
            out["plan"] = plan_resources(e, host_info())
            return self._send(200, out)
        m = re.match(r"^/api/logs/([A-Za-z0-9_.-]+)$", route)
        if m:
            tail = _int_or_none(self._query().get("tail")) or 200
            return self._send(200, {"logs": container_logs(m.group(1), min(2000, tail)),
                                    "events": events.recent(m.group(1), limit=40)})
        if route == "/api/events":
            q = self._query()
            return self._send(200, {"events": events.recent(q.get("name") or None,
                                                            limit=min(500, _int_or_none(q.get("limit")) or 100))})
        if route == "/api/space":
            return self._send(200, space.report())
        if route == "/api/addons":
            return self._send(200, {"addons": addons.list_addons(), "spec": addons.SPEC})
        if route == "/api/addons/scan":
            return self._send(200, addons.scan(max_age=0 if self._query().get("fresh") else 60))
        m = re.match(r"^/api/addons/([a-z0-9-]{2,40})/image$", route)
        if m:
            try:
                data, ctype = addons.image(m.group(1), self._query().get("path"))
            except (addons.AddonError, OSError) as ex:
                return self._err(404, ex)
            return self._image(data, ctype)
        m = re.match(r"^/api/addons/([a-z0-9-]{2,40})/check$", route)
        if m:
            try:
                return self._send(200, addons.check_updates(m.group(1)))
            except addons.AddonError as ex:
                return self._err(400, ex)
        m = re.match(r"^/api/addons/([a-z0-9-]{2,40})$", route)
        if m:
            try:
                return self._send(200, addons.public(addons.get(m.group(1)), with_status=True))
            except addons.AddonError as ex:
                return self._err(404, ex)
        if route == "/api/scheduler":
            return self._send(200, {"slots": scheduler.status(),
                                    "jobs": [j.snapshot() for j in jobs_running()]})
        return self._err(404, "no such endpoint")

    def _api_post(self, route, body):
        m = re.match(r"^/api/job/([0-9a-f]+)/cancel$", route)
        if m:
            job = job_get(m.group(1))
            if not job:
                # A launch running in a terminal: it cancels on SIGINT like Ctrl-C.
                return self._send(200, {"cancelled": cancel_foreign(m.group(1)), "foreign": True})
            return self._send(200, {"cancelled": job.cancel(), "job": job.snapshot()})
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/(backup|clone|idle)$", route)
        if m:
            name, what = m.group(1), m.group(2)
            if what == "idle":
                mins = body.get("minutes")
                return self._send(200, set_idle(name, None if mins in (None, "") else int(mins)))
            if what == "backup":
                job = job_put(Job("backup", name, "Back up %s" % name))
                return self._send(200, {"job": _run_job(job, backups.backup, name,
                                                        include_cache=bool(body.get("include_cache")),
                                                        job=job)})
            job = job_put(Job("clone", name, "Clone %s" % name))
            return self._send(200, {"job": _run_job(job, backups.clone, name,
                                                    new_name=body.get("name") or None,
                                                    tunnel=bool(body.get("tunnel")), job=job)})
        if route == "/api/backups/restore":
            name, file = body.get("name") or "", body.get("file") or ""
            job = job_put(Job("restore", name, "Restore %s" % name))
            return self._send(200, {"job": _run_job(job, backups.restore, name, file, job=job)})
        if route == "/api/backups/clone":
            job = job_put(Job("clone", None, "New desktop from %s" % body.get("file")))
            return self._send(200, {"job": _run_job(job, backups.clone, None,
                                                    new_name=body.get("name") or None,
                                                    from_backup=body.get("file") or "", job=job)})
        if route == "/api/backups/delete":
            return self._send(200, backups.delete_backup(body.get("file") or ""))
        if route == "/api/space/clean":
            return self._send(200, space.clean(everything=bool(body.get("all")),
                                               volumes=bool(body.get("volumes")),
                                               dry_run=bool(body.get("dry_run"))))
        if route in ("/api/burrow/publish", "/api/burrow/unpublish"):
            # Only desktops (by name), never an arbitrary port: whoever can
            # reach this API must not be able to publish, say, ssh.
            name = body.get("desktop") or ""
            inst = next((i for i in docker_instances() if i["name"] == name), None)
            if not inst:
                return self._err(404, "no such desktop")
            port = (inst.get("ports") or {}).get(str(KASM_HTTPS) if inst.get("profile") == "kasm" else str(SELKIES_HTTP))
            if not port:
                return self._err(400, "%s has no published port; start it first" % name)
            try:
                if route.endswith("/publish"):
                    t = burrow.publish(port, inst.get("title") or name,
                                       access="public" if body.get("access") == "public" else "login")
                    return self._send(200, {"tunnel": t, "burrow": burrow.status()})
                return self._send(200, dict(burrow.unpublish(port), burrow=burrow.status()))
            except RuntimeError as ex:
                return self._err(400, ex)
        m = re.match(r"^/api/addons/([a-z0-9-]{2,40})/share$", route)
        if m:
            try:
                return self._send(200, {"ways": addons.share(m.group(1), body.get("via"), on=body.get("on", True) is not False,
                                                              access="public" if body.get("access") == "public" else "login")})
            except addons.AddonError as ex:
                return self._err(400, ex)
        if route == "/api/addons/add":
            try:
                a = addons.add(body.get("source") or "")
                addons.forget_scan()
                return self._send(200, {"addon": a})
            except addons.AddonError as ex:
                return self._err(400, ex)
        m = re.match(r"^/api/addons/([a-z0-9-]{2,40})/(install|update|uninstall|remove|action)$", route)
        if m:
            aid, what = m.group(1), m.group(2)
            try:
                rec = addons.get(aid)
            except addons.AddonError as ex:
                return self._err(404, ex)
            name = rec["manifest"]["name"]
            if what == "remove":
                try:
                    return self._send(200, addons.remove(aid))
                except addons.AddonError as ex:
                    return self._err(400, ex)
            if what == "install":
                job = job_put(Job("addon", aid, "Install %s" % name))
                return self._send(200, {"job": _run_job(job, addons.install, aid,
                                                        settings=body.get("settings") or {}, job=job)})
            if what == "update":
                job = job_put(Job("addon", aid, "Update %s" % name))
                return self._send(200, {"job": _run_job(job, addons.update, aid, job=job)})
            if what == "uninstall":
                job = job_put(Job("addon", aid, "Uninstall %s" % name))
                return self._send(200, {"job": _run_job(job, addons.uninstall, aid,
                                                        keep_data=body.get("keep_data", True) is not False,
                                                        job=job)})
            act = str(body.get("action") or "")
            job = job_put(Job("addon", aid, "%s: %s" % (name, act)))
            return self._send(200, {"job": _run_job(job, addons.action, aid, act, job=job)})
        if route == "/api/update/check":
            check_update(install=True)
            return self._send(200, update_report())
        if route == "/api/update/restart":
            restart_webui_detached()
            return self._send(200, {"ok": True})
        if route == "/api/smart":
            prefs = {k: body.get(k) for k in
                     ("taste", "purpose", "family", "allow_build", "max_dl_mb", "want_tunnel")
                     if body.get(k) is not None}
            limit = int(body.get("limit") or 3)
            return self._send(200, recommend(prefs, limit=clamp(limit, 1, 12)))
        if route == "/api/launch":
            eid = body.get("id")
            if eid not in catalog.BY_ID:
                return self._err(400, "unknown catalog id")
            entry = catalog.BY_ID[eid]
            host = host_info(fresh=True)
            plan = plan_resources(entry, host)
            for k in ("memory_mb", "cpus", "shm_mb", "disk_mb"):
                if body.get("plan", {}).get(k):
                    plan[k] = body["plan"][k]
            plan["memory_mb"] = int(clamp(plan["memory_mb"], 256, max(256, host["mem_total_mb"])))
            plan["cpus"] = float(clamp(float(plan["cpus"]), 0.25, host["cpus"]))
            # /dev/shm is a ceiling, not a reservation: up to half the RAM.
            plan["shm_mb"] = int(clamp(plan["shm_mb"], 64, max(4096, host["mem_total_mb"] // 2)))
            opts = body.get("opts") or {}
            job = job_put(Job("launch", eid, entry["name"]))

            def work():
                try:
                    launch(eid, plan, opts, job=job, name=opts.get("name"))
                except Exception:
                    pass
            job.thread = threading.Thread(target=work, daemon=True)
            job.thread.start()
            return self._send(200, {"job": job.snapshot(), "plan": plan})
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/retune$", route)
        if m:
            return self._send(200, reconfigure(
                m.group(1), body.get("memory_mb"), body.get("cpus"), body.get("shm_mb"),
                body.get("disk_mb"), body.get("autostart"), body.get("display"),
                body.get("resolution")))
        if route == "/api/autostart-ui":
            srv = jload(SERVER_JSON, {}) or {}
            if body.get("enable"):
                return self._send(200, boot_enable(srv.get("port") or 8787,
                                                   srv.get("bind") or "127.0.0.1",
                                                   bool(srv.get("tunnel"))))
            return self._send(200, boot_disable())
        if route == "/api/restore":
            names = (last_stop_report() or {}).get("restore") or []
            started, errors = [], {}
            for n in names:
                try:
                    instance_action(n, "start")
                    started.append(n)
                except Exception as ex:
                    errors[n] = str(ex)
            dismiss_last_stop()
            return self._send(200, {"started": started, "errors": errors})
        if route == "/api/last-stop/dismiss":
            return self._send(200, dismiss_last_stop())
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/([a-z]+)$", route)
        if m:
            return self._send(200, instance_action(m.group(1), m.group(2), body))
        if route == "/api/term":
            name = body.get("container") or ""
            if not re.match(r"^[A-Za-z0-9_.-]+$", name):
                return self._err(400, "bad container name")
            # One targeted inspect; scanning every forge container here cost
            # a couple of seconds before the shell even started.
            rc, out, _ = run(["docker", "inspect", "-f",
                              '{{.State.Running}}|{{index .Config.Labels "%s.entry"}}' % LABEL,
                              name], timeout=20)
            running, _, lbl = (out.strip().partition("|"))
            if rc != 0 or running != "true" or not lbl:
                return self._err(400, "%s is not a running forge container" % name)
            s = term_open(name, body.get("cols") or 100, body.get("rows") or 28,
                          user=body.get("user"))
            return self._send(200, {"id": s.id, "container": name})
        m = re.match(r"^/api/term/([0-9a-f]+)/(input|resize|close)$", route)
        if m:
            s = term_get(m.group(1))
            if not s:
                return self._err(404, "no such terminal")
            what = m.group(2)
            if what == "input":
                s.write(body.get("data") or "")
            elif what == "resize":
                s.resize(body.get("cols") or 100, body.get("rows") or 28)
            else:
                s.close()
            return self._send(200, {"ok": True, "closed": s.closed})
        return self._err(404, "no such endpoint")

    # -- streams ----------------------------------------------------------
    def _stream_job(self, jid):
        job = job_get(jid)
        if not job:
            return self._err(404, "no such job")
        cursor = _int_or_none(self.headers.get("Last-Event-ID")) \
            or _int_or_none(self._query().get("cursor")) or 0
        self._sse_open()
        try:
            self._sse_send(job.snapshot(), event="snapshot")
            idle = 0
            while True:
                evs = job.since(cursor, timeout=8.0)
                if evs:
                    idle = 0
                    for ev in evs:
                        cursor = ev["seq"]
                        self._sse_send(ev, event=ev["type"], eid=ev["seq"])
                else:
                    idle += 1
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                if job.status != "running":
                    remaining = [e for e in job.events if e["seq"] > cursor]
                    for ev in remaining:
                        cursor = ev["seq"]
                        self._sse_send(ev, event=ev["type"], eid=ev["seq"])
                    self._sse_send(job.snapshot(), event="final")
                    return
                if idle > 150:
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _stream_term(self, sid):
        s = term_get(sid)
        if not s:
            return self._err(404, "no such terminal")
        cursor = _int_or_none(self.headers.get("Last-Event-ID")) \
            or _int_or_none(self._query().get("cursor")) or 0
        self._sse_open()
        try:
            while True:
                chunks = s.read_since(cursor, timeout=8.0)
                if chunks:
                    for seq, data in chunks:
                        cursor = seq
                        self._sse_send(base64.b64encode(data).decode("ascii"),
                                       event="data", eid=seq)
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                if s.closed:
                    self._sse_send({"exit": s.exit_code}, event="closed")
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


def _run_job(the_job, fn, *args, **kwargs):
    """Run fn in a thread as `the_job`; failures land in the job, not the request.

    (The first parameter is not called `job`: the work functions take job=...
    themselves, and a clash made every backup, clone and restore from the web
    UI fail with "got multiple values for argument 'job'".)"""
    def work():
        try:
            fn(*args, **kwargs)
        except Exception as ex:
            if the_job.status == "running":
                the_job.fail(str(ex))
    the_job.thread = threading.Thread(target=work, daemon=True)
    the_job.thread.start()
    return the_job.snapshot()


def serve(bind="127.0.0.1", port=8787, open_tunnel=False, quiet=False):
    ensure_dirs()
    os.environ["FORGE_JOB_OWNER"] = "server"
    loopback = bind in ("127.0.0.1", "localhost", "::1")
    Handler.loopback_only = loopback

    for attempt in range(60):
        try:
            httpd = ThreadingHTTPServer((bind, port), Handler)
            break
        except OSError as ex:
            if ex.errno in (errno.EADDRINUSE, errno.EACCES):
                port += 1
                continue
            raise
    else:
        raise RuntimeError("could not bind a port for the web UI")

    httpd.daemon_threads = True
    STATS.start()
    # Forget desktops that were removed behind our back, then keep watching.
    try:
        reconcile()
        recover_interrupted()          # launches this web UI was running when it stopped
    except Exception:
        pass
    WATCHDOG.start()

    updates.SERVE_PAYLOAD = installed_payload()
    for name in ("index.html", "app.css", "app.js", "addons.js", "term.js", "logos.js", "brands.js"):
        try:
            with open(os.path.join(WEBDIR, name), "rb") as fh:
                Handler.static_cache[name] = fh.read()
        except OSError:
            pass
    threading.Thread(target=_update_loop, daemon=True).start()

    url = "http://%s:%d/" % ("localhost" if loopback else bind, port)
    info = {"pid": os.getpid(), "port": port, "bind": bind, "url": url,
            "started": time.time(), "version": VERSION,
            "payload": updates.SERVE_PAYLOAD}
    jsave(SERVER_JSON, info)

    # Keep a record of this run so the next CLI start can say how it ended.
    prev = jload(LIFE_JSON, None)
    if prev and prev.get("pid") != os.getpid():
        rep = analyze_life(prev)
        if rep:
            rep["recorded"] = time.time()
            jsave(LAST_STOP_JSON, rep)
    life = {"pid": os.getpid(), "started": time.time(), "heartbeat": time.time(),
            "boot_id": boot_id(), "port": port, "bind": bind,
            "boot_start": os.environ.get("FORGE_BOOT") == "1",
            "desktops_running": running_desktop_names(), "stopped": None}
    jsave(LIFE_JSON, life)
    stop_state = {"reason": None, "detail": ""}

    def heartbeat():
        while True:
            time.sleep(20)
            try:
                life["heartbeat"] = time.time()
                life["desktops_running"] = running_desktop_names()
                jsave(LIFE_JSON, life)
            except Exception:
                pass
            try:
                addons.sync_integrations()   # apps like Burrow learn where this forge is
            except Exception:
                pass
    threading.Thread(target=heartbeat, daemon=True).start()

    def on_signal(signum, _frame):
        req = jload(STOP_REQUEST_JSON, {}) or {}
        if req.get("pid") == os.getpid() and time.time() - float(req.get("at") or 0) < 120:
            stop_state["reason"] = req.get("reason") or "user"
        else:
            down = host_going_down()
            if down:
                stop_state["reason"] = "host-" + down
            elif os.environ.get("INVOCATION_ID") and signum == signal.SIGTERM:
                stop_state["reason"] = "service"     # systemctl --user stop
            else:
                stop_state["reason"] = "signal"
            stop_state["detail"] = ("another program sent it %s"
                                    % ("SIGTERM" if signum == signal.SIGTERM else "SIGHUP"))
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, on_signal)
        except (ValueError, OSError):
            pass

    tun = None
    if open_tunnel:
        try:
            tun = tunnel_start("__webui__", port, mode="http")
            info["tunnel"] = tun["url"]
            jsave(SERVER_JSON, info)
        except Exception as ex:
            info["tunnel_error"] = str(ex)
            jsave(SERVER_JSON, info)

    if not quiet:
        print(json.dumps(info))
        sys.stdout.flush()
    try:
        addons.sync_integrations()
    except Exception:
        pass

    watchdog = threading.Thread(target=_tunnel_watchdog, daemon=True)
    watchdog.start()

    try:
        httpd.serve_forever(poll_interval=0.4)
    except KeyboardInterrupt:
        stop_state["reason"] = stop_state["reason"] or "ctrl-c"
    except Exception as ex:
        stop_state["reason"] = "error"
        stop_state["detail"] = "%s: %s" % (type(ex).__name__, ex)
        raise
    finally:
        try:
            life["stopped"] = {"reason": stop_state["reason"] or "signal",
                               "at": time.time(), "detail": stop_state["detail"]}
            life["heartbeat"] = time.time()
            jsave(LIFE_JSON, life)
            try:
                os.remove(STOP_REQUEST_JSON)
            except OSError:
                pass
        except Exception:
            pass
        STATS.stop()
        if tun:
            tunnel_stop("__webui__")
        try:
            os.remove(SERVER_JSON)
        except OSError:
            pass


def _tunnel_watchdog():
    """Serveo drops tunnels now and then; put them back."""
    while True:
        time.sleep(25)
        try:
            for it in docker_instances():
                t = it.get("tunnel")
                if not t or not it["running"] or t.get("alive"):
                    continue
                port = (it["ports"] or {}).get(
                    str(KASM_HTTPS) if it["profile"] == "kasm" else str(SELKIES_HTTP))
                if not port:
                    continue
                try:
                    tunnel_start(it["name"], port, mode=t.get("mode", "http"))
                except Exception:
                    pass
        except Exception:
            pass
