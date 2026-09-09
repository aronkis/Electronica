/* test_qsim.c -- discrete-event simulation of the RX DMA transfer-boundary loss,
 * legacy (reset-per-transfer) vs queued-request policies.
 *
 * Models the mechanism established on hardware: the S2MM engine captures K-frame
 * transfers gated by a per-transfer frame-sync marker. Between transfer N's EOT and
 * the engine being armed for N+1 there is a window; the next frame's sync falls
 * `gap` after EOT (the inter-frame air gap). If the arm latency exceeds the gap,
 * that frame is never captured (the engine waits a further sync) -> the measured
 * ~0.6 lost frames/transfer, lag-K periodic.
 *
 *   legacy: arm latency = host observe+reset+reprogram latency (jittered; the
 *           rx_want_spin path makes it small but not always under the gap)
 *   queued: the next transfer is ALREADY accepted by the transfer core at EOT;
 *           arm latency = hardware handoff (~cycles), always under the gap
 *
 * Emits one line per frame: "<frame_idx> <delivered 0|1>" for each policy, to be
 * analyzed by the same lag-K autocorrelation used on hardware captures. A small
 * unrelated random loss (0.1%) is injected into BOTH policies so the queued case
 * has a miss train at all -- the claim under test is that the lag-K PEAK collapses,
 * not that all loss vanishes.
 *
 * No hardware, no qpsk_tun.c -- policy timing model only. Deterministic (fixed LCG
 * seed). Usage: test_qsim <legacy_out> <queued_out>
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#define NFRAMES   200000
#define K         32          /* frames per transfer (-M 32) */
#define GAP       0.020       /* inter-frame air gap, fraction of a frame slot */
#define L_LEGACY  0.050       /* legacy max arm latency (uniform 0..L): P(loss) =
                               * 1 - GAP/L = 0.6 -> matches measured 0.59/transfer */
#define L_QUEUED  0.0001      /* hardware request handoff */
#define P_RANDOM  0.001       /* unrelated background loss, both policies */

static uint64_t lcg = 0x2545F4914F6CDD1Dull;
static double frand(void) {           /* deterministic uniform [0,1) */
    lcg = lcg * 6364136223846793005ull + 1442695040888963407ull;
    return (double)(lcg >> 11) / 9007199254740992.0;
}

static void simulate(const char *path, double arm_latency_max)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    int in_transfer = 0;      /* frames captured in the current transfer */
    int lose_next = 0;        /* boundary: engine not armed in time for this frame */
    for (int i = 0; i < NFRAMES; i++) {
        int delivered = 1;
        if (lose_next) { delivered = 0; lose_next = 0; }
        if (frand() < P_RANDOM) delivered = 0;            /* background loss */
        if (delivered) {
            if (++in_transfer == K) {                     /* EOT at this frame */
                in_transfer = 0;
                double lat = frand() * arm_latency_max;   /* arm-for-next latency */
                if (lat > GAP) lose_next = 1;             /* missed the next sync */
            }
        }
        fprintf(f, "%d %d\n", i, delivered);
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: test_qsim <legacy_out> <queued_out>\n"); return 2; }
    simulate(argv[1], L_LEGACY);
    simulate(argv[2], L_QUEUED);
    printf("QSIM_DONE frames=%d K=%d\n", NFRAMES, K);
    return 0;
}
