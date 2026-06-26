# openvpn-vpn-route

OpenVPN server in Docker that extends a remote private network onto the host's routing table.

```
[host scripts] ──▶ kernel routing ──▶ tun0 ──▶ OpenVPN (TCP) ──▶ MikroTik / client ──▶ 10.20.30.x
```

The route to the client's private network is added statically to the **host** routing table when the server container starts. When the client connects, OpenVPN dynamically registers the internal route (`iroute`) to direct packets to the client. No proxy, no NAT — just a routed tunnel.

Runs with `network_mode: host` so Docker adds zero iptables rules. Tunnel traffic is additionally marked `NOTRACK` to skip kernel connection tracking entirely.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SERVER_IP` | yes | — | Public IP or hostname of this server. Written into generated client configs. |
| `CLIENT_NETWORK` | yes | — | Network behind the VPN client, e.g. `10.20.30.0/24`. Statically routed on container start. |
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

| Event | Host routing table / OpenVPN behavior |
|---|---|
| Container starts | `10.8.0.0/24 via tun0` (VPN pool) & `10.20.30.0/24 via tun0` added (static routing) |
| Client connects | Old sessions killed globally; `iroute 10.20.30.0 255.255.255.0` registered internally |
| Client reconnects | Old session killed, new session dynamically registers the `iroute` mapping |
| Client disconnects | No routing table changes (static route remains pointing to `tun0`) |

Your scripts on the host connect to `10.20.30.x` directly — the kernel routes the packets through `tun0` with no userspace proxy in the path. Since the host route is static, traffic simply cannot pass through `tun0` when the client is disconnected.

---

## Disabling Docker NAT and iptables

### This container

`network_mode: host` already means Docker adds **zero** iptables rules for this container — no DNAT, no MASQUERADE, no bridge. Nothing to disable.

### System-wide (all containers on the host)

If you want Docker to never touch iptables at all — for any container on the host — add to `/etc/docker/daemon.json`:

```json
{
  "iptables": false
}
```

Then restart Docker:

```bash
systemctl restart docker
```

**What this affects:** Docker will no longer create forwarding or NAT rules for any container. Containers using bridge networking (the default) will lose internet access unless you set up routing manually. Containers using `network_mode: host` (like this one) are unaffected — they never relied on Docker's iptables rules.

**Safe combination:** Run this container with `network_mode: host` on a host where Docker has `"iptables": false`. This container works exactly the same; other containers that need bridge networking will need manual rules or a different approach (e.g. `network_mode: host` for them too, or an external firewall manager like `nftables`).

### Verify Docker has added no rules

After starting the container, confirm Docker has not inserted anything:

```bash
iptables -t nat -L DOCKER 2>/dev/null && echo "rules exist" || echo "no Docker nat rules"
iptables -L DOCKER 2>/dev/null && echo "rules exist" || echo "no Docker filter rules"
```

Both should return "no Docker nat rules" / "no Docker filter rules" when `network_mode: host` is used or `"iptables": false` is set.

---

## Performance Notes

- `network_mode: host` — Docker adds no iptables rules, no bridge, no NAT
- No NAT on the server side — pure routing, all in kernel space
- Only userspace overhead is OpenVPN itself doing AES-256-CBC encrypt/decrypt

---

## Reconnect Behaviour

`duplicate-cn` allows the same certificate (or multiple links from the same office) to reconnect. The `client-connect` hook queries the management socket status interface, identifies all other active sessions globally, and terminates them, ensuring only one client connection remains active on the server. The new connection then dynamically registers the `iroute` mapping.

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
    ├── start.sh                 # Entrypoint: configures kernel, parses CIDR, writes server.conf with static route, execs OpenVPN
    ├── init-ca.sh               # Initialize PKI — run once
    ├── gen-client.sh            # Generate standard OpenVPN .ovpn
    ├── gen-mikrotik.sh          # Generate MikroTik .ovpn + RouterOS script + cert files
    ├── client-connect.sh        # Hook: terminates other sessions globally, configures dynamic iroute
    └── client-disconnect.sh     # Hook: logs client disconnection
```

PKI lives in the `openvpn-pki` Docker named volume at `/etc/openvpn/pki`.
