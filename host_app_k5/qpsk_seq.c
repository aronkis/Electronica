/* qpsk_seq -- loss-proof sequence-streaming scorer. See qpsk_seq.h. */
#include <stdlib.h>
#include <string.h>
#include "qpsk_seq.h"

/* The in-fabric traffic generator (qpsk_traffic_gen, 2026-08-17) has no CRC
 * engine: it writes this CONSTANT in the frame's CRC field (design Approach 1,
 * mirrored in tgen_golden.c). qpsk_frame_decode() therefore can never accept a
 * generator frame; the structural-accept path below scores them instead. */
#define QPSK_TGEN_CRC_CONST 0x54474E21u

static int tgen_force;          /* selftest hook, bypasses the env gate */
static int tgen_on(void)
{
    static int v = -1;
    if (tgen_force)
        return 1;
    if (v < 0) {
        /* QPSK_SEQ_RXONLY exists only for scoring the in-fabric generator
         * (qpsk_tun.c seq_rxonly), so it doubles as the tgen-frame gate. */
        const char *e = getenv("QPSK_SEQ_RXONLY");
        v = (e && *e != '0');
    }
    return v;
}

void qpsk_seq_payload(unsigned char *buf, int len, uint32_t seq)
{
    uint32_t x = seq ^ 0x9E3779B9u;
    if (x == 0)
        x = 0xDEADBEEFu;
    for (int i = 0; i < len; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        buf[i] = (unsigned char)(x & 0xFFu);
    }
}

void qpsk_seq_expected(unsigned char *frame, int pkt_bytes, uint32_t seq)
{
    unsigned char payload[QPSK_SEQ_PAYLOAD_LEN];
    qpsk_seq_payload(payload, QPSK_SEQ_PAYLOAD_LEN, seq);
    qpsk_frame_encode(frame, pkt_bytes, payload, QPSK_SEQ_PAYLOAD_LEN, seq);
}

void qpsk_seq_reset(struct qpsk_seq_stats *s, int pkt_bytes, int batch_m)
{
    void (*evt)(void *, const char *, uint32_t, uint32_t, double) = s->evt;
    void *ctx = s->evt_ctx;
    FILE *rawf = s->rawf;
    memset(s, 0, sizeof *s);
    s->pkt_bytes = pkt_bytes;
    s->batch_m   = batch_m;
    s->evt = evt;
    s->evt_ctx = ctx;
    s->rawf = rawf;
}

static void raw_dump(struct qpsk_seq_stats *s, const char *cls, uint32_t seq,
                     const unsigned char *raw, double t)
{
    if (!s->rawf)
        return;
    fprintf(s->rawf, "RAW t=%.6f seq=%u class=%s hex=", t, seq, cls);
    for (int i = 0; i < s->pkt_bytes; i++)
        fprintf(s->rawf, "%02x", raw[i]);
    fprintf(s->rawf, "\n");
    fflush(s->rawf);
}

static void emit(struct qpsk_seq_stats *s, const char *type, uint32_t seq,
                 uint32_t n, double t)
{
    if (s->evt)
        s->evt(s->evt_ctx, type, seq, n, t);
}

static const unsigned char popc8[256] = {
#define B2(n) n, n + 1, n + 1, n + 2
#define B4(n) B2(n), B2(n + 1), B2(n + 1), B2(n + 2)
#define B6(n) B4(n), B4(n + 1), B4(n + 1), B4(n + 2)
    B6(0), B6(1), B6(1), B6(2)
#undef B6
#undef B4
#undef B2
};

/* bit errors of raw vs expected(seq); optionally accumulate per-offset */
static int bitdiff(struct qpsk_seq_stats *s, const unsigned char *raw,
                   uint32_t seq, int accumulate)
{
    unsigned char exp[QPSK_PKT_BYTES_MAX];
    int errs = 0;
    qpsk_seq_expected(exp, s->pkt_bytes, seq);
    for (int i = 0; i < s->pkt_bytes; i++) {
        int e = popc8[raw[i] ^ exp[i]];
        errs += e;
        if (accumulate && e)
            s->per_offset[i] += (uint64_t)e;
    }
    return errs;
}

/* generator frame ground truth: header (QK, len=fill, seq, CRC const) + PN
 * over fill bytes + zero pad to pkt_bytes -- mirror of tgen_golden.c build() */
static void tgen_expected(unsigned char *f, int pkt_bytes, uint32_t seq, int fill)
{
    memset(f, 0, (size_t)pkt_bytes);
    f[0] = 0x51; f[1] = 0x4B;
    f[2] = (unsigned char)(fill & 0xFF);
    f[3] = (unsigned char)((fill >> 8) & 0xFF);
    f[4] = (unsigned char)(seq & 0xFF);
    f[5] = (unsigned char)((seq >> 8) & 0xFF);
    f[6] = (unsigned char)((seq >> 16) & 0xFF);
    f[7] = (unsigned char)((seq >> 24) & 0xFF);
    f[8]  = (unsigned char)(QPSK_TGEN_CRC_CONST & 0xFF);
    f[9]  = (unsigned char)((QPSK_TGEN_CRC_CONST >> 8) & 0xFF);
    f[10] = (unsigned char)((QPSK_TGEN_CRC_CONST >> 16) & 0xFF);
    f[11] = (unsigned char)((QPSK_TGEN_CRC_CONST >> 24) & 0xFF);
    qpsk_seq_payload(f + QPSK_FRAME_HDR_BYTES, fill, seq);
}

/* public: build a TGEN-format frame (host TX leg of the TX-seam checker) */
void qpsk_seq_tgen_frame(unsigned char *frame, int pkt_bytes, uint32_t seq, int fill)
{
    if (fill < 0) fill = 0;
    if (fill > QPSK_FRAME_MAX_PAYLOAD(pkt_bytes)) fill = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
    tgen_expected(frame, pkt_bytes, seq, fill);
}

static int tgen_bitdiff(struct qpsk_seq_stats *s, const unsigned char *raw,
                        uint32_t seq, int fill, int accumulate)
{
    unsigned char exp[QPSK_PKT_BYTES_MAX];
    int errs = 0;
    tgen_expected(exp, s->pkt_bytes, seq, fill);
    for (int i = 0; i < s->pkt_bytes; i++) {
        int e = popc8[raw[i] ^ exp[i]];
        errs += e;
        if (accumulate && e)
            s->per_offset[i] += (uint64_t)e;
    }
    return errs;
}

/* close an open junk run (emit its summary event) */
static void junk_flush(struct qpsk_seq_stats *s, double t)
{
    if (s->junk_run) {
        emit(s, "junkrun", s->next_expect, (uint32_t)s->junk_run, t);
        s->junk_run = 0;
    }
}

/* account an attributed frame at seq with errs bit errors */
static int attribute(struct qpsk_seq_stats *s, uint32_t seq, int errs, double t,
                     const unsigned char *raw)
{
    junk_flush(s, t);
    if (!s->have_first) {
        s->have_first = 1;
        s->first_seq = seq;
        s->next_expect = seq;
    }
    if ((int32_t)(seq - s->next_expect) < 0) {
        s->dup++;
        emit(s, "dup", seq, 0, t);
        return QSEQ_DUP;
    }
    if (seq != s->next_expect) {
        uint32_t missed = seq - s->next_expect;
        s->lost += missed;
        s->lost_events++;
        /* LAYER B: a run that is an exact multiple of the batch depth is a DROPPED
         * BATCH, not the periodic single-slot loss. Only meaningful with batch_m set. */
        if (s->batch_m > 0 && missed >= (uint32_t)s->batch_m &&
            (missed % (uint32_t)s->batch_m) == 0)
            s->batch_drop++;
        emit(s, "lost", s->next_expect, missed, t);
    }
    /* LAYER B: is this corruption a DMA tear or a decode error? Walk 8-byte words
     * (the byte-DMA's transfer granularity -- a tear cannot land finer than that) and
     * find the first mismatching word; if everything BEFORE it matches expected(seq)
     * and everything AFTER is either all-zero or consistent with a different seq, the
     * slice was torn, not mis-decoded. */
    if (errs) {
        unsigned char exp[QPSK_PKT_BYTES_MAX];
        int nw = s->pkt_bytes / 8, w, split = -1;
        qpsk_seq_expected(exp, s->pkt_bytes, seq);
        for (w = 0; w < nw; w++)
            if (memcmp(raw + w*8, exp + w*8, 8) != 0) { split = w; break; }
        if (split > 0) {                       /* a good prefix exists */
            int allzero = 1, k;
            for (k = split*8; k < s->pkt_bytes; k++)
                if (raw[k]) { allzero = 0; break; }
            /* every word from the split on must differ -- a single bad word in the
             * middle followed by good data is scattered corruption, not a tear */
            int tail_all_bad = 1;
            for (w = split; w < nw; w++)
                if (memcmp(raw + w*8, exp + w*8, 8) == 0) { tail_all_bad = 0; break; }
            unsigned off = (unsigned)(split * 8);
            if (allzero) {
                s->torn_zero++;
                if (!s->tear_off_min || off < s->tear_off_min) s->tear_off_min = off;
                if (off > s->tear_off_max) s->tear_off_max = off;
                raw_dump(s, "TORN_ZERO", seq, raw, t);
            } else if (tail_all_bad) {
                s->torn_stale++;
                if (!s->tear_off_min || off < s->tear_off_min) s->tear_off_min = off;
                if (off > s->tear_off_max) s->tear_off_max = off;
                raw_dump(s, "TORN_STALE", seq, raw, t);
            } else {
                s->scattered++;
            }
        } else {
            s->scattered++;                    /* corrupt from the very first word */
        }
    }
    s->total_bits += (uint64_t)s->pkt_bytes * 8u;
    s->total_bit_errors += (uint64_t)errs;
    if (errs) {
        s->biterr++;
        emit(s, "biterr", seq, (uint32_t)errs, t);
    } else {
        s->ok++;
    }
    s->next_expect = seq + 1;
    return errs ? QSEQ_BITERR : QSEQ_OK;
}

/* rotate left by `words` 8-byte words (the byte-DMA delivery unit): a missed
 * SYNC_TRANSFER_START at arm shifts EVERY delivered frame by a constant word
 * rotation -- CRC never passes and the link reads as junk-forever. Detect it
 * once at anchor, then de-rotate the whole stream. */
static void rot_words(unsigned char *dst, const unsigned char *src, int n,
                      int words)
{
    int off = (words * 8) % n;
    memcpy(dst, src + off, (size_t)(n - off));
    memcpy(dst + (n - off), src, (size_t)off);
}

int qpsk_seq_score_frame(struct qpsk_seq_stats *s, const unsigned char *raw,
                         double t)
{
    unsigned char out[QPSK_PKT_BYTES_MAX];
    unsigned char dw[QPSK_PKT_BYTES_MAX];
    unsigned char rr[QPSK_PKT_BYTES_MAX];
    const unsigned char *p;
    uint32_t seq;
    int m, errs;

    s->frames_scored++;

    /* stream de-rotation (see rot_words) */
    if (s->rot_off) {
        rot_words(rr, raw, s->pkt_bytes, s->rot_off);
        raw = rr;
    }
    p = raw;

    /* fast path: intact frame -- seq is exact, zero bit errors */
    m = qpsk_frame_decode(raw, s->pkt_bytes, out, &seq);
    if (m >= 0)
        return attribute(s, seq, 0, t, raw);

    /* pre-anchor: probe for a constant word rotation (byte-DMA misalignment) */
    if (!s->have_first && s->rot_off == 0) {
        for (int r = 1; r < s->pkt_bytes / 8; r++) {
            unsigned char rt[QPSK_PKT_BYTES_MAX];
            rot_words(rt, raw, s->pkt_bytes, r);
            if (qpsk_frame_decode(rt, s->pkt_bytes, out, &seq) >= 0) {
                s->rot_off = r;
                emit(s, "wordrot", seq, (uint32_t)r, t);
                return attribute(s, seq, 0, t, raw);
            }
            /* TGEN structural probe at this rotation (2026-08-18): constant-CRC
             * generator frames can never pass qpsk_frame_decode, so without
             * this leg a word-rotated generator stream — the RX seam has no
             * frame/transfer realignment mechanism, so arming mid-stream
             * yields a constant rotation — reads as junk forever. */
            if (tgen_on() && rt[0] == 0x51 && rt[1] == 0x4B) {
                int tf = (int)rt[2] | ((int)rt[3] << 8);
                uint32_t tc = (uint32_t)rt[8] | ((uint32_t)rt[9] << 8) |
                              ((uint32_t)rt[10] << 16) | ((uint32_t)rt[11] << 24);
                if (tf <= QPSK_FRAME_MAX_PAYLOAD(s->pkt_bytes) &&
                    tc == QPSK_TGEN_CRC_CONST) {
                    uint32_t tseq = (uint32_t)rt[4] | ((uint32_t)rt[5] << 8) |
                                    ((uint32_t)rt[6] << 16) | ((uint32_t)rt[7] << 24);
                    int terr = tgen_bitdiff(s, rt, tseq, tf, 0);
                    if (terr * 100 < s->pkt_bytes * 8 * 35) {
                        s->rot_off = r;
                        emit(s, "wordrot", tseq, (uint32_t)r, t);
                        if (terr)
                            tgen_bitdiff(s, rt, tseq, tf, 1);
                        return attribute(s, tseq, terr, t, rt);
                    }
                }
            }
        }
    }

    /* CRC fail: read the raw seq field from the de-whitened view */
    if (qpsk_whiten_on()) {
        memcpy(dw, raw, (size_t)s->pkt_bytes);
        qpsk_whiten(dw, s->pkt_bytes);
        p = dw;
    }
    seq = (uint32_t)p[4] | ((uint32_t)p[5] << 8) |
          ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 24);

    /* TGEN structural accept (2026-08-17): generator frames carry the CRC
     * CONSTANT, so the decode fast path above can never take them (T8 smoke
     * scored 21,619 bit-perfect generator frames as junk). Accept on
     * magic + sane len + the constant, score payload bits against the
     * regenerated PN + zero pad, and anchor/attribute exactly like a
     * decoded frame so lost/dup accounting works. Requires QPSK_WHITEN=0:
     * generator frames are never whitened on the wire, so the de-whitened
     * view p would scramble them and this gate would never match. */
    if (tgen_on() && p[0] == 0x51 && p[1] == 0x4B) {
        int fill = (int)p[2] | ((int)p[3] << 8);
        uint32_t cf = (uint32_t)p[8] | ((uint32_t)p[9] << 8) |
                      ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 24);
        /* WINDOW CHECK (2026-08-18): mirror the normal path's seq plausibility
         * gate. Without it, ONE frame with a corrupted seq field (magic/len/
         * const intact -- and at short fills the PN region is too small for
         * the 35% bitdiff threshold to reject it) re-anchors next_expect
         * arbitrarily far: observed on silicon as a 16,344-frame phantom
         * "lost" followed by a 26 s dup avalanche (fill=48 run, 08:00). */
        int seq_plausible = !s->have_first ||
            ((int32_t)(seq - s->next_expect) >= -QPSK_SEQ_WINDOW &&
             (int32_t)(seq - s->next_expect) <   QPSK_SEQ_WINDOW);
        if (seq_plausible &&
            fill <= QPSK_FRAME_MAX_PAYLOAD(s->pkt_bytes) &&
            cf == QPSK_TGEN_CRC_CONST) {
            errs = tgen_bitdiff(s, p, seq, fill, 0);
            if (errs * 100 < s->pkt_bytes * 8 * 35) {   /* frac < 0.35 */
                if (errs) {
                    tgen_bitdiff(s, p, seq, fill, 1);
                    raw_dump(s, "biterr", seq, raw, t);
                }
                return attribute(s, seq, errs, t, raw);
            }
        }
    }

    if (s->have_first) {
        int32_t d = (int32_t)(seq - s->next_expect);
        if (d >= 0 && d < QPSK_SEQ_WINDOW) {
            /* plausibly a near-future frame: score vs its expectation */
            errs = bitdiff(s, raw, seq, 0);
            if (errs * 100 < s->pkt_bytes * 8 * 35) {   /* frac < 0.35 */
                bitdiff(s, raw, seq, 1);                 /* accumulate map */
                raw_dump(s, "biterr", seq, raw, t);
                return attribute(s, seq, errs, t, raw);
            }
        } else if (d < 0 && -d <= QPSK_SEQ_WINDOW) {
            errs = bitdiff(s, raw, seq, 0);
            if (errs * 100 < s->pkt_bytes * 8 * 35) {
                junk_flush(s, t);
                s->dup++;
                emit(s, "dup", seq, (uint32_t)errs, t);
                return QSEQ_DUP;
            }
        }
        /* raw seq untrustworthy: maybe only the header got hit -- try the
         * frame we are expecting right now */
        errs = bitdiff(s, raw, s->next_expect, 0);
        if (errs * 100 < s->pkt_bytes * 8 * 35) {
            bitdiff(s, raw, s->next_expect, 1);
            raw_dump(s, "biterr-hdr", s->next_expect, raw, t);
            return attribute(s, s->next_expect, errs, t, raw);
        }
    }

    /* unattributable garbage (outage burst / pre-anchor noise) */
    if (s->junk_run == 0)
        emit(s, "junkstart", s->next_expect, 0, t);
    raw_dump(s, "junk", s->next_expect, raw, t);
    s->junk_run++;
    s->junk++;
    return QSEQ_JUNK;
}

void qpsk_seq_report(const struct qpsk_seq_stats *s, FILE *f, double elapsed_s)
{
    fprintf(f, "SEQDMA torn_zero=%llu torn_stale=%llu scattered=%llu "
            "batch_drop=%llu batch_m=%d tear_off=%u..%u\n",
            (unsigned long long)s->torn_zero, (unsigned long long)s->torn_stale,
            (unsigned long long)s->scattered, (unsigned long long)s->batch_drop,
            s->batch_m, (unsigned)s->tear_off_min, (unsigned)s->tear_off_max);
    double ber = s->total_bits
        ? (double)s->total_bit_errors / (double)s->total_bits : 0.0;
    uint64_t accounted = s->ok + s->biterr + s->lost;
    double air = elapsed_s / 4.72e-3;   /* K5 frame period */
    fprintf(f,
        "SEQRX frames_scored=%llu ok=%llu biterr=%llu lost=%llu (%llu gaps) "
        "dup=%llu junk=%llu\n",
        (unsigned long long)s->frames_scored, (unsigned long long)s->ok,
        (unsigned long long)s->biterr, (unsigned long long)s->lost,
        (unsigned long long)s->lost_events, (unsigned long long)s->dup,
        (unsigned long long)s->junk);
    fprintf(f,
        "SEQRX seq_span=%llu accounted=%llu (ok+biterr+lost) "
        "air_expect~%.0f frames in %.1fs\n",
        s->have_first ? (unsigned long long)(s->next_expect - s->first_seq) : 0ull,
        (unsigned long long)accounted, air, elapsed_s);
    fprintf(f, "SEQRX total_bits=%llu bit_errors=%llu BER=%.3e "
            "(over ok+biterr frames)\n",
        (unsigned long long)s->total_bits,
        (unsigned long long)s->total_bit_errors, ber);
    if (s->total_bit_errors) {
        fprintf(f, "per-offset bit errors (byte 0..%d):\n", s->pkt_bytes - 1);
        for (int i = 0; i < s->pkt_bytes; i++) {
            if (i % 16 == 0)
                fprintf(f, "  [%3d]", i);
            fprintf(f, " %6llu", (unsigned long long)s->per_offset[i]);
            if (i % 16 == 15)
                fprintf(f, "\n");
        }
    }
}

/* ---------------- self-test (no hardware) ---------------- */
static struct { int n; char last[16]; uint32_t seq, cnt; } tev;
static void tevt(void *ctx, const char *type, uint32_t seq, uint32_t n, double t)
{
    (void)ctx; (void)t;
    tev.n++;
    snprintf(tev.last, sizeof tev.last, "%s", type);
    tev.seq = seq;
    tev.cnt = n;
}

#define CHK(cond, msg) do { if (!(cond)) { \
    fprintf(stderr, "qpsk_seq_selftest FAIL: %s\n", msg); return 1; } } while (0)

int qpsk_seq_selftest(void)
{
    unsigned char f[QPSK_PKT_BYTES_MAX], g[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    struct qpsk_seq_stats s;
    uint32_t seq;
    int pkt = 128;

    /* payload determinism + variation */
    qpsk_seq_payload(f, 64, 7);
    qpsk_seq_payload(g, 64, 7);
    CHK(memcmp(f, g, 64) == 0, "payload not deterministic");
    qpsk_seq_payload(g, 64, 8);
    CHK(memcmp(f, g, 64) != 0, "payload not seq-unique");

    /* expected frame round-trips */
    qpsk_seq_expected(f, pkt, 42);
    CHK(qpsk_frame_decode(f, pkt, out, &seq) == QPSK_SEQ_PAYLOAD_LEN,
        "expected frame does not decode");
    CHK(seq == 42, "expected frame seq mismatch");
    qpsk_seq_payload(g, QPSK_SEQ_PAYLOAD_LEN, 42);
    CHK(memcmp(out, g, QPSK_SEQ_PAYLOAD_LEN) == 0, "payload regen mismatch");

    memset(&s, 0, sizeof s);
    s.evt = tevt;
    qpsk_seq_reset(&s, pkt, 16);

    /* clean run 5..7 */
    for (uint32_t q = 5; q <= 7; q++) {
        qpsk_seq_expected(f, pkt, q);
        CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "clean frame not OK");
    }
    CHK(s.ok == 3 && s.lost == 0 && s.next_expect == 8, "clean accounting");

    /* gap: jump to 10 -> lost 8,9 */
    tev.n = 0;
    qpsk_seq_expected(f, pkt, 10);
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "post-gap frame not OK");
    CHK(s.lost == 2 && s.lost_events == 1, "gap loss count");
    CHK(tev.n == 1 && strcmp(tev.last, "lost") == 0 && tev.seq == 8 &&
        tev.cnt == 2, "lost event");

    /* biterr: corrupt 3 payload bits of seq 11 (CRC breaks, raw seq intact) */
    qpsk_seq_expected(f, pkt, 11);
    f[20] ^= 0x01; f[30] ^= 0x80; f[40] ^= 0x10;
    tev.n = 0;
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_BITERR, "biterr not attributed");
    CHK(s.biterr == 1 && s.total_bit_errors == 3, "biterr count");
    CHK(tev.n == 1 && strcmp(tev.last, "biterr") == 0 && tev.seq == 11 &&
        tev.cnt == 3, "biterr event");
    CHK(s.per_offset[20] == 1 && s.per_offset[30] == 1 && s.per_offset[40] == 1,
        "per-offset map");

    /* header-corrupt biterr: seq field trashed on the expected next frame */
    qpsk_seq_expected(f, pkt, 12);
    f[4] ^= 0xFF; f[5] ^= 0xFF; f[6] ^= 0xFF; f[7] ^= 0x7F;
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_BITERR,
        "header-corrupt frame not attributed to next_expect");
    CHK(s.next_expect == 13, "next_expect after header-corrupt attribution");

    /* junk: garbage does not advance accounting */
    memset(f, 0xA5, (size_t)pkt);
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_JUNK, "garbage not junk");
    CHK(s.junk == 1 && s.next_expect == 13, "junk advanced accounting");

    /* dup: replay of seq 10 */
    qpsk_seq_expected(f, pkt, 10);
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_DUP, "replay not dup");
    CHK(s.dup == 1, "dup count");

    /* full-frame reconstruction identity: every byte accounted */
    qpsk_seq_expected(f, pkt, 13);
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "post-junk clean frame");
    CHK(s.ok + s.biterr + s.lost ==
        (uint64_t)(s.next_expect - s.first_seq), "loss-proof identity");

    /* word-rotation wedge: a constantly rotated stream must self-heal */
    qpsk_seq_reset(&s, pkt, 16);
    for (uint32_t q = 100; q < 104; q++) {
        unsigned char rot[QPSK_PKT_BYTES_MAX];
        qpsk_seq_expected(f, pkt, q);
        memcpy(rot, f + pkt - 3 * 8, 3 * 8);           /* rotate RIGHT by 3 words */
        memmove(rot + 3 * 8, f, (size_t)(pkt - 3 * 8));
        int rc = qpsk_seq_score_frame(&s, rot, 0.0);
        CHK(rc == QSEQ_OK, "rotated frame not recovered");
    }
    CHK(s.rot_off != 0 && s.ok == 4, "rotation lock/accounting");

    /* TGEN structural accept: constant-CRC generator frames must score OK /
     * BITERR / LOST like decoded frames -- and must stay junk when the tgen
     * gate is off (positive AND negative control). */
    qpsk_seq_reset(&s, pkt, 16);
    tgen_expected(f, pkt, 200, 64);
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_JUNK,
        "tgen frame accepted with gate OFF");
    tgen_force = 1;
    qpsk_seq_reset(&s, pkt, 16);
    for (uint32_t q = 200; q <= 202; q++) {
        tgen_expected(f, pkt, q, 64);
        CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "tgen clean not OK");
    }
    CHK(s.ok == 3 && s.next_expect == 203, "tgen clean accounting");
    tgen_expected(f, pkt, 205, 64);              /* gap: lost 203,204 */
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "tgen post-gap not OK");
    CHK(s.lost == 2, "tgen gap loss count");
    tgen_expected(f, pkt, 206, 64);
    f[20] ^= 0x01; f[30] ^= 0x80;                /* 2 payload bit errors */
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_BITERR, "tgen biterr not scored");
    CHK(s.total_bit_errors == 2, "tgen biterr count");
    tgen_expected(f, pkt, 207, 0);               /* fill=0: header + all-zero pad */
    CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_OK, "tgen fill=0 not OK");
    tgen_expected(f, pkt, 208, 64);
    f[8] ^= 0xFF;                                 /* CRC-const wrong -> not OK */
    CHK(qpsk_seq_score_frame(&s, f, 0.0) != QSEQ_OK, "bad CRC-const accepted");
    {   /* corrupted-seq re-anchor guard: a far-future seq (window exceeded)
         * must NOT attribute -- it would inflate lost and dup-ify the rest */
        uint32_t ne = s.next_expect;
        tgen_expected(f, pkt, ne + 10000, 64);
        CHK(qpsk_seq_score_frame(&s, f, 0.0) == QSEQ_JUNK,
            "far-future tgen seq re-anchored");
        CHK(s.next_expect == ne, "next_expect moved on far-future tgen seq");
    }
    /* word-rotated tgen stream must self-heal via the structural rotation
     * probe (the RX seam has no frame/transfer alignment mechanism) */
    qpsk_seq_reset(&s, pkt, 16);
    for (uint32_t q = 300; q < 304; q++) {
        unsigned char rot[QPSK_PKT_BYTES_MAX];
        tgen_expected(f, pkt, q, 64);
        memcpy(rot, f + pkt - 3 * 8, 3 * 8);           /* rotate RIGHT by 3 words */
        memmove(rot + 3 * 8, f, (size_t)(pkt - 3 * 8));
        CHK(qpsk_seq_score_frame(&s, rot, 0.0) == QSEQ_OK,
            "rotated tgen frame not recovered");
    }
    CHK(s.rot_off != 0 && s.ok == 4, "tgen rotation lock/accounting");
    tgen_force = 0;

    fprintf(stderr, "qpsk_seq_selftest OK\n");
    return 0;
}
