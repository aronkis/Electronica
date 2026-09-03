Debug instruments
=================

You are reading this because you are about to measure something on this
link and you should not build a new instrument before checking what
already exists. This page is the **catalogue**: the host-side env-gated
instruments, the fabric register map and its free and contested
offsets, the MATLAB overlay-gating idioms used to add a fabric
instrument without perturbing the production image, the RTL simulation
harness family, and the offline analysis tooling.

:doc:`measurement-discipline` says *why* to instrument before theorising.
This page says *with what*.

Read the blind-spot warnings first
----------------------------------

Three instruments in this project produced confident-looking output
that meant nothing. Every one of the failures was about the instrument,
not the fault, and each is a trap a new instrument can walk into.

**1. In ``-M`` production mode the byte stream carries no frame
markers.** The skid v2 witness was keyed on TLAST and TUSER. On silicon
it read exactly zero for a whole run — 6689 samples with a single
transition — while 65 000 frames flowed. The reason: ``tlast_en = 0``
gates TLAST at the byte breakout, and TUSER never fires. Any
frame-framed witness at that boundary is inert in production mode. Do
not key a witness on a marker you have not confirmed present *on the
image you will flash*.

**2. A witness with no positive control produces uninterpretable
zeros.** The v3 marker-free gap witness was designed to sidestep trap 1
by counting inter-beat gaps instead of markers. Under air traffic it
reported ``onegap = 0/s`` over 8744 samples — it never saw its target
signature once — and ``multigap = 1743/s`` against a *structural*
inter-frame gap rate of 1245/s. Its uniform-cadence assumption is
likely false. **It is not a working instrument** and its output must
not be quoted as a measurement.

**3. Drive the netlist at the cadence of its own generation.** This is
the single most expensive harness trap in the project. See the drive
contract below.

Host-side instruments (``host_app_k5/qpsk_tun.c``)
--------------------------------------------------

Instruments are gated by an environment variable; unset, the hooks are
no-ops and the daemon behaves identically to an uninstrumented build.
Most are compiled into every build — the exception is the
``QPSK_RXQ_*`` experiment set, which is additionally behind
``#ifdef QPSK_RXQ_STAT``. Each instrument must pass its own on/off
perturbation A/B before its data is trusted (:doc:`host-software`).

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Variable
     - What it gives you
   * - ``QPSK_FRAMELOG``
     - Path to an append-mode binary log; one **48-byte record per
       scored slice** (wall clock, host_seq, CRC verdict, and raw reads
       of 0x104/0x108/0x150/0x154/0x15C). This is the substrate of
       every loss ledger and cadence analysis. ``SIGUSR2`` rotates the
       file, and the handler is installed **only** when the variable is
       set.
   * - ``QPSK_FSLOG``
     - The **CP1 comparator**: a ring of the last N slices pairing the
       fabric's per-frame checksum with the host's recompute. The
       framestat read protocol is exact and easy to get wrong — read
       0x1D0 (lo, non-popping), read 0x1D4 (hi), then **pop by writing
       a CHANGED token to 0x1DC**, gated on the level in 0x1D8[15:0].
       A repeated token value does **not** pop. The first run of this
       instrument omitted the pop and produced garbage pairing; that is
       why the protocol is spelled out everywhere it appears.
   * - ``QPSK_TXLOG``
     - Ring of the last N TX submits with timestamps, inflight depth
       and DMA spin counts. This is what proved the TX feeder was a
       metronome, and what caught the ~84 ms starvation gaps in the
       wedge (``inflight_after = 0``, ``spins = 0`` — fabric TX path
       exonerated).
   * - ``QPSK_CKPT`` / ``QPSK_CKPT_N``
     - CP2/CP3 fold checkpoints on the queued drain: count and checksum
       of a slice taken in the DMA carve (CP2) and again after the
       carve→host copy (CP3), every Nth slice. CP2 == CP3 across 7/7
       wedge reproductions is what exonerated the RX seam.
   * - ``QPSK_RX_DRAIN_BUDGET``
     - Slices drained per pump call; ``0`` = the historical unbounded
       behaviour. **The compiled default is now 4** (commit
       ``bf2398a``) — this variable is now an override, not the fix's
       delivery mechanism. It was env-gated-only for three days, which
       is exactly why the proven wedge fix never reached production
       bring-up.
   * - ``QPSK_RX_QUEUED``
     - Queued-request RX using the ``axi_dmac``'s native one-ahead
       request queue. Removes the per-transfer-boundary reset window
       (~2 % lag-M loss). Requires ``-M K > 0``; mutually exclusive
       with ``QPSK_RX_CYCLIC``. **This is the mode all current
       acceptance numbers are taken in.**
   * - ``QPSK_RX_CYCLIC``
     - Cyclic-ring RX for a ``CONFIG.CYCLIC 1`` bitstream: no transfer
       boundaries, freshness from the free-running 0x1C0 word counter.
       Requires ``-M K > 0``. **Warning in the source:** on a CYCLIC-0
       bitstream FLAGS bit 0 is masked to 0, the one-time arm receives
       exactly one transfer, and RX dies after one ring. Validated on
       loopback only — the air capture wedges within 12 s.
   * - ``QPSK_RX_AREAS``
     - Number of RX ring areas (≥ 2) in queued mode, decoupling re-arm
       from drain. Refused with a diagnostic if an area cannot hold a
       whole ``-M`` slot batch.
   * - ``QPSK_RX_WDOG_S``
     - No-progress window for the queued-RX watchdog; default 3.0 s.
   * - ``QPSK_RXQ_REREAD``
     - Re-reads a CRC-failed slice from the DMA buffer to test for torn
       reads. 0 of 23 740 re-reads ever rescued a frame — the
       corruption is stable in the buffer, which is a constraint on any
       forward-class mechanism. **Compile-time gated too:** this and
       its ``QPSK_RXQ_*`` siblings sit inside ``#ifdef QPSK_RXQ_STAT``,
       so setting the variable against a default build does nothing.

The fabric register map as an instrument surface
------------------------------------------------

Full offsets and semantics are in :doc:`byte-plane`; what matters here
is where you can *put* a new instrument and where you must not.

* **Occupied range**: 0x100–0x204 across all image lineages. The
  highest-addressed claimant in the tree is ``loop_tune_axi_overlay``
  at **0x1F0–0x204**.
* **Free space**: no overlay in ``jupiter_240k5_byte/`` claims any
  offset at **0x208 or above**. That is the natural home for a new
  telemetry register — confirm with a fresh grep before you take it,
  because this map has been re-cut repeatedly.
* **Contested: 0x1C0 / 0x1C4 / 0x1C8.** These are ``framestat``'s
  ``wordcnt`` / ``stallcnt`` / ``txurcnt`` in LEAN instrument images,
  and ``p1b_pc_w1`` / ``p1b_pc_w2`` / ``p1b_pa_w1`` of the p1b decision
  census (0x1B4–0x1C8) in non-LEAN debug builds. ``framestat_overlay.m``
  carries a **hard assert** that refuses a framestat + p1b combination
  rather than silently double-mapping any of the three.
* **Contested: 0x1A0.** Reserved (reads undefined) in ``canary2``,
  where the surrounding 0x18C–0x19C block is the IC/carrier shadow set;
  ``cs_vin_cnt`` in ``canary4_validcensus_overlay``; and
  ``QPSK_NCO_DIV_BEAT_OFF`` in ``qpsk_hw.h``. Confirm the image lineage
  before reading it.
* **Contested: 0x170–0x184.** The six ``loop_gain_axi`` runtime gain
  registers in LEAN images, but the **read-only T8.5 canary/shadow**
  registers in debug builds. This collision has already cost one
  experiment: the 0x184 CFO-threshold poke was inert on the
  ``433fd8da`` image because the write had nowhere to land.
* **DRA is a single address latch.** Any two concurrent readers corrupt
  each other's reads. Stop the lock watchdog before a manual
  ``direct_reg_access`` session and restart it afterwards.

Adding a fabric instrument: the overlay-gating idioms
------------------------------------------------------

Fabric instruments are added by MATLAB **overlay** functions in
``jupiter_240k5_byte/``, applied late in
``assemble_jupiter_240k5_byte.m``. The contract every overlay must
honour is *G0 preservation*: with the instrument off, the assembled
model must be **byte-identical** to the uninstrumented one. Three
idioms achieve that, in decreasing order of strength:

**Early return — the strongest, and the model to copy.**
``framestat_overlay.m`` gates its **entire body** on the environment:

.. code-block:: matlab

   % ---- G0 gate: early return => byte-identical when off (no blocks touched)
   if isempty(getenv('QPSK_FRAMESTAT'))
       return;
   end

With the variable unset the function touches not a single block, so the
OFF path adds zero blocks and zero ports — the guarantee is
*structural*, not merely tested. Everything else in that file is worth
reading too: the idempotency guard (``find_system`` for its own marker
block), the register-collision assert, and a header comment that states
the record layout field by field.

**Caller-wrap.** The call site in ``assemble_jupiter_240k5_byte.m`` is
itself wrapped, e.g. ``if isempty(getenv('QPSK_LEAN'))`` around debug
overlays, so LEAN production images never invoke them at all. This is
how the adcforensic (0x15C) and shadow/telemetry blocks are stripped.

**Overlay-internal drop.** Where an overlay must run but should shed
part of itself, it drops those pieces internally —
``iq_debug_tap_overlay.m`` strips the boundary state-pairs
(0x160–0x16C) under ``QPSK_LEAN``. Weaker than an early return, since
the overlay still executes; use only when the overlay has a
production-needed part.

**LEAN-only overlays** invert the test and *assert*:
``loop_gain_axi_overlay.m`` refuses to apply unless ``QPSK_LEAN`` is
set, rather than quietly producing an image whose register map does not
match its documentation.

RTL simulation harnesses (``jupiter_240k5_byte/rtl_sim/``)
-----------------------------------------------------------

A family of Verilator drivers replays captured IQ through the bit-true
HDL netlist. This is the project's sharpest knife: it splits
signal-domain faults (the netlist fails too) from platform-side faults
(the netlist decodes clean).

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Driver
     - What it does
   * - ``sim_byte_lock.cpp``
     - The baseline instrumented replay (``wrap_byte_lock.v``): one
       line per delivered frame with word count, 16-bit checksum, CFC
       estimate, symbol-sync and carrier-sync error RMS and the loop
       integrators sampled **at the frame boundary**, plus the
       delivered words for offline CRC verdicts.
   * - ``sim_byte_dip.cpp``
     - ``sim_byte_lock`` plus an **env-scheduled ``byte_rx_ready`` dip
       generator** (``QSIM_DIP_PERIOD`` / ``QSIM_DIP_LEN`` /
       ``QSIM_DIP_OFF``). This varied the one input that silicon replay
       had always hardwired to 1, and produced the backpressure
       refutation.
   * - ``sim_byte_tickfix.cpp``
     - A **behavioural model of the platform 1536-word byte FIFO**
       (which sits *outside* the netlist) inserted at the ``byte_rx``
       interface, with a swallowed-write-beat fault primitive and the
       skid guard, for clean / injected / guarded A/Bs.
   * - ``sim_byte_inject.cpp``
     - **State injection**: force arbitrary internal registers at a
       chosen input-sample index, and dump full state at chosen
       samples, via a generated ``INJ_TABLE``
       (``gen_inject_map.py``; build with ``--public-flat-rw`` so no
       register is optimised away). The tool for "does the fault
       reproduce if I put the machine in state S?".
   * - ``sim_byte_taps.cpp``
     - Per-stage tap logging at every stage boundary (symbol sync,
       CFC, carrier sync, preamble detector, …) so a BER loss can be
       attributed to a stage.

**The drive-cadence contract — read this before running any of them.**
Sample cadence is a property of the **netlist generation**, not of the
harness:

.. list-table::
   :header-rows: 1
   :widths: 44 18 38

   * - Netlist generation
     - Cadence
     - Evidence
   * - Jul-25 / Jul-29 archive (``*_jul25`` objects)
     - **4**
     - 74 CRC-good / 78 at cadence 4; **0** at cadence 2
   * - post-Jul-29 (fsv2 and the flashed lineage)
     - **2**
     - 71 CRC-good / 78 at cadence 2; **5 packets, 0 good** at cadence 4

Getting this wrong yields zero CRC-good frames and looks exactly like a
broken datapath. It cost the campaign a full false alarm — a netlist
was believed broken for a day when only the harness's drive contract
was stale (``two_jup/HARNESS_AB.md``). Note the corollary for the
backpressure refutation: it was run on ``obj_byte_dip_f1536_jul25``,
i.e. the **cadence-4 generation**, not the flashed one — which is why
:doc:`current-state` marks that refutation provisional.

Also in the family: ``tb_dma_contract.v`` under ``two_jup/skidfix/tb/``
— an Icarus testbench modelling the DUT↔``axi_dmac`` handshake
(descriptor gaps, the 5-beat SOF prime with held-beat replication,
``SYNC_TRANSFER_START`` semantics). It reproduced the skid v1 silicon
deadlock as a positive control. Its limit is instructive: it modelled
TLAST/TUSER framing that the production stream does not carry, so a
design that passed it bit-exactly still regressed on silicon.

Offline analysis tooling (``two_jup/``)
----------------------------------------

* **``accept_analyze.py``** — wedge-aware acceptance analysis of one or
  more ``frames.bin`` captures. It finds the live-link window (a
  persistent carrier wedge is reported **separately**, not silently
  averaged in — the capture harness disables the lock watchdog, so a
  mid-capture wedge stays wedged), then reports PER over the
  ``host_seq``-gap metric, burst decomposition, lag-33 singles
  autocorrelation, and a **Clopper-Pearson 95 % upper limit**, pooled
  at the end. Its wedge policy is stated in the docstring rather than
  hidden.
* **``loss_ledger.py``** — the class accounting behind
  ``two_jup/LOSS_LEDGER.md``. It classifies **every** hole in the
  clean-sequence ladder into named classes in a stated priority order
  (startup-burst, burst-frozen, boundary-single/-double on the ~8-frame
  comb, tx-underrun-comb, tx-mute-candidate, feeder-gap, mid-gap), and
  **enumerates the unnamed remainder event by event** rather than
  summarising it away. A class you have not named is a class you cannot
  claim to have fixed.
* **``skidfix/ab_score.py``** — the per-run scorer used for every
  overnight A/B. It calls ``loss_ledger.analyze_run`` so its classes
  match the ledger exactly, and reports delivered PER over the steady
  window (t ≥ 15 s) plus the class counts that matter (633-tick,
  8-comb, totals). Use it rather than ad-hoc scoring, so runs remain
  comparable across nights.
* **``paired_report.py``** — run-level paired analysis for interleaved
  A/B captures, and **the one tool that refuses to lead with a pooled
  number.** Its docstring records why: an ARQ improvement was once
  reported as "non-overlapping Clopper-Pearson intervals on ~170 k
  frames per arm", which was wrong, because CP assumes independent
  Bernoulli trials and this link's losses are **bursty** — the
  run-to-run PER spread on the treated arm was 1.34 points against 0.09
  on control. Pooling frames across runs hides run-level variance and
  lets one lucky run carry a conclusion. **The unit of analysis is the
  run, not the frame.** So it reports per-run PER, the paired delta per
  pair, a sign test over pairs, and the count of unusable/wedged
  captures **per arm** — because asymmetric drops silently bias
  whichever runs survive.

See also
--------

* :doc:`measurement-discipline` — the rules these instruments exist to
  serve, and the refuted-hypotheses section that shows them working.
* :doc:`byte-plane` — the full register map and the framestat record
  layout.
* :doc:`host-software` — the daemon these env gates live in.
* :doc:`current-state` — what is currently open and what an instrument
  would have to show to close it.
