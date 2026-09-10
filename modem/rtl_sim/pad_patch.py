#!/usr/bin/env python3
"""pad_patch.py <tree>/ByteSerializer.v -- apply RXFIX_PAD (frame-length padding for truncated
frames) to a ByteSerializer.v that already carries RXFIX_BS.  Standalone banked copy of the patch
that produced rtl_sim/s1_rtl_pad on 2026-09-08 (ledger FWD_CRC_REGRESSION_0907 §47.6); the
rxfix_inject.py variant 'PAD' must reproduce this text exactly.  Refuses if RXFIX_PAD is present.
"""
import sys
def patch(p):
    s = open(p).read()
    assert 'RXFIX_PAD' not in s, 'RXFIX_PAD already present'
    assert 'RXFIX_BS' in s, 'expects the RXFIX_BS-tapped ByteSerializer'
    def sub(old, new):
        nonlocal s
        assert s.count(old) == 1, 'anchor not unique/found: ' + old[:60]
        s = s.replace(old, new)
    sub("  reg  firstNext_next;\n",
"""  reg  firstNext_next;
  // RXFIX_PAD -- frame-length padding for TRUNCATED frames (2026-09-08, ledger
  // FWD_CRC_REGRESSION_0907 §47.5).  A `start` arriving with state_wordCnt in 1..190
  // used to abandon the partial frame at (wordCnt) words.  Downstream the stream is
  // consumed in fixed 191-word frames by axi_dmac transfers with SYNC_TRANSFER_START,
  // and one short frame misaligns every later transfer boundary: the DMAC then holds
  // ready low waiting for a tuser beat the FIFO head cannot present, the FIFO fills
  // and drop-oldest walks the head to the next mark (191 - wordCnt words lost) -- 3
  // host frames per event, reproduced word-for-word in rtl_sim/run_dmac_sim_rtl.sh.
  // Here the truncated frame is instead PADDED to exactly 191 words with filler words
  // (all-zero: no magic, CRC fails at the host -> exactly one frame lost) before the
  // new frame's words are released; wordLast rides the last filler so wordFirst lands
  // on the new frame's word 0 exactly as for a clean boundary.  Real words that
  // complete while fillers are being emitted are queued (<= 3 can arrive: one per 64
  // bits against <= 190 filler beats) and released in order afterwards.
  reg [7:0]  pad;                 // filler words still to emit (0 = idle)
  reg [63:0] pq0, pq1, pq2;       // queued real words, oldest first
  reg        pl0, pl1, pl2;       // ... their wordLast flags
  reg [1:0]  pqn;                 // queue occupancy 0..3
  reg [7:0]  pad_1, pad_next;
  reg [63:0] pq0_1, pq1_1, pq2_1, pq0_next, pq1_next, pq2_next;
  reg        pl0_1, pl1_1, pl2_1, pl0_next, pl1_next, pl2_next;
  reg [1:0]  pqn_1, pqn_next;
  reg [63:0] w_r;                 // the real word completed this step (if wv_r)
  reg        wv_r, wl_r;
""")
    sub("""        heldFirst <= 1'b1;
        firstNext <= 1'b1;
      end
      else begin
        if (enb_1_2_0_gated) begin
          state_acc <= state_acc_next;""",
"""        heldFirst <= 1'b1;
        firstNext <= 1'b1;
        pad <= 8'd0; pq0 <= 64'd0; pq1 <= 64'd0; pq2 <= 64'd0;   // RXFIX_PAD
        pl0 <= 1'b0; pl1 <= 1'b0; pl2 <= 1'b0; pqn <= 2'd0;      // RXFIX_PAD
      end
      else begin
        if (enb_1_2_0_gated) begin
          pad <= pad_next; pq0 <= pq0_next; pq1 <= pq1_next; pq2 <= pq2_next;   // RXFIX_PAD
          pl0 <= pl0_next; pl1 <= pl1_next; pl2 <= pl2_next; pqn <= pqn_next;   // RXFIX_PAD
          state_acc <= state_acc_next;""")
    sub("  always @(bitIn, bitValid, firstNext, heldFirst, heldLast, heldWord, start, state_acc,\n       state_bitIdx, state_wordCnt, tog) begin\n",
        "  always @(bitIn, bitValid, firstNext, heldFirst, heldLast, heldWord, start, state_acc,\n       state_bitIdx, state_wordCnt, tog,\n       pad, pq0, pq1, pq2, pl0, pl1, pl2, pqn) begin   // RXFIX_PAD\n")
    sub("""    if (start) begin
      // packet boundary: discard any partial word, restart word counting
      state_acc_1 = 64'd0;
      a1 = 8'd0;
      state_wordCnt_1 = 16'd0;
    end
""", """    pad_1 = pad; pq0_1 = pq0; pq1_1 = pq1; pq2_1 = pq2;                // RXFIX_PAD
    pl0_1 = pl0; pl1_1 = pl1; pl2_1 = pl2; pqn_1 = pqn;                // RXFIX_PAD
    if (start) begin
      // RXFIX_PAD: a start with 1..190 words accumulated is a TRUNCATED frame --
      // schedule 191 - wordCnt filler words so the stream stays 191-word aligned.
      if ((pad_1 == 8'd0) && (state_wordCnt_1 >= 16'd1) && (state_wordCnt_1 <= 16'd190)) begin
        pad_1 = 8'd191 - state_wordCnt_1[7:0];
      end
      // packet boundary: discard any partial word, restart word counting
      state_acc_1 = 64'd0;
      a1 = 8'd0;
      state_wordCnt_1 = 16'd0;
    end
""")
    sub("""    state_acc_next = state_acc_1;
    state_bitIdx_next = a1;
    state_wordCnt_next = state_wordCnt_1;
    if (wv) begin
""", """    // RXFIX_PAD: what the core completed this step is the REAL word; the emitted
    // word (w/wv/wl below) is chosen by the pad/queue arbiter so that fillers and
    // earlier-queued words always precede it.
    w_r = w; wv_r = wv; wl_r = wl;
    w = 64'd0; wv = 1'b0; wl = 1'b0;
    if (pad_1 != 8'd0) begin
      // emit one filler; a real word completing now is queued
      w = 64'd0; wv = 1'b1; wl = (pad_1 == 8'd1);
      pad_1 = pad_1 - 8'd1;
      if (wv_r) begin
        case (pqn_1)
          2'd0: begin pq0_1 = w_r; pl0_1 = wl_r; pqn_1 = 2'd1; end
          2'd1: begin pq1_1 = w_r; pl1_1 = wl_r; pqn_1 = 2'd2; end
          2'd2: begin pq2_1 = w_r; pl2_1 = wl_r; pqn_1 = 2'd3; end
          default: ;   // queue full: cannot happen (<= 3 words per 190 beats)
        endcase
      end
    end
    else if (pqn_1 != 2'd0) begin
      // drain the queue in order; a real word completing now joins the tail
      w = pq0_1; wl = pl0_1; wv = 1'b1;
      pq0_1 = pq1_1; pl0_1 = pl1_1; pq1_1 = pq2_1; pl1_1 = pl2_1; pqn_1 = pqn_1 - 2'd1;
      if (wv_r) begin
        case (pqn_1)
          2'd0: begin pq0_1 = w_r; pl0_1 = wl_r; pqn_1 = 2'd1; end
          2'd1: begin pq1_1 = w_r; pl1_1 = wl_r; pqn_1 = 2'd2; end
          2'd2: begin pq2_1 = w_r; pl2_1 = wl_r; pqn_1 = 2'd3; end
          default: ;
        endcase
      end
    end
    else begin
      w = w_r; wv = wv_r; wl = wl_r;
    end
    pad_next = pad_1; pq0_next = pq0_1; pq1_next = pq1_1; pq2_next = pq2_1;
    pl0_next = pl0_1; pl1_next = pl1_1; pl2_next = pl2_1; pqn_next = pqn_1;
    state_acc_next = state_acc_1;
    state_bitIdx_next = a1;
    state_wordCnt_next = state_wordCnt_1;
    if (wv) begin
""")
    open(p, 'w').write(s)
    return 'patched'
if __name__ == '__main__':
    print('RXFIX_PAD', patch(sys.argv[1]))
