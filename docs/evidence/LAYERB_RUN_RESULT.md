> Evidence ledger, moved verbatim from `two_jup/LAYERB_RUN_RESULT.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Layer B end-to-end — 2026-08-11 — **no DMA number produced (two runs)**

> **Run 2 (`r3cap/layerb_20260811_151334/`) — aborted by the new framing gate, 3/3
> attempts.** See §"Run 2" at the bottom. Run 1 below is the run that motivated the gate.

---

## Run 1 — **INVALID, banked 90 s of junk**

`QPSK_SEQ_KEEPM=1 ./layerb_run.sh 90` → `r3cap/layerb_20260811_145820/`

## The wiring was right this time

Everything the harness was built to verify passed:

```
ARM GATE PASS (try 1)
10.0.0.148: ./qpsk_tun -S -M 32 -r 15360 -d 90
10.0.0.146: ./qpsk_tun -S -M 32 -r 15360 -d 90
LAYER B: -S keeping multi-slot RX (-M 32) -- PN stream traverses the batched DMA path
LAYER B: scoring the QUEUED DMA path via raw-slice tap (-M 32, batch_m=32)
148 nakstat=4 BOOT=64bb24766032 before AND after (untouched)
```

`batch_m=32` is genuinely set, so the `BATCH_DROP` classifier is live — the defect that
made it inert last time is fixed and confirmed fixed.

## But the run scored nothing

```
146 (RX under test)
SEQDMA  torn_zero=0 torn_stale=0 scattered=0 batch_drop=0 batch_m=32 tear_off=0..0
SEQRX   frames_scored=32640 ok=0 biterr=0 lost=0 (0 gaps) dup=0 junk=32640
SEQRX   seq_span=0 accounted=0   air_expect~19068 frames in 90.0s
```

**Every one of 32,640 frames scored junk. `seq_span=0`, `accounted=0`, zero bits
compared.** The four all-zero DMA buckets therefore mean *nothing was classified*, not
*nothing went wrong*. Reported as invalid rather than as "the DMA is clean" — the
bucket totals must sum to the seq span for the headline to be trustworthy, and here the
span is zero.

Same on the peer (148: 5,728 frames, all junk).

## Two defects, and the first does not explain the second

**1. The PN transmitter underfeeds the air by ~2.2×.** Logged every 5 s throughout:

```
seq: TXRATE 555 f/s (air 1245 f/s -- 45% fed)
seq: TXRATE 517 f/s (air 1245 f/s -- 42% fed)
...  settling to 482-497 f/s (39-40% fed)
```

`-r 15360` is the correct R3 symbol rate (12333 sym / 15.36 Msym/s = 803 µs = 1245 f/s),
so this is not a parameter error — the `-S` feeder cannot source PN frames at the air
rate. 55–60% of air slots carry something the feeder never wrote.

**2. The link was not delivering framed data at all — so the scorer was correct.**
Analysis of the 200 banked raw slices in `seqraw_146.log` settles this:

| check | result | reading |
|---|---|---|
| slice length | **1528 B** | correct f1536 geometry (191 × 8) — not a `pkt_bytes` error |
| distinct slices | **200/200** | not a frozen or stale buffer |
| `'QK'` frame magic present anywhere in slice | **5/200**, at scattered offsets (76, 293, 496, 561, 1333) | chance — 2 bytes over 1528 positions predicts ~4.7/200 |
| zero bytes in a slice | 4/1528 | not a never-written / `carve_zero` slice |

**There is no frame structure in the delivered bytes, at any offset.** So this is not a
scorer bug, not an alignment bug, and not a DMA bug: the modem was not producing framed
output during the `-S` run. The scorer was fed unframed data and correctly called all of
it junk. Consistent with the startup line `rx_queued: no progress for 3.0s -- re-arming
(recovery #1)` — the link was effectively wedged for the whole PN run.

Ruled out along the way, cheaply and explicitly:
- **`pkt_bytes` mismatch** — the tap (`qpsk_tun.c:1031`) and `qpsk_seq_reset`
  (`qpsk_tun.c:1780`) take the *same* `pkt_bytes` variable, and the observed slice is
  1528 B as expected.
- **whitening** — opt-in (`QPSK_WHITEN` idiom), not set, so the raw tap is not comparing
  whitened bytes against unwhitened expectation.
- **tap placement** — correct, on the raw slice immediately before `qpsk_frame_decode`.

## What this run does and does not establish

- **Does:** the Layer B path is wired correctly end-to-end, `batch_m` is live, the PN
  build is deployed on both boards, and 148's AXR counter survived (`nakstat=4` both
  sides of the run).
- **Does not:** produce any DMA-boundary number. There is still no measurement of
  gap / torn-write / dropped-batch.

## Next step

The blocker is **not** in Layer B's code — it is that the run was taken on a link that
was not framing. Two things owed, in order:

1. **Gate the run on framing before scoring.** `layerb_run.sh` checks the ARM gate and
   the banner, but nothing asserts that framed data is actually arriving once `-S` is
   swapped in. Add a short pre-scoring probe: sample the first N raw slices and require
   a `'QK'` magic hit rate well above chance (the check above is the gate — 5/200 is
   chance, a framing link gives ~200/200 at offset 0). Abort and flag instead of banking
   90 s of junk. This is the same class as the `crc_health`-is-a-ratio and stall-watchdog
   fixes: the harness must detect its own no-op.
2. **Fix the PN feeder underfeed** (40–45% of air rate). Independent of the above and
   worth fixing regardless: at 40% feed the instrument can never observe more than 40%
   of the DMA's behaviour, so even a clean run would under-sample the fault.

Only then re-run for the DMA-boundary number.

## Rig

`layerb_run.sh` kills both `lock_watchdog`s and does not restart them, and the `-d 90`
daemons exit at the end. `restore_known_good.sh` was run immediately afterwards to bring
the link and both watchdogs back.

---

# Run 2 — 2026-08-11, framing gate added — **ABORTED, 3/3 attempts**

`QPSK_SEQ_KEEPM=1 ./layerb_run.sh 90` → `r3cap/layerb_20260811_151334/`

The framing gate built after Run 1 did its job on its first outing: it refused to bank a
third round of junk as data.

```
ATTEMPT 1  ARM GATE PASS (try 1)   ok=0 at t~12/16/20/24/28s   junk 5504 -> 12928
ATTEMPT 2  ARM GATE PASS (try 2)   ok=0 at t~12/16/20/24/28s   junk 5472 -> 12800
ATTEMPT 3  ARM GATE PASS (try 5)   ok=0 at t~12/16/20/24/28s   junk 5504 -> 12928

=== LAYER B ABORTED: framing gate failed on all 3 attempts ===
```

## Time-to-wedge is not measurable, and that is the finding

TTW presupposes a framing window that later collapses. There was never one: `ok=0` from
the first sample in all three attempts. This is **not** the mid-capture wedge that ate
Run 1 — the link never framed under `-S` at all. The TTW reporter was added and is in
place; it did not fire because no run got past the gate.

## The attribution sharpens: it is the `-S` swap, not the wedge lottery

Every attempt was preceded by a **passing bring-up** (ARM gate green, `BRING-UP
COMPLETE`), and under `-G` the link demonstrably delivers — the restore immediately
before measured 1023 f/s at 98% CRC. So each cycle ran:

> link frames under `-G` → swap to `-S` → framing gone immediately → repeat, 3×

Deterministic, not a lottery. That also **joins the two Run-1 defects into one causal
chain**: the PN feeder sources only 40–45% of the air rate, so most air slots carry
frames the feeder never wrote — plausibly why the RX finds no frame structure at any
offset. On that reading the underfeed is not a side issue that would merely under-sample
the DMA; it is what prevents framing outright, and is therefore *the* blocker.

**Stated as a hypothesis, not a measurement.** It is consistent with everything observed
but has not been tested directly.

## Next step (cheap, and mostly off-link)

Test the underfeed→no-framing chain directly:

1. Make the `-S` feeder source at the full air rate (1245 f/s at R3), **or** drive `-S`
   at a reduced `-r` so the feeder keeps up with the cadence it is pacing to.
2. Re-check framing with the gate. If `ok` starts advancing, the chain is confirmed and
   Layer B can finally produce a DMA-boundary number.

Only after `ok` advances is a scored 90 s run worth taking.

## Harness changes made for this run (kept)

| change | why |
|---|---|
| **framing gate** — require the scorer's own `ok` counter to advance before a run counts; retry the full bring-up; on give-up print *"No DMA number produced. The link would not frame; this is NOT a statement about the DMA."* | the ARM gate and banner check both PASSED on Run 1 and neither verifies that framed data is arriving |
| **TTW reporter** — per-interval `ok` progress, wedge anchored to the sub-second `junkstart` event, plus what fraction of the run was post-wedge | a mid-run wedge should be reported as a time, not silently absorbed into a bad PER |
| **unconditional watchdog restart on every exit path**, including abort | `layerb_run.sh` kills both watchdogs and used to leave them down |

## Rig after Run 2

Watchdogs verified up on both boards by the abort path; 148 `nakstat=4` intact; 146 on
TMR `433fd8dab393`. The gate-fail path kills the `-S` daemons and the watchdog does not
relaunch daemons (`DAEMON_CMD` unset), so `restore_known_good.sh` was run afterwards to
return the link to `-G`.

---

# Runs 3–5 — 2026-08-11 — feeder fixed twice, **both hypotheses falsified**

The feeder WAS broken and is now fixed. It was not the cause. Two explanations died
by measurement, in order:

## Hypothesis 1 — under-feed (DEAD)

Fix: re-fill the TX ring between drained RX slices, instead of once per outer loop
iteration (at F1536, `tx_batch_max()`=5 and polled `max_inflight`=2, so only ~10 frames
— about 8 ms of air — are ever queued, while a 64-slice drain takes longer).

Result: the two boards diverged hard, and the receiver framed nothing either way.

| board | TXRATE | vs air | ok |
|---|---|---|---|
| 148 | 3013 f/s | **242% — OVERfeeding** | 0 |
| 146 | 349 f/s | 28% | 0 |

A transmitter running at 2.4x the air rate with a receiver that frames nothing kills the
under-feed explanation outright. **Feed rate is not the cause.**

## Hypothesis 2 — missing pacing (DEAD)

That 242% was itself the clue. Every other transmit path in the daemon is paced by a
`tx_next` credit at `frame_period_s` — the `-G` loop's
`while (tx_capacity() && now_s() >= tx_next)`, plus `retx_pump` and `axr_pump` which each
consume a credit. **`seq_run` was the only unpaced path**: it filled as fast as the DMA
accepted rather than as fast as the modem transmits, which should overwrite queued frames
mid-transmission and put garbage on the air at any rate.

Fix: `seq_tx_fill` now takes a `tx_next` pacing clock, consumes n credits per batch, and
clamps arrears to one batch so a stalled loop cannot burst-flood the DMA.

The fix works exactly as intended — and framing still did not appear:

| board | before | after pacing | vs air | ok |
|---|---|---|---|---|
| 148 (TX) | 3013 f/s (242%) | **1186 f/s** | **95%** | 0 |
| 146 (RX) | 349 f/s (28%) | 707 f/s | 57% | 0 |

**148 transmits at 95% of the air rate, correctly paced, and the receiver still frames
nothing.** Gate failed 3/3 again.

## Where that leaves the fault

Ruled out by direct measurement, across five runs:

| candidate | evidence against |
|---|---|
| under-feed | 242% overfeed still framed nothing |
| missing pacing | 95% correctly-paced feed still framed nothing |
| `pkt_bytes` mismatch | tap and `qpsk_seq_reset` take the same variable; slices are 1528 B |
| whitening | opt-in, not set |
| tap placement | correct, pre-CRC on the raw slice |
| scorer lock logic | slices carry no frame structure at ANY offset ('QK' at chance) |

What remains is structural: **the `-S` mode does not put framed data on the air at all**,
and the difference from `-G` is no longer about rate or pacing.

## Next candidate, and the test for it

`-G` transmits via `tx_send`; `-S` transmits via `tx_send_batch`. And critically,
`layerb_run.sh` **kills the `-G` daemons and starts new `-S` ones after bring-up has
already established the TX byte-source mux**. The watchdog's `rearm_once` explicitly
re-applies `0x158` (tx_data_source), `0x118` (tx_source_select) and `0x114`
(rx_input_select) after any reset, which is evidence those settings do not survive on
their own.

**Test (cheap, ~2 min):** with `-G` running, read `0x114`/`0x118`; swap to `-S`; read
again. If they differ, the `-S` daemon restart is dropping the TX mux that bring-up
established, and the fix is to re-apply it after launching `-S`. (`0x158` is write-only
and cannot be read back — do not try to verify it directly.)

Second candidate if the mux is intact: `tx_send_batch` itself at F1536 geometry, which
`-G` never exercises.

---

# Run 6 — post-swap byte re-arm — **also dead.** Four hypotheses down; STOP GUESSING

`layerb_run.sh` was violating a finding documented in `bringup_r2r3.sh:128` (R2FINISH):
flipping `0x158=1` before the daemon's TX stream is flowing starts the modulator on an
underrunning byte FIFO, and the discontinuous stream is demod-hostile — "both dirs 0%
while ROM is clean", with a measured flip from 0%/0% to 551/602 f/s once the order was
corrected. Layer B killed the `-G` daemons *after* bring-up armed the byte source, then
started `-S` and never re-armed: exactly that state.

Fix applied: re-arm in bring-up's own order (B then A, double-tapped) **after** `-S` is
already pumping. It ran; the re-arms completed on both boards on every attempt.

**Framing gate still failed 3/3, `ok=0` throughout.**

## The four dead hypotheses

| # | hypothesis | how it died |
|---|---|---|
| 1 | PN feeder under-feeds the air | a **242% OVERfeed** framed nothing |
| 2 | feeder is unpaced, flooding the TX DMA | a **95% correctly-paced** feed framed nothing |
| 3 | `-S` restart drops the TX mux | **untestable as run** — `0x114`/`0x118` are write-only; verdict was void |
| 4 | byte-FIFO underrun from the daemon swap | re-arm applied in bring-up's exact order, still `ok=0` |

Also ruled out earlier: `pkt_bytes` mismatch, whitening, tap placement, scorer lock logic.

## The methodological error

Six runs, four hypotheses, one void test — all of it debugging `-S` on the air link,
one guess at a time, each costing a full bring-up cycle and one of them taking a board
down. **The question never asked is whether `-S` has EVER worked on hardware.** Per this
document's own §7 note, Layer B was "code-complete and sim-tested but never ran on
hardware" — so there is no working baseline, and every run so far has assumed one exists.

Debugging toward a state never demonstrated to be reachable is how six runs produce zero
numbers.

## The right next step: a loopback control, OFF the air link

Run `-S` with `rx_input_select=0` (internal loopback, no air, no peer). It is cheap, needs
neither board's RF nor the other end, and it **bisects the whole problem**:

* `-S` frames in loopback → the fault is in the air path under `-S`, and everything above
  was at least looking in the right half.
* `-S` does NOT frame in loopback → the fault is entirely host/mode-side, reproducible
  with no link at all, and debuggable off hardware with no bring-up cycle per attempt.

Establish that baseline before any further air-link run. If the loopback also fails, no
amount of link time will help, and the remaining air-link runs were spent on the wrong
half of the problem.
