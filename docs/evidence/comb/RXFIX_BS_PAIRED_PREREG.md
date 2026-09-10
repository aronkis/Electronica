> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_BS_PAIRED_PREREG.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX Task 51 — pre-registration: the paired-PER census leg

Written and committed BEFORE the leg. Board 148, image `dec007ae70dd`
(W1 + R4B + RXFIX_BS), FIXCTL_BASE=0x0.

## The question

Task 49 and Task 50 established that the byte-seam census is live, coherent under
freeze, and quiet: `dBS_DROP = 0` and `dBS_TRUNC = 0` over 55 s / ~69,000 frames.
That is a liveness control, **not a loss exclusion** — no PER was measured on the
same window, so "the census saw no drops" and "no drops happened where the loss is"
are not yet the same statement. This leg measures both on one window.

## The leg

    launch_rig_unit.sh <unit> two_jup/rxfix/w1leg_go.sh \
      MODE=air LEG=A BOARD=148 DUR=600 PERIOD=10 \
      BS=1 P8=1 R4B=1 EXP=dec007ae70dd FIXCTL_BASE=0x0 DRY=0 OUT=<run>

under a keeper hold, with a background watcher. `legrun_go.sh LEG=A` arms the pair
and captures (146 TX → 148 RX); the reader opens `DUR-120 = 480 s` after the health
gate resolves and takes one frozen sweep every 10 s. AUX = `0x104 0x124 0x150 0x134
0x130`. Scored by `w1_score.py` (instrument), `accept_analyze.py` (whole-leg PER),
and `bs_pair_score.py` (the pairing — census window intersected with the capture on
the board's own clock via the new `t_board` field).

## Expected sample count

~480 s at ~1250 f/s ≈ 600,000 frames in the census window. At the shipped forward
PER of 0.079 % that is **≈ 474 lost frames** — the number that makes a quiet census
informative. (Task 50's 55 s control contained only ~54, which is why it could not
carry an exclusion even in principle.)

## Pre-registered branches

**B1 — quiet with loss (expected).** `dBS_DROP = 0`, `dBS_TRUNC = 0`, windowed PER
> 0 with ≥ 200 lost frames. Reading: the residual loss is **not** the ByteRxFifo
drop-oldest class. It is downstream of the census taps or invisible to them. This
is a localisation, not an exoneration of the receiver, and it will be written that
way.

**B2 — census fires.** `dBS_DROP > 0` at a rate comparable with the loss rate
(ratio 0.5–2.0 of lost frames). Reading: the byte seam is implicated; next step is
per-interval alignment of drops against burst onsets (`accept_analyze.py
--burst-times`).

**B3 — census fires at the wrong rate.** `dBS_DROP > 0` but the ratio is outside
0.5–2.0. Reading: a second, unrelated drop process; report both numbers, claim
neither.

**B4 — no loss in the window.** Windowed PER = 0. UNINFORMATIVE for the exclusion;
`bs_pair_score.py` refuses to call it one.

## Falsifiers and refusals (fail-closed)

- Image readback ≠ `dec007ae70dd` → `W1LEG_REFUSED`, no leg.
- `deliver_rate_pre` or `deliver_rate_post` < `RATE_GATE=900` → `LEGRUN_GATE_FAIL`,
  the leg is **UNINFORMATIVE**, one re-run then stop.
- `freeze_effective: false` on any reading → that reading is not scored.
- `BS_CNT[7:0] ≠ 0` on any reading → fail-closed contract broken, the census words
  are not what the map says; no verdict.
- Any reading with `t_board = null` → `bs_pair_score.py` refuses the pairing rather
  than assume a host↔board clock offset.
- A recovered mid-window collapse (`recovery.txt`, `MID_RECOVER=1`) overlapping the
  census window → `bs_pair_score.py` **refuses** (rc 4). The census is frozen straight
  across such an interval, so its gap would be charged to the PER as loss the census
  never saw. `--allow-perturbed` scores it by cutting the interval out of BOTH sides
  (per-span host_seq denominators; census intervals touching the event dropped), and
  any leg scored that way will be labelled PERTURBED with its excluded seconds.
- A `recovery.txt` that is present but not fully parseable → **refused** (rc 4) as
  well. An unreadable line yields no event, so the overlap test above would see a
  clean window; the unread events could sit anywhere in it.
- `dBS_DROP` is scored as **deltas only**. This leg arms, so the absolute `BS_DROP`
  resets to a new post-arm baseline (Task 50's static 190 will not recur); a
  cross-leg absolute difference is meaningless.

## P8 (0x130 cnt_dec_bits)

Added by the new `P8=1` knob, which is off by default so every other leg's AUX list
stays byte-comparable. `0x130` **saturates** to `0xFFFFFFFF` ~281 s after an arm, and the reader window
opens only after the two-pass health gate resolves — nominally ~120 s, but the leg's
own `READER_ABORT` bound allows up to 480 s. So **0 to ~16 readings can carry an
unsaturated P8**, depending on how fast that gate resolves: a slow gate means none at
all, and most of the window cannot carry one in any case. `w1_score.py` already refuses a
saturated P8 with an explicit line. P8 does not gate this leg; the number of
unsaturated readings will be reported as a fact either way.

## What will NOT be claimed

- Not "the census conserves exactly" — the sweep is not start-aligned, so word
  conservation is only ever "within one partial frame at the window boundaries".
- Not "BS_STARTS is confirmed to count frame starts" — the `0x134` control proves
  the two counters count the same events at the same rate, not what those events
  are; the 191.00 words/start ratio is what ties them to frames.
- Not a frame rate quoted from the delivery sentinel's `rate=` (it aliases high).
