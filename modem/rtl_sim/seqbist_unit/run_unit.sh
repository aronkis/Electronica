#!/bin/bash
# run_unit.sh -- SEQ-BIST T0a unit gate (host-only, no board, no network).
#
# 1. regenerate the frame vectors with gen_frames.py
# 2. verilator --lint-only on the three new modules, with the waiver set
#    txfix_lint.sh uses, plus an explicit refusal of LATCH / ALWCOMBORDER /
#    CASEINCOMPLETE
# 3. iverilog + vvp for tb_rx_seq_checker, tb_tgen_v2, tb_cnt_mux32
#
# Every step is scored by its PASS token (vvp always exits 0), the results are
# summarised, and the last line is SEQBIST_UNIT_EXIT=<code> -- printed even
# when a step fails or crashes, so the trailer is always the credit.
# No `set -e`: each step's status is captured explicitly.
set -u
cd "$(dirname "$0")"
HERE="$(pwd)"
RTL=".."
REPO="$HERE/../../.."
LOG="$HERE/run_unit.log"
: > "$LOG"

rc=0
declare -a RESULTS=()

step_fail() { RESULTS+=("FAIL $1"); rc=1; }
step_ok()   { RESULTS+=("ok   $1"); }

say() { echo "$@" | tee -a "$LOG"; }

# ---- 1. vectors ------------------------------------------------------------
say "== gen_frames =="
if python3 "$HERE/gen_frames.py" "$HERE/vec" >>"$LOG" 2>&1; then
  step_ok gen_frames
  grep -h '^GEN_FRAMES_OK' "$LOG" | tail -1
else
  step_fail gen_frames
fi

# ---- 2. lint ---------------------------------------------------------------
say "== lint =="
LINT_FLAGS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-VARHIDDEN -Wno-BLKSEQ -Wno-WIDTHEXPAND"
# BLKSEQ/WIDTHEXPAND are waived because the sources these are derived from
# (rx_seam_checker.v, qpsk_traffic_gen.v) raise exactly the same two classes;
# LATCH/ALWCOMBORDER/CASEINCOMPLETE are refused outright.
if command -v verilator >/dev/null 2>&1; then
  # rx_seq_checker is linted in BOTH parameterisations: WITH_CRC=1 (default,
  # CRC32 datapath present) and WITH_CRC=0 (the compile-time WNS escape hatch).
  for SPEC in "rx_seq_checker|-GWITH_CRC=1|_WCRC1" \
              "rx_seq_checker|-GWITH_CRC=0|_WCRC0" \
              "cnt_mux32||" "qpsk_traffic_gen_v2||"; do
    M="${SPEC%%|*}"; REST="${SPEC#*|}"; GEN="${REST%%|*}"; SFX="${REST#*|}"
    out=$(verilator --lint-only $LINT_FLAGS $GEN --top-module "$M" "$RTL/$M.v" 2>&1)
    st=$?
    bad=$(echo "$out" | grep -E 'LATCH|ALWCOMBORDER|CASEINCOMPLETE')
    echo "$out" >>"$LOG"
    if [ $st -eq 0 ] && [ -z "$bad" ]; then
      say "SEQBIST_LINT_OK_${M}${SFX}"; step_ok "lint:${M}${SFX}"
    else
      say "SEQBIST_LINT_FAIL_${M}${SFX}"; echo "$out" | tail -20 | tee -a "$LOG"
      step_fail "lint:${M}${SFX}"
    fi
  done
else
  say "SEQBIST_LINT_SKIP (no verilator)"; step_fail "lint:missing-verilator"
fi

# ---- 3. sims ---------------------------------------------------------------
IVEXTRA=""
run_tb() {   # <name> <pass-token> <sources...>   (IVEXTRA = extra iverilog flags)
  local name="$1"; shift
  local token="$1"; shift
  say "== $name =="
  if ! iverilog -g2005 $IVEXTRA -o "$HERE/$name.vvp" "$@" >>"$LOG" 2>&1; then
    say "$name: COMPILE FAIL"; tail -20 "$LOG"; step_fail "$name:compile"; return
  fi
  local out
  out=$(cd "$HERE" && timeout 1800 vvp "$HERE/$name.vvp" 2>&1)
  echo "$out" >>"$LOG"
  echo "$out" | grep -E "^(TB_FAIL|TB_PHASE|TB_TGEN|TB_CNT|$token)" | head -40
  if echo "$out" | grep -q "^$token"; then step_ok "$name"; else step_fail "$name"; fi
}

run_tb tb_rx_seq_checker TB_RX_SEQ_CHECKER_PASS \
  "$HERE/tb_rx_seq_checker.v" "$RTL/rx_seq_checker.v"

# the same testbench against the WITH_CRC=0 build: every tgen_mode phase must be
# identical, and phase 4 (tgen_mode=0) must report good=0 crc_fail=0
IVEXTRA="-DNOCRC"
run_tb tb_rx_seq_checker_nocrc TB_RX_SEQ_CHECKER_PASS \
  "$HERE/tb_rx_seq_checker.v" "$RTL/rx_seq_checker.v"
IVEXTRA=""

run_tb tb_tgen_v2 TB_TGEN_V2_PASS \
  "$HERE/tb_tgen_v2.v" "$RTL/qpsk_traffic_gen_v2.v" \
  "$REPO/jupiter_byte_txfixF3_build/qpsk_traffic_gen.v"

run_tb tb_cnt_mux32 TB_CNT_MUX32_PASS \
  "$HERE/tb_cnt_mux32.v" "$RTL/cnt_mux32.v" "$RTL/cnt_mux16.v"

# ---- summary ---------------------------------------------------------------
say "== summary =="
for r in "${RESULTS[@]}"; do say "  $r"; done
say "SEQBIST_UNIT_EXIT=$rc"
exit $rc
