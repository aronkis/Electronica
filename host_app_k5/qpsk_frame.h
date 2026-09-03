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
#define QPSK_PKT_BYTES_MAX     1024
#define QPSK_FRAME_HDR_BYTES   12
#define QPSK_FRAME_MAX_PAYLOAD(pkt_bytes) ((pkt_bytes) - QPSK_FRAME_HDR_BYTES)

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
