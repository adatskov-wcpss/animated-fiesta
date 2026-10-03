import unittest

from tests import support
from forge.health import LaunchProblem, pick_fix


class PickFixTest(unittest.TestCase):
    def setUp(self):
        self.plan = {"memory_mb": 1024, "shm_mb": 256}
        self.opts = {}
        self.host = dict(support.FAKE_HOST)

    def test_oom_gets_more_memory_once(self):
        tried = set()
        fix = pick_fix(LaunchProblem("oom", "oom"), self.plan, self.opts, self.host, tried)
        self.assertEqual(fix[1], "memory")
        fix[2]()
        self.assertGreater(self.plan["memory_mb"], 1024)
        tried.add("memory")
        self.assertIsNone(pick_fix(LaunchProblem("oom", "oom"), self.plan, self.opts, self.host, tried))

    def test_no_memory_to_give(self):
        host = dict(self.host, mem_avail_mb=1100)
        self.assertIsNone(pick_fix(LaunchProblem("oom", "oom"), self.plan, self.opts, host, set()))

    def test_shm(self):
        fix = pick_fix(LaunchProblem("x", "exited", "shm_open failed: No space left on device"),
                       self.plan, self.opts, self.host, set())
        self.assertEqual(fix[1], "shm")
        fix[2]()
        self.assertEqual(self.plan["shm_mb"], 512)

    def test_crash_tries_seccomp_then_gives_up(self):
        tried = set()
        fix = pick_fix(LaunchProblem("x", "crash"), self.plan, self.opts, self.host, tried)
        self.assertEqual(fix[1], "seccomp")
        fix[2]()
        tried.add("seccomp")
        self.assertTrue(self.opts["seccomp_unconfined"])
        self.assertIsNone(pick_fix(LaunchProblem("x", "crash"), self.plan, self.opts, self.host, tried))

    def test_slow_boot_waits_longer(self):
        fix = pick_fix(LaunchProblem("x", "timeout"), self.plan, self.opts, self.host, set())
        self.assertEqual(fix[1], "slow")
        fix[2]()
        self.assertGreater(self.opts["health_timeout"], 300)

    def test_exited_restarts_once(self):
        opts = {"seccomp_unconfined": True}
        fix = pick_fix(LaunchProblem("x", "exited"), self.plan, opts, self.host, set())
        self.assertEqual(fix[1], "restart")
        self.assertIsNone(pick_fix(LaunchProblem("x", "exited"), self.plan, opts, self.host, {"restart"}))


if __name__ == "__main__":
    unittest.main()
