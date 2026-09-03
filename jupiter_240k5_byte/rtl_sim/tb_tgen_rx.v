// tb_tgen_rx -- build gate for qpsk_traffic_gen_rx (RX-seam injector).
// Clone of tb_tgen adapted to the RX-seam port set: generate legs byte-compare
// against the SAME golden_all.bin (frame content contract is shared with the
// TX-seam generator), plus RX-specific assertions: dma_last on word 190 only,
// dma_user==0 while generating, dut_ready held 0 while generating, and the
// pass-through leg mirrors {data,valid,last,user} forward and ready back.
`timescale 1ns/1ps
module tb_tgen_rx;
  reg clk=0, resetn=0; always #4 clk=~clk;           // 8 ns
  reg [31:0] ctrl=0, gap=0;
  reg [63:0] ud=64'hDEAD_DEAD_DEAD_DEAD; reg uv=0, ul=0, uu=0;
  wire ur; wire [63:0] dd; wire dv, dl, du; reg dr=1;
  integer corrupt; integer fd; integer nby; integer i, stall;
  integer stall_hits; integer lerr, uerr;
  reg [7:0] mem [0:6*1528-1];

  integer phase;                     // 0=idle 1=golden 2=gap 3=pass-through
  integer cyc;
  reg     gen_watch;                 // 1 while a generate leg expects dut_ready==0
  integer genmismatch;

  reg [7:0] gap_mem [0:2*1528-1];
  integer gnby, t_last0, t_first1, gap_spacing, gap_fail;

  integer ptmismatch, pt_words;
  integer lastoff_viol, lastoff_words;

  qpsk_traffic_gen_rx dut(.clk(clk), .resetn(resetn), .ctrl(ctrl), .gap(gap),
    .dut_data(ud), .dut_valid(uv), .dut_last(ul), .dut_user(uu), .dut_ready(ur),
    .dma_data(dd), .dma_valid(dv), .dma_last(dl), .dma_user(du), .dma_ready(dr));

  always @(posedge clk) cyc = cyc + 1;

  // adversarial downstream (DMA-side) ready stalls, live across all legs
  always @(posedge clk) begin
    stall = stall + 1;
    dr <= !(stall % 13 == 0);
  end

  // consume-and-discard: dut_ready must be held HIGH the whole time generate
  // mode is stably active (DUT drains at natural cadence, words dropped at seam)
  always @(posedge clk) if (gen_watch && ur !== 1'b1) genmismatch = genmismatch + 1;
  // and no upstream (DUT) word may ever leak into the DMA stream while generating:
  // drive a poisoned upstream pattern during generate legs and flag any leak
  integer leak; initial leak = 0;
  always @(posedge clk) if (gen_watch && dv && dr && dd === 64'hBAD0BAD0BAD0BAD0) leak = leak + 1;

  // golden-leg capture: accepted words; last must fire exactly on word 190;
  // user must be 0 throughout generation
  always @(posedge clk) begin
    if (phase == 1 && dv && !dr) stall_hits = stall_hits + 1;
    if (phase == 1 && dv && dr && dd !== 64'hBAD0BAD0BAD0BAD0) begin
      if (dl !== ((nby % 1528) == 1520)) begin
        $display("TGENRX_TB_LAST_ERR nby=%0d dl=%b", nby, dl);
        lerr = lerr + 1;
      end
      if (du !== ((nby % 1528) == 0)) uerr = uerr + 1;   // tuser on word 0 only
      for (i = 0; i < 8; i = i + 1)
        mem[nby + i] = dd[8*i +: 8];
      nby = nby + 8;
    end
  end

  always @(posedge clk) begin
    if (phase == 2 && dv && dr && dd !== 64'hBAD0BAD0BAD0BAD0) begin
      for (i = 0; i < 8; i = i + 1)
        gap_mem[gnby + i] = dd[8*i +: 8];
      if (gnby == 1520) t_last0  = cyc;
      if (gnby == 1528) t_first1 = cyc;
      gnby = gnby + 8;
    end
  end

  task run_frames(input [11:0] fill, input integer n);
    integer target;
    begin
      target = nby + n*1528;
      ud = 64'hBAD0BAD0BAD0BAD0; uv = 1;    // poisoned DUT stream, must be discarded
      ctrl = 32'b0; ctrl[15:4] = fill; ctrl[1] = 1; ctrl[0] = 1;  // last_en ON for golden legs
      repeat (4) @(posedge clk); gen_watch = 1;
      wait (nby >= target);
      ctrl[0] = 0; gen_watch = 0; uv = 0;
      repeat (2000) @(posedge clk);
      resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    end
  endtask

  task run_gap_frames(input [11:0] fill, input integer n, input [31:0] gapval);
    integer target;
    begin
      gap = gapval;
      gnby = 0; t_last0 = -1; t_first1 = -1; gap_fail = 0;
      target = n*1528;
      ud = 64'hBAD0BAD0BAD0BAD0; uv = 1;    // poisoned DUT stream, must be discarded
      ctrl = 32'b0; ctrl[15:4] = fill; ctrl[1] = 1; ctrl[0] = 1;
      repeat (4) @(posedge clk); gen_watch = 1;
      wait (gnby >= target);
      ctrl[0] = 0; gen_watch = 0; uv = 0;
      repeat (2000) @(posedge clk);
      resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
      gap = 32'd0;
      if (t_last0 < 0 || t_first1 < 0) begin
        $display("TGENRX_TB_GAP_TIMESTAMP_MISSING");
        gap_fail = 1;
      end else begin
        gap_spacing = t_first1 - t_last0;
        if (gap_spacing < gapval || gap_spacing > gapval + 200) gap_fail = 1;
      end
    end
  endtask

  // pass-through: en=0 mirrors upstream {data,valid,last,user} onto the dma
  // pins exactly, and dut_ready mirrors dma_ready (incl. dr stalls)
  task run_passthrough(input integer nwords);
    integer k;
    begin
      ctrl = 32'b0;
      uv = 0; ul = 0; uu = 0; ud = 64'h0;
      repeat (4) @(posedge clk);
      for (k = 0; k < nwords; k = k + 1) begin
        uv = !(k % 7 == 3);
        ul = (k % 191 == 190);
        uu = (k % 5 == 1);
        ud = {32'hA5A5A5A5, k[31:0]};
        @(posedge clk);
        if (dd !== ud || dv !== uv || dl !== ul || du !== uu || ur !== dr)
          ptmismatch = ptmismatch + 1;
      end
      uv = 0; ul = 0; uu = 0;
      pt_words = nwords;
    end
  endtask

  initial begin
    corrupt = 0; i = $value$plusargs("corrupt=%d", corrupt);
    nby = 0; stall = 0; stall_hits = 0; lerr = 0; uerr = 0;
    cyc = 0; phase = 0; gen_watch = 0; genmismatch = 0;
    gnby = 0; t_last0 = -1; t_first1 = -1; gap_spacing = -1;
    ptmismatch = 0; pt_words = 0;
    repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);

    // --- golden legs: byte-exact compare against golden_all.bin ---
    phase = 1;
    run_frames(12'd1516, 4);
    run_frames(12'd100, 1);
    run_frames(12'd0, 1);
    if (corrupt) mem[2*1528 + 700] = mem[2*1528 + 700] ^ 8'h01;
    fd = $fopen("tb_rx_frames.bin", "wb");
    for (i = 0; i < nby; i = i + 1) $fwrite(fd, "%c", mem[i]);
    $fclose(fd);
    $display("TB_CAPTURED bytes=%0d frames=%0d", nby, nby/1528);
    $display("TB_STALL_HITS %0d", stall_hits);
    if (stall_hits == 0) $display("TGENRX_TB_NO_STALL");
    $display("TB_LAST_ERR %0d", lerr);
    if (lerr != 0) $display("TGENRX_TB_LAST_ERR_COUNT %0d", lerr);
    $display("TB_USER_ERR %0d", uerr);
    if (uerr != 0) $display("TGENRX_TB_USER_FAIL %0d", uerr);

    // --- last_en default-off leg (silicon S2MM finding): dma_last must stay 0 ---
    phase = 4; lastoff_viol = 0; lastoff_words = 0;
    ctrl = 32'b0; ctrl[15:4] = 12'd1516; ctrl[0] = 1;   // ctrl[1]=0
    repeat (4) @(posedge clk);
    begin : lastoff_leg
      integer w;
      for (w = 0; w < 6000; w = w + 1) begin
        @(posedge clk);
        if (dv && dr) begin
          lastoff_words = lastoff_words + 1;
          if (dl !== 1'b0) lastoff_viol = lastoff_viol + 1;
        end
      end
    end
    ctrl = 32'b0;
    repeat (2000) @(posedge clk);
    resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    $display("TB_LASTOFF_WORDS %0d", lastoff_words);
    $display("TB_LASTOFF_VIOL %0d", lastoff_viol);
    if (lastoff_words < 382) $display("TGENRX_TB_LASTOFF_NO_DATA");
    if (lastoff_viol != 0) $display("TGENRX_TB_LASTOFF_FAIL %0d", lastoff_viol);

    // --- gap-timing leg ---
    phase = 2;
    run_gap_frames(12'd1516, 2, 32'd500);
    phase = 0;
    fd = $fopen("tb_rx_gap_frames.bin", "wb");
    for (i = 0; i < gnby; i = i + 1) $fwrite(fd, "%c", gap_mem[i]);
    $fclose(fd);
    $display("TB_GAP_BYTES %0d", gnby);
    $display("TB_GAP_SPACING %0d", gap_spacing);
    if (gap_fail) $display("TGENRX_TB_GAP_SPACING_FAIL");

    // --- pass-through leg ---
    phase = 3;
    run_passthrough(500);
    $display("TB_PASSTHRU_WORDS %0d", pt_words);
    $display("TB_PASSTHRU_MISMATCH %0d", ptmismatch);
    if (ptmismatch != 0) $display("TGENRX_TB_PASSTHRU_FAIL");

    $display("TB_GEN_DUTREADY_MISMATCH %0d", genmismatch);
    if (genmismatch != 0) $display("TGENRX_TB_DUTREADY_FAIL genmismatch=%0d", genmismatch);
    $display("TB_GEN_LEAK %0d", leak);
    if (leak != 0) $display("TGENRX_TB_LEAK_FAIL %0d", leak);

    $finish;
  end
endmodule
