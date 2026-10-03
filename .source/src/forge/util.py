"""
Selkies Forge engine - util

Small helpers: JSON state files, file locks, running commands, formatting.
"""

import fcntl
import json
import os
import re
import shutil
import subprocess
import time

from .paths import BUILDDIR, CACHE_JSON, JOBLOGDIR, JOBSTATEDIR, LOGDIR, ROOT, STATE


def ensure_dirs():
    for d in (ROOT, STATE, LOGDIR, JOBLOGDIR, BUILDDIR, JOBSTATEDIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


class FileLock(object):
    """A named cross-process lock (fcntl), shared by the web UI and the CLI.

    Used for port allocation, the instance registry, updates, and per-desktop
    operations, so two actions never race on the same thing.
    """

    def __init__(self, name, timeout=30.0):
        ensure_dirs()
        self.path = os.path.join(STATE, name + ".lock")
        self.timeout = timeout
        self.fh = None

    def __enter__(self):
        self.fh = open(self.path, "a+")
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except (IOError, OSError):
                if time.time() > deadline:
                    raise RuntimeError("timed out waiting for lock %s" % self.path)
                time.sleep(0.05)

    def __exit__(self, *a):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        finally:
            self.fh.close()
            self.fh = None


def jload(path, default=None):
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except Exception:
        return {} if default is None else default


def jsave(path, obj):
    ensure_dirs()
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


# Docker commands that only read state, so they are safe to repeat.
_DOCKER_READS = {"inspect", "ps", "images", "image", "stats", "info", "version", "logs",
                 "manifest", "volume", "system", "port", "top", "history"}
# The daemon briefly not answering (restarting, overloaded), as opposed to a
# real error about the thing we asked for.
_DOCKER_FLAKY = re.compile(r"cannot connect to the docker daemon|is the docker daemon running|"
                           r"daemon is not running|connection refused|i/o timeout|"
                           r"context deadline exceeded|connection reset by peer|"
                           r"error during connect|EOF$", re.I | re.M)


def _run_once(cmd, timeout, env):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout


def run(cmd, timeout=60, env=None, retries=None):
    """Return (rc, stdout, stderr); never raises for a non-zero exit.

    Read-only docker commands are retried (1s, 2s, 4s) when the daemon itself
    is briefly unreachable, so a Docker restart or a load spike does not turn
    into "your desktop is gone" in the UI. Commands that change something are
    never repeated behind your back unless the caller asks with retries=N.
    """
    if retries is None:
        retries = 3 if (len(cmd) > 1 and os.path.basename(cmd[0]) == "docker"
                        and cmd[1] in _DOCKER_READS) else 0
    delay = 1.0
    for attempt in range(retries + 1):
        rc, out, err = _run_once(cmd, timeout, env)
        if rc == 0 or attempt == retries or not _DOCKER_FLAKY.search(err or ""):
            return rc, out, err
        time.sleep(delay)
        delay *= 2
    return rc, out, err


def have(prog):
    return shutil.which(prog) is not None


def human(n, unit="B"):
    n = float(n or 0)
    for suf in ("", "K", "M", "G", "T"):
        if abs(n) < 1024.0:
            return "%.0f%s%s" % (n, suf, unit) if suf == "" else "%.1f%s%s" % (n, suf, unit)
        n /= 1024.0
    return "%.1fP%s" % (n, unit)


def human_mb(mb):
    mb = float(mb or 0)
    if mb >= 1024:
        return "%.1f GB" % (mb / 1024.0)
    return "%d MB" % int(mb)


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def slug(s):
    s = re.sub(r"[^a-zA-Z0-9]+", "-", str(s).lower()).strip("-")
    return s or "x"


def cache_get(key, max_age):
    c = jload(CACHE_JSON, {})
    e = c.get(key)
    if isinstance(e, dict) and time.time() - e.get("t", 0) < max_age:
        return e.get("v")
    return None


def cache_put(key, value):
    with FileLock("cache"):
        c = jload(CACHE_JSON, {})
        c[key] = {"t": time.time(), "v": value}
        jsave(CACHE_JSON, c)


_SIZE_UNITS = {"b": 1, "kb": 1024, "mb": 1024 ** 2, "gb": 1024 ** 3, "tb": 1024 ** 4,
               "kib": 1024, "mib": 1024 ** 2, "gib": 1024 ** 3}


def parse_size(txt):
    m = re.match(r"\s*([\d.]+)\s*([a-zA-Z]+)\s*$", txt or "")
    if not m:
        return 0
    try:
        return int(float(m.group(1)) * _SIZE_UNITS.get(m.group(2).lower(), 1))
    except Exception:
        return 0


def _int_or_none(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False
