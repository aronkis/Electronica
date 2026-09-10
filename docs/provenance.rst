Provenance
==========

Which image is on which board, what it carries, and the lineage that led there.
Identity is by BIST golden ``cap_out = 0x04922282`` and the gate stamps, not md5.

That last point is not pedantry. Vivado place-and-route and ``bootgen``
embed timestamps and non-deterministic placement, so three builds of the
*same* source produce three different md5s. The md5 prefix is how an
image is **named**; whether two images are equivalent is settled by the
gates being green and the on-chip BIST golden reading back correctly.

Current images
--------------

The deployment record is ``images/CURRENT.txt``, which
``ops/deploy_image.sh <ip> A|B`` reads directly — so the file is both
the documentation and the input to the flash tool. As of 2026-09-09 the
two boards no longer share one image:

.. list-table::
   :header-rows: 1
   :widths: 12 40 48

   * - Board
     - Image
     - What it carries
   * - 148 (role A)
     - ``BOOT.BIN.148.rxfixpad.bf2a7305bbe0``
     - W1 witness + R4B ring-skip steering + byte-seam census + PAD
       (truncated frames padded to 191 words so the DMA transfer
       alignment survives them). On the rig since 2026-09-08 17:12.
       Credited forward PER **0.070–0.079 %** with ``WHITEN=1``.
       On-board rollback: ``dec007ae70dd``.
   * - 146 (role B)
     - ``BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db``
     - 148-lineage tree (txfixF3 + SEQ-BIST) + W1 + R4D + R1. On the rig
       since 2026-09-05. Credited reverse PER **0.191 % pooled**,
       level-limited on the lab antennas. On-board rollback:
       ``2728dab3979a``.

Both boards run the same radio profile — ``lvds_61p44_fdd_jupiter``
(61.44 MSPS FDD LVDS DDR, 40 MHz bandwidth, 4 samples/symbol →
15.36 Msym/s, fabric clock 122.88 MHz), armed by ``ops/bringup_r2r3.sh
r3`` and verifiable by reading back
``in_voltage0_sampling_frequency = 61440000``. The boot set is three
files per board, not one: the ``BOOT.BIN`` above, the banked kernel
``Image.6.12.77-uio.a1ba00b51431`` and the per-board qpsk device tree —
deploy the kernel and dtb **before** the image on a fresh board
(:doc:`setup-prebuilt` Step 0). The host daemon is rebuilt from
``host/`` HEAD on every capture leg.

The two receiver fixes assume **opposite** sample-rate-offset signs, so
the A/B role assignment is not interchangeable on a fresh pair — see
:doc:`bringup`. The credited numbers, with their sample counts and the
lost-frame convention, are in :doc:`performance`.

2026-09-10: operator kit relocated to ``ops/``; bring-up and health gate
re-run on both boards, fsync/wcnt 1262 (148) and 1268 (146), clean 12/12
each, no flash (commands in the hygiene plan Task 13).

Lineage
-------

The images above descend from a long build lineage. Two fixes from
early in it are carried by every image since and are worth naming
because their symptoms still appear in old logs:

.. list-table::
   :header-rows: 1
   :widths: 22 34 44

   * - Fix
     - Locus
     - Effect on the live link
   * - CFO reset-storm fix ("rxfix")
     - ``modem/commhdlQPSKTxRxParameters.m`` —
       ``CFOChangeDetectThreshold`` 0.0015625 → 0.0125
     - ``rstcs`` 52/s → 0; frame yield 40 % → 93.5 %
   * - Phase-ambiguity resolver
     - ``resolver_lookback_fix``, git ``8033363``, applied by the
       assemble script
     - The byte plane carries **arbitrary** payloads (99.9 % on
       hardware), not only the golden BIST vector

The 2026-07 lineage below is **history, not deployment**. Its build
trees (``jupiter_byte_*_build/``) were never tracked and exist only on
the build host; the images themselves are either superseded or banked in
``images/``. Full per-build entries, including the forensic notes that
have been abridged here, are in the retired provenance page, preserved
on tag ``archive/pre-cleanup-2026-09-09``.

.. list-table::
   :header-rows: 1
   :widths: 16 22 62

   * - md5
     - Kit / build dir
     - What it was, and where it went
   * - ``dcf5c5fb29e6``
     - ``jupiter_byte_lean_build``
     - **The 2026-07-20 shipped image.** A LEAN debug-strip of P1E-v3:
       instrumentation removed (``QPSK_LEAN=1``; state-pairs
       0x160–0x16C stripped) to restore ZU3EG timing margin while
       keeping every fix — rxfix, resolver, pifix, byte RX FIFO, the
       P1E-v3 tick compensation, the dual-DMA tap, P1D telemetry.
       Deployed to both boards; rollback held v3 ``0de4d5cb``.
       Superseded by the current pair.
   * - ``0de4d5cba0af``
     - ``jupiter_byte_p1e2_build``
     - v3 tick compensation (accumulator-position arm qualifier) + P1D
       telemetry + dual-DMA tap. Deployed 2026-07-19, retained as the
       ``prelean`` rollback.
   * - ``d06f67410d4d``
     - ``jupiter_byte_telemetry_build``
     - T8.7 state telemetry (mux mode 4 = 24-slot state broadcast) and
       mode 5 = CFC output tap. Flashed both boards 2026-07-14.
   * - ``58429a449cf9``
     - ``jupiter_byte_t863_build``
     - T8.6.3 canary2: path canary, interpolation-control shadow with
       the leading-beat compensation, carrier loop-filter shadow. First
       build on which all seven canary registers read zero post-lock —
       every instrument truthful for the first time.
   * - ``a34233c5a3c2``
     - ``jupiter_byte_ch2hard_build``
     - Channel-2 retarget plus hardening and the dual-DMA tap. Held in
       reserve: the RX2 SSI path died on **both** boards during its
       test window, and the morning-golden configuration failed
       identically, which exonerates the image.
   * - ``a498d76d7428``
     - ``jupiter_byte_canary_build``
     - T8.5 canary instrumentation (shadow timing loop, divergence
       counters, strobe forensic) at 0x170–0x188. Its flat-zero
       divergence counters rejected the random-register-corruption
       model.
   * - ``6ed649badc9e``
     - ``jupiter_byte_hard_build``
     - T8.4 timing-loop anti-wedge hardening (interpolation delta clamp,
       integrator clamp, DTC saturate) — the class-4 acquisition-wedge
       fix.
   * - ``6b1b4409017d``
     - ``jupiter_byte_tap_build``
     - The dual-DMA tap that made the ``0x10C`` mux stream reachable
       from the host, by riding the second RX DMA.
   * - ``d32475cb1f42``
     - ``jupiter_byte_ch2tap_build``
     - The channel-2 variant. A/B'd against channel 1 on 2026-07-12;
       channel 1 was adopted.
   * - ``5c85af2cf62d``
     - ``jupiter_byte_pifix_build``
     - **pifix**: demodulator decision boundary returned to the 45° grid
       (it had been skewed 30.68°, the source of a 2–3e-3 floor) and the
       carrier-sync loop gains returned to design.
   * - ``8d6b82ff597e``
     - ``jupiter_byte_rxfix_build``
     - K5 byte modem + rxfix + resolver — but still carrying the
       poisoned demod/CS constants pifix later corrected.
   * - ``447caa20736a``
     - ``jupiter_byte_build``
     - K5 byte modem, pre-rxfix. The image that floored on 148.
   * - ``f351ad874b74``
     - ``jupiter_byte_verify_build``
     - A standalone rebuild of the rxfix source, never deployed. It is
       the reproducibility evidence: a different md5, all gates PASS,
       BIST golden — which is why identity in this project is by
       function, not by hash.

Gate evidence
-------------

Each build gate drops a stamp file, and those stamps in ``modem/`` are
the "green build" evidence a flash decision rests on:
``SIM_BYTE_GATE_K5.txt`` (the model oracle), ``CHECKHDL_240K5_BYTE.txt``
(checkhdl + makehdl), ``S1_GATE.txt`` (the ROM path under iverilog,
per-frame ``cap_out=04922282``) and ``S1B_GATE.txt`` (the byte netlist
under Verilator, rot0 and rot17). The recorded netlist provenance for
the campaign generations is ``docs/evidence/NETLIST_PROVENANCE.md``.

For an image *already on a board*, the check is the same golden by a
different route: arm the ROM source and read ``cap_out`` at 0x144. That
is why the BIST golden, not the md5, is the identity of record — an
image whose md5 you cannot reproduce still proves itself on silicon in
one read. What the gates do **not** cover, and never have, is anything
downstream of the IP pin: the block design, the S2MM egress and the host
are exercised only on hardware.
