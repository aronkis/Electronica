/* qpsk_join.h -- COMB campaign (2026-09-03) instrumentation ABI.
 *
 * This header is the SINGLE SOURCE OF TRUTH for the three on-disk record
 * layouts the daemon writes and the offline tools read:
 *
 *   QPSK_FRAMELOG  frames.bin    48 B/record, no file header  (UNCHANGED
 *                                legacy layout; only the previously-zero
 *                                `reserved` word now carries fail_class)
 *   QPSK_FAILHDR   failhdr.bin   32 B file header + 32 B/record  (NEW)
 *   QPSK_TXLOG     txlog.bin     32 B file header + 32 B/record  (CHANGED:
 *                                was a bare 16 B "<QIHH" record stream)
 *
 * Everything here is header-only (`static inline` / struct definitions) so
 * that qpsk_tun.c, the host unit tests (which link only qpsk_frame.o) and any
 * future scorer all agree byte-for-byte by construction.
 *
 * DEPLOY NOTE: qpsk_tun.c #includes this header, so this file must be copied
 * to the board alongside qpsk_tun.c/qpsk_frame.[ch]/... See
 * two_jup/comb/README_hostlog.md ("Deploy") -- two_jup/capture_r3.sh's scp
 * list does not yet name it.
 */
#ifndef QPSK_JOIN_H
#define QPSK_JOIN_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>
#include "qpsk_frame.h"

/* ---------------------------------------------------------------- sentinels */
#define QPSK_FZO_NONE      0xFFFFFFFFu   /* first_zero_off: no zero tail found */
/* magic_off: no 0x51 0x4B in the slice. 0xFFFF would alias a real offset of
 * 65535, which cannot occur (a slice is at most QPSK_PKT_BYTES_MAX = 1528 B);
 * qpsk_first_magic_off() maps any offset >= 0xFFFF to NONE anyway. */
#define QPSK_MAGOFF_NONE   0xFFFFu
#define QPSK_GAP_NONE      0xFFFFFFFFu   /* txlog gap_ns: not measured (queue busy) */
/* txlog t_complete_ns == 0 means "no completion was ever stamped for this
 * submit" (still in flight at dump, or the ring record was already old when
 * the reap happened).  It does NOT mean "never transmitted". */

/* zero-tail detector tuning: the shortest suffix that may be called a tail,
 * and the zero fraction (9/10 = 90 %) required over that suffix. */
#define QPSK_ZTAIL_MIN     32u
#define QPSK_ZTAIL_NUM     9u
#define QPSK_ZTAIL_DEN     10u

/* ------------------------------------------------------------- fail classes */
enum qpsk_fail_class {
    QPSK_FC_OK        = 0,  /* slice parses: magic + len + CRC all good      */
    QPSK_FC_MAGIC     = 1,  /* p[0]!=0x51 || p[1]!=0x4B (or slice too short) */
    QPSK_FC_LEN       = 2,  /* magic ok, len > max payload for this slice    */
    QPSK_FC_CRC       = 3,  /* magic+len ok, CRC32 mismatch                  */
    QPSK_FC_ZEROTAIL  = 4   /* header garbage (would be 1 or 2) AND a >=90 %
                             * zero suffix -- the ByteBitShifter ALIGNLOSS
                             * signature (zeros shifted in to the end)       */
};

/* First offset of the 0x51 0x4B magic inside the slice, or QPSK_MAGOFF_NONE.
 * INFORMATIONAL ONLY -- this is NOT an ALIGNLOSS discriminator.  The modelled
 * ByteBitShifter failure shifts zeros in at the frame END; it does not displace
 * the header to a later offset, so a nonzero magic_off is not evidence of a
 * shift.  It also has a chance floor of ~2.3 %: a random 1528-byte slice
 * contains the two-byte sequence 0x51 0x4B with probability ~1527 * 2^-16.
 * Recorded because a LARGE excess over that floor would be a genuinely new
 * observation, and it is cheap (failure path only).  See
 * two_jup/comb/README_hostlog.md sections 2 and 3.3. */
static inline uint32_t qpsk_first_magic_off(const uint8_t *p, size_t n)
{
    if (n < 2) return QPSK_MAGOFF_NONE;
    for (size_t i = 0; i + 1 < n; i++)
        if (p[i] == 0x51 && p[i + 1] == 0x4B)
            return i > QPSK_MAGOFF_NONE ? QPSK_MAGOFF_NONE : (uint32_t)i;
    return QPSK_MAGOFF_NONE;
}

/* Classify one received slice.  PURE: no globals, no I/O.
 *
 * Mirrors qpsk_frame.c:139-173 (qpsk_frame_decode) check-for-check and IN THE
 * SAME ORDER -- magic, then len, then CRC -- so that class N means "decode
 * would have returned -1 at check N".  The caller must pass the DE-WHITENED
 * bytes (qpsk_frame_decode removes the whitener before parsing); the campaign
 * runs QPSK_WHITEN=0, in which case the wire bytes are already de-whitened.
 *
 * *first_zero_off receives the SMALLEST offset k such that p[k] == 0 and
 * p[k..n) is at least 90 % zero bytes and at least QPSK_ZTAIL_MIN long, or
 * QPSK_FZO_NONE.  Anchoring on an actual zero byte makes it the ONSET of the
 * zero region rather than the earliest offset the 90 % average tolerates
 * (without the anchor a 200-byte garbage prefix followed by 1328 zeros would
 * report 53, not 200).  It
 * is filled in regardless of the returned class (a class-3 CRC failure with a
 * zero tail is still informative), so an all-zero good-looking slice can be
 * told from a random one.
 *
 * Class 4 takes precedence over 1 and 2 (never over 3): "header garbage AND a
 * zero tail" is the ALIGNLOSS fingerprint, and a shift that destroys the
 * header always destroys the magic or the length field first.
 *
 * Reading class 4: first_zero_off > 0 is the TX-plane ALIGNLOSS shape (the
 * frame starts correctly and degenerates part-way).  first_zero_off == 0 is an
 * ALL-ZERO CARVE SLICE -- a delivery-plane hole, not a TX event: rx_pump_queued
 * zeroes the carve before each arm (qpsk_tun.c:1461/1466 queued; :1203 legacy rx_arm; NOT under QPSK_RX_CYCLIC -- rx_arm_cyclic/rx_pump_cyclic :1256/:1314 never zero the carve, so class 4 with first_zero_off==0 cannot occur there), so a
 * slot the DMA never filled reads back as all zeros.  Under QPSK_RXQ_ZEROHDR
 * only the leading 8 bytes are zeroed, and such a slot lands in class 1
 * instead.  Split the class-4 census on first_zero_off == 0 before attributing
 * anything to the TX plane. */
static inline int qpsk_fail_class(const uint8_t *p, size_t n,
                                  uint32_t *first_zero_off)
{
    uint32_t fzo = QPSK_FZO_NONE;
    size_t zeros = 0, k;
    int cls;

    if (n >= QPSK_ZTAIL_MIN) {
        for (k = n; k-- > 0; ) {
            size_t len;
            if (p[k] == 0) zeros++;
            len = n - k;
            if (p[k] == 0 && len >= QPSK_ZTAIL_MIN &&
                zeros * QPSK_ZTAIL_DEN >= len * QPSK_ZTAIL_NUM)
                fzo = (uint32_t)k;   /* descending k -> ends at the smallest */
        }
    }
    if (first_zero_off)
        *first_zero_off = fzo;

    if (n < (size_t)QPSK_FRAME_HDR_BYTES || p[0] != 0x51 || p[1] != 0x4B) {
        cls = QPSK_FC_MAGIC;
    } else {
        int len = (int)p[2] | ((int)p[3] << 8);
        if (len < 0 || (size_t)len > n - (size_t)QPSK_FRAME_HDR_BYTES) {
            cls = QPSK_FC_LEN;
        } else {
            uint32_t crc_rx = (uint32_t)p[8] | ((uint32_t)p[9] << 8) |
                              ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 24);
            unsigned char tmp[QPSK_PKT_BYTES_MAX];
            size_t used = (size_t)QPSK_FRAME_HDR_BYTES + (size_t)len;
            if (used > sizeof tmp)
                return QPSK_FC_LEN;          /* cannot happen: len<=n<=MAX */
            memcpy(tmp, p, used);
            memset(tmp + 8, 0, 4);
            cls = (qpsk_crc32(tmp, used) == crc_rx) ? QPSK_FC_OK : QPSK_FC_CRC;
        }
    }
    if ((cls == QPSK_FC_MAGIC || cls == QPSK_FC_LEN) && fzo != QPSK_FZO_NONE)
        cls = QPSK_FC_ZEROTAIL;
    return cls;
}

/* -------------------------------------------------- QPSK_FRAMELOG record ---
 * 48 B, little-endian, written back-to-back with NO file header (unchanged
 * from the pre-campaign layout that every existing parser assumes).  The only
 * change: `reserved` -- previously always 0 -- now carries the fail class.
 * Python: struct "<QQIIIIIIII" (10 fields, 48 B). */
struct frame_rec {
    uint64_t t_mono_ns;       /* CLOCK_MONOTONIC at the decode                */
    uint64_t t_real_ns;       /* CLOCK_REALTIME (maps to capture wallclock)   */
    uint32_t host_seq;        /* decoded seq (pass) or raw header seq (fail)  */
    uint32_t crc_ok;          /* 1 = good frame, 0 = errored/dropped          */
    uint32_t reg_packets;     /* 0x104 packets_out (cumulative)               */
    uint32_t reg_biterr;      /* 0x108 bit_errors_out (cumulative BIST)       */
    uint32_t reg_rstcs;       /* 0x150 rstcs_count (cumulative carrier reset) */
    uint32_t reg_cfc;         /* 0x154 cfc_est (CFO trajectory snapshot)      */
    uint32_t reg_adcforensic; /* 0x15C adc_forensic (level/duty/gap snapshot) */
    uint32_t fail_class;      /* enum qpsk_fail_class (was `reserved`, == 0)  */
};
_Static_assert(sizeof(struct frame_rec) == 48, "frame_rec must be 48 bytes");

/* --------------------------------------------------- QPSK_FAILHDR record ---
 * 32 B, little-endian.  One record per FAILED frame, appended to a ring of
 * QPSK_FAILHDR_N entries; the ring is dumped (header + records, oldest first)
 * on SIGUSR1 and at exit.  Python: struct "<QIIBBH12s".
 * host_seq is the RAW header seq word -- garbage for a magic-bad frame; index
 * failures by record position, never by host_seq. */
struct failhdr_rec {
    uint64_t t_mono_ns;       /* CLOCK_MONOTONIC, same clock as frame_rec     */
    uint32_t host_seq;        /* raw p[4..7] as logged in the framelog        */
    uint32_t first_zero_off;  /* zero-tail onset, or QPSK_FZO_NONE            */
    uint8_t  fail_class;      /* enum qpsk_fail_class (1..4)                  */
    uint8_t  pad;             /* 0                                            */
    uint16_t magic_off;       /* first 0x51 0x4B offset, or QPSK_MAGOFF_NONE  */
    uint8_t  hdr[12];         /* the 12 raw header bytes of the slice         */
};
_Static_assert(sizeof(struct failhdr_rec) == 32, "failhdr_rec must be 32 bytes");

/* ------------------------------------------------------ QPSK_TXLOG record ---
 * 32 B, little-endian.  One record per TRANSMITTED frame at the submit path
 * (tx_send: one; tx_send_batch: n).  Python: struct "<QQIIIHH".
 *
 * gap_ns is the value txgap_note() computed for THIS transfer: an ESTIMATED
 * LOWER BOUND on the fabric-visible silence before the submit, and only when
 * the queue was empty after the reap (inflight_after_reap == 0).  When the
 * queue was still busy no silence is measurable and gap_ns == QPSK_GAP_NONE.
 * "not measured" and "measured 0 ns" are therefore distinct values. */
struct txlog_rec {
    uint64_t t_submit_ns;     /* CLOCK_MONOTONIC just after DMAC_SUBMIT       */
    uint64_t t_complete_ns;   /* CLOCK_MONOTONIC at tx_reap; 0 = never reaped */
    uint32_t seq;             /* header seq word of the submitted frame       */
    uint32_t gap_ns;          /* txgap_note's gap, or QPSK_GAP_NONE           */
    uint32_t slot;            /* tx_slot counter (monotonic, not modulo)      */
    uint16_t inflight;        /* queue depth BEFORE this submit (0,1,..)      */
    uint16_t spins;           /* polled-mode 100 us spins waiting for a slot  */
};
_Static_assert(sizeof(struct txlog_rec) == 32, "txlog_rec must be 32 bytes");

/* --------------------------------------------------------- file headers ---
 * Both NEW files start with this 32 B header so a reader can tell the layout
 * apart from the old bare-record dumps (the pre-campaign txlog was a headerless
 * stream of 16 B "<QIHH" records; two_jup/txlog_gaps.py and
 * two_jup/loss_ledger.py:tx_gaps_146 still assume that and must be updated).
 * Python: struct "<8sIIQII". */
#define QPSK_TXLOG_MAGIC   "QTXLOG02"
#define QPSK_FAILHDR_MAGIC "QFAILH01"
struct qpsk_log_hdr {
    char     magic[8];        /* QPSK_TXLOG_MAGIC / QPSK_FAILHDR_MAGIC        */
    uint32_t rec_bytes;       /* 32                                           */
    uint32_t n_records;       /* records that follow this header              */
    uint64_t t_dump_ns;       /* CLOCK_MONOTONIC at the dump                  */
    uint32_t total;           /* total events seen (> n_records => wrapped)   */
    uint32_t flags;           /* bit0 = ring wrapped (oldest events lost)     */
};
_Static_assert(sizeof(struct qpsk_log_hdr) == 32, "qpsk_log_hdr must be 32 bytes");
#define QPSK_LOGF_WRAPPED 0x1u

/* ---------------------------------------------------------- TX<->RX join ---
 * Reference semantics for the per-frame join the campaign scores.  The real
 * join runs in Python (two_jup/comb/); this C helper is the executable spec
 * the Python must agree with, and is what test_txlog.c exercises.
 *
 *   NEVER_SENT             the TX board has no submit record for that seq
 *   SENT_NOT_DECODED       submitted, but the RX framelog has no crc_ok==1
 *                          record for it (it may have a failed record, or
 *                          none at all)
 *   DECODED_NOT_DELIVERED  the RX framelog decoded it (crc_ok==1) but the
 *                          payload never reached the consumer (tun / qpsk_perf
 *                          sequence set)
 *   OK                     submitted, decoded and delivered
 *
 * `delivered` may be NULL (n_delivered 0) when no delivery evidence exists,
 * in which case a decoded frame is reported OK -- state that in any writeup
 * rather than silently calling the class absent. */
enum qpsk_join_class {
    QPSK_JOIN_OK                    = 0,
    QPSK_JOIN_NEVER_SENT            = 1,
    QPSK_JOIN_SENT_NOT_DECODED      = 2,
    QPSK_JOIN_DECODED_NOT_DELIVERED = 3
};

static inline int qpsk_join_classify(uint32_t seq,
                                     const struct txlog_rec *tx, size_t ntx,
                                     const struct frame_rec *rx, size_t nrx,
                                     const uint32_t *delivered, size_t n_delivered)
{
    size_t i;
    int sent = 0, decoded = 0, deliv = 0;

    for (i = 0; i < ntx; i++)
        if (tx[i].seq == seq) { sent = 1; break; }
    if (!sent)
        return QPSK_JOIN_NEVER_SENT;

    for (i = 0; i < nrx; i++)
        if (rx[i].crc_ok == 1u && rx[i].host_seq == seq) { decoded = 1; break; }
    if (!decoded)
        return QPSK_JOIN_SENT_NOT_DECODED;

    if (!delivered || n_delivered == 0)
        return QPSK_JOIN_OK;
    for (i = 0; i < n_delivered; i++)
        if (delivered[i] == seq) { deliv = 1; break; }
    return deliv ? QPSK_JOIN_OK : QPSK_JOIN_DECODED_NOT_DELIVERED;
}

#endif /* QPSK_JOIN_H */
