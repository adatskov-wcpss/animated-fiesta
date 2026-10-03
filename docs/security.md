# Security

Selkies Forge controls Docker on your machine. Docker access is root-equivalent, so it's worth knowing exactly what is reachable and by whom.

## The web UI

- **Listens on `127.0.0.1` only by default.** Nothing outside this machine can reach it.
- **`--expose`** (or `--bind 0.0.0.0`) makes it listen on all interfaces **and requires a token** on every API call. Anyone who has the full link, with `?k=<token>`, can control Docker here. The token is in `~/.selkies-forge/state/token`.
- **Public link for the UI** (`--expose` with a tunnel) puts that same token-protected link on the internet through serveo.
- **Cross-site protection.** Even on localhost, a web page you visit can try to send requests to `localhost:8787`. The server refuses any request whose `Origin` doesn't match the address it's served on, and accepts only JSON POSTs. Browsers won't send a cross-site JSON POST without a preflight, which the server never approves. A localhost-only UI also refuses requests addressed to any other host name, which stops DNS-rebinding attacks.

## Desktops

- Each desktop listens on two random host ports (31000–44000) on **all interfaces**: HTTP for Selkies, and HTTPS for other devices on your network. Kasm uses one HTTPS port.
- **Without sign-in, anyone who can reach a desktop's port or public link can use it**, including its passwordless `sudo`. Turn on sign-in for anything reachable beyond you.
- **Public links** go through [serveo](https://serveo.net): anonymous, free, and the address changes each time. They use an SSH key the forge creates (`state/serveo_key`).
- Desktops run with Docker's default seccomp profile and capabilities. *Relax seccomp* (or the engine's own auto-fix when a session is blocked) sets `seccomp=unconfined` for that desktop only. That's still a container, but it loosens one of its walls.
- Memory and swap are capped together, so a desktop can't push the host into swap.

## What the forge connects to

| Where | When |
|---|---|
| Container registries (`lscr.io`, `ghcr.io`, Docker Hub) | Pulling desktop and base images |
| Distribution package mirrors | Building desktops (inside the build) |
| `get.docker.com` | Only if it installs Docker for you |
| `serveo.net` | Only when a public link is opened |
| `github.com` | Every 5 minutes, `git fetch` for updates (`FORGE_AUTO_UPDATE=0` turns it off) |

Your browser additionally loads pictures from `upload.wikimedia.org` and real screenshots from `raw.githubusercontent.com`.

**There is no telemetry, no account, and no analytics.**

## Updates

Updates arrive by `git fetch` from this repository and are only accepted if they fast-forward from what's installed, or carry a higher version number. A rewound or force-pushed branch is refused. To follow your own fork instead, set `FORGE_REPO`. To turn updates off, set `FORGE_AUTO_UPDATE=0`.

## Reporting a problem

Open an issue on the repository. If it's sensitive, say so in the issue without the details, and a private channel will be arranged.
