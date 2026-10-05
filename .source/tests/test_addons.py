import json
import os
import shutil
import tempfile
import unittest

from tests import support  # noqa: F401
from forge import addons, jobs, paths, server

EXAMPLE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                       "addons", "hello-forge")


def make_addon(root, manifest=None, files=None):
    """A minimal addon folder; `manifest` entries override the defaults."""
    m = {"spec": 1, "id": "demo", "name": "Demo", "version": "1.2.3",
         "scripts": {"install": "install.sh", "status": "status.sh"}}
    m.update(manifest or {})
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "forge-addon.json"), "w") as fh:
        json.dump(m, fh)
    base = {"install.sh": "echo ::progress 50 half way\necho hello from install\necho ::open http://127.0.0.1:1/\n",
            "status.sh": 'echo \'{"state":"running","url":"http://127.0.0.1:1/x"}\'\n'}
    base.update(files or {})
    for name, body in base.items():
        p = os.path.join(root, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(body)
    return root


class SourceTest(unittest.TestCase):
    def test_github_repo_and_tree_links(self):
        s = addons.parse_source("https://github.com/o/r")
        self.assertEqual((s["kind"], s["url"], s["ref"], s["subdir"]), ("git", "https://github.com/o/r", None, ""))
        s = addons.parse_source("https://github.com/o/r/tree/main/addons/hello-forge")
        self.assertEqual((s["url"], s["ref"], s["subdir"]), ("https://github.com/o/r", "main", "addons/hello-forge"))
        s = addons.parse_source("https://gitlab.com/o/r/-/tree/dev/x/")
        self.assertEqual((s["url"], s["ref"], s["subdir"]), ("https://gitlab.com/o/r", "dev", "x"))
        s = addons.parse_source("https://example.com/r.git#pkg/addon")
        self.assertEqual((s["url"], s["subdir"]), ("https://example.com/r.git", "pkg/addon"))
        self.assertEqual(addons.parse_source("git@github.com:o/r.git")["kind"], "git")

    def test_bad_links(self):
        for bad in ("", "   ", "not a link", "ftp://x/y", "https://github.com/o/r#../../etc"):
            with self.assertRaises(addons.AddonError):
                addons.parse_source(bad)

    def test_local_folder(self):
        d = tempfile.mkdtemp()
        self.assertEqual(addons.parse_source(d)["kind"], "local")
        with self.assertRaises(addons.AddonError):
            addons.parse_source(os.path.join(d, "missing"))


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def bad(self, manifest, files=None, msg=None):
        make_addon(self.root, manifest, files)
        with self.assertRaises(addons.AddonError) as cm:
            addons.load_manifest(self.root)
        if msg:
            self.assertIn(msg, str(cm.exception))

    def test_the_example_addon_is_valid(self):
        m = addons.load_manifest(EXAMPLE)
        self.assertEqual(m["id"], "hello-forge")
        self.assertEqual(sorted(m["scripts"]), sorted(addons.SCRIPTS))
        self.assertEqual([s["key"] for s in m["settings"]], ["PORT", "GREETING", "ACCENT", "SHOW_DESKTOPS"])
        self.assertEqual(addons.check_requirements(dict(m, requires=dict(m["requires"], commands=[]))), [])

    def test_minimal(self):
        make_addon(self.root)
        m = addons.load_manifest(self.root)
        self.assertEqual((m["id"], m["version"], m["logo"]), ("demo", "1.2.3", ""))

    def test_required_fields_and_spec(self):
        self.bad({"spec": 2}, msg="newer Selkies Forge")
        self.bad({"spec": None}, msg='"spec": 1')
        self.bad({"id": "Bad_ID"}, msg='"id"')
        self.bad({"name": ""}, msg='"name"')
        self.bad({"scripts": {}}, msg="install")
        self.bad({"scripts": {"install": "install.sh", "postinstall": "install.sh"}}, msg="unknown script")

    def test_paths_stay_inside(self):
        self.bad({"scripts": {"install": "../outside.sh"}}, msg="relative path inside")
        self.bad({"scripts": {"install": "/bin/true"}}, msg="relative path inside")
        self.bad({"scripts": {"install": "missing.sh"}}, msg="does not exist")
        os.makedirs(self.root, exist_ok=True)
        os.symlink("/etc/hostname", os.path.join(self.root, "link.sh"))
        self.bad({"scripts": {"install": "link.sh"}}, msg="outside the addon")

    def test_logo_rules(self):
        self.bad({"logo": "logo.gif"}, files={"logo.gif": "GIF89a"}, msg=".svg")
        self.bad({"logo": "big.png"}, files={"big.png": "x" * (addons.MAX_IMAGE + 1)}, msg="larger")

    def test_settings(self):
        make_addon(self.root, {"settings": [
            {"key": "PORT", "label": "Port", "type": "number", "default": "8080", "min": 1, "max": 65535},
            {"key": "MODE", "label": "Mode", "type": "select", "options": ["a", {"value": "b", "label": "Bee"}], "default": "b"},
            {"key": "ON", "label": "On", "type": "bool", "default": "yes"}]})
        m = addons.load_manifest(self.root)
        port, mode, on = m["settings"]
        self.assertEqual(port["default"], 8080)
        self.assertEqual(mode["options"][1], {"value": "b", "label": "Bee"})
        self.assertIs(on["default"], True)
        with self.assertRaises(addons.AddonError):
            addons._coerce(port, 70000)
        with self.assertRaises(addons.AddonError):
            addons._coerce(mode, "c")
        self.bad({"settings": [{"key": "lower", "label": "x"}]}, msg="CAPITALS")
        self.bad({"settings": [{"key": "A", "label": "x"}, {"key": "A", "label": "y"}]}, msg="twice")
        self.bad({"settings": [{"key": "A", "label": "x", "type": "color"}]}, msg="type must be")

    def test_requirements(self):
        make_addon(self.root, {"requires": {"forge": ">=99.0.0", "commands": ["surely-not-a-command-xyz"],
                                            "arch": ["sparc64"]}})
        probs = addons.check_requirements(addons.load_manifest(self.root))
        self.assertEqual(len(probs), 3)
        self.assertIn("99.0.0", probs[0])
        self.assertEqual(addons.version_tuple("1.10.0"), (1, 10, 0))
        self.assertGreater(addons.version_tuple("1.10.0"), addons.version_tuple("1.9.9"))

    def test_integration_dir_must_be_under_home(self):
        self.bad({"integration": {"dir": "/etc/x"}}, msg="under ~/")
        self.bad({"integration": {"dir": "~/../x"}}, msg="under ~/")


class LifecycleTest(unittest.TestCase):
    """add -> install -> status -> uninstall -> remove, from a local folder, no network."""

    def setUp(self):
        self.src = make_addon(tempfile.mkdtemp(), {"id": "life", "name": "Life",
                                                    "settings": [{"key": "WORD", "label": "Word", "default": "hi"}],
                                                    "actions": [{"id": "poke", "label": "Poke", "script": "poke.sh"}],
                                                    "scripts": {"install": "install.sh", "status": "status.sh",
                                                                "uninstall": "uninstall.sh"}},
                              {"install.sh": 'echo "word=$FORGE_ADDON_SETTING_WORD adopt=$FORGE_ADDON_ADOPT"\n'
                                             'echo "$FORGE_ADDON_SETTING_WORD" > "$FORGE_ADDON_DATA/word"\n'
                                             "echo ::open http://127.0.0.1:9/\n",
                               "uninstall.sh": 'echo "keep=$FORGE_ADDON_KEEP_DATA"\n',
                               "poke.sh": "echo poked; exit 3\n"})

    def tearDown(self):
        try:
            addons.remove("life", force=True)
        except addons.AddonError:
            pass
        shutil.rmtree(self.src, ignore_errors=True)

    def test_round_trip(self):
        a = addons.add(self.src)
        self.assertFalse(a["installed"])
        self.assertTrue(a["logo"] is None)
        job = jobs.Job("addon", "life", "Install Life")
        res = addons.install("life", settings={"WORD": "yo"}, job=job)
        self.assertEqual(res["open_url"], "http://127.0.0.1:9/")
        self.assertEqual(job.status, "done")
        self.assertIn("word=yo adopt=0", [e["data"]["line"] for e in job.events if e["type"] == "log"])
        rec = addons.get("life")
        with open(os.path.join(addons.data_dir(rec), "word")) as fh:
            self.assertEqual(fh.read().strip(), "yo")
        st = addons.status(rec, max_age=0)
        self.assertEqual((st["state"], st["url"]), ("running", "http://127.0.0.1:1/x"))
        with self.assertRaises(addons.AddonError) as cm:
            addons.action("life", "poke")
        self.assertIn("exit 3", str(cm.exception))
        with self.assertRaises(addons.AddonError):
            addons.remove("life")                     # still installed
        addons.uninstall("life", keep_data=False)
        self.assertFalse(addons.get("life")["installed"])
        self.assertFalse(os.path.exists(os.path.join(addons.addon_dir("life"), "data", "word")))
        addons.remove("life")
        self.assertEqual([x["id"] for x in addons.list_addons(with_status=False)], [])

    def test_progress_and_warn_directives(self):
        addons.add(self.src)
        job = jobs.Job("addon", "life", "x")
        rc, lines, d = addons.run_script(addons.get("life"), "install.sh", job)
        self.assertEqual(rc, 0)
        self.assertEqual(d["open"], "http://127.0.0.1:9/")
        job2 = jobs.Job("addon", "life", "y")
        rec = addons.get("life")
        with open(os.path.join(addons.root_of(rec), "p.sh"), "w") as fh:
            fh.write("echo ::progress 40 Pulling\necho ::warn careful\necho ::progress nope\n")
        addons.run_script(rec, "p.sh", job2)
        self.assertAlmostEqual(job2.progress, 0.4)
        self.assertEqual(job2.label, "Pulling")

    def test_script_timeout_kills_it(self):
        addons.add(self.src)
        rec = addons.get("life")
        with open(os.path.join(addons.root_of(rec), "slow.sh"), "w") as fh:
            fh.write("sleep 30\n")
        rc, lines, _ = addons.run_script(rec, "slow.sh", timeout=0.5)
        self.assertNotEqual(rc, 0)
        self.assertIn("timed out", lines[-1])

    def test_password_settings_are_masked(self):
        shutil.rmtree(self.src)
        make_addon(self.src, {"id": "life", "settings": [{"key": "TOKEN", "label": "Token", "type": "password"}]})
        addons.add(self.src)
        addons.install("life", settings={"TOKEN": "s3cret"})
        view = addons.public(addons.get("life"))
        self.assertNotIn("s3cret", json.dumps(view))
        # sending the mask back keeps the real value
        self.assertEqual(addons._clean_settings(addons.get("life"), {"TOKEN": view["settings"][0]["value"]})["TOKEN"], "s3cret")


class IntegrationTest(unittest.TestCase):
    def test_descriptor_needs_a_running_web_ui(self):
        try:
            os.remove(paths.SERVER_JSON)
        except OSError:
            pass
        self.assertIsNone(addons.forge_descriptor())

    def test_descriptor_and_sync(self):
        home = tempfile.mkdtemp()
        old_known, old_home = addons.KNOWN_INTEGRATION_DIRS, os.environ.get("HOME")
        os.environ["HOME"] = home
        addons.KNOWN_INTEGRATION_DIRS = ("~/.config/burrow/integrations",)
        try:
            addons.jsave(paths.SERVER_JSON, {"port": 8787, "bind": "0.0.0.0"})
            self.assertEqual(addons.sync_integrations(), [])          # Burrow is not here
            os.makedirs(os.path.join(home, ".config", "burrow"))
            written = addons.sync_integrations()
            self.assertEqual(len(written), 1)
            with open(written[0]) as fh:
                d = json.load(fh)
            self.assertEqual((d["id"], d["kind"], d["url"], d["api"]),
                             ("selkies-forge", "selkies-forge", "http://127.0.0.1:8787/", "http://127.0.0.1:8787/api/"))
            self.assertTrue(d["logo"].startswith("<svg"))
            self.assertEqual(addons.sync_integrations(), [])          # unchanged: no rewrite
        finally:
            addons.KNOWN_INTEGRATION_DIRS = old_known
            os.environ["HOME"] = old_home
            os.remove(paths.SERVER_JSON)


class RunJobTest(unittest.TestCase):
    def test_work_functions_may_take_job(self):
        # Regression: _run_job's own first parameter was called `job`, so every
        # call passing job=... (backup, clone, restore) raised a TypeError.
        got = {}
        job = jobs.Job("test", None, "t")

        def work(x, job=None):
            got["x"], got["job"] = x, job
        server._run_job(job, work, 7, job=job)
        job.thread.join(5)
        self.assertEqual(got, {"x": 7, "job": job})


class WatchdogOwnerTest(unittest.TestCase):
    def test_only_its_own_desktops(self):
        # A second forge (another FORGE_HOME) once "healed" desktops the first
        # one had stopped on purpose, because it could not see that stop.
        from forge import watchdog
        mine = {"home": paths.ROOT}
        other = {"home": "/somewhere/else/.selkies-forge"}
        self.assertTrue(watchdog.is_mine("a", mine, {}))
        self.assertFalse(watchdog.is_mine("a", other, {"a": {}}))
        self.assertTrue(watchdog.is_mine("old", {"home": ""}, {"old": {}}))    # unlabelled, ours
        self.assertFalse(watchdog.is_mine("old", {"home": ""}, {}))           # unlabelled, unknown


if __name__ == "__main__":
    unittest.main()
