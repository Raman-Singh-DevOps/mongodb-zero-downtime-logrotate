#!/usr/bin/env bash
#
# check-logrotate.sh — health check for MongoDB custom logrotate.
#
# Answers, in one run:
#   1. Is the crontab redirect correct?  (catches the silent `2>&` bug)
#   2. Did cron actually fire the logrotate command recently?
#   3. Was the last run clean?           (error log exists AND is empty)
#   4. What do the rotated log files look like now?
#   5. Is a rotation / gzip still in progress?
#
# Run as the crontab owner (e.g. root) on a MongoDB server. Read-only: it
# changes nothing.

set -u

LOG_DIR="${MONGO_LOG_DIR:-/data/log/mongodb}"
ERR_LOG="${MONGO_ROTATE_ERR_LOG:-/tmp/mongo_rotate_error.log}"
CRON_LOG="${CRON_LOG:-/var/log/cron}"
MATCH="${LOGROTATE_MATCH:-logrotate.custom}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }
hr()    { printf '%s\n' "------------------------------------------------------------"; }

hr; echo "1. Crontab redirect check"; hr
cron_lines="$(crontab -l 2>/dev/null | grep -F "$MATCH")"
if [ -z "$cron_lines" ]; then
    yellow "  No crontab line matching '$MATCH' found."
elif crontab -l 2>/dev/null | grep -q '2>&$'; then
    red   "  BROKEN redirect found (line ends in '2>&') — logrotate is NOT running:"
    crontab -l 2>/dev/null | grep '2>&$' | sed 's/^/    /'
    echo "  Fix: change the trailing  2>&  to  2>&1"
else
    green "  OK — redirect looks correct (no trailing '2>&'):"
    echo "$cron_lines" | cat -A | sed 's/^/    /'
fi

hr; echo "2. Did cron fire the command recently?"; hr
if [ -r "$CRON_LOG" ]; then
    fired="$(grep "$MATCH" "$CRON_LOG" | tail -5)"
    if [ -n "$fired" ]; then
        green "  Recent cron entries firing the command:"
        echo "$fired" | sed 's/^/    /'
    else
        yellow "  No matching entries in $CRON_LOG yet (may be pre-first-run)."
    fi
else
    yellow "  $CRON_LOG not readable on this host — skipping."
fi

hr; echo "3. Was the last run clean?"; hr
if [ -f "$ERR_LOG" ]; then
    if [ -s "$ERR_LOG" ]; then
        red "  Error log exists but is NON-EMPTY — the run reported errors:"
        sed 's/^/    /' "$ERR_LOG"
    else
        green "  Error log exists and is empty — last run was clean."
    fi
else
    red   "  Error log MISSING ($ERR_LOG) — command likely never ran."
    echo  "  (This is the classic tell of the '2>&' syntax-error bug.)"
fi

hr; echo "4. Rotated log files"; hr
if [ -d "$LOG_DIR" ]; then
    ls -lh "$LOG_DIR" | sed 's/^/    /'
else
    yellow "  Log dir $LOG_DIR not found."
fi

hr; echo "5. Rotation in progress?"; hr
inflight="$(pgrep -a logrotate; pgrep -a gzip)"
if [ -n "$inflight" ]; then
    yellow "  A rotation/gzip is currently running — don't judge state until it clears:"
    echo "$inflight" | sed 's/^/    /'
else
    green "  No logrotate/gzip running right now."
fi
hr
