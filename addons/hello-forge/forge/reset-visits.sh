#!/usr/bin/env bash
# The "Reset visit count" action: actions are ordinary scripts.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
curl -fs -m 5 -X POST "http://$(host_for_url "$(conf bind)"):$(conf port)/reset" >/dev/null && echo "visits are back to 0"
