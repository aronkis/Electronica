/* ms_regmap.h -- static modem / DMAC register table and packed-word decoders.
 * Pure: no I/O. Offsets are BYTE offsets from the modem BAR (AXI word << 2). */
#ifndef MS_REGMAP_H
#define MS_REGMAP_H

#include "modem_status.h"

extern const struct ms_regdef ms_regmap[];
int  ms_nreg(void);                          /* entries in ms_regmap */
int  ms_reg_index(uint16_t off);             /* -1 if not in the table */
int  ms_reg_visible(const struct ms_regdef *r); /* not WO / ABSENT */

/* DMAC read-only words, in struct ms_dmac order. */
extern const uint16_t ms_dmac_offs[MS_NDMAC];
extern const char *const ms_dmac_names[MS_NDMAC];

/* R4D word order for an image: 1 swapped (0x234<->0x238), 0 canonical,
 * -1 unknown (empty md5) -> callers must show raw words only. */
int ms_r4d_order(const char *md5_12);

/* Effective byte offset that carries the R4 witness word and the extras word
 * for this image; returns 0 when unknown (fail closed). */
uint16_t ms_r4_witness_off(int r4d_order);
uint16_t ms_r4_extras_off(int r4d_order);

/* Packed-word decoders (W1_REGMAP.md / docs/byte-plane.rst). */
struct ms_w1_wita { unsigned occ, push_ptr, pop_ptr; };
struct ms_w1_witb { unsigned push_on_full, pop_on_empty; };
struct ms_r4      { unsigned locked, skips, window_opens; };
struct ms_fstat   { unsigned overflow, level; };
struct ms_bs_marks{ unsigned lasts, markpush; };
struct ms_bs_evt  { unsigned trunc_last, trunc_min, trunc_max, dropmax; };
struct ms_bs_cnt  { unsigned trunc, q24; };

void ms_dec_wita(uint32_t w, struct ms_w1_wita *o);
void ms_dec_witb(uint32_t w, struct ms_w1_witb *o);
void ms_dec_r4(uint32_t w, struct ms_r4 *o);
void ms_dec_fstat(uint32_t w, struct ms_fstat *o);
void ms_dec_bs_marks(uint32_t w, struct ms_bs_marks *o);
void ms_dec_bs_evt(uint32_t w, struct ms_bs_evt *o);
void ms_dec_bs_cnt(uint32_t w, struct ms_bs_cnt *o);

#endif
