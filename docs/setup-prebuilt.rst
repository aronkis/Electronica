Setup with pre-built images
===========================

This page is for a user who wants a **running link from the pre-built
boot images only** — no MATLAB, no Vivado, no image builds. Everything
you need is in the repository: the boot images in ``boot_known_good/``,
the host daemon source in ``host_app_k5/`` (built on-board with gcc in
seconds), and the operational scripts in ``two_jup/``.

If you are going to *build* images, read :doc:`build-and-flash`
instead; this page deliberately covers only the deploy-and-run path.

What you need
-------------

* Two ADALM-Jupiter boards on the LAN as **10.0.0.146** and
  **10.0.0.148** (canonical host facts: ``HOSTS.md`` in the infra
  repo). Antennas on Tx1/Rx1 of both boards.
* A Linux control host with this repository cloned, password ssh to
  ``root@`` both boards (the scripts drive it via
  ``two_jup/anyssh.sh`` + ``two_jup/askpass.sh``), and ``python3``.
* Boards running the stock ADALM-Jupiter Linux with the FAT boot
  partition mounted at ``/boot``.

The image bank
--------------

``boot_known_good/`` holds the five load-bearing images, named
``BOOT.BIN.<board>.<lineage>.<md5-12>``. The same files are published
alongside this documentation, so they can be fetched **without
repository access** — every image below is a direct download link, and
the checksum manifest is `MD5SUMS <MD5SUMS>`_ (bank notes:
`README.md <README.md>`_). For example::

   BASE=https://tfcollins.github.io/qpsk-jupiter-modem
   curl -fLO $BASE/BOOT.BIN.146.tmr.433fd8dab393
   curl -fLO $BASE/MD5SUMS

All five: `BOOT.BIN.146.tmr.433fd8dab393 <BOOT.BIN.146.tmr.433fd8dab393>`_ ·
`BOOT.BIN.146.tmrfresh.4be9286ca111 <BOOT.BIN.146.tmrfresh.4be9286ca111>`_ ·
`BOOT.BIN.146.vendh.ec414d2df8bc <BOOT.BIN.146.vendh.ec414d2df8bc>`_ ·
`BOOT.BIN.148.beatfix3.fe5bd8a4fe19 <BOOT.BIN.148.beatfix3.fe5bd8a4fe19>`_ ·
`BOOT.BIN.148.lean.e49c011b7a75 <BOOT.BIN.148.lean.e49c011b7a75>`_

Verify before every use (repo checkout shown; for downloads run it in
the download directory)::

   cd boot_known_good && md5sum -c MD5SUMS

Recommended pairing for a plain running link:

.. list-table::
   :header-rows: 1
   :widths: 12 30 58

   * - Board
     - Image
     - Why
   * - 146
     - ``BOOT.BIN.146.tmr.433fd8dab393``
     - Best-measured 146 image overall (saturated 10.62 % / idle
       9.33 % at the stock LO era).
   * - 148
     - ``BOOT.BIN.148.beatfix3.fe5bd8a4fe19``
     - The validated BEATFIX v3 image (fixctl\@0x208 and the tgen /
       beat-ILA instruments). **Caveat:** its rx-lpc IQ capture tap is
       structurally a ramp — if you need IQ captures for the float /
       BER oracles, flash ``BOOT.BIN.148.lean.e49c011b7a75`` instead
       and accept losing BEATFIX.

The ``boot_known_good/README.md`` manifest documents all five images,
their measured performance, and their caveats.

Step 1 — flash the images
-------------------------

For each board (146 shown; repeat for 148 with its image): back up the
live image on-board, stage with an md5 check, then reboot::

   D=two_jup; IP=10.0.0.146
   IMG=boot_known_good/BOOT.BIN.146.tmr.433fd8dab393
   MD5=$(md5sum $IMG | cut -c1-12)

   # on-board backup of whatever is currently flashed
   $D/anyssh.sh $IP 'cp /boot/BOOT.BIN /root/BOOT.BIN.prev.bak && sync'

   # stage (NOTE: plain scp silently writes 0-byte files to these
   # boards -- always use the SSH_ASKPASS form below)
   SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
     setsid -w scp -o StrictHostKeyChecking=no \
     -o PreferredAuthentications=password $IMG root@$IP:/boot/BOOT.BIN.new

   # verify the staged copy, then commit + reboot
   $D/anyssh.sh $IP "md5sum /boot/BOOT.BIN.new | grep -q ^$MD5 \
     && mv /boot/BOOT.BIN.new /boot/BOOT.BIN && sync && reboot"

   # after ~60 s: readback verify
   $D/anyssh.sh $IP 'md5sum /boot/BOOT.BIN | cut -c1-12'   # must equal $MD5

If a board is already running a campaign image and you are changing it,
prefer the rails scripts (``two_jup/skidfix/flash_148_beatfix2.sh``,
``flash_146_vendh.sh`` family) — they add the full gate set
(precondition, rollback bank, post-flash health gate, auto-rollback).
See :doc:`build-and-flash` for the rails.

Step 2 — deploy the host daemon
-------------------------------

The daemon builds on-board in seconds (no cross-compiler). From the
repo root, for each board::

   D=two_jup; SRC=host_app_k5
   for IP in 10.0.0.146 10.0.0.148; do
     $D/anyssh.sh $IP 'mkdir -p /root/host_app_k5'
     SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
       setsid -w scp -o StrictHostKeyChecking=no \
       -o PreferredAuthentications=password \
       $SRC/qpsk_tun.c $SRC/qpsk_frame.c $SRC/qpsk_frame.h \
       $SRC/qpsk_hw.h $SRC/qpsk_uio.c $SRC/qpsk_uio.h $SRC/qpsk_seq.c $SRC/qpsk_seq.h $SRC/qpsk_ber.c $SRC/qpsk_ber.h $SRC/qpsk_perf.c \
       root@$IP:/root/host_app_k5/
     $D/anyssh.sh $IP 'cd /root/host_app_k5 && \
       gcc -O2 -Wall -DQPSK_CARVE_2MB -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_uio.c qpsk_seq.c qpsk_ber.c && \
       gcc -O2 -o qpsk_perf qpsk_perf.c && echo BUILD_OK'
   done

Also stage the on-board watchdog once per board::

   for IP in 10.0.0.146 10.0.0.148; do
     SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
       setsid -w scp -o StrictHostKeyChecking=no \
       -o PreferredAuthentications=password \
       $D/lock_watchdog.sh root@$IP:/root/lock_watchdog.sh
   done

Step 3 — bring the link up
--------------------------

One command does the whole two-board ceremony (radio profiles, LO plan,
ROM arm with the double-tap that defeats the false-lock latch, SSI
overrides, daemons, stream-first byte-source flip, watchdogs)::

   cd two_jup && bash restore_known_good.sh

Notes:

* The RX daemons run in **queued-request DMA mode** by default
  (``QPSK_RX_QUEUED=1``, set 2026-08-27): the next S2MM transfer is
  pre-armed in hardware instead of the host resetting the engine after
  every transfer. Measured forward PER 13.9 % → 8.7–8.9 % on the same
  protocol with no fabric change; ``RXQ=0`` restores the legacy path.
* **Never read modem/ADC-core registers (``direct_reg_access``) on a board
  while its transceiver is being armed** — the read hangs the board's PS
  until a power cycle (root cause of the 148 "no-ping" outages). The
  bring-up kills the on-board watchdog first; host-side probes carry an
  arm-in-flight guard (``two_jup/sim_repro/no_arm_inflight.sh``) and all
  rig actors take ``RIG_LOCK`` (``two_jup/sim_repro/riglock.sh``).
* The stock ``/usr/bin/fan-control`` uses a stale gpio base (334); this
  kernel's ``zynqmp_gpio`` base is 516 — patch it or the fan is never
  commanded and the software over-temperature power-off never fires.
* The reverse RX LO defaults to **+40 kHz off-null** (``LO_B_RX=1900040000``,
  set 2026-08-28 from a sweep: 1.39 % vs 1.99 % at the old +2.5 kHz).
* The forward RX LO defaults to **+20 kHz off-null**
  (``LO_A_RX=2000020000``, set 2026-08-26). This is deliberate: the
  receiver tracking defect is CFO-sign-asymmetric and this operating
  point halves the forward loss. Do not "fix" it back to the plain LO.
* If you flashed the BEATFIX image on 148, arm the fix after bring-up::

     ./anyssh.sh 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
       echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
       echo "0x208 0x3" > $DRA'

  (write-only register — verified by effect, never by readback).

Step 4 — verify
---------------

Use the reset-aware probe (the legacy 4-second delta probe races
watchdog resets — do not use it)::

   bash health_probe_reset_aware.sh 10.0.0.148 12   # forward (146 TX -> 148 RX)
   bash health_probe_reset_aware.sh 10.0.0.146 12   # reverse (148 TX -> 146 RX)

Healthy: ``fsync≈1245 wcnt≈1245 clean=12/12``. Expected imperfections,
all documented (:doc:`current-state`, ``two_jup/KNOWN_HOLES.md``):

* Forward steady loss ~6 % and reverse ~2.6–2.9 % — the open
  receiver-tracking defect; the < 1 % campaign gate is **not yet met**.
* 146's receiver intermittently degrades to ~510–700 f/s (the
  "arm-lottery" class). Re-run ``restore_known_good.sh`` to redraw.
* Occasional multi-thousand-frame bursts and roughly hourly delivery
  wedges; the on-board watchdogs plus (on the control host) the
  ``delivery_sentinel.sh`` recovery loop handle them.

The link is now a TUN network: ``10.66.0.1`` (146) ⟷ ``10.66.0.2``
(148); test with ``ping`` across the tun addresses or
``qpsk_perf -s`` / ``-c`` for saturating UDP.

Operational rules (read before touching anything)
-------------------------------------------------

* One rig harness at a time; restore + verified watchdogs after every
  session.
* Never ``pkill`` a pattern present in your own command line — bracket
  it (``[l]ock_watchdog``).
* Registers ``0x114/0x118/0x158`` (and ``0x208``) are write-only:
  verify by effect, never readback.
* Any PER/BER claim needs the exact command, the sample count, and
  dropped frames in the denominator — and single 60 s windows can be
  inflated ~+7 pp by one burst; use multi-window minima/medians
  (:doc:`measurement-discipline`).
