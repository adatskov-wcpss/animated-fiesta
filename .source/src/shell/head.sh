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
#     ./selkies-forge.sh --setup      install everything, then exit
#
#  After the first run, "selkies-cli" brings you back here from any shell:
#     selkies-cli                     home screen: what is running, what next
#     selkies-cli status | start | stop | restart | open | update
#
#  Piped straight from GitHub, pass options after "bash -s --":
#     curl -fsSL <url>/docker.sh | bash -s -- --webui
#     ./selkies-forge.sh --doctor     check this machine
#     ./selkies-forge.sh --uninstall  remove everything it created
#
#  MIT licensed. No telemetry, no accounts, nothing phones home except
#  docker pulls and the serveo tunnel you asked for.

set -uo pipefail

FORGE_VERSION="1.5.0"
FORGE_HOME="${FORGE_HOME:-$HOME/.selkies-forge}"
FORGE_APP="$FORGE_HOME/app"
FORGE_STATE="$FORGE_HOME/state"
FORGE_LOGS="$FORGE_HOME/logs"
FORGE_LOCK="$FORGE_STATE/forge.lock"
PY=""
ASSUME_YES=0
NO_TUNNEL=0
WEBUI_PORT="${FORGE_PORT:-8787}"
WEBUI_PORT_SET=0
WEBUI_BIND="${FORGE_BIND:-127.0.0.1}"
WEBUI_EXPOSE=0
WEBUI_MODE=""
FORGE_FROM_MENU=0
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

# Where answers come from. A piped install (curl ... | bash) has the script
# itself on stdin, so every question has to read the keyboard via /dev/tty.
TTY_IN=""
if [ -t 0 ]; then
  TTY_IN="/dev/stdin"
elif ( : </dev/tty ) 2>/dev/null; then
  TTY_IN="/dev/tty"
fi

# How to run this script again, for the hints it prints. Under "curl | bash"
# $0 is just "bash", so point at the published copy instead.
FORGE_URL="${FORGE_URL:-https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh}"
FORGE_AS_CLI="${FORGE_AS_CLI:-0}"     # 1 when started as the selkies-cli command
CLI_PATH=""
CLI_NEW=0
CLI_RC_ADDED=0
if [ "$FORGE_AS_CLI" = 1 ]; then
  FORGE_RUN="selkies-cli"
elif [ -f "$0" ] && grep -q '^FORGE_VERSION=' "$0" 2>/dev/null; then
  FORGE_RUN="bash $0"
else
  FORGE_RUN="curl -fsSL $FORGE_URL | bash -s --"
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
  if [ -z "$TTY_IN" ]; then printf '%s' "$d"; return; fi
  if [ -n "$d" ]; then
    read -r -p "  $(printf '%s%s%s %s[%s]%s ' "$B" "$p" "$NC" "$DIM" "$d" "$NC")" r <"$TTY_IN"
  else
    read -r -p "  $(printf '%s%s%s ' "$B" "$p" "$NC")" r <"$TTY_IN"
  fi
  printf '%s' "${r:-$d}"
}

confirm() {  # confirm <prompt> <default y|n>
  local p="$1" d="${2:-n}" r
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ -z "$TTY_IN" ]; then [ "$d" = "y" ]; return $?; fi
  read -r -p "  $(printf '%s%s%s %s(%s)%s ' "$B" "$p" "$NC" "$DIM" "$([ "$d" = y ] && echo 'Y/n' || echo 'y/N')" "$NC")" r <"$TTY_IN"
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
  [ -n "$TTY_IN" ] && interactive=1

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

  exec 9<"$TTY_IN" 2>/dev/null || exec 9<&0
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
  command -v git >/dev/null 2>&1 || missing+=(git)
  [ ${#missing[@]} -eq 0 ] && return 0
  detect_pkg || return 0
  need_root || return 0
  title "Extras" "${missing[*]} needed for tunnels, downloads and updates"
  confirm "Install ${missing[*]}?" y || return 0
  local pkgs=()
  for m in "${missing[@]}"; do
    case "$m:$PKG" in
      ssh:apt-get) pkgs+=(openssh-client) ;;
      ssh:apk) pkgs+=(openssh-client) ;;
      ssh:*) pkgs+=(openssh-clients) ;;
      curl:*) pkgs+=(curl) ;;
      git:*) pkgs+=(git) ;;
    esac
  done
  spin_start "installing ${pkgs[*]}"
  pkg_install "${pkgs[@]}" >/dev/null 2>&1
  spin_stop
  ok "extras installed"
}
