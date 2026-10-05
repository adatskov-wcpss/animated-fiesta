<p align="center">
  <img src="assets/banner.svg" alt="Selkies Forge" width="100%">
</p>

# Selkies Forge documentation

Everything about Selkies Forge, from your first desktop to rebuilding `docker.sh` from source. Every page stands on its own, so start wherever your question is.

## Using it

| Page | What it covers |
|---|---|
| [Getting started](getting-started.md) | Requirements, the one-line install, your first desktop, where things end up |
| [The `selkies-cli` command](cli.md) | The home screen, every verb and flag, what each status line means |
| [The web UI](web-ui.md) | Browsing, the desktop page, forging, the manager, the shell, *This machine* |
| [The catalog](catalog.md) | All 153 desktops: ready-made, built, curated; RAM, download, screen mode, architectures |
| [Running it day to day](operations.md) | Start on boot, how it last stopped, restoring desktops, updates, disk space, uninstalling |
| [GPU Smart Passthrough](gpu.md) | How desktops get your GPU: detection, the in-image check, what is passed, fallbacks, NVIDIA |
| [Configuration](configuration.md) | Every environment variable and option, with defaults |
| [Security](security.md) | What listens where, what it connects to, sign-in, tunnels |
| [Troubleshooting](troubleshooting.md) | Symptoms and fixes, and how to read the logs and the event journal |
| [FAQ](faq.md) | Short answers to the usual questions |

## How it works

| Page | What it covers |
|---|---|
| [The engine](engine.md) | The heart of the project: modules, the launch pipeline, the scheduler, health checks, auto-fixes, the watchdog, the event journal |
| [The forge layer](forge-layer.md) | What goes inside every desktop: first-run seeds, the screen agent, the session supervisor, and the per-desktop fixes behind them |
| [HTTP API](api.md) | Every endpoint the web UI uses, for scripting the forge yourself |

## Changing it

| Page | What it covers |
|---|---|
| [Building from source](building.md) | The `.source/` tree, `build.py` and what it checks, the tests, the data tools, adding a desktop or a distro |
| [Contributing](../CONTRIBUTING.md) | How to send a change back, if you want to |

> **It's yours to change.** Selkies Forge is open source under the [MIT licence](../LICENSE). Fork it, rename it, rip parts out, add your own desktops. You don't need to ask. [Building from source](building.md) shows how.
