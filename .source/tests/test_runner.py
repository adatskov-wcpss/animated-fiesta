import unittest

from tests import support
from forge import catalog, runner


def env_of(args):
    return {args[i + 1].split("=", 1)[0]: args[i + 1].split("=", 1)[1]
            for i, a in enumerate(args) if a == "-e"}


def labels_of(args):
    return dict(args[i + 1].split("=", 1) for i, a in enumerate(args) if a == "--label")


class DisplayTest(unittest.TestCase):
    def test_auto_follows_the_desktop(self):
        self.assertEqual(runner.display_for(catalog.BY_ID["noble-xfce"], {}), ("fit", None))
        self.assertEqual(runner.display_for(catalog.BY_ID["noble-enlightenment"], {}),
                         ("fixed", (1920, 1080)))

    def test_explicit_and_clamped(self):
        e = catalog.BY_ID["noble-xfce"]
        self.assertEqual(runner.display_for(e, {"display": "fixed", "resolution": "1600x900"}),
                         ("fixed", (1600, 900)))
        self.assertEqual(runner.display_for(e, {"display": "fixed", "resolution": "9999x100"}),
                         ("fixed", (3840, 600)))
        self.assertEqual(runner.display_for(e, {"display": "nonsense"}), ("fit", None))
        kasm = next(x for x in catalog.CATALOG if x["profile"] == "kasm")
        self.assertEqual(runner.display_for(kasm, {"display": "fixed"}), ("fit", None))

    def test_labels_round_trip(self):
        self.assertEqual(runner.parse_display_label("fixed:1600x900"), ("fixed", "1600x900"))
        self.assertEqual(runner.parse_display_label("fit"), ("fit", None))
        self.assertEqual(runner.parse_display_label(""), ("auto", None))


class RunArgsTest(unittest.TestCase):
    plan = {"memory_mb": 2048, "cpus": 2.0, "shm_mb": 512, "disk_mb": 10240}

    def args(self, eid, opts, host=None):
        a, vol = runner.docker_run_args(catalog.BY_ID[eid], "forge-x", [31001, 31002], self.plan,
                                        opts, "img", host or support.FAKE_HOST)
        return a, vol

    def test_fit_caps_the_virtual_screen(self):
        a, vol = self.args("noble-xfce", {})
        env = env_of(a)
        self.assertEqual(env["MAX_RES"], "3840x2160")
        self.assertNotIn("SELKIES_MANUAL_WIDTH", env)
        self.assertEqual(vol, "forge-config-forge-x")
        self.assertIn("--restart", a)
        self.assertEqual(a[a.index("--restart") + 1], "no")
        self.assertEqual(a[a.index("--memory") + 1], a[a.index("--memory-swap") + 1])

    def test_fixed_sets_the_manual_size(self):
        env = env_of(self.args("noble-enlightenment", {})[0])
        self.assertEqual((env["SELKIES_MANUAL_WIDTH"], env["SELKIES_MANUAL_HEIGHT"]), ("1920", "1080"))
        self.assertNotIn("MAX_RES", env)

    def test_labels_credentials_and_options(self):
        a, _ = self.args("noble-xfce", {"username": "u", "password": "p", "autostart": True,
                                        "seccomp_unconfined": True, "heal": False})
        env, lab = env_of(a), labels_of(a)
        self.assertEqual((env["CUSTOM_USER"], env["PASSWORD"]), ("u", "p"))
        self.assertEqual(lab["io.selkiesforge.heal"], "off")
        self.assertEqual(lab["io.selkiesforge.entry"], "noble-xfce")
        self.assertEqual(a[a.index("--restart") + 1], "unless-stopped")
        self.assertIn("seccomp=unconfined", a)
        self.assertEqual(a[-1], "img")

    def test_quota_only_where_supported(self):
        a, _ = self.args("noble-xfce", {})
        self.assertNotIn("--storage-opt", a)
        a, _ = self.args("noble-xfce", {}, dict(support.FAKE_HOST, quota_support=True))
        self.assertIn("size=10240M", a)

    def test_kasm_profile(self):
        kasm = next(x for x in catalog.CATALOG if x["profile"] == "kasm")
        a, _ = runner.docker_run_args(kasm, "forge-k", [31001], self.plan, {"password": "pw"},
                                      "img", support.FAKE_HOST)
        self.assertIn("31001:6901", a)
        self.assertEqual(env_of(a)["VNC_PW"], "pw")


if __name__ == "__main__":
    unittest.main()
