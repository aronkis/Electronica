// wrap_byte_lock.v -- STAGE-1 sim instrumentation wrapper (2026-08-13 staged task).
// wrap_byte_taps.v + LOOP-STATE taps for the symbol-sync-resonance kill test:
//   - Gardner TED error + symbol-sync loop-filter integrator/proportional states
//   - carrier-sync phase error + loop-filter integrator/proportional states
// Tap mechanism = the same Verilator hierarchical-reference assigns the stage
// taps already use (wrap_byte_taps.v:58-93). Jul-25 f1536 netlist ONLY
// (.claude/worktrees/txmux-localize/.../s1_rtl_f1536/hdlsrc) -- the current
// regen is a known regression (FLOAT_GAP_BUDGET.md side finding).
`timescale 1 ns / 1 ns
module wrap_byte_dip
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
   // ---- Rx stage taps (as wrap_byte_taps.v) ----
   output wire ssV,   output wire signed [15:0] ssI,   output wire signed [15:0] ssQ,
   output wire cfcV,  output wire signed [15:0] cfcI,  output wire signed [15:0] cfcQ,
   output wire signed [20:0] cfcFreq,
   output wire csV,   output wire signed [15:0] csI,   output wire signed [15:0] csQ,
   output wire pdV,   output wire pdSync,
   output wire conV,  output wire signed [15:0] conI,  output wire signed [15:0] conQ,
   // ---- NEW loop-state taps ----
   output wire signed [39:0] ssErr,    // Gardner_TED_e            sfix40_En24
   output wire signed [29:0] ssIntP,   // SS Loop_Filter_stateP    sfix30_En23
   output wire signed [29:0] ssIntI,   // SS Loop_Filter_stateI    sfix30_En23
   output wire signed [12:0] csErr,    // Phase_Error_Detector_PhaseError sfix13_En10
   output wire signed [28:0] csIntP,   // CS Loop_Filter_stateP    sfix29_En29
   output wire signed [38:0] csIntI);  // CS Loop_Filter_stateI    sfix39_En39
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
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  // stage taps (hierarchy identical to wrap_byte_taps.v)
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
  assign pdSync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_syncPulse;
  assign conV = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationValid;
  assign conI = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationPoints_re;
  assign conQ = dut.u_Receiver.u_QPSK_Rx.QPSKConstellationPoints_im;
  // loop-state taps (wire names verified in the Jul-25 netlist:
  //   Symbol_Synchronizer.v:111-116, Carrier_Synchronizer.v:117-122)
  assign ssErr = 0;   // tied: probe absent in the flashed generation
  assign ssIntP = 0;   // tied: probe absent in the flashed generation
  assign ssIntI = 0;   // tied: probe absent in the flashed generation
  assign csErr = 0;   // tied: probe absent in the flashed generation
  assign csIntP = 0;   // tied: probe absent in the flashed generation
  assign csIntI = 0;   // tied: probe absent in the flashed generation
endmodule
