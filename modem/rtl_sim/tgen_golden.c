/* tgen_golden.c -- golden frames for the qpsk_traffic_gen TB.
 * Contract mirror of the RTL: real PN via the ACTUAL qpsk_seq_payload(),
 * header per qpsk_frame.h, CRC field CONSTANT (generator never computes CRC;
 * the -S scorer is pre-CRC). Build:
 *   gcc -O2 -I../../host -o tgen_golden tgen_golden.c
 * ../../host/qpsk_seq.c ../../host/qpsk_frame.c (qpsk_seq.c pulls
 * qpsk_frame.h helpers; link qpsk_frame.c for qpsk_frame_encode used elsewhere
 * in seq.c -- we call only qpsk_seq_payload here.) */
#include "qpsk_seq.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PKT 1528
#define HDR 12
#define TGEN_CRC_CONST 0x54474E21u

static void build(unsigned char *f, uint32_t seq, int fill) {
  memset(f, 0, PKT);
  f[0] = 0x51;
  f[1] = 0x4B;                         /* "QK" */
  f[2] = (unsigned char)(fill & 0xFF); /* payload len LE */
  f[3] = (unsigned char)((fill >> 8) & 0xFF);
  f[4] = (unsigned char)(seq & 0xFF); /* seq LE */
  f[5] = (unsigned char)((seq >> 8) & 0xFF);
  f[6] = (unsigned char)((seq >> 16) & 0xFF);
  f[7] = (unsigned char)((seq >> 24) & 0xFF);
  f[8] = (unsigned char)(TGEN_CRC_CONST & 0xFF); /* constant CRC LE */
  f[9] = (unsigned char)((TGEN_CRC_CONST >> 8) & 0xFF);
  f[10] = (unsigned char)((TGEN_CRC_CONST >> 16) & 0xFF);
  f[11] = (unsigned char)((TGEN_CRC_CONST >> 24) & 0xFF);
  qpsk_seq_payload(f + HDR, fill, seq); /* the real PN */
}

int main(int argc, char **argv) {
  unsigned char f[PKT];
  if (argc == 2 && !strcmp(argv[1], "--selftest")) {
    build(f, 1, 1516);
    if (f[0] != 0x51 || f[1] != 0x4B) {
      puts("FAIL magic");
      return 1;
    }
    if (f[2] != 0xEC || f[3] != 0x05) {
      puts("FAIL len");
      return 1;
    } /* 1516 */
    if (f[4] != 1 || f[7] != 0) {
      puts("FAIL seq");
      return 1;
    }
    /* PN spot check: seq=1 -> x0 = 1^0x9E3779B9 = 0x9E3779B8; after one
     * round x = ((x^=x<<13),(x^=x>>17),(x^=x<<5)); byte0 = x&0xFF.
     * Computed with the same code path, so assert self-consistency: */
    unsigned char p[4];
    qpsk_seq_payload(p, 4, 1);
    if (f[HDR] != p[0] || f[HDR + 3] != p[3]) {
      puts("FAIL pn");
      return 1;
    }
    build(f, 7, 0);
    for (int i = HDR; i < PKT; i++)
      if (f[i]) {
        puts("FAIL fill0 pad");
        return 1;
      }
    puts("SELFTEST_OK");
    return 0;
  }
  if (argc != 4) {
    fprintf(stderr, "usage: %s <seq> <fill> <out.bin> | --selftest\n", argv[0]);
    return 2;
  }
  uint32_t seq = (uint32_t)strtoul(argv[1], 0, 0);
  int fill = atoi(argv[2]);
  if (fill < 0)
    fill = 0;
  if (fill > 1516)
    fill = 1516;
  build(f, seq, fill);
  FILE *o = fopen(argv[3], "wb");
  if (!o || fwrite(f, 1, PKT, o) != PKT) {
    perror("write");
    return 3;
  }
  fclose(o);
  return 0;
}
