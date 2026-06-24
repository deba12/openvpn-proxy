#!/bin/bash
# Initialize PKI: CA, server certificate, DH params.
# Run once before first container start, or inside the container:
#   docker compose exec openvpn-proxy init-ca.sh
set -e

PKI_DIR=/etc/openvpn/pki

if [ -f "$PKI_DIR/ca.crt" ]; then
    echo "PKI already initialized at $PKI_DIR — delete it to reinitialize."
    exit 0
fi

export EASYRSA_PKI="$PKI_DIR"
export EASYRSA_BATCH=1
export EASYRSA_ALGO=rsa
export EASYRSA_KEY_SIZE=2048
export EASYRSA_CA_EXPIRE=3650
export EASYRSA_CERT_EXPIRE=3650
export EASYRSA_REQ_CN="VPN-CA"

cd /usr/share/easy-rsa

echo ">>> Initializing PKI..."
easyrsa init-pki

echo ">>> Building CA (no password)..."
easyrsa build-ca nopass

echo ">>> Generating server certificate..."
easyrsa build-server-full server nopass

echo ">>> Generating DH parameters (this takes a while)..."
easyrsa gen-dh

mkdir -p "$PKI_DIR/clients"

echo ""
echo "PKI initialized. Next step: generate a client config."
echo "  For standard OpenVPN:  gen-client.sh <name>"
echo "  For MikroTik:          gen-mikrotik.sh <name>"
