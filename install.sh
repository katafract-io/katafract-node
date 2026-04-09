#!/usr/bin/env bash
# install.sh — install or update katafract node agent components
#
# Run on the node itself (as root), or let Artemis run it via SSH:
#   ssh root@<node> "curl -fsSL https://raw.githubusercontent.com/katafractured/katafract-node/main/install.sh | bash"
#
# Or after a git pull on the node:
#   cd /opt/katafract-node && git pull && bash install.sh
#
# Requirements: /etc/katafract-node.env must already exist with KATAFRACT_NODE_ID set.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

log() { echo "[install] $*"; }
err() { echo "[install] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || err "Must run as root"
[ -f /etc/katafract-node.env ] || err "/etc/katafract-node.env missing — node not provisioned"

log "Installing katafract node agent from $REPO_DIR"

# ── Agent scripts ─────────────────────────────────────────────
install -m 755 "$REPO_DIR/agent/katafract-heartbeat"     "$BIN_DIR/katafract-heartbeat"
install -m 755 "$REPO_DIR/agent/katafract-abuse-check"   "$BIN_DIR/katafract-abuse-check"
install -m 755 "$REPO_DIR/agent/katafract-pre-reboot.sh" "$BIN_DIR/katafract-pre-reboot.sh"

log "Scripts installed to $BIN_DIR"

# ── Systemd units ─────────────────────────────────────────────
install -m 644 "$REPO_DIR/systemd/katafract-heartbeat.service"    "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/systemd/katafract-heartbeat.timer"      "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/systemd/katafract-abuse-check.service"  "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/systemd/katafract-abuse-check.timer"    "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/systemd/katafract-pre-reboot.service"   "$SYSTEMD_DIR/"

log "Systemd units installed"

systemctl daemon-reload

# Enable and restart timers
for unit in katafract-heartbeat.timer katafract-abuse-check.timer; do
    systemctl enable "$unit"
    systemctl restart "$unit"
    log "  $unit: enabled + restarted"
done

# Enable pre-reboot (oneshot — no restart)
systemctl enable katafract-pre-reboot.service
log "  katafract-pre-reboot.service: enabled"

VERSION=$(cat "$REPO_DIR/.git/refs/heads/main" 2>/dev/null | cut -c1-7 || echo unknown)
log "Done. Agent version: $VERSION"
