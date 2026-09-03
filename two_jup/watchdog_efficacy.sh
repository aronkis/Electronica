#!/bin/bash
# =============================================================================
# watchdog_efficacy.sh [secs] -- does lock_watchdog actually SEE the carrier wedge?
#
# THE SUSPICION, from lock_watchdog.sh:98
#     locked=0; [ "$dpkt" -ge "$PKT_MIN" ] && [ "$drst" -lt "$STORM_THRESH" ] && locked=1
# with PKT_MIN=50 and dpkt read from 0x104 = FABRIC PACKETS. During the carrier wedge the
# fabric still produced ~630 packets/s -- 12x over the threshold -- while cap_out was
# non-golden 99.6% of samples and biterr climbed at ~34,600/s. So the watchdog's notion
# of "locked" is "the fabric is emitting packets", not "the packets are correct".
#
# That is the SAME blindness the capture gate had (crc_health returned a RATIO, so a
# wedge reading 98% passed), one layer down. It was already observed once today:
#   [wd] FULL RE-ARM ... then LOCKED (drstcs=0 dpkts=6218 lvl=12)
# on a link that was delivering essentially nothing.
#
# THE TEST. Run the real watchdog, sample link QUALITY independently, and align them.
# Then ask two questions the code read cannot answer on its own:
#   Q1 does the watchdog ever declare NOT-LOCKED while the link is wedged?
#   Q2 if it does re-arm, does delivery actually RECOVER (or does it log LOCKED and
#      leave a dead link, which is what we appear to have been living with all day)?
#
# A watchdog that reports LOCKED through a total outage is worse than none: it converts a
# detectable failure into a silent one, and every downstream harness trusts it.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
SECS=${1:-240}
GOLDEN=0x04922282
OUT=$D/wdtest/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== watchdog_efficacy: ${SECS}s, watchdog RUNNING, quality sampled independently ==="
echo "--- arm ROM/BIST ---"
"$D/reverse_rom_soak.sh" 1 > "$OUT/arm.log" 2>&1 || true
grep -E "LOCKED|gate" "$OUT/arm.log" | tail -2

echo "--- start the real lock_watchdog on 146 ---"
# ISOLATED ssh calls. A detached launch bundled with other commands in one ssh block
# does not survive -- observed twice tonight (the restore, then here, where the watchdog
# silently never started and step 2 measured nothing). Kill, truncate and launch are
# three separate calls, and the launch is verified rather than assumed.
$W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
$W $B ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
$W $B 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
sleep 3
if $W $B 'pgrep -f "[l]ock_watchdog" >/dev/null && echo UP || echo DOWN' 2>/dev/null | grep -q UP; then
  echo "  watchdog confirmed RUNNING"
else
  echo "  !! watchdog FAILED TO START -- aborting, this test measures nothing without it"
  exit 1
fi

echo "--- sampling quality every 2s for ${SECS}s (watchdog free-running) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
  : > /dev/shm/wdq.log
  end=\$(( \$(date +%s) + $SECS ))
  pb=\$(( \$(rd 0x108) )); pp=\$(( \$(rd 0x104) ))
  while [ \$(date +%s) -lt \$end ]; do
    sleep 2
    cap=\$(rd 0x144); b=\$(( \$(rd 0x108) )); p=\$(( \$(rd 0x104) ))
    echo \"t=\$(date +%s) cap=\$cap dbiterr=\$(( b - pb )) dpkts=\$(( p - pp ))\" >> /dev/shm/wdq.log
    pb=\$b; pp=\$p
  done" 2>/dev/null

for f in wdq.log watchdog.log; do
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@$B:/dev/shm/$f "$OUT/$f" </dev/null 2>/dev/null
done

echo
echo "=== VERDICT ==="
python3 - "$OUT/wdq.log" "$OUT/watchdog.log" <<'PY'
import sys, re
GOLD = 0x04922282
q = []
for ln in open(sys.argv[1]):
    m = re.search(r"t=(\d+) cap=0x([0-9a-fA-F]+) dbiterr=(-?\d+) dpkts=(-?\d+)", ln)
    if m:
        q.append((int(m.group(1)), int(m.group(2), 16), int(m.group(3)), int(m.group(4))))
if not q:
    sys.exit("no quality samples")
bad = [r for r in q if r[1] != GOLD or r[2] > 1000]
print(f"quality samples : {len(q)}   WEDGED-looking (non-golden or dbiterr>1000): {len(bad)}")
if bad:
    print(f"  worst window: cap=0x{bad[0][1]:08x} dbiterr={max(r[2] for r in bad)} "
          f"dpkts={min(r[3] for r in bad)}")

wd = open(sys.argv[2]).read().splitlines() if len(sys.argv) > 2 else []
lk = sum(1 for l in wd if re.search(r"\bLOCKED\b", l) and "NOT-LOCKED" not in l)
nl = sum(1 for l in wd if "NOT-LOCKED" in l)
ra = sum(1 for l in wd if "RE-ARM" in l)
print(f"watchdog lines  : LOCKED={lk}  NOT-LOCKED={nl}  RE-ARM={ra}")
print()
if bad and nl == 0:
    print(">>> CONFIRMED BLIND: the link was wedged and the watchdog NEVER declared")
    print("    NOT-LOCKED. Its locked= test reads FABRIC PACKET COUNT (0x104 >= 50),")
    print("    which the wedge does not suppress -- ~630 pkts/s is 12x the threshold.")
    print("    FIX: gate on QUALITY, not quantity -- require cap_out golden and/or a")
    print("    bounded biterr rate, exactly as the capture gate was fixed today.")
elif bad and nl:
    print(f">>> watchdog DID detect it ({nl} NOT-LOCKED, {ra} re-arms). Next question is")
    print("    whether delivery recovered after the re-arm -- check the tail of wdq.log.")
else:
    print(">>> link never wedged during this window: inconclusive, re-run longer.")
PY
echo "=== artifacts: $OUT ==="
