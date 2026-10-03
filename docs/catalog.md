# The catalog

> Generated from `.source/src/forge/catalog.py` by `.source/tools/gen_catalog_doc.py`.
> Edit the catalog, then run the tool; do not edit this page by hand.

Selkies Forge knows **153 desktops**: 19 ready-made LinuxServer Webtops, 20 Kasm Workspaces, 100 distro × desktop combinations built on your machine, and 14 curated looks.
148 of them run on arm64 (Raspberry Pi and other ARM boards); all of them run on x86_64.

| Column | Meaning |
|---|---|
| **Kind** | *pull*: a prebuilt image, only downloaded. *build*: a Selkies base image plus the desktop's packages, built on your machine the first time. |
| **Screen** | *fit*: the desktop follows your browser window (on a 4K screen, scaled up from about 1920 wide). *fixed*: it runs at 1920×1080 and Selkies scales it into your window (desktops that misdraw when the screen changes size). Changeable per desktop. [More](forge-layer.md#screen-modes) |
| **RAM** | the floor it needs, then the comfortable amount the planner aims for |
| **Download** | compressed download for a first launch |

## Contents

- [Ready to run: LinuxServer Webtop](#ready-to-run-linuxserver-webtop)
- [Ready to run: Kasm Workspaces](#ready-to-run-kasm-workspaces)
- [Curated looks](#curated-looks)
- [Built on Ubuntu 24.04 LTS (Noble Numbat)](#built-on-ubuntu-2404-lts-noble-numbat)
- [Built on Debian 12 (Bookworm)](#built-on-debian-12-bookworm)
- [Built on Kali Linux (Rolling)](#built-on-kali-linux-rolling)
- [Built on Fedora 42 (Adams)](#built-on-fedora-42-adams)
- [Built on Arch Linux (Rolling)](#built-on-arch-linux-rolling)
- [Built on Alpine 3.21 (musl)](#built-on-alpine-321-musl)

## Ready to run: LinuxServer Webtop

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Alpine MATE | `webtop-alpine-mate` | MATE | pull | fit | 0.9 GB → 1.8 GB | 0.9 GB | x86_64 · arm64 |
| Alpine i3 | `webtop-alpine-i3` | i3 | pull | fit | 0.6 GB → 1.2 GB | 0.7 GB | x86_64 · arm64 |
| Arch Linux KDE Plasma | `webtop-arch-kde` | KDE Plasma | pull | fit | 1.2 GB → 2.5 GB | 1.7 GB | x86_64 · arm64 |
| Arch Linux MATE | `webtop-arch-mate` | MATE | pull | fit | 0.9 GB → 1.8 GB | 1.5 GB | x86_64 · arm64 |
| Arch Linux Xfce 4 | `webtop-arch-xfce` | Xfce 4 | pull | fit | 0.8 GB → 1.5 GB | 1.4 GB | x86_64 · arm64 |
| Arch Linux i3 | `webtop-arch-i3` | i3 | pull | fit | 0.6 GB → 1.2 GB | 1.2 GB | x86_64 · arm64 |
| Debian KDE Plasma | `webtop-debian-kde` | KDE Plasma | pull | fit | 1.2 GB → 2.5 GB | 1.6 GB | x86_64 · arm64 |
| Debian MATE | `webtop-debian-mate` | MATE | pull | fit | 0.9 GB → 1.8 GB | 1.3 GB | x86_64 · arm64 |
| Debian Xfce 4 | `webtop-debian-xfce` | Xfce 4 | pull | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Debian i3 | `webtop-debian-i3` | i3 | pull | fit | 0.6 GB → 1.2 GB | 1.0 GB | x86_64 · arm64 |
| Fedora KDE Plasma | `webtop-fedora-kde` | KDE Plasma | pull | fit | 1.2 GB → 2.5 GB | 1.6 GB | x86_64 · arm64 |
| Fedora MATE | `webtop-fedora-mate` | MATE | pull | fit | 0.9 GB → 1.8 GB | 1.3 GB | x86_64 · arm64 |
| Fedora Xfce 4 | `webtop-fedora-xfce` | Xfce 4 | pull | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |
| Fedora i3 | `webtop-fedora-i3` | i3 | pull | fit | 0.6 GB → 1.2 GB | 1.0 GB | x86_64 · arm64 |
| Ubuntu 24.04 KDE Plasma | `webtop-ubuntu-kde` | KDE Plasma | pull | fit | 1.2 GB → 2.5 GB | 1.6 GB | x86_64 · arm64 |
| Ubuntu 24.04 LXQt | `webtop-ubuntu-lxqt` | LXQt | pull | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 MATE | `webtop-ubuntu-mate` | MATE | pull | fit | 0.9 GB → 1.8 GB | 1.4 GB | x86_64 · arm64 |
| Ubuntu 24.04 Xfce 4 | `webtop-ubuntu-xfce` | Xfce 4 | pull | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 i3 | `webtop-ubuntu-i3` | i3 | pull | fit | 0.6 GB → 1.2 GB | 1.0 GB | x86_64 · arm64 |

## Ready to run: Kasm Workspaces

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| AlmaLinux 8 | `kasm-almalinux-8` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| AlmaLinux 9 | `kasm-almalinux-9` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| Alpine 3.17 | `kasm-alpine-317` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 1.2 GB | x86_64 · arm64 |
| CentOS 7 | `kasm-centos-7` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.1 GB | x86_64 |
| Debian 11 | `kasm-debian-bullseye` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.2 GB | x86_64 · arm64 |
| Fedora 37 | `kasm-fedora-37` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.3 GB | x86_64 · arm64 |
| Kali Rolling | `kasm-kali-rolling` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.5 GB | x86_64 · arm64 |
| Trace Labs OSINT | `kasm-tracelabs` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 3.1 GB | x86_64 |
| openSUSE Leap 15 | `kasm-opensuse-15` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.3 GB | x86_64 · arm64 |
| Oracle Linux 7 | `kasm-oracle-7` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.1 GB | x86_64 |
| Oracle Linux 8 | `kasm-oracle-8` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| Oracle Linux 9 | `kasm-oracle-9` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| Parrot OS 5 | `kasm-parrotos-5` | MATE | pull | browser | 1.0 GB → 2.0 GB | 2.7 GB | x86_64 · arm64 |
| REMnux | `kasm-remnux-focal` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 4.1 GB | x86_64 |
| Rocky Linux 8 | `kasm-rockylinux-8` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| Rocky Linux 9 | `kasm-rockylinux-9` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.4 GB | x86_64 · arm64 |
| Kasm Deluxe | `kasm-desktop-deluxe` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 3.5 GB | x86_64 |
| Ubuntu 18.04 | `kasm-ubuntu-bionic` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.1 GB | x86_64 · arm64 |
| Ubuntu 20.04 | `kasm-ubuntu-focal` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.2 GB | x86_64 · arm64 |
| Ubuntu 22.04 | `kasm-ubuntu-jammy` | Xfce 4 | pull | browser | 1.0 GB → 2.0 GB | 2.3 GB | x86_64 · arm64 |

## Curated looks

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Featherweight | `featherweight` | dwm | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Ricer i3 | `ricer-i3` | i3 | build | fit | 0.6 GB → 1.2 GB | 1.4 GB | x86_64 · arm64 |
| Ricer bspwm | `ricer-bspwm` | bspwm | build | fit | 0.6 GB → 1.2 GB | 1.2 GB | x86_64 · arm64 |
| Pantheon Lite | `elementary-ish` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |
| Dragonfire | `dragonfire` | KDE Plasma | build | fit | 1.2 GB → 2.5 GB | 2.0 GB | x86_64 · arm64 |
| Cupertino Clean | `cupertino` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |
| Redmond Classic | `redmond` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |
| Spearmint | `mintish-cinnamon` | Cinnamon | build | fixed | 1.1 GB → 2.2 GB | 1.4 GB | x86_64 · arm64 |
| Spearmint MATE | `mintish-mate` | MATE | build | fit | 0.9 GB → 1.8 GB | 1.2 GB | x86_64 · arm64 |
| Spearmint Xfce | `mintish-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Nightjar | `parrotish` | MATE | build | fit | 0.9 GB → 1.8 GB | 1.5 GB | x86_64 · arm64 |
| Nebula | `nebula-flashback` | GNOME Flashback | build | fixed | 0.9 GB → 1.8 GB | 1.3 GB | x86_64 · arm64 |
| Workbench | `workbench` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.6 GB | x86_64 · arm64 |
| Aurora | `aurora-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |

## Built on Ubuntu 24.04 LTS (Noble Numbat)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Ubuntu 24.04 LTS Budgie | `noble-budgie` | Budgie | build | fixed | 1.0 GB → 2.0 GB | 1.3 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Cinnamon | `noble-cinnamon` | Cinnamon | build | fixed | 1.0 GB → 2.0 GB | 1.3 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Enlightenment | `noble-enlightenment` | Enlightenment | build | fixed | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS FVWM3 | `noble-fvwm3` | FVWM3 | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Fluxbox | `noble-fluxbox` | Fluxbox | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS GNOME Flashback | `noble-gnome-flashback` | GNOME Flashback | build | fixed | 0.9 GB → 1.8 GB | 1.2 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS IceWM | `noble-icewm` | IceWM | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS JWM | `noble-jwm` | JWM | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS KDE Plasma | `noble-kde` | KDE Plasma | build | fit | 1.1 GB → 2.2 GB | 1.5 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS LXDE | `noble-lxde` | LXDE | build | fit | 0.6 GB → 1.2 GB | 1.0 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS LXQt | `noble-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS MATE | `noble-mate` | MATE | build | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Openbox | `noble-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS UKUI | `noble-ukui` | UKUI | build | fixed | 0.9 GB → 1.8 GB | 1.2 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Window Maker | `noble-wmaker` | Window Maker | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS Xfce 4 | `noble-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS awesome | `noble-awesome` | awesome | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS bspwm | `noble-bspwm` | bspwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS herbstluftwm | `noble-herbstluftwm` | herbstluftwm | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS i3 | `noble-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS pekwm | `noble-pekwm` | pekwm | build | fit | 0.5 GB → 1.0 GB | 0.9 GB | x86_64 · arm64 |
| Ubuntu 24.04 LTS xmonad | `noble-xmonad` | xmonad | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |

## Built on Debian 12 (Bookworm)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Debian 12 Budgie | `bookworm-budgie` | Budgie | build | fixed | 1.0 GB → 2.0 GB | 1.3 GB | x86_64 · arm64 |
| Debian 12 Cinnamon | `bookworm-cinnamon` | Cinnamon | build | fixed | 1.0 GB → 2.0 GB | 1.4 GB | x86_64 · arm64 |
| Debian 12 Enlightenment | `bookworm-enlightenment` | Enlightenment | build | fixed | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Debian 12 FVWM3 | `bookworm-fvwm3` | FVWM3 | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 Fluxbox | `bookworm-fluxbox` | Fluxbox | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 GNOME Flashback | `bookworm-gnome-flashback` | GNOME Flashback | build | fixed | 0.9 GB → 1.8 GB | 1.3 GB | x86_64 · arm64 |
| Debian 12 IceWM | `bookworm-icewm` | IceWM | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 JWM | `bookworm-jwm` | JWM | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 KDE Plasma | `bookworm-kde` | KDE Plasma | build | fit | 1.1 GB → 2.2 GB | 1.5 GB | x86_64 · arm64 |
| Debian 12 LXDE | `bookworm-lxde` | LXDE | build | fit | 0.6 GB → 1.2 GB | 1.1 GB | x86_64 · arm64 |
| Debian 12 LXQt | `bookworm-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 1.1 GB | x86_64 · arm64 |
| Debian 12 MATE | `bookworm-mate` | MATE | build | fit | 0.8 GB → 1.5 GB | 1.2 GB | x86_64 · arm64 |
| Debian 12 Openbox | `bookworm-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 Window Maker | `bookworm-wmaker` | Window Maker | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 Xfce 4 | `bookworm-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.1 GB | x86_64 · arm64 |
| Debian 12 awesome | `bookworm-awesome` | awesome | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 bspwm | `bookworm-bspwm` | bspwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 cwm | `bookworm-cwm` | cwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 dwm | `bookworm-dwm` | dwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 herbstluftwm | `bookworm-herbstluftwm` | herbstluftwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 i3 | `bookworm-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 pekwm | `bookworm-pekwm` | pekwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 ratpoison | `bookworm-ratpoison` | ratpoison | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 spectrwm | `bookworm-spectrwm` | spectrwm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 twm | `bookworm-twm` | twm | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |
| Debian 12 xmonad | `bookworm-xmonad` | xmonad | build | fit | 0.5 GB → 1.0 GB | 1.0 GB | x86_64 · arm64 |

## Built on Kali Linux (Rolling)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Kali Linux GNOME Flashback | `kali-gnome-flashback` | GNOME Flashback | build | fixed | 0.9 GB → 1.8 GB | 1.6 GB | x86_64 · arm64 |
| Kali Linux KDE Plasma | `kali-kde` | KDE Plasma | build | fit | 1.1 GB → 2.2 GB | 1.9 GB | x86_64 · arm64 |
| Kali Linux LXQt | `kali-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 1.5 GB | x86_64 · arm64 |
| Kali Linux Openbox | `kali-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 1.4 GB | x86_64 · arm64 |
| Kali Linux Xfce 4 | `kali-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.5 GB | x86_64 · arm64 |
| Kali Linux i3 | `kali-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 1.4 GB | x86_64 · arm64 |

## Built on Fedora 42 (Adams)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Fedora 42 Budgie | `fedora42-budgie` | Budgie | build | fixed | 1.0 GB → 2.0 GB | 1.2 GB | x86_64 · arm64 |
| Fedora 42 Cinnamon | `fedora42-cinnamon` | Cinnamon | build | fixed | 1.0 GB → 2.0 GB | 1.2 GB | x86_64 · arm64 |
| Fedora 42 Enlightenment | `fedora42-enlightenment` | Enlightenment | build | fixed | 0.8 GB → 1.5 GB | 1.0 GB | x86_64 · arm64 |
| Fedora 42 Fluxbox | `fedora42-fluxbox` | Fluxbox | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 IceWM | `fedora42-icewm` | IceWM | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 KDE Plasma | `fedora42-kde` | KDE Plasma | build | fit | 1.1 GB → 2.2 GB | 1.3 GB | x86_64 · arm64 |
| Fedora 42 LXDE | `fedora42-lxde` | LXDE | build | fit | 0.6 GB → 1.2 GB | 0.9 GB | x86_64 · arm64 |
| Fedora 42 LXQt | `fedora42-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 0.9 GB | x86_64 · arm64 |
| Fedora 42 MATE | `fedora42-mate` | MATE | build | fit | 0.8 GB → 1.5 GB | 1.0 GB | x86_64 · arm64 |
| Fedora 42 Openbox | `fedora42-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 Qtile | `fedora42-qtile` | Qtile | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 Xfce 4 | `fedora42-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.0 GB | x86_64 · arm64 |
| Fedora 42 awesome | `fedora42-awesome` | awesome | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 bspwm | `fedora42-bspwm` | bspwm | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |
| Fedora 42 i3 | `fedora42-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 0.8 GB | x86_64 · arm64 |

## Built on Arch Linux (Rolling)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Arch Linux Budgie | `arch-budgie` | Budgie | build | fixed | 1.0 GB → 2.0 GB | 1.6 GB | x86_64 · arm64 |
| Arch Linux Cinnamon | `arch-cinnamon` | Cinnamon | build | fixed | 1.0 GB → 2.0 GB | 1.6 GB | x86_64 · arm64 |
| Arch Linux Enlightenment | `arch-enlightenment` | Enlightenment | build | fixed | 0.8 GB → 1.5 GB | 1.4 GB | x86_64 · arm64 |
| Arch Linux Fluxbox | `arch-fluxbox` | Fluxbox | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux IceWM | `arch-icewm` | IceWM | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux JWM | `arch-jwm` | JWM | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux KDE Plasma | `arch-kde` | KDE Plasma | build | fit | 1.1 GB → 2.2 GB | 1.8 GB | x86_64 · arm64 |
| Arch Linux LXDE | `arch-lxde` | LXDE | build | fit | 0.6 GB → 1.2 GB | 1.3 GB | x86_64 · arm64 |
| Arch Linux LXQt | `arch-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 1.4 GB | x86_64 · arm64 |
| Arch Linux MATE | `arch-mate` | MATE | build | fit | 0.8 GB → 1.5 GB | 1.4 GB | x86_64 · arm64 |
| Arch Linux Openbox | `arch-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux Qtile | `arch-qtile` | Qtile | build | fit | 0.5 GB → 1.0 GB | 1.3 GB | x86_64 · arm64 |
| Arch Linux Window Maker | `arch-wmaker` | Window Maker | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux Xfce 4 | `arch-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 1.4 GB | x86_64 · arm64 |
| Arch Linux awesome | `arch-awesome` | awesome | build | fit | 0.5 GB → 1.0 GB | 1.3 GB | x86_64 · arm64 |
| Arch Linux bspwm | `arch-bspwm` | bspwm | build | fit | 0.5 GB → 1.0 GB | 1.3 GB | x86_64 · arm64 |
| Arch Linux herbstluftwm | `arch-herbstluftwm` | herbstluftwm | build | fit | 0.5 GB → 1.0 GB | 1.2 GB | x86_64 · arm64 |
| Arch Linux i3 | `arch-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 1.3 GB | x86_64 · arm64 |

## Built on Alpine 3.21 (musl)

| Desktop | ID | Desktop env. | Kind | Screen | RAM | Download | Runs on |
|---|---|---|---|---|---|---|---|
| Alpine 3.21 Fluxbox | `alpine321-fluxbox` | Fluxbox | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 IceWM | `alpine321-icewm` | IceWM | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 JWM | `alpine321-jwm` | JWM | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 LXQt | `alpine321-lxqt` | LXQt | build | fit | 0.6 GB → 1.2 GB | 0.6 GB | x86_64 · arm64 |
| Alpine 3.21 MATE | `alpine321-mate` | MATE | build | fit | 0.8 GB → 1.5 GB | 0.7 GB | x86_64 · arm64 |
| Alpine 3.21 Openbox | `alpine321-openbox` | Openbox | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 Xfce 4 | `alpine321-xfce` | Xfce 4 | build | fit | 0.8 GB → 1.5 GB | 0.6 GB | x86_64 · arm64 |
| Alpine 3.21 awesome | `alpine321-awesome` | awesome | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 bspwm | `alpine321-bspwm` | bspwm | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 dwm | `alpine321-dwm` | dwm | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 herbstluftwm | `alpine321-herbstluftwm` | herbstluftwm | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 i3 | `alpine321-i3` | i3 | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |
| Alpine 3.21 spectrwm | `alpine321-spectrwm` | spectrwm | build | fit | 0.5 GB → 1.0 GB | 0.5 GB | x86_64 · arm64 |

## Desktop environments

| Desktop | Weight | Idle RAM | Screen | Available on |
|---|---|---|---|---|
| awesome | feather | ~115 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux, Alpine 3.21 |
| bspwm | feather | ~105 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux, Alpine 3.21 |
| Budgie | full | ~560 MB | fixed | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux |
| Cinnamon | full | ~620 MB | fixed | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux |
| cwm | feather | ~40 MB | fit | Debian 12 |
| dwm | feather | ~45 MB | fit | Debian 12, Alpine 3.21 |
| Enlightenment | light | ~300 MB | fixed | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux |
| Fluxbox | feather | ~100 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux, Alpine 3.21 |
| FVWM3 | feather | ~75 MB | fit | Ubuntu 24.04 LTS, Debian 12 |
| GNOME Flashback | balanced | ~470 MB | fixed | Ubuntu 24.04 LTS, Debian 12, Kali Linux |
| herbstluftwm | feather | ~95 MB | fit | Ubuntu 24.04 LTS, Debian 12, Arch Linux, Alpine 3.21 |
| i3 | feather | ~120 MB | fit | Ubuntu 24.04 LTS, Debian 12, Kali Linux, Fedora 42, Arch Linux, Alpine 3.21 |
| IceWM | feather | ~85 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux, Alpine 3.21 |
| JWM | feather | ~70 MB | fit | Ubuntu 24.04 LTS, Debian 12, Arch Linux, Alpine 3.21 |
| KDE Plasma | heavy | ~760 MB | fit | Ubuntu 24.04 LTS, Debian 12, Kali Linux, Fedora 42, Arch Linux |
| LXDE | feather | ~200 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux |
| LXQt | light | ~250 MB | fit | Ubuntu 24.04 LTS, Debian 12, Kali Linux, Fedora 42, Arch Linux, Alpine 3.21 |
| MATE | light | ~380 MB | fit | Ubuntu 24.04 LTS, Debian 12, Fedora 42, Arch Linux, Alpine 3.21 |
| Openbox | feather | ~110 MB | fit | Ubuntu 24.04 LTS, Debian 12, Kali Linux, Fedora 42, Arch Linux, Alpine 3.21 |
| pekwm | feather | ~80 MB | fit | Ubuntu 24.04 LTS, Debian 12 |
| Qtile | feather | ~130 MB | fit | Fedora 42, Arch Linux |
| ratpoison | feather | ~35 MB | fit | Debian 12 |
| spectrwm | feather | ~60 MB | fit | Debian 12, Alpine 3.21 |
| twm | feather | ~30 MB | fit | Debian 12 |
| UKUI | balanced | ~430 MB | fixed | Ubuntu 24.04 LTS |
| Window Maker | feather | ~85 MB | fit | Ubuntu 24.04 LTS, Debian 12, Arch Linux |
| Xfce 4 | light | ~330 MB | fit | Ubuntu 24.04 LTS, Debian 12, Kali Linux, Fedora 42, Arch Linux, Alpine 3.21 |
| xmonad | feather | ~100 MB | fit | Ubuntu 24.04 LTS, Debian 12 |
