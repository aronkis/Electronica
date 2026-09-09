Current state & open threads
============================

You are reading this because you are picking up the campaign and need
to know what is solved, what is refuted, and what is still open — as of
**2026-08-15**. This page is the map, not the archive: every item cites
the ledger that holds the evidence, and the ledger is authoritative.

.. admonition:: Update — 2026-08-26
   :class: important

   This page's numbers are the 2026-08-15 snapshot and several
   conclusions have since been superseded. The headline changes, with
   evidence in ``two_jup/SINGLES_CAMPAIGN.md`` (dated sections) and the
   live open-questions inventory ``two_jup/KNOWN_HOLES.md``:

   * The forward "singles comb" is **not** a 146 TX / byte-plane fault.
     It requires cross-board clocks (real XO sample-rate offset), is
     violently CFO-sign-asymmetric on hardware, and was **reproduced in
     RTL simulation** (−15 kHz + SRO: 13 % corrupt frames; +15 kHz:
     clean; CFO-only: clean both signs). Named suspect: the one-sided
     mu clamp in ``Interpolation_Control.v`` (symbol synchronizer).
   * The forward RX LO now defaults to **+20 kHz off-null**
     (``bringup_r2r3.sh``), halving the standing forward loss ~13 % → ~6 %.
   * TX egress verified clean end-to-end by 1-ft self-reception on both
     boards (steady 0.25–0.3 % — the fabric-loopback floor).
   * The pre-built image bank moved to ``boot_known_good/`` (see
     :doc:`setup-prebuilt`); 146 currently carries ``4be9286ca111``,
     148 carries BEATFIX ``fe5bd8a4fe19``.
   * Campaign gate (< 1 % both directions, ARQ off): **still NOT MET**.

It is deliberately organised as an **index of open issues plus a
refuted-hypotheses ledger**. The refuted list is the most valuable part
of the page: it exists to stop re-litigation. Before proposing any
mechanism for the forward class, check it against that list and against
the constraint set below.

Where the goal stands
---------------------

Goal: delivered PER < 1 % both directions, ARQ off. Neither direction
meets it. The measurements below are the end-state of the overnight
2026-08-14/15 campaign (``two_jup/HANDOFF_20260815.md``).

**Configuration for every number in this table.** 148 = skid3 v3
witness-wire image ``6c06ecb7e888`` (datapath production-equivalent to
``e49c011b``); 146 = TMR ``433fd8dab393``; ``-M 16``; queued RX
(``QPSK_RX_QUEUED=1``, cyclic off); ``rx_drain_budget=4``; ARQ **off**;
scored over the steady window t ≥ 15 s with ``skidfix/ab_score.py``.

.. list-table::
   :header-rows: 1
   :widths: 26 14 20 14 26

   * - Direction / run
     - PER
     - Lost / span
     - CP95 UB
     - When
   * - forward 146→148, run 1
     - 8.23 %
     - 5295 / 64303
     - 8.45 %
     - 2026-08-15 01:53–02:03
   * - forward 146→148, run 2
     - 8.32 %
     - 5510 / 66217
     - 8.53 %
     - 2026-08-15 01:53–02:03
   * - forward 146→148, run 3
     - 8.27 %
     - 5464 / 66057
     - 8.48 %
     - 2026-08-15 01:53–02:03
   * - reverse 148→146, pooled
     - 1.72 %
     - 3944 / 228659
     - 1.78 %
     - 2026-08-15 01:41–01:52

The three forward runs are independent ~60 s captures. The reverse
pooled figure is over three runs that individually read 1.43 %, 1.49 %
and 2.25 %.

Honesty caveats — state these whenever the numbers are quoted
-------------------------------------------------------------

* **Nothing here is soak-grade.** Every capture above is ~60 s. No
  multi-hour acceptance soak has been run on this stack.
* **The reverse direction is non-stationary.** It read 1.20–2.25 %
  across the night. The drift is **unattributed**, and **no EVM was
  taken** during these runs, so link health is not separated from
  digital cause.
* **The 9.12 % → 1.72 % reverse improvement is indicative, not a
  controlled A/B.** The 9.12 % figure is a banked earlier run under a
  different stack. What *is* controlled is wedge elimination: both
  first baseline attempts of the night wedged on exactly the old class
  without the drain budget, and did not with it.
* CP95 upper bounds assume independent Bernoulli trials. This link's
  losses are bursty; see ``two_jup/paired_report.py``'s docstring and
  :doc:`measurement-discipline` for why the **run**, not the frame, is
  the unit of analysis.

Shipped this cycle
------------------

**``rx_drain_budget`` default 4** (commit ``bf2398a``). The wedge fix
was causally proven in loopback back on 2026-08-12 (0/3 vs 6/7 wedges,
``two_jup/WEDGE_ROOT_CAUSE.md``) but had only ever been **env-gated**
— it never reached production bring-up, so every production run since
then carried the unbounded drain. Both first baseline attempts of the
overnight campaign wedged on exactly the old class. Making 4 the
compiled default is the single largest PER win of the cycle. The
mechanism is walked through in :doc:`host-software`.

Solved (mechanism named, fix in production)
-------------------------------------------

**The wedge.** Single-threaded RX drain starves the TX feeder; junk
makes the drain slower; the loop self-sustains. Budget = 4 ends it.
``two_jup/WEDGE_ROOT_CAUSE.md``.

**TX zero-fill / "phase step".** The periodic zero-payload frames
(30/33/34-frame limit cycles) and the "11.7° phase step" are short
feeder starvation and its resume transient — the wedge mechanism at
lower severity. Same ledger.

**Fixed-vs-float — closed as a budget.** The fixed datapath meets float
on healthy captures (median −1.18 pp, fixed better); the internal stage
budget totals ≤ 0.65 pp EVM; RRC and CFC quantization exonerated. The
one real term is CFO handling on B-class links (~2.4 dB).
``two_jup/FLOAT_GAP_BUDGET.md``. The runtime poke that was proposed for
it is now refuted on the current images — see the ledger below.

The open forward class (the ~8.3 %)
-----------------------------------

The forward killer is the **air-singles class**: pairs of corrupt
frames on a comb, fully fingerprinted in ``two_jup/PAIR_RECURRENCE.md``
and ``two_jup/FWD_SINGLES_ROOT_CAUSE.md``. No mechanism is currently
validated for it. Every candidate mechanism must satisfy **all** of
these measured constraints:

* **Corruption originates inside the DUT.** CP1 — the fabric-computed
  16-bit checksum in the framestat record — matches the host's checksum
  of the corrupt bytes (107/117, 91.4 %). The DMA, bus and host
  transport downstream are faithful (:doc:`byte-plane`).
* **Full-length, wrong-content frames**: exactly 191 words, wrong
  payload, CRC fail. Not truncation, not a short read.
* **Self-heal within ≤ 2 frames** — the ByteSerializer re-anchors at
  each frame boundary.
* **Replay-clean from reset.** The same captured IQ driven through the
  bit-true netlist decodes CRC-good 12/12
  (``two_jup/SINGLES_REPLAY.md``).
* **~8-frame comb, 32-frame pair recurrence** in fabric units.
* **Invariant to ``-M``** (the host multi-drain factor).

**Surviving hypothesis.** State- or environment-dependent behaviour
that a reset-state replay cannot reach: long-uptime counter/pointer
phase, or concurrent AXI activity — note that ``framestat`` bridges
byte-plane data into AXI-read logic, the same structural family the
witness-build forensic flagged — or host traffic coupling. This is a
hypothesis *class*, not a named mechanism. The decisive instrument
named in the handoff is an **on-die ILA** on
ByteSerializer→breakout→DMA triggered on CRC-fail frames, which needs a
debug-core build on the skid3 lineage.

The open reverse residual (~1.4–2.3 %)
--------------------------------------

Scattered k ≤ 2 holes, ~60 bit-errors per event, signal-domain doubles;
**no 8-frame comb** and no large bursts — morphologically distinct from
the forward class. Its ~1.79 s super-period matches 148's loopback
class-B beat (header-sparing body scrambles plus a byte-0 bit-6 magic
flip), so the prime suspect is a **148-TX-side digital generator**.
The old attribution to 146's RX tracking calibrations is **refuted**
(ledger below). Next step in the handoff: class-B unification analysis
on the banked loopback captures (offline, cheap), then a 148-TX-path
discriminator.

Refuted hypotheses ledger
-------------------------

Each entry names the **discriminator** that killed it. Do not re-open
one of these without a discriminator that beats the one listed.

**1. FIFO-swallow at the platform byte FIFO / skid buffer v1.**
Proposed mechanism: a control-plane beat swallows write strobes at the
1536-word platform FIFO; a 1-deep skid buffer on the write port repairs
it. *Discriminator:* the image was built and flashed — the silicon
**deadlocked**, fsync = 1252 with ``wcnt = 0`` (zero byte words
accepted over 12 s while the modem ran at full line rate). The
deadlock was then **reproduced** in the DMA-contract testbench
(``two_jup/skidfix/tb/tb_dma_contract.v``): a frozen ``tuser = 0``
beat at the DMA input blocks ``SYNC_TRANSFER_START`` forever.
``two_jup/skidfix/SKID_BUILD.md``.

**2. Skid v2 (guard-preserving).** The redesign that passed the
contract testbench bit-exactly in sim. *Discriminator:* on silicon it
made the forward direction **worse by +5.6 pp** — 13.78 % and 13.93 %
on two runs versus 8.22 % on ``e49c011b`` the same night, replicated.
Its on-board witness was **blind**, and the reason is load-bearing:
in ``-M`` production mode the byte stream carries **neither frame
marker** — ``tlast_en = 0`` gates TLAST at the breakout and TUSER never
fires on silicon. Measured over 6689 witness samples with a single
transition while 65 k frames flowed. Same ledger.

**3. Brief DMA backpressure as the forward generator — PROVISIONAL.**
*Discriminator:* the ready-dip replay (``sim_byte_dip.cpp``) scheduled
26 ``byte_rx_ready`` dips at the exact 8-frame cadence, 1–3 word-times
each; the delivered stream was **bit-identical** to the undipped base
(0 short frames, 0 checksum diffs). The DUT's own 64-deep
``ByteRxFifo`` absorbs them, as designed. **Why provisional:** the dip
harness object is ``obj_byte_dip_f1536_jul25`` — built against the
**Jul-25 netlist generation** (drive cadence 4), a *different*
generation from the flashed image (post-Jul-29, cadence 2). The
ledger states the conclusion flatly; the honest scope is "refuted on
the Jul-25 generation". **It must be re-run against the flashed
generation** before the backpressure class is closed. See
``two_jup/HARNESS_AB.md`` and :doc:`debug-instruments` for the cadence
contract.

**4. Gated-clock / LUT-glitch on the byte-plane enable rail.**
Proposed after the witness-build rail-rehosting forensic. *Four
independent discriminators, all negative:* (a) the glitch-path probe on
skid3's own routed DCP found **every BUFGCE CE pin tied to VCC**, with
zero pulse-width violators; (b) the 60 k-load ``enb`` rail drives
**CE-class pins** (FDCE/CE ×3235 measured on the FrameStatFifo
repeater), i.e. it is a synchronous enable on a clock-network repeater,
glitch-tolerant by construction; (c) all **129 DUT modules clock only
on ``posedge clk``** — no gated-clock idiom exists in the RTL; (d) a
``skid4`` build (``33a962a85a22``) with ``GATED_CLOCK_CONVERSION`` on
all 19 synthesis runs came out **bit-identical in WNS and rail census**
— there was nothing to convert.

**5. Reverse-side levers.** All measured, none moved the reverse PER:

* **146 RX tracking-calibration freeze** (all-off, plus a 3-way
  bisect): **no configuration beat baseline** — all-off 1.51 %,
  fic-off 1.33 %, rfdc+bbdc-off 4.73 % (with two >100-frame bursts),
  agc+rssi-off 1.76 %; the 633-flagged counts stayed flat (16–32) in
  every configuration. All cals restored, readback-verified. **This
  refutes the ADRV9002-tracking-cal attribution** that earlier
  revisions of this page carried for the 633-frame tick pairs.
* **0x184 CFO-threshold poke**: the register is **absent** on the
  ``433fd8da`` image — 0x170–0x184 are the read-only T8.5 canary
  registers on that lineage, not the loop-gain block. The write does
  not take. This experiment needs a loop-gain image; do not re-run it
  as written.
* **TX power**: 148 TX is already at 0 dB attenuation (maximum).
* **RXM**: bring-up default is already 16 (the older acceptance
  header's "-M 32" is stale).

Instruments that are NOT working instruments
--------------------------------------------

**The v3 gap witness must not be presented as a working instrument.**
It is a marker-free inter-beat-gap counter designed to see the DUT's
drop-on-stall supersede without needing TLAST/TUSER (which, per
refutation 2, do not exist in production mode). On silicon under air
traffic it reported **onegap = 0/s over 8744 samples** — it never saw
its target signature at all — and **multigap = 1743/s** against a
structural inter-frame gap rate of 1245/s. Its uniform-cadence
assumption is likely false, so the ~500/s excess is not interpretable
as a fault rate. A structural-gap-aware v3.1 would be a small RTL
change on the same lineage, but as it stands the witness has no
demonstrated positive control. See :doc:`debug-instruments`.

Other open threads
------------------

* **Witness-image half-rate thread.** The two witness builds (fsv2
  ``f2e22135``, wit3 ``c79b72d2``) genuinely run the byte plane at
  ~46 % on silicon. The routed-DCP forensic named the divergence at
  pin level: synthesis re-hosted the rail/enable network into the AXI
  address decoder in both builds (:doc:`build-and-flash`). The
  specified **wit4** rail-guard build is still **pending and unbuilt**
  as of 2026-08-15. Note that this thread is no longer on the forward
  critical path — the glitch/rail altitude was tested directly on
  skid3's own DCP and refuted (ledger item 4) — but the wit4 build
  would still settle the half-rate question itself.
  ``two_jup/HANDOFF_20260813.md`` (03:15 entry).
* **Cyclic RX on air.** ``RXCYC_A=1`` engages correctly at runtime, but
  the air capture wedges within 12 s; the cyclic reader has only ever
  been validated on loopback. A gap, not a lever.
* **148-side mid-capture delivery wedge**, one event at 01:37 with
  ``budget = 4`` active — a different flavour from the budget-fixed 146
  class. Watch for recurrence; single observation, uncharacterised.
* Replay-gate threshold re-anchoring (73 vs 74/78 — the one-frame
  generation gap; needs a wider ``win_*`` replay set,
  ``two_jup/HARNESS_AB.md``).
* Forward mid-gap and mute-candidate classes (~0.6 pp combined,
  ``two_jup/LOSS_LEDGER.md``) — below the singles class in priority.

What is unmeasured
------------------

* Any **soak-grade** acceptance run on the current stack (all captures
  are ~60 s).
* **EVM / link health** during the overnight runs — so the reverse
  non-stationarity cannot be separated into RF versus digital.
* The forward class against a **flashed-generation** dip harness
  (ledger item 3).
* The reverse class-B **unification analysis** on the banked loopback
  captures (offline work, not yet done).
* Whether the forward class survives a long-uptime versus fresh-boot
  comparison — the surviving hypothesis predicts a difference and
  nobody has looked.

The morning queue (2026-08-15 handoff)
--------------------------------------

1. Decide the forward path: **on-die ILA** build on the skid3 lineage
   (ByteSerializer→breakout→DMA, triggered on CRC-fail) versus further
   DCP forensics. The handoff names the ILA as the decisive instrument.
2. Reverse **class-B unification analysis** on banked loopback
   captures — offline and cheap.
3. Cyclic-reader air debug, if cyclic is still wanted as a
   boundary-killer.
4. Witness **v3.1** (structural-gap-aware) if the fabric route is
   chosen — but only with a positive control, per the v3 lesson.

Rig state at handoff: 146 on TMR ``433fd8dab393``; 148 on skid3 v3
``6c06ecb7e888`` with the ``e49c011b`` rollback banked on-board;
``rx_drain_budget = 4`` on both boards via the shipped default; daemons
and watchdogs PID-verified healthy. Note the standing operator **HOLD**
discipline: no rig work without an explicit operator go (the 2026-08-12
RF-degradation hold is the precedent — antennas were *not* swapped, and
reverse ran ~5 dB short; treat link-health assumptions as stale until
re-gated).

See also
--------

* :doc:`measurement-discipline` — read before running anything in the
  queue above; its refuted-hypotheses section generalises the ledger on
  this page.
* :doc:`debug-instruments` — what exists to measure with, and which
  instruments have known blind spots.
* :doc:`build-and-flash` — the rails any flash must follow.
