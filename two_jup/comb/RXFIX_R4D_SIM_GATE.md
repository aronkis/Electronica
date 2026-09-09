# RXFIX_R4D — sim gate PRE-REGISTRATION  [sim, desk only]

Task 14, coordinator decision 2026-09-04: **R4D = R4B + the FULL-side mirror inside the
same structural window.** When occupancy **≥ 24** in the window `[pcEnd+1, pcEnd+13]`, take
**one extra pop** (emit one extra valid), at most one per `pcEnd`, registered exactly like
the skip. Committed **before any R4D code was written**. Ledger `Task 14:`.

## 0. Why this is not R3's extra pop again

Task 7 measured `r3_extras = 4` accompanying **100 % loss of framing**, and R3's extra-pop
branch was deleted rather than fixed. The difference is the **window**: R3's extras fired
under a "deframer idle" predicate — which is also true after a false sync, a missed sync
and during acquisition — and R3 had no lock term, so its extras landed in acquisition,
outside any frame structure. R4D's extra is gated on **lock (8 `pcEnd` pulses)** and on the
**13-slot structural window**, i.e. exactly the guard band where Task 11 §5 measured a
skipped valid to disturb **nothing**: `Rate_Handle`/CFC/CS/Correlator valid counts each
−1, `Preamble_Detector` and `Packet_Controller` unchanged, and every control signal
identical. R4D's `+1` is the mirror of that measured `−1`. It is a legitimate test with a
named falsifier, not a repeat.

**Symmetry, and the one asymmetry.** Both edges slip the valid-counting epochs by one
symbol (Task 12b §9 does not claim otherwise). The asymmetry worth stating: a skip
*suppresses* a pop, while an extra *reads the ring RAM* — but the trigger is occupancy
≥ 24 of 32, so the entry emitted is genuine buffered data, never the empty-ring garbage
that `pop_on_empty` exists to suppress.

## 1. Which legs can even differ from R4B — measured, not assumed

Maximum ring occupancy **after lock**, from the banked Task 12b `_frames.txt`:

| leg | lock frame | max `oMax` after lock | frames with `oMax ≥ 24` | R4D vs R4B |
|---|---|---|---|---|
| `n_p000` | 13 | **10** | 0 | **cannot differ** |
| `n_m40` | 19 | **10** | 0 | **cannot differ** |
| `s_m10` tiled | 10 | **10** | 0 | **cannot differ** |
| `n_m10c` | 13 | **10** | 0 | **cannot differ** |
| `s_m2p5_lol` | 10 | **10** | 0 | **cannot differ** |
| `n_m10` | 11 | **31** | 63 (frames 11–73) | short ratchet then identical |
| `n_p10` | 13 | **32** | 300 (frames 129–428) | **the leg the variant is for** |

So on five of seven legs R4D ≡ R4B **structurally** (the `≥ 24` predicate is never true
after lock), and content identity there is a prediction about the RTL text, not a hope.

## 2. The gate

Object dir `obj_byte_sro_rxfix4d`; wrapper `wrap_byte_sro4d.v` printing
`WRAP4D_FILE`/`WRAP4D_DEFINE` and greping the verilate log for the other **four**
`wrap_byte_sro` files. Same nine legs, same scorers, plus `t12b_window.py` extended to
carry a `kind` column (0 = skip, 1 = extra).

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| **J1** | `n_p10` | LOSS | **≤ 1 %** (baseline `b_p10` **4.99 %**, R4B **6.65 %**) |
| **J2** | `n_p10` | `push_on_full` in the scored window | **0** (baseline 21, R4B 28) |
| **J3** | `n_p10` | ring | self-centred at **23/24 from above**; `r4d_extras` ≈ **one per 8.1 frames** |
| **J4** | `n_p10` | falsifier | **no loss aligned to an extra** (±1 frame), scored as Task 11 scored skips |
| **J5** | `n_p000` | content identity vs `b_p000` | equal; `r4d_extras` = **0** (occupancy never ≥ 24) |
| **J6** | `n_m40`, `s_m10` tiled, `n_m10c`, `s_m2p5_lol` | delivered stream vs **R4B** | **byte-identical** (`_deliv.txt` equal) and `r4d_extras` = 0 |
| **J7** | `n_m10` | trajectory | a short ratchet **31 → 23** by extras in the first guard windows after lock (~8 extras, frames 11–19), then no further extras |
| **J8** | `n_m10` | LOSS | **≤ R4B's 0.48 %**; content-identical to `b_p000`-style scoring on the common seq |
| **J9** | all | skip **and extra** position | every event inside `[pcEnd+1, pcEnd+13]` and clustered on the leg's own modal `tref` |
| **J10** | all | wrapper provenance | `WRAP4D_FILE`/`WRAP4D_DEFINE`, no other wrapper in the verilate log |
| **J11** | injector | W1+R4D kit-shaped application | `verify_zip` green for both variants on both zips; lint clean both lineages |

## 3. Predictions, stated before the run

* `n_p10`: extras begin once the ring first reaches 24 after lock (**frame ~129** by the
  banked trajectory), then one per **8.1** frames to the end → **~37 extras**;
  `push_on_full` → **0**; loss → the baseline's non-FULL residual, predicted **≤ 1 %**.
* `n_m10`: **~8 extras** in frames 11–19 ratcheting 31 → 23, then none; the ring reaches
  the skip threshold ~58 frames earlier than R4B, so skips start ~frame **133** instead of
  191 and there are **~36** of them (vs R4B's 30). Loss unchanged at ~0.48 %.
* `n_p000`, `n_m40`, `s_m10`, `n_m10c`, `s_m2p5_lol`: **zero extras, byte-identical to R4B.**

## 4. Falsifier and the fallback

Any `n_p10` loss aligned to an extra ⇒ **the `+1` side is not harmless in the guard band**,
and R4D is refuted as R3 was. The fallback is then candidate **(b)**: drop a **push**
instead of adding a pop. The push side leads the deframer by the ring occupancy, so the
drop must be **scheduled to land in the next window** — the decision delayed by `occ`
symbols — and that is a separate cut with its own gate. **(b) is only cut if (a) fails**,
and the report must say why.

## 5. Rails

Sim only; no board contact; **no 146 flash without the operator**. R4B, R4C-that-was-never-cut,
Task 12's R4 and Task 7's `sim_sro.cpp` are all untouched. Marker `RXFIX_R4D`.
