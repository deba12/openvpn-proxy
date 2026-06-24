#!/bin/bash
# Container entrypoint — starts OpenVPN server only.
# Routes to CLIENT_NETWORK are managed by client-connect/client-disconnect hooks.
set -e

: "${SERVER_IP:?SERVER_IP must be set (public IP or hostname of this server)}"
: "${CLIENT_NETWORK:?CLIENT_NETWORK must be set (e.g. 10.20.30.0/24)}"

OVPN_PORT="${OVPN_PORT:-1194}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_SUBNET_MASK="${VPN_SUBNET_MASK:-255.255.255.0}"
PKI_DIR=/etc/openvpn/pki

# ── TUN device ────────────────────────────────────────────────────────────────
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# ── IP forwarding ─────────────────────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/ip_forward

# ── PKI check ────────────────────────────────────────────────────────────────
if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo "ERROR: PKI not initialized. Run init-ca.sh first:"
    echo "  docker compose run --rm openvpn init-ca.sh"
    exit 1
fi

# ── OpenVPN server config ─────────────────────────────────────────────────────
OVPN_CONF=/etc/openvpn/server.conf
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

# Allow same certificate to reconnect — new connection kills the old one
# via the management interface in client-connect.sh.
duplicate-cn

keepalive 10 60

# MikroTik-compatible: no tls-auth, no tls-crypt, no compression.
data-ciphers AES-256-CBC
data-ciphers-fallback AES-256-CBC
cipher AES-256-CBC
auth SHA256

persist-key
persist-tun

status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3

# Management socket — used by client-connect.sh to terminate stale sessions.
management 127.0.0.1 5555

script-security 2
client-connect    /usr/local/bin/client-connect.sh
client-disconnect /usr/local/bin/client-disconnect.sh

# Passed into hook scripts via OpenVPN environment.
setenv CLIENT_NETWORK $CLIENT_NETWORK
EOF

echo "OpenVPN starting — tunnel subnet $VPN_SUBNET/$VPN_SUBNET_MASK, client network $CLIENT_NETWORK"

exec openvpn --config "$OVPN_CONF"
