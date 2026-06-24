# openvpn-proxy

A Docker container that tunnels HTTP traffic through an OpenVPN server to a backend service on the client's private network.

```
[Browser] → [nginx :80] → [OpenVPN tunnel] → [MikroTik / OpenVPN client] → [backend 10.20.30.50:80]
```

The container runs both an OpenVPN server and an nginx reverse proxy. The remote side (client) connects to this container over OpenVPN, exposing its private network. Nginx then proxies HTTP traffic to a host on that private network.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SERVER_IP` | yes | — | Public IP or hostname of this server. Used in generated client configs. |
| `CLIENT_NETWORK` | yes | — | Network behind the VPN client, e.g. `10.20.30.0/24`. A static route to this network is added when the client connects. |
| `BACKEND_IP` | yes | — | IP of the backend service nginx proxies to. Must be within `CLIENT_NETWORK`. |
| `BACKEND_PORT` | no | `80` | Port of the backend service. |
| `VPN_SUBNET` | no | `10.8.0.0` | VPN tunnel address pool. |
| `VPN_SUBNET_MASK` | no | `255.255.255.0` | Netmask for the VPN tunnel pool. |

OpenVPN listens on TCP **1194**. Nginx listens on TCP **80**. Both are fixed inside the container; remap them with Docker port bindings if needed.

---

## Quick Start

### 1. Configure environment

Create a `.env` file:

```env
SERVER_IP=203.0.113.10
CLIENT_NETWORK=10.20.30.0/24
BACKEND_IP=10.20.30.50
BACKEND_PORT=80
```

### 2. Initialize the PKI (once)

```bash
docker compose run --rm openvpn-proxy init-ca.sh
```

This generates the CA, server certificate, and DH parameters. Everything is stored in the `openvpn-pki` Docker volume and survives container restarts.

### 3. Generate a client config

**Standard OpenVPN client:**
```bash
docker compose run --rm openvpn-proxy gen-client.sh myclient
```

**MikroTik client:**
```bash
docker compose run --rm openvpn-proxy gen-mikrotik.sh mkt-client
```

### 4. Copy the config files out of the container

```bash
# Standard OpenVPN — single .ovpn file
docker compose cp openvpn-proxy:/etc/openvpn/pki/clients/myclient/ ./

# MikroTik — several files, see below
docker compose cp openvpn-proxy:/etc/openvpn/pki/clients/mkt-client/ ./
```

### 5. Start the container

```bash
docker compose up -d
```

---

## Client Setup

### Standard OpenVPN Client

Import `myclient.ovpn` into your OpenVPN client. No further configuration needed — the file is self-contained with inline certificates.

### MikroTik (RouterOS 7+)

The generator produces three files for MikroTik:

| File | Purpose |
|---|---|
| `mkt-client.ovpn` | Import via Winbox → Files (RouterOS 7+) |
| `mkt-client-routeros.rsc` | RouterOS CLI script |
| `ca.crt`, `mkt-client.crt`, `mkt-client.key` | Individual cert files for manual upload |

**Option A — Winbox import (RouterOS 7+):**

1. Open Winbox → Files → Upload `mkt-client.ovpn`
2. Go to Interfaces → add OVPN Client → import the file

**Option B — CLI script:**

1. Upload `ca.crt`, `mkt-client.crt`, `mkt-client.key` to RouterOS via Winbox Files or SCP
2. In the RouterOS terminal:
   ```
   /import file=mkt-client-routeros.rsc
   ```

**MikroTik NAT (on the remote router):**

The container only adds a route to `CLIENT_NETWORK` — it does not push any routes to the client and does not configure NAT. The MikroTik admin must add a NAT masquerade rule so traffic from the VPN tunnel can reach the private network:

```
/ip firewall nat add chain=srcnat src-address=10.8.0.0/24 action=masquerade
```

Adjust `src-address` to match `VPN_SUBNET`.

---

## Reconnect Behaviour

Only one client can be active at a time. When the same certificate reconnects (e.g. after a link failure), the container automatically terminates the old session via the OpenVPN management interface before the new session is fully established. The static route is updated to the new VPN IP atomically.

This is intentional: the client always wins, and a stale session never blocks a reconnect.

---

## File Layout

```
.
├── Dockerfile
├── docker-compose.yml
├── scripts/
│   ├── start.sh              # Container entrypoint
│   ├── init-ca.sh            # Initialize PKI (run once)
│   ├── gen-client.sh         # Generate standard OpenVPN client config
│   ├── gen-mikrotik.sh       # Generate MikroTik client configs
│   ├── client-connect.sh     # OpenVPN hook: kill old session, add route
│   └── client-disconnect.sh  # OpenVPN hook: remove route
```

PKI data is stored in the `openvpn-pki` Docker named volume, mounted at `/etc/openvpn/pki` inside the container.

---

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| `1194` | TCP | OpenVPN server |
| `80` | TCP | Nginx reverse proxy (HTTP) |

To expose on different host ports without changing the container, edit `docker-compose.yml`:

```yaml
ports:
  - "11194:1194/tcp"   # host port 11194 → container 1194
  - "8080:80/tcp"      # host port 8080  → container 80
```

---

## Switching to Older MikroTik (RouterOS 6.x)

RouterOS 6.x does not support TUN mode or SHA256. If the connection fails, edit `/etc/openvpn/server.conf` inside the container (or delete it and let `start.sh` regenerate it) and change:

```
auth SHA256  →  auth SHA1
```

Then regenerate the MikroTik config with `gen-mikrotik.sh` and re-import on the router. RouterOS 6.x also requires TAP mode (`dev tap`) which changes routing behaviour — contact the router admin for the correct interface mode setting.
