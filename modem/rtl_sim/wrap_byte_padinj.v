// wrap_byte_bs.v -- [sim] Task 46 (RXFIX_BS, the byte-seam census) SRO harness wrapper.
//
// A SEVENTH separate file, not an edit of wrap_byte_sro.v (task 7), _sro3s.v (11),
// _sro4.v (12), _sro4b.v (12b), _sro4d.v (14) or _sro4e.v (21): every one of those,
// and every result banked from them, must not move under this task.  The module NAME
// is deliberately still `wrap_byte_sro` so that sim_sro.cpp -- task 7's driver, byte
// for byte -- links against it UNMODIFIED; that is what makes the identity legs a test
// of the RTL and not of a re-typed driver.
//
// SEVEN files now declare `module wrap_byte_sro`, so this one announces itself at time
// 0 with WRAPBS_FILE / WRAPBS_DEFINE, and build_sro_bs.sh greps the verilate log for
// the other six.
//
// WHAT THIS WRAPPER ADDS, and why each piece is outside the DUT:
//
//  (1) THE PIN CHECKER.  rx_seam_checker (the SAME rx_seam_checker.v that is in the
//      flashed images' cnt_mux32 slots 1..6) is instantiated on the DUT byte pins.  It
//      gives short_frm / orphan_w / frames a POSITIVE CONTROL for the first time
//      anywhere: BYTESEAM_INSTRUMENT.md sec 2.4 withdrew the drain-stall control as
//      structurally incapable of firing them (`acc = valid && ready` freezes every
//      checker counter while ready is low) and specified a BOUNDED stall scored on the
//      RELEASE side instead, which "has never been run".  Leg family `d*` runs it.
//
//  (2) THE BOUNDED STALL.  `+bsstall_at=P0 +bsstall_n=N` holds the ready the DUT sees
//      LOW from harness push index P0 until harness push index P0+N, then releases.
//      The push index is counted HERE from SerTogRT_out1 transitions -- a DUT net that
//      passes through no RXFIX_BS logic -- so the size of the injected deletion is
//      fixed by construction and is not read off the counter being tested.  Two legs
//      differing only in N have IDENTICAL history up to P0, hence identical FIFO
//      capacity at P0, hence a drop count differing by EXACTLY the difference in N.
//      That difference is the known-size injected deletion the gate scores.
//
//  (3) THE skip_count POKE.  `+bsskip=V [+bsskip_at=P0]` forces the DUT's skip_count
//      input to V from push index P0.  sec 2.4's truncation control, which on silicon
//      is a write to the write-only register 0x138 and has never been run there either.
//
//  (4) THE CENSUS DUMP.  One CSV line per BSDUMP clk cycles (and one at the end) to
//      the file named by +bsdump=<path>, carrying BOTH the RXFIX_BS shadow words read
//      out of the census's own bus AND an INDEPENDENT harness recount taken from the
//      pins and from SerTogRT_out1.  If the two disagree that is a finding, not a
//      silent pass -- the discipline wrap_byte_sro4d.v's skip trace established.
//
// With NO plusargs the wrapper drives the DUT exactly as wrap_byte_sro4d.v does
// (ready and skip_count pass straight through, the checker and the dump are snoops),
// which is what makes the identity legs meaningful.
//
// Original header of the file this was cut from (via the task 14 wrapper):
// wrap_byte_sro4d.v -- [sim] Task 14 (RXFIX_R4D) SRO harness wrapper (2026-09-04).
//
// A FIFTH SEPARATE FILE, not an edit of wrap_byte_sro.v (Task 7), wrap_byte_sro3s.v
// (Task 11) or wrap_byte_sro4.v (Task 12) or wrap_byte_sro4b.v (Task 12b): all four, and every result banked from
// them, must not move under Task 12b -- and Task 12's R4 legs are RUNNING against
// wrap_byte_sro4.v while this file is written.  The module NAME is deliberately still
// `wrap_byte_sro` so that sim_sro.cpp -- Task 7's driver, byte for byte -- links
// against it unmodified; that is what makes the n_p000 content-identity gate a test of
// the RTL and not a test of a re-typed driver.
//
// BECAUSE FIVE files now declare `module wrap_byte_sro`, this one announces itself at
// time 0.  A run that does not print WRAP4D_FILE / WRAP4D_DEFINE compiled the WRONG
// wrapper, and that failure would otherwise masquerade as "R4B never skipped".
// build_sro_rxfix4d.sh greps the verilate log for the other FOUR wrappers as well.
//
// R4B witnesses are carried on Task 7's three existing witness ports so that the driver
// needs no change:
//   r3Skips  = r4d_skips     (steered pop SKIPS; <p>_ep.txt kind 4 timestamps each one)
//   r3Extras = r4d_extras -- and here it IS a count, for the first time since task 7.
//              R4D deliberately reintroduces an extra pop, as the MIRROR of the skip and
//              inside the same structural window (see the injector header for why this is
//              not R3's extra pop).  So <p>_ep.txt kind 5 timestamps every EXTRA, exactly
//              as task 7 originally defined that kind.  Lock is read from the skipwin
//              trace's `locked` column instead of from a sentinel.
//   r3Guard  = Packet_Controller_endOut, the pulse that OPENS the structural window
//              (Task 11/12 carried ~sample_discard_controller.active here instead).
//
// THE SKIP-POSITION TRACE IS WRITTEN BY THIS WRAPPER, NOT BY THE DRIVER.  The gate has
// to prove every skip lands in slots [pcEnd+1, pcEnd+13], and sim_sro.cpp's <p>_ep.txt
// has no pcEnd record kind -- but sim_sro.cpp MUST NOT CHANGE (see above).  So the
// wrapper $fwrites one line per skip to the file named by +r4dwin=<path> (default
// r4d_skipwin.txt), carrying BOTH the RTL's own window slot (r4d_wslot + 1) and an
// INDEPENDENT recount made here from the taps rhValidIn / rhPhase / pcE, which do not
// pass through any R4B logic.  If the two disagree, the window logic and the
// measurement disagree, and that is a finding rather than a silent pass.
//
// It also keeps the read-only per-stage taps of the Task 11/12 wrappers (no effect on
// any port sim_sro.cpp drives) so a stagewin dump can be built against R4B if the
// falsifier fires; sim_stagewin.cpp is the only consumer.
//
// Original header of the file this was cut from (via the Task 11 and Task 12 wrappers):
// wrap_byte_sro.v -- [sim] COMB32 SRO reproduction wrapper (2026-09-03).
// wrap_byte_taps.v lineage, but the taps are the ones the SRO hypothesis needs:
//   * Symbol_Synchronizer interpolator: mu, Underflow
//   * Rate_Handle: strobe (FIFO push), pop, validIn, validOut
//   * FIFO_block: Push_Counter_out1 / Pop_Counter_out1 (the mod-32 pointers)
//   * Transmitter_dataOut{I,Q} so the harness can capture a legal TX stream
//     from the TX RTL itself (no Python modulator in the trust chain).
`timescale 1 ns / 1 ns
module wrap_byte_sro
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_out, rstcs_count, cfc_est,
   output wire railEnb,
   output wire signed [15:0] txI, output wire signed [15:0] txQ,
   // ---- symbol-timing / Rate_Handle taps ----
   output wire signed [10:0] icMu,       // Interpolation_Control mu   sfix11_En10
   output wire icUnd,                    // Interpolation_Control Underflow (= strobe src)
   output wire rhStrobe,                 // Rate_Handle .strobe  == FIFO push request
   output wire rhValidIn,                // Rate_Handle .validIn (input-sample beat)
   output wire rhPop,                    // Rate_Handle Logical_Operator_out1 == FIFO pop request
   output wire rhValidOut,               // Rate_Handle validOut (== FIFO validPop)
   output wire [4:0] fifoPush, output wire [4:0] fifoPop,   // the mod-32 pointers
   output wire fifoVPush, output wire fifoVPop,             // validated push/pop
   output wire pdSync, output wire demS, output wire demV, output wire fecS,
   // ---- valid chain, Symbol_Synchronizer.validOut -> Correlator.validOut ----
   // (the span TX_SEL8_DESK.md localises the one-sided symbol deletion to)
   output wire cfcV, output wire csV, output wire pdV, output wire paV, output wire conV,
   output wire corrV,                 // Preamble_Detector.Correlator_validOut
   output wire [13:0] tref,           // Peak_Search.timing_Reference_out1 (mod-12333)
   // ---- TRUE Rate_Handle ring taps (T0a, 2026-09-04): the guarded ring ----
   // Validate_Input_Push_Pop_block.v:49 (6-bit occupancy 0..32), :119, :129
   output wire [5:0] occTrue,          // u_Rate_Handle.u_FIFO.u_VIPP.Delay_out1
   output wire rhPopEmpty,             // .pop_on_empty_FIFO  (suppressed pop, no loss)
   output wire rhPushFull,             // .push_on_full_FIFO  (suppressed push = DELETION)
   // ---- Preamble_Detector realignment FIFO (12333 deep, 14-bit occupancy) ----
   // Validate_Input_Push_Pop.v:51,121,131 -- this tree has no enSlack, so
   // push_on_full_FIFO IS the raw event (pushOnFullRaw of the patched tree).
   output wire [13:0] pdOcc,
   output wire pdPopEmpty,
   output wire pdPof,
   // ---- T2 TRACE taps (2026-09-04, task 6): the tick-vs-valid divergence ----
   output wire pdPush,          // Preamble_Detector.Delay8_out1   (FIFO push = valid)
   output wire pdPopReq,        // Preamble_Detector.Delay10_out1  (FIFO pop request)
   output wire pdVPop,          // Preamble_Detector.FIFO_validPop
   output wire pdTAv,           // Preamble_Detector.Delay14_out1  (Timing_Adjust validIn)
   output wire [13:0] psToff,   // Peak_Search timingOffset (latched by TA on toffVal)
   output wire psNewpk,         // Peak_Search p1c_newpk
   output wire toffVal,         // done & success (timingOffsetValid)
   output wire [13:0] taRef,    // Timing_Adjust timing_Reference (VALID-counted, delayed chain)
   output wire [13:0] taAcc,    // Timing_Adjust accoff (latched timingOffset)
   output wire taArmed,         // Timing_Adjust State_Register
   output wire taSync,          // Timing_Adjust SyncPulse
   output wire sdcAct,          // sample_discard_controller.active
   output wire sdcStart,        // Packet_Controller Delay2_out1 (startIn)
   output wire sdcEnd,          // Packet_Controller End_Generator_endOut
   output wire [1:0] rhPhase,  // Rate_Handle mod-4 pop phase (HDL_Counter_out1)
   // ---- T7 (task 7): TGEN v2 non-repeating TX stimulus source ----
   // tgen_sel=0 leaves the DUT byte pins driven by the module ports, so every
   // rx-mode leg is bit-identical to the task-6 harness.
   input  wire        tgen_sel,
   input  wire [31:0] tgen_ctrl,
   input  wire [31:0] tgen_gap,
   output wire        tg_valid, tg_first, tg_ready,
   output wire [31:0] tg_seq,
   // ---- T7: RXFIX_R3 guard-band steering witnesses (zero on the baseline tree) ----
   output wire [31:0] r3Skips, r3Extras,
   output wire        r3Guard,
   // ---- T7 controller probe: the Rate_Handle ring RAM seam, per enb beat ----
   output wire signed [15:0] rhInI, rhInQ, rhOutI, rhOutQ,
   // ---- T11 (task 11): per-stage outputs for the falsifier dump ----
   // Frequency_and_Time_Synchronizer.v:82-105, Preamble_Detector.v:56-68.
   output wire signed [15:0] cfcI, cfcQ,      // Coarse_Frequency_Compensator_dataOut
   output wire signed [15:0] csI, csQ,        // Carrier_Synchronizer_dataOut
   output wire signed [15:0] pdI, pdQ,        // Preamble_Detector_dataOut
   output wire signed [15:0] pcI, pcQ,        // Packet_Controller_dataOut
   output wire pcV, pcS, pcE,                 // Packet_Controller valid/start/end
   output wire signed [31:0] corrD, corrT,    // Correlator dataOut / threshold
   output wire signed [31:0] psRmax,          // Peak_Search running max
   output wire [13:0] psTrefRaw,              // Peak_Search p1c_tref
   output wire signed [20:0] cfcEst);         // CFC normalizedFreqEst
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1,ncTI,ncTQ; wire ncV,ncTV;

  // ---- T7: RTL traffic generator (identical wiring to wrap_byte_seqbist.v) ----
  wire [63:0] tg_data_raw; wire tg_valid_raw, tg_first_raw;
  qpsk_traffic_gen_v2 u_tgen (
    .clk(clk), .resetn(!reset),
    .ctrl(tgen_ctrl), .gap(tgen_gap),
    .host_data(64'd0), .host_valid(1'b0), .host_first(1'b0), .host_ready(),
    .dut_data(tg_data_raw), .dut_valid(tg_valid_raw), .dut_first(tg_first_raw),
    .dut_ready(byte_ready));
  wire [63:0] dut_byte_data  = tgen_sel ? tg_data_raw  : byte_data;
  wire        dut_byte_valid = tgen_sel ? tg_valid_raw : byte_valid;
  wire        dut_byte_first = tgen_sel ? tg_first_raw : byte_first;
  assign tg_valid = tg_valid_raw & tgen_sel;
  assign tg_first = tg_first_raw;
  assign tg_ready = byte_ready;
  assign tg_seq   = u_tgen.seq;

  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count_eff),  // RXFIX_BS: +bsskip
    .byte_data(dut_byte_data), .byte_valid(dut_byte_valid),
    .tx_data_source(tx_data_source), .byte_first(dut_byte_first),
    .byte_rx_ready(byte_rx_ready_eff),  // RXFIX_BS: +bsstall
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(ncI1), .debugQ1(ncQ1),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(nc6), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  assign txI = dut.Transmitter_dataOutI;
  assign txQ = dut.Transmitter_dataOutQ;
  // Symbol_Synchronizer internals (Symbol_Synchronizer.v:74,87,446-456;
  // Rate_Handle.v:91,99-108; FIFO_block.v:113,148)
  assign icMu       = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.mu;
  assign icUnd      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.Underflow;
  assign rhStrobe   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.strobe;
  assign rhValidIn  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.validIn;
  assign rhPop      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.Logical_Operator_out1;
  assign rhValidOut = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.validOut;
  assign fifoPush   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Push_Counter_out1;
  assign fifoPop    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Pop_Counter_out1;
  assign fifoVPush  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Validate_Input_Push_Pop_valid_push;
  assign fifoVPop   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Validate_Input_Push_Pop_valid_pop;
  assign pdSync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_syncPulse;
  assign demS   = dut.u_Receiver.u_QPSK_Rx.QPSK_Demodulator_startOut;
  assign demV   = dut.u_Receiver.u_QPSK_Rx.QPSK_Demodulator_validOut;
  assign fecS   = dut.u_Receiver.u_QPSK_Rx.FEC_Decoder_Wrapper_startOut;
  assign cfcV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_validOut;
  assign csV   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_validOut;
  assign pdV   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_validOut;
  assign paV   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Phase_Ambiguity_Estimation_and_Correction_validOut;
  assign conV  = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationValid;
  assign corrV = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_validOut;
  assign tref  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_Peak_Search.timing_Reference_out1;
  assign occTrue    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1;
  assign rhPopEmpty = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.pop_on_empty_FIFO;
  assign rhPushFull = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO;
  assign pdOcc      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1;
  assign pdPopEmpty = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.pop_on_empty_FIFO;
  assign pdPof      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO;

  // ---- T2 TRACE taps ----
  assign pdPush   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay8_out1;
  assign pdPopReq = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay10_out1;
  assign pdVPop   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.FIFO_validPop;
  assign pdTAv    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay14_out1;
  assign psToff   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_timingOffset;
  assign psNewpk  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_newpk;
  assign toffVal  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Logical_Operator_out1;
  assign taRef    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_taref;
  assign taAcc    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_accoff;
  assign taArmed  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_armed;
  assign taSync   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.synchronizedPulse;
  assign sdcAct   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.u_sample_discard_controller.active;
  assign sdcStart = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.Delay2_out1;
  assign sdcEnd   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.End_Generator_endOut;
  // T7: the words actually entering and leaving the 32-entry ring
  assign rhInI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataIn_re;
  assign rhInQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataIn_im;
  assign rhOutI = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataOut_re;
  assign rhOutQ = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataOut_im;

  assign rhPhase  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.HDL_Counter_out1;

  // ---- T11: per-stage taps (read-only) ----
  assign cfcI = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_dataOut_re;
  assign cfcQ = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_dataOut_im;
  assign cfcEst = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_normalizedFreqEst;
  assign csI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_dataOut_re;
  assign csQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_dataOut_im;
  assign pdI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_dataOut_re;
  assign pdQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_dataOut_im;
  assign pcI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_dataOut_re;
  assign pcQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_dataOut_im;
  assign pcV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_validOut;
  assign pcS  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_startOut;
  assign pcE  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_endOut;
  assign corrD = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_dataOut;
  assign corrT = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_threshold;
  assign psRmax = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_runmax;
  assign psTrefRaw = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_tref;


  // ---- Task 46: R4D's three witness ports are unused here; tie them off ----------
  // This wrapper is for the BS instrument, not for a steering variant, so the T7
  // witness ports carry nothing.  A leg that reads r3Skips/r3Extras from a BS binary
  // is reading zeros BY CONSTRUCTION, and sim_sro.cpp's _res.txt line says so.
  assign r3Skips  = 32'd0;
  assign r3Extras = 32'd0;
  assign r3Guard  = 1'b0;

  // ================================================================================
  // Task 46 (1)-(3): the two DUT inputs this wrapper can intercept, and the pin
  // checker.  ALL of it is outside the DUT; with no plusargs it is a pure snoop.
  // ================================================================================
  reg [31:0] bs_stall_at, bs_stall_n, bs_skip_val, bs_skip_at, bs_dump_every;
  reg        bs_stall_on_arg, bs_skip_on_arg;
  reg [1023:0] bs_dump_fn;
  integer    bs_fh;

  // Harness push index: SerTogRT_out1 transitions.  SerTogRT_out1 is the serializer's
  // wordTog re-registered on enb_1_2_0 and is the FIFO's push request; it passes
  // through NO RXFIX_BS logic, which is what makes the injected deletion size
  // independent of the counter under test.
  reg        h_tog_prev;
  reg [31:0] h_push;              // words offered to the FIFO
  reg [31:0] h_acc;               // accepted beats at the DUT pins (valid && ready)
  reg [31:0] h_accmark;           // ... of which carried tuser
  reg [31:0] h_clk;
  wire       h_tog = dut.SerTogRT_out1;

  wire bs_stall_win = bs_stall_on_arg && (h_push >= bs_stall_at)
                      && (h_push < (bs_stall_at + bs_stall_n));
  wire bs_skip_win  = bs_skip_on_arg && (h_push >= bs_skip_at);

  wire        byte_rx_ready_eff = byte_rx_ready & ~bs_stall_win;
  wire [31:0] skip_count_eff    = bs_skip_win ? bs_skip_val : skip_count;

  // The pin checker: the SAME rx_seam_checker that is in silicon, on the DUT pins,
  // with the ready the DUT actually sees.
  wire [31:0] ck_frames, ck_ok, ck_fail, ck_magic, ck_short, ck_orphan;
  rx_seam_checker u_bs_pin_checker (
    .clk(clk), .resetn(!reset),
    .data(byte_rx_data), .valid(byte_rx_valid), .user(byte_rx_user),
    .ready(byte_rx_ready_eff),
    .frames(ck_frames), .crc_ok(ck_ok), .crc_fail(ck_fail),
    .magic_bad(ck_magic), .short_frm(ck_short), .orphan_w(ck_orphan));

  // ---- (4) the census dump ------------------------------------------------------
`ifdef RXFIX_BS
  wire [255:0] bs_bus_w = dut.u_bs_seam_census.bus;
  wire [31:0] bs_words = bs_bus_w[ 32*0 +: 32];
  wire [31:0] bs_starts= bs_bus_w[ 32*1 +: 32];
  wire [31:0] bs_push  = bs_bus_w[ 32*2 +: 32];
  wire [31:0] bs_pop   = bs_bus_w[ 32*3 +: 32];
  wire [31:0] bs_drop  = bs_bus_w[ 32*4 +: 32];
  wire [31:0] bs_marks = bs_bus_w[ 32*5 +: 32];
  wire [31:0] bs_evt   = bs_bus_w[ 32*6 +: 32];
  wire [31:0] bs_cnt   = bs_bus_w[ 32*7 +: 32];
`else
  wire [31:0] bs_words = 32'd0, bs_starts = 32'd0, bs_push = 32'd0, bs_pop = 32'd0;
  wire [31:0] bs_drop  = 32'd0, bs_marks  = 32'd0, bs_evt  = 32'd0, bs_cnt = 32'd0;
`endif

  initial begin
    if (!$value$plusargs("bsdump=%s", bs_dump_fn)) bs_dump_fn = "bs_census.txt";
    if (!$value$plusargs("bsstall_at=%d", bs_stall_at)) bs_stall_at = 32'd0;
    if (!$value$plusargs("bsstall_n=%d",  bs_stall_n))  bs_stall_n  = 32'd0;
    if (!$value$plusargs("bsskip=%d",     bs_skip_val)) bs_skip_val = 32'd0;
    if (!$value$plusargs("bsskip_at=%d",  bs_skip_at))  bs_skip_at  = 32'd0;
    if (!$value$plusargs("bsdump_every=%d", bs_dump_every)) bs_dump_every = 32'd1000000;
    bs_stall_on_arg = (bs_stall_n != 32'd0);
    bs_skip_on_arg  = $test$plusargs("bsskip");
    bs_fh = $fopen(bs_dump_fn, "w");
    $fwrite(bs_fh, "# clk,h_push,h_acc,h_accmark,ck_frames,ck_ok,ck_fail,ck_magic,");
    $fwrite(bs_fh, "ck_short,ck_orphan,bs_words,bs_starts,bs_push,bs_pop,bs_drop,");
    $fwrite(bs_fh, "bs_lasts,bs_markpush,bs_trunc_last,bs_trunc_min,bs_trunc_max,");
    $fwrite(bs_fh, "bs_dropmax,bs_trunc,bs_q24,bs_rsv,stall\n");
  end

  task bs_emit;
    begin
      $fwrite(bs_fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
              h_clk, h_push, h_acc, h_accmark,
              ck_frames, ck_ok, ck_fail, ck_magic, ck_short, ck_orphan,
              bs_words, bs_starts, bs_push, bs_pop, bs_drop,
              bs_marks[31:16], bs_marks[15:0],
              bs_evt[31:24], bs_evt[23:16], bs_evt[15:8], bs_evt[7:0],
              bs_cnt[31:16], bs_cnt[15:8], bs_cnt[7:0], bs_stall_win);
      $fflush(bs_fh);   // ~40 records per leg: the cost is nil and a killed leg still
                        // leaves a readable file, which a 70-minute leg needs.
    end
  endtask

  localparam [31:0] BS_PUSH_GRID = 32'd4096;
  reg [31:0] bs_tick;
  reg        bs_stall_win_d;

  always @(posedge clk) begin
    if (reset) begin
      h_tog_prev <= 1'b0; h_push <= 32'd0; h_acc <= 32'd0; h_accmark <= 32'd0;
      h_clk <= 32'd0; bs_tick <= 32'd0; bs_stall_win_d <= 1'b0;
    end
    else begin
      h_clk <= h_clk + 32'd1;
      h_tog_prev <= h_tog;
      if (h_tog != h_tog_prev) h_push <= h_push + 32'd1;
      if (byte_rx_valid && byte_rx_ready_eff) begin
        h_acc <= h_acc + 32'd1;
        if (byte_rx_user) h_accmark <= h_accmark + 32'd1;
      end
      bs_stall_win_d <= bs_stall_win;
      // One record every bs_dump_every clks, PLUS one on each edge of the stall
      // window, PLUS one every BS_PUSH_GRID pushes.  The release edge is the sweep
      // BYTESEAM_INSTRUMENT.md sec 2.4 pre-registers ("score the FIRST sweep after
      // release, never the stall itself"), so it must never be missed by falling
      // between two ticks.
      //
      // WHY THE PUSH GRID EXISTS (Task 46, first run).  The clk grid alone is NOT
      // comparable BETWEEN legs: a stall-edge emit re-phases the tick, so two legs
      // that differ only in stall length end their record streams ~124k clks apart,
      // and every cumulative counter differs by the ~240 words that arrive in that
      // extra window.  RXFIX_BS1_SIM_GATE.md D3/D4/D5/D6/D8 are cross-leg cumulative
      // comparisons and were unscoreable on the first run for exactly that reason
      // (D2 was immune because bs_drop stops advancing when the stall ends).  A record
      // at every BS_PUSH_GRID-th push gives both legs records at the SAME push index,
      // which is the only window in which those rows mean anything.  sim_sro.cpp never
      // calls Verilator's final(), so the `final` block below does not fire either --
      // hence a grid rather than an end-of-run record.
      if (bs_tick == 32'd0 || bs_stall_win != bs_stall_win_d
          || (h_tog != h_tog_prev && ((h_push + 32'd1) % BS_PUSH_GRID == 32'd0))) begin
        bs_emit;
        bs_tick <= bs_dump_every - 32'd1;
      end
      else bs_tick <= bs_tick - 32'd1;
    end
  end

  // ================================================================================
  // PADINJ (2026-09-08, ledger §47.12): (a) one CSV row per RxAlign startOut with the
  // beat counts of the previous frame at four stages, (b) +dvgap=N +dvgap_at=P kills
  // RxDeint's validIn for N enb_1_2_0 beats starting at FEC-validIn beat index P.
  // ================================================================================
`define FEC dut.u_Receiver.u_QPSK_Rx.u_FEC_Decoder_Wrapper
  reg [31:0] pf_dvgap, pf_dvgap_at, pf_mode, pf_killed; reg [1023:0] pf_fn; integer pf_fh;
  reg [31:0] fv_idx;            // FEC validIn beats since reset (injection index)
  reg [31:0] c_fecv, c_deint, c_align, c_ser;   // counts since the previous RxAlign start
  reg        pf_start_d; reg [31:0] pf_nframes;
  wire pf_enb   = `FEC.enb_1_2_0;
  wire pf_fecv  = `FEC.validIn;
  wire pf_deint = `FEC.deintValid_1;
  wire pf_align = `FEC.validOut;
  wire pf_start = `FEC.startOut;
  // mode 1: window of pf_dvgap FEC-validIn beats on RxDeint validIn.  mode 2: window that
  // stays open until pf_dvgap deintValid pulses have been suppressed (exact pair count).
  wire pf_win1  = (pf_mode == 32'd1) && (pf_dvgap != 32'd0) && (fv_idx >= pf_dvgap_at) && (fv_idx < pf_dvgap_at + pf_dvgap);
  wire pf_win2  = (pf_mode == 32'd2) && (pf_dvgap != 32'd0) && (fv_idx >= pf_dvgap_at) && (pf_killed < pf_dvgap);
  wire pf_win   = pf_win1 | pf_win2;
  wire pf_deint_raw = (`FEC.stateControl_2 == 1'b0 ? `FEC.deintValid_last_value : `FEC.deintValid);
  initial begin
    if (!$value$plusargs("dvgap=%d", pf_dvgap)) pf_dvgap = 32'd0;
    if (!$value$plusargs("dvgap_at=%d", pf_dvgap_at)) pf_dvgap_at = 32'd0;
    if (!$value$plusargs("dvgap_mode=%d", pf_mode)) pf_mode = 32'd1;
    if (!$value$plusargs("pftrace=%s", pf_fn)) pf_fn = "pf_trace.txt";
    pf_fh = $fopen(pf_fn, "w");
    $fwrite(pf_fh, "# frame,clk,fec_validIn,deintValid,align_validOut,ser_words,bs_wcnt_at_start,bs_trunc_cum,bs_drop_cum,inj_active,fv_idx\n");
    $display("PADINJ_ARGS mode=%0d dvgap=%0d dvgap_at=%0d", pf_mode, pf_dvgap, pf_dvgap_at);
  end
  always @(posedge clk) begin
    if (reset) begin
      fv_idx <= 0; c_fecv <= 0; c_deint <= 0; c_align <= 0; c_ser <= 0; pf_start_d <= 0; pf_nframes <= 0;
      `FEC.dvgap_kill <= 1'b0; `FEC.dvgap_kill2 <= 1'b0; pf_killed <= 0;
    end
    else begin
      `FEC.dvgap_kill  <= pf_win1;
      `FEC.dvgap_kill2 <= pf_win2;
      if (pf_enb && pf_win2 && pf_deint_raw) pf_killed <= pf_killed + 1;
      if (pf_enb) begin
        if (pf_fecv)  begin fv_idx <= fv_idx + 1; c_fecv <= c_fecv + 1; end
        if (pf_deint) c_deint <= c_deint + 1;
        if (pf_align) c_align <= c_align + 1;
        pf_start_d <= pf_start;
        if (pf_start && !pf_start_d) begin
          $fwrite(pf_fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", pf_nframes, h_clk, c_fecv, c_deint, c_align, c_ser,
`ifdef RXFIX_BS
                  dut.bs_wcnt, bs_cnt[31:16], bs_drop,
`else
                  0, 0, 0,
`endif
                  pf_win, fv_idx);
          pf_nframes <= pf_nframes + 1; c_fecv <= 0; c_deint <= 0; c_align <= 0; c_ser <= 0;
        end
      end
`ifdef RXFIX_BS
      if (dut.bs_enb_ser && dut.bs_wv) c_ser <= c_ser + 1;
`endif
    end
  end

  final begin
    $fflush(pf_fh);
    bs_emit;
    $fflush(bs_fh);
  end

  // ---- which wrapper actually compiled.  SEVEN files declare this module. --------
  initial begin
    $display("WRAPBS_FILE wrap_byte_padinj.v (bs + per-frame FEC trace + dvgap injection)");
`ifdef RXFIX_BS
    $display("WRAPBS_DEFINE RXFIX_BS");
`else
    $display("WRAPBS_DEFINE none");
`endif
    $display("WRAPBS_ARGS stall_at=%0d stall_n=%0d skip=%0d skip_at=%0d dump_every=%0d",
             bs_stall_at, bs_stall_n, bs_skip_val, bs_skip_at, bs_dump_every);
  end
endmodule
