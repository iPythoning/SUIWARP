#!/usr/bin/env bash
# SUIWARP - S-UI + Cloudflare WARP One-Liner Setup
# https://github.com/iPythoning/SUIWARP
# License: MIT
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

# ─── Pre-flight checks ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="amd64" ;;
  aarch64) ARCH_SUFFIX="arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

OS=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
[[ "$OS" != "ubuntu" && "$OS" != "debian" ]] && warn "Tested on Ubuntu/Debian only, proceeding anyway..."

SERVER_IP=$(curl -s --max-time 10 ifconfig.me || curl -s --max-time 10 icanhazip.com)
[[ -z "$SERVER_IP" ]] && error "Cannot detect public IP"
info "Server IP: $SERVER_IP"

# ─── Configuration ───────────────────────────────────────────────────
WGCF_VERSION="2.2.22"
WIREPROXY_VERSION="1.0.9"
S_UI_INSTALL_URL="https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
WIREPROXY_SOCKS_PORT=40000
SWAP_SIZE="2G"
SNI_TARGET="www.samsung.com"

# ─── Step 1: System dependencies ────────────────────────────────────
step "1/7 Installing dependencies"
apt-get update -qq
apt-get install -y -qq curl wget sqlite3 jq ufw > /dev/null 2>&1
info "Dependencies installed"

# ─── Step 2: Swap (if not present) ──────────────────────────────────
step "2/7 Configuring swap"
if [[ ! -f /swapfile ]]; then
  TOTAL_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [[ $TOTAL_MEM_MB -lt 4096 ]]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 > /dev/null
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    info "Created ${SWAP_SIZE} swap (swappiness=10)"
  else
    info "Sufficient RAM (${TOTAL_MEM_MB}MB), skipping swap"
  fi
else
  swapon /swapfile 2>/dev/null || true
  info "Swap already exists"
fi

# ─── Step 3: Install S-UI ───────────────────────────────────────────
step "3/7 Installing S-UI"
if systemctl is-active --quiet s-ui 2>/dev/null; then
  info "S-UI already running, skipping installation"
else
  # Install S-UI (uses its own installer)
  bash <(curl -sL "$S_UI_INSTALL_URL") <<< "y" || {
    warn "S-UI interactive install, trying alternative..."
    echo "y" | bash <(curl -sL "$S_UI_INSTALL_URL")
  }
  systemctl enable s-ui
  info "S-UI installed"
fi

# Wait for S-UI to be ready
sleep 3
S_UI_DB="/usr/local/s-ui/db/s-ui.db"
[[ ! -f "$S_UI_DB" ]] && error "S-UI database not found at $S_UI_DB"

# ─── Step 4: Generate Reality keypair & configure inbounds ──────────
step "4/7 Configuring S-UI inbounds"

# Generate Reality keypair
REALITY_OUTPUT=$(/usr/local/s-ui/sui generate reality-keypair 2>/dev/null || echo "")
if [[ -n "$REALITY_OUTPUT" ]]; then
  PRIVATE_KEY=$(echo "$REALITY_OUTPUT" | grep -oP '(?<=PrivateKey: ).+' || echo "")
  PUBLIC_KEY=$(echo "$REALITY_OUTPUT" | grep -oP '(?<=PublicKey: ).+' || echo "")
fi

# Fallback: check if keys already exist in DB
if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" ]]; then
  PRIVATE_KEY=$(sqlite3 "$S_UI_DB" "SELECT json FROM tls WHERE id=1;" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.loads(sys.stdin.read())
  print(d.get('reality',{}).get('private_key',''))
except: pass
" 2>/dev/null || echo "")
  PUBLIC_KEY=$(sqlite3 "$S_UI_DB" "SELECT json FROM tls WHERE id=1;" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.loads(sys.stdin.read())
  print(d.get('reality',{}).get('public_key',''))
except: pass
" 2>/dev/null || echo "")
fi

# If still no keys, generate with openssl
if [[ -z "${PRIVATE_KEY:-}" ]]; then
  warn "Could not generate Reality keypair via S-UI, using existing config"
fi

UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
PASSWORD=$(python3 -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(12)).decode())")
SHORT_ID=$(python3 -c "import secrets; print(secrets.token_hex(4))")

info "UUID: $UUID"
info "Password: $PASSWORD"
info "Short ID: $SHORT_ID"

# Configure inbounds via Python for reliability
python3 << PYEOF
import sqlite3, json, os

DB = "$S_UI_DB"
SERVER_IP = "$SERVER_IP"
UUID = "$UUID"
PASSWORD = "$PASSWORD"
SHORT_ID = "$SHORT_ID"
PRIVATE_KEY = "${PRIVATE_KEY:-}"
PUBLIC_KEY = "${PUBLIC_KEY:-}"
SNI = "$SNI_TARGET"

conn = sqlite3.connect(DB)
cur = conn.cursor()

# Check if inbounds already configured
cur.execute("SELECT COUNT(*) FROM inbounds")
count = cur.fetchone()[0]
if count > 0:
    print(f"Inbounds already configured ({count} entries), skipping")
    # Still update server IP in existing config
    cur.execute("SELECT id, out_json FROM inbounds")
    for row in cur.fetchall():
        rid = row[0]
        out_json = row[1]
        if isinstance(out_json, bytes):
            out_json = out_json.decode("utf-8")
        if out_json:
            data = json.loads(out_json)
            data["server"] = SERVER_IP
            cur.execute("UPDATE inbounds SET out_json=? WHERE id=?",
                        (json.dumps(data).encode("utf-8"), rid))
    conn.commit()
    conn.close()
    exit(0)

# TLS configurations
reality_tls_server = json.dumps({
    "enabled": True,
    "server_name": SNI,
    "reality": {
        "enabled": True,
        "handshake": {"server": SNI, "server_port": 443},
        "private_key": PRIVATE_KEY,
        "short_id": [SHORT_ID, ""]
    }
})

reality_tls_client = json.dumps({
    "utls": {"enabled": True, "fingerprint": "chrome"},
    "reality": {"public_key": PUBLIC_KEY}
})

self_signed_tls_server = json.dumps({
    "enabled": True,
    "certificate_path": "/usr/local/s-ui/certs/server.crt",
    "key_path": "/usr/local/s-ui/certs/server.key",
    "alpn": ["h3", "h2", "http/1.1"]
})

self_signed_tls_client = json.dumps({"insecure": True})

# Insert TLS configs
cur.execute("INSERT OR REPLACE INTO tls (id, type, json, client) VALUES (1, 'reality', ?, ?)",
            (reality_tls_server.encode("utf-8"), reality_tls_client.encode("utf-8")))
cur.execute("INSERT OR REPLACE INTO tls (id, type, json, client) VALUES (2, 'tls-self', ?, ?)",
            (self_signed_tls_server.encode("utf-8"), self_signed_tls_client.encode("utf-8")))

# Inbound definitions
inbounds = [
    {
        "type": "vless", "tag": "vless-reality", "tls_id": 1,
        "out_json": {
            "server": SERVER_IP, "server_port": 443,
            "tag": "vless-reality", "type": "vless",
            "tls": {
                "enabled": True, "server_name": SNI,
                "reality": {"enabled": True, "public_key": PUBLIC_KEY, "short_id": SHORT_ID},
                "utls": {"enabled": True, "fingerprint": "chrome"}
            },
            "transport": {}
        },
        "options": {
            "listen": "::", "listen_port": 443,
            "multiplex": {}, "transport": {}
        }
    },
    {
        "type": "tuic", "tag": "tuic-443", "tls_id": 2,
        "out_json": {
            "server": SERVER_IP, "server_port": 443,
            "tag": "tuic-443", "type": "tuic",
            "congestion_control": "bbr",
            "tls": {"enabled": True, "insecure": True, "alpn": ["h3","h2","http/1.1"]}
        },
        "options": {
            "congestion_control": "bbr",
            "listen": "::", "listen_port": 443
        }
    },
    {
        "type": "hysteria2", "tag": "hysteria2-8443", "tls_id": 2,
        "out_json": {
            "server": SERVER_IP, "server_port": 8443,
            "tag": "hysteria2-8443", "type": "hysteria2",
            "tls": {"enabled": True, "insecure": True, "server_name": "www.bing.com"}
        },
        "options": {
            "listen": "::", "listen_port": 8443,
            "up_mbps": 200, "down_mbps": 200
        }
    },
    {
        "type": "vless", "tag": "vless-reality-grpc", "tls_id": 1,
        "out_json": {
            "server": SERVER_IP, "server_port": 2053,
            "tag": "vless-reality-grpc", "type": "vless",
            "tls": {
                "enabled": True, "server_name": SNI,
                "reality": {"enabled": True, "public_key": PUBLIC_KEY, "short_id": SHORT_ID},
                "utls": {"enabled": True, "fingerprint": "chrome"}
            },
            "transport": {"type": "grpc", "service_name": "grpc"}
        },
        "options": {
            "listen": "::", "listen_port": 2053,
            "multiplex": {},
            "transport": {"type": "grpc", "service_name": "grpc"}
        }
    },
    {
        "type": "trojan", "tag": "trojan-reality", "tls_id": 1,
        "out_json": {
            "server": SERVER_IP, "server_port": 8880,
            "tag": "trojan-reality", "type": "trojan",
            "tls": {
                "enabled": True, "server_name": SNI,
                "reality": {"enabled": True, "public_key": PUBLIC_KEY, "short_id": SHORT_ID},
                "utls": {"enabled": True, "fingerprint": "chrome"}
            },
            "transport": {}
        },
        "options": {
            "listen": "::", "listen_port": 8880,
            "multiplex": {}, "transport": {}
        }
    },
    {
        "type": "vless", "tag": "vless-reality-ws", "tls_id": 1,
        "out_json": {
            "server": SERVER_IP, "server_port": 2083,
            "tag": "vless-reality-ws", "type": "vless",
            "tls": {
                "enabled": True, "server_name": SNI,
                "reality": {"enabled": True, "public_key": PUBLIC_KEY, "short_id": SHORT_ID},
                "utls": {"enabled": True, "fingerprint": "chrome"}
            },
            "transport": {"type": "ws", "path": "/ws"}
        },
        "options": {
            "listen": "::", "listen_port": 2083,
            "multiplex": {},
            "transport": {"type": "ws", "path": "/ws"}
        }
    }
]

for ib in inbounds:
    cur.execute(
        "INSERT INTO inbounds (type, tag, tls_id, addrs, out_json, options) VALUES (?, ?, ?, ?, ?, ?)",
        (ib["type"], ib["tag"], ib["tls_id"],
         json.dumps([]).encode("utf-8"),
         json.dumps(ib["out_json"]).encode("utf-8"),
         json.dumps(ib["options"]).encode("utf-8"))
    )

# Insert default client
client_config = {
    "vless": {"name": "default-user", "uuid": UUID, "flow": "xtls-rprx-vision"},
    "trojan": {"name": "default-user", "password": PASSWORD},
    "tuic": {"name": "default-user", "uuid": UUID, "password": PASSWORD},
    "hysteria2": {"name": "default-user", "password": PASSWORD},
    "shadowsocks": {"name": "default-user", "password": PASSWORD}
}

links = [
    {"remark": "vless-reality", "type": "local",
     "uri": f"vless://{UUID}@{SERVER_IP}:443?flow=xtls-rprx-vision&fp=chrome&pbk={PUBLIC_KEY}&security=reality&sni={SNI}&sid={SHORT_ID}&type=tcp#vless-reality"},
    {"remark": "tuic-443", "type": "local",
     "uri": f"tuic://{UUID}:{PASSWORD}@{SERVER_IP}:443?alpn=h3,h2,http/1.1&congestion_control=bbr&insecure=1#tuic-443"},
    {"remark": "hysteria2-8443", "type": "local",
     "uri": f"hy2://{PASSWORD}@{SERVER_IP}:8443?insecure=1&sni=www.bing.com#hysteria2-8443"},
    {"remark": "vless-reality-grpc", "type": "local",
     "uri": f"vless://{UUID}@{SERVER_IP}:2053?fp=chrome&pbk={PUBLIC_KEY}&security=reality&sni={SNI}&sid={SHORT_ID}&type=grpc&serviceName=grpc#vless-reality-grpc"},
    {"remark": "trojan-reality", "type": "local",
     "uri": f"trojan://{PASSWORD}@{SERVER_IP}:8880?fp=chrome&pbk={PUBLIC_KEY}&security=reality&sni={SNI}&sid={SHORT_ID}&type=tcp#trojan-reality"},
    {"remark": "vless-reality-ws", "type": "local",
     "uri": f"vless://{UUID}@{SERVER_IP}:2083?fp=chrome&pbk={PUBLIC_KEY}&security=reality&sni={SNI}&sid={SHORT_ID}&type=ws&path=/ws#vless-reality-ws"},
]

cur.execute(
    "INSERT INTO clients (enable, name, config, inbounds, links, volume, expiry, down, up) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    (1, "default-user",
     json.dumps(client_config).encode("utf-8"),
     json.dumps([3,5,2,1,4,6]).encode("utf-8"),
     json.dumps(links).encode("utf-8"),
     0, 0, 0, 0)
)

print(f"Configured {len(inbounds)} inbounds + 1 client")
conn.commit()
conn.close()
PYEOF

# ─── Step 5: Install wireproxy + WARP ───────────────────────────────
step "5/7 Setting up WARP via wireproxy"

# Install wgcf
if ! command -v wgcf &>/dev/null; then
  curl -sL "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${ARCH_SUFFIX}" \
    -o /usr/local/bin/wgcf
  chmod +x /usr/local/bin/wgcf
  info "wgcf installed"
fi

# Install wireproxy
if ! command -v wireproxy &>/dev/null; then
  curl -sL "https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_${ARCH_SUFFIX}.tar.gz" \
    -o /tmp/wireproxy.tar.gz
  tar -xzf /tmp/wireproxy.tar.gz -C /tmp/ wireproxy 2>/dev/null || true
  mv /tmp/wireproxy /usr/local/bin/ 2>/dev/null || true
  chmod +x /usr/local/bin/wireproxy
  rm -f /tmp/wireproxy.tar.gz
  info "wireproxy installed"
fi

# Register WARP account
WARP_DIR="/etc/suiwarp"
mkdir -p "$WARP_DIR"

if [[ ! -f "$WARP_DIR/wgcf-account.toml" ]]; then
  cd "$WARP_DIR"
  echo "y" | wgcf register --config "$WARP_DIR/wgcf-account.toml" 2>&1 | tail -5
  info "WARP account registered"
else
  info "WARP account already exists"
fi

# Generate WireGuard profile
if [[ ! -f "$WARP_DIR/wgcf-profile.conf" ]]; then
  wgcf generate --config "$WARP_DIR/wgcf-account.toml" \
    --profile "$WARP_DIR/wgcf-profile.conf" 2>&1 | tail -3
  info "WireGuard profile generated"
fi

# Extract WireGuard params
WG_PRIVATE_KEY=$(grep 'PrivateKey' "$WARP_DIR/wgcf-profile.conf" | awk '{print $3}')
WG_ADDRESS_V4=$(grep 'Address' "$WARP_DIR/wgcf-profile.conf" | head -1 | awk '{print $3}')
WG_ADDRESS_V6=$(grep 'Address' "$WARP_DIR/wgcf-profile.conf" | tail -1 | awk '{print $3}')
WG_PUBLIC_KEY=$(grep 'PublicKey' "$WARP_DIR/wgcf-profile.conf" | awk '{print $3}')
WG_ENDPOINT=$(grep 'Endpoint' "$WARP_DIR/wgcf-profile.conf" | awk '{print $3}')

# Create wireproxy config
cat > /etc/wireproxy.conf << EOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_ADDRESS_V4}
Address = ${WG_ADDRESS_V6}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${WG_PUBLIC_KEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0

[Socks5]
BindAddress = 127.0.0.1:${WIREPROXY_SOCKS_PORT}
EOF

# Create systemd service
cat > /etc/systemd/system/wireproxy-warp.service << EOF
[Unit]
Description=WireProxy WARP SOCKS5 Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/wireproxy -c /etc/wireproxy.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wireproxy-warp
systemctl restart wireproxy-warp
sleep 2

# Verify WARP connectivity
WARP_IP=$(curl -s --max-time 10 -x socks5h://127.0.0.1:${WIREPROXY_SOCKS_PORT} ifconfig.me 2>/dev/null || echo "")
if [[ -n "$WARP_IP" ]]; then
  info "WARP active! Exit IP: $WARP_IP"
else
  warn "WARP connection pending (may take a few seconds)"
fi

# ─── Step 6: Wire WARP into S-UI ────────────────────────────────────
step "6/7 Connecting S-UI to WARP exit"

python3 << PYEOF
import sqlite3, json

DB = "$S_UI_DB"
SOCKS_PORT = $WIREPROXY_SOCKS_PORT

conn = sqlite3.connect(DB)
cur = conn.cursor()

# Add WARP SOCKS5 outbound
warp_opts = {"server": "127.0.0.1", "server_port": SOCKS_PORT, "version": "5"}
cur.execute("SELECT id FROM outbounds WHERE tag='warp'")
if cur.fetchone():
    cur.execute("UPDATE outbounds SET type='socks', options=? WHERE tag='warp'",
                (json.dumps(warp_opts).encode("utf-8"),))
else:
    cur.execute("INSERT INTO outbounds (type, tag, options) VALUES ('socks', 'warp', ?)",
                (json.dumps(warp_opts).encode("utf-8"),))

# Update routing config: default -> warp, private -> direct
config = {
    "log": {"level": "warn"},
    "dns": {
        "servers": [
            {"tag": "cloudflare", "address": "tls://1.1.1.1", "detour": "direct"},
            {"tag": "google", "address": "tls://8.8.8.8", "detour": "direct"}
        ],
        "strategy": "prefer_ipv4"
    },
    "route": {
        "rules": [
            {"protocol": ["dns"], "action": "hijack-dns"},
            {"ip_is_private": True, "outbound": "direct"}
        ],
        "final": "warp"
    },
    "experimental": {}
}
cur.execute("UPDATE settings SET value=? WHERE key='config'",
            (json.dumps(config, indent=2),))

# Fix timezone
cur.execute("UPDATE settings SET value='UTC' WHERE key='timeLocation'")

print("S-UI routing -> WARP configured")
conn.commit()
conn.close()
PYEOF

# Restart S-UI
systemctl restart s-ui
sleep 4

# Verify sing-box started
if journalctl -u s-ui --no-pager -n 5 | grep -q "sing-box started"; then
  info "sing-box started successfully"
else
  warn "sing-box may need a moment to initialize"
fi

# ─── Step 7: Firewall ───────────────────────────────────────────────
step "7/7 Configuring firewall"

# Detect SSH port
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
SSH_PORT=${SSH_PORT:-22}

ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

ufw allow "$SSH_PORT"/tcp comment "SSH" > /dev/null 2>&1
ufw allow 443/tcp  comment "VLESS-Reality-Vision" > /dev/null 2>&1
ufw allow 443/udp  comment "TUIC-v5" > /dev/null 2>&1
ufw allow 8443/udp comment "Hysteria2" > /dev/null 2>&1
ufw allow 2053/tcp comment "VLESS-Reality-gRPC" > /dev/null 2>&1
ufw allow 8880/tcp comment "Trojan-Reality" > /dev/null 2>&1
ufw allow 2083/tcp comment "VLESS-Reality-WS" > /dev/null 2>&1
ufw allow 2095/tcp comment "S-UI-Panel" > /dev/null 2>&1
ufw allow 2096/tcp comment "S-UI-Sub" > /dev/null 2>&1

echo "y" | ufw enable > /dev/null 2>&1
info "Firewall configured (SSH:$SSH_PORT + all proxy ports)"

# ─── Summary ─────────────────────────────────────────────────────────
step "Setup Complete!"

WARP_EXIT=$(curl -s --max-time 10 -x socks5h://127.0.0.1:${WIREPROXY_SOCKS_PORT} ifconfig.me 2>/dev/null || echo "pending")
WARP_ORG=$(curl -s --max-time 10 -x socks5h://127.0.0.1:${WIREPROXY_SOCKS_PORT} "https://ipinfo.io/org" 2>/dev/null || echo "")

# Generate client links file
cat > /root/suiwarp-client-links.txt << EOF
# ============================================================
# SUIWARP Client Links
# Server: ${SERVER_IP}  |  SNI: ${SNI_TARGET}
# WARP Exit: ${WARP_EXIT} (${WARP_ORG})
# ============================================================

UUID:     ${UUID}
Password: ${PASSWORD}
Short ID: ${SHORT_ID}

[1] VLESS Reality Vision (TCP:443) - Daily driver
$(sqlite3 "$S_UI_DB" "SELECT links FROM clients LIMIT 1;" | python3 -c "
import sys,json
d=sys.stdin.buffer.read().decode()
for l in json.loads(d):
    print(f\"[{l['remark']}] {l['uri']}\")" 2>/dev/null || echo "Check S-UI panel for links")
EOF

echo -e "
${BOLD}┌─────────────────────────────────────────────────────┐${NC}
${BOLD}│${NC}  ${GREEN}SUIWARP deployed successfully!${NC}                      ${BOLD}│${NC}
${BOLD}├─────────────────────────────────────────────────────┤${NC}
${BOLD}│${NC}  Server IP:   ${CYAN}${SERVER_IP}${NC}
${BOLD}│${NC}  WARP Exit:   ${CYAN}${WARP_EXIT}${NC}
${BOLD}│${NC}  WARP Org:    ${CYAN}${WARP_ORG}${NC}
${BOLD}│${NC}                                                     ${BOLD}│${NC}
${BOLD}│${NC}  Panel:       ${YELLOW}http://${SERVER_IP}:2095/app/${NC}
${BOLD}│${NC}  Sub URL:     ${YELLOW}http://${SERVER_IP}:2096/sub/${NC}
${BOLD}│${NC}  Credentials: ${YELLOW}admin / admin${NC}  (change immediately!)
${BOLD}│${NC}                                                     ${BOLD}│${NC}
${BOLD}│${NC}  Protocols:                                          ${BOLD}│${NC}
${BOLD}│${NC}    1. VLESS Reality Vision  :443/tcp                  ${BOLD}│${NC}
${BOLD}│${NC}    2. TUIC v5               :443/udp                  ${BOLD}│${NC}
${BOLD}│${NC}    3. Hysteria2             :8443/udp                 ${BOLD}│${NC}
${BOLD}│${NC}    4. VLESS Reality gRPC    :2053/tcp                 ${BOLD}│${NC}
${BOLD}│${NC}    5. Trojan Reality        :8880/tcp                 ${BOLD}│${NC}
${BOLD}│${NC}    6. VLESS Reality WS      :2083/tcp                 ${BOLD}│${NC}
${BOLD}│${NC}                                                     ${BOLD}│${NC}
${BOLD}│${NC}  Client links: ${YELLOW}/root/suiwarp-client-links.txt${NC}
${BOLD}│${NC}  Memory:       ${GREEN}~60MB total (S-UI + wireproxy)${NC}
${BOLD}└─────────────────────────────────────────────────────┘${NC}
"

info "Client links saved to /root/suiwarp-client-links.txt"
info "Change panel password: http://${SERVER_IP}:2095/app/"
