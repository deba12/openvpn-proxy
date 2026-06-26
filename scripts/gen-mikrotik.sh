#!/bin/bash
# Generate MikroTik OVPN client configs.
# Outputs:
#   <name>.ovpn         — importable via Winbox Files (RouterOS 7+)
#   <name>-routeros.rsc — RouterOS CLI script (paste or /import)
#   ca.crt / <name>.crt / <name>.key — individual files for manual upload (older RouterOS)
#
# Usage: gen-mikrotik.sh <client-name>
#   docker compose exec openvpn-proxy gen-mikrotik.sh mkt-client
set -e

CLIENT_NAME="${1:?Usage: gen-mikrotik.sh <client-name>}"
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
    echo "Certificate for '$CLIENT_NAME' already exists. Skipping generation."
else
    echo ">>> Generating certificate for '$CLIENT_NAME'..."
    ./easyrsa build-client-full "$CLIENT_NAME" nopass
fi

mkdir -p "$OUT_DIR"

# Strip certificate to just the PEM block (no bag attributes)
CLIENT_CERT=$(openssl x509 -in "$PKI_DIR/issued/${CLIENT_NAME}.crt")
CA_CERT=$(cat "$PKI_DIR/ca.crt")
CLIENT_KEY=$(cat "$PKI_DIR/private/${CLIENT_NAME}.key")

# ── 1. .ovpn file for Winbox import (RouterOS 7+) ────────────────────────────
# MikroTik restrictions vs standard OpenVPN:
#   - TCP only (no UDP)
#   - No tls-auth / tls-crypt
#   - No comp-lzo / compress
#   - Supported ciphers: AES-128-CBC, AES-256-CBC
#   - RouterOS 7+ supports TUN mode and SHA256
cat > "$OUT_DIR/${CLIENT_NAME}.ovpn" <<EOF
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
$CA_CERT
</ca>
<cert>
$CLIENT_CERT
</cert>
<key>
$CLIENT_KEY
</key>
EOF

# ── 2. RouterOS CLI script (for /import or paste into terminal) ───────────────
# Upload ca.crt, <name>.crt, <name>.key to RouterOS Files first, then run this.
cat > "$OUT_DIR/${CLIENT_NAME}-routeros.rsc" <<EOF
# MikroTik RouterOS 7.x OpenVPN client configuration
# Step 1: Upload these three files to RouterOS via Winbox Files or SCP:
#   ca.crt, ${CLIENT_NAME}.crt, ${CLIENT_NAME}.key
#
# Step 2: Run this script (paste in terminal or use /import file=${CLIENT_NAME}-routeros.rsc)

/certificate import file-name=ca.crt passphrase=""
/certificate import file-name=${CLIENT_NAME}.crt passphrase=""
/certificate import file-name=${CLIENT_NAME}.key passphrase=""

/interface ovpn-client add \
    name=vpn-proxy \
    connect-to=$SERVER_IP \
    port=$OVPN_PORT \
    mode=ip \
    certificate=${CLIENT_NAME} \
    cipher=aes256 \
    auth=sha256 \
    disabled=no

# Verify connection status:
# /interface ovpn-client print
# /interface ovpn-client monitor [find name=vpn-proxy]
EOF

# ── 3. Individual certificate files for manual upload ────────────────────────
cp "$PKI_DIR/ca.crt" "$OUT_DIR/ca.crt"
echo "$CLIENT_CERT" > "$OUT_DIR/${CLIENT_NAME}.crt"
cp "$PKI_DIR/private/${CLIENT_NAME}.key" "$OUT_DIR/${CLIENT_NAME}.key"

echo ""
echo "MikroTik configs written to: $OUT_DIR/"
echo ""
echo "  RouterOS 7+ (Winbox import):"
echo "    Upload ${CLIENT_NAME}.ovpn via Winbox → Files, then import it."
echo ""
echo "  RouterOS CLI (manual):"
echo "    1. Upload: ca.crt, ${CLIENT_NAME}.crt, ${CLIENT_NAME}.key"
echo "    2. Run:    ${CLIENT_NAME}-routeros.rsc"
echo ""
echo "Copy all files out of the container:"
echo "  docker compose cp openvpn-proxy:$OUT_DIR ./"
