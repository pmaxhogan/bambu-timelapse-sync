#!/usr/bin/env bash
# Healthy when a sync finished cleanly within the last two intervals. A single
# failed pass is normal (the printer sleeps), so give it two chances to recover.
set -uo pipefail
STAMP=/tmp/last-successful-sync
INTERVAL="${SYNC_INTERVAL:-3600}"
[ "$INTERVAL" -le 0 ] 2>/dev/null && exit 0
[ -f "$STAMP" ] || exit 0   # not through the first pass yet
age=$(( $(date +%s) - $(date -r "$STAMP" +%s) ))
[ "$age" -lt $(( INTERVAL * 2 + 300 )) ]
