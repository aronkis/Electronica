// wrap_byte_sro4.v -- [sim] Task 12 (RXFIX_R4) SRO harness wrapper (2026-09-04).
//
// A THIRD SEPARATE FILE, not an edit of wrap_byte_sro.v (Task 7) or wrap_byte_sro3s.v
// (Task 11): both of those, and every result banked from them, must not move under
// Task 12.  The module NAME is deliberately still `wrap_byte_sro` so that
// sim_sro.cpp -- Task 7's driver, byte for byte -- links against it unmodified; that
// is what makes the n_p000 content-identity gate a test of the RTL and not a test of
// a re-typed driver.
//
// BECAUSE THREE files now declare `module wrap_byte_sro`, this one announces itself
// at time 0.  A run that does not print WRAP4_FILE / WRAP4_DEFINE compiled the WRONG
// wrapper, and that failure would otherwise masquerade as "R4 never skipped" --
// which is part of the n_p000 PASS condition.  build_sro_rxfix4.sh greps the
// verilate log for BOTH of the other two wrappers as well.
//
// R4 witnesses are carried on Task 7's three existing witness ports so that the
// driver needs no change:
//   r3Skips  = r4_skips     (count of steered pop SKIPS -- read as r4_skips)
//   r3Extras = 32'hA5A50001 while r4_prefilled, else 0.  It is a SENTINEL, NOT a
//              count: R4 has no extra-pop branch at all (that branch is what got R3
//              rejected), and a plain 1 here would read as "one extra pop was taken".
//              The transition 0 -> A5A50001 is the instant the ring finished
//              pre-filling, so <p>_ep.txt kind 5 timestamps the PRE-FILL.
//   r3Guard  = Packet_Controller_guardOut
// The <p>_ep.txt epoch trace therefore records kind 4 = steered SKIP and kind 5 =
// the single PRE-FILL-complete instant (Task 11 used kind 5 for its arming instant).
//
// It also keeps the read-only per-stage taps of the Task 11 wrapper (no effect on
// any port sim_sro.cpp drives) so a stagewin dump can be built against R4 if the
// falsifier fires; sim_stagewin.cpp is the only consumer.
//
// Original header of the file this was cut from (via the Task 11 wrapper):
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
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(dut_byte_data), .byte_valid(dut_byte_valid),
    .tx_data_source(tx_data_source), .byte_first(dut_byte_first),
    .byte_rx_ready(byte_rx_ready),
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

  // ---- T12: RXFIX_R4 witnesses, carried on T7's three witness ports ----
  // build_sro_rxfix4.sh passes +define+RXFIX_R4 with the R4 tree on -y.
`ifdef RXFIX_R4
  assign r3Skips  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.r4_skips;
  // SENTINEL, not a count -- R4 has no extra-pop branch.  See the header.
  assign r3Extras = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.r4_prefilled
                    ? 32'hA5A50001 : 32'd0;
  assign r3Guard  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_guardOut;
`else
  assign r3Skips  = 32'd0;
  assign r3Extras = 32'd0;
  assign r3Guard  = 1'b0;
`endif

  // ---- T12: which wrapper actually compiled.  THREE files declare this module. ----
  initial begin
    $display("WRAP4_FILE wrap_byte_sro4.v t12a");
`ifdef RXFIX_R4
    $display("WRAP4_DEFINE RXFIX_R4");
`else
    $display("WRAP4_DEFINE none");
`endif
  end
endmodule
