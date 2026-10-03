"""
Selkies Forge engine - paths

Where everything lives, and the constants every module shares.

Layout of an install (FORGE_HOME, default ~/.selkies-forge):

    app/            what docker.sh unpacks: engine.py, forge/, web/, data/, selkies-cli
    state/          JSON state: instances, ports, events, web UI lifecycle, updates
    logs/           launch jobs, tunnels, the web UI, updates
    builds/         Dockerfiles and forge-layer build contexts
    backups/        desktop home-folder backups (tar.gz + a .json note each)
    repo/           a git clone of the project, used for updates
"""

import os
import re

VERSION = "1.7.0"

# app/forge/paths.py -> app/
APPDIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBDIR = os.path.join(APPDIR, "web")
DATADIR = os.path.join(APPDIR, "data")

ROOT = os.environ.get("FORGE_HOME") or os.path.join(os.path.expanduser("~"), ".selkies-forge")
STATE = os.path.join(ROOT, "state")
LOGDIR = os.path.join(ROOT, "logs")
JOBLOGDIR = os.path.join(LOGDIR, "jobs")
BUILDDIR = os.path.join(ROOT, "builds")
BACKUPDIR = os.path.join(ROOT, "backups")
JOBSTATEDIR = os.path.join(STATE, "jobs")
LEDGER_JSON = os.path.join(STATE, "ledger.json")

INSTANCES_JSON = os.path.join(STATE, "instances.json")
PORTS_JSON = os.path.join(STATE, "ports.json")
CACHE_JSON = os.path.join(STATE, "cache.json")
EVENTS_JSONL = os.path.join(STATE, "events.jsonl")
TOKEN_FILE = os.path.join(STATE, "token")
SSH_KEY = os.path.join(STATE, "serveo_key")
SERVER_JSON = os.path.join(STATE, "server.json")
LIFE_JSON = os.path.join(STATE, "webui-life.json")
LAST_STOP_JSON = os.path.join(STATE, "last-stop.json")
STOP_REQUEST_JSON = os.path.join(STATE, "stop-request.json")
BOOT_JSON = os.path.join(STATE, "boot.json")
UPDATE_JSON = os.path.join(STATE, "update.json")

# Docker naming: every container, image and volume the forge makes is tagged.
LABEL = "io.selkiesforge"
CPREFIX = "forge-"
IPREFIX = "selkies-forge/"

# Host ports handed to desktops, and the ports inside the images.
PORT_LO, PORT_HI = 31000, 44000
SELKIES_HTTP, SELKIES_HTTPS, KASM_HTTPS = 3000, 3001, 6901
# Selkies' streaming websocket inside the container (nginx proxies /api to it):
# one established connection per open browser tab.
SELKIES_WS = 8082

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
