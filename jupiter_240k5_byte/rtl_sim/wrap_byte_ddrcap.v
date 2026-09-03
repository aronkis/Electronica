// wrap_byte_ddrcap.v -- DDRCAP sim-gate wrapper (Task 2, 2026-08-31).
// Model-1 loopback (two_jup/MODEL1_ENABLE_INJECT.md), same drive discipline
// as wrap_byte_dbgcap.v: internal Transmitter loopback (rx_input_select=0),
// ROM/BIST frame generator (tx_data_source=0), no ADC IQ needed.
//
// Unlike wrap_byte_dbgcap.v's use of Verilator hierarchical references for
// some signals (dut.u_Transmitter.u_QPSK_Tx.xxx) -- the exact mechanism the
// TX-INT report found reads dead copies -- the five ddrcap_* signals here are
// REAL top-level ports on TxRxComposite, connected as plain ports on this
// wrapper. No hierarchical refs are used for anything this sim gate asserts
// on, so a positive-control poke through iq_debug_mux is trustworthy.
`timescale 1 ns / 1 ns
module wrap_byte_ddrcap
  (input  wire clk, input wire reset,
   input  wire clk_enable,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   input  wire [31:0] fixctl,
   input  wire [31:0] iq_debug_mux,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_in, cap_out, rstcs_count, cfc_est,
   // ---- ddrcap: five real top-level ports, no hierarchical refs ----
   output wire signed [15:0] ddrcap_i,
   output wire signed [15:0] ddrcap_q,
   output wire [15:0] ddrcap_mark_demod,
   output wire [15:0] ddrcap_mark_fec,
   output wire ddrcap_valid,
   // ---- legacy DBGCAP readback (bits[3:0] of iq_debug_mux), real ports too --
   // needed to demonstrate the low/high nibble decodes run simultaneously
   // (review finding 5): iq_debug_mux[3:0] still drives DBGCAP/TXCAP/DEMODCAP
   // via fixctl exactly as sim_final.cpp exercises it, unaffected by [19:16].
   output wire [31:0] bfViol, output wire [31:0] bfLatch);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc7;
  wire signed [15:0] ncI,ncQ,ncTI,ncTQ; wire ncV,ncTV;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(clk_enable),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(iq_debug_mux), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(byte_data), .byte_valid(byte_valid),
    .tx_data_source(tx_data_source), .byte_first(byte_first),
    .byte_rx_ready(byte_rx_ready),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(), .debugQ1(),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(cap_in), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .fixctl(fixctl), .beatfix_viol_count(bfViol), .beatfix_viol_latch(bfLatch),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user),
    .ddrcap_i(ddrcap_i), .ddrcap_q(ddrcap_q),
    .ddrcap_mark_demod(ddrcap_mark_demod), .ddrcap_mark_fec(ddrcap_mark_fec),
    .ddrcap_valid(ddrcap_valid));

endmodule
