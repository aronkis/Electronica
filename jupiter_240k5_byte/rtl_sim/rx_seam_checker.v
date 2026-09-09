// rx_seam_checker -- in-fabric per-frame CRC verdict at the DUT RX byte pins
// (decoder output, BEFORE the seam injector / breakout / axi_dmac). Decouples
// the demod+Viterbi verdict from the delivery plane (DMA/DDR/host) on silicon.
//
// SNOOP-ONLY: observes {data, valid, user} and the DUT-side ready, counting
// ACCEPTED words only (valid && ready). Frame = user-marked word + 190 more
// (1528 B = 191 x 64-bit words, bytes little-endian within a word).
// Verdict per frame (qpsk_frame.c contract): bytes [0..1] = 'Q','K' magic,
// [2..3] len (LE, 12 bits used), [4..7] seq, [8..11] CRC32 (zlib polynomial,
// init/final 0xFFFFFFFF, reflected) over bytes [0 .. 12+len-1] with the CRC
// field zeroed. len > 1516 -> magic_bad. TGEN-format frames (CRC constant
// 0x54474E21 instead of a CRC) count as crc_fail by construction -- use the
// counters only when the far TX sends real frames (daemon / ROM->daemon) or
// read them as "frames seen" only.
// 8 bytes of CRC per accepted word (64-bit parallel, unrolled bitwise).
//
// Counters (free-running from reset, host reads deltas):
//   frames     user-marked words seen (frames started)
//   crc_ok     magic ok, len ok, CRC matches
//   crc_fail   magic ok, len ok, CRC mismatch
//   magic_bad  magic/len not parseable (filler / junk frames)
//   short_frm  a user word arrived before word 191 of the previous frame
//   orphan_w   accepted words beyond word 191 without a new user mark
`timescale 1ns/1ps
module rx_seam_checker (
  input  wire        clk,
  input  wire        resetn,
  input  wire [63:0] data,
  input  wire        valid,
  input  wire        user,
  input  wire        ready,
  output reg  [31:0] frames,
  output reg  [31:0] crc_ok,
  output reg  [31:0] crc_fail,
  output reg  [31:0] magic_bad,
  output reg  [31:0] short_frm,
  output reg  [31:0] orphan_w
);
  localparam integer WORDS = 191;
  wire acc = valid && ready;

  // CRC32 (reflected, poly 0xEDB88320) over 8 bytes, byte 0 first
  function [31:0] crc8b; input [31:0] c; input [7:0] b; integer i; reg [31:0] x;
    begin x = c ^ {24'd0, b}; for (i = 0; i < 8; i = i + 1) x = (x >> 1) ^ (x[0] ? 32'hEDB88320 : 32'd0); crc8b = x; end
  endfunction
  function [31:0] crc64; input [31:0] c; input [63:0] w; integer k; reg [31:0] x;
    begin x = c; for (k = 0; k < 8; k = k + 1) x = crc8b(x, w[8*k +: 8]); crc64 = x; end
  endfunction
  // CRC over only the first n (1..8) bytes of a word (frame tail)
  function [31:0] crcpart; input [31:0] c; input [63:0] w; input [3:0] n; integer k; reg [31:0] x;
    begin x = c; for (k = 0; k < 8; k = k + 1) if (k < n) x = crc8b(x, w[8*k +: 8]); crcpart = x; end
  endfunction

  reg verdict_done;
  reg [7:0]  widx;        // word index within frame, 0..191 (191 = complete)
  reg        inframe;
  reg [31:0] crc;
  reg [31:0] crc_field;
  reg [11:0] len;
  reg        hdr_ok;
  reg [10:0] used_bytes;  // 12 + len (<= 1528)
  wire [63:0] w1z = {data[63:32], 32'd0};  // word 1 with the CRC field (bytes 8..11 = low half of word 1) zeroed
  wire [11:0] len_w = data[27:16];         // bytes 2..3 (LE) -> [2]=data[23:16], [3]=data[31:24]; 12 bits used
  wire        magic_w = (data[7:0] == 8'h51) && (data[15:8] == 8'h4B) && (len_w <= 12'd1516);
  // bytes covered by word i: [8i .. 8i+7]; last covered byte = used_bytes-1
  wire [10:0] wbase = {widx, 3'b000};
  wire [11:0] remain = {1'b0, used_bytes} - {1'b0, wbase};   // bytes still to cover starting at this word

  always @(posedge clk) begin
    if (!resetn) begin
      frames <= 0; crc_ok <= 0; crc_fail <= 0; magic_bad <= 0; short_frm <= 0; orphan_w <= 0;
      widx <= 8'd0; inframe <= 1'b0; crc <= 32'hFFFFFFFF; hdr_ok <= 1'b0; used_bytes <= 11'd0; crc_field <= 0; len <= 0;
    end else if (acc) begin
      if (user) begin
        frames <= frames + 1;
        if (inframe && widx != WORDS) short_frm <= short_frm + 1;
        // start new frame: header word
        inframe <= 1'b1; widx <= 8'd1;
        hdr_ok <= magic_w; len <= len_w;
        used_bytes <= 11'd12 + {1'b0, len_w[10:0]};
        crc <= crc64(32'hFFFFFFFF, data);
      end else if (!inframe || widx == WORDS) begin
        orphan_w <= orphan_w + 1;
      end else begin
        // body word widx (1..190); word 1 carries the CRC field in its low 32 bits
        if (widx == 8'd1) begin crc_field <= data[31:0]; crc <= (remain >= 12'd8) ? crc64(crc, w1z) : crcpart(crc, w1z, remain[3:0]); end
        else if (wbase >= used_bytes) ;                       // past the used bytes: padding, not covered
        else if (remain >= 12'd8) crc <= crc64(crc, data);
        else crc <= crcpart(crc, data, remain[3:0]);
        if (widx == WORDS - 1) begin
          // frame complete at this word: verdict uses crc after this word
          inframe <= 1'b1; widx <= WORDS;
        end else widx <= widx + 1;
      end
    end
    // verdict one cycle after the last word (crc register settled)
    if (resetn && inframe && widx == WORDS && !verdict_done) begin
      verdict_done <= 1'b1;
      if (!hdr_ok) magic_bad <= magic_bad + 1;
      else if ((crc ^ 32'hFFFFFFFF) == crc_field) crc_ok <= crc_ok + 1;
      else crc_fail <= crc_fail + 1;
    end
    if (!resetn || (acc && user)) verdict_done <= 1'b0;
  end

endmodule
