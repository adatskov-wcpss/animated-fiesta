"""
Selkies Forge engine - jobs

A launch (or any long operation) is a Job: a thread doing the work and an
ordered stream of events (log lines, phase changes, progress, the result) that
the web UI reads over SSE and the CLI reads from stdout.

Jobs can be cancelled. Every subprocess a job starts (docker pull, docker
build) is registered with it, so cancelling kills what is running right now,
and the pipeline checks `job.check()` between stages so it stops cleanly.

Every job also writes its log to logs/jobs/<id>.log, so a failure can still be
read after the web UI restarts.

Jobs are durable. Each one keeps a small state file, state/jobs/<id>.json
(status, phase, progress, the process that owns it, the container it is
making), so:

  * any process can see every job: a launch started from `selkies-cli` shows
    up in the web UI, with its progress, and can be cancelled from there;
  * a job whose process died (the web UI restarted mid-launch, the machine
    lost power, a terminal was closed) is noticed, marked "interrupted", and
    the half-made desktop it left behind is removed. See recover_interrupted.

Commands can also stall without failing: a `docker pull` stuck on a dead
connection prints nothing and never exits. stream_cmd and stream_cmd_pty take
a `stall` time; no output for that long kills the command and raises
CommandStalled, which the callers treat like a network error and retry.
"""

import json
import os
import pty
import re
import select
import signal
import subprocess
import threading
import time
import uuid

from collections import deque

from .paths import ANSI_RE, JOBLOGDIR, JOBSTATEDIR
from .util import clamp, ensure_dirs, pid_alive

KEEP_JOB_LOGS = 60
KEEP_JOB_STATES = 80
PERSIST_EVERY = 1.0      # seconds between progress writes to the state file


class JobCancelled(Exception):
    """Raised inside a job's work when someone asked it to stop."""


class CommandStalled(RuntimeError):
    """A command printed nothing for too long and was killed."""

    def __init__(self, cmd, seconds):
        RuntimeError.__init__(self, "%s printed nothing for %ds and was stopped"
                              % (os.path.basename(str(cmd[0])), seconds))
        self.seconds = seconds


def _owner():
    """Who runs this process: the web UI ("server") or a terminal ("cli")."""
    return os.environ.get("FORGE_JOB_OWNER", "cli")


class Job(object):
    MAX_EVENTS = 6000

    def __init__(self, kind, entry_id=None, title=None):
        self.id = uuid.uuid4().hex[:12]
        self.kind = kind
        self.entry_id = entry_id
        self.title = title or entry_id or kind
        self.created = time.time()
        self.status = "running"
        self.phase = "starting"
        self.progress = 0.0
        self.result = None
        self.error = None
        self.events = deque(maxlen=self.MAX_EVENTS)
        self._seq = 0
        self._cv = threading.Condition()
        self.thread = None
        self.cancelled = False
        self._procs = set()           # Popen objects and pty child pids
        self._plock = threading.Lock()
        self.log_path = None
        self._logfh = None
        self.pid = os.getpid()
        self.owner = _owner()
        self.notes = {}               # e.g. {"container": "forge-x"} once one exists
        self._persisted = 0.0
        try:
            ensure_dirs()
            self.log_path = os.path.join(JOBLOGDIR, "%s-%s.log" % (
                time.strftime("%Y%m%d-%H%M%S"), self.id))
            self._logfh = open(self.log_path, "a", buffering=1)
            self._logfh.write("# %s %s %s\n" % (kind, entry_id or "", time.strftime("%F %T")))
            _prune_job_logs()
        except OSError:
            self._logfh = None
        self._persist(force=True)

    # -- producer ---------------------------------------------------------
    def _push(self, typ, data):
        with self._cv:
            self._seq += 1
            ev = {"seq": self._seq, "t": round(time.time(), 3), "type": typ, "data": data}
            self.events.append(ev)
            self._cv.notify_all()
            return ev

    def _write(self, text):
        if self._logfh:
            try:
                self._logfh.write(text + "\n")
            except (OSError, ValueError):
                pass

    def log(self, line, stream="out"):
        for ln in str(line).rstrip("\n").split("\n"):
            self._push("log", {"line": ln, "stream": stream})
            self._write(("! " if stream == "err" else "  ") + ln)

    def set_phase(self, phase, label=None, progress=None):
        self.phase = phase
        if progress is not None:
            self.progress = clamp(float(progress), 0.0, 1.0)
        self.label = label or phase
        self._push("phase", {"phase": phase, "label": label or phase,
                             "progress": round(self.progress, 4)})
        self._write("== %s: %s" % (phase, label or phase))
        self._persist(force=True)

    def set_progress(self, value, extra=None):
        self.progress = clamp(float(value), 0.0, 1.0)
        self._push("progress", {"phase": self.phase,
                                "progress": round(self.progress, 4),
                                "extra": extra or {}})
        self._persist()

    def finish(self, result):
        self.status = "done"
        self.progress = 1.0
        self.result = result
        self._push("done", result)
        self._write("== done")
        self._close_log()
        self._persist(force=True)

    def fail(self, message, hints=None):
        self.status = "cancelled" if self.cancelled else "error"
        self.error = {"message": str(message), "hints": hints or [],
                      "cancelled": self.cancelled, "log": self.log_path}
        self._push("error", self.error)
        self._write("== %s: %s" % (self.status, message))
        self._close_log()
        self._persist(force=True)

    def note(self, **kv):
        """Remember something about this job in its state file (e.g. container=...)."""
        self.notes.update({k: v for k, v in kv.items() if v is not None})
        self._persist(force=True)

    def _persist(self, force=False):
        now = time.time()
        if not force and now - self._persisted < PERSIST_EVERY:
            return
        self._persisted = now
        st = self.snapshot()
        st["result"] = _small_result(self.result)
        st.update({"pid": self.pid, "owner": self.owner, "notes": self.notes,
                   "label": getattr(self, "label", self.phase), "updated": now})
        try:
            ensure_dirs()
            path = os.path.join(JOBSTATEDIR, "%s.json" % self.id)
            tmp = "%s.tmp.%d" % (path, os.getpid())
            with open(tmp, "w") as fh:
                json.dump(st, fh)
            os.replace(tmp, path)
        except (OSError, TypeError, ValueError):
            pass

    def _close_log(self):
        if self._logfh:
            try:
                self._logfh.close()
            except OSError:
                pass
            self._logfh = None

    # -- cancellation -----------------------------------------------------
    def attach(self, proc):
        with self._plock:
            self._procs.add(proc)
        if self.cancelled:
            self._kill(proc)

    def detach(self, proc):
        with self._plock:
            self._procs.discard(proc)

    def cancel(self):
        """Stop the job: kill whatever it is running and make check() raise."""
        if self.status != "running":
            return False
        self.cancelled = True
        self.log("cancel requested, stopping", "err")
        with self._plock:
            procs = list(self._procs)
        for p in procs:
            self._kill(p)
        with self._cv:
            self._cv.notify_all()
        return True

    @staticmethod
    def _kill(proc):
        """Stop a command and everything it started (its whole process group)."""
        pid = proc if isinstance(proc, int) else proc.pid

        def signal_group(sig):
            try:
                os.killpg(pid, sig)
            except (OSError, ProcessLookupError):
                try:
                    os.kill(pid, sig)
                except (OSError, ProcessLookupError):
                    pass

        signal_group(signal.SIGTERM)
        # Anything that ignores SIGTERM gets SIGKILL a few seconds later.
        t = threading.Timer(4.0, signal_group, args=(signal.SIGKILL,))
        t.daemon = True
        t.start()

    def check(self):
        if self.cancelled:
            raise JobCancelled("cancelled")

    # -- consumer ---------------------------------------------------------
    def since(self, cursor, timeout=20.0):
        """Block until there are events after `cursor`, then return them."""
        deadline = time.time() + timeout
        with self._cv:
            while True:
                out = [e for e in self.events if e["seq"] > cursor]
                if out:
                    return out
                if self.status != "running" or time.time() >= deadline:
                    return []
                self._cv.wait(min(1.0, max(0.05, deadline - time.time())))

    def snapshot(self):
        return {"id": self.id, "kind": self.kind, "entry_id": self.entry_id,
                "title": self.title, "status": self.status, "phase": self.phase,
                "progress": round(self.progress, 4), "result": self.result,
                "error": self.error, "created": self.created,
                "last_seq": self._seq, "cancelled": self.cancelled,
                "log": self.log_path, "label": getattr(self, "label", self.phase),
                "owner": self.owner, "pid": self.pid, "notes": dict(self.notes)}


def _small_result(res):
    """The parts of a result worth keeping on disk (not the whole catalog entry)."""
    if not isinstance(res, dict):
        return res
    keep = ("name", "entry_id", "local_url", "warning", "fixes", "display", "dry_run",
            "file", "size", "backup", "clone")
    return {k: res[k] for k in keep if k in res}


def read_job_states():
    """Every job's state file, newest first. Dead "running" jobs are reported
    as "interrupted" (recover_interrupted cleans up after them)."""
    out = []
    try:
        names = [f for f in os.listdir(JOBSTATEDIR) if f.endswith(".json")]
    except OSError:
        return out
    for f in names:
        try:
            with open(os.path.join(JOBSTATEDIR, f)) as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            continue
        if st.get("status") == "running" and not _owner_alive(st):
            st["status"] = "interrupted"
        out.append(st)
    out.sort(key=lambda s: s.get("created") or 0, reverse=True)
    return out


def _owner_alive(st):
    pid = st.get("pid")
    if not pid_alive(pid):
        return False
    try:                          # the pid was not reused by something else
        with open("/proc/%d/cmdline" % int(pid), "rb") as fh:
            cmd = fh.read()
        return b"engine.py" in cmd or b"forge" in cmd or b"python" in cmd
    except OSError:
        return True


def all_jobs():
    """This process's jobs, plus every other process's (marked foreign)."""
    with JOBS_LOCK:
        mine = {j.id: j.snapshot() for j in JOBS.values()}
    for st in read_job_states():
        if st.get("id") in mine:
            continue
        st["foreign"] = True
        mine[st["id"]] = st
    return sorted(mine.values(), key=lambda s: s.get("created") or 0, reverse=True)[:40]


def cancel_foreign(jid):
    """Cancel a job another process runs. A `selkies-cli` launch treats SIGINT
    exactly like Ctrl-C: it kills the pull or build and cleans up."""
    for st in read_job_states():
        if st.get("id") != jid:
            continue
        if st.get("status") != "running":
            return False
        if st.get("owner") != "cli":
            return False          # never signal another web UI
        try:
            os.kill(int(st["pid"]), signal.SIGINT)
            return True
        except (OSError, KeyError, ValueError):
            return False
    return False


def mark_job_state(jid, **patch):
    path = os.path.join(JOBSTATEDIR, "%s.json" % jid)
    try:
        with open(path) as fh:
            st = json.load(fh)
        st.update(patch)
        st["updated"] = time.time()
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, path)
    except (OSError, ValueError):
        pass


def _prune_job_states():
    try:
        files = sorted((os.path.getmtime(os.path.join(JOBSTATEDIR, f)), f)
                       for f in os.listdir(JOBSTATEDIR) if f.endswith(".json"))
        for _, f in files[:-KEEP_JOB_STATES]:
            os.remove(os.path.join(JOBSTATEDIR, f))
    except OSError:
        pass


def _prune_job_logs():
    try:
        logs = sorted(f for f in os.listdir(JOBLOGDIR) if f.endswith(".log"))
        for f in logs[:-KEEP_JOB_LOGS]:
            os.remove(os.path.join(JOBLOGDIR, f))
    except OSError:
        pass


JOBS = {}
JOBS_LOCK = threading.Lock()


def job_put(job):
    _prune_job_states()
    with JOBS_LOCK:
        JOBS[job.id] = job
        if len(JOBS) > 40:
            old = sorted(JOBS.values(), key=lambda j: j.created)
            for j in old[:len(JOBS) - 40]:
                if j.status != "running":
                    JOBS.pop(j.id, None)
    return job


def job_get(jid):
    with JOBS_LOCK:
        return JOBS.get(jid)


def jobs_running():
    with JOBS_LOCK:
        return [j for j in JOBS.values() if j.status == "running"]


def stream_cmd(cmd, on_line, env=None, timeout=7200, job=None, stall=None):
    """Run a command, hand every output line to on_line, return exit code.

    `timeout` bounds the whole run; `stall` (seconds) bounds the silence
    between two lines. Either one kills the command and its children.
    """
    # Its own process group, so a cancel can stop the command and its children.
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=env, bufsize=1, universal_newlines=True,
                         errors="replace", start_new_session=True)
    if job:
        job.attach(p)
    start = time.time()
    last = [start]
    why = []
    done = threading.Event()

    def guard():
        while not done.wait(1.0):
            now = time.time()
            if now - start > timeout:
                why.append("timeout")
            elif stall and now - last[0] > stall:
                why.append("stall")
            if why:
                Job._kill(p)
                return

    threading.Thread(target=guard, name="forge-cmd-guard", daemon=True).start()
    try:
        for line in p.stdout:
            last[0] = time.time()
            on_line(line.rstrip("\n"))
    finally:
        done.set()
        try:
            p.stdout.close()
        except Exception:
            pass
        if job:
            job.detach(p)
    rc = p.wait()
    if job:
        job.check()
    if why == ["timeout"]:
        raise RuntimeError("command exceeded %ss" % timeout)
    if why == ["stall"]:
        raise CommandStalled(cmd, stall)
    return rc


def stream_cmd_pty(cmd, on_line, timeout=7200, job=None, stall=None):
    """Like stream_cmd, but behind a pty.

    `docker pull` only prints per-layer byte counts when stdout looks like a
    terminal; without one you get bare status lines and no numbers.
    """
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.environ["TERM"] = "xterm"
            os.environ["COLUMNS"] = "160"
            os.execvp(cmd[0], cmd)
        except Exception:
            os._exit(127)
    if job:
        job.attach(pid)
    buf = b""
    start = time.time()
    last = start
    stalled = False
    try:
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 1.0)
            except (OSError, ValueError):
                break
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break                      # child exited, pty closed
                if not data:
                    break
                last = time.time()
                buf += data
                parts = re.split(rb"[\r\n]", buf)
                buf = parts.pop()
                for raw in parts:
                    line = ANSI_RE.sub("", raw.decode("utf-8", "replace")).strip()
                    if line:
                        on_line(line)
            if time.time() - start > timeout:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
                raise RuntimeError("command exceeded %ss" % timeout)
            if stall and time.time() - last > stall:
                stalled = True
                Job._kill(pid)
                break
    finally:
        if buf.strip():
            line = ANSI_RE.sub("", buf.decode("utf-8", "replace")).strip()
            if line:
                on_line(line)
        try:
            os.close(fd)
        except OSError:
            pass
        if job:
            job.detach(pid)
    try:
        _, status = os.waitpid(pid, 0)
        rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
            else (status >> 8)
    except ChildProcessError:
        rc = 0
    if job:
        job.check()
    if stalled:
        raise CommandStalled(cmd, stall)
    return rc
