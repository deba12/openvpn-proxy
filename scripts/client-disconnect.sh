#!/bin/bash
# OpenVPN --client-disconnect hook.
# Logs client disconnection events.

log() {
    local msg="$*"
    logger -t ovpn-disconnect "$msg"
    echo "$msg"
    if [ -w /proc/1/fd/1 ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ovpn-disconnect: $msg" > /proc/1/fd/1
    fi
}

client_ip="${ifconfig_pool_remote_ip:-$ifconfig_remote}"
log "Client disconnected: $common_name ($client_ip)"

exit 0
