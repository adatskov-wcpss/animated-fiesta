#!/usr/bin/env python3
"""
Hello Forge - the example addon's app.

A tiny web page (Python standard library only) that greets you and lists the
desktops of the Selkies Forge it was installed from, read from the forge's
JSON API. Run by forge/install.sh as:

    python3 app/server.py $FORGE_ADDON_DATA/config.json

GET /         the page (and one more visit on the counter)
GET /health   {"app": "hello-forge", "ok": true, "visits": N}   used by status.sh
POST /reset   the visit counter back to 0 (from this machine only)
"""

import html
import json
import os
import sys
import threading
import urllib.request

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "config.json")
LOCK = threading.Lock()
ACCENTS = {"blue": ("#5aa6ff", "#8b7dff"), "green": ("#3ddc97", "#2bb3a3"),
           "amber": ("#ffad42", "#ff6a3d"), "mono": ("#f1f2f3", "#9aa0a8")}


def load():
    with open(CONF) as fh:
        return json.load(fh)


def save(cfg):
    tmp = CONF + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cfg, fh, indent=2)
    os.replace(tmp, CONF)


def desktops(cfg):
    """The forge's desktops, through its API: GET {FORGE_API}instances."""
    if not cfg.get("show_desktops") or not cfg.get("forge_api"):
        return None, None
    try:
        req = urllib.request.Request(cfg["forge_api"] + "instances", headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=4) as r:
            return json.load(r).get("instances") or [], None
    except Exception as ex:
        return None, "the forge's API did not answer (%s)" % type(ex).__name__


def page(cfg):
    a1, a2 = ACCENTS.get(cfg.get("accent"), ACCENTS["blue"])
    ink = "#000" if cfg.get("accent") == "mono" else "#061020"
    items, err = desktops(cfg)
    if items is None and not err:
        body = '<p class="muted">Listing desktops is switched off in this addon\'s settings.</p>'
    elif err:
        body = '<p class="muted">%s</p>' % html.escape(err)
    elif not items:
        body = '<p class="muted">No desktops yet. Make one in Selkies Forge and reload.</p>'
    else:
        rows = []
        for i in items:
            dot = "on" if i.get("running") else "off"
            link = i.get("local_url") or ""
            rows.append('<li><i class="%s"></i><b>%s</b><span>%s</span>%s</li>' % (
                dot, html.escape(i.get("title") or i.get("name") or "?"),
                html.escape(i.get("status") or ""),
                '<a href="%s" target="_blank" rel="noopener">open</a>' % html.escape(link) if link and i.get("running") else ""))
        body = '<ul class="desks">%s</ul>' % "".join(rows)
    return """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Hello Forge</title>
<style>
:root{--a1:%(a1)s;--a2:%(a2)s}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;
font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;color:#e9effd;background:#060a12;
background-image:radial-gradient(900px 500px at 15%% -10%%,color-mix(in srgb,var(--a1) 22%%,transparent),transparent 60%%),
radial-gradient(800px 500px at 90%% 0,color-mix(in srgb,var(--a2) 18%%,transparent),transparent 60%%)}
main{width:100%%;max-width:560px;padding:28px;border-radius:20px;background:rgba(16,26,46,.6);border:1px solid rgba(142,174,226,.18);
box-shadow:0 20px 60px rgba(2,6,16,.5)}
.mark{width:52px;height:52px;border-radius:15px;display:grid;place-items:center;margin-bottom:16px;
background:linear-gradient(135deg,var(--a1),var(--a2));color:%(ink)s;font-size:24px}
h1{margin:0 0 6px;font-size:26px;letter-spacing:-.02em}.muted{color:#9db2d8;margin:0}
.meta{display:flex;gap:8px;flex-wrap:wrap;margin:14px 0 22px}.meta span{font:12px ui-monospace,monospace;color:#9db2d8;
padding:3px 9px;border-radius:99px;border:1px solid rgba(142,174,226,.22)}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#6a80a8;margin:0 0 10px}
.desks{list-style:none;margin:0;padding:0;display:grid;gap:8px}
.desks li{display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:12px;background:rgba(255,255,255,.04);border:1px solid rgba(142,174,226,.12)}
.desks i{width:8px;height:8px;border-radius:50%%;background:#4a5568}.desks i.on{background:#3ddc97;box-shadow:0 0 10px #3ddc97}
.desks span{color:#6a80a8;font-size:12px}.desks a{margin-left:auto;color:var(--a1);font-weight:600;text-decoration:none}
footer{margin-top:22px;font-size:12px;color:#6a80a8}
</style></head><body><main>
<div class="mark">&#9650;</div>
<h1>%(greeting)s</h1>
<p class="muted">This page is Hello Forge, the example addon for Selkies Forge. Its whole source is in
<code>addons/hello-forge/</code>.</p>
<div class="meta"><span>addon v%(version)s</span><span>forge v%(fv)s</span><span>%(visits)d visits</span></div>
<h2>Desktops on this machine</h2>
%(body)s
<footer>Settings live in the forge: Addons &rarr; Hello Forge &rarr; &hellip; &rarr; Settings and reinstall.</footer>
</main></body></html>""" % {"a1": a1, "a2": a2, "ink": ink, "greeting": html.escape(cfg.get("greeting") or "Hello"),
                             "version": html.escape(cfg.get("version") or "?"), "fv": html.escape(cfg.get("forge_version") or "?"),
                             "visits": int(cfg.get("visits") or 0), "body": body}


class Handler(BaseHTTPRequestHandler):
    server_version = "HelloForge/1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with LOCK:
            cfg = load()
            if path == "/":
                cfg["visits"] = int(cfg.get("visits") or 0) + 1
                save(cfg)
        if path == "/health":
            return self._send(200, json.dumps({"app": "hello-forge", "ok": True, "visits": cfg.get("visits", 0),
                                               "version": cfg.get("version")}), "application/json")
        if path == "/":
            return self._send(200, page(cfg), "text/html; charset=utf-8")
        return self._send(404, "not found", "text/plain")

    def do_POST(self):
        if self.path != "/reset" or self.client_address[0] not in ("127.0.0.1", "::1", load().get("bind")):
            return self._send(404, "not found", "text/plain")
        with LOCK:
            cfg = load()
            cfg["visits"] = 0
            save(cfg)
        return self._send(200, '{"ok": true}', "application/json")


def main():
    cfg = load()
    bind = cfg.get("bind") or "127.0.0.1"
    httpd = ThreadingHTTPServer((bind, int(cfg.get("port") or 8790)), Handler)
    httpd.daemon_threads = True
    print("hello-forge on http://%s:%s/" % (bind, cfg.get("port")), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
