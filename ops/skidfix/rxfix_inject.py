#!/usr/bin/env python3
"""rxfix_inject.py <netlist_dir> R1|R2|R3|R3S|R4|R4B|R4D|R4E|W1|BS|PAD [--sim-tree] -- RX symbol-rate-offset fix injector
(plan /home/tcollins/.claude/plans/happy-bubbling-owl.md, T2; ledger
two_jup/sdd_archive/2026-09-04-rxfix/progress.md).

Netlist patch (by design: regenerating from Simulink would overwrite it) for the
~32-frame receiver frame-loss comb at a few ppm of inter-node sample-rate offset.

  R1  Preamble_Detector.v -- make the 12,333-deep realignment FIFO's pop
      VALID-indexed instead of enb-tick-indexed.

      Baseline: the FIFO's data delay is realised as
          push = Delay8_out1                       (the symbol valid)
          pop  = Delay10_out1 = Delay10_reg[49331] (that same valid delayed
                                                    49,332 enb_1_2_0 TICKS)
      49,332 ticks equal 12,333 valids ONLY while the valid density is exactly
      1-in-4.  Every Rate_Handle EMPTY-edge event (pop_on_empty_FIFO,
      Validate_Input_Push_Pop_block.v:119 -- one per 32.4 air frames at
      -2.5 ppm) punches a permanent hole in that density, so for the one epoch
      the hole is in flight the delay is 12,332 valids, not 12,333.  Peak_Search
      counts valids on the UNDELAYED chain (Peak_Search.v:94) and Timing_Adjust
      counts valids on the DELAYED chain (Timing_Adjust.v:126) while comparing
      against Peak_Search's timingOffset (Timing_Adjust.v:153) -- so the phase
      between the two epoch spaces moves by one symbol for that epoch.  What
      that phase step then does to the frame start is traced in [sim]
      two_jup/comb/COMB32_SRO_FIX_SIM.md 1.3.

      Fix: pop the FIFO by OCCUPANCY.  numEntries is the registered occupancy
      (Validate_Input_Push_Pop.v:143 -> FIFO.v:201), and the ring guard keeps it
      in 0..12333, so `numEntries == 12333` is exactly "full".  Popping on
      `push & full` makes the delay exactly 12,333 VALIDS for ever, which is what
      every downstream epoch counter already assumes.

          - assign Delay10_out1 = Delay10_reg[49331];
          + assign Delay10_full = FIFO_numEntries == 14'd12333;
          + assign Delay10_out1 = Delay8_out1 & Delay10_full;

      Nominal identity that makes this a no-op on a defect-free stream: at exact
      1-in-4 valid density the 12,333rd push after any push lands exactly 49,332
      ticks later, so the two pop streams are the same beats -- the s = 0 sim leg
      is gated bit-identical to baseline.

      Guard interaction (unchanged, still exact): push_on_full_FIFO =
      push & ~valid_pop & full (Validate_Input_Push_Pop.v:131).  Under R1 a push
      while full always carries its own pop, so valid_pop = 1 and push_on_full can
      no longer fire at all -- the FIFO deletes nothing by construction.

      Resources: Delay10_reg (49,332 flip-flops) loses its only reader and is
      trimmed; the patch adds one 14-bit equality comparator plus an AND.  See
      the resource note in two_jup/comb/COMB32_SRO_FIX_SIM.md for the build
      driver.

Idempotent: the patcher returns 'already' when the RXFIX_R1 marker is present.
Loose .v files are patched in place (basename, or the TxRxCompo_ip_src_ prefixed
name used inside the Vivado IP kit); TxRxCompo_ip_v1_0.zip members are patched and
re-verified exactly as txfix_inject.py / ddrcap2_inject.py do.

--sim-tree patches a bare Verilator source tree (one loose copy, no IP kit, no
zips): it relaxes the "a build kit must carry two zips" rule and instead asserts
exactly one loose copy of each file.
"""
import sys, os, io, re, zipfile

MARKER = 'RXFIX_R1'
MARKER_R2 = 'RXFIX_R2'
MARKER_R3 = 'RXFIX_R3'
MARKER_R3S = 'RXFIX_R3S'   # NB: 'RXFIX_R3' is a PREFIX of it -- see _has()
MARKER_R4 = 'RXFIX_R4'


def _has(s, marker):
    """True iff `marker` appears in `s` as a whole token.

    Task 11 added RXFIX_R3S, whose marker string CONTAINS RXFIX_R3.  A plain
    `MARKER_R3 in s` would then report an R3S-patched file as already carrying
    R3 (and verify_zip would certify an R3S kit as an R3 kit).  Matching on a
    token boundary removes the collision; on every file that existed before
    Task 11 the two tests are identical, because no such file contains
    RXFIX_R3S.
    """
    return re.search(marker + r'(?![0-9A-Za-z_])', s) is not None


def _sub(s, old, new, what):
    """Replace `old` by `new`, asserting the anchor occurs EXACTLY once."""
    n = s.count(old)
    assert n == 1, f"anchor for {what} occurs {n} times (want exactly 1): {old.strip()[:70]!r}"
    return s.replace(old, new, 1)


# ---------------------------------------------------------- R1: Preamble_Detector.v
PD_DECL_OLD = "  wire Delay10_out1;\n"
PD_DECL_NEW = ("  wire Delay10_out1;\n"
               "  wire Delay10_full;  // RXFIX_R1: FIFO_numEntries == 12333\n")

PD_ASSIGN_OLD = "  assign Delay10_out1 = Delay10_reg[49331];\n"
PD_ASSIGN_NEW = """  // RXFIX_R1: the realignment FIFO's pop is VALID-indexed, not enb-tick-indexed.
  // Baseline popped on Delay10_reg[49331] -- the symbol valid delayed 49,332
  // enb_1_2_0 TICKS -- which equals 12,333 valids only while the valid density
  // is exactly 1-in-4.  Every Rate_Handle EMPTY-edge event (pop_on_empty_FIFO,
  // one per 32.4 air frames at -2.5 ppm) removes one valid slot, so the data
  // delay was 12,332 valids for the epoch that hole is in flight, while
  // Peak_Search (undelayed chain, Peak_Search.v:94) and Timing_Adjust (delayed
  // chain, Timing_Adjust.v:126) both count VALIDS and compare against each
  // other.  Popping on push & full makes the delay exactly 12,333 valids for
  // ever, so the two epoch spaces can no longer move relative to one another.
  // numEntries is the registered occupancy and the guard bounds it to 0..12333,
  // so ==12333 is "full"; no combinational loop (numEntries is a register).  At
  // 1-in-4 density this is the same beat as the baseline, so s = 0 is
  // bit-identical.
  assign Delay10_full = FIFO_numEntries == 14'd12333;

  assign Delay10_out1 = Delay8_out1 & Delay10_full;
"""


def patch_preamble_detector(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER):
        return 'already'
    s = _sub(s, PD_DECL_OLD, PD_DECL_NEW, 'R1 Delay10_full declaration')
    s = _sub(s, PD_ASSIGN_OLD, PD_ASSIGN_NEW, 'R1 Delay10_out1 pop assignment')
    open(path, 'w').write(s)
    return 'patched'


# ------------------------------------------------ R2: Preamble_Detector.v flywheel
PD_R2_OLD = """  always @(posedge clk or posedge reset)
    begin : Delay11_process
      if (reset == 1'b1) begin
        Delay11_out1 <= 14'b00000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          Delay11_out1 <= Peak_Search_timingOffset;
        end
      end
    end
"""

PD_R2_NEW = """  // ---- RXFIX_R2: frame-sync flywheel on Peak_Search's epoch argmax ----
  // Peak_Search is a bare argmax over one 12,333-valid epoch (Peak_Search.v:132,
  // 145): whichever correlation sample is largest in the epoch becomes
  // timingOffset, and Timing_Adjust applies it verbatim (Timing_Adjust.v:153).
  // [sim, two_jup/comb/COMB32_SRO_FIX_SIM.md 1.3/1.3.1] under a few ppm of
  // sample-rate offset the preamble correlation arrives 32 symbols LATE in the
  // symbol stream for one sample-slip period, and 31 early on the way back -- a
  // +32/-31 round trip that nets the +1 symbol per cycle the offset really
  // requires.  It is the SAME peak throughout (one threshold crossing per epoch,
  // magnitude smooth across the excursion), so Peak_Search and Timing_Adjust are
  // both behaving correctly and the displacement is generated upstream of the
  // correlator.  Applying it moves the frame start by 32 symbols and kills the
  // frame at each transition: that, and not the valid-density hole, is the
  // 32.4-frame loss comb.  The excursion lasts 1/(4*12333*|s|) frames -- about 2
  // at -10 ppm, 7-8 at -2.5 ppm -- i.e. LONGER the SMALLER the offset.
  //
  // The flywheel therefore does NOT use a run-length escape (which would adopt
  // the excursion at small SRO, where it lasts longest).  It tracks the peak it
  // is locked to:
  //   * each epoch, search for a threshold-exceeding correlation sample within
  //     +/-PS_FW_WIN symbols of the applied offset and take the largest one;
  //   * if one exists, that becomes the applied offset (this follows the genuine
  //     +/-1 symbol walk the SRO produces) and the global argmax is ignored --
  //     the +/-32-symbol excursion is rejected for as long as a threshold-
  //     exceeding sample remains in the window, whatever the SRO;
  //   * if none exists for PS_FW_NLOST consecutive epochs, that is a loss of
  //     lock and the global argmax is adopted (re-acquisition);
  //   * cold start (ps_fw_have = 0) adopts the global argmax on the first epoch,
  //     so acquisition is bit-for-bit what it was.
  // timingOffsetValid is NOT suppressed -- Timing_Adjust must still re-arm every
  // epoch (Timing_Adjust.v:190-200) -- only the VALUE is held.
  // Witnesses: ps_fw_reject counts epochs where the flywheel overrode the global
  // argmax, ps_fw_reacq counts loss-of-lock re-acquisitions.  No port is added,
  // so the IP interface and the Vivado kit are unchanged; read them
  // hierarchically in sim, or wire them to a spare AXI/DDRCAP word later.
  localparam [13:0] PS_FW_MOD   = 14'd12333;
  localparam [13:0] PS_FW_WIN   = 14'd2;
  localparam [1:0]  PS_FW_NLOST = 2'd3;

  reg  [13:0] ps_fw_cur;
  reg         ps_fw_have;
  reg  [1:0]  ps_fw_lost;
  reg         ps_fw_seen;
  reg  [13:0] ps_fw_pos;
  reg  signed [31:0] ps_fw_max;
  reg  [31:0] ps_fw_reject;
  reg  [31:0] ps_fw_reacq;
  wire [13:0] ps_fw_cand;
  wire [13:0] ps_fw_d_a;
  wire [13:0] ps_fw_d;
  wire        ps_fw_inwin;
  wire        ps_fw_hit;
  wire        ps_fw_better;
  wire        ps_fw_track;
  wire        ps_fw_relock;
  wire [13:0] ps_fw_out;

  assign ps_fw_cand   = Peak_Search_timingOffset;
  assign ps_fw_d_a    = (Peak_Search_p1c_tref >= ps_fw_cur) ?
                        (Peak_Search_p1c_tref - ps_fw_cur) :
                        (ps_fw_cur - Peak_Search_p1c_tref);
  assign ps_fw_d      = (ps_fw_d_a > (PS_FW_MOD >> 1)) ?
                        (PS_FW_MOD - ps_fw_d_a) : ps_fw_d_a;
  assign ps_fw_inwin  = ps_fw_have & (ps_fw_d <= PS_FW_WIN);
  assign ps_fw_hit    = Correlator_validOut & Relational_Operator_out1 & ps_fw_inwin;
  assign ps_fw_better = ( ~ps_fw_seen) | (Correlator_dataOut > ps_fw_max);
  assign ps_fw_track  = ps_fw_have & ps_fw_seen;
  assign ps_fw_relock = ( ~ps_fw_have) |
                        (( ~ps_fw_seen) & (ps_fw_lost >= (PS_FW_NLOST - 2'd1)));
  assign ps_fw_out    = ps_fw_track ? ps_fw_pos :
                        (ps_fw_relock ? ps_fw_cand : ps_fw_cur);

  always @(posedge clk or posedge reset)
    begin : ps_fw_process
      if (reset == 1'b1) begin
        ps_fw_cur <= 14'b00000000000000;
        ps_fw_have <= 1'b0;
        ps_fw_lost <= 2'b00;
        ps_fw_seen <= 1'b0;
        ps_fw_pos <= 14'b00000000000000;
        ps_fw_max <= 32'sb00000000000000000000000000000000;
        ps_fw_reject <= 32'b00000000000000000000000000000000;
        ps_fw_reacq <= 32'b00000000000000000000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          if (Logical_Operator_out1) begin
            ps_fw_cur  <= ps_fw_out;
            ps_fw_have <= 1'b1;
            ps_fw_seen <= 1'b0;
            ps_fw_max  <= 32'sb00000000000000000000000000000000;
            if (ps_fw_track) begin
              ps_fw_lost <= 2'b00;
              if (ps_fw_pos != ps_fw_cand) begin
                ps_fw_reject <= ps_fw_reject + 32'b1;
              end
            end
            else begin
              if (ps_fw_relock) begin
                ps_fw_lost <= 2'b00;
                if (ps_fw_have) begin
                  ps_fw_reacq <= ps_fw_reacq + 32'b1;
                end
              end
              else begin
                ps_fw_lost <= ps_fw_lost + 2'b01;
              end
            end
          end
          else begin
            if (ps_fw_hit && ps_fw_better) begin
              ps_fw_seen <= 1'b1;
              ps_fw_max  <= Correlator_dataOut;
              ps_fw_pos  <= Peak_Search_p1c_tref;
            end
          end
        end
      end
    end

  always @(posedge clk or posedge reset)
    begin : Delay11_process
      if (reset == 1'b1) begin
        Delay11_out1 <= 14'b00000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          Delay11_out1 <= ps_fw_out;  // RXFIX_R2 (was Peak_Search_timingOffset)
        end
      end
    end
"""


def patch_preamble_detector_r2(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R2):
        return 'already'
    s = _sub(s, PD_R2_OLD, PD_R2_NEW, 'R2 Peak_Search flywheel')
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- R3: guard-band steering
# Mechanism-agnostic.  The Rate_Handle ring pops on a rigid mod-4 phase and pushes
# on the interpolator strobe, so under an SRO the occupancy drifts by 12333*s per
# air frame and eventually hits an edge.  At the EMPTY edge the guard suppresses a
# pop (Validate_Input_Push_Pop_block.v:119,121) -- one skipped valid slot -- and at
# the FULL edge it suppresses a push (:125-133) -- one DELETED symbol.  Either way
# the hole lands at an arbitrary point inside the 12,320-symbol payload window and
# the frames that straddle it die.
#
# R3 does not try to explain the death; it MOVES the hole.  Packet_Controller's
# sample_discard_controller is inactive for the 13 symbol slots between
# End_Generator's endOut and the next startIn (RATE_HANDLE_FIX_SURVEY.md 2), i.e.
# there is a per-frame window in which the deframer consumes nothing.  When the
# true occupancy is about to reach an edge, R3 pre-empts the edge INSIDE that
# window: skip one pop when occupancy <= 2 (draining, EMPTY edge ahead) or take one
# extra pop when occupancy >= 30 (filling, FULL edge ahead).  The built-in guard is
# untouched, so if the steering ever fails to pre-empt, the baseline behaviour still
# applies -- R3 can only move holes, it cannot create losses the baseline lacks.
#
# NOT claimed: that steering removes the epoch slip.  Peak_Search's
# timing_Reference, Timing_Adjust's timing_Reference and End_Generator's counter all
# count VALIDS (RATE_HANDLE_FIX_SURVEY.md 2), so a skipped valid still slips all
# three epochs by one symbol.  R3 bounds WHERE the hole lands, not what the epoch
# counters do with it; a residual is expected and is reported as measured.
#
# Phase note: Preamble_Detector's Delay10_reg delays the valid by 49,332 enb ticks =
# exactly one air frame, so the guard window observed at Rate_Handle's beat sits at
# the same intra-frame phase as the window the steered symbol meets downstream.  The
# witnesses r3_skips / r3_extras count the steered events, and the harness logs tref
# at each one so the alignment is measured rather than assumed.
#
# The IP interface is unchanged: no TxRxComposite port is added.  Seven internal
# modules gain read-only taps or one input each, all on the s1_rtl and the flashed
# txfixF3 lineages (whose port lists differ -- hence the structural helpers below,
# which insert into a port/pin list rather than matching it verbatim).

def _span(s, pat, what):
    """Return (start, index_of_closing_paren) of the paren group opened by `pat`."""
    m = re.search(pat, s)
    assert m, f"anchor for {what} not found: {pat!r}"
    assert len(re.findall(pat, s)) == 1, f"anchor for {what} is not unique: {pat!r}"
    i = m.end() - 1
    d = 0
    for j in range(i, len(s)):
        if s[j] == '(':
            d += 1
        elif s[j] == ')':
            d -= 1
            if d == 0:
                return m.start(), j
    raise AssertionError(f"unbalanced parens for {what}")


def _r3_guard(s):
    """R3 refuses to patch on top of R3S or R4 (Task 12: symmetric mutual exclusion).

    Before Task 12 only Rate_Handle failed loudly in this direction, via the
    exactly-once assert on a pop line that the other variant had already replaced;
    the remaining six files would have half-applied first.  Mutual exclusion is now
    checked on every file of the variant, in every direction.
    """
    for m in (MARKER_R3S, MARKER_R4, MARKER_R4B, MARKER_R4D, MARKER_R4E):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R3 both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


def _add_port(s, module, decl, what, tag='RXFIX_R3'):
    """Append `decl` to `module`'s port list (structural: tolerates either lineage)."""
    _, j = _span(s, r'module\s+' + module + r'\s*\(', what)
    return s[:j] + ',\n           // ' + tag + '\n           ' + decl + '\n          ' + s[j:]


def _add_pin(s, module, inst, pin, what, tag='RXFIX_R3'):
    """Append `pin` to the instantiation `module inst (...)`."""
    _, j = _span(s, r'\b' + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // ' + tag + '\n' + ' ' * 24 + s[j:]


# ---- sample_discard_controller.v: export the discard-window state -------------
def patch_sample_discard_controller_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'sample_discard_controller', 'activeOut', 'R3 sdc activeOut port')
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3: 1 while the deframer is consuming the 12,320-symbol payload\n"
             "  // window; 0 during the 13-symbol inter-frame guard (End_Generator endOut ->\n"
             "  // next startIn) in which every symbol is discarded.  Read-only tap.\n"
             "  output  activeOut;\n", 'R3 sdc activeOut declaration')
    s = _sub(s, "endmodule  // sample_discard_controller\n",
             "  assign activeOut = active;  // RXFIX_R3\n\n"
             "endmodule  // sample_discard_controller\n", 'R3 sdc activeOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Packet_Controller.v: hoist the guard out of the deframer ------------------
def patch_packet_controller_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'Packet_Controller', 'guardOut', 'R3 Packet_Controller guardOut port')
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3: 1 while the deframer is in its inter-frame guard (discarding).\n"
             "  output  guardOut;\n"
             "  wire sdc_active_r3;\n", 'R3 Packet_Controller guardOut declaration')
    s = _add_pin(s, 'sample_discard_controller', 'u_sample_discard_controller',
                 '.activeOut(sdc_active_r3)', 'R3 Packet_Controller sdc instantiation')
    s = _sub(s, "endmodule  // Packet_Controller\n",
             "  assign guardOut = ~sdc_active_r3;  // RXFIX_R3\n\n"
             "endmodule  // Packet_Controller\n", 'R3 Packet_Controller guardOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Validate_Input_Push_Pop_block.v: export the TRUE occupancy ---------------
def patch_vipp_block_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'Validate_Input_Push_Pop_block', 'occOut', 'R3 VIPP_block occOut port')
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R3: the registered TRUE ring occupancy, 0..32 (Delay_out1).\n"
             "  output  [5:0] occOut;\n", 'R3 VIPP_block occOut declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign occOut = Delay_out1;  // RXFIX_R3\n", 'R3 VIPP_block occOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- FIFO_block.v: pass the occupancy up to Rate_Handle -----------------------
def patch_fifo_block_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'FIFO_block', 'occOut', 'R3 FIFO_block occOut port')
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R3: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] occOut;\n", 'R3 FIFO_block occOut declaration')
    s = _add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                 '.occOut(occOut)', 'R3 FIFO_block VIPP instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- Rate_Handle.v: the steering itself ---------------------------------------
RH_POP_OLD = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW = """  // ---- RXFIX_R3: steer the occupancy edge into the deframer's guard window ----
  // r3_pop_nom is the baseline pop (rigid mod-4 phase).  Inside the guard, and at
  // most once per guard window:
  //   occupancy <= 2  (draining toward EMPTY)  -> SKIP one pop      (occ +1)
  //   occupancy >= 30 (filling toward FULL)    -> take one EXTRA pop (occ -1)
  // so the valid-density hole (or surplus) always lands where the deframer discards
  // symbols instead of at an arbitrary point in the payload window.  Outside the
  // guard the expression reduces to the baseline exactly, and with guardIn tied low
  // R3 is a no-op -- which is why the s = 0 leg is gated bit-identical.
  assign r3_pop_nom  = validIn & Compare_To_Constant_out1;

  assign r3_low      = r3_occ <= 6'd2;

  assign r3_high     = r3_occ >= 6'd30;

  assign r3_do_skip  = guardIn & r3_low & ( ~r3_lo_done) & r3_pop_nom;

  assign r3_do_extra = guardIn & r3_high & ( ~r3_hi_done) & validIn &
              ( ~Compare_To_Constant_out1);

  assign Logical_Operator_out1 = (r3_pop_nom & ( ~r3_do_skip)) | r3_do_extra;

  always @(posedge clk or posedge reset)
    begin : r3_steer_process
      if (reset == 1'b1) begin
        r3_lo_done <= 1'b0;
        r3_hi_done <= 1'b0;
        r3_skips <= 32'b00000000000000000000000000000000;
        r3_extras <= 32'b00000000000000000000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          if ( ~guardIn) begin
            r3_lo_done <= 1'b0;
            r3_hi_done <= 1'b0;
          end
          else begin
            if (r3_do_skip) begin
              r3_lo_done <= 1'b1;
              r3_skips <= r3_skips + 32'b1;
            end
            if (r3_do_extra) begin
              r3_hi_done <= 1'b1;
              r3_extras <= r3_extras + 32'b1;
            end
          end
        end
      end
    end
"""


def patch_rate_handle_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'Rate_Handle', 'guardIn', 'R3 Rate_Handle guardIn port')
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3: 1 during the deframer's inter-frame guard window.\n"
             "  input   guardIn;\n\n"
             "  wire [5:0] r3_occ;  // ufix6\n"
             "  wire r3_pop_nom;\n"
             "  wire r3_low;\n"
             "  wire r3_high;\n"
             "  wire r3_do_skip;\n"
             "  wire r3_do_extra;\n"
             "  reg  r3_lo_done;\n"
             "  reg  r3_hi_done;\n"
             "  reg [31:0] r3_skips;   // witness: steered pop SKIPS\n"
             "  reg [31:0] r3_extras;  // witness: steered EXTRA pops\n",
             'R3 Rate_Handle guardIn declaration')
    s = _sub(s, RH_POP_OLD, RH_POP_NEW, 'R3 Rate_Handle steered pop')
    s = _add_pin(s, 'FIFO_block', 'u_FIFO', '.occOut(r3_occ)',
                 'R3 Rate_Handle FIFO_block instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- Symbol_Synchronizer.v: route the guard down to Rate_Handle ---------------
def patch_symbol_synchronizer_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _add_port(s, 'Symbol_Synchronizer', 'guardIn', 'R3 Symbol_Synchronizer guardIn port')
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n",
             "  input   [31:0] ss_integ_gain;  // uint32\n"
             "  input   guardIn;  // RXFIX_R3: deframer inter-frame guard window\n",
             'R3 Symbol_Synchronizer guardIn declaration')
    s = _add_pin(s, 'Rate_Handle', 'u_Rate_Handle', '.guardIn(guardIn)',
                 'R3 Symbol_Synchronizer Rate_Handle instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- Frequency_and_Time_Synchronizer.v: close the loop ------------------------
def patch_freq_time_sync_r3(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3):
        return 'already'
    _r3_guard(s)
    s = _sub(s, "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             "  // RXFIX_R3: the deframer's inter-frame guard, fed back to the Rate_Handle\n"
             "  // ring.  Sourced from a register (sample_discard_controller.active), so\n"
             "  // there is no combinational loop through the receive chain.\n"
             "  wire Packet_Controller_guardOut;\n\n"
             "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             'R3 FTS guard wire declaration')
    s = _add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer',
                 '.guardIn(Packet_Controller_guardOut)', 'R3 FTS Symbol_Synchronizer instantiation')
    s = _add_pin(s, 'Packet_Controller', 'u_Packet_Controller',
                 '.guardOut(Packet_Controller_guardOut)', 'R3 FTS Packet_Controller instantiation')
    open(path, 'w').write(s)
    return 'patched'



# ============================================================ R3S: skip-only steering
# RXFIX_R3S (Task 11, brief two_jup/sdd_archive/2026-09-04-rxfix/task-11-brief.md).
#
# WHAT TASK 7 SETTLED, AND WHAT IT DID NOT.  On the certified non-repeating stimulus
# the verdict is H-B: the Rate_Handle ring reaching its EMPTY edge IS the death event
# (2.10 frames die per hole, 42 of 46 losses within +/-1 of a hole, 26.0 % post-edge
# at -10 ppm against a 22.01 % tiled control, 78.1 % at -40 ppm).  The guard already
# turns that edge into a SKIPPED POP -- a skipped time slot, not a lost symbol
# (cSS = cRH on the Task 9 census) -- so the frames die because of WHERE in the frame
# the skip lands, not because a symbol is deleted.
#
# WHY R3 WAS REJECTED, AND WHY THAT IS NOT A VERDICT ON STEERING.  Both R3 failures
# were failures of its PREDICATE:
#   1. the extra-pop branch (occ >= 30) fired during acquisition and destroyed
#      framing (r3_extras = 4 accompanied 100 % loss at -10 ppm).  An extra pop is
#      NOT the mirror image of a skipped pop: it EMITS a symbol and slips every
#      valid-counting epoch the other way.  R3S DELETES that branch outright; the
#      FULL edge / positive-SRO case is out of scope.
#   2. the low branch (occ <= 2) fired at s = 0 as well, because on the TGEN stream
#      the ring settles at occupancy ~1 after acquisition instead of the 5 the tiled
#      legs sat at.  An occupancy-threshold predicate alone cannot be inert across
#      both operating points, so R3S does not use one alone: it is ARMED, and before
#      arming it is the baseline netlist by construction.
#
# THE THREE PIECES.
#
# (a) LOCK, derivable with four flops and NO new routing.  Before the deframer has
#     ever framed a packet, sample_discard_controller.active is 0 for ever
#     (startIn comes from Preamble_Detector's synchronizedPulse), so guardIn = ~active
#     is CONSTANT 1 and never falls.  Every FALLING edge of guardIn is therefore one
#     deframer frame start, and `locked` = eight of them have been seen.  This is the
#     "N = 8 frames" arm of the brief's choice, realised without routing syncPulse
#     down two levels of hierarchy.  [sim] measured on b_p000: the first deframer
#     frame mark is at air frame 5.006 and every one of the 34 acquisition holes is
#     in air frame 0, so `locked` cannot be true at any hole on the 0 ppm leg.
#
# (b) ARM.  r3s_armed is a sticky flop set only by a POST-LOCK EMPTY edge -- the
#     guard's own pop_on_empty.  That event is reconstructed inside Rate_Handle from
#     the two signals that define it in Validate_Input_Push_Pop_block.v:118-121
#     (pop_on_empty_FIFO = Compare_To_Constant_y & pop), where
#     Compare_To_Constant_block.v:36-38 compares Delay_out1 against 6'b000000 and
#     occOut IS Delay_out1.  So r3s_pop_empty is BIT-EXACT pop_on_empty_FIFO, not an
#     approximation of it, and no extra port is needed to see it.
#
# (c) SKIP, at most one per guard window.  Packet_Controller's
#     sample_discard_controller is inactive for the 13 symbol slots between
#     End_Generator's endOut and the next startIn (RATE_HANDLE_FIX_SURVEY.md 2) -- a
#     per-frame window in which the deframer consumes nothing.  While armed, the
#     first nominal pop in that window at occupancy <= 1 is suppressed, so the
#     deficit is absorbed in the guard band BEFORE the built-in guard would suppress
#     a pop at an arbitrary point inside the 12,320-symbol payload window.  The ring
#     is thereby driven to a new operating point (occ ~2-3) at which it no longer
#     reaches EMPTY at all -- which is why rh_pop_on_empty in the scored window is
#     predicted to fall to ~0 rather than merely to move.
#
# IDENTITY, BY CONSTRUCTION AND NOT BY MEASUREMENT.  r3s_do_skip is ANDed with
# r3s_armed, so until the arm fires Logical_Operator_out1 is literally
# `validIn & Compare_To_Constant_out1` -- the baseline expression.  With guardIn tied
# low, or with no post-lock hole ever occurring, R3S is a no-op.
#
# FAILURE MODE, STATED.  If lock is lost after arming, guardIn sticks at 1, so
# r3s_skip_done latches after one skip and is never cleared: steering stops and the
# built-in guard resumes.  R3S fails TOWARD baseline; it can move holes, it cannot
# create losses the baseline lacks.
#
# NOT CLAIMED.  Peak_Search.timing_Reference, Timing_Adjust.timing_Reference and
# End_Generator's counter all count VALIDS, so a skipped valid still slips all three
# epochs by one symbol.  R3S bounds WHERE the hole lands, not what the epoch counters
# do with it.  A residual is expected and is reported as measured.
#
# The IP interface is unchanged: no TxRxComposite port is added.  Same seven internal
# modules as R3, same structural (paren-balanced) insertion so both netlist lineages
# take it despite their different port lists.

def _r3s_guard(s):
    """R3S refuses to patch on top of R3 or R4: all three redefine the same pop.

    Task 12 added R4, which redefines Rate_Handle.Logical_Operator_out1 as well.
    Rate_Handle itself would fail loudly anyway (the baseline pop line is gone, so
    the exactly-once anchor assert trips), but the OTHER SIX files of the variant
    still carry live anchors and distinct markers, so without this guard a second
    variant would half-apply across the tree before anything complained.
    """
    for m in (MARKER_R3, MARKER_R4, MARKER_R4B, MARKER_R4D, MARKER_R4E):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R3S both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


# ---- sample_discard_controller.v: export the discard-window state -------------
def patch_sample_discard_controller_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'sample_discard_controller', 'activeOut', 'R3S sdc activeOut port',
                  MARKER_R3S)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3S: 1 while the deframer is consuming the 12,320-symbol payload\n"
             "  // window; 0 during the 13-symbol inter-frame guard (End_Generator endOut ->\n"
             "  // next startIn) in which every symbol is discarded.  Read-only tap.\n"
             "  output  activeOut;\n", 'R3S sdc activeOut declaration')
    s = _sub(s, "endmodule  // sample_discard_controller\n",
             "  assign activeOut = active;  // RXFIX_R3S\n\n"
             "endmodule  // sample_discard_controller\n", 'R3S sdc activeOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Packet_Controller.v: hoist the guard out of the deframer ------------------
def patch_packet_controller_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'Packet_Controller', 'guardOut', 'R3S Packet_Controller guardOut port',
                  MARKER_R3S)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3S: 1 while the deframer is in its inter-frame guard (discarding).\n"
             "  output  guardOut;\n"
             "  wire sdc_active_r3s;\n", 'R3S Packet_Controller guardOut declaration')
    s = _add_pin(s, 'sample_discard_controller', 'u_sample_discard_controller',
                 '.activeOut(sdc_active_r3s)', 'R3S Packet_Controller sdc instantiation',
                 MARKER_R3S)
    s = _sub(s, "endmodule  // Packet_Controller\n",
             "  assign guardOut = ~sdc_active_r3s;  // RXFIX_R3S\n\n"
             "endmodule  // Packet_Controller\n", 'R3S Packet_Controller guardOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Validate_Input_Push_Pop_block.v: export the TRUE occupancy ---------------
def patch_vipp_block_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'Validate_Input_Push_Pop_block', 'occOut', 'R3S VIPP_block occOut port',
                  MARKER_R3S)
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R3S: the registered TRUE ring occupancy, 0..32 (Delay_out1).\n"
             "  // Compare_To_Constant_block compares this SAME net against 6'b000000 to\n"
             "  // form pop_on_empty_FIFO, so occOut == 0 is exactly the EMPTY condition.\n"
             "  output  [5:0] occOut;\n", 'R3S VIPP_block occOut declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign occOut = Delay_out1;  // RXFIX_R3S\n", 'R3S VIPP_block occOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- FIFO_block.v: pass the occupancy up to Rate_Handle -----------------------
def patch_fifo_block_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'FIFO_block', 'occOut', 'R3S FIFO_block occOut port', MARKER_R3S)
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R3S: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] occOut;\n", 'R3S FIFO_block occOut declaration')
    s = _add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                 '.occOut(occOut)', 'R3S FIFO_block VIPP instantiation', MARKER_R3S)
    open(path, 'w').write(s)
    return 'patched'


# ---- Rate_Handle.v: the steering itself ---------------------------------------
RH_POP_OLD_R3S = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW_R3S = """  // ---- RXFIX_R3S: skip-only, acquisition-safe guard-band steering ----
  // r3s_pop_nom is the baseline pop (the rigid mod-4 phase).  While ARMED, and at
  // most once per inter-frame guard window:
  //     occupancy <= 1  ->  SKIP that one pop  (occupancy +1)
  // and nothing else.  There is no extra-pop branch: R3's occ >= 30 branch fired
  // during acquisition and destroyed framing, and an extra pop is not the mirror of
  // a skipped one (it EMITS a symbol).  The FULL edge is out of scope here.
  //
  // Before r3s_armed the expression below is literally the baseline expression, so
  // the s = 0 leg is bit-identical BY CONSTRUCTION.
  assign r3s_pop_nom = validIn & Compare_To_Constant_out1;

  // The ring's own EMPTY edge, reconstructed here rather than routed out:
  // Validate_Input_Push_Pop_block.v defines pop_on_empty_FIFO = (Delay_out1 == 0) &
  // pop, occOut IS Delay_out1, and Compare_To_Constant_block compares against
  // 6'b000000 -- so this net is BIT-EXACT pop_on_empty_FIFO.
  assign r3s_pop_empty = (r3s_occ == 6'b000000) & Logical_Operator_out1;

  // LOCK: guardIn is constant 1 until the deframer frames its first packet, so each
  // FALLING edge of guardIn is one deframer frame start.  Eight of them = locked.
  assign r3s_locked = r3s_frames == 4'b1000;

  assign r3s_do_skip = r3s_armed & guardIn & (r3s_occ <= 6'b000001) &
              ( ~r3s_skip_done) & r3s_pop_nom;

  assign Logical_Operator_out1 = r3s_pop_nom & ( ~r3s_do_skip);

  always @(posedge clk or posedge reset)
    begin : r3s_steer_process
      if (reset == 1'b1) begin
        r3s_guard_d <= 1'b0;
        r3s_frames <= 4'b0000;
        r3s_armed <= 1'b0;
        r3s_skip_done <= 1'b0;
        r3s_skips <= 32'b00000000000000000000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          r3s_guard_d <= guardIn;
          if (r3s_guard_d && ( ~guardIn) && ( ~r3s_locked)) begin
            r3s_frames <= r3s_frames + 4'b0001;
          end
          if (r3s_locked && r3s_pop_empty) begin
            r3s_armed <= 1'b1;
          end
          if ( ~guardIn) begin
            r3s_skip_done <= 1'b0;
          end
          else if (r3s_do_skip) begin
            r3s_skip_done <= 1'b1;
            r3s_skips <= r3s_skips + 32'b1;
          end
        end
      end
    end
"""


def patch_rate_handle_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'Rate_Handle', 'guardIn', 'R3S Rate_Handle guardIn port', MARKER_R3S)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R3S: 1 during the deframer's inter-frame guard window.\n"
             "  input   guardIn;\n\n"
             "  wire [5:0] r3s_occ;  // ufix6\n"
             "  wire r3s_pop_nom;\n"
             "  wire r3s_pop_empty;\n"
             "  wire r3s_locked;\n"
             "  wire r3s_do_skip;\n"
             "  reg  r3s_guard_d;\n"
             "  reg [3:0] r3s_frames;  // ufix4, saturating at 8 deframer frames\n"
             "  reg  r3s_armed;        // WITNESS: steering armed (post-lock hole seen)\n"
             "  reg  r3s_skip_done;    // one skip per guard window\n"
             "  reg [31:0] r3s_skips;  // WITNESS: steered pop SKIPS\n",
             'R3S Rate_Handle guardIn declaration')
    s = _sub(s, RH_POP_OLD_R3S, RH_POP_NEW_R3S, 'R3S Rate_Handle steered pop')
    s = _add_pin(s, 'FIFO_block', 'u_FIFO', '.occOut(r3s_occ)',
                 'R3S Rate_Handle FIFO_block instantiation', MARKER_R3S)
    open(path, 'w').write(s)
    return 'patched'


# ---- Symbol_Synchronizer.v: route the guard down to Rate_Handle ---------------
def patch_symbol_synchronizer_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _add_port(s, 'Symbol_Synchronizer', 'guardIn', 'R3S Symbol_Synchronizer guardIn port',
                  MARKER_R3S)
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n",
             "  input   [31:0] ss_integ_gain;  // uint32\n"
             "  input   guardIn;  // RXFIX_R3S: deframer inter-frame guard window\n",
             'R3S Symbol_Synchronizer guardIn declaration')
    s = _add_pin(s, 'Rate_Handle', 'u_Rate_Handle', '.guardIn(guardIn)',
                 'R3S Symbol_Synchronizer Rate_Handle instantiation', MARKER_R3S)
    open(path, 'w').write(s)
    return 'patched'


# ---- Frequency_and_Time_Synchronizer.v: close the loop ------------------------
def patch_freq_time_sync_r3s(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R3S):
        return 'already'
    _r3s_guard(s)
    s = _sub(s, "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             "  // RXFIX_R3S: the deframer's inter-frame guard, fed back to the Rate_Handle\n"
             "  // ring.  Sourced from a register (sample_discard_controller.active), so\n"
             "  // there is no combinational loop through the receive chain.\n"
             "  wire Packet_Controller_guardOut;\n\n"
             "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             'R3S FTS guard wire declaration')
    s = _add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer',
                 '.guardIn(Packet_Controller_guardOut)',
                 'R3S FTS Symbol_Synchronizer instantiation', MARKER_R3S)
    s = _add_pin(s, 'Packet_Controller', 'u_Packet_Controller',
                 '.guardOut(Packet_Controller_guardOut)',
                 'R3S FTS Packet_Controller instantiation', MARKER_R3S)
    open(path, 'w').write(s)
    return 'patched'


# ============================================================ R4: pre-filled ring
# RXFIX_R4 (Task 12, brief two_jup/sdd_archive/2026-09-04-rxfix/task-12-brief.md).
# R4 is the SHIPPABLE form of R3S: same seven internal modules, same skip-only
# guard-band steering, but the OPERATING POINT is defined at reset instead of being
# discovered by waiting for a hole.
#
# WHAT R3S PROVED, AND THE ONE THING IT COULD NOT DO  [sim, task-11-report.md]
# On the certified non-repeating stimulus R3S took 21 steered skips at exactly the 21
# air frames where the baseline took its 21 EMPTY-edge holes and NOT ONE of those
# skips cost a frame (0.095 lost frames per skip against the baseline's 2.00 per
# hole); loss fell 10.93 % -> 0.95 % at -10 ppm, 78.07 % -> 4.48 % at -40 ppm and
# 22.01 % -> 1.89 % on the tiled control.  EVERY residual loss was either task 7's
# already-recorded seq 133/134 pair (lost in the baseline too) or the frames
# straddling the ONE hole R3S needs in order to arm -- because R3S's arming event IS
# a post-lock pop_on_empty.  R3S cannot arm on lock alone: at 0 ppm the ring settles
# at occupancy 1 on the TGEN stream, so a bare `occ <= N` predicate would fire every
# frame there and fill the ring.  That is exactly the R3 failure mode.
#
# THE TWO PIECES OF R4.
#
# (a) PRE-FILL TO MID-RING.  After reset every pop is suppressed until the registered
#     ring occupancy has reached 16 once; `r4_prefilled` is a sticky flop and from
#     then on the pop is the baseline expression again (modulo the steering below).
#     Cost: a CONSTANT extra latency of ~16 symbols (~64 enb ticks / 64 input
#     samples), measured on the 0 ppm leg and reported.  Benefit: the 0 ppm operating
#     point moves from occupancy 1/2 to 16/17, which is what makes a bare occupancy
#     predicate INERT at s = 0 -- and inertness at s = 0 is the whole reason R3 and
#     R3S needed an arming event at all.
#
#     WHAT PRE-FILL DOES *NOT* DO, stated because the brief's mechanism sentence
#     over-claims it and the banked data says otherwise.  It does NOT set the
#     steady-state occupancy on every leg "regardless of the acquisition transient":
#     task 7's b_m10_frames.txt air frame 2 shows the ring going 1 -> 31 with
#     push_on_full = 17 -- the acquisition burst fills the ring to FULL and deletes
#     17 pushes -- so on that leg the post-acquisition occupancy is ~31 whatever the
#     ring was pre-filled to.  b_m40 and tb_m10 have no such burst (push_on_full = 0)
#     and there the pre-fill does survive acquisition.  R4 is therefore two claims,
#     not one: pre-fill owns the s = 0 inertness, and the `occ <= 8` threshold owns
#     the steering wherever acquisition happens to leave the ring.
#
# (b) STEERING, skip-only, from lock.  While pre-filled AND locked, the first nominal
#     pop inside the deframer's inter-frame guard window at occupancy <= 8 is
#     suppressed, at most once per window.  `r4_locked` is R3S's four-flop
#     falling-edge count of guardIn (eight deframer frames): before the deframer
#     frames its first packet, sample_discard_controller.active is 0 for ever, so
#     guardIn = ~active is CONSTANT 1 and never falls, and every falling edge of
#     guardIn is one deframer frame start.  Lock is in the predicate for one reason:
#     pre-fill completes inside air frame 0 but lock is ~air frame 5, and in that gap
#     guardIn is stuck at 1, so a single stray skip could latch r4_skip_done (which
#     clears only on ~guardIn) and silently disable the steering for the whole run.
#     The lock term can only REMOVE skips, never add one.
#
# (c) Nothing on the FULL side.  R3's extra-pop branch stays deleted -- an extra pop
#     EMITS a symbol and slips every valid-counting epoch the opposite way; task 7
#     measured r3_extras = 4 accompanying 100 % loss of framing.  Positive SRO (the
#     reverse leg) is out of scope and is only OBSERVED here, on the +10 ppm leg.
#
# IDENTITY AT s = 0 IS MEASURED, NOT STRUCTURAL -- AND THAT IS A REAL DIFFERENCE FROM
# R3S.  R3S ANDed its skip with `armed`, so before arming its pop expression was
# LITERALLY the baseline line and the 0 ppm identity followed from the text.  R4
# gates the pop on r4_prefilled, so R4's pop expression is NEVER the baseline
# expression.  The 0 ppm claim is CONTENT identity (per-frame nwords / FNV hash /
# user flag) with a constant sidx offset equal to the pre-fill latency, and it has to
# be measured.  Do not copy R3S's stronger wording onto R4.
#
# FAILURE MODE, STATED, AND IT IS WORSE THAN R3S'S.  R3S failed TOWARD baseline: with
# no arming event it was the baseline netlist.  R4 fails toward NO OUTPUT: if the
# ring never reaches occupancy 16 after reset, r4_prefilled never sets and no pop is
# ever taken.  In practice the ring fills from the first interpolator strobes (~64
# enb ticks) and only a receiver with no symbol strobes at all could sit there -- a
# receiver that has nothing to deliver anyway -- but there is no timeout and a
# silicon build should be reviewed with that in mind.
#
# NOT CLAIMED.  Peak_Search.timing_Reference, Timing_Adjust.timing_Reference and
# End_Generator's counter all count VALIDS, so a skipped valid still slips all three
# epochs by one symbol.  R4 bounds WHERE the deficit is absorbed, not what the epoch
# counters do with it.  A residual is expected and is reported as measured.
#
# The IP interface is unchanged: no TxRxComposite port is added.  Same seven internal
# modules as R3/R3S, same structural (paren-balanced) insertion so both netlist
# lineages take it despite their different port lists.  R4 is COMBINABLE WITH W1
# (task 13 builds them together): W1 is a read-only instrument whose anchors are
# disjoint from R4's, and a test applies both, in both orders, on both lineages.


def _r4_guard(s):
    """R4 refuses to patch on top of R3 or R3S: all three redefine the same pop."""
    for m in (MARKER_R3, MARKER_R3S, MARKER_R4B, MARKER_R4D, MARKER_R4E):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R4 both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


# ---- sample_discard_controller.v: export the discard-window state -------------
def patch_sample_discard_controller_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'sample_discard_controller', 'activeOut', 'R4 sdc activeOut port',
                  MARKER_R4)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R4: 1 while the deframer is consuming the 12,320-symbol payload\n"
             "  // window; 0 during the 13-symbol inter-frame guard (End_Generator endOut ->\n"
             "  // next startIn) in which every symbol is discarded.  Read-only tap.\n"
             "  output  activeOut;\n", 'R4 sdc activeOut declaration')
    s = _sub(s, "endmodule  // sample_discard_controller\n",
             "  assign activeOut = active;  // RXFIX_R4\n\n"
             "endmodule  // sample_discard_controller\n", 'R4 sdc activeOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Packet_Controller.v: hoist the guard out of the deframer ------------------
def patch_packet_controller_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'Packet_Controller', 'guardOut', 'R4 Packet_Controller guardOut port',
                  MARKER_R4)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R4: 1 while the deframer is in its inter-frame guard (discarding).\n"
             "  output  guardOut;\n"
             "  wire sdc_active_r4;\n", 'R4 Packet_Controller guardOut declaration')
    s = _add_pin(s, 'sample_discard_controller', 'u_sample_discard_controller',
                 '.activeOut(sdc_active_r4)', 'R4 Packet_Controller sdc instantiation',
                 MARKER_R4)
    s = _sub(s, "endmodule  // Packet_Controller\n",
             "  assign guardOut = ~sdc_active_r4;  // RXFIX_R4\n\n"
             "endmodule  // Packet_Controller\n", 'R4 Packet_Controller guardOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- Validate_Input_Push_Pop_block.v: export the TRUE occupancy ---------------
def patch_vipp_block_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'Validate_Input_Push_Pop_block', 'occOut', 'R4 VIPP_block occOut port',
                  MARKER_R4)
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R4: the registered TRUE ring occupancy, 0..32 (Delay_out1).  This\n"
             "  // is the SAME net Compare_To_Constant_block compares against 6'b000000 to\n"
             "  // form pop_on_empty_FIFO, so it is the ring's own occupancy, not a\n"
             "  // pointer delta.\n"
             "  output  [5:0] occOut;\n", 'R4 VIPP_block occOut declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign occOut = Delay_out1;  // RXFIX_R4\n", 'R4 VIPP_block occOut assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- FIFO_block.v: pass the occupancy up to Rate_Handle -----------------------
def patch_fifo_block_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'FIFO_block', 'occOut', 'R4 FIFO_block occOut port', MARKER_R4)
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R4: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] occOut;\n", 'R4 FIFO_block occOut declaration')
    s = _add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                 '.occOut(occOut)', 'R4 FIFO_block VIPP instantiation', MARKER_R4)
    open(path, 'w').write(s)
    return 'patched'


# ---- Rate_Handle.v: the pre-fill and the steering ------------------------------
RH_POP_OLD_R4 = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW_R4 = """  // ---- RXFIX_R4: pre-filled ring + lock-armed, skip-only guard-band steering ----
  // r4_pop_nom is the baseline pop (the rigid mod-4 phase).  Two things are done to
  // it, and nothing else:
  //   1. PRE-FILL.  Every pop is suppressed until the registered occupancy has
  //      reached 16 once (r4_prefilled, sticky).  This defines the operating point
  //      at reset instead of discovering it from the first hole, and it is what
  //      makes the occupancy predicate below inert at s = 0, where the ring would
  //      otherwise sit at occupancy 1.  Cost: a constant ~16 symbols of latency.
  //   2. STEER.  While pre-filled AND locked, at most once per inter-frame guard
  //      window: occupancy <= 8 -> SKIP that one pop (occupancy +1).  Nothing on
  //      the FULL side -- R3's extra-pop branch is deleted, not fixed, because an
  //      extra pop EMITS a symbol and slips every valid-counting epoch the other
  //      way.  The FULL edge / positive SRO is out of scope.
  //
  // NOTE, deliberately unlike R3S: because the pop is gated on r4_prefilled, this
  // expression is NEVER the baseline expression, so the s = 0 identity is MEASURED
  // (content identity with a constant pre-fill latency), not structural.
  assign r4_pop_nom = validIn & Compare_To_Constant_out1;

  // LOCK: guardIn is constant 1 until the deframer frames its first packet, so each
  // FALLING edge of guardIn is one deframer frame start.  Eight of them = locked.
  // Pre-fill completes in air frame 0 but lock is ~air frame 5; without this term a
  // stray skip in that window would latch r4_skip_done (cleared only on ~guardIn)
  // and disable the steering for the rest of the run.  It can only remove skips.
  assign r4_locked = r4_frames == 4'b1000;

  assign r4_do_skip = r4_prefilled & r4_locked & guardIn & (r4_occ <= 6'b001000) &
              ( ~r4_skip_done) & r4_pop_nom;

  assign Logical_Operator_out1 = r4_pop_nom & r4_prefilled & ( ~r4_do_skip);

  always @(posedge clk or posedge reset)
    begin : r4_steer_process
      if (reset == 1'b1) begin
        r4_guard_d <= 1'b0;
        r4_frames <= 4'b0000;
        r4_prefilled <= 1'b0;
        r4_skip_done <= 1'b0;
        r4_skips <= 32'b00000000000000000000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          r4_guard_d <= guardIn;
          if (r4_occ >= 6'b010000) begin
            r4_prefilled <= 1'b1;
          end
          if (r4_guard_d && ( ~guardIn) && ( ~r4_locked)) begin
            r4_frames <= r4_frames + 4'b0001;
          end
          if ( ~guardIn) begin
            r4_skip_done <= 1'b0;
          end
          else if (r4_do_skip) begin
            r4_skip_done <= 1'b1;
            r4_skips <= r4_skips + 32'b1;
          end
        end
      end
    end
"""


def patch_rate_handle_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'Rate_Handle', 'guardIn', 'R4 Rate_Handle guardIn port', MARKER_R4)
    s = _sub(s, "  output  validOut;\n",
             "  output  validOut;\n"
             "  // RXFIX_R4: 1 during the deframer's inter-frame guard window.\n"
             "  input   guardIn;\n\n"
             "  wire [5:0] r4_occ;  // ufix6\n"
             "  wire r4_pop_nom;\n"
             "  wire r4_locked;\n"
             "  wire r4_do_skip;\n"
             "  reg  r4_guard_d;\n"
             "  reg [3:0] r4_frames;  // ufix4, saturating at 8 deframer frames\n"
             "  reg  r4_prefilled;    // WITNESS: ring pre-filled to mid-occupancy once\n"
             "  reg  r4_skip_done;    // one skip per guard window\n"
             "  reg [31:0] r4_skips;  // WITNESS: steered pop SKIPS\n",
             'R4 Rate_Handle guardIn declaration')
    s = _sub(s, RH_POP_OLD_R4, RH_POP_NEW_R4, 'R4 Rate_Handle pre-filled steered pop')
    s = _add_pin(s, 'FIFO_block', 'u_FIFO', '.occOut(r4_occ)',
                 'R4 Rate_Handle FIFO_block instantiation', MARKER_R4)
    open(path, 'w').write(s)
    return 'patched'


# ---- Symbol_Synchronizer.v: route the guard down to Rate_Handle ---------------
def patch_symbol_synchronizer_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _add_port(s, 'Symbol_Synchronizer', 'guardIn', 'R4 Symbol_Synchronizer guardIn port',
                  MARKER_R4)
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n",
             "  input   [31:0] ss_integ_gain;  // uint32\n"
             "  input   guardIn;  // RXFIX_R4: deframer inter-frame guard window\n",
             'R4 Symbol_Synchronizer guardIn declaration')
    s = _add_pin(s, 'Rate_Handle', 'u_Rate_Handle', '.guardIn(guardIn)',
                 'R4 Symbol_Synchronizer Rate_Handle instantiation', MARKER_R4)
    open(path, 'w').write(s)
    return 'patched'


# ---- Frequency_and_Time_Synchronizer.v: close the loop ------------------------
def patch_freq_time_sync_r4(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4):
        return 'already'
    _r4_guard(s)
    s = _sub(s, "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             "  // RXFIX_R4: the deframer's inter-frame guard, fed back to the Rate_Handle\n"
             "  // ring.  Sourced from a register (sample_discard_controller.active), so\n"
             "  // there is no combinational loop through the receive chain.\n"
             "  wire Packet_Controller_guardOut;\n\n"
             "  Symbol_Synchronizer u_Symbol_Synchronizer (.clk(clk),\n",
             'R4 FTS guard wire declaration')
    s = _add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer',
                 '.guardIn(Packet_Controller_guardOut)',
                 'R4 FTS Symbol_Synchronizer instantiation', MARKER_R4)
    s = _add_pin(s, 'Packet_Controller', 'u_Packet_Controller',
                 '.guardOut(Packet_Controller_guardOut)',
                 'R4 FTS Packet_Controller instantiation', MARKER_R4)
    open(path, 'w').write(s)
    return 'patched'


# =====================================================================================
# RXFIX_W1 -- silicon ring-witness + per-stage valid census (Task 9, brief
# two_jup/sdd_archive/2026-09-04-rxfix/task-9-brief.md; design source task-7-report.md
# section 6).  READ-ONLY INSTRUMENT: no data-path net is redefined anywhere, so the
# s = 0 bit-identity gate is structural, not merely measured.
#
# WHY IT IS NEW LOGIC AND NOT A MOVED ADDRESS  [netlist, Task 9 ownership check]
#   Task 7 section 6.1 said "the counters already exist; only the address decode moves".
#   That is wrong.  BeatObs (BeatObs.v:80-86,101-113) computes only (pushc - popc) & 255
#   -- a POINTER DELTA -- and packs it into the RX I/Q debug SAMPLE stream, not an AXI
#   register.  It has no numEntries input and no push_on_full counter.  A pointer delta
#   cannot tell occupancy 0 from occupancy 32 (exactly the sim_sro.cpp:115 defect), and
#   the survey's section 1 confirms true occupancy / pop_on_empty_FIFO / push_on_full_FIFO
#   are not exported anywhere.  0x20C/0x210 are owned by DBGCAP/DEMODCAP
#   (QPSK_Rx.v:816,818, fixctl[13]) and overridden by TXCAP (TxRxComposite.v:1975,2003,
#   fixctl[12]).  So W1 adds both the counters and eight NEW free read addresses.
#
# WHAT IS EXPOSED
#   witA = {16'b0, occTrue[5:0], pushPtr[4:0], popPtr[4:0]}    <- TRUE occupancy 0..32
#   witB = {push_on_full_count[15:0], pop_on_empty_count[15:0]}
#   six 32-bit free-running valid counters (the section 6.3 census):
#     cSS  Symbol_Synchronizer strobe   (= the Rate_Handle ring PUSH request)
#     cRH  Rate_Handle validOut         (= Symbol_Synchronizer validOut)
#     cCFC Coarse_Frequency_Compensator validOut
#     cCS  Carrier_Synchronizer validOut
#     cPD  Preamble_Detector validOut
#     cPC  Packet_Controller validOut
#   Deltas over K air frames must be 12,333*K everywhere upstream of the deframer and
#   12,320*K after sample_discard_controller; the first stage whose delta falls short is
#   the deleting stage.  All eight words are shadowed behind ONE freeze level so a host
#   read is a coherent snapshot.
#
# FREEZE
#   fixctl bit 4 (write-only register 0x208; bits 0..3 are FixCtlDec's
#   enContract/enSerAnchor/enGridPace/enSlack, bit 12 is TXCAP's mux, bit 13 is
#   DEMODCAP's mux -- bit 4 is free).  freeze = 1 holds every shadow word; the live
#   counters keep counting.  fixctl is WRITE-ONLY: the reader must not read-modify-write
#   it (see two_jup/rxfix/W1_REGMAP.md).  A netlist copy with no fixctl port (the s1_rtl
#   Verilator lineage) gets freeze tied to 1'b0 and the injector prints W1_FREEZE=tied0.
#
# NOT DONE ON PURPOSE
#   * cnt_mux32 is NOT used.  It is a BD cell (patch_seqbist_tcl.py), and its 32 slots
#     are fully allocated on the 148 lineage (0..15 BD counters, 16..31 rx_seq_checker).
#     Reaching it from inside the IP would need new TxRxComposite -> TxRxCompo_ip top
#     ports, which land in component.xml (verified: ddrcap_* ARE in component.xml,
#     beatfix_viol_count is NOT) and therefore need an IP re-package plus BD tcl edits.
#     Eight free AXI read words cost nothing and need neither.  Deviation from the
#     brief's item 2, recorded in the report.
#   * ddrcap_sel = 12 is SKIPPED (the brief allows it): it would touch the DDRCAP mux at
#     enb rate and put new logic near a path with only +0.11 ns routed margin, and it
#     would break the purely structural s = 0 bit-identity argument.
#
# ADDRESSES (word = addr_read[7:0], byte = 4*word; free -- today they hit the decoder's
# `default: const_0` branch, addr_decoder.v:596-599):
#   0x214 witA   0x218 witB   0x21C cSS   0x220 cRH
#   0x224 cCFC   0x228 cCS    0x22C cPD   0x230 cPC
# =====================================================================================

MARKER_W1 = 'RXFIX_W1'

_PFX = r'(?:TxRxCompo_ip_src_)?'
# every one of the twelve modules begins its declaration block with these two lines
W1_DECL_ANCHOR = "  input   clk;\n  input   reset;\n"


def _w1_add_port(s, module, decl, what):
    """Append `decl` to `module`'s port list (prefix-tolerant: both lineages)."""
    _, j = _span(s, r'module\s+' + _PFX + module + r'\s*\(', what)
    return s[:j] + ',\n           // RXFIX_W1\n           ' + decl + '\n          ' + s[j:]


def _w1_add_pin(s, module, inst, pin, what):
    """Append `pin` to the instantiation `[prefix]module inst (...)`."""
    _, j = _span(s, r'\b' + _PFX + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // RXFIX_W1\n' + ' ' * 24 + s[j:]


def _w1_decl(s, text, what, anchor=None):
    """Insert `text` right after `anchor` (default: the clk/reset declaration pair).

    The twelve W1 files do not all start their declaration block the same way --
    TxRxCompo_ip.v leads with IPCORE_CLK/IPCORE_RESETN and the axi_lite/dut
    wrappers lead with the AXI and gain ports -- so those three pass their own
    anchor.  Every anchor is still asserted exactly-once by _sub.
    """
    a = W1_DECL_ANCHOR if anchor is None else anchor
    return _sub(s, a, a + text, what)


# ---- 1. Validate_Input_Push_Pop_block.v: the three quantities that were never exported
def patch_vipp_block_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    for p in ('w1Occ', 'w1PopEmpty', 'w1PushFull'):
        s = _w1_add_port(s, 'Validate_Input_Push_Pop_block', p, 'W1 VIPP ' + p + ' port')
    s = _w1_decl(s,
                 "  // RXFIX_W1 read-only taps.  Delay_out1 is the REGISTERED true ring\n"
                 "  // occupancy 0..32 (MATLAB_Function_block2.v:86-136 next-state, registered\n"
                 "  // at :103-113); pop_on_empty_FIFO (:119) suppresses a pop into an empty\n"
                 "  // ring (a skipped valid slot, no data lost); push_on_full_FIFO (:125-129)\n"
                 "  // suppresses a push into a full ring -- the ONLY place Rate_Handle deletes\n"
                 "  // a symbol.  None of the three was observable before W1.\n"
                 "  output  [5:0] w1Occ;\n"
                 "  output  w1PopEmpty;\n"
                 "  output  w1PushFull;\n", 'W1 VIPP declarations')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign w1Occ = Delay_out1;        // RXFIX_W1\n"
             "  assign w1PopEmpty = pop_on_empty_FIFO;   // RXFIX_W1\n"
             "  assign w1PushFull = push_on_full_FIFO;   // RXFIX_W1\n",
             'W1 VIPP tap assigns')
    open(path, 'w').write(s)
    return 'patched'


# ---- 2. FIFO_block.v: pass the taps up, and add the two ring pointers
def patch_fifo_block_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    for p in ('w1Occ', 'w1PopEmpty', 'w1PushFull', 'w1PushPtr', 'w1PopPtr'):
        s = _w1_add_port(s, 'FIFO_block', p, 'W1 FIFO_block ' + p + ' port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: ring witness pass-through + the two 5-bit ring pointers.\n"
                 "  output  [5:0] w1Occ;\n"
                 "  output  w1PopEmpty;\n"
                 "  output  w1PushFull;\n"
                 "  output  [4:0] w1PushPtr;\n"
                 "  output  [4:0] w1PopPtr;\n", 'W1 FIFO_block declarations')
    s = _w1_add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                    '.w1Occ(w1Occ),\n' + ' ' * 24 + '.w1PopEmpty(w1PopEmpty),\n'
                    + ' ' * 24 + '.w1PushFull(w1PushFull)',
                    'W1 FIFO_block VIPP instantiation')
    s = _sub(s, "  assign validPop = Validate_Input_Push_Pop_valid_pop;\n",
             "  assign validPop = Validate_Input_Push_Pop_valid_pop;\n\n"
             "  assign w1PushPtr = Push_Counter_out1;  // RXFIX_W1\n"
             "  assign w1PopPtr = Pop_Counter_out1;    // RXFIX_W1\n",
             'W1 FIFO_block pointer assigns')
    open(path, 'w').write(s)
    return 'patched'


# ---- 3. Rate_Handle.v: pass the five ring witnesses up
def patch_rate_handle_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    for p in ('w1Occ', 'w1PopEmpty', 'w1PushFull', 'w1PushPtr', 'w1PopPtr'):
        s = _w1_add_port(s, 'Rate_Handle', p, 'W1 Rate_Handle ' + p + ' port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: ring witness pass-through (read-only).\n"
                 "  output  [5:0] w1Occ;\n"
                 "  output  w1PopEmpty;\n"
                 "  output  w1PushFull;\n"
                 "  output  [4:0] w1PushPtr;\n"
                 "  output  [4:0] w1PopPtr;\n", 'W1 Rate_Handle declarations')
    s = _w1_add_pin(s, 'FIFO_block', 'u_FIFO',
                    '.w1Occ(w1Occ),\n' + ' ' * 24 + '.w1PopEmpty(w1PopEmpty),\n'
                    + ' ' * 24 + '.w1PushFull(w1PushFull),\n'
                    + ' ' * 24 + '.w1PushPtr(w1PushPtr),\n'
                    + ' ' * 24 + '.w1PopPtr(w1PopPtr)',
                    'W1 Rate_Handle FIFO_block instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 4. Symbol_Synchronizer.v: pass the ring witnesses up, plus the ring PUSH request
def patch_symbol_synchronizer_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    for p in ('w1Occ', 'w1PopEmpty', 'w1PushFull', 'w1PushPtr', 'w1PopPtr', 'w1Strobe'):
        s = _w1_add_port(s, 'Symbol_Synchronizer', p, 'W1 Symbol_Synchronizer ' + p + ' port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: ring witness pass-through + the interpolator strobe\n"
                 "  // (Delay2_out1 = Interpolation_Control.Underflow delayed 14 ticks), which\n"
                 "  // is the Rate_Handle ring's PUSH request -- census stage (a).\n"
                 "  output  [5:0] w1Occ;\n"
                 "  output  w1PopEmpty;\n"
                 "  output  w1PushFull;\n"
                 "  output  [4:0] w1PushPtr;\n"
                 "  output  [4:0] w1PopPtr;\n"
                 "  output  w1Strobe;\n", 'W1 Symbol_Synchronizer declarations')
    s = _w1_add_pin(s, 'Rate_Handle', 'u_Rate_Handle',
                    '.w1Occ(w1Occ),\n' + ' ' * 24 + '.w1PopEmpty(w1PopEmpty),\n'
                    + ' ' * 24 + '.w1PushFull(w1PushFull),\n'
                    + ' ' * 24 + '.w1PushPtr(w1PushPtr),\n'
                    + ' ' * 24 + '.w1PopPtr(w1PopPtr)',
                    'W1 Symbol_Synchronizer Rate_Handle instantiation')
    s = _sub(s, "  assign validOut = Rate_Handle_validOut;\n",
             "  assign validOut = Rate_Handle_validOut;\n\n"
             "  assign w1Strobe = Delay2_out1;  // RXFIX_W1\n",
             'W1 Symbol_Synchronizer strobe assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 5. Frequency_and_Time_Synchronizer.v: the census itself + the rh_w1_census module
W1_CENSUS_MODULE = r'''

// =====================================================================================
// RXFIX_W1 -- ring witness + per-stage valid census.  Defined in this file (Verilog
// allows several modules per file) so no build-system file list has to change: this
// file is already in the IP, in the Vivado project and on Verilator's -y path.
//
// Every counter and every shadow is gated by `enb` (enb_1_2_0, the clk/8 tick that is
// one ADC sample at 4 samples/symbol), exactly like dbgcap_process and
// ddrcap_sel_process.  Counting raw clk cycles instead would break the 12,333*K
// arithmetic the census exists to test.
//
// The 32-bit valid counters WRAP (they are read as deltas over a window).  The two
// 16-bit edge counters also wrap; at the measured 2.5 ppm the predicted rate is one
// pop_on_empty per ~32.4 air frames, so 65,536 events is ~2.1 M frames -- hours.
//
// freeze is a LEVEL: while it is high every shadow word holds, so one host sweep of the
// eight addresses is a coherent snapshot.  The live counters never stop.
// =====================================================================================
module rh_w1_census
  (input  wire        clk,
   input  wire        reset,
   input  wire        enb,
   input  wire        freeze,
   input  wire [5:0]  occ,        // TRUE registered ring occupancy, 0..32
   input  wire [4:0]  pushPtr,
   input  wire [4:0]  popPtr,
   input  wire        popEmpty,   // pop_on_empty_FIFO  (skipped valid slot)
   input  wire        pushFull,   // push_on_full_FIFO  (DELETED symbol)
   input  wire        vSS,        // (a) Symbol_Synchronizer strobe = ring push request
   input  wire        vRH,        // (b) Rate_Handle validOut
   input  wire        vCFC,       // (c) Coarse_Frequency_Compensator validOut
   input  wire        vCS,        // (d) Carrier_Synchronizer validOut
   input  wire        vPD,        // (e) Preamble_Detector validOut
   input  wire        vPC,        // (f) Packet_Controller validOut
   output wire [31:0] witA,
   output wire [31:0] witB,
   output wire [31:0] cSS,
   output wire [31:0] cRH,
   output wire [31:0] cCFC,
   output wire [31:0] cCS,
   output wire [31:0] cPD,
   output wire [31:0] cPC);

  reg [15:0] poeCnt;
  reg [15:0] pofCnt;
  reg [31:0] lSS, lRH, lCFC, lCS, lPD, lPC;
  reg [31:0] sA, sB, sSS, sRH, sCFC, sCS, sPD, sPC;

  wire [31:0] wA = {16'b0, occ, pushPtr, popPtr};
  wire [31:0] wB = {pofCnt, poeCnt};

  always @(posedge clk or posedge reset) begin
    if (reset == 1'b1) begin
      poeCnt <= 16'd0; pofCnt <= 16'd0;
      lSS <= 32'd0; lRH <= 32'd0; lCFC <= 32'd0;
      lCS <= 32'd0; lPD <= 32'd0; lPC <= 32'd0;
      sA <= 32'd0; sB <= 32'd0; sSS <= 32'd0; sRH <= 32'd0;
      sCFC <= 32'd0; sCS <= 32'd0; sPD <= 32'd0; sPC <= 32'd0;
    end
    else if (enb) begin
      if (popEmpty) poeCnt <= poeCnt + 16'd1;
      if (pushFull) pofCnt <= pofCnt + 16'd1;
      if (vSS)  lSS  <= lSS  + 32'd1;
      if (vRH)  lRH  <= lRH  + 32'd1;
      if (vCFC) lCFC <= lCFC + 32'd1;
      if (vCS)  lCS  <= lCS  + 32'd1;
      if (vPD)  lPD  <= lPD  + 32'd1;
      if (vPC)  lPC  <= lPC  + 32'd1;
      if ( ~freeze) begin
        sA <= wA; sB <= wB;
        sSS <= lSS; sRH <= lRH; sCFC <= lCFC;
        sCS <= lCS; sPD <= lPD; sPC <= lPC;
      end
    end
  end

  assign witA = sA;
  assign witB = sB;
  assign cSS = sSS;
  assign cRH = sRH;
  assign cCFC = sCFC;
  assign cCS = sCS;
  assign cPD = sPD;
  assign cPC = sPC;

endmodule  // rh_w1_census
'''


def patch_freq_time_sync_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    s = _w1_add_port(s, 'Frequency_and_Time_Synchronizer', 'w1Freeze',
                     'W1 FTS w1Freeze port')
    s = _w1_add_port(s, 'Frequency_and_Time_Synchronizer', 'w1Bus', 'W1 FTS w1Bus port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: freeze level in, the eight 32-bit witness/census words out\n"
                 "  // as one 256-bit bus (bus, not eight ports, so the four hierarchy levels\n"
                 "  // above take one port edit each).  Word i is w1Bus[32*i +: 32]:\n"
                 "  //   0 witA  1 witB  2 cSS  3 cRH  4 cCFC  5 cCS  6 cPD  7 cPC\n"
                 "  input   w1Freeze;\n"
                 "  output  [255:0] w1Bus;\n"
                 "  wire [5:0] w1_occ;\n"
                 "  wire w1_pop_empty;\n"
                 "  wire w1_push_full;\n"
                 "  wire [4:0] w1_push_ptr;\n"
                 "  wire [4:0] w1_pop_ptr;\n"
                 "  wire w1_strobe;\n"
                 "  wire [31:0] w1_witA;\n"
                 "  wire [31:0] w1_witB;\n"
                 "  wire [31:0] w1_cSS;\n"
                 "  wire [31:0] w1_cRH;\n"
                 "  wire [31:0] w1_cCFC;\n"
                 "  wire [31:0] w1_cCS;\n"
                 "  wire [31:0] w1_cPD;\n"
                 "  wire [31:0] w1_cPC;\n", 'W1 FTS declarations',
                 anchor="  input   [31:0] ss_integ_gain;  // uint32\n")
    s = _w1_add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer',
                    '.w1Occ(w1_occ),\n' + ' ' * 24 + '.w1PopEmpty(w1_pop_empty),\n'
                    + ' ' * 24 + '.w1PushFull(w1_push_full),\n'
                    + ' ' * 24 + '.w1PushPtr(w1_push_ptr),\n'
                    + ' ' * 24 + '.w1PopPtr(w1_pop_ptr),\n'
                    + ' ' * 24 + '.w1Strobe(w1_strobe)',
                    'W1 FTS Symbol_Synchronizer instantiation')
    s = _sub(s, "  assign validOut = Packet_Controller_validOut;\n",
             "  // RXFIX_W1: the census.  Stage (b) is Symbol_Synchronizer_validOut, which is\n"
             "  // Rate_Handle's validOut verbatim (Symbol_Synchronizer.v `assign validOut =\n"
             "  // Rate_Handle_validOut`), so no extra port is needed for it.\n"
             "  rh_w1_census u_rh_w1_census (.clk(clk),\n"
             "                               .reset(reset),\n"
             "                               .enb(enb_1_2_0),\n"
             "                               .freeze(w1Freeze),\n"
             "                               .occ(w1_occ),\n"
             "                               .pushPtr(w1_push_ptr),\n"
             "                               .popPtr(w1_pop_ptr),\n"
             "                               .popEmpty(w1_pop_empty),\n"
             "                               .pushFull(w1_push_full),\n"
             "                               .vSS(w1_strobe),\n"
             "                               .vRH(Symbol_Synchronizer_validOut),\n"
             "                               .vCFC(Coarse_Frequency_Compensator_validOut),\n"
             "                               .vCS(Carrier_Synchronizer_validOut),\n"
             "                               .vPD(Preamble_Detector_validOut),\n"
             "                               .vPC(Packet_Controller_validOut),\n"
             "                               .witA(w1_witA),\n"
             "                               .witB(w1_witB),\n"
             "                               .cSS(w1_cSS),\n"
             "                               .cRH(w1_cRH),\n"
             "                               .cCFC(w1_cCFC),\n"
             "                               .cCS(w1_cCS),\n"
             "                               .cPD(w1_cPD),\n"
             "                               .cPC(w1_cPC)\n"
             "                               );\n\n"
             "  assign w1Bus = {w1_cPC, w1_cPD, w1_cCS, w1_cCFC,\n"
             "                  w1_cRH, w1_cSS, w1_witB, w1_witA};  // RXFIX_W1\n\n"
             "  assign validOut = Packet_Controller_validOut;\n",
             'W1 FTS census instantiation')
    s = s.rstrip('\n') + '\n' + W1_CENSUS_MODULE
    open(path, 'w').write(s)
    return 'patched'


# ---- 6. QPSK_Rx.v: the freeze source and the bus pass-through
def patch_qpsk_rx_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    has_fixctl = "  input   [31:0] fixctl;" in s
    src = ("  assign w1_freeze = fixctl[4];  // RXFIX_W1 freeze (write-only reg 0x208 bit 4)\n"
           if has_fixctl else
           "  // RXFIX_W1: this netlist copy has no fixctl port (the s1_rtl Verilator lineage\n"
           "  // predates it), so the freeze is tied off and the shadows track the live\n"
           "  // counters every enb tick.  Reported by the injector as W1_FREEZE=tied0.\n"
           "  assign w1_freeze = 1'b0;\n")
    s = _w1_add_port(s, 'QPSK_Rx', 'w1Bus', 'W1 QPSK_Rx w1Bus port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: the eight witness/census words, pass-through.\n"
                 "  output  [255:0] w1Bus;\n"
                 "  wire w1_freeze;\n" + src, 'W1 QPSK_Rx declarations')
    s = _w1_add_pin(s, 'Frequency_and_Time_Synchronizer', 'u_Frequency_and_Time_Synchronizer',
                    '.w1Freeze(w1_freeze),\n' + ' ' * 24 + '.w1Bus(w1Bus)',
                    'W1 QPSK_Rx FTS instantiation')
    open(path, 'w').write(s)
    return 'patched'


def _pass_through(module, inst_module, inst, what_prefix):
    def _fn(path, sim_tree=False):
        s = open(path).read()
        if _has(s, MARKER_W1):
            return 'already'
        s = _w1_add_port(s, module, 'w1Bus', what_prefix + ' w1Bus port')
        s = _w1_decl(s, "  // RXFIX_W1: witness/census bus, pass-through.\n"
                        "  output  [255:0] w1Bus;\n", what_prefix + ' declarations')
        s = _w1_add_pin(s, inst_module, inst, '.w1Bus(w1Bus)',
                        what_prefix + ' ' + inst_module + ' instantiation')
        open(path, 'w').write(s)
        return 'patched'
    return _fn


# ---- 7/8. Receiver.v and TxRxComposite.v: pure pass-through
patch_receiver_w1 = _pass_through('Receiver', 'QPSK_Rx', 'u_QPSK_Rx', 'W1 Receiver')
patch_txrxcomposite_w1 = _pass_through('TxRxComposite', 'Receiver', 'u_Receiver',
                                       'W1 TxRxComposite')


# ---- 9. TxRxCompo_ip_dut.v: out of the DUT wrapper
def patch_ip_dut_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    s = _w1_add_port(s, 'TxRxCompo_ip_dut', 'w1_bus', 'W1 dut w1_bus port')
    s = _w1_decl(s, "  // RXFIX_W1: witness/census bus out of the DUT wrapper.\n"
                    "  output  [255:0] w1_bus;  // ufix256\n"
                    "  wire [255:0] w1_bus_sig;  // ufix256\n", 'W1 dut declarations',
                 anchor="  input   [31:0] fixctl;  // ufix32\n")
    # the IP kit names the instance after the prefixed module
    s = _w1_add_pin(s, 'TxRxComposite', 'u_TxRxCompo_ip_src_TxRxComposite',
                    '.w1Bus(w1_bus_sig)', 'W1 dut TxRxComposite instantiation')
    s = _sub(s, "endmodule  // TxRxCompo_ip_dut\n",
             "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n\n"
             "endmodule  // TxRxCompo_ip_dut\n", 'W1 dut bus assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 10. TxRxCompo_ip_axi_lite.v: into the AXI-lite wrapper
def patch_ip_axi_lite_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    s = _w1_add_port(s, 'TxRxCompo_ip_axi_lite', 'read_w1_bus', 'W1 axi_lite port')
    s = _w1_decl(s, "  // RXFIX_W1: witness/census bus into the read decoder.\n"
                    "  input   [255:0] read_w1_bus;  // ufix256\n", 'W1 axi_lite declarations',
                 anchor="  input   [31:0] read_beatfix_viol_latch;  // ufix32\n")
    s = _w1_add_pin(s, 'TxRxCompo_ip_addr_decoder', 'u_TxRxCompo_ip_addr_decoder_inst',
                    '.read_w1_bus(read_w1_bus)', 'W1 axi_lite addr_decoder instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 11. TxRxCompo_ip_addr_decoder.v: eight FREE read words
def patch_ip_addr_decoder_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    s = _w1_add_port(s, 'TxRxCompo_ip_addr_decoder', 'read_w1_bus', 'W1 addr_decoder port')
    s = _w1_decl(s,
                 "  // RXFIX_W1: eight witness/census words at FREE read addresses.\n"
                 "  // address_select_level1 = addr_read[7:0] (a WORD index; byte address is\n"
                 "  // 4*word).  Words 0x85..0x8C = bytes 0x214..0x230 are unused by the\n"
                 "  // generated decoder -- today they fall through to `default: const_0`.\n"
                 "  // NOT touched: 0x83/0x84 (bytes 0x20C/0x210) are DBGCAP/TXCAP\n"
                 "  // (beatfix_viol_count/_latch), and the write-only registers\n"
                 "  // 0x158/0x114/0x118/0x10C/0x208 are untouched by construction (this is a\n"
                 "  // READ decode only).\n"
                 "  input   [255:0] read_w1_bus;  // ufix256\n"
                 "  reg [31:0] w1_reg [0:7];\n"
                 "  integer w1_i;\n"
                 "  wire w1_hit;\n"
                 "  wire [2:0] w1_idx;\n", 'W1 addr_decoder declarations')
    s = _sub(s, "  assign data_read = mux_out0_level1;\n",
             "  // RXFIX_W1 -----------------------------------------------------------------\n"
             "  always @(posedge clk or posedge reset)\n"
             "    begin : w1_reg_process\n"
             "      if (reset == 1'b1) begin\n"
             "        for (w1_i = 0; w1_i < 8; w1_i = w1_i + 1) begin\n"
             "          w1_reg[w1_i] <= 32'b0;\n"
             "        end\n"
             "      end\n"
             "      else begin\n"
             "        if (enb) begin\n"
             "          for (w1_i = 0; w1_i < 8; w1_i = w1_i + 1) begin\n"
             "            w1_reg[w1_i] <= read_w1_bus[32*w1_i +: 32];\n"
             "          end\n"
             "        end\n"
             "      end\n"
             "    end\n\n"
             "  assign w1_hit = (address_select_level1 >= 8'h85) &&\n"
             "              (address_select_level1 <= 8'h8C);\n\n"
             "  assign w1_idx = address_select_level1[2:0] - 3'd5;\n\n"
             "  assign data_read = (w1_hit ? w1_reg[w1_idx] : mux_out0_level1);  // RXFIX_W1\n",
             'W1 addr_decoder read override')
    open(path, 'w').write(s)
    return 'patched'


# ---- 12. TxRxCompo_ip.v: wire the DUT's bus to the AXI-lite read decoder
def patch_ip_top_w1(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_W1):
        return 'already'
    # TxRxCompo_ip.v's declaration block starts with IPCORE_CLK/IPCORE_RESETN, not
    # clk/reset, so it needs its own anchor.  beatfix_viol_count_sig is the wire that
    # carries the DBGCAP read-back from the DUT to the AXI-lite decoder -- exactly the
    # pattern W1 copies, which is why it is the right place to declare beside.
    s = _sub(s, "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n",
             "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
             "  // RXFIX_W1: DUT witness/census bus -> AXI-lite read decoder.  Internal\n"
             "  // only: no TxRxCompo_ip port is added, so component.xml is unchanged.\n"
             "  wire [255:0] w1_bus_sig;  // ufix256\n", 'W1 ip top declarations')
    s = _w1_add_pin(s, 'TxRxCompo_ip_axi_lite', 'u_TxRxCompo_ip_axi_lite_inst',
                    '.read_w1_bus(w1_bus_sig)', 'W1 ip top axi_lite instantiation')
    s = _w1_add_pin(s, 'TxRxCompo_ip_dut', 'u_TxRxCompo_ip_dut_inst',
                    '.w1_bus(w1_bus_sig)', 'W1 ip top dut instantiation')
    open(path, 'w').write(s)
    return 'patched'


W1_RTL_FILES = ['Validate_Input_Push_Pop_block.v', 'FIFO_block.v', 'Rate_Handle.v',
                'Symbol_Synchronizer.v', 'Frequency_and_Time_Synchronizer.v',
                'QPSK_Rx.v', 'Receiver.v', 'TxRxComposite.v']
W1_IP_FILES = ['TxRxCompo_ip_dut.v', 'TxRxCompo_ip_axi_lite.v',
               'TxRxCompo_ip_addr_decoder.v', 'TxRxCompo_ip.v']

W1_PATCHERS = {
    'Validate_Input_Push_Pop_block.v': patch_vipp_block_w1,
    'FIFO_block.v': patch_fifo_block_w1,
    'Rate_Handle.v': patch_rate_handle_w1,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer_w1,
    'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_w1,
    'QPSK_Rx.v': patch_qpsk_rx_w1,
    'Receiver.v': patch_receiver_w1,
    'TxRxComposite.v': patch_txrxcomposite_w1,
    'TxRxCompo_ip_dut.v': patch_ip_dut_w1,
    'TxRxCompo_ip_axi_lite.v': patch_ip_axi_lite_w1,
    'TxRxCompo_ip_addr_decoder.v': patch_ip_addr_decoder_w1,
    'TxRxCompo_ip.v': patch_ip_top_w1,
}


# =====================================================================================
# RXFIX_R4B -- the SILICON-READY form of R4 (Task 12b, brief
# two_jup/sdd_archive/2026-09-04-rxfix/task-12b-brief.md; pre-registration
# two_jup/comb/RXFIX_R4B_SIM_GATE.md).
#
# WHY R4B EXISTS.  The adversarial review of the R3S gate (3 refuters + a critic) did
# not refute the mechanism but found four design facts that make R4 unshippable on
# silicon as cut.  R4B answers each of them, and the controller's 17:07 ruling (from
# Task 12's own smoke diagnostics) removed a fifth piece as useless:
#
# (1) THE WINDOW IS STRUCTURAL, NOT "DEFRAMER IDLE".  R3S and R4 skip while
#     `guardIn = ~sample_discard_controller.active`, which is 1 during ANY idle period:
#     after a false sync, a missed sync, a filler or a garbage frame.  One of 240 R3S
#     skips fired mid-payload (s_m40 air frame 138, tref 7026, after a false
#     Preamble_Detector sync) and that frame died; on silicon 5-6 % of air frames are
#     garbage/filler at the decoder pins and the occ <= 8 predicate is true almost
#     always at steady state, so R4 would skip mid-payload often.  R4B instead opens a
#     ONE-SHOT window of exactly 13 nominal pop slots on `pcEnd`, and admits at most one
#     skip per pcEnd.  A period with no pcEnd within 13 slots gets NO skip.
#
#     pcEnd IS AN EXISTING PORT.  `Packet_Controller.endOut` (Packet_Controller.v:47,
#     driven at :159 by sample_discard_controller, which registers
#     `endOutReg <= endIn & active` under enb_1_2_0_gated) is already declared and is
#     already wired in Frequency_and_Time_Synchronizer.v:104 as the wire
#     `Packet_Controller_endOut`.  It is EXACTLY the signal Task 11's per-stage dump
#     printed as `pcEnd` (wrap_byte_sro4.v `assign pcE = ...Packet_Controller_endOut`,
#     sim_stagewin.cpp:102,155), where pcEnd fires at rel -4 and the R3S skip at rel -1.
#     So R4B needs NO sample_discard_controller.v and NO Packet_Controller.v edit at
#     all: its file set is FIVE files, not R3/R3S/R4's seven, and all five are also in
#     W1's set.
#
# (2) THE ANCHORS REACH THE PACKAGED IP KIT.  Tests 73/91 pin that R3S's and R4's
#     module-name anchors fail on the `TxRxCompo_ip_src_`-prefixed modules the kit uses.
#     Every R4B anchor goes through W1's `_PFX` pattern, and a test applies W1 + R4B to
#     a kit-shaped tree (prefixed modules, three loose mirrors, both zip members,
#     verify_zip) as well as to a --sim-tree.
#
# (3) THE DECISION IS REGISTERED.  R4's pop expression closed a combinational loop
#     (Delay_out1 occupancy -> compares -> do_skip -> pop -> valid_pop -> count ->
#     Delay_out1) and pulled guardIn through four hierarchy levels combinationally.  In
#     R4B the incoming pcEnd is registered (`r4b_pcend_d`), the occupancy compare is
#     registered (`r4b_occ_le8`), and the whole decision is registered
#     (`r4b_skip_en`).  The pop is `r4b_pop_nom & ~r4b_skip_en`: the ONLY combinational
#     path into it is the baseline's own `validIn & Compare_To_Constant_out1`.  One enb
#     tick of latency on the decision is harmless against a 13-slot window.
#
# (4) LOCK IS THE SAME STRUCTURAL SIGNAL AS THE WINDOW.  R3S/R4 counted guardIn falling
#     edges, which under-counts in merged-frame regimes and counts false syncs.  R4B's
#     lock is EIGHT pcEnd PULSES since reset (`r4b_frames`, saturating).
#
# (5) THE PRE-FILL IS DELETED, NOT WEAKENED [controller ruling 2026-09-04T17:07:50].
#     Task 12 measured it: at 0 ppm the ring pre-fills to 17 in air frame 0 and the
#     acquisition transient then DRAINS IT COMPLETELY, taking 23 pop_on_empty on the
#     way; the acquisition deficit is ~34 entries, larger than the 16 pre-filled and
#     larger than the 32-deep ring, so NO pre-fill depth survives it.  What defines the
#     operating point is the STEERING: after lock the occ <= 8 predicate fires once per
#     frame, occupancy ratchets 1 -> 9 over ~8 frames, the predicate goes false and the
#     ring sits FLAT at 9/10 with pop_on_empty = 0.  So R4B has no pre-fill, no timeout
#     and no `r4b_prefilled`.
#
#     A CONSEQUENCE WORTH HAVING: because the pop is gated only on a flag that is 0
#     until the first arm, R4B's pop expression IS LITERALLY THE BASELINE EXPRESSION
#     before the first skip -- the structural property R3S had and R4 gave up -- and
#     R4B fails TOWARD BASELINE (R4 failed toward NO OUTPUT if the ring never reached
#     16).  The 0 ppm gate row is still CONTENT identity, because the ~8 startup skips
#     shift sidx by 4 input samples each.
#
# (6) WITNESSES.  `{r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}` is assembled
#     in Rate_Handle as `r4bWit` and, WHEN W1 IS PRESENT, is carried to a NINTH W1 read
#     word at byte 0x234 (word 0x8D).  DEVIATION FROM THE BRIEF, STATED: the brief asks
#     for {prefilled, armed, skips[15:0], window_opens[15:0]} = 34 bits, which does not
#     fit a 32-bit read word; r4b_prefilled no longer exists and `armed` IS `locked` in
#     this design, so one flag is enough and only window_opens is narrowed to 15 bits
#     (it is read as a delta and wraps in ~136 s at 240 f/s).  If W1 is ABSENT the
#     witnesses stay internal: no port is added above Rate_Handle, exactly as the brief
#     requires.  The decision is per FILE (does this file already carry RXFIX_W1?), so
#     it cannot skew between the loose mirrors and the zip members.
#
# ORDER: apply W1 FIRST, then R4B.  R4B's addr_decoder hunk wraps W1's own `data_read`
# assign, so applying W1 afterwards fails LOUDLY on its exactly-once anchor rather than
# silently dropping the eight words (tested).  On the five core files and on a
# --sim-tree either order works.
# =====================================================================================

MARKER_R4B = 'RXFIX_R4B'   # NB: 'RXFIX_R4' is a PREFIX of it -- see _has()

R4B_CORE_FILES = ['Validate_Input_Push_Pop_block.v', 'FIFO_block.v', 'Rate_Handle.v',
                  'Symbol_Synchronizer.v', 'Frequency_and_Time_Synchronizer.v']
# the ninth-word carry chain: patched ONLY where RXFIX_W1 is already present
R4B_WIT_RTL_FILES = ['QPSK_Rx.v', 'Receiver.v', 'TxRxComposite.v']
R4B_WIT_IP_FILES = ['TxRxCompo_ip_dut.v', 'TxRxCompo_ip_axi_lite.v',
                    'TxRxCompo_ip_addr_decoder.v', 'TxRxCompo_ip.v']


def _r4b_guard(s):
    """R4B refuses to stack on R3/R3S/R4: all four redefine the same pop expression."""
    for m in (MARKER_R3, MARKER_R3S, MARKER_R4, MARKER_R4D, MARKER_R4E):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R4B both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


def _r4b_add_port(s, module, decl, what):
    """Append `decl` to `module`'s port list (PREFIX-TOLERANT: kit lineage included)."""
    _, j = _span(s, r'module\s+' + _PFX + module + r'\s*\(', what)
    return s[:j] + ',\n           // RXFIX_R4B\n           ' + decl + '\n          ' + s[j:]


def _r4b_add_pin(s, module, inst, pin, what):
    """Append `pin` to the instantiation `[prefix]module inst (...)`."""
    _, j = _span(s, r'\b' + _PFX + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // RXFIX_R4B\n' + ' ' * 24 + s[j:]


# ---- 1. Validate_Input_Push_Pop_block.v: export the TRUE occupancy ------------
def patch_vipp_block_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    _r4b_guard(s)
    s = _r4b_add_port(s, 'Validate_Input_Push_Pop_block', 'r4bOcc',
                      'R4B VIPP_block r4bOcc port')
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R4B: the registered TRUE ring occupancy, 0..32 (Delay_out1).  This\n"
             "  // is the SAME net Compare_To_Constant_block compares against 6'b000000 to\n"
             "  // form pop_on_empty_FIFO, so it is the ring's own occupancy, not a pointer\n"
             "  // delta.  Read-only tap.\n"
             "  output  [5:0] r4bOcc;\n", 'R4B VIPP_block r4bOcc declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign r4bOcc = Delay_out1;  // RXFIX_R4B\n",
             'R4B VIPP_block r4bOcc assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 2. FIFO_block.v: pass the occupancy up to Rate_Handle --------------------
def patch_fifo_block_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    _r4b_guard(s)
    s = _r4b_add_port(s, 'FIFO_block', 'r4bOcc', 'R4B FIFO_block r4bOcc port')
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R4B: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] r4bOcc;\n", 'R4B FIFO_block r4bOcc declaration')
    s = _r4b_add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                     '.r4bOcc(r4bOcc)', 'R4B FIFO_block VIPP instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 3. Rate_Handle.v: the structural window, the registered decision, the skip
RH_POP_OLD_R4B = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW_R4B = """  // ---- RXFIX_R4B: lock-armed, skip-only steering inside a STRUCTURAL guard window --
  // r4b_pop_nom is the baseline pop (the rigid mod-4 phase).  ONE thing is done to it:
  // inside a window of 13 nominal pop slots opened by the deframer's own end-of-packet
  // pulse, while locked and while the ring occupancy is <= 8, exactly one pop is
  // suppressed.  Nothing on the FULL side (an EXTRA pop emits a symbol and slips every
  // valid-counting epoch the other way; task 7 measured r3_extras = 4 accompanying
  // 100 % loss of framing).  There is no pre-fill: the steering self-centres the ring.
  //
  // WHY THE WINDOW IS pcEnd AND NOT "DEFRAMER IDLE".  ~sample_discard_controller.active
  // is 1 during ANY idle period -- after a false sync, a missed sync, a filler or a
  // garbage frame -- and one of 240 R3S skips fired mid-payload for exactly that reason
  // and killed the frame.  pcEnd is a structural, once-per-deframed-packet pulse, so a
  // period with no pcEnd within 13 slots gets no skip at all.
  //
  // WHY EVERYTHING IS REGISTERED.  pcEndIn arrives through four hierarchy levels and
  // the occupancy comes out of the ring's own state; if either reached the pop
  // combinationally the pop would close a loop through valid_pop -> occupancy.  Both
  // are registered here, and so is the decision (r4b_skip_en), so the ONLY
  // combinational path into the pop is the baseline's own guard.  Cost: up to one enb
  // tick of arming latency against a 13-slot window.
  //
  // BEFORE THE FIRST ARM r4b_skip_en IS 0 AND THIS LINE IS THE BASELINE LINE, so R4B
  // fails toward BASELINE, and acquisition is bit-identical to the baseline netlist.
  assign r4b_pop_nom = validIn & Compare_To_Constant_out1;

  // LOCK: eight pcEnd pulses since reset.  pcEnd is the same structural signal as the
  // window, unlike R3S/R4's guardIn falling edges (which under-count in merged-frame
  // regimes and count false syncs).
  assign r4b_locked = r4b_frames == 4'b1000;

  assign r4b_do_skip = r4b_skip_en & r4b_pop_nom;

  assign Logical_Operator_out1 = r4b_pop_nom & ( ~r4b_skip_en);

  always @(posedge clk or posedge reset)
    begin : r4b_steer_process
      if (reset == 1'b1) begin
        r4b_pcend_d <= 1'b0;
        r4b_occ_le8 <= 1'b0;
        r4b_win <= 1'b0;
        r4b_wslot <= 4'b0000;
        r4b_skip_done <= 1'b0;
        r4b_skip_en <= 1'b0;
        r4b_frames <= 4'b0000;
        r4b_skips <= 16'b0000000000000000;
        r4b_opens <= 15'b000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          // (a) register the two long paths.  Packet_Controller.endOut is exactly ONE
          //     enb tick wide (sample_discard_controller registers endOutReg <= endIn &
          //     active under enb_1_2_0_gated, and End_Generator's endIn is a one-tick
          //     pulse), so one flop is a complete edge detector.
          r4b_pcend_d <= pcEndIn;
          r4b_occ_le8 <= (r4b_occ <= 6'b001000);
          // (b) LOCK
          if (r4b_pcend_d && ( ~r4b_locked)) begin
            r4b_frames <= r4b_frames + 4'b0001;
          end
          // (c) the skip itself + its witness
          if (r4b_do_skip) begin
            r4b_skips <= r4b_skips + 16'b0000000000000001;
            r4b_skip_done <= 1'b1;
          end
          // (d) the window advances one slot per NOMINAL pop opportunity, whether or
          //     not that pop was taken, and closes after the 13th.
          if (r4b_win && r4b_pop_nom) begin
            if (r4b_wslot >= 4'b1101) begin
              r4b_win <= 1'b0;
            end
            else begin
              r4b_wslot <= r4b_wslot + 4'b0001;
            end
          end
          // (e) a pcEnd OPENS the window.  Last, so that a window opening on the same
          //     tick as a skip wins and the new window starts clean.
          if (r4b_pcend_d) begin
            r4b_win <= 1'b1;
            r4b_wslot <= 4'b0000;
            r4b_skip_done <= 1'b0;
            r4b_opens <= r4b_opens + 15'b000000000000001;
          end
          // (f) THE REGISTERED DECISION.  r4b_wslot <= 12 keeps the skip inside slots
          //     [pcEnd+1, pcEnd+13]: the slot is r4b_wslot + 1 at the instant it fires.
          if (r4b_do_skip) begin
            r4b_skip_en <= 1'b0;
          end
          else begin
            r4b_skip_en <= r4b_locked & r4b_win & r4b_occ_le8 & ( ~r4b_skip_done) &
                        (r4b_wslot <= 4'b1100);
          end
        end
      end
    end
"""

R4B_WIT_ASSIGN = ("\n  // RXFIX_R4B: the silicon witness word.  {locked, skips[15:0],\n"
                  "  // window_opens[14:0]} -- see two_jup/rxfix/W1_REGMAP.md.  Present only\n"
                  "  // when W1 is, because W1 owns the read path that carries it out.\n"
                  "  assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};  // RXFIX_R4B\n")


def patch_rate_handle_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    _r4b_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4b_add_port(s, 'Rate_Handle', 'pcEndIn', 'R4B Rate_Handle pcEndIn port')
    if wit:
        s = _r4b_add_port(s, 'Rate_Handle', 'r4bWit', 'R4B Rate_Handle r4bWit port')
    decl = ("  output  validOut;\n"
            "  // RXFIX_R4B: the deframer's end-of-packet pulse (Packet_Controller.endOut),\n"
            "  // which opens the 13-slot structural skip window.  Registered on arrival.\n"
            "  input   pcEndIn;\n")
    if wit:
        decl += ("  // RXFIX_R4B: {locked, skips[15:0], window_opens[14:0]} for the ninth W1\n"
                 "  // read word at 0x234.\n"
                 "  output  [31:0] r4bWit;\n")
    decl += ("\n"
             "  wire [5:0] r4b_occ;  // ufix6, the TRUE registered ring occupancy\n"
             "  wire r4b_pop_nom;\n"
             "  wire r4b_locked;\n"
             "  wire r4b_do_skip;\n"
             "  reg  r4b_pcend_d;     // pcEndIn, registered (breaks the 4-level path)\n"
             "  reg  r4b_occ_le8;     // the occupancy compare, registered\n"
             "  reg  r4b_win;         // the structural window is open\n"
             "  reg [3:0] r4b_wslot;  // ufix4, nominal pop slots since the window opened\n"
             "  reg  r4b_skip_done;   // one skip per window\n"
             "  reg  r4b_skip_en;     // THE REGISTERED DECISION\n"
             "  reg [3:0] r4b_frames; // ufix4, pcEnd pulses, saturating at 8 = locked\n"
             "  reg [15:0] r4b_skips; // WITNESS: steered pop SKIPS\n"
             "  reg [14:0] r4b_opens; // WITNESS: structural windows opened\n")
    s = _sub(s, "  output  validOut;\n", decl, 'R4B Rate_Handle declarations')
    body = RH_POP_NEW_R4B + (R4B_WIT_ASSIGN if wit else "")
    s = _sub(s, RH_POP_OLD_R4B, body, 'R4B Rate_Handle steered pop')
    s = _r4b_add_pin(s, 'FIFO_block', 'u_FIFO', '.r4bOcc(r4b_occ)',
                     'R4B Rate_Handle FIFO_block instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 4. Symbol_Synchronizer.v: route pcEnd down (and the witness up) ----------
def patch_symbol_synchronizer_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    _r4b_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4b_add_port(s, 'Symbol_Synchronizer', 'pcEndIn',
                      'R4B Symbol_Synchronizer pcEndIn port')
    decl = ("  input   [31:0] ss_integ_gain;  // uint32\n"
            "  input   pcEndIn;  // RXFIX_R4B: deframer end-of-packet, opens the window\n")
    pin = '.pcEndIn(pcEndIn)'
    if wit:
        s = _r4b_add_port(s, 'Symbol_Synchronizer', 'r4bWit',
                          'R4B Symbol_Synchronizer r4bWit port')
        decl += "  output  [31:0] r4bWit;  // RXFIX_R4B: witness word, pass-through\n"
        pin += ',\n' + ' ' * 24 + '.r4bWit(r4bWit)'
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n", decl,
             'R4B Symbol_Synchronizer declarations')
    s = _r4b_add_pin(s, 'Rate_Handle', 'u_Rate_Handle', pin,
                     'R4B Symbol_Synchronizer Rate_Handle instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 5. Frequency_and_Time_Synchronizer.v: close the loop --------------------
def patch_freq_time_sync_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    _r4b_guard(s)
    wit = _has(s, MARKER_W1)
    pin = '.pcEndIn(Packet_Controller_endOut)'
    if wit:
        s = _r4b_add_port(s, 'Frequency_and_Time_Synchronizer', 'r4bWit', 'R4B FTS r4bWit port')
        s = _sub(s, "  assign validOut = Packet_Controller_validOut;\n",
                 "  assign r4bWit = r4b_wit;  // RXFIX_R4B\n\n"
                 "  assign validOut = Packet_Controller_validOut;\n",
                 'R4B FTS r4bWit assign')
        pin += ',\n' + ' ' * 24 + '.r4bWit(r4b_wit)'
    decl = ("  // RXFIX_R4B: the deframer's own end-of-packet pulse, fed back to the\n"
            "  // Rate_Handle ring as the opener of the 13-slot structural skip window.\n"
            "  // Packet_Controller_endOut is an EXISTING wire (:104) on an EXISTING port\n"
            "  // (Packet_Controller.v:47) -- no new port is created anywhere for it, and\n"
            "  // it is registered inside sample_discard_controller, so nothing\n"
            "  // combinational is added to the receive chain.\n")
    if wit:
        decl += ("  output  [31:0] r4bWit;\n"
                 "  wire [31:0] r4b_wit;\n")
    s = _sub(s, "  wire Packet_Controller_endOut;\n",
             "  wire Packet_Controller_endOut;\n" + decl, 'R4B FTS declarations')
    s = _r4b_add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer', pin,
                     'R4B FTS Symbol_Synchronizer instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 6..8. the witness carry chain through the RTL wrappers -------------------
def _r4b_pass_through(module, inst_module, inst, what_prefix, anchor=None):
    """Add a 32-bit r4bWit output and pin it from `inst`.  W1-CONDITIONAL: if this file
    does not already carry RXFIX_W1 there is no read path for the word, so the witness
    stays internal and the file is left untouched ('skipped')."""
    def _fn(path, sim_tree=False):
        s = open(path).read()
        if _has(s, MARKER_R4B):
            return 'already'
        _r4b_guard(s)
        if not _has(s, MARKER_W1):
            return 'skipped'
        s = _r4b_add_port(s, module, 'r4bWit', what_prefix + ' r4bWit port')
        a = W1_DECL_ANCHOR if anchor is None else anchor
        s = _sub(s, a, a + "  // RXFIX_R4B: witness word, pass-through to the ninth W1\n"
                          "  // read word at 0x234.\n"
                          "  output  [31:0] r4bWit;\n", what_prefix + ' declarations')
        s = _r4b_add_pin(s, inst_module, inst, '.r4bWit(r4bWit)',
                         what_prefix + ' ' + inst_module + ' instantiation')
        open(path, 'w').write(s)
        return 'patched'
    return _fn


patch_qpsk_rx_r4b = _r4b_pass_through(
    'QPSK_Rx', 'Frequency_and_Time_Synchronizer', 'u_Frequency_and_Time_Synchronizer',
    'R4B QPSK_Rx')
patch_receiver_r4b = _r4b_pass_through('Receiver', 'QPSK_Rx', 'u_QPSK_Rx', 'R4B Receiver')
patch_txrxcomposite_r4b = _r4b_pass_through('TxRxComposite', 'Receiver', 'u_Receiver',
                                            'R4B TxRxComposite')


# ---- 9. TxRxCompo_ip_dut.v ----------------------------------------------------
def patch_ip_dut_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4b_add_port(s, 'TxRxCompo_ip_dut', 'r4b_wit', 'R4B dut r4b_wit port')
    s = _sub(s, "  input   [31:0] fixctl;  // ufix32\n",
             "  input   [31:0] fixctl;  // ufix32\n"
             "  // RXFIX_R4B: witness word out of the DUT wrapper.\n"
             "  output  [31:0] r4b_wit;  // ufix32\n"
             "  wire [31:0] r4b_wit_sig;  // ufix32\n", 'R4B dut declarations')
    s = _r4b_add_pin(s, 'TxRxComposite', 'u_TxRxCompo_ip_src_TxRxComposite',
                     '.r4bWit(r4b_wit_sig)', 'R4B dut TxRxComposite instantiation')
    s = _sub(s, "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n",
             "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n\n"
             "  assign r4b_wit = r4b_wit_sig;  // RXFIX_R4B\n", 'R4B dut witness assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 10. TxRxCompo_ip_axi_lite.v ---------------------------------------------
def patch_ip_axi_lite_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4b_add_port(s, 'TxRxCompo_ip_axi_lite', 'read_r4b_wit', 'R4B axi_lite port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4B: witness word into the read decoder.\n"
             "  input   [31:0] read_r4b_wit;  // ufix32\n", 'R4B axi_lite declarations')
    s = _r4b_add_pin(s, 'TxRxCompo_ip_addr_decoder', 'u_TxRxCompo_ip_addr_decoder_inst',
                     '.read_r4b_wit(read_r4b_wit)', 'R4B axi_lite addr_decoder instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 11. TxRxCompo_ip_addr_decoder.v: the NINTH read word at 0x234 ------------
# The eight W1 words are NOT touched: w1_reg, w1_hit (0x85..0x8C), w1_idx and the
# w1_reg_process are left byte-identical, and the only W1 line R4B rewrites is the ONE
# `assign data_read` line -- because there is exactly one data_read in the module and a
# ninth word has to come from somewhere.  A test asserts the byte-identity of everything
# else W1 injected.
W1_DATA_READ_LINE = ("  assign data_read = (w1_hit ? w1_reg[w1_idx] : mux_out0_level1);"
                     "  // RXFIX_W1\n")


def patch_ip_addr_decoder_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4b_add_port(s, 'TxRxCompo_ip_addr_decoder', 'read_r4b_wit',
                      'R4B addr_decoder port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4B: a NINTH free read word at byte 0x234 (word 0x8D), one past\n"
             "  // W1's 0x85..0x8C.  {r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}.\n"
             "  // It is ONE word, so it is coherent on a single AXI read and needs no\n"
             "  // place in W1's freeze shadow; W1's eight words are untouched.\n"
             "  input   [31:0] read_r4b_wit;  // ufix32\n"
             "  reg [31:0] r4b_reg;\n"
             "  wire r4b_hit;\n", 'R4B addr_decoder declarations')
    s = _sub(s, W1_DATA_READ_LINE,
             "  // RXFIX_R4B -----------------------------------------------------------------\n"
             "  always @(posedge clk or posedge reset)\n"
             "    begin : r4b_reg_process\n"
             "      if (reset == 1'b1) begin\n"
             "        r4b_reg <= 32'b0;\n"
             "      end\n"
             "      else begin\n"
             "        if (enb) begin\n"
             "          r4b_reg <= read_r4b_wit;\n"
             "        end\n"
             "      end\n"
             "    end\n\n"
             "  assign r4b_hit = (address_select_level1 == 8'h8D);\n\n"
             "  assign data_read = (r4b_hit ? r4b_reg :\n"
             "              (w1_hit ? w1_reg[w1_idx] : mux_out0_level1));  // RXFIX_R4B\n",
             'R4B addr_decoder ninth read word')
    open(path, 'w').write(s)
    return 'patched'


# ---- 12. TxRxCompo_ip.v -------------------------------------------------------
def patch_ip_top_r4b(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4B):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _sub(s, "  wire [255:0] w1_bus_sig;  // ufix256\n",
             "  wire [255:0] w1_bus_sig;  // ufix256\n"
             "  // RXFIX_R4B: DUT witness word -> AXI-lite read decoder.  Internal only:\n"
             "  // no TxRxCompo_ip port is added, so component.xml is unchanged.\n"
             "  wire [31:0] r4b_wit_sig;  // ufix32\n", 'R4B ip top declarations')
    s = _r4b_add_pin(s, 'TxRxCompo_ip_axi_lite', 'u_TxRxCompo_ip_axi_lite_inst',
                     '.read_r4b_wit(r4b_wit_sig)', 'R4B ip top axi_lite instantiation')
    s = _r4b_add_pin(s, 'TxRxCompo_ip_dut', 'u_TxRxCompo_ip_dut_inst',
                     '.r4b_wit(r4b_wit_sig)', 'R4B ip top dut instantiation')
    open(path, 'w').write(s)
    return 'patched'


R4B_PATCHERS = {
    'Validate_Input_Push_Pop_block.v': patch_vipp_block_r4b,
    'FIFO_block.v': patch_fifo_block_r4b,
    'Rate_Handle.v': patch_rate_handle_r4b,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer_r4b,
    'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r4b,
    'QPSK_Rx.v': patch_qpsk_rx_r4b,
    'Receiver.v': patch_receiver_r4b,
    'TxRxComposite.v': patch_txrxcomposite_r4b,
    'TxRxCompo_ip_dut.v': patch_ip_dut_r4b,
    'TxRxCompo_ip_axi_lite.v': patch_ip_axi_lite_r4b,
    'TxRxCompo_ip_addr_decoder.v': patch_ip_addr_decoder_r4b,
    'TxRxCompo_ip.v': patch_ip_top_r4b,
}


def r4b_files(sim_tree):
    """R4B's file set: the Verilator tree has no TxRxCompo_ip_* wrapper files."""
    f = list(R4B_CORE_FILES) + list(R4B_WIT_RTL_FILES)
    return f if sim_tree else f + list(R4B_WIT_IP_FILES)


# =====================================================================================
# RXFIX_R4D = R4B + THE FULL-SIDE MIRROR (Task 14, coordinator decision 2026-09-04;
# pre-registration two_jup/comb/RXFIX_R4D_SIM_GATE.md).  R4B steers only the EMPTY edge:
# it skips one pop when occupancy <= 8 inside the structural window.  Task 12b's G14
# measured the cost of that asymmetry -- on a POSITIVE-SRO link R4B's acquisition-transient
# skips park the ring 7 entries higher, which brings the FULL-edge comb forward by 57
# frames and costs 7 extra frames (6.65 % vs the baseline's 4.99 %).  R4D adds the mirror:
#
#   occupancy >= 24 inside [pcEnd+1, pcEnd+13]  ->  take ONE EXTRA pop (emit one extra
#   valid), at most one per pcEnd, registered exactly like the skip.
#
# WHY THIS IS NOT R3'S EXTRA POP, WHICH TASK 7 MEASURED AT 100 % LOSS OF FRAMING.  R3's
# extras fired under a "deframer idle" predicate -- true after a false sync, a missed sync
# and throughout acquisition -- and R3 had no lock term, so its 4 extras landed outside any
# frame structure.  R4D's extra is gated on LOCK (8 pcEnd pulses) and on the 13-slot
# STRUCTURAL window: exactly the guard band where Task 11 section 5 measured a skipped
# valid to disturb NOTHING (Rate_Handle/CFC/CS/Correlator each -1 valid, Preamble_Detector
# and Packet_Controller unchanged, every control signal identical).  R4D's +1 is the mirror
# of that measured -1.  The occupancy trigger is 24 of 32, so the entry emitted is genuine
# buffered data, never the empty-ring garbage pop_on_empty exists to suppress.
#
# THE TWO EDGES ARE SYMMETRIC AND CANNOT BOTH BE ARMED (occ cannot be both <= 8 and >= 24;
# the dead band 9..23 is 15 entries wide, so there is no oscillation).  The extra fires at
# mod-4 phase 2 -- halfway between nominal pops -- so the instantaneous valid spacing goes
# 4,2,2 rather than putting two pops on adjacent beats.
#
# (Original R4B header follows, since R4D is R4B plus the above.)
# RXFIX_R4B -- the SILICON-READY form of R4 (Task 12b, brief
# two_jup/sdd_archive/2026-09-04-rxfix/task-12b-brief.md; pre-registration
# two_jup/comb/RXFIX_R4D_SIM_GATE.md).
#
# WHY R4D EXISTS.  The adversarial review of the R3S gate (3 refuters + a critic) did
# not refute the mechanism but found four design facts that make R4 unshippable on
# silicon as cut.  R4D answers each of them, and the controller's 17:07 ruling (from
# Task 12's own smoke diagnostics) removed a fifth piece as useless:
#
# (1) THE WINDOW IS STRUCTURAL, NOT "DEFRAMER IDLE".  R3S and R4 skip while
#     `guardIn = ~sample_discard_controller.active`, which is 1 during ANY idle period:
#     after a false sync, a missed sync, a filler or a garbage frame.  One of 240 R3S
#     skips fired mid-payload (s_m40 air frame 138, tref 7026, after a false
#     Preamble_Detector sync) and that frame died; on silicon 5-6 % of air frames are
#     garbage/filler at the decoder pins and the occ <= 8 predicate is true almost
#     always at steady state, so R4 would skip mid-payload often.  R4D instead opens a
#     ONE-SHOT window of exactly 13 nominal pop slots on `pcEnd`, and admits at most one
#     skip per pcEnd.  A period with no pcEnd within 13 slots gets NO skip.
#
#     pcEnd IS AN EXISTING PORT.  `Packet_Controller.endOut` (Packet_Controller.v:47,
#     driven at :159 by sample_discard_controller, which registers
#     `endOutReg <= endIn & active` under enb_1_2_0_gated) is already declared and is
#     already wired in Frequency_and_Time_Synchronizer.v:104 as the wire
#     `Packet_Controller_endOut`.  It is EXACTLY the signal Task 11's per-stage dump
#     printed as `pcEnd` (wrap_byte_sro4.v `assign pcE = ...Packet_Controller_endOut`,
#     sim_stagewin.cpp:102,155), where pcEnd fires at rel -4 and the R3S skip at rel -1.
#     So R4D needs NO sample_discard_controller.v and NO Packet_Controller.v edit at
#     all: its file set is FIVE files, not R3/R3S/R4's seven, and all five are also in
#     W1's set.
#
# (2) THE ANCHORS REACH THE PACKAGED IP KIT.  Tests 73/91 pin that R3S's and R4's
#     module-name anchors fail on the `TxRxCompo_ip_src_`-prefixed modules the kit uses.
#     Every R4D anchor goes through W1's `_PFX` pattern, and a test applies W1 + R4D to
#     a kit-shaped tree (prefixed modules, three loose mirrors, both zip members,
#     verify_zip) as well as to a --sim-tree.
#
# (3) THE DECISION IS REGISTERED.  R4's pop expression closed a combinational loop
#     (Delay_out1 occupancy -> compares -> do_skip -> pop -> valid_pop -> count ->
#     Delay_out1) and pulled guardIn through four hierarchy levels combinationally.  In
#     R4D the incoming pcEnd is registered (`r4d_pcend_d`), the occupancy compare is
#     registered (`r4d_occ_le8`), and the whole decision is registered
#     (`r4d_skip_en`).  The pop is `r4d_pop_nom & ~r4d_skip_en`: the ONLY combinational
#     path into it is the baseline's own `validIn & Compare_To_Constant_out1`.  One enb
#     tick of latency on the decision is harmless against a 13-slot window.
#
# (4) LOCK IS THE SAME STRUCTURAL SIGNAL AS THE WINDOW.  R3S/R4 counted guardIn falling
#     edges, which under-counts in merged-frame regimes and counts false syncs.  R4D's
#     lock is EIGHT pcEnd PULSES since reset (`r4d_frames`, saturating).
#
# (5) THE PRE-FILL IS DELETED, NOT WEAKENED [controller ruling 2026-09-04T17:07:50].
#     Task 12 measured it: at 0 ppm the ring pre-fills to 17 in air frame 0 and the
#     acquisition transient then DRAINS IT COMPLETELY, taking 23 pop_on_empty on the
#     way; the acquisition deficit is ~34 entries, larger than the 16 pre-filled and
#     larger than the 32-deep ring, so NO pre-fill depth survives it.  What defines the
#     operating point is the STEERING: after lock the occ <= 8 predicate fires once per
#     frame, occupancy ratchets 1 -> 9 over ~8 frames, the predicate goes false and the
#     ring sits FLAT at 9/10 with pop_on_empty = 0.  So R4D has no pre-fill, no timeout
#     and no `r4d_prefilled`.
#
#     A CONSEQUENCE WORTH HAVING: because the pop is gated only on a flag that is 0
#     until the first arm, R4D's pop expression IS LITERALLY THE BASELINE EXPRESSION
#     before the first skip -- the structural property R3S had and R4 gave up -- and
#     R4D fails TOWARD BASELINE (R4 failed toward NO OUTPUT if the ring never reached
#     16).  The 0 ppm gate row is still CONTENT identity, because the ~8 startup skips
#     shift sidx by 4 input samples each.
#
# (6) WITNESSES.  TWO words are assembled in Rate_Handle as the 64-bit `r4dWit` and,
#     WHEN W1 IS PRESENT, carried to the NINTH and TENTH W1 read words:
#         r4dWit[31:0]  = word 0 = byte 0x234 (0x8D) = {r4d_locked, r4d_skips[15:0],
#                                                       r4d_window_opens[14:0]}
#         r4dWit[63:32] = word 1 = byte 0x238 (0x8E) = {16'b0, r4d_extras[15:0]}
#     TxRxCompo_ip_addr_decoder maps word i to address 0x8D+i (`r4d_idx`, Task 33).  The
#     first cut indexed by address_select_level1[0] (1 for 0x8D, 0 for 0x8E), so image
#     9acbe2ebe1db returns the two words SWAPPED; W1_REGMAP sec 6-R4D.2 'Silicon exception'
#     records it and the readers key the swap on that md5.  DEVIATION FROM THE BRIEF,
#     STATED: the brief asks
#     for {prefilled, armed, skips[15:0], window_opens[15:0]} = 34 bits, which does not
#     fit a 32-bit read word; r4d_prefilled no longer exists and `armed` IS `locked` in
#     this design, so one flag is enough and only window_opens is narrowed to 15 bits
#     (it is read as a delta and wraps in ~136 s at 240 f/s).  If W1 is ABSENT the
#     witnesses stay internal: no port is added above Rate_Handle, exactly as the brief
#     requires.  The decision is per FILE (does this file already carry RXFIX_W1?), so
#     it cannot skew between the loose mirrors and the zip members.
#
#     WHAT TASK 33 (AND ITS FIX1) CHANGED IN THE GENERATED TEXT, PRECISELY (measured:
#     the pre-Task-33 injector, commit 10b27b7, against this one, on three tree shapes;
#     test_167 pins it).  The functional change is the read-mux index in
#     TxRxCompo_ip_addr_decoder.v (r4d_idx + its `wire`) -- an IP-kit file a --sim-tree
#     does not have.  (a) On the R4D+R1 --sim-tree, the shape the sim gate ran (no W1,
#     so no witness text is emitted at all), every generated file is BYTE-IDENTICAL --
#     which is why the banked R4DR1 sim gate stands and no re-gate was needed.  (b) On
#     any tree with W1 applied -- the KIT-SHAPED W1+R4D tree that built image
#     9acbe2ebe1db, or a W1+R4D --sim-tree -- exactly four files differ, in COMMENT
#     lines only: Rate_Handle.v (this assign's header and the r4dWit port comment) and
#     the three witness-carry wrappers QPSK_Rx.v, Receiver.v, TxRxComposite.v (the
#     pass-through comment).  Symbol_Synchronizer.v, TxRxCompo_ip_dut.v and
#     TxRxCompo_ip_axi_lite.v are byte-identical; the `assign r4dWit = {...}` and every
#     other non-comment line are unchanged.  So "Rate_Handle text unchanged" holds for
#     the gated sim tree and is false, by comments alone, for the kit tree.
#
# ORDER: apply W1 FIRST, then R4D.  R4D's addr_decoder hunk wraps W1's own `data_read`
# assign, so applying W1 afterwards fails LOUDLY on its exactly-once anchor rather than
# silently dropping the eight words (tested).  On the five core files and on a
# --sim-tree either order works.
# =====================================================================================

MARKER_R4D = 'RXFIX_R4D'   # NB: 'RXFIX_R4' is a PREFIX of it -- see _has()

R4D_CORE_FILES = ['Validate_Input_Push_Pop_block.v', 'FIFO_block.v', 'Rate_Handle.v',
                  'Symbol_Synchronizer.v', 'Frequency_and_Time_Synchronizer.v']
# the ninth-word carry chain: patched ONLY where RXFIX_W1 is already present
R4D_WIT_RTL_FILES = ['QPSK_Rx.v', 'Receiver.v', 'TxRxComposite.v']
R4D_WIT_IP_FILES = ['TxRxCompo_ip_dut.v', 'TxRxCompo_ip_axi_lite.v',
                    'TxRxCompo_ip_addr_decoder.v', 'TxRxCompo_ip.v']


def _r4d_guard(s):
    """R4D refuses to stack on R3/R3S/R4: all four redefine the same pop expression."""
    for m in (MARKER_R3, MARKER_R3S, MARKER_R4, MARKER_R4B, MARKER_R4E):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R4D both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


def _r4d_add_port(s, module, decl, what):
    """Append `decl` to `module`'s port list (PREFIX-TOLERANT: kit lineage included)."""
    _, j = _span(s, r'module\s+' + _PFX + module + r'\s*\(', what)
    return s[:j] + ',\n           // RXFIX_R4D\n           ' + decl + '\n          ' + s[j:]


def _r4d_add_pin(s, module, inst, pin, what):
    """Append `pin` to the instantiation `[prefix]module inst (...)`."""
    _, j = _span(s, r'\b' + _PFX + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // RXFIX_R4D\n' + ' ' * 24 + s[j:]


# ---- 1. Validate_Input_Push_Pop_block.v: export the TRUE occupancy ------------
def patch_vipp_block_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    _r4d_guard(s)
    s = _r4d_add_port(s, 'Validate_Input_Push_Pop_block', 'r4dOcc',
                      'R4D VIPP_block r4dOcc port')
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R4D: the registered TRUE ring occupancy, 0..32 (Delay_out1).  This\n"
             "  // is the SAME net Compare_To_Constant_block compares against 6'b000000 to\n"
             "  // form pop_on_empty_FIFO, so it is the ring's own occupancy, not a pointer\n"
             "  // delta.  Read-only tap.\n"
             "  output  [5:0] r4dOcc;\n", 'R4D VIPP_block r4dOcc declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign r4dOcc = Delay_out1;  // RXFIX_R4D\n",
             'R4D VIPP_block r4dOcc assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 2. FIFO_block.v: pass the occupancy up to Rate_Handle --------------------
def patch_fifo_block_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    _r4d_guard(s)
    s = _r4d_add_port(s, 'FIFO_block', 'r4dOcc', 'R4D FIFO_block r4dOcc port')
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R4D: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] r4dOcc;\n", 'R4D FIFO_block r4dOcc declaration')
    s = _r4d_add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                     '.r4dOcc(r4dOcc)', 'R4D FIFO_block VIPP instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 3. Rate_Handle.v: the structural window, the registered decision, the skip
RH_POP_OLD_R4D = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW_R4D = """  // ---- RXFIX_R4D: lock-armed, skip-only steering inside a STRUCTURAL guard window --
  // r4d_pop_nom is the baseline pop (the rigid mod-4 phase).  ONE thing is done to it:
  // inside a window of 13 nominal pop slots opened by the deframer's own end-of-packet
  // pulse, while locked and while the ring occupancy is <= 8, exactly one pop is
  // suppressed.  Nothing on the FULL side (an EXTRA pop emits a symbol and slips every
  // valid-counting epoch the other way; task 7 measured r3_extras = 4 accompanying
  // 100 % loss of framing).  There is no pre-fill: the steering self-centres the ring.
  //
  // WHY THE WINDOW IS pcEnd AND NOT "DEFRAMER IDLE".  ~sample_discard_controller.active
  // is 1 during ANY idle period -- after a false sync, a missed sync, a filler or a
  // garbage frame -- and one of 240 R3S skips fired mid-payload for exactly that reason
  // and killed the frame.  pcEnd is a structural, once-per-deframed-packet pulse, so a
  // period with no pcEnd within 13 slots gets no skip at all.
  //
  // WHY EVERYTHING IS REGISTERED.  pcEndIn arrives through four hierarchy levels and
  // the occupancy comes out of the ring's own state; if either reached the pop
  // combinationally the pop would close a loop through valid_pop -> occupancy.  Both
  // are registered here, and so is the decision (r4d_skip_en), so the ONLY
  // combinational path into the pop is the baseline's own guard.  Cost: up to one enb
  // tick of arming latency against a 13-slot window.
  //
  // BEFORE THE FIRST ARM r4d_skip_en IS 0 AND THIS LINE IS THE BASELINE LINE, so R4D
  // fails toward BASELINE, and acquisition is bit-identical to the baseline netlist.
  assign r4d_pop_nom = validIn & Compare_To_Constant_out1;

  // LOCK: eight pcEnd pulses since reset.  pcEnd is the same structural signal as the
  // window, unlike R3S/R4's guardIn falling edges (which under-count in merged-frame
  // regimes and count false syncs).
  assign r4d_locked = r4d_frames == 4'b1000;

  assign r4d_do_skip = r4d_skip_en & r4d_pop_nom;

  // FULL-side mirror: one EXTRA pop at mod-4 phase 2, i.e. on a beat where the nominal
  // pop is not firing, so the instantaneous valid spacing goes 4,2,2 instead of putting
  // two pops on adjacent beats.  Gated on lock and on the same structural window.
  assign r4d_phase2 = HDL_Counter_out1 == 2'b10;

  assign r4d_do_extra = r4d_extra_en & validIn & r4d_phase2;

  assign Logical_Operator_out1 = (r4d_pop_nom & ( ~r4d_skip_en)) | r4d_do_extra;

  always @(posedge clk or posedge reset)
    begin : r4d_steer_process
      if (reset == 1'b1) begin
        r4d_pcend_d <= 1'b0;
        r4d_occ_le8 <= 1'b0;
        r4d_win <= 1'b0;
        r4d_wslot <= 4'b0000;
        r4d_skip_done <= 1'b0;
        r4d_skip_en <= 1'b0;
        r4d_frames <= 4'b0000;
        r4d_skips <= 16'b0000000000000000;
        r4d_opens <= 15'b000000000000000;
        r4d_occ_ge24 <= 1'b0;
        r4d_extra_en <= 1'b0;
        r4d_extra_done <= 1'b0;
        r4d_extras <= 16'b0000000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          // (a) register the two long paths.  Packet_Controller.endOut is exactly ONE
          //     enb tick wide (sample_discard_controller registers endOutReg <= endIn &
          //     active under enb_1_2_0_gated, and End_Generator's endIn is a one-tick
          //     pulse), so one flop is a complete edge detector.
          r4d_pcend_d <= pcEndIn;
          r4d_occ_le8 <= (r4d_occ <= 6'b001000);
          r4d_occ_ge24 <= (r4d_occ >= 6'b011000);
          // (b) LOCK
          if (r4d_pcend_d && ( ~r4d_locked)) begin
            r4d_frames <= r4d_frames + 4'b0001;
          end
          // (c) the skip itself + its witness
          if (r4d_do_skip) begin
            r4d_skips <= r4d_skips + 16'b0000000000000001;
            r4d_skip_done <= 1'b1;
          end
          if (r4d_do_extra) begin
            r4d_extras <= r4d_extras + 16'b0000000000000001;
            r4d_extra_done <= 1'b1;
          end
          // (d) the window advances one slot per NOMINAL pop opportunity, whether or
          //     not that pop was taken, and closes after the 13th.
          if (r4d_win && r4d_pop_nom) begin
            if (r4d_wslot >= 4'b1101) begin
              r4d_win <= 1'b0;
            end
            else begin
              r4d_wslot <= r4d_wslot + 4'b0001;
            end
          end
          // (e) a pcEnd OPENS the window.  Last, so that a window opening on the same
          //     tick as a skip wins and the new window starts clean.
          if (r4d_pcend_d) begin
            r4d_win <= 1'b1;
            r4d_wslot <= 4'b0000;
            r4d_skip_done <= 1'b0;
            r4d_extra_done <= 1'b0;
            r4d_opens <= r4d_opens + 15'b000000000000001;
          end
          // (f) THE REGISTERED DECISION.  r4d_wslot <= 12 keeps the skip inside slots
          //     [pcEnd+1, pcEnd+13]: the slot is r4d_wslot + 1 at the instant it fires.
          if (r4d_do_skip) begin
            r4d_skip_en <= 1'b0;
          end
          else begin
            r4d_skip_en <= r4d_locked & r4d_win & r4d_occ_le8 & ( ~r4d_skip_done) &
                        (r4d_wslot <= 4'b1100);
          end
          if (r4d_do_extra) begin
            r4d_extra_en <= 1'b0;
          end
          else begin
            r4d_extra_en <= r4d_locked & r4d_win & r4d_occ_ge24 & ( ~r4d_extra_done) &
                        (r4d_wslot <= 4'b1100);
          end
        end
      end
    end
"""

R4D_WIT_ASSIGN = ("\n  // RXFIX_R4D: the silicon witness, TWO 32-bit read words (0x234, 0x238).\n"
                  "  //   word 0 = r4dWit[31:0]  = byte 0x234 = {locked, skips[15:0],\n"
                  "  //                                          window_opens[14:0]}  (R4B's layout)\n"
                  "  //   word 1 = r4dWit[63:32] = byte 0x238 = {16'b0, extras[15:0]}  (the FULL side)\n"
                  "  // Verilog concatenation puts the MOST significant element LEFTMOST, so\n"
                  "  // word 1 (extras) is written first below; TxRxCompo_ip_addr_decoder maps\n"
                  "  // word i to address 0x8D+i (r4d_idx).  See two_jup/rxfix/W1_REGMAP.md\n"
                  "  // sec 6-R4D.  Present only when W1 is, because W1 owns the read path that\n"
                  "  // carries it out.\n"
                  "  assign r4dWit = {{16'b0, r4d_extras},\n"
                  "                   {r4d_locked, r4d_skips, r4d_opens}};  // RXFIX_R4D\n")


def patch_rate_handle_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    _r4d_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4d_add_port(s, 'Rate_Handle', 'pcEndIn', 'R4D Rate_Handle pcEndIn port')
    if wit:
        s = _r4d_add_port(s, 'Rate_Handle', 'r4dWit', 'R4D Rate_Handle r4dWit port')
    decl = ("  output  validOut;\n"
            "  // RXFIX_R4D: the deframer's end-of-packet pulse (Packet_Controller.endOut),\n"
            "  // which opens the 13-slot structural skip window.  Registered on arrival.\n"
            "  input   pcEndIn;\n")
    if wit:
        decl += ("  // RXFIX_R4D: the two witness words -- [31:0] = 0x234 {locked, skips[15:0],\n"
                 "  // window_opens[14:0]}, [63:32] = 0x238 {16'b0, extras[15:0]} -- the ninth\n"
                 "  // and tenth W1 read words.\n"
                 "  output  [63:0] r4dWit;\n")
    decl += ("\n"
             "  wire [5:0] r4d_occ;  // ufix6, the TRUE registered ring occupancy\n"
             "  wire r4d_pop_nom;\n"
             "  wire r4d_locked;\n"
             "  wire r4d_do_skip;\n"
             "  reg  r4d_pcend_d;     // pcEndIn, registered (breaks the 4-level path)\n"
             "  reg  r4d_occ_le8;     // the occupancy compare, registered\n"
             "  reg  r4d_win;         // the structural window is open\n"
             "  reg [3:0] r4d_wslot;  // ufix4, nominal pop slots since the window opened\n"
             "  reg  r4d_skip_done;   // one skip per window\n"
             "  reg  r4d_skip_en;     // THE REGISTERED DECISION\n"
             "  reg [3:0] r4d_frames; // ufix4, pcEnd pulses, saturating at 8 = locked\n"
             "  reg [15:0] r4d_skips; // WITNESS: steered pop SKIPS\n"
             "  reg [14:0] r4d_opens; // WITNESS: structural windows opened\n"
             "  // RXFIX_R4D: the FULL-side mirror\n"
             "  wire r4d_phase2;      // mod-4 phase 2: between nominal pops\n"
             "  wire r4d_do_extra;\n"
             "  reg  r4d_occ_ge24;    // the FULL-side compare, registered\n"
             "  reg  r4d_extra_en;    // THE REGISTERED DECISION (FULL side)\n"
             "  reg  r4d_extra_done;  // one extra per window\n"
             "  reg [15:0] r4d_extras;// WITNESS: steered EXTRA pops\n")
    s = _sub(s, "  output  validOut;\n", decl, 'R4D Rate_Handle declarations')
    body = RH_POP_NEW_R4D + (R4D_WIT_ASSIGN if wit else "")
    s = _sub(s, RH_POP_OLD_R4D, body, 'R4D Rate_Handle steered pop')
    s = _r4d_add_pin(s, 'FIFO_block', 'u_FIFO', '.r4dOcc(r4d_occ)',
                     'R4D Rate_Handle FIFO_block instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 4. Symbol_Synchronizer.v: route pcEnd down (and the witness up) ----------
def patch_symbol_synchronizer_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    _r4d_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4d_add_port(s, 'Symbol_Synchronizer', 'pcEndIn',
                      'R4D Symbol_Synchronizer pcEndIn port')
    decl = ("  input   [31:0] ss_integ_gain;  // uint32\n"
            "  input   pcEndIn;  // RXFIX_R4D: deframer end-of-packet, opens the window\n")
    pin = '.pcEndIn(pcEndIn)'
    if wit:
        s = _r4d_add_port(s, 'Symbol_Synchronizer', 'r4dWit',
                          'R4D Symbol_Synchronizer r4dWit port')
        decl += ("  output  [63:0] r4dWit;  // RXFIX_R4D: witness words, pass-through\n")
        pin += ',\n' + ' ' * 24 + '.r4dWit(r4dWit)'
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n", decl,
             'R4D Symbol_Synchronizer declarations')
    s = _r4d_add_pin(s, 'Rate_Handle', 'u_Rate_Handle', pin,
                     'R4D Symbol_Synchronizer Rate_Handle instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 5. Frequency_and_Time_Synchronizer.v: close the loop --------------------
def patch_freq_time_sync_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    _r4d_guard(s)
    wit = _has(s, MARKER_W1)
    pin = '.pcEndIn(Packet_Controller_endOut)'
    if wit:
        s = _r4d_add_port(s, 'Frequency_and_Time_Synchronizer', 'r4dWit', 'R4D FTS r4dWit port')
        s = _sub(s, "  assign validOut = Packet_Controller_validOut;\n",
                 "  assign r4dWit = r4d_wit;  // RXFIX_R4D\n\n"
                 "  assign validOut = Packet_Controller_validOut;\n",
                 'R4D FTS r4dWit assign')
        pin += ',\n' + ' ' * 24 + '.r4dWit(r4d_wit)'
    decl = ("  // RXFIX_R4D: the deframer's own end-of-packet pulse, fed back to the\n"
            "  // Rate_Handle ring as the opener of the 13-slot structural skip window.\n"
            "  // Packet_Controller_endOut is an EXISTING wire (:104) on an EXISTING port\n"
            "  // (Packet_Controller.v:47) -- no new port is created anywhere for it, and\n"
            "  // it is registered inside sample_discard_controller, so nothing\n"
            "  // combinational is added to the receive chain.\n")
    if wit:
        decl += ("  output  [63:0] r4dWit;\n"
                 "  wire [63:0] r4d_wit;\n")
    s = _sub(s, "  wire Packet_Controller_endOut;\n",
             "  wire Packet_Controller_endOut;\n" + decl, 'R4D FTS declarations')
    s = _r4d_add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer', pin,
                     'R4D FTS Symbol_Synchronizer instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 6..8. the witness carry chain through the RTL wrappers -------------------
def _r4d_pass_through(module, inst_module, inst, what_prefix, anchor=None):
    """Add the 64-bit r4dWit output and pin it from `inst`.  W1-CONDITIONAL: if this file
    does not already carry RXFIX_W1 there is no read path for the word, so the witness
    stays internal and the file is left untouched ('skipped')."""
    def _fn(path, sim_tree=False):
        s = open(path).read()
        if _has(s, MARKER_R4D):
            return 'already'
        _r4d_guard(s)
        if not _has(s, MARKER_W1):
            return 'skipped'
        s = _r4d_add_port(s, module, 'r4dWit', what_prefix + ' r4dWit port')
        a = W1_DECL_ANCHOR if anchor is None else anchor
        s = _sub(s, a, a + "  // RXFIX_R4D: the two witness words, pass-through to the ninth\n"
                          "  // and tenth W1 read words at 0x234/0x238.\n"
                          "  output  [63:0] r4dWit;\n", what_prefix + ' declarations')
        s = _r4d_add_pin(s, inst_module, inst, '.r4dWit(r4dWit)',
                         what_prefix + ' ' + inst_module + ' instantiation')
        open(path, 'w').write(s)
        return 'patched'
    return _fn


patch_qpsk_rx_r4d = _r4d_pass_through(
    'QPSK_Rx', 'Frequency_and_Time_Synchronizer', 'u_Frequency_and_Time_Synchronizer',
    'R4D QPSK_Rx')
patch_receiver_r4d = _r4d_pass_through('Receiver', 'QPSK_Rx', 'u_QPSK_Rx', 'R4D Receiver')
patch_txrxcomposite_r4d = _r4d_pass_through('TxRxComposite', 'Receiver', 'u_Receiver',
                                            'R4D TxRxComposite')


# ---- 9. TxRxCompo_ip_dut.v ----------------------------------------------------
def patch_ip_dut_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4d_add_port(s, 'TxRxCompo_ip_dut', 'r4d_wit', 'R4D dut r4d_wit port')
    s = _sub(s, "  input   [31:0] fixctl;  // ufix32\n",
             "  input   [31:0] fixctl;  // ufix32\n"
             "  // RXFIX_R4D: witness word out of the DUT wrapper.\n"
             "  output  [63:0] r4d_wit;  // ufix64\n"
             "  wire [63:0] r4d_wit_sig;  // ufix64\n", 'R4D dut declarations')
    s = _r4d_add_pin(s, 'TxRxComposite', 'u_TxRxCompo_ip_src_TxRxComposite',
                     '.r4dWit(r4d_wit_sig)', 'R4D dut TxRxComposite instantiation')
    s = _sub(s, "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n",
             "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n\n"
             "  assign r4d_wit = r4d_wit_sig;  // RXFIX_R4D\n", 'R4D dut witness assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 10. TxRxCompo_ip_axi_lite.v ---------------------------------------------
def patch_ip_axi_lite_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4d_add_port(s, 'TxRxCompo_ip_axi_lite', 'read_r4d_wit', 'R4D axi_lite port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4D: witness word into the read decoder.\n"
             "  input   [63:0] read_r4d_wit;  // ufix64\n", 'R4D axi_lite declarations')
    s = _r4d_add_pin(s, 'TxRxCompo_ip_addr_decoder', 'u_TxRxCompo_ip_addr_decoder_inst',
                     '.read_r4d_wit(read_r4d_wit)', 'R4D axi_lite addr_decoder instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 11. TxRxCompo_ip_addr_decoder.v: the NINTH read word at 0x234 ------------
# The eight W1 words are NOT touched: w1_reg, w1_hit (0x85..0x8C), w1_idx and the
# w1_reg_process are left byte-identical, and the only W1 line R4D rewrites is the ONE
# `assign data_read` line -- because there is exactly one data_read in the module and a
# ninth word has to come from somewhere.  A test asserts the byte-identity of everything
# else W1 injected.
W1_DATA_READ_LINE = ("  assign data_read = (w1_hit ? w1_reg[w1_idx] : mux_out0_level1);"
                     "  // RXFIX_W1\n")


def patch_ip_addr_decoder_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4d_add_port(s, 'TxRxCompo_ip_addr_decoder', 'read_r4d_wit',
                      'R4D addr_decoder port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4D: TWO free read words at bytes 0x234/0x238 (words\n"
             "  // 0x8D/0x8E), one past W1's 0x85..0x8C.  0x234 = {locked, skips[15:0],\n"
             "  // window_opens[14:0]}; 0x238 = {16'b0, extras[15:0]}.  Each is ONE word, so\n"
             "  // each is coherent on a single AXI read and needs no place in W1's freeze\n"
             "  // shadow; W1's eight words are untouched.\n"
             "  // Word i of the bus is read_r4d_wit[32*i +: 32] and answers address 0x8D+i\n"
             "  // (r4d_idx below) -- W1's own w1_idx convention.\n"
             "  input   [63:0] read_r4d_wit;  // ufix64\n"
             "  reg [31:0] r4d_reg [0:1];\n  integer r4d_i;\n"
             "  wire r4d_hit;\n"
             "  wire r4d_idx;\n", 'R4D addr_decoder declarations')
    s = _sub(s, W1_DATA_READ_LINE,
             "  // RXFIX_R4D -----------------------------------------------------------------\n"
             "  always @(posedge clk or posedge reset)\n"
             "    begin : r4d_reg_process\n"
             "      if (reset == 1'b1) begin\n"
             "        for (r4d_i = 0; r4d_i < 2; r4d_i = r4d_i + 1) begin\n"
             "          r4d_reg[r4d_i] <= 32'b0;\n"
             "        end\n"
             "      end\n"
             "      else begin\n"
             "        if (enb) begin\n"
             "          for (r4d_i = 0; r4d_i < 2; r4d_i = r4d_i + 1) begin\n"
             "            r4d_reg[r4d_i] <= read_r4d_wit[32*r4d_i +: 32];\n"
             "          end\n"
             "        end\n"
             "      end\n"
             "    end\n\n"
             "  assign r4d_hit = (address_select_level1 == 8'h8D) ||\n"
             "              (address_select_level1 == 8'h8E);\n\n"
             "  // Word index = address - 0x8D:  0x8D (byte 0x234) -> r4d_reg[0] =\n"
             "  // read_r4d_wit[31:0] = {locked, skips, opens};  0x8E (byte 0x238) ->\n"
             "  // r4d_reg[1] = read_r4d_wit[63:32] = {16'b0, extras}.  (Task 33.  The first\n"
             "  // cut indexed by address_select_level1[0], which is 1 for 0x8D and 0 for\n"
             "  // 0x8E, so image 9acbe2ebe1db returns the two words SWAPPED -- W1_REGMAP\n"
             "  // sec 6-R4D.2 'Silicon exception'; its readers key the swap on that md5.)\n"
             "  assign r4d_idx = (address_select_level1 == 8'h8E);\n\n"
             "  assign data_read = (r4d_hit ? r4d_reg[r4d_idx] :\n"
             "              (w1_hit ? w1_reg[w1_idx] : mux_out0_level1));  // RXFIX_R4D\n",
             'R4D addr_decoder ninth read word')
    open(path, 'w').write(s)
    return 'patched'


# ---- 12. TxRxCompo_ip.v -------------------------------------------------------
def patch_ip_top_r4d(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4D):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _sub(s, "  wire [255:0] w1_bus_sig;  // ufix256\n",
             "  wire [255:0] w1_bus_sig;  // ufix256\n"
             "  // RXFIX_R4D: DUT witness word -> AXI-lite read decoder.  Internal only:\n"
             "  // no TxRxCompo_ip port is added, so component.xml is unchanged.\n"
             "  wire [63:0] r4d_wit_sig;  // ufix64\n", 'R4D ip top declarations')
    s = _r4d_add_pin(s, 'TxRxCompo_ip_axi_lite', 'u_TxRxCompo_ip_axi_lite_inst',
                     '.read_r4d_wit(r4d_wit_sig)', 'R4D ip top axi_lite instantiation')
    s = _r4d_add_pin(s, 'TxRxCompo_ip_dut', 'u_TxRxCompo_ip_dut_inst',
                     '.r4d_wit(r4d_wit_sig)', 'R4D ip top dut instantiation')
    open(path, 'w').write(s)
    return 'patched'


R4D_PATCHERS = {
    'Validate_Input_Push_Pop_block.v': patch_vipp_block_r4d,
    'FIFO_block.v': patch_fifo_block_r4d,
    'Rate_Handle.v': patch_rate_handle_r4d,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer_r4d,
    'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r4d,
    'QPSK_Rx.v': patch_qpsk_rx_r4d,
    'Receiver.v': patch_receiver_r4d,
    'TxRxComposite.v': patch_txrxcomposite_r4d,
    'TxRxCompo_ip_dut.v': patch_ip_dut_r4d,
    'TxRxCompo_ip_axi_lite.v': patch_ip_axi_lite_r4d,
    'TxRxCompo_ip_addr_decoder.v': patch_ip_addr_decoder_r4d,
    'TxRxCompo_ip.v': patch_ip_top_r4d,
}


def r4d_files(sim_tree):
    """R4D's file set: the Verilator tree has no TxRxCompo_ip_* wrapper files."""
    f = list(R4D_CORE_FILES) + list(R4D_WIT_RTL_FILES)
    return f if sim_tree else f + list(R4D_WIT_IP_FILES)



# =====================================================================================
# RXFIX_R4E = R4B's EMPTY-side skip + the FULL side's TRUE MIRROR OF THE NATURAL EVENT
# (Task 21, night-2 plan 2026-09-04; pre-registration
# two_jup/comb/RXFIX_R4E_SIM_GATE.md, committed BEFORE this code existed).
#
# WHAT THE NATURAL FULL-EDGE EVENT ACTUALLY IS.  Validate_Input_Push_Pop_block.v:129,
# push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y: a push arriving at
# occupancy 32 is SILENTLY DISCARDED -- no RAM write, no Push_Counter advance, AND NO
# CHANGE TO THE POP SIDE AT ALL.  So the observable is: the popped valid density is
# unchanged and ONE PAYLOAD SYMBOL HAS VANISHED, at whatever position in the frame the
# ring happened to be full.  That deletion lands mid-payload and kills the frame.
#
# R4E does the same deletion ON PURPOSE, AT A CHOSEN POSITION.  It is the mirror of the
# natural event in SHAPE, which R4D's extra pop was not:
#
#   natural push_on_full : pops unchanged, density unchanged, ring -1, random position
#   R4B skip             : pops -1,       density -1,        ring +1
#   R4D extra pop        : pops +1,       density +1,        ring -1  -> PD FIFO
#                          push_on_full -> framing dies (task 14, REFUTED)
#   R4E drop (this)      : pops unchanged, density unchanged, ring -1, CHOSEN position
#
# WHY THAT MATTERS, AND WHY TASK 14 SECTION 3 IS WRONG ABOUT THIS VARIANT.  Task 14 said
# candidate (b) "changes which ring is short, not the 1-in-4 valid density ... any +1/-1
# at Rate_Handle propagates one-for-one into that density".  That is true of a POP and
# false of a PUSH.  The pop is Rate_Handle.v:95, validIn & (HDL_Counter_out1 == 0) -- a
# rigid mod-4 beat that knows nothing about the ring -- and valid_pop = pop &
# ~pop_on_empty.  R4E fires only at occupancy >= 24 of 32, so EVERY POP THAT WOULD HAVE
# FIRED STILL FIRES: validOut is bit-for-bit the same sequence of beats and only WHICH
# symbol rides each beat changes.  R4E's downstream footprint is therefore STRICTLY
# SMALLER than R4B's, which removes a valid pop outright.  The gate's K5 row (pdPof = 0,
# pdOcc flat at 12333, every leg) is what settles it, and refutes R4E if it fails.
#
# THE DROP-SCHEDULING FORMULA, DERIVED FROM THE POINTER ARITHMETIC.
#   Fact 1  Push_Counter/Pop_Counter advance ONLY on validated events (FIFO_block.v:127,
#           :162) and occupancy never exceeds 32, so no address aliases a live entry:
#           the symbol pushed as valid push index p is popped as valid pop index p.
#   Fact 2  Delay_out1 <= count under enb_1_2_0_gated, and count is
#           MATLAB_Function_block2's COMBINATIONAL next state (countReg_temp), which
#           already includes this tick's valid_push ^ valid_pop.  Hence
#              O(t) := Delay_out1(t) = P(<t) - Q(<t)      (events STRICTLY before t)
#   Fact 3  Suppress the push at tick t: it would have been valid push index P(<t),
#           hence valid pop index P(<t), and the pops at ticks >= t are indexed
#           Q(<t), Q(<t)+1, ...  So the vanished symbol would have been emitted on the
#              (O(t) + 1)-th VALIDATED POP at ticks >= t.
#   Fact 4  With T = the Packet_Controller.endOut tick and m = validated pops in the
#           closed interval [t, T], the slot-k pop is the (m + k)-th pop from t, so
#
#              k = O(t) + 1 - m         and in-window (1..13) needs O-12 <= m <= O.
#
# COROLLARY -- WHY THE DECISION CANNOT BE TAKEN AT pcEnd, AND WHY A PERIOD REGISTER
# EXISTS.  Read Fact 4 the other way: at the pcEnd tick itself (m = 0) the symbol that
# will be popped at slot k was pushed (O - k) PUSHES BACK.  With O >= 24 and k in [1,13]
# that is 11 to 23 pushes IN THE PAST -- there is nothing left to drop.  The drop must be
# taken m = O + 1 - k validated pops BEFORE a pcEnd THAT HAS NOT HAPPENED YET, i.e. 12 to
# 31 pops (~48-124 enb ticks) ahead of it.  No structural signal sits there
# (Packet_Controller.startOut is at the far end of the packet, ~12,320 pops earlier), so
# the predictor is a MEASURED period:
#
#     r4e_pcnt   = validated pops since the last pcEnd
#     r4e_period = validated pops between the last two pcEnds  (latched at pcEnd)
#     k_hat      = O + 1 - r4e_period + r4e_pcnt
#
# ARM BAND, ASYMMETRIC ON PURPOSE.  k_hat INCREASES with time, so every staleness source
# -- the registered compare (1 tick), the registered decision (1 more), the wait for the
# next strobe (~1 pop), a push landing in the gap -- pushes the REALISED k UP and never
# down.  The band is therefore centred low:
#
#     arm  <=>  pcnt + occ >= period + 6   AND   pcnt + occ <= period + 10
#               i.e. k_hat in [7, 11], realised k predicted in [7, 13].
#
# THE LANDING SLOT IS MEASURED, NOT ASSUMED.  At the drop, r4e_land_a <= r4e_pcnt and
# r4e_land_occ <= r4e_occ.  At the NEXT pcEnd, m = r4e_pcnt - r4e_land_a (r4e_pcnt is read
# before its reload, so this is exactly the validated pops in [t, T]) and the witness
# records k = r4e_land_occ + 1 - m, with out-of-[1,13] events counted separately.  The
# harness recomputes the same quantity from (fifoPush - fifoPop) mod 32, fifoVPop and pcE
# -- taps that share NO NET with the R4E logic.
#
# R4E CONTAINS R4B; IT DOES NOT STACK ON IT.  The EMPTY-side block is R4B's text with the
# prefix changed, so the skip side is provably unchanged and the content-identity rows are
# predictions about the RTL text.  _r4e_guard refuses R3/R3S/R4/R4B/R4D and all five of
# those refuse R4E.  Same five core files as R4B, same conditional witness carry chain,
# NO new TxRxComposite or IP port.
#
# ORDER: apply W1 FIRST, then R4E.  R4E's addr_decoder hunk wraps W1's own `data_read`
# assign, so W1 applied afterwards trips its exactly-once anchor assert.
# =====================================================================================

MARKER_R4E = 'RXFIX_R4E'   # NB: 'RXFIX_R4' is a PREFIX of it -- see _has()

R4E_CORE_FILES = ['Validate_Input_Push_Pop_block.v', 'FIFO_block.v', 'Rate_Handle.v',
                  'Symbol_Synchronizer.v', 'Frequency_and_Time_Synchronizer.v']
# the ninth-word carry chain: patched ONLY where RXFIX_W1 is already present
R4E_WIT_RTL_FILES = ['QPSK_Rx.v', 'Receiver.v', 'TxRxComposite.v']
R4E_WIT_IP_FILES = ['TxRxCompo_ip_dut.v', 'TxRxCompo_ip_axi_lite.v',
                    'TxRxCompo_ip_addr_decoder.v', 'TxRxCompo_ip.v']


def _r4e_guard(s):
    """R4E refuses to stack on R3/R3S/R4/R4B/R4D.

    R4B is in the list because R4E CONTAINS R4B's skip side: applying both would
    redefine Rate_Handle.Logical_Operator_out1 twice.  Cloning, not stacking, is what
    makes the EMPTY side provably identical to R4B's."""
    for m in (MARKER_R3, MARKER_R3S, MARKER_R4, MARKER_R4B, MARKER_R4D):
        assert not _has(s, m), (
            f'{m} is already present -- it and RXFIX_R4E both redefine '
            'Rate_Handle.Logical_Operator_out1 and are mutually exclusive')


def _r4e_add_port(s, module, decl, what):
    """Append `decl` to `module`'s port list (PREFIX-TOLERANT: kit lineage included)."""
    _, j = _span(s, r'module\s+' + _PFX + module + r'\s*\(', what)
    return s[:j] + ',\n           // RXFIX_R4E\n           ' + decl + '\n          ' + s[j:]


def _r4e_add_pin(s, module, inst, pin, what):
    """Append `pin` to the instantiation `[prefix]module inst (...)`."""
    _, j = _span(s, r'\b' + _PFX + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // RXFIX_R4E\n' + ' ' * 24 + s[j:]


# ---- 1. Validate_Input_Push_Pop_block.v: export the TRUE occupancy ------------
def patch_vipp_block_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    _r4e_guard(s)
    s = _r4e_add_port(s, 'Validate_Input_Push_Pop_block', 'r4eOcc',
                      'R4E VIPP_block r4eOcc port')
    s = _sub(s, "  output  valid_pop;\n",
             "  output  valid_pop;\n"
             "  // RXFIX_R4E: the registered TRUE ring occupancy, 0..32 (Delay_out1).  This\n"
             "  // is the SAME net Compare_To_Constant_block compares against 6'b000000 to\n"
             "  // form pop_on_empty_FIFO, so it is the ring's own occupancy, not a pointer\n"
             "  // delta.  Read-only tap.\n"
             "  output  [5:0] r4eOcc;\n", 'R4E VIPP_block r4eOcc declaration')
    s = _sub(s, "  assign valid_pop = Logical_Operator7_out1;\n",
             "  assign valid_pop = Logical_Operator7_out1;\n\n"
             "  assign r4eOcc = Delay_out1;  // RXFIX_R4E\n",
             'R4E VIPP_block r4eOcc assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 2. FIFO_block.v: pass the occupancy up to Rate_Handle --------------------
def patch_fifo_block_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    _r4e_guard(s)
    s = _r4e_add_port(s, 'FIFO_block', 'r4eOcc', 'R4E FIFO_block r4eOcc port')
    s = _sub(s, "  output  validPop;\n",
             "  output  validPop;\n"
             "  // RXFIX_R4E: registered TRUE ring occupancy, 0..32.\n"
             "  output  [5:0] r4eOcc;\n", 'R4E FIFO_block r4eOcc declaration')
    s = _r4e_add_pin(s, 'Validate_Input_Push_Pop_block', 'u_Validate_Input_Push_Pop',
                     '.r4eOcc(r4eOcc)', 'R4E FIFO_block VIPP instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 3. Rate_Handle.v: the structural window, the registered decision, the skip
RH_POP_OLD_R4E = "  assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;\n"
RH_POP_NEW_R4E = """  // ---- RXFIX_R4E: R4B's EMPTY-side skip, plus the FULL side's DROPPED PUSH -------
  // THE EMPTY SIDE IS R4B, UNCHANGED.  r4e_pop_nom is the baseline pop (the rigid mod-4
  // phase); inside a window of 13 nominal pop slots opened by the deframer's own
  // end-of-packet pulse, while locked and while the ring occupancy is <= 8, exactly one
  // pop is suppressed.  Everything is registered, so the ONLY combinational path into
  // the pop is the baseline's own guard, and before the first arm this line IS the
  // baseline line -- R4E fails toward BASELINE.
  //
  // THE FULL SIDE IS A DROPPED PUSH, WHICH IS THE NATURAL EVENT'S OWN SHAPE.
  // push_on_full discards a push and touches nothing on the pop side, so the popped
  // valid density is UNCHANGED and one symbol vanishes at a random position.  R4E takes
  // the same deletion deliberately, scheduled so the vanished symbol would have been
  // popped inside the SAME 13-slot structural window.  Unlike R4D's extra pop it adds no
  // valid, so the Preamble_Detector realignment FIFO -- which sits AT its 12,333 full
  // threshold because its pop is tick-indexed -- sees nothing at all.
  //
  // THE SCHEDULE.  A push dropped at tick t is emitted on the (occ + 1)-th validated pop
  // after t, so with m = validated pops in [t, pcEnd] the vanished symbol lands in window
  // slot k = occ + 1 - m.  At pcEnd itself slot k's symbol was pushed (occ - k) pushes
  // BACK -- 11..23 pushes in the past for occ >= 24 -- so the decision CANNOT be taken at
  // pcEnd and must be taken 12..31 pops ahead of one.  The predictor is the MEASURED
  // frame period in validated pops (r4e_period), and k_hat = occ + 1 - period + pcnt.
  // The arm band [+6,+10] is k_hat in [7,11], ASYMMETRIC because every staleness source
  // pushes the realised k UP and never down.
  assign r4e_pop_nom = validIn & Compare_To_Constant_out1;

  // LOCK: eight pcEnd pulses since reset.
  assign r4e_locked = r4e_frames == 4'b1000;

  assign r4e_do_skip = r4e_skip_en & r4e_pop_nom;

  assign Logical_Operator_out1 = r4e_pop_nom & ( ~r4e_skip_en);

  // ---- the FULL side ------------------------------------------------------------
  // FIFO_validPop is the ring's OWN validated pop (pop & ~pop_on_empty), which is the
  // unit the pointer arithmetic above is in.
  assign r4e_pop_val = FIFO_validPop;

  assign r4e_do_drop = r4e_drop_en & strobe;

  // THE DROP.  Structurally `strobe` until the first arm, exactly as the pop above is
  // structurally the baseline expression until its first arm.
  assign r4e_push_st = strobe & ( ~r4e_drop_en);

  // the registered schedule's operands, 15 bits so pcnt + occ cannot overflow
  assign r4e_sum15 = {1'b0, r4e_pcnt} + {9'b0, r4e_occ};

  assign r4e_ref15 = {1'b0, r4e_period};

  // the MEASURED landing slot of the pending drop: k = occ_at_drop + 1 - m, where
  // m = validated pops in [drop, pcEnd].  Combinational, consumed only by the flops
  // below, so nothing here reaches the pop or the push.
  assign r4e_m15 = {1'b0, r4e_pcnt} - {1'b0, r4e_land_a};

  assign r4e_o15 = {9'b0, r4e_land_occ};

  assign r4e_l_neg = r4e_m15 > r4e_o15;

  assign r4e_l_val = (r4e_o15 + 15'b000000000000001) - r4e_m15;

  assign r4e_l_slot = (r4e_l_neg == 1'b1 ? 4'b0000 :
              (r4e_l_val > 15'b000000000001111 ? 4'b1111 : r4e_l_val[3:0]));

  assign r4e_l_out = r4e_l_neg | (r4e_l_val > 15'b000000000001101);

  always @(posedge clk or posedge reset)
    begin : r4e_steer_process
      if (reset == 1'b1) begin
        r4e_pcend_d <= 1'b0;
        r4e_occ_le8 <= 1'b0;
        r4e_win <= 1'b0;
        r4e_wslot <= 4'b0000;
        r4e_skip_done <= 1'b0;
        r4e_skip_en <= 1'b0;
        r4e_frames <= 4'b0000;
        r4e_skips <= 16'b0000000000000000;
        r4e_opens <= 15'b000000000000000;
        r4e_occ_ge24 <= 1'b0;
        r4e_pcnt <= 14'b00000000000000;
        r4e_period <= 14'b00000000000000;
        r4e_per_ok <= 1'b0;
        r4e_sched_lo <= 1'b0;
        r4e_sched_hi <= 1'b0;
        r4e_drop_en <= 1'b0;
        r4e_drop_done <= 1'b0;
        r4e_drops <= 16'b0000000000000000;
        r4e_land_pend <= 1'b0;
        r4e_land_a <= 14'b00000000000000;
        r4e_land_occ <= 6'b000000;
        r4e_land_last <= 4'b0000;
        r4e_land_min <= 4'b1111;
        r4e_land_max <= 4'b0000;
        r4e_land_out <= 4'b0000;
      end
      else begin
        if (enb_1_2_0) begin
          // (a) register the two long paths and BOTH occupancy compares.
          //     Packet_Controller.endOut is exactly ONE enb tick wide, so one flop is a
          //     complete edge detector.
          r4e_pcend_d <= pcEndIn;
          r4e_occ_le8 <= (r4e_occ <= 6'b001000);
          r4e_occ_ge24 <= (r4e_occ >= 6'b011000);
          // (a2) the FULL-side SCHEDULE, registered.  [+6,+10] is k_hat in [7,11].
          r4e_sched_lo <= (r4e_sum15 >= (r4e_ref15 + 15'b000000000000110));
          r4e_sched_hi <= (r4e_sum15 <= (r4e_ref15 + 15'b000000000001010));
          // (b) LOCK
          if (r4e_pcend_d && ( ~r4e_locked)) begin
            r4e_frames <= r4e_frames + 4'b0001;
          end
          // (c) the skip itself + its witness
          if (r4e_do_skip) begin
            r4e_skips <= r4e_skips + 16'b0000000000000001;
            r4e_skip_done <= 1'b1;
          end
          // (d) the window advances one slot per NOMINAL pop opportunity, whether or
          //     not that pop was taken, and closes after the 13th.
          if (r4e_win && r4e_pop_nom) begin
            if (r4e_wslot >= 4'b1101) begin
              r4e_win <= 1'b0;
            end
            else begin
              r4e_wslot <= r4e_wslot + 4'b0001;
            end
          end
          // (e) a pcEnd OPENS the window.
          if (r4e_pcend_d) begin
            r4e_win <= 1'b1;
            r4e_wslot <= 4'b0000;
            r4e_skip_done <= 1'b0;
            r4e_opens <= r4e_opens + 15'b000000000000001;
          end
          // (f) THE REGISTERED SKIP DECISION.  r4e_wslot <= 12 keeps the skip inside
          //     slots [pcEnd+1, pcEnd+13].
          if (r4e_do_skip) begin
            r4e_skip_en <= 1'b0;
          end
          else begin
            r4e_skip_en <= r4e_locked & r4e_win & r4e_occ_le8 & ( ~r4e_skip_done) &
                        (r4e_wslot <= 4'b1100);
          end
          // (g) THE VALIDATED-POP CLOCK.  pcnt counts validated pops since the last
          //     pcEnd and saturates; period is the pops in the interval just closed;
          //     per_ok rejects a saturated (missed-pcEnd) or implausibly short period,
          //     so a lost deframer fails the schedule toward BASELINE.
          if (r4e_pcend_d) begin
            r4e_pcnt <= (r4e_pop_val == 1'b1 ? 14'b00000000000001 :
                        14'b00000000000000);
            r4e_period <= r4e_pcnt;
            r4e_per_ok <= (r4e_pcnt >= 14'b00000001000000) &&
                        (r4e_pcnt < 14'b11111111111111);
            r4e_drop_done <= 1'b0;
          end
          else if (r4e_pop_val && (r4e_pcnt != 14'b11111111111111)) begin
            r4e_pcnt <= r4e_pcnt + 14'b00000000000001;
          end
          // (h) RESOLVE the pending drop's MEASURED landing slot against the pcEnd it
          //     was scheduled for.  r4e_pcnt is read here BEFORE (g)'s reload takes
          //     effect, so m = r4e_pcnt - r4e_land_a is exactly the validated pops in
          //     [drop, pcEnd].
          if (r4e_pcend_d && r4e_land_pend) begin
            r4e_land_pend <= 1'b0;
            r4e_land_last <= r4e_l_slot;
            if (r4e_l_slot < r4e_land_min) begin
              r4e_land_min <= r4e_l_slot;
            end
            if (r4e_l_slot > r4e_land_max) begin
              r4e_land_max <= r4e_l_slot;
            end
            if (r4e_l_out && (r4e_land_out != 4'b1111)) begin
              r4e_land_out <= r4e_land_out + 4'b0001;
            end
          end
          // (i) THE DROP + its witness.  Placed AFTER (h) so that a drop coinciding with
          //     a pcEnd leaves its own measurement pending instead of clobbering the one
          //     just resolved, and after (g) so drop_done wins over the pcEnd clear --
          //     the conservative direction, since the invariant to protect is AT MOST ONE
          //     DROP PER pcEnd.  The schedule puts the drop ~24 pops before a pcEnd, so
          //     neither coincidence is expected; both are visible in r4e_land_out.
          if (r4e_do_drop) begin
            r4e_drops <= r4e_drops + 16'b0000000000000001;
            r4e_drop_done <= 1'b1;
            r4e_land_pend <= 1'b1;
            r4e_land_a <= r4e_pcnt;
            r4e_land_occ <= r4e_occ;
          end
          // (j) THE REGISTERED DROP DECISION.  Exactly one per pcEnd, only while locked,
          //     only with a plausible measured period, only at occupancy >= 24, and only
          //     inside the scheduled band.
          if (r4e_do_drop) begin
            r4e_drop_en <= 1'b0;
          end
          else begin
            r4e_drop_en <= r4e_locked & r4e_per_ok & r4e_occ_ge24 &
                        ( ~r4e_drop_done) & r4e_sched_lo & r4e_sched_hi;
          end
        end
      end
    end
"""

R4E_WIT_ASSIGN = ("\n  // RXFIX_R4E: the silicon witness, TWO 32-bit read words (0x234, 0x238).\n"
                  "  //   word 0 = r4eWit[31:0]  = 0x234 = {locked, skips[15:0], window_opens[14:0]}\n"
                  "  //                                     (R4B's layout)\n"
                  "  //   word 1 = r4eWit[63:32] = 0x238 = {land_out[3:0], land_max[3:0],\n"
                  "  //            land_min[3:0], land_last[3:0], drops[15:0]}  (the FULL side)\n"
                  "  // Leftmost concatenation element = most significant = word 1; the\n"
                  "  // addr_decoder maps word i to address 0x8D+i (r4e_idx).\n"
                  "  // The brief asked for a landing-slot HISTOGRAM in one word; a 13-bin\n"
                  "  // histogram does not fit beside a 16-bit counter, so the silicon form is\n"
                  "  // the ORDER STATISTIC -- last / min / max / out-of-window count.\n"
                  "  // land_out != 0 is the falsifier; min >= 1 and max <= 13 is the pass.\n"
                  "  // See two_jup/rxfix/W1_REGMAP.md sec 6-R4E.  Present only when W1 is,\n"
                  "  // because W1 owns the read path that carries it out.\n"
                  "  assign r4eWit = {{r4e_land_out, r4e_land_max, r4e_land_min,\n"
                  "                    r4e_land_last, r4e_drops},\n"
                  "                   {r4e_locked, r4e_skips, r4e_opens}};  // RXFIX_R4E\n")


def patch_rate_handle_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    _r4e_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4e_add_port(s, 'Rate_Handle', 'pcEndIn', 'R4E Rate_Handle pcEndIn port')
    if wit:
        s = _r4e_add_port(s, 'Rate_Handle', 'r4eWit', 'R4E Rate_Handle r4eWit port')
    decl = ("  output  validOut;\n"
            "  // RXFIX_R4E: the deframer's end-of-packet pulse (Packet_Controller.endOut),\n"
            "  // which opens the 13-slot structural skip window.  Registered on arrival.\n"
            "  input   pcEndIn;\n")
    if wit:
        decl += ("  // RXFIX_R4E: {locked, skips[15:0], window_opens[14:0]} for the ninth W1\n"
                 "  // read word at 0x234.\n"
                 "  output  [63:0] r4eWit;\n")
    decl += ("\n"
             "  wire [5:0] r4e_occ;  // ufix6, the TRUE registered ring occupancy\n"
             "  wire r4e_pop_nom;\n"
             "  wire r4e_locked;\n"
             "  wire r4e_do_skip;\n"
             "  reg  r4e_pcend_d;     // pcEndIn, registered (breaks the 4-level path)\n"
             "  reg  r4e_occ_le8;     // the EMPTY-side compare, registered\n"
             "  reg  r4e_win;         // the structural window is open\n"
             "  reg [3:0] r4e_wslot;  // ufix4, nominal pop slots since the window opened\n"
             "  reg  r4e_skip_done;   // one skip per window\n"
             "  reg  r4e_skip_en;     // THE REGISTERED DECISION (EMPTY side)\n"
             "  reg [3:0] r4e_frames; // ufix4, pcEnd pulses, saturating at 8 = locked\n"
             "  reg [15:0] r4e_skips; // WITNESS: steered pop SKIPS\n"
             "  reg [14:0] r4e_opens; // WITNESS: structural windows opened\n"
             "  // RXFIX_R4E: the FULL side -- a DROPPED PUSH, scheduled by the measured\n"
             "  // frame period so the vanished symbol lands in the structural window.\n"
             "  wire r4e_pop_val;     // FIFO_validPop: the ring's OWN validated pop\n"
             "  wire r4e_do_drop;\n"
             "  wire r4e_push_st;     // the gated push into FIFO_block\n"
             "  wire [14:0] r4e_sum15;// ufix15, pcnt + occ\n"
             "  wire [14:0] r4e_ref15;// ufix15, the measured period\n"
             "  wire [14:0] r4e_m15;  // ufix15, validated pops in [drop, pcEnd]\n"
             "  wire [14:0] r4e_o15;  // ufix15, occupancy at the drop\n"
             "  wire [14:0] r4e_l_val;// ufix15, occ + 1 - m = the MEASURED landing slot\n"
             "  wire r4e_l_neg;       // the drop landed at or before the pcEnd\n"
             "  wire r4e_l_out;       // the drop landed outside slots [1,13]\n"
             "  wire [3:0] r4e_l_slot;\n"
             "  reg  r4e_occ_ge24;    // the FULL-side compare, registered\n"
             "  reg [13:0] r4e_pcnt;  // ufix14, validated pops since the last pcEnd\n"
             "  reg [13:0] r4e_period;// ufix14, validated pops per frame, MEASURED\n"
             "  reg  r4e_per_ok;      // the measured period is plausible\n"
             "  reg  r4e_sched_lo;    // k_hat >= 7,  registered\n"
             "  reg  r4e_sched_hi;    // k_hat <= 11, registered\n"
             "  reg  r4e_drop_en;     // THE REGISTERED DECISION (FULL side)\n"
             "  reg  r4e_drop_done;   // one drop per pcEnd\n"
             "  reg [15:0] r4e_drops; // WITNESS: dropped pushes\n"
             "  reg  r4e_land_pend;   // a drop is awaiting its landing measurement\n"
             "  reg [13:0] r4e_land_a;// pcnt at the drop\n"
             "  reg [5:0] r4e_land_occ;// occupancy at the drop\n"
             "  reg [3:0] r4e_land_last;// WITNESS: last measured landing slot\n"
             "  reg [3:0] r4e_land_min; // WITNESS: smallest, init 15\n"
             "  reg [3:0] r4e_land_max; // WITNESS: largest\n"
             "  reg [3:0] r4e_land_out; // WITNESS: drops outside [1,13], saturating\n")
    s = _sub(s, "  output  validOut;\n", decl, 'R4E Rate_Handle declarations')
    body = RH_POP_NEW_R4E + (R4E_WIT_ASSIGN if wit else "")
    s = _sub(s, RH_POP_OLD_R4E, body, 'R4E Rate_Handle steered pop')
    s = _r4e_add_pin(s, 'FIFO_block', 'u_FIFO', '.r4eOcc(r4e_occ)',
                     'R4E Rate_Handle FIFO_block instantiation')
    # THE DROP ITSELF: the ring's push is gated by the registered decision.  This is the
    # only data-path edit outside the pop expression, and it is structurally `strobe`
    # until the first arm (r4e_push_st = strobe & ~r4e_drop_en, r4e_drop_en a flop).
    s = _sub(s, "                     .push(strobe),\n",
             "                     .push(r4e_push_st),  // RXFIX_R4E: the DROPPED PUSH\n",
             'R4E Rate_Handle gated push')
    open(path, 'w').write(s)
    return 'patched'


# ---- 4. Symbol_Synchronizer.v: route pcEnd down (and the witness up) ----------
def patch_symbol_synchronizer_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    _r4e_guard(s)
    wit = _has(s, MARKER_W1)
    s = _r4e_add_port(s, 'Symbol_Synchronizer', 'pcEndIn',
                      'R4E Symbol_Synchronizer pcEndIn port')
    decl = ("  input   [31:0] ss_integ_gain;  // uint32\n"
            "  input   pcEndIn;  // RXFIX_R4E: deframer end-of-packet, opens the window\n")
    pin = '.pcEndIn(pcEndIn)'
    if wit:
        s = _r4e_add_port(s, 'Symbol_Synchronizer', 'r4eWit',
                          'R4E Symbol_Synchronizer r4eWit port')
        decl += ("  output  [63:0] r4eWit;  // RXFIX_R4E: witness words, pass-through\n")
        pin += ',\n' + ' ' * 24 + '.r4eWit(r4eWit)'
    s = _sub(s, "  input   [31:0] ss_integ_gain;  // uint32\n", decl,
             'R4E Symbol_Synchronizer declarations')
    s = _r4e_add_pin(s, 'Rate_Handle', 'u_Rate_Handle', pin,
                     'R4E Symbol_Synchronizer Rate_Handle instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 5. Frequency_and_Time_Synchronizer.v: close the loop --------------------
def patch_freq_time_sync_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    _r4e_guard(s)
    wit = _has(s, MARKER_W1)
    pin = '.pcEndIn(Packet_Controller_endOut)'
    if wit:
        s = _r4e_add_port(s, 'Frequency_and_Time_Synchronizer', 'r4eWit', 'R4E FTS r4eWit port')
        s = _sub(s, "  assign validOut = Packet_Controller_validOut;\n",
                 "  assign r4eWit = r4e_wit;  // RXFIX_R4E\n\n"
                 "  assign validOut = Packet_Controller_validOut;\n",
                 'R4E FTS r4eWit assign')
        pin += ',\n' + ' ' * 24 + '.r4eWit(r4e_wit)'
    decl = ("  // RXFIX_R4E: the deframer's own end-of-packet pulse, fed back to the\n"
            "  // Rate_Handle ring as the opener of the 13-slot structural skip window.\n"
            "  // Packet_Controller_endOut is an EXISTING wire (:104) on an EXISTING port\n"
            "  // (Packet_Controller.v:47) -- no new port is created anywhere for it, and\n"
            "  // it is registered inside sample_discard_controller, so nothing\n"
            "  // combinational is added to the receive chain.\n")
    if wit:
        decl += ("  output  [63:0] r4eWit;\n"
                 "  wire [63:0] r4e_wit;\n")
    s = _sub(s, "  wire Packet_Controller_endOut;\n",
             "  wire Packet_Controller_endOut;\n" + decl, 'R4E FTS declarations')
    s = _r4e_add_pin(s, 'Symbol_Synchronizer', 'u_Symbol_Synchronizer', pin,
                     'R4E FTS Symbol_Synchronizer instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 6..8. the witness carry chain through the RTL wrappers -------------------
def _r4e_pass_through(module, inst_module, inst, what_prefix, anchor=None):
    """Add a 32-bit r4eWit output and pin it from `inst`.  W1-CONDITIONAL: if this file
    does not already carry RXFIX_W1 there is no read path for the word, so the witness
    stays internal and the file is left untouched ('skipped')."""
    def _fn(path, sim_tree=False):
        s = open(path).read()
        if _has(s, MARKER_R4E):
            return 'already'
        _r4e_guard(s)
        if not _has(s, MARKER_W1):
            return 'skipped'
        s = _r4e_add_port(s, module, 'r4eWit', what_prefix + ' r4eWit port')
        a = W1_DECL_ANCHOR if anchor is None else anchor
        s = _sub(s, a, a + "  // RXFIX_R4E: witness word, pass-through to the ninth W1\n"
                          "  // read word at 0x234.\n"
                          "  output  [63:0] r4eWit;\n", what_prefix + ' declarations')
        s = _r4e_add_pin(s, inst_module, inst, '.r4eWit(r4eWit)',
                         what_prefix + ' ' + inst_module + ' instantiation')
        open(path, 'w').write(s)
        return 'patched'
    return _fn


patch_qpsk_rx_r4e = _r4e_pass_through(
    'QPSK_Rx', 'Frequency_and_Time_Synchronizer', 'u_Frequency_and_Time_Synchronizer',
    'R4E QPSK_Rx')
patch_receiver_r4e = _r4e_pass_through('Receiver', 'QPSK_Rx', 'u_QPSK_Rx', 'R4E Receiver')
patch_txrxcomposite_r4e = _r4e_pass_through('TxRxComposite', 'Receiver', 'u_Receiver',
                                            'R4E TxRxComposite')


# ---- 9. TxRxCompo_ip_dut.v ----------------------------------------------------
def patch_ip_dut_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4e_add_port(s, 'TxRxCompo_ip_dut', 'r4e_wit', 'R4E dut r4e_wit port')
    s = _sub(s, "  input   [31:0] fixctl;  // ufix32\n",
             "  input   [31:0] fixctl;  // ufix32\n"
             "  // RXFIX_R4E: witness word out of the DUT wrapper.\n"
             "  output  [63:0] r4e_wit;  // ufix64\n"
             "  wire [63:0] r4e_wit_sig;  // ufix64\n", 'R4E dut declarations')
    s = _r4e_add_pin(s, 'TxRxComposite', 'u_TxRxCompo_ip_src_TxRxComposite',
                     '.r4eWit(r4e_wit_sig)', 'R4E dut TxRxComposite instantiation')
    s = _sub(s, "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n",
             "  assign w1_bus = w1_bus_sig;  // RXFIX_W1\n\n"
             "  assign r4e_wit = r4e_wit_sig;  // RXFIX_R4E\n", 'R4E dut witness assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 10. TxRxCompo_ip_axi_lite.v ---------------------------------------------
def patch_ip_axi_lite_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4e_add_port(s, 'TxRxCompo_ip_axi_lite', 'read_r4e_wit', 'R4E axi_lite port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4E: witness word into the read decoder.\n"
             "  input   [63:0] read_r4e_wit;  // ufix64\n", 'R4E axi_lite declarations')
    s = _r4e_add_pin(s, 'TxRxCompo_ip_addr_decoder', 'u_TxRxCompo_ip_addr_decoder_inst',
                     '.read_r4e_wit(read_r4e_wit)', 'R4E axi_lite addr_decoder instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 11. TxRxCompo_ip_addr_decoder.v: the NINTH read word at 0x234 ------------
# The eight W1 words are NOT touched: w1_reg, w1_hit (0x85..0x8C), w1_idx and the
# w1_reg_process are left byte-identical, and the only W1 line R4E rewrites is the ONE
# `assign data_read` line -- because there is exactly one data_read in the module and a
# ninth word has to come from somewhere.  A test asserts the byte-identity of everything
# else W1 injected.
W1_DATA_READ_LINE = ("  assign data_read = (w1_hit ? w1_reg[w1_idx] : mux_out0_level1);"
                     "  // RXFIX_W1\n")


def patch_ip_addr_decoder_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _r4e_add_port(s, 'TxRxCompo_ip_addr_decoder', 'read_r4e_wit',
                      'R4E addr_decoder port')
    s = _sub(s, "  input   [255:0] read_w1_bus;  // ufix256\n",
             "  input   [255:0] read_w1_bus;  // ufix256\n"
             "  // RXFIX_R4E: TWO free read words at bytes 0x234/0x238 (words\n"
             "  // 0x8D/0x8E), one past W1's 0x85..0x8C.  0x234 = {locked, skips[15:0],\n"
             "  // window_opens[14:0]}; 0x238 = {land_out, land_max,\n"
             "  // land_min, land_last, drops[15:0]}.  Each is ONE word, so\n"
             "  // each is coherent on a single AXI read and needs no place in W1's freeze\n"
             "  // shadow; W1's eight words are untouched.\n"
             "  // Word i of the bus is read_r4e_wit[32*i +: 32] and answers address 0x8D+i\n"
             "  // (r4e_idx below) -- W1's own w1_idx convention.\n"
             "  input   [63:0] read_r4e_wit;  // ufix64\n"
             "  reg [31:0] r4e_reg [0:1];\n  integer r4e_i;\n"
             "  wire r4e_hit;\n"
             "  wire r4e_idx;\n", 'R4E addr_decoder declarations')
    s = _sub(s, W1_DATA_READ_LINE,
             "  // RXFIX_R4E -----------------------------------------------------------------\n"
             "  always @(posedge clk or posedge reset)\n"
             "    begin : r4e_reg_process\n"
             "      if (reset == 1'b1) begin\n"
             "        for (r4e_i = 0; r4e_i < 2; r4e_i = r4e_i + 1) begin\n"
             "          r4e_reg[r4e_i] <= 32'b0;\n"
             "        end\n"
             "      end\n"
             "      else begin\n"
             "        if (enb) begin\n"
             "          for (r4e_i = 0; r4e_i < 2; r4e_i = r4e_i + 1) begin\n"
             "            r4e_reg[r4e_i] <= read_r4e_wit[32*r4e_i +: 32];\n"
             "          end\n"
             "        end\n"
             "      end\n"
             "    end\n\n"
             "  assign r4e_hit = (address_select_level1 == 8'h8D) ||\n"
             "              (address_select_level1 == 8'h8E);\n\n"
             "  // Word index = address - 0x8D:  0x8D (byte 0x234) -> r4e_reg[0] =\n"
             "  // read_r4e_wit[31:0] = {locked, skips, opens};  0x8E (byte 0x238) ->\n"
             "  // r4e_reg[1] = read_r4e_wit[63:32] = {land_out, land_max, land_min,\n"
             "  // land_last, drops}.  (Task 33: R4D's first cut indexed by\n"
             "  // address_select_level1[0] and came out swapped on silicon; R4E never\n"
             "  // built, so no image carries the swapped R4E order.)\n"
             "  assign r4e_idx = (address_select_level1 == 8'h8E);\n\n"
             "  assign data_read = (r4e_hit ? r4e_reg[r4e_idx] :\n"
             "              (w1_hit ? w1_reg[w1_idx] : mux_out0_level1));  // RXFIX_R4E\n",
             'R4E addr_decoder ninth read word')
    open(path, 'w').write(s)
    return 'patched'


# ---- 12. TxRxCompo_ip.v -------------------------------------------------------
def patch_ip_top_r4e(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_R4E):
        return 'already'
    if not _has(s, MARKER_W1):
        return 'skipped'
    s = _sub(s, "  wire [255:0] w1_bus_sig;  // ufix256\n",
             "  wire [255:0] w1_bus_sig;  // ufix256\n"
             "  // RXFIX_R4E: DUT witness word -> AXI-lite read decoder.  Internal only:\n"
             "  // no TxRxCompo_ip port is added, so component.xml is unchanged.\n"
             "  wire [63:0] r4e_wit_sig;  // ufix64\n", 'R4E ip top declarations')
    s = _r4e_add_pin(s, 'TxRxCompo_ip_axi_lite', 'u_TxRxCompo_ip_axi_lite_inst',
                     '.read_r4e_wit(r4e_wit_sig)', 'R4E ip top axi_lite instantiation')
    s = _r4e_add_pin(s, 'TxRxCompo_ip_dut', 'u_TxRxCompo_ip_dut_inst',
                     '.r4e_wit(r4e_wit_sig)', 'R4E ip top dut instantiation')
    open(path, 'w').write(s)
    return 'patched'


R4E_PATCHERS = {
    'Validate_Input_Push_Pop_block.v': patch_vipp_block_r4e,
    'FIFO_block.v': patch_fifo_block_r4e,
    'Rate_Handle.v': patch_rate_handle_r4e,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer_r4e,
    'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r4e,
    'QPSK_Rx.v': patch_qpsk_rx_r4e,
    'Receiver.v': patch_receiver_r4e,
    'TxRxComposite.v': patch_txrxcomposite_r4e,
    'TxRxCompo_ip_dut.v': patch_ip_dut_r4e,
    'TxRxCompo_ip_axi_lite.v': patch_ip_axi_lite_r4e,
    'TxRxCompo_ip_addr_decoder.v': patch_ip_addr_decoder_r4e,
    'TxRxCompo_ip.v': patch_ip_top_r4e,
}


def r4e_files(sim_tree):
    """R4E's file set: the Verilator tree has no TxRxCompo_ip_* wrapper files."""
    f = list(R4E_CORE_FILES) + list(R4E_WIT_RTL_FILES)
    return f if sim_tree else f + list(R4E_WIT_IP_FILES)


# =====================================================================================
# RXFIX_BS -- the BYTE-SEAM census instrument (Task 46).
#
# Design: two_jup/comb/BYTESEAM_INSTRUMENT.md sec 2 ("RXFIX_BS1").  Register map:
# two_jup/rxfix/W1_REGMAP.md sec 7-BS.  Pre-registration for the sim gate:
# two_jup/comb/RXFIX_BS1_SIM_GATE.md (committed with this code; its numbers were
# fixed before any leg ran and the file says so in its own text).
#
# WHAT IT IS.  Eight read-only counters on the byte plane -- the stretch from the
# ByteSerializer's word emitter to the ByteRxFifo's egress -- read through eight new
# words on W1's AXI read path at bytes 0x23C..0x258, behind W1's existing freeze level
# fixctl[4].  No net is redefined, no data-path expression is touched, no
# TxRxCompo_ip top-level port is added, so the s = 0 sim identity is STRUCTURAL in
# exactly the sense W1_REGMAP sec 4 argues for W1.
#
# ---------------------------------------------------------------------------------
# FOUR PLACES WHERE THE DESIGN DOCUMENT AND THE NETLIST DISAGREE.  The netlist wins;
# each deviation is recorded here rather than in a summary, because the document is
# the pre-registration and a silent deviation is the failure mode this campaign has
# already been bitten by (W1_REGMAP sec 6-R4D.2).
#
# (1) `bs_bits` IS NOT BUILT.  Sec 2.2 lists it as a new 32-bit counter on
#     RxAlign.validOut and sec 2.3 as an optional ninth word at 0x25C.  It already
#     exists in silicon: FEC_Decoder_Wrapper instantiates FecCounters with
#     e5 = RxAlign.validOut and e6 = RxAlign.startOut (FEC_Decoder_Wrapper.v:249-263),
#     and the addr_decoder decodes c5 at word 0x4C (byte 0x130, cnt_dec_bits) and c6 at
#     word 0x4D (byte 0x134, cnt_bist_start) on every image of this lineage.  So P8
#     costs no flops at all.  ONE CAVEAT, and it is a hard one: FecCounters
#     SATURATES rather than wraps (`if (e5 && (k5 < 32'd4294967295))` then clamp,
#     FecCounters.v:232-239), so cnt_dec_bits pins at 0xFFFFFFFF after ~281 s of run
#     time and is CONSTANT thereafter -- which would make P8 ("bs_bits/bs_starts
#     constant") pass trivially.  The reader must refuse to score P8 when 0x130 reads
#     all-ones.  0x134 saturates in ~39.9 d and is safe.
#     Consequence for sec 3's timing risk 1 (hierarchy depth): the deep RxAlign tap
#     that motivated it does not exist, and neither does the risk.  See (2).
#
# (2) THE TAPS ARE AT HIERARCHY LEVEL 1, NOT 4.  Sec 3 risk 1 assumed
#     bs_bits/bs_starts had to be taken inside Receiver/QPSK_Rx/FEC_Decoder_Wrapper/
#     RxAlign.  They do not: ByteSerializer and ByteRxFifo are instantiated DIRECTLY in
#     TxRxComposite (TxRxComposite.v:1460,1521 on the sim lineage; :1581,1642 on the
#     kit lineage), and RxAlign's startOut arrives there as `Receiver_recStart` (the
#     chain RxAlign.startOut -> FEC_Decoder_Wrapper.startOut -> QPSK_Rx.ctrlOut_startOut
#     -> Receiver.recStart, Receiver.v:460).  The census therefore lives in
#     TxRxComposite and the witness carry chain is FOUR files, all wrappers:
#     TxRxComposite -> TxRxCompo_ip_dut -> TxRxCompo_ip -> TxRxCompo_ip_axi_lite ->
#     TxRxCompo_ip_addr_decoder.  W1's chain is five RTL levels DEEPER than this one.
#
# (3) THERE IS NO CLOCK-DOMAIN CROSSING.  Sec 3 risk 2 called the serializer/FIFO
#     split an "enable-domain crossing ... must be declared and cdc_exceptions.xdc
#     reviewed".  Read off the netlist: ByteSerializer is `always @(posedge clk)` gated
#     by enb_1_2_0_gated and ByteRxFifo is `always @(posedge clk)` gated by enb_gated
#     (ByteSerializer.v:122, ByteRxFifo drop-in v5:75).  ONE clock, two clock enables.
#     No CDC, no xdc change.  The instrument exploits it: every shadow word is latched
#     on EVERY clk edge while freeze is low (not on an enb tick, as W1 does), so one
#     frozen sweep is coherent across both enable domains to a single clk edge.  That
#     is strictly stronger than W1's shadow and is the reason BS can be compared
#     word-for-word against W1's census in the same freeze window.
#
# (4) ONE ByteRxFifo FORM IS SUPPORTED, AND IT IS THE ONE IN THE BUILD TREES.  Every
#     build tree in this lineage carries the v5-DEBUG BRAM drop-in
#     (jupiter_240k5_byte/rxfifo_bram/ByteRxFifo.v, injected by rxfifo_inject.sh),
#     which names `push`, `pop` and `drop` as wires.  The HDL-Coder-generated 64-deep
#     module names none of them -- its drop is a combinational `nxt == rd` inside an
#     always @* block.  Patching both forms would mean the sim gate exercises a
#     DIFFERENT tap expression from the one the build ships, which is not a gate.  So
#     patch_byte_rx_fifo_bs REFUSES the generated form with a message naming
#     rxfifo_inject.sh, and the sim tree is built with the drop-in
#     (build_sro_bs.sh does the copy and asserts it).  This does NOT close O1 (which
#     ByteRxFifo is in the FLASHED image): no desk work can.
#
# ---------------------------------------------------------------------------------
# THE COUNTERS, THE TAP, AND WHAT MAKES EACH ONE FIRE (sec 2.4's binding rule).
#
#   bs_words   32  ByteSerializer `wv`               enbSer   skip_count poke; loopback 191/frame
#   bs_starts  32  Receiver_recStart (RxAlign)       enbSer   0x134 cnt_bist_start (independent HW)
#   bs_push    32  ByteRxFifo `push`                 enbFifo  bounded drain stall (push keeps running)
#   bs_pop     32  ByteRxFifo `pop`                  enbFifo  bounded drain stall (pop stops, resumes)
#   bs_drop    32  ByteRxFifo `drop`                 enbFifo  stall past DEPTH; sized deletion
#   bs_lasts   16  `wv && wl`                        enbSer   skip_count poke -> wordLast never fires
#   bs_markpush 16 `push && wFirst`                  enbFifo  same poke -> marks stop
#   bs_trunc   16  start with 1 <= wordCnt <= 190    enbSer   skip_count = 1536 -> every frame
#   bs_trunc_last/min/max 8+8+8  wordCnt at that start
#   bs_q24      8s truncations with (191-wordCnt) % 24 == 0   two pokes: one on the
#                                                    lattice (1536) and one OFF it
#   bs_dropmax  8s longest contiguous drop run       enbFifo  the stall legs
#
# `bs_q24`'s modulus is spelled as a 7-way equality against {24,48,...,168} rather
# than a divider: 191 - wordCnt is in 1..190 by the trunc predicate, so those are all
# the multiples of 24 it can take.
#
# ORDER: apply W1 (and R4B/R4D/R4E, if wanted) FIRST, then BS.  BS's decoder hunk
# wraps whatever single `assign data_read` is present, so it composes with all of
# them; applied the other way round W1's own literal anchor is gone and W1 fails
# loudly, which is the R4B/R4D rule and is tested.
# =====================================================================================

MARKER_BS = 'RXFIX_BS'

BS_CORE_FILES = ['ByteSerializer.v', 'ByteRxFifo.v', 'TxRxComposite.v']
BS_IP_FILES = ['TxRxCompo_ip_dut.v', 'TxRxCompo_ip_axi_lite.v',
               'TxRxCompo_ip_addr_decoder.v', 'TxRxCompo_ip.v']

# byte address of BS read word i.  ONE table, used by the RTL comment, the regmap doc
# and the address-resolver test; nothing recomputes it.
BS_WORD0 = 0x8F                      # AXI word index of BS_WORDS (byte 0x23C)
BS_NWORDS = 8


def _bs_guard(s):
    """BS is an instrument and stacks on anything; it only refuses ITSELF."""
    assert not _has(s, MARKER_BS), 'RXFIX_BS is already present'


def _bs_add_port(s, module, decl, what):
    """Append `decl` to `module`'s port list (prefix-tolerant, parameter-tolerant)."""
    _, j = _span(s, r'module\s+' + _PFX + module + r'\s*(?:#\s*\([^()]*\)\s*)?\(', what)
    return s[:j] + ',\n           // RXFIX_BS\n           ' + decl + '\n          ' + s[j:]


def _bs_add_pin(s, module, inst, pin, what):
    """Append `pin` to the instantiation `[prefix]module inst (...)`."""
    _, j = _span(s, r'\b' + _PFX + module + r'\s+' + inst + r'\s*\(', what)
    return s[:j] + ',\n' + ' ' * 24 + pin + '   // RXFIX_BS\n' + ' ' * 24 + s[j:]


def _bs_decl(s, text, what, anchor=None):
    a = W1_DECL_ANCHOR if anchor is None else anchor
    return _sub(s, a, a + text, what)


# ---- 1. ByteSerializer.v: the five word-plane taps ----------------------------
# wv / wl / state_wordCnt are module-scope regs driven by the block's combinational
# always @*; reading a reg in a continuous assign is legal and adds no logic.  They
# are only the "a word was emitted" event when qualified by enb_1_2_0_gated, which is
# exported with them so the census does the qualifying and this file states no policy.
def patch_byte_serializer_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    for p in ('bsWv', 'bsWl', 'bsStart', 'bsWordCnt', 'bsEnb'):
        s = _bs_add_port(s, 'ByteSerializer', p, 'BS ByteSerializer ' + p + ' port')
    s = _bs_decl(s,
                 "  // RXFIX_BS read-only taps on the word emitter.  wv = a 64-bit word\n"
                 "  // completed this step, wl = that word carries wordLast (ByteSerializer.v\n"
                 "  // 'wl = state_wordCnt_1 >= 191'), start = the Rx packet boundary that\n"
                 "  // DISCARDS the partial word and clears state_wordCnt, state_wordCnt = the\n"
                 "  // words already accumulated in the frame a start abandons (0 at a clean\n"
                 "  // boundary, 1..190 for a truncation).  bsEnb is this module's own gated\n"
                 "  // enable: every one of the four is an event only on an enb_1_2_0_gated\n"
                 "  // beat, and the census gates on bsEnb rather than assuming it.\n"
                 "  output  bsWv;\n"
                 "  output  bsWl;\n"
                 "  output  bsStart;\n"
                 "  output  [15:0] bsWordCnt;\n"
                 "  output  bsEnb;\n", 'BS ByteSerializer declarations')
    s = _sub(s, "  assign enb_1_2_0_gated = stateControl_2 && enb_1_2_0;\n",
             "  assign enb_1_2_0_gated = stateControl_2 && enb_1_2_0;\n\n"
             "  assign bsWv = wv;              // RXFIX_BS\n"
             "  assign bsWl = wl;              // RXFIX_BS\n"
             "  assign bsStart = start;        // RXFIX_BS\n"
             "  assign bsWordCnt = state_wordCnt;  // RXFIX_BS\n"
             "  assign bsEnb = enb_1_2_0_gated;    // RXFIX_BS\n",
             'BS ByteSerializer tap assigns')
    open(path, 'w').write(s)
    return 'patched'


# ---- 2. ByteRxFifo.v: the three seam events, from the drop-in's own wires ------
BS_FIFO_SIG = "  wire push     = (tog != prev);\n"
BS_FIFO_OVF = "  assign ovf      = stateControl_2 ? dbg         : ovf_last;\n"


def patch_byte_rx_fifo_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    # Deviation (4) in the header: the generated 64-deep module has no `push`/`pop`/
    # `drop` wire at all, and tapping its combinational always @* internals would make
    # the sim gate test an expression the build does not ship.  Refuse it by name.
    assert BS_FIFO_SIG in s, (
        "RXFIX_BS needs the v5 BRAM drop-in ByteRxFifo (its `push`/`pop`/`drop` wires); "
        f"{path} looks like the HDL-Coder-generated 64-deep module.  Run "
        "jupiter_240k5_byte/rxfifo_inject.sh on the build tree first (for a bare sim "
        "tree, copy jupiter_240k5_byte/rxfifo_bram/ByteRxFifo.v over it).")
    _, j = _span(s, r'module\s+' + _PFX + r'ByteRxFifo\s*(?:#\s*\([^()]*\)\s*)?\(',
                 'BS ByteRxFifo port list')
    s = (s[:j] + ',\n           bsPush, bsPop, bsDrop, bsEnbG'   # RXFIX_BS
         + s[j:])
    s = _sub(s, "  output [31:0]  ovf;      // uint32\n",
             "  output [31:0]  ovf;      // uint32\n"
             "  // RXFIX_BS read-only taps.  push = a serializer tog edge taken, pop =\n"
             "  // valid_i && ready_1 (a word leaving), drop = the drop-OLDEST on full --\n"
             "  // the only structure in the byte plane that deletes a word by design.\n"
             "  // bsEnbG is this module's own gated enable; all three are events only on\n"
             "  // an enb_gated beat.  Note drop implies push in this RTL.\n"
             "  output         bsPush;\n"
             "  output         bsPop;\n"
             "  output         bsDrop;\n"
             "  output         bsEnbG;\n", 'BS ByteRxFifo declarations')
    s = _sub(s, BS_FIFO_OVF,
             BS_FIFO_OVF +
             "  assign bsPush   = push;        // RXFIX_BS\n"
             "  assign bsPop    = pop;         // RXFIX_BS\n"
             "  assign bsDrop   = drop;        // RXFIX_BS\n"
             "  assign bsEnbG   = enb_gated;   // RXFIX_BS\n",
             'BS ByteRxFifo tap assigns')
    open(path, 'w').write(s)
    return 'patched'


# ---- 3. TxRxComposite.v: the census itself + the bs_seam_census module ---------
# Defined in this file (Verilog allows several modules per file) so no build-system
# file list has to change -- W1's rh_w1_census precedent.
BS_CENSUS_MODULE = r'''

// =====================================================================================
// RXFIX_BS -- the byte-seam census.  Eight 32-bit read words, one freeze level.
//
// TWO CLOCK ENABLES, ONE CLOCK.  enbSer is ByteSerializer's enb_1_2_0_gated
// (15.36 MHz) and enbFifo is ByteRxFifo's enb_gated (30.72 MHz); both are clock
// ENABLES on the same `clk`, so there is no CDC anywhere in this module.  The shadow
// words are latched on EVERY clk edge while freeze is low -- not on an enb tick, as
// rh_w1_census does -- so one frozen sweep is coherent across both enables to a
// single clk edge.  That is the whole point: the byte-plane and symbol-plane censuses
// must be comparable in one window.
//
// EVERY COUNTER WRAPS and is read as a delta.  Horizons at the f1536 rates
// (237,795 words/s, 1,245 frames/s): the 32-bit word-rate counters 5.0 h, the 32-bit
// bs_starts 39.9 d, the 16-bit frame-rate pair bs_lasts/bs_markpush 52.6 s.  That
// last pair is 5.3x the mandated 10 s read cadence and still unambiguous across ONE
// dropped read; the reader must flag any interval whose dt reaches 40 s.  bs_starts
// is a full 32-bit word rather than a packed field BECAUSE it is the denominator of
// every identity (W1_REGMAP sec 5.2's own correction: a frame-rate counter in a
// 15-bit field wraps in ~26 s and two dropped reads alias silently).
//
// bs_q24, bs_dropmax and the three order statistics SATURATE (they are not deltas).
// bs_trunc_min resets to 191 and bs_trunc_max to 0 so the first event sets both.
//
// FAIL-CLOSED CONTRACT the reader checks: BS_CNT[7:0] is hard zero here, and the
// three order-statistic bytes of BS_EVT are bounded by 191 by construction.
// =====================================================================================
module bs_seam_census
  (input  wire        clk,
   input  wire        reset,
   input  wire        enbSer,     // ByteSerializer enb_1_2_0_gated
   input  wire        enbFifo,    // ByteRxFifo enb_gated
   input  wire        freeze,     // fixctl[4], W1's shadow level
   input  wire        wv,         // serializer: a word completed this step
   input  wire        wl,         // ... and it carries wordLast
   input  wire        sstart,     // RxAlign startOut, via Receiver_recStart
   input  wire [15:0] wcnt,       // serializer state_wordCnt at this beat
   input  wire        push,       // FIFO: tog edge taken
   input  wire        pop,        // FIFO: valid_i && ready_1
   input  wire        drop,       // FIFO: drop-oldest on full (implies push)
   input  wire        mark,       // wFirst riding this push
   output wire [255:0] bus);

  reg [31:0] cWords;
  reg [31:0] cStarts;
  reg [31:0] cPush;
  reg [31:0] cPop;
  reg [31:0] cDrop;
  reg [15:0] cLasts;
  reg [15:0] cMarkP;
  reg [15:0] cTrunc;
  reg [7:0]  tLast;
  reg [7:0]  tMin;
  reg [7:0]  tMax;
  reg [7:0]  q24;
  reg [7:0]  dropMax;
  reg [7:0]  dropRun;
  reg [31:0] s0, s1, s2, s3, s4, s5, s6, s7;

  // A start arriving with 1..190 words already accumulated is a TRUNCATED frame: the
  // serializer discards the partial word and restarts word counting, so those words
  // never reach a wordLast.  wcnt == 0 is a clean boundary (state_wordCnt is cleared
  // when it reaches 191), wcnt == 191 cannot occur for the same reason.
  wire       trunc_ev = sstart && (wcnt >= 16'd1) && (wcnt <= 16'd190);
  wire [7:0] wc8      = wcnt[7:0];
  wire [7:0] dfc      = 8'd191 - wc8;   // words the truncated frame is short
  // 191 - wcnt is in 1..190, so these are every multiple of 24 it can be.
  wire       q24_ev   = trunc_ev && ((dfc == 8'd24)  || (dfc == 8'd48)  ||
                                     (dfc == 8'd72)  || (dfc == 8'd96)  ||
                                     (dfc == 8'd120) || (dfc == 8'd144) ||
                                     (dfc == 8'd168));
  wire [7:0] runNext  = drop ? ((dropRun == 8'd255) ? 8'd255 : dropRun + 8'd1) : 8'd0;

  wire [31:0] w0 = cWords;
  wire [31:0] w1 = cStarts;
  wire [31:0] w2 = cPush;
  wire [31:0] w3 = cPop;
  wire [31:0] w4 = cDrop;
  wire [31:0] w5 = {cLasts, cMarkP};
  wire [31:0] w6 = {tLast, tMin, tMax, dropMax};
  wire [31:0] w7 = {cTrunc, q24, 8'b0};

  always @(posedge clk or posedge reset) begin
    if (reset == 1'b1) begin
      cWords <= 32'd0; cStarts <= 32'd0; cPush <= 32'd0; cPop <= 32'd0; cDrop <= 32'd0;
      cLasts <= 16'd0; cMarkP <= 16'd0; cTrunc <= 16'd0;
      tLast <= 8'd0; tMin <= 8'd191; tMax <= 8'd0; q24 <= 8'd0;
      dropMax <= 8'd0; dropRun <= 8'd0;
      s0 <= 32'd0; s1 <= 32'd0; s2 <= 32'd0; s3 <= 32'd0;
      s4 <= 32'd0; s5 <= 32'd0; s6 <= 32'd0; s7 <= 32'd0;
    end
    else begin
      if (enbSer) begin
        if (wv) cWords <= cWords + 32'd1;
        if (wv && wl) cLasts <= cLasts + 16'd1;
        if (sstart) cStarts <= cStarts + 32'd1;
        if (trunc_ev) begin
          cTrunc <= cTrunc + 16'd1;
          tLast <= wc8;
          if (wc8 < tMin) tMin <= wc8;
          if (wc8 > tMax) tMax <= wc8;
        end
        if (q24_ev && (q24 != 8'd255)) q24 <= q24 + 8'd1;
      end
      if (enbFifo) begin
        if (push) begin
          cPush <= cPush + 32'd1;
          if (mark) cMarkP <= cMarkP + 16'd1;
          dropRun <= runNext;
          if (runNext > dropMax) dropMax <= runNext;
        end
        if (pop) cPop <= cPop + 32'd1;
        if (drop) cDrop <= cDrop + 32'd1;
      end
      if ( ~freeze) begin
        s0 <= w0; s1 <= w1; s2 <= w2; s3 <= w3;
        s4 <= w4; s5 <= w5; s6 <= w6; s7 <= w7;
      end
    end
  end

  // Leftmost element is the MOST significant, so it is bus word 7 and the rightmost is
  // bus word 0.  The decoder latches bs_reg[i] <= read_bs_bus[32*i +: 32] and answers
  // AXI word 0x8F+i from bs_reg[i], i.e.
  //   word 0 = bsBus[31:0]    = byte 0x23C = BS_WORDS
  //   word 1 = bsBus[63:32]   = byte 0x240 = BS_STARTS
  //   word 2 = bsBus[95:64]   = byte 0x244 = BS_PUSH
  //   word 3 = bsBus[127:96]  = byte 0x248 = BS_POP
  //   word 4 = bsBus[159:128] = byte 0x24C = BS_DROP
  //   word 5 = bsBus[191:160] = byte 0x250 = BS_MARKS = {bs_lasts, bs_markpush}
  //   word 6 = bsBus[223:192] = byte 0x254 = BS_EVT   = {tLast, tMin, tMax, dropMax}
  //   word 7 = bsBus[255:224] = byte 0x258 = BS_CNT   = {bs_trunc, bs_q24, 8'b0}
  assign bus = {s7, s6, s5, s4, s3, s2, s1, s0};

endmodule  // bs_seam_census
'''


def patch_txrxcomposite_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    has_fixctl = "  input   [31:0] fixctl;  // uint32" in s
    src = ("  assign bs_freeze = fixctl[4];  // RXFIX_BS freeze (write-only reg 0x208 bit 4)\n"
           if has_fixctl else
           "  // RXFIX_BS: this netlist copy has no fixctl port (the s1_rtl Verilator lineage\n"
           "  // predates it), so the freeze is tied off and the shadows track the live\n"
           "  // counters every clk.  Reported by the injector as BS_FREEZE=tied0.\n"
           "  assign bs_freeze = 1'b0;\n")
    s = _bs_add_port(s, 'TxRxComposite', 'bsBus', 'BS TxRxComposite bsBus port')
    s = _bs_decl(s,
                 "  // RXFIX_BS: the eight byte-seam census words as one 256-bit bus (a bus,\n"
                 "  // not eight ports, so each wrapper above takes one port edit).\n"
                 "  output  [255:0] bsBus;\n"
                 "  wire bs_freeze;\n"
                 "  wire bs_wv;\n"
                 "  wire bs_wl;\n"
                 "  wire bs_sstart;\n"
                 "  wire [15:0] bs_wcnt;\n"
                 "  wire bs_enb_ser;\n"
                 "  wire bs_push;\n"
                 "  wire bs_pop;\n"
                 "  wire bs_drop;\n"
                 "  wire bs_enb_fifo;\n" + src, 'BS TxRxComposite declarations')
    s = _bs_add_pin(s, 'ByteSerializer', 'u_ByteSerializer',
                    '.bsWv(bs_wv),\n' + ' ' * 24 + '.bsWl(bs_wl),\n'
                    + ' ' * 24 + '.bsStart(bs_sstart),\n'
                    + ' ' * 24 + '.bsWordCnt(bs_wcnt),\n'
                    + ' ' * 24 + '.bsEnb(bs_enb_ser)',
                    'BS TxRxComposite ByteSerializer instantiation')
    s = _bs_add_pin(s, 'ByteRxFifo', 'u_ByteRxFifo',
                    '.bsPush(bs_push),\n' + ' ' * 24 + '.bsPop(bs_pop),\n'
                    + ' ' * 24 + '.bsDrop(bs_drop),\n'
                    + ' ' * 24 + '.bsEnbG(bs_enb_fifo)',
                    'BS TxRxComposite ByteRxFifo instantiation')
    s = _sub(s, "  assign byte_rx_data = outWord_1;\n",
             "  // RXFIX_BS: the byte-seam census.  sstart is taken from INSIDE the\n"
             "  // serializer (its own `start` port), which is Receiver_recStart, which is\n"
             "  // RxAlign.startOut (RxAlign -> FEC_Decoder_Wrapper.startOut ->\n"
             "  // QPSK_Rx.ctrlOut_startOut -> Receiver.recStart, Receiver.v:460) -- so\n"
             "  // bs_starts and the truncation predicate are read off ONE signal, the same\n"
             "  // one the discarded partial word is decided by.  mark is SerFirstRT_out1,\n"
             "  // the wFirst this push carries.\n"
             "  bs_seam_census u_bs_seam_census (.clk(clk),\n"
             "                                   .reset(reset),\n"
             "                                   .enbSer(bs_enb_ser),\n"
             "                                   .enbFifo(bs_enb_fifo),\n"
             "                                   .freeze(bs_freeze),\n"
             "                                   .wv(bs_wv),\n"
             "                                   .wl(bs_wl),\n"
             "                                   .sstart(bs_sstart),\n"
             "                                   .wcnt(bs_wcnt),\n"
             "                                   .push(bs_push),\n"
             "                                   .pop(bs_pop),\n"
             "                                   .drop(bs_drop),\n"
             "                                   .mark(SerFirstRT_out1),\n"
             "                                   .bus(bsBus)\n"
             "                                   );  // RXFIX_BS\n\n"
             "  assign byte_rx_data = outWord_1;\n", 'BS TxRxComposite census instantiation')
    s = s.rstrip('\n') + '\n' + BS_CENSUS_MODULE
    open(path, 'w').write(s)
    return 'patched'


# ---- 4. TxRxCompo_ip_dut.v: out of the DUT wrapper ----------------------------
def patch_ip_dut_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    s = _bs_add_port(s, 'TxRxCompo_ip_dut', 'bs_bus', 'BS dut bs_bus port')
    s = _bs_decl(s, "  // RXFIX_BS: byte-seam census bus out of the DUT wrapper.\n"
                    "  output  [255:0] bs_bus;  // ufix256\n"
                    "  wire [255:0] bs_bus_sig;  // ufix256\n", 'BS dut declarations',
                 anchor="  input   [31:0] fixctl;  // ufix32\n")
    s = _bs_add_pin(s, 'TxRxComposite', 'u_TxRxCompo_ip_src_TxRxComposite',
                    '.bsBus(bs_bus_sig)', 'BS dut TxRxComposite instantiation')
    s = _sub(s, "endmodule  // TxRxCompo_ip_dut\n",
             "  assign bs_bus = bs_bus_sig;  // RXFIX_BS\n\n"
             "endmodule  // TxRxCompo_ip_dut\n", 'BS dut bus assign')
    open(path, 'w').write(s)
    return 'patched'


# ---- 5. TxRxCompo_ip_axi_lite.v: into the AXI-lite wrapper ---------------------
def patch_ip_axi_lite_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    s = _bs_add_port(s, 'TxRxCompo_ip_axi_lite', 'read_bs_bus', 'BS axi_lite port')
    s = _bs_decl(s, "  // RXFIX_BS: byte-seam census bus into the read decoder.\n"
                    "  input   [255:0] read_bs_bus;  // ufix256\n", 'BS axi_lite declarations',
                 anchor="  input   [31:0] read_beatfix_viol_latch;  // ufix32\n")
    s = _bs_add_pin(s, 'TxRxCompo_ip_addr_decoder', 'u_TxRxCompo_ip_addr_decoder_inst',
                    '.read_bs_bus(read_bs_bus)', 'BS axi_lite addr_decoder instantiation')
    open(path, 'w').write(s)
    return 'patched'


# ---- 6. TxRxCompo_ip_addr_decoder.v: EIGHT free read words at 0x23C..0x258 -----
# The single `assign data_read` statement is located by regex and asserted unique, so
# BS composes with W1 / R4B / R4D / R4E in that order whatever they left behind.  W1's
# own eight words, R4B's 0x234 and R4D/R4E's 0x238 are untouched.
_BS_DATA_READ_RE = re.compile(r'^  assign data_read = .*?;.*?\n', re.M | re.S)


def patch_ip_addr_decoder_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    hits = _BS_DATA_READ_RE.findall(s)
    assert len(hits) == 1, (
        f'anchor for BS addr_decoder read override occurs {len(hits)} times '
        '(want exactly 1): the single `assign data_read` statement')
    old = hits[0]
    s = _bs_add_port(s, 'TxRxCompo_ip_addr_decoder', 'read_bs_bus',
                     'BS addr_decoder port')
    s = _sub(s, "  input   clk;\n",
             "  input   clk;\n"
             "  // RXFIX_BS: EIGHT byte-seam census words at FREE read addresses.\n"
             "  // address_select_level1 = addr_read[7:0] is a WORD index; the host byte\n"
             "  // address is 4*word.  Occupied today: every literal decode <= 0x84 (byte\n"
             "  // 0x210), W1's 0x85..0x8C (0x214..0x230) and R4B/R4D/R4E's 0x8D/0x8E\n"
             "  // (0x234/0x238).  BS takes 0x8F..0x96 = bytes 0x23C..0x258, which fall\n"
             "  // through to `default: const_0` without this block.\n"
             "  // Bus word i answers word address 0x8F+i (bs_idx below) -- W1's own\n"
             "  // w1_idx = address - base convention.  Task 33's bug class is an INDEX\n"
             "  // rule, so the map is pinned from this generated text by\n"
             "  // test_170_bs_words_land_at_the_canonical_addresses, never from intent.\n"
             "  // NOT touched: 0x83/0x84 (DBGCAP/TXCAP) and the write-only registers\n"
             "  // 0x4/0x10C/0x110/0x114/0x118/0x138/0x158/0x170/0x174/0x178/0x17C/0x180/\n"
             "  // 0x184/0x1DC/0x208 -- this is a READ decode only.\n"
             "  input   [255:0] read_bs_bus;  // ufix256\n"
             "  reg [31:0] bs_reg [0:7];\n"
             "  integer bs_i;\n"
             "  wire bs_hit;\n"
             "  wire [2:0] bs_idx;\n"
             "  wire [31:0] bs_under;\n", 'BS addr_decoder declarations')
    s = _sub(s, old,
             "  // RXFIX_BS -----------------------------------------------------------------\n"
             "  always @(posedge clk or posedge reset)\n"
             "    begin : bs_reg_process\n"
             "      if (reset == 1'b1) begin\n"
             "        for (bs_i = 0; bs_i < 8; bs_i = bs_i + 1) begin\n"
             "          bs_reg[bs_i] <= 32'b0;\n"
             "        end\n"
             "      end\n"
             "      else begin\n"
             "        if (enb) begin\n"
             "          for (bs_i = 0; bs_i < 8; bs_i = bs_i + 1) begin\n"
             "            bs_reg[bs_i] <= read_bs_bus[32*bs_i +: 32];\n"
             "          end\n"
             "        end\n"
             "      end\n"
             "    end\n\n"
             "  assign bs_hit = (address_select_level1 >= 8'h8F) &&\n"
             "              (address_select_level1 <= 8'h96);\n\n"
             "  assign bs_idx = address_select_level1[2:0] - 3'd7;\n\n"
             + old.replace('  assign data_read = ', '  assign bs_under = ')
             + "\n  assign data_read = (bs_hit ? bs_reg[bs_idx] : bs_under);  // RXFIX_BS\n",
             'BS addr_decoder read override')
    open(path, 'w').write(s)
    return 'patched'


# ---- 7. TxRxCompo_ip.v: wire the DUT's bus to the AXI-lite read decoder --------
def patch_ip_top_bs(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_BS):
        return 'already'
    s = _sub(s, "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n",
             "  wire [31:0] beatfix_viol_count_sig;  // ufix32\n"
             "  // RXFIX_BS: DUT byte-seam census bus -> AXI-lite read decoder.  Internal\n"
             "  // only: no TxRxCompo_ip port is added, so component.xml is unchanged.\n"
             "  wire [255:0] bs_bus_sig;  // ufix256\n", 'BS ip top declarations')
    s = _bs_add_pin(s, 'TxRxCompo_ip_axi_lite', 'u_TxRxCompo_ip_axi_lite_inst',
                    '.read_bs_bus(bs_bus_sig)', 'BS ip top axi_lite instantiation')
    s = _bs_add_pin(s, 'TxRxCompo_ip_dut', 'u_TxRxCompo_ip_dut_inst',
                    '.bs_bus(bs_bus_sig)', 'BS ip top dut instantiation')
    open(path, 'w').write(s)
    return 'patched'


BS_PATCHERS = {
    'ByteSerializer.v': patch_byte_serializer_bs,
    'ByteRxFifo.v': patch_byte_rx_fifo_bs,
    'TxRxComposite.v': patch_txrxcomposite_bs,
    'TxRxCompo_ip_dut.v': patch_ip_dut_bs,
    'TxRxCompo_ip_axi_lite.v': patch_ip_axi_lite_bs,
    'TxRxCompo_ip_addr_decoder.v': patch_ip_addr_decoder_bs,
    'TxRxCompo_ip.v': patch_ip_top_bs,
}


def bs_files(sim_tree):
    """BS's file set: the Verilator tree has no TxRxCompo_ip_* wrapper files."""
    return list(BS_CORE_FILES) if sim_tree else list(BS_CORE_FILES) + list(BS_IP_FILES)


def bs_word_map():
    """The canonical byte-address -> field-name table, from ONE table (BS_WORD0)."""
    names = ['BS_WORDS', 'BS_STARTS', 'BS_PUSH', 'BS_POP', 'BS_DROP',
             'BS_MARKS', 'BS_EVT', 'BS_CNT']
    return {4 * (BS_WORD0 + i): names[i] for i in range(BS_NWORDS)}



# ---------------------------------------------------------------- dispatch tables
# variant -> {file: patcher}.  R1 and R2 are INDEPENDENT, not cumulative: R1
# (valid-indexed FIFO pop) was gated and measured to change nothing (ledger
# 2026-09-04, f_m10 == q_m10 frame for frame), so R2 does not carry it.
# ======================================================================== RXFIX_PAD
# F4 (2026-09-08, ledger FWD_CRC_REGRESSION_0907 §47.5-§47.6): pad a TRUNCATED frame to 191
# words in the ByteSerializer so one short frame cannot misalign the axi_dmac transfer
# boundary (SYNC_TRANSFER_START wait -> FIFO deadlock -> drop-oldest -> 3 lost frames).
# Stacks on BS (needs the BS-tapped ByteSerializer; the census keeps counting the
# upstream truncation).  Banked twin: jupiter_240k5_byte/rtl_sim/pad_patch.py -- the two
# must produce byte-identical output (test_rxfix_inject.TestPAD checks this).
MARKER_PAD = 'RXFIX_PAD'

def patch_byte_serializer_pad(path, sim_tree=False):
    s = open(path).read()
    if _has(s, MARKER_PAD):
        return 'already'
    assert _has(s, MARKER_BS), 'RXFIX_PAD expects the RXFIX_BS-tapped ByteSerializer (apply BS first)'
    def sub(old, new):
        nonlocal s
        s = _sub(s, old, new, 'PAD ByteSerializer')
    sub("  reg  firstNext_next;\n",
"""  reg  firstNext_next;
  // RXFIX_PAD -- frame-length padding for TRUNCATED frames (2026-09-08, ledger
  // FWD_CRC_REGRESSION_0907 §47.5).  A `start` arriving with state_wordCnt in 1..190
  // used to abandon the partial frame at (wordCnt) words.  Downstream the stream is
  // consumed in fixed 191-word frames by axi_dmac transfers with SYNC_TRANSFER_START,
  // and one short frame misaligns every later transfer boundary: the DMAC then holds
  // ready low waiting for a tuser beat the FIFO head cannot present, the FIFO fills
  // and drop-oldest walks the head to the next mark (191 - wordCnt words lost) -- 3
  // host frames per event, reproduced word-for-word in rtl_sim/run_dmac_sim_rtl.sh.
  // Here the truncated frame is instead PADDED to exactly 191 words with filler words
  // (all-zero: no magic, CRC fails at the host -> exactly one frame lost) before the
  // new frame's words are released; wordLast rides the last filler so wordFirst lands
  // on the new frame's word 0 exactly as for a clean boundary.  Real words that
  // complete while fillers are being emitted are queued (<= 3 can arrive: one per 64
  // bits against <= 190 filler beats) and released in order afterwards.
  reg [7:0]  pad;                 // filler words still to emit (0 = idle)
  reg [63:0] pq0, pq1, pq2;       // queued real words, oldest first
  reg        pl0, pl1, pl2;       // ... their wordLast flags
  reg [1:0]  pqn;                 // queue occupancy 0..3
  reg [7:0]  pad_1, pad_next;
  reg [63:0] pq0_1, pq1_1, pq2_1, pq0_next, pq1_next, pq2_next;
  reg        pl0_1, pl1_1, pl2_1, pl0_next, pl1_next, pl2_next;
  reg [1:0]  pqn_1, pqn_next;
  reg [63:0] w_r;                 // the real word completed this step (if wv_r)
  reg        wv_r, wl_r;
""")
    sub("""        heldFirst <= 1'b1;
        firstNext <= 1'b1;
      end
      else begin
        if (enb_1_2_0_gated) begin
          state_acc <= state_acc_next;""",
"""        heldFirst <= 1'b1;
        firstNext <= 1'b1;
        pad <= 8'd0; pq0 <= 64'd0; pq1 <= 64'd0; pq2 <= 64'd0;   // RXFIX_PAD
        pl0 <= 1'b0; pl1 <= 1'b0; pl2 <= 1'b0; pqn <= 2'd0;      // RXFIX_PAD
      end
      else begin
        if (enb_1_2_0_gated) begin
          pad <= pad_next; pq0 <= pq0_next; pq1 <= pq1_next; pq2 <= pq2_next;   // RXFIX_PAD
          pl0 <= pl0_next; pl1 <= pl1_next; pl2 <= pl2_next; pqn <= pqn_next;   // RXFIX_PAD
          state_acc <= state_acc_next;""")
    sub("  always @(bitIn, bitValid, firstNext, heldFirst, heldLast, heldWord, start, state_acc,\n       state_bitIdx, state_wordCnt, tog) begin\n",
        "  always @(bitIn, bitValid, firstNext, heldFirst, heldLast, heldWord, start, state_acc,\n       state_bitIdx, state_wordCnt, tog,\n       pad, pq0, pq1, pq2, pl0, pl1, pl2, pqn) begin   // RXFIX_PAD\n")
    sub("""    if (start) begin
      // packet boundary: discard any partial word, restart word counting
      state_acc_1 = 64'd0;
      a1 = 8'd0;
      state_wordCnt_1 = 16'd0;
    end
""", """    pad_1 = pad; pq0_1 = pq0; pq1_1 = pq1; pq2_1 = pq2;                // RXFIX_PAD
    pl0_1 = pl0; pl1_1 = pl1; pl2_1 = pl2; pqn_1 = pqn;                // RXFIX_PAD
    if (start) begin
      // RXFIX_PAD: a start with 1..190 words accumulated is a TRUNCATED frame --
      // schedule 191 - wordCnt filler words so the stream stays 191-word aligned.
      if ((pad_1 == 8'd0) && (state_wordCnt_1 >= 16'd1) && (state_wordCnt_1 <= 16'd190)) begin
        pad_1 = 8'd191 - state_wordCnt_1[7:0];
      end
      // packet boundary: discard any partial word, restart word counting
      state_acc_1 = 64'd0;
      a1 = 8'd0;
      state_wordCnt_1 = 16'd0;
    end
""")
    sub("""    state_acc_next = state_acc_1;
    state_bitIdx_next = a1;
    state_wordCnt_next = state_wordCnt_1;
    if (wv) begin
""", """    // RXFIX_PAD: what the core completed this step is the REAL word; the emitted
    // word (w/wv/wl below) is chosen by the pad/queue arbiter so that fillers and
    // earlier-queued words always precede it.
    w_r = w; wv_r = wv; wl_r = wl;
    w = 64'd0; wv = 1'b0; wl = 1'b0;
    if (pad_1 != 8'd0) begin
      // emit one filler; a real word completing now is queued
      w = 64'd0; wv = 1'b1; wl = (pad_1 == 8'd1);
      pad_1 = pad_1 - 8'd1;
      if (wv_r) begin
        case (pqn_1)
          2'd0: begin pq0_1 = w_r; pl0_1 = wl_r; pqn_1 = 2'd1; end
          2'd1: begin pq1_1 = w_r; pl1_1 = wl_r; pqn_1 = 2'd2; end
          2'd2: begin pq2_1 = w_r; pl2_1 = wl_r; pqn_1 = 2'd3; end
          default: ;   // queue full: cannot happen (<= 3 words per 190 beats)
        endcase
      end
    end
    else if (pqn_1 != 2'd0) begin
      // drain the queue in order; a real word completing now joins the tail
      w = pq0_1; wl = pl0_1; wv = 1'b1;
      pq0_1 = pq1_1; pl0_1 = pl1_1; pq1_1 = pq2_1; pl1_1 = pl2_1; pqn_1 = pqn_1 - 2'd1;
      if (wv_r) begin
        case (pqn_1)
          2'd0: begin pq0_1 = w_r; pl0_1 = wl_r; pqn_1 = 2'd1; end
          2'd1: begin pq1_1 = w_r; pl1_1 = wl_r; pqn_1 = 2'd2; end
          2'd2: begin pq2_1 = w_r; pl2_1 = wl_r; pqn_1 = 2'd3; end
          default: ;
        endcase
      end
    end
    else begin
      w = w_r; wv = wv_r; wl = wl_r;
    end
    pad_next = pad_1; pq0_next = pq0_1; pq1_next = pq1_1; pq2_next = pq2_1;
    pl0_next = pl0_1; pl1_next = pl1_1; pl2_next = pl2_1; pqn_next = pqn_1;
    state_acc_next = state_acc_1;
    state_bitIdx_next = a1;
    state_wordCnt_next = state_wordCnt_1;
    if (wv) begin
""")
    open(path, 'w').write(s)
    return 'patched'

PAD_PATCHERS = {'ByteSerializer.v': patch_byte_serializer_pad}
PAD_FILES = ['ByteSerializer.v']


PATCHERS = {
    'R1': {'Preamble_Detector.v': patch_preamble_detector},
    'R2': {'Preamble_Detector.v': patch_preamble_detector_r2},
    'R3': {'sample_discard_controller.v': patch_sample_discard_controller_r3,
           'Packet_Controller.v': patch_packet_controller_r3,
           'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r3,
           'Symbol_Synchronizer.v': patch_symbol_synchronizer_r3,
           'Rate_Handle.v': patch_rate_handle_r3,
           'FIFO_block.v': patch_fifo_block_r3,
           'Validate_Input_Push_Pop_block.v': patch_vipp_block_r3},
    'R3S': {'sample_discard_controller.v': patch_sample_discard_controller_r3s,
            'Packet_Controller.v': patch_packet_controller_r3s,
            'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r3s,
            'Symbol_Synchronizer.v': patch_symbol_synchronizer_r3s,
            'Rate_Handle.v': patch_rate_handle_r3s,
            'FIFO_block.v': patch_fifo_block_r3s,
            'Validate_Input_Push_Pop_block.v': patch_vipp_block_r3s},
    'R4': {'sample_discard_controller.v': patch_sample_discard_controller_r4,
           'Packet_Controller.v': patch_packet_controller_r4,
           'Frequency_and_Time_Synchronizer.v': patch_freq_time_sync_r4,
           'Symbol_Synchronizer.v': patch_symbol_synchronizer_r4,
           'Rate_Handle.v': patch_rate_handle_r4,
           'FIFO_block.v': patch_fifo_block_r4,
           'Validate_Input_Push_Pop_block.v': patch_vipp_block_r4},
    'R4B': dict(R4B_PATCHERS),
    'R4D': dict(R4D_PATCHERS),
    'R4E': dict(R4E_PATCHERS),
    'W1': dict(W1_PATCHERS),
    'BS': dict(BS_PATCHERS),
    'PAD': dict(PAD_PATCHERS),
}

VARIANT_FILES = {
    'R1': ['Preamble_Detector.v'],
    'R2': ['Preamble_Detector.v'],
    'R3': ['sample_discard_controller.v', 'Packet_Controller.v', 'Frequency_and_Time_Synchronizer.v', 'Symbol_Synchronizer.v', 'Rate_Handle.v', 'FIFO_block.v', 'Validate_Input_Push_Pop_block.v'],
    # R3S (Task 11) is R3's file set with the extra-pop branch deleted and an
    # arming predicate added; it is NOT cumulative with R3 (both redefine
    # Rate_Handle.Logical_Operator_out1) and the patchers refuse to stack.
    'R3S': ['sample_discard_controller.v', 'Packet_Controller.v', 'Frequency_and_Time_Synchronizer.v', 'Symbol_Synchronizer.v', 'Rate_Handle.v', 'FIFO_block.v', 'Validate_Input_Push_Pop_block.v'],
    # R4 (Task 12) is the shippable form of R3S: same seven files, same skip-only
    # steering, but the ring is PRE-FILLED to mid-occupancy at reset and the steering
    # is armed by that pre-fill plus lock instead of by the first post-lock hole.
    # Not cumulative with R3 or R3S (all three redefine the same pop expression);
    # IS combinable with W1, which is read-only and anchors elsewhere -- task 13
    # builds W1 + R4 together, and a test applies both in both orders.
    'R4': ['sample_discard_controller.v', 'Packet_Controller.v', 'Frequency_and_Time_Synchronizer.v', 'Symbol_Synchronizer.v', 'Rate_Handle.v', 'FIFO_block.v', 'Validate_Input_Push_Pop_block.v'],
    # R4B (Task 12b) is the SILICON-READY form of R4: the skip window is STRUCTURAL
    # (13 nominal pop slots opened by Packet_Controller.endOut, an EXISTING port), the
    # decision is REGISTERED, lock is 8 pcEnd pulses and the pre-fill is gone.  That
    # drops sample_discard_controller.v and Packet_Controller.v from the file set, so
    # the five core files are a SUBSET of W1's -- and the ninth witness word rides
    # W1's read path, so the seven carry-chain files are patched only where RXFIX_W1
    # already is (see r4b_files() / _r4b_pass_through).  Not cumulative with
    # R3/R3S/R4; IS combinable with W1, W1 FIRST.
    'R4B': R4B_CORE_FILES + R4B_WIT_RTL_FILES + R4B_WIT_IP_FILES,
    # R4D (Task 14) is R4B plus the FULL-side mirror: one EXTRA pop when occupancy
    # >= 24 inside the SAME 13-slot structural window, at most one per pcEnd,
    # registered like the skip.  Same twelve files, same conditional witness chain
    # (two read words at 0x234/0x238 instead of one).  Not cumulative with any other
    # steering variant; IS combinable with W1, W1 FIRST.
    'R4D': R4D_CORE_FILES + R4D_WIT_RTL_FILES + R4D_WIT_IP_FILES,
    # R4E (Task 21) is R4B plus the FULL side's TRUE mirror of the natural event: one
    # DROPPED PUSH per pcEnd when occupancy >= 24, SCHEDULED by the measured frame
    # period so the vanished symbol would have been popped inside the SAME 13-slot
    # structural window.  It CONTAINS R4B's skip side (a clone, not a stack), so it
    # is mutually exclusive with R3/R3S/R4/R4B/R4D.  Same twelve files, two read
    # words at 0x234/0x238.  IS combinable with W1, W1 FIRST.
    'R4E': R4E_CORE_FILES + R4E_WIT_RTL_FILES + R4E_WIT_IP_FILES,
    # W1 is an INSTRUMENT, not a fix, and it is not cumulative with R1/R2/R3.
    # On a --sim-tree only the eight RTL files exist (the Verilator lineage has no
    # Vivado IP wrapper), so the IP four are dropped there -- see w1_files().
    'W1': W1_RTL_FILES + W1_IP_FILES,
    # BS (Task 46) is an INSTRUMENT, read-only, and stacks on anything -- but it must
    # be applied AFTER W1/R4B/R4D/R4E because its addr_decoder hunk wraps the single
    # `assign data_read` those variants also rewrite.  On a --sim-tree only the three
    # core files exist (no Vivado IP wrapper), so the IP four are dropped -- bs_files().
    'BS': BS_CORE_FILES + BS_IP_FILES,
    # PAD (F4) touches ONE file and stacks on BS; identical on a --sim-tree and a kit.
    'PAD': list(PAD_FILES),
}

FILE_MARKER = {
    'R1': {'Preamble_Detector.v': MARKER},
    'R2': {'Preamble_Detector.v': MARKER_R2},
    'R3': {f: MARKER_R3 for f in VARIANT_FILES['R3']},
    'R3S': {f: MARKER_R3S for f in VARIANT_FILES['R3S']},
    'R4': {f: MARKER_R4 for f in VARIANT_FILES['R4']},
    'R4B': {f: MARKER_R4B for f in VARIANT_FILES['R4B']},
    'R4D': {f: MARKER_R4D for f in VARIANT_FILES['R4D']},
    'R4E': {f: MARKER_R4E for f in VARIANT_FILES['R4E']},
    'W1': {f: MARKER_W1 for f in VARIANT_FILES['W1']},
    'BS': {f: MARKER_BS for f in VARIANT_FILES['BS']},
    'PAD': {f: MARKER_PAD for f in VARIANT_FILES['PAD']},
}


def w1_files(sim_tree):
    """W1's file set: the Verilator tree has no TxRxCompo_ip_* wrapper files."""
    return list(W1_RTL_FILES) if sim_tree else list(W1_RTL_FILES) + list(W1_IP_FILES)


def zip_member_name(f):
    """Basename of `f` inside TxRxCompo_ip_v1_0.zip.

    Generated MODEL sources are prefixed TxRxCompo_ip_src_; the IP's own wrapper
    files (TxRxCompo_ip.v, _dut, _axi_lite, _addr_decoder) are not.
    """
    return f if f.startswith('TxRxCompo_ip') else SRC_PREFIX + f

SRC_PREFIX = 'TxRxCompo_ip_src_'


def logical_name(base):
    """Strip the Vivado IP kit's TxRxCompo_ip_src_ prefix, if present."""
    return base[len(SRC_PREFIX):] if base.startswith(SRC_PREFIX) else base


def _patcher_for(base, variant, want=None):
    """Return the patcher for this file basename under `variant`, else None.

    Dispatch is by exact (optionally TxRxCompo_ip_src_-prefixed) basename; the
    anchors then assert exactly-one occurrence and the patch fails loudly rather
    than silently editing the wrong module.  `want` narrows the set (W1 patches
    fewer files on a --sim-tree, which has no Vivado IP wrapper).
    """
    ln = logical_name(base)
    tbl = PATCHERS.get(variant, {})
    if want is None:
        want = VARIANT_FILES.get(variant, ())
    if ln in tbl and ln in want:
        return tbl[ln]
    return None


def patch_zip(zpath, variant, sim_tree=False, want=None):
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r'); entries = []; n = 0; done = {}
    for item in zin.infolist():
        data = zin.read(item.filename)
        base = os.path.basename(item.filename)
        fn = _patcher_for(base, variant, want)
        if fn is not None:
            tmp = zpath + '.rxfix_tmp'; os.makedirs(tmp, exist_ok=True)
            tp = os.path.join(tmp, base)
            open(tp, 'wb').write(data); status = fn(tp, sim_tree); data = open(tp, 'rb').read()
            os.remove(tp); os.rmdir(tmp); n += 1
            done[logical_name(base)] = status
            print(f"    zip member {base:50s} {status:8s}")
        entries.append((item, data))
    zin.close()
    out = io.BytesIO(); zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close(); open(zpath, 'wb').write(out.getvalue())
    # Task 12b: the per-member STATUS, not just a count.  A variant may deliberately
    # leave a file alone ('skipped' -- R4B's witness chain where W1 is absent), and
    # verify_zip must be told which files carry a marker rather than re-deciding it
    # from a second, skewable probe.
    return done


def verify_zip(zpath, variant, want=None):
    if want is None:
        want = VARIANT_FILES[variant]
    expected = {zip_member_name(f): FILE_MARKER[variant][f] for f in want}
    zin = zipfile.ZipFile(zpath, 'r'); found = {}
    for item in zin.infolist():
        b = os.path.basename(item.filename)
        if b in expected:
            found[b] = zin.read(item.filename).decode()
    zin.close()
    ok = True
    for b, marker in expected.items():
        if b not in found or not _has(found[b], marker):
            print(f"    VERIFY_FAIL {zpath}: {b} missing or lacks {marker}"); ok = False
    return ok


def main(d, variant, sim_tree=False):
    if variant not in VARIANT_FILES:
        print(f"RXFIX_INJECT_FAIL unknown variant {variant!r} (want R1|R2|R3|R3S|R4|R4B|R4D|R4E|W1|BS|PAD)")
        return 2
    want = (w1_files(sim_tree) if variant == 'W1' else
            bs_files(sim_tree) if variant == 'BS' else
            r4b_files(sim_tree) if variant == 'R4B' else
            r4d_files(sim_tree) if variant == 'R4D' else
            r4e_files(sim_tree) if variant == 'R4E' else VARIANT_FILES[variant])
    found = set(); nloose = 0; loose_status = {}
    percopy = {}
    for root, _, files in os.walk(d):
        if root.endswith('.rxfix_tmp'):
            continue
        for f in sorted(files):
            fn = _patcher_for(f, variant, want)
            if fn is None:
                continue
            p = os.path.join(root, f)
            status = fn(p, sim_tree)
            print(f"  {f:45s} {fn.__name__:28s} -> {status:8s} {p}")
            loose_status[logical_name(f)] = status
            ln = logical_name(f)
            found.add(ln); nloose += 1
            percopy[ln] = percopy.get(ln, 0) + 1
    nz = nv = 0
    if not sim_tree:
        for root, _, files in os.walk(d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    zp = os.path.join(root, f); nz += 1
                    print(f"  zip {zp}")
                    st = patch_zip(zp, variant, sim_tree, want)
                    vw = [x for x in want if st.get(x) != 'skipped']
                    if verify_zip(zp, variant, vw):
                        nv += 1; print(f"    VERIFY_OK {zp}")
    missing = sorted(set(want) - found)
    build_tree = any(os.path.basename(r) in ('ipcore', 'vivado_ip_prj')
                     or any(x.endswith('.xpr') for x in fs)
                     for r, _, fs in os.walk(d))
    skipped = sorted(k for k, v in loose_status.items() if v == 'skipped')
    # BS: report which freeze source the patched TxRxComposite got, so a leg log can
    # never silently assume fixctl[4] on a tree that has no fixctl port.
    bs_tied = False
    if variant == 'BS':
        for root, _, files in os.walk(d):
            for f in files:
                if logical_name(f) == 'TxRxComposite.v':
                    t = open(os.path.join(root, f)).read()
                    if "assign bs_freeze = 1'b0;" in t:
                        bs_tied = True
    print(f"RXFIX_INJECT variant={variant}{' sim-tree' if sim_tree else ''} "
          f"loose={nloose} missing={missing} zips={nz} zips_verified={nv}"
          + (f" skipped={skipped}" if skipped else "")
          + (f" {variant.lower()}_witness={'off' if skipped else 'on'}"
             if variant in ('R4B', 'R4D', 'R4E') else "")
          + (f" BS_FREEZE={'tied0' if bs_tied else 'fixctl4'}"
             if variant == 'BS' else ""))
    # A Vivado build kit holds the SAME set of loose copies in hdlsrc/, ipcore/ and
    # vivado_ip_prj/ipcore/, so EVERY file of the variant must appear the same number
    # of times.  The older `nloose % len(want) == 0` check could pass while one tree
    # was short two files and another long two -- a real hazard for W1, whose file set
    # mixes TxRxCompo_ip_src_* model sources with unprefixed TxRxCompo_ip_* wrappers.
    counts = sorted(set(percopy.values()))
    assert len(counts) <= 1, (
        f"RXFIX_INJECT_FAIL uneven loose copies for {variant}: "
        f"{ {k: v for k, v in sorted(percopy.items())} } -- a netlist copy is missing a file")
    if sim_tree:
        # a bare Verilator tree carries exactly one copy of each file and no zips
        if missing or nloose != len(want) or nz:
            print("RXFIX_INJECT_FAIL"); return 1
        return 0
    if missing or (build_tree and nz == 0) or (nz and nv != nz) or (nz not in (0, 2)):
        print("RXFIX_INJECT_FAIL"); return 1
    return 0


if __name__ == '__main__':
    st = '--sim-tree' in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != '--sim-tree']
    if len(args) != 2:
        print("usage: rxfix_inject.py <netlist_dir> R1|R2|R3|R3S|R4|R4B|R4D|R4E|W1|BS|PAD [--sim-tree]")
        sys.exit(2)
    sys.exit(main(args[0], args[1], st))
