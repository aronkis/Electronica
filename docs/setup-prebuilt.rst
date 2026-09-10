Setup with pre-built images
===========================

This page is for a user who wants a **running link from the pre-built
boot images only** — no MATLAB, no Vivado, no image builds. Everything
you need is in the repository: the boot images in ``images/``,
the host daemon source in ``host/`` (built on-board with gcc in
seconds), and the operational scripts in ``ops/``.

If you are going to *build* images, read :doc:`build-and-flash`
instead; this page deliberately covers only the deploy-and-run path.

What you need
-------------

* Two ADALM-Jupiter boards on the LAN as **10.0.0.146** and
  **10.0.0.148** (canonical host facts: ``HOSTS.md`` in the infra
  repo). Antennas on Tx1/Rx1 of both boards.
* A Linux control host with this repository cloned, password ssh to
  ``root@`` both boards (the scripts drive it via
  ``ops/anyssh.sh`` + ``ops/askpass.sh``), and ``python3``.
* Boards running the stock ADALM-Jupiter Linux with the FAT boot
  partition mounted at ``/boot``.

The image bank
--------------

``images/`` holds the banked images, named
``BOOT.BIN.<board>.<lineage>.<md5-12>``, with the checksum manifest
`MD5SUMS <MD5SUMS>`_ and per-image notes in `README.md <README.md>`_.
The same files are published alongside this documentation, so they can
be fetched **without repository access**::

   BASE=https://tfcollins.github.io/qpsk-jupiter-modem
   curl -fLO $BASE/BOOT.BIN.148.rxfixpad.bf2a7305bbe0
   curl -fLO $BASE/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db
   curl -fLO $BASE/Image.6.12.77-uio.a1ba00b51431.gz        # kernel Image (gzip, 14 MB)
   curl -fLO $BASE/system-qpsk.148.dtb.1da3a9cf05a0         # qpsk device tree, board 148
   curl -fLO $BASE/system-qpsk.146.dtb.19e974098b6e         # qpsk device tree, board 146
   curl -fLO $BASE/system.dtb.pristine.148.3334673acf50     # stock ADI reference dtb, 148
   curl -fLO $BASE/system.dtb.pristine.146.dba6d8f74aac     # stock ADI reference dtb, 146
   curl -fLO $BASE/MD5SUMS
   curl -fLO $BASE/SHA256SUMS.Image

The boot set is **three files per board**: ``BOOT.BIN`` (FPGA bitstream +
FSBL/PMU/ATF/U-Boot), ``/boot/Image`` (the UIO-enabled kernel) and
``/boot/system.dtb`` (the qpsk device tree). All three are banked here and
all three are what the rig boards run today (readback 2026-09-09):

.. list-table::
   :header-rows: 1
   :widths: 30 36 34

   * - File
     - Identity
     - What it is
   * - `Image.6.12.77-uio.a1ba00b51431.gz <Image.6.12.77-uio.a1ba00b51431.gz>`_
     - raw ``Image`` sha256 ``a1ba00b5…cfbffe0b5`` (`SHA256SUMS.Image <SHA256SUMS.Image>`_); ``uname -r`` = ``6.12.77-gcfe32235a832-dirty``
     - ADI kernel ``xlnx/release/v6.12.y-2026r1`` @ ``cfe32235`` with
       ``CONFIG_UIO_PDRV_GENIRQ=y`` built in and
       ``uio_pdrv_genirq.of_id=generic-uio`` baked into the command line
       (``CONFIG_CMDLINE_EXTEND``). Same Image on both boards. Rebuild
       recipe: :doc:`build-and-flash`, "Kernel provenance".
   * - `system-qpsk.148.dtb.1da3a9cf05a0 <system-qpsk.148.dtb.1da3a9cf05a0>`_ /
       `system-qpsk.146.dtb.19e974098b6e <system-qpsk.146.dtb.19e974098b6e>`_
     - md5-12 in the name
     - The stock dtb with ``modem/boot/qpsk_byte_uio.dtso`` merged in
       (``deploy_dtb.sh build`` substitutes the SPI cells and compiles it): a
       2 MB reserved carve at ``0x7FE00000`` and the three ``qpsk_*`` UIO
       nodes (SPI cells 110/111). **Per board** — the base dtbs differ.
   * - `system.dtb.pristine.148.3334673acf50 <system.dtb.pristine.148.3334673acf50>`_ /
       `system.dtb.pristine.146.dba6d8f74aac <system.dtb.pristine.146.dba6d8f74aac>`_
     - md5-12 in the name
     - The **reference** ADI ADALM-Jupiter ``system.dtb`` each board shipped
       with, pulled read-only before the first overlay build. Rollback
       target, and the ``BASE_DTB`` input if you rebuild the qpsk dtb.

Verify before every use (repo checkout shown; for downloads run it in
the download directory)::

   cd images && md5sum -c MD5SUMS

**The current best pair (2026-09-09)** — the roles ``A`` and ``B`` in
``images/CURRENT.txt``, which ``ops/deploy_image.sh`` reads:

.. list-table::
   :header-rows: 1
   :widths: 10 34 56

   * - Board
     - Image
     - Why
   * - 148 (role A)
     - `BOOT.BIN.148.rxfixpad.bf2a7305bbe0 <BOOT.BIN.148.rxfixpad.bf2a7305bbe0>`_
     - W1 witness + R4B ring-skip steering + byte-seam census + PAD
       (truncated frames padded to 191 words). Credited forward PER
       **0.070–0.079 %** with payload whitening on, the bring-up default
       (``images/CURRENT.txt``; ``docs/evidence/RXFIX_STATE.md``).
       Rollback on the board: ``dec007ae70dd``.
   * - 146 (role B)
     - `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db <BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db>`_
     - 148-lineage tree (txfixF3 + SEQ-BIST) + W1 + R4D + R1. Credited
       reverse PER **0.191 % pooled** over three legs
       (``docs/evidence/RXFIX_STATE.md`` Task 37), level-limited on the
       lab antennas. Rollback on the board: ``2728dab3979a``.

Two caveats before flashing a **fresh** pair: the two receiver fixes
assume opposite sample-rate-offset signs (R4B on A wants the receiver's
oscillator to be the faster one, R4D+R1 on B the slower — measure the
RX-LO residual sign first, ``docs/evidence/RXFIX_STATE.md`` "Sign cross-check");
and payload whitening is both-ends-or-nothing (``bringup_r2r3.sh``
defaults ``WHITEN=1``; a daemon started by hand needs ``QPSK_WHITEN=1``).

Older banked images (``tmr``, ``tmrfresh``, ``vendh``, ``beatfix3``,
``lean``, ``txfixF3``, ``seqbist``, ``rxfixr4b``, ``rxfixbs``) remain in
the bank for provenance and rollback; ``README.md`` there has every row.

Step 0 — kernel Image and device tree (once per board)
-------------------------------------------------------

Fresh boards (or boards rolled back to stock) need the UIO kernel and the
qpsk dtb **before** the modem BOOT.BIN is useful: the host daemon maps the
2 MB carve and binds the three UIO nodes, neither of which the stock kernel
and dtb provide. Order per board: kernel, then dtb, then BOOT.BIN (Step 1),
one board at a time, confirming each reboot. Jupiter has no remote power:
every one of these scripts backs up the file it replaces on the board and
has a ``rollback`` subcommand — see each script's header for the full
envelope, and :doc:`build-and-flash` for how the kernel was built. Skip this step if ``uname -r`` on the board already reads
``6.12.77`` and ``/sys/class/uio`` lists ``qpsk_tx_dma``/``qpsk_rx_dma``/``qpsk_byte_gpio``::

   cd images && md5sum -c MD5SUMS
   gunzip -kf Image.6.12.77-uio.a1ba00b51431.gz       # -> Image.6.12.77-uio.a1ba00b51431 (48 MB, untracked)
   sha256sum -c SHA256SUMS.Image                      # raw Image identity
   cd ../ops
   ./deploy_kernel.sh check ../images/Image.6.12.77-uio.a1ba00b51431  # size + ARM64 magic + sha256 (no board)
   ./deploy_kernel.sh 10.0.0.148 ../images/Image.6.12.77-uio.a1ba00b51431          # backs up /boot/Image, reboots, verifies
   ./deploy_dtb.sh check ../images/system-qpsk.148.dtb.1da3a9cf05a0
   ./deploy_dtb.sh 10.0.0.148 ../images/system-qpsk.148.dtb.1da3a9cf05a0
   # then the same for 146 with system-qpsk.146.dtb.19e974098b6e

The kernel verify is hard on two facts: ``uname -r`` contains ``6.12.77``
and ``uio_pdrv_genirq.of_id=generic-uio`` is in ``/proc/cmdline``. The dtb
verify wants the carve claimed in ``/proc/iomem`` and the three qpsk UIO
nodes bound. Rollback: ``./deploy_kernel.sh rollback <ip>`` and
``./deploy_dtb.sh rollback <ip>`` (or deploy the banked
``system.dtb.pristine.<board>.*`` file to return to stock).

Step 1 — flash the images
-------------------------

The one-command way, one board at a time (backs up ``/boot/BOOT.BIN``
on the board, size-checks the staged copy, flashes, reboots, waits for
the board to come back and prints the readback md5)::

   cd ops
   ./deploy_image.sh 10.0.0.148 A      # role A = BOOT.BIN.148.rxfixpad.bf2a7305bbe0
   ./deploy_image.sh 10.0.0.146 B      # role B = BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db
   ./anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN'   # bf2a7305bbe0...
   ./anyssh.sh 10.0.0.146 'md5sum /boot/BOOT.BIN'   # 9acbe2ebe1db...

The manual equivalent, for each board (146 shown; repeat for 148 with
its image): back up the live image on-board, stage with an md5 check,
then reboot::

   D=ops; IP=10.0.0.146
   IMG=images/BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db
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
prefer the rails scripts (``ops/skidfix/flash_148_beatfix2.sh``,
``flash_146_vendh.sh`` family) — they add the full gate set
(precondition, rollback bank, post-flash health gate, auto-rollback).
See :doc:`build-and-flash` for the rails.

Step 2 — deploy the host daemon, profiles and watchdog
-------------------------------------------------------

One command per board does all of it — scp the daemon sources and build
them on-board (2 MB-carve build when the qpsk dtb from Step 0 is live),
stage the ADRV9002 profiles for rungs r3/r2 plus the legacy 1.92 MSPS one
in ``/root/``, and stage the watchdog::

   cd ops
   ./provision.sh 10.0.0.148 && ./provision.sh 10.0.0.146

Its verify block lists every file and warns if the board is not on the
banked ``6.12.77`` UIO kernel. The manual equivalent, for reference (the
daemon builds on-board in seconds, no cross-compiler)::

   D=ops; SRC=host
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

   cd ops && bash restore_known_good.sh

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
  arm-in-flight guard (``ops/sim_repro/no_arm_inflight.sh``) and all
  rig actors take ``RIG_LOCK`` (``ops/sim_repro/riglock.sh``).
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

Healthy: ``fsync≈1245 wcnt≈1245 clean=12/12``. On the current image pair
both directions are inside the campaign gate — forward
**0.070–0.079 %**, reverse **0.191 % pooled**, lost frames in the
denominator (:doc:`performance`). Expected imperfections that remain,
all documented (:doc:`current-state`, ``docs/evidence/KNOWN_HOLES.md``):

* A mid-window delivery wedge class: delivery flatlines and the receiver
  enters a carrier-reset storm it does not leave, roughly 3 legs in 10
  (``docs/evidence/RXFIX_STATE.md`` Task 37). It is the dominant
  leg-killer and is not yet root-caused.
* Occasional multi-thousand-frame bursts; the on-board watchdogs plus
  (on the control host) the ``ops/sim_repro/delivery_sentinel.sh``
  recovery loop handle them.
* The "arm lottery" is **gone** as a category: with the monitor unplugged
  the reverse spread collapsed to 0.180–0.201 %, so what looked like
  arm-to-arm variance was the DisplayPort beat's amplitude
  (:doc:`bringup`).

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
