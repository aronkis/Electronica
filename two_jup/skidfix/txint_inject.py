#!/usr/bin/env python3
"""txint_inject.py <netlist_dir> -- bounded, frame-anchored capture for the four
TX-side blocks: Bit_Packetizer, HDL_Data_Scrambler (the block file is
HDL_Data_Scrambler.v), QPSK_Modulator, RRC_Transmit_Filter.

Apply AFTER dbgcap_inject.py, txcap_inject.py and demodcap_inject.py -- this
netlist must already carry all three (the "FINAL" lineage, 0f203cf887d3).
txcap_inject.py already exposes Bit_Packetizer_dataStart at the QPSK_Tx/
Transmitter/TxRxComposite boundary as txFrameStart -- this injector reuses that
wire (Transmitter_txFrameStart in TxRxComposite.v) as the anchor for all four
new captures, so no new frame-marker plumbing is needed.

Design (per AGENT_RUNBOOK / handoff §0, §23): bounded capture armed by the
frame marker, scored by GOLDEN-CONSTANCY across polled frames -- not the
on-chip mismatch counter as the primary signal (that class of counter is only
trustworthy when each instrument owns an undivided reference, which is true
here since each of these four is its own dedicated register/reference pair,
never muxed against another tap's data the way DBGCAP's dcref was). The
mismatch counter is included for parity with TXCAP/DEMODCAP but the governor
should score via capture-constancy on the raw 0x20C value across a poll,
exactly like capTAP.

Wiring:
  QPSK_Tx.v        : three new outputs -- bpBit/bpValid (Bit_Packetizer
                     bitsOut/bitsValid), scrBit/scrValid (HDL_Data_Scrambler
                     dataOut/validOut), modRe/modIm/modValid (QPSK_Modulator
                     constellation re/im/validOut). RRC_Transmit_Filter needs
                     NO new plumbing: its output is already QPSK_Tx.dataOut_re/
                     im, already carried to TxRxComposite as
                     Transmitter_dataOutI/Q (the same wires TXCAP taps) --
                     the RRC tap reuses that pair verbatim.
  Transmitter.v    : pass the three new pairs straight through as its own
                     outputs.
  TxRxComposite.v  : four new capture registers (bpcap, scrcap, modcap,
                     rrccap), each armed by the EXISTING Transmitter_txFrameStart
                     wire, each with its own dedicated frame-REFN reference and
                     mismatch counter (same discipline as txcap_process).

Readout: extends the fixctl mux past bits 12/13 (TXCAP/DEMODCAP, untouched) to
bits 14-17 -- bits 8-11 are a superseded instrument and are left alone, bits
0-4 are fix arms and untouched.
  fixctl[14]=1 -> Bit_Packetizer tap   (0x20C = 32 serial bits of bitsOut)
  fixctl[15]=1 -> HDL_Data_Scrambler tap (0x20C = 32 serial bits of dataOut)
  fixctl[16]=1 -> QPSK_Modulator tap   (0x20C = 16 x {sign(re),sign(im)})
  fixctl[17]=1 -> RRC_Transmit_Filter tap (0x20C = 16 x {sign(re),sign(im)},
                     same underlying samples TXCAP observes, different
                     dedicated capture register)
Priority when more than one bit is set: fixctl[12] (TXCAP) > [13] (DEMODCAP,
resolved inside QPSK_Rx.v) > [14] > [15] > [16] > [17] > default RX DBGCAP mux.

PRE-REGISTERED: on a clean run all four captures must be frame-invariant
(constant across frames past the warm-up reference frame). A witness that
cannot be shown to move under a forced upstream data change is dead and must
not be flashed.
"""
import sys, os, re

REFN = 8
NBIT_SER = 32     # Bit_Packetizer / Scrambler: 32 serial bits
NSMP_IQ = 16       # QPSK_Modulator / RRC: 16 complex samples x 2 sign bits = 32 bits


def _capture_block(prefix, arm_wire, valid_expr, shift_expr, nbits_or_nsmp, is_serial):
    """Build one capture+reference+mismatch-counter always-block, mirroring
    txcap_process in txcap_inject.py exactly (same discipline, new prefix)."""
    n = nbits_or_nsmp
    tmpl = """
  // ==================================================================
  // 2026-08-31 TXINT ${PU} -- bounded capture anchored on Transmitter_txFrameStart
  // (the same TX-native marker TXCAP uses), dedicated reference/mismatch pair.
  // ==================================================================
  reg  [31:0] ${P}cap;
  reg  [31:0] ${P}capl;
  reg  [31:0] ${P}cref;
  reg  [31:0] ${P}cmm;
  reg  [7:0]  ${P}cidx;
  reg  [15:0] ${P}cfc;

  always @(posedge clk or posedge reset)
    begin : ${P}cap_process
      if (reset == 1'b1) begin
        ${P}cap  <= 32'd0;
        ${P}capl <= 32'd0;
        ${P}cref <= 32'd0;
        ${P}cmm  <= 32'd0;
        ${P}cidx <= 8'd0;
        ${P}cfc  <= 16'd0;
      end
      else if (enb_1_2_0) begin
        if (${ARM}) begin
          ${P}capl <= ${P}cap;
          if (${P}cfc == 16'd${REFN}) begin
            ${P}cref <= ${P}cap;
          end
          else if (${P}cfc > 16'd${REFN}) begin
            if (${P}cap != ${P}cref && ${P}cmm != 32'hFFFFFFFF) begin
              ${P}cmm <= ${P}cmm + 32'd1;
            end
          end
          ${P}cap  <= 32'd0;
          ${P}cidx <= 8'd0;
          ${P}cfc  <= (${P}cfc == 16'hFFFF) ? ${P}cfc : (${P}cfc + 16'd1);
        end
        else if (${VALID} && ${P}cidx < 8'd${N}) begin
          ${P}cap  <= ${SHIFT};
          ${P}cidx <= ${P}cidx + 8'd1;
        end
      end
    end
"""
    out = tmpl
    out = out.replace("${PU}", prefix.upper())
    out = out.replace("${ARM}", arm_wire)
    out = out.replace("${REFN}", str(REFN))
    out = out.replace("${VALID}", valid_expr)
    out = out.replace("${N}", str(n))
    out = out.replace("${SHIFT}", shift_expr)
    out = out.replace("${P}", prefix)
    return out


BP_BLOCK = _capture_block(
    "bp", "Transmitter_txFrameStart", "Transmitter_bpValid",
    "{bpcap[30:0], Transmitter_bpBit}", NBIT_SER, True)
SCR_BLOCK = _capture_block(
    "scr", "Transmitter_txFrameStart", "Transmitter_scrValid",
    "{scrcap[30:0], Transmitter_scrBit}", NBIT_SER, True)
MOD_BLOCK = _capture_block(
    "mod", "Transmitter_txFrameStart", "Transmitter_modValid",
    "{modcap[29:0], Transmitter_modRe[15], Transmitter_modIm[15]}", NSMP_IQ, False)
RRC_BLOCK = _capture_block(
    "rrc", "Transmitter_txFrameStart", "1'b1",
    "{rrccap[29:0], Transmitter_dataOutI[15], Transmitter_dataOutQ[15]}", NSMP_IQ, False)

ALL_BLOCKS = BP_BLOCK + SCR_BLOCK + MOD_BLOCK + RRC_BLOCK

FIXCTL_COUNT = "  assign beatfix_viol_count = fixctl[12] ? txcapl : Receiver_beatfix_viol_count_1;"
FIXCTL_LATCH = "  assign beatfix_viol_latch = fixctl[12] ? txcmm : Receiver_beatfix_viol_latch_1;"

NEW_COUNT = (
    "  assign beatfix_viol_count = fixctl[12] ? txcapl :\n"
    "                               fixctl[14] ? bpcapl :\n"
    "                               fixctl[15] ? scrcapl :\n"
    "                               fixctl[16] ? modcapl :\n"
    "                               fixctl[17] ? rrccapl :\n"
    "                               Receiver_beatfix_viol_count_1;")
NEW_LATCH = (
    "  assign beatfix_viol_latch = fixctl[12] ? txcmm :\n"
    "                               fixctl[14] ? bpcmm :\n"
    "                               fixctl[15] ? scrcmm :\n"
    "                               fixctl[16] ? modcmm :\n"
    "                               fixctl[17] ? rrccmm :\n"
    "                               Receiver_beatfix_viol_latch_1;")


def patch_qpsktx(path):
    s = open(path).read()
    if 'bpBit' in s:
        return 'already'
    assert 'txFrameStart' in s, f'{path}: apply txcap_inject.py first (no txFrameStart)'

    # port list: append after txFrameStart
    s = s.replace("           txFrameStart);",
                  "           txFrameStart,\n"
                  "           bpBit,\n"
                  "           bpValid,\n"
                  "           scrBit,\n"
                  "           scrValid,\n"
                  "           modRe,\n"
                  "           modIm,\n"
                  "           modValid);", 1)
    assert 'bpValid);' in s or 'modValid);' in s, 'QPSK_Tx port list patch failed'

    # port decls: append after the txFrameStart output decl
    s = s.replace(
        "  output  txFrameStart;  // sfix16_En14\n",
        "  output  txFrameStart;  // sfix16_En14\n"
        "  output  bpBit;\n"
        "  output  bpValid;\n"
        "  output  scrBit;\n"
        "  output  scrValid;\n"
        "  output  signed [15:0] modRe;\n"
        "  output  signed [15:0] modIm;\n"
        "  output  modValid;\n", 1)
    assert '  output  bpValid;\n' in s, 'QPSK_Tx port decl patch failed'

    s = s.rstrip()
    assert 'endmodule' in s
    i = s.rindex('endmodule')
    tail = (
        "  assign bpBit    = Bit_Packetizer_bitsOut;\n"
        "  assign bpValid  = Bit_Packetizer_bitsValid;\n"
        "  assign scrBit   = HDL_Data_Scrambler_dataOut;\n"
        "  assign scrValid = HDL_Data_Scrambler_validOut;\n"
        "  assign modRe    = QPSKConstellationPoints_re;\n"
        "  assign modIm    = QPSKConstellationPoints_im;\n"
        "  assign modValid = QPSKConstellationValid;\n\n"
    )
    s = s[:i] + tail + s[i:] + "\n"
    assert s.count('bpBit') >= 3 and s.count('modValid') >= 3, 'QPSK_Tx tap assigns failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_transmitter(path):
    s = open(path).read()
    if 'bpBit' in s:
        return 'already'
    assert 'txFrameStart' in s, f'{path}: apply txcap_inject.py first (no txFrameStart)'

    s = s.replace("           txFrameStart);",
                  "           txFrameStart,\n"
                  "           bpBit,\n"
                  "           bpValid,\n"
                  "           scrBit,\n"
                  "           scrValid,\n"
                  "           modRe,\n"
                  "           modIm,\n"
                  "           modValid);", 1)
    s = s.replace(
        "  output  txFrameStart;\n",
        "  output  txFrameStart;\n"
        "  output  bpBit;\n"
        "  output  bpValid;\n"
        "  output  scrBit;\n"
        "  output  scrValid;\n"
        "  output  signed [15:0] modRe;\n"
        "  output  signed [15:0] modIm;\n"
        "  output  modValid;\n", 1)
    assert '  output  bpValid;\n' in s, 'Transmitter port decl patch failed'

    s = s.replace(
        ".txFrameStart(txFrameStart)\n                                      );",
        ".txFrameStart(txFrameStart),\n"
        "                                      .bpBit(bpBit),\n"
        "                                      .bpValid(bpValid),\n"
        "                                      .scrBit(scrBit),\n"
        "                                      .scrValid(scrValid),\n"
        "                                      .modRe(modRe),\n"
        "                                      .modIm(modIm),\n"
        "                                      .modValid(modValid)\n"
        "                                      );", 1)
    assert '.bpBit(bpBit)' in s, 'Transmitter instantiation patch failed'
    open(path, 'w').write(s)
    return 'patched'


def patch_composite(path):
    s = open(path).read()
    if 'bpcap_process' in s:
        return 'already'
    assert 'txcap_process' in s, f'{path}: apply txcap_inject.py first (no txcap_process)'
    assert FIXCTL_COUNT in s and FIXCTL_LATCH in s, 'TXCAP fixctl assigns not found -- apply txcap_inject.py first'

    # new wires for the Transmitter instance
    s = s.replace(
        "  wire Transmitter_txFrameStart;\n",
        "  wire Transmitter_txFrameStart;\n"
        "  wire Transmitter_bpBit;\n"
        "  wire Transmitter_bpValid;\n"
        "  wire Transmitter_scrBit;\n"
        "  wire Transmitter_scrValid;\n"
        "  wire signed [15:0] Transmitter_modRe;\n"
        "  wire signed [15:0] Transmitter_modIm;\n"
        "  wire Transmitter_modValid;\n", 1)
    assert 'wire Transmitter_bpBit;' in s, 'composite wire decl patch failed'

    # Transmitter instantiation: extend the txFrameStart port connection
    s = s.replace(
        ".txFrameStart(Transmitter_txFrameStart)\n                                              );",
        ".txFrameStart(Transmitter_txFrameStart),\n"
        "                                              .bpBit(Transmitter_bpBit),\n"
        "                                              .bpValid(Transmitter_bpValid),\n"
        "                                              .scrBit(Transmitter_scrBit),\n"
        "                                              .scrValid(Transmitter_scrValid),\n"
        "                                              .modRe(Transmitter_modRe),\n"
        "                                              .modIm(Transmitter_modIm),\n"
        "                                              .modValid(Transmitter_modValid)\n"
        "                                              );", 1)
    assert '.bpBit(Transmitter_bpBit)' in s, 'composite Transmitter instantiation patch failed'

    # insert the four capture blocks + extended mux right where TXCAP's mux was
    s = s.replace(FIXCTL_COUNT, ALL_BLOCKS + "\n" + NEW_COUNT, 1)
    s = s.replace(FIXCTL_LATCH, NEW_LATCH, 1)
    assert 'bpcap_process' in s and 'scrcap_process' in s and 'modcap_process' in s and 'rrccap_process' in s
    assert 'fixctl[17] ? rrccapl' in s and 'fixctl[17] ? rrccmm' in s
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
    print(f"TXINT_INJECT files={n}")
    return 0 if n else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
