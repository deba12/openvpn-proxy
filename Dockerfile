FROM debian:trixie-slim

RUN apt-get update && apt-get install --no-install-recommends -y \
    openvpn \
    easy-rsa \
    iproute2 \
    netcat-openbsd \
    openssl \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

VOLUME ["/etc/openvpn/pki"]

EXPOSE 1194/tcp

ENTRYPOINT ["/usr/local/bin/start.sh"]
