#!/bin/bash
# Katafract WraithGate Node Bootstrap
# Idempotent — safe to run multiple times on an existing node
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/katafract-io/katafract-node/main/bootstrap.sh \
#     | NODE_ID=vpn-eu-03 \
#       WG_PRIVATE_KEY=<key> \
#       WG_IPV4_TUNNEL=10.10.5.1/24 \
#       WG_IPV6_TUNNEL=fd10:0:5::1/64 \
#       WG_LISTEN_PORT=51820 \
#       HEADSCALE_PREAUTH_KEY=<key> \
#       NODE_AGENT_TOKEN=<token> \
#       AGH_PASSWORD=<plaintext-password> \
#       BOOTSTRAP_CF_TOKEN=<cloudflare-api-token> \
#       INFISICAL_TOKEN=<machine-identity-token> \
#       bash
#
# Required env vars:
#   NODE_ID               — unique node identifier (e.g. vpn-eu-03)
#   WG_PRIVATE_KEY        — WireGuard private key (awg genkey)
#   WG_IPV4_TUNNEL        — WireGuard server interface IP/CIDR (e.g. 10.10.5.1/24)
#   WG_LISTEN_PORT        — WireGuard listen port (default: 51820)
#   HEADSCALE_PREAUTH_KEY — reusable pre-auth key from headscale
#   NODE_AGENT_TOKEN      — shared secret for heartbeat auth with artemis-api
#   AGH_PASSWORD          — AdGuard Home admin password (plaintext, will be bcrypt-hashed)
#   BOOTSTRAP_CF_TOKEN    — Cloudflare DNS API token (used for LE cert DNS-01 challenge)
#                           Read from Infisical prod/ as CF_API_TOKEN_KATAFRACT by provisioner
#
# Optional:
#   WG_IPV6_TUNNEL        — WireGuard IPv6 tunnel address (e.g. fd10:0:5::1/64)
#   NODE_FQDN             — SS-fallback TLS hostname (default: <NODE_ID>.vpn.katafract.com)
#   INFISICAL_TOKEN       — machine identity token; if set, SERVER_PSK is auto-pushed to
#                           Infisical at prod/wraith/ss/<NODE_ID>/SERVER_PSK
#   INFISICAL_BASE_URL    — default: http://100.64.0.1:8080
#   ARTEMIS_HEARTBEAT_URL — default: http://100.64.0.1/internal/nodes/heartbeat
#   SITE                  — display name (e.g. Frankfurt)
#   REGION                — region slug (e.g. eu-west)
#   REBOOT_HOUR_UTC       — HH:MM slot for unattended-upgrades auto-reboot.
#                           Provisioner picks a free slot; defaults to 03:00
#                           if unset. Avoid colliding with artemis (03:00)
#                           and argus (04:00) on new nodes.

set -euo pipefail

: "${NODE_ID:?Required}"
: "${WG_PRIVATE_KEY:?Required}"
: "${WG_IPV4_TUNNEL:=10.10.1.1/24}"
: "${WG_LISTEN_PORT:=51820}"
: "${HEADSCALE_PREAUTH_KEY:?Required}"
: "${NODE_AGENT_TOKEN:?Required}"
: "${AGH_PASSWORD:?Required}"
: "${ARTEMIS_HEARTBEAT_URL:=http://100.64.0.1/internal/nodes/heartbeat}"
: "${SITE:=$NODE_ID}"
: "${REGION:=unknown}"
: "${WG_IPV6_TUNNEL:=}"

# wg1 — standard WireGuard listener for home routers (no AmneziaWG).
# CIDR mirrors wg0's 10.10.X.0/24 → 10.11.X.0/24. Port 51821 uniform.
: "${WG1_LISTEN_PORT:=51821}"
WG1_IPV4_TUNNEL_DEFAULT=$(echo "$WG_IPV4_TUNNEL" | sed 's|^10\.10\.|10.11.|')
: "${WG1_IPV4_TUNNEL:=$WG1_IPV4_TUNNEL_DEFAULT}"

WG_SERVER_IP=$(echo "$WG_IPV4_TUNNEL" | cut -d/ -f1)
WG1_SERVER_IP=$(echo "$WG1_IPV4_TUNNEL" | cut -d/ -f1)
WG1_SUBNET=$(echo "$WG1_IPV4_TUNNEL" | sed 's|\.[0-9]*/|.0/|')

echo "==> Bootstrapping WraithGate node: $NODE_ID ($SITE / $REGION)"

# ── 1. System packages ────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  wireguard-tools \
  iptables \
  fail2ban \
  curl wget jq git \
  net-tools htop \
  ca-certificates gnupg \
  software-properties-common \
  python3-bcrypt \
  unattended-upgrades \
  apt-listchanges

# Disable swap
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab

# IP forwarding
cat > /etc/sysctl.d/99-katafract.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p /etc/sysctl.d/99-katafract.conf

echo "  [ok] system packages"

# ── 1b. Vendor-agnostic DNS ───────────────────────────────────
# Pin to public DNS at boot — never rely on provider-assigned resolvers
# (Vultr and Hetzner DNS can fail at startup; tailscale must not override this)
cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=1.0.0.1 8.8.8.8
DNSStubListener=yes
DNSSEC=no
EOF
systemctl restart systemd-resolved
echo "  [ok] vendor-agnostic DNS (1.1.1.1/9.9.9.9)"

# ── 2. AmneziaWG (obfuscated WireGuard) ──────────────────────

add-apt-repository -y ppa:amnezia/ppa 2>&1 | tail -2
apt-get update -qq
apt-get install -y -qq linux-headers-$(uname -r) amneziawg amneziawg-tools 2>&1 | tail -3

# Verify AmneziaWG kernel module loads
modprobe amneziawg || { echo "[FATAL] amneziawg kernel module failed to load"; exit 1; }

# Derive public key
WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | awg pubkey)
echo "$WG_PUBLIC_KEY" > /etc/wireguard/public.key

# Detect default outbound interface
DEFAULT_IFACE=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')

# AWG config goes in /etc/amnezia/amneziawg/ (awg-quick@wg0 looks here)
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

# Build Address line (IPv4 + optional IPv6)
if [ -n "$WG_IPV6_TUNNEL" ]; then
  WG_ADDRESS="${WG_IPV4_TUNNEL}, ${WG_IPV6_TUNNEL}"
  IPV6_MASQ="ip6tables -t nat -A POSTROUTING -s $(echo "$WG_IPV6_TUNNEL" | sed 's|::1/64|::/64|') -o ${DEFAULT_IFACE} -j MASQUERADE; "
  IPV6_MASQ_DOWN="ip6tables -t nat -D POSTROUTING -s $(echo "$WG_IPV6_TUNNEL" | sed 's|::1/64|::/64|') -o ${DEFAULT_IFACE} -j MASQUERADE; "
else
  WG_ADDRESS="${WG_IPV4_TUNNEL}"
  IPV6_MASQ=""
  IPV6_MASQ_DOWN=""
fi

WG_SUBNET=$(echo "$WG_IPV4_TUNNEL" | sed 's|\.[0-9]*/|.0/|')

cat > /etc/amnezia/amneziawg/wg0.conf << EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = ${WG_PRIVATE_KEY}

# AWG obfuscation params (fleet-standard)
Jc = 4
Jmin = 40
Jmax = 70
S1 = 0
S2 = 0
H1 = 165494111
H2 = 2783653322
H3 = 825748096
H4 = 2426479516

# Peer isolation: clients get internet only, no mesh/P2P
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE; ${IPV6_MASQ}iptables -A FORWARD -i wg0 -o ${DEFAULT_IFACE} -j ACCEPT; iptables -A FORWARD -i ${DEFAULT_IFACE} -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -A FORWARD -i wg0 -o wg0 -j DROP; iptables -A FORWARD -i wg0 -d 100.64.0.0/10 -j DROP
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE; ${IPV6_MASQ_DOWN}iptables -D FORWARD -i wg0 -o ${DEFAULT_IFACE} -j ACCEPT; iptables -D FORWARD -i ${DEFAULT_IFACE} -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -D FORWARD -i wg0 -o wg0 -j DROP; iptables -D FORWARD -i wg0 -d 100.64.0.0/10 -j DROP

# Peers added dynamically by Artemis via awg addconf
EOF
chmod 600 /etc/amnezia/amneziawg/wg0.conf

# Symlink /etc/wireguard/wg0.conf → /etc/amnezia/amneziawg/wg0.conf so the
# platform API's _ssh_add_peer helper (which reads/writes the canonical
# /etc/wireguard/wg0.conf path) works on AmneziaWG nodes without branching.
# Without this, multi-hop provisioning fails with "Operation not permitted"
# during the post-addconf dedup/rewrite step.
mkdir -p /etc/wireguard
ln -sf /etc/amnezia/amneziawg/wg0.conf /etc/wireguard/wg0.conf

systemctl disable wg-quick@wg0 2>/dev/null || true
systemctl enable awg-quick@wg0
systemctl restart awg-quick@wg0

# Persistent DKMS safety net: on every boot, ensure amneziawg is built for the
# running kernel before awg-quick starts. Handles kernel updates via unattended-upgrades.
cat > /usr/local/sbin/ensure-amneziawg.sh << 'SAFETY'
#!/bin/bash
KERNEL=$(uname -r)
if ! modprobe amneziawg 2>/dev/null; then
    apt-get install -y -q linux-headers-${KERNEL} || true
    dkms install amneziawg/$(dkms status amneziawg | head -1 | awk -F'[/,]' '{print $2}' | tr -d ' ') -k ${KERNEL} || true
    modprobe amneziawg
fi
SAFETY
chmod +x /usr/local/sbin/ensure-amneziawg.sh

cat > /etc/systemd/system/ensure-amneziawg.service << 'SVC'
[Unit]
Description=Ensure AmneziaWG kernel module for current kernel
DefaultDependencies=no
Before=awg-quick@wg0.service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ensure-amneziawg.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
systemctl enable ensure-amneziawg.service

echo "  [ok] AmneziaWG (interface: $WG_SERVER_IP, port: $WG_LISTEN_PORT)"

# ── 2b. Standard WireGuard wg1 (router listener) ───────────────
#
# Home routers (OpenWRT/DD-WRT/Mikrotik/Ubiquiti) only speak stock WireGuard.
# wg1 is a second listener, separate port + subnet, no AWG magic numbers,
# served by `/v1/peers/provision-router` on artemis-api.
# See project_router_wg_endpoint_2026_04_21.md in memory.

mkdir -p /etc/wireguard
chmod 755 /etc/wireguard
if [ ! -f /etc/wireguard/wg1.key ]; then
  (umask 077; wg genkey > /etc/wireguard/wg1.key)
  cat /etc/wireguard/wg1.key | wg pubkey > /etc/wireguard/wg1.pub
  chmod 600 /etc/wireguard/wg1.key
  chmod 644 /etc/wireguard/wg1.pub
fi
WG1_PRIVKEY=$(cat /etc/wireguard/wg1.key)
WG1_PUBKEY=$(cat /etc/wireguard/wg1.pub)

cat > /etc/wireguard/wg1.conf << WG1CONF
[Interface]
Address = ${WG1_IPV4_TUNNEL}
ListenPort = ${WG1_LISTEN_PORT}
PrivateKey = ${WG1_PRIVKEY}
# Standard WireGuard (not AmneziaWG). Router clients.
# Peer isolation: wg1→internet only, no P2P, no mesh.
PostUp = iptables -A FORWARD -i wg1 -o ${DEFAULT_IFACE} -j ACCEPT; iptables -A FORWARD -i ${DEFAULT_IFACE} -o wg1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -A FORWARD -i wg1 -j DROP; iptables -t nat -A POSTROUTING -s ${WG1_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg1 -o ${DEFAULT_IFACE} -j ACCEPT; iptables -D FORWARD -i ${DEFAULT_IFACE} -o wg1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -D FORWARD -i wg1 -j DROP; iptables -t nat -D POSTROUTING -s ${WG1_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE
WG1CONF
chmod 600 /etc/wireguard/wg1.conf

systemctl enable wg-quick@wg1 2>&1 | tail -1
systemctl restart wg-quick@wg1
sleep 1
systemctl is-active wg-quick@wg1 >/dev/null || { echo "[FATAL] wg1 failed to start"; journalctl -u wg-quick@wg1 -n 20 --no-pager; exit 1; }

echo "  [ok] Standard WireGuard wg1 (interface: $WG1_SERVER_IP, port: $WG1_LISTEN_PORT, pubkey: $WG1_PUBKEY)"

# ── 3. AdGuard Home ───────────────────────────────────────────

mkdir -p /opt/adguardhome/conf /opt/adguardhome/work

if [ ! -f /opt/adguardhome/AdGuardHome ]; then
  AGH_VER="v0.107.73"
  curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VER}/AdGuardHome_linux_amd64.tar.gz" \
    | tar -xz -C /tmp
  mv /tmp/AdGuardHome/AdGuardHome /opt/adguardhome/
  chmod +x /opt/adguardhome/AdGuardHome
fi

# Hash the password with bcrypt
AGH_BCRYPT=$(python3 -c "import bcrypt, sys; pw=sys.argv[1].encode(); print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode())" "$AGH_PASSWORD")

# Write config using the format compatible with AGH v0.107.73
cat > /opt/adguardhome/conf/AdGuardHome.yaml << EOF
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:3000
  session_ttl: 720h
users:
  - name: admin
    password: ${AGH_BCRYPT}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - ${WG_SERVER_IP}
    - ${WG1_SERVER_IP}
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns10.quad9.net/dns-query
    - https://cloudflare-dns.com/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
  fallback_dns:
    - 9.9.9.9
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  hostsfile_enabled: true
  address_lists_cache_size: 0
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_enabled: true
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  safe_search:
    enabled: false
    bing: false
    duckduckgo: false
    ecosia: false
    google: false
    pixabay: false
    yandex: false
    youtube: false
  filters_update_interval: 24
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: false
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 29
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://big.oisd.nl
    name: OISD Full
    id: 2
EOF

# Systemd unit (uses conf/ subdir, consistent with fleet)
cat > /etc/systemd/system/adguardhome.service << 'EOF'
[Unit]
Description=AdGuard Home DNS
After=network-online.target awg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/adguardhome/AdGuardHome -c /opt/adguardhome/conf/AdGuardHome.yaml -w /opt/adguardhome/work --no-check-update
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable adguardhome
systemctl restart adguardhome

echo "  [ok] AdGuard Home (DNS on ${WG_SERVER_IP}:53)"

# ── 3b. Shadowsocks-rust SS-fallback (multi-user EIH, single port 8443) ───
#
# Standing rule (feedback_ss_rust_124_nested_config_required.md):
#   shadowsocks-rust 1.24.x MUST use nested "servers": [{...}] format.
#   Flat top-level format silently drops users[] — user_manager stays None,
#   EIH lookups fail with "decrypt header chunk failed". No parse error emitted.
#   Verified end-to-end on vpn-iad-01 2026-04-26 with two concurrent users.
#
# Each node has one SERVER_PSK (SS-2022 master key). Per-user PSKs are appended
# to users[] at peer provision time by artemis-api. Client password:
#   "<SERVER_PSK>:<USER_PSK>"
#
# Required env:
#   BOOTSTRAP_CF_TOKEN  — Cloudflare API token with DNS:edit for katafract.com
#                         (read from INFISICAL at bootstrap time by provisioner;
#                          never hardcoded here)
#   NODE_FQDN           — <node_id>.vpn.katafract.com (e.g. vpn-iad-01.vpn.katafract.com)
#                         Defaults to ${NODE_ID}.vpn.katafract.com if unset
#   INFISICAL_TOKEN     — machine identity token for pushing PSK to Infisical
#                         (usually already present from provisioner env)

: "${BOOTSTRAP_CF_TOKEN:?Required for SS-fallback LE cert (set by provisioner from Infisical)}"
: "${NODE_FQDN:=${NODE_ID}.vpn.katafract.com}"
: "${INFISICAL_BASE_URL:=http://100.64.0.1:8080}"

echo "==> Setting up SS-fallback for ${NODE_FQDN}..."

# Install certbot + dns-cloudflare plugin + shadowsocks-rust
apt-get install -y -qq certbot python3-certbot-dns-cloudflare

# Install shadowsocks-rust + v2ray-plugin if not already present
if [ ! -x /opt/shadowsocks-rust/ssservice ]; then
  SS_VER="1.24.0"
  curl -fsSL "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VER}/shadowsocks-v${SS_VER}.x86_64-unknown-linux-gnu.tar.xz" \
    | tar -xJ -C /tmp
  install -d /opt/shadowsocks-rust
  mv /tmp/ssservice /tmp/sslocal /tmp/ssmanager /opt/shadowsocks-rust/ 2>/dev/null || true
  # ssservice is the primary binary; ensure it's there
  ls /opt/shadowsocks-rust/ssservice >/dev/null || { echo "[FATAL] ssservice not found after extract"; exit 1; }
fi

if [ ! -x /usr/local/bin/v2ray-plugin ]; then
  V2RAY_VER="5.1.0"
  curl -fsSL "https://github.com/shadowsocks/v2ray-plugin/releases/download/v${V2RAY_VER}/v2ray-plugin-linux-amd64-v${V2RAY_VER}.tar.gz" \
    | tar -xz -C /tmp
  install -m 755 /tmp/v2ray-plugin_linux_amd64 /usr/local/bin/v2ray-plugin \
    || install -m 755 /tmp/v2ray-plugin /usr/local/bin/v2ray-plugin
fi

# Cloudflare credentials for certbot
install -d -m 700 /etc/letsencrypt
cat > /etc/letsencrypt/cf-katafract.ini << EOF_CF
dns_cloudflare_api_token = ${BOOTSTRAP_CF_TOKEN}
EOF_CF
chmod 600 /etc/letsencrypt/cf-katafract.ini

# Obtain LE cert via DNS-01 (works even before node is publicly reachable on 443)
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cf-katafract.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d "${NODE_FQDN}" \
  --non-interactive \
  --agree-tos \
  --email christian@katafract.com \
  || echo "  [warn] certbot returned non-zero — cert may already exist (idempotent run)"

# Install LE renewal-hook so ssservice restarts post-renewal
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-shadowsocks.sh <<'HOOK'
#!/bin/bash
# Reload ssservice so v2ray-plugin picks up the renewed cert
if systemctl is-active --quiet shadowsocks-server.service; then
  systemctl restart shadowsocks-server.service
fi
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-shadowsocks.sh
echo "  → LE deploy hook installed (auto-restart ssservice on cert renewal)"

# Generate per-node SERVER_PSK
install -d -m 700 /etc/shadowsocks
if [ ! -f /etc/shadowsocks/poc-secrets.txt ]; then
  SERVER_PSK=$(openssl rand -base64 32)
  echo "SERVER_PSK=${SERVER_PSK}" > /etc/shadowsocks/poc-secrets.txt
  chmod 600 /etc/shadowsocks/poc-secrets.txt
else
  # Idempotent: re-use existing PSK
  SERVER_PSK=$(grep -oP '(?<=SERVER_PSK=).*' /etc/shadowsocks/poc-secrets.txt)
fi

# Write nested-format server config (CRITICAL: flat format silently drops users[])
cat > /etc/shadowsocks/server.json << EOF_SS
{
  "servers": [
    {
      "server": "0.0.0.0",
      "server_port": 8443,
      "method": "2022-blake3-aes-256-gcm",
      "password": "${SERVER_PSK}",
      "users": [],
      "mode": "tcp_and_udp",
      "no_delay": true,
      "fast_open": false,
      "plugin": "/usr/local/bin/v2ray-plugin",
      "plugin_opts": "server;tls;cert=/etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem;key=/etc/letsencrypt/live/${NODE_FQDN}/privkey.pem;loglevel=warning"
    }
  ]
}
EOF_SS
chmod 600 /etc/shadowsocks/server.json

# Systemd unit
cat > /etc/systemd/system/shadowsocks-server.service << 'EOF_SVC'
[Unit]
Description=Shadowsocks-rust server (multi-user, single-port, v2ray-plugin TLS)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/shadowsocks-rust/ssservice server -c /etc/shadowsocks/server.json
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SVC

systemctl daemon-reload
systemctl enable shadowsocks-server.service
systemctl restart shadowsocks-server.service
sleep 2
systemctl is-active shadowsocks-server.service >/dev/null \
  || { echo "[FATAL] shadowsocks-server failed to start"; journalctl -u shadowsocks-server -n 20 --no-pager; exit 1; }

echo "  [ok] shadowsocks-server (8443, multi-user EIH, v2ray-plugin TLS)"

# Push SERVER_PSK to Infisical at prod/wraith/ss/<NODE_ID>/SERVER_PSK
# Bootstrap already has the Infisical machine identity token injected by provisioner.
if [ -n "${INFISICAL_TOKEN:-}" ]; then
  INFISICAL_API_URL="${INFISICAL_BASE_URL}" \
    infisical secrets set "SERVER_PSK=${SERVER_PSK}" \
      --token "${INFISICAL_TOKEN}" \
      --env prod \
      --path "/wraith/ss/${NODE_ID}" \
    && echo "  [ok] SERVER_PSK pushed to Infisical at prod/wraith/ss/${NODE_ID}" \
    || echo "  [warn] Infisical push failed — push SERVER_PSK manually: prod/wraith/ss/${NODE_ID}/SERVER_PSK"
else
  echo "  [warn] INFISICAL_TOKEN not set — SERVER_PSK NOT pushed to Infisical"
  echo "         Push manually: prod/wraith/ss/${NODE_ID}/SERVER_PSK"
fi

echo "  [ok] SS-fallback complete (port 8443, cert: ${NODE_FQDN})"

# ── 4. UFW firewall ───────────────────────────────────────────

apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed
ufw allow 22/tcp comment 'SSH'
ufw allow "${WG_LISTEN_PORT}/udp" comment 'WireGuard AWG'
ufw allow "${WG1_LISTEN_PORT}/udp" comment 'WireGuard router (standard)'
ufw allow in on wg0 to any port 53 proto udp comment 'Haven DNS (wg0)'
ufw allow in on wg0 to any port 53 proto tcp comment 'Haven DNS TCP (wg0)'
ufw allow in on wg1 to any port 53 proto udp comment 'Haven DNS (wg1)'
ufw allow in on wg1 to any port 53 proto tcp comment 'Haven DNS TCP (wg1)'
ufw allow 8443/tcp comment 'Wraith SS+v2ray-plugin TLS'
ufw --force enable

echo "  [ok] UFW firewall"

# ── 5. SSH hardening ──────────────────────────────────────────

# Create artemis + tek users if missing
for u in artemis tek; do
  id "$u" &>/dev/null || useradd -m -s /bin/bash "$u"
  usermod -p "*" "$u"  # unlock account without password (key-only)
done

# Grant artemis NOPASSWD sudo for fleet automation. Without this, every
# remote `sudo` call from artemis-api / artemis-worker / scheduler hangs
# waiting for a password prompt that never arrives.
install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/90-artemis-nopasswd <<'SUDOERS'
# Managed by katafract-node bootstrap.sh — do not edit manually.
artemis ALL=(ALL) NOPASSWD: ALL
SUDOERS
chmod 0440 /etc/sudoers.d/90-artemis-nopasswd
visudo -cf /etc/sudoers.d/90-artemis-nopasswd >/dev/null
echo "  [ok] artemis NOPASSWD sudo"

# Add the fleet SSH key to artemis and root
# FLEET_PUBKEY env var takes precedence (injected by provisioner); fall back to embedded key
FLEET_PUBKEY="${FLEET_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID2wuO8IVYfp0+mKvmOAI1QTyvnb3cRJ04ujX913Kd7I artemis@katafract.com}"
for u in artemis root; do
  home=$(eval echo "~$u")
  mkdir -p "$home/.ssh"
  chmod 700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  if ! grep -qF "$FLEET_PUBKEY" "$home/.ssh/authorized_keys" 2>/dev/null; then
    echo "$FLEET_PUBKEY" >> "$home/.ssh/authorized_keys"
  fi
  chmod 600 "$home/.ssh/authorized_keys"
  chown -R "$u:$u" "$home/.ssh"
done

# Restrict root to mesh-only, allow artemis+tek from anywhere
sed -i 's/^#\?AllowUsers.*//' /etc/ssh/sshd_config
echo "AllowUsers root@100.64.* tek artemis" >> /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "  [ok] SSH hardening (root mesh-only, artemis/tek anywhere)"

# ── 6. node_exporter ─────────────────────────────────────────

if ! command -v node_exporter &>/dev/null; then
  NE_VER="1.8.2"
  curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp
  mv "/tmp/node_exporter-${NE_VER}.linux-amd64/node_exporter" /usr/local/bin/
  chmod +x /usr/local/bin/node_exporter
fi

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo "  [ok] node_exporter (:9100)"

# ── 7. Katafract heartbeat agent ─────────────────────────────

cat > /usr/local/bin/katafract-heartbeat << HBEOF
#!/usr/bin/env bash
set -eo pipefail

ARTEMIS_URL="${ARTEMIS_HEARTBEAT_URL}"
TOKEN="${NODE_AGENT_TOKEN}"
source /etc/katafract-node.env
NODE_ID="\${KATAFRACT_NODE_ID}"
WG_IFACE="wg0"

# Prefer awg (AmneziaWG) — fall back to wg if not installed
AWG=\$(command -v awg || command -v wg || echo "")

# ── WireGuard metrics ─────────────────────────────────────────

registered_peers=0
active_peers=0
rx_bytes=0
tx_bytes=0

if [ -n "\$AWG" ]; then
    registered_peers=\$("\$AWG" show "\$WG_IFACE" peers 2>/dev/null | wc -l || echo 0)

    now=\$(date +%s)
    while IFS=\$'\t' read -r _ ts; do
        if [ "\$ts" != "0" ] && [ \$(( now - ts )) -le 180 ]; then
            active_peers=\$(( active_peers + 1 ))
        fi
    done < <("\$AWG" show "\$WG_IFACE" latest-handshakes 2>/dev/null || true)

    while IFS=\$'\t' read -r _ rx tx; do
        rx_bytes=\$(( rx_bytes + rx ))
        tx_bytes=\$(( tx_bytes + tx ))
    done < <("\$AWG" show "\$WG_IFACE" transfer 2>/dev/null || true)
fi

# ── WireGuard peer IPs (GeoIP country analytics) ─────────────
# declare -A outside if block — set -u false-positive on empty assoc array

peer_ips_json="[]"
declare -A seen_ips

if [ -n "\$AWG" ]; then
    while IFS=\$'\t' read -r pubkey endpoint; do
        [ -z "\$endpoint" ] || [ "\$endpoint" = "(none)" ] && continue
        ip="\$endpoint"
        if [[ "\$ip" == \[*\]:* ]]; then
            ip="\${ip%]:*}"; ip="\${ip#\[}"
        elif [[ "\$ip" == *:* ]]; then
            ip="\${ip%:*}"
        fi
        if [[ "\$ip" =~ ^10\. ]] || \
           [[ "\$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || \
           [[ "\$ip" =~ ^192\.168\. ]] || \
           [[ "\$ip" =~ ^100\.[6-9][0-9]\. ]] || \
           [[ "\$ip" =~ ^127\. ]]; then
            continue
        fi
        seen_ips["\$ip"]=1
    done < <("\$AWG" show "\$WG_IFACE" endpoints 2>/dev/null || true)

    if [ \${#seen_ips[@]} -gt 0 ]; then
        ips_array=()
        for ip in "\${!seen_ips[@]}"; do
            ips_array+=("\"\$ip\"")
        done
        peer_ips_json="[\$(IFS=,; echo "\${ips_array[*]}")]"
    fi
fi

# ── System metrics ────────────────────────────────────────────

ncpu=\$(nproc 2>/dev/null || echo 1)
load1=\$(awk '{print \$1}' /proc/loadavg)
cpu_pct=\$(awk "BEGIN{v=\$load1*100/\$ncpu; if(v>100) v=100; printf \"%d\", v}")

mem_total=\$(awk '/MemTotal/{print \$2}' /proc/meminfo)
mem_avail=\$(awk '/MemAvailable/{print \$2}' /proc/meminfo)
mem_pct=\$(( (mem_total - mem_avail) * 100 / mem_total ))

disk_pct=\$(df / 2>/dev/null | awk 'NR==2{gsub("%",""); print \$5}')
disk_pct=\${disk_pct:-0}

fail2ban_banned=0
if timeout 3 systemctl is-active fail2ban >/dev/null 2>&1; then
    jails=\$(timeout 5 fail2ban-client status 2>/dev/null \
        | awk -F':\t' '/Jail list/{print \$2}' \
        | tr ', ' '\n' | grep -v '^\$')
    if [ -n "\$jails" ]; then
        total=0
        while IFS= read -r jail; do
            count=\$(timeout 5 fail2ban-client status "\$jail" 2>/dev/null \
                | awk '/Currently banned/{print \$NF}')
            total=\$(( total + \${count:-0} ))
        done <<< "\$jails"
        fail2ban_banned=\$total
    fi
fi

# ── Report ────────────────────────────────────────────────────

curl -sf -X POST "\$ARTEMIS_URL" \
  -H "Authorization: Bearer \$TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"node_id\":        \"\$NODE_ID\",
    \"peers\":          \$registered_peers,
    \"active_peers\":   \$active_peers,
    \"rx_bytes\":       \$rx_bytes,
    \"tx_bytes\":       \$tx_bytes,
    \"healthy\":        true,
    \"cpu_pct\":        \$cpu_pct,
    \"mem_pct\":        \$mem_pct,
    \"disk_pct\":       \$disk_pct,
    \"fail2ban_banned\": \$fail2ban_banned,
    \"peer_ips\":       \$peer_ips_json
  }" \
  --max-time 10 || true
HBEOF
chmod +x /usr/local/bin/katafract-heartbeat

cat > /etc/katafract-node.env << EOF
KATAFRACT_NODE_ID=${NODE_ID}
EOF

cat > /etc/systemd/system/katafract-heartbeat.service << 'EOF'
[Unit]
Description=Katafract node heartbeat
After=network-online.target awg-quick@wg0.service

[Service]
Type=oneshot
EnvironmentFile=/etc/katafract-node.env
ExecStart=/usr/local/bin/katafract-heartbeat
EOF

cat > /etc/systemd/system/katafract-heartbeat.timer << 'EOF'
[Unit]
Description=Katafract heartbeat every 30s

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable katafract-heartbeat.timer
systemctl start katafract-heartbeat.timer

echo "  [ok] katafract-heartbeat (30s timer)"

# ── 8. Tailscale / Headscale mesh enrollment ─────────────────

if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

tailscale up \
  --login-server=https://mesh.katafract.io \
  --auth-key="${HEADSCALE_PREAUTH_KEY}" \
  --advertise-exit-node \
  --accept-dns=false \
  --hostname="${NODE_ID}" \
  || echo "  [warn] tailscale up returned non-zero (may already be enrolled)"

echo "  [ok] tailscale enrolled in headscale mesh"

# ── 9. Unattended upgrades ────────────────────────────────────

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52unattended-upgrades-katafract << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Package-Blacklist {
    "linux-image-*";
    "linux-headers-*";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Mail "christian@katafract.com";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_HOUR_UTC:-03:00}";
EOF

echo "  [ok] unattended-upgrades (reboot time set to ${REBOOT_HOUR_UTC:-03:00} UTC)"

# ── 10. Node identity summary ─────────────────────────────────

PUBLIC_IP=$(curl -sf https://api.ipify.org 2>/dev/null || echo "unknown")
MESH_IP=$(tailscale ip -4 2>/dev/null || echo "pending")

cat > /etc/katafract-node.json << EOF
{
  "node_id":          "${NODE_ID}",
  "site":             "${SITE}",
  "region":           "${REGION}",
  "public_ip":        "${PUBLIC_IP}",
  "mesh_ip":          "${MESH_IP}",
  "wg_pubkey":        "${WG_PUBLIC_KEY}",
  "wg_port":          ${WG_LISTEN_PORT},
  "wg_addr":          "${WG_SERVER_IP}",
  "wg1_pubkey":       "${WG1_PUBKEY}",
  "wg1_port":         ${WG1_LISTEN_PORT},
  "wg1_addr":         "${WG1_SERVER_IP}",
  "wg1_client_cidr":  "${WG1_SUBNET}",
  "bootstrapped_at":  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# ── 11. Self-register with platform (zero-touch) ────────────────

echo "[ok] registering with platform..."
_MESH_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "")
_WG_PUBKEY=$(awg show wg0 public-key 2>/dev/null || wg show wg0 public-key 2>/dev/null || echo "")
_ARTEMIS_BASE=$(echo "${ARTEMIS_HEARTBEAT_URL}" | sed 's|/nodes/heartbeat||')

_REG_PAYLOAD=$(cat <<REGEOF
{
  "node_id": "${NODE_ID}",
  "mesh_ip": "${_MESH_IP}",
  "public_key": "${_WG_PUBKEY}",
  "wg_server_addr": "${WG_SERVER_IP}",
  "wg1_public_key": "${WG1_PUBKEY}",
  "wg1_port": ${WG1_LISTEN_PORT},
  "wg1_client_cidr": "${WG1_SUBNET}",
  "wg1_server_addr": "${WG1_SERVER_IP}",
  "ss_fallback_endpoint": "${NODE_FQDN}:8443",
  "bootstrapped_at": $(date +%s),
  "site": "${SITE}",
  "region": "${REGION}"
}
REGEOF
)

_REG_RESP=$(curl -sf --max-time 15 -X POST "${_ARTEMIS_BASE}/nodes/register" \
  -H "Authorization: Bearer ${NODE_AGENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$_REG_PAYLOAD" 2>/dev/null)

if [ $? -eq 0 ]; then
  echo "  [ok] self-registration succeeded"
else
  echo "  [warn] self-registration failed (non-fatal — heartbeat will sync later)"
fi

echo ""
echo "============================================"
echo "  Bootstrap complete: ${NODE_ID}"
echo "  AWG pubkey (wg0):   ${WG_PUBLIC_KEY}"
echo "  AWG addr:           ${WG_SERVER_IP}"
echo "  AWG port:           ${WG_LISTEN_PORT}"
echo "  Std pubkey (wg1):   ${WG1_PUBKEY}"
echo "  Std addr:           ${WG1_SERVER_IP}"
echo "  Std port:           ${WG1_LISTEN_PORT}"
echo "  SS-fallback:        ${NODE_FQDN}:8443 (TCP, v2ray-plugin TLS)"
echo "  Public IP:          ${PUBLIC_IP}"
echo "  Mesh IP:            ${MESH_IP}"
echo "============================================"
echo ""
echo "  Reboot time: update /etc/apt/apt.conf.d/52unattended-upgrades-katafract"
echo ""
