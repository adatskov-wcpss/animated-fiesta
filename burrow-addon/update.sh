#!/usr/bin/env bash
# Burrow: bring Selkies Forge up to date (it also updates itself every few minutes).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
echo "::phase Updating Selkies Forge"
cli update
