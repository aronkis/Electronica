#!/usr/bin/env python3
"""demodcap_inject.py <netlist_dir> -- the discriminating test for §20.

Apply AFTER dbgcap_inject.py (and optionally txcap_inject.py).

§20 established on silicon that everything up to and including the demodulator's
INPUT (constellation decisions) is bit-identical every frame through bursts, while
the coded bits at the FEC decoder's INPUT (cap_in) are not. Two readings survive:

  (A) values change  -- the demod slices/serialises identical decisions into
                        different bits.
  (B) position shifts -- the bits are correct but cap_in's window moves, because
                        cap_in is armed by the FEC start (startSel, via BfContract)
                        while DBGCAP is armed by QPSK_Demodulator_startOut.

DEMODCAP captures the SAME BITS as cap_in -- QPSK_Demodulator_dataOut, gated by
QPSK_Demodulator_validOut -- but armed by QPSK_Demodulator_startOut instead of the
FEC start. Two anchors, one bit stream.

  DEMODCAP golden while cap_in deviates  => the FEC start marker moved: reading (B)
  both deviate                           => the bit values changed: reading (A)

That is a clean, pre-registered discrimination with no third possibility for the
same window, because the two captures cover the same 32 coded bits of the frame.

Readout: fixctl bit 13 selects DEMODCAP over DBGCAP on the beatfix_viol registers.
  fixctl[13]=0 -> DBGCAP (RX stage capture, iq_debug_mux selects the stage)
  fixctl[13]=1 -> DEMODCAP (0x20C = capture, 0x210 = mismatches)
fixctl[12] (TXCAP, applied at TxRxComposite) still overrides both when set.
Bits 0-4 remain the fix arms and are untouched.
"""
import sys, os

REFN = 8
NBIT = 32

BLOCK = """
  // ==================================================================
  // 2026-08-30 DEMODCAP -- same bits as cap_in, different anchor.
  // cap_in is armed by the FEC start (startSel); this is armed by
  // QPSK_Demodulator_startOut. If this stays golden while cap_in deviates,
  // the FEC start marker is moving rather than the bits changing.
  // ==================================================================
  reg  [31:0] mdcap;
  reg  [31:0] mdcapl;
  reg  [31:0] mdcref;
  reg  [31:0] mdcmm;
  reg  [7:0]  mdcidx;
  reg  [15:0] mdcfc;

  always @(posedge clk or posedge reset)
    begin : demodcap_process
      if (reset == 1'b1) begin
        mdcap  <= 32'd0;
        mdcapl <= 32'd0;
        mdcref <= 32'd0;
        mdcmm  <= 32'd0;
        mdcidx <= 8'd0;
        mdcfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (QPSK_Demodulator_startOut) begin
          mdcapl <= mdcap;
          if (mdcfc == 16'd%d) begin
            mdcref <= mdcap;
          end
          else if (mdcfc > 16'd%d) begin
            if (mdcap != mdcref && mdcmm != 32'hFFFFFFFF) begin
              mdcmm <= mdcmm + 32'd1;
            end
          end
          mdcap  <= 32'd0;
          mdcidx <= 8'd0;
          mdcfc  <= (mdcfc == 16'hFFFF) ? mdcfc : (mdcfc + 16'd1);
        end
        else if (QPSK_Demodulator_validOut && mdcidx < 8'd%d) begin
          mdcap  <= {mdcap[30:0], QPSK_Demodulator_dataOut};
          mdcidx <= mdcidx + 8'd1;
        end
      end
    end
""" % (REFN, REFN, NBIT)

OLD_A = "  assign beatfix_viol_count = dcapl;"
OLD_B = "  assign beatfix_viol_latch = dcmm;"
NEW = ("  assign beatfix_viol_count = fixctl[13] ? mdcapl : dcapl;\n"
       "\n"
       "  assign beatfix_viol_latch = fixctl[13] ? mdcmm : dcmm;")


def patch(path):
    s = open(path).read()
    if 'demodcap_process' in s:
        return 'already'
    assert 'dbgcap_process' in s, f'{path}: apply dbgcap_inject.py first'
    for need in ('QPSK_Demodulator_dataOut', 'QPSK_Demodulator_validOut',
                 'QPSK_Demodulator_startOut', OLD_A, OLD_B):
        assert need in s, f'anchor missing in {path}: {need[:40]}'
    s = s.replace(OLD_A, BLOCK + "\n" + NEW, 1)
    s = s.replace("\n" + OLD_B, "", 1)
    assert 'demodcap_process' in s and 'fixctl[13] ? mdcapl' in s
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
    print(f"DEMODCAP_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
