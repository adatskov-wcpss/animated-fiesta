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
        self.assertEqual(runner.display_for(catalog.BY_ID["webtop-alpine-i3"], {"display": "auto"}), ("fit", None))
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
        self.assertEqual(labels_of(a)["io.selkiesforge.display"], "fit")
        # fit leaves scaling to the viewer's browser (and the screen guard)
        self.assertFalse(any(k.startswith("SELKIES_") for k in env), env)
        self.assertEqual(vol, "forge-config-forge-x")
        self.assertIn("--restart", a)
        self.assertEqual(a[a.index("--restart") + 1], "no")
        self.assertEqual(a[a.index("--memory") + 1], a[a.index("--memory-swap") + 1])

    def test_fixed_holds_its_size_and_dpi(self):
        for eid, opts in (("noble-enlightenment", {}), ("noble-xfce", {"display": "fixed"})):
            a, _ = self.args(eid, opts)
            env = env_of(a)
            self.assertEqual((env["SELKIES_MANUAL_WIDTH"], env["SELKIES_MANUAL_HEIGHT"]), ("1920", "1080"))
            self.assertEqual(env["SELKIES_MANUAL_RESOLUTION"], "true|locked")
            # a 4K viewer's scaling DPI must not reach a fixed 1920x1080 desktop
            self.assertEqual(env["SELKIES_SCALING_DPI"], "96")
            self.assertNotIn("SELKIES_USE_CSS_SCALING", env)
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
    """1.6.0 forced every desktop to a fixed 1920x1080; 1.6.1 undoes that."""

    def plan(self, version, display_label, display=None, resolution=None, entry="noble-xfce"):
        from forge import lifecycle
        labels = {"io.selkiesforge.entry": entry, "io.selkiesforge.version": version,
                  "io.selkiesforge.display": display_label}
        return lifecycle._screen_plan(labels, display, resolution)

    def test_forced_fixed_goes_back_to_following_the_window(self):
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "auto"), ("auto", "1920x1080", True))
        want, _, _ = self.plan("1.6.0", "fixed:1920x1080")      # a repair
        self.assertEqual(runner.display_for(catalog.BY_ID["noble-xfce"], {"display": want}), ("fit", None))

    def test_desktops_that_want_fixed_stay_fixed(self):
        self.assertEqual(self.plan("1.6.0", "fixed:1920x1080", "auto", entry="noble-enlightenment")[2], False)

    def test_chosen_sizes_are_kept(self):
        self.assertEqual(self.plan("1.6.0", "fixed:1600x900"), ("fixed", "1600x900", False))
        self.assertEqual(self.plan("1.5.0", "fixed:1920x1080"), ("fixed", "1920x1080", False))
        self.assertEqual(self.plan("1.6.1", "fixed:1920x1080", "fixed")[2], False)

    def test_only_real_changes_recreate(self):
        self.assertEqual(self.plan("1.6.1", "fit", "auto")[2], False)
        self.assertEqual(self.plan("1.6.1", "fit", "fixed")[2], True)
        self.assertEqual(self.plan("1.6.1", "fixed:1920x1080", "fixed", "1600x900")[2], True)
