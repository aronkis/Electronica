#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ms_src_fake.h"

static struct fk_file *fk_find(struct ms_src_fake *f, const char *path)
{
    for (int i = 0; i < f->nfiles; i++)
        if (strcmp(f->files[i].path, path) == 0) return &f->files[i];
    return NULL;
}

void fk_set_file(struct ms_src_fake *f, const char *path, const char *data, int64_t mtime)
{
    struct fk_file *e = fk_find(f, path);
    if (!e) {
        if (f->nfiles >= FK_MAX_FILES) { fprintf(stderr, "fake: too many files\n"); abort(); }
        e = &f->files[f->nfiles++];
        snprintf(e->path, sizeof e->path, "%s", path);
        e->data = NULL;
    }
    free(e->data);
    e->len = strlen(data);
    e->data = malloc(e->len + 1);
    memcpy(e->data, data, e->len + 1);
    e->mtime = mtime;
}

void fk_set_file_raw(struct ms_src_fake *f, const char *path, const char *data, size_t len)
{
    struct fk_file *e;
    fk_set_file(f, path, "", 0);
    e = fk_find(f, path);
    free(e->data);
    e->data = malloc(len + 1);
    memcpy(e->data, data, len); e->data[len] = 0;
    e->len = len;
}

void fk_append_file(struct ms_src_fake *f, const char *path, const char *data, int64_t mtime)
{
    struct fk_file *e = fk_find(f, path);
    if (!e) { fk_set_file(f, path, data, mtime); return; }
    e->data = realloc(e->data, e->len + strlen(data) + 1);
    memcpy(e->data + e->len, data, strlen(data) + 1);
    e->len += strlen(data);
    e->mtime = mtime;
}

void fk_del_file(struct ms_src_fake *f, const char *path)
{
    struct fk_file *e = fk_find(f, path);
    if (!e) return;
    free(e->data);
    *e = f->files[--f->nfiles];
}

static int fk_regs_read(void *ctx, int bank, const uint16_t *offs, int n, uint32_t *out)
{
    struct ms_src_fake *f = ctx;
    const uint32_t *b = bank == 0 ? f->modem : bank == 1 ? f->tx : f->rx;
    f->regs_read_calls++;
    if (!f->regs_avail) return -1;
    for (int i = 0; i < n; i++) out[i] = b[offs[i] / 4];
    return 0;
}

static int fk_file_read(void *ctx, const char *path, char *buf, size_t cap, int tail)
{
    struct fk_file *e = fk_find(ctx, path);
    size_t n, from = 0;
    if (!e) return -1;
    n = e->len;
    if (n > cap - 1) { if (tail) from = n - (cap - 1); n = cap - 1; }
    memcpy(buf, e->data + from, n); buf[n] = 0;
    return (int)n;
}

static int fk_file_mtime(void *ctx, const char *path, int64_t *m)
{
    struct fk_file *e = fk_find(ctx, path);
    if (!e) return -1;
    *m = e->mtime; return 0;
}

static int fk_file_exists(void *ctx, const char *path)
{
    return fk_find(ctx, path) != NULL;
}

static int fk_dir_list(void *ctx, const char *path, int (*cb)(const char *, void *), void *arg)
{
    struct ms_src_fake *f = ctx;
    char seen[FK_MAX_FILES][64];
    int nseen = 0, any = 0;
    size_t pl = strlen(path);
    for (int i = 0; i < f->nfiles; i++) {
        const char *p = f->files[i].path, *rest, *slash;
        char name[64];
        if (strncmp(p, path, pl) != 0 || p[pl] != '/') continue;
        any = 1;
        rest = p + pl + 1;
        slash = strchr(rest, '/');
        snprintf(name, sizeof name, "%.*s", (int)(slash ? slash - rest : (long)strlen(rest)), rest);
        {
            int dup = 0;
            for (int k = 0; k < nseen; k++) if (strcmp(seen[k], name) == 0) dup = 1;
            if (dup) continue;
            snprintf(seen[nseen++], 64, "%s", name);
        }
        if (cb(name, arg)) break;
    }
    return any ? 0 : -1;
}

static int fk_image_md5(void *ctx, char *out, size_t cap)
{
    struct ms_src_fake *f = ctx;
    if (f->md5_fail) return -1;
    snprintf(out, cap, "%s", f->md5);
    return 0;
}

static int64_t fk_now_ms(void *ctx) { return ((struct ms_src_fake *)ctx)->now_ms; }
static int64_t fk_now_wall_s(void *ctx) { return ((struct ms_src_fake *)ctx)->wall_s; }

void ms_src_fake_init(struct ms_src_fake *f, struct ms_src *s)
{
    memset(f, 0, sizeof *f);
    f->regs_avail = 1;
    f->now_ms = 100000; f->wall_s = 1757430000;   /* 2026-09-09 */
    strcpy(f->md5, "bf2a7305bbe0");
    s->ctx = f;
    s->regs_read = fk_regs_read; s->file_read = fk_file_read;
    s->file_mtime = fk_file_mtime; s->file_exists = fk_file_exists;
    s->dir_list = fk_dir_list; s->image_md5 = fk_image_md5;
    s->now_ms = fk_now_ms; s->now_wall_s = fk_now_wall_s;
}

#define R(off) f->modem[(off) / 4]

void fk_populate_healthy(struct ms_src_fake *f)
{
    R(0x008) = 0x20260909; R(0x100) = 1000; R(0x104) = 16155433; R(0x108) = 0x3F2A1;
    R(0x120) = 16155433; R(0x124) = 16155433; R(0x128) = 0; R(0x12C) = 16155433;
    R(0x130) = 0xFFFFFFFFu; R(0x134) = 16155433; R(0x13C) = 0x11; R(0x140) = 0x22;
    R(0x144) = 0xBCF94856; R(0x14C) = 0x33; R(0x150) = 4; R(0x154) = 0xFFFFF31B;
    R(0x1B0) = 0; R(0x1C0) = 0x1A2B3C4D; R(0x1C4) = 0; R(0x1C8) = 2;
    R(0x1D0) = 0x1234; R(0x1D4) = 0x5678; R(0x1D8) = 0x0000000C;
    R(0x214) = (9u << 10) | (1u << 5) | 0u; R(0x218) = 0;
    R(0x21C) = R(0x220) = R(0x224) = R(0x228) = R(0x22C) = 4000000; R(0x230) = 3990000;
    R(0x234) = 0x80000000u | (0u << 15) | 100u; R(0x238) = 0x800C0000u;
    R(0x23C) = 500000; R(0x240) = 16155433; R(0x244) = 500000; R(0x248) = 500000;
    R(0x24C) = 0; R(0x250) = (100u << 16) | 100u; R(0x254) = 0; R(0x258) = 0;
    f->tx[0x80 / 4] = 1; f->tx[0x84 / 4] = 0; f->tx[0x400 / 4] = 1; f->tx[0x404 / 4] = 0x37;
    f->tx[0x40C / 4] = 2; f->tx[0x418 / 4] = 1527; f->tx[0x428 / 4] = 0x25;
    f->rx[0x80 / 4] = 1; f->rx[0x400 / 4] = 1; f->rx[0x404 / 4] = 0x1F; f->rx[0x418 / 4] = 32767;
    f->rx[0x428 / 4] = 0x11;

    {
        static const char d[] = "./qpsk_tun\0-G\0-M\0" "16\0-r\0" "15360\0-i\0tun0\0-s\0" "5";
        fk_set_file_raw(f, "/proc/834484/cmdline", d, sizeof d);
    }
    {
        static const char w[] = "/bin/sh\0/root/lock_watchdog.sh";
        fk_set_file_raw(f, "/proc/834869/cmdline", w, sizeof w);
    }
    fk_set_file(f, "/proc/1/cmdline", "/sbin/init", 0);
    fk_set_file(f, "/proc/loadavg", "0.42 0.38 0.35 1/319 954084\n", 0);
    fk_set_file(f, "/proc/uptime", "267240.12 1000.0\n", 0);
    fk_set_file(f, MS_DAEMON_LOG,
        "qpsk_tun: cross-link NAK ARQ ON\n"
        "qpsk_tun stats: tunA_rx=49 tunA_tx=0 tunB_rx=0 tunB_tx=41 dma_tx=16149205 dma_rx_ok=41 crc_drop=13808 seq_gap=0 idle_tx=16149156 idle_rx=16135175 tun_drop=0 oversize=0 tx_stall=0 b_drop=0 retx=0 dups=0 recovered=0 naks_tx=0 naks_rx=0 arq_lost=0\n"
        "qpsk_tun nakstat: seen=0 magic=0 parsed=0\n", f->wall_s - 3);
    fk_set_file(f, MS_WD_LOG,
        "[wd] === STARTING 14:57:01 pid=834869 ===\n"
        "[wd 14:57:56] LOCKED (drstcs=0 dpkts=6244 lvl=0)\n"
        "[wd 14:58:01] LOCKED (drstcs=0 dpkts=6244 lvl=0)\n"
        "[wd 14:58:08] LOCKED (drstcs=0 dpkts=6242 lvl=0)\n", f->wall_s - 7);
    fk_set_file(f, MS_IIO_DIR "/iio:device0/name", "mwipcore0:mwipcore_regs\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/name", "adrv9002-phy\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_rssi", "28.607 dB\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_decimated_power", "0.00 dB\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_hardwaregain", "34.000000 dB\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/out_voltage0_hardwaregain", "-10.000000 dB\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_gain_control_mode", "automatic\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_sampling_frequency", "61440000\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/in_voltage0_ensm_mode", "rf_enabled\n", 0);
    fk_set_file(f, MS_IIO_DIR "/iio:device2/out_voltage0_ensm_mode", "rf_enabled\n", 0);
}

void fk_tick(struct ms_src_fake *f, int64_t dt_ms, double fps)
{
    uint32_t df = (uint32_t)(fps * (double)dt_ms / 1000.0);
    f->now_ms += dt_ms; f->wall_s += dt_ms / 1000;
    R(0x104) += df; R(0x120) += df; R(0x124) += df; R(0x12C) += df; R(0x134) += df;
    R(0x240) += df; R(0x1C0) += df * 191; R(0x23C) += df * 191; R(0x244) += df * 191; R(0x248) += df * 191;
    R(0x21C) += df * 9905; R(0x220) += df * 9905; R(0x224) += df * 9905; R(0x228) += df * 9905;
    R(0x22C) += df * 9905; R(0x230) += df * 9900;
    R(0x234) = (R(0x234) & 0xFFFF8000u) | ((R(0x234) + df) & 0x7FFF);
    R(0x250) = (uint32_t)(((R(0x250) >> 16) + df) << 16) | (uint16_t)((R(0x250) & 0xFFFF) + df);
    f->tx[0x404 / 4] += df; f->tx[0x428 / 4] ^= 0x10; f->rx[0x404 / 4] += df; f->rx[0x428 / 4] ^= 0x10;
}
