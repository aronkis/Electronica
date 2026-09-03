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

static void on_term(int s) { (void)s; running = 0; }
static void on_usr1(int s) { (void)s; dump_req = 1; }

static void stats_dump(void)
{
    fprintf(stderr,
        "qpsk_tun stats: tunA_rx=%llu tunA_tx=%llu tunB_rx=%llu tunB_tx=%llu "
        "dma_tx=%llu dma_rx_ok=%llu crc_drop=%llu seq_gap=%llu "
        "idle_tx=%llu idle_rx=%llu tun_drop=%llu "
        "oversize=%llu tx_stall=%llu b_drop=%llu "
        "retx=%llu dups=%llu recovered=%llu\n",
        (unsigned long long)st.tun_a_rx, (unsigned long long)st.tun_a_tx,
        (unsigned long long)st.tun_b_rx, (unsigned long long)st.tun_b_tx,
        (unsigned long long)st.frames_tx, (unsigned long long)st.frames_rx_ok,
        (unsigned long long)st.crc_drops, (unsigned long long)st.seq_gaps,
        (unsigned long long)st.idle_tx, (unsigned long long)st.idle_rx,
        (unsigned long long)st.tun_drops,
        (unsigned long long)st.oversize, (unsigned long long)st.tx_stalls,
        (unsigned long long)st.b_side_drops, (unsigned long long)st.retx,
        (unsigned long long)st.dups, (unsigned long long)st.recovered);
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
static int tx_send(const unsigned char *pkt)
{
    if (irq_mode) {
        if (!tx_capacity())
            return -1;             /* defer to the event loop */
    } else {
        int spins = 0;
        while (!tx_capacity()) {
            if (++spins > 20000) { st.tx_stalls++; return -1; } /* ~2 s */
            usleep(100);
        }
    }
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

static double now_s(void);             /* defined below */

static uint32_t rx_area_phys(unsigned area)
{
    return RX_BUF_PHYS + area * (uint32_t)(RX_MULTI_MAX * SLOT_BYTES);
}

static unsigned char *rx_area_virt(unsigned area)
{
    return rxbuf + area * (RX_MULTI_MAX * SLOT_BYTES);
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
static int rx_want_spin(void)
{
    if (!rx_multi)
        return 1;
    if (rx_drain >= 0 || rx_done())
        return 1;
    return (now_s() - rx_t0) >= (double)(rx_multi - rx_spin_w) * rx_pkt_s;
}

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
        if (m < 0) { st.crc_drops++; return 0; }
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
#define HIST_SZ    256u   /* power of two; > frames per episode + RTT */
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

/* resubmit queued seqs while the Tx DMA has capacity */
static void retx_pump(void)
{
    /* promote due second copies, skipping any already delivered (the
     * dedup ring is RX-side knowledge, but this is one process) */
    while (retx2_head != retx2_tail && rx_tick >= retx2q[retx2_head % RETXQ_SZ].due) {
        uint32_t s2 = retx2q[retx2_head % RETXQ_SZ].seq;
        if (!dedup_seen(s2))
            retx_request(s2);
        retx2_head++;
    }
    while (retxq_head != retxq_tail && tx_capacity()) {
        uint32_t seq = retxq[retxq_head++ % RETXQ_SZ];
        struct hist_ent *h = &tx_hist[seq % HIST_SZ];
        if (!h->valid || h->seq != seq || h->retries >= RETX_MAX)
            continue;
        h->retries++;
        if (tx_send(h->pkt) == 0) {
            st.retx++;
            if (h->retries == 1 && retx2_tail - retx2_head < RETXQ_SZ) {
                retx2q[retx2_tail % RETXQ_SZ].seq = seq;
                retx2q[retx2_tail % RETXQ_SZ].due = rx_tick + RETX2_DELAY;
                retx2_tail++;
            }
        }
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
            usleep((useconds_t)rx_nap_us);
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
        /* keep the modulator continuously fed with the reference frame */
        while (tx_capacity())
            if (tx_send(ref) != 0)
                break;
        /* legacy single-packet capture: rearm before scoring so the engine is
         * never idle during the scan, then score the RAW bytes */
        if (rx_done()) {
            carve_copy_from(pkt, rx_area_virt(0), (size_t)pkt_bytes);  /* carve -> local */
            rx_arm(0);
            qpsk_ber_score_frame(pkt, ref, &bs);
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
    qpsk_seq_reset(&ss, pkt_bytes);
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
    while (running && now_s() - seq_t0 < duration) {
        while (tx_capacity()) {
            int n = tx_batch_max();  /* TX_BATCH frames don't always fit one
                                     * TX_BATCH_STRIDE slot at F1536's larger
                                     * tx_xfer_bytes -- see tx_batch_max() */
            for (int f = 0; f < n; f++) {
                qpsk_seq_payload(payload, QPSK_SEQ_PAYLOAD_LEN, tx_seq + (uint32_t)f);
                qpsk_frame_encode(batchf + f * pkt_bytes, pkt_bytes, payload,
                                  QPSK_SEQ_PAYLOAD_LEN, tx_seq + (uint32_t)f);
            }
            if (tx_send_batch(batchf, n) != 0)
                break;
            tx_seq += (uint32_t)n;
        }
        if (rx_done()) {
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
            fprintf(stderr,
                "seq: t=%.0fs tx=%u ok=%llu biterr=%llu lost=%llu dup=%llu "
                "junk=%llu BER=%.3e\n",
                now_s() - seq_t0, tx_seq, (unsigned long long)ss.ok,
                (unsigned long long)ss.biterr, (unsigned long long)ss.lost,
                (unsigned long long)ss.dup, (unsigned long long)ss.junk, ber);
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
        if (dump_req) { dump_req = 0; stats_dump(); }

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
        if (rx_active && rx_multi && rx_done()) {
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
                    if (arq_on)
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
                rx_tick++;
                if (arq_on) {
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
            if (arq_on)
                retx_pump();

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
                        if (arq_on)
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
                    unsigned char idle[QPSK_PKT_BYTES_MAX];
                    qpsk_frame_encode(idle, pkt_bytes, NULL, 0, tx_seq);
                    if (tx_send(idle) != 0)
                        break;
                    st.idle_tx++;
                    double tn = now_s();
                    if (tx_next < tn - pace_lead)
                        tx_next = tn - pace_lead;
                    tx_next += frame_period_s;
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
        case 'S': seqmode = 1; k5_mode = 1; break; /* seq mode uses K5 geometry */
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
    if (ber || seqmode)
        rx_multi = 0;                   /* -B/-S use the legacy single-packet RX */
    if (f1536_mode && k5_mode) {
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
        if (!arq_force)
            arq_on = 0;
    } else if (k5_mode) {
        if (!p_set)
            pkt_bytes = K5_PKT_BYTES;   /* 12 B header + <=116 B payload */
        tx_xfer_bytes = K5_TX_XFER_BYTES;  /* pad TX to the 35-word air frame */
        /* the in-process ARQ needs both RF endpoints in this process;
         * across two radios it is meaningless -- default it off (code
         * stays; -A forces it for single-process experiments) */
        if (!arq_force)
            arq_on = 0;
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
      if (rx_spin_w < 1) rx_spin_w = 1;
      if (rx_spin_w > RX_MULTI_MAX) rx_spin_w = RX_MULTI_MAX;
      if (rx_nap_us < 1) rx_nap_us = 1; }
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
        if (dump_req) { dump_req = 0; stats_dump(); }

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
                        if (arq_on)
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
            while ((m = rx_pump_frame(out, &seq)) > 0) {
                st.frames_rx_ok++;
                rx_tick++;
                if (arq_on) {
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
            if (arq_on)
                retx_pump();

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
            usleep((useconds_t)rx_nap_us);
    }
    /* leave the bitstream in legacy per-packet TLAST mode so the MATLAB
     * ByteDmaRegisters path (and any later daemon in legacy mode) behaves
     * -- gpio is not cleared by the modem soft reset */
    if (rx_multi && gpio_regs)
        gpio_regs[0] = 1;
    stats_dump();
    return 0;
}
