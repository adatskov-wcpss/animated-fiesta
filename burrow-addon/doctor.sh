#!/usr/bin/env bash
# Burrow action: check this machine for Selkies Forge.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cli --doctor
