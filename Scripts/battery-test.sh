#!/bin/bash
# Battery charge-limit test: status -> on -> status -> off -> status, logging the
# firmware reply and EC row 0x00 (0x03 holds LMEN/PSEE/BTHE bits) after each step.
# Ends with the limit OFF unless FINAL=on.   sudo ./Scripts/battery-test.sh [logfile]
set -uo pipefail

CTL="$(cd "$(dirname "$0")/.." && pwd)/build/nitroctl"
LOG="${1:-/dev/stdout}"
FINAL="${FINAL:-off}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

step() {  # label, battery limit arg
    echo "== $1" >>"$LOG"
    "$CTL" battery limit "$2" >>"$LOG" 2>&1 || echo "!! failed" >>"$LOG"
    echo "   EC $("$CTL" dump | sed -n 2p)" >>"$LOG"
    echo "   pmset: $(pmset -g batt | tail -1 | sed -E 's/.*\t//')" >>"$LOG"
}

: >"$LOG" 2>/dev/null || true
step "initial status" status
step "limit on"       on
sleep 3
step "status after on" status
step "limit off"      off
sleep 3
step "status after off" status
if [[ $FINAL == on ]]; then
    step "final: limit on" on
fi
