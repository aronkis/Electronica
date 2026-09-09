/* stage_poll.c -- fast, non-perturbing poll of the RX-processor pipeline
 * forensic registers (already present in the flashed build-1 beat-ILA image).
 * mmaps the modem regfile at 0x9D000000 (READ ONLY -- writes to this space must
 * go via mwipcore direct_reg_access; we never write here) and dumps a CSV with
 * monotonic-ms timestamps so burst anatomy is alias-free.
 *
 * Registers (base 0x9D000000, offset = addr_decoder select<<2, verified:
 *   bit_errors_out sel 0x42 -> 0x108 ; cap_out sel 0x51 -> 0x144, golden 0x04922282):
 *     0x100 count_out        0x104 packets_out      0x108 bit_errors_out
 *     0x120 cnt_descr_in     0x124 cnt_frame_start  0x128 cnt_vit_reset
 *     0x12C cnt_deint_valid  0x130 cnt_dec_bits     0x134 cnt_bist_start
 *     0x13C cap_in           0x140 cap_deint        0x144 cap_out
 *     0x14C cap_cad          0x150 rstcs_count      0x154 cfc_est
 *
 * usage: stage_poll <period_ms> <duration_s>   (CSV -> stdout)
 * Build on-board: gcc -O2 -o /root/stage_poll /root/stage_poll.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

#define BASE 0x9D000000u
#define LEN  0x1000u

static const uint32_t OFF[] = {
    0x100,0x104,0x108,0x120,0x124,0x128,0x12C,0x130,0x134,0x13C,0x140,0x144,0x14C,0x150,0x154,0x20C,0x210
};
static const char *NAME[] = {
    "count_out","packets_out","bit_errors_out","cnt_descr_in","cnt_frame_start",
    "cnt_vit_reset","cnt_deint_valid","cnt_dec_bits","cnt_bist_start",
    "cap_in","cap_deint","cap_out","cap_cad","rstcs_count","cfc_est","viol_count","viol_latch"
};
#define NREG (int)(sizeof(OFF)/sizeof(OFF[0]))

static long now_ms(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    return ts.tv_sec*1000L + ts.tv_nsec/1000000L;
}

int main(int argc, char **argv){
    long period_ms = argc>1 ? atol(argv[1]) : 100;
    long dur_s     = argc>2 ? atol(argv[2]) : 300;
    if (period_ms < 1) period_ms = 1;

    int fd = open("/dev/mem", O_RDWR|O_SYNC);
    if (fd < 0){ perror("open /dev/mem"); return 1; }
    volatile uint8_t *p = mmap(NULL, LEN, PROT_READ, MAP_SHARED, fd, BASE);
    if (p == MAP_FAILED){ perror("mmap"); return 1; }

    /* header */
    printf("t_ms");
    for (int i=0;i<NREG;i++) printf(",%s", NAME[i]);
    printf("\n");
    fflush(stdout);

    long t0 = now_ms();
    long end = t0 + dur_s*1000L;
    long next = t0;
    while (now_ms() < end){
        long t = now_ms();
        printf("%ld", t - t0);
        for (int i=0;i<NREG;i++){
            uint32_t v = *(volatile uint32_t*)(p + OFF[i]);
            printf(",0x%08X", v);
        }
        printf("\n");
        fflush(stdout);   /* durable against a killed/backgrounded run */
        /* pace to period; use absolute schedule to avoid drift */
        next += period_ms;
        long sleep_ms = next - now_ms();
        if (sleep_ms > 0){
            struct timespec req = { sleep_ms/1000, (sleep_ms%1000)*1000000L };
            nanosleep(&req, NULL);
        } else {
            next = now_ms(); /* fell behind; resync */
        }
        (void)t;
    }
    return 0;
}
