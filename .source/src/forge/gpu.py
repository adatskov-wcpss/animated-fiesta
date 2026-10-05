"""
Selkies Forge engine - gpu

GPU Smart Passthrough: find every GPU on this machine, work out what each one
can really do inside a desktop, hand Docker exactly that and nothing more, and
step back to software the moment something does not hold.

Four stages, each one safe on its own:

  detect   read-only: sysfs render nodes, kernel drivers, PCI / devicetree
           vendors, the NVIDIA driver and container toolkit, V4L2 encoders.
           Nothing is opened or loaded on the host.
  verify   inside the desktop's own image, as the same unprivileged user the
           desktop runs as, with exactly the devices it will get: start Xvfb
           with glamor on the render node and check DRI3 came up (GPU drawing),
           and ask pixelflux which codecs the node can encode (what Selkies
           itself asks). Cached per image + GPU + kernel, so it runs once.
  plan     the docker arguments: one render node (not all of /dev/dri), its
           group, and settings that pin the base image's guesses ("none",
           never empty: s6-overlay drops empty variables). The base
           image switches VA-API encoding on for any renderD128 it sees and
           glamor on for any render node; on a GPU that cannot do one of them
           (a Raspberry Pi has no VA-API, many VMs have no 3D) that guess is
           what breaks the stream. The plan sets each one to what verify saw.
  fall back
           if a desktop still fails with the GPU on, the launch retries with
           hardware encoding off, then with the GPU off (health.pick_fix).

Modes (opts["gpu"]): "auto" (default) uses what verify proves works; "on"
passes the best GPU through even if verify fails, and never falls back; "off"
passes nothing. True / False from older forges mean "auto" / "off".
"""

import json
import os
import re
import shlex
import uuid

from .util import cache_get, cache_put, have, run


MODES = ("auto", "on", "off")

# kernel driver -> (vendor key, vendor name, can draw 3D)
DRIVERS = {
    "i915": ("intel", "Intel", True),
    "xe": ("intel", "Intel", True),
    "amdgpu": ("amd", "AMD", True),
    "radeon": ("amd", "AMD (radeon)", True),
    "nvidia": ("nvidia", "NVIDIA", True),
    "nvidia-drm": ("nvidia", "NVIDIA", True),
    "nouveau": ("nouveau", "NVIDIA (nouveau)", True),
    "v3d": ("broadcom", "Broadcom VideoCore", True),
    "vc4": ("broadcom", "Broadcom VideoCore", True),
    "panfrost": ("arm", "Arm Mali", True),
    "panthor": ("arm", "Arm Mali", True),
    "lima": ("arm", "Arm Mali (Utgard)", True),
    "mali": ("arm", "Arm Mali (vendor driver)", False),
    "mali_kbase": ("arm", "Arm Mali (vendor driver)", False),
    "msm": ("qualcomm", "Qualcomm Adreno", True),
    "msm_drm": ("qualcomm", "Qualcomm Adreno", True),
    "virtio_gpu": ("virtio", "virtio-gpu (virtual machine)", True),
    "virtio-pci": ("virtio", "virtio-gpu (virtual machine)", True),
    "vmwgfx": ("vmware", "VMware SVGA", True),
    "etnaviv": ("vivante", "Vivante", True),
    "asahi": ("apple", "Apple AGX", True),
    "powervr": ("imagination", "Imagination PowerVR", True),
    "pvrsrvkm": ("imagination", "Imagination PowerVR (vendor driver)", False),
    "tegra": ("tegra", "NVIDIA Tegra", True),
    "nvgpu": ("tegra", "NVIDIA Tegra", True),
    "host1x": ("tegra", "NVIDIA Tegra", True),
    "rockchip-drm": ("rockchip", "Rockchip display", False),
    "mediatek-drm": ("mediatek", "MediaTek display", False),
    "simple-framebuffer": ("simple", "firmware framebuffer", False),
    "simpledrm": ("simple", "firmware framebuffer", False),
    "bochs-drm": ("bochs", "QEMU standard VGA", False),
    "bochs": ("bochs", "QEMU standard VGA", False),
    "cirrus": ("cirrus", "Cirrus VGA", False),
    "cirrus-qemu": ("cirrus", "Cirrus VGA", False),
    "ast": ("aspeed", "ASPEED BMC", False),
    "mgag200": ("matrox", "Matrox G200", False),
    "hyperv_drm": ("hyperv", "Hyper-V display", False),
}

PCI_VENDORS = {
    "0x8086": ("intel", "Intel", True),
    "0x1002": ("amd", "AMD", True),
    "0x10de": ("nvidia", "NVIDIA", True),
    "0x1af4": ("virtio", "virtio-gpu (virtual machine)", True),
    "0x15ad": ("vmware", "VMware SVGA", True),
    "0x1234": ("bochs", "QEMU standard VGA", False),
    "0x1013": ("cirrus", "Cirrus VGA", False),
    "0x1a03": ("aspeed", "ASPEED BMC", False),
    "0x102b": ("matrox", "Matrox G200", False),
    "0x1414": ("hyperv", "Hyper-V display", False),
}

# devicetree vendor prefix -> vendor key, for SoC GPUs with no PCI ids
DT_VENDORS = {"brcm": "broadcom", "arm": "arm", "qcom": "qualcomm", "rockchip": "rockchip",
              "amlogic": "arm", "allwinner": "arm", "mediatek": "mediatek", "apple": "apple",
              "nvidia": "tegra", "vivante": "vivante", "img": "imagination", "samsung": "arm"}

# Which GPU to hand a desktop when there are several: the one most likely to
# both draw and encode well.
RANK = {"nvidia": 100, "amd": 80, "intel": 70, "apple": 60, "qualcomm": 55, "arm": 50,
        "broadcom": 45, "tegra": 40, "imagination": 35, "vivante": 32, "virtio": 30,
        "vmware": 25, "nouveau": 20}

# The hardware encoder a vendor's GPU usually has. verify decides for real.
ENCODE_BACKEND = {"nvidia": "nvenc", "intel": "vaapi", "amd": "vaapi", "tegra": "tegra"}

# A stateful V4L2 memory-to-memory encoder (Raspberry Pi 4, Rockchip, Qualcomm,
# MediaTek, Allwinner). Decoders, ISPs and cameras are left alone.
V4L2_ENCODER = re.compile(r"enc(ode)?r?\b|-enc\b|_enc\b|vepu|venus-enc|h264.*enc", re.I)
V4L2_NOT = re.compile(r"(?:^|[-_\s])(?:dec|decode|decoder|isp)(?:$|[-_\s])|"
                      r"image_fx|camera|unicam|\bcsi|pispbe", re.I)

# Lines in a desktop's log that point at the GPU when it fails to come up.
GPU_HINTS = re.compile(
    r"glamor|dri3|\bdrm\b|drmOpen|render ?node|/dev/dri|\begl\b|EGL_|libEGL|libGL\b|"
    r"\bmesa\b|MESA-LOADER|failed to load driver|gbm|vaapi|va-api|libva|vainfo|"
    r"nvenc|nvidia|cuda|libcuda|NVML|amdgpu|i915|\bv3d\b|panfrost|zink|"
    r"GPU process|gpu_init|Exiting GPU process", re.I)
ENCODE_HINTS = re.compile(r"vaapi|va-api|libva|nvenc|cuda|v4l2.*enc|encoder.*(fail|error)|"
                          r"hardware encod", re.I)

# Every environment key the plan may set; a recreate drops the old values.
ENV_KEYS = ("DRINODE", "DRI_NODE", "DISABLE_DRI3", "LIBVA_DRIVER_NAME", "SELKIES_GPU_ID",
            "SELKIES_ENCODE_DRI", "NVIDIA_VISIBLE_DEVICES", "NVIDIA_DRIVER_CAPABILITIES",
            "AUTO_GPU")

VERIFY_TTL = 30 * 86400
HOST_TTL = 600


def normalize_mode(value):
    """'auto' / 'on' / 'off' from whatever an older forge, the CLI or the UI sent."""
    if value is True:
        return "auto"
    if value is False or value is None:
        return "off" if value is False else "auto"
    v = str(value).strip().lower()
    if v in ("1", "yes", "true", "smart", ""):
        return "auto"
    if v in ("0", "no", "false", "none", "disable", "disabled"):
        return "off"
    if v in ("force", "always"):
        return "on"
    return v if v in MODES else "auto"


# ------------------------------------------------------------------ detect --

def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace").strip("\x00\n ")
    except OSError:
        return ""


def _real(path):
    try:
        return os.path.realpath(path)
    except OSError:
        return ""


def _classify(driver, pci_vendor, compatible):
    if driver in DRIVERS:
        return DRIVERS[driver]
    if pci_vendor in PCI_VENDORS:
        return PCI_VENDORS[pci_vendor]
    for comp in compatible:
        prefix = comp.split(",", 1)[0]
        if prefix in DT_VENDORS:
            key = DT_VENDORS[prefix]
            return key, prefix.capitalize() + " GPU", True
    return "unknown", driver or "unknown GPU", True


def detect_gpus(sysfs="/sys", dev="/dev"):
    """Every DRM render node, with what drives it. Read-only."""
    drm = os.path.join(sysfs, "class", "drm")
    try:
        names = sorted(os.listdir(drm))
    except OSError:
        return []
    cards = {}
    for n in names:
        if re.match(r"^card\d+$", n):
            cards[_real(os.path.join(drm, n, "device"))] = n
    out = []
    for n in names:
        m = re.match(r"^renderD(\d+)$", n)
        if not m:
            continue
        devdir = os.path.join(drm, n, "device")
        real = _real(devdir)
        driver = os.path.basename(_real(os.path.join(devdir, "driver"))) if \
            os.path.exists(os.path.join(devdir, "driver")) else ""
        pci_vendor = _read(os.path.join(devdir, "vendor")).lower()
        pci_device = _read(os.path.join(devdir, "device")).lower()
        compatible = [c for c in _read(os.path.join(devdir, "of_node", "compatible")).split("\x00") if c]
        vendor, vname, can_3d = _classify(driver, pci_vendor, compatible)
        node = os.path.join(dev, "dri", n)
        try:
            st = os.stat(node)
            gid, mode = st.st_gid, st.st_mode
        except OSError:
            gid, mode = None, 0
        card = cards.get(real)
        out.append({
            "node": node,
            "index": int(m.group(1)) - 128,
            "card": os.path.join(dev, "dri", card) if card else None,
            "driver": driver or None,
            "vendor": vendor,
            "vendor_name": vname,
            "can_3d": bool(can_3d),
            "pci": ("%s:%s" % (pci_vendor, pci_device)) if pci_vendor.startswith("0x") else None,
            "compatible": compatible[:3],
            "gid": gid,
            "group_rw": bool(mode & 0o060 == 0o060),
            "boot_vga": _read(os.path.join(devdir, "boot_vga")) == "1",
            "exists": gid is not None,
        })
    return out


def detect_v4l2_encoders(sysfs="/sys", dev="/dev"):
    """V4L2 hardware video encoders (a Pi 4's bcm2835-codec, Rockchip, ...)."""
    base = os.path.join(sysfs, "class", "video4linux")
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    out = []
    for n in names:
        label = _read(os.path.join(base, n, "name"))
        if label and V4L2_ENCODER.search(label) and not V4L2_NOT.search(label):
            path = os.path.join(dev, n)
            try:
                gid = os.stat(path).st_gid
            except OSError:
                continue
            out.append({"node": path, "name": label, "gid": gid})
    return out


def detect_nvidia(proc="/proc", docker_info=None):
    """The NVIDIA kernel driver, and whether Docker can hand it to a container."""
    ver = _read(os.path.join(proc, "driver", "nvidia", "version"))
    out = {"driver": None, "toolkit": False, "runtime": False, "cdi": False, "how": None}
    if not ver:
        return out
    m = re.search(r"Kernel Module(?: for [\w.]+)?\s+([\d.]+)", ver)
    out["driver"] = m.group(1) if m else "present"
    out["toolkit"] = any(have(p) for p in ("nvidia-container-runtime-hook", "nvidia-container-cli",
                                            "nvidia-ctk", "nvidia-container-runtime"))
    if docker_info is None:
        rc, txt, _ = run(["docker", "info", "--format", "{{json .Runtimes}}|{{json .CDISpecDirs}}"],
                         timeout=25)
        docker_info = txt if rc == 0 else ""
    out["runtime"] = '"nvidia"' in (docker_info or "")
    for d in ("/etc/cdi", "/var/run/cdi"):
        try:
            if any("nvidia" in f for f in os.listdir(d)):
                out["cdi"] = True
        except OSError:
            pass
    if out["toolkit"] or out["runtime"]:
        out["how"] = "gpus"
    elif out["cdi"]:
        out["how"] = "cdi"
    return out


def host_gpus(fresh=False):
    """Everything detect knows about this machine, cached for a few minutes."""
    cached = None if fresh else cache_get("gpu-host", HOST_TTL)
    if cached:
        return cached
    gpus = detect_gpus()
    nv = detect_nvidia() if any(g["vendor"] == "nvidia" for g in gpus) or \
        os.path.exists("/proc/driver/nvidia/version") else {"driver": None}
    rep = {"gpus": gpus, "nvidia": nv, "v4l2": detect_v4l2_encoders(),
           "kernel": os.uname().release}
    best = pick(rep)
    rep["primary"] = best["node"] if best else None
    rep["summary"] = describe(rep)
    cache_put("gpu-host", rep)
    return rep


def usable(g, rep):
    """Can this GPU be handed to a container at all?"""
    if not g.get("exists") or not g.get("can_3d"):
        return False
    if g["vendor"] == "nvidia" and g.get("driver") in ("nvidia", "nvidia-drm"):
        return bool((rep.get("nvidia") or {}).get("how"))
    return True


def pick(rep, want=None):
    """The GPU a desktop gets: the one named in `want` (a node, an index, a
    driver or a vendor), else the best ranked usable one."""
    gpus = [g for g in rep.get("gpus") or [] if usable(g, rep)]
    if want:
        w = str(want).lower()
        for g in rep.get("gpus") or []:
            if w in (g["node"].lower(), os.path.basename(g["node"]).lower(), str(g["index"]),
                     (g.get("driver") or "").lower(), g["vendor"]):
                return g
    if not gpus:
        return None
    return sorted(gpus, key=lambda g: (-RANK.get(g["vendor"], 10), not g.get("boot_vga"),
                                       g["index"]))[0]


def describe(rep):
    g = next((x for x in rep.get("gpus") or [] if x["node"] == rep.get("primary")), None)
    if g:
        return "%s (%s) on %s" % (g["vendor_name"], g.get("driver") or "?",
                                  os.path.basename(g["node"]))
    gs = rep.get("gpus") or []
    nv = rep.get("nvidia") or {}
    if nv.get("driver") and not nv.get("how"):
        return "NVIDIA %s found, but Docker cannot use it yet (install nvidia-container-toolkit)" \
            % nv["driver"]
    if gs:
        return "no GPU that can draw in a container (%s)" % ", ".join(
            "%s on %s" % (x["vendor_name"], os.path.basename(x["node"])) for x in gs)
    return "no GPU found; desktops draw and encode in software"


# ------------------------------------------------------------------ verify --

PROBE_SCRIPT = r'''
N="$1"; IDX="$2"
say() { echo "$1=$2"; }
[ -c "$N" ] || { say dev missing; exit 0; }
say dev ok
( exec 3<>"$N" ) 2>/dev/null && say open ok || say open denied
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -L >/tmp/nv.txt 2>&1 && say nvsmi "$(head -1 /tmp/nv.txt | cut -c1-80)" || say nvsmi fail
fi
mkdir -p /tmp/gp
if command -v Xvfb >/dev/null 2>&1; then
  if Xvfb -help 2>&1 | grep -q -- '-glamor'; then
    say glamor_flag yes
    D=":$(( 87 + $$ % 7 ))"
    Xvfb "$D" -glamor -dri "$N" -nolisten tcp +extension GLX >/tmp/gp/x.log 2>&1 &
    P=$!
    i=0; up=no
    while [ $i -lt 24 ]; do
      sleep 0.5; i=$((i + 1))
      kill -0 $P 2>/dev/null || break
      if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$D" xdpyinfo >/tmp/gp/d.txt 2>/dev/null && { up=yes; break; }
      elif [ $i -ge 8 ]; then up=yes; break; fi
    done
    if kill -0 $P 2>/dev/null; then
      if command -v xdpyinfo >/dev/null 2>&1; then
        if [ "$up" = yes ] && grep -q DRI3 /tmp/gp/d.txt; then say dri3 yes; else say dri3 no; fi
      else say dri3 unknown; fi
    else say dri3 crashed; fi
    kill $P 2>/dev/null; wait $P 2>/dev/null
    say xlog "$(grep -iE 'glamor|egl|dri|drm|fail|error|fatal' /tmp/gp/x.log | grep -v 'removed in XLibre' | tail -4 | tr '\n' '|' | cut -c1-400)"
  else say glamor_flag no; fi
else say xvfb none; fi
PY=""
for p in /lsiopy/bin/python3 python3; do command -v "$p" >/dev/null 2>&1 && { PY="$p"; break; }; done
if [ -n "$PY" ]; then
  "$PY" - "$IDX" <<'PYEOF' 2>/dev/null || say encoders unknown
import json, sys
try:
    import pixelflux
except ImportError:
    print("encoders=unknown"); sys.exit(0)
f = getattr(pixelflux, "hardware_encoders", None)
if f is None:
    print("encoders=unknown"); sys.exit(0)
try:
    print("encoders=" + json.dumps(dict(f(int(sys.argv[1]), "true"))))
except Exception as e:
    print("encoders=error:%s" % str(e)[:120])
PYEOF
else say encoders unknown; fi
'''


def parse_probe(text):
    out = {}
    for line in (text or "").splitlines():
        k, sep, v = line.partition("=")
        if sep and re.match(r"^[a-z_0-9]+$", k):
            out[k] = v.strip()
    return out


def judge(raw, g):
    """What a probe's raw key=value output means for this GPU."""
    res = {"render": False, "encoders": {}, "why": [], "raw": raw}
    if raw.get("dev") != "ok":
        res["why"].append("the device did not show up inside the container")
        return res
    if raw.get("open") == "denied":
        res["why"].append("the desktop user cannot open %s (group permissions)" % g["node"])
        return res
    if g["vendor"] == "nvidia" and raw.get("nvsmi", "fail") == "fail":
        res["why"].append("nvidia-smi does not work inside the container")
    dri3 = raw.get("dri3")
    if raw.get("glamor_flag") == "no":
        res["why"].append("this image's X server has no GPU drawing (no glamor); "
                          "a newer build of the image may")
    elif raw.get("xvfb") == "none":
        res["why"].append("this image has no Xvfb to draw with")
    elif dri3 == "yes":
        res["render"] = True
    elif dri3 == "unknown":
        bad = re.search(r"fail|error|fatal|cannot", raw.get("xlog", ""), re.I)
        res["render"] = not bad
        if bad:
            res["why"].append("the X server could not draw on the GPU: %s" % raw.get("xlog"))
    elif dri3 == "crashed":
        res["why"].append("the X server crashed when drawing on the GPU: %s" % raw.get("xlog", ""))
    else:
        res["why"].append("the X server started but GPU drawing (DRI3) did not come up: %s"
                          % (raw.get("xlog") or "no detail"))
    enc = raw.get("encoders", "unknown")
    if enc.startswith("{"):
        try:
            res["encoders"] = {str(k): str(v) for k, v in json.loads(enc).items()}
        except ValueError:
            pass
        if not res["encoders"]:
            res["why"].append("no hardware video encoder on this GPU; video is encoded "
                              "in software")
    elif enc == "unknown":
        res["encoders"] = None
    return res


def probe_args(image, g, rep, uid=None, gid=None):
    """The `docker run` for a verify probe: the desktop's image, its devices,
    its user, no network, a small memory cap."""
    uid = os.getuid() if uid is None else uid
    gid = os.getgid() if gid is None else gid
    name = "forge-gpuprobe-%s" % uuid.uuid4().hex[:8]
    args = ["docker", "run", "--rm", "--name", name, "--network", "none",
            "--memory", "512m", "--user", "%d:%d" % (uid, gid), "-e", "HOME=/tmp"]
    args += device_args(g, rep)
    args += ["--entrypoint", "sh", image, "-c", PROBE_SCRIPT, "probe", g["node"],
             str(max(0, g["index"]))]
    return name, args


def device_args(g, rep, encode_v4l2=False):
    """Exactly the devices and groups one GPU needs."""
    args = ["--device", "%s:%s" % (g["node"], g["node"])]
    gids = set()
    if g.get("gid") is not None:
        gids.add(g["gid"])
    if g["vendor"] == "nvidia" and g.get("driver") in ("nvidia", "nvidia-drm"):
        how = (rep.get("nvidia") or {}).get("how")
        if how == "cdi":
            args += ["--device", "nvidia.com/gpu=all"]
        else:
            args += ["--gpus", "all"]
        args += ["-e", "NVIDIA_VISIBLE_DEVICES=all", "-e", "NVIDIA_DRIVER_CAPABILITIES=all"]
    if encode_v4l2:
        for v in rep.get("v4l2") or []:
            args += ["--device", "%s:%s" % (v["node"], v["node"])]
            gids.add(v["gid"])
    for x in sorted(gids):
        if x:
            args += ["--group-add", str(x)]
    return args


def image_id(image):
    rc, out, _ = run(["docker", "image", "inspect", "--format", "{{.Id}}", image], timeout=20)
    return out.strip() if rc == 0 else None


def verify(image, g, rep, job=None, fresh=False):
    """Run (or recall) the probe for this image on this GPU."""
    iid = image_id(image) or image
    key = "gpu-verify:%s:%s:%s:%s" % (iid[-24:], g["node"], g.get("driver"), rep.get("kernel"))
    if not fresh:
        hit = cache_get(key, VERIFY_TTL)
        if hit:
            hit["cached"] = True
            return hit
    name, args = probe_args(image, g, rep)
    if job:
        job.log("gpu      : checking %s inside the image (one time, a few seconds)"
                % os.path.basename(g["node"]))
    rc, out, err = run(["timeout", "75"] + args, timeout=90)
    if rc != 0 and not out.strip():
        run(["docker", "rm", "-f", name], timeout=30)
        res = {"render": False, "encoders": {}, "probe_failed": True,
               "why": ["the GPU check could not run: %s" % ((err or "").strip().splitlines() or
                                                             ["exit %d" % rc])[-1][:200]]}
    else:
        res = judge(parse_probe(out), g)
    res["cached"] = False
    if not res.get("probe_failed"):
        cache_put(key, res)
    return res


# -------------------------------------------------------------------- plan --

def plan(mode, image, host=None, profile="selkies", job=None, tried=(), want=None,
         probe=True, rep=None):
    """Decide what one desktop gets. Returns a dict with `args` (devices,
    groups), `env`, a short `label`, and `notes` for the launch log."""
    mode = normalize_mode(mode)
    tried = set(tried or ())
    out = {"mode": mode, "gpu": None, "render": False, "encode": None, "args": [], "env": [],
           "label": "off", "notes": []}
    if mode == "off" or "gpu" in tried:
        if "gpu" in tried and mode != "off":
            out["notes"].append("GPU off for this desktop: it did not start cleanly with it")
        out["label"] = "off" if mode == "off" else "auto:fallback-off"
        return out
    rep = rep or host_gpus()
    g = pick(rep, want)
    if not g:
        out["notes"].append(rep.get("summary") or "no usable GPU")
        out["label"] = "%s:none" % mode
        return out
    out["gpu"] = {k: g.get(k) for k in ("node", "driver", "vendor", "vendor_name", "index")}
    v4l2 = bool(rep.get("v4l2"))

    if profile == "kasm":
        # KasmVNC images find a render node on their own; give them the one.
        out["args"] = device_args(g, rep)
        out["render"] = True
        out["label"] = "%s:%s:kasm" % (mode, g.get("driver") or g["vendor"])
        out["notes"].append("%s passed to the image; KasmVNC uses it if it can"
                            % g["vendor_name"])
        return out

    res = None
    if probe and image:
        res = verify(image, g, rep, job=job)
    if res is None:
        # Not verified (a dry run): say what detection expects.
        render = bool(g.get("can_3d"))
        encoders = None
        encode_ok = g["vendor"] in ENCODE_BACKEND and "gpu-encode" not in tried
        out["notes"].append("not verified yet; the real launch checks it inside the image")
    else:
        render = bool(res.get("render")) or (mode == "on")
        encoders = res.get("encoders")
        encode_ok = bool(encoders) and "gpu-encode" not in tried
        if mode == "on" and encoders is None and "gpu-encode" not in tried:
            encode_ok = g["vendor"] in ENCODE_BACKEND

    if mode == "auto" and res is not None and not render and not encode_ok:
        out["notes"] += (res.get("why") or [])
        out["notes"].append("nothing on %s helps this image, so it is left out"
                            % os.path.basename(g["node"]))
        out["label"] = "auto:unused"
        out["verify"] = res
        return out

    # "none", never an empty value: s6-overlay drops empty variables, and the
    # base image reads a missing one as "guess" (it then picks renderD128).
    # Selkies reads a value that is not a /dev/dri path as "no device".
    env = []
    if render:
        env += ["DRINODE=%s" % g["node"], "DISABLE_DRI3=false"]
    else:
        env += ["DRINODE=none", "DISABLE_DRI3=true", "AUTO_GPU=false"]
    if encode_ok:
        backend = sorted(set((encoders or {}).values())) or [ENCODE_BACKEND.get(g["vendor"], "?")]
        env += ["DRI_NODE=%s" % g["node"], "SELKIES_GPU_ID=%d" % max(0, g["index"])]
        out["encode"] = ",".join(backend)
    else:
        # Pin it: the base image would otherwise switch VA-API on for this
        # node by itself, and Selkies would probe it at every start.
        env += ["DRI_NODE=none", "SELKIES_GPU_ID=-1"]
    out["args"] = device_args(g, rep, encode_v4l2=encode_ok and v4l2 and
                              "v4l2" in set((encoders or {}).values()))
    out["env"] = env
    out["render"] = render
    out["verify"] = res
    parts = [g.get("driver") or g["vendor"]]
    parts.append("render" if render else "no-render")
    parts.append("enc-" + out["encode"] if out["encode"] else "sw-enc")
    out["label"] = "%s:%s" % (mode, ":".join(parts))
    what = []
    if render:
        what.append("draws on the GPU (DRI3)")
    if out["encode"]:
        what.append("encodes video on it (%s)" % out["encode"])
    out["notes"].append("%s: %s" % (rep.get("summary"), ", ".join(what) or
                                    "passed through as asked (mode on)"))
    if res:
        out["notes"] += [w for w in res.get("why") or [] if render or encode_ok]
        if res.get("cached"):
            out["notes"].append("(checked before for this image; not re-run)")
    return out


def docker_bits(gp):
    """Flatten a plan into docker run arguments."""
    if not gp:
        return []
    args = list(gp.get("args") or [])
    for kv in gp.get("env") or []:
        args += ["-e", kv]
    return args


def mode_from_container(labels, hostcfg, label_key):
    """The mode an existing container was made with (for a recreate)."""
    lab = (labels or {}).get(label_key)
    if lab:
        return normalize_mode(lab.split(":", 1)[0])
    devs = [d.get("PathOnHost", "") for d in (hostcfg.get("Devices") or [])]
    return "auto" if any(p.startswith("/dev/dri") for p in devs) else "off"


# ------------------------------------------------------------ fall back --

def fallback(problem_text, gp, tried):
    """The next GPU step back after a failed start, or None.

    Returns (description, key) with key "gpu-encode" (keep drawing on the
    GPU, encode in software) or "gpu" (no GPU at all)."""
    if not gp or gp.get("mode") == "on" or gp.get("label", "").endswith((":none", ":unused")):
        return None
    if gp.get("mode") == "off" or not (gp.get("render") or gp.get("encode")):
        return None
    text = problem_text or ""
    if gp.get("encode") and "gpu-encode" not in tried and ENCODE_HINTS.search(text):
        return ("hardware video encoding failed; keeping the GPU for drawing and "
                "encoding in software", "gpu-encode")
    if "gpu" not in tried:
        return ("the desktop did not start cleanly with the GPU; retrying without it", "gpu")
    return None


def report(fresh=True):
    """A human report for `engine.py gpu` and the web UI."""
    rep = host_gpus(fresh=fresh)
    lines = ["GPU Smart Passthrough", ""]
    if not rep["gpus"]:
        lines.append("  no DRM render nodes on this machine: desktops draw and encode in software")
    for g in rep["gpus"]:
        star = "*" if g["node"] == rep.get("primary") else " "
        lines.append("  %s %-20s %-30s driver %-12s %s" % (
            star, g["node"], g["vendor_name"], g.get("driver") or "?",
            ("usable" if usable(g, rep) else "not usable in a container")))
        if g.get("pci"):
            lines.append("      pci %s" % g["pci"])
        elif g.get("compatible"):
            lines.append("      %s" % ", ".join(g["compatible"]))
        if not g.get("group_rw"):
            lines.append("      note: %s is not group read/write on the host" % g["node"])
    nv = rep.get("nvidia") or {}
    if nv.get("driver"):
        lines.append("")
        lines.append("  NVIDIA driver %s, container access: %s" % (
            nv["driver"], {"gpus": "--gpus (nvidia-container-toolkit)",
                           "cdi": "CDI (nvidia.com/gpu=all)"}.get(nv.get("how"),
                                                                    "none - install nvidia-container-toolkit")))
    for v in rep.get("v4l2") or []:
        lines.append("  V4L2 encoder %s (%s)" % (v["node"], v["name"]))
    lines += ["", "  " + rep["summary"]]
    return {"text": "\n".join(lines), "host": rep}


def shell_quote_args(args):
    return " ".join(shlex.quote(a) for a in args)
