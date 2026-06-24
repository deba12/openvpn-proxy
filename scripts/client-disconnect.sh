#!/bin/bash
# OpenVPN --client-disconnect hook.
# Removes the static route when the client disconnects.

log() { logger -t ovpn-disconnect "$*"; echo "$*"; }

if [ -n "$CLIENT_NETWORK" ]; then
    ip route del "$CLIENT_NETWORK" 2>/dev/null && \
        log "Route $CLIENT_NETWORK removed" || \
        log "Route $CLIENT_NETWORK not found (already gone)"
fi

exit 0
