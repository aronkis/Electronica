/* test_fecglue.c -- integration test for the FEC glue inside qpsk_tun.c.
 *
 * tests/test_fec.c proves the CODE (qpsk_fec.c) in isolation.  This proves the
 * GLUE: that a parity container survives the real qpsk_frame encode ->
 * whitener -> decode path and still sniffs as parity on the far side, that it
 * fits inside the frame payload cap the daemon computes, and that the TX-side
 * group/queue bookkeeping and the RX-side reorder buffer actually recover a
 * dropped frame when driven exactly the way run_irq_loop drives them.
 *
 * Same compile-time include trick as test_k5.c: rename qpsk_tun.c's entry
 * point so its file-scope statics (fec_e, fec_d, fecq_*, fec_tx_note, ...)
 * are directly reachable here.
 */
#define _GNU_SOURCE                    /* qpsk_tun.c uses ppoll */
#include <assert.h>
#include <math.h>

#define main qpsk_tun_main
#include "qpsk_tun.c"
#undef main

static int tests, fails;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, (msg)); } } while (0)

#define MAXR   1516                    /* the daemon's max_read at MTU 1516 */
#define PLBYTE(i, k) ((unsigned char)(((i) * 131 + (k) * 7) & 0xFF))

/* ---- a captured air frame ------------------------------------------------ */
struct air { unsigned char pkt[QPSK_PKT_BYTES_MAX]; };

static void fec_reset_all(void)
{
    qpsk_fec_enc_free(fec_e); fec_e = NULL;
    qpsk_fec_dec_free(fec_d); fec_d = NULL;
    fec_k = 0; fec_r = 2;
    fecq_head = fecq_n = 0; fec_group_open = 0; fec_group_t0 = 0;
    fec_par_tx = fec_par_drop = fec_unprot = 0;
}

static void setenv_int(const char *k, int v)
{ char b[32]; snprintf(b, sizeof b, "%d", v); setenv(k, b, 1); }

/* ---- 1. env gate --------------------------------------------------------- */
static void t_gate(void)
{
    fec_reset_all();
    unsetenv("QPSK_FEC");
    fec_init_from_env(MAXR);
    CHECK(fec_k == 0 && !fec_e && !fec_d, "FEC stays OFF with QPSK_FEC unset");

    fec_reset_all();
    setenv_int("QPSK_FEC", 0);
    fec_init_from_env(MAXR);
    CHECK(fec_k == 0, "QPSK_FEC=0 is OFF");

    /* K is clamped, and a frame too small to hold a container refuses. */
    fec_reset_all();
    setenv_int("QPSK_FEC", 999); setenv_int("QPSK_FEC_R", 99);
    fec_init_from_env(MAXR);
    CHECK(fec_k == QPSK_FEC_KMAX, "K clamps to KMAX");
    CHECK(fec_r == QPSK_FEC_RMAX, "R clamps to RMAX");

    fec_reset_all();
    setenv_int("QPSK_FEC", 8); setenv_int("QPSK_FEC_R", 2);
    fec_init_from_env(200);            /* 200 - (14 + 32) = 154 < 256 */
    CHECK(fec_k == 0 && !fec_e, "a frame too small for a container refuses FEC");
}

/* ---- 2. the container fits inside one frame ------------------------------ */
static void t_fits(void)
{
    unsigned char pay[MAXR], par[QPSK_PKT_BYTES_MAX];
    int i, k, n, lcap;

    fec_reset_all();
    setenv_int("QPSK_FEC", 8); setenv_int("QPSK_FEC_R", 2);
    fec_init_from_env(MAXR);
    CHECK(fec_k == 8 && fec_r == 2 && fec_e && fec_d, "K=8 R=2 initialises");

    lcap = MAXR - QPSK_FEC_HDR(8);
    CHECK(qpsk_fec_enc_maxprot(fec_e) == lcap, "encoder takes the header-adjusted cap");

    /* Fill a group with the longest protectable payload and check every parity
     * container still fits in a frame payload.  This is the constraint that
     * bites: the container carries 14 + 4K bytes of header ON TOP of L. */
    for (i = 0; i < 8; i++) {
        for (k = 0; k < lcap; k++) pay[k] = PLBYTE(i, k);
        CHECK(qpsk_fec_enc_add(fec_e, (uint32_t)i, pay, lcap) == (i == 7),
              "worst-case-length payload is accepted");
    }
    for (i = 0; i < 2; i++) {
        n = qpsk_fec_enc_parity(fec_e, i, par, (int)sizeof par);
        CHECK(n > 0, "parity built at worst-case length");
        CHECK(n <= MAXR, "parity container fits inside one frame payload");
        CHECK(n == QPSK_FEC_HDR(8) + lcap, "container is exactly hdr + L");
    }
    qpsk_fec_enc_reset(fec_e);

    /* One byte over the cap must be refused, not truncated. */
    CHECK(qpsk_fec_enc_add(fec_e, 100, pay, lcap + 1) < 0,
          "a payload over the cap is refused so the caller can send it bare");
}

/* ---- 3. a container survives encode -> whitener -> decode ---------------- */
static void t_wire(void)
{
    unsigned char pay[MAXR], par[QPSK_PKT_BYTES_MAX];
    unsigned char pkt[QPSK_PKT_BYTES_MAX], out[QPSK_PKT_BYTES_MAX];
    int i, k, n, m, lcap;
    uint32_t seq;

    fec_reset_all();
    setenv_int("QPSK_FEC", 8); setenv_int("QPSK_FEC_R", 2);
    fec_init_from_env(MAXR);
    lcap = MAXR - QPSK_FEC_HDR(8);

    for (i = 0; i < 8; i++) {
        for (k = 0; k < 600; k++) pay[k] = PLBYTE(i, k);
        qpsk_fec_enc_add(fec_e, (uint32_t)i, pay, 600);
    }
    n = qpsk_fec_enc_parity(fec_e, 0, par, (int)sizeof par);
    CHECK(n > 0, "parity built");

    /* Through the real frame path, at the real 1528 B geometry. */
    pkt_bytes = 1528;
    CHECK(qpsk_frame_encode(pkt, pkt_bytes, par, n, 4242) == pkt_bytes,
          "container encodes into an ordinary frame");
    m = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
    CHECK(m == n, "container survives the whitener round trip at full length");
    CHECK(seq == 4242, "seq survives");
    CHECK(memcmp(out, par, (size_t)n) == 0, "container bytes are byte-identical");
    CHECK(qpsk_fec_is_parity(out, m) == 1,
          "the decoded container still sniffs as parity");

    /* A real tun packet must never sniff as parity on the same path. */
    for (k = 0; k < 600; k++) pay[k] = PLBYTE(3, k);
    pay[0] = 0x45;                                    /* IPv4 */
    qpsk_frame_encode(pkt, pkt_bytes, pay, 600, 7);
    m = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
    CHECK(m == 600 && qpsk_fec_is_parity(out, m) == 0,
          "an IPv4 packet through the same path is not mistaken for parity");
    (void)lcap;
}

/* ---- 4. drive the glue the way run_irq_loop does ------------------------- */
/* Mirrors the daemon: poll-admitted data calls fec_tx_note under the seq it
 * went out with, then the credit loop drains fecq_* parity-first, each parity
 * taking the next tx_seq.  Frame `drop_at` is erased.  Then every survivor is
 * decoded and pushed through qpsk_fec_dec_rx exactly as the RX branch does. */
static void t_loop(int K, int R, int ndata, int drop_a, int drop_b, int expect_rec)
{
    static struct air air[512];
    static int seq2idx[512];              /* data index, or -1 for parity */
    unsigned char pay[MAXR], out[QPSK_PKT_BYTES_MAX], got[QPSK_PKT_BYTES_MAX];
    int nair = 0, i, k, m, plen = 700;
    uint32_t tx_seq = 0, seq;
    double t = 1000.0;
    const struct qpsk_fec_stats *s;
    int released = 0, mismatch = 0;
    uint32_t prev = 0; int have_prev = 0;

    memset(seq2idx, 0xFF, sizeof seq2idx);       /* -1 everywhere */
    fec_reset_all();
    setenv_int("QPSK_FEC", K); setenv_int("QPSK_FEC_R", R);
    setenv_int("QPSK_FEC_HOLD_MS", 40); setenv_int("QPSK_FEC_FLUSH_MS", 25);
    fec_init_from_env(MAXR);
    pkt_bytes = 1528;

    for (i = 0; i < ndata; i++) {
        for (k = 0; k < plen; k++) pay[k] = PLBYTE(i, k);
        pay[0] = 0x45;
        qpsk_frame_encode(air[nair].pkt, pkt_bytes, pay, plen, tx_seq);
        nair++;
        seq2idx[tx_seq] = i;
        fec_tx_note(tx_seq, pay, plen, t);
        tx_seq++;
        t += 0.002;
        /* credit loop: parity first.  Parity takes a tx_seq of its own, so
         * data seqs are NOT contiguous -- which is precisely why the container
         * carries an explicit delta table instead of assuming they are. */
        while (fecq_n > 0) {
            qpsk_frame_encode(air[nair].pkt, pkt_bytes,
                              fecq_buf[fecq_head], fecq_len[fecq_head], tx_seq);
            nair++;
            seq2idx[tx_seq] = -1;
            fecq_head = (fecq_head + 1) % FECQ_MAX;
            fecq_n--; fec_par_tx++; tx_seq++;
        }
    }
    fec_tx_tick(t + 1.0);                       /* flush the tail group */
    while (fecq_n > 0) {
        qpsk_frame_encode(air[nair].pkt, pkt_bytes,
                          fecq_buf[fecq_head], fecq_len[fecq_head], tx_seq);
        nair++;
        seq2idx[tx_seq] = -1;
        fecq_head = (fecq_head + 1) % FECQ_MAX;
        fecq_n--; fec_par_tx++; tx_seq++;
    }
    CHECK(fec_par_tx == (uint64_t)(((ndata + K - 1) / K) * R),
          "one parity burst per group, including the flushed tail");

    /* ---- RX: erase two frames, decode the rest through the real path ---- */
    t = 2000.0;
    for (i = 0; i < nair; i++) {
        if (i == drop_a || i == drop_b) continue;
        m = qpsk_frame_decode(air[i].pkt, pkt_bytes, out, &seq);
        CHECK(m > 0, "survivor decodes");
        qpsk_fec_dec_rx(fec_d, seq, out, m, t);
        t += 0.002;
        while ((m = qpsk_fec_dec_pop(fec_d, got, (int)sizeof got, &seq, t)) > 0) {
            int idx = seq2idx[seq];
            released++;
            if (idx < 0) { mismatch++; continue; }   /* parity must never reach tun0 */
            if (have_prev && !((int32_t)(seq - prev) > 0)) mismatch++;
            prev = seq; have_prev = 1;
            if (m != plen) { mismatch++; continue; }
            for (k = 0; k < plen; k++) {
                unsigned char want = (k == 0) ? 0x45 : PLBYTE(idx, k);
                if (got[k] != want) { mismatch++; break; }
            }
        }
    }
    t += 10.0;                                   /* let every hold expire */
    while ((m = qpsk_fec_dec_pop(fec_d, got, (int)sizeof got, &seq, t)) > 0) {
        int idx = seq2idx[seq];
        released++;
        if (idx < 0) { mismatch++; continue; }
        if (have_prev && !((int32_t)(seq - prev) > 0)) mismatch++;
        prev = seq; have_prev = 1;
        if (m != plen) { mismatch++; continue; }
        for (k = 0; k < plen; k++) {
            unsigned char want = (k == 0) ? 0x45 : PLBYTE(idx, k);
            if (got[k] != want) { mismatch++; break; }
        }
    }

    s = qpsk_fec_dec_stats(fec_d);
    CHECK(mismatch == 0, "every released frame is byte-exact and in seq order");
    CHECK((int)s->recovered == expect_rec, "the expected number of frames was rebuilt");
    CHECK(released == ndata, "every data frame reaches tun0 exactly once");
    CHECK(s->unrecoverable == 0, "nothing was given up on");
}

int main(void)
{
    qpsk_fec_init();
    t_gate();
    t_fits();
    t_wire();

    /* frame 0 is data seq 0; with K=8 R=2 the first parity pair is air[8..9] */
    t_loop(8, 2, 32, 3, -1, 1);        /* one data frame lost            */
    t_loop(8, 2, 32, 3, 5, 2);         /* two in one group, R=2 covers it */
    t_loop(8, 2, 32, 8, -1, 0);        /* a PARITY frame lost: no data hole */
    t_loop(8, 2, 32, 3, 9, 1);         /* one data + one parity           */
    t_loop(4, 1, 20, 2, -1, 1);        /* K=4 R=1                         */
    t_loop(16, 3, 48, 7, 11, 2);       /* bigger group, R=3               */

    fprintf(stderr, "fec glue tests: %d run, %d failed\n", tests, fails);
    return fails ? 1 : 0;
}
