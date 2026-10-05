#!/usr/bin/env bash
# Burrow: install Selkies Forge (its own installer, unattended, web UI in the
# background), or link the one already here.
set -euo pipefail
cd "$(dirname "$0")/.."
. burrow-addon/lib.sh
if [ "${ADDON_ADOPT:-0}" = 1 ] || installed; then
  echo "::phase Linking the Selkies Forge already on this machine"
  echo "Selkies Forge $(version) is installed in $FORGE_HOME; Burrow looks after it from now on."
  running || { echo "::progress 60 starting its web UI"; cli start || true; }
else
  echo "::phase Installing Selkies Forge"
  echo "::progress 10 running its installer (a few minutes: it pulls Docker images)"
  bash docker.sh --yes --bg
fi
url="$(jget url)"
[ -n "$url" ] && echo "::open $url"
echo "::progress 100 done"
