#!/usr/bin/env bash
# Burrow: is Selkies Forge already on this machine? One JSON line, or exit 1.
set -u
. "$(dirname "$0")/lib.sh"
installed || exit 1
printf '{"version":"%s","url":"%s","detail":"Selkies Forge %s in %s"}\n' "$(version)" "$(jget url)" "$(version)" "$FORGE_HOME"
