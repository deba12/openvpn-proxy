#!/bin/bash
# OpenVPN --client-connect hook.
# Called by OpenVPN when a client completes authentication.
# Kills any existing session with the same CN, then adds the static route.
#
# OpenVPN sets these env vars:
#   $common_name           — client certificate CN
#   $ifconfig_pool_remote_ip — VPN IP assigned to this client

MGMT_HOST=127.0.0.1
MGMT_PORT=5555

log() { logger -t ovpn-connect "$*"; echo "$*"; }

# Kill existing session with same CN (allows reconnect/takeover).
# We ignore errors — if no old session exists the kill is a no-op.
if (echo "kill $common_name"; sleep 0.3; echo "quit") | nc -w2 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null; then
    log "Sent kill for existing '$common_name' session (if any)"
    # Brief pause so OpenVPN processes the disconnect before we add the route
    sleep 0.5
fi

# Add/replace static route to the network behind the client.
# CLIENT_NETWORK is injected via 'setenv' in server.conf.
if [ -n "$CLIENT_NETWORK" ] && [ -n "$ifconfig_pool_remote_ip" ]; then
    ip route replace "$CLIENT_NETWORK" via "$ifconfig_pool_remote_ip"
    log "Route $CLIENT_NETWORK via $ifconfig_pool_remote_ip set"
else
    log "WARNING: CLIENT_NETWORK or ifconfig_pool_remote_ip not set — skipping route"
fi

exit 0
