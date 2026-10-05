# Shared by the Burrow addon scripts: where Selkies Forge lives on this machine.
FORGE_HOME="${FORGE_HOME:-$HOME/.selkies-forge}"
SERVER_JSON="$FORGE_HOME/state/server.json"
cli() { if command -v selkies-cli >/dev/null 2>&1; then selkies-cli "$@"; else bash "$FORGE_HOME/app/selkies-cli" "$@"; fi; }
jget() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$SERVER_JSON" 2>/dev/null | head -1; }
running() { local pid; pid="$(jget pid)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
# installed, or a web UI running from a checkout of the source
installed() { [ -f "$FORGE_HOME/app/engine.py" ] || running; }
version() { local v; v="$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$FORGE_HOME/app/forge/paths.py" 2>/dev/null | head -1)"; echo "${v:-$(jget version)}"; }
