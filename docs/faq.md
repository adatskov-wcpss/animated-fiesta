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
