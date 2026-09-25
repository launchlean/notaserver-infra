# NotaServer Infrastructure — Phase 1

Bootstrap and installer for NotaServer instances.

## What this builds

**One container = the server.** A single `nginx:stable-alpine` container named
`notacontainer` runs on ports 80/443 and serves everything. Static-site addons
(Monitor, NotMusic, NotVideos, NotaChat, NotTodo, NotaOS, etc.) live inside it.

```
notacontainer (nginx:stable-alpine)
├── ports 80/443
├── /etc/nginx/nginx.conf     ← conf/nginx.conf
├── /var/www/html/            ← html/index.html (homepage)
├── /etc/nginx/certs/         ← certs/server.crt + server.key
└── /var/log/nginx/           ← logs/
```

## Flow

```
1. System      apt update / upgrade? / tools? / Docker?
2. Network     Static IP? (yes/skip) → 2-IP → reconnect → --resume
3. Tailscale   Yes / No / Install-but-don't-connect
4. Firewall    UFW: SSH + network access choice
5. DNS         Install dnsmasq? (yes / no — I have my own)
6. Server      notacontainer + homepage from repo
End           Cleanup: remove old IP, delete temp files
```

## Files

- `installer.sh` — main installer
- `bootstrap.sh` — download + verify + run installer
- `rollback.sh` — undo steps (`--last`, `--all`, `--full`, `--panic`)
- `doctor.sh` — status check and diagnostics
- `installer.sh.sha256` — SHA256 manifest for bootstrap verification

## Usage

```bash
# Quick start (full setup, interactive)
curl -fsSL https://raw.githubusercontent.com/launchlean/notaserver-infra/main/bootstrap.sh | sudo bash

# Quick setup (skip network questions)
curl -fsSL .../bootstrap.sh | sudo bash -s -- --quick

# Non-interactive (env vars)
curl -fsSL .../bootstrap.sh | sudo bash -s -- --non-interactive

# Resume after IP change
sudo bash /tmp/notaserver-setup/installer.sh --resume

# Check status
sudo bash /tmp/notaserver-setup/doctor.sh --status

# Rollback
sudo bash /tmp/notaserver-setup/rollback.sh --last    # undo last step
sudo bash /tmp/notaserver-setup/rollback.sh --all     # undo session
sudo bash /tmp/notaserver-setup/rollback.sh --full    # full uninstall
sudo bash /tmp/notaserver-setup/rollback.sh --panic   # conservative undo
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOMEPAGE_SOURCE` | `https://github.com/launchlean/notaserver/raw/main/index.html` | Where to pull the homepage from |
| `INSTALL_TYPE` | — | `full`, `quick`, or `custom` (set by menu) |
| `SKIP_VERIFY` | `no` | Skip SHA256 verification (bootstrap only) |

## Adding an addon (future)

1. Clone addon repo from GitHub into `/tmp/`
2. Copy static site into `$DATA_ROOT/notacontainer/sites/<addon>/`
3. Add nginx `server` block for `<addon>.notaserver`
4. `docker exec notacontainer nginx -s reload`
5. Add navbar link to homepage

## Netplan

The installer uses netplan with `networkd` renderer. It backs up the existing
netplan file before making changes and supports a two-IP transition during the
static-IP step.

## Certificates

Self-signed certificate generated with OpenSSL during setup if none exists.
Replace with real certificates for production use.
