#!/usr/bin/env python3
"""Write docs/catalog.md from the catalog itself, so the list can never drift.

    python3 .source/tools/gen_catalog_doc.py
"""
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "src"))
from forge import catalog  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "docs", "catalog.md")


def arches(e):
    return " · ".join("x86_64" if a == "amd64" else "arm64" for a in e["arches"])


def gb(mb):
    return "%.1f GB" % (mb / 1024.0)


def main():
    C = catalog.CATALOG
    kinds = collections.Counter(
        "kasm" if e.get("profile") == "kasm" else ("curated" if "curated" in e["tags"] else e["kind"])
        for e in C)
    out = ["# The catalog", "",
           "> Generated from `.source/src/forge/catalog.py` by `.source/tools/gen_catalog_doc.py`.",
           "> Edit the catalog, then run the tool; do not edit this page by hand.", "",
           "Selkies Forge knows **%d desktops**: %d ready-made LinuxServer Webtops, %d Kasm "
           "Workspaces, %d distro × desktop combinations built on your machine, and %d curated "
           "looks." % (len(C), kinds["pull"], kinds["kasm"], kinds["build"], kinds["curated"]),
           "%d of them run on arm64 (Raspberry Pi and other ARM boards); all of them run on x86_64."
           % sum(1 for e in C if "arm64" in e["arches"]), "",
           "| Column | Meaning |", "|---|---|",
           "| **Kind** | *pull*: a prebuilt image, only downloaded. *build*: a Selkies base image plus "
           "the desktop's packages, built on your machine the first time. |",
           "| **Screen** | *fit*: the desktop follows your browser window (on phones, HiDPI and 4K "
           "screens, kept at 96 DPI and scaled). *fixed*: it runs at 1920×1080 and Selkies scales it into your "
           "window (desktops that misdraw when the screen changes size). Changeable per desktop. "
           "[More](forge-layer.md#screen-modes) |",
           "| **RAM** | the floor it needs, then the comfortable amount the planner aims for |",
           "| **Download** | compressed download for a first launch |", "",
           "## Contents", ""]
    sections = [
        ("Ready to run: LinuxServer Webtop", lambda e: e["kind"] == "pull" and e.get("profile") != "kasm"),
        ("Ready to run: Kasm Workspaces", lambda e: e.get("profile") == "kasm"),
        ("Curated looks", lambda e: "curated" in e["tags"]),
    ]
    for key, base in catalog.BASES.items():
        sections.append(("Built on %s (%s)" % (base["distro"], base["code"]),
                         (lambda k: lambda e: e.get("base") == k and "curated" not in e["tags"])(key)))
    for title, _ in sections:
        anchor = title.lower().replace(" ", "-")
        for ch in "():,.×":
            anchor = anchor.replace(ch, "")
        out.append("- [%s](#%s)" % (title, anchor))
    out.append("")
    for title, pred in sections:
        rows = sorted((e for e in C if pred(e)), key=lambda e: (e["family"], e["name"]))
        if not rows:
            continue
        out += ["## " + title, "", "| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |",
                "|---|---|---|---|---|---|---|---|"]
        for e in rows:
            out.append("| %s | `%s` | %s | %s | %s | %s → %s | %s | %s |" % (
                e["name"], e["id"], e["de_label"], e["kind"],
                "browser" if e.get("profile") == "kasm" else e.get("display", "fit"),
                gb(e["ram_min"]), gb(e["ram_rec"]), gb(e["dl_mb"]), arches(e)))
        out.append("")
    out += ["## Desktop environments", "",
            "| Desktop | Weight | Idle RAM | Screen | Available on |", "|---|---|---|---|---|"]
    for key, de in sorted(catalog.DESKTOPS.items(), key=lambda kv: kv[1]["label"].lower()):
        on = [b["distro"] for b in catalog.BASES.values() if key in b["des"] and de.get(b["pm"])]
        if not on:
            continue
        out.append("| %s | %s | ~%d MB | %s | %s |" % (de["label"], de["klass"], de["idle"],
                                                      de.get("display", "fit"), ", ".join(on)))
    out.append("")
    with open(OUT, "w") as fh:
        fh.write("\n".join(out))
    print("wrote %s (%d desktops)" % (os.path.relpath(OUT), len(C)))


if __name__ == "__main__":
    main()
