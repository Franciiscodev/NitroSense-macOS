#!/bin/bash
# Fan write test: PSEE on, then per fan max -> manual 60 % (EC) -> manual 60 % (WMBH) -> auto.
# Always returns both fans to auto on exit.   sudo ./Scripts/fan-test.sh [logfile]
set -uo pipefail

CTL="$(cd "$(dirname "$0")/.." && pwd)/build/nitroctl"
LOG="${1:-/dev/stdout}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
trap '"$CTL" fan all auto >/dev/null 2>&1; echo "[exit] fans back to auto" >>"$LOG"' EXIT

sample() {  # label, count, interval
    for ((i = 0; i < $2; i++)); do
        printf '%-14s %s\n' "$1" "$("$CTL" status | grep -E 'Temperatures|fan' | tr -s ' ' | sed -E 's/ \(0xB3, unverified\)//' | paste -sd'|' -)" >>"$LOG"
        sleep "$3"
    done
}

step() {  # label, nitroctl fan args...
    local label=$1; shift
    echo "== $label: nitroctl $*" >>"$LOG"
    if ! "$CTL" "$@" >/dev/null 2>>"$LOG"; then
        echo "!! write failed, aborting" >>"$LOG"
        exit 1
    fi
    echo "   regs: $("$CTL" dump | sed -n '2p;4,5p' | tr -s ' ' | paste -sd' ' -)" >>"$LOG"
}

: >"$LOG" 2>/dev/null || true
sample baseline 2 2
step "psee on" psee on; sample psee 3 3
for unit in cpu gpu; do
    step "$unit max"        fan "$unit" max;             sample "$unit-max" 6 3
    step "$unit man60 ec"   fan "$unit" manual 60;       sample "$unit-m60ec" 6 3
    step "$unit man60 wmi"  fan --wmi "$unit" manual 60; sample "$unit-m60wmi" 6 3
    step "$unit auto"       fan "$unit" auto;            sample "$unit-auto" 4 3
done
