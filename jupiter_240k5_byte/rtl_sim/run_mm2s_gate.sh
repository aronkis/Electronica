#!/bin/bash
# run_mm2s_gate.sh -- ADVERSARIAL MM2S/S2MM netlist byte gate (TXMUX 2026-07-25).
# Drives the realized TxRxComposite netlist with real-DMA behaviors the S1B
# gate abstracts away: per-transfer tlast/byte_first, host zero-padded
# transfers, mid-frame arm, inter-transfer gaps, tvalid duty, RX-ready
# per-descriptor gaps. DISTINCT per-frame tagged words make any word-phase
# offset, replay, drop or duplication directly visible; ALL packets are
# scored INCLUDING frame 1 (closes the S1B frame-1-blind follow-up).
# Usage: run_mm2s_gate.sh <netlist_dir> [frame_clks]
#   f1536: NTW=385 NDW=191 frame=197328 clks (sps8)
set -e -o pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
VD=${1:?netlist dir}
FR=${2:-197328}
NTW=385; NDW=191
cd "$KIT"
test -f "$VD/TxRxComposite.v"

# --- SKID lag contract assertion: the generated delayMatch chain depth on the
# byte_ready pin must equal qpskByteSkidLag() (the constant baked into
# qpskByteWordBufferSkid's push gate). See qpskByteSkidLag.m.
LAG=$(grep -oP 'lag = \K[0-9]+' "$KIT/../qpskByteSkidLag.m")
SIG=$(grep -oP 'assign ReadyDly_out1_1 = \KdelayMatch[0-9]+' "$VD/TxRxComposite.v" | head -1)
if [ -z "$SIG" ]; then
  # no delayMatch chain: pin lag would be 0 -- only correct if LAG=0
  echo "SKID_LAG_GATE: no delayMatch on byte_ready (depth 0), pinned LAG=$LAG"
  [ "$LAG" = "0" ] || { echo "SKID_LAG_GATE FAIL: netlist depth 0 != pinned $LAG"; exit 1; }
else
  DEPTH=$(grep -oP "reg  \[\K[0-9]+(?=:0\] ${SIG}_reg)" "$VD/TxRxComposite.v" | head -1)
  DEPTH=$((DEPTH+1))
  echo "SKID_LAG_GATE: netlist byte_ready delayMatch depth=$DEPTH, pinned LAG=$LAG"
  [ "$DEPTH" = "$LAG" ] || { echo "SKID_LAG_GATE FAIL: netlist depth $DEPTH != pinned $LAG -- update qpskByteSkidLag.m and re-run makehdl"; exit 1; }
fi
rm -rf obj_mm2s_gate
verilator -O2 -Wno-fatal --cc wrap_byte.v -y "$VD" --exe sim_byte_mm2s.cpp \
  -Mdir obj_mm2s_gate --top-module wrap_byte
PATH=/usr/bin:$PATH make -s -C obj_mm2s_gate -f Vwrap_byte.mk Vwrap_byte
CLKS=$((100 + 12*FR))
echo "=== run A: back-to-back (baseline) ==="
./obj_mm2s_gate/Vwrap_byte $NTW $NDW $CLKS 0 0 1 1 g_mm2s_A
python3 score_mm2s.py g_mm2s_A_rxw.txt $NDW --gate
echo "=== run B: mid-frame arm (the silicon qpsk_tun arm case) ==="
./obj_mm2s_gate/Vwrap_byte $NTW $NDW $CLKS 90000 0 1 1 g_mm2s_B
python3 score_mm2s.py g_mm2s_B_rxw.txt $NDW --gate
echo "=== run C: inter-transfer gaps (keepalive jitter) ==="
./obj_mm2s_gate/Vwrap_byte $NTW $NDW $CLKS 0 30000 1 1 g_mm2s_C
python3 score_mm2s.py g_mm2s_C_rxw.txt $NDW --gate --allow-zero-pkts
echo "=== run E: RX-ready per-descriptor gaps (S2MM prime cadence) ==="
./obj_mm2s_gate/Vwrap_byte $NTW $NDW $CLKS 0 0 1 1 g_mm2s_E 191 25
python3 score_mm2s.py g_mm2s_E_rxw.txt $NDW --gate
echo "MM2S_GATE_ALL PASS"
