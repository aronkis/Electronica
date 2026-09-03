The byte plane
==============

You are reading this because you need to work on — or reason about —
the path a decoded frame takes from the demodulator to the host, which
is where most of the campaign's remaining loss mechanisms live. This
page maps the RX byte-plane dataflow on board 148, the modem register
file, and the framestat telemetry block that instruments it.

.. raw:: html
   :file: _static/images/byte-plane-dataflow.svg

The dataflow, stage by stage
----------------------------

**ByteSerializer (netlist).** The MATLAB-generated receiver ends in the
``ByteSerializer``, which packs the decoded info bits into exactly
**191 × 64-bit words per frame** (1528 B). The serializer re-anchors
its packing at every frame boundary — a property that matters for fault
morphology: a disturbance downstream of it self-heals at the next frame
boundary, which is exactly what the air-singles class does
(``two_jup/PAIR_RECURRENCE.md``). The netlist also contains its own
small ``ByteRxFifo`` (64 deep); do not confuse it with the platform
FIFO below.

**Platform byte FIFO (1536 words).** Between the netlist output and the
DMA sits a platform-side FIFO of **1536 words = 8 × 192** — one wrap ≈
8.04 payload frames. It is *outside* the HDL netlist, which is why
faults located here replay clean when the same IQ is driven through the
netlist alone (``two_jup/SINGLES_REPLAY.md``). It was long the
prime-suspect site for the air-singles generator, and the site of the
proposed skid-buffer fix (``two_jup/TICK_FIX_SIM.md``). **That
mechanism is refuted as of 2026-08-15**: both skid images failed on
silicon (v1 deadlocked the byte plane; v2 cost +5.6 pp forward), and a
ready-dip replay showed the netlist's own 64-deep ``ByteRxFifo``
absorbs short backpressure bit-identically. See :doc:`current-state`
for the refuted-hypotheses ledger before building on anything here.

**rx_byte_dma.** An ADI ``axi_dmac`` instance at **0x9D200000**
(S2MM, ``DMA_TYPE_SRC 1 / DMA_TYPE_DEST 0``). It is *not* instantiated
anywhere in this repository — it comes from the TransceiverToolbox
reference-design script ``matlab_processors.tcl`` (line 1061 in the
checkout documented in ``two_jup/DMAC_IDENTIFIED.md``), gated on the
HDL Coder plugin parameter ``byte_dma``. Its siblings:
``tx_byte_dma`` at 0x9D100000, ``byte_ctrl_gpio`` at 0x9D300000, and
the modem register file at 0x9D000000. Newer images carry
``CONFIG.CYCLIC 1`` (opt-in at runtime via FLAGS bit 0); in cyclic mode
``TRANSFER_DONE``/EOT die and the host must use content-based
completion — see :doc:`host-software`.

**DDR carve.** The DMA rings live in a reserved-memory region the
daemon mmaps directly (``host_app_k5/qpsk_hw.h``; deployed layout: top
1 MB at 0x7FF00000, with a 2 MB variant for 1536 B frames behind
``-DQPSK_CARVE_2MB``).

Modem register map
------------------

All offsets are relative to the modem base 0x9D000000 and are accessed
through IIO debugfs ``direct_reg_access`` (DRA) or the daemon's mmap.
Two hard-won caveats first:

* **DRA is a single address latch.** Any two concurrent readers corrupt
  each other's reads with arithmetically-impossible values — this
  silently voided a full soak campaign
  (``two_jup/BRINGUP_SEQUENCER.md``). Stop the lock watchdog before any
  manual DRA session, and restart it afterwards.
* **0x104 is reset by rstCS and by the watchdog's 0x000 soft reset**,
  every ~5–7 s on a healthy link. Naive delta-over-window rate probes
  under-read a healthy link by ~2×; use the reset-aware probes
  (``two_jup/rate_probe.sh``, ``health_probe_reset_aware.sh``).

.. list-table::
   :header-rows: 1
   :widths: 12 24 64

   * - Offset
     - Name
     - Meaning
   * - 0x000
     - soft reset
     - Watchdog-driven full reset; clears 0x104 and (0x000-class) 0x1C0.
   * - 0x104
     - packets
     - Cumulative frames decoded (``packets_out``). Reset-prone — see above.
   * - 0x108
     - biterr
     - Cumulative BIST bit-error counter.
   * - 0x110
     - rstCS
     - Carrier-sync reset pulse (write 1 then 0 during bring-up).
   * - 0x114
     - rx_input_select
     - 1 = air (ADC), 0 = internal loopback. Write-only readback: always reads 0 (``two_jup/mux_test.sh``).
   * - 0x118
     - tx_source_select
     - TX source select (write-only readback, like 0x114).
   * - 0x158
     - tx_data_source
     - 1 = DMA bytes, 0 = in-fabric generator. K5/f1536 images moved this from the legacy 0x11C; a write to 0x11C on these images is silently meaningless (``qpsk_hw.h``).
   * - 0x150
     - rstcs_count
     - Cumulative carrier-sync reset count.
   * - 0x154
     - cfc
     - Coarse-frequency-compensation estimate snapshot (``cfc_est``).
   * - 0x15C
     - adcforensic
     - ADC level/duty/gap snapshot — debug builds only; stripped in LEAN.

Framestat block (instrument images)
-----------------------------------

The **framestat** overlay (LEAN instrument images, e.g. e49c011b and
later) adds a per-frame 64-bit telemetry record latched at the frame
strobe into a 64-deep side FIFO, plus three free-running counters. The
full contract is ``jupiter_240k5_byte/FRAMESTAT_NOTES.md``; the summary:

.. list-table::
   :header-rows: 1
   :widths: 12 24 64

   * - Offset
     - Name
     - Meaning
   * - 0x1C0
     - wordcnt
     - Free-running count of accepted ``byte_rx`` words. This is CP1's word count: differencing it gives words/s; a frozen count is an unambiguous wedge verdict.
   * - 0x1C4
     - stallcnt
     - Free-running count of ``byte_rx valid && !ready`` stall cycles (fsv2-generation witness images and later) — the direct backpressure witness.
   * - 0x1C8
     - txurcnt
     - TX ByteBitShifter underrun-reload *event* count (zeros aired, alignment dropped) — the ~72 µs TX-mute witness.
   * - 0x1D0 / 0x1D4
     - head lo / hi
     - FIFO head record [31:0] / [63:32]. **Non-popping** reads.
   * - 0x1D8
     - stat
     - ``{overflow_count[31:16] | level[15:0]}``. Drop-newest on full.
   * - 0x1DC
     - pop
     - Write a **changed** token to advance the read pointer. A repeated value does not pop — the host keeps an incrementing token.

Record layout (the load-bearing fields): **[63:48]** is a 16-bit
byte-sum checksum of the delivered words, computed *in fabric* at the
ByteSerializer output — this is checkpoint **CP1**. **[7:0]** is
``frame_seq`` = ``packets_out & 0xFF``, the host's frame-align tag.
Bit **[9]** is ``stall_in_frame``, bit **[10]** is ``txur_in_frame``
(set when the corresponding counter changed inside that frame's
window), bit [8] flags a carrier-sync reset in-frame, [47:32] is a CFC
snapshot, [23:16] correlation strength, [31:24] AGC level (pinned 0 in
LEAN).

Why CP1 matters: on paired CRC-fail slices the fabric checksum matched
the host's checksum of the corrupt bytes **107/117 (91.4 %)**
(``two_jup/FWD_SINGLES_ROOT_CAUSE.md``) — the fabric byte plane
*emitted* the corrupt frame; the DMA/bus/host transport downstream was
faithful. That single measurement moved the entire singles
investigation upstream of the DMA.

Offset-collision warning
------------------------

Register offsets are reused across image generations. 0x1C0–0x1C8
collide with the ``p1b`` census in non-LEAN debug builds (framestat
builds must be LEAN; the overlay hard-asserts this), and the
0x170–0x184 range means T8.5 canary/shadow registers in debug builds
but the six ``loop_gain_axi`` runtime gain registers
(``cs/ss prop/integ``, ``agc_loop_gain``, ``cfo_threshold``) in LEAN
images (``two_jup/FLOAT_GAP_BUDGET.md``). Always confirm which image an
offset table was written against before poking anything.

See also
--------

* :doc:`host-software` — how the daemon drains this plane and the
  instruments that watch it.
* :doc:`current-state` — the open fault classes that live here, and the
  ledger of mechanisms already refuted for them.
* :doc:`debug-instruments` — free and contested offsets in this map,
  and how to add a fabric instrument without perturbing production.
