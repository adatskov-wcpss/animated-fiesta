"""
Selkies Forge engine - addons

An addon is an app that installs beside the forge: a git repository (or a
folder inside one) with a forge-addon.json at its root. Paste its link in the
web UI (Addons) or run `selkies-cli addon add LINK`; the forge clones it,
checks the manifest, shows its logo and description, and runs its scripts:

    detect      is it already on this machine?          (quick, read-only)
    install     put it on this machine                  (a job, streamed live)
    update      new code arrived; bring the install up to date
    uninstall   take it off again
    status      is it running, and where do I open it?  (one JSON line)

Scripts are bash, run as you, from the addon's folder, with FORGE_* in the
environment (where the forge is, where to keep data, the user's settings).
Lines starting with "::" talk back: ::progress 40 Pulling, ::phase Linking,
::open URL, ::warn text. Everything else is log.

The full format, with a worked example, is docs/addons.md. The example addon
lives in addons/hello-forge/ in this repository.

Layout: FORGE_HOME/addons/<id>/repo (the checkout) and .../data (kept across
updates, FORGE_ADDON_DATA). The registry is state/addons.json.

Integrations: apps that keep a drop-in folder for other apps (Burrow reads
~/.config/burrow/integrations/) get a small JSON file describing the forge,
kept current while the web UI runs, so they can show its desktops.
"""

import json
import os
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from . import burrow
from .paths import ADDONDIR, ADDONS_JSON, ROOT, SERVER_JSON, VERSION
from .tunnels import kill_tunnel, tunnel_start
from .util import FileLock, ensure_dirs, have, jload, jsave, pid_alive

SPEC = 1
MANIFEST = "forge-addon.json"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
SETTING_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,31}$")
ACTION_RE = re.compile(r"^[a-z][a-z0-9-]{0,23}$")
SCRIPTS = ("detect", "install", "update", "uninstall", "status")
SETTING_TYPES = ("text", "number", "bool", "select", "password")
IMAGE_TYPES = {".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp",
               ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}
MAX_IMAGE = 512 * 1024
MAX_MANIFEST = 64 * 1024
TIMEOUT = {"detect": 20, "status": 15, "install": 3600, "update": 3600,
           "uninstall": 900, "action": 900}
ARCH_ALIASES = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64", "armhf": "armv7l"}

# Burrow (github.com/alexd-aero/burrow) keeps its drop-in folder here; the
# forge registers itself whenever Burrow is on this machine, however it got there.
KNOWN_INTEGRATION_DIRS = ("~/.config/burrow/integrations",)

FORGE_LOGO = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
              '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
              '<stop offset="0" stop-color="#5aa6ff"/><stop offset="1" stop-color="#8b7dff"/>'
              '</linearGradient></defs>'
              '<rect width="64" height="64" rx="16" fill="url(#g)"/>'
              '<path d="M18 44 32 18l14 26z" fill="#061020"/>'
              '<path d="M18 44 32 18l14 26z" fill="none" stroke="#061020" stroke-width="4" '
              'stroke-linejoin="round"/></svg>')


class AddonError(RuntimeError):
    """Something the person can fix: a bad link, a broken manifest, a failed script."""


# ------------------------------------------------------------------ sources
_HOSTED_TREE = re.compile(
    r"^(https://(?:github\.com|gitlab\.com|codeberg\.org)/[^/\s]+/[^/\s#]+?)(?:\.git)?"
    r"/(?:-/)?tree/([^/\s#]+)(?:/([^#\s]*?))?/?$")


def parse_source(text):
    """Turn what the person pasted into a fetchable source.

    https://github.com/OWNER/REPO                       the repository's root
    https://github.com/OWNER/REPO/tree/BRANCH/a/folder  a folder on a branch
    https://example.com/repo.git#a/folder               any git URL, a folder in it
    git@host:owner/repo.git                             ssh, if your keys allow it
    /home/me/my-addon                                   a folder on this machine (development)
    """
    raw = (text or "").strip()
    if not raw:
        raise AddonError("Paste a repository link.")
    if raw.startswith(("/", "~", "./", "../", "file://")):
        p = os.path.abspath(os.path.expanduser(raw[7:] if raw.startswith("file://") else raw))
        if not os.path.isdir(p):
            raise AddonError("%s is not a folder on this machine." % p)
        return {"kind": "local", "path": p, "subdir": "", "ref": None, "display": p}
    url, sub = raw, ""
    if "#" in url:
        url, sub = url.split("#", 1)
    ref = None
    m = _HOSTED_TREE.match(url)
    if m:
        url, ref = m.group(1), m.group(2)
        sub = sub or (m.group(3) or "")
    url = url.rstrip("/")
    if not re.match(r"^(https?://[^\s/]+/\S+|ssh://\S+|git@[^\s:]+:\S+)$", url):
        raise AddonError("That does not look like a git repository link.")
    sub = sub.strip("/")
    if sub and (".." in sub.split("/") or not re.match(r"^[A-Za-z0-9._/-]+$", sub)):
        raise AddonError("The folder part of the link is not valid.")
    return {"kind": "git", "url": url, "ref": ref, "subdir": sub, "display": raw}


def _git(args, cwd=None, timeout=240):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/true")
    p = subprocess.run(["git"] + args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def fetch(source, dest):
    """Put the source's files in dest (a new folder). Returns the commit, if any."""
    if source["kind"] == "local":
        shutil.copytree(source["path"], dest, symlinks=True,
                        ignore=shutil.ignore_patterns(".git", "node_modules", "__pycache__"))
        return None
    if not have("git"):
        raise AddonError("git is not installed on this machine; it is needed to fetch addons.")
    base = ["clone", "--depth", "1", "--quiet"]
    if source.get("ref"):
        base += ["--branch", source["ref"]]
    sub = source.get("subdir")
    rc, err = 1, ""
    if sub:
        # Only the folder we need: a big repository (this one has screenshots) stays small.
        rc, _, err = _git(base + ["--filter=blob:none", "--sparse", source["url"], dest])
        if rc == 0:
            rc, _, err = _git(["sparse-checkout", "set", "--no-cone", "/" + sub + "/"], cwd=dest)
            if rc != 0:
                shutil.rmtree(dest, ignore_errors=True)
    if rc != 0:
        rc, _, err = _git(base + [source["url"], dest])
    if rc != 0:
        msg = (err.strip().splitlines() or ["git clone failed"])[-1]
        if "could not read Username" in err or "Authentication failed" in err or "not found" in err.lower():
            msg = "the repository was not found, or it is private"
        raise AddonError("Could not fetch %s: %s" % (source["display"], msg))
    rc, out, _ = _git(["rev-parse", "HEAD"], cwd=dest, timeout=20)
    return out.strip()[:40] if rc == 0 else None


# ------------------------------------------------------------------ manifest
def _inside(root, rel, what, must_exist=True):
    """A path from the manifest, resolved inside the addon's folder (no escaping)."""
    if not isinstance(rel, str) or not rel.strip():
        raise AddonError("%s must be a path inside the addon" % what)
    rel = rel.strip()
    if rel.startswith("/") or ".." in rel.replace("\\", "/").split("/"):
        raise AddonError("%s (%s) must be a relative path inside the addon" % (what, rel))
    real_root = os.path.realpath(root)
    p = os.path.realpath(os.path.join(root, rel))
    if p != real_root and not p.startswith(real_root + os.sep):
        raise AddonError("%s (%s) points outside the addon" % (what, rel))
    if must_exist and not os.path.isfile(p):
        raise AddonError("%s (%s) does not exist" % (what, rel))
    return rel


def _image(root, rel, what):
    rel = _inside(root, rel, what)
    ext = os.path.splitext(rel)[1].lower()
    if ext not in IMAGE_TYPES:
        raise AddonError("%s must be .svg, .png, .webp or .jpg" % what)
    if os.path.getsize(os.path.join(root, rel)) > MAX_IMAGE:
        raise AddonError("%s is larger than %d KB" % (what, MAX_IMAGE // 1024))
    return rel


def _text(d, key, limit, required=False):
    v = d.get(key)
    if v is None or v == "":
        if required:
            raise AddonError("forge-addon.json needs \"%s\"" % key)
        return ""
    if not isinstance(v, str):
        raise AddonError("\"%s\" must be text" % key)
    v = v.strip()
    if len(v) > limit:
        raise AddonError("\"%s\" is longer than %d characters" % (key, limit))
    return v


def _url(v, what):
    if not isinstance(v, str) or not re.match(r"^https?://\S+$", v.strip()):
        raise AddonError("%s must be an http(s) link" % what)
    return v.strip()


def version_tuple(v):
    out = []
    for part in re.split(r"[.+-]", str(v or "0")):
        if not part.isdigit():
            break
        out.append(int(part))
    return tuple(out + [0] * (3 - len(out)))


def load_manifest(root):
    """Read and check forge-addon.json. Returns a clean copy, or raises AddonError
    with a message that says exactly what to fix."""
    path = os.path.join(root, MANIFEST)
    if not os.path.isfile(path):
        raise AddonError("No %s here. An addon needs one at its root (see the Addons docs)." % MANIFEST)
    if os.path.getsize(path) > MAX_MANIFEST:
        raise AddonError("%s is larger than 64 KB" % MANIFEST)
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except ValueError as ex:
        raise AddonError("%s is not valid JSON: %s" % (MANIFEST, ex))
    if not isinstance(d, dict):
        raise AddonError("%s must be a JSON object" % MANIFEST)

    spec = d.get("spec")
    if spec != SPEC:
        if isinstance(spec, int) and spec > SPEC:
            raise AddonError("This addon needs a newer Selkies Forge (addon spec %d; this forge reads %d)."
                             % (spec, SPEC))
        raise AddonError("forge-addon.json needs \"spec\": %d" % SPEC)
    m = {"spec": SPEC}
    m["id"] = _text(d, "id", 40, True)
    if not ID_RE.match(m["id"]):
        raise AddonError("\"id\" must be 2-40 lowercase letters, digits or dashes, starting with a letter or digit")
    m["name"] = _text(d, "name", 60, True)
    m["version"] = _text(d, "version", 30, True)
    m["description"] = _text(d, "description", 600)
    m["author"] = _text(d, "author", 80)
    m["license"] = _text(d, "license", 40)
    m["homepage"] = _url(d["homepage"], "\"homepage\"") if d.get("homepage") else ""
    m["logo"] = _image(root, d["logo"], "\"logo\"") if d.get("logo") else ""

    scripts = d.get("scripts")
    if not isinstance(scripts, dict) or not scripts.get("install"):
        raise AddonError("forge-addon.json needs \"scripts\": {\"install\": \"...\"}")
    m["scripts"] = {}
    for k, v in scripts.items():
        if k not in SCRIPTS:
            raise AddonError("unknown script \"%s\" (known: %s)" % (k, ", ".join(SCRIPTS)))
        m["scripts"][k] = _inside(root, v, "scripts.%s" % k)

    m["actions"] = []
    for a in d.get("actions") or []:
        if not isinstance(a, dict) or not ACTION_RE.match(str(a.get("id") or "")):
            raise AddonError("every action needs an \"id\" (lowercase letters, digits, dashes)")
        if a["id"] in SCRIPTS:
            raise AddonError("action \"%s\" has the name of a lifecycle script" % a["id"])
        m["actions"].append({"id": a["id"], "label": _text(a, "label", 24, True),
                             "script": _inside(root, a.get("script"), "actions.%s.script" % a["id"]),
                             "confirm": _text(a, "confirm", 200)})
    if len(m["actions"]) > 8:
        raise AddonError("at most 8 actions")

    m["settings"] = []
    seen = set()
    for s in d.get("settings") or []:
        if not isinstance(s, dict) or not SETTING_RE.match(str(s.get("key") or "")):
            raise AddonError("every setting needs a \"key\" in CAPITALS (A-Z, 0-9, _), e.g. PORT")
        if s["key"] in seen:
            raise AddonError("setting %s appears twice" % s["key"])
        seen.add(s["key"])
        typ = s.get("type") or "text"
        if typ not in SETTING_TYPES:
            raise AddonError("setting %s: type must be one of %s" % (s["key"], ", ".join(SETTING_TYPES)))
        st = {"key": s["key"], "type": typ, "label": _text(s, "label", 60, True),
              "help": _text(s, "help", 300), "default": s.get("default"),
              "required": bool(s.get("required"))}
        if typ == "number":
            for k in ("min", "max"):
                if s.get(k) is not None:
                    st[k] = float(s[k])
        if typ == "select":
            opts = []
            for o in s.get("options") or []:
                o = o if isinstance(o, dict) else {"value": o, "label": o}
                opts.append({"value": str(o.get("value")), "label": str(o.get("label") or o.get("value"))[:60]})
            if not opts:
                raise AddonError("setting %s: a select needs \"options\"" % s["key"])
            st["options"] = opts
        if s.get("icon"):
            st["icon"] = _image(root, s["icon"], "setting %s icon" % s["key"])
        st["default"] = _coerce(st, st["default"]) if st["default"] is not None else None
        m["settings"].append(st)
    if len(m["settings"]) > 16:
        raise AddonError("at most 16 settings")

    req = d.get("requires") or {}
    if not isinstance(req, dict):
        raise AddonError("\"requires\" must be an object")
    m["requires"] = {
        "forge": str(req.get("forge") or "").strip(),
        "os": [str(x).lower() for x in req.get("os") or []],
        "arch": [ARCH_ALIASES.get(str(x).lower(), str(x).lower()) for x in req.get("arch") or []],
        "commands": [str(x) for x in req.get("commands") or [] if re.match(r"^[A-Za-z0-9._+-]+$", str(x))],
    }
    if m["requires"]["forge"] and not re.match(r"^(>=)?\s*\d+(\.\d+){0,2}$", m["requires"]["forge"]):
        raise AddonError("requires.forge must look like \">=1.10.0\"")

    integ = d.get("integration") or {}
    m["integration"] = {}
    if integ:
        p = str(integ.get("dir") or "")
        if not (p.startswith("~/") or p.startswith("$HOME/")) or ".." in p.split("/"):
            raise AddonError("integration.dir must be a folder under ~/ (e.g. ~/.config/myapp/integrations)")
        m["integration"] = {"dir": p}

    m["links"] = []
    for ln in (d.get("links") or [])[:6]:
        if isinstance(ln, dict):
            m["links"].append({"label": _text(ln, "label", 40, True), "url": _url(ln.get("url"), "link url")})
    return m


def _coerce(st, v):
    """A setting's value as its type says; raises AddonError on nonsense."""
    typ = st["type"]
    if typ == "bool":
        if isinstance(v, str):
            return v.strip().lower() in ("1", "true", "yes", "on")
        return bool(v)
    if typ == "number":
        try:
            n = float(v)
        except (TypeError, ValueError):
            raise AddonError("%s must be a number" % st["label"])
        if "min" in st and n < st["min"] or "max" in st and n > st["max"]:
            raise AddonError("%s must be between %g and %g" % (st["label"], st.get("min", n), st.get("max", n)))
        return int(n) if n == int(n) else n
    v = "" if v is None else str(v)
    if typ == "select" and v not in [o["value"] for o in st["options"]]:
        raise AddonError("%s: pick one of the options" % st["label"])
    if len(v) > 2000:
        raise AddonError("%s is too long" % st["label"])
    return v


def check_requirements(m):
    """What this machine lacks for the addon, as sentences (empty: all good)."""
    out = []
    r = m["requires"]
    if r["forge"]:
        want = version_tuple(r["forge"].lstrip(">= "))
        if version_tuple(VERSION) < want:
            out.append("needs Selkies Forge %s or newer (this is %s)" % (".".join(map(str, want)), VERSION))
    sysname = platform.system().lower()
    if r["os"] and sysname not in r["os"]:
        out.append("runs on %s, not %s" % (", ".join(r["os"]), sysname))
    mach = ARCH_ALIASES.get(platform.machine().lower(), platform.machine().lower())
    if r["arch"] and mach not in r["arch"]:
        out.append("has no build for %s (it supports %s)" % (mach, ", ".join(r["arch"])))
    missing = [c for c in r["commands"] if not have(c)]
    if missing:
        out.append("needs %s installed" % ", ".join(missing))
    return out


# ------------------------------------------------------------------ registry
def _load():
    return (jload(ADDONS_JSON, {}) or {}).get("addons") or {}


def _save(addons):
    jsave(ADDONS_JSON, {"spec": SPEC, "addons": addons})


def _update(aid, patch):
    with FileLock("addons"):
        addons = _load()
        rec = addons.get(aid)
        if rec is None:
            raise AddonError("No addon called %s." % aid)
        rec.update(patch)
        addons[aid] = rec
        _save(addons)
        return rec


def get(aid):
    rec = _load().get(aid)
    if not rec:
        raise AddonError("No addon called %s." % aid)
    return rec


def addon_dir(aid):
    return os.path.join(ADDONDIR, aid)


def root_of(rec):
    return os.path.join(addon_dir(rec["id"]), "repo", rec.get("subdir") or "")


def data_dir(rec):
    d = os.path.join(addon_dir(rec["id"]), "data")
    os.makedirs(d, exist_ok=True)
    return d


# ------------------------------------------------------------------ running scripts
def forge_url():
    """The web UI's address as this machine reaches it, or None when it is not running."""
    srv = jload(SERVER_JSON, None) or {}
    if not srv.get("port"):
        return None
    host = srv.get("bind") or "127.0.0.1"
    if host in ("0.0.0.0", "::", ""):
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = "[%s]" % host
    return "http://%s:%d/" % (host, int(srv["port"]))


def script_env(rec, extra=None):
    m = rec["manifest"]
    url = forge_url()
    srv = jload(SERVER_JSON, None) or {}
    env = dict(os.environ)
    env.update({
        "FORGE_ADDON_SPEC": str(SPEC), "FORGE_ADDON_ID": rec["id"], "FORGE_ADDON_NAME": m["name"],
        "FORGE_ADDON_VERSION": m["version"], "FORGE_ADDON_DIR": root_of(rec),
        "FORGE_ADDON_DATA": data_dir(rec), "FORGE_HOME": ROOT, "FORGE_VERSION": VERSION,
        "FORGE_URL": url or "", "FORGE_API": (url + "api/") if url else "",
        "FORGE_BIND": srv.get("bind") or "127.0.0.1", "FORGE_PORT": str(srv.get("port") or ""),
        "FORGE_ARCH": ARCH_ALIASES.get(platform.machine().lower(), platform.machine().lower()),
        "FORGE_ADDON_ADOPT": "0", "FORGE_ADDON_UPDATE": "0",
    })
    for st in m["settings"]:
        v = (rec.get("settings") or {}).get(st["key"], st.get("default"))
        if v is None:
            v = ""
        elif st["type"] == "bool":
            v = "1" if v else "0"
        env["FORGE_ADDON_SETTING_" + st["key"]] = str(v)
    env.update(extra or {})
    return env


def run_script(rec, rel, job=None, extra_env=None, timeout=600):
    """Run one of the addon's scripts. Returns (exit code, output lines, directives).

    With a job, output is streamed into it (the web UI shows it live) and the
    job's cancel button kills the script and everything it started.
    """
    root = root_of(rec)
    path = os.path.join(root, rel)
    proc = subprocess.Popen(["bash", path], cwd=root, env=script_env(rec, extra_env),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    if job:
        job.attach(proc)
    killed = {"why": None}

    def stop(why):
        killed["why"] = why
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        t = threading.Timer(5.0, lambda: _kill9(proc.pid))
        t.daemon = True
        t.start()

    timer = threading.Timer(timeout, stop, args=("timed out after %ds" % timeout,))
    timer.daemon = True
    timer.start()
    lines, directives = [], {"open": None, "warn": []}
    try:
        for raw in iter(proc.stdout.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("::"):
                _directive(line, job, directives)
                continue
            lines.append(line)
            if len(lines) > 400:
                del lines[:100]
            if job:
                job.log(line)
        proc.wait()
    finally:
        timer.cancel()
        proc.stdout.close()
        if job:
            job.detach(proc)
    rc = proc.returncode
    if killed["why"]:
        lines.append(killed["why"])
        if job:
            job.log(killed["why"], "err")
        rc = rc if rc else 124
    return rc, lines, directives


def _kill9(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def _directive(line, job, out):
    word, _, rest = line[2:].partition(" ")
    rest = rest.strip()
    if word == "progress":
        pct, _, label = rest.partition(" ")
        try:
            value = max(0.0, min(100.0, float(pct))) / 100.0
        except ValueError:
            return
        if job:
            job.set_phase("addon", label or getattr(job, "label", "working"), progress=value)
    elif word == "phase" and job:
        job.set_phase("addon", rest[:120] or "working")
    elif word == "open" and re.match(r"^https?://\S+$", rest):
        out["open"] = rest
    elif word == "warn":
        out["warn"].append(rest[:300])
        if job:
            job.log(rest, "err")


def _last_json(lines):
    for ln in reversed(lines):
        ln = ln.strip()
        if ln.startswith("{") and ln.endswith("}"):
            try:
                v = json.loads(ln)
                if isinstance(v, dict):
                    return v
            except ValueError:
                pass
    return {}


def detect(rec):
    s = rec["manifest"]["scripts"].get("detect")
    if not s:
        return {"found": False}
    try:
        rc, lines, _ = run_script(rec, s, timeout=TIMEOUT["detect"])
    except OSError:
        return {"found": False}
    if rc != 0:
        return {"found": False}
    info = _last_json(lines)
    return {"found": True, "version": str(info.get("version") or "")[:30],
            "url": info.get("url") if re.match(r"^https?://\S+$", str(info.get("url") or "")) else None,
            "detail": str(info.get("detail") or "")[:200]}


_STATUS = {}            # id -> (time, status)
_STATUS_LOCK = threading.Lock()


def status(rec, max_age=8.0):
    """{"state": running|stopped|error|installed|not-installed, "url", "version", "detail"}"""
    if not rec.get("installed"):
        return {"state": "not-installed"}
    s = rec["manifest"]["scripts"].get("status")
    if not s:
        return {"state": "installed", "url": rec.get("open_url")}
    with _STATUS_LOCK:
        hit = _STATUS.get(rec["id"])
        if hit and time.time() - hit[0] < max_age:
            return hit[1]
    try:
        rc, lines, _ = run_script(rec, s, timeout=TIMEOUT["status"])
        info = _last_json(lines)
        st = {"state": str(info.get("state") or ("installed" if rc == 0 else "error"))[:20],
              "url": info.get("url") if re.match(r"^https?://\S+$", str(info.get("url") or "")) else rec.get("open_url"),
              "version": str(info.get("version") or "")[:30], "detail": str(info.get("detail") or "")[:200]}
        try:
            port = int(info.get("port") or 0)
        except (TypeError, ValueError):
            port = 0
        if 0 < port < 65536:
            st["port"] = port
    except Exception as ex:
        st = {"state": "error", "detail": str(ex)[:200], "url": rec.get("open_url")}
    with _STATUS_LOCK:
        _STATUS[rec["id"]] = (time.time(), st)
    return st


def _forget_status(aid):
    with _STATUS_LOCK:
        _STATUS.pop(aid, None)


# ------------------------------------------------------------------ the operations
def add(text):
    """Fetch an addon and register it (nothing is installed yet)."""
    source = parse_source(text)
    ensure_dirs()
    os.makedirs(ADDONDIR, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".add-", dir=ADDONDIR)
    try:
        commit = fetch(source, os.path.join(tmp, "repo"))
        root = os.path.join(tmp, "repo", source.get("subdir") or "")
        if not os.path.isdir(root):
            raise AddonError("The repository has no folder %s." % source["subdir"])
        m = load_manifest(root)
        with FileLock("addons", timeout=60):
            addons = _load()
            old = addons.get(m["id"])
            if old and old["source"].get("display") != source["display"] and old.get("installed"):
                raise AddonError("%s is already installed from %s. Uninstall it before adding another copy."
                                 % (m["name"], old["source"]["display"]))
            dest = addon_dir(m["id"])
            os.makedirs(dest, exist_ok=True)
            shutil.rmtree(os.path.join(dest, "repo"), ignore_errors=True)
            os.rename(os.path.join(tmp, "repo"), os.path.join(dest, "repo"))
            rec = dict(old or {}, id=m["id"], source=source, subdir=source.get("subdir") or "",
                       commit=commit, manifest=m, updated=time.time())
            rec.setdefault("added", time.time())
            rec.setdefault("installed", False)
            rec.setdefault("settings", {})
            addons[m["id"]] = rec
            _save(addons)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rec["detected"] = detect(rec)
    _update(rec["id"], {"detected": rec["detected"]})
    _forget_status(rec["id"])
    return public(rec)


def _clean_settings(rec, given):
    out = {}
    given = given or {}
    old = rec.get("settings") or {}
    for st in rec["manifest"]["settings"]:
        k = st["key"]
        if k in given and not (st["type"] == "password" and given[k] in (None, "", "•" * 8)):
            v = _coerce(st, given[k])
        elif k in old:
            v = old[k]
        else:
            v = st.get("default")
        if st.get("required") and v in (None, ""):
            raise AddonError("%s is required" % st["label"])
        out[k] = v
    return out


def install(aid, settings=None, job=None):
    rec = get(aid)
    m = rec["manifest"]
    problems = check_requirements(m)
    if problems:
        raise AddonError("%s %s." % (m["name"], "; ".join(problems)))
    rec = _update(aid, {"settings": _clean_settings(rec, settings)})
    found = detect(rec)
    adopt = found.get("found") and not rec.get("installed")
    if job:
        job.set_phase("addon", ("Linking the %s already on this machine" if adopt else "Installing %s") % m["name"], 0.02)
        if adopt:
            job.log("%s is already on this machine%s; linking it."
                    % (m["name"], " (%s)" % found["detail"] if found.get("detail") else ""))
    rc, lines, d = run_script(rec, m["scripts"]["install"], job,
                              {"FORGE_ADDON_ADOPT": "1" if adopt else "0"}, TIMEOUT["install"])
    if job:
        job.check()
    if rc != 0:
        tail = [l for l in lines if l.strip()][-1:] or ["no output"]
        raise AddonError("the install script failed (exit %d): %s" % (rc, tail[0][:300]))
    rec = _update(aid, {"installed": True, "installed_version": m["version"], "installed_at": time.time(),
                        "adopted": bool(adopt), "open_url": d["open"] or found.get("url") or rec.get("open_url"),
                        "detected": found})
    _forget_status(aid)
    sync_integrations()
    res = {"id": aid, "name": m["name"], "open_url": rec.get("open_url"), "adopted": bool(adopt),
           "warnings": d["warn"]}
    if job:
        job.finish(res)
    return res


def update(aid, job=None):
    """Fetch the addon's code again; if it is installed, run its update (or install) script."""
    rec = get(aid)
    src = rec["source"]
    if job:
        job.set_phase("addon", "Fetching %s" % rec["manifest"]["name"], 0.05)
    tmp = tempfile.mkdtemp(prefix=".upd-", dir=ADDONDIR)
    try:
        commit = fetch(src, os.path.join(tmp, "repo"))
        m = load_manifest(os.path.join(tmp, "repo", src.get("subdir") or ""))
        if m["id"] != aid:
            raise AddonError("the repository now holds a different addon (%s)" % m["id"])
        with FileLock("addons", timeout=60):
            dest = addon_dir(aid)
            shutil.rmtree(os.path.join(dest, "repo.old"), ignore_errors=True)
            if os.path.isdir(os.path.join(dest, "repo")):
                os.rename(os.path.join(dest, "repo"), os.path.join(dest, "repo.old"))
            os.rename(os.path.join(tmp, "repo"), os.path.join(dest, "repo"))
            shutil.rmtree(os.path.join(dest, "repo.old"), ignore_errors=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    old_version = rec["manifest"]["version"]
    rec = _update(aid, {"manifest": m, "commit": commit, "updated": time.time()})
    if job:
        job.log("%s %s -> %s%s" % (m["name"], old_version, m["version"],
                                   " (%s)" % commit[:10] if commit else ""))
    res = {"id": aid, "name": m["name"], "version": m["version"], "ran": None}
    if rec.get("installed"):
        script = m["scripts"].get("update") or m["scripts"]["install"]
        res["ran"] = "update" if m["scripts"].get("update") else "install"
        if job:
            job.set_phase("addon", "Updating %s" % m["name"], 0.2)
        rc, lines, d = run_script(rec, script, job, {"FORGE_ADDON_UPDATE": "1", "FORGE_ADDON_ADOPT": "1"},
                                  TIMEOUT["update"])
        if rc != 0:
            tail = [l for l in lines if l.strip()][-1:] or ["no output"]
            raise AddonError("the update script failed (exit %d): %s" % (rc, tail[0][:300]))
        rec = _update(aid, {"installed_version": m["version"], "open_url": d["open"] or rec.get("open_url")})
        res["open_url"] = rec.get("open_url")
    _forget_status(aid)
    sync_integrations()
    if job:
        job.finish(res)
    return res


def uninstall(aid, keep_data=True, job=None):
    rec = get(aid)
    m = rec["manifest"]
    s = m["scripts"].get("uninstall")
    if job:
        job.set_phase("addon", "Uninstalling %s" % m["name"], 0.05)
    if s:
        rc, lines, _ = run_script(rec, s, job, {"FORGE_ADDON_KEEP_DATA": "1" if keep_data else "0"},
                                  TIMEOUT["uninstall"])
        if rc != 0:
            tail = [l for l in lines if l.strip()][-1:] or ["no output"]
            raise AddonError("the uninstall script failed (exit %d): %s" % (rc, tail[0][:300]))
    elif job:
        job.log("%s has no uninstall script; the forge only forgets that it is installed." % m["name"])
    if not keep_data:
        shutil.rmtree(os.path.join(addon_dir(aid), "data"), ignore_errors=True)
    _drop_shares(rec, job)
    _update(aid, {"installed": False, "installed_version": None, "open_url": None, "adopted": False,
                  "tunnel": None, "port": None})
    _forget_status(aid)
    res = {"id": aid, "name": m["name"], "kept_data": bool(keep_data)}
    if job:
        job.finish(res)
    return res


def remove(aid, force=False):
    """Forget an addon and delete its checkout (and data). It must be uninstalled first."""
    rec = get(aid)
    if rec.get("installed") and not force:
        raise AddonError("Uninstall %s first." % rec["manifest"]["name"])
    with FileLock("addons"):
        addons = _load()
        addons.pop(aid, None)
        _save(addons)
    shutil.rmtree(addon_dir(aid), ignore_errors=True)
    _forget_status(aid)
    return {"ok": True, "id": aid}


def action(aid, action_id, job=None):
    rec = get(aid)
    a = next((x for x in rec["manifest"]["actions"] if x["id"] == action_id), None)
    if not a:
        raise AddonError("%s has no action %s." % (rec["manifest"]["name"], action_id))
    if not rec.get("installed"):
        raise AddonError("Install %s first." % rec["manifest"]["name"])
    if job:
        job.set_phase("addon", "%s: %s" % (rec["manifest"]["name"], a["label"]), 0.05)
    rc, lines, d = run_script(rec, a["script"], job, None, TIMEOUT["action"])
    if rc != 0:
        tail = [l for l in lines if l.strip()][-1:] or ["no output"]
        raise AddonError("%s failed (exit %d): %s" % (a["label"], rc, tail[0][:300]))
    _forget_status(aid)
    res = {"id": aid, "action": action_id, "open_url": d["open"]}
    if job:
        job.finish(res)
    return res


# ------------------------------------------------------------------ sharing
# An addon whose status script reports a "port" can be opened every way a
# desktop can: on this machine, through a serveo public link, and through a
# Burrow address when Burrow is on the machine.
def _port(rec, st=None):
    st = status(rec) if st is None else st
    return st.get("port") or rec.get("port")


def _host(rec, st=None):
    """Where the addon listens: the host in its status URL when that is this
    machine (it may listen only on the forge's LAN or Tailscale address),
    otherwise loopback."""
    st = status(rec) if st is None else st
    m = re.match(r"^https?://\[?([^\]/:]+)\]?(?::(\d+))?", str(st.get("url") or ""))
    if m and m.group(1) in burrow.local_addresses():
        return "127.0.0.1" if m.group(1) == "localhost" else m.group(1)
    return "127.0.0.1"


def links(rec, st=None):
    st = status(rec) if st is None else st
    port = _port(rec, st)
    if not port:
        return None
    t = rec.get("tunnel") or None
    if t and not pid_alive(t.get("pid")):
        t = dict(t, alive=False)
    b = burrow.status()
    bt = burrow.tunnel_for(port, b) if b.get("running") else None
    host = _host(rec, st)
    shown = "localhost" if host == "127.0.0.1" else ("[%s]" % host if ":" in host else host)
    return {"port": port, "host": host, "local": "http://%s:%d/" % (shown, port),
            "serveo": {"url": t["url"], "alive": t.get("alive", True)} if t else None,
            "burrow": {"installed": b.get("installed"), "running": b.get("running"),
                       "tunnel": bt and {k: bt.get(k) for k in ("url", "access", "enabled", "port")}}}


def share(aid, via, on=True, access="login"):
    """Open or drop a serveo link or a Burrow address for an addon's port."""
    rec = get(aid)
    if not rec.get("installed"):
        raise AddonError("Install %s first." % rec["manifest"]["name"])
    st = status(rec, max_age=0)
    port, host = _port(rec, st), _host(rec, st)
    if not port:
        raise AddonError("%s does not say which port it listens on (its status script has no \"port\")."
                         % rec["manifest"]["name"])
    if via == "serveo":
        kill_tunnel(rec.get("tunnel"))
        info = None
        if on:
            try:
                info = tunnel_start("addon-%s" % aid, port, mode="http", record=False, host=host)
            except RuntimeError as ex:
                raise AddonError(str(ex))
        _update(aid, {"tunnel": info, "port": port})
    elif via == "burrow":
        try:
            if on:
                burrow.publish(port, rec["manifest"]["name"], access=access, host=host)
            else:
                burrow.unpublish(port)
        except RuntimeError as ex:
            raise AddonError(str(ex))
        _update(aid, {"port": port})
    else:
        raise AddonError("Share through serveo or burrow.")
    return links(get(aid), status(get(aid), max_age=0))


def _drop_shares(rec, job=None):
    """Uninstalling: its public links would point at nothing."""
    if rec.get("tunnel"):
        kill_tunnel(rec["tunnel"])
    port = rec.get("port")
    if port and burrow.tunnel_for(port, burrow.status(max_age=0)):
        try:
            burrow.unpublish(port)
            if job:
                job.log("removed its Burrow address")
        except RuntimeError:
            pass


# ------------------------------------------------------------------ views
def image(aid, rel=None):
    """(bytes, content type) of the addon's logo, or of an icon its manifest names."""
    rec = get(aid)
    m = rec["manifest"]
    allowed = {m.get("logo")} | {s.get("icon") for s in m["settings"]}
    allowed.discard(None)
    allowed.discard("")
    rel = rel or m.get("logo")
    if not rel or rel not in allowed:
        raise AddonError("no such image")
    with open(os.path.join(root_of(rec), rel), "rb") as fh:
        data = fh.read(MAX_IMAGE + 1)
    return data[:MAX_IMAGE], IMAGE_TYPES[os.path.splitext(rel)[1].lower()]


def public(rec, with_status=False):
    m = rec["manifest"]
    v = rec.get("commit") or str(int(rec.get("updated") or 0))
    settings = []
    for st in m["settings"]:
        cur = (rec.get("settings") or {}).get(st["key"], st.get("default"))
        s2 = dict(st, value=("•" * 8 if cur else "") if st["type"] == "password" else cur)
        if st.get("icon"):
            s2["icon"] = "/api/addons/%s/image?path=%s&v=%s" % (rec["id"], st["icon"], v[:12])
        settings.append(s2)
    out = {
        "id": rec["id"], "name": m["name"], "version": m["version"], "description": m["description"],
        "author": m["author"], "license": m["license"], "homepage": m["homepage"], "links": m["links"],
        "logo": "/api/addons/%s/image?v=%s" % (rec["id"], v[:12]) if m.get("logo") else None,
        "source": rec["source"].get("display"), "commit": rec.get("commit"),
        "added": rec.get("added"), "updated": rec.get("updated"),
        "installed": bool(rec.get("installed")), "installed_version": rec.get("installed_version"),
        "adopted": bool(rec.get("adopted")), "open_url": rec.get("open_url"),
        "detected": rec.get("detected") or {"found": False},
        "settings": settings, "actions": [{"id": a["id"], "label": a["label"], "confirm": a["confirm"]}
                                          for a in m["actions"]],
        "has": {k: k in m["scripts"] for k in SCRIPTS},
        "problems": check_requirements(m),
        "integration": bool(m["integration"]),
    }
    out["update_pending"] = bool(out["installed"] and out["installed_version"]
                                 and out["installed_version"] != m["version"])
    if with_status:
        st = status(rec)
        out["status"] = st
        if st.get("url"):
            out["open_url"] = st["url"]
        if out["installed"]:
            try:
                out["ways"] = links(rec, st)       # "links" is the manifest's doc links
            except Exception:
                out["ways"] = None
    return out


def list_addons(with_status=True):
    recs = sorted(_load().values(), key=lambda r: (not r.get("installed"), r["manifest"]["name"].lower()))
    if not with_status:
        return [public(r) for r in recs]
    out = [None] * len(recs)

    def one(i, r):
        try:
            out[i] = public(r, with_status=True)
        except Exception as ex:
            out[i] = dict(public(r), status={"state": "error", "detail": str(ex)[:200]})
    threads = [threading.Thread(target=one, args=(i, r), daemon=True) for i, r in enumerate(recs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(TIMEOUT["status"] + 5)
    return [o for o in out if o]


# ------------------------------------------------------------------ integrations
def _integration_dirs():
    dirs = []
    for d in KNOWN_INTEGRATION_DIRS:
        full = os.path.expanduser(d)
        if os.path.isdir(os.path.dirname(full)):       # the app is on this machine
            dirs.append(full)
    for rec in _load().values():
        d = (rec.get("manifest") or {}).get("integration", {}).get("dir")
        if rec.get("installed") and d:
            dirs.append(os.path.expanduser(d.replace("$HOME/", "~/", 1)))
    return sorted(set(dirs))


def forge_descriptor():
    url = forge_url()
    if not url:
        return None
    srv = jload(SERVER_JSON, None) or {}
    return {"spec": 1, "id": "selkies-forge", "kind": "selkies-forge", "name": "Selkies Forge",
            "version": VERSION, "url": url, "api": url + "api/", "port": int(srv.get("port") or 0),
            "public_url": srv.get("tunnel") or None, "logo": FORGE_LOGO, "home": ROOT}


def sync_integrations():
    """Tell every app with a drop-in folder where this forge is. Cheap: only
    writes when something changed (and touches the file once an hour)."""
    desc = forge_descriptor()
    if not desc:
        return []
    written = []
    for d in _integration_dirs():
        path = os.path.join(d, "selkies-forge.json")
        try:
            old = jload(path, None) or {}
            fresh = dict(desc, updated=old.get("updated"))
            if old == fresh and time.time() - float(old.get("updated") or 0) < 3600:
                continue
            os.makedirs(d, exist_ok=True)
            fresh["updated"] = int(time.time())
            tmp = "%s.tmp.%d" % (path, os.getpid())
            with open(tmp, "w") as fh:
                json.dump(fresh, fh, indent=2)
            os.replace(tmp, path)
            written.append(path)
        except OSError:
            pass
    return written
