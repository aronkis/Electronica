#include "qpsk_frame.h"
#include <string.h>
#include <stdlib.h>

uint32_t qpsk_crc32(const unsigned char *buf, size_t len)
{
    static uint32_t table[256];
    static int have_table = 0;
    uint32_t crc;
    size_t i;
    int j;

    if (!have_table) {
        for (i = 0; i < 256; i++) {
            crc = (uint32_t)i;
            for (j = 0; j < 8; j++)
                crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320u : 0);
            table[i] = crc;
        }
        have_table = 1;
    }
    crc = 0xFFFFFFFFu;
    for (i = 0; i < len; i++)
        crc = (crc >> 8) ^ table[(crc ^ buf[i]) & 0xFF];
    return crc ^ 0xFFFFFFFFu;
}

/* PN9 (x^9 + x^5 + 1) byte generator. Fills the non-CRC'd frame padding with
 * high-entropy bytes so an idle/keepalive frame (all-padding) still radiates a
 * modulated carrier the peer's AGC/carrier-sync can ACQUIRE and hold lock on --
 * an all-zero idle frame produces a near-DC signal the peer never locks to. The
 * RX ignores the padding (CRC covers only header+payload), so any deterministic
 * PN works; seeded by seq for inter-frame variation. */
static void qpsk_pn_fill(unsigned char *buf, int n, uint32_t seed)
{
    uint16_t s = (uint16_t)(seed & 0x1FF);
    if (s == 0) s = 0x1FF;                 /* 9-bit LFSR must be nonzero */
    for (int i = 0; i < n; i++) {
        unsigned char b = 0;
        for (int k = 0; k < 8; k++) {
            uint16_t nb = ((s >> 8) ^ (s >> 4)) & 1u;   /* x^9 + x^5 + 1 */
            s = (uint16_t)(((s << 1) | nb) & 0x1FF);
            b = (unsigned char)((b << 1) | nb);
        }
        buf[i] = b;
    }
}

/* Frame-synchronous additive whitener (see qpsk_frame.h). A fixed PN9 sequence
 * (seed = all-ones, reset at byte 0 of every frame) XORed onto the buffer. Self-
 * inverse. Reuses the PN9 generator so no new LFSR state is introduced. */
#define QPSK_WHITEN_SEED 0x1FFu
void qpsk_whiten(unsigned char *buf, int n)
{
    unsigned char pn[QPSK_PKT_BYTES_MAX];
    if (n < 0) return;
    if (n > QPSK_PKT_BYTES_MAX) n = QPSK_PKT_BYTES_MAX;
    qpsk_pn_fill(pn, n, QPSK_WHITEN_SEED);
    for (int i = 0; i < n; i++)
        buf[i] ^= pn[i];
}

/* Whitening is enabled process-wide by env QPSK_WHITEN (nonzero), read once so
 * every frame in a run agrees. Default OFF -> the wire format is byte-identical
 * to the pre-whitener contract, so a whitened build interoperates only with
 * another whitened build (set QPSK_WHITEN on BOTH ends). encode() whitens the
 * finished frame; decode() removes it before parsing, keeping whitening
 * transparent to every caller (tun / echo / keepalive). */
int qpsk_whiten_on(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("QPSK_WHITEN");
        on = (e && *e && e[0] != '0') ? 1 : 0;
    }
    return on;
}

int qpsk_frame_encode(unsigned char *pkt, int pkt_bytes,
                      const unsigned char *payload, int len, uint32_t seq)
{
    uint32_t crc;

    if (pkt_bytes < QPSK_FRAME_HDR_BYTES + 1 || pkt_bytes > QPSK_PKT_BYTES_MAX)
        return -1;
    if (len < 0 || len > QPSK_FRAME_MAX_PAYLOAD(pkt_bytes))
        return -1;   /* len==0 = idle/keepalive frame (K5 -F path) */
    pkt[0] = 0x51; pkt[1] = 0x4B;
    pkt[2] = (unsigned char)(len & 0xFF);
    pkt[3] = (unsigned char)((len >> 8) & 0xFF);
    pkt[4] = (unsigned char)(seq & 0xFF);
    pkt[5] = (unsigned char)((seq >> 8) & 0xFF);
    pkt[6] = (unsigned char)((seq >> 16) & 0xFF);
    pkt[7] = (unsigned char)((seq >> 24) & 0xFF);
    memset(pkt + 8, 0, 4);
    if (len > 0)
        memcpy(pkt + QPSK_FRAME_HDR_BYTES, payload, (size_t)len);
    /* PN-fill the padding (NOT covered by the CRC) so idle/keepalive frames
     * carry enough entropy for the peer to lock; RX ignores these bytes. */
    qpsk_pn_fill(pkt + QPSK_FRAME_HDR_BYTES + len,
                 pkt_bytes - QPSK_FRAME_HDR_BYTES - len, seq);
    crc = qpsk_crc32(pkt, (size_t)(QPSK_FRAME_HDR_BYTES + len));
    pkt[8]  = (unsigned char)(crc & 0xFF);
    pkt[9]  = (unsigned char)((crc >> 8) & 0xFF);
    pkt[10] = (unsigned char)((crc >> 16) & 0xFF);
    pkt[11] = (unsigned char)((crc >> 24) & 0xFF);
    /* whiten the finished frame (CRC computed over the un-whitened data above);
     * decode() removes it before parsing. No-op unless QPSK_WHITEN is set. */
    if (qpsk_whiten_on())
        qpsk_whiten(pkt, pkt_bytes);
    return pkt_bytes;
}

int qpsk_frame_decode(const unsigned char *pkt, int pkt_bytes,
                      unsigned char *out, uint32_t *seq)
{
    unsigned char dw[QPSK_PKT_BYTES_MAX];
    unsigned char tmp[QPSK_PKT_BYTES_MAX];
    const unsigned char *p = pkt;
    uint32_t crc_rx, crc;
    int len;

    /* remove the whitener (if enabled) before parsing -- symmetric to encode */
    if (qpsk_whiten_on()) {
        int n = pkt_bytes > QPSK_PKT_BYTES_MAX ? QPSK_PKT_BYTES_MAX : pkt_bytes;
        memcpy(dw, pkt, (size_t)n);
        qpsk_whiten(dw, n);
        p = dw;
    }
    if (p[0] != 0x51 || p[1] != 0x4B)
        return -1;
    len = (int)p[2] | ((int)p[3] << 8);
    if (len > QPSK_FRAME_MAX_PAYLOAD(pkt_bytes))
        return -1;   /* len==0 is a valid idle/keepalive frame (K5 -F) */
    crc_rx = (uint32_t)p[8] | ((uint32_t)p[9] << 8) |
             ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 24);
    memcpy(tmp, p, (size_t)(QPSK_FRAME_HDR_BYTES + len));
    memset(tmp + 8, 0, 4);
    crc = qpsk_crc32(tmp, (size_t)(QPSK_FRAME_HDR_BYTES + len));
    if (crc != crc_rx)
        return -1;
    if (seq)
        *seq = (uint32_t)p[4] | ((uint32_t)p[5] << 8) |
               ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 24);
    if (len > 0)
        memcpy(out, p + QPSK_FRAME_HDR_BYTES, (size_t)len);
    return len;
}
