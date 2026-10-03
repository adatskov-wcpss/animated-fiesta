import os
import unittest

from tests import support  # noqa: F401
from forge import events, util


class EventsTest(unittest.TestCase):
    def test_record_and_filter(self):
        events.record("forge-a", "create", "x")
        events.record("forge-b", "stop", "requested")
        events.record("forge-a", "crashed", "exit code 139", exit_code=139)
        rows = events.recent("forge-a")
        self.assertEqual([r["event"] for r in rows][-2:], ["create", "crashed"])
        self.assertEqual(rows[-1]["exit_code"], 139)
        self.assertIsNotNone(events.last_deliberate("forge-b"))
        self.assertIsNone(events.last_deliberate("forge-a"))

    def test_trim_keeps_the_newest(self):
        old = events.MAX_BYTES
        events.MAX_BYTES = 2000
        try:
            for i in range(200):
                events.record("forge-t", "start", "n%d" % i)
        finally:
            events.MAX_BYTES = old
        self.assertLess(os.path.getsize(events.EVENTS_JSONL), 60000)
        self.assertEqual(events.recent("forge-t")[-1]["detail"], "n199")


class RunTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.real = util._run_once
        self.sleep = util.time.sleep
        util.time.sleep = lambda s: None

    def tearDown(self):
        util._run_once = self.real
        util.time.sleep = self.sleep

    def fake(self, results):
        def f(cmd, timeout, env):
            self.calls.append(cmd)
            return results.pop(0)
        util._run_once = f

    def test_docker_reads_retry_when_the_daemon_blinks(self):
        self.fake([(1, "", "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"),
                   (0, "ok", "")])
        self.assertEqual(util.run(["docker", "ps"]), (0, "ok", ""))
        self.assertEqual(len(self.calls), 2)

    def test_real_errors_and_writes_are_not_retried(self):
        self.fake([(1, "", "Error: No such container: x")])
        self.assertEqual(util.run(["docker", "inspect", "x"])[0], 1)
        self.fake([(1, "", "Cannot connect to the Docker daemon")])
        self.assertEqual(util.run(["docker", "rm", "-f", "x"])[0], 1)
        self.assertEqual(len(self.calls), 2)

    def test_helpers(self):
        self.assertEqual(util.parse_size("1.5GB"), int(1.5 * 1024 ** 3))
        self.assertEqual(util.human_mb(2048), "2.0 GB")
        self.assertEqual(util.slug("Ubuntu 24.04 KDE!"), "ubuntu-24-04-kde")
        self.assertEqual(util.clamp(5, 1, 3), 3)
        rc, out, _ = util.run(["sh", "-c", "echo hi"])
        self.assertEqual((rc, out.strip()), (0, "hi"))
        self.assertEqual(util.run(["/nonexistent-binary"])[0], 127)


if __name__ == "__main__":
    unittest.main()
