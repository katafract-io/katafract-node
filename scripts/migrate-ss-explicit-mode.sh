#!/usr/bin/env bash
# migrate-ss-explicit-mode.sh
#
# One-shot fleet migration to make `mode=websocket;path=/` explicit in
# /etc/shadowsocks/server.json on every WraithGate node.
#
# Background:
#   bootstrap.sh now writes `mode=websocket;path=/` explicitly into
#   plugin_opts (PR #4). All 10 production nodes were provisioned BEFORE
#   that change, so their plugin_opts strings rely on v2ray-plugin's
#   implicit default mode (websocket in 5.0.4).
#
#   wraith-ios PR #51 ships a client that sends `mode=websocket;path=/`
#   in its own plugin_opts during the WS handshake. Server-side strings
#   should match exactly; once the client is explicit, the server should
#   be too — otherwise a future v2ray-plugin release that flips the
#   default would silently break Stealth across the fleet.
#
# What this script does on each node:
#   1. Skip if `mode=websocket` is already present (idempotent).
#   2. Edit /etc/shadowsocks/server.json with `jq`, inserting
#      `;mode=websocket;path=/` immediately after the `tls` token in
#      `plugin_opts` (preserves cert/key/loglevel ordering).
#   3. Validate JSON with `jq empty` before swapping the file in.
#   4. `systemctl restart shadowsocks-server.service` and verify it's
#      active + listening on :8443.
#
# Usage (from artemis or anywhere with mesh access):
#   bash scripts/migrate-ss-explicit-mode.sh           # all 10 nodes
#   bash scripts/migrate-ss-explicit-mode.sh 100.64.0.6 # single node
#
# Run BEFORE merging wraith-ios#51. Re-run is safe (no-op on already-migrated nodes).

set -euo pipefail

# Mesh IPs of the 10 production WraithGate nodes (CLAUDE.md "Infrastructure — Node Map").
ALL_NODES=(
  100.64.0.6   # vpn-nbg-01
  100.64.0.7   # vpn-hel-01
  100.64.0.20  # vpn-iad-01
  100.64.0.21  # vpn-pdx-01
  100.64.0.9   # vpn-ewr-01
  100.64.0.5   # vpn-nrt-01
  100.64.0.31  # vpn-bom-01
  100.64.0.28  # vpn-sin-02
  100.64.0.3   # vpn-sin-03
  100.64.0.29  # vpn-pdx-02
)

if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("${ALL_NODES[@]}")
fi

# Remote routine: run on each node as root.
# Reads server.json, checks for mode=websocket, edits in-place if absent.
read -r -d '' REMOTE_CMD <<'REMOTE' || true
set -euo pipefail

CFG=/etc/shadowsocks/server.json
SVC=shadowsocks-server.service

if [[ ! -f "$CFG" ]]; then
  echo "[$(hostname)] SKIP: $CFG not found"; exit 0
fi

CURRENT=$(jq -r '.servers[0].plugin_opts' "$CFG")
if [[ "$CURRENT" == *"mode=websocket"* ]]; then
  echo "[$(hostname)] OK already explicit: $CURRENT"; exit 0
fi

# Insert ";mode=websocket;path=/" immediately after the "tls" token.
# Pattern: starts with "server;tls;..." (verified via grep below).
if [[ "$CURRENT" != *"tls"* ]]; then
  echo "[$(hostname)] ERROR: plugin_opts missing 'tls' token, refusing to edit: $CURRENT" >&2; exit 1
fi

NEW=$(printf '%s' "$CURRENT" | sed 's/\btls\b/tls;mode=websocket;path=\//')
if [[ "$NEW" == "$CURRENT" ]]; then
  echo "[$(hostname)] ERROR: sed produced no change, refusing to write" >&2; exit 1
fi

TMP=$(mktemp /etc/shadowsocks/server.json.XXXXXX)
trap 'rm -f "$TMP"' EXIT
jq --arg new "$NEW" '.servers[0].plugin_opts = $new' "$CFG" > "$TMP"
jq empty "$TMP"  # validate
chmod 600 "$TMP"
mv "$TMP" "$CFG"
trap - EXIT

echo "[$(hostname)] PATCH applied:"
echo "  was: $CURRENT"
echo "  now: $NEW"

systemctl restart "$SVC"
sleep 2
if ! systemctl is-active --quiet "$SVC"; then
  echo "[$(hostname)] ERROR: $SVC failed to come back up" >&2
  systemctl status --no-pager "$SVC" | tail -20 >&2
  exit 1
fi

# Confirm listener on :8443.
if ! ss -lntp 2>/dev/null | grep -q ':8443 '; then
  echo "[$(hostname)] ERROR: no listener on :8443 after restart" >&2; exit 1
fi
echo "[$(hostname)] DONE — $SVC active, listening on :8443"
REMOTE

FAILED=()
for ip in "${TARGETS[@]}"; do
  echo "==> Migrating $ip"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${ip}" "bash -s" <<< "$REMOTE_CMD"; then
    echo "    !! $ip FAILED" >&2
    FAILED+=("$ip")
  fi
  echo
done

if (( ${#FAILED[@]} > 0 )); then
  echo "Migration completed with ${#FAILED[@]} failure(s):" >&2
  for f in "${FAILED[@]}"; do echo "  $f" >&2; done
  exit 1
fi
echo "All ${#TARGETS[@]} node(s) migrated successfully."
