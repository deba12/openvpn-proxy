#!/bin/bash
# OpenVPN --client-disconnect hook.
# Logs client disconnection events.

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ovpn-disconnect: $*" >&2
}

client_ip="${ifconfig_pool_remote_ip:-$ifconfig_remote}"
log "Client disconnected: $common_name ($client_ip)"

exit 0
