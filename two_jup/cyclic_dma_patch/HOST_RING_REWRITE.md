# Host-side rewrite for a CYCLIC RX DMA (host_app_k5/qpsk_tun.c)

Scope: what the host must change to consume `axi_adrv9001_rx1_dma` once it is
synthesized with `CONFIG.CYCLIC 1`. Every hardware claim below is cited to the
IP source under
`jupiter_byte_lean_build/hdl_prj_jupiter_composite/vivado_ip_prj/library/axi_dmac/`.
Where the sources do not settle a question, that is stated explicitly.

--------------------------------------------------------------------------------
## 0. The load-bearing finding: simple cyclic mode gives NO completion signal
--------------------------------------------------------------------------------

This IP is built **non-scatter-gather** (`DMA_SG_TRANSFER = 0`, the default in
`axi_dmac_hw.tcl:215` and `axi_dmac.v:46`; system_bd.tcl sets no
`CONFIG.DMA_SG_TRANSFER`). Consequently `ctrl_hwdesc` can never be set:

    axi_dmac_regmap.v:228   ctrl_hwdesc <= up_wdata[2] & DMA_SG_TRANSFER;   // & 0 = 0

In cyclic mode with `ctrl_hwdesc == 0`, both the start- and end-of-transfer
strobes are **hard-tied to 0**:

    axi_dmac_regmap_request.v:357  up_sot = (up_dma_cyclic && !ctrl_hwdesc) ? 1'b0 : ...
    axi_dmac_regmap_request.v:358  up_eot = (up_dma_cyclic && !ctrl_hwdesc) ? 1'b0 : ...

Two direct consequences the host MUST design around:

1. **`DMAC_TRANSFER_DONE` (0x428) never updates.** The done bitmap is written
   only on `up_eot`/`up_sot`:

       axi_dmac_regmap_request.v:375-377
         if (up_eot == 1'b1) begin
           up_transfer_id_eot <= up_transfer_id_eot + 1'b1;
           up_transfer_done_bitmap[up_transfer_id_eot] <= 1'b1;
         end

   0x428 is `{up_partial_length_valid, 27'b0, up_transfer_done_bitmap[3:0]}`
   (regmap_request.v:219). So `rx_done()` (qpsk_tun.c:632-635, reads 0x428 & 1)
   **returns 0 forever** in cyclic mode.

2. **No EOT interrupt ever fires.** The IRQ trigger is literally `{up_eot,
   up_sot}`:

       axi_dmac_regmap.v:185  up_irq_trigger = {up_eot, up_sot};

   Both bits are 0, so `up_irq_source` never sets and `irq` never asserts.

> The task brief's assumption -- "the ADI axi_dmac cyclic mode raises periodic
> completion IRQs/flags as it wraps" -- is **determinately false for this
> configuration**, not merely undetermined. That behaviour requires SG hardware
> descriptors (`ctrl_hwdesc == 1`), which this IP is not built for. Do not write
> host code that waits on TRANSFER_DONE or an EOT IRQ under cyclic; it will hang
> silently (see Risks 4(a)).

There is therefore **no hardware write-pointer register and no per-lap event**.
The host must detect landed data by **content**, using the frame's own sequence
number (which the RX path already extracts). This is developed in section 3.

--------------------------------------------------------------------------------
## 1. What "cyclic" actually does in this IP (the ring shape)
--------------------------------------------------------------------------------

`FRAMELOCK = 0` (default: `axi_dmac.v:78`; system_bd.tcl sets no
`CONFIG.FRAMELOCK`), so `req_cyclic` only feeds the framelock block, which is
absent (`axi_dmac_transfer.v:462` is the `FRAMELOCK==1` arm; the `else` at
`:507` just passes requests through). Cyclic re-issue is driven purely by the
request-valid latch:

- The host sets `up_dma_req_valid` once by writing `DMAC_SUBMIT` (0x408 ==
  reg 9'h102): `regmap_request.v:177  up_dma_req_valid <= up_dma_req_valid | up_wdata[0];`
- It is cleared **only** on `up_sot` (`regmap_request.v:178-179`), which is 0 in
  cyclic mode -> `up_dma_req_valid` **latches high permanently**, so the arbiter
  re-issues the *same* descriptor (same `DEST_ADDRESS`, same `X_LENGTH`)
  forever.

Because the dest address does **not** advance between laps, the "ring" is one
flat `X_LENGTH`-byte window that the engine **overwrites in place** each lap.
To hold K frames you set `X_LENGTH = K * pkt_bytes`; the engine fills slot
0..K-1 then wraps to slot 0. `SYNC_TRANSFER_START` re-aligns the base to a frame
boundary at each lap restart (`regmap_request.v:161`).

Teardown: the ONLY way to stop a cyclic engine is to drop `ctrl_enable`, i.e.
write `DMAC_CONTROL = 0` (0x400 == reg 9'h100; enable is bit0,
`axi_dmac_regmap.v:263`). When `ctrl_enable == 0`, `up_dma_req_valid` is forced
0 (`regmap_request.v:181-182`) and the id/done state clears
(`regmap_request.v:365-368`).

--------------------------------------------------------------------------------
## 2. (a) The FLAGS / SUBMIT / reset sequence becomes a ONE-TIME arm
--------------------------------------------------------------------------------

Current per-transfer arm, `rx_arm()` (qpsk_tun.c:614-630), runs on **every**
transfer boundary:

    614  static void rx_arm(unsigned area) {
    617      carve_zero(rx_area_virt(area), span*pkt_bytes);   // zero the slot(s)
    618      dmac_wr(&rxd, DMAC_CONTROL, 0);                   // engine reset
    619      dmac_wr(&rxd, DMAC_CONTROL, 1);
    620      dmac_wr(&rxd, DMAC_IRQ_MASK, dmac_mask_val());
    622      dmac_wr(&rxd, DMAC_DEST_ADDRESS, rx_area_phys(area));
    623      dmac_wr(&rxd, DMAC_X_LENGTH, span*pkt_bytes - 1);
    624      dmac_wr(&rxd, DMAC_FLAGS, 0);                     // <-- non-cyclic
    625      dmac_wr(&rxd, DMAC_SUBMIT, 1);
    ...
    629      rx_t0 = now_s();
    630  }

Under cyclic this becomes a **single call at startup only** (call it
`rx_arm_cyclic()`), with two changes and no per-frame repetition:

    // one contiguous ring across the whole RX carve; RING_SLOTS frames
    dmac_wr(&rxd, DMAC_CONTROL, 0);                       // reset once
    dmac_wr(&rxd, DMAC_CONTROL, 1);                       // enable (bit0)
    dmac_wr(&rxd, DMAC_IRQ_MASK, 0x3);                    // mask both; no IRQ exists
    dmac_wr(&rxd, DMAC_DEST_ADDRESS, RX_BUF_PHYS);        // ring base
    dmac_wr(&rxd, DMAC_X_LENGTH, RING_SLOTS*pkt_bytes-1);
    dmac_wr(&rxd, DMAC_FLAGS, DMAC_FLAG_CYCLIC);          // NEW: bit0 = 1
    dmac_wr(&rxd, DMAC_SUBMIT, 1);                        // arm once, forever

New register define to add near qpsk_tun.c:110 (`DMAC_FLAG_TLAST 0x2`):

    #define DMAC_FLAG_CYCLIC   0x1    /* FLAGS bit0; gated by DMA_CYCLIC synth */

Note `DMAC_FLAG_CYCLIC` and `DMAC_FLAG_TLAST` map to `up_dma_cyclic` (bit0) and
`up_dma_last` (bit1) at `regmap_request.v:187-190`. For S2MM RX, `up_dma_last`
(bit1) affects only stream-side TLAST generation; set FLAGS to `0x1` (cyclic
only). Ring the whole carve as ONE window -- there is no double-buffer any more;
the two areas of `2 * RX_MULTI_MAX * SLOT_BYTES` mapped at qpsk_tun.c:945 become
a single contiguous ring of `RING_SLOTS = 2 * RX_MULTI_MAX` frame slots (subject
to the carve fitting; keep `RING_SLOTS * pkt_bytes` within the mapped region).

**Crucially there is NO `carve_zero`, NO `CONTROL=0/1`, NO re-SUBMIT per frame.**
Those writes are exactly the host round-trip that causes the miss today.

--------------------------------------------------------------------------------
## 2. (b) rx_pump_frame's rearm/drain state machine is DELETED
--------------------------------------------------------------------------------

The entire double-buffer / eager / rearm machinery in `rx_pump_frame`
(qpsk_tun.c:663-743) exists only to hide the reset/resubmit latency of a
non-cyclic single engine. Under cyclic it is replaced by a **stateless ring
reader**. Specifically these are removed:

- `rx_want_spin()` (qpsk_tun.c:645-652) -- no rearm window to protect.
- the `rx_drain`/`rx_dscan`/`rx_fill`/`rx_fscan` state (qpsk_tun.c:591-594) and
  the "rearm the OTHER area before draining" block (qpsk_tun.c:725-741).
- the completion branch `if (rx_done())` (qpsk_tun.c:727) -- `rx_done()` is dead
  under cyclic (section 0); leaving it in place is a silent-stall bug (Risk 4a).
- the per-arm `carve_zero` (qpsk_tun.c:617) -- see section 3 for why zeroing is
  actively harmful now.

`rx_pkt_s` self-calibration (qpsk_tun.c:733-735) can be kept as a pacing hint
(it drives nap-vs-spin) but is no longer tied to transfer completion; derive it
from consumed-frame timestamps instead.

--------------------------------------------------------------------------------
## 2. (c) Reading completed segments behind the write pointer, WITHOUT a reset
--------------------------------------------------------------------------------

There is no hardware write pointer (section 0/1). Detect freshness by
**sequence-number monotonicity**, which the frame layer already gives us for
free -- `qpsk_frame_decode(slice, pkt_bytes, out, seq)` returns the frame's seq
(used today at qpsk_tun.c:689, 701, 718). Keep a `last_seq` cursor:

    static uint32_t rx_ring_scan = 0;    // next slot to inspect (mod RING_SLOTS)
    static uint32_t rx_last_seq  = 0;    // highest consumed seq (+ have_seq flag)

    // per poll: inspect slot rx_ring_scan
    carve_copy_from(slice, rx_area_virt0 + rx_ring_scan*pkt_bytes, pkt_bytes);
    int m = qpsk_frame_decode(slice, pkt_bytes, out, seq);
    if (m > 0 && (!have_seq || seq_after(*seq, rx_last_seq))) {
        rx_last_seq = *seq; have_seq = 1;
        rx_ring_scan = (rx_ring_scan + 1) % RING_SLOTS;
        return m;                       // deliver
    }
    // else: slot not yet refreshed this lap (stale seq) or CRC not landed -> wait

Why seq and not "valid CRC": with the per-arm `carve_zero` gone, **every slot
permanently holds a valid-CRC frame after lap 1** (the DMA never blanks it), so
"CRC valid" can no longer distinguish fresh from stale. The seq is the only
in-band freshness signal. `seq_after()` must be wraparound-safe (32-bit serial
compare, `(int32_t)(a-b) > 0`); the frame seq space is already 32-bit
(qpsk_tun.c:685). This also cleanly reuses the existing gap/dedup/ARQ layer
(`st.seq_gaps`, `dedup_seen`, `retx_request`) unchanged.

Ordering: the engine writes strictly in address order within a lap (single
in-order S2MM stream, TLAST gated off -- see the transfer-geometry comment at
qpsk_tun.c:42), so scanning slots in index order is the correct consume order.

--------------------------------------------------------------------------------
## 2. (d) Risks
--------------------------------------------------------------------------------

(a) **Silent stall if `rx_done()` is left in the loop.** Under cyclic it never
    returns 1 (section 0). Any `while(!rx_done())` or `if(rx_done())` gate stalls
    RX forever with no error, no CRC drop, no crash. Grep and remove all
    `rx_done()` / `DMAC_TRANSFER_DONE` uses on the RX path before enabling
    cyclic. (TX path is untouched -- TX is not cyclic-consumed the same way.)

(b) **Buffer overrun if the host falls a full lap behind.** Nothing back-
    pressures the S2MM engine; if the reader is slower than the RX frame rate
    for a whole ring, the write pointer laps the read cursor and silently
    overwrites unconsumed slots. This is **detectable** with the seq cursor: a
    consumed seq that jumps by >= RING_SLOTS since the previous slot means a full
    lap was lost -- count it (reuse `st.seq_gaps` / `framelog_seq`) and, if
    persistent, that is the signal to grow RING_SLOTS. Size the ring for the
    worst host scheduling stall (the SCHED_FIFO/chrt-50 bring-up already bounds
    this; cf. two_jup bringup). At K5 4.72 ms/frame, `RING_SLOTS = 128` gives
    ~600 ms of slack.

(c) **Ordering / torn reads.** A slot being scanned may be mid-write. The seq
    check plus CRC (`qpsk_frame_decode` returns <0 on bad CRC) rejects a torn
    slot; the reader simply retries next poll. Do not advance `rx_ring_scan`
    past a slot whose seq is not yet fresh.

(d) **SYNC_TRANSFER_START interaction.** It still gates each lap restart on
    `req_sync` (regmap_request.v:161), so the ring base re-aligns to a frame
    boundary once per lap. The restart is single-cycle in hardware, so the
    host-round-trip race that loses ~1 frame/boundary today is gone. A residual
    single-cycle re-sync race at the lap boundary is NOT excluded by source
    reading -- expect the loss to drop by orders of magnitude, not provably to
    zero (see README validation).

(e) **Cache coherency.** Unchanged: `CONFIG.CACHE_COHERENT 1` /
    `AXI_AXCACHE 0b1111` (system_bd.tcl:331-332) and the non-cacheable carve
    accessors (`carve_copy_from`, qpsk_tun.c:381) already handle this; the ring
    reader keeps using them.

--------------------------------------------------------------------------------
## 2. (e) Keeping the non-CYCLIC path as a compile/runtime fallback
--------------------------------------------------------------------------------

Because `CONFIG.CYCLIC 1` is permissive (`up_dma_cyclic <= up_wdata[0] &
DMA_CYCLIC`, regmap_request.v:188), a single host binary can run **either** path
on the CYCLIC-1 bitstream, selected at runtime:

    static int rx_cyclic = 0;   // set from env QPSK_RX_CYCLIC=1 at startup

- `QPSK_RX_CYCLIC=0` (default): keep today's `rx_arm()` / `rx_pump_frame()`
  exactly (writes FLAGS=0, so the engine runs non-cyclic even on the new
  bitstream -- byte-for-byte the current behaviour). This is the safe default
  and the fallback.
- `QPSK_RX_CYCLIC=1`: use `rx_arm_cyclic()` + the ring reader (sections 2a-2c).

Gate at the two call sites (`rx_pump_frame` dispatch and startup arm), mirroring
the existing `irq_mode` / `QPSK_FORCE_POLLED` pattern (qpsk_tun.c:204). This lets
2(e) be validated on ONE image by flipping an env var, and makes rollback a
restart, not a reflash.

Do NOT enable the cyclic host path on the CURRENT (CYCLIC 0) bitstream: there
`DMA_CYCLIC == 0`, so FLAGS bit0 is masked to 0, the engine runs non-cyclic, and
the one-time arm would receive exactly one transfer then stop -> RX dies after
one lap. Guard `rx_cyclic` behind a runtime capability check if feasible, else
document the bitstream requirement at the env-var read site.

--------------------------------------------------------------------------------
## Register map cross-check (byte offset -> reg word -> field), from source
--------------------------------------------------------------------------------

| host #define (qpsk_tun.c) | byte | reg word | field (source)                          |
|---------------------------|------|----------|-----------------------------------------|
| DMAC_CONTROL        0x400 | 0x400| 9'h100   | {flock,hwdesc,pause,enable} regmap.v:263|
| DMAC_TRANSFER_ID    0x404 | 0x404| 9'h101   | up_transfer_id      regmap_request.v:210|
| DMAC_SUBMIT         0x408 | 0x408| 9'h102   | up_dma_req_valid (W1S) rr.v:177         |
| DMAC_FLAGS          0x40C | 0x40C| 9'h103   | {tlen,last,cyclic}  rr.v:187-190,212    |
| DMAC_DEST_ADDRESS   0x410 | 0x410| 9'h104   | up_dma_dest_address rr.v:192            |
| DMAC_SRC_ADDRESS    0x414 | 0x414| 9'h105   | up_dma_src_address  rr.v:193            |
| DMAC_X_LENGTH       0x418 | 0x418| 9'h106   | up_dma_x_length     rr.v:194            |
| DMAC_TRANSFER_DONE  0x428 | 0x428| 9'h10a   | {partial,-,done_bitmap} rr.v:219        |
| DMAC_IRQ_MASK       0x080 | 0x080| 9'h020   | up_irq_mask         regmap.v:260        |
| DMAC_IRQ_PENDING    0x084 | 0x084| 9'h021   | up_irq_pending(W1C) regmap.v:186,261    |

(reg word = byte/4; rr.v = axi_dmac_regmap_request.v)
