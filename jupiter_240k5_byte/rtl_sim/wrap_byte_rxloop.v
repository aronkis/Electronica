// wrap_byte_rxloop.v -- [sim] Task 8d: closed-loop RX-front-end harness (2026-09-04).
//
// wrap_byte_seqbist.v lineage (the RTL qpsk_traffic_gen_v2 drives the DUT TX
// byte pins) crossed with wrap_byte_sro.v's TX-IQ export, so that the C++
// driver can close the air loop THROUGH an impairment stage:
//
//   TGEN v2 -> byte pins -> Transmitter -> txI/txQ  --(C++: CFO + AWGN)-->
//   adc_dataIn{I,Q} (rx_input_select = 1) -> Receiver -> byte_rx_*
//
// One sim, one pass: no separate txcap + resample stage (COMB32_SRO_SIM.md's
// two-stage route), so the payload is the real non-tiled TGEN stream and every
// leg costs one run instead of two.
//
// The taps are the ones the frame-window hypothesis needs (RX_WINDOW_RTL.md
// section 2): Peak_Search's per-epoch argmax state and Timing_Adjust's applied
// offset, plus the correlator decision inputs.
`timescale 1 ns / 1 ns
module wrap_byte_rxloop
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   input  wire [31:0] tgen_ctrl,        // [0] en, [15:4] fill, [31:16] skip/corrupt
   input  wire [31:0] tgen_gap,         // [26:0] gap clks, [27] mode
   input  wire        byte_rx_ready,
   output wire [63:0] byte_rx_data,
   output wire        byte_rx_valid, byte_rx_last, byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_out, rstcs_count, cfc_est,
   output wire [31:0] byte_fifo_ovf,
   output wire        railEnb,
   output wire signed [15:0] txI, output wire signed [15:0] txQ,
   output wire        tg_valid, tg_first, tg_ready,
   output wire [31:0] tg_seq,
   // ---- Peak_Search / Timing_Adjust / correlator taps ----
   output wire [13:0] psTref,        // free-running mod-12333 epoch counter
   output wire [13:0] psToff,        // argmax position reported for the epoch
   output wire [31:0] psRunmax,      // winning correlation magnitude
   output wire [31:0] psHeldts,      // absolute timestamp of the winning peak
   output wire        psNewpk,       // a new epoch maximum was latched
   output wire [13:0] taAccoff,      // offset Timing_Adjust is applying
   output wire        taArmed,
   output wire        pdSync,        // Preamble_Detector syncPulse
   output wire signed [31:0] corr,   // Correlator dataOut  (sfix32_En26)
   output wire signed [31:0] corrThr, // Correlator threshold (sfix32_En28)
   output wire        corrXcd,       // thresholdExceeded
   output wire        corrValid);

  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1;
  wire ncV;

  // ---------------- TGEN v2 -> DUT TX byte pins ----------------
  wire [63:0] tg_data_raw; wire tg_valid_raw, tg_first_raw;
  wire        byte_ready;
  qpsk_traffic_gen_v2 u_tgen (
    .clk(clk), .resetn(!reset),
    .ctrl(tgen_ctrl), .gap(tgen_gap),
    .host_data(64'd0), .host_valid(1'b0), .host_first(1'b0), .host_ready(),
    .dut_data(tg_data_raw), .dut_valid(tg_valid_raw), .dut_first(tg_first_raw),
    .dut_ready(byte_ready));
  assign tg_valid = tg_valid_raw;
  assign tg_first = tg_first_raw;
  assign tg_ready = byte_ready;
  assign tg_seq   = u_tgen.seq;

  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(tg_data_raw), .byte_valid(tg_valid_raw),
    .tx_data_source(tx_data_source), .byte_first(tg_first_raw),
    .byte_rx_ready(byte_rx_ready),
    .framestat_pop(32'd0),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(ncI1), .debugQ1(ncQ1),
    .tx_dataOutI(), .tx_dataOutQ(), .tx_validOut(),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(nc6), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user),
    .byte_fifo_ovf(byte_fifo_ovf));

  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  assign txI = dut.Transmitter_dataOutI;
  assign txQ = dut.Transmitter_dataOutQ;

  // Peak_Search / Timing_Adjust / Correlator (Preamble_Detector.v:62-75,148-215;
  // Timing_Adjust.v:216-222)
  assign psTref    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_tref;
  assign psToff    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_timingOffset;
  assign psRunmax  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_runmax;
  assign psHeldts  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_heldts;
  assign psNewpk   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_p1c_newpk;
  assign taAccoff  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_accoff;
  assign taArmed   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_armed;
  assign pdSync    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_syncPulse;
  assign corr      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_dataOut;
  assign corrThr   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_threshold;
  assign corrXcd   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Relational_Operator_out1;
  assign corrValid = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Correlator_validOut;
endmodule
