"""
Selkies Forge engine - ledger

Memory booked by desktops that are on their way up.

Admission (launch.admit_memory) compares a desktop's floor with the memory
that is free right now. On its own that is fooled by two launches at once:
both see the same free memory, both are admitted, and the second one starts
into memory the first is about to use. So every admitted launch books its
floor here until it is up (or fails, or is cancelled), and admission
subtracts what other launches have booked.

The ledger is one JSON file under an fcntl lock, shared by every process.
Bookings belong to a process: one whose process has died is ignored and
dropped, so a crash can never leave memory booked forever.
"""

import os
import time

from .paths import LEDGER_JSON
from .util import FileLock, jload, jsave, pid_alive

MAX_AGE = 3 * 3600      # nothing takes this long to start; drop it if it claims to


def _live(row, now):
    return pid_alive(row.get("pid")) and now - float(row.get("ts") or 0) < MAX_AGE


def _load_live():
    now = time.time()
    data = jload(LEDGER_JSON, {})
    live = {k: v for k, v in data.items() if isinstance(v, dict) and _live(v, now)}
    return data, live


def book(job_id, mb, entry_id=None):
    with FileLock("ledger"):
        data, live = _load_live()
        live[job_id] = {"mb": int(mb), "pid": os.getpid(), "ts": time.time(),
                        "entry": entry_id}
        jsave(LEDGER_JSON, live)


def release(job_id):
    try:
        with FileLock("ledger"):
            data, live = _load_live()
            live.pop(job_id, None)
            if live != data:
                jsave(LEDGER_JSON, live)
    except Exception:
        pass


def booked(exclude=None):
    """(total MB booked by other live launches, [their bookings])."""
    _, live = _load_live()
    rows = [dict(v, job=k) for k, v in live.items() if k != exclude]
    return sum(int(r.get("mb") or 0) for r in rows), rows
