> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_R4C_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_R4C — pre-registration, and a FALSIFICATION of the specified predicate  [sim, desk only]

Task 14 (coordinator, 2026-09-04): "cut RXFIX_R4C = R4B plus your own proposed fix — the
skip is inhibited once `push_on_full` has ever fired since reset (sticky flag, cleared only
by reset)". Pre-registered **before any R4C code was written**, as required.

**No variant is cut in this document.** The specified predicate is refuted against banked
Task 12b data, the class of fix it belongs to is shown to be unable to meet the task's own
gate rows, and two viable candidates are put to the controller. Ledger `Task 14:`.

---

## 0. The proposal was mine and it was wrong

Task 12b's report §10 recommended this fix on the strength of a statement of mine that is
**false**: "`push_on_full` is 0 on all six negative-SRO legs". It is **17 on `n_m10`**.
Task 12b's report is corrected (§10.1) and the recommendation is withdrawn there too.

## 1. The specified predicate fails in BOTH directions

Measured from the banked per-frame columns (`<p>_frames.txt` col 26) and skip traces:

| leg | `push_on_full` | first pof frame | R4B skip frames | skips **before** the first pof |
|---|---|---|---|---|
| `n_m10` | **17** | **2** (acquisition burst) | 191 … 426 (30 skips) | **0 of 30** |
| `n_p10` | 28 | **202** | 13 … 19 (7 skips) | **7 of 7** |
| `n_p000`, `n_m40`, `s_m10` tiled, `n_m10c`, `s_m2p5_lol` | **0** | — | — | — |

* **On `n_m10` it destroys the fix.** The acquisition burst fires `push_on_full` 17 times
  at air frame 2 — *before lock*. A flag sticky from reset latches there and suppresses
  **all 30 skips** on the leg the whole variant exists for: forward loss would revert from
  **0.48 % to ~10.93 %**.
* **On `n_p10` it does nothing.** All 7 harmful skips are at frames 13–19; the first
  `push_on_full` is at frame **202**, ~180 frames too late. G14's regression is unchanged.

**The task's own gate row proves the contradiction.** It requires "byte-identity of r4c vs
r4b on `n_m10` … (push_on_full is 0 there so R4C must equal R4B)". `push_on_full` is 17 on
`n_m10`, so under the specified predicate R4C would differ from R4B on exactly the leg the
row asserts they must match. The predicate and the intent are inconsistent.

Making the flag *post-lock* rescues `n_m10` (pof at frame 2 is pre-lock; lock is frame 11)
but still leaves all 7 `n_p10` skips untouched. It is not a fix either.

## 2. No memoryless occupancy predicate can do what the task asks

The task wants R4C ≡ R4B on the negative-SRO legs **and** safe on `n_p10`. At the instant
the first skip is decided, the ring state is the same in the benign, the harmful and the
essential case. The four air frames before the first skip (`oMin/oMax`, all with
`pe = 0`, `pf = 0`):

| leg | f−4 | f−3 | f−2 | f−1 | first skip | verdict on that skip |
|---|---|---|---|---|---|---|
| `n_p000` (0 ppm) | 1/2 | 1/2 | 1/2 | 1/2 | frame 13, occ 1 | benign |
| **`n_p10` (+10 ppm)** | **1/2** | **1/2** | **1/2** | **1/2** | **frame 13, occ 2** | **harmful** |
| `n_m10c` (−10 ppm) | 1/1 | 0/1 | 0/1 | 0/1 | frame 13, occ 1 | essential |
| `n_m40` (−40 ppm) | 0/1 | 0/2 | 0/1 | 0/2 | frame 19, occ 1 | essential |

`n_p000` and `n_p10` are **identical** — 1/2 for four consecutive frames, first skip at
frame 13 — and the subsequent ratchets are 1,3,3,5,6,6 and 2,3,4,5,7,8. Nothing in the
ring state at decision time separates a link that is about to fill from one that is about
to drain. **That information does not exist yet**; at ±10 ppm it takes ~8 frames per entry
of drift to become visible, and ~57 frames to matter. Any predicate that is a function of
the current occupancy (and of `push_on_full`/`pop_on_empty`, both 0 in every row above)
must treat `n_p000` and `n_p10` identically.

**Corollary:** the task's three requirements — (i) R4C ≡ R4B on the negative legs, (ii) 0
harmful skips on `n_p10`, (iii) a memoryless sticky-flag predicate — cannot all be met.
One must be dropped.

## 3. The two candidates that do work, with their costs

**Candidate A — arm on a post-lock `pop_on_empty` (R3S's arming + R4B's structural window).**
Drops requirement (i).

* `n_p10` has **zero** `pop_on_empty` from air frame 3 on (all 178 are pre-lock
  acquisition), so it **never arms**: 0 skips, delivered stream equal to the baseline,
  G14 passes by construction.
* Every negative-SRO leg does run dry post-lock, so the steering still arms there.
* **Cost: the arming hole.** The first hole can no longer be pre-empted, so `n_m10` lands
  near R3S's measured **0.95 %** instead of R4B's 0.48 %, and R4C would **not** be
  byte-identical to R4B on any negative leg.
* Cheap: R3S's arming flop already exists and is already gated.

**Candidate B — observe the drift before acting.** Drops requirement (iii). Latch the
occupancy at each window open and compare against the value 16 windows earlier; skip only
while the ring is net-draining. Preserves R4B's steady-state behaviour on `n_m10`/`n_m40`,
suppresses `n_p10` (net-filling from frame 3), but delays the startup ratchet by ~16 frames
on every leg and needs a new 16-deep shift register plus a gate of its own.

**Candidate C — no new variant: gate per direction.** Already in force — the controller's
Task 13 GO is **148-only**, i.e. R4B on the forward leg where every gate row passes.

## 4. Recommendation

1. **For 148 / forward:** ship R4B as gated. Nothing here changes that.
2. **For 146 / reverse:** **a skip-only variant cannot help the reverse leg at all.** Its
   defect is the FULL edge — `push_on_full` deleting symbols — and R4B/R4C only ever *add*
   entries to a ring that is already against that edge. The best a reverse-leg R4C can do
   is **do nothing** (Candidate A achieves exactly that: zero skips on `n_p10`). If the
   goal is to improve 146, that is a **FULL-side** task, not this one — and note that R3's
   extra-pop branch was the previous attempt and Task 7 measured it at 100 % loss of
   framing.
3. If a reverse-leg-safe *bidirectional* image is wanted, **Candidate A** is the one to
   cut, accepting ~0.5 pp more forward loss for a reverse leg that is never made worse.

**Awaiting the controller's choice between A, B and C before cutting anything.** No board
contact; no 146 flash without the operator.

## 5. If Candidate A is chosen, this is the gate (pre-registered now)

Object dir `obj_byte_sro_rxfix4c`, wrapper `wrap_byte_sro4c.v` with a `WRAP4C_FILE` /
`WRAP4C_DEFINE` provenance print greping the other four wrappers; same nine legs.

| # | leg | criterion | prediction |
|---|---|---|---|
| H1 | `n_p10` | LOSS ≤ `b_p10`'s **4.99 %**, `r4c_skips` = **0** | equal to baseline, byte-identical delivered stream |
| H2 | `n_p000` | content identity vs `b_p000` | equal; skips 0 (no post-lock hole at 0 ppm) |
| H3 | `n_m10` | LOSS ≤ 1.0 % | ~0.95 %, ~21 skips (R3S's numbers, not R4B's) |
| H4 | `n_m40` | LOSS ≤ 5 % | arms at its first post-lock hole |
| H5 | `s_m10` tiled | LOSS ≤ 2 % | R3S measured 1.89 % |
| H6 | `n_m10c` | LOSS ≤ 1 % | arms at the frame-8 hole |
| H7 | all | every skip in `[pcEnd+1, pcEnd+13]` **and** clustered on the leg's own modal `tref` | as Task 12b |
| H8 | injector | W1+R4C kit-shaped application, `verify_zip` green both variants | as Task 12b |

**R4C is NOT predicted to be byte-identical to R4B on any leg** — Candidate A deliberately
delays the first skip. The task's byte-identity rows are therefore replaced by H1's
baseline identity on `n_p10`, which is the property that actually matters.
