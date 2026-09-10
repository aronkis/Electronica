#!/usr/bin/env python3
"""txcap_inject.py <netlist_dir> -- TX-side capture, anchored on the TRANSMITTER's
own frame start. Apply AFTER dbgcap_inject.py; the two combine into one image.

This is the instrument the TX-vs-RX fork actually needs. Every previous attempt
anchored the window on QPSK_Demodulator_startOut -- a RECEIVER, symbol-domain
event -- while observing the transmitter's SAMPLE-domain output. Nothing in the
design forces those two to keep a constant relative phase, and on hardware they
do not: stage 0 failed its clean-link gate twice (11.15 then 9.76 mismatches/s)
and bounding the window length did not help, because length was never the problem.

Here the anchor is `Bit_Packetizer_dataStart` inside QPSK_Tx -- the transmitter's
own per-frame marker. The capture is therefore phase-locked to the thing it
observes, with no receiver involvement at all.

Wiring (all internal; the IP's top-level ports are unchanged, so the BD is
untouched and a source-only resynth suffices):
  QPSK_Tx.v        : new output txFrameStart = Bit_Packetizer_dataStart
  Transmitter.v    : new output txFrameStart, passed through from u_QPSK_Tx
  TxRxComposite.v  : capture the first 16 TX samples after each txFrameStart as
                     32 bits of hard decisions {sign(I),sign(Q)}, plus a mismatch
                     counter vs the frame-8 reference.

Readout: fixctl bit 12 selects which witness drives the two beatfix_viol registers
  fixctl[12]=0 -> DBGCAP (RX stage capture, selected by iq_debug_mux @0x10C)
  fixctl[12]=1 -> TXCAP  (0x20C = TX decision capture, 0x210 = TX mismatches)
Bits 0-4 remain the fix arms and are untouched by either selector.

PRE-REGISTERED: on a clean run TXCAP mismatches must be 0. On hardware, if TXCAP
mismatches are 0 through a full-magnitude burst while 0x108 accumulates errors,
the transmitter's output is bit-identical every frame and the TX is EXONERATED on
silicon. If TXCAP climbs during bursts, the TX is the source.
"""
import sys, os, re

REFN = 8
NSMP = 16

TXBLOCK = """
  // ==================================================================
  // 2026-08-30 TXCAP -- transmitter-anchored decision capture (txcap_inject.py).
  // Anchor is the TX's OWN frame start, so the window is phase-locked to the
  // signal it observes. First %d TX samples after each start, as hard decisions.
  // ==================================================================
  reg  [31:0] txcap;
  reg  [31:0] txcapl;
  reg  [31:0] txcref;
  reg  [31:0] txcmm;
  reg  [7:0]  txcidx;
  reg  [15:0] txcfc;

  always @(posedge clk or posedge reset)
    begin : txcap_process
      if (reset == 1'b1) begin
        txcap  <= 32'd0;
        txcapl <= 32'd0;
        txcref <= 32'd0;
        txcmm  <= 32'd0;
        txcidx <= 8'd0;
        txcfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (Transmitter_txFrameStart) begin
          txcapl <= txcap;
          if (txcfc == 16'd%d) begin
            txcref <= txcap;
          end
          else if (txcfc > 16'd%d) begin
            if (txcap != txcref && txcmm != 32'hFFFFFFFF) begin
              txcmm <= txcmm + 32'd1;
            end
          end
          txcap  <= 32'd0;
          txcidx <= 8'd0;
          txcfc  <= (txcfc == 16'hFFFF) ? txcfc : (txcfc + 16'd1);
        end
        else if (txcidx < 8'd%d) begin
          txcap  <= {txcap[29:0], Transmitter_dataOutI[15], Transmitter_dataOutQ[15]};
          txcidx <= txcidx + 8'd1;
        end
      end
    end
""" % (NSMP, REFN, REFN, NSMP)


def patch_qpsktx(path):
    s = open(path).read()
    if 'txFrameStart' in s:
        return 'already'
    s = s.replace("           dataOut_im);", "           dataOut_im,\n           txFrameStart);", 1)
    s = s.replace("  output  signed [15:0] dataOut_im;",
                  "  output  signed [15:0] dataOut_im;\n  output  txFrameStart;", 1)
    if '  output  txFrameStart;' not in s:   # port decl style differs between generations
        m = re.search(r"\n  output [^\n]*dataOut_im[^\n]*\n", s)
        assert m, 'QPSK_Tx dataOut_im output decl not found'
        s = s[:m.end()] + "  output  txFrameStart;\n" + s[m.end():]
    s = s.rstrip()
    assert s.endswith('endmodule') or 'endmodule' in s
    i = s.rindex('endmodule')
    s = s[:i] + "  assign txFrameStart = Bit_Packetizer_dataStart;\n\n" + s[i:] + "\n"
    assert s.count('txFrameStart') >= 3, 'QPSK_Tx patch failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_transmitter(path):
    s = open(path).read()
    if 'txFrameStart' in s:
        return 'already'
    s = s.replace("           extWordPop);", "           extWordPop,\n           txFrameStart);", 1)
    s = s.replace("  output  extWordPop;", "  output  extWordPop;\n  output  txFrameStart;", 1)
    s = s.replace(".dataOut_im(QPSK_Tx_dataOut_im)  // sfix16_En14",
                  ".dataOut_im(QPSK_Tx_dataOut_im),  // sfix16_En14\n"
                  "                                      .txFrameStart(txFrameStart)", 1)
    assert s.count('txFrameStart') >= 3, 'Transmitter patch failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_composite(path):
    s = open(path).read()
    if 'txcap_process' in s:
        return 'already'
    # new wire + Transmitter port
    s = s.replace("  wire signed [15:0] Transmitter_dataOutI;  // int16",
                  "  wire Transmitter_txFrameStart;\n"
                  "  wire signed [15:0] Transmitter_dataOutI;  // int16", 1)
    s = s.replace(".extWordPop(Transmitter_extWordPop)",
                  ".extWordPop(Transmitter_extWordPop),\n"
                  "                                              .txFrameStart(Transmitter_txFrameStart)", 1)
    assert '.txFrameStart(Transmitter_txFrameStart)' in s, 'Transmitter instantiation not patched'
    # capture block + fixctl[12] readout mux
    a = "  assign beatfix_viol_count = Receiver_beatfix_viol_count_1;"
    b = "  assign beatfix_viol_latch = Receiver_beatfix_viol_latch_1;"
    assert a in s and b in s, 'composite beatfix_viol assigns not found'
    s = s.replace(a, TXBLOCK + "\n  assign beatfix_viol_count = fixctl[12] ? txcapl : Receiver_beatfix_viol_count_1;", 1)
    s = s.replace(b, "  assign beatfix_viol_latch = fixctl[12] ? txcmm : Receiver_beatfix_viol_latch_1;", 1)
    assert 'txcap_process' in s and 'fixctl[12] ? txcapl' in s, 'composite patch failed'
    open(path, 'w').write(s)
    return 'patched'


def main(d):
    n = 0
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            if f in ('QPSK_Tx.v', 'TxRxCompo_ip_src_QPSK_Tx.v'):
                print(f"  QPSK_Tx        {patch_qpsktx(p):8s} {p}"); n += 1
            elif f in ('Transmitter.v', 'TxRxCompo_ip_src_Transmitter.v'):
                print(f"  Transmitter    {patch_transmitter(p):8s} {p}"); n += 1
            elif f in ('TxRxComposite.v', 'TxRxCompo_ip_src_TxRxComposite.v'):
                print(f"  TxRxComposite  {patch_composite(p):8s} {p}"); n += 1
    print(f"TXCAP_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
