FROM alpine:3.22

# bash    - the sync scripts use arrays and [[ ]]
# curl    - speaks the implicit FTPS the printer serves on 990
# coreutils - GNU date/stat; the busybox versions lack the flags used here
# su-exec - drops to PUID/PGID when the host asks for specific ownership
RUN apk add --no-cache bash curl coreutils su-exec tzdata

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
