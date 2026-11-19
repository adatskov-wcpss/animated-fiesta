"""H.264 by default (runner.h264_first)."""
import unittest

from tests import support  # noqa: F401  (sets FORGE_HOME, sys.path)
from forge.runner import h264_first


class H264First(unittest.TestCase):
    def test_moves_h264_to_the_front(self):
        self.assertEqual(h264_first(["jpeg", "h264enc", "vp8enc"]), ["h264enc", "jpeg", "vp8enc"])

    def test_old_name(self):
        self.assertEqual(h264_first(["x264enc-striped", "jpeg", "x264enc"]), ["x264enc", "x264enc-striped", "jpeg"])

    def test_already_first_or_missing(self):
        self.assertIsNone(h264_first(["h264enc", "jpeg"]))
        self.assertIsNone(h264_first(["jpeg", "vp9enc"]))
        self.assertIsNone(h264_first([]))

    def test_keeps_every_encoder(self):
        src = ["av1enc", "jpeg", "h264enc", "h265enc", "h264enc-striped"]
        self.assertEqual(sorted(h264_first(src)), sorted(src))


if __name__ == "__main__":
    unittest.main()
