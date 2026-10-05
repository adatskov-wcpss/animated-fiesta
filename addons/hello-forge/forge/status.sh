#!/usr/bin/env bash
# status: one JSON line. state is running | stopped | error; url is what
# the forge's "Open" button opens; port lets the forge offer the other ways
# in (this network, a serveo public link, a Burrow address). Must be quick
# (the forge waits 15 s at most).
set -u
. "$(dirname "$0")/lib.sh"
[ -f "$CONF" ] || { echo '{"state":"error","detail":"no settings; reinstall it"}'; exit 0; }
if healthy; then
  v="$(curl -fs -m 2 "http://$(host_for_url "$(conf bind)"):$(conf port)/health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("visits", 0))' 2>/dev/null)"
  printf '{"state":"running","url":"%s","port":%s,"version":"%s","detail":"%s visits so far"}\n' "$(url)" "$(conf port)" "$(conf version)" "${v:-0}"
else
  printf '{"state":"stopped","url":"%s","port":%s,"detail":"not answering on port %s"}\n' "$(url)" "$(conf port)" "$(conf port)"
fi
