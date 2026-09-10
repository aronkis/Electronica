// rx_seq_checker -- in-fabric frame SEQUENCE / loss checker at the DUT RX byte
// pins (decoder output, BEFORE the seam injector / breakout / axi_dmac), so no
// DMA, DDR or host daemon is in the measurement path.  Derived from
// jupiter_byte_txfixF3_build/rx_seam_checker.v (frame geometry + CRC32) with
// the sequence-number tracking and the inter-gap interval histogram added.
//
// SNOOP-ONLY: observes {data, valid, user} and the DUT-side ready, counting
// ACCEPTED words only (valid && ready && en).  Frame = user-marked word + 190
// more (1528 B = 191 x 64-bit words, bytes little-endian within a word).
// Header (qpsk_frame.h): [0..1] 0x51 0x4B magic, [2..3] len LE (<= 1516),
// [4..7] seq LE, [8..11] CRC32 field.
//
//   tgen_mode = 1 : the CRC field is accepted when it equals 0x54474E21
//                   ("TGN!"), the constant qpsk_traffic_gen writes.
//   tgen_mode = 0 : the CRC field must equal the host CRC32 (reflected poly
//                   0xEDB88320, init/final 0xFFFFFFFF) over bytes
//                   [0 .. 12+len-1] with the CRC field zeroed.
//
// PARAMETER
//   WITH_CRC = 1 (default)  the CRC32 datapath is instantiated: tgen_mode = 0
//              checks the real host CRC32.
//   WITH_CRC = 0            the CRC32 accumulator, its 64-bit-parallel
//              combinational tree and its register are NOT instantiated.
//              tgen_mode = 1 still works in full (the check is just
//              crc_field == 0x54474E21); with tgen_mode = 0 there is nothing to
//              check against, so the verdict is skipped entirely and BOTH
//              `good` and `crc_fail` stay 0.  This is the compile-time escape
//              hatch for a routed-WNS/utilisation failure: the CRC tree is by
//              far the largest block here, it is useless in every tgen_mode
//              stage (fabric loopback, RF self-reception, RF legs), and
//              runtime gating would remove nothing from the netlist.  The BD
//              patcher passes WITH_CRC as a cell property so the build driver
//              can set it to 0 without an RTL edit.
//
// CLOCK DOMAINS
//   clk is axi_adrv9001/adc_1_clk, but en / freeze / tgen_mode come from
//   tgen_rx_ctrl_gpio, which is clocked by the PS AXI clock.  All three are
//   therefore taken through a 2-FF synchronizer inside this module before use
//   (a metastable `en` sample would otherwise fire the edge detector and
//   silently wipe all 16 counters mid-run -- a short measurement window the
//   host scorer could not distinguish from a quiet link).  data/valid/user/
//   ready are already in the clk domain.
//
// CONTROL
//   en      gates the snoop; a RISING EDGE of en clears every live counter,
//           the shadow registers and all sequence state.  A clear takes effect
//           even while freeze is asserted (so a clear issued inside a host
//           freeze/read/unfreeze window is never silently dropped).
//   freeze  holds the 16 outputs (shadow registers) still while the live
//           counters keep running, so a 16-word host readout is atomic.
//           freeze = 0 -> shadow tracks live with one clock of latency.
//
// COUNTER MAP (cnt0..cnt15 -> cnt_mux32 slots 16..31)
//   cnt0  frames          user-marked words accepted (frames started)
//   cnt1  good            magic ok AND crc ok AND the frame was in-order
//   cnt2  garbage         magic/len not parseable          [counted at header]
//   cnt3  crc_fail        magic ok, crc check failed       [counted at verdict]
//   cnt4  lost_slots      sum of (seq - expected) over all forward gaps
//   cnt5  gap_events      number of forward gaps (seq > expected)
//   cnt6  gap1            gaps of exactly 1 lost slot
//   cnt7  gap2            gaps of exactly 2 lost slots
//   cnt8  gap3plus        gaps of 3 or more lost slots
//   cnt9  dup_or_reorder  seq <= last_seq on a good-magic frame
//   cnt10 last_seq        raw seq of the last good-magic frame
//   cnt11 int_last        interval of the most recent binned gap event
//   cnt12 int_hist_lt30   intervals < 30
//   cnt13 int_32          intervals == 32
//   cnt14 int_33          intervals == 33
//   cnt15 int_other       intervals 30, 31 or >= 34
//
// SEQUENCE SEMANTICS (all resolved at the user/header word)
//   Only frames with a GOOD MAGIC take part.  exp = last_seq + 1.
//     seq == exp  -> in-order
//     seq >  exp  -> lost_slots += seq-exp; gap_events++; gap1/gap2/gap3plus
//     seq <= last_seq -> dup_or_reorder++
//   last_seq is updated to seq in every case (so a duplicate does not poison
//   the next comparison; a genuine REORDER therefore shows up as 2 gap_events
//   plus 1 dup_or_reorder).  The first good-magic frame after a clear only
//   seeds last_seq and counts as in-order.  Seq wraparound (2^32 frames,
//   ~40 days at 1245 f/s) is NOT handled.
//
// INTERVAL SEMANTICS (operator ruling 2026-09-03: EMITTED-frame units)
//   The interval of a gap event is the HEADER SEQ DELTA between it and the
//   previous gap event:
//
//       interval = seq(this gap's revealing frame) - seq(previous gap's)
//
//   where the revealing frame is the good-magic frame whose seq exceeded the
//   expected one.  This is in EMITTED frame units and needs no loss
//   correction: a comb that drops one frame every 32 emitted frames reads
//   int_last = 32 no matter how many frames were received in between, and no
//   matter how many other frames were lost or arrived magic-corrupted inside
//   the period.  It is therefore directly comparable with the 32.4-frame
//   on-air comb.  The first gap event after a clear only establishes the
//   reference; it is not binned and does not update int_last.
//
//   Positive-control calibration (see qpsk_traffic_gen_v2.v):
//     skip_every  = N -> interval N+1 (N emitted frames plus the skipped seq)
//     corrupt_every = M -> interval M exactly
//
// NOTE ON tx_seam_checker: qpsk_traffic_gen_v2's corrupt_every = M flips the
// magic byte, and tx_seam_checker.v:94 only arms on a good magic
// (`first && hdr_magic_ok && hdr_fill_hi_ok`).  So during a corrupt_every run
// the TX-side checker SKIPS every M-th frame: its frames_checked runs short by
// floor(F/M) and its bit_errors never covers those frames.  Any gate or scorer
// identity of the form "TX frames_checked == RX frames" will fail spuriously
// under that positive control.
//
// NOTE ON IDENTITIES: frames != good + garbage + crc_fail.  The frame that
// follows a gap has a good magic and a good CRC but is not in-order, so it is
// counted in none of the three.  Frames truncated by a short_frm event never
// reach a verdict and so are counted in frames (and possibly garbage) only.
`timescale 1ns/1ps
module rx_seq_checker #(
  parameter integer WITH_CRC = 1     // 0 = omit the CRC32 datapath (see header)
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        en,          // snoop enable; rising edge clears
  input  wire        freeze,      // hold the outputs for an atomic readout
  input  wire        tgen_mode,   // 1 = accept CRC field == 0x54474E21
  input  wire [63:0] data,
  input  wire        valid,
  input  wire        user,        // first word of a frame
  input  wire        ready,
  output wire [31:0] cnt0,  cnt1,  cnt2,  cnt3,
  output wire [31:0] cnt4,  cnt5,  cnt6,  cnt7,
  output wire [31:0] cnt8,  cnt9,  cnt10, cnt11,
  output wire [31:0] cnt12, cnt13, cnt14, cnt15
);
  localparam [7:0]   WORDS     = 8'd191;
  localparam [31:0]  TGEN_CRC  = 32'h54474E21;

  // ---- control synchronizers (PS AXI clock -> adc_1_clk) ------------------
  reg [1:0] en_s, fr_s, tm_s;
  always @(posedge clk) begin
    if (!rst_n) begin
      en_s <= 2'b00; fr_s <= 2'b00; tm_s <= 2'b00;
    end else begin
      en_s <= {en_s[0], en};
      fr_s <= {fr_s[0], freeze};
      tm_s <= {tm_s[0], tgen_mode};
    end
  end
  wire en_q = en_s[1];
  wire fr_q = fr_s[1];
  wire tm_q = tm_s[1];

  wire acc = valid && ready && en_q;

  reg  en_d;                                   // reset explicitly (no X at t=0)
  always @(posedge clk) begin
    if (!rst_n) en_d <= 1'b0;
    else        en_d <= en_q;
  end
  wire clr = en_q && !en_d;

  // ---- CRC32 (reflected, poly 0xEDB88320) ---------------------------------
  function [31:0] crc8b; input [31:0] c; input [7:0] b; integer i; reg [31:0] x;
    begin x = c ^ {24'd0, b}; for (i = 0; i < 8; i = i + 1) x = (x >> 1) ^ (x[0] ? 32'hEDB88320 : 32'd0); crc8b = x; end
  endfunction
  function [31:0] crc64; input [31:0] c; input [63:0] w; integer k; reg [31:0] x;
    begin x = c; for (k = 0; k < 8; k = k + 1) x = crc8b(x, w[8*k +: 8]); crc64 = x; end
  endfunction
  function [31:0] crcpart; input [31:0] c; input [63:0] w; input [3:0] n; integer k; reg [31:0] x;
    begin x = c; for (k = 0; k < 8; k = k + 1) if (k < n) x = crc8b(x, w[8*k +: 8]); crcpart = x; end
  endfunction

  // ---- live counters -------------------------------------------------------
  reg [31:0] r_frames, r_good, r_garbage, r_crcfail;
  reg [31:0] r_lost, r_gapev, r_gap1, r_gap2, r_gap3p, r_dup, r_lastseq;
  reg [31:0] r_intlast, r_ilt30, r_i32, r_i33, r_ioth;

  // ---- frame parse state ---------------------------------------------------
  reg [7:0]  widx;          // word index within the frame, 0..191 (191 = complete)
  reg        inframe;
  reg        verdict_done;
  reg [31:0] crc_field;
  reg        hdr_ok;        // magic+len of the frame in flight
  reg        ino_lat;       // frame in flight was in-order
  reg [10:0] used_bytes;    // 12 + len

  // ---- sequence state ------------------------------------------------------
  reg        seq_seen;      // last_seq is meaningful
  reg [31:0] prev_gap_seq;  // seq of the frame that revealed the previous gap
  reg        have_prev_gap;

  wire [63:0] w1z    = {data[63:32], 32'd0};   // word 1 with the CRC field zeroed
  wire [11:0] len_w  = data[27:16];            // bytes 2..3 (LE), 12 bits used
  wire        magic_w = (data[7:0] == 8'h51) && (data[15:8] == 8'h4B) && (len_w <= 12'd1516);
  wire [31:0] seq_w  = data[63:32];            // bytes 4..7 (LE)

  wire [10:0] wbase  = {widx, 3'b000};
  wire [11:0] remain = {1'b0, used_bytes} - {1'b0, wbase};

  wire [31:0] exp_seq  = r_lastseq + 32'd1;
  wire        is_gap   = seq_seen && (seq_w >  exp_seq);
  wire        is_dup   = seq_seen && (seq_w <= r_lastseq);
  wire        is_inord = !seq_seen || (seq_w == exp_seq);
  wire [31:0] gap_size = seq_w - exp_seq;
  wire [31:0] ival     = seq_w - prev_gap_seq;   // emitted-frame interval

  // ---- CRC32 datapath, instantiated only when WITH_CRC != 0 ---------------
  wire [31:0] crc_final;
  generate
    if (WITH_CRC != 0) begin : g_crc
      reg [31:0] crc;
      always @(posedge clk) begin
        if (!rst_n || clr) crc <= 32'hFFFFFFFF;
        else if (acc) begin
          if (user)                            crc <= crc64(32'hFFFFFFFF, data);
          else if (!inframe || widx == WORDS)  ;                 // orphan: hold
          else if (widx == 8'd1)
            crc <= (remain >= 12'd8) ? crc64(crc, w1z)
                                     : crcpart(crc, w1z, remain[3:0]);
          else if (wbase >= used_bytes)        ;                 // pad: hold
          else if (remain >= 12'd8)            crc <= crc64(crc, data);
          else                                 crc <= crcpart(crc, data, remain[3:0]);
        end
      end
      assign crc_final = crc ^ 32'hFFFFFFFF;
    end else begin : g_nocrc
      assign crc_final = 32'd0;
    end
  endgenerate

  // with WITH_CRC = 0 and tgen_mode = 0 there is nothing to check against, so
  // the verdict is skipped entirely and good/crc_fail both stay 0
  wire        crc_checkable = tm_q || (WITH_CRC != 0);
  wire        crc_pass      = tm_q ? (crc_field == TGEN_CRC)
                                   : (crc_final == crc_field);

  always @(posedge clk) begin
    if (!rst_n || clr) begin
      r_frames <= 32'd0; r_good <= 32'd0; r_garbage <= 32'd0; r_crcfail <= 32'd0;
      r_lost <= 32'd0; r_gapev <= 32'd0; r_gap1 <= 32'd0; r_gap2 <= 32'd0;
      r_gap3p <= 32'd0; r_dup <= 32'd0; r_lastseq <= 32'd0;
      r_intlast <= 32'd0; r_ilt30 <= 32'd0; r_i32 <= 32'd0; r_i33 <= 32'd0; r_ioth <= 32'd0;
      widx <= 8'd0; inframe <= 1'b0; verdict_done <= 1'b0;
      crc_field <= 32'd0; hdr_ok <= 1'b0; ino_lat <= 1'b0;
      used_bytes <= 11'd0;
      seq_seen <= 1'b0; prev_gap_seq <= 32'd0; have_prev_gap <= 1'b0;
    end else begin
      // ---- word accounting ------------------------------------------------
      if (acc) begin
        if (user) begin
          r_frames <= r_frames + 32'd1;
          inframe  <= 1'b1;
          widx     <= 8'd1;
          hdr_ok   <= magic_w;
          used_bytes <= 11'd12 + len_w[10:0];
          if (!magic_w) begin
            r_garbage <= r_garbage + 32'd1;
            ino_lat   <= 1'b0;
          end else begin
            r_lastseq    <= seq_w;
            seq_seen     <= 1'b1;
            ino_lat      <= is_inord;
            if (is_gap) begin
              r_lost  <= r_lost  + gap_size;
              r_gapev <= r_gapev + 32'd1;
              if      (gap_size == 32'd1) r_gap1  <= r_gap1  + 32'd1;
              else if (gap_size == 32'd2) r_gap2  <= r_gap2  + 32'd1;
              else                        r_gap3p <= r_gap3p + 32'd1;
              // inter-gap interval, in emitted frames (header seq delta)
              prev_gap_seq  <= seq_w;
              have_prev_gap <= 1'b1;
              if (have_prev_gap) begin
                r_intlast <= ival;
                if      (ival <  32'd30) r_ilt30 <= r_ilt30 + 32'd1;
                else if (ival == 32'd32) r_i32   <= r_i32   + 32'd1;
                else if (ival == 32'd33) r_i33   <= r_i33   + 32'd1;
                else                     r_ioth  <= r_ioth  + 32'd1;
              end
            end else if (is_dup) begin
              r_dup <= r_dup + 32'd1;
            end
          end
        end else if (!inframe || widx == WORDS) begin
          // orphan word: not counted (no slot budget); ignored
        end else begin
          if (widx == 8'd1) crc_field <= data[31:0];
          if (widx == (WORDS - 8'd1)) widx <= WORDS;
          else                           widx <= widx + 8'd1;
        end
      end

      // ---- verdict, one cycle after the last word of a frame ---------------
      if (inframe && widx == WORDS && !verdict_done) begin
        verdict_done <= 1'b1;
        if (hdr_ok && crc_checkable) begin
          if (crc_pass) begin
            if (ino_lat) r_good <= r_good + 32'd1;
          end else begin
            r_crcfail <= r_crcfail + 32'd1;
          end
        end
      end
      if (acc && user) verdict_done <= 1'b0;
    end
  end

  // ---- shadow registers (atomic readout) ----------------------------------
  reg [31:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15;
  always @(posedge clk) begin
    if (!rst_n || clr) begin
      s0 <= 32'd0; s1 <= 32'd0; s2 <= 32'd0; s3 <= 32'd0;
      s4 <= 32'd0; s5 <= 32'd0; s6 <= 32'd0; s7 <= 32'd0;
      s8 <= 32'd0; s9 <= 32'd0; s10 <= 32'd0; s11 <= 32'd0;
      s12 <= 32'd0; s13 <= 32'd0; s14 <= 32'd0; s15 <= 32'd0;
    end else if (!fr_q) begin
      s0  <= r_frames;  s1  <= r_good;    s2  <= r_garbage; s3  <= r_crcfail;
      s4  <= r_lost;    s5  <= r_gapev;   s6  <= r_gap1;    s7  <= r_gap2;
      s8  <= r_gap3p;   s9  <= r_dup;     s10 <= r_lastseq; s11 <= r_intlast;
      s12 <= r_ilt30;   s13 <= r_i32;     s14 <= r_i33;     s15 <= r_ioth;
    end
  end

  assign cnt0 = s0;   assign cnt1 = s1;   assign cnt2 = s2;   assign cnt3 = s3;
  assign cnt4 = s4;   assign cnt5 = s5;   assign cnt6 = s6;   assign cnt7 = s7;
  assign cnt8 = s8;   assign cnt9 = s9;   assign cnt10 = s10; assign cnt11 = s11;
  assign cnt12 = s12; assign cnt13 = s13; assign cnt14 = s14; assign cnt15 = s15;

endmodule
