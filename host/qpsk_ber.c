/* qpsk_ber -- full-packet bit-error scorer (see qpsk_ber.h). */
#include "qpsk_ber.h"
#include <string.h>
#include <stdlib.h>

/* Fixed reference seq: a len==0 frame with this seq is fully deterministic
 * (fixed header + PN9 padding seeded by the low 9 bits of the seq), so the
 * whole reference packet is a known constant, identical on both endpoints.
 * Override at runtime with env QBER_SEED (must match on BOTH endpoints) to
 * test pattern- vs position-dependence of the OTA error map. */
#define QBER_REF_SEQ 0x000001A5u

static int popc8(unsigned char b)
{
    return __builtin_popcount((unsigned int)b);
}

/* Hamming distance of rx vs ref cyclically word-rotated by k words (8k bytes).
 * k==0 is the direct (aligned) comparison. */
static int hamming_rot(const unsigned char *rx, const unsigned char *ref,
                       int n, int k)
{
    int shift = (k * 8) % n;
    int h = 0;
    for (int i = 0; i < n; i++)
        h += popc8((unsigned char)(rx[i] ^ ref[(i + shift) % n]));
    return h;
}

void qpsk_ber_make_ref(unsigned char *ref, int pkt_bytes)
{
    /* len==0 -> header (fixed seq) + PN9 padding (seeded by that seq): all
     * pkt_bytes deterministic. Reuses the daemon's exact encode path. The seed
     * (and thus the whole reference) is overridable via env QBER_SEED so the
     * OTA error map can be re-measured with a different known pattern. */
    uint32_t seq = QBER_REF_SEQ;
    const char *e = getenv("QBER_SEED");
    if (e && *e)
        seq = (uint32_t)strtoul(e, NULL, 0);
    if (getenv("QBER_ZERO")) {
        /* pathological LOW-entropy payload (all-zero) to exercise the whitener:
         * without whitening this radiates a near-constant symbol run that
         * stresses the carrier/timing loops; with whitening it is high-entropy. */
        unsigned char zeros[QPSK_PKT_BYTES_MAX];
        int maxp = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
        memset(zeros, 0, (size_t)maxp);
        (void)qpsk_frame_encode(ref, pkt_bytes, zeros, maxp, seq);
    } else {
        (void)qpsk_frame_encode(ref, pkt_bytes, NULL, 0, seq);
    }
    /* qpsk_frame_encode already applies the whitener when QPSK_WHITEN is set, so
     * ref equals what goes on air (both TX and the -B raw compare use it). */
}

void qpsk_ber_reset(struct qpsk_ber_stats *s, int pkt_bytes)
{
    memset(s, 0, sizeof(*s));
    s->pkt_bytes = pkt_bytes;
}

/* Accumulate per-offset bit errors and the error-run (burst) histogram for an
 * ALIGNED frame. The error bit stream is walked MSB-first within each byte and
 * sequentially across bytes, so a burst that straddles a byte boundary counts
 * as one run. */
static void accumulate_aligned(const unsigned char *rx, const unsigned char *ref,
                               struct qpsk_ber_stats *s)
{
    int n = s->pkt_bytes;
    int run = 0;
    for (int i = 0; i < n; i++) {
        unsigned char e = (unsigned char)(rx[i] ^ ref[i]);
        s->per_offset[i] += (uint64_t)popc8(e);
        for (int bit = 7; bit >= 0; bit--) {
            if ((e >> bit) & 1u) {
                run++;
            } else if (run) {
                s->burst_hist[run > QBER_MAX_BURST ? QBER_MAX_BURST : run]++;
                run = 0;
            }
        }
    }
    if (run)
        s->burst_hist[run > QBER_MAX_BURST ? QBER_MAX_BURST : run]++;
}

int qpsk_ber_score_frame(const unsigned char *rx, const unsigned char *ref,
                         struct qpsk_ber_stats *s)
{
    int n = s->pkt_bytes;
    int bits = n * 8;
    int nwords = n / 8;

    int ham0 = hamming_rot(rx, ref, n, 0);
    int best_ham = ham0, best_k = 0;
    for (int k = 1; k < nwords; k++) {
        int h = hamming_rot(rx, ref, n, k);
        if (h < best_ham) { best_ham = h; best_k = k; }
    }

    double f0 = (double)ham0 / (double)bits;
    double fb = (double)best_ham / (double)bits;

    int b;
    if (ham0 == 0)
        b = QBER_CLEAN;
    else if (f0 < QBER_NOISY_FRAC)
        b = QBER_NOISY;                       /* aligned, low BER -> counts */
    else if (fb < QBER_NOISY_FRAC && best_k != 0)
        b = QBER_ROTATED;                     /* a word-rotation aligns it */
    else if (f0 >= QBER_PHASE_FRAC)
        b = QBER_PHASE;                       /* aligned but scrambled/flipped */
    else
        b = QBER_MISS;                        /* junk / false trigger on noise */

    s->frames_scored++;
    s->bucket[b]++;
    if (b == QBER_CLEAN || b == QBER_NOISY) {
        s->total_bits += (uint64_t)bits;
        s->total_bit_errors += (uint64_t)ham0;
        if (b == QBER_NOISY)                  /* CLEAN has no errors to bin */
            accumulate_aligned(rx, ref, s);
    }
    return b;
}

void qpsk_ber_report(const struct qpsk_ber_stats *s, FILE *f)
{
    static const char *names[QBER_NBUCKET] = {
        "CLEAN", "NOISY", "PHASE", "ROTATED", "MISS"
    };
    double ber = s->total_bits
        ? (double)s->total_bit_errors / (double)s->total_bits : 0.0;

    fprintf(f, "=== qpsk_ber full-packet report (pkt=%d B / %d bits) ===\n",
            s->pkt_bytes, s->pkt_bytes * 8);
    fprintf(f, "frames_scored=%llu  aligned(clean+noisy)=%llu  "
               "total_bits=%llu  bit_errors=%llu  BER=%.3e\n",
            (unsigned long long)s->frames_scored,
            (unsigned long long)(s->bucket[QBER_CLEAN] + s->bucket[QBER_NOISY]),
            (unsigned long long)s->total_bits,
            (unsigned long long)s->total_bit_errors, ber);

    fprintf(f, "buckets:");
    for (int i = 0; i < QBER_NBUCKET; i++) {
        double pct = s->frames_scored
            ? 100.0 * (double)s->bucket[i] / (double)s->frames_scored : 0.0;
        fprintf(f, " %s=%llu(%.1f%%)", names[i],
                (unsigned long long)s->bucket[i], pct);
    }
    fprintf(f, "\n");

    /* per-offset error map: bit errors at each byte position (16/line). A
     * front/back skew reveals sync-settling vs intra-frame drift. */
    uint64_t off_max = 0;
    for (int i = 0; i < s->pkt_bytes; i++)
        if (s->per_offset[i] > off_max) off_max = s->per_offset[i];
    if (off_max) {
        fprintf(f, "per-offset bit errors (byte 0..%d):\n", s->pkt_bytes - 1);
        for (int i = 0; i < s->pkt_bytes; i++) {
            if (i % 16 == 0) fprintf(f, "  [%3d]", i);
            fprintf(f, " %6llu", (unsigned long long)s->per_offset[i]);
            if (i % 16 == 15) fprintf(f, "\n");
        }
        if (s->pkt_bytes % 16) fprintf(f, "\n");
    }

    /* error-run (burst) histogram: run length -> count. Isolated single-bit
     * flips (bin 1) = AWGN; long runs = cycle slips / Viterbi bursts. */
    int any_burst = 0;
    for (int i = 1; i <= QBER_MAX_BURST; i++)
        if (s->burst_hist[i]) { any_burst = 1; break; }
    if (any_burst) {
        fprintf(f, "burst-length histogram (run bits -> count):\n");
        for (int i = 1; i <= QBER_MAX_BURST; i++)
            if (s->burst_hist[i])
                fprintf(f, "  len%s%d: %llu\n",
                        i == QBER_MAX_BURST ? ">=" : "=", i,
                        (unsigned long long)s->burst_hist[i]);
    }
    fflush(f);
}

/* ---- self-test: inject known patterns, assert scorer outputs ---- */
#define QBER_CHECK(cond) do { if (!(cond)) { \
        fprintf(stderr, "qpsk_ber_selftest FAIL: %s (line %d)\n", #cond, __LINE__); \
        return 1; } } while (0)

/* flip serial bit g (MSB-first within a byte, sequential across bytes) */
static void flip_bit(unsigned char *buf, int g)
{
    buf[g / 8] ^= (unsigned char)(1u << (7 - (g % 8)));
}

int qpsk_ber_selftest(void)
{
    const int N = 128;
    unsigned char ref[QPSK_PKT_BYTES_MAX], t[QPSK_PKT_BYTES_MAX];
    struct qpsk_ber_stats s;
    int b;

    qpsk_ber_make_ref(ref, N);
    /* determinism: a second build must be byte-identical */
    qpsk_ber_make_ref(t, N);
    QBER_CHECK(memcmp(ref, t, (size_t)N) == 0);

    /* whitener: self-inverse and non-identity */
    memcpy(t, ref, (size_t)N);
    qpsk_whiten(t, N);
    QBER_CHECK(memcmp(t, ref, (size_t)N) != 0);   /* whitening changes the bytes */
    qpsk_whiten(t, N);
    QBER_CHECK(memcmp(t, ref, (size_t)N) == 0);   /* applied twice -> identity */

    qpsk_ber_reset(&s, N);

    /* 1. CLEAN */
    b = qpsk_ber_score_frame(ref, ref, &s);
    QBER_CHECK(b == QBER_CLEAN);

    /* 2. NOISY: single bit at byte 50 */
    memcpy(t, ref, (size_t)N);
    flip_bit(t, 50 * 8 + 3);
    b = qpsk_ber_score_frame(t, ref, &s);
    QBER_CHECK(b == QBER_NOISY);
    QBER_CHECK(s.per_offset[50] == 1);
    QBER_CHECK(s.burst_hist[1] == 1);

    /* 3. NOISY: 5-bit contiguous burst inside byte 30 */
    memcpy(t, ref, (size_t)N);
    for (int g = 30 * 8 + 2; g <= 30 * 8 + 6; g++) flip_bit(t, g);
    b = qpsk_ber_score_frame(t, ref, &s);
    QBER_CHECK(b == QBER_NOISY);
    QBER_CHECK(s.per_offset[30] == 5);
    QBER_CHECK(s.burst_hist[5] == 1);

    /* aligned accounting after cases 1-3 */
    QBER_CHECK(s.bucket[QBER_CLEAN] == 1);
    QBER_CHECK(s.bucket[QBER_NOISY] == 2);
    QBER_CHECK(s.total_bits == (uint64_t)(3 * N * 8));
    QBER_CHECK(s.total_bit_errors == 6);

    /* 4. PHASE: full 180 complement (f0 = 1.0) */
    for (int i = 0; i < N; i++) t[i] = (unsigned char)~ref[i];
    b = qpsk_ber_score_frame(t, ref, &s);
    QBER_CHECK(b == QBER_PHASE);

    /* 5. ROTATED: reference rotated by 3 words */
    for (int i = 0; i < N; i++) t[i] = ref[(i + 3 * 8) % N];
    b = qpsk_ber_score_frame(t, ref, &s);
    QBER_CHECK(b == QBER_ROTATED);

    /* 6. MISS: ~19.5% aligned errors (first 25 bytes complemented), no
     *    rotation aligns it, below the PHASE band */
    memcpy(t, ref, (size_t)N);
    for (int i = 0; i < 25; i++) t[i] = (unsigned char)~ref[i];
    b = qpsk_ber_score_frame(t, ref, &s);
    QBER_CHECK(b == QBER_MISS);

    /* totals: cases 4/5/6 do not touch the BER accumulators */
    QBER_CHECK(s.frames_scored == 6);
    QBER_CHECK(s.bucket[QBER_PHASE] == 1);
    QBER_CHECK(s.bucket[QBER_ROTATED] == 1);
    QBER_CHECK(s.bucket[QBER_MISS] == 1);
    QBER_CHECK(s.total_bits == (uint64_t)(3 * N * 8));
    QBER_CHECK(s.total_bit_errors == 6);

    fprintf(stderr, "qpsk_ber_selftest OK (6 cases + whitener)\n");
    return 0;
}
