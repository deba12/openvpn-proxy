#!/bin/bash
# Container entrypoint.
# Validates env, writes configs, starts nginx, then exec's OpenVPN.
set -e

# ── Required env vars ─────────────────────────────────────────────────────────
: "${SERVER_IP:?SERVER_IP must be set (public IP or hostname of this server)}"
: "${CLIENT_NETWORK:?CLIENT_NETWORK must be set (e.g. 10.20.30.0/24)}"
: "${BACKEND_IP:?BACKEND_IP must be set (IP of the backend service)}"

# ── Optional env vars with defaults ──────────────────────────────────────────
BACKEND_PORT="${BACKEND_PORT:-80}"
OVPN_PORT="${OVPN_PORT:-1194}"
NGINX_PORT="${NGINX_PORT:-80}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_SUBNET_MASK="${VPN_SUBNET_MASK:-255.255.255.0}"
PKI_DIR=/etc/openvpn/pki

# ── TUN device ────────────────────────────────────────────────────────────────
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# ── Kernel: IP forwarding ─────────────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/ip_forward

# ── PKI check ────────────────────────────────────────────────────────────────
if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo "ERROR: PKI not initialized. Run init-ca.sh first:"
    echo "  docker compose run --rm openvpn-proxy init-ca.sh"
    exit 1
fi

# ── OpenVPN server config ─────────────────────────────────────────────────────
OVPN_CONF=/etc/openvpn/server.conf
if [ ! -f "$OVPN_CONF" ]; then
    cat > "$OVPN_CONF" <<EOF
port $OVPN_PORT
proto tcp
dev tun

ca   $PKI_DIR/ca.crt
cert $PKI_DIR/issued/server.crt
key  $PKI_DIR/private/server.key
dh   $PKI_DIR/dh.pem

server $VPN_SUBNET $VPN_SUBNET_MASK
topology subnet

# Allow same certificate to reconnect (new connection kills the old one
# via the client-connect script + management interface).
duplicate-cn

keepalive 10 60

# MikroTik-compatible cipher — no tls-auth, no tls-crypt, no compression.
data-ciphers AES-256-CBC
data-ciphers-fallback AES-256-CBC
cipher AES-256-CBC
auth SHA256

persist-key
persist-tun

status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3

# Management interface (used by client-connect to kill old sessions).
management 127.0.0.1 5555

script-security 2
client-connect  /usr/local/bin/client-connect.sh
client-disconnect /usr/local/bin/client-disconnect.sh

# Pass CLIENT_NETWORK into hook scripts.
setenv CLIENT_NETWORK $CLIENT_NETWORK
EOF
    echo "OpenVPN config written to $OVPN_CONF"
fi

# ── Nginx config ──────────────────────────────────────────────────────────────
cat > /etc/nginx/sites-enabled/proxy.conf <<EOF
server {
    listen $NGINX_PORT;

    proxy_connect_timeout 10s;
    proxy_read_timeout    60s;
    proxy_send_timeout    60s;

    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    location / {
        proxy_pass http://$BACKEND_IP:$BACKEND_PORT;
    }
}
EOF

nginx -t
nginx

echo "Nginx started, proxying :$NGINX_PORT → $BACKEND_IP:$BACKEND_PORT"
echo "Waiting for VPN client from network $CLIENT_NETWORK..."

# OpenVPN takes over the process (exec replaces the shell).
exec openvpn --config "$OVPN_CONF"
