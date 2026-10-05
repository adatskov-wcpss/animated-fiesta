"""Shared setup: an isolated FORGE_HOME and the source tree on sys.path.

Nothing here talks to Docker or starts a desktop.
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
if SRC not in sys.path:
    sys.path.insert(0, SRC)
if not os.environ.get("FORGE_HOME"):
    os.environ["FORGE_HOME"] = tempfile.mkdtemp(prefix="forge-tests-")
os.environ.setdefault("FORGE_AUTO_UPDATE", "0")
# Never find (or publish through) a real Burrow or Aegis on the machine
# running the tests: an earlier version did, and published a test port.
os.environ["BURROW_CONFIG_DIR"] = tempfile.mkdtemp(prefix="forge-tests-burrow-")
os.environ["AEGIS_CONFIG_DIR"] = tempfile.mkdtemp(prefix="forge-tests-aegis-")   # Aegis carries Burrow too
# ...nor write into the real ~/.config (the forge's drop-ins go to ~/.config/<app>/integrations)
os.environ["HOME"] = tempfile.mkdtemp(prefix="forge-tests-home-")
os.environ["XDG_CONFIG_HOME"] = os.path.join(os.environ["HOME"], ".config")

# A pretend machine, so plans and recommendations do not depend on this one.
FAKE_HOST = {
    "arch": "arm64", "cpus": 4, "cpu_free": 3.5, "mem_total_mb": 16000, "mem_avail_mb": 12000,
    "disk_free_mb": 300000, "disk_total_mb": 480000, "quota_support": False,
    "storage_driver": "overlay2", "backing_fs": "extfs", "docker": True, "has_dri": False,
}
