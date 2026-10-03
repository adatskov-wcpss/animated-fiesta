"""
Selkies Forge engine - watchdog

While the web UI is running, the watchdog looks after every desktop:

  * Crash detection. A desktop that was running on the last pass and has now
    exited, without anyone stopping it (see events.DELIBERATE), crashed. That
    is recorded with its exit code, whether the kernel's OOM killer did it,
    and the last lines of its log.
  * Healing. A crashed desktop is started again, at most HEAL_MAX times per
    hour, unless healing is off for it (label io.selkiesforge.heal=off, or
    FORGE_HEAL=0 for all). Desktops are never started after a reboot or a
    deliberate stop: only a crash while the forge was watching counts.
  * Session health. The forge agent inside each desktop reports its window
    manager and screen; the watchdog caches that for the manager, and records
    when a desktop drops into its rescue session.
  * Housekeeping. Registry entries and port reservations for containers that
    no longer exist are dropped.

Every pass is cheap: one `docker ps`, plus a `docker inspect` only for
desktops that changed state, and one `docker exec cat` per running desktop at
most once a minute.
"""

import json
import os
import threading
import time

from . import events
from .health import container_logs, exec_read
from .paths import LABEL, PORTS_JSON
from .store import reg_delete, reg_load
from .util import FileLock, jload, jsave, run

INTERVAL = 15.0
HEALTH_EVERY = 60.0
HEAL_MAX = 3            # per desktop per hour
CLEAN_STOP_CODES = (0, 143)   # exited normally, or SIGTERM from docker stop

_session = {}           # name -> health dict (+ "read_at")
_lock = threading.Lock()


def heal_enabled():
    return os.environ.get("FORGE_HEAL", "1") != "0"


def session_health(name):
    with _lock:
        h = _session.get(name)
        return dict(h) if h else None


def _snapshot():
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}\t{{.State}}\t{{.Label \"%s.heal\"}}" % LABEL],
                     timeout=30)
    if rc != 0:
        return None
    state = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            state[parts[0]] = {"state": parts[1], "heal": (parts[2] if len(parts) > 2 else "")}
    return state


def _inspect_state(name):
    rc, out, _ = run(["docker", "inspect", "-f", "{{json .State}}", name], timeout=20)
    try:
        return json.loads(out) if rc == 0 else {}
    except ValueError:
        return {}


class Watchdog(object):
    def __init__(self, interval=INTERVAL):
        self.interval = interval
        self.prev = None
        self._stop = threading.Event()
        self._thread = None
        self._last_clean = 0.0

    def start(self):
        if self._thread:
            return
        self._thread = threading.Thread(target=self._loop, name="forge-watchdog", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _loop(self):
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception:
                pass
            self._stop.wait(self.interval)

    # -- one pass -----------------------------------------------------------
    def tick(self, now=None):
        now = now or time.time()
        cur = _snapshot()
        if cur is None:
            return {"docker": False}
        report = {"crashed": [], "healed": [], "rescue": []}
        if self.prev is not None:
            for name, info in cur.items():
                was = self.prev.get(name)
                if was and was["state"] == "running" and info["state"] in ("exited", "dead"):
                    self._on_stop(name, info, report)
        for name, info in cur.items():
            if info["state"] == "running":
                self._read_session(name, now, report)
        with _lock:
            for name in list(_session):
                if name not in cur or cur[name]["state"] != "running":
                    _session.pop(name, None)
        self.prev = cur
        if now - self._last_clean > 600:
            self._last_clean = now
            reconcile(set(cur))
        return report

    def _on_stop(self, name, info, report):
        if events.last_deliberate(name, within=300):
            return                                   # someone stopped it on purpose
        st = _inspect_state(name)
        code = st.get("ExitCode")
        oom = bool(st.get("OOMKilled"))
        if not oom and code in CLEAN_STOP_CODES:
            events.record(name, "stopped", "exited with code %s outside the forge" % code)
            return
        tail = container_logs(name, 15)
        events.record(name, "crashed", "exit code %s%s" % (code, ", out of memory" if oom else ""),
                      exit_code=code, oom=oom, log=tail[-1500:])
        report["crashed"].append(name)
        if info.get("heal") == "off" or not heal_enabled():
            return
        recent = events.recent(name, limit=20, since=time.time() - 3600, kinds={"healed"})
        if len(recent) >= HEAL_MAX:
            events.record(name, "heal-skipped", "crashed %d times this hour; leaving it stopped"
                          % (len(recent) + 1))
            return
        rc, out, err = run(["docker", "start", name], timeout=120)
        if rc == 0:
            events.record(name, "healed", "started again after a crash")
            report["healed"].append(name)
        else:
            events.record(name, "heal-failed", (err or out).strip()[:400])

    def _read_session(self, name, now, report):
        with _lock:
            h = _session.get(name)
        if h and now - h.get("read_at", 0) < HEALTH_EVERY:
            return
        raw = exec_read(name, "/tmp/forge/health.json", timeout=10)
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            data = {}
        data["read_at"] = now
        prev_mode = (h or {}).get("mode")
        with _lock:
            _session[name] = data
        if data.get("mode") == "rescue" and prev_mode != "rescue":
            events.record(name, "session-rescue",
                          "the desktop session kept crashing; a rescue session is showing its log")
            report["rescue"].append(name)


def reconcile(existing=None):
    """Drop registry entries and port reservations for containers that are gone."""
    if existing is None:
        snap = _snapshot()
        if snap is None:
            return {"docker": False}
        existing = set(snap)
    gone = [n for n in reg_load() if n not in existing and n != "__webui__"]
    for n in gone:
        reg_delete(n)
    with FileLock("ports"):
        res = jload(PORTS_JSON, {})
        fresh = {k: v for k, v in res.items() if time.time() - float(v) < 900}
        if fresh != res:
            jsave(PORTS_JSON, fresh)
    return {"removed": gone}


WATCHDOG = Watchdog()
