"""
Selkies Forge - the engine.

Launches Linux desktops in Docker and streams them to a browser through
Selkies. See docs/engine.md for how the pieces fit together; engine.py next to
this package is the command-line entry point.
"""

from .paths import VERSION

__all__ = ["VERSION"]
