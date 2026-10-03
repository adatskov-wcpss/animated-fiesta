#!/usr/bin/env python3
"""
Selkies Forge engine - entry point.

The engine is the `forge` package next to this file. This script only puts
that package on the path and hands the command line to forge.cli.main().
`selkies-cli` (and the web UI) call it as:

    python3 engine.py serve --port 8787          the web UI
    python3 engine.py launch <id> [options]      forge one desktop, streaming events
    python3 engine.py status | doctor | list ... everything else (see --help)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from forge.cli import main  # noqa: E402

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
