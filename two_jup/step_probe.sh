#!/bin/bash
# =============================================================================
# step_probe.sh -- localize the ~5 s post-arm STEP-DOWN (1244 -> ~500 f/s).
#
# decay_trace.sh established the step is real (0 counter resets in 120 s) but not
# WHERE it lives. This applies two escalating stimuli to an already-stepped-down
# link and watches whether the rate recovers:
#
#   t=20 s  0x110 rstCS pulse   -- resets ONLY the carrier-sync state.
#   t=40 s  0x000 soft re-arm   -- resets the whole modem datapath (+ re-select).
#
# Reading:
#   rstCS restores full rate      -> the step lives in CARRIER-SYNC state, and a
#                                    cheap periodic pulse is a candidate mitigation.
#   only 0x000 restores it        -> deeper demod state; needs a full re-arm.
#   NEITHER restores it           -> the step is in the RF/SSI/analog domain
#                                    (e.g. an ADRV9002 tracking cal), not the fabric.
#   recovery then re-steps ~5 s later -> repeatable, so we have a fast probe and
#                                    the "arm lottery" is fully explained as probe phase.
#
# SINGLE-READER RULE: stops lock_watchdog and stallpoll first (they share the one
# direct_reg_access address latch; 0xC010180 = adc_forensic 0x15C bled into the
# packet-count column of the soak CSVs).
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; IP=${IP:-10.0.0.146}
DUR=${DUR:-60}
OUT=$D/decay/step_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

$W $IP 'pkill -f "[l]ock_watchdog"; pkill -f "[s]tallpoll"; sleep 1; echo "  pollers stopped"' 2>/dev/null

echo "=== tracing $DUR s with stimuli at t=20 (rstCS) and t=40 (0x000 re-arm) ==="
$W $IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done)
T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
: > /dev/shm/step.csv
s=\$(date +%s); end=\$(( s + $DUR )); did20=0; did40=0
while [ \$(date +%s) -lt \$end ]; do
  now=\$(( \$(date +%s) - s ))
  if [ \$now -ge 20 ] && [ \$did20 = 0 ]; then
    echo \"\$(date +%s%N),STIM,rstCS\" >> /dev/shm/step.csv
    echo '0x110 0x1' > \$DRA; sleep 0.3; echo '0x110 0x0' > \$DRA
    did20=1
  fi
  if [ \$now -ge 40 ] && [ \$did40 = 0 ]; then
    echo \"\$(date +%s%N),STIM,softreset\" >> /dev/shm/step.csv
    echo '0x000 0x1' > \$DRA; sleep 0.5; echo '0x000 0x0' > \$DRA
    echo '0x158 0x1' > \$DRA; echo '0x118 0x0' > \$DRA; echo '0x114 0x1' > \$DRA
    if [ -n \"\$TXD\" ]; then echo '0x418 0x2' > \$T; echo '0x458 0x2' > \$T; echo '0x044 0x1' > \$T; fi
    echo '0x110 0x1' > \$DRA; sleep 0.3; echo '0x110 0x0' > \$DRA
    did40=1
  fi
  echo 0x104 > \$DRA; p=\$(cat \$DRA)
  echo 0x150 > \$DRA; r=\$(cat \$DRA)
  echo \"\$(date +%s%N),\$p,\$r\" >> /dev/shm/step.csv
  sleep 0.25
done
echo done \$(wc -l < /dev/shm/step.csv)" 2>/dev/null

$W $IP 'cat /dev/shm/step.csv' 2>/dev/null > "$OUT/step.csv"
echo "=== $(wc -l < "$OUT/step.csv") rows -> $OUT/step.csv ==="

python3 - "$OUT/step.csv" <<'PY'
import sys,csv
rows=[]
for r in csv.reader(open(sys.argv[1])):
    if len(r)<3: continue
    if r[1]=='STIM': rows.append((int(r[0]),None,r[2])); continue
    try: rows.append((int(r[0]),int(r[1],16),int(r[2],16)))
    except ValueError: pass
if len(rows)<5: print("too few"); raise SystemExit
t0=rows[0][0]
# 2 s blocks, annotated with stimuli
print("  window        f/s   rstcs   note")
blk=[]; i=0
data=[x for x in rows if x[1] is not None]
stims=[(x[0],x[2]) for x in rows if x[1] is None]
while i < len(data)-1:
    ta=data[i][0]; j=i
    while j<len(data)-1 and (data[j][0]-ta)<2e9: j+=1
    dt=(data[j][0]-ta)/1e9; dp=data[j][1]-data[i][1]; dr=data[j][2]-data[i][2]
    note=""
    for st,lbl in stims:
        if ta<=st<data[j][0]: note=f"<== {lbl}"
    if dt>0:
        rate = dp/dt if dp>=0 else -1
        print(f"  {(ta-t0)/1e9:5.1f}-{(data[j][0]-t0)/1e9:5.1f}s {rate:7.0f}   {dr:+4d}   {note}")
    i=j
PY
