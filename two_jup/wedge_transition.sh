#!/bin/bash
# =============================================================================
# wedge_transition.sh [max_s] -- capture the MOMENT the carrier wedge starts.
#
# WHY. We have both stable states characterised to death and nothing on the flip:
#   healthy : golden ~99%, cfc_std ~220,   rstcs/s 0.00, biterr/s ~400
#   wedged  : golden  0%,  cfc_std ~19000, rstcs/s ~2,   biterr/s ~34600
# Four loop settings across a 4x range were INDISTINGUISHABLE once it started, so
# retuning the loop is a closed avenue. What is missing is the ORDER of events at the
# transition, which discriminates three different faults needing three different fixes:
#
#   cfc excursion FIRST   -> the carrier loop loses lock on its own (tracking failure)
#   rstcs FIRST           -> something RESETS the carrier and it then cannot reacquire
#   AGC/level FIRST       -> a gain event drags the loop out (AGC/RF, not the loop)
#   adc maxGap/burst FIRST-> SSI delivery hiccup upstream of the modem
#
# METHOD. Arm ROM/BIST (fabric only -- DMA and host plane are irrelevant to this fault),
# then poll a small register set as fast as the DRA allows, on the BOARD, writing one
# line per sample to /dev/shm. Stop as soon as golden collapses and hold the ring, so the
# pre-transition history survives. Pull and align.
#
# Sampling on-board rather than over ssh is deliberate: an ssh round trip per sample
# would be ~10 Hz and would smear the very edge we are trying to time.
#
# Registers: 0x144 cap_out (golden), 0x154 cfc, 0x150 rstcs, 0x15C adc_forensic,
#            0x108 bit_errors, 0x104 packets.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
MAXS=${1:-600}
GOLDEN=0x04922282
OUT=$D/wedgetrans/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== wedge_transition: arm ROM/BIST then watch for the flip (max ${MAXS}s) -> $OUT ==="

# reuse the proven ROM arm from the soak tool
"$D/reverse_rom_soak.sh" 1 > "$OUT/arm.log" 2>&1 || true
grep -E "armed ROM|LOCKED|gate" "$OUT/arm.log" | tail -3

echo "--- sampling on-board until golden collapses (or ${MAXS}s) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
  : > /dev/shm/wtrans.log
  bad=0; n=0
  end=\$(( \$(date +%s) + $MAXS ))
  while [ \$(date +%s) -lt \$end ]; do
    cap=\$(rd 0x144); cfc=\$(rd 0x154); rst=\$(rd 0x150); adc=\$(rd 0x15C)
    be=\$(rd 0x108); pk=\$(rd 0x104)
    echo \"t=\$(date +%s.%N) cap=\$cap cfc=\$cfc rstcs=\$rst adc=\$adc biterr=\$be pkts=\$pk\" >> /dev/shm/wtrans.log
    n=\$((n+1))
    # NUMERIC compare: rd returns 0x4922282 but the constant is 0x04922282, so a
    # STRING compare marks every sample bad and "detects" an instant transition.
    if [ \$(( \$cap )) -ne \$(( $GOLDEN )) ]; then bad=\$((bad+1)); else bad=0; fi
    # 40 consecutive non-golden samples = the wedge has taken hold; keep a tail then stop
    if [ \$bad -ge 40 ]; then
      for i in \$(seq 60); do
        echo \"t=\$(date +%s.%N) cap=\$(rd 0x144) cfc=\$(rd 0x154) rstcs=\$(rd 0x150) adc=\$(rd 0x15C) biterr=\$(rd 0x108) pkts=\$(rd 0x104)\" >> /dev/shm/wtrans.log
      done
      echo TRANSITION_CAPTURED; break
    fi
  done
  echo \"samples=\$n\"" 2>/dev/null | tail -3

SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@$B:/dev/shm/wtrans.log "$OUT/wtrans.log" </dev/null 2>/dev/null

echo "--- ORDERING ANALYSIS ---"
python3 "$D/wedge_transition.py" "$OUT/wtrans.log"
echo "=== raw: $OUT/wtrans.log ==="
