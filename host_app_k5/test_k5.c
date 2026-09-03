/* test_k5.c -- unit tests for the -F two-radio K5 path of qpsk_tun.c.
 *
 * Compile-time include trick (same family as test_frame.c's contract
 * tests): pull in qpsk_tun.c with its main() renamed, then drive the Tx
 * and Rx paths against fake in-memory DMA register files and buffers --
 * no /dev/mem, no hardware, runs on the dev host via `make test`.
 *
 * Covers:
 *   - K5 frame geometry (128 B unit = 16 x 64-bit words; 12 B header +
 *     116 B payload fits exactly; frame period 1133 sym / 240 ksym)
 *   - rx period calibration window admits the 4.72 ms K5 frame period
 *   - idle (len=0) keepalive frame encode/decode round trip
 *   - tx_send submits one 128-byte one-shot with per-transfer TLAST
 *     (FLAGS=0x2) and the exact payload bytes
 *   - rx_pump_frame consumes idle frames (counted, not delivered) and
 *     delivers data frames
 */
#define _GNU_SOURCE     /* qpsk_tun.c uses ppoll */
#include <assert.h>
#include <math.h>

#define main qpsk_tun_main          /* rename qpsk_tun.c's entry point */
#include "qpsk_tun.c"
#undef main

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

/* fake hardware: DMA regfiles + Tx ring + Rx landing areas */
static uint32_t fake_tx_regs[0x1000 / 4];
static uint32_t fake_rx_regs[0x1000 / 4];
static unsigned char fake_txbuf[TX_SLOTS * SLOT_BYTES];
static unsigned char fake_rxbuf[2u * RX_MULTI_MAX * SLOT_BYTES];

int main(void)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    unsigned char payload[QPSK_PKT_BYTES_MAX];
    uint32_t seq;
    int i, n;

    /* ---- geometry ---- */
    CHECK(K5_PKT_BYTES == 128, "K5 unit is 128 bytes");
    CHECK(K5_PKT_BYTES % 8 == 0, "K5 unit is a whole number of 64-bit words");
    CHECK(K5_PKT_BYTES / 8 == 16, "K5 unit is 16 x 64-bit words");
    CHECK(QPSK_FRAME_MAX_PAYLOAD(K5_PKT_BYTES) == 116,
          "12 B header + 116 B payload fits exactly in 128");
    CHECK(fabs(K5_FRAME_S - 1133.0 / 240e3) < 5e-6,
          "frame period is 1133 symbols / 240 ksym");
    CHECK(1.0 / K5_FRAME_S > 205.0 && 1.0 / K5_FRAME_S < 220.0,
          "keepalive rate limit ~212 frames/s");

    /* ---- rx period calibration window ---- */
    CHECK(RX_PER_CAL_MAX > K5_FRAME_S, "cal window admits the K5 period");
    CHECK(RX_PER_CAL_MAX <= 8e-3, "cal upper bound per plan");
    CHECK(RX_PER_CAL_MIN < 632e-6, "cal window still admits legacy rates");

    /* ---- idle keepalive frame (len=0, valid CRC) ---- */
    pkt_bytes = K5_PKT_BYTES;
    tx_xfer_bytes = K5_TX_XFER_BYTES;   /* K5 pads each TX to a 35-word air frame */
    n = qpsk_frame_encode(pkt, pkt_bytes, NULL, 0, 0xA5A50001u);
    CHECK(n == pkt_bytes, "idle encode fills one 128 B unit");
    n = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
    CHECK(n == 0, "idle decodes to 0 (nothing delivered)");
    CHECK(seq == 0xA5A50001u, "idle seq preserved");
    pkt[5] ^= 0x10;
    CHECK(qpsk_frame_decode(pkt, pkt_bytes, out, &seq) < 0,
          "corrupt idle rejected");
    pkt[5] ^= 0x10;

    /* ---- Tx path: 128 B logical unit padded to a 280 B / 35-word air frame,
     *      per-transfer TLAST (silicon contract: a 16-word/128 B transfer
     *      decodes to garbage; only a whole 35-word/280 B air frame works) ---- */
    memset(&st, 0, sizeof st);
    txd.regs = fake_tx_regs;
    txbuf = fake_txbuf;
    fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0;   /* nothing completed yet */
    fake_tx_regs[DMAC_TRANSFER_ID / 4] = 0;

    for (i = 0; i < 116; i++) payload[i] = (unsigned char)(i * 5 + 1);
    n = qpsk_frame_encode(pkt, pkt_bytes, payload, 116, 77);
    CHECK(n == pkt_bytes, "data encode fills one unit");
    CHECK(tx_send(pkt) == 0, "tx_send accepts the unit");
    CHECK(fake_tx_regs[DMAC_X_LENGTH / 4] == (uint32_t)K5_TX_XFER_BYTES - 1,
          "X_LENGTH = 280-1 (one 35-word air frame per radio frame)");
    CHECK(fake_tx_regs[DMAC_FLAGS / 4] == DMAC_FLAG_TLAST,
          "FLAGS = 0x2 (per-transfer TLAST only)");
    CHECK(fake_tx_regs[DMAC_SUBMIT / 4] == 1, "transfer submitted");
    CHECK(fake_tx_regs[DMAC_SRC_ADDRESS / 4] == TX_BUF_PHYS,
          "slot 0 physical address");
    CHECK(memcmp(fake_txbuf, pkt, (size_t)pkt_bytes) == 0,
          "logical unit copied verbatim into the head of the air frame");
    { int pad_ok = 1;
      for (i = pkt_bytes; i < K5_TX_XFER_BYTES; i++)
          if (fake_txbuf[i] != 0) { pad_ok = 0; break; }
      CHECK(pad_ok, "air-frame tail is zero-padded"); }
    CHECK(st.frames_tx == 1 && tx_inflight == 1, "one frame in flight");

    /* second unit lands in slot 1; then completion reaps both */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 32, 78);
    CHECK(tx_send(pkt) == 0, "second unit accepted (MAX_INFLIGHT=2)");
    CHECK(fake_tx_regs[DMAC_SRC_ADDRESS / 4] == TX_BUF_PHYS + SLOT_BYTES,
          "slot 1 physical address");
    fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0xFFFFFFFFu;
    tx_reap();
    CHECK(tx_inflight == 0, "completions reaped");

    /* idle keepalive rides the same path */
    qpsk_frame_encode(pkt, pkt_bytes, NULL, 0, 79);
    CHECK(tx_send(pkt) == 0, "idle unit accepted");
    CHECK(fake_tx_regs[DMAC_X_LENGTH / 4] == (uint32_t)K5_TX_XFER_BYTES - 1 &&
          fake_tx_regs[DMAC_FLAGS / 4] == DMAC_FLAG_TLAST,
          "idle unit uses the same 35-word TLAST one-shot");

    /* ---- Rx path (legacy per-packet): idle consumed, data delivered ---- */
    memset(&st, 0, sizeof st);
    rxd.regs = fake_rx_regs;
    rxbuf = fake_rxbuf;
    rx_multi = 0;
    rx_active = 0;
    n = rx_pump_frame(out, &seq);       /* first call arms only */
    CHECK(n == 0 && rx_active, "first pump arms the engine");

    fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 1;    /* pretend landed */
    qpsk_frame_encode(fake_rxbuf, pkt_bytes, NULL, 0, 500);
    n = rx_pump_frame(out, &seq);
    CHECK(n == 0, "idle frame not delivered to tun");
    CHECK(st.idle_rx == 1, "idle frame counted");
    CHECK(st.crc_drops == 0, "idle frame is NOT a crc drop");

    fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 1;
    qpsk_frame_encode(fake_rxbuf, pkt_bytes, payload, 116, 501);
    n = rx_pump_frame(out, &seq);
    CHECK(n == 116, "data frame delivered");
    CHECK(seq == 501, "data seq recovered");
    CHECK(memcmp(out, payload, 116) == 0, "data payload intact");

    fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 1;
    memset(fake_rxbuf, 0x5A, (size_t)pkt_bytes);  /* garbage slice */
    n = rx_pump_frame(out, &seq);
    CHECK(n == 0 && st.crc_drops == 1, "garbage slice counted as crc drop");

    /* ---- Rx QUEUED-request mode (QPSK_RX_QUEUED path) ----
     * Models the axi_dmac semantics the driver relies on: SUBMIT reads the pending-
     * request latch (test clears it to model acceptance at SOT), DONE is a per-ID
     * bitmap. Asserts the design's core properties: the next transfer is queued in
     * hardware BEFORE the fill transfer completes (no reset, no host in the gap),
     * in-order delivery, drain->requeue, stale-done-bit immunity, and the watchdog. */
    {
        const int K = 4;
        const uint32_t CTRL_SENTINEL = 0x77u;
        memset(&st, 0, sizeof st);
        memset(fake_rx_regs, 0, sizeof fake_rx_regs);
        memset(fake_rxbuf, 0, sizeof fake_rxbuf);
        rxd.regs = fake_rx_regs;
        rxbuf = fake_rxbuf;
        rx_multi = K;
        rx_queued = 1; rx_cyclic = 0;
        rx_active = 0;
        rx_drain = -1; rx_dscan = 0; rx_fscan = 0; rx_fill = 0;

        /* arm: submits area0; area1's submit finds the pending slot busy -> DEFERRED */
        n = rx_pump_frame(out, &seq);
        CHECK(n == 0 && rx_active && rx_fill == 0, "queued: first pump arms");
        CHECK(fake_rx_regs[DMAC_SUBMIT / 4] == 1, "queued: area0 submitted");
        CHECK(fake_rx_regs[DMAC_DEST_ADDRESS / 4] == rx_area_phys(0), "queued: area0 dest");
        CHECK(rx_q_defer == 1, "queued: area1 submit deferred while slot busy");
        /* model hardware acceptance (SOT clears the pending latch) */
        fake_rx_regs[DMAC_SUBMIT / 4] = 0;
        fake_rx_regs[DMAC_CONTROL / 4] = CTRL_SENTINEL;   /* trip-wire: any reset overwrites */
        n = rx_pump_frame(out, &seq);                     /* retries the deferred submit */
        CHECK(rx_q_defer == -1 && fake_rx_regs[DMAC_SUBMIT / 4] == 1,
              "queued: deferred area1 submit retried and queued");
        CHECK(fake_rx_regs[DMAC_DEST_ADDRESS / 4] == rx_area_phys(1), "queued: area1 dest");
        CHECK(rx_q_id[0] == 0 && rx_q_id[1] == 1, "queued: IDs assigned in submit order");
        fake_rx_regs[DMAC_SUBMIT / 4] = 0;                /* area1 request accepted */

        /* eager: land 4 frames in area0, delivered in order */
        for (i = 0; i < K; i++)
            qpsk_frame_encode(rx_area_virt(0) + (size_t)i * pkt_bytes,
                              pkt_bytes, payload, 116, 700u + (uint32_t)i);
        for (i = 0; i < K; i++) {
            n = rx_pump_frame(out, &seq);
            CHECK(n == 116 && seq == 700u + (uint32_t)i, "queued: eager in-order delivery");
        }

        /* completion of area0 (ID 0): fully eager-consumed -> flip + IMMEDIATE requeue
         * of area0 (ID 2). Crucially: no CONTROL write (sentinel intact). */
        fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 0x1;       /* DONE bit for ID 0 */
        n = rx_pump_frame(out, &seq);
        CHECK(n == 0 && rx_fill == 1, "queued: completion flips fill (no delivery)");
        CHECK(fake_rx_regs[DMAC_DEST_ADDRESS / 4] == rx_area_phys(0) &&
              fake_rx_regs[DMAC_SUBMIT / 4] == 1 && rx_q_id[0] == 2,
              "queued: consumed area requeued at once (ID 2)");
        CHECK(fake_rx_regs[DMAC_CONTROL / 4] == CTRL_SENTINEL,
              "queued: NO engine reset across the boundary (sentinel intact)");
        fake_rx_regs[DMAC_SUBMIT / 4] = 0;

        /* partial-eager case: only 2 of 4 area1 slices land before completion (slots
         * 2,3 stay zeroed = corrupt on a completed transfer). DONE bitmap = 0x3: the
         * stale ID-0 bit is still set, as real hardware leaves it until ID 0 recycles
         * at its next SOT -- must not confuse the ID-1 check. */
        for (i = 0; i < 2; i++)
            qpsk_frame_encode(rx_area_virt(1) + (size_t)i * pkt_bytes,
                              pkt_bytes, payload, 116, 704u + (uint32_t)i);
        n = rx_pump_frame(out, &seq); CHECK(n == 116 && seq == 704, "queued: eager 1/2");
        n = rx_pump_frame(out, &seq); CHECK(n == 116 && seq == 705, "queued: eager 2/2");
        fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 0x3;       /* ID1 done (+ stale ID0 bit) */
        n = rx_pump_frame(out, &seq);
        CHECK(n == 0 && rx_fill == 0 && rx_drain == 1 && rx_dscan == 2,
              "queued: completion hands leftover tail to drainer (stale bit ignored)");
        fake_rx_regs[DMAC_TRANSFER_DONE / 4] = 0x2;       /* ID2 (new fill) not done */
        { uint64_t drops0 = st.crc_drops;
          n = rx_pump_frame(out, &seq);                   /* drain consumes 2 corrupt tails */
          CHECK(n == 0 && st.crc_drops == drops0 + 2,
                "queued: corrupt tail slices counted as crc drops");
          CHECK(rx_drain == -1 && fake_rx_regs[DMAC_DEST_ADDRESS / 4] == rx_area_phys(1) &&
                fake_rx_regs[DMAC_SUBMIT / 4] == 1 && rx_q_id[1] == 3,
                "queued: drained area requeued (ID 3)"); }
        CHECK(fake_rx_regs[DMAC_CONTROL / 4] == CTRL_SENTINEL,
              "queued: still no reset after full cycle");
        fake_rx_regs[DMAC_SUBMIT / 4] = 0;

        /* watchdog: no progress within the (shortened) window -> recovery re-arm */
        rx_q_wdog_s = 0.05;
        usleep(80000);
        n = rx_pump_frame(out, &seq);
        CHECK(rx_q_resets == 1, "queued: watchdog fired once");
        CHECK(fake_rx_regs[DMAC_CONTROL / 4] == 1,
              "queued: watchdog recovery DID reset the engine (sentinel overwritten)");
        rx_q_wdog_s = 3.0;
        rx_queued = 0;                                    /* restore default path */
    }

    /* ---- cross-link NAK ARQ (arq_x) ----
     * axr_note hole bookkeeping, NAK build->parse->retx round trip through the
     * fake TX DMA, re-NAK scheduling and hole expiry. */
    {
        memset(&st, 0, sizeof st);
        arq_x = 1;
        axr_have = 0;
        memset(axr_hole, 0, sizeof axr_hole);
        retxq_head = retxq_tail = 0;
        rx_tick = 0;

        /* in-order delivery */
        CHECK(axr_note(1000) == 1, "arqx: first frame delivers");
        CHECK(axr_note(1001) == 1, "arqx: in-order delivers");
        /* gap 1002..1004 lost, 1005 arrives */
        CHECK(axr_note(1005) == 1, "arqx: jump frame still delivers");
        CHECK(st.seq_gaps == 1, "arqx: gap counted once");
        int holes = 0;
        for (unsigned hi = 0; hi < AXR_HOLE_SZ; hi++) holes += axr_hole[hi].valid;
        CHECK(holes == 3, "arqx: three holes opened");
        /* late retransmit fills a hole -> delivered + recovered */
        CHECK(axr_note(1003) == 1 && st.recovered == 1, "arqx: hole fill delivers");
        /* the same seq again -> dup, dropped */
        CHECK(axr_note(1003) == 0 && st.dups == 1, "arqx: duplicate dropped");

        /* NAK build: fake TX DMA ready */
        memset(fake_tx_regs, 0, sizeof fake_tx_regs);
        txd.regs = fake_tx_regs;
        txbuf = fake_txbuf;
        tx_inflight = 0; tx_slot = 0;
        fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0;
        uint32_t txs = 5000;
        axr_pump(&txs, NULL);
        CHECK(st.naks_tx == 1 && txs == 5001, "arqx: NAK frame sent, consumed one tx_seq");
        /* the NAK frame is in fake_txbuf slot 0: decode + parse it (closes the loop) */
        {
            unsigned char nout[QPSK_PKT_BYTES_MAX]; uint32_t nseq;
            int nm = qpsk_frame_decode(fake_txbuf, pkt_bytes, nout, &nseq);
            CHECK(nm > 0 && nseq == 5000, "arqx: NAK frame decodes");
            CHECK(axr_is_nak(nout, nm), "arqx: NAK payload recognized");
            unsigned rq0 = retxq_tail - retxq_head;
            axr_parse_nak(nout);
            CHECK(retxq_tail - retxq_head == rq0 + 2 && st.naks_rx == 1,
                  "arqx: parse queues the 2 outstanding holes (1002,1004)");
        }
        /* peer-side resend: hist has the frames -> retx_pump re-sends them
         * (reap the fake TX completions first so tx_capacity() frees up) */
        fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0xFFFFFFFFu; tx_reap();
        for (i = 0; i < 116; i++) payload[i] = (unsigned char)i;
        { unsigned char p2[QPSK_PKT_BYTES_MAX];
          qpsk_frame_encode(p2, pkt_bytes, payload, 116, 1002); hist_store(1002, p2);
          qpsk_frame_encode(p2, pkt_bytes, payload, 116, 1004); hist_store(1004, p2); }
        { uint64_t r0 = st.retx;
          retx_pump(NULL);
          fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0xFFFFFFFFu; tx_reap();
          CHECK(st.retx == r0 + 2, "arqx: retx_pump resends both NAKed frames"); }

        /* re-NAK scheduling: holes re-NAK after AXR_RENAK ticks, expire after 3 */
        rx_tick += AXR_RENAK;
        axr_pump(&txs, NULL);      /* NAK try 2 */
        fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0xFFFFFFFFu; tx_reap();
        rx_tick += AXR_RENAK;
        axr_pump(&txs, NULL);      /* NAK try 3 */
        fake_tx_regs[DMAC_TRANSFER_DONE / 4] = 0xFFFFFFFFu; tx_reap();
        rx_tick += AXR_RENAK;
        { uint64_t l0 = st.arq_lost;
          axr_pump(&txs, NULL);    /* tries exhausted -> holes expire */
          holes = 0;
          for (unsigned hi = 0; hi < AXR_HOLE_SZ; hi++) holes += axr_hole[hi].valid;
          CHECK(holes == 0 && st.arq_lost == l0 + 2, "arqx: unanswered holes expire after 3 NAKs"); }
        CHECK(st.naks_tx == 3, "arqx: three NAK frames total");
        arq_x = 0;
    }

    /* ---- Rx CYCLIC ring reader (QPSK_RX_CYCLIC path) ----
     * Freshness by seq-monotonicity (no rx_done, no per-arm carve_zero). Drives the
     * ring reader against the fake carve: in-order delivery, wait on un-landed/stale
     * slots, and full-lap overrun detection. */
    {
        memset(&st, 0, sizeof st);
        memset(fake_rx_regs, 0, sizeof fake_rx_regs);
        memset(fake_rxbuf, 0, sizeof fake_rxbuf);
        rxd.regs = fake_rx_regs;
        rxbuf = fake_rxbuf;
        rx_multi = 4;
        rx_cyclic = 1;
        rx_active = 0;
        rx_ring_scan = 0; rx_cyc_last = 0; rx_cyc_have = 0;

        n = rx_pump_frame(out, &seq);          /* dispatches to cyclic; first call arms once */
        CHECK(n == 0 && rx_active, "cyclic: first pump arms the ring");
        unsigned slots = rx_ring_slots;
        CHECK(slots == (2u * RX_MULTI_MAX * SLOT_BYTES) / (unsigned)pkt_bytes,
              "cyclic: ring slot count derived from the carve");
        CHECK(fake_rx_regs[DMAC_FLAGS / 4] == DMAC_FLAG_CYCLIC, "cyclic: FLAGS = cyclic bit only");
        CHECK(fake_rx_regs[DMAC_X_LENGTH / 4] == slots * (uint32_t)pkt_bytes - 1,
              "cyclic: X_LENGTH spans the whole ring");

        /* land frames seq 100,101,102 in slots 0,1,2; slot 3 stays zero (not landed) */
        for (i = 0; i < 3; i++)
            qpsk_frame_encode(rx_area_virt(0) + (size_t)i * pkt_bytes,
                              pkt_bytes, payload, 116, 100u + (uint32_t)i);
        for (i = 0; i < 3; i++) {
            n = rx_pump_frame(out, &seq);
            CHECK(n == 116 && seq == 100u + (uint32_t)i, "cyclic: delivers ring frames in order");
        }
        n = rx_pump_frame(out, &seq);          /* slot 3 zeroed -> decode fails -> wait */
        CHECK(n == 0 && rx_ring_scan == 3, "cyclic: waits on an un-landed slot (no advance)");
        qpsk_frame_encode(rx_area_virt(0) + (size_t)3 * pkt_bytes, pkt_bytes, payload, 116, 103u);
        n = rx_pump_frame(out, &seq);
        CHECK(n == 116 && seq == 103u, "cyclic: delivers once the slot lands");

        unsigned sc = rx_ring_scan;
        qpsk_frame_encode(rx_area_virt(0) + (size_t)sc * pkt_bytes, pkt_bytes, payload, 116, 50u);
        n = rx_pump_frame(out, &seq);          /* older seq than last consumed -> stale */
        CHECK(n == 0, "cyclic: stale (older) seq in slot is not delivered");

        uint64_t g0 = st.seq_gaps;
        qpsk_frame_encode(rx_area_virt(0) + (size_t)sc * pkt_bytes, pkt_bytes, payload, 116,
                          103u + slots + 5u);   /* a full ring ahead -> overrun */
        n = rx_pump_frame(out, &seq);
        CHECK(n == 116 && st.seq_gaps == g0 + 1, "cyclic: full-lap seq jump counted as overrun");

        rx_cyclic = 0;                         /* restore default path for any later tests */
    }

    /* ---- carve guard: /proc/iomem coverage parser (MUST-FIX 1) ----
     * The -DQPSK_CARVE_2MB startup guard refuses to run unless a reserved
     * region covers the whole 2 MB carve 0x7FE00000..0x7FFFFFFF. Drive the
     * underlying parser (qpsk_uio.c, external linkage so both build configs
     * compile it) against synthetic /proc/iomem fixtures -- no board needed. */
    {
        const uint64_t B = 0x7FE00000ull, T = 0x7FFFFFFFull;  /* 2 MB carve */
        char tmpl[] = "/tmp/qpsk_iomem_XXXXXX";
        int tfd = mkstemp(tmpl);
        CHECK(tfd >= 0, "carve: temp iomem fixture created");
        if (tfd >= 0) {
            FILE *tf;
            /* helper: rewrite the fixture file with `body`, then probe [B,T] */
            #define IOMEM_COVERS(body) ( \
                (tf = fopen(tmpl, "w")) && fputs((body), tf) >= 0 && \
                fclose(tf) == 0 && \
                qpsk_iomem_reserved_covers(tmpl, B, T) )

            /* exact 2 MB carve -> covered */
            CHECK(IOMEM_COVERS(
                "84a30000-84a3ffff : 84a30000.dma-controller\n"
                "7fe00000-7fffffff : reserved\n"),
                "carve: 2 MB reserved region covers the carve");

            /* the hazard: DT still reserves only the old 1 MB @0x7FF00000 --
             * start 0x7FF00000 > 0x7FE00000, so it does NOT cover the base */
            CHECK(!IOMEM_COVERS(
                "7ff00000-7fffffff : reserved\n"),
                "carve: 1 MB-only reserve is REFUSED (DMA-scribble hazard)");

            /* no reserved line at all -> refused */
            CHECK(!IOMEM_COVERS(
                "84a30000-84a3ffff : 84a30000.dma-controller\n"
                "9d000000-9d00fffe : 9d000000.mwipcore\n"),
                "carve: absent reserve is refused");

            /* an oversized reserve (covers more than the carve) -> covered;
             * leading indent + zero-pad tolerated */
            CHECK(IOMEM_COVERS(
                "  007fc00000-007fffffff : reserved\n"),
                "carve: oversized/zero-padded reserve still covers");

            /* right range but a non-`reserved` label (driver-claimed) -> refused */
            CHECK(!IOMEM_COVERS(
                "7fe00000-7fffffff : some-driver\n"),
                "carve: covering region with non-reserved label is refused");

            /* substring/short label guards: "reserve" and "reserved-x" must not
             * be mistaken for the exact descriptor "reserved" */
            CHECK(!IOMEM_COVERS(
                "7fe00000-7fffffff : reserved-pool\n"),
                "carve: label longer than 'reserved' is refused");

            #undef IOMEM_COVERS
            close(tfd);
            unlink(tmpl);
        }
    }

    printf("k5 tests: %d run, %d failed\n", tests, fails);
    return fails ? 1 : 0;
}
