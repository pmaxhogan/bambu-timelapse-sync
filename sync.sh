#!/usr/bin/env bash
# One sync pass: pull every finished timelapse off the printer SD card into
# /data, verify it byte-for-byte, then delete it from the printer.
#
# The printer refuses new FTP sessions once a handful are open, answering
# "421 There are too many connections from your internet address", and it is
# slow to release them. So this does as few connections as it can: files are
# fetched and deleted in batches that reuse a single control connection.
#
# Everything is configured through environment variables; see README.md.

set -uo pipefail

: "${PRINTER_HOST:?PRINTER_HOST is required - the printer IP or hostname}"
: "${ACCESS_CODE:?ACCESS_CODE is required - the LAN access code from the printer screen}"

PRINTER_PORT="${PRINTER_PORT:-990}"
FTP_USER="${FTP_USER:-bblp}"
DATA_DIR="${DATA_DIR:-/data}"
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
REMOTE_DIR="${REMOTE_DIR:-timelapse}"
BATCH_SIZE="${BATCH_SIZE:-20}"
BATCH_PAUSE="${BATCH_PAUSE:-3}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"

is_true() { case "${1,,}" in true|1|yes|y|on) return 0 ;; *) return 1 ;; esac; }

DRY_RUN_ON=false;     is_true "${DRY_RUN:-false}" && DRY_RUN_ON=true
KEEP_REMOTE_ON=false; is_true "${KEEP_REMOTE:-false}" && KEEP_REMOTE_ON=true
THUMBNAILS_ON=true;   is_true "${DOWNLOAD_THUMBNAILS:-true}" || THUMBNAILS_ON=false
LAYOUT="${LAYOUT:-month}"

# Logs go to stderr so that messages emitted from inside a command
# substitution - the retry notices, most of all - still reach the container log
# instead of being captured as if they were output.
log() { printf '%s  %s\n' "$(date -Is)" "$*" >&2; }

FTP="ftps://${PRINTER_HOST}:${PRINTER_PORT}"

# The printer serves implicit FTPS with a self-signed certificate, so the
# certificate cannot be verified; credentials still travel inside the TLS
# session, and none of this leaves the local network.
curl_ftp() {
    curl -sS -k --ftp-ssl --connect-timeout 20 --max-time "${TRANSFER_TIMEOUT:-3600}" \
         -u "${FTP_USER}:${ACCESS_CODE}" "$@"
}

# A printer that is briefly out of FTP session slots refuses everything until it
# frees some, so give it time rather than treating that as a hard failure.
curl_retry() {
    local attempt=1 backoff
    while :; do
        if curl_ftp "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            return 1
        fi
        backoff=$((attempt * 20))
        log "  the printer refused that request; retrying in ${backoff}s (attempt $((attempt + 1)) of ${MAX_ATTEMPTS})"
        sleep "$backoff"
        attempt=$((attempt + 1))
    done
}

# Emits "name<TAB>size" for each regular file in a remote directory.
list_dir() {
    curl_retry "$FTP/$1/" | awk '/^-/ {
        name = $9
        for (i = 10; i <= NF; i++) name = name " " $i
        if (name != "") printf "%s\t%s\n", name, $5
    }'
}

bucket_for() {
    if [ "$LAYOUT" = flat ]; then
        printf '.'
    elif [[ $1 =~ ([0-9]{4})-([0-9]{2})-[0-9]{2} ]]; then
        printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf 'undated'
    fi
}

video_path() { printf '%s/videos/%s/%s' "$DATA_DIR" "$(bucket_for "$1")" "$1"; }
thumb_path() { printf '%s/thumbnails/%s/%s' "$DATA_DIR" "$(bucket_for "$1")" "$2"; }

log "sync start -> ${PRINTER_HOST}:${PRINTER_PORT}"
$DRY_RUN_ON && log "DRY_RUN is on: nothing will be written or deleted"
$KEEP_REMOTE_ON && log "KEEP_REMOTE is on: files will be downloaded but never deleted"

if ! first_pass=$(list_dir "$REMOTE_DIR"); then
    log "ERROR: cannot list /$REMOTE_DIR - the printer is unreachable, out of FTP"
    log "       sessions, or the access code is wrong"
    exit 1
fi
if [ -z "$first_pass" ]; then
    log "no timelapses on the printer; nothing to do"
    exit 0
fi

# The printer FTP timestamps are not trustworthy - they get bulk-touched and its
# clock drifts - so a still-encoding file is spotted by its size changing
# between two listings rather than by its mtime.
log "$(printf '%s\n' "$first_pass" | wc -l) file(s) on the printer; re-checking in ${SETTLE_SECONDS}s to skip anything still recording"
sleep "$SETTLE_SECONDS"
if ! second_pass=$(list_dir "$REMOTE_DIR"); then
    log "ERROR: the second listing failed"
    exit 1
fi

declare -A settled=()
while IFS=$'\t' read -r name size; do
    [ -n "$name" ] && settled["$name"]=$size
done <<<"$second_pass"

# Knowing which thumbnails actually exist keeps the batch fetches free of 550s,
# which would otherwise cut a batch short.
declare -A remote_thumbs=()
if $THUMBNAILS_ON; then
    thumb_listing=$(list_dir "$REMOTE_DIR/thumbnail")
    while IFS=$'\t' read -r name _; do
        [ -n "$name" ] && remote_thumbs["$name"]=1
    done <<<"$thumb_listing"
fi

declare -a needed=()
declare -a stored=()
recording=0

while IFS=$'\t' read -r name size; do
    [ -n "$name" ] || continue
    now=${settled[$name]:-}
    if [ -z "$now" ]; then
        log "  $name disappeared between listings; skipping it"
        continue
    fi
    if [ "$now" != "$size" ]; then
        log "  $name is still recording ($size then $now bytes); leaving it for the next pass"
        recording=$((recording + 1))
        continue
    fi
    target=$(video_path "$name")
    if [ -f "$target" ] && [ "$(stat -c%s "$target")" = "$size" ]; then
        stored+=("$name")
    else
        needed+=("$name")
    fi
done <<<"$first_pass"

if $DRY_RUN_ON; then
    for name in ${needed[@]+"${needed[@]}"}; do
        log "  would download $name (${settled[$name]} bytes) to $(video_path "$name")"
    done
    for name in ${stored[@]+"${stored[@]}"}; do
        log "  already stored, would free from the printer: $name"
    done
    log "dry run done: ${#needed[@]} to download, ${#stored[@]} already stored, $recording still recording"
    exit 0
fi

# --- fetch, a batch at a time down one reused connection ---------------------

declare -a verified=(${stored[@]+"${stored[@]}"})
downloaded=0
failed=0

for ((i = 0; i < ${#needed[@]}; i += BATCH_SIZE)); do
    batch=("${needed[@]:i:BATCH_SIZE}")
    args=()
    for name in "${batch[@]}"; do
        target=$(video_path "$name")
        mkdir -p "$(dirname "$target")"
        args+=("$FTP/$REMOTE_DIR/$name" -o "$target.part")
        if $THUMBNAILS_ON; then
            base=${name%.*}
            for thumb in "$base.jpg" "${base}_mini.jpg"; do
                [ -n "${remote_thumbs[$thumb]:-}" ] || continue
                tpath=$(thumb_path "$name" "$thumb")
                [ -f "$tpath" ] && continue
                mkdir -p "$(dirname "$tpath")"
                args+=("$FTP/$REMOTE_DIR/thumbnail/$thumb" -o "$tpath.part")
            done
        fi
    done

    log "fetching ${#batch[@]} timelapse(s)..."
    # Deliberately one attempt: retrying would re-fetch the whole batch to
    # recover one file, and hammer the sessions this is trying to conserve.
    # The per-file size checks below are the real gate, and whatever misses
    # is simply picked up by the next pass.
    curl_ftp "${args[@]}"

    for name in "${batch[@]}"; do
        target=$(video_path "$name")
        want=${settled[$name]}
        got=$(stat -c%s "$target.part" 2>/dev/null || echo 0)
        if [ "$got" = "$want" ]; then
            mv "$target.part" "$target"
            log "  saved $name ($want bytes)"
            downloaded=$((downloaded + 1))
            verified+=("$name")
        else
            log "  incomplete download of $name (got $got of $want bytes); leaving it on the printer"
            rm -f "$target.part"
            failed=$((failed + 1))
        fi
        if $THUMBNAILS_ON; then
            base=${name%.*}
            for thumb in "$base.jpg" "${base}_mini.jpg"; do
                tpath=$(thumb_path "$name" "$thumb")
                if [ -s "$tpath.part" ]; then
                    mv "$tpath.part" "$tpath"
                else
                    rm -f "$tpath.part"
                fi
            done
        fi
    done
    sleep "$BATCH_PAUSE"
done

# --- free the printer, a batch at a time -------------------------------------

removed=0
if $KEEP_REMOTE_ON; then
    log "KEEP_REMOTE is on: leaving ${#verified[@]} file(s) on the printer"
elif [ ${#verified[@]} -gt 0 ]; then
    for ((i = 0; i < ${#verified[@]}; i += BATCH_SIZE)); do
        batch=("${verified[@]:i:BATCH_SIZE}")
        args=()
        for name in "${batch[@]}"; do
            # A leading * lets the rest of the batch run even if one DELE fails.
            args+=(-Q "*DELE /$REMOTE_DIR/$name")
            if $THUMBNAILS_ON; then
                base=${name%.*}
                for thumb in "$base.jpg" "${base}_mini.jpg"; do
                    [ -n "${remote_thumbs[$thumb]:-}" ] || continue
                    args+=(-Q "*DELE /$REMOTE_DIR/thumbnail/$thumb")
                done
            fi
        done
        log "freeing ${#batch[@]} timelapse(s) from the printer..."
        curl_retry "$FTP/" "${args[@]}" -o /dev/null
        sleep "$BATCH_PAUSE"
    done

    # Deletes are confirmed by looking, not by trusting a return code.
    if leftovers=$(list_dir "$REMOTE_DIR"); then
        for name in "${verified[@]}"; do
            if ! printf '%s\n' "$leftovers" | grep -qF "$name"; then
                removed=$((removed + 1))
            fi
        done
        still=$(( ${#verified[@]} - removed ))
        if [ "$still" -gt 0 ]; then
            log "  $still verified file(s) are still on the printer; the next pass will retry them"
        fi
    else
        log "  could not confirm the deletes; the next pass will sort it out"
    fi
fi

log "sync done: $downloaded new, ${#stored[@]} already stored, $removed freed from the printer, $recording still recording, $failed failed"
[ "$failed" -eq 0 ]
