import json
import os
import shutil
import subprocess
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


    def test_an_addon_learns_how_the_forge_runs_it(self):
        # The drop-in folder an installed addon declares gets an "addon" block
        # (version, commit, update state, a link to its card); others don't.
        home = tempfile.mkdtemp()
        src = make_addon(tempfile.mkdtemp(), {"id": "gate", "name": "Gate",
                                              "integration": {"dir": "~/.config/gate/integrations"}})
        old_known, old_home = addons.KNOWN_INTEGRATION_DIRS, os.environ.get("HOME")
        os.environ["HOME"] = home
        addons.KNOWN_INTEGRATION_DIRS = ("~/.config/other/integrations",)
        os.makedirs(os.path.join(home, ".config", "other"))
        try:
            addons.jsave(paths.SERVER_JSON, {"port": 8787, "bind": "0.0.0.0"})
            addons.add(src)
            addons.install("gate")
            addons._update("gate", {"remote": {"checked": 5, "up_to_date": False, "commit": "abc", "version": "2.0.0",
                                               "subject": "new"}})
            addons.sync_integrations()
            with open(os.path.join(home, ".config", "gate", "integrations", "selkies-forge.json")) as fh:
                mine = json.load(fh)["addon"]
            self.assertEqual((mine["id"], mine["version"], mine["adopted"]), ("gate", "1.2.3", False))
            self.assertEqual(mine["update"], {"available": True, "commit": "abc", "version": "2.0.0", "subject": "new"})
            self.assertEqual(mine["page"], "http://127.0.0.1:8787/#addons/gate")
            with open(os.path.join(home, ".config", "other", "integrations", "selkies-forge.json")) as fh:
                self.assertIsNone(json.load(fh)["addon"])
            addons.uninstall("gate")                  # uninstalled: its folder no longer says it is an addon
            with open(os.path.join(home, ".config", "gate", "integrations", "selkies-forge.json")) as fh:
                self.assertIsNone(json.load(fh)["addon"])
        finally:
            addons.remove("gate", force=True)
            shutil.rmtree(src, ignore_errors=True)
            addons.KNOWN_INTEGRATION_DIRS = old_known
            os.environ["HOME"] = old_home
            os.remove(paths.SERVER_JSON)


class UniversalFormatTest(unittest.TestCase):
    """One manifest for every host: platforms, requires.burrow, ADDON_* names."""

    def test_platforms(self):
        d = make_addon(tempfile.mkdtemp())
        self.assertEqual(addons.load_manifest(d)["platforms"], ["selkies-forge", "burrow"])
        make_addon(d, {"platforms": ["burrow"]})
        m = addons.load_manifest(d)
        self.assertEqual(m["platforms"], ["burrow"])
        self.assertIn("is made for Burrow, not Selkies Forge", addons.check_requirements(m))
        for bad in (["windows"], [], "burrow"):
            make_addon(d, {"platforms": bad})
            with self.assertRaises(addons.AddonError):
                addons.load_manifest(d)
        make_addon(d, {"requires": {"burrow": "two"}})
        with self.assertRaises(addons.AddonError):
            addons.load_manifest(d)
        shutil.rmtree(d)

    def test_universal_environment(self):
        src = make_addon(tempfile.mkdtemp(), {"id": "envy", "settings": [{"key": "PORT", "label": "Port", "default": 5}]},
                         {"install.sh": 'echo "$ADDON_ID $ADDON_SETTING_PORT $ADDON_HOST $ADDON_ADOPT $FORGE_ADDON_ID"\n'})
        try:
            addons.add(src)
            rc, lines, _ = addons.run_script(addons.get("envy"), "install.sh")
            self.assertEqual(lines[-1], "envy 5 selkies-forge 0 envy")
        finally:
            addons.remove("envy", force=True)
            shutil.rmtree(src, ignore_errors=True)

    def test_scan_finds_addons_on_the_machine(self):
        home = tempfile.mkdtemp()
        make_addon(os.path.join(home, "code", "gizmo"), {"id": "gizmo", "name": "Gizmo", "scripts": {
            "install": "install.sh", "detect": "detect.sh", "status": "status.sh"}},
            {"detect.sh": 'echo \'{"version":"0.9"}\'\n', "status.sh": 'echo \'{"state":"stopped"}\'\n'})
        make_addon(os.path.join(home, "code", "other"), {"id": "other", "platforms": ["burrow"], "replaces": ["oldgizmo"]})
        make_addon(os.path.join(home, "code", "oldgizmo"), {"id": "oldgizmo"})      # replaced by "other": hidden
        os.makedirs(os.path.join(home, "code", "broken"))
        with open(os.path.join(home, "code", "broken", "forge-addon.json"), "w") as fh:
            fh.write("{nope")
        old = addons._scan_roots
        addons._scan_roots = lambda: [(home, 4)]
        try:
            r = addons.scan(max_age=0)
            by = {e["id"]: e for e in r["addons"]}
            self.assertEqual((by["gizmo"]["found"], by["gizmo"]["state"], by["gizmo"]["installed_version"]), (True, "stopped", "0.9"))
            self.assertTrue(by["gizmo"]["compatible"])
            self.assertFalse(by["other"]["compatible"])
            self.assertEqual(len(r["broken"]), 1)
            self.assertNotIn("oldgizmo", by)
        finally:
            addons._scan_roots = old
            addons.forget_scan()
            shutil.rmtree(home)

    def test_bridge_off_without_burrow(self):
        from forge import burrow as b
        self.assertEqual(b.health(addons)["state"], "off")


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


class CheckUpdatesTest(unittest.TestCase):
    """check_updates against a real (local) git repository, addon in a subfolder."""

    def git(self, *args, cwd=None):
        env = dict(os.environ, GIT_AUTHOR_NAME="T", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="T",
                   GIT_COMMITTER_EMAIL="t@x")
        out = subprocess.run(["git"] + list(args), cwd=cwd or self.origin, env=env, check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return out.stdout.strip()

    def setUp(self):
        self.origin = tempfile.mkdtemp()
        self.git("init", "-q", "-b", "main")
        self.git("config", "uploadpack.allowFilter", "true")
        make_addon(os.path.join(self.origin, "addons", "demo"), {"id": "upd", "name": "Upd"})
        with open(os.path.join(self.origin, "README"), "w") as fh:
            fh.write("one\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "first")
        src = {"kind": "git", "url": "file://" + self.origin, "ref": None, "subdir": "addons/demo",
               "display": "file://%s#addons/demo" % self.origin}
        dest = addons.addon_dir("upd")
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(dest)
        commit = addons.fetch(src, os.path.join(dest, "repo"))
        m = addons.load_manifest(os.path.join(dest, "repo", "addons", "demo"))
        recs = addons._load()
        recs["upd"] = {"id": "upd", "source": src, "subdir": "addons/demo", "commit": commit, "manifest": m,
                       "installed": False, "settings": {}}
        addons._save(recs)

    def tearDown(self):
        addons.remove("upd", force=True)
        shutil.rmtree(self.origin, ignore_errors=True)

    def test_up_to_date_then_new_commits(self):
        r = addons.check_updates("upd")
        self.assertTrue(r["up_to_date"])
        # a commit elsewhere in the repository does not count
        with open(os.path.join(self.origin, "README"), "w") as fh:
            fh.write("two\n")
        self.git("commit", "-qam", "readme only")
        r = addons.check_updates("upd")
        self.assertTrue(r["up_to_date"])
        self.assertIn("none of them touch", r["note"])
        # a commit in the addon's folder does
        path = os.path.join(self.origin, "addons", "demo", "forge-addon.json")
        with open(path) as fh:
            m = json.load(fh)
        m["version"] = "2.0.0"
        with open(path, "w") as fh:
            json.dump(m, fh)
        self.git("commit", "-qam", "Demo 2.0")
        head = self.git("rev-parse", "HEAD")
        r = addons.check_updates("upd")
        self.assertFalse(r["up_to_date"])
        self.assertEqual((r["remote"]["commit"], r["remote"]["subject"], r["remote"]["version"]), (head, "Demo 2.0", "2.0.0"))
        self.assertEqual([c["subject"] for c in r["commits"]], ["Demo 2.0"])
        self.assertFalse(addons.get("upd")["remote"]["up_to_date"])
        # updating clears the cached check
        addons.update("upd")
        self.assertIsNone(addons.get("upd").get("remote"))
        self.assertTrue(addons.check_updates("upd")["up_to_date"])


class WaysInTest(unittest.TestCase):
    def setUp(self):
        self.rec = {"id": "w", "installed": True, "manifest": {"name": "W"}}

    def test_host_follows_the_status_url_when_it_is_this_machine(self):
        from forge import burrow
        burrow._ADDRS.update(at=1e18, set={"127.0.0.1", "localhost", "::1", "100.64.0.5"})
        try:
            self.assertEqual(addons._host(self.rec, {"url": "http://100.64.0.5:8790/"}), "100.64.0.5")
            self.assertEqual(addons._host(self.rec, {"url": "http://localhost:8790/"}), "127.0.0.1")
            self.assertEqual(addons._host(self.rec, {"url": "https://example.com/"}), "127.0.0.1")
            self.assertEqual(addons._host(self.rec, {}), "127.0.0.1")
        finally:
            burrow._ADDRS.update(at=0.0, set=set())

    def test_links_need_a_port_and_know_burrow_is_absent(self):
        self.assertIsNone(addons.links(self.rec, {"state": "running"}))
        w = addons.links(self.rec, {"state": "running", "port": 8790, "url": "http://localhost:8790/"})
        self.assertEqual((w["port"], w["local"], w["serveo"]), (8790, "http://localhost:8790/", None))
        self.assertFalse(w["burrow"]["installed"])

    def test_burrow_publish_without_burrow_says_so(self):
        from forge import burrow
        with self.assertRaises(RuntimeError):
            burrow.publish(8790, "x")


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
