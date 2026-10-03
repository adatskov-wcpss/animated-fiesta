#!/usr/bin/env python3
"""Rebuild .source/src/data/shots.json from the real screenshots in shots/.

Each shots/<catalog id>.jpg is a capture of that exact desktop running in
Selkies Forge. The web UI shows it first on the desktop's page, loading it
from this repository. Run this after adding or replacing screenshots:

    python3 .source/tools/make_shots_index.py
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SHOTS = os.path.join(REPO, "shots")
OUT = os.path.join(os.path.dirname(HERE), "src", "data", "shots.json")
BASE = "https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/shots/"


def size(path):
    try:
        out = subprocess.run(["identify", "-format", "%w %h", path], capture_output=True,
                             text=True, timeout=30).stdout.split()
        return int(out[0]), int(out[1])
    except Exception:
        return 1280, 720


def main():
    ids = {}
    if os.path.isdir(SHOTS):
        for f in sorted(os.listdir(SHOTS)):
            if f.endswith(".jpg"):
                p = os.path.join(SHOTS, f)
                w, h = size(p)
                ids[f[:-4]] = {"w": w, "h": h, "kb": os.path.getsize(p) // 1024,
                               "taken": time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(p)))}
    with open(OUT, "w") as fh:
        json.dump({"base": BASE, "ids": ids}, fh, indent=0, sort_keys=True)
        fh.write("\n")
    print("shots.json: %d real screenshots" % len(ids))


if __name__ == "__main__":
    sys.exit(main())
