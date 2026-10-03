"""
Selkies Forge engine - ports

Free host port allocation with short-lived reservations.
"""

import random
import re
import socket
import time

from .paths import PORTS_JSON, PORT_HI, PORT_LO
from .util import FileLock, jload, jsave, run


def port_is_free(port):
    for fam, addr in ((socket.AF_INET, ""),):
        s = socket.socket(fam, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


def ports_in_use_by_docker():
    used = set()
    rc, out, _ = run(["docker", "ps", "--format", "{{.Ports}}"], timeout=30)
    if rc == 0:
        for m in re.finditer(r":(\d+)->", out):
            used.add(int(m.group(1)))
    return used


def alloc_ports(count, want=None):
    """Reserve `count` free host ports.  Honours an explicit first choice."""
    with FileLock("ports"):
        res = jload(PORTS_JSON, {})
        now = time.time()
        res = {k: v for k, v in res.items() if now - float(v) < 900}
        taken = set(int(k) for k in res) | ports_in_use_by_docker()
        out = []
        if want:
            for p in want:
                p = int(p)
                if p not in taken and port_is_free(p):
                    out.append(p)
                    taken.add(p)
        tries = 0
        while len(out) < count and tries < 4000:
            tries += 1
            p = random.randint(PORT_LO, PORT_HI)
            if p in taken or p in out:
                continue
            if not port_is_free(p):
                taken.add(p)
                continue
            out.append(p)
            taken.add(p)
        if len(out) < count:
            raise RuntimeError("could not find %d free ports in %d-%d" % (count, PORT_LO, PORT_HI))
        for p in out:
            res[str(p)] = now
        jsave(PORTS_JSON, res)
        return out[:count]


def release_port_reservation(ports):
    try:
        with FileLock("ports"):
            res = jload(PORTS_JSON, {})
            for p in ports or []:
                res.pop(str(p), None)
            jsave(PORTS_JSON, res)
    except Exception:
        pass
