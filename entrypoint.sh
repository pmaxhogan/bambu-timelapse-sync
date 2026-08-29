#!/usr/bin/env bash
# Container entrypoint: optionally drop privileges, then run sync.sh on a loop.
set -uo pipefail

DATA_DIR="${DATA_DIR:-/data}"
SYNC_INTERVAL="${SYNC_INTERVAL:-3600}"
RUN_ON_START="${RUN_ON_START:-true}"
STAMP=/tmp/last-successful-sync

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

mkdir -p "$DATA_DIR"

# Drop to an unprivileged uid/gid when asked, so files on a NAS share land with
# the ownership the host expects instead of root.
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        log "PUID/PGID given but the container is not running as root; ignoring them"
    else
        uid="${PUID:-1000}"
        gid="${PGID:-1000}"
        log "running syncs as ${uid}:${gid}"
        chown -R "${uid}:${gid}" "$DATA_DIR" 2>/dev/null || \
            log "warning: could not chown $DATA_DIR"
        exec su-exec "${uid}:${gid}" \
            env PUID= PGID= "$0" "$@"
    fi
fi

# Let docker stop interrupt a sleep immediately rather than waiting it out.
terminate=false
trap 'terminate=true; [ -n "${napper:-}" ] && kill "$napper" 2>/dev/null' TERM INT

if [ "$SYNC_INTERVAL" -le 0 ] 2>/dev/null; then
    log "SYNC_INTERVAL is 0: running a single pass and exiting"
    exec /usr/local/bin/sync.sh
fi

log "starting up; a sync will run every ${SYNC_INTERVAL}s"

first=true
while ! $terminate; do
    if $first && ! { [ "$RUN_ON_START" = true ] || [ "$RUN_ON_START" = 1 ]; }; then
        log "RUN_ON_START is off; waiting for the first interval"
    else
        if /usr/local/bin/sync.sh; then
            date -Is >"$STAMP"
        else
            log "sync pass reported errors; will try again next interval"
        fi
    fi
    first=false
    $terminate && break
    sleep "$SYNC_INTERVAL" &
    napper=$!
    wait "$napper" 2>/dev/null
    napper=
done

log "shutting down"
