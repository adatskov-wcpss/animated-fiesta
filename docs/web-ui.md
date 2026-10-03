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
- **Options.** A name, a public serveo link, start with Docker, pass the GPU (`/dev/dri`), relax seccomp, and **Screen** (automatic, follow my window, or fixed size with a resolution).
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
- **Session:** the window manager the agent sees, and the screen ("i3 running · 1600×900"). A red **Session crashed on start** line, with a link to what happened, if it's in rescue mode.
- **Metrics:** CPU, memory against its cap, and network, with a live bandwidth sparkline.
- **Access:** local and public links (copy, open), sign-in with reveal and copy.
- **Limits:** RAM, CPU, shared memory, storage, auto-start. **Edit** changes them; memory, CPU and auto-start apply live, the rest recreate the desktop (files kept).
- **Actions:** **Open desktop**, **Shell** (a live terminal that slides out inside the card), **Stop** / **Start**. The **⋯** menu has restart, open/drop public link, **container logs and what happened** (the event journal), edit limits, **Repair**, and remove (optionally with its files).

The top strip totals desktops, memory in use, and data downloaded and uploaded.

**Last stop banner.** After a reboot or a crash, a banner names what happened and offers to **start the desktops that were running then**.

**Update banner.** When the forge has installed a new version from GitHub, a banner offers **Restart now**. Your desktops keep running.

## The shell

**Shell** on a card opens a real PTY into the desktop (`docker exec -it`, bash if it has one): colours, cursor keys, Ctrl-C, paste, resize to fit. Pop it out to the full-size shell view if you need room.

## This machine

- **Checks:** Python, Docker, SSH, memory, disk, architecture, disk-quota support, serveo reachability, each with a fix if it fails.
- **Facts:** hostname, OS, kernel, Docker version, storage driver, cgroup version, and so on.
- **Web UI:** the **start on boot** toggle, and how the web UI last stopped.
- **Disk used by the forge:** layers, built and pulled desktop images (and how much of each is unused), base images, build cache, orphan volumes. **Tidy up** removes old layers. **Remove everything unused** also removes unused desktop images and the build cache. Nothing a desktop uses is ever removed.

## Keyboard

| Key | Does |
|---|---|
| `/` | Search |
| `1` / `2` / `3` | Browse / Manager / This machine |
| `Esc` | Close a dialog, menu or the lightbox |
| `←` `→` | Previous/next picture in the lightbox |

Shortcuts never fire while you're typing in a field or a terminal.
