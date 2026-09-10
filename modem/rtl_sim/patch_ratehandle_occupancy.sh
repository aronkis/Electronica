#!/bin/bash
# patch_ratehandle_occupancy.sh -- MODEL-6c CANDIDATE FIX (variant a, occupancy-
# based pop): eliminate the free-running pop/push relative phase in Rate_Handle
# by replacing the blind mod-4 pacer pop gate with an occupancy gate:
#
#     pop = validIn & FIFO notEmpty      (was: validIn & (HDL_Counter == 0))
#
# WHY THIS REMOVES THE MODEL-6 HOLDING STATE: with pop-on-non-empty, every
# pushed symbol is popped within one validIn beat of its push -- the pop train
# is SLAVED to the Gardner push strobe. There is no free-running pop phase to
# slip: the Model-6 "pop-early" phase advance becomes structurally impossible
# (the pacer counter still exists but is disconnected from the pop path), and a
# pop-pointer step changes occupancy, which the gate re-equalizes immediately.
# The FIFO's own Validate_Input_Push_Pop pop-on-empty guard stays in place as a
# second rail.
#
# 2-file minimal documented post-generation patch, emitted as a COPY
# (never edits s1_rtl in place):
#   FIFO_block.v   + output notEmpty = (Push_Counter_out1 != Pop_Counter_out1)
#   Rate_Handle.v  pop gate switched to validIn & notEmpty (pacer left in place,
#                  disconnected from the pop path)
#
# Usage: patch_ratehandle_occupancy.sh [src_netlist_dir] [dst_netlist_dir] [--also-serializer]
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
SRC=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
DST=${2:-$R/s1_rtl_rhfix2/hdlsrc/commhdlQPSKTxRxLoopback}
ALSO_SER=0; [ "${3:-}" = "--also-serializer" ] && ALSO_SER=1
[ -f "$SRC/Rate_Handle.v" ] || { echo "FATAL: no netlist at $SRC" >&2; exit 1; }
ROOT=$(dirname "$(dirname "$DST")")
rm -rf "$ROOT"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

python3 - "$DST" <<'PY'
import sys
dst=sys.argv[1]

# ---- FIFO_block.v : export notEmpty ----
p=dst+'/FIFO_block.v'
s=open(p).read()
assert 'notEmpty' not in s, 'already patched'
s=s.replace("           out_re,\n           out_im,\n           validPop);",
            "           out_re,\n           out_im,\n           validPop,\n           notEmpty);",1)
s=s.replace("  output  validPop;\n",
            "  output  validPop;\n  output  notEmpty;  // FIX(M6c): occupancy flag for the pop gate\n",1)
s=s.replace("endmodule  // FIFO_block",
            "  // FIX(M6c): non-empty = pointers differ (5-bit counters, depth 32,\n"
            "  // occupancy stays far below full in this design; Validate block still\n"
            "  // guards push-on-full/pop-on-empty as before)\n"
            "  assign notEmpty = Push_Counter_out1 != Pop_Counter_out1;\n"
            "\n"
            "endmodule  // FIFO_block",1)
open(p,'w').write(s)

# ---- Rate_Handle.v : occupancy pop gate ----
p=dst+'/Rate_Handle.v'
s=open(p).read()
assert 'notEmpty' not in s, 'already patched'
s=s.replace("  wire FIFO_validPop;\n",
            "  wire FIFO_validPop;\n  wire FIFO_notEmpty;  // FIX(M6c)\n",1)
old="  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;"
new=("  // FIX(M6c): pop gate = occupancy (slaved to the push strobe), NOT the\n"
     "  // free-running mod-4 pacer. The pacer counter above is left in place but\n"
     "  // no longer participates in the pop decision -- its phase is structurally\n"
     "  // irrelevant, which removes the Model-6 holding state.\n"
     "  assign Logical_Operator_out1 = validIn & FIFO_notEmpty;")
assert old in s, 'pop gate pattern not found'
s=s.replace(old,new,1)
s=s.replace("                     .out_im(FIFO_out_im),  // sfix16_En14\n"
            "                     .validPop(FIFO_validPop)\n"
            "                     );",
            "                     .out_im(FIFO_out_im),  // sfix16_En14\n"
            "                     .validPop(FIFO_validPop),\n"
            "                     .notEmpty(FIFO_notEmpty)  // FIX(M6c)\n"
            "                     );",1)
open(p,'w').write(s)
print('PATCHED (occupancy pop gate)', dst)
PY

if [ "$ALSO_SER" = "1" ]; then
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
