#!/usr/bin/env bash
# install.sh — install or update katafract node agent (common + node-specific)
#
# Idempotent. Run after any git pull, or by katafract-update automatically.
# Applies common/ to all nodes, then nodes/<NODE_ID>/ for node-specific overrides.
#
# Requirements: /etc/katafract-node.env must exist with KATAFRACT_NODE_ID set.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
NODE_CONF_DIR="/etc/katafract"

log() { echo "[install] $*"; }
err() { echo "[install] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || err "Must run as root"
[ -f /etc/katafract-node.env ] || err "/etc/katafract-node.env missing — node not provisioned"

source /etc/katafract-node.env
NODE_ID="${KATAFRACT_NODE_ID:?KATAFRACT_NODE_ID not set in /etc/katafract-node.env}"

log "Installing node agent — node: $NODE_ID  repo: $REPO_DIR"

# ── 1. Common agent scripts ───────────────────────────────────
install -m 755 "$REPO_DIR/common/agent/katafract-heartbeat"     "$BIN_DIR/katafract-heartbeat"
install -m 755 "$REPO_DIR/common/agent/katafract-abuse-check"   "$BIN_DIR/katafract-abuse-check"
install -m 755 "$REPO_DIR/common/agent/katafract-pre-reboot.sh" "$BIN_DIR/katafract-pre-reboot.sh"
install -m 755 "$REPO_DIR/common/agent/katafract-update"        "$BIN_DIR/katafract-update"
log "Common scripts installed"

# ── 2. Common systemd units ───────────────────────────────────
install -m 644 "$REPO_DIR/common/systemd/katafract-heartbeat.service"   "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-heartbeat.timer"     "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-abuse-check.service" "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-abuse-check.timer"   "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-pre-reboot.service"  "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-update.service"      "$SYSTEMD_DIR/"
install -m 644 "$REPO_DIR/common/systemd/katafract-update.timer"        "$SYSTEMD_DIR/"
log "Common systemd units installed"

# ── 3. Node-specific overrides ────────────────────────────────
NODE_DIR="$REPO_DIR/nodes/$NODE_ID"
if [ -d "$NODE_DIR" ]; then
    mkdir -p "$NODE_CONF_DIR"

    # node.conf — source of truth for node metadata
    if [ -f "$NODE_DIR/node.conf" ]; then
        install -m 644 "$NODE_DIR/node.conf" "$NODE_CONF_DIR/node.conf"
        log "Node config installed: $NODE_CONF_DIR/node.conf"
    fi

    # Any extra scripts in nodes/<id>/agent/
    if [ -d "$NODE_DIR/agent" ]; then
        for f in "$NODE_DIR/agent/"*; do
            [ -f "$f" ] || continue
            install -m 755 "$f" "$BIN_DIR/$(basename "$f")"
            log "  node script: $(basename "$f")"
        done
    fi

    # Any extra systemd units in nodes/<id>/systemd/
    if [ -d "$NODE_DIR/systemd" ]; then
        for f in "$NODE_DIR/systemd/"*; do
            [ -f "$f" ] || continue
            install -m 644 "$f" "$SYSTEMD_DIR/$(basename "$f")"
            log "  node unit: $(basename "$f")"
        done
    fi

    # Any executable patches in nodes/<id>/patches/ — run in order
    if [ -d "$NODE_DIR/patches" ]; then
        for patch in $(ls "$NODE_DIR/patches/"*.sh 2>/dev/null | sort); do
            log "  running patch: $(basename "$patch")"
            bash "$patch"
        done
    fi
else
    log "No node-specific directory for $NODE_ID — skipping node overrides"
fi

# ── 4. Reload + enable ────────────────────────────────────────
systemctl daemon-reload

for unit in katafract-heartbeat.timer katafract-abuse-check.timer katafract-update.timer; do
    systemctl enable "$unit"
    systemctl restart "$unit"
    log "  $unit: enabled + restarted"
done

systemctl enable katafract-pre-reboot.service
log "  katafract-pre-reboot.service: enabled"

VERSION=$(cat "$REPO_DIR/.git/refs/heads/main" 2>/dev/null | cut -c1-7 || echo unknown)
log "Done — node: $NODE_ID  version: $VERSION"
