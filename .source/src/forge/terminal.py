"""
Selkies Forge engine - terminal

Live PTY sessions into desktops (docker exec -it) for the web terminal.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import threading
import time
import uuid

from collections import deque


class TermSession(object):
    MAX_BUF = 512 * 1024

    def __init__(self, container, cols=100, rows=28, user=None, shell=None):
        self.id = uuid.uuid4().hex[:12]
        self.container = container
        self.cols, self.rows = int(cols), int(rows)
        self.chunks = deque()
        self.total = 0
        self.seq = 0
        self.closed = False
        self.lock = threading.Condition()
        self.exit_code = None

        shell = shell or "/bin/bash"
        cmd = ["docker", "exec", "-it", "-e", "TERM=xterm-256color",
               "-e", "COLUMNS=%d" % self.cols, "-e", "LINES=%d" % self.rows,
               "-w", "/config"]
        if user:
            cmd += ["-u", str(user)]
        # No stderr redirect here: bash writes its prompt to stderr, so hiding
        # it gives you a shell that looks dead until you type.
        cmd += [container, "/bin/sh", "-c",
                "if command -v %s >/dev/null 2>&1; then exec %s -l; else exec /bin/sh -l; fi"
                % (shell, shell)]

        self.pid, self.fd = pty.fork()
        if self.pid == 0:                      # child
            try:
                os.environ["TERM"] = "xterm-256color"
                os.execvp(cmd[0], cmd)
            except Exception:
                os._exit(127)
        self.resize(self.cols, self.rows)
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                r, _, _ = select.select([self.fd], [], [], 0.5)
                if not r:
                    if self._child_gone():
                        break
                    continue
                data = os.read(self.fd, 65536)
                if not data:
                    break
                self._append(data)
            except (OSError, ValueError):
                break
        self._finish()

    def _child_gone(self):
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid == self.pid:
                self.exit_code = os.waitstatus_to_exitcode(status) \
                    if hasattr(os, "waitstatus_to_exitcode") else 0
                return True
        except ChildProcessError:
            return True
        except OSError:
            return True
        return False

    def _append(self, data):
        with self.lock:
            self.seq += 1
            self.chunks.append((self.seq, data))
            self.total += len(data)
            while self.total > self.MAX_BUF and len(self.chunks) > 1:
                self.total -= len(self.chunks.popleft()[1])
            self.lock.notify_all()

    def _finish(self):
        with self.lock:
            self.closed = True
            self.lock.notify_all()
        try:
            os.close(self.fd)
        except OSError:
            pass

    def read_since(self, cursor, timeout=20.0):
        deadline = time.time() + timeout
        with self.lock:
            while True:
                out = [(s, d) for s, d in self.chunks if s > cursor]
                if out:
                    return out
                if self.closed or time.time() >= deadline:
                    return []
                self.lock.wait(min(1.0, max(0.05, deadline - time.time())))

    def write(self, data):
        if self.closed:
            raise RuntimeError("session closed")
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        os.write(self.fd, data)

    def resize(self, cols, rows):
        self.cols, self.rows = int(cols), int(rows)
        try:
            import termios as t
            fcntl.ioctl(self.fd, t.TIOCSWINSZ,
                        struct.pack("HHHH", self.rows, self.cols, 0, 0))
            os.kill(self.pid, signal.SIGWINCH)
        except Exception:
            pass

    def close(self):
        try:
            os.kill(self.pid, signal.SIGHUP)
        except Exception:
            pass
        self.closed = True


TERMS = {}
TERMS_LOCK = threading.Lock()


def term_open(container, cols=100, rows=28, user=None):
    with TERMS_LOCK:
        for s in list(TERMS.values()):
            if s.closed:
                TERMS.pop(s.id, None)
        if len(TERMS) >= 12:
            raise RuntimeError("too many open terminals")
    s = TermSession(container, cols, rows, user=user)
    with TERMS_LOCK:
        TERMS[s.id] = s
    return s


def term_get(sid):
    with TERMS_LOCK:
        return TERMS.get(sid)
