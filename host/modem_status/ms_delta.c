/* ms_delta.c -- per-tick counter deltas with wrap / saturation / reset rules. */
#include <string.h>
#include "ms_delta.h"
#include "ms_regmap.h"

void ms_delta_compute(const struct ms_sample *prev, const struct ms_sample *cur,
                      struct ms_delta *dl)
{
    int n = ms_nreg();
    memset(dl, 0, sizeof *dl);
    if (!prev) return;
    dl->dt_s = (double)(cur->t_ms - prev->t_ms) / 1000.0;
    if (dl->dt_s <= 0) dl->dt_s = 0.001;

    if (prev->regs_valid && cur->regs_valid) {
        dl->valid = 1;
        for (int i = 0; i < n; i++) {
            const struct ms_regdef *r = &ms_regmap[i];
            uint32_t p = prev->reg[i], c = cur->reg[i];
            if (r->flags & MS_F_SAT32) {
                if (c == 0xFFFFFFFFu) { dl->sat[i] = 1; dl->d[i] = 0; continue; }
                dl->d[i] = (int64_t)(uint32_t)(c - p);
            } else if (r->flags & MS_F_PACKED) {
                /* 16-bit halves, each mod 2^16 (0x218, 0x250); other packed
                 * words are decoded by the renderer, delta is informational */
                int64_t lo = (int64_t)(uint16_t)((c & 0xFFFF) - (p & 0xFFFF));
                int64_t hi = (int64_t)(uint16_t)((c >> 16) - (p >> 16));
                dl->d[i] = lo | (hi << 16);
                if (dl->dt_s > MS_AMBIG_DT_S) dl->ambig[i] = 1;
            } else if (r->flags & MS_F_RESET) {
                if (c < p && (p - c) < 0x80000000u) {
                    dl->reset[i] = 1; dl->d[i] = c;   /* cleared: count from 0 */
                } else dl->d[i] = (int64_t)(uint32_t)(c - p);
            } else {
                dl->d[i] = (int64_t)(uint32_t)(c - p);
            }
        }
    }

    if (prev->d.have_stats && cur->d.have_stats && cur->d.stats_hash != prev->d.stats_hash) {
        /* the stats line is written every -s seconds, not every tick: rate
         * it over the log mtime difference (writer cadence), not over dt */
        int64_t mprev = prev->wall_s - prev->d.log_age_s, mcur = cur->wall_s - cur->d.log_age_s;
        dl->stats_advanced = 1;
        dl->stats_dt_s = (mcur > mprev && prev->d.log_age_s >= 0) ? (double)(mcur - mprev) : dl->dt_s;
        for (int i = 0; i < MS_ST_N; i++)
            dl->dst[i] = (int64_t)(cur->d.st[i] - prev->d.st[i]);
    }

    if (prev->dmac_valid && cur->dmac_valid) {
        dl->dmac_valid = 1;
        dl->tx_progress = cur->tx.transfer_id != prev->tx.transfer_id ||
                          cur->tx.transfer_done != prev->tx.transfer_done;
        dl->rx_progress = cur->rx.transfer_id != prev->rx.transfer_id ||
                          cur->rx.transfer_done != prev->rx.transfer_done;
    }
}
