// tb_timing_wedge.v -- WEDGE PROOF testbench for the symbol-timing loop:
// drives Loop_Filter_block1 (timing PI filter) + Interpolation_Control (Rice
// mod-1 counter) exactly as wired in Symbol_Synchronizer, and shows that a
// poisoned integrator stops Underflow strobes FOREVER on the un-hardened
// design (Class-4 wedge / Class-1 transient), while the hardened design
// (integrator clamp + saturating output conversion) recovers.
//
// Phases:
//   P1 0..2999      : e=0 baseline           -> expect nominal strobes (1/8)
//   P2 3000..3999   : e = large NEGATIVE     -> integrator ramps deep negative
//   P3 4000..59999  : e=0 (TED silent: the observed no-strobe deadlock input)
//                     UNHARDENED: Delta stuck <= -0.125 -> ZERO strobes
//                     HARDENED:   strobes resume, cadence re-nominalizes
// Verdict line: WEDGE_TB strobes_P1=<n> strobes_P3=<n> verdict=<WEDGED|RECOVERED>
//
// Run: iverilog -o wedge.vvp tb_timing_wedge.v <hdl>/TxRxCompo_ip_src_Loop_Filter_block1.v \
//        <hdl>/TxRxCompo_ip_src_Interpolation_Control.v && vvp wedge.vvp
`timescale 1 ns / 1 ns
module tb_timing_wedge;
  reg clk=0, reset=1, enb=1;
  reg signed [39:0] e=0;              // sfix40_En24 TED error input
  wire signed [10:0] delta;           // sfix11_En10 loop filter out
  wire signed [10:0] mu;
  wire underflow;

  TxRxCompo_ip_src_Loop_Filter_block1 u_lf (
    .clk(clk), .reset(reset), .enb_1_2_0(enb), .e(e), .v(delta));
  TxRxCompo_ip_src_Interpolation_Control u_ic (
    .clk(clk), .reset(reset), .enb_1_2_0(enb), .Delta(delta), .mu(mu), .Underflow(underflow));

  integer n=0, s1=0, s3=0;
  always #5 clk = ~clk;

  always @(posedge clk) if (!reset) begin
    n = n + 1;
    if (n < 3000) begin
      e <= 0;
      if (underflow) s1 = s1 + 1;
    end else if (n < 4000) begin
      // poison: large negative TED error burst; K2 integrates it deep negative
      e <= -40'sd549755813888;        // -2^39/16 = large negative En24 value
    end else begin
      e <= 0;                          // TED silent -- the deadlock condition
      if (underflow) s3 = s3 + 1;
    end
    if (n == 59999) begin
      $display("WEDGE_TB strobes_P1=%0d strobes_P3=%0d delta_final=%0d verdict=%s",
               s1, s3, delta, (s3 < 100) ? "WEDGED" : "RECOVERED");
      $finish;
    end
  end

  initial begin
    #40 reset = 0;
  end
endmodule
