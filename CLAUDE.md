# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenVPN server in Docker that adds a route to a remote private network onto the host routing table when a VPN client connects. No proxy, no NAT, no iptables. The host's own scripts connect directly to the remote network via kernel routing through the tunnel.

```
[host scripts] → kernel routing → tun0 → OpenVPN TCP → MikroTik/client → 10.20.30.x
```

## Key design decisions

- `network_mode: host` — Docker adds zero iptables rules; no conntrack overhead on the host
- No iptables calls anywhere — do not add any, the user explicitly does not want them
- No NAT on the server side — pure routing only
- No nginx or any userspace proxy — removed intentionally for performance
- `duplicate-cn` + management socket kill — allows client reconnect to overwrite a stale session
- MikroTik compatibility — no `tls-auth`, no `tls-crypt`, no compression, `AES-256-CBC` included in `data-ciphers`; modern clients negotiate GCM

## Environment variables

| Variable | Required | Default |
|---|---|---|
| `SERVER_IP` | yes | — |
| `CLIENT_NETWORK` | yes | — |
| `VPN_SUBNET` | no | `10.8.0.0` |
| `VPN_SUBNET_MASK` | no | `255.255.255.0` |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/start.sh` | Entrypoint: validates env, writes `server.conf`, execs OpenVPN |
| `scripts/init-ca.sh` | One-time PKI init via easy-rsa |
| `scripts/gen-client.sh` | Generate standard OpenVPN `.ovpn` |
| `scripts/gen-mikrotik.sh` | Generate MikroTik `.ovpn` + RouterOS CLI script + individual cert files |
| `scripts/client-connect.sh` | OpenVPN hook: kills all other active sessions globally, writes dynamic `iroute` |
| `scripts/client-disconnect.sh` | OpenVPN hook: logs client disconnection |

## Route lifecycle

- On container start: OpenVPN statically creates the host route (`route CLIENT_NETWORK`) on interface startup.
- On client connect: Terminate all other connections via management socket, then write client's internal route (`iroute CLIENT_NETWORK`) to OpenVPN's temporary config file.
- On client disconnect: Log the disconnection. The host route remains in the routing table pointing to `tun0`.
- `server.conf` is regenerated on every container start from env vars

## Dependencies in the image

`openvpn`, `easy-rsa`, `iproute2`, `netcat-openbsd` (used in `client-connect.sh` to talk to the OpenVPN management socket), `openssl`. Base image is `debian:trixie-slim`.
