#!/usr/bin/env bash
#
#  ███████ ███████ ██      ██   ██ ██ ███████ ███████
#  ██      ██      ██      ██  ██  ██ ██      ██
#  ███████ █████   ██      █████   ██ █████   ███████
#       ██ ██      ██      ██  ██  ██ ██           ██
#  ███████ ███████ ███████ ██   ██ ██ ███████ ███████   F O R G E
#
#  One file. Installs what it needs, then runs any of 150+ Linux desktops
#  in Docker and streams them to your browser over a serveo tunnel.
#
#  Usage:
#     ./selkies-forge.sh              interactive menu
#     ./selkies-forge.sh --webui      straight to the web UI
#     ./selkies-forge.sh --cli        straight to the terminal picker
#     ./selkies-forge.sh --launch ID  forge one entry and exit
#     ./selkies-forge.sh --smart      let it choose for this machine
#     ./selkies-forge.sh --list       print the catalog
#     ./selkies-forge.sh --manager    manage running desktops
#     ./selkies-forge.sh --bg         web UI in the background, shell back
#     ./selkies-forge.sh --fg         web UI in the foreground until ctrl-c
#     ./selkies-forge.sh --stop       stop a backgrounded web UI
#     ./selkies-forge.sh --doctor     check this machine
#     ./selkies-forge.sh --uninstall  remove everything it created
#
#  MIT licensed. No telemetry, no accounts, nothing phones home except
#  docker pulls and the serveo tunnel you asked for.

set -uo pipefail

FORGE_VERSION="1.0.0"
FORGE_HOME="${FORGE_HOME:-$HOME/.selkies-forge}"
FORGE_APP="$FORGE_HOME/app"
FORGE_STATE="$FORGE_HOME/state"
FORGE_LOGS="$FORGE_HOME/logs"
FORGE_LOCK="$FORGE_STATE/forge.lock"
PY=""
ASSUME_YES=0
NO_TUNNEL=0
WEBUI_PORT="${FORGE_PORT:-8787}"
WEBUI_BIND="${FORGE_BIND:-127.0.0.1}"
WEBUI_EXPOSE=0
WEBUI_MODE=""
FORCE_EXTRACT=0

# ---------------------------------------------------------------- colours
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  COLOR=1
  NC=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'; IT=$'\033[3m'
  RED=$'\033[38;5;203m'; GRN=$'\033[38;5;79m'; YEL=$'\033[38;5;221m'
  BLU=$'\033[38;5;75m'; VIO=$'\033[38;5;141m'; CYA=$'\033[38;5;80m'
  GRY=$'\033[38;5;245m'; WHT=$'\033[38;5;255m'
  HIDE=$'\033[?25l'; SHOW=$'\033[?25h'; CLRL=$'\033[2K\r'
else
  COLOR=0
  NC=""; B=""; DIM=""; IT=""
  RED=""; GRN=""; YEL=""; BLU=""; VIO=""; CYA=""; GRY=""; WHT=""
  HIDE=""; SHOW=""; CLRL=$'\r'
fi

TRUECOLOR=0
case "${COLORTERM:-}" in
  truecolor|24bit) [ "$COLOR" = 1 ] && TRUECOLOR=1 ;;
esac

cols() { local c; c=$(tput cols 2>/dev/null || echo 80); [ "$c" -ge 20 ] 2>/dev/null || c=80; echo "$c"; }

# Blue -> violet gradient across a string.
grad() {
  local text="$1" n i r g b out=""
  n=${#text}
  if [ "$TRUECOLOR" != 1 ] || [ "$n" -eq 0 ]; then printf '%s' "${BLU}${text}${NC}"; return; fi
  for ((i = 0; i < n; i++)); do
    r=$((70 + (120 * i / (n > 1 ? n - 1 : 1))))
    g=$((150 - (40 * i / (n > 1 ? n - 1 : 1))))
    b=255
    out+=$'\033[38;2;'"${r};${g};${b}m${text:i:1}"
  done
  printf '%s%s' "$out" "$NC"
}

say()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "$DIM" "$*" "$NC"; }
ok()   { printf '  %s✔%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$NC" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$RED" "$NC" "$*"; }
info() { printf '  %s·%s %s\n' "$BLU" "$NC" "$*"; }
die()  { printf '\n  %s✘ %s%s\n\n' "$RED" "$*" "$NC" >&2; exit 1; }

rule() {
  local w c; w=$(cols); c=$((w - 4))
  [ "$c" -gt 76 ] && c=76
  [ "$c" -lt 10 ] && c=10
  printf '  %s' "$DIM"
  printf '─%.0s' $(seq 1 "$c")
  printf '%s\n' "$NC"
}

title() {
  printf '\n  %s%s%s\n' "$B$WHT" "$1" "$NC"
  [ $# -gt 1 ] && printf '  %s%s%s\n' "$DIM" "$2" "$NC"
  rule
}

# ------------------------------------------------------------------ banner
banner() {
  local w; w=$(cols)
  printf '\n'
  if [ "$w" -lt 62 ]; then
    printf '  %s  %s\n' "$(grad '▲ SELKIES FORGE')" "${DIM}v$FORGE_VERSION$NC"
    printf '  %sdesktops on tap%s\n\n' "$DIM" "$NC"
    return
  fi
  local l1='███████ ███████ ██      ██   ██ ██ ███████ ███████'
  local l2='██      ██      ██      ██  ██  ██ ██      ██     '
  local l3='███████ █████   ██      █████   ██ █████   ███████'
  local l4='     ██ ██      ██      ██  ██  ██ ██           ██'
  local l5='███████ ███████ ███████ ██   ██ ██ ███████ ███████'
  printf '  %s\n' "$(grad "$l1")"
  printf '  %s\n' "$(grad "$l2")"
  printf '  %s\n' "$(grad "$l3")"
  printf '  %s\n' "$(grad "$l4")"
  printf '  %s\n' "$(grad "$l5")"
  printf '  %s%s%s   %sF O R G E%s   %sv%s · desktops on tap%s\n\n' \
    "$DIM" "────────────────────" "$NC" "$B$VIO" "$NC" "$DIM" "$FORGE_VERSION" "$NC"
}

# ----------------------------------------------------------------- spinner
SPIN_PID=""
spin_start() {
  [ -t 1 ] || { printf '  %s...\n' "$1"; return; }
  local msg="$1"
  printf '%s' "$HIDE"
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while :; do
      i=$(((i + 1) % 10))
      printf '%s  %s%s%s %s' "$CLRL" "$BLU" "${frames:i:1}" "$NC" "$msg"
      sleep 0.08
    done
  ) &
  SPIN_PID=$!
}

spin_stop() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null
  wait "$SPIN_PID" 2>/dev/null
  SPIN_PID=""
  printf '%s%s' "$CLRL" "$SHOW"
}

cleanup() { spin_stop; printf '%s' "$SHOW"; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------ progress bar
# bar <pct> <label>
bar() {
  [ -t 1 ] || return 0
  local pct="${1:-0}" label="${2:-}" w bw filled i out=""
  w=$(cols)
  bw=$((w - 34)); [ "$bw" -lt 10 ] && bw=10; [ "$bw" -gt 46 ] && bw=46
  filled=$((pct * bw / 100))
  [ "$filled" -gt "$bw" ] && filled=$bw
  [ "$filled" -lt 0 ] && filled=0
  for ((i = 0; i < bw; i++)); do
    if [ "$i" -lt "$filled" ]; then
      if [ "$TRUECOLOR" = 1 ]; then
        out+=$'\033[38;2;'"$((80 + 110 * i / bw));$((150 - 30 * i / bw));255m█"
      else
        out+="${BLU}█"
      fi
    else
      out+="${DIM}░"
    fi
  done
  printf '%s  %s%s %s%3d%%%s  %s%-24.24s%s' "$CLRL" "$out" "$NC" "$B" "$pct" "$NC" "$DIM" "$label" "$NC"
}

# ------------------------------------------------------------------ prompts
ask() {  # ask <prompt> <default>
  local p="$1" d="${2:-}" r
  if [ ! -t 0 ]; then printf '%s' "$d"; return; fi
  if [ -n "$d" ]; then
    read -r -p "  $(printf '%s%s%s %s[%s]%s ' "$B" "$p" "$NC" "$DIM" "$d" "$NC")" r
  else
    read -r -p "  $(printf '%s%s%s ' "$B" "$p" "$NC")" r
  fi
  printf '%s' "${r:-$d}"
}

confirm() {  # confirm <prompt> <default y|n>
  local p="$1" d="${2:-n}" r
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ ! -t 0 ]; then [ "$d" = "y" ]; return $?; fi
  read -r -p "  $(printf '%s%s%s %s(%s)%s ' "$B" "$p" "$NC" "$DIM" "$([ "$d" = y ] && echo 'Y/n' || echo 'y/N')" "$NC")" r
  r="${r:-$d}"
  case "$r" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# -------------------------------------------------------------- arrow menu
# menu_choose <title> <array name of "value<TAB>label<TAB>hint">
# echoes the chosen value on stdout, returns 1 if cancelled.
MENU_RESULT=""
menu_choose() {
  local title="$1"; shift
  local -a items=("$@")
  local n=${#items[@]}
  [ "$n" -eq 0 ] && return 1
  MENU_RESULT=""

  # Callers read the answer with $(...), so every pixel of the menu goes to
  # the terminal directly and only the chosen value lands on stdout.
  local UI="/dev/stderr"
  [ -w /dev/tty ] && UI="/dev/tty"
  local interactive=0
  { [ -r /dev/tty ] && [ -t 1 ] || [ -t 0 ]; } && interactive=1

  if [ "$interactive" != 1 ]; then
    local i=1
    printf '\n  %s%s%s\n' "$B" "$title" "$NC" >"$UI"
    for it in "${items[@]}"; do
      printf '   %2d) %s\n' "$i" "$(printf '%s' "$it" | cut -f2)" >"$UI"
      i=$((i + 1))
    done
    local pick; read -r -p "  number: " pick
    [ -z "$pick" ] && return 1
    [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$n" ] || return 1
    MENU_RESULT=$(printf '%s' "${items[$((pick - 1))]}" | cut -f1)
    printf '%s' "$MENU_RESULT"
    return 0
  fi

  local sel=0 top=0 page rows key
  rows=$(tput lines 2>/dev/null || echo 24)
  page=$((rows - 9)); [ "$page" -lt 5 ] && page=5; [ "$page" -gt 16 ] && page=16
  [ "$page" -gt "$n" ] && page=$n

  exec 9<>/dev/tty 2>/dev/null || exec 9<&0
  printf '%s' "$HIDE" >"$UI"
  local drawn=0
  while :; do
    [ "$drawn" -gt 0 ] && printf '\033[%dA' "$drawn" >"$UI"
    drawn=0
    printf '%s  %s%s%s\n' "$CLRL" "$B$WHT" "$title" "$NC" >"$UI"; drawn=$((drawn + 1))
    printf '%s  %s↑↓ move · enter choose · q back%s\n' "$CLRL" "$DIM" "$NC" >"$UI"; drawn=$((drawn + 1))
    local i
    for ((i = top; i < top + page && i < n; i++)); do
      local lab hint
      lab=$(printf '%s' "${items[$i]}" | cut -f2)
      hint=$(printf '%s' "${items[$i]}" | cut -f3)
      if [ "$i" -eq "$sel" ]; then
        printf '%s  %s❯%s %s%-34.34s%s %s%s%s\n' "$CLRL" "$VIO" "$NC" "$B$WHT" "$lab" "$NC" "$CYA" "$hint" "$NC" >"$UI"
      else
        printf '%s    %s%-34.34s%s %s%s%s\n' "$CLRL" "$NC" "$lab" "$NC" "$DIM" "$hint" "$NC" >"$UI"
      fi
      drawn=$((drawn + 1))
    done
    printf '%s  %s%d of %d%s\n' "$CLRL" "$DIM" "$((sel + 1))" "$n" "$NC" >"$UI"; drawn=$((drawn + 1))

    IFS= read -rsn1 key <&9 || { printf '%s' "$SHOW" >"$UI"; exec 9<&-; return 1; }
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 0.05 key2 <&9 || key2=""
        case "$key2" in
          '[A') sel=$((sel > 0 ? sel - 1 : n - 1)) ;;
          '[B') sel=$((sel < n - 1 ? sel + 1 : 0)) ;;
          '[5') IFS= read -rsn1 -t 0.05 _ <&9; sel=$((sel - page)); [ "$sel" -lt 0 ] && sel=0 ;;
          '[6') IFS= read -rsn1 -t 0.05 _ <&9; sel=$((sel + page)); [ "$sel" -ge "$n" ] && sel=$((n - 1)) ;;
          '[H') sel=0 ;;
          '[F') sel=$((n - 1)) ;;
          '') printf '%s' "$SHOW" >"$UI"; exec 9<&-; return 1 ;;
        esac
        ;;
      k) sel=$((sel > 0 ? sel - 1 : n - 1)) ;;
      j) sel=$((sel < n - 1 ? sel + 1 : 0)) ;;
      g) sel=0 ;;
      G) sel=$((n - 1)) ;;
      q|Q) printf '%s\n' "$SHOW" >"$UI"; exec 9<&-; return 1 ;;
      "") MENU_RESULT=$(printf '%s' "${items[$sel]}" | cut -f1)
          printf '%s\n' "$SHOW" >"$UI"; exec 9<&-
          printf '%s' "$MENU_RESULT"; return 0 ;;
    esac
    if [ "$sel" -lt "$top" ]; then top=$sel; fi
    if [ "$sel" -ge $((top + page)) ]; then top=$((sel - page + 1)); fi
  done
}

# ------------------------------------------------------------ privileges
SUDO=""
need_root() {
  if [ "$(id -u)" = "0" ]; then SUDO=""; return 0; fi
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; return 0; fi
  return 1
}

run_root() {
  if [ -z "$SUDO" ]; then "$@"; else $SUDO "$@"; fi
}

# ----------------------------------------------------------- package mgmt
PKG=""
detect_pkg() {
  for p in apt-get dnf yum pacman apk zypper brew; do
    if command -v "$p" >/dev/null 2>&1; then PKG="$p"; return 0; fi
  done
  PKG=""
  return 1
}

pkg_refresh() {
  case "$PKG" in
    apt-get) run_root apt-get update -qq ;;
    apk) run_root apk update >/dev/null ;;
    pacman) run_root pacman -Sy --noconfirm >/dev/null ;;
    *) : ;;
  esac
}

pkg_install() {
  case "$PKG" in
    apt-get) DEBIAN_FRONTEND=noninteractive run_root apt-get install -y -qq "$@" ;;
    dnf) run_root dnf install -y "$@" ;;
    yum) run_root yum install -y "$@" ;;
    pacman) run_root pacman -S --noconfirm --needed "$@" ;;
    apk) run_root apk add --no-cache "$@" ;;
    zypper) run_root zypper --non-interactive install "$@" ;;
    brew) brew install "$@" ;;
    *) return 1 ;;
  esac
}

pkg_has() {
  case "$PKG" in
    apt-get) apt-cache show "$1" >/dev/null 2>&1 ;;
    dnf) dnf -q list "$1" >/dev/null 2>&1 ;;
    yum) yum -q list "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
    apk) apk info "$1" >/dev/null 2>&1 ;;
    zypper) zypper -q info "$1" >/dev/null 2>&1 ;;
    brew) brew info "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# -------------------------------------------------------------- python
python_ver_ok() {  # >= 3.8
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null
}

find_python() {
  local c
  for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
    if command -v "$c" >/dev/null 2>&1 && python_ver_ok "$c"; then
      PY=$(command -v "$c")
      return 0
    fi
  done
  return 1
}

install_python() {
  title "Python" "needed to run the forge engine, standard library only"
  if find_python; then
    ok "found $($PY --version 2>&1) at $PY"
    return 0
  fi
  warn "no usable Python 3.8+ on this machine"
  detect_pkg || die "no supported package manager found; install Python 3 yourself and re-run"
  need_root || die "need root (or sudo) to install Python"
  confirm "Install Python 3 with $PKG?" y || die "cannot continue without Python 3"
  spin_start "installing the newest Python $PKG offers"
  pkg_refresh >/dev/null 2>&1
  local cand installed=0
  # Take the newest interpreter this distro actually packages.
  for cand in python3.14 python3.13 python3.12 python3.11 python3; do
    if pkg_has "$cand" >/dev/null 2>&1; then
      if pkg_install "$cand" >/dev/null 2>&1; then installed=1; break; fi
    fi
  done
  [ "$installed" = 1 ] || pkg_install python3 >/dev/null 2>&1
  spin_stop
  find_python || die "Python install did not take; install python3 yourself and re-run"
  ok "installed $($PY --version 2>&1)"
}

# -------------------------------------------------------------- docker
docker_usable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

install_docker() {
  title "Docker" "every desktop runs as a container"
  if docker_usable; then
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) is up"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    warn "docker is installed but not answering"
    if [ -S /var/run/docker.sock ] && ! docker info >/dev/null 2>&1; then
      if need_root; then
        info "trying to start the docker service"
        run_root systemctl start docker >/dev/null 2>&1 || run_root service docker start >/dev/null 2>&1
        sleep 2
      fi
    fi
    if docker_usable; then ok "docker is up now"; return 0; fi
    if ! groups 2>/dev/null | grep -qw docker; then
      warn "you are not in the 'docker' group"
      if need_root && confirm "Add $USER to the docker group?" y; then
        run_root usermod -aG docker "$USER" 2>/dev/null
        warn "log out and back in (or run: newgrp docker) and re-run this script"
        exit 1
      fi
    fi
    die "docker is not usable: $(docker info 2>&1 | head -1)"
  fi

  warn "docker is not installed"
  need_root || die "need root (or sudo) to install Docker"
  confirm "Install Docker now?" y || die "cannot continue without Docker"
  detect_pkg
  case "$PKG" in
    apk)
      spin_start "installing docker with apk"
      pkg_install docker docker-cli docker-engine >/dev/null 2>&1
      run_root rc-update add docker default >/dev/null 2>&1
      run_root service docker start >/dev/null 2>&1
      spin_stop
      ;;
    pacman)
      spin_start "installing docker with pacman"
      pkg_install docker >/dev/null 2>&1
      run_root systemctl enable --now docker >/dev/null 2>&1
      spin_stop
      ;;
    brew)
      die "install Docker Desktop for Mac yourself, then re-run"
      ;;
    *)
      command -v curl >/dev/null 2>&1 || pkg_install curl >/dev/null 2>&1
      spin_start "running the official Docker install script (this takes a few minutes)"
      curl -fsSL https://get.docker.com -o "$FORGE_STATE/get-docker.sh" 2>/dev/null
      if [ -s "$FORGE_STATE/get-docker.sh" ]; then
        run_root sh "$FORGE_STATE/get-docker.sh" >"$FORGE_LOGS/docker-install.log" 2>&1
      fi
      spin_stop
      run_root systemctl enable --now docker >/dev/null 2>&1
      ;;
  esac

  if ! docker_usable; then
    if command -v docker >/dev/null 2>&1 && need_root; then
      run_root usermod -aG docker "$USER" 2>/dev/null
      warn "docker installed, but your shell is not in the docker group yet"
      warn "run:  newgrp docker    (or log out and back in), then re-run this script"
      exit 1
    fi
    die "docker install failed, see $FORGE_LOGS/docker-install.log"
  fi
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) installed"
}

install_extras() {
  local missing=()
  command -v ssh >/dev/null 2>&1 || missing+=(ssh)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  [ ${#missing[@]} -eq 0 ] && return 0
  detect_pkg || return 0
  need_root || return 0
  title "Extras" "${missing[*]} needed for tunnels and downloads"
  confirm "Install ${missing[*]}?" y || return 0
  local pkgs=()
  for m in "${missing[@]}"; do
    case "$m:$PKG" in
      ssh:apt-get) pkgs+=(openssh-client) ;;
      ssh:apk) pkgs+=(openssh-client) ;;
      ssh:*) pkgs+=(openssh-clients) ;;
      curl:*) pkgs+=(curl) ;;
    esac
  done
  spin_start "installing ${pkgs[*]}"
  pkg_install "${pkgs[@]}" >/dev/null 2>&1
  spin_stop
  ok "extras installed"
}

# =========================================================================
#  embedded payload: the engine and the web UI, written out on first run
# =========================================================================

FORGE_SHA_CATALOG_PY="c6723f6eddedba50f4aef0efc768a2b37770508ef7d71f2e3da1677ca47ef4de"
FORGE_SHA_ENGINE_PY="092ec3006f6c7e17b06ac12c5feedee66d5ab61254c280b9289f2e4d69c844c7"
FORGE_SHA_INDEX_HTML="9478e1fdaf4df021dd6900610f19c6b2ead6fed6e4a2a03dba0a02effcaa88a6"
FORGE_SHA_APP_CSS="ab1899039cc0d47d1a0a8bda2a9c162be222edf8cffb1b396177c6c9b0575577"
FORGE_SHA_APP_JS="4e6723ba448447fd8ff07ea4d5118b73a92123a86ae86a5da7f1c9888a16f520"
FORGE_SHA_TERM_JS="4562ca565db85e10c43c0ca7c7cf33f3726acb2f5b2b1e92f29d6137f7c99e41"
FORGE_SHA_LOGOS_JS="7d210251df9e2bfca5c2caaf07377042219f18650c7ca97149d4218c29d8bbaa"
FORGE_PAYLOAD_SHA="d8e0ca28caca5641a9fcdd50cb0f58fbe94a7185c7e8046cb49cbff5e3dae093"

# Writes the engine and UI into $FORGE_APP, but only when they changed.
extract_payload() {
  local stamp="$FORGE_APP/.payload"
  if [ "${FORCE_EXTRACT:-0}" != "1" ] && [ -f "$stamp" ] && \
     [ "$(cat "$stamp" 2>/dev/null)" = "$FORGE_PAYLOAD_SHA" ]; then
    return 0
  fi
  mkdir -p "$FORGE_APP"
  cat > "$FORGE_APP/catalog.py" <<'__FORGE_FILE_CATALOG_PY__'
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
        apk=dict(pkgs="xfce4 xfce4-terminal thunar xfce4-screensaver mousepad",
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
        apt=dict(pkgs="kde-plasma-desktop konsole dolphin kate",
                 session="startplasma-x11",
                 pre=['[ -f "$HOME/.config/kwinrc" ] || kwriteconfig6 --file "$HOME/.config/kwinrc" '
                      '--group Compositing --key Enabled false 2>/dev/null || true',
                      '[ -f "$HOME/.config/kscreenlockerrc" ] || kwriteconfig6 --file '
                      '"$HOME/.config/kscreenlockerrc" --group Daemon --key Autolock false '
                      '2>/dev/null || true',
                      'touch "$HOME/.local/share/user-places.xbel" 2>/dev/null || true']),
        dnf=dict(pkgs="plasma-desktop plasma-workspace-x11 konsole dolphin kwin-x11 "
                      "plasma-nm breeze-gtk", session="startplasma-x11"),
        pacman=dict(pkgs="plasma-desktop plasma-workspace konsole dolphin kwin",
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
        beauty=90, speed=66, term="gnome-terminal",
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
        beauty=91, speed=70, term="gnome-terminal",
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
        beauty=80, speed=74, term="gnome-terminal",
        blurb="GNOME's classic layout on Metacity. Works where real GNOME can't.",
        apt=dict(pkgs="gnome-session-flashback gnome-terminal nautilus metacity",
                 session="gnome-session --session=gnome-flashback-metacity"),
    ),
    "enlightenment": dict(
        label="Enlightenment", glyph="enlightenment", klass="light", idle=300, add_dl=240,
        beauty=82, speed=84, term="terminology",
        blurb="Animated, glossy, unlike anything else. A cult favourite.",
        apt=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
        dnf=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
        pacman=dict(pkgs="enlightenment terminology", session="enlightenment_start"),
    ),
    "i3": dict(
        label="i3", glyph="i3", klass="feather", idle=120, add_dl=120,
        beauty=68, speed=98, term="xterm", bare=True,
        blurb="Tiling, keyboard-driven, ruthlessly efficient.",
        apt=dict(pkgs="i3 i3status i3lock dmenu rofi xterm feh", session="i3"),
        dnf=dict(pkgs="i3 i3status i3lock dmenu rofi xterm feh", session="i3"),
        pacman=dict(pkgs="i3-wm i3status i3lock dmenu rofi xterm feh", session="i3"),
        apk=dict(pkgs="i3wm i3status i3lock dmenu xterm feh", session="i3"),
    ),
    "openbox": dict(
        label="Openbox", glyph="openbox", klass="feather", idle=110, add_dl=100,
        beauty=60, speed=98, term="xterm", bare=True,
        blurb="A window manager and nothing else. Yours to decorate.",
        apt=dict(pkgs="openbox obconf tint2 xterm feh nitrogen lxappearance",
                 session="openbox-session"),
        dnf=dict(pkgs="openbox obconf tint2 xterm feh", session="openbox-session"),
        pacman=dict(pkgs="openbox obconf tint2 xterm feh nitrogen", session="openbox-session"),
        apk=dict(pkgs="openbox obconf tint2 xterm feh", session="openbox-session"),
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
        apt=dict(pkgs="herbstluftwm xterm feh dmenu", session="herbstluftwm"),
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
        apt=dict(pkgs="xmonad libghc-xmonad-contrib-dev xterm feh dmenu", session="xmonad"),
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
        apt=dict(pkgs="spectrwm xterm feh dmenu", session="spectrwm"),
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
        beauty=79, speed=73, term="mate-terminal",
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
             "icewm", "jwm", "awesome", "bspwm", "herbstluftwm", "qtile",
             "xmonad", "pekwm", "wmaker", "fvwm3", "lumina", "ukui"]),
    "bookworm": dict(
        image="lscr.io/linuxserver/baseimage-selkies:debianbookworm", pm="apt",
        family="debian", distro="Debian 12", code="Bookworm",
        dl=912, arches=BOTH, polish=78,
        note="Boring on purpose. Nothing moves until you move it.",
        des=["xfce", "mate", "kde", "lxqt", "lxde", "cinnamon", "budgie",
             "gnome-flashback", "enlightenment", "i3", "openbox", "fluxbox",
             "icewm", "jwm", "awesome", "bspwm", "herbstluftwm", "qtile",
             "xmonad", "pekwm", "wmaker", "fvwm3", "dwm", "spectrwm", "cwm",
             "ratpoison", "twm", "lumina"]),
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
             "awesome", "bspwm", "herbstluftwm", "qtile", "xmonad", "wmaker"]),
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
               "python3-pip python3-venv nodejs npm yaru-theme-gtk papirus-icon-theme",
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


def _recipe(base_key, de_key):
    """Return the install recipe for a desktop on a base, or None."""
    base = BASES[base_key]
    de = DESKTOPS[de_key]
    spec = de.get(base["pm"])
    if not spec:
        return None
    return dict(image=base["image"], pm=base["pm"], pkgs=spec["pkgs"],
                session=spec["session"], pre=list(spec.get("pre", [])),
                env=list(spec.get("env", [])), bare=bool(de.get("bare")),
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
            glyph=de["glyph"], kind="pull",
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
__FORGE_FILE_CATALOG_PY__
  cat > "$FORGE_APP/engine.py" <<'__FORGE_FILE_ENGINE_PY__'
#!/usr/bin/env python3
"""
Selkies Forge engine.

Stdlib only, on purpose: the installer should never have to touch pip.

  engine.py serve            start the web UI
  engine.py list             print the catalog as json
  engine.py launch <id>      build/pull, run, tunnel, report
  engine.py smart            recommend something for this machine
  engine.py instances        what is running
  engine.py doctor           check the host
"""

import argparse
import base64
import errno
import fcntl
import hashlib
import json
import os
import pty
import random
import re
import select
import shlex
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog  # noqa: E402

VERSION = "1.0.0"
APPDIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("FORGE_HOME") or os.path.join(os.path.expanduser("~"), ".selkies-forge")
STATE = os.path.join(ROOT, "state")
LOGDIR = os.path.join(ROOT, "logs")
BUILDDIR = os.path.join(ROOT, "builds")
INSTANCES_JSON = os.path.join(STATE, "instances.json")
PORTS_JSON = os.path.join(STATE, "ports.json")
CACHE_JSON = os.path.join(STATE, "cache.json")
TOKEN_FILE = os.path.join(STATE, "token")
SSH_KEY = os.path.join(STATE, "serveo_key")

LABEL = "io.selkiesforge"
CPREFIX = "forge-"
IPREFIX = "selkies-forge/"
PORT_LO, PORT_HI = 31000, 44000
SELKIES_HTTP, SELKIES_HTTPS, KASM_HTTPS = 3000, 3001, 6901

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")


# ===========================================================================
# small utilities
# ===========================================================================

def ensure_dirs():
    for d in (ROOT, STATE, LOGDIR, BUILDDIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


class FileLock(object):
    """Cross-process lock so two Forges never allocate the same port."""

    def __init__(self, name, timeout=30.0):
        ensure_dirs()
        self.path = os.path.join(STATE, name + ".lock")
        self.timeout = timeout
        self.fh = None

    def __enter__(self):
        self.fh = open(self.path, "a+")
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except (IOError, OSError):
                if time.time() > deadline:
                    raise RuntimeError("timed out waiting for lock %s" % self.path)
                time.sleep(0.05)

    def __exit__(self, *a):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        finally:
            self.fh.close()
            self.fh = None


def jload(path, default=None):
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except Exception:
        return {} if default is None else default


def jsave(path, obj):
    ensure_dirs()
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def run(cmd, timeout=60, env=None):
    """Return (rc, stdout, stderr); never raises for a non-zero exit."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout


def have(prog):
    return shutil.which(prog) is not None


def human(n, unit="B"):
    n = float(n or 0)
    for suf in ("", "K", "M", "G", "T"):
        if abs(n) < 1024.0:
            return "%.0f%s%s" % (n, suf, unit) if suf == "" else "%.1f%s%s" % (n, suf, unit)
        n /= 1024.0
    return "%.1fP%s" % (n, unit)


def human_mb(mb):
    mb = float(mb or 0)
    if mb >= 1024:
        return "%.1f GB" % (mb / 1024.0)
    return "%d MB" % int(mb)


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def slug(s):
    s = re.sub(r"[^a-zA-Z0-9]+", "-", str(s).lower()).strip("-")
    return s or "x"


def cache_get(key, max_age):
    c = jload(CACHE_JSON, {})
    e = c.get(key)
    if isinstance(e, dict) and time.time() - e.get("t", 0) < max_age:
        return e.get("v")
    return None


def cache_put(key, value):
    with FileLock("cache"):
        c = jload(CACHE_JSON, {})
        c[key] = {"t": time.time(), "v": value}
        jsave(CACHE_JSON, c)


# ===========================================================================
# host facts
# ===========================================================================

_ARCH_MAP = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64",
             "arm64": "arm64", "armv7l": "arm", "armv6l": "arm"}


def meminfo():
    out = {"total_mb": 0, "avail_mb": 0, "swap_mb": 0}
    try:
        with open("/proc/meminfo") as fh:
            vals = {}
            for line in fh:
                k, _, v = line.partition(":")
                vals[k.strip()] = v.strip()

            def mb(key):
                try:
                    return int(vals.get(key, "0").split()[0]) // 1024
                except Exception:
                    return 0
            out["total_mb"] = mb("MemTotal")
            out["avail_mb"] = mb("MemAvailable") or mb("MemFree")
            out["swap_mb"] = mb("SwapTotal")
    except Exception:
        pass
    return out


def docker_root():
    rc, out, _ = run(["docker", "info", "--format", "{{.DockerRootDir}}"], timeout=25)
    p = out.strip()
    return p if rc == 0 and p and os.path.isdir(p) else "/var/lib/docker"


def host_info(fresh=False):
    cached = None if fresh else cache_get("host", 20)
    if cached:
        return cached

    mem = meminfo()
    try:
        load1 = os.getloadavg()[0]
    except Exception:
        load1 = 0.0
    cpus = os.cpu_count() or 1

    info = {
        "arch": _ARCH_MAP.get(os.uname().machine, os.uname().machine),
        "machine": os.uname().machine,
        "kernel": os.uname().release,
        "hostname": socket.gethostname(),
        "cpus": cpus,
        "load1": round(load1, 2),
        "cpu_free": round(max(0.0, cpus - load1), 2),
        "mem_total_mb": mem["total_mb"],
        "mem_avail_mb": mem["avail_mb"],
        "swap_mb": mem["swap_mb"],
        "docker": False,
        "docker_version": None,
        "storage_driver": None,
        "backing_fs": None,
        "quota_support": False,
        "cgroup": None,
        "disk_total_mb": 0,
        "disk_free_mb": 0,
        "docker_root": None,
        "os_pretty": None,
        "ssh": have("ssh"),
        "has_dri": os.path.exists("/dev/dri"),
        "python": "%d.%d.%d" % sys.version_info[:3],
    }

    try:
        with open("/etc/os-release") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    info["os_pretty"] = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass

    rc, out, _ = run(["docker", "version", "--format",
                      "{{.Server.Version}}|{{.Server.Arch}}"], timeout=25)
    if rc == 0 and "|" in out:
        ver, arch = out.strip().split("|", 1)
        info["docker"] = True
        info["docker_version"] = ver
        if arch.strip():
            info["arch"] = _ARCH_MAP.get(arch.strip(), arch.strip())

    rc, out, _ = run(["docker", "info", "--format",
                      "{{.Driver}}|{{.CgroupVersion}}|{{.DockerRootDir}}|{{json .DriverStatus}}"],
                     timeout=30)
    if rc == 0 and "|" in out:
        parts = out.strip().split("|", 3)
        info["storage_driver"] = parts[0]
        info["cgroup"] = parts[1] if len(parts) > 1 else None
        info["docker_root"] = parts[2] if len(parts) > 2 else None
        try:
            for k, v in json.loads(parts[3]):
                if k == "Backing Filesystem":
                    info["backing_fs"] = v
        except Exception:
            pass

    # A hard per-container disk cap only exists on xfs with project quotas,
    # or on btrfs/devicemapper.  Everywhere else the cap is advisory.
    drv = (info["storage_driver"] or "").lower()
    fs = (info["backing_fs"] or "").lower()
    info["quota_support"] = bool(
        (drv == "overlay2" and "xfs" in fs) or drv in ("btrfs", "devicemapper", "zfs"))

    root = info["docker_root"] or docker_root()
    try:
        du = shutil.disk_usage(root if os.path.isdir(root) else "/")
        info["disk_total_mb"] = du.total // (1024 * 1024)
        info["disk_free_mb"] = du.free // (1024 * 1024)
    except Exception:
        pass

    cache_put("host", info)
    return info


# ===========================================================================
# docker helpers
# ===========================================================================

def docker_ok():
    rc, _, err = run(["docker", "info", "--format", "{{.ID}}"], timeout=30)
    return rc == 0, err.strip()


def image_present(image):
    rc, _, _ = run(["docker", "image", "inspect", image], timeout=30)
    return rc == 0


def image_disk_mb(image):
    rc, out, _ = run(["docker", "image", "inspect", image, "--format", "{{.Size}}"], timeout=30)
    if rc == 0 and out.strip().isdigit():
        return int(out.strip()) // (1024 * 1024)
    return 0


def manifest_probe(image, fallback_arches=None):
    """(arches, download_mb_for_this_host).  Cached for a day."""
    key = "mani:" + image
    hit = cache_get(key, 86400)
    if hit:
        return hit.get("arches") or list(fallback_arches or []), hit.get("dl_mb") or 0

    arches, dl_mb = [], 0
    rc, out, _ = run(["docker", "manifest", "inspect", "--verbose", image], timeout=60)
    if rc == 0 and out.strip():
        try:
            data = json.loads(out)
            if isinstance(data, dict):
                data = [data]
            host_arch = host_info().get("arch")
            for item in data:
                plat = ((item.get("Descriptor") or {}).get("platform") or {})
                arch = plat.get("architecture")
                if not arch or arch == "unknown" or plat.get("os") not in (None, "linux"):
                    continue
                if arch not in arches:
                    arches.append(arch)
                if arch == host_arch:
                    man = item.get("SchemaV2Manifest") or item.get("OCIManifest") or {}
                    layers = man.get("layers") or []
                    tot = sum(int(l.get("size") or 0) for l in layers)
                    if tot:
                        dl_mb = tot // (1024 * 1024)
        except Exception:
            pass

    if not arches:
        arches = list(fallback_arches or [])
    cache_put(key, {"arches": arches, "dl_mb": dl_mb})
    return arches, dl_mb


_SIZE_UNITS = {"b": 1, "kb": 1024, "mb": 1024 ** 2, "gb": 1024 ** 3, "tb": 1024 ** 4,
               "kib": 1024, "mib": 1024 ** 2, "gib": 1024 ** 3}


def parse_size(txt):
    m = re.match(r"\s*([\d.]+)\s*([a-zA-Z]+)\s*$", txt or "")
    if not m:
        return 0
    try:
        return int(float(m.group(1)) * _SIZE_UNITS.get(m.group(2).lower(), 1))
    except Exception:
        return 0


class PullProgress(object):
    """Turns `docker pull` chatter into one number between 0 and 1."""

    LAYER = re.compile(r"^([0-9a-f]{6,}):\s+(.*)$")
    BYTES = re.compile(r"\[[=>\s]*\]\s+([\d.]+\s*[a-zA-Z]+)\s*/\s*([\d.]+\s*[a-zA-Z]+)")

    def __init__(self):
        self.layers = {}
        self.done = False

    def feed(self, line):
        line = ANSI_RE.sub("", line).strip()
        if not line:
            return None
        if line.startswith("Status:") or line.startswith("Digest:"):
            if line.startswith("Status:"):
                self.done = True
            return None
        m = self.LAYER.match(line)
        if not m:
            return None
        lid, rest = m.group(1), m.group(2)
        st = self.layers.setdefault(lid, {"phase": "wait", "cur": 0, "total": 0,
                                          "ex_cur": 0, "ex_total": 0})
        low = rest.lower()

        if "already exists" in low or "pull complete" in low:
            st["phase"] = "done"
        elif "extracting" in low:
            st["phase"] = "extract"
        elif "download complete" in low or "verifying" in low:
            st["phase"] = "downloaded"
        elif "downloading" in low:
            st["phase"] = "download"
        elif "waiting" in low or "pulling fs layer" in low:
            st["phase"] = "wait"

        # Download and unpack both report bytes; keep them in separate buckets
        # so the headline "x of y downloaded" never walks backwards.
        b = self.BYTES.search(rest)
        if b:
            cur, total = parse_size(b.group(1)), parse_size(b.group(2))
            if st["phase"] == "extract":
                st["ex_cur"], st["ex_total"] = cur, max(st["ex_total"], total)
            else:
                st["cur"], st["total"] = cur, max(st["total"], total)
        if st["phase"] in ("downloaded", "extract", "done") and st["total"]:
            st["cur"] = st["total"]
        return lid

    def fraction(self):
        if not self.layers:
            return 0.0
        if self.done:
            return 1.0
        # Downloading is 75% of the work of a layer, unpacking the rest.
        num = den = 0.0
        for st in self.layers.values():
            w = float(st["total"] or 40 * 1024 * 1024)
            den += w
            ph = st["phase"]
            if ph == "done":
                num += w
            elif ph == "extract":
                frac = (st["ex_cur"] / float(st["ex_total"])) if st["ex_total"] else 0.5
                num += w * (0.75 + 0.25 * clamp(frac, 0, 1))
            elif ph == "downloaded":
                num += w * 0.75
            elif ph == "download":
                frac = (st["cur"] / float(st["total"])) if st["total"] else 0.0
                num += w * 0.75 * clamp(frac, 0, 1)
        return clamp(num / den if den else 0.0, 0.0, 0.999)

    def summary(self):
        cur = sum(s["cur"] for s in self.layers.values())
        tot = sum(s["total"] for s in self.layers.values())
        done = sum(1 for s in self.layers.values() if s["phase"] == "done")
        return {"layers": len(self.layers), "layers_done": done,
                "bytes": cur, "bytes_total": tot}


# ===========================================================================
# the smart chooser
# ===========================================================================

#                    ram   cpu  disk beauty speed ready small
TASTES = {
    "beautiful": dict(ram=0.85, cpu=0.45, disk=0.35, beauty=3.60, speed=0.20,
                      ready=0.30, small=0.05),
    "balanced": dict(ram=1.20, cpu=0.90, disk=0.60, beauty=1.20, speed=1.00,
                     ready=0.70, small=0.50),
    "lightest": dict(ram=1.50, cpu=1.00, disk=1.00, beauty=0.25, speed=1.40,
                     ready=0.50, small=1.60),
    "fastest": dict(ram=1.30, cpu=1.20, disk=0.60, beauty=0.30, speed=2.00,
                    ready=1.00, small=0.90),
}

TASTE_BLURB = {
    "beautiful": "look first, within what the box can actually run",
    "balanced": "an even trade between looks and lightness",
    "lightest": "smallest footprint that is still pleasant",
    "fastest": "lowest latency over the stream, pull over build",
}

PURPOSE_TAGS = {
    "general": {},
    "dev": {"curated": 0.25, "ubuntu": 0.2, "xfce": 0.1},
    "security": {"kali": 0.9, "parrot": 0.8, "remnux": 0.5},
    "retro": {"feather": 0.5, "icewm": 0.3, "fluxbox": 0.3, "twm": 0.4, "wmaker": 0.4},
    "media": {"kde": 0.4, "ubuntu": 0.2, "curated": 0.2},
}


def _fit_curve(need, have_, comfort=0.45):
    """1.0 when `need` is a small slice of `have_`, falling off as it crowds it."""
    if have_ <= 0:
        return 0.0
    r = float(need) / float(have_)
    if r <= comfort:
        return 1.0
    if r >= 1.0:
        return 0.04
    return clamp(1.0 - ((r - comfort) / (1.0 - comfort)) ** 1.35, 0.04, 1.0)


def score_entry(e, host, prefs):
    """Return (score, factors, blockers). Score is 0-100."""
    w = dict(TASTES[prefs.get("taste", "balanced")])
    blockers = []

    if host["arch"] not in e["arches"]:
        blockers.append("no %s image" % host["arch"])
    if e["ram_min"] > host["mem_avail_mb"] * 0.85:
        blockers.append("needs %s RAM, only %s free" % (human_mb(e["ram_min"]),
                                                        human_mb(host["mem_avail_mb"])))
    if e["disk_mb"] + 1024 > host["disk_free_mb"]:
        blockers.append("needs %s disk" % human_mb(e["disk_mb"]))
    if e["kind"] == "build" and not prefs.get("allow_build", True):
        blockers.append("building is switched off")
    if prefs.get("max_dl_mb") and e["dl_mb"] > prefs["max_dl_mb"]:
        blockers.append("download over %s" % human_mb(prefs["max_dl_mb"]))

    f = {}
    f["ram"] = _fit_curve(e["ram_rec"], host["mem_avail_mb"], 0.40)
    # Momentary load shouldn't disqualify every heavy desktop, so treat at
    # least half the box as available.
    cpu_room = max(host["cpu_free"], host["cpus"] * 0.5, 0.5)
    f["cpu"] = _fit_curve(e["cpu_rec"], cpu_room, 0.60)
    f["disk"] = _fit_curve(e["disk_mb"] + 2048, max(1, host["disk_free_mb"]), 0.25)
    f["beauty"] = e["beauty"] / 100.0
    f["speed"] = e["speed"] / 100.0
    f["ready"] = 1.0 if e["kind"] == "pull" else 0.45
    f["small"] = clamp(1.0 - (e["dl_mb"] / 3000.0), 0.0, 1.0)

    base = sum(w[k] * f[k] for k in f) / sum(w.values())

    bonus = 0.0
    notes = []
    purpose = prefs.get("purpose", "general")
    tagw = PURPOSE_TAGS.get(purpose, {})
    if tagw:
        best = 0.0
        for tag, val in tagw.items():
            if tag in e["tags"] or tag == e["family"] or tag == e["de"]:
                best = max(best, val)
        if best:
            bonus += best * 0.25
            notes.append("carries what %s work needs" % purpose)
        else:
            bonus -= 0.08
    fam = prefs.get("family")
    if fam and e["family"] == fam:
        bonus += 0.05
        notes.append("the %s family you asked for" % catalog.FAMILY_LABEL.get(fam, fam))
    if "verified" in e["tags"]:
        bonus += 0.035
        notes.append("prebuilt and known good")
    if e["profile"] == "kasm" and prefs.get("want_tunnel", True):
        bonus -= 0.06
        notes.append("https image, so only a limited TCP tunnel")
    # A desktop that wants more RAM than half of free memory is a gamble.
    if e["ram_rec"] > host["mem_avail_mb"] * 0.5:
        bonus -= 0.05

    score = clamp((base + bonus) * 100.0, 0.0, 100.0)
    if blockers:
        score = 0.0
    return score, f, blockers, notes


def plan_resources(e, host, generous=False):
    """Pick cpu/memory/shm/disk for this entry on this host."""
    avail = max(512, host["mem_avail_mb"])
    share = 0.70 if generous else 0.55
    mem = clamp(e["ram_rec"], e["ram_min"], int(avail * share))
    mem = int(max(e["ram_min"], round(mem / 256.0) * 256))
    cores = max(1.0, float(host["cpus"]))
    cpus = clamp(e["cpu_rec"], 1.0, max(1.0, cores - 0.5 if cores > 1 else cores))
    cpus = round(cpus * 2) / 2.0
    shm = int(clamp(mem / 4.0, 256, 2048))
    disk = int(e["disk_mb"] + 4096)
    return {"memory_mb": mem, "cpus": cpus, "shm_mb": shm, "disk_mb": disk,
            "swap_mb": 0}


def recommend(prefs=None, limit=3, host=None):
    prefs = prefs or {}
    host = host or host_info(fresh=True)
    scored = []
    for e in catalog.CATALOG:
        s, f, blockers, notes = score_entry(e, host, prefs)
        if blockers:
            continue
        scored.append((s, f, notes, e))
    scored.sort(key=lambda t: -t[0])

    # Don't hand back three flavours of the same thing.  Try strict variety
    # first, then relax until we have enough picks.
    chosen = []
    for max_de, max_fam in ((1, 1), (1, 2), (2, 2), (99, 99)):
        chosen, seen_de, seen_fam = [], {}, {}
        for row in scored:
            e = row[3]
            if len(chosen) >= limit:
                break
            if seen_de.get(e["de"], 0) >= max_de:
                continue
            if seen_fam.get(e["family"], 0) >= max_fam:
                continue
            seen_de[e["de"]] = seen_de.get(e["de"], 0) + 1
            seen_fam[e["family"]] = seen_fam.get(e["family"], 0) + 1
            chosen.append(row)
        if len(chosen) >= min(limit, len(scored)):
            break

    picks = []
    for s, f, notes, e in chosen:
        picks.append({
            "id": e["id"], "name": e["name"], "score": round(s, 1),
            "factors": {k: round(v, 3) for k, v in f.items()},
            "why": _why(e, f, notes, host),
            "plan": plan_resources(e, host),
            "entry": public_entry(e),
        })
    return {"host": host, "prefs": prefs, "picks": picks,
            "considered": len(scored),
            "taste": TASTE_BLURB[prefs.get("taste", "balanced")]}


def _why(e, f, notes, host):
    out = []
    if f["ram"] > 0.9:
        out.append("sits well inside your %s of free RAM" % human_mb(host["mem_avail_mb"]))
    elif f["ram"] > 0.6:
        out.append("fits your free RAM with room to spare")
    else:
        out.append("will use a real slice of your RAM")
    if e["kind"] == "pull":
        out.append("prebuilt, so it only has to download %s" % human_mb(e["dl_mb"]))
    else:
        out.append("built locally from %s, about %s to fetch first"
                   % (e["distro"], human_mb(e["dl_mb"])))
    if e["beauty"] >= 88:
        out.append("one of the best looking desktops in the catalog")
    elif e["heavy"] <= 20:
        out.append("barely registers on the CPU, idles near %s" % human_mb(e["idle_mb"]))
    out.extend(notes)
    return out[:4]


def public_entry(e):
    """The catalog fields the UI and CLI need, without the build recipe."""
    keep = ("id", "name", "subtitle", "family", "distro", "de", "de_label", "glyph",
            "kind", "image", "desc", "dl_mb", "disk_mb", "idle_mb", "ram_min",
            "ram_rec", "cpu_rec", "heavy", "weight", "beauty", "speed", "arches",
            "tags", "profile")
    out = {k: e.get(k) for k in keep}
    out["family_label"] = catalog.FAMILY_LABEL.get(e["family"], e["family"].title())
    return out


# ===========================================================================
# ports
# ===========================================================================

def port_is_free(port):
    for fam, addr in ((socket.AF_INET, ""),):
        s = socket.socket(fam, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


def ports_in_use_by_docker():
    used = set()
    rc, out, _ = run(["docker", "ps", "--format", "{{.Ports}}"], timeout=30)
    if rc == 0:
        for m in re.finditer(r":(\d+)->", out):
            used.add(int(m.group(1)))
    return used


def alloc_ports(count, want=None):
    """Reserve `count` free host ports.  Honours an explicit first choice."""
    with FileLock("ports"):
        res = jload(PORTS_JSON, {})
        now = time.time()
        res = {k: v for k, v in res.items() if now - float(v) < 900}
        taken = set(int(k) for k in res) | ports_in_use_by_docker()
        out = []
        if want:
            for p in want:
                p = int(p)
                if p not in taken and port_is_free(p):
                    out.append(p)
                    taken.add(p)
        tries = 0
        while len(out) < count and tries < 4000:
            tries += 1
            p = random.randint(PORT_LO, PORT_HI)
            if p in taken or p in out:
                continue
            if not port_is_free(p):
                taken.add(p)
                continue
            out.append(p)
            taken.add(p)
        if len(out) < count:
            raise RuntimeError("could not find %d free ports in %d-%d" % (count, PORT_LO, PORT_HI))
        for p in out:
            res[str(p)] = now
        jsave(PORTS_JSON, res)
        return out[:count]


def release_port_reservation(ports):
    try:
        with FileLock("ports"):
            res = jload(PORTS_JSON, {})
            for p in ports or []:
                res.pop(str(p), None)
            jsave(PORTS_JSON, res)
    except Exception:
        pass


# ===========================================================================
# instance registry (docker labels are the source of truth)
# ===========================================================================

def reg_load():
    return jload(INSTANCES_JSON, {})


def reg_update(name, patch):
    with FileLock("instances"):
        reg = jload(INSTANCES_JSON, {})
        cur = reg.get(name) or {}
        cur.update(patch)
        reg[name] = cur
        jsave(INSTANCES_JSON, reg)
        return cur


def reg_delete(name):
    with FileLock("instances"):
        reg = jload(INSTANCES_JSON, {})
        reg.pop(name, None)
        jsave(INSTANCES_JSON, reg)


def docker_instances():
    """Every forge container, merged with our own notes about it."""
    rc, out, _ = run(["docker", "ps", "-aq", "--filter", "label=%s.entry" % LABEL], timeout=40)
    ids = [x for x in out.split() if x.strip()]
    data = []
    if ids:
        rc, out, _ = run(["docker", "inspect"] + ids, timeout=60)
        if rc == 0:
            try:
                data = json.loads(out)
            except Exception:
                data = []

    reg = reg_load()
    items = []
    for c in data:
        labels = ((c.get("Config") or {}).get("Labels") or {})
        name = (c.get("Name") or "").lstrip("/")
        state = c.get("State") or {}
        hostcfg = c.get("HostConfig") or {}
        ports = {}
        for cport, binds in ((c.get("NetworkSettings") or {}).get("Ports") or {}).items():
            if binds:
                try:
                    ports[cport.split("/")[0]] = int(binds[0].get("HostPort"))
                except Exception:
                    pass
        note = reg.get(name) or {}
        entry_id = labels.get("%s.entry" % LABEL)
        cat = catalog.BY_ID.get(entry_id)
        items.append({
            "name": name,
            "container_id": (c.get("Id") or "")[:12],
            "entry_id": entry_id,
            "entry": public_entry(cat) if cat else None,
            "title": labels.get("%s.title" % LABEL) or (cat or {}).get("name") or name,
            "family": labels.get("%s.family" % LABEL) or (cat or {}).get("family") or "ubuntu",
            "glyph": labels.get("%s.glyph" % LABEL) or (cat or {}).get("glyph") or "openbox",
            "de_label": labels.get("%s.de" % LABEL) or (cat or {}).get("de_label") or "",
            "profile": labels.get("%s.profile" % LABEL) or (cat or {}).get("profile") or "selkies",
            "image": (c.get("Config") or {}).get("Image"),
            "running": bool(state.get("Running")),
            "status": state.get("Status"),
            "health": ((state.get("Health") or {}).get("Status")),
            "started_at": state.get("StartedAt"),
            "created": c.get("Created"),
            "restarts": state.get("RestartCount") or 0,
            "exit_code": state.get("ExitCode"),
            "ports": ports,
            "limits": {
                "memory_mb": int((hostcfg.get("Memory") or 0) / (1024 * 1024)) or None,
                "cpus": round((hostcfg.get("NanoCpus") or 0) / 1e9, 2) or None,
                "shm_mb": int((hostcfg.get("ShmSize") or 0) / (1024 * 1024)) or None,
            },
            "disk_cap_mb": _int_or_none(labels.get("%s.disk" % LABEL)),
            "volume": labels.get("%s.volume" % LABEL),
            "tunnel": note.get("tunnel"),
            "local_url": None,
            "notes": {k: v for k, v in note.items() if k not in ("tunnel",)},
        })

    for it in items:
        it["local_url"] = local_url_for(it)
        it["tunnel"] = tunnel_status(it["name"], it.get("tunnel"))
    items.sort(key=lambda i: (not i["running"], i["name"]))
    return items


def _int_or_none(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def local_url_for(it):
    ports = it.get("ports") or {}
    if it.get("profile") == "kasm":
        p = ports.get(str(KASM_HTTPS))
        return "https://localhost:%d" % p if p else None
    p = ports.get(str(SELKIES_HTTP))
    return "http://localhost:%d" % p if p else None


def https_url_for(it):
    ports = it.get("ports") or {}
    p = ports.get(str(SELKIES_HTTPS))
    return "https://localhost:%d" % p if p else None


# ===========================================================================
# serveo tunnels
# ===========================================================================

def ensure_ssh_key():
    if os.path.exists(SSH_KEY):
        return SSH_KEY
    ensure_dirs()
    rc, _, err = run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                      "selkies-forge", "-f", SSH_KEY], timeout=60)
    if rc != 0 and not os.path.exists(SSH_KEY):
        return None
    try:
        os.chmod(SSH_KEY, 0o600)
    except OSError:
        pass
    return SSH_KEY


TUNNEL_HTTP_RE = re.compile(r"https?://[A-Za-z0-9._-]+\.serveousercontent\.com")
TUNNEL_TCP_RE = re.compile(r"(?:serveo\.net|serveousercontent\.com):(\d+)")


def tunnel_logfile(name):
    return os.path.join(LOGDIR, "tunnel-%s.log" % slug(name))


def tunnel_start(name, local_port, mode="http", subdomain=None, wait=50.0):
    """Open a serveo tunnel.  Returns a dict describing it, or raises."""
    if not have("ssh"):
        raise RuntimeError("ssh is not installed, cannot open a tunnel")
    ensure_dirs()
    tunnel_stop(name)
    log = tunnel_logfile(name)
    try:
        os.remove(log)
    except OSError:
        pass

    key = ensure_ssh_key()
    remote = "80" if mode == "http" else "0"
    if mode == "http" and subdomain:
        remote = "%s:80" % re.sub(r"[^a-z0-9-]", "", subdomain.lower())
    cmd = ["ssh", "-T", "-n",
           "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=%s" % os.path.join(STATE, "known_hosts"),
           "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
           "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=20"]
    # Deliberately no BatchMode and no NumberOfPasswordPrompts=0 here: serveo
    # authorises anonymous tunnels over keyboard-interactive, and both of
    # those options switch that method off, which just yields
    # "Permission denied (publickey,keyboard-interactive)".
    if key:
        cmd += ["-i", key, "-o", "IdentitiesOnly=yes"]
    cmd += ["-R", "%s:localhost:%d" % (remote, int(local_port)), "serveo.net"]

    fh = open(log, "ab", buffering=0)
    proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, start_new_session=True)

    deadline = time.time() + wait
    url = None
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        try:
            with open(log, "r", errors="replace") as rh:
                txt = ANSI_RE.sub("", rh.read())
        except OSError:
            txt = ""
        if mode == "http":
            m = TUNNEL_HTTP_RE.search(txt)
            if m:
                url = m.group(0)
                break
        else:
            m = TUNNEL_TCP_RE.search(txt)
            if m:
                url = "https://serveousercontent.com:%s" % m.group(1)
                break
        time.sleep(0.4)

    if not url:
        try:
            with open(log, "r", errors="replace") as rh:
                tail = ANSI_RE.sub("", rh.read())[-600:].strip()
        except OSError:
            tail = ""
        try:
            proc.terminate()
        except Exception:
            pass
        raise RuntimeError("serveo did not hand back a URL. %s" % (tail or "no output"))

    info = {"url": url, "mode": mode, "pid": proc.pid, "port": int(local_port),
            "log": log, "started": time.time(), "alive": True}
    reg_update(name, {"tunnel": info})
    return info


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def tunnel_status(name, info=None):
    if info is None:
        info = (reg_load().get(name) or {}).get("tunnel")
    if not info:
        return None
    info = dict(info)
    info["alive"] = pid_alive(info.get("pid"))
    return info


def tunnel_stop(name):
    info = (reg_load().get(name) or {}).get("tunnel")
    if info and info.get("pid") and pid_alive(info["pid"]):
        try:
            os.killpg(os.getpgid(int(info["pid"])), signal.SIGTERM)
        except Exception:
            try:
                os.kill(int(info["pid"]), signal.SIGTERM)
            except Exception:
                pass
    reg_update(name, {"tunnel": None})
    return True


# ===========================================================================
# build recipes -> Dockerfile
# ===========================================================================

INSTALL_SH = {
    "apt": """
export DEBIAN_FRONTEND=noninteractive
echo ">> forge: apt-get update"
apt-get update -qq
echo ">> forge: installing desktop packages"
if ! apt-get install -y --no-install-recommends $PKGS; then
  echo ">> forge: bulk install failed, falling back to one at a time"
  apt-get -f install -y || true
  for p in $PKGS; do
    apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \\
      && echo ">> forge: ok   $p" || echo ">> forge: skip $p"
  done
fi
apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/* /config/.cache 2>/dev/null || true
""",
    "dnf": """
echo ">> forge: installing desktop packages with dnf"
if ! dnf install -y --setopt=install_weak_deps=False --best --skip-broken $PKGS; then
  echo ">> forge: bulk install failed, falling back to one at a time"
  for p in $PKGS; do
    dnf install -y --setopt=install_weak_deps=False "$p" >/dev/null 2>&1 \\
      && echo ">> forge: ok   $p" || echo ">> forge: skip $p"
  done
fi
dnf clean all
rm -rf /var/cache/dnf /tmp/* /config/.cache 2>/dev/null || true
""",
    "pacman": """
echo ">> forge: refreshing pacman keyring"
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman -Sy --noconfirm >/dev/null 2>&1 || true
echo ">> forge: installing desktop packages with pacman"
if ! pacman -S --noconfirm --needed $PKGS; then
  echo ">> forge: bulk install failed, falling back to one at a time"
  for p in $PKGS; do
    pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 \\
      && echo ">> forge: ok   $p" || echo ">> forge: skip $p"
  done
fi
pacman -Scc --noconfirm >/dev/null 2>&1 || true
rm -rf /var/cache/pacman/pkg/* /tmp/* /config/.cache 2>/dev/null || true
""",
    "apk": """
echo ">> forge: installing desktop packages with apk"
apk update >/dev/null 2>&1 || true
if ! apk add --no-cache $PKGS; then
  echo ">> forge: bulk install failed, falling back to one at a time"
  for p in $PKGS; do
    apk add --no-cache "$p" >/dev/null 2>&1 \\
      && echo ">> forge: ok   $p" || echo ">> forge: skip $p"
  done
fi
rm -rf /var/cache/apk/* /tmp/* /config/.cache 2>/dev/null || true
""",
}


def session_candidates(session):
    """Binaries that would prove the desktop actually installed."""
    toks = [t for t in re.split(r"[^A-Za-z0-9_.+-]+", session) if t]
    drop = {"sh", "bash", "c", "exec", "session", "w", "start", "usr", "bin", "true"}
    out = []
    for t in toks:
        if t in drop or t.startswith("-") or t.isdigit():
            continue
        if t not in out:
            out.append(t)
    return out or ["true"]


def gen_install_sh(entry):
    rec = entry["recipe"]
    body = INSTALL_SH[rec["pm"]]
    verify = " ".join(session_candidates(rec["session"]))
    return """#!/bin/sh
set -eu
PKGS="%s"
VERIFY="%s"
echo ">> forge: building %s"
%s
ok=0
for b in $VERIFY; do
  if command -v "$b" >/dev/null 2>&1; then ok=1; echo ">> forge: found session binary $b"; fi
done
if [ "$ok" != "1" ]; then
  echo ">> forge: FATAL none of these session binaries installed: $VERIFY"
  exit 97
fi
echo ">> forge: desktop installed cleanly"
""" % (" ".join(rec["pkgs"].split()), verify, entry["name"], body.strip())


def gen_startwm(entry):
    rec = entry["recipe"]
    theme = rec.get("theme") or {}
    gtk = theme.get("gtk")
    icons = theme.get("icons")
    font = "Inter 10" if theme.get("gtk") == "Arc-Dark" else "Noto Sans 10"
    out = ["#!/usr/bin/env bash",
           "# generated by selkies-forge %s for %s" % (VERSION, entry["id"]),
           "setterm blank 0 2>/dev/null || true",
           "setterm powerdown 0 2>/dev/null || true",
           'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-abc}"',
           'mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true',
           'cfg="${HOME:-/config}"']
    for ev in rec.get("env", []):
        out.append("export %s" % ev)

    if gtk or icons:
        out += [
            'mkdir -p "$cfg/.config/gtk-3.0" "$cfg/.config/gtk-4.0" '
            '"$cfg/.config/xsettingsd" "$cfg/.config/autostart" 2>/dev/null || true',
            'if [ ! -f "$cfg/.config/gtk-3.0/settings.ini" ]; then',
            '  cat > "$cfg/.config/gtk-3.0/settings.ini" <<GTKEOF',
            '[Settings]',
            'gtk-theme-name=%s' % (gtk or "Adwaita"),
            'gtk-icon-theme-name=%s' % (icons or "Adwaita"),
            'gtk-font-name=%s' % font,
            'gtk-application-prefer-dark-theme=%d' % (1 if "dark" in (gtk or "").lower() else 0),
            'gtk-enable-animations=1',
            'GTKEOF',
            '  cp -f "$cfg/.config/gtk-3.0/settings.ini" '
            '"$cfg/.config/gtk-4.0/settings.ini" 2>/dev/null || true',
            'fi',
            'if [ ! -f "$cfg/.gtkrc-2.0" ]; then',
            '  printf \'gtk-theme-name="%s"\\ngtk-icon-theme-name="%s"\\ngtk-font-name="%s"\\n\' '
            '> "$cfg/.gtkrc-2.0"' % (gtk or "Adwaita", icons or "Adwaita", font),
            'fi',
            'if [ ! -f "$cfg/.config/xsettingsd/xsettingsd.conf" ]; then',
            '  cat > "$cfg/.config/xsettingsd/xsettingsd.conf" <<XSEOF',
            'Net/ThemeName "%s"' % (gtk or "Adwaita"),
            'Net/IconThemeName "%s"' % (icons or "Adwaita"),
            'Gtk/FontName "%s"' % font,
            'Gtk/EnableAnimations 1',
            'XSEOF',
            'fi',
        ]
        if entry.get("de") == "xfce":
            out += [
                'xfd="$cfg/.config/xfce4/xfconf/xfce-perchannel-xml"',
                'if [ ! -f "$xfd/xsettings.xml" ]; then',
                '  mkdir -p "$xfd" 2>/dev/null || true',
                '  cat > "$xfd/xsettings.xml" <<XFEOF',
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<channel name="xsettings" version="1.0">',
                '  <property name="Net" type="empty">',
                '    <property name="ThemeName" type="string" value="%s"/>' % (gtk or "Adwaita"),
                '    <property name="IconThemeName" type="string" value="%s"/>' % (icons or "Adwaita"),
                '  </property>',
                '  <property name="Gtk" type="empty">',
                '    <property name="FontName" type="string" value="%s"/>' % font,
                '  </property>',
                '</channel>',
                'XFEOF',
                'fi',
            ]

    if theme.get("dock"):
        out += [
            'if [ ! -f "$cfg/.config/autostart/plank.desktop" ] && command -v plank >/dev/null 2>&1; then',
            '  mkdir -p "$cfg/.config/autostart" 2>/dev/null || true',
            '  printf \'[Desktop Entry]\\nType=Application\\nName=Plank\\nExec=plank\\n'
            'X-GNOME-Autostart-enabled=true\\n\' > "$cfg/.config/autostart/plank.desktop"',
            'fi',
            '(sleep 6; command -v plank >/dev/null 2>&1 && plank >/dev/null 2>&1 &) &',
        ]

    for line in rec.get("pre", []):
        out.append(line)

    if rec.get("bare"):
        term = rec.get("term", "xterm")
        out.append('(sleep 3; command -v %s >/dev/null 2>&1 && %s >/dev/null 2>&1 &) &'
                   % (term, term))

    out.append("exec dbus-launch --exit-with-session %s > /dev/null 2>&1" % rec["session"])
    return "\n".join(out) + "\n"


def gen_dockerfile(entry):
    rec = entry["recipe"]
    inst = base64.b64encode(gen_install_sh(entry).encode()).decode()
    start = base64.b64encode(gen_startwm(entry).encode()).decode()
    df = [
        "# syntax=docker/dockerfile:1",
        "FROM %s" % rec["image"],
        'LABEL %s.entry="%s"' % (LABEL, entry["id"]),
        'LABEL %s.builder="selkies-forge %s"' % (LABEL, VERSION),
        'ENV TITLE="%s"' % entry["name"].replace('"', ""),
        "RUN printf '%%s' '%s' | base64 -d > /tmp/forge-install.sh \\\n"
        "    && chmod +x /tmp/forge-install.sh \\\n"
        "    && /tmp/forge-install.sh \\\n"
        "    && rm -f /tmp/forge-install.sh" % inst,
        "RUN printf '%%s' '%s' | base64 -d > /defaults/startwm.sh \\\n"
        "    && chmod 755 /defaults/startwm.sh" % start,
        "EXPOSE 3000 3001",
        "VOLUME /config",
    ]
    return "\n".join(df) + "\n"


def build_image_tag(entry):
    return "%s%s:latest" % (IPREFIX, entry["id"])


# ===========================================================================
# jobs: a launch is a stream of events the UI and the CLI both read
# ===========================================================================

class Job(object):
    MAX_EVENTS = 6000

    def __init__(self, kind, entry_id=None, title=None):
        self.id = uuid.uuid4().hex[:12]
        self.kind = kind
        self.entry_id = entry_id
        self.title = title or entry_id or kind
        self.created = time.time()
        self.status = "running"
        self.phase = "starting"
        self.progress = 0.0
        self.result = None
        self.error = None
        self.events = deque(maxlen=self.MAX_EVENTS)
        self._seq = 0
        self._cv = threading.Condition()
        self.thread = None

    # -- producer ---------------------------------------------------------
    def _push(self, typ, data):
        with self._cv:
            self._seq += 1
            ev = {"seq": self._seq, "t": round(time.time(), 3), "type": typ, "data": data}
            self.events.append(ev)
            self._cv.notify_all()
            return ev

    def log(self, line, stream="out"):
        for ln in str(line).rstrip("\n").split("\n"):
            self._push("log", {"line": ln, "stream": stream})

    def set_phase(self, phase, label=None, progress=None):
        self.phase = phase
        if progress is not None:
            self.progress = clamp(float(progress), 0.0, 1.0)
        self._push("phase", {"phase": phase, "label": label or phase,
                             "progress": round(self.progress, 4)})

    def set_progress(self, value, extra=None):
        self.progress = clamp(float(value), 0.0, 1.0)
        self._push("progress", {"phase": self.phase,
                                "progress": round(self.progress, 4),
                                "extra": extra or {}})

    def finish(self, result):
        self.status = "done"
        self.progress = 1.0
        self.result = result
        self._push("done", result)

    def fail(self, message, hints=None):
        self.status = "error"
        self.error = {"message": str(message), "hints": hints or []}
        self._push("error", self.error)

    # -- consumer ---------------------------------------------------------
    def since(self, cursor, timeout=20.0):
        """Block until there are events after `cursor`, then return them."""
        deadline = time.time() + timeout
        with self._cv:
            while True:
                out = [e for e in self.events if e["seq"] > cursor]
                if out:
                    return out
                if self.status != "running" or time.time() >= deadline:
                    return []
                self._cv.wait(min(1.0, max(0.05, deadline - time.time())))

    def snapshot(self):
        return {"id": self.id, "kind": self.kind, "entry_id": self.entry_id,
                "title": self.title, "status": self.status, "phase": self.phase,
                "progress": round(self.progress, 4), "result": self.result,
                "error": self.error, "created": self.created,
                "last_seq": self._seq}


JOBS = {}
JOBS_LOCK = threading.Lock()


def job_put(job):
    with JOBS_LOCK:
        JOBS[job.id] = job
        if len(JOBS) > 40:
            old = sorted(JOBS.values(), key=lambda j: j.created)
            for j in old[:len(JOBS) - 40]:
                if j.status != "running":
                    JOBS.pop(j.id, None)
    return job


def job_get(jid):
    with JOBS_LOCK:
        return JOBS.get(jid)


# ===========================================================================
# running containers
# ===========================================================================

def stream_cmd(cmd, on_line, env=None, timeout=7200):
    """Run a command, hand every output line to on_line, return exit code."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=env, bufsize=1, universal_newlines=True,
                         errors="replace")
    start = time.time()
    try:
        for line in p.stdout:
            on_line(line.rstrip("\n"))
            if time.time() - start > timeout:
                p.kill()
                raise RuntimeError("command exceeded %ss" % timeout)
    finally:
        try:
            p.stdout.close()
        except Exception:
            pass
    return p.wait()


def stream_cmd_pty(cmd, on_line, timeout=7200):
    """Like stream_cmd, but behind a pty.

    `docker pull` only prints per-layer byte counts when stdout looks like a
    terminal; without one you get bare status lines and no numbers.
    """
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.environ["TERM"] = "xterm"
            os.environ["COLUMNS"] = "160"
            os.execvp(cmd[0], cmd)
        except Exception:
            os._exit(127)
    buf = b""
    start = time.time()
    try:
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 1.0)
            except (OSError, ValueError):
                break
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break                      # child exited, pty closed
                if not data:
                    break
                buf += data
                parts = re.split(rb"[\r\n]", buf)
                buf = parts.pop()
                for raw in parts:
                    line = ANSI_RE.sub("", raw.decode("utf-8", "replace")).strip()
                    if line:
                        on_line(line)
            if time.time() - start > timeout:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
                raise RuntimeError("command exceeded %ss" % timeout)
    finally:
        if buf.strip():
            line = ANSI_RE.sub("", buf.decode("utf-8", "replace")).strip()
            if line:
                on_line(line)
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
            else (status >> 8)
    except ChildProcessError:
        return 0


def container_name_for(entry, wanted=None):
    base = CPREFIX + slug(wanted or entry["id"])[:40]
    rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=30)
    taken = set(out.split())
    if base not in taken:
        return base
    for i in range(2, 100):
        cand = "%s-%d" % (base, i)
        if cand not in taken:
            return cand
    return "%s-%s" % (base, uuid.uuid4().hex[:5])


def tz_name():
    try:
        p = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in p:
            return p.split("/zoneinfo/", 1)[1]
    except Exception:
        pass
    return os.environ.get("TZ") or "Etc/UTC"


def docker_run_args(entry, name, ports, plan, opts, image, host):
    prof = entry.get("profile", "selkies")
    args = ["docker", "run", "-d", "--name", name,
            "--hostname", slug(entry["family"])[:20] or "forge",
            "--restart", opts.get("restart", "unless-stopped"),
            "--shm-size", "%dm" % int(plan["shm_mb"]),
            "--label", "%s.entry=%s" % (LABEL, entry["id"]),
            "--label", "%s.title=%s" % (LABEL, entry["name"]),
            "--label", "%s.family=%s" % (LABEL, entry["family"]),
            "--label", "%s.glyph=%s" % (LABEL, entry["glyph"]),
            "--label", "%s.de=%s" % (LABEL, entry["de_label"]),
            "--label", "%s.profile=%s" % (LABEL, prof),
            "--label", "%s.version=%s" % (LABEL, VERSION),
            "--label", "%s.disk=%d" % (LABEL, int(plan["disk_mb"])),
            ]
    if plan.get("memory_mb"):
        args += ["--memory", "%dm" % int(plan["memory_mb"])]
        # Pin swap to the same value so a limited desktop can't swap the host out.
        args += ["--memory-swap", "%dm" % int(plan["memory_mb"])]
    if plan.get("cpus"):
        args += ["--cpus", "%s" % plan["cpus"]]

    vol = "%sconfig-%s" % (CPREFIX, slug(name))
    args += ["--label", "%s.volume=%s" % (LABEL, vol)]
    if host.get("quota_support") and plan.get("disk_mb"):
        args += ["--storage-opt", "size=%dM" % int(plan["disk_mb"])]
    args += ["-v", "%s:/config" % vol]

    if opts.get("gpu") and os.path.exists("/dev/dri"):
        args += ["--device", "/dev/dri"]
    if opts.get("seccomp_unconfined"):
        args += ["--security-opt", "seccomp=unconfined"]

    if prof == "kasm":
        args += ["-p", "%d:%d" % (ports[0], KASM_HTTPS),
                 "-e", "VNC_PW=%s" % opts.get("password", "forge"),
                 "-e", "TZ=%s" % tz_name()]
    else:
        args += ["-p", "%d:%d" % (ports[0], SELKIES_HTTP),
                 "-p", "%d:%d" % (ports[1], SELKIES_HTTPS),
                 "-e", "PUID=%d" % os.getuid(),
                 "-e", "PGID=%d" % os.getgid(),
                 "-e", "TZ=%s" % tz_name(),
                 "-e", "TITLE=%s" % entry["name"]]
        if opts.get("username") and opts.get("password"):
            args += ["-e", "CUSTOM_USER=%s" % opts["username"],
                     "-e", "PASSWORD=%s" % opts["password"]]
        if opts.get("locale"):
            args += ["-e", "LC_ALL=%s" % opts["locale"]]
    for kv in opts.get("env", []) or []:
        args += ["-e", kv]
    args.append(image)
    return args, vol


def wait_healthy(name, port, profile, job=None, timeout=240):
    """Poll the desktop's own web port until it answers."""
    url = ("https://127.0.0.1:%d/" if profile == "kasm" else "http://127.0.0.1:%d/") % port
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    deadline = time.time() + timeout
    last = ""
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        rc, out, _ = run(["docker", "inspect", "-f", "{{.State.Running}}|{{.State.ExitCode}}",
                          name], timeout=20)
        if rc == 0 and out.strip().startswith("false"):
            tail = container_logs(name, 25)
            raise RuntimeError("the container stopped on its own.\n%s" % tail)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "selkies-forge"})
            with urllib.request.urlopen(req, timeout=6, context=ctx) as resp:
                if resp.status < 500:
                    return True
                last = "HTTP %s" % resp.status
        except urllib.error.HTTPError as ex:
            if ex.code in (401, 403):
                return True          # basic auth is on, which means it is up
            last = "HTTP %s" % ex.code
        except Exception as ex:
            last = type(ex).__name__
        if job and attempt % 5 == 0:
            frac = 1.0 - (deadline - time.time()) / float(timeout)
            job.set_progress(clamp(0.90 + 0.06 * frac, 0.90, 0.96),
                             {"waiting": last, "seconds": int(time.time() - (deadline - timeout))})
        time.sleep(2.0)
    raise RuntimeError("the desktop never answered on port %d within %ds (last: %s)"
                       % (port, timeout, last or "no reply"))


def container_logs(name, lines=60):
    rc, out, err = run(["docker", "logs", "--tail", str(lines), name], timeout=30)
    return (out or "") + (err or "")


# ===========================================================================
# the launch pipeline
# ===========================================================================

def launch(entry_id, plan=None, opts=None, job=None, name=None):
    """Pull or build, run, wait, tunnel.  Returns the finished instance dict."""
    opts = dict(opts or {})
    entry = catalog.BY_ID.get(entry_id)
    if not entry:
        raise RuntimeError("unknown catalog id: %s" % entry_id)
    job = job or job_put(Job("launch", entry_id, entry["name"]))
    host = host_info(fresh=True)
    plan = dict(plan or plan_resources(entry, host))
    reserved = []

    try:
        # ---- 1. check this machine can run it ---------------------------
        job.set_phase("resolve", "Checking %s against this machine" % entry["name"], 0.01)
        job.log("forge %s  |  %s" % (VERSION, entry["name"]))
        job.log("host     : %s, %d cores, %s RAM free, %s disk free"
                % (host["arch"], host["cpus"], human_mb(host["mem_avail_mb"]),
                   human_mb(host["disk_free_mb"])))
        job.log("plan     : %s RAM, %s CPU, %s shm"
                % (human_mb(plan["memory_mb"]), plan["cpus"], human_mb(plan["shm_mb"])))

        ok, derr = docker_ok()
        if not ok:
            raise RuntimeError("docker is not answering: %s" % derr)

        probe_image = entry["image"] if entry["kind"] == "pull" else entry["recipe"]["image"]
        job.log("image    : %s" % probe_image)
        arches, real_dl = manifest_probe(probe_image, entry["arches"])
        if arches and host["arch"] not in arches:
            alts = [c["name"] for c in catalog.CATALOG
                    if host["arch"] in c["arches"] and c["de"] == entry["de"]][:3]
            raise RuntimeError(
                "%s has no %s build (it publishes: %s). Try: %s"
                % (probe_image, host["arch"], ", ".join(arches) or "nothing",
                   ", ".join(alts) or "another desktop"))
        if real_dl:
            job.log("download : about %s for %s" % (human_mb(real_dl), host["arch"]))

        if not host["quota_support"] and plan.get("disk_mb"):
            job.log("note     : %s on %s cannot enforce a hard disk cap, so the %s "
                    "limit is tracked, not enforced"
                    % (host.get("storage_driver"), host.get("backing_fs"),
                       human_mb(plan["disk_mb"])))

        # ---- 2. get the image ------------------------------------------
        if entry["kind"] == "pull":
            image = entry["image"]
            if image_present(image) and not opts.get("force_pull"):
                job.set_phase("fetch", "Image already here, skipping the pull", 0.70)
                job.log("image already present locally, not pulling again")
            else:
                job.set_phase("fetch", "Pulling %s" % image, 0.02)
                do_pull(image, host["arch"], job)
        else:
            image = build_image_tag(entry)
            if image_present(image) and not opts.get("force_build"):
                job.set_phase("fetch", "Built image already here", 0.70)
                job.log("%s already built, reusing it" % image)
            else:
                base = entry["recipe"]["image"]
                if not image_present(base):
                    job.set_phase("fetch", "Pulling base %s" % base, 0.02)
                    do_pull(base, host["arch"], job, weight=(0.02, 0.45))
                job.set_phase("build", "Building %s" % entry["name"], 0.46)
                do_build(entry, image, job)

        # ---- 3. create the container -----------------------------------
        job.set_phase("create", "Starting the container", 0.80)
        nports = 1 if entry["profile"] == "kasm" else 2
        reserved = alloc_ports(nports, want=opts.get("ports"))
        job.log("ports    : %s" % ", ".join(str(p) for p in reserved))
        cname = container_name_for(entry, name or opts.get("name"))
        args, vol = docker_run_args(entry, cname, reserved, plan, opts, image, host)
        job.log("$ " + " ".join(shlex.quote(a) for a in args))
        rc, out, err = run(args, timeout=180)
        if rc != 0:
            raise RuntimeError("docker run failed: %s" % (err.strip() or out.strip()))
        job.log("container: %s (%s)" % (cname, out.strip()[:12]))
        reg_update(cname, {"entry_id": entry["id"], "created": time.time(),
                           "plan": plan, "opts": {k: v for k, v in opts.items()
                                                  if k != "password"},
                           "volume": vol, "image": image,
                           "ports": reserved, "tunnel": None})

        # ---- 4. wait for the desktop to answer -------------------------
        job.set_phase("health", "Waiting for the desktop to come up", 0.90)
        wait_healthy(cname, reserved[0], entry["profile"], job,
                     timeout=int(opts.get("health_timeout", 300)))
        job.log("desktop is answering on port %d" % reserved[0])

        # ---- 5. tunnel --------------------------------------------------
        tun = None
        if opts.get("tunnel", True):
            mode = "tcp" if entry["profile"] == "kasm" else "http"
            job.set_phase("tunnel", "Opening a serveo tunnel (%s)" % mode, 0.96)
            try:
                tun = tunnel_start(cname, reserved[0], mode=mode,
                                   subdomain=opts.get("subdomain"))
                job.log("tunnel   : %s" % tun["url"])
                if mode == "tcp":
                    job.log("note     : anonymous serveo TCP tunnels are capped "
                            "(~10 min, 2 connections). The local link has no limits.")
            except Exception as ex:
                job.log("tunnel failed: %s" % ex, "err")
                job.log("the desktop is still fine on its local address", "err")
        else:
            job.log("tunnel   : skipped")

        release_port_reservation(reserved)
        inst = next((i for i in docker_instances() if i["name"] == cname), None)
        result = {"name": cname, "entry_id": entry["id"], "entry": public_entry(entry),
                  "ports": reserved, "image": image, "plan": plan,
                  "local_url": "http://localhost:%d" % reserved[0]
                  if entry["profile"] != "kasm" else "https://localhost:%d" % reserved[0],
                  "https_url": "https://localhost:%d" % reserved[1]
                  if entry["profile"] != "kasm" else None,
                  "tunnel": tun, "instance": inst,
                  "credentials": ({"user": "kasm_user",
                                   "password": opts.get("password", "forge")}
                                  if entry["profile"] == "kasm" else
                                  ({"user": opts["username"], "password": opts["password"]}
                                   if opts.get("username") else None)),
                  "quota_enforced": bool(host.get("quota_support")),
                  }
        job.set_phase("ready", "Ready", 1.0)
        job.finish(result)
        return result

    except Exception as ex:
        release_port_reservation(reserved)
        job.fail(str(ex), hints=_hints_for(str(ex)))
        raise


def _hints_for(msg):
    m = msg.lower()
    hints = []
    if "permission denied" in m and "docker" in m:
        hints.append("your user is not in the docker group yet: "
                     "run `sudo usermod -aG docker $USER`, then log out and back in")
    if "no space left" in m or "disk" in m:
        hints.append("free some disk, or run `docker system prune -af` to drop old images")
    if "no arm64" in m or "no amd64" in m or "has no" in m:
        hints.append("pick an entry whose badge lists your architecture")
    if "never answered" in m:
        hints.append("heavy desktops can take a few minutes on first boot; "
                     "try again with a longer timeout, or check `docker logs`")
    if "exit code 97" in m or "session binaries" in m:
        hints.append("that desktop's packages are not available on that base; "
                     "try the same desktop on another distro")
    if "serveo" in m:
        hints.append("serveo may be rate limiting; the local URL still works")
    return hints


BAR_LINE = re.compile(r"\[[=>\s]*\]")


def do_pull(image, arch, job, weight=(0.02, 0.78)):
    lo, hi = weight
    prog = PullProgress()
    last = [0.0]
    seen = set()

    def on_line(line):
        clean = ANSI_RE.sub("", line).strip()
        if not clean:
            return
        lid = prog.feed(clean)
        # A pty makes docker repaint every layer on every tick. Log each
        # layer/status once and let the progress bar carry the rest.
        if BAR_LINE.search(clean) and lid:
            key = (lid, prog.layers[lid]["phase"])
            if key not in seen:
                seen.add(key)
                job.log("%s: %s" % (lid, prog.layers[lid]["phase"]))
        else:
            if clean not in seen:
                seen.add(clean)
                job.log(clean)
        f = prog.fraction()
        if f - last[0] > 0.003 or f >= 0.999:
            last[0] = f
            job.set_progress(lo + (hi - lo) * f, prog.summary())

    cmd = ["docker", "pull", "--platform", "linux/%s" % arch, image]
    rc = stream_cmd_pty(cmd, on_line, timeout=5400)
    if rc != 0:
        raise RuntimeError("docker pull failed for %s (exit %d)" % (image, rc))
    job.set_progress(hi, prog.summary())


BUILD_STEP = re.compile(r"^#(\d+)\s")


def do_build(entry, tag, job, weight=(0.46, 0.78)):
    lo, hi = weight
    ctx = os.path.join(BUILDDIR, slug(entry["id"]))
    os.makedirs(ctx, exist_ok=True)
    df = gen_dockerfile(entry)
    with open(os.path.join(ctx, "Dockerfile"), "w") as fh:
        fh.write(df)
    with open(os.path.join(ctx, "startwm.sh"), "w") as fh:
        fh.write(gen_startwm(entry))
    job.log("build context: %s" % ctx)
    job.log("installing: %s" % entry["recipe"]["pkgs"])

    # Package installs dominate the time; step counting gives a usable curve.
    seen = {"max": 0.0, "pkgs": 0}
    total_pkgs = max(1, len(entry["recipe"]["pkgs"].split()))

    def on_line(line):
        clean = ANSI_RE.sub("", line)
        if clean.strip():
            job.log(clean)
        low = clean.lower()
        if "setting up " in low or ">> forge: ok" in low or "installing" in low:
            seen["pkgs"] = min(total_pkgs, seen["pkgs"] + 1)
        frac = clamp(0.08 + 0.85 * (seen["pkgs"] / float(total_pkgs)), 0.0, 0.95)
        if "exporting layers" in low or "writing image" in low:
            frac = 0.98
        if frac > seen["max"] + 0.004:
            seen["max"] = frac
            job.set_progress(lo + (hi - lo) * frac,
                             {"packages": seen["pkgs"], "packages_total": total_pkgs})

    env = dict(os.environ)
    env["DOCKER_BUILDKIT"] = "1"
    env["BUILDKIT_PROGRESS"] = "plain"
    cmd = ["docker", "build", "--progress=plain", "--platform",
           "linux/%s" % host_info()["arch"], "-t", tag, "-f",
           os.path.join(ctx, "Dockerfile"), ctx]
    rc = stream_cmd(cmd, on_line, env=env, timeout=10800)
    if rc != 0:
        raise RuntimeError("docker build failed for %s (exit %d). The log above "
                           "says which package broke." % (entry["id"], rc))
    job.set_progress(hi)


# ===========================================================================
# lifecycle
# ===========================================================================

def instance_action(name, action, opts=None):
    opts = opts or {}
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    if action == "start":
        rc, out, err = run(["docker", "start", name], timeout=120)
    elif action == "stop":
        tunnel_stop(name)
        rc, out, err = run(["docker", "stop", "-t", "20", name], timeout=180)
    elif action == "restart":
        tunnel_stop(name)
        rc, out, err = run(["docker", "restart", "-t", "20", name], timeout=240)
    elif action == "remove":
        tunnel_stop(name)
        run(["docker", "rm", "-f", name], timeout=180)
        if opts.get("purge"):
            vol = (reg_load().get(name) or {}).get("volume") or "%sconfig-%s" % (CPREFIX, slug(name))
            run(["docker", "volume", "rm", "-f", vol], timeout=120)
        reg_delete(name)
        return {"ok": True}
    elif action == "tunnel":
        inst = next((i for i in docker_instances() if i["name"] == name), None)
        if not inst or not inst["running"]:
            raise RuntimeError("%s is not running" % name)
        port = (inst["ports"] or {}).get(
            str(KASM_HTTPS) if inst["profile"] == "kasm" else str(SELKIES_HTTP))
        if not port:
            raise RuntimeError("no published port to tunnel")
        mode = "tcp" if inst["profile"] == "kasm" else "http"
        return {"ok": True, "tunnel": tunnel_start(name, port, mode=mode,
                                                   subdomain=opts.get("subdomain"))}
    elif action == "untunnel":
        tunnel_stop(name)
        return {"ok": True}
    else:
        raise RuntimeError("unknown action %s" % action)
    if rc != 0:
        raise RuntimeError((err or out).strip() or "docker %s failed" % action)
    return {"ok": True}


def retune(name, memory_mb=None, cpus=None):
    """Change limits on a live container, no restart needed."""
    args = ["docker", "update"]
    if memory_mb:
        args += ["--memory", "%dm" % int(memory_mb), "--memory-swap", "%dm" % int(memory_mb)]
    if cpus:
        args += ["--cpus", str(cpus)]
    if len(args) == 2:
        raise RuntimeError("nothing to change")
    args.append(name)
    rc, out, err = run(args, timeout=90)
    if rc != 0:
        raise RuntimeError((err or out).strip())
    return {"ok": True}


# ===========================================================================
# stats / bandwidth
# ===========================================================================

def _pair(txt):
    try:
        a, b = str(txt).split("/", 1)
        return parse_size(a.strip()), parse_size(b.strip())
    except Exception:
        return 0, 0


class StatsSampler(object):
    """Polls docker stats so the manager tab has live numbers and sparklines."""

    KEEP = 240

    def __init__(self, interval=3.0):
        self.interval = interval
        self.hist = {}
        self.latest = {}
        self.lock = threading.Lock()
        self.stop_flag = threading.Event()
        self.thread = None

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_flag.set()

    def sample_once(self):
        rc, out, _ = run(["docker", "stats", "--no-stream", "--no-trunc",
                          "--format", "{{json .}}"], timeout=40)
        if rc != 0:
            return {}
        now = time.time()
        rows = {}
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            name = d.get("Name") or ""
            if not name.startswith(CPREFIX):
                continue
            mem_u, mem_l = _pair(d.get("MemUsage"))
            rx, tx = _pair(d.get("NetIO"))
            bi, bo = _pair(d.get("BlockIO"))
            try:
                cpu = float(str(d.get("CPUPerc", "0")).strip().rstrip("%"))
            except Exception:
                cpu = 0.0
            rows[name] = {"t": now, "cpu": cpu, "mem_mb": mem_u / (1024.0 * 1024.0),
                          "mem_limit_mb": mem_l / (1024.0 * 1024.0),
                          "rx": rx, "tx": tx, "block_r": bi, "block_w": bo,
                          "pids": _int_or_none(d.get("PIDs")) or 0}
        with self.lock:
            for name, row in rows.items():
                h = self.hist.setdefault(name, deque(maxlen=self.KEEP))
                prev = h[-1] if h else None
                row["rx_rate"] = row["tx_rate"] = 0.0
                if prev:
                    dt = max(0.5, row["t"] - prev["t"])
                    row["rx_rate"] = max(0.0, (row["rx"] - prev["rx"]) / dt)
                    row["tx_rate"] = max(0.0, (row["tx"] - prev["tx"]) / dt)
                h.append(row)
            self.latest = rows
            for gone in [n for n in self.hist if n not in rows]:
                if len(self.hist[gone]) and now - self.hist[gone][-1]["t"] > 600:
                    self.hist.pop(gone, None)
        return rows

    def _loop(self):
        while not self.stop_flag.is_set():
            try:
                self.sample_once()
            except Exception:
                pass
            self.stop_flag.wait(self.interval)

    def report(self):
        with self.lock:
            out = {}
            for name, h in self.hist.items():
                rows = list(h)
                if not rows:
                    continue
                cur = rows[-1]
                out[name] = {
                    "cpu": round(cur["cpu"], 1),
                    "mem_mb": round(cur["mem_mb"], 1),
                    "mem_limit_mb": round(cur["mem_limit_mb"], 1),
                    "mem_pct": round(100.0 * cur["mem_mb"] / cur["mem_limit_mb"], 1)
                    if cur["mem_limit_mb"] else 0.0,
                    "rx_total": cur["rx"], "tx_total": cur["tx"],
                    "total_bytes": cur["rx"] + cur["tx"],
                    "rx_rate": round(cur["rx_rate"], 1), "tx_rate": round(cur["tx_rate"], 1),
                    "block_r": cur["block_r"], "block_w": cur["block_w"],
                    "pids": cur["pids"],
                    "spark_cpu": [round(r["cpu"], 1) for r in rows[-60:]],
                    "spark_net": [round((r["rx_rate"] + r["tx_rate"]) / 1024.0, 2)
                                  for r in rows[-60:]],
                    "spark_mem": [round(r["mem_mb"], 1) for r in rows[-60:]],
                    "age": round(time.time() - rows[0]["t"]),
                }
            return out


STATS = StatsSampler()


# ===========================================================================
# terminal sessions (a real pty into the container)
# ===========================================================================

class TermSession(object):
    MAX_BUF = 512 * 1024

    def __init__(self, container, cols=100, rows=28, user=None, shell=None):
        self.id = uuid.uuid4().hex[:12]
        self.container = container
        self.cols, self.rows = int(cols), int(rows)
        self.chunks = deque()
        self.total = 0
        self.seq = 0
        self.closed = False
        self.lock = threading.Condition()
        self.exit_code = None

        shell = shell or "/bin/bash"
        cmd = ["docker", "exec", "-it", "-e", "TERM=xterm-256color",
               "-e", "COLUMNS=%d" % self.cols, "-e", "LINES=%d" % self.rows,
               "-w", "/config"]
        if user:
            cmd += ["-u", str(user)]
        # No stderr redirect here: bash writes its prompt to stderr, so hiding
        # it gives you a shell that looks dead until you type.
        cmd += [container, "/bin/sh", "-c",
                "if command -v %s >/dev/null 2>&1; then exec %s -l; else exec /bin/sh -l; fi"
                % (shell, shell)]

        self.pid, self.fd = pty.fork()
        if self.pid == 0:                      # child
            try:
                os.environ["TERM"] = "xterm-256color"
                os.execvp(cmd[0], cmd)
            except Exception:
                os._exit(127)
        self.resize(self.cols, self.rows)
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                r, _, _ = select.select([self.fd], [], [], 0.5)
                if not r:
                    if self._child_gone():
                        break
                    continue
                data = os.read(self.fd, 65536)
                if not data:
                    break
                self._append(data)
            except (OSError, ValueError):
                break
        self._finish()

    def _child_gone(self):
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid == self.pid:
                self.exit_code = os.waitstatus_to_exitcode(status) \
                    if hasattr(os, "waitstatus_to_exitcode") else 0
                return True
        except ChildProcessError:
            return True
        except OSError:
            return True
        return False

    def _append(self, data):
        with self.lock:
            self.seq += 1
            self.chunks.append((self.seq, data))
            self.total += len(data)
            while self.total > self.MAX_BUF and len(self.chunks) > 1:
                self.total -= len(self.chunks.popleft()[1])
            self.lock.notify_all()

    def _finish(self):
        with self.lock:
            self.closed = True
            self.lock.notify_all()
        try:
            os.close(self.fd)
        except OSError:
            pass

    def read_since(self, cursor, timeout=20.0):
        deadline = time.time() + timeout
        with self.lock:
            while True:
                out = [(s, d) for s, d in self.chunks if s > cursor]
                if out:
                    return out
                if self.closed or time.time() >= deadline:
                    return []
                self.lock.wait(min(1.0, max(0.05, deadline - time.time())))

    def write(self, data):
        if self.closed:
            raise RuntimeError("session closed")
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        os.write(self.fd, data)

    def resize(self, cols, rows):
        self.cols, self.rows = int(cols), int(rows)
        try:
            import termios as t
            fcntl.ioctl(self.fd, t.TIOCSWINSZ,
                        struct.pack("HHHH", self.rows, self.cols, 0, 0))
            os.kill(self.pid, signal.SIGWINCH)
        except Exception:
            pass

    def close(self):
        try:
            os.kill(self.pid, signal.SIGHUP)
        except Exception:
            pass
        self.closed = True


TERMS = {}
TERMS_LOCK = threading.Lock()


def term_open(container, cols=100, rows=28, user=None):
    with TERMS_LOCK:
        for s in list(TERMS.values()):
            if s.closed:
                TERMS.pop(s.id, None)
        if len(TERMS) >= 12:
            raise RuntimeError("too many open terminals")
    s = TermSession(container, cols, rows, user=user)
    with TERMS_LOCK:
        TERMS[s.id] = s
    return s


def term_get(sid):
    with TERMS_LOCK:
        return TERMS.get(sid)


# ===========================================================================
# web server
# ===========================================================================

SERVER_JSON = os.path.join(STATE, "server.json")
MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml",
        ".json": "application/json", ".ico": "image/x-icon",
        ".png": "image/png", ".woff2": "font/woff2"}


def get_token(create=True):
    tok = jload(TOKEN_FILE.replace(".json", ".json"), None) if False else None
    try:
        with open(TOKEN_FILE) as fh:
            tok = fh.read().strip()
    except Exception:
        tok = None
    if not tok and create:
        ensure_dirs()
        tok = uuid.uuid4().hex
        with open(TOKEN_FILE, "w") as fh:
            fh.write(tok)
        try:
            os.chmod(TOKEN_FILE, 0o600)
        except OSError:
            pass
    return tok


class Handler(BaseHTTPRequestHandler):
    server_version = "SelkiesForge/" + VERSION
    protocol_version = "HTTP/1.1"
    require_token = False
    token = None

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):
        if os.environ.get("FORGE_HTTP_LOG"):
            sys.stderr.write("[http] %s\n" % (fmt % args))

    def _authed(self):
        if not self.require_token:
            return True
        want = self.token
        got = self.headers.get("X-Forge-Token")
        if not got:
            q = self._query()
            got = q.get("k")
        if not got:
            cookie = self.headers.get("Cookie") or ""
            m = re.search(r"forge_token=([0-9a-f]+)", cookie)
            got = m.group(1) if m else None
        return bool(want) and got == want

    def _query(self):
        if "?" not in self.path:
            return {}
        import urllib.parse as up
        return {k: v[0] for k, v in up.parse_qs(self.path.split("?", 1)[1]).items()}

    def _route(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if not n:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {"_raw": raw.decode("utf-8", "replace")}

    def _send(self, code, payload, ctype="application/json", extra=None):
        if ctype.startswith("application/json") and not isinstance(payload, (bytes, str)):
            payload = json.dumps(payload)
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _err(self, code, msg):
        self._send(code, {"error": str(msg)})

    def _sse_open(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _sse_send(self, data, event=None, eid=None):
        buf = []
        if event:
            buf.append("event: %s" % event)
        if eid is not None:
            buf.append("id: %s" % eid)
        buf.append("data: %s" % (data if isinstance(data, str) else json.dumps(data)))
        buf.append("")
        buf.append("")
        self.wfile.write("\n".join(buf).encode("utf-8"))
        self.wfile.flush()

    # -- verbs ------------------------------------------------------------
    def do_GET(self):
        route = self._route()
        if route in ("/", "/index.html"):
            return self._static("index.html")
        if route in ("/app.css", "/app.js", "/term.js", "/logos.js", "/favicon.ico"):
            return self._static(route.lstrip("/"))
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        if not self._authed():
            return self._err(401, "token required")
        try:
            return self._api_get(route)
        except Exception as ex:
            return self._err(500, ex)

    def do_POST(self):
        route = self._route()
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        if not self._authed():
            return self._err(401, "token required")
        try:
            return self._api_post(route, self._body())
        except Exception as ex:
            return self._err(500, ex)

    def _static(self, name):
        path = os.path.join(APPDIR, name)
        if not os.path.isfile(path):
            return self._err(404, "%s missing" % name)
        with open(path, "rb") as fh:
            data = fh.read()
        ext = os.path.splitext(name)[1]
        extra = {}
        if name == "index.html" and self.require_token and self.token:
            q = self._query()
            if q.get("k") == self.token:
                extra["Set-Cookie"] = "forge_token=%s; Path=/; SameSite=Lax; Max-Age=86400" % self.token
        return self._send(200, data, MIME.get(ext, "application/octet-stream"), extra)

    # -- API --------------------------------------------------------------
    def _api_get(self, route):
        if route == "/api/boot":
            host = host_info(fresh=True)
            return self._send(200, {
                "version": VERSION,
                "host": host,
                "catalog": [public_entry(e) for e in catalog.CATALOG],
                "families": sorted({e["family"] for e in catalog.CATALOG}),
                "family_labels": catalog.FAMILY_LABEL,
                "desktops": sorted({e["de_label"] for e in catalog.CATALOG}),
                "tastes": TASTE_BLURB,
                "quick_picks": catalog.QUICK_PICKS,
                "instances": docker_instances(),
                "counts": {"total": len(catalog.CATALOG),
                           "runnable": sum(1 for e in catalog.CATALOG
                                           if host["arch"] in e["arches"])},
            })
        if route == "/api/host":
            return self._send(200, host_info(fresh=True))
        if route == "/api/doctor":
            return self._send(200, cli_doctor())
        if route == "/api/instances":
            return self._send(200, {"instances": docker_instances()})
        if route == "/api/stats":
            return self._send(200, {"stats": STATS.report(), "host": host_info()})
        if route == "/api/jobs":
            with JOBS_LOCK:
                return self._send(200, {"jobs": [j.snapshot() for j in JOBS.values()]})
        m = re.match(r"^/api/job/([0-9a-f]+)$", route)
        if m:
            job = job_get(m.group(1))
            return self._send(200, job.snapshot()) if job else self._err(404, "no such job")
        m = re.match(r"^/api/job/([0-9a-f]+)/events$", route)
        if m:
            return self._stream_job(m.group(1))
        m = re.match(r"^/api/term/([0-9a-f]+)/stream$", route)
        if m:
            return self._stream_term(m.group(1))
        m = re.match(r"^/api/entry/([A-Za-z0-9_.-]+)$", route)
        if m:
            e = catalog.BY_ID.get(m.group(1))
            if not e:
                return self._err(404, "no such entry")
            out = public_entry(e)
            out["recipe"] = {k: v for k, v in (e.get("recipe") or {}).items()
                            if k in ("pkgs", "session", "pm", "image", "theme")}
            if e["kind"] == "build":
                out["dockerfile"] = gen_dockerfile(e)
                out["startwm"] = gen_startwm(e)
            out["plan"] = plan_resources(e, host_info())
            return self._send(200, out)
        m = re.match(r"^/api/logs/([A-Za-z0-9_.-]+)$", route)
        if m:
            tail = _int_or_none(self._query().get("tail")) or 200
            return self._send(200, {"logs": container_logs(m.group(1), min(2000, tail))})
        return self._err(404, "no such endpoint")

    def _api_post(self, route, body):
        if route == "/api/smart":
            prefs = {k: body.get(k) for k in
                     ("taste", "purpose", "family", "allow_build", "max_dl_mb", "want_tunnel")
                     if body.get(k) is not None}
            limit = int(body.get("limit") or 3)
            return self._send(200, recommend(prefs, limit=clamp(limit, 1, 12)))
        if route == "/api/launch":
            eid = body.get("id")
            if eid not in catalog.BY_ID:
                return self._err(400, "unknown catalog id")
            entry = catalog.BY_ID[eid]
            host = host_info(fresh=True)
            plan = plan_resources(entry, host)
            for k in ("memory_mb", "cpus", "shm_mb", "disk_mb"):
                if body.get("plan", {}).get(k):
                    plan[k] = body["plan"][k]
            plan["memory_mb"] = int(clamp(plan["memory_mb"], 256, max(256, host["mem_total_mb"])))
            plan["cpus"] = float(clamp(float(plan["cpus"]), 0.25, host["cpus"]))
            plan["shm_mb"] = int(clamp(plan["shm_mb"], 64, 4096))
            opts = body.get("opts") or {}
            job = job_put(Job("launch", eid, entry["name"]))

            def work():
                try:
                    launch(eid, plan, opts, job=job, name=opts.get("name"))
                except Exception:
                    pass
            job.thread = threading.Thread(target=work, daemon=True)
            job.thread.start()
            return self._send(200, {"job": job.snapshot(), "plan": plan})
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/retune$", route)
        if m:
            return self._send(200, retune(m.group(1), body.get("memory_mb"), body.get("cpus")))
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/([a-z]+)$", route)
        if m:
            return self._send(200, instance_action(m.group(1), m.group(2), body))
        if route == "/api/term":
            name = body.get("container") or ""
            if not re.match(r"^[A-Za-z0-9_.-]+$", name):
                return self._err(400, "bad container name")
            # One targeted inspect; scanning every forge container here cost
            # a couple of seconds before the shell even started.
            rc, out, _ = run(["docker", "inspect", "-f",
                              '{{.State.Running}}|{{index .Config.Labels "%s.entry"}}' % LABEL,
                              name], timeout=20)
            running, _, lbl = (out.strip().partition("|"))
            if rc != 0 or running != "true" or not lbl:
                return self._err(400, "%s is not a running forge container" % name)
            s = term_open(name, body.get("cols") or 100, body.get("rows") or 28,
                          user=body.get("user"))
            return self._send(200, {"id": s.id, "container": name})
        m = re.match(r"^/api/term/([0-9a-f]+)/(input|resize|close)$", route)
        if m:
            s = term_get(m.group(1))
            if not s:
                return self._err(404, "no such terminal")
            what = m.group(2)
            if what == "input":
                s.write(body.get("data") or "")
            elif what == "resize":
                s.resize(body.get("cols") or 100, body.get("rows") or 28)
            else:
                s.close()
            return self._send(200, {"ok": True, "closed": s.closed})
        return self._err(404, "no such endpoint")

    # -- streams ----------------------------------------------------------
    def _stream_job(self, jid):
        job = job_get(jid)
        if not job:
            return self._err(404, "no such job")
        cursor = _int_or_none(self.headers.get("Last-Event-ID")) \
            or _int_or_none(self._query().get("cursor")) or 0
        self._sse_open()
        try:
            self._sse_send(job.snapshot(), event="snapshot")
            idle = 0
            while True:
                evs = job.since(cursor, timeout=8.0)
                if evs:
                    idle = 0
                    for ev in evs:
                        cursor = ev["seq"]
                        self._sse_send(ev, event=ev["type"], eid=ev["seq"])
                else:
                    idle += 1
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                if job.status != "running":
                    remaining = [e for e in job.events if e["seq"] > cursor]
                    for ev in remaining:
                        cursor = ev["seq"]
                        self._sse_send(ev, event=ev["type"], eid=ev["seq"])
                    self._sse_send(job.snapshot(), event="final")
                    return
                if idle > 150:
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _stream_term(self, sid):
        s = term_get(sid)
        if not s:
            return self._err(404, "no such terminal")
        cursor = _int_or_none(self.headers.get("Last-Event-ID")) \
            or _int_or_none(self._query().get("cursor")) or 0
        self._sse_open()
        try:
            while True:
                chunks = s.read_since(cursor, timeout=8.0)
                if chunks:
                    for seq, data in chunks:
                        cursor = seq
                        self._sse_send(base64.b64encode(data).decode("ascii"),
                                       event="data", eid=seq)
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                if s.closed:
                    self._sse_send({"exit": s.exit_code}, event="closed")
                    return
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


def serve(bind="127.0.0.1", port=8787, open_tunnel=False, quiet=False):
    ensure_dirs()
    loopback = bind in ("127.0.0.1", "localhost", "::1")
    Handler.require_token = not loopback
    Handler.token = get_token(create=not loopback) if not loopback else None

    for attempt in range(60):
        try:
            httpd = ThreadingHTTPServer((bind, port), Handler)
            break
        except OSError as ex:
            if ex.errno in (errno.EADDRINUSE, errno.EACCES):
                port += 1
                continue
            raise
    else:
        raise RuntimeError("could not bind a port for the web UI")

    httpd.daemon_threads = True
    STATS.start()

    url = "http://%s:%d/" % ("localhost" if loopback else bind, port)
    if Handler.token:
        url += "?k=" + Handler.token
    info = {"pid": os.getpid(), "port": port, "bind": bind, "url": url,
            "token": Handler.token, "started": time.time(), "version": VERSION}
    jsave(SERVER_JSON, info)

    tun = None
    if open_tunnel:
        try:
            tun = tunnel_start("__webui__", port, mode="http")
            info["tunnel"] = tun["url"] + ("?k=" + Handler.token if Handler.token else "")
            jsave(SERVER_JSON, info)
        except Exception as ex:
            info["tunnel_error"] = str(ex)
            jsave(SERVER_JSON, info)

    if not quiet:
        print(json.dumps(info))
        sys.stdout.flush()

    watchdog = threading.Thread(target=_tunnel_watchdog, daemon=True)
    watchdog.start()

    try:
        httpd.serve_forever(poll_interval=0.4)
    except KeyboardInterrupt:
        pass
    finally:
        STATS.stop()
        if tun:
            tunnel_stop("__webui__")
        try:
            os.remove(SERVER_JSON)
        except OSError:
            pass


def _tunnel_watchdog():
    """Serveo drops tunnels now and then; put them back."""
    while True:
        time.sleep(25)
        try:
            for it in docker_instances():
                t = it.get("tunnel")
                if not t or not it["running"] or t.get("alive"):
                    continue
                port = (it["ports"] or {}).get(
                    str(KASM_HTTPS) if it["profile"] == "kasm" else str(SELKIES_HTTP))
                if not port:
                    continue
                try:
                    tunnel_start(it["name"], port, mode=t.get("mode", "http"))
                except Exception:
                    pass
        except Exception:
            pass


# ===========================================================================
# CLI
# ===========================================================================

def cli_launch_stream(args):
    """Launch with line-oriented output the shell front end can render."""
    entry = catalog.BY_ID.get(args.id)
    if not entry:
        print("E unknown catalog id: %s" % args.id)
        return 2
    host = host_info(fresh=True)
    plan = plan_resources(entry, host)
    if args.memory:
        plan["memory_mb"] = int(args.memory)
    if args.cpus:
        plan["cpus"] = float(args.cpus)
    if args.shm:
        plan["shm_mb"] = int(args.shm)
    if args.disk:
        plan["disk_mb"] = int(args.disk)
    opts = {"tunnel": not args.no_tunnel, "name": args.name,
            "gpu": args.gpu, "seccomp_unconfined": args.seccomp,
            "health_timeout": args.timeout}
    if args.user and args.password:
        opts["username"], opts["password"] = args.user, args.password
    if args.subdomain:
        opts["subdomain"] = args.subdomain

    job = job_put(Job("launch", args.id, entry["name"]))
    done = {"result": None, "error": None}

    def work():
        try:
            done["result"] = launch(args.id, plan, opts, job=job, name=args.name)
        except Exception as ex:
            done["error"] = str(ex)

    th = threading.Thread(target=work, daemon=True)
    th.start()

    cursor = 0
    print("P 0 start Preparing")
    sys.stdout.flush()
    while True:
        evs = job.since(cursor, timeout=2.0)
        for ev in evs:
            cursor = ev["seq"]
            typ, data = ev["type"], ev["data"]
            if typ == "log":
                print("L %s" % data["line"][:400])
            elif typ == "phase":
                print("P %d %s %s" % (int(data["progress"] * 100), data["phase"],
                                      data["label"]))
            elif typ == "progress":
                extra = data.get("extra") or {}
                note = ""
                if extra.get("bytes_total"):
                    note = " %s/%s" % (human(extra["bytes"]), human(extra["bytes_total"]))
                elif extra.get("packages_total"):
                    note = " %s/%s pkgs" % (extra["packages"], extra["packages_total"])
                print("P %d %s %s%s" % (int(data["progress"] * 100), data["phase"],
                                        data["phase"], note))
            elif typ == "error":
                print("E %s" % data["message"].replace("\n", " | "))
                for h in data.get("hints", []):
                    print("H %s" % h)
            elif typ == "done":
                print("D %s" % json.dumps(data))
        sys.stdout.flush()
        if job.status != "running" and not job.since(cursor, timeout=0.05):
            break
    th.join(timeout=5)
    return 0 if done["result"] else 1


def cli_doctor():
    host = host_info(fresh=True)
    checks = []

    def add(name, ok, detail, fix=None, severity="error"):
        checks.append({"name": name, "ok": bool(ok), "detail": detail, "fix": fix,
                       "severity": severity})

    add("python", sys.version_info >= (3, 8), "python %s" % host["python"],
        "install python 3.8 or newer")
    ok, err = docker_ok() if have("docker") else (False, "docker is not installed")
    add("docker", ok, host.get("docker_version") and
        "docker %s, %s driver" % (host["docker_version"], host["storage_driver"]) or err,
        "install docker, then add yourself to the docker group")
    add("ssh", host["ssh"], "ssh client present" if host["ssh"] else "missing",
        "install openssh-client for serveo tunnels")
    add("memory", host["mem_avail_mb"] >= 900,
        "%s free of %s" % (human_mb(host["mem_avail_mb"]), human_mb(host["mem_total_mb"])),
        "close something, or pick a feather-weight desktop")
    add("disk", host["disk_free_mb"] >= 6000,
        "%s free on %s" % (human_mb(host["disk_free_mb"]), host.get("docker_root") or "/"),
        "docker system prune -af")
    add("architecture", bool([e for e in catalog.CATALOG if host["arch"] in e["arches"]]),
        "%s, %d of %d catalog entries available"
        % (host["arch"], sum(1 for e in catalog.CATALOG if host["arch"] in e["arches"]),
           len(catalog.CATALOG)), None)
    add("disk quota", host["quota_support"],
        "hard per-container caps supported" if host["quota_support"] else
        "%s on %s: caps are advisory only" % (host.get("storage_driver"),
                                             host.get("backing_fs")),
        "use xfs with project quotas if you need hard caps", severity="info")
    net_ok = False
    try:
        socket.create_connection(("serveo.net", 22), timeout=6).close()
        net_ok = True
    except Exception:
        pass
    add("serveo", net_ok, "serveo.net:22 reachable" if net_ok else
        "cannot reach serveo.net:22", "tunnels will be unavailable; local URLs still work",
        severity="warn")
    return {"host": host, "checks": checks,
            "ok": all(c["ok"] for c in checks if c["name"] in
                      ("python", "docker", "memory", "disk"))}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="forge-engine", description="Selkies Forge engine")
    ap.add_argument("--version", action="version", version=VERSION)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve")
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--tunnel", action="store_true")
    p.add_argument("--quiet", action="store_true")

    sub.add_parser("host")
    sub.add_parser("doctor")
    sub.add_parser("instances")
    sub.add_parser("stats")

    p = sub.add_parser("list")
    p.add_argument("--quick", action="store_true")
    p.add_argument("--runnable", action="store_true")
    p.add_argument("--family")
    p.add_argument("--kind")
    p.add_argument("--format", default="json", choices=["json", "tsv"])

    p = sub.add_parser("info")
    p.add_argument("id")

    p = sub.add_parser("dockerfile")
    p.add_argument("id")

    p = sub.add_parser("smart")
    p.add_argument("--taste", default="balanced", choices=sorted(TASTES))
    p.add_argument("--purpose", default="general", choices=sorted(PURPOSE_TAGS))
    p.add_argument("--family")
    p.add_argument("--max-dl", type=int, dest="max_dl")
    p.add_argument("--no-build", action="store_true")
    p.add_argument("--limit", type=int, default=3)

    p = sub.add_parser("launch")
    p.add_argument("id")
    p.add_argument("--name")
    p.add_argument("--memory", type=int)
    p.add_argument("--cpus", type=float)
    p.add_argument("--shm", type=int)
    p.add_argument("--disk", type=int)
    p.add_argument("--no-tunnel", action="store_true")
    p.add_argument("--subdomain")
    p.add_argument("--user")
    p.add_argument("--password")
    p.add_argument("--gpu", action="store_true")
    p.add_argument("--seccomp", action="store_true")
    p.add_argument("--timeout", type=int, default=300)

    p = sub.add_parser("do")
    p.add_argument("name")
    p.add_argument("action", choices=["start", "stop", "restart", "remove",
                                      "tunnel", "untunnel"])
    p.add_argument("--purge", action="store_true")
    p.add_argument("--subdomain")

    p = sub.add_parser("retune")
    p.add_argument("name")
    p.add_argument("--memory", type=int)
    p.add_argument("--cpus", type=float)

    p = sub.add_parser("logs")
    p.add_argument("name")
    p.add_argument("--tail", type=int, default=200)

    a = ap.parse_args(argv)
    ensure_dirs()

    if a.cmd == "serve":
        serve(a.bind, a.port, a.tunnel, a.quiet)
        return 0
    if a.cmd == "host":
        print(json.dumps(host_info(fresh=True), indent=2))
        return 0
    if a.cmd == "doctor":
        print(json.dumps(cli_doctor(), indent=2))
        return 0
    if a.cmd == "instances":
        print(json.dumps({"instances": docker_instances()}, indent=2))
        return 0
    if a.cmd == "stats":
        STATS.sample_once()
        time.sleep(1.2)
        STATS.sample_once()
        print(json.dumps({"stats": STATS.report()}, indent=2))
        return 0
    if a.cmd == "list":
        host = host_info()
        items = [public_entry(e) for e in catalog.CATALOG]
        if a.quick:
            order = {k: i for i, k in enumerate(catalog.QUICK_PICKS)}
            items = sorted([i for i in items if i["id"] in order],
                           key=lambda i: order[i["id"]])
        if a.runnable:
            items = [i for i in items if host["arch"] in i["arches"]]
        if a.family:
            items = [i for i in items if i["family"] == a.family]
        if a.kind:
            items = [i for i in items if i["kind"] == a.kind]
        if a.format == "json":
            print(json.dumps({"entries": items, "host": host}))
        else:
            for i in items:
                print("\t".join([i["id"], i["name"], i["family_label"], i["de_label"],
                                 i["kind"], i["weight"], str(i["dl_mb"]),
                                 str(i["ram_rec"]), str(i["cpu_rec"]), str(i["beauty"]),
                                 i["subtitle"], i["desc"]]))
        return 0
    if a.cmd == "info":
        e = catalog.BY_ID.get(a.id)
        if not e:
            print(json.dumps({"error": "unknown id"}))
            return 2
        out = public_entry(e)
        out["plan"] = plan_resources(e, host_info())
        print(json.dumps(out, indent=2))
        return 0
    if a.cmd == "dockerfile":
        e = catalog.BY_ID.get(a.id)
        if not e or e["kind"] != "build":
            print("# nothing to build for %s" % a.id)
            return 2
        print(gen_dockerfile(e))
        return 0
    if a.cmd == "smart":
        prefs = {"taste": a.taste, "purpose": a.purpose,
                 "allow_build": not a.no_build}
        if a.family:
            prefs["family"] = a.family
        if a.max_dl:
            prefs["max_dl_mb"] = a.max_dl
        print(json.dumps(recommend(prefs, limit=a.limit), indent=2))
        return 0
    if a.cmd == "launch":
        return cli_launch_stream(a)
    if a.cmd == "do":
        try:
            print(json.dumps(instance_action(a.name, a.action,
                                             {"purge": a.purge, "subdomain": a.subdomain})))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "retune":
        try:
            print(json.dumps(retune(a.name, a.memory, a.cpus)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "logs":
        print(container_logs(a.name, a.tail))
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
__FORGE_FILE_ENGINE_PY__
  cat > "$FORGE_APP/index.html" <<'__FORGE_FILE_INDEX_HTML__'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Selkies Forge</title>
<link rel="stylesheet" href="/app.css">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%235aa6ff'/%3E%3Cpath d='M9 22l7-13 7 13z' fill='%23061020'/%3E%3C/svg%3E">
</head>
<body>
<div class="bg"></div>

<div class="app">
  <header class="topbar">
    <div class="brand">
      <span class="spark">▲</span>
      <span>Selkies Forge<small>desktops on tap</small></span>
    </div>
    <div class="search">
      <span class="mag">⌕</span>
      <input id="q" type="text" placeholder="Search 150+ desktops &mdash; try xfce, kali, tiny, kde  ( / )" autocomplete="off" spellcheck="false">
    </div>
    <div class="meters" id="meters"></div>
  </header>

  <nav class="rail" id="rail">
    <button data-view="browse" class="on"><span class="ico">◧</span>Browse<span class="tag" id="tagCat">-</span></button>
    <button data-view="manager"><span class="ico">▦</span>Manager<span class="tag" id="tagInst">0</span></button>
    <button data-view="host"><span class="ico">◉</span>This machine</button>
    <hr>
    <button id="liteBtn" class="ghost"><span class="ico">✦</span>Lite mode</button>
    <div class="note">Lite mode drops the blur and animation. It turns itself on for small devices.</div>
    <hr>
    <div class="note">Shortcuts<br>/ search &middot; 1 browse &middot; 2 manager &middot; 3 machine</div>
  </nav>

  <main class="main">

    <!-- ------------------------------------------------------- browse -->
    <section class="view on" id="v-browse">
      <h1 class="h1">Pick a desktop</h1>
      <p class="sub">Every entry here is a real, running Linux desktop streamed to your browser.
        <b id="count">-</b> &middot; prebuilt images pull in minutes, the rest are built on this machine.</p>

      <div class="panel">
        <h3>Let it choose <span class="hint">scored against this machine's actual free memory, cores and disk</span></h3>
        <div class="row" style="align-items:flex-start;gap:20px">
          <div style="min-width:200px">
            <div class="what" style="font-size:11px;color:var(--dim-2);margin-bottom:6px">WHAT MATTERS MOST</div>
            <div class="chips" id="tasteChips"></div>
          </div>
          <div style="min-width:200px">
            <div class="what" style="font-size:11px;color:var(--dim-2);margin-bottom:6px">WHAT FOR</div>
            <div class="chips" id="purposeChips"></div>
          </div>
          <div class="spacer"></div>
          <button class="btn primary" id="smartBtn">Choose for me</button>
        </div>
        <div id="smartOut" style="margin-top:14px"></div>
      </div>

      <div class="panel tight">
        <div class="chips" id="famChips" style="margin-bottom:9px"></div>
        <div class="row">
          <div class="chips" id="wChips"></div>
          <div class="spacer"></div>
          <select id="sort" style="width:auto">
            <option value="beauty">Sort: best looking</option>
            <option value="light">Sort: lightest</option>
            <option value="fast">Sort: snappiest</option>
            <option value="small">Sort: smallest download</option>
            <option value="name">Sort: name</option>
          </select>
        </div>
      </div>

      <div class="grid" id="grid"></div>
    </section>

    <!-- ---------------------------------------------------- configure -->
    <section class="view" id="v-configure">
      <button class="btn sm ghost" data-back="browse" style="margin-bottom:12px">&larr; back to the catalog</button>
      <div class="panel" id="cfgHero"></div>
      <div class="cfg">
        <div>
          <div class="panel" id="cfgTune"></div>
          <div class="panel" id="cfgGo"></div>
        </div>
        <div>
          <div class="panel" id="cfgSpecs"></div>
          <div class="panel" id="cfgOpts"></div>
        </div>
      </div>
    </section>

    <!-- ------------------------------------------------------- launch -->
    <section class="view" id="v-launch">
      <div class="panel" id="lTitle"></div>
      <div class="panel">
        <div class="steps" id="lSteps"></div>
        <div class="progress-wrap">
          <span class="what" id="lWhat">starting</span>
          <div class="progress"><i id="lBar"></i></div>
          <span class="pct" id="lPct">0%</span>
        </div>
        <div class="term-wrap">
          <div class="term-head">
            <span class="lights"><i></i><i></i><i></i></span>
            <span>live build and pull output</span>
          </div>
          <pre class="term tall" id="lTerm"></pre>
        </div>
      </div>
      <div id="lResult"></div>
    </section>

    <!-- ------------------------------------------------------ manager -->
    <section class="view" id="v-manager">
      <h1 class="h1">Running desktops</h1>
      <p class="sub">Live CPU, memory and the bandwidth each instance has pulled through its tunnel.</p>
      <div class="chips" id="instTotals" style="margin-bottom:14px"></div>
      <div id="instList"></div>
    </section>

    <!-- -------------------------------------------------------- shell -->
    <section class="view" id="v-shell">
      <h1 class="h1">Shell</h1>
      <p class="sub">A real pty inside <b id="shTitle">-</b>. Click the terminal and type.</p>
      <div class="term-wrap">
        <div class="term-head">
          <span class="lights"><i></i><i></i><i></i></span>
          <span id="shHead">docker exec</span>
          <div class="spacer"></div>
          <button class="btn sm ghost" id="shFit">Fit</button>
          <button class="btn sm ghost" id="shClose">Close</button>
        </div>
        <pre class="term tall" id="shTerm" tabindex="0" style="outline:none"></pre>
      </div>
    </section>

    <!-- --------------------------------------------------------- host -->
    <section class="view" id="v-host">
      <h1 class="h1">This machine</h1>
      <p class="sub">What the forge checked before it offered you anything.</p>
      <div class="cfg">
        <div class="panel"><h3>Checks</h3><div class="result" id="hostChecks"></div></div>
        <div class="panel"><h3>Facts</h3><div id="hostFacts"></div></div>
      </div>
    </section>

  </main>
</div>

<div id="modal" style="display:none;position:fixed;inset:0;z-index:50;background:rgba(3,7,14,.7);place-items:center;padding:24px">
  <div class="panel" style="max-width:860px;width:100%;margin:0" onclick="event.stopPropagation()">
    <div class="row" style="margin-bottom:10px">
      <h3 id="modalTitle" style="margin:0">-</h3>
      <div class="spacer"></div>
      <button class="btn sm ghost" id="modalClose">Close</button>
    </div>
    <div id="modalBody"></div>
  </div>
</div>

<div class="toasts" id="toasts"></div>

<script src="/logos.js"></script>
<script src="/term.js"></script>
<script src="/app.js"></script>
</body>
</html>
__FORGE_FILE_INDEX_HTML__
  cat > "$FORGE_APP/app.css" <<'__FORGE_FILE_APP_CSS__'
/* Selkies Forge - dark glass, blue tint, cheap to paint. */

:root {
  --bg: #060a12;
  --bg-2: #0a1120;
  --glass: rgba(16, 26, 46, 0.58);
  --glass-2: rgba(24, 36, 62, 0.46);
  --glass-3: rgba(10, 17, 32, 0.74);
  --line: rgba(142, 174, 226, 0.14);
  --line-2: rgba(142, 174, 226, 0.3);
  --txt: #e9effd;
  --dim: #9db2d8;
  --dim-2: #6a80a8;
  --acc: #5aa6ff;
  --acc-2: #8b7dff;
  --acc-soft: rgba(90, 166, 255, 0.14);
  --ok: #3ddc97;
  --warn: #ffc24d;
  --bad: #ff6b7e;
  --r-s: 10px;
  --r-m: 14px;
  --r-l: 20px;
  --blur: 16px;
  --sh: 0 10px 34px rgba(2, 6, 16, 0.46);
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --ease: cubic-bezier(0.22, 0.61, 0.36, 1);
}

* { box-sizing: border-box; }

html, body { height: 100%; }

body {
  margin: 0;
  font-family: var(--sans);
  color: var(--txt);
  background: var(--bg);
  font-size: 14.5px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
}

/* One fixed, non-animated background layer: no repaint cost while scrolling. */
.bg {
  position: fixed;
  inset: 0;
  z-index: 0;
  pointer-events: none;
  background:
    radial-gradient(1100px 620px at 12% -8%, rgba(60, 120, 255, 0.20), transparent 60%),
    radial-gradient(900px 560px at 88% 4%, rgba(130, 110, 255, 0.16), transparent 62%),
    radial-gradient(1200px 800px at 50% 110%, rgba(40, 90, 190, 0.14), transparent 60%),
    linear-gradient(180deg, #070c16 0%, #060a12 60%, #05080f 100%);
}

/* ------------------------------------------------------------------ shell */
.app {
  position: relative;
  z-index: 1;
  display: grid;
  grid-template-columns: 232px 1fr;
  grid-template-rows: 60px 1fr;
  height: 100vh;
  height: 100dvh;
}

.topbar {
  grid-column: 1 / -1;
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 0 18px;
  border-bottom: 1px solid var(--line);
  background: var(--glass-3);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
}

.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-weight: 650;
  letter-spacing: 0.2px;
  min-width: 196px;
}

.brand .spark {
  width: 26px;
  height: 26px;
  border-radius: 8px;
  background: linear-gradient(135deg, var(--acc), var(--acc-2));
  display: grid;
  place-items: center;
  box-shadow: 0 0 18px rgba(90, 166, 255, 0.4);
  font-size: 15px;
}

.brand small { color: var(--dim-2); font-weight: 500; font-size: 11px; display: block; }

.search {
  flex: 1;
  max-width: 460px;
  position: relative;
}

.search input {
  width: 100%;
  height: 38px;
  padding: 0 12px 0 38px;
  border-radius: 999px;
  border: 1px solid var(--line);
  background: rgba(10, 18, 34, 0.7);
  color: var(--txt);
  font: inherit;
  outline: none;
  transition: border-color 0.18s var(--ease), box-shadow 0.18s var(--ease);
}

.search input:focus {
  border-color: var(--acc);
  box-shadow: 0 0 0 3px var(--acc-soft);
}

.search .mag {
  position: absolute;
  left: 14px;
  top: 50%;
  transform: translateY(-50%);
  color: var(--dim-2);
  font-size: 13px;
}

.meters { display: flex; gap: 8px; margin-left: auto; align-items: center; }

.meter {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 96px;
  padding: 6px 10px;
  border-radius: var(--r-s);
  border: 1px solid var(--line);
  background: var(--glass-2);
}

.meter b { font-size: 11px; color: var(--dim); font-weight: 600; letter-spacing: 0.3px; }
.meter .v { font-size: 12px; color: var(--txt); font-variant-numeric: tabular-nums; }

.bar {
  height: 4px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  overflow: hidden;
}

.bar > i {
  display: block;
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--acc), var(--acc-2));
  transition: width 0.4s var(--ease);
}

.bar.warn > i { background: linear-gradient(90deg, var(--warn), #ff9a3d); }
.bar.bad > i { background: linear-gradient(90deg, var(--bad), #ff4d6d); }

/* ------------------------------------------------------------------- rail */
.rail {
  border-right: 1px solid var(--line);
  background: var(--glass-3);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  padding: 14px 10px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  overflow-y: auto;
}

.rail button {
  display: flex;
  align-items: center;
  gap: 11px;
  width: 100%;
  padding: 10px 12px;
  border: 1px solid transparent;
  border-radius: var(--r-m);
  background: transparent;
  color: var(--dim);
  font: inherit;
  font-weight: 550;
  cursor: pointer;
  text-align: left;
  transition: background 0.16s var(--ease), color 0.16s var(--ease);
}

.rail button:hover { background: rgba(255, 255, 255, 0.045); color: var(--txt); }

.rail button.on {
  color: #fff;
  background: linear-gradient(135deg, rgba(90, 166, 255, 0.22), rgba(139, 125, 255, 0.14));
  border-color: rgba(90, 166, 255, 0.34);
}

.rail .ico { width: 18px; text-align: center; font-size: 15px; }
.rail .tag {
  margin-left: auto;
  font-size: 11px;
  padding: 1px 7px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: var(--dim);
  font-variant-numeric: tabular-nums;
}
.rail hr { border: 0; border-top: 1px solid var(--line); margin: 10px 4px; }
.rail .note { font-size: 11px; color: var(--dim-2); padding: 4px 12px; line-height: 1.45; }

/* ------------------------------------------------------------------- main */
.main { overflow-y: auto; overflow-x: hidden; padding: 20px 22px 60px; scroll-behavior: smooth; }
.view { display: none; }
.view.on { display: block; animation: rise 0.26s var(--ease) both; }

@keyframes rise {
  from { opacity: 0; transform: translateY(6px); }
  to { opacity: 1; transform: none; }
}

.h1 { font-size: 22px; font-weight: 680; margin: 0 0 4px; letter-spacing: -0.2px; }
.sub { color: var(--dim); margin: 0 0 18px; font-size: 13px; }
.sub b { color: var(--txt); font-weight: 600; }

.panel {
  border: 1px solid var(--line);
  border-radius: var(--r-l);
  background: var(--glass);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  box-shadow: var(--sh);
  padding: 18px;
  margin-bottom: 18px;
}

.panel.tight { padding: 14px; }
.panel h3 { margin: 0 0 12px; font-size: 14px; font-weight: 640; letter-spacing: 0.1px; }
.panel h3 .hint { color: var(--dim-2); font-weight: 500; font-size: 12px; margin-left: 8px; }

/* ----------------------------------------------------------------- chips */
.chips { display: flex; flex-wrap: wrap; gap: 7px; }

.chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 5px 11px;
  border-radius: 999px;
  border: 1px solid var(--line);
  background: rgba(255, 255, 255, 0.035);
  color: var(--dim);
  font-size: 12px;
  font-weight: 550;
  cursor: pointer;
  user-select: none;
  transition: background 0.14s var(--ease), color 0.14s var(--ease), border-color 0.14s var(--ease);
}

.chip:hover { color: var(--txt); border-color: var(--line-2); }
.chip.on { background: var(--acc-soft); border-color: rgba(90, 166, 255, 0.45); color: #dbeaff; }
.chip .n { color: var(--dim-2); font-variant-numeric: tabular-nums; font-size: 11px; }
.chip.static { cursor: default; }

/* ----------------------------------------------------------------- cards */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(286px, 1fr));
  gap: 14px;
}

.card {
  position: relative;
  border: 1px solid var(--line);
  border-radius: var(--r-l);
  background: var(--glass);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  padding: 15px;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  gap: 10px;
  contain: layout paint style;
  content-visibility: auto;
  contain-intrinsic-size: auto 212px;
  transition: transform 0.18s var(--ease), border-color 0.18s var(--ease),
              box-shadow 0.18s var(--ease);
}

.card:hover {
  transform: translateY(-3px);
  border-color: rgba(90, 166, 255, 0.42);
  box-shadow: 0 14px 38px rgba(2, 8, 22, 0.55);
}

.card:focus-visible { outline: 2px solid var(--acc); outline-offset: 2px; }

.card .top { display: flex; gap: 12px; align-items: flex-start; }

.card .logo {
  width: 44px;
  height: 44px;
  flex: 0 0 44px;
  border-radius: 13px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--line);
  display: grid;
  place-items: center;
  color: var(--dim);
}

.card .logo svg { width: 30px; height: 30px; }
.card .name { font-weight: 640; font-size: 14.5px; line-height: 1.25; }
.card .meta { color: var(--dim-2); font-size: 11.5px; margin-top: 2px; }
.card .desc {
  color: var(--dim);
  font-size: 12.4px;
  line-height: 1.45;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.badges { display: flex; flex-wrap: wrap; gap: 5px; }

.badge {
  font-size: 10.5px;
  font-weight: 620;
  letter-spacing: 0.3px;
  text-transform: uppercase;
  padding: 2.5px 7px;
  border-radius: 6px;
  border: 1px solid var(--line);
  color: var(--dim);
  background: rgba(255, 255, 255, 0.03);
  display: inline-flex;
  align-items: center;
  gap: 4px;
}

.badge svg { width: 14px; height: 11px; }
.badge.feather { color: #8ef0c6; border-color: rgba(61, 220, 151, 0.4); background: rgba(61, 220, 151, 0.1); }
.badge.light { color: #b9ecc9; border-color: rgba(120, 220, 160, 0.3); background: rgba(120, 220, 160, 0.08); }
.badge.balanced { color: #a9ccff; border-color: rgba(90, 166, 255, 0.34); background: rgba(90, 166, 255, 0.1); }
.badge.full { color: #ffd79a; border-color: rgba(255, 194, 77, 0.34); background: rgba(255, 194, 77, 0.1); }
.badge.heavy { color: #ffb0bb; border-color: rgba(255, 107, 126, 0.34); background: rgba(255, 107, 126, 0.1); }
.badge.ready { color: #cbb8ff; border-color: rgba(139, 125, 255, 0.4); background: rgba(139, 125, 255, 0.12); }
.badge.off { color: var(--dim-2); opacity: 0.75; }

.specs {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 6px;
  margin-top: auto;
  padding-top: 10px;
  border-top: 1px solid var(--line);
}

.specs div { text-align: center; }
.specs b { display: block; font-size: 12px; font-variant-numeric: tabular-nums; }
.specs span { font-size: 9.5px; color: var(--dim-2); text-transform: uppercase; letter-spacing: 0.4px; }

.beauty { display: flex; align-items: center; gap: 7px; font-size: 11px; color: var(--dim-2); }
.beauty .bar { flex: 1; }

/* --------------------------------------------------------------- buttons */
.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 7px;
  padding: 9px 16px;
  border-radius: var(--r-m);
  border: 1px solid var(--line-2);
  background: rgba(255, 255, 255, 0.045);
  color: var(--txt);
  font: inherit;
  font-weight: 600;
  font-size: 13px;
  cursor: pointer;
  transition: transform 0.12s var(--ease), background 0.16s var(--ease),
              border-color 0.16s var(--ease);
}

.btn:hover { background: rgba(255, 255, 255, 0.085); border-color: var(--acc); }
.btn:active { transform: translateY(1px); }
.btn[disabled] { opacity: 0.45; cursor: not-allowed; transform: none; }

.btn.primary {
  background: linear-gradient(135deg, var(--acc), var(--acc-2));
  border-color: transparent;
  color: #061020;
  box-shadow: 0 8px 26px rgba(90, 166, 255, 0.3);
}

.btn.primary:hover { filter: brightness(1.08); }
.btn.ghost { background: transparent; }
.btn.danger { color: #ffd4da; border-color: rgba(255, 107, 126, 0.42); }
.btn.danger:hover { background: rgba(255, 107, 126, 0.14); border-color: var(--bad); }
.btn.sm { padding: 6px 11px; font-size: 12px; border-radius: 9px; }
.btn.wide { width: 100%; }

.row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.row.end { justify-content: flex-end; }
.spacer { flex: 1; }

/* --------------------------------------------------------------- configure */
.cfg { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr); gap: 18px; }
@media (max-width: 1000px) { .cfg { grid-template-columns: 1fr; } }

.hero { display: flex; gap: 16px; align-items: flex-start; }
.hero .logo { width: 68px; height: 68px; flex: 0 0 68px; border-radius: 18px; }
.hero .logo svg { width: 46px; height: 46px; }
.hero h2 { margin: 0; font-size: 20px; font-weight: 680; }
.hero p { margin: 6px 0 0; color: var(--dim); font-size: 13px; }

.kv { display: grid; grid-template-columns: 128px 1fr; gap: 8px 12px; font-size: 13px; }
.kv dt { color: var(--dim-2); }
.kv dd { margin: 0; font-variant-numeric: tabular-nums; }

.slider { margin-bottom: 15px; }
.slider .lbl { display: flex; justify-content: space-between; font-size: 12.5px; margin-bottom: 7px; }
.slider .lbl b { font-variant-numeric: tabular-nums; }
.slider .lbl .adv { color: var(--dim-2); font-weight: 500; }

input[type="range"] {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: 22px;
  background: transparent;
  cursor: pointer;
}

input[type="range"]::-webkit-slider-runnable-track {
  height: 5px;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--acc) var(--pct, 50%), rgba(255, 255, 255, 0.1) var(--pct, 50%));
}

input[type="range"]::-webkit-slider-thumb {
  -webkit-appearance: none;
  width: 15px;
  height: 15px;
  margin-top: -5px;
  border-radius: 50%;
  background: #fff;
  border: 3px solid var(--acc);
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);
}

input[type="range"]::-moz-range-track { height: 5px; border-radius: 999px; background: rgba(255, 255, 255, 0.1); }
input[type="range"]::-moz-range-progress { height: 5px; border-radius: 999px; background: var(--acc); }
input[type="range"]::-moz-range-thumb { width: 13px; height: 13px; border-radius: 50%; background: #fff; border: 3px solid var(--acc); }

input[type="text"], input[type="password"], select {
  width: 100%;
  height: 36px;
  padding: 0 11px;
  border-radius: var(--r-s);
  border: 1px solid var(--line);
  background: rgba(10, 18, 34, 0.7);
  color: var(--txt);
  font: inherit;
  font-size: 13px;
  outline: none;
}

input:focus, select:focus { border-color: var(--acc); box-shadow: 0 0 0 3px var(--acc-soft); }
label.field { display: block; margin-bottom: 12px; }
label.field > span { display: block; font-size: 12px; color: var(--dim); margin-bottom: 5px; }

.toggle { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; padding: 5px 0; }

.toggle input { display: none; }

.toggle i {
  width: 36px;
  height: 20px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.12);
  position: relative;
  flex: 0 0 36px;
  transition: background 0.18s var(--ease);
}

.toggle i::after {
  content: "";
  position: absolute;
  top: 3px;
  left: 3px;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: #fff;
  transition: transform 0.18s var(--ease);
}

.toggle input:checked + i { background: var(--acc); }
.toggle input:checked + i::after { transform: translateX(16px); }
.toggle span { display: flex; flex-direction: column; gap: 1px; }
.toggle small { display: block; color: var(--dim-2); font-size: 11.5px; line-height: 1.35; }

/* --------------------------------------------------------------- stepper */
.steps { display: flex; gap: 6px; margin-bottom: 14px; flex-wrap: wrap; }

.step {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 6px 12px;
  border-radius: 999px;
  border: 1px solid var(--line);
  font-size: 12px;
  color: var(--dim-2);
  background: rgba(255, 255, 255, 0.025);
}

.step .dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--dim-2);
  flex: 0 0 7px;
}

.step.on { color: #dbeaff; border-color: rgba(90, 166, 255, 0.5); background: var(--acc-soft); }
.step.on .dot { background: var(--acc); box-shadow: 0 0 10px var(--acc); animation: pulse 1.3s ease-in-out infinite; }
.step.done { color: #a6e9c8; border-color: rgba(61, 220, 151, 0.34); }
.step.done .dot { background: var(--ok); }
.step.bad { color: #ffb0bb; border-color: rgba(255, 107, 126, 0.4); }
.step.bad .dot { background: var(--bad); }

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.35; } }

.progress-wrap { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
.progress { flex: 1; height: 8px; border-radius: 999px; background: rgba(255, 255, 255, 0.08); overflow: hidden; }

.progress > i {
  display: block;
  height: 100%;
  width: 0;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--acc), var(--acc-2));
  transition: width 0.3s var(--ease);
}

.progress-wrap .pct { font-variant-numeric: tabular-nums; font-weight: 650; min-width: 46px; text-align: right; }
.progress-wrap .what { color: var(--dim); font-size: 12.5px; min-width: 160px; }

/* -------------------------------------------------------------- terminal */
.term-wrap {
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  background: #04070e;
  overflow: hidden;
  box-shadow: inset 0 0 40px rgba(0, 0, 0, 0.5);
}

.term-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 12px;
  border-bottom: 1px solid var(--line);
  background: rgba(14, 22, 40, 0.8);
  font-size: 11.5px;
  color: var(--dim-2);
}

.term-head .lights { display: flex; gap: 5px; margin-right: 4px; }
.term-head .lights i { width: 9px; height: 9px; border-radius: 50%; background: #2b3a55; }
.term-head .lights i:nth-child(1) { background: #ff5f57; }
.term-head .lights i:nth-child(2) { background: #febc2e; }
.term-head .lights i:nth-child(3) { background: #28c840; }

.term {
  margin: 0;
  padding: 11px 13px;
  font-family: var(--mono);
  font-size: 12.3px;
  line-height: 1.42;
  color: #cfe0f5;
  height: 420px;
  overflow-y: auto;
  overflow-x: auto;
  white-space: pre;
  tab-size: 8;
  overscroll-behavior: contain;
  contain: strict;
}

.term.tall { height: 58vh; }
.term::-webkit-scrollbar, .main::-webkit-scrollbar, .rail::-webkit-scrollbar { width: 9px; height: 9px; }
.term::-webkit-scrollbar-thumb, .main::-webkit-scrollbar-thumb, .rail::-webkit-scrollbar-thumb {
  background: rgba(140, 170, 220, 0.22);
  border-radius: 99px;
}

.term .e { color: #ff9aa7; }
.term .i { color: #7fd3ff; }
.term .g { color: #7ae2b0; }
.term .d { color: #6a80a8; }
.term .cur { background: rgba(207, 224, 245, 0.75); color: #04070e; }

.term-input {
  display: flex;
  align-items: center;
  gap: 8px;
  border-top: 1px solid var(--line);
  background: rgba(10, 17, 32, 0.8);
  padding: 7px 11px;
}

.term-input span { color: var(--acc); font-family: var(--mono); font-size: 12.5px; }

.term-input input {
  flex: 1;
  height: 30px;
  border: 0;
  background: transparent;
  color: var(--txt);
  font-family: var(--mono);
  font-size: 12.5px;
  outline: none;
  padding: 0;
}

/* -------------------------------------------------------------- results */
.result { display: grid; gap: 12px; }

.link-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 13px;
  border-radius: var(--r-m);
  border: 1px solid var(--line);
  background: rgba(255, 255, 255, 0.035);
}

.link-row .ico { font-size: 16px; }
.link-row .what { font-size: 11.5px; color: var(--dim-2); text-transform: uppercase; letter-spacing: 0.4px; }

.link-row a {
  color: var(--acc);
  text-decoration: none;
  font-family: var(--mono);
  font-size: 12.6px;
  word-break: break-all;
}

.link-row a:hover { text-decoration: underline; }
.link-row.hero-link { border-color: rgba(90, 166, 255, 0.4); background: var(--acc-soft); }

/* ------------------------------------------------------------- instances */
.inst {
  display: grid;
  grid-template-columns: 52px minmax(0, 1.4fr) minmax(0, 1fr) auto;
  gap: 14px;
  align-items: center;
  padding: 14px;
  border: 1px solid var(--line);
  border-radius: var(--r-l);
  background: var(--glass);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  margin-bottom: 12px;
}

@media (max-width: 920px) { .inst { grid-template-columns: 52px 1fr; } }

.inst .logo { width: 48px; height: 48px; border-radius: 14px; background: rgba(255, 255, 255, 0.05); border: 1px solid var(--line); display: grid; place-items: center; }
.inst .logo svg { width: 32px; height: 32px; }
.inst .nm { font-weight: 640; }
.inst .sub2 { font-size: 11.5px; color: var(--dim-2); font-family: var(--mono); }

.dot-state { display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px; }
.dot-state i { width: 8px; height: 8px; border-radius: 50%; }
.dot-state.up i { background: var(--ok); box-shadow: 0 0 8px var(--ok); }
.dot-state.down i { background: var(--dim-2); }
.dot-state.bad i { background: var(--bad); }

.gauges { display: grid; gap: 7px; min-width: 0; }
.gauge { display: grid; grid-template-columns: 34px 1fr 76px; gap: 8px; align-items: center; font-size: 11px; }
.gauge span { color: var(--dim-2); }
.gauge b { text-align: right; font-variant-numeric: tabular-nums; color: var(--dim); font-weight: 550; }

.spark { display: block; width: 100%; height: 26px; }
.spark path { fill: none; stroke: var(--acc); stroke-width: 1.6; vector-effect: non-scaling-stroke; }
.spark path.fill { fill: rgba(90, 166, 255, 0.14); stroke: none; }

.inst-actions { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }

/* ----------------------------------------------------------------- misc */
.empty { text-align: center; padding: 54px 20px; color: var(--dim-2); }
.empty .big { font-size: 34px; margin-bottom: 10px; opacity: 0.5; }

.toasts { position: fixed; right: 18px; bottom: 18px; z-index: 40; display: grid; gap: 8px; max-width: 380px; }

.toast {
  padding: 11px 14px;
  border-radius: var(--r-m);
  border: 1px solid var(--line-2);
  background: var(--glass-3);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  box-shadow: var(--sh);
  font-size: 13px;
  animation: toastin 0.22s var(--ease) both;
}

.toast.ok { border-color: rgba(61, 220, 151, 0.45); }
.toast.bad { border-color: rgba(255, 107, 126, 0.5); }
.toast b { display: block; margin-bottom: 2px; }
.toast small { color: var(--dim); }

@keyframes toastin { from { opacity: 0; transform: translateX(14px); } to { opacity: 1; transform: none; } }

.why { margin: 10px 0 0; padding-left: 18px; color: var(--dim); font-size: 12.6px; }
.why li { margin-bottom: 3px; }

.factors { display: grid; gap: 5px; margin-top: 10px; }
.factor { display: grid; grid-template-columns: 62px 1fr 34px; gap: 8px; align-items: center; font-size: 11px; color: var(--dim-2); }
.factor b { text-align: right; font-variant-numeric: tabular-nums; }

.pick {
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  padding: 13px;
  background: rgba(255, 255, 255, 0.03);
  display: grid;
  gap: 8px;
}

.pick.best { border-color: rgba(90, 166, 255, 0.45); background: var(--acc-soft); }
.pick .hd { display: flex; align-items: center; gap: 10px; }
.pick .score { margin-left: auto; font-weight: 700; font-size: 17px; font-variant-numeric: tabular-nums; }

pre.code {
  margin: 0;
  padding: 12px;
  border-radius: var(--r-m);
  background: #04070e;
  border: 1px solid var(--line);
  font-family: var(--mono);
  font-size: 11.6px;
  line-height: 1.5;
  color: #b8cce6;
  overflow: auto;
  max-height: 290px;
  white-space: pre;
}

.warnbox {
  border: 1px solid rgba(255, 194, 77, 0.35);
  background: rgba(255, 194, 77, 0.08);
  border-radius: var(--r-m);
  padding: 11px 13px;
  font-size: 12.6px;
  color: #ffe0ab;
  margin-bottom: 12px;
}

.warnbox.bad { border-color: rgba(255, 107, 126, 0.4); background: rgba(255, 107, 126, 0.08); color: #ffcdd4; }
.warnbox code { font-family: var(--mono); font-size: 11.6px; }

.skel { background: linear-gradient(90deg, rgba(255,255,255,.04), rgba(255,255,255,.1), rgba(255,255,255,.04)); background-size: 200% 100%; animation: sweep 1.3s linear infinite; border-radius: 8px; }
@keyframes sweep { to { background-position: -200% 0; } }

/* -------------------------------------------------- lite mode: no blur */
html.lite { --blur: 0px; --sh: none; }
html.lite .topbar, html.lite .rail, html.lite .panel, html.lite .card,
html.lite .inst, html.lite .toast {
  backdrop-filter: none;
  -webkit-backdrop-filter: none;
  background: #0b1220;
}
html.lite .bg { background: #070c16; }
html.lite .card:hover { transform: none; }
html.lite .view.on { animation: none; }
html.lite * { transition-duration: 0.08s !important; }
html.lite .step.on .dot { animation: none; }
html.lite .skel { animation: none; }

@media (prefers-reduced-motion: reduce) {
  * { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}

@media (max-width: 760px) {
  .app { grid-template-columns: 1fr; grid-template-rows: 56px auto 1fr; }
  .rail { flex-direction: row; overflow-x: auto; border-right: 0; border-bottom: 1px solid var(--line); padding: 8px; }
  .rail button { width: auto; white-space: nowrap; }
  .rail hr, .rail .note { display: none; }
  .meters { display: none; }
  .main { padding: 14px; }
  .brand small { display: none; }
}
__FORGE_FILE_APP_CSS__
  cat > "$FORGE_APP/app.js" <<'__FORGE_FILE_APP_JS__'
/* Selkies Forge - web UI. Vanilla, no build step, no CDN. */
(function () {
  "use strict";

  /* ------------------------------------------------------------- helpers */
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  function h(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function mb(v) {
    v = Number(v || 0);
    return v >= 1024 ? (v / 1024).toFixed(v >= 10240 ? 0 : 1) + " GB" : Math.round(v) + " MB";
  }

  function bytes(v) {
    v = Number(v || 0);
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
  }

  function ago(ts) {
    if (!ts) return "-";
    var s = Math.max(0, (Date.now() - new Date(ts).getTime()) / 1000);
    if (s < 60) return Math.round(s) + "s";
    if (s < 3600) return Math.round(s / 60) + "m";
    if (s < 86400) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  var TOKEN = (function () {
    var m = location.search.match(/[?&]k=([0-9a-f]+)/);
    if (m) { try { sessionStorage.setItem("forge_token", m[1]); } catch (e) {} return m[1]; }
    try { return sessionStorage.getItem("forge_token") || ""; } catch (e) { return ""; }
  })();

  function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", headers: { "Accept": "application/json" } };
    if (TOKEN) init.headers["X-Forge-Token"] = TOKEN;
    if (opts.body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
      init.method = opts.method || "POST";
    }
    return fetch(path, init).then(function (r) {
      return r.text().then(function (t) {
        var j = null;
        try { j = t ? JSON.parse(t) : {}; } catch (e) { j = { error: t.slice(0, 300) }; }
        if (!r.ok) throw new Error((j && j.error) || ("HTTP " + r.status));
        return j;
      });
    });
  }

  function sse(path, handlers) {
    var url = path + (path.indexOf("?") < 0 ? "?" : "&") + (TOKEN ? "k=" + TOKEN : "_=1");
    var es = new EventSource(url);
    Object.keys(handlers).forEach(function (k) {
      if (k === "error") return;
      es.addEventListener(k, function (ev) {
        var d = ev.data;
        try { d = JSON.parse(ev.data); } catch (e) {}
        handlers[k](d, ev);
      });
    });
    es.onerror = function () { if (handlers.error) handlers.error(); };
    return es;
  }

  function toast(title, detail, kind) {
    var box = $("#toasts");
    var el = document.createElement("div");
    el.className = "toast " + (kind || "");
    el.innerHTML = "<b>" + h(title) + "</b>" + (detail ? "<small>" + h(detail) + "</small>" : "");
    box.appendChild(el);
    setTimeout(function () {
      el.style.transition = "opacity .3s, transform .3s";
      el.style.opacity = "0";
      el.style.transform = "translateX(14px)";
      setTimeout(function () { el.remove(); }, 320);
    }, kind === "bad" ? 7000 : 4200);
  }

  function copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { toast("Copied", text, "ok"); },
        function () { toast("Could not copy", text); });
    } else {
      var ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); toast("Copied", text, "ok"); } catch (e) {}
      ta.remove();
    }
  }

  function sparkline(values, color) {
    var v = (values || []).slice(-60);
    if (v.length < 2) return '<svg class="spark" viewBox="0 0 100 26" preserveAspectRatio="none"></svg>';
    var max = Math.max.apply(null, v) || 1;
    var step = 100 / (v.length - 1);
    var pts = v.map(function (y, i) {
      return (i * step).toFixed(2) + "," + (24 - (y / max) * 22).toFixed(2);
    });
    var line = "M" + pts.join(" L");
    var fill = line + " L100,26 L0,26 Z";
    var c = color || "var(--acc)";
    return '<svg class="spark" viewBox="0 0 100 26" preserveAspectRatio="none">' +
      '<path class="fill" d="' + fill + '" style="fill:rgba(90,166,255,.14)"/>' +
      '<path d="' + line + '" style="stroke:' + c + '"/></svg>';
  }

  /* --------------------------------------------------------------- state */
  var S = {
    boot: null, host: null, catalog: [], instances: [], stats: {},
    view: "browse", sel: null, plan: null, job: null, jobES: null,
    term: null, termES: null, termId: null, termName: null,
    filters: { q: "", family: "", weight: "", kind: "", arch: true, sort: "beauty" },
    smart: { taste: "balanced", purpose: "general" },
    lite: false
  };

  /* ------------------------------------------------------------ lite mode */
  function decideLite() {
    var saved = null;
    try { saved = localStorage.getItem("forge_lite"); } catch (e) {}
    if (saved !== null) return saved === "1";
    var cores = navigator.hardwareConcurrency || 4;
    var memGb = navigator.deviceMemory || 4;
    var slow = cores <= 2 || memGb <= 2 ||
      (navigator.connection && navigator.connection.saveData) ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    return !!slow;
  }

  function applyLite(on) {
    S.lite = !!on;
    document.documentElement.classList.toggle("lite", S.lite);
    var b = $("#liteBtn");
    if (b) b.textContent = S.lite ? "Lite mode: on" : "Lite mode: off";
    try { localStorage.setItem("forge_lite", S.lite ? "1" : "0"); } catch (e) {}
  }

  /* ---------------------------------------------------------------- boot */
  function boot() {
    applyLite(decideLite());
    return api("/api/boot").then(function (b) {
      S.boot = b;
      S.host = b.host;
      S.catalog = b.catalog;
      S.instances = b.instances || [];
      renderMeters();
      renderFilters();
      renderGrid();
      renderRail();
      renderHost();
      renderSmartControls();
      pollStats();
      setInterval(refreshInstances, 6000);
      setInterval(refreshHost, 15000);
    }).catch(function (e) {
      document.body.insertAdjacentHTML("afterbegin",
        '<div class="warnbox bad" style="margin:14px">Could not reach the forge engine: ' +
        h(e.message) + "</div>");
    });
  }

  function refreshHost() {
    return api("/api/host").then(function (hh) { S.host = hh; renderMeters(); }).catch(function () {});
  }

  function refreshInstances() {
    return api("/api/instances").then(function (r) {
      S.instances = r.instances || [];
      renderRail();
      if (S.view === "manager") renderManager();
    }).catch(function () {});
  }

  function pollStats() {
    api("/api/stats").then(function (r) {
      S.stats = r.stats || {};
      if (S.view === "manager") renderManager();
    }).catch(function () {}).then(function () {
      setTimeout(pollStats, S.view === "manager" ? 3000 : 9000);
    });
  }

  /* ------------------------------------------------------------- top bar */
  function renderMeters() {
    var hst = S.host || {};
    var memUsed = (hst.mem_total_mb || 0) - (hst.mem_avail_mb || 0);
    var memPct = hst.mem_total_mb ? (memUsed / hst.mem_total_mb) * 100 : 0;
    var cpuPct = hst.cpus ? Math.min(100, ((hst.load1 || 0) / hst.cpus) * 100) : 0;
    var diskPct = hst.disk_total_mb ? (1 - hst.disk_free_mb / hst.disk_total_mb) * 100 : 0;
    function m(label, value, pct) {
      var cls = pct > 90 ? "bad" : pct > 72 ? "warn" : "";
      return '<div class="meter"><b>' + h(label) + '</b><div class="v">' + h(value) +
        '</div><div class="bar ' + cls + '"><i style="width:' + pct.toFixed(1) + '%"></i></div></div>';
    }
    $("#meters").innerHTML =
      m("RAM FREE", mb(hst.mem_avail_mb) + " of " + mb(hst.mem_total_mb), memPct) +
      m("CPU LOAD", (hst.load1 || 0).toFixed(2) + " of " + (hst.cpus || "?") + " cores", cpuPct) +
      m("DISK FREE", mb(hst.disk_free_mb), diskPct);
  }

  function renderRail() {
    var running = S.instances.filter(function (i) { return i.running; }).length;
    $("#tagInst").textContent = S.instances.length ? (running + "/" + S.instances.length) : "0";
    $("#tagCat").textContent = String(S.boot ? S.boot.counts.runnable : S.catalog.length);
  }

  /* ------------------------------------------------------------- filters */
  function familyCounts() {
    var c = {};
    S.catalog.forEach(function (e) {
      if (S.filters.arch && S.host && S.host.arch && e.arches.indexOf(S.host.arch) < 0) return;
      c[e.family] = (c[e.family] || 0) + 1;
    });
    return c;
  }

  function renderFilters() {
    var labels = (S.boot && S.boot.family_labels) || {};
    var counts = familyCounts();
    var fams = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; });
    var html = '<div class="chip' + (S.filters.family ? "" : " on") + '" data-fam="">All families <span class="n">' +
      Object.keys(counts).reduce(function (s, k) { return s + counts[k]; }, 0) + "</span></div>";
    html += fams.map(function (f) {
      return '<div class="chip' + (S.filters.family === f ? " on" : "") + '" data-fam="' + h(f) +
        '">' + h(labels[f] || f) + ' <span class="n">' + counts[f] + "</span></div>";
    }).join("");
    $("#famChips").innerHTML = html;

    var weights = [["", "Any weight"], ["feather", "Featherweight"], ["light", "Light"],
      ["balanced", "Balanced"], ["full", "Full"], ["heavy", "Heavy and pretty"]];
    $("#wChips").innerHTML = weights.map(function (w) {
      return '<div class="chip' + (S.filters.weight === w[0] ? " on" : "") + '" data-w="' + w[0] +
        '">' + h(w[1]) + "</div>";
    }).join("") +
      '<div class="chip' + (S.filters.kind === "pull" ? " on" : "") + '" data-kind="pull">Ready to pull</div>' +
      '<div class="chip' + (S.filters.kind === "build" ? " on" : "") + '" data-kind="build">Built locally</div>' +
      '<div class="chip' + (S.filters.arch ? " on" : "") + '" data-arch="1">Runs on ' +
      h((S.host && S.host.arch) || "this box") + "</div>";
  }

  function filtered() {
    var f = S.filters;
    var q = f.q.trim().toLowerCase();
    var out = S.catalog.filter(function (e) {
      if (f.arch && S.host && e.arches.indexOf(S.host.arch) < 0) return false;
      if (f.family && e.family !== f.family) return false;
      if (f.weight && e.weight !== f.weight) return false;
      if (f.kind && e.kind !== f.kind) return false;
      if (q) {
        var hay = (e.name + " " + e.subtitle + " " + e.desc + " " + e.de_label + " " +
          e.family_label + " " + (e.tags || []).join(" ")).toLowerCase();
        if (hay.indexOf(q) < 0) return false;
      }
      return true;
    });
    var sorters = {
      beauty: function (a, b) { return b.beauty - a.beauty || a.heavy - b.heavy; },
      light: function (a, b) { return a.heavy - b.heavy || b.beauty - a.beauty; },
      fast: function (a, b) { return b.speed - a.speed || a.heavy - b.heavy; },
      small: function (a, b) { return a.dl_mb - b.dl_mb; },
      name: function (a, b) { return a.name.localeCompare(b.name); }
    };
    out.sort(sorters[f.sort] || sorters.beauty);
    return out;
  }

  function cardHtml(e) {
    var glyph = window.forgeGlyph(e.glyph);
    var ready = e.kind === "pull";
    return '<article class="card" tabindex="0" data-id="' + h(e.id) + '">' +
      '<div class="top"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      '<div style="min-width:0"><div class="name">' + h(e.name) + "</div>" +
      '<div class="meta">' + h(e.subtitle) + "</div></div></div>" +
      '<div class="badges">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + glyph + h(e.de_label) + "</span>" +
      (ready ? '<span class="badge ready">ready</span>' : '<span class="badge">builds here</span>') +
      (e.profile === "kasm" ? '<span class="badge">kasm</span>' : "") +
      "</div>" +
      '<div class="desc">' + h(e.desc) + "</div>" +
      '<div class="beauty"><span>look</span><div class="bar"><i style="width:' + e.beauty +
      '%"></i></div><b>' + e.beauty + "</b></div>" +
      '<div class="specs">' +
      "<div><b>" + mb(e.dl_mb) + "</b><span>download</span></div>" +
      "<div><b>" + mb(e.disk_mb) + "</b><span>on disk</span></div>" +
      "<div><b>" + mb(e.ram_rec) + "</b><span>ram</span></div>" +
      "<div><b>" + e.cpu_rec + "</b><span>cores</span></div>" +
      "</div></article>";
  }

  function renderGrid() {
    var list = filtered();
    $("#count").textContent = list.length + " of " + S.catalog.length + " desktops";
    var grid = $("#grid");
    if (!list.length) {
      grid.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="big">¯\\_(ツ)_/¯</div>' +
        "Nothing matches that. Try clearing a filter.</div>";
      return;
    }
    grid.innerHTML = list.map(cardHtml).join("");
  }

  /* --------------------------------------------------------------- smart */
  function renderSmartControls() {
    var tastes = (S.boot && S.boot.tastes) || {};
    $("#tasteChips").innerHTML = Object.keys(tastes).map(function (t) {
      return '<div class="chip' + (S.smart.taste === t ? " on" : "") + '" data-taste="' + h(t) +
        '" title="' + h(tastes[t]) + '">' + h(t) + "</div>";
    }).join("");
    var purposes = [["general", "anything"], ["dev", "writing code"],
      ["security", "security work"], ["retro", "retro and tiny"], ["media", "media"]];
    $("#purposeChips").innerHTML = purposes.map(function (p) {
      return '<div class="chip' + (S.smart.purpose === p[0] ? " on" : "") + '" data-purpose="' +
        p[0] + '">' + h(p[1]) + "</div>";
    }).join("");
  }

  function runSmart() {
    var box = $("#smartOut");
    box.innerHTML = '<div class="skel" style="height:96px"></div>';
    api("/api/smart", { body: { taste: S.smart.taste, purpose: S.smart.purpose, limit: 3 } })
      .then(function (r) {
        if (!r.picks.length) {
          box.innerHTML = '<div class="warnbox">Nothing in the catalog fits this machine right now. ' +
            "Free some memory or disk and try again.</div>";
          return;
        }
        var fl = ["ram", "cpu", "disk", "beauty", "speed", "ready", "small"];
        box.innerHTML = '<p class="sub" style="margin:0 0 10px">Weighed <b>' + r.considered +
          "</b> candidates against this machine, aiming for <b>" + h(r.taste) + "</b>.</p>" +
          '<div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(270px,1fr))">' +
          r.picks.map(function (p, i) {
            var e = p.entry;
            return '<div class="pick' + (i === 0 ? " best" : "") + '">' +
              '<div class="hd"><div class="logo" style="width:34px;height:34px;border-radius:10px;' +
              'display:grid;place-items:center;border:1px solid var(--line)">' +
              window.forgeLogo(e.family) + "</div><div><b>" + h(e.name) + "</b><div class=\"meta\" " +
              'style="font-size:11px;color:var(--dim-2)">' + h(e.subtitle) + "</div></div>" +
              '<span class="score">' + p.score.toFixed(0) + "</span></div>" +
              '<ul class="why">' + p.why.map(function (w) { return "<li>" + h(w) + "</li>"; }).join("") + "</ul>" +
              '<div class="factors">' + fl.map(function (k) {
                var v = (p.factors[k] || 0) * 100;
                return '<div class="factor"><span>' + k + '</span><div class="bar"><i style="width:' +
                  v.toFixed(0) + '%"></i></div><b>' + v.toFixed(0) + "</b></div>";
              }).join("") + "</div>" +
              '<div class="row"><button class="btn primary sm" data-use="' + h(e.id) +
              '">Configure this</button><button class="btn sm" data-go="' + h(e.id) +
              '">Just forge it</button></div></div>';
          }).join("") + "</div>";
      }).catch(function (e) {
        box.innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
      });
  }

  /* ----------------------------------------------------------- configure */
  function openConfigure(id, autostart) {
    api("/api/entry/" + encodeURIComponent(id)).then(function (e) {
      S.sel = e;
      S.plan = Object.assign({}, e.plan);
      renderConfigure();
      show("configure");
      if (autostart) startLaunch();
    }).catch(function (err) { toast("Could not open that entry", err.message, "bad"); });
  }

  function renderConfigure() {
    var e = S.sel, hst = S.host;
    var maxMem = Math.max(512, Math.min(hst.mem_total_mb - 256, hst.mem_avail_mb));
    var tight = e.ram_rec > hst.mem_avail_mb * 0.6;
    var noArch = e.arches.indexOf(hst.arch) < 0;

    $("#cfgHero").innerHTML =
      '<div class="hero"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      "<div><h2>" + h(e.name) + "</h2><p>" + h(e.desc) + "</p>" +
      '<div class="badges" style="margin-top:9px">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + window.forgeGlyph(e.glyph) + h(e.de_label) + "</span>" +
      '<span class="badge">' + h(e.family_label) + "</span>" +
      '<span class="badge' + (noArch ? " off" : "") + '">' + h(e.arches.join(" / ")) + "</span>" +
      (e.kind === "pull" ? '<span class="badge ready">no build needed</span>'
        : '<span class="badge">built on this machine</span>') +
      "</div></div></div>" +
      (noArch ? '<div class="warnbox bad" style="margin-top:12px">This image has no ' + h(hst.arch) +
        " build, so it cannot run here.</div>" : "") +
      (tight ? '<div class="warnbox" style="margin-top:12px">This one likes ' + mb(e.ram_rec) +
        " of RAM and you have " + mb(hst.mem_avail_mb) +
        " free. It will run, but keep an eye on it.</div>" : "");

    $("#cfgSpecs").innerHTML =
      "<h3>What it costs</h3><dl class=\"kv\">" +
      "<dt>Download</dt><dd>" + mb(e.dl_mb) + "</dd>" +
      "<dt>On disk</dt><dd>about " + mb(e.disk_mb) + "</dd>" +
      "<dt>Idle memory</dt><dd>around " + mb(e.idle_mb) + "</dd>" +
      "<dt>Floor / sweet spot</dt><dd>" + mb(e.ram_min) + " / " + mb(e.ram_rec) + "</dd>" +
      "<dt>Cores wanted</dt><dd>" + e.cpu_rec + "</dd>" +
      "<dt>Base image</dt><dd style=\"font-family:var(--mono);font-size:11.5px;word-break:break-all\">" +
      h(e.image || (e.recipe && e.recipe.image) || "-") + "</dd>" +
      (e.recipe && e.recipe.pkgs ? "<dt>Installs</dt><dd style=\"font-size:12px;color:var(--dim)\">" +
        h(e.recipe.pkgs) + "</dd>" : "") +
      "</dl>";

    function slider(id, label, min, max, step, val, fmt, advice) {
      return '<div class="slider"><div class="lbl"><span>' + h(label) + ' <span class="adv">' +
        h(advice || "") + '</span></span><b id="' + id + 'V">' + fmt(val) + "</b></div>" +
        '<input type="range" id="' + id + '" min="' + min + '" max="' + max + '" step="' + step +
        '" value="' + val + '"></div>';
    }

    $("#cfgTune").innerHTML = "<h3>Resources <span class=\"hint\">this machine: " +
      mb(hst.mem_avail_mb) + " RAM free, " + hst.cpus + " cores, " + mb(hst.disk_free_mb) +
      " disk free</span></h3>" +
      slider("sMem", "Memory", 256, maxMem, 128, S.plan.memory_mb, mb,
        "floor " + mb(e.ram_min)) +
      slider("sCpu", "CPU cores", 0.5, hst.cpus, 0.5, S.plan.cpus,
        function (v) { return Number(v).toFixed(1) + " cores"; }, "wants " + e.cpu_rec) +
      slider("sShm", "Shared memory (/dev/shm)", 128, 2048, 64, S.plan.shm_mb, mb,
        "browsers need this") +
      slider("sDisk", "Storage budget", 2048,
        Math.max(8192, Math.min(hst.disk_free_mb, 200000)), 512, S.plan.disk_mb, mb,
        hst.quota_support ? "enforced" : "tracked, not enforced") +
      (hst.quota_support ? "" : '<div class="warnbox" style="margin-top:4px">' +
        h(hst.storage_driver + " on " + hst.backing_fs) + " cannot enforce a hard per-container " +
        "disk cap, so this figure is recorded and watched rather than enforced.</div>");

    $("#cfgOpts").innerHTML = "<h3>Options</h3>" +
      '<label class="field"><span>Name (optional)</span><input type="text" id="oName" placeholder="' +
      h(e.id) + '"></label>' +
      '<label class="toggle"><input type="checkbox" id="oTunnel" checked><i></i>' +
      "<span>Open a serveo tunnel<small>" +
      (e.profile === "kasm" ? "https image, so a limited TCP tunnel" : "public https link") +
      "</small></span></label>" +
      '<label class="toggle"><input type="checkbox" id="oAuth"><i></i><span>Password protect it' +
      "<small>basic auth on the desktop</small></span></label>" +
      '<div id="authFields" style="display:none;margin:8px 0 4px">' +
      '<label class="field"><span>User</span><input type="text" id="oUser" value="forge"></label>' +
      '<label class="field"><span>Password</span><input type="password" id="oPass"></label></div>' +
      '<label class="toggle"><input type="checkbox" id="oGpu"><i></i><span>Pass through /dev/dri' +
      "<small>" + ((S.host.has_dri === false) ? "no GPU node found" : "use the GPU if there is one") +
      "</small></span></label>" +
      '<label class="toggle"><input type="checkbox" id="oSeccomp"><i></i><span>seccomp=unconfined' +
      "<small>only if the desktop refuses to start</small></span></label>" +
      (e.dockerfile ? '<div style="margin-top:12px"><button class="btn sm ghost" id="dfBtn">' +
        "Show the Dockerfile it will build</button><pre class=\"code\" id=\"dfOut\" " +
        'style="display:none;margin-top:9px">' + h(e.dockerfile) + "</pre></div>" : "");

    $("#cfgGo").innerHTML =
      '<button class="btn primary wide" id="goBtn"' + (noArch ? " disabled" : "") + ">Forge " +
      h(e.name) + "</button>" +
      '<p class="sub" style="margin:10px 0 0;text-align:center">A free host port is picked for you, ' +
      "and the desktop is checked before you get the link.</p>";

    $$("#cfgTune input[type=range]").forEach(syncRange);
  }

  function syncRange(r) {
    var pct = ((r.value - r.min) / (r.max - r.min)) * 100;
    r.style.setProperty("--pct", pct.toFixed(1) + "%");
  }

  /* -------------------------------------------------------------- launch */
  function startLaunch() {
    var e = S.sel;
    var opts = {
      tunnel: $("#oTunnel") ? $("#oTunnel").checked : true,
      gpu: $("#oGpu") ? $("#oGpu").checked : false,
      seccomp_unconfined: $("#oSeccomp") ? $("#oSeccomp").checked : false
    };
    var nm = $("#oName") && $("#oName").value.trim();
    if (nm) opts.name = nm;
    if ($("#oAuth") && $("#oAuth").checked) {
      opts.username = ($("#oUser").value || "forge").trim();
      opts.password = $("#oPass").value || Math.random().toString(36).slice(2, 10);
    }
    if (e.profile === "kasm") opts.password = opts.password || "forge";

    show("launch");
    $("#lTitle").innerHTML = '<div class="hero"><div class="logo">' + window.forgeLogo(e.family) +
      "</div><div><h2>Forging " + h(e.name) + "</h2><p>" + h(e.subtitle) +
      " &middot; " + mb(S.plan.memory_mb) + " RAM &middot; " + S.plan.cpus + " cores</p></div></div>";
    $("#lResult").innerHTML = "";
    $("#lSteps").innerHTML = "";
    setProgress(0, "starting", "Preparing");

    var termEl = $("#lTerm");
    termEl.innerHTML = "";
    S.job = null;
    var term = new window.ForgeTerm(termEl, { cols: 200, rows: 1, maxScroll: 4000 });
    term.showCursor = false;
    term.grid = [];
    term.line("selkies forge :: " + e.name, "i");
    term.line("");

    api("/api/launch", { body: { id: e.id, plan: S.plan, opts: opts } }).then(function (r) {
      S.plan = r.plan;
      S.job = r.job;
      if (S.jobES) S.jobES.close();
      S.jobES = sse("/api/job/" + r.job.id + "/events", {
        snapshot: function () {},
        log: function (d) {
          var line = d.data ? d.data.line : d.line;
          var stream = (d.data ? d.data.stream : d.stream) || "out";
          var cls = stream === "err" ? "e" : /^(>>|forge |host |plan |image |ports |container|desktop|tunnel|note |download|build )/.test(line) ? "i" : null;
          term.line(line, cls);
        },
        phase: function (d) {
          var p = d.data || d;
          setProgress(p.progress * 100, p.phase, p.label);
          renderSteps(p.phase);
        },
        progress: function (d) {
          var p = d.data || d;
          var extra = p.extra || {};
          var note = "";
          if (extra.bytes_total) {
            note = bytes(extra.bytes) + " of " + bytes(extra.bytes_total) +
              " (" + (extra.layers_done || 0) + "/" + (extra.layers || 0) + " layers)";
          } else if (extra.packages_total) {
            note = extra.packages + " of ~" + extra.packages_total + " packages";
          } else if (extra.waiting) {
            note = "waiting for the desktop (" + extra.waiting + ")";
          }
          setProgress(p.progress * 100, p.phase, note || p.phase);
        },
        done: function (d) {
          var res = d.data || d;
          renderSteps("ready");
          setProgress(100, "ready", "Ready");
          term.line("");
          term.line(">> ready: " + (res.local_url || ""), "g");
          renderResult(res);
          refreshInstances();
          toast("Desktop is up", res.name, "ok");
        },
        error: function (d) {
          var err = d.data || d;
          renderSteps("error");
          term.line("");
          term.line("!! " + (err.message || "launch failed"), "e");
          (err.hints || []).forEach(function (x) { term.line("   hint: " + x, "e"); });
          $("#lResult").innerHTML = '<div class="warnbox bad"><b>That did not work.</b><br>' +
            h(err.message) + (err.hints && err.hints.length ?
              "<ul class=\"why\">" + err.hints.map(function (x) { return "<li>" + h(x) + "</li>"; }).join("") + "</ul>" : "") +
            '</div><div class="row"><button class="btn" data-back="browse">Pick something else</button>' +
            '<button class="btn primary" id="retryBtn">Try again</button></div>';
          toast("Launch failed", err.message, "bad");
        },
        final: function () { if (S.jobES) S.jobES.close(); }
      });
    }).catch(function (err) {
      $("#lResult").innerHTML = '<div class="warnbox bad">' + h(err.message) + "</div>";
    });
  }

  var PHASES = [["resolve", "check"], ["fetch", "fetch image"], ["build", "build"],
    ["create", "start"], ["health", "handshake"], ["tunnel", "tunnel"], ["ready", "ready"]];

  function renderSteps(active) {
    var idx = PHASES.findIndex(function (p) { return p[0] === active; });
    $("#lSteps").innerHTML = PHASES.map(function (p, i) {
      var cls = active === "error" ? (i <= Math.max(0, idx) ? "bad" : "")
        : i < idx ? "done" : i === idx ? "on" : "";
      return '<div class="step ' + cls + '"><i class="dot"></i>' + h(p[1]) + "</div>";
    }).join("");
  }

  function setProgress(pct, phase, what) {
    pct = Math.max(0, Math.min(100, pct || 0));
    $("#lBar").style.width = pct.toFixed(1) + "%";
    $("#lPct").textContent = pct.toFixed(0) + "%";
    $("#lWhat").textContent = what || phase || "";
  }

  function renderResult(res) {
    var e = res.entry || S.sel;
    var rows = [];
    if (res.tunnel && res.tunnel.url) {
      rows.push(linkRow("Public link", res.tunnel.url, "hero-link",
        res.tunnel.mode === "tcp" ? "serveo TCP tunnel, anonymous tunnels expire" : "serveo https tunnel"));
    }
    rows.push(linkRow("On this machine", res.local_url, "", "no tunnel needed"));
    if (res.https_url) rows.push(linkRow("Local https", res.https_url, "", "for LAN devices"));

    var cred = res.credentials ? '<div class="warnbox"><b>Sign in with</b> ' +
      h(res.credentials.user) + " / " + h(res.credentials.password) + "</div>" : "";

    $("#lResult").innerHTML = '<div class="panel"><h3>' + h(e ? e.name : res.name) +
      " is running</h3>" + cred + '<div class="result">' + rows.join("") + "</div>" +
      '<dl class="kv" style="margin-top:14px">' +
      "<dt>Container</dt><dd style=\"font-family:var(--mono);font-size:12px\">" + h(res.name) + "</dd>" +
      "<dt>Host ports</dt><dd>" + h((res.ports || []).join(", ")) + "</dd>" +
      "<dt>Memory cap</dt><dd>" + mb(res.plan.memory_mb) + "</dd>" +
      "<dt>CPU cap</dt><dd>" + res.plan.cpus + " cores</dd>" +
      "<dt>Shared memory</dt><dd>" + mb(res.plan.shm_mb) + "</dd>" +
      "<dt>Storage budget</dt><dd>" + mb(res.plan.disk_mb) +
      (res.quota_enforced ? " (enforced)" : " (tracked)") + "</dd>" +
      "<dt>Image</dt><dd style=\"font-family:var(--mono);font-size:11.5px;word-break:break-all\">" +
      h(res.image) + "</dd></dl>" +
      '<div class="row" style="margin-top:14px">' +
      '<a class="btn primary" href="' + h(res.local_url) + '" target="_blank" rel="noopener">Open the desktop</a>' +
      '<button class="btn" data-term="' + h(res.name) + '">Open a shell</button>' +
      '<button class="btn" data-back="manager">Go to the manager</button>' +
      '<button class="btn ghost" data-back="browse">Forge another</button></div></div>';
  }

  function linkRow(what, url, cls, note) {
    if (!url) return "";
    return '<div class="link-row ' + (cls || "") + '"><span class="ico">' +
      (cls ? "🌍" : "🏠") + '</span><div style="min-width:0;flex:1">' +
      '<div class="what">' + h(what) + (note ? " &middot; " + h(note) : "") + "</div>" +
      '<a href="' + h(url) + '" target="_blank" rel="noopener">' + h(url) + "</a></div>" +
      '<button class="btn sm" data-copy="' + h(url) + '">Copy</button></div>';
  }

  /* ------------------------------------------------------------- manager */
  function renderManager() {
    var box = $("#instList");
    if (!S.instances.length) {
      box.innerHTML = '<div class="empty"><div class="big">🗂</div>Nothing forged yet. ' +
        'Head to <b>Browse</b> and pick a desktop.</div>';
      return;
    }
    var totalRx = 0, totalTx = 0;
    box.innerHTML = S.instances.map(function (i) {
      var st = S.stats[i.name] || {};
      totalRx += st.rx_total || 0;
      totalTx += st.tx_total || 0;
      var state = i.running ? "up" : (i.exit_code ? "bad" : "down");
      var ports = Object.keys(i.ports || {}).map(function (k) {
        return i.ports[k] + "&rarr;" + k;
      }).join("  ");
      var tun = i.tunnel && i.tunnel.url;
      var memPct = st.mem_pct || 0;
      var cpuPct = Math.min(100, (st.cpu || 0));
      return '<div class="inst" data-name="' + h(i.name) + '">' +
        '<div class="logo">' + window.forgeLogo(i.family) + "</div>" +
        '<div style="min-width:0">' +
        '<div class="nm">' + h(i.title) + "</div>" +
        '<div class="sub2">' + h(i.name) + "</div>" +
        '<div class="row" style="gap:7px;margin-top:6px">' +
        '<span class="dot-state ' + state + '"><i></i>' +
        h(i.running ? "running " + ago(i.started_at) : (i.status || "stopped")) + "</span>" +
        '<span class="badge">' + h(i.de_label || "") + "</span>" +
        (i.profile === "kasm" ? '<span class="badge">kasm</span>' : "") +
        (i.restarts ? '<span class="badge">' + i.restarts + " restarts</span>" : "") +
        "</div>" +
        '<div class="sub2" style="margin-top:6px">' + ports + "</div>" +
        (i.local_url ? '<div style="margin-top:6px"><a href="' + h(i.local_url) +
          '" target="_blank" rel="noopener" style="color:var(--acc);font-size:12px">' +
          h(i.local_url) + "</a></div>" : "") +
        (tun ? '<div style="margin-top:3px"><a href="' + h(tun) +
          '" target="_blank" rel="noopener" style="color:var(--acc);font-size:12px;word-break:break-all">' +
          h(tun) + '</a> <button class="btn sm ghost" data-copy="' + h(tun) + '">copy</button>' +
          (i.tunnel.alive ? "" : ' <span class="badge off">tunnel down</span>') + "</div>" : "") +
        "</div>" +
        '<div class="gauges">' +
        '<div class="gauge"><span>cpu</span><div class="bar' + (cpuPct > 85 ? " bad" : "") +
        '"><i style="width:' + cpuPct.toFixed(0) + '%"></i></div><b>' +
        (st.cpu != null ? st.cpu.toFixed(1) + "%" : "-") + "</b></div>" +
        '<div class="gauge"><span>ram</span><div class="bar' + (memPct > 88 ? " bad" : memPct > 70 ? " warn" : "") +
        '"><i style="width:' + memPct.toFixed(0) + '%"></i></div><b>' +
        (st.mem_mb != null ? mb(st.mem_mb) : "-") + "</b></div>" +
        '<div class="gauge"><span>net</span>' + sparkline(st.spark_net) + "<b>" +
        bytes((st.rx_total || 0) + (st.tx_total || 0)) + "</b></div>" +
        '<div class="gauge" style="grid-template-columns:34px 1fr"><span>in/out</span>' +
        '<b style="text-align:left">' + bytes(st.rx_total) + " in &middot; " +
        bytes(st.tx_total) + " out &middot; " + bytes(st.rx_rate) + "/s now</b></div>" +
        "</div>" +
        '<div class="inst-actions">' +
        (i.running
          ? '<button class="btn sm" data-act="stop">Stop</button>' +
            '<button class="btn sm" data-act="restart">Restart</button>' +
            '<button class="btn sm" data-term="' + h(i.name) + '">Shell</button>' +
            (tun ? '<button class="btn sm" data-act="untunnel">Drop tunnel</button>'
                 : '<button class="btn sm" data-act="tunnel">Tunnel</button>')
          : '<button class="btn sm primary" data-act="start">Start</button>') +
        '<button class="btn sm ghost" data-logs="' + h(i.name) + '">Logs</button>' +
        '<button class="btn sm ghost" data-tune="' + h(i.name) + '">Tune</button>' +
        '<button class="btn sm danger" data-act="remove">Remove</button>' +
        "</div></div>";
    }).join("");
    $("#instTotals").innerHTML = "<span class=\"chip static\">" + S.instances.length +
      " instances</span><span class=\"chip static\">" +
      S.instances.filter(function (i) { return i.running; }).length + " running</span>" +
      "<span class=\"chip static\">" + bytes(totalRx) + " in</span>" +
      "<span class=\"chip static\">" + bytes(totalTx) + " out</span>";
  }

  function instAction(name, act) {
    if (act === "remove" && !confirm("Remove " + name + "? Its /config volume is kept unless you say otherwise.")) return;
    var body = {};
    if (act === "remove") body.purge = confirm("Also delete its saved /config volume? OK = delete, Cancel = keep.");
    toast(act + "...", name);
    api("/api/instance/" + encodeURIComponent(name) + "/" + act, { body: body })
      .then(function (r) {
        toast(act + " done", (r.tunnel && r.tunnel.url) || name, "ok");
        refreshInstances();
      })
      .catch(function (e) { toast(act + " failed", e.message, "bad"); });
  }

  function showLogs(name) {
    api("/api/logs/" + encodeURIComponent(name) + "?tail=400").then(function (r) {
      $("#modalTitle").textContent = "docker logs " + name;
      $("#modalBody").innerHTML = '<pre class="code" style="max-height:60vh">' + h(r.logs || "(empty)") + "</pre>";
      $("#modal").style.display = "grid";
    }).catch(function (e) { toast("No logs", e.message, "bad"); });
  }

  function showTune(name) {
    var i = S.instances.filter(function (x) { return x.name === name; })[0];
    if (!i) return;
    var mem = (i.limits && i.limits.memory_mb) || 1024;
    var cpus = (i.limits && i.limits.cpus) || 1;
    var maxMem = Math.max(512, S.host.mem_total_mb - 256);
    $("#modalTitle").textContent = "Tune " + name;
    $("#modalBody").innerHTML =
      '<p class="sub">Applied live, no restart.</p>' +
      '<div class="slider"><div class="lbl"><span>Memory</span><b id="tMemV">' + mb(mem) +
      '</b></div><input type="range" id="tMem" min="256" max="' + maxMem + '" step="128" value="' + mem + '"></div>' +
      '<div class="slider"><div class="lbl"><span>CPU cores</span><b id="tCpuV">' + cpus.toFixed(1) +
      '</b></div><input type="range" id="tCpu" min="0.5" max="' + S.host.cpus + '" step="0.5" value="' + cpus + '"></div>' +
      '<div class="row end"><button class="btn primary" id="tApply">Apply</button></div>';
    $("#modal").style.display = "grid";
    $$("#modalBody input[type=range]").forEach(syncRange);
    $("#tMem").oninput = function () { $("#tMemV").textContent = mb(this.value); syncRange(this); };
    $("#tCpu").oninput = function () { $("#tCpuV").textContent = Number(this.value).toFixed(1); syncRange(this); };
    $("#tApply").onclick = function () {
      api("/api/instance/" + encodeURIComponent(name) + "/retune",
        { body: { memory_mb: Number($("#tMem").value), cpus: Number($("#tCpu").value) } })
        .then(function () { toast("Retuned", name, "ok"); $("#modal").style.display = "none"; refreshInstances(); })
        .catch(function (e) { toast("Could not retune", e.message, "bad"); });
    };
  }

  /* ------------------------------------------------------------ terminal */
  function openTerm(name) {
    show("shell");
    $("#shTitle").textContent = name;
    var el = $("#shTerm");
    el.innerHTML = "";
    if (S.termES) { S.termES.close(); S.termES = null; }
    if (S.termId) api("/api/term/" + S.termId + "/close", { body: {} }).catch(function () {});
    S.termName = name;
    var term = new window.ForgeTerm(el, { cols: 100, rows: 28 });
    S.term = term;

    /* Attaching takes a second or two (docker exec, then the pty), so say so
       rather than showing an empty black box. */
    var head = $("#shHead");
    var t0 = Date.now();
    var frames = "\u280b\u2819\u2839\u2838\u283c\u2834\u2826\u2827\u2807\u280f";
    var fi = 0;
    var live = false;
    var spin = setInterval(function () {
      var secs = ((Date.now() - t0) / 1000).toFixed(1);
      head.textContent = frames.charAt(fi++ % 10) + "  attaching to " + name + "  " + secs + "s";
      if (fi === 90) {
        term.line("still waiting on docker exec, the container may be busy", "d");
      }
    }, 90);
    function settled(text) {
      if (spin) { clearInterval(spin); spin = null; }
      head.textContent = text;
    }
    term.line("connecting to " + name + " ...", "d");
    term.line("");

    var fit = term.fit();
    api("/api/term", { body: { container: name, cols: fit.cols, rows: fit.rows } })
      .then(function (r) {
        S.termId = r.id;
        head.textContent = "handshaking with the shell...";
        S.termES = sse("/api/term/" + r.id + "/stream", {
          data: function (d) {
            if (!live) {
              live = true;
              settled("docker exec \u00b7 " + name + "  \u00b7  " +
                      ((Date.now() - t0) / 1000).toFixed(1) + "s to attach");
            }
            var raw = atob(typeof d === "string" ? d.replace(/^"|"$/g, "") : d);
            var out;
            try {
              /* the pty gives us utf-8 bytes; turn them into real characters */
              out = decodeURIComponent(escape(raw));
            } catch (e) {
              out = raw;
            }
            term.write(out);
          },
          closed: function () {
            settled("session closed \u00b7 " + name);
            term.line("");
            term.line("[session closed]", "d");
          },
          error: function () {}
        });
        el.focus();
      })
      .catch(function (e) {
        settled("could not attach");
        term.line("could not open a shell: " + e.message, "e");
      });
  }

  function sendKeys(data) {
    if (!S.termId) return;
    api("/api/term/" + S.termId + "/input", { body: { data: data } }).catch(function () {});
  }

  function keyToSeq(ev) {
    var k = ev.key;
    if (ev.ctrlKey && k.length === 1) {
      var c = k.toUpperCase().charCodeAt(0);
      if (c >= 64 && c <= 95) return String.fromCharCode(c - 64);
      if (k === " ") return "\x00";
    }
    switch (k) {
      case "Enter": return "\r";
      case "Backspace": return "\x7f";
      case "Tab": return "\t";
      case "Escape": return "\x1b";
      case "ArrowUp": return "\x1b[A";
      case "ArrowDown": return "\x1b[B";
      case "ArrowRight": return "\x1b[C";
      case "ArrowLeft": return "\x1b[D";
      case "Home": return "\x1b[H";
      case "End": return "\x1b[F";
      case "PageUp": return "\x1b[5~";
      case "PageDown": return "\x1b[6~";
      case "Delete": return "\x1b[3~";
      case "Insert": return "\x1b[2~";
      default:
        if (k && k.length === 1) return k;
        return null;
    }
  }

  /* ---------------------------------------------------------------- host */
  function renderHost() {
    api("/api/doctor").then(function (d) {
      var hst = d.host;
      $("#hostChecks").innerHTML = d.checks.map(function (c) {
        var bad = !c.ok && c.severity !== "info";
        return '<div class="link-row' + (bad ? "" : "") + '" style="' +
          (bad ? "border-color:rgba(255,107,126,.4)" : "") + '">' +
          '<span class="ico">' + (c.ok ? "✅" : (c.severity === "info" ? "ℹ️" : "⚠️")) + "</span>" +
          '<div style="flex:1;min-width:0"><div class="what">' + h(c.name) + "</div>" +
          '<div style="font-size:13px">' + h(c.detail) + "</div>" +
          (!c.ok && c.fix ? '<div style="font-size:12px;color:var(--dim-2)">fix: ' + h(c.fix) + "</div>" : "") +
          "</div></div>";
      }).join("");
      $("#hostFacts").innerHTML = "<dl class=\"kv\">" +
        ["hostname", "os_pretty", "kernel", "arch", "cpus", "docker_version", "storage_driver",
         "backing_fs", "cgroup", "python"].map(function (k) {
          return "<dt>" + h(k.replace(/_/g, " ")) + "</dt><dd>" + h(hst[k]) + "</dd>";
        }).join("") +
        "<dt>memory</dt><dd>" + mb(hst.mem_avail_mb) + " free of " + mb(hst.mem_total_mb) + "</dd>" +
        "<dt>disk</dt><dd>" + mb(hst.disk_free_mb) + " free of " + mb(hst.disk_total_mb) + "</dd>" +
        "<dt>docker root</dt><dd>" + h(hst.docker_root) + "</dd></dl>";
    }).catch(function (e) {
      $("#hostChecks").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
    });
  }

  /* ------------------------------------------------------------ routing */
  function show(view) {
    S.view = view;
    $$(".view").forEach(function (v) { v.classList.toggle("on", v.id === "v-" + view); });
    $$("#rail button").forEach(function (b) { b.classList.toggle("on", b.dataset.view === view); });
    if (view === "manager") { refreshInstances(); renderManager(); }
    if (view === "host") renderHost();
    $(".main").scrollTop = 0;
  }

  /* ------------------------------------------------------------- events */
  function wire() {
    $("#rail").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-view]");
      if (b) show(b.dataset.view);
    });

    $("#liteBtn").addEventListener("click", function () { applyLite(!S.lite); });

    var qTimer = null;
    $("#q").addEventListener("input", function () {
      var v = this.value;
      clearTimeout(qTimer);
      qTimer = setTimeout(function () { S.filters.q = v; renderGrid(); }, 120);
    });

    $("#sort").addEventListener("change", function () { S.filters.sort = this.value; renderGrid(); });

    $("#famChips").addEventListener("click", function (ev) {
      var c = ev.target.closest("[data-fam]");
      if (!c) return;
      S.filters.family = c.dataset.fam;
      renderFilters();
      renderGrid();
    });

    $("#wChips").addEventListener("click", function (ev) {
      var c = ev.target.closest(".chip");
      if (!c) return;
      if (c.dataset.w !== undefined) S.filters.weight = c.dataset.w;
      else if (c.dataset.kind) S.filters.kind = S.filters.kind === c.dataset.kind ? "" : c.dataset.kind;
      else if (c.dataset.arch) S.filters.arch = !S.filters.arch;
      renderFilters();
      renderGrid();
    });

    $("#grid").addEventListener("click", function (ev) {
      var c = ev.target.closest(".card");
      if (c) openConfigure(c.dataset.id);
    });

    $("#grid").addEventListener("keydown", function (ev) {
      if (ev.key !== "Enter" && ev.key !== " ") return;
      var c = ev.target.closest(".card");
      if (c) { ev.preventDefault(); openConfigure(c.dataset.id); }
    });

    $("#tasteChips").addEventListener("click", function (ev) {
      var c = ev.target.closest("[data-taste]");
      if (!c) return;
      S.smart.taste = c.dataset.taste;
      renderSmartControls();
      runSmart();
    });

    $("#purposeChips").addEventListener("click", function (ev) {
      var c = ev.target.closest("[data-purpose]");
      if (!c) return;
      S.smart.purpose = c.dataset.purpose;
      renderSmartControls();
      runSmart();
    });

    $("#smartBtn").addEventListener("click", runSmart);

    $("#smartOut").addEventListener("click", function (ev) {
      var u = ev.target.closest("[data-use]");
      if (u) return openConfigure(u.dataset.use);
      var g = ev.target.closest("[data-go]");
      if (g) return openConfigure(g.dataset.go, true);
    });

    document.addEventListener("click", function (ev) {
      var cp = ev.target.closest("[data-copy]");
      if (cp) { copy(cp.dataset.copy); return; }
      var bk = ev.target.closest("[data-back]");
      if (bk) { show(bk.dataset.back); return; }
      var tm = ev.target.closest("[data-term]");
      if (tm) { openTerm(tm.dataset.term); return; }
      var lg = ev.target.closest("[data-logs]");
      if (lg) { showLogs(lg.dataset.logs); return; }
      var tn = ev.target.closest("[data-tune]");
      if (tn) { showTune(tn.dataset.tune); return; }
      var act = ev.target.closest("[data-act]");
      if (act) {
        var row = act.closest(".inst");
        if (row) instAction(row.dataset.name, act.dataset.act);
        return;
      }
      if (ev.target.id === "goBtn") { startLaunch(); return; }
      if (ev.target.id === "retryBtn") { startLaunch(); return; }
      if (ev.target.id === "dfBtn") {
        var o = $("#dfOut");
        o.style.display = o.style.display === "none" ? "block" : "none";
        return;
      }
      if (ev.target.id === "modalClose" || ev.target.id === "modal") {
        $("#modal").style.display = "none";
      }
    });

    document.addEventListener("input", function (ev) {
      var t = ev.target;
      if (t.type !== "range" || !S.plan) return;
      syncRange(t);
      if (t.id === "sMem") { S.plan.memory_mb = Number(t.value); $("#sMemV").textContent = mb(t.value); }
      if (t.id === "sCpu") { S.plan.cpus = Number(t.value); $("#sCpuV").textContent = Number(t.value).toFixed(1) + " cores"; }
      if (t.id === "sShm") { S.plan.shm_mb = Number(t.value); $("#sShmV").textContent = mb(t.value); }
      if (t.id === "sDisk") { S.plan.disk_mb = Number(t.value); $("#sDiskV").textContent = mb(t.value); }
    });

    document.addEventListener("change", function (ev) {
      if (ev.target.id === "oAuth") {
        $("#authFields").style.display = ev.target.checked ? "block" : "none";
      }
    });

    /* terminal keyboard */
    var sh = $("#shTerm");
    sh.addEventListener("keydown", function (ev) {
      if (ev.metaKey || ev.altKey) return;
      if (ev.ctrlKey && (ev.key === "c" || ev.key === "v") && window.getSelection().toString()) return;
      var seq = keyToSeq(ev);
      if (seq != null) { ev.preventDefault(); sendKeys(seq); }
    });
    sh.addEventListener("paste", function (ev) {
      ev.preventDefault();
      sendKeys((ev.clipboardData || window.clipboardData).getData("text"));
    });
    $("#shFit").addEventListener("click", function () {
      if (!S.term || !S.termId) return;
      var f = S.term.fit();
      api("/api/term/" + S.termId + "/resize", { body: f }).catch(function () {});
      toast("Resized", f.cols + "x" + f.rows);
    });
    $("#shClose").addEventListener("click", function () {
      if (S.termId) api("/api/term/" + S.termId + "/close", { body: {} }).catch(function () {});
      if (S.termES) S.termES.close();
      S.termId = null;
      show("manager");
    });

    window.addEventListener("keydown", function (ev) {
      if (ev.target.tagName === "INPUT" || ev.target.id === "shTerm") return;
      if (ev.key === "/") { ev.preventDefault(); $("#q").focus(); }
      if (ev.key === "Escape") $("#modal").style.display = "none";
      if (ev.key === "1") show("browse");
      if (ev.key === "2") show("manager");
      if (ev.key === "3") show("host");
    });
  }

  document.addEventListener("DOMContentLoaded", function () { wire(); boot(); });
})();
__FORGE_FILE_APP_JS__
  cat > "$FORGE_APP/term.js" <<'__FORGE_FILE_TERM_JS__'
/* Selkies Forge - a small but real terminal.
 *
 * Grid based, so cursor moves, line erases, colours and the alternate screen
 * all behave: `docker pull` output, vim and htop all render correctly.
 * Repaints are coalesced into one rAF per frame, which keeps it cheap on a Pi.
 */
(function () {
  "use strict";

  var PAL = [
    "#1b2130", "#ff6b7e", "#3ddc97", "#ffc24d", "#5aa6ff", "#b88dff", "#49d6e0", "#cfe0f5",
    "#4a5771", "#ff9aa7", "#7ae2b0", "#ffd79a", "#8ec5ff", "#cbb8ff", "#8ee9f0", "#ffffff"
  ];

  function xterm256(n) {
    if (n < 16) return PAL[n];
    if (n < 232) {
      n -= 16;
      var r = Math.floor(n / 36), g = Math.floor((n % 36) / 6), b = n % 6;
      var f = function (v) { return v === 0 ? 0 : 55 + v * 40; };
      return "rgb(" + f(r) + "," + f(g) + "," + f(b) + ")";
    }
    var v = 8 + (n - 232) * 10;
    return "rgb(" + v + "," + v + "," + v + ")";
  }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function Cell() { this.c = " "; this.f = null; this.b = null; this.bo = false; this.un = false; }

  function Term(el, opts) {
    opts = opts || {};
    this.el = el;
    this.cols = opts.cols || 100;
    this.rows = opts.rows || 28;
    this.maxScroll = opts.maxScroll || 2400;
    this.showCursor = true;
    this.cursorVisible = true;
    this.scroll = [];
    this.alt = null;
    this.state = "G";
    this.buf = "";
    this.pending = "";
    this.dirty = false;
    this.frame = null;
    this.atBottom = true;
    this.reset();
    var self = this;
    el.addEventListener("scroll", function () {
      self.atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 28;
    }, { passive: true });
  }

  Term.prototype.reset = function () {
    this.grid = [];
    for (var y = 0; y < this.rows; y++) this.grid.push(this.blankRow());
    this.x = 0;
    this.y = 0;
    this.attr = { f: null, b: null, bo: false, un: false, inv: false };
    this.scroll = [];
    this.markDirty();
  };

  Term.prototype.blankRow = function () {
    var r = [];
    for (var x = 0; x < this.cols; x++) r.push(new Cell());
    return r;
  };

  Term.prototype.resize = function (cols, rows) {
    cols = Math.max(20, Math.min(400, cols | 0));
    rows = Math.max(6, Math.min(200, rows | 0));
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    var g = [];
    for (var y = 0; y < rows; y++) {
      var old = this.grid[y];
      var row = this.blankRow();
      if (old) for (var x = 0; x < Math.min(cols, old.length); x++) row[x] = old[x];
      g.push(row);
    }
    this.grid = g;
    this.x = Math.min(this.x, cols - 1);
    this.y = Math.min(this.y, rows - 1);
    this.markDirty();
  };

  /* ---------------------------------------------------------- log mode */
  Term.prototype.line = function (text, cls) {
    var row = [];
    var s = String(text == null ? "" : text).replace(/\t/g, "        ");
    for (var i = 0; i < s.length; i++) {
      var c = new Cell();
      c.c = s[i];
      c.cls = cls || null;
      row.push(c);
    }
    this.scroll.push(row);
    while (this.scroll.length > this.maxScroll) this.scroll.shift();
    this.markDirty();
  };

  /* ---------------------------------------------------------- tty mode */
  Term.prototype.write = function (data) {
    this.pending += data;
    if (this.pending.length > 400000) {
      this.pending = this.pending.slice(-200000);
    }
    this.parse();
    this.markDirty();
  };

  Term.prototype.parse = function () {
    var s = this.pending;
    this.pending = "";
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (this.state === "G") {
        if (ch === "\x1b") { this.state = "E"; this.buf = ""; continue; }
        this.put(ch);
      } else if (this.state === "E") {
        if (ch === "[") { this.state = "C"; this.buf = ""; }
        else if (ch === "]") { this.state = "O"; this.buf = ""; }
        else if (ch === "(" || ch === ")" || ch === "#" || ch === "%") { this.state = "X"; }
        else if (ch === "M") { this.revIndex(); this.state = "G"; }
        else if (ch === "7" || ch === "8" || ch === "=" || ch === ">") { this.state = "G"; }
        else if (ch === "c") { this.reset(); this.state = "G"; }
        else { this.state = "G"; }
      } else if (this.state === "X") {
        this.state = "G";
      } else if (this.state === "C") {
        if (ch >= "@" && ch <= "~") { this.csi(ch, this.buf); this.state = "G"; this.buf = ""; }
        else { this.buf += ch; if (this.buf.length > 48) { this.state = "G"; this.buf = ""; } }
      } else if (this.state === "O") {
        if (ch === "\x07") { this.state = "G"; this.buf = ""; }
        else if (ch === "\x1b") { this.state = "OE"; }
        else { this.buf += ch; if (this.buf.length > 512) { this.state = "G"; this.buf = ""; } }
      } else if (this.state === "OE") {
        this.state = "G";
        this.buf = "";
      }
    }
  };

  Term.prototype.put = function (ch) {
    var code = ch.charCodeAt(0);
    if (ch === "\n") { this.nextLine(); return; }
    if (ch === "\r") { this.x = 0; return; }
    if (ch === "\b") { this.x = Math.max(0, this.x - 1); return; }
    if (ch === "\t") {
      var n = 8 - (this.x % 8);
      for (var i = 0; i < n && this.x < this.cols; i++) this.put(" ");
      return;
    }
    if (code === 7) return;                       /* bell */
    if (code < 32 || code === 127) return;
    if (this.x >= this.cols) { this.x = 0; this.nextLine(); }
    var cell = this.grid[this.y][this.x];
    cell.c = ch;
    cell.cls = null;
    if (this.attr.inv) { cell.f = this.attr.b || "#04070e"; cell.b = this.attr.f || "#cfe0f5"; }
    else { cell.f = this.attr.f; cell.b = this.attr.b; }
    cell.bo = this.attr.bo;
    cell.un = this.attr.un;
    this.x++;
  };

  Term.prototype.nextLine = function () {
    this.x = 0;
    this.y++;
    if (this.y >= this.rows) {
      this.y = this.rows - 1;
      if (!this.alt) {
        this.scroll.push(this.grid.shift());
        while (this.scroll.length > this.maxScroll) this.scroll.shift();
      } else {
        this.grid.shift();
      }
      this.grid.push(this.blankRow());
    }
  };

  Term.prototype.revIndex = function () {
    this.y--;
    if (this.y < 0) { this.y = 0; this.grid.pop(); this.grid.unshift(this.blankRow()); }
  };

  Term.prototype.csi = function (fin, raw) {
    var priv = raw[0] === "?";
    var body = priv ? raw.slice(1) : raw;
    var ps = body.split(";").map(function (v) { return v === "" ? null : parseInt(v, 10); });
    var p0 = ps[0] == null ? null : ps[0];
    var n = p0 == null ? 1 : Math.max(1, p0);

    if (priv) {
      var on = fin === "h";
      if (p0 === 1049 || p0 === 1047 || p0 === 47) {
        if (on && !this.alt) {
          this.alt = { grid: this.grid, x: this.x, y: this.y };
          this.grid = [];
          for (var i = 0; i < this.rows; i++) this.grid.push(this.blankRow());
          this.x = this.y = 0;
        } else if (!on && this.alt) {
          this.grid = this.alt.grid;
          this.x = this.alt.x;
          this.y = this.alt.y;
          this.alt = null;
        }
      } else if (p0 === 25) {
        this.cursorVisible = on;
      }
      return;
    }

    switch (fin) {
      case "A": this.y = Math.max(0, this.y - n); break;
      case "B": this.y = Math.min(this.rows - 1, this.y + n); break;
      case "C": this.x = Math.min(this.cols - 1, this.x + n); break;
      case "D": this.x = Math.max(0, this.x - n); break;
      case "E": this.y = Math.min(this.rows - 1, this.y + n); this.x = 0; break;
      case "F": this.y = Math.max(0, this.y - n); this.x = 0; break;
      case "G": case "`": this.x = Math.min(this.cols - 1, Math.max(0, n - 1)); break;
      case "d": this.y = Math.min(this.rows - 1, Math.max(0, n - 1)); break;
      case "H": case "f":
        this.y = Math.min(this.rows - 1, Math.max(0, (ps[0] || 1) - 1));
        this.x = Math.min(this.cols - 1, Math.max(0, (ps[1] || 1) - 1));
        break;
      case "J": this.eraseDisplay(p0 || 0); break;
      case "K": this.eraseLine(p0 || 0); break;
      case "L": this.insertLines(n); break;
      case "M": this.deleteLines(n); break;
      case "P": this.deleteChars(n); break;
      case "X": this.eraseChars(n); break;
      case "@": this.insertChars(n); break;
      case "m": this.sgr(ps); break;
      case "s": this.saved = { x: this.x, y: this.y }; break;
      case "u": if (this.saved) { this.x = this.saved.x; this.y = this.saved.y; } break;
      default: break;
    }
  };

  Term.prototype.blank = function (row, from, to) {
    for (var x = from; x < to && x < this.cols; x++) row[x] = new Cell();
  };

  Term.prototype.eraseLine = function (mode) {
    var row = this.grid[this.y];
    if (mode === 0) this.blank(row, this.x, this.cols);
    else if (mode === 1) this.blank(row, 0, this.x + 1);
    else this.blank(row, 0, this.cols);
  };

  Term.prototype.eraseDisplay = function (mode) {
    if (mode === 0) {
      this.eraseLine(0);
      for (var y = this.y + 1; y < this.rows; y++) this.grid[y] = this.blankRow();
    } else if (mode === 1) {
      this.eraseLine(1);
      for (var y2 = 0; y2 < this.y; y2++) this.grid[y2] = this.blankRow();
    } else {
      for (var y3 = 0; y3 < this.rows; y3++) this.grid[y3] = this.blankRow();
      if (mode === 3) this.scroll = [];
    }
  };

  Term.prototype.insertLines = function (n) {
    for (var i = 0; i < n; i++) { this.grid.splice(this.y, 0, this.blankRow()); this.grid.pop(); }
  };

  Term.prototype.deleteLines = function (n) {
    for (var i = 0; i < n; i++) { this.grid.splice(this.y, 1); this.grid.push(this.blankRow()); }
  };

  Term.prototype.deleteChars = function (n) {
    var row = this.grid[this.y];
    for (var i = 0; i < n; i++) { row.splice(this.x, 1); row.push(new Cell()); }
  };

  Term.prototype.insertChars = function (n) {
    var row = this.grid[this.y];
    for (var i = 0; i < n; i++) { row.splice(this.x, 0, new Cell()); row.pop(); }
  };

  Term.prototype.eraseChars = function (n) {
    this.blank(this.grid[this.y], this.x, this.x + n);
  };

  Term.prototype.sgr = function (ps) {
    if (!ps.length || (ps.length === 1 && ps[0] == null)) ps = [0];
    for (var i = 0; i < ps.length; i++) {
      var p = ps[i] == null ? 0 : ps[i];
      if (p === 0) this.attr = { f: null, b: null, bo: false, un: false, inv: false };
      else if (p === 1) this.attr.bo = true;
      else if (p === 2 || p === 22) this.attr.bo = false;
      else if (p === 4) this.attr.un = true;
      else if (p === 24) this.attr.un = false;
      else if (p === 7) this.attr.inv = true;
      else if (p === 27) this.attr.inv = false;
      else if (p >= 30 && p <= 37) this.attr.f = PAL[p - 30];
      else if (p === 39) this.attr.f = null;
      else if (p >= 40 && p <= 47) this.attr.b = PAL[p - 40];
      else if (p === 49) this.attr.b = null;
      else if (p >= 90 && p <= 97) this.attr.f = PAL[p - 90 + 8];
      else if (p >= 100 && p <= 107) this.attr.b = PAL[p - 100 + 8];
      else if (p === 38 || p === 48) {
        var isFg = p === 38;
        if (ps[i + 1] === 5) { var c = ps[i + 2] || 0; this.attr[isFg ? "f" : "b"] = xterm256(c); i += 2; }
        else if (ps[i + 1] === 2) {
          var col = "rgb(" + (ps[i + 2] || 0) + "," + (ps[i + 3] || 0) + "," + (ps[i + 4] || 0) + ")";
          this.attr[isFg ? "f" : "b"] = col;
          i += 4;
        }
      }
    }
  };

  /* ----------------------------------------------------------- painting */
  Term.prototype.markDirty = function () {
    if (this.dirty) return;
    this.dirty = true;
    var self = this;
    this.frame = requestAnimationFrame(function () { self.render(); });
  };

  Term.prototype.rowHtml = function (row, cursorX) {
    var out = "";
    var run = "";
    var key = null;
    var lastTrim = row.length;
    while (lastTrim > 0 && row[lastTrim - 1].c === " " && !row[lastTrim - 1].b) lastTrim--;
    if (cursorX != null) lastTrim = Math.max(lastTrim, cursorX + 1);

    function styleKey(c, isCur) {
      if (isCur) return "CUR";
      if (c.cls) return "L" + c.cls;
      if (!c.f && !c.b && !c.bo && !c.un) return "";
      return (c.f || "-") + "|" + (c.b || "-") + "|" + (c.bo ? 1 : 0) + "|" + (c.un ? 1 : 0);
    }

    function open(k, c) {
      if (k === "") return "";
      if (k === "CUR") return '<span class="cur">';
      if (k.charAt(0) === "L") return '<span class="' + k.slice(1) + '">';
      var st = "";
      if (c.f) st += "color:" + c.f + ";";
      if (c.b) st += "background:" + c.b + ";";
      if (c.bo) st += "font-weight:700;";
      if (c.un) st += "text-decoration:underline;";
      return '<span style="' + st + '">';
    }

    var curCell = null;
    for (var x = 0; x < lastTrim; x++) {
      var c = row[x];
      var isCur = cursorX === x;
      var k = styleKey(c, isCur);
      if (k !== key) {
        if (key !== null && key !== "") out += "</span>";
        out += open(k, c);
        key = k;
        curCell = c;
      }
      out += esc(c.c === "" ? " " : c.c);
    }
    if (key !== null && key !== "") out += "</span>";
    return out;
  };

  Term.prototype.render = function () {
    this.dirty = false;
    var parts = [];
    var sb = this.scroll;
    var start = Math.max(0, sb.length - this.maxScroll);
    for (var i = start; i < sb.length; i++) parts.push(this.rowHtml(sb[i], null));
    var showCur = this.showCursor && this.cursorVisible;
    for (var y = 0; y < this.grid.length; y++) {
      parts.push(this.rowHtml(this.grid[y], showCur && y === this.y ? this.x : null));
    }
    /* Trim trailing blank grid rows so the log view doesn't float in space. */
    while (parts.length && parts[parts.length - 1] === "" && this.gridOnlyTrailing) parts.pop();
    this.el.innerHTML = parts.join("\n");
    if (this.atBottom) this.el.scrollTop = this.el.scrollHeight;
  };

  Term.prototype.measure = function () {
    var probe = document.createElement("span");
    probe.textContent = "0123456789";
    probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre;font:inherit";
    this.el.appendChild(probe);
    var w = probe.getBoundingClientRect().width / 10;
    var h = probe.getBoundingClientRect().height * 1.42;
    this.el.removeChild(probe);
    return { w: w || 7.2, h: h || 17 };
  };

  Term.prototype.fit = function () {
    var m = this.measure();
    var cols = Math.max(24, Math.floor((this.el.clientWidth - 26) / m.w));
    var rows = Math.max(8, Math.floor((this.el.clientHeight - 22) / m.h));
    this.resize(cols, rows);
    return { cols: this.cols, rows: this.rows };
  };

  window.ForgeTerm = Term;
})();
__FORGE_FILE_TERM_JS__
  cat > "$FORGE_APP/logos.js" <<'__FORGE_FILE_LOGOS_JS__'
/* Selkies Forge - distro marks and desktop glyphs.
   Hand-drawn simplified shapes so the UI needs no network and no icon font. */
(function () {
  "use strict";

  var L = {};

  L.ubuntu = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="none" stroke="#E95420" stroke-width="3.4" stroke-dasharray="20 9" stroke-linecap="round" transform="rotate(-18 24 24)"/><circle cx="24" cy="7.6" r="4.6" fill="#E95420"/><circle cx="9.7" cy="32.2" r="4.6" fill="#E95420"/><circle cx="38.3" cy="32.2" r="4.6" fill="#E95420"/><circle cx="24" cy="24" r="4.1" fill="#E95420" opacity=".55"/></svg>';

  L.debian = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M31 11.5a15 15 0 1 0 5.4 17.8" fill="none" stroke="#D70A53" stroke-width="3.2" stroke-linecap="round"/><path d="M28.8 17.6a9.2 9.2 0 1 0 3.1 10.7" fill="none" stroke="#D70A53" stroke-width="3" stroke-linecap="round"/><circle cx="24.6" cy="24.4" r="3.1" fill="#D70A53"/></svg>';

  L.fedora = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="#51A2DA"/><path d="M28.6 13.6h-3.9a5.9 5.9 0 0 0-5.9 5.9v3.4h-3.2v5.4h3.2v6.1h5.6v-6.1h4.1v-5.4h-4.1v-2.6c0-.9.7-1.6 1.6-1.6h2.6z" fill="#fff"/></svg>';

  L.arch = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 6 7 40l17-9 17 9z" fill="none" stroke="#1793D1" stroke-width="3.2" stroke-linejoin="round"/><path d="M24 14.5 16.5 31 24 27.2 31.5 31z" fill="#1793D1" opacity=".5"/></svg>';

  L.alpine = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="6" width="36" height="36" rx="7" fill="#0D597F"/><path d="M12 33 20 20l5.5 9 2.6-4.2L36 33z" fill="#fff"/><path d="M20 20l5.5 9h-11z" fill="#9ad7f2"/></svg>';

  L.kali = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="17" fill="#0b1120" stroke="#367BF0" stroke-width="2"/><path d="M14 13v22M14 24l10-9M14 25l11 10" fill="none" stroke="#367BF0" stroke-width="3" stroke-linecap="round"/><path d="M28 14c7 2 10 6 10 11s-4 8-8 9c4-3 5-6 4-9s-3-6-6-11z" fill="#367BF0" opacity=".75"/></svg>';

  L.parrot = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M30 9c-8 0-14 6-14 14 0 6 3 9 3 13 0 2-2 3-4 3h18c5 0 9-5 9-12 0-10-5-18-12-18z" fill="#15E0C8"/><circle cx="31" cy="19" r="2.4" fill="#06262b"/><path d="M16 21l-7 4 7 3z" fill="#0fae9b"/></svg>';

  L.almalinux = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 7 10 41h6.4l7.6-19 7.6 19H38z" fill="#0F4266"/><path d="M17 29h14l2.4 6H14.6z" fill="#49C96D"/><circle cx="24" cy="12" r="3.4" fill="#FFD042"/></svg>';

  L.rocky = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="none" stroke="#10B981" stroke-width="2.4"/><path d="M13 31 25 15l11 15z" fill="#10B981"/><path d="M25 15l-5.5 8h11z" fill="#6ee7b7"/></svg>';

  L.oracle = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="15" width="36" height="18" rx="9" fill="none" stroke="#C74634" stroke-width="4.2"/></svg>';

  L.centos = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 7v12M24 29v12M7 24h12M29 24h12" stroke-width="5" stroke-linecap="round" fill="none" stroke="#932279"/><path d="M24 7v12" stroke="#932279" stroke-width="5" stroke-linecap="round"/><path d="M7 24h12" stroke="#EFA724" stroke-width="5" stroke-linecap="round"/><path d="M24 29v12" stroke="#79A031" stroke-width="5" stroke-linecap="round"/><path d="M29 24h12" stroke="#262577" stroke-width="5" stroke-linecap="round"/><circle cx="24" cy="24" r="4.2" fill="#fff" opacity=".85"/></svg>';

  L.opensuse = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="#73BA25"/><circle cx="18.5" cy="19.5" r="3" fill="#fff"/><circle cx="18.5" cy="19.5" r="1.3" fill="#2d4a0c"/><path d="M30 17c4 3 5 8 3 12-2 3-6 4-9 3 5-1 7-4 7-8 0-3-1-5-1-7z" fill="#fff" opacity=".85"/></svg>';

  L.remnux = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 6l14 8v20l-14 8-14-8V14z" fill="#5B3FA8"/><circle cx="22" cy="22" r="6.5" fill="none" stroke="#fff" stroke-width="2.6"/><path d="M27 27l6 6" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>';

  L.mint = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="9" width="36" height="30" rx="5" fill="#86BE43"/><path d="M13 31V20c0-3 2-5 5-5 2.4 0 3.6 1.2 4.4 2.6.8-1.4 2-2.6 4.4-2.6 3 0 5 2 5 5v11h-4.4V21c0-1-.6-1.6-1.6-1.6s-1.6.6-1.6 1.6v10h-4.4V21c0-1-.6-1.6-1.6-1.6S16 20 16 21v10z" fill="#fff"/></svg>';

  L.zorin = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="none" stroke="#1792D3" stroke-width="3"/><path d="M15 17h18L15 31h18" fill="none" stroke="#1792D3" stroke-width="3.2" stroke-linejoin="round" stroke-linecap="round"/></svg>';

  L.pop = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M10 38V12h9a8 8 0 0 1 0 16h-9" fill="none" stroke="#48B9C7" stroke-width="4" stroke-linecap="round"/><path d="M30 16h8v8" fill="none" stroke="#FFB13D" stroke-width="4" stroke-linecap="round"/><path d="M38 32h-8" fill="none" stroke="#FFB13D" stroke-width="4" stroke-linecap="round"/></svg>';

  L.elementary = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16.5" fill="#64BAFF"/><path d="M31 27a8 8 0 1 1-1-8H17v4h12" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>';

  L.garuda = '<svg viewBox="0 0 48 48" aria-hidden="true"><path d="M24 8c6 6 14 8 14 16s-6 14-14 16c-8-2-14-8-14-16S18 14 24 8z" fill="none" stroke="#D81E5B" stroke-width="2.6"/><path d="M24 14c3 4 8 6 8 11s-4 8-8 10c-4-2-8-5-8-10s5-7 8-11z" fill="#D81E5B" opacity=".8"/></svg>';

  L["generic-mac"] = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="10" width="36" height="26" rx="5" fill="none" stroke="#9fb3d9" stroke-width="2.4"/><path d="M6 17h36" stroke="#9fb3d9" stroke-width="2"/><circle cx="11.5" cy="13.5" r="1.5" fill="#9fb3d9"/><circle cx="16.5" cy="13.5" r="1.5" fill="#9fb3d9"/><circle cx="21.5" cy="13.5" r="1.5" fill="#9fb3d9"/><rect x="16" y="38" width="16" height="2.6" rx="1.3" fill="#9fb3d9"/></svg>';

  L["generic-win"] = '<svg viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="9" width="36" height="24" rx="3" fill="none" stroke="#7fb0f0" stroke-width="2.4"/><path d="M6 15h36" stroke="#7fb0f0" stroke-width="2"/><rect x="6" y="36" width="36" height="6" rx="2" fill="#7fb0f0" opacity=".55"/><rect x="9" y="37.6" width="7" height="2.8" rx="1.4" fill="#0b1120"/></svg>';

  L.generic = '<svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="16" fill="none" stroke="currentColor" stroke-width="2.4" opacity=".8"/><circle cx="24" cy="19" r="5" fill="currentColor" opacity=".8"/><path d="M14 36c2-5 5.5-7.5 10-7.5S32 31 34 36z" fill="currentColor" opacity=".8"/></svg>';

  /* ---------------------------------------------------------------- *
   * Desktop glyphs: layout marks, not brand logos.  Each one shows
   * roughly how that desktop arranges the screen.
   * ---------------------------------------------------------------- */
  var F = 'fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"';
  function frame(inner) {
    return '<svg viewBox="0 0 32 24" aria-hidden="true"><rect x="1" y="1" width="30" height="22" rx="2.5" ' +
      F + ' opacity=".55"/>' + inner + '</svg>';
  }
  var G = {};
  G.xfce = frame('<rect x="3" y="3" width="26" height="3" rx="1.2" fill="currentColor" opacity=".8"/><rect x="5" y="9" width="11" height="10" rx="1.6" ' + F + '/><rect x="18" y="12" width="9" height="7" rx="1.6" ' + F + '/>');
  G.mate = frame('<rect x="3" y="3" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="3" y="18.4" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="8" y="8" width="16" height="8" rx="1.6" ' + F + '/>');
  G.kde = frame('<rect x="3" y="18" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><rect x="5" y="4" width="13" height="11" rx="1.6" ' + F + '/><rect x="20" y="7" width="7" height="8" rx="1.6" ' + F + '/><circle cx="6.4" cy="19.5" r="1" fill="#0b1120"/>');
  G.lxqt = frame('<rect x="3" y="19" width="26" height="2.4" rx="1.2" fill="currentColor" opacity=".8"/><rect x="6" y="5" width="20" height="11" rx="1.6" ' + F + '/>');
  G.lxde = G.lxqt;
  G.lumina = G.lxqt;
  G.cinnamon = frame('<rect x="3" y="18" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><rect x="4" y="18.6" width="4" height="1.8" rx=".9" fill="#0b1120"/><rect x="5" y="4" width="22" height="11" rx="1.8" ' + F + '/>');
  G.budgie = frame('<rect x="22" y="3" width="7" height="18" rx="2" fill="currentColor" opacity=".75"/><rect x="4" y="5" width="15" height="14" rx="1.8" ' + F + '/>');
  G.gnome = frame('<rect x="3" y="3" width="26" height="3" rx="1.4" fill="currentColor" opacity=".8"/><circle cx="12" cy="14" r="1.5" fill="currentColor"/><circle cx="16.5" cy="14" r="1.5" fill="currentColor"/><circle cx="21" cy="14" r="1.5" fill="currentColor"/>');
  G.ukui = G.cinnamon;
  G.enlightenment = frame('<path d="M22 7a7.5 7.5 0 1 0 2 9.5" ' + F + '/><circle cx="16" cy="12" r="2.4" fill="currentColor" opacity=".8"/>');
  G.i3 = frame('<rect x="4" y="4" width="11" height="16" rx="1.4" ' + F + '/><rect x="17" y="4" width="11" height="7.5" rx="1.4" ' + F + '/><rect x="17" y="12.5" width="11" height="7.5" rx="1.4" ' + F + '/>');
  G.bspwm = frame('<rect x="4" y="4" width="13" height="16" rx="1.4" ' + F + '/><rect x="19" y="4" width="9" height="16" rx="1.4" ' + F + '/><path d="M19 12h9" stroke="currentColor" stroke-width="1.7"/>');
  G.herbstluftwm = frame('<rect x="4" y="4" width="24" height="7" rx="1.4" ' + F + '/><rect x="4" y="13" width="11" height="7" rx="1.4" ' + F + '/><rect x="17" y="13" width="11" height="7" rx="1.4" ' + F + '/>');
  G.qtile = frame('<rect x="4" y="4" width="8" height="16" rx="1.4" ' + F + '/><rect x="14" y="4" width="14" height="10" rx="1.4" ' + F + '/><rect x="14" y="16" width="14" height="4" rx="1.4" ' + F + '/>');
  G.xmonad = frame('<rect x="4" y="4" width="15" height="16" rx="1.4" ' + F + '/><rect x="21" y="4" width="7" height="5" rx="1.2" ' + F + '/><rect x="21" y="11" width="7" height="4" rx="1.2" ' + F + '/><rect x="21" y="17" width="7" height="3" rx="1.2" ' + F + '/>');
  G.awesome = frame('<rect x="3" y="3" width="26" height="2.6" rx="1.2" fill="currentColor" opacity=".8"/><rect x="4" y="8" width="12" height="12" rx="1.4" ' + F + '/><rect x="18" y="8" width="10" height="12" rx="1.4" ' + F + '/>');
  G.spectrwm = G.i3;
  G.dwm = frame('<rect x="3" y="3" width="26" height="2.4" rx="1.1" fill="currentColor" opacity=".8"/><rect x="4" y="8" width="16" height="12" rx="1.2" ' + F + '/><rect x="22" y="8" width="6" height="12" rx="1.2" ' + F + '/>');
  G.cwm = frame('<rect x="6" y="6" width="14" height="10" rx="1.4" ' + F + '/><rect x="13" y="11" width="14" height="9" rx="1.4" ' + F + '/>');
  G.ratpoison = frame('<rect x="4" y="4" width="24" height="16" rx="1.4" ' + F + '/>');
  G.openbox = frame('<rect x="5" y="5" width="14" height="10" rx="1.4" ' + F + '/><rect x="14" y="10" width="13" height="9" rx="1.4" ' + F + '/><rect x="3" y="19" width="26" height="2" rx="1" fill="currentColor" opacity=".7"/>');
  G.fluxbox = frame('<rect x="4" y="4" width="24" height="3" rx="1.2" fill="currentColor" opacity=".75"/><rect x="6" y="9" width="12" height="9" rx="1.4" ' + F + '/><rect x="19" y="9" width="8" height="9" rx="1.4" ' + F + '/>');
  G.icewm = frame('<rect x="3" y="18.4" width="26" height="2.8" rx="1.3" fill="currentColor" opacity=".8"/><rect x="5" y="4" width="22" height="12" rx="1.4" ' + F + '/><rect x="5" y="4" width="22" height="3" rx="1.4" fill="currentColor" opacity=".55"/>');
  G.jwm = G.icewm;
  G.pekwm = G.fluxbox;
  G.wmaker = frame('<rect x="22" y="3" width="6" height="6" rx="1.3" fill="currentColor" opacity=".8"/><rect x="22" y="11" width="6" height="6" rx="1.3" fill="currentColor" opacity=".55"/><rect x="4" y="5" width="15" height="14" rx="1.6" ' + F + '/>');
  G.fvwm = G.cwm;
  G.twm = frame('<rect x="6" y="7" width="20" height="11" rx="1" ' + F + '/><path d="M6 10h20" stroke="currentColor" stroke-width="1.7"/>');
  G.generic = G.openbox;

  window.FORGE_LOGOS = L;
  window.FORGE_GLYPHS = G;
  window.forgeLogo = function (family) { return L[family] || L.generic; };
  window.forgeGlyph = function (glyph) { return G[glyph] || G.generic; };
})();
__FORGE_FILE_LOGOS_JS__
  if command -v sha256sum >/dev/null 2>&1; then
    local bad=0 f want got
    for f in catalog.py engine.py index.html app.css app.js term.js logos.js; do
      case "$f" in
        catalog.py) want="$FORGE_SHA_CATALOG_PY" ;;
        engine.py) want="$FORGE_SHA_ENGINE_PY" ;;
        index.html) want="$FORGE_SHA_INDEX_HTML" ;;
        app.css) want="$FORGE_SHA_APP_CSS" ;;
        app.js) want="$FORGE_SHA_APP_JS" ;;
        term.js) want="$FORGE_SHA_TERM_JS" ;;
        logos.js) want="$FORGE_SHA_LOGOS_JS" ;;
      esac
      got=$(sha256sum "$FORGE_APP/$f" | cut -d' ' -f1)
      if [ "$got" != "$want" ]; then
        bad=1
        printf '  %s!%s %s did not extract cleanly\n' "$YEL" "$NC" "$f"
      fi
    done
    if [ "$bad" = 1 ]; then
      die "the embedded payload is damaged; re-download this script"
    fi
  fi
  printf '%s' "$FORGE_PAYLOAD_SHA" > "$stamp"
}

# =========================================================================
#  engine plumbing
# =========================================================================

engine() { "$PY" "$FORGE_APP/engine.py" "$@"; }

ensure_dirs() { mkdir -p "$FORGE_HOME" "$FORGE_APP" "$FORGE_STATE" "$FORGE_LOGS"; }

# A second copy of the forge must not fight the first one over ports.
singleton_check() {
  local sj="$FORGE_STATE/server.json" pid url
  [ -f "$sj" ] || return 0
  pid=$("$PY" -c "import json;print(json.load(open('$sj')).get('pid',''))" 2>/dev/null)
  url=$("$PY" -c "import json;print(json.load(open('$sj')).get('url',''))" 2>/dev/null)
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    title "Already running" "a forge web UI is live as pid $pid"
    info "$url"
    local act
    act=$(menu_choose "What now?" \
      $'open\tUse the running one\tprint the link and exit' \
      $'kill\tStop it and carry on\tfrees the port' \
      $'ignore\tLeave it, start another\ta second UI on another port')
    case "$act" in
      open) printf '\n'; ok "web UI: $url"; exit 0 ;;
      kill) kill "$pid" 2>/dev/null; sleep 1; rm -f "$sj"; ok "stopped pid $pid" ;;
      *) : ;;
    esac
  else
    rm -f "$sj"
  fi
}

# =========================================================================
#  launching, with a live progress bar
# =========================================================================

render_result() {
  "$PY" - "$1" <<'PYEOF'
import json, sys, os
d = json.loads(sys.argv[1])
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s):
    return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
rows = []
tun = d.get("tunnel") or {}
if tun.get("url"):
    rows.append(("public link", tun["url"],
                 "serveo " + tun.get("mode", "http") +
                 (" (anonymous TCP tunnels are short lived)" if tun.get("mode") == "tcp" else "")))
rows.append(("on this box", d.get("local_url"), "no tunnel needed"))
if d.get("https_url"):
    rows.append(("local https", d["https_url"], "for other devices on your LAN"))
cred = d.get("credentials")
if cred:
    rows.append(("sign in", "%s / %s" % (cred["user"], cred["password"]), ""))
plan = d.get("plan") or {}
rows.append(("container", d.get("name"), "docker name"))
rows.append(("ports", ", ".join(str(p) for p in d.get("ports") or []), "picked free on this host"))
rows.append(("memory", "%d MB" % plan.get("memory_mb", 0), "hard cap"))
rows.append(("cpu", "%s cores" % plan.get("cpus"), "hard cap"))
rows.append(("shared mem", "%d MB" % plan.get("shm_mb", 0), "/dev/shm"))
rows.append(("storage", "%d MB" % plan.get("disk_mb", 0),
             "enforced" if d.get("quota_enforced") else "tracked, not enforced here"))
rows.append(("image", d.get("image"), ""))
print()
print("  " + c("1;38;5;79", "▰ READY") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
print("  " + c("2", "─" * 66))
for k, v, note in rows:
    if not v:
        continue
    line = "  %s %s" % (c("2", "%-12s" % k), c("1;38;5;75", v) if "link" in k or "http" in str(v)[:5] else v)
    if note:
        line += "  " + c("2", "· " + note)
    print(line)
print()
print("  " + c("2", "next:") + "  open the link above, or run this script again for the manager")
print()
PYEOF
}

stream_launch() {
  local id="$1"; shift
  local -a eargs=("$@")
  local pct=0 phase="working" result="" failed=0
  local log="$FORGE_LOGS/launch-$(date +%Y%m%d-%H%M%S).log"

  title "Forging $id" "live output below, full log at $log"
  printf '%s' "$HIDE"

  while IFS= read -r line; do
    printf '%s' "$line" >>"$log"
    printf '\n' >>"$log"
    case "$line" in
      P\ *)
        local _t p ph rest
        read -r _t p ph rest <<<"$line"
        pct="$p"; phase="${rest:-$ph}"
        bar "$pct" "$phase"
        ;;
      L\ *)
        printf '%s  %s%s%s\n' "$CLRL" "$DIM" "$(printf '%.160s' "${line#L }")" "$NC"
        bar "$pct" "$phase"
        ;;
      D\ *) result="${line#D }" ;;
      E\ *) failed=1; printf '%s' "$CLRL"; bad "${line#E }" ;;
      H\ *) printf '%s' "$CLRL"; info "try: ${line#H }" ;;
      *) : ;;
    esac
  done < <(engine launch "$id" "${eargs[@]}" 2>&1)

  printf '%s%s' "$CLRL" "$SHOW"
  if [ -n "$result" ]; then
    FORGE_COLOR=$COLOR render_result "$result"
    return 0
  fi
  [ "$failed" = 1 ] && printf '\n  %sthe full log is at %s%s\n\n' "$DIM" "$log" "$NC"
  return 1
}

# Ask about resources, then launch.
configure_and_launch() {
  local id="$1"
  local info_json plan_mem plan_cpu plan_shm plan_disk name ram_free cores
  info_json=$(engine info "$id" 2>/dev/null)
  [ -n "$info_json" ] || { bad "unknown entry: $id"; return 1; }

  eval "$("$PY" - "$info_json" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
p = d["plan"]
def q(s): return str(s).replace("'", "")
print("E_NAME='%s'" % q(d["name"]))
print("E_DESC='%s'" % q(d["desc"][:150]))
print("E_KIND='%s'" % q(d["kind"]))
print("E_DL=%d" % d["dl_mb"])
print("E_DISK=%d" % d["disk_mb"])
print("E_RAMMIN=%d" % d["ram_min"])
print("P_MEM=%d" % p["memory_mb"])
print("P_CPU=%s" % p["cpus"])
print("P_SHM=%d" % p["shm_mb"])
print("P_DISK=%d" % p["disk_mb"])
PYEOF
)"

  title "$E_NAME" "$E_DESC"
  info "$([ "$E_KIND" = pull ] && echo "prebuilt image" || echo "built on this machine") · about $((E_DL)) MB to download · roughly $((E_DISK)) MB on disk"
  printf '\n'

  if confirm "Use the suggested resources (${P_MEM} MB RAM, ${P_CPU} cores, ${P_SHM} MB shm)?" y; then
    :
  else
    P_MEM=$(ask "memory in MB (floor ${E_RAMMIN})" "$P_MEM")
    P_CPU=$(ask "cpu cores" "$P_CPU")
    P_SHM=$(ask "shared memory in MB" "$P_SHM")
    P_DISK=$(ask "storage budget in MB" "$P_DISK")
  fi
  name=$(ask "name for this instance (blank = auto)" "")

  local -a args=(--memory "$P_MEM" --cpus "$P_CPU" --shm "$P_SHM" --disk "$P_DISK")
  [ -n "$name" ] && args+=(--name "$name")
  if [ "$NO_TUNNEL" = 1 ]; then
    args+=(--no-tunnel)
  elif ! confirm "Open a public serveo tunnel?" y; then
    args+=(--no-tunnel)
  fi
  stream_launch "$id" "${args[@]}"
}

# =========================================================================
#  catalog pickers
# =========================================================================

catalog_menu_items() {  # args passed to `engine list`
  engine list "$@" --format tsv 2>/dev/null | "$PY" -c '
import sys
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if len(f) < 12:
        continue
    eid, name, fam, de, kind, weight, dl, ram, cpu, beauty, sub, desc = f[:12]
    dl = int(dl); ram = int(ram)
    tag = "ready" if kind == "pull" else "build"
    hint = "%-9s %5s MB dl  %5s MB ram  %s cores  %s" % (weight, dl, ram, cpu, tag)
    print("%s\t%s\t%s" % (eid, "%s  (%s)" % (name, de), hint))
'
}

pick_quick() {
  local -a items
  mapfile -t items < <(catalog_menu_items --quick --runnable)
  [ ${#items[@]} -eq 0 ] && { bad "no catalog entries run on this architecture"; return 1; }
  local choice
  choice=$(menu_choose "Hand picked desktops" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

pick_family() {
  local -a fams
  mapfile -t fams < <(engine list --runnable 2>/dev/null | "$PY" -c '
import json, sys, collections
d = json.load(sys.stdin)
c = collections.Counter(e["family"] for e in d["entries"])
lab = {}
for e in d["entries"]:
    lab[e["family"]] = e["family_label"]
for fam, n in c.most_common():
    print("%s\t%s\t%d desktops" % (fam, lab[fam], n))
')
  local fam
  fam=$(menu_choose "Which family?" "${fams[@]}") || return 1
  local -a items
  mapfile -t items < <(catalog_menu_items --runnable --family "$fam")
  local choice
  choice=$(menu_choose "$fam desktops" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

pick_search() {
  local term
  term=$(ask "search for" "")
  [ -z "$term" ] && return 1
  local -a items
  mapfile -t items < <(catalog_menu_items --runnable | grep -i -- "$term")
  if [ ${#items[@]} -eq 0 ]; then warn "nothing matched '$term'"; return 1; fi
  local choice
  choice=$(menu_choose "Matches for '$term'" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

cmd_smart() {
  title "Let it choose" "scored against this machine's free memory, cores and disk"
  local taste purpose
  taste=$(menu_choose "What matters most?" \
    $'balanced\tBalanced\tan even trade between looks and lightness' \
    $'beautiful\tBeautiful\tthe prettiest thing that still runs well' \
    $'lightest\tLightest\tsmallest footprint that is still pleasant' \
    $'fastest\tFastest\tlowest latency over the stream') || return 1
  purpose=$(menu_choose "What for?" \
    $'general\tAnything\tno particular slant' \
    $'dev\tWriting code\tfavours tooling-friendly bases' \
    $'security\tSecurity work\tKali and Parrot style images' \
    $'retro\tRetro and tiny\told school window managers' \
    $'media\tMedia\tricher desktops') || return 1

  spin_start "weighing every entry against this machine"
  local out
  out=$(engine smart --taste "$taste" --purpose "$purpose" --limit 3 2>/dev/null)
  spin_stop

  local -a items
  mapfile -t items < <(printf '%s' "$out" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
for p in d["picks"]:
    e = p["entry"]
    print("%s\t%s  (%s)\tscore %.0f  ·  %s" % (
        p["id"], e["name"], e["de_label"], p["score"], p["why"][0]))
')
  if [ ${#items[@]} -eq 0 ]; then
    warn "nothing in the catalog fits this machine right now"
    return 1
  fi
  printf '%s' "$out" | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
print()
for i, p in enumerate(d["picks"]):
    e = p["entry"]
    print("  %s %s  %s" % (c("1;38;5;141", "%d." % (i + 1)), c("1", e["name"]),
                           c("2", "score %.0f" % p["score"])))
    for w in p["why"]:
        print("     %s %s" % (c("2", "·"), w))
    pl = p["plan"]
    print("     %s" % c("2", "plan: %d MB RAM · %s cores · %d MB shm" % (
        pl["memory_mb"], pl["cpus"], pl["shm_mb"])))
    print()
' FORGE_COLOR=$COLOR
  local choice
  choice=$(menu_choose "Forge which one?" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

# =========================================================================
#  manager
# =========================================================================

print_instances() {
  engine instances 2>/dev/null | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
items = d["instances"]
if not items:
    print("\n  nothing forged yet\n")
    raise SystemExit(0)
print()
for i in items:
    state = "running" if i["running"] else (i.get("status") or "stopped")
    dot = c("38;5;79", "●") if i["running"] else c("2", "○")
    print("  %s %s  %s" % (dot, c("1", i["title"]), c("2", i["name"])))
    print("     %s %s" % (c("2", "%-9s" % "state"), state))
    if i.get("local_url"):
        print("     %s %s" % (c("2", "%-9s" % "local"), c("38;5;75", i["local_url"])))
    t = i.get("tunnel") or {}
    if t.get("url"):
        print("     %s %s %s" % (c("2", "%-9s" % "tunnel"), c("38;5;75", t["url"]),
                                 "" if t.get("alive") else c("38;5;203", "(down)")))
    lim = i.get("limits") or {}
    print("     %s %s MB ram cap · %s cores · ports %s" % (
        c("2", "%-9s" % "limits"), lim.get("memory_mb"), lim.get("cpus"),
        ", ".join(str(v) for v in (i.get("ports") or {}).values())))
    print()
' FORGE_COLOR=$COLOR
}

cmd_manager() {
  while :; do
    title "Manager" "every desktop this forge has built"
    print_instances
    local -a items
    mapfile -t items < <(engine instances 2>/dev/null | "$PY" -c '
import json, sys
for i in json.load(sys.stdin)["instances"]:
    st = "running" if i["running"] else (i.get("status") or "stopped")
    print("%s\t%s\t%s · %s" % (i["name"], i["title"], st, i["name"]))
')
    if [ ${#items[@]} -eq 0 ]; then
      confirm "Nothing to manage. Forge one now?" y && { pick_quick; continue; }
      return 0
    fi
    items+=($'__stats\tLive stats\tcpu, memory and bandwidth right now')
    items+=($'__back\tBack\treturn to the main menu')
    local pick
    pick=$(menu_choose "Pick an instance" "${items[@]}") || return 0
    case "$pick" in
      __back|"") return 0 ;;
      __stats)
        spin_start "sampling docker stats"
        local s; s=$(engine stats 2>/dev/null)
        spin_stop
        printf '%s' "$s" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)["stats"]
if not d:
    print("\n  no running instances\n"); raise SystemExit
print()
print("  %-26s %7s %12s %12s %12s" % ("instance", "cpu", "memory", "net in", "net out"))
print("  " + "-" * 74)
def human(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024: return "%.1f %s" % (n, u)
        n /= 1024
    return "%.1f PB" % n
for name, v in sorted(d.items()):
    print("  %-26s %6.1f%% %12s %12s %12s" % (
        name[:26], v["cpu"], "%d/%d MB" % (v["mem_mb"], v["mem_limit_mb"]),
        human(v["rx_total"]), human(v["tx_total"])))
print()
'
        [ -t 0 ] && read -r -p "  press enter " _
        ;;
      *)
        local act
        act=$(menu_choose "$pick" \
          $'open\tShow its links\tlocal and tunnel URLs' \
          $'shell\tOpen a shell in it\tdocker exec' \
          $'tunnel\tOpen or replace the tunnel\tfresh serveo URL' \
          $'untunnel\tDrop the tunnel\tkeep it local only' \
          $'restart\tRestart it\t' \
          $'stop\tStop it\t' \
          $'start\tStart it\t' \
          $'logs\tShow recent logs\tlast 120 lines' \
          $'remove\tRemove it\tasks about the data volume too' \
          $'back\tBack\t') || continue
        case "$act" in
          back|"") : ;;
          open) print_instances ;;
          shell)
            printf '\n'; info "handing you a shell inside $pick, type exit to come back"; printf '\n'
            docker exec -it "$pick" /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash -l; else exec /bin/sh -l; fi'
            ;;
          logs) engine logs "$pick" --tail 120 | sed 's/^/    /' ;;
          remove)
            if confirm "Remove $pick?" n; then
              local purge=""
              confirm "Also delete its saved /config volume?" n && purge="--purge"
              engine do "$pick" remove $purge >/dev/null && ok "removed $pick"
            fi
            ;;
          *)
            spin_start "$act $pick"
            local r; r=$(engine do "$pick" "$act" 2>&1)
            spin_stop
            if printf '%s' "$r" | grep -q '"error"'; then
              bad "$(printf '%s' "$r" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
            else
              ok "$act done"
              printf '%s' "$r" | "$PY" -c '
import json,sys
try:
    t=(json.load(sys.stdin).get("tunnel") or {}).get("url")
    if t: print("    " + t)
except Exception: pass
' 2>/dev/null
            fi
            ;;
        esac
        [ -t 0 ] && read -r -p "  press enter " _
        ;;
    esac
  done
}

# =========================================================================
#  web UI
# =========================================================================

cmd_webui() {
  title "Web UI" "the full catalog, live build output and the instance manager"
  local args=(serve --port "$WEBUI_PORT" --bind "$WEBUI_BIND")
  [ "$WEBUI_EXPOSE" = 1 ] && args+=(--tunnel)

  if [ "$WEBUI_BIND" != "127.0.0.1" ] || [ "$WEBUI_EXPOSE" = 1 ]; then
    warn "this exposes docker control beyond localhost; a token is required in the URL"
  fi

  # Always start it detached, then decide whether to sit on it or hand the
  # shell back. setsid keeps it alive if this script exits.
  local log="$FORGE_LOGS/webui.log"
  : > "$log"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$PY" "$FORGE_APP/engine.py" "${args[@]}" >>"$log" 2>&1 </dev/null &
  else
    nohup "$PY" "$FORGE_APP/engine.py" "${args[@]}" >>"$log" 2>&1 </dev/null &
  fi
  disown 2>/dev/null

  spin_start "starting the engine"
  local info_json="" i=0
  while [ "$i" -lt 900 ]; do
    info_json=$(grep -m1 '^{' "$log" 2>/dev/null)
    [ -n "$info_json" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  spin_stop

  if [ -z "$info_json" ]; then
    bad "the web UI did not start"
    [ -s "$log" ] && sed 's/^/    /' "$log" | tail -12
    return 1
  fi

  local srv_pid srv_url
  srv_pid=$(printf '%s' "$info_json" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["pid"])')
  srv_url=$(printf '%s' "$info_json" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["url"])')

  printf '%s' "$info_json" | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
print()
print("  " + c("1;38;5;79", "▰ WEB UI IS UP"))
print("  " + c("2", "─" * 56))
print("  %s %s" % (c("2", "%-10s" % "local"), c("1;38;5;75", d["url"])))
if d.get("tunnel"):
    print("  %s %s" % (c("2", "%-10s" % "public"), c("1;38;5;75", d["tunnel"])))
if d.get("tunnel_error"):
    print("  %s %s" % (c("2", "%-10s" % "tunnel"), "failed: " + d["tunnel_error"]))
print("  %s %s" % (c("2", "%-10s" % "pid"), d["pid"]))
print()
' FORGE_COLOR=$COLOR

  command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ] && \
    xdg-open "$srv_url" >/dev/null 2>&1 &

  # Background, or hold the terminal until ctrl-c?
  local mode="$WEBUI_MODE"
  if [ -z "$mode" ]; then
    if [ -t 0 ] && [ -r /dev/tty ]; then
      mode=$(menu_choose "Leave it running?" \
        $'bg\tRun it in the background\tyou get your shell back, the UI keeps serving' \
        $'fg\tHold this terminal\tstays in the foreground until ctrl-c') || mode="bg"
    else
      mode="fg"
    fi
  fi

  if [ "$mode" = "bg" ]; then
    printf '\n'
    ok "running in the background as pid $srv_pid"
    info "stop it with:  $0 --stop      (or: kill $srv_pid)"
    info "log:           $log"
    printf '\n'
    return 0
  fi

  printf '\n  %sholding this terminal · ctrl-c stops the web UI%s\n' "$DIM" "$NC"
  printf '  %srunning desktops are not affected%s\n\n' "$DIM" "$NC"
  local stopping=0
  trap 'stopping=1' INT
  while kill -0 "$srv_pid" 2>/dev/null; do
    [ "$stopping" = 1 ] && break
    sleep 1
  done
  trap - INT
  if [ "$stopping" = 1 ]; then
    kill "$srv_pid" 2>/dev/null
    printf '\n'
    ok "web UI stopped"
  else
    warn "the web UI exited on its own, see $log"
  fi
  printf '\n'
}

cmd_stop() {
  local sj="$FORGE_STATE/server.json" pid
  if [ ! -f "$sj" ]; then
    warn "no web UI is recorded as running"
    return 1
  fi
  pid=$("$PY" -c "import json;print(json.load(open('$sj')).get('pid',''))" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    ok "stopped the web UI (pid $pid)"
  else
    warn "the recorded web UI (pid ${pid:-?}) is not running"
  fi
  rm -f "$sj"
  info "running desktops are untouched; use --manager to see them"
}

# =========================================================================
#  doctor / uninstall
# =========================================================================

cmd_doctor() {
  title "This machine" "what the forge checked before offering you anything"
  engine doctor | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
for ch in d["checks"]:
    if ch["ok"]:
        mark = c("38;5;79", "✔")
    elif ch.get("severity") == "info":
        mark = c("38;5;75", "·")
    else:
        mark = c("38;5;221", "!")
    print("  %s %-14s %s" % (mark, ch["name"], ch["detail"]))
    if not ch["ok"] and ch.get("fix") and ch.get("severity") != "info":
        print("    %s" % c("2", "fix: " + ch["fix"]))
h = d["host"]
print()
print("  " + c("2", "%s · %s · %d cores · %d MB free of %d MB · docker %s" % (
    h.get("os_pretty"), h["arch"], h["cpus"], h["mem_avail_mb"], h["mem_total_mb"],
    h.get("docker_version"))))
print()
' FORGE_COLOR=$COLOR
}

cmd_uninstall() {
  title "Uninstall" "removes containers, images and the forge directory"
  warn "this deletes every desktop this forge created"
  confirm "Really remove everything?" n || return 0
  local names
  names=$(docker ps -aq --filter "label=io.selkiesforge.entry" 2>/dev/null)
  if [ -n "$names" ]; then
    spin_start "removing containers"
    docker rm -f $names >/dev/null 2>&1
    spin_stop
    ok "containers removed"
  fi
  if confirm "Also delete the built images and data volumes?" n; then
    spin_start "removing images and volumes"
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^selkies-forge/' | \
      xargs -r docker rmi -f >/dev/null 2>&1
    docker volume ls -q 2>/dev/null | grep '^forge-config-' | xargs -r docker volume rm -f >/dev/null 2>&1
    spin_stop
    ok "images and volumes removed"
  fi
  rm -rf "$FORGE_HOME"
  ok "removed $FORGE_HOME"
  printf '\n  %sthanks for using the forge%s\n\n' "$DIM" "$NC"
}

# =========================================================================
#  main menu
# =========================================================================

main_menu() {
  while :; do
    local running total
    running=$(docker ps -q --filter "label=io.selkiesforge.entry" 2>/dev/null | wc -l | tr -d ' ')
    total=$(engine list --runnable --format tsv 2>/dev/null | wc -l | tr -d ' ')
    printf '\n  %s%s desktops available here · %s running%s\n' "$DIM" "$total" "$running" "$NC"
    local choice
    choice=$(menu_choose "What would you like to do?" \
      $'webui\tOpen the web UI\tthe whole catalog with live output' \
      $'quick\tPick from the hand picked list\tone strong choice per taste' \
      $'family\tBrowse by distro family\tUbuntu, Debian, Arch, Alpine, Kali...' \
      $'search\tSearch the catalog\tby name, desktop or tag' \
      $'smart\tLet it choose for me\tscored against this machine' \
      $'manager\tManage running desktops\tlinks, bandwidth, shells, limits' \
      $'doctor\tCheck this machine\tdocker, memory, disk, tunnels' \
      $'quit\tQuit\t') || return 0
    case "$choice" in
      webui) cmd_webui ;;
      quick) pick_quick ;;
      family) pick_family ;;
      search) pick_search ;;
      smart) cmd_smart ;;
      manager) cmd_manager ;;
      doctor) cmd_doctor ;;
      quit|"") printf '\n  %sbye%s\n\n' "$DIM" "$NC"; return 0 ;;
    esac
  done
}

usage() {
  banner
  sed -n '/^#  Usage:/,/^#  MIT/p' "$0" | sed 's/^#  \{0,1\}//' | head -n -2
  printf '\n'
}

# =========================================================================
#  entry point
# =========================================================================

main() {
  local MODE="menu" LAUNCH_ID=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --webui|-w) MODE="webui" ;;
      --cli|-c) MODE="cli" ;;
      --smart|-s) MODE="smart" ;;
      --manager|-m) MODE="manager" ;;
      --doctor) MODE="doctor" ;;
      --list|-l) MODE="list" ;;
      --launch) MODE="launch"; LAUNCH_ID="${2:-}"; shift ;;
      --uninstall) MODE="uninstall" ;;
      --port) WEBUI_PORT="${2:-8787}"; shift ;;
      --bind) WEBUI_BIND="${2:-127.0.0.1}"; shift ;;
      --expose) WEBUI_EXPOSE=1; WEBUI_BIND="0.0.0.0" ;;
      --bg) MODE="webui"; WEBUI_MODE="bg" ;;
      --fg) MODE="webui"; WEBUI_MODE="fg" ;;
      --stop) MODE="stop" ;;
      --no-tunnel) NO_TUNNEL=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --force-extract) FORCE_EXTRACT=1 ;;
      --version|-V) printf 'selkies-forge %s\n' "$FORGE_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done

  ensure_dirs
  [ "$MODE" = "uninstall" ] || banner

  install_python
  install_docker
  install_extras
  extract_payload

  case "$MODE" in
    stop) cmd_stop; exit $? ;;
    uninstall) cmd_uninstall; exit 0 ;;
    doctor) cmd_doctor; exit 0 ;;
    list) engine list --runnable --format tsv | column -t -s $'\t' 2>/dev/null || engine list --runnable --format tsv; exit 0 ;;
    launch)
      [ -n "$LAUNCH_ID" ] || die "--launch needs a catalog id (see --list)"
      local -a a=()
      [ "$NO_TUNNEL" = 1 ] && a+=(--no-tunnel)
      stream_launch "$LAUNCH_ID" "${a[@]}"
      exit $?
      ;;
  esac

  singleton_check

  case "$MODE" in
    webui) cmd_webui ;;
    cli) pick_quick ;;
    smart) cmd_smart ;;
    manager) cmd_manager ;;
    *) main_menu ;;
  esac
}

main "$@"
