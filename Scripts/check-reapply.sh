#!/bin/bash
# After sleep/wake or reboot: did nitrod re-apply, and does the EC match config.json?
#   ./Scripts/check-reapply.sh        (no sudo)
CTL="$(cd "$(dirname "$0")/.." && pwd)/build/nitroctl"
echo "== boot / last wake"
sysctl -n kern.boottime | sed 's/.*} //'
pmset -g log 2>/dev/null | grep -E "^\S+ \S+ \S+ +Wake +" | tail -1 | cut -c1-90
echo "== nitrod applies (last 5)"
grep -E "apply \(|failsafe|failed|:.*[Ee]rror" /var/log/nitrod.log | tail -5
echo "== config vs EC"
"$CTL" daemon status --json 2>/dev/null | python3 -I -c '
import json, sys
t = sys.stdin.read(); j = json.loads(t[:t.rindex("}") + 1]); c = j["config"]
ec = j.get("ec") or []
if len(ec) != 256: sys.exit("no EC data from nitrod")
modes = {"quiet": 0, "default": 1, "extreme": 4}
effects = ["static","breathing","neon","wave","shifting","zoom","meteor","twinkling"]
checks = [
    ("battery limit", c["batteryLimit"], bool(ec[0x03] & 0x40)),
    ("PSEE", True, bool(ec[0x03] & 0x10)),
    ("power plan", c["nitroMode"], next((k for k, v in modes.items() if v == ec[0x2C]), hex(ec[0x2C]))),
    ("usb charge", c["usbCharge"], ec[0x08] == 0x0F),
    ("kb timeout", c["kbTimeout"], ec[0x06] == 0x1E),
    ("led effect", c["led"]["effect"], effects[ec[0x17]] if ec[0x17] < 8 else hex(ec[0x17])),
    ("led brightness", c["led"]["brightness"], ec[0x19]),
]
bad = 0
for name, want, got in checks:
    ok = want == got; bad += not ok
    status = "OK " if ok else "BAD"
    print(f"{status} {name:15} config={want!s:10} ec={got}")
print("all match" if not bad else f"{bad} mismatch(es)")
print("(EC only stores what was written: also look at the keyboard itself)")
'
