/* test_txq.c -- unit tests for the TX inter-transfer gap witness (txgap) and the
 * QPSK_TX_QUEUED idle-batching path of qpsk_tun.c. Same compile-time include trick as
 * test_k5.c (qpsk_tun.c with main() renamed, fake DMA regfile + TX ring). No hardware. */
#define _GNU_SOURCE
#include <assert.h>
#include <math.h>
#define main qpsk_tun_main
#include "qpsk_tun.c"
#undef main

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

static uint32_t fake_tx_regs[0x1000 / 4];
static unsigned char fake_txbuf[TX_SLOTS * TX_BATCH_STRIDE];

int main(void)
{
    /* ---- txgap_bin: monotonic, bounded ---- */
    { int last = -1, ok = 1;
      for (double us = 0; us < 5e6; us = us * 1.3 + 1) { int b = txgap_bin(us); if (b < last || b > 47) ok = 0; last = b; }
      CHECK(ok, "txgap_bin monotonic non-decreasing and <= 47");
      CHECK(txgap_bin(0) == 0, "bin(0) == 0");
      CHECK(txgap_bin_hi_us(txgap_bin(30.0)) >= 30.0, "bin upper edge covers the sample"); }

    /* ---- txgap_note accounting (F1536 period, synthetic clock) ---- */
    frame_period_s = 802.93e-6;
    memset(txgap_hist, 0, sizeof txgap_hist); txgap_n = txgap_empty = txgap_gt20 = txgap_gt50 = txgap_gt200 = 0;
    txgap_max_us = txgap_sum_us = 0; txgap_prev_t = 0; txgap_prev_frames = 0;
    double t = 100.0;
    txgap_note(0, 1, t);                       /* first submit: no previous -> nothing counted */
    CHECK(txgap_n == 1 && txgap_empty == 0, "first submit counts n only");
    t += 0.0002; txgap_note(1, 1, t);          /* queue busy: back-to-back, no gap */
    CHECK(txgap_empty == 0, "busy queue -> no gap sample");
    /* previous transfer (1 frame) submitted at t-0.0002 finishes at +period; we arrive 30 us late with an EMPTY queue */
    t = t + frame_period_s + 30e-6; txgap_note(0, 1, t);
    CHECK(txgap_empty == 1 && txgap_gt20 == 1 && txgap_gt50 == 0, "30 us late with empty queue -> gt20 only");
    CHECK(fabs(txgap_max_us - 30.0) < 1.0, "max_us ~30");
    /* a 5-frame batch was the previous transfer: finishing time uses 5 periods */
    txgap_note(1, 5, t + 0.0001);              /* submit a 5-frame batch while busy */
    t = t + 0.0001 + 5 * frame_period_s + 250e-6; txgap_note(0, 1, t);
    CHECK(txgap_empty == 2 && txgap_gt20 == 2 && txgap_gt50 == 1 && txgap_gt200 == 1, "250 us late after a 5-frame batch -> all three bins");
    CHECK(fabs(txgap_max_us - 250.0) < 1.0, "max_us ~250");
    /* early arrival with empty queue (fabric not yet done): clipped to 0, counted as empty */
    txgap_note(1, 1, t + 0.0001); t = t + 0.0001 + frame_period_s - 100e-6; txgap_note(0, 1, t);
    CHECK(txgap_empty == 3 && txgap_gt20 == 2, "early arrival clips to 0 (no new gt20)");
    CHECK(txgap_p99_us() >= 250.0, "p99 covers the 250 us sample");
    txgap_dump();
    CHECK(txgap_n == 0 && txgap_empty == 0 && txgap_gt20 == 0 && txgap_max_us == 0, "dump resets the window");

    /* ---- idle batching: N idle air frames in ONE transfer (K5 geometry, fake DMA) ---- */
    memset(&st, 0, sizeof st);
    txd.regs = fake_tx_regs; txbuf = fake_txbuf;
    memset(fake_tx_regs, 0, sizeof fake_tx_regs); memset(fake_txbuf, 0xEE, sizeof fake_txbuf);
    pkt_bytes = K5_PKT_BYTES; tx_xfer_bytes = K5_TX_XFER_BYTES; tx_slot_stride = TX_BATCH_STRIDE;
    tx_inflight = 0; tx_slot = 0; irq_mode = 1; max_inflight = 2;   /* irq_mode: never spin in a test */
    tx_idle_batch = 4;
    int nb = tx_idle_batch < tx_batch_max() ? tx_idle_batch : tx_batch_max();
    CHECK(nb == 4, "4 K5 idle frames fit one 4 KB stride");
    static unsigned char idles[TX_BATCH * QPSK_PKT_BYTES_MAX];
    for (int f = 0; f < nb; f++) qpsk_frame_encode(idles + f * pkt_bytes, pkt_bytes, NULL, 0, 0x1234u);
    fake_tx_regs[DMAC_TRANSFER_ID / 4] = 0;
    CHECK(tx_send_batch(idles, nb) == 0, "batch submit accepted");
    CHECK(fake_tx_regs[DMAC_X_LENGTH / 4] == (uint32_t)(nb * K5_TX_XFER_BYTES) - 1, "X_LENGTH = N air frames - 1");
    CHECK(fake_tx_regs[DMAC_FLAGS / 4] == DMAC_FLAG_TLAST, "FLAGS = TLAST (per-transfer tlast kept)");
    CHECK(fake_tx_regs[DMAC_SUBMIT / 4] == 1 && fake_tx_regs[DMAC_SRC_ADDRESS / 4] == TX_BUF_PHYS, "one SUBMIT at slot 0");
    { int ok = 1; unsigned char out[QPSK_PKT_BYTES_MAX]; uint32_t seq;
      for (int f = 0; f < nb; f++) {
          const unsigned char *fr = fake_txbuf + f * K5_TX_XFER_BYTES;
          if (qpsk_frame_decode(fr, pkt_bytes, out, &seq) != 0 || seq != 0x1234u) ok = 0;   /* idle frame at each 35-word boundary */
          for (int i = pkt_bytes; i < K5_TX_XFER_BYTES; i++) if (fr[i] != 0) ok = 0;         /* zero pad to the air frame */
      }
      CHECK(ok, "N idle frames air-aligned at tx_xfer_bytes boundaries, zero-padded"); }
    CHECK(tx_inflight == 1 && tx_slot == 1 && st.frames_tx == (uint64_t)nb, "one transfer in flight, N frames counted");
    /* second batch goes to slot 1 (no reuse of the in-flight slot) */
    fake_tx_regs[DMAC_TRANSFER_ID / 4] = 1;
    CHECK(tx_send_batch(idles, nb) == 0, "second batch accepted (queue depth 2)");
    CHECK(fake_tx_regs[DMAC_SRC_ADDRESS / 4] == TX_BUF_PHYS + TX_BATCH_STRIDE && tx_inflight == 2, "slot 1 used, 2 in flight");
    /* third: both in flight and nothing DONE -> refused (never overwrites a latched/running slot) */
    CHECK(tx_send_batch(idles, nb) == -1 && tx_inflight == 2 && tx_slot == 2, "third batch refused while 2 in flight");
    /* complete id 0 -> capacity returns, slot 2 used (ring advances, no reuse of slot 1 still latched) */
    fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 1u << 0; fake_tx_regs[DMAC_TRANSFER_ID / 4] = 2;
    CHECK(tx_send_batch(idles, nb) == 0 && fake_tx_regs[DMAC_SRC_ADDRESS / 4] == TX_BUF_PHYS + 2 * TX_BATCH_STRIDE, "after DONE[0], slot 2 submitted");
    CHECK(tx_inflight == 2, "reap of id 0 keeps depth at 2");
    /* legacy per-frame path unaffected when batching is off */
    tx_idle_batch = 0; fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 3u; fake_tx_regs[DMAC_TRANSFER_ID / 4] = 3;
    CHECK(tx_send(idles) == 0 && fake_tx_regs[DMAC_X_LENGTH / 4] == (uint32_t)K5_TX_XFER_BYTES - 1, "per-frame tx_send: X_LENGTH = one air frame");

    fprintf(stderr, "txq tests: %d run, %d failed\n", tests, fails);
    return fails ? 1 : 0;
}
