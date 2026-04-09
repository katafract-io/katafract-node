# katafract-node

Node agent for every Katafract WraithGate VPN node. Public so users and security auditors can verify privacy claims.

**No secrets in this repo.** All credentials are injected at provision time by Artemis and live only in `/etc/katafract-node.env`.

## What runs on every node

| Component | Binary | Schedule | Purpose |
|---|---|---|---|
| **Heartbeat** | `katafract-heartbeat` | every 30s | Reports WireGuard peer counts, system metrics (CPU/mem/disk/fail2ban) to Artemis |
| **Abuse check** | `katafract-abuse-check` | every 5 min | Tracks per-peer daily bandwidth. Applies `tc` rate caps at warn/suspend thresholds |
| **Pre-reboot drain** | `katafract-pre-reboot.sh` | on shutdown | Signals GeoDNS weight=0, drains existing peers 90s before reboot |

Also on every node:

- **AmneziaWG** — obfuscated WireGuard tunnel (kernel module via DKMS)
- **AdGuard Home** — Haven DNS protection, binds on WireGuard interface only
- **Unbound** — encrypted upstream resolver (DoH/DoT)
- **fail2ban** — SSH brute-force protection
- **UFW** — firewall (SSH + WireGuard port only)

## Abuse thresholds

| Daily usage | Action |
|---|---|
| > 50 GB | 25 Mbps `tc htb` cap applied to peer's WireGuard IP |
| > 100 GB | 1 Mbps cap + abuse report to Artemis (token marked suspended) |
| Midnight UTC | All `tc` rules cleared, daily counters reset |

Rules are re-applied within 5 minutes after node reboot (state persists on disk in `/var/lib/katafract/abuse-state.json`).

## Privacy design

- Swap permanently disabled — no memory paged to disk
- No connection logs — WireGuard peer state in kernel memory only
- No DNS query logs — AdGuard Home logging disabled in production
- RAM-only ephemeral state — abuse counters in `/var/lib/katafract/` (local only, never sent to Artemis)

## Repo structure

```
agent/
  katafract-heartbeat       bash — heartbeat reporter
  katafract-abuse-check     python — per-peer bandwidth tracker + tc shaping
  katafract-pre-reboot.sh   bash — graceful drain before reboot
systemd/
  katafract-heartbeat.{service,timer}
  katafract-abuse-check.{service,timer}
  katafract-pre-reboot.service
configs/
  wg0.conf.template         WireGuard config template
  nftables.conf             default-deny firewall rules
  unbound.conf              Unbound upstream resolver config
scripts/
  deploy-fleet.sh           push updates to all nodes from Artemis
  health-check.sh           manual node health check
bootstrap.sh                full new-node provisioning (run by Artemis)
install.sh                  install/update agent components only
```

## Installing / updating the agent

**From Artemis (push to all nodes):**
```bash
cd ~/dev/katafract-node && git pull && bash scripts/deploy-fleet.sh
```

**On a single node:**
```bash
cd /opt/katafract-node && git pull && bash install.sh
```

**Fresh node bootstrap** (run by Artemis provisioner — not manual):
```bash
NODE_ID=vpn-eu-03 WG_PRIVATE_KEY=<key> ... bash bootstrap.sh
```

## Audit notes

WireGuard peers are added and removed by Artemis via SSH using `awg set wg0 peer ...`. No peer configuration is stored on the node between restarts — the `wg0.conf` only contains the server interface. This means:

- A node reboot drops all client sessions (clients reconnect automatically)
- No historical mapping of IP address to peer exists on the node
- Abuse tracking resets daily at midnight UTC
