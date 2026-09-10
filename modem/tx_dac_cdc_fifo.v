// tx_dac_cdc_fifo -- proper valid-handshake CDC for the in-FPGA-Tx modem output
// to the ADRV9002 fabric DAC input. Fixes the root cause: the reference-design
// sync_output crossing (sync_fast_to_slow) writes on a free-running clock-ratio
// tick and IGNORES the DUT data_valid, so the modem's gated 1-in-N valid samples
// slip/drop/repeat crossing adc_1_clk->dac_1_clk -> scrambled symbols (~35% EVM).
//
// This module WRITES each modem sample exactly once (gated by the modem valid on
// wr_clk=adc_1_clk) and READS exactly once per DAC beat (gated by dac_1_valid on
// rd_clk=dac_1_clk). Both clocks derive from the same ADRV9002 clkPLL (matched
// rate), so the FIFO self-centers and passes each sample once. On momentary
// underflow it holds the last sample (benign DAC reconstruction hold).
//
// Uses XPM async FIFO (Xilinx-verified CDC) so no hand-rolled gray-pointer risk.
// 1-sample/beat: only i0/q0 are driven; i1/q1 tied 0 (hardware spectrum showed the
// core consumes 1 sample/beat at these SSI rates -> no Nyquist image from zeros).

`timescale 1ns/1ps

module tx_dac_cdc_fifo #(
  parameter DW = 16
) (
  // write side (modem / adc_1_clk domain)
  input  wire            wr_clk,
  input  wire            wr_rstn,
  input  wire            wr_valid,      // dut_data_valid_out_tx
  input  wire [DW-1:0]   wr_i,          // dut_data_out_0_tx
  input  wire [DW-1:0]   wr_q,          // dut_data_out_1_tx
  // read side (DAC / dac_1_clk domain)
  input  wire            rd_clk,
  input  wire            rd_rstn,
  input  wire            rd_beat,       // dac_1_valid_i0 (DAC consumes a sample)
  output wire [DW-1:0]   dac_i0,
  output wire [DW-1:0]   dac_q0,
  output wire [DW-1:0]   dac_i1,
  output wire [DW-1:0]   dac_q1
);

  wire wr_rst = ~wr_rstn;
  wire [2*DW-1:0] din  = {wr_i, wr_q};
  wire [2*DW-1:0] dout;
  wire full, empty, prog_empty;

  // Hold read until the FIFO has primed past prog_empty -> centers fill level so
  // matched-rate producer/consumer never underflow in steady state.
  wire rd_en = rd_beat & ~empty & ~prog_empty_hold;

  reg prog_empty_hold;
  always @(posedge rd_clk) begin
    if (!rd_rstn)            prog_empty_hold <= 1'b1;   // start held (priming)
    else if (~prog_empty)    prog_empty_hold <= 1'b0;   // release once primed
    else if (empty)          prog_empty_hold <= 1'b1;   // re-prime on underflow
  end

  reg [2*DW-1:0] hold;
  always @(posedge rd_clk) begin
    if (!rd_rstn) hold <= {(2*DW){1'b0}};
    else if (rd_en) hold <= dout;
  end
  wire [2*DW-1:0] cur = rd_en ? dout : hold;

  assign dac_i0 = cur[2*DW-1:DW];
  assign dac_q0 = cur[DW-1:0];
  assign dac_i1 = {DW{1'b0}};
  assign dac_q1 = {DW{1'b0}};

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE("distributed"),
    .FIFO_WRITE_DEPTH(32),
    .WRITE_DATA_WIDTH(2*DW),
    .READ_DATA_WIDTH(2*DW),
    .READ_MODE("fwft"),
    .FIFO_READ_LATENCY(0),
    .CDC_SYNC_STAGES(3),
    .PROG_EMPTY_THRESH(8),
    .USE_ADV_FEATURES("0002"),   // enable prog_empty
    .WR_DATA_COUNT_WIDTH(1),
    .RD_DATA_COUNT_WIDTH(1),
    .DOUT_RESET_VALUE("0"),
    .ECC_MODE("no_ecc")
  ) u_fifo (
    .wr_clk     (wr_clk),
    .rst        (wr_rst),
    .wr_en      (wr_valid & ~full),
    .din        (din),
    .full       (full),
    .rd_clk     (rd_clk),
    .rd_en      (rd_en),
    .dout       (dout),
    .empty      (empty),
    .prog_empty (prog_empty),
    .sleep      (1'b0),
    .injectsbiterr(1'b0),
    .injectdbiterr(1'b0)
  );

endmodule
