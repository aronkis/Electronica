> Evidence ledger, moved verbatim from `two_jup/RIG_NOPING_FAULT.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# 148 "no-ping" fault — rig-instability finding (independent of the FIFO image)

Board 148 (ADALM-Jupiter, xczu3eg) intermittently drops off the network
entirely — no ICMP reply, ssh connect timeout — while 146 on the same switch
stays up. It predates the FIFO image and belongs in the rig-instability
write-up regardless of the A/B outcome.

## Occurrences on record

| # | when | image on 148 | what preceded it | how it ended |
|---|---|---|---|---|
| 1 | 2026-08-26 ~09:00 | v_endh flash era (146); 148 on BEATFIX/`e49c011b` lineage | overnight bidirectional soaks (3 attempts, each collapsing ≤15 s), then a flash-rail gate on 148 | physical power cycle ~3.5 h later; dmesg lost (volatile journal) — H-7 |
| 2 | 2026-08-27 ~13:23 | `fe5bd8a4fe19` (comb image) | queued-mode bidirectional soak attempt (collapsed at +12 s) → sentinel recovery bring-up started 13:23:34 | came back 13:54 with `up 1 min` (a reboot; operator power cycle within a minute of the notification is the likely cause) — fresh dmesg, no record |
| 3 | 2026-08-27 ~14:40 | `e09fdb32e375` (FIFO image) — booted, ssh answered, readback verified 14:39 | rails bring-up (`restore_known_good`) arming the DMA, **overlapped by a stray reverse-sweep bring-up** (my rig-mutex bug) | operator power cycle 17:15 (2 h 35 m); came up on the FIFO image, rollback applied |

Common factors: every occurrence followed a period of heavy simultaneous
TX+RX DMA activity on 148 within the preceding minutes (bidirectional
soaks in #1 and #2; DMA arming under two concurrent bring-ups in #3).
Not observed: during idle, during single-direction saturated legs (dozens
today), or during captures.

## What is and is not known

- The whole PS goes silent (no ICMP from the Linux stack), not just the
  daemon — so it is a kernel hang/oops, a PS-level lock-up (e.g. an AXI
  transaction that never completes, which stalls the CPU on the next
  access to that address space), a power/PMU event, or a thermal trip.
- Return requires a power cycle in #1 and #3; #2 returned as a reboot that
  coincides with the operator's reaction time to the notification — not
  evidence of self-recovery.
- Every occurrence so far left NO record: journald was volatile
  (`/run/log/journal`), the console was not attached. **From 2026-08-27
  17:15 journald on 148 is persistent (`/var/log/journal`)** — the next
  occurrence will leave the last kernel messages before the silence.
- Serial console: HOSTS.md lists the Jupiter A/B serial via
  `tron.local:/dev/ttyACM0`; nemo carries a CP210x bridge with no tty
  bound. Attaching either is the second evidence channel (see the ledger
  for what was reachable when the 2nd FIFO attempt ran).

## Discriminators for the next occurrence

- Persistent journal shows an oops/panic or a "rcu stall"/"watchdog: BUG:
  soft lockup" → kernel/AXI class; if the last lines are the DMA arm
  (`axi_dmac`/`cf_axi_adc` writes) → fabric-attributable (image matters).
- Journal ends cleanly with no kernel message → power/PMU/thermal class
  (image-independent); check PMU firmware / supply (the 12 V brick and USB
  power path are shared-suspect) and `/sys/class/thermal` history.
- Serial console live during the event: a hung PS with a live UART prints
  the panic; a dead UART means power.

## Standing handling

Stop, do not power-cycle in a loop; one power cycle by the operator;
pull `journalctl -b -1 -k | tail -100` immediately on return before any
bring-up; ledger it here.

## 2026-08-27 17:2x — first evidence from the persisted journal, and a fan finding

- **The journal of the boot that died IS on disk** (the ADI image already
  keeps `/var/log/journal`; `journalctl --list-boots` on 148 shows boot −2 =
  the FIFO-image boot, entries 14:37:42 → **14:39:02** board clock). Its last
  ~70 s contain NO kernel message at all — no oops, no panic, no soft-lockup,
  no DMA/AXI driver message; the log simply stops mid-way through the
  once-a-second `fan-control` error spam. That **excludes** an orderly
  shutdown, OOM and any logged kernel fault, and leaves two candidates:
  an instantaneous hard PS lock-up (an AXI transaction that never completes
  hangs the CPU before anything can be logged) or a power/PMU/thermal cut.
- **`fan-control` is non-functional on BOTH boards**: the script hard-codes
  `GPIO_CHIP=334` (the old kernel's gpio base); this kernel exposes
  `gpiochip512`/`gpiochip516`, so its exports of gpio479/348 fail every
  second and the fan is never commanded — nor is the script's 100 °C
  software power-off. Whether the fan runs at all is then a hardware default.
  Idle die temperatures right after boot: 148 PS 29.6 °C / PL 29.7 °C, 146
  30.1 / 29.8 °C (xilinx-ams `in_temp7/8`). **Forced the fan GPIO high on
  both boards (correct base + 145) as a precaution and added PS/PL
  temperature to the A/B polls**, so the second FIFO attempt measures die
  temperature under saturating load — the thermal hypothesis is testable
  in-band from here on.
- Serial console: HOSTS.md's `tron:/dev/ttyACM0` no longer exists; tron has
  `/dev/ttyUSB1` (dialout OK). A passive capture is attached to it; which
  board it belongs to is identified from the next boot banner.

| 4 | 2026-08-27 ~17:33 | `fe5bd8a4fe19` (comb image — the FIFO image was NOT flashed; attempt 2 never passed the health gate) | sentinel post-reboot recovery: first bring-up 17:16–17:23 "done" but probes failed; second bring-up started 17:33:16 (`bringup_r2r3 r3`: ROM arm on 146 logged, then hung on 148) | pending operator power cycle; return-forensics watcher armed (journal of the dead boot, no bring-up) |

**Occurrence #4 removes the FIFO image from the suspect list**: the same
no-ping death happened on the unmodified comb image, during a bring-up
(DMA/radio arming), ~17 min after a clean boot, with the fan forced high
and idle temperatures ~30 °C at boot. The common factor is now sharper:
**the arming sequence itself, or the first heavy DMA activity after it**
(#3 and #4 both died inside `bringup_r2r3`; #2 inside a sentinel recovery
bring-up; #1 after soaks + a flash-rail gate). The two hypotheses that
survive: a hard PS lock-up triggered by an AXI access during arming
(image-independent — present in both generations), or a power/PMU event
under the arming load step. The persistent journal of this boot (#4) is
the first that can be read after a clean power cycle without any bring-up
touching the board first.

Serial console status (18:1x): `tron:/dev/ttyUSB1` received nothing during
148's 17:16 boot nor its 17:33 death, and a marker written to 146's own
console (`/dev/ttyPS0`) did not appear on it either — so that adapter is
not attached to either Jupiter's UART (or not at 115200). **No serial
console is currently available for the Jupiters**; attaching one to 148
is a physical action (HOSTS.md's `ttyACM0` entry is stale). Until then the
persistent journal is the only forensic channel, and it can only show the
last message BEFORE an instantaneous hang.

## 2026-08-27 18:2x — occurrence #4 forensics (persistent journal, clean power cycle, no bring-up before reading)

Boot 17:15:30 → last entry **17:33:14**. Kernel: not a single message after
17:15:40 (boot) — no oops, panic, stall, thermal or DMA line. Userland: the
once-a-second fan-control spam runs to 17:33:14 and stops; the last
non-spam lines are an ssh session from nemo (10.0.0.71, session 56)
closing at **17:33:11** — that is the sentinel bring-up's arming command
on 148. On nemo at that moment two `anyssh 148` calls were in flight:
`P=/sys/bus/iio/devices/iio:device2 …` (the ADRV9002 profile/LO
programming, started ~17:33:05) and `DRA=/sys/kernel/debug/iio/iio:device0/
direct_reg_access …` (a modem register READ from my chain's 60-s health
poll, started ~17:33:09). The board went silent 3 s after the profile
command returned, with the register read still outstanding. Die
temperature after the power cycle: 28.7 °C. Fan forced high all along.

**Hypothesis (now the leading one, consistent with all four events):**
`direct_reg_access` on `iio:device0` is the **AXI ADC core**
(`axi-adrv9002-rx-lpc`); its register path handshakes into the ADC-clock
domain, which is driven by the ADRV9002 SSI. While the transceiver is being
re-profiled/re-armed that clock is absent → an AXI read that never
completes → the Cortex-A53 hard-hangs with nothing logged, which is exactly
the signature (instant silence, no kernel message, power-cycle only,
image-independent, always during an arm). Every occurrence had a register
reader running concurrently with an arm on 148: #4 my health poll; #3 the
stray reverse-sweep capture's health probe during the flash rails'
bring-up; #2 my rig-recovery waiter's 60-s health probes during the
sentinel recovery; #1 a flash-rail gate. The on-board `lock_watchdog.sh`
also reads registers in a loop and is only killed AFTER the sentinel's
bring-up, not before. 146 arms first in every bring-up and has never hung —
by the time 146 is being probed its profile is already applied.

**Countermeasure (mechanical, no hardware): never read modem/ADC-core
registers on a board while its transceiver is being armed.** Health probes
refuse to run while a bring-up is in flight; on-board watchdogs are killed
BEFORE arming; the rig lock covers probes too. This is testable: a clean
bring-up with no concurrent reader should not hang; a deliberate DRA read
during the profile write should (destructive — operator's call).

## Countermeasure scorecard (updated 2026-08-28 03:0x)

Clean arms on 148 under the never-read-during-arm guard since 20:25 on 08-27:
**8** (single-actor restore 20:25; flash attempts 2, 3 and the v4 diagnostic
flash — each with arm gate pass on try 1 plus the rollback bring-ups; the
sentinel/chain recoveries at 02:3x; the two bidirectional soaks' bring-ups).
Zero no-ping events since the guard. The bidirectional soak that had
collapsed 4/4 ran two full windows. Conclusion stands: the "hard crash" was
the register-read-during-reload hang, image-independent, now guarded.
Serial console still unattached (hardware action).
