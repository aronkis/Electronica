#!/bin/bash
# patch_phase_contract.sh -- MODEL-7: explicit downstream phase contract
# (two_jup/BEATFIX_DESIGN.md PRIMARY), adapted to this netlist generation.
#
# DEVIATION FROM THE DESIGN DOC (documented): in this netlist the frame decision
# (Packet_Controller startOut) exists DOWNSTREAM of Rate_Handle -- the chain is
# SymSync(RateHandle) -> CFC -> CS -> PreambleDet -> PhaseAmbig -> PacketCtrl ->
# Demod -> FEC. The tag therefore attaches at the EARLIEST point the frame
# decision exists: the Frequency_and_Time_Synchronizer output inside QPSK_Rx
# (symbol stream + startOut), upstream of the demapper serialization boundary
# and of the marker/data parallel transport into the FEC -- the boundary the
# silicon capture implicates. No FIFO widening is needed here because the
# Rate_Handle FIFO is upstream of the frame decision in this generation; the
# transport is a 4-stage tag pipeline matched to the demapper's start pipeline.
#
# Contract logic added to QPSK_Rx.v:
#   producer  : pcTag (13b symbol-index-in-frame, wrap 6159, re-zeroed by startOut)
#   transport : pcTagD1..D4 (enb-gated, matches demod Delay2->6->4->10 latency)
#   consumer  : pcFirstBit = demod validOut rising; pc_start_derived =
#               pcFirstBit & (pcTagD4==0); continuity check +1 mod 6160 with
#               pc_violations counter + pc_delta latch (testbench-visible).
# Stage A (default): checker + derived start EXPOSED but consumers UNCHANGED
#   (alignment verification; nominal untouched by construction).
# Stage B (--consume): FEC_Decoder_Wrapper and FecCaptureCadence .startIn()
#   switched from QPSK_Demodulator_startOut to pc_start_derived.
#
# Usage: patch_phase_contract.sh [src_netlist_dir] [dst_netlist_dir] [--consume]
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
SRC=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
DST=${2:-$R/s1_rtl_pcfix/hdlsrc/commhdlQPSKTxRxLoopback}
CONSUME=0; [ "${3:-}" = "--consume" ] && CONSUME=1
[ -f "$SRC/QPSK_Rx.v" ] || { echo "FATAL: no netlist at $SRC" >&2; exit 1; }
ROOT=$(dirname "$(dirname "$DST")")
rm -rf "$ROOT"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

python3 - "$DST" "$CONSUME" <<'PY'
import sys
dst=sys.argv[1]; consume=int(sys.argv[2])
p=dst+'/QPSK_Rx.v'
s=open(p).read()
assert 'pcTag' not in s, 'already patched'

logic = """
  // ---- FIX(M7): explicit downstream phase contract ----------------------
  // pcTagHold: BIT index in frame of the symbol in flight. The F&TS validOut
  // is TWO beats wide per symbol (measured), so this counter advances twice
  // per symbol = once per coded bit -> wrap at 12319 (12320 bits/frame),
  // re-zeroed by startOut. The demod validOut pulses once per BIT (measured:
  // +1 tag per validOut rising), so the consumer checks +1 continuity per
  // bit instant; tag==0 = frame-head bit. Free wrap keeps framing if the
  // marker vanishes.
  reg  [13:0] pcTagHold;
  reg  [13:0] pcTagD1;      // transport: 2-beat pipe lands the read mid-window
  reg  [13:0] pcTagD2;
  reg  [13:0] pcTagPrev;
  reg  pcValidPrev;
  reg  [31:0] pc_violations;
  reg  signed [15:0] pc_delta;
  wire pcFirstBit;
  wire [13:0] pcExpect;
  wire pc_start_derived;

  always @(posedge clk or posedge reset)
    begin : pc_tag_process
      if (reset == 1'b1) begin
        pcTagHold <= 14'd12319;
      end
      else begin
        if (enb_1_2_0 && QPSKConstellationValid) begin
          pcTagHold <= Frequency_and_Time_Synchronizer_startOut ? 14'd0 :
                       (pcTagHold == 14'd12319 ? 14'd0 : pcTagHold + 14'd1);
        end
      end
    end

  always @(posedge clk or posedge reset)
    begin : pc_transport_process
      if (reset == 1'b1) begin
        pcTagD1 <= 14'd12319; pcTagD2 <= 14'd12319;
      end
      else begin
        if (enb_1_2_0) begin
          pcTagD1 <= pcTagHold;
          pcTagD2 <= pcTagD1;
        end
      end
    end

  assign pcFirstBit = QPSK_Demodulator_validOut & (~pcValidPrev);
  assign pcExpect = (pcTagPrev == 14'd12319) ? 14'd0 : (pcTagPrev + 14'd1);
  assign pc_start_derived = pcFirstBit & (pcTagD2 == 14'd0);

  always @(posedge clk or posedge reset)
    begin : pc_check_process
      if (reset == 1'b1) begin
        pcValidPrev <= 1'b0;
        pcTagPrev <= 14'd12319;
        pc_violations <= 32'd0;
        pc_delta <= 16'sd0;
      end
      else begin
        if (enb_1_2_0) begin
          pcValidPrev <= QPSK_Demodulator_validOut;
          if (pcFirstBit) begin
            if (pcTagD2 != pcExpect) begin
              pc_violations <= pc_violations + 32'd1;
              pc_delta <= $signed({2'b00, pcTagD2}) - $signed({2'b00, pcExpect});
            end
            pcTagPrev <= pcTagD2;
          end
        end
      end
    end
  // ---- end FIX(M7) ------------------------------------------------------

"""
anchor="  FEC_Decoder_Wrapper u_FEC_Decoder_Wrapper (.clk(clk),"
assert anchor in s
s=s.replace(anchor, logic+anchor,1)
if consume:
    n=s.count(".startIn(QPSK_Demodulator_startOut),")
    assert n>=2, f'expected >=2 consumers, found {n}'
    s=s.replace(".startIn(QPSK_Demodulator_startOut),",
                ".startIn(pc_start_derived),  // FIX(M7): tag-derived framing")
open(p,'w').write(s)
print(f'PATCHED phase contract (consume={consume})', p)
PY
echo "PATCH_DONE $DST (consume=$CONSUME)"
