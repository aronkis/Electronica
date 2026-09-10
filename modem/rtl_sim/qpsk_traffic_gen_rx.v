// qpsk_traffic_gen_rx -- in-fabric programmable packet source at the RX seam:
// between the DUT byte-RX outputs and rx_byte_breakout / axi_dmac S2MM.
// Spec intent (Layer B, 2026-08-18): inject AFTER the demod, at the
// fabric-to-processor boundary, so generator -> DMA -> DDR -> host scorer
// contains NO modem DSP. Expectation there is bit-exact, zero loss.
// Pass-through (enable=0, reset default): DUT RX pins wired straight through
// (data/valid/last/user forward, ready back).
// Generate (enable=1): drives {data,valid,user[,last]} under the DMA's real
// ready; the DUT stream is CONSUMED AND DISCARDED at the seam (dut_ready held
// high -- never stall the DUT: sustained drain stall is the #48 wedge trigger).
// user pulses on word 0 of every generated frame (rx_byte_dma is built with
// SYNC_TRANSFER_START=true: transfers cannot start without a tuser beat).
// last asserts on word 190 only when ctrl[1] is set (default off; the -M
// queued path is marker-less and early TLAST desyncs it).
// Frame content is IDENTICAL to qpsk_traffic_gen (header QK/len/seq/CRC-const
// + PN fill + zero pad = 1528B = 191 words).
`timescale 1ns/1ps
module qpsk_traffic_gen_rx (
  input  wire        clk,
  input  wire        resetn,
  input  wire [31:0] ctrl,          // [0] enable, [1] last_en, [2] user_mask, [15:4] fill_len, [31:16] word_gap
  input  wire [31:0] gap,           // clks frame-end -> next frame-start
  // v2 (2026-08-28 DMAC-probe image): seam witness counters, free-running from reset
  output reg  [31:0] acc_beats,     // beats accepted at the seam toward the DMAC (valid&ready), any source
  output reg  [31:0] acc_user,      // of those, beats with user=1 as SEEN BY THE DMAC (post-mask)
  // DUT RX byte outputs (upstream)
  input  wire [63:0] dut_data,
  input  wire        dut_valid,
  input  wire        dut_last,
  input  wire        dut_user,
  output wire        dut_ready,
  // toward rx_byte_breakout -> axi_dmac S2MM (downstream)
  output wire [63:0] dma_data,
  output wire        dma_valid,
  output wire        dma_last,
  output wire        dma_user,
  input  wire        dma_ready
);
  localparam integer PKT_BYTES = 1528;
  localparam integer HDR_BYTES = 12;
  localparam [31:0] CRC_CONST = 32'h54474E21;
  localparam S_IDLE = 2'd0, S_BUILD = 2'd1, S_SEND = 2'd2, S_GAP = 2'd3;

  wire        en       = ctrl[0];
  // SILICON FINDING 2026-08-18 (daemon-witness discriminator): asserting TLAST
  // per frame toward the S2MM engine -- which this reference design NEVER does
  // in -M mode -- kills delivery persistently (early transfer termination
  // desyncs the queued descriptor chain; no recovery on disable). last is
  // therefore OFF by default and only driven when ctrl[1] is set (future -F).
  wire        last_en  = ctrl[1];
  // v2: user_mask=1 forces tuser=0 toward the DMAC for BOTH pass-through and
  // generated streams (Option E probe: host syncs the first transfer with the
  // mask off, then sets it -- a SYNC_TRANSFER_START engine can no longer discard
  // words waiting for a frame start; alignment is held by exact X_LENGTH).
  wire        user_mask = ctrl[2];
  // v2: word_gap = extra clks between consecutive generated words; word period =
  // word_gap + 10 clk (8 build + 2 send). (0 = v1
  // burst behaviour). ~545 @122.88 MHz reproduces the modem's continuous
  // 1180 f/s x 191 words cadence when gap == word_gap.
  wire [15:0] word_gap = ctrl[31:16];
  reg  [15:0] wgcnt;
  wire [11:0] fill_raw = ctrl[15:4];
  wire [11:0] fill_len = (fill_raw > 12'd1516) ? 12'd1516 : fill_raw;

  reg [1:0]  st;
  reg        en_d;
  reg [31:0] seq;
  reg [31:0] pn;                    // xorshift32 state
  reg [10:0] bidx;                  // byte index 0..1527
  reg [63:0] wreg;                  // word being assembled
  reg [63:0] sreg;                  // word being sent
  reg        s_valid, s_last, s_user;
  reg [31:0] gapcnt;
  reg [11:0] fill_lat;              // fill latched per frame

  // one xorshift round (matches qpsk_seq_payload byte step)
  function [31:0] xs; input [31:0] x; reg [31:0] a, b;
    begin a = x ^ (x << 13); b = a ^ (a >> 17); xs = b ^ (b << 5); end
  endfunction
  wire [31:0] pn_seed  = (seq ^ 32'h9E3779B9);
  wire [31:0] pn_init  = (pn_seed == 32'd0) ? 32'hDEADBEEF : pn_seed;

  // current header/pad/PN byte for bidx
  reg [7:0] cb;
  wire [31:0] pn_byte_w = xs(pn);
  always @* begin
    case (bidx)
      11'd0:  cb = 8'h51;  11'd1: cb = 8'h4B;
      11'd2:  cb = fill_lat[7:0];        11'd3: cb = {4'b0, fill_lat[11:8]};
      11'd4:  cb = seq[7:0];   11'd5: cb = seq[15:8];
      11'd6:  cb = seq[23:16]; 11'd7: cb = seq[31:24];
      11'd8:  cb = CRC_CONST[7:0];   11'd9:  cb = CRC_CONST[15:8];
      11'd10: cb = CRC_CONST[23:16]; 11'd11: cb = CRC_CONST[31:24];
      default: cb = (bidx < (HDR_BYTES + {1'b0,fill_lat})) ? pn_byte_w[7:0] : 8'h00;
    endcase
  end

  assign dma_data  = en_d ? sreg    : dut_data;
  assign dma_valid = en_d ? s_valid : dut_valid;
  assign dma_last  = en_d ? (s_last && last_en) : dut_last;
  // SYNC_TRANSFER_START (silicon root cause, 3rd defect, proven from BD config):
  // rx_byte_dma is built with SYNC_TRANSFER_START=true -- every queued transfer
  // gates its start on TUSER=1 at an accepted beat. The DUT pulses tuser on each
  // frame's first word; a generator that never asserts tuser can NEVER start a
  // transfer. Mirror the DUT: pulse user with word 0 of every generated frame.
  wire        user_pre = en_d ? s_user  : dut_user;
  assign dma_user  = user_pre & ~user_mask;
  // CONSUME-AND-DISCARD (silicon finding 2026-08-18, 2nd defect): holding
  // dut_ready=0 for the generate window is a sustained stall of the DUT
  // byte-RX drain -- the #48 "drain starves feeder" wedge-trigger profile
  // (daemon-witness: zero delivery during the window, no recovery after).
  // Instead keep the DUT draining at its natural cadence and drop its words
  // at the seam; the generator owns the DMA-facing stream.
  assign dut_ready = en_d ? 1'b1    : dma_ready;   // consume+discard DUT RX while generating

  wire s_fire = s_valid && dma_ready;

  // v2 witness counters (post-mux, post-mask: exactly what the DMAC accepted)
  always @(posedge clk) begin
    if (!resetn) begin acc_beats <= 32'd0; acc_user <= 32'd0; end
    else if (dma_valid && dma_ready) begin
      acc_beats <= acc_beats + 32'd1;
      if (dma_user) acc_user <= acc_user + 32'd1;
    end
  end

  always @(posedge clk) begin
    if (!resetn) begin
      st <= S_IDLE; en_d <= 1'b0; seq <= 32'd1; s_valid <= 1'b0; s_last <= 1'b0; s_user <= 1'b0;
      bidx <= 11'd0; gapcnt <= 32'd0; fill_lat <= 12'd0; wgcnt <= 16'd0;
    end else begin
      if (wgcnt != 16'd0) wgcnt <= wgcnt - 16'd1;
      // en_d switches the mux only at frame boundaries (never mid-frame)
      if (st == S_IDLE || st == S_GAP) en_d <= en;
      case (st)
        S_IDLE: if (en) begin
          seq <= 32'd1; fill_lat <= fill_len; pn <= pn_init;
          bidx <= 11'd0; st <= S_BUILD;
        end
        S_BUILD: if (wgcnt == 16'd0) begin   // 8 bytes -> one word (v2: held while word_gap runs)
          case (bidx[2:0])
            3'd0: wreg[7:0]   <= cb;
            3'd1: wreg[15:8]  <= cb;
            3'd2: wreg[23:16] <= cb;
            3'd3: wreg[31:24] <= cb;
            3'd4: wreg[39:32] <= cb;
            3'd5: wreg[47:40] <= cb;
            3'd6: wreg[55:48] <= cb;
            3'd7: wreg[63:56] <= cb;
          endcase
          if (bidx >= HDR_BYTES && bidx < (HDR_BYTES + {1'b0,fill_lat}))
            pn <= xs(pn);                    // consume one PN step per payload byte
          if (bidx[2:0] == 3'd7) st <= S_SEND;
          bidx <= bidx + 11'd1;
        end
        S_SEND: begin
          if (!s_valid) begin
            sreg <= wreg; s_valid <= 1'b1;
            s_last <= (bidx == PKT_BYTES[10:0]);   // word 190 just completed
            s_user <= (bidx == 11'd8);             // word 0 just completed
          end else if (s_fire) begin
            s_valid <= 1'b0; s_last <= 1'b0; s_user <= 1'b0;
            if (bidx == PKT_BYTES[10:0]) begin   // 1528: frame done
              gapcnt <= gap; st <= S_GAP;
            end else begin st <= S_BUILD; wgcnt <= word_gap; end
          end
        end
        S_GAP: begin
          if (!en && gapcnt == 32'd0) st <= S_IDLE;        // clean stop point
          else if (gapcnt != 32'd0) gapcnt <= gapcnt - 32'd1;
          else begin                                        // next frame
            seq <= seq + 32'd1; fill_lat <= fill_len;
            pn <= ((seq + 32'd1) ^ 32'h9E3779B9) == 32'd0 ? 32'hDEADBEEF
                                                          : ((seq + 32'd1) ^ 32'h9E3779B9);
            bidx <= 11'd0; st <= S_BUILD;
          end
        end
      endcase
      if (st == S_IDLE && !en) seq <= 32'd1;   // re-arm: seq restarts on next rise
    end
  end
endmodule
