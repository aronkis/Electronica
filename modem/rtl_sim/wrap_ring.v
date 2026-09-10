// wrap_ring.v -- [sim] task 6: per-beat Rate_Handle ring dump around the EMPTY edge.
`timescale 1 ns / 1 ns
module wrap_ring
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count, input wire [31:0] tx_data_source,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_out, rstcs_count, cfc_est,
   output wire railEnb,
   // ---- ring taps ----
   output wire signed [15:0] rhInI, output wire signed [15:0] rhInQ,
   output wire rhStrobe, output wire rhValidIn, output wire rhPop, output wire rhValidOut,
   output wire signed [15:0] rhOutI, output wire signed [15:0] rhOutQ,
   output wire [4:0] pushPtr, output wire [4:0] popPtr,
   output wire vPush, output wire vPop,
   output wire [5:0] occTrue, output wire popEmpty, output wire pushFull,
   // ---- correlator input ----
   output wire signed [15:0] corrInI, output wire signed [15:0] corrInQ,
   output wire corrInV, output wire [13:0] tref,
   // ---- interpolator / timing loop ----
   output wire signed [10:0] icCountReg, output wire signed [12:0] icCounter,
   output wire signed [10:0] icDelta,    output wire signed [10:0] icMu,
   output wire icUnd, output wire signed [39:0] tedE);
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
  assign rhInI     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataIn_re;
  assign rhInQ     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.dataIn_im;
  assign rhStrobe  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.strobe;
  assign rhValidIn = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.validIn;
  assign rhPop     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.Logical_Operator_out1;
  assign rhValidOut= dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.validOut;
  assign rhOutI    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.FIFO_out_re;
  assign rhOutQ    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.FIFO_out_im;
  assign pushPtr   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Push_Counter_out1;
  assign popPtr    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Pop_Counter_out1;
  assign vPush     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Validate_Input_Push_Pop_valid_push;
  assign vPop      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Validate_Input_Push_Pop_valid_pop;
  assign occTrue   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1;
  assign popEmpty  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.pop_on_empty_FIFO;
  assign pushFull  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO;
  assign corrInI   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay1_out1_re;
  assign corrInQ   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay1_out1_im;
  assign corrInV   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay2_out1;
  assign tref      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_Peak_Search.timing_Reference_out1;
  assign icCountReg= dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Interpolation_Control.countReg;
  assign icCounter = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Interpolation_Control.counter;
  assign icDelta   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Interpolation_Control.Delta;
  assign icMu      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.mu;
  assign icUnd     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.Underflow;
  assign tedE      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.Gardner_TED_e;
endmodule
