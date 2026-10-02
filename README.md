# Selkies Forge

Run any of **158 Linux desktops** in Docker and use them from your browser: Ubuntu, Debian, Fedora, Arch, Alpine, Kali, Rocky, AlmaLinux and more, with 29 desktop environments and window managers from KDE Plasma down to `twm`.

`docker.sh` is a single bash script. It installs what it needs, then gives you a terminal menu and a web UI for picking, launching and managing desktops.

![Browsing the catalog, with the "Let it choose" picks at the top](docs/screenshots/browse.png)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh | bash
```

Or download it first, so you can read it before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh -o docker.sh
bash docker.sh
```

To pass options while piping, put them after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh | bash -s -- --webui
```

On the first run it:

1. installs Python 3 and Docker if they are missing (it asks first, and needs `sudo`),
2. unpacks its engine and web UI into `~/.selkies-forge`,
3. installs the `selkies-cli` command,
4. opens the home screen.

## Coming back: `selkies-cli`

After the first run you never need the long command again. From any terminal:

```bash
selkies-cli
```

It checks what is going on before it asks you anything:

```
  Status
  ────────────────────────────────────────────────────────────────
  Web UI    ●  running at http://localhost:8787/  · up 2h 14m
  Desktops  ●  2 running · 1 stopped
     ● Alpine MATE            localhost:33149  public 8abccb82….serveousercontent.com
     ● Ubuntu 24.04 Xfce 4    localhost:34961
     ○ Debian KDE Plasma      stopped
  ────────────────────────────────────────────────────────────────
  What would you like to do?
  ❯ Open the web UI                    running at http://localhost:8787/
    Manage desktops                    2 running, 1 stopped
    Forge a new desktop                pick from 150+ desktops
    Stop the web UI                    your desktops keep running
    Restart the web UI                 after an update, or if it misbehaves
```

The first suggestions change with what it finds:

| It finds | It suggests first |
|---|---|
| Nothing set up yet | Forge your first desktop, then start the web UI |
| The web UI running | Open it, manage desktops, forge a new one, stop or restart it |
| The web UI crashed (its process is gone, or it stopped answering) | Start it again, show why it stopped |
| Desktops running, but no web UI | Start the web UI, or manage desktops right there in the terminal |
| Docker not answering | Find out why |

For quick jobs, skip the menu:

| Command | What it does |
|---|---|
| `selkies-cli status` | Print the status above and exit |
| `selkies-cli start` | Start the web UI in the background |
| `selkies-cli stop` | Stop the web UI (desktops keep running) |
| `selkies-cli restart` | Restart it on the same address |
| `selkies-cli open` | Print the web UI's link and open it in a browser if there is one; offers to start it if it is down |
| `selkies-cli manager` | Manage desktops in the terminal |
| `selkies-cli new` | Forge a new desktop from the hand picked list |
| `selkies-cli update` | Install the latest version from GitHub now, then offer to restart the web UI so it uses it |
| `selkies-cli uninstall` | Remove everything, including the command itself |

### Automatic updates

Selkies Forge keeps itself up to date from this repository:

- **While the web UI runs**, it checks GitHub every 5 minutes. When there is a new build, it installs it on its own and shows a banner with a **Restart now** button. Your desktops keep running through the restart.
- **When you run `selkies-cli`**, it checks too, at most once every 5 minutes. If there is a new build, it installs it and carries on with the new version.

Each check sends GitHub the identifier of the last copy it downloaded, so an unchanged file costs a tiny "not modified" reply instead of a 560 KB download. Set `FORGE_AUTO_UPDATE=0` to turn automatic updates off; `selkies-cli update` still works by hand.

`selkies-cli` goes in `~/.local/bin` (or `~/bin`) when that folder is on your `PATH`, otherwise in `/usr/local/bin` if you can write to it. If neither works it goes in `~/.local/bin`, and a short marked block is added to `~/.bashrc` (plus `~/.zshrc` and `~/.profile` if you have them) to put that folder on your `PATH`. Open a new terminal once for that to take effect. Set `FORGE_BIN_DIR` to choose the folder yourself; your shell profiles are then left alone.

## Requirements

| | |
|---|---|
| **OS** | Linux on x86_64 or arm64. All 158 desktops run on x86_64; 153 have arm64 images. |
| **Privileges** | `sudo` for the first install only. After that your user needs to be in the `docker` group. |
| **Package managers** | apt, dnf, yum, pacman, apk and zypper are handled automatically. |
| **Disk** | Each desktop image takes about 1.5 to 7 GB, plus its storage budget (10 GB by default). |
| **Memory** | About 1 GB for the lightest window managers, 2.5 GB or more for KDE Plasma. |
| **Network** | Outbound SSH (port 22) to `serveo.net` if you want public links. |

macOS and Windows hosts are not supported.

## Using it

### The home screen

Run `selkies-cli` (or the script with no options) to see the status and a menu. Besides the suggestions above, it has:

| Option | What it does |
|---|---|
| Forge a new desktop | From the 17 hand picked desktops, by distro family, by search, or "Let it choose" (scored against this machine's free memory, cores and disk) |
| Manage desktops | Links, sign-in, limits, auto-start, shells, logs |
| Check this machine | Docker, memory, disk and tunnel checks |
| Update Selkies Forge | Install the latest version from GitHub |

Use the arrow keys (or `j`/`k`) and Enter. `q` goes back.

### The web UI

When the web UI starts, the script asks whether to **run it in the background** (you get your shell back) or **hold the terminal** until you press Ctrl-C. It listens on `http://localhost:8787`, or on the next free port if that one is taken.

**Browse.** Search everything, filter by family, weight (feather to heavy) and kind (ready to run or built here), and sort by looks, lightness, speed or download size. "Let it choose" ranks the catalog for this machine and explains each pick.

**Desktop pages.** Every entry has a description and screenshots from Wikipedia and Wikimedia Commons. From the page you set memory, CPU, shared memory and storage, choose whether to require a username and password, and decide on a public link and auto-start.

![A desktop page: description, screenshots and resources](docs/screenshots/detail.png)

**Launching.** You see the live `docker pull` or build output with a progress bar (bytes and layers for pulls, packages for builds). The script checks that the desktop actually answers before it hands you the links.

**Manager.** Every desktop gets a card showing:

- live CPU, memory and network,
- its local and public links, plus the sign-in (hidden until you reveal it),
- its limits, with an Edit button,
- Open, Shell and Stop. Shell opens a real terminal inside the card.

The card's menu has restart, public link on or off, container logs, limits and remove.

![The manager](docs/screenshots/manager.png)

**Lite mode** turns off blur and animation. It switches itself on for devices with 2 cores or 2 GB of memory or less.

### Terminal only

Everything the web UI does for launching and managing is also in the menu. To launch straight from the shell, find an ID with `--list` and run:

```bash
bash docker.sh --launch webtop-ubuntu-xfce
```

## Options

These work with the script and with `selkies-cli` alike.

| Option | What it does |
|---|---|
| *(none)* | Home screen: status plus suggestions |
| `--webui`, `-w` | Straight to the web UI (asks background or foreground) |
| `--bg` / `--fg` | Web UI in the background, or held in the foreground until Ctrl-C |
| `--stop` | Stop a web UI running in the background |
| `--restart` | Restart the web UI on the same address |
| `--status` | Print the status of the web UI and desktops |
| `--open` | Print the web UI's link and open it if a browser is available |
| `--setup` | Install everything and the `selkies-cli` command, then exit |
| `--update` | Install the latest version from GitHub |
| `--cli`, `-c` | Straight to the hand picked list |
| `--smart`, `-s` | Let it choose for this machine |
| `--manager`, `-m` | Manage running desktops |
| `--launch ID` | Launch one desktop and exit |
| `--list`, `-l` | Print the catalog with IDs |
| `--doctor` | Check this machine |
| `--port N` | Web UI port (default 8787) |
| `--expose` | Serve the web UI beyond localhost, behind a token (see Security) |
| `--no-tunnel` | Don't open a public link |
| `--yes`, `-y` | Accept the install prompts for Python and Docker |
| `--uninstall` | Remove everything the script created |
| `--help`, `-h` | Show usage |

## The catalog

| Kind | Count | How it starts |
|---|---|---|
| LinuxServer Webtop images | 19 | Prebuilt, so it only pulls |
| Kasm Workspaces images | 20 | Prebuilt (5 are x86_64 only) |
| Distro and desktop combinations | 105 | Built on this machine from a Selkies base: Ubuntu 24.04, Debian 12, Kali, Fedora 42, Arch or Alpine 3.21 |
| Curated looks | 14 | Built here, themed: Aurora, Spearmint, Cupertino Clean, Dragonfire, Ricer i3, Featherweight and more |

The *-style* and *-like* entries (Mint-style, Zorin-style, Mac-like, Windows-like and so on) are themes on top of Ubuntu, Debian or Arch, not the real distributions.

## Good to know

**Public links.** Links come from [serveo](https://serveo.net), which is free and anonymous. The address changes every time a link is opened, including after a restart. Kasm images serve HTTPS, so they get a TCP link instead, which serveo limits to about 10 minutes and 2 connections. Without sign-in, anyone with the link can use the desktop.

**Sign-in.** Turning on sign-in puts a username and password in front of the desktop. Kasm images always ask for a password, and their username is `kasm_user`. The manager can show the password if you forget it.

**Auto-start.** Desktops only run when you start them. You can turn auto-start on per desktop so it comes back after a reboot. Desktops made by older versions of the script always restarted, so the menu offers once to switch that off.

**Changing limits.** Memory, CPU and auto-start change instantly. Docker can't change shared memory or storage on a running container, so those recreate it on the same image, ports and password. Your files in `/config` are kept.

**Storage.** The storage budget is a hard limit only where Docker supports one (overlay2 on xfs with project quotas, btrfs, devicemapper, zfs). On the common ext4 setup it is recorded and shown, not enforced.

**Your files.** Each desktop's home folder is a Docker volume named `forge-config-<name>`. Removing a desktop keeps that volume unless you choose to delete it.

**First boot.** A new desktop can take a minute or two to come up, and heavy ones longer.

## Files

Everything lives in `~/.selkies-forge`. Set `FORGE_HOME` to use a different folder.

```
~/.selkies-forge/
├── app/      the engine, the web UI and the selkies-cli front end
├── state/    instances, reserved ports, web UI pid
├── logs/     launch, tunnel and web UI logs
└── builds/   Dockerfiles for desktops built on this machine

~/.local/bin/selkies-cli   a small wrapper that runs app/selkies-cli
```

## Security

- The web UI listens on `127.0.0.1` only. `--expose` makes it listen on all interfaces and requires a token in the URL. Anyone who has that URL can control Docker on this machine.
- These desktops come with passwordless `sudo` inside the container. A public link without sign-in hands that to anyone who has the link.
- The script only connects to:
  - container registries (`lscr.io`, `ghcr.io`, Docker Hub),
  - `get.docker.com`, only if it installs Docker,
  - `serveo.net`, only when you open a public link,
  - `raw.githubusercontent.com`, every 5 minutes to check for updates (turn off with `FORGE_AUTO_UPDATE=0`).

  Your browser loads screenshots from `upload.wikimedia.org`. There is no telemetry.

## Uninstall

```bash
selkies-cli uninstall
```

This removes every desktop the script created, the `~/.selkies-forge` folder, the `selkies-cli` command and any `PATH` lines it added to your shell profiles. It asks before also deleting the images and data volumes. Docker and Python stay installed.

## Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied` on the Docker socket | `sudo usermod -aG docker $USER`, then log out and back in (or run `newgrp docker`) |
| "has no arm64 image" | Pick an entry whose badge lists your architecture |
| The desktop never answers | Heavy desktops are slow on first boot. Open its logs from the manager. |
| A built desktop fails | The log names the package that broke; try the same desktop on another distro |
| No public link | serveo sometimes refuses or rate-limits. The local link still works; retry from the manager menu. |
| `selkies-cli: command not found` | Open a new terminal (the `PATH` change only reaches new shells), or run `~/.local/bin/selkies-cli` |
| The web UI says it "stopped unexpectedly" | `selkies-cli`, then "Show why it stopped" to see its log, then "Start the web UI again" |
| Anything else | Run `selkies-cli doctor` |

## Credits

- [LinuxServer.io](https://www.linuxserver.io/) for `baseimage-selkies` and the Webtop images, and the [Selkies](https://github.com/selkies-project/selkies) project for the streaming
- [Kasm Technologies](https://www.kasmweb.com/) for the Kasm Workspaces images
- [Simple Icons](https://simpleicons.org/) for the distro logos (CC0). The trademarks belong to their owners.
- [Wikipedia](https://en.wikipedia.org/) for the descriptions (CC BY-SA 4.0) and [Wikimedia Commons](https://commons.wikimedia.org/) for the screenshots. Each image is under its own licence, linked from the image viewer.
- [serveo](https://serveo.net) for the public links

## Tested on

Raspberry Pi (aarch64) with Ubuntu 24.04.5, Docker 29.8 and Python 3.12. Seven desktops were launched end to end during development, both prebuilt and built locally. Not every one of the 158 has been launched, so if a built one fails, its log says which package caused it.
