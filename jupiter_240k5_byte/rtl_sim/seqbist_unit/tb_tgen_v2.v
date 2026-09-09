// tb_tgen_v2 -- unit sim for qpsk_traffic_gen_v2.v (SEQ-BIST T0a).
//
//   A  EQUIVALENCE: v1 and v2 instantiated side by side on identical inputs
//      (skip_every = corrupt_every = 0, gap[27] = 0, a pseudorandom dut_ready
//      shared by both).  {dut_data, dut_valid, dut_first, host_ready} must be
//      equal on EVERY clock, from reset through 200 complete frames, including
//      the enable=0 pass-through phase before the run.
//   B  skip_every = 5: exactly one +2 seq step after every 5th frame, every
//      other step +1.
//   C  corrupt_every = 4 (gap[27]=1): header byte 0 == 0xAE on exactly every
//      4th frame and 0x51 otherwise; the seq sequence stays contiguous.
`timescale 1ns/1ps
module tb_tgen_v2;

  localparam integer NFRAMES_EQ = 200;
  localparam integer NFRAMES_C  = 200;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg         resetn = 1'b0;
  reg  [31:0] ctrl = 32'd0;
  reg  [31:0] gap  = 32'd0;
  reg  [63:0] host_data = 64'd0;
  reg         host_valid = 1'b0;
  reg         host_first = 1'b0;
  reg         dut_ready = 1'b1;

  wire [63:0] d1, d2;
  wire        v1, v2, f1, f2, hr1, hr2;

  qpsk_traffic_gen u1 (
    .clk(clk), .resetn(resetn), .ctrl(ctrl), .gap(gap),
    .host_data(host_data), .host_valid(host_valid), .host_first(host_first),
    .host_ready(hr1),
    .dut_data(d1), .dut_valid(v1), .dut_first(f1), .dut_ready(dut_ready));

  qpsk_traffic_gen_v2 u2 (
    .clk(clk), .resetn(resetn), .ctrl(ctrl), .gap(gap),
    .host_data(host_data), .host_valid(host_valid), .host_first(host_first),
    .host_ready(hr2),
    .dut_data(d2), .dut_valid(v2), .dut_first(f2), .dut_ready(dut_ready));

  integer errors = 0;
  integer eq_words = 0;
  integer eq_frames = 0;
  integer cmp_on = 0;

  reg [31:0] lfsr = 32'h1234_5678;
  always @(posedge clk) begin
    lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    // a shared, deterministic ready pattern (~75 % duty) for the equivalence run
    if (cmp_on) dut_ready <= (lfsr[3:0] != 4'd0);
  end

  // cycle-by-cycle equivalence
  always @(posedge clk) if (cmp_on && resetn) begin
    if ((v1 !== v2) || (f1 !== f2) || (hr1 !== hr2) ||
        (v1 && (d1 !== d2))) begin
      errors = errors + 1;
      if (errors < 10)
        $display("TB_FAIL equivalence @%0t: v %b/%b f %b/%b hr %b/%b d %h/%h",
                 $time, v1, v2, f1, f2, hr1, hr2, d1, d2);
    end
    if (v1 && dut_ready) begin
      eq_words = eq_words + 1;
      if (f1) eq_frames = eq_frames + 1;
    end
  end

  // v2 frame observation (phases B and C)
  integer nobs = 0;
  reg [31:0] seq_obs [0:1023];
  reg [7:0]  b0_obs  [0:1023];
  reg        obs_on = 1'b0;
  always @(posedge clk) if (obs_on && v2 && dut_ready && f2 && nobs < 1024) begin
    seq_obs[nobs] = d2[63:32];
    b0_obs[nobs]  = d2[7:0];
    nobs = nobs + 1;
  end

  integer i, steps2, steps1, stepsx, ncorr, ok;

  task run_reset;
    begin
      cmp_on = 0; obs_on = 0; ctrl = 32'd0; gap = 32'd0;
      resetn = 1'b0; dut_ready = 1'b1;
      repeat (4) @(posedge clk);
      resetn = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    // =============== A: equivalence =====================================
    run_reset;
    cmp_on = 1;
    // pass-through phase: enable off, host traffic flowing
    host_valid = 1'b1; host_first = 1'b1; host_data = 64'hA5A5_0F0F_1234_5678;
    repeat (20) @(posedge clk);
    host_first = 1'b0;
    repeat (20) @(posedge clk);
    // generate: fill 1516, skip/corrupt = 0, gap = 20 clks, mode bit 0
    ctrl = {16'd0, 12'd1516, 4'd1};      // [31:16]=0, [15:4]=1516, [0]=1
    gap  = 32'd20;
    while (eq_frames < NFRAMES_EQ) @(posedge clk);
    repeat (50) @(posedge clk);
    ctrl[0] = 1'b0;
    repeat (4000) @(posedge clk);        // finish the frame in flight + idle
    if (errors == 0)
      $display("TB_TGEN_EQ_OK frames=%0d words=%0d", eq_frames, eq_words);
    else
      $display("TB_TGEN_EQ_FAIL mismatches=%0d frames=%0d", errors, eq_frames);
    cmp_on = 0; dut_ready = 1'b1;

    // =============== B: skip_every = 5 ==================================
    run_reset;
    nobs = 0; obs_on = 1;
    ctrl = {16'd5, 12'd1516, 4'd1};      // skip_every = 5 (gap[27] = 0)
    gap  = 32'd20;
    while (nobs < NFRAMES_C) @(posedge clk);
    obs_on = 0; ctrl[0] = 1'b0;
    steps1 = 0; steps2 = 0; stepsx = 0; ok = 1;
    for (i = 1; i < NFRAMES_C; i = i + 1) begin
      if (seq_obs[i] - seq_obs[i-1] == 32'd1) begin
        steps1 = steps1 + 1;
        if (i % 5 == 0) ok = 0;          // frame i-1 was the 5th -> must be +2
      end else if (seq_obs[i] - seq_obs[i-1] == 32'd2) begin
        steps2 = steps2 + 1;
        if (i % 5 != 0) ok = 0;          // +2 only right after an N-th frame
      end else stepsx = stepsx + 1;
    end
    if (seq_obs[0] !== 32'd1) begin
      errors = errors + 1; $display("TB_FAIL skip: first seq %0d != 1", seq_obs[0]);
    end
    if (stepsx != 0) begin
      errors = errors + 1; $display("TB_FAIL skip: %0d steps neither +1 nor +2", stepsx);
    end
    if (!ok) begin
      errors = errors + 1; $display("TB_FAIL skip: a +2 step landed off the 5-frame cadence");
    end
    if (steps2 != (NFRAMES_C - 1) / 5) begin
      errors = errors + 1;
      $display("TB_FAIL skip: %0d skips, want %0d", steps2, (NFRAMES_C - 1) / 5);
    end
    $display("TB_TGEN_SKIP steps1=%0d steps2=%0d other=%0d first=%0d last=%0d",
             steps1, steps2, stepsx, seq_obs[0], seq_obs[NFRAMES_C-1]);

    // =============== C: corrupt_every = 4 ===============================
    run_reset;
    nobs = 0; obs_on = 1;
    ctrl = {16'd4, 12'd1516, 4'd1};      // corrupt_every = 4
    gap  = {4'd0, 1'b1, 27'd20};         // gap[27] = 1 -> corrupt mode
    while (nobs < NFRAMES_C) @(posedge clk);
    obs_on = 0; ctrl[0] = 1'b0;
    ncorr = 0; ok = 1;
    for (i = 0; i < NFRAMES_C; i = i + 1) begin
      if (b0_obs[i] === 8'hAE) begin
        ncorr = ncorr + 1;
        if ((i + 1) % 4 != 0) ok = 0;
      end else if (b0_obs[i] !== 8'h51) begin
        ok = 0;
      end else if ((i + 1) % 4 == 0) ok = 0;
      if (seq_obs[i] !== i + 1) begin
        errors = errors + 1;
        if (errors < 10)
          $display("TB_FAIL corrupt: frame %0d seq %0d != %0d", i, seq_obs[i], i + 1);
      end
    end
    if (ncorr != NFRAMES_C / 4) begin
      errors = errors + 1;
      $display("TB_FAIL corrupt: %0d corrupted, want %0d", ncorr, NFRAMES_C / 4);
    end
    if (!ok) begin
      errors = errors + 1;
      $display("TB_FAIL corrupt: corruption off the 4-frame cadence");
    end
    $display("TB_TGEN_CORRUPT corrupted=%0d of %0d", ncorr, NFRAMES_C);

    if (errors == 0) $display("TB_TGEN_V2_PASS");
    else             $display("TB_TGEN_V2_FAIL errors=%0d", errors);
    $finish;
  end

  initial begin
    #60000000;
    $display("TB_TGEN_V2_FAIL timeout");
    $finish;
  end

endmodule
