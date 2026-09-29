/* test_fec -- qpsk_fec unit + end-to-end erasure-channel tests (no hardware).
 *
 * The end-to-end case at the bottom is the one that matters: it runs a
 * Bernoulli erasure channel at the loss rate measured on the real link and
 * reports residual loss with and without parity.  Everything above it exists
 * to make sure a "recovered" frame is byte-identical to what was sent and
 * that nothing is ever delivered out of order. */
#include "../qpsk_fec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { \
    printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); \
    printf("\n"); fails++; } } while (0)

/* ---- independent GF(256) for checking the generator matrix -------------- */
static unsigned char tmul(unsigned char a, unsigned char b)
{
    unsigned r = 0, x = a, y = b, i;
    for (i = 0; i < 8; i++) {
        if (y & 1) r ^= x;
        y >>= 1;
        x <<= 1;
        if (x & 0x100) x ^= 0x11D;
    }
    return (unsigned char)r;
}
static unsigned char tinv(unsigned char a)
{
    int i;
    for (i = 1; i < 256; i++) if (tmul(a, (unsigned char)i) == 1) return (unsigned char)i;
    return 0;
}
/* determinant of an e x e GF(256) matrix */
static unsigned char tdet(unsigned char m[4][4], int e)
{
    unsigned char d = 1;
    int c, r, k;
    for (c = 0; c < e; c++) {
        int piv = -1;
        for (r = c; r < e; r++) if (m[r][c]) { piv = r; break; }
        if (piv < 0) return 0;
        if (piv != c) for (k = 0; k < e; k++) { unsigned char t = m[c][k]; m[c][k] = m[piv][k]; m[piv][k] = t; }
        d = tmul(d, m[c][c]);
        for (r = c + 1; r < e; r++) {
            unsigned char f = tmul(m[r][c], tinv(m[c][c]));
            for (k = c; k < e; k++) m[r][k] ^= tmul(f, m[c][k]);
        }
    }
    return d;
}

static uint32_t rs = 12345u;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

#define MAXP 1516

/* ---- 1. generator matrix ------------------------------------------------ */
static void t_matrix(void)
{
    int i, j;
    qpsk_fec_init();
    for (i = 0; i < 32; i++)
        CHECK(qpsk_fec_gen(0, i) == 1, "row0 col%d = %u, want 1", i, qpsk_fec_gen(0, i));
    for (j = 0; j < 4; j++)
        for (i = 0; i < 32; i++)
            CHECK(qpsk_fec_gen(j, i) != 0, "gen[%d][%d] == 0", j, i);

    /* every 4x4 column subset of the 4x32 generator must be invertible: that
     * is exactly the guarantee that ANY 4 erasures are solvable. C(32,4)=35960 */
    {
        int a, b, c, d, bad = 0;
        for (a = 0; a < 32; a++) for (b = a + 1; b < 32; b++)
        for (c = b + 1; c < 32; c++) for (d = c + 1; d < 32; d++) {
            unsigned char m[4][4];
            int cols[4], r, k;
            cols[0] = a; cols[1] = b; cols[2] = c; cols[3] = d;
            for (r = 0; r < 4; r++) for (k = 0; k < 4; k++) m[r][k] = qpsk_fec_gen(r, cols[k]);
            if (tdet(m, 4) == 0) bad++;
        }
        CHECK(bad == 0, "%d singular 4x4 column subsets", bad);
    }
}

/* ---- 2. encode/decode a single group with a chosen erasure pattern ------
 * Returns 1 if every dropped frame came back byte-identical. */
static int one_group(int K, int R, const int *drop_data, int ndrop,
                     const int *drop_par, int ndpar, int varlen)
{
    unsigned char data[QPSK_FEC_KMAX][MAXP];
    int len[QPSK_FEC_KMAX];
    unsigned char par[QPSK_FEC_RMAX][MAXP];
    int plen[QPSK_FEC_RMAX];
    qpsk_fec_enc *e = qpsk_fec_enc_new(K, R, MAXP);
    qpsk_fec_dec *d = qpsk_fec_dec_new(64, MAXP, 0.040);
    uint32_t seq0 = 1000, sq;
    unsigned char out[MAXP];
    int i, j, k, ok = 1, got = 0;
    uint32_t seqs[QPSK_FEC_KMAX];

    if (!e || !d) { printf("FAIL alloc\n"); fails++; return 0; }
    for (i = 0; i < K; i++) {
        len[i] = varlen ? (int)(200 + rnd() % 1100) : 1300;
        for (k = 0; k < len[i]; k++) data[i][k] = (unsigned char)(rnd() & 0xFF);
        /* non-contiguous seqs: idle frames sit between data frames on the wire */
        seqs[i] = seq0 + (uint32_t)(i * 3);
        j = qpsk_fec_enc_add(e, seqs[i], data[i], len[i]);
        CHECK(j >= 0, "enc_add rejected K=%d i=%d len=%d", K, i, len[i]);
    }
    for (j = 0; j < R; j++) {
        plen[j] = qpsk_fec_enc_parity(e, j, par[j], MAXP);
        CHECK(plen[j] > 0, "parity %d build failed", j);
        CHECK(qpsk_fec_is_parity(par[j], plen[j]), "parity %d not recognised", j);
    }

    /* deliver surviving data, then surviving parity */
    for (i = 0; i < K; i++) {
        int dropped = 0;
        for (k = 0; k < ndrop; k++) if (drop_data[k] == i) dropped = 1;
        if (!dropped) qpsk_fec_dec_rx(d, seqs[i], data[i], len[i], 0.0);
    }
    for (j = 0; j < R; j++) {
        int dropped = 0;
        for (k = 0; k < ndpar; k++) if (drop_par[k] == j) dropped = 1;
        if (!dropped) {
            int r = qpsk_fec_dec_rx(d, seq0 + 500 + (uint32_t)j, par[j], plen[j], 0.0);
            CHECK(r == 1, "parity not classified as parity");
        }
    }
    /* drain with the hold expired */
    {
        uint32_t prev = 0; int haveprev = 0;
        while ((k = qpsk_fec_dec_pop(d, out, MAXP, &sq, 10.0)) > 0) {
            int idx = -1;
            for (i = 0; i < K; i++) if (seqs[i] == sq) idx = i;
            CHECK(idx >= 0, "popped unknown seq %u", sq);
            if (idx >= 0) {
                if (k != len[idx] || memcmp(out, data[idx], (size_t)k) != 0) {
                    ok = 0; CHECK(0, "payload %d corrupt (got %d want %d)", idx, k, len[idx]);
                }
            }
            if (haveprev) CHECK((int32_t)(sq - prev) > 0, "out of order: %u after %u", sq, prev);
            prev = sq; haveprev = 1;
            got++;
        }
    }
    if (got != K) ok = 0;
    qpsk_fec_enc_free(e); qpsk_fec_dec_free(d);
    return ok;
}

static void t_recover(void)
{
    int i, j;
    /* R=1: every single data erasure must be recovered */
    for (i = 0; i < 8; i++) {
        int dd[1]; dd[0] = i;
        CHECK(one_group(8, 1, dd, 1, NULL, 0, 0), "R=1 single loss idx %d", i);
    }
    /* R=1, variable payload lengths (exercises the zero-pad path) */
    for (i = 0; i < 8; i++) {
        int dd[1]; dd[0] = i;
        CHECK(one_group(8, 1, dd, 1, NULL, 0, 1), "R=1 varlen loss idx %d", i);
    }
    /* R=2: every PAIR of data erasures (28 patterns) */
    for (i = 0; i < 8; i++) for (j = i + 1; j < 8; j++) {
        int dd[2]; dd[0] = i; dd[1] = j;
        CHECK(one_group(8, 2, dd, 2, NULL, 0, 1), "R=2 pair %d,%d", i, j);
    }
    /* R=2 with one parity ALSO lost: one data erasure must still be fixed */
    for (i = 0; i < 8; i++) {
        int dd[1], dp[1]; dd[0] = i; dp[0] = 0;
        CHECK(one_group(8, 2, dd, 1, dp, 1, 1), "R=2 lost parity0 + data %d", i);
        dp[0] = 1;
        CHECK(one_group(8, 2, dd, 1, dp, 1, 1), "R=2 lost parity1 + data %d", i);
    }
    /* no loss at all -- must still deliver all K, unchanged */
    CHECK(one_group(8, 1, NULL, 0, NULL, 0, 1), "clean group");
    /* larger and smaller geometries */
    { int dd[1] = {5};  CHECK(one_group(16, 1, dd, 1, NULL, 0, 1), "K=16"); }
    { int dd[1] = {0};  CHECK(one_group(2,  1, dd, 1, NULL, 0, 1), "K=2"); }
    { int dd[3] = {1,4,6};
      CHECK(one_group(8, 4, dd, 3, NULL, 0, 1), "R=4 triple loss"); }
}

/* ---- 3. container sniffing must not eat real traffic -------------------- */
static void t_sniff(void)
{
    unsigned char ip[1400];
    int i;
    memset(ip, 0, sizeof ip);
    ip[0] = 0x45;                                  /* IPv4, IHL 5 */
    CHECK(!qpsk_fec_is_parity(ip, (int)sizeof ip), "IPv4 packet sniffed as parity");
    ip[0] = 0x60;                                  /* IPv6 */
    CHECK(!qpsk_fec_is_parity(ip, (int)sizeof ip), "IPv6 packet sniffed as parity");
    for (i = 0; i < 4000; i++) {                   /* random payloads */
        int n = 64 + (int)(rnd() % 1300);
        int k;
        for (k = 0; k < n; k++) ip[k] = (unsigned char)(rnd() & 0xFF);
        ip[0] = (rnd() & 1) ? 0x45 : 0x60;
        CHECK(!qpsk_fec_is_parity(ip, n), "random payload sniffed as parity");
    }
    /* right magic, wrong length -> rejected */
    {
        unsigned char p[128];
        memset(p, 0, sizeof p);
        p[0] = 0xFE; p[1] = 0xC1; p[2] = 1; p[3] = 1; p[4] = 4; p[5] = 1; p[6] = 0;
        p[12] = 10; p[13] = 0;                     /* L = 10 */
        CHECK(qpsk_fec_is_parity(p, QPSK_FEC_HDR(4) + 10), "valid container rejected");
        CHECK(!qpsk_fec_is_parity(p, QPSK_FEC_HDR(4) + 11), "length mismatch accepted");
        p[2] = 2;
        CHECK(!qpsk_fec_is_parity(p, QPSK_FEC_HDR(4) + 10), "bad version accepted");
    }
}

/* ---- 4. limits and refusals -------------------------------------------- */
static void t_limits(void)
{
    unsigned char big[MAXP];
    qpsk_fec_enc *e = qpsk_fec_enc_new(8, 1, MAXP);
    int cap;
    CHECK(e != NULL, "enc_new failed");
    if (!e) return;
    cap = qpsk_fec_enc_maxprot(e);
    CHECK(cap == MAXP - QPSK_FEC_HDR(8), "maxprot %d", cap);
    memset(big, 0xAB, sizeof big);
    CHECK(qpsk_fec_enc_add(e, 1, big, cap) == 0, "payload at the cap refused");
    CHECK(qpsk_fec_enc_pending(e) == 1, "pending after add");
    CHECK(qpsk_fec_enc_add(e, 2, big, cap + 1) == -1, "over-cap payload accepted");
    CHECK(qpsk_fec_enc_pending(e) == 1, "over-cap add disturbed the group");
    /* short flush: parity over the 1 pending frame must still be valid */
    {
        unsigned char par[MAXP];
        int pl = qpsk_fec_enc_parity(e, 0, par, MAXP);
        CHECK(pl > 0 && qpsk_fec_is_parity(par, pl), "short-group parity invalid");
        CHECK(par[4] == 1, "short group coded K=%u, want 1", par[4]);
    }
    qpsk_fec_enc_free(e);
    CHECK(qpsk_fec_enc_new(8, 1, QPSK_FEC_HDR(8) + 4) == NULL, "tiny frame accepted");
    CHECK(qpsk_fec_enc_new(0, 1, MAXP) == NULL, "K=0 accepted");
    CHECK(qpsk_fec_enc_new(8, 5, MAXP) == NULL, "R=5 accepted");
}

/* ---- 5. ordering: a late rebuild is discarded, never delivered late ----- */
static void t_ordering(void)
{
    qpsk_fec_enc *e = qpsk_fec_enc_new(4, 1, MAXP);
    qpsk_fec_dec *d = qpsk_fec_dec_new(32, MAXP, 0.040);
    unsigned char data[4][600], par[MAXP], out[MAXP];
    int i, k, pl;
    uint32_t sq;
    const struct qpsk_fec_stats *st;

    for (i = 0; i < 4; i++) {
        for (k = 0; k < 600; k++) data[i][k] = (unsigned char)(i * 31 + k);
        qpsk_fec_enc_add(e, 100 + (uint32_t)i, data[i], 600);
    }
    pl = qpsk_fec_enc_parity(e, 0, par, MAXP);

    /* frame 1 is lost; frames 0,2,3 arrive at t=0 */
    qpsk_fec_dec_rx(d, 100, data[0], 600, 0.0);
    qpsk_fec_dec_rx(d, 102, data[2], 600, 0.0);
    qpsk_fec_dec_rx(d, 103, data[3], 600, 0.0);
    /* the hold expires BEFORE the parity shows up -> the hole is committed */
    while (qpsk_fec_dec_pop(d, out, MAXP, &sq, 1.0) > 0) { }
    qpsk_fec_dec_rx(d, 200, par, pl, 1.0);
    CHECK(qpsk_fec_dec_pop(d, out, MAXP, &sq, 2.0) == 0, "late rebuild delivered");
    st = qpsk_fec_dec_stats(d);
    CHECK(st->too_late == 1, "too_late=%llu, want 1", (unsigned long long)st->too_late);
    CHECK(st->recovered == 0, "recovered=%llu, want 0", (unsigned long long)st->recovered);
    qpsk_fec_enc_free(e); qpsk_fec_dec_free(d);

    /* same loss, but the parity arrives INSIDE the hold window -> recovered
     * and delivered in its correct position */
    e = qpsk_fec_enc_new(4, 1, MAXP);
    d = qpsk_fec_dec_new(32, MAXP, 0.040);
    for (i = 0; i < 4; i++) qpsk_fec_enc_add(e, 100 + (uint32_t)i, data[i], 600);
    pl = qpsk_fec_enc_parity(e, 0, par, MAXP);
    qpsk_fec_dec_rx(d, 100, data[0], 600, 0.0);
    qpsk_fec_dec_rx(d, 102, data[2], 600, 0.0);
    qpsk_fec_dec_rx(d, 103, data[3], 600, 0.0);
    qpsk_fec_dec_rx(d, 200, par, pl, 0.001);
    {
        uint32_t want[4] = {100, 101, 102, 103};
        for (i = 0; i < 4; i++) {
            k = qpsk_fec_dec_pop(d, out, MAXP, &sq, 1.0);
            CHECK(k == 600, "pop %d returned %d", i, k);
            CHECK(sq == want[i], "pop %d seq %u want %u", i, sq, want[i]);
            CHECK(memcmp(out, data[i], 600) == 0, "pop %d payload mismatch", i);
        }
        CHECK(qpsk_fec_dec_pop(d, out, MAXP, &sq, 1.0) == 0, "extra pop");
    }
    st = qpsk_fec_dec_stats(d);
    CHECK(st->recovered == 1, "recovered=%llu want 1", (unsigned long long)st->recovered);
    qpsk_fec_enc_free(e); qpsk_fec_dec_free(d);
}

/* ---- 6. two losses with only one parity row: no bogus delivery ---------- */
static void t_unrecoverable(void)
{
    qpsk_fec_enc *e = qpsk_fec_enc_new(4, 1, MAXP);
    qpsk_fec_dec *d = qpsk_fec_dec_new(32, MAXP, 0.040);
    unsigned char data[4][600], par[MAXP], out[MAXP];
    int i, k, pl, got = 0;
    uint32_t sq;
    const struct qpsk_fec_stats *st;

    for (i = 0; i < 4; i++) {
        for (k = 0; k < 600; k++) data[i][k] = (unsigned char)(i * 7 + k);
        qpsk_fec_enc_add(e, 100 + (uint32_t)i, data[i], 600);
    }
    pl = qpsk_fec_enc_parity(e, 0, par, MAXP);
    qpsk_fec_dec_rx(d, 100, data[0], 600, 0.0);          /* 101 and 102 lost */
    qpsk_fec_dec_rx(d, 103, data[3], 600, 0.0);
    qpsk_fec_dec_rx(d, 200, par, pl, 0.001);
    while ((k = qpsk_fec_dec_pop(d, out, MAXP, &sq, 1.0)) > 0) {
        int idx = (int)(sq - 100);
        CHECK(idx == 0 || idx == 3, "delivered a frame that was never recoverable: %u", sq);
        CHECK(k == 600 && memcmp(out, data[idx], 600) == 0, "corrupt survivor %u", sq);
        got++;
    }
    CHECK(got == 2, "delivered %d, want 2", got);
    st = qpsk_fec_dec_stats(d);
    CHECK(st->unrecoverable == 1, "unrecoverable=%llu want 1", (unsigned long long)st->unrecoverable);
    CHECK(st->recovered == 0, "recovered=%llu want 0", (unsigned long long)st->recovered);
    qpsk_fec_enc_free(e); qpsk_fec_dec_free(d);
}

/* ---- 7. end-to-end erasure channel -------------------------------------
 * N payload frames through a Bernoulli(p) erasure channel, K/R parity, with
 * idle frames consuming sequence numbers in between (as on the real wire).
 * Reports residual loss so the coding gain is a measured number, not a claim. */
static void e2e(int K, int R, double p, int N, double *out_raw, double *out_res)
{
    qpsk_fec_enc *e = qpsk_fec_enc_new(K, R, MAXP);
    qpsk_fec_dec *d = qpsk_fec_dec_new(4 * (K + R) + 32, MAXP, 0.040);
    unsigned char pl[MAXP], par[MAXP], out[MAXP];
    uint32_t *sseq = (uint32_t *)calloc((size_t)N, sizeof *sseq);
    int      *slen = (int *)calloc((size_t)N, sizeof *slen);
    uint32_t seq = 7000;
    uint32_t thr = (uint32_t)(p * 4294967295.0);
    int i, k, lost_raw = 0, delivered = 0, disorder = 0, corrupt = 0, unknown = 0;
    uint32_t prev = 0, sq; int haveprev = 0, nfill = 0;
    double t = 0.0;

    /* payload i is a deterministic function of (i, k) so any delivered byte
     * can be checked against what was sent -- a "recovered" frame that is not
     * bit-exact must fail here. */
#define PLBYTE(i, k) ((unsigned char)(((i) * 131 + (k) * 7) & 0xFF))
#define DRAIN() do { \
        while ((k = qpsk_fec_dec_pop(d, out, MAXP, &sq, t)) > 0) { \
            int lo = 0, hi = nfill - 1, idx = -1, kk; \
            while (lo <= hi) { int mid = (lo + hi) / 2; \
                if (sseq[mid] == sq) { idx = mid; break; } \
                if (sseq[mid] < sq) lo = mid + 1; else hi = mid - 1; } \
            if (idx < 0) { unknown++; continue; } \
            if (k != slen[idx]) corrupt++; \
            else for (kk = 0; kk < k; kk++) \
                if (out[kk] != PLBYTE(idx, kk)) { corrupt++; break; } \
            if (haveprev && (int32_t)(sq - prev) <= 0) disorder++; \
            prev = sq; haveprev = 1; delivered++; \
        } } while (0)

    for (i = 0; i < N; i++) {
        int len = 1200 + (int)(rnd() % 145);          /* ~ mpegts 1316 B UDP */
        int full, j;
        for (k = 0; k < len; k++) pl[k] = PLBYTE(i, k);
        sseq[i] = seq; slen[i] = len; nfill = i + 1;
        full = qpsk_fec_enc_add(e, seq, pl, len);
        if (rnd() > thr) qpsk_fec_dec_rx(d, seq, pl, len, t);
        else             lost_raw++;
        seq += 1 + (rnd() % 3);                       /* idle frames in between */
        t += 0.0018;
        if (full == 1) {
            for (j = 0; j < R; j++) {
                int n = qpsk_fec_enc_parity(e, j, par, MAXP);
                if (n > 0 && rnd() > thr) qpsk_fec_dec_rx(d, seq, par, n, t);
                seq += 1 + (rnd() % 3);
                t += 0.0018;
            }
            qpsk_fec_enc_reset(e);
        }
        DRAIN();
    }
    t += 10.0;
    DRAIN();

    *out_raw = 100.0 * lost_raw / N;
    *out_res = 100.0 * (N - delivered) / N;
    CHECK(corrupt == 0, "%d corrupt payloads", corrupt);
    CHECK(disorder == 0, "%d out-of-order deliveries", disorder);
    CHECK(unknown == 0, "%d deliveries with an unknown seq", unknown);
    CHECK(delivered <= N, "delivered %d > sent %d", delivered, N);
    free(sseq); free(slen);
    qpsk_fec_enc_free(e); qpsk_fec_dec_free(d);
#undef DRAIN
#undef PLBYTE
}

static void t_e2e(void)
{
    double raw, res;
    printf("\n  end-to-end erasure channel (N=20000 payload frames)\n");
    printf("    %-22s %8s %8s %8s\n", "config", "raw%", "resid%", "gain");
    e2e(8, 1, 0.00, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %s\n", "K=8 R=1  p=0%", raw, res, "-");
    CHECK(res < 0.01, "clean channel lost %.2f%%", res);

    e2e(8, 1, 0.01, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %5.1fx\n", "K=8 R=1  p=1%", raw, res,
           res > 0 ? raw / res : 999.0);
    CHECK(res < raw / 3.0, "K=8 R=1 p=1%%: residual %.2f vs raw %.2f", res, raw);

    e2e(8, 1, 0.03, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %5.1fx\n", "K=8 R=1  p=3%", raw, res,
           res > 0 ? raw / res : 999.0);
    CHECK(res < raw / 2.5, "K=8 R=1 p=3%%: residual %.2f vs raw %.2f", res, raw);

    e2e(8, 2, 0.03, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %5.1fx\n", "K=8 R=2  p=3%", raw, res,
           res > 0 ? raw / res : 999.0);
    CHECK(res < raw / 6.0, "K=8 R=2 p=3%%: residual %.2f vs raw %.2f", res, raw);

    e2e(4, 1, 0.03, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %5.1fx\n", "K=4 R=1  p=3%", raw, res,
           res > 0 ? raw / res : 999.0);

    e2e(8, 1, 0.10, 20000, &raw, &res);
    printf("    %-22s %7.2f%% %7.2f%%   %5.1fx\n", "K=8 R=1  p=10%", raw, res,
           res > 0 ? raw / res : 999.0);

    /* --- the deployed link ------------------------------------------------
     * Sized against TWO measurements on 146, both 2026-09-24, because the loss
     * rate is not one number -- it depends on what the camera is looking at,
     * which is exactly the user-visible symptom ("glitches when things move").
     *
     * A. quiet, two consecutive 5 s stats lines
     *      seq_gap 115 / dma_rx_ok 2708 / idle_rx 3166  per 5 s
     *      -> 115/(2708+115) = 4.07% loss, 541.6 payload f/s, 633 idle f/s
     * B. live under motion, an 8 s delta taken while the camera was streaming
     *      seq_gap +342 / dma_rx_ok +5203 / idle_rx +6153  per 8 s
     *      -> 342/(5203+342) = 6.17% loss, 650.4 payload f/s, 769.1 idle f/s
     *
     * seq_gap counts lost PAYLOAD frames directly: idle frames do NOT consume
     * tx_seq.  Idle frames are pure filler, so parity displaces THEM, not
     * video -- which is why the air cost column can be paid out of the filler
     * budget on the last line rather than out of bitrate.
     *
     * Size for B, the worse case: it is the one the user actually complains
     * about, and B also has MORE filler to spend, so it costs nothing to. */
    {
        const int Ks[] = {8, 8, 8, 4, 16, 16};
        const int Rs[] = {1, 2, 3, 1,  2,  3};
        const double ps[2]   = {0.0407, 0.0617};
        const double rate[2] = {541.6,  650.4};
        const double idle[2] = {633.0,  769.1};
        const char  *nm[2]   = {"A: quiet          (4.07% payload frames)",
                                "B: under motion   (6.17% payload frames)"};
        int q, b;
        for (b = 0; b < 2; b++) {
            printf("\n  %s\n", nm[b]);
            printf("    %-10s %8s %8s %8s %10s\n", "K/R", "raw%", "resid%", "gain", "air cost");
            for (q = 0; q < 6; q++) {
                e2e(Ks[q], Rs[q], ps[b], 20000, &raw, &res);
                printf("    K=%-2d R=%-4d %7.2f%% %7.2f%%  %6.1fx %8.1f f/s\n",
                       Ks[q], Rs[q], raw, res, res > 0 ? raw / res : 9999.0,
                       rate[b] * Rs[q] / Ks[q]);
            }
            printf("    (idle filler available to spend: %.0f f/s)\n", idle[b]);
        }
    }
}

int main(void)
{
    printf("test_fec\n");
    t_matrix();      printf("  matrix        ok\n");
    t_recover();     printf("  recovery      ok\n");
    t_sniff();       printf("  sniffing      ok\n");
    t_limits();      printf("  limits        ok\n");
    t_ordering();    printf("  ordering      ok\n");
    t_unrecoverable(); printf("  unrecoverable ok\n");
    t_e2e();
    if (fails) { printf("\nFAILED: %d check(s)\n", fails); return 1; }
    printf("\nAll tests passed.\n");
    return 0;
}
