"""Durable jobs, stall detection, the memory ledger, the watchdog's new duties,
backups and dry runs. Docker is never called: `run` is replaced where needed."""
import json
import os
import subprocess
import time
import unittest

from tests import support
from forge import backups, catalog, jobs, launch, ledger, watchdog
from forge.paths import JOBSTATEDIR


def dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


class FakeRun(object):
    """Stands in for util.run: answers by the first matching command prefix."""

    def __init__(self, answers):
        self.answers = answers
        self.calls = []

    def __call__(self, cmd, timeout=None, env=None, retries=None):
        self.calls.append(cmd)
        for prefix, ans in self.answers:
            if cmd[:len(prefix)] == prefix:
                return ans
        return (0, "", "")


class DurableJobTest(unittest.TestCase):
    def test_a_job_keeps_a_state_file(self):
        j = jobs.job_put(jobs.Job("launch", "noble-xfce", "Test"))
        j.set_phase("fetch", "Pulling", 0.3)
        j.note(container="forge-x")
        with open(os.path.join(JOBSTATEDIR, j.id + ".json")) as fh:
            st = json.load(fh)
        self.assertEqual((st["status"], st["phase"], st["notes"]["container"]),
                         ("running", "fetch", "forge-x"))
        self.assertEqual(st["pid"], os.getpid())
        j.finish({"name": "forge-x", "entry": {"huge": "x" * 5000}})
        with open(os.path.join(JOBSTATEDIR, j.id + ".json")) as fh:
            st = json.load(fh)
        self.assertEqual(st["status"], "done")
        self.assertNotIn("entry", st["result"])           # only the small parts are kept

    def test_a_dead_owner_means_interrupted(self):
        jid = "deadbeef0001"
        with open(os.path.join(JOBSTATEDIR, jid + ".json"), "w") as fh:
            json.dump({"id": jid, "kind": "launch", "status": "running", "pid": dead_pid(),
                       "created": time.time(), "notes": {}}, fh)
        st = next(s for s in jobs.read_job_states() if s["id"] == jid)
        self.assertEqual(st["status"], "interrupted")
        self.assertTrue(any(j["id"] == jid and j.get("foreign") for j in jobs.all_jobs()))

    def test_only_cli_jobs_can_be_cancelled_from_outside(self):
        jid = "deadbeef0002"
        with open(os.path.join(JOBSTATEDIR, jid + ".json"), "w") as fh:
            json.dump({"id": jid, "kind": "launch", "status": "running", "pid": os.getpid(),
                       "owner": "server", "created": time.time()}, fh)
        self.assertFalse(jobs.cancel_foreign(jid))       # never signal a web UI


class StallTest(unittest.TestCase):
    def test_a_silent_command_is_stopped(self):
        t0 = time.time()
        with self.assertRaises(jobs.CommandStalled):
            jobs.stream_cmd(["sh", "-c", "echo hi; sleep 30"], lambda l: None, stall=2)
        self.assertLess(time.time() - t0, 10)

    def test_a_silent_pty_command_is_stopped(self):
        t0 = time.time()
        with self.assertRaises(jobs.CommandStalled):
            jobs.stream_cmd_pty(["sh", "-c", "echo hi; sleep 30"], lambda l: None, stall=2)
        self.assertLess(time.time() - t0, 10)

    def test_a_chatty_command_is_left_alone(self):
        lines = []
        rc = jobs.stream_cmd(["sh", "-c", "for i in 1 2 3; do echo $i; sleep 1; done"],
                             lines.append, stall=2)
        self.assertEqual((rc, lines), (0, ["1", "2", "3"]))


class LedgerTest(unittest.TestCase):
    def setUp(self):
        for jid in ("a", "b", "dead"):
            ledger.release(jid)

    def test_bookings_add_up_and_exclude_yourself(self):
        ledger.book("a", 1024, "noble-xfce")
        ledger.book("b", 512, "noble-mate")
        self.assertEqual(ledger.booked(exclude="a")[0], 512)
        self.assertEqual(ledger.booked()[0], 1536)
        ledger.release("a")
        ledger.release("b")
        self.assertEqual(ledger.booked()[0], 0)

    def test_a_dead_process_books_nothing(self):
        from forge.paths import LEDGER_JSON
        from forge.util import jsave
        jsave(LEDGER_JSON, {"dead": {"mb": 4096, "pid": dead_pid(), "ts": time.time()}})
        self.assertEqual(ledger.booked()[0], 0)

    def test_admission_counts_launches_in_flight(self):
        e = catalog.BY_ID["noble-xfce"]
        host = dict(support.FAKE_HOST, mem_avail_mb=e["ram_min"] + 300)
        other = jobs.Job("launch", "noble-mate", "other")
        ledger.book(other.id, 1024, "noble-mate")       # another desktop is starting
        j = jobs.Job("launch", e["id"], e["name"])
        orig = launch.running_desktop_names
        launch.running_desktop_names = lambda: []
        try:
            with self.assertRaises(RuntimeError) as cm:
                launch.admit_memory(e, {"memory_mb": 2048}, host, j, {})
            self.assertIn("still starting", str(cm.exception))
            ledger.release(other.id)
            launch.admit_memory(e, {"memory_mb": 2048}, host, j, {})   # fits now
            self.assertEqual(ledger.booked()[0], e["ram_min"])     # and books its floor
        finally:
            launch.running_desktop_names = orig
            ledger.release(other.id)
            ledger.release(j.id)


PROC_NET = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid
   0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0
   1: 0100007F:1F92 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000  1000
   2: 0100007F:A1B2 0100007F:1F92 01 00000000:00000000 00:00000000 00000000     0
   3: 0100007F:1F92 0100007F:A1C4 01 00000000:00000000 00:00000000 00000000  1000
   4: 0100007F:1F92 0100007F:A1C9 06 00000000:00000000 00:00000000 00000000  1000
   5: 0200000A:0BB8 0100000A:D2F0 01 00000000:00000000 00:00000000 00000000     0
"""


class WatchdogTest(unittest.TestCase):
    def test_viewers_are_established_websockets(self):
        # two tabs on 8082; the listener, nginx's side, a TIME_WAIT and an
        # HTTP connection to nginx itself do not count
        self.assertEqual(watchdog.count_viewers(PROC_NET, {8082}), 2)
        self.assertEqual(watchdog.count_viewers(PROC_NET, {6901}), 0)

    def test_idle_limit_per_desktop_or_default(self):
        reg = {"forge-a": {"idle_stop_min": 30}, "forge-b": {"idle_stop_min": 0}, "forge-c": {}}
        os.environ["FORGE_IDLE_STOP_MIN"] = "90"
        try:
            self.assertEqual(watchdog.idle_limit("forge-a", reg), 30)
            self.assertEqual(watchdog.idle_limit("forge-b", reg), 0)
            self.assertEqual(watchdog.idle_limit("forge-c", reg), 90)
        finally:
            del os.environ["FORGE_IDLE_STOP_MIN"]
        self.assertEqual(watchdog.idle_limit("forge-c", reg), 0)

    def test_a_frozen_desktop_is_restarted_once(self):
        fake = FakeRun([])
        orig = watchdog.run
        watchdog.run = fake
        try:
            wd = watchdog.Watchdog()
            now = time.time()
            rep = {"frozen": [], "healed": []}
            prev = {"ts": now - 400}
            # the heartbeat moved last time; still moving: fine
            self.assertFalse(wd._check_frozen("forge-z", {}, {"ts": now - 70}, {"ts": now - 5}, now, rep))
            # stuck at the same old value: frozen, restarted
            self.assertTrue(wd._check_frozen("forge-z", {}, prev, {"ts": now - 400}, now, rep))
            self.assertEqual(rep["frozen"], ["forge-z"])
            self.assertIn(["docker", "restart", "-t", "10", "forge-z"], fake.calls)
            # reported once, not every pass
            n = len(fake.calls)
            wd._check_frozen("forge-z", {}, dict(prev, frozen_reported=True), {"ts": now - 400}, now, rep)
            self.assertEqual(len(fake.calls), n)
            # healing off: noticed, not restarted
            fake.calls[:] = []
            wd._check_frozen("forge-y", {"heal": "off"}, prev, {"ts": now - 400}, now, rep)
            self.assertFalse(any(c[:2] == ["docker", "restart"] for c in fake.calls))
        finally:
            watchdog.run = orig

    def test_recovery_removes_only_its_own_half_made_desktop(self):
        jid = "cafecafe0001"
        with open(os.path.join(JOBSTATEDIR, jid + ".json"), "w") as fh:
            json.dump({"id": jid, "kind": "launch", "status": "running", "pid": dead_pid(),
                       "created": time.time() - 30, "phase": "health",
                       "notes": {"container": "forge-half", "volume": "forge-config-forge-half"}}, fh)
        other = "cafecafe0002"         # same container name, but another job made it
        with open(os.path.join(JOBSTATEDIR, other + ".json"), "w") as fh:
            json.dump({"id": other, "kind": "launch", "status": "running", "pid": dead_pid(),
                       "created": time.time() - 30, "notes": {"container": "forge-mine",
                                                              "volume": "forge-config-forge-mine"}}, fh)
        fake = FakeRun([(["docker", "inspect", "-f"], None)])

        def answer(cmd, timeout=None, env=None, retries=None):
            fake.calls.append(cmd)
            if cmd[:3] == ["docker", "inspect", "-f"]:
                return (0, jid if cmd[-1] == "forge-half" else "someone-else", "")
            return (0, "", "")
        orig = watchdog.run
        watchdog.run = answer
        try:
            done = watchdog.recover_interrupted()
        finally:
            watchdog.run = orig
        self.assertIn(jid, done)
        self.assertIn(["docker", "rm", "-f", "forge-half"], fake.calls)
        self.assertIn(["docker", "volume", "rm", "-f", "forge-config-forge-half"], fake.calls)
        self.assertNotIn(["docker", "rm", "-f", "forge-mine"], fake.calls)
        st = next(s for s in jobs.read_job_states() if s["id"] == jid)
        self.assertTrue(st["recovered"])
        self.assertIn("removed", st["error"]["message"])
        self.assertNotIn(jid, watchdog.recover_interrupted())    # only once


class BackupTest(unittest.TestCase):
    def test_backup_names_cannot_escape_the_folder(self):
        for bad in ("../x.tar.gz", "/etc/passwd", "a/b.tar.gz", "x.tar", ""):
            with self.assertRaises(RuntimeError):
                backups.delete_backup(bad)

    def test_backups_are_listed_newest_first(self):
        from forge.paths import BACKUPDIR
        os.makedirs(BACKUPDIR, exist_ok=True)
        for i, name in enumerate(("forge-a", "forge-b")):
            base = os.path.join(BACKUPDIR, "%s-2026010%d-000000" % (name, i))
            with open(base + ".tar.gz", "wb") as fh:
                fh.write(b"x" * 30)
            with open(base + ".json", "w") as fh:
                json.dump({"name": name, "file": os.path.basename(base) + ".tar.gz",
                           "created": 1000 + i}, fh)
        rows = backups.list_backups()
        self.assertEqual([r["name"] for r in rows[:2]], ["forge-b", "forge-a"])
        self.assertEqual([r["name"] for r in backups.list_backups("forge-a")], ["forge-a"])


class DryRunTest(unittest.TestCase):
    def test_a_dry_run_does_nothing_and_says_everything(self):
        stubs = {"docker_ok": lambda: (True, ""), "manifest_probe": lambda img, a: (["arm64"], 700),
                 "image_present": lambda img: False, "host_info": lambda fresh=False: dict(support.FAKE_HOST),
                 "container_name_for": lambda e, n=None: "forge-dry",
                 "running_desktop_names": lambda: [], "get_image": None, "ensure_layer": None}
        orig = {k: getattr(launch, k) for k in stubs}
        for k, v in stubs.items():
            setattr(launch, k, v)
        try:
            res = launch.launch("noble-xfce", opts={"dry_run": True, "tunnel": False})
        finally:
            for k, v in orig.items():
                setattr(launch, k, v)
        self.assertTrue(res["dry_run"])
        self.assertEqual(res["name"], "forge-dry")
        self.assertIn("docker", res["docker_run"][0])
        self.assertTrue(any(s.startswith("build ") for s in res["steps"]))
        self.assertEqual(ledger.booked()[0], 0)            # nothing left booked


if __name__ == "__main__":
    unittest.main()
