# FAQ

**Is this a virtual machine?**
No. Each desktop is a Docker container running a real Linux userland with an X server (Xvfb) and a desktop environment. [Selkies](https://github.com/selkies-project/selkies) streams it to your browser over WebRTC or WebSockets. It's much lighter than a VM, and shares the host's kernel.

**Does it work on a Raspberry Pi?**
Yes. It's developed and tested on a Raspberry Pi with arm64 Ubuntu. 148 of the 153 desktops have arm64 images. A Pi 4/5 with 4–8 GB runs the light and balanced desktops comfortably.

**How many desktops can I run at once?**
As many as memory allows. Each has a memory cap, the forge refuses to start one the machine plainly can't hold, and it never builds more than one at a time.

**Where are my files?**
In the desktop's `/config` (its home folder), a Docker volume named `forge-config-<name>`. It survives restarts, limit changes and **Repair**. Removing a desktop keeps it unless you choose to delete it.

**Why are some desktops "fixed size"?**
Enlightenment, Cinnamon, Budgie, GNOME Flashback and UKUI are compositing window managers. Under a virtual X server they misdraw, or leave parts of the screen behind, when the screen changes size. Running them at a fixed size and letting Selkies scale the picture avoids that completely. You can switch any desktop to the other mode.

**What happens on a phone, a Retina laptop or a 4K screen?**
Left alone, Selkies would raise the desktop's DPI to match the screen (264 on a phone), and panels sized in pixels would overflow with text: the Xfce top bar is the classic case. The forge's [screen guard](forge-layer.md#the-screen-guard-hidpi-phones-and-4k) spots a high-density or 4K screen in your browser, keeps the desktop at 96 DPI and about 1920 wide, and scales it to the screen. Ordinary screens at 100% aren't touched.

**Can I back up a desktop, or make a copy of one?**
Yes. **Back up files** and **Clone…** in the manager's menu, or `selkies-cli backup NAME` and `selkies-cli clone NAME`. A backup is the desktop's home folder, and can become a new desktop later even if the original is gone. See [Backups](operations.md#backups).

**Will a desktop I forgot about keep eating memory?**
Only if you let it. Set **Stop when nobody's watching** when you forge it, or `FORGE_IDLE_STOP_MIN` for all of them, and the forge stops a desktop no browser tab has had open for that long. Its files are kept.

**Why Alt instead of the Super key in i3 and bspwm?**
Browsers and host operating systems usually catch the Super (Windows) key before it reaches the desktop.

**Can I use my GPU?**
*Pass the GPU through* gives the desktop `/dev/dri`, so Intel and AMD GPUs can be used for rendering. Without it, rendering is in software (llvmpipe), which is fine for desktop work.

**Why do Kasm desktops get a different kind of link?**
Kasm images serve HTTPS with their own login, so they're tunnelled over TCP rather than HTTP. Anonymous serveo TCP tunnels are short-lived. The local link has no limits.

**What does "healed" mean in the events?**
The desktop crashed while the forge was watching, and the watchdog started it again. It does that up to three times an hour, and never after a deliberate stop or a reboot.

**Can I change it, rename it, ship my own version?**
Yes. It's MIT licensed. Change anything, then rebuild `docker.sh` with `python3 .source/build.py`. See [Building from source](building.md). Pointing `FORGE_REPO` at your fork makes your installs update from it.

**Does it phone home?**
No. There's no telemetry or account. It connects only to registries, package mirrors, serveo (if you open a public link) and GitHub (for updates). See [Security](security.md).
