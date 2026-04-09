#!/usr/bin/env bash
# katafract-pre-reboot.sh — graceful drain before system reboot
# Signals maintenance mode to Artemis (GeoDNS weight=0), waits for peers to drain,
# then allows the reboot to proceed. Always exits 0 — never blocks the reboot.

source /etc/katafract-node.env 2>/dev/null || true
set -uo pipefail
trap 'exit 0' EXIT

NODE_ID="${KATAFRACT_NODE_ID:-}"
TOKEN="e2675f896f618ac9eb23e05cb9686805bc4b3860f399a5e7e06e95582040b445"
API="http://100.64.0.1/internal/nodes"
DRAIN_WAIT=90       # seconds — WireGuard keepalive ~60-75 s
MESH_TIMEOUT=4

LOG_FILE="/var/log/katafract-maintenance.log"
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [pre-reboot] $*" | tee -a "$LOG_FILE"; }

log "=== Pre-reboot drain starting (Node: ${NODE_ID:-UNKNOWN}) ==="

if [ -z "$NODE_ID" ]; then
    log "KATAFRACT_NODE_ID not set — skipping drain"
    exit 0
fi

# Check mesh reachability before trying to signal
if ! curl -sf --max-time "$MESH_TIMEOUT" -o /dev/null "http://100.64.0.1/" 2>/dev/null; then
    log "Mesh (100.64.0.1) unreachable — skipping drain"
    exit 0
fi

log "Mesh reachable — signaling maintenance"

RESPONSE=$(curl -sf --max-time 6 \
    -X POST "$API/maintenance" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"node_id\":\"$NODE_ID\",\"duration_seconds\":600}" \
    2>/dev/null || echo "FAILED")

if [ "$RESPONSE" = "FAILED" ]; then
    log "Maintenance signal failed — rebooting anyway"
    exit 0
fi

log "Maintenance signaled. Waiting ${DRAIN_WAIT}s for peer drain."
sleep "$DRAIN_WAIT"
log "Drain complete — proceeding to reboot"
exit 0
