#!/bin/bash
# verify-node.sh — post-provision / post-incident health checklist for a
# WraithGate node. Runs from artemis (the control plane) and SSHes into the
# target node + queries the platform DB to confirm every critical setup
# step shipped correctly.
#
# Each check prints "  OK name — detail" or "  FAIL name — reason". Exits
# non-zero if any check failed so it can gate CI/automation.
#
# Usage:
#   ./scripts/verify-node.sh <node_id>
#
# Example:
#   ./scripts/verify-node.sh vpn-bom-01

set -u

NODE_ID="${1:-}"
if [ -z "$NODE_ID" ]; then
  echo "usage: $0 <node_id>" >&2
  exit 2
fi

ARGUS_HOST="${ARGUS_HOST:-100.64.0.2}"
ARGUS_PGUSER="${ARGUS_PGUSER:-katafract}"
ARGUS_PGDB="${ARGUS_PGDB:-katafract}"
FAILS=0
TOTAL=0

check() {
  local name="$1"
  local expect="$2"
  local got="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expect" = "$got" ]; then
    printf "  OK   %-36s %s\n" "$name" "$got"
  else
    printf "  FAIL %-36s got=%q expected=%q\n" "$name" "$got" "$expect"
    FAILS=$((FAILS + 1))
  fi
}

checknonempty() {
  local name="$1"
  local got="$2"
  TOTAL=$((TOTAL + 1))
  if [ -n "$got" ] && [ "$got" != "null" ]; then
    printf "  OK   %-36s %s\n" "$name" "$got"
  else
    printf "  FAIL %-36s empty\n" "$name"
    FAILS=$((FAILS + 1))
  fi
}

pgq() {
  ssh "root@${ARGUS_HOST}" \
    "psql -U ${ARGUS_PGUSER} -d ${ARGUS_PGDB} -tA -c \"$1\"" 2>/dev/null \
    | tr -d ' '
}

echo "== verifying $NODE_ID =="

# ── DB row sanity ────────────────────────────────────────────
STATUS=$(pgq "SELECT status FROM nodes WHERE node_id='$NODE_ID'")
[ -z "$STATUS" ] && { echo "  FAIL db row                        node not in nodes table"; exit 1; }
MESH_IP=$(pgq   "SELECT mesh_ip FROM nodes WHERE node_id='$NODE_ID'")
PROVIDER=$(pgq  "SELECT provider FROM nodes WHERE node_id='$NODE_ID'")
WG_CIDR=$(pgq   "SELECT wg_client_cidr FROM nodes WHERE node_id='$NODE_ID'")
WG_CIDR6=$(pgq  "SELECT wg_client_cidr6 FROM nodes WHERE node_id='$NODE_ID'")
LAST_HB=$(pgq   "SELECT last_heartbeat FROM nodes WHERE node_id='$NODE_ID'")

check          "db.status"           "healthy"   "$STATUS"
checknonempty  "db.mesh_ip"                      "$MESH_IP"
checknonempty  "db.provider"                     "$PROVIDER"
checknonempty  "db.wg_client_cidr"               "$WG_CIDR"
if [ -z "$WG_CIDR6" ]; then
  printf "  WARN %-36s empty (v6 tunnel not configured)\n" "db.wg_client_cidr6"
fi
NOW=$(date +%s)
HB_AGE=$((NOW - LAST_HB))
TOTAL=$((TOTAL + 1))
if [ "$HB_AGE" -lt 120 ]; then
  printf "  OK   %-36s age=%ss\n" "db.last_heartbeat" "$HB_AGE"
else
  printf "  FAIL %-36s age=%ss\n" "db.last_heartbeat" "$HB_AGE"
  FAILS=$((FAILS + 1))
fi

# ── Node-side SSH checks ─────────────────────────────────────
[ -z "$MESH_IP" ] && { echo "  skip on-node checks (no mesh_ip)"; exit 1; }

REMOTE=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "root@${MESH_IP}" bash <<'EOF' 2>&1
echo -n "SYMLINK="; [ -L /etc/wireguard/wg0.conf ] && echo OK || echo MISSING
echo -n "WG_UP="; awg show wg0 >/dev/null 2>&1 && echo OK || echo DOWN
echo -n "AWG_MOD="; lsmod | grep -q amneziawg && echo OK || (lsmod | grep -q wireguard && echo WIREGUARD || echo NONE)
echo -n "HB_TIMER="; systemctl is-active katafract-heartbeat.timer 2>&1
echo -n "AGH="; systemctl is-active adguardhome 2>&1
echo -n "NODE_EXPORTER="; systemctl is-active node-exporter 2>&1 || systemctl is-active node_exporter 2>&1
echo -n "TAILSCALE="; tailscale status --peers=false 2>&1 | grep -q "^100\." && echo OK || echo DOWN
echo -n "IPTABLES_FORWARD="; iptables -S FORWARD 2>/dev/null | grep -c wg0
echo -n "SSH_ALLOWUSERS="; grep -rc 'AllowUsers.*root@100\.64\.\* tek artemis' /etc/ssh/sshd_config.d/ /etc/ssh/sshd_config 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}'
echo -n "ARTEMIS_SUDO="; [ -f /etc/sudoers.d/90-artemis-nopasswd ] && echo OK || echo MISSING
echo -n "UATTENDED="; systemctl is-enabled unattended-upgrades 2>&1
echo -n "REBOOT_HOUR="; grep -oE 'Automatic-Reboot-Time "[0-9:]+"' /etc/apt/apt.conf.d/52unattended-upgrades-katafract 2>/dev/null | grep -oE '[0-9]+:[0-9]+'
EOF
)
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "  FAIL ssh to ${MESH_IP}                 rc=$RC"
  FAILS=$((FAILS + 1))
  TOTAL=$((TOTAL + 1))
else
  while IFS='=' read -r k v; do
    case "$k" in
      SYMLINK)           check "node.wg0.conf symlink" "OK" "$v" ;;
      WG_UP)             check "node.awg interface"     "OK" "$v" ;;
      AWG_MOD)           TOTAL=$((TOTAL+1))
                         case "$v" in
                           OK|WIREGUARD) printf "  OK   %-36s %s\n" "node.wg kernel module" "$v";;
                           *) printf "  FAIL %-36s %s\n" "node.wg kernel module" "$v"; FAILS=$((FAILS+1));;
                         esac ;;
      HB_TIMER)          check "node.katafract-heartbeat.timer" "active" "$v" ;;
      AGH)               check "node.adguardhome" "active" "$v" ;;
      NODE_EXPORTER)     check "node.node_exporter" "active" "$v" ;;
      TAILSCALE)         check "node.tailscale online" "OK" "$v" ;;
      IPTABLES_FORWARD)  TOTAL=$((TOTAL+1))
                         if [ "${v:-0}" -ge 4 ]; then
                           printf "  OK   %-36s %s rules\n" "node.peer-isolation iptables" "$v"
                         else
                           printf "  FAIL %-36s %s rules (expected >=4)\n" "node.peer-isolation iptables" "$v"
                           FAILS=$((FAILS+1))
                         fi ;;
      SSH_ALLOWUSERS)    TOTAL=$((TOTAL+1))
                         if [ "${v:-0}" -ge 1 ]; then
                           printf "  OK   %-36s configured\n" "node.sshd AllowUsers"
                         else
                           printf "  FAIL %-36s not configured\n" "node.sshd AllowUsers"
                           FAILS=$((FAILS+1))
                         fi ;;
      ARTEMIS_SUDO)      check "node.artemis NOPASSWD sudo" "OK" "$v" ;;
      UATTENDED)         check "node.unattended-upgrades" "enabled" "$v" ;;
      REBOOT_HOUR)       checknonempty "node.reboot hour (UTC)" "$v" ;;
    esac
  done <<< "$REMOTE"
fi

# ── Prometheus scrape target on fury ─────────────────────────
PROM=$(ssh -o ConnectTimeout=5 root@100.64.0.4 \
  "grep -q '${MESH_IP}:9100' /opt/monitoring/prometheus/prometheus.yml && echo OK || echo MISSING" 2>/dev/null)
check "prometheus.yml scrape target" "OK" "$PROM"

# ── Summary ──────────────────────────────────────────────────
echo
if [ "$FAILS" -eq 0 ]; then
  echo "  PASS   $TOTAL/$TOTAL checks"
  exit 0
else
  echo "  FAIL   $((TOTAL - FAILS))/$TOTAL checks (${FAILS} failures)"
  exit 1
fi
