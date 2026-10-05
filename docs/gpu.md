# GPU Smart Passthrough

Every desktop can draw on your GPU, and encode its video stream on it, without you knowing what GPU you have or what the desktop image supports. The forge works it out, checks it inside the image before the desktop starts, hands Docker exactly what is needed, and steps back to software by itself if anything does not hold.

It is on by default (**Smart**). Nothing about a desktop that worked before gets worse: when a GPU cannot help a desktop, that desktop simply does not get it.

## What it does, in four steps

| Step | What happens | Touches |
|---|---|---|
| **Detect** | Reads `/sys/class/drm`: every render node, the kernel driver behind it, the PCI or devicetree vendor. Looks for the NVIDIA driver and whether Docker can use it (container toolkit or CDI), and for V4L2 hardware encoders. | Nothing; read-only file reads |
| **Verify** | Starts a throwaway container from the desktop's **own image**, as the **same unprivileged user** the desktop runs as, with **exactly the devices** it will get, and no network. Inside, it starts Xvfb with glamor on the render node and checks that DRI3 comes up (the GPU is really drawing), then asks pixelflux, the encoder Selkies uses, which codecs that node can encode. | A few seconds, once per image and GPU, then cached for 30 days |
| **Plan** | Gives the desktop one render node (not all of `/dev/dri`), the node's group, and settings that pin every GPU choice the base image would otherwise guess. | The `docker run` line |
| **Fall back** | If the desktop still fails to come up with the GPU, the launch retries with hardware encoding off, then with the GPU off, and writes each step to the log. | Only a failing launch |

### Why pinning matters

The Selkies base images guess. Two of those guesses are what makes "just pass `/dev/dri`" break desktops:

- **VA-API encoding is switched on for any `renderD128`** the image sees, unless an NVIDIA card is present. On a GPU without VA-API (a Raspberry Pi, most ARM boards, most VMs) that is a stream that fails or stutters while it keeps re-probing.
- **glamor is switched on for any render node.** On a GPU or driver that cannot do it, the X server falls over or draws garbage.

The plan sets each of these to what verify actually saw: `DRINODE` and `DISABLE_DRI3` for drawing, `DRI_NODE` and `SELKIES_GPU_ID` for encoding. "No" is written as `none`, never as an empty value: s6-overlay, which starts everything in these images, drops empty variables, and the image reads a missing `DRI_NODE` as "guess" and picks `renderD128`. `DRI_NODE=none` is something the image leaves alone and Selkies reads as "no hardware encoder", so it encodes in software without probing the GPU at start.

## Modes

| Mode | Web UI | CLI | Behaviour |
|---|---|---|---|
| **auto** (default) | *Smart* | `--gpu auto` | Uses what verify proves works; falls back on its own |
| **on** | *Force on* | `--gpu on` | Passes the best GPU through even if verify fails, never falls back. For testing |
| **off** | *Off* | `--no-gpu` / `--gpu off` | No devices; draws and encodes in software |

Pick a specific GPU with `--gpu-device`, by render node (`renderD129`), index (`1`), driver (`amdgpu`) or vendor (`intel`). Without it the forge ranks usable GPUs (NVIDIA, AMD, Intel, Apple, Qualcomm, Arm, Broadcom, … then virtual GPUs) and prefers the one the firmware booted on among equals.

## What it knows about

| GPU | Detected by | Drawing | Encoding |
|---|---|---|---|
| Intel (`i915`, `xe`) | driver, PCI `0x8086` | glamor / DRI3 | VA-API |
| AMD (`amdgpu`, `radeon`) | driver, PCI `0x1002` | glamor / DRI3 | VA-API |
| NVIDIA (proprietary) | driver, `/proc/driver/nvidia` | glamor / DRI3 via the NVIDIA GBM | NVENC |
| NVIDIA (`nouveau`) | driver | glamor (ranked low) | none |
| Raspberry Pi (`v3d`) | driver, `brcm,*` | glamor / DRI3 | Pi 4: V4L2 `bcm2835-codec`; Pi 5 has no hardware encoder |
| Arm Mali (`panfrost`, `panthor`, `lima`) | driver, devicetree | glamor / DRI3 | V4L2 if the SoC has an encoder |
| Qualcomm Adreno (`msm`) | driver, `qcom,*` | glamor / DRI3 | V4L2 (venus) |
| Apple (`asahi`), Vivante (`etnaviv`), PowerVR, Tegra | driver, devicetree | glamor / DRI3 | Tegra: its own |
| virtio-gpu, VMware SVGA | driver, PCI | only if the VM gives it 3D (virgl); verify decides | none |
| Firmware framebuffers, QEMU/Cirrus VGA, BMCs | driver, PCI | never used: they cannot draw 3D | none |

"Drawing" and "Encoding" are what the forge tries; **verify is what decides**. A GPU whose node the desktop user cannot open, an image whose X server has no glamor, a driver that crashes Xvfb: each is caught before the desktop starts, and the reason is in the launch log.

### NVIDIA

The NVIDIA driver alone is not enough: Docker needs the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html). The forge uses `--gpus all` when the toolkit or the `nvidia` runtime is installed, and `--device nvidia.com/gpu=all` when only CDI specs exist. Without either, the NVIDIA GPU is reported (with the install hint) and left out, so the desktop runs in software instead of failing.

## Seeing what it decided

```bash
selkies-cli engine gpu                                   # what this machine has
python3 ~/.selkies-forge/app/engine.py gpu --image lscr.io/linuxserver/webtop:ubuntu-xfce
python3 ~/.selkies-forge/app/engine.py gpu --json        # for scripts
```

```
GPU Smart Passthrough

  * /dev/dri/renderD128  Broadcom VideoCore             driver v3d          usable
      brcm,2712-v3d

  Broadcom VideoCore (v3d) on renderD128

  lscr.io/linuxserver/webtop:ubuntu-xfce  ->  auto:v3d:render:sw-enc
    - Broadcom VideoCore (v3d) on renderD128: draws on the GPU (DRI3)
    - no hardware video encoder on this GPU; video is encoded in software
    docker run ... --device /dev/dri/renderD128:/dev/dri/renderD128 --group-add 992
                   -e DRINODE=/dev/dri/renderD128 -e DISABLE_DRI3=false -e DRI_NODE=none -e SELKIES_GPU_ID=-1
```

Every launch logs the same lines (`gpu      : …`), and once the desktop is up it confirms from the desktop's own log that it is drawing on the GPU (`DRI3 is up`). Each container carries a label, `io.selkiesforge.gpu`, such as `auto:v3d:render:sw-enc`, `auto:amdgpu:render:enc-vaapi`, `auto:unused` or `off`. The web UI shows the detected GPU under the GPU option, and `GET /api/gpu` returns the full report.

## Recreate, retune, restore

A recreate (changing `/dev/shm`, the screen mode, a repair) keeps the desktop's GPU mode and plans again from scratch, so a new driver, a moved card or an updated image is picked up. Old GPU settings are dropped first, never carried over. Desktops made by older forges with *Pass the GPU through* on become **auto**; ones without it stay **off**.

## Troubleshooting

| You see | Meaning |
|---|---|
| `this image's X server has no GPU drawing (no glamor)` | The image is too old for GPU drawing. A newer pull of the same image usually has it (LinuxServer added glamor to Xvfb in 2026) |
| `the desktop user cannot open /dev/dri/renderD128` | The node is not group read/write on the host. `ls -l /dev/dri`; a udev rule or `sudo chmod g+rw` fixes it |
| `NVIDIA … found, but Docker cannot use it yet` | Install the NVIDIA Container Toolkit, then `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` |
| `no hardware video encoder on this GPU` | Normal on a Raspberry Pi 5, most ARM boards and VMs: drawing is on the GPU, the stream is encoded in software (x264) |
| `auto-fix : … retrying without it` | The desktop failed with the GPU and came up without it. The log above that line shows why |

To re-run a cached check after changing drivers: `engine.py gpu --image IMAGE --fresh`.
