// tb_bs_census.v -- [sim] Task 46: the unit gate for bs_seam_census.
//
// WHY THIS EXISTS, and why the leg gate is not enough.  Two things the eleven
// RXFIX_BS_SIM_GATE legs cannot test, because the stimulus cannot make them vary:
//
//  (a) bs_trunc_min / bs_trunc_max.  Both skip_count control legs truncate EVERY frame
//      at the SAME word count (167 on k1536, 175 on k1024), so min == max == last is
//      satisfied trivially: an implementation in which both are copies of tLast, or in
//      which the two comparators are swapped, passes T1 and T3 identically.  Here the
//      truncation sizes VARY within one run, so the update direction is measured.
//
//  (b) The FREEZE level.  On the Verilator lineage TxRxComposite has no fixctl port, so
//      the injector ties bs_freeze to 1'b0 and the `if (~freeze)` shadow hold -- the
//      mechanism the whole "one coherent sweep across both enables" claim rests on --
//      is never exercised by any leg.  Here it is driven directly.
//
// The module under test is EXTRACTED FROM THE PATCHED TREE by build_bs_census_tb.sh
// (s1_rtl_bs/TxRxComposite.v, from `module bs_seam_census` to its endmodule), so this
// is a test of the injected text and not of a re-typed copy.
`timescale 1ns/1ps
module tb_bs_census;
  reg clk = 0, reset = 1, enbSer = 0, enbFifo = 0, freeze = 0;
  reg wv = 0, wl = 0, sstart = 0, push = 0, pop = 0, drop = 0, mark = 0;
  reg [15:0] wcnt = 0;
  wire [255:0] bus;
  integer errors = 0;
  integer i;

  bs_seam_census dut (.clk(clk), .reset(reset), .enbSer(enbSer), .enbFifo(enbFifo),
                      .freeze(freeze), .wv(wv), .wl(wl), .sstart(sstart), .wcnt(wcnt),
                      .push(push), .pop(pop), .drop(drop), .mark(mark), .bus(bus));

  always #5 clk = ~clk;

  // the eight words, by the canonical map (W1_REGMAP sec 7-BS.1)
  wire [31:0] w_words  = bus[ 32*0 +: 32];
  wire [31:0] w_starts = bus[ 32*1 +: 32];
  wire [31:0] w_push   = bus[ 32*2 +: 32];
  wire [31:0] w_pop    = bus[ 32*3 +: 32];
  wire [31:0] w_drop   = bus[ 32*4 +: 32];
  wire [15:0] f_lasts  = bus[ 32*5 +: 32] >> 16;
  wire [15:0] f_markp  = bus[ 32*5 +: 32];
  wire [7:0]  f_tlast  = bus[ 32*6 +: 32] >> 24;
  wire [7:0]  f_tmin   = bus[ 32*6 +: 32] >> 16;
  wire [7:0]  f_tmax   = bus[ 32*6 +: 32] >> 8;
  wire [7:0]  f_dmax   = bus[ 32*6 +: 32];
  wire [15:0] f_trunc  = bus[ 32*7 +: 32] >> 16;
  wire [7:0]  f_q24    = bus[ 32*7 +: 32] >> 8;
  wire [7:0]  f_rsv    = bus[ 32*7 +: 32];

  task chk; input [511:0] name; input [31:0] got, want;
    begin
      if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", name, got, want);
        errors = errors + 1;
      end else $display("PASS %0s = %0d", name, got);
    end
  endtask

  // One enbSer beat carrying (wv, wl, sstart, wcnt), followed by one idle beat.
  // The idle beat matters: the shadow is `sN <= wN` on the SAME clk edge that
  // increments the live counter, so the bus shows the pre-event value for one more
  // cycle.  Every task therefore returns with the bus already settled, and every chk
  // below reads a settled bus.
  task ser; input v, l, s; input [15:0] c;
    begin
      @(negedge clk); wv = v; wl = l; sstart = s; wcnt = c; enbSer = 1;
      @(negedge clk); enbSer = 0; wv = 0; wl = 0; sstart = 0;
      @(negedge clk);
    end
  endtask
  // one enbFifo beat carrying (push, pop, drop, mark), same settling rule
  task fif; input p, o, d, m;
    begin
      @(negedge clk); push = p; pop = o; drop = d; mark = m; enbFifo = 1;
      @(negedge clk); enbFifo = 0; push = 0; pop = 0; drop = 0; mark = 0;
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    @(negedge clk);
    // ---- reset values: min high, max low, reserved zero -------------------------
    chk("R.tmin resets to 191", f_tmin, 191);
    chk("R.tmax resets to 0",   f_tmax, 0);
    chk("R.rsv is hard 0",      f_rsv,  0);

    // ---- (a) the order statistics, with VARYING truncation sizes ----------------
    // 143 (on the 24 lattice: 191-143 = 48), then 167 (24), then 95 (96), then 100
    // (91 -- OFF the lattice).  min must fall to 95, max must rise to 167, last must
    // follow the most recent, and q24 must count 3 of the 4.
    ser(0, 0, 1, 16'd143);
    chk("A1.last after 143", f_tlast, 143);
    chk("A1.min after 143",  f_tmin,  143);
    chk("A1.max after 143",  f_tmax,  143);
    ser(0, 0, 1, 16'd167);
    chk("A2.last after 167", f_tlast, 167);
    chk("A2.min stays 143",  f_tmin,  143);
    chk("A2.max rises 167",  f_tmax,  167);
    ser(0, 0, 1, 16'd95);
    chk("A3.last after 95",  f_tlast, 95);
    chk("A3.min falls 95",   f_tmin,  95);
    chk("A3.max stays 167",  f_tmax,  167);
    ser(0, 0, 1, 16'd100);
    chk("A4.last after 100", f_tlast, 100);
    chk("A4.min stays 95",   f_tmin,  95);
    chk("A4.max stays 167",  f_tmax,  167);
    chk("A5.trunc counted 4", f_trunc, 4);
    chk("A5.q24 counted 3 of 4", f_q24, 3);
    chk("A5.starts counted 4", w_starts, 4);
    // a clean boundary (wcnt 0) is NOT a truncation, and neither is a full 191
    ser(0, 0, 1, 16'd0);
    ser(0, 0, 1, 16'd191);
    chk("A6.trunc still 4",   f_trunc, 4);
    chk("A6.starts now 6",    w_starts, 6);
    // an enbSer beat with sstart low must count nothing
    ser(0, 0, 0, 16'd143);
    chk("A7.trunc still 4",   f_trunc, 4);
    chk("A7.starts still 6",  w_starts, 6);

    // ---- words and lasts --------------------------------------------------------
    for (i = 0; i < 5; i = i + 1) ser(1, 0, 0, 16'd0);
    ser(1, 1, 0, 16'd0);
    chk("B1.words 6",  w_words, 6);
    chk("B2.lasts 1",  f_lasts, 1);

    // ---- the FIFO side, and bs_dropmax's RUN semantics --------------------------
    fif(1, 0, 0, 1);              // push carrying a mark
    fif(1, 0, 0, 0);
    fif(0, 1, 0, 0);              // a pop with no push
    chk("C1.push 2",     w_push,  2);
    chk("C2.pop 1",      w_pop,   1);
    chk("C3.markpush 1", f_markp, 1);
    // three contiguous drops, then a clean push, then two: the longest RUN is 3
    fif(1, 0, 1, 0); fif(1, 0, 1, 0); fif(1, 0, 1, 0);
    chk("C4.dropmax 3 after a run of 3", f_dmax, 3);
    fif(1, 0, 0, 0);
    fif(1, 0, 1, 0); fif(1, 0, 1, 0);
    chk("C5.drop total 5", w_drop, 5);
    chk("C6.dropmax still 3 (a clean push breaks the run)", f_dmax, 3);

    // ---- (b) THE FREEZE LEVEL ---------------------------------------------------
    freeze = 1;
    @(negedge clk);
    begin : freeze_blk
      reg [31:0] held_words, held_push, held_drop;
      reg [15:0] held_trunc;
      held_words = w_words; held_push = w_push; held_drop = w_drop; held_trunc = f_trunc;
      for (i = 0; i < 4; i = i + 1) begin ser(1, 0, 1, 16'd71); fif(1, 1, 0, 1); end
      chk("D1.words HELD",  w_words, held_words);
      chk("D2.push HELD",   w_push,  held_push);
      chk("D3.trunc HELD",  f_trunc, held_trunc);
      chk("D4.drop HELD",   w_drop,  held_drop);
      freeze = 0;
      @(negedge clk); @(negedge clk);
      // the LIVE counters never stopped, so the shadow must catch up by exactly the
      // four beats taken during the hold
      chk("D5.words caught up",  w_words,  held_words + 4);
      chk("D6.push caught up",   w_push,   held_push + 4);
      chk("D7.trunc caught up",  f_trunc,  held_trunc + 4);
    end
    chk("E1.reserved byte is still 0", f_rsv, 0);

    if (errors == 0) $display("TB_BS_CENSUS_PASS");
    else $display("TB_BS_CENSUS_FAIL errors=%0d", errors);
    $finish;
  end
endmodule
