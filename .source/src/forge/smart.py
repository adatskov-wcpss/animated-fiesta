"""
Selkies Forge engine - smart

The smart chooser: scores catalog entries against this machine and a taste.
"""

from . import catalog
from .host import host_info
from .info import public_entry
from .util import clamp, human_mb


#                    ram   cpu  disk beauty speed ready small
TASTES = {
    "beautiful": dict(ram=0.85, cpu=0.45, disk=0.35, beauty=3.60, speed=0.20,
                      ready=0.30, small=0.05),
    "balanced": dict(ram=1.20, cpu=0.90, disk=0.60, beauty=1.20, speed=1.00,
                     ready=0.70, small=0.50),
    "lightest": dict(ram=1.50, cpu=1.00, disk=1.00, beauty=0.25, speed=1.40,
                     ready=0.50, small=1.60),
    "fastest": dict(ram=1.30, cpu=1.20, disk=0.60, beauty=0.30, speed=2.00,
                    ready=1.00, small=0.90),
}
TASTE_BLURB = {
    "beautiful": "look first, within what the box can actually run",
    "balanced": "an even trade between looks and lightness",
    "lightest": "smallest footprint that is still pleasant",
    "fastest": "lowest latency over the stream, pull over build",
}
PURPOSE_TAGS = {
    "general": {},
    "dev": {"curated": 0.25, "ubuntu": 0.2, "xfce": 0.1},
    "security": {"kali": 0.9, "parrot": 0.8, "remnux": 0.5},
    "retro": {"feather": 0.5, "icewm": 0.3, "fluxbox": 0.3, "twm": 0.4, "wmaker": 0.4},
    "media": {"kde": 0.4, "ubuntu": 0.2, "curated": 0.2},
}


def _fit_curve(need, have_, comfort=0.45):
    """1.0 when `need` is a small slice of `have_`, falling off as it crowds it."""
    if have_ <= 0:
        return 0.0
    r = float(need) / float(have_)
    if r <= comfort:
        return 1.0
    if r >= 1.0:
        return 0.04
    return clamp(1.0 - ((r - comfort) / (1.0 - comfort)) ** 1.35, 0.04, 1.0)


def score_entry(e, host, prefs):
    """Return (score, factors, blockers). Score is 0-100."""
    w = dict(TASTES[prefs.get("taste", "balanced")])
    blockers = []

    if host["arch"] not in e["arches"]:
        blockers.append("no %s image" % host["arch"])
    if e["ram_min"] > host["mem_avail_mb"] * 0.85:
        blockers.append("needs %s RAM, only %s free" % (human_mb(e["ram_min"]),
                                                        human_mb(host["mem_avail_mb"])))
    if e["disk_mb"] + 1024 > host["disk_free_mb"]:
        blockers.append("needs %s disk" % human_mb(e["disk_mb"]))
    if e["kind"] == "build" and not prefs.get("allow_build", True):
        blockers.append("building is switched off")
    if prefs.get("max_dl_mb") and e["dl_mb"] > prefs["max_dl_mb"]:
        blockers.append("download over %s" % human_mb(prefs["max_dl_mb"]))

    f = {}
    f["ram"] = _fit_curve(e["ram_rec"], host["mem_avail_mb"], 0.40)
    # Momentary load shouldn't disqualify every heavy desktop, so treat at
    # least half the box as available.
    cpu_room = max(host["cpu_free"], host["cpus"] * 0.5, 0.5)
    f["cpu"] = _fit_curve(e["cpu_rec"], cpu_room, 0.60)
    f["disk"] = _fit_curve(e["disk_mb"] + 2048, max(1, host["disk_free_mb"]), 0.25)
    f["beauty"] = e["beauty"] / 100.0
    f["speed"] = e["speed"] / 100.0
    f["ready"] = 1.0 if e["kind"] == "pull" else 0.45
    f["small"] = clamp(1.0 - (e["dl_mb"] / 3000.0), 0.0, 1.0)

    base = sum(w[k] * f[k] for k in f) / sum(w.values())

    bonus = 0.0
    notes = []
    purpose = prefs.get("purpose", "general")
    tagw = PURPOSE_TAGS.get(purpose, {})
    if tagw:
        best = 0.0
        for tag, val in tagw.items():
            if tag in e["tags"] or tag == e["family"] or tag == e["de"]:
                best = max(best, val)
        if best:
            bonus += best * 0.25
            notes.append("carries what %s work needs" % purpose)
        else:
            bonus -= 0.08
    fam = prefs.get("family")
    if fam and e["family"] == fam:
        bonus += 0.05
        notes.append("the %s family you asked for" % catalog.FAMILY_LABEL.get(fam, fam))
    if "verified" in e["tags"]:
        bonus += 0.035
        notes.append("prebuilt and known good")
    if e["profile"] == "kasm" and prefs.get("want_tunnel", True):
        bonus -= 0.06
        notes.append("https image, so only a limited TCP tunnel")
    # A desktop that wants more RAM than half of free memory is a gamble.
    if e["ram_rec"] > host["mem_avail_mb"] * 0.5:
        bonus -= 0.05

    score = clamp((base + bonus) * 100.0, 0.0, 100.0)
    if blockers:
        score = 0.0
    return score, f, blockers, notes


def plan_resources(e, host, generous=False):
    """Pick cpu/memory/shm/disk for this entry on this host."""
    avail = max(512, host["mem_avail_mb"])
    share = 0.70 if generous else 0.55
    mem = clamp(e["ram_rec"], e["ram_min"], int(avail * share))
    mem = int(max(e["ram_min"], round(mem / 256.0) * 256))
    cores = max(1.0, float(host["cpus"]))
    cpus = clamp(e["cpu_rec"], 1.0, max(1.0, cores - 0.5 if cores > 1 else cores))
    cpus = round(cpus * 2) / 2.0
    shm = int(clamp(mem / 4.0, 256, 2048))

    # Give the desktop room to actually live in: the image itself plus a real
    # working allowance, never less than 10 GB, and never more than most of
    # what is free.
    want = max(10240, int(e["disk_mb"] * 2.0) + 6144)
    ceiling = int(max(5120, host.get("disk_free_mb", 0) * 0.85))
    disk = int(clamp(want, 5120, ceiling))
    disk = int(round(disk / 1024.0) * 1024)
    return {"memory_mb": mem, "cpus": cpus, "shm_mb": shm, "disk_mb": disk,
            "swap_mb": 0}


def recommend(prefs=None, limit=3, host=None):
    prefs = prefs or {}
    host = host or host_info(fresh=True)
    scored = []
    for e in catalog.CATALOG:
        s, f, blockers, notes = score_entry(e, host, prefs)
        if blockers:
            continue
        scored.append((s, f, notes, e))
    scored.sort(key=lambda t: -t[0])

    # Don't hand back three flavours of the same thing.  Try strict variety
    # first, then relax until we have enough picks.
    chosen = []
    for max_de, max_fam in ((1, 1), (1, 2), (2, 2), (99, 99)):
        chosen, seen_de, seen_fam = [], {}, {}
        for row in scored:
            e = row[3]
            if len(chosen) >= limit:
                break
            if seen_de.get(e["de"], 0) >= max_de:
                continue
            if seen_fam.get(e["family"], 0) >= max_fam:
                continue
            seen_de[e["de"]] = seen_de.get(e["de"], 0) + 1
            seen_fam[e["family"]] = seen_fam.get(e["family"], 0) + 1
            chosen.append(row)
        if len(chosen) >= min(limit, len(scored)):
            break

    picks = []
    for s, f, notes, e in chosen:
        picks.append({
            "id": e["id"], "name": e["name"], "score": round(s, 1),
            "factors": {k: round(v, 3) for k, v in f.items()},
            "why": _why(e, f, notes, host),
            "plan": plan_resources(e, host),
            "entry": public_entry(e),
        })
    return {"host": host, "prefs": prefs, "picks": picks,
            "considered": len(scored),
            "taste": TASTE_BLURB[prefs.get("taste", "balanced")]}


def _why(e, f, notes, host):
    out = []
    if f["ram"] > 0.9:
        out.append("sits well inside your %s of free RAM" % human_mb(host["mem_avail_mb"]))
    elif f["ram"] > 0.6:
        out.append("fits your free RAM with room to spare")
    else:
        out.append("will use a real slice of your RAM")
    if e["kind"] == "pull":
        out.append("prebuilt, so it only has to download %s" % human_mb(e["dl_mb"]))
    else:
        out.append("built locally from %s, about %s to fetch first"
                   % (e["distro"], human_mb(e["dl_mb"])))
    if e["beauty"] >= 88:
        out.append("one of the best looking desktops in the catalog")
    elif e["heavy"] <= 20:
        out.append("barely registers on the CPU, idles near %s" % human_mb(e["idle_mb"]))
    out.extend(notes)
    return out[:4]
