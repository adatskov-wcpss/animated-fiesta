# Shared by Hello Forge's scripts. Sourced, not run.
#
# Selkies Forge runs every script from the addon's folder with these set
# (docs/addons.md, "The environment"):
#   FORGE_ADDON_DIR   this folder            FORGE_ADDON_DATA  a folder kept across updates
#   FORGE_API         http://host:port/api/  FORGE_BIND        the web UI's bind address
#   FORGE_ADDON_SETTING_<KEY>                the settings from forge-addon.json
#
# The page runs as a systemd user service when the machine has one, otherwise
# as a plain background process with a pid file.

DATA="${FORGE_ADDON_DATA:?run me from Selkies Forge (FORGE_ADDON_DATA is not set)}"
APPDIR="${FORGE_ADDON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF="$DATA/config.json"
LOG="$DATA/hello-forge.log"
PIDF="$DATA/hello-forge.pid"
UNIT="forge-addon-hello-forge.service"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT"

has_systemd() { command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; }

conf() {  # conf KEY  -> a value from config.json
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$CONF" "$1" 2>/dev/null
}

host_for_url() {
  case "${1:-127.0.0.1}" in 0.0.0.0|::|"") echo 127.0.0.1 ;; *:*) echo "[$1]" ;; *) echo "$1" ;; esac
}
url() { echo "http://$(host_for_url "$(conf bind)"):$(conf port)/"; }

write_config() {
  local bind="${FORGE_BIND:-127.0.0.1}"
  python3 - "$CONF" <<PY
import json, os, sys
path = sys.argv[1]
old = {}
try:
    old = json.load(open(path))
except Exception:
    pass
cfg = {
    "port": int("${FORGE_ADDON_SETTING_PORT:-8790}"),
    "bind": "$bind",
    "greeting": os.environ.get("FORGE_ADDON_SETTING_GREETING") or "Hello from an addon",
    "accent": os.environ.get("FORGE_ADDON_SETTING_ACCENT") or "blue",
    "show_desktops": os.environ.get("FORGE_ADDON_SETTING_SHOW_DESKTOPS", "1") == "1",
    "forge_api": os.environ.get("FORGE_API", ""),
    "forge_version": os.environ.get("FORGE_VERSION", ""),
    "version": os.environ.get("FORGE_ADDON_VERSION", ""),
    "visits": old.get("visits", 0),
}
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(cfg, fh, indent=2)
os.replace(tmp, path)
PY
}

port_taken() {  # by something that is not us
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null || return 1
  ! curl -fs -m 2 "http://127.0.0.1:$1/health" 2>/dev/null | grep -q '"app": *"hello-forge"'
}

service_install() {
  if has_systemd; then
    mkdir -p "$(dirname "$UNIT_FILE")"
    cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Hello Forge (a Selkies Forge example addon)

[Service]
ExecStart=$(command -v python3) $APPDIR/app/server.py $CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT" >/dev/null 2>&1 || true
  fi
}

service_start() {
  if [ -f "$UNIT_FILE" ] && has_systemd; then systemctl --user restart "$UNIT"; return; fi
  service_stop
  nohup python3 "$APPDIR/app/server.py" "$CONF" >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
}

service_stop() {
  if [ -f "$UNIT_FILE" ] && has_systemd; then systemctl --user stop "$UNIT" 2>/dev/null || true; fi
  if [ -f "$PIDF" ]; then kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; fi
}

service_remove() {
  service_stop
  if [ -f "$UNIT_FILE" ]; then
    systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

healthy() { curl -fs -m 2 "http://$(host_for_url "$(conf bind)"):$(conf port)/health" >/dev/null 2>&1; }

wait_up() {
  local i
  for i in $(seq 1 30); do healthy && return 0; sleep 0.3; done
  return 1
}
