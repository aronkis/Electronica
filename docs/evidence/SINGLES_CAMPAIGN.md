> Evidence ledger, moved verbatim from `two_jup/SINGLES_CAMPAIGN.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Phase 1: does the forward-singles comb exist OFF AIR?

## Lead findings

1. **The forward-singles comb does NOT appear in FPGA-internal loopback
   under single-packet-per-transfer DMA.** Not singles-dominated (see
   Verdict) -- the discriminator that holds regardless of transfer size.
   Whether an M-BATCHED loopback would show it is UNTESTED here: `-B`
   (BER mode) forces `rx_multi=0` regardless of `-M` (`qpsk_tun.c` ~line
   2682), so this arm never exercised the batched-DMA-transfer path the
   comb's boundary-lock hypothesis is about. This capture rules the comb
   out of a single-packet loopback, not out of a batched-DMA mechanism
   specifically -- it needs something this arm didn't test (RF, the SSI
   clock chain, the air-side receive path, or M-batched DMA). Follow-up:
   SSI near-end loopback, to split "needs RF" from "needs the SSI clock
   chain."
2. **An episode matching class-B's signature reproduces with no radio at
   all.** Three ~1.00s outages spaced ~1.8s apart, carrying 96% of all loss
   in this capture, on demand, in a single 140s run, with **no air, no
   peer, no RF**. Previously class-B was only seen on the live link. Exact
   reproduction command:
   ```
   cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
   BOARD=10.0.0.148 M=16 DUR=120 FRAMELOG=1 ARMB_FLAG=-B ARMB_GREP="^ber: t=" \
     ./loopback_s_test.sh
   python3 singles_cadence.py <run-dir>/frames.bin --M 16 --seq reg_packets
   ```
   This makes a previously air-only, hours-per-iteration class into a
   minutes-per-iteration, RF-independent one. See "Off-air class-B-shaped
   episode" below for the scope of this claim (duration/beat match; timing
   determinism not yet shown to match on-air class-B, which is stochastic).

Pre-registered BEFORE the sweep completed (do not revise after seeing the data).

## Command

```
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
chmod +x singles_loopback.sh
setsid nohup env BOARD=10.0.0.148 DUR=120 MS="16 32 64" ./singles_loopback.sh \
  > /tmp/singlesloop.log 2>&1 < /dev/null & disown
```

Board: 10.0.0.148 only (146 untouched, frozen reference). FPGA-internal loopback
(0x114=0, no air, no peer, no RF). `-M` swept over {16, 32, 64}, 120 s per point.
`FRAMELOG=1` passthrough to `loopback_s_test.sh` so `singles_cadence.py` can score
`host_seq`/`crc_ok` from `frames.bin`.

## Verdict rule (stated before the run)

| outcome | meaning | campaign consequence |
|---|---|---|
| **REPRODUCES** | singles/doubles dominate, `boundary_locked` true at every M, PER within 3x of the air value | channel exonerated; campaign moves off-air |
| **DOES NOT REPRODUCE** | PER <= 0.5% and `boundary_locked` false at every M | class needs the air or SSI path; re-run over SSI near-end loopback |
| **PARTIAL** | present at a materially different rate | record the ratio; constrains the mechanism |
| **VOID** | -G positive control does not frame | loopback config wrong; discriminates nothing |

## Pre-registered air-value baseline (for the "within 3x" REPRODUCES test)

Looked up from committed artifacts BEFORE reading the loopback results, per the
"never revise after seeing the data" rule:

- Most recent, most authoritative: `OVERNIGHT_LOG.md` "PER TRUTH" section (commit
  `a2860fb`, 2026-08-22), forward direction (146 TX -> 148 RX), ARQ off, live 68s
  windows, drops counted in the denominator: r1..r4 = 12.370%, 12.222%, 12.488%,
  13.211% -> pooled ~12.4%. That document itself flags "BASELINE DRIFT: forward
  was 8.2-8.3% weeks ago, now ~12.4% -- channel/rig degradation on top of the comb
  class. Re-anchor before any new claim."
- Older baselines, same class, same forward direction: `two_jup/HANDOFF_20260815.md`
  ~8.27% pooled; `two_jup/FWD_SINGLES_ROOT_CAUSE.md` ~8.55% pooled (flagged
  "partially superseded").

Because the campaign's own record disputes which of these is "the" air value, the
pre-registered comparison band is the full observed range: **8.2% - 12.4%**. The
3x REPRODUCES threshold is therefore **PER <= ~37.2%** (3x the higher, more recent
figure) as the outer bound, with **PER in roughly 25-37%** the expected REPRODUCES
zone if the mechanism is unchanged. This band, not a single cherry-picked number,
was fixed before the loopback numbers were read.

## MODE CORRECTION (2026-08-22/23, applied after the pre-registration above)

The first sweep ran ARM B as `-S`; `QPSK_FRAMELOG` does not populate
`crc_ok`/`host_seq` under `-S` (every record logged `crc_ok=0`,
`host_seq` unset), so `singles_cadence.py` correctly refused to score it.
ARM B was switched to `-B` (BER mode, the mode `QPSK_FRAMELOG` actually
fills, as `capture_paired.sh` already does), scored via
`--seq reg_packets` (the hardware packet counter -- `-B` carries no usable
per-frame `host_seq`). Two further defects were found and fixed on real
captures before the final sweep: (1) `-B` sets `k5_mode=1` itself, which
conflicts with the inherited `QPSK_FRAME=f1536` env var and made the daemon
refuse to start -- fixed by dropping `QPSK_FRAME=f1536`/`QPSK_SEQ_KEEPM=1`
from the `-B` arm's env; (2) `reg_packets` is a free-running FABRIC counter
that the loopback arming sequence resets mid-capture (a `0x000` pulse) --
`singles_cadence.py` now de-wraps genuine counter resets (distinguished from
an isolated scrambled record's cancelling up/down spike) before scoring.
See `two_jup/loopback_s_test.sh`, `two_jup/singles_cadence.py`, and
`.superpowers/sdd/2026-08-22-forward-singles/task-3-report.md` for the full
diffs and validation (including a 60s M=16 smoke test that reproduced the
teammate's independent probe numbers exactly before the full sweep ran).

The final command actually run:

```
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
setsid nohup env BOARD=10.0.0.148 DUR=120 MS="16 32 64" ./singles_loopback.sh \
  > /tmp/singlesloop3.log 2>&1 < /dev/null & disown
```

(`singles_loopback.sh` internally passes `FRAMELOG=1 ARMB_FLAG=-B
ARMB_GREP="^ber: t="` to `loopback_s_test.sh` and scores with
`--seq reg_packets`.)

## Four scorer/harness defects found and fixed during this task

Recorded so the next person does not rediscover them:

1. **`QPSK_FRAMELOG` + `-S` is an invalid pairing.** `QPSK_FRAMELOG`
   populates `crc_ok`/`host_seq` only in tun/echo/`-B` modes
   (`qpsk_tun.c` `framelog_record()` call sites). Under `-S`, every record
   logs `crc_ok=0` with `host_seq` unset. The first sweep paired them and
   produced an unscorable capture.
2. **`classify()` used to invent a ~2^32 frame universe instead of
   refusing.** The old fallback took `seq.min()/max()` over ALL records,
   so a handful of scrambled/unset `host_seq` values (as in defect 1)
   fabricated an enormous span and reported a confident `per=1.0`.
   `singles_cadence.py` now raises `ValueError` naming the mode problem
   instead of scoring garbage. It also now raises on a *degenerate*
   sequence field (few unique values, heavy duplication -- the actual
   shape `-B`'s `host_seq` takes), a different failure mode from the
   all-`crc_ok==0` case, added in the same fix.
3. **`reg_packets` is a free-running FABRIC counter that the loopback
   arming sequence resets mid-capture** (a `0x000` pulse). Scored naively,
   that single backwards step reads as one enormous hole and inflates PER
   from ~4.5% to ~29%. `singles_cadence.py` now de-wraps genuine counter
   resets (any backwards step in an otherwise +1-stepping field, no
   magnitude threshold) while explicitly NOT stitching an isolated
   scrambled record's cancelling up/down spike (which would graft a huge
   offset onto the rest of the capture and defeat the garbage-seq guard).
4. **The harness printed a confident, false `-S` verdict for an arm that
   never ran `-S`.** When ARM B was switched to `-B`, `loopback_s_test.sh`'s
   VERDICT block still parsed for `-S`'s `ok=`/`junk=` lines and printed
   "-S DOES NOT FRAME IN LOOPBACK ... the fault is entirely HOST/MODE-SIDE"
   -- a real conclusion about a mode that was never executed, because the
   daemon that did run (`-S`) never started. Fixed by gating the entire
   `-S`-specific interpretation block on `ARMB_FLAG`, printing a neutral
   one-liner naming what actually ran when it isn't `-S`.

Also worth carrying forward: `-B` sets `k5_mode=1` itself, which conflicts
with `QPSK_FRAME=f1536` and made the daemon refuse to start on the first
`-B` attempt ("`-F (K5) and -G/QPSK_FRAME=f1536 are mutually exclusive`");
and `-B` forces `rx_multi=0` regardless of `-M`
(`if (ber || ...) rx_multi = 0;` in `qpsk_tun.c`), so `-M` does not change
the actual DMA transfer size under this arm -- see the Verdict section for
what that means for the boundary-lock and PER-invariance results below.

## Per-M results

| M | idle_rx (control) | n_frames | n_bad | PER | singles | doubles | longer | boundary_enrichment | boundary_locked |
|---|---|---|---|---|---|---|---|---|---|
| 16 | 185806 | 174191 | 4525 | 2.598% | 134 | 25 | 6 | 0.996 | False |
| 32 | 185813 | 174054 | 4524 | 2.599% | 133 | 25 | 6 | 0.972 | False |
| 64 | 185754 | 174122 | 4529 | 2.601% | 138 | 25 | 6 | 0.970 | False |

All `idle_rx` values are far above 0 (control OK, not VOID). `n_resets=1` at
every M -- the loopback-arming fabric-counter reset, correctly de-wrapped
(confirmed: `n_frames` matches the de-wrapped span with no manufactured
holes). Run-length histograms and per-10s loss profiles are inlined below
in this document; the raw per-M scorer output and this task's script diffs
are additionally in
`.superpowers/sdd/2026-08-22-forward-singles/task-3-report.md`.

**Holes in the denominator:** confirmed counted. `n_bad` includes every
CRC-failed record; there are zero unaccounted gaps in the de-wrapped
`reg_packets` stream beyond the single genuine fabric reset (excluded from
the loss count because it is a renumbering, not a lost frame).

## Run-length histograms and per-10s loss profile, every M

### M=16
```
run-length histogram: {1: 133, 2: 25, 3: 2, 20: 1, 628: 1, 1212: 1, 1235: 1, 1260: 1}
frames in runs>=3: 4361  (96.0% of all bad)
  len=20    t=0.0s   dur=0.02s   (startup transient)
  len=628   t=6.8s   dur=0.50s   (startup transient, second episode)
  len=1212  t=41.8s  dur=0.97s   (class-B-shaped outage 1)
  len=1235  t=43.6s  dur=0.99s   (class-B-shaped outage 2)
  len=1260  t=45.4s  dur=1.01s   (class-B-shaped outage 3)

per-10s loss profile:
  t=   0-10s  n=12442  bad= 663    5.33%
  t=  10-20s  n=12446  bad=  11    0.09%
  t=  20-30s  n=12444  bad=  15    0.12%
  t=  30-40s  n=12444  bad=  10    0.08%
  t=  40-50s  n=12443  bad=3714   29.85%   <- the three outages land here
  t=  50-60s  n=12444  bad=  18    0.14%
  t=  60-70s  n=12443  bad=  20    0.16%
  t=  70-80s  n=12443  bad=  18    0.14%
  t=  80-90s  n=12444  bad=  15    0.12%
  t=  90-100s n=12443  bad=  14    0.11%
  t= 100-110s n=12443  bad=  12    0.10%
  t= 110-120s n=12444  bad=  11    0.09%
  t= 120-130s n=12444  bad=  11    0.09%
  t= 130-140s n=12444  bad=  12    0.10%
```

### M=32
```
run-length histogram: {1: 133, 2: 25, 3: 2, 119: 1, 628: 1, 1212: 1, 1235: 1, 1260: 1}
frames in runs>=3: 4460  (96.1% of all bad)
  len=119   t=0.0s   dur=0.10s   (startup transient)
  len=628   t=6.8s   dur=0.50s   (startup transient, second episode)
  len=1212  t=41.8s  dur=0.97s   (class-B-shaped outage 1)
  len=1235  t=43.6s  dur=0.99s   (class-B-shaped outage 2)
  len=1260  t=45.4s  dur=1.01s   (class-B-shaped outage 3)

per-10s loss profile:
  t=   0-10s  n=12442  bad= 764    6.14%
  t=  10-20s  n=12445  bad=  11    0.09%
  t=  20-30s  n=12444  bad=  10    0.08%
  t=  30-40s  n=12442  bad=  12    0.10%
  t=  40-50s  n=12437  bad=3715   29.87%
  t=  50-60s  n=12438  bad=  18    0.14%
  t=  60-70s  n=12437  bad=  17    0.14%
  t=  70-80s  n=12437  bad=  19    0.15%
  t=  80-90s  n=12437  bad=  18    0.14%
  t=  90-100s n=12438  bad=  13    0.10%
  t= 100-110s n=12443  bad=  12    0.10%
  t= 110-120s n=12443  bad=  13    0.10%
  t= 120-130s n=12444  bad=  12    0.10%
  t= 130-140s n=12446  bad=   9    0.07%
```

### M=64
```
run-length histogram: {1: 138, 2: 25, 3: 2, 89: 1, 628: 1, 1212: 1, 1235: 1, 1260: 1}
frames in runs>=3: 4430  (95.9% of all bad)
  len=89    t=0.0s   dur=0.07s   (startup transient)
  len=628   t=6.8s   dur=0.50s   (startup transient, second episode)
  len=1212  t=41.8s  dur=0.97s   (class-B-shaped outage 1)
  len=1235  t=43.6s  dur=0.99s   (class-B-shaped outage 2)
  len=1260  t=45.4s  dur=1.01s   (class-B-shaped outage 3)

per-10s loss profile:
  t=   0-10s  n=12442  bad= 732    5.88%
  t=  10-20s  n=12445  bad=   9    0.07%
  t=  20-30s  n=12445  bad=  12    0.10%
  t=  30-40s  n=12444  bad=  12    0.10%
  t=  40-50s  n=12443  bad=3714   29.85%
  t=  50-60s  n=12444  bad=  19    0.15%
  t=  60-70s  n=12443  bad=  18    0.15%
  t=  70-80s  n=12443  bad=  19    0.15%
  t=  80-90s  n=12443  bad=  17    0.14%
  t=  90-100s n=12444  bad=  14    0.11%
  t= 100-110s n=12443  bad=  12    0.10%
  t= 110-120s n=12443  bad=  13    0.10%
  t= 120-130s n=12445  bad=  13    0.10%
  t= 130-140s n=12444  bad=  13    0.10%
```

The startup transient (t=0-10s, ~5.3-6.1% loss) and the three-outage episode
at t=41.8-46.4s are near-identical in timing and in run-length values
(1212/1235/1260) across all three independently-launched M sweeps. Outside
those two windows, the steady state runs at 0.07-0.16% per 10s decile.

## Verdict

**Branch that fired, on the letter of the pre-stated rule: PARTIAL** (PER
2.60% at every M exceeds the rule's 0.5% DOES NOT REPRODUCE ceiling;
boundary_locked is False at every M; the -G control is not VOID). This is
reported as the fired branch, not revised after seeing the data.

PARTIAL's own definition calls for the ratio: pre-registered air band was
**8.2-12.4%**; loopback PER is **2.60%**, i.e. **roughly 1/3 to 1/5 of the
air rate**. Confound stated explicitly: the loopback 2.60% is composed of a
DIFFERENT loss class (see below), so this ratio bounds an overall rate, not
a comb mechanism rate -- it must not be read as "the comb reproduces at
reduced strength."

**Substantive conclusion, reported alongside the fired branch rather than
in place of it: the forward-singles comb itself is absent from this
capture.**

- **Loss-rate class (the discriminator that holds regardless of what -M
  means under this arm):** ~0.95-0.99 singles/s over 140s vs the air
  class's ~50/s; 96.0-96.1% of all bad frames at every M sit inside 3 giant
  bursts (lengths 1212/1235/1260, each ~1.00s, ~1.8s apart) plus one smaller
  startup transient -- not the comb's isolated-singles shape at all.
- **Boundary lock is False at every M (enrichment 0.97-1.00x vs the air
  capture's 1.68x), but this is a WEAKER signal here, not independent
  confirmation:** `qpsk_tun.c` forces `rx_multi = 0` whenever `-B` is
  selected, regardless of `-M` (`if (ber || ...) rx_multi = 0`), and
  `rx_multi` is what actually sets the DMA transfer length
  (`dmac_wr(DMAC_X_LENGTH, rx_multi*pkt_bytes-1)`). So all three M points
  ran the SAME single-packet-per-transfer configuration; there is no real
  M-frame transfer boundary under this arm for a loss to lock to, so
  `boundary_locked=False` is close to the expected null rather than an
  independently informative negative.
- **PER is essentially identical across M (2.598/2.599/2.601%) -- this is
  run-to-run repeatability of the SAME configuration (see above), not
  evidence about DMA-transfer-size invariance.** Do not cite it as a
  transfer-boundary-mechanism result.

**Why the rule's 0.5% ceiling misfired:** it silently assumed the loopback
floor would otherwise be clean. It is not -- an episode matching class-B's
signature (below) occupies 96% of the bad frames and was not anticipated
when the rule was written. That is a defect in the pre-stated rule, named
here rather than used to relabel PARTIAL as something else.

**Bonus finding -- an episode matching class-B's duration/beat signature
reproduces off-air, deterministically.** Three ~1.00s dead windows at a
~1.8s beat (durations 0.97s/0.99s/1.01s, spaced 1.8s/1.8s), at essentially
the same wall-clock offset (t~42-46s) in all three independently-launched M
sweeps, plus a smaller startup transient at t=0-7s. Duration and beat match
`TGEN_SWEEP.md`'s class-B signature verbatim, reproduced with **no radio, no
peer, no RF at all**. But `TGEN_SWEEP.md` documents class-B as episodic and
STOCHASTIC ("6/10 windows had an episode" over ten 60s runs), not tied to a
fixed onset offset -- this capture's fixed ~t+42s offset across three
separate launches is a deterministic regularity not previously reported for
class-B. Whether this off-air, bring-up-timed episode shares a root
mechanism with on-air class-B is therefore OPEN, not established: they
match on duration/beat and are not yet shown to match on timing behavior.
Reported as "an episode matching class-B's signature reproduces off-air,
deterministically, with no RF" -- not as "class-B reproduces." Regardless of
mechanism identity, this is a useful, separate open track: previously only
seen on the live air link, now reproducible on demand in a single 140s
FPGA-loopback run on 148 alone.

**Follow-up per the brief:** re-run over SSI near-end loopback to split
"needs RF" from "needs the SSI clock chain" for the forward-singles comb,
and re-scope Phase 2 accordingly.

## Step 4: rig restore

```
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
setsid nohup ./restore_known_good.sh > /tmp/restore_after_loop.log 2>&1 < /dev/null & disown
```

Captured output (arm gate FAILED as expected -- the known, pre-existing RF
blocker, not a fault introduced by this task; not retried):

```
=== RESTORE: gated bring-up, plain app, default -M 16 (shipped) ===
bring-up exit=1 (log /tmp/restore_bringup.log)
gate try 12: 148 rx=1241 f/s   146 rx=580 f/s   (need >= 1120)
ARM GATE FAILED after 12 tries -- NOT starting daemons
=== restart lock_watchdog on BOTH boards ===
10.0.0.146 watchdog VERIFIED up
10.0.0.148 watchdog VERIFIED up
=== FINAL VERIFIED STATE ===
--- 10.0.0.146 ---
BOOT.BIN   : 433fd8dab393
app md5    : 27264f57
nakstat    : 0 (148 must be 4)
rxqstat    : 0 (must be 0 -- plain build)
daemon     : DOWN
watchdog   : up
--- 10.0.0.148 ---
BOOT.BIN   : fe5bd8a4fe19
app md5    : 038d0035
nakstat    : 4 (148 must be 4)
rxqstat    : 0 (must be 0 -- plain build)
daemon     : DOWN
watchdog   : up
link stats : dma_rx_ok=13 crc_drop=15443045
=== restore complete 2026-08-23T00:52:16-04:00 ===
```

148 healthy at ~1241 f/s; 146 pinned at ~580 f/s (unchanged since before
this task, still below the 1120 f/s gate). No daemons started on either
board; watchdogs verified up on both; 146's BOOT.BIN/app md5 unchanged --
the frozen reference board was not touched.

---

## Task 3b — batched DMA ENGAGED, rate-controlled, radio-free (2026-08-23 ~04:5x)

This is the configuration Tasks 3/3a each failed to achieve: the `-B` arm bypassed the
batched DMA path (`rx_multi=0`), and the `-S` arm engaged it but over-offered ~5.8x line
rate. Here the in-fabric TGEN supplies an exact offered rate through the real DUT TX path
into FPGA-internal loopback, and the host scorer runs `-S` with **`QPSK_SEQ_KEEPM=1`** so
the batched path is genuinely exercised.

**Gate (all four, every point):** `batch_m == RXM` (16), `accounted == seq_span` exactly,
no TX overrun, DMA pathology counters read out per point.

Harness: `two_jup/tgen_sweep.sh` with the new `KEEPM=1 RXM=<m>` knobs (default OFF, so
prior behaviour is byte-identical). CSV `tgen_sweep_20260823_045344.csv`.

    GAPS="200000 100000 50000 20000" FILLS=1516 DWELL=60 KEEPM=1 RXM=16 ./tgen_sweep.sh

| gap | seq rate (f/s) | ok | lost | gaps | biterr | scattered | batch_drop | **PER** |
|---|---|---|---|---|---|---|---|---|
| 200000 | 211  | 12543 | 91  | 76  | 0  | 0  | 0 | **0.72 %** |
| 100000 | 624  | 37198 | 213 | 148 | 1  | 1  | 0 | **0.57 %** |
| 50000  | 439  | 26202 | 135 | 46  | 12 | 12 | 1 | **0.51 %** |
| 20000  | **1247 = LINE RATE** | 74351 | 467 | 146 | 27 | 27 | 3 | **0.62 %** |

PER denominators are `seq_span = ok+biterr+lost` (the loss-proof identity held exactly at
every point). `batch_m=16` at every point.

### Finding

**At the air link's own operating point — 1247 f/s, line rate, through the real batched
DMA at M=16, with the radio removed — delivered loss is 0.62 %. On air it is ~12.4 %.**
Loss does not grow with offered rate (0.5–0.7 % flat from 211 to 1247 f/s).

The fabric RX -> byte plane -> batched DMA -> host path is therefore **NOT** where the
~12.4 % forward loss lives. FPGA-internal loopback still includes the demodulator (it
feeds the modulator output back into the demod input) and excludes only the ADRV9002 /
RF chain. So the loss is in the **RF / SSI path**, not the fabric or host side.

This closes the gap the Task-3 retraction opened: Task 3's `-B` arm could not speak to
batched DMA, and now the batched path has been tested directly, at line rate, and is
clean.

### Corroboration
`scattered == biterr` exactly at every point (0/0, 1/1, 12/12, 27/27) -- the documented
host scattered-DMA slice identity, reproduced again. `batch_drop` stays 0–3.

### Caveat
`offered_fps` in the CSV is a computed nominal from the gap; the delivered sequence rate
is `seq_span / DWELL` and is what the table above reports. Only the gap=20000 point
reaches line rate.

---

## Phase 0.3 — forward baseline RE-ANCHORED (2026-08-23 08:0x)

The rig was believed RF-blocked for ~6 h (146 RX pinned 498-580 f/s across 12-try gates,
three full restores, and a cold power cycle). A plain `GATE_DIR=A` bring-up then passed
on **try 1** with 146 rx=1210 f/s. On the very next run 146 was back to 519 f/s — but the
capture still succeeded, because `GATE_DIR=A` gates on 148 only and **the forward
direction (146 TX -> 148 RX) does not depend on 146's receiver at all.**

=> The blocker was NOT a hard reverse-RF fault. It is intermittent and matches the
open #48 arm-lottery class ("fresh queued arms fail ~40-100%, worsen with accumulated
state, only a full two-board bring-up recovers"). The ~6 dB RSSI asymmetry may still be
real; it was not what prevented lock. **Forward air measurement was never actually
blocked — only the both-directions gate was.**

Command (exact):

    GATE_DIR=A ./capture_r3.sh A -d 68 -k -o r3cap/fwdbase_20260823_080537
    python3 accept_analyze.py r3cap/fwdbase_20260823_080537/frames.bin

Result:

    live 78s/77s   PER = 13.107%  (10181/77674)   CP95UL = 13.347%
    lag33 = -0.056
    gap bins: {1: 6081, 2: 1576, 3-4: 222, 5-20: 29, 21-100: 0, >100: 0}
    wedges during capture: 0
    GATE (<1% at CP95 upper limit): NOT MET

Denominator is 77,674 frames over the steady live window; dropped frames are counted via
host_seq gaps and are IN the denominator. Zero wedges, so no window was excluded.

**The class is unambiguously the singles comb**: 7,657 of 7,908 loss runs are singles or
doubles, nothing above 20. And the drift continues — 8.3% (weeks ago) -> 12.4% (08-22)
-> **13.1%** (08-23).

### The contrast that now defines the campaign

| path | rate | DMA | loss | shape |
|---|---|---|---|---|
| air, forward | 1245 f/s | batched M=16 | **13.107 %** | singles+doubles dominated |
| FPGA-internal loopback (Task 3b) | 1247 f/s | batched M=16, verified `batch_m=16` | **0.62 %** | burst-dominated, no singles comb |

Same line rate, same batched DMA, same fabric, same host, same scorer discipline. The
21x difference is everything the air path adds and loopback does not: the RF chain, the
SSI ingress, and the ADC->demod ingress stage inside the fabric.

---

## Float vs fixed on the 13.1% capture — BOTH LEGS UNUSABLE (2026-08-23 09:xx)

Ran both oracles on `r3cap/fwdbase_20260823_080537/pair.iq` (the capture that scored
13.107% delivered PER). **Neither produced a citable number, and the root cause is the
same for both: that capture carries `qpsk_perf` TUN traffic — arbitrary payload — while
both oracles score against a KNOWN REFERENCE.**

### Float leg — did not lock (do not cite)
`float_oracle_r3(pair.iq, 4e6)`:

    frames detected 99 vs expected 80 | degraded 99/99 | "FAILURE BOUND 123.75%"
    EVM median 58.81 / p95 58.91 / max 58.92   (spread 0.11% across 99 frames)
    preCorr median 0.637 == min 0.637          (identical for every frame)

A >100% failure rate is degenerate on its face. Constant-to-3-digits EVM and an identical
preamble correlation for all 99 detections mean the front end never locked. **Decisive
check: the DUT decoded 86.9% of frames CLEANLY from these exact samples** — QPSK at 58.8%
EVM is unusable, so this is instrument failure, not a channel measurement. (The oracle's
own comment expects the population at ~13-14% EVM.)

Capture is sound: 4M complex samples, ZERO all-zero samples, no dropouts, mean |iq| 4004
on ~8000 full scale — NOT the zero-run problem `replay_capture.sh` splices out.
LEAD, not a conclusion: `max=7968`, `p99=7967` => ~1% of samples pinned at the ceiling
(hard clipping at the tap). Cannot be catastrophic (87% decoded) but would plausibly
break a float front end tuned for an unclipped constellation while a hardware slicer
tolerates it.

### Fixed leg — scored the wrong metric (do not cite)
`CAP=.../pair.iq ./run_region.sh 0 79 0 4`:

    chunk_0_69_r0 : packets=69 biterr=4109 outFrames=39 capGoldFrames=0/39 goldAny=0
    chunk_70_79_r0: packets=17 biterr=999  outFrames=8  capGoldFrames=0/8  goldAny=0

`capGoldFrames` and `biterr` both score against the **ROM/BIST golden pattern**. The
capture is tun traffic, so 0/39 golden is EXPECTED and MEANINGLESS — it is not evidence
of corruption. The recovered word stream (`_rxw.txt`, 11,114 words) is intact; what is
missing is a per-frame seq/CRC scorer over it (the path `SINGLES_REPLAY.md` used;
`score_rxw_seq` is not present in this tree).

**Also flagged: this harness is the WRONG NETLIST GENERATION.** `run_region.sh` links the
preserved `obj_byte_iq_f1536` archive at **cadence 4** = the Jul-25 generation; the
flashed image is cadence 2 (see `NETLIST_PROVENANCE.md`). Comparable to the Aug-12
`SINGLES_REPLAY` result, NOT to the netlist on the board today.

### What is actually needed
A forward capture with a **known reference stream** — ROM/BIST on-air (which
`replay_capture.sh` explicitly supports via `-r rx_words_golden.hex`, and which makes
`perframe_f1536`'s `capGold` meaningful) or `-S` sequence traffic. Then the fixed leg
scores directly. The float leg additionally needs its lock problem solved (clipping /
`bs_front_end` options) before its number means anything either.

**Process note:** the tun-vs-reference mismatch was identified BEFORE these runs and then
not acted on — both oracles were pointed at data they structurally cannot score. Confirm
the scorer can read the capture before spending the run.

---

## ROM-on-air capture + full quadrant sweep — the FIXED harness is the wrong generation

New instrument `two_jup/capture_rom_air.sh`: forward ROM/BIST-on-air IQ capture. Keeps the
link on the ROM source so **every transmitted frame IS the reference** (capture_r3 flips to
the byte source, which is why its captures carry unscoreable tun payload). Forward-only, so
it works while 146's receiver is in the #48 arm-lottery state. Gates on 148 ROM framesync
>= 1120 f/s and aborts rather than capturing something worthless.

Capture `r3cap/romair_20260823_115206` (148 ROM framesync 1242 f/s):

    CAP_START pkts=0x3833 biterr=0x91D8 rstcs=0x0
    CAP_END   pkts=0x38CF biterr=0x9313 rstcs=0x0
    => 156 frames, 315 bit errors, ZERO carrier resets  ~= 8.2e-5 BER on air

**That is a clean reference-scored hardware number for the forward air path.**

### Full rot x vphase sweep through the fixed netlist — ALL EIGHT NULL

`replay_capture.sh` warns that a cold-start wrong-quadrant lock scrambles post-FEC bits
irrecoverably and that the 8-point sweep is what made prior replays conclusive. Ran it
(40 frames/point):

| rot | vp | biterr | capGoldFrames |
|---|---|---|---|
| 0 | 0 | 2201 | 0/20 |
| 90 | 0 | 2311 | 0/17 |
| 180 | 0 | 2276 | 0/21 |
| 270 | 0 | 2338 | 0/21 |
| 0 | 1 | 2300 | 0/20 |
| 90 | 1 | 2376 | 0/19 |
| 180 | 1 | 2264 | 0/20 |
| 270 | 1 | 2348 | 0/20 |

`goldAny=0` and `capEverGold=0` in all eight. **The quadrant hypothesis is REFUTED**: a
genuine quadrant miss shows one rotation collapsing to near-zero while the others scramble.
Flat to within 8% across all eight means the harness is not decoding in ANY orientation.

### Verdict: harness, not data

Live silicon decoded **this same signal** at 315 errors / 156 frames (8.2e-5), rstcs=0. The
replay is ~30x worse per frame (2,250 / 39). **A bit-true model of a receiver cannot be 30x
worse than the silicon it models when fed that silicon's own samples.**

Mechanism, consistent with both symptoms at once: `sim_byte_iq_perframe.cpp:41` hardcodes
`CAPGOLD=0x04922282`, which Task 1 verified as the **v3** golden -- but `perframe_f1536`
links the preserved **Jul-25** `obj_byte_iq_f1536` archive (cadence 4). If the generations
differ in ROM content or framing, `capGoldFrames` reads 0/N even on a perfect decode AND
the internal BIST comparator counts spurious errors against the wrong reference.

**=> The Jul-25 fixed harness CANNOT validly score captures from the current lineage.**
This retires the tap_replay_study path for current work, the same way NETLIST_PROVENANCE
retired `sim_byte_dip` and `wrap_byte_lock.v`.

### What each leg still needs

* **FIXED**: an IQ-fed wrapper built against the **v3** netlist. `wrap_byte_bf2.v` (the only
  wrapper proven to build against v3) is BIST-ROM driven and takes no IQ; the IQ wrappers
  (`wrap_byte`, `wrap_byte_taps`) are the K5-geometry path. This is new RTL-harness work,
  not a flag change.
* **FLOAT**: `bs_front_end` must lock first (see the clipping lead: ~1% of samples pinned
  at 7968). Its number is a front-end BOUND, never an FER, at f1536.

**No float-vs-fixed comparison exists, and none is available without one of the above.**
Three separate offline oracles have now failed on current-lineage captures while the
silicon decodes them fine.

---

## Float front end does NOT achieve frame lock on air data — and it is not "broken instrument" (2026-08-24)

The purpose-built f1536 float receiver (`k5_240/float_baseline_f1536.m`, G1-clean: decodes
a synthetic waveform to **exactly 0 bit errors**, mapping self-identified, margin 12068)
was pointed at the ROM-on-air capture `r3cap/romair_20260823_115206`. It fails to frame:

    framed 103 candidates          (81 real frames in this capture)
    preCorr accepted 0.637/0.637/0.649    rejected n=0
    mapping winner err=12110, runner-up err=12110, margin=0
    ber=4.926e-01   frameRecovery=0.0000

### Direct preamble-correlation test (decisive)

Correlating the capture's symbol stream against `cfg.PreambleSymbols`:

    PEAKS n=51   peak min/med/max = 0.637 / 0.637 / 0.649
    SPACING med = 9280   (expect 12333)   frac within 1% of frame len: 0.06
    CORR floor: median of ALL samples = 0.343   p99 = 0.637

**The "peaks" are the correlation floor.** p99 of the entire correlation function is 0.637
— identical to the peak values. There is no distinguished maximum: the correlator is
picking noise-level maxima, and their spacing (9280) has nothing to do with the 12333-symbol
frame. The same pipeline gives preCorr **0.9998** on our synthetic waveform, so the pipeline
works when the input matches expectation.

### This partially VINDICATES float_oracle_r3, which I retired as "broken"

On 2026-08-23 I retired `float_oracle_r3` as an input-independent instrument because its EVM
was identical to 4 significant figures across two different captures. Our independently-built
receiver, sharing no code with it, now reproduces **the same 0.637 preamble correlation and
the same ~103-vs-81 over-detection** on this data.

Two independent front ends agreeing to three decimal places is not two coincidental bugs.
The likelier reading: BOTH are correctly reporting that the preamble does not correlate, and
`float_oracle_r3`'s identical-EVM-across-captures is what you get when EVM is computed on
mis-framed data in both. **"Broken instrument" was stated as settled and was not.**

### What is NOT the explanation

- Not geometry: 4e6 samples / 49332 samples-per-frame = 81 frames, matching
  `SINGLES_REPLAY.md`'s independently-derived SPF for captures from this same harness.
- Not CFO: the new geometry-derived bound correctly rejects a wild 28591 Hz refine estimate
  (`bound 623 Hz`) and applies 7 Hz.
- Not the hardware: 148's own framesync counter read **1242 f/s** throughout this capture,
  i.e. the DUT frames this exact signal without difficulty.

### Open, and the next thing to settle

`cfg.PreambleSymbols` is taken from `commhdlQPSKTxRxParameters()` on the strength of a
COMMENT in `evm_config_1536k.m:16` claiming it is shared with K5 verbatim. That has never
been checked against what the f1536 hardware actually transmits. Measured shape: 13 symbols,
all unit magnitude, angles only -135 deg or +45 deg — i.e. **BPSK on one diagonal**, a
Barker-13. Whether the DUT's ROM/BIST path emits that same sequence, at that same
modulation, un-whitened, is unverified.

This plan has now produced FOUR defects of the form "K5 value assumed valid at f1536"
(global RNG, Es/N0 scaling, Gray vs binary demap + continuous-traceback Viterbi, CFO
implausibility bound). An unverified K5-inherited preamble is the same shape as all four.

---

## ROOT CAUSE: the IQ CAPTURE PATH is bad, not the oracles (2026-08-24)

Every IQ-based conclusion drawn on 2026-08-23/24 rests on captures that do not contain the
modem signal. Sample-level evidence, no receiver involved:

| capture | occupied BW (-20 dB) | envelope periodicity |
|---|---|---|
| `singles_reread` (Aug-12, decoded 12/12 CRC-good by SINGLES_REPLAY) | **22.16 MHz** | lag 2604, corr 0.52 (normal) |
| `fwdbase_20260823_080537` (today, tun) | **2.88 MHz** | lag 256, corr **0.9997** |
| `romair_20260823_115206` (today, ROM/BIST) | **2.88 MHz** | lag 256, corr **0.9997** |

Expected for QPSK RRC beta=0.5 at Rsym=15.36 Msym/s is ~23 MHz. Today's captures occupy
**exactly 1/8 of that** and repeat every 256 samples with correlation 0.9997.

Cross-correlating today's two captures against each other -- taken 4 hours apart, one in
tun mode and one in ROM/BIST mode:

    identical bytes: 0
    peak cross-corr = 0.9986
    256-sample block: max deviation across 50 consecutive repeats = 25 (raw int16)
    distinct values within one 256 block: 247   (a real pattern, not a constant)

**The tap returns the same content regardless of what the modem transmits.** This is a
stale/replayed or mis-muxed buffer, not live RX data.

### This retracts three earlier conclusions, all of which blamed the wrong thing

1. **"float_oracle_r3 is a broken, input-independent instrument"** (08-23) -- WRONG, and now
   provably so. I retired it because its EVM was identical to 4 sig figs across two
   captures. Those two captures cross-correlate at **0.9986**: they ARE effectively the
   same signal. The tool was reporting correctly on degenerate input. **Fully vindicated.**
2. **"The Jul-25 fixed harness cannot score current-lineage captures"** (08-23) -- NOT
   SUPPORTED by that evidence. Its 0/N golden and ~30x-worse-than-silicon BER are exactly
   what feeding a non-f1536 signal produces. The generation-mismatch concern remains real
   in principle (CAPGOLD is the v3 value, the archive is Jul-25 cadence-4), but it was not
   demonstrated by those runs.
3. **"The f1536 float receiver cannot frame air data / the preamble may be wrong"**
   (earlier today) -- the receiver is FINE. Sample-level correlation with no symbol
   synchronizer involved finds our synthetic frames at exactly 49332-sample spacing
   (pk/floor 4.56, 83% within 1%) and finds nothing in the air capture because the air
   capture contains no f1536 frames. `cfg.PreambleSymbols` is NOT implicated.

### What still stands

- **Forward PER 13.107 %** (CP95UL 13.347 %, n=77674) -- derived from `frames.bin`, the
  HOST framelog, independent of the IQ tap.
- **Air BER ~8.2e-5, rstcs=0** -- derived from the on-board BIST counters (0x108/0x104
  deltas), independent of the IQ tap.
- **Task 3b's 0.62 % batched-DMA loopback result** -- host-side seq accounting, no IQ.
- All of Tasks 1-3 of the float-baseline plan: the receiver is G1-clean and its gates are
  sound. It was pointed at bad data.

### Live suspect for the capture defect

148 has been reflashed several times since Aug-12 and now runs BEATFIX v3 `fe5bd8a4fe19`.
That lineage carries the beat-ILA debug tap infrastructure -- `iq_debug_mux` taps consuming
all four 16-bit IP Data OUT slots, with mux selects driven by register writes
(`capture_window_iq.sh` sets mux=2 for post-carrier, mux=3 for decisions). If the
`axi-adrv9002-rx-lpc` tap is currently muxed to a debug source rather than the raw ADC
stream, every capture from this image would look like this regardless of traffic.

**Next step: read/set the iq_debug_mux state explicitly before capturing, and re-take a
capture with the mux verified. Do not draw another IQ-based conclusion until a capture
reproduces the ~22 MHz occupancy and non-degenerate envelope statistics of the Aug-12
reference.**

### Process note

Three separate instruments were investigated, two were retired, and one had a real bug
found and fixed -- before anyone checked whether the INPUT was valid. The Aug-12 capture
was available the whole time as a known-good reference; a two-line bandwidth/periodicity
comparison against it would have caught this at the start. **Characterise the input before
debugging the instrument.**

### Mux hypothesis REFUTED; it is the #48 stale-DDR-replay class (2026-08-24)

Gated probe (`gated_muxprobe.sh`): link brought up and **verified at 1243 f/s framesync**
at capture time, `iq_debug_mux` (0x10C) explicitly cleared to 0, device `rx-lpc`:

    GATED(fs=1243, mux=0)   occ= 2.88 MHz   env lag= 256  corr=0.9994
    REFERENCE(Aug-12 good)  occ=22.16 MHz   env lag=2604  corr=0.5153

Clearing the mux does NOT fix it. The earlier "clearing the mux changed the capture"
observation was confounded -- that probe ran at 384 f/s on a degraded link and was
uninterpretable. Also note the beat campaign's debug taps went to **rx2-lpc**, a different
IIO device from the `rx-lpc` we capture, which already argued against the mux mechanism.

**Verdict: the IQ capture DMA is in the #48 stale-DDR-replay state.** The decisive
evidence needs no new run: two captures **4 hours apart, in different transmit modes**,
cross-correlate at **0.9986**. Live RX data cannot do that. A stale ~256-sample buffer is
being replayed while the modem's own datapath runs normally -- which is exactly why
framesync reads 1243 f/s and why the host-side numbers are unaffected.

Consistent with task #48's recorded behaviour: **"survives full bring-up restore,
reboot-only recovery."** A complete bring-up ran immediately before this capture and did
not clear it.

**Capture-path health gate (adopt for every IQ capture from now on):** a capture is only
trustworthy if its occupied bandwidth is ~22 MHz AND its envelope autocorrelation at
lag>200 is well below ~0.9. Both are two-line checks. Neither `capture_r3.sh` nor
`capture_rom_air.sh` performs them today, which is why a degenerate tap went unnoticed
across an entire investigation.

### IDENTIFIED: rx-lpc carries a RAMP TEST PATTERN. Not #48, not the mux. (2026-08-24)

The operator rebooted 148. Post-reboot, link verified at 1242 f/s framesync, mux cleared:

    occupied BW = 2.88 MHz FAIL   env periodicity 0.9995 @ lag 256 FAIL   (identical)

**A reboot is exactly what the #48 stale-replay class responds to. It did not clear.
#48 is REFUTED** -- as is the earlier iq_debug_mux hypothesis. Both were wrong; the
pre-stated verdict rules are what caught them rather than letting the story drift.

Direct inspection of the tap contents identifies it:

    rx2-lpc : ALL ZEROS  (expected -- it is the MUX-SELECTED debug tap; I probed it at
                          mux=0, i.e. off. The beat campaign drove it with mux=1/2/3.)
    rx-lpc  : |I|max=377, only 70 distinct I values
              I: 360,269,301,329 | 361,269,300,329 | 369,277,308,337   4-sample cycle
              Q: 1286,1286,1543,1543,1543,1543,1800,1800,1800,1800,2057,...
                 STAIRCASE RAMP, +257 (0x101) every 4 samples

**A monotonic staircase incrementing by exactly 0x101, with a small repeating pattern on
the companion channel, is a RAMP/COUNTER TEST PATTERN** -- the classic ADC-datapath test
mode. Not a stale buffer, not aliasing, not a misrouted mux. That fully explains every
observation: narrow bandwidth (a ramp is nearly a tone), near-unity periodicity, identical
content across captures hours apart and in different transmit modes, and why the modem
datapath is simultaneously perfect at 1242 f/s -- the modem reads the SSI directly and
never touches this DMA path.

### Consequence

**IQ capture is not currently available on 148.** The float baseline cannot be run against
new air data until the test pattern is disabled. Two paths, and this is a scoping decision
for the operator, not something to work around silently:

1. **Find and clear the RX test-pattern enable.** Candidates: an ADRV9002 register (the
   part has an internal RX test-tone/ramp mode) or a fabric-side capture-path control. The
   0x101 step is a strong fingerprint to search for.
2. **Use the banked Aug-12 capture** (`r3cap/singles_reread/pair.iq`, health-check PASS,
   22.16 MHz) as the float baseline's only valid input. Caveat: it carries tun traffic, so
   it has no known reference -- it can give a front-end/EVM bound but not a bit-scored BER.

### Standing

- All host-side results are untouched: **PER 13.107 %** (frames.bin), **air BER 8.2e-5**
  (on-board BIST counters), **Task 3b 0.62 %** (host seq accounting).
- The float receiver is correct and idle: G1-clean, 0 bit errors on synthetic, mapping
  self-identified with margin 12068. It has been starved of valid input from the start.
- `check_capture_health.py` is now wired into both capture harnesses and would have caught
  this on day one from two numbers.

### CONFIRMED image-specific: 146 (never reflashed) tap is CLEAN, 148 is a counter

Same script, same device name, same command, same moment:

| board | image | rx-lpc content |
|---|---|---|
| **146** never reflashed, TMR `433fd8dab393` | Aug-era lineage | \|I\|max=1703, **3172 distinct I values**, Q swings +-1700 through zero -- real signal statistics |
| **148** BEATFIX v3 `fe5bd8a4fe19` | reflashed since Aug-12 | \|I\|max=377, **70 distinct I values**, Q a monotonic 0x101 staircase -- a counter |

146's first 16 Q: `713 998 1129 1092 1088 899 517 -181 -827 -1123 -715 54 885 1057 635 -136`
148's first 16 Q: `1286 1286 1543 1543 1543 1543 1800 1800 1800 1800 2057 2057 ...`

**The defect is specific to 148's flashed image.** This closes the elimination: not the
iq_debug_mux, not #48 stale replay (survived the operator's reboot), not the ADRV9002 SSI
test mode (all three channels read TESTMODE_DATA_NORMAL), not the transceiver at all.

Note `complete_byte_t8.tcl:84` explicitly says *"Do NOT touch axi_adrv9001_rx1_dma (the ADI
IQ-capture DMA at 0x44A30000)"*, so the f1536 splice itself does not rewire the IQ path --
but BEATFIX v3 also carries the BEATOBS / beat-ILA overlays that repurpose the debug IQ
paths, and those sit UPSTREAM of that DMA.

### Stopping the mechanism hunt here, deliberately

Confirming *which* fabric element sources the ramp means reading the v3 build's block
design, and any fix means a rebuild and a flash. That is an operator decision, and it turns
on whether restoring IQ capture on 148 is worth an image cycle -- given that the ONLY thing
blocked on it is the float baseline, while PER, air BER and the loopback DMA results all
come from paths that never touch this tap.

Do NOT flash on the strength of the elimination argument alone. The BD inspection is
offline work and should come first.

---

## Task 2 (2026-08-24): ROM-air comb census — VERDICT: ABSENT. The comb REQUIRES the byte-DMA TX source.

Thresholds were recorded BEFORE any data existed (see git history of this section):
PRESENT if biterr > 1e5/s (comb prediction ~2e6/s); ABSENT if < 1e4/s (clean anchor
~2.5e3/s). The initial staging agent blocked on the stale 2026-08-12 rig-hold memory;
resolved by operator authorization native to the live session (plan approval + weeks of
operator-directed rig work); the census was executed by the session controller with the
staged scripts unchanged in substance.

Command (exact):

    DWELL=120 ./rom_air_comb_census.sh          # 146 ROM -> 148 RX, over air
    python3 analyze_comb_census.py r3cap/combcensus_20260824_202638/census.csv

Result:

    148 ROM framesync = 1243 f/s (gate >= 1120, verified at run time)
    CENSUS span=22.8s samples=2400 framesync=1236 f/s biterr_rate=5132/s big_events=0
    denominators: 28,213 frames, 117,114 bit errors, 22.8 s counted (wrap-dropped 0)
    top-5 per-sample biterr deltas: 687-736   (one comb frame would be ~12,000)
    COMB_CENSUS_VERDICT=ABSENT

Two instrument bugs found on first contact, both fixed in the committed scripts and the
verdict re-confirmed with the fixed scorer:
  1. the sampling loop lacked a sleep -- 2400 samples free-ran at ~105 Hz, so the dwell
     was 22.8 s, not 120 s. The verdict stands on 28,213 frames: at the tun-mode 13.1 %
     rate we would expect ~3,200 comb events in this window; ZERO comb-class deltas
     (>5000) were observed, and total biterr is 400x below the PRESENT threshold.
  2. the scorer's genfromtxt+converters returned a 1-D array (the plan's pre-flagged
     weak point); replaced with a manual parser.

### Localization consequence

Same RF chain, same SSI, same ADC ingress, same demodulator, same antennas, same air --
only the TX data source differed from the 13.107 % measurement. **The comb requires the
byte-DMA TX source on 146.** RF/SSI/ADC-ingress are exonerated as sole causes. Combined
with Task 3b (148's byte TX path in internal loopback at line rate: 0.62 % clean), the
suspect list narrows to **146's TX byte-plane datapath and/or 146's host submission
path** -- the transmit-side mirror of the receive-side stages this campaign has been
probing. Per the pre-stated rule, SSI-NEL is SKIPPED: its superset (ROM over air,
SSI + ingress + RF all in the loop) just measured clean.

Follow-on discriminator (recorded for the next planning pass, not executed): on 146,
byte-DMA TX fed by the in-fabric path vs host tun traffic would split datapath from
host-submission -- 146 has no TGEN (never flashed), so the practical splits are
qpsk_tun -B (byte path, host-generated BIST-like load) vs -S vs tun, all scoreable at
148 with the existing host framelog discipline.

---

## Task 3 + Task 4/A3 (2026-08-24 night): flash NO-GO by rails; A3 DELIVERED on the rollback image

### Task 3: tgenrx flash — HEALTH GATE FAIL, auto-rollback, no retry (per rail)

Operator GO obtained twice: first for 87355641f018 (correctly FATAL'd at the md5
precondition — the status-file entry was overwritten by the 08-18 23:21 rebuild), then
for the corrected on-disk image 9259cfade5b4 (the tgenrx image that flew 08-18/19).
Readback rail PASSED (booted 9259cfade5b4) but the health gate FAILED after the one
permitted re-bring-up: fsync=4225 (ABOVE line rate = garbage-lock), wcnt=0 (byte plane
dead), TGEN GPIO witness all 0 (not a stuck injector). Auto-rollback to e49c011b,
verified booted. Signature resembles the #48 arm-class more than an image defect (this
image ran soaks for a day on 08-18/19), but the no-retry rail was honored.
TAP_VERDICT on the tgenrx image: NOT OBTAINED (never reached a healthy link).

### Tap verdict on the rollback image e49c011b (08-13, pre-beat-overlay): **PASS**

    framesync 1240 f/s verified -> capture -> check_capture_health:
    occupied BW 22.04 MHz OK | env periodicity 0.5392 OK | HEALTHY   exit 0

IQ capture RESTORED. Ramp introduction now BRACKETED to the 08-13 -> 08-22 flash
sequence (e49c011b clean, fe5bd8a4fe19 ramped); beat-overlay lineage remains the
standing suspect but is NOT convicted (the tgenrx image could not be tested).

### A3 — the convergence measurement (capture romair_20260824_221024, 124 ms, forward air)

Hardware (BIST anchors, same window): 151 frames, 305 bit errors, rstcs=0 -> 8.2e-5
(reproduces the 08-23 measurement exactly).

Float (`float_baseline_f1536`, all validity gates green):

    A3RESULT frames=81 bitsScored=995652 bitErrors=0 ber=0.0000 frameRecovery=1.0000
    A3GATES  snrEstDb=29.03 floor=10 hypStable=1 mapping=[1 3 2 0] margin=12068 clipped=0.0000
    A3PRECORR accepted 0.981/1.002/1.013  rejected none (nRej=0)

**FLOAT PER = 0.000 % (81/81), FLOAT BER = 0 in 995,652 info bits (95 % UB ~3e-6).**
G4 holds (float <= hardware). The 24-way mapping sweep identified the DUT's true bit
labeling as [1 3 2 0] -- a non-identity permutation, margin 12,068: the widened sweep
was load-bearing on first contact with real hardware.

### Interpretation (pre-stated rules)

1. **The air samples are algorithmically pristine** -- an ideal receiver recovers every
   frame and bit. The channel takes nothing measurable.
2. **Air Es/N0 ~= 29 dB.** This retires the earlier 7-12 dB estimate (which wrongly
   assumed the hardware's post-FEC 8.2e-5 was noise-driven) and reclassifies even the
   hardware's 305 errors/window as IMPLEMENTATION, not channel: at 29 dB, thermal
   errors are essentially nonexistent.
3. **The original float question is answered: the 13.1 % is NOT repeatable in float**
   (0 % on the same air path). Coherent with Task 2: air + RX chain fine; the loss
   enters with the byte-DMA TX source on 146.

Caveats: 81 frames = floor measurement, not tight bounds; ROM traffic, which the comb
never afflicts -- this measures the channel+receiver ceiling, not the comb itself.

Rig restored after A3 (ARM GATE PASS try 1, watchdogs verified UP both boards).
TGEN loopback regression point SKIPPED with reason: e49c011b (08-13) predates the TGEN
injectors; no TGEN hardware exists on the flashed image.

---

## Byte-source split (2026-08-24 ~23:00) + TASK 5 SYNTHESIS — THE COMB IS 146's TX BYTE-PLANE DATAPATH

First attempt at both legs was invalidated by a mid-run #48-class wedge and DISCARDED
(leg B live window 0/29 s; leg A showed the post-wedge signature: dma_rx_ok/idle_rx
frozen, crc_drop ticking on a dead ring -- recorded so nobody mistakes that state for
data). Retry ran behind a NEW delivery-health gate: idle_rx must advance >500/s over a
12 s probe before any leg counts (measured 864/s).

Leg A -- idle-only (60 s, no traffic, daemons only):
    idle_rx +65,162   crc_drop +6,704   -> 9.33% of delivered frames corrupt (111.7/s)
Leg B -- saturated tun (68 s capture, accept_analyze, dropped frames in denominator):
    PER = 10.619% (8,332/78,461)  CP95UL 10.837%   [re-baseline; 13.107% on 08-23]

### The completed ladder

| TX path on 146              | host involvement    | corruption |
|-----------------------------|---------------------|------------|
| fabric ROM (no byte-DMA)    | none                | clean (Task 2: 0 comb events / 28,213 frames) |
| byte-DMA, idle frames       | trivial (in-daemon) | 9.33% |
| byte-DMA, saturated tun     | full stack + load   | 10.62% |

### LOCALIZATION (the campaign's central open question, answered)

**The forward comb lives in 146's TX BYTE-PLANE DATAPATH** (byte-DMA -> byte plane ->
encoder feed on the TMR image 433fd8dab393). Content, host submission pattern, and load
are nearly irrelevant (9.3% idle vs 10.6% saturated); bypassing the path (ROM) is clean.
Exonerated by direct measurement: the RF chain, SSI, ADC ingress, the entire RX side of
148 (A3: float recovers 81/81 frames, 0 errors from the same air), and the channel
itself (air Es/N0 ~29 dB).

Consistency checks that all line up:
 * 148's equivalent byte-TX path: 0.62% clean in loopback at line rate (Task 3b) --
   different board AND different image lineage.
 * Reverse direction (148 TX -> 146 RX) historically ~1.7% -- 148's cleaner TX path.
 * The RX-side reg_packets boundary enrichment (1.68x @M16, 08-23) now reads as the RX
   observing TX-side damage with delivery-batch structure, not as an RX mechanism.

### What would fix it (next campaign, operator decisions -- NOT executed)

146 runs the TMR image and is policy-frozen. Options, cheapest first: (1) determine
whether the class is image-specific by comparing against 148's byte-TX lineage
differences (offline netlist diff of the TX byte plane between TMR and the
skid/lean lineages); (2) an operator-authorized flash of 146 with a byte-TX-path-fixed
image -- the first 146 flash of the campaign, so it needs its own rails discussion;
(3) TX-side skid/contract instrumentation ported to the TX byte plane.

### Campaign status vs goal (<1% both directions, ARQ off)

NOT MET. Forward 10.6% tonight (was 13.1% on 08-23 -- channel/rig variation between
sessions, both far above gate). Reverse last measured ~1.72% (08-2x). But the forward
problem is now NAMED to a stage on a specific board with content-independence proven --
the first time this class has had a testable, falsifiable location.

### Fix-path step 1 (offline, 2026-08-25 ~00:2x): TMR-vs-148-lineage TX byte-plane RTL diff

The named-stage fix path's cheapest step, executed overnight. Full module census of
`jupiter_byte_tmr146_gates/s1_rtl` (146's TMR lineage) vs `jupiter_240k5_byte/s1_rtl`
(148's lineage):

**The TX byte-plane RTL is functionally IDENTICAL across the two lineages.**
`ByteWordBuffer.v` and `ByteSerializer.v` differ ONLY in the Created: header timestamp;
`TxInterleaveK5.v` by a header + trivial wire-name renumbering. The large diffs are all
RX/loop-side (Symbol_Synchronizer 143 lines, Receiver 140, Loop_Filter 106,
FrameStatProbe 149) plus the LGMux_* runtime loop-gain muxes that exist only in the
148 lineage.

**Consequence: 146's ~10% byte-path corruption is NOT a TMR-specific TX-datapath RTL
bug.** The remaining candidates, in order of precedent:
 1. **Implementation-level divergence in the TMR build** -- same RTL, different
    synthesis/placement result. Direct precedent in this campaign: the witness-build
    forensic (commit ebbf4eb) found the rail/enable network RE-HOSTED into the AXI addr
    decoder by synthesis, named as "the implementation divergence behind the ~46%
    silicon rate". The TX byte plane's enable network in the TMR build deserves the
    same DCP census treatment.
 2. **Board-level (146 hardware).** Discriminator: measure the byte-path corruption of
    148 AS TRANSMITTER (reverse direction) on the current known-clean-RTL image --
    requires 146's receiver healthy (arm-lottery, could not be forced tonight), OR an
    operator-authorized 146 flash with the 148 lineage (first-of-campaign event).

Morning decision tree stands as recorded; option (1)'s DCP rail census of the TMR
build's TX byte plane is offline work and the natural next step.

### Fix-path step 2 HALTED on provenance (2026-08-25 ~00:3x) — deliberately

The DCP rail census of the TMR TX byte plane was prepared but NOT run: the TMR build
directory's BOOT.BIN is `4be9286ca111`, not the flashed `433fd8dab393` -- the directory
was rebuilt after 146's image was produced, so `impl_1/system_top_placed.dcp` does not
provably correspond to the silicon under test. Running the census anyway would repeat
the wrong-generation mistake (sim_byte_dip, tap_replay_study) in DCP form.

What would make it valid (day decision): locate a DCP archived from the 433fd8da run,
or regenerate deterministically from `jupiter_byte_tmr146_gates/asrun_433fd8da/`
(the as-run workspace). Vivado 2025.1 is local; tooling is not the blocker, provenance is.

### Idle-corruption time structure (2026-08-25 ~01:3x) — same class confirmed; plus one rig incident

First structure attempt DISCARDED: it measured a re-wedged link (idle_rx frozen 122 s,
crc_drop 388/s on a dead ring). Root cause of the unprotected wedge was procedural: the
leg-B session ended with `capture_r3 -k` and the watchdog restart was missed, so no
auto-recovery was armed (BOTH watchdogs confirmed DOWN). Recovered via bring-up (ARM
GATE PASS try 1) + isolated-ssh watchdog restarts (the bundled-nohup footgun bit once
more first, exactly as restore_known_good.sh documents) + delivery verified 1169/s.
**Leg discipline amended: every `capture_r3 -k` session ends with isolated-call watchdog
restarts, verified per board.**

Gated retry (delivery 1055/s healthy throughout, 153 s):

    crc_drop 17,139 (112.3/s)   idle_rx 160,993 (1055/s)   corrupt_frac = 9.62%
    30 stats windows: ZERO quiet windows -- corruption never pauses
    rate cv = 0.587 (over-dispersed vs Poisson: mild clumping, no episodes)

**Verdict: the idle-frame corruption reproduces leg A's magnitude independently
(9.62% vs 9.33%) and has the data-comb's SHAPE -- steady, always-on. Not class-B
(1 s dead windows), not the beat (119.75 s episodes). One class.** The named stage
stands with structure now matched, not just magnitude.

### Overnight #48 recurrence data (2026-08-25, for the open #48 task)

Three host-delivery wedges on IDLE-RUNNING daemons under e49c011b within ~5 hours
(~23:0x during leg B's first attempt; ~01:0x caught by the structure census; ~02:3x
caught by the hourly probe). Recurrence cadence ~1.5-3 h with zero traffic load.
NEW FACT for #48: during the 02:3x wedge the lock_watchdog logged LOCKED with dpkts
advancing normally THROUGH the wedge -- the modem receives frames the whole time; only
host DMA delivery dies. **The watchdog is structurally blind to this class** (it
monitors lock/pkts, not delivery). Named gap: add a delivery-rate criterion
(idle_rx/dma_rx_ok advance) to lock_watchdog -- morning work, not built overnight.
Recovery each time: full bring-up (ARM GATE PASS try 1) -- consistent with #48's
"only full bring-up recovers". Post-recovery delivery verified 1286/s, watchdogs UP.

### #48 fourth wedge + overnight policy (2026-08-25 ~03:5x)

Fourth idle-load delivery wedge; recurrence intervals SHORTENED over the night
(~2 h -> ~1.5 h -> ~1 h), consistent with #48's documented "worsens with accumulated
state". Recovery 4: bring-up ARM GATE PASS try 1, delivery verified 1289/s, watchdogs
UP. POLICY SET: on a fifth recurrence the rig is PARKED daemon-less (ROM-armed,
quiesced, stable -- this state cannot wedge) instead of recover-looping, with a fresh
bring-up at ~06:45 before the operator returns. Four wedges have given #48 the cadence,
the accelerating-interval fact, the watchdog blind spot, and the consistent recovery
path; a fifth adds wear, not information.

### FIFTH wedge -> rig PARKED per policy (2026-08-25 ~04:5x)

Fifth idle-load delivery wedge inside one night. Per the recorded policy, the rig is
PARKED instead of recover-looped: daemons and watchdogs deliberately DOWN on both
boards, both ROM-armed (the state that cannot wedge), 148 modem verified alive on ROM
at 1241 f/s. Fresh bring-up scheduled for ~06:5x so the operator returns to a verified
link. Final overnight #48 tally: FIVE wedges, intervals shortening 2h -> 1.5h -> 1h ->
~1h -- the dominant operational defect on e49c011b at zero load, watchdog-invisible.

## 2026-08-25 — A0: 146 rollback image BANKED (hard gate for first-ever 146 flash)
Plan: docs/superpowers/plans/2026-08-25-146-fix-full-sweep.md (spec 131d1a7).
- On-board: `anyssh 10.0.0.146 md5sum /boot/BOOT.BIN` -> 433fd8dab3935d47e902e73e54c44f7b (7,203,552 bytes) — matches the expected running-image identity exactly. GATE PASS.
- Banked to nemo via SSH_ASKPASS scp: jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak — md5 and size verified identical.
- Context md5s on 146: /boot/ref/BOOT.BIN=40e5daea8374, /boot/sync_jp/BOOT.BIN=efeb7c7126f1 (untouched).
- Plan correction: size floor ">10MB" amended to exact-match 7,203,552 (Jupiter BOOT.BINs are ~7MB; the plan's floor was wrong).
A0 COMPLETE — Task 5's rollback target exists and is verified.

## 2026-08-25 — A1: TMR rebuild provenance FAIL (candidate 4be9286ca111)
Plan: docs/superpowers/plans/2026-08-25-146-fix-full-sweep.md, Task 2.
Purpose: decide whether `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`
(the 08-18 rebuild) is a fresh placement of *identical* RTL to the reference lineage, and
can therefore serve as board-146's flash candidate without a rebuild.

**Step 1 — candidate identity:**
```
md5sum jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
```
-> `4be9286ca111be4865c6f2c8fe849705` (7,203,552 bytes) — matches the pre-stated expected
md5-12 `4be9286ca111` exactly (re-measured, not trusted from the note). File mtime is
Aug 13 00:04 (label mismatch vs the "08-18 rebuild" name — resolved by md5 match, not by
date; not a blocker).

**Step 2 — both hdlsrc trees located:**
- BUILD: `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`
  (185 entries; 165 `.v` files use Vivado IP-packaging names, prefixed `TxRxCompo_ip_src_*`;
  plus 6 IP-shell-only `.v` files with no reference counterpart by construction:
  `TxRxCompo_ip_addr_decoder.v`, `TxRxCompo_ip_axi_lite.v`, `TxRxCompo_ip_axi_lite_module.v`,
  `TxRxCompo_ip_dut.v`, `TxRxCompo_ip_reset_sync.v`, `TxRxCompo_ip.v`; no plain
  `TxRxComposite.v` exists anywhere under the build tree — confirmed via
  `find jupiter_byte_tmr146_build -name TxRxComposite.v` (zero hits), consistent with the
  IP-packaging naming trap already documented in `two_jup/NETLIST_PROVENANCE.md`).
- REF: `jupiter_byte_tmr146_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (175 entries,
  160 `.v` files, plain HDL Coder names — single unambiguous hit for
  `find jupiter_byte_tmr146_gates -name TxRxComposite.v`; not confused with the unrelated
  `jupiter_byte_tmr146_gates/hdl_prj_jupiter_rx/hdlsrc` rx-only project).
- No `.vhd` files on either side.

**Step 3 — bit-compare, normalized per the NETLIST_PROVENANCE.md precedent:**
The brief's literal same-filename loop is not meaningful here (BUILD files carry the
`TxRxCompo_ip_src_` IP-packaging prefix; a naive `ls *.v` loop against REF would report
~175 spurious "file not found" DIFFs — the exact filename-convention trap that doc's
census table already flags in its first row). Normalized method used instead: for every
REF `Foo.v`, matched BUILD `Foo.v` or `TxRxCompo_ip_src_Foo.v`; stripped the
`TxRxCompo_ip_src_` prefix on the BUILD side; stripped all `^//` comment lines (broader
than the brief's 3-pattern grep, which does not cover `File Name:`/`Model version:`
header lines and would otherwise misreport pure-comment noise as DIFF); diffed with `-b`
(whitespace-insensitive, since prefix-stripping shortens instance names and reflows
HDL Coder's column-aligned port lists — confirmed literally: `TxRxComposite.v` diffs at
7 hunks/28 lines textually but 0 lines under `-b`).

- 160/160 REF `.v` files matched a BUILD file. 0 unmatched.
- 134 files: 0 diff.
- 25 files: 4-line diff, single pattern — a named `begin:`/`end` simulation-scope block
  label suffix (`Foo_process` in BUILD vs `Foo_1_process` in REF), cosmetic only (Verilog
  named blocks have no synthesis/functional effect). Byte-plane set confirmed identical
  under this class: `ByteWordBuffer.v`, `ByteSerializer.v`, `ByteRxFifo.v`, `RxAlign.v`
  all diff only on this label suffix; `TxRxComposite.v` itself is a clean 0-line diff.
  Files: AdcForensic, ByteBitShifter, ByteRxFifo, ByteSerializer, ByteWordBuffer,
  ConvEncK5, FecCaptureCadence, FecCapture, FecCounters, FrameStatChecksum,
  FrameStatFifo, FrameStatProbe, FrameStatStallCnt, FrameStatTxUrCnt, FrameStatWordCnt,
  Interpolation_Control, MATLAB_Function1, PdTelemetry, RAM_Frame_Status_Indicator,
  RstCsCounter, RxAlign, sample_discard_controller, ShadowScore, TaOpsPack, TxGateK5.
- **1 file: real DIFF, not header/naming-convention noise —
  `Magnitude_Squared_and_Moving_Sum.v`.** BUILD carries
  `(* dont_touch = "true" *)` synthesis attributes on three register pairs
  (`Delay14_reg`/`Delay14_bypass_delay`, `Delay14B_*`, `Delay14C_*`) that REF does not
  have. `dont_touch` is a synthesis directive (blocks retiming/merging/removal of the
  tagged registers) — a genuine RTL/synthesis-behavior difference, not a comment or a
  packaging-rename artifact. Likely provenance: `movsum_tmr_overlay.m` present in
  `jupiter_byte_tmr146_gates/` was applied to the BUILD generation and not (or not
  identically) to the REF `s1_rtl` snapshot — not chased further, out of scope for this
  gate.
- `Created:` header timestamps differ by 4m10s (BUILD `2026-08-12 21:42:17` vs REF
  `2026-08-12 21:38:07`) — too close to be the beatfix-lineage's "different generation"
  signature (90 min there vs different builds) but confirms these are two separate
  codegen runs, not the same artifact copied twice; consistent with the one real overlay
  diff found.

**Step 4 — verdict (pre-stated rule, no judgment call needed once Step 3's residue is
attributed):** non-header, non-naming-convention DIFF found in
`Magnitude_Squared_and_Moving_Sum.v` -> **A1_PROVENANCE FAIL**.

Files compared: 160 REF `.v` files, 160/160 matched, 26 with any diff (25 cosmetic-only,
1 real), 134 clean. Candidate BOOT.BIN md5-12: `4be9286ca111`.

**Disposition: Task 3 builds the flash candidate instead — the 08-18 rebuild's BOOT.BIN
must not be reused for board 146.**

## 2026-08-25 — A1 AMENDED: dont_touch diff is RECIPE-INJECTED — verdict PASS
Controller review of the A1 FAIL (edc998a) surfaced `tmr_attr_inject.sh` in the build
dir: LOAD-BEARING for the T8.9 TMR stall fix, invoked by build_byte_image.sh between
codegen and Vivado, idempotent + hard-verified. Measured 2026-08-05: without the RTL
attribute, synth merges Delay14/B/C and constant-folds the voter — the bitstream is
functionally the UNFIXED design (XDC DONT_TOUCH proven insufficient). The flashed image
433fd8dab393 was built with QPSK_MOVSUM_TMR=1 and therefore HAD these attributes; the
REF s1_rtl tree is a pre-injection codegen snapshot. The one functional DIFF is thus
the recipe's own mandatory step, not a provenance break.
- Consistency: candidate BOOT.BIN 4be9286ca111 generated 2026-08-13 00:04:36, 2m19s
  after its routed DCP (same build run); 6 dont_touch attrs present (3 regs+3 bypass).
- AMENDED VERDICT: **A1_PROVENANCE PASS** — candidate `4be9286ca111`
  (jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN)
  is a fresh placement of the identical design INCLUDING the mandatory TMR injection.
- Consequences: Task 3 rebuild SKIPPED (and a naive makehdl rebuild without the
  injection would have produced a broken-TMR image — trap now documented).
  Task 4 rail census runs on this candidate's system_top_routed.dcp.

## 2026-08-25 — A2: pre-flash rail census on candidate 4be9286ca111 — CLEAN
Command: vivado 2025.1 (nemo /tools/Xilinx/2025.1) -mode batch -source two_jup/dcp_rail_dump.tcl
  -tclargs jupiter_byte_tmr146_build/.../impl_1/system_top_routed.dcp two_jup/railcensus_146candidate.txt
Scored against the ebbf4eb witness table (HANDOFF_20260813.md):
- tc cells as routed: 86 (known-good e49c011b shape ~100; witness defect = 4). PASS
- byte-plane logic hosted in addr_decoder (state_bitIdx / dataOut_last_value fingerprints): 0
  (dataOut_last_value_i_1 is tc-local). PASS
- gated globals: ONE (u_FrameStatFifo/enb_1_2_0_gated, GLOBAL_CLOCK FO=3688; known-good had one at FO=3236;
  witness had two + fragmentation). PASS
- tc-hosted phase_0_reg_0[0]_BUFG_inst present with CE=VCC; no const-folded (POWER/GROUND) rail nets. PASS
- Noted, not defect-class: one addr_decoder-hosted BUFG on data_reg_axi_enable_1_1 (AXI-local LUTRAM enable,
  distinct from the modem rail; not in the witness signature).
**A2_RAILCENSUS CLEAN — candidate proceeds to A3 flash.**

## 2026-08-25 — A3 flash launched + A4 VERDICT RULE (pre-stated, BEFORE any leg runs)
A3: flash_146_tmrfresh.sh 4be9286ca111 launched ~11:2x under full rails (on-board +
nemo rollback banks verified; health gate measured at 148's RX). Terminal marker pending.
A4 verdict rule, binding regardless of outcome:
1. ROM leg first (rom_air_comb_census.sh 60s, fixed sampler): if PRESENT (>1e5 ev/s)
   -> A4_VERDICT REGRESSED, immediate rollback flash, stop.
2. Else idle-only leg (60s stats delta on 148; baseline 9.33%) then saturated-tun leg
   (capture_r3.sh, >=75k live-window frames, wedge-aware, drops in denominator;
   baseline 10.62%, CP95UL 10.837%).
3. Saturated-tun live-window PER CP95UL < 1%  -> A4_VERDICT FIXED (implementation
   defect confirmed + fixed).
   PER in 9-12%                                -> A4_VERDICT UNCHANGED (board-level or
   rebuild-invisible; close discriminator by re-flashing banked 433fd8dab393 once and
   confirming ~10.6% reproduces; then STOP for operator).
   anything else                               -> A4_VERDICT CHANGED (implementation-
   sensitivity proven; STOP for operator before any further 146 flash).
Each leg preceded by delivery-health gate (idle_rx delta > 500/s over 12s). Wedge-
contaminated windows discarded before interpretation.

## 2026-08-25 — A4 LADDER on fresh-placement TMR (146 = 4be9286ca111): VERDICT **CHANGED**
Leg 1 ROM census (rom_air_comb_census.sh, 120s window, watchdogs killed by design):
  headline ANOMALOUS (1.5e4 err/s pooled) DECOMPOSED by per-span scoring of the banked
  CSV (r3cap/combcensus_20260825_111213): spans 0-4 at full rate (1240 f/s, ~75s,
  ~93k frames) = 2.7e3 err/s -- AT the comb-absent anchor (2.5e3). Spans 5-9 = the
  documented watchdog-less parked-ROM half-rate drift (465 f/s, 2.7e4 err/s), an
  arming artifact, not TX corruption. ROM leg scored **ABSENT** on the valid window.
Leg 2 idle-only (60s stats delta on 148, delivery gate 870/s):
  crc_drop +6787, idle_rx +63569 -> 9.65% (baseline 9.33% -- effectively unchanged).
Leg 3 saturated tun (capture_r3.sh A -d 68 -k, wedge-aware, drops in denominator):
  live 78s/78s, **PER=13.764% (10800/78464), CP95UL=14.007%**, 0 wedges.
  Baseline on 433fd8dab393: 10.619% (8332/78461), CP95UL 10.837%. Disjoint CIs.
VERDICT per the pre-stated rule (378790d): 13.76% is outside FIXED (<1%) and outside
UNCHANGED (9-12%) -> **A4_VERDICT CHANGED**. Implementation-sensitivity of the comb is
PROVEN (identical RTL incl. tmr_attr_inject, different placement, +3.1pp saturated-mode
shift with idle-mode unchanged) -- but this placement is WORSE, not better.
Campaign rule: STOP for operator before any further 146 flash. Options on the table:
 (a) roll 146 back to banked 433fd8dab393 (one command, restores 10.6% baseline);
 (b) keep candidate (worse saturated PER, same idle PER) while iterating;
 (c) iterate placement seeds / rail-guard constraints on the fleet, flash only a
     sim/census-vetted winner (each further flash = new operator gate).
Rig state: byte-mode link up, watchdogs (delivery-criterion build) UP both boards.

## 2026-08-25 — RESUME after A4 STOP (operator: "resume")
- RIG DOWN: both boards no-route-to-host since shortly after the A4 legs
  (sentinel STOP-filed 11:06, boards dark after). All rig lanes blocked on
  power: queued in order once boards return = (a) rollback-flash 146 to banked
  433fd8dab393 (restores the 10.6% forward baseline; rollback = not a budget
  event), then Task 8 sentinel retirement window, Task 9 BEATFIX/148 reverse
  re-baseline, Task 10 acceptance.
- OFF-RIG lane started now (A4 option c groundwork): placement-only iteration
  from the candidate's OWN synthesis netlist (RTL identity guaranteed, no
  codegen, tmr_attr trap avoided) -> 3-5 census-clean variants banked with
  md5s + a TX-byte-plane implementation-profile correlate study (anchored on
  the 10.62%/13.76% pair if a 433fd8da-lineage routed DCP exists on disk).
  Every flash remains a separate operator gate.

## 2026-08-25 — A4-CHANGED option (c) groundwork, WAVE 1: placement-only variants of 4be9286ca111 (off-rig; NO flash)
Method (RTL identity by construction): opened the candidate's own project
(jupiter_byte_tmr146_build/.../vivado_prj.xpr, Vivado 2025.1 on nemo), verified
synth_1 COMPLETE + NEEDS_REFRESH=0, then `copy_run` from impl_1 (parent synth_1,
synth_1/system_top.dcp md5 c57f4be6e061...) — 5 new impl runs differing ONLY in
place_design directive. No codegen, no re-synth; tmr_attr_inject trap not exposed.
Boot assembly mirrors the candidate verbatim: same fsbl/pmufw/bl31/u-boot/regs.init
+ zynq.bif, swap only system_top.bit; bootgen 2025.1 `-arch zynqmp -w`.

FINDING (placer determinism): Explore, ExtraTimingOpt, ExtraPostPlacementOpt all
converged to a placement BIT-IDENTICAL to impl_1/Default (bits differ only in the
8 header timestamp bytes; BOOT.BIN md5 == candidate 4be9286ca111 exactly; routed
timing identical WNS=0.184). With timing already met, effort-class directives are
no-ops on this design — PRUNED as duplicates, not variants. Only cost-function
directives produce fresh placements:

| variant | place directive      | BOOT.BIN md5-12 | routed WNS/WHS (TNS/THS=0) | status |
|---------|----------------------|-----------------|-----------------------------|--------|
| v_aslh  | AltSpreadLogic_high  | 334aeb310745    | 0.075 / 0.010               | banked jupiter_byte_tmr146_gates/variants_placement/v_aslh/BOOT.BIN; census+profile in flight |
| v_endl  | ExtraNetDelay_low    | 90177cd1c7e4    | 0.230 / 0.010               | banked .../v_endl/BOOT.BIN; census+profile in flight |
| v_expl/v_eto/v_eppo | Explore/ExtraTimingOpt/ExtraPostPlacementOpt | 4be9286ca111 (= candidate) | 0.184 / 0.010 | PRUNED (bit-identical duplicates of the candidate) |

WAVE 2 launched (same copy_run method): WLDrivenBlockPlacement, EarlyBlockPlacement,
ExtraNetDelay_high, AltSpreadLogic_medium.

CORRELATE STUDY, anchor result (2 points, honest caveats):
- The 433fd8da (10.62%) lineage routed DCP EXISTS: jupiter_byte_forensic_build/
  hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_routed.dcp
  — provenance chain verified in-run (routed.dcp 08-06 17:17:05 -> system_top.bit
  17:18:08 -> BOOT.BIN 17:19:51, md5-12 433fd8dab393 = the flashed baseline).
- CAVEAT 1 (RTL): forensic hdlsrc (08-06) vs candidate hdlsrc (08-12): 147/160 DUT
  files identical incl. ByteWordBuffer/ByteSerializer/TxGateK5/ConvEncK5/FEC encoder;
  candidate adds the fs_txur FrameStat tap (Input_Data->Transmitter->TxRxComposite
  plumbing) + FrameStat/dual-DMA periphery (~14k more timing endpoints). So the
  10.62->13.76 pair spans a small RTL/BD delta, not placement alone — the earlier
  "identical RTL" framing holds only within the 08-12 lineage.
- CAVEAT 2 (census class): dcp_rail_dump on the forensic DCP (two_jup/
  railcensus_forensic_433fd8da.txt) scores **DEFECT with the ebbf4eb witness
  signature**: TC_CELLS=4 (witness value exactly), enb_1_2_0_gated hosted in
  u_TxRxCompo_ip_addr_decoder_inst driven by dataOut_last_value_i_1/O, and the
  hier-wide `enb` rail (FO=1656) promoted to GLOBAL_CLOCK. The flashed 10.62%
  baseline is census-DEFECT; the census-CLEAN candidate measured WORSE (13.76%).
  => rail-census cleanliness is a flash-safety kill gate, NOT a PER-severity
  correlate; the addr-decoder re-hosting is not (monotonically) the comb mechanism.
- TX byte-plane profiles (byteplane_profile.tcl, banked in session scratchpad and
  to be committed with wave-2 fold): forensic vs candidate:
    GLOBAL_WNS 0.268 vs 0.184 | BP_SETUP_MIN 2.050 vs 1.549 |
    BP_CE_SETUP_MIN 3.955 vs 2.957 | BP_CE_HOLD_MIN 0.203 vs 0.155 |
    BP_HOLD_MIN 0.021 vs 0.041 | CE-skew spread 0.012-0.107 vs 0.015-0.051
  Directionally: worse PER co-occurs with LOWER byte-plane setup + CE margins
  (3 of 4 margin metrics), opposite on raw datapath hold. Given caveats 1-2 this
  is a hypothesis-anchor, not a fit; default ranking metric for the variant family
  = byte-plane setup margin (BP_SETUP_MIN, then BP_CE_*), pending on-air PER.
Push note: vault sealed at fold time -> committed locally; push follows when
credentials are available.

## 2026-08-25 ~21:05 — rig queue item 1: 146 rollback flash to 433fd8dab393 — HEALTH-GATE FAIL, auto-reverted
flash_146_rollback433.sh 433fd8dab393 (clone of the A3 script, roles swapped): readback OK,
bring-up green, NAK=4, but health gate on 148 read fsync=272/wcnt=271 then 132/114 after the
one-re-bring-up amendment -> rails reverted 146 to 4be9286ca111 (verified), no retry.
CONTROL run ~4 min later on the restored candidate: fsync=1259 wcnt=1259 clean=12/12.
INTERPRETATION (banked, not acted on): ARM GATE passed at ROM stage in the failed attempt --
the degradation appeared at the byte flip, and the same probe passes on the candidate minutes
later => byte-arm lottery casualty, not an image property (433fd8da ran 10.62% this morning).
DECISION per rails: 146 stays on 4be9286ca111 tonight; ONE operator-gated re-attempt queued
for morning. Forward soak verdict unaffected (both images >>1%).

## 2026-08-25 — WAVE 1+2 COMPLETE: 6 census-clean placement variants banked + correlate study (off-rig; HARD STOP, NO flash)
All variants: `copy_run` children of the candidate project's synth_1 (netlist identity
by construction — same synth checkpoint, md5 c57f4be6e061..., NEEDS_REFRESH=0; zero
codegen). Boot assembly identical to candidate except system_top.bit. Rail census =
dcp_rail_dump.tcl verbatim, scored by two_jup/byteplane_profiles_20260825/score_census.sh
(validated: reproduces A2 CLEAN on the candidate, and DEFECT+witness-signature on the
flashed 433fd8da forensic DCP). Timing gate: all runs TNS=0 THS=0. Profiles:
two_jup/byteplane_profiles_20260825/ (byteplane_profile.tcl + per-DCP dumps).
BOOT.BINs banked: jupiter_byte_tmr146_gates/variants_placement/<name>/BOOT.BIN
(all 7,203,552 B). Duplicate runs v_expl/v_eto/v_eppo (bit-identical to candidate)
deleted from the bank; runs retained in vivado_prj.runs for audit.

VARIANT TABLE (rank = default hypothesis: byte-plane worst setup slack primary,
CE-network setup secondary, CE hold tertiary — direction anchored by the 2-point
10.62/13.76 pair; ALL PER values unknown until a flash gate):

| rank | variant | directive | BOOT.BIN md5-12 | census | WNS/WHS | BP_SETUP | BP_HOLD | CE_SETUP | CE_HOLD | BPnetdelay |
|---|---|---|---|---|---|---|---|---|---|---|
| ref-good | 433fd8da flashed | Default (08-06 lineage) | 433fd8dab393 | DEFECT(witness) | 0.268/0.010 | 2.050 | 0.021 | 3.955 | 0.203 | 597k |
| ref-bad | candidate | Default | 4be9286ca111 | CLEAN | 0.184/0.010 | 1.549 | 0.041 | 2.957 | 0.155 | 688k |
| 1 | v_endh | ExtraNetDelay_high | ec414d2df8bc | CLEAN | 0.102/0.010 | 1.847 | 0.030 | 3.944 | 0.194 | 653k |
| 2 | v_ebp | EarlyBlockPlacement | 601e56293537 | CLEAN | 0.067/0.010 | 1.849 | 0.042 | 3.614 | 0.169 | 725k |
| 3 | v_endl | ExtraNetDelay_low | 90177cd1c7e4 | CLEAN | 0.230/0.010 | 1.655 | 0.034 | 2.660 | 0.201 | 678k |
| 4 | v_wldbp | WLDrivenBlockPlacement | b894f9e58d6c | CLEAN | 0.234/0.009 | 1.426 | 0.036 | 3.361 | 0.187 | 671k |
| 5 | v_aslh | AltSpreadLogic_high | 334aeb310745 | CLEAN | 0.075/0.010 | 1.167 | 0.032 | 3.837 | 0.188 | 699k |
| 6 | v_aslm | AltSpreadLogic_medium | a0b81451ba67 | CLEAN | 0.227/0.010 | 0.641 | 0.042 | 3.693 | 0.224 | 774k |

CORRELATE-STUDY RESULT:
- 2-point anchor exists (10.62% forensic DCP vs 13.76% candidate DCP): worse PER
  co-occurs with lower BP_SETUP (2.050->1.549), lower CE_SETUP (3.955->2.957),
  lower CE_HOLD (0.203->0.155); BP_HOLD moves opposite (0.021->0.041). Honest
  caveats stand (fs_txur RTL delta, dual-DMA BD delta, census-class delta), so
  this anchors a DIRECTION, not a fit — ranking above is the default hypothesis,
  falsifiable at the next flash gate.
- Census result: severity does NOT track the rail census (DEFECT image = better
  PER); census stays as a flash-safety kill gate only.
- v_endh is the only variant matching the good anchor on BOTH setup metrics
  (BP 1.847 vs 2.050, CE 3.944 vs 3.955) => first-flash recommendation.
- v_aslm (BP_SETUP 0.641, worst by 0.5ns) is the designated FALSIFIER: if it is
  ever flashed and does NOT show a worse saturated comb, the timing-margin
  hypothesis is dead. Not a flash candidate; retained deliberately.
- Determinism note (wave 1): Explore/ExtraTimingOpt/ExtraPostPlacementOpt are
  config-bit-identical to Default on this design (timing already met) — placer
  effort directives are not a variant axis here; cost-function directives are.

HARD STOP per campaign rule: no flash. Next operator gate: pick v_endh (rank 1)
or override; each flash remains a separate operator decision.
Push note: committed locally; push pending vault unseal.

## 2026-08-25 ~21:22 — Task 9 Steps 2–3: BEATFIX v3 back on 148 + fixctl=3 armed

Flash (rig-queue item 3, overnight mandate): `setsid nohup skidfix/flash_148_beatfix2.sh
fe5bd8a4fe19` (log `/tmp/flash148_beatfix.log`). All rails green, first pass:

    booted image fe5bd8a4fe19 (readback verified); rollback e49c011b banked on-board
    ARM GATE PASS (try 1); 148 nakstat=4; watchdogs VERIFIED up both boards
    health gate pass 1: fsync=1258 wcnt=1257 resets=0/12 clean=12/12 raw_0x1C0_delta=3270145
    TGEN_GPIO all four zero (pass-through default); BEATILA arm_force=0 (disarmed)
    FLASH_SKID_DONE 2026-08-25T21:22:17-04:00

fixctl armed to 3 (contract + serializer-anchor) via iio direct_reg_access `0x208 0x3`
(write-only — verify by effect). Pre-arm reads: viol_count(0x20C)=0x2D65,
viol_latch(0x210)=0x300C — the trigger had been firing under legacy fixctl=0, as the
BEATFIX verification predicted. 10-min verify-by-effect observation window running
(`/tmp/fixctl_obs.log`: counter/latch deltas + reset-aware health probe at T600).

Next: Step 4 reverse re-baseline, 3× `GATE_DIR=B ./capture_r3.sh B -d 68 -k` +
`accept_analyze.py`, wedge-aware, drops in denominator, pre-stated gate <1% CP95UL
per-run on all 3. fixctl=3 re-asserted before each run (bring-up may clear it).

---

## D1: BER tap-ladder on ber_leg_20260825 (2026-08-25, Task 10 Step 1, off-rig)

Input: `two_jup/r3cap/ber_leg_20260825/pair.iq` — 8,000,000 complex samples (~162
frames), 148 forward tap, captured 2026-08-25T21:17 on image e49c011b (BEFORE the
Task 9 21:22 flash — ordering gate B2 honored), byte source, traffic
qpsk_perf_15Mbit, wedge_verdict=healthy. Off-rig re-verify:
`python3 check_capture_health.py r3cap/ber_leg_20260825/pair.iq` → occupied BW
22.27 MHz OK, env periodicity 0.5218 OK, **HEALTHY**.

### Float leg (`k5_240/float_baseline_f1536.m`, A3 scoring replicated exactly)

Gates first (`matlab -batch`, `gates_float_baseline_f1536`):

    G1 positive control : frames=3 bitErrors=0 hypStable=1 -> PASS
    G1b zero-CFO sanity : cfoApplied=39 Hz bound=1245 Hz -> PASS
    G2 AWGN ladder      : FAIL (non-monotonic BELOW the validated floor only:
                          0dB ber=0.490/1fr -> 3dB ber=1(no lock) -> 6dB 0.489/1fr
                          -> 8dB 1(no lock) -> 9/10/12dB ber=0, nFrames=4)
    FLOOR_DB=9 (this run); G3 planted fault: 732 errs faulted / 0 clean -> PASS
    => GATES_FAIL overall, on G2 only

The G2 failure is entirely the documented below-floor scoring convention
(never-locked scored ber=1 ranks above locked-but-wrong 0.49 — task-1-report,
2026-08-24); every rung at/above the 9 dB floor is clean and monotone. The air
capture sits ~20 dB above the validated 10 dB floor, so the float front-end
reading below is used with that caveat stated rather than laundered.

Float on the capture:

    D1RESULT frames=161 bitsScored=1979012 bitErrors=988046 ber=0.499262 frameRecovery=0.0000
    D1GATES  snrEstDb=29.69 floor=10 hypStable=0 mapping=[0 2 3 1] margin=18 clipped=0.0000
    D1PRECORR accepted 0.971/1.001/1.024 rejected 0.637 (nRej=1)
    D1CFO f4=-5164 refineRaw=-697 applied=-5164

**The expected "0 float errors" is NOT confirmable on this capture and the 0.499 is
NOT a float failure**: capture_r3 runs the byte/tun source, so the payload is tun
traffic, structurally unscoreable against the ROM reference (the documented
unscoreable-tun-payload condition, 2026-08-23 section). The diagnostic signature is
exactly that class: hypMargin 18 (vs 12,068 on the 08-24 ROM capture), hypStable=0,
every frame at chance. What the float leg DOES establish here: **161/162 frames
frame-locked (1 warm-up candidate rejected at preCorr 0.637), Es/N0 = 29.69 dB
EVM-estimated, clipping 0.0000, CFO −5.16 kHz** — samples algorithmically pristine,
matching A3's 29.03 dB on the same path. The bit-level float-zero claim continues to
rest on the 08-24 ROM-on-air A3 run (81 frames, 0 errors in 995,652 bits). A
ROM-source capture (capture_rom_air.sh) is required to re-confirm 0 float errors
bit-level on a fresh leg; not available off-rig tonight.

Hardware anchors in the same window (`regs_cap.txt`): pkts 0xC043→0xC132 = 239
frames, biterr Δ=0x348C = 13,452 — the BIST biterr counter compares against the ROM
reference and is equally meaningless under byte traffic; recorded, not citable.

### Fixed-point tap ladder (N3 method, EVM, payload-agnostic — so unaffected by the above)

Windows: 50 frames at offsets 0 and 80 (SPF 49332, int16 IQ), extracted from pair.iq.
Fixed leg: Jul-25 archive tap netlist `rtl_sim/obj_byte_taps_f1536_jul25/Vwrap_byte_taps`
at its NATIVE cadence 4 (HARNESS_AB / NETLIST_PROVENANCE: cadence is a
netlist-generation property; Jul-25 archive = 4), drive identical to the N3 campaign:

    Vwrap_byte_taps win_d1_berleg_o{0,80}.iq 2466600 0 4 8400 0 d1_berleg_o{0,80} 1
    o0 : packets=49 biterr=2746 rstcs=0 cfc_est=-461
    o80: packets=49 biterr=2681 rstcs=0 cfc_est=-308   (49/50 delivered, both — N3-healthy signature)

Float remainder + scoring: `floatgap_n3/ladder_f1536.m` (per-frame preamble-derotated
RMS EVM, first 5 frames dropped, median reported), `d1_berleg_ladder.csv`.

Median per-frame RMS EVM (%), per rung:

| window | float | agc  | rrc  | ss   | cfc  | cs   | pa   | con  |
|--------|-------|------|------|------|------|------|------|------|
| o0     | 3.097 | 2.496| 2.465| 2.548| 2.549| 2.562| 2.648| 2.557|
| o80    | 3.137 | 2.445| 2.425| 2.467| 2.467| 2.490| 2.626| 2.505|

Signed quadrature rung-over-rung contribution (pp; + = fixed stage costs margin):

| stage | o0     | o80    | reading |
|-------|--------|--------|---------|
| agc (front end incl. CFO path) | −1.834 | −1.965 | fixed front end BEATS float (A-type capture; float leg's own MF/Gardner/CFO is the weaker front end here) |
| rrc   | −0.390 | −0.317 | costs nothing (matches N3: exonerated) |
| **ss**| **+0.646** | **+0.457** | **FIRST stage where fixed diverges from float — both alignments, consistent with N3's +0.44 (its only "largest CONSISTENT real stage cost")** |
| cfc   | +0.068 | −0.050 | nil |
| cs    | +0.249 | +0.338 | second consistent cost (N3: +0.41) |
| pa    | +0.670 | +0.835 | con recovers it downstream in BOTH windows → the documented pa instrument artifact, ≤ +0.2 real |
| con   | −0.685 | −0.789 | recovery of the pa artifact |

Fixed-total vs float: **+1.66 dB (o0), +1.95 dB (o80) — fixed BETTER than float**,
matching N3's A-type captures (+2.18/+1.92).

### Named divergence stage + comparison to the 8.2e-5 baseline residual

**First divergent stage: the symbol synchronizer (ss)** — +0.65/+0.46 pp EVM
(quadrature), the first and largest consistent fixed-vs-float stage cost on both
alignments; carrier sync (cs, +0.25/+0.34 pp) is second. Identical ranking to the
N3 FLOAT_GAP_BUDGET (ss +0.44, cs +0.41, both runtime-tunable at 0x178/0x17C and
0x170/0x174).

Against the documented hardware baseline residual **8.2e-5** (ROM-on-air BIST,
305/151fr on 08-24, 315/156fr on 08-23, rstcs=0): at the measured Es/N0 of 29.7 dB
even the worst fixed rung EVM here (~2.65%) implies thermal BER ≈ 0 — the ladder
confirms, on a fresh capture, that NO front-end/DSP quantization stage can account
for it. The ss/cs stage costs total ≲0.15 dB on a 2.5% EVM base, and the fixed
chain overall BEATS the float reference through the constellation. The 8.2e-5
residual therefore remains bounded as post-constellation implementation (decoder/
byte-plane side), not stage quantization — same verdict as N3, now reproduced on a
2026-08-25 capture. No B-type CFO-disparity signature on this leg: both windows
locked and delivered 49/50, with fixed cfc_est engaged and negative (−461/−308 SI,
sign-consistent with the float estimate of −5.16 kHz) — unlike the B-class case,
where the fixed CFC sat near zero while float measured +5–7 kHz.

Artifacts (on disk; `two_jup/floatgap_n3/` is gitignored, same as the N3 originals):
`floatgap_n3/d1_berleg_ladder.csv`, `d1_berleg_o{0,80}_res.txt`, tap dumps
`d1_berleg_o*_{agc,rrc,ss,cfc,cs,pa,con,...}.txt`, windows `win_d1_berleg_o*.iq`.

Commit is LOCAL ONLY: push blocked while the OpenBao vault is sealed.

## 2026-08-25 ~21:40 — Task 9 Step 3 verdict: fixctl=3 ENGAGED; degradation event A/B'd to link state, not the fix

10-min verify window (`/tmp/fixctl_obs.log`): viol_count 0x303F -> 0x17583
(~78k events, ~130/s — the BEATFIX trigger firing and the fix arm engaging),
viol_latch updating (0x300C -> 0x2C73). End-of-window health read degraded
(fsync=602 wcnt=512). Discriminated before proceeding — A/B on 0x208:

    fixctl=3: fsync=602   fixctl=0: fsync=598   fixctl=3: fsync=565

Degradation identical across arms => NOT fixctl-caused; it is the known ~510-600 f/s
degraded-link class (resets 1-2/12 appearing). One full restore_known_good re-bring-up
recovered fsync=1255 clean 12/12; fixctl=3 re-asserted. **Step 3 PASS** (fix verified
by effect: counter/latch active, no fix-attributable health delta).

Step 4 launched 21:40: `revbase3.sh` — 3x `GATE_DIR=B capture_r3.sh B -d 68 -k`
(reverse, capture on 146), per-run 146-RX health gate (run 1 passed try 1,
fsync=1261), fixctl=3 asserted per run, accept_analyze.py per run, post restore.
Pre-stated gate (from plan Task 9): <1% CP95UL per-run on ALL 3 => reverse gate MET;
else record honestly.

## 2026-08-25 22:07 — Task 9 Step 4 verdict: reverse gate NOT MET (recorded honestly)

`revbase3.sh` (3x `GATE_DIR=B capture_r3.sh B -d 68 -k`, accept_analyze.py, drops in
denominator, per-run 146-RX health gate, fixctl=3 asserted per run; watchdogs disabled
during captures per the capture protocol):

    r1: live 78s [WEDGE truncated]  PER=14.235% (11169/78460)  CP95UL=14.482%
        bins {1:1182, 2:66, 3-4:70, 5-20:74, >100:1}
    r2: UNUSABLE (wedged, live window 10s of 45s)
    r3: live 28s [WEDGE truncated]  PER=2.619% (424/16190)   CP95UL=2.877%
        bins {1:234, 2:13, 3-4:17, 5-20:10}

**Pre-stated gate (<1% CP95UL per-run on all 3): NOT MET.** Honest reading of the
spread: r1's 14.2% is dominated by ONE >100-frame outage run (1,393 loss runs carry
11,169 frames => the single >100 run holds ~9k frames, wedge-adjacent); excluding that
catastrophe the residual is ~2.7%, consistent with r3's 2.62%. So the reverse steady
residual tonight is ~2.6-2.9% singles-dominated (vs the 1.72% 08-2x anchor — worse),
PLUS a wedge/outage class that hit all 3 captures while watchdogs were disabled.
146-RX arm lottery churned between runs (gate tries: r2 needed 1 restore, r3 needed 2).
Post-restore: both directions recovered (148 fsync=1258 clean 12/12; 146 fsync=1260,
resets 5/12 — watchdog re-arms visible). fixctl=3 standing.

Requirement shortfall also recorded: only r1 reached >=75k live frames; r2/r3 were
wedge-truncated. The Task 10 soak (under the hardened watchdog, normal ops) is the
definitive both-direction measurement and proceeds regardless.

## 2026-08-25 22:09–22:15 — ROM-air float-zero reconfirmation leg: capture DEGENERATE (#48 stale-DDR-replay on 148's tap); reboot recovery launched

Attempted `capture_rom_air.sh` (146 ROM -> 148 tap; ROM framesync gate passed at
1242 f/s) to close D1's caveat (tun payload unscoreable => float-zero not
re-confirmable on ber_leg_20260825). The capture itself came back DEGENERATE per
`check_capture_health.py`: occupied BW 2.88 MHz (expect ~22), envelope autocorr
0.9995 @ lag 256 — the documented #48 stale-DDR-replay signature (DMA returning a
stale buffer). Recovery for this class is REBOOT-ONLY (verified 08-24). NOT scored.

Post-leg restore left the link degraded: 148 fsync=597; 146 in a full reset storm
(resets 12/12). Recovery running (`/tmp/recover_2215.log`): plain reboot of 148
(image untouched, fe5bd8a4fe19), full restore, conditional 146 reboot if the storm
persists, fixctl=3 re-assert, both-board probes. Float-zero re-confirmation stands
on the 08-24 A3 ROM-air run; tonight's leg is recorded as attempted-and-degenerate.

## 2026-08-26 00:20 — Task 8 window 1 verdict: sentinel NOT retired (criterion failed honestly)

2h observation 22:20–00:17 under the relaunched sentinel: TWO wedges (22:23:58,
22:55:24), both recovered by the SENTINEL's chain (~75 s each), zero unrecovered.
But the retirement criterion requires the WATCHDOGS to own recovery, and the
evidence says they did not: both boards' /dev/shm/lock_watchdog.log are 0 bytes.
Diagnosis: deployed watchdogs ARE the hardened Task 7 build (md5 aaf6908a...,
matches repo) and ARE running on both boards — but (a) the wedges escaped to the
sentinel anyway (no watchdog recovery within the sentinel's 5-min poll), and
(b) a named MEASUREMENT GAP: the sentinel's recovery bring-up restarts watchdogs
and TRUNCATES their logs, so any watchdog attempt evidence is destroyed at
recovery time. Sentinel stays. Second observation window queued post-soak.
End-of-window health: 148 clean 1257; 146 back in the reset-storm/degraded class
(fsync=680, resets 10/12) — the #48 lottery churning again.

## 2026-08-26 00:50 — Task 10 Step 2 verdict: acceptance soak — goal NOT MET (pre-stated rule)

`soak_run.sh` (3 attempts of `soak_bidir.sh A -d 200 -k`, simultaneous saturating
qpsk_perf both directions, both-directions bring-up gate GATE_TRIES=12, ARQ OFF
verified in-band each attempt — cmdline `./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5`,
no ARQ flag, both boards; 148 binary fingerprint nakfp=4, 146 nakfp=0 = its plain
build, both as deployed). fixctl=3 asserted per attempt. Watchdogs disabled during
captures per the capture protocol. Scoring: accept_analyze.py, drops in denominator.

FORWARD (146 TX -> 148 RX), per attempt (~278k live frames each, 1.67M total... the
driver's cumulative line double-counted per-run+POOLED greps; true totals are
278,151 + 277,731 + 278,294 = 834,176 live frames):

    a1: PER=13.391% (37247/278151)  CP95UL=13.518%
    a2: PER=13.212% (36693/277731)  CP95UL=13.338%
    a3: PER=13.277% (36950/278294)  CP95UL=13.404%
    shape: singles(~19k)+doubles(~5k) comb, 4 runs >100 per attempt

REVERSE (148 TX -> 146 RX): **UNUSABLE all 3 attempts** — 146's delivered leg
wedged essentially instantly under bidirectional load (live windows 4s/0s/0s of
~238s). 0 scoreable reverse frames. Contrast: reverse-only runs earlier tonight
delivered 2.6-2.9% — the simultaneous-load condition itself collapses 146's
delivery (#48 host-delivery class under concurrent TX+RX load is the surviving
hypothesis).

**Pre-stated rule (goal MET iff BOTH directions CP95UL <1%): NOT MET.**
Forward CP95UL ~13.3-13.5% (the saturated singles comb, consistent with A4's
13.76% on this fresh-placement candidate); reverse unmeasurable under the
soak's required simultaneous condition.

Post-soak both boards degraded (148 570 then 348 after restore; 146 reset storm);
restore alone insufficient -> dual-board reboot recovery launched (images
untouched; `/tmp/recover_0100.log`).

## 2026-08-26 03:1x — CAMPAIGN CLOSING SECTION (Task 10 Step 3): overnight rig queue complete

**Pre-stated goal (<1% delivered PER CP95UL both directions, ARQ OFF): NOT MET.**
Exact failing numbers: forward CP95UL 13.338-13.518% (3x ~278k live frames,
soak_20260826_002716_a{1,2,3}); reverse 0 scoreable frames under the required
simultaneous condition (146 delivery wedges in seconds, all 3 attempts).

Task 8 window 2 (01:05-03:05): FOUR more wedges (01:15, 01:47, 01:53, 02:39), all
sentinel-recovered, watchdog logs 0 bytes again. Combined windows: 6 wedges/4h,
sentinel-recovered 6/6, watchdog-recovered 0/6. **Sentinel NOT retired; it is the
load-bearing delivery owner.** Wedge-interval dataset archived:
soak_notes/sentinel_wedge_intervals_20260825-26.log.

**Surviving hypothesis list (per the plan's NOT-MET clause):**
1. Forward comb: implementation-sensitive placement artifact in 146's TX byte plane
   (proven by A4); current candidate is a WORSE draw (13.4% vs 10.6%). Paths:
   rollback re-attempt (gated), v_endh variant (best timing margins), or seed
   iteration with the byte-plane-slack correlate.
2. Reverse: #48-class host-delivery collapse on 146 under concurrent TX+RX load
   (NEW tonight — reverse-only 2.6-2.9%, bidirectional 0). Discriminator needed:
   host (daemon/DMA submission starvation) vs fabric on 146.
3. Wedge cadence ~1-2/h under sentinel ownership; hardened watchdog never wins the
   race and its evidence is truncated by the recovery itself (fix: sentinel should
   snapshot watchdog logs BEFORE recovery bring-up).

Rig at close: 148=fe5bd8a4fe19 fixctl=3; 146=4be9286ca111; sentinel ACTIVE; last
sentinel line 03:01 ok rate=1102/s; 146 RX in the degraded lottery state at the
03:05 probe (sentinel redraws as needed). focus.txt banner updated; dashboard picks
it up via collect.sh.

## 2026-08-26 03:2x — OPERATOR REDIRECT (Travis, live): TX isolation supersedes the queued plan

Direction: deprioritize Task 8 window 3 / further end-to-end soaks. Rationale: the rig
cannot hold a healthy bidirectional link, so every link-dependent measurement is
contaminated. New priorities: (P1) TX bit-exact isolation air-free — ROM vs byte-DMA
sources, same payload, compared against bit-exact references; DMA-fetched-vs-intended
readback; byte-plane packing focus. (P2) float-vs-fixed END-TO-END equivalence on >=2-3
captures + chase the "fixed beats float 1.7-2.0 dB" anomaly (scoring-symmetry audit).
(P3) rig instability as a first-class finding (146 concurrent-load delivery collapse,
watchdog-missed wedge class, sentinel evidence-truncation gap — patch already staged).
Full autonomy until 07:00; decisions ledgered, not asked.

P1 design (pre-stated): the decisive air-free discriminator is FPGA-internal loopback
ON 146 (the accused board), three legs, same methodology as the on-air ladder:
  L1 ROM-source loopback: fabric BIST 0x108 biterr delta (bit-exact vs ROM golden).
     Prediction if TX-byte-plane comb: CLEAN (ROM-air was clean).
  L2 byte-DMA idle loopback: crc_drop/idle_rx deltas 60s (air baseline 9.33-9.65%).
     Prediction: ~10% comb PRESENT if TX-fabric; ABSENT => SSI/RF-entangled.
  L3 byte-DMA -B loopback (singles_loopback.sh BOARD=146): content bit-exact vs known
     host payload + comb cadence shape.
L1-clean + L2/L3-dirty in the SAME loopback = comb confirmed TX-fabric with zero air
and bit-level divergence localized. All legs use existing validated harnesses.

---

## P2: float-vs-fixed end-to-end equivalence (operator redirect) — 2026-08-26, off-rig

Directive: same input through the float reference receiver and the fixed arm, scored
end-to-end (PER+BER), on >=2 captures; and chase the "fixed beats float 1.7-2.0 dB"
anomaly by auditing scoring symmetry. All work on BANKED captures; no rig contact.

### End-to-end table (float = `k5_240/float_baseline_f1536.m` fresh runs tonight;
### silicon = banked `regs_cap.txt` CAP_START/END deltas, post-Viterbi BIST vs ROM golden)

| capture | frames scored (float / silicon) | float BER (95% UB) | silicon BER | float PER | exclusions + why |
|---|---|---|---|---|---|
| `romair_20260823_115206` | **0 / 156** | NOT SCOREABLE | 315/3,843,840 = **8.19e-5** | n/a | Float arm: ALL frames excluded — the banked `pair.iq` is the #48 stale-DDR ramp, not air signal (re-verified tonight: `check_capture_health.py` DEGENERATE, BW 2.88 MHz + env corr 0.9995 @ lag 256, byte-identical verdict to the known-degenerate 08-25 control; sample-level: Q channel is literally a counter ramp 0..7967, diff spectrum {0,+1,+256,+257}, mean 3983.5 = half-scale; I is a period-4 pattern, max 541). Consistent with the 08-24 "ROOT CAUSE: the IQ CAPTURE PATH is bad" section — the regs deltas are valid (register reads), the IQ file never was. Silicon arm: no frames excluded (BIST counters over the full 125.2 ms window). |
| `romair_20260824_221024` | **81 / 151** | 0/995,652 = **0** (UB 3.0e-6) | 305/3,720,640 = **8.20e-5** | **0.000% (0/81)** | Float arm: no frames excluded (nRej=0; all 81 frames in the 65-ms IQ file accepted, preCorr 0.981/1.002/1.013). Silicon arm: none; its 124-ms window is a ~1.9x superset of the IQ file — denominators differ by window length, not by gating. Fresh tonight's run reproduces A3 bit-exactly: mapping [1 3 2 0], margin 12,068, snrEst 29.03 dB, clipped 0.0000. Silicon PER is not recorded by the regs (biterr/pkts counters only). |

The 08-25 leg (`romair_20260825_220911`) remains DEGENERATE (same ramp signature,
confirmed as negative control tonight) and was not scored. No other ROM-air capture
exists in the bank, so a second float-scoreable leg is not obtainable off-rig.

### Anomaly audit: D1/N3 ladder scoring symmetry (`two_jup/floatgap_n3/ladder_f1536.m`)

Symmetric (hypotheses refuted):
- (a) warm-start: REFUTED. The fixed taps are a COLD-started Verilator sim
  (`Vwrap_byte_taps win_d1_berleg_o*.iq ...`, D1 section) on the identical window —
  no silicon loop state is inherited; the agc/rrc/ss rungs re-run the float CFO
  estimator themselves (ladder_f1536.m:41-43, useCFO=true). cfc/cs/pa inherit the
  SIM's own converged CFC (ladder_f1536.m:43-45, useCFO=false) — by design, not
  hardware warm state.
- (b) normalization: REFUTED. Both arms share `evm/evm_metrics.m` — gainNorm rescales
  mean|y| to cfg.RefRMS (evm_metrics.m:36-38) and the EVM denominator is cfg.RefRMS==1
  (evm_metrics.m:50) for every rung; same per-frame preamble derotation
  (ladder_f1536.m:90-91) and same ideal-constellation reference in both arms.
- (c) acquisition-transient window: same WARM=5 head-drop in both arms
  (ladder_f1536.m:28, :101); float rung nF=49 vs tap rungs nF=50 (one-frame
  difference, median-robust). Not the cause.

ASYMMETRY FOUND (the cause) — remainder RATE/FORMAT:
- Rung-0 float processes the raw window at sps=4 (ladder_f1536.m:35); the agc rung's
  float remainder runs at sps=8 (ladder_f1536.m:41) on a tap stream that is the SAME
  4-sps data duplicated into 8 lines/symbol (ladder_f1536.m:12 "mostly duplicate
  pairs"; measured tonight: 83.0% literal duplicate pairs). The sps-8 remainder
  (rcosdesign(beta,span,8) MF at ladder_f1536.m:110 + Gardner SamplesPerSymbol=8 at
  :112) applied to a ZOH-duplicated stream adds noise filtering and finer timing
  operation the sps-4 float rung never receives.
- Falsifying measurement (scratch `p2_anom.m`, window `win_d1_berleg_o0.iq`):
      R0   float rung, sps=4 raw          : medEVM 3.097  (reproduces d1 csv)
      RAGC agc tap rung, sps=8            : medEVM 2.496  (reproduces d1 csv)
      RZOH raw window repelem x2, sps=8,
           ZERO fixed-point arithmetic    : medEVM 2.486
  20*log10(3.097/2.486) = **1.91 dB reproduced with no fixed code at all**; the fixed
  AGC itself moves the number 2.486->2.496 (~+0.03 dB). **The 1.7-2.0 dB "fixed beats
  float" gap is the instrument's rate asymmetry, not fixed-point superiority.** The
  same structure exists in the N3 originals (same ladder, same rungs), explaining the
  A-type +2.18/+1.92 there.
- Secondary asymmetries (named, non-causal): stale K5 refine-CFO trust bound 5 kHz at
  ladder_f1536.m:123 (vs the retuned 623 Hz bound, float_baseline_f1536.m:204) —
  shared by both arms within the ladder; rung-0 normalizes by max|raw| (:35) vs taps
  by max|tap stream| (:56), washed out by the rms re-norm inside float_chain (:109).

Stage-cost fallout (operator's "if scoring is asymmetric, stage conclusions are
suspect"): any rung-over-rung delta that CROSSES a remainder-rate boundary is
contaminated. float->agc (4->8 sps) is the 1.9 dB artifact above; rrc->ss (8->1 sps)
means the headline "**ss** +0.65/+0.46 first divergent stage" was measured against an
instrument-advantaged 8-sps baseline — against the sps-4 float baseline the fixed ss
rung is 0.55 pp BETTER (2.548 vs 3.097). The ss attribution is therefore NOT
established by this instrument; constant-rate deltas (ss->cfc->cs->pa, all 1/sym) are
clean, leaving **cs +0.25/+0.34 pp as the largest uncontaminated stage cost**. The
central verdict SURVIVES unchanged: at 29+ dB Es/N0 even the worst rung EVM (~2.65%)
implies ~0 thermal BER, so the 8.2e-5 residual remains post-constellation
implementation — that conclusion never depended on the fixed-vs-float sign.

### Verdict lines

- **FLOAT-ZERO: NOT CONFIRMED on 2 captures — CONFIRMED on 1** (`romair_20260824_221024`,
  re-run fresh tonight: 81/81 frames, 0 errors in 995,652 bits, 95% UB 3.0e-6, PER 0%).
  It cannot rest on a second capture because the only other banked ROM-air IQ
  (`romair_20260823_115206`) is the #48 stale-DDR ramp (proven sample-level tonight);
  the 08-25 re-capture attempt was also degenerate. A fresh ROM-air capture after a
  148 reboot is the only path to a second leg (rig work, not authorized tonight).
  Silicon end-to-end stands at 8.2e-5 on BOTH register windows.
- **ANOMALY: EXPLAINED (instrument rate/format asymmetry).** The ladder's float rung is
  scored through an sps-4 remainder while the tap rungs get an sps-8 ZOH-duplicated
  remainder; pure sample duplication with zero fixed-point arithmetic reproduces
  1.91 dB of the 1.7-2.0 dB gap. Fixed-vs-float end-to-end on the one valid capture is
  float 0 (995,652 bits) vs silicon 8.2e-5 — float is NOT beaten by fixed at bit level.

Scratch artifacts: session scratchpad `p2_e2e.log`, `p2_anom.log`, `p2_diag.log`
(assisted-CFO attempts on 115206 also fail — it is not a CFO problem, the file is a ramp).

## 2026-08-26 03:2x–04:0x — P1 VERDICT: the ~10% comb does NOT reproduce in internal loopback on 146

First-ever run of the off-air comb test ON THE ACCUSED BOARD (`singles_loopback.sh`
BOARD=10.0.0.146 M=16 DUR=120; the 08-22 off-air run was on 148). Three legs, all
zero-air, all on 146 (image 4be9286ca111):

  L2 (byte-DMA idle, -G, the config that shows 9.33-9.65% on air):
     steady-state loss 0.2-0.3% (13-22 crc_drop per ~6,220 frames per interval,
     30 consecutive intervals), punctuated by discrete burst events (~2.3k frames,
     2 bursts + arming transient in 165 s). NO COMB — ~40x below the air rate.
  L3 (byte-DMA -B, bit-exact vs known host payload, single-packet DMA):
     174,207 frames, 4,650 bad, PER 2.67%; only ~309 frames in singles/doubles
     runs; 6 long runs carry the bulk (the burst class). boundary_enrichment
     1.0005, boundary_locked=False. NO COMB SHAPE.
  L1 (ROM source, fabric BIST at the decoder output, bit-exact vs ROM golden):
     lock 1245 f/s, rstcs=0. Steady biterr 45-56/s over 6x10s windows
     => BER ~1.7e-6 steady; my first 60s window read 3,641/s because it caught
     one burst (218k errors) — same burst class as L2/L3.

Pre-stated rule outcome: NOT-REPRO clause fires for the comb (steady PER <=0.5%
in the idle arm, boundary_locked false); the 2.67% -B number is burst-class, not
comb. **The singles comb is NOT in the fabric byte-plane->modulator path as
observed at the loopback tap.** Combined with the standing facts (ROM-air clean
over the same SSI/RF path; 148's RX exonerated; A4: comb magnitude moves with
placement), the surviving hypothesis is:

  MARGINAL TX EGRESS ON 146 (post-modulator: SSI-TX serialization / clock-domain
  boundary), aggravated by byte-plane/DMA switching activity (content-independent
  aggressor), placement-sensitive (A4), invisible in loopback (tap is upstream of
  the egress) and clean under ROM (no byte-plane activity as aggressor).

Falsifiable predictions recorded: (a) v_endh (better byte-plane/CE slack) should
move the comb; (b) an SSI near-end loopback leg (byte source -> SSI TX -> ADRV9002
loopback -> SSI RX -> 146 demod) reproduces the comb if SSI-chain, exonerates RF/
air if clean. rf_loopback.sh exists but needs a PHYSICAL Tx1->Rx1 attenuated cable
(never rigged) — operator/bench item; transceiver-internal SSI loopback pokes are
unvalidated and were NOT attempted at night (board wedges on wrong sequences, no
remote power).

New fact for the BER thread: 146 self-loopback steady BIST BER 1.7e-6 (zero CFO,
zero channel) vs 8.2e-5 on air at 29 dB SNR with float=0 on the same air samples
=> the residual is RX-implementation-under-air-conditions (CFO/dynamics), which
P2's corrected ladder now attributes to no single DSP stage (cs +0.25/+0.34 pp
largest clean cost; the earlier "ss first divergent" claim is RETRACTED — P2
found the ladder's sps-4/sps-8 remainder asymmetry and reproduced 1.91 dB of the
"fixed beats float" gap with zero fixed-point code; anomaly EXPLAINED).

## 2026-08-26 04:0x — P3: rig instability characterization (first-class findings)

1. 146 CONCURRENT-LOAD DELIVERY COLLAPSE (new class, named tonight): reverse-only
   captures deliver 2.6-2.9%; under SIMULTANEOUS bidirectional saturating load the
   146-side delivered leg died within <=15 s live in 3/3 soak attempts (4s/0s/0s
   of ~238 s) while forward ran at full rate throughout. #48 family (modem keeps
   decoding; host delivery dies). Mechanism evidence thin — 146's /dev/shm logs
   were lost to the 00:55 reboot; next repro should pull qpsk_tun.log + perf logs
   BEFORE any recovery.
2. WEDGE CENSUS (this night, delivery wedges under sentinel ownership): SEVEN
   (22:23, 22:55, 01:15, 01:47, 01:53, 02:39, ~03:12), ALL sentinel-recovered
   (~75 s each), ZERO watchdog-recovered. Watchdogs verified: correct hardened
   build (md5 matches repo), running on both boards the whole time.
3. EVIDENCE-DESTRUCTION GAP, FOUND AND FIXED: delivery_sentinel.sh's recovery
   chain truncated /dev/shm/lock_watchdog.log on both boards BEFORE restart
   (line 21), destroying watchdog-attempt evidence at every recovery — why the
   watchdog-escape mechanism is still unnamed. Patched (03:2x): the sentinel now
   snapshots both boards' watchdog logs to ~/modem-status/wdlog_<ip>_<ts>.txt
   pre-recovery. The NEXT wedge carries its own evidence.
4. #48 STALE-DDR TAP RAMP: struck 148 again at 22:09 (romair leg DEGENERATE,
   reboot-only recovery, confirmed). P2's audit found the banked 08-23 romair
   IQ was ALSO the ramp — its silicon register numbers stand, its IQ never was
   valid. Every IQ-based claim must carry a check_capture_health.py PASS.
5. LOOPBACK BURST CLASS: all three loopback legs on 146 show discrete burst
   events (~1-2.4k frames) on top of clean steady state — consistent with the
   deterministic off-air burst artifact class from 08-22 (Task 3 on 148). It is
   a loopback/off-air measurement artifact class, distinct from the comb; do not
   let it contaminate steady-state numbers (score steady windows separately).

## 2026-08-26 04:4x — ROM-air attempt 2 DEGENERATE; diagnosis CORRECTED: structural tap absence on BEATFIX image, not #48

`romair_20260826_083927`: link ROM framesync 1242 f/s, rstcs=0, but pair.iq is the
ramp again (BW 2.88 MHz, env autocorr 0.994@256). CORRECTION of tonight's 22:09
diagnosis: this is NOT the reboot-recoverable #48 stale-DDR class. Evidence: the
21:17 HEALTHY ber_leg capture was taken on e49c011b BEFORE the BEATFIX flash;
both degenerate attempts (22:09, 04:39) are on fe5bd8a4fe19, with TWO 148 reboots
in between changing nothing. This matches the 2026-08-24 root cause verbatim:
on the BEATFIX lineage the rx-lpc DMA source is structurally wired to a
counter/ramp — the IQ tap DOES NOT EXIST on this image. The 22:13 "reboot
recovery" recovered the LINK state only; the tap was never coming back.

Consequences: (1) float-zero leg 2 is IMPOSSIBLE while 148 carries fe5bd8a4fe19 —
it needs e49c011b (working tap) = a 148 flash = operator gate; the plan's ORDERING
GATE B2 existed for exactly this. (2) The silicon BIST deltas in both degenerate
runs remain valid (04:39 window: 157 pkts, 268 biterr — small window, consistent
order with 8.2e-5-class). (3) check_capture_health.py's advice text conflates two
classes with one signature (stale-DDR vs structural tap absence) — the
discriminator is the image md5, now recorded here.

## 2026-08-26 ~05:0x — OPERATOR GO ("do it"): v_endh falsifier flash on 146

Operator authorized the P1 falsifiers live. The SSI near-end loopback needs the
physical Tx1->Rx1 attenuated cable (bench) — deferred. Executing the v_endh flash:
146 4be9286ca111 -> ec414d2df8bc (`variants_placement/v_endh`, rank-1 timing:
WNS 0.102/WHS 0.010, BP_SETUP 1.847, CE_SETUP 3.944, CE_HOLD 0.194; RTL-identical
to the candidate by construction — same synth checkpoint, place directive only).
Rails verbatim (flash_146_vendh.sh, cloned from tmrfresh): md5 precondition
4be9286ca111; on-board + nemo rollback banks verified (both 4be9286ca111);
readback verify; full bring-up; two-pass reset-aware health gate on 148
(fsync>=1100 AND wcnt>=1100); auto-rollback; NO retry.

**Pre-stated verdict rule (BEFORE data):** post-flash A4-style ladder —
(1) idle-only byte-DMA leg, 60 s stats delta on 148 (baselines: candidate 9.65%,
433fd8da 9.33%); (2) saturated-tun leg, capture_r3 A >=75k live frames, wedge-
aware CP95 (baselines: candidate 13.76%/CP95UL 14.0, 433fd8da 10.62%).
  COMB MOVED   = either leg shifts >2pp from the candidate baseline (either
                 direction) => placement/egress-marginality hypothesis SUPPORTED.
  FIXED        = saturated CP95UL <1% => comb closed on this draw.
  UNCHANGED    = both legs within 2pp of candidate => hypothesis WEAKENED
                 (comb insensitive to the best-timing draw); record honestly.
  Health-gate fail => rails roll back to 4be9286ca111; one arm-lottery re-attempt
  permitted (tonight's 21:00 rollback flash showed gate-fail can be lottery, and
  the operator GO covers the event); a SECOND gate-fail ends the lane.

## 2026-08-26 05:0x — v_endh attempt 1: VOID (148 died mid-gate), NOT a v_endh verdict; 146 rolled back by rails

`flash_146_vendh.sh ec414d2df8bc`: preconditions PASS, stage PASS, **readback PASS
(ec414d2df8bc booted and ran)** — then the bring-up's NAK re-check on 148 returned
EMPTY (not 0): 148's watchdog restart FAILED, its status block came back blank, and
post-rollback 148 is fully OFF THE NETWORK (no ping, no ssh, "no route to host").
The NAK rail fired on an unreachable gate instrument, and rails correctly rolled
146 back to 4be9286ca111 (readback verified). **This is VOID for the MOVED/FIXED/
UNCHANGED rule — the image was never health-gated; no verdict is claimable in
either direction.** The one operator-covered re-attempt REMAINS available.

148 down: crashed/hung on its own during the window (it served the romair leg at
04:39 and the sentinel's recovery chain was mid-flight through it at ~04:5x when
sentinel was stopped for the flash). Jupiter has no remote power — if the 30-min
watcher (/tmp/watch148.log) does not see it return, PHYSICAL POWER CYCLE required.

PROCESS MISS (mine, recorded): I launched the flash without re-verifying 148's
health after interrupting the sentinel's in-flight recovery — the health-gate
instrument was unverified at launch. AMENDMENT to the 146-flash rails: precondition
must include a live two-way probe of 148 (the gate instrument), not only 146's
image identity. Applied to flash_146_vendh.sh before any re-attempt.

## 2026-08-26 05:4x — 148 HARD DOWN, rig blocked on physical power cycle

30-min watcher expired: 148 never returned (no ping — hard hang or power fault,
dropped off ~05:00 mid-bring-up with no command from this side rebooting it; its
last served work was the 04:39 romair leg). Jupiter has no remote power => rig is
BLOCKED on an operator power cycle. 146 verified safe on 4be9286ca111. Sentinel
deliberately left STOPPED (recovery loop would thrash against a dead 148); its
patched build is in place and relaunches after restore. Push notification sent.
Restart sequence + staged re-attempt recorded in the focus.txt banner.

## 2026-08-26 12:4x — 148 restored by operator power cycle; v_endh RE-ATTEMPT launching

148 returned at 12:44 (fresh boot, uptime 26 s => physical power cycle; image
fe5bd8a4fe19 intact; dmesg clean — crash evidence lost to the cycle, cause stays
UNKNOWN/one-off). Auto-restore: ARM GATE PASS try 1, fixctl=3 re-armed, 148
1258/1258 clean 12/12, 146 wcnt 1261 clean 12/12 (reverse leg healthy), sentinel
relaunched (1738/s). Executing the operator-covered v_endh re-attempt under the
AMENDED rails (pre-flash 148 health precondition now in the script). Verdict rule
unchanged from the 05:0x pre-statement (MOVED >2pp / FIXED CP95UL<1% / UNCHANGED
within 2pp; a second health-gate fail ends the lane).

## 2026-08-26 13:0x — v_endh VERDICT: MOVED (both legs >2pp, OPPOSITE directions) — hypothesis SUPPORTED, correlate REFUTED

Flash re-attempt: all rails green first pass (amended precondition: 148 pre-flash
health 1257 clean; readback ec414d2df8bc; ARM GATE try 1; nakstat=4; health gate
1257/1256 clean 12/12, one pass). Ladder (same methodology as A4):

  idle byte-DMA 60s:  crc_drop=9695 idle_rx=64776 -> 13.02%
                      (candidate 9.65%, 433fd8da 9.33%)  => +3.37pp WORSE
  saturated tun:      PER=11.462% (8955/78131) CP95UL=11.687%, 0 wedges,
                      singles+doubles comb (5313+1449)
                      (candidate 13.76%/CP95UL 14.0, 433fd8da 10.62%) => -2.3pp BETTER

**A4-rule verdict: MOVED** — third RTL-identical placement, third distinct comb
signature. Placement/implementation sensitivity is now triple-confirmed. TWO new
facts: (1) the timing-slack correlate is REFUTED as a predictor — v_endh has the
BEST margins of all six variants (WNS 0.102, BP_SETUP 1.847, CE_SETUP 3.944) yet
the WORST idle comb measured to date; (2) idle and saturated legs moved in
OPPOSITE directions on the same image — the comb is not one scalar per placement;
the idle-mode and load-mode aggressor couplings vary independently, consistent
with the egress-marginality story (different switching-activity mixes excite
different marginal paths per placement).

Standings (saturated / idle): 433fd8da 10.62/9.33 < v_endh 11.46/13.02 (sat) —
candidate 13.76/9.65. No draw approaches <1%. Seed iteration alone is a random
walk; the fix path needs either the SSI near-end loopback split (bench cable) or
a constraint-driven approach (pin down the egress CDC paths with explicit
constraints rather than re-rolling placement).

146 currently carries v_endh ec414d2df8bc (best saturated draw so far, worst
idle). OPERATOR CHOICE queued: keep v_endh vs one more gated flash to 433fd8da
(best overall). Rig left healthy, sentinel relaunching.

## 2026-08-26 13:2x — P1 closing experiment: 1-ft SELF-RECEPTION on 146 (no attenuator available; antennas 1 ft apart per operator)

Design: keep the entire proven link configuration; change ONE knob — 146's RX LO
1900002500 -> 2000000000 (its own TX carrier; same XO => ~0 CFO). 146's Rx1 then
hears its own Tx1 across 1 ft of air: byte source -> SSI TX -> DAC -> RF -> antenna
-> antenna -> RX, the full egress chain, zero 148 involvement. Escalation if no
lock: TX attenuation -10/-20/-30 dB (front-end overload), then +20k off-null LO.
Restore: RX LO back to 1900002500, reverse-leg probe, sentinel relaunch.

**Pre-stated verdict rule (BEFORE data):** measure the 60 s idle-leg loss on
146's OWN daemon (crc_drop/idle_rx deltas), image = v_endh (today's baselines:
air-forward idle 13.02% at 148's RX; internal fabric loopback 0.2-0.3%).
  EGRESS CONVICTED: loss >= ~half the air rate (>6%) with the singles character
    => the comb is born in 146's TX egress (SSI/DAC/RF), 148 + long OTA path
    exonerated; cabled-free repro established.
  EGRESS CLEAN: loss <= 1% => egress produces clean frames at 1 ft; the comb
    then requires the long-path/SNR regime — record honestly, re-aim.
  INTERMEDIATE (1-6%): report the number, no forced call.
  NO LOCK after escalations: VOID (front-end/config), not a comb verdict.

## 2026-08-26 14:4x–15:0x — P1 SELF-RECEPTION VERDICT: steady comb ABSENT through the FULL TX egress — suspect list reshuffled

Operator had no attenuator; Tx1/Rx1 antennas ~1 ft apart => self-reception OTA.
Three takes, two instrument traps found and cured en route (both ledger-worthy):
  T1 (live RX-LO retune): INVALID — the retune alone perturbs 146's TX (148's
     simultaneously-observed reception collapsed to 100% crc at ~400 f/s; both
     receivers identical => transmitted frames broken). ADRV9002 live RX-LO
     writes disturb TX on this profile — NEVER live-retune; full re-arm only.
  T2 (full arm, RX LO == TX LO exactly): rstcs STORM (1377/s) at 972 f/s — the
     zero-IF trap: at zero CFO the TX LO feedthrough sits at DC and the carrier
     loop fights it. The link never runs true zero CFO (off-null policy).
  T3 (full arm, RX LO +20 kHz off-null, ROM double-tap per ARMCAUSE): CLEAN —
     ROM self: 1243 f/s, rstcs=0, BIST 3622 err/s (RF path adds ~70x over the
     51/s fabric floor — the ~1e-4 BER class enters in the analog path).
     Byte self idle leg, per-window: 0.30% / 9.1%(one 5.1k burst) / 0.29% / 0.25%
     => STEADY loss 0.25-0.30% == the internal-loopback floor, plus the known
     episodic burst class. First 60s read of 5.19% was burst-contaminated.

**VERDICT (pre-stated rule): steady EGRESS CLEAN.** 146's byte-sourced TX chain
END-TO-END (byte plane -> SSI -> DAC -> RF -> antenna -> 1 ft OTA) delivers
steady 0.25-0.30% to a co-located receiver — while the SAME image loses 13.02%
steady to 148 on the link. The comb is NOT born in 146's TX egress as a
standalone property of the transmitted signal at short range.

Surviving hypotheses, REORDERED (each with its cheap discriminator):
 H1 CFO-REGIME: link forward runs -5.15 kHz residual (148 RX plain 2.0 GHz);
    self-RX ran +20 kHz and was clean. R0 history: "CFO NULL REQUIRED" era +
    a BISTABLE LO value on record — carrier-loop tracking asymmetry is a live
    suspect. TEST (cheapest, on-link): arm forward with 148 RX LO 2000020000
    (off-null like the reverse policy) and re-run the 60s idle leg. One arm.
 H2 148-RX x BYTE-WAVEFORM interaction: ROM-air clean at 148 exonerated 148's
    RX for ROM payload statistics only; byte idles are structured/repetitive
    (whitening off) and may stress timing/carrier tracking at 148 in a way the
    msggen ROM pattern does not. Placement sensitivity (A4/v_endh) would then be
    TX waveform fine-timing changing per placement — still TX-coupled, but only
    visible through 148's demod. TEST: 148 self-reception of its OWN byte TX
    (mirror of tonight's protocol on 148), and/or QPSK_WHITEN=1 A/B on the link.
 H3 DISTANCE/CHANNEL: 1 ft vs across-room multipath. Steady comb at 112/s with
    zero quiet windows is un-fading-like — H3 is weak but only distance
    discriminates. TEST: boards co-located for one link-config leg.
Fabric byte plane, SSI serialization, DAC, RF egress: now all measured clean
steady at short range. 148's RX front-end + the link CFO/whitening/geometry
regime carry the remaining suspicion. Rig restored (fwd 1253 clean, rev 1261),
fixctl=3, sentinel up.

## 2026-08-26 15:1x–16:0x — THE COMB REQUIRES CROSS-BOARD CLOCKS; CFO operating point scales it; whitening refuted

Completed matrix (STEADY idle byte-DMA loss; single-window reads are burst-
vulnerable by up to ~+7pp — methodology amended to multi-window min/median):

    fabric loopback (146)              0.25-0.30%
    146 self-RX, 1 ft OTA, +20k       0.25-0.30% steady (bursts on top)
    148 self-RX, 1 ft OTA, +20k       0.3% steady (first 60s read 5.31% was
                                       burst-contaminated, same as 146's 5.19%)
    link 146->148, +20k off-null      6.0% steady (3 windows exactly 60 permille)
    link 146->148, -5.15k (stock)     13.0% steady
    WHITEN=1 on the +20k link         6.0% steady => WHITENING REFUTED

Isolated variable: same-clock configs have ZERO sample-rate offset even with a
dialed +20 kHz carrier offset; cross-board adds ~2.6 ppm XO offset (SRO + LO
dynamics). The steady comb requires the cross-board clock regime, and its
magnitude moved 13.0% -> 6.0% purely by re-dialing the RX LO operating point
(LO_A_RX env-overridable in bringup_r2r3.sh as of today). ROM payloads decode
clean through every path (self-RX ROM BIST ~3.6k err/s both boards, rstcs=0).

Reading: receiver symbol-timing/carrier tracking robustness deficit under real
clock offset — resonates with P2's corrected ladder (cs largest clean stage
cost), the R0-era "CFO NULL REQUIRED" history, and plausibly re-frames the A4/
v_endh placement deltas as receiver-side sensitivity to TX timing detail (and/or
single-window burst contamination of the earlier idle legs — flagged).

148 mirror self-RX also reproduced the same burst class (~5k frames every ~2-3
min) seen on 146 and in fabric loopback — the burst class is universal and
distinct from the comb.

NEXT (running): LO_A_RX operating-point sweep (+40k/+10k/+5k/-10k/-20k, burst-
robust min-of-2x45s scoring) — pre-stated: if any point reaches <1% steady, the
campaign gate becomes reachable HOST-SIDE (no flash); the found optimum then
gets a full 75k saturated CP95 leg.

## 2026-08-26 16:0x — LO SWEEP: violent SIGN ASYMMETRY; no sub-1% point; RTL suspect named

Sweep (steady = burst-robust min of 2x45s, idle leg, dialed LO_A_RX; true CFO =
dial - 5.15k XO):
    dial -20k (true ~-25k):  100%       dial +5k  (true ~ null): 12.2%
    dial -10k (true ~-15k):  85.4%      dial +10k (true ~+4.9k):  6.8%
    dial   0  (true -5.15k): 13.0%      dial +20k (true ~+14.9k): 6.0%  <- best
                                        dial +40k (true ~+34.9k): 7.8%
No point <1% => the LO knob alone cannot close the campaign gate; the positive
plateau bottoms ~6%. But the response is violently SIGN-ASYMMETRIC (+15k best
ever, -15k near-total loss, true null BAD at 12%) — the signature of a SIGNED
defect in the carrier/timing tracking loop (one-sided limiter, signed
truncation/rounding, accumulator bias). This also retro-explains why the stock
-5.15k residual sits on the bad side and why the reverse leg (+2.4k policy,
positive side) runs ~5x better than forward.

QUEUED (offline, no rig): feed the tap netlist synthetic f1536 waveforms at
+/-15k CFO — if the sign asymmetry reproduces in RTL sim, the comb has an
RTL-level repro and the fix lands in sim first. Interim host-side mitigation
available NOW: run forward at dial +20k (13.0% -> 6.0%, single env var
LO_A_RX=2000020000) — left OUT of the standing config pending operator ack
(restore reverts to stock). Rig restored stock, both boards clean (1254/1261),
fixctl=3, sentinel up.

## 2026-08-26 16:2x — OPERATOR GO: +20k off-null is now the STANDING forward default; RTL ±CFO repro campaign launched

Item 1 (operator: "do 1 now"): bringup_r2r3.sh LO_A_RX default changed
2000000000 -> 2000020000 (still env-overridable). Link re-armed on the new
default via full restore: 148 RX LO readback 2000020000, health 1255/1255 clean
12/12, fixctl=3, sentinel up. Verification windows: 6.6% steady (win2 14.9% =
burst window). The standing forward comb is now ~6% instead of ~13% with zero
firmware/fabric change. NOTE: this is MITIGATION, not the fix; the campaign gate
(<1%) still requires the tracking-loop defect fixed.

Item 2 (operator: "2 in the background"): offline agent launched to reproduce
the sign asymmetry in RTL sim (Jul-25 IQ tap netlist, synthetic f1536 waveforms,
CFO+SRO-coupled sweep 0/+-5k/+-15k/+-25k, 0-Hz G1 gate before any CFO claim;
verdict + first-divergent-signal localization if reproduced). Results will land
in a dated ledger section.

## 2026-08-26 — RTL ±CFO asymmetry repro (operator item 2): REPRODUCED, sign-asymmetric, REQUIRES the SRO component; first divergent signal = Symbol_Synchronizer output

Off-rig, pure sim. DUT: Jul-25 archive tap netlist
`jupiter_240k5_byte/rtl_sim/obj_byte_taps_f1536_jul25/Vwrap_byte_taps`
(cadence 4, D1 drive recipe verbatim: `Vwrap_byte_taps <stim.iq> 2466600 0 4
8400 0 <pfx> 0`). Netlist-generation caveat: this is the Jul-25 archive
generation, NOT the flashed v3/BEATFIX generation (which is BIST-ROM-driven and
takes no IQ — reproducing there needs new harness work, not done here).

Stimulus (`two_jup/rtl_cfo_repro/gen_cfo_stim.m`): synthetic f1536 waveform,
ROM payload (f1536_ref_bits), 51 source frames -> 50 frames of int16 IQ
(2,466,600 samp @61.44 MSPS), complex RMS 2450 (measured off the D1 windows
2453/2449), noiseless. Bit->symbol mapping calibrated empirically against the
DUT BIST: perm [0 1 3 2] uniquely reproduces the golden capout 04922282
(24-perm search, 4-frame stimuli); independently confirmed by the float
scorer's hyp.mapping=[0 1 3 2]. XO physics: true CFO f at Fc=2 GHz => ppm =
f/2e9 applied BOTH as carrier rotation and as sample-rate resample ("coupled");
CFO-only variants rotate without resampling. Stimulus CFO sign spot-checked by
4th-power estimator (+14.75k/−15.27k vs the 0 Hz baseline).

G1 gate (0 Hz): **PASS** — 48/50 frames delivered, capout golden 04922282,
biterr=51 (the documented latched-warmup ROM-BIST counter value), per-frame
rxw scoring: 46/46 scoreable frames bit-exact golden. Constant harness
overheads in EVERY run: frame 0 consumed as warm-up (delivered all-zero) and
the final frame truncated by the fixed 60k-clk drain tail — 46 scoreable
frames per run; per-frame scorer `two_jup/rtl_cfo_repro/score_rxw.py`.

Sweep (all runs delivered 48/50 packets — the defect corrupts frames, it does
not drop them in sim; corrupt = any bit error in a scoreable frame; corrupted
frames carry ~6.0-6.1k errors in 12,292 info bits ≈ 50% = quadrant/alignment
garbage, which on hardware = CRC drop = frame loss):

| true offset | variant   | delivered | corrupt/46 | loss% | cfc_est | notes |
|-------------|-----------|-----------|-----------|-------|---------|-------|
| 0           | coupled   | 48/50     | 0/46      | 0     | 5       | G1 gate |
| +5 kHz      | coupled   | 48/50     | 0/46      | 0     | 358     | clean |
| −5 kHz      | coupled   | 48/50     | 0/46      | 0     | −275    | clean |
| +15 kHz     | coupled   | 48/50     | 0/46      | 0     | 1141    | clean, sync dead-regular |
| **−15 kHz** | coupled   | 48/50     | **6/46**  | **13.0** | −998 | frames 33-35, 44-46 |
| +25 kHz     | coupled   | 48/50     | 0/46      | 0     | 1476    | clean |
| **−25 kHz** | coupled   | 48/50     | **11/46** | **23.9** | −1621 | 3 event clusters |
| +15 kHz     | CFO-only  | 48/50     | 0/46      | 0     | 1237    | clean |
| −15 kHz     | CFO-only  | 48/50     | 0/46      | 0     | −1228   | **clean — no SRO, no defect** |

**VERDICT line: RTL_ASYMMETRY: REPRODUCED (loss(−15k)=13.0% >> loss(+15k)=0%,
loss(−25k)=23.9% >> loss(+25k)=0%, both CFO-only ±15k clean).** Two structural
matches to the hardware matrix: (1) sign — negative side catastrophically
worse, positive side clean (hw: dial −10k 85.4% vs dial +20k 6.0%); (2) the
defect REQUIRES the sample-rate-offset component — CFO rotation alone is
harmless at both signs, exactly the on-air finding that the comb requires the
cross-board clock (SRO) regime. Magnitudes are smaller than hardware
(noiseless, 46-frame windows, single XO model) — the sim reproduces the
negative-side excess, not the +side ~6% floor.

Localization (stage taps, +15k vs −15k coupled):
- cfcFreq: symmetric and locked both signs (+2046 / −2049 SI ≈ ±15.0 kHz).
- **Symbol_Synchronizer output (ss tap) is the FIRST divergent signal**:
  per-frame derotated 4th-power coherence 1.000 on every +15k frame; on −15k
  it collapses to 0.925-0.94 in single-epoch bursts exactly at the corrupt
  frames (34, 45-46). Carrier_Synchronizer output stays ≥0.991 both signs.
- Downstream consequence chain (measured): in the bad epoch the Preamble
  Detector's Peak_Search latches a false peak +32 symbols late —
  Preamble_Detector_syncPulse spacing runs 12333 everywhere except single
  12365/12301 excursions, only on the negative side (−15k: 2 events; −25k: 3
  events) — and the Phase_Ambiguity resolution goes wrong for ~3 frames per
  event (~50% info-bit garbage), then recovers.
- Named RTL suspect (inspected, NOT yet instrument-proven): the one-sided mu
  clamp in `Interpolation_Control.v` (Jul-25 hdlsrc, lines 163-172): at
  underflow, mu = x<<3 but SATURATES to +1023 whenever the pre-underflow
  fractional count x ≥ 128 instead of wrapping — a one-sided limiter in the
  timing interpolator that only the counter-runs-long (negative-SRO) slip
  direction can exercise. Proving it needs a mu/underflow tap variant of
  wrap_byte_taps (netlist promotes Loop_Filter_stateP/I and the IC state
  word; straightforward follow-up).

Float control (`float_baseline_f1536` on the same coupled stimuli): +15k =
49 frames, 0 bit errors; −15k = 48 frames, 12,376 bit errors (≈ one garbage
frame, frameRecovery 0.9375). So the negative-side weakness is dominantly
fixed-point/RTL (6 corrupt frames vs float's ~1), with a small algorithmic
echo present even in the float port — consistent with a timing-chain edge
case, not a noise phenomenon.

Caveats (stated, not laundered): Jul-25 netlist generation (see above);
noiseless stimulus; all frames carry the identical ROM payload (the +32
sidelobe is a property of this frame content — hardware byte traffic varies,
so the hardware slip target may differ in offset while sharing the mechanism);
loss counted over the 46 scoreable frames (warm-up + drain-tail excluded,
identical overhead in every run, so cross-run deltas are clean).

Artifacts: `two_jup/rtl_cfo_repro/{gen_cfo_stim.m,score_rxw.py,loop_traj.py,res/*}`
(res/ = the 9 `_res.txt` register summaries). Stimuli + full tap dumps in the
session scratchpad (regenerable from gen_cfo_stim.m; ~10 MB x 9 + ~700 MB taps,
not committed).

NEXT (follow-ups, in order of leverage): (1) mu/underflow-tap wrapper run at
−15k to convict/acquit Interpolation_Control lines 163-172 in one sim; (2) same
sweep on the v3-generation netlist once an IQ harness exists for it (flagged as
new harness work); (3) if convicted, the fix is a wrap (not saturate) of mu —
one-line RTL change, then re-run this exact sweep as the regression gate.

## 2026-08-26 (evening) — Sim-repro campaign T1: capture health census; sentinel wdlog snapshots were EMPTY (path bug, fixed)

Plan: packet-error source outline + sim reproduction from captured datasets
(operator-approved; spine doc `ERROR_SOURCES_SIM_REPRO.md`).

**T1 census** (`sim_repro/health_sweep.sh` over 456 captures →
`sim_repro/capture_health_20260826.csv`, summary `sim_repro/CAPTURE_MANIFEST.md`):
**107 HEALTHY** (26 fwd / 72 rev; 98 with frames.bin) — the "only two
verified captures" premise is obsolete. Degenerate modes: 3 true #48 DDR
ramps (the known romairs, BW 2.88 MHz env≈0.999 lag 256 — gate catches them
perfectly), ~12 BW-low/no-signal, and **334 BW-wide with CLEAN envelope**
(30.7–57.3 MHz at −20 dB). The wide class is a GATE MISCALIBRATION on
low-SNR (mostly reverse) captures: the −20 dB occupied-BW measure inflates
with noise floor. −10 dB recheck (`sim_repro/capture_health_bw10_20260826.csv`):
139/334 re-enter 15–30 MHz (HEALTHY-NOISEWIDE, usable with float-decode
confirmation); 183 stay wide and remain excluded. prewedge (all 5) and
bigiq a1/a2/a4 are in the wide-excluded class; bigiq_093328_a3 (320 MB,
rev) is HEALTHY.

Tool bug found+fixed in the sweep itself: `check_capture_health.py`'s
DEGENERATE explanation text also matches the `at lag N` grep → newline into
the CSV row (31 truncated rows, repaired; `head -1` added in
health_sweep.sh).

**Sentinel evidence bug (H-6, my 08-26 morning patch was ineffective):**
all 8 banked `wdlog_*` snapshots are ZERO BYTES. Root cause:
`lock_watchdog.sh:19-20` execs its output to its own LOGFILE default
`/dev/shm/watchdog.log`, ignoring the launcher redirect to
`/dev/shm/lock_watchdog.log` — the sentinel snapshotted the latter, which
is permanently empty. Fix live (sentinel restarted 21:5x, pid 2010805):
snapshot `/dev/shm/watchdog.log` + last 40 kB of `/dev/shm/qpsk_tun.log`
per board. H-6 evidence collection is only now genuinely armed; the
watchdog-escape mechanism remains unnamed (no wedge since the fix).

**Sanity control 3 PASS:** `float_baseline_f1536('r3cap/romair_20260824_221024/pair.iq')`
→ nFrames=81 bitErrors=0 bitsScored=995652 ber=0 — reproduces the H-9
float-zero bit-exactly on this host.

## 2026-08-27 — Operator directive: E9 → FIX (deepen ByteRxFifo, sized from measurement), gate in sim, flash + A/B; root-cause the stall source separately; keep reverse distinct; check TX-side counterpart

Directive received 2026-08-27 (full autonomy, ledger reasoning). Plan of
record, in order:
1. Pin the overflow threshold (fine stall sweep 20k-150k clk, running) and
   MEASURE the real stall length on hardware traffic from the CP1 fslog
   (per-frame fabric word count on corrupt frames ⇒ words dropped ⇒ stall
   duration = (dropped + 64) × word interval), not from the sim guess.
2. Size the FIFO = worst-case measured stall × margin; report words + ms
   of cover + BRAM cost + timing before committing to a build.
3. Patch ByteRxFifo depth in the FLASHED lineage netlist (patch_*.sh
   pattern → s1_rtl_fifoN), gate with the same captured-stall harness
   (cadence 2 for the flashed generation): previously-failing 100k/300k
   cadences must be fully absorbed before any flash.
4. Vivado build on the lab build host (nemo has no Vivado), restore point,
   flash 148 (forward RX side) under the standing rails, A/B vs the
   comb-present image on the same forward capture protocol; baseline to
   beat = 13.2-13.4 % (three legs). One attempt; no retry loops.
5. Separate deliverable: NAME the stall source (8-frame cadence,
   M-independent, ~0.4 ms) — host DMA arming / axi_dmac inter-transfer /
   descriptor gap / IRQ latency — from host code + fslog + framelog
   timing.
6. Write-up keeps reverse (signal-level, 16 dB) distinct; audit TX-side
   byte-plane FIFOs for the same K5-era sizing assumption.

### 2026-08-27 ~11:0x — Measurements for the FIFO sizing (item 1)

**Sim threshold (fine sweep, singles_reread, Jul-25 netlist, cadence 4,
stall every 16 frames... [period 8 frames used in the harness]):** 50k clk
(0.20 ms) fully absorbed; 70k clk (0.28 ms) → one frame truncated to
185/186 words (6 words lost); 100k → 156/157 (35 lost); 150k → 107/108
(84 lost); 300k → two frames. Dropped words = (L − ~60k clk)/1,030 clk;
**overflow threshold ≈ 0.25 ms**, i.e. the 64-word FIFO exactly
(1 word/1,030 clk @ 245.76 MHz composite = 64 words ≈ 0.27 ms).

**Hardware, live 148 (BEATFIX v3, +20k LO, idle filler, read-only
register polls, two windows 11 s + 21 s):** the ByteRxFifo overflow
counter 0x1B0 (dropped words, drop-newest) advanced 190 words / 11.0 s and
935 words / 21.05 s (**≈17-45 dropped words/s**) while packets ran at
1,241 f/s and the daemon's crc_drop advanced **3,705 / 21 s ≈ 176
frames/s (14 % of frames)**. Each sim overflow event drops ≥6 words, so
FIFO overflow can account for at most ~7 events/s of today's ~176
corrupt frames/s — **on today's operating point the 64-word FIFO overflow
is a MINOR contributor to the live forward loss**; the dominant class on
the +20k rig is something else (E5 deletion episodes are the standing
candidate; a fresh framelog leg will classify it). This does NOT
contradict the 08-12 comb finding (stock LO, loaded link, 84 % boundary
class with a measured 16-frame transfer cadence) — but it means the FIFO
fix must be A/B'd on the SAME protocol as the 13.2-13.4 % baseline, and
the expected gain is bounded by the boundary-class share on that
protocol, not by today's idle 14 %.

**Cadence correction:** framelog inter-event intervals on 08-12 forward
runs peak at **12.85 ms = 16 frames = one -M16 transfer** (singles_reread,
cp1_verdict2, accept_160833_r1), and on -M32 reverse runs at 26 ms = 32
frames. LOSS_LEDGER's "8-frame comb" was the half-period from counting
doubles; the stall is **once per S2MM transfer** (M-dependent), which
names the source class: the inter-transfer turnaround of the queued
axi_dmac S2MM engine (item 4, investigation continues).

### 2026-08-27 ~11:5x — FIFO sizing decision (item 1) and fix implementation path (item 2)

**Depth chosen: 4096 words (64× the current 64).** Reasoning:
- Measured overflow threshold on the real netlist: 64 words = 0.25 ms of
  backpressure (fine sweep: 0.20 ms absorbed / 0.28 ms truncates).
- Measured stall population on real traffic (08-12 framelogs, LOSS_LEDGER
  classes = truncation depth): singles (stall 0.25–1.07 ms) 72 % of comb
  events, doubles (1.07–1.9 ms) 26 %, comb-flagged mid-gaps of 3–20 frames
  (up to ~16 ms) 1.8 % of events but 5.9 % of lost frames. The largest
  observed comb-cadence stall is therefore ≈20 frames ≈ 16 ms.
- Cover at 4096 words = 4096 × 1,032 clk / 245.76 MHz = **17.2 ms ≈ 21
  frames**: absorbs every observed comb-cadence stall including the
  20-frame tail; margin = **69× the measured threshold, ~1.1× the largest
  observed stall, 9× the double-class ceiling**. Going to 8192 (34 ms)
  buys only the unobserved tail at 2× the BRAM; 2048 (8.6 ms) would leave
  the 11–20-frame mid-gap tail (≈0.2 pp) uncovered. 4096 is the smallest
  power of two that covers everything observed.
- Resource: the generated FIFO is a 64×72 FLOP array (impossible to grow
  at 78 % FF utilisation: 110,251/141,120 CLB registers on xczu3eg). The
  replacement is a synchronous-read simple-dual-port array with a
  fall-through output register → Vivado infers **8 × RAMB36 (4096×72)**;
  BRAM utilisation goes 59/216 → 67/216 (31 %). Timing: a BRAM read +
  small mux in the 30.72/122.88 MHz byte domain — no risk; verified by
  the impl timing summary before flash.
- Implementation: hand-written drop-in `jupiter_240k5_byte/rxfifo_bram/
  ByteRxFifo.v` (same ports, same delay chains, same SOF-prime guard,
  same drop-oldest+ovf@0x1B0 semantics, parameter DEPTH) injected into
  the BEATFIX v3 build tree (hdlsrc + packaged ipcore zip + extracted
  ipshared copies, the tmr_attr_inject pattern) and re-run through the
  Vivado completion step only — so the image differs from fe5bd8a4fe19 in
  exactly one module. No MATLAB regeneration → no generation drift.
- Gate before flash: Verilator harness `sim_byte_stall.cpp` +
  `wrap_byte_bf2.v` against the flashed generation (s1_rtl_beatfix3,
  cadence 2), original vs replacement, on singles_reread air data:
  (a) no-stall rxw byte-exact; (b) stalls of 0.41 / 1.22 / 8 / 20 ms at the
  real 16-frame cadence: original truncates, replacement must lose zero
  frames up to 17 ms and degrade gracefully at 20 ms.
Sizing is from measurement + stated margin; the ONLY unmeasured input is
the true stall-length distribution on today's rig (0x1B0 says overflow
is currently rare at idle: 17–45 words/s), which the A/B protocol will
resolve by comparing 0x1B0 deltas on both images under the same load.

### 2026-08-27 ~12:0x — Stall-source investigation (item 4): what the host/daemon evidence says so far

- Comb cadence = one event per S2MM transfer (16 frames at -M16, 32 at
  -M32; see above). The 08-12 comb runs (singles_reread, cp1_verdict2,
  accept_rxq_*) ran **`RX queued-request mode ON` (QPSK_RX_QUEUED=1, 2
  areas)**: the next transfer is pre-queued in hardware, "no reset between
  transfers" — yet the per-transfer stall was present. Today's rig (and
  every run since the 08-23 bring-up default) runs **RXQ=0**: the legacy
  multi mode that RESETS the S2MM engine and re-arms it from the host
  after every transfer (`rx_arm`: CONTROL 0/1 + 24 KB non-cacheable
  `carve_zero` + submit, on completion detection by a 60 µs-nap poll loop
  whose worst iteration measured 4.1 ms, `loop_over2ms` ≈1.6/s).
- Candidate sources, in order: (1) host re-arm latency in RXQ=0 mode
  (engine dead from completion until the host resets+resubmits); (2) in
  queued mode, drain-then-submit lateness with 2 areas (the completed
  area is re-queued only after its drain — `rxq_engine_gaps` witness);
  (3) an axi_dmac-internal inter-transfer switch that deasserts tready
  (would survive both host fixes).
- Discriminator legs queued behind the baseline on the same protocol
  (`capture_r3.sh A -d 68 -k`, +0x1B0/0x104 polls during each leg):
  `rxq1` (RXQ=1, 2 areas) and `rxq1a4` (RXQ=1 + QPSK_RX_AREAS=4, re-arm
  decoupled from drain). Comb gone in rxq1a4 but not rxq1 → (2); gone in
  both → (1); present in both → (3). 0x1B0 Δ/transfer quantifies the
  residual stall on each.

### 2026-08-27 12:0x — A/B BASELINE (comb-present image fe5bd8a4fe19 on 148, fixctl=3, RXQ=0 default), forward saturated protocol `GATE_DIR=A capture_r3.sh A -d 68 -k` ×3, scored `accept_analyze.py` (live windows, drops in denominator)

    r1 fifobase_20260827_115224: PER=13.975% (12421/88882)  CP95UL=14.204%  bins 1:3019 2:1851 3-4:1635 5-20:59
    r2 fifobase_20260827_115610: PER=13.927% (12533/89993)  CP95UL=14.155%  bins 1:7408 2:1937 3-4:291  5-20:27
    r3 fifobase_20260827_115959: UNUSABLE — WEDGED (live 14 s of 45 s; the
       known hourly delivery-wedge class, not retried per directive)

Comb cadence in today's framelogs: crc-fail inter-event median 13.10 /
13.65 ms (= 16-17 frames = one -M16 transfer), ~5,000 events per 68 s leg
— the loaded-link loss is the transfer-boundary comb, exactly as on 08-12
and 08-25 (13.2-13.4 %). **Baseline to beat: 13.9-14.0 % PER, CP95UL
14.2 %** (two legs, ~179k live frames). IQ from these legs is the
expected BEATFIX ramp (no tap) and is not used; framelogs are the
instrument. Note the contrast with the idle 0x1B0 measurement earlier
(overflow rare at idle): the per-transfer stall is LOAD-dependent, which
already points at the host side of the re-arm rather than the DMAC.

### 2026-08-27 12:2x — Stall-source discriminator legs (item 4): host re-queue timing EXCLUDED; queued mode halves the comb; residual per-transfer stall is inside the S2MM transfer switch

Same protocol as the baseline (`capture_r3.sh A -d 68 -k`), comb-present
image, one leg each:

| RX mode (148 daemon) | PER | CP95UL | bins 1 / 2 / 3-4 | 0x1B0 dropped words per transfer (live poll) |
|---|---|---|---|---|
| RXQ=0 reset-per-transfer (deployed default), baseline ×2 | 13.93 / 13.98 % | 14.2 % | 3019-7408 / 1851-1937 / 291-1635 | (not polled) |
| RXQ=1 queued, 2 areas | **8.72 %** (8015/91868) | 8.91 % | 3907 / 1714 / 107 | ≈1.1 |
| RXQ=1 queued, **4 areas** (re-arm decoupled from drain) | **8.75 %** (7876/90015) | 8.94 % | 3832 / 1639 / 124 | ≈0.6 |

Reading: (a) the host's reset+re-arm in RXQ=0 mode adds ≈5.2 pp
(13.95 → 8.7 %) — that part IS host re-arm latency and is fixable today
by a daemon default (RXQ=1); (b) decoupling re-queue from drain (4 areas)
changes NOTHING → candidate (2), drain-then-submit lateness, is
EXCLUDED; (c) the residual comb (≈63 events/s ≈ 0.8 per transfer, ~1
dropped word per transfer at 0x1B0) persists with the next transfer
pre-queued in hardware → the residual tready-low gap is inside the
axi_dmac S2MM transfer switch itself (EOT/SOF-sync handling), duration
just over the 64-word cover (≈0.25-0.3 ms). One dropped word per
boundary is sufficient to produce the hardware signature (the slice
accounting shifts by a word; the transfer's X_LENGTH then ends one word
into the next frame, and the following SYNC_TRANSFER_START re-sync
discards that frame's remainder: garbage-header single, or intact-header
CRC-fail + lost pair).
**Named, to the block:** (1) host re-arm gap (RXQ=0) ≈0.3-2 ms per transfer
— 5.2 pp; (2) axi_dmac S2MM inter-transfer switch gap ≈0.25-0.3 ms per
transfer — the remaining 8.7 pp. Not named to the cycle: the DMAC's
internal reason for the ~0.26 ms tready-low (candidates: EOT write-burst
drain to DDR before the queued descriptor's SOF-sync arms; the W0x5 SOF
prime). That needs an ILA on tready at the boundary or an axi_dmac
RTL sim — parked as the follow-up to the FIFO A/B. The FIFO deepening
absorbs both (1) and (2) regardless of the exact DMAC cause, which is
why it remains the robustness fix; RXQ=1 is a zero-cost host mitigation
worth defaulting independently.

### 2026-08-27 12:2x — FIFO-4k image build LAUNCHED (Vivado-only completion of the cloned BEATFIX v3 tree)

`rxfifo_inject.sh jupiter_byte_rxfifo4k_build 4096` replaced all 6 copies
of `TxRxCompo_ip_src_ByteRxFifo.v` (loose hdlsrc, both ipcore dirs, both
packaged zips, the extracted ipshared/973a copy Vivado synthesizes) and
verified the marker; `build_rxfifo_image.sh` runs `complete_byte_t8.tcl`
(reset synth_1/impl_1 → synth → impl → bitstream → bootgen) in the clone.
Reasoning for launching the BUILD before the sim gate has finished: the
build takes ~3-4 h and produces a file, nothing more; the directive's
gate is on FLASHING ("sim must show the comb gone before anything is
flashed"), which stays hard-gated on the Verilator result. If the gate
fails, the image is discarded unflashed and the module is fixed first.
Log: scratchpad rxfifo_build.log; acceptance = fresh BOOT.BIN md5,
WNS ≥ 0, BRAM tiles 59 → ≈67, CLB registers not above 110,251.

### 2026-08-27 12:4x — FIFO-4k SIM GATE (item 2): **PASS** — comb absorbed on the flashed generation

Harness: `sim_byte_stall.cpp` + `wrap_byte_bf2.v` (wrap_byte_ce) built
twice against `s1_rtl_beatfix3` (the fe5bd8a4fe19 generation, cadence 2,
fixctl=3): original ByteRxFifo vs the BRAM drop-in (`rxfifo_bram/
ByteRxFifo.v`, DEPTH 4096, picked up by -y override, verified by symbol).
Capture: singles_reread (real air, 162 frames). Stalls at the REAL
16-frame transfer cadence (789,312 samples), phase 0:

| stall per transfer | original: frames lost vs no-stall (word lengths) | FIFO-4k: lost |
|---|---|---|
| none | 153/161 CRC-good, rxw 30,827 words | **byte-exact identical stream** (30,827 words, 153/161) |
| 0.41 ms (50k clk) | 10 lost (158-word truncations) | **0** |
| 1.22 ms (150k) | 20 lost (155/156-word) | **0** |
| 1.22 ms @ 8-frame cadence, phase 12k | 60 lost (180/346/347-word — merged frames) | **0** |
| 8.0 ms (983k) | 106 lost (141/260/261-word) | 3 "lost" = the final stall swallowing the sim's 60k-clk drain tail (end artefact; re-run with a shifted phase queued) |
| 20 ms @ 12.8 ms cadence | continuous tready-low (period < stall): 0 words both — degenerate config, not a cover test |

Pre-stated criterion — "previously-failing stall cadences fully absorbed,
no-stall stream unchanged" — **met**: 0 frames lost at every cadence that
truncated frames on the original, and the fix module is functionally
transparent (identical byte stream) without stalls. Supplementary runs
(8 ms phase-shifted; single 12 ms inside cover; single 25 ms beyond cover
to show graceful overflow) are running for the record; they do not gate
the flash decision, the build does (fresh md5, WNS ≥ 0, BRAM 59 → ~67).

## 2026-08-27 — Operator directive #2: validate QUEUED RX MODE (RXQ=1) on the full protocol, independent of the FIFO image; confirm mechanism (0x1B0 + cadence); safety/cost review; ship separately if it validates

Plan: (1) 3 forward saturated legs, current image fe5bd8a4fe19 + fixctl=3,
ONLY change RXQ=1 (`capture_r3.sh A -d 68 -k`, accept_analyze, CP95UL) —
same discipline as the 13.93/13.98 % baseline; 0x1B0/0x104 polls during
each leg; (2) comb-cadence + bin comparison baseline vs queued from the
framelogs; (3) archaeology: why RXQ=0 is the bring-up default, queued-mode
watchdog/re-arm behaviour, wedge-class interaction, 146 bidirectional
collapse interaction (one bidirectional attempt in queued mode, no retry);
(4) separate shippable write-up. FIFO A/B stays on RXQ=0 so it measures
the FIFO alone; an RXQ=1+FIFO arm afterwards tests additivity.

### 2026-08-27 12:5x — Queued-mode safety/cost archaeology (directive #2 item 4)

- **Why RXQ=0 is the default:** no recorded safety reason. `qpsk_tun.c`
  (queued-mode header): "Default OFF: legacy reset-per-transfer path
  unchanged and remains the fallback" — a conservatism default when the
  mode was added; commit e6fa5f0 (2026-08-11) already recorded "steady
  4.19 % = ~2 % DMA boundary (fixed by QPSK_RX_QUEUED, host-only)" and the
  08-12 acceptance/CP1/singles runs all ran queued (`RX queued-request
  mode ON`); the bring-up default was never flipped, and every run since
  the 08-23 bring-up (including the 13.2–13.4 % soak legs and today's
  baseline) has run RXQ=0.
- **Descriptor lifetime / error containment:** the axi_dmac natively
  queues ONE request ahead (SUBMIT latched in the regmap, handed to the
  core at SOT; per-ID DONE bitmap); each request still gates on the
  frame-sync tuser, so a mid-frame boundary re-syncs exactly as in reset
  mode. Containment is unchanged: carve_zero-before-submit keeps the
  "valid CRC = fresh slice" invariant.
- **Wedge recovery:** queued mode has its OWN no-progress watchdog
  (3.0 s engine / 10 s delivery) that re-arms via a full reset, i.e.
  degrades to legacy behaviour rather than stalling. In the 08-12 logs
  it fired exactly once per run, at bring-up before frames arrive
  (log lines 5–6, benign); in today's rxq1 / rxq1a4 legs: zero firings.
- **The 08-12 wedge fix lives in the queued path:** the drain budget
  (`QPSK_RX_DRAIN_BUDGET`, default 4; "0/3 wedges vs 6/7 unbounded") is
  implemented in `rx_pump_queued()` only. The legacy pump returns one
  slice per call, so it has no equivalent starvation loop — neutral, but
  the wedge-fix instrumentation and budget only exist in queued mode.
  The hourly sentinel wedges of 08-25/26 all occurred in RXQ=0 mode, so
  RXQ=1 cannot be implicated in that class.
- **146 bidirectional collapse (H-5b):** unknown interaction — one queued-
  mode bidirectional soak attempt (`RXQ=1 soak_bidir.sh A -d 200 -k`, no
  retry) is queued behind the forward legs to answer it directly.
- **Cost:** none in fabric (same bitstream); host CPU unchanged (the
  pump naps the same); memory: 2 areas × 16 slots as before.

### 2026-08-27 13:0x — FIFO-4k supplementary gate: cover confirmed at ~17 ms, graceful beyond

| stall config (flashed gen, cadence 2) | original lost | FIFO-4k lost |
|---|---|---|
| 8.0 ms per transfer, phase-shifted so no stall overlaps the sim tail | 105 | **0** |
| single 12 ms stall (inside cover) | 16 | **0** |
| single 25 ms stall (beyond the 17.2 ms cover) | 32 | 11 = (25 − 17.2 ms)/0.8 ms ≈ the excess only — graceful, recovers |

The end-of-sim artefact in the earlier 8 ms row is confirmed as such. Gate
verdict stands: PASS; the module's cover is exactly as sized.

### 2026-08-27 13:1x — QUEUED MODE VALIDATED on the full protocol (directive #2 items 1-3): 8.73 / 8.89 % vs 13.93 / 13.98 %; comb event rate UNCHANGED (once per transfer), per-event loss shrinks

`RXQ=1 sim_repro/ab_fifo_legs.sh rxq1full` (3 × `capture_r3.sh A -d 68 -k`,
image fe5bd8a4fe19, accept_analyze): r2 **8.887 %** (7375/82984, CP95UL
9.083 %), r3 **8.732 %** (7361/84301, CP95UL 8.924 %); r1 UNUSABLE
(mid-capture delivery wedge 12 s into traffic after a healthy bring-up —
same class as baseline r3; 1/3 wedged in each mode). Queued-mode
watchdog re-arms: 0 in all legs. Framelog cadence: 77-78 crc-fail
events/s at 12.85 ms median (one per 16-frame transfer) in queued mode
vs 74-76/s at 13.1-13.65 ms in reset mode — **the comb does not thin**;
the 3-4-frame holes collapse (1635/291 → 98/115) and 5-20-frame holes
stay rare, i.e. each boundary event loses ~1-2 frames instead of up to
4+. 0x1B0: 0 / 190 / 190 dropped words at the POLL2 points ≈ 0.8-0.9
words per transfer. Interpretation and the shippable recommendation
(RXQ default 0 → 1 in bringup_r2r3.sh) are in
`two_jup/QUEUED_RX_MODE_VERDICT.md`; bidirectional attempt pending.
Corrected cadence recorded there: once per S2MM transfer — 16 frames at
-M16, 32 at -M32; the "8-frame comb" was a half-period artefact.

### 2026-08-27 13:2x — Queued-mode bidirectional attempt: collapses at 12 s like reset mode (mode-independent, H-5b open); RXQ default SHIPPED 0 → 1 in bringup_r2r3.sh

One attempt, no retry (`bidir_rxq1_20260827_131733`): healthy bring-up,
MID_CAPTURE_WEDGE after 12 s, both directions unusable — same as 3/3 on
08-25/26 in reset mode. Queued mode is neutral for that class. With items
1-4 of directive #2 answered (validated, mechanism-confirmed, safety
neutral, no cost), the default is flipped (reversible via RXQ=0); the
FIFO A/B passes RXQ=0 explicitly for its FIFO-alone arm.

### 2026-08-27 13:2x — TRAP: the patched delivery sentinel had been DEAD since 2026-08-26 22:03

Found while checking rig health after the bidirectional attempt (148 in a
reset storm, 146 fsync 584 / wcnt 0): `sentinel.log` ends at 22:02 on
08-26. The sentinel I restarted at 21:57 was a plain `setsid nohup`
child and died with the session teardown at 22:03 — the same event that
killed the 12 sims (ledgered under background-jobs). Consequences: (a)
every "sentinel armed / wdlog evidence collection armed" statement
between 22:03 and 13:23 today was false — no wedge snapshots could have
been taken; (b) overnight the rig was unprotected (it happened to stay
up; today's legs each ran their own bring-up). Relaunched 13:23 as a
systemd user unit (`sentinel-132322.service`), which survives session
exit; verified running by exact-cmdline `ps` match (a `pgrep -f` with
the pattern in my own command line matched the wrapper shell and would
have falsely reported it alive — the standing trap, hit again).
Standing rule from here: the sentinel runs ONLY as a systemd user unit.

### 2026-08-27 13:3x — E7 at scale: reverse holes = E5 deletion episodes in the signal (bigiq_a3, 1,609 frames); reverse will not move with FIFO/RXQ; H-5a (reverse LO sign) is the cheap next lever

Details in `ERROR_SOURCES_SIM_REPRO.md` E7-at-scale. Key numbers: netlist
1534/1609 CRC-good; hardware holes at 32-frame spacing (52395/52427/52459/
52491/52522) reproduced by netlist failures at the same events (±2-frame
anchor drift, 6/7). The replay disambiguates the 32-frame cadence
(transfer boundary vs 2.5-ppm deletion period) in favour of the deletion
defect, because delivery-plane loss cannot appear in replayed IQ.

### 2026-08-27 13:4x — Flash + A/B chain ARMED (self-gating), FIFO-alone arm first

`run_flash_ab.sh` (systemd unit): waits for the build, accepts it only on
fresh BOOT.BIN with md5 ≠ fe5bd8a4fe19, WNS ≥ 0 and BRAM tiles ≥ 66 (the
FIFO must have inferred BRAM; 59 on the comb image), banks the image in
`boot_known_good/`, waits for 148 healthy, then runs
`skidfix/flash_148_rxfifo.sh` (rails: pre-flash health precondition,
on-board restore point fe5bd8a4fe19, readback verify, full bring-up,
NAK=4, two-pass reset-aware health gate, auto-rollback, no retry), then
the A/B: arm 1 = `RXQ=0` (FIFO alone vs the 13.93/13.98 % baseline), arm 2 =
`RXQ=1` (FIFO + the shipped queued default) — 3 legs each, same protocol,
0x1B0 polls. Any gate failure stops the chain; nothing is retried.

### 2026-08-27 13:4x — H-5a reverse LO operating-point sweep QUEUED behind the flash/A-B chain

Rationale: E7 at scale shows the reverse residual is the E5 deletion
defect; on forward the LO-sign/offset operating point (+20 kHz) moved the
same class 13 % → 6 %. Reverse has always run `LO_B_RX` = +2.5 kHz
off-null (bringup_r2r3.sh:55) and was never swept. Legs (one 68 s
reverse `capture_r3.sh B -d 68 -k` each, accept_analyze): default
(+2.5k), −20k (1899980000), +20k (1900020000), +40k (1900040000). Runs
only after the A/B chain releases the rig; no retries.

### 2026-08-27 13:5x — BUILD REJECTED at synthesis: Vivado could not map the drop-in FIFO to block RAM ("Infeasible attribute ram_style=block ... trying LUTRAM"); BRAM tiles stayed 59, registers 110,251 → 108,697 (the old flop array gone, the 4096×72 array went to distributed LUTRAM)

Cause (my RTL): the memory was read inside the async-reset always block
with two read addresses (mem[rd] and mem[rd_p1]) — three ports and an
async-reset data path, which no RAMB36 can implement. The chain's BRAM
≥ 66 acceptance would have stopped this image before flash; stopping the
build now instead. Fix: dedicated clock-only read port with ONE
registered read address (`ra = rd_next`), write port in its own
clock-only block, `valid` derived from a one-cycle-delayed write pointer
(`wr_q`) so a freshly written entry is presented only after the BRAM read
can see it (+2 cycles of latency at the empty→non-empty edge; the AXIS
consumer is latency-agnostic). Re-gated in Verilator (byte-exact +
stall sweep) before re-injection and rebuild.

### 2026-08-27 13:3x — v2 FIFO: re-gate running (Verilator, 5 configs), build relaunched (rxfifobuild4) after two script trips (BD-cell re-creation; marker grep). Flash/A-B chain still armed and untripped; reverse LO sweep chained behind it.

### 2026-08-27 14:0x — v2 FIFO SIM GATE: PASS (identical to v1 behaviourally)

Flashed generation, cadence 2, singles_reread: no-stall stream byte-exact
vs the original (30,827 words); per-transfer stalls of 0.41 / 1.22 / 8.0 ms
→ **0 frames lost** (original: 10 / 20 / 105); single 25 ms stall beyond the
17.2 ms cover → 11 lost (excess only, graceful). The +2-cycle
empty→non-empty latency is invisible in the byte stream. Flash gate:
satisfied for the v2 module; build #4 (v2 injected, marker fixed) running.

### 2026-08-27 14:1x — RIG STOP: 148 is OFF THE NETWORK (H-7 hard-crash class, 2nd occurrence)

Found via the sentinel's recovery bring-up hanging 28 min on `anyssh 148`:
148 does not answer ping or ssh (146 is up, `ec414d2df8bc`, load 0.2).
Timeline: bidirectional queued-mode attempt wedged at 13:17:45 (+12 s);
sentinel relaunched 13:23:22 and started a recovery bring-up 13:23:34;
148 never answered from that point. Same signature as 08-26 ~09:00
(H-7: off-network until physical power cycle; dmesg lost). Per directive
("if a board wedges, stop rather than retrying"): flash/A-B chain and
the reverse LO sweep STOPPED (not re-armed), sentinel held with
SENTINEL_STOP (it cannot recover a dead board and its bring-up hangs),
hung bring-up processes killed. Vivado build #4 continues (rig-independent).
Operator notified: 148 needs a physical power cycle; after it returns,
re-arm = `systemd-run --user … run_flash_ab.sh` (self-gating) and remove
SENTINEL_STOP. Note for H-7: both occurrences followed heavy
simultaneous-load episodes (08-26: overnight bidirectional soaks; today:
the queued-mode bidirectional attempt + immediate recovery bring-up) —
worth a persistent-journald + PMU/thermal check on 148 when it is back.

### 2026-08-27 13:55 — 148 BACK (rebooted ~13:54: `up 1 min`, image fe5bd8a4fe19, fresh dmesg — no crash record survives); sentinel released; flash/A-B chain and reverse LO sweep RE-ARMED (self-gating on build + health)

### 2026-08-27 14:2x — Build #4 synthesis: v2 FIFO IS block RAM

`system_top_utilization_synth.rpt`: **Block RAM Tile 59 → 66.5** (u_ByteRxFifo
`mem_reg_bram_0..7`, "implemented as a Block RAM"), CLB Registers 110,251 →
108,369 (the old 64×72 flop array gone). Synthesis INFO 8-7052 (no optional
output register merged) is a timing hint irrelevant at the 30.72/122.88 MHz
byte domain; the pre-impl timing gate and the routed WNS decide. Impl running.

### 2026-08-27 14:0x — Sentinel gap closed: a failed probe was a permanent no-op (post-reboot link never restored); now 2 consecutive probe failures with both boards pingable → recovery bring-up. Post-reboot bring-up launched manually meanwhile (`restore_known_good.sh`).

### 2026-08-27 14:0x — Sentinel keeper: the sentinel exits on SENTINEL_STOP (by design) and nobody relaunched it after holds; a keeper unit now relaunches it whenever the hold file is absent (2-min check, exact-cmdline match, never while the hold exists). Rig-mutex protocol unchanged: touch STOP before rig work, remove after.

### 2026-08-27 14:05 — Rig restored after the 148 reboot: ARM GATE PASS (try 1); 148 fsync 1257 / wcnt 1256 (10/12 clean), 146 fsync 1261 / wcnt 1261 (12/12). Daemons now run the shipped queued default (`RX queued-request mode ON` on 148). Sentinel running (keeper-managed). Flash/A-B chain waiting on build #4 (impl+bitstream in progress); reverse LO sweep behind it.

### 2026-08-27 14:36 — FIFO-4k IMAGE BUILT AND ACCEPTED: BOOT.BIN `e09fdb32e375` (7,203,552 B)

Build #4 (BEATFIX v3 tree + v2 BRAM ByteRxFifo, Vivado resynth):
- Routed timing: **all user constraints met — WNS +0.073 ns, TNS 0, 0 failing
  endpoints, WHS +0.009 ns** (the chain's first pass mis-parsed the report
  header as an empty WNS and stopped itself — parse fixed, re-armed).
- Utilization: Block RAM Tile 59 → **66.5** (the 4096×72 FIFO as 8 RAMB36-
  equivalents); CLB Registers 110,251 → **106,034**; CLB LUTs 48,685 →
  **43,032** (the old 64×72 flop array and its 64:1 mux are gone — the
  image is smaller than the comb image).
- Differs from fe5bd8a4fe19 in exactly one module (rxfifo_inject.sh, 6
  copies incl. both packaged zips and the ipshared copy Vivado synthesized).
Flash gate satisfied (sim PASS on the v2 module); chain re-armed at 14:36:
health precondition → rails flash → A/B arm 1 (RXQ=0) → arm 2 (RXQ=1).
2026-08-27_14:37:13 chain re-armed (4th): BRAM float compare fixed (66.5 tiles)

### 2026-08-27 16:5x — FLASH ATTEMPT 1 of the FIFO-4k image: 148 booted it (readback e09fdb32e375 verified ~14:39) and then went OFF THE NETWORK during the rails' bring-up; hung for 2 h 17 m. STOPPED, rollback armed for its return. Two confounders, ledgered honestly:

1. **My rig-mutex bug.** The reverse-LO-sweep unit waited on "chain done OR
   CHAIN_STOP in the chain log"; an earlier chain run's self-inflicted
   CHAIN_STOP (the WNS-parse trip at 14:33) released it, so `capture_r3.sh B`
   (a full two-board bring-up) started at 14:35:49 — concurrently with the
   re-armed flash (staged 14:37, 148 rebooting ~14:38). Its own bring-up
   reported "WEDGED delivery=0 f/s after 4 re-arms" and aborted. The flash
   rails' bring-up (restore_known_good) then hung on 148 from ~14:40. So
   the post-flash bring-up was NOT a clean single-actor sequence.
2. **The H-7 class was already active today on the OLD image** (13:2x, same
   no-ping signature, spontaneous return at 13:54).
Therefore this outage is NOT attributable to the FIFO image on the evidence
available — but it is also not excluded (a fabric change could hang the PS
via an AXI lock-up; the board did boot and answer ssh on the new image
before the DMA arming). Per the rails and the directive: no retry; when
148 returns, the watcher restores fe5bd8a4fe19 to /boot (backup banked
on-board at 14:37), enables persistent journald (`/var/log/journal`) so
the next H-7 leaves a record, reboots, verifies, and releases the sentinel
to restore the link on the comb image. The FIFO image is NOT re-flashed
without the operator; a clean re-attempt needs: single-actor sequencing
(all other rig units stopped — done now), persistent journald live, and
ideally a serial console on 148 to see whether the hang is a kernel
oops/AXI lock-up (image-attributable) or the power/PMU-class event.
A/B legs: none run (arm 1 never started).

### 2026-08-27 17:2x — Operator directive #3 (148 power-cycled): bring-up, close the evidence gaps, fix the self-arming bug, then a SECOND FIFO flash attempt with the same rails

Status against the directive:
1. 148 reachable 17:15; came up on the FIFO image (`e09fdb32e375`, readback),
   the armed watcher restored `fe5bd8a4fe19` from the on-board backup and
   rebooted; **readback 17:16: fe5bd8a4fe19**; link restore via the sentinel
   (queued default). Both boards idle ~30 °C.
2. Evidence gaps: journald persistence is live on 148 (`/var/log/journal`;
   it was in fact already persistent — the dead boot's journal exists and
   shows NO kernel message, see RIG_NOPING_FAULT.md); serial console: a
   passive reader is attached to `tron:/dev/ttyUSB1` (HOSTS.md's ttyACM0 is
   gone); board identity to be confirmed from the next boot banner.
3. Self-arming bug fixed: single-actor `RIG_LOCK` (sim_repro/riglock.sh)
   held by the flash chain across flash + both A/B arms; every rig runner
   refuses a foreign lock; the reverse sweep now gates on CHAIN_DONE only
   (never CHAIN_STOP); the sentinel keeper honours the lock. Audit of the
   other unit scripts: run_bidir/run_modelegs (one-shot, completed) and the
   flash chain had no OR-gating; only run_revlo.sh had the pattern.
4. No-ping fault written up as its own finding (`RIG_NOPING_FAULT.md`),
   incl. the broken fan-control on both boards (fan now forced high) and
   die-temperature polling added to the A/B legs.
Second flash attempt: armed once the link is up on the comb image and
the serial reader is confirmed — same rails, no retry; if 148 dies the
same way, STOP and leave it (journal + serial will be read on return).

### 2026-08-27 18:0x — STOP: 148 off-network for the 4th time, on the COMB image, during the sentinel's post-reboot bring-up (17:33). FIFO flash attempt 2 NEVER STARTED (health gate never passed; nothing flashed; image on 148 = fe5bd8a4fe19). All rig units stopped, sentinel held, operator notified; a forensics-only watcher pulls the dead boot's journal on return. The FIFO image is no longer a suspect for the outages (see RIG_NOPING_FAULT.md #4); the A/B remains blocked on rig stability, not on the image.

### 2026-08-27 18:3x — NO-PING FAULT NAMED (high confidence): a nemo-side `direct_reg_access` read during the ADRV9002 profile reload hangs 148's PS — a KNOWN hazard the bring-up only guarded on-board

`bringup_r2r3.sh:61-62` already records it: "CRITICAL (double-hang
2026-08-04 x2): arm_rom pkills [l]ock_watchdog+[s]tallpoll BEFORE the
profile reload -- a stale wd polling direct_reg_access across the [reload
hangs the board]". The on-board readers are killed before `arm_rom`; nothing
guarded the readers on nemo. Every one of the four outages had a nemo-side
register reader running concurrently with an arm on 148 (#4: my chain's
60-s health poll — its `anyssh 148 DRA=…` was in flight 3 s before the
silence; #3: the stray reverse-sweep capture's probe during the flash-rail
bring-up; #2: my rig-recovery waiter's health probes during the sentinel
recovery; #1: a flash-rail gate). Forensics of #4 (persistent journal):
zero kernel messages after boot, userland log stops 3 s after the
profile command's ssh session closed — the instantaneous-hang signature
of an AXI read that never completes. Die temperature irrelevant (28.7 °C).
Countermeasure shipped: `sim_repro/no_arm_inflight.sh` — every nemo-side
reader (`health_probe_reset_aware.sh`, the A/B polls) refuses to run while
a bring-up/arm/capture is in flight on this host; combined with the RIG_LOCK.
The single-actor bring-up now running (sentinel held, keeper off, no
polls) is the first test of the countermeasure; the flash attempt follows
only if it completes with 148 alive.

### 2026-08-27 20:29 — Countermeasure test #1 PASS: single-actor bring-up with no concurrent register readers — ARM GATE PASS (try 1), 148 fsync 1257 / wcnt 1257 (12/12 clean), 146 1260/1260 (12/12), 148 alive throughout. SECOND FIFO FLASH ATTEMPT ARMED (flashab6): same rails; the chain holds RIG_LOCK for flash + both A/B arms; all probes/polls carry the arm-in-flight guard; sentinel/keeper stay off until the chain ends (post-chain unit relaunches the keeper).

### 2026-08-27 20:3x — Near-miss ledgered: a post-chain helper keyed on "CHAIN_STOP in the log" fired on a STALE line from an earlier run (a zsh glob error had aborted the log cleanup), released RIG_LOCK for ~7 s and relaunched the keeper at 20:29:29. No harm: SENTINEL_STOP was still present so the keeper launched nothing, and the chain re-took the lock at 20:29:36. Helper stopped; replaced by one keyed on the chain UNIT's lifetime. Rule: never key on log-text tokens that persist across runs.

### 2026-08-27 20:39 — FIFO FLASH ATTEMPT 2: booted, readback OK, **ARM GATE PASS (try 1) — 148 SURVIVED THE ARM on the FIFO image** (countermeasure test #2 pass); then the legacy `nakstat=4` rail fired and the rails rolled back to fe5bd8a4fe19 (no retry). The same rail reads nakstat=0 on the rolled-back comb image too, i.e. it is a HOST-DAEMON fingerprint (today's capture legs rebuilt qpsk_tun on 148 from source), not an image property — a stale rail from the skid-fix era. No health-gate or A/B data was produced. 148 alive throughout.

### 2026-08-27 20:4x — Rail corrected, ATTEMPT 3 ARMED: the `nakstat=4` constant (a string count in the on-board qpsk_tun binary, `restore_known_good.sh:64`) is replaced by "post-flash daemon fingerprint == pre-flash fingerprint" — the integrity intent is kept (same daemon binary survives the flash) without the stale build constant that today's rebuilt daemon cannot satisfy on ANY image (it read 0 on the comb image after the rollback). All other rails unchanged (health precondition, restore point, readback, bring-up, two-pass health gate, auto-rollback, no retry). Rig at arming time: 148 fe5bd8a4fe19 healthy 1257/1257 (6/6), 146 1260/1260 (6/6). Sentinel/keeper held for the chain's duration; post-chain helper keyed on the unit's lifetime releases lock+hold and launches keeper + reverse sweep.

### 2026-08-27 20:5x — FIFO FLASH ATTEMPT 3: **HEALTH GATE FAIL on silicon → auto-rollback (no retry).** Board alive throughout.

Rails: readback OK, ARM GATE PASS (try 1), daemon fingerprint OK. Health gate
pass 1: **fsync=1256 (demod locked, packets counting) but wcnt=0,
raw_0x1C0_delta=0 — the byte plane delivered ZERO words to the DMA**; the
amendment's one re-bring-up then produced a reset storm (fsync 0, 12/12
dirty); rollback to fe5bd8a4fe19 executed. So the FIFO-4k image is
functionally broken on hardware despite the Verilator gate being
byte-exact against the original on the same flashed-generation netlist.
The discrepancy is between the sim's environment and silicon, not in the
byte stream the module produces: candidates (a) the axi_dmac S2MM
handshake ordering (tready before/after tvalid at SYNC_TRANSFER_START)
interacting with the SOF-prime guard (`rdyRun ≥ 6`) plus my +2-cycle
empty→non-empty latency, (b) the real `enb`/clk_enable pattern (the
harness ties clk_enable=1), (c) BRAM read-data register enable/reset
behaviour after the modem's 0x000 soft reset during arming. An offline
check of (a) is running (driver RDYMODE: ready low until first valid;
pulsed ready) on original vs v2. 148 survived the full arm/re-arm/rollback
sequence — the no-reader countermeasure held for a third time.
**Not retried on the rig.** The next on-rig step, if any, is a DIAGNOSTIC
flash (read 0x1B0/0x1C0/0x104 over 10 s after the arm instead of the
health gate) — operator's call, as the directive limits us to the rails.

### 2026-08-27 20:55 — Post-rollback state: 148 on fe5bd8a4fe19 (readback) but in a reset storm after the rails' rollback restore (fsync 0, 6/6 dirty); 146 healthy (1261/1261). Lock and hold released by the post-chain helper; the sentinel (keeper-managed, guarded) will recover 148 with a single-actor bring-up. The reverse LO sweep unit idles on the CHAIN_DONE token (never issued) — harmless. Offline ready-ordering gate (orig vs v2, RDYMODE 1/2) running.

### 2026-08-27 21:0x — Offline ready-ordering check: INCONCLUSIVE (my ready model is wrong for the real DMAC)

`sim_byte_stall.cpp RDYMODE=1` (tready low until the first tvalid) and `=2`
(pulsed) deliver **0 words with BOTH the original 64-word FIFO and v2** —
the SOF-prime guard (`valid` only after tready high for ≥6 cycles) deadlocks
against any consumer that waits for valid first, and the original evidently
does not deadlock on silicon, so the real axi_dmac asserts tready first (as
the W0x5 SOF-prime replication note already implied). The experiment
therefore says nothing about why v2 delivered nothing on hardware; it only
rules out "handshake ordering" as a difference between the two modules
(they are identical there). Remaining silicon-only candidates: (1) Xilinx
SDP block-RAM read-during-write on the head slot when the FIFO is empty
(v2 re-reads `mem[rd_next]` every enabled cycle, so a push to the head
address collides with that read; RTL semantics give old data and the next
cycle heals it, but a BRAM cross-port collision yields undefined read data
— if the head word is consumed on that very cycle the first word of every
burst could be corrupt; still should not yield ZERO accepted beats);
(2) the real clk_enable pattern vs the harness's constant 1; (3) reset
sequencing across the modem's 0x000 soft reset (BRAM contents and the
un-reset `rdata` register). None of these can be settled offline; the
10-second diagnostic flash (0x1B0 / 0x1C0 / 0x104 after the arm, no health
gate) would localize it to "FIFO full — valid withheld/ready never seen"
vs "FIFO empty — words never enqueued". That is the operator's call.
**FIFO A/B: NOT MEASURED** (three attempts: outage, stale rail, silicon
zero-delivery). Standing results unchanged: queued mode shipped (−5.1 pp,
forward 8.7–8.9 %), the no-ping hang named and guarded (three clean arms in
a row since), reverse = E5 deletion class.

## 2026-08-27 21:1x — Operator: "go ahead with the diagnostic flash once v3 passes the gate"

Plan of record: v3 gate (byte-exact + stall) → inject v3 into the build tree
→ Vivado resynth → acceptance (fresh md5, WNS ≥ 0, BRAM ≥ 66) → **diagnostic
flash** (`skidfix/flash_148_rxfifo_diag.sh`): same rails up to bring-up,
then a 10-second register census (0x104 packets, 0x1C0 accepted words,
0x1B0 FIFO overflow, daemon stats) BEFORE any health gate. Decision matrix:
words advancing → continue to the health gate and the A/B (arm 1 RXQ=0,
arm 2 RXQ=1); words frozen + overflow climbing → "enqueued but never
accepted" (handshake side); words frozen + overflow frozen → "never
enqueued" (write side) — both roll back, no retry. Single-actor lock,
guarded probes, sentinel/keeper held for the chain's duration.

### 2026-08-27 21:18 — v3 FIFO SIM GATE PASS (byte-exact; 0 lost at 0.41/1.22/8 ms per-transfer stalls); v3 injected (6 copies verified), Vivado build #5 launched; DIAGNOSTIC flash chain armed behind it (flashdiag-211836; sentinel/keeper held, single-actor lock, guarded probes; post-chain helper keyed on the unit's lifetime).

## 2026-08-27 21:2x — OVERNIGHT CAMPAIGN (plan approved, pre-authorised until 07:00 EST)

Track D1 (fan-control): `/usr/bin/fan-control` GPIO_CHIP 334 → 516 on both
boards (originals kept at /root/fan-control.orig), service restarted: 148
now error-free (fan gpio661 driven by the script's 73/78 °C thresholds; die
PS 29.5 / PL 30.1 °C); 146 fan control works too but its USER_LED export
(gpio530) still errors — cosmetic. Software over-temp power-off (100 °C) is
therefore active again on both boards.
Track D3 (burst census, `sim_repro/burst_census.py` over today's 13 framelogs,
~10 × 68 s legs + soaks): every >200-frame hole is either a **startup burst
(1,180–1,276 frames ≈ 1 s, at t = 0.4–2.9 s after daemon start, 1–2 per
run, delivered-corrupt)** or a wedge/collapse (13–15k frames). **Zero
steady-state bursts in ~700 s of live windows** — the "universal ~5k-frame
burst every 2–3 min" (H-4) did not occur on today's rig; either it belonged
to the reset-per-transfer/pre-08-27 configuration or needs longer windows
(the overnight sentinel-era framelogs will say). Startup bursts are the E4
TX-content class (reproduced in IQ).
Track A/B/C armed as planned: diag flash chain (unit flashdiag-211836) →
post-A/B decider (keep FIFO image only if arm-2 CP95UL < 9.083 % on ≥2 legs
and health re-passes, else rollback) → reverse LO sweep (revlo5). Track C
(E5 taps) starting offline.

### 2026-08-28 01:4x — Track C (E5 localisation): the deletion episode IS the Peak_Search "+32" false offset, and it tracks the strobe count

`wrap_byte_taps_e5.v` / `sim_byte_taps_e5.cpp` (Jul-25 gen; taps on
Preamble_Detector: Peak_Search timingOffset/done/success/newpk, Timing_Adjust
armed/offsetValid/SyncPulse). Synthetic ±15 kHz coupled:
- +15k (insertions): timingOffset at every `done` = **18**, all 49 frames;
  one sync pulse per frame; clean.
- −15k (deletions): timingOffset = 18 except **50 at frames 36 and 47**
  (+32 exactly), i.e. one frame after each corrupt episode (33-35, 44-46) —
  the +32 false latch from the 08-26 loop-trajectory analysis, now seen at
  the block. Sync pulses still one per frame (Timing_Adjust follows the
  false offset — it does not reject it).
Captured IQ (`singles_reread`): the offset mode is **4546**; after the
on-air mute (frames 84-85, −28 strobes) it steps to **4518 = 4546 − 28** and
stays there (frames 86-105+), with a **4550 (+4)** excursion at 91-93 —
the recovery transient the 08-12 record called alignment-dependent. So the
reported offset tracks the accumulated strobe deficit exactly (28 lost
strobes → −28), and a single-symbol deletion moves it by −1; the episodes
occur when that walk crosses a boundary that Peak_Search/Timing_Adjust
handle asymmetrically (+32 report only in the deletion direction — the
insertion direction never produced a non-18 offset in 49 frames).
**Fix target named to the block: Peak_Search's offset window/wrap
handling for an EARLY peak (frame shorter than the free-running 12333
count). Not patched tonight** — the exact wrap arithmetic needs the
Peak_Search search-window constants read against a symbol-accurate model
(morning item; sim harness and stimuli are in place, one RTL change + the
existing ±15k/captured-IQ A/B would settle it).

### 2026-08-28 00:2x — Build #5 (v3) REJECTED by the chain's acceptance: BRAM tiles back to 59 and WNS −0.047 ns — the v3 bypass mux inside the read assignment made Vivado infer LUTRAM again. Image 49145c6c20f3 NOT flashed. v4: bypass as a separate registered path muxed after the BRAM output register (RAM read is pure again). Self-gating pipeline launched: Verilator gate (byte-exact + 0.41/1.22/8 ms) → inject → build #6 → diagnostic flash chain (same rails), sentinel held. If the v4 gate fails the pipeline stops itself.

### 2026-08-28 00:4x — Track B: REVERSE LO SWEEP (H-5a), one 68-s reverse leg per point, image fe5bd8a4fe19, queued default, `capture_r3.sh B -d 68 -k`, accept_analyze

| LO_B_RX offset from 1.9 GHz | PER | CP95UL | bins 1/2/3-4/5-20 |
|---|---|---|---|
| +2.5 kHz (standing default) | 1.994 % (1784/89478) | 2.088 % | 142/95/75/114 |
| −20 kHz | 1.599 % (1430/89428) | 1.683 % | 58/94/75/84 |
| +20 kHz | 1.778 % (1592/89520) | 1.867 % | 61/100/75/102 |
| **+40 kHz** | **1.391 % (1258/90468)** | **1.469 %** | 62/98/79/67 |

Note the default itself now reads 1.99 % (vs 2.6–2.9 % standing) — the
queued-mode default helps reverse's host side too. The LO operating point
moves reverse by up to −0.6 pp with CP95UL non-overlap (+40k 1.469 % vs
default 2.088 %); the trend is not exhausted at +40k, so an extension leg
set (+60k, +80k, −40k) runs before any default change.

### 2026-08-28 00:49 — Track D4: the BIDIRECTIONAL SOAK SURVIVED THE FULL 236-s WINDOW in both directions (previously 4/4 collapses within 12–15 s)

`RXQ` default (queued), `GATE_DIR=A GATE_TRIES=12 soak_bidir.sh A -d 200 -k`,
single-actor (rig lock held, sentinel/keeper off, no concurrent register
readers, fan-control fixed), scored with accept_analyze:

    fwd (148 RX): PER=10.366% (28472/274672)  CP95UL=10.480%  bins 1:11659 2:4893 3-4:371 5-20:97 >100:4
    rev (146 RX): PER= 8.049% (22138/275050)  CP95UL= 8.151%  bins 1:1056  2:1207 3-4:322 5-20:172 >100:7

Reading: (a) the "146 delivery collapse under simultaneous load" (H-5b, 3/3
on 08-25/26 in reset mode and 1/1 on 08-27 13:17 in queued mode) did NOT
occur under the guarded single-actor protocol — the prior collapses are
now suspect of being the same concurrent-reader/arm interaction as the
no-ping hang (the soak's own bring-up + my polls/sentinel), or at least
not intrinsic to the load; N=1, needs repeats. (b) Under simultaneous
load both directions degrade: forward 8.7–8.9 → 10.4 % (comb singles
11.7k — the boundary class scales with load, as the E9 model predicts:
longer host drains → longer tready gaps), reverse 2.0 → 8.0 % with
burst holes (>100-frame: 7) — the reverse receiver (146) is the weaker
side under load. Deliverable: the bidirectional link is measurable
again; the standing "unmeasurable" verdict is retired.
2026-08-28_00:50:41 D4 repeat (N=2) queued behind the extension sweep: the first attempt survived; one repeat confirms whether the collapse class is gone under the guarded protocol (plan said one attempt because of collapse risk; the risk did not materialise)

### 2026-08-28 01:0x — Track B verdict: reverse LO default SHIPPED +2.5 kHz → +40 kHz (H-5a closed)

Full sweep (one 68-s reverse leg each, fe5bd8a4fe19, queued default):
+2.5k 1.994 % (CP95UL 2.088) | −20k 1.599 (1.683) | +20k 1.778 (1.867) |
**+40k 1.391 (1.469)** | +60k UNUSABLE (wedged at start — the hourly class;
+80k acquired fine so not an LO-range limit) | +80k 1.750 (1.838) | −40k
1.485 (1.582, wedge-truncated at 67 s). Every off-null point beats the old
default; +40k is best with CP95UL non-overlap against the default (1.469
vs 2.088), the pre-stated rule for a default change. `bringup_r2r3.sh`
`LO_B_RX` default → 1900040000 (reversible via env). Reverse now measures
**1.39 % delivered PER** on the standing protocol (was 2.6–2.9 % two days
ago: queued mode + LO point). The mechanism is the E5 tracking defect's
sign/phase sensitivity (same lever as forward's +20k), not SNR.

### 2026-08-28 01:06 — Track D4 repeat (N=2), now with the shipped +40k reverse default in the bring-up

    fwd (148 RX): live 55 s/87 s [wedge-truncated]  PER=8.679% (4324/49824)  CP95UL=8.929%
    rev (146 RX): live 87 s/87 s                    PER=1.794% (1604/89408)  CP95UL=1.883%

No collapse (N=2 under the guarded protocol; the forward window was cut by
a delivery wedge at 55 s — the hourly class, handled by the harness). The
reverse leg under simultaneous load dropped from 8.05 % (attempt 1, old
+2.5k) to **1.79 %** with the +40k default — the LO point holds under load;
forward 8.7 % under load (10.4 % in attempt 1). Bidirectional link state
today: fwd ≈ 8.7–10.4 %, rev ≈ 1.8 %.
2026-08-28_02:31:35 chain re-armed (flashdiag3-023135): build #6 accepted (e45df7741369, WNS +0.230, BRAM 66.5); previous arm-up timed out because the held sentinel could not recover a reset storm during the 2-h build wait -- the chain now restores the link itself (single actor, guarded)

### 2026-08-28 02:5x — DIAGNOSTIC FLASH (v4 image e45df7741369): DECISIVE — words are ENQUEUED but NEVER ACCEPTED

Rails: readback OK, fingerprint OK, **ARM GATE PASS (try 1)** (148 alive;
4th clean arm under the guard). 10-s census after bring-up:
`packets_delta=5046  words_delta=0  ovf_delta=879462` → the demod delivers
frames, the serializer enqueues every word into the FIFO (the overflow
counter climbs at the full word rate), and NOT ONE word is accepted at the
AXIS pins. DIAG_VERDICT = handshake side: `valid` withheld or `tready` never
high. Rollback to fe5bd8a4fe19 executed (rails; no retry).
What the RTL says must be true for that: `pop = valid_i && ready_1` never
fires with the FIFO full, i.e. `rdyRun` never reaches 6 — `ready_1` is not
seen high for 6 consecutive `enb` cycles on silicon — although the original
module carries the identical guard and works. The one remaining structural
difference is the 2-cycle later `valid` (write-pointer delay `wr_q`) at the
empty→non-empty edge; if the axi_dmac only holds tready high for a bounded
window after its SOF prime unless a valid beat arrives, the original's
same-cycle valid catches that window and mine misses it — testable, not
provable offline (my ready models are wrong for the real DMAC).
**Decision: no 4th flash tonight** (rails/directive). Built instead: v5
DEBUG = v4 with the handshake state exposed on AXI 0x1B0 ({rdyRun, ready_1,
valid_i, ready, stateControl, enb, nonempty, byp_sel, ovf!=0, wr, rd}) so a
single register read on the next (operator-approved) flash pins the dead
side in 10 s. Build-only pipeline launched (gate → inject → Vivado #7).
FIFO A/B: still NOT MEASURED.

### 2026-08-28 03:0x — H-6 (wedge classes) from the first two REAL sentinel snapshots

**Snapshot 13:23 (queued-mode bidirectional wedge, 148):** the on-board
`lock_watchdog` logged nothing for 4 min after starting — its criterion
(rstcs/packets/level) is demod-level and the demod was fine — while the
daemon showed `dma_rx_ok` and `idle_rx` FROZEN with `crc_drop` climbing
~2.2k per stats interval and `tunA_rx` frozen: **a delivery-plane wedge:
the RX pump keeps reading slots that all fail CRC; nothing is delivered.**
The daemon's own 10-s delivery watchdog ("no progress … re-arming") did
NOT fire either (no such line in the tail). Watchdog-invisible by design;
only the sentinel's delivery-rate probe catches it. Source check of the
daemon watchdog path follows.
**Snapshot 20:55 (post-rollback reset storm, 148):** the watchdog DID see it
(NOT-LOCKED #1/#2 every cycle: drstcs ≈12.7k per 5 s, packets ≈5k per 5 s)
and issued three FULL RE-ARMs (0x000 soft reset + re-select + rstCS
double-tap) that changed nothing — a carrier-reset storm after a reboot is
not cleared by a fabric re-arm; it needs the radio profile reload the
sentinel's bring-up does. So the "watchdog escape" has two named
mechanisms: (a) delivery-plane wedges are outside its detection; (b) reset
storms are inside its detection but outside its remedy. Both are handled
by the sentinel; the on-board watchdog needs (a) a delivery criterion
(0x1C0 word-count rate) and (b) an escalation to profile reload after N
failed re-arms — host/script changes, no fabric.

### 2026-08-28 03:5x — H-6 daemon-side cause found and fixed (source), deploying

`qpsk_tun.c rx_q_on_complete()` stamped `rx_q_delivered` on EVERY completion
(`rx_q_progress = rx_q_delivered = rx_t0`), so the "completions but NO
DELIVERY" 10-s watchdog could never fire while the engine kept completing —
exactly the 13:23 snapshot (crc_drop climbing, dma_rx_ok frozen for minutes,
no re-arm). The 08-15/08-17 notes describe splitting the two clocks; the
split had been lost in this path. Fix: stamp only the engine clock there;
`rx_q_delivered` is stamped solely where a payload frame reaches the host.
Deploying to both boards (on-board gcc, old binary kept as
`qpsk_tun.pre_h6`) under the rig lock, then a single-actor restore and
guarded probes. On-board `lock_watchdog` improvements (delivery criterion
via 0x1C0 rate; escalation to profile reload after N failed re-arms) are
left for the morning — the sentinel covers both cases meanwhile.

### 2026-08-28 02:55 — Deploy trap: the documented on-board daemon build (`qpsk_tun.c qpsk_frame.c qpsk_uio.c`) no longer links — the current daemon needs `qpsk_seq.c` and `qpsk_ber.c` too (capture_r3.sh:128 has the right list). First deploy aborted safely (old binary kept); deploy script and `docs/setup-prebuilt.rst` corrected; redeploying.

### 2026-08-28 03:00 — H-6 daemon fix DEPLOYED to both boards (BUILD_OK 146 + 148; old binaries kept as qpsk_tun.pre_h6), single-actor restore: 148 fsync 1255 / wcnt 1255 (12/12), 146 1242 / 1241 (12/12); queued default active. The delivery watchdog ("completions but NO DELIVERY", 10 s) can now fire; its first real firing will show up in the daemon log as `rx_queued: completions but NO DELIVERY for 10.0s -- re-arming`.

### 2026-08-28 03:5x — H-6 fix v1 was WRONG on an idle link (self-inflicted): corrected (v2), redeploying

The 03:46 sentinel snapshot shows the deployed daemon re-arming every 10 s
("completions but NO DELIVERY … recovery #295") from 03:00 onward: v1
stamped `rx_q_delivered` only on PAYLOAD frames, and an idle link carries
none, so the watchdog treated healthy idle delivery as a stall and reset
the engine every 10 s (each reset costs frames; the 03:46 wedge the
sentinel recovered is probably induced by it). Retracted. v2 stamps on any
validly decoded frame (payload or idle). The 13:23 wedge signature it was
meant to catch (crc_drop climbing, NO valid frames at all) still trips it.
Redeploying both boards (v1 binary kept as qpsk_tun.h6v1); acceptance =
zero "NO DELIVERY" re-arms in the first 2 min of an idle link.

### 2026-08-28 03:51 — H-6 fix v2 applied (queued pump: idle frames stamp `rx_q_delivered`), committed 5b6eea0, redeploying (deployh6d). Process note: the first v2 edit failed its own assertion and a deploy of the unchanged v1 binary was launched before I noticed — stopped within a minute (lock released, no restore ran). Acceptance for v2 = zero "NO DELIVERY" re-arms in the first 2 min of the idle link.

### 2026-08-28 03:58 — H-6 fix v2 ACCEPTED: 0 "NO DELIVERY" re-arms in the first ~4 min of the idle link (idle_rx 314,574 delivered, crc_drop 38,970 ≈ the normal comb share), both boards 12/12 clean post-deploy. The delivery watchdog is now live and correct: it fires only when completions continue with NO validly decoded frame for 10 s (the 13:23 signature).

### 2026-08-28 04:04 — v5 DEBUG image BUILT and accepted: `602b26c25c35`, BRAM 66.5, routed timing in the ledger line below; banked as boot_known_good/BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35. NOT flashed (morning item, operator go). Diagnostic read recipe: after `restore_known_good.sh`, `echo 0x1B0 > DRA; cat DRA` → bits [31:24] rdyRun, [23] ready_1, [22] valid_i, [21] raw ready, [20] stateControl, [19] enb, [18] nonempty, [17] byp_sel, [16] ovf!=0, [15:8] wr, [7:0] rd. Expected on the dead read side: nonempty=1, valid_i=0 with rdyRun<6 (tready never sustained) or valid_i=1 with ready_1=0 (DMAC not accepting).
v5 DEBUG routed timing: **WNS +0.244 ns, TNS 0, 0 failing endpoints** (all constraints met); BRAM 66.5 tiles.
2026-08-28_06:34:38 Operator go: v5 DEBUG diagnostic flash (602b26c25c35) launched as flashdiag5-063438

### 2026-08-28 06:40 — v5 DEBUG FIFO image (602b26c25c35): **THE BYTE PLANE DELIVERS ON SILICON — HEALTH GATE PASS (try 1)**

Rails: readback OK, ARM GATE PASS (try 1), fingerprint OK. 0x1B0 debug word
(decoded with `sim_repro/decode_fifo_dbg.py`): sample 1 (before the DMA was
armed) rdyRun=0, ready_raw=0, nonempty=1, wr=200 rd=33 — FIFO filling
against a low tready, as expected pre-arm; samples 2–5 (armed) **rdyRun=255,
ready_raw=1, ready_1=1, nonempty=0, wr==rd** — tready continuously high,
FIFO drained, words flowing. DIAG_10S: **packets 13,491 / words 2,576,482 /
10 s** (full rate), health gate pass 1: fsync 1259 / wcnt 1259 / 12 of 12
clean / raw 0x1C0 delta 3,298,696. (`OVF_WITNESS` on this image is the debug
word, not a drop count.) The chain is proceeding to the A/B: arm 1 `RXQ=0`
vs 13.93/13.98 %, arm 2 `RXQ=1` vs 8.73/8.89 %.
Open question ledgered honestly: v5 differs from v4 (two dead attempts:
health-gate wcnt=0 at 20:4x, census words=0 / overflow +879k at 02:4x) only
by the debug mux on the `ovf` output. Either those v4 measurements were
corrupted by the arm-gate's counter resets (0x104/0x1C0 restart on the
double-tap; the v5 census shows the same resets in its first samples), or a
build-to-build implementation difference (CDC on `tog`/`ready`?) — to be
settled by re-flashing v4 later under the same census, NOT tonight.

### 2026-08-28 07:01 — FIFO A/B VERDICT: **4096-word ByteRxFifo does NOT reduce the forward comb. E9 mechanism corrected.**

148 on v5 (`602b26c25c35`), 146 unchanged (v_endh). `sim_repro/ab_fifo_legs.sh`,
78-s legs, drops in the denominator, CP95UL Clopper–Pearson.
- Arm 1, FIFO alone (`RXQ=0`): r1 **14.181 %** (11072/78077, CP95UL 14.428), r3 **14.139 %**
  (11045/78116, CP95UL 14.386); r2 UNUSABLE (wedged after 10 s of 39, sentinel-recovered — one H-6 wedge during the arm). Comb image same mode: 13.93/13.98 %.
- Arm 2, FIFO + queued (`RXQ=1`): r1 **8.625 %** (6733/78065, CP95UL 8.824), r2 **8.625 %**
  (6739/78129, CP95UL 8.825), r3 11.371 % (8865/77964, lag33 0.172 — a burst leg).
  Comb image queued: 8.73/8.89 %. Additivity: none; CP95UL overlaps in both arms.
**Corrected mechanism (from `qpsk_tun.c:690`, `DMA_BOUNDARY_FIX_DESIGN.md:39`, and the
v5 census):** `rx_byte_dma` is built with `SYNC_TRANSFER_START=1`, so EVERY request
(reset-mode and queued) waits for a frame-start `tuser` and discards words until it
sees one, with tready HIGH (census: rdyRun=255, FIFO empty through the switch). Since
X_LENGTH is an exact frame multiple, the next frame's tuser word passes inside the
DMAC's EOT→SOT handoff and that whole frame is discarded — one frame per transfer
boundary (1/16 ≈ 6 pp at −M16, the bulk of the 8.7 % queued residual); reset mode
adds the host re-arm window on top. The sim stall model (tready LOW) reproduced the
same signature — the signature is boundary-truncation either way — so the sim could
not discriminate buffering-vs-discard; only the silicon A/B could, and it did.
Buffer depth can never help a discard. E9 verdict cell → "delivery plane, axi_dmac
sync-start discard at the transfer handoff; FIFO-depth fix REFUTED on silicon".
**Fix candidate for the operator (Option E):** gate `tuser` in the fabric like TLAST
already is (`byte_ctrl_gpio` bit): host syncs the FIRST transfer, then turns sync off;
alignment held by exact X_LENGTH + the 4096-word FIFO (which becomes useful exactly
here). Fabric edit + ~2 h build + a one-bit host change after first SOT. Shelved
alternatives: cyclic (reader wedge on air, 08-15), `SYNC_TRANSFER_START 0` (needs an
offset-tolerant parser).
**Rig:** 148 LEFT on v5 (gate-passed, PER identical to the comb image, debug 0x1B0).
Not auto-rolled back: a reboot is nonzero H-7 risk for no measurable benefit —
operator decides (rollback `fe5bd8a4fe19` banked on-board + repo). Lock/hold released
07:00:38, sentinel ok 1153/s.

### 2026-08-28 08:20 — Parallel path: DMAC-boundary probe on hardware (no RF) + real-DMAC sim

Operator direction: test the DMAC interfacing directly on hardware with NO over-the-air data,
repeatable and controllable. Findings while setting up:
- The v5/beatfix3 lineage ALREADY carries the RX-seam injector `qpsk_traffic_gen_rx` v1
  (`tgen_rx_ctrl_gpio` @0x9D410000) and `tx_checker` — so 148's current image has an
  RF-free byte source at the exact fabric→DMAC seam. v1 only paces per FRAME (burst + gap);
  the 08-18 "zero loss at 620/1229 f/s" results were bursty streams where the host re-arm
  and the DMAC handoff fit inside the idle gap — they never exercised the modem's
  CONTINUOUS word cadence (191 words/frame, one every ~545 clk), the case in which a
  sync-gated transfer handoff must discard a frame.
- Injector v2 (`rtl_sim/qpsk_traffic_gen_rx.v`, v1 kept as `_v1.v`): `ctrl[31:16]` word_gap
  (word period = word_gap+10 clk; 535 → modem cadence), `ctrl[2]` user_mask (tuser forced 0
  toward the DMAC for pass-through AND generated streams = Option E probe), witness counters
  `acc_beats`/`acc_user` (post-mux, post-mask = exactly what the DMAC accepted) on a new
  all-inputs gpio @0x9D430000/+8. TB: `tb_tgen_rx_v2.v` PASS, v1 TB gate still GREEN.
- Image: `jupiter_byte_dmacprobe_build` (clone of the v5 project; `resynth_dmacprobe.tcl`
  deletes/recreates the module_ref cell from the v2 source, adds the witness gpio, validates,
  rebuilds). `update_module_reference` fails silently on this project (trap ledgered).
- Harness: `two_jup/dmacprobe_run.sh` (one point; arm idiom verbatim from
  `rxseam_zeroloss.sh`; witness before/after; `dmacprobe_score.py` gives PER with drops in
  the denominator, lost-slot-in-transfer histogram `(seq-1)%M`, run lengths, seam/pin
  deltas, discarded = offered − landed), `dmacprobe_matrix.sh` (6 points: bursty control;
  continuous RXQ=1 M16/M32; continuous RXQ=0; Option E mask RXQ=1; mask RXQ=0).
  Predictions pre-stated in the script comments. Chain `run_flash_probe.sh` (scratchpad,
  systemd unit): build acceptance → bank → health precondition → flash under the standing
  rails (diag census, gate, auto-rollback, no retry) → matrix → bring-up restore → release.
- Sim track (subagent, no rig): real axi_dmac RTL + host model, clean-stream first.

### 2026-08-28 08:50 — Real-axi_dmac simulation (sim track): **"sync-start discard" REFUTED; my 07:01 mechanism was wrong**

`jupiter_240k5_byte/rtl_sim/DMAC_SIM_RESULTS.md` (harness: the 27 ADI axi_dmac sources with the
exact rx_byte_dma BD parameters, the real byte-RX egress RTL from the flashed lineage incl. the
original 64-word FIFO or the v4 4096 FIFO, host model replaying qpsk_tun's RXQ=0/1 register
sequences, 1000 frames at the modem's continuous 545-clk word cadence).
- `data_mover.v:114-116`: s_axi_ready is held LOW while waiting for sync — the DMAC never
  discards. With exact 191-word frames every transfer boundary lands on a frame start:
  **RXQ=1 −M16/−M32 and RXQ=0 (re-arm ≤ 200 µs): 0.000 % (992/992), words reconciled,
  blocked-waiting-for-sync = 0.** The v5 census "tready high" was sampling active transfers;
  the 14-clk sync wait is unobservable by polling. Retract the 07:01 claim.
- The ONLY mechanism that reproduces the silicon signature (single hole, always slot 0 of the
  transfer, ~1 frame/transfer) is a ready-low interval > the 64-word FIFO (≈ 280 µs; RXQ=0
  re-arm 300 µs → 5.787 %, 57 holes all length 1 at slot 0). The v4 4096 FIFO absorbs up to
  4 ms → 0 % — **inconsistent with this morning's silicon A/B (no gain)**, so the silicon
  comb is neither a sync discard nor a FIFO overflow, unless the v5 datapath is not what was
  simulated. Frame-length jitter produces junk runs to the transfer end, not single holes.
- Option E (tuser mask) fixes nothing in this model — NOT to be built on current evidence.
- Sharp prediction for the hardware probe (v2 injector, continuous pacing, RXQ=1 −M16):
  `acc_beats` = 3056 and `acc_user` = 16 per transfer while the host still sees the comb ⇒
  the defect is DOWNSTREAM of DMAC acceptance (DDR write / host slot read timing / carve);
  `acc_beats` < 3056 with ovf climbing ⇒ the silicon inter-transfer ready-low gap is ≥ 280 µs
  and the v5 FIFO datapath needs re-verification.

TRAP (2026-08-28 10:09): `sed -i` on a log that a running wrapper is writing replaces the inode —
the wrapper keeps writing to the deleted file and its completion markers never land; two
chains waited 38 min on a finished build. Never edit a live log in place; append or
use a side file. Probe-1 image `3d75ebf1e3b5` built (BRAM 66.5, LUT 43331); markers re-appended.

### 2026-08-28 10:35 — HARDWARE DMAC-boundary matrix (probe-1 image 3d75ebf1e3b5, injector v2, NO RF): **delivery plane is LOSSLESS at the modem's cadence in every mode**

`two_jup/dmacprobe_matrix.sh` → `DMACPROBE_MATRIX_20260828_101632.txt`; 60-s points, scorer
`qpsk_tun -S` (`QPSK_SEQ_RXONLY=1`), fabric witness counters @0x9D450000 (beats/user beats
accepted by the DMAC), raw logs in `r3cap/dmacprobe_*`. Flash rails green (readback, arm gate
try 1, census 2.56 M words/10 s, health gate pass 1: fsync 1258 / wcnt 1258 / 12 of 12).

| point | offered (fabric user beats) | host scored | lost events | verdict |
|---|---|---|---|---|
| 1 bursty control (gap 200k), RXQ=1 −M16 | 37,507 | 37,490 | 0 | zero loss (08-18 reproduced) |
| 2 **continuous 545 clk/word (1,175 f/s), RXQ=1 −M16** | 70,506 | 70,906 (incl. residue) | **0** | **zero loss** |
| 3 continuous, RXQ=1 −M32 | 70,501 | 70,937 | 0 | zero loss |
| 4 **continuous, RXQ=0 reset-per-transfer −M16** | 70,539 | 70,927 | **0** | **zero loss** |
| 5 continuous, RXQ=1, tuser masked after 3 s | 4,876 (then DMAC stops accepting) | 4,373 | 0 | delivery STOPS: DMAC holds tready LOW waiting for sync (sim `data_mover` confirmed on silicon) |
| 6 same under RXQ=0 | 4,893 | 4,375 | 0 | same |

Conclusions:
- axi_dmac + DDR + host (both RX modes, both M) deliver a clean seq stream at the modem's
  continuous word cadence with ZERO loss. The 13.9 % (RXQ=0) / 8.7 % (RXQ=1) air comb is
  NOT produced by the DMAC handoff, the host re-arm gap, FIFO depth, or the host read path
  acting on a well-formed stream. E9 as "delivery-plane defect" is now confined to: a
  property of the MODEM'S OWN output stream at the seam (per-frame word count / tuser
  placement / content) that the host's slot-aligned parser turns into boundary losses —
  or the loss is upstream of the seam (decoder output already missing/corrupt frames).
- Option E (tuser gating) is dead: masking tuser halts delivery (queued and reset modes).
- The "landed/offered" line in the matrix file mixes in the pre-enable residue; the
  authoritative numbers are total ok vs offered and lost_events=0 (all points).
Next instrument (building, probe-2): `rx_seam_checker` at the decoder output — per-frame
CRC verdict + short-frame / orphan-word counters — run on the real air link.

### 2026-08-28 11:25 — probe-2 (rx_seam_checker) flashed: fabric counters UNREADABLE (bus error); host-side observation banked

Image `5fcc16603140` (WNS +0.435) boots, gates green, link fine, but the three new all-inputs
GPIOs (smartconnect M17..M19 @0x9D460000/470000/480000) return a bus error on every read;
M16 (0x9D450000, probe-1 witness) and everything below read fine. BD/hwh/smartconnect netlist
all carry the ranges; cause NOT found (trap: do not add further smartconnect master ports —
route new counters through an existing readable GPIO). Probe-3 building: counters 8:1-muxed
onto the witness GPIO ch2 (0x9D450008) with `tgen_rx gap[31:28]` (0x9D410008) as the select.
Host-side numbers from leg 1 (RXQ=1, 90 s, air link) stand on their own:
**delivered 99,984 + host crc_drop 11,645 = 111,629 frames vs 112,770 expected at 1,253 f/s —
the host RECEIVES ≈99 % of the frames; 10.3 % of them FAIL the host CRC.** The comb is
frames landing corrupt, not frames missing (consistent with E1's truncated-but-header-intact
population). Probe-3 answers whether they already fail CRC at the decoder pins.
(Leg 3 on this image used an RXQ=0 bring-up that came up degraded — delivered 2,247 vs
crc_drop 27,513 in 90 s — not citable; RXQ=0 leg repeats on probe-3.)

### 2026-08-28 12:41 — probe-3 (rx_seam_checker via muxed witness GPIO, image 686ac144563d): **the frames the host drops are ALREADY corrupt at the decoder output; a second, RXQ=0-only loss is frames vanishing inside the DUT byte plane**

`two_jup/rxchk_run.sh`, 90-s windows on the live air link (146→148), daemons normal.

| leg | decoder frames (fabric) | 0x104 | fabric crc_ok | fabric crc_fail | fabric magic_bad | short / orphan w | host delivered | host crc_drop |
|---|---|---|---|---|---|---|---|---|
| 1 RXQ=1 | 112,890 (1254/s) | 112,896 | 101,151 | 724 (0.64 %) | **11,008 (9.75 %)** | 7 / 1,330 | 99,986 | 11,696 (10.36 %) |
| 2 RXQ=1 | 112,827 | 112,834 | 102,495 | 948 (0.84 %) | **9,377 (8.31 %)** | 6 / 1,140 | 101,353 | 10,298 (9.13 %) |
| 3 RXQ=0 | **106,035 (1178/s)** | **112,661** | 95,946 | 349 (0.33 %) | **9,723 (9.17 %)** | 16 / 1,710 | 94,868 | 10,092 (9.52 %) |

Identities: (fabric crc_fail + magic_bad) / frames = 10.39 / 9.15 / 9.50 % ≈ host crc_drop /
frames = 10.36 / 9.13 / 9.52 %. Seam user beats == decoder frames (all legs). So:
1. **~9 % of frames leave the decoder with a garbage/misaligned header (magic_bad), independent
   of the host RX mode.** These are the host's CRC drops. Not the DMAC, not the host — and
   mostly not bit errors (crc_fail with a sane header is < 1 %).
2. **RXQ=0 only: decoder frames at the pins (106,035) < framesync 0x104 (112,661): 5.9 % of
   frames never reach the pins** — dropped inside the DUT byte plane under host backpressure
   (reset-per-transfer). That is the 13.9 − 8.7 pp mode difference, and the FIFO-depth story
   was aimed at this second mechanism (v5 4096 FIFO did not remove it on silicon — to be
   re-examined with the checker: frames vs 0x104 on the v5 image).
Next split (running, 148-only loopback, RF excluded): Test A daemon TX via MM2S vs Test B fabric
TGEN TX at the TX byte pins → magic_bad fraction tells whether the ~9 % garbage frames are made
on the TX byte-DMA side (host/MM2S/ByteWordBuffer) or in the modulator→demod→decoder chain.
Prior evidence favouring TX-DMA: ROM/BIST-source air run (A3) showed only 315 bit errors in 156
frames — no 9 % garbage population when the TX source is fabric-generated.

### 2026-08-28 12:55 — 148-only LOOPBACK split (`two_jup/loopchk_run.sh`, probe-3 checker): **5.13 % garbage-header frames with RF removed**

Test A (internal loopback 0x114=0, TX = 148's own daemon frames via MM2S, 60 s, twice):
frames 75,797 / 75,805 (1263/s), **magic_bad 3,890 / 3,892 = 5.13 %**, crc_fail 10 / 10
(0.013 %), short 0, orphan 0; daemon: dma_tx 93,421, idle_rx 87,8xx, crc_drop 5,5xx (5.9 %).
So more than half of the on-air ~9 % population is produced with no RF at all — inside the
TX-byte-DMA → modulator → demod → decoder → byte-out path of a single board — and it is
header garbage, not bit errors. Test B (fabric TGEN at the TX byte pins, no MM2S) did NOT
produce a measurement in two attempts: run 1 the RX DMA was unarmed (0 words at the pins,
0x104 advancing); run 2 with the daemon armed, framesync itself stopped (0x104 delta 0) —
the ad-hoc TGEN-TX + double-tap arm sequence differs from the canonical `tgen_sweep.sh`
procedure; redo B with that procedure. Link restored by bring-up afterwards.

### 2026-08-28 13:15 — **148 OFF-NETWORK (H-7 class, 5th occurrence). RIG HELD. Operator power-cycle required.**

Timeline (nemo clocks): 12:5x loopchk2 Test B (ad-hoc TGEN-TX + double-tap re-arm with the -G
daemon running) ended with framesync 0x104 delta = 0 — the modem stopped decoding; 13:07-13:09
the unit's restore bring-up: "148 rx=0 f/s" on all 8 gate tries, ARM GATE FAILED (ssh still
worked); 13:09:21 keeper relaunched by the release helper; 13:09:56 `loopchk_b` (canonical
Test B) started: no ssh command produced output — 148 was already unreachable; 13:13 confirmed
NO PING (146 pings). No register reads by nemo overlapped a known arm; the last actors on 148
were the failed bring-up's arm attempts and the on-board lock_watchdog. Root cause not
determinable without the serial console (still absent). Actions: SENTINEL_STOP + RIG_LOCK
hold, keeper/sentinel/all chain units stopped, NO power-cycle loop (standing rule). 146 is up.
Test B (fabric TGEN TX in loopback) remains NOT OBTAINED (three attempts). Test A stands.
TRAP (repeat): `pkill -f <pattern>` with the pattern in the caller's own command line killed
the hold command itself (exit 144) — use `pgrep -f "[d]pattern"`.

### 2026-08-28 13:55 — Test B obtained (148 recovered by operator power-cycle 13:44; guarded bring-up OK, health 1258/1258 8/8): **a fabric-generated TX source is WORSE than the daemon — the garbage-header frames are made inside the modem's TX byte-in → encoder path, not by the host/MM2S**

`two_jup/loopchk_b.sh` (canonical tgen_sweep.sh idiom: single loopback arm, TGEN at the TX byte
pins, `-S` scorer arms RX; probe-3 checker read at start/end of a 55-s dwell):
| TGEN gap | frames at the decoder pins | 0x104 | header-intact (crc_fail = TGEN const CRC) | magic_bad | 0x108 delta |
|---|---|---|---|---|---|
| 200000 (620 f/s offered) | 34,131 (621/s) | 68,264 | 10,723 (31.4 %) | **23,408 (68.6 %)** | +3.58 M |
| 100000 (nominal 1229 f/s) | 34,157 (621/s — the gap change did not raise the rate at the pins; filler frames emit no words: 0x104 = 2× pins) | 68,318 | 18,255 (53.4 %) | **15,906 (46.6 %)** | +3.61 M |
Host scorer (same runs): ok 6,698 / lost 6,773 / junk 36,815 at gap 200000 — matches the 08-23
TGEN-TX sweep CSVs (junk ≫ ok), so this is the standing behaviour of TGEN-through-modulator,
not a new fault.
Reading, with Test A (daemon TX via MM2S at line rate, 5.13 % bad-magic, 0.013 % crc_fail):
- Host/MM2S is NOT the source: replacing it with a fabric generator makes the header-garbage
  fraction larger, not zero.
- The ROM/BIST source on air (A3: 315 bit errors / 156 frames, no garbage population) bypasses
  the TX byte plane and feeds the encoder directly → the defect lives BETWEEN the DUT TX byte
  pins and the encoder (TX byte-in plane: ByteWordBuffer / wordFirst framing / underrun-filler
  transitions), and it is strongly dependent on the arrival pattern (line-rate daemon 5 %;
  sub-line TGEN with filler interleave 47–69 %). The "TX-side counterpart" flagged in
  Directive #1 is the target.
- Caveat: TGEN frames are unwhitened; the daemon's are whitened — a content dependence
  (long constant runs) is not excluded by this pair alone.
Next (no flash needed for the first step): reproduce in the bit-true netlist — drive the DUT TX
byte pins (wrap_byte: byte_valid/first/data, tx_data_source=byte) with (a) line-rate whitened
frames, (b) sub-line frames with underrun gaps — in internal loopback, and score the decoded
headers with the same per-frame CRC; then A/B a TX-byte-plane fix in sim before any build.
Rig: link restored, released, keeper relaunched (unit testb3). 148 on probe-3 image 686ac144563d.

### 2026-08-28 14:05 — Operator directive (netlist repro of the TX byte-in plane; rule one; FIFO-4k A/B; no builds on guesses)

Rule-one audit: no chain/sweep units running (only sentinel + keeper). The 08-27 self-arming
bug (reverse sweep released by a stale CHAIN_STOP token) is fixed — `run_revlo.sh` gates on
the chain's done-FILE plus a free RIG_LOCK and is not armed. Remaining token-gated waiters
(`run_loopchk*.sh`, waiting on a specific chain's log) are one-shot units that have all
completed; every rig unit since 08:00 has run under RIG_LOCK with the keeper stopped and a
release helper keyed on unit lifetime. hdl-dev2 does not resolve and is not in HOSTS.md —
sim work runs on nemo only (12 cores, parallel cells); flagged to the operator.
Item 3 interpretation: the FIFO-4k image was flashed and A/B'd this morning (v5: RXQ=0
14.18/14.14 % vs 13.93/13.98; RXQ=1 8.63/8.63 vs 8.73/8.89 — no gain), and 148 currently
runs probe-3 = the same v5 4096-word FIFO lineage plus instruments (gate-passed). So the A/B
is re-run as the single rig actor WITHOUT a flash/reboot (no H-7 exposure): journald made
persistent on 148 first, then RXQ=0 and RXQ=1 legs with the decoder-output checker read
after each arm (frames vs 0x104 = the RX byte-plane loss with the 4k FIFO in place).
Unit `abconfirm`, lock held, keeper stopped, release on unit lifetime.

### 2026-08-28 15:03 — Item 3 done: FIFO-4k A/B CONFIRMED (no gain) on the image the board runs, no flash; the RXQ=0 RX-byte-plane loss is FIFO-depth-independent

148 on probe-3 `686ac144563d` (v5 4096-word ByteRxFifo lineage + instruments). `ab_fifo_legs.sh`,
78-s saturated forward legs, drops in the denominator, CP95UL; journald on 148 already
persistent (`/var/log/journal`, 1.6 GB — verified).
- RXQ=1: **8.647 / 8.777 / 8.633 %** (CP95UL 8.85 / 8.98 / 8.83) vs comb image 8.73 / 8.89 %.
- RXQ=0: **14.059 / 14.149 %** (CP95UL 14.31 / 14.39), r2 wedged/unusable, vs 13.93 / 13.98 %.
Decoder-output checker windows (60 s): idle link RXQ=1 → bad-magic 6.16 %, crc_fail 0.72 %,
host crc_drop 6.81 %; right after saturated traffic RXQ=1 → bad-magic **11.57 %**, crc_fail
0.74 %, host crc_drop 12.23 % (identity holds in both; full-length whitened traffic frames
carry ~2× the garbage-header fraction of len-0 keepalives — a content and/or host-pacing
dependence on hardware, to be separated by the sim matrix); RXQ=0 → **decoder frames 71,267 vs
0x104 75,718: 5.9 % of frames never reach the pins WITH the 4k FIFO in place**, bad-magic
6.04 %, host crc_drop 6.44 %.
Budget accounting (item 5): unchanged — ≈5 % made in the TX byte plane with no RF (Test A),
over-air increment variable (≈1–7 pp today, condition/content dependent), **5.9 % inside the RX
byte plane in RXQ=0 only and NOT a FIFO-depth effect** (new: measured with the 4k FIFO),
0 in DMA/DDR/host. The RXQ=0 loss therefore sits upstream of ByteRxFifo (between framesync and
the FIFO push: serializer/word buffer under byte_rx_ready backpressure) — separate defect.

2026-08-28 16:10 — Compute node added by operator: `HDL-dev-2.local` (10.0.0.11, 8 cores, 61 GB,
Verilator 5.020, no shared FS; rsync + rebuild obj there). NOT in ~/.claude/HOSTS.md — the
canonical copy lives in picard:~/dev/infra/HOSTS.md; operator to add. Sim agent told to move
~half the TX-plane cells there (nemo was at load 17.7 on 12 cores).

### 2026-08-28 17:25 — **TX byte-in plane REPRODUCED in the netlist and localised: 16-word ByteWordBuffer runs dry on host inter-transfer silence > ~20 µs → one garbage-header air frame per event. Arrival-dependent only. Test B WITHDRAWN.**

Full write-up: `jupiter_240k5_byte/rtl_sim/TXPLANE_SIM_RESULTS.md` (cell map `txplane_runs/CELL_MAP.txt`,
raw per cell). Flashed lineage `s1_rtl_beatfix3`, loopback, daemon-identical frames via `qpsk_frame.c`,
scorer = `rx_seam_checker` semantics. 400-frame cells (370 scored):
- Continuous line rate: idle / fill / whitened idle / whitened fill / 1.02× / 1.00×+jitter → **0 %** all.
- Rate 0.95× (source silent once per ~20 transfers): **20/370 = 5.4 % magic_bad, exactly one per
  underrun** — reproduces hardware Test A (5.13 %). 0.98× → 2.6 %.
- Taps: every loss is `buf=0 avail=0 first=0 bitIdx=64` — ByteWordBuffer empty mid-frame, the
  ByteBitShifter drops to unaligned and shifts zeros for the rest of that air frame. Cover at the
  input is 2000–3500 clk (16–28 µs; `readyNext = count <= 6` wastes most of the 16 words).
  **Sizing hypothesis CONFIRMED; wordFirst framing NOT implicated (no start&&!first events, no
  short/orphan); filler-transition logic NOT a separate defect (one frame per event, no neighbours).**
- Content (whitened/unwhitened, idle/fill): no effect. **Arrival pattern only.**
- **Test B withdrawn**: the fabric TGEN emits 191-word frames while the DUT consumes 385-word
  (3080 B) transfers per f1536 air frame — two TGEN frames per air frame = format mismatch; the
  47–69 % was an instrument artefact (c09/c10 reproduce it in sim: 61.7 % / 44.7 %). The 08-18
  TGEN-TX "Layer B" inferences inherit the same caveat.
- Candidate (sim only, NOT built): ByteWordBuffer 16→64 (ready threshold 54): clean at 4500/6000/8000
  clk gaps, marginal at 15000, broken at 20000. Depth required depends on the REAL host gap
  distribution (unmeasured). Fine sweeps landing (nemo c02/04/05/07/08 to 400 frames; HDL-dev-2
  threshold sweep → `txplane_runs/hdldev2/GAPS_FINE.txt`).
Budget (item 5), stated plainly: "≈5 % TX byte plane, no RF" CONFIRMED and now mechanistic;
"host is not the source" must be read as "host TIMING is the trigger, the 16-word buffer is the
defect"; "~4 pp over air" unchanged (146's TX plane has the same defect, so the forward air number
contains 146's underrun rate + RF); "5.9 % RX byte plane RXQ=0" unchanged and STILL UNEXPLAINED
(separate defect, separate block); "nothing in RX DMA/DDR/host" unchanged.
Hardware witness BEFORE any build (operator rule): (1) host-side MM2S inter-transfer gap
histogram in the daemon (count > 20 µs per stats window) vs fabric bad-magic per window —
predicted 1:1; (2) host-only TX one-ahead queueing (`QPSK_TX_QUEUED`), which removes the silence
without touching the fabric: predicted bad-magic → ~0 on 148's checker in loopback (Test A
setup) and on air. Both are zero-build; being implemented off-rig now.

### 2026-08-28 17:00 — TXQ session (single actor, `two_jup/txq_session.sh`): host silence is NOT the trigger; idle batching breaks the fabric contract; defect B EXPLAINED (RXQ=0 host rate deficit, FIFO full)

Daemon with the `txgap` witness deployed on both boards (`-DQPSK_CARVE_2MB` required — the
first pass without it built a K5-carve daemon that refused -G; recipe fixed). Rollback binaries
`qpsk_tun.pre_txq` kept. Defect A = TX byte-in plane; defect B = RXQ=0 RX byte-plane loss.
- **A1** 148 loopback, batching off: fabric bad-magic **5.072 %** (3,896/76,810, Test A reproduced)
  while the host-side silence witness saw only 5–20 queue-empty events per 5-s window (2–4/s)
  vs ≈65 bad frames/s. **Host inter-transfer silence explains ≤ 3 % of the events — the 1:1
  prediction FAILS by 20–30×.** On air (B1) 146's witness: ~2 events/s vs ≈130 bad frames/s at
  148 — same shortfall. The ByteWordBuffer starvation (netlist-proven) is therefore triggered
  INSIDE a transfer: the MM2S read path stalling > ~20 µs mid-transfer (DDR/AXI contention;
  the RX S2MM cadence is the natural suspect and would explain the "comb at the RX transfer
  period" from a TX defect). The host has no lever on that.
- **A2** loopback, `QPSK_TX_QUEUED=5` (5 air frames per MM2S transfer, one TLAST): bad-magic
  **81 %**; **B2** on air both ends: 96.8 / 97.3 %, framesync collapsed (0x104 1.6 k/min),
  orphan words 80 k/min. The fabric's per-air-frame wordFirst/TLAST contract is violated by
  batching — mitigation INVALID, stays off (default). Nothing else host-side is left to try.
- **B1** air legacy: bad-magic 10.23 % + crc_fail 0.36 % vs host crc_drop 10.52 % (identity).
- **C — defect B witness** (RXQ=0 bring-up, 200 rapid reads of the v5 ByteRxFifo debug word on
  the probe-3 image): **200/200 samples: DMAC tready = 0, FIFO nonempty, rdyRun < 255,
  occupancy low byte uniform (FIFO full and wrapping).** In reset-per-transfer mode the host's
  drain+reset+re-arm per 16-frame transfer costs ≈6 % of air time; the 4k FIFO sits full and
  the byte plane sheds whole frames upstream of it (frames vanish cleanly: no orphan/short
  burst). A steady consumer-rate deficit cannot be fixed by FIFO depth — which is why the
  4k FIFO gave nothing — and queued mode (RXQ=1, shipped default) has no idle and no such
  loss. **Defect B explained; no fabric change needed; it is the reason RXQ=0 must not be
  used.** (Caveat: each DRA read takes ~ms; the sampling cannot see sub-ms ready pulses, but
  a full FIFO at every sample is unambiguous.)
Budget (item 5), plainly: ≈5 % TX byte-in plane with no RF — CONFIRMED, trigger re-attributed
from "host inter-transfer silence" to "MM2S read-path stalls inside a transfer" (unmeasured
distribution); ~4 pp over-air increment — unchanged (146's plane + RF; measured 10 % total this
hour); 5.9 % RXQ=0-only — EXPLAINED as host rate deficit under reset-per-transfer (moot with
the RXQ=1 default); DMA/DDR/host delivery of well-formed frames — 0, unchanged.
Next hardware witness BEFORE any fix build (operator rule): an in-fabric TX byte-in
underrun counter + max-empty-duration histogram (ByteWordBuffer `avail==0 && start` events),
snoop-only, on the probe lineage (~2 h instrument build, not a fix build). Its per-window
count must equal the checker's bad-magic count (1:1) and its duration histogram sizes the
buffer/threshold fix. Also a TX-side ILA-free cross-check: throttle the RX S2MM (e.g. -M32)
and watch whether the TX bad-magic cadence follows it.
Rig: restored to defaults (legacy daemons with the witness line, RXQ=1), released 16:57:48.

### 2026-08-28 17:30 — Cadence cross-check (148 loopback, daemon TX legacy; `two_jup/loopA_cadence.sh`): TX defect is a FIXED ~64.8/s periodic source, independent of RX -M and RXQ; defect B vanishes at -M32

| point | frames at pins | 0x104 | magic_bad | rate |
|---|---|---|---|---|
| −M16 RXQ=1 | 75,938 | 75,937 | 3,891 (5.124 %) | 64.9/s |
| −M32 RXQ=1 | 75,971 | 75,972 | 3,890 (5.120 %) | 64.8/s |
| −M16 RXQ=0 | 71,473 (**−5.9 % vs 0x104 75,939** = defect B) | 75,939 | 3,669 (5.133 % of pins) | — |
| −M32 RXQ=0 | 76,112 (**= 0x104**, defect B GONE) | 76,112 | 3,902 (5.127 %) | 65.0/s |
- Defect A: the bad-magic count is 3,890–3,902 per 60 s in every loopback run today (A1: 3,896)
  — **a fixed periodic source at ≈64.8 events/s (one per ≈15.4 ms), independent of the RX S2MM
  transfer cadence (−M16 vs −M32) and of the host RX mode.** S2MM contention is ruled out; the
  trigger is a periodic host/MM2S/fabric event with a 15.4 ms period (not the 12.85 ms RX
  boundary, not the 0.79 ms frame). The probe-4 starvation witness (episode histogram at the
  TX byte-in pins) will show the length; the period identifies the source.
- Defect B: present at −M16 RXQ=0 (−5.9 %), ABSENT at −M32 RXQ=0 — the per-transfer host
  overhead halves per frame and the reset-per-transfer host keeps up. Confirms the rate-deficit
  explanation; moot with RXQ=1.
(The framelog hole analyser rejects idle-only loopback streams — spacing not obtained; rates suffice.)

### 2026-08-28 18:30 — probe-4 (TX input-starvation witness, image 02e8c97d6181, WNS +0.048): **input starvation REFUTED on silicon; the corruption is a DUT-internal decision, and it DECAYS after the arm**

Witness = `tx_starve_witness` on the DUT TX byte-in pins (`ready && !valid` episode histogram,
max length, since boot), read via the 16:1 mux (`rxchk16_run.sh`).
- Air window (RXQ=1, legacy daemons, 60 s): 148's TX input **never starved** (all bins 0,
  max episode 0 clk since boot); decoder-output bad-magic 12.0 % (that is 146's TX + RF).
- Loopback Test A leg 1 (60 s from ~8 s after arm): **bad-magic 3,890 (5.13 %) with ZERO input
  starvation** — the MM2S always has the next word ready; the DUT itself is the throttle.
  **The netlist's input-starvation mechanism does not occur on silicon** (the sim's trigger —
  a source withholding words — never happens here). A deeper ByteWordBuffer would have been
  another wrong-block build. The witness did its job.
- Loopback leg 2 (the NEXT 60 s, same daemon, no re-arm): **bad-magic 186 (0.245 %)**, still
  zero starvation. The ~64.8/s periodic corruption is a **post-arm transient lasting ≳ 60 s**
  in loopback. Every earlier Test-A number (5.07–5.13 %) was taken in the first minute after
  the arm. On air, windows taken 27 min after a bring-up still showed ~6 % — so the air behaviour
  is not the same transient (146's TX + RF), or the transient re-triggers under real traffic.
  Time series queued: checker every 10 s for 5 min after the arm, loopback then air.
Interpretation so far: with the input always available, the only ways a garbage-header air
frame is produced inside the DUT are its own filler/underrun decision (the modulator free-runs
filler frames "on byte-FIFO underrun" — a DUT-side condition that need not be visible at the
input pins if the DUT deasserts ready itself) or a periodic alignment drop in the
ByteBitShifter/wordFirst path. The 15.4 ms period and the decay point to a beat/settling
process (host TX pacing vs fabric consumption; rx_pkt_s self-calibration; DMAC queue fill)
rather than random stalls. Budget line "≈5 % TX byte plane": mechanism now OPEN again
(location still TX byte-in → encoder; trigger unknown); numbers unchanged.

### 2026-08-28 18:45 — TIME SERIES (`two_jup/tseries_badmagic.sh`, checker every 10 s after the arm): **the "5 %" is 0.24 % floor + periodic 120-s BURSTS; the bursts exist on air too. RE-ATTRIBUTION.**

Loopback (148, own daemon TX, no RF), 5 min: floor **0.22–0.31 %** every 10-s window except
bursts at **44.5 s, 164.7 s, 284.9 s** after the arm (period 120.2 s) of **3,734 / 4,963 / 3,729**
bad frames (27–37 % of a 10-s window ≈ 3–4 s of total corruption). Host `crc_drop` steps at the
same windows; the daemon logs NO event at those times (no re-arm/watchdog). TX input witness:
never starved in any window (the per-frame `ready&&!valid` idle is 0.65–1.7 k clk, below the
3 k bin; the ep>3k column in the TS lines is the frames-count mux index, not >3k episodes —
mux index confusion in the TS script; the probe-4 chain's direct readout of all bins = 0 stands).
Air (146→148, legacy daemons), 5 min: steady **5.4–6.4 %** per-frame comb plus bursts at
**33.6 s, 153.8 s, 274.0 s** (period 120.2 s) of **4,216 / 5,438 / 4,250** bad frames.
No 120-s host timer exists on 148 (systemd timers, processes checked; fan-control polls the
ADRV9002 temperature every 1 s — not it). The bursts are common to loopback (FPGA-internal,
no transceiver data path) and air, with a fixed 120 s period starting ~35–45 s after the arm →
leading suspect: an **ADRV9002 periodic process (tracking-calibration schedule) disturbing the
SSI clock / data-valid cadence the modem runs on**. Zero-build test: disable/alter the
tracking-cal schedule via the driver and repeat the series.
**Budget re-attribution (item 5), stated plainly:**
- TX byte-in plane with no RF: **0.24 %** (was "≈5 %"; the 5 % was 0.24 % + one burst per
  60-s window). The netlist starvation mechanism is real in the model but does not occur on
  silicon; no TX-plane fix is justified for 0.24 %.
- **NEW: periodic 120-s bursts ≈ 2.5–3.6 % of frames, on BOTH loopback and air** — periodic
  component, transceiver-schedule suspect, common to both boards (146 will show the same).
- Air-only per-frame comb: **≈6 %** (single garbage-header frames at the decoder output,
  RX-mode independent) — mechanism still open; with bursts and TX plane excluded, the E5-class
  timing/SRO symbol-deletion episodes (Peak_Search +32 false offset, already localised on the
  reverse leg) are the leading candidate — a misaligned frame decodes to a garbage header.
- RXQ=0 5.9 %: explained (host rate deficit), moot. DMA/DDR/host: 0.
Forward air ≈ 6 % comb + 3 % bursts ≈ 9 % ✓ (matches 8.7–10 % measured today).

### 2026-08-28 18:50 — 120-s bursts: ADRV9002 tracking calibrations EXCLUDED (zero-build test); fan-control excluded

`run_tseries_nocal.sh`: 148 loopback, all RX/TX `*_tracking_en` set to 0 after the arm (snapshot
restored afterwards, verified). Bursts at **33.6 s, 153.6 s, 273.7 s** (3,725 / 4,169 / 3,014 bad
frames), floor 0.23–0.31 % — identical to the cals-on series. Tracking cals are not the source
(caveat: sysfs disable acts on the driver; an already-scheduled ARM cal cycle could continue —
but the burst size and phase did not change at all). fan-control: 1-s temperature poll only,
heavy path gated at 65.2 °C (die at 57 °C) — not it. No host timer at 120 s; no daemon event.
Burst phase: first burst 33–45 s after the arm, then every 120.2 s — tied to the arm, not to
boot or wall clock. Next: ROM/BIST fabric TX source in loopback (no byte plane/DMA/host TX):
bursts in 0x108/0x150 ⇒ RX-side or clock; none ⇒ TX byte-DMA side (unit `tsrom`, queued).

### 2026-08-28 19:00 — **BURSTS LOCALISED TO THE MODEM RX CHAIN (fabric-internal): ROM/BIST source loopback shows them (no byte plane, no DMA, no host TX, no transceiver data path, tracking cals irrelevant)**

`run_tseries_rom.sh`: 148 loopback, TX source = fabric ROM/BIST (0x158=0), RX DMA armed by the
-S scorer, 0x104/0x108/0x150 + checker sampled every 10 s:
| t after arm | framesync/10 s | **BIST bit errors/10 s** | carrier resets |
|---|---|---|---|
| 11.8–22.7 s | 13,550–13,593 | 561 / 510 (baseline) | 0 |
| **33.6 s** | 13,564 | **199,569** | 0 |
| 44.5 s | 13,583 | 16,686 (tail) | 0 |
| 55–143 s | ~13,580 | 510–843 | 0 |
| **153.7 s** | 13,575 | **218,110** | 0 |
Same phase (first at ~34 s after the arm) and period (120.2 s) as every byte-plane series today.
During a burst: framesync holds, no carrier reset, ≈50 bit errors per frame for ~3 s (BER ≈ 4e-3)
— enough to corrupt every frame's header/CRC (the "garbage header" population), i.e. NOT
byte-plane misalignment but a modem-DSP degradation episode. Excluded today: TX byte plane
(0.24 % floor), DMA/DDR/host, host timing, ADRV9002 tracking cals, fan-control, RF (occurs in
FPGA-internal loopback). Remaining: a periodic process inside the RX (or shared TX→RX) DSP —
a free-running counter/accumulator with an effective 120.2-s period, first firing ~34 s after
the arm (a 32-bit counter at 125 MHz wraps at 34.4 s — matches the first burst; the 120-s
recurrence needs a second mechanism or a different width/clock). Candidates: Peak_Search
free-running symbol counter (E5 family), coarse-frequency NCO/accumulator, AGC/DC loops, the
BIST/reference generator itself (but the byte-plane series show the same bursts without it).
Off-rig next: enumerate free-running counters/accumulators in the RX netlist; Verilator test by
forcing each near its wrap and scoring decoded frames — cheap, no build.
Budget: the ≈3 pp periodic component is RX-DSP-internal and hits BOTH directions' receivers.

### 2026-08-28 20:55 — Netlist hunt for the 120-s burst (`rtl_sim/BURST120_SIM_RESULTS.md`): no native counter wrap; signature reproduced ONLY by symbol-timing / frame-reference disturbances (E5 class)

Enumeration: no demod-datapath counter/accumulator wraps at 120.2 s; the 2^32-at-clk (34.4 s)
counters are telemetry only; Peak_Search's uint32 is telemetry (279.6 s); the symbol-sync
integrator is CLAMPED (`IntegClamp` ±0x1EB852); carrier-sync (sfix39) and AGC (sfix34)
integrators unclamped. Forced-state Verilator runs (ROM/BIST loopback, force at frame 80):
control 0 err/frame; carrier-sync integrator→max: framesync LOST (wrong signature); AGC
integrator→max: 0 err; CFE window→max: 1 frame + 2 carrier resets (hardware rstcs=0 → excluded);
**symbol-timing kick: 59.9 err/frame (47–68), framesync intact, no reset, persistent — matches
the hardware burst (≈50/frame)**; Peak_Search/Timing_Adjust reference +32: 48/68 err/frame,
constant, persistent — same class. Verdict: the burst is a timing-plane event (E5 family), a slow
bias/drift ending in a symbol slip with a ~3-s re-latch cycle; the 120-s drift itself is beyond
15 k clk/s simulation. Fix proposal (not built): the reverse-leg E5 patch (accept a one-strobe-
short frame; re-latch on next `success`) — would cut a 3-s episode to ~1 frame; A/B in the E5 tap
harness first. Zero-build witness running next: `ss_integ_gain` (0x17C, default −2180) at ½×, 2×,
0 with `cs_integ_gain` (0x174) as control — burst period/presence vs the timing-loop integral gain.

### 2026-08-28 21:05 — Gain witness: the 120-s burst is DETERMINISTIC to the bit and independent of the timing/carrier loop gains

`run_tseries_gain.sh` (ROM loopback, 200-s points, 0x17C/0x174 written in the arm batch; the
registers are write-only override muxes at word addresses 95/93 — reads return 0):
ss default 34.2 s **215,285** / 156.8 s **293,433**; ss ½× 34.2 s **215,285** / 157.7 s **293,433**;
ss 2× 34.2 s 215,286 / 156.8 s 293,433; ss 0 34.5 s 215,285 / 158.2 s 293,557; cs 2× 35.4 s
215,386 / 158.3 s 293,506. Same phase, same period, same BIST error count to the bit across
five loop-gain settings → the loops' integral gains play no role; the event is a deterministic
schedule locked to the arm (not a drift-and-slip). The sim's "timing-plane" verdict describes the
*signature* (errors without framesync loss), not the driver. Next (running): image-lineage test —
148 flashed with the clean 08-13 lean image e49c011b7a75 (pre beat-overlay; 146's lineage shows no
burst component in the reverse leg) → same ROM series → probe-4 flashed back.

### 2026-08-28 21:10 — Lineage test: the clean 08-13 lean image e49c011b7a75 bursts IDENTICALLY (34.3 s, 215,285 BIST errors). Not the beatfix overlay; common to every 148 image = the modem core (or 148's clock/transceiver)

Next discriminator (queued): the same ROM-source loopback series on **146** (v_endh image, its own
hardware). Bursts on 146 too ⇒ design-wide (HDL Coder modem core schedule); none ⇒ 148-specific
(board/clock/ADRV9002 SSI on 148, or the 148 image family vs v_endh). No flash of 146 — loopback
arm + register reads only, single actor, guarded.

### 2026-08-28 21:20 — **146 bursts too** (ROM loopback, v_endh image, no flash): 36.1 s, 215,386 BIST errors — same deterministic count. The 120-s event is DESIGN-WIDE (modem core), not board/image/lineage.

Open contradiction to resolve: the reverse air leg (148 TX → 146 RX, six 68–78-s legs at 1.39–2.0 %,
CP95UL ≤ 2.1 %) shows no ~3 pp burst component although 146's RX bursts in loopback and 148's RX
bursts on forward air. Either the burst needs the TX and RX to share a clock/phase (loopback and…
forward air?), or it is driven by the host process common to every run (qpsk_tun -S / -G started
~3 s before each arm; the queued-RX watchdog is 3.0 s ≈ burst duration). Zero-build discriminator
queued: 148 ROM loopback with NO qpsk_tun at all (no RX DMA; 0x104/0x108 still count) — bursts
persist ⇒ fabric schedule; vanish ⇒ host/DMA-driven.
Rig: 148 on lean e49c011b7a75 (the probe-4 re-flash was refused by the pre-flash health rail while
the board sat in ROM loopback — correct behaviour; re-flash queued after the 146 restore).

### 2026-08-28 21:25 — THREE OPEN ITEMS, states kept separate (operator request)

**A. TX byte-in plane (~"5 %" no-RF) — SIM MATRIX COMPLETE; VERDICT: arrival-only in the netlist,
but the netlist mechanism does NOT occur on silicon; the "5 %" was item C's bursts + a 0.24 % floor.**
All 10 cells finished at 400 frames (370 scored), `txplane_runs/MATRIX1.txt`:
| cell | content / whitening / arrival | magic_bad |
|---|---|---|
| c01 idle len0, off, continuous | **0.000 %** |
| c06 fill1516, off, continuous | 0.000 % |
| c07 idle, ON, continuous | 0.000 % |
| c08 fill1516, ON, continuous | 0.000 % |
| c05 idle, off, rate 1.02× | 0.000 % |
| c04 idle, off, rate 1.00× + jitter ≤20k clk | 0.000 % |
| c02 idle, off, rate 0.98× (underrun ~1/50 frames) | 2.415 % (10/414) |
| c03 idle, off, rate 0.95× (underrun ~1/20 frames) | **4.695 % (20/426)** |
| c09 TGEN 191-word, continuous | 61.7 % (format mismatch, Test B artefact) |
| c10 TGEN 191-word, 50 % gaps | 44.7 % (same) |
Content (idle/fill, whitened/unwhitened) has NO effect; the fraction is set solely by how often the
source lets the input go silent: **arrival-dependent only.** Reproduction level: 4.7 % at 0.95× vs
hardware Test A 5.13 % — numerically a match, but the hardware witness (probe-4) then showed the
silicon input NEVER starves (`ready&&!valid` episodes: none, max 0 clk since boot) and that the
"5 %" decomposes into item C's 120-s bursts (≈3–4.9 pp) + a 0.24 % floor. **So: mechanism
MISMATCH — the sim reproduces a real netlist vulnerability (16-word ByteWordBuffer, ~6 usable
words) that the real host/DMAC never triggers. The number match was coincidental.**
Gap sweep (original, `GAPS.txt` + HDL-dev-2 `GAPS_FINE.txt`): clean at 2000 clk silence; corrupted
(23.9 % of 46 frames = every gapped transfer) from **2250 clk (18.3 µs at 122.88 MHz)** up — the
threshold is 2000–2250 clk, i.e. 16–18 µs. `s1_rtl_txfix` (ByteWordBuffer 16→64, threshold 54):
clean at 4500/6000/8000/10000/12000/14000 clk, 17.4 % at 15000, broken at 20000 — cover ≈ 14–15 k
clk (≈115–120 µs). **State: PARKED with verdict. No fix build (not justified for a 0.24 % floor;
the vulnerability matters only for a host that leaves >18 µs input gaps — ledger it as a design
note).** True no-RF TX-plane cost: 0.24 % (floor in every loopback window between bursts).

**B. RXQ=0-only 5.9 % between framesync and the ByteRxFifo push — VERDICT (evidence-based), PARKED.**
With the 4096-word FIFO in place: frames at pins 71,267 vs framesync 75,718 (−5.9 %); 200/200 samples
of the FIFO debug word show DMAC tready=0, FIFO non-empty, occupancy wrapping (full); at −M32 RXQ=0
the loss is ABSENT (76,112 = 0x104). ⇒ host reset-per-transfer cannot sustain line rate at −M16
(≈6 % of air time per 16-frame transfer in reset+drain+re-arm); the byte plane sheds whole frames
upstream of a full FIFO. Not a fabric defect; moot with the shipped RXQ=1 default. A fabric tap
(serializer drop counter) would only confirm the drop point; not scheduled unless the operator
wants RXQ=0 kept.

**C. 120.2-s deterministic burst — RUNNING (design-wide).** 146 (v_endh, different board and image)
bursts identically in ROM loopback: 36.1 s **215,386**, 151–163 s (101,288+192,944), 277.5 s
215,386. Bit-identical counts on 148 across five loop-gain settings and two images (215,285 /
293,433). ⇒ **design-wide, RTL/modem-core first-class suspect; board/clock/SSI de-prioritised**
(two boards, two images, same counts). Remaining discriminator (queued, single actor): 148 ROM
loopback with NO qpsk_tun/RX DMA at all — persists ⇒ fabric schedule; vanishes ⇒ host/DMA-driven.
Off-rig: burst-hunt agent re-targeted on deterministic (non-power-of-two) schedulers; E5 patch A/B
running. Reverse-air contradiction (no burst component in six 146-RX legs) still open.
Rig rails unchanged: the probe-4 re-flash refusal (wcnt=0 in ROM loopback) was the rail working;
re-flash queued behind a healthy link, same rails.

### 2026-08-28 21:30 — **C: MECHANISM FOUND IN THE NETLIST — the Preamble_Detector one-frame delay FIFO runs exactly FULL (12,333 = FULL) and silently DROPS a symbol on any +1 strobe excursion; the timing NCO's limit cycle supplies one such excursion per 120.2 s in noise-free loopback. This is E5's symbol-deletion class, now unified with the burst.**

`rtl_sim/BURST120_SIM_RESULTS.md` §6: frame = 12,333 symbol slots (12,320 data + 13 preamble),
49,332 samples (sps 4), 0.803 ms. The Preamble_Detector delay FIFO's pop strobe is the push strobe
delayed by a 49,332-cycle shift register → steady occupancy = 12,333 = the FULL constant (sim
confirms `occ=12333` every frame). `Validate_Input_Push_Pop`: `push_on_full = push & ~pop &
(occ==12333)` → `valid_push=0` — the symbol is dropped; occupancy counter modulus 12,334 vs
address counters modulus 12,333 (off-by-one design). Any interpolator strobe advancing one symbol
against the sample clock deletes one symbol at the detector input; the fixed-point timing NCO's
deterministic limit cycle drifts one symbol per 120.2 s at zero SRO (hence gain-, lineage- and
board-independence and bit-identical error counts); each deletion costs the ~3-s
Peak_Search/Timing_Adjust re-alignment with framesync intact and no carrier reset; the first event
~43 s after the arm is the first drift crossing from the post-lock phase. On air, SRO drives the
same excursions far more often (E5: one deletion per ~33 frames at 2.5 ppm) → the per-frame
"garbage header" comb is plausibly the SAME defect under SRO, and the reverse leg's E5 episodes too.
Fix proposal (not built): (1) slack in the delay FIFO (RAM is 16,384 words; FULL at 12,333+N with
pop-before-push priority) so a +1 excursion is buffered, not dropped — one-module change; (2) the
E5 `Peak_Search`/`Timing_Adjust` re-latch patch so any residual deletion costs one frame, not 3 s.
A/B running now in the forced-deletion harness (`e5fix_runs/orig_*` vs `fix_*`, selectors
slip1/slipm1/slip32/edge; nemo saturated, ~100 s per frame). Zero-build hardware witness:
`PdTelemetry` on the IQ debug mux (0x10C) streams fifoEnt/tOff/vPop/done/succ/newPk per preamble
event — capture debug IQ across a burst (bursts are deterministic at ~34 s after T0) and decode:
prediction fifoEnt=12,333 steady, a push-on-full at onset, tOff jump for the burst, return at end.
Rule stands: no fabric build until the A/B is clean AND the witness confirms on silicon.

### 2026-08-28 21:35 — C: no-daemon ROM loopback (no qpsk_tun, no RX DMA) bursts identically (34.2 s 215,285 / 156.1 s 293,336 / 278.1 s 215,335). Host and DMA fully excluded; fabric schedule confirmed. 148 back on probe-4 02e8c97d6181 (flash rails green, 21:27:54); rig restored and released 21:35:05.

### 2026-08-28 21:55 — **C is the already-known "119.75-s beat" (08-19 → 08-22 campaign). Reconciliation, and a hidden variable found: fixctl (0x208) reads 0 = LEGACY on the link today.**

Found while pre-registering the witness: `two_jup/beat_capture*.sh`, `BEAT_BISECTION_PLAN.md`,
`STAGE_LOCALIZED.md`, `BEATFIX_DESIGN.md`, `BEATILA*_DESIGN.md`, `LAYERA_BER.md`. The constraint set
there matches today exactly: strictly periodic bursts (119.75 s), first at arm+~35–153 s, two
deterministic species (~293,18x / ~215,0xx) byte-identical across FPGA loopback, SSI loopback and
board 146; tracking-cal invariant; period changes with link rate (341 f/s → 6.7 s). On 08-20 the ILA
showed the corruption is a COHERENT SEQUENCE SHIFT (value-perfect coded bits at a shifted position vs
the frame marker) at/before the FEC input; on 08-21 the BEATFIX "phase contract + serializer anchor"
(`fixctl`=3 at 0x208) gave ZERO BIST errors through six slots on air; beatfix2/3 (08-22) added the
framing calibration (08-27 A/B ran with fixctl=3 and readable host frames). The TRIGGER stayed unknown
("no DUT counter pair predicts the period; both idealised sims clean; suspect SSI clock chain").
Today's contribution: (1) the trigger candidate — the Preamble_Detector one-frame delay FIFO runs
exactly FULL and drops a symbol on a +1 strobe excursion, which is precisely a one-symbol shift of the
data path vs the marker path; (2) the burst is host-, DMA-, cal- and image-independent (no-daemon,
lean, 146) — consistent with the 08-19 constraints; (3) **0x208 reads 0x0 on 148 right now**: the
flash rail sets fixctl=3 at its end, but `bringup_r2r3.sh` never writes 0x208 and the modem soft
reset in every bring-up/arm returns it to legacy. Every checker/PER window today ran in LEGACY mode
— the ~3 pp burst component was measurable only because the mitigation was off. (The 08-27 13.9 %
baseline was taken right after a flash, i.e. WITH fixctl=3.) Tonight's stage-5 tests therefore
include fixctl=3 re-verification (ROM loopback + air) with the checker and the pre-registered
Witness-1 capture (`DELAYFIFO_WITNESS_PREREG.md`).

### 2026-08-28 22:00 — Stage 5 first result: **fixctl=3 (written after the arm, 08-21 idiom) does NOT suppress the burst on the flashed lineage** (probe-4 = beatfix3 + instruments): F2 burst at 45.3 s, 209,390 BIST errors (vs 215,285 @34.2 s legacy — phase and count shifted, so the write took effect, but the burst remains). The 08-21 "zero errors through six slots" was on BEATFIX v1 198ade9f234a; on v3 fe5bd8a4fe19 fixctl=3 was only ever "verified by effect" (H-11: counter/latch active), never by BIST slots. So the ~3 pp burst component is LIVE on the shipped lineage regardless of fixctl. Correction: 0x208/0x10C read back 0 always (write-only) — the earlier "reads 0 = legacy" inference is withdrawn; the effect test is what counts. Queued: fixctl ordering/bit-split test (single-tap-then-3 exactly as 08-21; 3-before-reset; bits 1 and 2 separately). Witness-1 snippets captured: baseline (T0+20), onset (t31: BIST 1,641→69,593 during the capture), mid-burst (t32), post (t33–t38); 4 M samples each, awaiting the RTL-derived decoder.
Air with fixctl=3 written after the bring-up (148 RX, legacy daemons): checker windows **10.5 % / 6.2 % / 13.6 %** bad-magic (burst-containing / burst-free / burst-containing) vs host crc_drop 11.3 / 6.5 / 14.5 % — indistinguishable from legacy. **On the shipped lineage the beatfix contract does not remove the beat, in loopback or on air.** Witness-1 snippets: `r3cap/witness1_20260828_215332/` (base20, t31=onset, t32=mid, t33–t38 post).

### 2026-08-28 22:25 — fixctl ordering/bit-split test (probe-4, ROM loopback): NO variant changes the burst
single-tap→3 (exact 08-21 idiom): 34.2 s 215,285 / 156.1 s 293,336; 3-before-reset: identical; fixctl=1: identical; fixctl=2: identical (first-slot count 215,285 in all four; the earlier double-tap→3 run gave 209,390 @45 s, a phase/count variant, not a suppression). On the v3/probe lineage the fixctl register is inert against the beat as measured by the BIST comparator. Stage-5 status: the only fix candidate left is the delay-FIFO slack (trigger removal) — sim A/B pending; the beatfix contract (damage masking) is not available on this lineage.

### 2026-08-29 06:45 — Overnight close-out (summary: `two_jup/OVERNIGHT_20260829.md`)
Netlist forced-state A/B (`sim_burst_force.cpp`, ROM/BIST loopback, force at frame 80, 407 frames):
control 0 err after lock, `occ=12333` every frame (**delay FIFO confirmed running exactly full in sim**);
`fpush` (+1 on the FIFO push address counter) → **42 err/frame from frame 82 to the end (326 frames)**,
rstcs=0, framesync intact; `fpop` (+1 pop) → ≈56 err/frame, same shape; `focc`/`foccp1` (occupancy counter
only, occ→12,334) → **0 errors**. So a one-symbol PUSH/POP ADDRESS desync reproduces the hardware's
per-frame magnitude (≈50) and character; an occupancy-only perturbation is harmless. **Mismatch stated
plainly:** hardware bursts self-heal in 3–7 s, the forced sim persists indefinitely — the sim reproduces
magnitude and character, NOT the recovery; something re-anchors on silicon that the injection does not model.
E5 `Peak_Search` window patch (`s1_rtl_e5fix`) built but its A/B never reached the injection frame (both
sim agents terminated at ~22:30 on the model usage limit). Witness-1 debug-IQ snippets captured around the
first slot (`r3cap/witness1_20260828_215332/`, baseline/onset/mid/post) — decode pending, no rig needed.
Housekeeping: `/dev/shm` on 148 hit 100 % (965 MB `seq_raw.log` from the `-S` scorer) at ~06:00, truncating
the daemon stats line and failing the sentinel probe; cleared both boards. TRAP: the ROM-loopback scorer
must be run with the raw seq log disabled or truncated between points.
TRAP (sentinel, unfixed by design decision): `delivery_sentinel.sh` resets its failed-probe counter using a
stale `r`, so the post-reboot recovery path can never fire; ledgered for the operator, not changed.

### 2026-08-29 06:50 — Witness-1 scored against the pre-registration: **NULL RESULT — the instrument does not exist on the flashed lineage** (not a confirmation, not a falsification)

Decoder written from the RTL (`two_jup/sim_repro/pdtelemetry_decode.py`, packing verbatim from
`PdTelemetry.v`: telI=w[31:16]/telQ=w[15:0]; s0 marker 0xE0000000 with tRef/tOff/flags, s1 dI/dQ,
s2 taRef/accOff/fifoEnt/vPop, s3 tRefLong, s4 runMax, s5 heldTs, s6 marker 0xA5 with beatCnt/symCtr).
All five captured snippets decode to **zero records: the rx2 stream is all zeros** (4 M samples,
1 unique value). Guarded read-only re-check on 148 (rig lock held, keeper stopped, no arm, released
after; link 1245 f/s throughout): `axi-adrv9002-rx2-lpc` = zeros at every mux setting;
`axi-adrv9002-rx-lpc` = the documented broken staircase (Q increments ~256 every few samples, I small
and varied) and **identical at mux 0x10C=4 and mux=1 → the debug mux does not reach either IQ output on
the probe-4/beatfix3 lineage** (matches `boot_known_good/README.md`: "the rx-lpc IQ capture tap is
STRUCTURALLY a ramp on this lineage — no IQ captures possible"; the BEATOBS overlay repurposed it).
So Witness-1 as pre-registered is **unavailable on the currently flashed image**; its predictions and
falsifiers stand untested. Instrument correction found while writing the decoder: `fifoEnt` is masked to
9 bits in the record, so a full FIFO reads **12,333 & 511 = 45**, not 12,333 — the pre-registered
wording "fifoEnt reads 12,333" is unmeasurable as written; the equivalent test is "45 steady, ±1 on an
excursion". Options for obtaining it are in the operator decision (lean image e49c011b7a75 has the only
working IQ tap AND bursts identically, so it can carry the witness; or wait for the counter in the fix build).
TRAP: `rig_lock`/`rig_unlock` only match when the SAME shell holds them (`pid=$$`), so a lock taken in one
Bash call cannot be released by another — take and release inside one script, as every chain script does.

### 2026-08-29 13:05 — Witness-1 on the LEAN image (operator-approved): **also unobtainable. Zero-build witness path is exhausted.**
Full-rails flash to `e49c011b7a75` green (gate pass 1, per-stage stamps: reboot→ssh 57.4 s, bring-up 185 s,
rail total 296.6 s). ROM loopback armed, `0x10C=4`, sanity snippet FIRST (3 M samples of rx-lpc):
**3,000,000 unique words and zero PdTelemetry records** — the lean tap is alive (unlike probe-4's zeros)
but carries ordinary IQ, i.e. the debug mux does not route the telemetry to the capture path on this
generation either. The chain skipped the capture phase (design intent: do not burn the burst window on a
dead tap) and went to flash-back; the flash-back was refused by the pre-flash health rail
(`fsync=1260 wcnt=0` — a loopback-only experiment leaves the byte plane idle). Correct rail behaviour;
the chain now does a bring-up before the flash-back (`run_p4back4.sh`). **Conclusion: the pre-registered
Witness-1 cannot be obtained on any available image; the witness must be Witness-2 (counters in the fix
build), as agreed.** PdTelemetry is functionally identical in the 08-12 and beatfix3 generations
(diff = header/process name only), so the decoder stands ready for any image that does route it.

### 2026-08-29 13:05 — E5 patch A/B (sized 48 frames, force at 16; `e5fix_ab/`): **joint slips do NOT persist — my "slip persists" claim is WITHDRAWN**
| stimulus (force at frame 16) | original | patched (`s1_rtl_e5fix`) |
|---|---|---|
| none (control) | 0 err | 0 err |
| joint slip +1 | **42 err in ONE frame, then clean** | 42 err, 1 frame |
| joint slip −1 | 56 err, 1 frame | 56 err, 1 frame |
| joint slip +32 | 68 err, 1 frame | **0 err** |
| `edge` (peak forced onto the window `done` slot) | **framesync LOST — only 17 frames decoded, then nothing** | 102 frames, 61 err in 1 frame |
| `ss` timing-loop kick | 3,931 err over **64 bad frames**, still bad at frame 82 | 2,198 err over 34 bad frames (shorter run — like-for-like 110-frame re-run queued) |
Readings: (a) a physically realistic one-symbol slip (both reference counters move together) costs exactly
ONE frame in the flashed netlist — the earlier "persists indefinitely" came from the single-counter
force, which the mechanism analysis identifies as an unreachable model artefact; withdrawn. (b) The E5
patch fixes a real failure mode — the `edge` case, where the original loses framesync completely — but
**that signature (frame loss) is NOT the hardware burst signature (framesync intact)**. (c) Only the
timing-loop kick reproduces multi-frame persistence with framesync intact; the patch reduces but does not
remove it. **The sim still does not reproduce the hardware burst DURATION (3–7 s ≈ thousands of frames);
the closest injection sustains tens of frames.** No fix is proposed as "the beat fix" on this evidence.

### 2026-08-29 17:10 — fixctl in the MODEL: **bit-identical to fixctl=0 on the v3 netlist — the mitigation is inert in simulation too, so it is not a wiring/build problem**
`sim_burst_force.cpp` gained a `fixctl` argument (the wrapper already exposes the port). Same injections,
original v3 netlist, fixctl 0 vs 3, 110 frames, force at 16:
| stimulus | fixctl=0 | fixctl=3 |
|---|---|---|
| joint slip +1 | 226 frames, 1 bad, 42 err | **226 frames, 1 bad, 42 err (identical)** |
| edge | 17 frames then framesync lost | **17 frames then framesync lost (identical)** |
| ss (loop-filter saturation) | 177 frames, 159 bad, 9,759 err | **identical** |
So the register is inert against these faults **in the model**, matching the four hardware orderings —
i.e. this is NOT a build/wiring defect on 148; the v3 contract simply does not act on this class. (The
contract IS in the datapath: `BfContract.startSel` drives the FEC `startIn`; v3 added an edge qualifier
`vEdge = vout && !voutPrev` that v1/v2 lacked.) Whether the v1 contract would still work is untested and
would need the v1 netlist generation, which is not in the tree.
**Retraction/relabel:** the `ss` selector saturates the symbol-sync loop-filter integrator to 0x7FFFFFFFFF —
a permanently pinned loop, not a slip. Its sustained errors are NOT evidence about the beat; my earlier
"closest match to the hardware signature" for `ss` is withdrawn. Like-for-like at 110 frames the E5 patch
under `ss` decodes 100 frames vs 177 with frame intervals of 197,328 clk (2x) — **it misses every other
frame under a disturbed timing loop**, a regression. The E5 patch's real result is the `edge` case:
original loses framesync permanently (17 frames), patched decodes 226 with 1 bad frame. That failure mode
is frame LOSS, which is not the hardware burst signature. **E5 patch is NOT a candidate fix for the beat.**
**Relabel of the overnight FIFO result (correcting my own mislabel):** `fpush`/`fpop` force the delay-FIFO
ADDRESS counters, which is exactly what a push-on-full drop does (push suppressed, pop continues → the
one-frame delay becomes 12,332 → data one symbol early against an unmoved marker). That is a physically
reachable state, unlike `ps`/`ta` (lock-stepped reference counters). It produced 42–56 err/frame,
persistent, framesync intact, rstcs=0 — the hardware signature and magnitude. Recovery hypothesis:
the burst ends when the OPPOSITE excursion restores the occupancy; duration = time between the two events,
period 120.2 s = the drift beat. Two-event test running (`rec_A..D`).

### 2026-08-29 18:45 — **MECHANISM AND RECOVERY DEMONSTRATED IN THE MODEL** (`e5fix_ab/rec_*`, `sim_burst_force.cpp` two-event mode)
| run | events | after 1st event | after 2nd event (f>47) |
|---|---|---|---|
| rec_A | push +1 @f16 only | **169 bad frames, 42 err/frame, still bad at f186** | 139 frames, **139 bad** — no recovery |
| rec_B | push +1 @f16, pop +1 @f46 | 30 bad frames | 139 frames, **0 bad, 0 err** — errors stop at f48 |
| rec_C | pop +1 @f16, push +1 @f46 | 32 bad | 2 bad (transition), then clean |
| rec_D | occupancy +1 @f16 (the slack state) | **0 errors** | 0 errors |
Per-frame: rec_A 42 err at f44…f50 and onward; rec_B 42 err through f47 then **0 from f48** — recovery two
frames after the compensating event (= delay-FIFO frame + Timing_Adjust latency). What is forced is a
**one-symbol displacement between the delay FIFO's write and read ADDRESSES with the occupancy counter
unchanged** — i.e. exactly the 08-20 silicon ILA finding (value-perfect bits at a shifted sequence
position). So in the model: displacement → persistent ~42–56 err/frame, framesync intact, rstcs=0
(hardware: ~50 err/frame, framesync intact, rstcs=0); compensating displacement → immediate, complete
recovery. **Burst duration = interval between the two displacement events; 120.2 s = the drift beat that
produces them.** Reproduction command (deterministic, run-to-run identical):
`./obj_burst/Vwrap_byte_ce 90 16 fpush e5fix_ab/rec_A 0` and `... 90 16 fpush e5fix_ab/rec_B 0 46 fpop`.
Still INFERRED (the sim cannot show it): what produces the displacement every 120.2 s on silicon. The
push-on-full drop is one sufficient cause (push suppressed while pop continues); any other cause that
displaces the addresses gives the same signature. **That is what the build's witness must discriminate.**

### 2026-08-29 22:55 — Pre-build gates: **PASS at the fifth witness design** (four self-vetoes, each one a measured fact about the FIFO)
The gates ran before any Vivado time and vetoed four designs. Each veto is a finding about normal operation
of the Preamble_Detector delay FIFO, not just a failed attempt:
| witness | idea | gate result | what it established |
|---|---|---|---|
| v1 | count changes of (push−pop) | 12,336 changes in 2 frames | the address difference toggles 0↔1 **every symbol** in a healthy FIFO |
| v2 | occupancy must equal (push−pop) between symbols | saturated on the clean control | `numEntries` is registered on a different pipeline stage — the two never agree cycle-by-cycle |
| v3 | same, sampled only when no push/pop in flight | 12,335 changes | "settled" is true both before and after each pop, so the oscillation survives |
| v4 | key on the range (diff ≥ 2) | max=255, events=1 on the CLEAN run | during the initial **fill** the difference legitimately sweeps 0…12,332 |
| **v5** | own frame strobe (mod-12333 pop count), sample once per frame, skip the first 4 frames | **PASS** | the per-frame sample is the clean invariant: 0 healthy, 1 displaced |
Final gate numbers (40 frames, displacement at f12, recovery at f30):
```
ctl0  err=0    diff_seen=[0]    events=0  max=0  push_on_full=0     <- G1 PASS (silent when healthy)
ctl8  err=0    diff_seen=[0]    events=0  max=0  push_on_full=0     <- G3 PASS (slack arm does not perturb)
rec0  err=756  diff_seen=[0,1]  events=2  max=1  push_on_full=0     <- G2 PASS (exactly drop + recover)
rec8  err=756  diff_seen=[0,1]  events=2  max=1  push_on_full=0
```
`push_on_full` is 0 in every arm, as expected — a forced address displacement is not a real push-on-full.
That counter is untouched by these gates and is the one that carries **P3 on silicon**.
(Two scoring bugs of mine also surfaced and were fixed: an `awk -F,` on space-separated data, and a
filename-slice key collision that mapped `g_ctl0`/`g_ctl8` to the same key and printed "missing data" on a
run that had actually passed. The sim data was re-scored from disk, not re-run.)

### 2026-08-30 00:22 — **P1/P2/P3 FALSIFIED ON SILICON: the beat is NOT a delay-FIFO displacement and NOT a push-on-full drop. Hypothesis killed.**
Witness image `786dce9fafc8` (WNS +0.071), full rails, health gate pass 1. Arm A (`fixctl`=0), ROM loopback,
witness sampled every 10 s:
```
t=11.7s  frames=13507 biterr=561     | occ=12333 diff=0 events=0 max=0 push_on_full=0
t=22.6s  frames=13570 biterr=510     | occ=12333 diff=0 events=0 max=0 push_on_full=0
t=33.5s  frames=13557 biterr=194049  | occ=12333 diff=0 events=0 max=0 push_on_full=0   <== BURST
```
**During a full-magnitude burst (194,049 bit errors in the window) the delay FIFO is untouched:** occupancy
stays exactly full at 12,333, the push−pop address difference stays 0, the displacement-event counter stays
0, and `push_on_full` never fires. Scored against the pre-registration written before the build:
- **P1 (delta_changes = 2 per burst): FAILED — 0 events.**
- **P2 (addr_diff steps ±1 at onset, returns at the end): FAILED — diff constant 0.**
- **P3 (push_on_full 1:1 with bursts ⇒ drop is the trigger): its precondition never arose — 0 events.**
The witness is trustworthy here: the same counters gave events=2 / max=1 on the forced displacement in the
gates, and 0 on healthy traffic, so a real displacement would have been visible. **Conclusion: the
Preamble_Detector delay-FIFO drop/displacement is NOT the beat trigger, and the slack fix is not justified.**
The sim reproduction (address displacement → persistent ~42–56 err/frame, framesync intact, recovery on the
compensating event) remains a real and exact *analogue* of the hardware signature, but it is not what the
hardware does — the same lesson as the FIFO-depth build, caught this time by a pre-registered witness
before any PER number was credited. Arm B (`fixctl`=8, slack) now serves only as a control; since it gates
an event that never occurs, it must be indistinguishable from arm A — if it is not, something else is going on.
**Where the search goes next** (the 08-20 ILA still stands: value-perfect coded bits at a shifted sequence
position at/before the FEC input): the shift must be produced downstream of the preamble delay FIFO —
Rate_Handle / serializer phase (the Model-6 class), the demodulator start/valid marker path, or the
deinterleaver input alignment. None of these is tested yet.

### 2026-08-30 09:00 — Two corrections requested by the operator: loopback taxonomy, and the loopback error floor

**1. Loopback taxonomy — and a ledger correction.**
`rx_input_select` (0x114) = 0 selects `Transmitter_dataOutI/Q` directly as the receiver input
(`TxRxComposite.v:679/735`, mux on `rx_input_select_1`). So the loopback used in **every burst test I ran**
is **purely FPGA-internal digital**: modulator output → demodulator input, never leaving the die — no DAC,
no ADC, no SSI, no analog. (The ADRV9002 TX registers written in the arm idiom configure the transceiver but
its data path is not in the RX loop.)
Modes actually available: **(1) FPGA-internal digital** (0x114=0) — used by all my tests; **(2) ADRV9002 SSI
near-end loopback** — out over LVDS to the transceiver and back, digital, no analog (`rx0_near_end_loopback`
in the phy debugfs); **(3) ADRV9002 TX datapath / ORx observation paths** (`tx0_datapath_loopback_en`,
`in_voltage0_orx_*`) — ORx is a separate receiver and does not feed the modem RX chain; **(4) external RF
cable loopback** TX SMA → attenuator → RX SMA on one board, with 0x114=1 and RX LO set equal to TX LO —
**not cabled today**; **(5) two-board over the air** — the normal link.
**Correction to the ledger wording:** "RF excluded" for the beat should read **"the beat occurs with RF
entirely absent (mode 1), therefore RF is not necessary"** — it is not the claim that RF has been tested and
found irrelevant. RF *has* been in the loop for burst tests only via mode 5 (air), where bursts also appear.
The 08-19 claim of byte-identical species in **mode 2** (`LAYERA_BER.md`) is prior-session evidence I have
not reproduced; it is the stronger exclusion, and it is worth re-running now that we have the witness image.
**For the comb this matters more:** absent in mode 1, present in mode 5, **untested in modes 2 and 4**.
A single-board mode-2 (SSI near-end) and mode-4 (RF cable) test would separate transceiver/analog from 146's
transmitter without involving 146 at all — cheaper and sharper than the TX-vs-air separation I had queued.
Mode 2 costs nothing but rig time; mode 4 costs one SMA cable + a 30–40 dB attenuator (operator's hands) and
a bring-up variant with matched LOs.

**2. The loopback floor is NOT noise: it is quantised at exactly 51 bit errors per event.**
45 baseline 10-s windows from last night (bursts excluded): the values are **510, 561, 612, 663 — exactly
51 × 10, 11, 12, 13** in 26 of 44 samples (59 %); the remainder (613–906) are higher and sit next to bursts.
So the floor is **10–13 discrete events per 10 s, each costing exactly 51 decoded bits** — 1 event per
1,040–1,360 frames = **0.074–0.096 % of frames**; average BER 3.4e-6; each event damages 0.42 % of a frame's
payload bits. In a noiseless digital path that is not a rounding-down, it is a real discrete mechanism.
**And it unifies with the beat.** Dividing each burst by 51: 194,049 → 3,805 events; 196,306 → 3,849;
206,409 → 4,047; 211,279 → 4,143. At 1,356 frames/s and **one event per frame** that is **2.81, 2.84, 2.98,
3.06 s** — every burst is exactly "one 51-bit event per frame for ~3 s", matching the observed 3–7 s
duration. **The beat is the floor mechanism at ~100 % duty instead of 0.09 %.**
Practical consequence: we no longer need to wait 120 s for a burst to study this — there are ~11 events
every 10 s continuously, in a fully digital loopback.
**Honest discrepancy, not smoothed over:** the daemon-source loopback floor is 0.24 % of frames with garbage
headers, whereas the ROM-source event rate is 0.09 % of frames, and a 51-bit burst landing uniformly would
hit the 12-byte header only ~0.8 % of the time. Those two floors do not reconcile yet; either the events are
not uniformly placed (a fixed offset — e.g. at the frame start — would explain it) or there is a second
low-rate mechanism in the daemon path. **Unexplained, and it is now the sharpest open question.**
**What would settle it (no rig time needed for the first):** (a) in sim, force one symbol error at the
demapper input and count the decoded bit errors — if it is exactly 51, the event is a single-symbol slip and
51 is the Viterbi error-burst length for this K=5 code; (b) on hardware, per-frame error *position* — the
existing `cap_in`/`cap_deint`/`cap_out` hashes or a small position-histogram counter would say whether the
51 bits are contiguous and at a fixed offset (framing) or scattered (bit errors).

### 2026-08-30 09:15 — Test (a) NOT OBTAINED: the sim probe cannot reach the demodulator output signals (three attempts, all silent no-ops)
`bit1/sym1/sym2/sym8` (corrupt coded bits at the FEC input) and `start1/start2` (spurious FEC start pulse)
all returned results byte-identical to the control. Instrumenting the probe showed why:
`validbeats=0 startbeats=0` over a full 24-frame run — `CAT(RXP,u_QPSK_Demodulator__DOT__Delay9_out1)` and
`..._Delay10_out1` read **zero at every cycle**, although `startOut` must pulse once per frame (54 times in
that run). The names compile, so Verilator resolved them to members that are not the live datapath signals
(optimised/renamed under `--public-flat-rw`). **Both injections wrote into dead variables**; the "no effect"
was an artefact, not FEC correction. Three attempts is enough — the fix is a proper tap, not another guess:
expose `startOut`/`validOut`/`bitsIn` as real wrap ports the way `wrap_byte_taps_e5.v` already does for the
Peak_Search signals (known-good pattern in this tree, ~1 h off-rig, no rig, no flash).
**What the same runs DID establish (and this is solid):** in FPGA-internal digital loopback the sim decodes
**exactly zero bit errors on 84 of 84 frames** after acquisition; the *only* nonzero frame is frame 2 at
**exactly 51** — the Viterbi acquisition transient, the decoder converging from an unknown state. So 51 is a
**decoder-side quantity**, and it is numerically identical to the hardware event size.

### 2026-08-30 10:30 — **TAPPED HARNESS: taps alive, and the start-pulse hypothesis is CONFIRMED in sim**
`wrap_byte_fec.v` (hierarchical-reference taps, the `wrap_byte_taps_e5` mechanism) + `sim_fec_taps.cpp`,
injection in RTL via `fixctl` bit4 (`FixCtlDec.enSpurStart` → one-beat pulse ORed into the FEC `startIn` in
`QPSK_Rx`). **Tap sanity (the check the five earlier attempts failed): `totStarts=50/51`, `totValids=2,463,751`
— the taps see one start per frame and every coded-bit beat.** Previous flat-rw probes read 0; these do not.
| run | packets | total bit errors | starts/frame | the nonzero frames |
|---|---|---|---|---|
| control (no injection) | 50 | **51** | **exactly 1 on every frame** | frame 2 = 51 (acquisition), all others 0 |
| spurious start at frame 14 | 51 | 119 | 1 on every frame | frame 2 = 51, **frame 17 = 68** |
**Scored against the pre-registration written before the run:**
- **Healthy == exactly one start pulse per frame: CONFIRMED** — `starts=1` on every frame of both runs, with
  49,280 coded-bit beats per frame, and zero bit errors on every frame except the two events.
- **A spurious start costs a single-frame burst of the 51-class: CONFIRMED** — 68 bit errors in one frame,
  then **zero afterwards** (not ~0, not corruption to end-of-frame; the two falsifiers are excluded). 68 vs
  51 is the same class: the acquisition transient (51) is a restart with the trellis already empty, the
  mid-stream restart (68) additionally discards the bits in flight through the traceback. Both are "one
  decoder restart", and hardware events measured 51 exactly because the floor events are quantised by the
  BIST counter in whole restarts.
**Therefore (proven in sim, on the flashed-lineage netlist):** one spurious FEC start pulse → one frame of
~51–68 decoded bit errors → full recovery. That is precisely the hardware signature: floor = ~1 spurious
start per 1,100 frames; beat = a spurious start on nearly every frame for ~3 s.
**Also proven in sim by the same runs:** the digital loopback is EXACTLY zero errors on every frame except
the acquisition frame — the zero-error standard is achievable and the hardware floor is a defect.
**Next (NOT started, needs operator approval):** a start-pulse-per-frame counter on silicon. Pre-registered:
healthy == 1 start/frame; during a burst == 2/frame (or one at the wrong position). Falsifier: if the
hardware shows exactly 1 start/frame through a burst, the spurious-start model is wrong and dies there.

### 2026-08-30 11:00–12:10 — **THE BIST COMPARATOR SEES ONLY THE FIRST 120 OF 2240 BITS**; open-queue item #1 dissolves; mode 2 answered from disk; the start counter is already flashed

Session detail: `two_jup/SESSION_20260830_AUTONOMOUS.md`. No rig command was issued (a permission denial
blocked the runner; not retried, per the standing rule). 148/146 untouched, link up throughout.

**1. Instrument fact, from the netlist that built the flashed image `786dce9fafc8`.**
`MATLAB_Function.v` (behind 0x104/0x108), instantiated from `Capture_Data_Bits` (`Receiver.v:388`) with
`.start(startOut) .valid(validOut) .datain(dataOut)`:
```
assign tmp_3  = (start == 1'b0 ? tmp_5 : count_1);           // bit index, reset to 1 each frame start
assign tmp_13 = (tmp_3 <= 32'd120) && (p12tmp_1 != p12tmp_2); // error counted ONLY for index 1..120
wire signed [7:0] p12tmp_tmp [0:119];                         // golden ref = 120 bits
// msgLen = uint32(2240);                                     // frame = 2240 bits
```
(The nearby `tmp_3 <= 130` gates the index *increment* only — the counter saturates at 131; it never
reaches the compare path.) Production source `TxRxCompo_ip_src_MATLAB_Function.v` is identical.
**So 0x108 measures errors in the first 5.4 % of each frame, at the frame start, and is blind to the rest.
Every bit-error number in this campaign is a frame-start number.** Not clipping: across 20 sim
`*_frames.txt` runs the per-frame max is 51–72, never ≥120.

**2. Open-queue item #1 (the "sharpest unexplained question") is DISSOLVED, not answered.** It argued that
0.09 % of frames with a 51-bit event cannot reconcile with 0.24 % garbage headers, because "a 51-bit burst
landing uniformly would hit the 12-byte header only ~0.8 % of the time". There is no landing-uniformly
step: the 0.09 % was already a frame-start damage rate, since the comparator only ever looks at the first
120 bits (15 bytes, containing the 12-byte header). Both numbers measure frame-start damage; they differ
by 2.7x from two different TX sources. No second mechanism is required.

**3. Corrections to earlier ledger wording.** "Each event damages 0.42 % of a frame's payload bits" → it
damages **51 of the 120 compared bits (42.5 % of the compared window)**; damage beyond bit 120 has never
been measured in any run. "84 of 84 frames with zero errors" → zero errors **in the first 120 bits**.

**4. Mode 2 (SSI near-end loopback) answered from captures already on disk** — the 08-19 mode-2 CSV and
three 08-18 mode-1 CSVs, scored against the 51-quantisation rule that was only discovered on 08-30:

| capture | quiet floor | quiet seconds that are exact multiples of 51 | event rate |
|---|---|---|---|
| mode 1 · 124443 | 60.6 err/s | 457/567 = 80.6 % | 0.094 % of frames |
| mode 1 · 131600 | 60.7 err/s | 456/567 = 80.4 % | 0.094 % of frames |
| mode 1 · 133323 | 60.5 err/s | 457/566 = 80.7 % | 0.094 % of frames |
| mode 2 · SSI-NEL | 62.0 err/s | 420/566 = 74.2 % | 0.096 % of frames |

Bursts are identical across all four in onset (88/208/327/448/567 s into an identically-timed poll),
duration, size (293,183 / 215,030 / 293,280 / 215,131 / 293,183) **and alternation parity**
(BIG sml BIG sml BIG in every capture). Four separate arms, two days, two signal paths.
**The SSI/LVDS path is exonerated for both the beat and the floor**, and the beat is a deterministic event
phase-locked to reset with a ~239.5 s two-state cycle — not a drifting or stochastic process.

**5. Mode-2 ROM BIST does NOT test the comb, in any mode.** Comb-absence in mode 1 was established on the
byte-DMA/daemon path (08-26 P1 on 146), and the comb is localised to the delivery plane (ByteRxFifo /
S2MM), which ROM BIST never traverses. The mode-2 comb leg still needs byte source + daemon + delivered
PER with NEL on (the 08-26 pre-registered prediction (b)) — and on 148 it is one-sided, since the accused
egress is 146's.

**6. The silicon start-pulse counter needs no build and no flash — it is already in `786dce9fafc8`.**
`FEC_Decoder_Wrapper` wires `FecCounters .e2(startIn) -> cnt_frame_start` and `.e3(vitReset_1) ->
cnt_vit_reset`, both mapped in `TxRxCompo_ip_addr_decoder.v`. Word address x4 gives the byte addresses;
the mapping reproduces the three known registers (0x104, 0x108) and both witness registers (0x20C/0x210),
which is what makes the two new ones trustworthy:
**cnt_frame_start = 0x124** (FEC decoder `startIn`), **cnt_vit_reset = 0x128** (Viterbi resets);
also cnt_descr_in 0x120, cnt_deint_valid 0x12C, cnt_dec_bits 0x130, cnt_bist_start 0x134.
Runner written and ready: `two_jup/mode2_startcnt_20260830.sh` (`DWELL=400`), carrying the pre-registered
prediction and falsifier verbatim. Self-test before interpreting: healthy must give
d(0x124)/d(0x104) = 1.00 exactly; any other constant means stop and characterise the counter first
(`FecCounters` increments on a level, not an explicit edge).

**7. Recorded, deliberately NOT chased** (would be a new candidate): because the comparator is blind past
bit 120, nothing has ever measured whether the beat damages the rest of the frame. If it does not, the
beat is a *framing* defect that destroys headers — which is what "bad magic" is, and would unify the beat,
the floor and forward PER. Testing it means widening the comparator window, i.e. a build.

### 2026-08-30 15:28–15:37 — **START-PULSE HYPOTHESIS FALSIFIED ON SILICON.** Exactly 1.0000 startIn / vitReset / startOut per frame through three full-magnitude bursts

No flash was used: `cnt_frame_start` (0x124 = FEC `startIn`), `cnt_vit_reset` (0x128 = trellis reset) and
`cnt_bist_start` (0x134 = decoder `startOut`) were already present in the flashed image `786dce9fafc8`,
and this run confirmed them **by read** rather than by build provenance. Runner
`two_jup/mode2_startcnt_20260830.sh`, scorer `two_jup/score_startcnt.py`, data
`two_jup/startcnt/20260830_152844/mode1.csv`. Mode 1 (FPGA-internal digital loopback), ROM BIST, 400 s @ 1 Hz.

Rails: positive control (`0x158=1`, byte source, no daemon) 63,563 err/s vs a 51 err/s floor — the
comparator tracks 148's own TX. Counter self-test on 381 quiet seconds / 484,979 frames:
startIn/frame = vitReset/frame = startOut/frame = **1.0000**. Quiet floor 61.1 err/s, 80.6 % of quiet
seconds exact multiples of 51 (the known floor, reproduced on a fresh arm).

| burst | t | dur | bit errors | startIn/f | vitReset/f | startOut/f |
|---|---|---|---|---|---|---|
| 1 | 87–93 s | 7 s | 293,183 | 1.000 | 1.000 | 1.000 |
| 2 | 206–210 s | 5 s | 215,030 | 1.000 | 1.000 | 1.000 |
| 3 | 323–329 s | 7 s | 293,183 | 1.000 | 1.000 | 1.000 |

Aggregate over 19 burst seconds: 24,183 frames, **801,396 bit errors, exactly 1.0000 starts per frame at
all three taps.** Across all 400 samples startIn/frame stays within 0.9984–1.0016 and vitReset/frame
within 0.9961–1.0039 (±1 count jitter on ~1250); never a second with frames advancing and a zero
start/reset/startOut delta.

**Pre-registered falsifier fired and is reported dead, not reinterpreted.** The spurious/duplicate-start
model is FALSIFIED on silicon. The broader "trellis restarted mid-stream" reading dies with it:
`cnt_vit_reset` is also exactly 1.000/frame through 801k bit errors, so the Viterbi is not being reset at
all. **Both boundaries are clean while the frame's first 120 bits are destroyed at ~33 err/frame.**

**Consequence for the settled paragraph.** It placed the fault in the RX decode/alignment chain *by
inference from the 51-bit decoder signature* (51 = Viterbi converging from an unknown state). **That
inference is now dead.** 51 remains the acquisition quantum in sim, but on hardware these events occur
with no restart, so 51 cannot be read as re-convergence. What survives: the damage is to the frame's
first 120 bits with the start/reset/marker path undisturbed — **the data is wrong, not the framing.**

**Scope — what this does NOT say.** It does not say the loopback is error-free (it is not: 61 err/s quiet,
63/120 bits wrong in the worst second; the zero-error standard is violated throughout), and it does not
exonerate the Viterbi as a *data-path* error source. 0x124/0x128/0x134 are control-path witnesses; they
count events, not bit correctness. A clean control path is fully consistent with the decoder emitting
wrong bits from already-wrong input, or misdecoding correct input. Both untested, as is everything upstream.

**Instrument warning: `cnt_dec_bits` (0x130) SATURATED in this run — all its numbers are void.** It looked
like decoded bits/frame went 6373 → 12254 → 0.0000, which reads as a dramatic data-path signal; it is an
artefact. `FecCounters` saturates at 0xFFFFFFFF rather than wrapping, and the delta went flat at t=212 and
stayed flat contiguously to t=400 after accumulating 3,278,243,230 against 2^32. Discard every 0x130
number from this run. The start counters are ~500k over the run, four orders of magnitude from saturation,
so the falsification is unaffected. Future runs wanting 0x130 must soft-reset between legs or poll faster.

Phase-lock reproduced again on a brand-new arm: onsets 87 / 206 / 323 s, sizes 293,183 / 215,030 / 293,183,
start-to-start 119 / 117 s, BIG-sml-BIG — matching the 08-18 and 08-19 captures exactly.

### 2026-08-30 15:58–16:08 — **THE BURST ERRORS ARE ALREADY PRESENT AT THE DEMODULATOR OUTPUT.** FEC decode stage exonerated as the origin

Follow-on to the 15:37 falsification, answering the operator's question: do we first see errors out of the
demod or out of the Viterbi? Answer: **out of the demod.** No build, no flash — `FecCapture` inside
`FEC_Decoder_Wrapper` already provides three per-frame snapshots (re-armed at `startIn`, first 32 bits each):
`cap_in` 0x13C = `bitsIn` from the demod (pre-deint, pre-Viterbi); `cap_deint` 0x140 = deinterleaver output
(pre-Viterbi); `cap_out` 0x144 = decoded output (post-Viterbi). Runner `two_jup/cap_localise_20260830.sh`,
scorer `two_jup/score_caploc.py`, data `two_jup/caploc/20260830_155824/caploc.csv`. Mode 1, ROM BIST, 400 s @ 1 Hz.

**C1 self-test PASS** (pre-registered: each tap ≥99 % constant on a clean link): cap_in 0x5216F3E2 at
99.47 %, cap_deint 0x52B9CE5C at 100.00 %, cap_out **0x04922282** at 99.21 % — the last being the
independently documented golden used by `carrier_loop_ab.sh`, which re-validates the address mapping.

Three bursts (t=70–77 / 190–195 / 308–314; 293,183 / 215,131 / 293,183 — same species and phase again).
Deviation from golden during the 21 burst seconds: **cap_in 52.38 %, cap_deint 52.38 %, cap_out 52.38 %.**
**Agreement pattern: all three golden (10 s) or all three deviated (11 s). A mixed pattern never occurs.**

**Verdict.** The coded bits reaching the FEC decoder are already corrupted; the deinterleaver and Viterbi
carry damage rather than create it. Had the Viterbi been the origin, cap_in would have stayed golden while
cap_out deviated — that combination occurs in **zero** burst seconds. Combined with the 15:37 result (one
clean start per frame, zero trellis resets through 801k bit errors), **the FEC decode stage is fully
exonerated as the source of the beat.**

**Surviving search space: modulator output → demodulator output** — matched filter, timing/carrier
synchroniser, symbol decisions, and the modulator itself. Note mode-1 internal loopback feeds
`Transmitter_dataOutI/Q` straight into the demod (`TxRxComposite.v:679/735`), so **the TX is inside this
loop and is NOT excluded on silicon**; the 08-30 sim exoneration of the transmitter does not transfer.

**Caveats.** (a) This localises the BURST only — the caps are snapshots, 1 Hz sees one frame in ~1246, and
only 5 quiet seconds showed any deviation, so the 0.09 % floor is unsampled. (b) Do NOT read the quiet
mixed patterns (3× cap_out-alone, 2× cap_in-alone): n=5 is noise, not a second mechanism. (c) The ~52 % is
not a duty cycle — the caps see bits 1–32 while the BIST scores 1–120, so at ~33 err/frame roughly half of
sampled frames have bits 1–32 intact.

Rig restored both times: bring-up exit 0, ARM GATE PASS try 1, daemons+watchdogs up on both boards,
sentinel relaunched 16:08:40. **No flash performed on either board today.**
