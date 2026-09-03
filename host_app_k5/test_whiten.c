/* test_whiten.c -- whitened-mode encode/decode transparency. Sets QPSK_WHITEN
 * before the first codec call so the (lazy, read-once) flag picks it up; this
 * process therefore exercises the whitened path end-to-end, while test_frame /
 * test_k5 cover the un-whitened path. No hardware. */
#define _DEFAULT_SOURCE
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "qpsk_frame.h"

int main(void)
{
    unsigned char pkt[128], out[116], pay[116];
    uint32_t seq = 0;
    int n, fails = 0;

    setenv("QPSK_WHITEN", "1", 1);
    for (int i = 0; i < 116; i++) pay[i] = (unsigned char)(i * 7 + 3);

    /* data frame: whitened on the wire, transparent through decode */
    qpsk_frame_encode(pkt, 128, pay, 116, 0x1234);
    if (pkt[0] == 0x51 && pkt[1] == 0x4B) {
        fprintf(stderr, "FAIL: frame not whitened (plain magic on the wire)\n"); fails++;
    }
    n = qpsk_frame_decode(pkt, 128, out, &seq);
    if (n != 116 || seq != 0x1234 || memcmp(out, pay, 116) != 0) {
        fprintf(stderr, "FAIL: whitened data round-trip (n=%d seq=%x)\n", n, seq); fails++;
    }

    /* a single bit flip on the wire must still be caught by the CRC */
    pkt[40] ^= 0x01;
    if (qpsk_frame_decode(pkt, 128, out, &seq) >= 0) {
        fprintf(stderr, "FAIL: corrupt whitened frame not rejected\n"); fails++;
    }

    /* idle (len=0) keepalive round-trip */
    qpsk_frame_encode(pkt, 128, NULL, 0, 7);
    n = qpsk_frame_decode(pkt, 128, out, &seq);
    if (n != 0 || seq != 7) {
        fprintf(stderr, "FAIL: whitened idle round-trip (n=%d seq=%x)\n", n, seq); fails++;
    }

    printf("whiten tests: %s\n", fails ? "FAILED" : "OK");
    return fails ? 1 : 0;
}
