FROM coturn/coturn:4.6.2-alpine

COPY turnserver.conf.template /etc/coturn/turnserver.conf.template
COPY entrypoint.sh /entrypoint.sh

USER root
RUN chmod +x /entrypoint.sh
USER nobody

EXPOSE 3478/udp 3478/tcp 5349/udp 5349/tcp 49160-49200/udp

ENTRYPOINT ["/entrypoint.sh"]
