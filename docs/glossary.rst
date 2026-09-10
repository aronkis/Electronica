Glossary
========

Terms used across this documentation, in the sense this project uses them.
Where a term names a rate or a rung, the value given is the deployed one
(rung **r3**: 61.44 MSPS, 15.36 Msym/s, 4 samples/symbol); the retired
1.92 MSPS rung is called out explicitly where it still appears in tooling.

.. glossary::
   :sorted:

   rung r3
      The deployed operating point: ADRV9002 LVDS profile
      ``lvds_61p44_fdd_jupiter`` at 61.44 MSPS FDD, 4 samples/symbol,
      15.36 Msym/s, fabric clock 122.88 MHz, 1245 frames/s. Armed by
      ``ops/bringup_r2r3.sh r3``. ``r2`` is the same ladder at 30.72 MSPS /
      7.68 Msym/s.

   240 ksym rung
      The retired original operating point — 1.92 MSPS SSI, 8 samples per
      symbol, 240 ksym/s, profile ``lvds_1p92_mhz``. Only legacy tooling
      (``ops/link_test.sh`` ``ber``/``tun``) still loads it; the banked
      images are not characterised on it. Much of the directory and file
      naming in this repository (``*_240k5_*``, ``*_k5.*``) is a fossil of
      this rung.

   sps
      Samples per symbol — **4** on rung r3.

   SSI
      The synchronous serial (LVDS) interface between the FPGA fabric and
      the ADRV9002 transceiver. 61.44 MSPS on rung r3.

   QPSK
      The modulation: π/4-rotated, Gray-coded quadrature phase-shift
      keying, 2 bits per symbol.

   sqrt-RRC
      The root-raised-cosine pulse-shaping filter, roll-off β = 0.5, used
      as the TX interpolator and the RX matched filter.

   Barker
      The 13-symbol known preamble prepended to every air frame, used by
      the preamble detector for frame start and by the phase-ambiguity
      resolver for quadrant resolution.

   K5
      The rate-1/2, constraint-length-5 convolutional code
      ``poly2trellis(5,[35 23])`` used for forward error correction, with
      a hard-decision Viterbi decoder at traceback depth 25 (**TB=25**).
      "K5" also names the earlier 1024 B frame geometry that preceded
      f1536.

   interleaver
      The block interleaver between the encoder and the symbol mapper. It
      is ping-pong: air frame N carries the encode of byte frame N−1, so
      the TX byte branch has exactly one frame of latency.

   f1536
      The deployed frame format, named for its 1536-byte host slot class:
      12,333 symbols per frame, 803 µs frame period, 191 × 64-bit
      delivered payload words (1528 B). See :doc:`system-overview`.

   CFC
      Coarse Frequency Compensator — removes bulk carrier frequency
      offset ahead of the timing and carrier loops. Its estimate is
      readable at register 0x154.

   SS
      Symbol Synchronizer — the Gardner timing-recovery loop.

   CS
      Carrier Synchronizer — a phase-locked loop whose NCO/DDS derotates
      the carrier.

   NCO/DDS
      The numerically-controlled oscillator (direct digital synthesizer)
      inside the carrier synchronizer that applies the derotation.

   FTS
      Frequency-and-Time Synchronizer — the subsystem holding the symbol
      synchronizer and the carrier synchronizer.

   IC
      Interpolation Control — the symbol synchronizer's timing
      (interpolation-index) loop.

   Gardner
      The timing-error-detector algorithm used by the symbol
      synchronizer.

   phase-ambiguity resolver
      The stage that resolves the QPSK four-fold (±90° / 180°) phase
      ambiguity to the correct quadrant using the preamble. Without it
      the receiver locks to the wrong quadrant for any payload other than
      the golden BIST vector; ``resolver_lookback_fix`` (git ``8033363``)
      is the fix that made arbitrary data work.

   byte plane
      Everything between the demodulator's decoded bits and the host's
      DMA buffer — ByteSerializer, platform byte FIFO, ``rx_byte_dma``,
      and the TX mirror. Selected as the TX bit source by
      ``tx_data_source`` (register 0x158); the alternative source is the
      in-fabric pre-coded ROM used for BIST. See :doc:`byte-plane`.

   CFO
      Carrier Frequency Offset — the TX/RX local-oscillator mismatch the
      CFC and CS remove.

   CFOChangeDetectThreshold
      The modem parameter that triggers a carrier-sync reset on a
      detected CFO step. Set too low it false-fires; raising it
      0.0015625 → 0.0125 is the ``rxfix`` change.

   quiet pair
      The FDD frequency plan chosen by RF survey for the lab pair:
      forward 2.00 GHz, reverse 1.90 GHz, dodging board 148's 2.10 GHz
      TX-LO leakage. It is board-specific — a different pair must
      re-survey.

   ENSM
      The ADRV9002 ENable State Machine (``calibrated`` / ``rf_enabled``
      modes).

   LVDS profile
      The ADRV9002 stream (``.bin``) and profile (``.json``) pair loaded
      into the driver at arm, from ``ops/profiles/``. The deployed pair
      is ``lvds_61p44_fdd_jupiter.{bin,json}``; **both files must be
      present in** ``/root/`` **on the board** — a missing file leaves the
      previous profile running while the log still says armed.

   BBDC
      Baseband DC offset rejection. Its tracking calibration on unit 148
      is the source of the tick.

   near-end loopback
      The ADRV9002 ``rx0_near_end_loopback``: a unit's transmitter looped
      to its own receiver through the ADC path, with no cable and no air.
      Distinct from the fabric-internal loopback selected by register
      0x114 = 0.

   the tick
      Board 148's BBDC rejection tracking calibration firing about every
      1.5 s and inserting 256 samples (= +32 symbols) into the RX stream
      delivered to the modem. Per-unit, chip-level, on both of 148's RX
      paths, absent on 146, over-the-air only. It is a device artifact,
      not a fabric bug: ``docs/evidence/ESCALATION_ADI.md``.

   mosaic window
      The single physically-inserted frame per tick that is
      information-theoretically unrecoverable — what remains after the
      fabric compensation recovers the displaced frame.

   stale-grid
      The deinterleaver window displaced by the tick's +32 symbols; the
      casualty class the ``p1e_comp`` compensation cancels.

   splice
      A testbench that injects a +256-sample insertion into a captured
      stream to reproduce the tick offline.

   error classes 1–4
      The loss taxonomy: 1 = tick episodes, 2 = between-episode scatter,
      3 = rare frame mangling, 4 = acquisition wedge. Silicon signatures
      for each are in ``docs/evidence/ERROR_TAXONOMY.md``.

   reset storm
      A burst of spurious carrier-sync resets (~52/s) caused by a
      too-low ``CFOChangeDetectThreshold``; fixed by ``rxfix`` and
      watched through the ``rstcs`` counter at 0x150.

   rxfix
      The CFO reset-storm fix: ``CFOChangeDetectThreshold``
      0.0015625 → 0.0125.

   pifix
      Restores the demodulator decision boundary to the 45° grid and
      corrects the carrier-sync loop gains.

   tafix
      The Timing-Adjust offset-tracking fix (class-1 casualties).

   p1e_comp
      The fabric compensation for the tick's +32-symbol displacement — an
      accumulator-position-qualified deinterleaver skip. On a board that
      does not tick it is a no-op.

   timing_hardening
      The anti-wedge clamps (interpolation-control delta clamp,
      loop-filter integrator clamp) that make the class-4 timing-loop
      deadlock impossible by construction.

   LEAN image
      A build with the debug instrumentation stripped (``QPSK_LEAN=1``)
      to restore timing margin on the ZU3EG, keeping every functional
      fix. All shipped images are LEAN; the runtime loop-gain registers
      at 0x170–0x184 exist only in LEAN builds.

   W1
      The witness-word generation carried by both deployed images: extra
      fabric counters exposing the RX ring state. Register map:
      ``docs/evidence/rxfix/W1_REGMAP.md``.

   R4B / R4D / R1
      The RX ring-steering fixes. Board 148 carries R4B, board 146
      carries R4D + R1. They assume **opposite** sample-rate-offset
      signs, so a fresh pair must measure the RX-LO residual sign before
      choosing (``docs/evidence/RXFIX_STATE.md``).

   PAD
      The fabric fix that pads a truncated frame out to 191 words so the
      DMA transfer alignment survives it; carried by 148's deployed
      image.

   cap_out
      The BIST golden readback at register 0x144. ``0x04922282`` means
      the receiver decoded the ROM vector correctly; it is the project's
      image-identity check, used in preference to md5.

   rstcs
      The carrier-sync reset counter at register 0x150. Flat is healthy;
      a growing delta is a reset storm, which usually means the wrong or
      an old image.

   packets_out
      The cumulative decoded-frame counter at register 0x104, used as the
      liveness/lock signal. It is **reset-prone** — see
      :doc:`measurement-discipline` before deriving any rate from it.

   framestat
      The per-frame telemetry block in instrument images: a 64-bit record
      per frame latched into a side FIFO, plus free-running word, stall
      and TX-underrun counters. Its record layout carries checkpoint CP1.
      Full contract: ``docs/evidence/FRAMESTAT_NOTES.md``.

   CP1 / CP2 / CP3
      The three checkpoints along the RX delivery path: CP1 is the
      fabric-side checksum at the ByteSerializer output (framestat),
      CP2 and CP3 are host-side fold checksums either side of the
      DMA-buffer → host-copy seam. Comparing them localizes where
      corruption enters.

   DRA
      ``direct_reg_access``, the IIO debugfs register window into the
      modem AXI space. It is a **single address latch**: two concurrent
      readers corrupt each other's reads, and a read taken while the
      board's transceiver is being armed hangs the PS until a power
      cycle.

   IQ debug mux
      The tap selector at register 0x10C — 0 AGC output, 1 post-symbol-
      sync, 2 post-carrier-sync, 3 constellation — routed to the second
      RX DMA channel in tap-enabled images.

   Tap-A
      The safe ``iio_readdev`` capture path. The modem S2MM capture path
      wedges the board above 512 KB; Tap-A does not.

   canary / shadow
      Debug instruments (shadow copies of loop state, divergence
      counters) at 0x170–0x1A0 in non-LEAN builds. They are stripped in
      LEAN images, where the same offsets mean the runtime loop-gain
      registers instead.

   verified lock
      The deterministic acquisition procedure — watchdog, then probe,
      then reset and re-arm on failure — that makes an otherwise
      stochastic lock reliable. See :doc:`bringup`.

   golden vector
      The fixed BIST payload the in-fabric ROM source radiates
      (``contract/golden_k5.mat``); a correct decode reads back
      ``cap_out = 0x04922282``.

   whitener
      The host-side payload whitener, enabled with ``QPSK_WHITEN=1``.
      It is **both-ends-or-nothing** and is on by default in bring-up:
      without it the daemon's idle frames are a constant byte pattern
      containing preamble-like stretches that the detector locks onto,
      truncating the following frame.

   result buckets
      The ``qpsk_tun -B`` per-frame verdicts: **CLEAN** (aligned, no bit
      errors), **NOISY** (aligned, under 10 % bit errors), **ROTATED** (a
      word rotation aligns it), **PHASE** (aligned but ≥ 35 % wrong — a
      quadrant mis-lock) and **MISS** (none of the above: lost or
      unaligned). Only CLEAN and NOISY feed BER.

   daemon modes
      ``qpsk_tun`` operating modes: ``-B`` full-packet BER scorer, ``-F``
      / ``-G`` forward TUN daemon, ``-S`` loss-proof sequence-stream
      scorer, ``-M K`` multi-drain factor.

   wedge
      A self-sustaining link collapse in which the RX drains junk and the
      TX starves. Root-caused host-side and fixed by the RX drain budget;
      see :doc:`host-software`.

   banked image
      A built ``BOOT.BIN`` identified by md5 prefix and stored in
      ``images/``. Banking is deliberately separate from flashing: a
      green gate matrix makes an image flash-eligible, and flashing stays
      an explicit operator decision.
