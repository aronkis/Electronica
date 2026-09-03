// burst_onset_det.v -- burst-onset trigger for the 119.75s periodic error burst
// hunt (BEATILA overlay). Counts post-Viterbi bit-error increments in a rolling
// ~1 ms window and asserts trig when the window count exceeds THRESH while
// software has armed the detector.
//
// Clock: DUT fabric clock adc_1_clk. Assumed 30.72 MHz (Image A f1536 rung,
// image_a_3072_clocks.xdc). WIN_CYCLES = 30720 cycles = 1.000 ms.
// Window is a two-bucket coarse rolling window (current + previous half-ms
// bucket), so detection latency <= 1 ms and no shift-RAM is needed.
//
// err_cnt is a free-running error COUNTER (e.g. DUT bit_errors_out brought to
// a port by overlay); increments are extracted internally, so either a pulse
// (counter that increments by 1) or a jumping counter works. Delta per cycle
// is capped at 255 to bound the adder.
//
// ctrl (from AXI GPIO, all-outputs channel):
//   ctrl[0]    arm        - trigger enabled only while 1 ("schedulable")
//   ctrl[1]    soft_force - software-forced trigger (for plumbing checks)
// status (to AXI GPIO, all-inputs channel):
//   status[15:0]  live window count, status[16] trig, status[17] trig_latched
//
// Single clock, synchronous active-low reset.

module burst_onset_det #(
  parameter integer THRESH       = 32,     // window err count > THRESH -> trig
  parameter integer WIN_CYCLES   = 30720   // ~1 ms @ 30.72 MHz
) (
  input  wire        clk,
  input  wire        resetn,     // synchronous, active low
  input  wire [31:0] err_cnt,    // free-running error counter (or pulse)
  input  wire [31:0] ctrl,       // [0]=arm  [1]=soft_force
  output wire        trig,       // 1-cycle-registered trigger level
  output reg         trig_latched,
  output wire [31:0] status
);

  localparam integer HALF = WIN_CYCLES / 2;

  reg  [31:0] err_cnt_q;
  reg  [15:0] bucket_cur, bucket_prev;
  reg  [15:0] half_timer;
  reg         trig_r;

  wire [31:0] delta_raw = err_cnt - err_cnt_q;
  wire [7:0]  delta     = (delta_raw > 32'd255) ? 8'd255 : delta_raw[7:0];
  wire [16:0] win_sum   = {1'b0, bucket_cur} + {1'b0, bucket_prev};
  wire        arm       = ctrl[0];
  wire        soft      = ctrl[1];

  always @(posedge clk) begin
    if (!resetn) begin
      err_cnt_q    <= 32'd0;
      bucket_cur   <= 16'd0;
      bucket_prev  <= 16'd0;
      half_timer   <= 16'd0;
      trig_r       <= 1'b0;
      trig_latched <= 1'b0;
    end else begin
      err_cnt_q <= err_cnt;
      // bucket accumulate, saturating
      if (half_timer == HALF - 1) begin
        half_timer  <= 16'd0;
        bucket_prev <= bucket_cur;
        bucket_cur  <= {8'd0, delta};
      end else begin
        half_timer <= half_timer + 16'd1;
        if (bucket_cur <= 16'hFF00)
          bucket_cur <= bucket_cur + {8'd0, delta};
      end
      trig_r <= arm & ((win_sum > THRESH) | soft);
      if (!arm)            trig_latched <= 1'b0;   // disarm clears the latch
      else if (trig_r)     trig_latched <= 1'b1;
    end
  end

  assign trig   = trig_r;
  assign status = {14'd0, trig_latched, trig_r, win_sum[15:0]};

endmodule
