/* test_frame.c -- contract tests for the QPSK packet framing library,
 * exercised at all deployed packet sizes (280 B / 2240-bit build, 560 B /
 * 4480-bit build, 128 B / two-radio K5 build, 1528 B / two-radio F1536
 * large-frame build). Build/run on the dev host: make test */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "qpsk_frame.h"
#include "qpsk_join.h"   /* COMB campaign: qpsk_fail_class + the log-record ABI */

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

static void run_suite(int pkt_bytes)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    unsigned char payload[QPSK_PKT_BYTES_MAX];
    uint32_t seq;
    int maxp = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
    int n, i, b;

    for (i = 0; i < maxp; i++) payload[i] = (unsigned char)(i * 7 + 3);
    int sizes[] = {1, 2, 64, 100, maxp - 1, maxp};
    for (i = 0; i < 6; i++) {
        n = qpsk_frame_encode(pkt, pkt_bytes, payload, sizes[i], 0xC0FFEE00u + (uint32_t)i);
        CHECK(n == pkt_bytes, "encode fills one packet");
        n = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
        CHECK(n == sizes[i], "decode length");
        CHECK(seq == 0xC0FFEE00u + (uint32_t)i, "decode seq");
        CHECK(memcmp(out, payload, (size_t)sizes[i]) == 0, "decode payload");
    }

    /* oversize and negative rejected at encode */
    CHECK(qpsk_frame_encode(pkt, pkt_bytes, payload, maxp + 1, 1) < 0, "oversize");
    CHECK(qpsk_frame_encode(pkt, pkt_bytes, payload, -1, 1) < 0, "negative len");

    /* len==0 = idle/keepalive frame (K5 -F): valid CRC, decodes to 0,
     * seq preserved, corruption still caught */
    n = qpsk_frame_encode(pkt, pkt_bytes, NULL, 0, 0x1D1E0000u);
    CHECK(n == pkt_bytes, "idle encode fills one packet");
    n = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
    CHECK(n == 0, "idle decode returns 0");
    CHECK(seq == 0x1D1E0000u, "idle seq");
    for (b = 0; b < QPSK_FRAME_HDR_BYTES * 8; b++) {
        pkt[b / 8] ^= (unsigned char)(1u << (b % 8));
        CHECK(qpsk_frame_decode(pkt, pkt_bytes, out, &seq) < 0,
              "corrupt idle rejected");
        pkt[b / 8] ^= (unsigned char)(1u << (b % 8));
    }

    /* corruption: flipping ANY single bit of the used region must be caught */
    n = qpsk_frame_encode(pkt, pkt_bytes, payload, maxp - 68, 42);
    int used = QPSK_FRAME_HDR_BYTES + maxp - 68;
    int caught = 1;
    for (b = 0; b < used * 8; b++) {
        pkt[b / 8] ^= (unsigned char)(1u << (b % 8));
        if (qpsk_frame_decode(pkt, pkt_bytes, out, &seq) >= 0) caught = 0;
        pkt[b / 8] ^= (unsigned char)(1u << (b % 8));
    }
    CHECK(caught, "every single-bit corruption rejected");

    /* garbage and all-zeros packets rejected */
    memset(pkt, 0x5A, sizeof pkt);
    CHECK(qpsk_frame_decode(pkt, pkt_bytes, out, &seq) < 0, "garbage rejected");
    memset(pkt, 0, sizeof pkt);
    CHECK(qpsk_frame_decode(pkt, pkt_bytes, out, &seq) < 0, "zeros rejected");

    printf("frame tests @%dB: done\n", pkt_bytes);
}


/* ---- COMB campaign (T0a): qpsk_fail_class truth table --------------------
 * The daemon writes this class into frame_rec.fail_class at every failed-frame
 * log site, so the classes must be exactly the checks qpsk_frame_decode makes,
 * in the same ORDER (magic, then len, then CRC), with class 4 (ALIGNLOSS
 * zero-tail) overriding a garbage HEADER class (1 or 2) but never a CRC
 * failure. Every case below is checked at F1536 (the deployed geometry). */
static void fc_suite(int pkt_bytes)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char payload[QPSK_PKT_BYTES_MAX];
    int maxp = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
    uint32_t fzo;
    int i;

    for (i = 0; i < maxp; i++) payload[i] = (unsigned char)(i * 7 + 3);

    /* good frame -> class 0, and its PN-filled padding is NOT a zero tail */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_OK, "fc: good frame -> 0");
    CHECK(fzo == QPSK_FZO_NONE, "fc: good frame has no zero tail");
    CHECK(qpsk_first_magic_off(pkt, pkt_bytes) == 0, "fc: good frame magic at 0");

    /* magic corrupted -> 1 (either byte) */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[0] ^= 0xFF;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_MAGIC, "fc: magic[0] -> 1");
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[1] ^= 0x01;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_MAGIC, "fc: magic[1] -> 1");

    /* len > max payload -> 2 (magic intact) */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[2] = (unsigned char)((maxp + 1) & 0xFF);
    pkt[3] = (unsigned char)(((maxp + 1) >> 8) & 0xFF);
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_LEN, "fc: len>max -> 2");
    pkt[2] = 0xFF; pkt[3] = 0xFF;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_LEN, "fc: len=0xFFFF -> 2");

    /* crc flipped -> 3 */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[8] ^= 0x01;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_CRC, "fc: crc flip -> 3");
    /* a payload bit flip is also a CRC failure, not a header class */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[QPSK_FRAME_HDR_BYTES] ^= 0x80;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_CRC, "fc: payload flip -> 3");

    /* ORDER: magic beats len beats crc */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[0] ^= 0xFF; pkt[2] = 0xFF; pkt[3] = 0xFF; pkt[8] ^= 0x01;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_MAGIC,
          "fc: magic checked before len and crc");
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    pkt[2] = 0xFF; pkt[3] = 0xFF; pkt[8] ^= 0x01;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_LEN,
          "fc: len checked before crc");

    /* header garbage + zero tail -> 4 (ALIGNLOSS signature) */
    memset(pkt, 0xA5, (size_t)pkt_bytes);
    memset(pkt + 200, 0, (size_t)(pkt_bytes - 200));
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_ZEROTAIL,
          "fc: garbage header + zero tail -> 4");
    CHECK(fzo == 200u, "fc: zero-tail onset offset");
    CHECK(qpsk_first_magic_off(pkt, pkt_bytes) == QPSK_MAGOFF_NONE,
          "fc: no magic in a zero-tail slice");

    /* an all-zero slice is the extreme case: onset 0 */
    memset(pkt, 0, (size_t)pkt_bytes);
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_ZEROTAIL,
          "fc: all-zero slice -> 4");
    CHECK(fzo == 0u, "fc: all-zero onset is 0");

    /* class 4 overrides a LEN failure too (magic survived the shift) */
    memset(pkt, 0, (size_t)pkt_bytes);
    pkt[0] = 0x51; pkt[1] = 0x4B; pkt[2] = 0xFF; pkt[3] = 0xFF;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_ZEROTAIL,
          "fc: len-bad + zero tail -> 4");

    /* ...but NEVER overrides a CRC failure: the header parsed, so this is a
     * bit-error frame, not an alignment loss */
    memset(pkt, 0, (size_t)pkt_bytes);
    pkt[0] = 0x51; pkt[1] = 0x4B; pkt[2] = 64; pkt[3] = 0;
    pkt[8] = 0xDE; pkt[9] = 0xAD; pkt[10] = 0xBE; pkt[11] = 0xEF;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_CRC,
          "fc: crc-bad + zero tail stays 3");
    CHECK(fzo != QPSK_FZO_NONE, "fc: zero-tail onset reported even for class 3");

    /* a shifted-but-present magic is reported by magic_off */
    memset(pkt, 0x11, (size_t)pkt_bytes);
    pkt[37] = 0x51; pkt[38] = 0x4B;
    CHECK(qpsk_first_magic_off(pkt, pkt_bytes) == 37u, "fc: shifted magic offset");
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_MAGIC,
          "fc: shifted magic is still class 1 (no zero tail)");

    /* a short zero run at the very end must NOT be called a tail */
    qpsk_frame_encode(pkt, pkt_bytes, payload, 64, 0x1234u);
    memset(pkt + pkt_bytes - 8, 0, 8);
    pkt[0] ^= 0xFF;
    CHECK(qpsk_fail_class(pkt, pkt_bytes, &fzo) == QPSK_FC_MAGIC,
          "fc: 8-byte zero run is below QPSK_ZTAIL_MIN");

    printf("fail-class truth table @%dB: done\n", pkt_bytes);
}

/* the on-disk ABI the offline tools parse byte-for-byte */
static void abi_suite(void)
{
    CHECK(sizeof(struct frame_rec) == 48, "abi: frame_rec 48 B");
    CHECK(sizeof(struct failhdr_rec) == 32, "abi: failhdr_rec 32 B");
    CHECK(sizeof(struct txlog_rec) == 32, "abi: txlog_rec 32 B");
    CHECK(sizeof(struct qpsk_log_hdr) == 32, "abi: qpsk_log_hdr 32 B");
    CHECK(offsetof(struct frame_rec, fail_class) == 44, "abi: fail_class at 44");
    CHECK(offsetof(struct failhdr_rec, host_seq) == 8, "abi: failhdr host_seq at 8");
    CHECK(offsetof(struct failhdr_rec, fail_class) == 16, "abi: failhdr class at 16");
    CHECK(offsetof(struct failhdr_rec, magic_off) == 18, "abi: failhdr magic_off at 18");
    CHECK(offsetof(struct failhdr_rec, hdr) == 20, "abi: failhdr hdr at 20");
    CHECK(offsetof(struct txlog_rec, t_complete_ns) == 8, "abi: txlog complete at 8");
    CHECK(offsetof(struct txlog_rec, seq) == 16, "abi: txlog seq at 16");
    CHECK(offsetof(struct txlog_rec, gap_ns) == 20, "abi: txlog gap at 20");
    CHECK(offsetof(struct txlog_rec, inflight) == 28, "abi: txlog inflight at 28");
}

int main(void)
{
    CHECK(QPSK_FRAME_HDR_BYTES == 12, "header size");
    CHECK(QPSK_FRAME_MAX_PAYLOAD(280) == 268, "280B max payload");
    CHECK(QPSK_FRAME_MAX_PAYLOAD(560) == 548, "560B max payload");
    CHECK(QPSK_FRAME_MAX_PAYLOAD(128) == 116, "128B (K5) max payload");
    CHECK(QPSK_FRAME_MAX_PAYLOAD(F1536_PKT_BYTES) == 1516,
          "1528B (F1536) max payload == MTU 1516");
    CHECK(F1536_PKT_BYTES == 1528, "F1536 host frame is 1528 B");
    CHECK(F1536_TX_XFER_BYTES == 3080, "F1536 TX air-frame transfer is 3080 B");
    CHECK(F1536_TX_XFER_BYTES % 8 == 0 && F1536_TX_XFER_BYTES / 8 == 385,
          "F1536 TX transfer is 385 x 64-bit words");
    CHECK(QPSK_PKT_BYTES_MAX >= F1536_PKT_BYTES,
          "QPSK_PKT_BYTES_MAX covers the F1536 frame");
    run_suite(128);
    run_suite(280);
    run_suite(560);
    run_suite(F1536_PKT_BYTES);
    abi_suite();
    fc_suite(F1536_PKT_BYTES);
    fc_suite(280);
    printf("frame tests: %d run, %d failed\n", tests, fails);
    return fails ? 1 : 0;
}
