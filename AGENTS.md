# katafract-node — Agent Instructions

## Project Purpose

Node agent for the Katafract/Enclave platform. Runs on every VPN/WraithGate node as a daemon — sends 30-second heartbeats to the Artemis control plane, monitors peer bandwidth, enforces fair-use policy (throttle/disconnect/suspend violators), and applies desired-state commands from the control plane.

## Tech Stack

- Python 3 + requests + python-dotenv
- systemd service (heartbeat daemon) + systemd timer (periodic scripts)
- subprocess calls to `wg` (WireGuard CLI) and `nft` (nftables) for peer management
- `bootstrap.sh` — Bash provisioning script (idempotent)

## Key Files

| File | Purpose |
|---|---|
| `agent/agent.py` | Heartbeat daemon — reports to Artemis, enforces bandwidth policy, applies desired-state commands |
| `bootstrap.sh` | Idempotent node provisioning: WireGuard, AdGuard Home DNS, nftables firewall, Prometheus node_exporter, Headscale mesh enrollment |
| `scripts/` | Helper scripts: health checks, metrics export, blocklist updates, IPv6 rotation |
| `configs/` | Reference config templates for firewall, DNS, WireGuard |

## How to Deploy to a Node

```bash
# From artemis (or any node with mesh access)
ssh root@<node-mesh-ip> "curl -fsSL https://raw.githubusercontent.com/katafractured/katafract-node/main/bootstrap.sh | bash"
```

Bootstrap is idempotent — safe to re-run for config updates.

## Config / Environment Variables

Config lives in `/etc/katafract-node.env` on each deployed node:

| Variable | Purpose |
|---|---|
| `KATAFRACT_NODE_ID` | Node identifier (set during bootstrap) |
| `KATAFRACT_API_URL` | Control plane heartbeat endpoint (`http://100.64.0.1/internal/nodes/heartbeat`) |
| `KATAFRACT_NODE_TOKEN` | Auth token for heartbeat API |
| `WG_INTERFACE` | WireGuard interface name (always `wg0`) |

## Systemd Services (on deployed nodes)

- `katafract-heartbeat.service` — runs `agent.py` continuously
- Heartbeat interval: **30 seconds** — hardcoded, non-negotiable (Artemis timeout depends on it)

## What the Agent Reports (Heartbeat Payload)

- Node ID, timestamp
- WireGuard peer stats (bytes tx/rx per peer)
- Bandwidth abuse flags
- System health metrics

## What the Agent Receives (Desired-State Commands)

- Blocklist refresh — update nftables blocklist
- IPv6 rotation — rotate exit IP
- Drain — stop accepting new peers
- Retire — graceful shutdown

## Bandwidth Enforcement Thresholds

| Usage | Action |
|---|---|
| 30 GB | Warn |
| 150 GB | Throttle |
| 300 GB | Disconnect |
| 600 GB | Suspend |

## Constraints

- **Do NOT change the 30-second heartbeat interval** — Artemis node-timeout logic depends on it
- **WireGuard interface must stay `wg0`** — hardcoded throughout agent and bootstrap
- **Firewall policy is default-deny** — do not add permissive rules without security review
- **Swap must be disabled** — audit requirement on all nodes
- **DNS logging must stay off** — privacy requirement (AdGuard verbosity: 0)
- **Peer management is dynamic via Artemis** — never manually add/remove WireGuard peers on a running node
- `bootstrap.sh` must remain idempotent — test before merging changes
- Do not store secrets in the repo — `/etc/katafract-node.env` is populated at provisioning time
