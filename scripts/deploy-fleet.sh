#!/usr/bin/env bash
# deploy-fleet.sh — push katafract-node agent to all active VPN nodes
# Run from artemis: bash scripts/deploy-fleet.sh
#
# Syncs repo to /opt/katafract-node on each node, then runs install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="/opt/katafract-node"
SSH_KEY="/home/artemis/.ssh/id_ed25519"

NODES=(
    "100.64.0.6"   # vpn-eu-01
    "100.64.0.7"   # vpn-eu-02
    "100.64.0.5"   # vpn-sin-01
    "100.64.0.20"  # vpn-us-east-01
    "100.64.0.21"  # vpn-us-west-01
)

log()  { echo "[deploy] $*"; }
ok()   { echo "[deploy] ✓ $1"; }
fail() { echo "[deploy] ✗ $1 — $2"; }

deploy_node() {
    local ip="$1"
    local ssh="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$ip"

    # Ensure target dir exists
    $ssh "mkdir -p $REMOTE_DIR"

    # Rsync repo contents (exclude git history and scripts not needed on node)
    rsync -az --delete \
        -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
        --exclude=".git" \
        --exclude="scripts/deploy-fleet.sh" \
        --exclude="bootstrap.sh" \
        "$REPO_DIR/" \
        "root@$ip:$REMOTE_DIR/"

    # Run install
    $ssh "bash $REMOTE_DIR/install.sh"
}

log "Deploying from $REPO_DIR"
log "Nodes: ${NODES[*]}"
echo ""

pids=()
results=()

for ip in "${NODES[@]}"; do
    (
        if deploy_node "$ip" 2>&1 | sed "s/^/[$ip] /"; then
            echo "__OK__ $ip"
        else
            echo "__FAIL__ $ip"
        fi
    ) &
    pids+=($!)
done

# Collect results
ok_count=0
fail_count=0
for pid in "${pids[@]}"; do
    wait "$pid"
done

echo ""
log "Fleet deploy complete"
