#!/usr/bin/env python3
"""
Build-time fetch of distro / desktop descriptions and screenshots from
Wikipedia, baked into src/data/info.json so the app never has to hit the
Wikimedia rate limits at runtime.  Polite: batched, paced, retries on 429.
"""
import json, os, re, sys, time, urllib.parse, urllib.request

UA = "SelkiesForge/1.1 (build-time catalog fetch; github.com/adatskov-wcpss/animated-fiesta)"
API = "https://en.wikipedia.org/w/api.php"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "data", "info.json")

FAMILY = {
    "ubuntu": "Ubuntu", "debian": "Debian", "fedora": "Fedora Linux",
    "arch": "Arch Linux", "alpine": "Alpine Linux", "kali": "Kali Linux",
    "parrot": "Parrot OS", "almalinux": "AlmaLinux", "rocky": "Rocky Linux",
    "oracle": "Oracle Linux", "centos": "CentOS", "opensuse": "OpenSUSE",
    "mint": "Linux Mint", "zorin": "Zorin OS", "pop": "Pop!_OS",
    "elementary": "Elementary OS", "garuda": "Garuda Linux",
}
DESKTOP = {
    "xfce": "Xfce", "mate": "MATE (desktop environment)", "kde": "KDE Plasma",
    "lxqt": "LXQt", "lxde": "LXDE", "cinnamon": "Cinnamon (desktop environment)",
    "budgie": "Budgie (desktop environment)", "gnome-flashback": "GNOME Flashback",
    "enlightenment": "Enlightenment (software)", "i3": "I3 (window manager)",
    "openbox": "Openbox", "fluxbox": "Fluxbox", "icewm": "IceWM", "jwm": "JWM",
    "awesome": "Awesome (window manager)", "bspwm": "Bspwm", "herbstluftwm": "Herbstluftwm",
    "qtile": "Qtile", "xmonad": "Xmonad", "pekwm": "PekWM", "wmaker": "Window Maker",
    "fvwm3": "FVWM", "dwm": "Dwm", "spectrwm": "Spectrwm", "cwm": "Cwm (window manager)",
    "ratpoison": "Ratpoison", "twm": "Twm", "lumina": "Lumina (desktop environment)",
    "ukui": "UKUI",
}

SKIP = re.compile(r"(logo|icon|symbol|commons-|wiki|flag|portal|question_book|edit-clear|"
                  r"text-x|crystal|nuvola|folder|padlock|ambox|lock-|mascot|badge|banner|"
                  r"emblem|signature|map_|diagram|chart|graph|_head|portrait|photo_of)", re.I)


def get(params, tries=7):
    params = dict(params, format="json", formatversion="2")
    url = API + "?" + urllib.parse.urlencode(params)
    wait = 4.0
    for attempt in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (429, 503):
                ra = e.headers.get("Retry-After")
                pause = float(ra) if ra and ra.isdigit() else wait
                print("    rate limited, waiting %.0fs" % pause, flush=True)
                time.sleep(pause)
                wait = min(wait * 1.8, 90)
                continue
            raise
        except Exception as e:
            print("    network hiccup (%s), retrying" % e, flush=True)
            time.sleep(wait)
    raise RuntimeError("gave up on " + url)


def summaries(titles):
    out = {}
    for i in range(0, len(titles), 18):
        chunk = titles[i:i + 18]
        d = get({"action": "query", "redirects": 1, "prop": "extracts|pageimages|info",
                 "exintro": 1, "explaintext": 1, "exlimit": "max",
                 "piprop": "original|thumbnail", "pithumbsize": 900, "inprop": "url",
                 "titles": "|".join(chunk)})
        q = d.get("query", {})
        back = {}
        for n in q.get("normalized", []) + q.get("redirects", []):
            back[n["to"]] = back.get(n["from"], n["from"])
        for p in q.get("pages", []):
            if p.get("missing"):
                continue
            asked = back.get(p["title"], p["title"])
            text = (p.get("extract") or "").strip()
            paras = [x.strip() for x in text.split("\n") if x.strip()]
            ex = " ".join(paras[:2])[:900]
            ex = re.sub(r"\(\s*[,;:]?\s*\)", "", ex)          # IPA left as "()"
            ex = re.sub(r"[,;]\s*\)", ")", re.sub(r"\(\s*[,;]\s*", "(", ex))
            ex = re.sub(r"\(\s+", "(", re.sub(r"\s+\)", ")", ex))
            ex = re.sub(r"\s{2,}", " ", re.sub(r"\s+([,.;:])", r"\1", ex)).strip()
            out[asked] = {
                "title": p["title"],
                "url": p.get("fullurl"),
                "extract": ex,
                "lead": (p.get("thumbnail") or {}).get("source"),
                "lead_full": (p.get("original") or {}).get("source"),
            }
        time.sleep(2.0)
    return out


def gallery(title, limit=6):
    d = get({"action": "query", "redirects": 1, "generator": "images", "titles": title,
             "gimlimit": 60, "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
             "iiurlwidth": 960, "iiextmetadatafilter": "LicenseShortName|Artist|ImageDescription"})
    pics = []
    for p in d.get("query", {}).get("pages", []):
        ii = (p.get("imageinfo") or [{}])[0]
        name = p.get("title", "")
        if ii.get("mime") not in ("image/png", "image/jpeg", "image/webp"):
            continue
        if SKIP.search(name):
            continue
        w, h = ii.get("width") or 0, ii.get("height") or 0
        if w < 640 or h < 360 or w / float(max(h, 1)) < 1.2:
            continue                       # screenshots are wide and decently sized
        meta = ii.get("extmetadata") or {}
        desc = re.sub(r"<[^>]+>", "", (meta.get("ImageDescription") or {}).get("value", ""))
        lic = (meta.get("LicenseShortName") or {}).get("value", "")
        score = 0
        low = name.lower()
        if "screenshot" in low or "desktop" in low:
            score += 3
        if re.search(r"20(1[5-9]|2\d)", low):
            score += 2                     # prefer recent shots
        score += min(w, 3840) / 3840.0
        pics.append({"src": ii.get("thumburl") or ii.get("url"), "full": ii.get("url"),
                     "page": ii.get("descriptionurl"), "w": w, "h": h,
                     "caption": (desc or name.replace("File:", "").rsplit(".", 1)[0]
                                 .replace("_", " "))[:160],
                     "license": lic[:40], "score": score})
    pics.sort(key=lambda x: -x["score"])
    for p in pics:
        p.pop("score", None)
    return pics[:limit]


def main():
    data = {"source": "Wikipedia / Wikimedia Commons", "fetched": time.strftime("%Y-%m-%d"),
            "families": {}, "desktops": {}}
    print("summaries: %d distro + %d desktop articles" % (len(FAMILY), len(DESKTOP)), flush=True)
    fam_sum = summaries(list(FAMILY.values()))
    de_sum = summaries(list(DESKTOP.values()))

    for key, title in FAMILY.items():
        s = fam_sum.get(title)
        if not s:
            print("  [no article] family %s (%s)" % (key, title)); continue
        print("  gallery  family %-11s %s" % (key, title), flush=True)
        s["images"] = gallery(s["title"])
        data["families"][key] = s
        time.sleep(1.6)
    for key, title in DESKTOP.items():
        s = de_sum.get(title)
        if not s:
            print("  [no article] desktop %s (%s)" % (key, title)); continue
        print("  gallery  desktop %-11s %s" % (key, title), flush=True)
        s["images"] = gallery(s["title"])
        data["desktops"][key] = s
        time.sleep(1.6)

    with open(OUT, "w") as fh:
        json.dump(data, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    nimg = sum(len(v["images"]) for v in list(data["families"].values()) + list(data["desktops"].values()))
    print("wrote %s: %d families, %d desktops, %d images, %d bytes"
          % (OUT, len(data["families"]), len(data["desktops"]), nimg, os.path.getsize(OUT)))


if __name__ == "__main__":
    main()
