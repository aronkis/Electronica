#!/bin/bash
# =============================================================================
# rate_probe.sh <ip> [dwell_s] -- RESET-AWARE frame-rate measurement.
#
# REPLACES the primitive used everywhere in this campaign:
#     p0=$(rd 0x104); sleep DWELL; p1=$(rd 0x104); rate=(p1-p0)/DWELL
# which is WRONG whenever a reset lands inside the window. 0x104 is reset by
# rstCS. A reset mid-window makes p1-p0 mean "frames since the last reset" --
# still POSITIVE, so the usual negative-delta guard never fires, but far too
# small. Measured in the soak CSVs: 0x104 resets every ~5-7 s, and 51% of those
# resets coincide with an rstcs change against a 1.2% base rate.
#
# The arithmetic of the bug, for the record: resets every ~15 s over a 30 s
# window give 1244*15/30 = 622 apparent f/s on a link actually running at 1244.
# That is the whole "control measures ~500 f/s" mystery.
#
# THIS VERSION samples ACROSS the dwell and reports three INDEPENDENT numbers:
#   frames_s  -- mean instantaneous rate over intervals containing NO reset
#   resets_s  -- reset rate, its own metric (a treatment can move this alone)
#   valid_pct -- fraction of wall time actually covered by clean intervals
#
# SINGLE-READER RULE: only one process may hold direct_reg_access. stallpoll and
# lock_watchdog sharing it corrupted 0.09% of soak rows with foreign register
# values (0xc010180 appeared 68 times as a "packet count"), and one such value
# inflates a run delta by 2e8. Callers must stop other pollers first.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:?usage: rate_probe.sh <ip> [dwell_s]}
DWELL=${2:-30}
STEP=${STEP:-0.25}

RAW=$($W "$IP" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
end=\$(( \$(date +%s) + $DWELL ))
while [ \$(date +%s) -lt \$end ]; do
  echo 0x104 > \$DRA; p=\$(cat \$DRA)
  echo 0x150 > \$DRA; r=\$(cat \$DRA)
  echo \"\$(date +%s%N),\$p,\$r\"
  sleep $STEP
done" 2>/dev/null)

echo "$RAW" | python3 -c '
import sys
rows=[]
for line in sys.stdin:
    f=line.strip().split(",")
    if len(f)<3: continue
    try: rows.append((int(f[0]),int(f[1],16),int(f[2],16)))
    except ValueError: pass
if len(rows)<5:
    print("frames_s=-1 resets_s=-1 valid_pct=0   # too few samples"); raise SystemExit
span=(rows[-1][0]-rows[0][0])/1e9
good_t=0.0; good_f=0; resets=0; rst=0
PLAUS=3000            # f/s ceiling; a higher value means a torn/foreign read
bad=0
for (ta,pa,ra),(tb,pb,rb) in zip(rows,rows[1:]):
    dt=(tb-ta)/1e9
    if dt<=0: continue
    if pb<pa: resets+=1; continue          # interval contains a reset -> unusable
    rate=(pb-pa)/dt
    if rate>PLAUS: bad+=1; continue        # foreign/torn read -> discard
    good_t+=dt; good_f+=pb-pa
    rst+=max(0,rb-ra)
fs = good_f/good_t if good_t>0 else -1
print(f"frames_s={fs:.0f} resets_s={resets/span:.2f} rstcs_s={rst/good_t if good_t>0 else 0:.1f} "
      f"valid_pct={100*good_t/span:.0f} samples={len(rows)} discarded={bad}")
'
