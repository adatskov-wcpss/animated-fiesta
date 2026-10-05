# The web UI

`selkies-cli start` (or `--webui`) starts it on `http://localhost:8787/`, or the next free port. It's a single-page app with no build step and no external scripts, served by the engine. It's built to stay smooth on a Raspberry Pi: one fixed background layer, no animated blur, and **Lite mode** turns the blur off completely (automatic on small devices).

## Browse

![Browsing the catalog](screenshots/browse.png)

- **Search** with `/`: names, desktops, tags (`xfce`, `kali`, `tiny`, `kde`).
- **Filters:** distro family, desktop, weight (feather → heavy), and kind (ready-made, built, Kasm, curated).
- **Let it choose:** pick a taste (*balanced, beautiful, lightest, fastest*) and a purpose. The chooser scores every desktop against this machine's free memory, cores and disk, and explains its picks.
- Cards show the logo, desktop, weight, download size, and whether this machine's architecture is supported.

## A desktop's page

![A desktop page](screenshots/detail.png)

- **What you get.** A real screenshot of this exact desktop running in Selkies Forge, when one has been captured (from this repository's `shots/` folder).
- **About.** The distro and desktop from Wikipedia, with links.
- **Screenshots.** Pictures of the desktop from Wikimedia Commons, plus the distro's own pictures **only when they show this same desktop**. Pictures that showed installers, other window managers or decades-old releases are filtered out. Click any picture for the lightbox (← → and Esc). Captions are shown in full.
- **Resources.** Sliders for memory, CPU, shared memory (browsers inside want 512 MB+) and storage, each with advice, and this machine's free resources.
- **Sign-in.** Optional username and password in front of the desktop; *Generate* makes a strong one. Kasm images always ask, as `kasm_user`.
- **Options.** A name, a public serveo link, start with Docker, **GPU** (Smart, Force on or Off; see [GPU Smart Passthrough](gpu.md)), relax seccomp, and **Screen** (automatic, follow my window, or fixed size with a resolution; phones, HiDPI and 4K screens are handled by the [screen guard](forge-layer.md#the-screen-guard-hidpi-phones-and-4k)).
- **How it's built.** The Dockerfile, for built desktops.

## Forging

The launch view streams everything: steps (*check → fetch → build → forge layer → start → handshake → desktop → tunnel → ready*), a progress bar with bytes and layers for pulls and packages for builds, and the full live log.

- **Queued**: it's waiting for a build, pull or boot slot. See [the scheduler](engine.md#the-scheduler).
- **Cancel** stops it at any point. The download or build is killed, and a half-made desktop is removed.
- **Ready** shows the links (public, local, LAN https), the sign-in, the window manager that came up, the screen mode, and any **fixes applied on the way**.
- **Started, with a problem** quotes the desktop's own session log. The desktop is left running in a rescue session that shows the same log.

## The manager

![The manager](screenshots/manager.png)

One card per desktop:

- **Header:** logo, name, distro, desktop, running time or exit status.
- **Session:** the window manager the agent sees, the screen, and who is watching ("i3 running · 1600×900 · 2 watching", or "unwatched 14 min, stops in 16 min"). A red **Session crashed on start** line, with a link to what happened, if it's in rescue mode.
- **Metrics:** CPU, memory against its cap, and network, with a live bandwidth sparkline.
- **Access:** local and public links (copy, open), sign-in with reveal and copy.
- **Limits:** RAM, CPU, shared memory, storage, auto-start. **Edit** changes them; memory, CPU and auto-start apply live, the rest recreate the desktop (files kept).
- **Actions:** **Open desktop**, **Shell** (a live terminal that slides out inside the card), **Stop** / **Start**. The **⋯** menu has restart, open/drop public link, **container logs and what happened** (the event journal), edit limits, **Repair**, **Stop when idle…**, **Back up files**, **Backups…** (restore one, start a new desktop from one, delete), **Clone…**, and remove (optionally with its files).

The top strip totals desktops, memory in use, and data downloaded and uploaded.

**Working.** Launches, backups, restores and clones in progress show above the cards with their progress and a **Cancel** button. That includes ones started from `selkies-cli` in a terminal.

**Low memory.** When the machine runs short of memory, the RAM meter turns red and a warning suggests what to stop.

**Last stop banner.** After a reboot or a crash, a banner names what happened and offers to **start the desktops that were running then**.

**Update banner.** When the forge has installed a new version from GitHub, a banner offers **Restart now**. Your desktops keep running.

### Open desktop

**Open desktop** lists every way into the desktop:

| | |
|---|---|
| **This machine** | `localhost:PORT`, for a browser on the forge's own machine |
| **This network** | the same port on the address you opened the forge with (your LAN or Tailscale address), when that isn't localhost |
| **Public link** | its serveo link (`https://….serveousercontent.com`), or **Make a public link** |
| **Burrow** | when [Burrow](https://github.com/alexd-aero/burrow) is installed: its Burrow address behind Burrow's login, or **Publish through Burrow**; **Unpublish** removes it |

A desktop published through Burrow also shows a **Burrow** row on its card, beside *Local* and *Public*. Addons whose status reports a port get the same chooser from their **Open** button.

## The shell

**Shell** on a card opens a real PTY into the desktop (`docker exec -it`, bash if it has one): colours, cursor keys, Ctrl-C, paste, resize to fit. Pop it out to the full-size shell view if you need room.

## This machine

- **Checks:** Python, Docker, SSH, memory, disk, architecture, disk-quota support, serveo reachability, each with a fix if it fails.
- **Facts:** hostname, OS, kernel, Docker version, storage driver, cgroup version, and so on.
- **Web UI:** the **start on boot** toggle, and how the web UI last stopped.
- **Disk used by the forge:** layers, built and pulled desktop images (and how much of each is unused), base images, build cache, orphan volumes. **Tidy up** removes old layers. **Remove everything unused** also removes unused desktop images and the build cache. Nothing a desktop uses is ever removed.

## Addons

Apps that install beside the forge. Paste a repository link and press **Add**. The forge fetches it and shows a card: logo, name, version, author, source, description, and anything about this machine that rules it out. Nothing is installed until you press **Install** (or **Link it**, when the app is already on the machine). That opens its settings, if it has any, then a live log with a progress bar and **Cancel**. Installed cards show a live state, **Open**, and a **⋯** menu with the addon's actions, *Settings and reinstall*, *Check for updates*, its links, and *Uninstall*. *Check for updates* compares the installed commit with the repository's newest one and says **Up to date**, or names the commit available to update to, with its new commits and an **Update** button. *Try the example addon* adds [Hello Forge](../addons/hello-forge/). Everything about addons, including writing one: [Addons](addons.md).

## Themes

The **Theme** picker in the left rail switches the whole UI; each browser remembers its choice.

| Theme | Look |
|---|---|
| **Forge** | Blue glass, the default |
| **Stealth** | Black room, a faint grid, graphite surfaces lit along their top edge, white as the only accent: the same look as [Burrow](https://github.com/alexd-aero/burrow)'s dashboard |
| **Daylight** | Light surfaces, for bright rooms (terminals stay dark) |
| **Ember** | Warm amber on charcoal |

Every colour in `app.css` is a variable on `:root` (`--bg`, `--glass`, `--txt`, `--acc`, `--ink` for overlays, `--term-bg`…). A theme is a block like this at the end of `app.css`, plus an entry in `THEMES` in `app.js`:

```css
html[data-theme="mine"] {
  --bg: #0b0f0c; --glass: rgba(20, 30, 24, 0.6); --txt: #e8f5ec;
  --acc: #3ddc97; --acc-2: #2bb3a3; --acc-rgb: 61, 220, 151; --on-acc: #04140c;
  --bg-paint: radial-gradient(900px 500px at 15% -10%, rgba(61, 220, 151, 0.15), transparent 60%), #0b0f0c;
}
```

## Keyboard

| Key | Does |
|---|---|
| `/` | Search |
| `1` / `2` / `3` / `4` | Browse / Manager / This machine / Addons |
| `Esc` | Close a dialog, menu or the lightbox |
| `←` `→` | Previous/next picture in the lightbox |

Shortcuts never fire while you're typing in a field or a terminal.
