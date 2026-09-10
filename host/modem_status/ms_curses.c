/* ms_curses.c -- the panelled ncurses UI. It only DRAWS: every value comes
 * from ms_sample/ms_delta/ms_health, every decode from ms_render.c helpers,
 * so the text (--once/--json) and curses views cannot disagree. Layout is
 * fixed at 80x24 minimum; wider terminals get the extra width, taller ones
 * push the footer down. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <locale.h>
#include <limits.h>
#include <stdarg.h>
#include <unistd.h>
#include <ncurses.h>
#include "ms_curses.h"
#include "ms_regmap.h"
#include "ms_health.h"
#include "ms_render.h"

static int entered;

static int attr_of(enum ms_level l)
{
    if (!has_colors()) return l == MS_BAD || l == MS_STALE ? A_BOLD : l == MS_NA ? A_DIM : A_NORMAL;
    switch (l) {
    case MS_OK:   return COLOR_PAIR(1);
    case MS_WARN: return COLOR_PAIR(2);
    case MS_BAD:  return COLOR_PAIR(3) | A_BOLD;
    case MS_STALE:return COLOR_PAIR(3) | A_BOLD;
    default:      return A_DIM;
    }
}

int ms_curses_enter(void)
{
    if (!isatty(0) || !isatty(1)) return -1;
    setlocale(LC_ALL, "");
    if (!initscr()) return -1;
    entered = 1;
    cbreak(); noecho(); keypad(stdscr, TRUE); curs_set(0); timeout(0);
    if (has_colors()) {
        start_color(); use_default_colors();
        init_pair(1, COLOR_GREEN, -1);
        init_pair(2, COLOR_YELLOW, -1);
        init_pair(3, COLOR_RED, -1);
        init_pair(4, COLOR_CYAN, -1);
    }
    return 0;
}

void ms_curses_leave(void)
{
    if (!entered) return;
    entered = 0;
    endwin();
}

int ms_curses_key(int timeout_ms)
{
    int ch;
    timeout(timeout_ms < 0 ? 0 : timeout_ms);
    ch = getch();
    if (ch == ERR) return -1;
    if (ch == KEY_RESIZE) return -2;
    if (ch == 3) return 'q';
    return ch;
}

/* ---------------------------------------------------------------- drawing */

static int W;   /* screen width */

static void hline_at(int y, int x0, int x1)
{
    mvhline(y, x0, ACS_HLINE, x1 - x0 + 1);
}

/* separator row with a left title and optional right title:  ├ TITLE ─────┤ */
static void sep(int y, const char *title, const char *rtitle, enum ms_level tl,
                int tee_at)
{
    hline_at(y, 1, W - 2);
    mvaddch(y, 0, ACS_LTEE); mvaddch(y, W - 1, ACS_RTEE);
    if (tee_at > 0) mvaddch(y, tee_at, ACS_BTEE);
    attron(A_BOLD | attr_of(tl)); mvprintw(y, 2, " %s ", title); attroff(A_BOLD | attr_of(tl));
    if (rtitle && rtitle[0]) {
        int len = (int)strlen(rtitle) + 2;
        mvprintw(y, W - 2 - len, " %s ", rtitle);
    }
}

static void lvl_str(int y, int x, enum ms_level l, const char *s)
{
    attron(attr_of(l)); mvaddstr(y, x, s); attroff(attr_of(l));
}

static void lvl_printf(int y, int x, enum ms_level l, const char *fmt, ...)
{
    char t[256]; va_list ap;
    va_start(ap, fmt); vsnprintf(t, sizeof t, fmt, ap); va_end(ap);
    lvl_str(y, x, l, t);
}

/* one register row at (y,x): name off value rate st */
static void reg_row(int y, int x, const struct ms_view *v, uint16_t off)
{
    int i = ms_reg_index(off);
    const struct ms_regdef *d = &ms_regmap[i];
    const struct ms_sample *c = v->cur;
    char rate[16];
    enum ms_level l = c->regs_valid ? v->h->reg[i] : MS_NA;
    mvprintw(y, x, "%-9.9s ", d->name);
    attron(A_DIM); mvprintw(y, x + 10, "%03X", off); attroff(A_DIM);
    if (!c->regs_valid) lvl_str(y, x + 14, MS_NA, "  paused  ");
    else if (off == 0x154) mvprintw(y, x + 14, "%+10d", (int)c->reg[i]);
    else if (d->flags & (MS_F_WRAP32 | MS_F_SAT32 | MS_F_RESET)) mvprintw(y, x + 14, "%10u", c->reg[i]);
    else mvprintw(y, x + 14, "0x%08X", c->reg[i]);
    ms_reg_rate(v, i, rate, sizeof rate);
    if (off == 0x144 && !v->cfg->bist) snprintf(rate, sizeof rate, "%7s", "(byte)");
    mvaddstr(y, x + 25, rate);
    if (c->paused) lvl_str(y, x + 33, MS_NA, "--");
    else lvl_str(y, x + 33, l, ms_level_str(l));
}

static void header(const struct ms_view *v)
{
    const struct ms_radio *ra = &v->cur->r;
    int64_t u = ra->uptime_s;
    char t[128];
    box(stdscr, 0, 0);
    snprintf(t, sizeof t, " modem_status %s  img %s  up %lldd%02lld:%02lld  %s ",
             v->cfg->name, v->cfg->image_md5[0] ? v->cfg->image_md5 : "????????????",
             (long long)(u / 86400), (long long)(u / 3600 % 24), (long long)(u / 60 % 60), v->wall);
    attron(A_BOLD); mvaddstr(0, 2, t); attroff(A_BOLD);
    if (v->cur->paused) { attron(A_REVERSE | attr_of(MS_WARN)); mvaddstr(0, W - 15, " REGS:PAUSED "); attroff(A_REVERSE | attr_of(MS_WARN)); }
    else { attron(A_REVERSE | attr_of(MS_OK)); mvaddstr(0, W - 13, " REGS:LIVE "); attroff(A_REVERSE | attr_of(MS_OK)); }
}

static void footer(const struct ms_view *v, int page)
{
    int y = LINES - 1;
    char t[128];
    snprintf(t, sizeof t, " q quit  r rezero  p pause  1/2/3 page [%d] ", page);
    mvaddstr(y, 2, t);
    if (v->cur->paused) {
        snprintf(t, sizeof t, " PAUSED: %s ", v->cur->pause_reason);
        lvl_str(y, 2 + (int)strlen(" q quit  r rezero  p pause  1/2/3 page [1] "), MS_WARN, t);
    }
    snprintf(t, sizeof t, " t=%lld ", (long long)v->tick);
    mvaddstr(y, W - 2 - (int)strlen(t), t);
}

static void page1(const struct ms_view *v)
{
    static const uint16_t left[9] = { 0x104, 0x150, 0x108, 0x154, 0x120, 0x124, 0x128, 0x130, 0x144 };
    static const uint16_t right4[4] = { 0x1C0, 0x1C4, 0x1C8, 0x1B0 };
    const struct ms_sample *c = v->cur;
    const struct ms_health *h = v->h;
    const int DIV = 39;
    char t[128], age[40];
    int y;

    header(v);
    /* column header row */
    hline_at(1, 1, W - 2); mvaddch(1, 0, ACS_LTEE); mvaddch(1, W - 1, ACS_RTEE); mvaddch(1, DIV, ACS_TTEE);
    attron(A_BOLD); mvaddstr(1, 2, " MODEM RX "); mvaddstr(1, DIV + 2, " BYTE PLANE "); attroff(A_BOLD);
    attron(A_DIM); mvaddstr(1, DIV - 23, " value       d/s   st "); mvaddstr(1, W - 24, " value       d/s   st "); attroff(A_DIM);
    for (int i = 0; i < 9; i++) {
        y = 2 + i;
        mvaddch(y, DIV, ACS_VLINE);
        reg_row(y, 2, v, left[i]);
        if (i < 4) reg_row(y, DIV + 2, v, right4[i]);
        else {
            enum ms_level l = ms_byte_extra(v, i, t, sizeof t);
            int room = W - 1 - (DIV + 1);
            if (c->regs_valid && l == MS_NA) mvaddnstr(y, DIV + 1, t, room);
            else { attron(attr_of(l)); mvaddnstr(y, DIV + 1, t, room); attroff(attr_of(l)); }
        }
    }

    /* DMAC */
    sep(11, "DMAC", NULL, MS_NA, DIV);
    if (!c->dmac_valid) lvl_str(12, 2, MS_NA, "paused");
    else {
        lvl_printf(12, 2, h->dmac_tx, "TX en=%u id=%02X done=%02X irq=%02X len=%u",
                   c->tx.control & 1, c->tx.transfer_id & 0xFF, c->tx.transfer_done & 0xFF,
                   c->tx.irq_pending & 0xFF, c->tx.x_length + 1);
        mvaddch(12, DIV, ACS_VLINE);
        lvl_printf(12, DIV + 2, h->dmac_rx, "RX en=%u id=%02X done=%02X irq=%02X",
                   c->rx.control & 1, c->rx.transfer_id & 0xFF, c->rx.transfer_done & 0xFF,
                   c->rx.irq_pending & 0xFF);
    }

    /* RADIO */
    if (c->r.found) snprintf(t, sizeof t, "RADIO %s", c->r.dev); else snprintf(t, sizeof t, "RADIO");
    sep(13, t, NULL, h->radio, 0);
    if (!c->r.found) lvl_str(14, 2, MS_BAD, "adrv9002-phy not found");
    else {
        mvaddstr(14, 2, "rssi ");
        lvl_printf(14, 7, c->r.rssi_db < 40 ? MS_OK : c->r.rssi_db < 55 ? MS_WARN : MS_BAD, "%.1f dBFS", c->r.rssi_db);
        mvprintw(14, 20, "decpow %.1f dB   rxgain %.1f dB %s   txgain %.1f dB",
                 c->r.decpow_db, c->r.rx_gain_db, c->r.agc_mode, c->r.tx_gain_db);
        mvprintw(15, 2, "fs %.2f MSPS   ensm rx=", (double)c->r.fs_hz / 1e6);
        mvprintw(15, W - 14, "load %.2f", c->r.load1);
        lvl_str(15, 26, h->radio, c->r.rx_ensm[0] ? c->r.rx_ensm : "?");
        mvaddstr(15, 26 + (int)strlen(c->r.rx_ensm[0] ? c->r.rx_ensm : "?"), "  tx=");
        lvl_str(15, 31 + (int)strlen(c->r.rx_ensm[0] ? c->r.rx_ensm : "?"), h->radio, c->r.tx_ensm[0] ? c->r.tx_ensm : "?");
    }

    /* DAEMON */
    if (c->d.pid) snprintf(t, sizeof t, "DAEMON qpsk_tun pid %d", c->d.pid);
    else snprintf(t, sizeof t, "DAEMON qpsk_tun");
    ms_fmt_age(age, sizeof age, c->d.log_age_s);
    snprintf(t + strlen(t), sizeof t - strlen(t), "%s", "");
    sep(16, t, c->d.pid ? age : NULL, h->daemon, 0);
    if (c->d.pid) {
        /* recolour the age in the separator */
        int len = (int)strlen(age) + 2;
        lvl_printf(16, W - 2 - len, ms_age_level(c->d.log_age_s, MS_DAEMON_CADENCE_S), " %s ", age);
    }
    if (!c->d.pid) lvl_str(17, 2, MS_BAD, "not running");
    else if (!c->d.have_stats) { lvl_str(17, 2, MS_WARN, "no stats line (-s unset?)"); mvaddstr(18, 2, c->d.cmdline); }
    else {
        int x = 2;
        mvprintw(17, x, "rx_ok %llu   crc_drop %llu", (unsigned long long)c->d.st[MS_ST_DMA_RX_OK], (unsigned long long)c->d.st[MS_ST_CRC_DROP]);
        x = 2 + (int)snprintf(t, sizeof t, "rx_ok %llu   crc_drop %llu", (unsigned long long)c->d.st[MS_ST_DMA_RX_OK], (unsigned long long)c->d.st[MS_ST_CRC_DROP]);
        if (v->dl->stats_advanced) { mvprintw(17, x, " +%lld", (long long)v->dl->dst[MS_ST_CRC_DROP]); x += (int)snprintf(t, sizeof t, " +%lld", (long long)v->dl->dst[MS_ST_CRC_DROP]); }
        mvaddstr(17, x, "   crc "); x += 7;
        if (h->crc_pct >= 0) lvl_printf(17, x, h->crc, "%.2f%%", h->crc_pct); else lvl_str(17, x, MS_NA, "--");
        x = 2 + (int)snprintf(t, sizeof t, "idle_rx %llu", (unsigned long long)c->d.st[MS_ST_IDLE_RX]);
        mvaddstr(18, 2, t);
        if (v->dl->stats_advanced && v->dl->stats_dt_s > 0) {
            snprintf(t, sizeof t, " +%.0f/s", (double)(v->dl->dst[MS_ST_IDLE_RX] + v->dl->dst[MS_ST_DMA_RX_OK]) / v->dl->stats_dt_s);
            mvaddstr(18, x, t); x += (int)strlen(t);
        }
        snprintf(t, sizeof t, "  gap %llu stall %llu drop %llu arq %s rec %llu dup %llu lost %llu",
                 (unsigned long long)c->d.st[MS_ST_SEQ_GAP], (unsigned long long)c->d.st[MS_ST_TX_STALL],
                 (unsigned long long)c->d.st[MS_ST_TUN_DROP], c->d.arq_on ? "ON" : "off",
                 (unsigned long long)c->d.st[MS_ST_RECOVERED], (unsigned long long)c->d.st[MS_ST_DUPS],
                 (unsigned long long)c->d.st[MS_ST_ARQ_LOST]);
        mvaddnstr(18, x, t, W - 1 - x);
    }

    /* WATCHDOG */
    if (c->wd.pid) snprintf(t, sizeof t, "WATCHDOG pid %d", c->wd.pid);
    else snprintf(t, sizeof t, "WATCHDOG not running");
    ms_fmt_age(age, sizeof age, c->wd.log_age_s);
    sep(19, t, age, h->wd, 0);
    lvl_printf(19, W - 2 - (int)strlen(age) - 2, ms_age_level(c->wd.log_age_s, MS_WD_CADENCE_S), " %s ", age);
    if (c->wd.have_verdict) lvl_str(20, 2, h->wd, c->wd.last_line);
    else lvl_str(20, 2, MS_NA, "no verdict");
    mvprintw(20, 2 + (int)strlen(c->wd.have_verdict ? c->wd.last_line : "no verdict"),
             "   rearm %d  wedge %d", c->wd.rearms, c->wd.wedges);

    /* HEALTH */
    sep(21, "HEALTH", NULL, h->overall, 0);
    lvl_printf(22, 2, h->overall, "%-5s", ms_level_str(h->overall));
    if (h->fps_meas >= 0) snprintf(t, sizeof t, "%s   [%.0f f/s, expect %.0f]", h->summary, h->fps_meas, v->cfg->expected_fps);
    else snprintf(t, sizeof t, "%s", h->summary);
    mvaddnstr(22, 8, t, W - 1 - 8);
}

static void reg_table(const struct ms_view *v, int y0, uint16_t lo, uint16_t hi, const char *title)
{
    uint16_t offs[MS_NREG_MAX]; int n = 0, half, y = y0 + 1;
    const int DIV = 39;
    for (int i = 0; i < ms_nreg(); i++)
        if (ms_reg_visible(&ms_regmap[i]) && ms_regmap[i].off >= lo && ms_regmap[i].off <= hi) offs[n++] = ms_regmap[i].off;
    half = (n + 1) / 2;
    hline_at(y0, 1, W - 2); mvaddch(y0, 0, ACS_LTEE); mvaddch(y0, W - 1, ACS_RTEE); mvaddch(y0, DIV, ACS_TTEE);
    attron(A_BOLD); mvprintw(y0, 2, " %s ", title); attroff(A_BOLD);
    attron(A_DIM); mvaddstr(y0, DIV - 23, " value       d/s   st "); mvaddstr(y0, W - 24, " value       d/s   st "); attroff(A_DIM);
    for (int i = 0; i < half && y < LINES - 1; i++, y++) {
        mvaddch(y, DIV, ACS_VLINE);
        reg_row(y, 2, v, offs[i]);
        if (i + half < n) reg_row(y, DIV + 2, v, offs[i + half]);
    }
}

static void page2(const struct ms_view *v)
{
    header(v);
    reg_table(v, 1, 0x000, 0x1FF, "REGISTERS 0x008-0x1D8");
}

static void page3(const struct ms_view *v)
{
    const struct ms_sample *c = v->cur;
    int y;
    char t[512];
    header(v);
    reg_table(v, 1, 0x200, 0x2FF, "INSTRUMENT WORDS 0x20C-0x258");
    y = 1 + 1 + 10;
    sep(y, "DMAC", NULL, MS_NA, 39); y++;
    if (!c->dmac_valid) lvl_str(y++, 2, MS_NA, "paused");
    else {
        const uint32_t *tx = (const uint32_t *)&c->tx, *rx = (const uint32_t *)&c->rx;
        int n = snprintf(t, sizeof t, "TX");
        for (int i = 0; i < MS_NDMAC; i++) n += snprintf(t + n, sizeof t - (size_t)n, " %s=%X", ms_dmac_names[i], tx[i]);
        lvl_str(y++, 2, v->h->dmac_tx, t);
        n = snprintf(t, sizeof t, "RX");
        for (int i = 0; i < MS_NDMAC; i++) n += snprintf(t + n, sizeof t - (size_t)n, " %s=%X", ms_dmac_names[i], rx[i]);
        lvl_str(y++, 2, v->h->dmac_rx, t);
    }
    sep(y++, "DAEMON STATS", NULL, MS_NA, 0);
    if (c->d.have_stats) {
        int x = 2;
        for (int i = 0; i < MS_ST_N; i++) {
            int n = snprintf(t, sizeof t, "%s=%llu  ", ms_stat_names[i], (unsigned long long)c->d.st[i]);
            if (x + n > W - 2) { x = 2; y++; }
            if (y >= LINES - 1) break;
            mvaddstr(y, x, t); x += n;
        }
        y++;
    } else lvl_str(y++, 2, MS_NA, "none");
    if (y < LINES - 2) {
        sep(y++, "WATCHDOG TAIL", NULL, MS_NA, 0);
        for (int i = 0; i < c->wd.ntail && y < LINES - 1; i++) mvaddstr(y++, 2, c->wd.tail[i]);
    }
}

void ms_curses_draw(const struct ms_view *v, int page)
{
    W = COLS;
    erase();
    if (COLS < 80 || LINES < 24) {
        mvprintw(0, 0, "modem_status: need a terminal of at least 80x24 (have %dx%d)", COLS, LINES);
        refresh();
        return;
    }
    if (page == 2) page2(v);
    else if (page == 3) page3(v);
    else page1(v);
    footer(v, page);
    refresh();
}
