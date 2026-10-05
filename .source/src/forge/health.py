"""
Selkies Forge engine - health

Is the desktop really up? Web port, session agent, OOM and crash detection, fixes.
"""

import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from .gpu import GPU_HINTS, fallback as gpu_fallback
from .util import clamp, human_mb, run


class LaunchProblem(RuntimeError):
    """A launch failure the pipeline may be able to fix and retry."""

    def __init__(self, msg, kind, detail=""):
        RuntimeError.__init__(self, msg)
        self.kind = kind
        self.detail = detail or ""


def container_state(name):
    rc, out, _ = run(["docker", "inspect", "-f", "{{json .State}}", name], timeout=20)
    if rc != 0:
        return {}
    try:
        return json.loads(out) or {}
    except Exception:
        return {}


def exec_read(name, path, timeout=15):
    rc, out, _ = run(["docker", "exec", name, "cat", path], timeout=timeout)
    return out if rc == 0 else ""


def _stopped_problem(name):
    st = container_state(name)
    tail = container_logs(name, 40)
    if st.get("OOMKilled"):
        return LaunchProblem("the desktop ran out of memory and was killed", "oom", tail)
    return LaunchProblem("the container stopped on its own (exit %s)" % st.get("ExitCode"),
                         "exited", tail)


def wait_http(name, port, profile, job=None, timeout=240):
    """Poll the desktop's own web port until it answers."""
    url = ("https://127.0.0.1:%d/" if profile == "kasm" else "http://127.0.0.1:%d/") % port
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    t0 = time.time()
    deadline = t0 + timeout
    last = ""
    attempt = 0
    while time.time() < deadline:
        if job:
            job.check()
        attempt += 1
        st = container_state(name)
        if st and not st.get("Running") and not st.get("Restarting"):
            raise _stopped_problem(name)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "selkies-forge"})
            with urllib.request.urlopen(req, timeout=6, context=ctx) as resp:
                if resp.status < 500:
                    return True
                last = "HTTP %s" % resp.status
        except urllib.error.HTTPError as ex:
            if ex.code in (401, 403):
                return True          # basic auth is on, which means it is up
            last = "HTTP %s" % ex.code
        except Exception as ex:
            last = type(ex).__name__
        if job and attempt % 5 == 0:
            frac = (time.time() - t0) / float(timeout)
            job.set_progress(clamp(0.88 + 0.04 * frac, 0.88, 0.92),
                             {"waiting": last, "seconds": int(time.time() - t0)})
        time.sleep(2.0)
    raise LaunchProblem("the desktop never answered on port %d within %ds (last: %s)"
                        % (port, timeout, last or "no reply"), "timeout",
                        container_logs(name, 30))


# Kept for callers that only care about the web port (reconfigure, repair).
wait_healthy = wait_http


def session_log(name, lines=40):
    txt = exec_read(name, "/tmp/forge/session.log")
    return "\n".join(txt.splitlines()[-lines:])


# Window managers that never announce themselves (no _NET_SUPPORTING_WM_CHECK);
# for these, windows on screen are the best sign of life we get.
NO_EWMH = {"twm", "ratpoison", "wmaker"}


def wait_session(name, entry, job=None, timeout=180):
    """After the web port answers, wait until the desktop session is really up.

    The forge agent inside the container reports the window manager it sees
    and how many windows exist. "Up" means a window manager that is still
    there on the next look, not just a web page in front of a black screen.
    A session that keeps crashing flips the agent into rescue mode; one that
    never brings up a window manager, or gets OOM-killed, is a problem the
    launch can act on.
    """
    if entry.get("profile") == "kasm":
        return {"wm": "KasmVNC"}
    t0 = time.time()
    deadline = t0 + timeout
    checked_agent = False
    last = {}
    seen_wm = 0
    bare = entry.get("de") in NO_EWMH
    while time.time() < deadline:
        if job:
            job.check()
        st = container_state(name)
        if st and not st.get("Running") and not st.get("Restarting"):
            raise _stopped_problem(name)
        if st.get("OOMKilled"):
            raise LaunchProblem("the desktop ran out of memory (the kernel killed part of it)",
                                "oom", session_log(name))
        raw = exec_read(name, "/tmp/forge/health.json")
        if raw.strip():
            try:
                last = json.loads(raw)
            except Exception:
                last = {}
            if last.get("mode") == "rescue":
                raise LaunchProblem("the desktop session keeps crashing on start", "crash",
                                    session_log(name))
            if last.get("wm"):
                seen_wm += 1
                if seen_wm >= 2:
                    return last
            else:
                seen_wm = 0
                if bare and int(last.get("clients") or 0) > 0 and time.time() - t0 > 25:
                    return last
        elif not checked_agent and time.time() - t0 > 20:
            checked_agent = True
            rc, _, _ = run(["docker", "exec", name, "test", "-x", "/usr/local/share/forge/agent"],
                           timeout=15)
            if rc != 0:
                return {"agent": False}      # an old container without the forge layer
        if job:
            frac = (time.time() - t0) / float(timeout)
            job.set_progress(clamp(0.92 + 0.04 * frac, 0.92, 0.96),
                             {"waiting": "desktop session", "seconds": int(time.time() - t0)})
        time.sleep(2.5)
    raise LaunchProblem("the web page is up, but no desktop session appeared within %ds"
                        % timeout, "nowm", session_log(name, 30))


def mem_pressure(name):
    """Memory use of a container as a percent of its limit (0 if unknown)."""
    rc, out, _ = run(["docker", "stats", "--no-stream", "--format", "{{.MemPerc}}", name],
                     timeout=30)
    try:
        return float(out.strip().rstrip("%"))
    except ValueError:
        return 0.0


def container_logs(name, lines=60):
    rc, out, err = run(["docker", "logs", "--tail", str(lines), name], timeout=30)
    return (out or "") + (err or "")


SECCOMP_HINTS = re.compile(r"operation not permitted|seccomp|bwrap:|clone3|"
                           r"failed to move to new namespace|unshare", re.I)
SHM_HINTS = re.compile(r"/dev/shm|shm_open|no space left on device", re.I)


def _gpu_fix(text, gp, opts, tried):
    """Step the GPU back one notch (gpu.fallback) and re-plan on the next try."""
    step = gpu_fallback(text, gp, tried)
    if not step:
        return None
    desc, key = step

    def apply():
        opts["gpu_tried"] = sorted(set(opts.get("gpu_tried") or []) | {key})
        opts["gpu_plan"] = None
    return desc, key, apply


def pick_fix(problem, plan, opts, host, tried):
    """Decide how to retry a failed start. Returns (description, apply) or None."""
    text = "%s\n%s" % (problem, getattr(problem, "detail", ""))
    kind = getattr(problem, "kind", "")
    if kind == "oom" and "memory" not in tried:
        room = int(host.get("mem_avail_mb", 0) * 0.8)
        new = int(min(room, max(plan["memory_mb"] * 1.75, plan["memory_mb"] + 768)))
        if new > plan["memory_mb"] + 128:
            def apply():
                plan["memory_mb"] = int(round(new / 256.0) * 256)
            return ("it ran out of memory; retrying with %s" % human_mb(new), "memory", apply)
    shm_cap = max(4096, int(host.get("mem_total_mb") or 0) // 2)
    shm_new = int(min(shm_cap, plan["shm_mb"] * 2))
    if SHM_HINTS.search(text) and "shm" not in tried and shm_new > plan["shm_mb"]:
        def apply():
            plan["shm_mb"] = shm_new
        return ("shared memory ran out; retrying with %s /dev/shm" % human_mb(shm_new),
                "shm", apply)
    gp = opts.get("gpu_plan")
    if gp and GPU_HINTS.search(text):
        gfix = _gpu_fix(text, gp, opts, tried)
        if gfix:
            return gfix
    if kind in ("crash", "exited", "nowm") and "seccomp" not in tried and \
            not opts.get("seccomp_unconfined") and \
            (SECCOMP_HINTS.search(text) or kind in ("crash", "nowm")):
        def apply():
            opts["seccomp_unconfined"] = True
        return ("the session was blocked by Docker's syscall filter; retrying with "
                "seccomp unconfined", "seccomp", apply)
    if gp and kind in ("crash", "exited", "nowm"):
        gfix = _gpu_fix(text, gp, opts, tried)
        if gfix:
            return gfix
    if kind == "timeout" and "slow" not in tried:
        def apply():
            opts["health_timeout"] = int(int(opts.get("health_timeout") or 300) * 1.6)
        return ("it is slow to boot on this machine; giving it longer", "slow", apply)
    if kind == "exited" and "restart" not in tried:
        return ("the container stopped during start; trying once more", "restart",
                lambda: None)
    return None
