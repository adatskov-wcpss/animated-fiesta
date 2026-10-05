#!/usr/bin/env bash
# Burrow: stop looking after Selkies Forge. It stays installed with every
# desktop: removing it all is `selkies-cli --uninstall`, on purpose a step you
# take yourself.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
echo "Selkies Forge stays installed in $FORGE_HOME, desktops and all."
echo "To remove it completely, run: selkies-cli --uninstall"
