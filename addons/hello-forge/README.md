<img src="logo.svg" width="72" align="right" alt="Hello Forge">

# Hello Forge

The example addon for [Selkies Forge](../../README.md). A small web page that greets you and lists this machine's desktops, read from the forge's API. It exists to be read: every part of the [addon format](../../docs/addons.md) is used here once, in the simplest way that works.

**Add it:** in Selkies Forge, *Addons → Try the example addon*, or paste

```
https://github.com/adatskov-wcpss/animated-fiesta/tree/main/addons/hello-forge
```

| File | What it shows |
|---|---|
| [`forge-addon.json`](forge-addon.json) | the manifest: requirements, all five scripts, four kinds of settings, two actions (one with a confirmation), a link |
| [`forge/lib.sh`](forge/lib.sh) | one file of helpers sourced by every script: paths, writing the config from settings, a systemd user service with a background-process fallback, health checks |
| [`forge/detect.sh`](forge/detect.sh) | quick, read-only "already here?", answered with one JSON line |
| [`forge/install.sh`](forge/install.sh) | `::phase`, `::progress`, `::warn`, `::open`; refuses a port someone else holds; waits until healthy; explains failures |
| [`forge/update.sh`](forge/update.sh) | restarts on the new code, keeps the data |
| [`forge/uninstall.sh`](forge/uninstall.sh) | leaves nothing behind; honours `FORGE_ADDON_KEEP_DATA` |
| [`forge/status.sh`](forge/status.sh) | `{"state", "url", "version", "detail"}` |
| [`forge/restart.sh`](forge/restart.sh), [`forge/reset-visits.sh`](forge/reset-visits.sh) | actions |
| [`app/server.py`](app/server.py) | the app: Python standard library only, calls `FORGE_API`, keeps its counter in `FORGE_ADDON_DATA` |

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `PORT` | number | `8790` | where the page listens (on the forge's own address) |
| `GREETING` | text | `Hello from an addon` | the headline |
| `ACCENT` | select | `blue` | blue, green, amber, black and white |
| `SHOW_DESKTOPS` | bool | on | list the forge's desktops |

Needs `python3` and `curl`. Runs as a systemd user service (`forge-addon-hello-forge-<id>.service`, one per install) when there is one, otherwise in the background. MIT licensed, like the forge: copy it as the start of your own addon.
