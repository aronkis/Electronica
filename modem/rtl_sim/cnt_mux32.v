// cnt_mux32 -- 32:1 32-bit counter selector for a single read-only GPIO channel
// (registered).  Drop-in superset of cnt_mux16: slots 0..15 keep the existing
// meaning and wiring (0 acc_user, 1 frames, 2 crc_ok, 3 crc_fail, 4 magic_bad,
// 5 short, 6 orphan, 7 acc_beats, 8..15 tx_starve_witness), slots 16..31 are
// the new rx_seq_checker outputs cnt0..cnt15 in order.
//
// sel comes from tgen_rx_ctrl_gpio gap word bits [31:27] @0x9D410008 (one bit
// wider than cnt_mux16's [31:28]); the output is tgen_rx_wit_gpio ch2
// @0x9D450008.
`timescale 1ns/1ps
module cnt_mux32 (
  input  wire        clk,
  input  wire [4:0]  sel,
  input  wire [31:0] c0,  c1,  c2,  c3,  c4,  c5,  c6,  c7,
  input  wire [31:0] c8,  c9,  c10, c11, c12, c13, c14, c15,
  input  wire [31:0] c16, c17, c18, c19, c20, c21, c22, c23,
  input  wire [31:0] c24, c25, c26, c27, c28, c29, c30, c31,
  output reg  [31:0] q
);
  always @(posedge clk) case (sel)
    5'd0:  q <= c0;   5'd1:  q <= c1;   5'd2:  q <= c2;   5'd3:  q <= c3;
    5'd4:  q <= c4;   5'd5:  q <= c5;   5'd6:  q <= c6;   5'd7:  q <= c7;
    5'd8:  q <= c8;   5'd9:  q <= c9;   5'd10: q <= c10;  5'd11: q <= c11;
    5'd12: q <= c12;  5'd13: q <= c13;  5'd14: q <= c14;  5'd15: q <= c15;
    5'd16: q <= c16;  5'd17: q <= c17;  5'd18: q <= c18;  5'd19: q <= c19;
    5'd20: q <= c20;  5'd21: q <= c21;  5'd22: q <= c22;  5'd23: q <= c23;
    5'd24: q <= c24;  5'd25: q <= c25;  5'd26: q <= c26;  5'd27: q <= c27;
    5'd28: q <= c28;  5'd29: q <= c29;  5'd30: q <= c30;  default: q <= c31;
  endcase
endmodule
