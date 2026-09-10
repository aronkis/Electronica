/* qpsk_ber -- full-packet bit-error scorer for the QPSK byte link.
 *
 * The on-chip BIST checks only a fixed sliver of each packet (cap_out = 32
 * bits, bit_errors = 120 bits) against a hardwired "ADI Hello World"; the
 * host daemon only does whole-frame CRC pass/fail. But the ENTIRE decoded
 * packet (pkt_bytes = 128 B = 1024 bits) is already delivered over the byte-RX
 * DMA every frame. This module compares that whole packet, byte-for-byte,
 * against a fixed known reference so we can measure real full-packet BER and
 * characterise the error STRUCTURE on the OTA links.
 *
 * Two facts shape the design (see the plan / README_BYTE.md):
 *  - A CRC-pass frame has zero bit errors by construction, so BER must be
 *    measured on the RAW received bytes against a header-INDEPENDENT reference
 *    -- never gated on CRC. The BER-bearing frames are the CRC-fail ones.
 *  - A word rotation reads as ~100% error at every offset, so each frame is
 *    first aligned (best word-rotation) and CLASSIFIED, not blind-histogrammed.
 *
 * The reference is a constant frame identical on both endpoints (same binary),
 * so no per-frame header trust is needed: qpsk_ber_make_ref() builds it once.
 */
#ifndef QPSK_BER_H
#define QPSK_BER_H

#include <stdint.h>
#include <stdio.h>
#include "qpsk_frame.h"          /* QPSK_PKT_BYTES_MAX */

/* Per-frame classification buckets (see qpsk_ber_score_frame):
 *   CLEAN    aligned, zero errors (also CRC-pass)          -> link is clean
 *   NOISY    aligned, low BER (< QBER_NOISY_FRAC)          -> SNR/AWGN-limited
 *   PHASE    aligned position but heavily/systematically   -> phase ambiguity/slip
 *            errored (>= QBER_PHASE_FRAC, e.g. ~50% or 180 complement)
 *   ROTATED  a non-zero word-rotation aligns it            -> framing/word slip
 *   MISS     no rotation aligns it, not a clean flip       -> false trigger on noise
 * Only CLEAN + NOISY feed the BER numerator/denominator and the per-offset /
 * burst detail; the bucket counts themselves are the error-source breakdown. */
enum {
    QBER_CLEAN = 0,
    QBER_NOISY,
    QBER_PHASE,
    QBER_ROTATED,
    QBER_MISS,
    QBER_NBUCKET
};

#define QBER_MAX_BYTES  QPSK_PKT_BYTES_MAX   /* per-offset map spans a full packet */
#define QBER_MAX_BURST  64                   /* error-run histogram cap (>= saturates) */

/* classification thresholds (bit-error fraction of a whole packet) */
#define QBER_NOISY_FRAC 0.10   /* aligned & below this => NOISY (counts toward BER) */
#define QBER_PHASE_FRAC 0.35   /* aligned & at/above this => PHASE (gross phase problem) */

struct qpsk_ber_stats {
    int      pkt_bytes;                          /* frame size being scored */
    uint64_t frames_scored;
    uint64_t bucket[QBER_NBUCKET];
    uint64_t total_bits;                         /* denominator: CLEAN+NOISY frames */
    uint64_t total_bit_errors;                   /* numerator */
    uint64_t per_offset[QBER_MAX_BYTES];         /* bit errors per byte position (aligned) */
    uint64_t burst_hist[QBER_MAX_BURST + 1];     /* run-length hist of error bits (aligned) */
};

/* Build the constant reference frame (identical on both endpoints). A len==0
 * frame is fully deterministic: fixed header (fixed seq) + PN9 padding seeded
 * by that fixed seq, so all pkt_bytes are known and comparable header-free. */
void qpsk_ber_make_ref(unsigned char *ref, int pkt_bytes);

/* Zero the stats and record the frame size. */
void qpsk_ber_reset(struct qpsk_ber_stats *s, int pkt_bytes);

/* Score one raw received packet (s->pkt_bytes long) against ref; update s.
 * Returns the QBER_* bucket the frame was classified into. */
int  qpsk_ber_score_frame(const unsigned char *rx, const unsigned char *ref,
                          struct qpsk_ber_stats *s);

/* Human-readable report: BER, bucket breakdown, per-offset error map, burst
 * histogram. */
void qpsk_ber_report(const struct qpsk_ber_stats *s, FILE *f);

/* Self-test: inject known error patterns, assert scorer outputs. Returns 0 on
 * success, nonzero on the first failed assertion. No hardware. */
int  qpsk_ber_selftest(void);

#endif /* QPSK_BER_H */
