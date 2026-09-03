#!/usr/bin/env python3
"""dbgcap_inject.py <netlist_dir> -- DIRECT per-stage decision capture.

NOT a third revision of the stage-signature window. That approach is abandoned:
it accumulated a rolling signature over a window whose PHASE was never anchored,
and it failed its own clean-link gate twice on silicon (11.15 then 9.76
mismatches/s at stage 0). This is a different instrument class -- a bounded
CAPTURE armed by the frame start, which is exactly the discipline that makes
FecCapture's cap_in work on hardware at 99.47 % constant.

It also adds no new taps. The design already carries a per-stage RX debug mux,
selected by the existing writable register iq_debug_mux (0x10C):
    0 -> Automatic_Gain_Control out      (SAMPLE domain)
    1 -> postSymbolSync                  (symbol domain, after timing recovery)
    2 -> postCarrierSync                 (symbol domain, before ambiguity fix)
    3 -> QPSKConstellationPoints         (symbol domain, demod input)
   4+ -> P1c telemetry
Its output (Index_Vector_out1_re/im) previously went only to debugI/debugQ, which
this lineage does not route to any capture path. This adds the readout.

What it captures: the first 16 symbols after each frame start, as 32 bits of HARD
DECISIONS ({sign(I), sign(Q)} per symbol), strobed by QPSKConstellationValid.
Hard decisions because the carrier loop leaves a residual rotation that makes the
soft values differ every frame while the decisions do not (sim gate 4).

Readout, on the two registers already routed for the dead delay-FIFO witness:
    0x20C = last completed frame's 32-bit decision capture
    0x210 = MISMATCH COUNT vs the reference frame (latched at frame 8, past the
            acquisition transient). Accumulating, so slow polling is fine.

PRE-REGISTERED GATE: on a clean run, mismatches must be 0 for the symbol-domain
taps (1, 2, 3). Tap 0 is sample-domain and strobed by a symbol-rate valid, so it
is UNCOVERED BY CONSTRUCTION and must be reported as such, never interpreted.
"""
import sys, os, re

REFN = 8
NSYM = 16   # 16 symbols x 2 decision bits = 32 bits

BLOCK = """
  // ==================================================================
  // 2026-08-30 DBGCAP -- direct per-stage decision capture (dbgcap_inject.py).
  // Taps the EXISTING RX debug mux (selected by iq_debug_mux @0x10C) and
  // captures the first %d symbols after each frame start as hard decisions.
  // Armed by QPSK_Demodulator_startOut, strobed by QPSKConstellationValid:
  // the same bounded, frame-anchored discipline that makes cap_in work.
  // 0x20C = capture, 0x210 = mismatches vs the frame-%d reference.
  // ==================================================================
  reg  [31:0] dcap;
  reg  [31:0] dcapl;
  reg  [31:0] dcref;
  reg  [31:0] dcmm;
  reg  [7:0]  dcidx;
  reg  [15:0] dcfc;

  always @(posedge clk or posedge reset)
    begin : dbgcap_process
      if (reset == 1'b1) begin
        dcap  <= 32'd0;
        dcapl <= 32'd0;
        dcref <= 32'd0;
        dcmm  <= 32'd0;
        dcidx <= 8'd0;
        dcfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (QPSK_Demodulator_startOut) begin
          dcapl <= dcap;
          if (dcfc == 16'd%d) begin
            dcref <= dcap;
          end
          else if (dcfc > 16'd%d) begin
            if (dcap != dcref && dcmm != 32'hFFFFFFFF) begin
              dcmm <= dcmm + 32'd1;
            end
          end
          dcap  <= 32'd0;
          dcidx <= 8'd0;
          dcfc  <= (dcfc == 16'hFFFF) ? dcfc : (dcfc + 16'd1);
        end
        else if (QPSKConstellationValid && dcidx < 8'd%d) begin
          dcap  <= {dcap[29:0], Index_Vector_out1_re[15], Index_Vector_out1_im[15]};
          dcidx <= dcidx + 8'd1;
        end
      end
    end
""" % (NSYM, REFN, REFN, REFN, NSYM)

OUT_A = "  assign beatfix_viol_count = pdWitA;"
OUT_B = "  assign beatfix_viol_latch = pdWitB;"
NEW = ("  assign beatfix_viol_count = dcapl;\n"
       "\n"
       "  assign beatfix_viol_latch = dcmm;")


def patch(path):
    s = open(path).read()
    if 'dbgcap_process' in s:
        return 'already'
    for need in ('Index_Vector_out1_re', 'QPSKConstellationValid',
                 'QPSK_Demodulator_startOut', OUT_A, OUT_B):
        assert need in s, f'anchor missing in {path}: {need[:50]}'
    s = s.replace(OUT_A, BLOCK + "\n" + NEW, 1)
    s = s.replace("\n" + OUT_B, "", 1)
    assert 'dbgcap_process' in s and 'assign beatfix_viol_count = dcapl;' in s
    assert 'pdWitA' not in s.split('dbgcap_process')[1]
    open(path, 'w').write(s)
    return 'patched'


def main(d):
    n = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f in ('QPSK_Rx.v', 'TxRxCompo_ip_src_QPSK_Rx.v'):
                p = os.path.join(root, f)
                print(f"  QPSK_Rx {patch(p):8s} {p}")
                n += 1
    print(f"DBGCAP_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
