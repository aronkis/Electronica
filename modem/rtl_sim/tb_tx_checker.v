// tb_tx_checker -- build gate for tx_seam_checker.
// Legs: (A) continuous-valid golden frames -> bit_errors==0, frames_checked==N;
// (B) gapped-valid (9-clk word cadence, the TX-seam generator's bubble) ->
//     identical result (the checker counts ACCEPTED beats; cadence-agnostic);
// (C) planted corruption -> exact popcount detected (positive control);
// (D) non-TGEN frames skipped (frames_checked unchanged);
// (E) ready-stall robustness (adversarial ready during both legs).
`timescale 1ns/1ps
module tb_tx_checker;
  reg clk=0, resetn=0; always #4 clk=~clk;
  reg [63:0] d=0; reg v=0, f=0; reg r=1;
  wire [31:0] be, fc;
  integer i, w, stall, fails;
  reg [7:0] frame [0:1527];
  integer corrupt_bits;

  tx_seam_checker dut(.clk(clk), .resetn(resetn),
    .data(d), .valid(v), .first(f), .ready(r),
    .bit_errors(be), .frames_checked(fc));

  always @(posedge clk) begin stall = stall + 1; r <= !(stall % 13 == 0); end

  // build a tgen-format frame into `frame`
  task build_frame(input [31:0] seq, input [11:0] fill);
    reg [31:0] x; integer bi;
    begin
      for (bi = 0; bi < 1528; bi = bi + 1) frame[bi] = 8'h00;
      frame[0]=8'h51; frame[1]=8'h4B;
      frame[2]=fill[7:0]; frame[3]={4'b0,fill[11:8]};
      frame[4]=seq[7:0]; frame[5]=seq[15:8]; frame[6]=seq[23:16]; frame[7]=seq[31:24];
      frame[8]=8'h21; frame[9]=8'h4E; frame[10]=8'h47; frame[11]=8'h54;
      x = seq ^ 32'h9E3779B9; if (x==0) x=32'hDEADBEEF;
      for (bi = 0; bi < fill; bi = bi + 1) begin
        x = x ^ (x<<13); x = x ^ (x>>17); x = x ^ (x<<5);
        frame[12+bi] = x[7:0];
      end
    end
  endtask

  // drive one frame; bubble = idle clks between words (0 = continuous)
  task send_frame(input integer bubble);
    integer wi, k; reg accepted;
    begin
      for (wi = 0; wi < 191; wi = wi + 1) begin
        @(negedge clk);
        for (k = 0; k < 8; k = k + 1) d[8*k +: 8] = frame[wi*8 + k];
        f = (wi == 0); v = 1;
        accepted = 0;
        while (!accepted) begin @(posedge clk); if (r) accepted = 1; end
        @(negedge clk); v = 0; f = 0;
        for (k = 0; k < bubble; k = k + 1) @(posedge clk);
      end
    end
  endtask

  initial begin
    fails = 0; stall = 0;
    repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);

    // Leg A: 4 continuous-valid golden frames (mixed fills)
    build_frame(32'd1, 12'd1516); send_frame(0);
    build_frame(32'd2, 12'd1516); send_frame(0);
    build_frame(32'd3, 12'd100);  send_frame(0);
    build_frame(32'd4, 12'd0);    send_frame(0);
    repeat (4) @(posedge clk);
    if (be !== 32'd0 || fc !== 32'd4) begin
      $display("TXCHK_TB_LEGA_FAIL be=%0d fc=%0d", be, fc); fails = fails + 1;
    end else $display("TXCHK_LEGA_OK fc=%0d be=%0d", fc, be);

    // Leg B: gapped-valid (9-clk bubble) golden frames
    build_frame(32'd5, 12'd1516); send_frame(9);
    build_frame(32'd6, 12'd700);  send_frame(9);
    repeat (4) @(posedge clk);
    if (be !== 32'd0 || fc !== 32'd6) begin
      $display("TXCHK_TB_LEGB_FAIL be=%0d fc=%0d", be, fc); fails = fails + 1;
    end else $display("TXCHK_LEGB_OK fc=%0d be=%0d", fc, be);

    // Leg C: planted corruption -- flip 3 payload bits, expect be==3
    build_frame(32'd7, 12'd1516);
    frame[100] = frame[100] ^ 8'h01;
    frame[500] = frame[500] ^ 8'h10;
    frame[1400] = frame[1400] ^ 8'h80;
    send_frame(0);
    repeat (4) @(posedge clk);
    if (be !== 32'd3 || fc !== 32'd7) begin
      $display("TXCHK_TB_LEGC_FAIL be=%0d fc=%0d (want 3,7)", be, fc); fails = fails + 1;
    end else $display("TXCHK_LEGC_OK planted=3 counted=%0d", be);

    // Leg D: non-TGEN frame (bad magic) skipped whole
    build_frame(32'd8, 12'd1516); frame[0] = 8'hAA;
    send_frame(0);
    repeat (4) @(posedge clk);
    if (fc !== 32'd7) begin
      $display("TXCHK_TB_LEGD_FAIL fc=%0d (want 7)", fc); fails = fails + 1;
    end else $display("TXCHK_LEGD_OK skipped");

    // Leg E: one more clean frame after the skip (re-arm)
    build_frame(32'd9, 12'd1516); send_frame(3);
    repeat (4) @(posedge clk);
    if (be !== 32'd3 || fc !== 32'd8) begin
      $display("TXCHK_TB_LEGE_FAIL be=%0d fc=%0d (want 3,8)", be, fc); fails = fails + 1;
    end else $display("TXCHK_LEGE_OK");

    if (fails == 0) $display("TXCHK_TB_PASS");
    else $display("TXCHK_TB_FAIL n=%0d", fails);
    $finish;
  end
endmodule
