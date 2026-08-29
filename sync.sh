#!/usr/bin/env bash
# One sync pass: pull every finished timelapse off the printer's SD card into
# /data, verify it byte-for-byte, then delete it from the printer.
#
# Everything is configured through environment variables; see README.md.

set -uo pipefail

: "${PRINTER_HOST:?PRINTER_HOST is required - the printer IP or hostname}"
: "${ACCESS_CODE:?ACCESS_CODE is required (LAN access code from the printer screen)}"

PRINTER_PORT="${PRINTER_PORT:-990}"
FTP_USER="${FTP_USER:-bblp}"
DATA_DIR="${DATA_DIR:-/data}"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
REMOTE_DIR="${REMOTE_DIR:-timelapse}"

is_true() { case "${1,,}" in true|1|yes|y|on) return 0 ;; *) return 1 ;; esac; }

DRY_RUN_ON=false;             is_true "${DRY_RUN:-false}" && DRY_RUN_ON=true
KEEP_REMOTE_ON=false;         is_true "${KEEP_REMOTE:-false}" && KEEP_REMOTE_ON=true
THUMBNAILS_ON=true;           is_true "${DOWNLOAD_THUMBNAILS:-true}" || THUMBNAILS_ON=false
LAYOUT="${LAYOUT:-month}"

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

FTP="ftps://${PRINTER_HOST}:${PRINTER_PORT}"
# The printer serves implicit FTPS with a self-signed certificate, so the cert
# check has to be off; the credentials still travel inside the TLS session.
curl_ftp() {
    curl -sS -k --ftp-ssl --connect-timeout 15 --max-time "${TRANSFER_TIMEOUT:-1800}" \
         -u "${FTP_USER}:${ACCESS_CODE}" "$@"
}

# Emits "name<TAB>size" for each regular file in a remote directory.
list_dir() {
    curl_ftp "$FTP/$1/" | awk '/^-/ {
        name = $9
        for (i = 10; i <= NF; i++) name = name " " $i
        if (name != "") printf "%s\t%s\n", name, $5
    }'
}

# DELE only works against an absolute path on this server.
remote_delete() { curl_ftp "$FTP/" -Q "DELE /$1" -o /dev/null; }

bucket_for() {
    [ "$LAYOUT" = flat ] && { printf '.'; return; }
    if [[ $1 =~ ([0-9]{4})-([0-9]{2})-[0-9]{2} ]]; then
        printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf 'undated'
    fi
}

log "sync start -> ${PRINTER_HOST}:${PRINTER_PORT}"
$DRY_RUN_ON && log "DRY_RUN is on: nothing will be written or deleted"
$KEEP_REMOTE_ON && log "KEEP_REMOTE is on: files will be downloaded but never deleted"

if ! first_pass=$(list_dir "$REMOTE_DIR"); then
    log "ERROR: cannot list /$REMOTE_DIR - printer unreachable, or the access code is wrong"
    exit 1
fi
if [ -z "$first_pass" ]; then
    log "no timelapses on the printer; nothing to do"
    exit 0
fi

# The printer's FTP timestamps are not trustworthy (bulk-touched, and its clock
# drifts), so a still-encoding file is spotted by its size changing between two
# listings rather than by its mtime.
log "$(printf '%s\n' "$first_pass" | wc -l) file(s) on the printer; re-checking in ${SETTLE_SECONDS}s to skip anything still recording"
sleep "$SETTLE_SECONDS"
if ! second_pass=$(list_dir "$REMOTE_DIR"); then
    log "ERROR: second listing failed"
    exit 1
fi

declare -A settled=()
while IFS=$'\t' read -r name size; do
    [ -n "$name" ] && settled["$name"]=$size
done <<<"$second_pass"

downloaded=0 already=0 removed=0 recording=0 failed=0

while IFS=$'\t' read -r name size; do
    [ -n "$name" ] || continue

    now=${settled[$name]:-}
    if [ -z "$now" ]; then
        log "  $name disappeared between listings; skipping"
        continue
    fi
    if [ "$now" != "$size" ]; then
        log "  $name is still recording ($size -> $now bytes); leaving it for the next pass"
        recording=$((recording + 1))
        continue
    fi

    base=${name%.*}
    bucket=$(bucket_for "$name")
    vdir="$DATA_DIR/videos/$bucket"
    tdir="$DATA_DIR/thumbnails/$bucket"
    target="$vdir/$name"

    if $DRY_RUN_ON; then
        log "  would sync $name ($size bytes) -> $target"
        continue
    fi

    mkdir -p "$vdir"
    $THUMBNAILS_ON && mkdir -p "$tdir"

    verified=false
    if [ -f "$target" ] && [ "$(stat -c%s "$target")" = "$size" ]; then
        log "  $name is already stored; skipping the download"
        already=$((already + 1))
        verified=true
    else
        if ! curl_ftp "$FTP/$REMOTE_DIR/$name" -o "$target.part"; then
            log "  FAILED to download $name; leaving it on the printer"
            rm -f "$target.part"
            failed=$((failed + 1))
            continue
        fi
        got=$(stat -c%s "$target.part" 2>/dev/null || echo 0)
        if [ "$got" != "$size" ]; then
            log "  SIZE MISMATCH on $name: got $got, expected $size; leaving it on the printer"
            rm -f "$target.part"
            failed=$((failed + 1))
            continue
        fi
        mv "$target.part" "$target"
        log "  saved $name ($size bytes)"
        downloaded=$((downloaded + 1))
        verified=true
    fi

    # Thumbnails are a nicety: a missing one must never hold up the delete.
    if $THUMBNAILS_ON; then
        for thumb in "$base.jpg" "${base}_mini.jpg"; do
            [ -f "$tdir/$thumb" ] && continue
            if curl_ftp "$FTP/$REMOTE_DIR/thumbnail/$thumb" -o "$tdir/$thumb.part" 2>/dev/null \
               && [ -s "$tdir/$thumb.part" ]; then
                mv "$tdir/$thumb.part" "$tdir/$thumb"
            else
                rm -f "$tdir/$thumb.part"
            fi
        done
    fi

    # Reached only with a size-verified copy on disk.
    $KEEP_REMOTE_ON && continue
    $verified || continue

    if remote_delete "$REMOTE_DIR/$name"; then
        removed=$((removed + 1))
        if $THUMBNAILS_ON; then
            for thumb in "$base.jpg" "${base}_mini.jpg"; do
                remote_delete "$REMOTE_DIR/thumbnail/$thumb" 2>/dev/null
            done
        fi
    else
        log "  could not delete $name from the printer (the local copy is safe)"
        failed=$((failed + 1))
    fi
done <<<"$first_pass"

log "sync done: $downloaded new, $already already stored, $removed freed from the printer, $recording still recording, $failed failed"
[ "$failed" -eq 0 ]
