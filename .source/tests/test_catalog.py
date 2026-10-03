import unittest

from tests import support  # noqa: F401
from forge import catalog


class CatalogTest(unittest.TestCase):
    def test_ids_are_unique_and_indexed(self):
        ids = [e["id"] for e in catalog.CATALOG]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(set(ids), set(catalog.BY_ID))
        self.assertGreater(len(ids), 140)

    def test_every_entry_is_complete(self):
        need = ("id", "name", "family", "de", "de_label", "glyph", "kind", "arches", "ram_min",
                "ram_rec", "cpu_rec", "disk_mb", "weight", "profile")
        for e in catalog.CATALOG:
            for k in need:
                self.assertIn(k, e, "%s lacks %s" % (e["id"], k))
            self.assertIn(e["kind"], ("pull", "build"), e["id"])
            self.assertIn(e.get("display", "fit"), ("fit", "fixed"), e["id"])
            self.assertTrue(set(e["arches"]) <= {"amd64", "arm64"}, e["id"])
            self.assertGreaterEqual(e["ram_rec"], e["ram_min"], e["id"])
            if e["kind"] == "pull":
                self.assertTrue(e["image"], e["id"])
            else:
                r = e["recipe"]
                self.assertTrue(r["pkgs"].strip() and r["session"].strip(), e["id"])
                self.assertIn(r["pm"], ("apt", "dnf", "pacman", "apk"), e["id"])
                self.assertIn("XDG_SESSION_TYPE=x11", r["env"], e["id"])

    def test_quick_picks_and_family_labels_exist(self):
        for q in catalog.QUICK_PICKS:
            self.assertIn(q, catalog.BY_ID)
        for e in catalog.CATALOG:
            self.assertIn(e["family"], catalog.FAMILY_LABEL, e["id"])

    def test_desktops_that_misdraw_on_resize_run_fixed(self):
        for de in ("enlightenment", "cinnamon", "budgie", "gnome-flashback"):
            rows = [e for e in catalog.CATALOG if e["de"] == de]
            self.assertTrue(rows)
            for e in rows:
                self.assertEqual(e["display"], "fixed", e["id"])

    def test_known_package_traps_stay_fixed(self):
        kde = catalog.DESKTOPS["kde"]
        self.assertIn("kwin-x11", kde["apt"]["pkgs"].split())
        self.assertIn("kwin-x11", kde["pacman"]["pkgs"].split())
        self.assertNotIn("XDG_SESSION_DESKTOP=cinnamon", catalog.SESSION_ENV["cinnamon"])
        self.assertIn("XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME", catalog.SESSION_ENV["gnome-flashback"])


if __name__ == "__main__":
    unittest.main()
