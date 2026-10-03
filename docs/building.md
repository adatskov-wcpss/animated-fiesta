# Building from source

`docker.sh` is generated. Everything it contains lives, readable and in separate files, in **`.source/`**. Change anything there, run the builder, and you get a new single-file `docker.sh` that has been checked end to end.

> **It's yours.** Selkies Forge is MIT licensed. Fork it, change it, rename it, strip it down, ship it. You don't need permission. Contributions back are welcome but never expected.

## The layout

```
.source/
├── build.py              the compiler: asks where to write docker.sh, checks everything, writes it
├── build.sh              the same, for people who reach for a shell script (passes options through)
├── src/                  everything that ends up inside docker.sh
│   ├── shell/
│   │   ├── head.sh       the installer front half: colours, prompts, menus, Python/Docker install
│   │   └── tail.sh       the front end: home screen, verbs, web UI control, manager, boot, clean
│   ├── engine.py         the engine's entry point
│   ├── forge/            the engine, one module per job (see docs/engine.md)
│   │   ├── catalog.py    every desktop, distro base and package list
│   │   ├── layer.py      the forge layer that goes inside every desktop
│   │   ├── launch.py     the pipeline · health.py, runner.py, images.py, scheduler.py, jobs.py …
│   │   └── …             29 modules in all
│   ├── web/              the web UI: index.html, app.css, app.js, term.js, logos.js, brands.js
│   └── data/             info.json (Wikipedia/Commons, curated), shots.json (real screenshots)
├── tests/                unit tests (stdlib unittest; no Docker, no desktops)
└── tools/                data refreshers and generators (not part of docker.sh)
```

At install time `docker.sh` unpacks `src/` (minus `shell/`) into `~/.selkies-forge/app/`, keeping the same layout. `head.sh` + `tail.sh` become both the installer and the `selkies-cli` front end.

## Build

```bash
python3 .source/build.py
```

It asks where to write the file:

```
   ___ ___ _    _  _____ ___ ___   ___ ___  ___  ___ ___
  / __| __| |  | |/ /_ _| __/ __| | __/ _ \| _ \/ __| __|
  \__ \ _|| |__| ' < | || _|\__ \ | _| (_) |   / (_ | _|
  |___/___|____|_|\_\___|___|___/ |_| \___/|_|_\\___|___|
  build.py: compile .source/ into one docker.sh, then prove it works

  This compiles every file in .source/src into one docker.sh.

  ? Where should docker.sh be written? [docker.sh]
```

Press Enter for the repository's own `docker.sh`, or type any path (a directory gets `docker.sh` inside it). If the file exists, it asks before overwriting. Then it works through its checks:

```
   1  Python
  ✔ 35 Python files compile; all 29 engine modules import
  ✔ pyflakes: no undefined names
   2  Web UI
  ✔ 4 JavaScript files parse (node --check)
   3  Data
  ✔ 2 JSON data files parse
   4  Shell front end
  ✔ head.sh, tail.sh and the generated selkies-cli pass bash -n
   5  Forge layer and desktop scripts
  ✔ forge layer scripts (5) and startwm/install scripts for 114 built desktops pass
   6  Payload
  ✔ 40 payload files, no heredoc collisions
   7  Assemble
  ✔ docker.sh assembles and passes bash -n (733 KB, 16488 lines)
   8  Unpack and run
  ✔ docker.sh unpacks all 40 files byte for byte
  ✔ unpacked engine 1.6.0 lists 153 desktops; selkies-cli answers (selkies-forge 1.6.0)
   9  Unit tests
  ✔ 57 tests passed (3.8s)

  ▰ BUILT  Selkies Forge 1.6.0
```

If any check fails, it shows why and **writes nothing**.

| Option | What it does |
|---|---|
| *(none)* | Interactive: asks for the output path |
| `-o PATH`, `--out PATH` | Write there, no questions |
| `-y`, `--yes` | No questions; write the repository's `docker.sh` |
| `--check` | Build in memory and compare with the existing `docker.sh` (for CI: fails if they differ) |
| `--no-tests` | Skip the unit tests (every other check still runs) |

`bash .source/build.sh` accepts the same options. Requirements: Python 3.8+ and bash. Node (for the JavaScript check) and pyflakes (for undefined names) are used when present. No network, Docker or root is needed.

### What the checks catch

| # | Check | Catches |
|---|---|---|
| 1 | Every `.py` compiles; every engine module imports in a clean process; pyflakes | Syntax errors, circular imports, missing imports, undefined names |
| 2 | `node --check` on every `.js`; `index.html` present | A broken web UI |
| 3 | Every `.json` parses | Corrupt data |
| 4 | `bash -n` on `head.sh`, `tail.sh` and the generated `selkies-cli` | A front end that won't start |
| 5 | `bash -n` / `sh -n` on the agent, seed, xsettingsd guard and bwrap shim, and on the `startwm.sh` and install script of **every** built desktop | A desktop that can't start, found before anyone forges it |
| 6 | No file contains its own heredoc terminator; every file ends with a newline | A `docker.sh` that silently truncates a file |
| 7 | `bash -n` on the assembled script | The whole thing failing to parse |
| 8 | `docker.sh --extract-only` into a temp dir; every file compared byte for byte; the unpacked engine and `selkies-cli` run | Anything lost or changed in packaging |
| 9 | The unit tests | Logic regressions in the engine |

### How `docker.sh` is put together

```
head.sh                                   installer front half
FORGE_SHA_<FILE>="…"  × every file        sha256 of each embedded file
FORGE_PAYLOAD_SHA, FORGE_PAYLOAD_FILES     the set, for "unchanged? skip unpacking"
extract_payload() {                        one quoted heredoc per file, then:
  cat > "$FORGE_APP/forge/launch.py" <<'__FORGE_FILE_FORGE_LAUNCH_PY__'
  …                                        - verify every sha256
}                                          - remove files an older version had
tail.sh                                    front end, then main "$@"
```

The heredocs are quoted, so nothing inside is ever expanded. Each terminator is unique to its file.

## Tests

```bash
cd .source
PYTHONPATH=src python3 -m unittest discover -s tests -t .
```

| File | Covers |
|---|---|
| `test_catalog.py` | Every entry is complete; IDs unique; compositing desktops run fixed; known package traps stay fixed |
| `test_recipes_layer.py` | startwm/install scripts parse and contain the supervisor; layer files, digest, Dockerfile wiring, seeds |
| `test_runner.py` | Every desktop defaults to a locked 1920×1080; resolution clamping; moving 1.5 desktops over; `docker run` arguments (caps, labels, sign-in, quota, Kasm) |
| `test_health.py` | Which auto-fix each problem gets, and that each is tried once |
| `test_jobs_scheduler.py` | Job events and logs; cancelling kills commands (and their children) and health waits; scheduler slots and queueing |
| `test_events_util.py` | The journal and its trimming; Docker-daemon retries (and what is never retried); helpers |
| `test_webui_info_smart.py` | How the last stop is explained; gallery filtering; plans and recommendations |
| `test_server_guard.py` | Cross-site, non-JSON and DNS-rebinding requests are refused; the UI's own requests pass |

The tests run in a throwaway `FORGE_HOME` and never touch Docker containers.

## Tools

| Tool | What it does |
|---|---|
| `tools/gen_catalog_doc.py` | Regenerates `docs/catalog.md` from the catalog |
| `tools/make_shots_index.py` | Rebuilds `src/data/shots.json` from the real screenshots in `shots/` |
| `tools/fetch_info.py`, `tools/fetch_commons.py` | Refresh Wikipedia descriptions and Commons pictures into `src/data/info.json` (slow, polite to Wikimedia's rate limits) |
| `tools/curate_info.py` | Drops off-topic pictures and trims cut-off captions in `info.json` (idempotent; run after fetching) |
| `tools/fetch_logos.py` | Refreshes the distro logos (Simple Icons, CC0) into `src/web/brands.js` |

## Adding a desktop or a distro

**A desktop environment.** Add it to `DESKTOPS` in `src/forge/catalog.py`:

```python
"mydesk": dict(
    label="My Desk", glyph="mydesk", klass="light", idle=280, add_dl=220,
    beauty=78, speed=85, term="xterm",
    # display defaults to "fixed" (1920x1080, scaled); only set "fit" if you must
    blurb="One line about it.",
    apt=dict(pkgs="mydesk xterm", session="mydesk-session"),
    dnf=dict(pkgs="mydesk xterm", session="mydesk-session"),
),
```

Then list `"mydesk"` in the `des` of each base in `BASES` that should offer it. Add its session variables to `SESSION_ENV` if it needs any.

**A distro base.** Add an entry to `BASES` with a Selkies base image (`lscr.io/linuxserver/baseimage-selkies:<tag>`), its package manager (`apt`, `dnf`, `pacman` or `apk`), and the desktops it offers.

**A ready-made image.** Add a line to `WEBTOP` or `KASM`.

**A first-run fix inside desktops.** Add it to `SEED` in `src/forge/layer.py` (runs as root before the desktop starts; use `put` so it only writes missing files), or to `PRESESSION` (runs inside the session's D-Bus, for `gsettings`).

Then:

```bash
python3 .source/tools/gen_catalog_doc.py     # update docs/catalog.md
python3 .source/build.py                     # check and build
bash docker.sh --launch <your-id> --no-tunnel   # try it
```

## Releasing

1. Bump the version in **both** `src/shell/head.sh` (`FORGE_VERSION`) and `src/forge/paths.py` (`VERSION`). Installs only accept updates that fast-forward or carry a higher version.
2. `python3 .source/build.py --yes`
3. Commit `docker.sh` together with `.source/`. `python3 .source/build.py --check` confirms they match.
4. Push. Installs pick it up within five minutes.

To run your own fork's updates, point installs at it with `FORGE_REPO=https://github.com/you/your-fork.git`.
