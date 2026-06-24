# openvpn-vpn-route

OpenVPN server in Docker that extends a remote private network onto the host's routing table.

```
[host scripts] ──▶ kernel routing ──▶ tun0 ──▶ OpenVPN (TCP) ──▶ MikroTik / client ──▶ 10.20.30.x
```

When the VPN client connects, a route to its private network is added to the **host** routing table. When it disconnects the route is removed. No proxy, no NAT — just a routed tunnel.

Runs with `network_mode: host` so Docker adds zero iptables rules. Tunnel traffic is additionally marked `NOTRACK` to skip kernel connection tracking entirely.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SERVER_IP` | yes | — | Public IP or hostname of this server. Written into generated client configs. |
| `CLIENT_NETWORK` | yes | — | Network behind the VPN client, e.g. `10.20.30.0/24`. Added as a host route on connect, removed on disconnect. |
| `VPN_SUBNET` | no | `10.8.0.0` | VPN tunnel address pool. Change only if it conflicts with existing host routes. |
| `VPN_SUBNET_MASK` | no | `255.255.255.0` | Netmask for the VPN pool. |

OpenVPN binds directly to the host on TCP **1194** (host networking — no port mapping).

---

## Quick Start

### 1. Configure environment

```bash
cat > .env <<EOF
SERVER_IP=203.0.113.10
CLIENT_NETWORK=10.20.30.0/24
EOF
```

### 2. Initialize the PKI (once)

```bash
docker compose run --rm openvpn init-ca.sh
```

Generates CA, server certificate, and DH parameters into the `openvpn-pki` volume.

### 3. Generate a client config

**Standard OpenVPN:**
```bash
docker compose run --rm openvpn gen-client.sh myclient
docker compose cp openvpn:/etc/openvpn/pki/clients/myclient/ ./
```

**MikroTik:**
```bash
docker compose run --rm openvpn gen-mikrotik.sh mkt-client
docker compose cp openvpn:/etc/openvpn/pki/clients/mkt-client/ ./
```

### 4. Start

```bash
docker compose up -d
```

---

## Client Setup

### Standard OpenVPN Client

Import `myclient.ovpn` — self-contained with inline certificates, no extra steps.

### MikroTik (RouterOS 7+)

The generator produces:

| File | Use |
|---|---|
| `mkt-client.ovpn` | Winbox → Files → import (RouterOS 7+) |
| `mkt-client-routeros.rsc` | Paste into terminal or `/import` |
| `ca.crt` / `mkt-client.crt` / `mkt-client.key` | Manual upload for older RouterOS |

**RouterOS CLI path:**
1. Upload `ca.crt`, `mkt-client.crt`, `mkt-client.key` via Winbox Files or SCP
2. Run: `/import file=mkt-client-routeros.rsc`

**Required on the MikroTik side:**

The host server's scripts will source-IP from the VPN pool (`10.8.0.1`). The backend hosts need a return route. Simplest way — add a static route on MikroTik pointing the VPN pool back through the tunnel interface:

```
/ip route add dst-address=10.8.0.0/24 gateway=<ovpn-interface>
```

If all backend hosts use MikroTik as their default gateway this is usually already satisfied.

---

## How Routes Work

| Event | Host routing table |
|---|---|
| Container starts | `10.8.0.0/24 via tun0` added (VPN pool) |
| Client connects | `10.20.30.0/24 via <client VPN IP>` added |
| Client reconnects | Old session killed, route replaced atomically |
| Client disconnects | `10.20.30.0/24` removed |

Your scripts on the host connect to `10.20.30.x` directly — the kernel routes the packets through `tun0` with no userspace proxy in the path.

---

## Performance Notes

- `network_mode: host` — Docker adds no iptables rules, no bridge, no NAT
- No NAT on the server side — pure routing, all in kernel space
- Only userspace overhead is OpenVPN itself doing AES-256-CBC encrypt/decrypt

---

## Reconnect Behaviour

`duplicate-cn` allows the same certificate to reconnect. The `client-connect` hook immediately sends `kill <CN>` to the management socket, terminating the stale session before the new one is fully established. The route is then replaced atomically with the new client VPN IP.

---

## Switching to Older MikroTik (RouterOS 6.x)

RouterOS 6.x does not support SHA256. Delete `/etc/openvpn/server.conf` inside the container (it is regenerated on next start) and set:

```bash
# Add to .env
OVPN_EXTRA_AUTH=SHA1
```

Then regenerate the MikroTik config and re-import. RouterOS 6.x may also require `dev tap` — consult the router admin for the correct mode.

---

## File Layout

```
.
├── Dockerfile
├── docker-compose.yml
├── .env                         # SERVER_IP, CLIENT_NETWORK (not committed)
└── scripts/
    ├── start.sh                 # Entrypoint: configures kernel, writes server.conf, execs OpenVPN
    ├── init-ca.sh               # Initialize PKI — run once
    ├── gen-client.sh            # Generate standard OpenVPN .ovpn
    ├── gen-mikrotik.sh          # Generate MikroTik .ovpn + RouterOS script + cert files
    ├── client-connect.sh        # Hook: kill stale session, add host route
    └── client-disconnect.sh     # Hook: remove host route
```

PKI lives in the `openvpn-pki` Docker named volume at `/etc/openvpn/pki`.
