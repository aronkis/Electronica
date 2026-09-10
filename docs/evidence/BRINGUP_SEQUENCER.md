> Evidence ledger, moved verbatim from `two_jup/BRINGUP_SEQUENCER.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Bring-up sequencer — precondition ladder

Status: **design, unblocked 2026-08-08.** It was gated behind the NAK-path observable,
which now exists (`-DQPSK_ARQ_NAKSTAT`, deployed on 148). Supersedes the "deterministic
state classification" section of `SW_BRINGUP_DESIGN.md`, which the 16-arm null result
demoted.

## What changed, and why this is not the old design

`SW_BRINGUP_DESIGN.md` proposed classifying the arm lottery from driver state and
recovering per class. The 16-arm experiment killed that: **no field in the driver
register set separates FULL from 0.42×.** So a sequencer cannot diagnose its way out
of a bad arm.

What it *can* do is stop accepting bring-ups that were never verified. Every rung below
exists because something silently passed when it should not have:

- the arm gate passes on a ~5 s probe that samples across a rate step-down
- `fwd 100%` was a **hardcoded constant**, not a measurement, in every capture ever run
- `capture_r3.sh` silently rebuilt 148 without the counter
- `stallpoll` + `lock_watchdog` corrupted each other's register reads for a whole campaign

The value is in *refusing to proceed*, not in being clever.

## The ladder

Each rung: check → observable → pass criterion → action on fail. A rung that cannot be
observed is marked and **must not be silently skipped** — that is exactly how `fwd 100%`
survived.

| # | precondition | observable | pass | on fail |
|---|---|---|---|---|
| 1 | correct image | `md5sum /boot/BOOT.BIN` vs expected | exact match | abort, do not soak an unknown image |
| 2 | correct geometry | frame rate ≉ 2× nominal | not ~2439 f/s | **abort, do not retry** — 2439 f/s is the sps=8 wrong-image tell |
| 3 | single reader | *(none — see gaps)* | — | warn |
| 4 | daemons up both ends | `pgrep qpsk_tun` | both | relaunch |
| 5 | rx0 SSI pinned | `ssi_delays` readback | matches `RXPIN` | re-apply, re-arm |
| 6 | arm rate class | `rate_probe.sh` (reset-aware) | ≥ 0.9 × nominal, `resets_s` low, `valid_pct` high | re-arm (bounded retries) |
| 7 | **reverse** link health | `crc_health` | ≥ threshold | byte double-tap re-arm |
| 8 | **forward** link health | `fwd_health` — **must be measured, not assumed** | ≥ threshold | re-arm; NAKs travel this path |
| 9 | ARQ engaged (if `-A`) | `nakstat seen/magic/parsed` + peer `naks_rx`/`retx` | `seen` advancing | see below |
| 10 | steady state | rate holds over ≥ 60 s | no step-down | re-arm |

**Rung 6 must use `rate_probe.sh`, not the legacy probe.** `0x104` is reset by rstCS and
by the watchdog's `0x000`; the old primitive guards only against *negative* deltas, so a
reset inside the window yields a positive-but-far-too-small rate — resets every ~15 s over
a 30 s window read 622 f/s on a link genuinely running 1244.

**Rung 9 is the new one.** `nakstat` splits three previously indistinguishable states:

- `seen` flat → nothing reaching the ARQ layer at all (dead forward link, or the peer's
  daemon started late). Observed on a bad run: 146 sent 1462 NAKs, 148 `naks_rx=0`.
- `seen` advancing, `magic` flat → frames arrive, none look like NAKs
- `magic > parsed` → NAKs arrive malformed or truncated (sanity check rejects them)

Scope limit, and it must stay in the doc: `axr_is_nak()` only sees payloads that
**already passed CRC**, so `seen` is not "NAK frames on the wire" — a NAK lost on air is
invisible. Bounding air loss needs `seen` on the receiver paired against `naks_tx` on the
sender.

## Checks with NO observable — these need instrumentation added

1. **Single-reader enforcement (rung 3).** Nothing detects two processes sharing
   `direct_reg_access`. This defect corrupted real soak data for a full campaign and was
   invisible. Needs a lock/owner file that readers claim, or at minimum a check for other
   known readers before starting. *Highest value of the three: it silently corrupts data
   rather than failing loudly.*
2. **Cross-board daemon start ordering.** No timestamp exchange, so "did the peer's ARQ
   layer come up before I began NAKing" is unanswerable. Directly implicated in the ARQ
   bimodality. Needs each daemon to log a start epoch the other side can read.
3. **RX-side SSI status.** `rx0_ssi_test_mode_status` reads empty, and the TX-side status
   is only meaningful *inside* test mode — `dataError=1` on all 16 arms including
   full-rate ones proves it is being read out of context. Any BIST-based rung can cover
   the transmit direction only.

## Not doing

- **Per-class recovery.** The 16-arm null says the classes are not distinguishable from
  the register set. Bounded retry with verification beats a classifier built on nothing.
- **Auto-remediation beyond re-arm.** `lock_watchdog` owns recovery. Two controllers
  fighting is worse than one.
