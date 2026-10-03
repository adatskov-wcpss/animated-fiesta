"""
Selkies Forge engine - scheduler

Heavy work is rationed so a small machine is never flattened by it. Building a
desktop (package installs) is the most expensive thing the forge does, then
pulling images, then the first boot of a desktop. Each has a number of slots:

    build   FORGE_MAX_BUILDS  default 1
    pull    FORGE_MAX_PULLS   default 2
    boot    FORGE_MAX_BOOTS   default 2

A slot is an fcntl lock file under state/slots/, so the limits hold across
every process: the web UI, `selkies-cli`, and a second web UI if you start
one. A job waiting for a slot shows as "queued" and can be cancelled while it
waits. Locks are released by the kernel if a process dies, so a crash can
never leave a slot stuck.
"""

import fcntl
import os
import time

from contextlib import contextmanager

from .paths import STATE
from .util import ensure_dirs

DEFAULTS = {"build": 1, "pull": 2, "boot": 2}
ENV = {"build": "FORGE_MAX_BUILDS", "pull": "FORGE_MAX_PULLS", "boot": "FORGE_MAX_BOOTS"}
LABELS = {"build": "another desktop is building", "pull": "other downloads are running",
          "boot": "other desktops are starting"}


def limit(kind):
    try:
        return max(1, int(os.environ.get(ENV[kind], DEFAULTS[kind])))
    except (ValueError, KeyError):
        return DEFAULTS.get(kind, 1)


def _slot_dir():
    d = os.path.join(STATE, "slots")
    ensure_dirs()
    os.makedirs(d, exist_ok=True)
    return d


def _try_take(kind):
    d = _slot_dir()
    for i in range(limit(kind)):
        fh = open(os.path.join(d, "%s-%d.lock" % (kind, i)), "a+")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fh.seek(0)
            fh.truncate()
            fh.write("%d %d\n" % (os.getpid(), int(time.time())))
            fh.flush()
            return fh
        except OSError:
            fh.close()
    return None


def busy(kind):
    """How many slots of this kind are taken right now (by anyone)."""
    d = _slot_dir()
    n = 0
    for i in range(limit(kind)):
        with open(os.path.join(d, "%s-%d.lock" % (kind, i)), "a+") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
            except OSError:
                n += 1
    return n


@contextmanager
def slot(kind, job=None, poll=1.0):
    """Hold one `kind` slot for the duration of the block, queueing if needed."""
    fh = _try_take(kind)
    if fh is None and job is not None:
        prev_phase = job.phase
        job.set_phase("queued", "Queued: %s (%d at a time)" % (LABELS.get(kind, kind), limit(kind)))
        job.log("queued   : %s; waiting for a free %s slot" % (LABELS.get(kind, kind), kind))
        t0 = time.time()
        while fh is None:
            job.check()
            time.sleep(poll)
            fh = _try_take(kind)
        job.log("queued   : got a %s slot after %ds" % (kind, int(time.time() - t0)))
        job.phase = prev_phase
    while fh is None:
        time.sleep(poll)
        fh = _try_take(kind)
    try:
        yield
    finally:
        try:
            fcntl.flock(fh, fcntl.LOCK_UN)
        finally:
            fh.close()


def status():
    return {k: {"limit": limit(k), "busy": busy(k)} for k in DEFAULTS}
