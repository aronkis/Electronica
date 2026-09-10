/* ms_regmap.c -- see ms_regmap.h. Sources: stage_poll.c (verified
 * offsets), rxfix/W1_REGMAP.md (0x214-0x258, write-only list, R4D swap;
 * both on tag archive/pre-cleanup-2026-09-09),
 * docs/byte-plane.rst (0x1C0-0x1DC), qpsk_hw.h (tap/canary words),
 * qpsk_tun.c (DMAC defines). */
#include <string.h>
#include <strings.h>
#include "ms_regmap.h"

#define P MS_SEC_RXPIPE
#define C MS_SEC_CAP
#define B MS_SEC_BYTE
#define W MS_SEC_W1
#define S MS_SEC_BS
#define M MS_SEC_MISC

const struct ms_regdef ms_regmap[] = {
    { 0x000, "soft_reset",  M, MS_F_WO,               "soft reset (write-only)" },
    { 0x004, "wo_004",      M, MS_F_WO,               "write-only" },
    { 0x008, "ip_stamp",    M, MS_F_SNAP,             "build timestamp" },
    { 0x100, "count_out",   P, MS_F_WRAP32,           "output count" },
    { 0x104, "packets",     P, MS_F_WRAP32|MS_F_RESET,"detected frames (framesyncs)" },
    { 0x108, "biterr",      P, MS_F_WRAP32|MS_F_BIST, "BIST bit errors, first 120 bits/frame" },
    { 0x10C, "iq_dbg_mux",  M, MS_F_WO,               "tap mux (write-only)" },
    { 0x110, "cs_reset",    M, MS_F_WO,               "carrier-sync reset pulse (write-only)" },
    { 0x114, "rx_in_sel",   M, MS_F_WO,               "rx input select (write-only)" },
    { 0x118, "tx_src_sel",  M, MS_F_WO,               "tx source select (write-only)" },
    { 0x11C, "dbg_sentinel",M, MS_F_SNAP,             "K5 debug sentinel" },
    { 0x120, "descr_in",    P, MS_F_SAT32,            "descrambler input count (saturates)" },
    { 0x124, "frstart",     P, MS_F_WRAP32,           "frame start pulses" },
    { 0x128, "vit_reset",   P, MS_F_WRAP32,           "Viterbi resets" },
    { 0x12C, "deint_valid", P, MS_F_SAT32,            "deinterleaver valid (saturates)" },
    { 0x130, "dec_bits",    P, MS_F_SAT32,            "decoded info bits (saturates ~281 s)" },
    { 0x134, "bist_start",  P, MS_F_WRAP32,           "independent frame starts" },
    { 0x138, "wo_138",      M, MS_F_WO,               "write-only" },
    { 0x13C, "cap_in",      C, MS_F_SNAP,             "capture tap: input" },
    { 0x140, "cap_deint",   C, MS_F_SNAP,             "capture tap: deinterleaver" },
    { 0x144, "cap_out",     C, MS_F_SNAP|MS_F_BIST,   "capture tap: output (golden 0x04922282 in BIST)" },
    { 0x14C, "cap_cad",     C, MS_F_SNAP,             "capture tap: cadence" },
    { 0x150, "rstcs",       P, MS_F_WRAP32,           "carrier-sync resets (storm indicator)" },
    { 0x154, "cfc",         P, MS_F_SNAP,             "coarse frequency compensator estimate" },
    { 0x158, "tx_data_src", M, MS_F_WO,               "0 ROM/BIST, 1 byte DMA (write-only)" },
    { 0x15C, "adc_forensic",M, MS_F_ABSENT,           "not decoded on current images" },
    { 0x160, "agc_in",      C, MS_F_SNAP|MS_F_OPT,    "AGC in I/Q (tap images)" },
    { 0x164, "agc_out",     C, MS_F_SNAP|MS_F_OPT,    "AGC out I/Q (tap images)" },
    { 0x168, "cs_in",       C, MS_F_SNAP|MS_F_OPT,    "carrier-sync in I/Q (tap images)" },
    { 0x16C, "cs_out",      C, MS_F_SNAP|MS_F_OPT,    "carrier-sync out I/Q (tap images)" },
    { 0x170, "wo_170",      M, MS_F_WO,               "write-only" },
    { 0x174, "wo_174",      M, MS_F_WO,               "write-only" },
    { 0x178, "wo_178",      M, MS_F_WO,               "write-only" },
    { 0x17C, "wo_17C",      M, MS_F_WO,               "write-only" },
    { 0x180, "wo_180",      M, MS_F_WO,               "write-only" },
    { 0x184, "wo_184",      M, MS_F_WO,               "write-only" },
    { 0x188, "beat_cnt",    M, MS_F_WRAP32|MS_F_OPT,  "free-running rail-beat counter (canary images)" },
    { 0x18C, "path_canary", M, MS_F_SNAP|MS_F_OPT,    "path canary sat counters (canary images)" },
    { 0x1B0, "fifo_ovf",    B, MS_F_WRAP32,           "byte FIFO overflow" },
    { 0x1C0, "wordcnt",     B, MS_F_WRAP32|MS_F_RESET,"byte_rx words accepted (CP1)" },
    { 0x1C4, "stallcnt",    B, MS_F_WRAP32,           "byte_rx valid&&!ready stall cycles" },
    { 0x1C8, "txurcnt",     B, MS_F_WRAP32,           "TX bit-shifter underrun reloads" },
    { 0x1D0, "fs_head_lo",  B, MS_F_SNAP,             "frame-status head [31:0] (non-popping)" },
    { 0x1D4, "fs_head_hi",  B, MS_F_SNAP,             "frame-status head [63:32] (non-popping)" },
    { 0x1D8, "fstat",       B, MS_F_PACKED,           "{overflow[31:16]|level[15:0]}" },
    { 0x1DC, "fs_pop",      M, MS_F_WO,               "frame-status pop token (write-only)" },
    { 0x208, "fixctl",      M, MS_F_WO,               "fix control (write-only)" },
    { 0x20C, "viol_count",  M, MS_F_WRAP32|MS_F_OPT,  "beatfix violation count" },
    { 0x210, "viol_latch",  M, MS_F_SNAP|MS_F_OPT,    "beatfix violation latch" },
    { 0x214, "w1_wita",     W, MS_F_PACKED,           "{occ[15:10] pushPtr[9:5] popPtr[4:0]}" },
    { 0x218, "w1_witb",     W, MS_F_PACKED,           "{push_on_full[31:16] pop_on_empty[15:0]}" },
    { 0x21C, "w1_ss",       W, MS_F_WRAP32,           "census (a) symbol-sync strobes" },
    { 0x220, "w1_rh",       W, MS_F_WRAP32,           "census (b) Rate_Handle validOut" },
    { 0x224, "w1_cfc",      W, MS_F_WRAP32,           "census (c) CFC validOut" },
    { 0x228, "w1_cs",       W, MS_F_WRAP32,           "census (d) carrier-sync validOut" },
    { 0x22C, "w1_pd",       W, MS_F_WRAP32,           "census (e) preamble-detector validOut" },
    { 0x230, "w1_pc",       W, MS_F_WRAP32,           "census (f) packet-controller validOut" },
    { 0x234, "r4_wit",      W, MS_F_PACKED|MS_F_IMGKEY,"{locked[31] skips[30:15] opens[14:0]} (image-keyed)" },
    { 0x238, "r4_extras",   W, MS_F_PACKED|MS_F_IMGKEY,"R4D/R4E extras (image-keyed)" },
    { 0x23C, "bs_words",    S, MS_F_WRAP32,           "ByteSerializer words" },
    { 0x240, "bs_starts",   S, MS_F_WRAP32,           "RxAlign start pulses (frame boundaries)" },
    { 0x244, "bs_push",     S, MS_F_WRAP32,           "ByteRxFifo pushes" },
    { 0x248, "bs_pop",      S, MS_F_WRAP32,           "ByteRxFifo pops" },
    { 0x24C, "bs_drop",     S, MS_F_WRAP32,           "ByteRxFifo drop-oldest events" },
    { 0x250, "bs_marks",    S, MS_F_PACKED,           "{lasts[31:16] markpush[15:0]} wraps 52.6 s" },
    { 0x254, "bs_evt",      S, MS_F_PACKED,           "{trunc_last trunc_min trunc_max dropmax} sat" },
    { 0x258, "bs_cnt",      S, MS_F_PACKED,           "{trunc[31:16] q24[15:8]}" },
};

int ms_nreg(void) { return (int)(sizeof(ms_regmap) / sizeof(ms_regmap[0])); }

int ms_reg_index(uint16_t off)
{
    int n = ms_nreg();
    for (int i = 0; i < n; i++)
        if (ms_regmap[i].off == off) return i;
    return -1;
}

int ms_reg_visible(const struct ms_regdef *r)
{
    return (r->flags & (MS_F_WO | MS_F_ABSENT)) == 0;
}

/* axi_dmac: read-only words only. 0x408 SUBMIT, 0x410 DEST, 0x414 SRC are
 * deliberately absent (SUBMIT has side effects; the others are the daemon's). */
const uint16_t ms_dmac_offs[MS_NDMAC] = {
    0x080, 0x084, 0x088, 0x400, 0x404, 0x40C, 0x418, 0x428
};
const char *const ms_dmac_names[MS_NDMAC] = {
    "irq_mask", "irq_pending", "irq_source", "control", "transfer_id",
    "flags", "x_length", "transfer_done"
};

int ms_r4d_order(const char *md5_12)
{
    if (!md5_12 || !md5_12[0]) return -1;
    if (strncasecmp(md5_12, MS_R4D_SWAPPED_MD5, 12) == 0) return 1;
    return 0;
}

uint16_t ms_r4_witness_off(int r4d_order)
{
    if (r4d_order == 1) return 0x238;
    if (r4d_order == 0) return 0x234;
    return 0;
}

uint16_t ms_r4_extras_off(int r4d_order)
{
    if (r4d_order == 1) return 0x234;
    if (r4d_order == 0) return 0x238;
    return 0;
}

void ms_dec_wita(uint32_t w, struct ms_w1_wita *o)
{
    o->occ = (w >> 10) & 0x3F; o->push_ptr = (w >> 5) & 0x1F; o->pop_ptr = w & 0x1F;
}
void ms_dec_witb(uint32_t w, struct ms_w1_witb *o)
{
    o->push_on_full = w >> 16; o->pop_on_empty = w & 0xFFFF;
}
void ms_dec_r4(uint32_t w, struct ms_r4 *o)
{
    o->locked = w >> 31; o->skips = (w >> 15) & 0xFFFF; o->window_opens = w & 0x7FFF;
}
void ms_dec_fstat(uint32_t w, struct ms_fstat *o)
{
    o->overflow = w >> 16; o->level = w & 0xFFFF;
}
void ms_dec_bs_marks(uint32_t w, struct ms_bs_marks *o)
{
    o->lasts = w >> 16; o->markpush = w & 0xFFFF;
}
void ms_dec_bs_evt(uint32_t w, struct ms_bs_evt *o)
{
    o->trunc_last = w >> 24; o->trunc_min = (w >> 16) & 0xFF;
    o->trunc_max = (w >> 8) & 0xFF; o->dropmax = w & 0xFF;
}
void ms_dec_bs_cnt(uint32_t w, struct ms_bs_cnt *o)
{
    o->trunc = w >> 16; o->q24 = (w >> 8) & 0xFF;
}

const char *const ms_stat_names[MS_ST_N] = {
    "tunA_rx", "tunA_tx", "tunB_rx", "tunB_tx", "dma_tx", "dma_rx_ok",
    "crc_drop", "seq_gap", "idle_tx", "idle_rx", "tun_drop", "oversize",
    "tx_stall", "b_drop", "retx", "dups", "recovered", "naks_tx", "naks_rx",
    "arq_lost"
};
