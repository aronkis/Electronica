/* gen_txplane_frames.c -- TX byte-in stimulus for the netlist TX-plane reproduction.
 * Emits NF frames as 64-bit words (16 hex digits/line, LSB byte first), NWF words per frame
 * (385 = the daemon's 3080-byte MM2S transfer: 1528-byte frame + zero pad; 191 = TGEN format).
 *   content: idle0  -> qpsk_frame_encode(len=0, seq)          (daemon keepalive; PN pad, real CRC)
 *            fill   -> qpsk_frame_encode(len=1516, PN payload) (daemon data frame, real CRC)
 *            tgen   -> TGEN format (fill 1516 PN, CRC CONSTANT 0x54474E21), per tgen_golden.c
 *   whitening: env QPSK_WHITEN=1 (qpsk_frame_encode whitens exactly as the daemon does)
 * usage: gen_txplane_frames <content> <NF> <NWF> <out.hex>
 * build: gcc -O2 -I../../host -o gen_txplane_frames gen_txplane_frames.c ../../host/qpsk_frame.c ../../host/qpsk_seq.c */
#include "qpsk_frame.h"
#include "qpsk_seq.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: gen_txplane_frames idle0|fill|tgen NF NWF out.hex\n"); return 2; }
  const char *mode = argv[1]; int NF = atoi(argv[2]), NWF = atoi(argv[3]);
  FILE *o = fopen(argv[4], "w"); if (!o) return 2;
  unsigned char pl[1516], f[3080];
  for (int k = 0; k < NF; k++) {
    uint32_t seq = (uint32_t)(k + 1);
    memset(f, 0, sizeof f);
    if (!strcmp(mode, "idle0")) qpsk_frame_encode(f, 1528, NULL, 0, seq);
    else if (!strcmp(mode, "fill")) { qpsk_seq_payload(pl, 1516, seq); qpsk_frame_encode(f, 1528, pl, 1516, seq); }
    else { f[0]=0x51; f[1]=0x4B; f[2]=0xEC; f[3]=0x05; f[4]=seq&255; f[5]=(seq>>8)&255; f[6]=(seq>>16)&255; f[7]=(seq>>24)&255;
           f[8]=0x21; f[9]=0x4E; f[10]=0x47; f[11]=0x54; qpsk_seq_payload(f + 12, 1516, seq); }
    for (int w = 0; w < NWF; w++) { uint64_t v = 0; for (int b = 0; b < 8; b++) v |= (uint64_t)f[w*8+b] << (8*b); fprintf(o, "%016llx\n", (unsigned long long)v); }
  }
  fclose(o); return 0;
}
