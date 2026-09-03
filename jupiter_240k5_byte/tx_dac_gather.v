// tx_dac_gather -- 1->2 sample gather for the in-FPGA-Tx modem output to the
// ADRV9002 fabric DAC. Root cause of the half-rate transmit: the DAC fabric
// interface is number_of_inputs=4 = TWO complex samples per beat (i0/q0 = sample
// n, i1/q1 = sample n+1), but the modem drives only ONE complex sample per beat
// (dut_data_out_0/1_tx) with i1/q1 left at 0 -> the DAC transmits 1 real sample
// per 2-sample beat = HALF the intended symbol rate (120 vs 240 ksym).
//
// Fix: gather two CONSECUTIVE modem samples and present them together as
// (i0/q0)=even, (i1/q1)=odd per DAC beat, so the DAC transmits 2 real samples/
// beat = full rate. Write side paces on the modem sample valid (dut_data_valid_
// out_tx, which is <=1-in-2 per the ADI regularizer contract); read side pops one
// gathered pair per DAC beat (dac_1_valid_i0). CDC via XPM async FIFO.

`timescale 1ns/1ps

module tx_dac_gather #(
  parameter DW = 16
) (
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            wr_clk,     // adc_1_clk (modem / IPCORE_CLK domain)
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            wr_rstn,
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            wr_valid,   // dut_data_valid_out_tx (one pulse per modem sample)
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire [DW-1:0]   wr_i,       // dut_data_out_0_tx
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire [DW-1:0]   wr_q,       // dut_data_out_1_tx
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            rd_clk,     // dac_1_clk
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            rd_rstn,
  (* X_INTERFACE_IGNORE = "true" *)
  input  wire            rd_beat,    // dac_1_valid_i0 (2-sample DAC beat)
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [DW-1:0]   dac_i0,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [DW-1:0]   dac_q0,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [DW-1:0]   dac_i1,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [DW-1:0]   dac_q1
);

  wire wr_rst = ~wr_rstn;

  // --- write side: gather two consecutive modem samples into one pair ---
  reg [DW-1:0] i_even, q_even;
  reg          phase;
  always @(posedge wr_clk) begin
    if (!wr_rstn) begin
      phase <= 1'b0; i_even <= {DW{1'b0}}; q_even <= {DW{1'b0}};
    end else if (wr_valid) begin
      if (phase == 1'b0) begin
        i_even <= wr_i; q_even <= wr_q; phase <= 1'b1;   // first of pair
      end else begin
        phase <= 1'b0;                                   // second -> commit pair
      end
    end
  end
  wire            wr_pair = wr_valid & phase;                 // commit on 2nd sample
  wire [4*DW-1:0] din     = {i_even, q_even, wr_i, wr_q};     // {i0,q0,i1,q1}

  wire [4*DW-1:0] dout;
  wire full, empty, prog_empty;

  reg prog_empty_hold;
  always @(posedge rd_clk) begin
    if (!rd_rstn)          prog_empty_hold <= 1'b1;
    else if (~prog_empty)  prog_empty_hold <= 1'b0;
    else if (empty)        prog_empty_hold <= 1'b1;
  end
  wire rd_en = rd_beat & ~empty & ~prog_empty_hold;

  reg [4*DW-1:0] hold;
  always @(posedge rd_clk) begin
    if (!rd_rstn) hold <= {(4*DW){1'b0}};
    else if (rd_en) hold <= dout;
  end
  wire [4*DW-1:0] cur = rd_en ? dout : hold;

  assign dac_i0 = cur[4*DW-1:3*DW];
  assign dac_q0 = cur[3*DW-1:2*DW];
  assign dac_i1 = cur[2*DW-1:1*DW];
  assign dac_q1 = cur[1*DW-1:0];

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"),
    .FIFO_WRITE_DEPTH(32),
    .WRITE_DATA_WIDTH(4*DW),
    .READ_DATA_WIDTH(4*DW),
    .READ_MODE("fwft"),
    .FIFO_READ_LATENCY(0),
    .CDC_SYNC_STAGES(3),
    .PROG_EMPTY_THRESH(8),
    .USE_ADV_FEATURES("0002"),
    .WR_DATA_COUNT_WIDTH(1),
    .RD_DATA_COUNT_WIDTH(1),
    .DOUT_RESET_VALUE("0"),
    .ECC_MODE("no_ecc")
  ) u_fifo (
    .wr_clk(wr_clk), .rst(wr_rst), .wr_en(wr_pair & ~full), .din(din), .full(full),
    .rd_clk(rd_clk), .rd_en(rd_en), .dout(dout), .empty(empty), .prog_empty(prog_empty),
    .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0)
  );

endmodule
