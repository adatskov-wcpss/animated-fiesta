# Troubleshooting

## First, look at what happened

| Where | What it tells you |
|---|---|
| `selkies-cli events` (or a desktop's **Logs** in the manager) | Launches, auto-fixes, crashes, heals, repairs, stops |
| `~/.selkies-forge/logs/jobs/` | The full log of every launch, one file each |
| `selkies-cli doctor` | Docker, memory, disk, quotas, serveo |
| Inside a desktop: `/tmp/forge/session.log`, `agent.log`, `health.json` | What the session printed, what the agent saw and moved |
| `~/.selkies-forge/logs/webui.log` | The web UI's own log |

## Problems and fixes

| Problem | Fix |
|---|---|
| `permission denied` on the Docker socket | `sudo usermod -aG docker $USER`, then log out and back in (or `newgrp docker`) |
| "has no arm64 image" | Pick an entry whose badge lists your architecture; the error suggests some |
| "only N MB of memory is free and … needs at least …" | Stop a desktop (the message names them), pick a lighter one, or pass `force` |
| A launch says **queued** | Another build, pull or first boot is using the slot ([scheduler](engine.md#the-scheduler)). It starts by itself, or cancel it. |
| The desktop never answers | Heavy desktops are slow on a first boot. The engine already waits longer once. Check the job log. |
| **Started, with a problem** | The session crashed or never showed a window manager. The desktop is in a rescue session that shows its log. Read it there, or in the launch view. |
| Part of the desktop is off the bottom of the window | Set **Screen** to *Fixed size, scaled to fit* under **Edit limits** |
| A black desktop, a missing panel, a setup wizard | A desktop made by an older version: choose **Repair** in its menu (files are kept) |
| A built desktop fails to build | The log names the package that broke (exit 97 means the desktop's session binary didn't install). Try the same desktop on another distro. |
| No public link | serveo sometimes refuses or rate-limits. The local link still works; reopen the link from the manager. |
| The web UI "stopped unexpectedly" | `selkies-cli` → *Show why it stopped*, then *Start the web UI again*. With start-on-boot via systemd, it restarts by itself. |
| It doesn't start on boot | `selkies-cli boot`. With systemd, check linger: `loginctl show-user $USER -p Linger`. |
| A desktop keeps restarting by itself | The watchdog heals crashes, up to three times an hour. See `selkies-cli events` for why it crashes, or launch it with healing off. |
| The disk is filling up | `selkies-cli clean` |
| `selkies-cli: command not found` | Open a new terminal (the `PATH` change only reaches new shells), or run `~/.local/bin/selkies-cli` |
| "POST requests must send Content-Type: application/json" / "cross-site request refused" | You're scripting the API: send JSON with that header, and no foreign `Origin` ([API rules](api.md#rules)) |

## Starting clean

```bash
selkies-cli uninstall                                  # remove everything the forge made
curl -fsSL https://raw.githubusercontent.com/adatskov-wcpss/animated-fiesta/main/docker.sh | bash
```
