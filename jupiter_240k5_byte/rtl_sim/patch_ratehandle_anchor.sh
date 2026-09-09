#!/bin/bash
# patch_ratehandle_anchor.sh -- MODEL-6b CANDIDATE FIX: per-frame re-anchor of the
# Rate_Handle mod-4 pop pacer (the Model-6 holding element) so a slipped
# pop-cadence phase self-corrects at the next frame start instead of holding.
#
# ANCHOR SIGNAL: Packet_Controller_startOut in Frequency_and_Time_Synchronizer
# (F&TS line 103/196) -- the SAME per-frame start marker that becomes the
# demapper startIn and re-arms FecCapture. Chosen because (a) it is the frame
# reference the caps are measured against, (b) it pulses once per frame on the
# same enb_1_2_0 rail, (c) its beat-position relative to the pop pacer is
# constant in nominal lock (the marker travels with data popped by the pacer).
#
# SCHEME (self-calibrating, does NOT assume the nominal phase value): on the
# FIRST anchor pulse after reset, LATCH the pacer's in-flight next-value
# (count_1) as anchor_ref; on every LATER anchor pulse, FORCE the counter to
# anchor_ref. Nominal lock: count_1 == anchor_ref at the anchor beat -> forcing
# is a no-op (gate 2 verifies bit-identity). Slipped phase: restored <=1 frame.
#
# 3-file minimal documented post-generation patch, emitted as a COPY
# (never edits s1_rtl in place):
#   Rate_Handle.v                       + startAnchor port, ref latch, restore
#   Symbol_Synchronizer.v               + startAnchor port -> u_Rate_Handle
#   Frequency_and_Time_Synchronizer.v   wire Packet_Controller_startOut in
#
# Usage: patch_ratehandle_anchor.sh [src_netlist_dir] [dst_netlist_dir] [--also-serializer]
#   --also-serializer : additionally apply the Model-1 serializer anchor patch
#                       (patch_serializer_anchor.sh edits) to the SAME copy.
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
SRC=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
DST=${2:-$R/s1_rtl_rhfix/hdlsrc/commhdlQPSKTxRxLoopback}
ALSO_SER=0; [ "${3:-}" = "--also-serializer" ] && ALSO_SER=1
[ -f "$SRC/Rate_Handle.v" ] || { echo "FATAL: no netlist at $SRC" >&2; exit 1; }
ROOT=$(dirname "$(dirname "$DST")")
rm -rf "$ROOT"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

python3 - "$DST" <<'PY'
import sys
dst=sys.argv[1]

# ---- Rate_Handle.v ----
p=dst+'/Rate_Handle.v'
s=open(p).read()
assert 'startAnchor' not in s, 'already patched'
s=s.replace("           enb_1_2_0,\n           dataIn_re,",
            "           enb_1_2_0,\n           startAnchor,\n           dataIn_re,",1)
s=s.replace("  input   enb_1_2_0;\n",
            "  input   enb_1_2_0;\n"
            "  input   startAnchor;  // FIX(M6b): per-frame pop-phase re-anchor strobe\n",1)
s=s.replace("  wire signed [15:0] FIFO_out_re;",
            "  reg  [1:0] anchor_ref;   // FIX(M6b): nominal pacer phase at frame start\n"
            "  reg  anchor_have;        // FIX(M6b): anchor_ref valid\n"
            "  wire signed [15:0] FIFO_out_re;",1)
old=("  always @(posedge clk or posedge reset)\n"
     "    begin : HDL_Counter_process\n"
     "      if (reset == 1'b1) begin\n"
     "        HDL_Counter_out1 <= 2'b00;\n"
     "      end\n"
     "      else begin\n"
     "        if (enb_1_2_0) begin\n"
     "          HDL_Counter_out1 <= count_1;\n"
     "        end\n"
     "      end\n"
     "    end")
new=("  // FIX(M6b): self-calibrating per-frame re-anchor -- first frame start\n"
     "  // latches the nominal phase (count_1), later frame starts restore it.\n"
     "  always @(posedge clk or posedge reset)\n"
     "    begin : anchor_ref_process\n"
     "      if (reset == 1'b1) begin\n"
     "        anchor_ref <= 2'b00;\n"
     "        anchor_have <= 1'b0;\n"
     "      end\n"
     "      else begin\n"
     "        if (enb_1_2_0 && startAnchor && (~anchor_have)) begin\n"
     "          anchor_ref <= count_1;\n"
     "          anchor_have <= 1'b1;\n"
     "        end\n"
     "      end\n"
     "    end\n"
     "\n"
     "  always @(posedge clk or posedge reset)\n"
     "    begin : HDL_Counter_process\n"
     "      if (reset == 1'b1) begin\n"
     "        HDL_Counter_out1 <= 2'b00;\n"
     "      end\n"
     "      else begin\n"
     "        if (enb_1_2_0) begin\n"
     "          if (startAnchor && anchor_have)\n"
     "            HDL_Counter_out1 <= anchor_ref;  // FIX(M6b): restore nominal phase\n"
     "          else\n"
     "            HDL_Counter_out1 <= count_1;\n"
     "        end\n"
     "      end\n"
     "    end")
assert old in s, 'Rate_Handle HDL_Counter_process pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)

# ---- Symbol_Synchronizer.v ----
p=dst+'/Symbol_Synchronizer.v'
s=open(p).read()
assert 'startAnchor' not in s, 'already patched'
s=s.replace("           enb_1_2_0,\n           dataIn_re,",
            "           enb_1_2_0,\n           startAnchor,\n           dataIn_re,",1)
s=s.replace("  input   enb_1_2_0;\n",
            "  input   enb_1_2_0;\n  input   startAnchor;  // FIX(M6b): pass-through to Rate_Handle\n",1)
s=s.replace("  Rate_Handle u_Rate_Handle (.clk(clk),\n"
            "                             .reset(reset),\n"
            "                             .enb_1_2_0(enb_1_2_0),",
            "  Rate_Handle u_Rate_Handle (.clk(clk),\n"
            "                             .reset(reset),\n"
            "                             .enb_1_2_0(enb_1_2_0),\n"
            "                             .startAnchor(startAnchor),  // FIX(M6b)",1)
open(p,'w').write(s)

# ---- Frequency_and_Time_Synchronizer.v ----
p=dst+'/Frequency_and_Time_Synchronizer.v'
s=open(p).read()
old=("  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n")
assert old in s, 'F&TS Symbol_Synchronizer inst not found'
# add the port right after .clk(clk), line; find the reset line of that inst
idx=s.index(old)
ins=s.index(".reset(reset),",idx)
eol=s.index("\n",ins)+1
s=s[:eol]+ "                                             .startAnchor(Packet_Controller_startOut),  // FIX(M6b)\n" +s[eol:]
open(p,'w').write(s)
print('PATCHED (ratehandle anchor)', dst)
PY

if [ "$ALSO_SER" = "1" ]; then
  # apply the Model-1 serializer anchor edits to the same copy
  python3 - "$DST" <<'PY'
import sys
dst=sys.argv[1]
p=dst+'/Serializer.v'
s=open(p).read()
assert 'startAnchor' not in s, 'serializer already patched'
s=s.replace("           enb_1_2_0,\n           u_0,",
            "           enb_1_2_0,\n           startAnchor,\n           u_0,",1)
s=s.replace("  input   enb_1_2_0;\n",
            "  input   enb_1_2_0;\n  input   startAnchor;  // FIX: per-frame coded-bit phase re-anchor\n",1)
old=("        if (enb_1_2_0) begin\n"
     "          HDL_Counter_out1 <= count_1;\n"
     "        end")
new=("        if (enb_1_2_0) begin\n"
     "          if (startAnchor)\n"
     "            HDL_Counter_out1 <= 1'b0;  // FIX: re-sync serialize phase every frame\n"
     "          else\n"
     "            HDL_Counter_out1 <= count_1;\n"
     "        end")
assert old in s, 'Serializer anchor pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)
p=dst+'/QPSK_Demodulator.v'
s=open(p).read()
old=("  Serializer u_Serializer (.clk(clk),\n"
     "                           .reset(reset),\n"
     "                           .enb_1_2_0(enb_1_2_0),\n"
     "                           .u_0(Delay12_out1[0]),  // boolean")
new=("  Serializer u_Serializer (.clk(clk),\n"
     "                           .reset(reset),\n"
     "                           .enb_1_2_0(enb_1_2_0),\n"
     "                           .startAnchor(Delay6_out1),  // FIX: startIn aligned to In2\n"
     "                           .u_0(Delay12_out1[0]),  // boolean")
assert old in s, 'Serializer inst pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)
print('PATCHED (serializer anchor too)', dst)
PY
fi
echo "PATCH_DONE $DST"
