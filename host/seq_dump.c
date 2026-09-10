/* seq_dump.c -- print the exact -S WIRE frame bytes for a sequence number,
 * as space-separated 2-digit hex, one line per seq given on argv. This is the
 * C ground-truth (qpsk_seq_expected) that contract/seq_frame_bytes_k5.m claims
 * bit-exactness against; tests/TestFrameContract.m cross-checks the two.
 * No hardware. Usage: seq_dump <pkt_bytes> <seq> [seq ...]  */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "qpsk_seq.h"

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: seq_dump <pkt_bytes> <seq>...\n"); return 2; }
    int pkt = atoi(argv[1]);
    if (pkt < 12 || pkt > 1024) { fprintf(stderr, "pkt out of range\n"); return 2; }
    unsigned char frame[1024];
    for (int a = 2; a < argc; a++) {
        uint32_t seq = (uint32_t)strtoul(argv[a], NULL, 0);
        qpsk_seq_expected(frame, pkt, seq);
        for (int i = 0; i < pkt; i++)
            printf("%02x%s", frame[i], (i + 1 < pkt) ? " " : "\n");
    }
    return 0;
}
