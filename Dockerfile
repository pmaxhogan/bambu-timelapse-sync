# Debian, not Alpine, and this is load-bearing: the printer requires TLS session
# reuse on the FTPS data connection, and answers
#   522 SSL connection failed: session reuse required
# to clients that do not do it. curl 7.88 reuses the session; the curl 8.x that
# Alpine ships does not, so an Alpine image can log in and then fail every
# single transfer. Do not "simplify" this to alpine without testing a real
# download against a real printer.
FROM debian:bookworm-slim

# curl speaks the implicit FTPS the printer serves on 990; bash, coreutils and
# setpriv (util-linux) are already in the base image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY sync.sh entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/sync.sh /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENV DATA_DIR=/data \
    SYNC_INTERVAL=3600 \
    PRINTER_PORT=990 \
    FTP_USER=bblp \
    SETTLE_SECONDS=15 \
    LAYOUT=month \
    DOWNLOAD_THUMBNAILS=true \
    DRY_RUN=false \
    KEEP_REMOTE=false

VOLUME ["/data"]

HEALTHCHECK --interval=5m --timeout=10s --start-period=1m \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="bambu-timelapse-sync" \
      org.opencontainers.image.description="Copies Bambu Lab timelapses off the printer SD card onto your own storage, then frees the space." \
      org.opencontainers.image.licenses="MIT"
