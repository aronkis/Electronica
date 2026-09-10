// tb_rx_seq_checker -- unit sim for rx_seq_checker.v (SEQ-BIST T0a).
//
// Vectors come from seqbist_unit/gen_frames.py (run by run_unit.sh into
// ./vec/): a scripted stream of 191-word frames covering in-order runs, lost
// 1 / lost 2 / lost 5, a duplicate, a magic-corrupted frame, a CRC-corrupted
// frame, and gap events at EMITTED-frame (seq-delta) intervals 6, 30, 2, 32, 33
// and 40 -- one in each of int_hist_lt30, int_32, int_33 and int_other.  The
// interval-32 case is built WITH two intervening lost frames, so it only lands
// in int_32 if the interval really is a seq delta and not a received-frame count.

//
// Phases:
//   1  tgen_mode=1, the scripted stream driven BACK-TO-BACK (no idle cycle
//      between frames, which exercises the verdict / next-user-word same-cycle
//      path); all 16 counters compared exactly with vec/tgen_exp.hex.
//   2  freeze atomicity: freeze=1, 7 more clean frames driven, outputs must
//      not move; freeze=0, outputs must catch up.
//   3  clear-on-enable + en asserted mid-frame: after the clear the partial
//      frame tail must be ignored and only whole frames counted.
//   4  tgen_mode=0 (real host CRC32) with idle bubbles between words.  Under
//      -DNOCRC (WITH_CRC=0) the verdict is skipped in this mode, so good and
//      crc_fail must both read 0 while every other counter is unchanged.
//   5  the exact frame stream TGEN v2 emits with skip_every=5, end to end:
//      int_last must be N+1 = 6 (skip_every removes a seq number, not a
//      stream slot) and every gap must be gap1.
//   6  the exact stream with corrupt_every=8: garbage = 7, int_last = M = 8.
// Every check is an assertion; failures print TB_FAIL and set the exit code.
`timescale 1ns/1ps
module tb_rx_seq_checker;

  localparam integer MAXW = 40000;

  reg  clk = 1'b0;
  always #5 clk = ~clk;

  reg         rst_n = 1'b0;
  reg         en = 1'b0;
  reg         freeze = 1'b0;
  reg         tgen_mode = 1'b1;
  reg  [63:0] data = 64'd0;
  reg         valid = 1'b0;
  reg         user = 1'b0;
  reg         ready = 1'b0;
  wire [31:0] c [0:15];

  // WITH_CRC=0 build: iverilog -DNOCRC (see run_unit.sh)
`ifdef NOCRC
  localparam integer WCRC = 0;
`else
  localparam integer WCRC = 1;
`endif

  rx_seq_checker #(.WITH_CRC(WCRC)) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .freeze(freeze), .tgen_mode(tgen_mode),
    .data(data), .valid(valid), .user(user), .ready(ready),
    .cnt0(c[0]),   .cnt1(c[1]),   .cnt2(c[2]),   .cnt3(c[3]),
    .cnt4(c[4]),   .cnt5(c[5]),   .cnt6(c[6]),   .cnt7(c[7]),
    .cnt8(c[8]),   .cnt9(c[9]),   .cnt10(c[10]), .cnt11(c[11]),
    .cnt12(c[12]), .cnt13(c[13]), .cnt14(c[14]), .cnt15(c[15])
  );

  reg [63:0] tw [0:MAXW-1];
  reg [63:0] tu [0:MAXW-1];
  reg [63:0] ew [0:MAXW-1];
  reg [63:0] eu [0:MAXW-1];
  reg [63:0] hw [0:MAXW-1];
  reg [63:0] hu [0:MAXW-1];
  reg [31:0] texp [0:15];
  reg [31:0] hexp [0:15];
  reg [31:0] sexp [0:15];
  reg [31:0] xexp [0:15];
  reg [31:0] cur_exp [0:15];
  reg [63:0] sw [0:MAXW-1];
  reg [63:0] su [0:MAXW-1];
  reg [63:0] xw [0:MAXW-1];
  reg [63:0] xu [0:MAXW-1];
  reg [31:0] sizes [0:4];
  reg [31:0] snap [0:15];

  integer errors = 0;
  integer i, j;

  reg [8*20-1:0] NAMES [0:15];
  initial begin
    NAMES[0]="frames";      NAMES[1]="good";      NAMES[2]="garbage";
    NAMES[3]="crc_fail";    NAMES[4]="lost_slots";NAMES[5]="gap_events";
    NAMES[6]="gap1";        NAMES[7]="gap2";      NAMES[8]="gap3plus";
    NAMES[9]="dup_reorder"; NAMES[10]="last_seq"; NAMES[11]="int_last";
    NAMES[12]="int_lt30";   NAMES[13]="int_32";   NAMES[14]="int_33";
    NAMES[15]="int_other";
  end

  task chk; input [8*40-1:0] what; input [31:0] got; input [31:0] want;
    begin
      if (got !== want) begin
        errors = errors + 1;
        $display("TB_FAIL %0s: got %0d want %0d", what, got, want);
      end
    end
  endtask

  // compare all 16 outputs with cur_exp (loaded by the caller)
  task chk_all; input [8*20-1:0] tag;
    integer k;
    begin
      for (k = 0; k < 16; k = k + 1) begin
        if (c[k] !== cur_exp[k]) begin
          errors = errors + 1;
          $display("TB_FAIL %0s slot%0d (%0s): got %0d want %0d",
                   tag, 16 + k, NAMES[k], c[k], cur_exp[k]);
        end
      end
    end
  endtask

  task load_exp; input integer which;   // 0 texp, 1 hexp, 2 sexp, 3 xexp
    integer k;
    begin
      for (k = 0; k < 16; k = k + 1)
        cur_exp[k] = (which == 0) ? texp[k] : (which == 1) ? hexp[k] :
                     (which == 2) ? sexp[k] : xexp[k];
    end
  endtask

  // drive one word; bubbles = idle cycles inserted before it
  task drive; input [63:0] d; input u; input integer bubbles;
    integer b;
    begin
      for (b = 0; b < bubbles; b = b + 1) begin
        valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
        @(posedge clk);
      end
      data <= d; user <= u; valid <= 1'b1; ready <= 1'b1;
      @(posedge clk);
      valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
    end
  endtask

  integer nt, ne, nh, ns, nx;

  initial begin
    $readmemh("vec/tgen.hex", tw);
    $readmemh("vec/tgen.usr", tu);
    $readmemh("vec/extra.hex", ew);
    $readmemh("vec/extra.usr", eu);
    $readmemh("vec/host.hex", hw);
    $readmemh("vec/host.usr", hu);
    $readmemh("vec/tgen_exp.hex", texp);
    $readmemh("vec/host_exp.hex", hexp);
    $readmemh("vec/skip.hex", sw);
    $readmemh("vec/skip.usr", su);
    $readmemh("vec/corrupt.hex", xw);
    $readmemh("vec/corrupt.usr", xu);
    $readmemh("vec/skip_exp.hex", sexp);
    $readmemh("vec/corrupt_exp.hex", xexp);
    $readmemh("vec/sizes.hex", sizes);
    nt = sizes[0]; ne = sizes[1]; nh = sizes[2]; ns = sizes[3]; nx = sizes[4];

    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---------------- phase 1: scripted stream, back-to-back ---------------
    en <= 1'b1;                     // rising edge -> clear (2-FF synchronised)
    repeat (8) @(posedge clk);
    chk("phase1 pre frames", c[0], 32'd0);

    for (i = 0; i < nt; i = i + 1) begin
      data <= tw[i]; user <= tu[i][0]; valid <= 1'b1; ready <= 1'b1;
      @(posedge clk);
    end
    valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
    repeat (5) @(posedge clk);
    load_exp(0); chk_all("phase1");
    $display("TB_PHASE1 frames=%0d good=%0d garbage=%0d crc_fail=%0d lost=%0d gapev=%0d g1=%0d g2=%0d g3p=%0d dup=%0d lastseq=%0d ilast=%0d lt30=%0d i32=%0d i33=%0d ioth=%0d",
             c[0],c[1],c[2],c[3],c[4],c[5],c[6],c[7],c[8],c[9],c[10],c[11],c[12],c[13],c[14],c[15]);

    // ---------------- phase 2: freeze atomicity ----------------------------
    freeze <= 1'b1;
    repeat (8) @(posedge clk);
    for (j = 0; j < 16; j = j + 1) snap[j] = c[j];
    for (i = 0; i < ne; i = i + 1) begin
      data <= ew[i]; user <= eu[i][0]; valid <= 1'b1; ready <= 1'b1;
      @(posedge clk);
    end
    valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
    repeat (5) @(posedge clk);
    for (j = 0; j < 16; j = j + 1) begin
      if (c[j] !== snap[j]) begin
        errors = errors + 1;
        $display("TB_FAIL freeze not atomic: slot%0d (%0s) moved %0d -> %0d",
                 16 + j, NAMES[j], snap[j], c[j]);
      end
    end
    freeze <= 1'b0;
    repeat (8) @(posedge clk);
    // the 7 extra frames restart at seq 1 -> 1 duplicate/reorder-ish backward
    // step then 6 in-order frames; only `frames` is asserted here.
    chk("freeze released frames", c[0], texp[0] + 32'd7);
    if (c[0] === snap[0]) begin
      errors = errors + 1;
      $display("TB_FAIL freeze release: outputs never updated");
    end
    $display("TB_PHASE2 frames_after_release=%0d (held at %0d)", c[0], snap[0]);

    // ---------------- phase 3: clear + en mid-frame ------------------------
    en <= 1'b0;
    repeat (8) @(posedge clk);
    // drive the first half of a frame while disabled
    for (i = 0; i < 90; i = i + 1) drive(ew[i], eu[i][0], 0);
    en <= 1'b1;                     // rising edge mid-frame -> clear
    repeat (8) @(posedge clk);
    // the tail of that frame must be ignored (no user word seen since clear)
    for (i = 90; i < 191; i = i + 1) drive(ew[i], eu[i][0], 0);
    repeat (5) @(posedge clk);
    chk("clear frames", c[0], 32'd0);
    chk("clear good",   c[1], 32'd0);
    chk("clear garbage",c[2], 32'd0);
    chk("clear lost",   c[4], 32'd0);
    chk("clear lastseq",c[10], 32'd0);
    // now 3 whole frames (seq 1,2,3)
    for (i = 191; i < 4 * 191; i = i + 1) drive(ew[i], eu[i][0], 0);
    repeat (5) @(posedge clk);
    chk("midframe frames",  c[0], 32'd3);
    chk("midframe good",    c[1], 32'd3);
    chk("midframe garbage", c[2], 32'd0);
    chk("midframe crc_fail",c[3], 32'd0);
    chk("midframe lost",    c[4], 32'd0);
    chk("midframe gapev",   c[5], 32'd0);
    chk("midframe lastseq", c[10], 32'd4);
    $display("TB_PHASE3 frames=%0d good=%0d lastseq=%0d", c[0], c[1], c[10]);

    // ---------------- phase 4: host CRC32 mode, with bubbles ---------------
    en <= 1'b0;
    tgen_mode <= 1'b0;
    repeat (8) @(posedge clk);
    en <= 1'b1;
    repeat (8) @(posedge clk);
    for (i = 0; i < nh; i = i + 1) drive(hw[i], hu[i][0], (i % 7 == 0) ? 2 : 0);
    repeat (5) @(posedge clk);
    load_exp(1);
`ifdef NOCRC
    // WITH_CRC=0 and tgen_mode=0: nothing to check the CRC field against, so
    // the verdict is skipped and both good and crc_fail must stay 0
    cur_exp[1] = 32'd0; cur_exp[3] = 32'd0;
`endif
    chk_all("phase4-host");
    $display("TB_PHASE4 frames=%0d good=%0d crc_fail=%0d lost=%0d gap2=%0d",
             c[0], c[1], c[3], c[4], c[7]);

    // ---- phase 5: skip_every=5 stream end to end (positive control) -------
    en <= 1'b0; tgen_mode <= 1'b1;
    repeat (8) @(posedge clk);
    en <= 1'b1;
    repeat (8) @(posedge clk);
    for (i = 0; i < ns; i = i + 1) begin
      data <= sw[i]; user <= su[i][0]; valid <= 1'b1; ready <= 1'b1;
      @(posedge clk);
    end
    valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
    repeat (5) @(posedge clk);
    load_exp(2); chk_all("phase5-skip5");
    // the derived calibration, asserted on the real RTL:
    chk("skip5 int_last == N+1", c[11], 32'd6);
    chk("skip5 gap1 == gap_events", c[6], c[5]);
    chk("skip5 garbage", c[2], 32'd0);
    $display("TB_PHASE5 skip_every=5 frames=%0d gapev=%0d gap1=%0d int_last=%0d lost=%0d",
             c[0], c[5], c[6], c[11], c[4]);

    // ---- phase 6: corrupt_every=8 stream end to end (positive control) ----
    en <= 1'b0;
    repeat (8) @(posedge clk);
    en <= 1'b1;
    repeat (8) @(posedge clk);
    for (i = 0; i < nx; i = i + 1) begin
      data <= xw[i]; user <= xu[i][0]; valid <= 1'b1; ready <= 1'b1;
      @(posedge clk);
    end
    valid <= 1'b0; ready <= 1'b0; user <= 1'b0;
    repeat (5) @(posedge clk);
    load_exp(3); chk_all("phase6-corrupt8");
    chk("corrupt8 int_last == M", c[11], 32'd8);
    chk("corrupt8 garbage", c[2], 32'd7);
    chk("corrupt8 gap1 == gap_events", c[6], c[5]);
    $display("TB_PHASE6 corrupt_every=8 frames=%0d garbage=%0d gapev=%0d gap1=%0d int_last=%0d",
             c[0], c[2], c[5], c[6], c[11]);

    if (errors == 0) $display("TB_RX_SEQ_CHECKER_PASS");
    else             $display("TB_RX_SEQ_CHECKER_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("TB_RX_SEQ_CHECKER_FAIL timeout");
    $finish;
  end

endmodule
