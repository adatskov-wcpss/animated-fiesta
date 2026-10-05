#!/usr/bin/env bash
# The "Restart" action from forge-addon.json.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
service_start
wait_up && echo "restarted at $(url)" || { echo "it did not come back"; exit 1; }
