Testing
=======

Tier A (self-loopback, no RF), Tier B (on-chip BIST), Tier C (over the air), and
the MATLAB unit suite ``tests/runTests.m`` (L1 host-pure, L2 gates, L3 hardware).

The acceptance ladder is deliberately ordered: a failure at rung *N*
localizes the fault below rung *N+1*. If rung 2 fails while rung 1
passes, the problem is the FPGA image, not the host logic. Run it top to
bottom and stop at the first red rung.

Tiers
-----

The operator entry point is ``ops/test.sh``, which drives
``ops/link_test.sh`` underneath::

   cd ops
   ./test.sh loopback          # Tier A: self-loopback, host + internal FPGA, no RF
   ./test.sh bist              # Tier B: on-chip BIST comparator (golden cap_out)
   ./test.sh ber               # Tier B: host full-packet scorer (buckets + BER)
   ./test.sh link --radios 2   # Tier C: real data, two-board FDD pair
   ./test.sh link --radios 1   # Tier C: single-board RF loopback (needs a cable)
   ./test.sh all               # the ladder: host tests -> preflight -> ber

.. list-table::
   :header-rows: 1
   :widths: 10 26 34 30

   * - Rung
     - Command
     - What it proves
     - Healthy
   * - 1. Host contract
     - ``test.sh loopback`` (host part)
     - The frame, FEC, scorer and whitener logic is correct off
       hardware
     - every host unit test 0-failed
   * - 2. Digital loopback
     - ``test.sh loopback`` (board part)
     - The FPGA datapath decodes its own transmit with
       ``rx_input_select = 0`` — no RF involved
     - echo CRC-pass **and** ``-B`` BER ≈ 0
   * - 3. On-chip BIST
     - ``test.sh bist``
     - The in-fabric pattern generator and comparator lock
     - ``cap_out`` (0x144) = ``0x04922282``, bit-error counter low and
       flat
   * - 4. Real link
     - ``test.sh ber`` / ``link --radios 2``
     - The RF link carries data both directions
     - the reset-aware health gate passes (``fsync≈1245 wcnt≈1245``,
       ``rstcs`` delta ≈ 0) — :doc:`bringup`
   * - 5. IP and SSH
     - ``link_test.sh tun`` / ``ssh``
     - IP-over-RF, and an encrypted session, survive the link
     - ``tun0`` up both ways; the ``RF-SSH-OK`` token

**Tier A — self-loopback, no RF.** The host unit tests run on any
machine (``make -C host test``): frame encode/decode with every
single-bit corruption caught, the K5 FEC path, the bucket scorer, and
the whitener's self-inverse and transparency properties. On-board,
``ops/ber_loopback_gate.sh <ip>`` arms **one** board with
``rx_input_select = 0`` (0x114 = 0) so the receiver decodes that board's
own transmit with no RF at all, then runs the daemon's self-test, echo
and ``-B`` modes. Its decision table is the useful part: echo passes and
``-B`` is clean ⇒ the FPGA datapath is sound and over-the-air work is
unblocked; echo passes but ``-B`` errors ⇒ a tool bug; both fail ⇒ an
arm or image problem. This is the calibration gate before any RF test.
Offline, ``modem/rtl_sim/`` carries the Verilator and iverilog harnesses
that are also the build-time S1B and S1 netlist gates
(:doc:`build-and-flash`).

**Tier B — two distinct BER mechanisms.** Keep them straight. The
*on-chip BIST* (``ops/measure_ber.sh``) reads the in-fabric comparator's
counters — ``packets_out`` 0x104, ``bit_errors`` 0x108, ``cap_out``
0x144 — and is most meaningful while a link or an internal loopback is
armed, since the comparator needs the internal pattern flowing; on an
idle board it simply reads the last locked golden. The *host full-packet
scorer* (``qpsk_tun -B``) radiates a fixed reference payload and scores
**every** received packet, including CRC failures — they are where the
errors are — into the five result buckets (see the :doc:`glossary`).
Only CLEAN and NOISY feed BER; ROTATED, PHASE and MISS do not.

**Tier C — real data.** Two radios exercise the FDD pair (forward
146 → 148 at 2.00 GHz, reverse 148 → 146 at 1.90 GHz): ``ber`` is the
read-only-safe quality metric, ``tun`` brings ``tun0`` up both ways, and
``ssh`` runs an encrypted session over it. Judge quality by ``ber`` or
``ssh``, **not** by ping — ping payloads are low-entropy and lossy even
on a good link. One radio (``ops/rf_loopback.sh``) exercises the real
DAC → PA → external cable and attenuator → LNA → ADC chain with TX LO =
RX LO; it is distinct from Tier A's *digital* loopback, is ready to run,
and has never been exercised in this kit because no loopback cable was
present.

Credited PER is not part of this ladder — the ladder proves the link
works. What "credited" means, and the discipline behind it, is
:doc:`performance` and :doc:`measurement-discipline`.

The MATLAB suite
----------------

``tests/runTests.m`` is the single entry point. It discovers every
``matlab.unittest`` ``TestCase`` under ``tests/``, selects by level tag,
emits JUnit-XML and TAP into ``tests/results/``, and exits non-zero on
failure under ``matlab -batch``. ``tests/README.md`` is the full guide::

   matlab -batch "cd tests; runTests"                     # L1 host-pure (< 3 min)
   matlab -batch "cd tests; runTests('L2')"                # HDL gate stamps
   QPSK_HIL=1 matlab -batch "cd tests; runTests('L3')"     # RF link, both boards
   sudo -E matlab -batch "cd tests; runTests"              # adds the root-gated tun/tap tests

.. list-table::
   :header-rows: 1
   :widths: 10 56 34

   * - Level
     - Scope
     - Needs
   * - **L1**
     - The C tests, the MATLAB ↔ C frame contract, the byte and decode
       self-tests, and tun/tap loopback
     - nothing — the tun/tap tests need root and report Incomplete
       without it
   * - **L2**
     - The HDL gate verdicts, by stamp check; ``RUN_GATES=1`` actually
       runs the suite (~30 min)
     - MATLAB, and Vivado to execute rather than check
   * - **L3**
     - tun bring-up, latency, UDP and TCP throughput, SSH usability
     - ``QPSK_HIL=1`` and both boards

L3 automates the Tier-C operator procedure through ``ops/link_test.sh``,
so it inherits every rig rule: it arms boards, and an arm is never safe
to run concurrently with a register read (:doc:`bringup`).

Host C tests
------------

The host tests build and run off-board with ``make -C host test``, and
each one is a contract test rather than a smoke test: the frame test
asserts that *every* single-bit corruption is caught, the whitener test
asserts self-inverse and transparency, and the bucket scorer test is the
same code path the on-board ``qpsk_tun -T`` self-test exercises, so a
green host run and a green on-board self-test mean the same thing. The
``modem_status`` TUI has its own suite — ``make test_modem_status`` in
``host/`` — which runs its 228 checks against a fake source, so it needs
no hardware.

On-board prerequisites
----------------------

``ops/link_test.sh preflight`` verifies that each board carries the
daemon at ``/root/host_app_k5/qpsk_tun``, the deployed-rung LVDS profile
pair in ``/root/``, the lock watchdog, and working modem register
access. Install all of it with ``ops/provision.sh <ip>``, after the
kernel, device tree and boot image (:doc:`setup-prebuilt`).

Preflight **reads registers**, so never run it while a bring-up or an
arm is in flight on either board. Board scratch and logs go to
``/dev/shm``, never ``/tmp``.

Safety
------

Tiers B and C touch fragile hardware, and Jupiter has **no remote
power** — a wedge costs a physical power cycle. The test scripts honour
a fixed set of rules, and so should anything new: never write
``BOOT.BIN`` from a test; never request an RX S2MM capture over 512 KB;
one ``anyssh`` session per board arm; the two boards arm in parallel but
never two concurrent sessions to the *same* board (the ``A_IP == B_IP``
guard enforces this); board scratch to ``/dev/shm``. On any board cycle,
quiesce and stop.
