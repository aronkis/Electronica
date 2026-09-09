# Health monitor — design note

`modem_status.sh` — read-only status readout for the two-Jupiter R3 link.
Status: **implemented and verified** 2026-08-08. Text, `--json`, and `--watch N` modes.

## The one design constraint everything else follows from

The obvious way to build this — poll `direct_reg_access` for packet counts and
lock state — is the one way that is **actively harmful**, and we have the damage
to prove it.

That debugfs interface is a **single address latch**: a reader writes the address
it wants, then reads the value back. Two readers interleaving corrupt each other,
silently, with no error anywhere. Measured 2026-08-07: with `stallpoll` and
`lock_watchdog` both running, 0.08% of soak rows carried a *foreign register's*
value — `0xC010180`, which is `adc_forensic 0x15C`, appearing in the **packet
count** column 77 times in one 3.5 h capture. One such value inflates a run delta
by 2×10⁸ and poisons any run-based statistic downstream. It cost a full re-derive
of the frame-rate analysis to find.

A monitor that polls registers would be a **third** contending reader, and it
would corrupt whatever measurement is in flight — soaks, captures, acceptance runs
— precisely when someone is watching the dashboard because something interesting
is happening.

**So this monitor reads no registers at all.** Not as a limitation: the daemon and
the watchdog *already* read them, on their own cadence, and write what they saw to
files. We read the files. Same data, zero contention, and it can never gate or
interrupt a run. It also never writes a register, so running it cannot change link
state — safe to leave in a `--watch` loop indefinitely.

## Fields, sources, cadence

Nothing here is polled from hardware by this tool. "Cadence" is the **writer's**
update rate, which bounds freshness regardless of how often you call the monitor.

| field | source (file) | written by | cadence |
|---|---|---|---|
| boot image md5 | `/boot/BOOT.BIN` | flash | on flash only (cached in `--watch`) |
| daemon up/down | `pgrep qpsk_tun` | kernel | on call |
| watchdog up/down | `pgrep lock_watchdog` | kernel | on call |
| poller up/down | `pgrep stallpoll` | kernel | on call |
| ARQ on/off | `qpsk_tun.log` banner | daemon | once at daemon start |
| `dma_rx_ok`, `crc_drop`, `seq_gap` | `qpsk_tun.log` stats line | daemon | daemon's stats interval |
| `recovered`, `dups`, `naks_tx`, `naks_rx`, `arq_lost` | same stats line | daemon | same |
| `nakstat seen/magic/parsed` | `qpsk_tun.log` | daemon (`-DQPSK_ARQ_NAKSTAT` builds) | same |
| watchdog verdict + `dpkts`/`drstcs` | `watchdog.log` | lock_watchdog | ~5 s decision window |
| cumulative re-arms | `watchdog.log` | lock_watchdog | per re-arm |
| uptime, loadavg | `/proc/uptime`, `/proc/loadavg` | kernel | on call |
| die temperature | `/sys/class/thermal/thermal_zone0/temp` | kernel | on call (absent on these boards → `n/a`) |

**Per-field age is displayed, not hidden.** `(stats Ns old)` and `(log Ns old)` come
from `stat -c %Y`. A monitor that renders stale numbers as though they were current
is worse than one that admits the lag — during a wedge the daemon can stop updating
entirely, and a frozen-but-plausible readout is exactly the failure this rig has
already been bitten by.

## Call cadence

One ssh round trip per board per refresh; each is a handful of file reads.
`--watch 10` is comfortable. Lower is possible but pointless: the *watchdog*
decides every ~5 s and the daemon dumps stats on its own interval, so refreshing
faster than the writers just re-renders identical numbers.

The boot-image md5 hashes 7 MB off the SD card. Fine once; wasteful every tick and
needless flash wear. `--watch` reads it on the first pass and reuses it — the image
cannot change without a reboot, which resets uptime and is visible anyway.

## Modes

- default — one text snapshot, both boards
- `--json` — one object per call, for logging or a dashboard feed
- `--watch N` — clear-and-redraw every N s
- `A_IP` / `B_IP` override the board addresses

## What it deliberately does not do

- **No register reads or writes.** See above. If you want live packet rates, use
  `rate_probe.sh` while nothing else is running, and understand you are taking the
  reader slot.
- **No re-arm, no recovery, no remediation.** It is an instrument, not an actuator.
  `lock_watchdog` owns recovery. A monitor that also acts is a second controller
  fighting the first.
- **No derived PER.** Delivered PER needs the per-frame log and a live-window
  analysis (`accept_analyze.py`); a number scraped from counters would look
  authoritative and be wrong. `crc_drop` here is a raw counter, not a rate, and on
  an idle link it climbs from keepalive traffic that carries no user data.

## Known gaps

- Thermal zone is absent on these boards, so temperature always reads `n/a`.
- ARQ on/off is inferred from a banner logged once at daemon start; if the log is
  rotated the field goes stale. The counters beside it are the fallback signal.
- Counters are cumulative since daemon start, not rates. Deltas are left to the
  caller deliberately — computing a rate across an unknown restart is how the
  campaign produced negative frame rates more than once.
