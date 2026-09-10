#!/bin/bash
# patch_serializer_anchor.sh -- CANDIDATE FIX for the enable-phase-swap RX burst
# fault (MODEL1_ENABLE_INJECT.md, tag archive/pre-cleanup-2026-09-09). Produces
# a PATCHED COPY of the flashed
# netlist (never edits s1_rtl in place) in which the QPSK-demapper Serializer's
# coded-bit phase counter (HDL_Counter_out1) is RE-ANCHORED to the per-frame
# start each frame, so a phase glitch self-heals within one frame instead of
# holding for the whole burst.
#
# Minimal, documented, post-HDL-Coder-generation RTL edit (2 files):
#   Serializer.v          : + startAnchor input; force HDL_Counter_out1<=0 when it pulses
#   QPSK_Demodulator.v    : wire Delay6_out1 (startIn aligned to In2) -> .startAnchor()
#
# Usage: patch_serializer_anchor.sh [src_netlist_dir] [dst_netlist_dir]
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
SRC=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
DST=${2:-$R/s1_rtl_fix/hdlsrc/commhdlQPSKTxRxLoopback}
[ -f "$SRC/Serializer.v" ] || { echo "FATAL: no netlist at $SRC" >&2; exit 1; }
rm -rf "$(dirname "$(dirname "$DST")")"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

python3 - "$DST" <<'PY'
import sys,io,re
dst=sys.argv[1]

# ---- Serializer.v ----
p=dst+'/Serializer.v'
s=open(p).read()
assert 'startAnchor' not in s, 'already patched'
# add to port list: after "enb_1_2_0," in the module port list
s=s.replace("           enb_1_2_0,\n           u_0,",
            "           enb_1_2_0,\n           startAnchor,\n           u_0,",1)
# add input decl after "input   enb_1_2_0;"
s=s.replace("  input   enb_1_2_0;\n",
            "  input   enb_1_2_0;\n  input   startAnchor;  // FIX: per-frame coded-bit phase re-anchor\n",1)
# re-anchor counter: force to count_from(0) on frame start
old=("        if (enb_1_2_0) begin\n"
     "          HDL_Counter_out1 <= count_1;\n"
     "        end")
new=("        if (enb_1_2_0) begin\n"
     "          if (startAnchor)\n"
     "            HDL_Counter_out1 <= 1'b0;  // FIX: re-sync serialize phase every frame\n"
     "          else\n"
     "            HDL_Counter_out1 <= count_1;\n"
     "        end")
assert old in s, 'HDL_Counter_process anchor pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)

# ---- QPSK_Demodulator.v ----
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
assert old in s, 'Serializer instantiation pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)
print('PATCHED', dst)
PY
echo "PATCH_DONE $DST"
