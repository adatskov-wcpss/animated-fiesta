#!/usr/bin/env bash
# Burrow action: restart the Selkies Forge web UI.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cli restart
