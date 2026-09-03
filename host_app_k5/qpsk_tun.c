/* qpsk_tun -- bridge TUN/TAP interfaces to the QPSK byte DMA modem.
 *
 * Runs on the jupiter_sdr ARM. Two deployment shapes:
 *
 *   Single-board (legacy, two -i): packets read from the A-side interface
 *   are framed (qpsk_frame) and pushed into the Tx byte DMA; the modem
 *   carries them over RF; recovered packets from the Rx byte DMA are
 *   validated and written to the B-side interface. The reverse direction
 *   is routed over a second loopback-mode instance by qpsk_net_setup.sh;
 *   B-side reads are counted and dropped in DMA mode.
 *
 *   Two-radio (one -i, one daemon per board): the single tun fd carries
 *   BOTH directions -- reads go to the Tx DMA, Rx DMA deliveries are
 *   written back to the same fd. The peer daemon on the other board is
 *   the other end of the link. Use -F for the K5 (240k/K5) frame
 *   geometry: 128-byte payload units (16 x 64-bit words) per radio frame,
 *   per-transfer TLAST; the fabric encoder expands each unit to 2240 air
 *   bits internally, one radio frame = 1133 symbols / 240 ksym = 4.72 ms
 *   (~212 frames/s). -F also disables the in-process ARQ by default (it
 *   is single-process by design and meaningless across two radios; -A
 *   forces it back on) and arms an idle-frame keepalive: if the tun is
 *   quiet for >1 frame period, a len=0 qpsk_frame (valid CRC) is pushed,
 *   rate-limited to the frame rate, so the fabric encoder/modulator
 *   cadence never starves (the historical underfill -> CW-tone class).
 *
 * DMA register sequences follow ByteDmaRegisters.m (the proven recipes):
 * engine reset = CONTROL 0 then 1 before use; Tx one-shots use FLAGS=2
 * (TLAST only -- the in-FPGA word aligner needs per-transfer tlast). The
 * modem register file at 0x9D000000 is owned by the bring-up script
 * (qpsk_net_setup.sh single-board; two_jup/byte_link_up.sh two-radio K5 --
 * NOTE the K5 image moves tx_data_source to QPSK_TX_DATA_SOURCE_OFF 0x158
 * and Jupiter modem writes must go via mwipcore direct_reg_access, not
 * devmem).
 *
 * Rx capture has two modes (HW constraints measured on silicon: the S2MM
 * engine never chains a second transfer without an engine reset, and an
 * incoming TLAST terminates a transfer early):
 *   legacy (default): per-packet TLAST is on (byte_ctrl_gpio=1), so each
 *     transfer captures exactly one packet; the loop spins to make the
 *     ~18 us rearm window between packets. One core pegged.
 *   multi (-M K, byte-DMA bitstreams with byte_ctrl_gpio @0x9D300000):
 *     TLAST is gated off, one transfer spans K packets (SYNC_TRANSFER_
 *     START still aligns the start). Frames are consumed eagerly as their
 *     CRCs validate in the landing buffer; the loop sleeps except for the
 *     last-packet window, dropping CPU from 100% to a few %.
 *
 * Modes:
 *   default      DMA bridge; two -i = single-board A->B, one -i = two-radio
 *   -F           two-radio K5 frame geometry (pkt 128 B, keepalive, no ARQ)
 *   -G           two-radio F1536 large-frame geometry (pkt 1528 B / TX xfer
 *                3080 B, same keepalive/no-ARQ defaults as -F; needs the 2 MB
 *                carve, -DQPSK_CARVE_2MB); also QPSK_FRAME=f1536 env
 *   -l           loopback: A<->B in-process through encode/decode (no DMA)
 *   -e           echo: no tun; generate/check frames over the DMA path
 */
#define _GNU_SOURCE     /* ppoll (sub-ms pacing wakeups, HOSTPERF) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <net/if.h>
#include <linux/if_tun.h>
#include "qpsk_frame.h"
#include "qpsk_ber.h"    /* full-packet BER scorer (-B mode / -T self-test) */
#include "qpsk_seq.h"    /* loss-proof sequence-streaming scorer (-S mode) */
#include "qpsk_uio.h"    /* UIO /sys scan + fd ops for the IRQ event loop */

#include "qpsk_hw.h"     /* board-configurable base addresses (-DQPSK_BOARD_ZED) */
#define TX_DMA_BASE  QPSK_TX_DMA_BASE
#define RX_DMA_BASE  QPSK_RX_DMA_BASE
#define GPIO_BASE    QPSK_GPIO_BASE
#define TX_BUF_PHYS  QPSK_TX_BUF_PHYS
#define RX_BUF_PHYS  QPSK_TUN_RX_BUF_PHYS
/* Slot/carve geometry lives in qpsk_hw.h so the buffer layout is derived in one
 * place. DEFAULT build (no -DQPSK_CARVE_2MB) resolves SLOT_BYTES to 1024 and
 * TX_BATCH_STRIDE to 4096 -- today's values, byte-for-byte on the deployed
 * image. -DQPSK_CARVE_2MB bundles the 2 MB / 2048 / 16 KB new-image geometry. */
#define SLOT_BYTES   QPSK_SLOT_BYTES        /* >= QPSK_PKT_BYTES_MAX */
#define TX_SLOTS     QPSK_TX_SLOTS
/* Keep RX_MULTI_MAX a signed int literal (as it always was) so the existing
 * signed comparisons below stay warning-clean under -Wextra -Werror; it must
 * equal QPSK_RX_MULTI_MAX (the unsigned form used for the carve math). */
#define RX_MULTI_MAX 64
/* Max areas in the queued RX ring; QPSK_RX_AREAS selects 2..RX_AREAS_MAX at runtime.
 * Defined here because both the instrumentation block and rx_q_id[] are sized by it. */
#define RX_AREAS_MAX 4
_Static_assert(RX_MULTI_MAX == (int)QPSK_RX_MULTI_MAX, "RX_MULTI_MAX mismatch");
/* tx_ids[] is sized to TX_SLOTS; the RUNTIME inflight cap is max_inflight
 * (2 in polled mode -- unchanged -- raised to TX_SLOTS only in IRQ mode). */
#define MAX_INFLIGHT TX_SLOTS

/* axi_dmac register map (byte offsets) */
#define DMAC_IRQ_MASK      0x080
#define DMAC_IRQ_PENDING   0x084   /* W1C: write-1-to-clear the pending IRQ bits */
#define DMAC_IRQ_SOURCE    0x088   /* raw IRQ source (diagnostic) */
#define DMAC_CONTROL       0x400
#define DMAC_TRANSFER_ID   0x404
#define DMAC_SUBMIT        0x408
#define DMAC_FLAGS         0x40C
#define DMAC_DEST_ADDRESS  0x410
#define DMAC_SRC_ADDRESS   0x414
#define DMAC_X_LENGTH      0x418
#define DMAC_TRANSFER_DONE 0x428

#define DMAC_FLAG_TLAST    0x2
#define DMAC_FLAG_CYCLIC   0x1    /* FLAGS bit0: cyclic re-issue (gated by DMA_CYCLIC
                                  * synth param; permissive -- no-op on a CYCLIC-0 build) */

/* IRQ-mode interrupt mask. axi_dmac IRQ_MASK bit0 = SOT (start-of-transfer),
 * bit1 = EOT (end-of-transfer); a set bit MASKS (disables) that interrupt.
 * Polled mode masks BOTH (0x3, unchanged). IRQ mode masks SOT only (0x1) so we
 * take exactly one EOT interrupt per completed transfer -- SOT carries no
 * information the event loop needs and would just double the wakeups. */
#define DMAC_IRQ_MASK_POLLED   0x3
#define DMAC_IRQ_MASK_IRQ_EOT  0x1

/* -F two-radio K5 frame geometry: one 128-byte payload unit (16 x 64-bit
 * words) per radio frame; the fabric encoder expands it to 2240 air bits.
 * Frame period = 1133 symbols / 240 ksym = 4.72 ms (~212 frames/s).
 *
 * ASYMMETRIC byte contract (k5_240/PACKET_K5.txt, gen_byte_vectors_k5.m):
 *   TX byte transfer = 35 x uint64 = 280 B = ONE air frame (2240 bits): the
 *     info field (1084 bits) sits in words 0..16, the rest is zero fill. The
 *     fabric's bit shifter aligns the byte->air framing on the per-transfer
 *     wordFirst (= tlast), so a TX transfer MUST be a whole 35-word air frame
 *     or every frame decodes to garbage (verified on silicon: a 16-word/128 B
 *     transfer -> garbage cap_out + garbage byte-RX; a 35-word/280 B transfer
 *     -> golden cap_out 0x04922282 + the 16 golden RX words).
 *   RX byte packet = 16 x uint64 = 128 B = the first 1024 of the 1084 decoded
 *     info bits (WORDS_PER_PACKET=16). So RX stays at pkt_bytes (128); only TX
 *     is padded up to the air-frame word count.
 * The logical frame the daemon encodes/CRCs/decodes is the 128 B unit (it
 * round-trips through the 1024-bit RX field); the 152 B TX tail is zero pad. */
#define K5_PKT_BYTES     128
#define K5_TX_XFER_BYTES 280

/* Frame period = (payload_bits/2 QPSK symbols + BARKER_SYMS preamble) /
 * symbol_rate. Derived, not hardcoded: the symbol rate is a RUNTIME parameter
 * (rate_ksym, -r flag or QPSK_RATE_KSYM env, default RATE_KSYM_DEFAULT =
 * 240 ksym/s -- the deployed 240k link). K5_FRAME_S/F1536_FRAME_S_DEFAULT
 * below are the compile-time values AT the 240k default (used for the usage
 * banner and as the initial rx_pkt_s estimate); frame_period_s is the
 * variable every runtime use actually reads, recomputed from rate_ksym and
 * the selected profile's payload bits once mode + rate are known (see
 * qpsk_frame_period()). K5: 2240/2 + 13 Barker = 1133 sym / 240 ksym =
 * 4.72 ms (unchanged literal, now derived). F1536: 24640/2 + 13 = 12333 sym /
 * 240 ksym = 51.39 ms (k5_240/PACKET_F1536.txt; the WPP=191 delivery frame
 * rides the same air-frame cadence as the ROM's 385-word payload). */
#define BARKER_SYMS         13
#define RATE_KSYM_DEFAULT   240.0
#define K5_PAYLOAD_BITS     2240
#define F1536_PAYLOAD_BITS  24640
#define K5_FRAME_S \
    (((double)K5_PAYLOAD_BITS / 2.0 + BARKER_SYMS) / (RATE_KSYM_DEFAULT * 1000.0))
#define F1536_FRAME_S_DEFAULT \
    (((double)F1536_PAYLOAD_BITS / 2.0 + BARKER_SYMS) / (RATE_KSYM_DEFAULT * 1000.0))

/* rx per-packet period self-calibration acceptance window. The upper bound
 * must admit the selected profile's frame period (was 3e-3 for the legacy
 * 280 B / high-rate builds; 8e-3 for K5's 4.72 ms; F1536's ~51.4 ms needs a
 * profile-scaled bound -- see rx_per_cal_max below). */
#define RX_PER_CAL_MIN 150e-6
#define RX_PER_CAL_MAX 8e-3

struct dmac {
    volatile uint32_t *regs;
};

static struct {
    uint64_t tun_a_rx, tun_b_rx, tun_b_tx, tun_a_tx;
    uint64_t frames_tx, frames_rx_ok, crc_drops, seq_gaps;
    uint64_t oversize, tx_stalls, b_side_drops;
    uint64_t retx, dups, recovered;
    uint64_t idle_tx, idle_rx, tun_drops;
    uint64_t naks_tx, naks_rx, arq_lost;   /* cross-link ARQ (arq_x) */
} st;

static int pkt_bytes = QPSK_PKT_BYTES_DEFAULT;
static int tx_xfer_bytes = 0;   /* TX byte-DMA transfer size; 0 -> pkt_bytes.
                                 * K5 pads TX up to the 35-word air frame while
                                 * the logical/RX frame stays pkt_bytes. */
static int rx_multi = 0;        /* packets per transfer; 0 = legacy */
static int k5_mode = 0;         /* -F: two-radio K5 frame geometry */
static int f1536_mode = 0;      /* -G or QPSK_FRAME=f1536: F1536 large-frame
                                 * geometry (pkt=1528 B / tx_xfer=3080 B);
                                 * needs the 2 MB carve (-DQPSK_CARVE_2MB) */
static double rate_ksym = RATE_KSYM_DEFAULT;  /* -r or QPSK_RATE_KSYM env */
static double frame_period_s = K5_FRAME_S;    /* recomputed once mode+rate
                                               * are known (qpsk_frame_period) */
static double rx_per_cal_max = RX_PER_CAL_MAX; /* recomputed with frame_period_s */
static uint32_t tx_slot_stride = SLOT_BYTES;  /* per-slot TX address stride: SLOT_BYTES
                                  * unless tx_xfer_bytes needs more room (only
                                  * F1536 does), in which case TX_BATCH_STRIDE
                                  * (already sized to hold TX_BATCH air frames,
                                  * so it always has headroom) -- set once at
                                  * startup, read by tx_send(). */

/* IRQ (UIO) mode: set only when BOTH qpsk_tx_dma and qpsk_rx_dma UIO nodes are
 * found at startup (the future bitstream+devicetree). On the current image no
 * UIO nodes exist, so irq_mode stays 0 and every shared helper takes its exact
 * historical polled-mode branch. QPSK_FORCE_POLLED=1 forces the fallback. */
static int irq_mode = 0;
static int tx_uio_fd = -1;
static int rx_uio_fd = -1;
static int max_inflight = 2;    /* polled cap (unchanged); IRQ mode -> TX_SLOTS */

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t dump_req = 0;
static volatile sig_atomic_t framelog_rotate_req = 0;  /* SIGUSR2: rotate framelog */

static void on_term(int s) { (void)s; running = 0; }
static void on_usr1(int s) { (void)s; dump_req = 1; }
static void on_usr2(int s) { (void)s; framelog_rotate_req = 1; }

#ifdef QPSK_ARQ_NAKSTAT
/* Declared here rather than beside axr_is_nak() because stats_dump() below is the
 * first use and sits ~900 lines earlier in the file. Definitions, not externs --
 * this is a single translation unit. See the block at axr_is_nak() for semantics. */
static unsigned long long nakstat_seen, nakstat_magic, nakstat_parsed;
#endif

#ifdef QPSK_RXQ_STAT
/* Forward declaration ONLY -- the counters themselves live beside the queued-RX code
 * that maintains them. Deliberately not hoisted the way the nakstat counters were:
 * hoisting a definition reorders .bss and perturbs the object layout even when the
 * feature is compiled out, and board 148 must rebuild from this same source to a
 * functionally untouched binary. A forward function declaration moves nothing. */
static void rxq_stats_dump(void);
#endif
static void ckpt_stats_dump(void);
static void txgap_dump(void);

static void stats_dump(void)
{
    fprintf(stderr,
        "qpsk_tun stats: tunA_rx=%llu tunA_tx=%llu tunB_rx=%llu tunB_tx=%llu "
        "dma_tx=%llu dma_rx_ok=%llu crc_drop=%llu seq_gap=%llu "
        "idle_tx=%llu idle_rx=%llu tun_drop=%llu "
        "oversize=%llu tx_stall=%llu b_drop=%llu "
        "retx=%llu dups=%llu recovered=%llu "
        "naks_tx=%llu naks_rx=%llu arq_lost=%llu\n",
        (unsigned long long)st.tun_a_rx, (unsigned long long)st.tun_a_tx,
        (unsigned long long)st.tun_b_rx, (unsigned long long)st.tun_b_tx,
        (unsigned long long)st.frames_tx, (unsigned long long)st.frames_rx_ok,
        (unsigned long long)st.crc_drops, (unsigned long long)st.seq_gaps,
        (unsigned long long)st.idle_tx, (unsigned long long)st.idle_rx,
        (unsigned long long)st.tun_drops,
        (unsigned long long)st.oversize, (unsigned long long)st.tx_stalls,
        (unsigned long long)st.b_side_drops, (unsigned long long)st.retx,
        (unsigned long long)st.dups, (unsigned long long)st.recovered,
        (unsigned long long)st.naks_tx, (unsigned long long)st.naks_rx,
        (unsigned long long)st.arq_lost);
    txgap_dump();   /* separate line; the stats line above stays byte-identical */
#ifdef QPSK_ARQ_NAKSTAT
    /* separate line, not appended to the format above, so the uninstrumented
     * build's stats line stays byte-for-byte what every existing parser expects */
    fprintf(stderr, "qpsk_tun nakstat: seen=%llu magic=%llu parsed=%llu\n",
            nakstat_seen, nakstat_magic, nakstat_parsed);
#endif
#ifdef QPSK_RXQ_STAT
    rxq_stats_dump();   /* separate line; the stats line above stays byte-identical */
#endif
    ckpt_stats_dump();  /* prints only when QPSK_CKPT is set */
}

/* ---- per-frame telemetry logger (QPSK_FRAMELOG) --------------------------
 * Opt-in, env-gated instrument for the PER<1% capture->reproduce campaign.
 * When QPSK_FRAMELOG is unset every hook below is a no-op and the daemon
 * behaves exactly as before (mirrors the QPSK_WHITEN opt-in idiom). Set
 * QPSK_FRAMELOG=/dev/shm/frames.bin to append one 48-byte record per scored
 * RX frame, tagging it with the modem forensic counters read INLINE at the
 * frame boundary -- a synchronous volatile load off the modem BAR, not an
 * async poll, so there is no poll-rate aliasing (R3 frames ~0.8 ms « any ms
 * poll). Cumulative counters (0x104/0x108/0x150) are logged raw; analysis
 * takes deltas (alias-immune). cfc/adcforensic are moving-quantity snapshots,
 * kept as corroboration only (CFO is independently recoverable from the IQ).
 * crc_ok is per-frame good/bad: CRC pass in tun/echo, scored-CLEAN in -B.
 * Flush: SIGUSR1 (with the stats dump) and atexit; SIGUSR2 rotates (truncates)
 * the file so a long capture can be drained without stopping the daemon. */
struct frame_rec {
    uint64_t t_mono_ns;       /* CLOCK_MONOTONIC at the decode                */
    uint64_t t_real_ns;       /* CLOCK_REALTIME (maps to capture wallclock)   */
    uint32_t host_seq;        /* decoded seq (pass) or raw header seq (fail)  */
    uint32_t crc_ok;          /* 1 = good frame, 0 = errored/dropped          */
    uint32_t reg_packets;     /* 0x104 packets_out (cumulative)               */
    uint32_t reg_biterr;      /* 0x108 bit_errors_out (cumulative BIST)       */
    uint32_t reg_rstcs;       /* 0x150 rstcs_count (cumulative carrier reset) */
    uint32_t reg_cfc;         /* 0x154 cfc_est (CFO trajectory snapshot)      */
    uint32_t reg_adcforensic; /* 0x15C adc_forensic (level/duty/gap snapshot) */
    uint32_t reserved;        /* pad to 48 B / 8-byte record alignment        */
};
_Static_assert(sizeof(struct frame_rec) == 48, "frame_rec must be 48 bytes");

/* Modem forensic register offsets (read-only status). Reads are plain volatile
 * loads off the modem BAR mmap -- the direct_reg_access caveat in qpsk_hw.h
 * applies to control WRITES (arm sequencing), not status reads. */
#define FL_REG_PACKETS  0x104u
#define FL_REG_BITERR   0x108u
#define FL_REG_RSTCS    0x150u
#define FL_REG_CFC      0x154u
#define FL_REG_ADCFOR   0x15Cu

static const char *framelog_path = NULL;      /* NULL => logger disabled */
static FILE *framelog_fp = NULL;
static volatile uint32_t *modem_regs = NULL;  /* modem BAR, mapped in dma_open when enabled */

static uint64_t framelog_clock_ns(clockid_t clk)
{
    struct timespec ts;
    clock_gettime(clk, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint32_t framelog_seq(const unsigned char *p)
{
    return (uint32_t)p[4] | ((uint32_t)p[5] << 8)
         | ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 24);
}

static void framelog_record(int crc_ok, uint32_t seq)
{
    if (!framelog_fp || !modem_regs)
        return;
    struct frame_rec r;
    r.t_mono_ns       = framelog_clock_ns(CLOCK_MONOTONIC);
    r.t_real_ns       = framelog_clock_ns(CLOCK_REALTIME);
    r.host_seq        = seq;
    r.crc_ok          = crc_ok ? 1u : 0u;
    r.reg_packets     = modem_regs[FL_REG_PACKETS / 4];
    r.reg_biterr      = modem_regs[FL_REG_BITERR  / 4];
    r.reg_rstcs       = modem_regs[FL_REG_RSTCS   / 4];
    r.reg_cfc         = modem_regs[FL_REG_CFC     / 4];
    r.reg_adcforensic = modem_regs[FL_REG_ADCFOR  / 4];
    r.reserved        = 0;
    fwrite(&r, sizeof r, 1, framelog_fp);
}

static void framelog_flush(void)
{
    if (framelog_fp)
        fflush(framelog_fp);
}

static void framelog_close(void)
{
    if (framelog_fp) { fflush(framelog_fp); fclose(framelog_fp); framelog_fp = NULL; }
}

/* Consumed from the event loops (not the signal handler) when SIGUSR2 sets the
 * flag: fopen/fclose are not async-signal-safe. */
static void framelog_service(void)
{
    if (framelog_rotate_req && framelog_fp) {
        framelog_rotate_req = 0;
        fclose(framelog_fp);
        framelog_fp = fopen(framelog_path, "wb");   /* truncate + reopen */
        if (framelog_fp)
            setvbuf(framelog_fp, NULL, _IOFBF, 1u << 20);
    }
}

static uint32_t dmac_rd(struct dmac *d, uint32_t off)
{
    return d->regs[off / 4];
}

static void dmac_wr(struct dmac *d, uint32_t off, uint32_t val)
{
    d->regs[off / 4] = val;
}

static void *map_phys(int memfd, uint32_t phys, size_t len)
{
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED,
                   memfd, (off_t)phys);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap 0x%08x: %s\n", phys, strerror(errno));
        exit(1);
    }
    return p;
}

/* ---- device-safe DMA-carve access ----------------------------------------
 * The DMA carve (txbuf/rxbuf, mapped by map_phys via /dev/mem O_SYNC) is
 * NON-CACHEABLE ARM64 Device memory. libc memcpy/memset MUST NEVER touch it:
 * glibc >= ~2.34 emits `dc zva` (cache-zero-by-VA) and unaligned LDP/STP/SIMD,
 * all illegal on Device memory -> synchronous external abort -> SIGBUS. This is
 * userspace-glibc-dependent, NOT board hardware: board 148 (Debian trixie,
 * glibc 2.41) was the canary that faulted here; board 146 (Kuiper, glibc 2.31)
 * only survives because its older mem* happen to use compatible instructions.
 * tx_send/tx_send_batch already store to the carve via an aligned volatile word
 * loop (see tx_send's comment); these helpers give the RX side and rx_arm's
 * zero the SAME treatment. Contract: aligned VOLATILE u64 words + byte tail;
 * the carve side is always 8-byte aligned (carve base + pkt_bytes multiples).
 * The `volatile` is LOAD-BEARING -- it stops GCC -O2 loop-idiom recognition
 * from re-synthesizing a libc mem* call (which would reintroduce the SIGBUS);
 * verified with objdump (accessor bodies contain no `bl <mem*>`, no `dc zva`).
 * The u64<->local moves go through a scalar temp so the LOCAL side needs no
 * particular alignment. */
static void carve_zero(volatile void *carve, size_t n)
{
    volatile uint64_t *d = carve;
    size_t w = n / 8, i;
    for (i = 0; i < w; i++)
        d[i] = 0;
    volatile uint8_t *db = (volatile uint8_t *)carve + w * 8;
    for (i = 0; i < n - w * 8; i++)
        db[i] = 0;
}

static void carve_copy_from(void *dst, const volatile void *carve, size_t n)
{
    const volatile uint64_t *s = carve;
    size_t w = n / 8, i;
    for (i = 0; i < w; i++) {
        uint64_t v = s[i];                          /* aligned volatile Device read */
        memcpy((unsigned char *)dst + i * 8, &v, 8);/* store to cacheable local */
    }
    const volatile uint8_t *sb = (const volatile uint8_t *)carve + w * 8;
    unsigned char *db = (unsigned char *)dst + w * 8;
    for (i = 0; i < n - w * 8; i++)
        db[i] = sb[i];
}

static void carve_copy_to(volatile void *carve, const void *src, size_t n)
{
    volatile uint64_t *d = carve;
    size_t w = n / 8, i;
    for (i = 0; i < w; i++) {
        uint64_t v;
        memcpy(&v, (const unsigned char *)src + i * 8, 8);  /* load from cacheable local */
        d[i] = v;                                           /* aligned volatile Device write */
    }
    volatile uint8_t *db = (volatile uint8_t *)carve + w * 8;
    const unsigned char *sb = (const unsigned char *)src + w * 8;
    for (i = 0; i < n - w * 8; i++)
        db[i] = sb[i];
}

/* IRQ_MASK value for the current mode: polled masks both SOT+EOT (0x3, as it
 * always has); IRQ mode unmasks EOT (0x1). Must be re-applied after every
 * engine reset (the reset reverts the mask), hence a helper. */
static uint32_t dmac_mask_val(void)
{
    return irq_mode ? DMAC_IRQ_MASK_IRQ_EOT : DMAC_IRQ_MASK_POLLED;
}

static void dmac_init(struct dmac *d)
{
    dmac_wr(d, DMAC_CONTROL, 0);   /* engine reset before reprogramming */
    dmac_wr(d, DMAC_CONTROL, 1);
    dmac_wr(d, DMAC_IRQ_MASK, dmac_mask_val());
}

/* IRQ-mode ack: W1C the axi_dmac IRQ_PENDING bits via the existing register
 * accessor, then re-enable the interrupt at the UIO layer. No-op registers are
 * only ever written here in IRQ mode. */
static void dmac_irq_ack(struct dmac *d, int uio_fd)
{
    uint32_t pending = dmac_rd(d, DMAC_IRQ_PENDING);
    dmac_wr(d, DMAC_IRQ_PENDING, pending);   /* write-1-to-clear */
    qpsk_uio_irq_enable(uio_fd);
}

/* ---- Tx side: per-frame one-shots, <= MAX_INFLIGHT outstanding ---- */
static struct dmac txd;
static unsigned char *txbuf;
static uint32_t tx_ids[MAX_INFLIGHT];
static int tx_inflight = 0;
static unsigned tx_slot = 0;

/* ---- TX inter-transfer gap witness (2026-08-28, always on, one line per stats window) ----
 * The modem's TX byte-in plane (16-word ByteWordBuffer) runs dry whenever the MM2S byte
 * stream is silent for more than ~16-28 us between transfers, and every such event costs
 * exactly one air frame (netlist reproduction: rtl_sim/TXPLANE_SIM_RESULTS.md). The
 * hardware queue is ONE request ahead (axi_dmac latches a single request set; a SUBMIT
 * while one is latched overwrites its parameters -- regmap_request.v 9'h102/104-106), so
 * max_inflight=2 (running + latched) is the hardware maximum and the slack the host has
 * is at most one transfer of air (~0.8 ms per F1536 air frame). Silence therefore appears
 * whenever the host does not return to tx_send() before the latched transfer ends --
 * i.e. whenever an event-loop iteration (the RX transfer drain at each S2MM boundary is
 * the long one: 16 CRC checks + tun writes) takes longer than the remaining slack.
 * This witness estimates that silence from the host side, cheaply:
 *   at each submit, after tx_reap(): if the queue is EMPTY (inflight_after_reap == 0)
 *   the fabric has been starved since the previous transfer finished; that finish time
 *   is estimated as previous_submit_time + (frames_in_previous_transfer * frame_period_s)
 *   -- when the previous submit found the queue already busy the fabric consumed it
 *   back-to-back, so the estimate is a lower bound (silence >= estimate). gap_us < 0 is
 *   clipped to 0. Bins: > 20 us (the ByteWordBuffer's cover), > 50 us, > 200 us.
 * Prediction to check against the in-fabric decoder-output checker on the receiver:
 *   gt20us per window ~= garbage-header (magic_bad) frames per window. */
static double now_s(void);              /* defined below (monotonic seconds) */
static uint64_t txgap_n, txgap_empty, txgap_gt20, txgap_gt50, txgap_gt200;
static double   txgap_max_us, txgap_sum_us;
static uint32_t txgap_hist[48];         /* log2 bins of gap_us (bin i: [2^(i/2)) coarse) */
static double   txgap_prev_t = 0;       /* previous submit time (monotonic s) */
static int      txgap_prev_frames = 0;  /* air frames in the previous transfer */
static int      tx_idle_batch = 0;      /* QPSK_TX_QUEUED=N: N idle frames per transfer (0/1 = off) */

static int txgap_bin(double us)
{
    /* integer half-octave bins (no libm: the on-board build links libc only):
     * bin = 2*floor(log2(v+1)) + (mantissa >= sqrt(2)), clipped to 47 */
    uint64_t v = us < 0 ? 0 : (uint64_t)us + 1;
    int l = 0; while ((v >> (l + 1)) != 0) l++;      /* floor(log2 v) */
    int hi = (l > 0 && (v & (1ull << (l - 1))) != 0); /* next bit set -> upper half-octave */
    int b = 2 * l + hi;
    return b >= 48 ? 47 : b;
}
static double txgap_bin_hi_us(int b)                  /* upper edge of bin b, in us */
{
    int l = b / 2; double v = (double)(1ull << l);
    return (b & 1) ? v * 2.0 - 1.0 : v * 1.5 - 1.0;
}

/* called by every submit path with the queue depth after reap and the transfer's frame count */
static void txgap_note(int inflight_after_reap, int frames, double now)
{
    txgap_n++;
    if (txgap_prev_t > 0 && inflight_after_reap == 0) {
        double fin = txgap_prev_t + (double)txgap_prev_frames * frame_period_s;
        double gap = (now - fin) * 1e6;
        if (gap < 0) gap = 0;
        txgap_empty++;
        txgap_sum_us += gap;
        if (gap > txgap_max_us) txgap_max_us = gap;
        if (gap > 20.0)  txgap_gt20++;
        if (gap > 50.0)  txgap_gt50++;
        if (gap > 200.0) txgap_gt200++;
        txgap_hist[txgap_bin(gap)]++;
    }
    txgap_prev_t = now;
    txgap_prev_frames = frames;
}

static double txgap_p99_us(void)
{
    uint64_t tot = 0; for (int i = 0; i < 48; i++) tot += txgap_hist[i];
    if (tot == 0) return 0.0;
    uint64_t acc = 0; uint64_t goal = (tot * 99 + 99) / 100;
    for (int i = 0; i < 48; i++) { acc += txgap_hist[i]; if (acc >= goal) return txgap_bin_hi_us(i); }
    return txgap_max_us;
}

static void txgap_dump(void)
{
    fprintf(stderr, "qpsk_tun txgap: n=%llu empty=%llu gt20us=%llu gt50us=%llu gt200us=%llu max_us=%.0f p99_us=%.0f mean_us=%.1f idle_batch=%d\n",
            (unsigned long long)txgap_n, (unsigned long long)txgap_empty,
            (unsigned long long)txgap_gt20, (unsigned long long)txgap_gt50,
            (unsigned long long)txgap_gt200, txgap_max_us, txgap_p99_us(),
            txgap_empty ? txgap_sum_us / (double)txgap_empty : 0.0, tx_idle_batch);
    txgap_n = txgap_empty = txgap_gt20 = txgap_gt50 = txgap_gt200 = 0;
    txgap_max_us = txgap_sum_us = 0; memset(txgap_hist, 0, sizeof txgap_hist);
}

/* ---- TX submit log (QPSK_TXLOG) ------------------------------------------
 * Ring of the LAST TXLOG_N tx_send() submissions: monotonic timestamp, slot,
 * inflight-before, and spin count. Dumped once at exit. Separates "the FEEDER
 * missed the air deadline" (gap between consecutive submits > frame period)
 * from "the fabric underran on its own" (submit cadence clean while the RX
 * side shows zero-fill) -- the discriminator the periodic TX zero-fill events
 * (TX_ANOMALY_SCAN.md: exact 30/33/34-frame cadence) need. Unset = NULL = no
 * code in the path beyond one pointer test. */
struct txlog_rec { uint64_t t_ns; uint32_t slot; uint16_t inflight; uint16_t spins; };
#define TXLOG_N 65536u
static struct txlog_rec *txlog_buf;      /* NULL = disabled */
static unsigned txlog_head;
static const char *txlog_path;

static void txlog_dump(void)
{
    if (!txlog_buf || !txlog_path) return;
    FILE *f = fopen(txlog_path, "wb");
    if (!f) return;
    unsigned n = txlog_head < TXLOG_N ? txlog_head : TXLOG_N;
    unsigned start = txlog_head < TXLOG_N ? 0 : txlog_head % TXLOG_N;
    for (unsigned i = 0; i < n; i++)
        fwrite(&txlog_buf[(start + i) % TXLOG_N], sizeof *txlog_buf, 1, f);
    fclose(f);
    fprintf(stderr, "qpsk_tun txlog: wrote %u records (of %u submits) to %s\n",
            n, txlog_head, txlog_path);
}

static void tx_reap(void)
{
    while (tx_inflight > 0 &&
           ((dmac_rd(&txd, DMAC_TRANSFER_DONE) >> tx_ids[0]) & 1)) {
        memmove(tx_ids, tx_ids + 1, sizeof(tx_ids[0]) * (size_t)(tx_inflight - 1));
        tx_inflight--;
    }
}

static int tx_capacity(void)
{
    tx_reap();
    return tx_inflight < max_inflight;
}

/* Polled mode: block (bounded, ~2 s) for a free submission slot -- EXACTLY as
 * before. IRQ mode: never spin; return -1 ("would block") and let the event
 * loop apply backpressure via tun-read gating (pfds[tun].events tied to
 * tx_capacity()), so the slot is reaped on the next tx EOT interrupt. Returns
 * 0 on success. */
/* WHERE THE INTER-TRANSFER SILENCE COMES FROM (finding, 2026-08-28):
 * tx_send() already keeps the axi_dmac one request ahead (max_inflight = 2 = running +
 * latched; the regmap holds a single request set, see the txgap block above), and the
 * keepalive path fills eagerly (`while (tx_capacity())`), so the queue is full whenever
 * the event loop is here. The silence is the event loop NOT being here: one iteration
 * of the polled -G loop runs rx_pump (at an S2MM transfer boundary that is a drain of
 * rx_multi slices -- CRC + tun writes, tens of us each, and every so often the whole
 * drain), retx/axr pumps, then the keepalive fill. With F1536 air frames of ~0.8 ms and
 * only ONE latched transfer, any iteration longer than the remaining latched air time
 * starves the fabric; a 16-frame drain at the transfer boundary is the recurring case,
 * which is why the TX defect on one board shows the OTHER direction's S2MM cadence.
 * The daemon already knew the shape of this (see the DRAIN BUDGET note in rx_pump_queued:
 * "TX queue only max_inflight(2) deep, ~1.6 ms of air"). Two host-only mitigations, both
 * opt-in: QPSK_RX_DRAIN_BUDGET (bound the drain per call) and QPSK_TX_QUEUED=N (idle
 * keepalives batched N air frames per transfer, so one latched transfer covers N frames
 * of air instead of one: N=5 at F1536 -> ~4 ms of cover per latched transfer). */
static int tx_send(const unsigned char *pkt)
{
    int spins = 0;
    if (irq_mode) {
        if (!tx_capacity())
            return -1;             /* defer to the event loop */
    } else {
        while (!tx_capacity()) {
            if (++spins > 20000) { st.tx_stalls++; return -1; } /* ~2 s */
            usleep(100);
        }
    }
    txgap_note(tx_inflight, 1, now_s());
    unsigned char *slot = txbuf + (tx_slot % TX_SLOTS) * tx_slot_stride;
    if (tx_xfer_bytes > pkt_bytes) {
        /* K5/F1536: the DMA transfer is a whole air frame (tx_xfer_bytes);
         * the logical frame goes in the leading words, the tail is zero pad so
         * the fabric's per-transfer wordFirst lands on the air-frame boundary.
         * The reserved DMA buffer is mapped NON-CACHEABLE (/dev/mem O_SYNC), so
         * glibc memset (DC ZVA cache-zero) and unaligned SIMD fault on it --
         * build the frame in a local (cacheable) buffer, then store it to the
         * slot in aligned 64-bit words (both sizes are 8-byte aligned). Sized
         * to the largest deployed air frame (F1536_TX_XFER_BYTES) so K5's
         * smaller 280 B frame always fits. */
        static unsigned char frame[F1536_TX_XFER_BYTES] __attribute__((aligned(8)));
        memset(frame, 0, (size_t)tx_xfer_bytes);
        memcpy(frame, pkt, (size_t)pkt_bytes);
        volatile uint64_t *dw = (volatile uint64_t *)slot;
        const uint64_t *sw = (const uint64_t *)frame;
        for (int i = 0; i < tx_xfer_bytes / 8; i++)
            dw[i] = sw[i];
    } else {
        carve_copy_to(slot, pkt, (size_t)pkt_bytes);  /* slot is the NON-CACHEABLE carve */
    }
    uint32_t id = dmac_rd(&txd, DMAC_TRANSFER_ID);
    dmac_wr(&txd, DMAC_SRC_ADDRESS, TX_BUF_PHYS + (tx_slot % TX_SLOTS) * tx_slot_stride);
    dmac_wr(&txd, DMAC_X_LENGTH, (uint32_t)tx_xfer_bytes - 1);
    dmac_wr(&txd, DMAC_FLAGS, DMAC_FLAG_TLAST);
    dmac_wr(&txd, DMAC_SUBMIT, 1);
    tx_ids[tx_inflight++] = id;
    if (txlog_buf) {
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
        struct txlog_rec *r = &txlog_buf[txlog_head++ % TXLOG_N];
        r->t_ns = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
        r->slot = tx_slot;
        r->inflight = (uint16_t)(tx_inflight - 1);
        r->spins = (uint16_t)(spins > 65535 ? 65535 : spins);
    }
    tx_slot++;
    st.frames_tx++;
    return 0;
}

/* -S tick-proof TX: batch TX_BATCH padded air frames into one 4 KB-stride
 * slot and submit as ONE transfer. The TX board's device tick stalls this
 * process 10-40 ms; with per-frame transfers (MAX_INFLIGHT=2 ~ 9.4 ms) the
 * fabric byte feed underruns and those frames NEVER TRANSMIT (proven:
 * seq 1194 absent from a clean air capture, ev1 20260716_022655 -- the
 * Class-1 loss origin). 8 frames x 2 in flight = ~75 ms of queued air.
 * Frames 2..8 of a batch stay air-aligned by the 35-word cadence (the
 * fabric consumes exactly tx_xfer_bytes per air frame). */
#define TX_BATCH        8
#define TX_BATCH_STRIDE QPSK_TX_BATCH_STRIDE   /* 4096 (deployed) / 16384 (2 MB carve) */
/* Local staging buffer for tx_send_batch(): must hold TX_BATCH frames at the
 * WORST-CASE tx_xfer_bytes across every deployed profile (previously a fixed
 * "512 B/frame" guess -- silently too small for any profile with
 * tx_xfer_bytes > 512, e.g. F1536's 3080 B air frame: a latent overflow of
 * this static buffer, flagged in the B2 review). Sized generically off
 * F1536_TX_XFER_BYTES (the largest known tx_xfer_bytes) so it never needs
 * revisiting when a new profile is added below that ceiling. */
#define TX_BATCH_STAGE_BYTES (TX_BATCH * F1536_TX_XFER_BYTES)
/* max frames per batch that still fit in one TX_BATCH_STRIDE slot at the
 * CURRENT tx_xfer_bytes -- F1536's 3080 B air frame only fits 5 per 16 KB
 * stride, not the nominal TX_BATCH=8, so batch callers must ask this instead
 * of assuming TX_BATCH. */
static int tx_batch_max(void)
{
    int n = TX_BATCH;
    if (tx_xfer_bytes > 0 && (uint32_t)(n * tx_xfer_bytes) > TX_BATCH_STRIDE)
        n = (int)(TX_BATCH_STRIDE / (uint32_t)tx_xfer_bytes);
    return n < 1 ? 1 : n;
}

static int tx_send_batch(const unsigned char *frames, int n)
{
    if (n < 1 || n > TX_BATCH ||
        (size_t)n * (size_t)tx_xfer_bytes > (size_t)TX_BATCH_STAGE_BYTES ||
        (uint32_t)(n * tx_xfer_bytes) > TX_BATCH_STRIDE) {
        fprintf(stderr, "tx_send_batch: %d x %d B exceeds staging/stride (max %d frames)\n",
                n, tx_xfer_bytes, tx_batch_max());
        return -1;
    }
    if (irq_mode) {
        if (!tx_capacity())
            return -1;             /* defer to the event loop (see tx_send) */
    } else {
        int spins = 0;
        while (!tx_capacity()) {
            if (++spins > 20000) { st.tx_stalls++; return -1; }
            usleep(100);
        }
    }
    txgap_note(tx_inflight, n, now_s());
    unsigned char *slot = txbuf + (tx_slot % TX_SLOTS) * TX_BATCH_STRIDE;
    static unsigned char batch[TX_BATCH_STAGE_BYTES] __attribute__((aligned(8)));
    memset(batch, 0, (size_t)(n * tx_xfer_bytes));
    for (int f = 0; f < n; f++)
        memcpy(batch + f * tx_xfer_bytes, frames + f * pkt_bytes,
               (size_t)pkt_bytes);
    volatile uint64_t *dw = (volatile uint64_t *)slot;
    const uint64_t *sw = (const uint64_t *)batch;
    for (int i = 0; i < n * tx_xfer_bytes / 8; i++)
        dw[i] = sw[i];
    uint32_t id = dmac_rd(&txd, DMAC_TRANSFER_ID);
    dmac_wr(&txd, DMAC_SRC_ADDRESS, TX_BUF_PHYS + (tx_slot % TX_SLOTS) * TX_BATCH_STRIDE);
    dmac_wr(&txd, DMAC_X_LENGTH, (uint32_t)(n * tx_xfer_bytes) - 1);
    dmac_wr(&txd, DMAC_FLAGS, DMAC_FLAG_TLAST);
    dmac_wr(&txd, DMAC_SUBMIT, 1);
    tx_ids[tx_inflight++] = id;
    tx_slot++;
    st.frames_tx += (unsigned)n;
    return 0;
}

/* ---- Rx side (double-buffered in multi mode) ----
 * The single S2MM engine must be reset before each transfer, so whenever
 * it is between transfers it captures nothing. In multi mode a transfer
 * spans K packets; if the K decoded packets were drained BEFORE rearming,
 * the engine would sit idle for the whole drain window and drop every
 * packet that arrives during it (~30% loss under sustained load). So:
 * the moment a transfer on the fill area completes, rearm the engine on
 * the OTHER area immediately, THEN drain the just-completed area while the
 * engine fills the new one. Legacy mode (-M 0) is single-packet: copy one
 * packet out, rearm at once, decode -- the same "rearm before consume"
 * principle, one packet at a time. */
static struct dmac rxd;
static volatile uint32_t *gpio_regs;   /* byte_ctrl_gpio (multi mode only) */
static unsigned char *rxbuf;           /* legacy: 1 slot; multi: 2 areas */
static int rx_active = 0;
static unsigned rx_fill = 0;           /* area the engine is filling (0/1) */
static int rx_fscan = 0;               /* next slice to eager-check in fill */
static int rx_drain = -1;              /* completed area being drained, or -1 */
static int rx_dscan = 0;               /* next slice in the drain area */
static double rx_t0 = 0;               /* when the fill transfer started */
static double rx_pkt_s = 632e-6;       /* est. seconds/packet (EWMA-tuned) */
static int rx_spin_w = 6;              /* spin the last W packets (QPSK_SPIN_W);
                                        * higher W -> lower loss, higher CPU */
static int rx_nap_us = 60;             /* nap while filling (QPSK_NAP_US) */

/* ---- cyclic-ring RX (QPSK_RX_CYCLIC=1; needs a CONFIG.CYCLIC 1 bitstream) ----
 * The single S2MM engine is armed ONCE and auto-restarts in hardware, so the
 * per-transfer-boundary reset/resubmit (which drops ~1 frame per K-packet transfer)
 * is eliminated. This (non-SG) cyclic mode raises NO completion IRQ and never sets
 * DMAC_TRANSFER_DONE, and the per-arm carve_zero is gone, so freshness is detected by
 * frame sequence-number monotonicity rather than rx_done()/CRC. Default OFF: the legacy
 * rx_arm/rx_pump_frame path is byte-for-byte unchanged and stays the fallback. */
static int rx_cyclic = 0;              /* QPSK_RX_CYCLIC: cyclic ring RX (needs rx_multi>0) */
static unsigned rx_ring_slots = 0;     /* frames in the contiguous ring (computed at arm) */
static unsigned rx_ring_scan = 0;      /* next ring slot to inspect (index order) */
static uint32_t rx_cyc_words0 = 0;     /* 0x1C0 snapshot at arm (ring slot-0 anchor) */
static uint32_t rx_cyc_last = 0;       /* highest consumed seq */
static int rx_cyc_have = 0;            /* rx_cyc_last valid */

/* ---- queued-request RX (QPSK_RX_QUEUED=1; works on the CURRENT bitstream) ----
 * The axi_dmac natively queues ONE request ahead: SUBMIT latches the request in the
 * regmap and it is handed to the transfer core at start-of-transfer (up_dma_req_valid
 * clears on SOT, regmap_request.v:177-179), each request still gates on the frame-sync
 * tuser (request_sync_transfer_start hard-tied, rr.v:161), and completions are tracked
 * by a per-ID DONE bitmap (bit cleared at that ID's SOT, set at its EOT, rr.v:371-378).
 * So instead of reset+reprogram per transfer (a host round-trip during which the
 * un-armed engine drops ~1 frame per boundary -- the measured ~2% lag-M loss), keep TWO
 * transfers outstanding: when the fill transfer completes, the other area's transfer is
 * ALREADY queued in hardware and starts at the next frame sync with no host action.
 * carve_zero-before-submit keeps the "valid CRC = fresh slice" eager invariant.
 * Default OFF: legacy reset-per-transfer path unchanged and remains the fallback; a
 * no-progress watchdog re-arms (reset) if the never-reset engine hits an undocumented
 * wedge, so the failure mode degrades to legacy behavior, not a stall. */
static int rx_queued = 0;              /* QPSK_RX_QUEUED: queued-request RX (needs rx_multi>0) */
static unsigned rx_q_id[RX_AREAS_MAX] = {0};  /* hardware transfer ID (mod 4) per area */
/* QPSK_RX_AREAS: number of RX areas in the queued ring (2 = legacy behaviour).
 * >2 decouples re-arm from drain -- see the header comment in apply_nareas. */
static int      rx_nareas = 2;
static int      rx_qd = -1;            /* area submitted-but-not-yet-running, or -1 */
static unsigned rx_clean_mask = 0;     /* areas drained and free to submit */
static uint32_t rx_area_stride = 0;    /* bytes per area = CARVE / rx_nareas */
static unsigned rx_q_nsub = 0;         /* submissions since arm (IDs assigned in order) */
static int rx_q_defer = -1;            /* area whose submit awaits the pending slot, or -1 */
static double rx_q_progress = 0;       /* last ENGINE event: arm or completion */
/* rx_q_delivered: last time a frame with actual PAYLOAD reached the host (m > 0).
 * Split from rx_q_progress (2026-08-15, RE-APPLIED 2026-08-17 after the original
 * edit was lost uncommitted): rx_q_on_complete() stamps rx_q_progress on EVERY
 * completion, so a stream of bogus completions (ring stopped re-submitting,
 * byte_rx_ready low, 0x1C0 frozen, host re-consuming stale buffers) kept the
 * timestamp fresh and the watchdog could never fire wherever it lived.
 * Engine-alive and data-flowing are different questions with different clocks;
 * the delivery window is looser so a bad RF stretch does not cause re-arm churn. */
static double rx_q_delivered = 0;
static double rx_q_deliv_wdog_s = 10.0; /* QPSK_RX_DELIV_WDOG_S override */
static unsigned rx_q_resets = 0;       /* watchdog re-arms (should stay 0) */
static double rx_q_wdog_s = 3.0;       /* no-progress window (QPSK_RX_WDOG_S override) */
static int rx_drain_budget = 4;        /* QPSK_RX_DRAIN_BUDGET: max slices drained per
                                        * pump call; 0 = unbounded (historical).
                                        * DEFAULT 4 (2026-08-14): the wedge root-cause
                                        * fix (WEDGE_ROOT_CAUSE.md, causal A/B 0/3 vs
                                        * 6/7) was env-gated only and never reached
                                        * production bring-up -- reverse acceptance
                                        * still wedged tonight. Env overrides either
                                        * way (0 restores unbounded). */
/* LAYER B fix 2: raw-slice tap. The -S scorer must see the RAW packet BEFORE the CRC
 * gate (that is the whole -S discipline), so it cannot consume rx_pump_frame's decoded
 * return -- and seq_run's own legacy rx_done()/rx_arm() drain bypassed the QUEUED path
 * entirely, which is why the earlier run measured the wrong path while announcing the
 * right one. When set, every slice the queued pump reads is handed here first. NULL by
 * default: no tap, no behaviour change. */
static void (*rx_raw_tap)(const unsigned char *slice);

/* ---- CP2/CP3 seam checkpoints (QPSK_CKPT) --------------------------------
 * (byte_count, running checksum) pairs bracketing the carve->host copy, per
 * SEGMENTED_LOOPBACK_DESIGN.md: CP2 folds the slice DIRECTLY from the mapped
 * DMA carve (a second uncached read pass), CP3 folds the copied slice. On a
 * per-slice CP2!=CP3 the copy tore or the carve changed under a COMPLETED
 * transfer -- either is a finding. Drain path only: eager-path slices may
 * still be landing, so a mismatch there would be routine, not evidence.
 * Env-gated and sampled (QPSK_CKPT / QPSK_CKPT_N): unset costs nothing and
 * the stats output stays byte-identical. Fold is one rotate+xor per 64-bit
 * word on pkt_bytes (multiple of 8 in every shipped geometry; byte tail kept
 * for -p overrides), chosen over CRC32 for cost -- detection, not correction. */
static int                ck_en;        /* QPSK_CKPT,   0 = off               */
static unsigned           ck_every = 1; /* QPSK_CKPT_N, fold every Nth slice  */
static unsigned long long ck_seen;      /* slices considered (denominator)    */
static unsigned long long ck_slices;    /* slices actually folded             */
static unsigned long long ck2_bytes, ck3_bytes;
static unsigned long long ck_mismatch;  /* CP2 (carve) vs CP3 (copy) disagree */
static uint64_t           ck2_sum, ck3_sum;

/* ---- framestat comparator log (QPSK_FSLOG) -------------------------------
 * CP1-vs-host per-slice comparator for the instrument image: pops one
 * framestat record (0x1D0 lo non-popping, 0x1D4 hi POPS) per drained slice
 * and logs it beside the 16-bit byte-sum of the HOST-received slice (raw,
 * pre-de-whiten -- the checksum contract in FRAMESTAT_NOTES.md). Offline:
 * fabric checksum (record [63:48]) == host sum on a CRC-FAIL slice means the
 * corruption is at/before the ByteSerializer output (demod side); mismatch
 * means it entered between ByteSerializer and the host buffer (DMA write).
 * record[7:0] frame_seq (= packets_out low byte) is the re-sync tag when the
 * FIFO and drain order drift. Requires the instrument image on the board --
 * on a non-instrument image 0x1D0/0x1D4 read as whatever the composite mux
 * returns there and the log is meaningless (analysis must check the tag
 * advances). Ring of the last FSLOG_N slices, dumped at exit. */
struct fslog_rec { uint64_t t_ns; uint32_t fs_lo, fs_hi; uint32_t seq;
                   uint16_t host_ck; uint16_t crc_ok; };
#define FSLOG_N 131072u
static struct fslog_rec *fslog_buf;      /* NULL = disabled */
static unsigned fslog_head;
static uint32_t fslog_pop_token;         /* 0x1DC pops on a CHANGED value */
static const char *fslog_path;

static void fslog_dump(void)
{
    if (!fslog_buf || !fslog_path) return;
    FILE *f = fopen(fslog_path, "wb");
    if (!f) return;
    unsigned n = fslog_head < FSLOG_N ? fslog_head : FSLOG_N;
    unsigned start = fslog_head < FSLOG_N ? 0 : fslog_head % FSLOG_N;
    for (unsigned i = 0; i < n; i++)
        fwrite(&fslog_buf[(start + i) % FSLOG_N], sizeof *fslog_buf, 1, f);
    fclose(f);
    fprintf(stderr, "qpsk_tun fslog: wrote %u records (of %u slices) to %s\n",
            n, fslog_head, fslog_path);
}

static uint64_t ck_fold(const volatile unsigned char *p, size_t n)
{
    uint64_t h = 0;
    const volatile uint64_t *w = (const volatile uint64_t *)p;
    size_t i, nw = n >> 3;
    for (i = 0; i < nw; i++)
        h = ((h << 1) | (h >> 63)) ^ w[i];
    for (i = nw << 3; i < n; i++)
        h = ((h << 1) | (h >> 63)) ^ p[i];
    return h;
}

static void ckpt_stats_dump(void)
{
    if (!ck_en) return;
    fprintf(stderr, "qpsk_tun ckpt: cp2_bytes=%llu cp2_sum=%016llx cp3_bytes=%llu "
            "cp3_sum=%016llx mismatch=%llu slices=%llu seen=%llu every=%u\n",
            ck2_bytes, (unsigned long long)ck2_sum, ck3_bytes,
            (unsigned long long)ck3_sum, ck_mismatch, ck_slices, ck_seen, ck_every);
}

static double now_s(void);             /* defined below */

#ifdef QPSK_RXQ_STAT
/* Queued-RX occupancy/contention counters. These separate the two ways the queued path
 * can lose a slot, which is otherwise unobservable:
 *
 *   defers    -- rx_q_submit() found the ONE pending-request slot still busy after its
 *                bounded spin, so the drained area's next transfer could not be queued
 *                immediately. RACE indicator (submit-slot contention).
 *   backlog   -- slices still undrained when a transfer completed (rx_multi - rx_fscan).
 *                HEADROOM indicator (host not keeping up with the fill). full_eager
 *                counts completions where the host had consumed the whole area.
 *   resets    -- watchdog re-arms; should stay 0 on a healthy link.
 *
 * A zero defer count is a real result (it rules out submit contention), so these are
 * reported every dump rather than only when non-zero. */
static unsigned long long rxq_defers, rxq_completions, rxq_full_eager;
static unsigned long long rxq_backlog_sum;
static unsigned           rxq_backlog_max;

/* ENGINE GAPS -- the race that actually matters here, which `defers` cannot see.
 * defers fires only when SUBMIT is still pending, i.e. genuine slot contention. But in
 * steady state the slot is FREE and the danger is the opposite: the host has not
 * REACHED rx_q_submit() yet, because it is still in the drain loop. With one-ahead
 * queueing, when the running transfer ends the other area must ALREADY be queued; it is
 * only queued after its drain finishes. If the drain outruns the transfer, the engine
 * has nothing to start and frames are lost in that gap -- with defers stuck at 0.
 *
 * rxq_queued_flag[a] = "area a has a submitted-but-not-yet-started transfer". Set on a
 * successful submit (which covers the deferred-retry path too, since the retry calls
 * rx_q_submit again), cleared when that transfer begins running, and reset by
 * rx_arm_queued so a watchdog recovery cannot leave stale 1s that hide later gaps. */
static int                rxq_queued_flag[RX_AREAS_MAX];
static unsigned long long rxq_engine_gaps;
static int                rxq_zerohdr;          /* QPSK_RXQ_ZEROHDR,       0 = off */
static int                rxq_reread;           /* QPSK_RXQ_REREAD,        0 = off */
static int                rxq_drain_delay_us;   /* QPSK_RXQ_DRAINDELAY_US, 0 = off */
static unsigned long long rxq_reread_tries, rxq_reread_ok;
static unsigned long long rxq_zero_us_sum, rxq_zero_n;
static unsigned           rxq_zero_us_max;
static unsigned long long rxq_nap_n, rxq_nap_over2ms, rxq_nap_us_sum;
static unsigned           rxq_nap_us_max;
static unsigned long long rxq_loop_n, rxq_loop_over2ms;
static unsigned           rxq_loop_us_max;
static unsigned long long rxq_pump_n, rxq_pump_over2ms, rxq_pump_us_sum;
static unsigned           rxq_pump_us_max;

static void rxq_stats_dump(void)
{
    fprintf(stderr, "qpsk_tun rxqstat: defers=%llu engine_gaps=%llu completions=%llu "
            "full_eager=%llu backlog_sum=%llu backlog_max=%u resets=%u\n",
            rxq_defers, rxq_engine_gaps, rxq_completions, rxq_full_eager,
            rxq_backlog_sum, rxq_backlog_max, rx_q_resets);
    fprintf(stderr, "qpsk_tun rxqexp: zerohdr=%d reread=%d drain_delay_us=%d "
            "zero_n=%llu zero_us_mean=%.1f zero_us_max=%u reread_tries=%llu reread_ok=%llu\n",
            rxq_zerohdr, rxq_reread, rxq_drain_delay_us, rxq_zero_n,
            rxq_zero_n ? (double)rxq_zero_us_sum/(double)rxq_zero_n : 0.0,
            rxq_zero_us_max, rxq_reread_tries, rxq_reread_ok);
    fprintf(stderr, "qpsk_tun rxqstall: nap_n=%llu nap_us_mean=%.1f nap_us_max=%u "
            "nap_over2ms=%llu | loop_n=%llu loop_us_max=%u loop_over2ms=%llu\n",
            rxq_nap_n, rxq_nap_n ? (double)rxq_nap_us_sum/(double)rxq_nap_n : 0.0,
            rxq_nap_us_max, rxq_nap_over2ms,
            rxq_loop_n, rxq_loop_us_max, rxq_loop_over2ms);
    fprintf(stderr, "qpsk_tun rxqpump: pump_n=%llu pump_us_mean=%.1f pump_us_max=%u "
            "pump_over2ms=%llu\n", rxq_pump_n,
            rxq_pump_n ? (double)rxq_pump_us_sum/(double)rxq_pump_n : 0.0,
            rxq_pump_us_max, rxq_pump_over2ms);
}
#endif

/* Stride is the carve divided evenly between areas. At rx_nareas==2 this is exactly
 * RX_MULTI_MAX*SLOT_BYTES, i.e. the historical layout, unchanged. */
static uint32_t rx_area_span(void)
{
    return rx_area_stride ? rx_area_stride
                          : (uint32_t)(RX_MULTI_MAX * SLOT_BYTES);
}

static uint32_t rx_area_phys(unsigned area)
{
    return RX_BUF_PHYS + area * rx_area_span();
}

static unsigned char *rx_area_virt(unsigned area)
{
    return rxbuf + (size_t)area * (size_t)rx_area_span();
}

/* reset + submit a transfer on `area`; that area becomes the fill area */
static void rx_arm(unsigned area)
{
    int span = rx_multi ? rx_multi : 1;
    carve_zero(rx_area_virt(area), (size_t)(span * pkt_bytes));  /* NON-CACHEABLE carve */
    dmac_wr(&rxd, DMAC_CONTROL, 0);
    dmac_wr(&rxd, DMAC_CONTROL, 1);
    dmac_wr(&rxd, DMAC_IRQ_MASK, dmac_mask_val());  /* re-applied per reset */
    /* TRANSFER_ID is 0 after reset; completion is TRANSFER_DONE bit0 */
    dmac_wr(&rxd, DMAC_DEST_ADDRESS, rx_area_phys(area));
    dmac_wr(&rxd, DMAC_X_LENGTH, (uint32_t)(span * pkt_bytes) - 1);
    dmac_wr(&rxd, DMAC_FLAGS, 0);
    dmac_wr(&rxd, DMAC_SUBMIT, 1);
    rx_fill = area;
    rx_fscan = 0;
    rx_active = 1;
    rx_t0 = now_s();
}

static int rx_done(void)
{
    return dmac_rd(&rxd, DMAC_TRANSFER_DONE) & 1;
}

/* Spin (vs nap) to keep the inter-transfer rearm window under the ~18 us
 * packet gap -- napping past it makes the rearmed transfer miss the next
 * packet's SYNC_TRANSFER_START tuser, skipping ~1 packet per transfer
 * (~8% loss under load; verified). Legacy always spins (per-packet gap).
 * Multi spins while draining, when the transfer is done-but-not-rearmed,
 * and in the ~2-packet window before the K-packet transfer is expected to
 * finish (rx_pkt_s self-calibrates to the packet rate). It naps only
 * through the bulk of the fill, so CPU stays low. */
static int rx_done_q(unsigned area);   /* fwd (queued mode) */
static int rx_want_spin(void)
{
    if (!rx_multi)
        return 1;
    if (rx_queued) {
        /* queued mode has no host-timed rearm window to protect -- the next transfer
         * is pre-queued in hardware. Spin only to keep drain/completion latency low. */
        return rx_drain >= 0 || rx_done_q(rx_fill);
    }
    if (rx_drain >= 0 || rx_done())
        return 1;
    return (now_s() - rx_t0) >= (double)(rx_multi - rx_spin_w) * rx_pkt_s;
}

/* 32-bit serial-number comparison (RFC1982-style): true iff a is strictly after b. */
static inline int seq_after(uint32_t a, uint32_t b) { return (int32_t)(a - b) > 0; }

/* One-time arm of the CYCLIC RX ring. The whole RX carve becomes ONE contiguous ring of
 * rx_ring_slots frames; the engine fills slot 0..N-1 then wraps in place (no per-lap
 * dest advance in this non-SG mode) and re-issues forever with no host reset/resubmit.
 * TLAST stays gated off (transfers are X_LENGTH-bounded -- the multi-drain GPIO setup in
 * dma_open already did this). Requires the CONFIG.CYCLIC 1 bitstream; on a CYCLIC-0 build
 * FLAGS bit0 is masked to 0 and the engine would run one transfer then stop (see the
 * QPSK_RX_CYCLIC guard at startup). */
static void rx_arm_cyclic(void)
{
    rx_ring_slots = (2u * RX_MULTI_MAX * SLOT_BYTES) / (unsigned)pkt_bytes;
    dmac_wr(&rxd, DMAC_CONTROL, 0);                 /* reset once */
    dmac_wr(&rxd, DMAC_CONTROL, 1);                 /* enable (bit0) */
    dmac_wr(&rxd, DMAC_IRQ_MASK, dmac_mask_val());  /* no IRQ fires in cyclic; harmless */
    dmac_wr(&rxd, DMAC_DEST_ADDRESS, rx_area_phys(0));                 /* ring base */
    dmac_wr(&rxd, DMAC_X_LENGTH, rx_ring_slots * (uint32_t)pkt_bytes - 1);
    dmac_wr(&rxd, DMAC_FLAGS, DMAC_FLAG_CYCLIC);    /* bit0 cyclic (TLAST off) */
    dmac_wr(&rxd, DMAC_SUBMIT, 1);                  /* arm once -> re-issues forever */
    rx_ring_scan = 0; rx_cyc_last = 0; rx_cyc_have = 0;
    /* wordcnt free-runs from BOOT; ring slot 0 corresponds to the first frame
     * accepted AFTER this arm (SYNC_TRANSFER_START frame-aligns the base), so
     * the write-pointer math must be relative to the arm-time snapshot --
     * without it the reader chases an arbitrarily offset pointer and decodes
     * torn/unlanded slots forever (manual repro: crc_drop 514/s, idle_rx 0). */
    if (modem_regs)
        rx_cyc_words0 = modem_regs[0x1C0 / 4];
    rx_active = 1;
    rx_t0 = now_s();
}

/* Cyclic ring reader: inspect the next slot in index order (the S2MM stream writes
 * strictly in address order, so consecutive frames land in consecutive slots). With the
 * per-arm carve_zero gone, every slot holds a valid-CRC frame after lap 1, so "valid CRC"
 * no longer means "fresh" -- freshness is the seq advancing past the last consumed one.
 * A seq jump of a full ring means the host fell a lap behind (overrun): count it and
 * resync via the +1 cursor (frame S+1 always lands in the slot after frame S). */
/* CP1 comparator note shared by the cyclic paths (same record the queued drain
 * writes inline): pop-one framestat record + host byte-sum for this slice. */
static void fslog_note(const unsigned char *slice, int m)
{
    if (!fslog_buf || !modem_regs) return;
    struct timespec fts;
    clock_gettime(CLOCK_MONOTONIC, &fts);
    struct fslog_rec *fre = &fslog_buf[fslog_head++ % FSLOG_N];
    fre->t_ns = (uint64_t)fts.tv_sec * 1000000000ull + (uint64_t)fts.tv_nsec;
    if ((modem_regs[0x1D8 / 4] & 0xFFFFu) > 0) {
        fre->fs_lo = modem_regs[0x1D0 / 4];
        fre->fs_hi = modem_regs[0x1D4 / 4];
        modem_regs[0x1DC / 4] = ++fslog_pop_token;
    } else
        fre->fs_lo = fre->fs_hi = 0xFFFFFFFFu;
    { uint32_t hck = 0;
      for (int fb = 0; fb < pkt_bytes; fb++) hck += slice[fb];
      fre->host_ck = (uint16_t)hck; }
    fre->seq    = framelog_seq(slice);
    fre->crc_ok = (uint16_t)(m >= 0);
}

static int rx_cyc_armed = 0;           /* rx_active is SHARED and gets set by the
                                        * startup arm of the legacy/queued path, so
                                        * gating the cyclic arm on it meant
                                        * rx_arm_cyclic NEVER ran: rx_ring_slots
                                        * stayed 0, the mod-0 arithmetic let the scan
                                        * index run unbounded, and carve_copy_from
                                        * walked off the 2 MB mapping -> the exit-139
                                        * SEGV at ~15.9k slices (2026-08-12). */
static int rx_pump_cyclic(unsigned char *out, uint32_t *seq)
{
    if (!rx_cyc_armed || rx_ring_slots == 0) {
        rx_arm_cyclic();
        rx_cyc_armed = 1;
        return 0;
    }
    unsigned char slice[QPSK_PKT_BYTES_MAX];
    /* WRITE-POINTER freshness (instrument image). 0x1C0 free-runs counting
     * accepted 64-bit byte_rx words, so frames_written = wordcnt/WPP and the
     * ring write slot = frames_written % ring_slots. Slots strictly behind it
     * (1-slot guard for the frame in flight) are FINAL: decode either delivers
     * or counts a corrupt frame. No dependence on seq advancing -- which idle
     * frames do not provide: the seq-monotonicity path below wedged after ONE
     * frame on idle-only loopback traffic (cycab_212559, idle_rx=1). The
     * wordcnt wraps mod 2^32 (~5 h at line rate); a wrap misreads one poll and
     * self-heals under the mod-ring compare. Falls back to the seq path when
     * the modem BAR is unmapped (non-instrument image). */
    if (modem_regs) {
        uint32_t wpp = (uint32_t)pkt_bytes / 8u;
        uint32_t words = modem_regs[0x1C0 / 4];
        /* STALL RE-ARM. A fabric soft reset (0x000) after the one-time arm can
         * hang the engine mid-SYNC_TRANSFER_START handshake: wordcnt freezes
         * while the demod resumes (cycab_214552: frozen from t=0 because the
         * loopback re-arm resets the modem AFTER the daemon armed). If the
         * write pointer is static for >0.5 s, re-arm the ring; counted in
         * rx_q_resets. Also makes cyclic survive any future fabric reset. */
        { static uint32_t cw; static double ct;
          double n = now_s();
          if (words != cw) { cw = words; ct = n; }
          else if (ct > 0 && n - ct > 0.5) {
              rx_q_resets++;
              rx_arm_cyclic();
              ct = n;
              return 0;
          } }
        unsigned wslot = (unsigned)(((words - rx_cyc_words0) / wpp) % rx_ring_slots);
        unsigned avail = (wslot + rx_ring_slots - rx_ring_scan) % rx_ring_slots;
        if (avail <= 1)
            return 0;                      /* nothing final behind the writer */
        if (avail >= rx_ring_slots - 2) {  /* about to be lapped: resync ahead */
            st.seq_gaps++;
            rx_ring_scan = (wslot + 2u) % rx_ring_slots;
            return 0;
        }
        carve_copy_from(slice, rx_area_virt(0)
            + (size_t)rx_ring_scan * (size_t)pkt_bytes, (size_t)pkt_bytes);
        int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
        fslog_note(slice, m);
        rx_ring_scan = (rx_ring_scan + 1u) % rx_ring_slots;
        if (m < 0) { st.crc_drops++; framelog_record(0, framelog_seq(slice)); return 0; }
        if (m == 0) { st.idle_rx++; return 0; }
        rx_cyc_last = *seq; rx_cyc_have = 1;   /* keep the cursor coherent */
        return m;
    }
    carve_copy_from(slice, rx_area_virt(0) + (size_t)rx_ring_scan * (size_t)pkt_bytes,
                    (size_t)pkt_bytes);
    int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
    if (fslog_buf && modem_regs) {          /* CP1 comparator, as in the queued drain */
        struct timespec fts;
        clock_gettime(CLOCK_MONOTONIC, &fts);
        struct fslog_rec *fre = &fslog_buf[fslog_head++ % FSLOG_N];
        fre->t_ns = (uint64_t)fts.tv_sec * 1000000000ull + (uint64_t)fts.tv_nsec;
        if ((modem_regs[0x1D8 / 4] & 0xFFFFu) > 0) {
            fre->fs_lo = modem_regs[0x1D0 / 4];
            fre->fs_hi = modem_regs[0x1D4 / 4];
            modem_regs[0x1DC / 4] = ++fslog_pop_token;
        } else
            fre->fs_lo = fre->fs_hi = 0xFFFFFFFFu;
        { uint32_t hck = 0;
          for (int fb = 0; fb < pkt_bytes; fb++) hck += slice[fb];
          fre->host_ck = (uint16_t)hck; }
        fre->seq    = framelog_seq(slice);
        fre->crc_ok = (uint16_t)(m >= 0);
    }
    if (m < 0) {
        /* Ambiguous: mid-write (wait) or a GENUINELY corrupt frame (which would
         * otherwise pin the scan cursor here forever -- a one-frame wedge). Peek
         * the successor slot: the stream writes in address order, so if it
         * already holds a FRESH frame, this slot's frame is corrupt-and-final --
         * count it and step past. A mid-write slot's successor cannot be fresh. */
        /* Peek up to 4 slots ahead (runs of adjacent corrupt frames -- doubles
         * are a real class -- would deadlock a 1-deep peek). Any fresh frame
         * ahead proves this slot is final; advance ONE slot per call so each
         * dead slot is counted individually. */
        unsigned char peek[QPSK_PKT_BYTES_MAX];
        unsigned char pout[QPSK_PKT_BYTES_MAX];
        uint32_t pseq;
        for (unsigned pk = 1; pk <= 4 && pk < rx_ring_slots; pk++) {
            unsigned nxt = (rx_ring_scan + pk) % rx_ring_slots;
            carve_copy_from(peek, rx_area_virt(0) + (size_t)nxt * (size_t)pkt_bytes,
                            (size_t)pkt_bytes);
            if (qpsk_frame_decode(peek, pkt_bytes, pout, &pseq) >= 0 &&
                rx_cyc_have && seq_after(pseq, rx_cyc_last)) {
                st.crc_drops++;
                framelog_record(0, framelog_seq(slice));
                rx_ring_scan = (rx_ring_scan + 1u) % rx_ring_slots;
                break;                     /* consumed the dead slot; deliver nothing */
            }
        }
        return 0;
    }
    if (rx_cyc_have && !seq_after(*seq, rx_cyc_last))
        return 0;                          /* stale slot (not refreshed this lap) -> wait */
    if (rx_cyc_have && (*seq - rx_cyc_last) >= rx_ring_slots)
        st.seq_gaps++;                     /* host fell >=1 full lap behind -> overrun */
    rx_cyc_last = *seq; rx_cyc_have = 1;
    rx_ring_scan = (rx_ring_scan + 1u) % rx_ring_slots;
    if (m == 0) { st.idle_rx++; return 0; }  /* keepalive: consumed, deliver nothing */
    return m;
}

/* Queue the next transfer for `area`. The regmap holds ONE pending request (SUBMIT
 * reads up_dma_req_valid, cleared when the transfer core accepts at SOT); programming
 * the request registers while a request is pending would corrupt it. If the slot is
 * still busy after a short bounded spin, DEFER: remember the area and retry on later
 * pump calls (never blocks the pump loop). In steady state the slot is long free (we
 * submit right after a drain completes, mid-way through the other area's transfer);
 * acceptance itself is a few fabric cycles. carve_zero BEFORE submit preserves the
 * "valid CRC = landed slice" eager invariant. */
#ifdef QPSK_RXQ_STAT
/* Clear only each slice's magic. qpsk_frame_decode rejects on p[0]!=0x51||p[1]!=0x4B
 * before touching anything else, so this preserves the "stale slice must fail to
 * decode" invariant that carve_zero provided -- at 8 bytes per slice, not pkt_bytes. */
static void carve_zero_hdr(unsigned area, int nslots)
{
    int i;
    for (i = 0; i < nslots; i++)
        carve_zero(rx_area_virt(area) + (size_t)i * (size_t)pkt_bytes, 8);
}
#endif

static void rx_q_submit(unsigned area)
{
    int spins = 64;                              /* acceptance is ~cycles on hardware */
    while ((dmac_rd(&rxd, DMAC_SUBMIT) & 1) && --spins > 0)
        ;
    if (spins <= 0) {
        rx_q_defer = (int)area;                  /* retry on a later pump call */
#ifdef QPSK_RXQ_STAT
        rxq_defers++;                            /* submit-slot contention (race side) */
#endif
        return;
    }
#ifdef QPSK_RXQ_STAT
    { double _z0 = now_s();
      if (rxq_zerohdr) carve_zero_hdr(area, rx_multi);
      else             carve_zero(rx_area_virt(area), (size_t)(rx_multi * pkt_bytes));
      { double _us = (now_s() - _z0) * 1e6;
        rxq_zero_us_sum += (unsigned long long)_us; rxq_zero_n++;
        if (_us > (double)rxq_zero_us_max) rxq_zero_us_max = (unsigned)_us; } }
#else
    carve_zero(rx_area_virt(area), (size_t)(rx_multi * pkt_bytes));
#endif
    dmac_wr(&rxd, DMAC_DEST_ADDRESS, rx_area_phys(area));
    dmac_wr(&rxd, DMAC_X_LENGTH, (uint32_t)(rx_multi * pkt_bytes) - 1);
    dmac_wr(&rxd, DMAC_FLAGS, 0);
    dmac_wr(&rxd, DMAC_SUBMIT, 1);
    rx_q_id[area] = rx_q_nsub++ & 3u;            /* IDs assigned at SOT in submit order */
#ifdef QPSK_RXQ_STAT
    rxq_queued_flag[area] = 1;                   /* queued; cleared when it starts running */
#endif
    if (rx_q_defer == (int)area)
        rx_q_defer = -1;
}

/* One-time (and watchdog-recovery) arm: reset, then queue BOTH areas' transfers.
 * Area 0 starts filling at the first frame sync; area 1's request sits queued in
 * hardware and takes over the instant area 0's transfer ends -- no host in the gap. */
static void rx_arm_queued(void)
{
    dmac_wr(&rxd, DMAC_CONTROL, 0);              /* reset: clears IDs + DONE bitmap */
    dmac_wr(&rxd, DMAC_CONTROL, 1);
    dmac_wr(&rxd, DMAC_IRQ_MASK, dmac_mask_val());
    rx_q_nsub = 0;
    rx_q_defer = -1;
    /* carve split: every area gets CARVE/nareas bytes (nareas==2 -> historical stride) */
    rx_area_stride = (uint32_t)(2u * RX_MULTI_MAX * SLOT_BYTES) / (uint32_t)rx_nareas;
#ifdef QPSK_RXQ_STAT
    { int _i; for (_i = 0; _i < RX_AREAS_MAX; _i++) rxq_queued_flag[_i] = 0; }
#endif
    /* areas 2..N-1 start clean and available; 0 runs, 1 is queued */
    rx_clean_mask = 0;
    { int _i; for (_i = 2; _i < rx_nareas; _i++) rx_clean_mask |= 1u << _i; }
    rx_q_submit(0);
    rx_q_submit(1);
    rx_qd = 1;
#ifdef QPSK_RXQ_STAT
    /* area 0 begins RUNNING immediately -- no completion event will clear its flag, and
     * leaving it set masks the first gap after every arm */
    rxq_queued_flag[0] = 0;
#endif
    rx_fill = 0;
    rx_fscan = 0;
    rx_drain = -1;
    rx_active = 1;
    rx_t0 = now_s();
    rx_q_progress = rx_q_delivered = rx_t0;
}

/* Per-ID completion: exact because the bitmap bit for an ID is cleared at that ID's
 * SOT (which precedes any check of a fill area) and set at its EOT. */
static int rx_done_q(unsigned area)
{
    return (int)((dmac_rd(&rxd, DMAC_TRANSFER_DONE) >> rx_q_id[area]) & 1u);
}

/* Completion handling shared by the polled pump and the IRQ event loop: flip the fill
 * area (its transfer is already running in hardware), hand the leftover tail to the
 * drainer; the drained area is re-queued when its drain finishes (rx_pump_queued), or
 * immediately when there is nothing left to drain. */
static void rx_q_on_complete(void)
{
    unsigned completed = rx_fill;
    int from = rx_fscan;
#ifdef QPSK_RXQ_STAT
    /* The area about to take over is `completed ^ 1`. If it was not already queued the
     * engine has nothing to start -> a gap at this boundary. Checked BEFORE any other
     * work here so no early return can skip it. */
    { int nxt = rx_qd;
      if (nxt < 0 || !rxq_queued_flag[nxt]) rxq_engine_gaps++;
      if (nxt >= 0) rxq_queued_flag[nxt] = 0;    /* now running, no longer queued */ }
    /* occupancy at completion: how many slices the host had NOT yet consumed */
    { unsigned bl = (from < rx_multi) ? (unsigned)(rx_multi - from) : 0u;
      rxq_completions++;
      rxq_backlog_sum += bl;
      if (bl > rxq_backlog_max) rxq_backlog_max = bl;
      if (bl == 0) rxq_full_eager++; }
#endif
    double per = (now_s() - rx_t0) / (double)rx_multi;
    if (per > RX_PER_CAL_MIN && per < rx_per_cal_max)
        rx_pkt_s = 0.85 * rx_pkt_s + 0.15 * per;
    /* the queued area is the one the hardware has just started */
    rx_fill = (rx_qd >= 0) ? (unsigned)rx_qd : (completed ^ 1u);
    rx_qd = -1;
    rx_fscan = 0;
    rx_t0 = now_s();
    /* H-6 fix (2026-08-28): stamp ONLY the engine clock here. Stamping rx_q_delivered on
     * every completion neutralised the "completions but NO DELIVERY" watchdog -- the
     * 13:23 wedge snapshot shows completions flowing, crc_drop climbing and dma_rx_ok
     * frozen for minutes with no re-arm. rx_q_delivered is stamped only where a frame
     * with payload OR a valid idle frame reaches the host (drain paths) -- v1 of this fix
     * stamped payload frames only, which made the watchdog re-arm every 10 s on an IDLE
     * link (03:00-03:46 on 08-28: recovery #295). */
    rx_q_progress = rx_t0;
    /* Submit a CLEAN area right now if one exists. With >=3 areas this is the whole
     * point: the engine gets its next transfer queued immediately instead of waiting
     * for `completed` to finish draining. With 2 areas the mask is always empty here,
     * so the historical drain-then-submit order is preserved exactly. */
    if (rx_clean_mask) {
        int a = __builtin_ctz(rx_clean_mask);
        rx_clean_mask &= ~(1u << a);
        rx_q_submit((unsigned)a);
        rx_qd = a;
    }
    if (from < rx_multi) {
        rx_drain = (int)completed;
        rx_dscan = from;
    } else if (rx_qd < 0) {
        rx_q_submit(completed);        /* fully consumed and nothing queued: requeue */
        rx_qd = (int)completed;
    } else {
        rx_clean_mask |= 1u << completed;   /* fully consumed: return to the clean pool */
    }
}

/* Queued-request pump: same drain->eager order as legacy multi, but the completion
 * step never touches CONTROL/reset -- the next transfer is already queued in hardware.
 * A no-progress watchdog (no delivery AND no completion for RX_Q_WDOG_S) recovers via
 * a full re-arm, so an undocumented never-reset wedge degrades to a legacy-style reset
 * instead of a permanent stall. */
static int rx_pump_queued(unsigned char *out, uint32_t *seq)
{
    if (!rx_active) { rx_arm_queued(); return 0; }
    /* 0a. WATCHDOG FIRST (2026-08-15). It used to live at the bottom (step 4),
     * which made it unreachable in the wedge measured on 148 today: a stream of
     * bogus completions makes step 3 (rx_done_q -> rx_q_on_complete) return on
     * EVERY call, so control never reached the timeout check. Observed state was
     * modem decoding at full line rate (0x104 +1240/s, framesync 1251, zero
     * rstcs) with the fabric byte counter 0x1C0 FROZEN -- byte_rx_ready held low
     * because the ring stopped re-submitting -- while the host re-consumed stale
     * buffers: crc_drop climbing ~25k/window, idle_rx frozen, dma_rx_ok=2.
     * rx_q_progress is only stamped on a DELIVERED frame, so the timeout had in
     * fact long expired; the code simply never looked. Evaluating it on entry
     * makes "completions without deliveries" recoverable, which is the whole
     * point of the watchdog. */
    {   double nowv = now_s();
        int engine_stall = (nowv - rx_q_progress  > rx_q_wdog_s);
        int deliv_stall  = (nowv - rx_q_delivered > rx_q_deliv_wdog_s);
        if (engine_stall || deliv_stall) {
            rx_q_resets++;
            fprintf(stderr, "rx_queued: %s for %.1fs -- re-arming (recovery #%u)\n",
                    engine_stall ? "no ENGINE event" : "completions but NO DELIVERY",
                    engine_stall ? rx_q_wdog_s : rx_q_deliv_wdog_s, rx_q_resets);
            rx_arm_queued();          /* re-stamps both clocks */
            return 0;
        }
    }
    /* 0. retry a deferred submit (pending slot was busy at the time) */
    if (rx_q_defer >= 0)
        rx_q_submit((unsigned)rx_q_defer);
    /* 1. drain a completed area (in-order; fully landed slices).
     *
     * DRAIN BUDGET (QPSK_RX_DRAIN_BUDGET, 0 = unbounded = historical). The
     * unbounded loop drains all rx_multi slices in ONE call; with the TX queue
     * only max_inflight(2) deep (~1.6 ms of air at F1536) any drain that takes
     * longer starves the transmitter, and expensive-to-score junk slices make
     * the drain slower still -- a self-sustaining loop measured as the WEDGE:
     * txlog showed ~84 ms all-junk drains repeating ~7/s with inflight_after=0
     * at every gap end (wedgeck_102044). A budget caps slices per call so the
     * caller can feed TX between chunks; state persists and the next call
     * resumes the same area. */
    if (rx_drain >= 0) {
        int ck_budget = rx_drain_budget;
        while (rx_dscan < rx_multi) {
            if (rx_drain_budget > 0 && ck_budget-- <= 0)
                return 0;              /* resume this area on the next call */
            unsigned char slice[QPSK_PKT_BYTES_MAX];
            const volatile unsigned char *ck_src = rx_area_virt((unsigned)rx_drain)
                + (size_t)rx_dscan * (size_t)pkt_bytes;
            uint64_t ck_c2 = 0;
            int ck_this = ck_en && (ck_seen++ % ck_every) == 0;
            if (ck_this) {
                ck_c2 = ck_fold(ck_src, (size_t)pkt_bytes);
                ck2_sum = ((ck2_sum << 1) | (ck2_sum >> 63)) ^ ck_c2;
                ck2_bytes += (unsigned long long)pkt_bytes;
            }
            carve_copy_from(slice, ck_src, (size_t)pkt_bytes);
            if (ck_this) {
                uint64_t ck_c3 = ck_fold(slice, (size_t)pkt_bytes);
                ck3_sum = ((ck3_sum << 1) | (ck3_sum >> 63)) ^ ck_c3;
                ck3_bytes += (unsigned long long)pkt_bytes;
                ck_slices++;
                if (ck_c3 != ck_c2) ck_mismatch++;
            }
            if (rx_raw_tap) rx_raw_tap(slice);
            int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
#ifdef QPSK_RXQ_STAT
            if (rxq_drain_delay_us > 0)
                usleep((unsigned)rxq_drain_delay_us);
            if (m < 0 && rxq_reread) {
                rxq_reread_tries++;
                carve_copy_from(slice, rx_area_virt((unsigned)rx_drain)
                    + (size_t)rx_dscan * (size_t)pkt_bytes, (size_t)pkt_bytes);
                m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
                if (m >= 0) rxq_reread_ok++;
            }
#endif
            if (fslog_buf && modem_regs) {
                struct timespec fts;
                clock_gettime(CLOCK_MONOTONIC, &fts);
                struct fslog_rec *fre = &fslog_buf[fslog_head++ % FSLOG_N];
                fre->t_ns  = (uint64_t)fts.tv_sec * 1000000000ull
                           + (uint64_t)fts.tv_nsec;
                /* FRAMESTAT_NOTES.md protocol: BOTH head reads are non-popping;
                 * pop = write a CHANGED token to 0x1DC, and only when the FIFO
                 * has a record (level = 0x1D8[15:0]). The first comparator run
                 * omitted the pop and read the same head 74k times. */
                if ((modem_regs[0x1D8 / 4] & 0xFFFFu) > 0) {
                    fre->fs_lo = modem_regs[0x1D0 / 4];
                    fre->fs_hi = modem_regs[0x1D4 / 4];
                    modem_regs[0x1DC / 4] = ++fslog_pop_token;
                } else {
                    fre->fs_lo = fre->fs_hi = 0xFFFFFFFFu;   /* FIFO empty */
                }
                { uint32_t hck = 0;
                  for (int fb = 0; fb < pkt_bytes; fb++) hck += slice[fb];
                  fre->host_ck = (uint16_t)hck; }
                fre->seq    = framelog_seq(slice);
                fre->crc_ok = (uint16_t)(m >= 0);
            }
            rx_dscan++;
            if (m > 0) { rx_q_progress = rx_q_delivered = now_s(); return m; }
            if (m == 0) { st.idle_rx++; rx_q_delivered = now_s(); continue; }   /* idle frame = delivery too (H-6 fix v2) */
            st.crc_drops++;
            framelog_record(0, framelog_seq(slice));
        }
        unsigned drained = (unsigned)rx_drain;
        rx_drain = -1;
        if (rx_qd < 0) {
            rx_q_submit(drained);      /* nothing queued: this area takes the slot */
            rx_qd = (int)drained;
        } else {
            rx_clean_mask |= 1u << drained;   /* keep it clean and ready for later */
        }
    }
    /* 2. eager-deliver landed slices of the filling area (decode-fail = not yet
     *    landed vs corrupt is ambiguous -> stop; resolved at completion) */
    if (rx_fscan < rx_multi) {
        unsigned char slice[QPSK_PKT_BYTES_MAX];
        carve_copy_from(slice, rx_area_virt(rx_fill)
            + (size_t)rx_fscan * (size_t)pkt_bytes, (size_t)pkt_bytes);
        int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
        if (m >= 0) {
            rx_fscan++;
            rx_q_progress = now_s();
            if (m == 0) { st.idle_rx++; rx_q_delivered = now_s(); return 0; }   /* engine alive, no payload */
            rx_q_delivered = now_s();
            return m;
        }
    }
    /* 3. completion: flip to the already-running transfer; no reset, no reprogram */
    if (rx_done_q(rx_fill)) {
        rx_q_on_complete();
        return 0;
    }
    /* 4. (watchdog moved to entry -- see 0a. Leaving it here as well would double
     *     the re-arm rate without adding coverage.) */
    return 0;
}

#ifdef QPSK_RXQ_STAT
static int rx_pump_frame(unsigned char *out, uint32_t *seq);   /* fwd for the wrapper */
/* Times one rx_pump_frame call. Used at the tun-loop call site only, so the comparison
 * against the whole-iteration timer isolates the RX half of the loop. */
static int rx_pump_timed(unsigned char *out, uint32_t *seq)
{
    double _t0 = now_s();
    int _r = rx_pump_frame(out, seq);
    double _us = (now_s() - _t0) * 1e6;
    rxq_pump_n++; rxq_pump_us_sum += (unsigned long long)_us;
    if (_us > (double)rxq_pump_us_max) rxq_pump_us_max = (unsigned)_us;
    if (_us > 2000.0) rxq_pump_over2ms++;
    return _r;
}
#else
#define rx_pump_timed rx_pump_frame
#endif

/* Delivers at most one validated frame per call; returns 0 when nothing is
 * deliverable yet. CRC failures are counted internally.
 *
 * Multi mode is eager AND double-buffered: slices of the FILLING area are
 * delivered as soon as their CRC validates (the DMA writes in order and a
 * valid CRC means the slice is fully landed) -- low latency. The instant
 * the K-packet transfer completes, the engine is rearmed on the OTHER area
 * BEFORE the leftover slices are drained -- low loss (the single engine is
 * never idle for a whole drain window). */
static int rx_pump_frame(unsigned char *out, uint32_t *seq)
{
    if (rx_cyclic)
        return rx_pump_cyclic(out, seq);
    if (rx_queued)
        return rx_pump_queued(out, seq);
    if (!rx_active) {
        rx_arm(0);
        rx_drain = -1;
        return 0;
    }
    if (!rx_multi) {
        if (!rx_done())
            return 0;
        unsigned char pkt[QPSK_PKT_BYTES_MAX];
        carve_copy_from(pkt, rx_area_virt(0), (size_t)pkt_bytes);  /* carve -> local */
        rx_arm(0);                 /* rearm before decoding */
        { static int dl=-2; if(dl==-2){const char*e=getenv("QPSK_ATOMDBG");dl=e?atoi(e):0;}
          if(dl>0){dl--; int mo=-1; for(int i=0;i+1<pkt_bytes;i++) if(pkt[i]==0x51&&pkt[i+1]==0x4B){mo=i;break;}
            int gr=-1; unsigned char rr[QPSK_PKT_BYTES_MAX],tt[QPSK_PKT_BYTES_MAX];
            for(int r=0;r<pkt_bytes/8&&gr<0;r++){for(int i=0;i<pkt_bytes;i++)rr[i]=pkt[(i+r*8)%pkt_bytes];
              if(rr[0]!=0x51||rr[1]!=0x4B) continue;
              int l=rr[2]|(rr[3]<<8);
              if(l>QPSK_FRAME_MAX_PAYLOAD(pkt_bytes)) continue;
              uint32_t cx=rr[8]|(rr[9]<<8)|(rr[10]<<16)|((uint32_t)rr[11]<<24);
              memcpy(tt,rr,12+l); memset(tt+8,0,4); if(qpsk_crc32(tt,12+l)==cx)gr=r;}
            int l0=pkt[2]|(pkt[3]<<8); uint32_t s0=pkt[4]|(pkt[5]<<8)|(pkt[6]<<16)|((uint32_t)pkt[7]<<24);
            fprintf(stderr,"ATOM magoff=%d good_word_rot=%d len0=%d seq0=0x%x pay0=0x%02x(want0x%02x) b:",
              mo,gr,l0,s0,l0?pkt[12]:0,(unsigned)(s0&0xff));
            for(int i=0;i<pkt_bytes;i++){if(i%8==0)fprintf(stderr,"|");fprintf(stderr,"%02x",pkt[i]);} fprintf(stderr,"\n"); } }
        int m = qpsk_frame_decode(pkt, pkt_bytes, out, seq);
        if (m < 0) { st.crc_drops++; framelog_record(0, framelog_seq(pkt)); return 0; }
        if (m == 0) { st.idle_rx++; return 0; } /* peer keepalive: consume */
        return m;
    }
    /* 1. drain a completed area first (in-order delivery; its slices are
     *    fully landed, so a failed decode is a genuine corrupt packet) */
    if (rx_drain >= 0) {
        while (rx_dscan < rx_multi) {
            unsigned char slice[QPSK_PKT_BYTES_MAX];
            carve_copy_from(slice, rx_area_virt((unsigned)rx_drain)
                + (size_t)rx_dscan * (size_t)pkt_bytes, (size_t)pkt_bytes);
            int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
            rx_dscan++;
            if (m > 0)
                return m;
            if (m == 0) { st.idle_rx++; continue; } /* keepalive: keep draining */
            st.crc_drops++;
            framelog_record(0, framelog_seq(slice));
        }
        rx_drain = -1;             /* fully drained */
    }
    /* 2. eager-deliver newly-landed slices of the filling area. A failed
     *    decode here is ambiguous (not landed yet vs corrupt), so stop --
     *    it is resolved when the transfer completes (moved to the drain). */
    if (rx_fscan < rx_multi) {
        unsigned char slice[QPSK_PKT_BYTES_MAX];
        carve_copy_from(slice, rx_area_virt(rx_fill)
            + (size_t)rx_fscan * (size_t)pkt_bytes, (size_t)pkt_bytes);
        int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
        if (m >= 0) {
            rx_fscan++;
            if (m == 0) { st.idle_rx++; return 0; } /* keepalive landed */
            return m;
        }
    }
    /* 3. on completion, rearm the OTHER area at once and hand the leftover
     *    slices [rx_fscan, K) of the completed area to the drainer */
    if (rx_done()) {
        unsigned completed = rx_fill;
        int from = rx_fscan;
        /* calibrate the per-packet period from this transfer's duration
         * (guard against idle-stretched transfers under light load; the
         * window admits the K5 4.72 ms frame period) */
        double per = (now_s() - rx_t0) / (double)rx_multi;
        if (per > RX_PER_CAL_MIN && per < rx_per_cal_max)
            rx_pkt_s = 0.85 * rx_pkt_s + 0.15 * per;
        rx_arm(completed ^ 1u);    /* engine resumes immediately; rx_fscan=0 */
        if (from < rx_multi) {
            rx_drain = (int)completed;
            rx_dscan = from;
        }
    }
    return 0;
}

/* ---- link-layer ARQ (DMA tun mode) ----
 * The parked in-FPGA-Tx artifact corrupts frames in bursts, which
 * collapses TCP cubic. Both RF endpoints terminate in this process, so
 * recovery is local: keep the last HIST_SZ transmitted frames; when a
 * validated frame's seq jumps past the expected value, resubmit the
 * missing seqs from history. Delivery is deduplicated; IP tolerates the
 * reordering this introduces. */
#define HIST_SZ    1024u  /* power of two; > episode + full NAK retry cycle at R3 rates */
#define RETX_MAX   3      /* per-seq resubmission cap */
#define RETXQ_SZ   512u
#define DEDUP_SZ   512u

struct hist_ent {
    uint32_t seq;
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char retries;
    unsigned char valid;
};
static struct hist_ent tx_hist[HIST_SZ];
static uint32_t retxq[RETXQ_SZ];
static unsigned retxq_head = 0, retxq_tail = 0;
static uint32_t dedup_ring[DEDUP_SZ];
static unsigned dedup_pos = 0;
static int arq_on = 1;

/* second-copy scheduler: a retransmit lost inside another corruption
 * episode is invisible to gap detection, so every first retransmit gets a
 * second copy ~RETX2_DELAY rx-frames later -- beyond an episode length,
 * decorrelating the two copies. rx_tick advances on every validated rx
 * frame (the link's natural clock). */
#define RETX2_DELAY 16
static struct { uint32_t seq; uint64_t due; } retx2q[RETXQ_SZ];
static unsigned retx2_head = 0, retx2_tail = 0;
static uint64_t rx_tick = 0;

static void hist_store(uint32_t seq, const unsigned char *pkt)
{
    struct hist_ent *h = &tx_hist[seq % HIST_SZ];
    h->seq = seq;
    memcpy(h->pkt, pkt, (size_t)pkt_bytes);
    h->retries = 0;
    h->valid = 1;
}

static void retx_request(uint32_t seq)
{
    if (retxq_tail - retxq_head >= RETXQ_SZ)
        return; /* queue full: episode bigger than recovery capacity */
    retxq[retxq_tail++ % RETXQ_SZ] = seq;
}

static int dedup_seen(uint32_t seq)
{
    for (unsigned i = 0; i < DEDUP_SZ; i++)
        if (dedup_ring[i] == seq)
            return 1;
    return 0;
}

static void dedup_mark(uint32_t seq)
{
    dedup_ring[dedup_pos++ % DEDUP_SZ] = seq;
}

/* resubmit queued seqs while the Tx DMA has capacity. PACED: every resend
 * consumes a matured pacing credit (tx_next), exactly like a data frame --
 * un-paced sends at R3's saturated 1245 f/s overflow the fabric TX FIFO and
 * corrupt the WHOLE stream mid-frame (the historical unpaced-fill lesson;
 * re-learned when un-paced NAK/retx injection collapsed both link directions). */
static void retx_pump(double *tx_next)
{
    /* promote due second copies, skipping any already delivered (the
     * dedup ring is RX-side knowledge, but this is one process) */
    while (retx2_head != retx2_tail && rx_tick >= retx2q[retx2_head % RETXQ_SZ].due) {
        uint32_t s2 = retx2q[retx2_head % RETXQ_SZ].seq;
        if (!dedup_seen(s2))
            retx_request(s2);
        retx2_head++;
    }
    while (retxq_head != retxq_tail && tx_capacity() &&
           (!tx_next || now_s() >= *tx_next)) {
        uint32_t seq = retxq[retxq_head++ % RETXQ_SZ];
        struct hist_ent *h = &tx_hist[seq % HIST_SZ];
        if (!h->valid || h->seq != seq || h->retries >= RETX_MAX)
            continue;
        h->retries++;
        if (tx_send(h->pkt) == 0) {
            st.retx++;
            if (tx_next)
                *tx_next += frame_period_s;   /* consumed a pacing credit */
            if (h->retries == 1 && retx2_tail - retx2_head < RETXQ_SZ) {
                retx2q[retx2_tail % RETXQ_SZ].seq = seq;
                retx2q[retx2_tail % RETXQ_SZ].due = rx_tick + RETX2_DELAY;
                retx2_tail++;
            }
        }
    }
}

/* ---- CROSS-LINK NAK ARQ (arq_x; two-radio -F/-G modes, enabled by -A) ----
 * The in-process ARQ above is meaningless across two radios: the board that
 * DETECTS a loss (RX side) is not the board that SENT the frame. Cross-link
 * flow: the RX side tracks per-seq HOLES; a small NAK control frame (payload
 * magic "QNK1" + seq list) rides its own TX back to the peer; the peer's NAK
 * parser feeds retx_request() and the EXISTING retx_pump/tx_hist/second-copy
 * machinery resends. Retransmits arrive late/out-of-order; a hole-fill is
 * delivered to tun (IP tolerates reordering), a non-hole old seq is a dup.
 * Control frames consume a normal tx_seq (the peer's hole logic sees a
 * contiguous stream) but are NOT hist-stored: a lost NAK costs one wasted
 * peer-side lookup (invalid hist entry -> skipped) and the hole re-NAKs.
 * Loss classes this absorbs (measured): DMA-boundary singles, DC-transient
 * 1-4-frame events, ADC-tick 5-100-frame bursts -- all << HIST_SZ deep. */
#define AXR_MAGIC0 'Q'
#define AXR_MAGIC1 'N'
#define AXR_MAGIC2 'K'
#define AXR_MAGIC3 '1'
#define AXR_HOLE_CAP  4096u  /* table CAPACITY; the live size is axr_hole_sz below */
#define AXR_NAK_MAX   24     /* seqs per NAK frame (fits K5's 116 B payload) */

/* ---- runtime-tunable ARQ parameters (env; defaults reproduce the original) ----
 * Measured 2026-08-07 on the two-radio link: the NAK path works end to end (305 of
 * 354 NAKs arrive, the peer retransmits 3176 frames), but the hole bookkeeping is
 * overwhelmed -- arq_lost=27257 against recovered=1208, and dups=1307 means more
 * than half the retransmits land after their hole was already abandoned. With
 * tries=3 and renak=64 rx_ticks a hole lives only ~150 ms, which is plausibly
 * shorter than the retransmit round trip. These knobs make that testable without a
 * rebuild per point. Unset env => byte-identical behaviour to the original build. */
static unsigned axr_hole_sz   = 512u;   /* QPSK_ARQ_HOLES     (<= AXR_HOLE_CAP) */
static unsigned axr_nak_tries = 3u;     /* QPSK_ARQ_TRIES */
static unsigned axr_renak     = 64u;    /* QPSK_ARQ_RENAK  (rx_ticks) */
static unsigned axr_gap_clamp = 128u;   /* QPSK_ARQ_CLAMP */

static void axr_tune_from_env(void)
{
    const char *s;
    if ((s = getenv("QPSK_ARQ_HOLES")) && *s) {
        unsigned v = (unsigned)strtoul(s, NULL, 0);
        if (v >= 1 && v <= AXR_HOLE_CAP) axr_hole_sz = v;
    }
    if ((s = getenv("QPSK_ARQ_TRIES")) && *s) {
        unsigned v = (unsigned)strtoul(s, NULL, 0);
        if (v >= 1 && v <= 255) axr_nak_tries = v;
    }
    if ((s = getenv("QPSK_ARQ_RENAK")) && *s) {
        unsigned v = (unsigned)strtoul(s, NULL, 0);
        if (v >= 1 && v <= 100000) axr_renak = v;
    }
    if ((s = getenv("QPSK_ARQ_CLAMP")) && *s) {
        unsigned v = (unsigned)strtoul(s, NULL, 0);
        if (v >= 1 && v <= AXR_HOLE_CAP) axr_gap_clamp = v;
    }
}

static int arq_x = 0;
static struct { uint32_t seq; uint64_t due; uint8_t naks; uint8_t valid; }
    axr_hole[AXR_HOLE_CAP];
static uint32_t axr_expected = 0;   /* next in-order seq */
static int axr_have = 0;

static void axr_hole_add(uint32_t seq)
{
    unsigned free_i = axr_hole_sz;
    for (unsigned i = 0; i < axr_hole_sz; i++) {
        if (axr_hole[i].valid && axr_hole[i].seq == seq)
            return;
        if (!axr_hole[i].valid && free_i == axr_hole_sz)
            free_i = i;
    }
    if (free_i == axr_hole_sz) { st.arq_lost++; return; }   /* table full */
    axr_hole[free_i].seq = seq;
    axr_hole[free_i].due = rx_tick;          /* NAK on the next pump */
    axr_hole[free_i].naks = 0;
    axr_hole[free_i].valid = 1;
}

static int axr_hole_fill(uint32_t seq)
{
    for (unsigned i = 0; i < axr_hole_sz; i++)
        if (axr_hole[i].valid && axr_hole[i].seq == seq) {
            axr_hole[i].valid = 0;
            return 1;
        }
    return 0;
}

/* Bookkeep a delivered data seq. Returns 1 = deliver to tun, 0 = drop (dup). */
static int axr_note(uint32_t seq)
{
    if (!axr_have) { axr_have = 1; axr_expected = seq + 1; return 1; }
    int32_t d = (int32_t)(seq - axr_expected);
    if (d == 0) { axr_expected = seq + 1; return 1; }
    if (d > 0) {                              /* jump: open holes for the gap */
        uint32_t miss = (uint32_t)d;
        st.seq_gaps++;
        if (miss > axr_gap_clamp) {           /* too far: count + resync */
            st.arq_lost += miss - axr_gap_clamp;
            miss = axr_gap_clamp;
        }
        for (uint32_t k = 1; k <= miss; k++)
            axr_hole_add(seq - k);
        axr_expected = seq + 1;
        return 1;
    }
    if (axr_hole_fill(seq)) { st.recovered++; return 1; }   /* late fill */
    st.dups++;
    return 0;
}

#ifdef QPSK_ARQ_NAKSTAT
/* ---- NAK-path observability (compile-time opt-in; -DQPSK_ARQ_NAKSTAT) --------
 * WHY: on the bad ARQ runs 148 reported naks_rx=0 while 146 reported naks_tx=1462.
 * naks_rx alone cannot distinguish "no frame ever reached the ARQ layer" from
 * "frames reached it but were not recognised as NAKs". These three counters split
 * that. NOTE the scope limit: axr_is_nak() only ever sees payloads that ALREADY
 * passed CRC and reached the ARQ layer, so nakstat_seen is NOT "NAK frames on the
 * wire" -- a NAK lost on air is invisible here. Pairing nakstat_seen on 148 with
 * naks_tx on 146 is what bounds the air loss.
 *   nakstat_seen   every payload inspected (data frames included)
 *   nakstat_magic  first four bytes matched 'QNK1'
 *   nakstat_parsed matched AND passed the count/length sanity test => a real NAK
 * magic-minus-parsed is malformed or truncated NAKs; seen-minus-magic is ordinary
 * data. Compiled out => this file is byte-identical to the uninstrumented build.
 * (The three counters are DEFINED up beside stats_dump(), which uses them first.) */
static int axr_is_nak(const unsigned char *p, int m)
{
    nakstat_seen++;
    /* guard on m>=4 before touching p[0..3]; the uninstrumented predicate's m>=5
     * short-circuits first, so this must not read past the buffer on a 4-byte frame */
    int magic = (m >= 4 && p[0] == AXR_MAGIC0 && p[1] == AXR_MAGIC1 &&
                 p[2] == AXR_MAGIC2 && p[3] == AXR_MAGIC3);
    if (magic) nakstat_magic++;
    int ok = (m >= 5 && magic &&
              p[4] <= AXR_NAK_MAX && m >= 5 + 4 * (int)p[4]);
    if (ok) nakstat_parsed++;
    return ok;
}
#else
static int axr_is_nak(const unsigned char *p, int m)
{
    return m >= 5 && p[0] == AXR_MAGIC0 && p[1] == AXR_MAGIC1 &&
           p[2] == AXR_MAGIC2 && p[3] == AXR_MAGIC3 &&
           p[4] <= AXR_NAK_MAX && m >= 5 + 4 * (int)p[4];
}
#endif

/* Peer asked for these seqs: feed the existing TX-side resend machinery. */
static void axr_parse_nak(const unsigned char *p)
{
    unsigned n = p[4];
    st.naks_rx++;
    for (unsigned i = 0; i < n; i++) {
        uint32_t s = (uint32_t)p[5 + 4*i] | ((uint32_t)p[6 + 4*i] << 8) |
                     ((uint32_t)p[7 + 4*i] << 16) | ((uint32_t)p[8 + 4*i] << 24);
        retx_request(s);
    }
}

/* Send NAKs for due holes + expire hopeless ones. tx_seq is the caller's data
 * sequence counter (control frames consume one). Rare (~per loss event), so
 * they bypass pacing credits; tx_capacity() still bounds them. */
static void axr_pump(uint32_t *tx_seq, double *tx_next)
{
    uint32_t batch[AXR_NAK_MAX];
    unsigned n = 0;
    /* expire hopeless holes regardless of TX capacity */
    for (unsigned i = 0; i < axr_hole_sz; i++)
        if (axr_hole[i].valid && rx_tick >= axr_hole[i].due &&
            axr_hole[i].naks >= axr_nak_tries) {
            axr_hole[i].valid = 0;
            st.arq_lost++;
        }
    if (!tx_capacity() || (tx_next && now_s() < *tx_next))
        return;               /* don't mark holes NAKed unless we can SEND (paced) */
    for (unsigned i = 0; i < axr_hole_sz && n < AXR_NAK_MAX; i++) {
        if (!axr_hole[i].valid || rx_tick < axr_hole[i].due)
            continue;
        batch[n++] = axr_hole[i].seq;
        axr_hole[i].naks++;
        axr_hole[i].due = rx_tick + axr_renak;
    }
    if (n == 0)
        return;
    unsigned char payload[5 + 4 * AXR_NAK_MAX];
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    payload[0] = AXR_MAGIC0; payload[1] = AXR_MAGIC1;
    payload[2] = AXR_MAGIC2; payload[3] = AXR_MAGIC3;
    payload[4] = (unsigned char)n;
    for (unsigned i = 0; i < n; i++) {
        payload[5 + 4*i] = (unsigned char)(batch[i] & 0xFF);
        payload[6 + 4*i] = (unsigned char)((batch[i] >> 8) & 0xFF);
        payload[7 + 4*i] = (unsigned char)((batch[i] >> 16) & 0xFF);
        payload[8 + 4*i] = (unsigned char)((batch[i] >> 24) & 0xFF);
    }
    qpsk_frame_encode(pkt, pkt_bytes, payload, (int)(5 + 4 * n), *tx_seq);
    if (tx_send(pkt) == 0) {
        st.naks_tx++;
        (*tx_seq)++;              /* consumed a data seq (not hist-stored) */
        if (tx_next)
            *tx_next += frame_period_s;   /* consumed a pacing credit */
    }
}

/* ---- TUN/TAP ---- */
static int tun_alloc(const char *name, int tap)
{
    struct ifreq ifr;
    int fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("/dev/net/tun"); exit(1); }
    memset(&ifr, 0, sizeof ifr);
    ifr.ifr_flags = (short)((tap ? IFF_TAP : IFF_TUN) | IFF_NO_PI);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        fprintf(stderr, "TUNSETIFF %s: %s\n", name, strerror(errno));
        exit(1);
    }
    return fd;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s -i ifA [-i ifB] [-t] [-F | -G] [-l | -e] [-p bytes] [-M pkts]\n"
        "          [-m mtu] [-s secs] [-d secs] [-r ksym] [-R] [-A]\n"
        "  -i name   interface name; give once for a two-radio link (the\n"
        "            single tun carries both directions), twice for the\n"
        "            single-board A-side/B-side topology (-l needs two)\n"
        "  -t        TAP instead of TUN (set iface MTU <= payload - 14)\n"
        "  -F        two-radio K5 frame geometry: pkt=%d bytes (16x64-bit\n"
        "            words per radio frame), idle-frame keepalive at the\n"
        "            ~%.0f/s frame rate (at -r's %.0f ksym default), ARQ off\n"
        "            by default\n"
        "  -G        two-radio F1536 large-frame geometry: pkt=%d bytes\n"
        "            (%d x 64-bit words per radio frame; needs the 2 MB carve,\n"
        "            build with -DQPSK_CARVE_2MB), same keepalive/ARQ-off\n"
        "            defaults as -F. Also selected by QPSK_FRAME=f1536.\n"
        "  -l        loopback mode: A<->B in-process, no DMA (host test)\n"
        "  -e        echo mode: no tun; frame generator/checker over DMA\n"
        "  -B        full-packet BER mode: radiate a fixed reference frame and\n"
        "            score every raw RX packet against it (-d sets duration)\n"
        "  -S        sequence-streaming mode: unique seq+PRBS frame per\n"
        "            transmission; loss-proof OK/BITERR/LOST accounting and\n"
        "            error events to /dev/shm/seq_events.log (-d duration)\n"
        "  -T        run the BER + seq scorer self-tests and exit (no hardware)\n"
        "  -p bytes  QPSK packet payload size (default %d; 560 for the\n"
        "            4480-bit build; overrides the -F/-G default)\n"
        "  -M pkts   multi-packet Rx capture (needs byte_ctrl_gpio in the\n"
        "            bitstream); 0 = legacy per-packet spin (default)\n"
        "  -r ksym   symbol rate in ksym/s (default %.0f); the -F/-G frame\n"
        "            period is derived from this, not hardcoded (also\n"
        "            QPSK_RATE_KSYM env)\n"
        "  -R        disable the link-layer ARQ (gap-driven retransmit)\n"
        "  -A        force the ARQ on even in -F/-G mode (single-process only)\n"
        "  -m mtu    max payload accepted (default pkt - %d)\n"
        "  -s secs   periodic stats dump interval (default off)\n"
        "  -d secs   echo-mode duration (default 60)\n",
        argv0, K5_PKT_BYTES, 1.0 / K5_FRAME_S, RATE_KSYM_DEFAULT,
        F1536_PKT_BYTES, F1536_PKT_BYTES / 8,
        QPSK_PKT_BYTES_DEFAULT, RATE_KSYM_DEFAULT, QPSK_FRAME_HDR_BYTES);
    exit(2);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

#ifdef QPSK_CARVE_2MB
/* Startup guard (2 MB-carve build only). Refuse to touch the carve unless
 * /proc/iomem shows a reserved region covering the WHOLE 2 MB carve
 * (0x7FE00000..0x7FFFFFFF). A -DQPSK_CARVE_2MB binary on a board whose device
 * tree still reserves only the old 1 MB (0x7FF00000..) would map 0x7FE00000
 * and let the RX S2MM engine scribble the unreserved MB of kernel RAM below
 * it. This is fatal by design -- the alternative is silent memory corruption.
 * Deploy the 2 MB qpsk dtb (two_jup/deploy_dtb.sh) before provisioning the
 * 2 MB host build; see docs/DEPLOY_F1536.md. */
#define QPSK_CARVE_BYTES 0x200000u
static void carve_guard_or_die(void)
{
    uint64_t base = QPSK_DMA_BUF_BASE;
    uint64_t top  = base + QPSK_CARVE_BYTES - 1u;
    if (!qpsk_iomem_reserved_covers("/proc/iomem", base, top)) {
        fprintf(stderr,
            "FATAL: -DQPSK_CARVE_2MB build requires a 2 MB reserved carve at "
            "0x%08llx..0x%08llx,\n"
            "  but /proc/iomem has no 'reserved' region covering it -- this "
            "board's device tree\n"
            "  still reserves only the old 1 MB (0x7FF00000..). Mapping "
            "0x7FE00000 now would let\n"
            "  the DMA engine scribble kernel RAM. Deploy the 2 MB qpsk dtb "
            "(two_jup/deploy_dtb.sh)\n"
            "  first, or run a 1 MB-carve build (make qpsk_tun, no "
            "-DQPSK_CARVE_2MB).\n",
            (unsigned long long)base, (unsigned long long)top);
        exit(1);
    }
}
#endif

static void dma_open(void)
{
#ifdef QPSK_CARVE_2MB
    carve_guard_or_die();   /* refuse before the first carve mapping */
#endif
    int memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (memfd < 0) { perror("/dev/mem"); exit(1); }
    txd.regs = map_phys(memfd, TX_DMA_BASE, 0x1000);
    rxd.regs = map_phys(memfd, RX_DMA_BASE, 0x1000);
    txbuf = map_phys(memfd, TX_BUF_PHYS, TX_SLOTS * TX_BATCH_STRIDE);
    rxbuf = map_phys(memfd, RX_BUF_PHYS, 2u * RX_MULTI_MAX * SLOT_BYTES);
    if (framelog_path || fslog_path || rx_cyclic)
        /* per-frame telemetry / CP1 comparator / cyclic write-pointer (0x1C0)
         * all read the modem BAR inline */
        modem_regs = map_phys(memfd, QPSK_MODEM_BASE, 0x1000);
    if (rx_multi) {
        gpio_regs = map_phys(memfd, GPIO_BASE, 0x1000);
        gpio_regs[0] = 0;   /* TLAST off: transfers bounded by X_LENGTH */
    }
    dmac_init(&txd);
    rx_arm(0);
    rx_drain = -1;
}

static void echo_mode(int duration)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char payload[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    int maxp = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
    uint32_t tx_seq = 0, last_rx_seq = 0;
    int have_rx = 0;
    double t0 = now_s(), tlast = t0;

    dma_open();
    while (running && now_s() - t0 < duration) {
        framelog_service();                              /* SIGUSR2 rotate */
        if (dump_req) { dump_req = 0; framelog_flush(); } /* SIGUSR1 flush */
        if (tx_capacity()) {
            for (int i = 0; i < maxp; i++)
                payload[i] = (unsigned char)(tx_seq + (uint32_t)i);
            qpsk_frame_encode(pkt, pkt_bytes, payload, maxp, tx_seq);
            if (tx_send(pkt) == 0)
                tx_seq++;
        }
        uint32_t seq;
        int n;
        while ((n = rx_pump_frame(out, &seq)) > 0) {
            st.frames_rx_ok++;
            framelog_record(1, seq);
            if (have_rx && seq != last_rx_seq + 1)
                st.seq_gaps++;
            last_rx_seq = seq;
            have_rx = 1;
        }
        if (now_s() - tlast >= 5.0) {
            tlast = now_s();
            fprintf(stderr, "echo: t=%.0fs tx=%llu rx_ok=%llu crc_drop=%llu gaps=%llu\n",
                now_s() - t0, (unsigned long long)st.frames_tx,
                (unsigned long long)st.frames_rx_ok,
                (unsigned long long)st.crc_drops,
                (unsigned long long)st.seq_gaps);
        }
        if (!rx_want_spin())
#ifdef QPSK_RXQ_STAT
            { double _n0 = now_s();
              usleep((useconds_t)rx_nap_us);
              { double _us = (now_s() - _n0) * 1e6;
                rxq_nap_n++; rxq_nap_us_sum += (unsigned long long)_us;
                if (_us > (double)rxq_nap_us_max) rxq_nap_us_max = (unsigned)_us;
                if (_us > 2000.0) rxq_nap_over2ms++; } }
#else
            usleep((useconds_t)rx_nap_us);
#endif
    }
    if (rx_multi && gpio_regs)
        gpio_regs[0] = 1;   /* restore legacy per-packet TLAST */
    printf("ECHO: dur=%.1f tx=%llu rx_ok=%llu crc_drop=%llu gaps=%llu\n",
        now_s() - t0, (unsigned long long)st.frames_tx,
        (unsigned long long)st.frames_rx_ok,
        (unsigned long long)st.crc_drops, (unsigned long long)st.seq_gaps);
}

/* -B full-packet BER mode: continuously radiate ONE fixed reference frame and
 * score every raw RX packet (INCLUDING CRC failures -- those carry the bit
 * errors) against that same reference. Uses the legacy single-packet RX path
 * directly (not rx_pump_frame, which decodes and drops CRC-fail frames). The
 * reference is header-independent (a fixed constant), so alignment is resolved
 * per frame and the whole 1024-bit packet is compared. Peer runs the same
 * binary -> identical reference; on internal loopback (0x114=0) it scores its
 * own frames and must read BER~0 (the calibration gate). */
static void ber_run(int duration)
{
    unsigned char ref[QPSK_PKT_BYTES_MAX];
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    struct qpsk_ber_stats bs;
    double t0, tlast;

    qpsk_ber_make_ref(ref, pkt_bytes);
    qpsk_ber_reset(&bs, pkt_bytes);
    dma_open();                     /* legacy single-packet RX (rx_multi==0) + tx */
    t0 = now_s();
    tlast = t0;

    while (running && now_s() - t0 < duration) {
        framelog_service();                              /* SIGUSR2 rotate */
        if (dump_req) { dump_req = 0; framelog_flush(); } /* SIGUSR1 flush */
        /* keep the modulator continuously fed with the reference frame */
        while (tx_capacity())
            if (tx_send(ref) != 0)
                break;
        /* legacy single-packet capture: rearm before scoring so the engine is
         * never idle during the scan, then score the RAW bytes */
        if (rx_done()) {
            carve_copy_from(pkt, rx_area_virt(0), (size_t)pkt_bytes);  /* carve -> local */
            rx_arm(0);
            int bkt = qpsk_ber_score_frame(pkt, ref, &bs);
            framelog_record(bkt == QBER_CLEAN, framelog_seq(pkt));  /* good = 0 bit errors */
        }
        if (now_s() - tlast >= 5.0) {
            tlast = now_s();
            double ber = bs.total_bits
                ? (double)bs.total_bit_errors / (double)bs.total_bits : 0.0;
            fprintf(stderr,
                "ber: t=%.0fs frames=%llu clean=%llu noisy=%llu phase=%llu "
                "rot=%llu miss=%llu BER=%.3e\n",
                now_s() - t0, (unsigned long long)bs.frames_scored,
                (unsigned long long)bs.bucket[QBER_CLEAN],
                (unsigned long long)bs.bucket[QBER_NOISY],
                (unsigned long long)bs.bucket[QBER_PHASE],
                (unsigned long long)bs.bucket[QBER_ROTATED],
                (unsigned long long)bs.bucket[QBER_MISS], ber);
        }
    }
    qpsk_ber_report(&bs, stdout);
}

/* -S sequence-streaming mode: radiate a UNIQUE frame per transmission
 * (monotonic seq + PRBS(seq) payload) and score every raw RX packet against
 * its regenerated expectation (qpsk_seq). Loss-proof: every seq in the span
 * ends up OK/BITERR/LOST exactly once. Events (biterr/lost/dup/junk-run) go
 * to stderr AND /dev/shm/seq_events.log -- the trigger feed for the IQ ring
 * capture (error_hunt.sh). Both endpoints run -S; each scores the link INTO
 * itself, seq spaces are independent per direction. */
static FILE *seq_evf = NULL;
static double seq_t0 = 0;

static void seq_evt(void *ctx, const char *type, uint32_t seq, uint32_t n,
                    double t)
{
    (void)ctx;
    fprintf(stderr, "EVT t=%.6f seq=%u type=%s n=%u\n", t, seq, type, n);
    if (seq_evf) {
        fprintf(seq_evf, "EVT t=%.6f seq=%u type=%s n=%u\n", t, seq, type, n);
        fflush(seq_evf);
    }
}

/* LAYER B: tap target -- scores the raw slice the QUEUED pump just read, pre-CRC. */
static struct qpsk_seq_stats *seq_ss;
static void seq_raw_tap(const unsigned char *slice)
{
    if (seq_ss)
        qpsk_seq_score_frame(seq_ss, slice, now_s() - seq_t0);
}

/* QPSK_SEQ_NOBATCH: -S submits one frame per transfer (tx_send) instead of a batch
 * (tx_send_batch). Set from the environment in seq_run; 0 = unchanged behaviour. */
static int seq_nobatch = 0;

/* Fill the TX ring with PN frames, PACED TO THE AIR FRAME PERIOD.
 *
 * LAYER B fix 4 -- the real defect behind three aborted runs. seq_run used to fill
 * to capacity with no pacing at all:  while (tx_capacity()) { ...send... }
 * Every other transmit path in this daemon is paced by a tx_next credit at
 * frame_period_s (see the -G loop's `while (tx_capacity() && now_s() >= tx_next)`,
 * and retx_pump/axr_pump which each consume one credit). -S was the sole exception.
 *
 * Unpaced, the feeder submits as fast as the DMA accepts rather than as fast as the
 * modem transmits, so queued frames are overwritten mid-transmission and the air
 * carries garbage. Measured directly: with an earlier "fill harder" change 148 ran
 * at 3013 f/s against a 1245 f/s air rate -- 242% -- and the receiver STILL framed
 * nothing. That falsified the under-feed explanation and pointed here: the fault is
 * the absence of pacing, not the rate.
 *
 * Called between drained RX slices as well as at the top of the loop, so credits are
 * consumed promptly and a long scoring pass cannot starve the air.
 */
static void seq_tx_fill(uint32_t *tx_seq, unsigned char *batchf,
                        unsigned char *payload, double *tx_next)
{
    /* CHEAP CHECK FIRST. tx_capacity() calls tx_reap(), which does a dmac_rd() MMIO
     * read; now_s() is a vDSO clock read. This function is called after EVERY drained
     * RX slice (up to rx_multi*2 = 64 per outer iteration), so evaluating
     * tx_capacity() first meant up to 64 MMIO reads per iteration even when no pacing
     * credit was due. Ordering the clock test first short-circuits nearly all of them.
     * Measured before this: 604 f/s against a 1245 f/s air rate on the RX-heavy board
     * while the TX-light peer managed 1186 f/s -- the asymmetry is the RX drain path,
     * and this is the MMIO cost inside it. */
    while (now_s() >= *tx_next && tx_capacity()) {
        /* Per-frame tx_send() by default -- the path -G uses. QPSK_SEQ_BATCH=1
         * selects the old tx_send_batch() path, kept only so the A/B is repeatable;
         * it delivers ~11% of what it sends against ~66% per-frame (batch_ab.sh). */
        int n = seq_nobatch ? 1 : tx_batch_max();
                                 /* TX_BATCH frames don't always fit one
                                  * TX_BATCH_STRIDE slot at F1536's larger
                                  * tx_xfer_bytes -- see tx_batch_max() */
        /* TX-seam checker leg (2026-08-18): QPSK_SEQ_TGENTX=<fill> sends
         * TGEN-format frames (const CRC, PN fill) so the in-fabric
         * tx_seam_checker can score the byte plane before the modulator. */
        static int seq_tgentx = -2;
        if (seq_tgentx == -2) {
            const char *e = getenv("QPSK_SEQ_TGENTX");
            seq_tgentx = (e && *e) ? atoi(e) : -1;
        }
        for (int f = 0; f < n; f++) {
            if (seq_tgentx >= 0) {
                qpsk_seq_tgen_frame(batchf + f * pkt_bytes, pkt_bytes,
                                    *tx_seq + (uint32_t)f, seq_tgentx);
            } else {
                qpsk_seq_payload(payload, QPSK_SEQ_PAYLOAD_LEN, *tx_seq + (uint32_t)f);
                qpsk_frame_encode(batchf + f * pkt_bytes, pkt_bytes, payload,
                                  QPSK_SEQ_PAYLOAD_LEN, *tx_seq + (uint32_t)f);
            }
        }
        if ((seq_nobatch ? tx_send(batchf) : tx_send_batch(batchf, n)) != 0)
            break;
        *tx_seq += (uint32_t)n;
        *tx_next += (double)n * frame_period_s;   /* consumed n pacing credits */
        /* Do not let credit accumulate without bound if the loop was stalled:
         * a huge backlog would burst-flood the DMA exactly as the unpaced code
         * did. Cap the arrears at one batch, mirroring the -G pace_lead clamp. */
        if (now_s() - *tx_next > (double)n * frame_period_s)
            *tx_next = now_s() - (double)n * frame_period_s;
    }
}

static void seq_run(int duration)
{
    unsigned char payload[QPSK_SEQ_PAYLOAD_LEN];
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    struct qpsk_seq_stats ss;
    uint32_t tx_seq = 0;
    double tlast;

    memset(&ss, 0, sizeof ss);
    ss.evt = seq_evt;
    ss.rawf = fopen("/dev/shm/seq_raw.log", "a");  /* errored-frame hex dumps */
    /* batch_m is a REQUIRED reset parameter now: it used to be assigned afterwards and
     * seq_run forgot, leaving BATCH_DROP unable to fire while the unit test passed
     * because it set the field by hand. The compiler enforces it here. */
    /* PER-FRAME SUBMIT IS NOW THE DEFAULT for -S (2026-08-11). The batched path was
     * the instrument manufacturing the loss it was built to measure: an interleaved
     * off-air A/B (batch_ab.sh, 3 cycles) measured delivery = ok/(ok+lost) at
     * 11.1%/11.1%/11.1% batched against 66.3%/67.3%/66.5% per-frame -- 6.0x, 3/3 in
     * each arm with no overlap, and batched sitting on exactly 1/9 across runs whose
     * absolute ok differed by 2.5x. That loss was being reported as a DMA-boundary
     * result. tx_send_batch() has exactly ONE caller (this function): every
     * production path -- -G data/idle, retx_pump, axr_pump, -B reference -- already
     * uses tx_send(), so this is an instrument correctness fix with no product
     * exposure. QPSK_SEQ_BATCH=1 restores the old batched path for A/B work. */
    { const char *e = getenv("QPSK_SEQ_BATCH"); seq_nobatch = !(e && *e != '0'); }
    fprintf(stderr, "LAYER B: TX submit = %s\n",
            seq_nobatch ? "per-frame tx_send() [default, matches -G]"
                        : "BATCHED tx_send_batch() [QPSK_SEQ_BATCH=1 -- loses ~6x more]");
    /* TGEN (2026-08-17): pure-scorer mode. The in-fabric traffic generator owns
     * TX and holds the byte path's ready low toward the host, so -S TX submits
     * would push against an intentionally stalled DMA. */
    static int seq_rxonly;
    { const char *e = getenv("QPSK_SEQ_RXONLY"); seq_rxonly = (e && *e != '0'); }
    if (seq_rxonly)
        fprintf(stderr, "LAYER B: TX DISABLED (QPSK_SEQ_RXONLY) -- pure scorer\n");
    qpsk_seq_reset(&ss, pkt_bytes, rx_multi);
    seq_ss = &ss;
    if (rx_queued) {
        rx_raw_tap = seq_raw_tap;   /* score pre-CRC slices from the QUEUED pump */
        fprintf(stderr, "LAYER B: scoring the QUEUED DMA path via raw-slice tap "
                        "(-M %d, batch_m=%d)\n", rx_multi, ss.batch_m);
    }
    seq_evf = fopen("/dev/shm/seq_events.log", "a");
    if (seq_evf) {
        fprintf(seq_evf, "SEQSTART t_mono=%.6f pid=%d dur=%d\n",
                now_s(), (int)getpid(), duration);
        fflush(seq_evf);
    }

    dma_open();                     /* -M K: multi-slot RX (tick-proof); else legacy */
    seq_t0 = now_s();
    tlast = seq_t0;

    static unsigned char batchf[TX_BATCH * QPSK_PKT_BYTES_MAX];
    double tx_next = now_s();          /* air-frame pacing clock, as in the -G loop */
    while (running && now_s() - seq_t0 < duration) {
        if (!seq_rxonly) seq_tx_fill(&tx_seq, batchf, payload, &tx_next);
        /* LAYER B fix 2: when the QUEUED path is selected, drive it -- do not run the
         * bespoke legacy drain below. That drain uses rx_done()/rx_arm() (reset per
         * transfer), so with QPSK_SEQ_KEEPM=1 the earlier run set rx_multi but still
         * measured the LEGACY path while announcing the batched one. The tap scores
         * each raw slice pre-CRC from inside rx_pump_queued; the decoded return is
         * discarded because scoring already happened. */
        if (rx_queued) {
            unsigned char dummy[QPSK_PKT_BYTES_MAX];
            uint32_t dseq;
            int guard = rx_multi ? rx_multi * 2 : 2;
            /* LAYER B fix 4 (the underfeed): TOP THE TX UP BETWEEN DRAINED SLICES.
             * Filling once per outer iteration and then draining up to rx_multi*2
             * slices starves the transmitter: at F1536 tx_batch_max() is 5 frames
             * (16384 stride / 3080 B) and polled max_inflight is 2, so only ~10
             * frames -- about 8 ms of air -- are ever queued, while a full 64-slice
             * drain takes longer than that. Measured result was 482-555 f/s against
             * a 1245 f/s air rate (39-45% fed), so most air slots carried frames the
             * feeder never wrote, and the RX found no frame structure at any offset
             * in 3/3 gated attempts. Re-filling inside the drain keeps the air fed
             * regardless of how long scoring takes. */
            /* rx_pump_timed, not rx_pump_frame: the pump_us_max/loop_us_max
             * perturbation observables are otherwise structurally zero in -S,
             * which voided the first wedge_ckpt A/B */
            while (guard-- > 0 && rx_pump_timed(dummy, &dseq) > 0)
                if (!seq_rxonly) seq_tx_fill(&tx_seq, batchf, payload, &tx_next);
        } else if (rx_done()) {
            if (rx_multi) {
                /* tick-proof RX: one transfer spans rx_multi frames; a host
                 * stall (device-tick SPI/interconnect storms freeze this
                 * loop for 10-40 ms) must exceed rx_multi frame periods
                 * (~4.7 ms each) before anything is lost. Rearm the OTHER
                 * area BEFORE draining (the engine fills while we score;
                 * same principle as the -M bridge path). */
                unsigned done_area = (unsigned)rx_fill;
                rx_arm(1u - done_area);
                for (int i = 0; i < rx_multi; i++) {
                    unsigned char sframe[QPSK_PKT_BYTES_MAX];
                    carve_copy_from(sframe,
                        rx_area_virt(done_area) + (size_t)i * (size_t)pkt_bytes,
                        (size_t)pkt_bytes);                          /* carve -> local */
                    qpsk_seq_score_frame(&ss, sframe, now_s() - seq_t0);
                }
            } else {
                carve_copy_from(pkt, rx_area_virt(0), (size_t)pkt_bytes);  /* carve -> local */
                rx_arm(0);
                qpsk_seq_score_frame(&ss, pkt, now_s() - seq_t0);
            }
        }
        if (now_s() - tlast >= 5.0) {
            tlast = now_s();
            double ber = ss.total_bits
                ? (double)ss.total_bit_errors / (double)ss.total_bits : 0.0;
            /* LAYER B fix 3: show the TX rate against the air rate. The earlier run
             * fed 467 f/s into a 1245 f/s air frame, so most air frames carried no PN
             * and everything scored junk -- which looked like total link loss. An
             * under-fed transmitter must be visible, not inferred afterwards. */
            { double el = now_s() - seq_t0;
              if (el > 0)
                  fprintf(stderr, "seq: TXRATE %.0f f/s (air %.0f f/s -- %.0f%% fed)\n",
                          tx_seq / el, 1.0 / frame_period_s,
                          100.0 * (tx_seq / el) * frame_period_s); }
            fprintf(stderr,
                "seq: t=%.0fs tx=%u ok=%llu biterr=%llu lost=%llu dup=%llu "
                "junk=%llu BER=%.3e\n",
                now_s() - seq_t0, tx_seq, (unsigned long long)ss.ok,
                (unsigned long long)ss.biterr, (unsigned long long)ss.lost,
                (unsigned long long)ss.dup, (unsigned long long)ss.junk, ber);
            /* seq_run never reaches stats_dump(), so without these the rxq/ckpt
             * instruments are invisible in exactly the -S runs that need them */
#ifdef QPSK_RXQ_STAT
            rxq_stats_dump();
#endif
            ckpt_stats_dump();
        }
    }
    printf("SEQTX frames=%u dur=%.2f\n", tx_seq, now_s() - seq_t0);
    qpsk_seq_report(&ss, stdout, now_s() - seq_t0);
    if (ss.rawf) {
        fclose(ss.rawf);
        ss.rawf = NULL;
    }
    if (seq_evf) {
        fprintf(seq_evf, "SEQEND t_mono=%.6f\n", now_s());
        fclose(seq_evf);
        seq_evf = NULL;
    }
}

/* readlink /proc/self/fd/<fd> and copy the basename (e.g. "uio3") into buf */
static void uio_basename_of_fd(int fd, char *buf, size_t n)
{
    char lp[64];
    snprintf(lp, sizeof lp, "/proc/self/fd/%d", fd);
    char target[64];
    ssize_t r = readlink(lp, target, sizeof target - 1);
    if (r <= 0) { snprintf(buf, n, "uio?"); return; }
    target[r] = '\0';
    const char *base = strrchr(target, '/');
    base = base ? base + 1 : target;
    snprintf(buf, n, "%.*s", n ? (int)n - 1 : 0, base);
}

/* ---- IRQ (UIO) event loop ------------------------------------------------
 * Interrupt-driven counterpart to the polled main loop. Entered ONLY when both
 * qpsk_tx_dma and qpsk_rx_dma UIO nodes were found at startup (future image).
 * The polled loop in main() is left byte-for-byte untouched; this is a wholly
 * separate path. One blocking poll() over {tun A, [tun B], tx_uio, rx_uio}:
 *   - rx_uio readable -> read+ack, then (on completion) REARM THE OTHER AREA
 *     IMMEDIATELY, before draining the completed one -- this ordering kills the
 *     ~1/K rearm loss (the single S2MM engine is never idle for a drain window).
 *   - tx_uio readable -> read+ack, reap slots, refill (retx / keepalive).
 *   - tun A gated on tx_capacity() (backpressure); B-side reads dropped (RF is
 *     one-way here, reverse routed externally) exactly as in polled mode.
 * Poll timeout: ~1 frame period while a multi-transfer is in flight so the
 * eager mid-transfer CRC scan still runs (latency << K*frame_period); the
 * keepalive period when idle. */
static void run_irq_loop(int fda, int fdb, int nif, int max_read, int stats_int)
{
    unsigned char buf[QPSK_PKT_BYTES_MAX + 64];
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    uint32_t tx_seq = 0, last_rx_seq = 0;
    int have_rx = 0;
    double tlast = now_s();

    /* --- TX pacing (R0MEAS finding: submission overfill) ------------------
     * A TX EOT fires when the DMA lands the frame in the fabric FIFO, NOT
     * when it is radiated, so inflight-slot gating alone lets the loop
     * submit 53-70 f/s against a 19.5 f/s air drain: the FIFO overflows and
     * ~2/3 of frames (data racing idles) are silently dropped pre-air. Pace
     * submissions to the air rate instead: one credit per frame_period_s
     * (geometry-derived, so K5's 4.72 ms and F1536's ~51 ms both work), with
     * at most TX_PACE_LEAD periods of burst catch-up after a host stall --
     * enough to keep the modulator fed, never enough to overflow the FIFO.
     * Data preempts idle: the tun gate opens exactly when a credit matures,
     * and the keepalive sends (one) idle only on a credit no data claimed. */
    /* Catch-up window: at least 2 frame periods (the R0-proven margin; at K5's
     * 4.72 ms and F1536-R0's 51 ms periods that dominates), but never below
     * 32 ms -- at R2's 1.6 ms period a 2-frame window (3.2 ms) is SMALLER than
     * routine scheduler jitter (10 ms ticks), so the clamp fired constantly,
     * forgave credits, and the modulator micro-underran: measured 620.0 f/s
     * submitted vs 622.7 f/s drained -> per-frame phase discontinuities that
     * the R2 demod cannot ride (TXCHAR2 §4: peer CRC-fails ~100% while the
     * same TX decodes clean when the stream is continuous). Burst catch-up is
     * still bounded by tx_capacity() (TX_SLOTS inflight), so a larger window
     * cannot overflow the fabric FIFO. */
    double pace_lead = 2.0 * frame_period_s;
    if (pace_lead < 0.032)
        pace_lead = 0.032;
    double tx_next = now_s();

    /* non-blocking tun A: the paced credit-consumption path below does an
     * opportunistic read outside poll(); it must never block the loop. */
    {
        int fl = fcntl(fda, F_GETFL, 0);
        if (fl >= 0)
            (void)fcntl(fda, F_SETFL, fl | O_NONBLOCK);
    }

    /* fds: [0]=tun A, [1]=tun B (or -1), [2]=tx_uio, [3]=rx_uio */
    struct pollfd pfds[4] = {
        { .fd = fda,        .events = POLLIN },
        { .fd = (nif == 2) ? fdb : -1, .events = POLLIN },
        { .fd = tx_uio_fd,  .events = POLLIN },
        { .fd = rx_uio_fd,  .events = POLLIN },
    };
    const int TUNA = 0, TUNB = 1, TXU = 2, RXU = 3;

    while (running) {
#ifdef QPSK_RXQ_STAT
        { static double _lt = 0; double _n = now_s();
          if (_lt > 0) { double _us = (_n - _lt) * 1e6;
            rxq_loop_n++;
            if (_us > (double)rxq_loop_us_max) rxq_loop_us_max = (unsigned)_us;
            if (_us > 2000.0) rxq_loop_over2ms++; }
          _lt = _n; }
#endif
        if (dump_req) { dump_req = 0; stats_dump(); framelog_flush(); }
        framelog_service();

        /* only accept tun-A frames when the Tx DMA can take one AND a pacing
         * credit has matured (submission at the air rate, data first) */
        double pnow = now_s();
        int tx_credit = (pnow >= tx_next);
        pfds[TUNA].events = (short)((tx_capacity() && tx_credit) ? POLLIN : 0);

        /* ~1 frame period keeps the eager mid-transfer scan alive and bounds
         * completion latency; idle falls back to the same period (keepalive).
         * If the next pacing credit matures sooner, wake for it. HOSTPERF:
         * use ppoll for SUB-MILLISECOND precision -- at R3 the frame period
         * (0.803 ms) is below poll()'s 1 ms floor, which quantized wakeups to
         * ~1 kHz and delivered TX as alternating 1/2-frame bursts against a
         * 1245.5 f/s drain: the FIFO oscillated near empty and the resulting
         * air-stream micro-gaps CRC-killed the over-air link (internal
         * loopback clean, ROM clean, dma_tx at rate). Waking exactly at credit
         * maturation keeps the modulator feed smooth at any rate. */
        double tmo_s = frame_period_s;
        if (!tx_credit) {
            double dt = tx_next - pnow;
            if (dt < tmo_s) tmo_s = dt;
        }
        if (tmo_s < 0.0) tmo_s = 0.0;
        if (tmo_s > 1.0) tmo_s = 1.0;
        struct timespec tmo_ts;
        tmo_ts.tv_sec  = (time_t)tmo_s;
        tmo_ts.tv_nsec = (long)((tmo_s - (double)tmo_ts.tv_sec) * 1e9);
        if (tmo_ts.tv_nsec < 50000) tmo_ts.tv_nsec = 50000;   /* >=50 us floor */

        int pr = ppoll(pfds, 4, &tmo_ts, NULL);
        if (pr < 0 && errno != EINTR)
            break;

        /* --- RX interrupt: consume + ack, then handle completion --- */
        if (pfds[RXU].revents & POLLIN) {
            uint32_t irqcnt;
            ssize_t r = read(rx_uio_fd, &irqcnt, sizeof irqcnt);
            (void)r;
            dmac_irq_ack(&rxd, rx_uio_fd);
        }
        /* Rearm the OTHER area IMMEDIATELY on completion, BEFORE draining, so
         * the engine refills while we score (multi mode). Doing this here --
         * not inside rx_pump_frame's eager path -- is what removes the ~1/K
         * loss: without it the eager drain would delay the rearm by a whole
         * drain window. Legacy (rx_multi==0) keeps its own rearm-before-consume
         * inside rx_pump_frame. */
        if (rx_active && rx_multi && rx_queued) {
            /* queued mode: the next transfer is already in hardware; just flip +
             * hand the tail to the drainer (requeue happens at drain-complete). */
            if (rx_done_q(rx_fill))
                rx_q_on_complete();
        } else if (rx_active && rx_multi && rx_done()) {
            unsigned completed = rx_fill;
            int from = rx_fscan;
            double per = (now_s() - rx_t0) / (double)rx_multi;
            if (per > RX_PER_CAL_MIN && per < rx_per_cal_max)
                rx_pkt_s = 0.85 * rx_pkt_s + 0.15 * per;
            rx_arm(completed ^ 1u);            /* engine resumes at once; rx_fscan=0 */
            if (from < rx_multi) {
                rx_drain = (int)completed;
                rx_dscan = from;
            }
        }

        /* --- TX interrupt: consume + ack, reap completed slots --- */
        if (pfds[TXU].revents & POLLIN) {
            uint32_t irqcnt;
            ssize_t r = read(tx_uio_fd, &irqcnt, sizeof irqcnt);
            (void)r;
            dmac_irq_ack(&txd, tx_uio_fd);
        }
        tx_reap();

        /* --- tun A -> Tx DMA (gated above on tx_capacity + pacing credit) --- */
        if (pfds[TUNA].revents & POLLIN) {
            ssize_t n = read(fda, buf, sizeof buf);
            if (n > 0) {
                st.tun_a_rx++;
                if ((int)n > max_read) {
                    st.oversize++;
                } else {
                    qpsk_frame_encode(pkt, pkt_bytes, buf, (int)n, tx_seq);
                    if (arq_on || arq_x)
                        hist_store(tx_seq, pkt);
                    if (tx_send(pkt) == 0) {
                        double tn = now_s();
                        if (tx_next < tn - pace_lead)
                            tx_next = tn - pace_lead;
                        tx_next += frame_period_s;
                    }
                    tx_seq++;
                }
            }
        }
        /* --- tun B: reverse routed externally; count + drop (as polled) --- */
        if (nif == 2 && (pfds[TUNB].revents & POLLIN)) {
            ssize_t n = read(fdb, buf, sizeof buf);
            if (n > 0) {
                st.tun_b_rx++;
                st.b_side_drops++;
            }
        }

        /* --- drain all deliverable Rx frames (same ARQ semantics as polled) --- */
        {
            uint32_t seq;
            int m;
            while ((m = rx_pump_frame(out, &seq)) > 0) {
                st.frames_rx_ok++;
                framelog_record(1, seq);
                rx_tick++;
                if (arq_x) {
                    if (axr_is_nak(out, m)) { axr_parse_nak(out); continue; }
                    if (axr_note(seq)) {
                        if (write(fdb, out, (size_t)m) == m)
                            st.tun_b_tx++;
                        else
                            st.tun_drops++;
                    }
                } else if (arq_on) {
                    if (dedup_seen(seq)) {
                        st.dups++;
                    } else {
                        dedup_mark(seq);
                        if (have_rx && seq < last_rx_seq)
                            st.recovered++;
                        if (have_rx && seq > last_rx_seq + 1) {
                            st.seq_gaps++;
                            uint32_t miss = seq - last_rx_seq - 1;
                            if (miss > HIST_SZ / 2)
                                miss = HIST_SZ / 2;
                            for (uint32_t k = 1; k <= miss; k++)
                                retx_request(seq - k);
                        }
                        if (!have_rx || seq > last_rx_seq)
                            last_rx_seq = seq;
                        have_rx = 1;
                        if (write(fdb, out, (size_t)m) == m)
                            st.tun_b_tx++;
                        else
                            st.tun_drops++;
                    }
                } else {
                    if (have_rx && seq != last_rx_seq + 1)
                        st.seq_gaps++;
                    last_rx_seq = seq;
                    have_rx = 1;
                    if (write(fdb, out, (size_t)m) == m)
                        st.tun_b_tx++;
                    else
                        st.tun_drops++;
                }
            }
            if (arq_on || arq_x)
                retx_pump(&tx_next);
            if (arq_x)
                axr_pump(&tx_seq, &tx_next);

            /* PACED credit consumption: when a credit has matured and no
             * poll-admitted data claimed it, offer it to tun DATA FIRST via a
             * non-blocking read (the credit usually matures via poll timeout,
             * so the gated tun fd had no chance to report POLLIN this cycle --
             * without this, the keepalive claims every credit at the loop
             * bottom and data is starved to ~0). Idle keepalive only when the
             * tun ring is genuinely empty at the credit instant. (The old
             * unpaced while-fill submitted 53-70 f/s against the 19.5 f/s air
             * drain -- fabric TX FIFO overflow silently dropped ~2/3 of
             * frames: the R0MEAS ping-loss / seconds-RTT / goodput-gap root
             * cause. pace_lead bounds burst catch-up across host stalls.) */
            /* Drain ALL matured credits this wakeup, data first. HOSTPERF:
             * poll's 1 ms timeout floor caps wakeups at ~1 kHz; sending one
             * frame per wakeup capped TX at ~877 f/s against R3's 1245.5 f/s
             * drain (the R3 byte-link killer). At R3 ~1.25 credits mature per
             * wakeup -- send them all (bounded by tx_capacity / TX_SLOTS). */
            /* (tx_used_credit no longer gates this: with multiple credits per
             * wakeup the poll-admitted data frame consumed only one) */
            while (tx_capacity() && now_s() >= tx_next) {
                ssize_t n = read(fda, buf, sizeof buf);   /* fda O_NONBLOCK */
                if (n > 0) {
                    st.tun_a_rx++;
                    if ((int)n > max_read) {
                        st.oversize++;
                    } else {
                        qpsk_frame_encode(pkt, pkt_bytes, buf, (int)n, tx_seq);
                        if (arq_on || arq_x)
                            hist_store(tx_seq, pkt);
                        if (tx_send(pkt) == 0) {
                            double tn = now_s();
                            if (tx_next < tn - pace_lead)
                                tx_next = tn - pace_lead;
                            tx_next += frame_period_s;
                        } else
                            break;
                        tx_seq++;
                    }
                } else if (k5_mode) {
                    int nb = 1;
                    if (tx_idle_batch > 1) {
                        static unsigned char idles[TX_BATCH * QPSK_PKT_BYTES_MAX];
                        nb = tx_idle_batch < tx_batch_max() ? tx_idle_batch : tx_batch_max();
                        for (int f = 0; f < nb; f++)
                            qpsk_frame_encode(idles + f * pkt_bytes, pkt_bytes, NULL, 0, tx_seq);
                        if (tx_send_batch(idles, nb) != 0)
                            break;
                    } else {
                        unsigned char idle[QPSK_PKT_BYTES_MAX];
                        qpsk_frame_encode(idle, pkt_bytes, NULL, 0, tx_seq);
                        if (tx_send(idle) != 0)
                            break;
                    }
                    st.idle_tx += (uint64_t)nb;
                    double tn = now_s();
                    if (tx_next < tn - pace_lead)
                        tx_next = tn - pace_lead;
                    tx_next += (double)nb * frame_period_s;
                } else
                    break;
            }
        }

        if (stats_int > 0 && now_s() - tlast >= stats_int) {
            tlast = now_s();
            stats_dump();
        }
    }
}

int main(int argc, char **argv)
{
    const char *ifnames[2] = {NULL, NULL};
    int nif = 0, tap = 0, loopback = 0, echo = 0;
    int mtu = 0, stats_int = 0, duration = 60;
    int p_set = 0, arq_force = 0, ber = 0, selftest = 0, seqmode = 0;
    int opt;

    while ((opt = getopt(argc, argv, "i:tlFGeBSTRAp:M:m:s:d:r:h")) != -1) {
        switch (opt) {
        case 'i':
            if (nif < 2) ifnames[nif++] = optarg;
            break;
        case 't': tap = 1; break;
        case 'l': loopback = 1; break;
        case 'F': k5_mode = 1; break;
        case 'G': f1536_mode = 1; break;
        case 'e': echo = 1; break;
        case 'B': ber = 1; k5_mode = 1; break;   /* BER mode uses K5 geometry */
        case 'S': seqmode = 1; break; /* geometry chosen below: K5 unless f1536 */
        case 'T': selftest = 1; break;
        case 'R': arq_on = 0; break;
        case 'A': arq_force = 1; break;
        case 'p': pkt_bytes = atoi(optarg); p_set = 1; break;
        case 'M': rx_multi = atoi(optarg); break;
        case 'm': mtu = atoi(optarg); break;
        case 's': stats_int = atoi(optarg); break;
        case 'd': duration = atoi(optarg); break;
        case 'r': rate_ksym = atof(optarg); break;
        default: usage(argv[0]);
        }
    }
    if (selftest) {                     /* no hardware, no geometry needed */
        int rc = qpsk_ber_selftest();
        return rc ? rc : qpsk_seq_selftest();
    }
    /* QPSK_FRAME=f1536 (env, matching the MATLAB frame_config_k5 selector)
     * is an alternate trigger for the same mode as -G. QPSK_RATE_KSYM mirrors
     * -r. Explicit flags/env checked here so either style works. */
    { const char *e;
      if ((e = getenv("QPSK_FRAME")) && strcmp(e, "f1536") == 0)
          f1536_mode = 1;
      if ((e = getenv("QPSK_RATE_KSYM")))
          rate_ksym = atof(e);
    }
    if (rate_ksym <= 0.0)
        rate_ksym = RATE_KSYM_DEFAULT;
    /* -S defaults to K5 geometry for backward compatibility, but may run at f1536
     * (R3) -- which is the whole point of LAYER B: the DMA fault is an R3 phenomenon. */
    if (seqmode && !f1536_mode)
        k5_mode = 1;
    /* -B keeps the legacy single-packet RX. -S does too UNLESS QPSK_SEQ_KEEPM=1, which
     * keeps the multi-slot/queued path so the PN stream actually traverses the batched
     * DMA under test. Without this, -S bypasses the very path we are bisecting. */
    { const char *e = getenv("QPSK_SEQ_KEEPM");
      int keepm = seqmode && e && atoi(e) != 0;
      if (ber || (seqmode && !keepm))
          rx_multi = 0;
      if (keepm)
          fprintf(stderr, "LAYER B: -S keeping multi-slot RX (-M %d) -- PN stream "
                          "traverses the batched DMA path\n", rx_multi); }
    if (f1536_mode && k5_mode && !seqmode) {
        fprintf(stderr, "-F (K5) and -G/QPSK_FRAME=f1536 are mutually exclusive\n");
        return 2;
    }
    if (f1536_mode) {
#ifndef QPSK_CARVE_2MB
        fprintf(stderr, "F1536 mode needs the 2 MB carve layout -- rebuild with "
                        "-DQPSK_CARVE_2MB (the deployed 1 MB carve only fits the "
                        "K5 geometry)\n");
        return 2;
#endif
        if (!p_set)
            pkt_bytes = F1536_PKT_BYTES;      /* 12 B header + <=1516 B payload */
        tx_xfer_bytes = F1536_TX_XFER_BYTES;  /* pad TX to the 385-word air frame */
        k5_mode = 1;                          /* shares K5's two-radio bridging:
                                               * idle keepalive, ARQ default off */
        arq_on = 0;                       /* in-process ARQ meaningless: 2 radios */
        if (arq_force) {                  /* -A = CROSS-LINK NAK ARQ */
            arq_x = 1;
            axr_tune_from_env();
            fprintf(stderr, "cross-link NAK ARQ ON (hist=%u, holes=%u, renak=%u ticks, "
                    "tries=%u, clamp=%u)\n",
                    HIST_SZ, axr_hole_sz, axr_renak, axr_nak_tries, axr_gap_clamp);
        }
    } else if (k5_mode) {
        if (!p_set)
            pkt_bytes = K5_PKT_BYTES;   /* 12 B header + <=116 B payload */
        tx_xfer_bytes = K5_TX_XFER_BYTES;  /* pad TX to the 35-word air frame */
        /* the in-process ARQ needs both RF endpoints in this process;
         * across two radios it is meaningless -- default it off (code
         * stays; -A now enables the CROSS-LINK NAK ARQ instead) */
        arq_on = 0;
        if (arq_force) {
            arq_x = 1;
            axr_tune_from_env();
            fprintf(stderr, "cross-link NAK ARQ ON (hist=%u, holes=%u, renak=%u ticks, "
                    "tries=%u, clamp=%u)\n",
                    HIST_SZ, axr_hole_sz, axr_renak, axr_nak_tries, axr_gap_clamp);
        }
    }
    /* frame period is DERIVED from the selected profile's payload bits and
     * rate_ksym (240k default) -- never hardcoded per mode. Used for the rx
     * period calibration seed, the IRQ event-loop poll timeout, and the
     * calibration window's upper bound below. */
    {
        int payload_bits = f1536_mode ? F1536_PAYLOAD_BITS : K5_PAYLOAD_BITS;
        frame_period_s = ((double)payload_bits / 2.0 + BARKER_SYMS)
                        / (rate_ksym * 1000.0);
    }
    if (k5_mode || f1536_mode)
        rx_pkt_s = frame_period_s;      /* initial rx period estimate */
    /* F1536's frame period (~51 ms at the 240k default) exceeds the legacy
     * 8 ms calibration ceiling by design -- scale it up for f1536 only; every
     * other profile keeps the historical 8e-3 bound exactly. */
    rx_per_cal_max = f1536_mode ? frame_period_s * 1.7 : RX_PER_CAL_MAX;
    if (pkt_bytes < QPSK_FRAME_HDR_BYTES + 1 || pkt_bytes > QPSK_PKT_BYTES_MAX ||
        pkt_bytes % 8 != 0) {
        fprintf(stderr, "bad -p (need multiple of 8, %d..%d)\n",
            QPSK_FRAME_HDR_BYTES + 8, QPSK_PKT_BYTES_MAX);
        return 2;
    }
    /* the RX ring's per-slot size is a COMPILE-TIME carve choice (qpsk_hw.h);
     * a pkt_bytes that doesn't fit means the wrong carve was built for this
     * frame size (F1536 needs -DQPSK_CARVE_2MB; refused above already, but a
     * custom -p size can hit this on either carve). */
    if ((uint32_t)pkt_bytes > SLOT_BYTES) {
        fprintf(stderr, "pkt_bytes %d exceeds SLOT_BYTES %u -- rebuild with "
                        "-DQPSK_CARVE_2MB for frames this large\n",
                pkt_bytes, SLOT_BYTES);
        return 2;
    }
    if (tx_xfer_bytes <= 0)
        tx_xfer_bytes = pkt_bytes;      /* non-K5/F1536: TX transfer == logical frame */
    if (tx_xfer_bytes < pkt_bytes || tx_xfer_bytes > (int)TX_BATCH_STRIDE ||
        tx_xfer_bytes % 8 != 0) {
        fprintf(stderr, "bad tx_xfer_bytes %d (need pkt_bytes..%u, mult of 8)\n",
            tx_xfer_bytes, TX_BATCH_STRIDE);
        return 2;
    }
    /* TX single-shot slot stride: SLOT_BYTES is enough for every profile up
     * to K5 (280 B air frame); F1536's 3080 B air frame needs the bigger
     * TX_BATCH_STRIDE (already sized with headroom for TX_BATCH frames, so it
     * always has room for one). Picking the smallest stride that fits keeps
     * the K5/legacy ring layout byte-for-byte unchanged. */
    tx_slot_stride = ((uint32_t)tx_xfer_bytes <= SLOT_BYTES) ? SLOT_BYTES : TX_BATCH_STRIDE;
    if (rx_multi < 0 || rx_multi > RX_MULTI_MAX ||
        (rx_multi > 0 && rx_multi * pkt_bytes > RX_MULTI_MAX * (int)SLOT_BYTES)) {
        fprintf(stderr, "bad -M (0..%d, K*pkt <= %u bytes)\n",
            RX_MULTI_MAX, RX_MULTI_MAX * SLOT_BYTES);
        return 2;
    }
    /* Gate -M multi-packet RX on POSITIVE evidence that the byte_ctrl_gpio
     * exists (a claimed 9d300000 region or a qpsk_byte_gpio UIO node), instead
     * of a blind /dev/mem read-probe. Without the GPIO, multi mode's TLAST gate
     * write in dma_open() would be a blind poke at an absent peripheral, so fall
     * back to legacy per-packet RX. On the current byte image the GPIO IS
     * present, so this is a no-op there (multi stays available). */
    if (rx_multi > 0 && !qpsk_gpio_present()) {
        fprintf(stderr, "no byte_ctrl_gpio (9d300000) present -- "
                        "falling back to legacy per-packet RX (-M ignored)\n");
        rx_multi = 0;
    }
    { const char *e;
      if ((e = getenv("QPSK_SPIN_W"))) rx_spin_w = atoi(e);
      if ((e = getenv("QPSK_NAP_US"))) rx_nap_us = atoi(e);
      if ((e = getenv("QPSK_TX_QUEUED"))) { tx_idle_batch = atoi(e); if (tx_idle_batch < 0) tx_idle_batch = 0;
          if (tx_idle_batch > TX_BATCH) tx_idle_batch = TX_BATCH;
          fprintf(stderr, "qpsk_tun: TX idle batching ON: %d idle air frames per transfer (QPSK_TX_QUEUED)\n", tx_idle_batch); }
      if (rx_spin_w < 1) rx_spin_w = 1;
      if (rx_spin_w > RX_MULTI_MAX) rx_spin_w = RX_MULTI_MAX;
      if (rx_nap_us < 1) rx_nap_us = 1; }
    /* QPSK_RX_CYCLIC=1: cyclic-ring RX (needs a CONFIG.CYCLIC 1 bitstream). Requires
     * multi-drain (-M K>0). Default off -> legacy per-transfer rx_arm/rx_pump_frame.
     * WARNING: on a CYCLIC-0 bitstream FLAGS bit0 is masked to 0, so the one-time arm
     * receives exactly one transfer then stops -> RX dies after one ring. Only enable
     * against a bitstream built with axi_adrv9001_rx1_dma CONFIG.CYCLIC 1. */
    { const char *e = getenv("QPSK_RX_CYCLIC");
      rx_cyclic = (e && atoi(e) != 0);
      if (rx_cyclic && !rx_multi) {
          fprintf(stderr, "QPSK_RX_CYCLIC requires multi-drain (-M K>0) -- ignoring\n");
          rx_cyclic = 0;
      }
      if (rx_cyclic)
          fprintf(stderr, "RX cyclic-ring mode ON -- REQUIRES a CONFIG.CYCLIC 1 bitstream\n"); }
    /* QPSK_RX_QUEUED=1: queued-request RX (works on the CURRENT bitstream -- the
     * axi_dmac's native one-ahead request queue; see rx_arm_queued). Removes the
     * per-transfer-boundary reset window (~2% lag-M loss). Requires -M K>0; mutually
     * exclusive with QPSK_RX_CYCLIC. Default off = legacy reset-per-transfer path. */
    { const char *e = getenv("QPSK_RX_QUEUED");
      rx_queued = (e && atoi(e) != 0);
      if (rx_queued && rx_cyclic) {
          fprintf(stderr, "QPSK_RX_QUEUED ignored (QPSK_RX_CYCLIC already selected)\n");
          rx_queued = 0;
      }
      if (rx_queued && !rx_multi) {
          fprintf(stderr, "QPSK_RX_QUEUED requires multi-drain (-M K>0) -- ignoring\n");
          rx_queued = 0;
      }
      if (rx_queued) {
          if ((e = getenv("QPSK_RX_AREAS")) && atoi(e) >= 2) {
              int n = atoi(e);
              if (n > RX_AREAS_MAX) n = RX_AREAS_MAX;
              /* each area must still hold a whole M-slot batch */
              { uint32_t span = (uint32_t)(2u * RX_MULTI_MAX * SLOT_BYTES) / (uint32_t)n;
                if ((uint32_t)(rx_multi * pkt_bytes) > span) {
                    fprintf(stderr, "QPSK_RX_AREAS=%d needs %u B/area but only %u B "
                            "available -- staying at 2\n", n,
                            (unsigned)(rx_multi * pkt_bytes), span);
                } else {
                    rx_nareas = n;
                    fprintf(stderr, "RX queued ring: %d areas x %d slots "
                            "(%u B/area) -- re-arm decoupled from drain\n",
                            rx_nareas, rx_multi, span);
                } }
          }
#ifdef QPSK_RXQ_STAT
          if ((e = getenv("QPSK_RXQ_ZEROHDR")) && atoi(e) != 0) {
              rxq_zerohdr = 1;
              fprintf(stderr, "RXQ EXPERIMENT: header-only pre-submit zero\n");
          }
          if ((e = getenv("QPSK_RXQ_REREAD")) && atoi(e) != 0) {
              rxq_reread = 1;
              fprintf(stderr, "RXQ EXPERIMENT: re-read on drain CRC failure\n");
          }
          if ((e = getenv("QPSK_RXQ_DRAINDELAY_US")) && atoi(e) > 0) {
              rxq_drain_delay_us = atoi(e);
              fprintf(stderr, "RXQ EXPERIMENT: drain delay %d us/slice\n",
                      rxq_drain_delay_us);
          }
#endif
          if ((e = getenv("QPSK_RX_DELIV_WDOG_S")) && atof(e) > 0)
              rx_q_deliv_wdog_s = atof(e);
          if ((e = getenv("QPSK_RX_DRAIN_BUDGET")) && atoi(e) >= 0) {
              rx_drain_budget = atoi(e);
          }
          fprintf(stderr, "RX drain budget: %d slices/pump call (0 = unbounded; "
                  "TX can be fed between chunks)\n", rx_drain_budget);
          if ((e = getenv("QPSK_CKPT")) && atoi(e) != 0) {
              ck_en = 1;
              if ((e = getenv("QPSK_CKPT_N")) && atoi(e) > 0)
                  ck_every = (unsigned)atoi(e);
              fprintf(stderr, "SEAM CKPT: CP2 (carve) / CP3 (copy) count+checksum on "
                      "the queued drain, every %u slice(s)\n", ck_every);
          }
          if ((e = getenv("QPSK_RX_WDOG_S")) && atof(e) > 0)
              rx_q_wdog_s = atof(e);
          fprintf(stderr, "RX queued-request mode ON (no reset between transfers; wdog %.1fs)\n",
                  rx_q_wdog_s);
      } }
    if (mtu == 0)
        mtu = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);
    if (mtu < 1 || mtu > QPSK_FRAME_MAX_PAYLOAD(pkt_bytes)) {
        fprintf(stderr, "mtu must be 1..%d\n", QPSK_FRAME_MAX_PAYLOAD(pkt_bytes));
        return 2;
    }

    signal(SIGINT, on_term);
    signal(SIGTERM, on_term);
    signal(SIGUSR1, on_usr1);
    signal(SIGPIPE, SIG_IGN);

    /* Per-frame telemetry logger (opt-in; default-disabled -> no behavior
     * change). Open the sink before any mode runs; the modem BAR is mapped
     * later in dma_open(). SIGUSR2 (rotate) is installed ONLY when enabled so
     * the default SIGUSR2 disposition is unchanged. See the QPSK_FRAMELOG
     * block above. */
    { const char *e = getenv("QPSK_FSLOG");
      if (e && *e) {
          fslog_buf = calloc(FSLOG_N, sizeof *fslog_buf);
          if (fslog_buf) {
              fslog_path = e;
              atexit(fslog_dump);
              fprintf(stderr, "QPSK_FSLOG: CP1 comparator, ring of last %u slices -> %s\n",
                      FSLOG_N, e);
          }
      } }
    { const char *e = getenv("QPSK_TXLOG");
      if (e && *e) {
          txlog_buf = calloc(TXLOG_N, sizeof *txlog_buf);
          if (txlog_buf) {
              txlog_path = e;
              atexit(txlog_dump);
              fprintf(stderr, "QPSK_TXLOG: ring of last %u tx submits -> %s\n",
                      TXLOG_N, e);
          }
      } }
    { const char *e = getenv("QPSK_FRAMELOG");
      if (e && *e) {
          framelog_path = e;
          framelog_fp = fopen(framelog_path, "ab");   /* append across runs */
          if (!framelog_fp) {
              fprintf(stderr, "QPSK_FRAMELOG %s: %s\n", framelog_path, strerror(errno));
              return 2;
          }
          setvbuf(framelog_fp, NULL, _IOFBF, 1u << 20);
          signal(SIGUSR2, on_usr2);                   /* rotate (only when enabled) */
          atexit(framelog_close);
          fprintf(stderr, "framelog: %s (48 B/frame)\n", framelog_path);
      } }

    if (ber) {
        ber_run(duration);
        return 0;
    }
    if (seqmode) {
        seq_run(duration);
        return 0;
    }
    if (echo) {
        echo_mode(duration);
        return 0;
    }
    /* loopback bridges two interfaces in-process; DMA mode accepts one
     * (two-radio: the single tun fd carries both directions) or two
     * (single-board legacy A->B) */
    if (loopback ? (nif != 2) : (nif < 1))
        usage(argv[0]);

    memset(dedup_ring, 0xFF, sizeof dedup_ring); /* 0 is a valid seq */

    /* IRQ-vs-polled selection (DMA bridge only; loopback has no DMA). Both
     * qpsk_tx_dma and qpsk_rx_dma UIO nodes must be present for IRQ mode; else
     * fall back to the byte-for-byte-identical polled path. QPSK_FORCE_POLLED=1
     * forces the fallback even when the nodes exist. This runs BEFORE dma_open()
     * so the first engine reset applies the correct IRQ_MASK. */
    if (!loopback) {
        const char *fp = getenv("QPSK_FORCE_POLLED");
        int forced = fp && atoi(fp) == 1;
        if (rx_cyclic && !forced) {
            /* Non-SG cyclic raises NO EOT IRQ ever (HOST_RING_REWRITE.md sect 0):
             * the IRQ event loop would block forever waiting for RX interrupts.
             * Measured 2026-08-12 (cycab_213522: one ring lap of records, then
             * the reader never ran again; the manual devmem probe showed the
             * engine itself re-issuing at line rate). Cyclic forces polled. */
            fprintf(stderr, "QPSK_RX_CYCLIC: no EOT IRQ in cyclic mode -- forcing POLLED\n");
            forced = 1;
        }
        if (!forced) {
            int t = qpsk_uio_open("qpsk_tx_dma");
            int r = qpsk_uio_open("qpsk_rx_dma");
            if (t >= 0 && r >= 0) {
                irq_mode = 1;
                tx_uio_fd = t;
                rx_uio_fd = r;
                max_inflight = (int)TX_SLOTS;   /* use all TX slots in IRQ mode */
                char tn[32], rn[32];
                uio_basename_of_fd(t, tn, sizeof tn);
                uio_basename_of_fd(r, rn, sizeof rn);
                fprintf(stderr, "irq mode: %s/%s\n", tn, rn);
            } else {
                if (t >= 0) close(t);
                if (r >= 0) close(r);
                fprintf(stderr, "no UIO nodes, polled mode\n");
            }
        } else {
            fprintf(stderr, "QPSK_FORCE_POLLED=1, polled mode\n");
        }
    }

    int fda = tun_alloc(ifnames[0], tap);
    int fdb = (nif == 2) ? tun_alloc(ifnames[1], tap) : fda;
    if (!loopback)
        dma_open();
    /* setup scripts wait for this line before moving ifaces into netns */
    if (nif == 2)
        printf("READY %s %s\n", ifnames[0], ifnames[1]);
    else
        printf("READY %s\n", ifnames[0]);
    fflush(stdout);

    /* TAP frames carry a 14-byte ethernet header on top of the payload MTU */
    int max_read = mtu + (tap ? 14 : 0);
    if (max_read > QPSK_FRAME_MAX_PAYLOAD(pkt_bytes))
        max_read = QPSK_FRAME_MAX_PAYLOAD(pkt_bytes);

    /* IRQ mode runs its own event loop; the polled loop below is left exactly
     * as it was (the safety net for a board on the current image). */
    if (irq_mode) {
        run_irq_loop(fda, fdb, nif, max_read, stats_int);
        if (rx_multi && gpio_regs)
            gpio_regs[0] = 1;   /* restore legacy per-packet TLAST (as polled) */
        stats_dump();
        return 0;
    }

    unsigned char buf[QPSK_PKT_BYTES_MAX + 64];
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char out[QPSK_PKT_BYTES_MAX];
    uint32_t tx_seq = 0, last_rx_seq = 0;
    int have_rx = 0;
    double tlast = now_s();

    struct pollfd pfds[2] = {
        { .fd = fda, .events = POLLIN },
        /* single-interface mode: no B side; poll ignores negative fds */
        { .fd = (nif == 2) ? fdb : -1, .events = POLLIN },
    };

    while (running) {
#ifdef QPSK_RXQ_STAT
        { static double _lt = 0; double _n = now_s();
          if (_lt > 0) { double _us = (_n - _lt) * 1e6;
            rxq_loop_n++;
            if (_us > (double)rxq_loop_us_max) rxq_loop_us_max = (unsigned)_us;
            if (_us > 2000.0) rxq_loop_over2ms++; }
          _lt = _n; }
#endif
        if (dump_req) { dump_req = 0; stats_dump(); framelog_flush(); }
        framelog_service();

        /* only read the A side when the Tx DMA can take a frame; spin
         * only when the rx rearm window demands it */
        pfds[0].events = (short)((loopback || tx_capacity()) ? POLLIN : 0);
        int pr = poll(pfds, 2, loopback ? 50 : 0);
        if (pr < 0 && errno != EINTR)
            break;

        if (pfds[0].revents & POLLIN) {
            ssize_t n = read(fda, buf, sizeof buf);
            if (n > 0) {
                st.tun_a_rx++;
                if ((int)n > max_read) {
                    st.oversize++;
                } else {
                    qpsk_frame_encode(pkt, pkt_bytes, buf, (int)n, tx_seq);
                    if (loopback) {
                        uint32_t seq;
                        int m = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
                        if (m > 0 && write(fdb, out, (size_t)m) == m)
                            st.tun_b_tx++;
                        st.frames_tx++;
                        st.frames_rx_ok++;
                    } else {
                        if (arq_on || arq_x)
                            hist_store(tx_seq, pkt);
                        (void)tx_send(pkt);
                    }
                    tx_seq++;
                }
            }
        }

        if (pfds[1].revents & POLLIN) {
            ssize_t n = read(fdb, buf, sizeof buf);
            if (n > 0) {
                st.tun_b_rx++;
                if (loopback) {
                    if ((int)n <= max_read) {
                        qpsk_frame_encode(pkt, pkt_bytes, buf, (int)n, tx_seq++);
                        uint32_t seq;
                        int m = qpsk_frame_decode(pkt, pkt_bytes, out, &seq);
                        if (m > 0 && write(fda, out, (size_t)m) == m)
                            st.tun_a_tx++;
                    }
                } else {
                    /* reverse path is routed externally; RF is one-way here */
                    st.b_side_drops++;
                }
            }
        }

        if (!loopback) {
            uint32_t seq;
            int m;
            /* drain everything deliverable this iteration (the poll may
             * sleep ~1 ms in multi mode) */
            while ((m = rx_pump_timed(out, &seq)) > 0) {
                st.frames_rx_ok++;
                framelog_record(1, seq);
                rx_tick++;
                if (arq_x) {
                    if (axr_is_nak(out, m)) { axr_parse_nak(out); continue; }
                    if (axr_note(seq)) {
                        if (write(fdb, out, (size_t)m) == m)
                            st.tun_b_tx++;
                        else
                            st.tun_drops++;
                    }
                } else if (arq_on) {
                    if (dedup_seen(seq)) {
                        st.dups++;
                    } else {
                        dedup_mark(seq);
                        if (have_rx && seq < last_rx_seq)
                            st.recovered++; /* a retransmit filled a gap */
                        if (have_rx && seq > last_rx_seq + 1) {
                            st.seq_gaps++;
                            uint32_t miss = seq - last_rx_seq - 1;
                            if (miss > HIST_SZ / 2)
                                miss = HIST_SZ / 2;
                            for (uint32_t k = 1; k <= miss; k++)
                                retx_request(seq - k);
                        }
                        if (!have_rx || seq > last_rx_seq)
                            last_rx_seq = seq;
                        have_rx = 1;
                        if (write(fdb, out, (size_t)m) == m)
                            st.tun_b_tx++;
                        else
                            st.tun_drops++;
                    }
                } else {
                    if (have_rx && seq != last_rx_seq + 1)
                        st.seq_gaps++;
                    last_rx_seq = seq;
                    have_rx = 1;
                    if (write(fdb, out, (size_t)m) == m)
                        st.tun_b_tx++;
                    else
                        st.tun_drops++;
                }
            }
            if (arq_on || arq_x)
                retx_pump(NULL);          /* polled loop: legacy unpaced TX */
            if (arq_x)
                axr_pump(&tx_seq, NULL);

            /* -F idle-frame keepalive: when the tun is quiet the Tx byte path
             * starves and the fabric mux can underfill (the historical CW-tone
             * class). Push len=0 frames (valid CRC) so the encoder/modulator
             * cadence never starves. Idle frames reuse the current tx_seq
             * WITHOUT consuming it -- the peer ignores idle seq, and data seqs
             * stay contiguous for its gap accounting. */
            if (k5_mode) {
                /* Fill the Tx FIFO with idle frames so the modulator is fed
                 * CONTINUOUSLY (no dead-air gaps between frames). A gap-free
                 * carrier is what lets the peer's AGC/carrier-sync ACQUIRE and
                 * HOLD lock -- the old rate-limit (one idle per K5_FRAME_S) left
                 * inter-frame gaps that kept the peer from locking on an idle
                 * link. Real tun data still preempts via the poll path above; it
                 * waits at most a few frame periods for FIFO room. */
                while (tx_capacity()) {
                    if (tx_idle_batch > 1) {
                        /* QPSK_TX_QUEUED=N: N idle air frames per transfer (see tx_send) */
                        static unsigned char idles[TX_BATCH * QPSK_PKT_BYTES_MAX];
                        int nb = tx_idle_batch < tx_batch_max() ? tx_idle_batch : tx_batch_max();
                        for (int f = 0; f < nb; f++)
                            qpsk_frame_encode(idles + f * pkt_bytes, pkt_bytes, NULL, 0, tx_seq);
                        if (tx_send_batch(idles, nb) != 0) break;
                        st.idle_tx += (uint64_t)nb;
                        continue;
                    }
                    unsigned char idle[QPSK_PKT_BYTES_MAX];
                    qpsk_frame_encode(idle, pkt_bytes, NULL, 0, tx_seq);
                    if (tx_send(idle) != 0) break;
                    st.idle_tx++;
                }
            }
        }

        if (stats_int > 0 && now_s() - tlast >= stats_int) {
            tlast = now_s();
            stats_dump();
        }
        /* While the K-packet transfer is filling (multi mode), nap briefly
         * instead of spinning -- keeps CPU low but bounds the rearm latency
         * when the transfer completes (a 1 ms poll would drop ~1.6 packets
         * per transfer). Legacy and the drain/rearm windows spin. */
        if (!loopback && !rx_want_spin())
#ifdef QPSK_RXQ_STAT
            { double _n0 = now_s();
              usleep((useconds_t)rx_nap_us);
              { double _us = (now_s() - _n0) * 1e6;
                rxq_nap_n++; rxq_nap_us_sum += (unsigned long long)_us;
                if (_us > (double)rxq_nap_us_max) rxq_nap_us_max = (unsigned)_us;
                if (_us > 2000.0) rxq_nap_over2ms++; } }
#else
            usleep((useconds_t)rx_nap_us);
#endif
    }
    /* leave the bitstream in legacy per-packet TLAST mode so the MATLAB
     * ByteDmaRegisters path (and any later daemon in legacy mode) behaves
     * -- gpio is not cleared by the modem soft reset */
    if (rx_multi && gpio_regs)
        gpio_regs[0] = 1;
    stats_dump();
    return 0;
}
