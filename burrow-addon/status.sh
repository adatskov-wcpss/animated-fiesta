#!/usr/bin/env bash
# Burrow: {"state", "version", "url", "port", "detail"}. The port lets Burrow
# give the dashboard its own HTTPS address.
set -u
. "$(dirname "$0")/lib.sh"
if ! installed; then echo '{"state":"not-installed"}'; exit 0; fi
if running; then
  printf '{"state":"running","version":"%s","url":"%s","port":%s,"detail":"web UI on %s"}\n' "$(version)" "$(jget url)" "$(jget port)" "$(jget url)"
else
  printf '{"state":"stopped","version":"%s","detail":"the web UI is stopped: Start it from the actions"}\n' "$(version)"
fi
