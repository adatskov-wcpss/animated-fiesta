# Addons

An **addon** is an app that installs beside Selkies Forge. You paste a repository link into the web UI, the forge fetches it, checks it, shows you its logo, description and settings, and installs it only when you press **Install**. From then on the forge shows whether it's running, opens it, updates it, runs its actions and uninstalls it.

This page is the complete guide: how to use addons, and how to write one. The format is small on purpose. An addon is **one JSON file and a few bash scripts**, in any repository, written in any language.

- [Using addons](#using-addons)
- [What an addon is](#what-an-addon-is)
- [Your first addon in ten minutes](#your-first-addon-in-ten-minutes)
- [`forge-addon.json`, field by field](#forge-addonjson-field-by-field)
- [The scripts](#the-scripts)
- [The environment](#the-environment)
- [Talking back: `::` lines](#talking-back--lines)
- [Settings](#settings)
- [Already installed? Detect and link](#already-installed-detect-and-link)
- [Updates](#updates)
- [Actions](#actions)
- [Using the forge's API](#using-the-forges-api)
- [Integrations: when the forge plugs into your app](#integrations-when-the-forge-plugs-into-your-app)
- [Where things live](#where-things-live)
- [The example addon, line by line](#the-example-addon-line-by-line)
- [Testing and debugging](#testing-and-debugging)
- [Publishing](#publishing)
- [Rules the forge enforces](#rules-the-forge-enforces)
- [Security](#security)
- [Style guide](#style-guide)
- [Reference: the HTTP API and the CLI](#reference-the-http-api-and-the-cli)
- [FAQ](#faq)

---

## Using addons

### In the web UI

Open **Addons** in the left rail (or press <kbd>4</kbd>).

1. **Paste a link** and press **Add**. Any of these work:

   | You paste | The forge fetches |
   |---|---|
   | `https://github.com/OWNER/REPO` | the repository's root, default branch |
   | `https://github.com/OWNER/REPO/tree/BRANCH/some/folder` | that folder, on that branch (GitLab's `/-/tree/` and Codeberg links work the same) |
   | `https://example.com/repo.git#some/folder` | any git URL, a folder inside it |
   | `git@github.com:OWNER/REPO.git` | over ssh, if your keys allow it |
   | `/home/you/my-addon` | a folder on this machine (for development) |

   Adding only **fetches and checks**. Nothing runs except the addon's quick, read-only `detect` script, which asks "are you already on this machine?".

2. The addon appears as a **card**: its logo, name, version, author, where it came from, and its description. If something about this machine rules it out (Selkies Forge too old, wrong CPU, a missing command), the card says so and **Install** stays disabled.

3. Press **Install**. If the addon has settings, a form opens first (a port, a name, a checkbox for an optional extra…). The install runs as a job: a progress bar, the live log, and a **Cancel** button that stops the script and everything it started. When it's done, **Open** takes you to the addon.

4. The card then shows a live state (**running**, **stopped**, **error**) and gives you, under **⋯**:
   - the addon's **actions** (for example *Restart*),
   - **Settings and reinstall**,
   - **Update** (fetches the code again and runs the addon's update),
   - its links and homepage,
   - **Uninstall** (optionally deleting its data), and once uninstalled, **Remove from the list**.

**Try it:** the *Try the example addon* link on the Addons page adds [Hello Forge](../addons/hello-forge/), a tiny web page that lists your desktops. It installs in a second and uninstalls cleanly.

### From the terminal

```bash
selkies-cli addon add https://github.com/alexd-aero/burrow
selkies-cli addon install burrow --set PORT=4310 --set TERMIX=1
selkies-cli addon list
selkies-cli addon status burrow
selkies-cli addon action burrow restart
selkies-cli addon update burrow
selkies-cli addon uninstall burrow            # --purge also deletes its data
selkies-cli addon remove burrow
```

Installs, updates, uninstalls and actions draw the same progress bar and live log as a desktop launch, and show up (cancellable) in the web UI while they run.

---

## What an addon is

A folder with a manifest and scripts:

```
my-addon/
├── forge-addon.json      the manifest: who it is, what it needs, which scripts do what
├── logo.svg              shown on its card (svg, png, webp or jpg, up to 512 KB)
├── forge/
│   ├── detect.sh         is it already on this machine?          (optional)
│   ├── install.sh        put it on this machine                  (required)
│   ├── update.sh         new code arrived, bring the install up  (optional)
│   ├── uninstall.sh      take it off again                       (optional)
│   └── status.sh         running? where do I open it?            (optional)
└── … your app, in any language …
```

The folder can be a whole repository or one folder inside it, so a project can keep its addon next to its code, and one repository can hold several addons.

The forge never guesses. It runs exactly the scripts the manifest names, from the addon's folder, with `bash`, as the user running the forge, and it reads only what they print. Your app can be Python, Node, Go, a Docker container or a static binary. The forge doesn't care, as long as the scripts start and stop it.

---

## Your first addon in ten minutes

We'll make **Clock**: a page that shows the time, on a port the user picks.

**1. The manifest**, `forge-addon.json`:

```json
{
  "spec": 1,
  "id": "clock",
  "name": "Clock",
  "version": "1.0.0",
  "description": "A page that shows the time. The smallest useful addon.",
  "author": "You",
  "logo": "logo.svg",
  "requires": { "forge": ">=1.10.0", "commands": ["python3"] },
  "scripts": {
    "install": "forge/install.sh",
    "uninstall": "forge/uninstall.sh",
    "status": "forge/status.sh"
  },
  "settings": [
    { "key": "PORT", "label": "Port", "type": "number", "default": 8791, "min": 1024, "max": 65535 }
  ]
}
```

**2. A logo**, `logo.svg`. Anything square works:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="16" fill="#5aa6ff"/>
  <circle cx="32" cy="32" r="18" fill="none" stroke="#061020" stroke-width="5"/>
  <path d="M32 21v12l8 5" fill="none" stroke="#061020" stroke-width="5" stroke-linecap="round"/>
</svg>
```

**3. The app**, `clock.py`:

```python
import http.server, sys, time
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<h1 style='font:64px system-ui'>%s</h1>" % time.strftime("%H:%M:%S")).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
```

**4. Install**, `forge/install.sh`. Start the app in the background, remember its pid in the data folder, tell the forge where to open it:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "::progress 30 Starting the clock"
pkill -F "$FORGE_ADDON_DATA/pid" 2>/dev/null || true
nohup python3 "$FORGE_ADDON_DIR/clock.py" "$FORGE_ADDON_SETTING_PORT" >> "$FORGE_ADDON_DATA/log" 2>&1 &
echo $! > "$FORGE_ADDON_DATA/pid"
sleep 1
kill -0 "$(cat "$FORGE_ADDON_DATA/pid")" || { echo "it did not start:"; tail "$FORGE_ADDON_DATA/log"; exit 1; }
echo "::open http://127.0.0.1:$FORGE_ADDON_SETTING_PORT/"
```

**5. Uninstall**, `forge/uninstall.sh`:

```bash
#!/usr/bin/env bash
pkill -F "$FORGE_ADDON_DATA/pid" 2>/dev/null || true
rm -f "$FORGE_ADDON_DATA/pid"
```

**6. Status**, `forge/status.sh`. One JSON line:

```bash
#!/usr/bin/env bash
url="http://127.0.0.1:$FORGE_ADDON_SETTING_PORT/"
if curl -fs -m 2 "$url" >/dev/null; then
  echo "{\"state\":\"running\",\"url\":\"$url\"}"
else
  echo "{\"state\":\"stopped\",\"url\":\"$url\"}"
fi
```

**7. Try it** straight from the folder:

```bash
selkies-cli addon add ~/clock
selkies-cli addon install clock --set PORT=8791
```

Push it to GitHub and anyone can paste the link. That's a complete addon. Everything below makes it better: detection, updates, actions, and talking to the forge.

> A real addon should survive a reboot. The `pkill`/`nohup` above doesn't. The example addon shows the usual way: a **systemd user unit** when the machine has one, with the background process as the fallback.

---

## `forge-addon.json`, field by field

| Field | Required | Type | What it does |
|---|---|---|---|
| `spec` | **yes** | `1` | The addon format version. This page describes spec 1. A forge refuses a spec it doesn't know and says it needs updating. |
| `id` | **yes** | text | 2–40 lowercase letters, digits and dashes, starting with a letter or digit. The addon's identity: its folder name, its URL, its CLI name. **Never change it** once people use your addon. |
| `name` | **yes** | text, ≤ 60 | Shown on the card. |
| `version` | **yes** | text, ≤ 30 | Shown on the card. Use semantic versions (`1.4.2`). After an update, the forge compares this with the installed version. |
| `description` | no | text, ≤ 600 | One or two sentences: what it is and why you'd want it. The card shows three lines. |
| `author` | no | text, ≤ 80 | "by …" on the card. |
| `homepage` | no | http(s) URL | In the card's menu. |
| `license` | no | text, ≤ 40 | For example `MIT`. |
| `logo` | no | path | `.svg`, `.png`, `.webp` or `.jpg` inside the addon, at most 512 KB. Square, with its own background (cards can be dark or light). |
| `requires` | no | object | What the machine needs. See below. |
| `scripts` | **yes** | object | Which script does what. `install` is required. See [The scripts](#the-scripts). |
| `actions` | no | list, ≤ 8 | Extra buttons in the card's menu. See [Actions](#actions). |
| `settings` | no | list, ≤ 16 | A form shown before installing. See [Settings](#settings). |
| `integration` | no | object | `{"dir": "~/.config/yourapp/integrations"}`: the forge drops a file describing itself there. See [Integrations](#integrations-when-the-forge-plugs-into-your-app). |
| `links` | no | list, ≤ 6 | `[{"label": "Docs", "url": "https://…"}]`, shown in the card's menu. |

Unknown top-level fields are ignored, so a newer manifest still loads in an older forge. Unknown **script names** are an error, because a typo there (`"instal"`) would silently do nothing.

### `requires`

```json
"requires": {
  "forge": ">=1.10.0",
  "os": ["linux"],
  "arch": ["x86_64", "aarch64"],
  "commands": ["python3", "curl", "docker"]
}
```

| Key | Meaning |
|---|---|
| `forge` | The oldest Selkies Forge it works with: `">=1.10.0"` (or just `"1.10.0"`). Spec 1 arrived in 1.10.0. |
| `os` | Lowercase `platform.system()` names. Always `linux` today. |
| `arch` | `uname -m` names: `x86_64`, `aarch64`, `armv7l`. `amd64`, `x64`, `arm64` and `armhf` are understood too. |
| `commands` | Programs that must be on `PATH`. |

If any requirement fails, the card lists exactly what's missing ("needs docker installed", "has no build for armv7l"), and **Install** stays disabled. Requirements are checked again right before installing.

---

## The scripts

Every script is run the same way:

- with **`bash path/to/script`**, so the executable bit doesn't matter (but set it anyway, for running by hand),
- with the **addon's folder** as the working directory,
- as **the user who runs the forge** (never root; use `sudo -n` yourself if you must, and fail clearly when it isn't allowed),
- with **`FORGE_*` variables** in the environment ([below](#the-environment)),
- with **stdin closed** (no prompts: a script that waits for input will hang until its timeout),
- in **its own process group**, so *Cancel* and timeouts stop it and everything it started.

Everything a script prints (stdout and stderr) goes to the live log, except [`::` lines](#talking-back--lines). The exit code decides success: **0 is success**, anything else is failure, and the last line printed becomes the error message. So print a clear sentence before `exit 1`.

| Script | Required | When | Time limit | Must print |
|---|---|---|---|---|
| `detect` | no | when the addon is added, and just before installing | 20 s | exit 0 and one JSON line if the app is already here, otherwise exit 1 |
| `install` | **yes** | **Install** / **Link it** / **Settings and reinstall** | 60 min | `::open URL` (recommended) |
| `update` | no | **Update**, after new code was fetched, if installed | 60 min | `::open URL` if it changed |
| `uninstall` | no | **Uninstall** | 15 min | |
| `status` | no | every few seconds while the Addons page is open (cached for 8 s) | 15 s | one JSON line |
| actions | no | when the user picks the action | 15 min | |

### `detect`

Answers *"is this app already on this machine, installed some other way?"* Keep it quick and **read-only**: look for a config file, a service, a port that answers.

```bash
#!/usr/bin/env bash
[ -f "$HOME/.config/myapp/myapp.json" ] || exit 1
printf '{"version":"%s","url":"%s","detail":"%s"}\n' "2.1.0" "http://127.0.0.1:9000/" "found in ~/.config/myapp"
```

All three JSON fields are optional. `detail` is shown on the card ("Already on this machine: found in ~/.config/myapp"). What happens next: [Already installed? Detect and link](#already-installed-detect-and-link).

### `install`

Puts the app on the machine and starts it. Runs again for **Settings and reinstall**, so it must be **idempotent**: running it twice should give the same result as once (stop the old process before starting a new one, overwrite config files rather than append to them).

### `update`

Runs after the forge has replaced the addon's folder with new code. Typically: migrate the data if needed, restart on the new code. If you don't provide `update`, the forge runs `install` again with `FORGE_ADDON_UPDATE=1`, which is usually exactly right for an idempotent install.

### `uninstall`

Stops the app and removes what `install` created outside `FORGE_ADDON_DATA` (services, symlinks, containers). `FORGE_ADDON_KEEP_DATA` says whether the user ticked *Also delete its data*. If it's `0`, delete your own data elsewhere too (the forge deletes `FORGE_ADDON_DATA` itself). Without an `uninstall` script, the forge only forgets that the addon is installed.

### `status`

Prints one JSON line (the last JSON line printed wins):

```json
{"state": "running", "url": "http://127.0.0.1:9000/", "version": "2.1.0", "detail": "3 clients connected"}
```

| Field | Meaning |
|---|---|
| `state` | `running`, `stopped` or `error` (shown as a coloured pill). Anything else is shown as "installed". |
| `url` | Where **Open** goes. It overrides the URL from `::open`, so it can follow changes (a new port, a linked domain). |
| `version` | The version actually running, if you know it. |
| `detail` | A short line under the description ("3 visits so far", "linked to example.com"). |
| `port` | The port your app's web page listens on. With it, **Open** offers every way in, like a desktop's: see [below](#ways-in-open). |

Without a `status` script the card just says "installed", and **Open** uses the last `::open` URL.

### Ways in: Open

When `status` reports a `port`, the card's **Open** button opens the same chooser as a desktop's **Open desktop**:

| Way in | Address |
|---|---|
| **This machine** | `http://localhost:PORT/`, or the address in your status `url` when the app listens only there |
| **This network** | the same port on the address the forge's page was opened with (a LAN or Tailscale address) |
| **Public link** | **Make a public link** opens a serveo tunnel (`https://….serveousercontent.com`) to the port; **Drop** closes it |
| **Burrow** | when [Burrow](https://github.com/alexd-aero/burrow) is on the machine: **Publish through Burrow** gives the port its own HTTPS address behind Burrow's login; **Unpublish** removes it |

The forge points the tunnels at the host in your status `url` when that's this machine, so an app that listens only on `FORGE_BIND` still works. Uninstalling drops both tunnels. The forge's API has the same thing as `ways` on each addon, so your app can show its own addresses (Hello Forge's page does, under *Ways in*).

---

## The environment

| Variable | Example | Meaning |
|---|---|---|
| `FORGE_ADDON_SPEC` | `1` | The addon spec this forge speaks |
| `FORGE_ADDON_ID` | `hello-forge` | Your `id` |
| `FORGE_ADDON_NAME` | `Hello Forge` | Your `name` |
| `FORGE_ADDON_VERSION` | `1.0.0` | Your `version`, from the manifest being run |
| `FORGE_ADDON_DIR` | `~/.selkies-forge/addons/hello-forge/repo/addons/hello-forge` | Your folder (the working directory). **Replaced on every update**: keep nothing here |
| `FORGE_ADDON_DATA` | `~/.selkies-forge/addons/hello-forge/data` | A folder that's yours, kept across updates and reinstalls. Settings, databases, logs, pid files go here |
| `FORGE_ADDON_SETTING_<KEY>` | `FORGE_ADDON_SETTING_PORT=8790` | Each [setting](#settings). Booleans are `1` or `0` |
| `FORGE_ADDON_ADOPT` | `0` / `1` | `1` when `detect` found the app already here (see [below](#already-installed-detect-and-link)), and during updates |
| `FORGE_ADDON_UPDATE` | `0` / `1` | `1` when this run is an update |
| `FORGE_ADDON_KEEP_DATA` | `1` / `0` | `uninstall` only: `0` when the user asked to delete the data |
| `FORGE_HOME` | `~/.selkies-forge` | The forge's own folder. Read-only for you |
| `FORGE_VERSION` | `1.10.0` | The forge's version |
| `FORGE_URL` | `http://127.0.0.1:8787/` | The web UI, as this machine reaches it. Empty when the web UI isn't running (a CLI install) |
| `FORGE_API` | `http://127.0.0.1:8787/api/` | The [HTTP API](api.md). Empty when the web UI isn't running |
| `FORGE_BIND` | `127.0.0.1` | The address the web UI listens on. Listen on the same one, and your app is reachable from exactly where the forge is |
| `FORGE_PORT` | `8787` | The web UI's port |
| `FORGE_ARCH` | `aarch64` | `uname -m`, normalised |

Everything else in the forge's own environment (`HOME`, `PATH`, `USER`, `XDG_*`…) is passed through.

---

## Talking back: `::` lines

A script talks to the forge by printing lines that start with `::`. They aren't shown in the log.

| Line | Effect |
|---|---|
| `::progress 40 Pulling the image` | Moves the progress bar to 40 % and shows the text. The text is optional. |
| `::phase Installing Burrow` | Names the current step, without moving the bar. |
| `::open https://example.com/` | Where **Open** goes after this install, update or action. http(s) only. |
| `::warn It only answers on this machine` | Shown in the log in the warning colour, and again at the end, beside the result. |

Lines the forge doesn't understand (a misspelt `::progres`) are ignored, never fatal. That lets newer addons stay friendly to older forges.

A good install uses three or four `::progress` steps and one `::open`:

```bash
echo "::progress 10 Checking this machine"
…
echo "::progress 60 Starting"
…
echo "::progress 100 Ready"
echo "::open http://127.0.0.1:$PORT/"
```

---

## Settings

Settings are a form, shown before installing and again under **Settings and reinstall**. Each value reaches the scripts as `FORGE_ADDON_SETTING_<KEY>`.

```json
"settings": [
  { "key": "PORT", "label": "Port", "type": "number", "default": 8790, "min": 1024, "max": 65535,
    "help": "Where the page listens." },
  { "key": "GREETING", "label": "Greeting", "type": "text", "default": "Hello", "required": true },
  { "key": "ACCENT", "label": "Accent", "type": "select", "default": "blue",
    "options": [ { "value": "blue", "label": "Forge blue" }, "green", "amber" ] },
  { "key": "TOKEN", "label": "API token", "type": "password" },
  { "key": "TERMIX", "label": "Also install Termix", "type": "bool", "default": false,
    "icon": "logos/termix.svg", "help": "A terminal in the browser." }
]
```

| Field | Meaning |
|---|---|
| `key` | **Required.** CAPITALS, digits and `_`, starting with a letter, ≤ 32 characters. Unique. |
| `label` | **Required.** The field's label. |
| `type` | `text` (default), `number`, `bool`, `select` or `password`. |
| `default` | The starting value (coerced to the type: `"8080"` becomes `8080`, `"yes"` becomes `true`). |
| `help` | A line under the field. |
| `required` | The install refuses an empty value. |
| `min`, `max` | `number` only. Out-of-range values are refused, with a message. |
| `options` | `select` only: strings, or `{"value", "label"}` objects. |
| `icon` | An image inside the addon (same rules as `logo`), shown beside the field. Good for "also install X" choices: show X's logo. |

**Passwords** are stored in the forge's state file (readable only by you) and never sent back to the browser: the form shows `••••••••`, and leaving it untouched keeps the stored value.

Values are remembered: reinstalling shows what was chosen last time.

---

## Already installed? Detect and link

People often have your app already, installed by hand or by its own installer, before they find your addon. The forge handles that for you:

1. When the addon is **added**, the forge runs `detect`. If it exits 0, the card says **"Already on this machine"**, with your `detail`, and the button reads **Link it** instead of *Install*.
2. **Link it** runs your `install` script with **`FORGE_ADDON_ADOPT=1`**.
3. Your install sees that and **keeps everything the user has**: their data, their config, their login. Usually that means skipping first-run setup and only refreshing the code, the service file, or whatever your addon is responsible for.
4. The forge marks it installed (and *linked*), and from then on it's like any other installed addon: status, actions, updates, uninstall.

```bash
if [ "${FORGE_ADDON_ADOPT:-0}" = 1 ]; then
  echo "::phase Linking the MyApp already on this machine"
  # keep the user's config; only upgrade the code and restart
else
  echo "::phase Installing MyApp"
  # first install: write a fresh config
fi
```

[Burrow](https://github.com/alexd-aero/burrow) is a full example. Its `detect` reads `~/.config/burrow/burrow.json`, which its own installer writes. Its install upgrades an existing Burrow in place, keeping the login, the linked domain and every tunnel, even when that Burrow runs as a system service someone set up by hand.

---

## Updates

**Update** (in the card's menu, or `selkies-cli addon update ID`):

1. Fetches the source again into a temporary folder, from the same link and branch.
2. Checks the new manifest (it must have the same `id`).
3. Swaps the new folder in. `FORGE_ADDON_DATA` is untouched.
4. If the addon is installed, runs `update` (or `install`, with `FORGE_ADDON_UPDATE=1` and `FORGE_ADDON_ADOPT=1`).

If fetching or checking fails, the old code stays as it was. If the update script fails, the new code is in place but the card still shows the old installed version and an **Update** button, so the user can try again.

The forge doesn't check for addon updates by itself (it updates **itself** automatically, but addons are yours to update when you choose).

---

## Actions

Extra buttons in the card's menu, each a script:

```json
"actions": [
  { "id": "restart", "label": "Restart", "script": "forge/restart.sh" },
  { "id": "reset", "label": "Reset everything", "script": "forge/reset.sh",
    "confirm": "Delete every saved item and start over?" }
]
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits, dashes, ≤ 24. Not one of the lifecycle script names. |
| `label` | ≤ 24 characters, the button's text. |
| `script` | The script to run. Same rules as the lifecycle scripts. |
| `confirm` | If set, the user must confirm this sentence first. Use it for anything destructive. |

Actions only appear once the addon is installed. They run as jobs, with the live log, and can print `::open`.

---

## Using the forge's API

`FORGE_API` points at the forge's [HTTP API](api.md) when the web UI is running. Your scripts, or your app, can read and drive the forge:

```bash
# every desktop, with its state and links
curl -s "$FORGE_API"instances | python3 -c 'import json,sys; [print(i["name"], i["running"]) for i in json.load(sys.stdin)["instances"]]'

# stop one (POSTs must send JSON)
curl -s -X POST -H 'Content-Type: application/json' -d '{}' "$FORGE_API"instance/forge-noble-xfce/stop
```

Save `FORGE_API` in your config at install time (the example addon does). The web UI's address can change when it's restarted with another `--bind` or `--port`, so refresh it on every install and update.

Calls from your app on the same machine need no token. Mind the API's [rules](api.md#rules): JSON bodies, and no `Origin` header from another site.

---

## Integrations: when the forge plugs into your app

Some apps want to show the forge inside *their own* dashboard. If your app keeps a **drop-in folder** for that, declare it:

```json
"integration": { "dir": "~/.config/myapp/integrations" }
```

While your addon is installed and the forge's web UI runs, the forge keeps a file called `selkies-forge.json` in that folder up to date:

```json
{
  "spec": 1,
  "id": "selkies-forge",
  "kind": "selkies-forge",
  "name": "Selkies Forge",
  "version": "1.10.0",
  "url": "http://127.0.0.1:8787/",
  "api": "http://127.0.0.1:8787/api/",
  "port": 8787,
  "public_url": null,
  "logo": "<svg …>",
  "home": "/home/you/.selkies-forge",
  "updated": 1760000000
}
```

Your app reads it to find the forge, and calls `api` for desktops (`GET instances`) and actions (`POST instance/NAME/start|stop|restart`). The file is written when something changes and touched once an hour, so `updated` also tells you the forge is alive.

[Burrow](https://github.com/alexd-aero/burrow) does exactly this. The forge also knows Burrow's folder (`~/.config/burrow/integrations`), so it registers itself there **whenever Burrow is on the machine**, however Burrow was installed. Burrow then shows a Selkies Forge card on its Tunnels page: every desktop, its links, start/stop/restart, and one-click publishing.

---

## Where things live

```
~/.selkies-forge/                     FORGE_HOME
├── addons/
│   └── <id>/
│       ├── repo/                     the checkout (a sparse clone if you linked a folder)
│       │   └── <subdir>/             FORGE_ADDON_DIR, replaced on update
│       └── data/                     FORGE_ADDON_DATA, kept across updates
├── state/
│   └── addons.json                   the registry: source, commit, manifest, installed?, settings
└── logs/jobs/                        every install, update, uninstall and action, one log each
```

Removing an addon deletes `addons/<id>/` (checkout and data). Uninstalling keeps the data unless the user ticks *Also delete its data*.

---

## The example addon, line by line

[`addons/hello-forge/`](../addons/hello-forge/) in this repository is a complete addon that uses every feature: detection, all five scripts, four kinds of settings, two actions (one with a confirmation), progress, `::open`, `::warn`, a systemd user service with a fallback, the forge's API, and data that survives updates.

```
addons/hello-forge/
├── forge-addon.json       spec 1, settings PORT · GREETING · ACCENT · SHOW_DESKTOPS, two actions
├── logo.svg
├── app/server.py          the page: stdlib Python, reads its config, calls FORGE_API
└── forge/
    ├── lib.sh             shared: paths, config writing, the service, health checks
    ├── detect.sh          "already here" = its config exists and the page answers
    ├── install.sh         checks, config, service, waits until healthy, ::open
    ├── update.sh          rewrites the config (new FORGE_API), restarts on new code
    ├── uninstall.sh       removes the service; deletes settings if asked
    ├── status.sh          {"state","url","port","version","detail": "N visits so far"}
    ├── restart.sh         an action
    └── reset-visits.sh    an action with a confirmation
```

Things worth copying from it:

- **One `lib.sh`, sourced by every script**, so paths and the service logic live in one place.
- **`write_config` turns settings into a config file** in `FORGE_ADDON_DATA`, keeping state the user built up (the visit counter) across reinstalls.
- **`port_taken` refuses a port something else holds**, but not its own previous instance, so a reinstall on the same port works.
- **The service unit runs the app from `FORGE_ADDON_DIR`**. That path stays the same across updates, so `update.sh` only restarts.
- **`wait_up` polls `/health`** before declaring success, and on failure prints the log's last lines, so the install's error message explains itself.
- **The app listens on `FORGE_BIND`**, so it's reachable from exactly where the forge's web UI is.

Add it from the Addons page (*Try the example addon*), or:

```bash
selkies-cli addon add https://github.com/adatskov-wcpss/animated-fiesta/tree/main/addons/hello-forge
selkies-cli addon install hello-forge --set GREETING="Hi there"
```

---

## Testing and debugging

**Add from a folder while you develop.** `selkies-cli addon add ~/src/my-addon` copies the folder (minus `.git` and `node_modules`). After changing it, `selkies-cli addon update my-addon` copies it again and runs your update.

**Run a script by hand**, with the same environment the forge gives it:

```bash
cd ~/.selkies-forge/addons/my-addon/repo
FORGE_ADDON_ID=my-addon FORGE_ADDON_DIR=$PWD FORGE_ADDON_DATA=../data \
FORGE_ADDON_SETTING_PORT=8791 FORGE_API=http://127.0.0.1:8787/api/ bash forge/install.sh
```

**Read the logs.** Every job's full output is in `~/.selkies-forge/logs/jobs/` (newest last), and `selkies-cli jobs` lists them.

**Check the manifest without installing.** `selkies-cli addon add` checks it and prints the exact problem ("setting PORT: type must be one of …", "scripts.install (forge/instal.sh) does not exist").

**Check the state the forge keeps:**

```bash
selkies-cli addon info my-addon     # everything the web UI sees, as JSON
selkies-cli addon status my-addon   # just the status script's answer
```

**A checklist before you publish:**

- [ ] `install` twice in a row works (idempotent).
- [ ] `install`, `uninstall`, `install` works.
- [ ] `uninstall` leaves no process, service or container behind.
- [ ] A reboot brings the app back (a systemd user unit, or `@reboot` in cron).
- [ ] `status` answers within a second or two, even when the app is down.
- [ ] `detect` is read-only and quick.
- [ ] A failed install prints a clear last line.
- [ ] It works when the forge listens on `127.0.0.1` **and** on a LAN or Tailscale address (`FORGE_BIND`).
- [ ] The logo looks right on dark and light cards (the forge has dark and light themes).

---

## Publishing

There is no store and nothing to register. Push the folder to any git host and share the link:

- a whole repository: `https://github.com/you/my-addon`,
- or a folder in one: `https://github.com/you/project/tree/main/forge-addon`.

Put a short **README** beside the manifest: what it is, what it installs, what its settings mean. People see your card before they read your code. Tag the repository with **`selkies-forge-addon`** so others can find it.

Bump `version` with every release that changes behaviour. People update when they choose, and the version is how they know there's something new.

---

## Rules the forge enforces

| Rule | Why |
|---|---|
| Paths in the manifest are relative, inside the addon, and must exist | Nothing outside the addon is ever run or served, symlinks included |
| `install` is required, unknown script names are refused | A typo must not silently skip a step |
| Logos and icons: svg/png/webp/jpg, ≤ 512 KB, and only the ones the manifest names | The forge serves them, and nothing else, from your folder |
| SVGs are served with a sandboxing CSP and shown with `<img>` | A logo can never run script in the forge's page |
| `id` is 2–40 lowercase letters, digits, dashes | It's a folder name, a URL part and a CLI argument |
| Two different sources can't hold the same `id` while one is installed | Updating must not swap one app for another |
| Settings are type-checked and range-checked on the server | Scripts can trust what they receive |
| Time limits on every script, and *Cancel* kills the whole process group | A stuck script can't wedge the forge |
| `::open` URLs must be http(s) | Nothing else is ever linked |
| The manifest is ≤ 64 KB, ≤ 8 actions, ≤ 16 settings, ≤ 6 links | Cards stay readable |

---

## Security

> [!WARNING]
> **An addon runs code as you.** Its scripts can do anything you can do on this machine, including everything Docker allows. Add addons from people you trust, and read the scripts of ones you don't know: they're short by design.

- Adding an addon runs **only** its `detect` script. Nothing installs until someone presses **Install**.
- The install dialog names the source whose script will run.
- The web UI has no sign-in (see [Security](security.md)). Anyone who can reach it can install addons, just as they can already run containers. Keep it on localhost, or behind a login like [Burrow](https://github.com/alexd-aero/burrow)'s.
- Addon logos and icons are never rendered as pages, and SVGs can't run script.
- Password settings never go back to the browser.

---

## Style guide

Addons feel native when they follow the forge's habits:

- **Say what happens, in plain words.** "Pulling the image (once, about 300 MB)…" beats "step 3/7".
- **End every failure with one clear sentence**: what went wrong, and what to do. The last line is the error the user sees.
- **Listen on `FORGE_BIND`**, and default to a port that's unlikely to clash (8790–8799 is a good neighbourhood).
- **Keep state in `FORGE_ADDON_DATA`.** Never in `FORGE_ADDON_DIR`, which is replaced on every update.
- **Make install idempotent**, and make uninstall leave nothing behind.
- **A square logo with its own background**, readable at 54 px, on both dark and light themes.
- **Describe it in one breath**: what it is, then why. Three lines show on the card.

---

## Reference: the HTTP API and the CLI

| Method & path | What it does |
|---|---|
| `GET /api/addons` | Every addon, with its live status: `{addons: [...], spec: 1}` |
| `GET /api/addons/<id>` | One addon |
| `GET /api/addons/<id>/image[?path=…]` | Its logo, or an icon the manifest names |
| `POST /api/addons/add` | `{source}` → `{addon}`. Fetches and checks; runs `detect` |
| `POST /api/addons/<id>/install` | `{settings: {KEY: value}}` → `{job}` |
| `POST /api/addons/<id>/update` | `{}` → `{job}` |
| `POST /api/addons/<id>/uninstall` | `{keep_data: true}` → `{job}` |
| `POST /api/addons/<id>/action` | `{action: "restart"}` → `{job}` |
| `POST /api/addons/<id>/remove` | `{}` → `{ok}`. Only when uninstalled |
| `POST /api/addons/<id>/share` | `{via: "serveo"\|"burrow", on: true\|false, access?: "login"\|"public"}` → `{ways}`. Needs a `port` from `status` |

Jobs stream like launches: `GET /api/job/<id>/events` (Server-Sent Events), cancel with `POST /api/job/<id>/cancel`. See [the HTTP API](api.md).

```
selkies-cli addon list
selkies-cli addon add LINK
selkies-cli addon info ID
selkies-cli addon install ID [--set KEY=VALUE]...
selkies-cli addon update ID
selkies-cli addon uninstall ID [--purge]
selkies-cli addon remove ID [--force]
selkies-cli addon action ID ACTION
selkies-cli addon status ID
```

---

## FAQ

**Can an addon be private?** Yes, if `git` on this machine can clone it (an ssh link with your key, or a credential helper). The forge never asks for passwords.

**Can an addon run a Docker container?** Of course: `docker run` in `install`, `docker rm -f` in `uninstall`. Give it a name and a label, and bind its ports to `127.0.0.1` or `FORGE_BIND`.

**Can it need root?** Try not to. If you must, use `sudo -n` (no prompt) and, when that fails, print the exact command for the user to run, then `exit 1`.

**Does the forge restart addons after a reboot?** No. Your install sets that up (a systemd user unit, cron `@reboot`, or Docker's `--restart unless-stopped`). The forge only shows what `status` says.

**What happens to installed addons when the forge updates?** Nothing. Addons are independent of the forge's own updates.

**What if two addons want the same port?** The second one's install should notice (`port_taken` in the example) and say so. Settings let the user pick another.

**Is there a size limit for the repository?** No, but when the link points at a folder, the forge fetches only that folder (a sparse clone), so a big repository costs little.

**How do I uninstall an addon whose repository vanished?** Uninstall and remove work from the local copy. Only *Update* needs the source.
