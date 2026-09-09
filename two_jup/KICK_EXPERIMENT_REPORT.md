# Forced-kick displacement experiment — report (2026-09-01, all reproduced in sim)

Netlist: `s1_rtl_txmark` (flat `--public-flat-rw` build, `wrap_byte_ddrcap.v`, `obj_kick/Vkick`
built from `sim_kick_taps.cpp`, itself derived from `sim_burst_force_txmark.cpp` with the DDR
record-write loop copied verbatim from `sim_golden_taps.cpp`, per the Task-2 brief). Selector 6
(tap3, symbol domain), skew +1 (§36 anchoring), scored with the unmodified
`two_jup/t6_score_large.py` against the unmodified `two_jup/offsetmap/tap3_word_to_offset.tsv`.
Five cases, NF=20, K=12 (force applied at packet 12), launched concurrently under
`systemd-run --user`, one single-threaded process per case (~4 kclk/s). All results below are
labeled **reproduced in sim**.

## Positive control — PASS

Case `none` (no force applied — `apply()` is skipped for `sel=="none"` in `sim_kick_taps.cpp`):
every one of the 46 scored frames (indices 0–45, i.e. every frame, which is a superset of "every
frame after frame 8") maps to offset 0 with the tap3 map:

```
scored 46 frames: 46 placed, 0 displacement-inexplicable
  aligned at 0      : 46
  on a known rung   : 0
  INTERMEDIATE (0,6176): 0
  0<->rung transitions observed: 0
```

The positive control passes: the tap3 map applies to this netlist build. Predictions A/B may be
read. **reproduced in sim**.

`none`'s `KICKTAPS` line reports `biterr=51` (nonzero), which is not itself part of the map-based
control criterion but is worth closing explicitly: `awk '!/^#/ && $2>0 {print $1,$2}'
beat_runs/kick_none_frames.txt` shows all 51 errors land at **packet 2** — well before the
packet-9+ control window — and zero errors from packet 3 through 45. The control is clean by both
measures.

## Per-case results

All FORCED lines confirm the force landed at packet 12 as specified (`# FORCED <sel> at packet 12
clk 1283668 fifo push=56 pop=56 occ=12333`), and for `slip1` the pre-force joint reference was
`offset_before=12323 shift=1`.

### `ss` (Symbol-Sync loop-filter integrator forced to max)
- Per-frame offset sequence, frames 8–44 (run stops at frame 38 — see below):
  `8:0 9:0 10:0 11:0 12:0 13:None 14:None 15:None 16:None 17:None 18:None 19:None 20:None
  21:None 22:None 23:None 24:None 25:None 26:None 27:None 28:None 29:None 30:None 31:None
  32:None 33:None 34:None 35:None 36:None 37:None 38:None` (no packets 39–44 exist in this run).
- Counts: aligned-at-0 = 13 (frames 0–12), on-rung = 0, intermediate (0,6176) = 0,
  None (word not in map) = 26 (frames 13–38).
- **All five runs used the identical clock budget** (`total = 100 + 24*197328`), and `ss`'s
  process printed its final `KICKTAPS` line, i.e. it ran to completion — it did not run out of
  budget. What differs is the captured beat count: `ss` wrote 410,867 `ddrcap_valid` records
  (39 markers) vs 566,660–566,673 (46 markers) for every other case. Saturating the symbol-sync
  loop-filter integrator changes the **symbol output rate itself**, not just the decoded data —
  fewer symbol strobes fit in the same clock budget. This is itself informative: the hardware
  beat leaves the marker cadence and frame timing intact (only the demod-input word jumps to a
  rung), whereas the `ss` kick perturbs the symbol cadence — a further point against `ss` as the
  beat mechanism, beyond the None-vs-rung result below. **reproduced in sim**.
- Transition type: 0 → **None** at frame 13 (word corruption, not a rung landing) — a single-frame
  transition, sustained thereafter (no recovery within the run).
- Frame-log cross-check: `packets_out` bit-error count is 0 through packet 14, first ≥20 at
  packet 15 (err=59, then 59–70 per subsequent packet, not settling to a single constant).
  First-error packet (15) vs first-displacement frame (13): **+2 packets**, not within the ±1
  frame the brief's rule 5 anticipated — see note below.
- **reproduced in sim**.

### `ps` (Peak_Search timing reference forced +32, mod 12333)
- Per-frame offset sequence, frames 8–44:
  `8:0 9:0 10:0 11:0 12:0 13:None 14:None 15:None 16:None 17:None 18:None 19:None 20:None
  21:None 22:None 23:None 24:None 25:None 26:None 27:None 28:None 29:None 30:None 31:None
  32:None 33:None 34:None 35:None 36:None 37:None 38:None 39:None 40:None 41:None 42:None
  43:None 44:None`
- Counts: aligned-at-0 = 13 (frames 0–12), on-rung = 0, intermediate = 0, None = 33
  (frames 13–45).
- Transition type: 0 → **None** at frame 13, sustained (no recovery).
- Frame-log cross-check: bit-error count 0 through packet 15, first ≥20 at packet 16
  (err=48), then **constant 48** at every subsequent packet through 20 — matches the August
  table's "ps gives CONSTANT ~48-68 errs/frame" exactly. First-error packet (16) vs
  first-displacement frame (13): **+3 packets**.
- **reproduced in sim**.

### `ta` (Timing_Adjust timing reference forced +32, mod 12333)
- Per-frame offset sequence, frames 8–44:
  `8:0 9:0 10:0 11:0 12:None 13:None 14:None 15:None 16:None 17:None 18:None 19:None 20:None
  21:None 22:None 23:None 24:None 25:None 26:None 27:None 28:None 29:None 30:None 31:None
  32:None 33:None 34:None 35:None 36:None 37:None 38:None 39:None 40:None 41:None 42:None
  43:None 44:None`
- Counts: aligned-at-0 = 12 (frames 0–11), on-rung = 0, intermediate = 0, None = 34
  (frames 12–45).
- Transition type: 0 → **None** at frame 12, sustained (no recovery).
- Frame-log cross-check: bit-error count 0 through packet 14, first ≥20 at packet 15
  (err=68), then **constant 68** at every subsequent packet through 20 — again matches the
  August table's ps/ta constant-error signature. First-error packet (15) vs first-displacement
  frame (12): **+3 packets**.
- **reproduced in sim**.

### `slip1` (joint Peak_Search + Timing_Adjust reference, +1)
- Per-frame offset sequence, frames 8–44 (all 46 scored, frames 0–45):
  `8:0 9:0 10:0 11:0 12:12319 13:0 14:0 15:0 16:0 17:0 18:0 19:0 20:0 21:0 22:0 23:0 24:0
  25:0 26:0 27:0 28:0 29:0 30:0 31:0 32:0 33:0 34:0 35:0 36:0 37:0 38:0 39:0 40:0 41:0 42:0
  43:0 44:0`
- Counts: aligned-at-0 = 45 (every frame except 12), on-rung = 0, intermediate (0,6176) = 0,
  None = 0. The single non-zero value, 12319, is **not** in the known-rung set
  `{6176,6240,6299,6363,6432,6489,6548}` — it is `12320-1`, i.e. the frame span minus one
  symbol, the direct arithmetic signature of the ±1-symbol joint reference shift that was
  forced.
- Transition type: 0 → 12319 at frame 12, then 12319 → 0 at frame 13 — a **single-frame,
  self-healing excursion**, not a sustained displacement and not a rung landing.
- Frame-log cross-check: bit-error count 0 through packet 14, jumps to 42 at packet 15, then
  drops back to 0 at packet 16 and stays 0 through packet 20 — the error transient exactly
  brackets the one-frame offset excursion. First-error packet (15) vs first-displacement frame
  (12): **+3 packets** (recovery also matches: error clears at packet 16, offset clears at
  frame 13).
- **reproduced in sim**.

**Note on the packet-vs-frame cross-check (rule 5):** across all four forced cases the first
bit-error packet trails the first-displacement frame by a consistent **+2 to +3 packets**, not
the ±1 the brief anticipated. This offset is stable across `ss`/`ps`/`ta`/`slip1` (2, 3, 3, 3
respectively) and both the onset AND the recovery for `slip1` share the same +3 lag, which points
to a fixed FEC/decoder pipeline latency between the ddrcap marker (symbol domain, used for the
offset sequence) and the `packets_out` counter (used for the bit-error log), rather than to any
disagreement between the two measurements about which frame was disturbed. This is reported as
observed, not reinterpreted into a ±1 match.

## Verdict against the pre-registered predictions

**Prediction A (kick = beat mechanism)** requires ≥3 consecutive frames landing on a SINGLE known
rung, with the 0→d transition between two consecutive frames and no frame landing strictly between
0 and 6176. **Not observed in any of the four forced cases.** `on-rung` = 0 in every case; no
frame in any run maps to any of the seven known rungs.

**Prediction B (kick ≠ beat)** requires that frames after the force are `None` for most frames,
OR map to a non-rung offset, OR walk through intermediate offsets. **Confirmed for all four forced
cases:**
- `ss`, `ps`, `ta`: sustained `None` (word not found in the injective map = corrupted symbol
  data) for every frame after the force, through the end of each run (26/38, 33/46, 34/46 frames
  respectively).
- `slip1`: a single non-rung offset (12319, arithmetically `-1` symbol, not a member of the rung
  set) for exactly one frame, immediately self-correcting back to 0 — a transient loop-consistent
  slip, not the sustained single-jump-to-a-rung behaviour of the hardware beat.

**Overall: kick ≠ beat.** None of the four forced-kick mechanisms (symbol-sync integrator
saturation, Peak_Search +32, Timing_Adjust +32, joint ±1 reference slip) reproduces the
hardware's displacement signature (single-frame jump to a fixed known rung, data still bit-exact
at the new offset, marker unmoved, sustained for ≥3 frames). The forced kicks in this netlist
either corrupt the decoded word outright (`ss`/`ps`/`ta`, consistent with B's "None for most
frames" clause) or produce a transient, self-healing, non-rung symbol-domain slip (`slip1`,
consistent with B's "non-rung offset" clause). Predictions A and B are mutually exclusive as
written, and the observed behaviour is prediction B, unambiguously, in all four cases.
**reproduced in sim**.

## Comparator sentence

`ps` and `ta` do reproduce the August table's signature of a CONSTANT ~48–68 errors/frame after
the force (ps settles to a constant 48, ta to a constant 68), but per-frame scoring shows those
frames are **not** rung displacements — they score `None` (word not present in the injective tap3
map, i.e. genuinely corrupted decoded symbols) — so the constant-error pattern discriminates
toward "frame reference shift into decode corruption," not "kick into the timing loop that
reproduces the beat's rung structure." **reproduced in sim**.

## Status contract

Status: **DONE_WITH_CONCERNS** (rule-5 packet/frame lag not resolved to ±1; see concern below —
does not touch the A-vs-B verdict)

One-line verdict: none of the four forced-kick mechanisms (ss/ps/ta/slip1) reproduces the
hardware beat's single-frame jump-to-a-known-rung; ss/ps/ta corrupt the decoded word outright and
slip1 produces only a transient, self-healing, non-rung ±1-symbol excursion — kick ≠ beat,
confirming Prediction B in all four cases.

Positive-control result: PASS — the unforced `none` run maps all 46 scored frames (0–45) to
offset 0 with the tap3 map.

Concerns: (1) the packet-vs-frame cross-check (rule 5) shows a consistent +2 to +3 packet lag
rather than the anticipated ±1, attributable to a fixed FEC/decoder pipeline latency between the
ddrcap marker and the `packets_out` counter (same lag on both onset and, for `slip1`, recovery) —
noted, not reinterpreted. (2) `ss` captured 410,867 beats / 39 markers vs ~566,660 beats / 46
markers for the other four runs under the identical clock budget — saturating the symbol-sync
loop-filter integrator changes the symbol strobe rate itself, not just the decoded word; this
strengthens rather than weakens the kick≠beat verdict but means the `ss` run's frame coverage
(0–38) is shorter than the other cases (0–45).

Report path: `/mnt/onetb/scratch/qpsk-jupiter-modem/.superpowers/sdd/2026-09-01-beat-tap-compare/kick-report.md`
