// wrap_byte_w1.v -- [sim] RXFIX_W1 instrument gate wrapper (Task 9, 2026-09-04).
//
// NEW FILE.  wrap_byte_sro.v is Task 7's and is running live legs out of
// obj_byte_sro; nothing here touches it or that obj dir.
//
// Purpose: prove, on the real receiver RTL, that the RXFIX_W1 registers report
// exactly what an INDEPENDENT reference computed from the raw hierarchical taps
// says they should -- true ring occupancy, both ring pointers, the two edge-event
// counters, and the six per-stage valid counters -- and that the instrument does
// not disturb the data path (the byte-plane output stream is compared, frame for
// frame, against a baseline build of the SAME wrapper on the unpatched tree).
//
// The W1 taps are behind `ifdef RXFIX_W1 so ONE driver binary layout serves both
// the patched and the baseline build, exactly as wrap_byte_sro.v does for R3.
`timescale 1 ns / 1 ns
module wrap_byte_w1
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
   output wire railEnb,
   // ---- raw hierarchical taps: the INDEPENDENT reference for the gate ----
   output wire rhStrobe,                 // Rate_Handle .strobe  (census stage a)
   output wire rhValidOut,               // Rate_Handle validOut (census stage b)
   output wire cfcV, csV, pdV, pcV,      // census stages c, d, e, f
   output wire [4:0] fifoPush, fifoPop,  // ring pointers
   output wire [5:0] occTrue,            // TRUE ring occupancy 0..32
   output wire rhPopEmpty, rhPushFull,   // the two ring edge events
   // ---- the RXFIX_W1 registers themselves (zero on the baseline build) ----
   output wire [31:0] w1A, w1B, w1cSS, w1cRH, w1cCFC, w1cCS, w1cPD, w1cPC);

  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7,nc8,nc9,nc10;
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
    .cnt_descr_in(nc0), .cnt_frame_start(nc8),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(nc6), .cap_deint(nc7), .cap_out(nc9), .cap_cad(),
    .rstcs_count(nc10), .cfc_est(),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));

  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;

  // ---- raw taps, identical hierarchy paths to wrap_byte_sro.v:126-147 ----
  assign rhStrobe   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.strobe;
  assign rhValidOut = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.validOut;
  assign cfcV       = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_validOut;
  assign csV        = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Carrier_Synchronizer_validOut;
  assign pdV        = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_validOut;
  assign pcV        = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_validOut;
  assign fifoPush   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Push_Counter_out1;
  assign fifoPop    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.Pop_Counter_out1;
  assign occTrue    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1;
  assign rhPopEmpty = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.pop_on_empty_FIFO;
  assign rhPushFull = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO;

`ifdef RXFIX_W1
  // The eight words exactly as the AXI decoder would slice them out of w1Bus.
  assign w1A    = dut.u_Receiver.u_QPSK_Rx.w1Bus[ 31:  0];
  assign w1B    = dut.u_Receiver.u_QPSK_Rx.w1Bus[ 63: 32];
  assign w1cSS  = dut.u_Receiver.u_QPSK_Rx.w1Bus[ 95: 64];
  assign w1cRH  = dut.u_Receiver.u_QPSK_Rx.w1Bus[127: 96];
  assign w1cCFC = dut.u_Receiver.u_QPSK_Rx.w1Bus[159:128];
  assign w1cCS  = dut.u_Receiver.u_QPSK_Rx.w1Bus[191:160];
  assign w1cPD  = dut.u_Receiver.u_QPSK_Rx.w1Bus[223:192];
  assign w1cPC  = dut.u_Receiver.u_QPSK_Rx.w1Bus[255:224];
`else
  assign w1A = 32'd0; assign w1B = 32'd0;
  assign w1cSS = 32'd0; assign w1cRH = 32'd0; assign w1cCFC = 32'd0;
  assign w1cCS = 32'd0; assign w1cPD = 32'd0; assign w1cPC = 32'd0;
`endif
endmodule
