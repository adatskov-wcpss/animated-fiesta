# .source: everything inside docker.sh, in readable files

`docker.sh` at the top of this repository is **generated** from this folder. Edit here, then compile:

```bash
python3 .source/build.py        # asks where to write docker.sh
bash .source/build.sh           # the same, as a shell script
```

The builder asks where to put `docker.sh` (press Enter for the repository's own). It then checks every Python, JavaScript, JSON and shell file and every built desktop's scripts, unpacks the result byte for byte, and runs the unit tests. It only writes the file once everything passes.

```
src/shell/   head.sh + tail.sh   the installer and the selkies-cli front end
src/engine.py, src/forge/        the engine: launch pipeline, health, scheduler, watchdog …
src/web/                         the web UI
src/data/                        Wikipedia/Commons data, real-screenshot index
tests/                           unit tests (no Docker needed)
tools/                           data refreshers and the catalog page generator
```

Full guide: **[docs/building.md](../docs/building.md)**. How the engine works: **[docs/engine.md](../docs/engine.md)**.

This is open source under the MIT licence. Change whatever you like.
