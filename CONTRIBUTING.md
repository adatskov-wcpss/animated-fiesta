# Contributing

Thanks for looking. First, the most important part:

> **You're free to do whatever you want with Selkies Forge.** It's MIT licensed. Modify it, fork it, rename it, use it in your own projects, commercial or not. You don't need to ask or to contribute anything back.

If you *do* want to send something back, here's how.

## Making a change

1. Edit the files in **`.source/`**, never `docker.sh` directly; it's generated. See [Building from source](docs/building.md).
2. Build and check:
   ```bash
   python3 .source/build.py --yes
   ```
   It compiles everything, checks every script of every desktop, unpacks the result byte for byte, and runs the tests. It writes nothing if anything fails.
3. Try it for real, on the desktops your change touches:
   ```bash
   bash docker.sh --launch <id> --no-tunnel
   ```
   Please test one or two desktops at a time. Launching the whole catalog at once flattens most machines.
4. If you changed the catalog: `python3 .source/tools/gen_catalog_doc.py`.
5. Commit `.source/` **and** the rebuilt `docker.sh` together. `python3 .source/build.py --check` confirms they match.

## Good first changes

- A desktop that misbehaves somewhere: a seed in `layer.py`, a session variable in `catalog.SESSION_ENV`, or a package fix
- A new distro base or desktop environment ([how](docs/building.md#adding-a-desktop-or-a-distro))
- A real screenshot of a desktop in `shots/<id>.jpg`, then `tools/make_shots_index.py`
- A better auto-fix in `health.pick_fix`, with a test
- Docs: anything that confused you is worth a sentence

## Style

- Python: standard library only, Python 3.8+, four-space indents, comments that say *why*.
- Shell: bash, `set -uo pipefail`-safe, quote everything.
- JavaScript: no frameworks and no build step; it has to stay fast on a Raspberry Pi.
- Write user-facing text plainly: say what happened and what to do.
