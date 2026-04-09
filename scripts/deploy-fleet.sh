#!/usr/bin/env bash
# deploy-fleet.sh — bootstrap self-update on all active VPN nodes
#
# Normal workflow: push to GitHub → nodes self-update within 15 min.
# Use this script to force immediate rollout (e.g. after a critical fix),
# or to bootstrap the self-update mechanism on a node for the first time.
#
# Usage:
#   bash scripts/deploy-fleet.sh           # all nodes
#   bash scripts/deploy-fleet.sh 100.64.0.6  # single node

set -euo pipefail

REPO_URL="https://github.com/katafractured/katafract-node.git"
REMOTE_DIR="/opt/katafract-node"
SSH_KEY="/home/artemis/.ssh/id_ed25519"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

ALL_NODES=(
    "100.64.0.6"   # vpn-eu-01
    "100.64.0.7"   # vpn-eu-02
    "100.64.0.5"   # vpn-sin-01
    "100.64.0.20"  # vpn-us-east-01
    "100.64.0.21"  # vpn-us-west-01
)

log() { echo "[deploy] $*"; }

bootstrap_node() {
    local ip="$1"
    local ssh_cmd="ssh $SSH_OPTS root@$ip"

    # Ensure git is installed
    $ssh_cmd "apt-get install -y -qq git 2>/dev/null || true"

    if $ssh_cmd "[ -d $REMOTE_DIR/.git ]"; then
        # Repo already present — just pull and install
        $ssh_cmd "cd $REMOTE_DIR && git fetch --quiet origin main && git reset --hard origin/main --quiet && bash install.sh"
    else
        # Fresh clone
        $ssh_cmd "git clone --depth=1 https://github.com/katafractured/katafract-node.git $REMOTE_DIR && bash $REMOTE_DIR/install.sh"
    fi
}

# Target: single node or full fleet
if [ "${1:-}" != "" ]; then
    NODES=("$1")
else
    NODES=("${ALL_NODES[@]}")
fi

log "Nodes: ${NODES[*]}"
echo ""

for ip in "${NODES[@]}"; do
    (
        bootstrap_node "$ip" 2>&1 | sed "s/^/[$ip] /"
        echo "[$ip] done"
    ) &
done

wait
echo ""
log "Complete. Nodes will self-update every 15 min from GitHub going forward."
