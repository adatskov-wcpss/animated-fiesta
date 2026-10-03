import subprocess
import tempfile
import unittest

from tests import support  # noqa: F401
from forge import catalog, layer, recipes


def syntax_ok(text, shell="bash"):
    with tempfile.NamedTemporaryFile("w", suffix=".sh") as fh:
        fh.write(text)
        fh.flush()
        return subprocess.run([shell, "-n", fh.name], capture_output=True).returncode == 0


class RecipesTest(unittest.TestCase):
    def test_startwm_runs_the_session_under_the_supervisor(self):
        e = catalog.BY_ID["noble-xfce"]
        s = recipes.gen_startwm(e)
        self.assertIn("dbus-run-session", s)
        self.assertIn("quick-exits", s)
        self.assertIn("rescue", s)
        self.assertIn("export XDG_SESSION_TYPE=x11", s)
        self.assertTrue(syntax_ok(s))

    def test_bare_window_managers_get_wallpaper_and_one_terminal(self):
        s = recipes.gen_startwm(catalog.BY_ID["noble-openbox"])
        self.assertIn("feh --no-fehbg --bg-fill /usr/local/share/forge/wallpaper.jpg", s)
        self.assertIn('pgrep -u "$(id -u)" -x xterm', s)

    def test_dockerfile_installs_and_verifies(self):
        e = catalog.BY_ID["bookworm-i3"]
        df = recipes.gen_dockerfile(e)
        self.assertTrue(df.startswith("FROM lscr.io/linuxserver/baseimage-selkies:debianbookworm"))
        self.assertIn("forge-install.sh", df)
        self.assertNotIn("# syntax=", df)          # no extra network fetch for a frontend
        sh = recipes.gen_install_sh(e)
        self.assertIn("exit 97", sh)
        self.assertTrue(syntax_ok(sh, "sh"))


class LayerTest(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ("AGENT", "SEED", "XSETTINGSD_RUN", "AGENT_RUN"):
            self.assertTrue(syntax_ok(getattr(layer, name)), name)
        self.assertTrue(syntax_ok(layer.BWRAP_SHIM, "sh"))

    def test_files_and_digest(self):
        pulled = layer.files()
        self.assertIn("forge/agent", pulled)
        self.assertIn("forge/wallpaper.jpg", pulled)
        self.assertNotIn("forge/startwm.sh", pulled)
        built = layer.files("#!/bin/sh\n")
        self.assertIn("forge/startwm.sh", built)
        self.assertIn("forge/built", built)
        self.assertTrue(layer.wallpaper_bytes().startswith(b"\xff\xd8"))   # a JPEG
        a = layer.digest("sha256:x")
        self.assertEqual(a, layer.digest("sha256:x"))
        self.assertNotEqual(a, layer.digest("sha256:y"))
        self.assertNotEqual(a, layer.digest("sha256:x", "#!/bin/sh\n"))

    def test_dockerfile_wires_the_services(self):
        df = layer.dockerfile("img:tag", "io.selkiesforge", "noble-xfce", "abc", startwm=True)
        self.assertIn("contents.d/init-forge", df)
        self.assertIn("contents.d/svc-forge-agent", df)
        self.assertIn("svc-de/dependencies.d/init-forge", df)
        self.assertIn("/defaults/startwm.sh", df)
        self.assertIn('io.selkiesforge.layer="abc"', df)

    def test_seed_skips_the_wizards(self):
        s = layer.SEED
        for needle in ("E_CONF_PROFILE", ".config/i3/config", "bspwmrc", "use_compositing",
                       "plasma-welcomerc", "gnome-session/sessions", "sysactions.conf"):
            self.assertIn(needle, s)


if __name__ == "__main__":
    unittest.main()
