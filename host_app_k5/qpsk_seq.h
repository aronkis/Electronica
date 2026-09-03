/* qpsk_seq -- loss-proof sequence-streaming test mode (-S) for the QPSK byte
 * link.
 *
 * -B radiates ONE fixed frame forever, so a transmitted-but-never-framed
 * packet is invisible (MISS only classifies junk that WAS framed) and every
 * frame is identical (no per-frame identity). -S closes both gaps:
 *
 *   TX: every frame carries a monotonically increasing seq (header bytes
 *       [4..7], already in the wire format) and a payload deterministically
 *       regenerable from that seq (xorshift32 stream, len=QPSK_SEQ_PAYLOAD_LEN,
 *       CRC-covered). The full 128-byte wire frame is a pure function of seq
 *       (header + payload + CRC + PN9 pad + optional whitener) -- so any
 *       received frame can be scored bit-for-bit against its regenerated
 *       expectation, and any frame absent from the received seq record is a
 *       PROVEN loss, not a guess.
 *
 *   RX: scores the RAW packet BEFORE the CRC gate (the -B discipline):
 *       CRC-pass  -> OK   (seq trusted exactly; anchors/advances accounting)
 *       CRC-fail  -> recover the raw seq field; if plausibly the next frames
 *                    (monotonic window) score bits vs expected(seq) -> BITERR;
 *                    else try expected(next) -> BITERR at next; else JUNK.
 *       seq jump  -> the skipped seqs are counted LOST (exact count).
 *       seq < expected -> DUP (the link cannot reorder; a dup is a real event).
 *       Every seq in [first, last] ends in exactly one bucket: OK/BITERR/LOST.
 *
 * Events (biterr / lost / dup / junk-run) are delivered through a callback so
 * the runner can append trigger lines to /dev/shm/seq_events.log for the
 * error-triggered IQ ring capture.
 */
#ifndef QPSK_SEQ_H
#define QPSK_SEQ_H

#include <stdint.h>
#include <stdio.h>
#include "qpsk_frame.h"

#define QPSK_SEQ_PAYLOAD_LEN 64   /* CRC-covered unique bytes per frame */
#define QPSK_SEQ_WINDOW      64   /* raw-seq plausibility window (frames) */

enum {
    QSEQ_OK = 0,     /* CRC pass */
    QSEQ_BITERR,     /* CRC fail, attributed to a seq; bits scored */
    QSEQ_JUNK,       /* unattributable framed garbage (outage bursts) */
    QSEQ_DUP,        /* seq at/behind the accounting point */
    QSEQ_NBUCKET
};

struct qpsk_seq_stats {
    int      pkt_bytes;
    uint64_t frames_scored;
    uint64_t ok, biterr, junk, dup;
    uint64_t lost;                              /* seqs proven never received */
    uint64_t lost_events;                       /* distinct gap events */
    /* ---- LAYER B: DMA-boundary failure-mode classification ----
     * batch_m is the RX DMA batch depth (-M). Set it to attribute losses to whole
     * dropped batches; 0 disables that test. The tear tests need no configuration. */
    int      batch_m;
    uint64_t torn_zero;      /* prefix good, tail all zero  -> slice never completed */
    uint64_t torn_stale;     /* prefix good, tail = another seq -> half-old/half-new */
    uint64_t scattered;      /* no aligned split -> decode-side, not DMA */
    uint64_t batch_drop;     /* LOST runs that are an exact multiple of batch_m */
    uint64_t tear_off_min, tear_off_max;  /* byte offset range of observed tears */
    uint64_t total_bits, total_bit_errors;      /* over OK+BITERR frames */
    uint64_t per_offset[QPSK_PKT_BYTES_MAX];    /* BITERR bit errors per byte */
    uint32_t first_seq, next_expect;
    int      have_first;
    int      rot_off;                           /* byte-DMA word rotation (0..15
                                                 * words) detected at anchor; the
                                                 * whole stream is de-rotated by
                                                 * this before scoring */
    uint64_t junk_run;                          /* current consecutive junk */
    /* event sink: type is "biterr"|"lost"|"dup"|"junkrun"; n = errs or count */
    void   (*evt)(void *ctx, const char *type, uint32_t seq, uint32_t n, double t);
    void    *evt_ctx;
    /* optional raw-frame dump: every BITERR/JUNK frame's raw bytes are written
     * as "RAW t=.. seq=.. class=.. hex=.." lines (error-STRUCTURE forensics:
     * word-aligned zero/stale tails = DMA slicing; scattered bits = decode) */
    FILE    *rawf;
};

/* deterministic per-seq payload: xorshift32 stream keyed on seq */
void qpsk_seq_payload(unsigned char *buf, int len, uint32_t seq);

/* the full expected WIRE frame for seq (incl. CRC, PN9 pad, whitener-if-on) */
void qpsk_seq_expected(unsigned char *frame, int pkt_bytes, uint32_t seq);
void qpsk_seq_tgen_frame(unsigned char *frame, int pkt_bytes, uint32_t seq, int fill);

/* batch_m is REQUIRED, not optional. It was previously set (or not) by the caller after
 * reset, and seq_run forgot -- leaving BATCH_DROP structurally unable to fire while the
 * unit test passed because it set the field by hand. Making it a parameter turns that
 * whole failure mode into a compile error. Pass 0 only if there is genuinely no batching. */
void qpsk_seq_reset(struct qpsk_seq_stats *s, int pkt_bytes, int batch_m);

/* score one raw received packet; t is a caller timestamp passed to events.
 * Returns the QSEQ_* bucket. */
int  qpsk_seq_score_frame(struct qpsk_seq_stats *s, const unsigned char *raw,
                          double t);

/* machine-readable summary: SEQRX line + per-offset map. elapsed_s and the
 * local tx count feed the air-rate cross-check. */
void qpsk_seq_report(const struct qpsk_seq_stats *s, FILE *f, double elapsed_s);

/* no-hardware self-test; 0 on success */
int  qpsk_seq_selftest(void);

#endif /* QPSK_SEQ_H */
