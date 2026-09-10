/* ref_dump.c -- print the fixed -B reference frame as 16 uint64 words (LSB byte
 * first, matching the byte-DMA word packing) so an offline scorer can compare
 * the RTL-replayed byte_rx against the exact transmitted reference. No hardware. */
#include <stdio.h>
#include <stdint.h>
#include "qpsk_ber.h"
int main(void){
    unsigned char ref[128];
    qpsk_ber_make_ref(ref, 128);
    for (int w = 0; w < 16; w++){
        uint64_t v = 0;
        for (int b = 0; b < 8; b++) v |= ((uint64_t)ref[w*8+b]) << (8*b);
        printf("%016llx\n", (unsigned long long)v);
    }
    return 0;
}
