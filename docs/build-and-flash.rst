Build & flash flow
==================

You are reading this because you are about to build an FPGA image, or —
more consequentially — flash one to a board. This page describes the
pipeline from the Simulink model to a banked BOOT.BIN, the image-bank
discipline, and the safety rails around flashing. The rails exist
because each one was paid for; do not improvise around them.

.. raw:: html
   :file: _static/images/build-flash-pipeline.svg

Which chain actually built the deployed images
-----------------------------------------------

Be honest about this before reading further: **the images now on the
boards were built by the campaign kit chain under** ``ops/skidfix/``
(the ``run_*_build.sh`` scripts and the ``txfix_build.*.tmpl``
templates), which wraps the model assemble, the netlist gates and the
Vivado completion for one specific overlay lineage at a time. Cleanup
sub-project 2 replaces that chain with a single supported entry point,
``modem/build_image.sh``. Until it does, a build reproduced from
``modem/`` alone is a *functionally equivalent* image, not the same
image — and equivalence here is established by the gates plus the BIST
golden, never by md5 (see below).

``modem/build_lean_image.sh`` is the model-to-netlist step of that
chain: it runs the ``QPSK_LEAN=1`` gate suite and the HDL Coder
workflow. It is not, by itself, the recipe that produced any image in
``images/``.

The build host
--------------

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Need
     - Value on the build host used
   * - MATLAB (HDL Coder + Simulink)
     - R2025b
   * - Vivado
     - 2025.1
   * - Verilator / iverilog
     - on ``PATH`` — the S1B and S1 netlist gates
   * - ADI byte reference design
     - the TransceiverToolbox Jupiter plugin "JUPITER (RX & TX, BYTE
       DMA)" — a **read-only donor**, never edited
   * - Device target
     - Zynq UltraScale+ ``xczu3eg-sfva625-2-e``

Do not set ``ADI_PERF_TIMING``: Jupiter closes at about +2 ns without it
and the performance directives cost roughly 20 minutes per run for
nothing.

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
(``docs/evidence/SLX_RECONCILE.md``): the ``.slx`` files are **mutable
as-built artifacts, not sources** — every assemble re-saves the model
in place. A "dirty" ``.slx`` after a build is expected; the reconcile
procedure is to XML-diff the extracted model against HEAD before
trusting or reverting anything.

HDL Coder then emits the netlist, which is gated *before* Vivado. The
pre-synthesis suite is six stages, each dropping a stamp file that is
the "green build" evidence:

.. list-table::
   :header-rows: 1
   :widths: 8 46 46

   * - #
     - Stage
     - Stamp / marker
   * - 1
     - Assemble the composite from the overlays
     - the assemble script's own pre-synth structural gates
   * - 2
     - Model-level byte oracle — four runs: aligned golden, rotated word
       phase, alternate-PN pad, and ROM source
     - ``SIM_BYTE_GATE_K5.txt`` (``result: PASS``)
   * - 3
     - ``checkhdl`` + ``makehdl``
     - ``CHECKHDL_240K5_BYTE.txt``
   * - 4
     - Golden byte vectors
     - ``tx_words_golden.hex``
   * - 5
     - S1B byte netlist under Verilator (rot0 + rot17)
     - ``S1B_GATE.txt`` (``result: PASS``)
   * - 6
     - S1 ROM path under iverilog
     - ``S1_GATE.txt`` (``result: PASS``)

The oracles are the real safety net, and stage 2's alternate-PN run is
the load-bearing one: it proves the air comes from the **in-fabric
encoder fed by the host bytes** rather than from a stuck ROM. Stages 5
and 6 re-prove that the generated *netlist*, not merely the model,
reproduces the golden air stream bit-exactly. Note that stage 1
re-assembles the ``.slx`` in place, so ``git status`` will show the
model and the refreshed stamps as modified after any build — stage a
targeted ``git add``, never a blanket one.

Two cautions about that suite, both paid for:

* **S1B has a coverage hole.** It is a self-consistent TX→RX BIST
  simulation on a clean synthetic signal, so it does not catch real-IQ
  regressions. A green S1B is necessary, not sufficient.
* **Real-IQ replay gate** — Verilator replay of a pinned captured-air
  chunk, scored by CRC. The critical contract
  (``docs/evidence/HARNESS_AB.md``): the **drive cadence is a property of
  the netlist generation** — the Jul-25 netlist consumes one ADC
  sample per 4 DUT clocks (CAD=4); post-Jul-29 generations consume one
  per 2 (CAD=2). Driving a netlist at the wrong cadence produces a
  catastrophic-looking false failure (5/78 packets) that once
  red-gated two perfectly good images.

Vivado → BOOT.BIN
-----------------

The image-side scripts in ``modem/`` (``build_cyclic_image.sh`` and its
siblings, with ``QPSK_BUILD_DIR`` for a fresh build directory) drive the
TransceiverToolbox Vivado project: the netlist lands in the
reference-design block design, ``matlab_processors.tcl`` instantiates
the byte DMAs (see :doc:`byte-plane`), and the run ends in
``boot/BOOT.BIN``.

Two structural facts about that run are worth carrying in your head.
First, **the HDL Coder IP-core workflow fails by design at its "Create
Project" task** — an ADI ``add_ip`` insert-path bug — and the Vivado
completion Tcl (``modem/complete_byte_t8.tcl``) finishes the project
instead: it inserts the packaged IP, wires the nine byte DUT ↔ breakout
pins, keeps the stock DAC wiring, validates the block design, and runs
synthesis, implementation, ``write_bitstream`` and ``bootgen``. A
MATLAB error at Create Project is expected and benign; the build guards
on the real artifacts (the ``.xpr`` exists, the packaged IP zip exists,
and the block design contains ``byte_breakout`` — its absence means the
wrong reference design was applied). Second, **there is no XSA/HDF
export**: ``bootgen`` packages the PS boot chain (FSBL, PMU firmware,
ATF, U-Boot) with the PL bitstream straight from the Vivado project.

Post-implementation gates: timing (WNS/WHS clean),
``static_rate_parity_gate`` against the known-good image (timing
controller, rails, per-port, BD parity), and — since the witness
forensic — the DCP rail check below.

The synthesis rail-re-hosting hazard
------------------------------------

The most subtle build hazard found so far
(``docs/evidence/HANDOFF_20260813.md``, the 02:45–03:15 forensic): in two
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
``ops/dcp_rail_dump.tcl`` — assert the tc-cell census matches the
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

Kernel provenance: how the UIO bind is delivered
------------------------------------------------

The banked kernel ``Image.6.12.77-uio.a1ba00b51431`` is not stock, and the
reason is worth knowing before anyone rebuilds it.
``CONFIG_UIO_PDRV_GENIRQ=y`` is **built in**, so ``modprobe.d`` and
``modules-load.d`` are ignored — ``generic-uio`` binds only if the kernel
command line carries ``uio_pdrv_genirq.of_id=generic-uio``. On these boards
the effective ``/proc/cmdline`` comes from **U-Boot's compiled default
environment**: the on-disk device tree's ``/chosen/bootargs`` is rewritten by
U-Boot at ``bootm``, ``uEnv.txt`` is not consulted, and the persistent U-Boot
environment in ``/dev/mtd1`` is invalid, so U-Boot falls back to its built-in
default. Both of the obvious delivery mechanisms are therefore dead.

The option is instead **compiled into the kernel** and appended to whatever
the bootloader passes, via ``CONFIG_CMDLINE`` + ``CONFIG_CMDLINE_EXTEND``
(the append is done by the generic ``drivers/of/fdt.c``
``early_init_dt_scan_chosen``). This survives a BOOT.BIN swap and is
independent of uEnv, mtd and ``/chosen``, which is why the deploy script does
not touch ``uEnv.txt``.

One arm64 caveat: this xlnx 6.12 tree's ``arch/arm64/Kconfig`` exposes only
``CMDLINE_FROM_BOOTLOADER`` and ``CMDLINE_FORCE`` — no ``CMDLINE_EXTEND``
menu entry, although the backing code exists regardless. A three-line Kconfig
delta adds it, saved as
``modem/boot/kernel-arm64-cmdline-extend.patch``. ``CMDLINE_FORCE`` was
rejected deliberately: it *replaces* the whole command line, dropping
``root=`` / ``rootwait`` unless perfectly replicated — a brick risk on a
board with no remote power. ``CMDLINE_EXTEND`` only appends, so a failed
append still boots and the missing option is caught at the deploy verify.

To reproduce the Image, from the ADI kernel tree with its own build
environment sourced (Xilinx 2025.1 ``aarch64-linux-gnu-``)::

   git apply modem/boot/kernel-arm64-cmdline-extend.patch
   ./scripts/config --set-str CMDLINE "uio_pdrv_genirq.of_id=generic-uio" \
                    --disable CMDLINE_FROM_BOOTLOADER --disable CMDLINE_FORCE \
                    --enable CMDLINE_EXTEND
   make ARCH=arm64 olddefconfig
   grep -E '^CONFIG_CMDLINE' .config     # CMDLINE_EXTEND=y + the of_id string
   make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image
   sha256sum arch/arm64/boot/Image       # must match SHA256SUMS.Image in images/
   strings vmlinux | grep uio_pdrv_genirq.of_id=generic-uio

The deploy side — which script writes what, in which order, and how to roll
each step back — is :doc:`setup-prebuilt` Step 0.

The image bank
--------------

Images are identified **by md5 prefix, forever** — logs, handoffs, and
rollback files all refer to images this way. The prefix is a *name*, not
a checksum contract: Vivado place-and-route and ``bootgen`` embed
timestamps and non-deterministic placement, so a functionally identical
rebuild produces a different md5. Equivalence is established by the
gates being green and the on-chip BIST golden reading
``cap_out = 0x04922282``, never by md5 equality.

**The bank below is the 2026-08 development generation**, kept because
the refuted-hypothesis ledger and the handoffs refer to these images by
name. It is *not* the deployment record: what is on the boards today,
and what it carries, is :doc:`provenance` and ``images/CURRENT.txt``.

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
     - skid3 v3 witness-wire — the 2026-08 rig image on 148. Datapath
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
   ``ops/health_probe_reset_aware.sh``, not a naive 0x104 delta —
   0x104 resets every ~5–7 s on a healthy link and a naive 4 s window
   probe reads ~½ rate on a link genuinely running 1245 f/s
   (``docs/evidence/BRINGUP_SEQUENCER.md`` rung 6).
5. **Any failure = halt**: roll back, md5-verify the rollback, **no
   retry variants**, bank the evidence, stop rig work.

RTL-sim harness contract
------------------------

When replaying captures through a netlist (the replay gate, the tap
ladder, the tick-fix campaign), the drive cadence must match the
netlist generation: **Jul-25 netlist = cadence 4; post-Jul-29 (fsv2
lineage and later) = cadence 2** (``docs/evidence/HARNESS_AB.md``). The
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
