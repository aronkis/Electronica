`timescale 1ns/1ps
// v2 features: word_gap spacing, user_mask, witness counters. dma_ready always 1.
module tb_tgen_rx_v2;
  reg clk=0, resetn=0; always #4 clk=~clk;
  reg [31:0] ctrl=0, gap=0;
  wire [63:0] dd; wire dv, dl, du, dr; wire [31:0] ab, au;
  qpsk_traffic_gen_rx g(.clk(clk),.resetn(resetn),.ctrl(ctrl),.gap(gap),
    .dut_data(64'h0),.dut_valid(1'b0),.dut_last(1'b0),.dut_user(1'b0),.dut_ready(dr),
    .dma_data(dd),.dma_valid(dv),.dma_last(dl),.dma_user(du),.dma_ready(1'b1),
    .acc_beats(ab),.acc_user(au));
  integer t=0, last_t=-1, nb=0, nu=0, mind=1<<30, maxd=0, d, fails=0;
  always @(posedge clk) begin
    t=t+1;
    if (dv) begin
      nb=nb+1; if (du) nu=nu+1;
      if (last_t>=0 && !(nb%191==1)) begin d=t-last_t; if(d<mind) mind=d; if(d>maxd) maxd=d; end
      last_t=t;
    end
  end
  initial begin
    #40 resetn=1;
    // 1) word_gap=100, gap=100, fill 1516, enable: continuous stream, 4 frames
    ctrl = (32'd100<<16) | (32'd1516<<4) | 32'd1; gap=100;
    wait(nb==191*4); #1;
    if (mind != 110 || maxd != 110) begin $display("TGENRX2_WORDGAP_FAIL min=%0d max=%0d", mind, maxd); fails=fails+1; end
    else $display("TGENRX2_WORDGAP_OK min=%0d max=%0d", mind, maxd);
    if (nu != 4) begin $display("TGENRX2_USER_FAIL nu=%0d", nu); fails=fails+1; end
    if (ab != nb || au != nu) begin $display("TGENRX2_COUNTER_FAIL ab=%0d nb=%0d au=%0d nu=%0d", ab, nb, au, nu); fails=fails+1; end
    else $display("TGENRX2_COUNTER_OK beats=%0d user=%0d", ab, au);
    // 2) set user_mask: from now on no user beats reach the DMAC
    ctrl = ctrl | 32'd4;
    wait(nb==191*8); #1;
    if (nu != 4 || au != 4) begin $display("TGENRX2_MASK_FAIL nu=%0d au=%0d", nu, au); fails=fails+1; end
    else $display("TGENRX2_MASK_OK user beats still %0d after 4 more frames", au);
    ctrl = 0; #5000;
    if (fails==0) $display("TGENRX2_TB_PASS"); else $display("TGENRX2_TB_FAIL %0d", fails);
    $finish;
  end
endmodule
