# Task 1 (T0a) — harness truth taps + re-score — REPORT  [sim]

Deliverable: `two_jup/comb/COMB32_SRO_SIM_TAPS.md`. Commits `95475f3`, `043bd80`
(branch `per-under-1pct-2026-07`, not pushed). No board contact, no subagents.

## What was built
- `jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v` — six new hierarchical taps: the Rate_Handle
  ring's TRUE 6-bit occupancy `…u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1`
  with `.pop_on_empty_FIFO` / `.push_on_full_FIFO`, and the Preamble_Detector realignment
  FIFO's 14-bit occupancy with its two guard events. `verilator --lint-only` clean.
  **Note:** the s1_rtl tree is pre-slack-patch — no `enSlack`, no `push_on_full_raw` — so
  `push_on_full_FIFO` there IS the `pushOnFullRaw` the brief names. Stated in the doc.
- `sim_sro.cpp` — per-frame counts of all four events, true occupancy at frame start/end
  **and its min/max envelope** (boundary sampling alone would miss a momentary edge touch),
  appended as columns 21–30 of `_frames.txt` (columns 1–20 byte-identical, older scorers
  keep parsing) and 13–18 of `_marks.txt`. Old pointer metric retained as a column.
- `score_sro2.py` — edge test on the true occupancy against the netlist thresholds (ring
  0/**32**, PD FIFO 0/**12333**; the old code tested 31 on a metric that cannot tell 0 from
  32); `exc = pushes − pops`; two-directional phase-lock score with the ±1 gate, the
  reciprocal, and a best-constant-offset diagnostic; per-frame tap self-check
  (`occTE − occTS == pushes − pops`, ±1 boundary beat) — **PASS on all four legs**.
- `runall3.sh` / `runall4.sh`. Build and all legs under transient `systemd --user` units.

## Results

| leg | s | frames | loss % | first true edge | `pop_on_empty` | `push_on_full` | `pdPof` | `pd pop_on_empty` | verdict |
|---|---|---|---|---|---|---|---|---|---|
| `r_p000` | 0 | 162 | 0.00 | none | 0 | 0 | 0 | 0 | NEITHER (control passes) |
| `q_m2p5` | −2.5 | 417 | 4.11 | EMPTY f=137 | 8 | 0 | 0 | 0 | NEITHER; ring-EMPTY candidate INCONCLUSIVE (gate 47.1 %) |
| `q_m10` | −10 | 207 | 23.04 | EMPTY f=34 | 21 | 0 | 0 | 0 | NEITHER; ring-EMPTY candidate INCONCLUSIVE (gate 55.3 %) |
| `q_p2p5` | +2.5 | 914 | 0.11 | **FULL f=843** | 0 | **2** (f=875,907) | 0 | 0 | **INCONCLUSIVE** — RATE_HANDLE_FULL_DELETES confirmed as a *mechanism* (deletion measured at the guard), but n=1 loss so the loss verdict is not earned |

Comb: 32.4 frames at −2.5 ppm (lag-32 +0.452 vs null p95 +0.208), 8.1 at −10 ppm
(lag-8 +0.669 vs +0.219), **none** at +2.5 ppm. Reciprocal phase lock (events with a loss
within ±1): 87.5 % (q_m2p5), 95.2 % (q_m10).

## The three findings that matter

1. **`pdPof` and `pd pop_on_empty` are identically ZERO on every leg, both signs.** The
   Preamble_Detector realignment FIFO deletes nothing and drops nothing. Its occupancy dips
   to 12,332 for one epoch after a skipped valid slot, but neither guard fires. This
   **predicts T1's silicon null** (`enSlack` ON changed nothing): `enSlack` suppresses only
   that FIFO's `push_on_full`, and there was never one to suppress.
2. **The FULL edge is the CHEAP failure.** It genuinely deletes symbols (2 events, measured
   at the guard) but costs 0.11 % with no comb, and the local-time valid-chain census stays
   balanced. The pre-registered f≈876 prediction is confirmed (f=875). That the fast strobe
   *causes* the cheapness is **[inferred]** from the coincidence of those two measurements —
   no deleted symbol was traced to an epoch counter.
3. **The EMPTY edge is the expensive one.** It deletes nothing at the RAM — the guard behaves
   exactly as `RATE_HANDLE_FIX_SURVEY.md` §0 describes — but the skipped valid slot is a
   permanent hole in valid density: local-time deficit equals the event count **one for
   one** (8/8, 21/21), surplus zero, identically at `ss = cfc = cs = pd = corr`, and frames
   die on the same comb. **The survey's "the empty edge is benign" does not survive.**

## Does the earlier "ring deletes at its edge" reading survive?
Half of it. "Reaching an edge causes the loss" survives and is now measured on the real
occupancy. "Only the FULL edge matters / the EMPTY edge is benign" does **not** — it is
inverted. And the survey's own fallback ("either the sim misread FULL as EMPTY, or the
frame-killing step is elsewhere") is decided: not a misread, so **the frame-killing step is
downstream of the ring**, driven by the valid-density hole.

## For T2 (not done here — it is T2 work per the plan)
- The fix must target the **EMPTY** edge / the valid-density hole, not the PD FIFO's guard.
  Making the PD FIFO's pop occupancy-driven leaves the skipped slot in the stream.
- Open question, recorded not explained: at −2.5 ppm the losses form **two** interleaved
  series — one exactly on the event, one **~7 frames earlier**. That second series is what
  drags the losses→event gate to 47.1 %. Settling it needs a per-epoch trace.
- Mark-space vs local-space: mark-space shows matched delete/insert pairs (256/288 at
  −2.5 ppm) because a shifted frame start books as both; local sample time is the census
  that is one-sided. Not a contradiction.

## Rails
Build and legs under `systemd-run --user` (`t1-build`, `t1-legs-a`, `t1-legs-b`), never a
harness background job; heartbeat unit `t1-hb` plus explicit lines from the poll loop.
Commits `-s` with the session trailer, by explicit filename — no `.iq` (the 920-frame
stimulus is 181 MB) and no `.bin` entered the index.
