#!/usr/bin/env python3
"""Fill the gaps fetch_info.py leaves: things with no Wikipedia article or no
usable screenshots get images from a Wikimedia Commons search instead."""
import json, os, re, sys, time, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_info as fi

API = "https://commons.wikimedia.org/w/api.php"
INFO = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "data", "info.json")
GAPS = {
    ("families", "alpine"): ("Alpine Linux", "Alpine Linux", "https://alpinelinux.org"),
    ("desktops", "bspwm"): ("bspwm", "bspwm", "https://github.com/baskerville/bspwm"),
    ("desktops", "herbstluftwm"): ("herbstluftwm", "herbstluftwm", "https://herbstluftwm.org"),
    ("desktops", "spectrwm"): ("spectrwm", "spectrwm", "https://github.com/conformal/spectrwm"),
    ("desktops", "jwm"): ("JWM", "JWM window manager", "https://joewing.net/projects/jwm/"),
    ("desktops", "pekwm"): ("PekWM", "pekwm", "https://www.pekwm.se"),
}


def commons(query, limit=6):
    params = {"action": "query", "format": "json", "formatversion": "2",
              "generator": "search", "gsrnamespace": 6, "gsrlimit": 30,
              "gsrsearch": query + " screenshot", "prop": "imageinfo",
              "iiprop": "url|size|mime|extmetadata", "iiurlwidth": 960,
              "iiextmetadatafilter": "LicenseShortName|ImageDescription"}
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": fi.UA})
            with urllib.request.urlopen(req, timeout=40) as r:
                d = json.loads(r.read().decode("utf-8"))
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(8 * (attempt + 1)); continue
            raise
    want = re.sub(r"\W+", "", query.split()[0].lower())
    pics = []
    for p in d.get("query", {}).get("pages", []):
        ii = (p.get("imageinfo") or [{}])[0]
        name = p.get("title", "")
        if ii.get("mime") not in ("image/png", "image/jpeg", "image/webp"):
            continue
        if fi.SKIP.search(name) or want not in re.sub(r"\W+", "", name.lower()):
            continue                     # must actually be about this thing
        w, h = ii.get("width") or 0, ii.get("height") or 0
        if w < 640 or h < 360 or w / float(max(h, 1)) < 1.2:
            continue
        meta = ii.get("extmetadata") or {}
        desc = re.sub(r"<[^>]+>", "", (meta.get("ImageDescription") or {}).get("value", ""))
        pics.append({"src": ii.get("thumburl") or ii.get("url"), "full": ii.get("url"),
                     "page": ii.get("descriptionurl"), "w": w, "h": h,
                     "caption": (desc or name.replace("File:", "").rsplit(".", 1)[0]
                                 .replace("_", " "))[:160],
                     "license": (meta.get("LicenseShortName") or {}).get("value", "")[:40]})
    return pics[:limit]


data = json.load(open(INFO))
for (section, key), (title, query, home) in GAPS.items():
    cur = data[section].get(key)
    pics = commons(query)
    print("  %-9s %-13s commons: %d image(s)" % (section, key, len(pics)), flush=True)
    if cur is None:
        data[section][key] = {"title": title, "url": home, "extract": None,
                              "lead": None, "lead_full": None, "images": pics}
    elif not cur.get("images"):
        cur["images"] = pics
    time.sleep(2.5)
open(INFO, "w").write(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
print("updated", INFO, os.path.getsize(INFO), "bytes")
