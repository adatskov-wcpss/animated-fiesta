"""
Selkies Forge engine - updates

Self-update from GitHub (git fast-forward, never backwards).
"""

import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from .paths import APPDIR, LOGDIR, ROOT, STATE, UPDATE_JSON, VERSION
from .util import FileLock, have, jload, jsave, run


UPDATE_URL_DEFAULT = "https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh"
UPDATE_EVERY = int(os.environ.get("FORGE_UPDATE_EVERY") or 300)
SERVE_PAYLOAD = None            # what this web UI process was started from


def installed_payload():
    try:
        with open(os.path.join(APPDIR, ".payload")) as fh:
            return fh.read().strip() or None
    except Exception:
        return None


def installed_version():
    """FORGE_VERSION of the build that is actually installed (not this process)."""
    try:
        with open(os.path.join(APPDIR, "selkies-cli")) as fh:
            for line in fh:
                if line.startswith("FORGE_VERSION="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return VERSION


def _vtuple(v):
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:4]) or (0,)


def auto_update_enabled():
    return os.environ.get("FORGE_AUTO_UPDATE", "1") != "0"


REPO_URL_DEFAULT = "https://github.com/adatskov-wcpss/animated-fiesta.git"
REPO_BRANCH = os.environ.get("FORGE_BRANCH") or "main"
REPO_DIR = os.path.join(ROOT, "repo")


def check_update(install=True, max_age=0, timeout=20):
    """Is there a newer Selkies Forge?  Install it if asked.

    The normal path is a git clone of the repo that only ever fast-forwards
    (a "git pull --ff-only"): it talks to GitHub's git servers directly, so
    there is no cache lag, and it can never move backwards.  Without git it
    falls back to downloading docker.sh, newer versions only.
    """
    with FileLock("update", timeout=300):
        st = jload(UPDATE_JSON, {})
        if max_age and time.time() - float(st.get("checked_at") or 0) < max_age:
            st["just_installed"] = False
            return st
        st.update(checked_at=time.time(), error=None, just_installed=False)
        if have("git") and not os.environ.get("FORGE_URL"):
            _check_git(st, install)
        else:
            _check_download(st, install, timeout)
        st["installed_version"] = installed_version()
        jsave(UPDATE_JSON, {k: v for k, v in st.items() if k != "just_installed"})
        return st


def _git(*args, **kw):
    return run(["git", "-C", REPO_DIR] + list(args), timeout=kw.get("timeout", 120))


def _payload_and_version(txt):
    m = re.search(r'^FORGE_PAYLOAD_SHA="([0-9a-f]{64})"', txt or "", re.M)
    v = re.search(r'^FORGE_VERSION="([^"]+)"', txt or "", re.M)
    return (m.group(1) if m else None), (v.group(1) if v else None)


def _check_git(st, install):
    url = os.environ.get("FORGE_REPO") or REPO_URL_DEFAULT
    st["method"] = "git"
    st["url"] = url
    # Our own private clone; re-clone if it is missing or points elsewhere.
    ok = os.path.isdir(os.path.join(REPO_DIR, ".git"))
    if ok:
        rc, out, _ = _git("remote", "get-url", "origin", timeout=20)
        ok = rc == 0 and out.strip() == url
        if not ok:
            shutil.rmtree(REPO_DIR, ignore_errors=True)
    if not ok:
        rc, _, err = run(["git", "clone", "--quiet", "--single-branch", "--branch", REPO_BRANCH,
                          url, REPO_DIR], timeout=600)
        if rc != 0:
            st["error"] = "git clone failed: %s" % (err.strip().splitlines() or ["?"])[-1][:160]
            return
        st.pop("installed_commit", None)

    rc, _, err = _git("fetch", "--quiet", "origin", REPO_BRANCH, timeout=180)
    if rc != 0:
        st["error"] = "git fetch failed: %s" % (err.strip().splitlines() or ["?"])[-1][:160]
        return
    rc, out, _ = _git("rev-parse", "FETCH_HEAD", timeout=20)
    remote = out.strip()
    rc, txt, _ = _git("show", "%s:docker.sh" % remote, timeout=60)
    remote_sha, remote_version = _payload_and_version(txt if rc == 0 else "")
    if not remote_sha:
        st["error"] = "docker.sh in %s does not look like Selkies Forge" % url
        return
    st.update(remote_commit=remote, remote_sha=remote_sha, remote_version=remote_version)

    local = installed_payload()
    mine = st.get("installed_commit")
    if remote_sha == local:
        st["available"] = False
        st["installed_commit"] = remote          # in step with GitHub
    elif mine and mine != remote:
        # A fast-forward only: the installed commit must be in GitHub's history.
        rc, _, _ = _git("merge-base", "--is-ancestor", mine, remote, timeout=30)
        # If history was rewritten, still take a release whose version is
        # genuinely higher; otherwise one force-push would freeze updates.
        higher = _vtuple(remote_version) > _vtuple(installed_version())
        st["available"] = rc == 0 or higher
        if not st["available"]:
            st["error"] = ("GitHub's history no longer contains the installed commit; "
                           "not following it backwards")
    else:
        # First check after installing from a downloaded script: we don't know
        # which commit that was, so only a higher version counts as newer.
        st["available"] = _vtuple(remote_version) > _vtuple(installed_version())

    if not (st["available"] and install and auto_update_enabled()):
        return
    # The "git pull": fast-forward our clone, then install from it.
    rc, _, err = _git("merge", "--ff-only", "--quiet", remote, timeout=120)
    if rc != 0:
        _git("checkout", "--quiet", "-B", REPO_BRANCH, remote, timeout=120)
    _install_update(st, os.path.join(REPO_DIR, "docker.sh"))
    if st.get("just_installed"):
        st["installed_commit"] = remote


def _check_download(st, install, timeout):
    """Fallback without git: fetch docker.sh itself (ETag keeps repeats cheap)."""
    url = os.environ.get("FORGE_URL") or UPDATE_URL_DEFAULT
    st["method"] = "download"
    headers = {"User-Agent": "selkies-forge/" + VERSION}
    dl = os.path.join(STATE, "update-docker.sh")
    if st.get("etag") and st.get("url") == url and os.path.exists(dl):
        headers["If-None-Match"] = st["etag"]
    st["url"] = url
    body = None
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            st["etag"] = r.headers.get("ETag")
    except urllib.error.HTTPError as ex:
        if ex.code != 304:
            st["error"] = "GitHub answered HTTP %s" % ex.code
    except Exception as ex:
        st["error"] = "could not reach GitHub (%s)" % type(ex).__name__
    if body:
        txt = body.decode("utf-8", "replace")
        m = re.search(r'^FORGE_PAYLOAD_SHA="([0-9a-f]{64})"', txt, re.M)
        v = re.search(r'^FORGE_VERSION="([^"]+)"', txt, re.M)
        if m:
            with open(dl, "wb") as fh:
                fh.write(body)
            st["remote_sha"] = m.group(1)
            st["remote_version"] = v.group(1) if v else None
        else:
            st["error"] = "the file on GitHub does not look like Selkies Forge"
    local = installed_payload()
    st["installed_sha"] = local
    st["installed_version"] = installed_version()
    # Only ever move forward. GitHub's raw cache can serve an older copy for
    # a few minutes after a push, and "different" must not mean "install".
    newer = _vtuple(st.get("remote_version")) > _vtuple(st["installed_version"])
    st["available"] = bool(st.get("remote_sha") and local and
                           st["remote_sha"] != local and newer)
    if st["available"] and install and auto_update_enabled():
        _install_update(st, dl)


def _install_update(st, path):
    rc, _, _ = run(["bash", "-n", path], timeout=60)
    if rc != 0:
        st["error"] = "the downloaded update does not parse; skipped"
        return
    env = dict(os.environ, FORGE_HOME=ROOT)
    env.pop("FORGE_AS_CLI", None)
    with open(os.path.join(LOGDIR, "update.log"), "ab") as log:
        log.write(("\n--- %s installing %s\n" % (time.ctime(), st.get("remote_version"))).encode())
        log.flush()
        try:
            rc = subprocess.call(["bash", path, "--setup", "--yes"], stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, env=env, timeout=900)
        except Exception as ex:
            rc = 1
            log.write(("install crashed: %s\n" % ex).encode())
    if rc == 0 and installed_payload() == st.get("remote_sha"):
        st.update(available=False, just_installed=True, installed_at=time.time(),
                  installed_version=st.get("remote_version"), installed_sha=st.get("remote_sha"))
    else:
        st["error"] = "the update did not install cleanly; see logs/update.log"


def update_report():
    st = jload(UPDATE_JSON, {})
    running = SERVE_PAYLOAD
    installed = installed_payload()
    return {"running_version": VERSION, "auto": auto_update_enabled(),
            "checked_at": st.get("checked_at"), "available": bool(st.get("available")),
            "remote_version": st.get("remote_version"),
            "installed_version": installed_version(),
            "installed_at": st.get("installed_at"), "error": st.get("error"),
            "restart_needed": bool(running and installed and running != installed),
            "method": st.get("method"), "commit": (st.get("installed_commit") or "")[:7],
            "every_s": UPDATE_EVERY}


def _update_loop():
    time.sleep(min(30, UPDATE_EVERY))
    while True:
        try:
            check_update(install=True)
        except Exception:
            pass
        time.sleep(UPDATE_EVERY)


def restart_webui_detached():
    """Ask selkies-cli to restart us on the same port; it outlives this process."""
    cli = os.path.join(APPDIR, "selkies-cli")
    # FORGE_JUST_UPDATED only stops the CLI re-checking during the restart; it
    # must not be FORGE_AUTO_UPDATE=0, which the new server would inherit.
    env = dict(os.environ, FORGE_HOME=ROOT, FORGE_AS_CLI="1", FORGE_JUST_UPDATED="1",
               FORGE_STOP_REASON="update")
    with open(os.path.join(LOGDIR, "restart.log"), "ab") as log:
        subprocess.Popen(["bash", cli, "restart"], stdin=subprocess.DEVNULL, stdout=log,
                         stderr=subprocess.STDOUT, env=env, start_new_session=True)
