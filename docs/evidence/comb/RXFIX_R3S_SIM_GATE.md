> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_R3S_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_R3S — pre-registered sim gate  [sim, desk only]

Task 11, brief `two_jup/sdd_archive/2026-09-04-rxfix/task-11-brief.md`, ledger
`two_jup/sdd_archive/2026-09-04-rxfix/progress.md` (`Task 11:` lines), branch
`per-under-1pct-2026-07`.

**Written and committed BEFORE any Task 11 leg was started.** Every number below is a
prediction; the measured column is filled in `task-11-report.md` and nowhere else. No
board contact, no Vivado, no subagents.

## 0. What is being tested

R3S is skip-only, acquisition-safe guard-band steering: while **armed**, the first
nominal Rate_Handle pop inside the deframer's inter-frame guard window at occupancy
≤ 1 is suppressed, at most once per window. Arming requires (a) eight deframer frames
(lock) and (b) a post-lock `pop_on_empty`. Before arming the pop expression is
literally the baseline expression.

The **mechanism under test**, stated so it can fail: steering drives the ring to a new
operating point around occupancy 2–3 at which the EMPTY edge is no longer reached at
all, and the residual deficit is absorbed where the deframer discards symbols. If the
mechanism is right, the losses disappear *and* `rh_pop_on_empty` in the scored window
goes to ~0 — not merely moves.

## 1. Legs, binaries and stimuli

| leg | binary | stimulus | nsamp | scorer | banked baseline |
|---|---|---|---|---|---|
| `s_p000` | `obj_byte_sro_rxfix3s/Vwrap_byte_sro` | `n_p000.iq` (non-repeating, 0 ppm) | 21,114,096 (428 fr) | `score_t7.py` + md5 | `b_p000` LOSS 0.00 % |
| `s_m10` | same | `n_m10.iq` (non-repeating, −10 ppm) | 21,114,096 | `score_t7.py` | `b_m10` LOSS **10.93 %** |
| `s_m40` | same | `n_m40.iq` (non-repeating, −40 ppm) | 21,114,096 | honest delivered/OK count | `b_m40` LOSS **78.1 %** |
| `s_tm10` | same | `s_m10.iq` (TILED control) | 8,139,780 (165 fr) | `score_sro2.py tb_p000 …` | `tb_m10` LOSS **22.01 %** |

Baselines are Task 7's and are **not re-run**. Command shape for every leg:
`Vwrap_byte_sro rx <iq> <nsamp> 8400 <pfx> 2 0`, one transient
`systemd-run --user` unit each with `WorkingDirectory=two_jup/comb/sro_sim`.

Witness mapping (the R3S wrapper carries the witnesses on Task 7's three witness
ports so that `sim_sro.cpp` is used **unmodified**):

* `r3_skips` in `<p>_res.txt` **is** `r3s_skips` (steered pop SKIPS);
* `r3_extras` in `<p>_res.txt` **is a SENTINEL, not a count**: `0xA5A50001` while
  `r3s_armed`, else `0`. R3S has no extra-pop branch at all;
* `<p>_ep.txt` kind **4** = one steered skip; kind **5** = the single arming instant.

## 2. Gate table — pre-registered

Pass requires **every** row. Bands, not point values, are given where the transient
after arming makes a point value dishonest (see §3).

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| G1 | `s_p000` | delivered byte stream | `md5(s_p000_deliv.txt) == md5(b_p000_deliv.txt)` — **byte-identical** |
| G2 | `s_p000` | `r3s_armed` | 0 throughout (`r3_extras = 0` in `_res.txt`, no kind-5 record in `_ep.txt`) |
| G3 | `s_p000` | `r3s_skips` | **exactly 0** |
| G4 | `s_m10` | LOSS (seq denominator, lost frames included) | **≤ 0.5 %** (baseline 10.93 %) |
| G5 | `s_m10` | `r3s_skips` | **15–35** (nominal ≈ 21 = one per 8.1-frame hole cycle over the 169 post-edge frames, plus the arming transient) |
| G6 | `s_m10` | `rh_pop_on_empty` inside the scored window | **≤ 2** (nominal 1 = the arming hole itself; baseline 21) |
| G7 | `s_m10` | hole/skip/loss alignment | the residual lost frames are **not** aligned to `r3s_skips` (see the falsifier, §4) |
| G8 | `s_m40` | LOSS | **< 5 %** (baseline 78.1 %) |
| G9 | `s_m40` | `r3s_skips` | **150–260** (nominal ≈ 211) |
| G10 | `s_tm10` | LOSS (`score_sro2.py`, Task 6 definition) | **≤ 0.5 %** (baseline 22.01 %) |
| G11 | all | wrapper provenance | every run prints `WRAP3S_FILE wrap_byte_sro3s.v e7c1` and `WRAP3S_DEFINE RXFIX_R3S` |

G11 is not cosmetic. Two files declare `module wrap_byte_sro`; if Verilator had read
Task 7's wrapper, the witnesses would tie to 0 and that failure would look exactly
like the G2/G3 **pass** condition.

## 3. Why bands, and the arming transient — stated in advance

At −10 ppm the ring drifts by 12,333 · 10⁻⁵ = 0.123 entries per air frame, and after
the drain the measured per-frame occupancy envelope on `b_m10` is `oMin = 0,
oMax = 1` for **every** frame from ≈ 250 onward. So immediately after arming the
`occ ≤ 1` predicate is true in consecutive guard windows and R3S will take **one skip
per frame for a few frames** until occupancy has climbed above the threshold; only
then does it self-regulate to one skip per ≈ 8 frames (the drift rate). The nominal
21 is the steady-state count; the transient adds a handful. A gate written as
"≈ 21" would have been argued post hoc, so the band is 15–35 and the transient is the
stated reason.

`b_m40` drifts 16× faster (0.49 entries/frame), so its steady-state rate is one skip
per ≈ 2 frames over ≈ 425 frames → ≈ 211, with a proportionally shorter transient.

## 4. Falsifier — pre-registered, and it ends this line of work

If `s_m10` still loses ≈ 2 frames per **skip** — i.e. the residual losses are aligned
to the `r3s_skips` events (kind 4) the way the baseline's losses are aligned to its
holes (kind 0) — then **the position of the skipped slot does not matter**, the death
is not a framing-window effect, and no amount of steering will fix it.

In that case the deliverable is the dump, not another variant: `sim_stagewin`
(`jupiter_240k5_byte/rtl_sim/sim_stagewin.cpp`) dumps **every** `enb_1_2_0` beat for
±64 beats around ONE skip at every stage output — Rate_Handle out, CFC,
Carrier_Synchronizer, Preamble_Detector correlator / Peak_Search / Timing_Adjust, and
Packet_Controller — together with the matched ±64-beat window **one air frame earlier
at the same intra-frame phase** (a frame with no skip). The report then names the
first stage whose behaviour differs between the two windows.

## 5. Things that are NOT claimed

* R3S does not remove the epoch slip. `Peak_Search.timing_Reference`,
  `Timing_Adjust.timing_Reference` and `End_Generator`'s counter all count VALIDS, so
  a skipped valid still slips all three epochs by one symbol. R3S bounds *where* the
  hole lands. **A residual is expected and is reported as measured, not rounded.**
* The FULL edge / positive-SRO case is **out of scope**. R3's extra-pop branch is
  deleted, not fixed.
* `b_m2p5` is not a gate leg: Task 7 measured zero hole events in its scored window,
  so it is vacuous for or against any steering variant.
* No silicon claim of any kind. R3S has not been synthesised; there is no timing or
  resource number in this document.
