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
