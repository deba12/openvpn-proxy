#!/bin/bash
# Container entrypoint — starts OpenVPN server only.
set -e

# If the user passed a script to execute (like init-ca.sh), run it directly and exit
if [[ "$1" == *.sh ]]; then
    exec "$@"
fi

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
if [ -w /proc/sys/net/ipv4/ip_forward ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward
else
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
        echo "WARNING: /proc/sys/net/ipv4/ip_forward is not writable. Please ensure IP forwarding is enabled on the host:"
        echo "  sysctl -w net.ipv4.ip_forward=1"
    fi
fi

# ── PKI check ────────────────────────────────────────────────────────────────
if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo "ERROR: PKI not initialized. Run init-ca.sh first:"
    echo "  docker compose run --rm openvpn init-ca.sh"
    exit 1
fi

# ── Parse CLIENT_NETWORK into IP and netmask for OpenVPN config ───────────────
CLIENT_IP="${CLIENT_NETWORK%/*}"
CLIENT_PREFIX="${CLIENT_NETWORK#*/}"

prefix_to_mask() {
    local prefix=$1
    local mask=""
    local octet
    for i in 1 2 3 4; do
        if [ $prefix -ge 8 ]; then
            octet=255
            prefix=$((prefix - 8))
        elif [ $prefix -gt 0 ]; then
            octet=$(( 256 - (1 << (8 - prefix)) ))
            prefix=0
        else
            octet=0
        fi
        mask="${mask}${octet}"
        [ $i -lt 4 ] && mask="${mask}."
    done
    echo "$mask"
}

CLIENT_MASK=$(prefix_to_mask "$CLIENT_PREFIX")

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

# Statically route client network onto the host routing table when OpenVPN starts
route $CLIENT_IP $CLIENT_MASK

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
