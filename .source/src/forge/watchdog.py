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
  * Frozen desktops. The agent writes a heartbeat every few seconds. A running
    desktop whose heartbeat stops (the X server or the whole container hung)
    is restarted, from the same healing budget as a crash.
  * Viewers. Each open browser tab holds one websocket to Selkies (or Kasm);
    counting them tells the manager who is watching, and how long a desktop
    has gone unwatched.
  * Idle stop. A desktop nobody has watched for its idle limit (per desktop,
    or FORGE_IDLE_STOP_MIN for all; off by default) is stopped to give its
    memory back. Its files are kept, and it starts again like any other.
  * Host memory pressure. When the machine runs short of memory, that is
    recorded with the biggest desktops named. With FORGE_PRESSURE_STOP=1 the
    biggest desktop that nobody is watching is stopped before the kernel's
    OOM killer picks something itself.
  * Recovery. A launch whose process died (the web UI restarted, the power
    went) is marked interrupted, and the half-made desktop it left is removed.
  * Housekeeping. Registry entries and port reservations for containers that
    no longer exist are dropped.

Every pass is cheap: one `docker ps`, plus a `docker inspect` only for
desktops that changed state, and one `docker exec` per running desktop at
most once a minute (the heartbeat and the viewer count in one read).
"""

import json
import os
import threading
import time

from . import events, ledger
from .health import container_logs
from .jobs import mark_job_state, read_job_states
from .paths import CPREFIX, KASM_HTTPS, LABEL, PORTS_JSON, SELKIES_WS
from .store import reg_delete, reg_load
from .util import FileLock, human_mb, jload, jsave, run

INTERVAL = 15.0
HEALTH_EVERY = 60.0
HEAL_MAX = 3            # per desktop per hour
CLEAN_STOP_CODES = (0, 143)   # exited normally, or SIGTERM from docker stop
FROZEN_AFTER = 180      # seconds without a heartbeat from a desktop that had one
PRESSURE_TICKS = 2      # consecutive low-memory passes before it counts
PRESSURE_EVERY = 600    # seconds between host-pressure events

_session = {}           # name -> health dict (+ "read_at", "viewers", "idle_s")
_seen = {}              # name -> {"last_viewer": ts, "since": ts}
_lock = threading.Lock()
PRESSURE = {"active": False, "since": None, "avail_mb": None, "total_mb": None}


def heal_enabled():
    return os.environ.get("FORGE_HEAL", "1") != "0"


def _env_int(var, default=0):
    try:
        return int(os.environ.get(var, default))
    except ValueError:
        return default


def idle_limit(name, reg=None):
    """Minutes a desktop may go unwatched before it is stopped (0: never)."""
    note = (reg if reg is not None else reg_load()).get(name) or {}
    if note.get("idle_stop_min") is not None:
        try:
            return max(0, int(note["idle_stop_min"]))
        except (TypeError, ValueError):
            return 0
    return max(0, _env_int("FORGE_IDLE_STOP_MIN", 0))


def count_viewers(proc_net, ports):
    """Established connections whose local port is one of `ports`, from the
    text of /proc/net/tcp and /proc/net/tcp6 inside a container."""
    n = 0
    for line in proc_net.splitlines():
        parts = line.split()
        if len(parts) < 4 or ":" not in parts[1] or parts[0] == "sl":
            continue
        try:
            port = int(parts[1].rsplit(":", 1)[1], 16)
        except ValueError:
            continue
        if parts[3] == "01" and port in ports:
            n += 1
    return n


def read_meminfo():
    out = {}
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                k, _, v = line.partition(":")
                out[k] = int(v.split()[0]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return out.get("MemTotal"), out.get("MemAvailable")


def session_health(name):
    with _lock:
        h = _session.get(name)
        return dict(h) if h else None


def _snapshot():
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}\t{{.State}}\t{{.Label \"%s.heal\"}}"
                      "\t{{.Label \"%s.profile\"}}" % (LABEL, LABEL)],
                     timeout=30)
    if rc != 0:
        return None
    state = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            state[parts[0]] = {"state": parts[1], "heal": (parts[2] if len(parts) > 2 else ""),
                               "profile": (parts[3] if len(parts) > 3 else "") or "selkies"}
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
        self._last_recover = 0.0
        self._pressure_ticks = 0
        self._last_pressure = 0.0

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
        report = {"crashed": [], "healed": [], "rescue": [], "frozen": [], "idle_stopped": [],
                  "pressure": False, "recovered": []}
        if self.prev is not None:
            for name, info in cur.items():
                was = self.prev.get(name)
                if was and was["state"] == "running" and info["state"] in ("exited", "dead"):
                    self._on_stop(name, info, report)
        reg = reg_load()
        for name, info in cur.items():
            if info["state"] == "running":
                was_running = bool(self.prev and (self.prev.get(name) or {}).get("state") == "running")
                self._read_session(name, info, now, report, reg, was_running)
        with _lock:
            for name in list(_session):
                if name not in cur or cur[name]["state"] != "running":
                    _session.pop(name, None)
                    _seen.pop(name, None)
        self.prev = cur
        self._check_pressure(cur, now, report)
        if now - self._last_recover > 60:
            self._last_recover = now
            report["recovered"] = recover_interrupted()
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

    def _heal_budget_left(self, name):
        recent = events.recent(name, limit=20, since=time.time() - 3600, kinds={"healed"})
        return HEAL_MAX - len(recent)

    def _read_session(self, name, info, now, report, reg, was_running):
        with _lock:
            h = _session.get(name)
            seen = _seen.setdefault(name, {"last_viewer": now, "since": now})
            if not was_running:
                seen["since"] = now
        if h and now - h.get("read_at", 0) < HEALTH_EVERY:
            return
        # One exec: the agent's heartbeat file, then the container's sockets.
        rc, out, _ = run(["docker", "exec", name, "sh", "-c",
                          "cat /tmp/forge/health.json 2>/dev/null; echo; echo @@NET@@; "
                          "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"], timeout=10)
        if rc != 0 and not out:
            return
        raw, _, net = out.partition("@@NET@@")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            data = {}
        ports = {KASM_HTTPS} if info.get("profile") == "kasm" else {SELKIES_WS}
        viewers = count_viewers(net, ports)
        if viewers:
            seen["last_viewer"] = now
        data["viewers"] = viewers
        data["idle_s"] = 0 if viewers else int(now - seen["last_viewer"])
        data["read_at"] = now
        prev_mode = (h or {}).get("mode")
        with _lock:
            _session[name] = data
        if data.get("mode") == "rescue" and prev_mode != "rescue":
            events.record(name, "session-rescue",
                          "the desktop session kept crashing; a rescue session is showing its log")
            report["rescue"].append(name)
        if self._check_frozen(name, info, h, data, now, report):
            return
        limit = idle_limit(name, reg)
        if limit and not viewers and now - seen["last_viewer"] >= limit * 60 \
                and now - seen["since"] >= limit * 60:
            self._idle_stop(name, limit, report)

    def _check_frozen(self, name, info, h, data, now, report):
        """A heartbeat that was moving and has stopped: the desktop hung."""
        ts, prev_ts = data.get("ts"), (h or {}).get("ts")
        if not ts or not prev_ts or ts != prev_ts or now - float(ts) < FROZEN_AFTER:
            return False
        if (h or {}).get("frozen_reported"):
            data["frozen_reported"] = True
            return True
        data["frozen_reported"] = True
        stuck = int(now - float(ts))
        events.record(name, "session-frozen", "no sign of life from the desktop for %ds" % stuck)
        report["frozen"].append(name)
        if info.get("heal") == "off" or not heal_enabled():
            return True
        if self._heal_budget_left(name) <= 0:
            events.record(name, "heal-skipped", "froze again; healed %d times this hour already"
                          % HEAL_MAX)
            return True
        events.record(name, "restart", "watchdog: restarting a frozen desktop")
        rc, out, err = run(["docker", "restart", "-t", "10", name], timeout=120)
        if rc == 0:
            events.record(name, "healed", "restarted after it froze")
            report["healed"].append(name)
        else:
            events.record(name, "heal-failed", (err or out).strip()[:400])
        return True

    def _idle_stop(self, name, limit, report):
        from .lifecycle import instance_action        # lifecycle imports this module
        events.record(name, "idle-stop", "nobody has watched it for %d minutes; stopping it "
                      "to free its memory (files are kept)" % limit)
        try:
            instance_action(name, "stop")
            report["idle_stopped"].append(name)
        except Exception as ex:
            events.record(name, "idle-stop-failed", str(ex)[:300])

    def _check_pressure(self, cur, now, report):
        total, avail = read_meminfo()
        if not total or avail is None:
            return
        low = avail < max(256, total * 0.05)
        self._pressure_ticks = self._pressure_ticks + 1 if low else 0
        PRESSURE.update(total_mb=total, avail_mb=avail)
        if self._pressure_ticks < PRESSURE_TICKS:
            if not low:
                PRESSURE.update(active=False, since=None)
            return
        if not PRESSURE["active"]:
            PRESSURE.update(active=True, since=now)
        report["pressure"] = True
        if now - self._last_pressure < PRESSURE_EVERY:
            return
        self._last_pressure = now
        running = [n for n, i in cur.items() if i["state"] == "running"]
        usage = desktop_memory(running)
        top = sorted(usage.items(), key=lambda kv: -kv[1])[:3]
        events.record("host", "host-pressure",
                      "only %s of %s memory left; biggest desktops: %s"
                      % (human_mb(avail), human_mb(total),
                         ", ".join("%s %s" % (n.replace(CPREFIX, "", 1), human_mb(mb))
                                   for n, mb in top) or "none"))
        if os.environ.get("FORGE_PRESSURE_STOP") != "1":
            return
        with _lock:
            unwatched = [n for n, _ in sorted(usage.items(), key=lambda kv: -kv[1])
                         if not (_session.get(n) or {}).get("viewers")]
        if unwatched:
            from .lifecycle import instance_action
            victim = unwatched[0]
            events.record(victim, "pressure-stop", "the machine was out of memory and nobody "
                          "was watching this desktop; stopped it (files are kept)")
            try:
                instance_action(victim, "stop")
                report["idle_stopped"].append(victim)
            except Exception as ex:
                events.record(victim, "idle-stop-failed", str(ex)[:300])


def desktop_memory(names):
    """{name: MB in use} for running desktops (one `docker stats` call)."""
    if not names:
        return {}
    rc, out, _ = run(["docker", "stats", "--no-stream", "--format",
                      "{{.Name}}\t{{.MemUsage}}"] + list(names), timeout=40)
    from .util import parse_size
    usage = {}
    for line in out.splitlines():
        n, _, mem = line.partition("\t")
        try:
            usage[n] = int(parse_size(mem.split("/")[0].strip()) / (1024 * 1024))
        except (ValueError, TypeError):
            continue
    return usage


def recover_interrupted():
    """Clean up after launches whose process died part-way.

    The job is marked interrupted. If it had already created its container,
    and that container carries this job's label and never reported ready, the
    container is removed, and its volume too unless the volume held files
    from before (a kept volume of a removed desktop, which is never touched).
    """
    done = []
    for st in read_job_states():
        if st.get("status") != "interrupted" or st.get("recovered"):
            continue
        jid = st.get("id")
        notes = st.get("notes") or {}
        cname = notes.get("container")
        removed = False
        if st.get("kind") in ("launch", "clone") and cname:
            rc, out, _ = run(["docker", "inspect", "-f",
                              "{{index .Config.Labels \"%s.job\"}}" % LABEL, cname], timeout=20)
            ready = any(e.get("event") == "ready" and e.get("ts", 0) >= (st.get("created") or 0)
                        for e in events.recent(cname, limit=40))
            if rc == 0 and out.strip() == jid and not ready:
                run(["docker", "rm", "-f", cname], timeout=120)
                if notes.get("volume") and not notes.get("keep_volume"):
                    run(["docker", "volume", "rm", "-f", notes["volume"]], timeout=60)
                reg_delete(cname)
                removed = True
            elif rc != 0 and notes.get("volume") and not notes.get("keep_volume") \
                    and st.get("kind") == "clone":
                run(["docker", "volume", "rm", "-f", notes["volume"]], timeout=60)
        ledger.release(jid)
        what = ("the half-made desktop %s was removed" % cname) if removed else "nothing was left behind"
        mark_job_state(jid, status="interrupted", recovered=True,
                       error={"message": "interrupted during %s (its process stopped); %s"
                              % (st.get("phase") or "start", what), "hints": [],
                              "cancelled": False, "log": st.get("log")})
        if cname:
            events.record(cname, "launch-interrupted",
                          "the process running this launch stopped during %s; %s"
                          % (st.get("phase") or "start", what))
        done.append(jid)
    return done


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
