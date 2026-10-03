"""
Selkies Forge engine - backups

A desktop's files live in its /config volume. This module copies them out
(backup), puts a copy back (restore), and starts a second desktop from a copy
(clone).

  backup   tar.gz of the volume in FORGE_HOME/backups/, plus a .json note:
           which desktop, which catalog entry, its limits and options, so a
           backup can become a desktop again even after the original is gone.
           Caches (~/.cache) are left out unless asked for; they are large
           and rebuild themselves.
  restore  replaces a desktop's files with a backup's. A safety backup of the
           current files is taken first, so a restore can itself be undone.
           A running desktop is stopped for the swap and started again.
  clone    copies a desktop's files into a new volume and launches the same
           catalog entry on it, with the same limits and options: a second,
           independent desktop with everything the first had.

Every container used for this is the desktop's own image (already on this
machine, so nothing is downloaded) with tar or cp as its entrypoint. The
archive streams through this process, so it is owned by you, not root.
"""

import json
import os
import re
import subprocess
import time

from . import catalog, events
from .jobs import Job, job_put
from .lifecycle import instance_action
from .paths import BACKUPDIR, CPREFIX, LABEL
from .runner import container_name_for
from .store import reg_load
from .util import ensure_dirs, human_mb, run, slug

SAFE_FILE = re.compile(r"^[A-Za-z0-9_.-]+\.tar\.gz$")


def _inspect(name):
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad desktop name")
    rc, out, err = run(["docker", "inspect", name], timeout=40)
    if rc != 0:
        raise RuntimeError("no such desktop: %s" % name)
    c = json.loads(out)[0]
    labels = (c.get("Config") or {}).get("Labels") or {}
    vol = labels.get("%s.volume" % LABEL)
    if not vol:
        raise RuntimeError("%s has no forge volume to back up" % name)
    return c, labels, vol


def _helper(image, *docker_args):
    """`docker run` of the desktop's own image as a one-shot file tool."""
    return ["docker", "run", "--rm", "--network", "none"] + list(docker_args) + [image]


def _meta_for(name, c, labels, vol):
    hostcfg = c.get("HostConfig") or {}
    note = reg_load().get(name) or {}
    return {
        "name": name, "entry_id": labels.get("%s.entry" % LABEL),
        "title": labels.get("%s.title" % LABEL), "volume": vol,
        "display": labels.get("%s.display" % LABEL), "forge_version": labels.get("%s.version" % LABEL),
        "image": (c.get("Config") or {}).get("Image"),
        "limits": {"memory_mb": int((hostcfg.get("Memory") or 0) / 1048576) or None,
                   "cpus": round((hostcfg.get("NanoCpus") or 0) / 1e9, 2) or None,
                   "shm_mb": int((hostcfg.get("ShmSize") or 0) / 1048576) or None,
                   "disk_mb": note.get("plan", {}).get("disk_mb")},
        "opts": {k: v for k, v in (note.get("opts") or {}).items()
                 if k in ("display", "resolution", "gpu", "seccomp_unconfined", "heal", "locale")},
    }


def backup(name, include_cache=False, job=None, tag=None):
    """Write a backup of a desktop's files. Returns the backup's note."""
    job = job or job_put(Job("backup", name, "Back up %s" % name))
    c, labels, vol = _inspect(name)
    ensure_dirs()
    os.makedirs(BACKUPDIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = "%s-%s%s" % (slug(name), stamp, "-" + slug(tag) if tag else "")
    path = os.path.join(BACKUPDIR, base + ".tar.gz")
    image = (c.get("Config") or {}).get("Image")
    job.set_phase("backup", "Backing up %s" % name, 0.05)
    job.log("backup   : %s (volume %s) -> %s" % (name, vol, path))
    if (c.get("State") or {}).get("Running"):
        job.log("note     : it is running; files being written right now may be caught "
                "half-way (stop it first for a perfectly still copy)")
    excl = [] if include_cache else ["--exclude=./.cache"]
    cmd = _helper(image, "-v", "%s:/v:ro" % vol, "--entrypoint", "tar") + \
        ["-czf", "-", "-C", "/v"] + excl + ["."]
    tmp = path + ".part"
    t0 = time.time()
    with open(tmp, "wb") as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.PIPE, start_new_session=True)
        job.attach(p)
        try:
            while p.poll() is None:
                time.sleep(1.0)
                job.check()
                job.set_progress(min(0.9, 0.05 + (time.time() - t0) / 600.0),
                                 {"bytes": os.path.getsize(tmp)})
        finally:
            job.detach(p)
        err = p.stderr.read().decode("utf-8", "replace")
    # GNU tar exits 1 when a file changed while it was read: still a good backup.
    if p.returncode not in (0, 1) or os.path.getsize(tmp) < 20:
        os.remove(tmp)
        raise RuntimeError("the backup failed (tar exit %s): %s" % (p.returncode, err.strip()[-300:]))
    os.replace(tmp, path)
    meta = _meta_for(name, c, labels, vol)
    meta.update({"file": os.path.basename(path), "created": time.time(),
                 "size": os.path.getsize(path), "include_cache": bool(include_cache),
                 "tag": tag})
    with open(path[:-len(".tar.gz")] + ".json", "w") as fh:
        json.dump(meta, fh, indent=2)
    events.record(name, "backup", "%s (%s)" % (meta["file"], human_mb(meta["size"] / 1048576.0)))
    job.log("backup   : done, %s in %ds" % (human_mb(meta["size"] / 1048576.0), time.time() - t0))
    job.finish({"backup": meta, "file": meta["file"], "size": meta["size"], "name": name})
    return meta


def list_backups(name=None):
    try:
        files = sorted(f for f in os.listdir(BACKUPDIR) if f.endswith(".json"))
    except OSError:
        return []
    out = []
    for f in files:
        try:
            with open(os.path.join(BACKUPDIR, f)) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        if not os.path.exists(os.path.join(BACKUPDIR, meta.get("file") or "")):
            continue
        if name and meta.get("name") != name:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("created") or 0, reverse=True)
    return out


def _backup_path(file):
    if not SAFE_FILE.match(file or ""):
        raise RuntimeError("bad backup file name")
    path = os.path.join(BACKUPDIR, file)
    if not os.path.exists(path):
        raise RuntimeError("no such backup: %s" % file)
    return path


def delete_backup(file):
    path = _backup_path(file)
    os.remove(path)
    try:
        os.remove(path[:-len(".tar.gz")] + ".json")
    except OSError:
        pass
    return {"deleted": file}


def restore(name, file, job=None):
    """Replace a desktop's files with a backup's (after a safety backup)."""
    job = job or job_put(Job("restore", name, "Restore %s" % name))
    path = _backup_path(file)
    c, labels, vol = _inspect(name)
    image = (c.get("Config") or {}).get("Image")
    was_running = bool((c.get("State") or {}).get("Running"))
    job.set_phase("safety", "Saving the current files first", 0.05)
    safety = backup(name, job=Job("backup", name, "Safety backup"), tag="before-restore")
    job.log("safety   : current files saved as %s" % safety["file"])
    job.check()
    if was_running:
        job.set_phase("stop", "Stopping %s for the swap" % name, 0.4)
        events.record(name, "backup-restore", "restoring %s" % file)
        instance_action(name, "stop")
    job.set_phase("restore", "Restoring %s" % file, 0.5)
    cmd = _helper(image, "-i", "-v", "%s:/v" % vol, "--entrypoint", "sh") + \
        ["-c", "find /v -mindepth 1 -delete && tar -xzf - -C /v"]
    with open(path, "rb") as fh:
        p = subprocess.run(cmd, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=3600)
    if p.returncode != 0:
        raise RuntimeError("the restore failed: %s (your files before the restore are in %s)"
                           % (p.stderr.decode("utf-8", "replace").strip()[-300:], safety["file"]))
    events.record(name, "restored", "files replaced from %s (previous files: %s)"
                  % (file, safety["file"]))
    if was_running:
        job.set_phase("start", "Starting %s again" % name, 0.9)
        instance_action(name, "start")
    job.log("restore  : done; the files from before are in %s" % safety["file"])
    job.finish({"name": name, "file": file, "safety": safety["file"]})
    return {"name": name, "file": file, "safety": safety["file"]}


def clone(name, new_name=None, job=None, tunnel=False, from_backup=None):
    """A second desktop with a copy of a desktop's files (or of a backup's).

    `name` is the desktop to copy; with `from_backup` it may be gone, and the
    backup's note says which catalog entry and limits to use.
    """
    from .launch import launch                      # launch imports lifecycle
    from .host import host_info
    from .smart import plan_resources
    meta = None
    if from_backup:
        path = _backup_path(from_backup)
        with open(path[:-len(".tar.gz")] + ".json") as fh:
            meta = json.load(fh)
        src_c = None
        entry_id = meta.get("entry_id")
        base_name = new_name or "%s-copy" % (meta.get("name") or "desktop").replace(CPREFIX, "", 1)
    else:
        src_c, labels, src_vol = _inspect(name)
        meta = _meta_for(name, src_c, labels, src_vol)
        entry_id = meta["entry_id"]
        base_name = new_name or "%s-copy" % name.replace(CPREFIX, "", 1)
    entry = catalog.BY_ID.get(entry_id)
    if not entry:
        raise RuntimeError("that desktop's catalog entry (%s) is not in this version" % entry_id)
    job = job or job_put(Job("clone", entry_id, "Clone %s" % (name or from_backup)))
    cname = container_name_for(entry, base_name)
    vol = "%sconfig-%s" % (CPREFIX, slug(cname))
    if run(["docker", "volume", "inspect", vol], timeout=20)[0] == 0:
        raise RuntimeError("a volume named %s already exists (files of a removed desktop); "
                           "pick another name" % vol)
    job.note(container=cname, volume=vol)
    job.set_phase("copy", "Copying the files", 0.02)
    run(["docker", "volume", "create", "--label", "%s.clone-of=%s" % (LABEL, name or from_backup),
         vol], timeout=30)
    if from_backup:
        image = meta.get("image")
        if not image or run(["docker", "image", "inspect", image], timeout=20)[0] != 0:
            image = entry["image"] if entry["kind"] == "pull" else None
        if not image or run(["docker", "image", "inspect", image], timeout=20)[0] != 0:
            image = "busybox"
        cmd = _helper(image, "-i", "-v", "%s:/v" % vol, "--entrypoint", "tar") + \
            ["-xzf", "-", "-C", "/v"]
        with open(_backup_path(from_backup), "rb") as fh:
            p = subprocess.run(cmd, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=3600)
    else:
        image = (src_c.get("Config") or {}).get("Image")
        cmd = _helper(image, "-v", "%s:/s:ro" % src_vol, "-v", "%s:/d" % vol,
                      "--entrypoint", "cp") + ["-a", "/s/.", "/d/"]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3600)
    if p.returncode != 0:
        run(["docker", "volume", "rm", "-f", vol], timeout=60)
        raise RuntimeError("copying the files failed: %s"
                           % p.stderr.decode("utf-8", "replace").strip()[-300:])
    job.log("copy     : files copied into %s" % vol)
    job.check()
    host = host_info(fresh=True)
    plan = plan_resources(entry, host)
    for k in ("memory_mb", "cpus", "shm_mb", "disk_mb"):
        if (meta.get("limits") or {}).get(k):
            plan[k] = meta["limits"][k]
    opts = dict(meta.get("opts") or {})
    opts.update({"tunnel": bool(tunnel), "prepared_volume": True})
    res = launch(entry_id, plan, opts, job=job, name=cname[len(CPREFIX):])
    events.record(res["name"], "cloned", "from %s" % (name or from_backup))
    return res
