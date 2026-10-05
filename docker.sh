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

FORGE_VERSION="1.9.0"
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

# =========================================================================
#  embedded payload: the engine, the web UI and the selkies-cli front end
#  (generated by .source/build.py; edit the files in .source/src instead)
# =========================================================================

FORGE_SHA_ENGINE_PY="c19b7564dcce3fe384ef85e99a7d4dff50f59db2d86a94369363ef0f3074ef0d"
FORGE_SHA_FORGE___INIT___PY="53965ab6fd730187d3ffa29691f6252f97cc368622d0fa536271ba27889cb1e3"
FORGE_SHA_FORGE_BACKUPS_PY="a7dbe4d9d15202209a1526774f2e42c493285cd429409ebd98fe3bc7eaa14003"
FORGE_SHA_FORGE_CATALOG_PY="d1430ab0542c2d023bef41cbb3a36575decd26c833a33083e6f226aea3b8d15c"
FORGE_SHA_FORGE_CLI_PY="889abad218bd5c1c005cbcf744ee77d40ded758da83ce497f6380b8c47a76d1a"
FORGE_SHA_FORGE_DOCTOR_PY="b21dfbda03d710f244312df3283a8988b40d4ac2ab4c48ed252f3c3d7a839210"
FORGE_SHA_FORGE_EVENTS_PY="3580b5654e071cb6e59f44c90dcfec9f5ea5d53358190e12722bf6017c497712"
FORGE_SHA_FORGE_GPU_PY="18d779546907e20d334ca27f331d926c33b480b16c560d4ba265b55e0aca4cb3"
FORGE_SHA_FORGE_HEALTH_PY="ee292cbf761b40ae09b5a7689ff4b5dd6699d5ba6147a7d0dabdbda0ca94788f"
FORGE_SHA_FORGE_HOST_PY="3cc811b6ed8e8bf76402250d320dd8e0f91315b8ba8f1a1aaeb75184c1382116"
FORGE_SHA_FORGE_IMAGES_PY="dc8a0d7f70e43494b1d0e99101c233b92691da41e2c03163214021a64d4fb1a5"
FORGE_SHA_FORGE_INFO_PY="2c7e4c6fb531f111288902458f75491629b546de65301c9613dda0fd5eb3564f"
FORGE_SHA_FORGE_JOBS_PY="a78f564dadd53f11560bea39907245a2332f9c35402bc1ebe92dd364a1214c86"
FORGE_SHA_FORGE_LAUNCH_PY="c6eabb9c8db7236c12c2ff05fff228430441c92d7bc23d617af83b0031e53c5a"
FORGE_SHA_FORGE_LAYER_PY="b804c7ad977d4172ae30077759d94b69ec02c4ab250e372c87df66b860bbe276"
FORGE_SHA_FORGE_LEDGER_PY="56dc82d992d89020ddc2e8a2e0df43b8fc9db160c058f6d180188e745ae45fa6"
FORGE_SHA_FORGE_LIFECYCLE_PY="32da83d5c07d9f795702a45c9a6c2cabbb4a6974cf6045905f123b0418e7dd9f"
FORGE_SHA_FORGE_PATHS_PY="58e72798465e7b4f9a8b904dedf96edaa5b317f235fd33881e13b90be57344d9"
FORGE_SHA_FORGE_PORTS_PY="b6643ed366d355e7ec4825102296af97de25cfd62bb1532598067703b06a870c"
FORGE_SHA_FORGE_RECIPES_PY="a39d52d1a2ab541784102aa9ad1c505c3dfce2842b9dd94d999710ca1ce4e40a"
FORGE_SHA_FORGE_REGISTRY_PY="fcbd775bec6d7dcfdde38ba55f675443e307576140cff75e9fe6c53ed02b780b"
FORGE_SHA_FORGE_RUNNER_PY="65d10364866e5ebf7d409c2113e2e9708337b04ef8555a0bf92ab54ac14c267c"
FORGE_SHA_FORGE_SCHEDULER_PY="1eecd9e5cc6cce999fa55eb6330710d68ef43b0f6ba711bd9050d93c32025a37"
FORGE_SHA_FORGE_SERVER_PY="dad7198e18ae93366dda0ac12583bdacb6c108aba3c1c65d839cfc32467662cd"
FORGE_SHA_FORGE_SMART_PY="938528e24012ad5cc524d07a8bf029c11796f9a04f919a7d6fbf64ef305a6c76"
FORGE_SHA_FORGE_SPACE_PY="370c18a74bea1396490ff8a8654f947572e500aa15b2463179630339ace9a37a"
FORGE_SHA_FORGE_STATS_PY="342e01783512fed766e667e13b3a3acf28ec53ac8395bf96e180b93f749e8fcc"
FORGE_SHA_FORGE_STORE_PY="ff80f149c72bcb9bae180695a7f45c124caeca4fb4e6d7e4fc0bcb4d61c35e03"
FORGE_SHA_FORGE_TERMINAL_PY="befcf471ac7032b93bb187cc51159667ab9cf5531251938cc92b415a27f72556"
FORGE_SHA_FORGE_TUNNELS_PY="e2758607ff12b385f51d78a8469eb21ccbaba7312afe5091c69fdbc0869f30db"
FORGE_SHA_FORGE_UPDATES_PY="0e13cce414f7b6b85847eff0849152576f6d6b3ba78e1eec97f2603212e511a5"
FORGE_SHA_FORGE_UTIL_PY="11a06e6537ba2417f08ceb9dc2c833915b3e1d2029dae7442c92768ebb12d5a7"
FORGE_SHA_FORGE_WATCHDOG_PY="27dc5c8016adeb4ee1ead130bab53ad80a883f9bf8fd8b7cfb794c7fe3a43e1a"
FORGE_SHA_FORGE_WEBUI_PY="b2ecf5efadf820b9063246e1019d1504181b71b53fc2ef11660b2d8eac2af154"
FORGE_SHA_WEB_APP_CSS="cde7b0533be9734bfd18d55989987ddb598754dd3bfbf4df0da985dcb3b3061d"
FORGE_SHA_WEB_APP_JS="c701d32d3d84984a15afad0d3576ece1cc7717535c4dff7cf2c172376809d914"
FORGE_SHA_WEB_BRANDS_JS="41940af3caeb272b1ba91030ffece7783bdd9ed7eb83f193d1d39f10d5ecca5f"
FORGE_SHA_WEB_INDEX_HTML="f830edb32b2fb69a6918064d08bc2cfe33949dba14c4960a789372e203e1e409"
FORGE_SHA_WEB_LOGOS_JS="cda14786865a4c35fc30c8a3fe90d1ac945966219c9003fc081414ea12a07fb7"
FORGE_SHA_WEB_TERM_JS="4562ca565db85e10c43c0ca7c7cf33f3726acb2f5b2b1e92f29d6137f7c99e41"
FORGE_SHA_DATA_INFO_JSON="e49d544627545e1bd1acedddbd5cc3c4932772499efce9da438bb28af9ff9055"
FORGE_SHA_DATA_SHOTS_JSON="a35b5ab6f311598ba0bf3c350310f60d6cae734af51bf7bc0a2223aee5cfe880"
FORGE_SHA_SELKIES_CLI="5bbdf8a58e82de48bf804adf289d5845dd6ba780c310e610aa8da4f8c5020b7a"
FORGE_PAYLOAD_SHA="c9a00e58c53e152e592187e4a3750b659bd9e3c5271a5af098d3ef5f6717558e"
FORGE_PAYLOAD_FILES="engine.py forge/__init__.py forge/backups.py forge/catalog.py forge/cli.py forge/doctor.py forge/events.py forge/gpu.py forge/health.py forge/host.py forge/images.py forge/info.py forge/jobs.py forge/launch.py forge/layer.py forge/ledger.py forge/lifecycle.py forge/paths.py forge/ports.py forge/recipes.py forge/registry.py forge/runner.py forge/scheduler.py forge/server.py forge/smart.py forge/space.py forge/stats.py forge/store.py forge/terminal.py forge/tunnels.py forge/updates.py forge/util.py forge/watchdog.py forge/webui.py web/app.css web/app.js web/brands.js web/index.html web/logos.js web/term.js data/info.json data/shots.json selkies-cli"

# Writes the engine and UI into $FORGE_APP, but only when they changed.
extract_payload() {
  local stamp="$FORGE_APP/.payload"
  if [ "${FORCE_EXTRACT:-0}" != "1" ] && [ -f "$stamp" ] && \
     [ "$(cat "$stamp" 2>/dev/null)" = "$FORGE_PAYLOAD_SHA" ]; then
    return 0
  fi
  mkdir -p "$FORGE_APP/forge" "$FORGE_APP/web" "$FORGE_APP/data"
  cat > "$FORGE_APP/engine.py" <<'__FORGE_FILE_ENGINE_PY__'
#!/usr/bin/env python3
"""
Selkies Forge engine - entry point.

The engine is the `forge` package next to this file. This script only puts
that package on the path and hands the command line to forge.cli.main().
`selkies-cli` (and the web UI) call it as:

    python3 engine.py serve --port 8787          the web UI
    python3 engine.py launch <id> [options]      forge one desktop, streaming events
    python3 engine.py status | doctor | list ... everything else (see --help)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from forge.cli import main  # noqa: E402

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
__FORGE_FILE_ENGINE_PY__
  cat > "$FORGE_APP/forge/__init__.py" <<'__FORGE_FILE_FORGE___INIT___PY__'
"""
Selkies Forge - the engine.

Launches Linux desktops in Docker and streams them to a browser through
Selkies. See docs/engine.md for how the pieces fit together; engine.py next to
this package is the command-line entry point.
"""

from .paths import VERSION

__all__ = ["VERSION"]
__FORGE_FILE_FORGE___INIT___PY__
  cat > "$FORGE_APP/forge/backups.py" <<'__FORGE_FILE_FORGE_BACKUPS_PY__'
"""
Selkies Forge engine - backups

A desktop's files live in its /config volume. This module copies them out
(backup), puts a copy back (restore), and starts a second desktop from a copy
(clone).

  backup   tar.gz of the volume in FORGE_HOME/backups/, plus a .json note:
           which desktop, which catalog entry, its limits and options, so a
           backup can become a desktop again even after the original is gone.
           Caches (~/.cache) are left out unless asked for; they are large
           and rebuild themselves.
  restore  replaces a desktop's files with a backup's. A safety backup of the
           current files is taken first, so a restore can itself be undone.
           A running desktop is stopped for the swap and started again.
  clone    copies a desktop's files into a new volume and launches the same
           catalog entry on it, with the same limits and options: a second,
           independent desktop with everything the first had.

Every container used for this is the desktop's own image (already on this
machine, so nothing is downloaded) with tar or cp as its entrypoint. The
archive streams through this process, so it is owned by you, not root.
"""

import json
import os
import re
import subprocess
import time

from . import catalog, events
from .jobs import Job, job_put
from .lifecycle import instance_action
from .paths import BACKUPDIR, CPREFIX, LABEL
from .runner import container_name_for
from .store import reg_load
from .util import ensure_dirs, human_mb, run, slug

SAFE_FILE = re.compile(r"^[A-Za-z0-9_.-]+\.tar\.gz$")


def _inspect(name):
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad desktop name")
    rc, out, err = run(["docker", "inspect", name], timeout=40)
    if rc != 0:
        raise RuntimeError("no such desktop: %s" % name)
    c = json.loads(out)[0]
    labels = (c.get("Config") or {}).get("Labels") or {}
    vol = labels.get("%s.volume" % LABEL)
    if not vol:
        raise RuntimeError("%s has no forge volume to back up" % name)
    return c, labels, vol


def _helper(image, *docker_args):
    """`docker run` of the desktop's own image as a one-shot file tool."""
    return ["docker", "run", "--rm", "--network", "none"] + list(docker_args) + [image]


def _meta_for(name, c, labels, vol):
    hostcfg = c.get("HostConfig") or {}
    note = reg_load().get(name) or {}
    return {
        "name": name, "entry_id": labels.get("%s.entry" % LABEL),
        "title": labels.get("%s.title" % LABEL), "volume": vol,
        "display": labels.get("%s.display" % LABEL), "forge_version": labels.get("%s.version" % LABEL),
        "image": (c.get("Config") or {}).get("Image"),
        "limits": {"memory_mb": int((hostcfg.get("Memory") or 0) / 1048576) or None,
                   "cpus": round((hostcfg.get("NanoCpus") or 0) / 1e9, 2) or None,
                   "shm_mb": int((hostcfg.get("ShmSize") or 0) / 1048576) or None,
                   "disk_mb": note.get("plan", {}).get("disk_mb")},
        "opts": {k: v for k, v in (note.get("opts") or {}).items()
                 if k in ("display", "resolution", "gpu", "seccomp_unconfined", "heal", "locale")},
    }


def backup(name, include_cache=False, job=None, tag=None):
    """Write a backup of a desktop's files. Returns the backup's note."""
    job = job or job_put(Job("backup", name, "Back up %s" % name))
    c, labels, vol = _inspect(name)
    ensure_dirs()
    os.makedirs(BACKUPDIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = "%s-%s%s" % (slug(name), stamp, "-" + slug(tag) if tag else "")
    path = os.path.join(BACKUPDIR, base + ".tar.gz")
    image = (c.get("Config") or {}).get("Image")
    job.set_phase("backup", "Backing up %s" % name, 0.05)
    job.log("backup   : %s (volume %s) -> %s" % (name, vol, path))
    if (c.get("State") or {}).get("Running"):
        job.log("note     : it is running; files being written right now may be caught "
                "half-way (stop it first for a perfectly still copy)")
    excl = [] if include_cache else ["--exclude=./.cache"]
    cmd = _helper(image, "-v", "%s:/v:ro" % vol, "--entrypoint", "tar") + \
        ["-czf", "-", "-C", "/v"] + excl + ["."]
    tmp = path + ".part"
    t0 = time.time()
    with open(tmp, "wb") as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.PIPE, start_new_session=True)
        job.attach(p)
        try:
            while p.poll() is None:
                time.sleep(1.0)
                job.check()
                job.set_progress(min(0.9, 0.05 + (time.time() - t0) / 600.0),
                                 {"bytes": os.path.getsize(tmp)})
        finally:
            job.detach(p)
        err = p.stderr.read().decode("utf-8", "replace")
    # GNU tar exits 1 when a file changed while it was read: still a good backup.
    if p.returncode not in (0, 1) or os.path.getsize(tmp) < 20:
        os.remove(tmp)
        raise RuntimeError("the backup failed (tar exit %s): %s" % (p.returncode, err.strip()[-300:]))
    os.replace(tmp, path)
    meta = _meta_for(name, c, labels, vol)
    meta.update({"file": os.path.basename(path), "created": time.time(),
                 "size": os.path.getsize(path), "include_cache": bool(include_cache),
                 "tag": tag})
    with open(path[:-len(".tar.gz")] + ".json", "w") as fh:
        json.dump(meta, fh, indent=2)
    events.record(name, "backup", "%s (%s)" % (meta["file"], human_mb(meta["size"] / 1048576.0)))
    job.log("backup   : done, %s in %ds" % (human_mb(meta["size"] / 1048576.0), time.time() - t0))
    job.finish({"backup": meta, "file": meta["file"], "size": meta["size"], "name": name})
    return meta


def list_backups(name=None):
    try:
        files = sorted(f for f in os.listdir(BACKUPDIR) if f.endswith(".json"))
    except OSError:
        return []
    out = []
    for f in files:
        try:
            with open(os.path.join(BACKUPDIR, f)) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        if not os.path.exists(os.path.join(BACKUPDIR, meta.get("file") or "")):
            continue
        if name and meta.get("name") != name:
            continue
        out.append(meta)
    out.sort(key=lambda m: m.get("created") or 0, reverse=True)
    return out


def _backup_path(file):
    if not SAFE_FILE.match(file or ""):
        raise RuntimeError("bad backup file name")
    path = os.path.join(BACKUPDIR, file)
    if not os.path.exists(path):
        raise RuntimeError("no such backup: %s" % file)
    return path


def delete_backup(file):
    path = _backup_path(file)
    os.remove(path)
    try:
        os.remove(path[:-len(".tar.gz")] + ".json")
    except OSError:
        pass
    return {"deleted": file}


def restore(name, file, job=None):
    """Replace a desktop's files with a backup's (after a safety backup)."""
    job = job or job_put(Job("restore", name, "Restore %s" % name))
    path = _backup_path(file)
    c, labels, vol = _inspect(name)
    image = (c.get("Config") or {}).get("Image")
    was_running = bool((c.get("State") or {}).get("Running"))
    job.set_phase("safety", "Saving the current files first", 0.05)
    safety = backup(name, job=Job("backup", name, "Safety backup"), tag="before-restore")
    job.log("safety   : current files saved as %s" % safety["file"])
    job.check()
    if was_running:
        job.set_phase("stop", "Stopping %s for the swap" % name, 0.4)
        events.record(name, "backup-restore", "restoring %s" % file)
        instance_action(name, "stop")
    job.set_phase("restore", "Restoring %s" % file, 0.5)
    cmd = _helper(image, "-i", "-v", "%s:/v" % vol, "--entrypoint", "sh") + \
        ["-c", "find /v -mindepth 1 -delete && tar -xzf - -C /v"]
    with open(path, "rb") as fh:
        p = subprocess.run(cmd, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=3600)
    if p.returncode != 0:
        raise RuntimeError("the restore failed: %s (your files before the restore are in %s)"
                           % (p.stderr.decode("utf-8", "replace").strip()[-300:], safety["file"]))
    events.record(name, "restored", "files replaced from %s (previous files: %s)"
                  % (file, safety["file"]))
    if was_running:
        job.set_phase("start", "Starting %s again" % name, 0.9)
        instance_action(name, "start")
    job.log("restore  : done; the files from before are in %s" % safety["file"])
    job.finish({"name": name, "file": file, "safety": safety["file"]})
    return {"name": name, "file": file, "safety": safety["file"]}


def clone(name, new_name=None, job=None, tunnel=False, from_backup=None):
    """A second desktop with a copy of a desktop's files (or of a backup's).

    `name` is the desktop to copy; with `from_backup` it may be gone, and the
    backup's note says which catalog entry and limits to use.
    """
    from .launch import launch                      # launch imports lifecycle
    from .host import host_info
    from .smart import plan_resources
    meta = None
    if from_backup:
        path = _backup_path(from_backup)
        with open(path[:-len(".tar.gz")] + ".json") as fh:
            meta = json.load(fh)
        src_c = None
        entry_id = meta.get("entry_id")
        base_name = new_name or "%s-copy" % (meta.get("name") or "desktop").replace(CPREFIX, "", 1)
    else:
        src_c, labels, src_vol = _inspect(name)
        meta = _meta_for(name, src_c, labels, src_vol)
        entry_id = meta["entry_id"]
        base_name = new_name or "%s-copy" % name.replace(CPREFIX, "", 1)
    entry = catalog.BY_ID.get(entry_id)
    if not entry:
        raise RuntimeError("that desktop's catalog entry (%s) is not in this version" % entry_id)
    job = job or job_put(Job("clone", entry_id, "Clone %s" % (name or from_backup)))
    cname = container_name_for(entry, base_name)
    vol = "%sconfig-%s" % (CPREFIX, slug(cname))
    if run(["docker", "volume", "inspect", vol], timeout=20)[0] == 0:
        raise RuntimeError("a volume named %s already exists (files of a removed desktop); "
                           "pick another name" % vol)
    job.note(container=cname, volume=vol)
    job.set_phase("copy", "Copying the files", 0.02)
    run(["docker", "volume", "create", "--label", "%s.clone-of=%s" % (LABEL, name or from_backup),
         vol], timeout=30)
    if from_backup:
        image = meta.get("image")
        if not image or run(["docker", "image", "inspect", image], timeout=20)[0] != 0:
            image = entry["image"] if entry["kind"] == "pull" else None
        if not image or run(["docker", "image", "inspect", image], timeout=20)[0] != 0:
            image = "busybox"
        cmd = _helper(image, "-i", "-v", "%s:/v" % vol, "--entrypoint", "tar") + \
            ["-xzf", "-", "-C", "/v"]
        with open(_backup_path(from_backup), "rb") as fh:
            p = subprocess.run(cmd, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=3600)
    else:
        image = (src_c.get("Config") or {}).get("Image")
        cmd = _helper(image, "-v", "%s:/s:ro" % src_vol, "-v", "%s:/d" % vol,
                      "--entrypoint", "cp") + ["-a", "/s/.", "/d/"]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3600)
    if p.returncode != 0:
        run(["docker", "volume", "rm", "-f", vol], timeout=60)
        raise RuntimeError("copying the files failed: %s"
                           % p.stderr.decode("utf-8", "replace").strip()[-300:])
    job.log("copy     : files copied into %s" % vol)
    job.check()
    host = host_info(fresh=True)
    plan = plan_resources(entry, host)
    for k in ("memory_mb", "cpus", "shm_mb", "disk_mb"):
        if (meta.get("limits") or {}).get(k):
            plan[k] = meta["limits"][k]
    opts = dict(meta.get("opts") or {})
    opts.update({"tunnel": bool(tunnel), "prepared_volume": True})
    res = launch(entry_id, plan, opts, job=job, name=cname[len(CPREFIX):])
    events.record(res["name"], "cloned", "from %s" % (name or from_backup))
    return res
__FORGE_FILE_FORGE_BACKUPS_PY__
  cat > "$FORGE_APP/forge/catalog.py" <<'__FORGE_FILE_FORGE_CATALOG_PY__'
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
__FORGE_FILE_FORGE_CATALOG_PY__
  cat > "$FORGE_APP/forge/cli.py" <<'__FORGE_FILE_FORGE_CLI_PY__'
"""
Selkies Forge engine - cli

The engine's command line (what selkies-cli calls under the hood).
"""

import argparse
import json
import sys
import threading
import time

from . import backups, catalog, events, scheduler, space
from .watchdog import Watchdog, reconcile, recover_interrupted
from .doctor import cli_doctor
from .health import container_logs
from .host import host_info
from .info import public_entry
from .jobs import Job, all_jobs, job_put
from .launch import launch
from .lifecycle import instance_action, reconfigure, set_idle
from .paths import VERSION
from .recipes import gen_dockerfile
from .registry import docker_instances
from .server import serve
from .smart import PURPOSE_TAGS, TASTES, plan_resources, recommend
from .stats import STATS
from .updates import check_update
from .util import ensure_dirs, human
from .webui import (
    boot_disable,
    boot_enable,
    boot_mark_asked,
    boot_report,
    dismiss_last_stop,
    forge_status,
    last_stop_report,
    request_stop,
)


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
    opts = {"tunnel": not args.no_tunnel, "name": args.name, "autostart": args.autostart,
            "gpu": args.gpu, "gpu_device": args.gpu_device, "seccomp_unconfined": args.seccomp,
            "display": args.display, "resolution": args.resolution,
            "health_timeout": args.timeout, "force": args.force,
            "dry_run": args.dry_run}
    if args.idle_stop is not None:
        opts["idle_stop"] = args.idle_stop
    if args.user and args.password:
        opts["username"], opts["password"] = args.user, args.password
    if args.subdomain:
        opts["subdomain"] = args.subdomain

    job = job_put(Job("launch", args.id, entry["name"]))
    return stream_job(job, lambda: launch(args.id, plan, opts, job=job, name=args.name))


def cli_gpu(a):
    """`engine.py gpu [--image IMG]`: the detection report, and optionally the
    plan a launch of IMG would get (running the in-image check)."""
    from . import gpu
    rep = gpu.report(fresh=True)
    out = {"host": rep["host"]}
    if a.image:
        g = gpu.pick(rep["host"])
        if g and a.fresh:
            gpu.verify(a.image, g, rep["host"], fresh=True)
        out["plan"] = gpu.plan("auto", a.image, rep=rep["host"])
    if a.json:
        print(json.dumps(out, indent=2, default=str))
        return 0
    print(rep["text"])
    if a.image:
        p = out["plan"]
        print("")
        print("  %s  ->  %s" % (a.image, p["label"]))
        for n in p["notes"]:
            print("    - %s" % n)
        bits = gpu.docker_bits(p)
        if bits:
            print("    docker run ... %s" % gpu.shell_quote_args(bits))
    return 0


def stream_job(job, work_fn):
    """Run work_fn in a thread and print the job's events as lines the shell
    front end renders: P progress, L log, E error, H hint, D result JSON.
    Ctrl-C (or SIGINT from the web UI's cancel) cancels the job properly."""
    done = {"result": None, "error": None}

    def work():
        try:
            done["result"] = work_fn()
        except Exception as ex:
            done["error"] = str(ex)
            if job.status == "running":
                job.fail(str(ex))

    th = threading.Thread(target=work, daemon=True)
    th.start()

    cursor = 0
    print("P 0 start Preparing")
    sys.stdout.flush()
    interrupted = False
    while True:
        try:
            evs = job.since(cursor, timeout=2.0)
        except KeyboardInterrupt:
            # Ctrl-C cancels the launch properly: kill the pull/build, remove
            # the half-made desktop, then report like any other ending.
            if interrupted:
                raise
            interrupted = True
            job.cancel()
            continue
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
                elif extra.get("bytes"):
                    note = " %s" % human(extra["bytes"])
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
    th.join(timeout=30)
    return 0 if done["result"] else (130 if job.cancelled else 1)


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
    p = sub.add_parser("gpu", help="GPU Smart Passthrough: what this machine has, and what a "
                                   "desktop image would get")
    p.add_argument("--image", help="also check this image (as a launch would)")
    p.add_argument("--json", action="store_true")
    p.add_argument("--fresh", action="store_true", help="re-run the image check")
    sub.add_parser("status")
    p = sub.add_parser("boot")
    p.add_argument("action", choices=["status", "enable", "disable", "asked"])
    p.add_argument("--port", type=int, default=8787)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--expose", action="store_true")
    p.add_argument("--no-linger", action="store_true")
    p = sub.add_parser("stop-request")
    p.add_argument("reason")
    sub.add_parser("last-stop")
    sub.add_parser("dismiss-last-stop")
    p = sub.add_parser("restore")
    p.add_argument("names", nargs="*")
    p = sub.add_parser("check-update")
    p.add_argument("--install", action="store_true")
    p.add_argument("--max-age", type=int, default=0)
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
    p.add_argument("--gpu", nargs="?", const="auto", default="auto", choices=["auto", "on", "off"],
                   help="GPU Smart Passthrough: auto (default) uses what is checked to work, "
                        "on forces the GPU in, off keeps it out")
    p.add_argument("--no-gpu", dest="gpu", action="store_const", const="off")
    p.add_argument("--gpu-device", help="which GPU: a render node, its index, a driver or a vendor")
    p.add_argument("--seccomp", action="store_true")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--autostart", action="store_true",
                   help="start this desktop again whenever Docker starts")
    p.add_argument("--force", action="store_true",
                   help="start even if the machine looks short of memory")
    p.add_argument("--display", default="auto", choices=["auto", "fit", "fixed"],
                   help="fit: follow the browser window (4K screens are scaled "
                        "from a ~1920-wide desktop); fixed: one size, scaled")
    p.add_argument("--resolution", default="1920x1080", help="size for --display fixed")
    p.add_argument("--dry-run", action="store_true",
                   help="check everything and show what would happen, without doing it")
    p.add_argument("--idle-stop", type=int, metavar="MIN",
                   help="stop it after MIN minutes with nobody watching (0: never)")

    p = sub.add_parser("jobs", help="every launch, backup and clone on this machine")
    p.add_argument("--json", action="store_true")
    sub.add_parser("recover", help="clean up after launches whose process died")

    p = sub.add_parser("idle", help="stop a desktop after MIN minutes unwatched")
    p.add_argument("name")
    p.add_argument("minutes", help="minutes, 0 for never, or default")

    p = sub.add_parser("backup", help="back up a desktop's files")
    p.add_argument("name")
    p.add_argument("--with-cache", action="store_true", help="include ~/.cache too")
    p = sub.add_parser("backups", help="list backups")
    p.add_argument("--name")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("restore-backup", help="replace a desktop's files with a backup's")
    p.add_argument("name")
    p.add_argument("file")
    p = sub.add_parser("delete-backup")
    p.add_argument("file")
    p = sub.add_parser("clone", help="a new desktop with a copy of another's files")
    p.add_argument("name", nargs="?")
    p.add_argument("--as", dest="new_name", help="name for the new desktop")
    p.add_argument("--from-backup", metavar="FILE", help="start it from a backup instead")
    p.add_argument("--tunnel", action="store_true", help="also open a public link")

    p = sub.add_parser("do")
    p.add_argument("name")
    p.add_argument("action", choices=["start", "stop", "restart", "remove",
                                      "tunnel", "untunnel", "repair"])
    p.add_argument("--purge", action="store_true")
    p.add_argument("--subdomain")

    p = sub.add_parser("retune")
    p.add_argument("name")
    p.add_argument("--memory", type=int)
    p.add_argument("--cpus", type=float)
    p.add_argument("--shm", type=int)
    p.add_argument("--disk", type=int)
    p.add_argument("--autostart", choices=["on", "off"])

    p = sub.add_parser("events", help="the event journal (crashes, heals, repairs, launches)")
    p.add_argument("--name")
    p.add_argument("--limit", type=int, default=40)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("space", help="what the forge uses on disk; --clean to free it")
    p.add_argument("--clean", action="store_true")
    p.add_argument("--all", action="store_true", help="also unused desktop images and build cache")
    p.add_argument("--volumes", action="store_true", help="also orphaned /config volumes")
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("watchdog", help="watch desktops: crashes, healing, session health")
    p.add_argument("--once", action="store_true", help="one pass, print what it found")
    sub.add_parser("reconcile", help="drop records of desktops that no longer exist")
    sub.add_parser("scheduler", help="build/pull/boot slots in use")

    p = sub.add_parser("logs")
    p.add_argument("name")
    p.add_argument("--tail", type=int, default=200)

    a = ap.parse_args(argv)
    ensure_dirs()

    if a.cmd == "serve":
        serve(a.bind, a.port, a.tunnel, a.quiet)
        return 0
    if a.cmd == "check-update":
        print(json.dumps(check_update(install=a.install, max_age=a.max_age, timeout=12)))
        return 0
    if a.cmd == "status":
        print(json.dumps(forge_status()))
        return 0
    if a.cmd == "boot":
        try:
            if a.action == "enable":
                out = boot_enable(a.port, a.bind, a.expose, try_linger=not a.no_linger)
            elif a.action == "disable":
                out = boot_disable()
            elif a.action == "asked":
                out = boot_mark_asked()
            else:
                out = boot_report()
        except Exception as ex:
            out = {"ok": False, "error": str(ex)}
        print(json.dumps(out))
        return 0 if out.get("ok", True) else 1
    if a.cmd == "stop-request":
        print(json.dumps(request_stop(a.reason)))
        return 0
    if a.cmd == "last-stop":
        print(json.dumps(last_stop_report()))
        return 0
    if a.cmd == "dismiss-last-stop":
        print(json.dumps(dismiss_last_stop()))
        return 0
    if a.cmd == "restore":
        names = a.names or (last_stop_report() or {}).get("restore") or []
        done = []
        for n in names:
            try:
                instance_action(n, "start")
                done.append(n)
            except Exception as ex:
                print(json.dumps({"name": n, "error": str(ex)}), file=sys.stderr)
        dismiss_last_stop()
        print(json.dumps({"started": done}))
        return 0
    if a.cmd == "host":
        print(json.dumps(host_info(fresh=True), indent=2))
        return 0
    if a.cmd == "gpu":
        return cli_gpu(a)
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
    if a.cmd == "jobs":
        rows = all_jobs()
        if a.json:
            print(json.dumps({"jobs": rows}))
        else:
            for j in rows:
                print("%s  %-8s %-12s %-11s %3d%%  %s" % (
                    time.strftime("%m-%d %H:%M", time.localtime(j.get("created") or 0)),
                    j.get("kind", ""), j.get("status", ""), (j.get("phase") or "")[:11],
                    int((j.get("progress") or 0) * 100), j.get("title") or ""))
        return 0
    if a.cmd == "recover":
        print(json.dumps({"recovered": recover_interrupted()}))
        return 0
    if a.cmd == "idle":
        mins = None if a.minutes == "default" else int(a.minutes)
        try:
            print(json.dumps(set_idle(a.name, mins)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "backup":
        job = job_put(Job("backup", a.name, "Back up %s" % a.name))
        return stream_job(job, lambda: backups.backup(a.name, include_cache=a.with_cache, job=job))
    if a.cmd == "backups":
        rows = backups.list_backups(a.name)
        if a.json:
            print(json.dumps({"backups": rows}))
        else:
            for b in rows:
                print("%s  %-26s %9s  %s" % (
                    time.strftime("%Y-%m-%d %H:%M", time.localtime(b.get("created") or 0)),
                    (b.get("name") or "")[:26], human(b.get("size") or 0), b.get("file")))
        return 0
    if a.cmd == "restore-backup":
        job = job_put(Job("restore", a.name, "Restore %s" % a.name))
        return stream_job(job, lambda: backups.restore(a.name, a.file, job=job))
    if a.cmd == "delete-backup":
        try:
            print(json.dumps(backups.delete_backup(a.file)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "clone":
        if not a.name and not a.from_backup:
            print("E name a desktop to clone, or --from-backup FILE")
            return 2
        job = job_put(Job("clone", a.name, "Clone %s" % (a.name or a.from_backup)))
        return stream_job(job, lambda: backups.clone(a.name, new_name=a.new_name, job=job,
                                                     tunnel=a.tunnel, from_backup=a.from_backup))
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
            auto = None if a.autostart is None else (a.autostart == "on")
            print(json.dumps(reconfigure(a.name, a.memory, a.cpus, a.shm, a.disk, auto)))
            return 0
        except Exception as ex:
            print(json.dumps({"error": str(ex)}))
            return 1
    if a.cmd == "events":
        rows = events.recent(a.name, limit=a.limit)
        if a.json:
            print(json.dumps({"events": rows}))
        else:
            for r in rows:
                print("%s  %-26s %-16s %s" % (time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"])),
                                               r.get("name", "")[:26], r.get("event", ""),
                                               (r.get("detail") or "").replace("\n", " ")[:90]))
        return 0
    if a.cmd == "space":
        if a.clean:
            print(json.dumps(space.clean(everything=a.all, volumes=a.volumes, dry_run=a.dry_run)))
        else:
            print(json.dumps(space.report()))
        return 0
    if a.cmd == "watchdog":
        if a.once:
            wd = Watchdog()
            wd.tick()
            time.sleep(1)
            print(json.dumps(wd.tick()))
            return 0
        wd = Watchdog()
        try:
            while True:
                rep = wd.tick()
                if any(rep.get(k) for k in ("crashed", "healed", "rescue")):
                    print(json.dumps(rep))
                    sys.stdout.flush()
                time.sleep(wd.interval)
        except KeyboardInterrupt:
            return 0
    if a.cmd == "reconcile":
        print(json.dumps(reconcile()))
        return 0
    if a.cmd == "scheduler":
        print(json.dumps(scheduler.status()))
        return 0
    if a.cmd == "logs":
        print(container_logs(a.name, a.tail))
        return 0
    return 1
__FORGE_FILE_FORGE_CLI_PY__
  cat > "$FORGE_APP/forge/doctor.py" <<'__FORGE_FILE_FORGE_DOCTOR_PY__'
"""
Selkies Forge engine - doctor

Checks of this machine, for `selkies-cli doctor` and the web UI.
"""

import socket
import sys

from . import catalog
from .host import docker_ok, host_info
from .util import have, human_mb


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
__FORGE_FILE_FORGE_DOCTOR_PY__
  cat > "$FORGE_APP/forge/events.py" <<'__FORGE_FILE_FORGE_EVENTS_PY__'
"""
Selkies Forge engine - events

An append-only journal of what happened to each desktop: created, started,
stopped, crashed, healed, repaired, a fix applied during launch. It is how the
watchdog tells "you stopped it" from "it crashed", and what the manager shows
under a desktop's logs.

One JSON object per line in state/events.jsonl, trimmed when it grows large.
"""

import json
import os
import time

from .paths import EVENTS_JSONL
from .util import FileLock, ensure_dirs

MAX_BYTES = 2 * 1024 * 1024
KEEP_LINES = 4000

# Events that mean a person (or the forge, on their behalf) stopped a desktop
# on purpose. The watchdog never treats a stop after one of these as a crash.
DELIBERATE = {"stop", "restart", "remove", "repair", "recreate", "retune", "launch-cancelled",
              "launch-failed", "user-stop", "idle-stop", "pressure-stop", "backup-restore"}


def record(name, event, detail="", **extra):
    """Append one event. Never raises: the journal must not break real work."""
    try:
        ensure_dirs()
        row = {"ts": round(time.time(), 3), "name": name, "event": event}
        if detail:
            row["detail"] = str(detail)[:2000]
        row.update({k: v for k, v in extra.items() if v is not None})
        line = json.dumps(row, sort_keys=True) + "\n"
        with FileLock("events", timeout=10):
            with open(EVENTS_JSONL, "a") as fh:
                fh.write(line)
            if os.path.getsize(EVENTS_JSONL) > MAX_BYTES:
                _trim()
    except Exception:
        pass


def _trim():
    with open(EVENTS_JSONL) as fh:
        lines = fh.readlines()[-KEEP_LINES:]
    tmp = EVENTS_JSONL + ".tmp"
    with open(tmp, "w") as fh:
        fh.writelines(lines)
    os.replace(tmp, EVENTS_JSONL)


def recent(name=None, limit=100, since=0.0, kinds=None):
    """Newest last. Filter by desktop name, time and event kinds."""
    out = []
    try:
        with open(EVENTS_JSONL) as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if name and row.get("name") != name:
                    continue
                if since and row.get("ts", 0) < since:
                    continue
                if kinds and row.get("event") not in kinds:
                    continue
                out.append(row)
    except OSError:
        return []
    return out[-limit:]


def last_deliberate(name, within=180.0):
    """The most recent deliberate action on this desktop within `within` seconds."""
    rows = recent(name, limit=50, since=time.time() - within, kinds=DELIBERATE)
    return rows[-1] if rows else None
__FORGE_FILE_FORGE_EVENTS_PY__
  cat > "$FORGE_APP/forge/gpu.py" <<'__FORGE_FILE_FORGE_GPU_PY__'
"""
Selkies Forge engine - gpu

GPU Smart Passthrough: find every GPU on this machine, work out what each one
can really do inside a desktop, hand Docker exactly that and nothing more, and
step back to software the moment something does not hold.

Four stages, each one safe on its own:

  detect   read-only: sysfs render nodes, kernel drivers, PCI / devicetree
           vendors, the NVIDIA driver and container toolkit, V4L2 encoders.
           Nothing is opened or loaded on the host.
  verify   inside the desktop's own image, as the same unprivileged user the
           desktop runs as, with exactly the devices it will get: start Xvfb
           with glamor on the render node and check DRI3 came up (GPU drawing),
           and ask pixelflux which codecs the node can encode (what Selkies
           itself asks). Cached per image + GPU + kernel, so it runs once.
  plan     the docker arguments: one render node (not all of /dev/dri), its
           group, and settings that pin the base image's guesses ("none",
           never empty: s6-overlay drops empty variables). The base
           image switches VA-API encoding on for any renderD128 it sees and
           glamor on for any render node; on a GPU that cannot do one of them
           (a Raspberry Pi has no VA-API, many VMs have no 3D) that guess is
           what breaks the stream. The plan sets each one to what verify saw.
  fall back
           if a desktop still fails with the GPU on, the launch retries with
           hardware encoding off, then with the GPU off (health.pick_fix).

Modes (opts["gpu"]): "auto" (default) uses what verify proves works; "on"
passes the best GPU through even if verify fails, and never falls back; "off"
passes nothing. True / False from older forges mean "auto" / "off".
"""

import json
import os
import re
import shlex
import uuid

from .util import cache_get, cache_put, have, run


MODES = ("auto", "on", "off")

# kernel driver -> (vendor key, vendor name, can draw 3D)
DRIVERS = {
    "i915": ("intel", "Intel", True),
    "xe": ("intel", "Intel", True),
    "amdgpu": ("amd", "AMD", True),
    "radeon": ("amd", "AMD (radeon)", True),
    "nvidia": ("nvidia", "NVIDIA", True),
    "nvidia-drm": ("nvidia", "NVIDIA", True),
    "nouveau": ("nouveau", "NVIDIA (nouveau)", True),
    "v3d": ("broadcom", "Broadcom VideoCore", True),
    "vc4": ("broadcom", "Broadcom VideoCore", True),
    "panfrost": ("arm", "Arm Mali", True),
    "panthor": ("arm", "Arm Mali", True),
    "lima": ("arm", "Arm Mali (Utgard)", True),
    "mali": ("arm", "Arm Mali (vendor driver)", False),
    "mali_kbase": ("arm", "Arm Mali (vendor driver)", False),
    "msm": ("qualcomm", "Qualcomm Adreno", True),
    "msm_drm": ("qualcomm", "Qualcomm Adreno", True),
    "virtio_gpu": ("virtio", "virtio-gpu (virtual machine)", True),
    "virtio-pci": ("virtio", "virtio-gpu (virtual machine)", True),
    "vmwgfx": ("vmware", "VMware SVGA", True),
    "etnaviv": ("vivante", "Vivante", True),
    "asahi": ("apple", "Apple AGX", True),
    "powervr": ("imagination", "Imagination PowerVR", True),
    "pvrsrvkm": ("imagination", "Imagination PowerVR (vendor driver)", False),
    "tegra": ("tegra", "NVIDIA Tegra", True),
    "nvgpu": ("tegra", "NVIDIA Tegra", True),
    "host1x": ("tegra", "NVIDIA Tegra", True),
    "rockchip-drm": ("rockchip", "Rockchip display", False),
    "mediatek-drm": ("mediatek", "MediaTek display", False),
    "simple-framebuffer": ("simple", "firmware framebuffer", False),
    "simpledrm": ("simple", "firmware framebuffer", False),
    "bochs-drm": ("bochs", "QEMU standard VGA", False),
    "bochs": ("bochs", "QEMU standard VGA", False),
    "cirrus": ("cirrus", "Cirrus VGA", False),
    "cirrus-qemu": ("cirrus", "Cirrus VGA", False),
    "ast": ("aspeed", "ASPEED BMC", False),
    "mgag200": ("matrox", "Matrox G200", False),
    "hyperv_drm": ("hyperv", "Hyper-V display", False),
}

PCI_VENDORS = {
    "0x8086": ("intel", "Intel", True),
    "0x1002": ("amd", "AMD", True),
    "0x10de": ("nvidia", "NVIDIA", True),
    "0x1af4": ("virtio", "virtio-gpu (virtual machine)", True),
    "0x15ad": ("vmware", "VMware SVGA", True),
    "0x1234": ("bochs", "QEMU standard VGA", False),
    "0x1013": ("cirrus", "Cirrus VGA", False),
    "0x1a03": ("aspeed", "ASPEED BMC", False),
    "0x102b": ("matrox", "Matrox G200", False),
    "0x1414": ("hyperv", "Hyper-V display", False),
}

# devicetree vendor prefix -> vendor key, for SoC GPUs with no PCI ids
DT_VENDORS = {"brcm": "broadcom", "arm": "arm", "qcom": "qualcomm", "rockchip": "rockchip",
              "amlogic": "arm", "allwinner": "arm", "mediatek": "mediatek", "apple": "apple",
              "nvidia": "tegra", "vivante": "vivante", "img": "imagination", "samsung": "arm"}

# Which GPU to hand a desktop when there are several: the one most likely to
# both draw and encode well.
RANK = {"nvidia": 100, "amd": 80, "intel": 70, "apple": 60, "qualcomm": 55, "arm": 50,
        "broadcom": 45, "tegra": 40, "imagination": 35, "vivante": 32, "virtio": 30,
        "vmware": 25, "nouveau": 20}

# The hardware encoder a vendor's GPU usually has. verify decides for real.
ENCODE_BACKEND = {"nvidia": "nvenc", "intel": "vaapi", "amd": "vaapi", "tegra": "tegra"}

# A stateful V4L2 memory-to-memory encoder (Raspberry Pi 4, Rockchip, Qualcomm,
# MediaTek, Allwinner). Decoders, ISPs and cameras are left alone.
V4L2_ENCODER = re.compile(r"enc(ode)?r?\b|-enc\b|_enc\b|vepu|venus-enc|h264.*enc", re.I)
V4L2_NOT = re.compile(r"(?:^|[-_\s])(?:dec|decode|decoder|isp)(?:$|[-_\s])|"
                      r"image_fx|camera|unicam|\bcsi|pispbe", re.I)

# Lines in a desktop's log that point at the GPU when it fails to come up.
GPU_HINTS = re.compile(
    r"glamor|dri3|\bdrm\b|drmOpen|render ?node|/dev/dri|\begl\b|EGL_|libEGL|libGL\b|"
    r"\bmesa\b|MESA-LOADER|failed to load driver|gbm|vaapi|va-api|libva|vainfo|"
    r"nvenc|nvidia|cuda|libcuda|NVML|amdgpu|i915|\bv3d\b|panfrost|zink|"
    r"GPU process|gpu_init|Exiting GPU process", re.I)
ENCODE_HINTS = re.compile(r"vaapi|va-api|libva|nvenc|cuda|v4l2.*enc|encoder.*(fail|error)|"
                          r"hardware encod", re.I)

# Every environment key the plan may set; a recreate drops the old values.
ENV_KEYS = ("DRINODE", "DRI_NODE", "DISABLE_DRI3", "LIBVA_DRIVER_NAME", "SELKIES_GPU_ID",
            "SELKIES_ENCODE_DRI", "NVIDIA_VISIBLE_DEVICES", "NVIDIA_DRIVER_CAPABILITIES",
            "AUTO_GPU")

VERIFY_TTL = 30 * 86400
HOST_TTL = 600


def normalize_mode(value):
    """'auto' / 'on' / 'off' from whatever an older forge, the CLI or the UI sent."""
    if value is True:
        return "auto"
    if value is False or value is None:
        return "off" if value is False else "auto"
    v = str(value).strip().lower()
    if v in ("1", "yes", "true", "smart", ""):
        return "auto"
    if v in ("0", "no", "false", "none", "disable", "disabled"):
        return "off"
    if v in ("force", "always"):
        return "on"
    return v if v in MODES else "auto"


# ------------------------------------------------------------------ detect --

def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace").strip("\x00\n ")
    except OSError:
        return ""


def _real(path):
    try:
        return os.path.realpath(path)
    except OSError:
        return ""


def _classify(driver, pci_vendor, compatible):
    if driver in DRIVERS:
        return DRIVERS[driver]
    if pci_vendor in PCI_VENDORS:
        return PCI_VENDORS[pci_vendor]
    for comp in compatible:
        prefix = comp.split(",", 1)[0]
        if prefix in DT_VENDORS:
            key = DT_VENDORS[prefix]
            return key, prefix.capitalize() + " GPU", True
    return "unknown", driver or "unknown GPU", True


def detect_gpus(sysfs="/sys", dev="/dev"):
    """Every DRM render node, with what drives it. Read-only."""
    drm = os.path.join(sysfs, "class", "drm")
    try:
        names = sorted(os.listdir(drm))
    except OSError:
        return []
    cards = {}
    for n in names:
        if re.match(r"^card\d+$", n):
            cards[_real(os.path.join(drm, n, "device"))] = n
    out = []
    for n in names:
        m = re.match(r"^renderD(\d+)$", n)
        if not m:
            continue
        devdir = os.path.join(drm, n, "device")
        real = _real(devdir)
        driver = os.path.basename(_real(os.path.join(devdir, "driver"))) if \
            os.path.exists(os.path.join(devdir, "driver")) else ""
        pci_vendor = _read(os.path.join(devdir, "vendor")).lower()
        pci_device = _read(os.path.join(devdir, "device")).lower()
        compatible = [c for c in _read(os.path.join(devdir, "of_node", "compatible")).split("\x00") if c]
        vendor, vname, can_3d = _classify(driver, pci_vendor, compatible)
        node = os.path.join(dev, "dri", n)
        try:
            st = os.stat(node)
            gid, mode = st.st_gid, st.st_mode
        except OSError:
            gid, mode = None, 0
        card = cards.get(real)
        out.append({
            "node": node,
            "index": int(m.group(1)) - 128,
            "card": os.path.join(dev, "dri", card) if card else None,
            "driver": driver or None,
            "vendor": vendor,
            "vendor_name": vname,
            "can_3d": bool(can_3d),
            "pci": ("%s:%s" % (pci_vendor, pci_device)) if pci_vendor.startswith("0x") else None,
            "compatible": compatible[:3],
            "gid": gid,
            "group_rw": bool(mode & 0o060 == 0o060),
            "boot_vga": _read(os.path.join(devdir, "boot_vga")) == "1",
            "exists": gid is not None,
        })
    return out


def detect_v4l2_encoders(sysfs="/sys", dev="/dev"):
    """V4L2 hardware video encoders (a Pi 4's bcm2835-codec, Rockchip, ...)."""
    base = os.path.join(sysfs, "class", "video4linux")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    out = []
    for n in names:
        label = _read(os.path.join(base, n, "name"))
        if label and V4L2_ENCODER.search(label) and not V4L2_NOT.search(label):
            path = os.path.join(dev, n)
            try:
                gid = os.stat(path).st_gid
            except OSError:
                continue
            out.append({"node": path, "name": label, "gid": gid})
    return out


def detect_nvidia(proc="/proc", docker_info=None):
    """The NVIDIA kernel driver, and whether Docker can hand it to a container."""
    ver = _read(os.path.join(proc, "driver", "nvidia", "version"))
    out = {"driver": None, "toolkit": False, "runtime": False, "cdi": False, "how": None}
    if not ver:
        return out
    m = re.search(r"Kernel Module(?: for [\w.]+)?\s+([\d.]+)", ver)
    out["driver"] = m.group(1) if m else "present"
    out["toolkit"] = any(have(p) for p in ("nvidia-container-runtime-hook", "nvidia-container-cli",
                                            "nvidia-ctk", "nvidia-container-runtime"))
    if docker_info is None:
        rc, txt, _ = run(["docker", "info", "--format", "{{json .Runtimes}}|{{json .CDISpecDirs}}"],
                         timeout=25)
        docker_info = txt if rc == 0 else ""
    out["runtime"] = '"nvidia"' in (docker_info or "")
    for d in ("/etc/cdi", "/var/run/cdi"):
        try:
            if any("nvidia" in f for f in os.listdir(d)):
                out["cdi"] = True
        except OSError:
            pass
    if out["toolkit"] or out["runtime"]:
        out["how"] = "gpus"
    elif out["cdi"]:
        out["how"] = "cdi"
    return out


def host_gpus(fresh=False):
    """Everything detect knows about this machine, cached for a few minutes."""
    cached = None if fresh else cache_get("gpu-host", HOST_TTL)
    if cached:
        return cached
    gpus = detect_gpus()
    nv = detect_nvidia() if any(g["vendor"] == "nvidia" for g in gpus) or \
        os.path.exists("/proc/driver/nvidia/version") else {"driver": None}
    rep = {"gpus": gpus, "nvidia": nv, "v4l2": detect_v4l2_encoders(),
           "kernel": os.uname().release}
    best = pick(rep)
    rep["primary"] = best["node"] if best else None
    rep["summary"] = describe(rep)
    cache_put("gpu-host", rep)
    return rep


def usable(g, rep):
    """Can this GPU be handed to a container at all?"""
    if not g.get("exists") or not g.get("can_3d"):
        return False
    if g["vendor"] == "nvidia" and g.get("driver") in ("nvidia", "nvidia-drm"):
        return bool((rep.get("nvidia") or {}).get("how"))
    return True


def pick(rep, want=None):
    """The GPU a desktop gets: the one named in `want` (a node, an index, a
    driver or a vendor), else the best ranked usable one."""
    gpus = [g for g in rep.get("gpus") or [] if usable(g, rep)]
    if want:
        w = str(want).lower()
        for g in rep.get("gpus") or []:
            if w in (g["node"].lower(), os.path.basename(g["node"]).lower(), str(g["index"]),
                     (g.get("driver") or "").lower(), g["vendor"]):
                return g
    if not gpus:
        return None
    return sorted(gpus, key=lambda g: (-RANK.get(g["vendor"], 10), not g.get("boot_vga"),
                                       g["index"]))[0]


def describe(rep):
    g = next((x for x in rep.get("gpus") or [] if x["node"] == rep.get("primary")), None)
    if g:
        return "%s (%s) on %s" % (g["vendor_name"], g.get("driver") or "?",
                                  os.path.basename(g["node"]))
    gs = rep.get("gpus") or []
    nv = rep.get("nvidia") or {}
    if nv.get("driver") and not nv.get("how"):
        return "NVIDIA %s found, but Docker cannot use it yet (install nvidia-container-toolkit)" \
            % nv["driver"]
    if gs:
        return "no GPU that can draw in a container (%s)" % ", ".join(
            "%s on %s" % (x["vendor_name"], os.path.basename(x["node"])) for x in gs)
    return "no GPU found; desktops draw and encode in software"


# ------------------------------------------------------------------ verify --

PROBE_SCRIPT = r'''
N="$1"; IDX="$2"
say() { echo "$1=$2"; }
[ -c "$N" ] || { say dev missing; exit 0; }
say dev ok
( exec 3<>"$N" ) 2>/dev/null && say open ok || say open denied
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L >/tmp/nv.txt 2>&1 && say nvsmi "$(head -1 /tmp/nv.txt | cut -c1-80)" || say nvsmi fail
fi
mkdir -p /tmp/gp
if command -v Xvfb >/dev/null 2>&1; then
  if Xvfb -help 2>&1 | grep -q -- '-glamor'; then
    say glamor_flag yes
    D=":$(( 87 + $$ % 7 ))"
    Xvfb "$D" -glamor -dri "$N" -nolisten tcp +extension GLX >/tmp/gp/x.log 2>&1 &
    P=$!
    i=0; up=no
    while [ $i -lt 24 ]; do
      sleep 0.5; i=$((i + 1))
      kill -0 $P 2>/dev/null || break
      if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$D" xdpyinfo >/tmp/gp/d.txt 2>/dev/null && { up=yes; break; }
      elif [ $i -ge 8 ]; then up=yes; break; fi
    done
    if kill -0 $P 2>/dev/null; then
      if command -v xdpyinfo >/dev/null 2>&1; then
        if [ "$up" = yes ] && grep -q DRI3 /tmp/gp/d.txt; then say dri3 yes; else say dri3 no; fi
      else say dri3 unknown; fi
    else say dri3 crashed; fi
    kill $P 2>/dev/null; wait $P 2>/dev/null
    say xlog "$(grep -iE 'glamor|egl|dri|drm|fail|error|fatal' /tmp/gp/x.log | grep -v 'removed in XLibre' | tail -4 | tr '\n' '|' | cut -c1-400)"
  else say glamor_flag no; fi
else say xvfb none; fi
PY=""
for p in /lsiopy/bin/python3 python3; do command -v "$p" >/dev/null 2>&1 && { PY="$p"; break; }; done
if [ -n "$PY" ]; then
  "$PY" - "$IDX" <<'PYEOF' 2>/dev/null || say encoders unknown
import json, sys
try:
    import pixelflux
except ImportError:
    print("encoders=unknown"); sys.exit(0)
f = getattr(pixelflux, "hardware_encoders", None)
if f is None:
    print("encoders=unknown"); sys.exit(0)
try:
    print("encoders=" + json.dumps(dict(f(int(sys.argv[1]), "true"))))
except Exception as e:
    print("encoders=error:%s" % str(e)[:120])
PYEOF
else say encoders unknown; fi
'''


def parse_probe(text):
    out = {}
    for line in (text or "").splitlines():
        k, sep, v = line.partition("=")
        if sep and re.match(r"^[a-z_0-9]+$", k):
            out[k] = v.strip()
    return out


def judge(raw, g):
    """What a probe's raw key=value output means for this GPU."""
    res = {"render": False, "encoders": {}, "why": [], "raw": raw}
    if raw.get("dev") != "ok":
        res["why"].append("the device did not show up inside the container")
        return res
    if raw.get("open") == "denied":
        res["why"].append("the desktop user cannot open %s (group permissions)" % g["node"])
        return res
    if g["vendor"] == "nvidia" and raw.get("nvsmi", "fail") == "fail":
        res["why"].append("nvidia-smi does not work inside the container")
    dri3 = raw.get("dri3")
    if raw.get("glamor_flag") == "no":
        res["why"].append("this image's X server has no GPU drawing (no glamor); "
                          "a newer build of the image may")
    elif raw.get("xvfb") == "none":
        res["why"].append("this image has no Xvfb to draw with")
    elif dri3 == "yes":
        res["render"] = True
    elif dri3 == "unknown":
        bad = re.search(r"fail|error|fatal|cannot", raw.get("xlog", ""), re.I)
        res["render"] = not bad
        if bad:
            res["why"].append("the X server could not draw on the GPU: %s" % raw.get("xlog"))
    elif dri3 == "crashed":
        res["why"].append("the X server crashed when drawing on the GPU: %s" % raw.get("xlog", ""))
    else:
        res["why"].append("the X server started but GPU drawing (DRI3) did not come up: %s"
                          % (raw.get("xlog") or "no detail"))
    enc = raw.get("encoders", "unknown")
    if enc.startswith("{"):
        try:
            res["encoders"] = {str(k): str(v) for k, v in json.loads(enc).items()}
        except ValueError:
            pass
        if not res["encoders"]:
            res["why"].append("no hardware video encoder on this GPU; video is encoded "
                              "in software")
    elif enc == "unknown":
        res["encoders"] = None
    return res


def probe_args(image, g, rep, uid=None, gid=None):
    """The `docker run` for a verify probe: the desktop's image, its devices,
    its user, no network, a small memory cap."""
    uid = os.getuid() if uid is None else uid
    gid = os.getgid() if gid is None else gid
    name = "forge-gpuprobe-%s" % uuid.uuid4().hex[:8]
    args = ["docker", "run", "--rm", "--name", name, "--network", "none",
            "--memory", "512m", "--user", "%d:%d" % (uid, gid), "-e", "HOME=/tmp"]
    args += device_args(g, rep)
    args += ["--entrypoint", "sh", image, "-c", PROBE_SCRIPT, "probe", g["node"],
             str(max(0, g["index"]))]
    return name, args


def device_args(g, rep, encode_v4l2=False):
    """Exactly the devices and groups one GPU needs."""
    args = ["--device", "%s:%s" % (g["node"], g["node"])]
    gids = set()
    if g.get("gid") is not None:
        gids.add(g["gid"])
    if g["vendor"] == "nvidia" and g.get("driver") in ("nvidia", "nvidia-drm"):
        how = (rep.get("nvidia") or {}).get("how")
        if how == "cdi":
            args += ["--device", "nvidia.com/gpu=all"]
        else:
            args += ["--gpus", "all"]
        args += ["-e", "NVIDIA_VISIBLE_DEVICES=all", "-e", "NVIDIA_DRIVER_CAPABILITIES=all"]
    if encode_v4l2:
        for v in rep.get("v4l2") or []:
            args += ["--device", "%s:%s" % (v["node"], v["node"])]
            gids.add(v["gid"])
    for x in sorted(gids):
        if x:
            args += ["--group-add", str(x)]
    return args


def image_id(image):
    rc, out, _ = run(["docker", "image", "inspect", "--format", "{{.Id}}", image], timeout=20)
    return out.strip() if rc == 0 else None


def verify(image, g, rep, job=None, fresh=False):
    """Run (or recall) the probe for this image on this GPU."""
    iid = image_id(image) or image
    key = "gpu-verify:%s:%s:%s:%s" % (iid[-24:], g["node"], g.get("driver"), rep.get("kernel"))
    if not fresh:
        hit = cache_get(key, VERIFY_TTL)
        if hit:
            hit["cached"] = True
            return hit
    name, args = probe_args(image, g, rep)
    if job:
        job.log("gpu      : checking %s inside the image (one time, a few seconds)"
                % os.path.basename(g["node"]))
    rc, out, err = run(["timeout", "75"] + args, timeout=90)
    if rc != 0 and not out.strip():
        run(["docker", "rm", "-f", name], timeout=30)
        res = {"render": False, "encoders": {}, "probe_failed": True,
               "why": ["the GPU check could not run: %s" % ((err or "").strip().splitlines() or
                                                             ["exit %d" % rc])[-1][:200]]}
    else:
        res = judge(parse_probe(out), g)
    res["cached"] = False
    if not res.get("probe_failed"):
        cache_put(key, res)
    return res


# -------------------------------------------------------------------- plan --

def plan(mode, image, host=None, profile="selkies", job=None, tried=(), want=None,
         probe=True, rep=None):
    """Decide what one desktop gets. Returns a dict with `args` (devices,
    groups), `env`, a short `label`, and `notes` for the launch log."""
    mode = normalize_mode(mode)
    tried = set(tried or ())
    out = {"mode": mode, "gpu": None, "render": False, "encode": None, "args": [], "env": [],
           "label": "off", "notes": []}
    if mode == "off" or "gpu" in tried:
        if "gpu" in tried and mode != "off":
            out["notes"].append("GPU off for this desktop: it did not start cleanly with it")
        out["label"] = "off" if mode == "off" else "auto:fallback-off"
        return out
    rep = rep or host_gpus()
    g = pick(rep, want)
    if not g:
        out["notes"].append(rep.get("summary") or "no usable GPU")
        out["label"] = "%s:none" % mode
        return out
    out["gpu"] = {k: g.get(k) for k in ("node", "driver", "vendor", "vendor_name", "index")}
    v4l2 = bool(rep.get("v4l2"))

    if profile == "kasm":
        # KasmVNC images find a render node on their own; give them the one.
        out["args"] = device_args(g, rep)
        out["render"] = True
        out["label"] = "%s:%s:kasm" % (mode, g.get("driver") or g["vendor"])
        out["notes"].append("%s passed to the image; KasmVNC uses it if it can"
                            % g["vendor_name"])
        return out

    res = None
    if probe and image:
        res = verify(image, g, rep, job=job)
    if res is None:
        # Not verified (a dry run): say what detection expects.
        render = bool(g.get("can_3d"))
        encoders = None
        encode_ok = g["vendor"] in ENCODE_BACKEND and "gpu-encode" not in tried
        out["notes"].append("not verified yet; the real launch checks it inside the image")
    else:
        render = bool(res.get("render")) or (mode == "on")
        encoders = res.get("encoders")
        encode_ok = bool(encoders) and "gpu-encode" not in tried
        if mode == "on" and encoders is None and "gpu-encode" not in tried:
            encode_ok = g["vendor"] in ENCODE_BACKEND

    if mode == "auto" and res is not None and not render and not encode_ok:
        out["notes"] += (res.get("why") or [])
        out["notes"].append("nothing on %s helps this image, so it is left out"
                            % os.path.basename(g["node"]))
        out["label"] = "auto:unused"
        out["verify"] = res
        return out

    # "none", never an empty value: s6-overlay drops empty variables, and the
    # base image reads a missing one as "guess" (it then picks renderD128).
    # Selkies reads a value that is not a /dev/dri path as "no device".
    env = []
    if render:
        env += ["DRINODE=%s" % g["node"], "DISABLE_DRI3=false"]
    else:
        env += ["DRINODE=none", "DISABLE_DRI3=true", "AUTO_GPU=false"]
    if encode_ok:
        backend = sorted(set((encoders or {}).values())) or [ENCODE_BACKEND.get(g["vendor"], "?")]
        env += ["DRI_NODE=%s" % g["node"], "SELKIES_GPU_ID=%d" % max(0, g["index"])]
        out["encode"] = ",".join(backend)
    else:
        # Pin it: the base image would otherwise switch VA-API on for this
        # node by itself, and Selkies would probe it at every start.
        env += ["DRI_NODE=none", "SELKIES_GPU_ID=-1"]
    out["args"] = device_args(g, rep, encode_v4l2=encode_ok and v4l2 and
                              "v4l2" in set((encoders or {}).values()))
    out["env"] = env
    out["render"] = render
    out["verify"] = res
    parts = [g.get("driver") or g["vendor"]]
    parts.append("render" if render else "no-render")
    parts.append("enc-" + out["encode"] if out["encode"] else "sw-enc")
    out["label"] = "%s:%s" % (mode, ":".join(parts))
    what = []
    if render:
        what.append("draws on the GPU (DRI3)")
    if out["encode"]:
        what.append("encodes video on it (%s)" % out["encode"])
    out["notes"].append("%s: %s" % (rep.get("summary"), ", ".join(what) or
                                    "passed through as asked (mode on)"))
    if res:
        out["notes"] += [w for w in res.get("why") or [] if render or encode_ok]
        if res.get("cached"):
            out["notes"].append("(checked before for this image; not re-run)")
    return out


def docker_bits(gp):
    """Flatten a plan into docker run arguments."""
    if not gp:
        return []
    args = list(gp.get("args") or [])
    for kv in gp.get("env") or []:
        args += ["-e", kv]
    return args


def mode_from_container(labels, hostcfg, label_key):
    """The mode an existing container was made with (for a recreate)."""
    lab = (labels or {}).get(label_key)
    if lab:
        return normalize_mode(lab.split(":", 1)[0])
    devs = [d.get("PathOnHost", "") for d in (hostcfg.get("Devices") or [])]
    return "auto" if any(p.startswith("/dev/dri") for p in devs) else "off"


# ------------------------------------------------------------ fall back --

def fallback(problem_text, gp, tried):
    """The next GPU step back after a failed start, or None.

    Returns (description, key) with key "gpu-encode" (keep drawing on the
    GPU, encode in software) or "gpu" (no GPU at all)."""
    if not gp or gp.get("mode") == "on" or gp.get("label", "").endswith((":none", ":unused")):
        return None
    if gp.get("mode") == "off" or not (gp.get("render") or gp.get("encode")):
        return None
    text = problem_text or ""
    if gp.get("encode") and "gpu-encode" not in tried and ENCODE_HINTS.search(text):
        return ("hardware video encoding failed; keeping the GPU for drawing and "
                "encoding in software", "gpu-encode")
    if "gpu" not in tried:
        return ("the desktop did not start cleanly with the GPU; retrying without it", "gpu")
    return None


def report(fresh=True):
    """A human report for `engine.py gpu` and the web UI."""
    rep = host_gpus(fresh=fresh)
    lines = ["GPU Smart Passthrough", ""]
    if not rep["gpus"]:
        lines.append("  no DRM render nodes on this machine: desktops draw and encode in software")
    for g in rep["gpus"]:
        star = "*" if g["node"] == rep.get("primary") else " "
        lines.append("  %s %-20s %-30s driver %-12s %s" % (
            star, g["node"], g["vendor_name"], g.get("driver") or "?",
            ("usable" if usable(g, rep) else "not usable in a container")))
        if g.get("pci"):
            lines.append("      pci %s" % g["pci"])
        elif g.get("compatible"):
            lines.append("      %s" % ", ".join(g["compatible"]))
        if not g.get("group_rw"):
            lines.append("      note: %s is not group read/write on the host" % g["node"])
    nv = rep.get("nvidia") or {}
    if nv.get("driver"):
        lines.append("")
        lines.append("  NVIDIA driver %s, container access: %s" % (
            nv["driver"], {"gpus": "--gpus (nvidia-container-toolkit)",
                           "cdi": "CDI (nvidia.com/gpu=all)"}.get(nv.get("how"),
                                                                    "none - install nvidia-container-toolkit")))
    for v in rep.get("v4l2") or []:
        lines.append("  V4L2 encoder %s (%s)" % (v["node"], v["name"]))
    lines += ["", "  " + rep["summary"]]
    return {"text": "\n".join(lines), "host": rep}


def shell_quote_args(args):
    return " ".join(shlex.quote(a) for a in args)
__FORGE_FILE_FORGE_GPU_PY__
  cat > "$FORGE_APP/forge/health.py" <<'__FORGE_FILE_FORGE_HEALTH_PY__'
"""
Selkies Forge engine - health

Is the desktop really up? Web port, session agent, OOM and crash detection, fixes.
"""

import json
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from .gpu import GPU_HINTS, fallback as gpu_fallback
from .util import clamp, human_mb, run


class LaunchProblem(RuntimeError):
    """A launch failure the pipeline may be able to fix and retry."""

    def __init__(self, msg, kind, detail=""):
        RuntimeError.__init__(self, msg)
        self.kind = kind
        self.detail = detail or ""


def container_state(name):
    rc, out, _ = run(["docker", "inspect", "-f", "{{json .State}}", name], timeout=20)
    if rc != 0:
        return {}
    try:
        return json.loads(out) or {}
    except Exception:
        return {}


def exec_read(name, path, timeout=15):
    rc, out, _ = run(["docker", "exec", name, "cat", path], timeout=timeout)
    return out if rc == 0 else ""


def _stopped_problem(name):
    st = container_state(name)
    tail = container_logs(name, 40)
    if st.get("OOMKilled"):
        return LaunchProblem("the desktop ran out of memory and was killed", "oom", tail)
    return LaunchProblem("the container stopped on its own (exit %s)" % st.get("ExitCode"),
                         "exited", tail)


def wait_http(name, port, profile, job=None, timeout=240):
    """Poll the desktop's own web port until it answers."""
    url = ("https://127.0.0.1:%d/" if profile == "kasm" else "http://127.0.0.1:%d/") % port
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    t0 = time.time()
    deadline = t0 + timeout
    last = ""
    attempt = 0
    while time.time() < deadline:
        if job:
            job.check()
        attempt += 1
        st = container_state(name)
        if st and not st.get("Running") and not st.get("Restarting"):
            raise _stopped_problem(name)
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
            frac = (time.time() - t0) / float(timeout)
            job.set_progress(clamp(0.88 + 0.04 * frac, 0.88, 0.92),
                             {"waiting": last, "seconds": int(time.time() - t0)})
        time.sleep(2.0)
    raise LaunchProblem("the desktop never answered on port %d within %ds (last: %s)"
                        % (port, timeout, last or "no reply"), "timeout",
                        container_logs(name, 30))


# Kept for callers that only care about the web port (reconfigure, repair).
wait_healthy = wait_http


def session_log(name, lines=40):
    txt = exec_read(name, "/tmp/forge/session.log")
    return "\n".join(txt.splitlines()[-lines:])


# Window managers that never announce themselves (no _NET_SUPPORTING_WM_CHECK);
# for these, windows on screen are the best sign of life we get.
NO_EWMH = {"twm", "ratpoison", "wmaker"}


def wait_session(name, entry, job=None, timeout=180):
    """After the web port answers, wait until the desktop session is really up.

    The forge agent inside the container reports the window manager it sees
    and how many windows exist. "Up" means a window manager that is still
    there on the next look, not just a web page in front of a black screen.
    A session that keeps crashing flips the agent into rescue mode; one that
    never brings up a window manager, or gets OOM-killed, is a problem the
    launch can act on.
    """
    if entry.get("profile") == "kasm":
        return {"wm": "KasmVNC"}
    t0 = time.time()
    deadline = t0 + timeout
    checked_agent = False
    last = {}
    seen_wm = 0
    bare = entry.get("de") in NO_EWMH
    while time.time() < deadline:
        if job:
            job.check()
        st = container_state(name)
        if st and not st.get("Running") and not st.get("Restarting"):
            raise _stopped_problem(name)
        if st.get("OOMKilled"):
            raise LaunchProblem("the desktop ran out of memory (the kernel killed part of it)",
                                "oom", session_log(name))
        raw = exec_read(name, "/tmp/forge/health.json")
        if raw.strip():
            try:
                last = json.loads(raw)
            except Exception:
                last = {}
            if last.get("mode") == "rescue":
                raise LaunchProblem("the desktop session keeps crashing on start", "crash",
                                    session_log(name))
            if last.get("wm"):
                seen_wm += 1
                if seen_wm >= 2:
                    return last
            else:
                seen_wm = 0
                if bare and int(last.get("clients") or 0) > 0 and time.time() - t0 > 25:
                    return last
        elif not checked_agent and time.time() - t0 > 20:
            checked_agent = True
            rc, _, _ = run(["docker", "exec", name, "test", "-x", "/usr/local/share/forge/agent"],
                           timeout=15)
            if rc != 0:
                return {"agent": False}      # an old container without the forge layer
        if job:
            frac = (time.time() - t0) / float(timeout)
            job.set_progress(clamp(0.92 + 0.04 * frac, 0.92, 0.96),
                             {"waiting": "desktop session", "seconds": int(time.time() - t0)})
        time.sleep(2.5)
    raise LaunchProblem("the web page is up, but no desktop session appeared within %ds"
                        % timeout, "nowm", session_log(name, 30))


def mem_pressure(name):
    """Memory use of a container as a percent of its limit (0 if unknown)."""
    rc, out, _ = run(["docker", "stats", "--no-stream", "--format", "{{.MemPerc}}", name],
                     timeout=30)
    try:
        return float(out.strip().rstrip("%"))
    except ValueError:
        return 0.0


def container_logs(name, lines=60):
    rc, out, err = run(["docker", "logs", "--tail", str(lines), name], timeout=30)
    return (out or "") + (err or "")


SECCOMP_HINTS = re.compile(r"operation not permitted|seccomp|bwrap:|clone3|"
                           r"failed to move to new namespace|unshare", re.I)
SHM_HINTS = re.compile(r"/dev/shm|shm_open|no space left on device", re.I)


def _gpu_fix(text, gp, opts, tried):
    """Step the GPU back one notch (gpu.fallback) and re-plan on the next try."""
    step = gpu_fallback(text, gp, tried)
    if not step:
        return None
    desc, key = step

    def apply():
        opts["gpu_tried"] = sorted(set(opts.get("gpu_tried") or []) | {key})
        opts["gpu_plan"] = None
    return desc, key, apply


def pick_fix(problem, plan, opts, host, tried):
    """Decide how to retry a failed start. Returns (description, apply) or None."""
    text = "%s\n%s" % (problem, getattr(problem, "detail", ""))
    kind = getattr(problem, "kind", "")
    if kind == "oom" and "memory" not in tried:
        room = int(host.get("mem_avail_mb", 0) * 0.8)
        new = int(min(room, max(plan["memory_mb"] * 1.75, plan["memory_mb"] + 768)))
        if new > plan["memory_mb"] + 128:
            def apply():
                plan["memory_mb"] = int(round(new / 256.0) * 256)
            return ("it ran out of memory; retrying with %s" % human_mb(new), "memory", apply)
    shm_cap = max(4096, int(host.get("mem_total_mb") or 0) // 2)
    shm_new = int(min(shm_cap, plan["shm_mb"] * 2))
    if SHM_HINTS.search(text) and "shm" not in tried and shm_new > plan["shm_mb"]:
        def apply():
            plan["shm_mb"] = shm_new
        return ("shared memory ran out; retrying with %s /dev/shm" % human_mb(shm_new),
                "shm", apply)
    gp = opts.get("gpu_plan")
    if gp and GPU_HINTS.search(text):
        gfix = _gpu_fix(text, gp, opts, tried)
        if gfix:
            return gfix
    if kind in ("crash", "exited", "nowm") and "seccomp" not in tried and \
            not opts.get("seccomp_unconfined") and \
            (SECCOMP_HINTS.search(text) or kind in ("crash", "nowm")):
        def apply():
            opts["seccomp_unconfined"] = True
        return ("the session was blocked by Docker's syscall filter; retrying with "
                "seccomp unconfined", "seccomp", apply)
    if gp and kind in ("crash", "exited", "nowm"):
        gfix = _gpu_fix(text, gp, opts, tried)
        if gfix:
            return gfix
    if kind == "timeout" and "slow" not in tried:
        def apply():
            opts["health_timeout"] = int(int(opts.get("health_timeout") or 300) * 1.6)
        return ("it is slow to boot on this machine; giving it longer", "slow", apply)
    if kind == "exited" and "restart" not in tried:
        return ("the container stopped during start; trying once more", "restart",
                lambda: None)
    return None
__FORGE_FILE_FORGE_HEALTH_PY__
  cat > "$FORGE_APP/forge/host.py" <<'__FORGE_FILE_FORGE_HOST_PY__'
"""
Selkies Forge engine - host

What this machine is: architecture, memory, disk, Docker, image manifests.
"""

import json
import os
import shutil
import socket
import sys

from .util import cache_get, cache_put, have, run


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

    try:
        from .gpu import host_gpus
        g = host_gpus()
        prim = next((x for x in g["gpus"] if x["node"] == g.get("primary")), None)
        info["gpu"] = {"summary": g["summary"], "primary": g.get("primary"),
                       "vendor": prim and prim["vendor"], "driver": prim and prim.get("driver"),
                       "count": len(g["gpus"])}
    except Exception as ex:          # never let GPU detection break the host report
        info["gpu"] = {"summary": "GPU detection failed: %s" % ex, "primary": None}

    cache_put("host", info)
    return info


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


def tz_name():
    try:
        p = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in p:
            return p.split("/zoneinfo/", 1)[1]
    except Exception:
        pass
    return os.environ.get("TZ") or "Etc/UTC"


def image_id(image):
    rc, out, _ = run(["docker", "image", "inspect", "-f", "{{.Id}}", image], timeout=30)
    return out.strip() if rc == 0 else ""
__FORGE_FILE_FORGE_HOST_PY__
  cat > "$FORGE_APP/forge/images.py" <<'__FORGE_FILE_FORGE_IMAGES_PY__'
"""
Selkies Forge engine - images

Getting images: docker pull with progress, docker build, and the forge layer.
"""

import os
import re
import shutil
import time

from collections import deque

from . import layer
from .host import host_info, image_id, image_present
from .jobs import CommandStalled, stream_cmd, stream_cmd_pty
from .scheduler import slot
from .paths import ANSI_RE, BUILDDIR, IPREFIX, LABEL
from .recipes import build_image_tag, gen_dockerfile, gen_startwm
from .util import clamp, parse_size, run, slug


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


def layer_repo(entry):
    return "%srun-%s" % (IPREFIX, slug(entry["id"])[:60])


def ensure_layer(entry, base_image, job=None):
    """Return the image to run: base_image plus the forge layer on top."""
    if entry.get("profile") == "kasm":
        return base_image
    startwm = gen_startwm(entry) if entry["kind"] == "build" else None
    dig = layer.digest(image_id(base_image), startwm)
    tag = "%s:%s" % (layer_repo(entry), dig)
    if image_present(tag):
        if job:
            job.log("layer    : %s (already built)" % tag)
        return tag
    ctx = os.path.join(BUILDDIR, "layer-" + slug(entry["id"]))
    shutil.rmtree(ctx, ignore_errors=True)
    os.makedirs(ctx, exist_ok=True)
    for rel, (content, mode) in layer.files(startwm).items():
        path = os.path.join(ctx, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content if isinstance(content, bytes) else content.encode())
        os.chmod(path, mode)
    with open(os.path.join(ctx, "Dockerfile"), "w") as fh:
        fh.write(layer.dockerfile(base_image, LABEL, entry["id"], dig, startwm=bool(startwm)))
    if job:
        job.log("layer    : adding the forge layer (first-run fixes, screen agent%s)"
                % (", session supervisor" if startwm else ""))
    lines = []
    env = dict(os.environ)
    env["DOCKER_BUILDKIT"] = "1"
    rc = stream_cmd(["docker", "build", "--progress=plain", "-t", tag, ctx],
                    lines.append, env=env, timeout=900, job=job)
    if rc != 0:
        # No buildx on this Docker: the classic builder handles a file this simple.
        env["DOCKER_BUILDKIT"] = "0"
        lines = []
        rc = stream_cmd(["docker", "build", "-t", tag, ctx], lines.append, env=env, timeout=900,
                        job=job)
    if rc != 0:
        raise RuntimeError("could not add the forge layer:\n" + "\n".join(lines[-12:]))
    # Older layers of this entry are only a few KB each, but tidy them anyway.
    rc, out, _ = run(["docker", "images", layer_repo(entry), "--format", "{{.Tag}}"], timeout=30)
    for t in out.split():
        if t != dig:
            run(["docker", "rmi", "%s:%s" % (layer_repo(entry), t)], timeout=60)
    if job:
        job.log("layer    : %s" % tag)
    return tag


def get_image(entry, host, job, opts):
    """Pull or build the desktop image. Returns its tag.

    Pulls and builds take a scheduler slot first (see scheduler.py), and look
    again once they have it: another launch may have fetched the same image
    while this one waited.
    """
    if entry["kind"] == "pull":
        image = entry["image"]
        if image_present(image) and not opts.get("force_pull"):
            job.set_phase("fetch", "Image already here, skipping the pull", 0.70)
            job.log("image already present locally, not pulling again")
            return image
        with slot("pull", job):
            if image_present(image) and not opts.get("force_pull"):
                job.log("image arrived while this launch was queued")
                return image
            job.set_phase("fetch", "Pulling %s" % image, 0.02)
            do_pull(image, host["arch"], job)
        return image
    image = build_image_tag(entry)
    if image_present(image) and not opts.get("force_build"):
        job.set_phase("fetch", "Built image already here", 0.70)
        job.log("%s already built, reusing it" % image)
        return image
    base = entry["recipe"]["image"]
    if not image_present(base):
        with slot("pull", job):
            if not image_present(base):
                job.set_phase("fetch", "Pulling base %s" % base, 0.02)
                do_pull(base, host["arch"], job, weight=(0.02, 0.45))
    job.check()
    with slot("build", job):
        if image_present(image) and not opts.get("force_build"):
            job.log("%s was built while this launch was queued" % image)
            return image
        job.set_phase("build", "Building %s" % entry["name"], 0.46)
        do_build(entry, image, job)
    return image


BAR_LINE = re.compile(r"\[[=>\s]*\]")


def _stall_limit(var, default):
    """Seconds of silence before a pull or build counts as stuck."""
    try:
        return max(30, int(os.environ.get(var, default)))
    except ValueError:
        return default


# A pull prints progress every second while bytes move; four silent minutes
# means a dead connection. Package installs can sit quietly in a long
# post-install script, so a build gets twenty.
PULL_STALL = _stall_limit("FORGE_PULL_STALL", 240)
BUILD_STALL = _stall_limit("FORGE_BUILD_STALL", 1200)
NET_FLAKY = re.compile(r"tls handshake timeout|i/o timeout|connection reset|unexpected eof|"
                       r"context deadline exceeded|toomanyrequests|too many requests|"
                       r"\b50[234]\b|temporary failure|net/http|connection refused|"
                       r"no route to host|eof$|timeout exceeded|failed to fetch|"
                       r"could not resolve|hash sum mismatch|failed retrieving file|"
                       r"curl error|could not connect|connection timed out", re.I)


def do_pull(image, arch, job, weight=(0.02, 0.78)):
    """docker pull with a live progress bar, retried on network hiccups."""
    lo, hi = weight
    tail = deque(maxlen=30)
    for attempt in range(1, 5):
        prog = PullProgress()
        last = [0.0]
        seen = set()

        def on_line(line):
            clean = ANSI_RE.sub("", line).strip()
            if not clean:
                return
            tail.append(clean)
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
        try:
            rc = stream_cmd_pty(cmd, on_line, timeout=5400, job=job, stall=PULL_STALL)
        except CommandStalled as st:
            if attempt < 4:
                job.log("pull stalled: no progress for %ds (a dead connection); restarting it, "
                        "already downloaded layers are kept" % st.seconds, "err")
                time.sleep(3)
                continue
            raise RuntimeError("docker pull of %s kept stalling (no progress for %ds, %d times); "
                               "the network or registry is not delivering" % (image, st.seconds,
                                                                              attempt))
        if rc == 0:
            job.set_progress(hi, prog.summary())
            return
        txt = "\n".join(tail)
        if re.search(r"manifest unknown|not found|no matching manifest", txt, re.I):
            raise RuntimeError("the image tag is gone from the registry: %s" % image)
        if attempt < 4 and (NET_FLAKY.search(txt) or rc in (1, 255)):
            wait = 5 * attempt
            job.log("pull interrupted (%s); retrying in %ds, already downloaded layers are kept"
                    % ((tail[-1] if tail else "exit %d" % rc)[:120], wait), "err")
            time.sleep(wait)
            continue
        break
    raise RuntimeError("docker pull failed for %s (exit %d): %s"
                       % (image, rc, (tail[-1] if tail else "")[:200]))


BUILD_STEP = re.compile(r"^#(\d+)\s")


def do_build(entry, tag, job, weight=(0.46, 0.78)):
    lo, hi = weight
    ctx = os.path.join(BUILDDIR, slug(entry["id"]))
    os.makedirs(ctx, exist_ok=True)
    df = gen_dockerfile(entry)
    with open(os.path.join(ctx, "Dockerfile"), "w") as fh:
        fh.write(df)
    job.log("build context: %s" % ctx)
    job.log("installing: %s" % entry["recipe"]["pkgs"])

    # Package installs dominate the time; step counting gives a usable curve.
    seen = {"max": 0.0, "pkgs": 0}
    total_pkgs = max(1, len(entry["recipe"]["pkgs"].split()))
    tail = deque(maxlen=60)

    def on_line(line):
        clean = ANSI_RE.sub("", line)
        if clean.strip():
            job.log(clean)
            tail.append(clean)
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

    for attempt in (1, 2, 3):
        env = dict(os.environ)
        env["DOCKER_BUILDKIT"] = "1"
        env["BUILDKIT_PROGRESS"] = "plain"
        cmd = ["docker", "build", "--progress=plain", "--platform",
               "linux/%s" % host_info()["arch"], "-t", tag, "-f",
               os.path.join(ctx, "Dockerfile"), ctx]
        try:
            rc = stream_cmd(cmd, on_line, env=env, timeout=10800, job=job, stall=BUILD_STALL)
        except CommandStalled as st:
            if attempt < 3:
                job.log("build stalled: no output for %ds; restarting it (finished steps are "
                        "cached)" % st.seconds, "err")
                continue
            raise RuntimeError("docker build of %s kept stalling (no output for %ds)"
                               % (entry["id"], st.seconds))
        if rc == 0:
            job.set_progress(hi)
            return
        txt = "\n".join(tail)
        if "exit code: 97" in txt or "FATAL none of these session" in txt:
            raise RuntimeError("docker build failed for %s: the desktop's packages did not "
                               "install (exit code 97, session binaries missing)" % entry["id"])
        if attempt < 3 and NET_FLAKY.search(txt):
            job.log("build hit a network error; retrying in %ds (finished steps are cached)"
                    % (10 * attempt), "err")
            time.sleep(10 * attempt)
            continue
        break
    raise RuntimeError("docker build failed for %s (exit %d). The log above "
                       "says which package broke." % (entry["id"], rc))
__FORGE_FILE_FORGE_IMAGES_PY__
  cat > "$FORGE_APP/forge/info.py" <<'__FORGE_FILE_FORGE_INFO_PY__'
"""
Selkies Forge engine - info

Wikipedia/Commons descriptions and pictures, real screenshots, public catalog fields.
"""

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

from . import catalog
from .paths import DATADIR
from .util import jload


# Descriptions and screenshots are fetched from Wikipedia when the script is
# built (fetch_info.py) and shipped inside it, so every entry has them instantly
# and offline, and the app never trips Wikimedia's rate limits.
_INFO = None
FALLBACK_TEXT = {
    "remnux": "REMnux is an Ubuntu-based Linux toolkit for reverse-engineering and "
              "analysing malicious software, bundling hundreds of free analysis tools.",
    "generic-mac": "A clean, Mac-like layout built on Debian: a slim top panel, a dock "
                   "along the bottom and a calm dark theme. It is ordinary Linux underneath.",
    "generic-win": "A familiar Windows-like layout built on Debian: one taskbar along the "
                   "bottom, a start-style menu and plain grey chrome.",
}


def info_db():
    global _INFO
    if _INFO is None:
        try:
            with open(os.path.join(DATADIR, "info.json")) as fh:
                _INFO = json.load(fh)
        except Exception:
            _INFO = {"families": {}, "desktops": {}}
    return _INFO


def entry_info(e):
    db = info_db()
    fams, des = db.get("families", {}), db.get("desktops", {})
    de_key = e["de"]
    base_family = catalog.BASES[e["base"]]["family"] if e.get("base") else e["family"]

    def article(src, kind):
        if not src:
            return None
        return {"kind": kind, "title": src.get("title"), "url": src.get("url"),
                "extract": src.get("extract"), "lead": src.get("lead")}

    distro = fams.get(e["family"])
    based_on = None
    if not distro:
        distro = fams.get(base_family)
    elif base_family != e["family"] and fams.get(base_family):
        based_on = fams.get(base_family)          # e.g. Mint-style built on Ubuntu

    desktop = des.get(de_key)
    out = {
        "distro": article(distro, "distro"),
        "based_on": article(based_on, "base"),
        "desktop": article(desktop, "desktop"),
        "fallback": FALLBACK_TEXT.get(e["family"]),
        "desktop_blurb": catalog.DESKTOPS.get(de_key, {}).get("blurb"),
        "images": [],
        "source": db.get("source"),
        "fetched": db.get("fetched"),
    }
    # What you will actually see is the desktop, so only its screenshots are
    # shown, plus distro screenshots that show this same desktop (Debian's
    # "KDE default desktop" for a Debian KDE entry, Alpine's Xfce shots for
    # Alpine Xfce). A distro's stock screenshot of some other desktop, like
    # Ubuntu's GNOME under Ubuntu Enlightenment, says nothing about this one.
    pat = DE_PICTURE_WORDS.get(de_key)
    seen = set()
    for src, tag in ((desktop, "desktop"), (distro, "distro"), (based_on, "base")):
        for img in (src or {}).get("images", []):
            if img["src"] in seen:
                continue
            if tag != "desktop":
                text = "%s %s" % (img.get("caption") or "",
                                  urllib.parse.unquote(img["src"].split("?")[0].rsplit("/", 1)[-1]))
                if not pat or not re.search(pat, text.replace("_", " "), re.I):
                    continue
            seen.add(img["src"])
            out["images"].append(dict(img, about=(src or {}).get("title"), tag=tag))
    out["images"] = out["images"][:9]
    return out


# How a desktop is named in screenshot captions and file names.
DE_PICTURE_WORDS = {
    "xfce": r"\bxfce", "mate": r"\bmate\b", "kde": r"\bkde\b|\bplasma\b",
    "lxqt": r"\blxqt\b", "lxde": r"\blxde\b", "cinnamon": r"\bcinnamon\b",
    "budgie": r"\bbudgie\b", "gnome-flashback": r"flashback|gnome classic",
    "enlightenment": r"\benlightenment\b", "i3": r"\bi3\b", "openbox": r"\bopenbox\b",
    "fluxbox": r"\bfluxbox\b", "icewm": r"\bicewm\b", "jwm": r"\bjwm\b|joe's window",
    "awesome": r"\bawesome\b", "bspwm": r"\bbspwm\b", "herbstluftwm": r"herbstluftwm",
    "qtile": r"\bqtile\b", "xmonad": r"\bxmonad\b", "pekwm": r"\bpekwm\b",
    "wmaker": r"window ?maker|wmaker", "fvwm3": r"\bfvwm", "dwm": r"\bdwm\b",
    "spectrwm": r"spectrwm|scrotwm", "cwm": r"\bcwm\b", "ratpoison": r"ratpoison",
    "twm": r"\btwm\b", "lumina": r"\blumina\b", "ukui": r"\bukui\b|kylin",
}
_SHOTS = {}


def shots_index():
    """Real screenshots of each desktop, taken by the forge itself (shots.json)."""
    if not _SHOTS:
        _SHOTS.update(jload(os.path.join(DATADIR, "shots.json"), {}) or {"ids": {}})
    return _SHOTS


def public_entry(e):
    """The catalog fields the UI and CLI need, without the build recipe."""
    keep = ("id", "name", "subtitle", "family", "distro", "de", "de_label", "glyph",
            "kind", "image", "desc", "dl_mb", "disk_mb", "idle_mb", "ram_min",
            "ram_rec", "cpu_rec", "heavy", "weight", "beauty", "speed", "arches",
            "tags", "profile", "display")
    out = {k: e.get(k) for k in keep}
    out["family_label"] = catalog.FAMILY_LABEL.get(e["family"], e["family"].title())
    return out
__FORGE_FILE_FORGE_INFO_PY__
  cat > "$FORGE_APP/forge/jobs.py" <<'__FORGE_FILE_FORGE_JOBS_PY__'
"""
Selkies Forge engine - jobs

A launch (or any long operation) is a Job: a thread doing the work and an
ordered stream of events (log lines, phase changes, progress, the result) that
the web UI reads over SSE and the CLI reads from stdout.

Jobs can be cancelled. Every subprocess a job starts (docker pull, docker
build) is registered with it, so cancelling kills what is running right now,
and the pipeline checks `job.check()` between stages so it stops cleanly.

Every job also writes its log to logs/jobs/<id>.log, so a failure can still be
read after the web UI restarts.

Jobs are durable. Each one keeps a small state file, state/jobs/<id>.json
(status, phase, progress, the process that owns it, the container it is
making), so:

  * any process can see every job: a launch started from `selkies-cli` shows
    up in the web UI, with its progress, and can be cancelled from there;
  * a job whose process died (the web UI restarted mid-launch, the machine
    lost power, a terminal was closed) is noticed, marked "interrupted", and
    the half-made desktop it left behind is removed. See recover_interrupted.

Commands can also stall without failing: a `docker pull` stuck on a dead
connection prints nothing and never exits. stream_cmd and stream_cmd_pty take
a `stall` time; no output for that long kills the command and raises
CommandStalled, which the callers treat like a network error and retry.
"""

import json
import os
import pty
import re
import select
import signal
import subprocess
import threading
import time
import uuid

from collections import deque

from .paths import ANSI_RE, JOBLOGDIR, JOBSTATEDIR
from .util import clamp, ensure_dirs, pid_alive

KEEP_JOB_LOGS = 60
KEEP_JOB_STATES = 80
PERSIST_EVERY = 1.0      # seconds between progress writes to the state file


class JobCancelled(Exception):
    """Raised inside a job's work when someone asked it to stop."""


class CommandStalled(RuntimeError):
    """A command printed nothing for too long and was killed."""

    def __init__(self, cmd, seconds):
        RuntimeError.__init__(self, "%s printed nothing for %ds and was stopped"
                              % (os.path.basename(str(cmd[0])), seconds))
        self.seconds = seconds


def _owner():
    """Who runs this process: the web UI ("server") or a terminal ("cli")."""
    return os.environ.get("FORGE_JOB_OWNER", "cli")


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
        self.cancelled = False
        self._procs = set()           # Popen objects and pty child pids
        self._plock = threading.Lock()
        self.log_path = None
        self._logfh = None
        self.pid = os.getpid()
        self.owner = _owner()
        self.notes = {}               # e.g. {"container": "forge-x"} once one exists
        self._persisted = 0.0
        try:
            ensure_dirs()
            self.log_path = os.path.join(JOBLOGDIR, "%s-%s.log" % (
                time.strftime("%Y%m%d-%H%M%S"), self.id))
            self._logfh = open(self.log_path, "a", buffering=1)
            self._logfh.write("# %s %s %s\n" % (kind, entry_id or "", time.strftime("%F %T")))
            _prune_job_logs()
        except OSError:
            self._logfh = None
        self._persist(force=True)

    # -- producer ---------------------------------------------------------
    def _push(self, typ, data):
        with self._cv:
            self._seq += 1
            ev = {"seq": self._seq, "t": round(time.time(), 3), "type": typ, "data": data}
            self.events.append(ev)
            self._cv.notify_all()
            return ev

    def _write(self, text):
        if self._logfh:
            try:
                self._logfh.write(text + "\n")
            except (OSError, ValueError):
                pass

    def log(self, line, stream="out"):
        for ln in str(line).rstrip("\n").split("\n"):
            self._push("log", {"line": ln, "stream": stream})
            self._write(("! " if stream == "err" else "  ") + ln)

    def set_phase(self, phase, label=None, progress=None):
        self.phase = phase
        if progress is not None:
            self.progress = clamp(float(progress), 0.0, 1.0)
        self.label = label or phase
        self._push("phase", {"phase": phase, "label": label or phase,
                             "progress": round(self.progress, 4)})
        self._write("== %s: %s" % (phase, label or phase))
        self._persist(force=True)

    def set_progress(self, value, extra=None):
        self.progress = clamp(float(value), 0.0, 1.0)
        self._push("progress", {"phase": self.phase,
                                "progress": round(self.progress, 4),
                                "extra": extra or {}})
        self._persist()

    def finish(self, result):
        self.status = "done"
        self.progress = 1.0
        self.result = result
        self._push("done", result)
        self._write("== done")
        self._close_log()
        self._persist(force=True)

    def fail(self, message, hints=None):
        self.status = "cancelled" if self.cancelled else "error"
        self.error = {"message": str(message), "hints": hints or [],
                      "cancelled": self.cancelled, "log": self.log_path}
        self._push("error", self.error)
        self._write("== %s: %s" % (self.status, message))
        self._close_log()
        self._persist(force=True)

    def note(self, **kv):
        """Remember something about this job in its state file (e.g. container=...)."""
        self.notes.update({k: v for k, v in kv.items() if v is not None})
        self._persist(force=True)

    def _persist(self, force=False):
        now = time.time()
        if not force and now - self._persisted < PERSIST_EVERY:
            return
        self._persisted = now
        st = self.snapshot()
        st["result"] = _small_result(self.result)
        st.update({"pid": self.pid, "owner": self.owner, "notes": self.notes,
                   "label": getattr(self, "label", self.phase), "updated": now})
        try:
            ensure_dirs()
            path = os.path.join(JOBSTATEDIR, "%s.json" % self.id)
            tmp = "%s.tmp.%d" % (path, os.getpid())
            with open(tmp, "w") as fh:
                json.dump(st, fh)
            os.replace(tmp, path)
        except (OSError, TypeError, ValueError):
            pass

    def _close_log(self):
        if self._logfh:
            try:
                self._logfh.close()
            except OSError:
                pass
            self._logfh = None

    # -- cancellation -----------------------------------------------------
    def attach(self, proc):
        with self._plock:
            self._procs.add(proc)
        if self.cancelled:
            self._kill(proc)

    def detach(self, proc):
        with self._plock:
            self._procs.discard(proc)

    def cancel(self):
        """Stop the job: kill whatever it is running and make check() raise."""
        if self.status != "running":
            return False
        self.cancelled = True
        self.log("cancel requested, stopping", "err")
        with self._plock:
            procs = list(self._procs)
        for p in procs:
            self._kill(p)
        with self._cv:
            self._cv.notify_all()
        return True

    @staticmethod
    def _kill(proc):
        """Stop a command and everything it started (its whole process group)."""
        pid = proc if isinstance(proc, int) else proc.pid

        def signal_group(sig):
            try:
                os.killpg(pid, sig)
            except (OSError, ProcessLookupError):
                try:
                    os.kill(pid, sig)
                except (OSError, ProcessLookupError):
                    pass

        signal_group(signal.SIGTERM)
        # Anything that ignores SIGTERM gets SIGKILL a few seconds later.
        t = threading.Timer(4.0, signal_group, args=(signal.SIGKILL,))
        t.daemon = True
        t.start()

    def check(self):
        if self.cancelled:
            raise JobCancelled("cancelled")

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
                "last_seq": self._seq, "cancelled": self.cancelled,
                "log": self.log_path, "label": getattr(self, "label", self.phase),
                "owner": self.owner, "pid": self.pid, "notes": dict(self.notes)}


def _small_result(res):
    """The parts of a result worth keeping on disk (not the whole catalog entry)."""
    if not isinstance(res, dict):
        return res
    keep = ("name", "entry_id", "local_url", "warning", "fixes", "display", "dry_run",
            "file", "size", "backup", "clone")
    return {k: res[k] for k in keep if k in res}


def read_job_states():
    """Every job's state file, newest first. Dead "running" jobs are reported
    as "interrupted" (recover_interrupted cleans up after them)."""
    out = []
    try:
        names = [f for f in os.listdir(JOBSTATEDIR) if f.endswith(".json")]
    except OSError:
        return out
    for f in names:
        try:
            with open(os.path.join(JOBSTATEDIR, f)) as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            continue
        if st.get("status") == "running" and not _owner_alive(st):
            st["status"] = "interrupted"
        out.append(st)
    out.sort(key=lambda s: s.get("created") or 0, reverse=True)
    return out


def _owner_alive(st):
    pid = st.get("pid")
    if not pid_alive(pid):
        return False
    try:                          # the pid was not reused by something else
        with open("/proc/%d/cmdline" % int(pid), "rb") as fh:
            cmd = fh.read()
        return b"engine.py" in cmd or b"forge" in cmd or b"python" in cmd
    except OSError:
        return True


def all_jobs():
    """This process's jobs, plus every other process's (marked foreign)."""
    with JOBS_LOCK:
        mine = {j.id: j.snapshot() for j in JOBS.values()}
    for st in read_job_states():
        if st.get("id") in mine:
            continue
        st["foreign"] = True
        mine[st["id"]] = st
    return sorted(mine.values(), key=lambda s: s.get("created") or 0, reverse=True)[:40]


def cancel_foreign(jid):
    """Cancel a job another process runs. A `selkies-cli` launch treats SIGINT
    exactly like Ctrl-C: it kills the pull or build and cleans up."""
    for st in read_job_states():
        if st.get("id") != jid:
            continue
        if st.get("status") != "running":
            return False
        if st.get("owner") != "cli":
            return False          # never signal another web UI
        try:
            os.kill(int(st["pid"]), signal.SIGINT)
            return True
        except (OSError, KeyError, ValueError):
            return False
    return False


def mark_job_state(jid, **patch):
    path = os.path.join(JOBSTATEDIR, "%s.json" % jid)
    try:
        with open(path) as fh:
            st = json.load(fh)
        st.update(patch)
        st["updated"] = time.time()
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, path)
    except (OSError, ValueError):
        pass


def _prune_job_states():
    try:
        files = sorted((os.path.getmtime(os.path.join(JOBSTATEDIR, f)), f)
                       for f in os.listdir(JOBSTATEDIR) if f.endswith(".json"))
        for _, f in files[:-KEEP_JOB_STATES]:
            os.remove(os.path.join(JOBSTATEDIR, f))
    except OSError:
        pass


def _prune_job_logs():
    try:
        logs = sorted(f for f in os.listdir(JOBLOGDIR) if f.endswith(".log"))
        for f in logs[:-KEEP_JOB_LOGS]:
            os.remove(os.path.join(JOBLOGDIR, f))
    except OSError:
        pass


JOBS = {}
JOBS_LOCK = threading.Lock()


def job_put(job):
    _prune_job_states()
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


def jobs_running():
    with JOBS_LOCK:
        return [j for j in JOBS.values() if j.status == "running"]


def stream_cmd(cmd, on_line, env=None, timeout=7200, job=None, stall=None):
    """Run a command, hand every output line to on_line, return exit code.

    `timeout` bounds the whole run; `stall` (seconds) bounds the silence
    between two lines. Either one kills the command and its children.
    """
    # Its own process group, so a cancel can stop the command and its children.
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         env=env, bufsize=1, universal_newlines=True,
                         errors="replace", start_new_session=True)
    if job:
        job.attach(p)
    start = time.time()
    last = [start]
    why = []
    done = threading.Event()

    def guard():
        while not done.wait(1.0):
            now = time.time()
            if now - start > timeout:
                why.append("timeout")
            elif stall and now - last[0] > stall:
                why.append("stall")
            if why:
                Job._kill(p)
                return

    threading.Thread(target=guard, name="forge-cmd-guard", daemon=True).start()
    try:
        for line in p.stdout:
            last[0] = time.time()
            on_line(line.rstrip("\n"))
    finally:
        done.set()
        try:
            p.stdout.close()
        except Exception:
            pass
        if job:
            job.detach(p)
    rc = p.wait()
    if job:
        job.check()
    if why == ["timeout"]:
        raise RuntimeError("command exceeded %ss" % timeout)
    if why == ["stall"]:
        raise CommandStalled(cmd, stall)
    return rc


def stream_cmd_pty(cmd, on_line, timeout=7200, job=None, stall=None):
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
    if job:
        job.attach(pid)
    buf = b""
    start = time.time()
    last = start
    stalled = False
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
                last = time.time()
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
            if stall and time.time() - last > stall:
                stalled = True
                Job._kill(pid)
                break
    finally:
        if buf.strip():
            line = ANSI_RE.sub("", buf.decode("utf-8", "replace")).strip()
            if line:
                on_line(line)
        try:
            os.close(fd)
        except OSError:
            pass
        if job:
            job.detach(pid)
    try:
        _, status = os.waitpid(pid, 0)
        rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
            else (status >> 8)
    except ChildProcessError:
        rc = 0
    if job:
        job.check()
    if stalled:
        raise CommandStalled(cmd, stall)
    return rc
__FORGE_FILE_FORGE_JOBS_PY__
  cat > "$FORGE_APP/forge/launch.py" <<'__FORGE_FILE_FORGE_LAUNCH_PY__'
"""
Selkies Forge engine - launch

The launch pipeline: resolve, fetch, layer, start, verify, tunnel.
"""

import time

from . import catalog, gpu, ledger
from .health import LaunchProblem, mem_pressure, pick_fix, wait_http, wait_session
from .host import docker_ok, host_info, image_present, manifest_probe
from .images import ensure_layer, get_image
from .info import public_entry
from . import events
from .jobs import Job, JobCancelled, job_put
from .paths import VERSION
from .ports import release_port_reservation
from .recipes import build_image_tag
from .registry import docker_instances
from .paths import CPREFIX
from .runner import container_name_for, display_for, docker_run_args, docker_run_resilient
from .scheduler import slot
from .smart import plan_resources
from .store import reg_delete, reg_update
from .tunnels import tunnel_start
from .util import human_mb, run
from .webui import running_desktop_names


def launch(entry_id, plan=None, opts=None, job=None, name=None):
    """Pull or build, layer, run, verify the session, tunnel.

    Every stage that can fail for an ordinary reason (a flaky network, a port
    someone grabbed, a desktop that needs more memory or a looser syscall
    filter) is retried with a fix applied, and each fix is written to the log.

    Heavy stages wait for a scheduler slot (one build, two pulls, two boots at
    a time by default), the job can be cancelled at any point (whatever is
    running is killed and a half-made desktop is removed), and everything that
    happens is written to the event journal.

    opts["dry_run"] stops after the checks and reports what would happen: the
    plan, the image, the download, and the exact `docker run`.
    """
    opts = dict(opts or {})
    entry = catalog.BY_ID.get(entry_id)
    if not entry:
        raise RuntimeError("unknown catalog id: %s" % entry_id)
    job = job or job_put(Job("launch", entry_id, entry["name"]))
    opts["job_id"] = job.id
    host = host_info(fresh=True)
    plan = dict(plan or plan_resources(entry, host))
    reserved = []
    cname = None
    vol_existed = False

    try:
        # ---- 1. check this machine can run it ---------------------------
        job.set_phase("resolve", "Checking %s against this machine" % entry["name"], 0.01)
        job.log("forge %s  |  %s" % (VERSION, entry["name"]))
        job.log("host     : %s, %d cores, %s RAM free, %s disk free"
                % (host["arch"], host["cpus"], human_mb(host["mem_avail_mb"]),
                   human_mb(host["disk_free_mb"])))
        mode, res = display_for(entry, opts)
        job.log("plan     : %s RAM, %s CPU, %s shm, screen %s"
                % (human_mb(plan["memory_mb"]), plan["cpus"], human_mb(plan["shm_mb"]),
                   "fixed %dx%d, scaled to your window" % res if res
                   else "follows your browser window"))

        ok, derr = docker_ok()
        if not ok:
            raise RuntimeError("docker is not answering: %s" % derr)

        admit_memory(entry, plan, host, job, opts)

        need = 3 * 1024 if image_present(entry.get("image") or build_image_tag(entry)) \
            else int(entry["disk_mb"] * 1.3) + 1024
        if host.get("disk_free_mb") and host["disk_free_mb"] < need:
            raise RuntimeError("only %s of disk is free and this needs about %s; "
                               "free some space (docker system prune) and try again"
                               % (human_mb(host["disk_free_mb"]), human_mb(need)))

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
        opts["gpu"] = gpu.normalize_mode(opts.get("gpu", "auto"))
        if opts.get("dry_run"):
            opts["gpu_plan"] = gpu.plan(opts["gpu"], None, host, profile=entry["profile"],
                                        probe=False, want=opts.get("gpu_device"))
            return _dry_run(entry, plan, opts, host, job, name, real_dl, res)

        if not host["quota_support"] and plan.get("disk_mb"):
            job.log("note     : %s on %s cannot enforce a hard disk cap, so the %s "
                    "limit is tracked, not enforced"
                    % (host.get("storage_driver"), host.get("backing_fs"),
                       human_mb(plan["disk_mb"])))

        # ---- 2. get the image, then the forge layer on top ----------------
        job.check()
        image = get_image(entry, host, job, opts)
        job.check()
        job.set_phase("layer", "Adding the forge layer", 0.80)
        run_image = ensure_layer(entry, image, job)
        job.check()
        _gpu_plan(entry, run_image, host, opts, job)

        # ---- 3 + 4. start it and make sure the desktop really came up -----
        tried = set()
        session = {}
        warning = None
        attempt = 0
        boot = slot("boot", job)
        boot.__enter__()
        while True:
            attempt += 1
            job.check()
            job.set_phase("create", "Starting the container" if attempt == 1
                          else "Starting it again (try %d)" % attempt, 0.84)
            if opts.get("gpu_plan") is None and opts["gpu"] != "off":
                _gpu_plan(entry, run_image, host, opts, job)   # after a GPU step-back
            if not cname:
                cname = container_name_for(entry, name or opts.get("name"))
                # A volume kept from a removed desktop of the same name is
                # someone's files: never delete it when this launch fails.
                vol_existed = run(["docker", "volume", "inspect", _volume_for(cname)],
                                  timeout=20)[0] == 0 and not opts.get("prepared_volume")
                job.note(container=cname, volume=_volume_for(cname),
                         keep_volume=vol_existed or None)
            cname, reserved, vol, cid = docker_run_resilient(
                entry, cname, plan, opts, run_image, host, job,
                want_ports=reserved or opts.get("ports"))
            job.log("container: %s (%s)" % (cname, cid[:12]))
            events.record(cname, "create", "%s (try %d)" % (entry["name"], attempt),
                          entry=entry["id"], image=run_image)
            note = {"entry_id": entry["id"], "created": time.time(),
                    "plan": plan, "opts": {k: v for k, v in opts.items()
                                           if k not in ("password", "job_id", "prepared_volume", "dry_run",
                                                        "gpu_plan")},
                    "gpu": (opts.get("gpu_plan") or {}).get("label", "off"),
                    "volume": vol, "image": run_image,
                    "ports": reserved, "tunnel": None}
            if opts.get("idle_stop") is not None:
                note["idle_stop_min"] = int(opts["idle_stop"])
            reg_update(cname, note)
            try:
                job.set_phase("health", "Waiting for the desktop to come up", 0.88)
                heavy = entry.get("weight") in ("full", "heavy")
                wait_http(cname, reserved[0], entry["profile"], job,
                          timeout=int(opts.get("health_timeout", 420 if heavy else 300)))
                job.log("web      : answering on port %d" % reserved[0])
                job.set_phase("session", "Waiting for the desktop session", 0.92)
                session = wait_session(cname, entry, job, timeout=240 if heavy else 150)
                break
            except LaunchProblem as lp:
                job.log("problem  : %s" % lp, "err")
                for ln in (lp.detail or "").strip().splitlines()[-12:]:
                    job.log("  | " + ln, "err")
                if lp.kind in ("crash", "nowm") and "memory" not in tried and \
                        mem_pressure(cname) > 88:
                    lp.kind = "oom"          # it is starving, not broken
                fix = pick_fix(lp, plan, opts, host, tried) if attempt < 4 else None
                if not fix:
                    if lp.kind in ("crash", "nowm"):
                        # Leave it running: the rescue session shows the log in
                        # the desktop itself, which beats a dead container.
                        warning = (("The desktop session crashed on start, so it opened a "
                                    "rescue session that shows why. " if lp.kind == "crash" else
                                    "The desktop did not come up properly. ") + str(lp))
                        session = {"mode": "rescue" if lp.kind == "crash" else "nowm",
                                   "log": (lp.detail or "")[-1500:]}
                        break
                    raise RuntimeError("%s\n%s" % (lp, "\n".join(
                        (lp.detail or "").strip().splitlines()[-15:])))
                desc, key, apply = fix
                tried.add(key)
                apply()
                job.log("auto-fix : %s" % desc)
                events.record(cname, "recreate", "auto-fix: " + desc)
                run(["docker", "rm", "-f", cname], timeout=120)
                release_port_reservation(reserved)

        boot.__exit__(None, None, None)
        boot = None
        if session.get("wm"):
            job.log("session  : %s is running (%s, %s window%s)"
                    % (session["wm"], session.get("screen", "?"), session.get("clients", 0),
                       "" if session.get("clients") == 1 else "s"))
        elif int(session.get("clients") or 0) > 0:
            job.log("session  : up (%s window%s on screen)"
                    % (session["clients"], "" if session["clients"] == 1 else "s"))
        elif session.get("slow"):
            warning = warning or ("The web page is up but the desktop session had not "
                                  "reported in yet. Give it a minute, then reload.")
            job.log("session  : still starting, the page will catch up", "err")
        if tried:
            job.log("fixed    : %s" % ", ".join(sorted(tried)))
        gp = opts.get("gpu_plan") or {}
        if gp.get("render"):
            if _dri3_confirmed(cname):
                job.log("gpu      : the desktop is drawing on %s (DRI3 is up)"
                        % (gp.get("gpu") or {}).get("node", "the GPU"))
            else:
                job.log("gpu      : the desktop did not report DRI3; it may be drawing in "
                        "software (see the container log)", "err")

        # ---- 5. tunnel --------------------------------------------------
        job.check()
        tun = None
        if opts.get("tunnel", True):
            tmode = "tcp" if entry["profile"] == "kasm" else "http"
            job.set_phase("tunnel", "Opening a serveo tunnel (%s)" % tmode, 0.96)
            try:
                tun = tunnel_start(cname, reserved[0], mode=tmode,
                                   subdomain=opts.get("subdomain"))
                job.log("tunnel   : %s" % tun["url"])
                if tmode == "tcp":
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
                  "ports": reserved, "image": run_image, "plan": plan,
                  "local_url": "http://localhost:%d" % reserved[0]
                  if entry["profile"] != "kasm" else "https://localhost:%d" % reserved[0],
                  "https_url": "https://localhost:%d" % reserved[1]
                  if entry["profile"] != "kasm" else None,
                  "tunnel": tun, "instance": inst,
                  "session": session, "warning": warning, "fixes": sorted(tried),
                  "display": "fixed %dx%d" % res if res else "fit",
                  "credentials": ({"user": "kasm_user",
                                   "password": opts.get("password", "forge")}
                                  if entry["profile"] == "kasm" else
                                  ({"user": opts["username"], "password": opts["password"]}
                                   if opts.get("username") else None)),
                  "quota_enforced": bool(host.get("quota_support")),
                  "gpu": {k: gp.get(k) for k in ("mode", "label", "render", "encode", "gpu", "notes")},
                  }
        events.record(cname, "ready", warning or (session.get("wm") or "up"),
                      fixes=sorted(tried) or None)
        ledger.release(job.id)
        job.set_phase("ready", "Ready", 1.0)
        job.finish(result)
        return result

    except Exception as ex:
        if "boot" in locals() and boot is not None:
            boot.__exit__(None, None, None)
        release_port_reservation(reserved)
        ledger.release(job.id)
        if isinstance(ex, JobCancelled) or job.cancelled:
            # A desktop that never finished starting is of no use to anyone.
            if cname:
                run(["docker", "rm", "-f", cname], timeout=120)
                if not vol_existed:
                    run(["docker", "volume", "rm", "-f", _volume_for(cname)], timeout=60)
                reg_delete(cname)
                events.record(cname, "launch-cancelled", "cancelled during %s" % job.phase)
            job.fail("cancelled during %s; nothing was left behind" % job.phase)
            raise JobCancelled("cancelled")
        if cname:
            events.record(cname, "launch-failed", str(ex)[:500])
        job.fail(str(ex), hints=_hints_for(str(ex)))
        raise


def _gpu_plan(entry, run_image, host, opts, job):
    """Decide (and check, once per image) what GPU this desktop gets."""
    gp = gpu.plan(opts["gpu"], run_image, host, profile=entry["profile"], job=job,
                  tried=opts.get("gpu_tried") or (), want=opts.get("gpu_device"))
    opts["gpu_plan"] = gp
    for n in gp.get("notes") or []:
        job.log("gpu      : %s" % n)
    if gp["mode"] == "off":
        job.log("gpu      : off for this desktop")
    return gp


def _dri3_confirmed(cname):
    """The base image logs which node Xvfb draws on when glamor comes up."""
    rc, out, err = run(["docker", "logs", "--tail", "400", cname], timeout=30)
    return "using DRI3" in (out or "") + (err or "")


def admit_memory(entry, plan, host, job, opts):
    """Refuse to start a desktop the machine plainly cannot hold right now.

    A limit is a cap, not a reservation, so the plan can exceed what is free
    (the desktop just runs tighter). But below the desktop's floor it would
    thrash or be OOM-killed; say so up front and name what is using memory.

    Memory other launches have booked (see ledger.py) counts as used: two
    desktops starting at once must both fit, not each fit on its own. Once
    admitted, this launch books its own floor until it is up.
    """
    free = int(host.get("mem_avail_mb") or 0)
    floor = int(entry.get("ram_min") or 0)
    if not free or not floor:
        return
    others, rows = ledger.booked(exclude=job.id)
    usable = free - others
    if others:
        job.log("memory   : %s free, %s of it set aside for %d desktop%s still starting"
                % (human_mb(free), human_mb(others), len(rows), "" if len(rows) == 1 else "s"))
    running = running_desktop_names()
    if usable < floor and not opts.get("force"):
        starting = ""
        if others:
            starting = ("%s is set aside for desktops that are still starting (%s). "
                        % (human_mb(others), ", ".join(sorted(set(
                            (catalog.BY_ID.get(r.get("entry")) or {}).get("name", r.get("entry") or "?")
                            for r in rows)))))
        raise RuntimeError(
            "only %s of memory is free and %s needs at least %s to start. %s%s"
            "Stop a desktop, wait for the others to finish starting, or pick a lighter one "
            "(or pass force to try anyway)."
            % (human_mb(max(0, usable)), entry["name"], human_mb(floor), starting,
               ("Running now: %s. " % ", ".join(n.replace(CPREFIX, "", 1) for n in running))
               if running else ""))
    ledger.book(job.id, floor, entry["id"])
    if usable < plan.get("memory_mb", 0):
        job.log("note     : the %s memory cap is more than the %s free right now; it will "
                "work, but may get slow if it uses it all" % (human_mb(plan["memory_mb"]),
                                                              human_mb(max(0, usable))))


def _volume_for(cname):
    return "%sconfig-%s" % (CPREFIX, cname)


def _dry_run(entry, plan, opts, host, job, name, real_dl, res):
    """Everything a launch would do, without doing it."""
    ledger.release(job.id)
    image = entry["image"] if entry["kind"] == "pull" else build_image_tag(entry)
    have = image_present(image)
    cname = container_name_for(entry, name or opts.get("name"))
    run_image = image if entry.get("profile") == "kasm" else "%s + forge layer" % image
    args, vol = docker_run_args(entry, cname, [0, 0] if entry["profile"] != "kasm" else [0],
                                plan, dict(opts, job_id=None), run_image, host)
    steps = []
    if entry["kind"] == "pull":
        steps.append("use %s (already here)" % image if have else
                     "pull %s (%s)" % (image, human_mb(real_dl or entry["dl_mb"])))
    else:
        steps.append("reuse the built image %s" % image if have else
                     "build %s on %s: %s" % (image, entry["recipe"]["image"],
                                             entry["recipe"]["pkgs"]))
    if entry.get("profile") != "kasm":
        steps.append("add the forge layer (first-run fixes, screen agent, screen guard)")
    steps.append("start %s with %s RAM, %s CPU, %s shm, volume %s"
                 % (cname, human_mb(plan["memory_mb"]), plan["cpus"],
                    human_mb(plan["shm_mb"]), vol))
    steps.append("wait for the web page, then for a window manager that stays up")
    if opts.get("tunnel", True):
        steps.append("open a serveo tunnel")
    job.log("dry run  : nothing will be downloaded, built or started")
    for i, st in enumerate(steps, 1):
        job.log("  %d. %s" % (i, st))
    shown = " ".join(a if " " not in a else "'%s'" % a for a in args)
    job.log("docker   : " + shown.replace("PASSWORD=%s" % opts.get("password"), "PASSWORD=***")
            if opts.get("password") else "docker   : " + shown)
    result = {"dry_run": True, "entry_id": entry["id"], "name": cname, "plan": plan,
              "image": image, "image_present": have, "download_mb": real_dl or entry["dl_mb"],
              "display": "fixed %dx%d" % res if res else "fit", "steps": steps,
              "docker_run": args}
    job.set_phase("ready", "Dry run complete", 1.0)
    job.finish(result)
    return result


def _hints_for(msg):
    m = msg.lower()
    hints = []
    if "permission denied" in m and "docker" in m:
        hints.append("your user is not in the docker group yet: "
                     "run `sudo usermod -aG docker $USER`, then log out and back in")
    if "no space left" in m or "disk is free" in m:
        hints.append("free some disk, or run `docker system prune -af` to drop old images")
    if "no arm64" in m or "no amd64" in m or "has no" in m:
        hints.append("pick an entry whose badge lists your architecture")
    if "never answered" in m:
        hints.append("heavy desktops can take a few minutes on first boot; "
                     "try again with a longer timeout, or check `docker logs`")
    if "exit code 97" in m or "session binaries" in m:
        hints.append("that desktop's packages are not available on that base; "
                     "try the same desktop on another distro")
    if "tag is gone" in m or "manifest unknown" in m:
        hints.append("the publisher removed that image; pick another entry")
    if "network" in m or "timeout" in m or "tls" in m:
        hints.append("the network dropped out several times in a row; try again in a minute")
    if "serveo" in m:
        hints.append("serveo may be rate limiting; the local URL still works")
    return hints
__FORGE_FILE_FORGE_LAUNCH_PY__
  cat > "$FORGE_APP/forge/layer.py" <<'__FORGE_FILE_FORGE_LAYER_PY__'
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
/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAAgFBgcGBQgHBgcJCAgJDBMMDAsLDBgREg4THBgdHRsYGxofIywlHyEqIRobJjQnKi4v
MTIxHiU2OjYwOiwwMTD/2wBDAQgJCQwKDBcMDBcwIBsgMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAw
MDAwMDAwMDD/wAARCAQ4B4ADASIAAhEBAxEB/8QAGQABAQEBAQEAAAAAAAAAAAAAAAECBAMG/8QAIxABAQACAgMBAAMBAQEAAAAA
AAERQSExUWFxgZGhscHw8f/EABoBAQEBAQEBAQAAAAAAAAAAAAABAgUDBAb/xAAVEQEBAAAAAAAAAAAAAAAAAAAAAf/aAAwDAQAC
EQMRAD8A+DyEI/YOEGgigZCdAvR0Ags8IsUCEAUICHtU0As6NCKLBF6A0aACAAqBsAPgoCpOkFiAof4AgAQDYIABQPgIimjRCAVN
GQADPCCS8hAVAEBPIVFE0qAHRtEUBEDCKnyIogAnQqaRUARRDQgaT4dAqAIqapooggCKmg7AT9BEUICCapoBRDQgaQEUymeAAARU
AgAgin0E0AdgKAiAeSAoAAnQfiAUIKCeVA+G0WAJTZoUAA0AAaADPAIKpu5IAQhkAAFF/UIBSAophJ0QVQ/QCKgAqRVCBPYKEFUI
ENAE6FVTyEAF9YQ0osPoQUm1iKoQgApEWKp5WdIqgaAFgCqfQAUgKCz0kWKoEAURYqgYFFDsA/xYaQFAVQFgJ/awNKBkWAioKKQn
QABqimOCC/AQVABQEh9VIAeQA7AA8kNgAUAAEMp5UARRBAOwAwAATpBDyQA9IoAhkADyIgfoAEQB3iK9XEA0ARYgopAAVARQ8igG
jYKiwA7AVFnYmgFE1wsABOgWcHZCABAAAAE0CzoIQBBQQJ0AAACCKBUAp5Os4EBPJ0Ch5QQIQ7QAoVFQ+GhFEAENiVFDk9CCaC/0
iKFEBc+EERTSaXafEUBECB0noUBEBFRFIioAm16RFEXSIomlRA8oqCgJpA0AKICAi9J5FVAQEAABFIkXtAC9gCCoinoIgKE64QVU
yHnIAfoB5E2op0AgEBQAQBP0VRUAUygCwJfJkUhogBPcVBQhD0oqKAENnZ/oEoCiidrkUCAKIvlQIAop5FCAARQ0qi4SHkFhAUUi
KqhABSEOlFEVVFiRQAP8UIKKpCACw0QVTk4BRQgAqRVDzgAVdCRVCE9gABOgIpOSdeVADIEJeAFBU2B+qCiRRNACgB+IoCQNAQBA
AAIACKfBBDRpAJ0EApCgG0/wAP8AgH8IHwABFBEXpOxAmdIuzQCKgO6GQeriC6TXo+UFNBADRlVAyigLpIQRYAoRUICiKAEAPISk
VDyT6HwBUIC75QPQKIAqAAB0AEACggZQhoU+AgKIIB0IKE9CY4QVAA2gRFEyH6Ai6RFPiL5RARURRFAQTIimkCdopUIAZQEUQ2iC
5QEVABUBEABFQKiCoAqUBAQEUQ0SgVFRFDJek0CoCKJ8ABNKIqAACZUVDAbQIayHkCIFFAAD2CBo4Cf2KH6RKBAAAAIZMcgppUAA
+AKgKqoAKhFn0AgAAiqsPJPYChogECE+gohFVQ+gC+kiqpCHZACBFFCdAKTtBVWHkgosNEIB0qLNqoACwBQ6WIsVSAoACiyZCGFU
iooEJ0QUAWSKodAAqRdqBDaigixQyACiCigAQhAUD9UECKoQACAAIuAAgAIs4tQFTyqAqKm0AioAcGwQ8ovSCgCIQABFSAYCCAQg
Aiz0mgDaoiB9DyBORJyA7j8RZ29XFAgIpwhAUACdLEFFEi6EWCAKQ0KBABUJ5yAokAUgnYgpoUOAyCkAQJyQAOie0PgBs+AHnIAB
1UPILlIUQNAgoFEC+kABAFDQiBoE+ooCIHkDYqAnxBYgiKH0QAoiKHwTOED+kyuu0RRFRFE0qATaZ0qIoiogaRdIiiUBRFRBPgqC
iL8RABMoKggqoexAPR/qCifVTSKqdAAaM+0AICKQ58iaBU2YJ1yAAiiKgKgAQPhoUNABnBgQFEUUPSAL+gk4yC6EM9goGhQhADZA
12AE+iiwSALAJ2KQ7OVUSKnw5BZ6ICqomQFhngAU0T2KoqTAC9GiChlYh6VVDXBsCKEUNqiqp0EANrKixVJVSKoTpU9UgKJpYoKk
NKqnR+Ci/oQnQp6WdHk7URZ0CiiRYKKgC+SdkFDSxIALoIoHQT2KeVRQQ0RVE+rs/wDZIAbAEUn8AEBAUAE6UAMAAmlEgBF8ogaD
AB6ODWjQiHQChARDYFARYiBOgAEVPIH0ORAAEMJ8XQDsgSfyPRxRUICrGViookNApE6UCL8QyCwQnSjSfAEUQBQiRRSB5AyQAA4O
wUTIAAAB+gaJfQAfoAIGiVAA0KJ+AAAgmdgbA/UVEUnop9QFQRBdJo/QVNgIIT0vpEUQBUA0gcJ9NIir9TdEqBTIIqAgAZEVEXpO
EU0ZEQAQUPIiAioinsKgoCfUDsBAQNiiU8iKCEABEF6ToBQE/wCIAAp5DKAdByICaUFBIAQNAEA77AP7TyRFWCAACh8A+IpkAAgA
QBQJDOgFIkBV77EzxlQAnQB/AHSqLPSRdAfgEAVD6osIQFPpoFFDZ9A/4sQVVOggBD4ulCd8gQUXKKoKhlRQhJgVQhFBUVQhDkFW
crOYkPKiw5RfagqG1VQICgRQVF2qgEAXR2KCoCmlCKAE/wAFUBUDEAUmyC6URfggKBsAIa6A2fgAQAADQEJABFiKBAPQIAAHQgGj
QCCggh2IAEA0aQQDWQABPoGQ0Iho8nRQNIQB2LpFejigigsElAX0IqoEMgLwaRQP0ADpfWUPKiiKAIogsQAVCABDILn2mrgAU8oA
v6IQAAAggqiAKgIGhAD6Gj5gU0IIAgCodIir+oGgMoHaAnYgq4Re0QED/UUT6tRFENCBEOgVAEElBP1FARBekNIKf6FTSAGhFQE8
igIgAIIBpFEyGhRAQDRUopQRAAoGUVNIoAAJyCgfUQUnVE0AeQFATpA0AKQhAA0AAJAUSEBSchkUEgCiLoDQAGgBSASgQBQVAUWI
sAhogoTpYn6bBTRDucgQhoVV+k4SEBV8pP8AD+1F/SJFFFiZFFhCZFF6CEFFiEUWH9EJ0opryQ8iqaRdKE4WIKLFQFFIeYoLEXSq
GCKoLLmJ0AKH2qpFSdrOlCBFgAi6qhyqGhVA8qHw2QBeyIqhyBkVQARezyKE6CEA9B0AAdgGTgAAAAAyAAmqpsEFRAAA3wdwJ0AJ
TuCAvURASrgAiAgHnIAUNIAB0iAApBCUR2BOjltxQOyAL9T0fFFho/klBU/CAKEIqAAKawgCwPgBMgKE9rEICz+RFgGidpF5AIgC
6EWACEBZ0gAGyICmkEFO0M8AcB5RFXSdCAv0SdAHwEyiqgIAgACIpwIdAaTK9JlFBDKAGU0KIqICAinSVU/UBAFENiKgCAgIqa4A
AQzwIplBNCreMpoggIvWURRNAgZMoAAiKBoABPKKaDR0CbD0Ip9BAVCdAAE8oqAAZOA+AHKKKRAA0u0EF84QAIAKT0QADyaACAAB
yqrOkJ5AU6iAKIAoQ+cgGCCqohAUBQVIAp0EFIQFBYn9rtVFRQDARRRFAVBVVUgCkBQkVFVSLlIKLjyBFF0ToMYFUntFigqKqmuA
wRRcgAsEWe1UixFUCACwNkVSEF8gCL2oLEixQAn0UABRIqhgwTkwAAAEAAMAAAQNkA3gAAAD0ACKIgB3nAAGD5gBFBBAQAATsDQA
CAioAAiAAGhAHWvSDbjEVJSAvwAQVMkBRPiqC6TJNguqIAogqKAAuUP4AXVSE6BRNAKa5RfgHR0AH+QQBcpoAUQADKAoJ5FAEA+i
AqEvJpARUFAggJAAT4H9IsQCACF2iiZgAdn0qRFDyIgAiKcGxABBFPiL9TSKaQyIIKnwUQEBART0hkQEAUQNICL9TyinoO4mgD8E
RVTyACZnwoigEAT2dCAgd0UOwAEPKAQO4KAk4QVA6yAEBQ8ooGxNAL9EW7BCAKB+FBUyGgO4qAKIbFWGeBO56BQ4QF4OgUVCKKCK
AT0QUUQAWCelGhDAqkPIoQnEAFCdEVT4qL0AvaCi+SEFgokWdCipNn6ooCqsIEUUABdosVT9VIqhAhFFIGhSKQ0oLCE6VRUWAECK
LwTOEiqCp2QVQNqGlSEBQhFANGhVgkFF2AABAAANEAA0AEAAAwAddAAQnRzsDpMKgAQQCAAiw6EQBA7AAQOkCAUBAADQiAACaAHU
ukGnGXIH6BAJ/KiiaAURRCBAFQhFF+CLoAyQA/FzymQFEgouhBEUSGlVQ+ogp+IfgKeUM9gs2gQAyICxF8oC/qBtAlEyAuk3Qgp2
IsQQEFIH6IE2gIGkAUm010aP1ANH+psUEEAIiKBtAARFEPggaRURQ5E0AJkRSoFRRA7ABMooCdxAgf2iKBpPQBoEVDRSAJzg0IoZ
8oAfQxBA+iAoHkQQnYAAgq5Q0IE2T+TKfoKGUgqk6QAXyhEAIAHkBQEBYIt/oAJx0kBQBQ6hOxQAmAMkADapADysEVVhkAFSAKQg
oBSCqTpFnYGV6QUWESKoaVIopFQUURYoTvCooCoRVXYGlF42AKpAWCiLFDapo0qqEIosEUFhOEiqp9VFihsITtVUD+wIsD8UIsRV
UipxCAobFAPJAWBBQ6oAoQAUIKEAyBoCZAgAAAAT0AEJ/YABAAvXNARSCCB8AEXQIIqfiAYXSdgAARCCAexAVKqAAIAaIIVAQdQi
tOOGSfBUFiGeAF0gCmiUnYB5BRYT0mQRRFBU0EAntUFFydoAuRIAvAZQFRUgLBCAsPqQgKgZAgf8NIGhNAoTAAZIIgACggAZEqAU
QFT2GkUQO0U5EEDynC+sIAehEUuwQA2hekU7NCIBng0iKfpBAATpFDSfDpFEDQCKiKIqIAGEEBBQPKIqoaPMA+J8DSBlMmgUPIiC
p8M8AoiogBsAymlTaKAAdB5TyCxNAimT9IeQDwfOEBUlAA+AAAKeQSAoi9gaNnkyABrApODZ+kgKJoBRMkUX0F9psFgQFXZP4Q0C
kTSzaguU0QFEUUAUUyiqC55QBfhMgqrCeE/0UWLlFAAiihCdCi+UXSgplFFgv4iqofgos/lcpCCqRF2oRfiKoTpUVVIsRYoECfyC
wCLFFRVAIRRezyRRUnSoqhsD4CwIaUCGgUVADQpNqEJ1ck6JgAAAIABokAx2BoACAAAIoCFBAAAAgIAiH0ISgCZ0oIAgB8QAIQA0
CIgqAqQ6EHSa9IrTjmhFAVAFMosUAlNCAEAWdVFyB9AAD2KKIZAVIdiKaQFWCGhFyICqJDyIvAgKeQAAQF+mkEAggL2Joz4RViCA
v6gAQMmkBBBVS+wygZQEU0IdQD/UVEUPIgGg8oimjJEQP+mRNIpoE8gCCKGqZRA3yCIoCAAIqAkQAT9FXyl9msJEFSmhFN8IAAIK
H0TSC77TydE2gIcgpkABARQABJyTsADIgEQ+iqnQAERUAiKKGzSAaVAAhAADsD0qAoEAIqAKId+1FEXIAEAVFFNHdDlQnALASLEi
qHZA+AuhFwqgQgLBFUUyk/kBdcBKKqwhD2osE8rAJ0s65Sdk+Kq+VTVP4UWKgqrOtgAT+VRVDNwsRZwoL5SLpVJz0sQUXYeRVX+j
QQFCG1FE+qqkBYABpRRFVRUUEUIoeVQBRBVUNEAWIKKAAHCAoGgMHYAAAGwADJ+gh+CoIaAAARMioKCoiHw6EBUVADoEBFiAAIgi
6QANgBkEHQBlXHAAFieRRRFmQIbJ/FP0AlIApEgqKQAJfAAKRDQCoAoh8BeMCAKZTICwQAlAyAUQFEBVghfSBkABAA+giKqfDtAU
TR0gqAB0nQkRVygAH1BFEDOUAIlFARA9AiKIAAIih0ggAiKfQ/UADKIoHQAgmeEUBEAEFUEQCGUQDyJoVUD9QNEQFJsEQAIKGkAN
gIGTSAKn9nsRQEBUPYAf0AAEFBCAuhAFEANAS8CqJ2dcgppFAgJoFzyQACBFF0ICr/QaNACL5AXaTlVCEoAuezKLFA8kIKZX2igo
kFFAiqRRIoqzlIQFhCbFFh5NGdKos7RYoRcos6Ai7QVVipCKLFiQUUgCrAIopCEVVhEVQyqToUXhe0htVXo+hsFyQIoLOUX9AIEV
RYgopPoUAPw8qL/wAACCm10J0BwKaURUXsAE/oFNCAAdgC4RADzg8gegAEX4AhA0gACGxFgIAgAgBQQEUEECgAaQDuIsvkHuIK5C
gAplNE4EURcgeQhANKgCiCizYigAAeViaQFDPYCiACoApwgIqAKQE67BQQFzwhAADKAAKRIAAfE6QMgACGkUP0vSAtQKgnkEyKqd
qiAgZFATSACdopeAiaADaIp+giAGkRQ5EA9B7RFMmQBKGhFOj9Q6QE0Ap5QzmiAIdxABBQEQNgaFQ65BAIH6CAIoIfQDRkAyEEVN
KmT2AHQAAAmjRpFAAAIACAoICgdCh0AEAAAAXSToBRBRezfaEgqkPZoCGxfigGyALEIosJ0EBYRBVWbIT0T2CwSL0oLEICqkIqqJ
P5VQVIoCxCKqrPSCi8mw8qLAh9VVIEAWJFUWCLFVSIqhlYmiKqrwk8Ciqi9AQgRRdexFVRUiqEOTPYCwThVUVITyCgRQCEAVFVTn
IQAMcfQACAAqAGj/AAyoGTs0gaAAAANfQgBlOjQBkgiBAA8opsE0AgbPSKAgcAAIAJoQA8oAQ7BAAe4TgHINAZwAACnCKAAof6bA
CdL0hBFNIsoAfTIAH0AJwARUAIHRFCHsABFQBFATIeRVQNAZBAWUSCCoZABDKKqSiAqAB9MiaRT6GUABEF0IRFP8QABBFATKACaF
VAQT6CAFBFQERQ0IABrhFE0ZRBfiBoUEMoF2JkQAQUAQEAUQEAEAARTYgAAgkUnKCr/iQT/oLRNCC1AA6JQ0KZOkUAQ8gAIBkAVA
ADsVVQ+AHwJ7AD8P0BRAFnAGgA+kUWIAqiRQIaBRRFAVJ6AXIiqoqCikIbAixJeFUXJEhOVVVQgL0QNKLBFVVNcoqi9CRSBFRVCL
pJ2KqxdJBRVSCqoEUUIQFgizhVXgTpfKhFQUUnGwyKsCf0bUUScwUUAFAVRU5AIuU+L6UA0AToNAKEKqgZAAgAABoPYIfDoNCidr
7SCC54QFA8iIB0Ah2qYBUDpAP6CAgdGgAEBFP9EQBAAAQAAnYg9vIijknwgaAVBRRDyIp6MkoCppMg0JDQKRFnIB8QUXImVAngRQ
BMqAAAZBAgnC/wDQBDILoiAL9SiQFDKToBUyIp1AQFyIAAiCoAogIBRAKU8iKCJ3EFPiAoJQAE0igeUQDybTaKGQgJpO1RBUCoqG
cACAIoioAgIpUVEBKqChkEEA+oAmQU4D/iABOEqKqHkQAAQwAoaEQXKAACAoJQAPqKGk0AoEAPqE8gogKSqmQRTST0QUVNACpwAo
igQQBQMqGlQFFJ/ABFSACxIKKcYCAcrEVQgQVVEigKixQJ0EBVQVV5Ik9LpQVNKAEFFXSGVVVnhIKKQFFzAFVdCLkD4sqSr5UWAK
oqKoKgqr0QAUCKLOvBpFVSL0k5WKCoARfKKqhkAWdHkPKgqEBQFCcB9JvkAgAQ0AHKpNii6E/RBTKLlRAXyB+oCAB2B8D6AIZAJ/
ICATjJ/B2CTsh8oB5ARAiAFyFED4mlICaA8gBRAyCbB7H4QRySAaAWIKKRAFEUBZeGVBRD9EU2n6QFEiqBngymUFAUNBO0Bfgn6A
ohAWCGxTszgRBpDIBQnpMgqZCgecmeDRkDo0ggqZNIKoggfTQgLlPQIpoiAB0aRBU0ZBRAQBAUBEDrlFTOUUNCAGgRUBEDJkATR+
mhFEP6AED4iiB8QA2gocCIAaTQqoaEDKKmUDgEzwKqAgYIe0ABAUS+BFPZoQFE9Q+oGSBBSGfIgKJoAAA7BEFIiihntFggipoVRF
A7yIsAghAUndye0UUABUMgok9rBQBQVD9BQhoBYkqqBEUUVCcxRViHwFNJFUUnNT9NKLFRYAToFVYEFFEVQixFFFScRVDhUFF+qg
qqsSCirPaE2ooAqxUOlDKpFUURZwqipOligBAUh0Kqk+pD9UUIQBSCgqAqgRQhAgLKk9gouhFACAAigQgAAAEMGQO/QIChnyAIHk
A7gIAAJwC6BAlNIAAggIHYaATyBAAECIEvAGuQ/T4g9TyhngcpQ/AAIQQVJwAuz+0igf8D9SA1E0EvtQixMgLDSQ6BRCdAuexIAo
hoFh0mgFQAUQgAAAJlBRNgKgCgZQFE9CAIAqGT9RRMh0ABADKCKbDSAAmUFTRoRT6J+mgEVEURbwgBsS7RTsEQDJQEgCAgIogCgI
gFNJ7FVP7EQNmzIgn0OTWBRAQVEXoVAMoHlAAhDREEA0KIqAAIAh6FAnIASgAJwfqCoU+AGjvRBQAAEgKAAJFAIICkAAPgCiALD0
gKs2doqoZDqEFUm0WAARRQAPgEqqpEXoRSRFVQCAok9KouSdIqgqRVUCGVFEX8BRO4qizogKq6WbZi9gvJEitCkSKKReEVQWJFih
AhP5VVixCAsAUUiLlVX+xJ0dKNCQlUWEMgoqdCikJSAoIop8ICioAoEUCBsBUAXsQAVAF+pCAAE2AACoaAAnpPQKIAKhlAPptICi
ZNgqBEQQP0F2kACBUQX/AICaAgCB8D/AR6AiOWuFyk6QFXScdGwXQgC+hNgLF7QUITsgAvlKAqB/ICp3ARZeEKaFWUQ+iLCIAL9Q
FAAAAD+EEBUyTkAPoB+iAKkoAQQRVQMoAhQVNiZFUQQBP/oACIpQAEBFE2CBRAA6ERQyJdgqaLURVQPgCAigggBpANAmkVUBBOAB
QEQAAQBFE7AA/sTKBKB8FBDO0ADIAgKARAE3gAgAGjYaACJKgsTYCmggAAAAB5IGwAAD9NABDjROwUBVBIogqQ0KRYiwDoT/ABVB
UICwD4oKgKpMEFRSCQVVSLFABRYvCf2AsEXuKKIuVUVFihFiZUBUFVT0CigKL1BFVVIkWALKiqC47ykq+VFMpFVT4v1CKLA0bUWf
FToFURVDPCz0h/ainkMirMICinoAU0nQop+JF8gHYQUVJ0AuhIKLBF0ACApBAU8gAeUUEF9IgBwQDyGuwAEA+B8BANCB+CABo0RA
CoC/EP4P+gaICBBJ2cCKgQHoIrLmGiJ5AXRlMrAWIfARSIaUXqCHkFEyoKhMAAACpk0BwAAJpQM8gAHJoAoAAJoFydICqnWTSIL5
JRAUQgH6fwICgiKEACiCAZEgKgIoJkAIIgvSAKIAGkM5P7QNmuSdJtFXKEQAPOBFMoGUBM9gAf0ZRFATsDIIirEKIG0+gKG0EAEy
AQRFXSB0BRL0IAAp5QggdmjygHkBAEUVAANAiC+EABYgKfoQlABAVJQAhrkAMqkEBdoAL0mhQv8Aip5AUiKAGSehQ6CCEVFFD6EU
DQdAomVUFiALAIoRUUCbWJpeFUX+2VBYdoKKCxQhn0igpOAVVnonKKopMJ5WKLMYJzEixRckQiqqpCKLO/CxAFgQiqvapBRdho0C
mUXTSqRF0CiCixUgqiooCoqgsqQVRdJFAVBRfpBICgAsEFFOhAUhAUIkyoBAAAA6A2IaEh5FXQgIpEAXSGvJEAD6AGkBU0dgBoRB
UMkBc9oCAAAgdCBA2gFQB6dEQZcxZsn0QFAADQoTlYgCjMUFMiZBckCUDyAIBpBV0IohoEFUzyZAMielgBqoQDSoAqAAZE6QUQAN
AKa4CJAUQQATIBkABDKKQMpsFE0IHkEFNAmfaCoHQoHSekA8of6Cp2REVc8pQQEyfADyIIoCZyACIoZBAQANp0CKUE/ANAZQEAUE
+CACAqAigZ44QDyAigh0AEEDKegAJwQAEBQIZukFQABFAAgGgygLkhAATR5BcE7EgKGiAEIAKhpVIu00oBM4SKAHRoFIRFFAAVFU
IsSALCEFFEBVWIaUUnlNKCwn9IqguklFFXSLFCe1Ql8ir0sQUXQHxRTKRfKqp7Tys8KKIoKIqqQwGlFVBRVTIqqGgFIkFGhFUDky
KqgkBVQii6WIZAWJkiqpOAAipwKE2pOkBSCTYLAAFwgoBBAVAFQP1Q2TsIgGQ0BxQ8xAUQAAQKIvkCeBAAgAAIIqQEDoEDR9TdAB
UBYk7BBuCdKy5poieRRQSUFMkBDKp2AZWcJAFMp9MgpEICmTtM4BZZgyhAWCez2CiALBM4M8gvZpMmgX2IeQIqEFCGQAQBU+gga0
aE7BScoAvRnlBFMgnQKVEBQ6SoKhoA1ygRFD9EADCAoIih/iXAgBpBQ0ZRBRDICAiheBAE0qaQAEUTQAZPiQqKaBAARFAAEM+zO0
AEACCKIF6ANGUtQVAFAiIBPAAAAICAEwCgndXQE6QMgAIB8IZA/SABwCAoEAAFIsSAgAqi/8SKBOhFAVDIKJ2qgToIAsTS7UPpoJ
/IKJpdKCzpDvsFDQoKnXSiioRRViEUUiLAWEqL7VTSppYoohtRelSdAKsQwqrAhOdqLPh+mhRdiLFFImVgqnxIRRYs/UFFyBFFEV
YqzZEUBUFFMgCwRZ5VSGgUX+hFA7We0AUiCqppFyABkABRYaQgCpogKkAFSHkBRODaAAoARAE0sAQAVAyAGezqIGRAF+Jvs0CACB
P4TybACBnAAaRBUAG/ggy5q9iKBKIoAiwDKxMgCoToFnAhOvICoAodRMgs7EFFyIIKIAuRDQGVTICpKQAXKAAICofQFQNgHoEUgm
eAFQ2AToQRTVAEElCcIodiAvaaWIBsEyigICoCKAgKgIIAKICAURABNgAeUUDKfoB8Eyih5AEA/tBABRPgIGzIgAG0UTZnsA/AEE
gFFBBAgAAaEEJ6DIAAon0APoCACAqAAACzpAFA2CEAAABciQFXQnoBQhoDRDkUWCALCdJlQCAooiwBfKLtQJUlUFEVQVAVYBFFEg
os+Kk2AqpBRZQIoqxCCrFnCCikSEUaEVQVCKLpc+kBVNBFFEiyqLSdEJyqrBAFWIKKsZiqqwRYAuEFFVIKLD0QFM8LEFFCbACGhR
dn1AVYQIIKkNKqkSnkFNmcRMgpO0h8BYaTQCwTIC/RCAuUDQAAEICIAgqiQggEANGTaIKipoFQAAIgJAAAA6EEGxDOWXOUQ8gplC
Ap+osogAACCqAqEAiCoCime0AWe0BFXKZBUFykJUUAAIQEMiSmhVM8oAZ4XKAHkADOQRBUCAEPKZ5FUQ0gZPIQBMhoAERVEAARAo
AohsAzoEQCiX2CiCKZEXIIAin0QQBDIAIihnyToA0gIJngNHYoQRABMgqCIqoAAIgs9ofToBFRFXKAAJoQM47AAEN9iqndDKABQE
CAAAAIBsQF+JABThNgq+UM8H4IoIKoQgE6J0CgfDkgC5QBQAVNkFFnQigSmSCiwD4AqHQKcUhFFEi/AJ0sTJFFixBVUSKosEi9gp
EIosDXJFF17XKCqqoAsAUURVDysTSxVFQUVZtIdAoTYopAiqRUnaqCpNrANKyqqoEA7VNCi+QAURdqoBAA6FF/8AU0HkAMl6BUJ0
KKbQnIL7NofAXIigCAKIAomgVQQQOwAAA4A0gQ0k6AVFTQACAIv9gRAA4EVAiAAqAgQnYC/p5IMOesQ0AplAFyRAFEVQEIgoE6AE
0qgGQBfiAEoAGQAAAPIICkTQgvcM+RMguciAKmQ/QMhKb4FBFAEOkAPwgAhrAEpoJ1wih6QyBPpoABMiAfRBQBARZsBANICGgU/U
WJ2AAiiHQgZQyaADCIKgCifoICfVQABFQABDYgQEgpk+AgJFQBFSdIoAAiogXsNgIQ2IoZ8CAqAABkBFEBABYIAHAChkQFAAgH0C
f4B/QFDQAAAqecEBRFgKhBRRAFXSEUMrEWdgTyENKLyJFA2qKBAgooQ0qrrnoiCiqiwAnoFF1QFFNosFFiKoLE2qgqEUWGQgLoIK
KRFyqiz6h8UVYmOQFWIKqkSKooiwAgRRdiRRSXtUFFhAUUT6AuQmBQXaQBZjQAoueEhAWEQUU6QBRAFAADyAZ4PQkBdEMgBEnS5A
CcfqAAYAOgAzgDSAJkBUP0AAQTS+UMiKgZAAQEAFnSADSQO2HPMgAp0n9kFUT/gIsEgqqICKCQFpAAEXIBkQFDPCAoGwCeEWcikC
AgRJ4AX6IaFX6IILEJsA6EAUiACpo/UC0QyCmfCZPYoa9AACfECAACTrBkUDSfqC/RDIBKIirnhBNguhPggACpoM8CAIfAPIIgGw
FARA8ggoAgmw6AEBFAT0ABEBFQBFKiobABAQPIJsDPYH0UD6iCiACKIB8QAA0AIopAQFOkEFEAAPoGgACGgFT6aWACLlQDsAnBoA
FiLAAIoRUJ0CkzzgFBUgCxYz9WKLoIAE6JVUFQgKAos+kIKoqQ85BSAovGRFUUiKosIiiqbTQovSpPZFFNgosEWCkWcoqiiRVCKn
wBTYKqiKoKhOgWARRRIsAAlUUSKKeVSCgpE12CkDXILOhMk7UWGkhBVyQ+oIsIhsVdGSAHAigGhAU9E/hAWbBAU0gCiAAQ0AGU2C
7ppNG0FKkBCAAaOxEDKoALEABPQC/BDSCnoyMvgXPYmTyBOjQQFJ6QBciAL9EoC5MkQFBICibWACf6Aug8gB8IgKTo0gKfidAKJ/
ICiALnwIAZDrYAIqKBEAAA7gICwSdCAaP0+AIHkUAQAQAPhAKlXPSIoAAgZQNlwJ/gqoZEAKgAaRFAIAIIBOxAANIqAAAiACCgEQ
AQAEQVAFMJo8iAeTCAswiogIqf6KqBoABARYgB0AAgKqAgaAANBAAAASAofqQF0JpYBCcBAPgH0F7QgCz4IvlQABUVAU0EUIqKAH
oUUzygCxUgosABSbRYop9IgLFRVUIEUUiKopEnQDWRPK6UAIqroBRZ0J96UF2RFUFiRVFJygCgKpFnaRYoLE+AL2JF0qqcosyAuU
67IosEigRfqQUXyIuhTIGFFJzCIChsnoBUhFFEgC7EJ6BSABkEUUDSKBEBQgIHwTQqiAKIAqBAABA+nKIBABUno0AETZ1AWCCABA
CCaBdGk0ILyAy+AgALEgCqkARSIAoh2CkQnYL9EzwaBchEBdCaUA4AA2AoaNJngFEAFieVEEoCgABsifQUTRxkBRM4QVAlAEXQH9
iAoqCAIAs9oABwJUVdIcwA6PJ5NAgcHcwgJ1VQUIQQOkAAPggJN9mqZFJENCAioAZDtFCpsARRBANCiKiABAQEQVAFA7TPCAdB+g
QO0QABU2HQACIBoAAhkBFSIoGwDAAAaQFyRPhsFMp+CCofoATnYAppIKCoYBTKeiAvo5IaAXPhCAL5RVAgf0BOl0mgFgaOFCKhAX
ROgiiwyQA+KmxRTQRRQ+nYKQn+ChFSKKRUFFgHagqLLwBFT4qhO18pgUWdqyvCqs+mjVAWeghFBdoKLF2hNirDykVRfhEgoqpogL
CJFigqaBVgaIoLKhAWXwIqhlUICiEBSBlVXOz4gCiAKJAFDfg8gZMhOe1AhoAE0QFPKKgZIfiApNifAU0gC6SAAAAaMppBUAAAA0
AAhUFTQAZ4MgACfQURYw+EgQAgdACoAsMIAv1D6AonJPYKJonSizZKkAUyk6AUQ8oKJ+AKRNgKZQ0Coqf8BciQAIHkAAAQFX+CIA
qBEDQAAdRAXJpBABAUSApoyACKiAEAAQUAQEzwEAoaRAXST0CgJPQACAh8KKAnlBUMnlAQAEVBQBAzhAARUQNhOkFCggAUBAQNIq
CnsgIAgAAAhkQAMCiZ4UAQAANoBoAAnlAU0ncWAB7ADJCAEDQCoaBYfUgopAAVCAsEWKEABTyigRYmlUIJO1ihoFAvK6QgKT0iqL
OhFUFiEBT+wUWCcrpVUSdqAvHKCigKLAAMKiqoqCiwIQFnoRVBUixQX+0N8iqIvGaookAU7BQVIsoEXSCqsDKAswZMChOlQgKH9J
FF7IAqiEEUQFXIi/AP08h5Al0Q0RQDQAdZDIAfDQAAAigGUEFiEAAAA0ZQBADRrkNAfAPgHkPKAqAiAfoAIsAIRGHxqaO0gikDyB
VQBUIKKJ5AWexIAogCm0AUygCiaAUlTOSAoJAURc0AnaAouUBBUmxAIZNigh5BdEQ7BTtDYAAHZ+ggCGhVQAOEVEFiZADRoQFQEA
AVAgBk0IgACgdoAAgVP0KAaMiKgQAM+0ogAAVKCKCQ8gBqp+oAdHYoZBBAAEDygAeRU4NgABpBAOwEVEAhwAH1PYKqB5BfidAgAA
ioSgHazlAIACoQ0BkABdgBAAAAVAiiiLOQAAFiKoKkICn02fAF+IKLLyQFF4EXoFnfaGhRQIC4ICiiCqqzafAF1SEFFhOkXSiwSK
AvaL8UPoQUWE6RRVhMJBRSAooigKhpRdLO0BVCdIosABZwCRRVT6QFEVVNAAp7T/AIKKH4ZAPhCdAvoQBRIAuRFAA6FCmRUNEvg0
kFUAATQgpAAJUXYEIh5AnSoAE6DIED6ACAKJP6EAAQ0CAqZMkQWbSeAAgdAAT6MvjAAIAAqACpAFEIAqEBciQBYJk+AogC6ElAUh
wgLDSEBSIAvYgC/qZMgKIAAQARfqAdiAuIIAQ5NgoQQFENIAHwDVD9QFTR5BQ6ITCAEATsM8AGkyqIGTJo5AKIik9AZABKCoJ5RV
QAEWpUA67ABA0ihoQAIAIqIB/wADsUQEA7ggGOAECIvSUURTSBUAE0a9qnwFSEEBFPIpEXSAqa4BAABAACAAABAAAAIQAJ2QWAip
OAFAAJ9ABUiqAfhoAJz2ToFJwQUUnpJhYBpfKLFEWEQFW+UFFyACkRYoKgoqsrAU0iqqwRVBSJAUBRSJ+KAs4qKoLlNLFCHsAU+h
OsKoqCihsAnKxBRdEnACmliRVD9JQBYIAoi1QWIQF8hlIKp/gKKIAqEP0FEAUiGVFPQZAyEIABfoAJkFNXKKBDJUBTKaAABVz5EN
VEA/gAA2ARADaxBA0QAMgmQUQBUBBUADyfpoZfGdUgAERYAGgD0BP4AOOiACoAsEIC/onkBYnoAUiHQLRN1fdAEICmUAU0kICiGg
UQAlXKGQDQChwAHkymVygJAzgADYAICiAKgIAegUEAA/sQNJlUBUIABURQM5ADKGgAEURUAAAQECAAIQiKIukAAQPKU6BS9CCAEA
QPwQEVBQVNCB7ERQABA6RTfYdJkFBBD0cAigIBgAAioAAAGiIAeQARQJQP0ABQAAiooBCGgIAooiwAhCAsEXtQDYCwIRQWIAodQk
UWE+J+rAFiRVCTyTgICgkUUguVUWIoHpUhFFD+wBdJtVACdKL+nxFmQFQVVyQ9AKIs7UFQBfgGVFNIQFEWKoswhkFgkVQhwAKIKL
7ImgFAA0sTRkVT6mwFNIqgAAAAZDYHkhAA5ygCggKfEAUTKoB5SAKhD4ABAWIi8Y5A6EAUTPB+gB8EAAAiAGw/QA+muACUBh8gJ+
gKAB7VCUAJwAdH0yAsMoSgs4EAUiG1F+CGgUEyiCpOuRVWdCAKIAtEgCiQQXSGQBU2AqdAAAAndCAoJoFQANcARAEUUE8nYGsAaA
nQAHZtBA2AKCbPKB9IaAAQFSAgCEFAEAEAABNUCIoGkA90DSAEQAgIoioAACAIoioBQEBMAAAgJoAA+H0VIABAEBFAQCQAgfqBAP
9AJ6OwBFJ0AIAugPQB1wAAEUAMAKEACegBU7VQAAmLlYmV9gQgRRRF5AgCihrg9gs8ETyqhD6QUUhCAecL2kVQ0aIAsAiimkiih2
aFFAiiw/g9gGlQUU0mvqgRYnaqoaJsBTSLFCAApCIosIAKRFUA0CipkUU0igdGqdkA0uUICiEBRNCihE/wBBQBQDIBAAgEAIi8AQ
0bNAAgLNiAKIZ9oCoABlNAv0iRQDSRQMmUAAAANoGTSAGgAWCAAaGHyAH9gBAA0ehQIAHSpAFEIC6EAUiAL+iAKIApP5SeQFAAIm
iAoJugohoFEMgp2kAIAKBo9IgEAIGkFURQBOgBUAAOkAT2QBU4AABQsQl4QIAAET4AAgAQVAKAE6RAAATpUANAiiKgACCQDnwKIq
AqfgICKgHs+hpAQBQBBAADYiBybNFFA6ztJ6AOQQEXYCQUBPwwAAToqAZuxAUQ8gCoAfTtRUFQRQmUgKGjCgE2AKmlACGgFiQUUD
+AAgChgUUSLAJ0GhRYaSKBOlQUUAFEWdKEXKHUBQz5IoonSqCpAF0QFFgi/QA6FVQAPQKoQAFIIqroBQPpFgBEUFghFFJtIoAALA
RVURQAAFQBYJkiiho66AO6mjgFBAXJ5ABek1lBVgH+CAApA0ACLAIZEBfImgFQh6QPIEAKICkqcgLCdJkEAEUA0BoyIIok6NAKhr
kAmztIy+ZYQIBANgQnACLEDQqwQEFTgFXoiGQUymyAsEBF4EP0FnkSKBKIoHR0igGRAXZyJAUEBRCbFWCAKgAGgA5AANEAAJ0gZE
vYAQ0AS9gAJBUVAyAAACAHsBADSCgAEAQQ7IAAmgVARRMqdAgABoRADogqL9EQPwyAJ5FRAA/AQxwukFAMoIbPoBQRAAxwAioKHc
BADybBDB5AN4oAAi/wBoAAIqRdAXZJwHnQJjggAoJICggLAIAAoL2lAUwigH00aUUQBT6Ts+AoQUANApA8xQXKKBOgh0ooQAWIsU
CE+AL6AnpQJgUDkPpFFEUUWJCKigdKou085AUBQi7SU/wFAAVIRVUACVUIos6E2oAeQFEJ2ooAAQFFTyKLATQKfUAURcgQyQA/QP
wAAD9A/4B5AgAH8AAmgWbEJwKohkRUAADQHk8mjyAHQgAgLlD/T4CoGQAIgCEBdiZAVD4AT2Bll8yoAH0ABfaaADJAD0ACoQ6BSI
KKRCILkiZFFAiAIqgCZQUTysUPIioBEX9AAigZD6gGT9RRRBBTJOkA0BoCAAGwACGhT4CIH+AbAAANHkAIgAToEAEBfiBngUO9gg
f0aQgAEARUQABQQA+AICKnkDZARUMqkA2ACT0HwQAPQqBsA8h0kQNGwASbUQTswYAEFwKhgEBF+gIKkAAgBCCCf0qAL8RYbBAAA8
gHIKAfqAKQgAGRQgKCKAAEBfgQihAAUTaxQgE6Bfw7IKHlUUAP8AhFBQgAHaigAomhRSHZPoL0bEiixUUA0QVRQAD6RRYJFAEUFN
poUURdAdrEIqrOjtJ1yoGTAAptNCiiZ5X4AACiQ0oonwBciZXQpsgeQCHtAaQNAAZAIEA85AAAADXIAHYAJAFgZQFEh6BROzQLpA
A0ERBQT4CoQgLlIAGuQQFImRBfhtAF/tD4AaPKKy+Yz4AA0B7FDvPIQRRJ12AAdqKRIcAugQFEyoGQSAuew5ANERQJwEANYOuwA0
dgAEAAyZAnAAAAGQAA4SAsCAAfoACbRV+ESGwAAPwRQOkDILNofQABAPqAKgcCho6hEBPqxANAAfQQFModRFNAQECAAYEE7AAAiK
gqcgaOiACAgheVwAgqVA2ioKBoARUQAAEVBQBARYewSeRagGqB6AICAAAHICRQgJnkUn0EhFn/qQEihwBsAAhDCgsRQCJF/QFiel
gIs6TSqEVAFEVQgaAX8PQAAqh7IQgCp2s9qAaNAoCgGOFnoCAKGVzwi58gE6BRSekUABRQBTsBQVIs6AgAC9QFAgARU0KKIooABD
AAokIooigB+gFMgAJFFVAAyeQA7pPYKBoJ4ADjYAQIgBAACf0ACAppAF8mUOgPIABDIACSgoIgoIAABAAOjQkBcntFQRUyAAI+cA
AWIAQCdAplMcEBSIAsqKdAGkNAoiwAOjQAAAAAaBCKkSUVQBDoDIofAyCpohPoEyqQA9KgAAABgDs2AGeAABFANEQBYhEAIAaA0C
KIKGlQQCCKbRUBYip2B2ACBsAARQAEAADPFEDSBx0BANIJ+mA6FNIogkA5AMACGARRFMAgu0oH06TQgHAAbRSCoAgBegBFASdC7T
2AAgEABFAPoAJoFgAAEAAMfDIoQhCABFnsD+iABwEUEUNKGiHRAVFlIoaJxCf4sAAAgLFAMACpvlcqCztCAKCgBAXRwChAAWBCKK
IAsAAVCRRfIdQFDIKLBAF8hAACKKIoECGgVICqtPxFAEUAAAAADyoLtDQAfAFJUAX/qawEBRAF/BAUCAGQAMhORAggCw9oAuiIAq
YAFQABFQDYnQKJAFQAAhdgfoAAgCiCAGTpHzgQyC5PiT2AogBFQBUAFEUAT0AuRNKof4AgBoUAAUQ0AqdALDygCk5Q0CggKJAF2i
oAqTgBSJNgKIsA0hoBUAFSEEA0EABAXYnYC6EnWDsUAoH4AAAgk9B+r8BCB5AAQQyYAAhBTPpNhsD9ICAip5AF0gH9AiKqHkABPK
AABwi9AqAIAAIAAAghlfaAbIEAP7Q0ihPYAAAhsOoAABQ0IAAHBoAMHR+gAEAME6FBUUCbQAWBgAgAEWHQoQADQuEBYBNqEXKLwA
bIKChAJ4DvIBtZO0WKB+hoCAKLAAFiLACGBQ6VFgB+BFF0EAM8FBQioQFn0AABVJ0vlDoF/Ts/4AKgCiCigAaA8ih2EEUnCCqsIk
JQUQBScIAp2hOwWXhDQCiEBU7XtABYgLEAUMh5ENU+gKCLoDIkplBZEyuUBTOUyZAPIAT4GwACIBpPpoBUN9AdcgAAmQUEBTKACp
Bl4LoygIugQFIh+qq9iCIugiTai9CAKIoEoQANk+mQXSB5BRPIBpUUAQgKJAFEWAQRQAnQAQ0AegADyf2aAAAAAMYIAGkyoAgCoq
AAAACmTrKKgaRdJoFRUAAAAQQACH0ACCeRVntAAMewQRZ8EA6ARRFQADYGiAggACL9NAgAGAgiiaAAEA8i6IgmA1QBNqCoAgYABF
hD/AAgCC6QA6LsAgAAEAhNgAAB+EVP4ABdABsBUMEBQhFANALOCJhdCECdCqCghKAoeSG1FCAIoiqGQgKTpSCoToAUlU5FAPMJsC
AvsCbDrQoHk/xYAQIAHwihFSEBYIsFIACwQii9HRADslDoAJ2RQ0ABONqnICh/1PoqwRQDSKBpNKQAPqAoIChogGhAFNIAohAFkQ
FAgIAChBBFgggv1DyfQMr5QyKACHkymyCqkNUzwgpKgIaAAho0CggC9CGgWckSfRHgohrIKRIAoJPQKH6mgUACENgLEADQAAGOBF
0S6Qiqv6JpRANAoBBAEBQgAABAAXpDoAVPgBoPgCiQANB5ADIB0B8FOigAYBA9AAfTR0aAQXQILE0BOgJwACAoggAAACnQQ0iCAK
aAoILEAnQCCZIoKIACKbQQoAaPRAEMaN1dAnwBFE6VKByAgAAgAAAGsIoggGhQDVAx4AARQEFQAi/qcgGlNgmCLjlNAqL0QEWcgB
sAAAAWGlAAA7NFBYB7UCBOgFAABUWERYAAKuANKhDAAAvIpoRVBcooIsMkVCdLhAVfIfhsDogKCoaBf0CAKkFD6fAFUlPhoCezRd
kAgHlQVAFnZpF2ACAponZqgZAFPQfT+xAgcKosQ0AGQCB9ogbCIChACCZWAAnHIC54QBYh+AAIC/4JpQEPpkFyhzgygqB6A6EWgC
ZPYKIAuT0ggT6B3AAQVQ2CHVQWAaogjxUiAKCApkn8AAi0ACf0B5NB5UCEEFTWCCgqLO+QDInQLBNAKbDIE5AA+mgnYAALsQVBdE
EUgiiBE9KqhCdGUCCKIAAQAASelVSAiCiLAE9KACHkCAAQ0AAi+QICIKgTvkANAECGhRFQADygAAIAAdiACCgHsBFAQ8qkiAAAio
Af8AuQ/1FEigIB0B7ICAgAAQAAE0KCoayE6RAgCgAAAED6AAYgHOAADR1QAOgCAqhEVAXQGgAgCooAEFQBQIENcChORQRYCoE6F8
giwFD/AICk4SdKAAoQFgpPQToUAIBFQBSEFA8kPwF8hAAh2AZNBFCe1EA0sTKgToRRQPoodBkADjyXoFEAFiACxJsBdH1AFyIToV
UD6BOggAH0AAAA9AbBAUQBRCIBk0eQAQFCIC5E0ILlA0AAAIQFEAVP7BBUCcgGUXWQDyAGhAF0CDyU8xPS6AOqE7A0IohKAAqfQB
UAXPYgC6EAXsTnACkDPYAaAAhFAPROgWCaICkIT2BAANCRdgAUBU5NAKhAVCAAGQMgAQFBFTRoAgABs7gHoDQB5OgAABBfIAIgAA
fQAE2pzyKICIGbkBQJwAIqQDjACAACACmQEBMgAAAi+QECHlAAFNJ0oCQOTQEAQRTWKAmgPgAUwAigJ+CogAKoKkQNlIoIKgB+ns
ACcqonsFBFgAaMGAAh8UDAi+QDskFQIEAFJQIHwAUFAIQA0Q2ChBQnoh8J2CwIAAqiTrhYi9AkVN9rAIH01wqipFnYGgACAosQX6
BNm0UCegNAAcKED0AogC6IJsVfgJ8BT+wAA+gAaAIaFADygATYFJ4AElWfUBV0fUAMhDQAdHwA0ToAEUAQQX6h6AVO+gyBoTslBR
MgLBBBUhNgB5JQAQBcoaAWCCAEFDIJEFBM8Ap2Gh5BCAAZADQAqACoEBRAF6EIC8iL10oZAggSgBwqAHxd1AFBJ0CiKAZADyAAaA
DyqQUVABYfqACooGQADSRQIZ4OjQB9CAEDIGD8AD4AgmBUBRDIC6PKABAD+zRoAAARURQADyAB2ACAUD2AgJFAQVADQCiCoAgBoA
EUQAWp5RTAHkQ0igqcAQA7NCCRQBD/oAAdTkEUP0AAU0eg0IkgvkFDBgREgooik4EUAUCbIAH/VgIiwIAGhQIEAUAAgBAVQP9AAg
QDysPYoE7CAGsBAF6DtQNhoCKgChpAXBAigGulFTWFTKgHUACBP7FFPmUAFSKBCB9AAgAChpfKGkABVVDR10B0qHkAnghsBUAFQA
nRsACf0QAODoAn08oCqIZQWCcAEAAh+HQARCAC5RBZ0hoBF/wNACAAqAqaBAA1yBCIAvIhoF0JwAGeQyAAgGThAXRnIDyDODIBoB
QVDIL0honQLCcpeAFIigHWjR2AAAqQgHBogC/wChnsA+EBQVDQgQAAJ0ACwAwi9AAAHkAIs4TIBcHQAZCALBDQLoQiioqRBdJABQ
ACIoJAgAHwAAAKICgAGz8QFTXJFRUPQAQIAYDQCaOAAAQAAQPICofAUyiiAnkwASH0h9AAgGUxlRBBUAD6aFEXYB+IvxAAADAdoJ
hRJ7A0L1kBAAAANGgA/QMZAPpCAHwABYAnap0oGgAPpsO+QCCqJyaFnsAABUAF0EUIFAAnKgAAAeVFQ6X4ARIqgCxBFNIopAA2Bj
hQ/0CALEICgCh+EAAP0BRFD6sRQRZyYABFACewAADRCHtVNGCGkCHlIqgAgCQBf9IgC0/wBQBdIAAAAi7AEEBUOBQAAEBYIAAeUA
OpUBQARYhkFJUyAAeUAyABlAFQAFQAhk0ABng8gfQB5ipn+AFEAUyiiBAAIAGSAB5NBAXPCS8gopyh0CiTpdUAAACAqT+SAKIuwA
IBAPIACoBAVRDQikIdACZ8LAAMgXgCdAAbA0BnkAM/QD2H0AD9AIHYAAAUnAAB/oAAJyqKKIQ/6iAqCgAAAIL7QAgRAoHkDIAIE4
BQBEEXRkU8ovACdgAROlAQXACBoQCGiCgSH0EFQDAqAAIAEAABPpFARSAIoAgqAqLgA+AQAAAx2CgLoAgnxQAAA6AOp6WHQoBCAa
VACrgAOdAKE4CcAE2HxQBFgH0IdxQVP7ICnaKBQgB2AofSABF1hDALDQCgAACgBOwIAAXoAFTQAQ8nkAAUgAgAKfFQAIAAGEDWBB
RQ+JwguRCAqGQCiaXYAJ5BUh9BQBACGQIfUADQQDJAQPwiAGlzUMgQDQGgzxwiCwQBdCALtABUgAAAKnQPNRFAv0EUUJ/IBNgQCB
0AbX6mjQgqAqoqCLs5NEAAADQAqALo0k6XSgQ+AAAEVIoIsTKgBoEABT6AqAa7ICiLyAJPoAqKB0GeEBQQFAA9AQA0E4AAAABNKk
XIB+CABOBBUDyAQ6IABBQ/gzqoCoqAAAAIAACLpAAgAeQQEUFTXAUAPJ8AEUBBfYggAAegDsPgBEXB/YJ2aIaFDACAHIoAgE5DpQ
AiAaDyAAB8J0KonYLARQAAwBoVAA0oIRdEUAgAACoLoRFRRQ4OhQga6XsADQEIACoRRUnQAoigEOgACKBAAVNgLCAKAQQAFDRDgA
8goAIHw9AoAIGgh5UCHwRQ2f0CAIKp5QBUAA6IAZAAIlAX+xC9IBkzwAaAAIIC9ICKbP0ABKAqBkCAAEoTaByIAukD0AQPIGQToF
9AiAqdH8Af2qeSAHmEAUlBXmE7ADOQ0QAIQD9DYAsTs9AKgosIhtBRNKoATsFSACgCAE4Ai4QA2qLOwP+kSL+qEDXRoAIQDyqACi
Aon0nQKBoAAQAFDoXKomzyALAQFNdgAQAInlUBTQAnlU0oIomUBUgBFE7gAsQUAAAABAX4mlQA2KgmwAAAA+AIAB0AB+HsEBFwCo
L2gAH4Bg7CgIvk6QEwoCaNmgAJzACAfoAAqCgiKfUFFEBSBaIIvYBsAUiKTYGgBDBoBQIsESLAFRQUAh9AIKIkJwugA/6AEgQVTQ
GhFPKKBQ6/QA8gKBg9ZUFEBQOsgQCAE8AAGDagGwBUi/oIpEBU6FBFE0KvkDQAAE6CICnSQBRNAKIfoGD+wwABsUMnkACHoAPKIH
lUAAAASAoIAT9DVQD6AIQgKqAIaBO0VRADIqAAaAgaRBdoABdlAAAIT2igfEOlgGRIIAaPgLlU1RXmKgKelSYFRRIAKkAO1TYC9A
eQPoAAEAizwkICiTlQIAoLvlAFSegBRIogqE9gRUAVIKAQgoAf8AuACAC/okUEWcEANGj9ANBPIIQNEFNACHIZAWoHVFFifQRdCE
AXKAKJAAnoBQDkRUOwAAUAAPZOgE0sPIAi6EEgqABnABoABPagJqwVOAIAAAgIpBU6h5J6UEAADBAAh0gAKJsUQQ0sgCCk6BD4AA
AAqAf4AAAAf2oCBACB9WAkWn6AQIKAGADYQAwSdqCCk6AJ2EAnAeRQDoAVFANGAAIAQCAAKooAih+gZA+AAAAQADSgCwE8r8IgGl
iE7A+1UNeADhYgqifABYgAAAQANBAA/sEA6NCgIIq/EADyAAHkABEDRBAUnsQFgJ0AAgAnoF0f8AUBQnonsAOhEF+CGgA0AQDygC
CgqbEDYSgGzaZWAaAAEUA0JAXRAisLBCegUAAACez+z4mhFMgAU5MgpEzwKHSoApBJQX9A7BfKB0AsQAUAFQ+KLoQgih5BTjCz6m
QQABfYiqAQAAA7CwyCpABQAJQIIAQUAgEPYCAAAAAAB/hAAAA+mQA+AAAAQOhTR2AAAIAAKmkA7DQAAAAED5yAJFgCE9GhAAA0AA
BoVBekED4oKnkAQBRUNEKB9oAHk+gB9RRA6TCwgB/oAAAigCKEUAAOyej4AQAANgHlQACAAAGiEADXKihEABT0QAACGggEDR2oCo
CxFQVQBAIaFIGz6AAAAAukIAY4IKBo0TgAyQyKACAApAAIf2egA/A0AIvaBoEAAgpnsNghoD/BU7U8oB/pxg0IAHICABoNiBoEBR
DQAAAhtFUQEPpoBQQBdpAQAANHJ5QFPSZICoHxAVAARZ0B0ABAQGg/RpgxkJk6QAFAP0gCpogHyAAfVQBdcmgANhoQAAipBRSCAo
ZAF2gCiALkRVDrlU9gLymSKIBoAMB0Ck6SAKIqh8NBAFwgAAC4BAWAbAhoIAefQCAfp5AAAgewAhAAADyaCfQPgQ+CkA6gh3DRb8
NAAACLBTAmlQIgfQNKhgAoAGg2AABAAEFmwQ/FiaQIBAAAAIAAAikA/UwqAGlmQEU3gBIBj2AGjAGhYgoGiAaFTYHYs5SAAoGiHQ
CKigRFAEiwAgYAIfgAE68Hs+qAoAmwgKJ6UDsNU+gBs+ACoAKKBgACgAB0AQAPIAAEFMgAAaAJ7NAHs+AAE2AAKACABkURQDoEgC
+UnYB5CceAAMoCh6SbQX/EIbFAAAQF7QECbBABYgAAHwPKIKhpQTR2IKoIiBAFBFn9gfQTQKhwIAABoOQCCAKkOADPsEAMigfA0g
uQI0wAALEMgBoBQABMqAIqhAh8Aip1wdAsKICifFggEP9AVCAoChOAICiZNgoAACgBP5BZ6ImVggqHkDEVCAoigAABwaUFSgBOAB
aYQ8guBFAAAAA0BBAJ1QA0HQHs2AAbADRCAHw6OgAgAm1wAHIICLqgJ+Gl4BUVIoiH0MaFNBDQGAAEUAAARTvKCQFBDkAAnQAAAE
9AB6DQGyABAAAP0D6AAGgDRAgCKAAAAABwAAAAoIRUxwoCoKv0AAAQAlFAADsNgQ/QyBshFBFIiikAAgAi/pADRCEA6AACAEJ2Ao
AAQIAEAAAAAIBARROhVSKgASgAAGg0aQQP7AVCAEDKCqCT6B+gbQAT+wXSEAAEAggKhxsA0URAIQA2BkUggiGgM4FDQAIuk0CiCB
8AAEX4AABBABekPoB5NgNT2JBphQyeQIQ2ACLANhAACARekAFQBfokUAgKEDfIAqT6sAVJigAdGxBSIoq7QAVIQFhEUABQ7VICEV
FAAgCoQF2RFANhACEAOVToUIqGgXQhOhFmEUFD1QECEAD0H0AADogaAAAmQh9AJwfCcAZDYAEAAADRkQAAT/AKKk5BZEguAMZQAI
eQ+Cn4BoQ6A6gAApgNmhAwEBMCgoBEE0L5FBFEExjggoIBPgGBUBdIABpUAJ2ThQQ0qaAFAScCpAUSKCZFFCQRQDRAAIQAAAIcgB
AFQ0AKICgAYRUVVIiwAgAAQANAEAAPQQAADsDoD4EBQgToDsD+ABFgB7QgKioAqEFDHYAAIAAIACoABrg0gKgCgHSBAAQAAIiABk
AgAQSCB1yAAZx7EBUyfRAAAAFQMnAHYIgoICoH4AGTkABAIaANcgAH6RAaDQ0yZAA6AgEVARU8l7ICgkBQhOlBUPPIAEAXyigEAA
BQ+qh/gLs0GwPgbJ0IvQigaMgoTpUOwUToBfgTqgGwOlFnfoIAHkBCAYBTybTAL2Q0AeToAA8igqGgFTZAVFNAdCKIACgAhAIATY
AdcAY5A0eQBFAAPoAaIIH+E8hL2AABAAEUnQAToBIKAJoAPgYUEAABQTQKCAoJ8AAAAIAE6AQANKEA6QOiHw0KAKgAKAIAdAAaPa
hgAAnQAHwAA0AQ/QBfKAB7WAAigIqfoCkEBQNAAKHaKAGA8igeQAMnYAAGdBg8gH+BgAhDgCdACkD6AEInYCooCB5AngADICACAK
mbhRU+noAMgAAkoAQQNGj/gCKlXyKmg7EANGQO0gAAIB0nkAAAMpTygtTQAAgKhn0AfwZBA0hAUABf7QTeAXo0mhBYgApLwgBA8g
AEAPIaBqCDTKgACKAaRdgaoAHQAAAi9IdAKRFUIQOgCcgCiKBCAAcUIosIaQFVCCCoAoiqAvxOtgpBAUCAohehFD8IoBogGfAQBS
JOgFAv8AgHBsAMH00ARUPqgB9EWGwiKi/AVAD9ANGTsAAAAAIAeQACBADsADAAAIGgnRAIE4AANAYA4A0dAAE6AQUA0goJrK6IAI
oCY4NKAdoqACzsBBQEBQSBhfIJDCxADYuwQVANcGjRAFOQEIoCQwRQTyc1QEhpSCooCBDQKRPikERQ0KAAAQAhogAAACgAgQBVNB
wCAApoAANgBDoANnwA8nwNAik/kACIKKgAFJ0AAgAfoEABA4MChg8gAACbBAIJ+AqKAnkNCAQQFQPIoAgcJAAnQCAJo0Ach6yAgf
6AAgQNIKEAAIIB5ToAABfqAAbBAAABAOliAH6ZAGgPjbIAAAAucIAvaACggKAB5DySAToCAogqLAAAyAoiwAP0gKkBRexFAgaIIs
EP8AAU6BQ8r8SnkBUnS/oGjybyAKgIvwRf8AVDQaAAIAukP8BSdAAAoQNABA+oLoSKIB7FAmwADYBoNAAAAAAaNAAAHQAAAHQaQA
AAIAACponABCgBAAPYKCAAGjQABAAIAH0AIEA4IAGg0AGz6QDRn2AHsD6B8NABDQfAMdnwAAAIYABFhoAgAAcAEAAAAAAAD8AFAF
CECAAIBgIoH0ACAAGSCkPgAAAAToCAAfhohyBIZEAD2CgqIAToA+GgnQH6CAqeQBUIToUAQBAD4egAD4AmiAgGRMgBoFAT6gBDYA
IC7QPiBLgE9AuxNmEAIAQQyAQEUDzwmwPIaADQAThFNoJFOkAyGgDoDXYBAACICgA0Jo6aZUl0aQFIGAIAAHwAVNn6ofqyoeQWd4
ogCzoD9A6hshPgEVARQIoRU0QBUnSgAQCLEFF6Ei6ADZBBYkUANkUIEUASKBoD8EIsRYqkE+KIHYQDYTogCgAH06AAACAKgYEWAT
mAbAUIBoADQAGkDYChoAAXSQDQKB/YgB0cYIAQi6QF8oCApsETB5XgnQILAVCLEAkVFET0QUBMkAA0ACoBOg88gAs6ToCCgJjgAD
o/sUEIKCLABFD4CEJ0oqEAQBQQgCr+oukAF2gGlQAhjhUAABUhpQQVFCBrgQP4FRQgGBQ6AANABCABPooJDRDQGgNcAHQQU0AAGq
IGgTWOVFCIgKgB5OgFD50AAGAQVAOwAARBRFvoVPOAABFyCTyAgAegOhDIAIirOiIUAEAMcAgAgLEVKBOjIaQD+xIAAiiaVAVA1g
AE+IKi5QAACdAAGQiAIoH+CUAWdoAogDQDbJo0EBZhIAHwzkIC/BIAaVPa6ACCgBAAh6BYIAuyB5ANAIpCCh5NHwAyqaUARQURVD
WcCLOhAhAFggCkBQnQALPAQzAFT+QQ8i/wCIChPQAQkFBUAWAAEIfoAdEEVABSdIoBAUAwAL0kMewMAQAAFQnXaghOiAAdgCoAqQ
UAwgIqLCAmCfD4oCKYQCACLonSfQWBAAAANCgAgml0ToAnQAAHkAgAHk6ACeD/gABASLAAAADsACAIvQAAABAA0AAAH+AYUCBEUA
gJpQBBZ2KAkVBJzAFBRAIoAixDjwKZDaghpUACewAPoAAKAeQAh8BBUQA0ABDoDs2JoUFhQQ7N9GQOgMICeVAQ0AAeQURfKZQPoF
AyhADQCBwh+r8FQwAB9QQAAMJAQCABEADgNCAgsFT6ToJAMkQQXtIAFIAAkVAEAAIBoNABoNAEIaAgaAaCezTaHkJ8BD+z4AAE6A
AAITpQP7IgCh/pAAFBUAURQDsM8gdEIAsCCoRUAWAcABDIKRFiof6AAogKaDYCoqhsQgKAIHrsAU8oqgHxYCd9KhoFE0sAwAAewE
JDs7P0FAAAA6IaAANqGFiAAqAKhOkANCgLD8ETSwATIKBoBAAUANgAIBgFAADYH9AQwEAMccnRsDYABpUA0HYgGCCgAiBk0KAsRA
FAT/AKAKbAVCQF9IqC1AFQ+qEILEEAUMU+ggHIAGjQoEJkQANKAAHYApAOs8AAaBF0AJ5VJOFATQoJona/QVDQACoAQEA8goEBBF
Q4FFQAgABOw0AB2CACgaMIAIAAAAKIqAHw0IAaAQACBEQNCoKCLEEIABRAA8iAIAAaQBDQAAAIimgIBoDQEE0IAaUEAAJyHQCdQy
Aoh3kF8ifRAVCKN5SqjaGOV7TQCiRQBNAHle+A2IECAEDQCpOQFEqwACdqCpDQLOgyAEIALEIIpAUVIALAAAP9UUIAQCCChAIQAA
NKLDYCEAFUgCGihNqBCLoEnSosACcAAAgQX9AJ6RQDQKEEWdgTg0aAOCBoDyGgBfRpBCKAqKAB8DAgikAAAAAAgEDAABgCLEANCx
BD4AKbFQRdJgAUADAE9gdAABogIsCAi6ADSKAih5yAmP7Ux5APZDyghFFDSa7WdACSZUu0DAQVUigCFADXgVMcgAegAAA0IASHag
aDAoBPAAEgIoAaMnICCogvaAqgTZAMgaADoQANAIsQU0KgAHQAQAAFQIAATpAmMpA2B5U8oAY5EQN8lVBQAEAAAQEXCQU2B6gCAg
AAgCABngBAAPIiAaBA0CCqk2Z8AAf4AiiIBsyAaBAUT4sBF0n0ACKgkNAAFP9AMGzoGvYEbQAAABeRAQURVU7Tyoh2EIKEARUyaA
XoifVyBAAFRVDRpIoEVCAqSkWKh/IHYC/wCIsAgfgAsQ0oq4QggGwBSEUIQAXRE6WAfoAhoIbUUCAfAAFQBQOhDQa8kAiof4BFnS
AKIuADRADQH4oQAA0QAgpAT0v6QEPoTIAaACAQA0ezjyAAALj2k6AVOsmhCACqAIigCRSABjsAAgBAANAAAAAAB3QAF+gkMgABoA
P9AAAOgADQToDVAAAACewAOMABJ5IChoAIi/AEXyAIaIIEIGlAVAA1QUNBAAIgIvKKAAKgCh0GEABQCCAdnlAD4ApOqBkAAED6fA
AEUNCAaWe045AKfQABEFQx2Cgc4NgICAB+AhkAAidIAAoiogByAIqIBDQCAAQBBBfKCgAIsiHxAAAIQAN9oILEACbAA4DYAdG00C
gAimkBsPpptAIABAA/Tr4CEAFFSLoEVNCigCBAFWCAhpchAAFBU0ugAPoBoBFgQUFSHQKaCQDK/UPgLCIsUJyHkEFRZsABQnQfDy
CgAqaF8iCC/QDIaUAIAqLgAAQIcKCBAFAAAyBsABfxFgBE+KqAQBFADQEAPJoAAAMACnpPi6BDpYCAEBFDQEAACAH0CAAQA2AAoC
Cp+gAoiAaAFidgqKAgKCCgCRQEXoAQUBAUVKHo/AAANAAQnQAaAAicLoANACRcAKhtUAIoCAQA0HlFAFDaKAHkAEX+gBIAEARQAA
AD0inQIAKQPJ2AbRegO0CIGz+gn9ignSgbRUAKACB8QABRKqIED8ANoqTrsA/snQgIuUA3gEnAq9Jr2qfEAEANAgIsAQABF8p5RQ
ABFRAioAAACKCH0O0DIbACAAfpEA0LsAEVA+iCjfkDy2h2IsAn8EOCAEJ0AQAAMAHCoKCphQCAIeTJggE9KE7BFgKAQBdkSfVgHs
ACLkBAhoUIsRQA4AF9VBRYB5EFQgLAANBCYUUP8ASABCCLDtIoECEAgCiiKAHwEAKAqLoDR2RAUAABQ0qQgAsgIHQAEpAAD0AEAD
QToCH9qgiooAQgCKEAgE6AAAgTs0ABoAgoiLgIAGDuAIvfkwBAARQAwAAAAigIs6IQA+nZAAMAEABFAE0oCCxBQ/sUEFQA0AGqAA
BoCAAHoIKaSKdgCKCKi4xAQNnYBoBTIGAT2pAAE6QAhPQoBoACcAJVQA5VBQCAB3DtATAAAdgnxRNCmwNAAekEFiAGgFQAAhkQQ+
gACIAAokVEAmwARcIACIKgdgH0EE0KgoB0CaNdggBOgCdCAKgIB+AAGkBYJlQE7VEDsybooAaQOthDQNHkWPRDaaIQCKiwAAACbA
gAAH4CwyfqAsIkXyqGuDRDAEABYBoAhPppRdIAKHGCATapJ5BFCdcCgdE+AKQAFTSgTBoFQngFAhpN5UCBBRRIogaACAAvQHkAip
+KBBQABAACLEAXAmF0AB1AIE8igqKiAiqBx2aJ0CLA10AAACiJBQVIoCEnYAAABAA2H+ABgURAiipFDyIihAA0AbAACHPkAACACE
wToBQAAAAhPFADQuhECE6FAP7AA9gB6AAAD4QBIoAYBBRYIABvkAPw8gE6PYAHwFIikBDKgIAABMgQp2CgEAQEAD9FAAAOwNIsAI
hjkFAAAATYqfUD4BAQyoKgACKIIaNAAAIGjhFAQFQIgIAHQACHoiKBlAANoAAIcB9QIFQACdCoqKgh/QAIuSewRUEFQIBCABOgRA
NgoAekDIAGA0AaABrRA6j0QIuk8gHQAuhABTsAAAAA2EAFSGlFE+LP5EIBAWCThQAAAOMKLDSLgAAFPSRdCCpBRUF0ABAUh0bVAF
gIqQBZeDAAB7FFhOIAhAnWQFAgGsGwigoTkQgQ/6AGwDCpAFnYY7IAENfAA2QAUEBBRQNAQD+kACKCosERQgIp6oAQ1wAEAAgsBA
URBQEVIoAQACbACdAAbAADHAEP0URA2ugASAuED+ANKJAAigigAhpewRQFTRAEIAKBoAnsP7ACQAT9XR8AQ8qYFQ/wAVAANAegAN
ho8gT+TQCoLoBAUEnXkAANHQp5P7BAQX0CHaoAYOgUAgCLOkAgaAAIigJ0BoIAbNGwEFQUJ0CAgQANnACKIqAAIqAUPoghPagJn9
BNAAaRQAEDoQEXSAbAQEXaCgACLEQNAAaRZjSAB2IGghsADQJBdJ5BdIAHQCAAAQN0D9ABoXiI9EMgTAEwQUCIALCBAA+AHoDqAA
AqEBFAigaIQAF/QOMiLFAIoATg6oEVCcCKTjoAJ0AoLPSKAEIC+SAqAABDSgQABfqLhQAEA2oAmlAnRCEAX4gqLrghTuAQPhPQAA
CooEA0As5QEIBFFE+qAABAIAdKgHwXCCLPdNJOlAhA1gDASgAAChoAICFSKQAgQADXAEIKCAAHQCKYQ/QFgAGk2oEEigc8gAENAA
AAAH0AE0onYBwqAGlQUIqAeQIAcgAAAQNgikAEVIKAT0AGzQAAB0AoipoBRAAAA3gRRFAEVAAwAUEgoLoA+oHoAgIGgBRDAAZEAF
kSChA5QE8gAAAip6QABTSBADHZoQT6AAAghs0YFEVEAuygJ7CABAQEVAAgKJ0G0AABFibQNBrgAPJAA9JeAA0LOgQCIGgOgJxQMA
QACEAGgOXohAIAqACoAL2GgIcpoBSbNkA7KSEAgAKAIQIKLEPQB2s+BrgCfoCign+goEECdBAU2GlBf0gAQADQulQAAixF0AQAIv
pFVAIeQNgAuhFgB0ABBVAAQABZ1UDQLshAAACBARUIsUDQAAQA6CABPIIaU6AIBAAADQALhJ6AUEEUEgKAAQAMAQAPOABT9QRZ7B
AUAAgAHQAeQAAgAQAMHYTsDHYAHk/Q2AABg2QATSgIKgALoVDAABgAAAONABpFBQQACbUEhC9gCKCmhFBDg7AAAAEURTQJoAAJxk
AA7FE7DQAqAaAFT0CoJ5AoIug/AQqogbAFQAAAEPKogBOwUQ6AEUQQD4ACIoAAnSogAAgAAH1BAAAEVAAIENAICAAAGgCoAAAAHx
A0QAKEQFwABOwAagD0Q6AgENAAAChsBBTkAOuiAaJ0EA/s0CgsRYAHlBFhvgh0CgAZAUFiL5AAAIdKIZPIRQXaRQPgYAFQVF+BCA
EFAAAOjaiBx9BQIALgAAnQAL9ToVFCAGgICpBZ3yB+iKAewghF0h9BUwoAAoB+mOQAAFT6QRYH6TYEIAAaNAYNE6pAPwFECAAAAB
gDkAQIApBZ/aCBhQE+r7NAE7EUAxwGeAN4AAIeQAAQDVIKaIAAqf4AEAAAAAReyUANBABP0AFQCQXadCgToA6ABNKEBPCgKdIqeQ
D9AA8h/gAAqHaoCxFQAD4gACgnk+gFAAgAilQU8gAAICTAuRUAAABAAAgip9VABF/QEDQgAQUiBECB0gB8AEyvwRAAFEDtAABOgN
cAJFEECAAaEVAPIGgEBFQAABFTkAX9QAOhAwAAayAAeT/gAAB8NANp8B6IdAIBOuQUPIAGAAXSAEXPgAAAA2AKTYCB0CqACCgAQF
AAFAAi4gCACgsACAAAKigAKAEMAIAKq7MZAQgAKkAFhAAn8rOAECAqgAhAAUAAABYAJ9WAIGgUAEAgKCwBEigAaAAAAgAugBEUAA
AIAAACoAgugAOgAIAAAEAAAAAEDuABAAMY4AAgAoWAIAAACkAAgCiAIKACRQFEAAAAAC+zQCooCIAKAAACnaAEUBBCAKAAJ0AAAA
ACAKAAAAaSAihQAAATQIACiAIp6AQQAAAVAEBAAgCAgAJ0AL8QEU+9GwBAEAoKIAyAAIAKICB2AAAAcABOE7AF7QEA0AEAAAAPIA
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
__FORGE_FILE_FORGE_LAYER_PY__
  cat > "$FORGE_APP/forge/ledger.py" <<'__FORGE_FILE_FORGE_LEDGER_PY__'
"""
Selkies Forge engine - ledger

Memory booked by desktops that are on their way up.

Admission (launch.admit_memory) compares a desktop's floor with the memory
that is free right now. On its own that is fooled by two launches at once:
both see the same free memory, both are admitted, and the second one starts
into memory the first is about to use. So every admitted launch books its
floor here until it is up (or fails, or is cancelled), and admission
subtracts what other launches have booked.

The ledger is one JSON file under an fcntl lock, shared by every process.
Bookings belong to a process: one whose process has died is ignored and
dropped, so a crash can never leave memory booked forever.
"""

import os
import time

from .paths import LEDGER_JSON
from .util import FileLock, jload, jsave, pid_alive

MAX_AGE = 3 * 3600      # nothing takes this long to start; drop it if it claims to


def _live(row, now):
    return pid_alive(row.get("pid")) and now - float(row.get("ts") or 0) < MAX_AGE


def _load_live():
    now = time.time()
    data = jload(LEDGER_JSON, {})
    live = {k: v for k, v in data.items() if isinstance(v, dict) and _live(v, now)}
    return data, live


def book(job_id, mb, entry_id=None):
    with FileLock("ledger"):
        data, live = _load_live()
        live[job_id] = {"mb": int(mb), "pid": os.getpid(), "ts": time.time(),
                        "entry": entry_id}
        jsave(LEDGER_JSON, live)


def release(job_id):
    try:
        with FileLock("ledger"):
            data, live = _load_live()
            live.pop(job_id, None)
            if live != data:
                jsave(LEDGER_JSON, live)
    except Exception:
        pass


def booked(exclude=None):
    """(total MB booked by other live launches, [their bookings])."""
    _, live = _load_live()
    rows = [dict(v, job=k) for k, v in live.items() if k != exclude]
    return sum(int(r.get("mb") or 0) for r in rows), rows
__FORGE_FILE_FORGE_LEDGER_PY__
  cat > "$FORGE_APP/forge/lifecycle.py" <<'__FORGE_FILE_FORGE_LIFECYCLE_PY__'
"""
Selkies Forge engine - lifecycle

Start, stop, restart, remove, repair and reconfigure existing desktops.

Every action on a desktop holds that desktop's lock (inst-<name>), so a stop
from the CLI and a repair from the web UI can never run over each other, and
is written to the event journal *before* it runs: that is how the watchdog
knows a desktop that just exited was stopped on purpose, not crashed.
"""

import json
import re

from . import catalog, events
from .health import LaunchProblem, wait_healthy, wait_http, wait_session
from .host import host_info, image_present
from .images import ensure_layer
from .paths import CPREFIX, KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS
from .recipes import build_image_tag
from .registry import docker_instances
from .gpu import ENV_KEYS as GPU_ENV_KEYS, mode_from_container as gpu_mode_from_container
from .runner import FIXED_SCREEN_KEYS, OLD_SCREEN_KEYS, display_for, docker_run_args, parse_display_label
from .store import reg_delete, reg_load, reg_update
from .tunnels import tunnel_start, tunnel_stop
from .util import FileLock, _int_or_none, run, slug

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def _locked(name, kind, detail, fn):
    if not NAME_RE.match(name or ""):
        raise RuntimeError("bad container name")
    events.record(name, kind, detail)
    try:
        with FileLock("inst-" + name, timeout=900):
            return fn()
    except Exception as ex:
        events.record(name, kind + "-failed", str(ex)[:500])
        raise


def _screen_plan(labels, display, resolution):
    """(display, resolution, changes) for a reconfigure of a container with
    these labels. `changes` says whether the screen that would run differs
    from the one running now, so only a real change recreates it."""
    cur_display, cur_res = parse_display_label(labels.get("%s.display" % LABEL))
    running = (cur_display, cur_res)
    if (labels.get("%s.version" % LABEL) == "1.6.0" and cur_display == "fixed"
            and cur_res == "1920x1080"):
        # 1.6.0 forced every desktop onto a fixed 1920x1080, and the label
        # cannot tell that apart from choosing it. Treat it as automatic, so
        # the next recreate or repair goes back to the desktop's own default.
        cur_display = "auto"
    want_display = cur_display if display in (None, "") else str(display)
    want_res = cur_res if resolution in (None, "") else str(resolution)
    entry = catalog.BY_ID.get(labels.get("%s.entry" % LABEL))
    if display in (None, "") or not entry or entry.get("profile") == "kasm":
        return want_display, want_res, False
    # Compare the screens that would actually run, not the words for them:
    # "auto" on a desktop 1.6.0 forced to a fixed screen is a real change.
    mode, res = display_for(entry, {"display": want_display, "resolution": want_res})
    return want_display, want_res, (mode, "%dx%d" % res if res else None) != running


def instance_action(name, action, opts=None):
    """start | stop | restart | remove | tunnel | untunnel | repair, under the desktop's lock."""
    return _locked(name, action, "requested", lambda: _instance_action(name, action, opts))


def reconfigure(name, memory_mb=None, cpus=None, shm_mb=None, disk_mb=None,
                autostart=None, display=None, resolution=None, repair=False):
    """Change limits or screen mode, or repair; see _reconfigure."""
    detail = "repair" if repair else ", ".join(
        "%s=%s" % (k, v) for k, v in (("memory_mb", memory_mb), ("cpus", cpus), ("shm_mb", shm_mb),
                                      ("disk_mb", disk_mb), ("autostart", autostart),
                                      ("display", display), ("resolution", resolution))
        if v not in (None, ""))
    return _locked(name, "repair" if repair else "retune", detail,
                   lambda: _reconfigure(name, memory_mb, cpus, shm_mb, disk_mb, autostart,
                                        display, resolution, repair))


def _instance_action(name, action, opts=None):
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
    elif action == "repair":
        return _reconfigure(name, repair=True)
    else:
        raise RuntimeError("unknown action %s" % action)
    if rc != 0:
        raise RuntimeError((err or out).strip() or "docker %s failed" % action)
    return {"ok": True}


def _reconfigure(name, memory_mb=None, cpus=None, shm_mb=None, disk_mb=None,
                 autostart=None, display=None, resolution=None, repair=False):
    """Change an instance's limits, its screen mode, or repair it.

    Memory, CPU and auto-start apply live. Docker cannot change /dev/shm, the
    storage budget or the environment of a running container, so those (and
    a repair, which moves it onto the newest forge layer) recreate it on the
    same ports, environment and /config volume: files survive.
    """
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    rc, out, err = run(["docker", "inspect", name], timeout=40)
    if rc != 0:
        raise RuntimeError("no such container: %s" % name)
    c = json.loads(out)[0]
    hostcfg = c.get("HostConfig") or {}
    labels = (c.get("Config") or {}).get("Labels") or {}
    cur_shm = int((hostcfg.get("ShmSize") or 0) / (1024 * 1024))
    cur_disk = _int_or_none(labels.get("%s.disk" % LABEL))
    want_display, want_res, screen_changes = _screen_plan(labels, display, resolution)
    need_recreate = ((shm_mb and int(shm_mb) != cur_shm) or
                     (disk_mb and cur_disk and int(disk_mb) != cur_disk) or
                     repair or screen_changes)

    if not need_recreate:
        args = ["docker", "update"]
        if memory_mb:
            args += ["--memory", "%dm" % int(memory_mb),
                     "--memory-swap", "%dm" % int(memory_mb)]
        if cpus:
            args += ["--cpus", str(cpus)]
        if autostart is not None:
            args += ["--restart", "unless-stopped" if autostart else "no"]
        if len(args) > 2:
            args.append(name)
            rc, out, err = run(args, timeout=90)
            if rc != 0:
                raise RuntimeError((err or out).strip())
        return {"ok": True, "recreated": False}

    entry = catalog.BY_ID.get(labels.get("%s.entry" % LABEL))
    if not entry:
        raise RuntimeError("this container was not made by the forge")
    env = {}
    for kv in ((c.get("Config") or {}).get("Env") or []):
        k, _, v = kv.partition("=")
        env[k] = v
    # Anything the user added at launch (not ours, not the image's) is carried over.
    image_env = set()
    rc_i, out_i, _ = run(["docker", "image", "inspect", "-f", "{{json .Config.Env}}",
                          (c.get("Config") or {}).get("Image") or ""], timeout=30)
    if rc_i == 0:
        try:
            image_env = set(json.loads(out_i) or [])
        except Exception:
            pass
    ports = []
    for cport in ((str(KASM_HTTPS),) if entry["profile"] == "kasm"
                  else (str(SELKIES_HTTP), str(SELKIES_HTTPS))):
        binds = ((c.get("NetworkSettings") or {}).get("Ports") or {}).get(cport + "/tcp") or \
            (hostcfg.get("PortBindings") or {}).get(cport + "/tcp") or []
        if binds:
            ports.append(int(binds[0].get("HostPort")))
    if not ports:
        raise RuntimeError("could not read the published ports")
    restart = ((hostcfg.get("RestartPolicy") or {}).get("Name") or "no")

    plan = {
        "memory_mb": int(memory_mb or (hostcfg.get("Memory") or 0) / (1024 * 1024) or 1024),
        "cpus": float(cpus or (hostcfg.get("NanoCpus") or 0) / 1e9 or 1),
        "shm_mb": int(shm_mb or cur_shm or 256),
        "disk_mb": int(disk_mb or cur_disk or 10240),
    }
    opts = {"autostart": (restart != "no") if autostart is None else bool(autostart),
            "gpu": gpu_mode_from_container(labels, hostcfg, "%s.gpu" % LABEL),
            "seccomp_unconfined": "seccomp=unconfined" in (hostcfg.get("SecurityOpt") or []),
            "heal": labels.get("%s.heal" % LABEL) != "off"}
    if env.get("CUSTOM_USER") and env.get("PASSWORD"):
        opts["username"], opts["password"] = env["CUSTOM_USER"], env["PASSWORD"]
    if env.get("VNC_PW"):
        opts["password"] = env["VNC_PW"]
    if env.get("LC_ALL"):
        opts["locale"] = env["LC_ALL"]
    ours = ("PUID", "PGID", "TZ", "TITLE", "CUSTOM_USER", "PASSWORD", "VNC_PW", "LC_ALL",
            "MAX_RES") + FIXED_SCREEN_KEYS + OLD_SCREEN_KEYS + GPU_ENV_KEYS
    opts["env"] = ["%s=%s" % (k, v) for k, v in env.items()
                   if k not in ours and "%s=%s" % (k, v) not in image_env]
    opts["display"] = want_display if want_display in ("fit", "fixed") else "auto"
    if want_res:
        opts["resolution"] = want_res
    image = (c.get("Config") or {}).get("Image")
    if repair or entry.get("profile") != "kasm":
        # Always run on the newest forge layer; a repair rebuilds it if needed.
        base = entry["image"] if entry["kind"] == "pull" else build_image_tag(entry)
        if image_present(base):
            image = ensure_layer(entry, base)
        elif repair:
            raise RuntimeError("the desktop image %s is gone from this machine; "
                               "forge this desktop again instead" % base)
    was_running = bool((c.get("State") or {}).get("Running"))

    tunnel = (reg_load().get(name) or {}).get("tunnel")
    tunnel_stop(name)
    rc, out, err = run(["docker", "rm", "-f", name], timeout=120)
    if rc != 0:
        raise RuntimeError("could not remove the old container: %s" % (err or out).strip())
    args, _vol = docker_run_args(entry, name, ports, plan, opts, image, host_info())
    rc, out, err = run(args, timeout=180)
    if rc != 0:
        raise RuntimeError("recreate failed: %s" % (err or out).strip())
    reg_update(name, {"plan": plan, "image": image})
    if not was_running and not repair:
        run(["docker", "stop", name], timeout=120)
    elif tunnel:
        try:
            wait_healthy(name, ports[0], entry["profile"], timeout=240)
            tunnel_start(name, ports[0], mode=tunnel.get("mode", "http"))
        except Exception:
            pass
    out = {"ok": True, "recreated": True, "image": image}
    if repair:
        try:
            wait_http(name, ports[0], entry["profile"], timeout=300)
            out["session"] = wait_session(name, entry, timeout=150)
        except LaunchProblem as lp:
            out["warning"] = "%s\n%s" % (lp, (lp.detail or "")[-800:])
    return out


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


def set_idle(name, minutes):
    """Stop this desktop after `minutes` with nobody watching (0: never; None:
    follow FORGE_IDLE_STOP_MIN). Takes effect at once; nothing is recreated."""
    if not re.match(r"^[A-Za-z0-9_.-]+$", name or ""):
        raise RuntimeError("bad container name")
    if run(["docker", "inspect", "-f", "{{.Name}}", name], timeout=20)[0] != 0:
        raise RuntimeError("no such container: %s" % name)
    value = None if minutes is None or minutes == "" else max(0, int(minutes))
    reg_update(name, {"idle_stop_min": value})
    events.record(name, "idle-limit", "stop after %d idle minutes" % value if value
                  else ("never stopped for being idle" if value == 0 else "the forge default"))
    return {"name": name, "idle_stop_min": value}
__FORGE_FILE_FORGE_LIFECYCLE_PY__
  cat > "$FORGE_APP/forge/paths.py" <<'__FORGE_FILE_FORGE_PATHS_PY__'
"""
Selkies Forge engine - paths

Where everything lives, and the constants every module shares.

Layout of an install (FORGE_HOME, default ~/.selkies-forge):

    app/            what docker.sh unpacks: engine.py, forge/, web/, data/, selkies-cli
    state/          JSON state: instances, ports, events, web UI lifecycle, updates
    logs/           launch jobs, tunnels, the web UI, updates
    builds/         Dockerfiles and forge-layer build contexts
    backups/        desktop home-folder backups (tar.gz + a .json note each)
    repo/           a git clone of the project, used for updates
"""

import os
import re

VERSION = "1.9.0"

# app/forge/paths.py -> app/
APPDIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBDIR = os.path.join(APPDIR, "web")
DATADIR = os.path.join(APPDIR, "data")

ROOT = os.environ.get("FORGE_HOME") or os.path.join(os.path.expanduser("~"), ".selkies-forge")
STATE = os.path.join(ROOT, "state")
LOGDIR = os.path.join(ROOT, "logs")
JOBLOGDIR = os.path.join(LOGDIR, "jobs")
BUILDDIR = os.path.join(ROOT, "builds")
BACKUPDIR = os.path.join(ROOT, "backups")
JOBSTATEDIR = os.path.join(STATE, "jobs")
LEDGER_JSON = os.path.join(STATE, "ledger.json")

INSTANCES_JSON = os.path.join(STATE, "instances.json")
PORTS_JSON = os.path.join(STATE, "ports.json")
CACHE_JSON = os.path.join(STATE, "cache.json")
EVENTS_JSONL = os.path.join(STATE, "events.jsonl")
SSH_KEY = os.path.join(STATE, "serveo_key")
SERVER_JSON = os.path.join(STATE, "server.json")
LIFE_JSON = os.path.join(STATE, "webui-life.json")
LAST_STOP_JSON = os.path.join(STATE, "last-stop.json")
STOP_REQUEST_JSON = os.path.join(STATE, "stop-request.json")
BOOT_JSON = os.path.join(STATE, "boot.json")
UPDATE_JSON = os.path.join(STATE, "update.json")

# Docker naming: every container, image and volume the forge makes is tagged.
LABEL = "io.selkiesforge"
CPREFIX = "forge-"
IPREFIX = "selkies-forge/"

# Host ports handed to desktops, and the ports inside the images.
PORT_LO, PORT_HI = 31000, 44000
SELKIES_HTTP, SELKIES_HTTPS, KASM_HTTPS = 3000, 3001, 6901
# Selkies' streaming websocket inside the container (nginx proxies /api to it):
# one established connection per open browser tab.
SELKIES_WS = 8082

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
__FORGE_FILE_FORGE_PATHS_PY__
  cat > "$FORGE_APP/forge/ports.py" <<'__FORGE_FILE_FORGE_PORTS_PY__'
"""
Selkies Forge engine - ports

Free host port allocation with short-lived reservations.
"""

import random
import re
import socket
import time

from .paths import PORTS_JSON, PORT_HI, PORT_LO
from .util import FileLock, jload, jsave, run


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
__FORGE_FILE_FORGE_PORTS_PY__
  cat > "$FORGE_APP/forge/recipes.py" <<'__FORGE_FILE_FORGE_RECIPES_PY__'
"""
Selkies Forge engine - recipes

Build recipes: install scripts, startwm.sh and Dockerfiles for built desktops.
"""

import base64
import re

from . import layer
from .paths import IPREFIX, LABEL, VERSION


INSTALL_SH = {
    "apt": """
export DEBIAN_FRONTEND=noninteractive
echo 'Acquire::Retries "6";' > /etc/apt/apt.conf.d/80-forge-retries
echo ">> forge: apt-get update"
for i in 1 2 3; do apt-get update -qq && break; echo ">> forge: apt-get update failed, retry $i"; sleep $((i * 5)); done
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
echo "retries=10" >> /etc/dnf/dnf.conf 2>/dev/null || true
if ! dnf install -y --setopt=install_weak_deps=False --skip-broken --skip-unavailable $PKGS; then
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
for i in 1 2 3; do apk update >/dev/null 2>&1 && break; sleep $((i * 5)); done
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
        # A bare window manager starts on a black root window: paint the forge
        # wallpaper (twice: some window managers paint over it as they start).
        out.append('(for d in 2 6; do sleep $d; command -v feh >/dev/null 2>&1 && '
                   'feh --no-fehbg --bg-fill /usr/local/share/forge/wallpaper.jpg 2>/dev/null; done) &')
        # Open a terminal, unless the seeded config (i3, bspwm) already opened one.
        out.append('(sleep 4; pgrep -u "$(id -u)" -x %s >/dev/null 2>&1 || '
                   '{ command -v %s >/dev/null 2>&1 && %s >/dev/null 2>&1; } &) &'
                   % (term, term, term))

    out.append(layer.supervised_session(rec["session"]))
    return "\n".join(out) + "\n"


def gen_dockerfile(entry):
    rec = entry["recipe"]
    inst = base64.b64encode(gen_install_sh(entry).encode()).decode()
    df = [
        "FROM %s" % rec["image"],
        'LABEL %s.entry="%s"' % (LABEL, entry["id"]),
        'LABEL %s.builder="selkies-forge %s"' % (LABEL, VERSION),
        'ENV TITLE="%s"' % entry["name"].replace('"', ""),
        "RUN printf '%%s' '%s' | base64 -d > /tmp/forge-install.sh \\\n"
        "    && chmod +x /tmp/forge-install.sh \\\n"
        "    && /tmp/forge-install.sh \\\n"
        "    && rm -f /tmp/forge-install.sh" % inst,
        "EXPOSE 3000 3001",
        "VOLUME /config",
    ]
    return "\n".join(df) + "\n"


def build_image_tag(entry):
    return "%s%s:latest" % (IPREFIX, entry["id"])
__FORGE_FILE_FORGE_RECIPES_PY__
  cat > "$FORGE_APP/forge/registry.py" <<'__FORGE_FILE_FORGE_REGISTRY_PY__'
"""
Selkies Forge engine - registry

The live view of every desktop, read from Docker labels.
"""

import json

from . import catalog
from .info import public_entry
from .paths import KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS
from .store import reg_load
from .tunnels import tunnel_status
from .watchdog import idle_limit, session_health
from .util import _int_or_none, run


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
        env = {}
        for kv in ((c.get("Config") or {}).get("Env") or []):
            k, _, v = kv.partition("=")
            env[k] = v
        if env.get("CUSTOM_USER") and env.get("PASSWORD"):
            auth = {"user": env["CUSTOM_USER"], "password": env["PASSWORD"]}
        elif env.get("VNC_PW"):
            auth = {"user": "kasm_user", "password": env["VNC_PW"]}
        else:
            auth = None
        restart = ((hostcfg.get("RestartPolicy") or {}).get("Name") or "no")
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
            "display": labels.get("%s.display" % LABEL) or "",
            "heal": labels.get("%s.heal" % LABEL) != "off",
            "session": session_health(name) if state.get("Running") else None,
            # minutes unwatched before the watchdog stops it (0: never)
            "idle_stop_min": idle_limit(name, reg),
            "autostart": restart in ("always", "unless-stopped", "on-failure"),
            "restart_policy": restart,
            "auth": auth,
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
__FORGE_FILE_FORGE_REGISTRY_PY__
  cat > "$FORGE_APP/forge/runner.py" <<'__FORGE_FILE_FORGE_RUNNER_PY__'
"""
Selkies Forge engine - runner

docker run: arguments, screen modes, and a run that fixes the usual refusals.
"""

import os
import re
import shlex
import time
import uuid

from . import gpu
from .host import tz_name
from .paths import CPREFIX, KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS, VERSION
from .ports import alloc_ports, release_port_reservation
from .util import clamp, run, slug


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


DISPLAY_MODES = ("auto", "fit", "fixed")
RES_RE = re.compile(r"^\s*(\d{3,5})\s*[xX\u00d7]\s*(\d{3,5})\s*$")


def display_for(entry, opts):
    """('fit', None) or ('fixed', (w, h)) for this launch.

    fit    the desktop follows your browser window (Selkies resizes the screen).
           On a phone, a HiDPI or a 4K screen the forge layer's screen guard
           keeps it at 96 DPI and about 1920 wide, and scales it
    fixed  the screen stays one size and Selkies scales it into the window;
           for window managers that cannot cope with the screen changing size
           under them, so nothing can ever end up below the bottom edge
    """
    if entry.get("profile") == "kasm":
        return "fit", None
    mode = str(opts.get("display") or "auto").lower()
    if mode not in DISPLAY_MODES:
        mode = "auto"
    if mode == "auto":
        mode = entry.get("display") or "fit"
    if mode != "fixed":
        return "fit", None
    m = RES_RE.match(str(opts.get("resolution") or ""))
    w, h = (int(m.group(1)), int(m.group(2))) if m else (1920, 1080)
    return "fixed", (int(clamp(w, 800, 3840)), int(clamp(h, 600, 2160)))


# A fixed screen, held whatever the browser asks. The server overrides any
# size the client wants, and the DPI is locked at 96: in manual mode the
# client would otherwise push its own scaling DPI (192 from a 4K screen)
# onto a 1920x1080 desktop. "|locked" keeps Selkies' menu from undoing it.
FIXED_SCREEN_KEYS = ("SELKIES_MANUAL_RESOLUTION", "SELKIES_MANUAL_WIDTH",
                     "SELKIES_MANUAL_HEIGHT", "SELKIES_SCALING_DPI")
# Set by 1.6.0 only; listed so a recreate never carries it over.
OLD_SCREEN_KEYS = ("SELKIES_USE_CSS_SCALING",)


def fixed_screen_env(res):
    w, h = res
    return ["-e", "SELKIES_MANUAL_RESOLUTION=true|locked",
            "-e", "SELKIES_MANUAL_WIDTH=%d" % w,
            "-e", "SELKIES_MANUAL_HEIGHT=%d" % h,
            "-e", "SELKIES_SCALING_DPI=96"]


def parse_display_label(txt):
    """'fixed:1920x1080' -> ('fixed', '1920x1080'); 'fit' -> ('fit', None)."""
    txt = str(txt or "")
    if txt.startswith("fixed"):
        return "fixed", (txt.split(":", 1)[1] if ":" in txt else "1920x1080")
    return ("fit" if txt == "fit" else "auto"), None


def docker_run_args(entry, name, ports, plan, opts, image, host):
    prof = entry.get("profile", "selkies")
    args = ["docker", "run", "-d", "--name", name,
            "--hostname", slug(entry["family"])[:20] or "forge",
            # Off by default: a desktop should only start when you start it.
            # "unless-stopped" made every one of them come back whenever
            # Docker (or the machine) restarted.
            "--restart", "unless-stopped" if opts.get("autostart") else "no",
            "--shm-size", "%dm" % int(plan["shm_mb"]),
            "--label", "%s.entry=%s" % (LABEL, entry["id"]),
            "--label", "%s.title=%s" % (LABEL, entry["name"]),
            "--label", "%s.family=%s" % (LABEL, entry["family"]),
            "--label", "%s.glyph=%s" % (LABEL, entry["glyph"]),
            "--label", "%s.de=%s" % (LABEL, entry["de_label"]),
            "--label", "%s.profile=%s" % (LABEL, prof),
            "--label", "%s.version=%s" % (LABEL, VERSION),
            "--label", "%s.disk=%d" % (LABEL, int(plan["disk_mb"])),
            # Restart after a crash while the forge is watching (see watchdog.py).
            "--label", "%s.heal=%s" % (LABEL, "off" if opts.get("heal") is False else "on"),
            ]
    if opts.get("job_id"):
        # Which launch made it: recovery after a crash removes a half-made
        # desktop only if this matches the job that died.
        args += ["--label", "%s.job=%s" % (LABEL, opts["job_id"])]
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

    # GPU Smart Passthrough (gpu.py). The launch hands over a checked plan;
    # a recreate asks for one here. No "gpu" option at all means off.
    gp = opts.get("gpu_plan")
    if gp is None and gpu.normalize_mode(opts.get("gpu", False)) != "off":
        gp = gpu.plan(opts.get("gpu"), image, host, profile=prof,
                      tried=opts.get("gpu_tried") or (), want=opts.get("gpu_device"))
    args += ["--label", "%s.gpu=%s" % (LABEL, (gp or {}).get("label", "off"))]
    args += gpu.docker_bits(gp)
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
        mode, res = display_for(entry, opts)
        args += ["--label", "%s.display=%s" % (LABEL, "fixed:%dx%d" % res if res else "fit")]
        if res:
            args += fixed_screen_env(res)
        # Xvfb's default virtual screen is 15360x8640: a full-screen
        # wallpaper alone is half a gigabyte, enough to get a 1 GB desktop
        # OOM-killed. 4K is the largest screen anyone will stream.
        args += ["-e", "MAX_RES=3840x2160"]
        if opts.get("username") and opts.get("password"):
            args += ["-e", "CUSTOM_USER=%s" % opts["username"],
                     "-e", "PASSWORD=%s" % opts["password"]]
        if opts.get("locale"):
            args += ["-e", "LC_ALL=%s" % opts["locale"]]
    for kv in opts.get("env", []) or []:
        args += ["-e", kv]
    args.append(image)
    return args, vol


RUN_PORT_ERR = re.compile(r"port is already allocated|address already in use|bind for", re.I)
RUN_NAME_ERR = re.compile(r"is already in use by container|Conflict\. The container name", re.I)
RUN_QUOTA_ERR = re.compile(r"storage-opt|--storage-opt|quota", re.I)
RUN_CPU_ERR = re.compile(r"range of CPUs is from", re.I)


def docker_run_resilient(entry, cname, plan, opts, image, host, job, want_ports=None):
    """docker run, fixing the usual reasons it refuses: ports, names, quotas."""
    nports = 1 if entry["profile"] == "kasm" else 2
    ports = alloc_ports(nports, want=want_ports)
    host = dict(host)
    for attempt in range(5):
        job.check()
        args, vol = docker_run_args(entry, cname, ports, plan, opts, image, host)
        job.log("$ " + " ".join(shlex.quote(a) for a in args))
        rc, out, err = run(args, timeout=180)
        if rc == 0:
            return cname, ports, vol, out.strip()
        msg = (err.strip() or out.strip())
        job.log("docker run refused: %s" % msg.splitlines()[-1] if msg else "docker run refused",
                "err")
        run(["docker", "rm", "-f", cname], timeout=60)
        if RUN_PORT_ERR.search(msg):
            release_port_reservation(ports)
            ports = alloc_ports(nports)
            job.log("auto-fix  : that port was taken, moving to %s"
                    % ", ".join(str(p) for p in ports))
        elif RUN_NAME_ERR.search(msg):
            cname = container_name_for(entry, cname + "-%d" % (attempt + 2))
            job.log("auto-fix  : that name was taken, using %s" % cname)
        elif RUN_QUOTA_ERR.search(msg) and host.get("quota_support"):
            host["quota_support"] = False
            job.log("auto-fix  : this storage driver refused a disk quota; tracking the "
                    "budget instead of enforcing it")
        elif RUN_CPU_ERR.search(msg):
            plan["cpus"] = float(max(1, host.get("cpus", 1)))
            job.log("auto-fix  : capping CPUs at %s" % plan["cpus"])
        elif "no such image" in msg.lower() or "unable to find image" in msg.lower():
            raise RuntimeError("docker run failed: %s" % msg)
        elif attempt < 2:
            job.log("auto-fix  : retrying in a moment")
            time.sleep(3 + attempt * 3)
        else:
            release_port_reservation(ports)
            raise RuntimeError("docker run failed: %s" % msg)
    release_port_reservation(ports)
    raise RuntimeError("docker run kept failing; see the log above")
__FORGE_FILE_FORGE_RUNNER_PY__
  cat > "$FORGE_APP/forge/scheduler.py" <<'__FORGE_FILE_FORGE_SCHEDULER_PY__'
"""
Selkies Forge engine - scheduler

Heavy work is rationed so a small machine is never flattened by it. Building a
desktop (package installs) is the most expensive thing the forge does, then
pulling images, then the first boot of a desktop. Each has a number of slots:

    build   FORGE_MAX_BUILDS  default 1
    pull    FORGE_MAX_PULLS   default 2
    boot    FORGE_MAX_BOOTS   default 2

A slot is an fcntl lock file under state/slots/, so the limits hold across
every process: the web UI, `selkies-cli`, and a second web UI if you start
one. A job waiting for a slot shows as "queued" and can be cancelled while it
waits. Locks are released by the kernel if a process dies, so a crash can
never leave a slot stuck.
"""

import fcntl
import os
import time

from contextlib import contextmanager

from .paths import STATE
from .util import ensure_dirs

DEFAULTS = {"build": 1, "pull": 2, "boot": 2}
ENV = {"build": "FORGE_MAX_BUILDS", "pull": "FORGE_MAX_PULLS", "boot": "FORGE_MAX_BOOTS"}
LABELS = {"build": "another desktop is building", "pull": "other downloads are running",
          "boot": "other desktops are starting"}


def limit(kind):
    try:
        return max(1, int(os.environ.get(ENV[kind], DEFAULTS[kind])))
    except (ValueError, KeyError):
        return DEFAULTS.get(kind, 1)


def _slot_dir():
    d = os.path.join(STATE, "slots")
    ensure_dirs()
    os.makedirs(d, exist_ok=True)
    return d


def _try_take(kind):
    d = _slot_dir()
    for i in range(limit(kind)):
        fh = open(os.path.join(d, "%s-%d.lock" % (kind, i)), "a+")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fh.seek(0)
            fh.truncate()
            fh.write("%d %d\n" % (os.getpid(), int(time.time())))
            fh.flush()
            return fh
        except OSError:
            fh.close()
    return None


def busy(kind):
    """How many slots of this kind are taken right now (by anyone)."""
    d = _slot_dir()
    n = 0
    for i in range(limit(kind)):
        with open(os.path.join(d, "%s-%d.lock" % (kind, i)), "a+") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
            except OSError:
                n += 1
    return n


@contextmanager
def slot(kind, job=None, poll=1.0):
    """Hold one `kind` slot for the duration of the block, queueing if needed."""
    fh = _try_take(kind)
    if fh is None and job is not None:
        prev_phase = job.phase
        job.set_phase("queued", "Queued: %s (%d at a time)" % (LABELS.get(kind, kind), limit(kind)))
        job.log("queued   : %s; waiting for a free %s slot" % (LABELS.get(kind, kind), kind))
        t0 = time.time()
        while fh is None:
            job.check()
            time.sleep(poll)
            fh = _try_take(kind)
        job.log("queued   : got a %s slot after %ds" % (kind, int(time.time() - t0)))
        job.phase = prev_phase
    while fh is None:
        time.sleep(poll)
        fh = _try_take(kind)
    try:
        yield
    finally:
        try:
            fcntl.flock(fh, fcntl.LOCK_UN)
        finally:
            fh.close()


def status():
    return {k: {"limit": limit(k), "busy": busy(k)} for k in DEFAULTS}
__FORGE_FILE_FORGE_SCHEDULER_PY__
  cat > "$FORGE_APP/forge/server.py" <<'__FORGE_FILE_FORGE_SERVER_PY__'
"""
Selkies Forge engine - server

The web UI's HTTP server and JSON/SSE API.
"""

import base64
import errno
import json
import os
import re
import signal
import sys
import threading
import time
import urllib.parse

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import catalog, events, scheduler, space, updates
from .doctor import cli_doctor
from .health import container_logs
from .host import host_info
from .info import entry_info, public_entry, shots_index
from . import backups
from .jobs import Job, all_jobs, cancel_foreign, job_get, job_put, jobs_running, read_job_states
from .watchdog import PRESSURE, WATCHDOG, reconcile, recover_interrupted
from .launch import launch
from .lifecycle import instance_action, reconfigure, set_idle
from .paths import (
    WEBDIR,
    KASM_HTTPS,
    LABEL,
    LAST_STOP_JSON,
    LIFE_JSON,
    SELKIES_HTTP,
    SERVER_JSON,
    STOP_REQUEST_JSON,
    VERSION,
)
from .recipes import gen_dockerfile, gen_startwm
from .registry import docker_instances
from .smart import TASTE_BLURB, plan_resources, recommend
from .stats import STATS
from .terminal import term_get, term_open
from .tunnels import tunnel_start, tunnel_stop
from .updates import (
    _update_loop,
    check_update,
    installed_payload,
    restart_webui_detached,
    update_report,
)
from .util import _int_or_none, clamp, ensure_dirs, jload, jsave, run
from .webui import (
    analyze_life,
    boot_disable,
    boot_enable,
    boot_id,
    boot_report,
    dismiss_last_stop,
    host_going_down,
    last_stop_report,
    running_desktop_names,
)


MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml",
        ".json": "application/json", ".ico": "image/x-icon",
        ".png": "image/png", ".woff2": "font/woff2"}


class Handler(BaseHTTPRequestHandler):
    server_version = "SelkiesForge/" + VERSION
    protocol_version = "HTTP/1.1"
    loopback_only = True

    # -- plumbing ---------------------------------------------------------
    def log_message(self, fmt, *args):
        if os.environ.get("FORGE_HTTP_LOG"):
            sys.stderr.write("[http] %s\n" % (fmt % args))

    LOOPBACK_HOSTS = ("localhost", "127.0.0.1", "[::1]", "::1")

    def _guard(self, post):
        """Refuse requests a web page on another site could forge.

        * Origin: browsers send it on cross-site requests; it must match the
          address the UI is served on.
        * POST bodies must be JSON: a cross-site page can only send JSON after
          a CORS preflight, which this server never approves.
        * Host: a UI listening on localhost only answers to localhost names,
          which stops DNS-rebinding pages from reading the API. A UI bound
          beyond localhost answers to any name and has no access control.
        Returns an error message, or None when the request is fine.
        """
        host = (self.headers.get("Host") or "").strip().lower()
        if host.startswith("["):
            hostname = host.split("]", 1)[0] + "]"
        else:
            hostname = host.rsplit(":", 1)[0] if ":" in host else host
        if self.loopback_only and hostname and hostname not in self.LOOPBACK_HOSTS:
            return "this web UI only answers on localhost"
        origin = self.headers.get("Origin")
        if origin is not None:
            netloc = urllib.parse.urlsplit(origin).netloc.lower() if origin != "null" else ""
            if netloc != host:
                return "cross-site request refused"
        if post:
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":
                return "POST requests must send Content-Type: application/json"
        return None

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
        if route in ("/app.css", "/app.js", "/term.js", "/logos.js", "/brands.js",
                     "/favicon.ico"):
            return self._static(route.lstrip("/"))
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        why = self._guard(post=False)
        if why:
            return self._err(403, why)
        try:
            return self._api_get(route)
        except Exception as ex:
            return self._err(500, ex)

    def do_POST(self):
        route = self._route()
        if not route.startswith("/api/"):
            return self._err(404, "no such path")
        why = self._guard(post=True)
        if why:
            return self._err(403, why)
        try:
            return self._api_post(route, self._body())
        except Exception as ex:
            return self._err(500, ex)

    static_cache = {}

    def _static(self, name):
        data = self.static_cache.get(name)
        if data is None:
            path = os.path.join(WEBDIR, name)
            if not os.path.isfile(path):
                return self._err(404, "%s missing" % name)
            with open(path, "rb") as fh:
                data = fh.read()
        ext = os.path.splitext(name)[1]
        return self._send(200, data, MIME.get(ext, "application/octet-stream"))

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
                "shots": shots_index(),
                "instances": docker_instances(),
                "counts": {"total": len(catalog.CATALOG),
                           "runnable": sum(1 for e in catalog.CATALOG
                                           if host["arch"] in e["arches"])},
            })
        if route == "/api/host":
            out = dict(host_info(fresh=True))
            out["pressure"] = dict(PRESSURE)
            return self._send(200, out)
        if route == "/api/gpu":
            from .gpu import report as gpu_report
            return self._send(200, gpu_report(fresh=True))
        if route == "/api/lifecycle":
            return self._send(200, {"last_stop": last_stop_report(), "boot": boot_report()})
        if route == "/api/update":
            return self._send(200, update_report())
        if route == "/api/doctor":
            return self._send(200, cli_doctor())
        if route == "/api/instances":
            return self._send(200, {"instances": docker_instances()})
        if route == "/api/stats":
            return self._send(200, {"stats": STATS.report(), "host": host_info()})
        if route == "/api/jobs":
            # Every job on this machine: this web UI's, and selkies-cli's.
            return self._send(200, {"jobs": all_jobs()})
        m = re.match(r"^/api/job/([0-9a-f]+)$", route)
        if m:
            job = job_get(m.group(1))
            if job:
                return self._send(200, job.snapshot())
            st = next((j for j in read_job_states() if j.get("id") == m.group(1)), None)
            return self._send(200, dict(st, foreign=True)) if st else self._err(404, "no such job")
        if route == "/api/backups":
            return self._send(200, {"backups": backups.list_backups(self._query().get("name") or None)})
        m = re.match(r"^/api/job/([0-9a-f]+)/events$", route)
        if m:
            return self._stream_job(m.group(1))
        m = re.match(r"^/api/term/([0-9a-f]+)/stream$", route)
        if m:
            return self._stream_term(m.group(1))
        m = re.match(r"^/api/info/([A-Za-z0-9_.-]+)$", route)
        if m:
            e = catalog.BY_ID.get(m.group(1))
            if not e:
                return self._err(404, "no such entry")
            return self._send(200, entry_info(e))
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
            return self._send(200, {"logs": container_logs(m.group(1), min(2000, tail)),
                                    "events": events.recent(m.group(1), limit=40)})
        if route == "/api/events":
            q = self._query()
            return self._send(200, {"events": events.recent(q.get("name") or None,
                                                            limit=min(500, _int_or_none(q.get("limit")) or 100))})
        if route == "/api/space":
            return self._send(200, space.report())
        if route == "/api/scheduler":
            return self._send(200, {"slots": scheduler.status(),
                                    "jobs": [j.snapshot() for j in jobs_running()]})
        return self._err(404, "no such endpoint")

    def _api_post(self, route, body):
        m = re.match(r"^/api/job/([0-9a-f]+)/cancel$", route)
        if m:
            job = job_get(m.group(1))
            if not job:
                # A launch running in a terminal: it cancels on SIGINT like Ctrl-C.
                return self._send(200, {"cancelled": cancel_foreign(m.group(1)), "foreign": True})
            return self._send(200, {"cancelled": job.cancel(), "job": job.snapshot()})
        m = re.match(r"^/api/instance/([A-Za-z0-9_.-]+)/(backup|clone|idle)$", route)
        if m:
            name, what = m.group(1), m.group(2)
            if what == "idle":
                mins = body.get("minutes")
                return self._send(200, set_idle(name, None if mins in (None, "") else int(mins)))
            if what == "backup":
                job = job_put(Job("backup", name, "Back up %s" % name))
                return self._send(200, {"job": _run_job(job, backups.backup, name,
                                                        include_cache=bool(body.get("include_cache")),
                                                        job=job)})
            job = job_put(Job("clone", name, "Clone %s" % name))
            return self._send(200, {"job": _run_job(job, backups.clone, name,
                                                    new_name=body.get("name") or None,
                                                    tunnel=bool(body.get("tunnel")), job=job)})
        if route == "/api/backups/restore":
            name, file = body.get("name") or "", body.get("file") or ""
            job = job_put(Job("restore", name, "Restore %s" % name))
            return self._send(200, {"job": _run_job(job, backups.restore, name, file, job=job)})
        if route == "/api/backups/clone":
            job = job_put(Job("clone", None, "New desktop from %s" % body.get("file")))
            return self._send(200, {"job": _run_job(job, backups.clone, None,
                                                    new_name=body.get("name") or None,
                                                    from_backup=body.get("file") or "", job=job)})
        if route == "/api/backups/delete":
            return self._send(200, backups.delete_backup(body.get("file") or ""))
        if route == "/api/space/clean":
            return self._send(200, space.clean(everything=bool(body.get("all")),
                                               volumes=bool(body.get("volumes")),
                                               dry_run=bool(body.get("dry_run"))))
        if route == "/api/update/check":
            check_update(install=True)
            return self._send(200, update_report())
        if route == "/api/update/restart":
            restart_webui_detached()
            return self._send(200, {"ok": True})
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
            # /dev/shm is a ceiling, not a reservation: up to half the RAM.
            plan["shm_mb"] = int(clamp(plan["shm_mb"], 64, max(4096, host["mem_total_mb"] // 2)))
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
            return self._send(200, reconfigure(
                m.group(1), body.get("memory_mb"), body.get("cpus"), body.get("shm_mb"),
                body.get("disk_mb"), body.get("autostart"), body.get("display"),
                body.get("resolution")))
        if route == "/api/autostart-ui":
            srv = jload(SERVER_JSON, {}) or {}
            if body.get("enable"):
                return self._send(200, boot_enable(srv.get("port") or 8787,
                                                   srv.get("bind") or "127.0.0.1",
                                                   bool(srv.get("tunnel"))))
            return self._send(200, boot_disable())
        if route == "/api/restore":
            names = (last_stop_report() or {}).get("restore") or []
            started, errors = [], {}
            for n in names:
                try:
                    instance_action(n, "start")
                    started.append(n)
                except Exception as ex:
                    errors[n] = str(ex)
            dismiss_last_stop()
            return self._send(200, {"started": started, "errors": errors})
        if route == "/api/last-stop/dismiss":
            return self._send(200, dismiss_last_stop())
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


def _run_job(job, fn, *args, **kwargs):
    """Run fn in a thread as `job`; failures land in the job, not the request."""
    def work():
        try:
            fn(*args, **kwargs)
        except Exception as ex:
            if job.status == "running":
                job.fail(str(ex))
    job.thread = threading.Thread(target=work, daemon=True)
    job.thread.start()
    return job.snapshot()


def serve(bind="127.0.0.1", port=8787, open_tunnel=False, quiet=False):
    ensure_dirs()
    os.environ["FORGE_JOB_OWNER"] = "server"
    loopback = bind in ("127.0.0.1", "localhost", "::1")
    Handler.loopback_only = loopback

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
    # Forget desktops that were removed behind our back, then keep watching.
    try:
        reconcile()
        recover_interrupted()          # launches this web UI was running when it stopped
    except Exception:
        pass
    WATCHDOG.start()

    updates.SERVE_PAYLOAD = installed_payload()
    for name in ("index.html", "app.css", "app.js", "term.js", "logos.js", "brands.js"):
        try:
            with open(os.path.join(WEBDIR, name), "rb") as fh:
                Handler.static_cache[name] = fh.read()
        except OSError:
            pass
    threading.Thread(target=_update_loop, daemon=True).start()

    url = "http://%s:%d/" % ("localhost" if loopback else bind, port)
    info = {"pid": os.getpid(), "port": port, "bind": bind, "url": url,
            "started": time.time(), "version": VERSION,
            "payload": updates.SERVE_PAYLOAD}
    jsave(SERVER_JSON, info)

    # Keep a record of this run so the next CLI start can say how it ended.
    prev = jload(LIFE_JSON, None)
    if prev and prev.get("pid") != os.getpid():
        rep = analyze_life(prev)
        if rep:
            rep["recorded"] = time.time()
            jsave(LAST_STOP_JSON, rep)
    life = {"pid": os.getpid(), "started": time.time(), "heartbeat": time.time(),
            "boot_id": boot_id(), "port": port, "bind": bind,
            "boot_start": os.environ.get("FORGE_BOOT") == "1",
            "desktops_running": running_desktop_names(), "stopped": None}
    jsave(LIFE_JSON, life)
    stop_state = {"reason": None, "detail": ""}

    def heartbeat():
        while True:
            time.sleep(20)
            try:
                life["heartbeat"] = time.time()
                life["desktops_running"] = running_desktop_names()
                jsave(LIFE_JSON, life)
            except Exception:
                pass
    threading.Thread(target=heartbeat, daemon=True).start()

    def on_signal(signum, _frame):
        req = jload(STOP_REQUEST_JSON, {}) or {}
        if req.get("pid") == os.getpid() and time.time() - float(req.get("at") or 0) < 120:
            stop_state["reason"] = req.get("reason") or "user"
        else:
            down = host_going_down()
            if down:
                stop_state["reason"] = "host-" + down
            elif os.environ.get("INVOCATION_ID") and signum == signal.SIGTERM:
                stop_state["reason"] = "service"     # systemctl --user stop
            else:
                stop_state["reason"] = "signal"
            stop_state["detail"] = ("another program sent it %s"
                                    % ("SIGTERM" if signum == signal.SIGTERM else "SIGHUP"))
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, on_signal)
        except (ValueError, OSError):
            pass

    tun = None
    if open_tunnel:
        try:
            tun = tunnel_start("__webui__", port, mode="http")
            info["tunnel"] = tun["url"]
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
        stop_state["reason"] = stop_state["reason"] or "ctrl-c"
    except Exception as ex:
        stop_state["reason"] = "error"
        stop_state["detail"] = "%s: %s" % (type(ex).__name__, ex)
        raise
    finally:
        try:
            life["stopped"] = {"reason": stop_state["reason"] or "signal",
                               "at": time.time(), "detail": stop_state["detail"]}
            life["heartbeat"] = time.time()
            jsave(LIFE_JSON, life)
            try:
                os.remove(STOP_REQUEST_JSON)
            except OSError:
                pass
        except Exception:
            pass
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
__FORGE_FILE_FORGE_SERVER_PY__
  cat > "$FORGE_APP/forge/smart.py" <<'__FORGE_FILE_FORGE_SMART_PY__'
"""
Selkies Forge engine - smart

The smart chooser: scores catalog entries against this machine and a taste.
"""

from . import catalog
from .host import host_info
from .info import public_entry
from .util import clamp, human_mb


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


SHM_DEFAULT_MB = 1024


def plan_resources(e, host, generous=False):
    """Pick cpu/memory/shm/disk for this entry on this host."""
    avail = max(512, host["mem_avail_mb"])
    share = 0.70 if generous else 0.55
    mem = clamp(e["ram_rec"], e["ram_min"], int(avail * share))
    mem = int(max(e["ram_min"], round(mem / 256.0) * 256))
    cores = max(1.0, float(host["cpus"]))
    cpus = clamp(e["cpu_rec"], 1.0, max(1.0, cores - 0.5 if cores > 1 else cores))
    cpus = round(cpus * 2) / 2.0
    # /dev/shm is a ceiling, not a reservation: what is stored there counts
    # against the memory cap anyway, so a generous 1 GB costs nothing until a
    # browser or video player actually uses it, and keeps them from crashing
    # on a small /dev/shm.
    shm = SHM_DEFAULT_MB

    # Give the desktop room to actually live in: the image itself plus a real
    # working allowance, never less than 10 GB, and never more than most of
    # what is free.
    want = max(10240, int(e["disk_mb"] * 2.0) + 6144)
    ceiling = int(max(5120, host.get("disk_free_mb", 0) * 0.85))
    disk = int(clamp(want, 5120, ceiling))
    disk = int(round(disk / 1024.0) * 1024)
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
__FORGE_FILE_FORGE_SMART_PY__
  cat > "$FORGE_APP/forge/space.py" <<'__FORGE_FILE_FORGE_SPACE_PY__'
"""
Selkies Forge engine - space

What the forge is using on disk, and cleaning it up.

  forge layers      selkies-forge/run-*: a few KB each on top of a desktop image;
                    old ones are safe to delete (they are rebuilt in seconds)
  built desktops    selkies-forge/<id>:latest: the package installs; slow to
                    rebuild, so only removed with --all and only when unused
  pulled desktops   webtop and kasm images from the catalog; only with --all,
                    only when no desktop uses them
  orphan volumes    forge-config-* volumes whose desktop was removed but whose
                    files were kept; only with --volumes, because they are files
  build cache       docker's builder cache; with --all

Nothing in use by a container (running or stopped) is ever removed.
"""

import json

from . import catalog
from .paths import CPREFIX, IPREFIX, LABEL
from .util import run, slug


def _images():
    rc, out, _ = run(["docker", "images", "--format", "{{json .}}"], timeout=60)
    rows = []
    for line in out.splitlines() if rc == 0 else []:
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    return rows


def _used_images():
    rc, out, _ = run(["docker", "ps", "-a", "--format", "{{.Image}}"], timeout=30)
    used = set(out.split()) if rc == 0 else set()
    # A container records the tag it was made from; resolve to IDs as well.
    ids = set()
    for ref in used:
        rc, out, _ = run(["docker", "image", "inspect", "-f", "{{.Id}}", ref], timeout=20)
        if rc == 0:
            ids.add(out.strip())
    return used, ids


def _size_mb(txt):
    txt = (txt or "").strip().upper()
    try:
        for unit, mul in (("GB", 1024.0), ("MB", 1.0), ("KB", 1 / 1024.0), ("B", 1 / 1048576.0)):
            if txt.endswith(unit):
                return float(txt[:-len(unit)]) * mul
    except ValueError:
        pass
    return 0.0


def report():
    used_refs, used_ids = _used_images()
    catalog_images = {e["image"] for e in catalog.CATALOG if e.get("image")}
    catalog_bases = {e["recipe"]["image"] for e in catalog.CATALOG if e.get("recipe")}
    groups = {"layers": [], "built": [], "pulled": [], "bases": []}
    for im in _images():
        ref = "%s:%s" % (im.get("Repository"), im.get("Tag"))
        row = {"ref": ref, "id": im.get("ID"), "size_mb": round(_size_mb(im.get("Size")), 1),
               "in_use": ref in used_refs or any(i.startswith("sha256:" + (im.get("ID") or "~"))
                                                 for i in used_ids)}
        if ref.startswith(IPREFIX + "run-"):
            groups["layers"].append(row)
        elif ref.startswith(IPREFIX):
            groups["built"].append(row)
        elif ref in catalog_images:
            groups["pulled"].append(row)
        elif ref in catalog_bases:
            groups["bases"].append(row)
    # A forge layer's reported size includes the desktop image under it; what
    # deleting it frees is only the difference (usually a few hundred KB).
    sizes = {}
    for g in groups.values():
        for r in g:
            sizes[r["ref"]] = r["size_mb"]
    by_slug = {slug(e["id"])[:60]: e for e in catalog.CATALOG}
    for r in groups["layers"]:
        e = by_slug.get(r["ref"][len(IPREFIX + "run-"):].split(":")[0])
        base = None
        if e:
            base = e["image"] if e["kind"] == "pull" else "%s%s:latest" % (IPREFIX, e["id"])
        r["total_mb"] = r["size_mb"]
        if base in sizes:
            r["size_mb"] = round(max(0.1, r["size_mb"] - sizes[base]), 1)
    rc, out, _ = run(["docker", "volume", "ls", "-q"], timeout=30)
    vols = [v for v in out.split() if v.startswith(CPREFIX + "config-")] if rc == 0 else []
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=30)
    names = set(out.split()) if rc == 0 else set()
    orphans = [v for v in vols if v[len(CPREFIX + "config-"):] not in names]
    rc, out, _ = run(["docker", "system", "df", "--format", "{{json .}}"], timeout=60)
    cache_mb = 0.0
    for line in out.splitlines() if rc == 0 else []:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("Type") == "Build Cache":
            cache_mb = _size_mb(row.get("Size"))
    out = {"groups": groups, "orphan_volumes": orphans, "build_cache_mb": round(cache_mb, 1)}
    out["reclaimable_mb"] = round(
        sum(r["size_mb"] for r in groups["layers"] if not r["in_use"]), 1)
    out["reclaimable_all_mb"] = round(out["reclaimable_mb"] + cache_mb + sum(
        r["size_mb"] for g in ("built", "pulled", "bases") for r in groups[g] if not r["in_use"]), 1)
    return out


def clean(everything=False, volumes=False, dry_run=False):
    """Remove what report() calls reclaimable. Returns what was (or would be) removed."""
    rep = report()
    targets = [r["ref"] for r in rep["groups"]["layers"] if not r["in_use"]]
    if everything:
        targets += [r["ref"] for g in ("built", "pulled", "bases") for r in rep["groups"][g]
                    if not r["in_use"]]
    removed, failed = [], {}
    for ref in targets:
        if dry_run:
            removed.append(ref)
            continue
        rc, out, err = run(["docker", "rmi", ref], timeout=300)
        (removed.append(ref) if rc == 0 else failed.__setitem__(ref, (err or out).strip()[:200]))
    vols = rep["orphan_volumes"] if volumes else []
    for v in vols:
        if not dry_run:
            run(["docker", "volume", "rm", v], timeout=120)
    if everything and not dry_run:
        run(["docker", "builder", "prune", "-af"], timeout=900)
    if not dry_run:
        run(["docker", "image", "prune", "-f"], timeout=300)
    return {"removed_images": removed, "failed": failed, "removed_volumes": vols,
            "dry_run": dry_run, "build_cache": everything}
__FORGE_FILE_FORGE_SPACE_PY__
  cat > "$FORGE_APP/forge/stats.py" <<'__FORGE_FILE_FORGE_STATS_PY__'
"""
Selkies Forge engine - stats

Docker stats sampler: CPU, memory and bandwidth per desktop.
"""

import json
import threading
import time

from collections import deque

from .paths import CPREFIX
from .util import _int_or_none, parse_size, run


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
__FORGE_FILE_FORGE_STATS_PY__
  cat > "$FORGE_APP/forge/store.py" <<'__FORGE_FILE_FORGE_STORE_PY__'
"""
Selkies Forge engine - store

The instance registry file (notes the engine keeps beside Docker's labels).
"""

from .paths import INSTANCES_JSON
from .util import FileLock, jload, jsave


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
__FORGE_FILE_FORGE_STORE_PY__
  cat > "$FORGE_APP/forge/terminal.py" <<'__FORGE_FILE_FORGE_TERMINAL_PY__'
"""
Selkies Forge engine - terminal

Live PTY sessions into desktops (docker exec -it) for the web terminal.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import threading
import time
import uuid

from collections import deque


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
__FORGE_FILE_FORGE_TERMINAL_PY__
  cat > "$FORGE_APP/forge/tunnels.py" <<'__FORGE_FILE_FORGE_TUNNELS_PY__'
"""
Selkies Forge engine - tunnels

serveo tunnels: open, watch, close.
"""

import os
import re
import signal
import subprocess
import time

from .paths import ANSI_RE, LOGDIR, SSH_KEY, STATE
from .store import reg_load, reg_update
from .util import ensure_dirs, have, pid_alive, run, slug


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
__FORGE_FILE_FORGE_TUNNELS_PY__
  cat > "$FORGE_APP/forge/updates.py" <<'__FORGE_FILE_FORGE_UPDATES_PY__'
"""
Selkies Forge engine - updates

Self-update from GitHub (git fast-forward, never backwards).
"""

import os
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from .paths import APPDIR, LOGDIR, ROOT, STATE, UPDATE_JSON, VERSION
from .util import FileLock, have, jload, jsave, run


UPDATE_URL_DEFAULT = "https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh"
UPDATE_EVERY = int(os.environ.get("FORGE_UPDATE_EVERY") or 300)
SERVE_PAYLOAD = None            # what this web UI process was started from


def installed_payload():
    try:
        with open(os.path.join(APPDIR, ".payload")) as fh:
            return fh.read().strip() or None
    except Exception:
        return None


def installed_version():
    """FORGE_VERSION of the build that is actually installed (not this process)."""
    try:
        with open(os.path.join(APPDIR, "selkies-cli")) as fh:
            for line in fh:
                if line.startswith("FORGE_VERSION="):
                    return line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass
    return VERSION


def _vtuple(v):
    nums = re.findall(r"\d+", v or "")
    return tuple(int(x) for x in nums[:4]) or (0,)


def auto_update_enabled():
    return os.environ.get("FORGE_AUTO_UPDATE", "1") != "0"


REPO_URL_DEFAULT = "https://github.com/adatskov-wcpss/animated-fiesta.git"
REPO_BRANCH = os.environ.get("FORGE_BRANCH") or "main"
REPO_DIR = os.path.join(ROOT, "repo")


def check_update(install=True, max_age=0, timeout=20):
    """Is there a newer Selkies Forge?  Install it if asked.

    The normal path is a git clone of the repo that only ever fast-forwards
    (a "git pull --ff-only"): it talks to GitHub's git servers directly, so
    there is no cache lag, and it can never move backwards.  Without git it
    falls back to downloading docker.sh, newer versions only.
    """
    with FileLock("update", timeout=300):
        st = jload(UPDATE_JSON, {})
        if max_age and time.time() - float(st.get("checked_at") or 0) < max_age:
            st["just_installed"] = False
            return st
        st.update(checked_at=time.time(), error=None, just_installed=False)
        if have("git") and not os.environ.get("FORGE_URL"):
            _check_git(st, install)
        else:
            _check_download(st, install, timeout)
        st["installed_version"] = installed_version()
        jsave(UPDATE_JSON, {k: v for k, v in st.items() if k != "just_installed"})
        return st


def _git(*args, **kw):
    return run(["git", "-C", REPO_DIR] + list(args), timeout=kw.get("timeout", 120))


def _payload_and_version(txt):
    m = re.search(r'^FORGE_PAYLOAD_SHA="([0-9a-f]{64})"', txt or "", re.M)
    v = re.search(r'^FORGE_VERSION="([^"]+)"', txt or "", re.M)
    return (m.group(1) if m else None), (v.group(1) if v else None)


def _check_git(st, install):
    url = os.environ.get("FORGE_REPO") or REPO_URL_DEFAULT
    st["method"] = "git"
    st["url"] = url
    # Our own private clone; re-clone if it is missing or points elsewhere.
    ok = os.path.isdir(os.path.join(REPO_DIR, ".git"))
    if ok:
        rc, out, _ = _git("remote", "get-url", "origin", timeout=20)
        ok = rc == 0 and out.strip() == url
        if not ok:
            shutil.rmtree(REPO_DIR, ignore_errors=True)
    if not ok:
        rc, _, err = run(["git", "clone", "--quiet", "--single-branch", "--branch", REPO_BRANCH,
                          url, REPO_DIR], timeout=600)
        if rc != 0:
            st["error"] = "git clone failed: %s" % (err.strip().splitlines() or ["?"])[-1][:160]
            return
        st.pop("installed_commit", None)

    rc, _, err = _git("fetch", "--quiet", "origin", REPO_BRANCH, timeout=180)
    if rc != 0:
        st["error"] = "git fetch failed: %s" % (err.strip().splitlines() or ["?"])[-1][:160]
        return
    rc, out, _ = _git("rev-parse", "FETCH_HEAD", timeout=20)
    remote = out.strip()
    rc, txt, _ = _git("show", "%s:docker.sh" % remote, timeout=60)
    remote_sha, remote_version = _payload_and_version(txt if rc == 0 else "")
    if not remote_sha:
        st["error"] = "docker.sh in %s does not look like Selkies Forge" % url
        return
    st.update(remote_commit=remote, remote_sha=remote_sha, remote_version=remote_version)

    local = installed_payload()
    mine = st.get("installed_commit")
    if remote_sha == local:
        st["available"] = False
        st["installed_commit"] = remote          # in step with GitHub
    elif mine and mine != remote:
        # A fast-forward only: the installed commit must be in GitHub's history.
        rc, _, _ = _git("merge-base", "--is-ancestor", mine, remote, timeout=30)
        # If history was rewritten, still take a release whose version is
        # genuinely higher; otherwise one force-push would freeze updates.
        higher = _vtuple(remote_version) > _vtuple(installed_version())
        st["available"] = rc == 0 or higher
        if not st["available"]:
            st["error"] = ("GitHub's history no longer contains the installed commit; "
                           "not following it backwards")
    else:
        # First check after installing from a downloaded script: we don't know
        # which commit that was, so only a higher version counts as newer.
        st["available"] = _vtuple(remote_version) > _vtuple(installed_version())

    if not (st["available"] and install and auto_update_enabled()):
        return
    # The "git pull": fast-forward our clone, then install from it.
    rc, _, err = _git("merge", "--ff-only", "--quiet", remote, timeout=120)
    if rc != 0:
        _git("checkout", "--quiet", "-B", REPO_BRANCH, remote, timeout=120)
    _install_update(st, os.path.join(REPO_DIR, "docker.sh"))
    if st.get("just_installed"):
        st["installed_commit"] = remote


def _check_download(st, install, timeout):
    """Fallback without git: fetch docker.sh itself (ETag keeps repeats cheap)."""
    url = os.environ.get("FORGE_URL") or UPDATE_URL_DEFAULT
    st["method"] = "download"
    headers = {"User-Agent": "selkies-forge/" + VERSION}
    dl = os.path.join(STATE, "update-docker.sh")
    if st.get("etag") and st.get("url") == url and os.path.exists(dl):
        headers["If-None-Match"] = st["etag"]
    st["url"] = url
    body = None
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            st["etag"] = r.headers.get("ETag")
    except urllib.error.HTTPError as ex:
        if ex.code != 304:
            st["error"] = "GitHub answered HTTP %s" % ex.code
    except Exception as ex:
        st["error"] = "could not reach GitHub (%s)" % type(ex).__name__
    if body:
        txt = body.decode("utf-8", "replace")
        m = re.search(r'^FORGE_PAYLOAD_SHA="([0-9a-f]{64})"', txt, re.M)
        v = re.search(r'^FORGE_VERSION="([^"]+)"', txt, re.M)
        if m:
            with open(dl, "wb") as fh:
                fh.write(body)
            st["remote_sha"] = m.group(1)
            st["remote_version"] = v.group(1) if v else None
        else:
            st["error"] = "the file on GitHub does not look like Selkies Forge"
    local = installed_payload()
    st["installed_sha"] = local
    st["installed_version"] = installed_version()
    # Only ever move forward. GitHub's raw cache can serve an older copy for
    # a few minutes after a push, and "different" must not mean "install".
    newer = _vtuple(st.get("remote_version")) > _vtuple(st["installed_version"])
    st["available"] = bool(st.get("remote_sha") and local and
                           st["remote_sha"] != local and newer)
    if st["available"] and install and auto_update_enabled():
        _install_update(st, dl)


def _install_update(st, path):
    rc, _, _ = run(["bash", "-n", path], timeout=60)
    if rc != 0:
        st["error"] = "the downloaded update does not parse; skipped"
        return
    env = dict(os.environ, FORGE_HOME=ROOT)
    env.pop("FORGE_AS_CLI", None)
    with open(os.path.join(LOGDIR, "update.log"), "ab") as log:
        log.write(("\n--- %s installing %s\n" % (time.ctime(), st.get("remote_version"))).encode())
        log.flush()
        try:
            rc = subprocess.call(["bash", path, "--setup", "--yes"], stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, env=env, timeout=900)
        except Exception as ex:
            rc = 1
            log.write(("install crashed: %s\n" % ex).encode())
    if rc == 0 and installed_payload() == st.get("remote_sha"):
        st.update(available=False, just_installed=True, installed_at=time.time(),
                  installed_version=st.get("remote_version"), installed_sha=st.get("remote_sha"))
    else:
        st["error"] = "the update did not install cleanly; see logs/update.log"


def update_report():
    st = jload(UPDATE_JSON, {})
    running = SERVE_PAYLOAD
    installed = installed_payload()
    return {"running_version": VERSION, "auto": auto_update_enabled(),
            "checked_at": st.get("checked_at"), "available": bool(st.get("available")),
            "remote_version": st.get("remote_version"),
            "installed_version": installed_version(),
            "installed_at": st.get("installed_at"), "error": st.get("error"),
            "restart_needed": bool(running and installed and running != installed),
            "method": st.get("method"), "commit": (st.get("installed_commit") or "")[:7],
            "every_s": UPDATE_EVERY}


def _update_loop():
    time.sleep(min(30, UPDATE_EVERY))
    while True:
        try:
            check_update(install=True)
        except Exception:
            pass
        time.sleep(UPDATE_EVERY)


def restart_webui_detached():
    """Ask selkies-cli to restart us on the same port; it outlives this process."""
    cli = os.path.join(APPDIR, "selkies-cli")
    # FORGE_JUST_UPDATED only stops the CLI re-checking during the restart; it
    # must not be FORGE_AUTO_UPDATE=0, which the new server would inherit.
    env = dict(os.environ, FORGE_HOME=ROOT, FORGE_AS_CLI="1", FORGE_JUST_UPDATED="1",
               FORGE_STOP_REASON="update")
    with open(os.path.join(LOGDIR, "restart.log"), "ab") as log:
        subprocess.Popen(["bash", cli, "restart"], stdin=subprocess.DEVNULL, stdout=log,
                         stderr=subprocess.STDOUT, env=env, start_new_session=True)
__FORGE_FILE_FORGE_UPDATES_PY__
  cat > "$FORGE_APP/forge/util.py" <<'__FORGE_FILE_FORGE_UTIL_PY__'
"""
Selkies Forge engine - util

Small helpers: JSON state files, file locks, running commands, formatting.
"""

import fcntl
import json
import os
import re
import shutil
import subprocess
import time

from .paths import BUILDDIR, CACHE_JSON, JOBLOGDIR, JOBSTATEDIR, LOGDIR, ROOT, STATE


def ensure_dirs():
    for d in (ROOT, STATE, LOGDIR, JOBLOGDIR, BUILDDIR, JOBSTATEDIR):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError:
            pass


class FileLock(object):
    """A named cross-process lock (fcntl), shared by the web UI and the CLI.

    Used for port allocation, the instance registry, updates, and per-desktop
    operations, so two actions never race on the same thing.
    """

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


# Docker commands that only read state, so they are safe to repeat.
_DOCKER_READS = {"inspect", "ps", "images", "image", "stats", "info", "version", "logs",
                 "manifest", "volume", "system", "port", "top", "history"}
# The daemon briefly not answering (restarting, overloaded), as opposed to a
# real error about the thing we asked for.
_DOCKER_FLAKY = re.compile(r"cannot connect to the docker daemon|is the docker daemon running|"
                           r"daemon is not running|connection refused|i/o timeout|"
                           r"context deadline exceeded|connection reset by peer|"
                           r"error during connect|EOF$", re.I | re.M)


def _run_once(cmd, timeout, env):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout


def run(cmd, timeout=60, env=None, retries=None):
    """Return (rc, stdout, stderr); never raises for a non-zero exit.

    Read-only docker commands are retried (1s, 2s, 4s) when the daemon itself
    is briefly unreachable, so a Docker restart or a load spike does not turn
    into "your desktop is gone" in the UI. Commands that change something are
    never repeated behind your back unless the caller asks with retries=N.
    """
    if retries is None:
        retries = 3 if (len(cmd) > 1 and os.path.basename(cmd[0]) == "docker"
                        and cmd[1] in _DOCKER_READS) else 0
    delay = 1.0
    for attempt in range(retries + 1):
        rc, out, err = _run_once(cmd, timeout, env)
        if rc == 0 or attempt == retries or not _DOCKER_FLAKY.search(err or ""):
            return rc, out, err
        time.sleep(delay)
        delay *= 2
    return rc, out, err


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


def _int_or_none(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False
__FORGE_FILE_FORGE_UTIL_PY__
  cat > "$FORGE_APP/forge/watchdog.py" <<'__FORGE_FILE_FORGE_WATCHDOG_PY__'
"""
Selkies Forge engine - watchdog

While the web UI is running, the watchdog looks after every desktop:

  * Crash detection. A desktop that was running on the last pass and has now
    exited, without anyone stopping it (see events.DELIBERATE), crashed. That
    is recorded with its exit code, whether the kernel's OOM killer did it,
    and the last lines of its log.
  * Healing. A crashed desktop is started again, at most HEAL_MAX times per
    hour, unless healing is off for it (label io.selkiesforge.heal=off, or
    FORGE_HEAL=0 for all). Desktops are never started after a reboot or a
    deliberate stop: only a crash while the forge was watching counts.
  * Session health. The forge agent inside each desktop reports its window
    manager and screen; the watchdog caches that for the manager, and records
    when a desktop drops into its rescue session.
  * Frozen desktops. The agent writes a heartbeat every few seconds. A running
    desktop whose heartbeat stops (the X server or the whole container hung)
    is restarted, from the same healing budget as a crash.
  * Viewers. Each open browser tab holds one websocket to Selkies (or Kasm);
    counting them tells the manager who is watching, and how long a desktop
    has gone unwatched.
  * Idle stop. A desktop nobody has watched for its idle limit (per desktop,
    or FORGE_IDLE_STOP_MIN for all; off by default) is stopped to give its
    memory back. Its files are kept, and it starts again like any other.
  * Host memory pressure. When the machine runs short of memory, that is
    recorded with the biggest desktops named. With FORGE_PRESSURE_STOP=1 the
    biggest desktop that nobody is watching is stopped before the kernel's
    OOM killer picks something itself.
  * Recovery. A launch whose process died (the web UI restarted, the power
    went) is marked interrupted, and the half-made desktop it left is removed.
  * Housekeeping. Registry entries and port reservations for containers that
    no longer exist are dropped.

Every pass is cheap: one `docker ps`, plus a `docker inspect` only for
desktops that changed state, and one `docker exec` per running desktop at
most once a minute (the heartbeat and the viewer count in one read).
"""

import json
import os
import threading
import time

from . import events, ledger
from .health import container_logs
from .jobs import mark_job_state, read_job_states
from .paths import CPREFIX, KASM_HTTPS, LABEL, PORTS_JSON, SELKIES_WS
from .store import reg_delete, reg_load
from .util import FileLock, human_mb, jload, jsave, run

INTERVAL = 15.0
HEALTH_EVERY = 60.0
HEAL_MAX = 3            # per desktop per hour
CLEAN_STOP_CODES = (0, 143)   # exited normally, or SIGTERM from docker stop
FROZEN_AFTER = 180      # seconds without a heartbeat from a desktop that had one
PRESSURE_TICKS = 2      # consecutive low-memory passes before it counts
PRESSURE_EVERY = 600    # seconds between host-pressure events

_session = {}           # name -> health dict (+ "read_at", "viewers", "idle_s")
_seen = {}              # name -> {"last_viewer": ts, "since": ts}
_lock = threading.Lock()
PRESSURE = {"active": False, "since": None, "avail_mb": None, "total_mb": None}


def heal_enabled():
    return os.environ.get("FORGE_HEAL", "1") != "0"


def _env_int(var, default=0):
    try:
        return int(os.environ.get(var, default))
    except ValueError:
        return default


def idle_limit(name, reg=None):
    """Minutes a desktop may go unwatched before it is stopped (0: never)."""
    note = (reg if reg is not None else reg_load()).get(name) or {}
    if note.get("idle_stop_min") is not None:
        try:
            return max(0, int(note["idle_stop_min"]))
        except (TypeError, ValueError):
            return 0
    return max(0, _env_int("FORGE_IDLE_STOP_MIN", 0))


def count_viewers(proc_net, ports):
    """Established connections whose local port is one of `ports`, from the
    text of /proc/net/tcp and /proc/net/tcp6 inside a container."""
    n = 0
    for line in proc_net.splitlines():
        parts = line.split()
        if len(parts) < 4 or ":" not in parts[1] or parts[0] == "sl":
            continue
        try:
            port = int(parts[1].rsplit(":", 1)[1], 16)
        except ValueError:
            continue
        if parts[3] == "01" and port in ports:
            n += 1
    return n


def read_meminfo():
    out = {}
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                k, _, v = line.partition(":")
                out[k] = int(v.split()[0]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return out.get("MemTotal"), out.get("MemAvailable")


def session_health(name):
    with _lock:
        h = _session.get(name)
        return dict(h) if h else None


def _snapshot():
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}\t{{.State}}\t{{.Label \"%s.heal\"}}"
                      "\t{{.Label \"%s.profile\"}}" % (LABEL, LABEL)],
                     timeout=30)
    if rc != 0:
        return None
    state = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            state[parts[0]] = {"state": parts[1], "heal": (parts[2] if len(parts) > 2 else ""),
                               "profile": (parts[3] if len(parts) > 3 else "") or "selkies"}
    return state


def _inspect_state(name):
    rc, out, _ = run(["docker", "inspect", "-f", "{{json .State}}", name], timeout=20)
    try:
        return json.loads(out) if rc == 0 else {}
    except ValueError:
        return {}


class Watchdog(object):
    def __init__(self, interval=INTERVAL):
        self.interval = interval
        self.prev = None
        self._stop = threading.Event()
        self._thread = None
        self._last_clean = 0.0
        self._last_recover = 0.0
        self._pressure_ticks = 0
        self._last_pressure = 0.0

    def start(self):
        if self._thread:
            return
        self._thread = threading.Thread(target=self._loop, name="forge-watchdog", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _loop(self):
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception:
                pass
            self._stop.wait(self.interval)

    # -- one pass -----------------------------------------------------------
    def tick(self, now=None):
        now = now or time.time()
        cur = _snapshot()
        if cur is None:
            return {"docker": False}
        report = {"crashed": [], "healed": [], "rescue": [], "frozen": [], "idle_stopped": [],
                  "pressure": False, "recovered": []}
        if self.prev is not None:
            for name, info in cur.items():
                was = self.prev.get(name)
                if was and was["state"] == "running" and info["state"] in ("exited", "dead"):
                    self._on_stop(name, info, report)
        reg = reg_load()
        for name, info in cur.items():
            if info["state"] == "running":
                was_running = bool(self.prev and (self.prev.get(name) or {}).get("state") == "running")
                self._read_session(name, info, now, report, reg, was_running)
        with _lock:
            for name in list(_session):
                if name not in cur or cur[name]["state"] != "running":
                    _session.pop(name, None)
                    _seen.pop(name, None)
        self.prev = cur
        self._check_pressure(cur, now, report)
        if now - self._last_recover > 60:
            self._last_recover = now
            report["recovered"] = recover_interrupted()
        if now - self._last_clean > 600:
            self._last_clean = now
            reconcile(set(cur))
        return report

    def _on_stop(self, name, info, report):
        if events.last_deliberate(name, within=300):
            return                                   # someone stopped it on purpose
        st = _inspect_state(name)
        code = st.get("ExitCode")
        oom = bool(st.get("OOMKilled"))
        if not oom and code in CLEAN_STOP_CODES:
            events.record(name, "stopped", "exited with code %s outside the forge" % code)
            return
        tail = container_logs(name, 15)
        events.record(name, "crashed", "exit code %s%s" % (code, ", out of memory" if oom else ""),
                      exit_code=code, oom=oom, log=tail[-1500:])
        report["crashed"].append(name)
        if info.get("heal") == "off" or not heal_enabled():
            return
        recent = events.recent(name, limit=20, since=time.time() - 3600, kinds={"healed"})
        if len(recent) >= HEAL_MAX:
            events.record(name, "heal-skipped", "crashed %d times this hour; leaving it stopped"
                          % (len(recent) + 1))
            return
        rc, out, err = run(["docker", "start", name], timeout=120)
        if rc == 0:
            events.record(name, "healed", "started again after a crash")
            report["healed"].append(name)
        else:
            events.record(name, "heal-failed", (err or out).strip()[:400])

    def _heal_budget_left(self, name):
        recent = events.recent(name, limit=20, since=time.time() - 3600, kinds={"healed"})
        return HEAL_MAX - len(recent)

    def _read_session(self, name, info, now, report, reg, was_running):
        with _lock:
            h = _session.get(name)
            seen = _seen.setdefault(name, {"last_viewer": now, "since": now})
            if not was_running:
                seen["since"] = now
        if h and now - h.get("read_at", 0) < HEALTH_EVERY:
            return
        # One exec: the agent's heartbeat file, then the container's sockets.
        rc, out, _ = run(["docker", "exec", name, "sh", "-c",
                          "cat /tmp/forge/health.json 2>/dev/null; echo; echo @@NET@@; "
                          "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"], timeout=10)
        if rc != 0 and not out:
            return
        raw, _, net = out.partition("@@NET@@")
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            data = {}
        ports = {KASM_HTTPS} if info.get("profile") == "kasm" else {SELKIES_WS}
        viewers = count_viewers(net, ports)
        if viewers:
            seen["last_viewer"] = now
        data["viewers"] = viewers
        data["idle_s"] = 0 if viewers else int(now - seen["last_viewer"])
        data["read_at"] = now
        prev_mode = (h or {}).get("mode")
        with _lock:
            _session[name] = data
        if data.get("mode") == "rescue" and prev_mode != "rescue":
            events.record(name, "session-rescue",
                          "the desktop session kept crashing; a rescue session is showing its log")
            report["rescue"].append(name)
        if self._check_frozen(name, info, h, data, now, report):
            return
        limit = idle_limit(name, reg)
        if limit and not viewers and now - seen["last_viewer"] >= limit * 60 \
                and now - seen["since"] >= limit * 60:
            self._idle_stop(name, limit, report)

    def _check_frozen(self, name, info, h, data, now, report):
        """A heartbeat that was moving and has stopped: the desktop hung."""
        ts, prev_ts = data.get("ts"), (h or {}).get("ts")
        if not ts or not prev_ts or ts != prev_ts or now - float(ts) < FROZEN_AFTER:
            return False
        if (h or {}).get("frozen_reported"):
            data["frozen_reported"] = True
            return True
        data["frozen_reported"] = True
        stuck = int(now - float(ts))
        events.record(name, "session-frozen", "no sign of life from the desktop for %ds" % stuck)
        report["frozen"].append(name)
        if info.get("heal") == "off" or not heal_enabled():
            return True
        if self._heal_budget_left(name) <= 0:
            events.record(name, "heal-skipped", "froze again; healed %d times this hour already"
                          % HEAL_MAX)
            return True
        events.record(name, "restart", "watchdog: restarting a frozen desktop")
        rc, out, err = run(["docker", "restart", "-t", "10", name], timeout=120)
        if rc == 0:
            events.record(name, "healed", "restarted after it froze")
            report["healed"].append(name)
        else:
            events.record(name, "heal-failed", (err or out).strip()[:400])
        return True

    def _idle_stop(self, name, limit, report):
        from .lifecycle import instance_action        # lifecycle imports this module
        events.record(name, "idle-stop", "nobody has watched it for %d minutes; stopping it "
                      "to free its memory (files are kept)" % limit)
        try:
            instance_action(name, "stop")
            report["idle_stopped"].append(name)
        except Exception as ex:
            events.record(name, "idle-stop-failed", str(ex)[:300])

    def _check_pressure(self, cur, now, report):
        total, avail = read_meminfo()
        if not total or avail is None:
            return
        low = avail < max(256, total * 0.05)
        self._pressure_ticks = self._pressure_ticks + 1 if low else 0
        PRESSURE.update(total_mb=total, avail_mb=avail)
        if self._pressure_ticks < PRESSURE_TICKS:
            if not low:
                PRESSURE.update(active=False, since=None)
            return
        if not PRESSURE["active"]:
            PRESSURE.update(active=True, since=now)
        report["pressure"] = True
        if now - self._last_pressure < PRESSURE_EVERY:
            return
        self._last_pressure = now
        running = [n for n, i in cur.items() if i["state"] == "running"]
        usage = desktop_memory(running)
        top = sorted(usage.items(), key=lambda kv: -kv[1])[:3]
        events.record("host", "host-pressure",
                      "only %s of %s memory left; biggest desktops: %s"
                      % (human_mb(avail), human_mb(total),
                         ", ".join("%s %s" % (n.replace(CPREFIX, "", 1), human_mb(mb))
                                   for n, mb in top) or "none"))
        if os.environ.get("FORGE_PRESSURE_STOP") != "1":
            return
        with _lock:
            unwatched = [n for n, _ in sorted(usage.items(), key=lambda kv: -kv[1])
                         if not (_session.get(n) or {}).get("viewers")]
        if unwatched:
            from .lifecycle import instance_action
            victim = unwatched[0]
            events.record(victim, "pressure-stop", "the machine was out of memory and nobody "
                          "was watching this desktop; stopped it (files are kept)")
            try:
                instance_action(victim, "stop")
                report["idle_stopped"].append(victim)
            except Exception as ex:
                events.record(victim, "idle-stop-failed", str(ex)[:300])


def desktop_memory(names):
    """{name: MB in use} for running desktops (one `docker stats` call)."""
    if not names:
        return {}
    rc, out, _ = run(["docker", "stats", "--no-stream", "--format",
                      "{{.Name}}\t{{.MemUsage}}"] + list(names), timeout=40)
    from .util import parse_size
    usage = {}
    for line in out.splitlines():
        n, _, mem = line.partition("\t")
        try:
            usage[n] = int(parse_size(mem.split("/")[0].strip()) / (1024 * 1024))
        except (ValueError, TypeError):
            continue
    return usage


def recover_interrupted():
    """Clean up after launches whose process died part-way.

    The job is marked interrupted. If it had already created its container,
    and that container carries this job's label and never reported ready, the
    container is removed, and its volume too unless the volume held files
    from before (a kept volume of a removed desktop, which is never touched).
    """
    done = []
    for st in read_job_states():
        if st.get("status") != "interrupted" or st.get("recovered"):
            continue
        jid = st.get("id")
        notes = st.get("notes") or {}
        cname = notes.get("container")
        removed = False
        if st.get("kind") in ("launch", "clone") and cname:
            rc, out, _ = run(["docker", "inspect", "-f",
                              "{{index .Config.Labels \"%s.job\"}}" % LABEL, cname], timeout=20)
            ready = any(e.get("event") == "ready" and e.get("ts", 0) >= (st.get("created") or 0)
                        for e in events.recent(cname, limit=40))
            if rc == 0 and out.strip() == jid and not ready:
                run(["docker", "rm", "-f", cname], timeout=120)
                if notes.get("volume") and not notes.get("keep_volume"):
                    run(["docker", "volume", "rm", "-f", notes["volume"]], timeout=60)
                reg_delete(cname)
                removed = True
            elif rc != 0 and notes.get("volume") and not notes.get("keep_volume") \
                    and st.get("kind") == "clone":
                run(["docker", "volume", "rm", "-f", notes["volume"]], timeout=60)
        ledger.release(jid)
        what = ("the half-made desktop %s was removed" % cname) if removed else "nothing was left behind"
        mark_job_state(jid, status="interrupted", recovered=True,
                       error={"message": "interrupted during %s (its process stopped); %s"
                              % (st.get("phase") or "start", what), "hints": [],
                              "cancelled": False, "log": st.get("log")})
        if cname:
            events.record(cname, "launch-interrupted",
                          "the process running this launch stopped during %s; %s"
                          % (st.get("phase") or "start", what))
        done.append(jid)
    return done


def reconcile(existing=None):
    """Drop registry entries and port reservations for containers that are gone."""
    if existing is None:
        snap = _snapshot()
        if snap is None:
            return {"docker": False}
        existing = set(snap)
    gone = [n for n in reg_load() if n not in existing and n != "__webui__"]
    for n in gone:
        reg_delete(n)
    with FileLock("ports"):
        res = jload(PORTS_JSON, {})
        fresh = {k: v for k, v in res.items() if time.time() - float(v) < 900}
        if fresh != res:
            jsave(PORTS_JSON, fresh)
    return {"removed": gone}


WATCHDOG = Watchdog()
__FORGE_FILE_FORGE_WATCHDOG_PY__
  cat > "$FORGE_APP/forge/webui.py" <<'__FORGE_FILE_FORGE_WEBUI_PY__'
"""
Selkies Forge engine - webui

The web UI's own lifecycle: how it last stopped, start-on-boot, status.
"""

import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from .host import docker_ok
from .paths import (
    APPDIR,
    BOOT_JSON,
    LABEL,
    LAST_STOP_JSON,
    LIFE_JSON,
    LOGDIR,
    ROOT,
    SERVER_JSON,
    STOP_REQUEST_JSON,
    VERSION,
)
from .registry import docker_instances
from .updates import installed_payload
from .util import have, jload, jsave, pid_alive, run


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def boot_time():
    try:
        with open("/proc/stat") as fh:
            for line in fh:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def host_going_down():
    """'reboot', 'shutdown' or None, asked while we are being stopped."""
    try:
        rc, out, _ = run(["systemctl", "list-jobs", "--no-legend", "--no-pager"], timeout=4)
        jobs = out if rc == 0 else ""
        if re.search(r"\breboot\.target|kexec\.target", jobs):
            return "reboot"
        if re.search(r"\b(poweroff|halt|shutdown)\.target", jobs):
            return "shutdown"
        rc, out, _ = run(["systemctl", "is-system-running"], timeout=4)
        if out.strip() == "stopping":
            return "shutdown"
    except Exception:
        pass
    if os.path.exists("/run/nologin") and os.path.exists("/run/systemd/shutdown/scheduled"):
        return "shutdown"
    return None


def running_desktop_names():
    rc, out, _ = run(["docker", "ps", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=15)
    return sorted(out.split()) if rc == 0 else []


def _oom_hint(pid, since):
    """Best effort: did the kernel's OOM killer take this pid?"""
    for cmd in (["journalctl", "-k", "--no-pager", "-q", "--since", "@%d" % int(since)],
                ["dmesg"]):
        try:
            rc, out, _ = run(cmd, timeout=6)
        except Exception:
            continue
        if rc == 0 and re.search(r"Killed process %s\b" % pid, out):
            return True
    return False


STOP_LABELS = {
    "user": "you stopped it",
    "ctrl-c": "you stopped it with ctrl-c",
    "restart": "it was restarted",
    "update": "it restarted to install an update",
    "host-reboot": "this machine rebooted",
    "host-shutdown": "this machine shut down",
    "signal": "something sent it a stop signal",
    "service": "its systemd service was stopped",
    "error": "it hit an error and exited",
    "host-crash": "this machine crashed or lost power",
    "crash": "the web UI process died unexpectedly",
    "oom": "the system ran out of memory and killed it",
}


def analyze_life(life, now_boot=None):
    """Explain how a recorded web UI run ended."""
    if not life:
        return None
    now_boot = now_boot if now_boot is not None else boot_id()
    stopped = life.get("stopped") or {}
    boot_changed = bool(life.get("boot_id") and now_boot and life["boot_id"] != now_boot)
    out = {"pid": life.get("pid"), "started": life.get("started"),
           "last_seen": life.get("heartbeat") or life.get("started"),
           "desktops_running": life.get("desktops_running") or [],
           "boot_changed": boot_changed, "boot_time": boot_time() if boot_changed else None}
    if stopped.get("reason"):
        out.update(reason=stopped["reason"], at=stopped.get("at"),
                   detail=stopped.get("detail") or "")
        # A clean SIGTERM we could not place, followed by a new boot, was the
        # machine going down.
        if stopped["reason"] == "signal" and boot_changed:
            out["reason"] = "host-shutdown"
    elif pid_alive(life.get("pid")) and not boot_changed:
        return None                                   # still running
    elif boot_changed:
        out.update(reason="host-crash", at=life.get("heartbeat"),
                   detail="the last sign of life was its heartbeat; nothing "
                          "recorded a clean shutdown")
    else:
        oom = _oom_hint(life.get("pid"), life.get("heartbeat") or life.get("started") or 0)
        out.update(reason="oom" if oom else "crash", at=life.get("heartbeat"),
                   detail=_webui_log_tail())
    out["label"] = STOP_LABELS.get(out["reason"], out["reason"])
    out["clean"] = out["reason"] in ("user", "ctrl-c", "restart", "update", "service",
                                     "host-reboot", "host-shutdown")
    return out


def _webui_log_tail():
    try:
        with open(os.path.join(LOGDIR, "webui.log"), errors="replace") as fh:
            lines = [l.rstrip() for l in fh.readlines()[-30:]
                     if l.strip() and not l.lstrip().startswith("{")]
        tb = [l for l in lines if "Error" in l or "Traceback" in l or "Exception" in l]
        return (tb[-1] if tb else "")[:300]
    except OSError:
        return ""


def last_stop_report():
    """What the CLI and UI show about the previous run, or None."""
    info = jload(SERVER_JSON, None)
    life = jload(LIFE_JSON, None)
    up = bool(info and pid_alive(info.get("pid")))
    if up:
        rep = jload(LAST_STOP_JSON, None)
        if not rep or rep.get("dismissed") or time.time() - float(rep.get("recorded") or 0) > 7 * 86400:
            return None
    else:
        rep = analyze_life(life)
        if rep:
            prev = jload(LAST_STOP_JSON, {}) or {}
            if prev.get("dismissed") and prev.get("pid") == rep.get("pid"):
                rep["dismissed"] = True
    if not rep:
        return None
    running = set(running_desktop_names())
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=%s.entry" % LABEL,
                      "--format", "{{.Names}}"], timeout=15)
    exists = set(out.split()) if rc == 0 else set()
    rep["restore"] = [n for n in rep.get("desktops_running") or []
                      if n in exists and n not in running]
    return rep


def dismiss_last_stop():
    rep = last_stop_report() or {}
    rep["dismissed"] = True
    rep.setdefault("recorded", time.time())
    jsave(LAST_STOP_JSON, rep)
    return {"ok": True}


UNIT_NAME = "selkies-forge.service"
CRON_MARK = "# selkies-forge-boot"


def _unit_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "systemd", "user", UNIT_NAME)


def _user():
    import pwd
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return os.environ.get("USER") or ""


def systemd_user_ok():
    if not have("systemctl"):
        return False
    rc, _, _ = run(["systemctl", "--user", "show-environment"], timeout=8)
    return rc == 0


def linger_on():
    if not have("loginctl"):
        return None
    rc, out, _ = run(["loginctl", "show-user", _user(), "-p", "Linger", "--value"], timeout=8)
    if rc != 0:
        return None
    return out.strip() == "yes"


def _serve_argv(port, bind, expose):
    a = [sys.executable, os.path.join(APPDIR, "engine.py"), "serve",
         "--port", str(int(port)), "--bind", bind]
    if expose:
        a.append("--tunnel")
    return a


def _crontab_lines():
    if not have("crontab"):
        return None
    rc, out, err = run(["crontab", "-l"], timeout=10)
    if rc != 0:
        return [] if "no crontab" in (err or "").lower() or not err.strip() else []
    return out.splitlines()


def _crontab_write(lines):
    p = subprocess.run(["crontab", "-"], input="\n".join(lines) + "\n", text=True,
                       capture_output=True, timeout=10)
    if p.returncode != 0:
        raise RuntimeError("crontab refused the change: %s" % (p.stderr or p.stdout).strip())


def boot_report():
    st = jload(BOOT_JSON, {}) or {}
    out = {"asked": bool(st.get("asked")), "enabled": False, "method": st.get("method"),
           "port": st.get("port"), "bind": st.get("bind"), "expose": st.get("expose")}
    try:
        if os.path.exists(_unit_path()) and have("systemctl"):
            rc, o, _ = run(["systemctl", "--user", "is-enabled", UNIT_NAME], timeout=8)
            if o.strip() == "enabled":
                out.update(enabled=True, method="systemd", linger=linger_on())
                return out
        lines = _crontab_lines() or []
        if any(CRON_MARK in l for l in lines):
            out.update(enabled=True, method="cron")
    except Exception:
        pass
    return out


def boot_enable(port=8787, bind="127.0.0.1", expose=False, try_linger=True):
    argv = _serve_argv(port, bind, expose)
    log = os.path.join(LOGDIR, "webui.log")
    res = {"ok": True}
    if os.environ.get("FORGE_BOOT_METHOD") != "cron" and systemd_user_ok():
        path = _unit_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        unit = "\n".join([
            "[Unit]",
            "Description=Selkies Forge web UI",
            "Documentation=https://github.com/adatskov-wcpss/animated-fiesta",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            "Environment=FORGE_BOOT=1",
            "Environment=FORGE_HOME=%s" % ROOT,
            "Environment=PATH=%s" % ":".join(dict.fromkeys(
                p for p in os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin").split(":")
                if p and " " not in p)),
            "ExecStart=%s" % " ".join(shlex.quote(a) for a in argv),
            "StandardOutput=append:%s" % log,
            "StandardError=append:%s" % log,
            # A crash (or the OOM killer) brings it back; a clean stop does not.
            "Restart=on-failure",
            "RestartSec=5",
            "",
            "[Install]",
            "WantedBy=default.target",
            ""])
        with open(path, "w") as fh:
            fh.write(unit)
        run(["systemctl", "--user", "daemon-reload"], timeout=20)
        rc, out, err = run(["systemctl", "--user", "enable", UNIT_NAME], timeout=20)
        if rc != 0:
            raise RuntimeError("systemctl --user enable failed: %s" % (err or out).strip())
        res["method"] = "systemd"
        lg = linger_on()
        if lg is False and try_linger:
            run(["loginctl", "enable-linger", _user()], timeout=15)
            lg = linger_on()
        res["linger"] = lg
        if lg is False:
            res["needs"] = "sudo loginctl enable-linger %s" % _user()
    elif _crontab_lines() is not None:
        lines = [l for l in (_crontab_lines() or []) if CRON_MARK not in l]
        lines.append("@reboot sleep 20; FORGE_BOOT=1 FORGE_HOME=%s %s >> %s 2>&1 %s"
                     % (shlex.quote(ROOT), " ".join(shlex.quote(a) for a in argv),
                        shlex.quote(log), CRON_MARK))
        _crontab_write(lines)
        res["method"] = "cron"
    else:
        raise RuntimeError("this machine has neither a systemd user session nor cron; "
                           "add `selkies-cli start` to your own startup instead")
    jsave(BOOT_JSON, {"asked": True, "enabled": True, "method": res["method"],
                      "port": int(port), "bind": bind, "expose": bool(expose)})
    return res


def boot_disable():
    if os.path.exists(_unit_path()):
        run(["systemctl", "--user", "disable", UNIT_NAME], timeout=20)
        try:
            os.remove(_unit_path())
        except OSError:
            pass
        run(["systemctl", "--user", "daemon-reload"], timeout=20)
    lines = _crontab_lines()
    if lines and any(CRON_MARK in l for l in lines):
        _crontab_write([l for l in lines if CRON_MARK not in l])
    st = jload(BOOT_JSON, {}) or {}
    st.update(asked=True, enabled=False)
    jsave(BOOT_JSON, st)
    return {"ok": True}


def boot_mark_asked():
    st = jload(BOOT_JSON, {}) or {}
    st["asked"] = True
    jsave(BOOT_JSON, st)
    return {"ok": True}


def request_stop(reason):
    """Tell a running web UI why it is about to be stopped (read by its signal handler)."""
    info = jload(SERVER_JSON, None) or {}
    jsave(STOP_REQUEST_JSON, {"pid": info.get("pid"), "reason": reason, "at": time.time()})
    return {"ok": True, "pid": info.get("pid")}


def webui_status():
    """Is the web UI up?  up / stale (recorded but dead or not answering) / down."""
    info = jload(SERVER_JSON, None)
    if not info or not info.get("pid"):
        return {"state": "down"}
    out = {"state": "stale", "pid": info.get("pid"), "port": info.get("port"),
           "url": info.get("url"), "bind": info.get("bind"),
           "tunnel": info.get("tunnel"), "started": info.get("started"),
           "uptime_s": int(time.time() - float(info.get("started") or time.time())),
           "log": os.path.join(LOGDIR, "webui.log")}
    if not pid_alive(info["pid"]):
        out["why"] = "its process (pid %s) is gone" % info["pid"]
        return out
    try:
        req = urllib.request.Request("http://127.0.0.1:%d/api/host" % int(info["port"]),
                                     headers={"User-Agent": "selkies-cli"})
        with urllib.request.urlopen(req, timeout=4) as r:
            ok = r.status < 500
    except urllib.error.HTTPError as ex:
        ok = ex.code in (401, 403)          # pre-1.9 servers wanted a token, but alive
    except Exception as ex:
        ok = False
        out["why"] = "it is running but not answering (%s)" % type(ex).__name__
    if ok:
        out["state"] = "up"
        out["payload"] = info.get("payload")
        inst = installed_payload()
        out["restart_needed"] = bool(info.get("payload") and inst and info.get("payload") != inst)
    return out


def forge_status():
    items = []
    try:
        for i in docker_instances():
            t = i.get("tunnel") or {}
            items.append({"name": i["name"], "title": i["title"], "running": i["running"],
                          "status": i.get("status"), "local_url": i.get("local_url"),
                          "public_url": t.get("url") if t.get("alive") else None,
                          "autostart": i.get("autostart"), "started_at": i.get("started_at")})
    except Exception:
        pass
    ok, err = docker_ok()
    try:
        last = last_stop_report()
    except Exception:
        last = None
    return {"version": VERSION, "webui": webui_status(), "docker": ok,
            "last_stop": last, "boot": boot_report(),
            "docker_error": None if ok else err, "desktops": items,
            "running": sum(1 for i in items if i["running"]),
            "stopped": sum(1 for i in items if not i["running"])}
__FORGE_FILE_FORGE_WEBUI_PY__
  cat > "$FORGE_APP/web/app.css" <<'__FORGE_FILE_WEB_APP_CSS__'
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

.topbar .search input {
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

.topbar .search input:focus {
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
  text-decoration: none;
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
.btn svg { width: 14px; height: 14px; flex: 0 0 14px; }
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
.stat-strip {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 12px;
  margin-bottom: 18px;
}

@media (max-width: 900px) { .stat-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); } }

/* Jobs in progress on this machine (this UI's and selkies-cli's). */
.jobstrip {
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  background: var(--glass-2);
  padding: 10px 14px;
  margin-bottom: 18px;
  display: grid;
  gap: 8px;
  font-size: 13px;
}
.jobstrip[hidden] { display: none; }
.jobstrip > b { color: var(--dim); font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; }
.jrow { display: flex; align-items: center; gap: 10px; min-width: 0; flex-wrap: wrap; }
.jrow .jt { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 40%; }
.jrow .jp { color: var(--dim); flex: 1; min-width: 120px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.jrow .jbar { width: 120px; height: 6px; border-radius: 3px; background: var(--line); overflow: hidden; }
.jrow .jbar i { display: block; height: 100%; background: linear-gradient(90deg, var(--acc), var(--acc-2)); }
.jrow .jn { width: 3.2em; text-align: right; color: var(--dim); font-variant-numeric: tabular-nums; }

.stat {
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  background: var(--glass-2);
  padding: 14px 16px;
  display: grid;
  gap: 4px;
}

.stat .k, .sec-k {
  font-size: 10.5px;
  letter-spacing: 0.55px;
  text-transform: uppercase;
  color: var(--dim-2);
  font-weight: 650;
}

.stat .v { font-size: 20px; font-weight: 660; font-variant-numeric: tabular-nums; line-height: 1.15; }
.stat .s { font-size: 11.5px; color: var(--dim-2); }

.inst-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(470px, 1fr));
  gap: 16px;
  align-items: stretch;
}

@media (max-width: 1060px) { .inst-grid { grid-template-columns: 1fr; } }

.mc {
  border: 1px solid var(--line);
  border-radius: var(--r-l);
  background: var(--glass);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  box-shadow: var(--sh);
  overflow: hidden;
  display: flex;
  flex-direction: column;
  transition: border-color 0.18s var(--ease);
}

.mc.up { border-color: rgba(61, 220, 151, 0.24); }
.mc.busy { border-color: rgba(90, 166, 255, 0.45); }
.mc.busy .mc-actions { opacity: 0.55; pointer-events: none; }
.mc > section { padding: 16px 18px; }
.mc > section + section { border-top: 1px solid var(--line); }

.mc-head { display: grid; grid-template-columns: 52px minmax(0, 1fr) auto; gap: 14px; align-items: center; }

.mc-head .logo {
  width: 52px;
  height: 52px;
  border-radius: 15px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--line);
  display: grid;
  place-items: center;
}

.mc-head .logo svg { width: 32px; height: 32px; }
.mc-head .nm { font-weight: 660; font-size: 16px; line-height: 1.25; }

.mc-head .sub2 {
  margin-top: 2px;
  font-size: 12px;
  color: var(--dim-2);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.pill {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 5px 11px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 620;
  border: 1px solid var(--line);
  background: rgba(255, 255, 255, 0.04);
  color: var(--dim);
  white-space: nowrap;
}

.pill i { width: 7px; height: 7px; border-radius: 50%; background: var(--dim-2); flex: 0 0 7px; }
.pill.up { color: #9bf0cd; border-color: rgba(61, 220, 151, 0.34); background: rgba(61, 220, 151, 0.1); }
.pill.up i { background: var(--ok); box-shadow: 0 0 8px var(--ok); }
.pill.bad { color: #ffb0bb; border-color: rgba(255, 107, 126, 0.34); background: rgba(255, 107, 126, 0.1); }
.pill.bad i { background: var(--bad); }

.mc-metrics { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px; }
.m { display: grid; gap: 6px; min-width: 0; }
.m .k { font-size: 10.5px; letter-spacing: 0.5px; text-transform: uppercase; color: var(--dim-2); font-weight: 650; }
.m .v { font-size: 15px; font-weight: 630; font-variant-numeric: tabular-nums; line-height: 1.15; white-space: nowrap; }
.m .v small { font-size: 11.5px; color: var(--dim-2); font-weight: 500; }
.m .bar { height: 4px; }
.sparkbox { height: 22px; }

svg.spark { display: block; width: 100%; height: 22px; overflow: visible; }
svg.spark path { fill: none; stroke: var(--acc); stroke-width: 1.6; vector-effect: non-scaling-stroke; }
svg.spark path.fill { fill: rgba(90, 166, 255, 0.16); stroke: none; }

.mc-access { display: grid; gap: 8px; }

.arow {
  display: grid;
  grid-template-columns: 30px 74px minmax(0, 1fr) auto;
  align-items: center;
  gap: 10px;
  min-height: 44px;
  padding: 6px 8px 6px 10px;
  border-radius: var(--r-m);
  border: 1px solid var(--line);
  background: rgba(255, 255, 255, 0.025);
}

.arow.pub { border-color: rgba(90, 166, 255, 0.3); background: rgba(90, 166, 255, 0.07); }
.arow.down { opacity: 0.62; }
.arow .ic { display: grid; place-items: center; color: var(--dim); }
.arow .ic svg { width: 17px; height: 17px; }
.arow .lab { font-size: 12px; color: var(--dim-2); font-weight: 600; }

.arow .val {
  font-family: var(--mono);
  font-size: 13px;
  color: var(--txt);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}

.arow .val .muted { color: var(--dim-2); }
.arow .acts { display: flex; gap: 4px; }

.iconbtn {
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  border-radius: 9px;
  border: 1px solid transparent;
  background: transparent;
  color: var(--dim);
  cursor: pointer;
  padding: 0;
  text-decoration: none;
  transition: background 0.14s var(--ease), color 0.14s var(--ease), border-color 0.14s var(--ease);
}

.iconbtn:hover { background: rgba(255, 255, 255, 0.08); color: var(--txt); border-color: var(--line); }
.iconbtn svg { width: 16px; height: 16px; }
.iconbtn.on { color: var(--acc); background: var(--acc-soft); }

.mc-limits { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 14px; align-items: center; }

/* Five fixed columns: the limits read as one tidy row instead of wrapping chips. */
.limits-line {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 0;
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  overflow: hidden;
}

.lchip {
  display: grid;
  gap: 2px;
  padding: 8px 10px;
  background: rgba(255, 255, 255, 0.025);
  font-size: 13px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}

.lchip + .lchip { border-left: 1px solid var(--line); }
.lchip span { font-size: 10px; font-weight: 650; color: var(--dim-2); text-transform: uppercase; letter-spacing: 0.45px; }
.lchip.on { color: #9bf0cd; }

.mc-actions {
  margin-top: auto;
  display: grid;
  /* the primary action gets a little more room so its label never wraps */
  grid-template-columns: minmax(0, 1.35fr) minmax(0, 1fr) minmax(0, 1fr) 44px;
  gap: 10px;
  padding: 14px 18px 16px !important;
}

.mc-actions .btn {
  height: 42px;
  font-size: 13.5px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  padding: 0 12px;
}
.mc-actions .btn svg { width: 16px; height: 16px; flex: 0 0 16px; }
.mc-actions .iconbtn { width: 44px; height: 42px; border: 1px solid var(--line-2); border-radius: var(--r-m); }

.menu-wrap { position: relative; }

.menu {
  position: absolute;
  right: 0;
  bottom: calc(100% + 8px);
  min-width: 200px;
  padding: 6px;
  border-radius: var(--r-m);
  border: 1px solid var(--line-2);
  background: rgba(12, 20, 36, 0.98);
  box-shadow: 0 16px 44px rgba(2, 6, 16, 0.72);
  z-index: 12;
  display: grid;
  gap: 2px;
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-width: thin;
  scrollbar-color: var(--line-2) transparent;
}

.menu[hidden] { display: none; }

.menu button {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 8px 11px;
  border: 0;
  border-radius: 9px;
  background: transparent;
  color: var(--dim);
  font: inherit;
  font-size: 13px;
  text-align: left;
  cursor: pointer;
}

.menu button:hover { background: rgba(255, 255, 255, 0.07); color: var(--txt); }
.menu button svg { width: 15px; height: 15px; flex: 0 0 15px; }
.menu button.danger { color: #ffb0bb; }
.menu button.danger:hover { background: rgba(255, 107, 126, 0.14); }
.menu hr { border: 0; border-top: 1px solid var(--line); margin: 4px 2px; }

.drawer { border-top: 1px solid var(--line); background: #04070e; }
.drawer .term { height: 320px; }

.drawer-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px 6px 14px;
  border-bottom: 1px solid var(--line);
  background: rgba(14, 22, 40, 0.85);
  font-size: 11.5px;
  color: var(--dim-2);
  font-family: var(--mono);
}

/* ------------------------------------------------------------ browse bar */
.toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
  padding: 12px 14px;
  margin-bottom: 16px;
  border: 1px solid var(--line);
  border-radius: var(--r-l);
  background: var(--glass);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  position: sticky;
  top: -20px;
  z-index: 5;
}

.toolbar select { width: auto; min-width: 170px; height: 36px; }
.toolbar .sep { width: 1px; height: 24px; background: var(--line); }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }

.seg button {
  padding: 7px 12px;
  border: 0;
  background: transparent;
  color: var(--dim);
  font: inherit;
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
}

.seg button + button { border-left: 1px solid var(--line); }
.seg button:hover { color: var(--txt); background: rgba(255, 255, 255, 0.04); }
.seg button.on { background: var(--acc-soft); color: #dbeaff; }

.smart-row { display: flex; flex-wrap: wrap; gap: 14px; align-items: center; }
.smart-row .grp { display: grid; gap: 6px; }

/* ------------------------------------------------------------ detail page */
.dhero { display: grid; grid-template-columns: 76px minmax(0, 1fr) 250px; gap: 20px; align-items: start; }
@media (max-width: 900px) { .dhero { grid-template-columns: 64px 1fr; } .dhero .go { grid-column: 1 / -1; } }

.dhero .logo {
  width: 76px;
  height: 76px;
  border-radius: 20px;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--line);
  display: grid;
  place-items: center;
}

.dhero .logo svg { width: 48px; height: 48px; }
.dhero h2 { margin: 0; font-size: 22px; font-weight: 690; letter-spacing: -0.2px; }
.dhero .tag { margin-top: 3px; color: var(--dim); font-size: 13px; }
.dhero .about { margin: 12px 0 0; color: var(--dim); font-size: 13.5px; line-height: 1.6; max-width: 760px; }
.dhero .about a, .srclink { color: var(--acc); text-decoration: none; font-size: 12.5px; white-space: nowrap; }
.dhero .about a:hover, .srclink:hover { text-decoration: underline; }
.dhero .go { display: grid; gap: 8px; }
.dhero .go .btn { height: 46px; font-size: 14px; }
.dhero .go .sum { font-size: 12px; color: var(--dim-2); text-align: center; line-height: 1.5; }

.gallery {
  display: grid;
  grid-auto-flow: column;
  grid-auto-columns: minmax(300px, 34%);
  align-items: stretch;
  gap: 14px;
  overflow-x: auto;
  padding-bottom: 6px;
  scroll-snap-type: x mandatory;
  overscroll-behavior-x: contain;
}

.shot {
  margin: 0;
  scroll-snap-align: start;
  border: 1px solid var(--line);
  border-radius: var(--r-m);
  overflow: hidden;
  background: rgba(255, 255, 255, 0.03);
  cursor: zoom-in;
  display: flex;
  flex-direction: column;
}

.shot .ph { aspect-ratio: 16 / 10; background: #0a1120; overflow: hidden; }

.shot img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  transition: transform 0.3s var(--ease), opacity 0.3s var(--ease);
  opacity: 0;
}

.shot img.ok { opacity: 1; }
.shot:hover img { transform: scale(1.03); }

/* The whole caption shows: the card grows to fit it instead of clipping text
   against its rounded corners. */
.shot figcaption {
  flex: 1 0 auto;
  padding: 10px 14px 14px;
  font-size: 12px;
  color: var(--dim);
  line-height: 1.45;
  overflow-wrap: anywhere;
}

.shot figcaption b { display: block; color: var(--dim-2); font-weight: 600; font-size: 10.5px;
  text-transform: uppercase; letter-spacing: 0.4px; margin-bottom: 2px; }

.credit { margin: 10px 0 0; font-size: 11.5px; color: var(--dim-2); }

.dgrid { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 18px; }
@media (max-width: 1000px) { .dgrid { grid-template-columns: 1fr; } }

.panel h3 .num {
  display: inline-grid;
  place-items: center;
  width: 22px;
  height: 22px;
  margin-right: 8px;
  border-radius: 7px;
  background: var(--acc-soft);
  color: #cfe3ff;
  font-size: 12px;
  font-weight: 700;
}

.prose { color: var(--dim); font-size: 13px; line-height: 1.6; margin: 0 0 8px; }

.gobar {
  position: sticky;
  bottom: -60px;
  margin: 6px -22px -60px;
  padding: 14px 22px 18px;
  display: flex;
  align-items: center;
  gap: 14px;
  border-top: 1px solid var(--line);
  background: rgba(8, 13, 24, 0.9);
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
  z-index: 6;
}

.gobar .what { flex: 1; min-width: 0; font-size: 13px; color: var(--dim); }
.gobar .what b { color: var(--txt); }
.gobar .btn { height: 42px; padding: 0 22px; }

.lightbox {
  position: fixed;
  inset: 0;
  z-index: 60;
  display: grid;
  grid-template-rows: auto 1fr auto;
  background: rgba(3, 6, 12, 0.92);
  padding: 16px 20px 22px;
}

.lightbox[hidden] { display: none; }
.lightbox .lb-top { display: flex; align-items: center; gap: 10px; color: var(--dim); font-size: 13px; }
.lightbox .lb-top .spacer { flex: 1; }
.lightbox .lb-img { display: grid; place-items: center; min-height: 0; padding: 10px 0; }
.lightbox .lb-img img { max-width: 100%; max-height: 100%; border-radius: 10px; box-shadow: 0 20px 60px rgba(0,0,0,.6); }
.lightbox .lb-cap { text-align: center; color: var(--dim); font-size: 12.5px; }
.lightbox .lb-cap a { color: var(--acc); }

/* ----------------------------------------------------------- update bar */
.updbar {
  display: flex;
  align-items: center;
  gap: 14px;
  margin-bottom: 16px;
  padding: 12px 16px;
  border-radius: var(--r-l);
  border: 1px solid rgba(90, 166, 255, 0.42);
  background: linear-gradient(135deg, rgba(90, 166, 255, 0.16), rgba(139, 125, 255, 0.12));
  backdrop-filter: blur(var(--blur));
  -webkit-backdrop-filter: blur(var(--blur));
}

.updbar[hidden] { display: none; }
.updbar .ic { color: #cfe3ff; display: grid; place-items: center; }
.updbar .ic svg { width: 20px; height: 20px; }
.updbar .msg { flex: 1; min-width: 0; font-size: 13.5px; }
.updbar .msg b { display: block; font-size: 14px; }
.updbar .msg small { color: var(--dim); }
.updbar.warn { border-color: rgba(255, 194, 77, 0.45); background: rgba(255, 194, 77, 0.09); }

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
.toast { display: grid; grid-template-columns: 1fr auto; gap: 8px; align-items: start; cursor: default; }
.toast .x { background: none; border: 0; color: var(--dim-2); cursor: pointer; font-size: 16px; line-height: 1; padding: 0 2px; }
.toast .x:hover { color: var(--txt); }
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
html.lite .mc, html.lite .stat, html.lite .menu, html.lite .toast, html.lite .toolbar,
html.lite .gobar {
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

/* ------------------------------------------------------------------ modal */
/* The backdrop scrolls, and the panel's header sticks, so Close is always on
   screen: phones with a browser bar, short windows, long logs. */
#modal {
  position: fixed;
  inset: 0;
  z-index: 70;
  background: rgba(3, 7, 14, 0.72);
  padding: 24px;
  overflow: auto;
  overscroll-behavior: contain;
  place-items: start center;
}
#modalPanel {
  max-width: 860px;
  width: 100%;
  margin: auto 0;
  max-height: calc(100dvh - 48px);
  max-height: calc(100vh - 48px);
  overflow: auto;
  padding-top: 0;
}
@supports (height: 100dvh) {
  #modalPanel { max-height: calc(100dvh - 48px); }
}
#modalPanel .modal-head {
  position: sticky;
  top: 0;
  z-index: 2;
  margin: 0 -2px 10px;
  padding: 16px 2px 10px;
  background: inherit;
  background: rgba(12, 20, 36, 0.97);
  border-bottom: 1px solid var(--line);
}
@media (max-width: 560px) {
  #modal { padding: 10px; }
  #modalPanel { max-height: calc(100vh - 20px); }
}

/* the real capture of the entry leads the gallery, full width */
.shot.real { margin: 0 0 14px; }
.shot.real .ph { aspect-ratio: 16 / 9; }
.shot.real figcaption b { color: var(--ok, #3ddc97); }
.galsub { font-size: 12.5px; color: var(--dim); margin: 4px 0 10px; }

/* ------------------------------------------------------- engine additions */
.mc > section.mc-session { padding: 8px 18px; font-size: 12.5px; color: var(--dim); display: flex;
  align-items: center; gap: 8px; }
.mc-session i.ok { width: 7px; height: 7px; border-radius: 50%; background: #3ddc97; display: inline-block; }
.mc-session.bad { color: #ffb4be; background: rgba(255, 107, 126, 0.07); justify-content: space-between; }
.evlist { display: grid; gap: 6px; max-height: 26vh; overflow: auto; }
.ev { display: grid; grid-template-columns: 160px 1fr; gap: 2px 12px; font-size: 12.5px;
  padding: 6px 10px; border: 1px solid var(--line); border-radius: var(--r-s, 8px); }
.ev .t { color: var(--dim-2); grid-row: span 2; }
.ev .d { color: var(--dim); overflow-wrap: anywhere; }
.ev.bad { border-color: rgba(255, 107, 126, 0.4); }
.muted { color: var(--dim-2); font-size: 12px; }
#lCancel { margin-left: 10px; }
__FORGE_FILE_WEB_APP_CSS__
  cat > "$FORGE_APP/web/app.js" <<'__FORGE_FILE_WEB_APP_JS__'
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

  function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", headers: { "Accept": "application/json" } };
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
    var url = path + (path.indexOf("?") < 0 ? "?" : "&") + "_=1";
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
    el.innerHTML = "<div><b>" + h(title) + "</b>" + (detail ? "<small>" + h(detail) + "</small>" : "") +
      '</div><button class="x" type="button" title="Dismiss">\u00d7</button>';
    el.querySelector(".x").onclick = function () { el.remove(); };
    box.appendChild(el);
    while (box.children.length > 4) box.removeChild(box.firstChild);
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

  var SVG = 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
            'stroke-linecap="round" stroke-linejoin="round"';
  var I = {
    globe: '<svg ' + SVG + '><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/>' +
           '<path d="M12 3c2.5 2.6 3.8 5.6 3.8 9S14.5 18.4 12 21C9.5 18.4 8.2 15.4 8.2 12S9.5 5.6 12 3z"/></svg>',
    home: '<svg ' + SVG + '><path d="M4 11l8-7 8 7"/><path d="M6 10v9h12v-9"/></svg>',
    plus: '<svg ' + SVG + '><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M4 16V6a2 2 0 0 1 2-2h10"/><path d="M14 11v6M11 14h6"/></svg>',
    save: '<svg ' + SVG + '><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>',
    lock: '<svg ' + SVG + '><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
    copy: '<svg ' + SVG + '><rect x="9" y="9" width="11" height="11" rx="2"/>' +
          '<path d="M5 15V5h10"/></svg>',
    open: '<svg ' + SVG + '><path d="M14 5h5v5"/><path d="M19 5l-8 8"/>' +
          '<path d="M18 14v4a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h4"/></svg>',
    play: '<svg ' + SVG + '><path d="M7 4l12 8-12 8z"/></svg>',
    stop: '<svg ' + SVG + '><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
    restart: '<svg ' + SVG + '><path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4v5h-5"/></svg>',
    term: '<svg ' + SVG + '><rect x="3" y="4" width="18" height="16" rx="2"/>' +
          '<path d="M7 9l3 3-3 3"/><path d="M13 15h4"/></svg>',
    logs: '<svg ' + SVG + '><path d="M6 3h8l4 4v14H6z"/><path d="M9 12h6M9 16h6M9 8h3"/></svg>',
    tune: '<svg ' + SVG + '><path d="M5 8h14M5 16h14"/><circle cx="10" cy="8" r="2.4"/>' +
          '<circle cx="15" cy="16" r="2.4"/></svg>',
    trash: '<svg ' + SVG + '><path d="M4 7h16"/><path d="M10 11v6M14 11v6"/>' +
           '<path d="M6 7l1 13h10l1-13"/><path d="M9 7V4h6v3"/></svg>',
    plug: '<svg ' + SVG + '><path d="M9 3v6M15 3v6"/><path d="M7 9h10v3a5 5 0 0 1-10 0z"/>' +
          '<path d="M12 17v4"/></svg>',
    unplug: '<svg ' + SVG + '><path d="M4 4l16 16"/><path d="M9 3v6M15 3v6"/>' +
            '<path d="M7 9h10v3a5 5 0 0 1-10 0z"/></svg>',
    more: '<svg ' + SVG + '><circle cx="6" cy="12" r="1.4" fill="currentColor"/>' +
          '<circle cx="12" cy="12" r="1.4" fill="currentColor"/>' +
          '<circle cx="18" cy="12" r="1.4" fill="currentColor"/></svg>',
    close: '<svg ' + SVG + '><path d="M6 6l12 12M18 6L6 18"/></svg>',
    fit: '<svg ' + SVG + '><path d="M4 9V4h5M20 15v5h-5M15 4h5v5M9 20H4v-5"/></svg>',
    upd: '<svg ' + SVG + '><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>',
    eye: '<svg ' + SVG + '><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/>' +
         '<circle cx="12" cy="12" r="3"/></svg>'
  };

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
    shell: null, drawerSess: null, drawerName: null, termName: null, instKey: "",
    info: null, gallery: [], shotIdx: 0,
    filters: { q: "", family: "", weight: "", kind: "", sort: "beauty" },
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
      pollUpdate();
      pollLife();
    }).catch(function (e) {
      document.body.insertAdjacentHTML("afterbegin",
        '<div class="warnbox bad" style="margin:14px">Could not reach the forge engine: ' +
        h(e.message) + "</div>");
    });
  }

  function refreshHost() {
    return api("/api/host").then(function (hh) { S.host = hh; renderMeters(); }).catch(function () {});
  }

  /* Everything running on this machine: this UI's launches and selkies-cli's. */
  function refreshJobs() {
    return api("/api/jobs").then(function (r) {
      S.jobs = (r.jobs || []).filter(function (j) { return j.status === "running"; });
      renderJobStrip();
    }).catch(function () {});
  }
  function renderJobStrip() {
    var el = $("#jobStrip");
    if (!el) return;
    var jobs = S.jobs || [];
    el.hidden = !jobs.length;
    el.innerHTML = jobs.length ? "<b>Working</b>" + jobs.map(function (j) {
      var pct = Math.round((j.progress || 0) * 100);
      return '<div class="jrow"><span class="jt">' + h(j.title || j.kind) + "</span>" +
        '<span class="jp">' + h(j.label || j.phase || "") + (j.foreign ? " \u00b7 from the terminal" : "") + "</span>" +
        '<span class="jbar"><i style="width:' + pct + '%"></i></span><span class="jn">' + pct + "%</span>" +
        ((!j.foreign || j.owner === "cli") ? '<button class="btn sm ghost" data-jobcancel="' + h(j.id) + '">Cancel</button>' : "") +
        "</div>";
    }).join("") : "";
  }

  function refreshInstances() {
    if (S.view === "manager") refreshJobs();
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
    var pr = hst.pressure || {};
    if (pr.active && !S.pressureToast) {
      S.pressureToast = true;
      toast("The machine is low on memory", "Stop a desktop you are not using, or set one to stop when idle.", "bad");
    }
    if (!pr.active) S.pressureToast = false;
    $("#meters").innerHTML =
      m(pr.active ? "RAM LOW" : "RAM FREE", mb(hst.mem_avail_mb) + " of " + mb(hst.mem_total_mb), pr.active ? 100 : memPct) +
      m("CPU LOAD", (hst.load1 || 0).toFixed(2) + " of " + (hst.cpus || "?") + " cores", cpuPct) +
      m("DISK FREE", mb(hst.disk_free_mb), diskPct);
  }

  function renderRail() {
    var running = S.instances.filter(function (i) { return i.running; }).length;
    $("#tagInst").textContent = S.instances.length ? (running + "/" + S.instances.length) : "0";
    $("#tagCat").textContent = String(S.boot ? S.boot.counts.runnable : S.catalog.length);
  }

  /* -------------------------------------------------------------- browse */
  function runnable(e) {
    return !S.host || !S.host.arch || e.arches.indexOf(S.host.arch) >= 0;
  }

  function renderFilters() {
    var labels = (S.boot && S.boot.family_labels) || {};
    var counts = {}, total = 0;
    S.catalog.forEach(function (e) {
      if (!runnable(e)) return;
      counts[e.family] = (counts[e.family] || 0) + 1;
      total++;
    });
    var fams = Object.keys(counts).sort(function (a, b) {
      return (labels[a] || a).localeCompare(labels[b] || b);
    });
    $("#famSel").innerHTML = '<option value="">All families (' + total + ")</option>" +
      fams.map(function (f) {
        return '<option value="' + h(f) + '"' + (S.filters.family === f ? " selected" : "") +
          ">" + h(labels[f] || f) + " (" + counts[f] + ")</option>";
      }).join("");
    $$("#weightSeg button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.w === S.filters.weight);
    });
    $$("#kindSeg button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.kind === S.filters.kind);
    });
  }

  function filtered() {
    var f = S.filters;
    var q = f.q.trim().toLowerCase();
    var out = S.catalog.filter(function (e) {
      if (!runnable(e)) return false;
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
    var ready = e.kind === "pull";
    return '<article class="card" tabindex="0" data-id="' + h(e.id) + '">' +
      '<div class="top"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      '<div style="min-width:0"><div class="name">' + h(e.name) + "</div>" +
      '<div class="meta">' + h(e.family_label) + " · " + h(e.de_label) + "</div></div></div>" +
      '<div class="badges">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + window.forgeGlyph(e.glyph) + h(e.de_label) + "</span>" +
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
    var hidden = S.catalog.filter(function (e) { return !runnable(e); }).length;
    $("#count").textContent = list.length + " shown" +
      (hidden ? " · " + hidden + " more need a different CPU" : "");
    var grid = $("#grid");
    if (!list.length) {
      grid.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="big">∅</div>' +
        "Nothing matches that. Try clearing a filter.</div>";
      return;
    }
    grid.innerHTML = list.map(cardHtml).join("");
  }

  /* --------------------------------------------------------------- smart */
  function renderSmartControls() {
    var tastes = (S.boot && S.boot.tastes) || {};
    var order = ["balanced", "beautiful", "lightest", "fastest"].filter(function (t) { return tastes[t]; });
    $("#tasteSeg").innerHTML = order.map(function (t) {
      return '<button data-taste="' + h(t) + '" title="' + h(tastes[t]) + '" class="' +
        (S.smart.taste === t ? "on" : "") + '">' + h(t.charAt(0).toUpperCase() + t.slice(1)) +
        "</button>";
    }).join("");
    $("#purposeSel").value = S.smart.purpose;
  }

  function runSmart() {
    var box = $("#smartOut");
    box.innerHTML = '<div class="skel" style="height:110px;margin-top:14px"></div>';
    api("/api/smart", { body: { taste: S.smart.taste, purpose: S.smart.purpose, limit: 3 } })
      .then(function (r) {
        if (!r.picks.length) {
          box.innerHTML = '<div class="warnbox" style="margin-top:14px">Nothing in the catalog fits ' +
            "this machine right now. Free some memory or disk and try again.</div>";
          return;
        }
        var fl = ["ram", "cpu", "disk", "beauty", "speed", "ready", "small"];
        box.innerHTML = '<p class="sub" style="margin:16px 0 10px">Weighed <b>' + r.considered +
          "</b> candidates against this machine, aiming for <b>" + h(r.taste) + "</b>.</p>" +
          '<div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(280px,1fr))">' +
          r.picks.map(function (p, i) {
            var e = p.entry;
            return '<div class="pick' + (i === 0 ? " best" : "") + '">' +
              '<div class="hd"><div class="logo" style="width:38px;height:38px;border-radius:11px;' +
              'display:grid;place-items:center;border:1px solid var(--line)">' +
              window.forgeLogo(e.family) + '</div><div style="min-width:0"><b>' + h(e.name) +
              '</b><div style="font-size:11.5px;color:var(--dim-2)">' + h(e.family_label) +
              " · " + h(e.de_label) + "</div></div>" +
              '<span class="score">' + p.score.toFixed(0) + "</span></div>" +
              '<ul class="why">' + p.why.map(function (w) { return "<li>" + h(w) + "</li>"; }).join("") +
              "</ul>" +
              '<div class="factors">' + fl.map(function (k) {
                var v = (p.factors[k] || 0) * 100;
                return '<div class="factor"><span>' + k + '</span><div class="bar"><i style="width:' +
                  v.toFixed(0) + '%"></i></div><b>' + v.toFixed(0) + "</b></div>";
              }).join("") + "</div>" +
              '<div class="row" style="margin-top:4px"><button class="btn primary sm" data-use="' +
              h(e.id) + '">See details</button><button class="btn sm" data-go="' + h(e.id) +
              '">Forge it now</button></div></div>';
          }).join("") + "</div>";
      }).catch(function (e) {
        box.innerHTML = '<div class="warnbox bad" style="margin-top:14px">' + h(e.message) + "</div>";
      });
  }

  /* -------------------------------------------------------------- detail */
  function openDetail(id, autostart) {
    show("configure");
    $("#dHero").innerHTML = '<div class="skel" style="height:96px"></div>';
    $("#dGallery").hidden = true;
    ["cfgTune", "cfgAuth", "cfgOpts", "dAbout", "cfgSpecs"].forEach(function (k) {
      $("#" + k).innerHTML = '<div class="skel" style="height:120px"></div>';
    });
    $("#dDocker").hidden = true;
    $("#goBar").innerHTML = "";
    Promise.all([
      api("/api/entry/" + encodeURIComponent(id)),
      api("/api/info/" + encodeURIComponent(id)).catch(function () { return null; })
    ]).then(function (r) {
      S.sel = r[0];
      S.info = r[1] || {};
      S.plan = Object.assign({}, r[0].plan);
      renderDetail();
      if (autostart) startLaunch();
    }).catch(function (err) {
      $("#dHero").innerHTML = '<div class="warnbox bad">Could not open that entry: ' + h(err.message) + "</div>";
    });
  }

  function trimText(t, n) {
    t = String(t || "").trim();
    if (t.length <= n) return t;
    var cut = t.slice(0, n);
    var dot = cut.lastIndexOf(". ");
    return (dot > n * 0.5 ? cut.slice(0, dot + 1) : cut.replace(/\s+\S*$/, "") + "…");
  }

  function renderDetail() {
    var e = S.sel, hst = S.host, inf = S.info || {};
    var noArch = e.arches.indexOf(hst.arch) < 0;
    var kasm = e.profile === "kasm";
    var distro = inf.distro, desk = inf.desktop, base = inf.based_on;
    var curated = (e.tags || []).indexOf("curated") >= 0;
    // A curated look ("Cupertino Clean") should describe itself, not Debian.
    var aboutText = curated ? e.desc : ((distro && distro.extract) || inf.fallback || e.desc);
    var aboutLink = curated ? null : distro;

    /* -- hero */
    $("#dHero").innerHTML =
      '<div class="dhero"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      '<div style="min-width:0"><h2>' + h(e.name) + "</h2>" +
      '<div class="tag">' + h(e.family_label) + " · " + h(e.de_label) + " · " +
      h(e.kind === "pull" ? "prebuilt image" : "built on this machine") + "</div>" +
      '<div class="badges" style="margin-top:10px">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + window.forgeGlyph(e.glyph) + h(e.de_label) + "</span>" +
      '<span class="badge' + (noArch ? " off" : "") + '">' + h(e.arches.join(" / ")) + "</span>" +
      (kasm ? '<span class="badge">kasm</span>' : "") + "</div>" +
      '<p class="about">' + h(trimText(aboutText, 400)) +
      (aboutLink && aboutLink.url ? ' <a href="' + h(aboutLink.url) + '" target="_blank" rel="noopener">' +
        "Read on Wikipedia ↗</a>" : "") + "</p></div>" +
      '<div class="go"><button class="btn primary" id="goBtn"' + (noArch ? " disabled" : "") +
      ">Forge " + h(e.name) + '</button><div class="sum" id="goSum"></div></div></div>' +
      (noArch ? '<div class="warnbox bad" style="margin:14px 0 0">This image has no ' + h(hst.arch) +
        " build, so it cannot run on this machine.</div>" : "");

    /* -- screenshots: first the real thing, captured by the forge running this
       exact entry; then Wikimedia's pictures of the distro and desktop in general */
    var shots = (S.boot && S.boot.shots) || {};
    var real = shots.ids && shots.ids[e.id] ? [{
      src: shots.base + e.id + ".jpg?d=" + encodeURIComponent(shots.ids[e.id].taken || ""),
      caption: "This exact desktop, running in Selkies Forge (captured " + (shots.ids[e.id].taken || "") + ")",
      about: e.name, real: true
    }] : [];
    var wiki = (inf.images || []).map(function (im) {
      return Object.assign({}, im, { caption: (im.caption || "") });
    });
    var imgs = real.concat(wiki);
    var gal = $("#dGallery");
    if (imgs.length) {
      S.gallery = imgs;
      gal.hidden = false;
      var realHtml = real.length ? '<figure class="shot real" data-shot="0"><div class="ph">' +
        '<img decoding="async" src="' + h(real[0].src) + '" alt="' + h(e.name) + '"></div>' +
        "<figcaption><b>What you get</b>" + h(real[0].caption) + "</figcaption></figure>" : "";
      gal.innerHTML = "<h3>Screenshots <span class=\"hint\">" +
        (real.length ? "a real capture of this desktop, then " : "") +
        (wiki.length ? wiki.length + " picture" + (wiki.length === 1 ? "" : "s") + " of " + h(e.de_label) +
          " from Wikimedia Commons" : "") +
        " · click to enlarge</span></h3>" + realHtml +
        (wiki.length ? (real.length ? '<div class="galsub">From Wikipedia: ' + h(e.de_label) +
          " on various systems, so themes and versions differ from this build</div>" : "") +
        '<div class="gallery">' + wiki.map(function (im, j) {
          var i = j + real.length;
          return '<figure class="shot" data-shot="' + i + '"><div class="ph">' +
            '<img loading="lazy" decoding="async" referrerpolicy="no-referrer" src="' + h(im.src) +
            '" alt="' + h(im.caption) + '"></div><figcaption><b>' +
            h(im.about || "") + "</b>" + h(im.caption) + "</figcaption></figure>";
        }).join("") + "</div>" : "") +
        '<p class="credit">Descriptions from Wikipedia and images from Wikimedia Commons, used under ' +
        "their CC licences. Open an image for its author and licence.</p>";
      $$("#dGallery img").forEach(function (img) {
        img.onload = function () { img.classList.add("ok"); };
        img.onerror = function () {
          var f = img.closest(".shot");
          if (f && f.classList.contains("real")) {
            var hint = $("#dGallery h3 .hint");
            if (hint) hint.textContent = (S.gallery.length - 1) + " pictures from Wikimedia Commons \u00b7 click to enlarge";
          }
          if (f) f.remove();
        };
        if (img.complete && img.naturalWidth) img.classList.add("ok");
      });
    } else {
      gal.hidden = true;
    }

    /* -- about the desktop + base */
    $("#dAbout").innerHTML = "<h3>About " + h(e.de_label) + "</h3>" +
      '<p class="prose">' + h(trimText((desk && desk.extract) || inf.desktop_blurb || e.desc, 560)) + "</p>" +
      (desk && desk.url ? '<a class="srclink" href="' + h(desk.url) +
        '" target="_blank" rel="noopener">Read on Wikipedia ↗</a>' : "") +
      (curated && distro && base ? sideArticle("Inspired by " + distro.title, distro) : "") +
      (curated && distro && !base ? sideArticle("Built on " + distro.title, distro) : "") +
      (base ? sideArticle("Built on " + base.title, base) : "");

    /* -- specs */
    $("#cfgSpecs").innerHTML = "<h3>At a glance</h3><dl class=\"kv\">" +
      "<dt>Download</dt><dd>" + mb(e.dl_mb) + "</dd>" +
      "<dt>On disk</dt><dd>about " + mb(e.disk_mb) + "</dd>" +
      "<dt>Idle memory</dt><dd>around " + mb(e.idle_mb) + "</dd>" +
      "<dt>Memory floor</dt><dd>" + mb(e.ram_min) + " (sweet spot " + mb(e.ram_rec) + ")</dd>" +
      "<dt>Cores wanted</dt><dd>" + e.cpu_rec + "</dd>" +
      "<dt>Weight</dt><dd>" + h(e.weight) + "</dd>" +
      "<dt>Image</dt><dd style=\"font-family:var(--mono);font-size:11.5px;word-break:break-all\">" +
      h(e.image || (e.recipe && e.recipe.image) || "-") + "</dd>" +
      (e.recipe && e.recipe.pkgs ? "<dt>Installs</dt><dd style=\"font-size:12px;color:var(--dim)\">" +
        h(e.recipe.pkgs) + "</dd>" : "") + "</dl>";

    /* -- 1 resources */
    var maxMem = Math.max(512, Math.min(hst.mem_total_mb - 256, hst.mem_avail_mb));
    var maxDisk = Math.max(20480, Math.min(hst.disk_free_mb, 400000));
    $("#cfgTune").innerHTML = '<h3><span class="num">1</span>Resources <span class="hint">' +
      mb(hst.mem_avail_mb) + " RAM free · " + hst.cpus + " cores · " +
      mb(hst.disk_free_mb) + " disk free</span></h3>" +
      slider("sMem", "Memory", 256, maxMem, 128, S.plan.memory_mb, mb, "needs at least " + mb(e.ram_min)) +
      slider("sCpu", "CPU cores", 0.5, hst.cpus, 0.5, S.plan.cpus,
        function (v) { return Number(v).toFixed(1) + " cores"; }, "wants " + e.cpu_rec) +
      slider("sShm", "Shared memory", 128, 4096, 64, S.plan.shm_mb, mb,
        "browsers inside want 512 MB or more") +
      slider("sDisk", "Storage", 5120, maxDisk, 1024, S.plan.disk_mb, mb,
        hst.quota_support ? "hard limit" : "budget, tracked") +
      (hst.quota_support ? "" : '<p class="sub" style="margin:2px 0 0;font-size:12px">' +
        h(hst.storage_driver + " on " + hst.backing_fs) + " cannot hard-cap one container's disk, " +
        "so storage is a tracked budget here rather than an enforced limit.</p>");

    /* -- 2 sign-in */
    $("#cfgAuth").innerHTML = '<h3><span class="num">2</span>Sign-in <span class="hint">' +
      (kasm ? "this image always asks for a password" : "off means anyone with the link gets straight in") +
      "</span></h3>" +
      '<label class="toggle"><input type="checkbox" id="oAuth"' + (kasm ? " checked" : "") +
      '><i></i><span>Ask for a username and password<small>' +
      (kasm ? "Kasm signs you in as kasm_user" : "basic auth in front of the desktop") +
      "</small></span></label>" +
      '<div id="authFields" style="display:' + (kasm ? "block" : "none") + ';margin-top:12px">' +
      '<label class="field"><span>Username</span><input type="text" id="oUser" value="' +
      (kasm ? "kasm_user" : "forge") + '"' + (kasm ? " disabled" : "") + "></label>" +
      '<label class="field"><span>Password</span><div class="row" style="gap:8px;flex-wrap:nowrap">' +
      '<input type="text" id="oPass" placeholder="type one, or generate" autocomplete="new-password" ' +
      'spellcheck="false"><button class="btn sm" type="button" id="genPass">Generate</button></div></label>' +
      '<p class="sub" style="margin:0;font-size:12px">It is shown again in the manager if you forget it.</p></div>';

    /* -- 3 options */
    $("#cfgOpts").innerHTML = '<h3><span class="num">3</span>Options</h3>' +
      '<label class="field"><span>Name (optional)</span><input type="text" id="oName" placeholder="' +
      h(e.id) + '"></label>' +
      toggle("oTunnel", true, "Public link through serveo",
        kasm ? "https image, so a short-lived TCP tunnel" : "an https link that works from anywhere") +
      toggle("oAuto", false, "Start with Docker",
        "off: it only runs when you start it, not after a reboot") +
      gpuField("oGpu", "auto") +
      toggle("oSeccomp", false, "Relax seccomp", "only if the desktop refuses to start; the forge tries this by itself") +
      idleField("oIdle", null) +
      (kasm ? "" : screenField("o", e.display || "fit", "auto", "1920x1080"));

    /* -- dockerfile */
    var dd = $("#dDocker");
    if (e.dockerfile) {
      dd.hidden = false;
      dd.innerHTML = '<div class="row"><h3 style="margin:0">How it is built</h3><div class="spacer"></div>' +
        '<button class="btn sm ghost" id="dfBtn">Show Dockerfile</button></div>' +
        '<pre class="code" id="dfOut" style="display:none;margin-top:12px">' + h(e.dockerfile) + "</pre>";
    } else {
      dd.hidden = true;
    }

    $("#goBar").innerHTML = '<div class="what" id="goWhat"></div>' +
      '<button class="btn sm ghost" data-back="browse">Cancel</button>' +
      '<button class="btn primary" id="goBtn2"' + (noArch ? " disabled" : "") + ">Forge it</button>";

    $$("#cfgTune input[type=range]").forEach(syncRange);
    updateGoSummary();

    $("#genPass").onclick = function () {
      var abc = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      var buf = new Uint32Array(16), out = "";
      if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(buf);
      else for (var j = 0; j < 16; j++) buf[j] = Math.floor(Math.random() * 1e9);
      for (var i = 0; i < 16; i++) out += abc.charAt(buf[i] % abc.length);
      $("#oPass").value = out;
      $("#oAuth").checked = true;
      $("#authFields").style.display = "block";
    };
  }

  function sideArticle(title, art) {
    return '<h3 style="margin-top:20px">' + h(title) + "</h3>" +
      '<p class="prose">' + h(trimText(art.extract || "", 300)) + "</p>" +
      (art.url ? '<a class="srclink" href="' + h(art.url) + '" target="_blank" rel="noopener">' +
        "Read on Wikipedia ↗</a>" : "");
  }

  /* Screen: follow the browser window, or a fixed size scaled to fit. Desktops
     that cannot cope with the screen changing size default to fixed. On 4K
     screens the forge layer's screen guard scales "follow" for the viewer. */
  function screenField(p, preferred, cur, res) {
    var auto = "Automatic \u00b7 " + (preferred === "fixed" ? "fixed size, scaled" : "follows your window");
    var opt = function (v, t) { return '<option value="' + v + '"' + (cur === v ? " selected" : "") + ">" + t + "</option>"; };
    var ropt = function (v) { return '<option value="' + v + '"' + (res === v ? " selected" : "") + ">" + v.replace("x", " \u00d7 ") + "</option>"; };
    return '<label class="field" style="margin-top:12px"><span>Screen</span><select id="' + p + 'Display" data-pref="' + preferred + '">' +
      opt("auto", auto) + opt("fit", "Follow my browser window") + opt("fixed", "Fixed size, scaled to fit") +
      "</select></label>" +
      '<label class="field" id="' + p + 'ResWrap" style="display:' +
      ((cur === "fixed" || (cur === "auto" && preferred === "fixed")) ? "block" : "none") +
      '"><span>Fixed size</span><select id="' + p + 'Res">' +
      ["1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440"].map(ropt).join("") + "</select></label>" +
      '<p class="sub" style="margin:2px 0 0;font-size:12px">' +
      (preferred === "fixed" ? "This desktop misdraws when the screen changes size under it, so it runs at a fixed size by default."
        : "Follow suits most desktops; on a 4K screen it's scaled up from a desktop about 1920 wide, so text stays readable. " +
          "Choose fixed if anything ever ends up off the edge.") + "</p>";
  }

  /* Stop when nobody's watching: the watchdog counts open tabs, and stops a
     desktop that has had none for this long. Its files are kept. */
  var IDLE_CHOICES = [["", "Forge default"], ["0", "Never"], ["30", "After 30 minutes"],
    ["60", "After 1 hour"], ["120", "After 2 hours"], ["240", "After 4 hours"]];
  /* GPU Smart Passthrough: auto checks what really works inside the image
     and falls back by itself; on forces it; off keeps the GPU out. */
  function gpuField(id, cur) {
    var g = (S.host && S.host.gpu) || {};
    var found = !!g.primary;
    var opt = function (v, t) { return '<option value="' + v + '"' + (cur === v ? " selected" : "") + ">" + t + "</option>"; };
    return '<label class="field" style="margin-top:12px"><span>GPU</span><select id="' + id + '">' +
      opt("auto", found ? "Smart · use it where it’s checked to work" : "Smart · none usable here, software") +
      opt("on", "Force on · skip the checks and fallbacks") +
      opt("off", "Off · draw and encode in software") +
      "</select></label>" +
      '<p class="sub" style="margin:2px 0 14px;font-size:12px">' + h(g.summary || "Detecting…") +
      (found ? ". Checked once inside the image; if the desktop misbehaves with it, the forge steps back to software by itself." : "") +
      "</p>";
  }

  function idleField(id, cur) {
    var v = cur === null || cur === undefined ? "" : String(cur);
    if (v && !IDLE_CHOICES.some(function (c) { return c[0] === v; })) IDLE_CHOICES.push([v, "After " + v + " minutes"]);
    return '<label class="field" style="margin-top:12px"><span>Stop when nobody\u2019s watching</span><select id="' + id + '">' +
      IDLE_CHOICES.map(function (c) {
        return '<option value="' + c[0] + '"' + (c[0] === v ? " selected" : "") + ">" + h(c[1]) + "</option>";
      }).join("") + "</select></label>" +
      '<p class="sub" style="margin:2px 0 0;font-size:12px">Frees its memory when no browser tab has it open. ' +
      "Files are kept; start it again any time. Needs the web UI running.</p>";
  }

  function slider(id, label, min, max, step, val, fmt, advice) {
    val = Math.max(min, Math.min(max, val));
    return '<div class="slider"><div class="lbl"><span>' + h(label) + ' <span class="adv">' +
      h(advice || "") + '</span></span><b id="' + id + 'V">' + fmt(val) + "</b></div>" +
      '<input type="range" id="' + id + '" min="' + min + '" max="' + max + '" step="' + step +
      '" value="' + val + '"></div>';
  }

  function toggle(id, on, label, hint) {
    return '<label class="toggle"><input type="checkbox" id="' + id + '"' + (on ? " checked" : "") +
      "><i></i><span>" + h(label) + "<small>" + h(hint) + "</small></span></label>";
  }

  function updateGoSummary() {
    if (!S.plan || !S.sel) return;
    var txt = mb(S.plan.memory_mb) + " RAM · " + Number(S.plan.cpus).toFixed(1) + " cores · " +
      mb(S.plan.shm_mb) + " shared · " + mb(S.plan.disk_mb) + " storage";
    var w = $("#goWhat");
    if (w) w.innerHTML = "<b>" + h(S.sel.name) + "</b> · " + h(txt);
    var s = $("#goSum");
    if (s) s.textContent = S.sel.kind === "pull" ? "About " + mb(S.sel.dl_mb) + " to download"
      : "Builds here · about " + mb(S.sel.dl_mb) + " to fetch";
  }

  function syncRange(r) {
    var pct = ((r.value - r.min) / (r.max - r.min)) * 100;
    r.style.setProperty("--pct", pct.toFixed(1) + "%");
  }

  /* ------------------------------------------------------------ lightbox */
  function openShot(i) {
    var list = S.gallery || [];
    if (!list.length) return;
    S.shotIdx = (i + list.length) % list.length;
    var im = list[S.shotIdx];
    $("#lbImg").src = im.src;
    $("#lbImg").alt = im.caption || "";
    $("#lbCount").textContent = (S.shotIdx + 1) + " of " + list.length + " · " + (im.about || "");
    $("#lbCap").innerHTML = h(im.caption || "") +
      (im.page ? ' · <a href="' + h(im.page) + '" target="_blank" rel="noopener">source and licence' +
        (im.license ? " (" + h(im.license) + ")" : "") + "</a>" : "");
    $("#lightbox").hidden = false;
  }

  function closeShot() { $("#lightbox").hidden = true; $("#lbImg").removeAttribute("src"); }

  /* -------------------------------------------------------------- launch */
  function startLaunch() {
    var e = S.sel;
    var opts = {
      tunnel: $("#oTunnel") ? $("#oTunnel").checked : true,
      autostart: $("#oAuto") ? $("#oAuto").checked : false,
      gpu: $("#oGpu") ? $("#oGpu").value : "auto",
      seccomp_unconfined: $("#oSeccomp") ? $("#oSeccomp").checked : false
    };
    if ($("#oDisplay")) {
      opts.display = $("#oDisplay").value;
      opts.resolution = $("#oRes").value;
    }
    if ($("#oIdle") && $("#oIdle").value !== "") opts.idle_stop = parseInt($("#oIdle").value, 10);
    var nm = $("#oName") && $("#oName").value.trim();
    if (nm) opts.name = nm;
    if ($("#oAuth") && $("#oAuth").checked) {
      opts.username = ($("#oUser").value || "forge").trim();
      opts.password = $("#oPass").value || Math.random().toString(36).slice(2, 10);
    }
    if (e.profile === "kasm" && !opts.password) opts.password = "forge";

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

    var cancelBtn = $("#lCancel");
    cancelBtn.hidden = true;
    cancelBtn.disabled = false;
    cancelBtn.textContent = "Cancel";
    api("/api/launch", { body: { id: e.id, plan: S.plan, opts: opts } }).then(function (r) {
      S.plan = r.plan;
      S.job = r.job;
      cancelBtn.hidden = false;
      cancelBtn.onclick = function () {
        if (!confirm("Stop forging " + e.name + "?\n\nWhatever is downloading or building stops, and a half-made desktop is removed.")) return;
        cancelBtn.disabled = true;
        cancelBtn.textContent = "Cancelling\u2026";
        api("/api/job/" + r.job.id + "/cancel", { body: {} }).catch(function (x) {
          toast("Could not cancel", x.message, "bad");
          cancelBtn.disabled = false;
          cancelBtn.textContent = "Cancel";
        });
      };
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
          cancelBtn.hidden = true;
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
          cancelBtn.hidden = true;
          if (err.cancelled) {
            renderSteps("error");
            setProgress(0, "cancelled", "Cancelled");
            term.line("");
            term.line("!! cancelled: " + (err.message || ""), "e");
            $("#lResult").innerHTML = '<div class="warnbox">Cancelled. ' + h(err.message || "") + "</div>" +
              '<div class="row"><button class="btn" data-back="browse">Back to the catalog</button></div>';
            toast("Cancelled", e.name);
            return;
          }
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
    ["layer", "forge layer"], ["create", "start"], ["health", "handshake"],
    ["session", "desktop"], ["tunnel", "tunnel"], ["ready", "ready"]];

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

    var warn = res.warning ? '<div class="warnbox bad"><b>Heads up.</b> ' + h(res.warning) +
      (res.session && res.session.log ? '<pre class="code" style="margin-top:10px;max-height:220px">' +
        h(res.session.log) + "</pre>" : "") + "</div>" : "";
    var fixed = (res.fixes && res.fixes.length) ? '<div class="warnbox"><b>Fixed on the way:</b> ' +
      h(res.fixes.map(function (f) {
        return ({ memory: "gave it more memory", shm: "more shared memory", seccomp: "relaxed seccomp",
                  slow: "waited longer for a slow first boot", restart: "restarted it once" })[f] || f;
      }).join(", ")) + ". Nothing for you to do.</div>" : "";
    var sess = res.session && res.session.wm ? '<div class="sub" style="margin:0 0 10px">' +
      h(res.session.wm) + " is up" + (res.display ? " \u00b7 screen: " + h(res.display === "fit" ?
        "follows your browser window" : res.display + ", scaled to fit") : "") + "</div>" : "";
    $("#lResult").innerHTML = '<div class="panel"><h3>' + h(e ? e.name : res.name) +
      (res.warning ? " started, with a problem" : " is running") + "</h3>" + sess + warn + fixed + cred +
      '<div class="result">' + rows.join("") + "</div>" +
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
      '<button class="btn" data-term="' + h(res.name) + '">' + I.term + "Open a shell</button>" +
      '<button class="btn" data-back="manager">Go to the manager</button>' +
      '<button class="btn ghost" data-back="browse">Forge another</button></div></div>';
  }

  function linkRow(what, url, cls, note) {
    if (!url) return "";
    return '<div class="link-row ' + (cls || "") + '"><span class="ico">' +
      (cls ? I.globe : I.home) + '</span><div style="min-width:0;flex:1">' +
      '<div class="what">' + h(what) + (note ? " &middot; " + h(note) : "") + "</div>" +
      '<a href="' + h(url) + '" target="_blank" rel="noopener">' + h(url) + "</a></div>" +
      '<button class="iconbtn" data-copy="' + h(url) + '" title="Copy">' + I.copy + "</button></div>";
  }

  /* ------------------------------------------------------------- manager */
  function instKey() {
    return S.instances.map(function (i) {
      var l = i.limits || {};
      return [i.name, i.running ? 1 : 0, (i.tunnel && i.tunnel.url) || "",
        (i.tunnel && i.tunnel.alive) ? 1 : 0, l.memory_mb, l.cpus, l.shm_mb, i.disk_cap_mb,
        i.autostart ? 1 : 0, i.auth ? i.auth.user : "",
        i.session ? [i.session.wm, i.session.mode, i.session.screen, i.session.viewers,
          Math.floor((i.session.idle_s || 0) / 60)].join("/") : "", i.idle_stop_min].join(":");
    }).join("|");
  }

  function renderManager() {
    var box = $("#instList");
    if (!S.instances.length) {
      $("#instStats").innerHTML = "";
      box.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="big">\u25A6</div>' +
        "Nothing forged yet.<br>Pick a desktop in <b>Browse</b> and it shows up here.</div>";
      S.instKey = "";
      return;
    }
    var key = instKey();
    if (key !== S.instKey) {
      var keepDrawer = S.drawerName && S.instances.some(function (i) {
        return i.name === S.drawerName && i.running;
      });
      var drawerEl = keepDrawer ? $("#drawerHost") : null;
      if (drawerEl) drawerEl.remove();
      else closeDrawer();
      S.instKey = key;
      box.innerHTML = S.instances.map(mcCard).join("");
      if (drawerEl) {
        var card = document.querySelector('.mc[data-name="' + cssq(S.drawerName) + '"]');
        if (card) card.appendChild(drawerEl); else closeDrawer();
      }
    }
    paintStats();
  }

  function shortHost(url) {
    var m = String(url).match(/^https?:\/\/([^/:]+)(:\d+)?/);
    if (!m) return { head: url, tail: "" };
    var parts = m[1].split(".");
    var head = parts.shift();
    if (head.length > 10) head = head.slice(0, 8) + "\u2026";
    return { head: head, tail: "." + parts.join(".") + (m[2] || "") };
  }

  function mcCard(i) {
    var running = i.running;
    var tun = (i.tunnel && i.tunnel.url) ? i.tunnel : null;
    var lim = i.limits || {};
    var fam = (S.boot && S.boot.family_labels && S.boot.family_labels[i.family]) || i.family;
    var rows = "";

    if (i.local_url) {
      var lp = i.local_url.replace(/^https?:\/\//, "");
      rows += arow("home", "Local", '<span>' + h(lp) + "</span>", i.local_url, i.local_url, "");
    }
    if (tun) {
      var sh = shortHost(tun.url);
      rows += arow("globe", "Public", '<span>' + h(sh.head) + '</span><span class="muted">' +
        h(sh.tail) + "</span>", tun.url, tun.url, "pub" + (tun.alive ? "" : " down"),
        tun.alive ? "" : "tunnel is down, use the menu to reopen it");
    }
    if (i.auth) {
      rows += '<div class="arow"><span class="ic">' + I.lock + '</span><span class="lab">Sign-in</span>' +
        '<span class="val" data-secret="' + h(i.name) + '"><span>' + h(i.auth.user) +
        '</span><span class="muted"> / \u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022</span></span>' +
        '<div class="acts"><button class="iconbtn" data-reveal="' + h(i.name) + '" title="Show password">' +
        I.eye + '</button><button class="iconbtn" data-copy="' + h(i.auth.password) +
        '" title="Copy password">' + I.copy + "</button></div></div>";
    }

    var actions = running
      ? '<a class="btn primary" href="' + h(i.local_url || "#") + '" target="_blank" rel="noopener">' +
        I.open + "Open desktop</a>" +
        '<button class="btn" data-drawer="' + h(i.name) + '">' + I.term + "Shell</button>" +
        '<button class="btn" data-act="stop">' + I.stop + "Stop</button>"
      : '<button class="btn primary" data-act="start">' + I.play + "Start</button>" +
        '<button class="btn" data-tune="' + h(i.name) + '">' + I.tune + "Limits</button>" +
        '<button class="btn" data-logs="' + h(i.name) + '">' + I.logs + "Logs</button>";

    return '<article class="mc ' + (running ? "up" : "") + '" data-name="' + h(i.name) + '">' +
      '<section class="mc-head"><div class="logo">' + window.forgeLogo(i.family) + "</div>" +
        '<div style="min-width:0"><div class="nm">' + h(i.title) + "</div>" +
        '<div class="sub2">' + h(fam) + " \u00b7 " + h(i.de_label || "") + " \u00b7 " + h(i.name) + "</div></div>" +
        '<span class="pill ' + (running ? "up" : (i.exit_code ? "bad" : "")) + '"><i></i>' +
        h(running ? "Running \u00b7 " + ago(i.started_at) : cap(i.status || "stopped")) + "</span>" +
      "</section>" +
      sessionLine(i) +
      '<section class="mc-metrics">' +
        metricCell(i.name, "cpu", "CPU") + metricCell(i.name, "mem", "Memory") +
        metricCell(i.name, "net", "Network") +
      "</section>" +
      (rows ? '<section class="mc-access">' + rows + "</section>" : "") +
      '<section class="mc-limits"><div class="limits-line">' +
        lchip("RAM", lim.memory_mb ? mb(lim.memory_mb) : "no cap") +
        lchip("CPU", lim.cpus ? lim.cpus + (lim.cpus === 1 ? " core" : " cores") : "No cap") +
        lchip("Shared", lim.shm_mb ? mb(lim.shm_mb) : "64 MB") +
        lchip("Storage", i.disk_cap_mb ? mb(i.disk_cap_mb) : "\u2014") +
        lchip("Auto-start", i.autostart ? "On" : "Off", i.autostart) +
        '</div><button class="btn sm" data-tune="' + h(i.name) + '">' + I.tune + "Edit</button>" +
      "</section>" +
      '<section class="mc-actions">' + actions +
        '<div class="menu-wrap"><button class="iconbtn" data-menu="' + h(i.name) + '" title="More">' +
        I.more + '</button><div class="menu" hidden>' +
          (running ? '<button data-act="restart">' + I.restart + "Restart</button>" : "") +
          (running ? (tun ? '<button data-act="untunnel">' + I.unplug + "Drop public link</button>"
                          : '<button data-act="tunnel">' + I.plug + "Open public link</button>") : "") +
          '<button data-logs="' + h(i.name) + '">' + I.logs + "Container logs</button>" +
          (i.profile === "kasm" ? "" : '<button data-act="repair" title="Recreate it on the newest forge layer; files are kept">' +
            I.restart + "Repair</button>") +
          '<button data-tune="' + h(i.name) + '">' + I.tune + "Edit limits</button>" +
          '<button data-act="idle" title="Stop it when nobody has it open">' + I.stop + "Stop when idle\u2026</button>" +
          "<hr>" +
          '<button data-act="backup" title="Copy its files (home folder) to a backup">' + I.save + "Back up files</button>" +
          '<button data-act="backups">' + I.logs + "Backups\u2026</button>" +
          '<button data-act="clone" title="A second desktop with a copy of its files">' + I.plus + "Clone\u2026</button>" +
          "<hr>" +
          '<button class="danger" data-act="remove">' + I.trash + "Remove</button>" +
        "</div></div>" +
      "</section>" +
    "</article>";
  }

  function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1); }

  /* What the forge agent inside the desktop last reported (via the watchdog). */
  function sessionLine(i) {
    var s = i.session;
    if (!i.running || !s) return "";
    if (s.mode === "rescue") {
      return '<section class="mc-session bad">Session crashed on start; a rescue window shows why. ' +
        '<button class="btn sm" data-logs="' + h(i.name) + '">See what happened</button></section>';
    }
    var watch = "";
    if (typeof s.viewers === "number") {
      watch = s.viewers ? " \u00b7 " + s.viewers + " watching"
        : " \u00b7 unwatched" + (s.idle_s >= 120 ? " " + dur(s.idle_s) : "");
      if (!s.viewers && i.idle_stop_min) {
        var left = i.idle_stop_min * 60 - (s.idle_s || 0);
        watch += left > 0 ? ", stops in " + dur(left) : ", stopping";
      }
    }
    if (!s.wm) return watch ? '<section class="mc-session">' + h(watch.slice(3)) + "</section>" : "";
    var scr = s.screen && s.screen !== "wayland" ? s.screen.replace("x", "\u00d7") : s.screen;
    return '<section class="mc-session"><i class="ok"></i>' + h(s.wm) + " running" +
      (scr ? " \u00b7 " + h(scr) : "") + ((i.display || "").indexOf("fixed") === 0 ? " \u00b7 fixed size, scaled" : "") +
      h(watch) + "</section>";
  }
  function dur(sec) {
    sec = Math.max(0, Math.round(sec));
    if (sec < 90) return sec + "s";
    if (sec < 5400) return Math.round(sec / 60) + " min";
    return (sec / 3600).toFixed(sec < 36000 ? 1 : 0) + " h";
  }
  function catEntry(id) {
    var c = (S.boot && S.boot.catalog) || [];
    for (var k = 0; k < c.length; k++) if (c[k].id === id) return c[k];
    return null;
  }

  function arow(icon, label, valHtml, copyText, openUrl, cls, title) {
    return '<div class="arow ' + (cls || "") + '"' + (title ? ' title="' + h(title) + '"' : "") + ">" +
      '<span class="ic">' + I[icon] + '</span><span class="lab">' + h(label) + "</span>" +
      '<span class="val">' + valHtml + "</span>" +
      '<div class="acts"><button class="iconbtn" data-copy="' + h(copyText) + '" title="Copy">' + I.copy +
      '</button><a class="iconbtn" href="' + h(openUrl) + '" target="_blank" rel="noopener" title="Open">' +
      I.open + "</a></div></div>";
  }

  function lchip(k, v, on) {
    return '<span class="lchip' + (on ? " on" : "") + '"><span>' + h(k) + "</span>" + h(v) + "</span>";
  }

  function metricCell(name, kind, label) {
    var body = kind === "net"
      ? '<div class="sparkbox" data-spark="net" data-name="' + h(name) + '"></div>'
      : '<div class="bar" data-bar="' + kind + '" data-name="' + h(name) + '"><i></i></div>';
    return '<div class="m"><div class="k">' + h(label) + "</div>" +
      '<div class="v" data-metric="' + kind + '" data-name="' + h(name) + '">\u2014</div>' + body + "</div>";
  }

  /* Numbers repaint in place every few seconds; rebuilding the cards each
     time would drop an open shell and make the page crawl on a small box. */
  function paintStats() {
    var totRx = 0, totTx = 0, totMem = 0, running = 0;
    S.instances.forEach(function (i) {
      var st = S.stats[i.name] || {};
      totRx += st.rx_total || 0;
      totTx += st.tx_total || 0;
      totMem += st.mem_mb || 0;
      if (i.running) running++;
      if (!i.running) {
        set(i.name, "cpu", '<small>stopped</small>');
        set(i.name, "mem", '<small>stopped</small>');
        set(i.name, "net", '<small>stopped</small>');
        bar(i.name, "cpu", 0); bar(i.name, "mem", 0);
        return;
      }
      set(i.name, "cpu", st.cpu != null ? st.cpu.toFixed(1) + "<small> %</small>" : "\u2014");
      set(i.name, "mem", st.mem_mb != null ? Math.round(st.mem_mb) + "<small> of " +
        mb(st.mem_limit_mb || 0) + "</small>" : "\u2014");
      set(i.name, "net", bytes((st.rx_total || 0) + (st.tx_total || 0)) +
        (st.rx_rate || st.tx_rate ? "<small> \u00b7 " + bytes((st.rx_rate || 0) + (st.tx_rate || 0)) + "/s</small>" : ""));
      bar(i.name, "cpu", Math.min(100, st.cpu || 0));
      bar(i.name, "mem", st.mem_pct || 0);
      var sp = document.querySelector('[data-spark="net"][data-name="' + cssq(i.name) + '"]');
      if (sp) sp.innerHTML = sparkline(st.spark_net || []);
    });
    $("#instStats").innerHTML =
      stat("Desktops", S.instances.length, running + " running") +
      stat("Memory in use", mb(totMem), "across running desktops") +
      stat("Downloaded", bytes(totRx), "into the desktops") +
      stat("Uploaded", bytes(totTx), "out of the desktops");
  }

  function cssq(s) { return String(s).replace(/["\\]/g, "\\$&"); }

  function set(name, kind, html) {
    var el = document.querySelector('[data-metric="' + kind + '"][data-name="' + cssq(name) + '"]');
    if (el) el.innerHTML = html;
  }

  function bar(name, kind, pct) {
    var el = document.querySelector('[data-bar="' + kind + '"][data-name="' + cssq(name) + '"]');
    if (!el) return;
    el.className = "bar" + (pct > 88 ? " bad" : pct > 70 ? " warn" : "");
    el.firstChild.style.width = Math.max(0, Math.min(100, pct)).toFixed(0) + "%";
  }

  function stat(k, v, s) {
    return '<div class="stat"><div class="k">' + h(k) + '</div><div class="v">' + h(v) +
      '</div><div class="s">' + h(s) + "</div></div>";
  }

  function closeMenus(except) {
    $$(".menu").forEach(function (m) { if (m !== except) m.hidden = true; });
    $$("[data-menu]").forEach(function (b) { b.classList.remove("on"); });
    if (except) {
      var btn = except.parentNode.querySelector("[data-menu]");
      if (btn) btn.classList.add("on");
    }
  }

  /* Long jobs started from the manager (backup, restore, clone) report back
     through the job API; the Working strip shows them while they run. */
  function watchJob(id, label, onDone) {
    var tick = function () {
      api("/api/job/" + id).then(function (j) {
        if (j.status === "running") { setTimeout(tick, 1500); return; }
        if (j.status === "done") toast(label + " done", (j.result && (j.result.file || j.result.name)) || "", "ok");
        else toast(label + (j.status === "cancelled" ? " cancelled" : " failed"),
          (j.error && j.error.message) || j.status, j.status === "cancelled" ? "" : "bad");
        S.instKey = "";
        refreshInstances();
        refreshJobs();
        if (onDone) onDone(j);
      }).catch(function () { setTimeout(tick, 3000); });
    };
    setTimeout(tick, 800);
    refreshJobs();
  }

  function startJob(url, body, label, onDone) {
    toast(label + "\u2026", "");
    return api(url, { body: body || {} }).then(function (r) { watchJob(r.job.id, label, onDone); })
      .catch(function (e) { toast(label + " failed", e.message, "bad"); });
  }

  function showBackups(name) {
    openModal("Backups \u00b7 " + name, '<div class="skel" style="height:120px"></div>');
    api("/api/backups?name=" + encodeURIComponent(name)).then(function (r) {
      var rows = r.backups || [];
      $("#modalBody").innerHTML =
        '<div class="row" style="margin-bottom:12px"><p class="sub" style="margin:0;flex:1">Copies of this desktop\u2019s ' +
        "home folder (caches left out). Restoring takes a safety copy of the current files first.</p>" +
        '<button class="btn sm primary" data-bk="new">Back up now</button></div>' +
        (rows.length ? '<div class="evlist">' + rows.map(function (b) {
          return '<div class="ev"><span class="t">' + h(new Date(b.created * 1000).toLocaleString()) + "</span>" +
            "<b>" + h(mb(b.size / 1048576)) + (b.tag ? " \u00b7 " + h(b.tag) : "") + "</b>" +
            '<span class="d">' + h(b.file) + "</span>" +
            '<span class="row" style="gap:6px;margin-left:auto">' +
            '<button class="btn sm" data-bk="restore" data-file="' + h(b.file) + '">Restore</button>' +
            '<button class="btn sm ghost" data-bk="fork" data-file="' + h(b.file) + '">New desktop</button>' +
            '<button class="btn sm ghost" data-bk="del" data-file="' + h(b.file) + '">Delete</button></span></div>';
        }).join("") + "</div>" : '<div class="empty">No backups yet.</div>');
      $$("#modalBody [data-bk]").forEach(function (b) {
        b.onclick = function () {
          var f = b.dataset.file, k = b.dataset.bk;
          if (k === "new") { closeModal(); startJob("/api/instance/" + encodeURIComponent(name) + "/backup", {}, "Backup of " + name); }
          if (k === "restore" && confirm("Replace " + name + "\u2019s files with this backup?\n\n" + f +
              "\n\nA safety backup of the current files is taken first. A running desktop restarts.")) {
            closeModal(); startJob("/api/backups/restore", { name: name, file: f }, "Restore of " + name);
          }
          if (k === "fork") {
            var nn = prompt("Name for the new desktop (optional)", "");
            if (nn === null) return;
            closeModal(); startJob("/api/backups/clone", { file: f, name: nn.trim() }, "New desktop from backup");
          }
          if (k === "del" && confirm("Delete this backup for good?\n\n" + f)) {
            api("/api/backups/delete", { body: { file: f } }).then(function () { showBackups(name); })
              .catch(function (e) { toast("Delete failed", e.message, "bad"); });
          }
        };
      });
    }).catch(function (e) { $("#modalBody").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>"; });
  }

  function instAction(name, act) {
    var body = {};
    var enc = encodeURIComponent(name);
    if (act === "backup") return startJob("/api/instance/" + enc + "/backup", {}, "Backup of " + name);
    if (act === "backups") return showBackups(name);
    if (act === "clone") {
      var nn = prompt("Clone " + name + "\n\nA second desktop with a copy of all its files, the same limits " +
        "and options. Name for the copy (optional):", "");
      if (nn === null) return;
      return startJob("/api/instance/" + enc + "/clone", { name: nn.trim() }, "Clone of " + name);
    }
    if (act === "idle") {
      var cur = (S.instances.filter(function (x) { return x.name === name; })[0] || {}).idle_stop_min || 0;
      var mins = prompt("Stop " + name + " after how many minutes with nobody watching?\n\n" +
        "0 = never. Leave empty for the forge default. Files are always kept.", cur ? String(cur) : "");
      if (mins === null) return;
      return api("/api/instance/" + enc + "/idle", { body: { minutes: mins.trim() === "" ? null : parseInt(mins, 10) || 0 } })
        .then(function (r) {
          toast("Idle stop " + (r.idle_stop_min ? "after " + r.idle_stop_min + " min" : r.idle_stop_min === 0 ? "off" : "default"), name, "ok");
          S.instKey = ""; refreshInstances();
        }).catch(function (e) { toast("Could not set it", e.message, "bad"); });
    }
    if (act === "repair" && !confirm("Repair " + name + "?\n\nIt is recreated on the newest forge layer " +
        "(first-run fixes, screen agent, crash supervisor). Your files in /config are kept; it restarts.")) return;
    if (act === "remove") {
      if (!confirm("Remove " + name + "?")) return;
      body.purge = confirm("Also delete its saved files (the /config volume)?\n\nOK deletes them, Cancel keeps them.");
    }
    var card = document.querySelector('.mc[data-name="' + cssq(name) + '"]');
    if (card) card.classList.add("busy");
    toast(cap(act) + "\u2026", name);
    api("/api/instance/" + encodeURIComponent(name) + "/" + act, { body: body })
      .then(function (r) {
        if (r.warning) toast(cap(act) + " done, with a problem", r.warning, "bad");
        else toast(cap(act) + " done", (r.tunnel && r.tunnel.url) || name, "ok");
        S.instKey = "";
        refreshInstances();
      })
      .catch(function (e) { toast(cap(act) + " failed", e.message, "bad"); })
      .then(function () { if (card) card.classList.remove("busy"); });
  }

  /* ---------------------------------------------------------------- modal */
  function openModal(title, html) {
    $("#modalTitle").textContent = title;
    $("#modalBody").innerHTML = html;
    $("#modal").style.display = "grid";
  }

  // Every close path hides first and tidies up after, so nothing that goes
  // wrong while tidying can leave a panel stuck open.
  function closeModal() {
    $("#modal").style.display = "none";
    try { $("#modalBody").innerHTML = ""; } catch (e) { console.error(e); }
  }

  function showLogs(name) {
    openModal("Logs \u00b7 " + name, '<div class="skel" style="height:200px"></div>');
    api("/api/logs/" + encodeURIComponent(name) + "?tail=400").then(function (r) {
      var evs = (r.events || []).slice().reverse();
      var EV = { create: "created", ready: "ready", crashed: "crashed", healed: "restarted after a crash",
        "heal-skipped": "crashed too often, left stopped", "session-rescue": "session crashed, rescue shown",
        stop: "stopped", start: "started", restart: "restarted", repair: "repaired", retune: "limits changed",
        recreate: "recreated", "launch-failed": "launch failed", "launch-cancelled": "launch cancelled",
        stopped: "stopped outside the forge", "session-frozen": "froze (no sign of life)",
        "idle-stop": "stopped: nobody was watching", "pressure-stop": "stopped: the machine was out of memory",
        "launch-interrupted": "launch interrupted", backup: "backed up", restored: "files restored",
        cloned: "cloned", "idle-limit": "idle stop changed", "heal-failed": "restart after a crash failed" };
      var evHtml = evs.length ? '<h3 style="margin:0 0 8px">What happened</h3><div class="evlist">' +
        evs.map(function (x) {
          var bad = /crash|fail|rescue|skipped|frozen|interrupted|pressure/.test(x.event);
          return '<div class="ev' + (bad ? " bad" : "") + '"><span class="t">' +
            h(new Date(x.ts * 1000).toLocaleString()) + '</span><b>' + h(EV[x.event] || x.event) + "</b>" +
            (x.detail && x.detail !== "requested" ? '<span class="d">' + h(x.detail) + "</span>" : "") + "</div>";
        }).join("") + '</div><h3 style="margin:16px 0 8px">Container log</h3>' : "";
      $("#modalBody").innerHTML = evHtml + '<pre class="code" style="max-height:52vh">' + h(r.logs || "(empty)") + "</pre>";
    }).catch(function (e) {
      $("#modalBody").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
    });
  }

  function showTune(name) {
    var i = S.instances.filter(function (x) { return x.name === name; })[0];
    if (!i) return;
    var L = i.limits || {};
    var cur = {
      mem: L.memory_mb || 1024, cpu: L.cpus || 1, shm: L.shm_mb || 256,
      disk: i.disk_cap_mb || 10240, auto: !!i.autostart,
      display: (i.display || "").indexOf("fixed") === 0 ? "fixed" : (i.display === "fit" ? "fit" : "auto"),
      res: (i.display || "").indexOf("fixed:") === 0 ? i.display.slice(6) : ""
    };
    var maxMem = Math.max(512, S.host.mem_total_mb - 256);
    var maxDisk = Math.max(20480, Math.min(S.host.disk_free_mb, 400000));
    openModal("Limits \u00b7 " + i.title,
      '<p class="sub" style="margin-top:-4px">Memory, CPU and auto-start change instantly. ' +
      "Shared memory, storage and the screen mode need the desktop recreated; your files in /config are kept.</p>" +
      slider("tMem", "Memory", 256, maxMem, 128, cur.mem, mb, "live") +
      slider("tCpu", "CPU cores", 0.5, S.host.cpus, 0.5, cur.cpu,
        function (v) { return Number(v).toFixed(1) + " cores"; }, "live") +
      slider("tShm", "Shared memory", 128, 4096, 64, cur.shm, mb, "restarts it \u00b7 browsers want 512 MB+") +
      slider("tDisk", "Storage", 5120, maxDisk, 1024, cur.disk, mb,
        S.host.quota_support ? "restarts it" : "restarts it \u00b7 tracked budget") +
      toggle("tAuto", cur.auto, "Start with Docker", "on: comes back after a reboot. off: only when you start it") +
      (i.profile === "kasm" ? "" : screenField("t", (catEntry(i.entry_id) || {}).display || "fit",
        cur.display, cur.res || "1920x1080")) +
      '<div class="row" style="margin-top:16px"><span class="sub" id="tNote" style="margin:0;flex:1"></span>' +
      '<button class="btn ghost" id="tCancel" type="button">Cancel</button>' +
      '<button class="btn primary" id="tApply" type="button">Apply</button></div>');
    $$("#modalBody input[type=range]").forEach(syncRange);

    function changed() {
      return {
        mem: Number($("#tMem").value), cpu: Number($("#tCpu").value),
        shm: Number($("#tShm").value), disk: Number($("#tDisk").value), auto: $("#tAuto").checked,
        display: $("#tDisplay") ? $("#tDisplay").value : cur.display,
        res: $("#tRes") ? $("#tRes").value : cur.res
      };
    }
    function note() {
      var c = changed();
      var screen = c.display !== cur.display || (c.display === "fixed" && c.res !== cur.res);
      var restart = c.shm !== cur.shm || c.disk !== cur.disk || screen;
      var any = restart || c.mem !== cur.mem || c.cpu !== cur.cpu || c.auto !== cur.auto;
      $("#tNote").textContent = !any ? "Nothing changed yet." :
        restart ? "This restarts the desktop to apply (about half a minute). Files are kept." :
        "Applies instantly, no restart.";
      $("#tApply").disabled = !any;
    }
    $("#modalBody").oninput = function (ev) {
      var t = ev.target;
      if (t.type === "range") {
        syncRange(t);
        var fmt = t.id === "tCpu" ? Number(t.value).toFixed(1) + " cores" : mb(t.value);
        $("#" + t.id + "V").textContent = fmt;
      }
      note();
    };
    $("#modalBody").onchange = note;
    $("#tCancel").onclick = closeModal;
    $("#tApply").onclick = function () {
      var c = changed();
      var body = {};
      if (c.mem !== cur.mem) body.memory_mb = c.mem;
      if (c.cpu !== cur.cpu) body.cpus = c.cpu;
      if (c.shm !== cur.shm) body.shm_mb = c.shm;
      if (c.disk !== cur.disk) body.disk_mb = c.disk;
      if (c.auto !== cur.auto) body.autostart = c.auto;
      if (c.display !== cur.display || (c.display === "fixed" && c.res !== cur.res)) {
        body.display = c.display;
        body.resolution = c.res;
      }
      var btn = $("#tApply");
      btn.disabled = true;
      var rec = body.shm_mb || body.disk_mb || body.display;
      btn.textContent = rec ? "Recreating\u2026" : "Applying\u2026";
      if (S.drawerName === name && rec) closeDrawer();
      api("/api/instance/" + encodeURIComponent(name) + "/retune", { body: body })
        .then(function (r) {
          toast(r.recreated ? "Recreated with new limits" : "Limits applied", name, "ok");
          closeModal();
          S.instKey = "";
          refreshInstances();
        })
        .catch(function (e) {
          toast("Could not change limits", e.message, "bad");
          btn.disabled = false;
          btn.textContent = "Apply";
        });
    };
    note();
  }

  /* ------------------------------------------------------------ terminal */
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
      default: return (k && k.length === 1) ? k : null;
    }
  }

  /* One attach routine, used by the full Shell view and by the drawer that
     slides out of a manager card. */
  function attachTerm(cfg) {
    var term = new window.ForgeTerm(cfg.el, { cols: 100, rows: cfg.rows || 28 });
    var sess = { id: null, es: null, term: term, name: cfg.name, dead: false };
    var t0 = Date.now();
    var frames = "\u280b\u2819\u2839\u2838\u283c\u2834\u2826\u2827\u2807\u280f";
    var fi = 0, live = false;
    var spin = setInterval(function () {
      head(frames.charAt(fi++ % 10) + "  attaching to " + cfg.name + "  " +
           ((Date.now() - t0) / 1000).toFixed(1) + "s");
      if (fi === 90) term.line("still waiting on docker exec, the container may be busy", "d");
    }, 90);

    function head(txt) { if (cfg.head) cfg.head.textContent = txt; }
    function settled(txt) { if (spin) { clearInterval(spin); spin = null; } head(txt); }

    term.line("connecting to " + cfg.name + " ...", "d");
    term.line("");

    var fit = term.fit();
    api("/api/term", { body: { container: cfg.name, cols: fit.cols, rows: fit.rows } })
      .then(function (r) {
        sess.id = r.id;
        head("handshaking with the shell\u2026");
        sess.es = sse("/api/term/" + r.id + "/stream", {
          data: function (d) {
            if (!live) {
              live = true;
              settled("docker exec \u00b7 " + cfg.name + "  \u00b7  " +
                      ((Date.now() - t0) / 1000).toFixed(1) + "s to attach");
            }
            var raw = atob(typeof d === "string" ? d.replace(/^"|"$/g, "") : d);
            var out;
            try { out = decodeURIComponent(escape(raw)); } catch (e) { out = raw; }
            term.write(out);
          },
          closed: function () {
            sess.dead = true;
            settled("session closed \u00b7 " + cfg.name);
            term.line("");
            term.line("[session closed]", "d");
          },
          error: function () {}
        });
        cfg.el.focus();
      })
      .catch(function (e) {
        settled("could not attach");
        term.line("could not open a shell: " + e.message, "e");
      });

    function onKey(ev) {
      if (ev.metaKey || ev.altKey) return;
      if (ev.ctrlKey && (ev.key === "c" || ev.key === "v") && window.getSelection().toString()) return;
      var seq = keyToSeq(ev);
      if (seq != null) {
        ev.preventDefault();
        if (sess.id) api("/api/term/" + sess.id + "/input", { body: { data: seq } })
          .catch(function () {});
      }
    }
    function onPaste(ev) {
      ev.preventDefault();
      var txt = (ev.clipboardData || window.clipboardData).getData("text");
      if (sess.id) api("/api/term/" + sess.id + "/input", { body: { data: txt } })
        .catch(function () {});
    }
    cfg.el.addEventListener("keydown", onKey);
    cfg.el.addEventListener("paste", onPaste);

    sess.refit = function () {
      var f = term.fit();
      if (sess.id) api("/api/term/" + sess.id + "/resize", { body: f }).catch(function () {});
      return f;
    };
    sess.close = function () {
      if (spin) { clearInterval(spin); spin = null; }
      cfg.el.removeEventListener("keydown", onKey);
      cfg.el.removeEventListener("paste", onPaste);
      if (sess.es) sess.es.close();
      if (sess.id) api("/api/term/" + sess.id + "/close", { body: {} }).catch(function () {});
      sess.dead = true;
    };
    return sess;
  }

  function closeShell() {
    var s = S.shell;
    S.shell = null;
    if (s) { try { s.close(); } catch (e) { console.error(e); } }
  }

  function closeDrawer() {
    var d = $("#drawerHost");
    if (d) d.remove();
    var s = S.drawerSess;
    S.drawerSess = null;
    S.drawerName = null;
    if (s) { try { s.close(); } catch (e) { console.error(e); } }
  }

  /* The shell slides out inside the card you clicked, so you keep the
     instance's numbers in view while you type. */
  function toggleDrawer(name) {
    if (S.drawerName === name) { closeDrawer(); return; }
    closeDrawer();
    var card = document.querySelector('.mc[data-name="' + cssq(name) + '"]');
    if (!card) return;
    var host = document.createElement("div");
    host.id = "drawerHost";
    host.className = "drawer";
    host.innerHTML = '<div class="drawer-head"><span id="drawerHead">starting\u2026</span>' +
      '<div class="spacer" style="flex:1"></div>' +
      '<button class="iconbtn" id="drawerFit" title="Fit to size">' + I.fit + "</button>" +
      '<button class="iconbtn" id="drawerPop" title="Open the full shell view">' + I.open + "</button>" +
      '<button class="iconbtn" id="drawerClose" title="Close">' + I.close + "</button></div>" +
      '<pre class="term" id="drawerTerm" tabindex="0" style="outline:none"></pre>';
    card.appendChild(host);
    S.drawerName = name;
    S.drawerSess = attachTerm({ el: $("#drawerTerm"), head: $("#drawerHead"), name: name, rows: 20 });
    $("#drawerFit").onclick = function () {
      var f = S.drawerSess.refit();
      toast("Resized", f.cols + "\u00d7" + f.rows);
    };
    $("#drawerClose").onclick = closeDrawer;
    $("#drawerPop").onclick = function () { closeDrawer(); openTerm(name); };
    host.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  function openTerm(name) {
    closeShell();
    show("shell");
    $("#shTitle").textContent = name;
    var el = $("#shTerm");
    el.innerHTML = "";
    S.shell = attachTerm({ el: el, head: $("#shHead"), name: name, rows: 28 });
    S.termName = name;
  }

  /* ---------------------------------------------------------------- host */
  function renderHost() {
    renderHostLife();
    renderSpace();
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

  /* ----------------------------------------------------------- lifecycle */
  /* After a reboot or a crash the server knows which desktops were running;
     offer to start them again, and show whether the UI starts on boot. */
  function pollLife() {
    api("/api/lifecycle").then(renderLife).catch(function () {}).then(function () {
      setTimeout(pollLife, 90000);
    });
  }

  function renderLife(L) {
    S.life = L;
    var bar = $("#lifeBar");
    var ls = L && L.last_stop;
    if (ls && !ls.dismissed && ls.restore && ls.restore.length) {
      var n = ls.restore.length;
      bar.className = "updbar life" + (ls.clean ? "" : " warn");
      bar.innerHTML = '<span class="ic">' + I.restart + "</span>" +
        '<div class="msg"><b>Last stop: ' + h(ls.label || "the web UI stopped") + "</b><small>" + n +
        " desktop" + (n === 1 ? " that was" : "s that were") + " running then " + (n === 1 ? "is" : "are") +
        " stopped now: " + h(ls.restore.map(function (x) { return x.replace(/^forge-/, ""); }).join(", ")) + "</small></div>" +
        '<button class="btn primary sm" id="lifeRestore" type="button">Start ' + (n === 1 ? "it" : "them") + " again</button>" +
        '<button class="iconbtn" id="lifeHide" type="button" title="Dismiss">' + I.close + "</button>";
      bar.hidden = false;
      $("#lifeRestore").onclick = function () {
        var b = $("#lifeRestore");
        b.disabled = true; b.textContent = "Starting\u2026";
        api("/api/restore", { body: {} }).then(function (r) {
          toast("Started again", (r.started || []).join(", ") || "nothing needed starting", "ok");
          bar.hidden = true; S.instKey = ""; refreshInstances();
        }).catch(function (e) { toast("Could not start them", e.message, "bad"); b.disabled = false; });
      };
      $("#lifeHide").onclick = function () {
        bar.hidden = true;
        api("/api/last-stop/dismiss", { body: {} }).catch(function () {});
      };
    } else {
      bar.hidden = true;
    }
    if (S.view === "host") renderHostLife();
  }

  function renderSpace() {
    var el = $("#hostSpace");
    if (!el) return;
    api("/api/space").then(function (r) {
      var g = r.groups || {};
      var sum = function (list, used) {
        return (list || []).filter(function (x) { return used === undefined || x.in_use === used; })
          .reduce(function (a, x) { return a + (x.size_mb || 0); }, 0);
      };
      var row = function (k, list, note) {
        var n = (list || []).length;
        return "<dt>" + h(k) + "</dt><dd>" + n + (n ? " \u00b7 " + mb(sum(list)) : "") +
          (note ? ' <span class="muted">' + h(note) + "</span>" : "") + "</dd>";
      };
      el.innerHTML = '<dl class="kv">' +
        row("Forge layers", g.layers, "a few KB on top of each image") +
        row("Built desktops", g.built, mb(sum(g.built, false)) + " unused") +
        row("Pulled desktops", g.pulled, mb(sum(g.pulled, false)) + " unused") +
        row("Base images", g.bases) +
        "<dt>Build cache</dt><dd>" + mb(r.build_cache_mb || 0) + "</dd>" +
        "<dt>Orphan volumes</dt><dd>" + (r.orphan_volumes || []).length +
        ' <span class="muted">files of removed desktops you chose to keep</span></dd></dl>' +
        '<div class="row" style="margin-top:12px"><button class="btn sm" id="spClean">Tidy up (' +
        mb(r.reclaimable_mb || 0) + ")</button>" +
        '<button class="btn sm ghost" id="spCleanAll">Remove everything unused (' + mb(r.reclaimable_all_mb || 0) +
        ")</button></div>" +
        '<p class="sub" style="font-size:12px;margin:8px 0 0">Nothing a desktop uses is ever removed. ' +
        "Kept files of removed desktops stay unless you delete them from the terminal (selkies-cli clean).</p>";
      var go = function (all) {
        if (all && !confirm("Remove every desktop image no desktop uses, and Docker's build cache?\n\n" +
            "They download or rebuild again if you forge those desktops later.")) return;
        el.querySelectorAll("button").forEach(function (b) { b.disabled = true; });
        api("/api/space/clean", { body: { all: all } }).then(function (x) {
          toast("Cleaned up", (x.removed_images || []).length + " images removed", "ok");
          renderSpace();
        }).catch(function (x) { toast("Clean-up failed", x.message, "bad"); renderSpace(); });
      };
      $("#spClean").onclick = function () { go(false); };
      $("#spCleanAll").onclick = function () { go(true); };
    }).catch(function (x) { el.innerHTML = '<div class="warnbox bad">' + h(x.message) + "</div>"; });
  }

  function renderHostLife() {
    var el = $("#hostLife");
    if (!el) return;
    var L = S.life || {};
    var b = L.boot || {}, ls = L.last_stop;
    el.innerHTML = toggle("bootToggle", !!b.enabled, "Start the web UI when this machine boots",
        b.enabled ? ("on, through " + (b.method === "systemd" ? "a systemd user service" : "cron") +
          (b.method === "systemd" && b.linger === false ? "; it waits for you to log in until linger is on " +
            "(sudo loginctl enable-linger $USER)" : "")) : "off: start it yourself with selkies-cli") +
      (ls ? '<p class="sub" style="margin:12px 0 0">Last stop: ' + h(ls.label || ls.reason) +
        (ls.at ? " \u00b7 " + h(new Date(ls.at * 1000).toLocaleString()) : "") + "</p>" : "");
    $("#bootToggle").onchange = function (ev) {
      var on = ev.target.checked;
      ev.target.disabled = true;
      api("/api/autostart-ui", { body: { enable: on } }).then(function (r) {
        toast(on ? "Starts on boot" : "No longer starts on boot",
          r.needs ? "run: " + r.needs + " so it starts before anyone logs in" : (r.method || ""), r.needs ? "" : "ok");
        return api("/api/lifecycle").then(renderLife);
      }).catch(function (e) {
        toast("Could not change that", e.message, "bad");
        ev.target.checked = !on;
      }).then(function () { ev.target.disabled = false; });
    };
  }

  /* ------------------------------------------------------------- updates */
  /* The server checks GitHub every 5 minutes and installs new builds on its
     own; this just asks the local server whether one is waiting. */
  function pollUpdate() {
    api("/api/update").then(renderUpdate).catch(function () {}).then(function () {
      setTimeout(pollUpdate, 60000);
    });
  }

  function renderUpdate(u) {
    var bar = $("#updBar");
    if (!u || S.restarting) return;
    if (u.restart_needed) {
      bar.className = "updbar";
      bar.innerHTML = '<span class="ic">' + I.upd + "</span>" +
        '<div class="msg"><b>Selkies Forge ' + h(u.installed_version || "update") +
        " is installed</b><small>Restart the web UI to start using it. Your desktops keep running.</small></div>" +
        '<button class="btn primary sm" id="updRestart" type="button">Restart now</button>' +
        '<button class="iconbtn" id="updHide" type="button" title="Later">' + I.close + "</button>";
      bar.hidden = S.updHidden === "r:" + u.installed_version;
    } else if (u.available && u.error) {
      bar.className = "updbar warn";
      bar.innerHTML = '<span class="ic">' + I.upd + "</span>" +
        '<div class="msg"><b>An update' + (u.remote_version ? " (" + h(u.remote_version) + ")" : "") +
        " is available</b><small>It could not install by itself: " + h(u.error) + "</small></div>" +
        '<button class="btn sm" id="updRetry" type="button">Try again</button>' +
        '<button class="iconbtn" id="updHide" type="button" title="Later">' + I.close + "</button>";
      bar.hidden = S.updHidden === "a:" + u.remote_version;
    } else {
      bar.hidden = true;
      return;
    }
    var hide = $("#updHide");
    if (hide) hide.onclick = function () {
      S.updHidden = u.restart_needed ? "r:" + u.installed_version : "a:" + u.remote_version;
      bar.hidden = true;
    };
    var rs = $("#updRestart");
    if (rs) rs.onclick = restartForUpdate;
    var rt = $("#updRetry");
    if (rt) rt.onclick = function () {
      rt.disabled = true;
      rt.textContent = "Installing\u2026";
      api("/api/update/check", { body: {} }).then(renderUpdate)
        .catch(function (e) { toast("Update failed", e.message, "bad"); rt.disabled = false; });
    };
  }

  function restartForUpdate() {
    S.restarting = true;
    var bar = $("#updBar");
    bar.className = "updbar";
    bar.innerHTML = '<span class="ic">' + I.restart + '</span><div class="msg"><b>Restarting the web UI\u2026</b>' +
      "<small>This page reloads by itself in a few seconds.</small></div>";
    api("/api/update/restart", { body: {} }).catch(function () {});
    var tries = 0;
    function waitForIt() {
      tries++;
      fetch("/api/update", { cache: "no-store" })
        .then(function (r) { return r.json(); })
        .then(function (u) {
          if (!u.restart_needed) location.reload();
          else if (tries < 90) setTimeout(waitForIt, 1500);
        })
        .catch(function () { if (tries < 90) setTimeout(waitForIt, 1500); });
    }
    setTimeout(waitForIt, 3000);
  }

  /* ------------------------------------------------------------ routing */
  function show(view) {
    S.view = view;
    $$(".view").forEach(function (v) { v.classList.toggle("on", v.id === "v-" + view); });
    $$("#rail button[data-view]").forEach(function (b) {
      var on = b.dataset.view === view || (view === "configure" && b.dataset.view === "browse");
      b.classList.toggle("on", on);
    });
    closeMenus();
    if (view === "manager") { S.instKey = ""; refreshInstances(); }
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

    /* browse */
    var qTimer = null;
    $("#q").addEventListener("input", function () {
      var v = this.value;
      clearTimeout(qTimer);
      qTimer = setTimeout(function () {
        S.filters.q = v;
        if (S.view !== "browse") show("browse");
        renderGrid();
      }, 120);
    });
    $("#sort").addEventListener("change", function () { S.filters.sort = this.value; renderGrid(); });
    $("#famSel").addEventListener("change", function () { S.filters.family = this.value; renderGrid(); });
    $("#weightSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-w]");
      if (!b) return;
      S.filters.weight = b.dataset.w;
      renderFilters(); renderGrid();
    });
    $("#kindSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-kind]");
      if (!b) return;
      S.filters.kind = b.dataset.kind;
      renderFilters(); renderGrid();
    });
    $("#grid").addEventListener("click", function (ev) {
      var c = ev.target.closest(".card");
      if (c) openDetail(c.dataset.id);
    });
    $("#grid").addEventListener("keydown", function (ev) {
      if (ev.key !== "Enter" && ev.key !== " ") return;
      var c = ev.target.closest(".card");
      if (c) { ev.preventDefault(); openDetail(c.dataset.id); }
    });

    /* smart chooser */
    $("#tasteSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-taste]");
      if (!b) return;
      S.smart.taste = b.dataset.taste;
      renderSmartControls();
      runSmart();
    });
    $("#purposeSel").addEventListener("change", function () {
      S.smart.purpose = this.value;
      runSmart();
    });
    $("#smartBtn").addEventListener("click", runSmart);
    $("#smartOut").addEventListener("click", function (ev) {
      var u = ev.target.closest("[data-use]");
      if (u) return openDetail(u.dataset.use);
      var g = ev.target.closest("[data-go]");
      if (g) return openDetail(g.dataset.go, true);
    });

    /* detail page */
    $("#dGallery").addEventListener("click", function (ev) {
      var f = ev.target.closest("[data-shot]");
      if (f) openShot(Number(f.dataset.shot));
    });

    /* lightbox */
    $("#lbClose").addEventListener("click", closeShot);
    $("#lbPrev").addEventListener("click", function () { openShot(S.shotIdx - 1); });
    $("#lbNext").addEventListener("click", function () { openShot(S.shotIdx + 1); });
    $("#lightbox").addEventListener("click", function (ev) {
      if (ev.target.id === "lightbox" || ev.target.classList.contains("lb-img")) closeShot();
    });

    /* Close buttons: caught in the capture phase on the document, so no other
       handler (or an error in one) can swallow the click. */
    document.addEventListener("click", function (ev) {
      var b = ev.target.closest && ev.target.closest("#modalClose, #modalX, #drawerClose, #shClose, #lbClose, .toast .x, #updHide");
      if (!b) return;
      if (b.id === "modalClose" || b.id === "modalX") closeModal();
      else if (b.id === "drawerClose") closeDrawer();
      else if (b.id === "lbClose") closeShot();
      else if (b.id === "shClose") { closeShell(); show("manager"); }
      else if (b.classList.contains("x")) { var t = b.closest(".toast"); if (t) t.remove(); }
      else if (b.id === "updHide") { $("#updBar").hidden = true; return; }
      ev.stopPropagation();
      ev.preventDefault();
    }, true);
    /* modal: its own listeners, so nothing can swallow the close click */
    $("#modal").addEventListener("click", function (ev) {
      if (ev.target.id === "modal") closeModal();
    });

    /* everything rendered on the fly */
    document.addEventListener("click", function (ev) {
      var t = ev.target;
      var mbtn = t.closest("[data-menu]");
      if (mbtn) {
        var menu = mbtn.parentNode.querySelector(".menu");
        var wasOpen = !menu.hidden;
        closeMenus();
        if (!wasOpen) {
          menu.hidden = false;
          // The card clips its contents (rounded corners), so fit the menu in
          // the room above the button and let it scroll if it is longer.
          var card = mbtn.closest(".mc");
          if (card) {
            var room = mbtn.getBoundingClientRect().top - card.getBoundingClientRect().top - 14;
            menu.style.maxHeight = Math.max(160, room) + "px";
          }
          closeMenus(menu);
        }
        return;
      }
      if (!t.closest(".menu")) closeMenus();

      var x;
      if ((x = t.closest("[data-drawer]"))) { toggleDrawer(x.dataset.drawer); return; }
      if ((x = t.closest("[data-copy]"))) { copy(x.dataset.copy); return; }
      if ((x = t.closest("[data-back]"))) { show(x.dataset.back); return; }
      if ((x = t.closest("[data-term]"))) { openTerm(x.dataset.term); return; }
      if ((x = t.closest("[data-logs]"))) { closeMenus(); showLogs(x.dataset.logs); return; }
      if ((x = t.closest("[data-tune]"))) { closeMenus(); showTune(x.dataset.tune); return; }
      if ((x = t.closest("[data-reveal]"))) {
        var nm = x.dataset.reveal;
        var inst = S.instances.filter(function (i) { return i.name === nm; })[0];
        var val = document.querySelector('[data-secret="' + cssq(nm) + '"]');
        if (inst && inst.auth && val) {
          var shown = x.classList.toggle("on");
          val.innerHTML = "<span>" + h(inst.auth.user) + '</span><span class="muted"> / ' +
            (shown ? h(inst.auth.password) : "••••••••") + "</span>";
        }
        return;
      }
      if ((x = t.closest("[data-jobcancel]"))) {
        x.disabled = true;
        api("/api/job/" + x.dataset.jobcancel + "/cancel", { body: {} }).then(function (r) {
          toast(r.cancelled ? "Cancelling\u2026" : "Could not cancel it", "", r.cancelled ? "" : "bad");
          setTimeout(refreshJobs, 1500);
        }).catch(function (e) { toast("Cancel failed", e.message, "bad"); });
        return;
      }
      if ((x = t.closest("[data-act]"))) {
        var card = x.closest(".mc");
        closeMenus();
        if (card) instAction(card.dataset.name, x.dataset.act);
        return;
      }
      var id = t.id || (t.closest("button") || {}).id;
      if (id === "goBtn" || id === "goBtn2" || id === "retryBtn") { startLaunch(); return; }
      if (id === "dfBtn") {
        var o = $("#dfOut");
        var open = o.style.display === "none";
        o.style.display = open ? "block" : "none";
        $("#dfBtn").textContent = open ? "Hide Dockerfile" : "Show Dockerfile";
      }
    });

    document.addEventListener("input", function (ev) {
      var t = ev.target;
      if (t.type !== "range" || !S.plan || !t.closest("#cfgTune")) return;
      syncRange(t);
      if (t.id === "sMem") { S.plan.memory_mb = Number(t.value); $("#sMemV").textContent = mb(t.value); }
      if (t.id === "sCpu") { S.plan.cpus = Number(t.value); $("#sCpuV").textContent = Number(t.value).toFixed(1) + " cores"; }
      if (t.id === "sShm") { S.plan.shm_mb = Number(t.value); $("#sShmV").textContent = mb(t.value); }
      if (t.id === "sDisk") { S.plan.disk_mb = Number(t.value); $("#sDiskV").textContent = mb(t.value); }
      updateGoSummary();
    });

    document.addEventListener("change", function (ev) {
      if (ev.target.id === "oAuth") $("#authFields").style.display = ev.target.checked ? "block" : "none";
      if (ev.target.id === "oDisplay" || ev.target.id === "tDisplay") {
        var p = ev.target.id.charAt(0), pref = ev.target.dataset.pref || (S.sel && S.sel.display) || "fit";
        var v = ev.target.value;
        $("#" + p + "ResWrap").style.display = (v === "fixed" || (v === "auto" && pref === "fixed")) ? "block" : "none";
      }
    });

    /* shell view */
    $("#shFit").addEventListener("click", function () {
      if (!S.shell) return;
      var f = S.shell.refit();
      toast("Resized", f.cols + "×" + f.rows);
    });


    var rsz = null;
    window.addEventListener("resize", function () {
      clearTimeout(rsz);
      rsz = setTimeout(function () {
        if (S.shell && S.view === "shell") S.shell.refit();
        if (S.drawerSess) S.drawerSess.refit();
      }, 220);
    });

    window.addEventListener("keydown", function (ev) {
      if (!$("#lightbox").hidden) {
        if (ev.key === "Escape") { closeShot(); ev.preventDefault(); }
        if (ev.key === "ArrowLeft") openShot(S.shotIdx - 1);
        if (ev.key === "ArrowRight") openShot(S.shotIdx + 1);
        return;
      }
      if (ev.key === "Escape") {
        if ($("#modal").style.display === "grid") { closeModal(); return; }
        closeMenus();
      }
      // A page shortcut must never eat a keystroke meant for a shell or a field.
      var tag = ev.target.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      if (ev.target.closest && ev.target.closest(".term")) return;
      if (ev.key === "/") { ev.preventDefault(); $("#q").focus(); }
      if (ev.key === "1") show("browse");
      if (ev.key === "2") show("manager");
      if (ev.key === "3") show("host");
    });
  }

  document.addEventListener("DOMContentLoaded", function () { wire(); boot(); });
})();
__FORGE_FILE_WEB_APP_JS__
  cat > "$FORGE_APP/web/brands.js" <<'__FORGE_FILE_WEB_BRANDS_JS__'
/* Real distro marks from Simple Icons (CC0 1.0, simpleicons.org).
   Trademarks belong to their owners; shown only to identify each distro.
   Generated by fetch_logos.py on 2026-10-02. */
window.FORGE_BRANDS = {
 "ubuntu": "<svg aria-hidden=\"true\" fill=\"#E95420\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M17.61.455a3.41 3.41 0 0 0-3.41 3.41 3.41 3.41 0 0 0 3.41 3.41 3.41 3.41 0 0 0 3.41-3.41 3.41 3.41 0 0 0-3.41-3.41zM12.92.8C8.923.777 5.137 2.941 3.148 6.451a4.5 4.5 0 0 1 .26-.007 4.92 4.92 0 0 1 2.585.737A8.316 8.316 0 0 1 12.688 3.6 4.944 4.944 0 0 1 13.723.834 11.008 11.008 0 0 0 12.92.8zm9.226 4.994a4.915 4.915 0 0 1-1.918 2.246 8.36 8.36 0 0 1-.273 8.303 4.89 4.89 0 0 1 1.632 2.54 11.156 11.156 0 0 0 .559-13.089zM3.41 7.932A3.41 3.41 0 0 0 0 11.342a3.41 3.41 0 0 0 3.41 3.409 3.41 3.41 0 0 0 3.41-3.41 3.41 3.41 0 0 0-3.41-3.41zm2.027 7.866a4.908 4.908 0 0 1-2.915.358 11.1 11.1 0 0 0 7.991 6.698 11.234 11.234 0 0 0 2.422.249 4.879 4.879 0 0 1-.999-2.85 8.484 8.484 0 0 1-.836-.136 8.304 8.304 0 0 1-5.663-4.32zm11.405.928a3.41 3.41 0 0 0-3.41 3.41 3.41 3.41 0 0 0 3.41 3.41 3.41 3.41 0 0 0 3.41-3.41 3.41 3.41 0 0 0-3.41-3.41z\"/></svg>",
 "debian": "<svg aria-hidden=\"true\" fill=\"#A81D33\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M13.88 12.685c-.4 0 .08.2.601.28.14-.1.27-.22.39-.33a3.001 3.001 0 01-.99.05m2.14-.53c.23-.33.4-.69.47-1.06-.06.27-.2.5-.33.73-.75.47-.07-.27 0-.56-.8 1.01-.11.6-.14.89m.781-2.05c.05-.721-.14-.501-.2-.221.07.04.13.5.2.22M12.38.31c.2.04.45.07.42.12.23-.05.28-.1-.43-.12m.43.12l-.15.03.14-.01V.43m6.633 9.944c.02.64-.2.95-.38 1.5l-.35.181c-.28.54.03.35-.17.78-.44.39-1.34 1.22-1.62 1.301-.201 0 .14-.25.19-.34-.591.4-.481.6-1.371.85l-.03-.06c-2.221 1.04-5.303-1.02-5.253-3.842-.03.17-.07.13-.12.2a3.551 3.552 0 012.001-3.501 3.361 3.362 0 013.732.48 3.341 3.342 0 00-2.721-1.3c-1.18.01-2.281.76-2.651 1.57-.6.38-.67 1.47-.93 1.661-.361 2.601.66 3.722 2.38 5.042.27.19.08.21.12.35a4.702 4.702 0 01-1.53-1.16c.23.33.47.66.8.91-.55-.18-1.27-1.3-1.48-1.35.93 1.66 3.78 2.921 5.261 2.3a6.203 6.203 0 01-2.33-.28c-.33-.16-.77-.51-.7-.57a5.802 5.803 0 005.902-.84c.44-.35.93-.94 1.07-.95-.2.32.04.16-.12.44.44-.72-.2-.3.46-1.24l.24.33c-.09-.6.74-1.321.66-2.262.19-.3.2.3 0 .97.29-.74.08-.85.15-1.46.08.2.18.42.23.63-.18-.7.2-1.2.28-1.6-.09-.05-.28.3-.32-.53 0-.37.1-.2.14-.28-.08-.05-.26-.32-.38-.861.08-.13.22.33.34.34-.08-.42-.2-.75-.2-1.08-.34-.68-.12.1-.4-.3-.34-1.091.3-.25.34-.74.54.77.84 1.96.981 2.46-.1-.6-.28-1.2-.49-1.76.16.07-.26-1.241.21-.37A7.823 7.824 0 0017.702 1.6c.18.17.42.39.33.42-.75-.45-.62-.48-.73-.67-.61-.25-.65.02-1.06 0C15.082.73 14.862.8 13.8.4l.05.23c-.77-.25-.9.1-1.73 0-.05-.04.27-.14.53-.18-.741.1-.701-.14-1.431.03.17-.13.36-.21.55-.32-.6.04-1.44.35-1.18.07C9.6.68 7.847 1.3 6.867 2.22L6.838 2c-.45.54-1.96 1.611-2.08 2.311l-.131.03c-.23.4-.38.85-.57 1.261-.3.52-.45.2-.4.28-.6 1.22-.9 2.251-1.16 3.102.18.27 0 1.65.07 2.76-.3 5.463 3.84 10.776 8.363 12.006.67.23 1.65.23 2.49.25-.99-.28-1.12-.15-2.08-.49-.7-.32-.85-.7-1.34-1.13l.2.35c-.971-.34-.57-.42-1.361-.67l.21-.27c-.31-.03-.83-.53-.97-.81l-.34.01c-.41-.501-.63-.871-.61-1.161l-.111.2c-.13-.21-1.52-1.901-.8-1.511-.13-.12-.31-.2-.5-.55l.14-.17c-.35-.44-.64-1.02-.62-1.2.2.24.32.3.45.33-.88-2.172-.93-.12-1.601-2.202l.15-.02c-.1-.16-.18-.34-.26-.51l.06-.6c-.63-.74-.18-3.102-.09-4.402.07-.54.53-1.1.88-1.981l-.21-.04c.4-.71 2.341-2.872 3.241-2.761.43-.55-.09 0-.18-.14.96-.991 1.26-.7 1.901-.88.7-.401-.6.16-.27-.151 1.2-.3.85-.7 2.421-.85.16.1-.39.14-.52.26 1-.49 3.151-.37 4.562.27 1.63.77 3.461 3.011 3.531 5.132l.08.02c-.04.85.13 1.821-.17 2.711l.2-.42M9.54 13.236l-.05.28c.26.35.47.73.8 1.01-.24-.47-.42-.66-.75-1.3m.62-.02c-.14-.15-.22-.34-.31-.52.08.32.26.6.43.88l-.12-.36m10.945-2.382l-.07.15c-.1.76-.34 1.511-.69 2.212.4-.73.65-1.541.75-2.362M12.45.12c.27-.1.66-.05.95-.12-.37.03-.74.05-1.1.1l.15.02M3.006 5.142c.07.57-.43.8.11.42.3-.66-.11-.18-.1-.42m-.64 2.661c.12-.39.15-.62.2-.84-.35.44-.17.53-.2.83\"/></svg>",
 "fedora": "<svg aria-hidden=\"true\" fill=\"#51A2DA\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12.001 0C5.376 0 .008 5.369.004 11.992H.002v9.287h.002A2.726 2.726 0 0 0 2.73 24h9.275c6.626-.004 11.993-5.372 11.993-11.997C23.998 5.375 18.628 0 12 0zm2.431 4.94c2.015 0 3.917 1.543 3.917 3.671 0 .197.001.395-.03.619a1.002 1.002 0 0 1-1.137.893 1.002 1.002 0 0 1-.842-1.175 2.61 2.61 0 0 0 .013-.337c0-1.207-.987-1.672-1.92-1.672-.934 0-1.775.784-1.777 1.672.016 1.027 0 2.046 0 3.07l1.732-.012c1.352-.028 1.368 2.009.016 1.998l-1.748.013c-.004.826.006.677.002 1.093 0 0 .015 1.01-.016 1.776-.209 2.25-2.124 4.046-4.424 4.046-2.438 0-4.448-1.993-4.448-4.437.073-2.515 2.078-4.492 4.603-4.469l1.409-.01v1.996l-1.409.013h-.007c-1.388.04-2.577.984-2.6 2.47a2.438 2.438 0 0 0 2.452 2.439c1.356 0 2.441-.987 2.441-2.437l-.001-7.557c0-.14.005-.252.02-.407.23-1.848 1.883-3.256 3.754-3.256z\"/></svg>",
 "arch": "<svg aria-hidden=\"true\" fill=\"#1793D1\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M11.39.605C10.376 3.092 9.764 4.72 8.635 7.132c.693.734 1.543 1.589 2.923 2.554-1.484-.61-2.496-1.224-3.252-1.86C6.86 10.842 4.596 15.138 0 23.395c3.612-2.085 6.412-3.37 9.021-3.862a6.61 6.61 0 01-.171-1.547l.003-.115c.058-2.315 1.261-4.095 2.687-3.973 1.426.12 2.534 2.096 2.478 4.409a6.52 6.52 0 01-.146 1.243c2.58.505 5.352 1.787 8.914 3.844-.702-1.293-1.33-2.459-1.929-3.57-.943-.73-1.926-1.682-3.933-2.713 1.38.359 2.367.772 3.137 1.234-6.09-11.334-6.582-12.84-8.67-17.74zM22.898 21.36v-.623h-.234v-.084h.562v.084h-.234v.623h.331v-.707h.142l.167.5.034.107a2.26 2.26 0 01.038-.114l.17-.493H24v.707h-.091v-.593l-.206.593h-.084l-.205-.602v.602h-.091\"/></svg>",
 "alpine": "<svg aria-hidden=\"true\" fill=\"#4a9ccc\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M5.998 1.607L0 12l5.998 10.393h12.004L24 12 18.002 1.607H5.998zM9.965 7.12L12.66 9.9l1.598 1.595.002-.002 2.41 2.363c-.2.14-.386.252-.563.344a3.756 3.756 0 01-.496.217 2.702 2.702 0 01-.425.111c-.131.023-.25.034-.358.034-.13 0-.242-.014-.338-.034a1.317 1.317 0 01-.24-.072.95.95 0 01-.2-.113l-1.062-1.092-3.039-3.041-1.1 1.053-3.07 3.072a.974.974 0 01-.2.111 1.274 1.274 0 01-.237.073c-.096.02-.209.033-.338.033-.108 0-.227-.009-.358-.031a2.7 2.7 0 01-.425-.114 3.748 3.748 0 01-.496-.217 5.228 5.228 0 01-.563-.343l6.803-6.727zm4.72.785l4.579 4.598 1.382 1.353a5.24 5.24 0 01-.564.344 3.73 3.73 0 01-.494.217 2.697 2.697 0 01-.426.111c-.13.023-.251.034-.36.034-.129 0-.241-.014-.337-.034a1.285 1.285 0 01-.385-.146c-.033-.02-.05-.036-.053-.04l-1.232-1.218-2.111-2.111-.334.334L12.79 9.8l1.896-1.897zm-5.966 4.12v2.529a2.128 2.128 0 01-.356-.035 2.765 2.765 0 01-.422-.116 3.708 3.708 0 01-.488-.214 5.217 5.217 0 01-.555-.34l1.82-1.825Z\"/></svg>",
 "kali": "<svg aria-hidden=\"true\" fill=\"#557C94\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12.778 5.943s-1.97-.13-5.327.92c-3.42 1.07-5.36 2.587-5.36 2.587s5.098-2.847 10.852-3.008zm7.351 3.095l.257-.017s-1.468-1.78-4.278-2.648c1.58.642 2.954 1.493 4.021 2.665zm.42.74c.039-.068.166.217.263.337.004.024.01.039-.045.027-.005-.025-.013-.032-.013-.032s-.135-.08-.177-.137c-.041-.057-.049-.157-.028-.195zm3.448 8.479s.312-3.578-5.31-4.403a18.277 18.277 0 0 0-2.524-.187c-4.506.06-4.67-5.197-1.275-5.462 1.407-.116 3.087.643 4.73 1.408-.007.204.002.385.136.552.134.168.648.35.813.445.164.094.691.43 1.014.85.07-.131.654-.512.654-.512s-.14.003-.465-.119c-.326-.122-.713-.49-.722-.511-.01-.022-.015-.055.06-.07.059-.049-.072-.207-.13-.265-.058-.058-.445-.716-.454-.73-.009-.016-.012-.031-.04-.05-.085-.027-.46.04-.46.04s-.575-.283-.774-.893c.003.107-.099.224 0 .469-.3-.127-.558-.344-.762-.88-.12.305 0 .499 0 .499s-.707-.198-.82-.85c-.124.293 0 .469 0 .469s-1.153-.602-3.069-.61c-1.283-.118-1.55-2.374-1.43-2.754 0 0-1.85-.975-5.493-1.406-3.642-.43-6.628-.065-6.628-.065s6.45-.31 11.617 1.783c.176.785.704 2.094.989 2.723-.815.563-1.733 1.092-1.876 2.97-.143 1.878 1.472 3.53 3.474 3.58 1.9.102 3.214.116 4.806.942 1.52.84 2.766 3.4 2.89 5.703.132-1.709-.509-5.383-3.5-6.498 4.181.732 4.549 3.832 4.549 3.832zM12.68 5.663l-.15-.485s-2.484-.441-5.822-.204C3.37 5.211 0 6.38 0 6.38s6.896-1.735 12.68-.717Z\"/></svg>",
 "parrot": "<svg aria-hidden=\"true\" fill=\"#15E0ED\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0Zm6.267 2.784L13.03 5.54l8.05-.179-8.05 3.333-2.154 2.688 5.007 9.038-1.536-1.605 1.645 3.456-4.937-5.527-6.268-6.28L2.77 12.11l.7-3.442 4.018-.261.823-4.06Z\"/></svg>",
 "almalinux": "<svg aria-hidden=\"true\" fill=\"#dfe5ee\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M23.994 15.133c.079 1.061-.668 1.927-1.69 2.005a1.8 1.8 0 0 1-1.928-1.651c-.078-1.062.63-1.849 1.691-1.967 1.023-.078 1.849.59 1.927 1.613zm-12.623 4.955c-.944 0-1.73.786-1.73 1.809 0 1.14.747 1.848 1.887 1.848.904-.04 1.691-.865 1.691-1.809 0-.983-.904-1.848-1.848-1.848zm1.061-9.675c-.039-.865-.078-1.73.08-2.556.156-.944.314-1.887.904-2.674.707-.983 1.809-.944 2.399.118.314.511.432 1.062.471 1.652 0 .354.158.432.472.393.944-.157 1.888-.157 2.792.197.118.039.236.118.394 0 .314-.276.393-1.652.196-2.006-.354-.63-.904-.55-1.455-.55-.629.039-1.18-.158-1.612-.67-.393-.471-.511-1.06-.59-1.65-.04-.276-.079-.512-.315-.709-.55-.55-1.809-.432-2.477.118-2.556 2.045-2.989 5.467-1.534 8.18.04.118.118.236.275.157zm7.984 3.658c.354-.511.865-.747 1.415-.983a.973.973 0 0 0 .59-.472c.354-.669-.078-1.81-.747-2.36-2.595-2.006-5.938-1.612-8.18.433-.118.078-.157.196-.078.314.786-.236 1.612-.472 2.477-.51.905-.08 1.848-.158 2.753.235 1.14.472 1.337 1.534.472 2.36-.393.393-.905.668-1.455.825-.315.08-.354.236-.236.551.354.865.59 1.77.472 2.753-.04.157-.079.275.078.393.354.236 1.691 0 1.967-.275.511-.472.314-1.023.196-1.534-.157-.63-.078-1.219.276-1.73zm-7.197-2.045c-.118-.079-.197-.118-.315 0 .472.708.905 1.455 1.259 2.241.314.866.668 1.73.55 2.714-.118 1.18-1.1 1.69-2.123 1.101-.511-.275-.905-.669-1.22-1.14-.196-.276-.393-.276-.629-.08-.747.63-1.533 1.102-2.516 1.26-.158 0-.315 0-.394.157-.118.393.472 1.612.826 1.809.59.354 1.062 0 1.534-.276.55-.314 1.101-.432 1.73-.236.59.197.983.63 1.337 1.102.158.196.315.353.63.432.747.197 1.77-.59 2.084-1.376 1.18-3.028-.157-6.135-2.753-7.708zm-2.556 2.438c.472-.669.826-1.416.983-2.202-.157-.04-.197.04-.315.078-.904.944-1.848 1.849-3.067 2.478-.472.236-.983.433-1.534.433-.865 0-1.376-.551-1.298-1.416a2.92 2.92 0 0 1 .787-1.849c.236-.275.236-.432-.04-.668-.786-.55-1.494-1.22-1.848-2.124-.078-.275-.275-.275-.51-.157a4.293 4.293 0 0 0-.434.236c-1.022.63-1.14 1.416-.275 2.28.63.63.944 1.338.708 2.203-.118.433-.354.747-.63 1.101a.95.95 0 0 0-.235.787c.079.747.826 1.494 1.73 1.573 2.517.236 4.562-.63 5.978-2.753zm-4.68-5.152c1.376 1.18 3.067 1.455 4.837 1.377.157 0 .315 0 .354-.118.04-.197-.157-.197-.275-.236-.826-.354-1.691-.63-2.438-1.14S6.848 8.25 6.534 7.266c-.236-.747.078-1.415.825-1.651.669-.236 1.337-.236 1.967 0 .393.157.55.078.629-.354.118-.747.354-1.455.826-2.085.55-.786.55-.865-.354-1.376-.04 0-.04-.04-.079-.04-.865-.471-1.534-.196-1.848.709-.472 1.376-1.377 1.887-2.832 1.612-.196-.04-.393-.079-.472-.079-.747.118-1.18.55-1.297 1.14-.158 1.81.786 3.107 2.084 4.17zm-2.32 3.658c-.079-.944-1.023-1.652-2.045-1.534-.905.079-1.691 1.022-1.613 1.966.08.983 1.023 1.77 1.967 1.652 1.14-.079 1.73-1.18 1.69-2.084zm15.18-8.298c.943-.079 1.73-.983 1.651-1.927-.078-.983-1.022-1.77-2.005-1.691-1.023.079-1.73.983-1.652 1.966s.983 1.73 2.006 1.652zm-12.27-.826c1.062-.157 1.77-1.023 1.652-2.045C8.107.897 7.163.149 6.18.267c-1.062.118-1.691.944-1.573 2.085.118.865 1.061 1.612 1.966 1.494z\"/></svg>",
 "rocky": "<svg aria-hidden=\"true\" fill=\"#10B981\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M23.332 15.957c.433-1.239.668-2.57.668-3.957 0-6.627-5.373-12-12-12S0 5.373 0 12c0 3.28 1.315 6.251 3.447 8.417L15.62 8.245l3.005 3.005zm-2.192 3.819l-5.52-5.52L6.975 22.9c1.528.706 3.23 1.1 5.025 1.1 3.661 0 6.94-1.64 9.14-4.224z\"/></svg>",
 "centos": "<svg aria-hidden=\"true\" fill=\"#8f8fd6\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12.076.066L8.883 3.28H3.348v5.434L0 12.01l3.349 3.298v5.39h5.374l3.285 3.236 3.285-3.236h5.43v-5.374L24 12.026l-3.232-3.252V3.321H15.31zm0 .749l2.49 2.506h-1.69v6.441l-.8.805-.81-.815V3.28H9.627zm-8.2 2.991h4.483L6.485 5.692l4.253 4.279v.654H9.94L5.674 6.423l-1.798 1.77zm5.227 0h1.635v5.415l-3.509-3.53zm4.302.043h1.687l1.83 1.842-3.517 3.539zm2.431 0h4.404v4.394l-1.83-1.842-4.241 4.267h-.764v-.69l4.261-4.287zm2.574 3.3l1.83 1.843v1.676h-5.327zm-12.735.013l3.515 3.462H3.876v-1.69zM3.348 9.454v1.697h6.377l.871.858-.782.77H3.35v1.786L.753 12.01zm17.42.068l2.488 2.503-2.533 2.55v-1.796h-6.41l-.75-.754.825-.83h6.38zm-9.502.978l.81.815.186-.188.614-.618v.686h.768l-.825.83.75.754h-.719v.808l-.842-.83-.741.73v-.707h-.7l.781-.77-.188-.186-.682-.672h.788zm-7.39 2.807h5.402l-3.603 3.55-1.798-1.772zm6.154 0h.708v.7l-4.404 4.338 1.852 1.824h-4.31v-4.342l1.798 1.77zm3.348 0h.715l4.317 4.343.186-.187 1.599-1.61v4.316h-4.366l1.853-1.825-.188-.185-4.116-4.054zm1.46 0h5.357v1.798l-1.785 1.796zm-2.83.191l.842.829v6.37h1.691l-2.532 2.495-2.533-2.495h1.79V14.23zm-1.27 1.251v5.42H8.939l-1.852-1.823zm2.64.097l3.552 3.499-1.853 1.825h-1.7z\"/></svg>",
 "opensuse": "<svg aria-hidden=\"true\" fill=\"#73BA25\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M10.724 0a12 12 0 0 0-9.448 4.623c1.464.391 2.5.727 2.81.832.005-.19.037-1.893.037-1.893s.004-.04.025-.06c.026-.026.065-.018.065-.018.385.056 8.602 1.274 12.066 3.292.427.25.638.517.902.786.958.99 2.223 5.108 2.359 5.957.005.033-.036.07-.054.083a5.177 5.177 0 0 1-.313.228c-.82.55-2.708 1.872-5.13 1.656-2.176-.193-5.018-1.44-8.445-3.699.336.79.668 1.58 1 2.371.497.258 5.287 2.7 7.651 2.651 1.904-.04 3.941-.968 4.756-1.458 0 0 .179-.108.257-.048.085.066.061.167.041.27-.05.234-.164.66-.242.863l-.065.165c-.093.25-.183.482-.356.625-.48.436-1.246.784-2.446 1.305-1.855.812-4.865 1.328-7.66 1.31-1.001-.022-1.968-.133-2.817-.232-1.743-.197-3.161-.357-4.026.269A12 12 0 0 0 10.724 24a12 12 0 0 0 12-12 12 12 0 0 0-12-12zM13.4 6.963a3.503 3.503 0 0 0-2.521.942 3.498 3.498 0 0 0-1.114 2.449 3.528 3.528 0 0 0 3.39 3.64 3.48 3.48 0 0 0 2.524-.946 3.504 3.504 0 0 0 1.114-2.446 3.527 3.527 0 0 0-3.393-3.64zm-.03 1.035a2.458 2.458 0 0 1 2.368 2.539 2.43 2.43 0 0 1-.774 1.706 2.456 2.456 0 0 1-1.762.659 2.461 2.461 0 0 1-2.364-2.542c.02-.655.3-1.26.777-1.707a2.419 2.419 0 0 1 1.756-.655zm.402 1.23c-.602 0-1.087.325-1.087.727 0 .4.485.725 1.087.725.6 0 1.088-.326 1.088-.725 0-.402-.487-.726-1.088-.726Z\"/></svg>",
 "mint": "<svg aria-hidden=\"true\" fill=\"#86BE43\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M5.438 5.906v8.438c0 2.06 1.69 3.75 3.75 3.75h5.625c2.06 0 3.75-1.69 3.75-3.75V9.656a2.827 2.827 0 0 0-2.813-2.812 2.8 2.8 0 0 0-1.875.737A2.8 2.8 0 0 0 12 6.844a2.827 2.827 0 0 0-2.812 2.812v4.688h1.875V9.656c0-.529.408-.937.937-.937s.938.408.938.937v4.688h1.875V9.656c0-.529.408-.937.937-.937s.938.408.938.937v4.688a1.86 1.86 0 0 1-1.875 1.875H9.188a1.86 1.86 0 0 1-1.875-1.875V5.906ZM12 0C5.384 0 0 5.384 0 12s5.384 12 12 12 12-5.384 12-12S18.616 0 12 0m0 1.875A10.11 10.11 0 0 1 22.125 12 10.11 10.11 0 0 1 12 22.125 10.11 10.11 0 0 1 1.875 12 10.11 10.11 0 0 1 12 1.875\"/></svg>",
 "zorin": "<svg aria-hidden=\"true\" fill=\"#15A6F0\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M4 18.944L5.995 22.4h12.01L20 18.944H4zM24 12l-2.013 3.488H9.216l12.771-6.976L24 12zM0 12l2.013-3.488h12.771L2.013 15.488 0 12zm4-6.944L5.995 1.6h12.01L20 5.056H4z\"/></svg>",
 "pop": "<svg aria-hidden=\"true\" fill=\"#48B9C7\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12 0C5.372 0 0 5.373 0 12c0 6.628 5.372 12 12 12 6.627 0 12-5.372 12-12 0-6.627-5.373-12-12-12ZM9.64 2.918c1.091-.026 1.548.229 2.182.635a4.459 4.459 0 0 1 1.902 2.764c.254 1.141.178 2.029-.127 2.664v.05c-.609 1.294-1.622 2.335-3.043 2.842l1.217 3.172c.228.583.432 1.192.254 1.75-.177.558-.989.736-1.572.127-1.116-1.192-4.871-8.702-5.15-9.26-.279-.558-.584-1.016-.584-1.574.026-.837 1.318-1.7 1.953-2.131.634-.431 1.877-1.014 2.968-1.039Zm-.996 2.311c-.789.022-.358 1.669-.197 2.129.178.507.661 1.572 1.193 2.105.127.127.254.229.407.254.152.027.457-.127.584-.33a.932.932 0 0 0 .15-.559 3.232 3.232 0 0 0-.049-1.216c-.228-.787-.711-1.548-1.346-2.055-.127-.102-.279-.229-.457-.279a.901.901 0 0 0-.285-.049Zm8.414 2.027a2.283 2.283 0 0 1 1.588.636c.305.279.33.582.229.963-.102.38-.457 1.194-.736 1.777l-.709 1.344c-1.37 2.435-1.649 2.689-2.03 2.537-.456-.178-.304-2.614.127-5.582.127-.812.329-1.217.557-1.42.171-.152.6-.248.975-.254l-.001-.001Zm-1.859 8.332c.554.011.789.7.656 1.232a.861.861 0 0 1-.379.559c-.203.127-.685.127-.965-.102-.278-.228-.33-.609-.254-.914.076-.304.331-.635.686-.736a.757.757 0 0 1 .256-.039Zm-8.604 2.805h10.809c.52 0 .938.419.938.939v.074c0 .52-.418.94-.938.94H6.595a.936.936 0 0 1-.937-.94v-.074c0-.52.417-.939.937-.939Z\"/></svg>",
 "elementary": "<svg aria-hidden=\"true\" fill=\"#64BAFF\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M12 0a12 12 0 1 0 0 24 12 12 0 0 0 0-24zm0 1a11 11 0 0 1 10.59 8.01 19.09 19.09 0 0 1-4.66 6.08c-.94.81-1.96 1.53-3.08 2.04-1.13.5-2.37.8-3.6.72a6.23 6.23 0 0 1-2.66-.76 20.02 20.02 0 0 0 5.68-4.58 9.97 9.97 0 0 0 2.31-4.17c.18-.79.2-1.6.04-2.4a4.42 4.42 0 0 0-1.08-2.11 4.33 4.33 0 0 0-2-1.19 5.25 5.25 0 0 0-2.33-.08A7.8 7.8 0 0 0 7.2 4.85a9.77 9.77 0 0 0-2.94 7.49 7.88 7.88 0 0 0 1.95 4.59 18 18 0 0 1-3.56.85A11 11 0 0 1 12 1zm.07 2.22c.77 0 1.55.24 2.17.7.55.42.97 1.02 1.2 1.68.23.65.3 1.37.21 2.06a7.85 7.85 0 0 1-1.7 3.76 16.22 16.22 0 0 1-6.37 4.96c-.48-.42-.9-.92-1.2-1.48a6.61 6.61 0 0 1-.75-3.87c.12-1.32.58-2.6 1.2-3.79a7.92 7.92 0 0 1 3.02-3.42c.68-.37 1.45-.6 2.22-.6zm10.83 7.3A11 11 0 0 1 3.52 19a19.8 19.8 0 0 0 3.63-1.2c.51.4 1.08.71 1.67.94a8 8 0 0 0 5.44-.04 13.3 13.3 0 0 0 4.64-2.95 20 20 0 0 0 4-5.22z\"/></svg>",
 "garuda": "<svg aria-hidden=\"true\" fill=\"#8839EF\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M10.24 3.179C6.82 6.579 3.366 10.064 0 13.465c2.4 2.406 4.889 4.898 7.319 7.332l7.504.024 6.334-6.316-13.754-.012-1.525 1.54 11.512.024-3.198 3.197H7.956L2.172 13.47l8.74-8.74h6.284l4.815 4.815-7.501-.01v-2.12l-3.68 3.68c3.873.004 7.746.003 11.62 0v2.102l1.55-1.55-.003-2.306-6.16-6.159z\"/></svg>"
};
__FORGE_FILE_WEB_BRANDS_JS__
  cat > "$FORGE_APP/web/index.html" <<'__FORGE_FILE_WEB_INDEX_HTML__'
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
    <div class="updbar" id="updBar" hidden></div>
    <div class="updbar life" id="lifeBar" hidden></div>

    <!-- ------------------------------------------------------- browse -->
    <section class="view on" id="v-browse">
      <h1 class="h1">Pick a desktop</h1>
      <p class="sub">Real Linux desktops, streamed to your browser. <b id="count">-</b>.
        Prebuilt ones pull in minutes; the rest are built on this machine.</p>

      <div class="panel">
        <h3>Not sure? Let it choose <span class="hint">scored against this machine's free memory, cores and disk</span></h3>
        <div class="smart-row">
          <div class="grp">
            <span class="sec-k">What matters most</span>
            <div class="seg" id="tasteSeg"></div>
          </div>
          <div class="grp">
            <span class="sec-k">What it is for</span>
            <select id="purposeSel" style="width:auto;min-width:170px">
              <option value="general">Anything</option>
              <option value="dev">Writing code</option>
              <option value="security">Security work</option>
              <option value="retro">Retro and tiny</option>
              <option value="media">Media</option>
            </select>
          </div>
          <div class="spacer"></div>
          <button class="btn primary" id="smartBtn">Choose for me</button>
        </div>
        <div id="smartOut"></div>
      </div>

      <div class="toolbar">
        <select id="famSel" aria-label="Distro family"></select>
        <div class="seg" id="weightSeg">
          <button data-w="" class="on">Any weight</button>
          <button data-w="feather">Feather</button>
          <button data-w="light">Light</button>
          <button data-w="balanced">Balanced</button>
          <button data-w="full">Full</button>
          <button data-w="heavy">Heavy</button>
        </div>
        <div class="seg" id="kindSeg">
          <button data-kind="" class="on">All</button>
          <button data-kind="pull">Ready to run</button>
          <button data-kind="build">Built here</button>
        </div>
        <div class="spacer"></div>
        <select id="sort" aria-label="Sort">
          <option value="beauty">Best looking</option>
          <option value="light">Lightest</option>
          <option value="fast">Snappiest</option>
          <option value="small">Smallest download</option>
          <option value="name">Name</option>
        </select>
      </div>

      <div class="grid" id="grid"></div>
    </section>

    <!-- ---------------------------------------------------- configure -->
    <section class="view" id="v-configure">
      <button class="btn sm ghost" data-back="browse" style="margin-bottom:14px">&larr; All desktops</button>
      <div class="panel" id="dHero"></div>
      <div class="panel" id="dGallery" hidden></div>
      <div class="dgrid">
        <div>
          <div class="panel" id="cfgTune"></div>
          <div class="panel" id="cfgAuth"></div>
          <div class="panel" id="cfgOpts"></div>
        </div>
        <div>
          <div class="panel" id="dAbout"></div>
          <div class="panel" id="cfgSpecs"></div>
          <div class="panel" id="dDocker" hidden></div>
        </div>
      </div>
      <div class="gobar" id="goBar"></div>
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
          <button class="btn sm ghost" id="lCancel" type="button" hidden>Cancel</button>
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
      <p class="sub">Live CPU, memory and bandwidth. Open a shell without leaving the card.</p>
      <div class="stat-strip" id="instStats"></div>
      <div class="jobstrip" id="jobStrip" hidden></div>
      <div class="inst-grid" id="instList"></div>
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
        <div class="panel"><h3>Web UI</h3><div id="hostLife"></div></div>
        <div class="panel"><h3>Disk used by the forge</h3><div id="hostSpace"><div class="skel" style="height:80px"></div></div></div>
      </div>
    </section>

  </main>
</div>

<div id="modal" style="display:none">
  <div class="panel" id="modalPanel">
    <div class="row modal-head">
      <h3 id="modalTitle" style="margin:0">-</h3>
      <div class="spacer"></div>
      <button class="btn sm ghost" id="modalClose" type="button">Close</button>
    </div>
    <div id="modalBody"></div>
  </div>
</div>

<div class="lightbox" id="lightbox" hidden>
  <div class="lb-top">
    <span id="lbCount"></span>
    <div class="spacer"></div>
    <button class="btn sm" id="lbPrev" type="button">&larr; Prev</button>
    <button class="btn sm" id="lbNext" type="button">Next &rarr;</button>
    <button class="btn sm" id="lbClose" type="button">Close</button>
  </div>
  <div class="lb-img"><img id="lbImg" alt=""></div>
  <div class="lb-cap" id="lbCap"></div>
</div>

<div class="toasts" id="toasts"></div>

<script src="/brands.js"></script>
<script src="/logos.js"></script>
<script src="/term.js"></script>
<script src="/app.js"></script>
</body>
</html>
__FORGE_FILE_WEB_INDEX_HTML__
  cat > "$FORGE_APP/web/logos.js" <<'__FORGE_FILE_WEB_LOGOS_JS__'
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
  /* Real marks (brands.js, from Simple Icons) win; the hand-drawn ones above
     cover families Simple Icons does not carry, and anything offline. */
  window.forgeLogo = function (family) {
    var B = window.FORGE_BRANDS || {};
    return B[family] || L[family] || L.generic;
  };
  window.forgeGlyph = function (glyph) { return G[glyph] || G.generic; };
})();
__FORGE_FILE_WEB_LOGOS_JS__
  cat > "$FORGE_APP/web/term.js" <<'__FORGE_FILE_WEB_TERM_JS__'
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
__FORGE_FILE_WEB_TERM_JS__
  cat > "$FORGE_APP/data/info.json" <<'__FORGE_FILE_DATA_INFO_JSON__'
{
 "source": "Wikipedia / Wikimedia Commons",
 "fetched": "2026-10-02",
 "families": {
  "ubuntu": {
   "title": "Ubuntu",
   "url": "https://en.wikipedia.org/wiki/Ubuntu",
   "extract": "Ubuntu (uu-BUUN-too) is a Linux distribution based on Debian and composed primarily of free and open-source software. Developed by the British company Canonical and a community of contributors under a meritocratic governance model, Ubuntu is released in multiple official editions: Desktop, Server, and Core for IoT and robotic devices. Ubuntu is published on a six-month release cycle, with long-term support (LTS) versions issued every two years. Canonical provides security updates and support until each release reaches its designated end-of-life (EOL), with optional extended support available through the Ubuntu Pro and Expanded Security Maintenance (ESM) services.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/76/Ubuntu-logo-2022.svg/960px-Ubuntu-logo-2022.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/7/76/Ubuntu-logo-2022.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/12/Ubuntu_26.04_LTS_desktop.png/960px-Ubuntu_26.04_LTS_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/1/12/Ubuntu_26.04_LTS_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Ubuntu_26.04_LTS_desktop.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of the default desktop environment of Ubuntu 26.04 LTS \"Resolute Raccoon\"",
     "license": "GPL"
    }
   ]
  },
  "debian": {
   "title": "Debian",
   "url": "https://en.wikipedia.org/wiki/Debian",
   "extract": "Debian is a free, general-purpose operating system developed by the Debian Project, a worldwide volunteer association founded by Ian Murdock on August 16, 1993. It is the second-oldest Linux distribution still being developed (only Slackware is older) and forms the base of many others. It is deployed across servers, personal computers, and embedded devices. Among Linux distributions, it ranks second only to Ubuntu (a Debian derivative), with 16% of the overall market. According to the 2025 Stack Overflow Developer Survey, 11.4% of developers use it as their primary personal operating system and 10.4% professionally. Its emphasis on stability and long-term support over frequent package updates has made it prevalent in server and embedded deployments.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/50/Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png/960px-Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/5/50/Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/50/Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png/960px-Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/50/Debian_13_%28Trixie%29_screenshot_-_using_GNOME_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_13_(Trixie)_screenshot_-_using_GNOME_desktop.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of Debian Trixie with the GNOME desktop",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/de/Debian_13.0.0_KDE_default_desktop_-_English.png/960px-Debian_13.0.0_KDE_default_desktop_-_English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/d/de/Debian_13.0.0_KDE_default_desktop_-_English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_13.0.0_KDE_default_desktop_-_English.png",
     "w": 1454,
     "h": 991,
     "caption": "Debian 13.0.0 KDE default desktop",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fa/Debian10_Gnome.png/960px-Debian10_Gnome.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/f/fa/Debian10_Gnome.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian10_Gnome.png",
     "w": 1920,
     "h": 1200,
     "caption": "Screenshot of Debian 10 (buster) with GNOME desktop environment running a couple of free software applications",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "fedora": {
   "title": "Fedora Linux",
   "url": "https://en.wikipedia.org/wiki/Fedora_Linux",
   "extract": "Fedora Linux is a Linux distribution developed by the Fedora Project. It was originally developed in 2003 as a continuation of the Red Hat Linux project. It contains software distributed under various free and open-source licenses and aims to be on the leading edge of open-source technologies. It is now the upstream source for CentOS Stream and Red Hat Enterprise Linux. Since the release of Fedora 21 in December 2014, three editions have been made available: personal computer, server and cloud computing. This was expanded to five editions for containerization and Internet of Things (IoT) as of the release of Fedora 37 in November 2022. A new version of Fedora Linux is usually released roughly every six months.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/32/Fedora_44_Workstation.png/960px-Fedora_44_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/3/32/Fedora_44_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6d/Fedora_SilverBlue_41_desktop.png/960px-Fedora_SilverBlue_41_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/6d/Fedora_SilverBlue_41_desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Fedora_SilverBlue_41_desktop.png",
     "w": 1920,
     "h": 1080,
     "caption": "Fedora Silverblue 41, desktop screenshot",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/86/Fedora_42_KDE_Plasma_Desktop_English.png/960px-Fedora_42_KDE_Plasma_Desktop_English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/8/86/Fedora_42_KDE_Plasma_Desktop_English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Fedora_42_KDE_Plasma_Desktop_English.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of Fedora Linux KDE Plasma Desktop Edition release version 42 featuring the KDE Plasma 6.3 Desktop…",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/32/Fedora_44_Workstation.png/960px-Fedora_44_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/32/Fedora_44_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Fedora_44_Workstation.png",
     "w": 1920,
     "h": 1080,
     "caption": "Fedora 44 Workstation",
     "license": "GPL"
    }
   ]
  },
  "arch": {
   "title": "Arch Linux",
   "url": "https://en.wikipedia.org/wiki/Arch_Linux",
   "extract": "Arch Linux is an open source, rolling release Linux distribution. Arch Linux is kept up-to-date by regularly updating the individual pieces of software that it comprises. It provides monthly \"snapshots\" which are used as installation media. Arch Linux is intentionally minimal, and is meant to be configured by the user during installation to add only what is needed. Pacman, a package manager written specifically for Arch Linux, is used to install, remove and update software packages. The Arch User Repository (AUR) serves as a community-driven software repository for Arch Linux and provides packages not included in the official repositories and alternative versions of packages. AUR packages can be downloaded and built manually, or installed through an AUR 'helper'. such as Yet Another Yogurt (yay).",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cd/Arch_Linux_screenshot%2C_12.06.2024.png/960px-Arch_Linux_screenshot%2C_12.06.2024.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/c/cd/Arch_Linux_screenshot%2C_12.06.2024.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cd/Arch_Linux_screenshot%2C_12.06.2024.png/960px-Arch_Linux_screenshot%2C_12.06.2024.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/cd/Arch_Linux_screenshot%2C_12.06.2024.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Arch_Linux_screenshot,_12.06.2024.png",
     "w": 1920,
     "h": 1080,
     "caption": "Arch Linux screenshot showcasing KDE Plasma 6.",
     "license": "GPL"
    }
   ]
  },
  "alpine": {
   "title": "Alpine Linux",
   "url": "https://en.wikipedia.org/wiki/Alpine_Linux",
   "extract": "Alpine Linux is a Linux distribution \"designed for power users who appreciate security, simplicity and resource efficiency\". It uses musl, BusyBox, and OpenRC instead of glibc, GNU Core Utilities, and systemd, respectively. This makes Alpine one of the few Linux distributions not to be based on systemd. For security, Alpine compiles all user-space binaries as position-independent executables with stack-smashing protection. Because of its small size and rapid startup, it is commonly used in containers providing quick boot-up times, on virtual machines (e.g., OS-level virtualization) as well as on real hardware in embedded devices, such as routers, servers and NAS.",
   "lead": null,
   "lead_full": null,
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a8/Alpine-xfce.jpg/960px-Alpine-xfce.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/a/a8/Alpine-xfce.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Alpine-xfce.jpg",
     "w": 1280,
     "h": 720,
     "caption": "Alpine Linux with XFCE",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/62/Alpine_Linux_3.19_in_Xfce_4.19.png/960px-Alpine_Linux_3.19_in_Xfce_4.19.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/62/Alpine_Linux_3.19_in_Xfce_4.19.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Alpine_Linux_3.19_in_Xfce_4.19.png",
     "w": 1366,
     "h": 768,
     "caption": "Alpine Linux 3.19 Standard ejecutandose en Xfce 4.19 con modificaciones",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cf/Alpine_Linux_3.11_Xfce_-_English.png/960px-Alpine_Linux_3.11_Xfce_-_English.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/cf/Alpine_Linux_3.11_Xfce_-_English.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Alpine_Linux_3.11_Xfce_-_English.png",
     "w": 1366,
     "h": 768,
     "caption": "Alpine Linux 3.11 with Xfce desktop",
     "license": "GPL"
    }
   ]
  },
  "kali": {
   "title": "Kali Linux",
   "url": "https://en.wikipedia.org/wiki/Kali_Linux",
   "extract": "Kali Linux is a Linux distribution designed for digital forensics and penetration testing. It is maintained and funded by Offensive Security. The software is based on the testing branch of the Debian Linux Distribution: most packages Kali uses are imported from the Debian repositories. Kali Linux has gained popularity in the cybersecurity community due to its comprehensive set of tools designed for penetration testing, vulnerability analysis, and reverse engineering. It was developed by Mati Aharoni and Devon Kearns of Offensive Security through the rewrite of BackTrack, their previous information security testing Linux distribution based on Knoppix.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4b/Kali_Linux_2.0_wordmark.svg/960px-Kali_Linux_2.0_wordmark.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/4/4b/Kali_Linux_2.0_wordmark.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e6/VirtualBox_Kali_Linux_29_03_2022_11_10_35.png/960px-VirtualBox_Kali_Linux_29_03_2022_11_10_35.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/e/e6/VirtualBox_Kali_Linux_29_03_2022_11_10_35.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:VirtualBox_Kali_Linux_29_03_2022_11_10_35.png",
     "w": 1680,
     "h": 945,
     "caption": "Kali Linux",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "parrot": {
   "title": "Parrot OS",
   "url": "https://en.wikipedia.org/wiki/Parrot_OS",
   "extract": "Parrot OS is a Linux distribution based on Debian with a focus on security, privacy, and development.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/36/Parrot_OS_Desktop.png/960px-Parrot_OS_Desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/3/36/Parrot_OS_Desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/36/Parrot_OS_Desktop.png/960px-Parrot_OS_Desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/36/Parrot_OS_Desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Parrot_OS_Desktop.png",
     "w": 1920,
     "h": 952,
     "caption": "Parrot OS Desktop",
     "license": "GPL"
    }
   ]
  },
  "almalinux": {
   "title": "AlmaLinux",
   "url": "https://en.wikipedia.org/wiki/AlmaLinux",
   "extract": "AlmaLinux is a free and open source Linux distribution, a community-supported, production-grade enterprise operating system that is binary-compatible with Red Hat Enterprise Linux (RHEL). The name of the distribution comes from the word \"alma\", meaning \"soul\" in Spanish and other Latin languages. It was chosen to be a homage to the Linux community. It is developed by the American AlmaLinux OS Foundation, a 501(c) organization. The first stable release of AlmaLinux was published on 30 March 2021, and will be supported until 1 March 2029. AlmaLinux is built using publicly-viewable and reproducible methods using the AlmaLinux Build System (ALBS), which is a customized build system whose source code, like the distribution itself, is publicly distributed and licensed under open-source licenses.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/35/AlmaLinux_10.0_desktop_with_GNOME_47.png/960px-AlmaLinux_10.0_desktop_with_GNOME_47.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/3/35/AlmaLinux_10.0_desktop_with_GNOME_47.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/35/AlmaLinux_10.0_desktop_with_GNOME_47.png/960px-AlmaLinux_10.0_desktop_with_GNOME_47.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/35/AlmaLinux_10.0_desktop_with_GNOME_47.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:AlmaLinux_10.0_desktop_with_GNOME_47.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of default AlmaLinux version 10.0 desktop with GNOME 47",
     "license": "GPL"
    }
   ]
  },
  "rocky": {
   "title": "Rocky Linux",
   "url": "https://en.wikipedia.org/wiki/Rocky_Linux",
   "extract": "Rocky Linux is a free and open source Linux distribution developed by Rocky Enterprise Software Foundation, which is a privately owned benefit corporation that describes itself as a \"self-imposed not-for-profit\". It is intended to be a downstream, complete binary-compatible release using the Red Hat Enterprise Linux (RHEL) operating system source code. The project's aim is to provide a community-supported, production-grade enterprise operating system. Rocky Linux, along with RHEL, has become popular for enterprise operating system use. The first release candidate version of Rocky Linux was released on April 30, 2021, and its first general availability version was released on June 21, 2021. Rocky Linux 8 will be supported through May 2029, Rocky Linux 9 through May 2032, and Rocky Linux 10 through May 2035.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d9/Rocky_Linux_10_Workstation.png/960px-Rocky_Linux_10_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/d/d9/Rocky_Linux_10_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d9/Rocky_Linux_10_Workstation.png/960px-Rocky_Linux_10_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/d/d9/Rocky_Linux_10_Workstation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Rocky_Linux_10_Workstation.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of default Rocky Linux version 10.0 desktop with GNOME 47",
     "license": "GPL"
    }
   ]
  },
  "oracle": {
   "title": "Oracle Linux",
   "url": "https://en.wikipedia.org/wiki/Oracle_Linux",
   "extract": "Oracle Linux (abbreviated OL, formerly known as Oracle Enterprise Linux or OEL) is a Linux distribution packaged and freely distributed by Oracle, available partially under the GNU General Public License since late 2006. It is, in part, compiled from Red Hat Enterprise Linux (RHEL) source code, replacing Red Hat branding with Oracle's. It is also used by Oracle Cloud and Oracle Engineered Systems such as Oracle Exadata and others. Potential users can freely download Oracle Linux through Oracle's server, or from a variety of mirror sites, and can deploy and distribute it without cost. The company's Oracle Linux Support program aims to provide commercial technical support, covering Oracle Linux and existing RHEL or CentOS installations but without any certification from the former (i.e. without re-installation or re-boot). As of 2016, Oracle Linux had over 15,000 customers subscribed to",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/bf/Oracle_Linux_9_screenshot.png/960px-Oracle_Linux_9_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/b/bf/Oracle_Linux_9_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/bf/Oracle_Linux_9_screenshot.png/960px-Oracle_Linux_9_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/b/bf/Oracle_Linux_9_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Oracle_Linux_9_screenshot.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of an Oracle Linux 9 default desktop",
     "license": "GPL"
    }
   ]
  },
  "centos": {
   "title": "CentOS",
   "url": "https://en.wikipedia.org/wiki/CentOS",
   "extract": "CentOS (from Community Enterprise Operating System; also known as CentOS Linux) is a discontinued Linux distribution that provided a free and open-source community-supported computing platform, functionally compatible with its upstream source, Red Hat Enterprise Linux (RHEL). In January 2014, CentOS announced the official joining with Red Hat while staying independent from RHEL, under a new CentOS governing board. The first CentOS release in May 2004, numbered as CentOS version 2, was forked from RHEL version 2.1AS. Since version 8, CentOS officially supports the x86-64, ARM64, and POWER8 architectures, and releases up to version 6 also supported the IA-32 architecture. As of December 2015, AltArch releases of CentOS 7 are available for the IA-32 architecture, Power ISA, and for the ARMv7hl and AArch64 variants of the ARM architecture. CentOS 8 was released on 24 September 2019.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/51/CentOS_8.5_screenshot.png/960px-CentOS_8.5_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/5/51/CentOS_8.5_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/51/CentOS_8.5_screenshot.png/960px-CentOS_8.5_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/51/CentOS_8.5_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:CentOS_8.5_screenshot.png",
     "w": 1360,
     "h": 768,
     "caption": "English GUI of CentOS 8.5 (11.16.2021)",
     "license": "GPL"
    }
   ]
  },
  "opensuse": {
   "title": "OpenSUSE",
   "url": "https://en.wikipedia.org/wiki/OpenSUSE",
   "extract": "openSUSE is a free and open-source Linux distribution developed by the openSUSE Project. It is offered in two main variations: Tumbleweed, an upstream rolling release distribution, and Leap, a stable release distribution which is sourced from SUSE Linux Enterprise. The openSUSE project is sponsored by SUSE of Germany. The company released the first version as SUSE Linux in 1994. Its development was opened up to the community in 2005, which marked the creation of openSUSE. The focus of the developers is on creating a stable and user-friendly RPM-based operating system with a large target group for workstations and servers.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d0/OpenSUSE_Logo.svg/960px-OpenSUSE_Logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/d/d0/OpenSUSE_Logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7e/OpenSUSE_Leap_16.0_screenshot.webp/960px-OpenSUSE_Leap_16.0_screenshot.webp?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/7/7e/OpenSUSE_Leap_16.0_screenshot.webp?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:OpenSUSE_Leap_16.0_screenshot.webp",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of openSUSE Leap 16.0",
     "license": "GPL"
    }
   ]
  },
  "mint": {
   "title": "Linux Mint",
   "url": "https://en.wikipedia.org/wiki/Linux_Mint",
   "extract": "Linux Mint is a community-developed Linux distribution for x86-64 systems, based on Ubuntu. First released in 2006, Linux Mint is often noted for its ease of use, out-of-the-box functionality, and appeal to desktop users. It comes bundled with a selection of free and open-source software. The default desktop environment is Cinnamon, developed by the Linux Mint team, with MATE and Xfce available as alternatives. A Debian based version of Linux Mint also exists, called Linux Mint Debian Edition (LMDE).",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ac/LinuxMint22-Wilma-English.png/960px-LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/a/ac/LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ac/LinuxMint22-Wilma-English.png/960px-LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/a/ac/LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LinuxMint22-Wilma-English.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of Linux Mint 22 \"Wilma\" using the default Cinnamon desktop.",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/38/Lmde2.png/960px-Lmde2.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/38/Lmde2.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Lmde2.png",
     "w": 1366,
     "h": 768,
     "caption": "Linux Mint Debian Edition running Cinnamon 2.8",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "zorin": {
   "title": "Zorin OS",
   "url": "https://en.wikipedia.org/wiki/Zorin_OS",
   "extract": "Zorin OS is a Linux distribution based on Ubuntu which provides both free and paid versions. It uses a GNOME and Xfce 4 desktop environment by default, although the desktop is heavily customized and is for users more familiar with Windows, Chrome OS and macOS. Zorin OS Pro is a premium paid version offering additional desktop appearance customization options and apps for creative users such as for photo or video editing. Zorin is marketed as a privacy focused operating system aimed at everyday computer users.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c3/Zorin-18-Desktop_Installed.png/960px-Zorin-18-Desktop_Installed.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/c/c3/Zorin-18-Desktop_Installed.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c3/Zorin-18-Desktop_Installed.png/960px-Zorin-18-Desktop_Installed.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/c3/Zorin-18-Desktop_Installed.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Zorin-18-Desktop_Installed.png",
     "w": 1366,
     "h": 768,
     "caption": "Screenshot of Zorin OS 18 showing the menu using the modified default GNOME desktop",
     "license": "GPL"
    }
   ]
  },
  "pop": {
   "title": "Pop! OS",
   "url": "https://en.wikipedia.org/wiki/Pop!_OS",
   "extract": "Pop OS (stylized as Pop!_OS) is a free and open-source Linux distribution based on Ubuntu and developed by the American Linux computer manufacturer System76. It features the COSMIC desktop environment, a Rust-based and Wayland-only desktop created and maintained by System76. Pop!_OS is primarily designed to ship with the company’s computers, but it can also be downloaded and installed on most PCs. Pop!_OS provides full out-of-the-box support for both AMD and Nvidia GPUs. Pop!_OS provides default disk encryption, streamlined window and workspace management, keyboard shortcuts for navigation as well as built-in power management profiles. The latest releases also have packages that allow for easy setup for TensorFlow and CUDA.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c5/Pop_OS-Logo-nobg.svg/960px-Pop_OS-Logo-nobg.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/c/c5/Pop_OS-Logo-nobg.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5f/Apps_Pop%21_OS_21.10.png/960px-Apps_Pop%21_OS_21.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/5f/Apps_Pop%21_OS_21.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Apps_Pop!_OS_21.10.png",
     "w": 1920,
     "h": 1080,
     "caption": "Captura de pantalla mostrant el nou menú d'aplicacions anomenat Library més reduït i centrat a l'escriptori…",
     "license": "GPL"
    }
   ]
  },
  "elementary": {
   "title": "Elementary OS",
   "url": "https://en.wikipedia.org/wiki/Elementary_OS",
   "extract": "Elementary OS (stylized as elementary OS) is a Linux distribution based on Ubuntu LTS. It promotes itself as \"thoughtful, capable, and ethical computing\" and has a pay-what-you-want model. The operating system, the desktop environment (called Pantheon), and accompanying applications are developed and maintained by elementary, Inc.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/40/ElementaryOS8.0-Desktop.png/960px-ElementaryOS8.0-Desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/4/40/ElementaryOS8.0-Desktop.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/40/ElementaryOS8.0-Desktop.png/960px-ElementaryOS8.0-Desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/40/ElementaryOS8.0-Desktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:ElementaryOS8.0-Desktop.png",
     "w": 1920,
     "h": 1080,
     "caption": "A screenshot of the desktop of elementary OS 8.0",
     "license": "GPLv3"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/24/Scrivania_di_elementary_OS_5.0_Juno.png/960px-Scrivania_di_elementary_OS_5.0_Juno.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/24/Scrivania_di_elementary_OS_5.0_Juno.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Scrivania_di_elementary_OS_5.0_Juno.png",
     "w": 2560,
     "h": 1600,
     "caption": "Screenshot della scrivania di elementary OS 5.0 Juno, basato su Ubuntu 18.04 LTS",
     "license": "GPLv3"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b8/Elementary_odin.png/960px-Elementary_odin.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/b/b8/Elementary_odin.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Elementary_odin.png",
     "w": 1920,
     "h": 1080,
     "caption": "This image is the official screenshot of Elementary OS 6.0 Odin",
     "license": "GPLv3"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e5/Elementary_OS_7.0_Horus.jpg/960px-Elementary_OS_7.0_Horus.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/e/e5/Elementary_OS_7.0_Horus.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Elementary_OS_7.0_Horus.jpg",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of elementary OS 7 desktop",
     "license": "GPLv3"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c7/Elementary_OS_5.1_Hera.png/960px-Elementary_OS_5.1_Hera.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/c7/Elementary_OS_5.1_Hera.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Elementary_OS_5.1_Hera.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of elementary OS 5.1",
     "license": "GPLv3"
    }
   ]
  },
  "garuda": {
   "title": "Garuda Linux",
   "url": "https://en.wikipedia.org/wiki/Garuda_Linux",
   "extract": "Garuda Linux is an Arch Linux-based Linux distribution targeted towards gaming. It offers multiple desktop environments, but the KDE Plasma version is the default. The distribution is named after Garuda, the divine eagle mount of the god Vishnu in Hinduism. Garuda Linux features a rolling release update model using Pacman as its package manager.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png/960px-Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/6/69/Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png/960px-Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/69/Garuda_Linux_Dr460nized%2C_Bird_of_Prey.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Garuda_Linux_Dr460nized,_Bird_of_Prey.png",
     "w": 2560,
     "h": 1600,
     "caption": "Garuda Linux KDE Dr460nized, \"Bird of Prey\" screenshot",
     "license": "GPLv3"
    }
   ]
  }
 },
 "desktops": {
  "xfce": {
   "title": "Xfce",
   "url": "https://en.wikipedia.org/wiki/Xfce",
   "extract": "Xfce is a free and open-source desktop environment for Linux and other Unix-like operating systems. Xfce aims to be fast and lightweight while still visually appealing and easy to use. The desktop environment is designed to embody the traditional Unix philosophy of modularity and re-usability, as well as adherence to standards; specifically, those defined at freedesktop.org.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ed/XFCE_4.20.png/960px-XFCE_4.20.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/e/ed/XFCE_4.20.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ed/XFCE_4.20.png/960px-XFCE_4.20.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/e/ed/XFCE_4.20.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:XFCE_4.20.png",
     "w": 1920,
     "h": 1080,
     "caption": "XFCE 4.20 desktop environment",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/60/Xfce_4.12_on_Fedora_22.png/960px-Xfce_4.12_on_Fedora_22.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/60/Xfce_4.12_on_Fedora_22.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Xfce_4.12_on_Fedora_22.png",
     "w": 1024,
     "h": 768,
     "caption": "Xfce 4.12 desktop running on Fedora 22",
     "license": "GPL"
    }
   ]
  },
  "mate": {
   "title": "MATE (desktop environment)",
   "url": "https://en.wikipedia.org/wiki/MATE_(desktop_environment)",
   "extract": "MATE (MAH-tay) is a desktop environment composed of free and open-source software that runs on Linux, and other Unix-like operating systems such as BSD, and Illumos.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e8/Mate-logo.svg/960px-Mate-logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/e/e8/Mate-logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c1/PC-BSD_10.1.2_MATE_Screenshot.png/960px-PC-BSD_10.1.2_MATE_Screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/c1/PC-BSD_10.1.2_MATE_Screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:PC-BSD_10.1.2_MATE_Screenshot.png",
     "w": 2340,
     "h": 1440,
     "caption": "Screenshot of a PC-BSD 10.1.2 desktop (MATE) with dual monitor (dual head, pivot).",
     "license": "CC BY-SA 4.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/75/Mate-desktop-1.26.en.png/960px-Mate-desktop-1.26.en.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/7/75/Mate-desktop-1.26.en.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Mate-desktop-1.26.en.png",
     "w": 1366,
     "h": 768,
     "caption": "This is a screenshot of a typical MATE desktop with 1.26 version, which was taken from Fedora Linux 34 by me",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7a/MATE_1.10.png/960px-MATE_1.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/7/7a/MATE_1.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:MATE_1.10.png",
     "w": 1366,
     "h": 768,
     "caption": "MATE 1.10 on Manjaro Linux, GTK+3 version, taken by myself",
     "license": "LGPL"
    }
   ]
  },
  "kde": {
   "title": "KDE Plasma",
   "url": "https://en.wikipedia.org/wiki/KDE_Plasma",
   "extract": "KDE Plasma is a graphical shell developed by the KDE community for Linux and BSD. It serves as the interface layer between the user and the operating system, providing a graphical user interface (GUI) and workspace environment for launching applications, managing windows, and interacting with files and system settings. Plasma is designed to be modular and adaptable, with different variants tailored for specific device types, such as Plasma Desktop for personal computers, and Plasma Mobile for smartphones. Plasma was first introduced in 2008 as part of KDE Software Compilation 4, as a major technical overhaul, combining traditional desktop functionality with a widget-based system designed for flexibility and visual consistency. With the KDE brand repositioning in 2009, the KDE software compilation was split into three distinct projects: KDE Plasma, KDE Frameworks and KDE Gear, allowing ea",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/15/KDE_Plasma_6.4.5_Light.png/960px-KDE_Plasma_6.4.5_Light.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/1/15/KDE_Plasma_6.4.5_Light.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/46/KDE_Plasma_5.24_on_Arch_Linux_screenshot.png/960px-KDE_Plasma_5.24_on_Arch_Linux_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/46/KDE_Plasma_5.24_on_Arch_Linux_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:KDE_Plasma_5.24_on_Arch_Linux_screenshot.png",
     "w": 1920,
     "h": 1080,
     "caption": "KDE Plasma 5.24 screenshot with Konsole and System Settings showing Wayland information",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/15/KDE_Plasma_6.4.5_Light.png/960px-KDE_Plasma_6.4.5_Light.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/1/15/KDE_Plasma_6.4.5_Light.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:KDE_Plasma_6.4.5_Light.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of KDE Plasma 6.4.5 in Light theme (called Breeze Light)",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/52/KDE_Plasma_6.4.5_Dark.png/960px-KDE_Plasma_6.4.5_Dark.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/52/KDE_Plasma_6.4.5_Dark.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:KDE_Plasma_6.4.5_Dark.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of KDE Plasma 6.4.5 in Dark theme (called Breeze Dark)",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c6/KDE_Arch.png/960px-KDE_Arch.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/c6/KDE_Arch.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:KDE_Arch.png",
     "w": 1920,
     "h": 1080,
     "caption": "KDE Plasma running on Arch Linux. Shown are Konsole and Dolphin, two of KDE's core application windows",
     "license": "GPL"
    }
   ]
  },
  "lxqt": {
   "title": "LXQt",
   "url": "https://en.wikipedia.org/wiki/LXQt",
   "extract": "LXQt is a free and open source lightweight desktop environment. It was formed from the merger of the LXDE and Razor-qt projects. Like its GTK predecessor LXDE, LXQt does not ship or develop its own window manager; instead, LXQt lets the user decide which (supported) window manager they want to use. Linux distributions commonly default LXQt to Openbox, Xfwm4, or KWin.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/29/LXQt_2.0.0_Ambiance_screenshot.png/960px-LXQt_2.0.0_Ambiance_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/2/29/LXQt_2.0.0_Ambiance_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/29/LXQt_2.0.0_Ambiance_screenshot.png/960px-LXQt_2.0.0_Ambiance_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/29/LXQt_2.0.0_Ambiance_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LXQt_2.0.0_Ambiance_screenshot.png",
     "w": 1920,
     "h": 1080,
     "caption": "LXQt 2.0.0 with Ambiance theme",
     "license": "CC BY-SA 3.0"
    }
   ]
  },
  "lxde": {
   "title": "LXDE",
   "url": "https://en.wikipedia.org/wiki/LXDE",
   "extract": "LXDE (abbreviation for Lightweight X11 Desktop Environment) is a free desktop environment with comparatively low resource requirements. This makes it especially suitable for use on older or resource-constrained personal computers such as netbooks or system on a chip computers. LXDE was written in the C programming language, using the GTK 2 toolkit, and runs on Unix and other POSIX-compliant platforms, such as Linux and BSDs. The LXDE project aims to provide a fast and energy-efficient desktop environment.",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/4/4c/LXDE_desktop_full.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/4/4c/LXDE_desktop_full.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://upload.wikimedia.org/wikipedia/commons/4/4c/LXDE_desktop_full.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail_unscaled",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/4c/LXDE_desktop_full.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LXDE_desktop_full.png",
     "w": 801,
     "h": 601,
     "caption": "Base LXDE desktop, taken from lubuntu-9.10_lynxis_b14",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/53/LXDE-ArchLinux.png/960px-LXDE-ArchLinux.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/53/LXDE-ArchLinux.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LXDE-ArchLinux.png",
     "w": 1280,
     "h": 800,
     "caption": "LXDE desktop on ArchLinux",
     "license": "GPL"
    }
   ]
  },
  "cinnamon": {
   "title": "Cinnamon (desktop environment)",
   "url": "https://en.wikipedia.org/wiki/Cinnamon_(desktop_environment)",
   "extract": "Cinnamon is a free and open-source desktop environment for Linux and other Unix-like operating systems. It was originally based on GNOME 3, but follows traditional desktop metaphor conventions. The development of Cinnamon began by the Linux Mint team following the April 2011 release of GNOME 3, in which the conventional desktop metaphor of GNOME 2 was replaced in favor of GNOME Shell. Following several attempts to extend GNOME 3 so that it would suit the Linux Mint design goals through \"Mint GNOME Shell Extensions\", the Linux Mint team eventually forked several components of GNOME 3 to build an independent desktop environment. This separation from GNOME was completed with the release of Cinnamon 2.0.0 on 9 October 2013. Applets, extensions, actions, and desklets made explicitly for Cinnamon are no longer compatible with GNOME Shell.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5a/Cinnamon-logo.svg/960px-Cinnamon-logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/5/5a/Cinnamon-logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/LinuxMint22-Wilma-English-CustomDesktop.png/960px-LinuxMint22-Wilma-English-CustomDesktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/69/LinuxMint22-Wilma-English-CustomDesktop.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LinuxMint22-Wilma-English-CustomDesktop.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of Linux Mint 22 \"Wilma\" using the Cinnamon desktop.",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/48/Linux_Mint_19.1_%22Tessa%22_%28Cinnamon%29.png/960px-Linux_Mint_19.1_%22Tessa%22_%28Cinnamon%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/48/Linux_Mint_19.1_%22Tessa%22_%28Cinnamon%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Linux_Mint_19.1_%22Tessa%22_(Cinnamon).png",
     "w": 1920,
     "h": 1200,
     "caption": "Screenshot of Linux Mint 19.1 \"Tessa\"",
     "license": "GPLv2"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ac/LinuxMint22-Wilma-English.png/960px-LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/a/ac/LinuxMint22-Wilma-English.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:LinuxMint22-Wilma-English.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot of Linux Mint 22 \"Wilma\" using the default Cinnamon desktop.",
     "license": "GPL"
    }
   ]
  },
  "budgie": {
   "title": "Budgie (desktop environment)",
   "url": "https://en.wikipedia.org/wiki/Budgie_(desktop_environment)",
   "extract": "Budgie is an independent, free and open-source desktop environment for Linux and other Unix-like operating systems that targets the desktop metaphor. Budgie is developed by the Buddies of Budgie organization, which is composed of a team of contributors from Linux distributions such as Fedora, Debian, and Arch Linux. Its design emphasizes simplicity, minimalism, and elegance, while providing the means to extend or customize the desktop in various ways. Unlike desktop environments like Cinnamon, Budgie does not have a reference platform, and all distributions that ship Budgie are recommended to set defaults that best fit their desired user experience. Budgie is also shipped as an edition of certain Linux distributions, such as Ubuntu Budgie.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4e/BudgieDesktop-v10.7.jpg/960px-BudgieDesktop-v10.7.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/4/4e/BudgieDesktop-v10.7.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4e/BudgieDesktop-v10.7.jpg/960px-BudgieDesktop-v10.7.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/4e/BudgieDesktop-v10.7.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:BudgieDesktop-v10.7.jpg",
     "w": 2000,
     "h": 1125,
     "caption": "A screenshot depicting the default configuration of the Budgie desktop environment.",
     "license": "Apache License 2.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8d/Budgie_%28desktop_environment%29_v10.4.png/960px-Budgie_%28desktop_environment%29_v10.4.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/8/8d/Budgie_%28desktop_environment%29_v10.4.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Budgie_(desktop_environment)_v10.4.png",
     "w": 1366,
     "h": 768,
     "caption": "Screenshot of Budgie (desktop environment) version 10.4 showing settings dialog, panel, and open menu",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a6/Fedora_Budgie_38_Beta.jpg/960px-Fedora_Budgie_38_Beta.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/a/a6/Fedora_Budgie_38_Beta.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Fedora_Budgie_38_Beta.jpg",
     "w": 2711,
     "h": 1557,
     "caption": "The Budgie Desktop version 10.7.1 on the version 38 beta of Fedora Linux, with desktop icons enabled and a…",
     "license": "Apache License 2.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4d/Ubuntu_Budgie_22.10.png/960px-Ubuntu_Budgie_22.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/4d/Ubuntu_Budgie_22.10.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Ubuntu_Budgie_22.10.png",
     "w": 2048,
     "h": 1152,
     "caption": "Ubuntu Budgie 22.10",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/30/Solus_Budgie_4.3.jpg/960px-Solus_Budgie_4.3.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/30/Solus_Budgie_4.3.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Solus_Budgie_4.3.jpg",
     "w": 1920,
     "h": 1080,
     "caption": "Solus 4.3 Operating system with Budgie desktop environment developed by Solus",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e0/Budgie_on_Ultramarine_Linux_37.jpg/960px-Budgie_on_Ultramarine_Linux_37.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/e/e0/Budgie_on_Ultramarine_Linux_37.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Budgie_on_Ultramarine_Linux_37.jpg",
     "w": 1920,
     "h": 1080,
     "caption": "The Budgie Desktop version 10.7.1 on Ultramarine Linux, with desktop icons enabled and a single full-width…",
     "license": "Apache License 2.0"
    }
   ]
  },
  "gnome-flashback": {
   "title": "GNOME",
   "url": "https://en.wikipedia.org/wiki/GNOME",
   "extract": "GNOME is a desktop environment and suite of software for Linux and BSD developed by the GNOME Project and released as free and open source software. The primary components of GNOME are the GNOME Shell, which provides features such as virtual desktops and window management; and the GNOME Core Applications, which distribute a suite of software that integrates with the shell and provides basic system features such as a file manager and a computer configuration application. The GNOME Project is composed of both volunteers and paid contributors, the largest contributor being Red Hat. In 2023 and 2024, GNOME received €1,000,000 from Germany's Sovereign Tech Fund.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/68/Gnomelogo.svg/960px-Gnomelogo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/6/68/Gnomelogo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3d/GNOME_Flashback_3.36_with_GNOME_Panel_3.36_%282020-03%29.png/960px-GNOME_Flashback_3.36_with_GNOME_Panel_3.36_%282020-03%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/3d/GNOME_Flashback_3.36_with_GNOME_Panel_3.36_%282020-03%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:GNOME_Flashback_3.36_with_GNOME_Panel_3.36_(2020-03).png",
     "w": 1920,
     "h": 1199,
     "caption": "GNOME Flashback 3.36 with GNOME Panel 3.36 (2020-03)",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d8/GNOME_Classic_3.36_%282020-03%29.png/960px-GNOME_Classic_3.36_%282020-03%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/d/d8/GNOME_Classic_3.36_%282020-03%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:GNOME_Classic_3.36_(2020-03).png",
     "w": 1600,
     "h": 900,
     "caption": "GNOME Classic 3.36",
     "license": "GPL"
    }
   ]
  },
  "enlightenment": {
   "title": "Enlightenment (window manager)",
   "url": "https://en.wikipedia.org/wiki/Enlightenment_(window_manager)",
   "extract": "Enlightenment, also known simply as E, is a compositing window manager for the X Window System. Since version 0.20, Enlightenment also supports Wayland. It is shipped with some Linux distributions such as Bodhi Linux and Pentoo. Enlightenment is only a window manager at its core; however, with many modules included, it can be extended to resemble a full desktop environment. Since version 0.17 (E17), Enlightenment has been written with the Enlightenment Foundation Libraries (EFL), and the Enlightenment project also writes a set of applications with the EFL.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/9/9e/E17_enlightenment_logo_shiny_black_curved.svg/960px-E17_enlightenment_logo_shiny_black_curved.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/9/9e/E17_enlightenment_logo_shiny_black_curved.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/16/Enlightenment_0.26.0.png/960px-Enlightenment_0.26.0.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/1/16/Enlightenment_0.26.0.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Enlightenment_0.26.0.png",
     "w": 1920,
     "h": 1080,
     "caption": "A screenshot of the Enlightenment 0.26.0 desktop with various applications open.",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "i3": {
   "title": "I3 (window manager)",
   "url": "https://en.wikipedia.org/wiki/I3_(window_manager)",
   "extract": "i3 is a tiling window manager designed for X11, inspired by wmii and written in C. It supports tiling, stacking, and tabbing layouts, which are handled manually. Its configuration is achieved via a plain text file and extending i3 is possible using its Unix domain socket and JSON based IPC interface from many programming languages. Like wmii, i3 uses a control system very similar to that of vi and Vim. By default, window focus is controlled by what the documentation refers to as the 'Mod1' key (Alt key/Windows key) in addition to the right-hand home row keys (Mod1+J,K,L,Semicolon), while window movement is controlled by the addition of the Shift key (Mod1+Shift+J,K,L,Semicolon).",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/27/I3_window_manager_logo.svg/960px-I3_window_manager_logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/2/27/I3_window_manager_logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/af/I3_window_manager_screenshot.png/960px-I3_window_manager_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/a/af/I3_window_manager_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:I3_window_manager_screenshot.png",
     "w": 1280,
     "h": 800,
     "caption": "Screenshot of a typical i3 session",
     "license": "CC BY-SA 3.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/85/I3_window_manager_with_tabbed_layout.png/960px-I3_window_manager_with_tabbed_layout.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/8/85/I3_window_manager_with_tabbed_layout.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:I3_window_manager_with_tabbed_layout.png",
     "w": 1366,
     "h": 768,
     "caption": "Example of i3 window manager with tabbed layout",
     "license": "Public domain"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3b/I3_window_manager_with_stacking_layout.png/960px-I3_window_manager_with_stacking_layout.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/3b/I3_window_manager_with_stacking_layout.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:I3_window_manager_with_stacking_layout.png",
     "w": 1366,
     "h": 768,
     "caption": "Example of i3 window manager with stacking layout",
     "license": "Public domain"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/f/fc/I3_window_manager_with_floating_window.png/960px-I3_window_manager_with_floating_window.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/f/fc/I3_window_manager_with_floating_window.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:I3_window_manager_with_floating_window.png",
     "w": 1366,
     "h": 768,
     "caption": "Example of i3 window manager with floating window",
     "license": "Public domain"
    }
   ]
  },
  "openbox": {
   "title": "Openbox",
   "url": "https://en.wikipedia.org/wiki/Openbox",
   "extract": "Openbox is a free, stacking window manager for the X Window System, licensed under the GNU General Public License. Originally derived from Blackbox 0.65.0 (a C++ project), Openbox has been completely re-written in the C programming language and since version 3.0 is no longer based upon any code from Blackbox. Since at least 2010, it has been considered feature complete, bug free and a completed project. Occasional maintenance is done to keep it working, but only if needed. Openbox is designed to be small, fast, and fully compliant with the Inter-Client Communication Conventions Manual (ICCCM) and Extended Window Manager Hints (EWMH). It supports many features such as menus by which the user can control applications or which display various dynamic information.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f7/2010-04-24-133031_1280x800_scrot.png/960px-2010-04-24-133031_1280x800_scrot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/f/f7/2010-04-24-133031_1280x800_scrot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f7/2010-04-24-133031_1280x800_scrot.png/960px-2010-04-24-133031_1280x800_scrot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/f/f7/2010-04-24-133031_1280x800_scrot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:2010-04-24-133031_1280x800_scrot.png",
     "w": 1280,
     "h": 800,
     "caption": "Openbox 3.4.11 with the default Clearlooks theme. Other running programs are UXTerm, Vim, and Thunar",
     "license": "GPL"
    }
   ]
  },
  "fluxbox": {
   "title": "Fluxbox",
   "url": "https://en.wikipedia.org/wiki/Fluxbox",
   "extract": "Fluxbox is a stacking window manager for the X Window System, which started as a fork of Blackbox 0.61.1 in 2001, with the same aim to be lightweight. Its user interface has only a taskbar, a pop-up menu accessible by right-clicking on the desktop, and minimal support for graphical icons. All basic configurations are controlled by text files, including the construction of menus and the mapping of key-bindings. Fluxbox has high compliance to the Extended Window Manager Hints specification. Fluxbox is basic in appearance, but it can show a few options for improved attractiveness: colors, gradients, borders, and several other basic appearance attributes can be specified. Recent versions support rounded corners and graphical elements. Effects managers such as xcompmgr, cairo-compmgr and transset-df (deprecated) can add true transparency to desktop elements and windows. Enhancements can also",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8d/Fluxbox-logo.svg/960px-Fluxbox-logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/8/8d/Fluxbox-logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/56/Fluxbox.png/960px-Fluxbox.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/56/Fluxbox.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Fluxbox.png",
     "w": 1024,
     "h": 768,
     "caption": "Fluxbox",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "icewm": {
   "title": "IceWM",
   "url": "https://en.wikipedia.org/wiki/IceWM",
   "extract": "IceWM is a stacking window manager for the X Window System, originally written by Marko Maček. It was written from scratch in C++ and is released under the terms of the GNU Lesser General Public License. It is customizable, relatively lightweight in terms of memory and CPU usage, and comes with themes that allow it to imitate the GUI of Windows 95, Windows XP, Windows 7, OS/2, Motif, and other graphical user interfaces. IceWM can be configured from plain text files stored in a user's home directory, making it easy to customize and copy settings. IceWM has an optional, built-in taskbar with a dynamic start menu, tasks display, system tray, network and CPU meters, mail check and configurable clock. It features a task list window and an Alt+Tab task switcher. Official support for GNOME and KDE menus used to be available as a separate package. In recent IceWM versions, support for them is bu",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/7/77/IceWM_Logo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/7/77/IceWM_Logo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4a/IceWM_with_Xeyes.png/960px-IceWM_with_Xeyes.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/4a/IceWM_with_Xeyes.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:IceWM_with_Xeyes.png",
     "w": 1366,
     "h": 768,
     "caption": "IceWM on Debian Buster, featuring Xeyes and the Futureproto theme",
     "license": "CC BY-SA 4.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/23/IceWM_in_action.png/960px-IceWM_in_action.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/23/IceWM_in_action.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:IceWM_in_action.png",
     "w": 1366,
     "h": 768,
     "caption": "IceWM on Debian Buster, featuring Xcalendar and LXappearance",
     "license": "CC BY-SA 4.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2d/IceWM_NanoBlue_openSUSE.png/960px-IceWM_NanoBlue_openSUSE.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/2d/IceWM_NanoBlue_openSUSE.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:IceWM_NanoBlue_openSUSE.png",
     "w": 1366,
     "h": 768,
     "caption": "Screenshot of IceWM with xterm, using NanoBlue theme on openSUSE",
     "license": "LGPL"
    },
    {
     "src": "https://upload.wikimedia.org/wikipedia/commons/2/27/Icewm-default.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail_unscaled",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/27/Icewm-default.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Icewm-default.jpg",
     "w": 800,
     "h": 600,
     "caption": "A screenshot showing IceWM's default setup on a Debian machine.",
     "license": "CC BY-SA 3.0"
    }
   ]
  },
  "jwm": {
   "title": "JWM",
   "url": "https://en.wikipedia.org/wiki/JWM",
   "extract": "JWM may refer to: Waco JWM, a straight-wing model based on the ASO",
   "lead": null,
   "lead_full": null,
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/48/Openbsd37withjwm.png/960px-Openbsd37withjwm.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/48/Openbsd37withjwm.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Openbsd37withjwm.png",
     "w": 1024,
     "h": 768,
     "caption": "OpenBSD 3.7 with Joe's Window Manager for the window manager, on top of X.org",
     "license": "Public domain"
    }
   ]
  },
  "awesome": {
   "title": "Awesome (window manager)",
   "url": "https://en.wikipedia.org/wiki/Awesome_(window_manager)",
   "extract": "awesome, formerly jdwm, is a dynamic window manager for the X Window System developed in the programming languages C and Lua. Lua is also used to configure and extend the system. Its development began as a fork of dwm, though has diverged largely since. It aims to be very small and fast, yet highly customizable. It enables managing windows via keyboard. The fork was initially nicknamed jdwm, where \"jd\" denoted the principal programmer's initials and dwm denoted the software project it was forked from. The first git repository for what was to become awesome was set up in September 2007. jdwm was renamed to awesome, after the same phrase used by the How I Met Your Mother character Barney Stinson. awesome was officially announced on the dwm mailing list on September 20, 2007.",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/1/1f/Awesome_logo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/1/1f/Awesome_logo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/f/f0/Awesome_screenshot.png/960px-Awesome_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/f/f0/Awesome_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Awesome_screenshot.png",
     "w": 1280,
     "h": 1024,
     "caption": "Awesome screenshot",
     "license": "GPL"
    }
   ]
  },
  "qtile": {
   "title": "Tiling window manager",
   "url": "https://en.wikipedia.org/wiki/Tiling_window_manager",
   "extract": "In computing, a tiling window manager is a window manager with the organization of the screen often dependent on mathematical formulas to organise the windows into a non-overlapping frame. This is opposed to the more common approach used by stacking window managers, which allow the user to drag windows around, instead of windows snapping into a position. This allows for a different style of organization, although it departs from the traditional desktop metaphor.",
   "lead": null,
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/1/17/Dwm-screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": []
  },
  "xmonad": {
   "title": "Xmonad",
   "url": "https://en.wikipedia.org/wiki/Xmonad",
   "extract": "xmonad is a dynamic window manager (tiling) for the X Window System, noted for being written in the functional programming language Haskell.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d3/Xmonad-2022-new-logo.svg/960px-Xmonad-2022-new-logo.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/d/d3/Xmonad-2022-new-logo.svg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/2/2e/Xmonad_screenshot.png/960px-Xmonad_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/2/2e/Xmonad_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Xmonad_screenshot.png",
     "w": 1920,
     "h": 1080,
     "caption": "XMonad in tiling mode with two URXVT terminals and pcmanFM open",
     "license": "CC BY-SA 3.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/71/Xmonad-screen-triplehead-dons.png/960px-Xmonad-screen-triplehead-dons.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/7/71/Xmonad-screen-triplehead-dons.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Xmonad-screen-triplehead-dons.png",
     "w": 1600,
     "h": 1200,
     "caption": "This is a screenshot of an X window manager named Xmonad; it is a screenshot taken by Xmonad developer Don…",
     "license": "CC BY-SA 3.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/64/Xmonad-tall-status-dons.png/960px-Xmonad-tall-status-dons.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/6/64/Xmonad-tall-status-dons.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Xmonad-tall-status-dons.png",
     "w": 1024,
     "h": 768,
     "caption": "This is a screenshot of an X window manager named Xmonad; it is a screenshot taken by Xmonad developer Don…",
     "license": "CC BY-SA 3.0"
    }
   ]
  },
  "pekwm": {
   "title": "PekWM",
   "url": "https://en.wikipedia.org/wiki/PekWM",
   "extract": "PekWM is a minimalist window manager. It provides an application menu and window decorations. Other features include the likes of window grouping, xinerama support, automatic properties, and a keygrabber with keychains. PekWM is developed by Claes Nästen and is originally based on the code base of aewm++ but has since then diverged from it. PekWM is suitable to be used as a technical foundation for the user of a computer to build a customized environment around. PekWM is very customizable and has good system performance. PekWM is made for the X windowing system (X11). PekWM is primarily designed for use on operating systems featuring the Linux kernel, and is available in the repositories for many such system distributions.",
   "lead": null,
   "lead_full": null,
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/9/98/Pekwm.jpg/960px-Pekwm.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/9/98/Pekwm.jpg?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Pekwm.jpg",
     "w": 1024,
     "h": 768,
     "caption": "Une capture d'écran rendant compte de l'aspect de pekwm Screenshot of pekwm",
     "license": "CC BY-SA 4.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/73/Arch_Linux_with_PekWM.png/960px-Arch_Linux_with_PekWM.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/7/73/Arch_Linux_with_PekWM.png?utm_source=commons.wikimedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Arch_Linux_with_PekWM.png",
     "w": 1366,
     "h": 768,
     "caption": "A screenshot of Arch Linux with PekWM",
     "license": "GPL"
    }
   ]
  },
  "wmaker": {
   "title": "Window Maker",
   "url": "https://en.wikipedia.org/wiki/Window_Maker",
   "extract": "Window Maker is a free and open-source window manager for the X Window System. It emulates NeXTSTEP's Look and feel as a GNUstep-compatible environment.",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/f/fa/Wmaker-0.80.2.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/f/fa/Wmaker-0.80.2.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://upload.wikimedia.org/wikipedia/commons/f/fa/Wmaker-0.80.2.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail_unscaled",
     "full": "https://upload.wikimedia.org/wikipedia/commons/f/fa/Wmaker-0.80.2.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Wmaker-0.80.2.png",
     "w": 800,
     "h": 600,
     "caption": "A screenshot of the Window Maker window manager.",
     "license": "GPL"
    }
   ]
  },
  "fvwm3": {
   "title": "FVWM",
   "url": "https://en.wikipedia.org/wiki/FVWM",
   "extract": "The F Virtual Window Manager (FVWM) is a virtual window manager for the X Window System. Originally a twm derivative, FVWM is now a window manager for Unix-like systems.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/ba/Debian_FVWM_Green.png/960px-Debian_FVWM_Green.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/b/ba/Debian_FVWM_Green.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://upload.wikimedia.org/wikipedia/commons/0/0a/SUSE_5.1_FVWM_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail_unscaled",
     "full": "https://upload.wikimedia.org/wikipedia/commons/0/0a/SUSE_5.1_FVWM_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:SUSE_5.1_FVWM_screenshot.png",
     "w": 801,
     "h": 600,
     "caption": "Screenshot of SUSE Linux 5.1 with FVWM",
     "license": "GPL"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/87/Debian_FVWM_Motif_MWM_Emulation.png/960px-Debian_FVWM_Motif_MWM_Emulation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/8/87/Debian_FVWM_Motif_MWM_Emulation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_FVWM_Motif_MWM_Emulation.png",
     "w": 1024,
     "h": 768,
     "caption": "FVWM emulating Motif and MWM (Motif Window Manager), using the \"FVWM-min\" package. Running on Debian GNU/Linux",
     "license": "CC0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/ba/Debian_FVWM_Green.png/960px-Debian_FVWM_Green.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/b/ba/Debian_FVWM_Green.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_FVWM_Green.png",
     "w": 1024,
     "h": 768,
     "caption": "Green screen style for FVWM, using the \"FVWM-min\" package. Running on Debian GNU/Linux",
     "license": "CC0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/58/Debian_FVWM_CDE_Emulation.png/960px-Debian_FVWM_CDE_Emulation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/5/58/Debian_FVWM_CDE_Emulation.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_FVWM_CDE_Emulation.png",
     "w": 1024,
     "h": 768,
     "caption": "FVWM emulating the look of the Common Desktop Environment (CDE), using the \"FVWM-min\" package.",
     "license": "CC0"
    }
   ]
  },
  "dwm": {
   "title": "Dwm",
   "url": "https://en.wikipedia.org/wiki/Dwm",
   "extract": "dwm is a minimalist dynamic window manager for the X Window System developed by Suckless that has influenced the development of several other X window managers, including xmonad and awesome. It is externally similar to wmii, but internally much simpler. dwm is written purely in C for performance and lacks any configuration interface besides editing the source code. One of the project's guidelines is that the source code is intended never to exceed 2000 SLOC, and options meant to be user-configurable are all contained in a single header file.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b0/Dwm-shot.png/960px-Dwm-shot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/b/b0/Dwm-shot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b0/Dwm-shot.png/960px-Dwm-shot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/b/b0/Dwm-shot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Dwm-shot.png",
     "w": 1280,
     "h": 801,
     "caption": "Screenshot of the dwm window manager in use",
     "license": "Public domain"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c2/Dwm_dual_monitor.jpeg/960px-Dwm_dual_monitor.jpeg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/c/c2/Dwm_dual_monitor.jpeg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Dwm_dual_monitor.jpeg",
     "w": 1000,
     "h": 750,
     "caption": "The Dynamic Window Manager (\"dwm\") X11 window manager displaying its tiled modes running on two screens…",
     "license": "Public domain"
    }
   ]
  },
  "cwm": {
   "title": "Cwm (window manager)",
   "url": "https://en.wikipedia.org/wiki/Cwm_(window_manager)",
   "extract": "cwm (Calm Window Manager) is a stacking window manager for the X Window System. While it is primarily developed as a part of OpenBSD's base system, portable versions are available on other Unix-like operating systems.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/36/Cwm_%28window_manager%29.png/960px-Cwm_%28window_manager%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/3/36/Cwm_%28window_manager%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/36/Cwm_%28window_manager%29.png/960px-Cwm_%28window_manager%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/36/Cwm_%28window_manager%29.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Cwm_(window_manager).png",
     "w": 1280,
     "h": 720,
     "caption": "OpenBSD desktop managed with cwm running xstatbar, xconsole, xombrero/xxxterm and uxterm (with tmux, scrot…",
     "license": "CC BY-SA 3.0"
    }
   ]
  },
  "ratpoison": {
   "title": "Ratpoison",
   "url": "https://en.wikipedia.org/wiki/Ratpoison",
   "extract": "ratpoison is a tiling window manager for the X Window System primarily developed by Shawn Betts. The user interface and much of their functionality are inspired by the GNU Screen terminal multiplexer. While ratpoison is written in C, Betts' StumpWM re-implements a similar window manager in Common Lisp.",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/3/3d/Ratpoison_new.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/3/3d/Ratpoison_new.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0d/Ratpoison-screenshot.png/960px-Ratpoison-screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/0/0d/Ratpoison-screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Ratpoison-screenshot.png",
     "w": 1024,
     "h": 768,
     "caption": "en:Ratpoison",
     "license": "CC BY-SA 3.0"
    }
   ]
  },
  "twm": {
   "title": "Twm",
   "url": "https://en.wikipedia.org/wiki/Twm",
   "extract": "twm is a window manager for the X Window System. Started in 1987 by Tom LaStrange, it has been the standard window manager for the X Window System since version X11R4. The name originally stood for Tom's Window Manager, but the software was renamed Tab Window Manager by the X Consortium when they adopted it in 1989. twm is a stacking window manager that provides title bars, shaped windows, and icon management. It is highly configurable and extensible. twm was a breakthrough achievement in the early years, but has been superseded by other window managers which, unlike twm, use a widget toolkit rather than a combination of the X Toolkit Intrinsics and XRandR.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/bd/Debian_TWM_Maroon.png/960px-Debian_TWM_Maroon.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/b/bd/Debian_TWM_Maroon.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/bd/Debian_TWM_Maroon.png/960px-Debian_TWM_Maroon.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/b/bd/Debian_TWM_Maroon.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Debian_TWM_Maroon.png",
     "w": 1024,
     "h": 768,
     "caption": "TWM (Tom's Window Manager) running with its classic maroon theme as seen in early X11 versions.",
     "license": "CC0"
    }
   ]
  },
  "lumina": {
   "title": "Lumina (desktop environment)",
   "url": "https://en.wikipedia.org/wiki/Lumina_(desktop_environment)",
   "extract": "Lumina Desktop Environment, or simply Lumina, is a plugin-based desktop environment for Unix and Unix-like operating systems. It was designed specifically as a system interface for the now-discontinued TrueOS as well as systems derived from Berkeley Software Distribution (BSD) in general, but it has been ported to various Linux distributions.",
   "lead": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/82/DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png/960px-DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/8/82/DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/8/82/DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png/960px-DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/8/82/DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:DragonFly_BSD_6.2.1_Lumina_desktop_screenshot.png",
     "w": 1280,
     "h": 720,
     "caption": "Screenshot of DragonFly BSD 6.2.1 with Lumina (desktop environment)",
     "license": "BSD"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/45/Lumina1.0.0-TrueOS.png/960px-Lumina1.0.0-TrueOS.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/4/45/Lumina1.0.0-TrueOS.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Lumina1.0.0-TrueOS.png",
     "w": 1920,
     "h": 1080,
     "caption": "Screenshot which shows Lumina Desktop in TrueOS system",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "ukui": {
   "title": "UKUI",
   "url": "https://en.wikipedia.org/wiki/UKUI",
   "extract": "UKUI (Ultimate Kylin User Interface) is a desktop environment for Linux distributions and other UNIX-like operating systems, originally developed for Ubuntu Kylin, and written using the Qt framework. UKUI was a fork of the MATE Desktop Environment. UKUI is a lightweight desktop environment, which consumes few resources and works with older computers. It has been developed with GTK and Qt technologies. Its visual appearance is similar to Windows 7, making it easier for new users of Linux.",
   "lead": "https://upload.wikimedia.org/wikipedia/commons/c/c1/UKUI.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled",
   "lead_full": "https://upload.wikimedia.org/wikipedia/commons/c/c1/UKUI.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=original",
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/38/Ubuntu_kylin.png/960px-Ubuntu_kylin.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/38/Ubuntu_kylin.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Ubuntu_kylin.png",
     "w": 2560,
     "h": 1600,
     "caption": "Image of Ubuntu Kylin 21.10",
     "license": "CC BY-SA 4.0"
    },
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/18/White-theme-Linux-Kylin.jpg/960px-White-theme-Linux-Kylin.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/1/18/White-theme-Linux-Kylin.jpg?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:White-theme-Linux-Kylin.jpg",
     "w": 1366,
     "h": 672,
     "caption": "Desktop environment UKUI in Linux Kylin",
     "license": "CC BY-SA 4.0"
    }
   ]
  },
  "bspwm": {
   "title": "bspwm",
   "url": "https://github.com/baskerville/bspwm",
   "extract": null,
   "lead": null,
   "lead_full": null,
   "images": []
  },
  "herbstluftwm": {
   "title": "herbstluftwm",
   "url": "https://herbstluftwm.org",
   "extract": null,
   "lead": null,
   "lead_full": null,
   "images": []
  },
  "spectrwm": {
   "title": "spectrwm",
   "url": "https://github.com/conformal/spectrwm",
   "extract": null,
   "lead": null,
   "lead_full": null,
   "images": [
    {
     "src": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/39/Scrotwm.png/960px-Scrotwm.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=thumbnail",
     "full": "https://upload.wikimedia.org/wikipedia/commons/3/39/Scrotwm.png?utm_source=en.wikipedia.org&utm_campaign=imageinfo&utm_content=original",
     "page": "https://commons.wikimedia.org/wiki/File:Scrotwm.png",
     "w": 1920,
     "h": 1200,
     "caption": "spectrwm (then called scrotwm) in action",
     "license": "Public domain"
    }
   ]
  }
 },
 "curated": true
}
__FORGE_FILE_DATA_INFO_JSON__
  cat > "$FORGE_APP/data/shots.json" <<'__FORGE_FILE_DATA_SHOTS_JSON__'
{
"base": "https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/shots/",
"ids": {}
}
__FORGE_FILE_DATA_SHOTS_JSON__
  cat > "$FORGE_APP/selkies-cli" <<'__FORGE_FILE_SELKIES_CLI__'
#!/usr/bin/env bash
# selkies-cli front end, generated by build.py
FORGE_AS_CLI=1
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

FORGE_VERSION="1.9.0"
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

# The engine and UI were unpacked by docker.sh; nothing to extract here.
extract_payload() {
  if [ ! -f "$FORGE_APP/engine.py" ]; then
    die "Selkies Forge is not installed in $FORGE_HOME. Run: curl -fsSL $FORGE_URL | bash"
  fi
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
sess = d.get("session") or {}
if sess.get("wm"):
    rows.insert(0, ("desktop", "%s is up" % sess["wm"],
                    "screen " + ("follows your window" if d.get("display") == "fit"
                                 else (d.get("display") or "") + ", scaled to fit")))
print()
if d.get("warning"):
    print("  " + c("1;38;5;221", "▰ STARTED, WITH A PROBLEM") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
else:
    print("  " + c("1;38;5;79", "▰ READY") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
print("  " + c("2", "─" * 66))
if d.get("warning"):
    import textwrap
    for ln in textwrap.wrap(d["warning"], 70):
        print("  " + c("38;5;221", ln))
    for ln in ((sess.get("log") or "").strip().splitlines()[-8:]):
        print("    " + c("2", ln[:100]))
    print("  " + c("2", "─" * 66))
fx = {"memory": "gave it more memory", "shm": "more shared memory", "seccomp": "relaxed seccomp",
      "slow": "waited longer for a slow first boot", "restart": "restarted it once"}
if d.get("fixes"):
    print("  %s %s" % (c("38;5;79", "\u2714 fixed on the way:"), ", ".join(fx.get(f, f) for f in d["fixes"])))
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
  stream_job_view launch "Forging $id" launch "$id" "$@"
}

# Run an engine command that streams a job (launch, clone, backup, restore)
# and draw it: a progress bar, the log scrolling above it, then the result.
# Ctrl-C reaches the engine, which cancels the job and cleans up.
stream_job_view() {
  local kind="$1" heading="$2"; shift 2
  local -a eargs=("$@")
  local pct=0 phase="working" result="" failed=0
  local log="$FORGE_LOGS/$kind-$(date +%Y%m%d-%H%M%S).log"

  title "$heading" "live output below, full log at $log"
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
  done < <(engine "${eargs[@]}" 2>&1)

  printf '%s%s' "$CLRL" "$SHOW"
  if [ -n "$result" ]; then
    case "$kind" in
      launch|clone) FORGE_COLOR=$COLOR render_result "$result" ;;
      *) printf '%s' "$result" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
b = d.get("backup") or {}
if b:
    print("  \u2714 backed up %s: %s (%.1f MB)" % (d.get("name"), b.get("file"), (b.get("size") or 0) / 1048576.0))
elif d.get("safety"):
    print("  \u2714 restored %s from %s" % (d.get("name"), d.get("file")))
    print("    the files from before are kept in %s" % d["safety"])
else:
    print("  \u2714 done")
' ;;
    esac
    printf '\n'
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
print("E_PROFILE='%s'" % q(d["profile"]))
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

  local disk_gb=$((P_DISK / 1024))
  if confirm "Use the suggested resources (${P_MEM} MB RAM, ${P_CPU} cores, ${disk_gb} GB storage)?" y; then
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

  # Sign-in. Without this anyone who reaches the URL is already inside.
  local want_auth=n
  [ "$E_PROFILE" = "kasm" ] && want_auth=y
  if confirm "Set a username and password for this desktop?" "$want_auth"; then
    local u pw
    if [ "$E_PROFILE" = "kasm" ]; then
      u="kasm_user"
      info "this image always signs you in as kasm_user"
    else
      u=$(ask "username" "forge")
    fi
    pw=$(ask "password (blank generates one)" "")
    if [ -z "$pw" ]; then
      pw=$("$PY" -c "import secrets,string
a = string.ascii_letters + string.digits
print(''.join(secrets.choice(a) for _ in range(16)))")
      info "generated password: $pw"
      warn "write it down, it is set inside the container and cannot be read back"
    fi
    args+=(--user "$u" --password "$pw")
  fi
  if [ "$NO_TUNNEL" = 1 ]; then
    args+=(--no-tunnel)
  elif ! confirm "Open a public serveo tunnel?" y; then
    args+=(--no-tunnel)
  fi
  if confirm "Start it automatically whenever Docker starts (after a reboot)?" n; then
    args+=(--autostart)
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
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
        ;;
      *)
        local act
        act=$(menu_choose "$pick" \
          $'open\tShow its links\tlocal and tunnel URLs' \
          $'shell\tOpen a shell in it\tdocker exec' \
          $'tunnel\tOpen or replace the tunnel\tfresh serveo URL' \
          $'untunnel\tDrop the tunnel\tkeep it local only' \
          $'limits\tChange limits\tmemory, cpu, shared memory, storage' \
          $'autostart\tToggle auto-start\tcome back after a reboot, or not' \
          $'restart\tRestart it\t' \
          $'stop\tStop it\t' \
          $'start\tStart it\t' \
          $'logs\tShow recent logs\tlast 120 lines' \
          $'events\tWhat happened to it\tlaunches, crashes, heals, repairs' \
          $'backup\tBack up its files\ta copy of its home folder' \
          $'clone\tClone it\ta second desktop with a copy of its files' \
          $'idle\tStop it when idle\twhen nobody has had it open for a while' \
          $'repair\tRepair it\trecreate on the newest forge layer; files are kept' \
          $'remove\tRemove it\tasks about the data volume too' \
          $'back\tBack\t') || continue
        case "$act" in
          back|"") : ;;
          open) print_instances ;;
          shell)
            printf '\n'; info "handing you a shell inside $pick, type exit to come back"; printf '\n'
            if [ -z "$TTY_IN" ]; then
              warn "a shell needs a terminal; run this script from one"
            else
              docker exec -it "$pick" /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash -l; else exec /bin/sh -l; fi' <"$TTY_IN"
            fi
            ;;
          logs) engine logs "$pick" --tail 120 | sed 's/^/    /' ;;
          events) engine events --name "$pick" --limit 30 | sed 's/^/    /' ;;
          backup) cmd_backup "$pick" ;;
          clone) cmd_clone "$pick" "$(ask "name for the copy" "${pick#forge-}-copy")" ;;
          idle) cmd_idle "$pick" "$(ask "minutes with nobody watching (0 = never)" "60")" ;;
          limits)
            local cur; cur=$(engine instances 2>/dev/null | "$PY" -c "
import json,sys
for i in json.load(sys.stdin)['instances']:
    if i['name']=='$pick':
        l=i.get('limits') or {}
        print(l.get('memory_mb') or 1024, l.get('cpus') or 1, l.get('shm_mb') or 256, i.get('disk_cap_mb') or 10240)")
            local cm cc cs cd nm nc ns nd
            read -r cm cc cs cd <<<"$cur"
            nm=$(ask "memory in MB" "$cm"); nc=$(ask "cpu cores" "$cc")
            ns=$(ask "shared memory in MB (browsers want 512+)" "$cs"); nd=$(ask "storage in MB" "$cd")
            if [ "$ns" != "$cs" ] || [ "$nd" != "$cd" ]; then
              info "shared memory and storage need the desktop recreated; files in /config are kept"
            fi
            spin_start "applying limits to $pick"
            local r; r=$(engine retune "$pick" --memory "$nm" --cpus "$nc" --shm "$ns" --disk "$nd" 2>&1)
            spin_stop
            if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
            elif printf '%s' "$r" | grep -q '"recreated": true'; then ok "recreated $pick with the new limits"
            else ok "limits applied live"; fi
            ;;
          autostart)
            local now; now=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$pick" 2>/dev/null)
            if [ "$now" = "no" ] || [ -z "$now" ]; then
              engine retune "$pick" --autostart on >/dev/null && ok "$pick now starts with Docker"
            else
              engine retune "$pick" --autostart off >/dev/null && ok "$pick only starts when you start it"
            fi
            ;;
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
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
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
    warn "this exposes docker control beyond localhost; anyone who can reach it controls docker"
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

  ask_boot_once

  # Background, or hold the terminal until ctrl-c?
  local mode="$WEBUI_MODE"
  if [ -z "$mode" ]; then
    if [ -n "$TTY_IN" ]; then
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
    info "open:          $srv_url"
    info "stop it with:  $FORGE_RUN --stop"
    info "           or:  kill $srv_pid"
    info "log:           $log"
    printf '\n  %syour shell is back · the forge menu has exited so the prompt is yours%s\n\n' \
      "$DIM" "$NC"
    # Leaving the menu running would just redraw it over the shell we were
    # asked to hand back, which looks like the whole thing restarted.
    exit 0
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
    engine stop-request ctrl-c >/dev/null 2>&1
    kill "$srv_pid" 2>/dev/null
    printf '\n'
    ok "web UI stopped"
  else
    warn "the web UI exited on its own, see $log"
  fi
  [ "$FORGE_FROM_MENU" = 1 ] && printf '  %sback to the forge menu%s\n' "$DIM" "$NC"
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
    # Tell it why, so the next start can say "you stopped it" rather than guess.
    engine stop-request "${FORGE_STOP_REASON:-user}" >/dev/null 2>&1
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
  local cli; cli=$(cat "$FORGE_STATE/cli-path" 2>/dev/null)
  if [ -n "$cli" ] && grep -q 'Installed by docker.sh' "$cli" 2>/dev/null; then
    rm -f "$cli" && ok "removed the selkies-cli command ($cli)"
  fi
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null; then
      sed -i '/# >>> selkies-forge >>>/,/# <<< selkies-forge <<</d' "$rc" && ok "cleaned the PATH line from $rc"
    fi
  done
  engine boot disable >/dev/null 2>&1
  rm -rf "$FORGE_HOME"
  ok "removed $FORGE_HOME"
  printf '\n  %sthanks for using the forge%s\n\n' "$DIM" "$NC"
}

# =========================================================================
#  main menu
# =========================================================================

# Older versions created every desktop with --restart unless-stopped, so they
# all came back whenever Docker or the machine restarted. Offer to undo that once.
review_autostart() {
  local marker="$FORGE_STATE/autostart-reviewed"
  [ -f "$marker" ] && return 0
  local names
  names=$(docker ps -a --filter "label=io.selkiesforge.entry" \
    --format '{{.Names}}' 2>/dev/null | while read -r n; do
      [ -n "$n" ] || continue
      p=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)
      [ "$p" != "no" ] && [ -n "$p" ] && printf '%s ' "$n"
    done)
  if [ -z "$names" ]; then touch "$marker"; return 0; fi
  title "Desktops that start on their own" "these come back every time Docker or this machine restarts"
  for n in $names; do info "$n"; done
  if confirm "Stop them starting automatically? (you can turn it back on per desktop)" y; then
    for n in $names; do docker update --restart no "$n" >/dev/null 2>&1 && ok "$n: auto-start off"; done
  else
    info "left as they are; change any of them later in the manager"
  fi
  # Only remember the question once it has actually been answered.
  touch "$marker"
}

# =========================================================================
#  the selkies-cli command
# =========================================================================

# A small wrapper on your PATH that runs the copy of this front end unpacked
# next to the engine. That copy exists even after "curl ... | bash", where no
# copy of this script is ever saved to disk.
cli_bin_dir() {
  if [ -n "${FORGE_BIN_DIR:-}" ]; then printf '%s' "$FORGE_BIN_DIR"; return; fi
  local d
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in
      *":$d:"*) if [ -d "$d" ] && [ -w "$d" ]; then printf '%s' "$d"; return; fi ;;
    esac
  done
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then printf '%s' /usr/local/bin; return; fi
  printf '%s' "$HOME/.local/bin"
}

add_path_to_rc() {
  local dir="$1" rc added=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ] || continue
    grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null && continue
    {
      printf '\n# >>> selkies-forge >>>\n'
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$dir" "$dir"
      printf '# <<< selkies-forge <<<\n'
    } >>"$rc" 2>/dev/null && added=1
  done
  [ "$added" = 1 ] && CLI_RC_ADDED=1
  return 0
}

install_cli() {
  local dir target body
  dir=$(cli_bin_dir)
  target="$dir/selkies-cli"
  body="#!/usr/bin/env bash
# selkies-cli: brings Selkies Forge back up. Installed by docker.sh.
export FORGE_HOME=\"\${FORGE_HOME:-$FORGE_HOME}\"
if [ ! -f \"\$FORGE_HOME/app/selkies-cli\" ]; then
  echo \"selkies-cli: Selkies Forge is no longer installed in \$FORGE_HOME.\" >&2
  echo \"Reinstall it with: curl -fsSL $FORGE_URL | bash\" >&2
  exit 1
fi
exec bash \"\$FORGE_HOME/app/selkies-cli\" \"\$@\""

  if [ -e "$target" ] && ! grep -q 'Installed by docker.sh' "$target" 2>/dev/null; then
    warn "$target already exists and is not ours, so selkies-cli was not installed"
    return 1
  fi
  # The command belongs to whichever install made it. A second install in
  # another FORGE_HOME (a test copy, say) must not quietly take it over;
  # it only does if that other install is gone, or you named the folder.
  if [ -f "$target" ] && [ -z "${FORGE_BIN_DIR:-}" ]; then
    local other
    other=$(sed -n 's/^export FORGE_HOME="\${FORGE_HOME:-\(.*\)}"$/\1/p' "$target" 2>/dev/null)
    if [ -n "$other" ] && [ "$other" != "$FORGE_HOME" ] && [ -f "$other/app/selkies-cli" ]; then
      CLI_PATH="$FORGE_APP/selkies-cli"
      FORGE_RUN="bash $CLI_PATH"
      return 0
    fi
  fi
  if [ -f "$target" ] && [ "$(cat "$target")" = "$body" ]; then
    CLI_PATH="$target"
  else
    mkdir -p "$dir" 2>/dev/null
    if ! printf '%s\n' "$body" >"$target" 2>/dev/null; then
      warn "could not write $target, so selkies-cli was not installed"
      return 1
    fi
    chmod 755 "$target"
    CLI_PATH="$target"
    CLI_NEW=1
  fi
  printf '%s' "$CLI_PATH" >"$FORGE_STATE/cli-path"
  case ":$PATH:" in
    *":$dir:"*) FORGE_RUN="selkies-cli" ;;
    *)
      # A directory you picked yourself (FORGE_BIN_DIR) is your business;
      # only the default location gets a PATH line in your shell profile.
      [ -z "${FORGE_BIN_DIR:-}" ] && add_path_to_rc "$dir"
      FORGE_RUN="$CLI_PATH"
      ;;
  esac
  return 0
}

announce_cli() {
  [ "$CLI_NEW" = 1 ] || return 0
  printf '\n'
  ok "installed ${B}selkies-cli${NC}: run it from any terminal to come back here"
  if [ "$CLI_RC_ADDED" = 1 ]; then
    info "added $(dirname "$CLI_PATH") to your PATH in your shell profile;"
    info "open a new terminal first, or run:  export PATH=\"$(dirname "$CLI_PATH"):\$PATH\""
  fi
}

# Quiet when everything is already in place, which is the normal case for
# selkies-cli; the full installers only speak up when something is missing.
preflight() {
  if [ "$FORGE_AS_CLI" = 1 ] && find_python && docker_usable; then
    return 0
  fi
  install_python
  install_docker
  install_extras
}

# =========================================================================
#  status + home screen
# =========================================================================

forge_status_json() { engine status 2>/dev/null || printf '{}'; }

# Turns the status JSON into shell variables the menu can branch on.
status_vars() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
w = d.get("webui") or {}
def q(v): return "'" + str(v if v is not None else "").replace("'", "") + "'"
print("UI_STATE=" + q(w.get("state", "down")))
print("UI_URL=" + q(w.get("url", "")))
print("UI_PID=" + q(w.get("pid", "")))
print("UI_PORT=" + q(w.get("port", "")))
print("UI_BIND=" + q(w.get("bind", "")))
print("UI_EXPOSED=" + q(1 if w.get("tunnel") else 0))
print("UI_RESTART=" + q(1 if w.get("restart_needed") else 0))
print("UI_LOG=" + q(w.get("log", "")))
print("DOCKER_OK=" + q(1 if d.get("docker") else 0))
print("RUNNING=" + q(d.get("running", 0)))
print("STOPPED=" + q(d.get("stopped", 0)))
print("TOTAL=" + q(len(d.get("desktops") or [])))
ls = d.get("last_stop") or {}
print("LAST_REASON=" + q(ls.get("reason", "")))
print("LAST_CLEAN=" + q(1 if ls.get("clean") else 0))
print("LAST_DISMISSED=" + q(1 if ls.get("dismissed") else 0))
print("RESTORE_N=" + q(len(ls.get("restore") or [])))
b = d.get("boot") or {}
print("BOOT_ON=" + q(1 if b.get("enabled") else 0))
print("BOOT_ASKED=" + q(1 if b.get("asked") else 0))
print("BOOT_METHOD=" + q(b.get("method") or ""))
print("BOOT_LINGER=" + q("" if b.get("linger") is None else (1 if b.get("linger") else 0)))
PYEOF
}

render_status() {
  FORGE_COLOR=$COLOR "$PY" - "$1" <<'PYEOF'
import json, os, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def dur(s):
    s = int(s or 0)
    if s < 60: return "%ds" % s
    if s < 3600: return "%dm" % (s // 60)
    if s < 86400: return "%dh %dm" % (s // 3600, s % 3600 // 60)
    return "%dd %dh" % (s // 86400, s % 86400 // 3600)
def short(url):
    if not url: return ""
    host = url.split("://", 1)[-1].split("/")[0]
    head, _, tail = host.partition(".")
    return (head[:8] + "…." + tail) if len(head) > 10 and tail else host

w = d.get("webui") or {}
st = w.get("state", "down")
print()
print("  " + c("1;38;5;255", "Status"))
print("  " + c("2", "─" * 64))
if not d.get("docker", True):
    print("  %s %s  %s" % (c("2", "%-9s" % "Docker"), c("38;5;203", "!"),
                           c("38;5;203", "not answering: " + str(d.get("docker_error") or "")[:60])))
if st == "up":
    print("  %s %s  running at %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;79", "●"),
          c("1;38;5;75", w.get("url", "")), c("2", "· up " + dur(w.get("uptime_s")))))
    if w.get("restart_needed"):
        print("  %s %s  %s" % (c("2", "%-9s" % "Update"), c("38;5;141", "\u2726"),
              "a new version is installed; restart the web UI to use it"))
elif st == "stale":
    print("  %s %s  %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;221", "!"),
          c("38;5;221", "stopped unexpectedly"), c("2", "· " + (w.get("why") or ""))))
else:
    print("  %s %s  %s" % (c("2", "%-9s" % "Web UI"), c("2", "○"), "not running"))

import time as _t
def when(ts):
    if not ts: return ""
    ago = _t.time() - float(ts)
    stamp = _t.strftime("%H:%M", _t.localtime(float(ts))) if ago < 86400 else \
        _t.strftime("%a %d %b %H:%M", _t.localtime(float(ts)))
    return "%s, %s ago" % (stamp, dur(ago))
ls = d.get("last_stop") or {}
if ls and not ls.get("dismissed"):
    clean = ls.get("clean")
    col = "38;5;79" if clean else ("38;5;203" if ls.get("reason") in ("host-crash", "crash", "oom", "error") else "38;5;221")
    head = "Last time" if st == "up" else "Stopped"
    print("  %s %s  %s  %s" % (c("2", "%-9s" % head), c(col, "●" if clean else "!"),
          ls.get("label", ""), c("2", "· " + when(ls.get("at") or ls.get("last_seen")))))
    if ls.get("boot_changed") and ls.get("boot_time"):
        print("  %s    %s" % (" " * 9, c("2", "machine up since " + _t.strftime("%a %H:%M", _t.localtime(ls["boot_time"])))))
    if ls.get("detail") and not clean and ls.get("reason") != "host-crash":
        print("  %s    %s" % (" " * 9, c("2", str(ls["detail"])[:70])))
    if ls.get("restore"):
        n = len(ls["restore"])
        print("  %s    %s" % (" " * 9, c("38;5;221", "%d desktop%s that %s running then %s stopped now" % (
            n, "" if n == 1 else "s", "was" if n == 1 else "were", "is" if n == 1 else "are"))))
b = d.get("boot") or {}
if b.get("enabled"):
    extra = ""
    if b.get("method") == "systemd" and b.get("linger") is False:
        extra = c("38;5;221", " · only after you log in (linger is off)")
    print("  %s %s  %s%s" % (c("2", "%-9s" % "On boot"), c("38;5;79", "●"),
          "the web UI starts by itself (%s)" % b.get("method"), extra))

items = d.get("desktops") or []
run, stop = d.get("running", 0), d.get("stopped", 0)
if not items:
    print("  %s %s  %s" % (c("2", "%-9s" % "Desktops"), c("2", "○"), "none yet"))
else:
    print("  %s %s  %d running · %d stopped" % (c("2", "%-9s" % "Desktops"),
          c("38;5;79", "●") if run else c("2", "○"), run, stop))
    for i in sorted(items, key=lambda x: (not x["running"], x["title"]))[:6]:
        dot = c("38;5;79", "●") if i["running"] else c("2", "○")
        where = i.get("local_url") or "" if i["running"] else c("2", "stopped")
        pub = (c("2", "  public ") + short(i["public_url"])) if i.get("public_url") else ""
        print("     %s %-22.22s %s%s" % (dot, i["title"], where.replace("http://", ""), pub))
    if len(items) > 6:
        print("     " + c("2", "and %d more" % (len(items) - 6)))
print("  " + c("2", "─" * 64))
PYEOF
}

cmd_status() {
  local js; js=$(forge_status_json)
  render_status "$js"
  printf '\n'
}

cmd_open() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  if [ "$UI_STATE" != "up" ]; then
    warn "the web UI is not running"
    if confirm "Start it in the background now?" y; then
      WEBUI_MODE="bg" cmd_webui
    fi
    return 0
  fi
  printf '\n  %s%s%s\n\n' "$B$BLU" "$UI_URL" "$NC"
  if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$UI_URL" >/dev/null 2>&1 &
    ok "opened in your browser"
  else
    info "open that link in your browser"
  fi
  printf '\n'
}

cmd_restart() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  # Come back on the same address, unless you asked for a different one.
  if [ -n "$UI_PORT" ] && [ "$WEBUI_PORT_SET" != 1 ]; then WEBUI_PORT="$UI_PORT"; fi
  if [ -n "$UI_BIND" ] && [ "$WEBUI_BIND" = "127.0.0.1" ]; then WEBUI_BIND="$UI_BIND"; fi
  [ "$UI_EXPOSED" = 1 ] && WEBUI_EXPOSE=1
  [ "$UI_STATE" = "down" ] || FORGE_STOP_REASON="${FORGE_STOP_REASON:-restart}" cmd_stop >/dev/null 2>&1
  WEBUI_MODE="${WEBUI_MODE:-bg}" cmd_webui
}

cmd_ui_log() {
  local log="$FORGE_LOGS/webui.log"
  title "Web UI log" "$log"
  if [ -s "$log" ]; then tail -n 25 "$log" | sed 's/^/    /'; else info "the log is empty"; fi
  [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
}

cmd_update() {
  title "Update" "git pull from GitHub, fast-forward only"
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  spin_start "checking GitHub"
  local r
  r=$(engine check-update --install 2>/dev/null)
  spin_stop
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
via = "git pull" if d.get("method") == "git" else "download"
commit = (d.get("installed_commit") or d.get("remote_commit") or "")[:7]
tag = c("2", "(" + via + (", " + commit if commit else "") + ")")
if d.get("just_installed"):
    print("  %s updated to %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
elif d.get("error"):
    print("  %s %s" % (c("38;5;221", "!"), d["error"]))
else:
    print("  %s already up to date: %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
'
  if printf '%s' "$r" | grep -q '"just_installed": true' && [ "$UI_STATE" = "up" ] && \
     confirm "Restart the web UI so it runs the new version?" y; then
    exec bash "$FORGE_APP/selkies-cli" restart
  fi
}

# selkies-cli keeps itself current: at most once every 5 minutes it asks
# GitHub for a newer build, installs it, and reruns itself on the new code.
# FORGE_AUTO_UPDATE=0 turns this off.
auto_update_cli() {
  [ "${FORGE_AUTO_UPDATE:-1}" = 0 ] && return 0
  local r
  r=$(engine check-update --install --max-age 300 2>/dev/null) || return 0
  if printf '%s' "$r" | grep -q '"just_installed": true'; then
    local v
    v=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("installed_version") or "")' 2>/dev/null)
    ok "updated Selkies Forge to ${v:-the latest version}"
    FORGE_JUST_UPDATED=1 exec bash "$FORGE_APP/selkies-cli" "$@"
  fi
}

pick_new() {
  local choice
  choice=$(menu_choose "Forge a new desktop" \
    $'quick\tFrom the hand picked list\tone strong choice per taste' \
    $'smart\tLet it choose for me\tscored against this machine' \
    $'family\tBrowse by distro family\tUbuntu, Debian, Arch, Alpine, Kali...' \
    $'search\tSearch the catalog\tby name, desktop or tag' \
    $'back\tBack\t') || return 0
  case "$choice" in
    quick) pick_quick ;;
    smart) cmd_smart ;;
    family) pick_family ;;
    search) pick_search ;;
  esac
}

# Start the web UI when this machine boots? Asked once, the first time the
# web UI is started from an interactive terminal; `selkies-cli boot` changes it.
ask_boot_once() {
  [ -n "$TTY_IN" ] || return 0
  [ "${FORGE_BOOT:-0}" = 1 ] && return 0
  local b; b=$(engine boot status 2>/dev/null)
  printf '%s' "$b" | grep -q '"asked": true' && return 0
  printf '%s' "$b" | grep -q '"enabled": true' && return 0
  printf '\n'
  if confirm "Start the web UI automatically whenever this machine boots?" y; then
    cmd_boot on
  else
    engine boot asked >/dev/null 2>&1
    info "it will not start on boot; turn it on later with: ${B}selkies-cli boot on${NC}"
  fi
}

cmd_boot() {
  local act="${1:-status}"
  case "$act" in
    on|enable)
      [ -n "${UI_PORT:-}" ] || eval "$(status_vars "$(forge_status_json)")"
      local -a a=(boot enable --port "${UI_PORT:-$WEBUI_PORT}" --bind "${UI_BIND:-$WEBUI_BIND}")
      [ "${UI_EXPOSED:-0}" = 1 ] || [ "$WEBUI_EXPOSE" = 1 ] && a+=(--expose)
      local r; r=$(engine "${a[@]}" 2>&1)
      if ! printf '%s' "$r" | grep -q '"ok": true'; then
        bad "could not set that up: $(printf '%s' "$r" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")')"
        return 1
      fi
      local method; method=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method",""))')
      ok "the web UI will start by itself when this machine boots ($method)"
      if printf '%s' "$r" | grep -q '"needs"'; then
        warn "systemd only starts your services at boot once \"linger\" is on for your user"
        if confirm "Turn it on now? (runs: sudo loginctl enable-linger $USER)" y; then
          if run_root loginctl enable-linger "$USER"; then
            ok "linger is on: it now starts at boot, even before anyone logs in"
          else
            warn "that did not work; until it does, it starts when you log in"
          fi
        else
          info "until then it starts when you log in, not at boot"
        fi
      fi
      ;;
    off|disable)
      engine boot disable >/dev/null 2>&1 && ok "the web UI will no longer start on boot"
      ;;
    *)
      local r; r=$(engine boot status 2>/dev/null)
      if printf '%s' "$r" | grep -q '"enabled": true'; then
        ok "starts on boot ($(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method"))'))"
      else
        info "does not start on boot · turn it on with: selkies-cli boot on"
      fi
      ;;
  esac
}

# What the forge uses on disk, and tidying it up. Nothing a desktop uses is
# ever removed; images come back by themselves when you forge again.
cmd_clean() {
  title "Disk" "what the forge uses, and what it can give back"
  local r; r=$(engine space 2>/dev/null)
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def mb(x):
    x = float(x or 0)
    return "%.1f GB" % (x / 1024) if x >= 1024 else "%d MB" % x
g = d.get("groups") or {}
for key, label in (("layers", "forge layers"), ("built", "built desktops"),
                   ("pulled", "pulled desktops"), ("bases", "base images")):
    rows = g.get(key) or []
    unused = [r for r in rows if not r.get("in_use")]
    print("  %s %3d  %9s   %s" % (c("2", "%-16s" % label), len(rows),
          mb(sum(r["size_mb"] for r in rows)), c("2", "%s unused" % mb(sum(r["size_mb"] for r in unused)))))
print("  %s      %9s" % (c("2", "%-16s" % "build cache"), mb(d.get("build_cache_mb"))))
print("  %s %3d   %s" % (c("2", "%-16s" % "orphan volumes"), len(d.get("orphan_volumes") or []),
      c("2", "files of removed desktops you chose to keep")))
print()
print("  tidy up frees %s; removing everything unused frees %s" % (
    c("1", mb(d.get("reclaimable_mb"))), c("1", mb(d.get("reclaimable_all_mb")))))
'
  printf '\n'
  local act
  act=$(menu_choose "Clean up?" \
    $'tidy\tTidy up\told forge layers only; nothing to download again' \
    $'all\tRemove everything unused\tunused desktop images and the build cache' \
    $'vols\tAlso delete kept files\torphan volumes of removed desktops (cannot be undone)' \
    $'no\tLeave it\t') || return 0
  local -a a=(space --clean)
  case "$act" in
    tidy) : ;;
    all) a+=(--all) ;;
    vols) confirm "Delete the kept files of removed desktops for good?" n || return 0; a+=(--all --volumes) ;;
    *) return 0 ;;
  esac
  spin_start "cleaning up"
  r=$(engine "${a[@]}" 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print("  \u2714 removed %d images%s" % (len(d.get("removed_images") or []),
      ", %d volumes" % len(d["removed_volumes"]) if d.get("removed_volumes") else ""))
for k, v in (d.get("failed") or {}).items():
    print("  ! kept %s: %s" % (k, v[:80]))
'
}

# A desktop by its short name or its container name (forge-...).
resolve_desktop() {
  local n="$1"
  if docker inspect "$n" >/dev/null 2>&1; then printf '%s' "$n"
  elif docker inspect "forge-$n" >/dev/null 2>&1; then printf 'forge-%s' "$n"
  else printf '%s' "$n"; fi
}

cmd_backup() {
  [ -n "${1:-}" ] || die "usage: selkies-cli backup NAME"
  local n; n=$(resolve_desktop "$1")
  stream_job_view backup "Backing up $n" backup "$n"
}

cmd_backups() {
  title "Backups" "in $FORGE_HOME/backups; restore with: selkies-cli restore-backup NAME FILE"
  local -a a=(backups)
  [ -n "${1:-}" ] && a+=(--name "$(resolve_desktop "$1")")
  engine "${a[@]}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore_backup() {
  [ -n "${2:-}" ] || die "usage: selkies-cli restore-backup NAME FILE"
  local n; n=$(resolve_desktop "$1")
  confirm "Replace $n's files with $2? (a safety backup is taken first)" n || return 0
  stream_job_view restore "Restoring $n" restore-backup "$n" "$2"
}

cmd_clone() {
  [ -n "${1:-}" ] || die "usage: selkies-cli clone NAME [NEW-NAME]"
  local n; n=$(resolve_desktop "$1")
  local -a a=(clone "$n")
  [ -n "${2:-}" ] && a+=(--as "$2")
  stream_job_view clone "Cloning $n" "${a[@]}"
}

cmd_jobs() {
  title "Jobs" "launches, backups and clones, from the web UI and the terminal"
  engine jobs | sed 's/^/  /'
  printf '\n'
}

cmd_idle() {
  [ -n "${2:-}" ] || die "usage: selkies-cli idle NAME MINUTES|0|default"
  local n; n=$(resolve_desktop "$1")
  local r; r=$(engine idle "$n" "$2" 2>&1)
  if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
  elif [ "$2" = 0 ]; then ok "$n is never stopped for being idle"
  elif [ "$2" = default ]; then ok "$n follows the forge default (FORGE_IDLE_STOP_MIN)"
  else ok "$n stops after $2 minutes with nobody watching (needs the web UI running)"; fi
}

cmd_events() {
  title "What happened" "launches, crashes, heals and repairs, newest last"
  engine events --limit "${1:-40}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore() {
  spin_start "starting the desktops that were running before"
  local r; r=$(engine restore 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
for n in d.get("started") or []:
    print("  ✔ started " + n)
if not d.get("started"):
    print("  ! nothing needed starting")
'
}

main_menu() {
  review_autostart
  while :; do
    local js
    js=$(forge_status_json)
    eval "$(status_vars "$js")"
    render_status "$js"

    # Suggestions first: what you most likely want given what is running.
    # "Browse / forge a new desktop" always sits third, wherever the list starts.
    local -a items=()
    local newitem=$'new\tBrowse & forge a new desktop\tpick from 150+ desktops'
    [ "$TOTAL" -eq 0 ] && newitem=$'new\tBrowse & forge your first desktop\tpick from 150+ desktops'
    if [ "$DOCKER_OK" != 1 ]; then
      items+=($'doctor\tFind out why Docker is not answering\tchecks docker, memory, disk')
    fi
    if [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ]; then
      local why="they were running before it stopped"
      case "$LAST_REASON" in
        host-reboot) why="they were running before the reboot" ;;
        host-shutdown) why="they were running before the shutdown" ;;
        host-crash) why="they were running before the machine went down" ;;
      esac
      items+=("restore"$'\t'"Start the $RESTORE_N desktop(s) again"$'\t'"$why")
    fi
    case "$UI_STATE" in
      up)
        [ "$UI_RESTART" = 1 ] && items+=($'uirestart\tRestart the web UI\ta new version is installed')
        items+=("open"$'\t'"Open the web UI"$'\t'"running at $UI_URL")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops"$'\t'"$RUNNING running, $STOPPED stopped")
        items+=($'uistop\tStop the web UI\tyour desktops keep running')
        [ "$UI_RESTART" = 1 ] || items+=($'uirestart\tRestart the web UI\tafter an update, or if it misbehaves')
        ;;
      stale)
        items+=($'uistart\tStart the web UI again\tit stopped unexpectedly')
        items+=($'uilog\tShow why it stopped\tlast lines of its log')
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        ;;
      *)
        local hint="browse everything with screenshots"
        [ "$TOTAL" -gt 0 ] && hint="manage your $TOTAL desktop(s) in the browser"
        case "$LAST_REASON" in
          crash|oom|error|host-crash) hint="it stopped unexpectedly last time" ;;
        esac
        items+=("uistart"$'\t'"Start the web UI"$'\t'"$hint")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        case "$LAST_REASON" in
          crash|oom|error) items+=($'uilog\tShow why it stopped\tlast lines of its log') ;;
        esac
        ;;
    esac
    # Slot the browse entry in as the third choice (or last, if the list is shorter).
    if [ "${#items[@]}" -ge 2 ]; then
      items=("${items[@]:0:2}" "$newitem" "${items[@]:2}")
    else
      items+=("$newitem")
    fi
    if [ "$BOOT_ON" = 1 ]; then
      items+=($'bootoff\tStop starting the web UI on boot\tit currently starts by itself')
    else
      items+=($'booton\tStart the web UI on boot\tcomes back by itself after a reboot')
    fi
    [ "$DOCKER_OK" = 1 ] && items+=($'doctor\tCheck this machine\tdocker, memory, disk, tunnels')
    [ "$DOCKER_OK" = 1 ] && items+=($'clean\tFree up disk space\tunused images, old layers, build cache')
    items+=($'update\tUpdate Selkies Forge\tget the latest version from GitHub')
    [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ] && \
      items+=($'dismiss\tForget about the last stop\tstop suggesting the restart')
    items+=($'quit\tQuit\t')

    local choice
    choice=$(menu_choose "What would you like to do?" "${items[@]}") || { printf '\n'; return 0; }
    case "$choice" in
      open) cmd_open; return 0 ;;
      uistart) FORGE_FROM_MENU=1 cmd_webui ;;
      uistop) cmd_stop ;;
      uirestart) cmd_restart ;;
      uilog) cmd_ui_log ;;
      manager) cmd_manager ;;
      new) pick_new ;;
      restore) cmd_restore ;;
      dismiss) engine dismiss-last-stop >/dev/null 2>&1; ok "ok, it will not ask again" ;;
      booton) cmd_boot on ;;
      bootoff) cmd_boot off ;;
      doctor) cmd_doctor ;;
      clean) cmd_clean ;;
      update) cmd_update ;;
      quit|"") printf '\n  %sbye%s\n\n' "$DIM" "$NC"; return 0 ;;
    esac
  done
}

usage() {
  banner
  cat <<USAGE
Usage:
   $FORGE_RUN              interactive menu
   $FORGE_RUN --webui      straight to the web UI
   $FORGE_RUN --bg         web UI in the background, shell back
   $FORGE_RUN --fg         web UI in the foreground until ctrl-c
   $FORGE_RUN --stop       stop a backgrounded web UI
   $FORGE_RUN --cli        straight to the terminal picker
   $FORGE_RUN --smart      let it choose for this machine
   $FORGE_RUN --launch ID  forge one entry and exit
   $FORGE_RUN --list       print the catalog
   $FORGE_RUN --manager    manage running desktops
   $FORGE_RUN --doctor     check this machine
   $FORGE_RUN --uninstall  remove everything it created

After the first run:
   selkies-cli                     home screen: what is running, what to do next
   selkies-cli status              one-shot status of the web UI and desktops
   selkies-cli start | stop        web UI in the background, or stop it
   selkies-cli restart | open      restart it, or print/open its link
   selkies-cli manager | new       manage desktops, or forge a new one
   selkies-cli update              install the latest version from GitHub
   selkies-cli boot on | off       start the web UI by itself when the machine boots
   selkies-cli restore             start the desktops that were running before a reboot
   selkies-cli events              what happened: launches, crashes, heals, repairs
   selkies-cli clean               see and free the disk the forge uses
   selkies-cli jobs                launches, backups and clones in progress or recent
   selkies-cli backup NAME         back up a desktop's files (its home folder)
   selkies-cli backups [NAME]      list backups
   selkies-cli restore-backup NAME FILE   put a backup's files back (safety copy first)
   selkies-cli clone NAME [NEW]    a second desktop with a copy of its files
   selkies-cli idle NAME MIN       stop it after MIN minutes unwatched (0 = never)

Options:
   --port N       web UI port (default 8787, the next free one if taken)
   --expose       serve the web UI beyond localhost (no access control)
   --no-tunnel    skip the public serveo link
   --yes, -y      accept the install prompts (Python, Docker)

USAGE
}

# =========================================================================
#  entry point
# =========================================================================

main() {
  local MODE="menu" LAUNCH_ID="" BOOT_ACT="" EXTRACT_TO=""
  local -a ORIG_ARGS=("$@")
  # Verbs that take desktop names: run them straight after the usual setup.
  case "${1:-}" in
    backup|backups|restore-backup|clone|jobs|idle)
      local verb="$1"; shift
      ensure_dirs; preflight; extract_payload
      case "$verb" in
        backup) cmd_backup "$@" ;;
        backups) cmd_backups "$@" ;;
        restore-backup) cmd_restore_backup "$@" ;;
        clone) cmd_clone "$@" ;;
        jobs) cmd_jobs ;;
        idle) cmd_idle "$@" ;;
      esac
      exit $?
      ;;
  esac
  # Plain words for the common things: selkies-cli status, selkies-cli stop...
  case "${1:-}" in
    status|start|stop|restart|open|update|setup|manager|doctor|list|new|uninstall|help|boot|restore|clean|events)
      local verb="$1"; shift
      case "$verb" in
        start) set -- --bg "$@" ;;
        new) set -- --cli "$@" ;;
        help) set -- --help "$@" ;;
        boot) BOOT_ACT="${1:-status}"; [ $# -gt 0 ] && shift; set -- --boot "$@" ;;
        restore) set -- --restore "$@" ;;
        clean) set -- --clean "$@" ;;
        events) set -- --events "$@" ;;
        *) set -- "--$verb" "$@" ;;
      esac
      ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) MODE="status" ;;
      --boot) MODE="boot" ;;
      --restore) MODE="restore" ;;
      --clean) MODE="clean" ;;
      --events) MODE="events" ;;
      --restart) MODE="restart" ;;
      --open) MODE="open" ;;
      --update) MODE="update" ;;
      --setup) MODE="setup" ;;
      --webui|-w) MODE="webui" ;;
      --cli|-c) MODE="cli" ;;
      --smart|-s) MODE="smart" ;;
      --manager|-m) MODE="manager" ;;
      --doctor) MODE="doctor" ;;
      --list|-l) MODE="list" ;;
      --launch) MODE="launch"; LAUNCH_ID="${2:-}"; shift ;;
      --uninstall) MODE="uninstall" ;;
      --port) WEBUI_PORT="${2:-8787}"; WEBUI_PORT_SET=1; shift ;;
      --bind) WEBUI_BIND="${2:-127.0.0.1}"; shift ;;
      --expose) WEBUI_EXPOSE=1; WEBUI_BIND="0.0.0.0" ;;
      --bg) MODE="webui"; WEBUI_MODE="bg" ;;
      --fg) MODE="webui"; WEBUI_MODE="fg" ;;
      --stop) MODE="stop" ;;
      --no-tunnel) NO_TUNNEL=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --force-extract) FORCE_EXTRACT=1 ;;
      --version|-V) printf 'selkies-forge %s\n' "$FORGE_VERSION"; exit 0 ;;
      --extract-only) MODE="extract"; EXTRACT_TO="${2:-}"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done

  # Unpack the engine and web UI somewhere and stop: no installs, no checks.
  # build.py uses this for its self-test; packagers can use it too.
  if [ "$MODE" = extract ]; then
    [ -n "$EXTRACT_TO" ] || die "--extract-only needs a directory"
    mkdir -p "$EXTRACT_TO" || die "cannot create $EXTRACT_TO"
    FORGE_APP="$(cd "$EXTRACT_TO" && pwd)"
    FORCE_EXTRACT=1 extract_payload
    printf '%s\n' "$FORGE_APP"
    exit 0
  fi

  ensure_dirs
  case "$MODE" in
    uninstall|status|boot|events) : ;;
    *) banner ;;
  esac

  preflight
  extract_payload
  install_cli || true
  if [ "$FORGE_AS_CLI" = 1 ] && [ "${FORGE_JUST_UPDATED:-0}" != 1 ]; then
    case "$MODE" in
      update|uninstall|setup) : ;;
      *) auto_update_cli ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} ;;
    esac
  fi

  case "$MODE" in
    setup)
      announce_cli
      printf '\n'
      ok "Selkies Forge $FORGE_VERSION is ready"
      info "run ${B}${FORGE_RUN}${NC} any time to see what is running and pick what to do"
      printf '\n'
      exit 0
      ;;
    status) cmd_status; exit 0 ;;
    boot) cmd_boot "${BOOT_ACT:-status}"; exit $? ;;
    restore) cmd_restore; exit 0 ;;
    clean) cmd_clean; exit 0 ;;
    events) cmd_events; exit 0 ;;
    open) cmd_open; exit 0 ;;
    restart) cmd_restart; exit $? ;;
    update) cmd_update; exit 0 ;;
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

  announce_cli
  case "$MODE" in
    webui) singleton_check ;;
  esac

  case "$MODE" in
    webui) cmd_webui ;;
    cli) pick_quick ;;
    smart) cmd_smart ;;
    manager) cmd_manager ;;
    *) main_menu ;;
  esac
}

main "$@"
__FORGE_FILE_SELKIES_CLI__
  chmod 755 "$FORGE_APP/selkies-cli" "$FORGE_APP/engine.py" 2>/dev/null
  if command -v sha256sum >/dev/null 2>&1; then
    local bad=0 f var
    for f in $FORGE_PAYLOAD_FILES; do
      var="FORGE_SHA_$(printf '%s' "$f" | tr -c 'A-Za-z0-9\n' '_' | tr '[:lower:]' '[:upper:]')"
      if [ "$(sha256sum "$FORGE_APP/$f" | cut -d' ' -f1)" != "${!var}" ]; then
        bad=1
        printf '  %s!%s %s did not extract cleanly\n' "$YEL" "$NC" "$f"
      fi
    done
    [ "$bad" = 1 ] && die "the embedded payload is damaged; re-download this script"
  fi
  # Files an older version shipped that this one does not (the engine used to
  # be a single engine.py). Only inside the forge's own app directory.
  if [ "$FORGE_APP" = "$FORGE_HOME/app" ]; then
    local keep=" $FORGE_PAYLOAD_FILES " rel
    while IFS= read -r f; do
      rel="${f#"$FORGE_APP"/}"
      case "$keep" in *" $rel "*) ;; *) rm -f -- "$f" ;; esac
    done < <(find "$FORGE_APP" -type f ! -name .payload ! -path '*/__pycache__/*' 2>/dev/null)
    find "$FORGE_APP" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
    find "$FORGE_APP" -mindepth 1 -type d -empty -delete 2>/dev/null
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
sess = d.get("session") or {}
if sess.get("wm"):
    rows.insert(0, ("desktop", "%s is up" % sess["wm"],
                    "screen " + ("follows your window" if d.get("display") == "fit"
                                 else (d.get("display") or "") + ", scaled to fit")))
print()
if d.get("warning"):
    print("  " + c("1;38;5;221", "▰ STARTED, WITH A PROBLEM") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
else:
    print("  " + c("1;38;5;79", "▰ READY") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
print("  " + c("2", "─" * 66))
if d.get("warning"):
    import textwrap
    for ln in textwrap.wrap(d["warning"], 70):
        print("  " + c("38;5;221", ln))
    for ln in ((sess.get("log") or "").strip().splitlines()[-8:]):
        print("    " + c("2", ln[:100]))
    print("  " + c("2", "─" * 66))
fx = {"memory": "gave it more memory", "shm": "more shared memory", "seccomp": "relaxed seccomp",
      "slow": "waited longer for a slow first boot", "restart": "restarted it once"}
if d.get("fixes"):
    print("  %s %s" % (c("38;5;79", "\u2714 fixed on the way:"), ", ".join(fx.get(f, f) for f in d["fixes"])))
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
  stream_job_view launch "Forging $id" launch "$id" "$@"
}

# Run an engine command that streams a job (launch, clone, backup, restore)
# and draw it: a progress bar, the log scrolling above it, then the result.
# Ctrl-C reaches the engine, which cancels the job and cleans up.
stream_job_view() {
  local kind="$1" heading="$2"; shift 2
  local -a eargs=("$@")
  local pct=0 phase="working" result="" failed=0
  local log="$FORGE_LOGS/$kind-$(date +%Y%m%d-%H%M%S).log"

  title "$heading" "live output below, full log at $log"
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
  done < <(engine "${eargs[@]}" 2>&1)

  printf '%s%s' "$CLRL" "$SHOW"
  if [ -n "$result" ]; then
    case "$kind" in
      launch|clone) FORGE_COLOR=$COLOR render_result "$result" ;;
      *) printf '%s' "$result" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
b = d.get("backup") or {}
if b:
    print("  \u2714 backed up %s: %s (%.1f MB)" % (d.get("name"), b.get("file"), (b.get("size") or 0) / 1048576.0))
elif d.get("safety"):
    print("  \u2714 restored %s from %s" % (d.get("name"), d.get("file")))
    print("    the files from before are kept in %s" % d["safety"])
else:
    print("  \u2714 done")
' ;;
    esac
    printf '\n'
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
print("E_PROFILE='%s'" % q(d["profile"]))
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

  local disk_gb=$((P_DISK / 1024))
  if confirm "Use the suggested resources (${P_MEM} MB RAM, ${P_CPU} cores, ${disk_gb} GB storage)?" y; then
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

  # Sign-in. Without this anyone who reaches the URL is already inside.
  local want_auth=n
  [ "$E_PROFILE" = "kasm" ] && want_auth=y
  if confirm "Set a username and password for this desktop?" "$want_auth"; then
    local u pw
    if [ "$E_PROFILE" = "kasm" ]; then
      u="kasm_user"
      info "this image always signs you in as kasm_user"
    else
      u=$(ask "username" "forge")
    fi
    pw=$(ask "password (blank generates one)" "")
    if [ -z "$pw" ]; then
      pw=$("$PY" -c "import secrets,string
a = string.ascii_letters + string.digits
print(''.join(secrets.choice(a) for _ in range(16)))")
      info "generated password: $pw"
      warn "write it down, it is set inside the container and cannot be read back"
    fi
    args+=(--user "$u" --password "$pw")
  fi
  if [ "$NO_TUNNEL" = 1 ]; then
    args+=(--no-tunnel)
  elif ! confirm "Open a public serveo tunnel?" y; then
    args+=(--no-tunnel)
  fi
  if confirm "Start it automatically whenever Docker starts (after a reboot)?" n; then
    args+=(--autostart)
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
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
        ;;
      *)
        local act
        act=$(menu_choose "$pick" \
          $'open\tShow its links\tlocal and tunnel URLs' \
          $'shell\tOpen a shell in it\tdocker exec' \
          $'tunnel\tOpen or replace the tunnel\tfresh serveo URL' \
          $'untunnel\tDrop the tunnel\tkeep it local only' \
          $'limits\tChange limits\tmemory, cpu, shared memory, storage' \
          $'autostart\tToggle auto-start\tcome back after a reboot, or not' \
          $'restart\tRestart it\t' \
          $'stop\tStop it\t' \
          $'start\tStart it\t' \
          $'logs\tShow recent logs\tlast 120 lines' \
          $'events\tWhat happened to it\tlaunches, crashes, heals, repairs' \
          $'backup\tBack up its files\ta copy of its home folder' \
          $'clone\tClone it\ta second desktop with a copy of its files' \
          $'idle\tStop it when idle\twhen nobody has had it open for a while' \
          $'repair\tRepair it\trecreate on the newest forge layer; files are kept' \
          $'remove\tRemove it\tasks about the data volume too' \
          $'back\tBack\t') || continue
        case "$act" in
          back|"") : ;;
          open) print_instances ;;
          shell)
            printf '\n'; info "handing you a shell inside $pick, type exit to come back"; printf '\n'
            if [ -z "$TTY_IN" ]; then
              warn "a shell needs a terminal; run this script from one"
            else
              docker exec -it "$pick" /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash -l; else exec /bin/sh -l; fi' <"$TTY_IN"
            fi
            ;;
          logs) engine logs "$pick" --tail 120 | sed 's/^/    /' ;;
          events) engine events --name "$pick" --limit 30 | sed 's/^/    /' ;;
          backup) cmd_backup "$pick" ;;
          clone) cmd_clone "$pick" "$(ask "name for the copy" "${pick#forge-}-copy")" ;;
          idle) cmd_idle "$pick" "$(ask "minutes with nobody watching (0 = never)" "60")" ;;
          limits)
            local cur; cur=$(engine instances 2>/dev/null | "$PY" -c "
import json,sys
for i in json.load(sys.stdin)['instances']:
    if i['name']=='$pick':
        l=i.get('limits') or {}
        print(l.get('memory_mb') or 1024, l.get('cpus') or 1, l.get('shm_mb') or 256, i.get('disk_cap_mb') or 10240)")
            local cm cc cs cd nm nc ns nd
            read -r cm cc cs cd <<<"$cur"
            nm=$(ask "memory in MB" "$cm"); nc=$(ask "cpu cores" "$cc")
            ns=$(ask "shared memory in MB (browsers want 512+)" "$cs"); nd=$(ask "storage in MB" "$cd")
            if [ "$ns" != "$cs" ] || [ "$nd" != "$cd" ]; then
              info "shared memory and storage need the desktop recreated; files in /config are kept"
            fi
            spin_start "applying limits to $pick"
            local r; r=$(engine retune "$pick" --memory "$nm" --cpus "$nc" --shm "$ns" --disk "$nd" 2>&1)
            spin_stop
            if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
            elif printf '%s' "$r" | grep -q '"recreated": true'; then ok "recreated $pick with the new limits"
            else ok "limits applied live"; fi
            ;;
          autostart)
            local now; now=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$pick" 2>/dev/null)
            if [ "$now" = "no" ] || [ -z "$now" ]; then
              engine retune "$pick" --autostart on >/dev/null && ok "$pick now starts with Docker"
            else
              engine retune "$pick" --autostart off >/dev/null && ok "$pick only starts when you start it"
            fi
            ;;
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
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
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
    warn "this exposes docker control beyond localhost; anyone who can reach it controls docker"
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

  ask_boot_once

  # Background, or hold the terminal until ctrl-c?
  local mode="$WEBUI_MODE"
  if [ -z "$mode" ]; then
    if [ -n "$TTY_IN" ]; then
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
    info "open:          $srv_url"
    info "stop it with:  $FORGE_RUN --stop"
    info "           or:  kill $srv_pid"
    info "log:           $log"
    printf '\n  %syour shell is back · the forge menu has exited so the prompt is yours%s\n\n' \
      "$DIM" "$NC"
    # Leaving the menu running would just redraw it over the shell we were
    # asked to hand back, which looks like the whole thing restarted.
    exit 0
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
    engine stop-request ctrl-c >/dev/null 2>&1
    kill "$srv_pid" 2>/dev/null
    printf '\n'
    ok "web UI stopped"
  else
    warn "the web UI exited on its own, see $log"
  fi
  [ "$FORGE_FROM_MENU" = 1 ] && printf '  %sback to the forge menu%s\n' "$DIM" "$NC"
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
    # Tell it why, so the next start can say "you stopped it" rather than guess.
    engine stop-request "${FORGE_STOP_REASON:-user}" >/dev/null 2>&1
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
  local cli; cli=$(cat "$FORGE_STATE/cli-path" 2>/dev/null)
  if [ -n "$cli" ] && grep -q 'Installed by docker.sh' "$cli" 2>/dev/null; then
    rm -f "$cli" && ok "removed the selkies-cli command ($cli)"
  fi
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null; then
      sed -i '/# >>> selkies-forge >>>/,/# <<< selkies-forge <<</d' "$rc" && ok "cleaned the PATH line from $rc"
    fi
  done
  engine boot disable >/dev/null 2>&1
  rm -rf "$FORGE_HOME"
  ok "removed $FORGE_HOME"
  printf '\n  %sthanks for using the forge%s\n\n' "$DIM" "$NC"
}

# =========================================================================
#  main menu
# =========================================================================

# Older versions created every desktop with --restart unless-stopped, so they
# all came back whenever Docker or the machine restarted. Offer to undo that once.
review_autostart() {
  local marker="$FORGE_STATE/autostart-reviewed"
  [ -f "$marker" ] && return 0
  local names
  names=$(docker ps -a --filter "label=io.selkiesforge.entry" \
    --format '{{.Names}}' 2>/dev/null | while read -r n; do
      [ -n "$n" ] || continue
      p=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)
      [ "$p" != "no" ] && [ -n "$p" ] && printf '%s ' "$n"
    done)
  if [ -z "$names" ]; then touch "$marker"; return 0; fi
  title "Desktops that start on their own" "these come back every time Docker or this machine restarts"
  for n in $names; do info "$n"; done
  if confirm "Stop them starting automatically? (you can turn it back on per desktop)" y; then
    for n in $names; do docker update --restart no "$n" >/dev/null 2>&1 && ok "$n: auto-start off"; done
  else
    info "left as they are; change any of them later in the manager"
  fi
  # Only remember the question once it has actually been answered.
  touch "$marker"
}

# =========================================================================
#  the selkies-cli command
# =========================================================================

# A small wrapper on your PATH that runs the copy of this front end unpacked
# next to the engine. That copy exists even after "curl ... | bash", where no
# copy of this script is ever saved to disk.
cli_bin_dir() {
  if [ -n "${FORGE_BIN_DIR:-}" ]; then printf '%s' "$FORGE_BIN_DIR"; return; fi
  local d
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in
      *":$d:"*) if [ -d "$d" ] && [ -w "$d" ]; then printf '%s' "$d"; return; fi ;;
    esac
  done
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then printf '%s' /usr/local/bin; return; fi
  printf '%s' "$HOME/.local/bin"
}

add_path_to_rc() {
  local dir="$1" rc added=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ] || continue
    grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null && continue
    {
      printf '\n# >>> selkies-forge >>>\n'
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$dir" "$dir"
      printf '# <<< selkies-forge <<<\n'
    } >>"$rc" 2>/dev/null && added=1
  done
  [ "$added" = 1 ] && CLI_RC_ADDED=1
  return 0
}

install_cli() {
  local dir target body
  dir=$(cli_bin_dir)
  target="$dir/selkies-cli"
  body="#!/usr/bin/env bash
# selkies-cli: brings Selkies Forge back up. Installed by docker.sh.
export FORGE_HOME=\"\${FORGE_HOME:-$FORGE_HOME}\"
if [ ! -f \"\$FORGE_HOME/app/selkies-cli\" ]; then
  echo \"selkies-cli: Selkies Forge is no longer installed in \$FORGE_HOME.\" >&2
  echo \"Reinstall it with: curl -fsSL $FORGE_URL | bash\" >&2
  exit 1
fi
exec bash \"\$FORGE_HOME/app/selkies-cli\" \"\$@\""

  if [ -e "$target" ] && ! grep -q 'Installed by docker.sh' "$target" 2>/dev/null; then
    warn "$target already exists and is not ours, so selkies-cli was not installed"
    return 1
  fi
  # The command belongs to whichever install made it. A second install in
  # another FORGE_HOME (a test copy, say) must not quietly take it over;
  # it only does if that other install is gone, or you named the folder.
  if [ -f "$target" ] && [ -z "${FORGE_BIN_DIR:-}" ]; then
    local other
    other=$(sed -n 's/^export FORGE_HOME="\${FORGE_HOME:-\(.*\)}"$/\1/p' "$target" 2>/dev/null)
    if [ -n "$other" ] && [ "$other" != "$FORGE_HOME" ] && [ -f "$other/app/selkies-cli" ]; then
      CLI_PATH="$FORGE_APP/selkies-cli"
      FORGE_RUN="bash $CLI_PATH"
      return 0
    fi
  fi
  if [ -f "$target" ] && [ "$(cat "$target")" = "$body" ]; then
    CLI_PATH="$target"
  else
    mkdir -p "$dir" 2>/dev/null
    if ! printf '%s\n' "$body" >"$target" 2>/dev/null; then
      warn "could not write $target, so selkies-cli was not installed"
      return 1
    fi
    chmod 755 "$target"
    CLI_PATH="$target"
    CLI_NEW=1
  fi
  printf '%s' "$CLI_PATH" >"$FORGE_STATE/cli-path"
  case ":$PATH:" in
    *":$dir:"*) FORGE_RUN="selkies-cli" ;;
    *)
      # A directory you picked yourself (FORGE_BIN_DIR) is your business;
      # only the default location gets a PATH line in your shell profile.
      [ -z "${FORGE_BIN_DIR:-}" ] && add_path_to_rc "$dir"
      FORGE_RUN="$CLI_PATH"
      ;;
  esac
  return 0
}

announce_cli() {
  [ "$CLI_NEW" = 1 ] || return 0
  printf '\n'
  ok "installed ${B}selkies-cli${NC}: run it from any terminal to come back here"
  if [ "$CLI_RC_ADDED" = 1 ]; then
    info "added $(dirname "$CLI_PATH") to your PATH in your shell profile;"
    info "open a new terminal first, or run:  export PATH=\"$(dirname "$CLI_PATH"):\$PATH\""
  fi
}

# Quiet when everything is already in place, which is the normal case for
# selkies-cli; the full installers only speak up when something is missing.
preflight() {
  if [ "$FORGE_AS_CLI" = 1 ] && find_python && docker_usable; then
    return 0
  fi
  install_python
  install_docker
  install_extras
}

# =========================================================================
#  status + home screen
# =========================================================================

forge_status_json() { engine status 2>/dev/null || printf '{}'; }

# Turns the status JSON into shell variables the menu can branch on.
status_vars() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
w = d.get("webui") or {}
def q(v): return "'" + str(v if v is not None else "").replace("'", "") + "'"
print("UI_STATE=" + q(w.get("state", "down")))
print("UI_URL=" + q(w.get("url", "")))
print("UI_PID=" + q(w.get("pid", "")))
print("UI_PORT=" + q(w.get("port", "")))
print("UI_BIND=" + q(w.get("bind", "")))
print("UI_EXPOSED=" + q(1 if w.get("tunnel") else 0))
print("UI_RESTART=" + q(1 if w.get("restart_needed") else 0))
print("UI_LOG=" + q(w.get("log", "")))
print("DOCKER_OK=" + q(1 if d.get("docker") else 0))
print("RUNNING=" + q(d.get("running", 0)))
print("STOPPED=" + q(d.get("stopped", 0)))
print("TOTAL=" + q(len(d.get("desktops") or [])))
ls = d.get("last_stop") or {}
print("LAST_REASON=" + q(ls.get("reason", "")))
print("LAST_CLEAN=" + q(1 if ls.get("clean") else 0))
print("LAST_DISMISSED=" + q(1 if ls.get("dismissed") else 0))
print("RESTORE_N=" + q(len(ls.get("restore") or [])))
b = d.get("boot") or {}
print("BOOT_ON=" + q(1 if b.get("enabled") else 0))
print("BOOT_ASKED=" + q(1 if b.get("asked") else 0))
print("BOOT_METHOD=" + q(b.get("method") or ""))
print("BOOT_LINGER=" + q("" if b.get("linger") is None else (1 if b.get("linger") else 0)))
PYEOF
}

render_status() {
  FORGE_COLOR=$COLOR "$PY" - "$1" <<'PYEOF'
import json, os, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def dur(s):
    s = int(s or 0)
    if s < 60: return "%ds" % s
    if s < 3600: return "%dm" % (s // 60)
    if s < 86400: return "%dh %dm" % (s // 3600, s % 3600 // 60)
    return "%dd %dh" % (s // 86400, s % 86400 // 3600)
def short(url):
    if not url: return ""
    host = url.split("://", 1)[-1].split("/")[0]
    head, _, tail = host.partition(".")
    return (head[:8] + "…." + tail) if len(head) > 10 and tail else host

w = d.get("webui") or {}
st = w.get("state", "down")
print()
print("  " + c("1;38;5;255", "Status"))
print("  " + c("2", "─" * 64))
if not d.get("docker", True):
    print("  %s %s  %s" % (c("2", "%-9s" % "Docker"), c("38;5;203", "!"),
                           c("38;5;203", "not answering: " + str(d.get("docker_error") or "")[:60])))
if st == "up":
    print("  %s %s  running at %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;79", "●"),
          c("1;38;5;75", w.get("url", "")), c("2", "· up " + dur(w.get("uptime_s")))))
    if w.get("restart_needed"):
        print("  %s %s  %s" % (c("2", "%-9s" % "Update"), c("38;5;141", "\u2726"),
              "a new version is installed; restart the web UI to use it"))
elif st == "stale":
    print("  %s %s  %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;221", "!"),
          c("38;5;221", "stopped unexpectedly"), c("2", "· " + (w.get("why") or ""))))
else:
    print("  %s %s  %s" % (c("2", "%-9s" % "Web UI"), c("2", "○"), "not running"))

import time as _t
def when(ts):
    if not ts: return ""
    ago = _t.time() - float(ts)
    stamp = _t.strftime("%H:%M", _t.localtime(float(ts))) if ago < 86400 else \
        _t.strftime("%a %d %b %H:%M", _t.localtime(float(ts)))
    return "%s, %s ago" % (stamp, dur(ago))
ls = d.get("last_stop") or {}
if ls and not ls.get("dismissed"):
    clean = ls.get("clean")
    col = "38;5;79" if clean else ("38;5;203" if ls.get("reason") in ("host-crash", "crash", "oom", "error") else "38;5;221")
    head = "Last time" if st == "up" else "Stopped"
    print("  %s %s  %s  %s" % (c("2", "%-9s" % head), c(col, "●" if clean else "!"),
          ls.get("label", ""), c("2", "· " + when(ls.get("at") or ls.get("last_seen")))))
    if ls.get("boot_changed") and ls.get("boot_time"):
        print("  %s    %s" % (" " * 9, c("2", "machine up since " + _t.strftime("%a %H:%M", _t.localtime(ls["boot_time"])))))
    if ls.get("detail") and not clean and ls.get("reason") != "host-crash":
        print("  %s    %s" % (" " * 9, c("2", str(ls["detail"])[:70])))
    if ls.get("restore"):
        n = len(ls["restore"])
        print("  %s    %s" % (" " * 9, c("38;5;221", "%d desktop%s that %s running then %s stopped now" % (
            n, "" if n == 1 else "s", "was" if n == 1 else "were", "is" if n == 1 else "are"))))
b = d.get("boot") or {}
if b.get("enabled"):
    extra = ""
    if b.get("method") == "systemd" and b.get("linger") is False:
        extra = c("38;5;221", " · only after you log in (linger is off)")
    print("  %s %s  %s%s" % (c("2", "%-9s" % "On boot"), c("38;5;79", "●"),
          "the web UI starts by itself (%s)" % b.get("method"), extra))

items = d.get("desktops") or []
run, stop = d.get("running", 0), d.get("stopped", 0)
if not items:
    print("  %s %s  %s" % (c("2", "%-9s" % "Desktops"), c("2", "○"), "none yet"))
else:
    print("  %s %s  %d running · %d stopped" % (c("2", "%-9s" % "Desktops"),
          c("38;5;79", "●") if run else c("2", "○"), run, stop))
    for i in sorted(items, key=lambda x: (not x["running"], x["title"]))[:6]:
        dot = c("38;5;79", "●") if i["running"] else c("2", "○")
        where = i.get("local_url") or "" if i["running"] else c("2", "stopped")
        pub = (c("2", "  public ") + short(i["public_url"])) if i.get("public_url") else ""
        print("     %s %-22.22s %s%s" % (dot, i["title"], where.replace("http://", ""), pub))
    if len(items) > 6:
        print("     " + c("2", "and %d more" % (len(items) - 6)))
print("  " + c("2", "─" * 64))
PYEOF
}

cmd_status() {
  local js; js=$(forge_status_json)
  render_status "$js"
  printf '\n'
}

cmd_open() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  if [ "$UI_STATE" != "up" ]; then
    warn "the web UI is not running"
    if confirm "Start it in the background now?" y; then
      WEBUI_MODE="bg" cmd_webui
    fi
    return 0
  fi
  printf '\n  %s%s%s\n\n' "$B$BLU" "$UI_URL" "$NC"
  if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$UI_URL" >/dev/null 2>&1 &
    ok "opened in your browser"
  else
    info "open that link in your browser"
  fi
  printf '\n'
}

cmd_restart() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  # Come back on the same address, unless you asked for a different one.
  if [ -n "$UI_PORT" ] && [ "$WEBUI_PORT_SET" != 1 ]; then WEBUI_PORT="$UI_PORT"; fi
  if [ -n "$UI_BIND" ] && [ "$WEBUI_BIND" = "127.0.0.1" ]; then WEBUI_BIND="$UI_BIND"; fi
  [ "$UI_EXPOSED" = 1 ] && WEBUI_EXPOSE=1
  [ "$UI_STATE" = "down" ] || FORGE_STOP_REASON="${FORGE_STOP_REASON:-restart}" cmd_stop >/dev/null 2>&1
  WEBUI_MODE="${WEBUI_MODE:-bg}" cmd_webui
}

cmd_ui_log() {
  local log="$FORGE_LOGS/webui.log"
  title "Web UI log" "$log"
  if [ -s "$log" ]; then tail -n 25 "$log" | sed 's/^/    /'; else info "the log is empty"; fi
  [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
}

cmd_update() {
  title "Update" "git pull from GitHub, fast-forward only"
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  spin_start "checking GitHub"
  local r
  r=$(engine check-update --install 2>/dev/null)
  spin_stop
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
via = "git pull" if d.get("method") == "git" else "download"
commit = (d.get("installed_commit") or d.get("remote_commit") or "")[:7]
tag = c("2", "(" + via + (", " + commit if commit else "") + ")")
if d.get("just_installed"):
    print("  %s updated to %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
elif d.get("error"):
    print("  %s %s" % (c("38;5;221", "!"), d["error"]))
else:
    print("  %s already up to date: %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
'
  if printf '%s' "$r" | grep -q '"just_installed": true' && [ "$UI_STATE" = "up" ] && \
     confirm "Restart the web UI so it runs the new version?" y; then
    exec bash "$FORGE_APP/selkies-cli" restart
  fi
}

# selkies-cli keeps itself current: at most once every 5 minutes it asks
# GitHub for a newer build, installs it, and reruns itself on the new code.
# FORGE_AUTO_UPDATE=0 turns this off.
auto_update_cli() {
  [ "${FORGE_AUTO_UPDATE:-1}" = 0 ] && return 0
  local r
  r=$(engine check-update --install --max-age 300 2>/dev/null) || return 0
  if printf '%s' "$r" | grep -q '"just_installed": true'; then
    local v
    v=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("installed_version") or "")' 2>/dev/null)
    ok "updated Selkies Forge to ${v:-the latest version}"
    FORGE_JUST_UPDATED=1 exec bash "$FORGE_APP/selkies-cli" "$@"
  fi
}

pick_new() {
  local choice
  choice=$(menu_choose "Forge a new desktop" \
    $'quick\tFrom the hand picked list\tone strong choice per taste' \
    $'smart\tLet it choose for me\tscored against this machine' \
    $'family\tBrowse by distro family\tUbuntu, Debian, Arch, Alpine, Kali...' \
    $'search\tSearch the catalog\tby name, desktop or tag' \
    $'back\tBack\t') || return 0
  case "$choice" in
    quick) pick_quick ;;
    smart) cmd_smart ;;
    family) pick_family ;;
    search) pick_search ;;
  esac
}

# Start the web UI when this machine boots? Asked once, the first time the
# web UI is started from an interactive terminal; `selkies-cli boot` changes it.
ask_boot_once() {
  [ -n "$TTY_IN" ] || return 0
  [ "${FORGE_BOOT:-0}" = 1 ] && return 0
  local b; b=$(engine boot status 2>/dev/null)
  printf '%s' "$b" | grep -q '"asked": true' && return 0
  printf '%s' "$b" | grep -q '"enabled": true' && return 0
  printf '\n'
  if confirm "Start the web UI automatically whenever this machine boots?" y; then
    cmd_boot on
  else
    engine boot asked >/dev/null 2>&1
    info "it will not start on boot; turn it on later with: ${B}selkies-cli boot on${NC}"
  fi
}

cmd_boot() {
  local act="${1:-status}"
  case "$act" in
    on|enable)
      [ -n "${UI_PORT:-}" ] || eval "$(status_vars "$(forge_status_json)")"
      local -a a=(boot enable --port "${UI_PORT:-$WEBUI_PORT}" --bind "${UI_BIND:-$WEBUI_BIND}")
      [ "${UI_EXPOSED:-0}" = 1 ] || [ "$WEBUI_EXPOSE" = 1 ] && a+=(--expose)
      local r; r=$(engine "${a[@]}" 2>&1)
      if ! printf '%s' "$r" | grep -q '"ok": true'; then
        bad "could not set that up: $(printf '%s' "$r" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")')"
        return 1
      fi
      local method; method=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method",""))')
      ok "the web UI will start by itself when this machine boots ($method)"
      if printf '%s' "$r" | grep -q '"needs"'; then
        warn "systemd only starts your services at boot once \"linger\" is on for your user"
        if confirm "Turn it on now? (runs: sudo loginctl enable-linger $USER)" y; then
          if run_root loginctl enable-linger "$USER"; then
            ok "linger is on: it now starts at boot, even before anyone logs in"
          else
            warn "that did not work; until it does, it starts when you log in"
          fi
        else
          info "until then it starts when you log in, not at boot"
        fi
      fi
      ;;
    off|disable)
      engine boot disable >/dev/null 2>&1 && ok "the web UI will no longer start on boot"
      ;;
    *)
      local r; r=$(engine boot status 2>/dev/null)
      if printf '%s' "$r" | grep -q '"enabled": true'; then
        ok "starts on boot ($(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method"))'))"
      else
        info "does not start on boot · turn it on with: selkies-cli boot on"
      fi
      ;;
  esac
}

# What the forge uses on disk, and tidying it up. Nothing a desktop uses is
# ever removed; images come back by themselves when you forge again.
cmd_clean() {
  title "Disk" "what the forge uses, and what it can give back"
  local r; r=$(engine space 2>/dev/null)
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def mb(x):
    x = float(x or 0)
    return "%.1f GB" % (x / 1024) if x >= 1024 else "%d MB" % x
g = d.get("groups") or {}
for key, label in (("layers", "forge layers"), ("built", "built desktops"),
                   ("pulled", "pulled desktops"), ("bases", "base images")):
    rows = g.get(key) or []
    unused = [r for r in rows if not r.get("in_use")]
    print("  %s %3d  %9s   %s" % (c("2", "%-16s" % label), len(rows),
          mb(sum(r["size_mb"] for r in rows)), c("2", "%s unused" % mb(sum(r["size_mb"] for r in unused)))))
print("  %s      %9s" % (c("2", "%-16s" % "build cache"), mb(d.get("build_cache_mb"))))
print("  %s %3d   %s" % (c("2", "%-16s" % "orphan volumes"), len(d.get("orphan_volumes") or []),
      c("2", "files of removed desktops you chose to keep")))
print()
print("  tidy up frees %s; removing everything unused frees %s" % (
    c("1", mb(d.get("reclaimable_mb"))), c("1", mb(d.get("reclaimable_all_mb")))))
'
  printf '\n'
  local act
  act=$(menu_choose "Clean up?" \
    $'tidy\tTidy up\told forge layers only; nothing to download again' \
    $'all\tRemove everything unused\tunused desktop images and the build cache' \
    $'vols\tAlso delete kept files\torphan volumes of removed desktops (cannot be undone)' \
    $'no\tLeave it\t') || return 0
  local -a a=(space --clean)
  case "$act" in
    tidy) : ;;
    all) a+=(--all) ;;
    vols) confirm "Delete the kept files of removed desktops for good?" n || return 0; a+=(--all --volumes) ;;
    *) return 0 ;;
  esac
  spin_start "cleaning up"
  r=$(engine "${a[@]}" 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print("  \u2714 removed %d images%s" % (len(d.get("removed_images") or []),
      ", %d volumes" % len(d["removed_volumes"]) if d.get("removed_volumes") else ""))
for k, v in (d.get("failed") or {}).items():
    print("  ! kept %s: %s" % (k, v[:80]))
'
}

# A desktop by its short name or its container name (forge-...).
resolve_desktop() {
  local n="$1"
  if docker inspect "$n" >/dev/null 2>&1; then printf '%s' "$n"
  elif docker inspect "forge-$n" >/dev/null 2>&1; then printf 'forge-%s' "$n"
  else printf '%s' "$n"; fi
}

cmd_backup() {
  [ -n "${1:-}" ] || die "usage: selkies-cli backup NAME"
  local n; n=$(resolve_desktop "$1")
  stream_job_view backup "Backing up $n" backup "$n"
}

cmd_backups() {
  title "Backups" "in $FORGE_HOME/backups; restore with: selkies-cli restore-backup NAME FILE"
  local -a a=(backups)
  [ -n "${1:-}" ] && a+=(--name "$(resolve_desktop "$1")")
  engine "${a[@]}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore_backup() {
  [ -n "${2:-}" ] || die "usage: selkies-cli restore-backup NAME FILE"
  local n; n=$(resolve_desktop "$1")
  confirm "Replace $n's files with $2? (a safety backup is taken first)" n || return 0
  stream_job_view restore "Restoring $n" restore-backup "$n" "$2"
}

cmd_clone() {
  [ -n "${1:-}" ] || die "usage: selkies-cli clone NAME [NEW-NAME]"
  local n; n=$(resolve_desktop "$1")
  local -a a=(clone "$n")
  [ -n "${2:-}" ] && a+=(--as "$2")
  stream_job_view clone "Cloning $n" "${a[@]}"
}

cmd_jobs() {
  title "Jobs" "launches, backups and clones, from the web UI and the terminal"
  engine jobs | sed 's/^/  /'
  printf '\n'
}

cmd_idle() {
  [ -n "${2:-}" ] || die "usage: selkies-cli idle NAME MINUTES|0|default"
  local n; n=$(resolve_desktop "$1")
  local r; r=$(engine idle "$n" "$2" 2>&1)
  if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
  elif [ "$2" = 0 ]; then ok "$n is never stopped for being idle"
  elif [ "$2" = default ]; then ok "$n follows the forge default (FORGE_IDLE_STOP_MIN)"
  else ok "$n stops after $2 minutes with nobody watching (needs the web UI running)"; fi
}

cmd_events() {
  title "What happened" "launches, crashes, heals and repairs, newest last"
  engine events --limit "${1:-40}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore() {
  spin_start "starting the desktops that were running before"
  local r; r=$(engine restore 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
for n in d.get("started") or []:
    print("  ✔ started " + n)
if not d.get("started"):
    print("  ! nothing needed starting")
'
}

main_menu() {
  review_autostart
  while :; do
    local js
    js=$(forge_status_json)
    eval "$(status_vars "$js")"
    render_status "$js"

    # Suggestions first: what you most likely want given what is running.
    # "Browse / forge a new desktop" always sits third, wherever the list starts.
    local -a items=()
    local newitem=$'new\tBrowse & forge a new desktop\tpick from 150+ desktops'
    [ "$TOTAL" -eq 0 ] && newitem=$'new\tBrowse & forge your first desktop\tpick from 150+ desktops'
    if [ "$DOCKER_OK" != 1 ]; then
      items+=($'doctor\tFind out why Docker is not answering\tchecks docker, memory, disk')
    fi
    if [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ]; then
      local why="they were running before it stopped"
      case "$LAST_REASON" in
        host-reboot) why="they were running before the reboot" ;;
        host-shutdown) why="they were running before the shutdown" ;;
        host-crash) why="they were running before the machine went down" ;;
      esac
      items+=("restore"$'\t'"Start the $RESTORE_N desktop(s) again"$'\t'"$why")
    fi
    case "$UI_STATE" in
      up)
        [ "$UI_RESTART" = 1 ] && items+=($'uirestart\tRestart the web UI\ta new version is installed')
        items+=("open"$'\t'"Open the web UI"$'\t'"running at $UI_URL")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops"$'\t'"$RUNNING running, $STOPPED stopped")
        items+=($'uistop\tStop the web UI\tyour desktops keep running')
        [ "$UI_RESTART" = 1 ] || items+=($'uirestart\tRestart the web UI\tafter an update, or if it misbehaves')
        ;;
      stale)
        items+=($'uistart\tStart the web UI again\tit stopped unexpectedly')
        items+=($'uilog\tShow why it stopped\tlast lines of its log')
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        ;;
      *)
        local hint="browse everything with screenshots"
        [ "$TOTAL" -gt 0 ] && hint="manage your $TOTAL desktop(s) in the browser"
        case "$LAST_REASON" in
          crash|oom|error|host-crash) hint="it stopped unexpectedly last time" ;;
        esac
        items+=("uistart"$'\t'"Start the web UI"$'\t'"$hint")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        case "$LAST_REASON" in
          crash|oom|error) items+=($'uilog\tShow why it stopped\tlast lines of its log') ;;
        esac
        ;;
    esac
    # Slot the browse entry in as the third choice (or last, if the list is shorter).
    if [ "${#items[@]}" -ge 2 ]; then
      items=("${items[@]:0:2}" "$newitem" "${items[@]:2}")
    else
      items+=("$newitem")
    fi
    if [ "$BOOT_ON" = 1 ]; then
      items+=($'bootoff\tStop starting the web UI on boot\tit currently starts by itself')
    else
      items+=($'booton\tStart the web UI on boot\tcomes back by itself after a reboot')
    fi
    [ "$DOCKER_OK" = 1 ] && items+=($'doctor\tCheck this machine\tdocker, memory, disk, tunnels')
    [ "$DOCKER_OK" = 1 ] && items+=($'clean\tFree up disk space\tunused images, old layers, build cache')
    items+=($'update\tUpdate Selkies Forge\tget the latest version from GitHub')
    [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ] && \
      items+=($'dismiss\tForget about the last stop\tstop suggesting the restart')
    items+=($'quit\tQuit\t')

    local choice
    choice=$(menu_choose "What would you like to do?" "${items[@]}") || { printf '\n'; return 0; }
    case "$choice" in
      open) cmd_open; return 0 ;;
      uistart) FORGE_FROM_MENU=1 cmd_webui ;;
      uistop) cmd_stop ;;
      uirestart) cmd_restart ;;
      uilog) cmd_ui_log ;;
      manager) cmd_manager ;;
      new) pick_new ;;
      restore) cmd_restore ;;
      dismiss) engine dismiss-last-stop >/dev/null 2>&1; ok "ok, it will not ask again" ;;
      booton) cmd_boot on ;;
      bootoff) cmd_boot off ;;
      doctor) cmd_doctor ;;
      clean) cmd_clean ;;
      update) cmd_update ;;
      quit|"") printf '\n  %sbye%s\n\n' "$DIM" "$NC"; return 0 ;;
    esac
  done
}

usage() {
  banner
  cat <<USAGE
Usage:
   $FORGE_RUN              interactive menu
   $FORGE_RUN --webui      straight to the web UI
   $FORGE_RUN --bg         web UI in the background, shell back
   $FORGE_RUN --fg         web UI in the foreground until ctrl-c
   $FORGE_RUN --stop       stop a backgrounded web UI
   $FORGE_RUN --cli        straight to the terminal picker
   $FORGE_RUN --smart      let it choose for this machine
   $FORGE_RUN --launch ID  forge one entry and exit
   $FORGE_RUN --list       print the catalog
   $FORGE_RUN --manager    manage running desktops
   $FORGE_RUN --doctor     check this machine
   $FORGE_RUN --uninstall  remove everything it created

After the first run:
   selkies-cli                     home screen: what is running, what to do next
   selkies-cli status              one-shot status of the web UI and desktops
   selkies-cli start | stop        web UI in the background, or stop it
   selkies-cli restart | open      restart it, or print/open its link
   selkies-cli manager | new       manage desktops, or forge a new one
   selkies-cli update              install the latest version from GitHub
   selkies-cli boot on | off       start the web UI by itself when the machine boots
   selkies-cli restore             start the desktops that were running before a reboot
   selkies-cli events              what happened: launches, crashes, heals, repairs
   selkies-cli clean               see and free the disk the forge uses
   selkies-cli jobs                launches, backups and clones in progress or recent
   selkies-cli backup NAME         back up a desktop's files (its home folder)
   selkies-cli backups [NAME]      list backups
   selkies-cli restore-backup NAME FILE   put a backup's files back (safety copy first)
   selkies-cli clone NAME [NEW]    a second desktop with a copy of its files
   selkies-cli idle NAME MIN       stop it after MIN minutes unwatched (0 = never)

Options:
   --port N       web UI port (default 8787, the next free one if taken)
   --expose       serve the web UI beyond localhost (no access control)
   --no-tunnel    skip the public serveo link
   --yes, -y      accept the install prompts (Python, Docker)

USAGE
}

# =========================================================================
#  entry point
# =========================================================================

main() {
  local MODE="menu" LAUNCH_ID="" BOOT_ACT="" EXTRACT_TO=""
  local -a ORIG_ARGS=("$@")
  # Verbs that take desktop names: run them straight after the usual setup.
  case "${1:-}" in
    backup|backups|restore-backup|clone|jobs|idle)
      local verb="$1"; shift
      ensure_dirs; preflight; extract_payload
      case "$verb" in
        backup) cmd_backup "$@" ;;
        backups) cmd_backups "$@" ;;
        restore-backup) cmd_restore_backup "$@" ;;
        clone) cmd_clone "$@" ;;
        jobs) cmd_jobs ;;
        idle) cmd_idle "$@" ;;
      esac
      exit $?
      ;;
  esac
  # Plain words for the common things: selkies-cli status, selkies-cli stop...
  case "${1:-}" in
    status|start|stop|restart|open|update|setup|manager|doctor|list|new|uninstall|help|boot|restore|clean|events)
      local verb="$1"; shift
      case "$verb" in
        start) set -- --bg "$@" ;;
        new) set -- --cli "$@" ;;
        help) set -- --help "$@" ;;
        boot) BOOT_ACT="${1:-status}"; [ $# -gt 0 ] && shift; set -- --boot "$@" ;;
        restore) set -- --restore "$@" ;;
        clean) set -- --clean "$@" ;;
        events) set -- --events "$@" ;;
        *) set -- "--$verb" "$@" ;;
      esac
      ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) MODE="status" ;;
      --boot) MODE="boot" ;;
      --restore) MODE="restore" ;;
      --clean) MODE="clean" ;;
      --events) MODE="events" ;;
      --restart) MODE="restart" ;;
      --open) MODE="open" ;;
      --update) MODE="update" ;;
      --setup) MODE="setup" ;;
      --webui|-w) MODE="webui" ;;
      --cli|-c) MODE="cli" ;;
      --smart|-s) MODE="smart" ;;
      --manager|-m) MODE="manager" ;;
      --doctor) MODE="doctor" ;;
      --list|-l) MODE="list" ;;
      --launch) MODE="launch"; LAUNCH_ID="${2:-}"; shift ;;
      --uninstall) MODE="uninstall" ;;
      --port) WEBUI_PORT="${2:-8787}"; WEBUI_PORT_SET=1; shift ;;
      --bind) WEBUI_BIND="${2:-127.0.0.1}"; shift ;;
      --expose) WEBUI_EXPOSE=1; WEBUI_BIND="0.0.0.0" ;;
      --bg) MODE="webui"; WEBUI_MODE="bg" ;;
      --fg) MODE="webui"; WEBUI_MODE="fg" ;;
      --stop) MODE="stop" ;;
      --no-tunnel) NO_TUNNEL=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --force-extract) FORCE_EXTRACT=1 ;;
      --version|-V) printf 'selkies-forge %s\n' "$FORGE_VERSION"; exit 0 ;;
      --extract-only) MODE="extract"; EXTRACT_TO="${2:-}"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done

  # Unpack the engine and web UI somewhere and stop: no installs, no checks.
  # build.py uses this for its self-test; packagers can use it too.
  if [ "$MODE" = extract ]; then
    [ -n "$EXTRACT_TO" ] || die "--extract-only needs a directory"
    mkdir -p "$EXTRACT_TO" || die "cannot create $EXTRACT_TO"
    FORGE_APP="$(cd "$EXTRACT_TO" && pwd)"
    FORCE_EXTRACT=1 extract_payload
    printf '%s\n' "$FORGE_APP"
    exit 0
  fi

  ensure_dirs
  case "$MODE" in
    uninstall|status|boot|events) : ;;
    *) banner ;;
  esac

  preflight
  extract_payload
  install_cli || true
  if [ "$FORGE_AS_CLI" = 1 ] && [ "${FORGE_JUST_UPDATED:-0}" != 1 ]; then
    case "$MODE" in
      update|uninstall|setup) : ;;
      *) auto_update_cli ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} ;;
    esac
  fi

  case "$MODE" in
    setup)
      announce_cli
      printf '\n'
      ok "Selkies Forge $FORGE_VERSION is ready"
      info "run ${B}${FORGE_RUN}${NC} any time to see what is running and pick what to do"
      printf '\n'
      exit 0
      ;;
    status) cmd_status; exit 0 ;;
    boot) cmd_boot "${BOOT_ACT:-status}"; exit $? ;;
    restore) cmd_restore; exit 0 ;;
    clean) cmd_clean; exit 0 ;;
    events) cmd_events; exit 0 ;;
    open) cmd_open; exit 0 ;;
    restart) cmd_restart; exit $? ;;
    update) cmd_update; exit 0 ;;
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

  announce_cli
  case "$MODE" in
    webui) singleton_check ;;
  esac

  case "$MODE" in
    webui) cmd_webui ;;
    cli) pick_quick ;;
    smart) cmd_smart ;;
    manager) cmd_manager ;;
    *) main_menu ;;
  esac
}

main "$@"
