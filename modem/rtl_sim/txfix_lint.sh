#!/bin/bash
# txfix_lint.sh <variant>   (variant = F1|F2|F3, or a full tree name)
#
# Two lint passes over a TXFIX variant tree (plan happy-bubbling-owl.md,
# "Verilator gate (sim lane)"):
#   pass 1  lenient (-Wno-lint) elaboration of the five tops that carry the fix,
#           up to and including the sim top wrap_byte_ddrcap -- proves the patched
#           netlist still elaborates in every context it is instantiated in.
#   pass 2  strict (-Wall) on each of the four touched files, and an explicit
#           refusal of LATCH / ALWCOMBORDER / CASEINCOMPLETE, which are the three
#           classes these netlist patches could plausibly introduce (they add
#           combinational regs and restructure two if-chains).
# Prints TXFIX_LINT_OK_<V>_<TOP> per passing top. Host-only, no board.
set -u
cd "$(dirname "$0")"

V="${1:?usage: txfix_lint.sh F1|F2|F3}"
case "$V" in
  F1|F2|F3) TREE="s1_rtl_txfix_$V" ;;
  *)        TREE="$V" ;;
esac
SRC="$TREE/hdlsrc/commhdlQPSKTxRxLoopback"
[ -d "$SRC" ] || { echo "TXFIX_LINT_FAIL_${V}: no such tree $SRC"; exit 2; }

LENIENT_TOPS="Data_Bits_FIFO Bit_Packetizer QPSK_Tx Transmitter TxRxComposite"
# the four files the injector may touch (F1 touches 1, F2 2, F3 4)
STRICT_FILES="Data_Bits_FIFO RAM_Frame_Status_Indicator Bit_Packetizer MATLAB_Function1"

rc=0

# ---- pass 1: lenient elaboration -------------------------------------------
for TOP in $LENIENT_TOPS; do
  out=$(verilator --lint-only -Wno-fatal -Wno-lint --top-module "$TOP" \
          -y "$SRC" -y . "$SRC/$TOP.v" 2>&1)
  if [ $? -eq 0 ]; then
    echo "TXFIX_LINT_OK_${V}_${TOP}"
  else
    echo "TXFIX_LINT_FAIL_${V}_${TOP}"; echo "$out" | tail -30; rc=1
  fi
done

# the sim top lives in rtl_sim/, not in the netlist dir
out=$(verilator --lint-only -Wno-fatal -Wno-lint --top-module wrap_byte_ddrcap \
        -y "$SRC" -y . wrap_byte_ddrcap.v 2>&1)
if [ $? -eq 0 ]; then
  echo "TXFIX_LINT_OK_${V}_wrap_byte_ddrcap"
else
  echo "TXFIX_LINT_FAIL_${V}_wrap_byte_ddrcap"; echo "$out" | tail -30; rc=1
fi

# ---- pass 2: strict on the touched files -----------------------------------
for F in $STRICT_FILES; do
  out=$(verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
          -Wno-UNUSEDPARAM -Wno-VARHIDDEN --top-module "$F" \
          -y "$SRC" "$SRC/$F.v" 2>&1)
  st=$?
  bad=$(echo "$out" | grep -E 'LATCH|ALWCOMBORDER|CASEINCOMPLETE' || true)
  if [ $st -eq 0 ] && [ -z "$bad" ]; then
    echo "TXFIX_LINT_OK_${V}_STRICT_${F}"
  else
    echo "TXFIX_LINT_FAIL_${V}_STRICT_${F}"; echo "$out" | tail -30; rc=1
  fi
done

if [ $rc -eq 0 ]; then echo "TXFIX_LINT_OK_${V}"; else echo "TXFIX_LINT_FAIL_${V}"; fi
exit $rc
