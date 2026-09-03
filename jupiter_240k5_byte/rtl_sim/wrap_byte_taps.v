// wrap_byte_taps.v -- campaign wrapper: wrap_byte.v + hierarchical Rx STAGE TAPS
// for the float-vs-fixed per-stage localization (P3). Keeps the proven S1B gate
// wrapper (wrap_byte.v) untouched; built only by build_replay_iq.sh into
// obj_byte_taps. Tap mechanism = the same Verilator hierarchical-reference
// assigns the Tx oracle taps already use (wrap_byte.v:46-50).
`timescale 1 ns / 1 ns
module wrap_byte_taps
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
   // ---- Rx stage taps (signal order of the deployed chain) ----
   output wire agcV,  output wire signed [15:0] agcI,  output wire signed [15:0] agcQ,   // AGC out            sfix16_En14
   output wire rrcV,  output wire signed [15:0] rrcI,  output wire signed [15:0] rrcQ,   // RRC MF out         sfix16_En12
   output wire ssV,   output wire signed [15:0] ssI,   output wire signed [15:0] ssQ,    // symbol-sync out    sfix16_En14
   output wire cfcV,  output wire signed [15:0] cfcI,  output wire signed [15:0] cfcQ,   // coarse-freq-comp   sfix16_En14
   output wire signed [20:0] cfcFreq,                                                    // normalizedFreqEst  sfix21_En21
   output wire csV,   output wire signed [15:0] csI,   output wire signed [15:0] csQ,    // carrier-sync out   sfix16_En14
   output wire pdV,   output wire signed [15:0] pdI,   output wire signed [15:0] pdQ,    // preamble-det out   sfix16_En14
   output wire pdSync,
   output wire paV,   output wire signed [15:0] paI,   output wire signed [15:0] paQ,    // resolver out       sfix16_En14
   output wire paSync,
   output wire conV,  output wire signed [15:0] conI,  output wire signed [15:0] conQ,   // recovered constellation (post packet ctrl)
   output wire demV,  output wire demB, output wire demS,                                // demod bit / valid / startOut
   output wire fecV,  output wire fecB, output wire fecS);                               // FEC-decoded bit / valid / startOut
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
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
    .cap_in(nc6), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est), .adc_forensic(),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  // ---- stage taps (hierarchy verified: TxRxComposite.v:467 / Receiver.v:210 /
  //      QPSK_Rx.v:130; wire names from QPSK_Rx.v:73-89, F_a_T_S.v:55-73) ----
  assign agcV = dut.u_Receiver.u_QPSK_Rx.Automatic_Gain_Control_validOut;
  assign agcI = dut.u_Receiver.u_QPSK_Rx.Automatic_Gain_Control_dataOut_re;
  assign agcQ = dut.u_Receiver.u_QPSK_Rx.Automatic_Gain_Control_dataOut_im;
  assign rrcV = dut.u_Receiver.u_QPSK_Rx.RRC_Receive_Filter_out2;
  assign rrcI = dut.u_Receiver.u_QPSK_Rx.RRC_Receive_Filter_out1_re;
  assign rrcQ = dut.u_Receiver.u_QPSK_Rx.RRC_Receive_Filter_out1_im;
  assign ssV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Symbol_Synchronizer_validOut;
  assign ssI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Symbol_Synchronizer_dataOut_re;
  assign ssQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Symbol_Synchronizer_dataOut_im;
  assign cfcV = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_validOut;
  assign cfcI = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_dataOut_re;
  assign cfcQ = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_dataOut_im;
  assign cfcFreq = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_normalizedFreqEst;
  assign csV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_validOut;
  assign csI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_dataOut_re;
  assign csQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_dataOut_im;
  assign pdV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_validOut;
  assign pdI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_dataOut_re;
  assign pdQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_dataOut_im;
  assign pdSync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_syncPulse;
  assign paV  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Phase_Ambiguity_Estimation_and_Correction_validOut;
  assign paI  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Phase_Ambiguity_Estimation_and_Correction_dataOut_re;
  assign paQ  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Phase_Ambiguity_Estimation_and_Correction_dataOut_im;
  assign paSync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Phase_Ambiguity_Estimation_and_Correction_syncPulseOut;
  assign conV = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationValid;
  assign conI = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationPoints_re;
  assign conQ = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationPoints_im;
  assign demV = dut.u_Receiver.u_QPSK_Rx.QPSK_Demodulator_validOut;
  assign demB = dut.u_Receiver.u_QPSK_Rx.QPSK_Demodulator_dataOut;
  assign demS = dut.u_Receiver.u_QPSK_Rx.QPSK_Demodulator_startOut;
  assign fecV = dut.u_Receiver.u_QPSK_Rx.FEC_Decoder_Wrapper_validOut;
  assign fecB = dut.u_Receiver.u_QPSK_Rx.FEC_Decoder_Wrapper_dataOut;
  assign fecS = dut.u_Receiver.u_QPSK_Rx.FEC_Decoder_Wrapper_startOut;
endmodule
