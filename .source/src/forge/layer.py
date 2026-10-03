"""
Selkies Forge - the forge layer.

Every Selkies desktop the forge runs, pulled or built, gets a thin image layer
on top with three things in it:

  seed    a one-shot s6 service that runs before the desktop starts and writes
          sane first-run configs, so nothing opens a setup wizard that is sized
          for a screen you do not have (Enlightenment's language picker, i3's
          "generate a config?" prompt, the Xfce panel question, KDE's welcome
          centre, screen lockers that ask for a password nobody set).
  agent   a small supervised service that watches the X screen. When Selkies
          resizes the screen to your browser window, any window that would
          now hang off the edge is pulled back inside it. It also writes a
          health file the engine reads to know the desktop really came up.
  startwm (built desktops only) runs the session under a supervisor that logs
          what it prints, and drops to a rescue session that shows the log
          instead of a black screen if the desktop keeps crashing.

The layer is a few kilobytes and builds in seconds, so it is rebuilt whenever
this file changes, without touching the big package layers underneath.
"""

import base64
import hashlib

LAYER_VERSION = "8"

AGENT = r"""#!/bin/bash
# Selkies Forge agent: keeps windows on the visible screen, reports health.
export DISPLAY="${DISPLAY:-:1}"
S=/tmp/forge
mkdir -p "$S" 2>/dev/null
LOG="$S/agent.log"
until xprop -root >/dev/null 2>&1; do sleep 1; done
echo "$(date '+%F %T') agent up on $DISPLAY" >> "$LOG"

geom() { xdotool getdisplaygeometry 2>/dev/null; }

# Windows the window manager says it manages. Only when there is no EWMH
# window manager at all (twm, ratpoison...) fall back to mapped top-levels.
clients() {
  if xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q '0x'; then
    xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o '0x[0-9a-fA-F]*'
  else
    xdotool search --onlyvisible --maxdepth 1 --name '' 2>/dev/null
  fi
}

nums() { grep -o -- '-\?[0-9]\+' | tr '\n' ' '; }

fit_one() {  # fit_one <window> <screen w> <screen h>
  local id=$1 W=$2 H=$3 t st X= Y= WIDTH= HEIGHT=
  t=$(xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null)
  case "$t" in *DOCK*|*DESKTOP*|*NOTIFICATION*|*TOOLTIP*|*MENU*|*SPLASH*|*COMBO*|*DND*) return ;; esac
  st=$(xprop -id "$id" _NET_WM_STATE 2>/dev/null)
  case "$st" in *FULLSCREEN*|*MAXIMIZED_VERT*|*HIDDEN*) return ;; esac
  eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null | grep -E '^(X|Y|WIDTH|HEIGHT)=-?[0-9]+$')"
  [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] || return
  [ "$WIDTH" -lt 40 ] || [ "$HEIGHT" -lt 40 ] && return
  # Exactly screen-sized at the origin: a desktop, a backdrop or a fullscreen
  # app. The window manager owns those.
  if [ "$X" -le 0 ] && [ "$Y" -le 0 ] && [ "$WIDTH" -ge "$W" ] && [ "$HEIGHT" -ge "$H" ]; then return; fi

  # Decorations (title bar, borders) and the usable work area (screen minus panels).
  local l=0 r=0 tp=0 b=0 wx=0 wy=0 ww=$W wh=$H e wa
  e=$(xprop -id "$id" _NET_FRAME_EXTENTS 2>/dev/null | sed -n 's/.*= //p' | nums)
  [ -n "$e" ] && set -- $e && l=${1:-0} r=${2:-0} tp=${3:-0} b=${4:-0}
  wa=$(xprop -root _NET_WORKAREA 2>/dev/null | sed -n 's/.*= //p' | nums)
  if [ -n "$wa" ]; then
    set -- $wa
    wx=${1:-0}; wy=${2:-0}; ww=${3:-$W}; wh=${4:-$H}
  fi
  # Right after a resize the work area can still describe the old screen.
  [ $((wx + ww)) -gt "$W" ] && ww=$((W - wx))
  [ $((wy + wh)) -gt "$H" ] && wh=$((H - wy))
  [ "$ww" -lt 200 ] && { wx=0; ww=$W; }
  [ "$wh" -lt 150 ] && { wy=0; wh=$H; }

  local maxw=$((ww - l - r)) maxh=$((wh - tp - b))
  local nw=$WIDTH nh=$HEIGHT
  [ "$nw" -gt "$maxw" ] && nw=$maxw
  [ "$nh" -gt "$maxh" ] && nh=$maxh
  local fx=$((X - l)) fy=$((Y - tp)) fw=$((nw + l + r)) fh=$((nh + tp + b))
  local tx=$fx ty=$fy
  [ $((tx + fw)) -gt $((wx + ww)) ] && tx=$((wx + ww - fw))
  [ $((ty + fh)) -gt $((wy + wh)) ] && ty=$((wy + wh - fh))
  [ "$tx" -lt "$wx" ] && tx=$wx
  [ "$ty" -lt "$wy" ] && ty=$wy
  if [ "$nw" = "$WIDTH" ] && [ "$nh" = "$HEIGHT" ] && [ "$tx" = "$fx" ] && [ "$ty" = "$fy" ]; then
    return
  fi
  if [ "$nw" != "$WIDTH" ] || [ "$nh" != "$HEIGHT" ]; then
    xdotool windowsize "$id" "$nw" "$nh" 2>/dev/null
  fi
  xdotool windowmove "$id" "$tx" "$ty" 2>/dev/null
  # Window managers disagree on whether a move means the frame or the client.
  # Look at where it actually landed and correct once.
  sleep 0.2
  local X2= Y2=
  eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null | grep -E '^(X|Y)=-?[0-9]+$' | sed 's/^/2/;s/^2X/X2/;s/^2Y/Y2/')"
  if [ -n "$X2" ] && [ -n "$Y2" ]; then
    local dx=$((tx - (X2 - l))) dy=$((ty - (Y2 - tp)))
    if [ "$dx" != 0 ] || [ "$dy" != 0 ]; then
      xdotool windowmove "$id" $((tx + dx)) $((ty + dy)) 2>/dev/null
    fi
  fi
  echo "$(date '+%F %T') fit $id ${WIDTH}x${HEIGHT}+$X+$Y -> ${nw}x${nh} frame@$tx,$ty in ${ww}x${wh}+$wx+$wy" >> "$LOG"
}

health() {  # health <screen>
  local wid wm n mode
  wid=$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -o '0x[0-9a-fA-F]*' | head -n 1)
  wm=""
  [ -n "$wid" ] && wm=$(xprop -id "$wid" _NET_WM_NAME 2>/dev/null | sed -n 's/^[^"]*"\(.*\)"$/\1/p' | tr -d '"\\')
  n=$(printf '%s\n' $2 | grep -c .)
  mode=$(cat "$S/mode" 2>/dev/null || echo normal)
  printf '{"ts": %s, "screen": "%s", "wm": "%s", "clients": %s, "mode": "%s"}\n' \
    "$(date +%s)" "$1" "$wm" "$n" "$mode" > "$S/health.json.tmp" && mv -f "$S/health.json.tmp" "$S/health.json"
}

# Xvfb starts at a huge virtual size (15360x8640) and svc-de shrinks it once.
# When a session restarts, the screen can fall back to that huge size and stay
# there: half a gigabyte of framebuffer and a blank screen until a browser
# reconnects. Put it back to the last real size.
MAXRES=$(xrandr 2>/dev/null | sed -n 's/.*maximum \([0-9]*\) x \([0-9]*\).*/\1 \2/p' | head -n 1)
good="1024 768" huge=0
set_mode() {  # set_mode <w> <h>
  local m n
  m=$(cvt "$1" "$2" 2>/dev/null | sed -n 's/^Modeline //p' | tr -d '"')
  [ -n "$m" ] || return
  n=$(echo $m | cut -d' ' -f1)
  xrandr --newmode $m >/dev/null 2>&1
  xrandr --addmode screen "$n" >/dev/null 2>&1
  xrandr --output screen --mode "$n" >/dev/null 2>&1
}

last="" prev="" done_ids="" tick=0
while :; do
  g=$(geom)
  if [ -z "$g" ]; then sleep 2; continue; fi
  W=${g% *}; H=${g#* }
  if [ -z "${SELKIES_MANUAL_WIDTH:-}" ] && [ -n "$MAXRES" ] && [ "$g" = "$MAXRES" ] && \
     [ "${MAXRES%% *}" -ge 7000 ]; then
    huge=$((huge + 1))
    if [ "$huge" -ge 3 ]; then
      echo "$(date '+%F %T') screen stuck at the ${MAXRES/ /x} default, back to ${good/ /x}" >> "$LOG"
      set_mode $good
      huge=0
      sleep 1
      continue
    fi
  else
    huge=0
    [ "$W" -ge 320 ] && [ "$H" -ge 240 ] && good="$g"
  fi
  ids=$(clients | tr '\n' ' ')
  if [ "$g" != "$last" ]; then
    [ -n "$last" ] && { echo "$(date '+%F %T') screen ${last/ /x} -> ${W}x${H}" >> "$LOG"; sleep 0.7; ids=$(clients | tr '\n' ' '); }
    for id in $ids; do fit_one "$id" "$W" "$H"; done
    done_ids="$ids"
  else
    # New windows get one tick to be placed by the window manager first.
    for id in $ids; do
      case " $done_ids " in *" $id "*) continue ;; esac
      case " $prev " in *" $id "*) fit_one "$id" "$W" "$H"; done_ids="$done_ids $id" ;; esac
    done
  fi
  last="$g"; prev="$ids"
  tick=$((tick + 1))
  if [ $((tick % 3)) = 1 ]; then
    health "${W}x${H}" "$ids"
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 200000 ]; then
      tail -n 400 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    fi
  fi
  sleep 1
done
"""

# Runs as root before the desktop starts. Only ever writes files that do not
# exist yet, so anything you change inside the desktop is kept.
SEED = r"""#!/usr/bin/with-contenv bash
H="${HOME:-/config}"
[ -d "$H" ] || H=/config
mkdir -p /tmp/forge && chown abc:abc /tmp/forge 2>/dev/null
rm -f /tmp/forge/quick-exits /tmp/forge/mode
CE=/run/s6/container_environment
have() { command -v "$1" >/dev/null 2>&1; }
put() {  # put <path relative to $H> [mode]: stdin becomes the file, if it is missing
  local f="$H/$1"
  if [ -e "$f" ]; then cat >/dev/null; return 0; fi
  mkdir -p "$(dirname "$f")"
  cat > "$f"
  [ -n "${2:-}" ] && chmod "$2" "$f"
  echo "[forge] seeded $1"
}
term() { for t in "$@" kitty alacritty xfce4-terminal qterminal lxterminal mate-terminal gnome-terminal konsole terminology xterm; do have "$t" && { echo "$t"; return; }; done; echo xterm; }
launcher() { if have rofi; then echo "rofi -show drun"; else echo "dmenu_run"; fi; }

# --- Enlightenment: skip the first-run wizard (it is sized for 1024x768 and
# its Next button falls off a smaller screen).
if have enlightenment; then
  [ -d "$CE" ] && printf 'standard' > "$CE/E_CONF_PROFILE"
fi

# Enlightenment's system helper (mounts, brightness, shutdown menu) only lets
# listed users and groups in. On Arch the desktop user is in none of them, and
# E greets you with "Error in Enlightenment System Service".
SA=/etc/enlightenment/sysactions.conf
if [ -f "$SA" ] && ! grep -q '^user: *abc ' "$SA"; then
  sed -i '0,/^user:/s//user:     abc       allow: *\nuser:/' "$SA" && echo "[forge] allowed abc in sysactions.conf"
fi

# --- i3: without a config i3 opens "generate a config?" on a black screen.
if have i3 && [ ! -e "$H/.config/i3/config" ] && [ ! -e "$H/.i3/config" ]; then
  T=$(term); L=$(launcher)
  GAPS=""
  v=$(i3 --version 2>/dev/null | sed -n 's/^i3 version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
  set -- $v
  if [ -n "${1:-}" ] && { [ "$1" -gt 4 ] || { [ "$1" -eq 4 ] && [ "${2:-0}" -ge 22 ]; }; }; then
    GAPS="gaps inner 6"
  fi
  put .config/i3/config <<I3EOF
# Selkies Forge i3 config. The modifier is Alt, because browsers and the
# host OS usually swallow the Super key before it reaches the desktop.
#   Alt+Enter terminal   Alt+d launcher   Alt+Shift+q close
#   Alt+1..5 workspaces  Alt+f fullscreen Alt+Shift+space float
set \$mod Mod1
font pango:DejaVu Sans Mono 10
floating_modifier \$mod
default_border pixel 2
default_floating_border normal
$GAPS
client.focused #5aa0ff #2a5db0 #ffffff #8cc4ff #5aa0ff
client.unfocused #1b2433 #121a26 #9aa7b8 #1b2433 #1b2433
for_window [window_role="pop-up"] floating enable
for_window [window_type="dialog"] floating enable
bindsym \$mod+Return exec $T
bindsym \$mod+d exec --no-startup-id $L
bindsym \$mod+Shift+q kill
bindsym \$mod+h focus left
bindsym \$mod+j focus down
bindsym \$mod+k focus up
bindsym \$mod+l focus right
bindsym \$mod+Left focus left
bindsym \$mod+Down focus down
bindsym \$mod+Up focus up
bindsym \$mod+Right focus right
bindsym \$mod+Shift+h move left
bindsym \$mod+Shift+j move down
bindsym \$mod+Shift+k move up
bindsym \$mod+Shift+l move right
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Down move down
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Right move right
bindsym \$mod+b split h
bindsym \$mod+v split v
bindsym \$mod+f fullscreen toggle
bindsym \$mod+s layout stacking
bindsym \$mod+w layout tabbed
bindsym \$mod+e layout toggle split
bindsym \$mod+Shift+space floating toggle
bindsym \$mod+space focus mode_toggle
bindsym \$mod+1 workspace number 1
bindsym \$mod+2 workspace number 2
bindsym \$mod+3 workspace number 3
bindsym \$mod+4 workspace number 4
bindsym \$mod+5 workspace number 5
bindsym \$mod+Shift+1 move container to workspace number 1
bindsym \$mod+Shift+2 move container to workspace number 2
bindsym \$mod+Shift+3 move container to workspace number 3
bindsym \$mod+Shift+4 move container to workspace number 4
bindsym \$mod+Shift+5 move container to workspace number 5
bindsym \$mod+Shift+c reload
bindsym \$mod+Shift+r restart
mode "resize" {
  bindsym h resize shrink width 10 px or 10 ppt
  bindsym j resize grow height 10 px or 10 ppt
  bindsym k resize shrink height 10 px or 10 ppt
  bindsym l resize grow width 10 px or 10 ppt
  bindsym Return mode "default"
  bindsym Escape mode "default"
}
bindsym \$mod+r mode "resize"
bar {
  status_command i3status
  position bottom
  colors {
    background #0b1422
    statusline #c9d6e8
    separator #33435a
    focused_workspace #5aa0ff #2a5db0 #ffffff
    inactive_workspace #0b1422 #0b1422 #8a98ab
  }
}
exec_always --no-startup-id sh -c 'feh --no-fehbg --bg-fill /usr/local/share/forge/wallpaper.jpg 2>/dev/null || xsetroot -solid "#10233d" 2>/dev/null || true'
exec --no-startup-id $T
I3EOF
fi
if have i3status && [ ! -e "$H/.config/i3status/config" ]; then
  put .config/i3status/config <<'ISEOF'
general {
  colors = true
  interval = 5
}
order += "cpu_usage"
order += "memory"
order += "disk /"
order += "tztime local"
cpu_usage { format = "cpu %usage" }
memory { format = "mem %used / %total" }
disk "/" { format = "disk %avail free" }
tztime local { format = "%a %d %b  %H:%M" }
ISEOF
fi

# --- bspwm does nothing at all without a bspwmrc and an sxhkdrc.
if have bspwm && [ ! -e "$H/.config/bspwm/bspwmrc" ]; then
  T=$(term); L=$(launcher)
  put .config/bspwm/bspwmrc 755 <<BSEOF
#!/bin/sh
pgrep -x sxhkd >/dev/null || sxhkd &
bspc monitor -d 1 2 3 4 5
bspc config border_width 2
bspc config window_gap 10
bspc config split_ratio 0.52
bspc config borderless_monocle true
bspc config gapless_monocle true
bspc config focused_border_color "#5aa0ff"
bspc config normal_border_color "#1b2433"
xsetroot -cursor_name left_ptr 2>/dev/null
feh --no-fehbg --bg-fill /usr/local/share/forge/wallpaper.jpg 2>/dev/null || xsetroot -solid "#10233d" 2>/dev/null
pgrep -x $T >/dev/null || $T &
BSEOF
  put .config/sxhkd/sxhkdrc <<SXEOF
# Alt is the modifier: browsers swallow Super.
alt + Return
	$T
alt + d
	$L
alt + shift + q
	bspc node -c
alt + {h,j,k,l}
	bspc node -f {west,south,north,east}
alt + shift + {h,j,k,l}
	bspc node -s {west,south,north,east}
alt + {_,shift + }{1-5}
	bspc {desktop -f,node -d} '^{1-5}'
alt + f
	bspc node -t ~fullscreen
alt + s
	bspc node -t ~floating
alt + shift + r
	bspc wm -r
SXEOF
fi

# Ready-made images (webtops) already ship tuned first-run configs; only the
# desktops the forge built itself need the panel and locker defaults below.
BUILT=0
[ -f /usr/local/share/forge/built ] && BUILT=1

# --- Xfce: the panel asks "default config or one empty panel?" on first run.
if [ "$BUILT" = 1 ] && have xfce4-panel; then
  for d in /etc/xdg/xfce4/panel/default.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml; do
    if [ -f "$d" ]; then
      put .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml < "$d"
      break
    fi
  done
fi
# xfwm4's compositor does not repaint after the screen is resized under Xvfb,
# which leaves a black band where the desktop grew. LinuxServer's own Xfce
# webtops turn it off for the same reason.
if [ "$BUILT" = 1 ] && have xfwm4; then
  put .config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XWEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="borderless_maximize" type="bool" value="true"/>
    <property name="click_to_focus" type="bool" value="true"/>
    <property name="workspace_count" type="int" value="2"/>
  </property>
</channel>
XWEOF
fi
if [ "$BUILT" = 1 ] && have xfdesktop; then
  put .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'XDEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/local/share/forge/wallpaper.jpg"/>
        </property>
        <property name="workspace1" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/local/share/forge/wallpaper.jpg"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XDEOF
fi
if [ "$BUILT" = 1 ] && { have xfce4-screensaver || have xfce4-power-manager; }; then
  put .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml <<'XSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false"/>
  </property>
</channel>
XSEOF
  put .config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml <<'XPEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
  </property>
</channel>
XPEOF
fi

# --- KDE: no welcome centre, no wallet prompts, no splash, no file indexer.
if have plasmashell || have startplasma-x11; then
  put .config/plasma-welcomerc <<'KEOF'
[General]
LastSeenVersion=9.9.9
ShouldShow=false
KEOF
  put .config/kwalletrc <<'KEOF'
[Wallet]
Enabled=false
First Use=false
KEOF
  put .config/ksplashrc <<'KEOF'
[KSplash]
Engine=none
Theme=None
KEOF
  put .config/baloofilerc <<'KEOF'
[Basic Settings]
Indexing-Enabled=false
KEOF
  put .config/kscreenlockerrc <<'KEOF'
[Daemon]
Autolock=false
LockOnResume=false
Timeout=0
KEOF
fi

# --- GNOME Flashback and Budgie run on gnome-session, which shows "Oh no!
# Something has gone wrong" when any *required* component dies. Power,
# Sharing, Smartcard, Wacom and friends need logind, UPower or hardware a
# container does not have, so a user copy of the session drops them.
for f in /usr/share/gnome-session/sessions/*.session; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  for d in .config/gnome-session/sessions .local/share/gnome-session/sessions; do
    [ -e "$H/$d/$b" ] && continue
    mkdir -p "$H/$d"
    sed -E '/^RequiredComponents=/{s/org\.gnome\.SettingsDaemon\.(Power|Sharing|Smartcard|UsbProtection|Wacom|Rfkill|PrintNotifications|ScreensaverProxy);//g}' \
      "$f" > "$H/$d/$b" && echo "[forge] relaxed $b"
    # Ubuntu starts gnome-flashback itself (desktop, background, notifications)
    # from a systemd user unit; there is no systemd here, so name it directly.
    case "$b" in
      gnome-flashback-*) grep -q '=gnome-flashback;' "$H/$d/$b" || \
        sed -i 's/^RequiredComponents=/RequiredComponents=gnome-flashback;/' "$H/$d/$b" ;;
    esac
  done
done

# --- LXQt's desktop (pcmanfm-qt) defaults to a wallpaper some bases lack.
if have pcmanfm-qt && have lxqt-session; then
  put .config/pcmanfm-qt/lxqt/settings.conf <<'PQEOF'
[Desktop]
Wallpaper=/usr/local/share/forge/wallpaper.jpg
WallpaperMode=zoom
BgColor=#0a1730
PQEOF
fi

# --- LXQt asks which window manager to use unless it is already set.
if have lxqt-session && have openbox; then
  put .config/lxqt/session.conf <<'LQEOF'
[General]
window_manager=openbox
LQEOF
fi

# Everything above was written as root; hand it all to the desktop user
# (a root-owned ~/.local broke xmonad and gnome-session's migrations).
chown -R abc:abc "$H/.config" "$H/.local" "$H/.e" "$H/.i3" 2>/dev/null || true
exit 0
"""

# Replaces the base image's svc-xsettingsd/run: LinuxServer's version only
# stands aside for Xfce, but GNOME, Cinnamon, MATE and Budgie bring their own
# XSETTINGS manager too, and theirs exits ("only one xsettings manager at a
# time"), which gnome-session treats as a fatal error.
XSETTINGSD_RUN = """#!/usr/bin/with-contenv bash
for b in xfce4-session /usr/libexec/gsd-xsettings /usr/bin/csd-xsettings \\
         /usr/lib/cinnamon-settings-daemon/csd-xsettings mate-settings-daemon \\
         budgie-daemon ukui-settings-daemon; do
  if command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; then exec sleep infinity; fi
done
if [[ "${PIXELFLUX_WAYLAND,,}" == "true" ]]; then exec sleep infinity; fi
if [ ! -f "${HOME}/.xsettingsd" ]; then
  echo "Xft/DPI 98304" > "${HOME}/.xsettingsd"
fi
chown abc:abc "${HOME}/.xsettingsd"
exec s6-setuidgid abc xsettingsd
"""

# GTK's newest image loaders (glycin, on Arch) run every SVG/PNG decode inside
# bwrap. Docker does not let an unprivileged container create the namespaces
# bwrap needs, so every icon fails to load and Xfce, MATE and LXQt abort on
# start. This shim, placed ahead of the real bwrap on PATH, uses the real
# sandbox when it works and otherwise runs the loader directly.
BWRAP_SHIM = r"""#!/bin/sh
REAL=/usr/bin/bwrap
OK=/tmp/forge/bwrap-works
if [ ! -f "$OK" ] && [ ! -f "$OK.no" ]; then
  mkdir -p /tmp/forge 2>/dev/null
  if "$REAL" --unshare-all --die-with-parent --ro-bind / / true >/dev/null 2>&1; then
    : > "$OK"
  else
    : > "$OK.no"
  fi
fi
[ -f "$OK" ] && exec "$REAL" "$@"
# Unsandboxed: drop bwrap's own options, keep its --setenv, run the program.
while [ $# -gt 0 ]; do
  case "$1" in
    --setenv) export "$2=$3"; shift 3 ;;
    --unsetenv) unset "$2"; shift 2 ;;
    --bind|--bind-try|--ro-bind|--ro-bind-try|--dev-bind|--dev-bind-try|--symlink|\
    --file|--bind-data|--ro-bind-data|--chmod|--overlay-src) shift 3 ;;
    --chdir) cd "$2" 2>/dev/null; shift 2 ;;
    --dev|--proc|--tmpfs|--dir|--remount-ro|--seccomp|--add-seccomp-fd|--hostname|\
    --uid|--gid|--lock-file|--sync-fd|--info-fd|--json-status-fd|--block-fd|\
    --userns-block-fd|--userns|--userns2|--pidns|--perms|--size|--cap-add|--cap-drop|\
    --args|--mqueue|--exec-label|--file-label|--argv0|--tmp-overlay|--ro-overlay) shift 2 ;;
    --) shift; break ;;
    --*) shift ;;
    *) break ;;
  esac
done
exec "$@"
"""

AGENT_RUN = """#!/usr/bin/with-contenv bash
# Wayland webtops (LinuxServer's KDE images default to it): there is no X
# screen to manage, so only report which compositor is up.
if [[ "${PIXELFLUX_WAYLAND,,}" == "true" ]]; then
  mkdir -p /tmp/forge && chown abc:abc /tmp/forge
  while :; do
    wm=""
    for p in kwin_wayland gnome-shell mutter sway wayfire Hyprland labwc; do
      if pgrep -x "$p" >/dev/null 2>&1; then wm="$p"; break; fi
    done
    printf '{"ts": %s, "screen": "wayland", "wm": "%s", "clients": 0, "mode": "normal"}\\n' \\
      "$(date +%s)" "$wm" > /tmp/forge/health.json.tmp && mv -f /tmp/forge/health.json.tmp /tmp/forge/health.json
    sleep 3
  done
fi
exec s6-setuidgid abc /bin/bash /usr/local/share/forge/agent
"""

# Lines that run inside the session's D-Bus, just before the desktop itself:
# turn off every screen locker that would ask for a password nobody set.
PRESESSION = r"""
W=/usr/local/share/forge/wallpaper.jpg
if command -v gsettings >/dev/null 2>&1 && [ -f "$W" ]; then
  for sk in "org.gnome.desktop.background picture-uri" \
            "org.gnome.desktop.background picture-uri-dark" \
            "org.cinnamon.desktop.background picture-uri" \
            "org.mate.background picture-filename"; do
    cur=$(gsettings get $sk 2>/dev/null | tr -d "'")
    [ -n "$cur" ] || continue
    f=$(readlink -f "${cur#file://}" 2>/dev/null || echo "${cur#file://}")
    svgok=0
    ls /usr/lib/*/gdk-pixbuf-2.0/*/loaders/*svg* /usr/lib/gdk-pixbuf-2.0/*/loaders/*svg* >/dev/null 2>&1 && svgok=1
    case "$f" in *.svg) [ "$svgok" = 1 ] || f="" ;; esac
    if [ -z "$f" ] || [ ! -e "$f" ]; then
      case "$sk" in *picture-filename) gsettings set $sk "$W" ;; *) gsettings set $sk "file://$W" ;; esac
    fi
  done
fi
if command -v gsettings >/dev/null 2>&1; then
  for kv in "org.gnome.desktop.screensaver lock-enabled false" \
            "org.gnome.desktop.screensaver idle-activation-enabled false" \
            "org.gnome.desktop.session idle-delay uint32 0" \
            "org.gnome.desktop.lockdown disable-lock-screen true" \
            "org.cinnamon.desktop.screensaver lock-enabled false" \
            "org.cinnamon.desktop.session idle-delay uint32 0" \
            "org.mate.screensaver lock-enabled false" \
            "org.mate.screensaver idle-activation-enabled false" \
            "org.mate.power-manager sleep-display-ac 0" \
            "org.mate.Marco.general compositing-manager false" \
            "org.gnome.metacity compositing-manager false" \
            "org.gnome.metacity.general compositing-manager false" \
            "com.solus-project.budgie-panel dark-theme true"; do
    gsettings set $kv >/dev/null 2>&1 || true
  done
fi
"""


def supervised_session(session):
    """The tail of startwm.sh: run the session under a crash supervisor."""
    pre = PRESESSION.replace("'", "'\"'\"'")
    return r"""
S=/tmp/forge
mkdir -p "$S" 2>/dev/null
LOG="$S/session.log"
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 400000 ] && tail -n 600 "$LOG" > "$LOG.1" && mv -f "$LOG.1" "$LOG"
echo "== $(date '+%%F %%T') starting: %(session)s" >> "$LOG"
# dbus-run-session keeps the session bus alive exactly as long as the desktop.
# dbus-launch --exit-with-session watches stdin instead, and s6 starts us with
# stdin closed: on Arch (dbus 1.16) the bus is gone before the desktop starts,
# so Xfce hangs, LXQt exits and Enlightenment aborts.
if command -v dbus-run-session >/dev/null 2>&1; then
  BUS="dbus-run-session --"
else
  BUS="dbus-launch --exit-with-session"
fi
t0=$(date +%%s)
$BUS sh -c '%(pre)s
exec %(session_q)s' >> "$LOG" 2>&1
rc=$?
dt=$(( $(date +%%s) - t0 ))
echo "== $(date '+%%F %%T') session ended rc=$rc after ${dt}s" >> "$LOG"
if [ "$dt" -lt 30 ]; then
  n=$(( $(cat "$S/quick-exits" 2>/dev/null || echo 0) + 1 ))
else
  n=0
fi
echo "$n" > "$S/quick-exits"
if [ "$n" -ge 3 ] && command -v openbox-session >/dev/null 2>&1; then
  echo rescue > "$S/mode"
  echo "== $(date '+%%F %%T') crashed $n times in a row, starting the rescue session" >> "$LOG"
  ( sleep 2
    xterm -geometry 120x34+30+30 -T "Selkies Forge rescue" -e sh -c '
      echo "The desktop session (%(session_q2)s) crashed $0 times in a row.";
      echo "This is a rescue session so you can see why. Last lines of /tmp/forge/session.log:";
      echo; tail -n 40 /tmp/forge/session.log; echo;
      echo "Fix it here, then remove /tmp/forge/quick-exits and log out of openbox to retry.";
      exec bash' "$n" & ) &
  exec $BUS openbox-session >> "$LOG" 2>&1
fi
# A short pause, then s6 starts the desktop again.
sleep 2
exit "$rc"
""" % {"session": session.replace("%", "%%"), "pre": pre,
       "session_q": session.replace("'", "'\"'\"'"),
       "session_q2": session.replace("'", "").replace('"', "")}


# A quiet Selkies Forge wallpaper (1920x1080 JPEG, ~24 KB), used wherever a
# desktop's own default points at a file the base image does not ship, which
# otherwise leaves a black desktop.
WALLPAPER_B64 = """
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
mlAH/9k=
"""


def wallpaper_bytes():
    return base64.b64decode("".join(WALLPAPER_B64.split()))


# The screen guard: a few lines of JavaScript the layer puts at the top of
# Selkies' own page, so they run in the viewer's browser before Selkies does.
#
# The HiDPI bug. On any screen with a pixel ratio above 1 (phones, Retina
# laptops, a monitor scaled to 125% or 200%) Selkies sizes the desktop in
# device pixels and turns the pixel ratio into a DPI: a phone at 2.6x gets
# 264 DPI, a 4K screen at 200% gets 192. Programs that honour the DPI draw
# huge text inside panels and title bars that are sized in pixels and do not
# grow (the Xfce panel's text spills out of the bar), others stay tiny, and a
# big window runs past the 3840x2160 the forge allows Xvfb. A 4K screen at
# 100% has no such DPI, but gets a 3840x2160 desktop with unreadable text.
#
# The fix, on those screens only: Selkies' own "CSS scaling" mode, with its
# scaling DPI as a divisor. The desktop always runs at 96 DPI, so every panel
# and font agree, sized to about 1920 pixels wide (never wider than the
# screen's own pixels), and is stretched to the window. A screen at 100% that
# is smaller than 4K is left exactly as it was: the desktop follows the
# window, pixel for pixel, at 96 DPI already.
#
# It only touches what it set itself: once someone picks their own scaling in
# Selkies' menu, the guard leaves it alone, and on a smaller screen it takes
# its own settings back out.
SCREEN_GUARD = r"""/* Selkies Forge screen guard: see forge/layer.py. */
(function () {
  try {
    var ls = window.localStorage;
    var p = (location.origin + location.pathname).replace(/[^a-zA-Z0-9._-]/g, "_") + "_";
    var K = { css: p + "useCssScaling", pick: p + "useCssScaling_explicit_choice",
              dpi: p + "scaling_dpi", mark: p + "forge_screen" };
    var dpr = window.devicePixelRatio || 1;
    var w = Math.round(Math.max(screen.width, screen.height) * dpr);
    var h = Math.round(Math.min(screen.width, screen.height) * dpr);
    var mine = null;
    try { mine = JSON.parse(ls.getItem(K.mark) || "null"); } catch (e) {}
    var ours = !!mine && ls.getItem(K.css) === "true" && ls.getItem(K.dpi) === mine.dpi;
    var free = ls.getItem(K.css) === null && ls.getItem(K.dpi) === null;
    /* Selkies raises the DPI from a pixel ratio of 1.125 up (round(r*4)*24) */
    if (dpr >= 1.125 || (w >= 3200 && h >= 1800)) {
      if (!free && !ours) return;            /* the viewer chose their own scaling */
      var target = Math.min(1920, Math.max(1280, w));
      var want = 96 * w / target, dpi = 96;
      [96, 120, 144, 168, 192, 216, 240, 264, 288].forEach(function (d) {
        if (Math.abs(d - want) < Math.abs(dpi - want)) dpi = d;
      });
      ls.setItem(K.css, "true");
      ls.setItem(K.pick, "true");
      ls.setItem(K.dpi, String(dpi));
      ls.setItem(K.mark, JSON.stringify({ dpi: String(dpi), screen: w + "x" + h }));
    } else if (mine) {
      if (ours) { ls.removeItem(K.css); ls.removeItem(K.pick); ls.removeItem(K.dpi); }
      ls.removeItem(K.mark);
    }
  } catch (e) { /* storage blocked: Selkies runs as it always did */ }
})();
"""


def files(startwm=None):
    """{path in build context: (content, mode)} for the forge layer."""
    out = {
        "forge/agent": (AGENT, 0o755),
        "forge/seed": (SEED, 0o755),
        "forge/xsettingsd-run": (XSETTINGSD_RUN, 0o755),
        "forge/bwrap": (BWRAP_SHIM, 0o755),
        "forge/wallpaper.jpg": (wallpaper_bytes(), 0o644),
        "forge/screen-guard.js": (SCREEN_GUARD, 0o644),
        "s6/init-forge/type": ("oneshot\n", 0o644),
        "s6/init-forge/up": ("/usr/local/share/forge/seed\n", 0o644),
        "s6/init-forge/dependencies.d/init-config": ("", 0o644),
        "s6/svc-forge-agent/type": ("longrun\n", 0o644),
        "s6/svc-forge-agent/run": (AGENT_RUN, 0o755),
        "s6/svc-forge-agent/dependencies.d/init-services": ("", 0o644),
        "s6/svc-forge-agent/dependencies.d/svc-xorg": ("", 0o644),
    }
    if startwm:
        out["forge/startwm.sh"] = (startwm, 0o755)
        out["forge/built"] = ("built by selkies-forge\n", 0o644)
    return out


def dockerfile(base_image, label, entry_id, digest, startwm=False):
    lines = [
        "FROM %s" % base_image,
        "COPY forge/ /usr/local/share/forge/",
        "COPY s6/ /etc/s6-overlay/s6-rc.d/",
        "RUN chmod 755 /usr/local/share/forge/agent /usr/local/share/forge/seed"
        " /usr/local/share/forge/xsettingsd-run /usr/local/share/forge/bwrap"
        " /etc/s6-overlay/s6-rc.d/svc-forge-agent/run"
        " && if [ -x /usr/bin/bwrap ]; then cp -f /usr/local/share/forge/bwrap /usr/local/bin/bwrap; fi"
        " && chmod 644 /usr/local/share/forge/wallpaper.jpg /usr/local/share/forge/screen-guard.js"
        # The screen guard goes first in <head> of every Selkies page (the
        # dashboards init-nginx copies to web/ at boot, and the server's own).
        " && for f in /usr/share/selkies/*/index.html /lsiopy/lib/python3*/site-packages/selkies/selkies_web/index.html; do"
        " [ -f \"$f\" ] || continue;"
        " cp -f /usr/local/share/forge/screen-guard.js \"$(dirname \"$f\")/forge-screen.js\";"
        " grep -q forge-screen.js \"$f\" || sed -i 's|<head>|<head><script src=\"forge-screen.js\"></script>|' \"$f\" || true;"
        " done"
        " && mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d /etc/s6-overlay/s6-rc.d/svc-de/dependencies.d"
        " && touch /etc/s6-overlay/s6-rc.d/user/contents.d/init-forge"
        " /etc/s6-overlay/s6-rc.d/user/contents.d/svc-forge-agent"
        " /etc/s6-overlay/s6-rc.d/svc-de/dependencies.d/init-forge"
        " && if [ -f /etc/s6-overlay/s6-rc.d/svc-xsettingsd/run ]; then"
        " cp -f /usr/local/share/forge/xsettingsd-run /etc/s6-overlay/s6-rc.d/svc-xsettingsd/run"
        " && chmod 755 /etc/s6-overlay/s6-rc.d/svc-xsettingsd/run; fi"
        + (" && cp -f /usr/local/share/forge/startwm.sh /defaults/startwm.sh"
           " && chmod 755 /defaults/startwm.sh" if startwm else ""),
        'LABEL %s.layer="%s"' % (label, digest),
        'LABEL %s.entry="%s"' % (label, entry_id),
    ]
    return "\n".join(lines) + "\n"


def digest(base_image_id, startwm=None):
    h = hashlib.sha256()
    h.update(LAYER_VERSION.encode())
    h.update((base_image_id or "").encode())
    for path, (content, mode) in sorted(files(startwm).items()):
        h.update(path.encode())
        h.update(content if isinstance(content, bytes) else content.encode())
        h.update(str(mode).encode())
    return h.hexdigest()[:12]
