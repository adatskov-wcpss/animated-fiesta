#!/usr/bin/env bash
# Selkies Forge - build.sh: the same as `python3 .source/build.py`, for people
# who reach for a shell script first. Every option is passed through:
#
#   bash .source/build.sh              asks where to write docker.sh
#   bash .source/build.sh -o out.sh    writes there without asking
#   bash .source/build.sh --check      checks docker.sh matches .source/
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "build.sh: python3 is required (3.8 or newer)" >&2
  exit 1
fi
exec "$PY" "$HERE/build.py" "$@"
