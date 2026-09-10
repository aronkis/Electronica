/* ms_health.c -- pure health rules. Thresholds from ops/lock_watchdog.sh
 * (PKT_MIN 50/5 s, STORM_THRESH 100/5 s, BITERR_MAX 8000/5 s, GOLDEN),
 * docs/debug-instruments.rst and ops/sim_repro/delivery_sentinel.sh (crc window).
 * crc% is a per-window delivery ratio; it is NOT a PER (no loss accounting). */
#include <stdio.h>
#include <string.h>
#include "ms_health.h"
#include "ms_regmap.h"

const char *ms_level_str(enum ms_level l)
{
    switch (l) {
    case MS_OK: return "OK"; case MS_WARN: return "WARN"; case MS_BAD: return "BAD";
    case MS_STALE: return "STALE"; default: return "--";
    }
}

static enum ms_level worse(enum ms_level a, enum ms_level b)
{
    /* STALE ranks between WARN and BAD for the overall verdict */
    int ra = a == MS_STALE ? 2 : (int)a, rb = b == MS_STALE ? 2 : (int)b;
    return ra >= rb ? a : b;
}

static double rate(const struct ms_delta *dl, int idx)
{
    return dl->valid ? (double)dl->d[idx] / dl->dt_s : -1;
}

void ms_health_eval(const struct ms_cfg *cfg, const struct ms_sample *cur,
                    const struct ms_delta *dl, struct ms_health *h)
{
    int i_pk = ms_reg_index(0x104), i_rst = ms_reg_index(0x150),
        i_be = ms_reg_index(0x108), i_cap = ms_reg_index(0x144),
        i_wc = ms_reg_index(0x1C0), i_drop = ms_reg_index(0x24C),
        i_ovf = ms_reg_index(0x1B0);
    const char *reason = NULL;
    double fps = rate(dl, i_pk), rst = rate(dl, i_rst);

    memset(h, 0, sizeof *h);
    h->fps_meas = -1; h->crc_pct = -1;

    /* -- registers ------------------------------------------------------ */
    if (dl->valid && !dl->reset[i_pk]) {
        h->fps_meas = fps;
        if (fps >= 0.8 * cfg->expected_fps) h->fps = MS_OK;
        else if (fps >= 10) h->fps = MS_WARN;
        else h->fps = MS_BAD;
        if (rst <= 0) h->storm = MS_OK;
        else if (rst < 20) h->storm = MS_WARN;
        else h->storm = MS_BAD;
        if (h->storm == MS_BAD) h->fps = MS_BAD;
    }
    h->reg[i_pk] = h->fps; h->reg[i_rst] = h->storm;

    if (cfg->bist && cur->regs_valid) {
        h->reg[i_cap] = cur->reg[i_cap] == MS_GOLDEN_CAP_OUT ? MS_OK : MS_BAD;
        if (dl->valid) h->reg[i_be] = rate(dl, i_be) < 1600 ? MS_OK : MS_BAD;
    }
    if (dl->valid) {
        if (h->fps == MS_OK && dl->d[i_wc] == 0 && cur->reg[i_wc] != 0) {
            h->byteplane = MS_BAD; h->reg[i_wc] = MS_BAD;
        } else if (h->fps == MS_OK) {
            h->byteplane = MS_OK; h->reg[i_wc] = MS_OK;
        }
        h->reg[i_drop] = dl->d[i_drop] > 0 ? MS_WARN : MS_OK;
        h->reg[i_ovf]  = dl->d[i_ovf]  > 0 ? MS_WARN : MS_OK;
        for (int i = 0; i < ms_nreg(); i++)
            if (dl->reset[i]) h->reg[i] = MS_WARN;
    }

    /* -- daemon --------------------------------------------------------- */
    if (cur->d.pid == 0) h->daemon = MS_BAD;
    else if (!cur->d.have_stats) h->daemon = MS_WARN;
    else if (cur->d.log_age_s > 2 * MS_DAEMON_CADENCE_S) h->daemon = MS_STALE;
    else h->daemon = MS_OK;
    if (dl->stats_advanced) {
        int64_t ok = dl->dst[MS_ST_IDLE_RX] + dl->dst[MS_ST_DMA_RX_OK];
        int64_t bad = dl->dst[MS_ST_CRC_DROP];
        if (ok + bad > 0) {
            h->crc_pct = 100.0 * (double)ok / (double)(ok + bad);
            h->crc = h->crc_pct >= 99.5 ? MS_OK : h->crc_pct >= 95 ? MS_WARN : MS_BAD;
        }
        if (h->fps == MS_OK && cur->d.pid && ok == 0) h->delivery = MS_BAD;
        else if (cur->d.pid && ok > 0) h->delivery = MS_OK;
    }

    /* -- watchdog ------------------------------------------------------- */
    if (cur->wd.pid == 0) h->wd = MS_WARN;
    else if (!cur->wd.have_verdict) h->wd = MS_WARN;
    else if (cur->wd.log_age_s > 3 * MS_WD_CADENCE_S) h->wd = MS_STALE;
    else if (!cur->wd.locked) h->wd = MS_BAD;
    else h->wd = MS_OK;
    if (cur->wd.ntail && (strstr(cur->wd.tail[cur->wd.ntail - 1], "WEDGE"))) h->wd = MS_BAD;

    /* -- radio ---------------------------------------------------------- */
    if (!cur->r.found) h->radio = MS_BAD;
    else if ((cur->r.rx_ensm[0] && strcmp(cur->r.rx_ensm, "rf_enabled")) ||
             (cur->r.tx_ensm[0] && strcmp(cur->r.tx_ensm, "rf_enabled"))) h->radio = MS_WARN;
    else h->radio = MS_OK;

    /* -- DMAC ----------------------------------------------------------- */
    /* enabled = OK. transfer_id/transfer_done do NOT advance every second on
     * the queued/cyclic RX path (measured 148/146 2026-09-09), so "no progress"
     * is informational only, never a WARN. */
    if (cur->dmac_valid) {
        int en_tx = cur->tx.control & 1, en_rx = cur->rx.control & 1;
        h->dmac_tx = en_tx ? MS_OK : (cur->d.pid ? MS_BAD : MS_NA);
        h->dmac_rx = en_rx ? MS_OK : (cur->d.pid ? MS_BAD : MS_NA);
    }

    /* -- overall -------------------------------------------------------- */
    h->overall = MS_NA;
    h->overall = worse(h->overall, h->storm);
    h->overall = worse(h->overall, h->fps);
    h->overall = worse(h->overall, h->byteplane);
    h->overall = worse(h->overall, h->delivery);
    h->overall = worse(h->overall, h->crc);
    h->overall = worse(h->overall, h->daemon);
    h->overall = worse(h->overall, h->wd);
    h->overall = worse(h->overall, h->radio);
    h->overall = worse(h->overall, h->dmac_tx);
    h->overall = worse(h->overall, h->dmac_rx);

    if (h->storm == MS_BAD) reason = "carrier-sync RESET STORM";
    else if (h->fps == MS_BAD) reason = "not decoding (packets flat)";
    else if (h->byteplane == MS_BAD) reason = "BYTE-PLANE WEDGE (wordcnt frozen)";
    else if (h->delivery == MS_BAD) reason = "DELIVERY WEDGE (daemon rx frozen)";
    else if (h->crc == MS_BAD) reason = "crc window below 95%";
    else if (h->daemon == MS_BAD) reason = "qpsk_tun not running";
    else if (h->wd == MS_BAD) reason = "watchdog NOT-LOCKED / wedge";
    else if (h->radio == MS_BAD) reason = "adrv9002-phy not found";
    else if (h->dmac_tx == MS_BAD || h->dmac_rx == MS_BAD) reason = "DMAC disabled while daemon up";
    else if (cur->paused) reason = "register reads paused";
    else if (h->overall == MS_STALE) reason = "a file-sourced field is stale";
    else if (h->overall == MS_WARN) reason = "marginal (see yellow rows)";
    else if (h->overall == MS_OK) reason = "decoding at rate, no reset storm";
    else reason = "no verdict yet";
    if (h->overall == MS_OK && h->crc_pct >= 0)
        snprintf(h->summary, sizeof h->summary, "%s, crc %.2f%%", reason, h->crc_pct);
    else
        snprintf(h->summary, sizeof h->summary, "%s", reason);
}
