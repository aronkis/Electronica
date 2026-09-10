#!/usr/bin/env python3
"""ddrcap_inject.py <netlist_dir> -- DDR RAW CAPTURE: five new top-level IP
ports (ddrcap_i, ddrcap_q, ddrcap_mark_demod, ddrcap_mark_fec, ddrcap_valid)
carrying any-of-12 selectable datapath taps plus both frame markers, so raw
samples/bits can be compared against marker POSITION directly instead of only
a 32-bit digest of hard decisions (see docs/superpowers/specs/
2026-08-31-ddr-raw-capture-design.md).

Design decision recorded here because it deviates from a literal reading of
the plan ("widen the existing iq_debug_mux decode"): the EXISTING iq_debug_mux
(0x10C) decode inside QPSK_Rx that DBGCAP taps via Index_Vector_out1_re/im is
NOT renumbered. DBGCAP's sim gate (sim_final.cpp) hardcodes register value 3
expecting the OLD mapping (constellation) and checks digest 0xBCF94856; a
renumber would silently change what that value selects and break the golden
check while looking like a harmless RTL change. Instead:

  - iq_debug_mux bits [3:0]   -- UNCHANGED legacy 4-way DBGCAP selector.
    (Compares were widened from full-32-bit equality to a [3:0] slice compare
    so a nonzero value in bits [19:16] -- see next line -- doesn't silently
    knock DBGCAP onto its P1cDtc fallback. Mapping 0/1/2/3 is bit-identical
    to before the patch.)
  - iq_debug_mux bits [19:16] -- NEW 12-way ddrcap selector (spec sec 4.2).

Both decodes read the same register and run simultaneously; DBGCAP and ddrcap
can be pointed at different taps in the same run, which Task 5's cross-check
(ddrcap sel 6 vs DBGCAP tap 3, both = constellation) requires anyway.

Selector map (QPSK_Rx.v / TxRxComposite.v):
  0 dataIn (TX output under loopback)   1 AGC out            2 RRC rx out
  3 postSymbolSync                      4 postCoarseFreq*    5 postCarrierSync
  6 QPSKConstellationPoints (demod in)  7 QPSK_Modulator out (TX)
  8 TX RRC out (Transmitter_dataOutI/Q) 9 demod coded bits (packed, Sec 4.3)
  10 FEC bitsIn (packed)                11 Bit_Packetizer/Scrambler out (packed)
  * new port, added to Frequency_and_Time_Synchronizer.v following the exact
    pattern that module already uses for postSymbolSync/postCarrierSync.

Markers (ddrcap_mark_demod = QPSK_Demodulator_startOut, ddrcap_mark_fec =
startSel) are carried on their OWN top-level ports, independent of the
selected tap, sampled every packer beat (Global Constraints: never packed
into a data bit). Because all four eventual packer channels share ONE valid
(ddrcap_valid = the selected tap's own valid), a marker whose native pulse
cycle does not coincide with that valid -- guaranteed for the bit-domain taps,
whose valid only fires once per 16 bits -- would otherwise be silently
dropped, which is exactly the "dropped strobe reads as a lag jump" failure
the whole build exists to prevent. So both markers are STICKY-until-captured:
a pulse sets a latch; the latch clears on the next captured (ddrcap_valid)
beat, whether or not that beat's cycle is the pulse's own cycle.

Bit-domain packing (selectors 9-11): a 16-bit shift register accumulates 16
successive valid bits MSB-first and pulses ddrcap_valid for one cycle when
full; no bit is stolen for a marker (markers have their own channels, see
above), matching Sec 4.3's "do not zero-extend one bit per word."

Files patched, both as loose HDL and inside both TxRxCompo_ip_v1_0.zip
archives (Vivado synthesises the zip copy, not the loose one):
  QPSK_Tx.v, Transmitter.v                    -- expose TX-side taps
  Frequency_and_Time_Synchronizer.v           -- new postCoarseFreq_re/im port
  QPSK_Rx.v, Receiver.v                       -- expose RX-side taps
  TxRxComposite.v                             -- 12-way mux, bit packer,
                                                  sticky markers, 5 new ports
"""
import sys, os, re, io, zipfile

# --------------------------------------------------------------------------
# QPSK_Tx.v -- expose QPSK_Modulator out (sel 7) and scrambler out (sel 11).
# --------------------------------------------------------------------------

def patch_qpsk_tx(path):
    s = open(path).read()
    if 'modOut_re' in s:
        return 'already'
    assert 'txFrameStart' in s, f'QPSK_Tx.v: txFrameStart missing (apply txcap_inject.py first) in {path}'
    for need in ('QPSKConstellationPoints_re', 'QPSKConstellationValid',
                 'HDL_Data_Scrambler_dataOut', 'HDL_Data_Scrambler_validOut'):
        assert need in s, f'anchor missing in {path}: {need}'

    s = s.replace("           txFrameStart);",
                  "           txFrameStart,\n"
                  "           modOut_re,\n"
                  "           modOut_im,\n"
                  "           modValid,\n"
                  "           scramBit,\n"
                  "           scramValid);", 1)
    s = s.replace("  output  txFrameStart;  // sfix16_En14",
                  "  output  txFrameStart;  // sfix16_En14\n"
                  "  output  signed [15:0] modOut_re;  // sfix16_En15\n"
                  "  output  signed [15:0] modOut_im;  // sfix16_En15\n"
                  "  output  modValid;\n"
                  "  output  scramBit;\n"
                  "  output  scramValid;", 1)
    if 'output  signed [15:0] modOut_re;' not in s:
        # port decl style differs between generations -- anchor off txFrameStart plainly
        m = re.search(r"\n  output [^\n]*txFrameStart;[^\n]*\n", s)
        assert m, 'QPSK_Tx txFrameStart output decl not found'
        s = (s[:m.end()] +
             "  output  signed [15:0] modOut_re;  // sfix16_En15\n"
             "  output  signed [15:0] modOut_im;  // sfix16_En15\n"
             "  output  modValid;\n"
             "  output  scramBit;\n"
             "  output  scramValid;\n" + s[m.end():])

    s = s.rstrip()
    i = s.rindex('endmodule')
    tail = ("  assign modOut_re  = QPSKConstellationPoints_re;\n"
            "  assign modOut_im  = QPSKConstellationPoints_im;\n"
            "  assign modValid   = QPSKConstellationValid;\n"
            "  assign scramBit   = HDL_Data_Scrambler_dataOut;\n"
            "  assign scramValid = HDL_Data_Scrambler_validOut;\n\n")
    s = s[:i] + tail + s[i:] + "\n"
    assert s.count('modOut_re') >= 3 and s.count('scramBit') >= 3, 'QPSK_Tx ddrcap patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# Transmitter.v -- pass QPSK_Tx's new ports straight through.
# --------------------------------------------------------------------------

def patch_transmitter(path):
    s = open(path).read()
    if 'modOut_re' in s:
        return 'already'
    assert 'txFrameStart' in s, f'Transmitter.v: txFrameStart missing in {path}'

    s = s.replace("           txFrameStart);",
                  "           txFrameStart,\n"
                  "           modOut_re,\n"
                  "           modOut_im,\n"
                  "           modValid,\n"
                  "           scramBit,\n"
                  "           scramValid);", 1)
    s = s.replace("  output  txFrameStart;",
                  "  output  txFrameStart;\n"
                  "  output  signed [15:0] modOut_re;  // sfix16_En15\n"
                  "  output  signed [15:0] modOut_im;  // sfix16_En15\n"
                  "  output  modValid;\n"
                  "  output  scramBit;\n"
                  "  output  scramValid;", 1)
    s = s.replace(".txFrameStart(txFrameStart)\n                                      )",
                  ".txFrameStart(txFrameStart),\n"
                  "                                      .modOut_re(modOut_re),\n"
                  "                                      .modOut_im(modOut_im),\n"
                  "                                      .modValid(modValid),\n"
                  "                                      .scramBit(scramBit),\n"
                  "                                      .scramValid(scramValid)\n"
                  "                                      )", 1)
    assert '.modOut_re(modOut_re)' in s, 'Transmitter u_QPSK_Tx instantiation not patched'
    assert s.count('modOut_re') >= 3, 'Transmitter ddrcap patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# Frequency_and_Time_Synchronizer.v -- new postCoarseFreq_re/im port,
# following the module's own postSymbolSync/postCarrierSync pattern exactly.
# --------------------------------------------------------------------------

def patch_fts(path):
    s = open(path).read()
    if 'postCoarseFreq_re' in s:
        return 'already'
    for need in ('postCarrierSync_re', 'postCarrierSync_im',
                 'Coarse_Frequency_Compensator_dataOut_re',
                 'Coarse_Frequency_Compensator_dataOut_im'):
        assert need in s, f'anchor missing in {path}: {need}'

    s = s.replace("           postCarrierSync_im,\n",
                  "           postCarrierSync_im,\n"
                  "           postCoarseFreq_re,\n"
                  "           postCoarseFreq_im,\n"
                  "           carrierSyncValid,\n"
                  "           symSyncValid,\n"
                  "           coarseFreqValid,\n", 1)
    s = s.replace("  output  signed [15:0] postCarrierSync_im;  // sfix16_En14\n",
                  "  output  signed [15:0] postCarrierSync_im;  // sfix16_En14\n"
                  "  output  signed [15:0] postCoarseFreq_re;  // sfix16_En14\n"
                  "  output  signed [15:0] postCoarseFreq_im;  // sfix16_En14\n"
                  "  output  carrierSyncValid;\n"
                  "  output  symSyncValid;\n"
                  "  output  coarseFreqValid;\n", 1)
    # symSyncValid/coarseFreqValid: review finding 3 -- selectors 3 (postSymbolSync)
    # and 4 (postCoarseFreq) were sampled on the downstream QPSKConstellationValid,
    # exactly the borrowed-valid defect that made selector 5 read zero (fixed
    # above via carrierSyncValid). Symbol_Synchronizer_validOut and Coarse_
    # Frequency_Compensator_validOut are each stage's own native valid, already
    # wired internally to feed the next stage's validIn -- same fix, same pattern.
    s = s.replace("  assign postCarrierSync_im = Carrier_Synchronizer_dataOut_im;\n",
                  "  assign postCarrierSync_im = Carrier_Synchronizer_dataOut_im;\n\n"
                  "  assign postCoarseFreq_re = Coarse_Frequency_Compensator_dataOut_re;\n\n"
                  "  assign postCoarseFreq_im = Coarse_Frequency_Compensator_dataOut_im;\n\n"
                  "  assign carrierSyncValid = Carrier_Synchronizer_validOut;\n\n"
                  "  assign symSyncValid = Symbol_Synchronizer_validOut;\n\n"
                  "  assign coarseFreqValid = Coarse_Frequency_Compensator_validOut;\n", 1)
    assert s.count('postCoarseFreq_re') >= 3 and s.count('postCoarseFreq_im') >= 3, \
        'Frequency_and_Time_Synchronizer postCoarseFreq patch failed'
    assert s.count('carrierSyncValid') >= 3, \
        'Frequency_and_Time_Synchronizer carrierSyncValid patch failed'
    assert s.count('symSyncValid') >= 3 and s.count('coarseFreqValid') >= 3, \
        'Frequency_and_Time_Synchronizer symSyncValid/coarseFreqValid patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# QPSK_Rx.v -- widen postCoarseFreq through, narrow the legacy mux compares
# to [3:0] (mapping unchanged), and expose every RX-domain ddrcap tap.
# --------------------------------------------------------------------------

QPSK_RX_NEW_PORTS = [
    ("ddrcap_agc_re", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_agc_im", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_agc_valid", "", ""),
    ("ddrcap_rrc_re", "signed [15:0]", "sfix16_En12"),
    ("ddrcap_rrc_im", "signed [15:0]", "sfix16_En12"),
    ("ddrcap_rrc_valid", "", ""),
    ("ddrcap_symsync_re", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_symsync_im", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_symsync_valid", "", ""),
    ("ddrcap_coarsefreq_re", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_coarsefreq_im", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_coarsefreq_valid", "", ""),
    ("ddrcap_carriersync_re", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_carriersync_im", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_carriersync_valid", "", ""),
    ("ddrcap_constpts_re", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_constpts_im", "signed [15:0]", "sfix16_En14"),
    ("ddrcap_symvalid", "", ""),
    ("ddrcap_demodbit", "", ""),
    ("ddrcap_demodvalid", "", ""),
    ("ddrcap_demodstart", "", ""),
    ("ddrcap_fecstart", "", ""),
]


def patch_qpsk_rx(path):
    s = open(path).read()
    if 'ddrcap_agc_re' in s:
        return 'already'
    for need in ('Index_Vector_out1_re', 'debugMuxCtrl_1', 'QPSKConstellationValid',
                 'QPSK_Demodulator_startOut', 'startSel', 'RRC_Receive_Filter_out2',
                 'Automatic_Gain_Control_validOut'):
        assert need in s, f'anchor missing in {path}: {need}'

    # -- postCoarseFreq + native valids: wire decl + instantiation connection
    s = s.replace(
        "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCarrierSync_im;  // sfix16_En14\n",
        "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCarrierSync_im;  // sfix16_En14\n"
        "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCoarseFreq_re;  // sfix16_En14\n"
        "  wire signed [15:0] Frequency_and_Time_Synchronizer_postCoarseFreq_im;  // sfix16_En14\n"
        "  wire Frequency_and_Time_Synchronizer_carrierSyncValid;\n"
        "  wire Frequency_and_Time_Synchronizer_symSyncValid;\n"
        "  wire Frequency_and_Time_Synchronizer_coarseFreqValid;\n", 1)
    s = s.replace(
        "                                                                                      .postCarrierSync_im(Frequency_and_Time_Synchronizer_postCarrierSync_im),  // sfix16_En14\n",
        "                                                                                      .postCarrierSync_im(Frequency_and_Time_Synchronizer_postCarrierSync_im),  // sfix16_En14\n"
        "                                                                                      .postCoarseFreq_re(Frequency_and_Time_Synchronizer_postCoarseFreq_re),  // sfix16_En14\n"
        "                                                                                      .postCoarseFreq_im(Frequency_and_Time_Synchronizer_postCoarseFreq_im),  // sfix16_En14\n"
        "                                                                                      .carrierSyncValid(Frequency_and_Time_Synchronizer_carrierSyncValid),\n"
        "                                                                                      .symSyncValid(Frequency_and_Time_Synchronizer_symSyncValid),\n"
        "                                                                                      .coarseFreqValid(Frequency_and_Time_Synchronizer_coarseFreqValid),\n", 1)
    assert 'Frequency_and_Time_Synchronizer_postCoarseFreq_re' in s
    assert 'Frequency_and_Time_Synchronizer_carrierSyncValid' in s
    assert 'Frequency_and_Time_Synchronizer_symSyncValid' in s
    assert 'Frequency_and_Time_Synchronizer_coarseFreqValid' in s

    # -- narrow the legacy 4-way mux compares to a [3:0] slice --------------
    for val in ('00000000000000000000000000000000',
                '00000000000000000000000000000001',
                '00000000000000000000000000000010',
                '00000000000000000000000000000011'):
        old = f"debugMuxCtrl_1 == 32'b{val}"
        assert old in s, f'legacy mux compare not found for {val[-4:]} in {path}'
        new = f"debugMuxCtrl_1[3:0] == 4'b{val[-4:]}"
        s = s.replace(old, new)
    assert "debugMuxCtrl_1[3:0] == 4'b0011" in s, 'legacy mux narrowing failed'

    # -- new top-level ddrcap ports: port list + I/O decls ------------------
    port_list = "".join(f"           {n},\n" for n, _, _ in QPSK_RX_NEW_PORTS)
    s = s.replace("           beatfix_viol_count,\n           beatfix_viol_latch);",
                  "           beatfix_viol_count,\n           beatfix_viol_latch,\n"
                  + port_list.rstrip().rstrip(",") + ");", 1)

    decls = ""
    for n, w, tag in QPSK_RX_NEW_PORTS:
        if w:
            decls += f"  output  {w} {n};  // {tag}\n"
        else:
            decls += f"  output  {n};\n"
    s = s.replace("  output  [31:0] beatfix_viol_latch;  // uint32\n",
                  "  output  [31:0] beatfix_viol_latch;  // uint32\n" + decls, 1)

    # -- assigns, just before endmodule -------------------------------------
    assigns = (
        "\n  // ==================================================================\n"
        "  // 2026-08-31 DDRCAP -- RX-domain tap exposure (ddrcap_inject.py).\n"
        "  // Selectors 9 and 10 (demod coded bits / FEC bitsIn) are the SAME net\n"
        "  // at this wiring level (bitsIn is fed directly from the demodulator's\n"
        "  // dataOut with no intervening buffer) -- reported honestly, not hidden.\n"
        "  // Selectors 3/4/5 each use their OWN stage's native valid (review\n"
        "  // finding 3): a shared downstream QPSKConstellationValid silently\n"
        "  // corrupts sample-to-symbol-index mapping for stages upstream of it.\n"
        "  // ==================================================================\n"
        "  assign ddrcap_agc_re = Automatic_Gain_Control_dataOut_re;\n"
        "  assign ddrcap_agc_im = Automatic_Gain_Control_dataOut_im;\n"
        "  assign ddrcap_agc_valid = Automatic_Gain_Control_validOut;\n"
        "  assign ddrcap_rrc_re = RRC_Receive_Filter_out1_re;\n"
        "  assign ddrcap_rrc_im = RRC_Receive_Filter_out1_im;\n"
        "  assign ddrcap_rrc_valid = RRC_Receive_Filter_out2;\n"
        "  assign ddrcap_symsync_re = Frequency_and_Time_Synchronizer_postSymbolSync_re;\n"
        "  assign ddrcap_symsync_im = Frequency_and_Time_Synchronizer_postSymbolSync_im;\n"
        "  assign ddrcap_symsync_valid = Frequency_and_Time_Synchronizer_symSyncValid;\n"
        "  assign ddrcap_coarsefreq_re = Frequency_and_Time_Synchronizer_postCoarseFreq_re;\n"
        "  assign ddrcap_coarsefreq_im = Frequency_and_Time_Synchronizer_postCoarseFreq_im;\n"
        "  assign ddrcap_coarsefreq_valid = Frequency_and_Time_Synchronizer_coarseFreqValid;\n"
        "  assign ddrcap_carriersync_re = Frequency_and_Time_Synchronizer_postCarrierSync_re;\n"
        "  assign ddrcap_carriersync_im = Frequency_and_Time_Synchronizer_postCarrierSync_im;\n"
        "  assign ddrcap_carriersync_valid = Frequency_and_Time_Synchronizer_carrierSyncValid;\n"
        "  assign ddrcap_constpts_re = QPSKConstellationPoints_re;\n"
        "  assign ddrcap_constpts_im = QPSKConstellationPoints_im;\n"
        "  assign ddrcap_symvalid = QPSKConstellationValid;\n"
        "  assign ddrcap_demodbit = QPSK_Demodulator_dataOut;\n"
        "  assign ddrcap_demodvalid = QPSK_Demodulator_validOut;\n"
        "  assign ddrcap_demodstart = QPSK_Demodulator_startOut;\n"
        "  assign ddrcap_fecstart = startSel;\n\n"
    )
    # module type name is prefixed (TxRxCompo_ip_src_QPSK_Rx) inside the IP
    # zip -- anchor on the LAST 'endmodule' in the file, not its trailing
    # comment, so this works for both the loose and the zip-packaged copy.
    assert '\nendmodule' in s
    j = s.rindex('\nendmodule')
    s = s[:j] + '\n' + assigns.rstrip('\n') + s[j:]

    assert 'ddrcap_fecstart = startSel' in s, 'QPSK_Rx ddrcap patch failed'
    assert 'ddrcap_symsync_valid = Frequency_and_Time_Synchronizer_symSyncValid' in s
    assert 'ddrcap_coarsefreq_valid = Frequency_and_Time_Synchronizer_coarseFreqValid' in s
    open(path, 'w').write(s)
    return 'patched'


def patch_receiver(path):
    s = open(path).read()
    if 'ddrcap_agc_re' in s:
        return 'already'
    for need in ('u_QPSK_Rx', 'beatfix_viol_latch', 'QPSK_Rx_beatfix_viol_latch'):
        assert need in s, f'anchor missing in {path}: {need}'

    port_list = "".join(f"           {n},\n" for n, _, _ in QPSK_RX_NEW_PORTS)
    s = s.replace("           beatfix_viol_count,\n           beatfix_viol_latch);",
                  "           beatfix_viol_count,\n           beatfix_viol_latch,\n"
                  + port_list.rstrip().rstrip(",") + ");", 1)

    decls = ""
    for n, w, tag in QPSK_RX_NEW_PORTS:
        if w:
            decls += f"  output  {w} {n};  // {tag}\n"
        else:
            decls += f"  output  {n};\n"
    s = s.replace("  output  [31:0] beatfix_viol_latch;  // uint32\n",
                  "  output  [31:0] beatfix_viol_latch;  // uint32\n" + decls, 1)

    # instantiation: connect u_QPSK_Rx's new ports straight to local wires
    inst_conn = "".join(f"                                      .{n}(QPSK_Rx_{n}),\n" for n, _, _ in QPSK_RX_NEW_PORTS)
    s = s.replace(
        "                                      .beatfix_viol_count(QPSK_Rx_beatfix_viol_count),  // uint32\n"
        "                                      .beatfix_viol_latch(QPSK_Rx_beatfix_viol_latch)  // uint32\n"
        "                                      );",
        "                                      .beatfix_viol_count(QPSK_Rx_beatfix_viol_count),  // uint32\n"
        "                                      .beatfix_viol_latch(QPSK_Rx_beatfix_viol_latch),  // uint32\n"
        + inst_conn.rstrip().rstrip(',') + "\n                                      );", 1)
    assert '.ddrcap_agc_re(QPSK_Rx_ddrcap_agc_re)' in s, 'Receiver u_QPSK_Rx instantiation not patched'

    wire_decls = ""
    for n, w, tag in QPSK_RX_NEW_PORTS:
        if w:
            wire_decls += f"  wire {w} QPSK_Rx_{n};  // {tag}\n"
        else:
            wire_decls += f"  wire QPSK_Rx_{n};\n"
    s = s.replace("  wire [31:0] QPSK_Rx_beatfix_viol_latch;  // uint32\n",
                  "  wire [31:0] QPSK_Rx_beatfix_viol_latch;  // uint32\n" + wire_decls, 1)

    assigns = "".join(f"  assign {n} = QPSK_Rx_{n};\n" for n, _, _ in QPSK_RX_NEW_PORTS)
    # module type name is prefixed inside the IP zip -- anchor on the LAST
    # 'endmodule' in the file rather than its trailing comment.
    assert '\nendmodule' in s
    j = s.rindex('\nendmodule')
    s = s[:j] + '\n' + assigns.rstrip('\n') + '\n' + s[j:]

    assert s.count('ddrcap_fecstart') >= 3, 'Receiver ddrcap patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# TxRxComposite.v -- the 12-way mux, bit packer, sticky markers, and the
# five new top-level IP ports.
# --------------------------------------------------------------------------

COMPOSITE_BLOCK = """
  // ==================================================================
  // 2026-08-31 DDRCAP -- raw per-block capture to the idle RX2 packer chain
  // (ddrcap_inject.py). Five new top-level ports: ddrcap_i, ddrcap_q,
  // ddrcap_mark_demod, ddrcap_mark_fec, ddrcap_valid. Selector is
  // iq_debug_mux[19:16] (bits [3:0] stay the untouched legacy DBGCAP
  // selector -- see the injector's module docstring). See spec sec 4.1-4.4.
  // ==================================================================
  reg  [3:0] ddrcap_sel_r;

  always @(posedge clk or posedge reset)
    begin : ddrcap_sel_process
      if (reset == 1'b1) begin
        ddrcap_sel_r <= 4'd0;
      end
      else if (enb_1_2_0) begin
        ddrcap_sel_r <= iq_debug_mux[19:16];
      end
    end

  // sample/symbol-domain (sel 0-8) data + valid mux. sel3/4/5 each use
  // their own stage's native valid (review finding 3) rather than the
  // downstream QPSKConstellationValid, which silently offsets the
  // sample-to-symbol-index mapping for stages upstream of it -- exactly
  // what made sel5 read zero before that fix. sel8 (TX RRC out) is left
  // on enb_1_2_0 deliberately, NOT a leftover free-run: RRC_Transmit_Filter
  // (see RRC_Transmit_Filter.v) has no validOut port at all, so there is no
  // finer-grained native valid to borrow, and Transmitter_dataOutI/Q is
  // unconditionally updated every enb_1_2_0 tick by construction (a
  // continuously-running pulse-shaping interpolator). Checked and rejected:
  // TxRxComposite's own tx_validOut port is NOT this stage's valid -- it is
  // wired to host_txValid_1, the EXTERNAL host-byte-injection path's valid,
  // an unrelated net; connecting it here would be wrong, not a fix.
  wire signed [15:0] ddrcap_mux_i =
      (ddrcap_sel_r == 4'd0) ? MUX_RxI_out1 :
      (ddrcap_sel_r == 4'd1) ? Receiver_ddrcap_agc_re :
      (ddrcap_sel_r == 4'd2) ? Receiver_ddrcap_rrc_re :
      (ddrcap_sel_r == 4'd3) ? Receiver_ddrcap_symsync_re :
      (ddrcap_sel_r == 4'd4) ? Receiver_ddrcap_coarsefreq_re :
      (ddrcap_sel_r == 4'd5) ? Receiver_ddrcap_carriersync_re :
      (ddrcap_sel_r == 4'd6) ? Receiver_ddrcap_constpts_re :
      (ddrcap_sel_r == 4'd7) ? Transmitter_modOut_re :
      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :
      16'sd0;
  wire signed [15:0] ddrcap_mux_q =
      (ddrcap_sel_r == 4'd0) ? MUX_RxQ_out1 :
      (ddrcap_sel_r == 4'd1) ? Receiver_ddrcap_agc_im :
      (ddrcap_sel_r == 4'd2) ? Receiver_ddrcap_rrc_im :
      (ddrcap_sel_r == 4'd3) ? Receiver_ddrcap_symsync_im :
      (ddrcap_sel_r == 4'd4) ? Receiver_ddrcap_coarsefreq_im :
      (ddrcap_sel_r == 4'd5) ? Receiver_ddrcap_carriersync_im :
      (ddrcap_sel_r == 4'd6) ? Receiver_ddrcap_constpts_im :
      (ddrcap_sel_r == 4'd7) ? Transmitter_modOut_im :
      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :
      16'sd0;
  wire ddrcap_mux_valid =
      (ddrcap_sel_r == 4'd0) ? MUX_RxValid_out1 :
      (ddrcap_sel_r == 4'd1) ? Receiver_ddrcap_agc_valid :
      (ddrcap_sel_r == 4'd2) ? Receiver_ddrcap_rrc_valid :
      (ddrcap_sel_r == 4'd3) ? Receiver_ddrcap_symsync_valid :
      (ddrcap_sel_r == 4'd4) ? Receiver_ddrcap_coarsefreq_valid :
      (ddrcap_sel_r == 4'd5) ? Receiver_ddrcap_carriersync_valid :
      (ddrcap_sel_r == 4'd6) ? Receiver_ddrcap_symvalid :
      (ddrcap_sel_r == 4'd7) ? Transmitter_modValid :
      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :
      1'b0;

  // bit-domain (sel 9-11) source bit/valid/frame-marker mux
  wire ddrcap_bitsel_bit =
      (ddrcap_sel_r == 4'd9)  ? Receiver_ddrcap_demodbit :
      (ddrcap_sel_r == 4'd10) ? Receiver_ddrcap_demodbit :
      (ddrcap_sel_r == 4'd11) ? Transmitter_scramBit : 1'b0;
  wire ddrcap_bitsel_valid =
      (ddrcap_sel_r == 4'd9)  ? Receiver_ddrcap_demodvalid :
      (ddrcap_sel_r == 4'd10) ? Receiver_ddrcap_demodvalid :
      (ddrcap_sel_r == 4'd11) ? Transmitter_scramValid : 1'b0;

  // 16-bit-per-word bit packer (Sec 4.3): 16 successive valid bits, MSB
  // first, no bit stolen for a marker -- markers ride their own channels.
  reg  [15:0] ddrcap_bitpack;
  reg  [3:0]  ddrcap_bitcnt;
  reg         ddrcap_bitword_rdy;
  reg  [15:0] ddrcap_bitword;

  always @(posedge clk or posedge reset)
    begin : ddrcap_bitpack_process
      if (reset == 1'b1) begin
        ddrcap_bitpack <= 16'h0000;
        ddrcap_bitcnt  <= 4'h0;
        ddrcap_bitword_rdy <= 1'b0;
        ddrcap_bitword <= 16'h0000;
      end
      else if (enb_1_2_0) begin
        ddrcap_bitword_rdy <= 1'b0;
        if (ddrcap_sel_r >= 4'd9 && ddrcap_sel_r <= 4'd11 && ddrcap_bitsel_valid) begin
          if (ddrcap_bitcnt == 4'd15) begin
            ddrcap_bitword <= {ddrcap_bitpack[14:0], ddrcap_bitsel_bit};
            ddrcap_bitword_rdy <= 1'b1;
            ddrcap_bitcnt <= 4'd0;
          end
          else begin
            ddrcap_bitpack <= {ddrcap_bitpack[14:0], ddrcap_bitsel_bit};
            ddrcap_bitcnt  <= ddrcap_bitcnt + 4'd1;
          end
        end
      end
    end

  // NOTE (bug found in sim gate, fixed here): the underlying valid/ready
  // signals this mux reads (MUX_RxValid_out1, *_validOut, ddrcap_bitword_rdy,
  // ...) are registers clocked on posedge clk but updated only when
  // enb_1_2_0 is asserted -- the multi-rate-clocking convention this whole
  // design uses (see the ce_out_0/ce_out_1 sample-time comment block at the
  // top of this file: ce_out_1 is 2x the rate of ce_out_0, i.e. TWO raw clk
  // edges occur per enb_1_2_0-qualified update). A bare continuous assign of
  // ddrcap_valid_beat is therefore HIGH across BOTH of those raw clk cycles
  // (the update edge, then the held-over cycle before the next enb_1_2_0),
  // not just one -- which double-counted every marker pulse and would make
  // the real packer write every captured word to DDR twice. AND with
  // enb_1_2_0 so ddrcap_valid pulses exactly once per genuine sample/word,
  // matching how every OTHER capture block in this file (DBGCAP, TXCAP,
  // DEMODCAP) already gates its own sampling with `else if (enb_1_2_0)`.
  wire ddrcap_valid_beat = (ddrcap_sel_r <= 4'd8) ? ddrcap_mux_valid : ddrcap_bitword_rdy;

  assign ddrcap_valid = ddrcap_valid_beat && enb_1_2_0;
  assign ddrcap_i = (ddrcap_sel_r <= 4'd8) ? ddrcap_mux_i : ddrcap_bitword;
  assign ddrcap_q = (ddrcap_sel_r <= 4'd8) ? ddrcap_mux_q : 16'sd0;

  // Sticky-until-captured frame markers (both new top-level ports). A marker
  // whose native pulse cycle does not land on a ddrcap_valid_beat -- the
  // normal case for the bit-domain taps, whose valid fires once per 16 bits
  // -- would otherwise vanish, which is exactly the dropped-strobe/lag-jump
  // failure the Global Constraints forbid. The latch holds a pending marker
  // across cycles and clears on the beat that captures it, never earlier.
  reg  ddrcap_demod_mark_latch;
  reg  ddrcap_fec_mark_latch;
  wire ddrcap_demod_mark_now = Receiver_ddrcap_demodstart | ddrcap_demod_mark_latch;
  wire ddrcap_fec_mark_now   = @FECMARK@   | ddrcap_fec_mark_latch;

  always @(posedge clk or posedge reset)
    begin : ddrcap_mark_process
      if (reset == 1'b1) begin
        ddrcap_demod_mark_latch <= 1'b0;
        ddrcap_fec_mark_latch   <= 1'b0;
      end
      else if (enb_1_2_0) begin
        ddrcap_demod_mark_latch <= ddrcap_valid_beat ? 1'b0 : ddrcap_demod_mark_now;
        ddrcap_fec_mark_latch   <= ddrcap_valid_beat ? 1'b0 : ddrcap_fec_mark_now;
      end
    end

  assign ddrcap_mark_demod = ddrcap_demod_mark_now ? 16'h7FFF : 16'h0000;
  assign ddrcap_mark_fec   = ddrcap_fec_mark_now   ? 16'h7FFF : 16'h0000;
"""


def patch_composite(path):
    s = open(path).read()
    if 'ddrcap_sel_process' in s:
        # Already patched. The ONE thing that may still need changing is the
        # FEC-marker source, because TXMARK repoints it (§58). Returning
        # 'already' unconditionally would silently leave a tree on the old
        # marker and produce an image that looks patched and answers nothing.
        import re as _re
        cur = _re.search(r'wire ddrcap_fec_mark_now\s+=\s+(\w+)', s)
        if cur and cur.group(1) != FECMARK_SRC:
            s2 = _re.sub(r'(wire ddrcap_fec_mark_now\s+=\s+)\w+',
                         r'\g<1>' + FECMARK_SRC, s, count=1)
            assert FECMARK_SRC in s2, 'FEC-marker retarget failed'
            open(path, 'w').write(s2)
            return 'retargeted->' + FECMARK_SRC
        return 'already'
    for need in ('MUX_RxI_out1', 'MUX_RxQ_out1', 'MUX_RxValid_out1', 'u_Receiver', 'u_Transmitter',
                 'Transmitter_dataOutI', 'Transmitter_dataOutQ',
                 '.beatfix_viol_latch(Receiver_beatfix_viol_latch)  // uint32\n                                        );'):
        assert need in s, f'anchor missing in {path}: {need[:50]}'

    # -- top-level port list + I/O decls -------------------------------------
    s = s.replace("           beatfix_viol_count,\n           beatfix_viol_latch);",
                  "           beatfix_viol_count,\n           beatfix_viol_latch,\n"
                  "           ddrcap_i,\n"
                  "           ddrcap_q,\n"
                  "           ddrcap_mark_demod,\n"
                  "           ddrcap_mark_fec,\n"
                  "           ddrcap_valid);", 1)
    s = s.replace("  output  [31:0] beatfix_viol_latch;  // uint32\n",
                  "  output  [31:0] beatfix_viol_latch;  // uint32\n"
                  "  output  signed [15:0] ddrcap_i;  // int16\n"
                  "  output  signed [15:0] ddrcap_q;  // int16\n"
                  "  output  [15:0] ddrcap_mark_demod;  // uint16\n"
                  "  output  [15:0] ddrcap_mark_fec;  // uint16\n"
                  "  output  ddrcap_valid;\n", 1)

    # -- u_Receiver instantiation: pull in the 19 new RX-domain taps --------
    recv_wires = "".join(
        f"  wire {w if w else ''}{' ' if w else ''}Receiver_{n};" if False else
        (f"  wire {w} Receiver_{n};  // {tag}\n" if w else f"  wire Receiver_{n};\n")
        for n, w, tag in QPSK_RX_NEW_PORTS)
    s = s.replace("  wire MUX_RxValid_out1;\n",
                  "  wire MUX_RxValid_out1;\n" + recv_wires, 1)

    recv_conn = "".join(f"                                        .{n}(Receiver_{n}),\n" for n, _, _ in QPSK_RX_NEW_PORTS)
    old_recv_tail = ("                                        .beatfix_viol_count(Receiver_beatfix_viol_count),  // uint32\n"
                      "                                        .beatfix_viol_latch(Receiver_beatfix_viol_latch)  // uint32\n"
                      "                                        );")
    assert old_recv_tail in s, 'u_Receiver instantiation tail anchor not found'
    new_recv_tail = ("                                        .beatfix_viol_count(Receiver_beatfix_viol_count),  // uint32\n"
                      "                                        .beatfix_viol_latch(Receiver_beatfix_viol_latch),  // uint32\n"
                      + recv_conn.rstrip().rstrip(',') + "\n                                        );")
    s = s.replace(old_recv_tail, new_recv_tail, 1)
    assert '.ddrcap_agc_re(Receiver_ddrcap_agc_re)' in s, 'u_Receiver ddrcap wiring failed'

    # -- u_Transmitter instantiation: pull in modOut/scram taps --------------
    s = s.replace("  wire signed [15:0] Transmitter_dataOutQ;  // int16\n",
                  "  wire signed [15:0] Transmitter_dataOutQ;  // int16\n"
                  "  wire signed [15:0] Transmitter_modOut_re;  // sfix16_En15\n"
                  "  wire signed [15:0] Transmitter_modOut_im;  // sfix16_En15\n"
                  "  wire Transmitter_modValid;\n"
                  "  wire Transmitter_scramBit;\n"
                  "  wire Transmitter_scramValid;\n", 1)
    s = s.replace(".dataOutQ(Transmitter_dataOutQ),  // int16\n"
                  "                                              .extWordPop(Transmitter_extWordPop),\n"
                  "                                              .txFrameStart(Transmitter_txFrameStart)\n"
                  "                                              );",
                  ".dataOutQ(Transmitter_dataOutQ),  // int16\n"
                  "                                              .extWordPop(Transmitter_extWordPop),\n"
                  "                                              .txFrameStart(Transmitter_txFrameStart),\n"
                  "                                              .modOut_re(Transmitter_modOut_re),\n"
                  "                                              .modOut_im(Transmitter_modOut_im),\n"
                  "                                              .modValid(Transmitter_modValid),\n"
                  "                                              .scramBit(Transmitter_scramBit),\n"
                  "                                              .scramValid(Transmitter_scramValid)\n"
                  "                                              );", 1)
    assert '.modOut_re(Transmitter_modOut_re)' in s, 'u_Transmitter ddrcap wiring failed'

    # -- the mux/packer/marker block + final assigns -------------------------
    s = s.rstrip()
    i = s.rindex('endmodule')
    # Resolve the FEC-marker source HERE, at use time. It cannot be interpolated
    # inside COMPOSITE_BLOCK -- that is a plain triple-quoted literal, and an
    # attempt to do so emitted the text `" + FECMARK_SRC + "` straight into the
    # Verilog. Caught by inspecting the emitted string before building.
    block = COMPOSITE_BLOCK.replace('@FECMARK@', FECMARK_SRC)
    assert '@FECMARK@' not in block, 'FEC-marker token not substituted'
    s = s[:i] + block + "\n" + s[i:] + "\n"

    assert 'ddrcap_sel_process' in s and 'ddrcap_mark_process' in s
    open(path, 'w').write(s)
    return 'patched'




# --------------------------------------------------------------------------
# TxRxCompo_ip_dut.v -- the DUT wrapper directly inside the IP: instantiates
# TxRxComposite and re-exports its outputs as its own ports (same shape as
# TxRxComposite's own re-export of Receiver -- beatfix_viol_count/latch
# pattern). Required per code review finding 1: without this, the five new
# TxRxComposite ports terminate one level below the IP boundary and get
# optimised away by synthesis, a silently-identical-to-unpatched result.
# --------------------------------------------------------------------------

def patch_dut(path):
    s = open(path).read()
    if 'ddrcap_i' in s:
        return 'already'
    for need in ('beatfix_viol_count', 'beatfix_viol_latch'):
        assert need in s, f'anchor missing in {path}: {need}'

    s = s.replace("           beatfix_viol_count,\n           beatfix_viol_latch);",
                  "           beatfix_viol_count,\n           beatfix_viol_latch,\n"
                  "           ddrcap_i,\n"
                  "           ddrcap_q,\n"
                  "           ddrcap_mark_demod,\n"
                  "           ddrcap_mark_fec,\n"
                  "           ddrcap_valid);", 1)
    s = s.replace("  output  [31:0] beatfix_viol_latch;  // ufix32\n",
                  "  output  [31:0] beatfix_viol_latch;  // ufix32\n"
                  "  output  signed [15:0] ddrcap_i;  // sfix16\n"
                  "  output  signed [15:0] ddrcap_q;  // sfix16\n"
                  "  output  [15:0] ddrcap_mark_demod;  // ufix16\n"
                  "  output  [15:0] ddrcap_mark_fec;  // ufix16\n"
                  "  output  ddrcap_valid;  // ufix1\n", 1)
    s = s.replace("  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
                  "  wire [31:0] beatfix_viol_latch_sig;  // ufix32\n",
                  "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
                  "  wire [31:0] beatfix_viol_latch_sig;  // ufix32\n"
                  "  wire signed [15:0] ddrcap_i_sig;  // sfix16\n"
                  "  wire signed [15:0] ddrcap_q_sig;  // sfix16\n"
                  "  wire [15:0] ddrcap_mark_demod_sig;  // ufix16\n"
                  "  wire [15:0] ddrcap_mark_fec_sig;  // ufix16\n"
                  "  wire ddrcap_valid_sig;  // ufix1\n", 1)
    old_inst_tail = ("                                                                   .beatfix_viol_count(beatfix_viol_count_sig),  // ufix32\n"
                      "                                                                   .beatfix_viol_latch(beatfix_viol_latch_sig)  // ufix32\n"
                      "                                                                   );")
    assert old_inst_tail in s, 'TxRxCompo_ip_dut instantiation tail anchor not found'
    new_inst_tail = ("                                                                   .beatfix_viol_count(beatfix_viol_count_sig),  // ufix32\n"
                      "                                                                   .beatfix_viol_latch(beatfix_viol_latch_sig),  // ufix32\n"
                      "                                                                   .ddrcap_i(ddrcap_i_sig),\n"
                      "                                                                   .ddrcap_q(ddrcap_q_sig),\n"
                      "                                                                   .ddrcap_mark_demod(ddrcap_mark_demod_sig),\n"
                      "                                                                   .ddrcap_mark_fec(ddrcap_mark_fec_sig),\n"
                      "                                                                   .ddrcap_valid(ddrcap_valid_sig)\n"
                      "                                                                   );")
    s = s.replace(old_inst_tail, new_inst_tail, 1)

    anchor = "  assign beatfix_viol_latch = beatfix_viol_latch_sig;\n"
    assert anchor in s, 'TxRxCompo_ip_dut tail-assign anchor not found'
    tail_assigns = ("\n  assign ddrcap_i = ddrcap_i_sig;\n\n"
                     "  assign ddrcap_q = ddrcap_q_sig;\n\n"
                     "  assign ddrcap_mark_demod = ddrcap_mark_demod_sig;\n\n"
                     "  assign ddrcap_mark_fec = ddrcap_mark_fec_sig;\n\n"
                     "  assign ddrcap_valid = ddrcap_valid_sig;\n")
    s = s.replace(anchor, anchor + tail_assigns, 1)

    assert s.count('ddrcap_i_sig') >= 3 and 'ddrcap_valid = ddrcap_valid_sig' in s, \
        'TxRxCompo_ip_dut ddrcap patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# TxRxCompo_ip.v -- the actual packaged IP top (matches the .zip's own name).
# Physical pins here use the IP's generic dut_data_out_N_rx/tx naming
# convention (e.g. debugI/debugQ/debugI1/debugQ1 -> dut_data_out_0..3_rx);
# five NEW, clearly-named physical pins are added here rather than
# continuing that opaque numbering, to avoid any risk of colliding with an
# existing consumer of dut_data_out_N_rx. This is the file whose ports
# Task 3's BD script actually needs (TxRxCompo_ip_0/dut_ddrcap_i etc. --
# the dut_ prefix is what the BD sees; see ddrcap_bd.tcl).
# --------------------------------------------------------------------------

def patch_ip_top(path):
    s = open(path).read()
    if 'dut_ddrcap_i' in s:
        return 'already'
    for need in ('dut_data_out_3_rx', 'beatfix_viol_count_sig', 'beatfix_viol_latch_sig'):
        assert need in s, f'anchor missing in {path}: {need}'

    s = s.replace("           dut_data_out_3_rx,\n",
                  "           dut_data_out_3_rx,\n"
                  "           dut_ddrcap_i,\n"
                  "           dut_ddrcap_q,\n"
                  "           dut_ddrcap_mark_demod,\n"
                  "           dut_ddrcap_mark_fec,\n"
                  "           dut_ddrcap_valid,\n", 1)
    s = s.replace("  output  [15:0] dut_data_out_3_rx;  // ufix16\n",
                  "  output  [15:0] dut_data_out_3_rx;  // ufix16\n"
                  "  output  [15:0] dut_ddrcap_i;  // sfix16\n"
                  "  output  [15:0] dut_ddrcap_q;  // sfix16\n"
                  "  output  [15:0] dut_ddrcap_mark_demod;  // ufix16\n"
                  "  output  [15:0] dut_ddrcap_mark_fec;  // ufix16\n"
                  "  output  dut_ddrcap_valid;  // ufix1\n", 1)
    s = s.replace("  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
                  "  wire [31:0] beatfix_viol_latch_sig;  // ufix32\n",
                  "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
                  "  wire [31:0] beatfix_viol_latch_sig;  // ufix32\n"
                  "  wire signed [15:0] ddrcap_i_sig;  // sfix16\n"
                  "  wire signed [15:0] ddrcap_q_sig;  // sfix16\n"
                  "  wire [15:0] ddrcap_mark_demod_sig;  // ufix16\n"
                  "  wire [15:0] ddrcap_mark_fec_sig;  // ufix16\n"
                  "  wire ddrcap_valid_sig;  // ufix1\n", 1)

    old_inst_tail = ("                                            .beatfix_viol_count(beatfix_viol_count_sig),  // ufix32\n"
                      "                                            .beatfix_viol_latch(beatfix_viol_latch_sig)  // ufix32\n"
                      "                                            );")
    assert old_inst_tail in s, 'u_TxRxCompo_ip_dut_inst instantiation tail anchor not found'
    new_inst_tail = ("                                            .beatfix_viol_count(beatfix_viol_count_sig),  // ufix32\n"
                      "                                            .beatfix_viol_latch(beatfix_viol_latch_sig),  // ufix32\n"
                      "                                            .ddrcap_i(ddrcap_i_sig),\n"
                      "                                            .ddrcap_q(ddrcap_q_sig),\n"
                      "                                            .ddrcap_mark_demod(ddrcap_mark_demod_sig),\n"
                      "                                            .ddrcap_mark_fec(ddrcap_mark_fec_sig),\n"
                      "                                            .ddrcap_valid(ddrcap_valid_sig)\n"
                      "                                            );")
    s = s.replace(old_inst_tail, new_inst_tail, 1)

    anchor2 = "  assign dut_data_out_3_rx = debugQ_sig;\n"
    assert anchor2 in s, 'dut_data_out_3_rx assign anchor not found'
    tail_assigns = ("\n  assign dut_ddrcap_i = ddrcap_i_sig;\n\n"
                     "  assign dut_ddrcap_q = ddrcap_q_sig;\n\n"
                     "  assign dut_ddrcap_mark_demod = ddrcap_mark_demod_sig;\n\n"
                     "  assign dut_ddrcap_mark_fec = ddrcap_mark_fec_sig;\n\n"
                     "  assign dut_ddrcap_valid = ddrcap_valid_sig;\n")
    s = s.replace(anchor2, anchor2 + tail_assigns, 1)

    assert s.count('dut_ddrcap_i') >= 3 and 'dut_ddrcap_valid = ddrcap_valid_sig' in s, \
        'TxRxCompo_ip.v ddrcap patch failed'
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# component.xml -- Vivado IP-packager metadata. Declares TxRxCompo_ip.v's
# physical pins (the dut_* names) as <spirit:port> entries; without this,
# Vivado's IP packager does not know the five new HDL ports exist and they
# cannot be wired in the BD (Task 3: TxRxCompo_ip_0/dut_ddrcap_i etc.). Only
# ever present inside the IP zip, never as a loose file.
# --------------------------------------------------------------------------

XML_PORT_TEMPLATE_VEC = """      <spirit:port>
        <spirit:name>{name}</spirit:name>
        <spirit:wire>
          <spirit:direction>out</spirit:direction>
          <spirit:vector>
            <spirit:left spirit:format="long">15</spirit:left>
            <spirit:right spirit:format="long">0</spirit:right>
          </spirit:vector>
          <spirit:wireTypeDefs>
            <spirit:wireTypeDef>
              <spirit:typeName>std_logic_vector</spirit:typeName>
              <spirit:viewNameRef>xilinx_anylanguagesynthesis</spirit:viewNameRef>
              <spirit:viewNameRef>xilinx_anylanguagebehavioralsimulation</spirit:viewNameRef>
            </spirit:wireTypeDef>
          </spirit:wireTypeDefs>
        </spirit:wire>
      </spirit:port>
"""

XML_PORT_TEMPLATE_BIT = """      <spirit:port>
        <spirit:name>{name}</spirit:name>
        <spirit:wire>
          <spirit:direction>out</spirit:direction>
          <spirit:wireTypeDefs>
            <spirit:wireTypeDef>
              <spirit:typeName>std_logic</spirit:typeName>
              <spirit:viewNameRef>xilinx_anylanguagesynthesis</spirit:viewNameRef>
              <spirit:viewNameRef>xilinx_anylanguagebehavioralsimulation</spirit:viewNameRef>
            </spirit:wireTypeDef>
          </spirit:wireTypeDefs>
        </spirit:wire>
      </spirit:port>
"""


# TXMARK=1 repoints the FEC-marker capture channel at Transmitter_txFrameStart,
# giving a TX-anchored marker beside the RX-anchored demod marker. That is the
# §45 discriminator: with both, one frame decides whether the data moved or the
# marker moved. §45 showed the two RX markers are coincident BY CONSTRUCTION
# (FEC startIn derives from demod startOut), so the FEC channel is redundant and
# is the natural one to give up. Default off, so the change is reversible.
FECMARK_SRC = ('Transmitter_txFrameStart' if os.environ.get('TXMARK') == '1'
               else 'Receiver_ddrcap_fecstart')


def patch_component_xml(path):
    s = open(path).read()
    if 'dut_ddrcap_i' in s:
        return 'already'
    anchor = ("      <spirit:port>\n"
              "        <spirit:name>dut_data_out_3_rx</spirit:name>\n"
              "        <spirit:wire>\n"
              "          <spirit:direction>out</spirit:direction>\n"
              "          <spirit:vector>\n"
              "            <spirit:left spirit:format=\"long\">15</spirit:left>\n"
              "            <spirit:right spirit:format=\"long\">0</spirit:right>\n"
              "          </spirit:vector>\n"
              "          <spirit:wireTypeDefs>\n"
              "            <spirit:wireTypeDef>\n"
              "              <spirit:typeName>std_logic_vector</spirit:typeName>\n"
              "              <spirit:viewNameRef>xilinx_anylanguagesynthesis</spirit:viewNameRef>\n"
              "              <spirit:viewNameRef>xilinx_anylanguagebehavioralsimulation</spirit:viewNameRef>\n"
              "            </spirit:wireTypeDef>\n"
              "          </spirit:wireTypeDefs>\n"
              "        </spirit:wire>\n"
              "      </spirit:port>\n")
    assert anchor in s, 'component.xml dut_data_out_3_rx port block anchor not found'
    new_ports = (XML_PORT_TEMPLATE_VEC.format(name='dut_ddrcap_i')
                 + XML_PORT_TEMPLATE_VEC.format(name='dut_ddrcap_q')
                 + XML_PORT_TEMPLATE_VEC.format(name='dut_ddrcap_mark_demod')
                 + XML_PORT_TEMPLATE_VEC.format(name='dut_ddrcap_mark_fec')
                 + XML_PORT_TEMPLATE_BIT.format(name='dut_ddrcap_valid'))
    s = s.replace(anchor, anchor + new_ports, 1)
    assert s.count('dut_ddrcap_i') >= 1 and 'dut_ddrcap_valid' in s, 'component.xml ddrcap patch failed'
    import xml.dom.minidom as minidom
    minidom.parseString(s)  # raises on malformed XML
    open(path, 'w').write(s)
    return 'patched'


# --------------------------------------------------------------------------
# driver: walk loose files, then patch matching members inside both zips.
# --------------------------------------------------------------------------

PATCHERS = {
    ('QPSK_Tx.v', 'TxRxCompo_ip_src_QPSK_Tx.v'): patch_qpsk_tx,
    ('Transmitter.v', 'TxRxCompo_ip_src_Transmitter.v'): patch_transmitter,
    ('Frequency_and_Time_Synchronizer.v', 'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v'): patch_fts,
    ('QPSK_Rx.v', 'TxRxCompo_ip_src_QPSK_Rx.v'): patch_qpsk_rx,
    ('Receiver.v', 'TxRxCompo_ip_src_Receiver.v'): patch_receiver,
    ('TxRxComposite.v', 'TxRxCompo_ip_src_TxRxComposite.v'): patch_composite,
    # IP-boundary files (review finding 1): same filename loose and inside the
    # zip for dut.v/TxRxCompo_ip.v; component.xml exists only inside the zip.
    ('TxRxCompo_ip_dut.v',): patch_dut,
    ('TxRxCompo_ip.v',): patch_ip_top,
    ('component.xml',): patch_component_xml,
}


def _patcher_for(fname):
    for names, fn in PATCHERS.items():
        if fname in names:
            return fn
    return None


def patch_zip(zpath):
    """Patch the matching hdl/TxRxCompo_ip_src_*.v members in place."""
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r')
    entries = []
    n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        base = os.path.basename(item.filename)
        fn = _patcher_for(base)
        if fn is not None:
            tmp_dir = zpath + '.ddrcap_tmp'
            os.makedirs(tmp_dir, exist_ok=True)
            tmp_path = os.path.join(tmp_dir, base)
            open(tmp_path, 'wb').write(data)
            status = fn(tmp_path)
            data = open(tmp_path, 'rb').read()
            os.remove(tmp_path)
            os.rmdir(tmp_dir)
            print(f"    zip member {base:45s} {status:8s} ({os.path.basename(zpath)})")
            n += 1
        entries.append((item, data))
    zin.close()

    out_buf = io.BytesIO()
    zout = zipfile.ZipFile(out_buf, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close()
    open(zpath, 'wb').write(out_buf.getvalue())
    return n


# The exact set of members every zip MUST contain and verify. A zip that is
# missing one of these (wrong lineage, renamed, IP repackaged differently)
# must FAIL LOUDLY -- review finding 2: a patcher that reports success while
# patching nothing (or patching only some of what matters) is the same class
# of instrument fault as a counter that never increments.
EXPECTED_ZIP_MEMBERS = {
    'TxRxCompo_ip_src_QPSK_Tx.v': 'scramValid',
    'TxRxCompo_ip_src_Transmitter.v': 'modOut_re',
    'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v': 'postCoarseFreq_re',
    'TxRxCompo_ip_src_QPSK_Rx.v': 'ddrcap_fecstart',
    'TxRxCompo_ip_src_Receiver.v': 'ddrcap_fecstart',
    'TxRxCompo_ip_src_TxRxComposite.v': 'ddrcap_mark_process',
    'TxRxCompo_ip_dut.v': 'ddrcap_valid_sig',
    'TxRxCompo_ip.v': 'dut_ddrcap_valid',
    'component.xml': 'dut_ddrcap_valid',
}

# Expected loose (non-zip) source files, expressed PER LOGICAL FILE with
# both accepted basenames -- a sim tree (s1_rtl_*) uses the unprefixed name
# (QPSK_Rx.v); a real build tree's hdlsrc/commhdlQPSKTxRxLoopback uses the
# PREFIXED name even for the loose (non-zip) copy (TxRxCompo_ip_src_QPSK_Rx.v)
# -- confirmed by walking a real build tree, which has no unprefixed sources
# at all. Set-equality against one fixed naming false-FAILs on whichever tree
# layout it wasn't written for (re-review finding 3); subset/any-of semantics
# per logical file works for both. TxRxCompo_ip_dut.v and TxRxCompo_ip.v are
# never prefixed in either layout.
EXPECTED_LOOSE_GROUPS = [
    ('QPSK_Tx', {'QPSK_Tx.v', 'TxRxCompo_ip_src_QPSK_Tx.v'}),
    ('Transmitter', {'Transmitter.v', 'TxRxCompo_ip_src_Transmitter.v'}),
    ('Frequency_and_Time_Synchronizer', {'Frequency_and_Time_Synchronizer.v',
                                          'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v'}),
    ('QPSK_Rx', {'QPSK_Rx.v', 'TxRxCompo_ip_src_QPSK_Rx.v'}),
    ('Receiver', {'Receiver.v', 'TxRxCompo_ip_src_Receiver.v'}),
    ('TxRxComposite', {'TxRxComposite.v', 'TxRxCompo_ip_src_TxRxComposite.v'}),
    ('TxRxCompo_ip_dut', {'TxRxCompo_ip_dut.v'}),
    ('TxRxCompo_ip', {'TxRxCompo_ip.v'}),
]

EXPECTED_ZIP_COUNT = 2


def verify_zip(zpath):
    zin = zipfile.ZipFile(zpath, 'r')
    found = {}
    for item in zin.infolist():
        base = os.path.basename(item.filename)
        if base in EXPECTED_ZIP_MEMBERS:
            found[base] = zin.read(item.filename).decode()
    zin.close()

    missing = sorted(EXPECTED_ZIP_MEMBERS.keys() - found.keys())
    if missing:
        print(f"    VERIFY_FAIL {zpath}: missing member(s) {missing}")
        return False

    ok = True
    for base, marker in EXPECTED_ZIP_MEMBERS.items():
        if marker not in found[base]:
            print(f"    VERIFY_FAIL {base} in {zpath}: missing {marker}")
            ok = False
    return ok


def main(d):
    found_loose = set()
    for root, _, files in os.walk(d):
        if root.endswith('.ddrcap_tmp'):
            continue
        for f in files:
            fn = _patcher_for(f)
            if fn is None:
                continue
            p = os.path.join(root, f)
            # `component.xml` is the ONE dispatch key that is not unique to this
            # IP: a real build tree carries dozens belonging to unrelated cores
            # (axi_dmac, axi_sysid, every bd/mref/* reference IP). Dispatching on
            # the bare filename sent those into patch_component_xml, whose anchor
            # assert then killed the whole walk mid-tree. Scope it by path.
            if f == 'component.xml' and 'TxRxCompo_ip' not in p:
                continue
            print(f"  {f:45s} {fn.__name__:20s} -> ", end='')
            status = fn(p)
            print(f"{status:8s} {p}")
            found_loose.add(f)

    n_zip = 0
    n_zip_verified = 0
    n_zips_found = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                n_zips_found += 1
                zp = os.path.join(root, f)
                print(f"  zip {zp}")
                n_zip += patch_zip(zp)
                if verify_zip(zp):
                    n_zip_verified += 1
                    print(f"    VERIFY_OK {zp}")

    # Subset/any-of semantics per logical file (re-review finding 3): a real
    # build tree's loose copies are PREFIXED, a sim tree's are not: neither
    # naming should be treated as "missing" just because the other exists.
    missing_groups = [name for name, names in EXPECTED_LOOSE_GROUPS if not (names & found_loose)]
    loose_ok = not missing_groups
    loose_seen_any = bool(found_loose)

    print(f"DDRCAP_INJECT loose_files={len(found_loose)} logical_groups_satisfied="
          f"{len(EXPECTED_LOOSE_GROUPS) - len(missing_groups)}/{len(EXPECTED_LOOSE_GROUPS)} "
          f"zip_members_patched={n_zip} zips_verified={n_zip_verified}/{n_zips_found}")

    if loose_seen_any and not loose_ok:
        print(f"DDRCAP_INJECT_FAIL: loose tree found {sorted(found_loose)} but is missing "
              f"a match for logical file(s) {missing_groups}")
        return 1

    if n_zips_found > 0 and n_zips_found != EXPECTED_ZIP_COUNT:
        print(f"DDRCAP_INJECT_FAIL: expected {EXPECTED_ZIP_COUNT} zips, found {n_zips_found}")
        return 1

    # A tree that LOOKS like a Vivado IP build tree (has an ipcore dir, a
    # vivado_ip_prj dir, or an .xpr project file anywhere under it) MUST have
    # zips, and they must all verify -- Vivado synthesises the zip copy, not
    # the loose one, so patching only the loose tree of a build target is
    # exactly "reports success while the built RTL is the old one" (review
    # finding 2, the third time this specific failure has been found here).
    looks_like_build_tree = False
    for root, dirs, files in os.walk(d):
        if os.path.basename(root) in ('ipcore', 'vivado_ip_prj'):
            looks_like_build_tree = True
            break
        if any(f.endswith('.xpr') for f in files):
            looks_like_build_tree = True
            break

    if looks_like_build_tree and n_zips_found == 0:
        print("DDRCAP_INJECT_FAIL: tree looks like a Vivado IP build tree "
              "(ipcore/vivado_ip_prj/*.xpr present) but no TxRxCompo_ip_v1_0.zip was found -- "
              "zips are mandatory here, since Vivado synthesises the zip copy.")
        return 1

    zips_present_and_ok = n_zips_found == 0 or (n_zip_verified == n_zips_found)

    # Both halves must hold, not either: a complete loose tree can no longer
    # mask a zip set that was found but failed to verify (re-review finding
    # 2 reproduced this exact case: loose_ok=True, zips_verified=0/2, old
    # code's `or` returned success anyway).
    ok = loose_ok and zips_present_and_ok
    if not ok:
        reasons = []
        if not loose_ok:
            reasons.append("loose tree incomplete")
        if not zips_present_and_ok:
            reasons.append(f"zips found ({n_zips_found}) but only {n_zip_verified} verified")
        print(f"DDRCAP_INJECT_FAIL: {'; '.join(reasons) if reasons else 'nothing that matters was patched'}.")
        return 1
    return 0
if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
