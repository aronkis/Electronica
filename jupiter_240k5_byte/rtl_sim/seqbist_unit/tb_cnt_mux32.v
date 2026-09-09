// tb_cnt_mux32 -- slot-mapping check for cnt_mux32.v (SEQ-BIST T0a).
// Drives c<k> = 32'hC0DE0000 + k and sweeps sel 0..31, asserting q == the
// value of the selected input one clock later.  Also instantiates cnt_mux16 on
// the same 16 low inputs and asserts that cnt_mux32 slots 0..15 return exactly
// what cnt_mux16 returns for the same sel (the compatibility requirement for
// the BD swap in Task 2).
`timescale 1ns/1ps
module tb_cnt_mux32;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg  [4:0]  sel = 5'd0;
  wire [31:0] q32, q16;
  integer errors = 0;
  integer k;

  function [31:0] val; input integer n; begin val = 32'hC0DE0000 + n; end endfunction

  cnt_mux32 u32 (.clk(clk), .sel(sel),
    .c0 (val(0)),  .c1 (val(1)),  .c2 (val(2)),  .c3 (val(3)),
    .c4 (val(4)),  .c5 (val(5)),  .c6 (val(6)),  .c7 (val(7)),
    .c8 (val(8)),  .c9 (val(9)),  .c10(val(10)), .c11(val(11)),
    .c12(val(12)), .c13(val(13)), .c14(val(14)), .c15(val(15)),
    .c16(val(16)), .c17(val(17)), .c18(val(18)), .c19(val(19)),
    .c20(val(20)), .c21(val(21)), .c22(val(22)), .c23(val(23)),
    .c24(val(24)), .c25(val(25)), .c26(val(26)), .c27(val(27)),
    .c28(val(28)), .c29(val(29)), .c30(val(30)), .c31(val(31)),
    .q(q32));

  cnt_mux16 u16 (.clk(clk), .sel(sel[3:0]),
    .c0 (val(0)),  .c1 (val(1)),  .c2 (val(2)),  .c3 (val(3)),
    .c4 (val(4)),  .c5 (val(5)),  .c6 (val(6)),  .c7 (val(7)),
    .c8 (val(8)),  .c9 (val(9)),  .c10(val(10)), .c11(val(11)),
    .c12(val(12)), .c13(val(13)), .c14(val(14)), .c15(val(15)),
    .q(q16));

  initial begin
    for (k = 0; k < 32; k = k + 1) begin
      sel = k[4:0];
      @(posedge clk);
      @(posedge clk);           // q is registered
      if (q32 !== val(k)) begin
        errors = errors + 1;
        $display("TB_FAIL cnt_mux32 sel=%0d: got %h want %h", k, q32, val(k));
      end
      if (k < 16 && q32 !== q16) begin
        errors = errors + 1;
        $display("TB_FAIL cnt_mux32 sel=%0d differs from cnt_mux16: %h vs %h",
                 k, q32, q16);
      end
    end
    if (errors == 0) $display("TB_CNT_MUX32_PASS slots=32");
    else             $display("TB_CNT_MUX32_FAIL errors=%0d", errors);
    $finish;
  end

endmodule
