#!/bin/bash
# patch_ratehandle_pushslave.sh -- MODEL-6c CANDIDATE FIX (variant b, push-slaved
# pacer): eliminate the free-running pop/push relative phase in Rate_Handle by
# DISCIPLINING the existing mod-4 pop pacer to the Gardner push strobe:
#
#   - warmup: count pushes; after PUSH_WARMUP (49152 ~ well past lock at ~300k
#     clk in this design) LATCH the pacer's in-flight next-value (count_1) at a
#     push beat as pushRef -- the NOMINAL pacer-phase-at-push.
#   - discipline: at every later push beat, if count_1 != pushRef, FORCE the
#     pacer to pushRef.
#
# WHY THIS ANCHOR SURVIVES THE 6b LESSON: the 6b frame-start anchor failed
# because the frame marker travels WITH the popped data, so a pacer slip moves
# the marker and the reference is slip-invariant. The PUSH strobe comes from the
# Gardner/interpolation side -- UPSTREAM of the pacer -- and does not move when
# the pacer slips: a slipped pacer phase IS visible as count_1 != pushRef at the
# next push and is restored within one symbol period.
#
# WHY PHASE-PRESERVING (the 6c-variant-(a) lesson): the occupancy-gate variant
# broke nominal lock by MOVING the pop beat phase (clean run settled in the
# AB7A4307 phase class) -- the pop BEAT phase is functionally consumed
# downstream. This variant does not alter nominal pop timing at all: in lock,
# count_1 == pushRef at every push and the discipline is a no-op (gate 1 checks
# bit-identity).
#
# KNOWN LIMITATION (stated for the record): on hardware, a LEGITIMATE Gardner
# timing slew (clock-offset catch-up) changes the pacer-phase-at-push; this
# discipline would restore the OLD phase once per slew. In the ROM-loopback sim
# there are no post-lock slews. If the hardware fault IS such a slew interacting
# with beat-locked downstream processing, this fix pins the phase to the
# post-acquisition value -- which is the intended corrective behavior -- but
# hardware validation must watch for interaction with real timing drift.
#
# 1-file minimal documented post-generation patch, emitted as a COPY:
#   Rate_Handle.v  + pushRef/pushRefHave/warmup regs + discipline in the
#                    HDL_Counter process (pop gate UNCHANGED)
#
# Usage: patch_ratehandle_pushslave.sh [src_netlist_dir] [dst_netlist_dir]
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
SRC=${1:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
DST=${2:-$R/s1_rtl_rhfix3/hdlsrc/commhdlQPSKTxRxLoopback}
[ -f "$SRC/Rate_Handle.v" ] || { echo "FATAL: no netlist at $SRC" >&2; exit 1; }
ROOT=$(dirname "$(dirname "$DST")")
rm -rf "$ROOT"
mkdir -p "$DST"
cp -a "$SRC/." "$DST/"

python3 - "$DST" <<'PY'
import sys
dst=sys.argv[1]
p=dst+'/Rate_Handle.v'
s=open(p).read()
assert 'pushRef' not in s, 'already patched'
s=s.replace("  wire FIFO_validPop;\n",
            "  wire FIFO_validPop;\n"
            "  reg  [1:0] pushRef;      // FIX(M6c-b): nominal pacer phase at push\n"
            "  reg  pushRefHave;        // FIX(M6c-b): pushRef valid\n"
            "  reg  [15:0] pushWarmup;  // FIX(M6c-b): pushes seen since reset\n",1)
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
new=("  // FIX(M6c-b): push-slaved pacer discipline. After warmup, the pacer's\n"
     "  // next-value at each push beat must equal the latched nominal (pushRef);\n"
     "  // a mismatch (= a pacer phase slip -- the Model-6 holding state) is\n"
     "  // restored on the spot. No-op in nominal lock.\n"
     "  localparam [15:0] PUSH_WARMUP = 16'd49152;\n"
     "  always @(posedge clk or posedge reset)\n"
     "    begin : push_ref_process\n"
     "      if (reset == 1'b1) begin\n"
     "        pushRef <= 2'b00;\n"
     "        pushRefHave <= 1'b0;\n"
     "        pushWarmup <= 16'd0;\n"
     "      end\n"
     "      else begin\n"
     "        if (enb_1_2_0 && strobe) begin\n"
     "          if (pushWarmup < PUSH_WARMUP) begin\n"
     "            pushWarmup <= pushWarmup + 16'd1;\n"
     "          end\n"
     "          else if (~pushRefHave) begin\n"
     "            pushRef <= count_1;\n"
     "            pushRefHave <= 1'b1;\n"
     "          end\n"
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
     "          if (strobe && pushRefHave && (count_1 != pushRef))\n"
     "            HDL_Counter_out1 <= pushRef;  // FIX(M6c-b): restore nominal phase\n"
     "          else\n"
     "            HDL_Counter_out1 <= count_1;\n"
     "        end\n"
     "      end\n"
     "    end")
assert old in s, 'HDL_Counter_process pattern not found'
s=s.replace(old,new,1)
open(p,'w').write(s)
print('PATCHED (push-slaved pacer)', dst)
PY
echo "PATCH_DONE $DST"
