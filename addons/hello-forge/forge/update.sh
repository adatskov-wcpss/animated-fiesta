#!/usr/bin/env bash
# update: the forge fetched new code into this folder; restart on it. The
# visit counter (and anything else in FORGE_ADDON_DATA) is kept.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
echo "::phase Updating Hello Forge to ${FORGE_ADDON_VERSION:-?}"
write_config
service_install
service_start
wait_up || { echo "It did not come back after the update."; exit 1; }
echo "::progress 100 Updated"
echo "::open $(url)"
