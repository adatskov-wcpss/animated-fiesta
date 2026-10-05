#!/usr/bin/env bash
# uninstall: stop and remove the service. FORGE_ADDON_KEEP_DATA=0 means the
# person asked to delete the data too (the forge then also deletes FORGE_ADDON_DATA).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
echo "::phase Uninstalling Hello Forge"
service_remove
echo "stopped and removed"
if [ "${FORGE_ADDON_KEEP_DATA:-1}" = 1 ]; then
  echo "kept $DATA (settings and the visit count)"
else
  rm -f "$CONF" "$LOG"
  echo "deleted its settings"
fi
