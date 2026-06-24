FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    openvpn \
    easy-rsa \
    nginx \
    iptables \
    iproute2 \
    netcat-openbsd \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Remove default nginx config
RUN rm -f /etc/nginx/sites-enabled/default

COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

VOLUME ["/etc/openvpn/pki"]

EXPOSE 1194/tcp 80/tcp

ENTRYPOINT ["/usr/local/bin/start.sh"]
