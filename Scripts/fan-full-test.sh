#!/bin/bash
# Full fan test through nitrod (no sudo): Auto, Max, Custom, Curve idle/load, curveGPU,
# and the 95 °C failsafe under full CPU load with fans at 20 %. Restores the fan config.
#   ./Scripts/fan-full-test.sh [logfile]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/build/nitroctl"
LOG="${1:-/dev/stdout}"
: >"$LOG" 2>/dev/null || true
STRESS=()

stop_stress() { for p in "${STRESS[@]:-}"; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done; STRESS=(); }
start_stress() { for _ in $(seq "$(sysctl -n hw.ncpu)"); do yes >/dev/null & STRESS+=($!); done; }

ORIG="$("$CTL" daemon status --json | python3 -I -c 'import json,sys; print(json.dumps({"fan": json.load(sys.stdin)["config"]["fan"]}))')"
restore() { stop_stress; "$CTL" daemon set "$ORIG" >/dev/null && echo "== restored $ORIG" >>"$LOG"; }
trap restore EXIT

say() { echo "$(date +%H:%M:%S) $*" >>"$LOG"; }
set_cfg() { "$CTL" daemon set "$1" >/dev/null || say "!! set failed: $1"; }
snap() {
    "$CTL" daemon status --json | python3 -I -c '
import json, sys
j = json.load(sys.stdin); e = j["ec"]; mode = j["config"]["fan"]["mode"]; fs = j["failsafe"]
modes = {0x04: "auto", 0x08: "max", 0x0C: "manual", 0x10: "auto", 0x20: "max", 0x30: "manual", 0: "auto(0)"}
cm = modes.get(e[0x22], hex(e[0x22])); gm = modes.get(e[0x21], hex(e[0x21]))
print("%-28s CPU %3d°C %5d rpm %-7s duty %3d%% | GPU %3d°C %5d rpm %-7s duty %3d%% | cfg %s failsafe=%s" % (
    sys.argv[1], e[0xB0], e[0x13] | e[0x14] << 8, cm, e[0x37], e[0xB6], e[0x15] | e[0x16] << 8, gm, e[0x3A], mode, fs))
' "$1" | sed "s/^/$(date +%H:%M:%S) /" >>"$LOG"
}
failsafe() { "$CTL" daemon status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["failsafe"])'; }

say "== 1. basic modes (25 s settle each)"
set_cfg '{"fan":{"mode":"auto"}}';  sleep 25; snap "auto"
set_cfg '{"fan":{"mode":"max"}}';   sleep 25; snap "max"
for p in 30 60 100; do
    set_cfg "{\"fan\":{\"mode\":\"manual\",\"cpuPercent\":$p,\"gpuPercent\":$p}}"; sleep 25; snap "custom $p/$p"
done
set_cfg '{"fan":{"mode":"manual","cpuPercent":100,"gpuPercent":30}}'; sleep 25; snap "custom cpu100/gpu30"
set_cfg '{"fan":{"mode":"manual","cpuPercent":30,"gpuPercent":100}}'; sleep 25; snap "custom cpu30/gpu100"

say "== 2. curve, CPU only"
set_cfg '{"fan":{"mode":"curve","curveGPU":false}}'; sleep 20; snap "curve idle"
start_stress; say "stress on ($(sysctl -n hw.ncpu) x yes)"
for i in 1 2 3 4 5 6 7 8 9; do sleep 10; snap "curve load +$((i*10))s"; done
say "== 3. curve incl. GPU fan"
set_cfg '{"fan":{"curveGPU":true}}'
for i in 1 2 3; do sleep 10; snap "curveGPU load +$((i*10))s"; done
set_cfg '{"fan":{"curveGPU":false}}'

say "== 4. failsafe: custom 20/20 under load, wait for >= 95 °C (max 180 s)"
set_cfg '{"fan":{"mode":"manual","cpuPercent":20,"gpuPercent":20}}'
for i in $(seq 1 36); do
    sleep 5; snap "fs load +$((i*5))s"
    [[ "$(failsafe)" == "True" ]] && { say "failsafe triggered"; break; }
done
sleep 10; snap "fs after trigger +10s"
stop_stress; say "stress off, waiting for failsafe to clear (<= 85 °C, max 150 s)"
for i in $(seq 1 15); do
    sleep 10; snap "fs cool +$((i*10))s"
    [[ "$(failsafe)" == "False" ]] && { say "failsafe cleared"; break; }
done
sleep 15; snap "after clear (back to custom 20)"
grep -E "failsafe" /var/log/nitrod.log | tail -4 >>"$LOG"
