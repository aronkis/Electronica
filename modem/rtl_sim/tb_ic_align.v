// tb_ic_align.v -- T8.6.3 IC shadow alignment proof on the generated netlist:
// Interpolation_Control_Shadow driven by Delta delayed one enb beat must
// track the primary's mu/Underflow delayed one beat BIT-EXACTLY (the shadow
// carries the +1/8 countReg init compensating its extra leading beat).
// Run: iverilog -o ic.vvp tb_ic_align.v <hdl>/Interpolation_Control.v \
//        <hdl>/<shadow-module>.v && vvp ic.vvp
`timescale 1 ns / 1 ns
module tb_ic_align;
  reg clk=0, reset=1, enb=0;
  reg signed [10:0] d=0, dD=0;
  wire signed [10:0] muP, muS;
  wire undP, undS;
  reg signed [10:0] muPd=0;
  reg undPd=0;

  Interpolation_Control        u_p (.clk(clk), .reset(reset), .enb_1_2_0(enb),
                                    .Delta(d),  .mu(muP), .Underflow(undP));
  Interpolation_Control_Shadow u_s (.clk(clk), .reset(reset), .enb_1_2_0(enb),
                                    .Delta(dD), .mu(muS), .Underflow(undS));

  integer n=0, mism=0;
  reg [31:0] lfsr = 32'hC0FFEE11;
  always #5 clk = ~clk;
  always @(posedge clk) enb <= ~enb & ~reset;

  always @(posedge clk) if (!reset && enb) begin
    n = n + 1;
    if (n > 4) begin
      if (muPd !== muS || undPd !== undS) begin
        mism = mism + 1;
        if (mism < 5)
          $display("MISMATCH beat %0d: muPd=%0d muS=%0d undPd=%b undS=%b", n, muPd, muS, undPd, undS);
      end
    end
    muPd <= muP; undPd <= undP;
    dD <= d;
    lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    case (n[13:12])
      2'd0: d <= {{7{lfsr[0]}}, lfsr[3:0]};        // small noise
      2'd1: d <= {lfsr[5], {10{~lfsr[5]}}};        // clamp-scale extremes
      2'd2: d <= 0;
      2'd3: d <= -{4'b0, lfsr[6:0]};
    endcase
    if (n == 99999) begin
      $display("IC_ALIGN beats=%0d mismatches=%0d verdict=%s",
               n, mism, (mism==0) ? "ALIGN_OK" : "ALIGN_BROKEN");
      $finish;
    end
  end

  initial #40 reset = 0;
endmodule
