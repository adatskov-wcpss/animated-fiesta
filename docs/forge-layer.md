# The forge layer

Every Selkies desktop the forge runs, pulled or built, gets a thin image layer on top: `selkies-forge/run-<id>:<digest>`. It's a few kilobytes. Its digest covers the layer's contents and the image underneath, so it's rebuilt in seconds whenever either changes, and the big package layers are never touched. Kasm images don't get it, because they run their own stack.

The layer has five parts, wired into LinuxServer's s6 supervision tree:

| Piece | Where it lives | When it runs |
|---|---|---|
| **seed** | `/usr/local/share/forge/seed`, oneshot `init-forge` | As root, after `init-config` and before the desktop (`svc-de` depends on it) |
| **agent** | `/usr/local/share/forge/agent`, longrun `svc-forge-agent` | As the desktop user, for as long as the container runs |
| **session supervisor** | `/defaults/startwm.sh` (built desktops) | Each time the desktop session starts |
| **xsettingsd guard** | replaces `svc-xsettingsd/run` | At start |
| **bwrap shim** | `/usr/local/bin/bwrap` (only where bwrap exists) | Whenever GTK decodes an image |

Plus a 24 KB wallpaper, `/usr/local/share/forge/wallpaper.jpg`.

## The seed: no first-run wizards

Desktops love to greet you with a setup window sized for a 1024×768 screen. In a browser tab that has just been resized, that window's buttons end up off the bottom. The seed writes sane first-run configs **only where none exist**, so anything you change later is kept:

| Desktop | What the seed does | Why |
|---|---|---|
| Enlightenment | `E_CONF_PROFILE=standard` | Skips the language/keyboard wizard, whose **Next** button fell off smaller screens |
| Enlightenment (Arch) | adds `user: abc allow: *` to `sysactions.conf` | Otherwise: *Error in Enlightenment System Service* |
| i3 | a full `~/.config/i3/config` with Alt as the modifier, a themed bar, gaps where supported, and a terminal on start | Without one, i3 asks "generate a config?" on a black screen. Browsers and host OSes swallow the Super key. |
| i3status | a compact cpu/mem/disk/clock config | |
| bspwm | `bspwmrc` + `sxhkdrc` (Alt-based bindings) | bspwm does nothing at all without them |
| Xfce (built) | the default panel, no compositor, the forge wallpaper, screensaver and lock off | The panel asks "default or empty?"; xfwm4's compositor doesn't repaint after a resize under Xvfb (black band); the screensaver locks with a password nobody set |
| KDE Plasma | no welcome centre, wallet, splash, file indexer or auto-lock | Pop-ups on first start, and wasted CPU |
| LXQt | window manager set to openbox; pcmanfm-qt wallpaper | Otherwise LXQt asks which WM to use |
| GNOME Flashback / Budgie | a user copy of the gnome-session file without Power, Sharing, Smartcard, Wacom, Rfkill, PrintNotifications, ScreensaverProxy, UsbProtection; adds `gnome-flashback` itself | Those need logind/UPower/hardware a container lacks. When a *required* component dies, gnome-session shows **"Oh no! Something has gone wrong"**. Ubuntu starts `gnome-flashback` from a systemd unit, which doesn't exist here. |

Everything the seed writes is handed back to the desktop user (`abc`). A root-owned `~/.local` once broke xmonad and gnome-session.

## The agent: windows stay on screen

Selkies resizes the X screen to your browser window. Most window managers cope; some leave windows hanging off the edge. Every second, the agent:

1. reads the screen size (`xdotool getdisplaygeometry`)
2. on a resize, or when a window appears, fits every normal window into the **usable work area** (`_NET_WORKAREA`, so panels are respected), using its frame extents (`_NET_FRAME_EXTENTS`, so title bars count). It skips docks, desktops, menus, tooltips, maximized and fullscreen windows, and anything screen-sized at the origin. It then checks where the window actually landed and corrects once, because window managers disagree on whether a move positions the frame or the client.
3. **unsticks the giant screen.** Xvfb starts at 15360×8640. If a session restart leaves the screen there, the agent puts it back to the last real size after three seconds (the forge also caps it with `MAX_RES` in fit mode).
4. every few seconds writes `/tmp/forge/health.json`: `{"wm": "Xfwm4", "screen": "1600x900", "clients": 3, "mode": "normal"}`. The engine's health check and the watchdog read it.

On Wayland webtops (LinuxServer's KDE images default to Wayland) the agent only reports which compositor is running.

Its log is `/tmp/forge/agent.log` inside the desktop.

## The session supervisor (built desktops)

`startwm.sh` exports the variables the session expects (`XDG_SESSION_TYPE=x11`, `XDG_CURRENT_DESKTOP`, …), turns off screen lockers, sets the wallpaper where the desktop's own default image is missing, and then:

```
dbus-run-session -- <the session>  >> /tmp/forge/session.log
```

- **`dbus-run-session`** keeps the session bus alive exactly as long as the desktop. `dbus-launch --exit-with-session` watches stdin instead, and s6 starts the desktop with stdin closed. On Arch's dbus 1.16 the bus was gone before the desktop started: Xfce hung, LXQt exited silently, Enlightenment aborted.
- Everything the session prints goes to **`/tmp/forge/session.log`** (trimmed as it grows).
- If the session dies within 30 seconds **three times in a row**, the supervisor starts a **rescue session**: openbox plus a terminal that shows the log tail and explains what happened. The agent reports `mode: rescue`, and the engine and watchdog record it.

Session variables by desktop:

| Desktop | Notes |
|---|---|
| Cinnamon | `XDG_CURRENT_DESKTOP=X-Cinnamon` only. Its window manager refuses to start without `XDG_SESSION_TYPE=x11` ("Unsupported session type"). `XDG_SESSION_DESKTOP` is left unset on purpose, so nemo-desktop draws the wallpaper; Cinnamon can't, with software rendering under Xvfb. |
| GNOME Flashback | `XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME`, or gnome-session skips its own panel and shell (they're `OnlyShowIn=GNOME-Flashback`) |
| KDE | `KDE_FULL_SESSION=true`; compositing off; `kwin-x11` installed explicitly (`--no-install-recommends` and Plasma 6.4 both drop it) |
| Budgie, MATE, Xfce, LXDE, UKUI, Enlightenment | their own `XDG_CURRENT_DESKTOP`, plus compositor and screensaver settings through gsettings |

## The xsettingsd guard

LinuxServer's base runs `xsettingsd` unless the desktop is Xfce. GNOME, Cinnamon, MATE, Budgie and UKUI bring their own XSETTINGS manager, which then exits ("only one xsettings manager at a time"). gnome-session treats that as a fatal error. The guard stands `xsettingsd` aside for all of them.

## The bwrap shim

GTK's newest image loaders (glycin, on Arch) decode every icon inside `bwrap`. Docker doesn't let an unprivileged container create the namespaces bwrap needs, so every icon failed to load, and Xfce, MATE and LXQt aborted on start. The shim tests the real bwrap once. If it works, every call goes to the real bwrap. If it doesn't, the shim drops bwrap's own options, keeps its `--setenv`, and runs the loader directly.

## Screen modes

| Mode | What happens | Default for |
|---|---|---|
| **fit** | The desktop follows your browser window; Selkies resizes the X screen. Capped at 3840×2160. | Everything else |
| **fixed** | The screen stays one size (1920×1080 by default; 1280×720 up to 2560×1440 to choose from) and Selkies scales it into your window. Nothing can ever end up off the bottom. | Enlightenment, Cinnamon, Budgie, GNOME Flashback, UKUI: compositing window managers that misdraw when the screen changes size under Xvfb |

Pick it per desktop under **Screen** when you forge it, or later under **Edit limits** (which recreates the desktop; files are kept). From the engine: `launch --display fixed --resolution 1600x900`.

## Repair

Desktops made by an older version keep the layer they were created with. **Repair** (in the manager's ⋯ menu, `selkies-cli manager`, or `engine.py do NAME repair`) recreates the container on the newest layer. It keeps the same ports, sign-in, limits and screen mode, and the same `/config` volume, so your files are untouched. It then waits until the session is up again.

## Debugging inside a desktop

Open a shell from the manager (or `docker exec -it forge-<name> bash`):

```bash
cat /tmp/forge/health.json        # what the agent sees
tail -50 /tmp/forge/session.log   # what the session printed (built desktops)
tail -20 /tmp/forge/agent.log     # resizes and windows it moved
ls /tmp/forge/                    # quick-exits, mode, bwrap-works(.no)
```
