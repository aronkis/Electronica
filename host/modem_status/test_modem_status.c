/* test_modem_status.c -- host-only unit tests for the modem_status TUI.
 * No board, no hardware: everything runs against ms_src_fake.
 * Build/run: make test_modem_status && ./test_modem_status */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "modem_status.h"
#include "ms_regmap.h"
#include "ms_collect.h"
#include "ms_delta.h"
#include "ms_health.h"
#include "ms_render.h"
#include "ms_src_fake.h"

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static struct ms_src_fake F;
static struct ms_src S;
static struct ms_cfg cfg;
static struct ms_collect_state st;
static struct ms_sample a, b;
static struct ms_delta dl;
static struct ms_health h;
static struct ms_view v;
static char out[65536];

static void setup(void)
{
    ms_src_fake_init(&F, &S);
    fk_populate_healthy(&F);
    memset(&cfg, 0, sizeof cfg);
    cfg.expected_fps = MS_DEFAULT_FPS; cfg.pause_path = MS_PAUSE_PATH_DEFAULT;
    strcpy(cfg.name, "148");
    ms_collect_image(&S, &cfg);
    memset(&st, 0, sizeof st);
}

/* two ticks 1 s apart at fps, view ready */
static void two_ticks(double fps)
{
    ms_collect(&S, &cfg, &st, &a);
    fk_tick(&F, 1000, fps);
    ms_collect(&S, &cfg, &st, &b);
    ms_delta_compute(&a, &b, &dl);
    ms_health_eval(&cfg, &b, &dl, &h);
    v.cfg = &cfg; v.cur = &b; v.dl = &dl; v.h = &h; v.tick = 1; v.since_reset_s = 1;
    strcpy(v.wall, "12:34:56");
}

static void t_regmap(void)
{
    static const uint16_t wo[] = { 0x004, 0x10C, 0x110, 0x114, 0x118, 0x138, 0x158, 0x170, 0x174,
                                   0x178, 0x17C, 0x180, 0x184, 0x1DC, 0x208 };
    static const uint16_t known[] = { 0x104, 0x108, 0x124, 0x128, 0x130, 0x144, 0x150, 0x154,
                                      0x1B0, 0x1C0, 0x1C4, 0x1C8, 0x1D8, 0x214, 0x218, 0x21C,
                                      0x230, 0x234, 0x238, 0x23C, 0x24C, 0x250, 0x254, 0x258 };
    int n = ms_nreg();
    CHECK(n > 40 && n <= MS_NREG_MAX);
    for (int i = 1; i < n; i++) CHECK(ms_regmap[i].off > ms_regmap[i - 1].off);
    for (size_t i = 0; i < sizeof wo / sizeof wo[0]; i++) {
        int k = ms_reg_index(wo[i]);
        CHECK(k >= 0 && (ms_regmap[k].flags & MS_F_WO) && !ms_reg_visible(&ms_regmap[k]));
    }
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++) {
        int k = ms_reg_index(known[i]);
        CHECK(k >= 0 && ms_reg_visible(&ms_regmap[k]));
    }
    CHECK(ms_regmap[ms_reg_index(0x15C)].flags & MS_F_ABSENT);
    CHECK(!ms_reg_visible(&ms_regmap[ms_reg_index(0x15C)]));
    CHECK(ms_reg_index(0x9D3) < 0);
    /* DMAC: exactly the 8 read-only words; SUBMIT/DEST/SRC never */
    for (int i = 0; i < MS_NDMAC; i++)
        CHECK(ms_dmac_offs[i] != 0x408 && ms_dmac_offs[i] != 0x410 && ms_dmac_offs[i] != 0x414);
    CHECK(ms_dmac_offs[1] == 0x084 && ms_dmac_offs[7] == 0x428);
    CHECK(sizeof(struct ms_dmac) == MS_NDMAC * 4);
}

static void t_decoders(void)
{
    struct ms_w1_wita wa; struct ms_w1_witb wb; struct ms_r4 r4; struct ms_fstat fs;
    struct ms_bs_marks bm; struct ms_bs_evt be; struct ms_bs_cnt bc;
    ms_dec_wita((32u << 10) | (7u << 5) | 3u, &wa);
    CHECK(wa.occ == 32 && wa.push_ptr == 7 && wa.pop_ptr == 3);
    ms_dec_witb(0x00050002u, &wb);
    CHECK(wb.push_on_full == 5 && wb.pop_on_empty == 2);
    ms_dec_r4(0x80000000u | (0x1234u << 15) | 0x0777u, &r4);
    CHECK(r4.locked == 1 && r4.skips == 0x1234 && r4.window_opens == 0x777);
    ms_dec_fstat(0x0003000Cu, &fs);
    CHECK(fs.overflow == 3 && fs.level == 12);
    ms_dec_bs_marks(0x00640065u, &bm);
    CHECK(bm.lasts == 100 && bm.markpush == 101);
    ms_dec_bs_evt(0x01020304u, &be);
    CHECK(be.trunc_last == 1 && be.trunc_min == 2 && be.trunc_max == 3 && be.dropmax == 4);
    ms_dec_bs_cnt(0x00070500u, &bc);
    CHECK(bc.trunc == 7 && bc.q24 == 5);
}

static void t_image_key(void)
{
    CHECK(ms_r4d_order("9acbe2ebe1db") == 1);
    CHECK(ms_r4d_order("9ACBE2EBE1DB") == 1);
    CHECK(ms_r4d_order("bf2a7305bbe0") == 0);
    CHECK(ms_r4d_order("") == -1 && ms_r4d_order(NULL) == -1);
    CHECK(ms_r4_witness_off(1) == 0x238 && ms_r4_extras_off(1) == 0x234);
    CHECK(ms_r4_witness_off(0) == 0x234 && ms_r4_extras_off(0) == 0x238);
    CHECK(ms_r4_witness_off(-1) == 0 && ms_r4_extras_off(-1) == 0);
    setup();
    CHECK(strcmp(cfg.image_md5, "bf2a7305bbe0") == 0 && cfg.r4d_swapped == 0);
    strcpy(F.md5, "9acbe2ebe1db"); ms_collect_image(&S, &cfg);
    CHECK(cfg.r4d_swapped == 1);
    F.md5_fail = 1; ms_collect_image(&S, &cfg);
    CHECK(cfg.image_md5[0] == 0 && cfg.r4d_swapped == -1);
    F.md5_fail = 0;
    /* unknown image renders raw words with img? marker, never a decoded field */
    two_ticks(1245);
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(strstr(out, "img?") != NULL);
    CHECK(strstr(out, "locked=") == NULL);
}

static void t_delta(void)
{
    struct ms_sample p, c; struct ms_delta d;
    int ip = ms_reg_index(0x104), id = ms_reg_index(0x130), ib = ms_reg_index(0x250),
        iw = ms_reg_index(0x21C);
    memset(&p, 0, sizeof p); memset(&c, 0, sizeof c);
    p.regs_valid = c.regs_valid = 1;
    p.t_ms = 1000; c.t_ms = 2000;
    p.reg[iw] = 0xFFFFFFF0u; c.reg[iw] = 0x10;          /* wrap */
    p.reg[id] = 0xFFFFFFF0u; c.reg[id] = 0xFFFFFFFFu;   /* saturated */
    p.reg[ip] = 5000; c.reg[ip] = 100;                  /* reset (cleared) */
    p.reg[ib] = 0xFFF0FFF0u; c.reg[ib] = 0x00100010u;   /* 16-bit halves */
    ms_delta_compute(&p, &c, &d);
    CHECK(d.valid && d.dt_s == 1.0);
    CHECK(d.d[iw] == 0x20);
    CHECK(d.sat[id] == 1);
    CHECK(d.reset[ip] == 1 && d.d[ip] == 100);
    CHECK(((d.d[ib] >> 16) & 0xFFFF) == 0x20 && (d.d[ib] & 0xFFFF) == 0x20);
    CHECK(d.ambig[ib] == 0);
    c.t_ms = 1000 + 27000;
    ms_delta_compute(&p, &c, &d);
    CHECK(d.ambig[ib] == 1);
    /* a real u32 wrap on 0x104 (prev near max) is NOT a reset */
    p.reg[ip] = 0xFFFFFFFEu; c.reg[ip] = 2; c.t_ms = 2000;
    ms_delta_compute(&p, &c, &d);
    CHECK(d.reset[ip] == 0 && d.d[ip] == 4);
    ms_delta_compute(NULL, &c, &d);
    CHECK(d.valid == 0);
}

static void t_stats_parser(void)
{
    uint64_t stv[MS_ST_N];
    char line[512]; int arq = 0;
    const char *l = "qpsk_tun stats: tunA_rx=49 tunA_tx=0 tunB_rx=0 tunB_tx=41 dma_tx=16149205 dma_rx_ok=41 crc_drop=13808 seq_gap=0 idle_tx=16149156 idle_rx=16135175 tun_drop=0 oversize=0 tx_stall=0 b_drop=0 retx=0 dups=0 recovered=0 naks_tx=0 naks_rx=0 arq_lost=0";
    CHECK(ms_parse_stats_line(l, stv) == 0);
    CHECK(stv[MS_ST_TUNA_RX] == 49 && stv[MS_ST_DMA_TX] == 16149205ull && stv[MS_ST_CRC_DROP] == 13808);
    CHECK(stv[MS_ST_IDLE_RX] == 16135175ull && stv[MS_ST_ARQ_LOST] == 0 && stv[MS_ST_TUNB_TX] == 41);
    CHECK(ms_parse_stats_line("qpsk_tun stats: tunA_rx=1", stv) == -1);
    CHECK(ms_find_last_stats("qpsk_tun: cross-link NAK ARQ ON\nqpsk_tun stats: A\nqpsk_tun stats: B\nqpsk_tun nakstat: seen=0\nqpsk_tun txgap: x\n", line, sizeof line, &arq) == 0);
    CHECK(strcmp(line, "qpsk_tun stats: B") == 0 && arq == 1);
    CHECK(ms_find_last_stats("nothing here\n", line, sizeof line, &arq) == -1 && arq == 0);
    /* truncated tail: partial first line must not confuse the scan */
    CHECK(ms_find_last_stats("ats: junk\nqpsk_tun stats: C", line, sizeof line, NULL) == 0);
    CHECK(strcmp(line, "qpsk_tun stats: C") == 0);
}

static void t_wd_parser(void)
{
    struct ms_watchdog wd; memset(&wd, 0, sizeof wd);
    ms_parse_wd_tail("[wd 14:58:01] LOCKED (drstcs=0 dpkts=6242 lvl=0)\n", &wd);
    CHECK(wd.have_verdict && wd.locked && wd.drstcs == 0 && wd.dpkts == 6242);
    CHECK(strcmp(wd.last_line, "LOCKED (drstcs=0 dpkts=6242 lvl=0)") == 0);
    ms_parse_wd_tail("[wd 1] LOCKED (drstcs=0 dpkts=6242 lvl=0)\n[wd 2] NOT-LOCKED #1/2 (drstcs=7 dpkts=3 lvl=0)\n[wd 3] FULL RE-ARM (x)\n[wd 4] FULL RE-ARM (y)\n[wd 5] BYTE-PLANE WEDGE (z)\n", &wd);
    CHECK(wd.have_verdict && !wd.locked && wd.fail_k == 1 && wd.fail_n == 2 && wd.drstcs == 7);
    CHECK(wd.rearms == 2 && wd.wedges == 1 && wd.ntail == 4);
    CHECK(strstr(wd.tail[3], "WEDGE") != NULL && strstr(wd.tail[0], "NOT-LOCKED") != NULL);
    ms_parse_wd_tail("ial line\n[wd 6] LOCKED (drstcs=0 dpkts=1 lvl=0)\n", &wd);   /* partial first line */
    CHECK(wd.have_verdict && wd.locked && wd.ntail == 1);
    ms_parse_wd_tail("", &wd);
    CHECK(!wd.have_verdict && wd.ntail == 0);
}

static void t_proc_scan(void)
{
    static const char sh[] = "sh\0-c\0./qpsk_tun -G -M 16";
    static const char arm[] = "sh\0-c\0cat /root/p.json > /sys/bus/iio/devices/iio:device2/profile_config";
    setup();
    two_ticks(1245);
    CHECK(b.d.pid == 834484 && strstr(b.d.cmdline, "qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5") != NULL);
    CHECK(b.wd.pid == 834869);
    CHECK(!b.paused);
    /* a shell whose argument mentions qpsk_tun is not the daemon */
    fk_del_file(&F, "/proc/834484/cmdline");
    fk_set_file_raw(&F, "/proc/999/cmdline", sh, sizeof sh);
    ms_collect(&S, &cfg, &st, &b);
    CHECK(b.d.pid == 0);
    /* an arm in flight pauses register reads */
    fk_set_file_raw(&F, "/proc/1000/cmdline", arm, sizeof arm);
    F.regs_read_calls = 0;
    ms_collect(&S, &cfg, &st, &b);
    CHECK(b.paused && F.regs_read_calls == 0 && strcmp(b.pause_reason, "arm in progress") == 0);
    CHECK(b.regs_valid == 0 && b.dmac_valid == 0);
}

static void t_iio(void)
{
    setup();
    two_ticks(1245);
    CHECK(b.r.found && strcmp(b.r.dev, "iio:device2") == 0);
    CHECK(b.r.rssi_db > 28.6 && b.r.rssi_db < 28.61);
    CHECK(b.r.rx_gain_db == 34.0 && b.r.tx_gain_db == -10.0 && b.r.fs_hz == 61440000);
    CHECK(strcmp(b.r.agc_mode, "automatic") == 0 && strcmp(b.r.rx_ensm, "rf_enabled") == 0);
    CHECK(b.r.temp_mc == INT_MIN);
    CHECK(b.r.load1 > 0.41 && b.r.uptime_s == 267240);
    /* radio on another index; mwipcore must not be picked */
    setup();
    fk_del_file(&F, MS_IIO_DIR "/iio:device2/name");
    fk_set_file(&F, MS_IIO_DIR "/iio:device3/name", "adrv9002-phy\n", 0);
    fk_set_file(&F, MS_IIO_DIR "/iio:device3/in_voltage0_rssi", "-42.3 dB\n", 0);
    ms_collect(&S, &cfg, &st, &b);
    CHECK(b.r.found && strcmp(b.r.dev, "iio:device3") == 0 && b.r.rssi_db == -42.3);
    /* no radio at all */
    setup();
    fk_del_file(&F, MS_IIO_DIR "/iio:device2/name");
    ms_collect(&S, &cfg, &st, &b);
    CHECK(b.r.found == 0);
    ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(h.radio == MS_BAD);
}

static void t_health(void)
{
    int ip = ms_reg_index(0x104);
    setup(); two_ticks(1245);
    CHECK(h.fps == MS_OK && h.storm == MS_OK && h.daemon == MS_OK && h.wd == MS_OK && h.radio == MS_OK);
    CHECK(h.byteplane == MS_OK && h.dmac_tx == MS_OK && h.dmac_rx == MS_OK);
    CHECK(h.overall == MS_OK && h.fps_meas > 1240 && h.fps_meas < 1250);
    CHECK(h.reg[ip] == MS_OK);
    /* storm: rstcs +25/s overrides a good fps */
    F.modem[0x150 / 4] += 25; fk_tick(&F, 1000, 1245);
    ms_collect(&S, &cfg, &st, &a); ms_delta_compute(&b, &a, &dl); ms_health_eval(&cfg, &a, &dl, &h);
    CHECK(h.storm == MS_BAD && h.fps == MS_BAD && h.overall == MS_BAD && strstr(h.summary, "STORM"));
    /* marginal fps, low rate */
    setup(); two_ticks(900);
    CHECK(h.fps == MS_WARN && h.overall == MS_WARN);
    setup(); two_ticks(0);
    CHECK(h.fps == MS_BAD && strstr(h.summary, "not decoding"));
    /* byte-plane wedge: frames advance, wordcnt frozen */
    setup(); ms_collect(&S, &cfg, &st, &a); fk_tick(&F, 1000, 1245); F.modem[0x1C0 / 4] = a.reg[ms_reg_index(0x1C0)];
    ms_collect(&S, &cfg, &st, &b); ms_delta_compute(&a, &b, &dl); ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(h.byteplane == MS_BAD && strstr(h.summary, "BYTE-PLANE"));
    /* --fps 212 accepts 200 f/s */
    setup(); cfg.expected_fps = 212; two_ticks(200);
    CHECK(h.fps == MS_OK);
    /* --bist: golden vs not */
    setup(); cfg.bist = 1; two_ticks(1245);
    CHECK(h.reg[ms_reg_index(0x144)] == MS_BAD);
    F.modem[0x144 / 4] = MS_GOLDEN_CAP_OUT; two_ticks(1245);
    CHECK(h.reg[ms_reg_index(0x144)] == MS_OK && h.reg[ms_reg_index(0x108)] == MS_OK);
    /* daemon down */
    setup(); fk_del_file(&F, "/proc/834484/cmdline"); two_ticks(1245);
    CHECK(h.daemon == MS_BAD && h.overall == MS_BAD && strstr(h.summary, "qpsk_tun not running"));
    /* crc window from a new stats line: 1000 ok, 5 bad -> 99.5 OK; 1000/100 -> WARN */
    setup(); ms_collect(&S, &cfg, &st, &a); fk_tick(&F, 1000, 1245);
    fk_set_file(&F, MS_DAEMON_LOG, "qpsk_tun stats: tunA_rx=49 tunA_tx=0 tunB_rx=0 tunB_tx=41 dma_tx=1 dma_rx_ok=41 crc_drop=13813 seq_gap=0 idle_tx=1 idle_rx=16136175 tun_drop=0 oversize=0 tx_stall=0 b_drop=0 retx=0 dups=0 recovered=0 naks_tx=0 naks_rx=0 arq_lost=0\n", F.wall_s);
    ms_collect(&S, &cfg, &st, &b); ms_delta_compute(&a, &b, &dl); ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(dl.stats_advanced && h.crc_pct > 99.49 && h.crc_pct < 99.51 && h.crc == MS_OK && h.delivery == MS_OK);
    fk_tick(&F, 1000, 1245);
    fk_set_file(&F, MS_DAEMON_LOG, "qpsk_tun stats: tunA_rx=49 tunA_tx=0 tunB_rx=0 tunB_tx=41 dma_tx=1 dma_rx_ok=41 crc_drop=13843 seq_gap=0 idle_tx=1 idle_rx=16137175 tun_drop=0 oversize=0 tx_stall=0 b_drop=0 retx=0 dups=0 recovered=0 naks_tx=0 naks_rx=0 arq_lost=0\n", F.wall_s);
    ms_collect(&S, &cfg, &st, &a); ms_delta_compute(&b, &a, &dl); ms_health_eval(&cfg, &a, &dl, &h);
    CHECK(h.crc == MS_WARN && h.crc_pct < 98 && h.crc_pct > 97);
    /* delivery wedge: stats advance but nothing received while frames decode */
    fk_tick(&F, 1000, 1245);
    fk_set_file(&F, MS_DAEMON_LOG, "qpsk_tun stats: tunA_rx=49 tunA_tx=0 tunB_rx=0 tunB_tx=41 dma_tx=2 dma_rx_ok=41 crc_drop=13843 seq_gap=0 idle_tx=2 idle_rx=16137175 tun_drop=0 oversize=0 tx_stall=0 b_drop=0 retx=0 dups=0 recovered=0 naks_tx=0 naks_rx=0 arq_lost=0\n", F.wall_s);
    ms_collect(&S, &cfg, &st, &b); ms_delta_compute(&a, &b, &dl); ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(h.delivery == MS_BAD && strstr(h.summary, "DELIVERY"));
    /* watchdog NOT-LOCKED */
    setup(); fk_append_file(&F, MS_WD_LOG, "[wd 14:58:13] NOT-LOCKED #1/2 (drstcs=0 dpkts=0 lvl=0)\n", F.wall_s);
    two_ticks(1245);
    CHECK(h.wd == MS_BAD && b.wd.fail_k == 1);
    /* DMAC disabled while daemon up */
    setup(); F.tx[0x400 / 4] = 0; two_ticks(1245);
    CHECK(h.dmac_tx == MS_BAD && strstr(h.summary, "DMAC"));
}

static void t_pause(void)
{
    setup();
    fk_set_file(&F, MS_PAUSE_PATH_DEFAULT, "", 0);
    F.regs_read_calls = 0;
    for (int i = 0; i < 3; i++) { ms_collect(&S, &cfg, &st, &b); fk_tick(&F, 1000, 1245); }
    CHECK(F.regs_read_calls == 0 && b.paused && strcmp(b.pause_reason, "flag file") == 0);
    CHECK(b.d.pid == 834484 && b.r.found);          /* file fields still live */
    fk_del_file(&F, MS_PAUSE_PATH_DEFAULT);
    ms_collect(&S, &cfg, &st, &b); CHECK(b.paused && strcmp(b.pause_reason, "resuming") == 0);
    ms_collect(&S, &cfg, &st, &b); CHECK(b.paused);
    ms_collect(&S, &cfg, &st, &b); CHECK(!b.paused && F.regs_read_calls == 3 && b.regs_valid);
    /* ensm not rf_enabled */
    setup(); fk_set_file(&F, MS_IIO_DIR "/iio:device2/in_voltage0_ensm_mode", "calibrated\n", 0);
    F.regs_read_calls = 0; ms_collect(&S, &cfg, &st, &b);
    CHECK(b.paused && F.regs_read_calls == 0 && strstr(b.pause_reason, "ensm"));
    ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(h.radio == MS_WARN);
    /* --no-regs */
    setup(); cfg.no_regs = 1; ms_collect(&S, &cfg, &st, &b);
    CHECK(b.paused && !b.regs_valid);
    /* key p */
    setup(); st.user_pause = 1; ms_collect(&S, &cfg, &st, &b);
    CHECK(b.paused && strcmp(b.pause_reason, "key p") == 0);
    /* regs bank unavailable -> regs_valid 0, no crash, rates n/a */
    setup(); F.regs_avail = 0; two_ticks(1245);
    CHECK(!b.regs_valid && !dl.valid && h.fps_meas < 0);
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(strstr(out, "paused") != NULL);
}

static const char golden_p1[] =
"modem_status 148 img bf2a7305bbe0 up 3d02:14 load 0.42 12:34:56      REGS:LIVE \n"
"MODEM RX  off  value         d/s  st | BYTE PLANE off value         d/s  st\n"
" packets   104   16156678    1245 OK   | wordcnt   1C0  439278896    238K OK\n"
" rstcs     150          4     0.0 OK   | stallcnt  1C4          0     0.0 --\n"
" biterr    108     258721     0.0 --   | txurcnt   1C8          2     0.0 --\n"
" cfc       154      -3301      -- --   | fifo_ovf  1B0          0     0.0 OK\n"
" descr_in  120   16156678    1245 --   | fstat     1D8 ovf=0 level=12\n"
" frstart   124   16156678    1245 --   | W1 occ=9 push=1 pop=0 pof=0 poe=0\n"
" vit_reset 128          0     0.0 --   | W1 ss12.33M rh+0 cfc+0 cs+0 pd+0 pc-622\n"
" dec_bits  130 4294967295     SAT --   | R4 234 L=1 skip=0 open+1245 can\n"
" cap_out   144 0xBCF94856  (byte) --   | BS lasts+1245 marks+1245 dropmax=0\n"
"DMAC TX en=1 id=14 done=35 irq=00 len=1528 | RX en=1 id=FC done=01 irq=00 len=32\n"
"RADIO iio:device2 rssi 28.6 dBFS decpow 0.0 rxgain 34.0 automatic txgain -10.0\n"
"      fs 61.44 MSPS  ensm rx=rf_enabled tx=rf_enabled\n"
"DAEMON pid 834484 up  stats 4s old  rx_ok 41  crc_drop 13808  crc --\n"
"       idle_rx 16135175 gap 0 stall 0 drop 0 arq ON rec 0 dup 0 lost 0\n"
"WD pid 834869 up  LOCKED (drstcs=0 dpkts=6242 lvl=0)  8s old  rearm 0 wedge 0\n"
"HEALTH  OK  decoding at rate, no reset storm  [1245 f/s, expect 1245]\n"
"\n"
"\n"
"\n"
"\n"
"\n"
" q quit  r rezero  p pause  1/2/3 page  [1]  t=1";

static void t_render(void)
{
    size_t n;
    char *col;
    setup(); two_ticks(1245);
    n = ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(n == strlen(out));
    if (strcmp(out, golden_p1) != 0) {
        fails++; fprintf(stderr, "FAIL page-1 golden mismatch; got:\n%s\n---\n", out);
    }
    /* every line <= 80 visible columns */
    {
        const char *p = out; int ok = 1;
        while (*p) { const char *e = strchr(p, '\n'); size_t l = e ? (size_t)(e - p) : strlen(p); if (l > 80) ok = 0; p = e ? e + 1 : p + l; }
        CHECK(ok);
    }
    /* colour output stripped == plain output */
    col = malloc(sizeof out);
    ms_render_tui(&v, col, sizeof out, 80, 24, 1, 1);
    CHECK(strstr(col, "\x1b[32m") != NULL && strncmp(col, "\x1b[H", 3) == 0);
    ms_strip_sgr(col);
    CHECK(strcmp(col, out) == 0);
    free(col);
    /* pages 2 and 3 render, fit, and carry the expected sections */
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 2);
    CHECK(strstr(out, "REGS 0x008-0x1D8") && strstr(out, " packets   104   16156678") && strstr(out, "[2]"));
    CHECK(strstr(out, " cap_out   144 0xBCF94856") != NULL);   /* snapshots stay hex */
    CHECK(strstr(out, "adc_foren") == NULL && strstr(out, "tx_data_s") == NULL);   /* hidden words */
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 3);
    CHECK(strstr(out, "w1_ss") && strstr(out, "DMAC TX irq_mask=1") && strstr(out, "idle_rx=16135175") && strstr(out, "WATCHDOG tail:"));
    /* tiny terminal */
    ms_render_tui(&v, out, sizeof out, 60, 24, 0, 1);
    CHECK(strstr(out, "need a terminal") != NULL);
    /* --once carries both pages */
    ms_render_once(&v, out, sizeof out);
    CHECK(strstr(out, "MODEM RX") && strstr(out, "INSTRUMENT WORDS") && strstr(out, "\x1b") == NULL);
    /* paused rendering */
    setup(); fk_set_file(&F, MS_PAUSE_PATH_DEFAULT, "", 0); two_ticks(1245);
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(strstr(out, "REGS:PAUSE") && strstr(out, "PAUSED: flag file") && strstr(out, "paused"));
}

static void t_json(void)
{
    int depth = 0, maxd = 0, instr = 0;
    setup(); two_ticks(1245);
    ms_render_json(&v, out, sizeof out);
    for (const char *p = out; *p; p++) {
        if (*p == '"' && (p == out || p[-1] != '\\')) instr = !instr;
        if (instr) continue;
        if (*p == '{') { depth++; if (depth > maxd) maxd = depth; }
        if (*p == '}') depth--;
    }
    CHECK(depth == 0 && maxd >= 3);
    CHECK(strstr(out, "\"packets\":{\"off\":260,\"val\":16156678,\"dps\":1245,\"level\":\"OK\"}"));
    CHECK(strstr(out, "\"image\":\"bf2a7305bbe0\"") && strstr(out, "\"overall\":\"OK\""));
    CHECK(strstr(out, "\"rssi_dbfs\":28.607") && strstr(out, "\"idle_rx\":16135175") && strstr(out, "\"locked\":1"));
    CHECK(strstr(out, "\"dec_bits\":{\"off\":304,\"val\":4294967295,\"dps\":null"));
    CHECK(strstr(out, "nan") == NULL && strstr(out, "inf") == NULL);
    CHECK(strstr(out, "\"transfer_done\":") != NULL);
}

static void t_age(void)
{
    setup(); ms_collect(&S, &cfg, &st, &a);
    fk_tick(&F, 46000, 1245);
    ms_collect(&S, &cfg, &st, &b); ms_delta_compute(&a, &b, &dl); ms_health_eval(&cfg, &b, &dl, &h);
    CHECK(b.d.log_age_s == 49 && h.daemon == MS_STALE && h.wd == MS_STALE && h.overall == MS_STALE);
    v.cfg = &cfg; v.cur = &b; v.dl = &dl; v.h = &h; v.tick = 1; strcpy(v.wall, "00:00:00");
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(strstr(out, "stats STALE 49s") != NULL && strstr(out, "stale") != NULL);
    /* missing logs */
    setup(); fk_del_file(&F, MS_DAEMON_LOG); fk_del_file(&F, MS_WD_LOG); two_ticks(1245);
    CHECK(b.d.log_age_s == -1 && !b.d.have_stats && h.daemon == MS_WARN && !b.wd.have_verdict);
    ms_render_tui(&v, out, sizeof out, 80, 24, 0, 1);
    CHECK(strstr(out, "no log") && strstr(out, "no stats line"));
}

int main(void)
{
    t_regmap(); t_decoders(); t_image_key(); t_delta(); t_stats_parser(); t_wd_parser();
    t_proc_scan(); t_iio(); t_health(); t_pause(); t_render(); t_json(); t_age();
    printf("test_modem_status: %d checks, %d failures\n", checks, fails);
    return fails ? 1 : 0;
}
