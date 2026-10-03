"""
Selkies Forge engine - space

What the forge is using on disk, and cleaning it up.

  forge layers      selkies-forge/run-*: a few KB each on top of a desktop image;
                    old ones are safe to delete (they are rebuilt in seconds)
  built desktops    selkies-forge/<id>:latest: the package installs; slow to
                    rebuild, so only removed with --all and only when unused
  pulled desktops   webtop and kasm images from the catalog; only with --all,
                    only when no desktop uses them
  orphan volumes    forge-config-* volumes whose desktop was removed but whose
                    files were kept; only with --volumes, because they are files
  build cache       docker's builder cache; with --all

Nothing in use by a container (running or stopped) is ever removed.
"""

import json

from . import catalog
from .paths import CPREFIX, IPREFIX, LABEL
from .util import run, slug


def _images():
    rc, out, _ = run(["docker", "images", "--format", "{{json .}}"], timeout=60)
    rows = []
    for line in out.splitlines() if rc == 0 else []:
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    return rows


def _used_images():
    rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Image}}"], timeout=30)
    used = set(out.split()) if rc == 0 else set()
    # A container records the tag it was made from; resolve to IDs as well.
    ids = set()
    for ref in used:
        rc, out, _ = run(["docker", "image", "inspect", "-f", "{{.Id}}", ref], timeout=20)
        if rc == 0:
            ids.add(out.strip())
    return used, ids


def _size_mb(txt):
    txt = (txt or "").strip().upper()
    try:
        for unit, mul in (("GB", 1024.0), ("MB", 1.0), ("KB", 1 / 1024.0), ("B", 1 / 1048576.0)):
            if txt.endswith(unit):
                return float(txt[:-len(unit)]) * mul
    except ValueError:
        pass
    return 0.0


def report():
    used_refs, used_ids = _used_images()
    catalog_images = {e["image"] for e in catalog.CATALOG if e.get("image")}
    catalog_bases = {e["recipe"]["image"] for e in catalog.CATALOG if e.get("recipe")}
    groups = {"layers": [], "built": [], "pulled": [], "bases": []}
    for im in _images():
        ref = "%s:%s" % (im.get("Repository"), im.get("Tag"))
        row = {"ref": ref, "id": im.get("ID"), "size_mb": round(_size_mb(im.get("Size")), 1),
               "in_use": ref in used_refs or any(i.startswith("sha256:" + (im.get("ID") or "~"))
                                                 for i in used_ids)}
        if ref.startswith(IPREFIX + "run-"):
            groups["layers"].append(row)
        elif ref.startswith(IPREFIX):
            groups["built"].append(row)
        elif ref in catalog_images:
            groups["pulled"].append(row)
        elif ref in catalog_bases:
            groups["bases"].append(row)
    # A forge layer's reported size includes the desktop image under it; what
    # deleting it frees is only the difference (usually a few hundred KB).
    sizes = {}
    for g in groups.values():
        for r in g:
            sizes[r["ref"]] = r["size_mb"]
    by_slug = {slug(e["id"])[:60]: e for e in catalog.CATALOG}
    for r in groups["layers"]:
        e = by_slug.get(r["ref"][len(IPREFIX + "run-"):].split(":")[0])
        base = None
        if e:
            base = e["image"] if e["kind"] == "pull" else "%s%s:latest" % (IPREFIX, e["id"])
        r["total_mb"] = r["size_mb"]
        if base in sizes:
            r["size_mb"] = round(max(0.1, r["size_mb"] - sizes[base]), 1)
    rc, out, _ = run(["docker", "volume", "ls", "-q"], timeout=30)
    vols = [v for v in out.split() if v.startswith(CPREFIX + "config-")] if rc == 0 else []
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=30)
    names = set(out.split()) if rc == 0 else set()
    orphans = [v for v in vols if v[len(CPREFIX + "config-"):] not in names]
    rc, out, _ = run(["docker", "system", "df", "--format", "{{json .}}"], timeout=60)
    cache_mb = 0.0
    for line in out.splitlines() if rc == 0 else []:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("Type") == "Build Cache":
            cache_mb = _size_mb(row.get("Size"))
    out = {"groups": groups, "orphan_volumes": orphans, "build_cache_mb": round(cache_mb, 1)}
    out["reclaimable_mb"] = round(
        sum(r["size_mb"] for r in groups["layers"] if not r["in_use"]), 1)
    out["reclaimable_all_mb"] = round(out["reclaimable_mb"] + cache_mb + sum(
        r["size_mb"] for g in ("built", "pulled", "bases") for r in groups[g] if not r["in_use"]), 1)
    return out


def clean(everything=False, volumes=False, dry_run=False):
    """Remove what report() calls reclaimable. Returns what was (or would be) removed."""
    rep = report()
    targets = [r["ref"] for r in rep["groups"]["layers"] if not r["in_use"]]
    if everything:
        targets += [r["ref"] for g in ("built", "pulled", "bases") for r in rep["groups"][g]
                    if not r["in_use"]]
    removed, failed = [], {}
    for ref in targets:
        if dry_run:
            removed.append(ref)
            continue
        rc, out, err = run(["docker", "rmi", ref], timeout=300)
        (removed.append(ref) if rc == 0 else failed.__setitem__(ref, (err or out).strip()[:200]))
    vols = rep["orphan_volumes"] if volumes else []
    for v in vols:
        if not dry_run:
            run(["docker", "volume", "rm", v], timeout=120)
    if everything and not dry_run:
        run(["docker", "builder", "prune", "-af"], timeout=900)
    if not dry_run:
        run(["docker", "image", "prune", "-f"], timeout=300)
    return {"removed_images": removed, "failed": failed, "removed_volumes": vols,
            "dry_run": dry_run, "build_cache": everything}
