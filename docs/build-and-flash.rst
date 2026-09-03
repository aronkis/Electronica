Build & flash flow
==================

You are reading this because you are about to build an FPGA image, or —
more consequentially — flash one to a board. This page describes the
pipeline from the Simulink model to a banked BOOT.BIN, the image-bank
discipline, and the safety rails around flashing. The rails exist
because each one was paid for; do not improvise around them.

.. raw:: html
   :file: _static/images/build-flash-pipeline.svg

Model → netlist
---------------

The modem source of truth is the Simulink model
``commhdlQPSKTxRxLoopback`` plus a stack of env-gated overlay scripts
applied by ``assemble_jupiter_240k5_byte.m`` (frame geometry, LEAN
stripping, framestat, loop-gain AXI threading, witness counters …).
The environment at assemble time therefore *is* the image
configuration — e.g. the proven instrument lineage is
``QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_FRAMESTAT=1``.

One structural caveat that generates recurring false alarms
(``two_jup/SLX_RECONCILE.md``): the ``.slx`` files are **mutable
as-built artifacts, not sources** — every assemble re-saves the model
in place. A "dirty" ``.slx`` after a build is expected; the reconcile
procedure is to XML-diff the extracted model against HEAD before
trusting or reverting anything.

HDL Coder then emits the netlist, which is gated *before* Vivado:

* ``checkhdl`` — zero errors required.
* **S1B** — the self-consistent TX→RX BIST simulation on the netlist.
  Note its known coverage hole: it passes on a clean synthetic signal
  and does not catch real-IQ regressions.
* **Real-IQ replay gate** — Verilator replay of a pinned captured-air
  chunk, scored by CRC. The critical contract
  (``two_jup/HARNESS_AB.md``): the **drive cadence is a property of
  the netlist generation** — the Jul-25 netlist consumes one ADC
  sample per 4 DUT clocks (CAD=4); post-Jul-29 generations consume one
  per 2 (CAD=2). Driving a netlist at the wrong cadence produces a
  catastrophic-looking false failure (5/78 packets) that once
  red-gated two perfectly good images.

Vivado → BOOT.BIN
-----------------

``build_cyclic_image.sh`` (with ``QPSK_BUILD_DIR`` for a fresh build
directory) drives the TransceiverToolbox Vivado project: the netlist
lands in the reference-design block design, ``matlab_processors.tcl``
instantiates the byte DMAs (see :doc:`byte-plane`), and the run ends in
``boot/BOOT.BIN``. Post-implementation gates: timing (WNS/WHS clean),
``static_rate_parity_gate`` against the known-good image (timing
controller, rails, per-port, BD parity), and — since the witness
forensic — the DCP rail check below.

The synthesis rail-re-hosting hazard
------------------------------------

The most subtle build hazard found so far
(``two_jup/HANDOFF_20260813.md``, the 02:45–03:15 forensic): in two
independent *witness builds* (images extended with the 0x1C4/0x1C8
witness counters), Vivado synthesis **re-hosted the modem's
rail-generation and byte-plane enable logic out of the DUT into the
AXI-Lite address-decoder hierarchy** — the exact module the witness
overlay extended. Every netlist/BD/timing/clock diff was clean, yet
both images deterministically ran the byte plane at ~46 % of line rate
on silicon. The trigger: the witness logic bridged byte-plane signals
into the address decoder's readback, and cross-hierarchy resource
sharing then elected addr-decoder copies as the canonical hosts for
shared enable LUTs design-wide.

Mitigation (specified, pending validation by the wit4 build, which is
**still unbuilt** as of 2026-08-15): pin the implementation structure
with ``KEEP_HIERARCHY``/``DONT_TOUCH`` on ``u_TxRxComposite_tc`` and the
addr-decoder instances, and gate every future build with
``two_jup/dcp_rail_dump.tcl`` — assert the tc-cell census matches the
known-good image and that the ``enb_1_2_0`` driver lives under
``u_TxRxComposite_tc``. The DCP rail-census gate is now standard on
every build and has caught real recipe artifacts.

**Do not extrapolate this forensic to the forward loss class.** It was
tested directly at that altitude on 2026-08-15 and refuted: a
glitch-path probe on the shipping image's own routed DCP found every
BUFGCE CE pin tied to VCC with zero pulse-width violators, all 129 DUT
modules clock only on ``posedge clk``, and a ``GATED_CLOCK_CONVERSION``
build came out bit-identical in WNS and rail census. The rail-rehosting
mechanism remains the named explanation for the *witness builds'*
half-rate behaviour only — see :doc:`current-state`.

The image bank
--------------

Images are identified **by md5 prefix, forever** — logs, handoffs, and
rollback files all refer to images this way. Current bank (from the
2026-08-13/14 handoffs):

.. list-table::
   :header-rows: 1
   :widths: 16 84

   * - md5 prefix
     - Image
   * - ``e49c011b``
     - **Proven-good** LEAN f1536 instrument image on 148: framestat
       CP1 live, cyclic-capable ``rx_byte_dma``. The reference lineage.
   * - ``433fd8da``
     - The TMR image running on 146.
   * - ``64bb2476``
     - 148's pre-instrument image (kept as a rollback generation).
   * - ``f2e22135``
     - fsv2 witness (stall 0x1C4 + txur 0x1C8) — genuinely ~46 %
       byte-plane rate on silicon; do not flash.
   * - ``c79b72d2``
     - wit3 witness, same lineage, same silicon rate break — banked,
       not flash-eligible until the rail-guard (wit4) validates.
   * - ``4be9286c``
     - tmr146-v2 witness variant for 146 — never flashed.
   * - ``c9d3e1ec``
     - skid v1. **Flashed and failed**: deadlocked the byte plane on
       silicon (fsync 1252, wcnt = 0). Do not flash.
   * - ``c85b0693``
     - skid v2 (guard-preserving). **Flashed and failed**: forward PER
       +5.6 pp worse, replicated; its witness was blind. Do not flash.
   * - ``6c06ecb7``
     - skid3 v3 witness-wire — **currently running on 148**. Datapath
       production-equivalent to ``e49c011b`` (PER verified identical)
       plus a marker-free gap witness at 0x9D300008. The witness itself
       has no positive control and its output is not interpretable
       (:doc:`debug-instruments`); the datapath is sound.
   * - ``33a962a8``
     - skid4, ``GATED_CLOCK_CONVERSION`` experiment — banked, never
       flashed; bit-identical to its parent in WNS and rail census.

Banking is separate from flashing: a green gate matrix makes an image
*flash-eligible*, and flashing remains an explicit operator-context
decision.

Flashing: the standing rails
----------------------------

The procedure, verbatim from the overnight runbooks:

1. **Rollback first.** The known-good BOOT.BIN backup must exist on the
   board (e.g. ``/root/BOOT.BIN.e49c011b.bak``) plus host and in-repo
   copies, before anything is written.
2. **Flash by scp** to ``/boot``, then **readback md5 verify**.
3. **Full bring-up** (``restore_known_good``: reset sequence, selects,
   daemons, watchdog) — never measure a freshly-flashed board without
   it; a witness run without bring-up once produced an entire false
   "quarter-rate" verdict.
4. **Health gate before counting anything:** reset-aware framesync
   rate ≥ 1100 f/s **and** wordcnt-derived rate ≥ 1100 f/s. Use
   ``two_jup/health_probe_reset_aware.sh``, not a naive 0x104 delta —
   0x104 resets every ~5–7 s on a healthy link and a naive 4 s window
   probe reads ~½ rate on a link genuinely running 1245 f/s
   (``two_jup/BRINGUP_SEQUENCER.md`` rung 6).
5. **Any failure = halt**: roll back, md5-verify the rollback, **no
   retry variants**, bank the evidence, stop rig work.

RTL-sim harness contract
------------------------

When replaying captures through a netlist (the replay gate, the tap
ladder, the tick-fix campaign), the drive cadence must match the
netlist generation: **Jul-25 netlist = cadence 4; post-Jul-29 (fsv2
lineage and later) = cadence 2** (``two_jup/HARNESS_AB.md``). The
fixed harness (``replay_gate_n2.sh``) defaults to CAD=2 and scales the
rstCS window and drain tail with cadence. Reference score on the pinned
78-frame chunk: Jul-25 archive 74/78 CRC-good, fsv2 lineage 73/78 —
the true generation gap is one frame on one marginal-heavy slice, not
the 5/78 the mis-driven harness reported.

See also
--------

* :doc:`measurement-discipline` — why the health gate and the negative
  control around it exist.
* :doc:`current-state` — the current rig state, the open fault classes,
  and the ledger of mechanisms already refuted for them.
* :doc:`debug-instruments` — the sim harnesses this contract governs and
  the rest of the instrument catalogue.
