#!/bin/bash
# OpenVPN --client-connect hook.
# Called by OpenVPN when a client completes authentication.
# Kills any other active connection globally, then adds the static route.
#
# OpenVPN sets these env vars:
#   $common_name             — client certificate CN
#   $ifconfig_pool_remote_ip — VPN IP assigned to this client
#   $untrusted_ip            — Real IP of the connecting client
#   $untrusted_port          — Real port of the connecting client

MGMT_HOST=127.0.0.1
MGMT_PORT=5555

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ovpn-connect: $*" >&2
}

new_real_address=""
if [ -n "$untrusted_ip" ] && [ -n "$untrusted_port" ]; then
    new_real_address="$untrusted_ip:$untrusted_port"
fi

if [ -n "$new_real_address" ]; then
    log "New connection authenticated from $new_real_address ($common_name). Terminating all other connections..."
    
    # Query OpenVPN status (version 2) to list all active clients
    status_output=$( (echo "status 2"; sleep 0.4; echo "quit") | nc -w2 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null )
    
    # Process CLIENT_LIST lines and kill all connections except the new one
    echo "$status_output" | grep "^CLIENT_LIST," | while IFS=',' read -r type cn real_addr rest; do
        if [ -n "$real_addr" ]; then
            if [ "$real_addr" = "$new_real_address" ] || [ "$real_addr" = "[$untrusted_ip]:$untrusted_port" ]; then
                log "Keeping current connection: $cn ($real_addr)"
            else
                log "Terminating old connection: $cn at $real_addr"
                (echo "kill $real_addr"; sleep 0.1; echo "quit") | nc -w2 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null
            fi
        fi
    done
    
    # Pause to allow OpenVPN to process the disconnects before route updates
    sleep 0.5
else
    # Fallback to CN-based kill if untrusted_ip/port are somehow missing
    log "Warning: untrusted_ip or untrusted_port not set. Falling back to CN-based kill for '$common_name'"
    if (echo "kill $common_name"; sleep 0.3; echo "quit") | nc -w2 "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null; then
        sleep 0.5
    fi
fi

# Add dynamic iroute to the client session configuration.
# CLIENT_NETWORK is injected via 'setenv' in server.conf.
cc_config_file="$1"
if [ -n "$CLIENT_NETWORK" ] && [ -n "$cc_config_file" ] && [ -f "$cc_config_file" ]; then
    CLIENT_IP="${CLIENT_NETWORK%/*}"
    CLIENT_PREFIX="${CLIENT_NETWORK#*/}"
    
    prefix_to_mask() {
        local prefix=$1
        local mask=""
        local octet
        for i in 1 2 3 4; do
            if [ $prefix -ge 8 ]; then
                octet=255
                prefix=$((prefix - 8))
            elif [ $prefix -gt 0 ]; then
                octet=$(( 256 - (1 << (8 - prefix)) ))
                prefix=0
            else
                octet=0
            fi
            mask="${mask}${octet}"
            [ $i -lt 4 ] && mask="${mask}."
        done
        echo "$mask"
    }

    CLIENT_MASK=$(prefix_to_mask "$CLIENT_PREFIX")
    
    echo "iroute $CLIENT_IP $CLIENT_MASK" >> "$cc_config_file"
    log "Wrote dynamic iroute $CLIENT_IP $CLIENT_MASK to $cc_config_file"
else
    log "WARNING: CLIENT_NETWORK not set or connect config file '$cc_config_file' not found — skipping iroute"
fi

exit 0
