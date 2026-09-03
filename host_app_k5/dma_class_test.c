/* dma_class_test.c -- positive controls for the LAYER B DMA-boundary classifier.
 *
 * A classifier that has never been seen to fire is worth nothing: engine_gaps read zero
 * all night and turned out structurally incapable of firing. So each failure mode is
 * synthesised here and asserted to be counted as itself, and clean frames are asserted
 * NOT to trip anything.
 *
 * Modes (per the Layer B brief):
 *   gap           -> seq jump, already covered by qpsk_seq_selftest
 *   torn write    -> half-old/half-new slice   (TORN_ZERO / TORN_STALE)
 *   dropped batch -> missing run of exactly M  (BATCH_DROP)
 * plus SCATTERED, which must NOT be attributed to the DMA (it is a decode signature).
 */
#include <stdio.h>
#include <string.h>
#include "qpsk_seq.h"

static int fails;
#define CHK(c, msg) do { if (!(c)) { printf("  FAIL: %s\n", msg); fails = 1; } } while (0)

int main(void)
{
    const int PKT = 128;
    unsigned char f[QPSK_PKT_BYTES_MAX], other[QPSK_PKT_BYTES_MAX];
    struct qpsk_seq_stats s;
    uint32_t sq;

    /* qpsk_seq_reset() PRESERVES s->rawf across the reset, so an
     * uninitialised stack struct leaves a garbage FILE* that raw_dump
     * would write to. Zero it once up front. */
    memset(&s, 0, sizeof s);

    /* ---- clean frames must not trip any DMA classifier (negative control) ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    for (sq = 1; sq <= 20; sq++) {
        qpsk_seq_expected(f, PKT, sq);
        qpsk_seq_score_frame(&s, f, 0.0);
    }
    printf("clean   : ok=%llu torn_zero=%llu torn_stale=%llu scattered=%llu\n",
           (unsigned long long)s.ok, (unsigned long long)s.torn_zero,
           (unsigned long long)s.torn_stale, (unsigned long long)s.scattered);
    CHK(s.ok == 20, "clean frames not all OK");
    CHK(s.torn_zero == 0 && s.torn_stale == 0 && s.scattered == 0,
        "clean frames tripped a DMA classifier (false positive)");

    /* ---- TORN_ZERO: good prefix, tail never written (carve_zero pattern) ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    qpsk_seq_expected(f, PKT, 1); qpsk_seq_score_frame(&s, f, 0.0);
    qpsk_seq_expected(f, PKT, 2);
    memset(f + 64, 0, PKT - 64);                 /* zero from word 8 onward */
    qpsk_seq_score_frame(&s, f, 0.0);
    printf("tornzero: torn_zero=%llu torn_stale=%llu scattered=%llu tear_off=%u\n",
           (unsigned long long)s.torn_zero, (unsigned long long)s.torn_stale,
           (unsigned long long)s.scattered, (unsigned)s.tear_off_min);
    CHK(s.torn_zero == 1, "TORN_ZERO not detected");
    CHK(s.tear_off_min == 64, "tear offset wrong");

    /* ---- TORN_STALE: good prefix, tail is a DIFFERENT seq (last lap) ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    qpsk_seq_expected(f, PKT, 1); qpsk_seq_score_frame(&s, f, 0.0);
    qpsk_seq_expected(f, PKT, 2);
    qpsk_seq_expected(other, PKT, 99);
    memcpy(f + 64, other + 64, PKT - 64);        /* half-old / half-new */
    qpsk_seq_score_frame(&s, f, 0.0);
    printf("tornstal: torn_zero=%llu torn_stale=%llu scattered=%llu\n",
           (unsigned long long)s.torn_zero, (unsigned long long)s.torn_stale,
           (unsigned long long)s.scattered);
    CHK(s.torn_stale == 1, "TORN_STALE not detected");

    /* ---- SCATTERED: isolated bit flips must NOT be blamed on the DMA ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    qpsk_seq_expected(f, PKT, 1); qpsk_seq_score_frame(&s, f, 0.0);
    qpsk_seq_expected(f, PKT, 2);
    f[20] ^= 0x01; f[70] ^= 0x02; f[100] ^= 0x04;   /* spread, non-contiguous */
    qpsk_seq_score_frame(&s, f, 0.0);
    printf("scatter : torn_zero=%llu torn_stale=%llu scattered=%llu\n",
           (unsigned long long)s.torn_zero, (unsigned long long)s.torn_stale,
           (unsigned long long)s.scattered);
    CHK(s.scattered == 1, "SCATTERED not classified");
    CHK(s.torn_zero == 0 && s.torn_stale == 0,
        "scattered bit errors misattributed to the DMA");

    /* ---- BATCH_DROP: a lost run of exactly M ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    qpsk_seq_expected(f, PKT, 1);  qpsk_seq_score_frame(&s, f, 0.0);
    qpsk_seq_expected(f, PKT, 18); qpsk_seq_score_frame(&s, f, 0.0);   /* skip 2..17 = 16 */
    printf("batch   : lost=%llu lost_events=%llu batch_drop=%llu (M=16)\n",
           (unsigned long long)s.lost, (unsigned long long)s.lost_events,
           (unsigned long long)s.batch_drop);
    CHK(s.lost == 16, "lost count wrong");
    CHK(s.batch_drop == 1, "BATCH_DROP not detected for a run of exactly M");

    /* ---- a run that is NOT a multiple of M must not be called a batch drop ---- */
    memset(&s, 0, sizeof s); qpsk_seq_reset(&s, PKT, 16);
    qpsk_seq_expected(f, PKT, 1); qpsk_seq_score_frame(&s, f, 0.0);
    qpsk_seq_expected(f, PKT, 4); qpsk_seq_score_frame(&s, f, 0.0);    /* skip 2,3 */
    printf("nonbatch: lost=%llu batch_drop=%llu (expect batch_drop=0)\n",
           (unsigned long long)s.lost, (unsigned long long)s.batch_drop);
    CHK(s.batch_drop == 0, "non-multiple run wrongly called a batch drop");

    printf("\n%s\n", fails ? "DMA_CLASS_TEST: FAIL" : "DMA_CLASS_TEST: PASS");
    return fails;
}
