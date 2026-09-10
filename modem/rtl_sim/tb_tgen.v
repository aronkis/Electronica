`timescale 1ns/1ps
module tb_tgen;
  reg clk=0, resetn=0; always #4 clk=~clk;           // 8 ns
  reg [31:0] ctrl=0, gap=0;
  reg [63:0] hd=64'hDEAD_DEAD_DEAD_DEAD; reg hv=0, hf=0;
  wire hr; wire [63:0] dd; wire dv, df; reg dr=1;
  integer corrupt; integer fd; integer nby; integer i, fcnt, stall;
  integer stall_hits; integer ferr;
  reg [7:0] mem [0:6*1528-1];

  // phase gates which leg's capture/monitor logic is live:
  // 0=idle/setup, 1=golden legs (6 frames, byte-compared), 2=gap-timing leg,
  // 3=pass-through leg
  integer phase;
  integer cyc;                       // free-running cycle counter (timestamps)
  reg     gen_watch;                 // 1 while a generate leg expects host_ready==0
  integer genmismatch;               // host_ready!=0 while gen_watch asserted

  // Finding 1 (gap-timing leg): nonzero gap must produce >= gap cycles of
  // inter-frame spacing, and frame content must still byte-match golden.
  reg [7:0] gap_mem [0:2*1528-1];
  integer gnby, t_last0, t_first1, gap_spacing, gap_fail;

  // Finding 2 (pass-through leg): en=0 must mirror host pins onto dut pins
  // exactly, and host_ready must mirror dut_ready (including dr stalls).
  integer ptmismatch, pt_words;

  qpsk_traffic_gen dut(.clk(clk), .resetn(resetn), .ctrl(ctrl), .gap(gap),
    .host_data(hd), .host_valid(hv), .host_first(hf), .host_ready(hr),
    .dut_data(dd), .dut_valid(dv), .dut_first(df), .dut_ready(dr));

  // free-running cycle counter, used only for gap-spacing timestamps
  always @(posedge clk) cyc = cyc + 1;

  // adversarial ready stalls -- unconditional so they stay active across
  // every leg (golden, gap, pass-through), never just the golden legs
  always @(posedge clk) begin
    stall = stall + 1;
    dr <= !(stall % 13 == 0);                        // 1-in-13 stall cycles
  end

  // host_ready must be held 0 for the whole time a generate leg has told us
  // (via gen_watch) that it expects generate mode to be stably active
  always @(posedge clk) if (gen_watch && hr !== 1'b0) genmismatch = genmismatch + 1;

  // capture accepted words into mem during the golden legs (phase==1) only
  always @(posedge clk) begin
    if (phase == 1 && dv && !dr) stall_hits = stall_hits + 1;   // backpressure applied
    if (phase == 1 && dv && dr) begin
      if (df !== ((nby % 1528) == 0)) begin
        $display("TGEN_TB_FIRST_ERR nby=%0d df=%b", nby, df);
        ferr = ferr + 1;
      end
      for (i = 0; i < 8; i = i + 1)
        mem[nby + i] = dd[8*i +: 8];
      nby = nby + 8;
    end
  end

  // capture accepted words + frame-boundary timestamps during the gap leg
  // (phase==2) only
  always @(posedge clk) begin
    if (phase == 2 && dv && dr) begin
      for (i = 0; i < 8; i = i + 1)
        gap_mem[gnby + i] = dd[8*i +: 8];
      if (gnby == 1520) t_last0  = cyc;   // last word of frame 0 (bytes 1520..1527)
      if (gnby == 1528) t_first1 = cyc;   // first word of frame 1
      gnby = gnby + 8;
    end
  end

  task run_frames(input [11:0] fill, input integer n);
    integer target;
    begin
      target = nby + n*1528;
      ctrl = 32'b0; ctrl[15:4] = fill; ctrl[0] = 1;  // explicit field writes
      repeat (4) @(posedge clk); gen_watch = 1;       // settle, then watch host_ready
      wait (nby >= target);
      ctrl[0] = 0; gen_watch = 0;                     // completes current frame
      repeat (2000) @(posedge clk);
      // full re-arm so seq restarts at 1 for the next fill setting
      resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    end
  endtask

  // Finding 1: nonzero-gap leg. fill/n reuse the existing golden_s{1,2}_f1516
  // content (seq restarts at 1 via the prior leg's re-arm), so no new golden
  // files are needed -- only the inter-frame timing is novel here.
  task run_gap_frames(input [11:0] fill, input integer n, input [31:0] gapval);
    integer target;
    begin
      gap = gapval;
      gnby = 0; t_last0 = -1; t_first1 = -1; gap_fail = 0;
      target = n*1528;
      ctrl = 32'b0; ctrl[15:4] = fill; ctrl[0] = 1;
      repeat (4) @(posedge clk); gen_watch = 1;
      wait (gnby >= target);
      ctrl[0] = 0; gen_watch = 0;
      repeat (2000) @(posedge clk);
      resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
      gap = 32'd0;
      // bound the check against the actual argument, not a hardcoded literal,
      // so a future call with a different gapval stays a real assertion
      if (t_last0 < 0 || t_first1 < 0) begin
        $display("TGEN_TB_GAP_TIMESTAMP_MISSING");
        gap_fail = 1;
      end else begin
        gap_spacing = t_first1 - t_last0;
        if (gap_spacing < gapval || gap_spacing > gapval + 200) gap_fail = 1;
      end
    end
  endtask

  // Finding 2: pass-through leg (en=0). Drives a known host pattern with
  // valid gaps and checks the dut_* pins mirror it exactly every cycle, and
  // that host_ready mirrors dut_ready (which keeps stalling via dr above).
  task run_passthrough(input integer nwords);
    integer k;
    begin
      ctrl = 32'b0;                      // en=0: pass-through
      hv = 0; hf = 0; hd = 64'h0;
      repeat (4) @(posedge clk);
      for (k = 0; k < nwords; k = k + 1) begin
        hv = !(k % 7 == 3);              // include valid gaps
        hf = (k == 0);
        hd = {32'hA5A5A5A5, k[31:0]};
        @(posedge clk);
        if (dd !== hd || dv !== hv || df !== hf || hr !== dr)
          ptmismatch = ptmismatch + 1;
      end
      hv = 0; hf = 0;
      pt_words = nwords;
    end
  endtask

  initial begin
    corrupt = 0; i = $value$plusargs("corrupt=%d", corrupt);
    nby = 0; stall = 0; fcnt = 0; stall_hits = 0; ferr = 0;
    cyc = 0; phase = 0; gen_watch = 0; genmismatch = 0;
    gnby = 0; t_last0 = -1; t_first1 = -1; gap_spacing = -1;
    ptmismatch = 0; pt_words = 0;
    repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);

    // --- golden legs: byte-exact compare against golden_all.bin ---
    phase = 1;
    run_frames(12'd1516, 4);                         // frames seq 1..4 @1516
    run_frames(12'd100, 1);                          // frame seq 1 @100
    run_frames(12'd0, 1);                             // frame seq 1 @0
    if (corrupt) mem[2*1528 + 700] = mem[2*1528 + 700] ^ 8'h01;
    fd = $fopen("tb_frames.bin", "wb");
    for (i = 0; i < nby; i = i + 1) $fwrite(fd, "%c", mem[i]);
    $fclose(fd);
    $display("TB_CAPTURED bytes=%0d frames=%0d", nby, nby/1528);
    $display("TB_STALL_HITS %0d", stall_hits);
    if (stall_hits == 0) $display("TGEN_TB_NO_STALL");
    $display("TB_FIRST_ERR %0d", ferr);
    if (ferr != 0) $display("TGEN_TB_FIRST_ERR_COUNT %0d", ferr);

    // --- Finding 1: gap-timing leg ---
    phase = 2;
    run_gap_frames(12'd1516, 2, 32'd500);
    phase = 0;
    fd = $fopen("tb_gap_frames.bin", "wb");
    for (i = 0; i < gnby; i = i + 1) $fwrite(fd, "%c", gap_mem[i]);
    $fclose(fd);
    $display("TB_GAP_BYTES %0d", gnby);
    $display("TB_GAP_SPACING %0d", gap_spacing);
    if (gap_fail) $display("TGEN_TB_GAP_SPACING_FAIL");

    // --- Finding 2: pass-through leg ---
    phase = 3;
    run_passthrough(300);
    $display("TB_PASSTHRU_WORDS %0d", pt_words);
    $display("TB_PASSTHRU_MISMATCH %0d", ptmismatch);
    if (ptmismatch != 0) $display("TGEN_TB_PASSTHRU_FAIL");

    $display("TB_GEN_HOSTREADY_MISMATCH %0d", genmismatch);
    if (genmismatch != 0) $display("TGEN_TB_HOSTREADY_FAIL genmismatch=%0d", genmismatch);

    $finish;
  end
endmodule
