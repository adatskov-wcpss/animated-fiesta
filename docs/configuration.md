# Configuration

Selkies Forge needs no configuration file. Everything has a sensible default, and these environment variables change it. Set them in front of `selkies-cli`, `docker.sh`, or the `curl … | bash` line.

## Where and how it runs

| Variable | Default | What it does |
|---|---|---|
| `FORGE_HOME` | `~/.selkies-forge` | Where the app, state, logs, builds and update clone live |
| `FORGE_BIN_DIR` | first writable of `~/.local/bin`, `~/bin` on your `PATH`, else `/usr/local/bin`, else `~/.local/bin` | Where `selkies-cli` is installed. Setting it leaves your shell profiles alone. |
| `FORGE_PORT` | `8787` | Web UI port (the next free one if taken); same as `--port` |
| `FORGE_BIND` | `127.0.0.1` | Web UI address; same as `--bind` |
| `NO_COLOR` | unset | Plain output with no colours (CLI and `build.py`) |
| `FORGE_HTTP_LOG` | unset | Log every web UI request to its log |

## Engine behaviour

| Variable | Default | What it does |
|---|---|---|
| `FORGE_MAX_BUILDS` | `1` | Desktops building at once ([scheduler](engine.md#the-scheduler)) |
| `FORGE_MAX_PULLS` | `2` | Images downloading at once |
| `FORGE_MAX_BOOTS` | `2` | Desktops in their first boot at once |
| `FORGE_HEAL` | `1` | `0` turns off restarting desktops that crash or freeze while the web UI runs |
| `FORGE_IDLE_STOP_MIN` | `0` | Stop desktops nobody has watched for this many minutes (`0`: never). A desktop's own setting wins. |
| `FORGE_PRESSURE_STOP` | `0` | `1`: when the machine is out of memory, stop the biggest desktop nobody is watching |
| `FORGE_PULL_STALL` | `240` | Seconds without progress before a `docker pull` is restarted |
| `FORGE_BUILD_STALL` | `1200` | Seconds without output before a `docker build` is restarted |

## Updates

| Variable | Default | What it does |
|---|---|---|
| `FORGE_AUTO_UPDATE` | `1` | `0` turns off automatic updates (`selkies-cli update` still works) |
| `FORGE_UPDATE_EVERY` | `300` | Seconds between checks while the web UI runs |
| `FORGE_REPO` | this repository's git URL | Where updates come from (a fork, say) |
| `FORGE_BRANCH` | `main` | The branch to follow |
| `FORGE_URL` | this repository's raw `docker.sh` | The reinstall hint, and the download used when git isn't available. Setting it switches updates to that download (no git). |

## Start on boot

| Variable | Default | What it does |
|---|---|---|
| `FORGE_BOOT_METHOD` | automatic | `cron` forces the crontab method even where systemd user services work |

## Per desktop

These are set when you forge a desktop: in the web UI, the CLI prompts, or the [API](api.md#launching).

| Setting | Default | Changeable later |
|---|---|---|
| Memory cap (swap pinned to the same) | Planned for the desktop and this machine | Live |
| CPUs | Planned | Live |
| Shared memory (`/dev/shm`) | 1 GB (a ceiling: what's stored there counts against the memory cap, so it costs nothing until used) | Recreates the desktop |
| Storage budget | At least 10 GB; enforced only where the storage driver supports quotas | Recreates the desktop |
| Screen | `auto`: fixed 1920×1080 for compositing desktops, else follows the window (scaled on phones, HiDPI and 4K screens by the [screen guard](forge-layer.md#the-screen-guard-hidpi-phones-and-4k)) | Recreates the desktop |
| Auto-start with Docker | Off | Live |
| Healing after a crash or freeze | On | At launch |
| Stop when nobody's watching | The forge default (`FORGE_IDLE_STOP_MIN`, off) | Live, from the menu or `selkies-cli idle` |
| Sign-in | Off (Kasm always on) | Recreate |
| Public link | On | Any time, from the menu |
| GPU (`/dev/dri`), seccomp unconfined | Off | Recreate |

## Docker labels

Every container the forge makes carries `io.selkiesforge.*` labels: `entry`, `title`, `family`, `glyph`, `de`, `profile`, `version`, `disk`, `volume`, `display` (`fit` or `fixed:WxH`), `heal`, and `job` (the launch that made it, for crash recovery). These labels, not the engine's own files, are the source of truth.
