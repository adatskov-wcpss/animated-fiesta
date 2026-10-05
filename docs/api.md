# HTTP API

The web UI is a thin page over a JSON API served by the engine. You can use the same API from scripts.

```bash
curl -s localhost:8787/api/instances | jq '.instances[] | {name, running, session}'
```

## Rules

- **Base URL:** wherever the web UI runs (`selkies-cli open` prints it). By default it's `http://localhost:8787`, listening on `127.0.0.1` only.
- **No token.** There is no access control on the API: whoever can reach the web UI can use it. Keep it on localhost, or put it behind something that signs people in.
- **POST bodies must be JSON** (`Content-Type: application/json`), even when empty (`{}`).
- **Cross-site requests are refused.** If a request carries an `Origin` header, it must match the host it was sent to. A localhost-only UI also refuses any `Host` header that isn't `localhost`, `127.0.0.1` or `[::1]` (DNS rebinding). Scripts that send neither header are unaffected.
- **Errors** are `{"error": "message"}` with status 400, 403, 404 or 500.
- **Streams** (job events, terminal output) are Server-Sent Events.

## Catalog and machine

| Method & path | Returns |
|---|---|
| `GET /api/boot` | Everything the page needs at start: version, host, the public catalog, family labels, tastes, quick picks, real-screenshot index, instances, counts |
| `GET /api/host` | This machine: arch, cores, memory, disk, Docker version, storage driver, quota support, `/dev/dri`, and a `gpu` summary |
| `GET /api/gpu` | GPU Smart Passthrough report: every render node, its driver and vendor, NVIDIA toolkit status, V4L2 encoders, and which GPU desktops get |
| `GET /api/doctor` | The checks shown under *This machine*: `{checks: [{name, ok, detail, fix, severity}], host}` |
| `GET /api/info/<id>` | Wikipedia text and filtered pictures for a catalog entry |
| `GET /api/entry/<id>` | One entry, with its plan for this machine (plus Dockerfile and startwm.sh for built entries) |
| `POST /api/smart` | `{taste, purpose, family?, allow_build?, max_dl_mb?, limit?}` → scored picks with reasons |

## Launching

| Method & path | Body / returns |
|---|---|
| `POST /api/launch` | `{id, plan?: {memory_mb, cpus, shm_mb, disk_mb}, opts?: {...}}` → `{job, plan}` |
| `GET /api/job/<id>` | The job's snapshot: status (`running`, `done`, `error`, `cancelled`, `interrupted`), phase, label, progress, result, error, log path, `owner` (`server` or `cli`), `notes` (container, volume). Jobs from other processes come from their state files, with `foreign: true`. |
| `GET /api/job/<id>/events` | SSE stream of `log`, `phase`, `progress`, `done`, `error` events (first a `snapshot`) |
| `POST /api/job/<id>/cancel` | Cancel it: `{cancelled, job}`. A `selkies-cli` job is cancelled too (it gets SIGINT, like Ctrl-C): `{cancelled, foreign: true}` |
| `GET /api/jobs` | Every recent job on this machine, this web UI's and `selkies-cli`'s, newest first |
| `GET /api/scheduler` | `{slots: {build|pull|boot: {limit, busy}}, jobs: [running jobs]}` |

Launch options (`opts`):

| Key | Meaning |
|---|---|
| `name` | Container name (prefixed with `forge-`) |
| `tunnel` | Open a serveo link (default `true`) |
| `subdomain` | Ask serveo for a subdomain |
| `username`, `password` | Sign-in in front of the desktop (Kasm: `password` is the `kasm_user` password) |
| `autostart` | Start again whenever Docker starts (`--restart unless-stopped`) |
| `heal` | `false` to stop the watchdog restarting it after a crash |
| `display` | `auto` (default), `fit` or `fixed` |
| `resolution` | For `fixed`, e.g. `"1600x900"` (800×600 to 3840×2160) |
| `gpu` | `auto` (default), `on` or `off`: [GPU Smart Passthrough](gpu.md). `true`/`false` from older clients mean `auto`/`off` |
| `gpu_device` | Which GPU: a render node, index, driver or vendor (optional) |
| `seccomp_unconfined` | Start with `seccomp=unconfined` (the engine tries this on its own when a session is blocked) |
| `health_timeout` | Seconds to wait for the web port |
| `force` | Start even if free memory is below the desktop's floor |
| `force_pull`, `force_build` | Fetch or build again even if the image is present |
| `env` | Extra `KEY=value` environment variables |
| `idle_stop` | Minutes with nobody watching before the watchdog stops it (`0`: never) |
| `dry_run` | Check everything and report what would happen (the result has `steps` and `docker_run`); nothing is fetched or started |

A job's `done` result has `name`, `local_url`, `https_url`, `tunnel`, `credentials`, `session` (window manager, screen, clients), `display`, `fixes` (the auto-fixes it applied), `warning` (if the session came up with a problem) and `instance`.

## Desktops

| Method & path | Body / returns |
|---|---|
| `GET /api/instances` | Every forge desktop, with state, ports, limits, links, tunnel, sign-in, screen mode, `session` (from the watchdog: window manager, screen, `viewers`, `idle_s`), `heal`, `idle_stop_min` |
| `GET /api/stats` | CPU, memory and network per running desktop, with rates and sparklines |
| `POST /api/instance/<name>/start` | Also `stop`, `restart`, `tunnel` (`{subdomain?}`), `untunnel`, `repair`, `remove` (`{purge: true}` also deletes its `/config` volume) |
| `POST /api/instance/<name>/retune` | `{memory_mb?, cpus?, shm_mb?, disk_mb?, autostart?, display?, resolution?}` → `{ok, recreated}`. Memory, CPU and auto-start apply live; the rest recreate the desktop. |
| `GET /api/logs/<name>?tail=N` | `{logs, events}`: the container log and the desktop's recent journal events |
| `GET /api/events?name=&limit=` | The event journal, newest last |
| `POST /api/instance/<name>/idle` | `{minutes}`: stop it after that many minutes unwatched (`0` never, `null` the forge default) |

## Backups and clones

| Method & path | Body / returns |
|---|---|
| `GET /api/backups?name=` | Backups, newest first: `file`, `name`, `entry_id`, `size`, `created`, `limits`, `opts`, `tag` |
| `POST /api/instance/<name>/backup` | `{include_cache?}` → `{job}`. The job's result has `backup` and `file`. |
| `POST /api/backups/restore` | `{name, file}` → `{job}`. A safety backup is taken first; the result names it (`safety`). |
| `POST /api/instance/<name>/clone` | `{name?, tunnel?}` → `{job}`: a new desktop with a copy of its files. The result is a launch result. |
| `POST /api/backups/clone` | `{file, name?}` → `{job}`: a new desktop from a backup |
| `POST /api/backups/delete` | `{file}` |

## Addons

See [Addons](addons.md) for the format. Long operations are jobs, streamed like launches.

| Method & path | Returns |
|---|---|
| `GET /api/addons` | `{addons: [...], spec}`: each with name, version, description, source, logo URL, settings (passwords masked), actions, requirement problems, `detected`, `installed`, and a live `status` (`{state, url, version, detail}`) |
| `GET /api/addons/<id>` | One addon, with its live status |
| `GET /api/addons/<id>/check` | Newer commits than the installed one? `{up_to_date, local, remote, commits, note?}` (only commits touching the addon's folder count) |
| `GET /api/addons/<id>/image[?path=…]` | Its logo, or an icon its manifest names. SVGs carry a sandboxing CSP |
| `POST /api/addons/inspect` | `{source}` → `{valid: true, source, commit, manifest, scripts, actions, settings, integration, logo, files, problems, registered}`, or `{valid: false, error}`. Fetches to a scratch folder and validates; adds nothing and runs nothing |
| `GET /api/addons/scan` | `?fresh=1` to skip the one-minute cache → `{scanned, addons: [{id, name, version, platforms, compatible, problems, registered, installed, found, state, installed_version, source, locations, logo}], broken: [{path, error}]}`: addons already on this machine ([the smart scan](addons.md#found-on-this-machine-the-smart-scan)) |
| `POST /api/addons/add` | `{source}` → `{addon}`. Fetches, checks the manifest, runs `detect`. 400 with the exact problem otherwise |
| `POST /api/addons/<id>/install` | `{settings?: {KEY: value}}` → `{job}`. Links it instead when `detect` finds it already here |
| `POST /api/addons/<id>/update` | `{}` → `{job}` |
| `POST /api/addons/<id>/uninstall` | `{keep_data?: true}` → `{job}` |
| `POST /api/addons/<id>/action` | `{action}` → `{job}` |
| `POST /api/addons/<id>/remove` | `{}` → `{ok}`, only once uninstalled |
| `POST /api/addons/<id>/share` | `{via: "serveo"\|"burrow", on, access?}` → `{ways}`: open or drop a serveo link or a Burrow address for an addon whose status reports a `port`. Each addon's `ways` lists `{port, host, local, serveo, burrow}` |

## Burrow

When [Aegis × Burrow](https://github.com/alexd-aero/aegis-burrow) is on the machine, the forge talks to Burrow, its tunnel engine, over the control socket (`AEGIS_HOME/data/control.sock`, readable by your user only), found through `~/.config/aegis/aegis.json` (or `~/.config/burrow/burrow.json` for the older standalone Burrow). Every call carries `X-Burrow-Client: selkies-forge/<version>`, so Burrow's Addon tab can show what the forge did.

| Method & path | Returns |
|---|---|
| `GET /api/burrow` | `{installed, running, mode, pattern, dashboard, tunnels: [{port, url, access, enabled, targetHost, targetPort}]}`. Also included in `GET /api/instances` as `burrow` |
| `POST /api/burrow/publish` | `{desktop, access?: "login"\|"public"}` → `{tunnel, burrow}`: the desktop's web port gets its own Burrow address. Desktops only, never an arbitrary port |
| `POST /api/burrow/unpublish` | `{desktop}` → `{removed, burrow}` |
| `GET /api/bridge` | The [bridge's health](addons.md#the-bridge-selkies-forge-and-burrow-both-ways): `{state: ok\|warn\|fail\|off, checks: [{id, label, state, detail}], checked, logos}` |

## Disk

| Method & path | Body / returns |
|---|---|
| `GET /api/space` | Images by group (`layers`, `built`, `pulled`, `bases`) with size and in-use flag, orphan volumes, build cache, `reclaimable_mb`, `reclaimable_all_mb` |
| `POST /api/space/clean` | `{all?, volumes?, dry_run?}` → removed images and volumes. Never touches anything a container uses. |

## Shell

| Method & path | Body / returns |
|---|---|
| `POST /api/term` | `{container, cols, rows, user?}` → `{id}`; the container must be a running forge desktop |
| `GET /api/term/<id>/stream` | SSE: base64 output chunks, then `closed` |
| `POST /api/term/<id>/input` | `{data}`: keystrokes or pasted text |
| `POST /api/term/<id>/resize` | `{cols, rows}` |
| `POST /api/term/<id>/close` | Ends the session |

## The web UI itself

| Method & path | Body / returns |
|---|---|
| `GET /api/lifecycle` | `{last_stop, boot}`: how it last stopped (with `restore`, the desktops to offer), and the start-on-boot setting |
| `POST /api/restore` | Start the desktops in `last_stop.restore` |
| `POST /api/last-stop/dismiss` | Stop offering that |
| `POST /api/autostart-ui` | `{enable: true\|false}` → start on boot via a systemd user service or cron |
| `GET /api/update` | Update state: installed/running versions, available, restart needed, method (git/download), last error |
| `POST /api/update/check` | Check GitHub now (and install a newer version) |
| `POST /api/update/restart` | Restart the web UI on the same address |

## Example: forge, wait, open

```bash
UI=http://localhost:8787
JOB=$(curl -s -H 'Content-Type: application/json' \
  -d '{"id":"webtop-alpine-i3","opts":{"tunnel":false}}' $UI/api/launch | jq -r .job.id)

until [ "$(curl -s $UI/api/job/$JOB | jq -r .status)" != running ]; do sleep 2; done
curl -s $UI/api/job/$JOB | jq '.result | {name, local_url, session, fixes, warning}'
```
