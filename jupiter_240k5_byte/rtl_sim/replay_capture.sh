#!/bin/bash
# =============================================================================
# replay_capture.sh <capture.iq> [opts] -- the campaign's FIXED-POINT-leg oracle.
#
# Replays a raw int16 I,Q hardware capture (Tap-A, 1.92 Msps) through the
# bit-true TxRxComposite netlist (obj_byte_iq/Vwrap_byte) with:
#   * zero-run splice ONCE (iq_prep.py) -- parity with the float leg, which
#     strips zeros internally; the raw RTL feed must see the same stream,
#   * a SAMPLE-level quadrant sweep: rot {0,90,180,270} x vphase {0,1} = 8 runs
#     (a cold-start wrong-quadrant lock scrambles post-FEC bits irrecoverably;
#     scoring-level rotation cannot fix it -- this sweep is what made the prior
#     floor_148 replay conclusive-izable),
#   * best-of scoring via score_rxw_ref vs the -B reference (or -r REFFILE for
#     ROM-on-air captures: pass rx_words_golden.hex).
#
# Options:
#   -o DIR     output dir (default: rtl_sim/replay/<capture-basename>[-dc])
#   -r FILE    16-hexword reference file (default: built-in -B, seed 0x1a5)
#   -s N       skip_count (default 0; mirror the live arm's value)
#   -e N       rstcs_end clk (default 8400, the proven replay arm pulse)
#   -j N       parallel sim jobs (default 8 -- the full sweep at once)
#   --dc       DC-removal ablation (subtract mean before replay)
# Output: <outdir>/verdict.txt + replay_verdict.mat + per-run _rxw/_res/.log
# =============================================================================
set -u
KIT=$(cd "$(dirname "$0")/.." && pwd)
RTL=$KIT/rtl_sim
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/usr/local/bin:/usr/bin:/bin

CAP=${1:?usage: replay_capture.sh <capture.iq> [-o outdir] [-r reffile] [-s skip] [-e rstcs_end] [-j jobs] [--dc]}
shift
OUT="" REF="" SKIP=0 RSTCS_END=8400 JOBS=8 DC=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT=$2; shift 2;;
    -r) REF=$2; shift 2;;
    -s) SKIP=$2; shift 2;;
    -e) RSTCS_END=$2; shift 2;;
    -j) JOBS=$2; shift 2;;
    --dc) DC=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

test -f "$CAP" || { echo "FATAL: capture not found: $CAP" >&2; exit 1; }
test -x "$RTL/obj_byte_iq/Vwrap_byte" || { echo "FATAL: run build_replay_iq.sh first" >&2; exit 1; }
BASE=$(basename "$CAP" .iq); [ "$DC" = 1 ] && BASE="${BASE}-dc"
[ -n "$OUT" ] || OUT=$RTL/replay/$BASE
mkdir -p "$OUT"

DCFLAG=""; [ "$DC" = 1 ] && DCFLAG="--dc"
echo "=== replay_capture: $CAP -> $OUT (skip=$SKIP rstcs_end=$RSTCS_END dc=$DC ref=${REF:--B}) ==="

# ---- 1. preprocess: zero-splice (+ optional DC) x 4 exact rotations ----
for ROT in 0 90 180 270; do
  python3 "$RTL/iq_prep.py" "$CAP" "$OUT/prep_r$ROT.iq" --rot $ROT $DCFLAG | tee -a "$OUT/prep.log"
done
NSAMP=$(( $(stat -c%s "$OUT/prep_r0.iq") / 4 ))
echo "prepped NSAMP=$NSAMP complex samples (~$((NSAMP/9064)) frames)"

# ---- 2. the 8-run sweep (cadence=2 = 1.92 Msps rail; sims run in parallel) ----
cd "$RTL"   # Vwrap_byte reads ./rx_words_golden.hex from cwd (optional golden tracker)
n=0
for ROT in 0 90 180 270; do
  for VP in 0 1; do
    ( ./obj_byte_iq/Vwrap_byte "$OUT/prep_r$ROT.iq" "$NSAMP" $VP 2 "$RSTCS_END" "$SKIP" \
        "$OUT/r${ROT}v${VP}" > "$OUT/r${ROT}v${VP}.log" 2>&1 ) &
    n=$((n+1))
    [ $((n % JOBS)) -eq 0 ] && wait
  done
done
wait
grep -H '^IQ ' "$OUT"/r*v*.log | sed 's|.*/||' || true

# ---- 3. score the sweep, pick the locked hypothesis, emit the verdict ----
matlab -batch "cd('$RTL'); replay_verdict('$OUT','$REF');" || { echo "REPLAY_CAPTURE_FAIL (verdict)"; exit 1; }
echo "---"
cat "$OUT/verdict.txt"
echo "REPLAY_CAPTURE_DONE $OUT"
