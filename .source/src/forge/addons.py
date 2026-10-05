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
# One addon format for every host. An addon runs on all of them unless its
# manifest names the ones it is made for ("platforms").
PLATFORMS = ("selkies-forge", "burrow")
HOST = "selkies-forge"
SETTING_TYPES = ("text", "number", "bool", "select", "password")
IMAGE_TYPES = {".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp",
               ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}
MAX_IMAGE = 512 * 1024
MAX_MANIFEST = 64 * 1024
TIMEOUT = {"detect": 20, "status": 15, "install": 3600, "update": 3600,
           "uninstall": 900, "action": 900}
ARCH_ALIASES = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64", "armhf": "armv7l"}

# Aegis × Burrow (github.com/alexd-aero/aegis-burrow), and the standalone
# Burrow it grew from, keep their drop-in folders here; the forge registers
# itself whenever either is on this machine, however it got there.
KNOWN_INTEGRATION_DIRS = ("~/.config/burrow/integrations", "~/.config/aegis/integrations")

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
# GitHub and Codeberg: OWNER/REPO/tree|blob/REF[/path]
_HOSTED_TREE = re.compile(
    r"^(https://(?:github\.com|codeberg\.org)/[^/\s]+/[^/\s#]+?)(?:\.git)?"
    r"/(?:tree|blob|src/branch)/([^/\s#]+)(?:/([^#\s]*?))?/?$")
# GitLab, gitlab.com or self-hosted, with subgroups: GROUP/SUB/.../REPO/-/tree|blob/REF[/path]
_GITLAB_TREE = re.compile(r"^(https://[^/\s]+/[^\s#]+?)(?:\.git)?/-/(?:tree|blob)/([^/\s#]+)(?:/([^#\s]*?))?/?$")
# a download: .zip, .tar.gz, .tgz (GitHub's and GitLab's archive links included)
_ARCHIVE = re.compile(r"^https?://[^\s#]+?\.(zip|tar\.gz|tgz)(?:\?[^\s#]*)?$", re.I)
ARCHIVE_MAX = 200 * 1024 * 1024        # bytes downloaded
ARCHIVE_UNPACKED = 500 * 1024 * 1024   # bytes once unpacked
ARCHIVE_FILES = 20000


def parse_source(text):
    """Turn what the person pasted into a fetchable source.

    https://github.com/OWNER/REPO                       the repository's root
    https://github.com/OWNER/REPO/tree/BRANCH/a/folder  a folder on a branch (/blob/ links to a file in it too)
    https://gitlab.com/GROUP/SUB/REPO/-/tree/REF/a/b    GitLab, subgroups and self-hosted instances included
    https://example.com/repo.git#a/folder               any git URL, a folder in it
    https://example.com/addon.zip#a/folder              a .zip, .tar.gz or .tgz download (inspected before use)
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
    if _ARCHIVE.match(url):
        sub = sub.strip("/")
        if sub and (".." in sub.split("/") or not re.match(r"^[A-Za-z0-9._/-]+$", sub)):
            raise AddonError("The folder part of the link is not valid.")
        fmt = "zip" if url.lower().split("?")[0].endswith(".zip") else "tar"
        return {"kind": "archive", "url": url, "format": fmt, "ref": None, "subdir": sub, "display": raw}
    m = _HOSTED_TREE.match(url) or _GITLAB_TREE.match(url)
    if m:
        url, ref = m.group(1), m.group(2)
        sub = sub or (m.group(3) or "")
        if sub == MANIFEST or sub.endswith("/" + MANIFEST):     # a /blob/ link to the manifest itself
            sub = sub[:-len(MANIFEST)]
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


def _safe_member(name):
    n = name.replace("\\", "/")
    return bool(n) and not n.startswith("/") and ".." not in n.split("/") and not re.match(r"^[A-Za-z]:", n)


def fetch_archive(source, dest):
    """Download a .zip or .tar.gz and unpack it into dest, refusing anything
    that could escape it (absolute paths, .., links) or that is too big. A
    single top-level folder (GitHub and GitLab archives have one) is dropped.
    Returns "sha256:<hex>" of the download, which stands in for a commit."""
    import hashlib
    import tarfile
    import urllib.request
    import zipfile
    os.makedirs(dest)
    blob = os.path.join(dest, ".download")
    h = hashlib.sha256()
    req = urllib.request.Request(source["url"], headers={"User-Agent": "selkies-forge/" + VERSION})
    try:
        with urllib.request.urlopen(req, timeout=120) as r, open(blob, "wb") as fh:
            got = 0
            while True:
                chunk = r.read(1 << 16)
                if not chunk:
                    break
                got += len(chunk)
                if got > ARCHIVE_MAX:
                    raise AddonError("The archive is larger than %d MB." % (ARCHIVE_MAX >> 20))
                h.update(chunk)
                fh.write(chunk)
    except AddonError:
        raise
    except Exception as ex:
        raise AddonError("Could not download %s: %s" % (source["display"], ex))
    out = os.path.join(dest, ".unpacked")
    os.makedirs(out)
    total = 0
    try:
        if zipfile.is_zipfile(blob):
            with zipfile.ZipFile(blob) as z:
                infos = z.infolist()
                if len(infos) > ARCHIVE_FILES:
                    raise AddonError("The archive holds more than %d files." % ARCHIVE_FILES)
                for i in infos:
                    if not _safe_member(i.filename):
                        raise AddonError("The archive has an unsafe path: %s" % i.filename[:120])
                    if (i.external_attr >> 16) & 0o170000 == 0o120000:
                        continue                                  # links are not unpacked
                    total += i.file_size
                    if total > ARCHIVE_UNPACKED:
                        raise AddonError("The archive unpacks to more than %d MB." % (ARCHIVE_UNPACKED >> 20))
                    z.extract(i, out)
        else:
            with tarfile.open(blob) as t:
                members = t.getmembers()
                if len(members) > ARCHIVE_FILES:
                    raise AddonError("The archive holds more than %d files." % ARCHIVE_FILES)
                keep = []
                for mem in members:
                    if not _safe_member(mem.name):
                        raise AddonError("The archive has an unsafe path: %s" % mem.name[:120])
                    if mem.isfile() or mem.isdir():
                        total += mem.size
                        keep.append(mem)
                if total > ARCHIVE_UNPACKED:
                    raise AddonError("The archive unpacks to more than %d MB." % (ARCHIVE_UNPACKED >> 20))
                t.extractall(out, members=keep, filter="data")
    except (zipfile.BadZipFile, tarfile.TarError, EOFError) as ex:
        raise AddonError("That is not a valid .zip or .tar.gz archive: %s" % ex)
    os.remove(blob)
    root = out
    names = os.listdir(out)
    if len(names) == 1 and os.path.isdir(os.path.join(out, names[0])) and not os.path.isfile(os.path.join(out, MANIFEST)):
        root = os.path.join(out, names[0])
    for n in os.listdir(root):
        os.rename(os.path.join(root, n), os.path.join(dest, n))
    shutil.rmtree(out, ignore_errors=True)
    return "sha256:" + h.hexdigest()


def fetch(source, dest):
    """Put the source's files in dest (a new folder). Returns the commit, if any
    ("sha256:…" of the download, for an archive)."""
    if source["kind"] == "archive":
        return fetch_archive(source, dest)
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

    plats = d.get("platforms")
    if plats is None:
        m["platforms"] = list(PLATFORMS)
    else:
        if not isinstance(plats, list) or not plats or not all(isinstance(x, str) for x in plats):
            raise AddonError("\"platforms\" must be a list, e.g. [\"selkies-forge\", \"burrow\"]")
        bad = [x for x in plats if x not in PLATFORMS]
        if bad:
            raise AddonError("unknown platform \"%s\" (known: %s)" % (bad[0], ", ".join(PLATFORMS)))
        m["platforms"] = [x for x in PLATFORMS if x in plats]

    req = d.get("requires") or {}
    if not isinstance(req, dict):
        raise AddonError("\"requires\" must be an object")
    m["requires"] = {
        "forge": str(req.get("forge") or "").strip(),
        "burrow": str(req.get("burrow") or "").strip(),
        "os": [str(x).lower() for x in req.get("os") or []],
        "arch": [ARCH_ALIASES.get(str(x).lower(), str(x).lower()) for x in req.get("arch") or []],
        "commands": [str(x) for x in req.get("commands") or [] if re.match(r"^[A-Za-z0-9._+-]+$", str(x))],
    }
    for host in ("forge", "burrow"):
        if m["requires"][host] and not re.match(r"^(>=)?\s*\d+(\.\d+){0,2}$", m["requires"][host]):
            raise AddonError("requires.%s must look like \">=1.10.0\"" % host)

    integ = d.get("integration") or {}
    m["integration"] = {}
    if integ:
        p = str(integ.get("dir") or "")
        if not (p.startswith("~/") or p.startswith("$HOME/")) or ".." in p.split("/"):
            raise AddonError("integration.dir must be a folder under ~/ (e.g. ~/.config/myapp/integrations)")
        m["integration"] = {"dir": p}

    rep = d.get("replaces") or []
    if not isinstance(rep, list) or len(rep) > 8 or not all(isinstance(x, str) and ID_RE.match(x) for x in rep):
        raise AddonError("\"replaces\" must be a list of addon ids, e.g. [\"old-name\"]")
    m["replaces"] = [x for x in rep if x != m["id"]]

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
    if HOST not in m.get("platforms", PLATFORMS):
        out.append("is made for %s, not Selkies Forge" % " and ".join(
            {"burrow": "Burrow"}.get(p, p) for p in m["platforms"]))
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
    # The universal names every host sets (FORGE_ADDON_* stay for older scripts).
    for k in [k for k in env if k.startswith("FORGE_ADDON_")]:
        env["ADDON_" + k[len("FORGE_ADDON_"):]] = env[k]
    env.update({"ADDON_HOST": HOST, "ADDON_HOST_VERSION": VERSION, "ADDON_HOST_URL": url or "",
                "ADDON_BIND": env["FORGE_BIND"]})
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
        if isinstance(info.get("name"), str) and info["name"].strip():
            st["name"] = info["name"].strip()[:60]        # e.g. "Aegis × Burrow" while its module is on
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


def inspect(text):
    """Look at an addon without adding it or running anything: fetch it to a
    scratch folder, validate forge-addon.json, and return its metadata."""
    import base64
    source = parse_source(text)
    ensure_dirs()
    os.makedirs(ADDONDIR, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".inspect-", dir=ADDONDIR)
    try:
        commit = fetch(source, os.path.join(tmp, "repo"))
        root = os.path.join(tmp, "repo", source.get("subdir") or "")
        if not os.path.isdir(root):
            raise AddonError("There is no folder %s in it." % source["subdir"])
        m = load_manifest(root)
        logo = None
        if m.get("logo"):
            p = os.path.join(root, m["logo"])
            if os.path.getsize(p) <= 65536:
                with open(p, "rb") as fh:
                    logo = "data:%s;base64,%s" % (IMAGE_TYPES[os.path.splitext(p)[1].lower()], base64.b64encode(fh.read()).decode())
        files = sum(len(f) for _, _, f in os.walk(root))
        return {"valid": True, "source": {k: source.get(k) for k in ("kind", "url", "ref", "subdir", "display", "format")},
                "commit": commit, "manifest": {k: m[k] for k in ("id", "name", "version", "description", "author", "license",
                                                                 "homepage", "platforms", "replaces", "requires", "links")},
                "scripts": sorted(m["scripts"]), "actions": [a["label"] for a in m["actions"]],
                "settings": [st["key"] for st in m["settings"]], "integration": m["integration"].get("dir"),
                "logo": logo, "files": files, "problems": check_requirements(m),
                "registered": m["id"] in _load()}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
    rec = _update(aid, {"manifest": m, "commit": commit, "updated": time.time(), "remote": None})
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


def check_updates(aid):
    """Is there newer code than what this addon was fetched at?

    For a git source: fetch the newest commit (shallow, no file contents) into
    the addon's checkout and compare. When the link points at a folder, only
    commits that touch that folder count; a repository that moved on
    elsewhere is still "up to date". Nothing is installed or changed.
    """
    rec = get(aid)
    src = rec["source"]
    m = rec["manifest"]
    out = {"id": aid, "name": m["name"], "kind": src["kind"], "source": src.get("display"),
           "checked": time.time(), "local": {"commit": rec.get("commit"), "version": m["version"],
                                             "installed_version": rec.get("installed_version")}}
    if src["kind"] == "archive":
        # download it again: the same bytes mean nothing changed
        tmp = tempfile.mkdtemp(prefix=".chk-", dir=ADDONDIR)
        try:
            digest = fetch_archive(src, os.path.join(tmp, "x"))
            same = digest == rec.get("commit")
            out["remote"] = {"commit": digest, "short": digest[7:14], "subject": "a new archive"}
            try:
                out["remote"]["version"] = load_manifest(os.path.join(tmp, "x", rec.get("subdir") or ""))["version"]
            except AddonError:
                out["remote"]["version"] = ""
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        out["up_to_date"] = same
        out["note"] = "Checked by downloading the archive again." if same else "The archive at that link has changed."
        _update(aid, {"remote": {"checked": out["checked"], "up_to_date": same, "commit": digest,
                                 "version": out["remote"]["version"], "subject": "a new archive"}})
        sync_integrations()
        return out
    if src["kind"] != "git":
        out.update(up_to_date=None, note="This addon was added from a folder on this machine. "
                                         "Update copies the folder again.")
        return out
    repo = os.path.join(addon_dir(aid), "repo")
    if not os.path.isdir(os.path.join(repo, ".git")):
        raise AddonError("Its checkout has no git history. Remove it and add it again.")
    ref = src.get("ref") or "HEAD"
    rc, _, err = _git(["fetch", "--quiet", "--depth", "40", "--filter=blob:none", "origin", ref], cwd=repo, timeout=90)
    if rc != 0:
        msg = (err.strip().splitlines() or ["git fetch failed"])[-1]
        raise AddonError("Could not reach %s: %s" % (src.get("display"), msg))
    rc, remote, _ = _git(["rev-parse", "FETCH_HEAD"], cwd=repo, timeout=20)
    remote = remote.strip()
    local = rec.get("commit") or ""
    sub = (rec.get("subdir") or "").strip("/")

    def info(sha):
        rc, o, _ = _git(["log", "-1", "--format=%H%x09%ct%x09%an%x09%s", sha], cwd=repo, timeout=20)
        if rc != 0 or "\t" not in o:
            return {"commit": sha, "short": sha[:7]}
        h, ct, an, subj = (o.strip().split("\t", 3) + ["", "", ""])[:4]
        return {"commit": h, "short": h[:7], "date": int(ct or 0), "author": an, "subject": subj}

    out["remote"] = info(remote)
    out["local"].update({k: v for k, v in info(local).items() if k != "commit"} if local else {})
    if local:
        out["local"]["short"] = local[:7]
    same = remote == local
    if not same and sub and local:
        # the folder's tree on both sides: equal means nothing in this addon changed
        r1, t1, _ = _git(["rev-parse", "%s:%s" % (remote, sub)], cwd=repo, timeout=20)
        r2, t2, _ = _git(["rev-parse", "%s:%s" % (local, sub)], cwd=repo, timeout=20)
        if r1 == 0 and r2 == 0 and t1.strip() == t2.strip():
            same = True
            out["note"] = "The repository has newer commits, but none of them touch this addon."
    out["up_to_date"] = same
    if not same:
        args = ["log", "--format=%H%x09%ct%x09%an%x09%s", "-n", "30", remote]
        if sub:
            args += ["--", sub]
        rc, o, _ = _git(args, cwd=repo, timeout=30)
        commits = []
        for line in o.splitlines():
            h, ct, an, subj = (line.split("\t", 3) + ["", "", ""])[:4]
            if h == local:
                break
            commits.append({"commit": h, "short": h[:7], "date": int(ct or 0), "author": an, "subject": subj})
        out["commits"] = commits[:20]
        out["more"] = len(commits) > 20
        if commits:
            out["remote"] = commits[0]          # the newest commit that changes this addon
        mpath = (sub + "/" if sub else "") + MANIFEST
        rc, mj, _ = _git(["show", "%s:%s" % (remote, mpath)], cwd=repo, timeout=60)
        try:
            out["remote"]["version"] = str(json.loads(mj).get("version") or "")[:30] if rc == 0 else ""
        except ValueError:
            out["remote"]["version"] = ""
    _update(aid, {"remote": {"checked": out["checked"], "up_to_date": out["up_to_date"],
                             "commit": out.get("remote", {}).get("commit"), "version": out.get("remote", {}).get("version"),
                             "subject": (out.get("remote", {}).get("subject") or "")[:160]}})
    sync_integrations()                 # an app showing its own addon state sees it now
    return out


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
    sync_integrations()
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
        "platforms": m.get("platforms") or list(PLATFORMS),
        "remote": rec.get("remote"),
    }
    out["update_pending"] = bool(out["installed"] and out["installed_version"]
                                 and out["installed_version"] != m["version"])
    if with_status:
        st = status(rec)
        out["status"] = st
        if st.get("url"):
            out["open_url"] = st["url"]
        if st.get("name") and out["installed"]:
            out["name"] = st["name"]
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


# ------------------------------------------------------------------ the smart scan
#
# Addons already on this machine, in any folder: a checkout you cloned, an app
# that installed itself, another host's copy. Anything with a valid
# forge-addon.json counts. Each one's detect script says whether the app is
# installed, and its status script whether it runs; both are read-only by the
# spec and are given a scratch data folder, so a scan never changes anything.

SCAN_SKIP = {"node_modules", "__pycache__", ".git", ".cache", ".npm", ".nvm", ".cargo", ".rustup", ".local/lib",
             "snap", "venv", ".venv", "site-packages", "proc", "sys", "dev", ".mozilla", ".config/chromium",
             "go", ".gradle", ".m2", ".docker", "Downloads", "builds", "logs"}
SCAN_HIDDEN_OK = {".local", ".selkies-forge", ".config", ".share"}
_SCAN = {"at": 0.0, "value": None}


def _scan_roots():
    home = os.path.expanduser("~")
    roots = [(home, 4), ("/opt", 3), ("/srv", 3)]
    # apps that say where their code is (~/.config/<app>/<app>.json, "code": ...)
    cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    try:
        for app in os.listdir(cfg):
            d = jload(os.path.join(cfg, app, app + ".json"), None)
            if isinstance(d, dict) and isinstance(d.get("code"), str):
                roots.append((d["code"], 1))
    except OSError:
        pass
    return roots


def _find_manifests(budget=25000, seconds=4.0):
    found, seen, t0 = [], set(), time.time()
    for root, depth in _scan_roots():
        stack = [(os.path.realpath(root), 0)]
        while stack and budget > 0 and time.time() - t0 < seconds:
            d, lvl = stack.pop()
            if d in seen:
                continue
            seen.add(d)
            budget -= 1
            try:
                names = os.listdir(d)
            except OSError:
                continue
            if MANIFEST in names:
                found.append(d)
            if lvl >= depth:
                continue
            for n in names:
                if n in SCAN_SKIP or (n.startswith(".") and n not in SCAN_HIDDEN_OK):
                    continue
                p = os.path.join(d, n)
                if os.path.isdir(p) and not os.path.islink(p):
                    stack.append((p, lvl + 1))
    return found


def _git_source(path):
    """A link the forge can fetch (and later update) for a checkout at path, or the folder itself."""
    rc, top, _ = _git(["rev-parse", "--show-toplevel"], cwd=path, timeout=10) if have("git") else (1, "", "")
    if rc == 0:
        rc2, url, _ = _git(["remote", "get-url", "origin"], cwd=path, timeout=10)
        url = url.strip()
        if rc2 == 0 and re.match(r"^https://\S+$", url):
            url = re.sub(r"\.git$", "", url)
            sub = os.path.relpath(path, top.strip())
            if sub in (".", ""):
                return url
            rc3, br, _ = _git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=path, timeout=10)
            return "%s/tree/%s/%s" % (url, br.strip() or "main", sub) if re.match(r"^https://(github|gitlab)\.com/", url) \
                else "%s#%s" % (url, sub)
    return path


def _probe(root, m):
    """detect, then status, from a found folder (scratch data dir, nothing kept)."""
    rec = {"id": m["id"], "manifest": m, "subdir": "", "settings": {}}
    scratch = tempfile.mkdtemp(prefix=".scan-", dir=ADDONDIR)
    env = {"FORGE_ADDON_DIR": root, "FORGE_ADDON_DATA": scratch, "FORGE_ADDON_SCAN": "1"}
    out = {"found": False, "state": None}
    try:
        for key in ("detect", "status"):
            s = m["scripts"].get(key)
            if not s or (key == "status" and not out["found"]):
                continue
            p = subprocess.run(["bash", os.path.join(root, s)], cwd=root, env=script_env_at(rec, root, env),
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=TIMEOUT[key], start_new_session=True)
            info = _last_json(p.stdout.decode("utf-8", "replace").splitlines())
            if key == "detect":
                out["found"] = p.returncode == 0
                out.update({k: str(info.get(k) or "")[:200] for k in ("version", "url", "detail")})
            else:
                out["state"] = str(info.get("state") or "")[:20] or None
                if isinstance(info.get("name"), str):
                    out["name"] = info["name"][:60]
    except (OSError, subprocess.TimeoutExpired):
        pass
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return out


def script_env_at(rec, root, extra):
    """script_env for a folder that is not (yet) one of ours."""
    m = rec["manifest"]
    env = dict(os.environ)
    url = forge_url()
    env.update({"FORGE_ADDON_SPEC": str(SPEC), "FORGE_ADDON_ID": m["id"], "FORGE_ADDON_NAME": m["name"],
                "FORGE_ADDON_VERSION": m["version"], "FORGE_HOME": ROOT, "FORGE_VERSION": VERSION,
                "FORGE_URL": url or "", "FORGE_API": (url + "api/") if url else "",
                "FORGE_ADDON_ADOPT": "0", "FORGE_ADDON_UPDATE": "0"})
    for st in m["settings"]:
        v = st.get("default")
        env["FORGE_ADDON_SETTING_" + st["key"]] = ("1" if v else "0") if st["type"] == "bool" else ("" if v is None else str(v))
    env.update(extra)
    for k in [k for k in env if k.startswith("FORGE_ADDON_")]:
        env["ADDON_" + k[len("FORGE_ADDON_"):]] = env[k]
    env.update({"ADDON_HOST": HOST, "ADDON_HOST_VERSION": VERSION, "ADDON_HOST_URL": url or ""})
    return env


def scan(max_age=60.0):
    """Every addon on this machine, one entry per id:
    {id, name, version, description, logo, platforms, compatible, problems,
     registered, installed, found, state, source, locations, error}"""
    if _SCAN["value"] is not None and time.time() - _SCAN["at"] < max_age:
        return _SCAN["value"]
    ensure_dirs()
    os.makedirs(ADDONDIR, exist_ok=True)
    mine = os.path.realpath(ADDONDIR) + os.sep
    reg = _load()
    by_id, broken = {}, []
    for d in _find_manifests():
        if (os.path.realpath(d) + os.sep).startswith(mine) or os.path.basename(d).startswith(".scan-"):
            continue                                  # our own checkouts: already in the list
        try:
            m = load_manifest(d)
        except AddonError as ex:
            broken.append({"path": d, "error": str(ex)})
            continue
        if m["id"] == "selkies-forge":
            continue                                  # the forge itself (an addon for Burrow)
        by_id.setdefault(m["id"], []).append((d, m))
    # an addon that replaces older ones (renamed, merged) hides them
    gone = set()
    for places in by_id.values():
        for _, m in places:
            gone.update(m.get("replaces") or [])
    for rec in reg.values():
        gone.update((rec.get("manifest") or {}).get("replaces") or [])
    for aid in [a for a in by_id if a in gone]:
        del by_id[aid]
    out = []
    lock = threading.Lock()

    def one(aid, places):
        # the newest version wins; a git checkout (updatable) beats a plain copy
        places.sort(key=lambda p: (version_tuple(p[1]["version"]), os.path.isdir(os.path.join(p[0], ".git"))), reverse=True)
        d, m = places[0]
        probe = _probe(d, m)
        logo = None
        if m.get("logo") and m["logo"].endswith(".svg") and os.path.getsize(os.path.join(d, m["logo"])) <= 65536:
            with open(os.path.join(d, m["logo"]), "rb") as fh:
                import base64
                logo = "data:image/svg+xml;base64," + base64.b64encode(fh.read()).decode()
        rec = reg.get(aid) or {}
        if rec.get("installed"):                     # ours already: what the forge knows
            st = status(rec)
            probe = {"found": True, "state": st.get("state"), "version": rec.get("installed_version"),
                     "name": st.get("name"), "detail": st.get("detail")}
        e = {"id": aid, "name": probe.get("name") or m["name"], "version": m["version"],
             "description": m["description"][:300], "logo": logo,
             "platforms": m["platforms"], "compatible": HOST in m["platforms"], "problems": check_requirements(m),
             "registered": bool(rec), "installed": bool(rec.get("installed")),
             "found": probe["found"], "installed_version": probe.get("version") or None,
             "state": probe["state"], "detail": probe.get("detail") or "",
             "source": _git_source(d), "locations": [p[0] for p in places]}
        with lock:
            out.append(e)

    threads = [threading.Thread(target=one, args=(k, v), daemon=True) for k, v in by_id.items()]
    for t in threads:
        t.start()
    for t in threads:
        t.join(40)
    out.sort(key=lambda e: (not e["compatible"], e["registered"], not e["found"], e["name"].lower()))
    value = {"scanned": time.time(), "addons": out, "broken": broken[:20]}
    _SCAN.update(at=time.time(), value=value)
    return value


def forget_scan():
    _SCAN.update(at=0.0, value=None)


# ------------------------------------------------------------------ integrations
def _integration_dirs():
    dirs = []
    for d in KNOWN_INTEGRATION_DIRS:
        full = os.path.expanduser(d)
        if os.path.isdir(os.path.dirname(full)):       # the app is on this machine
            dirs.append(full)
    for rec in _load().values():
        d = (rec.get("manifest") or {}).get("integration", {}).get("dir")
        if not d:
            continue
        full = os.path.expanduser(d.replace("$HOME/", "~/", 1))
        # installed, or uninstalled with its folder still there (it learns it is no longer an addon)
        if rec.get("installed") or os.path.isdir(full):
            dirs.append(full)
    return sorted(set(dirs))


def _addon_for_dir(d):
    """The installed addon that owns integration folder d: how this forge runs
    it, for that app to show (Aegis × Burrow's Burrow → Addon tab)."""
    url = forge_url()
    for rec in _load().values():
        idir = (rec.get("manifest") or {}).get("integration", {}).get("dir")
        if not rec.get("installed") or not idir:
            continue
        if os.path.expanduser(idir.replace("$HOME/", "~/", 1)) != d:
            continue
        m, rem = rec["manifest"], rec.get("remote") or {}
        with _STATUS_LOCK:
            hit = _STATUS.get(rec["id"])           # never run the status script from here
        return {"id": rec["id"], "name": m["name"], "version": rec.get("installed_version") or m["version"],
                "commit": rec.get("commit"), "source": (rec.get("source") or {}).get("display"),
                "adopted": bool(rec.get("adopted")), "installed_at": int(rec.get("installed_at") or 0),
                "state": hit[1].get("state") if hit else None, "checked_at": int(rem.get("checked") or 0) or None,
                "update": ({"available": rem.get("up_to_date") is False, "commit": rem.get("commit"),
                            "version": rem.get("version"), "subject": rem.get("subject")} if rem else None),
                "page": (url + "#addons/" + rec["id"]) if url else None}
    return None


def forge_descriptor(d=None):
    url = forge_url()
    if not url:
        return None
    srv = jload(SERVER_JSON, None) or {}
    out = {"spec": 1, "id": "selkies-forge", "kind": "selkies-forge", "name": "Selkies Forge",
           "version": VERSION, "url": url, "api": url + "api/", "port": int(srv.get("port") or 0),
           "public_url": srv.get("tunnel") or None, "logo": FORGE_LOGO, "home": ROOT}
    if d:
        out["addon"] = _addon_for_dir(d)
    return out


def sync_integrations():
    """Tell every app with a drop-in folder where this forge is. Cheap: only
    writes when something changed (and touches the file once an hour)."""
    if not forge_url():
        return []
    written = []
    for d in _integration_dirs():
        path = os.path.join(d, "selkies-forge.json")
        try:
            old = jload(path, None) or {}
            fresh = dict(forge_descriptor(d), updated=old.get("updated"))
            mine, was = fresh.get("addon"), old.get("addon") or {}
            if mine and mine.get("state") is None and was.get("id") == mine["id"]:
                mine["state"] = was.get("state")      # status not asked lately: keep the last known one
            loose = os.path.exists(path) and os.stat(path).st_mode & 0o022
            if old == fresh and time.time() - float(old.get("updated") or 0) < 3600 and not loose:
                continue
            os.makedirs(d, exist_ok=True)
            fresh["updated"] = int(time.time())
            tmp = "%s.tmp.%d" % (path, os.getpid())
            with open(tmp, "w") as fh:
                json.dump(fresh, fh, indent=2)
            os.chmod(tmp, 0o644)                    # the bridge check insists: only we may write it
            os.replace(tmp, path)
            written.append(path)
        except OSError:
            pass
    return written
