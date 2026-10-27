#!/bin/bash
# Keyboard LED test: read back via firmware, then a sequence of visible steps,
# each held for $HOLD seconds so you can watch the keyboard.
#   sudo ./Scripts/led-test.sh [logfile]
set -uo pipefail

CTL="$(cd "$(dirname "$0")/.." && pwd)/build/nitroctl"
LOG="${1:-/dev/stdout}"
HOLD="${HOLD:-6}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

led_regs() {
    "$CTL" dump | awk '/^10:/ {print "   0x17-1E:", $9, $10, $11, $12, $13, $14, $15, $16} /^30:/ {z=$14" "$15" "$16" "$17} /^40:/ {print "   0x3C-48:", z, $2, $3, $4, $5, $6, $7, $8, $9, $10}'
}

step() {  # step number, description, nitroctl args...
    local n=$1 desc=$2; shift 2
    echo "== [$n] $desc: nitroctl $*" >>"$LOG"
    "$CTL" "$@" >/dev/null 2>>"$LOG" || echo "!! failed" >>"$LOG"
    led_regs >>"$LOG"
    sleep "$HOLD"
}

: >"$LOG" 2>/dev/null || true
echo "== firmware read-back" >>"$LOG"
for z in 01 02 04 08; do "$CTL" wmbh 0x07 "$z" >>"$LOG" 2>&1; done
"$CTL" wmbh 0x15 >>"$LOG" 2>&1
led_regs >>"$LOG"

step 0 "enable 4-zone keyboard"          led init
"$CTL" led init >>"$LOG" 2>&1
step 1 "all zones red"                   led zone all ff0000
step 2 "zones red/green/blue/white"      led zone 1 ff0000
"$CTL" led zone 2 00ff00 >/dev/null 2>>"$LOG"
"$CTL" led zone 3 0000ff >/dev/null 2>>"$LOG"
"$CTL" led zone 4 ffffff >/dev/null 2>>"$LOG"
led_regs >>"$LOG"
sleep "$HOLD"
step 3 "brightness 30"                   led brightness 30
step 4 "brightness 100"                  led brightness 100
step 5 "breathing cyan, speed 5"         led effect breathing 5 00ffff
step 6 "wave, speed 7"                   led effect wave 7
step 7 "neon, speed 5"                   led effect neon 5
step 8 "back to static 4-colour"         led effect static
echo "== done" >>"$LOG"
