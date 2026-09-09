// tx_starve_witness -- snoop-only input-starvation witness at the DUT TX byte-in pins.
// The DUT raises byte_ready when its ByteWordBuffer wants data (count <= 6). An episode
// = consecutive clks with ready=1 && valid=0 (DUT wants a word, the host/MM2S has none).
// The modulator consumes one 64-bit word every ~512 clk at line rate, and the buffer's
// usable cover is ~6 words, so episodes longer than ~3000 clk starve the buffer
// (netlist: garbage-header air frame). Histogram of episode lengths + max + total.
`timescale 1ns/1ps
module tx_starve_witness (
  input  wire        clk,
  input  wire        resetn,
  input  wire        valid,     // DUT dut_byte_valid_in (host -> DUT)
  input  wire        ready,     // DUT dut_byte_ready_out (DUT -> host)
  output reg  [31:0] ep_gt1k,   // episodes > 1024 clk (8.3 us)
  output reg  [31:0] ep_gt2k,   // > 2048 (16.7 us)
  output reg  [31:0] ep_gt3k,   // > 3072 (25 us)  ~ starvation threshold
  output reg  [31:0] ep_gt6k,   // > 6144 (50 us)
  output reg  [31:0] ep_gt12k,  // > 12288 (100 us)
  output reg  [31:0] ep_gt25k,  // > 24576 (200 us)
  output reg  [31:0] max_len,   // longest episode (clk)
  output reg  [31:0] starve_clk // total clks in episodes > 3072
);
  reg [31:0] len;
  wire starving = ready && !valid;
  always @(posedge clk) begin
    if (!resetn) begin
      ep_gt1k <= 0; ep_gt2k <= 0; ep_gt3k <= 0; ep_gt6k <= 0; ep_gt12k <= 0; ep_gt25k <= 0;
      max_len <= 0; starve_clk <= 0; len <= 0;
    end else if (starving) begin
      len <= len + 1;
      if (len == 32'd1024)  ep_gt1k  <= ep_gt1k  + 1;
      if (len == 32'd2048)  ep_gt2k  <= ep_gt2k  + 1;
      if (len == 32'd3072)  ep_gt3k  <= ep_gt3k  + 1;
      if (len == 32'd6144)  ep_gt6k  <= ep_gt6k  + 1;
      if (len == 32'd12288) ep_gt12k <= ep_gt12k + 1;
      if (len == 32'd24576) ep_gt25k <= ep_gt25k + 1;
      if (len >= 32'd3072)  starve_clk <= starve_clk + 1;
      if (len > max_len)    max_len <= len;
    end else begin
      len <= 0;
    end
  end
endmodule
