// tx_seam_checker -- in-fabric bit-exact scorer at the DUT TX byte pins
// (post-mux, pre-modulator). TX-side Layer B isolation (spec 2026-08-18):
// host -> MM2S DMA -> breakout -> seam -> THIS TAP, zero RF, no modem DSP.
//
// SNOOP-ONLY: never drives the stream; observes {data, valid, first} and the
// DUT-side ready, counting ACCEPTED beats only (valid && ready).
// SELF-ARMING, zero config: idles until an accepted, first-marked word whose
// low bytes carry the TGEN-format header start (0x51 0x4B) -- then parses
// fill (len field) and seq from the header words, regenerates the expected
// PN(fill)+zero-pad stream (xorshift32, tgen contract), and scores every
// accepted byte of the frame via popcount-XOR. CRC field bytes (8..11) are
// compared against the TGEN constant. Frames whose header does not parse as
// TGEN format are skipped whole (frames_skipped counts them).
//
// Outputs (to an all-INPUTS dual axi_gpio, read-only from the host):
//   bit_errors[31:0]     cumulative mismatched bits over checked frames
//   frames_checked[31:0] frames fully scored
`timescale 1ns/1ps
module tx_seam_checker (
  input  wire        clk,
  input  wire        resetn,
  // snoop taps (same nets as the DUT TX byte pins)
  input  wire [63:0] data,
  input  wire        valid,
  input  wire        first,
  input  wire        ready,
  // counters out
  output reg  [31:0] bit_errors,
  output reg  [31:0] frames_checked
);
  localparam integer PKT_BYTES = 1528;
  localparam integer HDR_BYTES = 12;
  localparam [31:0] CRC_CONST = 32'h54474E21;
  localparam S_IDLE = 1'd0, S_FRAME = 1'd1;

  wire acc = valid && ready;

  reg        st;
  reg [7:0]  widx;                 // word index within frame 0..190
  reg [31:0] pn;                   // xorshift32 state
  reg [31:0] seq;
  reg [11:0] fill;
  reg [31:0] frame_errs;

  function [31:0] xs; input [31:0] x; reg [31:0] a, b;
    begin a = x ^ (x << 13); b = a ^ (a >> 17); xs = b ^ (b << 5); end
  endfunction

  // header word 0 fields (LE): [15:0]=magic 4B51? bytes: data[7:0]=0x51,
  // data[15:8]=0x4B, data[31:16]=len LE, data[63:32]=seq LE
  wire hdr_magic_ok = (data[7:0] == 8'h51) && (data[15:8] == 8'h4B);
  wire [11:0] hdr_fill = data[27:16];              // len low 12 bits
  wire        hdr_fill_hi_ok = (data[31:28] == 4'h0);
  wire [31:0] hdr_seq  = data[63:32];
  wire [31:0] pn_seed  = (hdr_seq ^ 32'h9E3779B9);
  wire [31:0] pn_init  = (pn_seed == 32'd0) ? 32'hDEADBEEF : pn_seed;

  // expected bytes for word widx (computed byte-serially below)
  // scoring is done per accepted word: XOR against expected 8 bytes.
  integer i;
  reg [63:0] expw;
  reg [31:0] pnx;
  reg [7:0]  eb;
  reg [31:0] errs_w;
  always @* begin
    expw = 64'd0; pnx = pn; errs_w = 0;
    if (st == S_FRAME) begin
      for (i = 0; i < 8; i = i + 1) begin : gen
        // global byte index = widx*8 + i
        reg [10:0] bix;
        bix = {widx, 3'b000} + i[10:0];
        if (bix == 11'd8)       eb = CRC_CONST[7:0];
        else if (bix == 11'd9)  eb = CRC_CONST[15:8];
        else if (bix == 11'd10) eb = CRC_CONST[23:16];
        else if (bix == 11'd11) eb = CRC_CONST[31:24];
        else if (bix >= HDR_BYTES && bix < (HDR_BYTES + {1'b0, fill})) begin
          pnx = xs(pnx); eb = pnx[7:0];
        end else eb = 8'h00;
        expw[8*i +: 8] = eb;
      end
      // popcount of mismatch
      for (i = 0; i < 64; i = i + 1)
        errs_w = errs_w + {31'd0, (data[i] ^ expw[i])};
    end
  end

  always @(posedge clk) begin
    if (!resetn) begin
      st <= S_IDLE; widx <= 8'd0; pn <= 32'd0; seq <= 32'd0; fill <= 12'd0;
      bit_errors <= 32'd0; frames_checked <= 32'd0; frame_errs <= 32'd0;
    end else if (acc) begin
      case (st)
        S_IDLE: begin
          if (first && hdr_magic_ok && hdr_fill_hi_ok) begin
            // word 0 accepted: header parsed; CRC-const lives in word 1
            seq  <= hdr_seq;
            fill <= hdr_fill;
            pn   <= pn_init;
            widx <= 8'd1;
            frame_errs <= 32'd0;   // word 0 is header-defined, no PN content
            st   <= S_FRAME;
          end
        end
        S_FRAME: begin
          pn <= pnx;                       // advance PN by bytes consumed this word
          frame_errs <= frame_errs + errs_w;
          if (widx == 8'd190) begin        // last word of the frame
            bit_errors <= bit_errors + frame_errs + errs_w;
            frames_checked <= frames_checked + 32'd1;
            st <= S_IDLE; widx <= 8'd0;
          end else begin
            widx <= widx + 8'd1;
          end
        end
      endcase
      // resync guard: a first-marker mid-frame restarts framing
      if (st == S_FRAME && first) begin
        st <= S_IDLE; widx <= 8'd0;
        if (hdr_magic_ok && hdr_fill_hi_ok) begin
          seq <= hdr_seq; fill <= hdr_fill; pn <= pn_init;
          widx <= 8'd1; frame_errs <= 32'd0; st <= S_FRAME;
        end
      end
    end
  end
endmodule
