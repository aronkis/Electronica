/* qpsk_hw.h -- board-specific physical addresses for the QPSK byte-DMA path.
 *
 * Defaults target the ZynqMP byte bitstream (Jupiter / ADRV9002-ZCU102): the
 * modem regfile + byte DMAs live in the 0x9D000000 master-interconnect space,
 * and the DMA ring buffers are carved from a reserved region near the top of
 * the 2 GB DDR map.
 *
 * Build for a different board at compile time:
 *   ZedBoard (Zynq-7000, xc7z020):   make CFLAGS+=-DQPSK_BOARD_ZED
 *     -> regs move to the Zynq-7000 GP0 window (0x40000000-0x7FFFFFFF) at
 *        0x43C..., and the DMA buffer carve moves into ZedBoard's 512 MB DDR
 *        (0x00000000-0x1FFFFFFF). These match the adrv9002/zed byte reference
 *        design (get_memory_axi_interface_info + matlab_processors.tcl zed case).
 *   Any single symbol can also be overridden directly, e.g.
 *     make CFLAGS+='-DQPSK_MODEM_BASE=0x60000000u'
 *
 * NOTE: the DMA buffer region must be reserved from Linux on the target (a
 * device-tree reserved-memory node at QPSK_DMA_BUF_BASE); this header only
 * fixes the address the userspace daemon mmaps.
 */
#ifndef QPSK_HW_H
#define QPSK_HW_H

#ifdef QPSK_BOARD_ZED
/* --- ZedBoard / Zynq-7000 (xc7z020) --- */
#  ifndef QPSK_MODEM_BASE
#    define QPSK_MODEM_BASE   0x43C00000u
#  endif
#  ifndef QPSK_TX_DMA_BASE
#    define QPSK_TX_DMA_BASE  0x43C10000u
#  endif
#  ifndef QPSK_RX_DMA_BASE
#    define QPSK_RX_DMA_BASE  0x43C20000u
#  endif
#  ifndef QPSK_GPIO_BASE
#    define QPSK_GPIO_BASE    0x43C30000u
#  endif
#  ifndef QPSK_DMA_BUF_BASE
#    define QPSK_DMA_BUF_BASE 0x1FF00000u   /* top 1 MB of ZedBoard 512 MB DDR */
#  endif
#else
/* --- ZynqMP default (Jupiter / ADRV9002-ZCU102) --- */
#  ifndef QPSK_MODEM_BASE
#    define QPSK_MODEM_BASE   0x9D000000u
#  endif
#  ifndef QPSK_TX_DMA_BASE
#    define QPSK_TX_DMA_BASE  0x9D100000u
#  endif
#  ifndef QPSK_RX_DMA_BASE
#    define QPSK_RX_DMA_BASE  0x9D200000u
#  endif
#  ifndef QPSK_GPIO_BASE
#    define QPSK_GPIO_BASE    0x9D300000u
#  endif
#  ifndef QPSK_DMA_BUF_BASE
#    ifdef QPSK_CARVE_2MB
#      define QPSK_DMA_BUF_BASE 0x7FE00000u /* NEW image: 2 MB carve (1536 B frames) */
#    else
#      define QPSK_DMA_BUF_BASE 0x7FF00000u /* deployed image: top 1 MB reserved */
#    endif
#  endif
#endif

/* Modem regfile offset of tx_data_source (0 = in-FPGA generator, 1 = DMA
 * bytes). The K5 (240k/K5) images move this register to 0x158 -- the legacy
 * 0x11C offset is reused by the K5 image as a debug sentinel, so a write to
 * 0x11C on a K5 image is silently meaningless. This define is the single
 * source of truth for the offset in the K5 host path (qpsk_capture.c;
 * qpsk_net_setup.sh and two_jup/byte_link_up.sh mirror it); never hardcode
 * 0x11C in K5-path code. Building against a legacy byte image:
 *   make CFLAGS+='-DQPSK_TX_DATA_SOURCE_OFF=0x11Cu'
 */
#ifndef QPSK_TX_DATA_SOURCE_OFF
#  define QPSK_TX_DATA_SOURCE_OFF 0x158u
#endif

/* iq_debug_mux (0x10C) tap selector -- ACTIVE on tap-enabled images
 * (iq_debug_tap_overlay): selects what the rx DMA's SECOND complex channel
 * (voltage1 = debugI/Q, 'IP Data 2/3 OUT') carries, sample-held at ADC rate
 * and sample-aligned with voltage0 (receiver-input IQ). */
#define QPSK_IQ_DEBUG_MUX_OFF   0x10Cu
#define QPSK_TAP_AGC_OUT        0u   /* post-AGC samples (reset default) */
#define QPSK_TAP_POST_SS        1u   /* post-symbol-sync symbols */
#define QPSK_TAP_POST_CS        2u   /* post-carrier-sync symbols */
#define QPSK_TAP_CONSTELLATION  3u   /* recovered constellation (pre-demod) */

/* boundary loop-state pair registers (tap-enabled images): packed stored-int
 * I/Q ((uint16 I)<<16 | uint16 Q, sfix16_En14 reinterpret), latched every
 * 4096th rail beat (~59 Hz). AGC gain = |out|/|in|; carrier NCO rotation =
 * angle(out * conj(in)). */
#define QPSK_STATE_AGC_IN_OFF   0x160u
#define QPSK_STATE_AGC_OUT_OFF  0x164u
#define QPSK_STATE_CS_IN_OFF    0x168u
#define QPSK_STATE_CS_OUT_OFF   0x16Cu

/* T8.5 canary regs (canary_instrumentation_overlay): shadow timing loop +
 * strobe forensic + beat counter. All clear on soft reset 0x000.
 * EXPECT pdiv/idiv == 0 in any simulation; nonzero on HW = direct physical
 * state-corruption observation. */
#define QPSK_SHDW_PDIV_CNT_OFF   0x170u /* P-path upset events (u32)        */
#define QPSK_SHDW_PDIV_BEAT_OFF  0x174u /* beat stamp of last P-path event  */
#define QPSK_SHDW_IDIV_BEAT_OFF  0x178u /* beat of FIRST integ divergence   */
#define QPSK_SHDW_IP_LATCH_OFF   0x17Cu /* primary integrator bits at idiv  */
#define QPSK_SHDW_IS_LATCH_OFF   0x180u /* shadow integrator bits at idiv   */
#define QPSK_STROBE_FORENSIC_OFF 0x184u /* {maxStrobeGap[31:16]|skip[15:0]} */
#define QPSK_BEAT_COUNTER_OFF    0x188u /* free-running rail-beat counter   */

/* T8.6 canary2 regs: path canary (graduated critical-path replicas) +
 * IC/carrier shadow extension. div regs: 0 = never diverged. */
#define QPSK_PATH_CANARY_OFF     0x18Cu /* {c5|c4|c3|c2} u8 sat counters    */
#define QPSK_IC_DIV_BEAT_OFF     0x190u /* IC shadow first-divergence beat  */
#define QPSK_IC_DIV_CNT_OFF      0x194u /* IC mismatch event count          */
#define QPSK_CS_LF_DIV_BEAT_OFF  0x198u /* carrier LF shadow first div beat */
#define QPSK_CS_LF_DIV_CNT_OFF   0x19Cu /* carrier LF divergence episodes   */
#define QPSK_NCO_DIV_BEAT_OFF    0x1A0u /* NCO twin-replica first div beat  */

/* ---- DMA slot geometry + carve layout -------------------------------------
 *
 * TWO carve layouts share this header, selected at COMPILE time:
 *
 *   DEFAULT (no -DQPSK_CARVE_2MB): the DEPLOYED-image layout. The current boot
 *     image reserves ONLY the top 1 MB (0x7FF00000..0x7FFFFFFF), so this MUST
 *     stay exactly as it was historically -- fixed offsets, SLOT_BYTES 1024.
 *     This is the polled fallback's safety net; it is byte-for-byte identical
 *     to prior builds. DO NOT change these values.
 *
 *   -DQPSK_CARVE_2MB: the NEW-image geometry for 1536 B frames. This ONE switch
 *     bundles: 2 MB carve based at 0x7FE00000, SLOT_BYTES 2048, TX batch stride
 *     16 KB, and size-DERIVED (stacked) sub-region offsets. Enabling it against
 *     the deployed image is unsafe -- the extra 1 MB is NOT reserved there and
 *     the DMA engines would scribble live kernel RAM. Only build with it once
 *     the 2 MB reserved-memory node is in the device tree.
 *
 * Per-rung K / inflight guidance (RX -M K multi-packet, TX MAX_INFLIGHT):
 *   In IRQ mode -M K is pure interrupt coalescing: one EOT interrupt per K
 *   frames. Latency <= K * frame_period (the eager mid-transfer CRC scan keeps
 *   effective latency well below that). Pick K so K*frame_period comfortably
 *   exceeds the worst host stall (device-tick storms freeze the loop 10-40 ms):
 *     240k5 (frame ~4.72 ms): K=16 -> ~75 ms coalesce window, robust; K=8 lean.
 *     1536 B / higher-rate rungs: raise K so K*frame_period stays >= ~50 ms.
 *   TX inflight: polled keeps MAX 2 (the silicon-tuned bounded-spin depth);
 *   IRQ mode raises it to TX_SLOTS (8) so ~8 air frames stay queued across a
 *   host stall (the Class-1 tick-loss origin). Both bounded by TX_SLOTS.
 */
#ifdef QPSK_CARVE_2MB
#  define QPSK_SLOT_BYTES      2048u
#  define QPSK_TX_BATCH_STRIDE 16384u
#else
#  define QPSK_SLOT_BYTES      1024u
#  define QPSK_TX_BATCH_STRIDE 4096u
#endif
#define QPSK_TX_SLOTS          8u
#define QPSK_RX_MULTI_MAX      64u

/* Sub-region SIZES (bytes). Used to DERIVE the 2 MB carve offsets by stacking,
 * so the layout stays consistent when SLOT_BYTES / strides change. */
#define QPSK_TX_REGION_BYTES         (QPSK_TX_SLOTS * QPSK_TX_BATCH_STRIDE)
#define QPSK_TUN_RX_REGION_BYTES     (2u * QPSK_RX_MULTI_MAX * QPSK_SLOT_BYTES)
#define QPSK_CAPTURE_RX_REGION_BYTES (512u * 1024u)

/* DMA ring sub-regions. The Tx ring sits at the carve base.
 *   2 MB carve : TX 128 KB, then tun-RX 256 KB, then capture 512 KB (stacked,
 *                size-derived -- no magic offsets, fits well inside 2 MB).
 *   deployed   : historical FIXED offsets (qpsk_capture +0x80000, qpsk_tun
 *                +0x40000) -- MUST NOT change (byte-for-byte on the 1 MB carve). */
#ifndef QPSK_TX_BUF_PHYS
#  define QPSK_TX_BUF_PHYS         (QPSK_DMA_BUF_BASE + 0x00000u)
#endif
#ifdef QPSK_CARVE_2MB
#  ifndef QPSK_TUN_RX_BUF_PHYS
#    define QPSK_TUN_RX_BUF_PHYS     (QPSK_TX_BUF_PHYS + QPSK_TX_REGION_BYTES)
#  endif
#  ifndef QPSK_CAPTURE_RX_BUF_PHYS
#    define QPSK_CAPTURE_RX_BUF_PHYS (QPSK_TUN_RX_BUF_PHYS + QPSK_TUN_RX_REGION_BYTES)
#  endif
#else
#  ifndef QPSK_CAPTURE_RX_BUF_PHYS
#    define QPSK_CAPTURE_RX_BUF_PHYS (QPSK_DMA_BUF_BASE + 0x80000u)
#  endif
#  ifndef QPSK_TUN_RX_BUF_PHYS
#    define QPSK_TUN_RX_BUF_PHYS     (QPSK_DMA_BUF_BASE + 0x40000u)
#  endif
#endif

#endif /* QPSK_HW_H */
