#!/usr/bin/env bash
# install: put Hello Forge on this machine. Exit 0 on success.
#   ::progress N text   moves the progress bar      ::open URL  what "Open" opens
#   ::phase text        names the current step      ::warn text a warning to show at the end
# Everything else printed here is shown in the live log.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ "${FORGE_ADDON_ADOPT:-0}" = 1 ]; then
  echo "::phase Linking the Hello Forge that is already running"
else
  echo "::phase Installing Hello Forge"
fi

echo "::progress 10 Checking this machine"
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
port="${FORGE_ADDON_SETTING_PORT:-8790}"
if port_taken "$port"; then
  echo "Port $port is used by something else. Pick another in the addon's settings."
  exit 1
fi
echo "python3 $(python3 -c 'import platform; print(platform.python_version())'), port $port is free"

echo "::progress 35 Writing the settings"
write_config
echo "settings in $CONF"

echo "::progress 60 Starting the page"
service_install
service_start
if ! wait_up; then
  echo "It did not start. The last lines of its log:"
  tail -n 20 "$LOG" 2>/dev/null || journalctl --user -u "$UNIT" -n 20 --no-pager 2>/dev/null || true
  exit 1
fi
has_systemd && [ -f "$UNIT_FILE" ] && echo "running as the user service $UNIT" || echo "running in the background (pid $(cat "$PIDF"))"

[ "$(conf bind)" = 127.0.0.1 ] && echo "::warn It only answers on this machine, like the forge's web UI."
echo "::progress 100 Ready"
echo "::open $(url)"
