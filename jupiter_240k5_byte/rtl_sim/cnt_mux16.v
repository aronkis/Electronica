// cnt_mux16 -- 16:1 32-bit counter selector for a single read-only GPIO channel (registered).
`timescale 1ns/1ps
module cnt_mux16 (
  input  wire        clk,
  input  wire [3:0]  sel,
  input  wire [31:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15,
  output reg  [31:0] q
);
  always @(posedge clk) case (sel)
    4'd0: q <= c0;  4'd1: q <= c1;  4'd2: q <= c2;  4'd3: q <= c3;
    4'd4: q <= c4;  4'd5: q <= c5;  4'd6: q <= c6;  4'd7: q <= c7;
    4'd8: q <= c8;  4'd9: q <= c9;  4'd10: q <= c10; 4'd11: q <= c11;
    4'd12: q <= c12; 4'd13: q <= c13; 4'd14: q <= c14; default: q <= c15;
  endcase
endmodule
