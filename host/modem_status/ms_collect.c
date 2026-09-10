/* ms_collect.c -- see ms_collect.h. All I/O goes through the ms_src vtable. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <ctype.h>
#include "ms_collect.h"
#include "ms_regmap.h"

/* ---------------------------------------------------------------- parsers */

double ms_parse_num(const char *s, double dflt)
{
    char *end; double v;
    if (!s) return dflt;
    while (*s && isspace((unsigned char)*s)) s++;
    v = strtod(s, &end);
    return end == s ? dflt : v;
}

int ms_parse_stats_line(const char *line, uint64_t st[MS_ST_N])
{
    const char *p = strstr(line, "stats:");
    int n = 0;
    if (!p) return -1;
    p += 6;
    for (int i = 0; i < MS_ST_N; i++) {
        size_t nl = strlen(ms_stat_names[i]);
        const char *q = p;
        int found = 0;
        while ((q = strstr(q, ms_stat_names[i])) != NULL) {
            if ((q == p || q[-1] == ' ') && q[nl] == '=') {
                st[i] = strtoull(q + nl + 1, NULL, 10);
                found = 1; n++;
                break;
            }
            q += nl;
        }
        if (!found) st[i] = 0;
    }
    return n == MS_ST_N ? 0 : -1;
}

/* Last line that begins "qpsk_tun stats:" wins; nakstat:/txgap:/rxqstat:
 * lines after it must not. Also notes the ARQ-ON banner. */
int ms_find_last_stats(const char *log, char *line, size_t cap, int *arq_on)
{
    const char *p = log, *best = NULL;
    if (arq_on) *arq_on = 0;
    while (p && *p) {
        const char *e = strchr(p, '\n');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len >= 15 && strncmp(p, "qpsk_tun stats:", 15) == 0) best = p;
        if (arq_on && strstr(p, "cross-link NAK ARQ ON") && (!e || strstr(p, "cross-link NAK ARQ ON") < e))
            *arq_on = 1;
        p = e ? e + 1 : NULL;
    }
    if (!best) { line[0] = 0; return -1; }
    {
        const char *e = strchr(best, '\n');
        size_t len = e ? (size_t)(e - best) : strlen(best);
        if (len >= cap) len = cap - 1;
        memcpy(line, best, len); line[len] = 0;
    }
    return 0;
}

static void copy_line(char *dst, size_t cap, const char *src, size_t len)
{
    if (len >= cap) len = cap - 1;
    memcpy(dst, src, len); dst[len] = 0;
}

void ms_parse_wd_tail(const char *tail, struct ms_watchdog *wd)
{
    const char *p = tail;
    wd->have_verdict = 0; wd->rearms = 0; wd->wedges = 0; wd->ntail = 0;
    wd->last_line[0] = 0;
    /* skip a partial first line (tail read may start mid-line) */
    if (p && *p) {
        const char *e = strchr(p, '\n');
        if (e && tail[0] != '[') p = e + 1;
    }
    while (p && *p) {
        const char *e = strchr(p, '\n');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        char l[160];
        copy_line(l, sizeof l, p, len);
        if (len) {
            const char *v;
            if (wd->ntail < 4) {
                copy_line(wd->tail[wd->ntail++], 96, l, strlen(l));
            } else {
                memmove(wd->tail[0], wd->tail[1], 3 * 96);
                copy_line(wd->tail[3], 96, l, strlen(l));
            }
            if (strstr(l, "FULL RE-ARM")) wd->rearms++;
            if (strstr(l, "-WEDGE") || strstr(l, " WEDGE")) wd->wedges++;
            if ((v = strstr(l, "NOT-LOCKED")) != NULL) {
                wd->have_verdict = 1; wd->locked = 0;
                wd->fail_k = wd->fail_n = 0;
                sscanf(v, "NOT-LOCKED #%d/%d", &wd->fail_k, &wd->fail_n);
                copy_line(wd->last_line, 96, v, strlen(v));
            } else if ((v = strstr(l, "LOCKED")) != NULL) {
                wd->have_verdict = 1; wd->locked = 1;
                copy_line(wd->last_line, 96, v, strlen(v));
            }
            if (v) {
                const char *q;
                if ((q = strstr(v, "drstcs="))) wd->drstcs = strtoll(q + 7, NULL, 10);
                if ((q = strstr(v, "dpkts=")))  wd->dpkts  = strtoll(q + 6, NULL, 10);
                if ((q = strstr(v, "lvl=")))    wd->lvl    = strtoll(q + 4, NULL, 10);
            }
        }
        p = e ? e + 1 : NULL;
    }
}

/* -------------------------------------------------------------- /proc scan */

struct proc_scan {
    const struct ms_src *s;
    struct ms_sample *out;
    int arm_marker;
};

static int proc_cb(const char *name, void *arg)
{
    struct proc_scan *ps = arg;
    char path[64], buf[512];
    int n;
    if (!isdigit((unsigned char)name[0])) return 0;
    snprintf(path, sizeof path, "/proc/%s/cmdline", name);
    n = ps->s->file_read(ps->s->ctx, path, buf, sizeof buf, 0);
    if (n <= 0) return 0;
    {
        /* argv0 basename */
        const char *a0 = buf, *slash = strrchr(buf, '/');
        char joined[512];
        int j = 0;
        if (slash) a0 = slash + 1;
        for (int i = 0; i < n && j < (int)sizeof joined - 1; i++)
            joined[j++] = buf[i] ? buf[i] : ' ';
        joined[j] = 0;
        if (strcmp(a0, "qpsk_tun") == 0 && ps->out->d.pid == 0) {
            ps->out->d.pid = atoi(name);
            copy_line(ps->out->d.cmdline, sizeof ps->out->d.cmdline, joined, strlen(joined));
        }
        if (strstr(joined, "lock_watchdog") && ps->out->wd.pid == 0 &&
            strcmp(a0, "modem_status") != 0)
            ps->out->wd.pid = atoi(name);
        if (strstr(joined, "profile_config") || strstr(joined, "stream_config"))
            ps->arm_marker = 1;
    }
    return 0;
}

/* -------------------------------------------------------------- radio */

struct iio_scan { const struct ms_src *s; char dev[24]; };

static int iio_cb(const char *name, void *arg)
{
    struct iio_scan *is = arg;
    char path[96], buf[64];
    if (strncmp(name, "iio:device", 10) != 0) return 0;
    snprintf(path, sizeof path, MS_IIO_DIR "/%s/name", name);
    if (is->s->file_read(is->s->ctx, path, buf, sizeof buf, 0) <= 0) return 0;
    buf[strcspn(buf, "\n")] = 0;
    if (strcmp(buf, MS_RADIO_NAME) == 0) {
        copy_line(is->dev, sizeof is->dev, name, strlen(name));
        return 1;
    }
    return 0;
}

static int rd_attr(const struct ms_src *s, const char *dev, const char *attr,
                   char *buf, size_t cap)
{
    char path[128];
    int n;
    snprintf(path, sizeof path, MS_IIO_DIR "/%s/%s", dev, attr);
    n = s->file_read(s->ctx, path, buf, cap, 0);
    if (n > 0) buf[strcspn(buf, "\n")] = 0;
    return n;
}

static void collect_radio(const struct ms_src *s, struct ms_collect_state *st,
                          struct ms_radio *r)
{
    char buf[96];
    r->found = 0; r->dev[0] = 0; r->temp_mc = INT_MIN;
    r->rssi_db = r->decpow_db = r->rx_gain_db = r->tx_gain_db = 0;
    r->agc_mode[0] = r->rx_ensm[0] = r->tx_ensm[0] = 0; r->fs_hz = 0;
    if (!st->radio_dev[0]) {
        struct iio_scan is; is.s = s; is.dev[0] = 0;
        s->dir_list(s->ctx, MS_IIO_DIR, iio_cb, &is);
        if (is.dev[0]) strcpy(st->radio_dev, is.dev);
    }
    if (st->radio_dev[0]) {
        const char *d = st->radio_dev;
        r->found = 1; strcpy(r->dev, d);
        if (rd_attr(s, d, "in_voltage0_rssi", buf, sizeof buf) > 0) r->rssi_db = ms_parse_num(buf, 0);
        if (rd_attr(s, d, "in_voltage0_decimated_power", buf, sizeof buf) > 0) r->decpow_db = ms_parse_num(buf, 0);
        if (rd_attr(s, d, "in_voltage0_hardwaregain", buf, sizeof buf) > 0) r->rx_gain_db = ms_parse_num(buf, 0);
        if (rd_attr(s, d, "out_voltage0_hardwaregain", buf, sizeof buf) > 0) r->tx_gain_db = ms_parse_num(buf, 0);
        if (rd_attr(s, d, "in_voltage0_sampling_frequency", buf, sizeof buf) > 0) r->fs_hz = (int64_t)ms_parse_num(buf, 0);
        if (rd_attr(s, d, "in_voltage0_gain_control_mode", buf, sizeof buf) > 0) copy_line(r->agc_mode, sizeof r->agc_mode, buf, strlen(buf));
        if (rd_attr(s, d, "in_voltage0_ensm_mode", buf, sizeof buf) > 0) copy_line(r->rx_ensm, sizeof r->rx_ensm, buf, strlen(buf));
        if (rd_attr(s, d, "out_voltage0_ensm_mode", buf, sizeof buf) > 0) copy_line(r->tx_ensm, sizeof r->tx_ensm, buf, strlen(buf));
    }
    if (s->file_read(s->ctx, "/sys/class/thermal/thermal_zone0/temp", buf, sizeof buf, 0) > 0)
        r->temp_mc = (int)ms_parse_num(buf, 0);
    r->load1 = s->file_read(s->ctx, "/proc/loadavg", buf, sizeof buf, 0) > 0 ? ms_parse_num(buf, 0) : 0;
    r->uptime_s = s->file_read(s->ctx, "/proc/uptime", buf, sizeof buf, 0) > 0 ? (int64_t)ms_parse_num(buf, 0) : 0;
}

/* -------------------------------------------------------------- files */

static uint32_t fnv1a(const char *s)
{
    uint32_t h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h;
}

static int64_t file_age(const struct ms_src *s, const char *path, int64_t now_s)
{
    int64_t m;
    if (s->file_mtime(s->ctx, path, &m) != 0) return -1;
    return now_s - m < 0 ? 0 : now_s - m;
}

static void collect_daemon(const struct ms_src *s, struct ms_daemon *d, int64_t now_s)
{
    static char tail[MS_TAIL_CAP];
    char line[1024];
    d->have_stats = 0; d->arq_on = 0; d->stats_hash = 0;
    memset(d->st, 0, sizeof d->st);
    d->log_age_s = file_age(s, MS_DAEMON_LOG, now_s);
    if (s->file_read(s->ctx, MS_DAEMON_LOG, tail, sizeof tail, 1) <= 0) return;
    if (ms_find_last_stats(tail, line, sizeof line, &d->arq_on) == 0 &&
        ms_parse_stats_line(line, d->st) == 0) {
        d->have_stats = 1;
        d->stats_hash = fnv1a(line);
    }
}

static void collect_watchdog(const struct ms_src *s, struct ms_watchdog *wd, int64_t now_s)
{
    static char tail[MS_TAIL_CAP];
    wd->log_age_s = file_age(s, MS_WD_LOG, now_s);
    if (s->file_read(s->ctx, MS_WD_LOG, tail, sizeof tail, 1) <= 0) {
        wd->have_verdict = 0; wd->ntail = 0; wd->last_line[0] = 0;
        return;
    }
    ms_parse_wd_tail(tail, wd);
}

/* -------------------------------------------------------------- image */

void ms_collect_image(const struct ms_src *s, struct ms_cfg *cfg)
{
    cfg->image_md5[0] = 0;
    if (s->image_md5 && s->image_md5(s->ctx, cfg->image_md5, sizeof cfg->image_md5) != 0)
        cfg->image_md5[0] = 0;
    cfg->r4d_swapped = ms_r4d_order(cfg->image_md5);
}

/* -------------------------------------------------------------- tick */

void ms_collect(const struct ms_src *s, const struct ms_cfg *cfg,
                struct ms_collect_state *st, struct ms_sample *out)
{
    struct proc_scan ps;
    const char *reason = NULL;

    memset(out, 0, sizeof *out);
    out->t_ms = s->now_ms(s->ctx);
    out->wall_s = s->now_wall_s(s->ctx);

    /* file-sourced first: they also feed the pause decision */
    ps.s = s; ps.out = out; ps.arm_marker = 0;
    s->dir_list(s->ctx, "/proc", proc_cb, &ps);
    collect_daemon(s, &out->d, out->wall_s);
    collect_watchdog(s, &out->wd, out->wall_s);
    collect_radio(s, st, &out->r);

    /* pause policy (contract item 4) */
    if (cfg->no_regs) reason = "--no-regs";
    else if (st->user_pause) reason = "key p";
    else if (s->file_exists(s->ctx, cfg->pause_path)) reason = "flag file";
    else if (ps.arm_marker) reason = "arm in progress";
    else if (out->r.found && ((out->r.rx_ensm[0] && strcmp(out->r.rx_ensm, "rf_enabled") != 0) ||
                              (out->r.tx_ensm[0] && strcmp(out->r.tx_ensm, "rf_enabled") != 0)))
        reason = "ensm not rf_enabled";

    if (reason) {
        st->clear_ticks = 0;
        if (!st->paused) { st->paused = 1; st->paused_since_ms = out->t_ms; }
    } else if (st->paused) {
        if (++st->clear_ticks >= MS_RESUME_TICKS) st->paused = 0;
        else reason = "resuming";
    }
    out->paused = st->paused;
    out->paused_since_ms = st->paused_since_ms;
    if (reason) copy_line(out->pause_reason, sizeof out->pause_reason, reason, strlen(reason));

    if (!st->paused) {
        uint16_t offs[MS_NREG_MAX];
        int n = ms_nreg(), rc;
        for (int i = 0; i < n; i++) offs[i] = ms_regmap[i].off;
        rc = s->regs_read(s->ctx, MS_BANK_MODEM, offs, n, out->reg);
        out->regs_valid = rc == 0;
        rc  = s->regs_read(s->ctx, MS_BANK_TXDMAC, ms_dmac_offs, MS_NDMAC, (uint32_t *)&out->tx);
        rc |= s->regs_read(s->ctx, MS_BANK_RXDMAC, ms_dmac_offs, MS_NDMAC, (uint32_t *)&out->rx);
        out->dmac_valid = rc == 0;
    }
}
