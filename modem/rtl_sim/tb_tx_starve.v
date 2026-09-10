`timescale 1ns/1ps
module tb_tx_starve;
  reg clk=0, resetn=0; always #4 clk=~clk;
  reg valid=0, ready=0;
  wire [31:0] a,b,c,d,e,f,mx,tot;
  tx_starve_witness w(.clk(clk),.resetn(resetn),.valid(valid),.ready(ready),.ep_gt1k(a),.ep_gt2k(b),.ep_gt3k(c),.ep_gt6k(d),.ep_gt12k(e),.ep_gt25k(f),.max_len(mx),.starve_clk(tot));
  task starve(input integer n); begin ready=1; valid=0; repeat(n) @(negedge clk); valid=1; @(negedge clk); valid=0; ready=0; repeat(5) @(negedge clk); end endtask
  initial begin
    #40 resetn=1; #20;
    starve(500); starve(1500); starve(2500); starve(4000); starve(7000); starve(30000);
    #100;
    $display("TXSTARVE gt1k=%0d gt2k=%0d gt3k=%0d gt6k=%0d gt12k=%0d gt25k=%0d max=%0d tot=%0d", a,b,c,d,e,f,mx,tot);
    if (a==5 && b==4 && c==3 && d==2 && e==1 && f==1 && mx==29999 && tot==(4000-3072)+(7000-3072)+(30000-3072)) $display("TXSTARVE_TB_PASS"); else $display("TXSTARVE_TB_FAIL");
    $finish;
  end
endmodule
