# Running it day to day

## Start the web UI on boot

The first time you start the web UI from a terminal, it asks:

```
  Start the web UI automatically whenever this machine boots? (Y/n)
```

Change your mind any time:

```bash
selkies-cli boot on      # or the toggle under "This machine" in the web UI
selkies-cli boot off
selkies-cli boot         # show the setting
```

| Method | Used when | Notes |
|---|---|---|
| **systemd user service** (`~/.config/systemd/user/selkies-forge.service`) | `systemctl --user` works | `Restart=on-failure`, so a crashed or OOM-killed web UI comes back by itself. A clean stop stays stopped. Starts at boot only when **linger** is on for your user; `selkies-cli boot on` offers to run `sudo loginctl enable-linger $USER`. Without linger, it starts when you log in. |
| **cron** (`@reboot` line, marked `# selkies-forge-boot`) | no systemd user session | Starts 20 seconds after boot |

Only the **web UI** starts on boot. Desktops never start by themselves unless you turn on **auto-start** for that desktop. After a reboot, the forge offers to start the ones that were running (below).

## How did it stop last time?

The web UI writes a heartbeat every 20 seconds and records how it stops. Together with the machine's boot ID, that tells these cases apart:

| Shown as | What happened | How it knows |
|---|---|---|
| you stopped it / with ctrl-c | `selkies-cli stop`, the menu, Ctrl-C in the foreground | The CLI leaves a stop request before it signals the web UI |
| it was restarted / restarted to install an update | `selkies-cli restart`, or an automatic update | Same |
| its systemd service was stopped | `systemctl --user stop selkies-forge` | SIGTERM, with systemd's `INVOCATION_ID` set |
| this machine rebooted / shut down | The machine went down cleanly | SIGTERM while systemd has a reboot or poweroff job queued |
| this machine crashed or lost power | The machine came back, but nothing recorded a stop | A new boot ID, and no stop record |
| the web UI process died unexpectedly / the system ran out of memory | The machine stayed up; the web UI didn't | Same boot, process gone, no record; the kernel log is checked for the OOM killer |
| something sent it a stop signal | Another program sent SIGTERM or SIGHUP | No request, no shutdown in progress |

`selkies-cli` shows it on the home screen; the web UI shows it in a banner and under *This machine*.

### Restoring desktops

The heartbeat also records which desktops were running. If any of them exist but are stopped now (after a reboot, for example), you're offered **Start them again**:

```bash
selkies-cli restore      # or the banner in the web UI, or the home screen
```

**Forget about the last stop** (or the banner's ×) stops the offer.

## Crashes while it's running

While the web UI runs, the [watchdog](engine.md#the-watchdog) restarts a desktop that crashes, up to three times an hour, and records it all:

```bash
selkies-cli events
```

```
10-03 00:51:39  forge-rt     create        Alpine i3 (try 1)
10-03 00:51:46  forge-rt     ready         i3
10-03 00:52:15  forge-rt     crashed       exit code 137
10-03 00:52:15  forge-rt     healed        started again after a crash
```

Turn healing off for everything with `FORGE_HEAL=0`, or for one desktop by launching it with `"heal": false` ([API](api.md)).

## Updates

Selkies Forge keeps itself up to date from GitHub, like a `git pull` that only ever moves forward:

- The engine keeps a clone of the repository in `~/.selkies-forge/repo`. Every check is a `git fetch`. A new commit is taken only if it **fast-forwards** from the installed one, or carries a **higher version number**. A rewound or force-pushed branch is refused, with a message.
- **While the web UI runs**, it checks every 5 minutes (`FORGE_UPDATE_EVERY`), installs a new build by itself, and shows **Restart now**. Desktops keep running through the restart.
- **When you run `selkies-cli`**, it checks too (at most every 5 minutes), installs, and re-runs itself on the new version.
- No git? It falls back to downloading `docker.sh` and only accepts a higher version number.
- `selkies-cli update` checks now. `FORGE_AUTO_UPDATE=0` turns automatic updates off.

Installing an update re-runs `docker.sh --setup` from the clone. That unpacks the new engine and UI, and removes files the old version had that the new one doesn't.

## Disk space

```bash
selkies-cli clean
```

| Group | What | Cleaned by |
|---|---|---|
| Forge layers | `selkies-forge/run-*`, a few KB on top of each desktop image | **Tidy up** (old, unused ones) |
| Built desktops | `selkies-forge/<id>:latest`: the package installs | **Remove everything unused** |
| Pulled desktops, base images | Webtop and Kasm images, Selkies base images | **Remove everything unused** |
| Build cache | Docker's builder cache | **Remove everything unused** |
| Orphan volumes | `forge-config-*` volumes of desktops you removed but whose files you kept | **Also delete kept files** (asks first; cannot be undone) |

Nothing a desktop uses (running or stopped) is ever removed. Removed images come back by themselves the next time you forge that desktop.

## Uninstall

```bash
selkies-cli uninstall
```

This removes every desktop the forge created, the `~/.selkies-forge` folder, the `selkies-cli` command, the start-on-boot service or crontab line, and the `PATH` lines it added to your shell profiles. It asks before also deleting images and data volumes. Docker and Python stay installed.
