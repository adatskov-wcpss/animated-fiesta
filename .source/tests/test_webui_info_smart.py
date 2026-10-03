import time
import unittest

from tests import support
from forge import catalog, info, smart, webui


class LastStopTest(unittest.TestCase):
    def life(self, **kw):
        base = {"pid": 999999999, "started": time.time() - 600, "heartbeat": time.time() - 60,
                "boot_id": "boot-a", "desktops_running": ["forge-a"], "stopped": None}
        base.update(kw)
        return base

    def test_clean_reasons(self):
        r = webui.analyze_life(self.life(stopped={"reason": "user", "at": time.time()}), "boot-a")
        self.assertEqual((r["reason"], r["clean"]), ("user", True))
        r = webui.analyze_life(self.life(stopped={"reason": "host-reboot", "at": time.time()}), "boot-b")
        self.assertTrue(r["boot_changed"])
        self.assertEqual(r["label"], "this machine rebooted")

    def test_unplaced_sigterm_before_a_new_boot_was_a_shutdown(self):
        r = webui.analyze_life(self.life(stopped={"reason": "signal", "at": time.time()}), "boot-b")
        self.assertEqual(r["reason"], "host-shutdown")

    def test_no_record_and_a_new_boot_is_a_crash(self):
        r = webui.analyze_life(self.life(), "boot-b")
        self.assertEqual((r["reason"], r["clean"]), ("host-crash", False))

    def test_no_record_same_boot_dead_pid_is_a_web_ui_crash(self):
        r = webui.analyze_life(self.life(), "boot-a")
        self.assertIn(r["reason"], ("crash", "oom"))
        self.assertFalse(r["clean"])


class GalleryTest(unittest.TestCase):
    def names(self, eid):
        return [im["src"].split("?")[0].rsplit("/", 1)[-1] for im in
                info.entry_info(catalog.BY_ID[eid])["images"]]

    def test_only_pictures_of_the_desktop_you_get(self):
        imgs = self.names("noble-enlightenment")
        self.assertTrue(imgs)
        self.assertFalse([i for i in imgs if "Ubuntu" in i])

    def test_distro_pictures_that_show_the_same_desktop_stay(self):
        self.assertTrue([i for i in self.names("bookworm-kde") if "Debian" in i])
        self.assertTrue([i for i in self.names("alpine321-xfce") if "Alpine" in i])

    def test_public_entry(self):
        p = info.public_entry(catalog.BY_ID["noble-cinnamon"])
        self.assertEqual(p["display"], "fixed")
        self.assertNotIn("recipe", p)
        self.assertEqual(p["family_label"], "Ubuntu")


class SmartTest(unittest.TestCase):
    def test_plans_respect_floors(self):
        for e in catalog.CATALOG:
            p = smart.plan_resources(e, support.FAKE_HOST)
            self.assertGreaterEqual(p["memory_mb"], e["ram_min"], e["id"])
            self.assertGreaterEqual(p["disk_mb"], 10240, e["id"])
            self.assertGreaterEqual(p["shm_mb"], 256, e["id"])
            self.assertGreaterEqual(p["cpus"], 1.0, e["id"])

    def test_recommendations_run_here(self):
        r = smart.recommend({"taste": "lightest"}, limit=3, host=support.FAKE_HOST)
        picks = r.get("picks") or r.get("results") or []
        self.assertTrue(picks)
        for pk in picks:
            e = pk.get("entry") or pk
            self.assertIn("arm64", e["arches"])


if __name__ == "__main__":
    unittest.main()
