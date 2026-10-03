# HTTP API

The web UI is a thin page over a JSON API served by the engine. You can use the same API from scripts.

```bash
curl -s localhost:8787/api/instances | jq '.instances[] | {name, running, session}'
```

## Rules

- **Base URL:** wherever the web UI runs (`selkies-cli open` prints it). By default it's `http://localhost:8787`, listening on `127.0.0.1` only.
- **Token:** with `--expose` (or any non-loopback bind) every `/api/` call needs the token, sent as a header `X-Forge-Token: <token>`, a query `?k=<token>`, or the `forge_token` cookie (which the page sets when you open the `?k=` link). The token is in `~/.selkies-forge/state/token`. On localhost-only, no token is needed.
- **POST bodies must be JSON** (`Content-Type: application/json`), even when empty (`{}`).
- **Cross-site requests are refused.** If a request carries an `Origin` header, it must match the host it was sent to. A localhost-only UI also refuses any `Host` header that isn't `localhost`, `127.0.0.1` or `[::1]` (DNS rebinding). Scripts that send neither header are unaffected.
- **Errors** are `{"error": "message"}` with status 400, 401, 403, 404 or 500.
- **Streams** (job events, terminal output) are Server-Sent Events.

## Catalog and machine

| Method & path | Returns |
|---|---|
| `GET /api/boot` | Everything the page needs at start: version, host, the public catalog, family labels, tastes, quick picks, real-screenshot index, instances, counts |
| `GET /api/host` | This machine: arch, cores, memory, disk, Docker version, storage driver, quota support, `/dev/dri` |
| `GET /api/doctor` | The checks shown under *This machine*: `{checks: [{name, ok, detail, fix, severity}], host}` |
| `GET /api/info/<id>` | Wikipedia text and filtered pictures for a catalog entry |
| `GET /api/entry/<id>` | One entry, with its plan for this machine (plus Dockerfile and startwm.sh for built entries) |
| `POST /api/smart` | `{taste, purpose, family?, allow_build?, max_dl_mb?, limit?}` → scored picks with reasons |

## Launching

| Method & path | Body / returns |
|---|---|
| `POST /api/launch` | `{id, plan?: {memory_mb, cpus, shm_mb, disk_mb}, opts?: {...}}` → `{job, plan}` |
| `GET /api/job/<id>` | The job's snapshot: status (`running`, `done`, `error`, `cancelled`), phase, progress, result, error, log path |
| `GET /api/job/<id>/events` | SSE stream of `log`, `phase`, `progress`, `done`, `error` events (first a `snapshot`) |
| `POST /api/job/<id>/cancel` | Cancel it: `{cancelled, job}` |
| `GET /api/jobs` | Recent jobs |
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
| `gpu` | Pass `/dev/dri` through |
| `seccomp_unconfined` | Start with `seccomp=unconfined` (the engine tries this on its own when a session is blocked) |
| `health_timeout` | Seconds to wait for the web port |
| `force` | Start even if free memory is below the desktop's floor |
| `force_pull`, `force_build` | Fetch or build again even if the image is present |
| `env` | Extra `KEY=value` environment variables |

A job's `done` result has `name`, `local_url`, `https_url`, `tunnel`, `credentials`, `session` (window manager, screen, clients), `display`, `fixes` (the auto-fixes it applied), `warning` (if the session came up with a problem) and `instance`.

## Desktops

| Method & path | Body / returns |
|---|---|
| `GET /api/instances` | Every forge desktop, with state, ports, limits, links, tunnel, sign-in, screen mode, `session` (from the watchdog), `heal` |
| `GET /api/stats` | CPU, memory and network per running desktop, with rates and sparklines |
| `POST /api/instance/<name>/start` | Also `stop`, `restart`, `tunnel` (`{subdomain?}`), `untunnel`, `repair`, `remove` (`{purge: true}` also deletes its `/config` volume) |
| `POST /api/instance/<name>/retune` | `{memory_mb?, cpus?, shm_mb?, disk_mb?, autostart?, display?, resolution?}` → `{ok, recreated}`. Memory, CPU and auto-start apply live; the rest recreate the desktop. |
| `GET /api/logs/<name>?tail=N` | `{logs, events}`: the container log and the desktop's recent journal events |
| `GET /api/events?name=&limit=` | The event journal, newest last |

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
