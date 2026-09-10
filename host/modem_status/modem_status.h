/* modem_status.h -- shared types for the on-board modem link status TUI.
 *
 * modem_status is a jesd_status-style full-screen readout of the QPSK modem
 * data link: modem RX-pipeline counters, byte plane / census words, the two
 * axi_dmac engines, the ADRV9002 radio, and the qpsk_tun daemon + lock
 * watchdog state, refreshed once per second with health colouring.
 *
 * SAFETY CONTRACT (the whole design, not a footnote):
 *   1. It NEVER writes a register. /dev/mem is opened O_RDONLY and every
 *      mapping is PROT_READ. No soft reset, no re-arm, no CS pulse, ever.
 *   2. It NEVER touches /sys/kernel/debug/iio/.../direct_reg_access. That
 *      interface is a single address latch shared by every reader and
 *      concurrent readers corrupt each other (modem_status.sh, dra_guard.sh,
 *      both tag archive/pre-cleanup-2026-09-09). Status words are read off
 *      the mmap'd modem BAR exactly as stage_poll.c does (same tag), which
 *      touches no latch.
 *   3. It polls at a FIXED 1 s (MS_TICK_MS is compile-time, not a flag). A
 *      0.25 s register poll hung a board on 2026-09-01; every hang-free run
 *      polled at 1 s (RIG_NOPING_FAULT.md, tag archive/pre-cleanup-2026-09-09).
 *   4. Register reads PAUSE while an ADRV9002 arm may be in flight: a pause
 *      flag file, a /proc cmdline carrying profile_config/stream_config, or
 *      an ENSM mode other than rf_enabled. File-sourced fields keep going.
 *      Residual risk: an arm that starts between two ticks can still race one
 *      batched read (window <= 1 s). Do not run this during a scripted
 *      bring-up; the bring-up can `touch /dev/shm/modem_status.pause` first.
 */
#ifndef MODEM_STATUS_H
#define MODEM_STATUS_H

#include <stdint.h>
#include <stddef.h>
#include "qpsk_hw.h"

#define MS_TICK_MS            1000      /* fixed; see contract item 3 */
#define MS_MAP_LEN            0x1000u
#define MS_PAUSE_PATH_DEFAULT "/dev/shm/modem_status.pause"
#define MS_DAEMON_LOG         "/dev/shm/qpsk_tun.log"
#define MS_WD_LOG             "/dev/shm/watchdog.log"
#define MS_BOOT_BIN           "/boot/BOOT.BIN"
#define MS_IIO_DIR            "/sys/bus/iio/devices"
#define MS_RADIO_NAME         "adrv9002-phy"
#define MS_R4D_SWAPPED_MD5    "9acbe2ebe1db"   /* W1_REGMAP.md sec 6-R4D.2 */
#define MS_GOLDEN_CAP_OUT     0x04922282u
#define MS_AMBIG_DT_S         26.0    /* 15/16-bit packed fields wrap horizon */
#define MS_RESUME_TICKS       3       /* clear ticks before regs resume */
#define MS_DEFAULT_FPS        1245.0  /* r3 profile frame rate, BRINGUP.md */
#define MS_STALE_S            30
#define MS_DAEMON_CADENCE_S   5       /* qpsk_tun -s 5 */
#define MS_WD_CADENCE_S       5
#define MS_TAIL_CAP           65536

enum ms_bank { MS_BANK_MODEM = 0, MS_BANK_TXDMAC = 1, MS_BANK_RXDMAC = 2 };

enum ms_regflag {
    MS_F_WO     = 1 << 0,  /* write-only: reads const 0, never displayed     */
    MS_F_WRAP32 = 1 << 1,  /* free-running u32 counter: show delta/s          */
    MS_F_SAT32  = 1 << 2,  /* saturates at 0xFFFFFFFF (0x130)                 */
    MS_F_RESET  = 1 << 3,  /* cleared by watchdog re-arm / 0x000 (0x104,0x1C0)*/
    MS_F_PACKED = 1 << 4,  /* bitfield word: decode via ms_regmap_decode      */
    MS_F_IMGKEY = 1 << 5,  /* meaning depends on image md5 (0x234/0x238)      */
    MS_F_SNAP   = 1 << 6,  /* snapshot value, no delta (cfc, cap_*)           */
    MS_F_ABSENT = 1 << 7,  /* const 0 on current images (0x15C): hidden       */
    MS_F_BIST   = 1 << 8,  /* only meaningful in ROM/BIST mode                */
    MS_F_OPT    = 1 << 9,  /* present only on some image lineages             */
};

enum ms_section { MS_SEC_RXPIPE, MS_SEC_CAP, MS_SEC_BYTE, MS_SEC_W1, MS_SEC_BS,
                  MS_SEC_MISC, MS_SEC_N };

struct ms_regdef {
    uint16_t    off;
    const char *name;
    uint8_t     sec;
    uint16_t    flags;
    const char *desc;
};

#define MS_NREG_MAX 96

struct ms_dmac {
    uint32_t irq_mask, irq_pending, irq_source, control, transfer_id,
             flags, x_length, transfer_done;
};
#define MS_NDMAC 8

/* order == the qpsk_tun stats line (qpsk_tun.c stats_dump) */
enum ms_statf {
    MS_ST_TUNA_RX, MS_ST_TUNA_TX, MS_ST_TUNB_RX, MS_ST_TUNB_TX,
    MS_ST_DMA_TX, MS_ST_DMA_RX_OK, MS_ST_CRC_DROP, MS_ST_SEQ_GAP,
    MS_ST_IDLE_TX, MS_ST_IDLE_RX, MS_ST_TUN_DROP, MS_ST_OVERSIZE,
    MS_ST_TX_STALL, MS_ST_B_DROP, MS_ST_RETX, MS_ST_DUPS, MS_ST_RECOVERED,
    MS_ST_NAKS_TX, MS_ST_NAKS_RX, MS_ST_ARQ_LOST, MS_ST_N
};
extern const char *const ms_stat_names[MS_ST_N];

struct ms_daemon {
    int      pid;               /* 0 = not running */
    char     cmdline[96];
    int      have_stats;
    uint64_t st[MS_ST_N];
    int      arq_on;
    int64_t  log_age_s;         /* -1 = no log */
    uint32_t stats_hash;        /* changes when a new stats line appears */
};

struct ms_watchdog {
    int     pid;
    int     have_verdict;
    int     locked;             /* 1 LOCKED, 0 NOT-LOCKED */
    int     fail_k, fail_n;     /* NOT-LOCKED #k/N */
    int64_t drstcs, dpkts, lvl;
    int     rearms, wedges;     /* counted over the tail window */
    int64_t log_age_s;          /* -1 = no log */
    char    last_line[96];
    char    tail[4][96];        /* last 4 log lines, oldest first */
    int     ntail;
};

struct ms_radio {
    int     found;
    char    dev[24];            /* "iio:device2" */
    double  rssi_db, decpow_db, rx_gain_db, tx_gain_db;
    char    agc_mode[24];
    char    rx_ensm[24], tx_ensm[24];
    int64_t fs_hz;
    int     temp_mc;            /* INT32_MIN = n/a */
    double  load1;
    int64_t uptime_s;
};

struct ms_sample {
    int64_t  t_ms;                       /* monotonic */
    int64_t  wall_s;
    uint32_t reg[MS_NREG_MAX];
    int      regs_valid;                 /* 0 = not read this tick */
    struct ms_dmac tx, rx;
    int      dmac_valid;
    struct ms_daemon   d;
    struct ms_watchdog wd;
    struct ms_radio    r;
    int      paused;
    char     pause_reason[40];
    int64_t  paused_since_ms;
};

struct ms_delta {
    int      valid;                      /* both samples had regs */
    double   dt_s;
    int64_t  d[MS_NREG_MAX];
    uint8_t  reset[MS_NREG_MAX], sat[MS_NREG_MAX], ambig[MS_NREG_MAX];
    int      stats_advanced;             /* new stats line since prev */
    double   stats_dt_s;
    int64_t  dst[MS_ST_N];
    int      dmac_valid;
    int      tx_progress, rx_progress;   /* transfer_id/done changed */
};

struct ms_cfg {
    double      expected_fps;
    int         bist;
    const char *pause_path;
    int         no_regs;
    char        image_md5[16];          /* 12 hex chars or "" */
    int         r4d_swapped;            /* -1 unknown, 0 canonical, 1 swapped */
    char        name[32];               /* board label in the header */
};

enum ms_level { MS_NA = 0, MS_OK = 1, MS_WARN = 2, MS_BAD = 3, MS_STALE = 4 };

struct ms_health {
    enum ms_level reg[MS_NREG_MAX];
    enum ms_level fps, storm, crc, byteplane, delivery, daemon, wd, radio,
                  dmac_tx, dmac_rx, overall;
    double fps_meas;            /* -1 = n/a */
    double crc_pct;             /* -1 = n/a */
    char   summary[80];
};

struct ms_view {
    const struct ms_cfg    *cfg;
    const struct ms_sample *cur;
    const struct ms_delta  *dl;
    const struct ms_health *h;
    int64_t tick;
    int64_t since_reset_s;
    char    wall[9];            /* HH:MM:SS */
};

#endif /* MODEM_STATUS_H */
