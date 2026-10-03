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

# A pretend machine, so plans and recommendations do not depend on this one.
FAKE_HOST = {
    "arch": "arm64", "cpus": 4, "cpu_free": 3.5, "mem_total_mb": 16000, "mem_avail_mb": 12000,
    "disk_free_mb": 300000, "disk_total_mb": 480000, "quota_support": False,
    "storage_driver": "overlay2", "backing_fs": "extfs", "docker": True, "has_dri": False,
}
