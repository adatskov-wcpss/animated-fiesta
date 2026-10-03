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
"""

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

from .paths import ANSI_RE, JOBLOGDIR
from .util import clamp, ensure_dirs

KEEP_JOB_LOGS = 60


class JobCancelled(Exception):
    """Raised inside a job's work when someone asked it to stop."""


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
        try:
            ensure_dirs()
            self.log_path = os.path.join(JOBLOGDIR, "%s-%s.log" % (
                time.strftime("%Y%m%d-%H%M%S"), self.id))
            self._logfh = open(self.log_path, "a", buffering=1)
            self._logfh.write("# %s %s %s\n" % (kind, entry_id or "", time.strftime("%F %T")))
            _prune_job_logs()
        except OSError:
            self._logfh = None

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
        self._push("phase", {"phase": phase, "label": label or phase,
                             "progress": round(self.progress, 4)})
        self._write("== %s: %s" % (phase, label or phase))

    def set_progress(self, value, extra=None):
        self.progress = clamp(float(value), 0.0, 1.0)
        self._push("progress", {"phase": self.phase,
                                "progress": round(self.progress, 4),
                                "extra": extra or {}})

    def finish(self, result):
        self.status = "done"
        self.progress = 1.0
        self.result = result
        self._push("done", result)
        self._write("== done")
        self._close_log()

    def fail(self, message, hints=None):
        self.status = "cancelled" if self.cancelled else "error"
        self.error = {"message": str(message), "hints": hints or [],
                      "cancelled": self.cancelled, "log": self.log_path}
        self._push("error", self.error)
        self._write("== %s: %s" % (self.status, message))
        self._close_log()

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
                "log": self.log_path}


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


def stream_cmd(cmd, on_line, env=None, timeout=7200, job=None):
    """Run a command, hand every output line to on_line, return exit code."""
    # Its own process group, so a cancel can stop the command and its children.
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=env, bufsize=1, universal_newlines=True,
                         errors="replace", start_new_session=True)
    if job:
        job.attach(p)
    start = time.time()
    try:
        for line in p.stdout:
            on_line(line.rstrip("\n"))
            if time.time() - start > timeout:
                p.kill()
                raise RuntimeError("command exceeded %ss" % timeout)
    finally:
        try:
            p.stdout.close()
        except Exception:
            pass
        if job:
            job.detach(p)
    rc = p.wait()
    if job:
        job.check()
    return rc


def stream_cmd_pty(cmd, on_line, timeout=7200, job=None):
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
    return rc
