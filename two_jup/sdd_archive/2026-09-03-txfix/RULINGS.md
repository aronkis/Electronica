# TXFIX campaign — rulings ledger (extracted 2026-09-03, Task 9)

Every `Ruling` line from `two_jup/sdd_archive/2026-09-03-txfix/progress.md`, in ledger order,
with the context that made it necessary and the cost if it was wrong. **10 rulings**
(the eleventh `Ruling` substring in the ledger is the grammar line in the header, not a ruling).
Extraction is auditable with `grep -n 'Ruling' two_jup/sdd_archive/2026-09-03-txfix/progress.md`.
All were taken by the controller; none was overturned.

---

### R1 — 10:15 · one retry after the Vivado temp-file failure, then UNBUILDABLE [vivado]
> "one retry after removing the stale `.Xil` dir in the F3 remote tree (attempt-1 log kept as
> `build_txfix_vivado.attempt1.log`). If attempt 2 fails the same way → report
> UNBUILDABLE-environment, no third try."

**Context.** F3 attempt 1 died in 3.5 min inside the ADI `axi_adrv9001` IP synthesis on
`Failed to open ./.Xil/Vivado-…/realtime/tmp/genlib…`. Main synthesis never ran, so this was
environmental, not a design error.
**Cost if wrong.** If the failure had actually been caused by the F3 patches, a blind retry would
have burned 90 min of the campaign's only build host and masked a real RTL defect behind
"environmental". The bounded retry (one, with a stated give-up condition) capped that at one
build slot. Attempt 2 ran to completion, confirming the diagnosis.

### R2 — 10:15 · T3a baseline runs on a FRESH arm before the timeline [silicon]
> "T3a baseline runs with a FRESH arm first (`baseline_arm148.sh`, must print
> `ARM_OK fps>=1120 capTAP golden`) so the positive control shares the post-arm phase of the
> fixed-image runs; then `beat_timeline_go.sh SECS=420`. Controller runs the silicon lane directly
> for T3a."

**Context.** The fixed-image timeline necessarily follows a fresh arm (the flash chain arms twice).
A baseline measured on a long-settled arm would not be the same experiment.
**Cost if wrong.** The whole acceptance is a before/after comparison on one instrument. If the
baseline had been taken in a different post-arm phase, an "n=7 → n=0" difference could have been
a phase artefact rather than the fix, and F3's PASS would have been unsupported.

### R3 — 10:29 · the "no gap > 2 s" criterion becomes "no gap > 4 s"; identical for every image [silicon]
> "the effective poll cadence is ~2 s (ssh round trip per read), so the pre-registered 'no gap > 2 s'
> criterion becomes 'no gap > 4 s'; identical criterion for every image; `beat_detect` needs ≥2
> consecutive rows Δ≥5000, which a ~3 s burst still meets at 2 s cadence."

**Context.** The plan pre-registered a 1 s poll; the real cadence is ssh-bound at ~2 s. Loosening a
pre-registered criterion mid-campaign is exactly the move that invalidates pre-registration.
**Cost if wrong.** If a ~3 s burst could be *missed* at a 2 s cadence, "BURSTS n=0" on the fixed
image would be an artefact of sampling, not evidence — the central F3 claim would collapse. The
ruling is defensible only because the detector needs 2 consecutive rows and a burst spans 3-5 rows
at this cadence (observed on the baseline), and because the criterion was applied identically to
baseline and fixed image.

### R4 — 10:32 · the 2 s gap metric is informational; acceptance uses BURSTS n and rows=420 [silicon]
> "the script's 2 s gap metric is informational; acceptance uses `BURSTS n` and `rows=420`,
> identical for every image."

**Context.** T3a reported `gaps_gt_2s=112` — a pure artefact of R3's cadence, not missing data.
**Cost if wrong.** If those gaps had been real data loss rather than cadence, the 420-row window
would cover less air time than claimed on both images, and the "> 6 beat periods" coverage
statement in §91 would be overstated.

### R5 — 10:42 · the sim-lane STALL lines are false positives; register the growing `.bin` as the liveness file [sim/monitoring]
> "sim lanes register the growing `.bin` as their liveness file (or `max_age` 60 min); Task 5
> re-registering; no run was touched."

**Context.** The stall detector flagged 10 gate lanes as stalled while all `Vtxkick`/`Vtxrate`
processes sat at 99 % CPU — the harnesses `fprintf` only at exit, so log mtime is not a liveness
signal for them.
**Cost if wrong.** Acting on the false positives would have killed healthy 40-minute simulation
runs and lost the gate matrix. This is the general lesson carried into §91's memory line: a silent
buffered log is not a stalled job.

### R6 — 11:47 · the no-flash-on-routed-WNS-fail rule stands; one re-implementation retry; F2 not built yet [vivado]
> "the no-flash-on-WNS-fail rule stands (these counters feed the error witnesses); ONE
> re-implementation retry of the same F3 netlist with stronger placement/route/phys-opt directives
> (the plan's allowed timing retry); F2 is not built (it would hit the same instrument paths)."

**Context.** F3 attempt 2 built an image (`873902b705fb`) at routed WNS −0.392 ns, with all 10 worst
paths inside the tx_checker instrument counters — not in the modem DUT, not in the fix. The
tempting reading was "the violations are only in an instrument, ship it".
**Cost if wrong.** Those counters *are* the error witnesses (`bit_errors`/`frame_errs`, feeding
`0x108`). A metastable counter on the fixed image would have corrupted the very evidence the
acceptance rests on — and would most plausibly have corrupted it toward *zero*, i.e. toward a false
PASS. This ruling is the single most load-bearing one in the campaign.

### R7 — 12:12 · gate-lane `max_age` raised to 90 min; process liveness verified by hand [monitoring]
> "gate-lane `max_age` raised to 90 min in `lanes.json` (26 lanes) by the controller — the harness
> logs are silent until exit, so log-age is not a liveness signal for sims; CLEAR lines emitted.
> Process liveness (99 % CPU) verified by hand each time."

**Context.** R5's fix again, applied at scale to all 26 gate lanes.
**Cost if wrong.** Raising a stall threshold is how a genuinely hung job goes unnoticed for 90 min.
The mitigation was replacing the automated signal with a manual one (CPU check per sweep), not
simply deleting the alarm — if that manual check had lapsed, a hung run could have silently
delayed or (worse, given the premature-scoring bug) been scored as complete.

### R8 — 12:35 · F3 is flash-eligible; second build = F2; G6 parked [sim → vivado/silicon]
> "F3 is flash-eligible (every load-bearing gate PASS). Second build = F2 (F1 disqualified by G8).
> G6 parked as an open control question for the write-up."

**Context.** The final exit-gated matrix: F3 clean on G3/G4/G5/G7/G9/G10/G11/G13; G8 F1 FAIL
(`zeroEvents=14`, `pops` 24639/24640); G6 FAIL identically on all three variants.
**Cost if wrong.** Three separate exposures. (a) If G6's failure had been an F3-specific regression
rather than variant-invariant, a defective image went to silicon. (b) If F1 had in fact been clean,
the campaign spent its second build slot on the less informative variant. (c) "Flash-eligible with
a FAIL on the board" is only defensible because the FAIL is variant-invariant and its cause is
identified as a scoring criterion — if that reading is wrong, the sim gate did not actually clear
F3 and the flash was unjustified. G6 is carried as an open item in §91 precisely because this
ruling rests on it.

### R9 — 12:55 · the sel6 witness is the primary silicon evidence; the `0x108` null is corroboration [silicon]
> "the primary silicon evidence is the sel6 512 MB witness (stall runs + per-frame offset-map
> lookups across all ~5445 frames — a live, content-level check with its own positive control on
> yesterday's capture); the `0x108` null is corroboration, labelled as such."

**Context.** *(Corrected 2026-09-03, final review — the ruling stands unchanged; only this context
note was wrong.)* `0x108` did **not** read zero: `two_jup/beattl/20260903_124118/errps.csv` holds a
**constant cumulative 67 on all 420 rows → delta 0** across the full 792 s. The verdict is
unaffected — `BURSTS n=0` rests on the delta — but "read exactly zero" was a misdescription of the
register. `errps=0` post-arm on both gate passes is likewise a *delta*. The timeline does not
populate a packets column on either image, so a low-rate counter fault and a clean link are still
not fully distinguished through that instrument alone. Two facts do now partly answer it: the
counter is **not reset by an arm** (`arm148_mode1.sh` writes only `0x10C 0x60003` and reads
`0x104`/`0x108`; nothing resets the BIST), so the 67 accumulated on F3 between the 12:37 boot and
the 12:41 timeline start — the counter *did* count on this image; and the `0x108` feed paths
(`fill_reg[3]` → `bit_errors`/`frame_errs`, the tx_checker instrument counters that failed at
−0.392 ns in F3 attempt 2) close at **+0.095 ns** on the flashed image and **+0.105 ns** on the
unfixed comparison image, so the n=7 vs n=0 difference is not a timing artefact.
**Cost if wrong.** If the sel6 witness were *not* independently load-bearing, F3's acceptance would
rest entirely on a counter whose liveness on this image was never demonstrated, and the PASS would
be unsupported. The ruling is what keeps the acceptance standing on a live, content-level check
(5,449 frames resolved in the injective map, stalls=0) rather than on an absence of counts. Its
residual cost: the sel6 capture covers ≈ 4.4 s of air time, so the multi-period coverage still comes
from the corroborating instrument — stated explicitly in §91 §4/§5.

### R10 — 12:57 · F3 stays on 148 and is banked VERIFIED; F2 bank-only, not flashed; sentinel stays stopped [silicon]
> "F3 (`f6a8c3ea119c`) stays on 148 and is banked as VERIFIED. F2: bank the bitstream with its
> routed timing, DO NOT flash (operator preference; F3 clean; attribution value already established
> in sim). Sentinel stays stopped until the operator declares the campaign done."

**Context.** F3 passed the pre-registered acceptance. F2's only purpose was attribution, which G8/G9
already settled in sim (F1 dirty, F2 clean at `zeroEvents=0`).
**Cost if wrong.** Flashing F2 would have consumed a flash cycle and a rig slot to re-answer in
silicon a question already answered in sim, while displacing a verified good image — the risk being
a failed flash or a gate failure leaving the board on a worse image. Conversely, if the F2/F3
difference (the fullRAM runaway) ever turns out to matter on silicon in a way sim did not predict,
that discrimination has not been made on the board and cannot be claimed. Leaving the sentinel
stopped keeps the rig deterministic for any follow-up but means the link is out of service until
the operator restarts it.
