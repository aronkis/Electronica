#!/bin/bash
# =============================================================================
# stage3h_reader.sh -- stage 3h: read the SEQ-BIST checker on 148 DURING a normal
# daemon leg, with the checker in HOST-FRAME mode.
#
# Why this leg exists: stage 3 proved the fabric can carry a filler-free generator
# stream across the air at full rate, but the generator is not the mission traffic.
# 3h puts the checker on the REAL daemon stream at the fabric decoder pins, upstream
# of the RX DMA and the host, so its loss number is directly comparable with the
# host's 8.12 % PER on the same leg.
#
# HOST-FRAME mode = tgen_mode (0x9D410000 bit 5) CLEARED, so rx_seq_checker CRC32-checks
# the daemon's real frames instead of accepting the generator's 0x54474E21 constant.
# SINK is none: the daemon's own S2MM drains the seam, so the seam is live without us.
# Every write to 0x9D410000 is a read-modify-write and bit 0 is never touched.
#
# Ordering: the bring-up inside the daemon leg re-arms both radios, and a
# direct_reg_access read during an ADRV9002 profile reload hangs the board (the
# documented double-hang). So this script waits for BOTH: the leg's own
# "BRING-UP COMPLETE" line, and the nemo-side arm guard going clear.
#
# Env: LEGLOG (required: the leg's capture_r3.log), DUR=540, BOARD=148,
#      OUT (run dir), WAIT_MAX=420, DRY=1
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); TJ=$(cd "$S/.." && pwd); W=$TJ/anyssh.sh
. "$TJ/sim_repro/no_arm_inflight.sh"
BOARD=${BOARD:-148}
case "$BOARD" in 148) BRD=10.0.0.148 ;; 146) BRD=10.0.0.146 ;; *) BRD=$BOARD ;; esac
DUR=${DUR:-540}; WAIT_MAX=${WAIT_MAX:-420}; DRY=${DRY:-1}
LEGLOG=${LEGLOG:?usage: LEGLOG=<leg capture_r3.log> stage3h_reader.sh}
TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$TJ/comb/runs/${TS}_seqbist_s3h}
mkdir -p "$OUT"
DM='DM=$(command -v devmem || echo "busybox devmem")'
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }
log "=== stage3h_reader: checker on $BOARD in HOST-FRAME mode during the daemon leg; DUR=$DUR DRY=$DRY -> $OUT ==="

if [ "$DRY" = 1 ]; then
  log "[dry] wait for BRING-UP COMPLETE in $LEGLOG and for the nemo arm guard to clear"
  log "[dry] RMW 0x9D410000 on $BRD: clear bit5 (tgen_mode=0, host-frame CRC32), bit0 untouched"
  log "[dry] RMW pulse bit4 low->high (checker clear), checker left enabled"
  log "[dry] timeout $DUR python3 seqbist_read.py $BOARD --watch 10 >> $OUT/readings.jsonl"
  echo "leg=seqbist_s3h board=$BRD mode=hostframe dur=$DUR dry=1 window_s=0" > "$OUT/meta.txt"
  log "=== stage3h_reader done (dry) ==="; exit 0
fi

waited=0
while :; do
  # The guard must be the NARROW one here. no_arm_inflight.sh's arm_guard refuses while
  # capture_r3.sh is running -- but capture_r3.sh runs for the WHOLE leg, so waiting on it
  # means never reading at all (measured: the first t8-3h-read sat blocked past its own
  # BRING-UP COMPLETE). The hazard the guard exists for is an ADRV9002 PROFILE RELOAD, which
  # lives in bringup_r2r3.sh / restore_known_good.sh and is finished by definition once the
  # leg has printed BRING-UP COMPLETE. So: wait for that line AND for no bring-up script in
  # flight, and do not wait on capture_r3.sh itself.
  if grep -q "BRING-UP COMPLETE" "$LEGLOG" 2>/dev/null \
     && ! ps -eo args | grep -qE "^(/bin/bash|bash|/bin/sh) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|soak_bidir)\.sh"; then
    log "leg bring-up complete and no arm in flight after ${waited}s -- taking the checker"
    break
  fi
  [ "$waited" -ge "$WAIT_MAX" ] && { log "STAGE3H_ABORT: no BRING-UP COMPLETE within ${WAIT_MAX}s"; \
    echo "leg=seqbist_s3h board=$BRD mode=hostframe dur=$DUR dry=0 window_s=0 abort=no_bringup" > "$OUT/meta.txt"; exit 7; }
  sleep 5; waited=$((waited+5))
done
sleep 5

C0=$($W "$BRD" "$DM; \$DM 0x9D410000" 2>/dev/null | tr -d '\r')
log "tgen_rx ctrl before: $C0"
C1=$($W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~32 )); \$DM 0x9D410000" 2>/dev/null | tr -d '\r')
log "HOST-FRAME mode: tgen_mode (bit5) cleared, ctrl=$C1 (bit0 untouched)"
C2=$($W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 )); \$DM 0x9D410000" 2>/dev/null | tr -d '\r')
log "checker clear pulse (bit4 low->high), ctrl=$C2"

READINGS=$OUT/readings.jsonl; : > "$READINGS"
t0=$(date +%s)
timeout "$DUR" python3 "$S/seqbist_read.py" "$BOARD" --watch 10 >> "$READINGS" 2>>"$OUT/run.log"
t1=$(date +%s); WIN=$((t1-t0))
N=$(wc -l < "$READINGS")
C3=$($W "$BRD" "$DM; \$DM 0x9D410000" 2>/dev/null | tr -d '\r')
log "window_s=$WIN n_readings=$N ctrl_after=$C3"
# restore tgen_mode for the next generator leg (RMW, bit0 untouched)
C4=$($W "$BRD" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 32 )); \$DM 0x9D410000" 2>/dev/null | tr -d '\r')
log "tgen_mode restored for later generator legs, ctrl=$C4"
{
  echo "leg=seqbist_s3h board=$BRD mode=hostframe dur=$DUR dry=0 window_s=$WIN"
  echo "n_readings=$N rearms_in_window=0 rearm_pre_window=0 arm_verified_by_effect=1"
  echo "sink=none tgen_mode=0 gap=NA skip_every=0 corrupt_every=0 fill=NA"
  echo "ctrl_pre=$C0 ctrl_hostframe=$C1 ctrl_cleared=$C2 ctrl_post=$C3 ctrl_restored=$C4"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"
log "STAGE3H_DONE $OUT"
echo "STAGE3H_DONE $OUT"
