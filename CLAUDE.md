# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenVPN server + nginx reverse proxy in Docker. A remote client (OpenVPN or MikroTik) connects to this container over VPN, exposing its private network. Nginx proxies HTTP traffic from the outside world to a host on that private network.

```
[Browser] → [nginx :80] → [tun0] → [OpenVPN TCP] → [MikroTik/client] → [backend 10.20.30.x:port]
```

The `hostnetwork` branch is a stripped-down variant with nginx removed — only the VPN tunnel and host routing, no proxy.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SERVER_IP` | yes | — | Public IP/hostname — written into generated client configs |
| `CLIENT_NETWORK` | yes | — | Network behind the VPN client, e.g. `10.20.30.0/24` |
| `BACKEND_IP` | yes | — | IP nginx proxies to; must be within `CLIENT_NETWORK` |
| `BACKEND_PORT` | no | `80` | Port of the backend service |
| `VPN_SUBNET` | no | `10.8.0.0` | VPN tunnel address pool |
| `VPN_SUBNET_MASK` | no | `255.255.255.0` | Netmask for the VPN pool |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/start.sh` | Entrypoint: validates env, writes `server.conf` + nginx config, starts nginx, execs OpenVPN |
| `scripts/init-ca.sh` | One-time PKI init via easy-rsa — run before first container start |
| `scripts/gen-client.sh` | Generate standard OpenVPN inline `.ovpn` |
| `scripts/gen-mikrotik.sh` | Generate MikroTik `.ovpn` + RouterOS CLI script + individual cert files |
| `scripts/client-connect.sh` | OpenVPN hook: kills stale session via management socket (netcat), adds host route |
| `scripts/client-disconnect.sh` | OpenVPN hook: removes host route |

## Key design decisions

- `duplicate-cn` + management socket kill — allows client reconnect to overwrite a stale session without rejecting the new connection; `max-clients 1` was intentionally avoided because it blocks the new connection before the hook can kill the old one
- MikroTik compatibility — no `tls-auth`, no `tls-crypt`, no compression, `AES-256-CBC` only; `data-ciphers-fallback` prevents OpenVPN 2.5+ from negotiating unsupported ciphers
- `setenv CLIENT_NETWORK` in `server.conf` — OpenVPN hook scripts do not inherit the container environment; this is the only way to pass it in
- `server.conf` is always regenerated from env vars on container start — do not persist it, edit env vars instead
- PKI lives in a Docker named volume (`openvpn-pki`) — never baked into the image

## Route lifecycle

- Client connects → `ip route replace CLIENT_NETWORK via <client VPN IP>` (client-connect.sh)
- Client disconnects → `ip route del CLIENT_NETWORK` (client-disconnect.sh)

## Dependencies in the image

`openvpn`, `easy-rsa`, `nginx`, `iptables`, `iproute2`, `netcat-openbsd` (management socket in client-connect.sh), `openssl`. Base image: `debian:trixie-slim`.
