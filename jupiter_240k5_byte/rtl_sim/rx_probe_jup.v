// rx_probe_jup.v -- taps the exact sample stream delivered to QPSK_Rx core
`timescale 1 ns / 1 ns
module rx_probe_jup
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   output wire [31:0] packets_out, bit_errors_out, cnt_frame_start,
   output wire [31:0] cap_out, cfc_est,
   output wire qEn, output wire qV,
   output wire signed [15:0] qdI, output wire signed [15:0] qdQ);
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7,nc8,nc9,nc10;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .count_out(nc7), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc8), .cnt_deint_valid(nc1),
    .cnt_dec_bits(nc2), .cnt_bist_start(nc9), .dbg_sentinel(nc3),
    .cap_in(nc4), .cap_deint(nc5), .cap_out(cap_out), .cap_cad(nc6),
    .rstcs_count(nc10), .cfc_est(cfc_est));
  assign qEn = dut.u_Receiver.enb_1_4_0_smp;
  assign qV  = dut.u_Receiver.Delay1_out1;
  assign qdI = dut.u_Receiver.Delay_out1_re;
  assign qdQ = dut.u_Receiver.Delay_out1_im;
endmodule
