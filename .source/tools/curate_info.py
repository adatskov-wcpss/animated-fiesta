#!/usr/bin/env python3
"""Drop Wikimedia images that do not show what the card is about.

fetch_info.py pulls every screenshot an article uses. Some articles borrow
other projects' screenshots (Qtile's article is about tiling WMs in general,
"Alpine" also names an email client), and some show installers, package
managers or 20-year-old releases rather than the desktop you will get.
Idempotent; build.sh runs it before embedding info.json.
"""
import json, os

PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "data", "info.json")

# Substrings (case-insensitive) of the image file name that must go, per article.
DROP = {
    ("families", "debian"): ["hurd", "etch", "woody"],
    ("families", "fedora"): ["fedora_21", "fedora_15", "default_applications"],
    ("families", "arch"): ["bootup", "pacman", "pacstrap", "archinstall", "neofetch"],
    ("families", "alpine"): ["alpine_1.00", "alpine_linux.jpg", "set_up"],
    ("families", "opensuse"): ["agama", "cockpit", "myrlyn", "yast", "webyast"],
    ("families", "pop"): ["system76_product"],
    ("families", "mint"): ["mintupdate"],
    ("families", "elementary"): ["loki"],
    ("desktops", "xfce"): ["mousepad", "parole", "xfce-4.4", "default_plus_xffm"],
    ("desktops", "mate"): ["caja"],
    ("desktops", "kde"): ["plasma_desktop_4.9"],
    ("desktops", "lxde"): ["gpicview", "lxappearance", "pcmanfm.png"],
    ("desktops", "cinnamon"): ["system_settings", "nemo_", "cinnamon_1.6"],
    ("desktops", "gnome-flashback"): ["gnome-2.18", "clocks", "phone-concept", "builder"],
    ("desktops", "ukui"): ["reactos"],
    # Qtile's article only carries other tiling window managers' screenshots.
    ("desktops", "qtile"): ["dwm", "bluetile", "scrotwm", "wmfs"],
}
# Images that belong to another card: (from, to, file substring)
MOVE = [
    (("desktops", "qtile"), ("desktops", "spectrwm"), "scrotwm"),   # spectrwm was called scrotwm
]


def main():
    d = json.load(open(PATH))
    removed = 0
    for (frm, to, sub) in MOVE:
        src = d.get(frm[0], {}).get(frm[1]) or {}
        dst = d.get(to[0], {}).setdefault(to[1], {"title": to[1], "images": []})
        dst.setdefault("images", [])
        for im in list(src.get("images") or []):
            if sub in im.get("src", "").lower() and not any(sub in x.get("src", "").lower() for x in dst["images"]):
                dst["images"].append(dict(im, caption="spectrwm (then called scrotwm) in action"))
    for (sec, key), subs in DROP.items():
        art = d.get(sec, {}).get(key)
        if not art:
            continue
        keep = []
        for im in art.get("images") or []:
            name = im.get("src", "").lower().split("?")[0].rsplit("/", 1)[-1]
            if any(s in name for s in subs):
                removed += 1
                continue
            keep.append(im)
        art["images"] = keep
        lead = (art.get("lead") or "").lower()
        if lead and any(s in lead.split("?")[0].rsplit("/", 1)[-1] for s in subs):
            art["lead"] = keep[0]["src"] if keep else None
    # Captions were stored cut at a fixed length ("...Clockwise from top left:…").
    # Show whole sentences instead: cut back to the last full stop.
    trimmed = 0
    for sec in ("families", "desktops"):
        for art in d.get(sec, {}).values():
            for im in art.get("images") or []:
                c = (im.get("caption") or "").strip()
                if c.endswith("\u2026"):
                    cut = c[:-1].rfind(". ")
                    if cut >= 25:
                        im["caption"] = c[:cut + 1]
                        trimmed += 1
    print("curate_info: trimmed %d cut-off captions" % trimmed)
    d["curated"] = True
    with open(PATH, "w") as fh:
        json.dump(d, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print("curate_info: dropped %d off-topic images" % removed)


if __name__ == "__main__":
    main()
