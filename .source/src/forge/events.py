"""
Selkies Forge engine - events

An append-only journal of what happened to each desktop: created, started,
stopped, crashed, healed, repaired, a fix applied during launch. It is how the
watchdog tells "you stopped it" from "it crashed", and what the manager shows
under a desktop's logs.

One JSON object per line in state/events.jsonl, trimmed when it grows large.
"""

import json
import os
import time

from .paths import EVENTS_JSONL
from .util import FileLock, ensure_dirs

MAX_BYTES = 2 * 1024 * 1024
KEEP_LINES = 4000

# Events that mean a person (or the forge, on their behalf) stopped a desktop
# on purpose. The watchdog never treats a stop after one of these as a crash.
DELIBERATE = {"stop", "restart", "remove", "repair", "recreate", "retune", "launch-cancelled",
              "launch-failed", "user-stop", "idle-stop", "pressure-stop", "backup-restore"}


def record(name, event, detail="", **extra):
    """Append one event. Never raises: the journal must not break real work."""
    try:
        ensure_dirs()
        row = {"ts": round(time.time(), 3), "name": name, "event": event}
        if detail:
            row["detail"] = str(detail)[:2000]
        row.update({k: v for k, v in extra.items() if v is not None})
        line = json.dumps(row, sort_keys=True) + "\n"
        with FileLock("events", timeout=10):
            with open(EVENTS_JSONL, "a") as fh:
                fh.write(line)
            if os.path.getsize(EVENTS_JSONL) > MAX_BYTES:
                _trim()
    except Exception:
        pass


def _trim():
    with open(EVENTS_JSONL) as fh:
        lines = fh.readlines()[-KEEP_LINES:]
    tmp = EVENTS_JSONL + ".tmp"
    with open(tmp, "w") as fh:
        fh.writelines(lines)
    os.replace(tmp, EVENTS_JSONL)


def recent(name=None, limit=100, since=0.0, kinds=None):
    """Newest last. Filter by desktop name, time and event kinds."""
    out = []
    try:
        with open(EVENTS_JSONL) as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if name and row.get("name") != name:
                    continue
                if since and row.get("ts", 0) < since:
                    continue
                if kinds and row.get("event") not in kinds:
                    continue
                out.append(row)
    except OSError:
        return []
    return out[-limit:]


def last_deliberate(name, within=180.0):
    """The most recent deliberate action on this desktop within `within` seconds."""
    rows = recent(name, limit=50, since=time.time() - within, kinds=DELIBERATE)
    return rows[-1] if rows else None
