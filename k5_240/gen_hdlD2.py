#!/usr/bin/env python3
"""Generate hdlD2 = patch D retarget (newPk-armed deint skip) from the hdlD (v1) tree.

Design (proven timing model, matches v1's empirical one-window-late result):
- Arm at newPk time in Timing_Adjust: p2e_d = (psTref - accOff) mod 1133 == 32.
  The arm always lands between deint startIn(stale-1) and startIn(stale) because
  the arm trails the stale TA fire by only 32 symbols while the PD FIFO transit
  (4532 clk = 283 sym in sim, ~53 sym live) + demod latency separates fire from
  startIn.  Invariant holds in both clock domains.
- Freshest-newPk-wins cancel: a later newPk with d != 32 clears the pend.
- Report-time backstop: timingOffsetValid with report delta != 32 clears too
  (set/clr collision resolves to clear = safe no-skip default).
- Consume: v1's proven RxDeint mechanism (skip 64 head write bits at startIn).
"""
import shutil, sys

BASE = '/dev/shm/hdlproto'
shutil.rmtree(f'{BASE}/hdlD2', ignore_errors=True)
shutil.copytree(f'{BASE}/hdlD', f'{BASE}/hdlD2')
B = f'{BASE}/hdlD2/commhdlQPSKTxRxLoopback'

def rep(s, old, new, n=1):
    assert s.count(old) == n, f'pattern x{s.count(old)} (want {n}): {old[:70]!r}'
    return s.replace(old, new)

# ---- 1. Timing_Adjust: newPk-time arm + cancel/backstop ----
p = f'{B}/Timing_Adjust.v'
s = open(p).read()
s = rep(s, "           p1c_accoff,\n           p1e_dispp);",
           "           p1c_accoff,\n           psTref,\n           psNewpk,\n           p1e_set,\n           p1e_clr);")
s = rep(s, "  output  p1e_dispp;",
           "  input   [10:0] psTref;  // ufix11\n  input   psNewpk;\n  output  p1e_set;\n  output  p1e_clr;")
s = rep(s, "  wire [11:0] p1e_d;\n  reg  p1e_dispp_r;",
           "  wire [11:0] p1e_d;\n  wire [11:0] p2e_d;\n  reg  p1e_set_r;\n  reg  p1e_clr_r;\n  reg [31:0] p1e_cyc;")
old_tail = """  always @(posedge clk or posedge reset)
    begin : p1e_dispp_process
      if (reset == 1'b1) begin
        p1e_dispp_r <= 1'b0;
      end
      else begin
        if (enb_1_2_0) begin
          p1e_dispp_r <= timingOffsetValid & (p1e_d == 12'd32);
        end
      end
    end

  assign p1e_dispp = p1e_dispp_r;"""
new_tail = """  assign p2e_d = (psTref >= Unit_Delay_Enabled_Synchronous3_out1) ?
                 {1'b0, psTref} - {1'b0, Unit_Delay_Enabled_Synchronous3_out1} :
                 ({1'b0, psTref} + 12'd1133) - {1'b0, Unit_Delay_Enabled_Synchronous3_out1};

  always @(posedge clk or posedge reset)
    begin : p1e_arm_process
      if (reset == 1'b1) begin
        p1e_set_r <= 1'b0;
        p1e_clr_r <= 1'b0;
        p1e_cyc <= 32'd0;
      end
      else begin
        if (enb_1_2_0) begin
          p1e_set_r <= psNewpk & (p2e_d == 12'd32);
          p1e_clr_r <= (psNewpk & (p2e_d != 12'd32)) | (timingOffsetValid & (p1e_d != 12'd32));
          p1e_cyc <= p1e_cyc + 32'd1;
          // synthesis translate_off
          if (psNewpk & (p2e_d == 12'd32)) begin
            $display("P1E_SET cyc=%0d tref=%0d acc=%0d", p1e_cyc, psTref, Unit_Delay_Enabled_Synchronous3_out1);
          end
          if (timingOffsetValid & (p1e_d == 12'd32)) begin
            $display("P1E_REP32 cyc=%0d off=%0d acc=%0d", p1e_cyc, timingOffset, Unit_Delay_Enabled_Synchronous3_out1);
          end
          // synthesis translate_on
        end
      end
    end

  assign p1e_set = p1e_set_r;
  assign p1e_clr = p1e_clr_r;"""
s = rep(s, old_tail, new_tail)
open(p, 'w').write(s)

# ---- 2. Preamble_Detector: feed PS tref/newpk into TA, route set/clr out ----
p = f'{B}/Preamble_Detector.v'
s = open(p).read()
s = rep(s, "           p1c_telQ,\n           p1e_dispp);",
           "           p1c_telQ,\n           p1e_set,\n           p1e_clr);")
s = rep(s, "  output  p1e_dispp;", "  output  p1e_set;\n  output  p1e_clr;")
s = rep(s, "                                 .p1e_dispp(p1e_dispp)\n",
           "                                 .psTref(Peak_Search_p1c_tref),  // ufix11\n"
           "                                 .psNewpk(Peak_Search_p1c_newpk),\n"
           "                                 .p1e_set(p1e_set),\n"
           "                                 .p1e_clr(p1e_clr)\n")
open(p, 'w').write(s)

# ---- 3. Frequency_and_Time_Synchronizer: route two wires ----
p = f'{B}/Frequency_and_Time_Synchronizer.v'
s = open(p).read()
s = rep(s, "           p1e_dispp,\n", "           p1e_set,\n           p1e_clr,\n")
s = rep(s, "  output  p1e_dispp;", "  output  p1e_set;\n  output  p1e_clr;")
s = rep(s, ".p1e_dispp(p1e_dispp),\n",
           ".p1e_set(p1e_set),\n" + " " * 41 + ".p1e_clr(p1e_clr),\n")
open(p, 'w').write(s)

# ---- 4. QPSK_Rx: two wires FTS -> FEC wrapper ----
p = f'{B}/QPSK_Rx.v'
s = open(p).read()
s = rep(s, "  wire p1e_dispp_w;", "  wire p1e_set_w;\n  wire p1e_clr_w;")
s = rep(s, ".p1e_dispp(p1e_dispp_w),\n",
           ".p1e_set(p1e_set_w),\n" + " " * 70 + ".p1e_clr(p1e_clr_w),\n")
s = rep(s, "  FEC_Decoder_Wrapper u_FEC_Decoder_Wrapper (.dispIn(p1e_dispp_w),\n",
           "  FEC_Decoder_Wrapper u_FEC_Decoder_Wrapper (.setIn(p1e_set_w),\n"
           "                                              .clrIn(p1e_clr_w),\n")
open(p, 'w').write(s)

# ---- 5. FEC_Decoder_Wrapper: two inputs -> RxDeint ----
p = f'{B}/FEC_Decoder_Wrapper.v'
s = open(p).read()
s = rep(s, "          (dispIn,\n", "          (setIn,\n           clrIn,\n")
s = rep(s, "  input   dispIn;", "  input   setIn;\n  input   clrIn;")
s = rep(s, "  RxDeint u_RxDeint (.dispIn(dispIn),\n",
           "  RxDeint u_RxDeint (.setIn(setIn),\n                     .clrIn(clrIn),\n")
open(p, 'w').write(s)

# ---- 6. RxDeint: set/clr pend semantics + consume debug ----
p = f'{B}/RxDeint.v'
s = open(p).read()
s = rep(s, "           frameEnd,\n           dispIn);", "           frameEnd,\n           setIn,\n           clrIn);")
s = rep(s, "  input   dispIn;", "  input   setIn;\n  input   clrIn;")
s = rep(s, "    pendD_next = pendD | dispIn;", "    pendD_next = (pendD | setIn) & ~clrIn;")
s = rep(s, "          skipCnt <= skipCnt_next;\n          pendD <= pendD_next;",
           "          skipCnt <= skipCnt_next;\n          pendD <= pendD_next;\n"
           "          // synthesis translate_off\n"
           "          if (skipCnt == 7'd0 && skipCnt_next == 7'd64) begin\n"
           "            $display(\"P1E_CONSUME\");\n"
           "          end\n"
           "          // synthesis translate_on")
open(p, 'w').write(s)

print('hdlD2 generated OK')
