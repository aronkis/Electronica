// wrap_byte_bf2.v -- BEATFIX2 gate wrapper: wrap_byte_ce + fixctl/viol ports.
// Model-1 (two_jup/MODEL1_ENABLE_INJECT.md). Derived from wrap_byte.v but:
//   (1) drives the DUT from the IN-FABRIC BIST ROM loopback source
//       (rx_input_select=0 -> internal Transmitter loopback; tx_data_source=0
//        -> ROM/BIST frame generator), NO ADC IQ needed;
//   (2) EXPOSES cap_in (top-level FEC-wrapper-INPUT hash; golden 0x5216F3E2),
//       cap_out (decoder-output hash; golden 0x04922282) and cnt_frame_start;
//   (3) makes clk_enable a WRAPPER INPUT so the harness can DROP one pulse
//       (the glitch-free enable-phase-swap injection); default driven to 1;
//   (4) taps the demod-serializer enable enb_1_2_0 as railEnb for cadence.
// count2 (TxRxComposite_tc) and HDL_Counter_out1 (QPSK_Demodulator Serializer)
// are reached via Verilator --public-flat-rw for the direct-poke injection legs.
`timescale 1 ns / 1 ns
module wrap_byte_ce
  (input  wire clk, input wire reset,
   input  wire clk_enable,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   input  wire [31:0] fixctl,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_in, cap_out, rstcs_count, cfc_est,
   output wire modValid,
   output wire signed [15:0] modI, output wire signed [15:0] modQ,
   output wire signed [15:0] txOutI, output wire signed [15:0] txOutQ,
   output wire signed [15:0] dbg1I, output wire signed [15:0] dbg1Q,
   output wire [31:0] bfViol, output wire [31:0] bfLatch,
   output wire railEnb);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc7;
  wire signed [15:0] ncI,ncQ,ncTI,ncTQ; wire ncV,ncTV;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(clk_enable),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(byte_data), .byte_valid(byte_valid),
    .tx_data_source(tx_data_source), .byte_first(byte_first),
    .byte_rx_ready(byte_rx_ready),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(dbg1I), .debugQ1(dbg1Q),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(cap_in), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .fixctl(fixctl), .beatfix_viol_count(bfViol), .beatfix_viol_latch(bfLatch),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user));
  assign modValid = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationValid;
  assign modI     = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationPoints_re;
  assign modQ     = dut.u_Transmitter.u_QPSK_Tx.QPSKConstellationPoints_im;
  assign railEnb  = dut.u_TxRxComposite_tc.enb_1_2_0;
  // TX pulse-shaped loopback samples (what rx_input_select=0 feeds the RX).
  // Route these back through the adc_dataIn/adc_validIn front port (ADC mode,
  // rx_input_select=1) to exercise the physically-real sample-cadence path.
  assign txOutI   = dut.Transmitter_dataOutI;
  assign txOutQ   = dut.Transmitter_dataOutQ;
endmodule
