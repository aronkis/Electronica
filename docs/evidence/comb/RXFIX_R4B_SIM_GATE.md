> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_R4B_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_R4B — sim gate PRE-REGISTRATION  [sim, desk only]

Brief `two_jup/sdd_archive/2026-09-04-rxfix/task-12b-brief.md`; controller design ruling
2026-09-04T17:07:50-04:00 (pre-fill dropped — see §0). **Committed BEFORE the R4B tree
was generated, before the harness was built and before any leg was started.** Ledger
`two_jup/sdd_archive/2026-09-04-rxfix/progress.md`, lines `Task 12b:`.

Harness: `jupiter_240k5_byte/rtl_sim/wrap_byte_sro4b.v` (new file, module name still
`wrap_byte_sro` so **Task 7's `sim_sro.cpp` links unmodified**), object dir
`obj_byte_sro_rxfix4b`, built by `build_sro_rxfix4b.sh`. FOUR files now declare
`module wrap_byte_sro`, so the wrapper prints `WRAP4B_FILE` / `WRAP4B_DEFINE` at time 0
and the build script greps the verilate log for the **other three**.

No board contact. Every row below is [sim].

---

## 0. What R4B is, and the two things it is NOT

R4B = **lock (8 `pcEnd` pulses) → skip inside a STRUCTURAL window → ring self-centres at
9/10.** In `Rate_Handle`:

* `r4b_pop_nom = validIn & Compare_To_Constant_out1` — the baseline pop.
* `Logical_Operator_out1 = r4b_pop_nom & ~r4b_skip_en`, where `r4b_skip_en` is a
  **register**. Until the first arm, `r4b_skip_en = 0` and the pop expression is
  **literally the baseline expression** — the structural s = 0 property R3S had and R4
  gave up.
* The window is opened by `Packet_Controller.endOut` (`pcEnd`), is exactly **13 nominal
  pop slots** wide, and admits **at most one skip per `pcEnd`**.

**NOT a pre-fill.** The brief's items 4 (bounded pre-fill with a 4096-tick timeout) and
the whole `r4b_prefilled` flag are **deleted**, on the controller's 17:07 ruling from
Task 12's measured smoke diagnostics: the 0 ppm acquisition deficit is **~34 entries**,
larger than the 16 a pre-fill buys and larger than the 32-deep ring, so no pre-fill
depth survives acquisition. R4B therefore fails **toward baseline** (no arm ⇒ baseline
pop), not toward no-output.

**NOT "deframer idle".** The R3S/R4 predicate `guardIn = ~sample_discard_controller.active`
opens on any idle period — false sync, missed sync, filler or garbage frame — which is
the defect the adversarial review found (one of 240 R3S skips fired mid-payload after a
false sync and that frame died). R4B's window is keyed to `pcEnd`, the deframer's own
end-of-packet pulse, and closes after 13 slots.

## 1. Thresholds, and why they were not retuned

`occ ≤ 8` and the 13-slot window are **kept**. Brief item 7 made the threshold
conditional on Task 12's R4 gate; the controller's 17:07 diagnostics (occupancy
ratchets 1 → 9 and sits flat at 9/10 with `pop_on_empty = 0`) are that evidence and they
arrived **before** any R4B leg. The pre-fill depth 16 is not retuned because there is no
pre-fill. No threshold is chosen from an R4B measurement.

## 2. Predictions, stated before the run (arithmetic on Task 7's banked columns)

Drift is `12333 × |s|` ring entries per air frame; one skip supplies one entry.

| leg | ppm | drift/frame | post-acq occupancy (banked) | predicted first skip | predicted skips |
|---|---|---|---|---|---|
| `n_p000` | 0 | 0 | 1/2 (`b_p000`, pf = 0) | air frame ~13 (lock) | **8** (ratchet 1→9), then flat |
| `n_m10` | −10 | 0.1233 | **31** (`b_m10` air frame 2 goes 1→31, pf = 17) | ~frame 199 (drain 31→8) | **~28** |
| `n_m40` | −40 | 0.4933 | 0/1 (`b_m40`, pf = 0) | ~frame 14 | **~212** |
| `s_m10` tiled | −10 | 0.1233 | 5/4 (`tb_m10`, pf = 0) | ~frame 14 | **~23** |
| `n_m10c` | −10 +20 kHz CFO | 0.1233 | as `n_m10` | ~frame 199 | **~28** |
| `n_p10` | +10 | fills | ring rises to FULL | — | **0** (predicate false) |
| `s_m2p5_lol` | −2.5 | 0.0308 | as `s_m2p5` | after lock | **~8–13** |

The `n_m10` number reconciles R3S's measured 21: R3S armed only at its first hole
(frame 259) and 21 = (428 − 259) × 0.1233. R4B arms earlier (at occ ≤ 8, frame ~199), so
28 ≈ (428 − 199) × 0.1233. The **bands below are the brief's / Task 12's, unchanged**,
so these predictions are inside bands that were fixed before I computed them.

**Skip position.** `pcEnd` is one `enb_1_2_0` tick wide (`sample_discard_controller`
clocks `endOutReg` under `enb_1_2_0_gated` from the one-tick `End_Generator` pulse), so
one register `r4b_pcend_d` is enough to detect it. Budget from Task 11's dump (pcEnd at
rel −4, first nominal pop at rel −1): window opens at rel −3, `r4b_skip_en` sets at
rel −2, the skip lands at rel −1 = **slot 1**. Predicted histogram mode **slot 1**, with
slot 2 possible on a phase-unlucky frame. **Every** skip must be in slots 1..13.

## 3. The gate

Scored with `score_t7.py` (seq denominator: lost frames ARE in the denominator),
`t12_ident.py` (content identity), `t11_align.py` (hole/skip/loss alignment),
`score_sro2.py` (tiled leg), and the new `t12b_window.py` (skip-position histogram).
Baselines `b_p000` / `b_m10` / `b_m40` / `tb_m10` are Task 7's and are **not re-run**;
`t_lol` is Task 6's baseline on the loss-of-lock stimulus and is not re-run. Two
baselines **are** run because their stimuli are new: `b_m10c` and `b_p10`, both on Task
7's unmodified `obj_byte_sro/Vwrap_byte_sro`.

| # | leg | quantity | PASS criterion |
|---|---|---|---|
| **G1** | `r4b_p000` | delivered content vs `b_p000` | `t12_ident.py` content_equal = True on every common seq (nwords/FNV/user), ≥ 420 common seq |
| **G2** | `r4b_p000` | `r4b_skips` | **4 ≤ skips ≤ 14**, ALL inside the first 12 air frames after lock, none after |
| **G3** | `r4b_p000` | ring after the ratchet | occupancy plateau `oMin/oMax` in **[8, 12]**, and `rh_pop_on_empty = 0` on every air frame after the last skip |
| **G4** | `r4b_p000` | pre-lock identity | delivered frames with seq delivered before the first skip are byte-identical to `b_p000` **including sidx** (structural: the pop is the baseline expression until the first arm) |
| **G5** | `r4b_m10` | LOSS (seq denominator) | **≤ 0.5 %**, and the only permitted losses are seq **133/134** |
| **G6** | `r4b_m10` | `rh_pop_on_empty` in the scored window | **0** |
| **G7** | `r4b_m10` | `r4b_skips` | **15 ≤ skips ≤ 35** |
| **G8** | `r4b_m10` | skip position | **every** skip in slots **[pcEnd+1, pcEnd+13]**; histogram reported |
| **G9** | `r4b_m40` | LOSS | **≤ 1 %** |
| **G10** | `r4b_m40` | `r4b_skips` / position | 150 ≤ skips ≤ 260; **every** skip inside the structural window |
| **G11** | `r4b_tm10` | LOSS (`score_sro2.py`) | **= 0.00 %** |
| **G12** | `r4b_m10c` | LOSS at −10 ppm **+20 kHz CFO** | **≤ 0.5 %**; every skip inside the window |
| **G13** | `b_m10c` | baseline LOSS on the same CFO stimulus | report; pre-registered **≈ `b_m10`'s 10.93 %** (band 5–20 %). If the baseline does not lose frames on this leg the leg is VACUOUS and G12 is reported as such |
| **G14** | `r4b_p10` vs `b_p10` | +10 ppm, FULL side | **loss(R4B) ≤ loss(base)** (no regression; R4B does not fix the FULL edge) |
| **G15** | `r4b_lol` | re-lock after a forced outage (4.05 air frames deleted at frame 200) | `r4b_locked` stays 1 across the outage (never cleared except by reset), **no skip fires inside the outage window**, and framing is re-acquired: delivered frames after the outage ≥ `t_lol`'s |
| **G16** | all legs | wrapper provenance | `WRAP4B_FILE wrap_byte_sro4b.v t12b` **and** `WRAP4B_DEFINE RXFIX_R4B` present; verilate log names **none** of `wrap_byte_sro.v`, `wrap_byte_sro3s.v`, `wrap_byte_sro4.v` |
| **G17** | injector | kit-shaped W1 + R4B application | W1 then R4B on a kit-shaped tree (prefixed module names, three loose mirrors, **both** zip members) with `verify_zip` green for both variants, and the eight existing W1 read words byte-identical in the injected text |

## 4. Falsifiers, named in advance

1. **Any** skip outside `[pcEnd+1, pcEnd+13]` ⇒ the window logic is wrong. Report the
   offending records; do not reinterpret the window.
2. Any `n_m10` loss aligned to a skip (as the baseline's losses are aligned to its
   holes) ⇒ position does not matter after all ⇒ per-stage `stagewin` dump around one
   skip, as Task 11 did.
3. `r4b_skips` = 0 on `n_m10`/`n_m40` ⇒ the pcEnd window never opened (or lock never
   came true) ⇒ the ninth-word witness `r4b_window_opens` distinguishes the two.
4. G4 failing (pre-lock delivery not byte-identical) ⇒ the steering is disturbing the
   receiver before it can possibly have armed ⇒ stop, do not score the rest.

## 5. What is NOT claimed by this gate

* **No silicon claim.** No synthesis, no timing, no resource, no PER number. The
  registered decision (item 3 of the review) is a reading of the RTL plus a lint pass,
  not a timing result.
* R4B does **not** remove the one-symbol epoch slip: `Peak_Search`, `Timing_Adjust` and
  `End_Generator` all count VALIDs, so a skipped valid still slips all three epochs by
  one symbol. R4B bounds **where** the deficit is absorbed.
* The **FULL edge / positive SRO is untouched** and is only observed (G14).
* A `pcEnd` produced by a FALSE sync opens a window in the wrong place. R4B bounds the
  damage to one 13-slot window per false frame instead of R3S/R4's whole idle period; it
  does not eliminate it. Stated here so it is not discovered later.

---

## 6. AMENDMENT 2026-09-04T17:4x, before any leg was scored

Added a **stricter** falsifier and two extra measurements. No criterion is weakened, no
band is moved, and nothing here was informed by a leg result — the nine legs were still
running and only the 25-frame smoke had been read. It is recorded as an amendment rather
than an edit so the original table stays auditable.

**F1b (new falsifier, and it is the one that matters most).** `slot_rtl` measures position
relative to **the deframer's own** `pcEnd`. After a **false sync** the deframer emits a
`pcEnd` 12,320 symbols into the wrong place, so a skip in that frame's guard band is
**mid-payload of the true air frame while still reading `slot_rtl` = 1..13**. The window
counter cannot see it, so falsifier 1 alone would pass exactly the defect finding (1) of
the adversarial review is about — R3S's `s_m40` skip at air frame 138, which fired after a
false Preamble_Detector sync at **tref 7026** and killed that frame, against R3S's clean
skips at tref 52/21/28.

`tref` (`Peak_Search.timing_Reference` mod 12,333) is an **air-frame-referenced** clock
that a moved `pcEnd` does not move, and it is already recorded on every trace line. So:

> **every skip must be within 60 symbols of the epoch boundary** (`min(tref, 12333-tref) ≤ 60`).
> Any skip outside that is a **mid-payload skip** and is reported as such, per leg,
> whatever `slot_rtl` says.

This is reported as a **second, independent window row** for every R4B leg, and it is the
row that carries the claim that R4B fixed the mid-payload skip.

**G15 is sharpened.** As well as "no skip inside the outage", the **re-acquisition**
window (air frames 195–220, and 198–206 around the 4.05-frame deletion at frame 200) is
listed skip by skip with `tref`. If none fires mid-payload there, that is the strongest
silicon-relevant claim in the gate; if one does, it is the finding, and §5 already said
R4B bounds this case rather than eliminating it.

**G4 is generalised to every paired leg** (`t12b_prearm.py`, new). Because the pop is
literally the baseline expression until the first arm, *every* frame delivered before the
first skip must match the baseline **including `sidx`** — not just on `n_p000`. On `n_m10`
the first skip is predicted at frame ~199, so this converts ~190 delivered frames into a
structural identity test at no cost. A single pre-arm mismatch is a real failure, since the
steering cannot have acted yet.
