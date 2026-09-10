/* ms_render.c -- see ms_render.h. */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <limits.h>
#include "ms_render.h"
#include "ms_regmap.h"
#include "ms_health.h"

struct rd { char *buf; size_t pos, cap; int colour, cols, rows, vis, line; };

static void rd_raw(struct rd *r, const char *s)
{
    size_t n = strlen(s);
    if (r->pos + n >= r->cap) n = r->cap - 1 - r->pos;
    memcpy(r->buf + r->pos, s, n); r->pos += n; r->buf[r->pos] = 0;
}

static void rd_txt(struct rd *r, const char *s)
{
    size_t n = strlen(s);
    if ((int)n > r->cols - r->vis) n = r->cols > r->vis ? (size_t)(r->cols - r->vis) : 0;
    if (r->pos + n >= r->cap) n = r->cap - 1 - r->pos;
    memcpy(r->buf + r->pos, s, n); r->pos += n; r->buf[r->pos] = 0;
    r->vis += (int)n;
}

static void rd_f(struct rd *r, const char *fmt, ...)
{
    char tmp[256]; va_list ap;
    va_start(ap, fmt); vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    rd_txt(r, tmp);
}

static const char *sgr(enum ms_level l)
{
    switch (l) {
    case MS_OK: return "\x1b[32m"; case MS_WARN: return "\x1b[33m";
    case MS_BAD: return "\x1b[1;31m"; case MS_STALE: return "\x1b[1;31m";
    default: return "\x1b[2m";
    }
}

static void rd_lvl(struct rd *r, enum ms_level l, const char *s)
{
    if (r->colour) rd_raw(r, sgr(l));
    rd_txt(r, s);
    if (r->colour) rd_raw(r, "\x1b[0m");
}

static void rd_lvlf(struct rd *r, enum ms_level l, const char *fmt, ...)
{
    char tmp[256]; va_list ap;
    va_start(ap, fmt); vsnprintf(tmp, sizeof tmp, fmt, ap); va_end(ap);
    rd_lvl(r, l, tmp);
}

static void rd_inv(struct rd *r, const char *s)
{
    if (r->colour) rd_raw(r, "\x1b[7m");
    rd_txt(r, s);
    if (r->colour) rd_raw(r, "\x1b[0m");
}

static void rd_pad(struct rd *r, int col)
{
    while (r->vis < col && r->vis < r->cols) rd_txt(r, " ");
}

static void rd_nl(struct rd *r)
{
    if (r->colour) rd_raw(r, "\x1b[K");
    rd_raw(r, "\n");
    r->vis = 0; r->line++;
}

/* ------------------------------------------------------------ formatting */

static void fmt_rate(char *o, size_t cap, double rps)
{
    if (rps < 0) rps = -rps;
    if (rps >= 100000) snprintf(o, cap, "%6.0fK", rps / 1000.0);
    else if (rps >= 1000) snprintf(o, cap, "%7.0f", rps);
    else snprintf(o, cap, "%7.1f", rps);
}

/* "  1245.0", "     --", "  RESET", "    SAT", "      ?" */
void ms_reg_rate(const struct ms_view *v, int idx, char *o, size_t cap)
{
    const struct ms_delta *dl = v->dl;
    const struct ms_regdef *r = &ms_regmap[idx];
    if (!dl->valid) { snprintf(o, cap, "%7s", "--"); return; }
    if (dl->sat[idx]) { snprintf(o, cap, "%7s", "SAT"); return; }
    if (dl->reset[idx]) { snprintf(o, cap, "%7s", "RESET"); return; }
    if (dl->ambig[idx]) { snprintf(o, cap, "%7s", "?"); return; }
    if (r->flags & MS_F_SNAP) { snprintf(o, cap, "%7s", "--"); return; }
    if (r->flags & MS_F_PACKED) {
        snprintf(o, cap, "%3u/%-3u", (unsigned)((dl->d[idx] >> 16) & 0xFFFF), (unsigned)(dl->d[idx] & 0xFFFF));
        return;
    }
    fmt_rate(o, cap, (double)dl->d[idx] / dl->dt_s);
}

enum ms_level ms_age_level(int64_t age, int cadence)
{
    if (age < 0) return MS_BAD;
    if (age > MS_STALE_S) return MS_STALE;
    if (age > 2 * cadence) return MS_WARN;
    return MS_OK;
}

void ms_fmt_age(char *o, size_t cap, int64_t age)
{
    if (age < 0) snprintf(o, cap, "no log");
    else if (age > MS_STALE_S) snprintf(o, cap, "STALE %llds", (long long)age);
    else snprintf(o, cap, "%llds old", (long long)age);
}

static enum ms_level regs_level(const struct ms_view *v, enum ms_level l)
{
    return v->cur->regs_valid ? l : MS_NA;
}

/* one register row: " name     off  0xVALUE   d/s  st" (38 visible cols) */
static void reg_row(struct rd *r, const struct ms_view *v, uint16_t off)
{
    int i = ms_reg_index(off);
    const struct ms_regdef *d = &ms_regmap[i];
    char rate[16];
    enum ms_level l = regs_level(v, v->h->reg[i]);
    rd_f(r, " %-9.9s %03X ", d->name, off);
    if (!v->cur->regs_valid) rd_lvl(r, MS_NA, " paused   ");
    else if (off == 0x154) rd_f(r, "%+10d", (int)v->cur->reg[i]);
    else if (d->flags & (MS_F_WRAP32 | MS_F_SAT32 | MS_F_RESET)) rd_f(r, "%10u", v->cur->reg[i]);
    else rd_f(r, "0x%08X", v->cur->reg[i]);
    ms_reg_rate(v, i, rate, sizeof rate);
    if (off == 0x144 && !v->cfg->bist) snprintf(rate, sizeof rate, "%7s", "(byte)");
    rd_f(r, " %s ", rate);
    if (v->cur->paused) rd_lvl(r, MS_NA, "--");
    else rd_lvl(r, l, ms_level_str(l));
}

/* ------------------------------------------------------------ page 1 */

static void hdr_line(struct rd *r, const struct ms_view *v)
{
    const struct ms_radio *ra = &v->cur->r;
    char up[48];
    int64_t u = ra->uptime_s;
    snprintf(up, sizeof up, "%lldd%02lld:%02lld", (long long)(u / 86400), (long long)(u / 3600 % 24), (long long)(u / 60 % 60));
    rd_f(r, "modem_status %s img %s up %s load %.2f", v->cfg->name,
         v->cfg->image_md5[0] ? v->cfg->image_md5 : "????????????", up, ra->load1);
    if (ra->temp_mc != INT_MIN) rd_f(r, " %d C", ra->temp_mc / 1000);
    rd_f(r, " %s", v->wall);
    rd_pad(r, r->cols - 11);
    if (v->cur->paused) rd_inv(r, "REGS:PAUSE");
    else rd_inv(r, "REGS:LIVE ");
    rd_nl(r);
}

/* Rows 4-8 of the BYTE PLANE column as plain text plus a level. Shared with
 * the ncurses front end so both UIs show identical decodes. */
enum ms_level ms_byte_extra(const struct ms_view *v, int row, char *o, size_t cap)
{
    const struct ms_sample *c = v->cur;
    const struct ms_delta *dl = v->dl;
    enum ms_level lvl = MS_NA;
    o[0] = 0;
    if (!c->regs_valid) {
        static const char *tag[5] = { "fstat     1D8", "W1 ring", "W1 census", "R4", "BS" };
        snprintf(o, cap, " %-9s paused", row >= 4 && row <= 8 ? tag[row - 4] : "");
        return MS_NA;
    }
    switch (row) {
    case 4: {
        struct ms_fstat fs;
        ms_dec_fstat(c->reg[ms_reg_index(0x1D8)], &fs);
        snprintf(o, cap, " fstat     1D8 ovf=%u level=%u", fs.overflow, fs.level);
        break; }
    case 5: {
        struct ms_w1_wita a; struct ms_w1_witb b;
        ms_dec_wita(c->reg[ms_reg_index(0x214)], &a);
        ms_dec_witb(c->reg[ms_reg_index(0x218)], &b);
        snprintf(o, cap, " W1 occ=%u push=%u pop=%u pof=%u poe=%u",
                 a.occ, a.push_ptr, a.pop_ptr, b.push_on_full, b.pop_on_empty);
        break; }
    case 6: {
        static const uint16_t offs[6] = { 0x21C, 0x220, 0x224, 0x228, 0x22C, 0x230 };
        static const char *tag[6] = { "ss", "rh", "cfc", "cs", "pd", "pc" };
        int ia = ms_reg_index(offs[0]);
        size_t n;
        if (!dl->valid) { snprintf(o, cap, " W1 census --"); break; }
        n = (size_t)snprintf(o, cap, " W1 ss%.2fM", (double)dl->d[ia] / dl->dt_s / 1e6);
        for (int k = 1; k < 6 && n < cap; k++) {
            int64_t diff = dl->d[ms_reg_index(offs[k])] - dl->d[ia];
            if (diff < -1000) lvl = MS_WARN;
            n += (size_t)snprintf(o + n, cap - n, " %s%+lld", tag[k], (long long)diff);
        }
        break; }
    case 7: {
        uint16_t wo = ms_r4_witness_off(v->cfg->r4d_swapped);
        struct ms_r4 q; int wi; size_t n;
        if (!wo) {
            snprintf(o, cap, " R4 234=%08X 238=%08X img?", c->reg[ms_reg_index(0x234)], c->reg[ms_reg_index(0x238)]);
            lvl = MS_WARN; break;
        }
        wi = ms_reg_index(wo);
        ms_dec_r4(c->reg[wi], &q);
        n = (size_t)snprintf(o, cap, " R4 %03X L=%u skip=%u open", wo, q.locked, q.skips);
        if (dl->valid && !dl->ambig[wi]) n += (size_t)snprintf(o + n, cap - n, "+%u", (unsigned)(dl->d[wi] & 0x7FFF));
        else n += (size_t)snprintf(o + n, cap - n, " ?");
        snprintf(o + n, cap - n, " %s", v->cfg->r4d_swapped == 1 ? "swp" : "can");
        break; }
    case 8: {
        struct ms_bs_marks m; struct ms_bs_evt e; int bi = ms_reg_index(0x250); size_t n;
        ms_dec_bs_marks(c->reg[bi], &m);
        ms_dec_bs_evt(c->reg[ms_reg_index(0x254)], &e);
        if (dl->valid && !dl->ambig[bi])
            n = (size_t)snprintf(o, cap, " BS lasts+%u marks+%u", (unsigned)((dl->d[bi] >> 16) & 0xFFFF), (unsigned)(dl->d[bi] & 0xFFFF));
        else n = (size_t)snprintf(o, cap, " BS lasts ? marks ?");
        snprintf(o + n, cap - n, " dropmax=%u", e.dropmax);
        if (e.dropmax) lvl = MS_WARN;
        break; }
    default: break;
    }
    return lvl;
}

static void byte_right(struct rd *r, const struct ms_view *v, int row)
{
    char t[96];
    enum ms_level l;
    switch (row) {
    case 0: reg_row(r, v, 0x1C0); return;
    case 1: reg_row(r, v, 0x1C4); return;
    case 2: reg_row(r, v, 0x1C8); return;
    case 3: reg_row(r, v, 0x1B0); return;
    default: break;
    }
    l = ms_byte_extra(v, row, t, sizeof t);
    if (l == MS_NA && v->cur->regs_valid) rd_txt(r, t);
    else rd_lvl(r, l, t);
}

static void page1(struct rd *r, const struct ms_view *v)
{
    static const uint16_t left[9] = { 0x104, 0x150, 0x108, 0x154, 0x120, 0x124, 0x128, 0x130, 0x144 };
    const struct ms_sample *c = v->cur;
    const struct ms_health *h = v->h;
    char age[40];

    hdr_line(r, v);
    rd_txt(r, "MODEM RX  off  value         d/s  st | BYTE PLANE off value         d/s  st");
    rd_nl(r);
    for (int i = 0; i < 9; i++) {
        reg_row(r, v, left[i]);
        rd_pad(r, 38); rd_txt(r, " |");
        byte_right(r, v, i);
        rd_nl(r);
    }

    /* DMAC */
    rd_txt(r, "DMAC ");
    if (!c->dmac_valid) rd_lvl(r, MS_NA, "paused");
    else {
        rd_lvlf(r, h->dmac_tx, "TX en=%u id=%02X done=%02X irq=%02X len=%u",
                c->tx.control & 1, c->tx.transfer_id & 0xFF, c->tx.transfer_done & 0xFF,
                c->tx.irq_pending & 0xFF, c->tx.x_length + 1);
        rd_txt(r, " | ");
        rd_lvlf(r, h->dmac_rx, "RX en=%u id=%02X done=%02X irq=%02X len=%u",
                c->rx.control & 1, c->rx.transfer_id & 0xFF, c->rx.transfer_done & 0xFF,
                c->rx.irq_pending & 0xFF, c->rx.x_length + 1);
    }
    rd_nl(r);

    /* RADIO */
    rd_txt(r, "RADIO ");
    if (!c->r.found) rd_lvl(r, MS_BAD, "adrv9002-phy not found");
    else {
        rd_f(r, "%s rssi ", c->r.dev);
        rd_lvlf(r, c->r.rssi_db < 40 ? MS_OK : c->r.rssi_db < 55 ? MS_WARN : MS_BAD, "%.1f dBFS", c->r.rssi_db);
        rd_f(r, " decpow %.1f rxgain %.1f %s txgain %.1f", c->r.decpow_db, c->r.rx_gain_db, c->r.agc_mode, c->r.tx_gain_db);
    }
    rd_nl(r);
    rd_txt(r, "      ");
    if (c->r.found) {
        rd_f(r, "fs %.2f MSPS  ensm rx=", (double)c->r.fs_hz / 1e6);
        rd_lvl(r, h->radio, c->r.rx_ensm[0] ? c->r.rx_ensm : "?");
        rd_txt(r, " tx=");
        rd_lvl(r, h->radio, c->r.tx_ensm[0] ? c->r.tx_ensm : "?");
    }
    rd_nl(r);

    /* DAEMON */
    rd_txt(r, "DAEMON ");
    if (!c->d.pid) rd_lvl(r, MS_BAD, "qpsk_tun not running");
    else {
        rd_lvlf(r, MS_OK, "pid %d up", c->d.pid);
        ms_fmt_age(age, sizeof age, c->d.log_age_s);
        rd_txt(r, "  stats ");
        rd_lvl(r, ms_age_level(c->d.log_age_s, MS_DAEMON_CADENCE_S), age);
        if (c->d.have_stats) {
            rd_f(r, "  rx_ok %llu", (unsigned long long)c->d.st[MS_ST_DMA_RX_OK]);
            rd_f(r, "  crc_drop %llu", (unsigned long long)c->d.st[MS_ST_CRC_DROP]);
            if (v->dl->stats_advanced) rd_f(r, " +%lld", (long long)v->dl->dst[MS_ST_CRC_DROP]);
            rd_txt(r, "  crc ");
            if (h->crc_pct >= 0) rd_lvlf(r, h->crc, "%.2f%%", h->crc_pct);
            else rd_lvl(r, MS_NA, "--");
        } else rd_lvl(r, MS_WARN, "  no stats line (-s unset?)");
    }
    rd_nl(r);
    rd_txt(r, "       ");
    if (c->d.pid && c->d.have_stats) {
        rd_f(r, "idle_rx %llu", (unsigned long long)c->d.st[MS_ST_IDLE_RX]);
        if (v->dl->stats_advanced && v->dl->stats_dt_s > 0)
            rd_f(r, " +%.0f/s", (double)(v->dl->dst[MS_ST_IDLE_RX] + v->dl->dst[MS_ST_DMA_RX_OK]) / v->dl->stats_dt_s);
        rd_f(r, " gap %llu stall %llu drop %llu arq %s rec %llu dup %llu lost %llu",
             (unsigned long long)c->d.st[MS_ST_SEQ_GAP], (unsigned long long)c->d.st[MS_ST_TX_STALL],
             (unsigned long long)c->d.st[MS_ST_TUN_DROP], c->d.arq_on ? "ON" : "off",
             (unsigned long long)c->d.st[MS_ST_RECOVERED], (unsigned long long)c->d.st[MS_ST_DUPS],
             (unsigned long long)c->d.st[MS_ST_ARQ_LOST]);
    } else if (c->d.pid) rd_f(r, "%s", c->d.cmdline);
    rd_nl(r);

    /* WATCHDOG */
    rd_txt(r, "WD ");
    if (!c->wd.pid) rd_lvl(r, MS_WARN, "not running");
    else rd_lvlf(r, MS_OK, "pid %d up", c->wd.pid);
    rd_txt(r, "  ");
    if (c->wd.have_verdict) rd_lvl(r, h->wd, c->wd.last_line);
    else rd_lvl(r, MS_NA, "no verdict");
    ms_fmt_age(age, sizeof age, c->wd.log_age_s);
    rd_txt(r, "  ");
    rd_lvl(r, ms_age_level(c->wd.log_age_s, MS_WD_CADENCE_S), age);
    rd_f(r, "  rearm %d wedge %d", c->wd.rearms, c->wd.wedges);
    rd_nl(r);

    /* HEALTH */
    rd_txt(r, "HEALTH  ");
    rd_lvl(r, h->overall, ms_level_str(h->overall));
    rd_f(r, "  %s", h->summary);
    if (h->fps_meas >= 0) rd_f(r, "  [%.0f f/s, expect %.0f]", h->fps_meas, v->cfg->expected_fps);
    rd_nl(r);
}

/* ------------------------------------------------------------ page 2/3 */

static void page2(struct rd *r, const struct ms_view *v)
{
    uint16_t offs[MS_NREG_MAX]; int n = 0, half;
    hdr_line(r, v);
    rd_txt(r, "REGS 0x008-0x1D8  value         d/s  st | (page 2)");
    rd_nl(r);
    for (int i = 0; i < ms_nreg(); i++)
        if (ms_reg_visible(&ms_regmap[i]) && ms_regmap[i].off < 0x200) offs[n++] = ms_regmap[i].off;
    half = (n + 1) / 2;
    for (int i = 0; i < half && r->line < r->rows - 1; i++) {
        reg_row(r, v, offs[i]);
        rd_pad(r, 38); rd_txt(r, " |");
        if (i + half < n) reg_row(r, v, offs[i + half]);
        rd_nl(r);
    }
}

static void dmac_full(struct rd *r, const char *tag, const struct ms_dmac *d, enum ms_level l)
{
    const uint32_t *w = (const uint32_t *)d;
    rd_lvlf(r, l, "%s", tag);
    for (int i = 0; i < MS_NDMAC; i++) rd_f(r, " %s=%X", ms_dmac_names[i], w[i]);
    rd_nl(r);
}

static void page3(struct rd *r, const struct ms_view *v)
{
    const struct ms_sample *c = v->cur;
    hdr_line(r, v);
    rd_txt(r, "INSTRUMENT WORDS  value         d/s  st | (page 3)");
    rd_nl(r);
    {
        uint16_t offs[MS_NREG_MAX]; int n = 0, half;
        for (int i = 0; i < ms_nreg(); i++)
            if (ms_reg_visible(&ms_regmap[i]) && ms_regmap[i].off >= 0x200) offs[n++] = ms_regmap[i].off;
        half = (n + 1) / 2;
        for (int i = 0; i < half; i++) {
            reg_row(r, v, offs[i]);
            rd_pad(r, 38); rd_txt(r, " |");
            if (i + half < n) reg_row(r, v, offs[i + half]);
            rd_nl(r);
        }
    }
    if (c->dmac_valid) {
        dmac_full(r, "DMAC TX", &c->tx, v->h->dmac_tx);
        dmac_full(r, "DMAC RX", &c->rx, v->h->dmac_rx);
    } else { rd_lvl(r, MS_NA, "DMAC paused"); rd_nl(r); }
    rd_txt(r, "STATS ");
    if (c->d.have_stats) {
        for (int i = 0; i < MS_ST_N; i++) {
            if (r->vis > r->cols - 20) { rd_nl(r); rd_txt(r, "      "); }
            rd_f(r, "%s=%llu ", ms_stat_names[i], (unsigned long long)c->d.st[i]);
        }
    } else rd_lvl(r, MS_NA, "none");
    rd_nl(r);
    rd_txt(r, "WATCHDOG tail:"); rd_nl(r);
    for (int i = 0; i < c->wd.ntail; i++) { rd_f(r, "  %s", c->wd.tail[i]); rd_nl(r); }
}

/* ------------------------------------------------------------ entry points */

static void footer(struct rd *r, const struct ms_view *v, int page)
{
    while (r->line < r->rows - 1) rd_nl(r);
    rd_f(r, " q quit  r rezero  p pause  1/2/3 page  [%d]  t=%lld", page, (long long)v->tick);
    if (v->cur->paused) { rd_txt(r, "  "); rd_lvlf(r, MS_WARN, "PAUSED: %s", v->cur->pause_reason); }
    if (r->colour) rd_raw(r, "\x1b[K");
}

size_t ms_render_tui(const struct ms_view *v, char *buf, size_t cap,
                     int cols, int rows, int colour, int page)
{
    struct rd r = { buf, 0, cap, colour, cols, rows, 0, 0 };
    buf[0] = 0;
    if (colour) rd_raw(&r, "\x1b[H");
    if (cols < 80 || rows < 20) {
        rd_f(&r, "modem_status: need a terminal of at least 80x20 (have %dx%d)", cols, rows);
        if (colour) rd_raw(&r, "\x1b[J");
        return r.pos;
    }
    if (page == 2) page2(&r, v);
    else if (page == 3) page3(&r, v);
    else page1(&r, v);
    footer(&r, v, page);
    if (colour) rd_raw(&r, "\x1b[J");
    return r.pos;
}

size_t ms_render_once(const struct ms_view *v, char *buf, size_t cap)
{
    struct rd r = { buf, 0, cap, 0, 80, 1000, 0, 0 };
    buf[0] = 0;
    page1(&r, v);
    rd_nl(&r);
    page3(&r, v);
    if (v->cur->paused) { rd_f(&r, "PAUSED: %s", v->cur->pause_reason); rd_nl(&r); }
    return r.pos;
}

static void jstr(struct rd *r, const char *s)
{
    rd_raw(r, "\"");
    for (; *s; s++) {
        char t[3] = { *s, 0, 0 };
        if (*s == '"' || *s == '\\') { t[0] = '\\'; t[1] = *s; }
        else if ((unsigned char)*s < 0x20) { t[0] = ' '; }
        rd_raw(r, t);
    }
    rd_raw(r, "\"");
}

static void jnum(struct rd *r, double x)
{
    char t[32];
    if (x != x) snprintf(t, sizeof t, "null");
    else if (x == (double)(long long)x) snprintf(t, sizeof t, "%lld", (long long)x);
    else snprintf(t, sizeof t, "%.3f", x);
    rd_raw(r, t);
}

size_t ms_render_json(const struct ms_view *v, char *buf, size_t cap)
{
    struct rd r = { buf, 0, cap, 0, 100000, 1000, 0, 0 };
    const struct ms_sample *c = v->cur;
    const struct ms_health *h = v->h;
    char t[128];
    buf[0] = 0;
    rd_raw(&r, "{\"name\":"); jstr(&r, v->cfg->name);
    rd_raw(&r, ",\"image\":"); jstr(&r, v->cfg->image_md5);
    rd_raw(&r, ",\"r4d_swapped\":"); jnum(&r, v->cfg->r4d_swapped);
    rd_raw(&r, ",\"wall_s\":"); jnum(&r, (double)c->wall_s);
    rd_raw(&r, ",\"uptime_s\":"); jnum(&r, (double)c->r.uptime_s);
    rd_raw(&r, ",\"load1\":"); jnum(&r, c->r.load1);
    rd_raw(&r, ",\"tick\":"); jnum(&r, (double)v->tick);
    rd_raw(&r, ",\"regs_paused\":"); jnum(&r, c->paused);
    rd_raw(&r, ",\"pause_reason\":"); jstr(&r, c->pause_reason);
    rd_raw(&r, ",\"dt_s\":"); jnum(&r, v->dl->dt_s);
    rd_raw(&r, ",\"regs\":{");
    {
        int first = 1;
        for (int i = 0; i < ms_nreg(); i++) {
            const struct ms_regdef *d = &ms_regmap[i];
            if (!ms_reg_visible(d) || !c->regs_valid) continue;
            if (!first) rd_raw(&r, ",");
            first = 0;
            jstr(&r, d->name);
            snprintf(t, sizeof t, ":{\"off\":%u,\"val\":%u,", d->off, c->reg[i]); rd_raw(&r, t);
            rd_raw(&r, "\"dps\":");
            if (v->dl->valid && !v->dl->sat[i] && !v->dl->reset[i] && !v->dl->ambig[i] && !(d->flags & (MS_F_SNAP | MS_F_PACKED)))
                jnum(&r, (double)v->dl->d[i] / v->dl->dt_s);
            else rd_raw(&r, "null");
            rd_raw(&r, ",\"level\":"); jstr(&r, ms_level_str(h->reg[i]));
            rd_raw(&r, "}");
        }
    }
    rd_raw(&r, "},\"dmac\":");
    if (c->dmac_valid) {
        const uint32_t *tx = (const uint32_t *)&c->tx, *rx = (const uint32_t *)&c->rx;
        rd_raw(&r, "{\"tx\":{");
        for (int i = 0; i < MS_NDMAC; i++) { snprintf(t, sizeof t, "%s\"%s\":%u", i ? "," : "", ms_dmac_names[i], tx[i]); rd_raw(&r, t); }
        rd_raw(&r, "},\"rx\":{");
        for (int i = 0; i < MS_NDMAC; i++) { snprintf(t, sizeof t, "%s\"%s\":%u", i ? "," : "", ms_dmac_names[i], rx[i]); rd_raw(&r, t); }
        rd_raw(&r, "}}");
    } else rd_raw(&r, "null");
    rd_raw(&r, ",\"radio\":{\"found\":"); jnum(&r, c->r.found);
    rd_raw(&r, ",\"dev\":"); jstr(&r, c->r.dev);
    rd_raw(&r, ",\"rssi_dbfs\":"); jnum(&r, c->r.rssi_db);
    rd_raw(&r, ",\"decimated_power_db\":"); jnum(&r, c->r.decpow_db);
    rd_raw(&r, ",\"rx_gain_db\":"); jnum(&r, c->r.rx_gain_db);
    rd_raw(&r, ",\"tx_gain_db\":"); jnum(&r, c->r.tx_gain_db);
    rd_raw(&r, ",\"agc_mode\":"); jstr(&r, c->r.agc_mode);
    rd_raw(&r, ",\"fs_hz\":"); jnum(&r, (double)c->r.fs_hz);
    rd_raw(&r, ",\"rx_ensm\":"); jstr(&r, c->r.rx_ensm);
    rd_raw(&r, ",\"tx_ensm\":"); jstr(&r, c->r.tx_ensm);
    rd_raw(&r, "},\"daemon\":{\"pid\":"); jnum(&r, c->d.pid);
    rd_raw(&r, ",\"cmdline\":"); jstr(&r, c->d.cmdline);
    rd_raw(&r, ",\"log_age_s\":"); jnum(&r, (double)c->d.log_age_s);
    rd_raw(&r, ",\"arq_on\":"); jnum(&r, c->d.arq_on);
    rd_raw(&r, ",\"stats\":");
    if (c->d.have_stats) {
        rd_raw(&r, "{");
        for (int i = 0; i < MS_ST_N; i++) { snprintf(t, sizeof t, "%s\"%s\":%llu", i ? "," : "", ms_stat_names[i], (unsigned long long)c->d.st[i]); rd_raw(&r, t); }
        rd_raw(&r, "}");
    } else rd_raw(&r, "null");
    rd_raw(&r, "},\"watchdog\":{\"pid\":"); jnum(&r, c->wd.pid);
    rd_raw(&r, ",\"locked\":"); if (c->wd.have_verdict) jnum(&r, c->wd.locked); else rd_raw(&r, "null");
    rd_raw(&r, ",\"last\":"); jstr(&r, c->wd.last_line);
    rd_raw(&r, ",\"log_age_s\":"); jnum(&r, (double)c->wd.log_age_s);
    rd_raw(&r, ",\"rearms\":"); jnum(&r, c->wd.rearms);
    rd_raw(&r, ",\"wedges\":"); jnum(&r, c->wd.wedges);
    rd_raw(&r, "},\"health\":{\"overall\":"); jstr(&r, ms_level_str(h->overall));
    rd_raw(&r, ",\"summary\":"); jstr(&r, h->summary);
    rd_raw(&r, ",\"fps\":"); if (h->fps_meas >= 0) jnum(&r, h->fps_meas); else rd_raw(&r, "null");
    rd_raw(&r, ",\"crc_pct\":"); if (h->crc_pct >= 0) jnum(&r, h->crc_pct); else rd_raw(&r, "null");
    rd_raw(&r, ",\"fps_level\":"); jstr(&r, ms_level_str(h->fps));
    rd_raw(&r, ",\"storm_level\":"); jstr(&r, ms_level_str(h->storm));
    rd_raw(&r, ",\"daemon_level\":"); jstr(&r, ms_level_str(h->daemon));
    rd_raw(&r, ",\"wd_level\":"); jstr(&r, ms_level_str(h->wd));
    rd_raw(&r, ",\"radio_level\":"); jstr(&r, ms_level_str(h->radio));
    rd_raw(&r, "}}\n");
    return r.pos;
}

void ms_strip_sgr(char *s)
{
    char *o = s;
    while (*s) {
        if (*s == '\x1b' && s[1] == '[') {
            s += 2;
            while (*s && !((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z'))) s++;
            if (*s) s++;
            continue;
        }
        *o++ = *s++;
    }
    *o = 0;
}
