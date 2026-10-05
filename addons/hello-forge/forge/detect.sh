#!/usr/bin/env bash
# detect: is Hello Forge already here? Exit 0 with one JSON line if so, 1 if not.
# Selkies Forge runs this when the addon is added and before installing; when
# it says yes, the install runs with FORGE_ADDON_ADOPT=1 ("Link it").
# Keep it quick and read-only.
set -u
. "$(dirname "$0")/lib.sh"
[ -f "$CONF" ] && healthy || exit 1
printf '{"version":"%s","url":"%s","detail":"answering on port %s"}\n' "$(conf version)" "$(url)" "$(conf port)"
