/* test_rxresync.c -- RXFIX Task 26: the RX carve re-anchor.
 *
 * Two layers, no hardware:
 *   1. the PURE scanner qpsk_frame_resync() -- offsets, bounds, whitening;
 *   2. the DEPLOYED drain path -- qpsk_tun.c's rx_pump_queued() driven against
 *      a fake DMA regfile and a synthetic carve, the same compile-time include
 *      trick test_k5.c / test_txq.c use (qpsk_tun.c with main() renamed).
 *
 * The synthetic carve reproduces the geometry Task 23 measured on silicon
 * (two_jup/comb/FWD_RESIDUAL_0p22.md): F1536 frames of 1528 B carved at a fixed
 * 1528 B stride out of one 16-slice DMA transfer, with 960 B deleted from the
 * byte stream part-way through, which puts every following frame at slot phase
 * 1528 - 960 = 568.
 *
 * Two claims are pinned here and nowhere else:
 *   * a displaced frame is SPLIT ACROSS TWO SLOTS (960 B in one, 568 B in the
 *     next), so a scan confined to a single slice can never validate it -- the
 *     re-anchor has to run over the contiguous carve.  The "one-slice window"
 *     check is the falsifier for that.
 *   * a comb-style failure (the W1 baseline: garbage, dominant magic offset 64)
 *     must NOT re-anchor and must be classified and counted exactly as before.
 *
 * Built with -DQPSK_CARVE_2MB so the carve geometry is the DEPLOYED one.
 */
#define _GNU_SOURCE
#include <assert.h>
#include <sys/wait.h>
#define main qpsk_tun_main
#include "qpsk_tun.c"
#undef main

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

#define PB    F1536_PKT_BYTES     /* 1528 -- the F1536 logical frame */
#define MULT  16                  /* deployed -M (bringup_r2r3.sh:171) */
#define PHASE 568                 /* the slot phase Task 23 measured */
#define DEL   (PB - PHASE)        /* 960 B deleted from the byte stream */

static uint32_t fake_rx_regs[0x1000 / 4];
static unsigned char fake_rxbuf[2u * RX_MULTI_MAX * SLOT_BYTES]
    __attribute__((aligned(8)));
static unsigned char tout[QPSK_FRAME_MAX_PAYLOAD(QPSK_PKT_BYTES_MAX)];

/* One wire frame with a FULL 1516 B payload keyed by seq.
 *
 * The payload length is load-bearing, not decoration.  The CRC32 covers only
 * header+payload, so a frame with a short payload survives being truncated in
 * the byte stream -- its CRC still validates off the surviving head and the
 * slot decodes as if nothing happened.  The deployed forward leg carries the
 * tun MTU (1516 B, QPSK_FRAME_MAX_PAYLOAD(1528)), which is why Task 23 sees
 * burst position 0 as a CRC-FAIL in 157 of 159 bursts.  Reproducing that means
 * reproducing the payload length. */
#define TPAY QPSK_FRAME_MAX_PAYLOAD(PB)          /* 1516 */
static void mkframe(unsigned char *dst, uint32_t seq)
{
    static unsigned char pay[TPAY];
    int i;
    for (i = 0; i < TPAY; i++)
        pay[i] = (unsigned char)(seq * 7u + (uint32_t)i);
    qpsk_frame_encode(dst, PB, pay, TPAY, seq);
}

/* Fill the drain area with back-to-back frames, seq 0,1,2,...  When
 * del_after >= 0, frame number del_after is truncated to PHASE bytes -- DEL
 * bytes deleted from the stream -- and everything after it slides back by DEL,
 * which is exactly the displacement the forward leg shows.  Returns the number
 * of WHOLE frames written inside the DMA-written region. */
static int fill_area(int del_after)
{
    static unsigned char fr[PB];
    size_t limit = (size_t)MULT * PB;
    size_t w = 0;
    uint32_t seq = 0;
    int whole = 0;

    memset(fake_rxbuf, 0, sizeof fake_rxbuf);
    while (w < limit) {
        size_t n = PB;
        mkframe(fr, seq);
        if (del_after >= 0 && seq == (uint32_t)del_after)
            n = PHASE;                    /* this frame loses its last DEL bytes */
        if (w + n > limit) n = limit - w;
        memcpy(fake_rxbuf + w, fr, n);
        if (n == (size_t)PB) whole++;
        w += n;
        seq++;
    }
    return whole;
}

/* Overwrite one slot with W1-baseline comb garbage: high-entropy bytes with the
 * frame magic at offset 64 (the offset the W1 comb actually shows) and no valid
 * frame anywhere. */
static void comb_slot(int slot)
{
    unsigned char *p = fake_rxbuf + (size_t)slot * PB;
    int i;
    for (i = 0; i < PB; i++)
        p[i] = (unsigned char)(i * 37 + slot * 11 + 3);
    p[64] = 0x51; p[65] = 0x4B;
}

/* Drive the deployed drain to exhaustion.  Returns frames delivered with
 * payload; *lost receives st.crc_drops over the run. */
static int drain_all(int resync_on, unsigned long long *lost)
{
    uint32_t seq;
    int delivered = 0, guard = 4 * MULT + 8;

    memset(&st, 0, sizeof st);
    rxr_568 = rxr_other = rxr_fail = rxr_recovered = rxr_tail = 0;
    memset(fake_rx_regs, 0, sizeof fake_rx_regs);
    rxd.regs = fake_rx_regs;
    rxbuf = fake_rxbuf;
    pkt_bytes = PB;
    rx_multi = MULT;
    rx_nareas = 2;
    rx_area_stride = (uint32_t)(2u * RX_MULTI_MAX * SLOT_BYTES) / 2u;
    rx_queued = 1;
    rx_cyclic = 0;
    rx_resync = resync_on;
    rx_drain_budget = 0;                  /* unbounded: historical drain */
    rx_active = 1;
    rx_fill = 1;
    rx_fscan = rx_multi;                  /* eager path exhausted -> drain only */
    rx_qd = -1;
    rx_q_defer = -1;
    rx_clean_mask = 0;
    rx_drain = 0;
    rx_dscan = 0;
    rx_dphase = 0;
    rx_q_progress = rx_q_delivered = now_s();

    while (rx_drain >= 0 && guard-- > 0) {
        int m = rx_pump_queued(tout, &seq);
        if (m > 0) delivered++;
    }
    if (lost) *lost = st.crc_drops;
    return delivered;
}

/* The whitened wire format.  qpsk_whiten_on() caches its answer process-wide
 * and every qpsk_frame_encode() latches it, so the whitened case only means
 * anything in a process that has not yet touched the framer -- hence a child
 * forked before any other check runs. */
static int whitened_child(void)
{
    static unsigned char wb[PB], ww[2 * PB], wo[TPAY];
    uint32_t ws = 0;
    int wl = -1, wd;

    setenv("QPSK_WHITEN", "1", 1);
    if (!qpsk_whiten_on())
        return 2;
    memset(ww, 0x33, sizeof ww);
    mkframe(wb, 0x4242u);
    memcpy(ww + PHASE, wb, PB);
    wd = qpsk_frame_resync(ww, sizeof ww, PB, PB - QPSK_RESYNC_STEP,
                           wo, &ws, &wl);
    return (wd == PHASE && ws == 0x4242u && wl == TPAY) ? 0 : 1;
}

int main(void)
{
    unsigned char frm[PB];
    unsigned char win[2 * PB];
    uint32_t seq;
    int d, len;

    /* ---- 0. whitened wire format (must precede any framer call here) ---- */
    {   pid_t pid = fork();
        int status = 1;
        if (pid == 0)
            _exit(whitened_child());
        if (pid > 0) waitpid(pid, &status, 0);
        CHECK(pid > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0,
              "whitened wire format re-anchors at 568 (forked child, QPSK_WHITEN=1)"); }

    /* ================= 1. the pure scanner ================= */

    /* 1a. the measured case: a whole frame at phase 568 of a window that starts
     *     on the slot the parser rejected. */
    memset(win, 0xA5, sizeof win);
    mkframe(frm, 0x1234u);
    memcpy(win + PHASE, frm, PB);
    len = -1;
    d = qpsk_frame_resync(win, sizeof win, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d == PHASE, "resync finds the frame at the measured 568 B phase");
    CHECK(seq == 0x1234u && len == TPAY, "recovered frame decodes with its own seq/len");

    /* 1b. A SINGLE SLICE CANNOT HOLD IT.  At phase 568 only PB-568 = 960 of the
     *     frame's 1528 bytes are inside the slice the parser rejected, so any
     *     scan bounded to one slice must fail.  This is precisely why the fix
     *     re-anchors a byte cursor into the CONTIGUOUS carve rather than
     *     scanning a slice, and it is the check that separates a working fix
     *     from one that counts re-anchors and recovers nothing. */
    CHECK(PB - PHASE == 960, "at phase 568 only 960 of 1528 bytes are in the slice");
    d = qpsk_frame_resync(win, (size_t)PB, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d < 0, "a one-slice window cannot validate the displaced frame");

    /* 1c. the bound: a frame at exactly +pkt_bytes is the ORDINARY next slot,
     *     never a re-anchor.  Without this bound every isolated failure would
     *     be miscounted as a re-anchor. */
    memset(win, 0x5A, sizeof win);
    mkframe(frm, 0x777u);
    memcpy(win + PB, frm, PB);
    d = qpsk_frame_resync(win, sizeof win, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d < 0, "a frame at exactly +pkt_bytes is NOT reported as a re-anchor");

    /* 1d. word granularity.  Not a tuning choice: carve_copy_from() reads the
     *     carve with 64-bit volatile loads and an unaligned one FAULTS on ARM64
     *     Device memory. */
    memset(win, 0x5A, sizeof win);
    memcpy(win + PHASE + 1, frm, PB);
    d = qpsk_frame_resync(win, sizeof win, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d < 0, "a frame at an unaligned offset is not re-anchored to");
    CHECK(PHASE % QPSK_RESYNC_STEP == 0 && 376 % QPSK_RESYNC_STEP == 0 &&
          1136 % QPSK_RESYNC_STEP == 0,
          "every measured offset (568/376/1136) is a whole 64-bit word");

    /* 1e. garbage: nothing found, no false positive. */
    { int i; for (i = 0; i < (int)sizeof win; i++)
          win[i] = (unsigned char)(i * 131 + 17); }
    d = qpsk_frame_resync(win, sizeof win, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d < 0, "garbage produces no re-anchor");

    /* 1f. a recovered IDLE frame (len 0) is a valid recovery. */
    memset(win, 0x00, sizeof win);
    qpsk_frame_encode(frm, PB, NULL, 0, 0x99u);
    memcpy(win + 8, frm, PB);
    len = -1;
    d = qpsk_frame_resync(win, sizeof win, PB, PB - QPSK_RESYNC_STEP,
                          tout, &seq, &len);
    CHECK(d == 8 && len == 0 && seq == 0x99u, "an idle frame re-anchors at len 0");

    /* 1g. degenerate inputs are refused, not crashed. */
    CHECK(qpsk_frame_resync(NULL, 100, PB, 8, tout, &seq, &len) < 0, "NULL buf refused");
    CHECK(qpsk_frame_resync(win, 4, PB, 8, tout, &seq, &len) < 0, "tiny window refused");
    CHECK(qpsk_frame_resync(win, sizeof win, 100, 8, tout, &seq, &len) < 0,
          "pkt_bytes not a multiple of 8 refused (no unaligned carve reads)");

    /* ================= 2. the deployed drain path ================= */

    /* 2a. CLEAN area: the no-defect control.  Proves the cursor change is inert
     *     when nothing is displaced. */
    { unsigned long long lost; int n;
      fill_area(-1);
      n = drain_all(1, &lost);
      CHECK(n == MULT && lost == 0, "clean area: 16 delivered, 0 lost");
      CHECK(rxr_568 == 0 && rxr_other == 0 && rxr_fail == 0 && rxr_tail == 0,
            "clean area: no re-anchor, no scan, no tail loss");
      CHECK(rx_dphase == 0, "clean area leaves the cursor aligned"); }

    /* 2b/2c. THE DEFECT and THE FIX on the same bytes. */
    { unsigned long long lost_off, lost_on; int n_off, n_on;
      int whole = fill_area(5);
      CHECK(whole == 15, "synthetic stream carries 15 whole frames after the deletion");

      n_off = drain_all(0, &lost_off);            /* historical parser */
      CHECK(n_off == 5, "resync OFF: only the 5 aligned frames survive");
      CHECK(lost_off == MULT - 5, "resync OFF: 11 slots lost from ONE deletion");
      CHECK(rxr_568 == 0 && rxr_recovered == 0,
            "resync OFF: no re-anchor accounting at all");
      CHECK(rx_dphase == 0, "resync OFF: the cursor never leaves phase 0");

      fill_area(5);
      n_on = drain_all(1, &lost_on);              /* the fix */
      CHECK(lost_on == 1, "resync ON: exactly ONE frame lost (the damaged one)");
      CHECK(n_on == 15, "resync ON: 15 of 16 frames delivered");
      CHECK(rxr_568 == 1, "resync ON: exactly one re-anchor, at 568 B");
      CHECK(rxr_other == 0, "resync ON: no re-anchor at any other offset");
      CHECK(rxr_tail == 1, "resync ON: one transfer tail given up");
      CHECK(rxr_recovered == 10, "resync ON: 10 frames delivered from a displaced phase");
      CHECK(lost_off - lost_on == 10, "the fix recovers 10 of the 11 lost slots"); }

    /* 2d. the phase MUST be cleared wherever a new area reaches the drain: a
     *     stale phase would CAUSE loss on the next transfer instead of fixing
     *     it, and would read as "the fix made things worse". */
    { fill_area(5);
      drain_all(1, NULL);
      CHECK(rx_dphase == PHASE, "cursor is left displaced at the end of the burst");
      rx_fscan = 0; rx_fill = 0; rx_qd = -1; rx_clean_mask = 0; rx_t0 = now_s();
      rx_q_on_complete();
      CHECK(rx_dphase == 0,
            "rx_q_on_complete re-anchors: every transfer starts on a tuser frame sync");
      rx_dphase = PHASE;
      rx_arm_queued();
      CHECK(rx_dphase == 0, "rx_arm_queued clears the phase"); }

    /* 2e. THE W1 BASELINE COMB is classified and counted exactly as before. */
    { unsigned long long lost_on, lost_off; int n_on, n_off;
      uint32_t fzo = 0;
      fill_area(-1); comb_slot(3); comb_slot(7); comb_slot(11);
      CHECK(qpsk_fail_class(fake_rxbuf + 3 * PB, PB, &fzo) == QPSK_FC_MAGIC,
            "comb slice still classifies as MAGIC (class 1)");
      CHECK(qpsk_first_magic_off(fake_rxbuf + 3 * PB, PB) == 64,
            "comb slice still reports magic_off 64");
      n_on = drain_all(1, &lost_on);
      CHECK(n_on == MULT - 3 && lost_on == 3,
            "comb: 3 lost / 13 delivered with resync ON");
      CHECK(rxr_568 == 0 && rxr_other == 0 && rxr_recovered == 0,
            "comb: no re-anchor -- those frames are corrupt, not shifted");
      CHECK(rxr_fail == 3, "comb: three scans ran and correctly found nothing");
      CHECK(rxr_tail == 0, "comb: alignment never lost, so no tail loss");
      fill_area(-1); comb_slot(3); comb_slot(7); comb_slot(11);
      n_off = drain_all(0, &lost_off);
      CHECK(n_off == n_on && lost_off == lost_on,
            "comb: resync ON and OFF give identical accounting"); }

    /* 2f. the bound on what the fix can do: a displacement in the LAST slot
     *     costs one frame either way -- there is no room left to re-anchor in. */
    { unsigned long long lost; int n;
      fill_area(MULT - 1);
      n = drain_all(1, &lost);
      CHECK(n == MULT - 1 && lost == 1,
            "deletion in the last slot: 1 lost, nothing to re-anchor to");
      CHECK(rxr_568 == 0, "no re-anchor when the transfer has no room left"); }

    fprintf(stderr, "test_rxresync: %d checks, %d failures\n", tests, fails);
    return fails ? 1 : 0;
}
