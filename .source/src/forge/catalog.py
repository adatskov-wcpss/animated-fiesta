"""
Selkies Forge - distro catalog.

Every entry is one launchable desktop. Three kinds:

  pull   ready-made image, we just docker pull it
  build  a Selkies base image + a desktop recipe, we docker build it

Sizes are measured from the real registry manifests (compressed download),
disk is the uncompressed on-disk cost. Numbers were sampled on 2026-10-02.
"""

BOTH = ("amd64", "arm64")
X86 = ("amd64",)

# Compressed -> on-disk expansion factor, measured against the real images.
EXPAND = 2.85

# --------------------------------------------------------------------------
# Desktops.  klass: feather < light < balanced < full < heavy
#   idle   : approximate idle RSS of the session, MB
#   add_dl : extra compressed download on top of the base image, MB
#   beauty : how pretty it looks out of the box, 0-100
#   speed  : how snappy it feels over a stream, 0-100
# --------------------------------------------------------------------------
DESKTOPS = {
    "xfce": dict(
        label="Xfce 4", glyph="xfce", klass="light", idle=330, add_dl=230,
        beauty=76, speed=86, term="xfce4-terminal",
        blurb="The dependable one. Fast, tidy, endlessly configurable.",
        apt=dict(pkgs="xfce4 xfce4-terminal xfce4-goodies thunar mousepad "
                      "xfce4-taskmanager libxfce4ui-utils", session="xfce4-session"),
        dnf=dict(pkgs="xfce4-session xfce4-panel xfdesktop xfwm4 xfwm4-themes xfce4-terminal "
                      "Thunar xfce4-settings xfconf xfce4-appfinder mousepad",
                 session="xfce4-session"),
        pacman=dict(pkgs="xfce4 xfce4-goodies", session="xfce4-session"),
        apk=dict(pkgs="xfce4 xfce4-terminal thunar mousepad",
                 session="xfce4-session"),
    ),
    "mate": dict(
        label="MATE", glyph="mate", klass="light", idle=380, add_dl=300,
        beauty=74, speed=82, term="mate-terminal",
        blurb="GNOME 2 kept alive and kept sane. Traditional and warm.",
        apt=dict(pkgs="mate-desktop-environment mate-terminal", session="mate-session"),
        dnf=dict(pkgs="mate-session-manager mate-panel marco caja mate-terminal "
                      "mate-control-center mate-settings-daemon mate-themes",
                 session="mate-session"),
        pacman=dict(pkgs="mate mate-extra", session="mate-session"),
        apk=dict(pkgs="mate-session-manager mate-panel marco caja mate-terminal "
                      "mate-settings-daemon mate-control-center mate-themes",
                 session="mate-session"),
    ),
    "kde": dict(
        label="KDE Plasma", glyph="kde", klass="heavy", idle=760, add_dl=620,
        beauty=94, speed=58, term="konsole",
        blurb="Maximalist and gorgeous. Every knob you could want, twice.",
        # kwin-x11 is only a Recommends, and --no-install-recommends drops it:
        # Plasma then starts with no window manager at all.
        apt=dict(pkgs="kde-plasma-desktop kwin-x11 konsole dolphin kate",
                 session="startplasma-x11",
                 pre=['for kw in kwriteconfig6 kwriteconfig5; do command -v $kw >/dev/null && break; done; '
                      '[ -f "$HOME/.config/kwinrc" ] || $kw --file "$HOME/.config/kwinrc" '
                      '--group Compositing --key Enabled false 2>/dev/null || true',
                      '[ -f "$HOME/.config/kscreenlockerrc" ] || $kw --file '
                      '"$HOME/.config/kscreenlockerrc" --group Daemon --key Autolock false '
                      '2>/dev/null || true',
                      'touch "$HOME/.local/share/user-places.xbel" 2>/dev/null || true']),
        dnf=dict(pkgs="plasma-desktop plasma-workspace-x11 konsole dolphin kwin-x11 "
                      "plasma-nm breeze-gtk", session="startplasma-x11"),
        # Plasma 6.4 split the X11 window manager out into kwin-x11.
        pacman=dict(pkgs="plasma-desktop plasma-workspace plasma-x11-session konsole dolphin kwin kwin-x11",
                    session="startplasma-x11"),
    ),
    "lxqt": dict(
        label="LXQt", glyph="lxqt", klass="light", idle=250, add_dl=210,
        beauty=70, speed=90, term="qterminal",
        blurb="Qt, but featherlight. Clean lines, almost no weight.",
        apt=dict(pkgs="lxqt-core qterminal openbox pcmanfm-qt",
                 session="lxqt-session -w /usr/bin/openbox-session",
                 env=["XDG_CURRENT_DESKTOP=LXQt"]),
        dnf=dict(pkgs="lxqt-session lxqt-panel lxqt-runner pcmanfm-qt qterminal openbox "
                      "lxqt-config", session="lxqt-session -w /usr/bin/openbox-session",
                 env=["XDG_CURRENT_DESKTOP=LXQt"]),
        pacman=dict(pkgs="lxqt openbox qterminal breeze-icons",
                    session="lxqt-session -w /usr/bin/openbox-session",
                    env=["XDG_CURRENT_DESKTOP=LXQt"]),
        apk=dict(pkgs="lxqt-session lxqt-panel lxqt-runner pcmanfm-qt qterminal openbox "
                      "lxqt-config adwaita-icon-theme",
                 session="lxqt-session -w /usr/bin/openbox-session",
                 env=["XDG_CURRENT_DESKTOP=LXQt"]),
    ),
    "lxde": dict(
        label="LXDE", glyph="lxde", klass="feather", idle=200, add_dl=170,
        beauty=58, speed=94, term="lxterminal",
        blurb="The old reliable netbook desktop. Starts before you blink.",
        apt=dict(pkgs="lxde-core lxterminal pcmanfm openbox", session="startlxde"),
        dnf=dict(pkgs="lxde-common lxpanel pcmanfm lxterminal openbox lxsession lxappearance",
                 session="startlxde"),
        pacman=dict(pkgs="lxde-common lxpanel pcmanfm lxterminal openbox lxsession",
                    session="startlxde"),
    ),
    "cinnamon": dict(
        label="Cinnamon", glyph="cinnamon", klass="full", idle=620, add_dl=480,
        beauty=90, speed=66, term="gnome-terminal", display="fixed",
        blurb="Polished, modern, familiar. Mint's calling card.",
        apt=dict(pkgs="cinnamon-core gnome-terminal nemo",
                 session="sh -c 'cinnamon-session-cinnamon2d || cinnamon-session'"),
        dnf=dict(pkgs="cinnamon cinnamon-control-center nemo gnome-terminal",
                 session="sh -c 'cinnamon-session-cinnamon2d || cinnamon-session'"),
        pacman=dict(pkgs="cinnamon nemo gnome-terminal xed",
                    session="sh -c 'cinnamon-session-cinnamon2d || cinnamon-session'"),
    ),
    "budgie": dict(
        label="Budgie", glyph="budgie", klass="full", idle=560, add_dl=450,
        beauty=91, speed=70, term="gnome-terminal", display="fixed",
        blurb="Opinionated and elegant. Raven sidebar, no clutter.",
        apt=dict(pkgs="budgie-desktop budgie-indicator-applet gnome-terminal nautilus",
                 session="budgie-desktop"),
        dnf=dict(pkgs="budgie-desktop budgie-control-center gnome-terminal nautilus",
                 session="budgie-desktop"),
        pacman=dict(pkgs="budgie-desktop budgie-control-center gnome-terminal nautilus",
                    session="budgie-desktop"),
    ),
    "gnome-flashback": dict(
        label="GNOME Flashback", glyph="gnome", klass="balanced", idle=470, add_dl=390,
        beauty=80, speed=74, term="gnome-terminal", display="fixed",
        blurb="GNOME's classic layout on Metacity. Works where real GNOME can't.",
        apt=dict(pkgs="gnome-session-flashback gnome-terminal nautilus metacity",
                 session="gnome-session --session=gnome-flashback-metacity"),
    ),
    "enlightenment": dict(
        label="Enlightenment", glyph="enlightenment", klass="light", idle=300, add_dl=240,
        beauty=82, speed=84, term="terminology", display="fixed",
        blurb="Animated, glossy, unlike anything else. A cult favourite.",
        apt=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
        dnf=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
        pacman=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
    ),
    "i3": dict(
        label="i3", glyph="i3", klass="feather", idle=120, add_dl=120,
        beauty=68, speed=98, term="xterm", bare=True,
        blurb="Tiling, keyboard-driven, ruthlessly efficient.",
        apt=dict(pkgs="i3 i3status i3lock suckless-tools rofi xterm feh", session="i3"),
        dnf=dict(pkgs="i3 i3status i3lock dmenu rofi xterm feh", session="i3"),
        pacman=dict(pkgs="i3-wm i3status i3lock dmenu rofi xterm feh", session="i3"),
        apk=dict(pkgs="i3wm i3status i3lock dmenu xterm feh", session="i3"),
    ),
    "openbox": dict(
        label="Openbox", glyph="openbox", klass="feather", idle=110, add_dl=100,
        beauty=60, speed=98, term="xterm", bare=True,
        blurb="A window manager and nothing else. Yours to decorate.",
        apt=dict(pkgs="openbox obconf tint2 xterm feh lxappearance",
                 session="openbox-session"),
        dnf=dict(pkgs="openbox xterm feh", session="openbox-session"),
        pacman=dict(pkgs="openbox tint2 xterm feh", session="openbox-session"),
        apk=dict(pkgs="openbox tint2 xterm feh", session="openbox-session"),
    ),
    "fluxbox": dict(
        label="Fluxbox", glyph="fluxbox", klass="feather", idle=100, add_dl=95,
        beauty=57, speed=98, term="xterm", bare=True,
        blurb="Blackbox's heir. Tabs, slit, and almost zero RAM.",
        apt=dict(pkgs="fluxbox xterm feh", session="startfluxbox"),
        dnf=dict(pkgs="fluxbox xterm feh", session="startfluxbox"),
        pacman=dict(pkgs="fluxbox xterm feh", session="startfluxbox"),
        apk=dict(pkgs="fluxbox xterm feh", session="startfluxbox"),
    ),
    "icewm": dict(
        label="IceWM", glyph="icewm", klass="feather", idle=85, add_dl=90,
        beauty=55, speed=99, term="xterm", bare=True,
        blurb="A taskbar, a menu, 20MB of RAM. It just works.",
        apt=dict(pkgs="icewm xterm feh", session="icewm-session"),
        dnf=dict(pkgs="icewm xterm feh", session="icewm-session"),
        pacman=dict(pkgs="icewm xterm feh", session="icewm-session"),
        apk=dict(pkgs="icewm xterm feh", session="icewm-session"),
    ),
    "jwm": dict(
        label="JWM", glyph="jwm", klass="feather", idle=70, add_dl=85,
        beauty=50, speed=99, term="xterm", bare=True,
        blurb="Joe's Window Manager. One config file, instant start.",
        apt=dict(pkgs="jwm xterm feh", session="jwm"),
        pacman=dict(pkgs="jwm xterm feh", session="jwm"),
        apk=dict(pkgs="jwm xterm feh", session="jwm"),
    ),
    "awesome": dict(
        label="awesome", glyph="awesome", klass="feather", idle=115, add_dl=110,
        beauty=72, speed=97, term="xterm", bare=True,
        blurb="Tiling driven by Lua. Scriptable down to the pixel.",
        apt=dict(pkgs="awesome awesome-extra xterm feh rofi", session="awesome"),
        dnf=dict(pkgs="awesome xterm feh rofi", session="awesome"),
        pacman=dict(pkgs="awesome xterm feh rofi", session="awesome"),
        apk=dict(pkgs="awesome xterm feh", session="awesome"),
    ),
    "bspwm": dict(
        label="bspwm", glyph="bspwm", klass="feather", idle=105, add_dl=105,
        beauty=74, speed=98, term="xterm", bare=True,
        blurb="Binary space partitioning. The ricer's blank canvas.",
        apt=dict(pkgs="bspwm sxhkd xterm feh rofi picom",
                 session="bspwm", pre=["sxhkd &"]),
        dnf=dict(pkgs="bspwm sxhkd xterm feh rofi picom",
                 session="bspwm", pre=["sxhkd &"]),
        pacman=dict(pkgs="bspwm sxhkd xterm feh rofi picom",
                    session="bspwm", pre=["sxhkd &"]),
        apk=dict(pkgs="bspwm sxhkd xterm feh", session="bspwm", pre=["sxhkd &"]),
    ),
    "herbstluftwm": dict(
        label="herbstluftwm", glyph="herbstluftwm", klass="feather", idle=95, add_dl=95,
        beauty=66, speed=98, term="xterm", bare=True,
        blurb="Manual tiling, driven entirely from the shell.",
        apt=dict(pkgs="herbstluftwm xterm feh suckless-tools", session="herbstluftwm"),
        pacman=dict(pkgs="herbstluftwm xterm feh dmenu", session="herbstluftwm"),
        apk=dict(pkgs="herbstluftwm xterm feh dmenu", session="herbstluftwm"),
    ),
    "qtile": dict(
        label="Qtile", glyph="qtile", klass="feather", idle=130, add_dl=120,
        beauty=73, speed=96, term="xterm", bare=True,
        blurb="Tiling written and configured in pure Python.",
        apt=dict(pkgs="qtile xterm feh rofi", session="qtile start"),
        dnf=dict(pkgs="qtile xterm feh rofi", session="qtile start"),
        pacman=dict(pkgs="qtile xterm feh rofi", session="qtile start"),
    ),
    "xmonad": dict(
        label="xmonad", glyph="xmonad", klass="feather", idle=100, add_dl=130,
        beauty=64, speed=98, term="xterm", bare=True,
        blurb="Haskell tiling. Mathematically tidy windows.",
        apt=dict(pkgs="xmonad xterm feh suckless-tools", session="xmonad"),
        pacman=dict(pkgs="xmonad xmonad-contrib xterm feh dmenu", session="xmonad"),
    ),
    "pekwm": dict(
        label="pekwm", glyph="pekwm", klass="feather", idle=80, add_dl=85,
        beauty=56, speed=99, term="xterm", bare=True,
        blurb="Tiny, themeable, window-grouping classic.",
        apt=dict(pkgs="pekwm xterm feh", session="pekwm"),
    ),
    "wmaker": dict(
        label="Window Maker", glyph="wmaker", klass="feather", idle=85, add_dl=95,
        beauty=63, speed=98, term="xterm", bare=True,
        blurb="NeXTSTEP, faithfully. Dock, clip, and all.",
        apt=dict(pkgs="wmaker xterm feh", session="wmaker"),
        pacman=dict(pkgs="windowmaker xterm feh", session="wmaker"),
    ),
    "fvwm3": dict(
        label="FVWM3", glyph="fvwm", klass="feather", idle=75, add_dl=90,
        beauty=52, speed=99, term="xterm", bare=True,
        blurb="Unix history you can still run. Infinitely scriptable.",
        apt=dict(pkgs="fvwm3 xterm feh", session="fvwm3"),
    ),
    "dwm": dict(
        label="dwm", glyph="dwm", klass="feather", idle=45, add_dl=80,
        beauty=48, speed=100, term="xterm", bare=True,
        blurb="Suckless tiling in 2000 lines. The absolute floor.",
        apt=dict(pkgs="dwm suckless-tools xterm", session="dwm"),
        apk=dict(pkgs="dwm xterm", session="dwm"),
    ),
    "spectrwm": dict(
        label="spectrwm", glyph="spectrwm", klass="feather", idle=60, add_dl=85,
        beauty=58, speed=99, term="xterm", bare=True,
        blurb="dwm's ideas with a readable config file.",
        apt=dict(pkgs="spectrwm xterm feh suckless-tools", session="spectrwm"),
        apk=dict(pkgs="spectrwm xterm dmenu", session="spectrwm"),
    ),
    "cwm": dict(
        label="cwm", glyph="cwm", klass="feather", idle=40, add_dl=78,
        beauty=44, speed=100, term="xterm", bare=True,
        blurb="OpenBSD's calm window manager. Keyboard first.",
        apt=dict(pkgs="cwm xterm", session="cwm"),
    ),
    "ratpoison": dict(
        label="ratpoison", glyph="ratpoison", klass="feather", idle=35, add_dl=76,
        beauty=38, speed=100, term="xterm", bare=True,
        blurb="No mouse. No decorations. Screen for your windows.",
        apt=dict(pkgs="ratpoison xterm", session="ratpoison"),
    ),
    "twm": dict(
        label="twm", glyph="twm", klass="feather", idle=30, add_dl=74,
        beauty=30, speed=100, term="xterm", bare=True,
        blurb="1987, unchanged. The original X window manager.",
        apt=dict(pkgs="twm xterm", session="twm"),
    ),
    "lumina": dict(
        label="Lumina", glyph="lumina", klass="light", idle=190, add_dl=165,
        beauty=64, speed=92, term="qterminal",
        blurb="BSD-born, Qt-based, refreshingly simple.",
        apt=dict(pkgs="lumina-desktop qterminal", session="start-lumina-desktop"),
    ),
    "ukui": dict(
        label="UKUI", glyph="ukui", klass="balanced", idle=430, add_dl=360,
        beauty=79, speed=73, term="mate-terminal", display="fixed",
        blurb="Kylin's desktop. A very deliberate Windows-like flow.",
        apt=dict(pkgs="ukui-session-manager ukui-panel ukui-settings-daemon peony "
                      "ukui-control-center mate-terminal", session="ukui-session"),
    ),
}

# --------------------------------------------------------------------------
# Selkies base images used for recipe builds.
# --------------------------------------------------------------------------
BASES = {
    "noble": dict(
        image="lscr.io/linuxserver/baseimage-selkies:ubuntunoble", pm="apt",
        family="ubuntu", distro="Ubuntu 24.04 LTS", code="Noble Numbat",
        dl=872, arches=BOTH, polish=84,
        note="The most packages, the most answers online.",
        des=["xfce", "mate", "kde", "lxqt", "lxde", "cinnamon", "budgie",
             "gnome-flashback", "enlightenment", "i3", "openbox", "fluxbox",
             "icewm", "jwm", "awesome", "bspwm", "herbstluftwm",
             "xmonad", "pekwm", "wmaker", "fvwm3", "ukui"]),
    "bookworm": dict(
        image="lscr.io/linuxserver/baseimage-selkies:debianbookworm", pm="apt",
        family="debian", distro="Debian 12", code="Bookworm",
        dl=912, arches=BOTH, polish=78,
        note="Boring on purpose. Nothing moves until you move it.",
        des=["xfce", "mate", "kde", "lxqt", "lxde", "cinnamon", "budgie",
             "gnome-flashback", "enlightenment", "i3", "openbox", "fluxbox",
             "icewm", "jwm", "awesome", "bspwm", "herbstluftwm",
             "xmonad", "pekwm", "wmaker", "fvwm3", "dwm", "spectrwm", "cwm",
             "ratpoison", "twm"]),
    "kali": dict(
        image="lscr.io/linuxserver/baseimage-selkies:kali", pm="apt",
        family="kali", distro="Kali Linux", code="Rolling",
        dl=1284, arches=BOTH, polish=82,
        note="Offensive security tooling, one apt away.",
        des=["xfce", "kde", "lxqt", "gnome-flashback", "i3", "openbox"]),
    "fedora42": dict(
        image="lscr.io/linuxserver/baseimage-selkies:fedora42", pm="dnf",
        family="fedora", distro="Fedora 42", code="Adams",
        dl=744, arches=BOTH, polish=86,
        note="Newest everything, upstream-first.",
        des=["xfce", "mate", "kde", "lxqt", "lxde", "cinnamon", "budgie",
             "enlightenment", "i3", "openbox", "fluxbox", "icewm", "awesome",
             "bspwm", "qtile"]),
    "arch": dict(
        image="lscr.io/linuxserver/baseimage-selkies:arch", pm="pacman",
        family="arch", distro="Arch Linux", code="Rolling",
        dl=1179, arches=BOTH, polish=74,
        note="Bleeding edge, and you hold the knife.",
        des=["xfce", "mate", "kde", "lxqt", "lxde", "cinnamon", "budgie",
             "enlightenment", "i3", "openbox", "fluxbox", "icewm", "jwm",
             "awesome", "bspwm", "herbstluftwm", "qtile", "wmaker"]),
    "alpine321": dict(
        image="lscr.io/linuxserver/baseimage-selkies:alpine321", pm="apk",
        family="alpine", distro="Alpine 3.21", code="musl",
        dl=434, arches=BOTH, polish=62,
        note="Half the download of anything else. musl, not glibc.",
        des=["xfce", "mate", "lxqt", "i3", "openbox", "fluxbox", "icewm",
             "jwm", "awesome", "bspwm", "herbstluftwm", "dwm", "spectrwm"]),
}

# --------------------------------------------------------------------------
# Ready-made Webtop images (Selkies, port 3000 http / 3001 https, no auth).
# dl numbers are real arm64 manifest sizes.
# --------------------------------------------------------------------------
WEBTOP = [
    ("ubuntu-xfce", "ubuntu", "Ubuntu 24.04", "xfce", 1100),
    ("ubuntu-mate", "ubuntu", "Ubuntu 24.04", "mate", 1383),
    ("ubuntu-kde", "ubuntu", "Ubuntu 24.04", "kde", 1630),
    ("ubuntu-lxqt", "ubuntu", "Ubuntu 24.04", "lxqt", 1147),
    ("ubuntu-i3", "ubuntu", "Ubuntu 24.04", "i3", 1049),
    ("debian-xfce", "debian", "Debian", "xfce", 1131),
    ("debian-mate", "debian", "Debian", "mate", 1290),
    ("debian-kde", "debian", "Debian", "kde", 1610),
    ("debian-i3", "debian", "Debian", "i3", 1020),
    ("fedora-xfce", "fedora", "Fedora", "xfce", 1180),
    ("fedora-mate", "fedora", "Fedora", "mate", 1320),
    ("fedora-kde", "fedora", "Fedora", "kde", 1632),
    ("fedora-i3", "fedora", "Fedora", "i3", 1010),
    ("arch-xfce", "arch", "Arch Linux", "xfce", 1420),
    ("arch-mate", "arch", "Arch Linux", "mate", 1510),
    ("arch-kde", "arch", "Arch Linux", "kde", 1780),
    ("arch-i3", "arch", "Arch Linux", "i3", 1240),
    ("alpine-mate", "alpine", "Alpine", "mate", 877),
    ("alpine-i3", "alpine", "Alpine", "i3", 718),
]

# --------------------------------------------------------------------------
# Kasm desktop images (KasmVNC, port 6901, https + basic auth).
# Tags and arches verified against the registry.
# --------------------------------------------------------------------------
KASM = [
    ("ubuntu-jammy-desktop", "1.19.0", "ubuntu", "Ubuntu 22.04", "xfce", 2400, BOTH),
    ("ubuntu-focal-desktop", "1.16.1", "ubuntu", "Ubuntu 20.04", "xfce", 2300, BOTH),
    ("ubuntu-bionic-desktop", "1.10.0", "ubuntu", "Ubuntu 18.04", "xfce", 2100, BOTH),
    ("debian-bullseye-desktop", "1.19.0", "debian", "Debian 11", "xfce", 2250, BOTH),
    ("kali-rolling-desktop", "1.19.0", "kali", "Kali Rolling", "xfce", 2600, BOTH),
    ("parrotos-5-desktop", "1.14.0", "parrot", "Parrot OS 5", "mate", 2800, BOTH),
    ("almalinux-8-desktop", "1.19.0", "almalinux", "AlmaLinux 8", "xfce", 2500, BOTH),
    ("almalinux-9-desktop", "1.19.0", "almalinux", "AlmaLinux 9", "xfce", 2450, BOTH),
    ("rockylinux-8-desktop", "1.19.0", "rocky", "Rocky Linux 8", "xfce", 2500, BOTH),
    ("rockylinux-9-desktop", "1.19.0", "rocky", "Rocky Linux 9", "xfce", 2450, BOTH),
    ("oracle-8-desktop", "1.19.0", "oracle", "Oracle Linux 8", "xfce", 2500, BOTH),
    ("oracle-9-desktop", "1.19.0", "oracle", "Oracle Linux 9", "xfce", 2450, BOTH),
    ("opensuse-15-desktop", "1.18.0", "opensuse", "openSUSE Leap 15", "xfce", 2400, BOTH),
    ("fedora-37-desktop", "1.15.0", "fedora", "Fedora 37", "xfce", 2350, BOTH),
    ("alpine-317-desktop", "1.16.1", "alpine", "Alpine 3.17", "xfce", 1200, BOTH),
    ("centos-7-desktop", "1.15.0", "centos", "CentOS 7", "xfce", 2200, X86),
    ("oracle-7-desktop", "1.15.0", "oracle", "Oracle Linux 7", "xfce", 2200, X86),
    ("remnux-focal-desktop", "1.16.1", "remnux", "REMnux", "xfce", 4200, X86),
    ("desktop-deluxe", "1.19.0", "ubuntu", "Kasm Deluxe", "xfce", 3600, X86),
    ("tracelabs", "1.19.0", "kali", "Trace Labs OSINT", "xfce", 3200, X86),
]

# --------------------------------------------------------------------------
# Personalities: curated looks built on top of a base.  This is where the
# "make it beautiful" and "make it tiny" requests actually live.
# --------------------------------------------------------------------------
PERSONALITIES = [
    dict(id="aurora-xfce", name="Aurora", family="zorin", base="noble", de="xfce",
         subtitle="Zorin-inspired Ubuntu", beauty=93, add_dl=120,
         desc="Yaru theming, a Plank dock, Papirus icons. The friendliest desktop "
              "here, and still light enough to fly.",
         extra="yaru-theme-gtk yaru-theme-icon yaru-theme-gnome-shell plank "
               "papirus-icon-theme fonts-ubuntu arc-theme",
         theme=dict(gtk="Yaru-dark", icons="Papirus-Dark", dock=True, panel="top")),
    dict(id="mintish-cinnamon", name="Spearmint", family="mint", base="noble",
         de="cinnamon", subtitle="Mint-style Cinnamon", beauty=94, add_dl=90,
         desc="Cinnamon with a green-accented dark theme and Papirus icons. "
              "The layout everyone recognises.",
         extra="materia-gtk-theme papirus-icon-theme fonts-noto-core",
         theme=dict(gtk="Materia-dark", icons="Papirus-Dark")),
    dict(id="mintish-mate", name="Spearmint MATE", family="mint", base="noble",
         de="mate", subtitle="Mint-style MATE", beauty=86, add_dl=80,
         desc="The traditional two-panel MATE layout with a soft dark theme. "
              "Very light for how finished it looks.",
         extra="materia-gtk-theme papirus-icon-theme fonts-noto-core",
         theme=dict(gtk="Materia-dark", icons="Papirus-Dark")),
    dict(id="mintish-xfce", name="Spearmint Xfce", family="mint", base="noble",
         de="xfce", subtitle="Mint-style Xfce", beauty=84, add_dl=75,
         desc="Mint's Xfce edition in spirit: one panel, dark theme, no surprises.",
         extra="materia-gtk-theme papirus-icon-theme fonts-noto-core",
         theme=dict(gtk="Materia-dark", icons="Papirus-Dark", panel="bottom")),
    dict(id="nebula-flashback", name="Nebula", family="pop", base="noble",
         de="gnome-flashback", subtitle="Pop-flavoured GNOME", beauty=90, add_dl=110,
         desc="GNOME's classic session with a cool dark palette and a dock. "
              "Pop!_OS energy without the Pop repos.",
         extra="materia-gtk-theme papirus-icon-theme plank fonts-firacode",
         theme=dict(gtk="Materia-dark", icons="Papirus-Dark", dock=True)),
    dict(id="cupertino", name="Cupertino Clean", family="generic-mac", base="bookworm",
         de="xfce", subtitle="Mac-like Xfce", beauty=92, add_dl=130,
         desc="Top panel, bottom Plank dock, Arc theme, rounded everything. "
              "Calm and uncluttered.",
         extra="arc-theme papirus-icon-theme plank fonts-inter conky-std picom",
         theme=dict(gtk="Arc-Dark", icons="Papirus-Dark", dock=True, panel="top")),
    dict(id="redmond", name="Redmond Classic", family="generic-win", base="bookworm",
         de="xfce", subtitle="Windows-like Xfce", beauty=78, add_dl=85,
         desc="One bottom taskbar, start-style menu, grey chrome. Instantly "
              "familiar to anyone switching over.",
         extra="greybird-gtk-theme elementary-xfce-icon-theme fonts-dejavu",
         theme=dict(gtk="Greybird-dark", icons="elementary-xfce-dark", panel="bottom")),
    dict(id="elementary-ish", name="Pantheon Lite", family="elementary", base="noble",
         de="xfce", subtitle="elementary-style Xfce", beauty=89, add_dl=115,
         desc="elementary's icon set, a slim top panel and a dock. Extremely "
              "tidy, extremely light.",
         extra="elementary-xfce-icon-theme greybird-gtk-theme plank fonts-inter",
         theme=dict(gtk="Greybird", icons="elementary-xfce", dock=True, panel="top")),
    dict(id="dragonfire", name="Dragonfire", family="garuda", base="arch", de="kde",
         subtitle="Garuda-flavoured Arch KDE", beauty=96, add_dl=260,
         desc="Arch plus Plasma, Kvantum, blur and dark glass. The heaviest and "
              "the prettiest thing in the catalog.",
         extra="kvantum papirus-icon-theme ttf-fira-code materia-kde",
         theme=dict(icons="Papirus-Dark")),
    dict(id="parrotish", name="Nightjar", family="parrot", base="bookworm", de="mate",
         subtitle="Parrot-flavoured security MATE", beauty=85, add_dl=320,
         desc="Dark MATE with a working network-tools kit: nmap, tcpdump, "
              "wireshark CLI, netcat, whois.",
         extra="materia-gtk-theme papirus-icon-theme nmap tcpdump tshark netcat-openbsd "
               "whois dnsutils curl wget git",
         theme=dict(gtk="Materia-dark", icons="Papirus-Dark")),
    dict(id="ricer-i3", name="Ricer i3", family="arch", base="arch", de="i3",
         subtitle="Polybar + picom + rofi", beauty=88, add_dl=180,
         desc="The screenshot-thread setup: polybar, picom blur, rofi launcher, "
              "Alacritty and Nerd Fonts. Tiny and sharp.",
         extra="polybar picom rofi alacritty ttf-fira-code ttf-nerd-fonts-symbols feh",
         theme=dict()),
    dict(id="ricer-bspwm", name="Ricer bspwm", family="debian", base="bookworm",
         de="bspwm", subtitle="Polybar + picom + kitty", beauty=86, add_dl=170,
         desc="bspwm with polybar, picom, rofi and kitty. A blank, beautiful "
              "canvas on a Debian base.",
         extra="polybar picom rofi kitty fonts-firacode feh",
         theme=dict()),
    dict(id="featherweight", name="Featherweight", family="alpine", base="alpine321",
         de="dwm", subtitle="Alpine + dwm", beauty=46, add_dl=20,
         desc="The smallest real desktop here: Alpine, dwm, xterm. Boots in "
              "about a second and barely touches RAM.",
         extra="xterm", theme=dict()),
    dict(id="workbench", name="Workbench", family="ubuntu", base="noble", de="xfce",
         subtitle="Ubuntu Xfce dev station", beauty=82, add_dl=520,
         desc="Xfce with the tools already installed: git, neovim, Python, Node, "
              "build-essential, ripgrep, tmux, htop.",
         extra="git neovim vim tmux htop ripgrep fd-find jq curl wget build-essential "
               "python3-pip python3-venv nodejs yaru-theme-gtk papirus-icon-theme",
         theme=dict(gtk="Yaru-dark", icons="Papirus-Dark")),
]

# --------------------------------------------------------------------------
# Derivation helpers
# --------------------------------------------------------------------------

def _clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def _round_mb(v, step=128):
    return int(max(step, round(float(v) / step) * step))


def _metrics(idle_mb, dl_mb):
    """RAM floor/recommendation, cpu recommendation and a heaviness score."""
    # Selkies itself (Xorg + nginx + pulse + the WebRTC encoder) needs headroom.
    overhead = 420
    ram_min = _round_mb(idle_mb + overhead)
    ram_rec = _round_mb(max(ram_min * 2, 1024))
    if idle_mb >= 600:
        cpu_rec = 3.0
    elif idle_mb >= 350:
        cpu_rec = 2.0
    elif idle_mb >= 180:
        cpu_rec = 1.5
    else:
        cpu_rec = 1.0
    disk_mb = int(dl_mb * EXPAND)
    # Heaviness is mostly about what it costs you while it runs; disk matters,
    # but only a quarter as much as idle memory.
    runtime = _clamp((idle_mb - 30) / 7.7, 0, 100)
    footprint = _clamp((disk_mb - 1200) / 45.0, 0, 100)
    heavy = int(round(0.75 * runtime + 0.25 * footprint))
    return ram_min, ram_rec, cpu_rec, disk_mb, heavy


def _weight_class(heavy):
    if heavy < 20:
        return "feather"
    if heavy < 33:
        return "light"
    if heavy < 50:
        return "balanced"
    if heavy < 72:
        return "full"
    return "heavy"


def _entry(**kw):
    idle = kw.pop("idle")
    dl = kw.pop("dl")
    ram_min, ram_rec, cpu_rec, disk_mb, heavy = _metrics(idle, dl)
    kw.update(dl_mb=int(dl), disk_mb=disk_mb, idle_mb=int(idle), ram_min=ram_min,
              ram_rec=ram_rec, cpu_rec=cpu_rec, heavy=heavy,
              weight=_weight_class(heavy))
    kw.setdefault("tags", [])
    kw.setdefault("profile", "selkies")
    kw.setdefault("arches", list(BOTH))
    kw["arches"] = list(kw["arches"])
    return kw


# What each session expects to find in its environment. Without these,
# gnome-session skips GNOME Flashback's own panel and shell (they are
# OnlyShowIn=GNOME-Flashback), and Cinnamon's window manager refuses to start
# at all ("Unsupported session type").
SESSION_ENV = {
    "xfce": ["XDG_CURRENT_DESKTOP=XFCE", "XDG_SESSION_DESKTOP=xfce"],
    "mate": ["XDG_CURRENT_DESKTOP=MATE", "XDG_SESSION_DESKTOP=mate", "DESKTOP_SESSION=mate"],
    "kde": ["XDG_CURRENT_DESKTOP=KDE", "XDG_SESSION_DESKTOP=KDE", "KDE_FULL_SESSION=true",
            "DESKTOP_SESSION=plasma"],
    "lxqt": ["XDG_SESSION_DESKTOP=lxqt", "DESKTOP_SESSION=lxqt"],
    "lxde": ["XDG_CURRENT_DESKTOP=LXDE", "XDG_SESSION_DESKTOP=LXDE", "DESKTOP_SESSION=LXDE"],
    # No XDG_SESSION_DESKTOP/DESKTOP_SESSION here on purpose: when nemo-desktop
    # sees "cinnamon" there it leaves the wallpaper to Cinnamon, which cannot
    # draw it with software rendering under Xvfb, and the desktop is black.
    "cinnamon": ["XDG_CURRENT_DESKTOP=X-Cinnamon"],
    "budgie": ["XDG_CURRENT_DESKTOP=Budgie:GNOME", "XDG_SESSION_DESKTOP=budgie-desktop",
               "DESKTOP_SESSION=budgie-desktop"],
    "gnome-flashback": ["XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME",
                        "XDG_SESSION_DESKTOP=gnome-flashback-metacity",
                        "DESKTOP_SESSION=gnome-flashback-metacity", "GNOME_SHELL_SESSION_MODE="],
    "enlightenment": ["XDG_CURRENT_DESKTOP=Enlightenment", "E_CONF_PROFILE=standard"],
    "ukui": ["XDG_CURRENT_DESKTOP=UKUI", "XDG_SESSION_DESKTOP=ukui", "DESKTOP_SESSION=ukui"],
}
# GTK desktops whose icons are SVGs need the loader that --no-install-recommends skips.
EXTRA_PKGS = {
    "apt": {"gnome-flashback": "librsvg2-common", "budgie": "librsvg2-common",
            "cinnamon": "librsvg2-common", "mate": "librsvg2-common", "ukui": "librsvg2-common"},
}


def _recipe(base_key, de_key):
    """Return the install recipe for a desktop on a base, or None."""
    base = BASES[base_key]
    de = DESKTOPS[de_key]
    spec = de.get(base["pm"])
    if not spec:
        return None
    pkgs = spec["pkgs"]
    extra = EXTRA_PKGS.get(base["pm"], {}).get(de_key)
    if extra:
        pkgs = pkgs + " " + extra
    env = ["XDG_SESSION_TYPE=x11"] + SESSION_ENV.get(de_key, []) + list(spec.get("env", []))
    return dict(image=base["image"], pm=base["pm"], pkgs=pkgs,
                session=spec["session"], pre=list(spec.get("pre", [])),
                env=env, bare=bool(de.get("bare")),
                term=de.get("term", "xterm"))


def build_catalog():
    out = []

    # --- ready-made Webtop images -----------------------------------------
    for tag, family, distro, de_key, dl in WEBTOP:
        de = DESKTOPS[de_key]
        out.append(_entry(
            id="webtop-" + tag,
            name="%s %s" % (distro, de["label"]),
            subtitle="Webtop - ready to run",
            family=family, distro=distro, de=de_key, de_label=de["label"],
            glyph=de["glyph"], kind="pull", display=de.get("display", "fit"),
            image="lscr.io/linuxserver/webtop:" + tag,
            desc="LinuxServer's prebuilt %s desktop on %s. No build step, "
                 "pulls and runs." % (de["label"], distro),
            idle=de["idle"] + 40, dl=dl,
            beauty=min(97, de["beauty"] + 8), speed=de["speed"],
            tags=["ready", "verified", family, de_key],
        ))

    # --- Kasm desktops ----------------------------------------------------
    for repo, ver, family, distro, de_key, dl, arches in KASM:
        de = DESKTOPS[de_key]
        out.append(_entry(
            id="kasm-" + repo.replace("-desktop", ""),
            name=distro,
            subtitle="Kasm workspace",
            family=family, distro=distro, de=de_key, de_label=de["label"],
            glyph=de["glyph"], kind="pull", profile="kasm",
            image="kasmweb/%s:%s" % (repo, ver),
            desc="Kasm's hardened %s workspace. Serves HTTPS with its own login, "
                 "so it tunnels over TCP rather than HTTP." % distro,
            idle=de["idle"] + 260, dl=dl,
            beauty=de["beauty"] + 4, speed=de["speed"] - 10,
            arches=arches,
            tags=["ready", "kasm", family, de_key],
        ))

    # --- recipe builds ----------------------------------------------------
    for base_key, base in BASES.items():
        for de_key in base["des"]:
            rec = _recipe(base_key, de_key)
            if not rec:
                continue
            de = DESKTOPS[de_key]
            out.append(_entry(
                id="%s-%s" % (base_key, de_key),
                name="%s %s" % (base["distro"], de["label"]),
                subtitle="built on %s" % base["code"],
                family=base["family"], distro=base["distro"], de=de_key,
                de_label=de["label"], glyph=de["glyph"], kind="build",
                display=de.get("display", "fit"),
                image=None, base=base_key, recipe=rec,
                desc="%s %s" % (de["blurb"], base["note"]),
                idle=de["idle"], dl=base["dl"] + de["add_dl"],
                beauty=de["beauty"], speed=de["speed"],
                arches=base["arches"],
                tags=["build", base["family"], de_key, de["klass"]],
            ))

    # --- personalities ----------------------------------------------------
    for p in PERSONALITIES:
        base = BASES[p["base"]]
        de = DESKTOPS[p["de"]]
        rec = _recipe(p["base"], p["de"])
        if not rec:
            continue
        rec = dict(rec)
        rec["pkgs"] = rec["pkgs"] + " " + p["extra"]
        rec["theme"] = p.get("theme", {})
        out.append(_entry(
            id=p["id"], name=p["name"], subtitle=p["subtitle"],
            family=p["family"], distro=base["distro"], de=p["de"],
            de_label=de["label"], glyph=de["glyph"], kind="build",
            display=de.get("display", "fit"),
            image=None, base=p["base"], recipe=rec, desc=p["desc"],
            idle=de["idle"] + 60, dl=base["dl"] + de["add_dl"] + p["add_dl"],
            beauty=p["beauty"], speed=max(30, de["speed"] - 6),
            arches=base["arches"],
            tags=["curated", "themed", p["family"], p["de"]],
        ))

    out.sort(key=lambda e: (-e["beauty"], e["heavy"], e["name"]))
    return out


CATALOG = build_catalog()
BY_ID = {e["id"]: e for e in CATALOG}

# A short list for the terminal menu: one strong pick per flavour of taste.
QUICK_PICKS = [
    "webtop-ubuntu-xfce", "webtop-ubuntu-mate", "webtop-ubuntu-kde",
    "aurora-xfce", "mintish-cinnamon", "cupertino", "dragonfire",
    "webtop-debian-xfce", "noble-budgie", "elementary-ish",
    "webtop-alpine-i3", "featherweight", "ricer-i3", "workbench",
    "kasm-kali-rolling", "noble-lxqt", "bookworm-icewm",
]

FAMILY_LABEL = {
    "ubuntu": "Ubuntu", "debian": "Debian", "fedora": "Fedora", "arch": "Arch",
    "alpine": "Alpine", "kali": "Kali", "parrot": "Parrot OS",
    "almalinux": "AlmaLinux", "rocky": "Rocky Linux", "oracle": "Oracle Linux",
    "centos": "CentOS", "opensuse": "openSUSE", "remnux": "REMnux",
    "mint": "Mint-style", "zorin": "Zorin-style", "pop": "Pop-style",
    "elementary": "elementary-style", "garuda": "Garuda-style",
    "generic-mac": "Mac-like", "generic-win": "Windows-like",
}
