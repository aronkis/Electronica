// cnt_mux8 -- 8:1 32-bit counter selector for a single read-only GPIO channel (registered).
`timescale 1ns/1ps
module cnt_mux8 (
  input  wire        clk,
  input  wire [3:0]  sel,
  input  wire [31:0] c0, c1, c2, c3, c4, c5, c6, c7,
  output reg  [31:0] q
);
  always @(posedge clk) case (sel[2:0])
    3'd0: q <= c0; 3'd1: q <= c1; 3'd2: q <= c2; 3'd3: q <= c3;
    3'd4: q <= c4; 3'd5: q <= c5; 3'd6: q <= c6; default: q <= c7;
  endcase
endmodule
