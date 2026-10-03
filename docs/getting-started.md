# Getting started

## What you need

| | |
|---|---|
| **A Linux machine** | x86_64 or arm64 (a Raspberry Pi 4/5 works well). All 153 desktops run on x86_64; 148 also run on arm64. |
| **Permission to install** | `sudo` the first time, if Python 3.8+ or Docker are missing. After that your user needs to be in the `docker` group. |
| **Package manager** | apt, dnf, yum, pacman, apk or zypper. The script uses whichever one you have. |
| **Disk** | About 1.5 to 7 GB per desktop image, plus each desktop's storage budget (10 GB by default). |
| **Memory** | About 1 GB for the lightest window managers; 2.5 GB or more for KDE Plasma. |
| **Network** | Registry access for images. Outbound SSH (port 22) to `serveo.net`, only if you want public links. |

## Install and run

```bash
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh | bash
```

That one file does everything:

1. It checks for Python 3.8+ and Docker, and offers to install whatever is missing.
2. It unpacks the engine and web UI into `~/.selkies-forge/app`.
3. It installs the `selkies-cli` command, so you never need the long command again.
4. It opens the home screen.

To pass options through a pipe, put them after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh | bash -s -- --webui
```

Or download it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh
bash docker.sh --help
```

## Your first desktop

**From the web UI** (`selkies-cli start`, then open the link):

1. Pick a desktop in **Browse**. *Let it choose* at the top scores the catalog against this machine's free memory, cores and disk.
2. On its page, check the resources, sign-in, screen and public-link options, then press **Forge it**.
3. Watch the live log. A ready-made image only downloads. A built desktop installs its packages on your machine the first time, which takes a few minutes. You can cancel at any point.
4. When it says **Ready**, open the link. It's a full Linux desktop in your browser tab.

**From the terminal:** run `selkies-cli` and pick **Browse & forge a new desktop**, or launch one directly:

```bash
selkies-cli list                    # every desktop with its ID
bash docker.sh --launch noble-xfce  # forge one and print its links
```

## What a first launch looks like

```
P 1 resolve Checking Ubuntu 24.04 LTS Xfce 4 against this machine
L host     : arm64, 4 cores, 12.8 GB RAM free, 364.5 GB disk free
L plan     : 1.5 GB RAM, 1.5 CPU, 384 MB shm, screen fixed 1920×1080, scaled to fit
L image    : lscr.io/linuxserver/baseimage-selkies:ubuntunoble
L layer    : adding the forge layer (first-run fixes, screen agent, session supervisor)
L container: forge-noble-xfce (5cda436c8fc4)
L web      : answering on port 41820
L session  : Xfwm4 is running (1024x768, 3 windows)
L tunnel   : https://8abccb82….serveousercontent.com
P 100 ready Ready
```

A launch isn't "ready" until a window manager is running and stays up. A page that loads but shows a black screen doesn't count. See [the engine](engine.md#health-is-the-desktop-really-up).

## Where things end up

```
~/.selkies-forge/
├── app/        engine.py, forge/ (the engine), web/ (the UI), data/, selkies-cli
├── state/      instances, ports, events.jsonl, web UI lifecycle, boot setting, updates
├── logs/       web UI, tunnels, updates, and jobs/ (one log per launch)
├── builds/     Dockerfiles and forge-layer build contexts
└── repo/       a git clone of this project, used for updates

~/.local/bin/selkies-cli    a small wrapper that runs app/selkies-cli
```

Docker holds the rest: containers named `forge-*`, images tagged `selkies-forge/*`, and one volume per desktop, `forge-config-<name>`, which is that desktop's home folder.

## Next

- [The `selkies-cli` command](cli.md)
- [The web UI](web-ui.md)
- [Start the web UI on boot](operations.md#start-the-web-ui-on-boot)
