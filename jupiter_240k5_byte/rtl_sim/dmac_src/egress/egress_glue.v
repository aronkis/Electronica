// egress_glue.v -- the byte-RX egress of TxRxComposite (flashed lineage) with the
// demod+serializer replaced by generator inputs. Copied verbatim from
// TxRxCompo_ip_src_TxRxComposite.v (ipshared/973a): clock-enable block (_tc),
// RxReadyRT (byte_rx_ready sampled under enb_1_2_1), Ser*RT registers (serializer
// outputs sampled under enb_1_2_0), ByteRxFifo (ORIGINAL 64-word: FIFO_V4=0, or the
// rxfifo4k v4 BRAM drop-in: FIFO_V4=1), and the 4-stage delayMatch chains on
// data/valid/last/user that feed the byte_rx_* pins.
`timescale 1ns/1ps
module egress_glue #(parameter FIFO_V4 = 0) (
  input  wire        clk,
  input  wire        reset,
  input  wire        clk_enable,
  // serializer-side inputs (held stable; tog flips once per emitted word)
  input  wire [63:0] ser_word,
  input  wire        ser_tog,
  input  wire        ser_last,
  input  wire        ser_first,
  // AXIS pins toward rx_byte_breakout / axi_dmac
  input  wire        byte_rx_ready,
  output wire [63:0] byte_rx_data,
  output wire        byte_rx_valid,
  output wire        byte_rx_last,
  output wire        byte_rx_user,
  output wire [31:0] ovf,
  output wire        enb_1_2_0_o,
  output wire        fifo_valid_o
);
  wire enb, enb_1_1_1, enb_1_2_0, enb_1_2_1;
  TxRxCompo_ip_src_TxRxComposite_tc u_tc (.clk(clk), .reset(reset), .clk_enable(clk_enable),
    .enb(enb), .enb_1_1_1(enb_1_1_1), .enb_1_2_0(enb_1_2_0), .enb_1_2_1(enb_1_2_1));
  assign enb_1_2_0_o = enb_1_2_0;
  // Ser*RT: serializer outputs registered under enb_1_2_0
  reg [63:0] SerWordRT_out1; reg SerTogRT_out1, SerLastRT_out1, SerFirstRT_out1;
  always @(posedge clk or posedge reset) begin
    if (reset) begin SerWordRT_out1 <= 64'd0; SerTogRT_out1 <= 1'b0; SerLastRT_out1 <= 1'b0; SerFirstRT_out1 <= 1'b0; end
    else if (enb_1_2_0) begin SerWordRT_out1 <= ser_word; SerTogRT_out1 <= ser_tog; SerLastRT_out1 <= ser_last; SerFirstRT_out1 <= ser_first; end
  end
  wire [63:0] outWord; wire valid, outLast, outFirst; wire [31:0] ovf_w;
  generate if (FIFO_V4) begin : g_v4
    ByteRxFifo #(.DEPTH(4096), .AW(12)) u_ByteRxFifo (.clk(clk), .reset(reset), .enb(enb), .word(SerWordRT_out1), .tog(SerTogRT_out1),
      .wLast(SerLastRT_out1), .wFirst(SerFirstRT_out1), .ready(byte_rx_ready), .outWord(outWord), .valid(valid), .outLast(outLast), .outFirst(outFirst), .ovf(ovf_w));
  end else begin : g_orig
    TxRxCompo_ip_src_ByteRxFifo u_ByteRxFifo (.clk(clk), .reset(reset), .enb(enb), .word(SerWordRT_out1), .tog(SerTogRT_out1),
      .wLast(SerLastRT_out1), .wFirst(SerFirstRT_out1), .ready(byte_rx_ready), .outWord(outWord), .valid(valid), .outLast(outLast), .outFirst(outFirst), .ovf(ovf_w));
  end endgenerate
  assign fifo_valid_o = valid;
  // delayMatch32..35: 4 stages under enb
  reg [63:0] dm32 [0:3]; reg [3:0] dm33, dm34, dm35;
  integer i;
  always @(posedge clk or posedge reset) begin
    if (reset) begin for (i=0;i<4;i=i+1) dm32[i] <= 64'd0; dm33 <= 4'd0; dm34 <= 4'd0; dm35 <= 4'd0; end
    else if (enb) begin
      dm32[0] <= outWord; dm32[1] <= dm32[0]; dm32[2] <= dm32[1]; dm32[3] <= dm32[2];
      dm33 <= {dm33[2:0], valid}; dm34 <= {dm34[2:0], outLast}; dm35 <= {dm35[2:0], outFirst};
    end
  end
  assign byte_rx_data  = dm32[3];
  assign byte_rx_valid = dm33[3];
  assign byte_rx_last  = dm34[3];
  assign byte_rx_user  = dm35[3];
  assign ovf = ovf_w;
endmodule
