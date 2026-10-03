"""The screen guard, run in Node against pretend screens."""
import json
import shutil
import subprocess
import unittest

from tests import support  # noqa: F401  (puts src/ on the path)
from forge import layer

HARNESS = r"""
const store = new Map(Object.entries(%(store)s));
global.localStorage = {
  getItem: k => store.has(k) ? store.get(k) : null,
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: k => store.delete(k),
};
global.window = { localStorage: global.localStorage, devicePixelRatio: %(dpr)s };
global.screen = { width: %(w)s, height: %(h)s };
global.location = { origin: "http://127.0.0.1:43441", pathname: "/" };
%(guard)s
console.log(JSON.stringify(Object.fromEntries(store)));
"""
P = "http___127.0.0.1_43441__"


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class ScreenGuardTest(unittest.TestCase):
    def run_guard(self, w, h, dpr, store=None):
        js = HARNESS % {"store": json.dumps(store or {}), "dpr": dpr, "w": w, "h": h,
                        "guard": layer.SCREEN_GUARD}
        out = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_4k_at_200_percent_gets_css_scaling(self):
        s = self.run_guard(1920, 1080, 2)
        self.assertEqual((s[P + "useCssScaling"], s[P + "scaling_dpi"]), ("true", "192"))

    def test_4k_at_100_percent_is_divided_down_too(self):
        s = self.run_guard(3840, 2160, 1)
        self.assertEqual((s[P + "useCssScaling"], s[P + "scaling_dpi"]), ("true", "192"))

    def test_5k_and_4k_at_150_percent(self):
        self.assertEqual(self.run_guard(2560, 1440, 2)[P + "scaling_dpi"], "264")
        self.assertEqual(self.run_guard(2560, 1440, 1.5)[P + "scaling_dpi"], "192")

    def test_smaller_screens_are_left_alone(self):
        for w, h, dpr in ((1920, 1080, 1), (2560, 1440, 1), (1440, 900, 2), (1366, 768, 1.25)):
            self.assertEqual(self.run_guard(w, h, dpr), {}, (w, h, dpr))

    def test_a_viewers_own_choice_is_kept(self):
        mine = {P + "useCssScaling": "false", P + "useCssScaling_explicit_choice": "true"}
        self.assertEqual(self.run_guard(1920, 1080, 2, mine), mine)

    def test_it_takes_its_settings_back_on_a_smaller_screen(self):
        s = self.run_guard(1920, 1080, 2)
        self.assertEqual(self.run_guard(1920, 1080, 1, s), {})

    def test_it_leaves_settings_the_viewer_changed_since(self):
        s = self.run_guard(1920, 1080, 2)
        s[P + "scaling_dpi"] = "144"                       # picked in Selkies' menu
        after = self.run_guard(1920, 1080, 1, s)
        self.assertEqual(after[P + "scaling_dpi"], "144")
        self.assertNotIn(P + "forge_screen", after)


class GuardWiringTest(unittest.TestCase):
    def test_layer_ships_and_injects_it(self):
        self.assertIn("forge/screen-guard.js", layer.files())
        df = layer.dockerfile("img", "io.selkiesforge", "x", "d")
        self.assertIn("forge-screen.js", df)
        self.assertIn("/usr/share/selkies/*/index.html", df)
