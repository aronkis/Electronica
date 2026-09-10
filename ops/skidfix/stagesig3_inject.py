#!/usr/bin/env python3
"""stagesig3_inject.py (GATE-4 RTL: bounded 1024-beat window + hard-decision taps at stages 4/5)

Original header follows.

stagesig_inject.py <netlist_dir> -- per-stage per-frame signature witness.

Adds, INSIDE the IP (no top-level port changes, so the BD is untouched and a
source-only resynth suffices):

  FixCtlDec.v : stageSel = ctl[11:8]   (bits 0-4 are already taken:
                0 contract, 1 ser-anchor, 2 grid-pace, 3 enSlack, 4 enSpurStart)

  QPSK_Rx.v   : seven per-frame signature accumulators, one per RX-chain stage,
                all running simultaneously; a per-stage mismatch counter; and a
                readout mux onto the two existing beatfix_viol registers.

Taps (all already visible in QPSK_Rx.v -- Frequency_and_Time_Synchronizer
already exports postSymbolSync/postCarrierSync as ports):

  0  dataIn                 RX input == TX modulator output (loopback input)
  1  AGC out
  2  RRC matched-filter out
  3  postSymbolSync         (timing recovery)
  4  postCarrierSync        (carrier recovery)
  5  QPSKConstellationPoints  FTS out == demod in (post phase-ambiguity)
  6  QPSK_Demodulator dataOut  demod output bits

Readout: 0x20C = selected stage's latest per-frame signature
         0x210 = selected stage's MISMATCH COUNT (frames whose signature
                 differed from the reference frame). Accumulating, so it
                 survives slow polling -- unlike the FecCapture snapshots.

Reference frame is latched at frame REFN=8 after reset, deliberately past the
acquisition transient (frame 1 is the only nonzero frame in a clean sim run).

PRE-REGISTERED GATE: on a clean run every mismatch counter must read 0.
Any stage that is nonzero when healthy has no frame-invariant signature and
gets NO coverage -- report it as uncovered, do not interpret it.
"""
import sys, os, re, hashlib

REFN = 8
NTAP = 7

FIXCTL_OLD = "  assign enSpurStart = (ctl & 32'd16) != 32'd0;"
FIXCTL_NEW = """  assign enSpurStart = (ctl & 32'd16) != 32'd0;

  // 2026-08-30 stage-signature witness: bits [11:8] select which RX-chain stage
  // is read back on beatfix_viol_count/latch. Bits 0-4 are unchanged.
  assign stageSel = ctl[11:8];"""


def patch_fixctl(path):
    """Tolerant of both netlist variants: the sim tree (s1_rtl_pdwit) carries an
    extra enSpurStart port (fixctl bit4) that the FLASHED production netlist does
    not have. Anchor on things common to both."""
    s = open(path).read()
    if 'stageSel' in s:
        return 'already'
    # port list: append stageSel after the last port, whatever it is
    m = re.search(r"\n           (enSpurStart|enSlack)\);", s)
    assert m, 'FixCtlDec port-list terminator not found in %s' % path
    s = s[:m.start()] + "\n           %s,\n           stageSel);" % m.group(1) + s[m.end():]
    # output declaration: after the enSlack output decl line (may carry a comment)
    m2 = re.search(r"\n  output  enSlack;[^\n]*\n", s)
    assert m2, 'FixCtlDec enSlack output decl not found'
    s = s[:m2.end()] + "  output  [3:0] stageSel;  // ufix4  stage-signature readout select (ctl[11:8])\n" + s[m2.end():]
    # assign: after the last existing decode assign
    anchor = "  assign enSlack = (ctl & 32'd8) != 32'd0;"
    assert anchor in s, 'FixCtlDec enSlack assign not found'
    add = ("\n\n  // 2026-08-30 stage-signature witness: bits [11:8] select which RX-chain stage\n"
           "  // is read back on beatfix_viol_count/latch. Bits 0-4 are unchanged.\n"
           "  assign stageSel = ctl[11:8];")
    s = s.replace(anchor, anchor + add, 1)
    assert s.count('stageSel') >= 3, 'FixCtlDec patch failed on %s' % path
    open(path, 'w').write(s)
    return 'patched'


SIG_BLOCK = "\n  // ==================================================================\n  // 2026-08-30 STAGE-SIGNATURE WITNESS (stagesig_inject.py)\n  // Seven per-frame rotate-XOR signatures, one per RX-chain stage, all\n  // accumulating simultaneously; readout muxed by fixctl[11:8] onto the\n  // two beatfix_viol registers (0x20C signature / 0x210 mismatch count).\n  // Frame strobe = QPSK_Demodulator_startOut (one pulse per frame).\n  // Reference latched at frame 8, past the acquisition transient.\n  // ==================================================================\n  reg  [31:0] ssig   [0:6];\n  reg  [31:0] ssigl  [0:6];\n  reg  [31:0] sref   [0:6];\n  reg  [31:0] smm    [0:6];\n  reg  [15:0] sfc;\n  reg  [15:0] sidx  [0:6];\n  integer si;\n\n  wire [31:0] sdat [0:6];\n  wire        sval [0:6];\n\n  assign sdat[0] = {dataIn_re, dataIn_im};\n  assign sval[0] = validIn;\n  assign sdat[1] = {Automatic_Gain_Control_dataOut_re, Automatic_Gain_Control_dataOut_im};\n  assign sval[1] = Automatic_Gain_Control_validOut;\n  assign sdat[2] = {RRC_Receive_Filter_out1_re, RRC_Receive_Filter_out1_im};\n  assign sval[2] = RRC_Receive_Filter_out2;\n  assign sdat[3] = {Frequency_and_Time_Synchronizer_postSymbolSync_re, Frequency_and_Time_Synchronizer_postSymbolSync_im};\n  assign sval[3] = 1'b1;\n  assign sdat[4] = {30'b0, Frequency_and_Time_Synchronizer_postCarrierSync_re[15], Frequency_and_Time_Synchronizer_postCarrierSync_im[15]};\n  assign sval[4] = 1'b1;\n  assign sdat[5] = {30'b0, QPSKConstellationPoints_re[15], QPSKConstellationPoints_im[15]};\n  assign sval[5] = QPSKConstellationValid;\n  assign sdat[6] = {31'b0, QPSK_Demodulator_dataOut};\n  assign sval[6] = QPSK_Demodulator_validOut;\n\n  always @(posedge clk or posedge reset)\n    begin : stagesig_process\n      if (reset == 1'b1) begin\n        for (si = 0; si <= 6; si = si + 1) begin\n          ssig[si]  <= 32'd0;\n          ssigl[si] <= 32'd0;\n          sidx[si]  <= 16'd0;\n          sref[si]  <= 32'd0;\n          smm[si]   <= 32'd0;\n        end\n        sfc <= 16'd0;\n      end\n      else if (enb_1_2_0) begin\n        if (QPSK_Demodulator_startOut) begin\n          for (si = 0; si <= 6; si = si + 1) begin\n            ssigl[si] <= ssig[si];\n            if (sfc == 16'd8) begin\n              sref[si] <= ssig[si];\n            end\n            else if (sfc > 16'd8) begin\n              if (ssig[si] != sref[si] && smm[si] != 32'hFFFFFFFF) begin\n                smm[si] <= smm[si] + 32'd1;\n              end\n            end\n            ssig[si] <= sval[si] ? ({32'd0} ^ sdat[si]) : 32'd0;\n            sidx[si] <= sval[si] ? 16'd1 : 16'd0;\n          end\n          if (sfc != 16'hFFFF) begin\n            sfc <= sfc + 16'd1;\n          end\n        end\n        else begin\n          for (si = 0; si <= 6; si = si + 1) begin\n            if (sval[si] && sidx[si] < 16'd1024) begin\n              ssig[si] <= {ssig[si][30:0], ssig[si][31]} ^ sdat[si];\n              sidx[si] <= sidx[si] + 16'd1;\n            end\n          end\n        end\n      end\n    end\n"


OUT_OLD_A = "  assign beatfix_viol_count = pdWitA;"
OUT_OLD_B = "  assign beatfix_viol_latch = pdWitB;"
OUT_NEW = ("  assign beatfix_viol_count = ssigl[stageSel[2:0]];\n"
           "\n"
           "  assign beatfix_viol_latch = smm[stageSel[2:0]];")


def patch_qpskrx(path):
    s = open(path).read()
    if 'stagesig_process' in s:
        return 'already'
    # stageSel wire + FixCtlDec port
    s = s.replace("  wire [31:0] violCount;  // uint32",
                  "  wire [3:0] stageSel;  // ufix4  stage-signature readout select\n"
                  "  wire [31:0] violCount;  // uint32", 1)
    m = re.search(r"(\.enSpurStart\(enSpurStart\)|\.enSlack\(enSlack\))\);\n", s)
    assert m, 'FixCtlDec instantiation terminator not found'
    s = s[:m.start()] + m.group(1) + ",\n                                        .stageSel(stageSel));\n" + s[m.end():]
    assert '.stageSel(stageSel)' in s, 'FixCtlDec instantiation not patched'
    # signature block: insert just before the output assigns
    assert OUT_OLD_A in s and OUT_OLD_B in s, 'beatfix_viol assigns not found'
    s = s.replace(OUT_OLD_A, SIG_BLOCK + "\n" + OUT_NEW, 1)
    # drop the now-dead second assign
    s = s.replace("\n" + OUT_OLD_B, "", 1)
    assert 'stagesig_process' in s and 'ssigl[stageSel' in s, 'QPSK_Rx patch failed'
    assert 'assign beatfix_viol_count = pdWitA' not in s
    assert 'assign beatfix_viol_latch = pdWitB' not in s
    open(path, 'w').write(s)
    return 'patched'


def main(d):
    n = 0
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            if f in ('FixCtlDec.v', 'TxRxCompo_ip_src_FixCtlDec.v'):
                print(f"  FixCtlDec {patch_fixctl(p):8s} {p}"); n += 1
            elif f in ('QPSK_Rx.v', 'TxRxCompo_ip_src_QPSK_Rx.v'):
                print(f"  QPSK_Rx   {patch_qpskrx(p):8s} {p}"); n += 1
    print(f"STAGESIG_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
