// tb_shadow_align.v -- proves the T8.5 shadow-loop ALIGNMENT INVARIANT on the
// generated netlist: Loop_Filter_Shadow driven by e delayed one enb beat must
// track Loop_Filter_block1's state delayed one enb beat BIT-EXACTLY, on every
// beat, under arbitrary stimulus (including clamp-engaging bursts). Any
// mismatch in functional RTL = overlay wiring bug; zero mismatches = hardware
// nonzeros in shdw_pdiv/idiv are necessarily NON-FUNCTIONAL (physical) events.
//
// Run: iverilog -o align.vvp tb_shadow_align.v <hdlsrc>/Loop_Filter_block1.v \
//        <hdlsrc>/Loop_Filter_Shadow.v && vvp align.vvp
`timescale 1 ns / 1 ns
module tb_shadow_align;
  reg clk=0, reset=1, enb=0;
  reg signed [39:0] e=0, eD=0;
  wire signed [10:0] vP;
  wire signed [29:0] pP, iP, pS, iS;
  reg signed [29:0] pPd=0, iPd=0;

  Loop_Filter_block1 u_prim (.clk(clk), .reset(reset), .enb_1_2_0(enb),
                             .e(e), .v(vP), .stateP(pP), .stateI(iP));
  Loop_Filter_Shadow u_shdw (.clk(clk), .reset(reset), .enb_1_2_0(enb),
                             .e(eD), .stateP(pS), .stateI(iS));

  integer n=0, mism=0;
  reg [31:0] lfsr = 32'hACE1_2026;
  always #5 clk = ~clk;
  always @(posedge clk) enb <= ~enb & ~reset;   // 1-in-2 rate enable, like the fabric

  always @(posedge clk) if (!reset && enb) begin
    n = n + 1;
    // compare: primary state delayed 1 beat vs shadow state (shadow runs on eD)
    if (n > 4) begin
      if (pPd !== pS || iPd !== iS) begin
        mism = mism + 1;
        if (mism < 5)
          $display("MISMATCH beat %0d: pPd=%0d pS=%0d iPd=%0d iS=%0d",
                   n, pPd, pS, iPd, iS);
      end
    end
    pPd <= pP; iPd <= iP;              // 1-beat delay of primary taps
    eD  <= e;                          // 1-beat delay of the shared input
    // stimulus: small noise, huge clamp-engaging bursts, sign flips, zeros
    lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    case (n[13:12])
      2'd0: e <= {{28{lfsr[0]}}, lfsr[11:0]};              // small noise
      2'd1: e <= {lfsr[3], {7{~lfsr[3]}}, lfsr[31:0]};     // huge bursts (clamps engage)
      2'd2: e <= 0;                                        // silence
      2'd3: e <= -{8'b0, lfsr[31:0]};                      // negative ramps
    endcase
    if (n == 99999) begin
      $display("SHADOW_ALIGN beats=%0d mismatches=%0d verdict=%s",
               n, mism, (mism==0) ? "ALIGN_OK" : "ALIGN_BROKEN");
      $finish;
    end
  end

  initial #40 reset = 0;
endmodule
