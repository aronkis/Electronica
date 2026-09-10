/* qpsk_frame -- framing for one network frame per QPSK packet payload.
 *
 * Layout (little-endian multi-byte fields):
 *   [0..1]  magic 0x51 0x4B ("QK")
 *   [2..3]  payload length in bytes (0..pkt_bytes-12; 0 = idle/keepalive
 *           frame: header-only, valid CRC, no payload delivered)
 *   [4..7]  sequence number
 *   [8..11] CRC32 (zlib polynomial) over the whole used frame with the
 *           CRC field zeroed -- detects the modem's episodic packet
 *           corruption so bad frames are dropped, not delivered
 *   [12..]  payload, zero-padded to pkt_bytes
 *
 * pkt_bytes is the QPSK packet payload size: DataBitsPerPacket/8 of the
 * deployed bitstream (280 for the default 2240-bit build, 560 for 4480,
 * 128 for the two-radio K5 build -- 12 B header + <=116 B payload).
 *
 * K5 host change vs the legacy contract: len==0 is now a VALID frame (the
 * -F keepalive idle frame). Legacy daemons reject len==0 at decode, so idle
 * frames must only be sent between two K5-mode endpoints.
 */
#ifndef QPSK_FRAME_H
#define QPSK_FRAME_H

#include <stdint.h>
#include <stddef.h>

#define QPSK_PKT_BYTES_DEFAULT 280
/* F1536: 1528 B host frame (12 B header + 1516 B MTU payload) -- see
 * contract/PACKET_F1536.txt and modem/frame_config_k5.m's 'f1536'
 * case. QPSK_PKT_BYTES_MAX must cover the largest deployed frame; F1536 (1528)
 * is currently the largest, so it sets the ceiling. */
#define QPSK_PKT_BYTES_MAX     1528
#define QPSK_FRAME_HDR_BYTES   12
#define QPSK_FRAME_MAX_PAYLOAD(pkt_bytes) ((pkt_bytes) - QPSK_FRAME_HDR_BYTES)

/* F1536 large-frame geometry (runtime MODE selected in qpsk_tun.c via -G or
 * QPSK_FRAME=f1536; k5 stays the default -- see qpsk_tun.c's K5_* constants
 * for the two-radio 240k/K5 geometry these sit alongside):
 *   PKT_BYTES     = host-delivered logical frame (WPP=191*64/8 = 1528 B,
 *                   12 B header + 1516 B payload, MTU 1516).
 *   TX_XFER_BYTES = the full air-frame TX transfer (385*8 = 3080 B; the
 *                   fabric's per-transfer wordFirst/TLAST must land on the
 *                   air-frame boundary, same padding contract as K5's
 *                   128 B logical / 280 B air-frame pair). */
#define F1536_PKT_BYTES      1528
#define F1536_TX_XFER_BYTES  3080

/* fills pkt[pkt_bytes]; returns pkt_bytes or -1 on bad length.
 * len==0 encodes an idle/keepalive frame (payload may be NULL). */
int qpsk_frame_encode(unsigned char *pkt, int pkt_bytes,
                      const unsigned char *payload, int len, uint32_t seq);

/* validates magic/length/CRC; copies payload to out (must hold
 * QPSK_FRAME_MAX_PAYLOAD(pkt_bytes)); returns payload length (0 for a
 * valid idle frame -- nothing is written to out) or -1 */
int qpsk_frame_decode(const unsigned char *pkt, int pkt_bytes,
                      unsigned char *out, uint32_t *seq);

uint32_t qpsk_crc32(const unsigned char *buf, size_t len);

/* ---- RX carve re-anchor (RXFIX Task 26) -----------------------------------
 * The host RX path carves the DMA area into frames at a FIXED pkt_bytes stride
 * and re-anchors only when the next DMA transfer starts on a frame-sync tuser.
 * So a byte-count anomaly in the fabric's byte stream whose size is not a
 * multiple of pkt_bytes displaces EVERY following frame in that transfer by a
 * constant phase, and every one of them fails to parse even though its bytes
 * are intact.  Measured on the forward leg: phase 568 on 1,259 of 1,305
 * magic-carrying class-1 failures (FWD_RESIDUAL_0p22.md, tag
 * archive/pre-cleanup-2026-09-09; "The
 * five questions" headline table), i.e. 1528 - 568 = 960 B deleted from (or
 * 568 B inserted into) the stream.
 *
 * QPSK_RESYNC_STEP -- re-anchor offsets are scanned on 8-byte steps.  Two
 * independent reasons, both binding:
 *   1. the RX byte plane delivers whole 64-bit words (F1536: WPP = 191 words
 *      = 1528 B), and every displacement the campaign has measured is a whole
 *      number of words: 568 = 71 w, 376 = 47 w, 1136 = 142 w;
 *   2. qpsk_tun's carve_copy_from() reads the /dev/mem O_SYNC DMA carve with
 *      volatile 64-bit loads.  An unaligned 64-bit access to Device memory
 *      FAULTS on ARM64, so a byte-granular re-anchor would SIGBUS on the board
 *      while passing every x86 unit test.
 *
 * QPSK_RESYNC_OFF_568 is the measured forward-leg phase; it exists only so the
 * daemon can split its re-anchor counter into "the known defect" and "anything
 * else" (resync_568 / resync_other).  Nothing in the scan is specialised to it.
 */
#define QPSK_RESYNC_STEP     8
#define QPSK_RESYNC_OFF_568  568

/* Bounded re-anchor scan.  Scans d = STEP, 2*STEP, ... up to max_shift for the
 * FIRST offset at which a COMPLETE frame validates (magic, then len, then
 * CRC32 -- qpsk_frame_decode itself, so whitening is handled and the accept
 * rule is identical to the normal path).  A candidate is only considered when
 * the whole frame fits: d + pkt_bytes <= n.
 *
 * Returns d (> 0) on success, having decoded that frame into out/seq and
 * stored its payload length (0 = idle frame) in *len; -1 when nothing
 * validates.  d == 0 is never returned: the caller has already tried offset 0.
 *
 * Callers must pass max_shift < pkt_bytes.  That is not a tuning knob, it is
 * the correctness rule: allowing d == pkt_bytes would let the scan "re-anchor"
 * onto the NEXT, perfectly aligned frame, which is not a re-anchor at all --
 * it is the ordinary advance the drain loop already does, and counting it
 * would corrupt the re-anchor statistic.  With max_shift < pkt_bytes a
 * successful scan can only mean a genuine sub-frame displacement.
 *
 * PURE: no globals, no I/O.  `out` must hold QPSK_FRAME_MAX_PAYLOAD(pkt_bytes).
 */
int qpsk_frame_resync(const unsigned char *buf, size_t n, int pkt_bytes,
                      int max_shift, unsigned char *out, uint32_t *seq,
                      int *len);

/* Frame-synchronous additive whitener: XORs a fixed PN9 sequence (reset at
 * byte 0 of every frame) onto buf[0..n). Whitens low-entropy payloads so they
 * radiate high-transition-density symbols instead of stressing the receiver's
 * carrier/timing loops (a constant/near-constant symbol run). Self-inverse:
 * call again with the same n to remove it. Both endpoints must whiten
 * identically (same build). */
void qpsk_whiten(unsigned char *buf, int n);

/* process-wide whitener switch (env QPSK_WHITEN, read once); exported so
 * raw-buffer scorers (qpsk_seq) mirror the wire format exactly */
int qpsk_whiten_on(void);

#endif
