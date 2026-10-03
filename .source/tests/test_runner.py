import unittest

from tests import support
from forge import catalog, runner


def env_of(args):
    return {args[i + 1].split("=", 1)[0]: args[i + 1].split("=", 1)[1]
            for i, a in enumerate(args) if a == "-e"}


def labels_of(args):
    return dict(args[i + 1].split("=", 1) for i, a in enumerate(args) if a == "--label")


class DisplayTest(unittest.TestCase):
    def test_every_selkies_desktop_defaults_to_a_fixed_1080p(self):
        for e in catalog.CATALOG:
            if e["profile"] == "kasm":
                continue
            self.assertEqual(runner.display_for(e, {}), ("fixed", (1920, 1080)), e["id"])
            self.assertEqual(runner.display_for(e, {"display": "auto"}), ("fixed", (1920, 1080)), e["id"])

    def test_following_the_window_is_opt_in(self):
        self.assertEqual(runner.display_for(catalog.BY_ID["noble-xfce"], {"display": "fit"}), ("fit", None))

    def test_explicit_and_clamped(self):
        e = catalog.BY_ID["noble-xfce"]
        self.assertEqual(runner.display_for(e, {"display": "fixed", "resolution": "1600x900"}),
                         ("fixed", (1600, 900)))
        self.assertEqual(runner.display_for(e, {"display": "fixed", "resolution": "9999x100"}),
                         ("fixed", (3840, 600)))
        self.assertEqual(runner.display_for(e, {"display": "nonsense"}), ("fixed", (1920, 1080)))
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
        a, vol = self.args("noble-xfce", {"display": "fit"})
        env = env_of(a)
        self.assertEqual(env["MAX_RES"], "3840x2160")
        self.assertNotIn("SELKIES_MANUAL_WIDTH", env)
        self.assertEqual(labels_of(a)["io.selkiesforge.display"], "fit")
        self.assertEqual(vol, "forge-config-forge-x")
        self.assertIn("--restart", a)
        self.assertEqual(a[a.index("--restart") + 1], "no")
        self.assertEqual(a[a.index("--memory") + 1], a[a.index("--memory-swap") + 1])

    def test_fixed_locks_the_screen_against_hidpi_browsers(self):
        for eid in ("noble-xfce", "noble-enlightenment"):
            a, _ = self.args(eid, {})
            env = env_of(a)
            self.assertEqual((env["SELKIES_MANUAL_WIDTH"], env["SELKIES_MANUAL_HEIGHT"]), ("1920", "1080"))
            self.assertEqual(env["SELKIES_MANUAL_RESOLUTION"], "true|locked")
            self.assertEqual(env["SELKIES_SCALING_DPI"], "96")
            self.assertEqual(env["SELKIES_USE_CSS_SCALING"], "true|locked")
            self.assertEqual(env["MAX_RES"], "3840x2160")
            self.assertEqual(labels_of(a)["io.selkiesforge.display"], "fixed:1920x1080")
            self.assertTrue(set(runner.FIXED_SCREEN_KEYS) <= set(env))

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


class ScreenMigrationTest(unittest.TestCase):
    """A 1.5 desktop that followed the window moves to the fixed 1080p screen."""

    def plan(self, version, display_label, display=None, resolution=None):
        from forge import lifecycle
        labels = {"io.selkiesforge.entry": "noble-xfce", "io.selkiesforge.version": version,
                  "io.selkiesforge.display": display_label}
        return lifecycle._screen_plan(labels, display, resolution)

    def test_old_automatic_fit_becomes_fixed(self):
        self.assertEqual(self.plan("1.5.0", "fit", "auto"), ("auto", None, True))
        # a repair (no screen asked for) keeps "auto", which now resolves to fixed
        want, res, _ = self.plan("1.5.0", "fit")
        self.assertEqual(want, "auto")
        self.assertEqual(runner.display_for(catalog.BY_ID["noble-xfce"], {"display": want}),
                         ("fixed", (1920, 1080)))

    def test_a_chosen_fit_is_kept(self):
        self.assertEqual(self.plan("1.6.0", "fit"), ("fit", None, False))
        self.assertEqual(self.plan("1.6.0", "fit", "fit"), ("fit", None, False))

    def test_only_real_changes_recreate(self):
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "auto")[2], False)
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "fixed", "1920x1080")[2], False)
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "fixed", "1600x900")[2], True)
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "fit")[2], True)
