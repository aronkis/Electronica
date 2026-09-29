/* qpsk_fec -- systematic erasure FEC for the QPSK byte link.
 *
 * WHY ERASURE CODING AND NOT ERROR CORRECTION
 * -------------------------------------------
 * Every frame on this link already carries a CRC32 (qpsk_frame.c) and the RX
 * path drops the frame outright when it fails.  So the receiver never sees
 * corrupt data -- it sees a *hole*, and it knows exactly where the hole is.
 * That is an ERASURE channel, and erasure codes are twice as efficient as
 * error-correcting codes on it: R parity frames recover ANY R lost frames,
 * versus R/2 for a code that must also locate the errors.
 *
 * WHAT IT IS FOR
 * --------------
 * The residual per-frame loss between wedges (measured ~2-3% of frames) is
 * what makes the video glitch when the scene moves: a lost 1316 B UDP
 * datagram is 7 MPEG-TS packets, and an I-frame slice hit that way smears
 * until the next keyframe.  One parity frame per group of K turns an
 * isolated loss into no loss at all.
 *
 * It is NOT a fix for the PAYLOAD-WEDGE (100% CRC failure for ~15 s): during
 * a wedge every frame in every group is lost and no code with finite rate
 * recovers that.  FEC and the wedge watchdog are complementary.
 *
 * WIRE FORMAT -- NO CHANGE TO qpsk_frame
 * --------------------------------------
 * A parity frame is an ORDINARY qpsk_frame whose *payload* is an FEC
 * container.  Nothing in the 12-byte frame header changes, so parity frames
 * ride the existing CRC, whitener, re-anchor scan and DMA carve untouched.
 *
 *   off   size  field
 *   0     2     0xFE 0xC1   container magic
 *   2     1     version (QPSK_FEC_VER)
 *   3     1     type    (QPSK_FEC_T_PARITY)
 *   4     1     K       data frames in this group (1..QPSK_FEC_KMAX)
 *   5     1     R       parity frames in this group (1..QPSK_FEC_RMAX)
 *   6     1     j       this frame's parity row index (0..R-1)
 *   7     1     reserved (0)
 *   8     4     base_seq   uint32 LE -- frame seq of data frame #0
 *   12    2     L          uint16 LE -- protected length (max payload in group)
 *   14    2*K   delta[i]   uint16 LE -- seq_i - base_seq
 *   14+2K 2*K   len[i]     uint16 LE -- payload length of data frame i
 *   14+4K L     parity bytes for row j
 *
 * The magic cannot collide with real traffic: tun0 is IFF_TUN|IFF_NO_PI, so
 * byte 0 of every payload is an IP header whose high nibble is 4 or 6.  0xFE
 * has high nibble 0xF, which is not a legal IP version.  The parser also
 * checks that 14 + 4*K + L equals the frame's payload length exactly.
 *
 * ORDERING -- WHY THE DECODER HOLDS FRAMES BACK
 * ---------------------------------------------
 * A recovered frame necessarily arrives AFTER the frames that follow it.
 * Handing that to the MPEG-TS demuxer out of order is worse than the hole it
 * fills: the continuity counters jump twice and 1316 B of stale transport
 * stream is spliced mid-picture.  That is the same failure the NAK/ARQ
 * experiment produced (ops notes: "out-of-order fills break mpegts"), and it
 * is why -A is not used.  So the decoder is a small reorder buffer: frames
 * are held for hold_s (or until hi_water slots are occupied), released in
 * strict seq order, and a recovery that arrives after its slot has already
 * been released is DISCARDED and counted, never delivered late.
 *
 * Latency cost is one group plus the hold: at the measured ~560 payload
 * frames/s with K=8 that is ~14 ms of group span and a 40 ms default hold.
 *
 * SEQUENCE NUMBERS
 * ----------------
 * seq is qpsk_tun's tx_seq, which counts idle/keepalive frames too, so the K
 * data seqs of a group are NOT contiguous.  That is why the container carries
 * an explicit delta[] table: the decoder learns a group's exact membership
 * from the parity frame and never has to guess whether a missing seq was an
 * idle frame or a lost data frame.  All seq comparisons use wrap-safe signed
 * differences.
 *
 * PURITY: no I/O, no globals, no clock of its own (the caller passes `now`).
 * Every function here is unit-testable on an x86 dev box -- see
 * tests/test_fec.c.
 */
#ifndef QPSK_FEC_H
#define QPSK_FEC_H

#include <stdint.h>
#include <stddef.h>

#define QPSK_FEC_MAGIC0   0xFEu
#define QPSK_FEC_MAGIC1   0xC1u
#define QPSK_FEC_VER      1u
#define QPSK_FEC_T_PARITY 1u

#define QPSK_FEC_KMAX     32     /* data frames per group   */
#define QPSK_FEC_RMAX     4      /* parity frames per group */

/* Upper bound on a protected payload, used only to size the decoder's small
 * solving scratch on the stack.  Kept self-contained (no qpsk_frame.h
 * dependency) so this module stays pure; it must be >= the largest
 * QPSK_FRAME_MAX_PAYLOAD the daemon can be built for (F1536: 1528-12=1516). */
#define QPSK_PKT_MAXP_GUARD 1516

/* container header bytes for a given K */
#define QPSK_FEC_HDR(K)   (14 + 4 * (K))

/* ---- GF(256) / matrix ---------------------------------------------------
 * Cauchy generator, column-normalised so row 0 is all ones (row 0 parity is
 * therefore a plain XOR, the common R=1 case, with no multiplies at all).
 * Every square submatrix of a Cauchy matrix is invertible, and scaling whole
 * columns by nonzero constants preserves that, so ANY e<=R erasures are
 * solvable with ANY e surviving parity rows. */
void qpsk_fec_init(void);                    /* idempotent; tables */
unsigned char qpsk_fec_gen(int j, int i);    /* g'[j][i], after init */

/* ---- encoder ------------------------------------------------------------ */
typedef struct qpsk_fec_enc qpsk_fec_enc;

/* K data frames per group, R parity frames, payload cap `max_payload`
 * (== QPSK_FRAME_MAX_PAYLOAD(pkt_bytes)).  Fails (NULL) when the container
 * header plus one full payload cannot fit a frame. */
qpsk_fec_enc *qpsk_fec_enc_new(int K, int R, int max_payload);
void          qpsk_fec_enc_free(qpsk_fec_enc *e);

/* Record a data frame that was just handed to the modem.  Returns 1 when the
 * group is now full and the caller should drain parity, 0 otherwise, -1 if
 * the payload is too long to protect (the group is abandoned and reset). */
int  qpsk_fec_enc_add(qpsk_fec_enc *e, uint32_t seq,
                      const unsigned char *payload, int len);

int  qpsk_fec_enc_pending(const qpsk_fec_enc *e);   /* data frames in the open group */

/* Longest payload this encoder can protect (max_payload - container header).
 * A payload above it must be sent unprotected -- see qpsk_fec_enc_add. */
int  qpsk_fec_enc_maxprot(const qpsk_fec_enc *e);

/* Build parity row j (0..R-1) of the open group into out[0..outcap).
 * Returns the container length, or -1.  Valid once >=1 frame is pending; a
 * short group (flush) is encoded with its actual K. */
int  qpsk_fec_enc_parity(qpsk_fec_enc *e, int j,
                         unsigned char *out, int outcap);

void qpsk_fec_enc_reset(qpsk_fec_enc *e);           /* start a new group */

/* ---- container sniffing (both ends) ------------------------------------- */
/* 1 when buf[0..len) is a well-formed parity container. Cheap: magic first. */
int  qpsk_fec_is_parity(const unsigned char *buf, int len);

/* ---- decoder ------------------------------------------------------------ */
typedef struct qpsk_fec_dec qpsk_fec_dec;

struct qpsk_fec_stats {
    uint64_t data_in;      /* data frames accepted into the buffer        */
    uint64_t parity_in;    /* parity containers accepted                  */
    uint64_t parity_bad;   /* containers rejected (malformed/oversize)    */
    uint64_t recovered;    /* frames rebuilt from parity AND delivered    */
    uint64_t too_late;     /* rebuilt, but its slot had already released  */
    uint64_t unrecoverable;/* groups with more losses than parity rows    */
    uint64_t released;     /* payloads handed back by _pop                */
    uint64_t dups;         /* duplicate seq dropped                       */
    uint64_t overflow;     /* slot evicted early because the ring was full*/
};

/* slots = reorder ring depth (>= 2*(K+R) recommended), hold_s = how long the
 * oldest held frame waits for its parity before being released with the hole
 * still in it. */
/* NOTE the asymmetry with qpsk_fec_enc_new: there, max_payload is the FRAME
 * payload cap and the container header is subtracted internally; here it is
 * simply the per-slot buffer size, which need only be >= any protected length
 * L that can appear on the wire.  Passing the frame cap to both is correct and
 * is what the daemon does -- it also lets a peer using a different K decode. */
qpsk_fec_dec *qpsk_fec_dec_new(int slots, int max_payload, double hold_s);
void          qpsk_fec_dec_free(qpsk_fec_dec *d);
void          qpsk_fec_dec_hold(qpsk_fec_dec *d, double hold_s);

/* Feed one CRC-valid received frame.  Detects parity vs data itself.
 * Returns 1 if it was a parity container (caller must NOT write it to tun),
 * 0 if it was ordinary data. */
int qpsk_fec_dec_rx(qpsk_fec_dec *d, uint32_t seq,
                    const unsigned char *payload, int len, double now);

/* Pop the next in-order payload that is due for release.  Returns its length
 * (>0), or 0 when nothing is due yet.  Call in a loop until it returns 0. */
int qpsk_fec_dec_pop(qpsk_fec_dec *d, unsigned char *out, int outcap,
                     uint32_t *seq, double now);

/* Release everything still held, ignoring the hold timer (shutdown/re-arm). */
void qpsk_fec_dec_flush(qpsk_fec_dec *d);

const struct qpsk_fec_stats *qpsk_fec_dec_stats(const qpsk_fec_dec *d);

#endif
