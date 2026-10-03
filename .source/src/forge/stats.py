"""
Selkies Forge engine - stats

Docker stats sampler: CPU, memory and bandwidth per desktop.
"""

import json
import threading
import time

from collections import deque

from .paths import CPREFIX
from .util import _int_or_none, parse_size, run


def _pair(txt):
    try:
        a, b = str(txt).split("/", 1)
        return parse_size(a.strip()), parse_size(b.strip())
    except Exception:
        return 0, 0


class StatsSampler(object):
    """Polls docker stats so the manager tab has live numbers and sparklines."""

    KEEP = 240

    def __init__(self, interval=3.0):
        self.interval = interval
        self.hist = {}
        self.latest = {}
        self.lock = threading.Lock()
        self.stop_flag = threading.Event()
        self.thread = None

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_flag.set()

    def sample_once(self):
        rc, out, _ = run(["docker", "stats", "--no-stream", "--no-trunc",
                          "--format", "{{json .}}"], timeout=40)
        if rc != 0:
            return {}
        now = time.time()
        rows = {}
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            name = d.get("Name") or ""
            if not name.startswith(CPREFIX):
                continue
            mem_u, mem_l = _pair(d.get("MemUsage"))
            rx, tx = _pair(d.get("NetIO"))
            bi, bo = _pair(d.get("BlockIO"))
            try:
                cpu = float(str(d.get("CPUPerc", "0")).strip().rstrip("%"))
            except Exception:
                cpu = 0.0
            rows[name] = {"t": now, "cpu": cpu, "mem_mb": mem_u / (1024.0 * 1024.0),
                          "mem_limit_mb": mem_l / (1024.0 * 1024.0),
                          "rx": rx, "tx": tx, "block_r": bi, "block_w": bo,
                          "pids": _int_or_none(d.get("PIDs")) or 0}
        with self.lock:
            for name, row in rows.items():
                h = self.hist.setdefault(name, deque(maxlen=self.KEEP))
                prev = h[-1] if h else None
                row["rx_rate"] = row["tx_rate"] = 0.0
                if prev:
                    dt = max(0.5, row["t"] - prev["t"])
                    row["rx_rate"] = max(0.0, (row["rx"] - prev["rx"]) / dt)
                    row["tx_rate"] = max(0.0, (row["tx"] - prev["tx"]) / dt)
                h.append(row)
            self.latest = rows
            for gone in [n for n in self.hist if n not in rows]:
                if len(self.hist[gone]) and now - self.hist[gone][-1]["t"] > 600:
                    self.hist.pop(gone, None)
        return rows

    def _loop(self):
        while not self.stop_flag.is_set():
            try:
                self.sample_once()
            except Exception:
                pass
            self.stop_flag.wait(self.interval)

    def report(self):
        with self.lock:
            out = {}
            for name, h in self.hist.items():
                rows = list(h)
                if not rows:
                    continue
                cur = rows[-1]
                out[name] = {
                    "cpu": round(cur["cpu"], 1),
                    "mem_mb": round(cur["mem_mb"], 1),
                    "mem_limit_mb": round(cur["mem_limit_mb"], 1),
                    "mem_pct": round(100.0 * cur["mem_mb"] / cur["mem_limit_mb"], 1)
                    if cur["mem_limit_mb"] else 0.0,
                    "rx_total": cur["rx"], "tx_total": cur["tx"],
                    "total_bytes": cur["rx"] + cur["tx"],
                    "rx_rate": round(cur["rx_rate"], 1), "tx_rate": round(cur["tx_rate"], 1),
                    "block_r": cur["block_r"], "block_w": cur["block_w"],
                    "pids": cur["pids"],
                    "spark_cpu": [round(r["cpu"], 1) for r in rows[-60:]],
                    "spark_net": [round((r["rx_rate"] + r["tx_rate"]) / 1024.0, 2)
                                  for r in rows[-60:]],
                    "spark_mem": [round(r["mem_mb"], 1) for r in rows[-60:]],
                    "age": round(time.time() - rows[0]["t"]),
                }
            return out


STATS = StatsSampler()
