#!/usr/bin/env bash
# Burrow action: stop the Selkies Forge web UI.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cli stop
