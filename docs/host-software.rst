Host software
=============

You are reading this because you need to modify, instrument, or reason
about ``host/qpsk_tun.c`` — the single-binary daemon that turns
the FPGA byte link into a Linux network interface. This page explains
its structure, the environment-gated instruments built into it, and —
as the worked example of how this project debugs — the RX-drain wedge
and its fix.

.. raw:: html
   :file: _static/images/host-app-dataflow.svg

Structure
---------

``qpsk_tun`` is deliberately **single-threaded**: one event loop
services the TUN file descriptor, the TX submit path, and the RX drain.
On the TX side it frames payloads (magic ``QK``, length, LE32 sequence
number, CRC-32, PN-filled pad), writes them into TX slots in the
reserved DDR carve, and submits transfers to ``tx_byte_dma`` with
``max_inflight = 2`` — only about 1.6 ms of air buffered ahead. On the
RX side, each completed DMA area covers ``rx_multi`` (typically 32)
frame slices; ``rx_pump_queued()`` walks the slices, scores each
against CRC, and hands good payloads to TUN. The daemon talks to the
hardware through a direct mmap of the modem registers and the DMA
carve (``qpsk_hw.h`` is the single source of truth for addresses).

The env-gated instruments
-------------------------

Every instrument is compiled in but **gated by an environment
variable**; unset, the hooks are no-ops and the daemon's output is
byte-identical to an uninstrumented build. This is a deliberate
discipline: production behavior and instrumented behavior are the same
binary, and each instrument passed an A/B (on vs off) perturbation
check before its data was trusted.

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Variable
     - What it does
   * - ``QPSK_FRAMELOG``
     - Appends one 48-byte record per scored slice (wall clock,
       host_seq, CRC verdict, and raw reads of 0x104/0x108/0x150/
       0x154/0x15C) to a file. This log is the substrate of every loss
       ledger and cadence analysis (``docs/evidence/LOSS_LEDGER.md``).
   * - ``QPSK_TXLOG``
     - Ring of the last N TX submits with timestamps, inflight depth,
       and DMA spin counts. This is the instrument that proved the TX
       feeder was a metronome in the singles investigation and caught
       the ~84 ms starvation gaps in the wedge.
   * - ``QPSK_CKPT`` / ``QPSK_CKPT_N``
     - CP2/CP3 fold checkpoints: checksums of a slice taken in the DMA
       buffer (CP2) and after the carve→host copy (CP3), sampled every
       Nth slice. CP2==CP3 with zero mismatches across 7/7 wedge
       reproductions exonerated the RX seam
       (``docs/evidence/WEDGE_ROOT_CAUSE.md``).
   * - ``QPSK_FSLOG``
     - The CP1 comparator: per drained slice, reads a framestat record
       (0x1D0 lo non-popping, 0x1D4 hi, then **pop by writing a
       CHANGED token to 0x1DC**, level-gated on 0x1D8[15:0]) and pairs
       the fabric checksum with the host's recompute. The first run
       omitted the pop and produced garbage pairing — the fix is why
       the protocol is spelled out here.
   * - ``QPSK_RX_DRAIN_BUDGET``
     - Caps the number of slices drained per pump call (0 = historical
       unbounded). ``N=4`` is the wedge fix (below), and since commit
       ``bf2398a`` **4 is the compiled default** — the variable is now
       an override. It was env-gated only for three days, which is why
       the causally-proven fix never reached production bring-up; see
       :doc:`current-state`.
   * - ``QPSK_RX_CYCLIC``
     - Cyclic-ring RX reader for CONFIG.CYCLIC bitstreams: no transfer
       boundaries, freshness detected from the free-running 0x1C0 word
       counter (write-pointer anchor at arm). In cyclic mode the EOT
       IRQ is dead, so the daemon forces polled mode. Requires
       multi-drain (``-M K``); mutually exclusive with
       ``QPSK_RX_QUEUED``.
   * - ``QPSK_RXQ_REREAD``
     - Re-reads a CRC-failed slice from the DMA buffer to test for torn
       reads. 0/23,740 re-reads ever rescued a frame — the corruption
       is stable in the buffer (``docs/evidence/FWD_SINGLES_ROOT_CAUSE.md``).
   * - ``QPSK_TX_QUEUED``
     - Batches **idle keepalive** frames N air frames per MM2S transfer
       instead of one, so a single latched transfer covers N frames of
       air. N = 5 is the maximum at f1536 (5 × 3080 B per 16 KB
       stride); 0 or 1 is the legacy per-frame behaviour. Data frames
       are still sent per-frame, but wait up to N frame periods (~4 ms
       at N = 5) for the queue — acceptable for a PER experiment, not
       free for latency.

The TX-gap witness and idle batching
------------------------------------

One instrument is **always on**: after every ``qpsk_tun stats:`` line
(which is byte-for-byte unchanged) the daemon prints a ``txgap:`` line
counting TX submits, submits that found the DMA queue empty, and
estimated silences over 20 / 50 / 200 µs with max, p99 and mean. The
silence is estimated host-side — when a submit finds the queue empty
after reaping, the fabric has been idle since the previous submit plus
its frames' air time — so it is a **lower bound**, not a measurement of
the fabric's own idleness.

It exists because of a hardware constraint worth knowing before
optimising anything on this path: the ``axi_dmac`` latches exactly
**one** request ahead (a submit while one is latched overwrites it), so
``max_inflight = 2`` is the hardware maximum and the TX slack is at most
one transfer of air — about 0.8 ms per f1536 frame. Any event-loop
iteration longer than the remaining latched air starves the fabric's
TX word buffer and costs exactly one air frame; the recurring offender
is the S2MM-boundary drain, which is the same mechanism as the wedge
below, at lower severity. ``QPSK_TX_QUEUED=N`` raises the slack to N
frames for idle traffic, and ``QPSK_RX_DRAIN_BUDGET`` bounds the other
side of the same loop.

How to read the pair: with batching off, this board's ``gt20us`` count
should track the **peer's** bad-magic count for frames this board
transmitted. If ``gt20us`` is near zero while the peer's bad-magic
count stays high, the silence is not host-side and batching will not
help — say so and stop rather than enabling it anyway.

One risk to watch. Batching changes the transfer size the fabric sees
(N × 3080 B under one TLAST); the bit shifter re-aligns on the
first-word flag per transfer and frames 2…N stay aligned by the
385-word cadence, but that has been verified in the netlist only for
per-frame transfers. Watch the checker's short/orphan counts. Do not
enable it during a bring-up arm.

The worked example: the wedge
-----------------------------

The **wedge** was the project's most dramatic failure mode: the link
would collapse into a self-sustaining state delivering ~254 junk
slices/s with framesync lost, recoverable only by restart. The root
cause (``docs/evidence/WEDGE_ROOT_CAUSE.md``, causally confirmed in loopback
2026-08-12) is a starvation loop inside the single-threaded daemon:

1. ``rx_pump_queued()`` historically drained **all 32 slices** of a
   completed area in one call.
2. Junk slices are expensive to score — ~2.6 ms each, so an all-junk
   area costs up to ~84 ms (measured via ``QPSK_TXLOG`` gap analysis).
3. The TX queue is only ``max_inflight = 2`` transfers deep — about
   1.6 ms of air. Any drain longer than that starves the transmitter.
4. A starved TX airs zero-payload frames (short starvation) or loses
   cadence entirely (long starvation); either way the RX sees more
   junk, which makes the next drain slower. The loop self-sustains.

The evidence chain is a model of the project's method: CP2/CP3
checkpoints exonerated the RX seam; PN-correlation analysis classified
the junk as demod noise, not stale or shifted frames
(``docs/evidence/WEDGE_JUNK_CLASS.md``); TXLOG caught the feeder gaps with
``inflight_after=0`` and ``spins=0`` (fabric TX path exonerated —
the DMA never lacked capacity); and the causal A/B —
``QPSK_RX_DRAIN_BUDGET=4`` vs unbounded — produced **0/3 wedges versus
6/7**, with framesync at the full 1246/s. The same mechanism at lower
severity explains the periodic TX zero-fill class and its "11.7° phase
step" resume transient, and why ``-S`` (scorer) sessions historically
never framed on air.

The fix costs nothing structural: budget=4 simply interleaves TX
feeding between drain chunks. The deeper options (raise
``max_inflight`` toward ``TX_SLOTS=8``, cheapen junk scoring) were
noted but not needed.

Instrument-perturbation rule
----------------------------

Before any instrument's data is used, it must pass its own A/B: run
with the instrument on and off and show the loop timing is unchanged
(e.g. the ckpt on/off check held ``pump_us_max`` within ×1.04–1.10).
An instrument that perturbs the loop it measures manufactures its own
signal — see :doc:`measurement-discipline` for the general rule and
its most expensive violations.

Live status: ``modem_status`` (on-board TUI)
--------------------------------------------

``host/modem_status/modem_status`` is a ``jesd_status``-style full-screen readout of
one board's view of the data link: the modem RX-pipeline counters with per-second
deltas, the byte plane and census words, both axi_dmac engines, the ADRV9002
(rssi, gains, ENSM), the ``qpsk_tun`` stats line and the lock watchdog verdict,
each with its age and a health colour. The full-screen view is ncurses (panels
with box-drawing dividers; ``libncurses-dev`` is on both boards, installed on 148
2026-09-09); ``--plain`` is a libc VT100 fallback. Build **on each board** (148 is
arm64, 146 is armhf); ``/usr/local/bin/modem_status`` is the installed copy::

   make -C /root/host_app_k5 modem_status
   ssh -t root@10.0.0.148 /root/host_app_k5/modem_status      # TUI: q r p 1 2 3
   /root/host_app_k5/modem_status --once                        # two samples, plain text
   /root/host_app_k5/modem_status --json                        # one JSON object
   /root/host_app_k5/modem_status --no-regs --once              # file-sourced fields only

Safety contract (``modem_status.h``): it never writes a register, never opens
``direct_reg_access`` (it reads the modem BAR through a ``PROT_READ`` mmap like
the campaign's own stage poller (``stage_poll.c`` at tag
``archive/pre-cleanup-2026-09-09``), so it adds no latch reader), polls at a fixed 1 s, and
pauses register reads while a ``profile_config``/``stream_config`` write is in a
process cmdline, while the ENSM mode is not ``rf_enabled``, or while
``/dev/shm/modem_status.pause`` exists. The residual race is one batched read per
second; do not run it during a scripted bring-up, or ``touch`` the pause file first.

Reading it: ``crc`` is the daemon's per-window delivered ratio (the sentinel's
``crc=`` column), not a PER. ``cap_out``/``biterr`` are scored only with ``--bist``
(``tx_data_source`` is write-only, so the mode cannot be read back). The R4 word is
keyed on the boot-image md5 (``9acbe2ebe1db`` on 146 reads 0x234/0x238 swapped);
an unknown image shows the raw words with ``img?``. Host tests: ``make
test_modem_status`` in ``host/`` (228 checks against a fake source).

See also
--------

* :doc:`byte-plane` — the fabric side of every register this daemon
  touches.
* :doc:`current-state` — which host-side classes are now solved
  (wedge, zero-fill) and what remains.
* :doc:`debug-instruments` — the full instrument catalogue these env
  gates belong to, including the fabric and sim-side tooling.
