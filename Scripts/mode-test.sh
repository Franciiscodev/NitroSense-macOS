#!/bin/bash
# Operating-mode test: for quiet/default/extreme, idle then 30 s of 12-thread load,
# sampling fans, temps and CPU package power. Ends in default mode with no load.
#   sudo ./Scripts/mode-test.sh [logfile]
set -uo pipefail

CTL="$(cd "$(dirname "$0")/.." && pwd)/build/nitroctl"
LOG="${1:-/dev/stdout}"
LOAD_PIDS=()

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

stop_load() {
    ((${#LOAD_PIDS[@]})) && kill -KILL "${LOAD_PIDS[@]}" 2>/dev/null  # osascript shells ignore SIGTERM
    LOAD_PIDS=()
}
trap 'stop_load; "$CTL" mode default >/dev/null 2>&1; echo "[exit] load stopped, mode default" >>"$LOG"' EXIT

sample() {  # label  (takes ~3 s: powermetrics window)
    local power
    power=$(powermetrics --samplers cpu_power -n 1 -i 3000 2>/dev/null \
        | grep -E "package power|Average frequency" | sed -E 's/.*: //' | paste -sd' ' -)
    printf '%-16s %s | %s\n' "$1" \
        "$("$CTL" status | grep -E 'Temperatures|fan' | tr -s ' ' | sed -E 's/ \(0xB3, unverified\)//; s/ manual [0-9]+%//g; s/ mode / /g' | paste -sd'|' -)" \
        "${power:-no powermetrics}" >>"$LOG"
}

: >"$LOG" 2>/dev/null || true
for mode in quiet default extreme; do
    echo "== mode $mode" >>"$LOG"
    "$CTL" mode "$mode" >/dev/null 2>>"$LOG" || { echo "!! mode $mode failed" >>"$LOG"; exit 1; }
    echo "   OPMS(0x2C) = $("$CTL" read 0x2C)" >>"$LOG"
    for i in 1 2 3; do sample "$mode-idle"; done
    for c in $(seq 12); do yes >/dev/null 2>&1 & LOAD_PIDS+=($!); done
    for i in $(seq 10); do sample "$mode-load"; done
    stop_load
    sleep 20
done
