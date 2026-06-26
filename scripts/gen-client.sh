#!/bin/bash
# Generate a standard OpenVPN client certificate and inline .ovpn config.
# Usage: gen-client.sh <client-name>
#   docker compose exec openvpn-proxy gen-client.sh myclient
set -e

CLIENT_NAME="${1:?Usage: gen-client.sh <client-name>}"
PKI_DIR=/etc/openvpn/pki
OUT_DIR="$PKI_DIR/clients/$CLIENT_NAME"
SERVER_IP="${SERVER_IP:?SERVER_IP env var not set}"
OVPN_PORT="${OVPN_PORT:-1194}"

export EASYRSA_PKI="$PKI_DIR"
export EASYRSA_BATCH=1

if [ ! -f "$PKI_DIR/ca.crt" ]; then
    echo "PKI not initialized. Run init-ca.sh first."
    exit 1
fi

cd /usr/share/easy-rsa

if [ -f "$PKI_DIR/issued/${CLIENT_NAME}.crt" ]; then
    echo "Certificate for '$CLIENT_NAME' already exists. Skipping generation." >&2
else
    echo ">>> Generating certificate for '$CLIENT_NAME'..." >&2
    ./easyrsa build-client-full "$CLIENT_NAME" nopass
fi

mkdir -p "$OUT_DIR"

OVPN_FILE="$OUT_DIR/${CLIENT_NAME}.ovpn"

cat > "$OVPN_FILE" <<EOF
client
dev tun
proto tcp
remote $SERVER_IP $OVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
verb 3

<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<cert>
$(openssl x509 -in "$PKI_DIR/issued/${CLIENT_NAME}.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/${CLIENT_NAME}.key")
</key>
EOF

cat "$OVPN_FILE"
echo "" >&2
echo "Client config written to: $OVPN_FILE" >&2
