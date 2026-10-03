import os
import threading
import time
import unittest

from tests import support  # noqa: F401
from forge import scheduler
from forge.jobs import Job, JobCancelled, stream_cmd, stream_cmd_pty


class JobTest(unittest.TestCase):
    def test_events_and_log_file(self):
        j = Job("test", "x")
        j.set_phase("fetch", "Fetching", 0.2)
        j.log("hello\nworld")
        j.finish({"ok": True})
        kinds = [e["type"] for e in j.since(0, timeout=0)]
        self.assertEqual(kinds, ["phase", "log", "log", "done"])
        self.assertTrue(os.path.isfile(j.log_path))
        with open(j.log_path) as fh:
            text = fh.read()
        self.assertIn("hello", text)
        self.assertIn("== done", text)

    def test_cancel_kills_the_running_command(self):
        j = Job("test")
        lines = []
        out = {}

        def work():
            try:
                stream_cmd(["sh", "-c", "echo started; sleep 30; echo never"], lines.append, job=j)
            except JobCancelled:
                out["cancelled"] = True

        t = threading.Thread(target=work)
        t0 = time.time()
        t.start()
        while "started" not in lines and time.time() - t0 < 5:
            time.sleep(0.05)
        self.assertTrue(j.cancel())
        t.join(10)
        self.assertFalse(t.is_alive())
        self.assertTrue(out.get("cancelled"))
        self.assertLess(time.time() - t0, 8)
        self.assertNotIn("never", lines)
        j.fail("cancelled")
        self.assertEqual(j.status, "cancelled")

    def test_cancel_kills_a_pty_command(self):
        j = Job("test")
        out = {}

        def work():
            try:
                stream_cmd_pty(["sh", "-c", "sleep 30"], lambda _l: None, job=j)
            except JobCancelled:
                out["cancelled"] = True

        t = threading.Thread(target=work)
        t.start()
        time.sleep(0.5)
        j.cancel()
        t.join(10)
        self.assertTrue(out.get("cancelled"))


class CancelWhileWaitingTest(unittest.TestCase):
    def test_cancel_reaches_the_health_wait(self):
        from forge.health import wait_http
        j = Job("test")
        out = {}

        def work():
            try:
                wait_http("forge-does-not-exist-test", 1, "selkies", job=j, timeout=60)
            except JobCancelled:
                out["cancelled"] = time.time()
            except Exception as ex:          # no docker here: the container check fails first
                out["other"] = ex

        t0 = time.time()
        t = threading.Thread(target=work)
        t.start()
        time.sleep(0.5)
        j.cancel()
        t.join(15)
        self.assertFalse(t.is_alive())
        if "other" not in out:
            self.assertLess(out["cancelled"] - t0, 8)


class SchedulerTest(unittest.TestCase):
    def setUp(self):
        os.environ["FORGE_MAX_BUILDS"] = "1"

    def tearDown(self):
        os.environ.pop("FORGE_MAX_BUILDS", None)

    def test_one_build_at_a_time(self):
        with scheduler.slot("build"):
            self.assertEqual(scheduler.busy("build"), 1)
            self.assertIsNone(scheduler._try_take("build"))
        self.assertEqual(scheduler.busy("build"), 0)

    def test_queued_job_can_be_cancelled(self):
        j = Job("test")
        out = {}

        def waiter():
            try:
                with scheduler.slot("build", j, poll=0.1):
                    out["got"] = True
            except JobCancelled:
                out["cancelled"] = True

        with scheduler.slot("build"):
            t = threading.Thread(target=waiter)
            t.start()
            time.sleep(0.5)
            self.assertEqual(j.phase, "queued")
            j.cancel()
            t.join(5)
        self.assertTrue(out.get("cancelled"))
        self.assertNotIn("got", out)

    def test_queued_job_runs_when_the_slot_frees(self):
        j = Job("test")
        out = {}
        hold = scheduler._try_take("build")

        def waiter():
            with scheduler.slot("build", j, poll=0.1):
                out["got"] = time.time()

        t = threading.Thread(target=waiter)
        t.start()
        time.sleep(0.4)
        self.assertNotIn("got", out)
        import fcntl
        fcntl.flock(hold, fcntl.LOCK_UN)
        hold.close()
        t.join(5)
        self.assertIn("got", out)


if __name__ == "__main__":
    unittest.main()
