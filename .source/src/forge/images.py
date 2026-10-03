"""
Selkies Forge engine - images

Getting images: docker pull with progress, docker build, and the forge layer.
"""

import os
import re
import shutil
import time

from collections import deque

from . import layer
from .host import host_info, image_id, image_present
from .jobs import CommandStalled, stream_cmd, stream_cmd_pty
from .scheduler import slot
from .paths import ANSI_RE, BUILDDIR, IPREFIX, LABEL
from .recipes import build_image_tag, gen_dockerfile, gen_startwm
from .util import clamp, parse_size, run, slug


class PullProgress(object):
    """Turns `docker pull` chatter into one number between 0 and 1."""

    LAYER = re.compile(r"^([0-9a-f]{6,}):\s+(.*)$")
    BYTES = re.compile(r"\[[=>\s]*\]\s+([\d.]+\s*[a-zA-Z]+)\s*/\s*([\d.]+\s*[a-zA-Z]+)")

    def __init__(self):
        self.layers = {}
        self.done = False

    def feed(self, line):
        line = ANSI_RE.sub("", line).strip()
        if not line:
            return None
        if line.startswith("Status:") or line.startswith("Digest:"):
            if line.startswith("Status:"):
                self.done = True
            return None
        m = self.LAYER.match(line)
        if not m:
            return None
        lid, rest = m.group(1), m.group(2)
        st = self.layers.setdefault(lid, {"phase": "wait", "cur": 0, "total": 0,
                                          "ex_cur": 0, "ex_total": 0})
        low = rest.lower()

        if "already exists" in low or "pull complete" in low:
            st["phase"] = "done"
        elif "extracting" in low:
            st["phase"] = "extract"
        elif "download complete" in low or "verifying" in low:
            st["phase"] = "downloaded"
        elif "downloading" in low:
            st["phase"] = "download"
        elif "waiting" in low or "pulling fs layer" in low:
            st["phase"] = "wait"

        # Download and unpack both report bytes; keep them in separate buckets
        # so the headline "x of y downloaded" never walks backwards.
        b = self.BYTES.search(rest)
        if b:
            cur, total = parse_size(b.group(1)), parse_size(b.group(2))
            if st["phase"] == "extract":
                st["ex_cur"], st["ex_total"] = cur, max(st["ex_total"], total)
            else:
                st["cur"], st["total"] = cur, max(st["total"], total)
        if st["phase"] in ("downloaded", "extract", "done") and st["total"]:
            st["cur"] = st["total"]
        return lid

    def fraction(self):
        if not self.layers:
            return 0.0
        if self.done:
            return 1.0
        # Downloading is 75% of the work of a layer, unpacking the rest.
        num = den = 0.0
        for st in self.layers.values():
            w = float(st["total"] or 40 * 1024 * 1024)
            den += w
            ph = st["phase"]
            if ph == "done":
                num += w
            elif ph == "extract":
                frac = (st["ex_cur"] / float(st["ex_total"])) if st["ex_total"] else 0.5
                num += w * (0.75 + 0.25 * clamp(frac, 0, 1))
            elif ph == "downloaded":
                num += w * 0.75
            elif ph == "download":
                frac = (st["cur"] / float(st["total"])) if st["total"] else 0.0
                num += w * 0.75 * clamp(frac, 0, 1)
        return clamp(num / den if den else 0.0, 0.0, 0.999)

    def summary(self):
        cur = sum(s["cur"] for s in self.layers.values())
        tot = sum(s["total"] for s in self.layers.values())
        done = sum(1 for s in self.layers.values() if s["phase"] == "done")
        return {"layers": len(self.layers), "layers_done": done,
                "bytes": cur, "bytes_total": tot}


def layer_repo(entry):
    return "%srun-%s" % (IPREFIX, slug(entry["id"])[:60])


def ensure_layer(entry, base_image, job=None):
    """Return the image to run: base_image plus the forge layer on top."""
    if entry.get("profile") == "kasm":
        return base_image
    startwm = gen_startwm(entry) if entry["kind"] == "build" else None
    dig = layer.digest(image_id(base_image), startwm)
    tag = "%s:%s" % (layer_repo(entry), dig)
    if image_present(tag):
        if job:
            job.log("layer    : %s (already built)" % tag)
        return tag
    ctx = os.path.join(BUILDDIR, "layer-" + slug(entry["id"]))
    shutil.rmtree(ctx, ignore_errors=True)
    os.makedirs(ctx, exist_ok=True)
    for rel, (content, mode) in layer.files(startwm).items():
        path = os.path.join(ctx, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content if isinstance(content, bytes) else content.encode())
        os.chmod(path, mode)
    with open(os.path.join(ctx, "Dockerfile"), "w") as fh:
        fh.write(layer.dockerfile(base_image, LABEL, entry["id"], dig, startwm=bool(startwm)))
    if job:
        job.log("layer    : adding the forge layer (first-run fixes, screen agent%s)"
                % (", session supervisor" if startwm else ""))
    lines = []
    env = dict(os.environ)
    env["DOCKER_BUILDKIT"] = "1"
    rc = stream_cmd(["docker", "build", "--progress=plain", "-t", tag, ctx],
                    lines.append, env=env, timeout=900, job=job)
    if rc != 0:
        # No buildx on this Docker: the classic builder handles a file this simple.
        env["DOCKER_BUILDKIT"] = "0"
        lines = []
        rc = stream_cmd(["docker", "build", "-t", tag, ctx], lines.append, env=env, timeout=900,
                        job=job)
    if rc != 0:
        raise RuntimeError("could not add the forge layer:\n" + "\n".join(lines[-12:]))
    # Older layers of this entry are only a few KB each, but tidy them anyway.
    rc, out, _ = run(["docker", "images", layer_repo(entry), "--format", "{{.Tag}}"], timeout=30)
    for t in out.split():
        if t != dig:
            run(["docker", "rmi", "%s:%s" % (layer_repo(entry), t)], timeout=60)
    if job:
        job.log("layer    : %s" % tag)
    return tag


def get_image(entry, host, job, opts):
    """Pull or build the desktop image. Returns its tag.

    Pulls and builds take a scheduler slot first (see scheduler.py), and look
    again once they have it: another launch may have fetched the same image
    while this one waited.
    """
    if entry["kind"] == "pull":
        image = entry["image"]
        if image_present(image) and not opts.get("force_pull"):
            job.set_phase("fetch", "Image already here, skipping the pull", 0.70)
            job.log("image already present locally, not pulling again")
            return image
        with slot("pull", job):
            if image_present(image) and not opts.get("force_pull"):
                job.log("image arrived while this launch was queued")
                return image
            job.set_phase("fetch", "Pulling %s" % image, 0.02)
            do_pull(image, host["arch"], job)
        return image
    image = build_image_tag(entry)
    if image_present(image) and not opts.get("force_build"):
        job.set_phase("fetch", "Built image already here", 0.70)
        job.log("%s already built, reusing it" % image)
        return image
    base = entry["recipe"]["image"]
    if not image_present(base):
        with slot("pull", job):
            if not image_present(base):
                job.set_phase("fetch", "Pulling base %s" % base, 0.02)
                do_pull(base, host["arch"], job, weight=(0.02, 0.45))
    job.check()
    with slot("build", job):
        if image_present(image) and not opts.get("force_build"):
            job.log("%s was built while this launch was queued" % image)
            return image
        job.set_phase("build", "Building %s" % entry["name"], 0.46)
        do_build(entry, image, job)
    return image


BAR_LINE = re.compile(r"\[[=>\s]*\]")


def _stall_limit(var, default):
    """Seconds of silence before a pull or build counts as stuck."""
    try:
        return max(30, int(os.environ.get(var, default)))
    except ValueError:
        return default


# A pull prints progress every second while bytes move; four silent minutes
# means a dead connection. Package installs can sit quietly in a long
# post-install script, so a build gets twenty.
PULL_STALL = _stall_limit("FORGE_PULL_STALL", 240)
BUILD_STALL = _stall_limit("FORGE_BUILD_STALL", 1200)
NET_FLAKY = re.compile(r"tls handshake timeout|i/o timeout|connection reset|unexpected eof|"
                       r"context deadline exceeded|toomanyrequests|too many requests|"
                       r"\b50[234]\b|temporary failure|net/http|connection refused|"
                       r"no route to host|eof$|timeout exceeded|failed to fetch|"
                       r"could not resolve|hash sum mismatch|failed retrieving file|"
                       r"curl error|could not connect|connection timed out", re.I)


def do_pull(image, arch, job, weight=(0.02, 0.78)):
    """docker pull with a live progress bar, retried on network hiccups."""
    lo, hi = weight
    tail = deque(maxlen=30)
    for attempt in range(1, 5):
        prog = PullProgress()
        last = [0.0]
        seen = set()

        def on_line(line):
            clean = ANSI_RE.sub("", line).strip()
            if not clean:
                return
            tail.append(clean)
            lid = prog.feed(clean)
            # A pty makes docker repaint every layer on every tick. Log each
            # layer/status once and let the progress bar carry the rest.
            if BAR_LINE.search(clean) and lid:
                key = (lid, prog.layers[lid]["phase"])
                if key not in seen:
                    seen.add(key)
                    job.log("%s: %s" % (lid, prog.layers[lid]["phase"]))
            else:
                if clean not in seen:
                    seen.add(clean)
                    job.log(clean)
            f = prog.fraction()
            if f - last[0] > 0.003 or f >= 0.999:
                last[0] = f
                job.set_progress(lo + (hi - lo) * f, prog.summary())

        cmd = ["docker", "pull", "--platform", "linux/%s" % arch, image]
        try:
            rc = stream_cmd_pty(cmd, on_line, timeout=5400, job=job, stall=PULL_STALL)
        except CommandStalled as st:
            if attempt < 4:
                job.log("pull stalled: no progress for %ds (a dead connection); restarting it, "
                        "already downloaded layers are kept" % st.seconds, "err")
                time.sleep(3)
                continue
            raise RuntimeError("docker pull of %s kept stalling (no progress for %ds, %d times); "
                               "the network or registry is not delivering" % (image, st.seconds,
                                                                              attempt))
        if rc == 0:
            job.set_progress(hi, prog.summary())
            return
        txt = "\n".join(tail)
        if re.search(r"manifest unknown|not found|no matching manifest", txt, re.I):
            raise RuntimeError("the image tag is gone from the registry: %s" % image)
        if attempt < 4 and (NET_FLAKY.search(txt) or rc in (1, 255)):
            wait = 5 * attempt
            job.log("pull interrupted (%s); retrying in %ds, already downloaded layers are kept"
                    % ((tail[-1] if tail else "exit %d" % rc)[:120], wait), "err")
            time.sleep(wait)
            continue
        break
    raise RuntimeError("docker pull failed for %s (exit %d): %s"
                       % (image, rc, (tail[-1] if tail else "")[:200]))


BUILD_STEP = re.compile(r"^#(\d+)\s")


def do_build(entry, tag, job, weight=(0.46, 0.78)):
    lo, hi = weight
    ctx = os.path.join(BUILDDIR, slug(entry["id"]))
    os.makedirs(ctx, exist_ok=True)
    df = gen_dockerfile(entry)
    with open(os.path.join(ctx, "Dockerfile"), "w") as fh:
        fh.write(df)
    job.log("build context: %s" % ctx)
    job.log("installing: %s" % entry["recipe"]["pkgs"])

    # Package installs dominate the time; step counting gives a usable curve.
    seen = {"max": 0.0, "pkgs": 0}
    total_pkgs = max(1, len(entry["recipe"]["pkgs"].split()))
    tail = deque(maxlen=60)

    def on_line(line):
        clean = ANSI_RE.sub("", line)
        if clean.strip():
            job.log(clean)
            tail.append(clean)
        low = clean.lower()
        if "setting up " in low or ">> forge: ok" in low or "installing" in low:
            seen["pkgs"] = min(total_pkgs, seen["pkgs"] + 1)
        frac = clamp(0.08 + 0.85 * (seen["pkgs"] / float(total_pkgs)), 0.0, 0.95)
        if "exporting layers" in low or "writing image" in low:
            frac = 0.98
        if frac > seen["max"] + 0.004:
            seen["max"] = frac
            job.set_progress(lo + (hi - lo) * frac,
                             {"packages": seen["pkgs"], "packages_total": total_pkgs})

    for attempt in (1, 2, 3):
        env = dict(os.environ)
        env["DOCKER_BUILDKIT"] = "1"
        env["BUILDKIT_PROGRESS"] = "plain"
        cmd = ["docker", "build", "--progress=plain", "--platform",
               "linux/%s" % host_info()["arch"], "-t", tag, "-f",
               os.path.join(ctx, "Dockerfile"), ctx]
        try:
            rc = stream_cmd(cmd, on_line, env=env, timeout=10800, job=job, stall=BUILD_STALL)
        except CommandStalled as st:
            if attempt < 3:
                job.log("build stalled: no output for %ds; restarting it (finished steps are "
                        "cached)" % st.seconds, "err")
                continue
            raise RuntimeError("docker build of %s kept stalling (no output for %ds)"
                               % (entry["id"], st.seconds))
        if rc == 0:
            job.set_progress(hi)
            return
        txt = "\n".join(tail)
        if "exit code: 97" in txt or "FATAL none of these session" in txt:
            raise RuntimeError("docker build failed for %s: the desktop's packages did not "
                               "install (exit code 97, session binaries missing)" % entry["id"])
        if attempt < 3 and NET_FLAKY.search(txt):
            job.log("build hit a network error; retrying in %ds (finished steps are cached)"
                    % (10 * attempt), "err")
            time.sleep(10 * attempt)
            continue
        break
    raise RuntimeError("docker build failed for %s (exit %d). The log above "
                       "says which package broke." % (entry["id"], rc))
