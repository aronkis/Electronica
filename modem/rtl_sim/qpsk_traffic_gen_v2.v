// qpsk_traffic_gen_v2 -- qpsk_traffic_gen (fabric TX-byte-mux packet source)
// plus the two SEQ-BIST positive-control fields, skip_every and corrupt_every.
// Everything else -- header layout, seq, PN payload, zero pad, mux/pass-through
// behaviour and the ready handshake -- is bit-identical to v1 and is proven so
// by seqbist_unit/tb_tgen_v2 (200 frames compared word-for-word with the new
// fields at 0).
//
// Pass-through (enable=0, reset default): host pins wired straight through.
// Generate (enable=1): drives {data,valid,first} under the DUT's real ready;
// holds host_ready low so host TX stalls harmlessly at the DMA.
// Frame: 12B header (QK, len LE, seq LE, CRC const 0x54474E21) + fill_len PN
// bytes (xorshift32, bit-compatible with qpsk_seq_payload) + zero pad = 1528B.
// One payload byte per clk; a 64-bit word every 8 clks; 191 words/frame.
// Enable-off mid-frame completes the frame. Seq restarts at 1 on enable rise.
//
// CONTROL-WORD ENCODING (SEQ-BIST contract, 2026-09-03)
//   ctrl @0x9D400000
//     [0]      enable
//     [15:4]   fill_len (0..1516)
//     [31:16]  N -- skip_every   when gap[27] == 0
//              M -- corrupt_every when gap[27] == 1
//              0 in either mode = the feature is OFF
//   gap  @0x9D400008
//     [26:0]   gap, in clocks, from frame end to the next frame start
//     [27]     mode bit: 0 = ctrl[31:16] is skip_every,
//                        1 = ctrl[31:16] is corrupt_every
//     [31:28]  reserved, must be 0
//
//   skip_every = N : every N-th generated frame is the last before a
//     deliberately skipped sequence number -- the frame that follows it is
//     emitted with seq advanced by 2.  Over F frames the checker must see
//     ~F/N gap_events, all of size 1 (gap1), and int_last == N.
//   corrupt_every = M : every M-th generated frame has header byte 0 (the
//     0x51 magic byte) XORed with 0xFF (0x51 -> 0xAE), so the checker must
//     count exactly ~F/M in `garbage`.  seq, PN and pad are untouched, so a
//     corrupted frame simply drops out of the sequence tracking (the frame
//     after it is a gap of 1 -- expected, and what the host scorer subtracts).
//
//   The two fields are mutually exclusive by construction (one mode bit, one
//   cadence counter), which is deliberate: a run exercises one control at a
//   time so its count is unambiguous.
//   Note: gap is 27 bits here (v1 used all 32).  27 bits = 134 M clocks
//   ~ 1.3 s at 100 MHz, far beyond any usable frame period.
`timescale 1ns/1ps
module qpsk_traffic_gen_v2 (
  input  wire        clk,
  input  wire        resetn,
  input  wire [31:0] ctrl,          // [0] enable, [15:4] fill_len, [31:16] skip_every/corrupt_every
  input  wire [31:0] gap,           // [26:0] clks frame-end -> next frame-start, [27] mode
  // host side (from byte_breakout)
  input  wire [63:0] host_data,
  input  wire        host_valid,
  input  wire        host_first,
  output wire        host_ready,
  // DUT side
  output wire [63:0] dut_data,
  output wire        dut_valid,
  output wire        dut_first,
  input  wire        dut_ready
);
  localparam integer PKT_BYTES = 1528;
  localparam integer HDR_BYTES = 12;
  localparam [31:0] CRC_CONST = 32'h54474E21;
  localparam S_IDLE = 2'd0, S_BUILD = 2'd1, S_SEND = 2'd2, S_GAP = 2'd3;

  wire        en       = ctrl[0];
  wire [11:0] fill_raw = ctrl[15:4];
  wire [11:0] fill_len = (fill_raw > 12'd1516) ? 12'd1516 : fill_raw;

  // ---- v2: skip_every / corrupt_every cadence (see the header comment) ----
  wire        mode_corrupt = gap[27];
  wire [26:0] gap_clks     = gap[26:0];
  wire [15:0] nth          = ctrl[31:16];          // N or M, per mode_corrupt
  wire        nth_on       = (nth != 16'd0);

  reg [1:0]  st;
  reg        en_d;
  reg [31:0] seq;
  reg [31:0] pn;                    // xorshift32 state
  reg [10:0] bidx;                  // byte index 0..1527
  reg [63:0] wreg;                  // word being assembled
  reg [63:0] sreg;                  // word being sent
  reg        s_valid, s_first;
  reg [31:0] gapcnt;
  reg [11:0] fill_lat;              // fill latched per frame
  reg [15:0] mcnt;                  // v2: 1-based index of the frame being generated
  reg        skip_lat;              // v2: this frame is the N-th (seq skips after it)
  reg        corrupt_lat;           // v2: this frame's magic byte is flipped

  // one xorshift round (matches qpsk_seq_payload byte step)
  function [31:0] xs; input [31:0] x; reg [31:0] a, b;
    begin a = x ^ (x << 13); b = a ^ (a >> 17); xs = b ^ (b << 5); end
  endfunction
  wire [31:0] pn_seed  = (seq ^ 32'h9E3779B9);
  wire [31:0] pn_init  = (pn_seed == 32'd0) ? 32'hDEADBEEF : pn_seed;

  wire        hit_cur   = nth_on && (mcnt == nth);
  wire [15:0] mcnt_nxt  = hit_cur ? 16'd1 : (mcnt + 16'd1);
  wire        hit_nxt   = nth_on && (mcnt_nxt == nth);
  wire        hit_first = nth_on && (nth == 16'd1);       // first frame after enable
  // the only edit on the seq/PN path: step 2 instead of 1 after an N-th frame
  wire [31:0] seq_next  = seq + (skip_lat ? 32'd2 : 32'd1);
  wire [31:0] pn_seed_n = seq_next ^ 32'h9E3779B9;

  // current header/pad/PN byte for bidx
  reg [7:0] cb;
  wire [31:0] pn_byte_w = xs(pn);
  always @* begin
    case (bidx)
      11'd0:  cb = corrupt_lat ? (8'h51 ^ 8'hFF) : 8'h51;  11'd1: cb = 8'h4B;
      11'd2:  cb = fill_lat[7:0];        11'd3: cb = {4'b0, fill_lat[11:8]};
      11'd4:  cb = seq[7:0];   11'd5: cb = seq[15:8];
      11'd6:  cb = seq[23:16]; 11'd7: cb = seq[31:24];
      11'd8:  cb = CRC_CONST[7:0];   11'd9:  cb = CRC_CONST[15:8];
      11'd10: cb = CRC_CONST[23:16]; 11'd11: cb = CRC_CONST[31:24];
      default: cb = (bidx < (HDR_BYTES + {1'b0,fill_lat})) ? pn_byte_w[7:0] : 8'h00;
    endcase
  end

  assign dut_data   = en_d ? sreg    : host_data;
  assign dut_valid  = en_d ? s_valid : host_valid;
  assign dut_first  = en_d ? s_first : host_first;
  assign host_ready = en_d ? 1'b0    : dut_ready;   // stall host while generating

  wire s_fire = s_valid && dut_ready;

  always @(posedge clk) begin
    if (!resetn) begin
      st <= S_IDLE; en_d <= 1'b0; seq <= 32'd1; s_valid <= 1'b0; s_first <= 1'b0;
      bidx <= 11'd0; gapcnt <= 32'd0; fill_lat <= 12'd0;
      mcnt <= 16'd1; skip_lat <= 1'b0; corrupt_lat <= 1'b0;
    end else begin
      // en_d switches the mux only at frame boundaries (never mid-frame)
      if (st == S_IDLE || st == S_GAP) en_d <= en;
      case (st)
        S_IDLE: if (en) begin
          seq <= 32'd1; fill_lat <= fill_len; pn <= pn_init;
          bidx <= 11'd0; st <= S_BUILD;
          mcnt <= 16'd1;
          skip_lat    <= !mode_corrupt && hit_first;
          corrupt_lat <=  mode_corrupt && hit_first;
        end
        S_BUILD: begin                       // 8 bytes -> one word
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
            s_first <= (bidx == 11'd8);      // word 0 just completed
          end else if (s_fire) begin
            s_valid <= 1'b0; s_first <= 1'b0;
            if (bidx == PKT_BYTES[10:0]) begin   // 1528: frame done
              gapcnt <= {5'd0, gap_clks}; st <= S_GAP;
            end else st <= S_BUILD;
          end
        end
        S_GAP: begin
          if (!en && gapcnt == 32'd0) st <= S_IDLE;        // clean stop point
          else if (gapcnt != 32'd0) gapcnt <= gapcnt - 32'd1;
          else begin                                        // next frame
            seq <= seq_next; fill_lat <= fill_len;
            pn <= (pn_seed_n == 32'd0) ? 32'hDEADBEEF : pn_seed_n;
            bidx <= 11'd0; st <= S_BUILD;
            mcnt        <= mcnt_nxt;
            skip_lat    <= !mode_corrupt && hit_nxt;
            corrupt_lat <=  mode_corrupt && hit_nxt;
          end
        end
      endcase
      if (st == S_IDLE && !en) begin
        seq <= 32'd1;                          // re-arm: seq restarts on next rise
        mcnt <= 16'd1; skip_lat <= 1'b0; corrupt_lat <= 1'b0;
      end
    end
  end
endmodule
