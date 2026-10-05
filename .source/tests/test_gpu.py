"""GPU Smart Passthrough: detection on fake sysfs trees, plans, fallbacks.

No Docker, no real GPU: every machine here is a directory of files shaped
like /sys and /dev, and verify results are handed in directly.
"""
import os
import shutil
import tempfile
import unittest
from unittest import mock

from tests import support  # noqa: F401  (sets FORGE_HOME, sys.path)
from forge import gpu, health, runner, catalog


class FakeMachine:
    """A throwaway /sys + /dev with DRM render nodes and V4L2 devices."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="forge-gpu-")
        self.sys = os.path.join(self.root, "sys")
        self.dev = os.path.join(self.root, "dev")
        os.makedirs(os.path.join(self.sys, "class", "drm"))
        os.makedirs(os.path.join(self.sys, "class", "video4linux"))
        os.makedirs(os.path.join(self.dev, "dri"))

    def _device(self, name, driver, vendor=None, device=None, compatible=None, boot_vga=None):
        d = os.path.join(self.sys, "devices", name)
        os.makedirs(d, exist_ok=True)
        drv = os.path.join(self.sys, "bus", "drivers", driver)
        os.makedirs(drv, exist_ok=True)
        if not os.path.lexists(os.path.join(d, "driver")):
            os.symlink(drv, os.path.join(d, "driver"))
        if vendor:
            open(os.path.join(d, "vendor"), "w").write(vendor + "\n")
            open(os.path.join(d, "device"), "w").write((device or "0x0000") + "\n")
        if compatible:
            os.makedirs(os.path.join(d, "of_node"), exist_ok=True)
            open(os.path.join(d, "of_node", "compatible"), "w").write("\x00".join(compatible) + "\x00")
        if boot_vga is not None:
            open(os.path.join(d, "boot_vga"), "w").write("1" if boot_vga else "0")
        return d

    def gpu(self, render, driver, card=None, **kw):
        d = self._device("gpu-" + driver + render, driver, **kw)
        for n in filter(None, (render, card)):
            nd = os.path.join(self.sys, "class", "drm", n)
            os.makedirs(nd)
            os.symlink(d, os.path.join(nd, "device"))
            open(os.path.join(self.dev, "dri", n), "w").close()
        return self

    def display_only(self, card, driver):
        d = self._device("disp-" + driver, driver)
        nd = os.path.join(self.sys, "class", "drm", card)
        os.makedirs(nd)
        os.symlink(d, os.path.join(nd, "device"))
        return self

    def v4l2(self, n, label):
        nd = os.path.join(self.sys, "class", "video4linux", n)
        os.makedirs(nd)
        open(os.path.join(nd, "name"), "w").write(label + "\n")
        open(os.path.join(self.dev, n), "w").close()
        return self

    def report(self, nvidia=None):
        gpus = gpu.detect_gpus(self.sys, self.dev)
        rep = {"gpus": gpus, "nvidia": nvidia or {"driver": None},
               "v4l2": gpu.detect_v4l2_encoders(self.sys, self.dev), "kernel": "test"}
        best = gpu.pick(rep)
        rep["primary"] = best["node"] if best else None
        rep["summary"] = gpu.describe(rep)
        return rep

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def env_of(args):
    return {args[i + 1].split("=", 1)[0]: args[i + 1].split("=", 1)[1]
            for i, a in enumerate(args) if a == "-e"}


RENDER_OK = {"render": True, "encoders": {}, "why": ["no hardware video encoder on this GPU"]}
RENDER_AND_VAAPI = {"render": True, "encoders": {"h264": "vaapi", "h265": "vaapi"}, "why": []}
NOTHING = {"render": False, "encoders": None, "why": ["this image's X server has no GPU drawing"]}


class DetectTest(unittest.TestCase):
    def setUp(self):
        self.m = FakeMachine()

    def tearDown(self):
        self.m.close()

    def test_raspberry_pi_5(self):
        # vc4 drives the display (cards only), v3d is the 3D GPU (render node)
        self.m.display_only("card0", "vc4").gpu("renderD128", "v3d", card="card1",
                                                 compatible=["brcm,2712-v3d"])
        rep = self.m.report()
        self.assertEqual(len(rep["gpus"]), 1)
        g = rep["gpus"][0]
        self.assertEqual((g["vendor"], g["driver"], g["index"]), ("broadcom", "v3d", 0))
        self.assertTrue(g["node"].endswith("/dri/renderD128"))
        self.assertTrue(g["card"].endswith("/dri/card1"))
        self.assertEqual(rep["primary"], g["node"])
        self.assertIn("Broadcom", rep["summary"])

    def test_intel_igpu_and_amd_dgpu_prefers_amd(self):
        self.m.gpu("renderD128", "i915", card="card0", vendor="0x8086", device="0x46a6", boot_vga=True)
        self.m.gpu("renderD129", "amdgpu", card="card1", vendor="0x1002", device="0x73df")
        rep = self.m.report()
        self.assertEqual([g["vendor"] for g in rep["gpus"]], ["intel", "amd"])
        self.assertTrue(rep["primary"].endswith("renderD129"))
        self.assertEqual(gpu.pick(rep, "intel")["driver"], "i915")
        self.assertEqual(gpu.pick(rep, "renderD128")["driver"], "i915")
        self.assertEqual(gpu.pick(rep, "1")["driver"], "amdgpu")

    def test_nvidia_without_toolkit_is_not_used(self):
        self.m.gpu("renderD128", "nvidia", card="card0", vendor="0x10de", device="0x2684")
        rep = self.m.report(nvidia={"driver": "550.1", "how": None})
        self.assertIsNone(rep["primary"])
        self.assertIn("nvidia-container-toolkit", rep["summary"])
        self.assertEqual(gpu.plan("auto", "img", rep=rep)["label"], "auto:none")

    def test_nvidia_with_toolkit_gets_gpus_all(self):
        self.m.gpu("renderD128", "nvidia", card="card0", vendor="0x10de", device="0x2684")
        rep = self.m.report(nvidia={"driver": "550.1", "how": "gpus"})
        with mock.patch.object(gpu, "verify", return_value={"render": True,
                                                            "encoders": {"h264": "nvenc"}, "why": []}):
            p = gpu.plan("auto", "img", rep=rep)
        bits = gpu.docker_bits(p)
        self.assertIn("--gpus", bits)
        self.assertEqual(env_of(bits)["NVIDIA_DRIVER_CAPABILITIES"], "all")
        self.assertEqual(p["encode"], "nvenc")
        self.assertEqual(env_of(bits)["DRI_NODE"], p["gpu"]["node"])

    def test_nvidia_cdi(self):
        self.m.gpu("renderD128", "nvidia", vendor="0x10de")
        rep = self.m.report(nvidia={"driver": "550.1", "how": "cdi"})
        self.assertIn("nvidia.com/gpu=all", gpu.device_args(rep["gpus"][0], rep))

    def test_display_only_and_virtual_vga_are_skipped(self):
        self.m.gpu("renderD128", "bochs-drm", vendor="0x1234")
        rep = self.m.report()
        self.assertIsNone(rep["primary"])
        self.assertEqual(gpu.plan("auto", "img", rep=rep)["args"], [])

    def test_unknown_soc_by_devicetree(self):
        self.m.gpu("renderD128", "weirdgpu", compatible=["rockchip,rk3588-mali"])
        g = self.m.report()["gpus"][0]
        self.assertEqual(g["vendor"], "rockchip")

    def test_no_drm_at_all(self):
        rep = self.m.report()
        self.assertEqual(rep["gpus"], [])
        self.assertIn("software", rep["summary"])

    def test_v4l2_keeps_encoders_only(self):
        self.m.v4l2("video10", "bcm2835-codec-decode").v4l2("video11", "bcm2835-codec-encode") \
            .v4l2("video12", "bcm2835-codec-isp").v4l2("video19", "rpi-hevc-dec") \
            .v4l2("video20", "pispbe").v4l2("video0", "unicam-image")
        enc = gpu.detect_v4l2_encoders(self.m.sys, self.m.dev)
        self.assertEqual([e["name"] for e in enc], ["bcm2835-codec-encode"])


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.m = FakeMachine()
        self.m.gpu("renderD128", "v3d", compatible=["brcm,2712-v3d"])
        self.rep = self.m.report()

    def tearDown(self):
        self.m.close()

    def plan(self, verified, mode="auto", **kw):
        with mock.patch.object(gpu, "verify", return_value=verified):
            return gpu.plan(mode, "img", rep=self.rep, **kw)

    def test_render_only_pins_encoding_off(self):
        p = self.plan(RENDER_OK)
        env = env_of(gpu.docker_bits(p))
        self.assertEqual(env["DRINODE"], p["gpu"]["node"])
        self.assertEqual(env["DISABLE_DRI3"], "false")
        # the base image would otherwise turn VA-API on for this node
        # never empty: s6-overlay drops empty variables and the image then guesses
        self.assertEqual(env["DRI_NODE"], "none")
        self.assertEqual(env["SELKIES_GPU_ID"], "-1")
        self.assertTrue(all(kv.split("=", 1)[1] for kv in p["env"]))
        self.assertEqual(p["label"], "auto:v3d:render:sw-enc")
        bits = gpu.docker_bits(p)
        # exactly one node, never the whole /dev/dri
        self.assertEqual([bits[i + 1] for i, a in enumerate(bits) if a == "--device"],
                         ["%s:%s" % (p["gpu"]["node"], p["gpu"]["node"])])

    def test_render_and_encode(self):
        p = self.plan(RENDER_AND_VAAPI)
        env = env_of(gpu.docker_bits(p))
        self.assertEqual(env["DRI_NODE"], p["gpu"]["node"])
        self.assertEqual(env["SELKIES_GPU_ID"], "0")
        self.assertEqual(p["encode"], "vaapi")

    def test_image_that_cannot_use_it_gets_nothing(self):
        p = self.plan(NOTHING)
        self.assertEqual(p["args"], [])
        self.assertEqual(p["label"], "auto:unused")
        self.assertTrue(any("glamor" in n or "GPU drawing" in n for n in p["notes"]))

    def test_no_render_pins_drawing_off_without_empty_values(self):
        p = self.plan({"render": False, "encoders": {"h264": "vaapi"}, "why": []})
        env = env_of(gpu.docker_bits(p))
        self.assertEqual((env["DRINODE"], env["DISABLE_DRI3"], env["AUTO_GPU"]), ("none", "true", "false"))
        self.assertTrue(all(kv.split("=", 1)[1] for kv in p["env"]))

    def test_force_on_passes_it_anyway(self):
        p = self.plan(NOTHING, mode="on")
        self.assertTrue(p["render"])
        self.assertIn("--device", p["args"])

    def test_off(self):
        p = self.plan(RENDER_OK, mode="off")
        self.assertEqual((p["args"], p["env"], p["label"]), ([], [], "off"))

    def test_tried_encode_then_gpu(self):
        p = self.plan(RENDER_AND_VAAPI, tried={"gpu-encode"})
        self.assertIsNone(p["encode"])
        self.assertTrue(p["render"])
        p = self.plan(RENDER_AND_VAAPI, tried={"gpu-encode", "gpu"})
        self.assertEqual(p["args"], [])
        self.assertEqual(p["label"], "auto:fallback-off")

    def test_unverified_dry_run_plan(self):
        p = gpu.plan("auto", None, rep=self.rep, probe=False)
        self.assertTrue(p["render"])
        self.assertTrue(any("not verified" in n for n in p["notes"]))

    def test_kasm_gets_device_only(self):
        p = gpu.plan("auto", "img", rep=self.rep, profile="kasm")
        self.assertIn("--device", p["args"])
        self.assertEqual(p["env"], [])

    def test_modes_from_older_forges(self):
        self.assertEqual(gpu.normalize_mode(True), "auto")
        self.assertEqual(gpu.normalize_mode(False), "off")
        self.assertEqual(gpu.normalize_mode(None), "auto")
        self.assertEqual(gpu.normalize_mode("force"), "on")
        self.assertEqual(gpu.normalize_mode("nonsense"), "auto")

    def test_mode_from_container(self):
        self.assertEqual(gpu.mode_from_container({"x.gpu": "auto:v3d:render:sw-enc"}, {}, "x.gpu"), "auto")
        self.assertEqual(gpu.mode_from_container({}, {"Devices": [{"PathOnHost": "/dev/dri"}]}, "x.gpu"),
                         "auto")
        self.assertEqual(gpu.mode_from_container({}, {}, "x.gpu"), "off")


class VerifyJudgeTest(unittest.TestCase):
    G = {"node": "/dev/dri/renderD128", "vendor": "broadcom"}

    def test_dri3_and_no_encoders(self):
        r = gpu.judge(gpu.parse_probe("dev=ok\nopen=ok\nglamor_flag=yes\ndri3=yes\nxlog=\nencoders={}\n"), self.G)
        self.assertTrue(r["render"])
        self.assertEqual(r["encoders"], {})

    def test_no_glamor_in_image(self):
        r = gpu.judge(gpu.parse_probe("dev=ok\nopen=ok\nglamor_flag=no\nencoders=unknown\n"), self.G)
        self.assertFalse(r["render"])
        self.assertIsNone(r["encoders"])

    def test_permission_denied(self):
        r = gpu.judge(gpu.parse_probe("dev=ok\nopen=denied\n"), self.G)
        self.assertFalse(r["render"])
        self.assertIn("cannot open", r["why"][0])

    def test_xvfb_crash(self):
        r = gpu.judge(gpu.parse_probe("dev=ok\nopen=ok\nglamor_flag=yes\ndri3=crashed\nxlog=glamor: EGL failed|\n"), self.G)
        self.assertFalse(r["render"])
        self.assertIn("crashed", r["why"][0])

    def test_vaapi_encoders(self):
        r = gpu.judge(gpu.parse_probe('dev=ok\nopen=ok\nglamor_flag=yes\ndri3=yes\nencoders={"h264": "vaapi"}\n'),
                      {"node": "/dev/dri/renderD128", "vendor": "intel"})
        self.assertEqual(r["encoders"], {"h264": "vaapi"})


class FallbackTest(unittest.TestCase):
    GP = {"mode": "auto", "label": "auto:i915:render:enc-vaapi", "render": True, "encode": "vaapi"}

    def test_encode_failure_drops_encoding_first(self):
        self.assertEqual(gpu.fallback("vaapi: failed to initialise", self.GP, set())[1], "gpu-encode")
        self.assertEqual(gpu.fallback("vaapi: failed to initialise", self.GP, {"gpu-encode"})[1], "gpu")
        self.assertIsNone(gpu.fallback("anything", self.GP, {"gpu-encode", "gpu"}))

    def test_render_crash_drops_gpu(self):
        gp = dict(self.GP, encode=None)
        self.assertEqual(gpu.fallback("glamor: failed", gp, set())[1], "gpu")

    def test_never_steps_back_in_on_mode_or_when_unused(self):
        self.assertIsNone(gpu.fallback("glamor", dict(self.GP, mode="on"), set()))
        self.assertIsNone(gpu.fallback("glamor", {"mode": "auto", "label": "auto:unused"}, set()))

    def test_health_ladder_uses_gpu_step_on_gpu_errors(self):
        prob = health.LaunchProblem("the session crashed", "crash", "glamor: failed to init EGL")
        opts = {"gpu_plan": dict(self.GP)}
        desc, key, apply = health.pick_fix(prob, {"memory_mb": 2048, "shm_mb": 1024}, opts,
                                           {"mem_total_mb": 8000, "mem_avail_mb": 6000}, set())
        self.assertEqual(key, "gpu")
        apply()
        self.assertIsNone(opts["gpu_plan"])
        self.assertEqual(opts["gpu_tried"], ["gpu"])

    def test_health_ladder_tries_seccomp_before_gpu_on_a_plain_crash(self):
        prob = health.LaunchProblem("the session crashed", "crash", "Segmentation fault")
        opts = {"gpu_plan": dict(self.GP)}
        tried = set()
        _d, key, _a = health.pick_fix(prob, {"memory_mb": 2048, "shm_mb": 1024}, opts,
                                      {"mem_total_mb": 8000}, tried)
        self.assertEqual(key, "seccomp")
        tried.add(key)
        opts["seccomp_unconfined"] = True
        _d, key, _a = health.pick_fix(prob, {"memory_mb": 2048, "shm_mb": 1024}, opts,
                                      {"mem_total_mb": 8000}, tried)
        self.assertEqual(key, "gpu")

    def test_shm_retry_grows_past_4g_on_big_machines_only_when_it_can(self):
        prob = health.LaunchProblem("crash", "crash", "No space left on device /dev/shm")
        plan = {"memory_mb": 5120, "shm_mb": 5120}
        fix = health.pick_fix(prob, plan, {}, {"mem_total_mb": 16000}, set())
        self.assertEqual(fix[1], "shm")
        fix[2]()
        self.assertEqual(plan["shm_mb"], 8000)
        plan = {"memory_mb": 1024, "shm_mb": 4096}
        fix = health.pick_fix(prob, plan, {}, {"mem_total_mb": 4000}, set())
        self.assertNotEqual(fix and fix[1], "shm")


class RunnerTest(unittest.TestCase):
    def test_no_gpu_option_means_no_devices_and_no_detection(self):
        e = catalog.BY_ID["noble-xfce"]
        with mock.patch.object(gpu, "plan", side_effect=AssertionError("must not plan")):
            args, _ = runner.docker_run_args(e, "forge-x", [1, 2], {"shm_mb": 512, "disk_mb": 1000},
                                             {}, "img", support.FAKE_HOST)
        self.assertNotIn("--device", args)
        self.assertTrue(any(a.endswith(".gpu=off") for a in args))

    def test_plan_is_applied(self):
        e = catalog.BY_ID["noble-xfce"]
        gp = {"label": "auto:v3d:render:sw-enc", "args": ["--device", "/dev/dri/renderD128:/dev/dri/renderD128",
                                                          "--group-add", "992"],
              "env": ["DRINODE=/dev/dri/renderD128", "DRI_NODE=none"]}
        args, _ = runner.docker_run_args(e, "forge-x", [1, 2], {"shm_mb": 512, "disk_mb": 1000},
                                         {"gpu_plan": gp}, "img", support.FAKE_HOST)
        self.assertIn("/dev/dri/renderD128:/dev/dri/renderD128", args)
        self.assertEqual(env_of(args)["DRI_NODE"], "none")
        self.assertTrue(any(a.endswith(".gpu=auto:v3d:render:sw-enc") for a in args))


if __name__ == "__main__":
    unittest.main()
