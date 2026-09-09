#!/bin/bash
# w1_read.sh -- RXFIX Task 9 (RXFIX_W1): read the eight ring-witness / per-stage
# valid census words from a board running an RXFIX_W1 image, at most once per
# 10 s, one JSON line per reading.
#
# WHAT IT READS (see two_jup/rxfix/W1_REGMAP.md for the full map)
#   0x214 witA = {16'b0, occTrue[5:0], pushPtr[4:0], popPtr[4:0]}   TRUE occupancy 0..32
#   0x218 witB = {push_on_full_count[15:0], pop_on_empty_count[15:0]}
#   0x21C cSS   Symbol_Synchronizer strobe   (ring PUSH request)
#   0x220 cRH   Rate_Handle validOut
#   0x224 cCFC  Coarse_Frequency_Compensator validOut
#   0x228 cCS   Carrier_Synchronizer validOut
#   0x22C cPD   Preamble_Detector validOut
#   0x230 cPC   Packet_Controller validOut
#
# WITH R4B=1 (Task 13, an image carrying RXFIX_W1 *and* RXFIX_R4B) a NINTH word is
# swept:
#   0x234 r4bWit = {r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}
# It is deliberately NOT behind W1's freeze (one word, so a single AXI read is
# already coherent -- W1_REGMAP.md sec 5.1), so it is read in BOTH sweeps and
# reported twice: `words.r4bWit` from the first sweep, `r4b_wit2` from the second,
# and `r4b_moved` for whether it advanced between them.  freeze_effective is still
# computed over the EIGHT frozen words ONLY: including the ninth would make every
# reading of a live board freeze_effective:false, and Task 9's rule says such a
# reading must be discarded -- which would throw away the whole leg.  On a freeze
# HOLD reading `r4b_moved:true` is itself the positive control that the ninth word
# is live and outside the shadow.
#
# HOW TO USE IT (Task 7 report sec 6.3): take TWO readings K air frames apart with
# FREEZE=1 held across each sweep, then subtract.  Every delta must be 12,333*K
# upstream of the deframer and 12,320*K after sample_discard_controller.  The
# FIRST stage whose delta falls short is the deleting stage.  If every delta is
# exact while frames still die at the ~32-frame comb period, the loss is NOT a
# symbol deletion and the SRO/Rate_Handle path is exonerated on silicon.
#
# MECHANISM: modem registers are read through the IIO debugfs direct_reg_access
# node, exactly as two_jup/seqbist/seqbist_run.sh:122-132 does -- NOT devmem.
# devmem is for the 0x9D4x BD GPIOs; the modem AXI-lite window has no devmem
# alias on these images.  (The brief said "ssh devmem"; corrected here, with the
# in-repo precedent cited.)
#
# FREEZE IS WRITE-ONLY AND CANNOT BE READ BACK.  fixctl lives at write address
# 0x208 and reads back const_0 (KNOWN: two_jup write-only regs 0x158/0x114/0x118/
# 0x10C/0x208).  So this script NEVER read-modify-writes it: it writes
# FIXCTL_BASE|0x10 to freeze and FIXCTL_BASE to release, where FIXCTL_BASE is the
# value the operator knows is currently armed (default 0).  Passing the wrong
# FIXCTL_BASE would silently clear enSlack (bit 3) or the TXCAP/DEMODCAP mux bits
# (12/13) -- state it deliberately.  Freeze is verified BY EFFECT: with FREEZE=1
# two consecutive sweeps must return identical words; the script reports
# freeze_effective per reading.
#
# K=V env:
#   BOARD=148|146   (required)
#   N=<readings>    (required, >= 1)
#   PERIOD=10       (floor 10 s; a lower value is clamped up with a logged warning)
#   FREEZE=1|0      (default 1: hold the shadows across each eight-word sweep)
#   R4B=1|0         (default 0: also sweep 0x234, the R4B witness word -- only on an
#                    image built from a W1+R4B kit; reads const_0 on a W1-only image)
#   FIXCTL_BASE=0   (the fixctl value to OR the freeze bit into / restore)
#   AUX="0x104 ..." (default empty; extra READ-ONLY addresses swept in the SAME ssh
#                    round trip, reported under "aux". See AUX IS NOT FROZEN below.)
#   HOLD=<secs>     (default 0; sleep this long BETWEEN the two frozen sweeps, inside
#                    the freeze window -- the 10 s freeze-path positive control)
#   DRY=1           (default; zero board contact -- uses the ssh shim below)
#   SSH=<path>      (override the ssh wrapper; DRY tests point it at a shim)
#   OUT=<dir>
#
# AUX IS NOT FROZEN, AND THAT IS THE POINT OF THE TIMESTAMPS.  The freeze (fixctl
# bit 4) holds the EIGHT W1 shadow words and nothing else.  An AUX address such as
# 0x104 (packets_out) keeps counting while the sweep runs, so an AUX value is NOT
# part of the coherent snapshot: it is sampled `aux_lag_s` AFTER the freeze instant.
# The script therefore reports three board-side timestamps per reading --
# t_freeze (immediately after the freeze write), t_aux (immediately before the AUX
# reads) and t_end -- so a consumer can BOUND the pairing error as
# rate x aux_lag_s rather than assume the two are simultaneous.  Task 10's census
# control needs exactly this: "census delta == frames x 12,333 within +/-1 frame"
# is NOT achievable against 0x104, because 0x104 is not behind the freeze.
#
# DRY=1 performs no ssh at all and emits N lines with "dry":true and null words.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/rxfix
TJ=$(cd "$D/.." && pwd)                   # two_jup
W=${SSH:-$TJ/anyssh.sh}
DRY=${DRY:-1}
BOARD=${BOARD:?usage: BOARD=148|146 N=<readings> w1_read.sh}
N=${N:?usage: BOARD=148|146 N=<readings> w1_read.sh}
PERIOD=${PERIOD:-10}
FREEZE=${FREEZE:-1}
R4B=${R4B:-0}
FIXCTL_BASE=${FIXCTL_BASE:-0}
AUX=${AUX:-}
HOLD=${HOLD:-0}
case "$HOLD" in ''|*[!0-9]*) echo "HOLD must be a non-negative integer (seconds)" >&2; exit 2 ;; esac
# AUX is interpolated into a remote shell `for` list; keep it to hex addresses only.
for a in $AUX; do
  case "$a" in
    0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F]) ;;
    *) echo "AUX entries must be 0xNN/0xNNN hex addresses (got '$a')" >&2; exit 2 ;;
  esac
done
NAUX=$(printf %s "$AUX" | wc -w)

case "$BOARD" in
  148) BRD=10.0.0.148 ;;
  146) BRD=10.0.0.146 ;;
  *) echo "BOARD must be 148 or 146" >&2; exit 2 ;;
esac
case "$N" in ''|*[!0-9]*|0) echo "N must be a positive integer" >&2; exit 2 ;; esac
case "$FREEZE" in 0|1) ;; *) echo "FREEZE must be 0 or 1" >&2; exit 2 ;; esac
case "$R4B" in 0|1) ;; *) echo "R4B must be 0 or 1" >&2; exit 2 ;; esac

PERIOD_WARN=""
if [ "$PERIOD" -lt 10 ] 2>/dev/null; then
  PERIOD_WARN="PERIOD=$PERIOD requested < 10s floor, clamped to 10"
  PERIOD=10
fi

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_w1_${BOARD}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" >> "$OUT/run.log"; }
[ -n "$PERIOD_WARN" ] && log "WARN: $PERIOD_WARN"
log "=== w1_read.sh: board=$BOARD ($BRD) n=$N period=${PERIOD}s freeze=$FREEZE r4b=$R4B fixctl_base=$FIXCTL_BASE dry=$DRY -> $OUT ==="

ADDRS="0x214 0x218 0x21C 0x220 0x224 0x228 0x22C 0x230"
NAMES="witA witB cSS cRH cCFC cCS cPD cPC"
# The eight frozen words, then (R4B=1 only) the unfrozen ninth appended to each sweep.
NFRZ=8
if [ "$R4B" = 1 ]; then
  SWEEP="$ADDRS 0x234"; NSW=9; NAMES="$NAMES r4bWit"
else
  SWEEP="$ADDRS"; NSW=8
fi

# One remote command per reading.  Register polling stays at one sweep per
# PERIOD (>= 10 s) -- see the rig rule that direct_reg_access traffic racing
# board state is what hangs boards; never run this during an arm.
remote_sweep(){
  # hex, matching the direct_reg_access write form used everywhere else in the
  # rig scripts (seqbist_run.sh:145 `echo "0x158 0x1" > $DRA`)
  local fx_on fx_off
  fx_on=$(printf '0x%x' $(( FIXCTL_BASE | 16 )))
  fx_off=$(printf '0x%x' "$FIXCTL_BASE")
  local pre="" post="" hold="" aux=""
  if [ "$FREEZE" = 1 ]; then
    pre="wr 0x208 $fx_on;"
    post="wr 0x208 $fx_off;"
  fi
  # HOLD=0 and AUX="" leave these empty, so the REGISTER-TOUCHING sequence of a
  # default invocation is byte-for-byte what it was before AUX/HOLD existed
  # (pinned by test_w1_read_default_remote_script_register_sequence_unchanged).
  [ "$HOLD" -gt 0 ] && hold="sleep $HOLD;"
  [ -n "$AUX" ] && aux="for a in $AUX; do rd \$a; done"
  $W "$BRD" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
     echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
     rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
     wr(){ echo \"\$1 \$2\" > \$DRA; }
     $pre
     echo W1T0=\$(date +%s.%N)
     for a in $SWEEP; do rd \$a; done
     $hold
     for a in $SWEEP; do rd \$a; done
     echo W1TA=\$(date +%s.%N)
     $aux
     echo W1T1=\$(date +%s.%N)
     $post" 2>/dev/null
}

READINGS=$OUT/readings.jsonl; : > "$READINGS"
i=1
while [ "$i" -le "$N" ]; do
  T=$(date -Is)
  if [ "$DRY" = 1 ]; then
    printf '{"ts":"%s","seq":%d,"board":%s,"dry":true,"freeze":%s,"fixctl_base":"%s","hold":%s,"words":null,"aux":null,"aux_lag_s":null,"sweep_span_s":null,"freeze_effective":null}\n' \
      "$T" "$i" "$BOARD" "$FREEZE" "$FIXCTL_BASE" "$HOLD" | tee -a "$READINGS"
  else
    RAW=$(remote_sweep | tr -d '\r')
    VALS=$(echo "$RAW" | grep -E '^(0x)?[0-9a-fA-F]+$')
    NV=$(echo "$VALS" | grep -c .)
    WANT=$((2 * NSW + NAUX))
    TF=$(echo "$RAW" | sed -n 's/^W1T0=//p' | head -1)
    TA=$(echo "$RAW" | sed -n 's/^W1TA=//p' | head -1)
    TE=$(echo "$RAW" | sed -n 's/^W1T1=//p' | head -1)
    # board-side elapsed times; null unless BOTH endpoints parsed as numbers (busybox
    # date without %N support would print a literal N -- report null, never a wrong lag)
    span(){ awk -v a="$1" -v b="$2" 'BEGIN{ if (a+0>0 && b+0>0) printf "%.3f", b-a; else printf "null" }'; }
    LAG=$(span "$TF" "$TA"); SPAN=$(span "$TF" "$TE")
    if [ "$NV" != "$WANT" ]; then
      log "read failed (got $NV of $WANT words)"
      printf '{"ts":"%s","seq":%d,"board":%s,"dry":false,"freeze":%s,"error":"got %s of %s words"}\n' \
        "$T" "$i" "$BOARD" "$FREEZE" "$NV" "$WANT" | tee -a "$READINGS"
    else
      A=$(echo "$VALS" | head -"$NSW"); B=$(echo "$VALS" | sed -n "$((NSW+1)),$((2*NSW))p")
      # freeze_effective is over the EIGHT FROZEN words only: 0x234 is outside the
      # freeze shadow by design and advances at the frame rate, so folding it in
      # would mark every live reading incoherent (W1_REGMAP.md sec 5.1).
      AF=$(echo "$A" | head -"$NFRZ"); BF=$(echo "$B" | head -"$NFRZ")
      SAME=$([ "$AF" = "$BF" ] && echo true || echo false)
      R4BX=""
      if [ "$R4B" = 1 ]; then
        w2=$(echo "$B" | sed -n "${NSW}p"); w1=$(echo "$A" | sed -n "${NSW}p")
        mv=$([ "$w1" != "$w2" ] && echo true || echo false)
        R4BX="\"r4b_wit2\":\"$w2\",\"r4b_moved\":$mv,"
      fi
      J="" ; k=1
      for n in $NAMES; do
        v=$(echo "$A" | sed -n "${k}p"); J="$J\"$n\":\"$v\","; k=$((k+1))
      done
      X=""
      if [ "$NAUX" -gt 0 ]; then
        k=$((2 * NSW + 1))
        for a in $AUX; do
          v=$(echo "$VALS" | sed -n "${k}p"); X="$X\"$a\":\"$v\","; k=$((k+1))
        done
      fi
      printf '{"ts":"%s","seq":%d,"board":%s,"dry":false,"freeze":%s,"fixctl_base":"%s","hold":%s,"words":{%s},"aux":{%s},%s"aux_lag_s":%s,"sweep_span_s":%s,"freeze_effective":%s}\n' \
        "$T" "$i" "$BOARD" "$FREEZE" "$FIXCTL_BASE" "$HOLD" "${J%,}" "${X%,}" "$R4BX" "$LAG" "$SPAN" "$SAME" | tee -a "$READINGS"
    fi
  fi
  if [ "$i" -lt "$N" ]; then sleep "$PERIOD"; fi
  i=$((i+1))
done

{
  echo "board=$BOARD n=$N period=$PERIOD freeze=$FREEZE r4b=$R4B fixctl_base=$FIXCTL_BASE hold=$HOLD dry=$DRY"
  echo "addrs=$SWEEP"
  echo "names=$NAMES"
  echo "aux=${AUX:-<none>} naux=$NAUX (NOT frozen; sampled aux_lag_s after the freeze instant)"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"
log "W1_READ_DONE $OUT ($N readings)"
echo "W1_READ_DONE $OUT"
