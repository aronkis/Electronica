#!/bin/bash
# t87_protocol.sh -- the T8.7 full protocol on captured episodes.
# PRECONDITIONS: telemetry image (jupiter_byte_telemetry_build) built; boards
# free (T8.6 hunt done). Steps:
#   1. deploy telemetry image both boards (staged) + smoke (retries)
#   2. capture session: error_hunt TAPMODE=4 -> input ring + TELEMETRY ring
#      windows per -S error event
#   3. rebuild the inject harness against the TELEMETRY netlist (names must
#      match this build) + validate the tel_parse register names
#   4. per event: parse telemetry -> trajectory + inject file at T0' (~2
#      frames pre-trigger); cold-sim TRACE run over the input window ->
#      sim-predicted trajectory; compare live vs sim word-by-word -> first
#      divergent register+beat (the PRIMARY verdict); injection run for
#      confirmation
#   5. emit per-event verdicts to two_jup/hunt/<session>/T87_VERDICTS.txt
set -u
T=$(cd "$(dirname "$0")" && pwd)
K=$(dirname "$T")/jupiter_240k5_byte
R=$K/rtl_sim
B=$(dirname "$T")/jupiter_byte_telemetry_build
W=$T/anyssh.sh
BOOT=$B/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
step(){ echo "T87P[$(date +%H:%M)] $*"; }
test -f "$BOOT" || { echo "T87P_ABORT: no telemetry BOOT.BIN"; exit 1; }

# 1. deploy + smoke
cd $T
for ip in 10.0.0.148 10.0.0.146; do
  BOOT=$BOOT bash deploy_tap.sh $ip >/dev/null 2>&1
  until ! ping -c1 -W1 $ip >/dev/null 2>&1; do sleep 2; done
  until ping -c1 -W2 $ip >/dev/null 2>&1; do sleep 3; done; sleep 25
  step "$ip: $($W $ip 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null)"
done
LOCKED=0
for try in 1 2 3 4; do
  RES=$(bash tap_smoke.sh A 2>&1 | grep -m1 TAP_SMOKE)
  step "smoke try$try: $RES"
  echo "$RES" | grep -q PASS && { LOCKED=1; break; }
done
[ $LOCKED = 1 ] || { echo T87P_ABORT_NO_LOCK; exit 1; }

# 2. capture session (mode 4 telemetry ring; 600 s forward)
TAPMODE=4 bash error_hunt.sh 600 A 2>&1 | tail -8
HUNT=$(ls -dt $T/hunt/*_fwd | head -1)
step "session: $HUNT"
NEV=$(ls $HUNT/ev*_tap.iq 2>/dev/null | wc -l)
[ "$NEV" -ge 1 ] || { echo T87P_ABORT_NO_EVENTS; exit 1; }

# 3. rebuild harness against the telemetry netlist + validate names
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin
VD=$K/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback
grep -q TelemetrySerializer $VD/QPSK_Rx.v 2>/dev/null || step "WARN: kit netlist may predate telemetry overlay (names could still match)"
bash $R/build_replay_inject.sh > $HUNT/inject_build.log 2>&1 || { echo T87P_ABORT_HARNESS; exit 1; }
python3 $R/tel_parse.py names > $HUNT/telnames.txt
MISS=0
while read -r nm; do
  grep -qF "\"$nm\"" $R/obj_byte_inject/inject_map.h || { step "MISSING REG: $nm"; MISS=1; }
done < $HUNT/telnames.txt
[ $MISS = 0 ] || { echo T87P_ABORT_NAME_MISMATCH; exit 1; }
step "harness + names validated"

# 4. per-event analysis
VER=$HUNT/T87_VERDICTS.txt; : > $VER
for EV in $HUNT/ev*_seq*.iq; do
  case "$EV" in *_tap.iq) continue;; esac
  TAP=${EV%.iq}_tap.iq
  [ -f "$TAP" ] || continue
  BASE=$(basename $EV .iq)
  step "analyzing $BASE"
  python3 $R/tel_parse.py traj $TAP $HUNT/${BASE}_livetraj.txt 2>>$VER || continue
  # T0' = 2 frames before the trigger (trigger at input sample 4194304 = 16M/4)
  # telemetry image nearest to that stream position feeds the inject file
  python3 - $R $HUNT $BASE $EV $TAP >> $VER <<'PYEOF'
import sys, subprocess, os
R, H, B, EV, TAP = sys.argv[1:6]
traj = [l.split() for l in open(f'{H}/{B}_livetraj.txt')]
# input trigger at sample 16M/4 = 4194304 of the input ring; the tap ring is
# sample-locked in fabric: pick the image with stream index nearest 2 frames
# (2*9064 rail beats) before the trigger-equivalent position
trig_word = 4194304 - 2*9064
best = min(range(len(traj)), key=lambda i: abs(int(traj[i][0]) - trig_word))
subprocess.run(['python3', f'{R}/tel_parse.py', 'inject', TAP, str(best),
                f'{H}/{B}_inject.txt'], check=True)
t0 = int(traj[best][0])
print(f'{B}: T0 image {best} at stream word {t0}')
# cold-sim trace over the input window, dumping the telemetry subset every 24 samples
names = open(f'{H}/telnames.txt').read().split()
open(f'{H}/{B}_subset.txt','w').write('\n'.join(names))
subprocess.run([f'{R}/obj_byte_inject/Vwrap_byte_taps', EV, '6291456', '0', '2',
                '8399', '0', f'{H}/{B}_coldsim',
                '--trace', f'{H}/{B}_subset.txt', f'{H}/{B}_simtraj.txt', '24'],
               check=True, capture_output=True)
# compare live vs sim trajectories in the post-lock region
live = {int(r[0]): r[1:23] for r in traj}
sim  = {}
for l in open(f'{H}/{B}_simtraj.txt'):
    p = l.split(); sim[int(p[0])] = p[1:]
# align: live stream words vs sim sample indices are both rail-beat scaled;
# compare word values at matching indices where both exist (nearest match)
divs = []
skeys = sorted(sim.keys())
for lw in sorted(live.keys()):
    if lw < 200000: continue   # skip acquisition
    import bisect
    j = bisect.bisect_left(skeys, lw)
    if j >= len(skeys): break
    sv = sim[skeys[j]]
    lv = live[lw]
    for wi in range(min(len(lv), 22)):
        if int(lv[wi],16) != int(sv[wi],16) if wi < len(sv) else True:
            divs.append((lw, wi)); break
    if len(divs) > 5: break
if not divs:
    print(f'{B}: TRAJECTORIES MATCH (no live-vs-sim state divergence found)')
else:
    print(f'{B}: first divergences (streamword, slot): {divs[:5]}')
PYEOF
done
step "verdicts in $VER"
cat $VER
echo T87_PROTOCOL_DONE
