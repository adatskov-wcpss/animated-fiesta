"""
Selkies Forge engine - registry

The live view of every desktop, read from Docker labels.
"""

import json

from . import catalog
from .info import public_entry
from .paths import KASM_HTTPS, LABEL, SELKIES_HTTP, SELKIES_HTTPS
from .store import reg_load
from .tunnels import tunnel_status
from .watchdog import idle_limit, session_health
from .util import _int_or_none, run


def docker_instances():
    """Every forge container, merged with our own notes about it."""
    rc, out, _ = run(["docker", "ps", "-aq", "--filter", "label=%s.entry" % LABEL], timeout=40)
    ids = [x for x in out.split() if x.strip()]
    data = []
    if ids:
        rc, out, _ = run(["docker", "inspect"] + ids, timeout=60)
        if rc == 0:
            try:
                data = json.loads(out)
            except Exception:
                data = []

    reg = reg_load()
    items = []
    for c in data:
        labels = ((c.get("Config") or {}).get("Labels") or {})
        name = (c.get("Name") or "").lstrip("/")
        state = c.get("State") or {}
        hostcfg = c.get("HostConfig") or {}
        ports = {}
        for cport, binds in ((c.get("NetworkSettings") or {}).get("Ports") or {}).items():
            if binds:
                try:
                    ports[cport.split("/")[0]] = int(binds[0].get("HostPort"))
                except Exception:
                    pass
        note = reg.get(name) or {}
        entry_id = labels.get("%s.entry" % LABEL)
        env = {}
        for kv in ((c.get("Config") or {}).get("Env") or []):
            k, _, v = kv.partition("=")
            env[k] = v
        if env.get("CUSTOM_USER") and env.get("PASSWORD"):
            auth = {"user": env["CUSTOM_USER"], "password": env["PASSWORD"]}
        elif env.get("VNC_PW"):
            auth = {"user": "kasm_user", "password": env["VNC_PW"]}
        else:
            auth = None
        restart = ((hostcfg.get("RestartPolicy") or {}).get("Name") or "no")
        cat = catalog.BY_ID.get(entry_id)
        items.append({
            "name": name,
            "container_id": (c.get("Id") or "")[:12],
            "entry_id": entry_id,
            "entry": public_entry(cat) if cat else None,
            "title": labels.get("%s.title" % LABEL) or (cat or {}).get("name") or name,
            "family": labels.get("%s.family" % LABEL) or (cat or {}).get("family") or "ubuntu",
            "glyph": labels.get("%s.glyph" % LABEL) or (cat or {}).get("glyph") or "openbox",
            "de_label": labels.get("%s.de" % LABEL) or (cat or {}).get("de_label") or "",
            "profile": labels.get("%s.profile" % LABEL) or (cat or {}).get("profile") or "selkies",
            "image": (c.get("Config") or {}).get("Image"),
            "running": bool(state.get("Running")),
            "status": state.get("Status"),
            "health": ((state.get("Health") or {}).get("Status")),
            "started_at": state.get("StartedAt"),
            "created": c.get("Created"),
            "restarts": state.get("RestartCount") or 0,
            "exit_code": state.get("ExitCode"),
            "ports": ports,
            "limits": {
                "memory_mb": int((hostcfg.get("Memory") or 0) / (1024 * 1024)) or None,
                "cpus": round((hostcfg.get("NanoCpus") or 0) / 1e9, 2) or None,
                "shm_mb": int((hostcfg.get("ShmSize") or 0) / (1024 * 1024)) or None,
            },
            "disk_cap_mb": _int_or_none(labels.get("%s.disk" % LABEL)),
            "display": labels.get("%s.display" % LABEL) or "",
            "heal": labels.get("%s.heal" % LABEL) != "off",
            "session": session_health(name) if state.get("Running") else None,
            # minutes unwatched before the watchdog stops it (0: never)
            "idle_stop_min": idle_limit(name, reg),
            "autostart": restart in ("always", "unless-stopped", "on-failure"),
            "restart_policy": restart,
            "auth": auth,
            "volume": labels.get("%s.volume" % LABEL),
            "tunnel": note.get("tunnel"),
            "local_url": None,
            "notes": {k: v for k, v in note.items() if k not in ("tunnel",)},
        })

    for it in items:
        it["local_url"] = local_url_for(it)
        it["tunnel"] = tunnel_status(it["name"], it.get("tunnel"))
    items.sort(key=lambda i: (not i["running"], i["name"]))
    return items


def local_url_for(it):
    ports = it.get("ports") or {}
    if it.get("profile") == "kasm":
        p = ports.get(str(KASM_HTTPS))
        return "https://localhost:%d" % p if p else None
    p = ports.get(str(SELKIES_HTTP))
    return "http://localhost:%d" % p if p else None


def https_url_for(it):
    ports = it.get("ports") or {}
    p = ports.get(str(SELKIES_HTTPS))
    return "https://localhost:%d" % p if p else None
