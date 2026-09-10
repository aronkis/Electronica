// wrap_byte_trace.v -- trace harness for the Phase Ambiguity resolver.
// Same drive as wrap_byte_dbg.v (byte source, tx_data_source=1) plus taps on
// the Phase Ambiguity Estimation and Correction block boundary:
//   pa_inI/Q  = received symbol entering the block (dataIn)
//   pa_zI/Q   = averaged estimate Z (Average_Estimates.avgEst)
//   pa_outI/Q = corrected output (dataOut)
//   pa_sync/pa_vin/pa_vout = syncPulseIn / validIn / validOut
`timescale 1 ns / 1 ns
module wrap_byte_trace
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
   output wire [31:0] cap_in, output wire [31:0] cap_deint,
   // --- Phase Ambiguity resolver taps ---
   output wire signed [15:0] pa_inI,  output wire signed [15:0] pa_inQ,
   output wire signed [15:0] pa_zI,   output wire signed [15:0] pa_zQ,
   output wire signed [15:0] pa_outI, output wire signed [15:0] pa_outQ,
   output wire pa_sync, output wire pa_vin, output wire pa_vout,
   // --- estimator-internal taps (what it actually correlates) ---
   output wire signed [15:0] est_inI, output wire signed [15:0] est_inQ,
   output wire [2:0] est_cnt, output wire est_scnt,
   output wire signed [15:0] est_refI, output wire signed [15:0] est_refQ);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1,ncTI,ncTQ; wire ncV,ncTV;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(byte_data), .byte_valid(byte_valid),
    .tx_data_source(tx_data_source), .byte_first(byte_first),
    .byte_rx_ready(byte_rx_ready),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(ncI1), .debugQ1(ncQ1),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(cap_in), .cap_deint(cap_deint), .cap_out(cap_out), .cap_cad(),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est), .adc_forensic(),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  assign railEnb  = dut.u_TxRxComposite_tc.enb_1_2_0;
  // Phase Ambiguity Estimation and Correction block boundary (full hierarchical taps)
  assign pa_inI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.dataIn_re;
  assign pa_inQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.dataIn_im;
  assign pa_zI   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Average_Estimates.avgEst_re;
  assign pa_zQ   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Average_Estimates.avgEst_im;
  assign pa_outI = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.dataOut_re;
  assign pa_outQ = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.dataOut_im;
  assign pa_sync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.syncPulseIn;
  assign pa_vin  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.validIn;
  assign pa_vout = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.validOut;
  // estimator internals: dataIn it sees, its ref index (counter), the ref symbol
  assign est_inI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.dataIn_re;
  assign est_inQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.dataIn_im;
  assign est_cnt  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.HDL_Counter_out1;
  assign est_scnt = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.Subsystem1_validOut;
  assign est_refI = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.Direct_Lookup_Table_n_D_out1_re;
  assign est_refQ = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Phase_Ambiguity_Estimation_and_Correction.u_Phase_Ambiguity_Estimator.Direct_Lookup_Table_n_D_out1_im;
endmodule
