`timescale 1ns/1ps
module tb_rx_seam_checker;
  reg clk=0, resetn=0; always #4 clk=~clk;
  reg [63:0] mem [0:8*191-1]; reg [63:0] data=0; reg valid=0, user=0, ready=1;
  wire [31:0] frames, crc_ok, crc_fail, magic_bad, short_frm, orphan_w;
  rx_seam_checker c(.clk(clk),.resetn(resetn),.data(data),.valid(valid),.user(user),.ready(ready),
    .frames(frames),.crc_ok(crc_ok),.crc_fail(crc_fail),.magic_bad(magic_bad),.short_frm(short_frm),.orphan_w(orphan_w));
  integer f,w,g; integer fails=0;
  task send(input integer fi, input integer nwords, input integer gap);
    begin for (w=0; w<nwords; w=w+1) begin
      @(negedge clk); data=mem[fi*191+w]; valid=1; user=(w==0); ready=1;
      @(negedge clk); valid=0; user=0; repeat(gap) @(negedge clk); end end
  endtask
  initial begin
    $readmemh("rxchk_frames.hex", mem);
    #40 resetn=1; #20;
    for (f=0; f<8; f=f+1) send(f, 191, (f%3==0)?0:5);
    send(0, 100, 2);                                          // short frame (100 words) then next user
    send(1, 191, 0);
    @(negedge clk); data=64'h1; valid=1; user=0; @(negedge clk); valid=0;  // orphan word
    repeat(10) @(negedge clk);
    $display("RXCHK frames=%0d crc_ok=%0d crc_fail=%0d magic_bad=%0d short=%0d orphan=%0d", frames, crc_ok, crc_fail, magic_bad, short_frm, orphan_w);
    if (frames!=10 || crc_ok!=7 || crc_fail!=1 || magic_bad!=1 || short_frm!=1 || orphan_w!=1) begin $display("RXCHK_TB_FAIL"); end else $display("RXCHK_TB_PASS");
    $finish;
  end
endmodule
