"""
Selkies Forge engine - store

The instance registry file (notes the engine keeps beside Docker's labels).
"""

from .paths import INSTANCES_JSON
from .util import FileLock, jload, jsave


def reg_load():
    return jload(INSTANCES_JSON, {})


def reg_update(name, patch):
    with FileLock("instances"):
        reg = jload(INSTANCES_JSON, {})
        cur = reg.get(name) or {}
        cur.update(patch)
        reg[name] = cur
        jsave(INSTANCES_JSON, reg)
        return cur


def reg_delete(name):
    with FileLock("instances"):
        reg = jload(INSTANCES_JSON, {})
        reg.pop(name, None)
        jsave(INSTANCES_JSON, reg)
