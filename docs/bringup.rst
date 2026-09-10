Bring-up and porting
====================

How to take a provisioned pair of boards from power-on to a credited link, and
what changes when the pair is not the lab pair (10.0.0.148 / 10.0.0.146).

This page assumes the boards already carry the banked kernel, device tree,
boot image and host daemon — that is :doc:`setup-prebuilt`, and it is the
prerequisite for everything below. Board access throughout is
``ops/anyssh.sh <ip> '<command>'`` (password auth). The boards have **no
remote power**: the only remote recovery from a bad ``/boot`` write is a
reflash, so treat ``/boot/BOOT.BIN``, ``/boot/Image`` and
``/boot/system.dtb`` as precious.

Standing rules, before any of it
--------------------------------

Three rules cost real campaign time to learn, and each one silently
invalidates measurements taken without it.

**No monitor on a board that is receiving.** A DisplayPort or HDMI cable
plugged into a receiving Jupiter costs roughly **1–3 % packet error rate**
on that board's receive leg. It is not an RF effect: the DisplayPort DMA,
its DDR read stream and the PS-GTR lanes beat against the modem's frame
rate and destroy *frame starts*, so the damage appears as bad-magic frames
rather than CRC failures, is visible at the fabric pins, follows the board
rather than the image, and its beat period is re-seeded at every reboot.
Measured on this rig with the same image in the same session
(``docs/evidence/RXFIX_STATE.md`` Tasks 36–37): reverse-leg PER **0.967–2.825 %**
with the display attached against **0.180–0.201 %** with it unplugged, host
bad-magic frames 2.2 % against 0.012 %. Check any board before trusting a
number from it::

   ssh root@<board> 'grep " 28:" /proc/interrupts; sleep 10; grep " 28:" /proc/interrupts'
   # ~1200 counts in 10 s (~120/s) = a display is attached -> unplug it
   # also: cat /sys/class/drm/card0-DP-1/status   -> want "disconnected"

If a display is genuinely needed, keep it on the transmitting board only,
and never quote a receive number measured with one attached.

**Payload whitening is on, and is both-ends-or-nothing.** The TX scrambler
in the fabric is hard-disabled and there is no RX descrambler, so payload
bytes reach the air as they are written. With whitening off, the daemon's
idle frames are a constant byte pattern containing two preamble-like
stretches; the preamble detector occasionally locks onto one of them, the
payload gate starts the frame 1,549 or 3,085 symbols early, and the next
true start truncates it. That was 97 % of the forward residual — the
census-window PER fell 0.045 % → 0.005 % with whitening on
(``docs/evidence/comb/FWD_CRC_REGRESSION_0907.md`` §47.21–§47.23).
``ops/bringup_r2r3.sh`` defaults ``WHITEN=1`` and carries ``QPSK_WHITEN``
into the watchdog's relaunch string; a daemon started by hand must set
``QPSK_WHITEN=1`` too, or the link decodes nothing. Confirm on both
boards::

   tr '\0' '\n' < /proc/$(pgrep -x qpsk_tun)/environ | grep QPSK_WHITEN

**Register reads and arms do not mix.** A ``direct_reg_access`` read on a
board while its ADRV9002 profile is being reloaded hangs the PS with no log
entry, and recovery is a power cycle. Any unit that runs
``ops/bringup_r2r3.sh`` arms **both** boards — a reverse-leg bring-up arms
148 as well. So: no register read on a board while anything that can arm it
is running; every host-side reader sources
``ops/sim_repro/no_arm_inflight.sh`` and calls ``arm_guard`` first; polls
stay at 1 s or slower; rig actors take ``RIG_LOCK``
(``ops/sim_repro/riglock.sh``). The occurrences are logged in
``docs/evidence/RIG_NOPING_FAULT.md``.

Sequence
--------

**1. Flash and provision** — only when the image changes.
``images/CURRENT.txt`` names the current role-A and role-B images, and
``ops/deploy_image.sh <ip> A|B`` reads it, refusing to flash on an md5
mismatch. One board at a time, confirming each is back before touching the
other; then ``ops/provision.sh <ip>`` on each to build the daemon on-board
and stage the LVDS profiles and the watchdog. The full deploy, including
the kernel and device tree a fresh board needs first, is
:doc:`setup-prebuilt`.

**2. Arm, per session.** The whole two-board ceremony is one command::

   cd ops && bash restore_known_good.sh     # or: ./bringup_r2r3.sh r3

It loads the r3 LVDS profile on both boards, sets the LO plan, does the ROM
arm with the double-tap that defeats the false-lock latch, applies the SSI
overrides, starts the daemons with whitening on, flips the byte source, and
starts the watchdogs. The canonical, do-not-paraphrase register sequence
underneath it lives in ``ops/link_test.sh`` (``arm_ber`` / ``coldstart_tun``):
load the profile, ENSM ``calibrated``, front-end GPIOs, ``tx_a`` port, TX LO
with 0 dB attenuation and ``rf_enabled``, RX LO with ``rf_enabled`` and
``automatic`` gain, modem regfile reset, ``0x158=1`` (byte TX), ``0x118=0``,
``0x114=1`` (RX from air), DAC mux, rstCS pulse, byte-DMA arm (``devmem
0x9D300000 32 0x1``).

Two arm-time rules that are load-bearing: the ``agpio4-7`` writes are part
of the sequence, not decoration, and **ADRV9002 tracking calibrations must
not be enabled beyond the profile defaults** — ``quadrature_w_poly`` /
``fic`` / ``rfdc`` enabled at arm time mis-converge and scramble the
constellation past the resolver's one-time lock. The profile ships with the
correct calibration set.

**3. Acquire — verified lock.** Acquisition is stochastic: a board armed
before its peer radiates can sit in a never-locks state, and roughly one arm
in three needs a nudge. The procedure that makes lock deterministic is

1. start ``ops/lock_watchdog.sh`` on the receiving board, detached;
2. wait about 12 s, then kill it (``pkill -f '[l]ock_watchdog'``) — never
   leave it running through a measurement, because a mid-window re-arm
   pulses reset and corrupts the run;
3. probe with a short ``qpsk_tun -B`` and require aligned frames
   (clean + noisy) above 100;
4. on zero aligned, pulse the carrier-sync reset (``0x110`` 1 → 0), re-arm
   the byte DMA, and repeat from step 1, up to three tries.

``ops/exp_forward.sh`` implements this loop; fold it into any new runner
rather than re-deriving it.

**4. Pin the RX gain, after lock.** The hardware AGC's mid-frame gain steps
cost about 2× in BER on the margin-limited direction. After verified lock,
read the settled ``in_voltage0_hardwaregain``, switch
``in_voltage0_gain_control_mode`` to **``spi``** (the token ``manual`` is
silently rejected) and write the value back. Pin only *after* lock, so the
captured value is the settled operating point; leave the mode ``automatic``
during acquisition.

**5. Verify** — the health gate below, then the acceptance ladder in
:doc:`testing`.

SRO sign on a fresh pair
------------------------

The two deployed images do **not** carry the same receiver fix, and the two
fixes assume opposite sample-rate-offset signs. Board 148 runs R4B, which
wants the receiver's oscillator to be the **faster** one (a negative
sample-rate offset); board 146 runs R4D + R1, which wants the **slower**
one. On the lab pair this is settled and recorded in ``images/CURRENT.txt``;
on a fresh pair it is not.

So before flashing a fresh pair, **measure the RX-LO residual sign first**
and pick the role assignment from it — the sign cross-check procedure is in
``docs/evidence/RXFIX_STATE.md``. Getting it backwards does not fail
loudly; it costs PER on both legs.

Two related operating points are deliberate and should not be "fixed" back
to the plain LO: the forward RX LO sits **+20 kHz off-null**
(``LO_A_RX=2000020000``) and the reverse RX LO **+40 kHz off-null**
(``LO_B_RX=1900040000``), both set from sweeps. The receiver's tracking
defect is CFO-sign-asymmetric, and these offsets halve the loss on their
legs.

Health gate
-----------

Nothing counts until the link passes the gate, and the gate must be the
reset-aware probe — ``0x104`` is reset by rstCS and by the watchdog's
``0x000`` soft reset every 5–7 s on a *healthy* link, so a naive
delta-over-window probe under-reads a healthy link by roughly 2×::

   cd ops
   bash health_probe_reset_aware.sh 10.0.0.148 12   # forward (146 TX -> 148 RX)
   bash health_probe_reset_aware.sh 10.0.0.146 12   # reverse (148 TX -> 146 RX)

Healthy reads ``fsync≈1245 wcnt≈1245 clean=12/12``. The standing gate for
counting anything is **framesync rate ≥ 1100 f/s and wordcnt-derived rate
≥ 1100 f/s**; a frozen ``wordcnt`` is an unambiguous wedge verdict. A
growing ``rstcs`` (0x150) delta means a reset storm, which in practice means
the wrong or an old image; all-PHASE buckets mean a quadrant mis-lock, so
redo the verified-lock loop; ``frames_scored=0`` means no lock at all.

Why the ladder exists at all is :doc:`measurement-discipline`; what the
credited numbers are, and how a credited run is taken, is
:doc:`performance`.

A one-directional degradation is an antenna, not a DSP problem
--------------------------------------------------------------

On 2026-09-06/07 the forward leg collapsed to about 60 % CRC-good with no
image and no configuration change. Board 148's ``in_voltage0_rssi`` at the
shipped carrier had drifted 27.5 → 34.9 dBFS (weaker) over three days while
the reverse receiver did not move; the loss was frequency-selective; and it
produced every DSP-looking symptom — carrier-loop reset storms, an apparent
CFO error on the preamble correlator, a receiver that went deaf, and a
failing arm gate. **Swapping 148's RX antenna with 146's moved the loss to
146** (``docs/evidence/comb/FWD_CRC_REGRESSION_0907.md`` §46.8–§46.12).

The forward and reverse legs use *different* antenna pairs (146-TX → 148-RX
against 148-TX → 146-RX), so a one-direction-only defect points at one of
two physical elements, not at "the band". Before any DSP investigation of a
leg that degraded without a configuration change: compare that receiver's
rssi against its own history at the same LO and gain, and if it drifted, run
``ops/comb/band_ber_sweep.sh FREQS="1900 1960 2000 2040 2110" DWELL=25``,
then swap one antenna or cable and re-run. Fifteen minutes. Note also that
"level excluded" arguments comparing *different* frequencies do not survive
a frequency-selective element.

Porting to another pair
-----------------------

Everything in the repository is already board-agnostic: ``ops/anyssh.sh``,
``ops/provision.sh``, the LVDS profiles, ``ops/lock_watchdog.sh``, the host
sources and ``ops/link_test.sh``'s arm sequence carry no hardcoded IP or
board identity (the arm uses the fixed channel-1 datapath — ``voltage0``,
TX1/RX1 LO, ``tx_a``, ``agpio4-7`` — on any board). Point the tools at your
boards with ``export A_IP=<ip> B_IP=<ip>`` (or ``-A``/``-B`` per call) and
run ``./link_test.sh preflight``; "A" and "B" are role labels, and the
frequency plan is keyed to the roles.

A new board needs its **own** device tree: the qpsk dtb is merged onto that
board's pristine ``system.dtb``, so pull it read-only first, keep it, and
build against it (``ops/deploy_dtb.sh build``) — :doc:`setup-prebuilt`
Step 0. The kernel ``Image`` is common to all boards.

What you must re-survey, and must not copy from this rig:

* **The frequency plan.** Forward 2.00 / reverse 1.90 GHz came from a
  1.5–2.1 GHz survey of *these* units, where 2.10 GHz was polluted by 148's
  TX-LO leakage. Re-run the survey and set ``FWD_HZ`` / ``REV_HZ``.
* **The RX-gain pin value.** The procedure is universal; the number is the
  settled operating point of *this* link budget.
* **The SRO sign**, and therefore which image goes on which board — see
  above.
* **Whether your boards tick.** The ~1.5 s BBDC calibration insertion is a
  per-unit artifact observed on one of these two units
  (``docs/evidence/ESCALATION_ADI.md``). The shipped compensation is a no-op
  on a board that does not exhibit it, so it costs nothing either way —
  but do not assume you have inherited the defect.
* **The PER numbers themselves.** :doc:`performance` records what this pair
  achieves on its own antennas and bench.

The 1.92 MSPS rung and the f1536 upgrade
-----------------------------------------

The original operating point was 1.92 MSPS SSI, 8 samples per symbol,
240 ksym/s. It is retired: the banked images are characterised on rung r3
only, and the legacy profile ``lvds_1p92_mhz`` survives solely because
``ops/link_test.sh``'s ``ber`` and ``tun`` subcommands still load it (its
``preflight`` is rung-independent and still the right readiness check).

The move to f1536 with interrupt-driven DMA was carried out board-by-board
in 2026-07 and its session record — the deploy runbook, the three
integration bugs found on hardware, the over-air deframe blocker and its
root cause — is preserved on tag ``archive/pre-cleanup-2026-09-09`` (the
retired deploy runbook and bring-up results pages). Nothing in
it is needed to bring the current stack up; the one piece that outlived the
session, the kernel command-line provenance, is in :doc:`build-and-flash`.
