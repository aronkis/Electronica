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
(``docs/evidence/PAIR_RECURRENCE.md``). The netlist also contains its own
small ``ByteRxFifo`` (64 deep); do not confuse it with the platform
FIFO below.

**Platform byte FIFO (1536 words).** Between the netlist output and the
DMA sits a platform-side FIFO of **1536 words = 8 × 192** — one wrap ≈
8.04 payload frames. It is *outside* the HDL netlist, which is why
faults located here replay clean when the same IQ is driven through the
netlist alone (``docs/evidence/SINGLES_REPLAY.md``). It was long the
prime-suspect site for the air-singles generator, and the site of the
proposed skid-buffer fix (``docs/evidence/TICK_FIX_SIM.md``). **That
mechanism is refuted as of 2026-08-15**: both skid images failed on
silicon (v1 deadlocked the byte plane; v2 cost +5.6 pp forward), and a
ready-dip replay showed the netlist's own 64-deep ``ByteRxFifo``
absorbs short backpressure bit-identically. See :doc:`current-state`
for the refuted-hypotheses ledger before building on anything here.

**rx_byte_dma.** An ADI ``axi_dmac`` instance at **0x9D200000**
(S2MM, ``DMA_TYPE_SRC 1 / DMA_TYPE_DEST 0``). It is *not* instantiated
anywhere in this repository — it comes from the TransceiverToolbox
reference-design script ``matlab_processors.tcl`` (line 1061 in the
checkout documented in ``docs/evidence/DMAC_IDENTIFIED.md``), gated on the
HDL Coder plugin parameter ``byte_dma``. Its siblings:
``tx_byte_dma`` at 0x9D100000, ``byte_ctrl_gpio`` at 0x9D300000, and
the modem register file at 0x9D000000. Newer images carry
``CONFIG.CYCLIC 1`` (opt-in at runtime via FLAGS bit 0); in cyclic mode
``TRANSFER_DONE``/EOT die and the host must use content-based
completion — see :doc:`host-software`.

**DDR carve.** The DMA rings live in a reserved-memory region the
daemon mmaps directly (``host/qpsk_hw.h``; deployed layout: top
1 MB at 0x7FF00000, with a 2 MB variant for 1536 B frames behind
``-DQPSK_CARVE_2MB``).

The TX mirror
-------------

The transmit side runs the same plane backwards, and three of its
properties explain fault shapes you will meet on the RX side.

**The chain.** Host DMA beats land in the ``ByteWordBuffer`` (two deep,
registered ``tready``), the ``ByteBitShifter`` serializes them to bits,
and the K5 transmit encoder codes them: a gate block frames the beats
and tags the information bits with ``infoValid``, the convolutional
encoder advances its shift register **only on ``infoValid``** — the
anti-zero-stuff gate — and the block interleaver writes the current
frame while reading the previous one. A multiplexer then selects between
the encoded byte branch and the in-fabric pre-coded ROM, under
``tx_data_source`` (0x158).

**The encoder resets, then advances.** At each frame start the encoder
state is zeroed *before* the first bit is shifted in, which makes the
per-frame encoding bit-exact to a reference ``convenc`` for **arbitrary**
payloads and self-heals any state corruption at every frame boundary. The
donor's clear-instead-of-shift form was bit-exact only by accident of the
golden vector's leading bit.

**The interleaver costs exactly one frame of latency.** Air frame N
carries the encode of byte frame N−1. This is a causal necessity, not a
choice: the interleaver's first read needs a coded bit that is not
produced until late in the same frame's write pass, so a same-frame read
is impossible and the ping-pong schedule is kept. The practical
consequences are that the first frame after any (re)start is garbage,
and that frame-indexed analyses of TX-side events are off by one against
the byte stream that produced them.

**TX and RX transfer sizes are not the same number.** On f1536 the host
pushes 3080 B per frame and receives 191 × 64-bit words = 1528 B. The
asymmetry is structural — the transmit side carries the whole coded air
frame, the receive side carries the decoded payload — and using one size
for both was a real host bug once, producing misframed air with a
perfectly healthy fabric.

Modem register map
------------------

All offsets are relative to the modem base 0x9D000000 and are accessed
through IIO debugfs ``direct_reg_access`` (DRA) or the daemon's mmap.
Two hard-won caveats first:

* **DRA is a single address latch.** Any two concurrent readers corrupt
  each other's reads with arithmetically-impossible values — this
  silently voided a full soak campaign
  (``docs/evidence/BRINGUP_SEQUENCER.md``). Stop the lock watchdog before any
  manual DRA session, and restart it afterwards.
* **0x104 is reset by rstCS and by the watchdog's 0x000 soft reset**,
  every ~5–7 s on a healthy link. Naive delta-over-window rate probes
  under-read a healthy link by ~2×; use the reset-aware probes
  (``ops/rate_probe.sh``, ``health_probe_reset_aware.sh``).

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
   * - 0x10C
     - iq_debug_mux
     - Tap selector — 0 AGC output, 1 post-symbol-sync, 2 post-carrier-sync, 3 constellation. Tap-enabled images only; the selected stream rides the second RX DMA channel. Write-only.
   * - 0x110
     - rstCS
     - Carrier-sync reset pulse (write 1 then 0 during bring-up).
   * - 0x114
     - rx_input_select
     - 1 = air (ADC), 0 = internal loopback. Write-only readback: always reads 0 (``ops/mux_test.sh``).
   * - 0x118
     - tx_source_select
     - TX source select (write-only readback, like 0x114).
   * - 0x144
     - cap_out
     - BIST golden readback. ``0x04922282`` is a correct decode of the ROM vector, and is how an image's identity is checked (md5 is not reproducible across Vivado rebuilds).
   * - 0x158
     - tx_data_source
     - 1 = DMA bytes, 0 = in-fabric generator. K5/f1536 images moved this from the legacy 0x11C, because 0x11C is this kit's debug sentinel and would have collided; a write to 0x11C on these images is silently meaningless (``qpsk_hw.h``).
   * - 0x150
     - rstcs_count
     - Cumulative carrier-sync reset count.
   * - 0x154
     - cfc
     - Coarse-frequency-compensation estimate snapshot (``cfc_est``).
   * - 0x15C
     - adcforensic
     - ADC level/duty/gap snapshot — debug builds only; stripped in LEAN.
   * - 0x160 – 0x16C
     - loop-state pairs
     - AGC in/out and CS in/out, packed I/Q. Tap-enabled debug images only; stripped in LEAN.
   * - 0x170 – 0x1A0
     - canary / loop gains
     - **Meaning depends on the build.** Canary/shadow instrumentation in debug builds; the six runtime ``loop_gain_axi`` registers (0x170–0x184) in LEAN images. See the offset-collision warning below.

Three access notes that are not offsets. The byte DMA is armed by
writing 1 to the ``byte_ctrl_gpio`` at ``0x9D300000`` (``devmem
0x9D300000 32 0x1``); the front-end ``agpio4-7`` writes made during the
arm are **load-bearing for lock**, not cosmetic; and the arm sequence
also pokes ADRV9002 *chip* registers, which are not part of this
register file. The canonical, do-not-paraphrase arm sequence lives in
``ops/link_test.sh`` and ``ops/bringup_r2r3.sh``.

Framestat block (instrument images)
-----------------------------------

The **framestat** overlay (LEAN instrument images, e.g. e49c011b and
later) adds a per-frame 64-bit telemetry record latched at the frame
strobe into a 64-deep side FIFO, plus three free-running counters. The
full contract is ``docs/evidence/FRAMESTAT_NOTES.md``; the summary:

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
(``docs/evidence/FWD_SINGLES_ROOT_CAUSE.md``) — the fabric byte plane
*emitted* the corrupt frame; the DMA/bus/host transport downstream was
faithful. That single measurement moved the entire singles
investigation upstream of the DMA.

Offset-collision warning
------------------------

Register offsets are reused across image generations. 0x1C0–0x1C8
collide with the ``p1b`` census in non-LEAN debug builds (framestat
builds must be LEAN; the overlay hard-asserts this), and the
0x170–0x184 range means T8.5 canary/shadow registers in debug builds
but the six ``loop_gain_axi`` runtime gain registers in LEAN
images (``docs/evidence/FLOAT_GAP_BUDGET.md``). Always confirm which image an
offset table was written against before poking anything.

The runtime loop gains (LEAN only)
----------------------------------

Those six registers make the receiver's loop constants writable at
runtime, so an on-air tuning sweep needs no bitstream rebuild. They are
**write** registers, and the semantics are worth stating exactly:
**value 0 means the compiled default is used, bit for bit** — the
original constant stays on the multiplexer's ``reg == 0`` path, so a
reset image is provably unchanged and the added datapath is dead until
written. A non-zero write is interpreted as the **stored integer** of
the desired fixed-point value in that register's own type, i.e.
``round(value · 2^F)`` in the low *W* bits.

.. list-table::
   :header-rows: 1
   :widths: 12 24 34 30

   * - Offset
     - Register
     - Loop constant
     - Type (compiled stored integer)
   * - 0x170
     - ``cs_prop_gain``
     - carrier-sync loop filter, proportional
     - ``ufix16_En16`` (98)
   * - 0x174
     - ``cs_integ_gain``
     - carrier-sync loop filter, integral
     - ``ufix16_En16`` (1)
   * - 0x178
     - ``ss_prop_gain``
     - symbol-sync loop filter K1
     - ``sfix24_En24`` (−163506)
   * - 0x17C
     - ``ss_integ_gain``
     - symbol-sync loop filter K2
     - ``sfix24_En24`` (−2180)
   * - 0x180
     - ``agc_loop_gain``
     - AGC loop filter gain
     - ``ufix32_En31`` (4294967) — see the exception below
   * - 0x184
     - ``cfo_threshold``
     - CFO step-change detector, ±threshold
     - ``sfix22_En21`` (±26214)

**The AGC register is the exception.** Its compiled parameter is a
*double* literal, so there is no native fixed-point constant to match;
the runtime type is a chosen representation. Writing the nominal stored
integer to 0x180 is therefore **not** guaranteed bit-identical to
leaving it at zero — it is a tunable knob, not a passthrough. The other
five are exact stored-integer passthroughs of their native types.

Two practical warnings. The overlay is applied **only in LEAN images**
and asserts rather than silently skipping, because in non-LEAN builds
these offsets are the canary registers — which is how a 0x184
CFO-threshold experiment once wrote into nothing and produced a null
result that meant only "wrong image lineage" (:doc:`current-state`). And
the gate that proves the threading is correct is not the decode oracle:
a decode locks golden at zero, at the compiled value and at twice it
alike, so only a poke test that reads the coefficient signal *inside*
the DUT can catch a mis-threaded register or a wrong fraction length.

See also
--------

* :doc:`host-software` — how the daemon drains this plane and the
  instruments that watch it.
* :doc:`current-state` — the open fault classes that live here, and the
  ledger of mechanisms already refuted for them.
* :doc:`debug-instruments` — free and contested offsets in this map,
  and how to add a fabric instrument without perturbing production.
