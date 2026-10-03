"""
Selkies Forge engine - info

Wikipedia/Commons descriptions and pictures, real screenshots, public catalog fields.
"""

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

from . import catalog
from .paths import DATADIR
from .util import jload


# Descriptions and screenshots are fetched from Wikipedia when the script is
# built (fetch_info.py) and shipped inside it, so every entry has them instantly
# and offline, and the app never trips Wikimedia's rate limits.
_INFO = None
FALLBACK_TEXT = {
    "remnux": "REMnux is an Ubuntu-based Linux toolkit for reverse-engineering and "
              "analysing malicious software, bundling hundreds of free analysis tools.",
    "generic-mac": "A clean, Mac-like layout built on Debian: a slim top panel, a dock "
                   "along the bottom and a calm dark theme. It is ordinary Linux underneath.",
    "generic-win": "A familiar Windows-like layout built on Debian: one taskbar along the "
                   "bottom, a start-style menu and plain grey chrome.",
}


def info_db():
    global _INFO
    if _INFO is None:
        try:
            with open(os.path.join(DATADIR, "info.json")) as fh:
                _INFO = json.load(fh)
        except Exception:
            _INFO = {"families": {}, "desktops": {}}
    return _INFO


def entry_info(e):
    db = info_db()
    fams, des = db.get("families", {}), db.get("desktops", {})
    de_key = e["de"]
    base_family = catalog.BASES[e["base"]]["family"] if e.get("base") else e["family"]

    def article(src, kind):
        if not src:
            return None
        return {"kind": kind, "title": src.get("title"), "url": src.get("url"),
                "extract": src.get("extract"), "lead": src.get("lead")}

    distro = fams.get(e["family"])
    based_on = None
    if not distro:
        distro = fams.get(base_family)
    elif base_family != e["family"] and fams.get(base_family):
        based_on = fams.get(base_family)          # e.g. Mint-style built on Ubuntu

    desktop = des.get(de_key)
    out = {
        "distro": article(distro, "distro"),
        "based_on": article(based_on, "base"),
        "desktop": article(desktop, "desktop"),
        "fallback": FALLBACK_TEXT.get(e["family"]),
        "desktop_blurb": catalog.DESKTOPS.get(de_key, {}).get("blurb"),
        "images": [],
        "source": db.get("source"),
        "fetched": db.get("fetched"),
    }
    # What you will actually see is the desktop, so only its screenshots are
    # shown, plus distro screenshots that show this same desktop (Debian's
    # "KDE default desktop" for a Debian KDE entry, Alpine's Xfce shots for
    # Alpine Xfce). A distro's stock screenshot of some other desktop, like
    # Ubuntu's GNOME under Ubuntu Enlightenment, says nothing about this one.
    pat = DE_PICTURE_WORDS.get(de_key)
    seen = set()
    for src, tag in ((desktop, "desktop"), (distro, "distro"), (based_on, "base")):
        for img in (src or {}).get("images", []):
            if img["src"] in seen:
                continue
            if tag != "desktop":
                text = "%s %s" % (img.get("caption") or "",
                                  urllib.parse.unquote(img["src"].split("?")[0].rsplit("/", 1)[-1]))
                if not pat or not re.search(pat, text.replace("_", " "), re.I):
                    continue
            seen.add(img["src"])
            out["images"].append(dict(img, about=(src or {}).get("title"), tag=tag))
    out["images"] = out["images"][:9]
    return out


# How a desktop is named in screenshot captions and file names.
DE_PICTURE_WORDS = {
    "xfce": r"\bxfce", "mate": r"\bmate\b", "kde": r"\bkde\b|\bplasma\b",
    "lxqt": r"\blxqt\b", "lxde": r"\blxde\b", "cinnamon": r"\bcinnamon\b",
    "budgie": r"\bbudgie\b", "gnome-flashback": r"flashback|gnome classic",
    "enlightenment": r"\benlightenment\b", "i3": r"\bi3\b", "openbox": r"\bopenbox\b",
    "fluxbox": r"\bfluxbox\b", "icewm": r"\bicewm\b", "jwm": r"\bjwm\b|joe's window",
    "awesome": r"\bawesome\b", "bspwm": r"\bbspwm\b", "herbstluftwm": r"herbstluftwm",
    "qtile": r"\bqtile\b", "xmonad": r"\bxmonad\b", "pekwm": r"\bpekwm\b",
    "wmaker": r"window ?maker|wmaker", "fvwm3": r"\bfvwm", "dwm": r"\bdwm\b",
    "spectrwm": r"spectrwm|scrotwm", "cwm": r"\bcwm\b", "ratpoison": r"ratpoison",
    "twm": r"\btwm\b", "lumina": r"\blumina\b", "ukui": r"\bukui\b|kylin",
}
_SHOTS = {}


def shots_index():
    """Real screenshots of each desktop, taken by the forge itself (shots.json)."""
    if not _SHOTS:
        _SHOTS.update(jload(os.path.join(DATADIR, "shots.json"), {}) or {"ids": {}})
    return _SHOTS


def public_entry(e):
    """The catalog fields the UI and CLI need, without the build recipe."""
    keep = ("id", "name", "subtitle", "family", "distro", "de", "de_label", "glyph",
            "kind", "image", "desc", "dl_mb", "disk_mb", "idle_mb", "ram_min",
            "ram_rec", "cpu_rec", "heavy", "weight", "beauty", "speed", "arches",
            "tags", "profile", "display")
    out = {k: e.get(k) for k in keep}
    out["family_label"] = catalog.FAMILY_LABEL.get(e["family"], e["family"].title())
    return out
