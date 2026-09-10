// rx_wrap_jup.v -- Verilator wrapper for jupiter_240k5 TxRxComposite (linkA replay)
`timescale 1 ns / 1 ns
module rx_wrap_jup
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cnt_vit_reset, cnt_bist_start,
   output wire [31:0] cap_out, rstcs_count, cfc_est,
   output wire enb14, output wire ssV,
   output wire signed [20:0] cfcEst, output wire cfcRst, output wire pcStart);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(cnt_vit_reset), .cnt_deint_valid(nc1),
    .cnt_dec_bits(nc2), .cnt_bist_start(cnt_bist_start), .dbg_sentinel(nc3),
    .cap_in(nc4), .cap_deint(nc5), .cap_out(cap_out), .cap_cad(nc6),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est));
  assign enb14 = dut.u_TxRxComposite_tc.enb_1_4_0;
  assign ssV   = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Symbol_Synchronizer_validOut;
  assign cfcEst= dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_normalizedFreqEst;
  assign cfcRst= dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Coarse_Frequency_Compensator_rstCS;
  assign pcStart=dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Packet_Controller_startOut;
endmodule
