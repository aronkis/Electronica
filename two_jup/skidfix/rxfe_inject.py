#!/usr/bin/env python3
"""rxfe_inject.py <netlist_dir> -- two new RX-chain witnesses: the RRC receive
filter output and the coarse frequency compensator output, the two RX-chain
points between AGC out and postSymbolSync that carry no instrument today.

Apply AFTER dbgcap_inject.py and demodcap_inject.py (this patches the same
final assign statements they leave behind in QPSK_Rx.v). Independent of
txcap_inject.py (different file, different fixctl bits) -- order with it does
not matter.

Same instrument class as DBGCAP/DEMODCAP: a bounded capture armed by the
RX frame marker (QPSK_Demodulator_startOut), scored by golden-constancy
against a frame-8 reference. No rolling signature, no on-chip mismatch
counter used as ground truth (0x210 is diagnostic only, per RESUME_20260831
Sec.4 item 2 -- score 0x20C by golden-constancy in software).

Both new taps carry SOFT sample values that are demonstrably NOT
frame-invariant downstream of the carrier loop (rotation), so -- like
DBGCAP -- this captures HARD DECISIONS only: sign(I), sign(Q) per sample,
16 samples -> 32 bits.

Tap A -- RRC receive filter output (RRC_Receive_Filter_out1_re/im, valid
  RRC_Receive_Filter_out2). Already a plain wire inside QPSK_Rx.v; no port
  surgery needed there.

Tap B -- coarse frequency compensator output. That signal is INTERNAL to
  Frequency_and_Time_Synchronizer (Coarse_Frequency_Compensator_dataOut_re/im,
  valid Coarse_Frequency_Compensator_validOut). This adds a new
  postCoarseFreq_re/im/valid OUTPUT PORT to that module (internal-port
  surgery only -- QPSK_Rx.v's and the IP's TOP-LEVEL ports are untouched, so
  this remains a source-only resynth, same pattern the runbook used for
  postSymbolSync/postCarrierSync) and wires it through to QPSK_Rx.v.

Both taps are SAMPLE-domain, captured against a SYMBOL-domain frame marker
(QPSK_Demodulator_startOut) -- the same relationship DBGCAP's tap 0 (AGC out)
already has, documented there as "uncovered by construction" for the exact
frame boundary. That is an accepted, pre-existing limitation of this
instrument class for sample-domain taps, not a new defect; golden-constancy
scoring is still meaningful because the reference and every subsequent frame
sample the same relative phase.

Readout: fixctl bit 20 selects tap A (RRC out), bit 21 selects tap B (coarse
freq out), on top of the existing fixctl[12] (TXCAP, in TxRxComposite.v),
fixctl[13] (DEMODCAP). Priority when multiple bits are set: TXCAP (in
TxRxComposite.v) overrides everything; within QPSK_Rx.v, tap B > tap A >
DEMODCAP > DBGCAP. Bits 0-4 (fix arms) and 8-11 (superseded) are untouched.
Bits 14+ belong to the concurrently-building TX-INT agent -- do not use them.

2026-08-31 SIM-GATE RESULT (jupiter_240k5_byte/rtl_sim, Verilator, clean
mode-1 internal loopback, s1_rtl_rxfe):
  - Tap A (RFCAP, fixctl[20]) PASSES golden-constancy: 0 mismatches at
    NF=10 AND at a 126-frame long run (cap=0x5EA9540A throughout).
  - Tap B (CFCAP, fixctl[21]) FAILS golden-constancy, NOT a startup/
    acquisition-reference transient: over 126 frames it cycles through
    FOUR distinct capture values with a period of 16 frames (4 frames per
    state), e.g. 0xD174DDCD -> 0x48124464 -> 0x2E8B2232 -> (270 deg state,
    equals the frame-8 reference) -> repeat. The four states are exactly
    the four 90-degree sign-bit quadrant rotations of one underlying
    sample sequence ((sI,sQ) -> (~sQ,sI) for +90, (~sI,~sQ) for 180, etc),
    consistent with a small residual frequency offset that the coarse
    (bulk-only) frequency compensator does not fully remove -- fine/
    carrier-loop correction has not yet been applied at this tap, unlike
    the demod-input tap DBGCAP/DEMODCAP score against (which sits AFTER
    the full carrier sync). This is an ARCHITECTURAL property of that tap
    point, not an instrument bug, and it means absolute-quadrant hard-
    decision capture cannot be scored by golden-constancy this early in
    the chain. DO NOT re-run fixctl[21] expecting a golden-constant
    result; it will not converge at any reference frame. A follow-on
    agent wanting to instrument this point should capture a ROTATION-
    INVARIANT encoding instead, e.g. per-sample quadrant TRANSITION
    (q_n - q_[n-1]) mod 4, 2 bits x 16 transitions = same 32-bit register.
  Because CFCAP fails the clean-loopback gate, NO Vivado image was built
  from this injector as of 2026-08-31; only the sim-gated RTL exists.
  RFCAP's positive control (does the capture value actually change) could
  not be demonstrated in the same session -- see agent-rxfe-report.md for
  the full record, including the DEMODCAP null-control that shows the
  byte-plane payload knob (tx_data_source) does not reach the modulated
  content in this composite/wrapper, so RFCAP's non-movement is not (yet)
  attributable to the witness itself.
"""
import sys, os

REFN = 8
NSMP = 16

FTS_ANCHOR_PORTLIST = "           postCarrierSync_im,\n"
FTS_NEW_PORTLIST = ("           postCarrierSync_im,\n"
                     "           postCoarseFreq_re,\n"
                     "           postCoarseFreq_im,\n"
                     "           postCoarseFreq_valid,\n")

FTS_ANCHOR_DECL = "  output  signed [15:0] postCarrierSync_im;  // sfix16_En14\n"
FTS_NEW_DECL = (FTS_ANCHOR_DECL +
                 "  output  signed [15:0] postCoarseFreq_re;  // sfix16_En14\n"
                 "  output  signed [15:0] postCoarseFreq_im;  // sfix16_En14\n"
                 "  output  postCoarseFreq_valid;\n")

FTS_ASSIGN_ANCHOR = "  assign postCarrierSync_im = Carrier_Synchronizer_dataOut_im;\n"
FTS_NEW_ASSIGN = (FTS_ASSIGN_ANCHOR +
                   "\n"
                   "  assign postCoarseFreq_re = Coarse_Frequency_Compensator_dataOut_re;\n"
                   "  assign postCoarseFreq_im = Coarse_Frequency_Compensator_dataOut_im;\n"
                   "  assign postCoarseFreq_valid = Coarse_Frequency_Compensator_validOut;\n")


def patch_freqsync(path):
    s = open(path).read()
    if 'postCoarseFreq_re' in s:
        return 'already'
    for need in (FTS_ANCHOR_PORTLIST, FTS_ANCHOR_DECL, FTS_ASSIGN_ANCHOR,
                 'Coarse_Frequency_Compensator_dataOut_re',
                 'Coarse_Frequency_Compensator_validOut'):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = s.replace(FTS_ANCHOR_PORTLIST, FTS_NEW_PORTLIST, 1)
    s = s.replace(FTS_ANCHOR_DECL, FTS_NEW_DECL, 1)
    s = s.replace(FTS_ASSIGN_ANCHOR, FTS_NEW_ASSIGN, 1)
    assert s.count('postCoarseFreq_re') >= 3
    open(path, 'w').write(s)
    return 'patched'


# --- QPSK_Rx.v -------------------------------------------------------------

QRX_WIRE_ANCHOR = "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCarrierSync_im;  // sfix16_En14\n"
QRX_WIRE_NEW = (QRX_WIRE_ANCHOR +
                 "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCoarseFreq_re;  // sfix16_En14\n"
                 "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCoarseFreq_im;  // sfix16_En14\n"
                 "  wire Frequency_and_Time_Synchronizer_postCoarseFreq_valid;\n")

QRX_INST_ANCHOR = "                                                                                      .postCarrierSync_im(Frequency_and_Time_Synchronizer_postCarrierSync_im),  // sfix16_En14\n"
QRX_INST_NEW = (QRX_INST_ANCHOR +
                 "                                                                                      .postCoarseFreq_re(Frequency_and_Time_Synchronizer_postCoarseFreq_re),  // sfix16_En14\n"
                 "                                                                                      .postCoarseFreq_im(Frequency_and_Time_Synchronizer_postCoarseFreq_im),  // sfix16_En14\n"
                 "                                                                                      .postCoarseFreq_valid(Frequency_and_Time_Synchronizer_postCoarseFreq_valid),\n")

BLOCK = """
  // ==================================================================
  // 2026-08-31 RXFECAP -- RX front-end witnesses (rxfe_inject.py).
  // Two new taps, both currently uninstrumented: the RRC receive filter
  // output (rfcap, sample domain, valid RRC_Receive_Filter_out2) and the
  // coarse frequency compensator output (cfcap, sample domain, valid
  // Frequency_and_Time_Synchronizer_postCoarseFreq_valid). Same discipline
  // as DBGCAP/DEMODCAP: bounded capture of the first %d samples after each
  // RX frame start (QPSK_Demodulator_startOut), hard decisions only
  // (sign(I), sign(Q) per sample -- soft values rotate with the carrier and
  // are not frame-invariant). Scored by golden-constancy against the
  // frame-%d reference; 0x210-style on-chip mismatch counters are kept for
  // continuity but are diagnostic only, per RESUME_20260831 Sec.4.
  // fixctl[20] selects rfcap, fixctl[21] selects cfcap on the shared
  // beatfix_viol_count/latch bus (see readout mux below).
  // ==================================================================
  reg  [31:0] rfcap;
  reg  [31:0] rfcapl;
  reg  [31:0] rfcref;
  reg  [31:0] rfcmm;
  reg  [7:0]  rfcidx;
  reg  [15:0] rfcfc;

  reg  [31:0] cfcap;
  reg  [31:0] cfcapl;
  reg  [31:0] cfcref;
  reg  [31:0] cfcmm;
  reg  [7:0]  cfcidx;
  reg  [15:0] cfcfc;

  always @(posedge clk or posedge reset)
    begin : rxfecap_process
      if (reset == 1'b1) begin
        rfcap  <= 32'd0;
        rfcapl <= 32'd0;
        rfcref <= 32'd0;
        rfcmm  <= 32'd0;
        rfcidx <= 8'd0;
        rfcfc  <= 16'd0;
        cfcap  <= 32'd0;
        cfcapl <= 32'd0;
        cfcref <= 32'd0;
        cfcmm  <= 32'd0;
        cfcidx <= 8'd0;
        cfcfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (QPSK_Demodulator_startOut) begin
          rfcapl <= rfcap;
          if (rfcfc == 16'd%d) begin
            rfcref <= rfcap;
          end
          else if (rfcfc > 16'd%d) begin
            if (rfcap != rfcref && rfcmm != 32'hFFFFFFFF) begin
              rfcmm <= rfcmm + 32'd1;
            end
          end
          rfcap  <= 32'd0;
          rfcidx <= 8'd0;
          rfcfc  <= (rfcfc == 16'hFFFF) ? rfcfc : (rfcfc + 16'd1);

          cfcapl <= cfcap;
          if (cfcfc == 16'd%d) begin
            cfcref <= cfcap;
          end
          else if (cfcfc > 16'd%d) begin
            if (cfcap != cfcref && cfcmm != 32'hFFFFFFFF) begin
              cfcmm <= cfcmm + 32'd1;
            end
          end
          cfcap  <= 32'd0;
          cfcidx <= 8'd0;
          cfcfc  <= (cfcfc == 16'hFFFF) ? cfcfc : (cfcfc + 16'd1);
        end
        else begin
          if (RRC_Receive_Filter_out2 && rfcidx < 8'd%d) begin
            rfcap  <= {rfcap[29:0], RRC_Receive_Filter_out1_re[15], RRC_Receive_Filter_out1_im[15]};
            rfcidx <= rfcidx + 8'd1;
          end
          if (Frequency_and_Time_Synchronizer_postCoarseFreq_valid && cfcidx < 8'd%d) begin
            cfcap  <= {cfcap[29:0], Frequency_and_Time_Synchronizer_postCoarseFreq_re[15], Frequency_and_Time_Synchronizer_postCoarseFreq_im[15]};
            cfcidx <= cfcidx + 8'd1;
          end
        end
      end
    end
""" % (NSMP, REFN, REFN, REFN, REFN, REFN, NSMP, NSMP)

OLD_A = "  assign beatfix_viol_count = fixctl[13] ? mdcapl : dcapl;"
OLD_B = "  assign beatfix_viol_latch = fixctl[13] ? mdcmm : dcmm;"
NEW = ("  assign beatfix_viol_count = fixctl[21] ? cfcapl : (fixctl[20] ? rfcapl : (fixctl[13] ? mdcapl : dcapl));\n"
       "\n"
       "  assign beatfix_viol_latch = fixctl[21] ? cfcmm : (fixctl[20] ? rfcmm : (fixctl[13] ? mdcmm : dcmm));")


def patch_qpskrx(path):
    s = open(path).read()
    if 'rxfecap_process' in s:
        return 'already'
    assert 'demodcap_process' in s, f'{path}: apply dbgcap_inject.py + demodcap_inject.py first'
    for need in (QRX_WIRE_ANCHOR, QRX_INST_ANCHOR, OLD_A, OLD_B,
                 'RRC_Receive_Filter_out1_re', 'RRC_Receive_Filter_out2',
                 'QPSK_Demodulator_startOut'):
        assert need in s, f'anchor missing in {path}: {need[:60]!r}'
    s = s.replace(QRX_WIRE_ANCHOR, QRX_WIRE_NEW, 1)
    s = s.replace(QRX_INST_ANCHOR, QRX_INST_NEW, 1)
    s = s.replace(OLD_A, BLOCK + "\n" + NEW, 1)
    s = s.replace("\n" + OLD_B, "", 1)
    assert 'rxfecap_process' in s and 'fixctl[21] ? cfcapl' in s
    open(path, 'w').write(s)
    return 'patched'


def main(d):
    n = 0
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            if f in ('Frequency_and_Time_Synchronizer.v', 'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v'):
                print(f"  FreqSync {patch_freqsync(p):8s} {p}"); n += 1
            elif f in ('QPSK_Rx.v', 'TxRxCompo_ip_src_QPSK_Rx.v'):
                print(f"  QPSK_Rx  {patch_qpskrx(p):8s} {p}"); n += 1
    print(f"RXFE_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
