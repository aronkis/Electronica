# Demod-marker vs TX-marker inter-gap test: MARKER-moves vs DATA-moves

Captures: `two_jup/pair/20260901_155752/sel3.bin`, `.../sel5.bin` (512 MB each,
67,108,864 rows, 4x int16 LE: I, Q, demod_marker, tx_marker). Marker fires where
column == 0x7FFF (32767). Load: `a=np.fromfile(path,dtype='<i2'); a=a[:len(a)//4*4].reshape(-1,4)`.

Analysis script logic: find all row indices where col2==32767 (demod fires) and
col3==32767 (tx fires); take `np.diff()` of each index array to get inter-fire
gaps; classify each gap as modal (==12333) or non-modal (!=12333); for each
non-modal demod gap, find the nearest tx gap (by `searchsorted` on tx fire row
index against the demod gap's start row) and record its value; check for
adjacent non-modal-demod pairs (within 3 fire-indices of each other) whose
gaps sum to ≈2×12333 (the jump-then-return signature).

## IMPORTANT premise mismatch

The task's pre-registered setup states §72 found sel3 has **6** non-modal
demod-marker gaps (5,430 of 5,436 gaps modal). Direct measurement on this file
finds **105** non-modal demod gaps (5,334 of 5,439 gaps modal) in sel3, and
**71** non-modal demod gaps (5,360 of 5,431) in sel5. This is not a rounding
difference — it is ~17x more anomalies than expected. Possible explanations
(not investigated further, out of scope for this read-only test): §72's "6"
referred to a different derived metric (e.g. decoded-frame-level anomalies
after some correction/filtering), a different tolerance window, or a
different/older capture. Whatever the cause, the raw marker-fire cadence in
this specific pair of files is NOT the clean "6 anomalies in ~5436" picture
the hypothesis was framed against. The measurement below is reported as-is
against the raw data actually on disk.

## sel3 (67,108,864 rows)

- demod-marker (col2) fires: 5,440. Gaps: 5,439. Modal gap = 12,333 rows,
  count at modal = 5,334 (98.07%). Non-modal demod gaps: **105**.
- tx-marker (col3) fires: 5,443. Gaps: 5,442. Modal gap = 12,333, count at
  modal = 5,342 (98.16%). Non-modal tx gaps: 100.
- Non-modal demod-gap deviation stats (dev = gap − 12333):
  min −7,596, max +12,333 (a "+12,333" deviation = a gap of 24,666 = exactly
  2×12,333, i.e. a single missed/undetected marker fire, not a jump-return —
  5 such cases in sel3).
  Median dev −983, mean +187.
  Distribution of |dev|: <500: 1; 500–2000: 74; 2000–5900: 11;
  near-rung (5900–6800, covers the 6160–6548 rung set): **4 of 105**;
  >6800 (excluding the 5 doubled/missed-marker cases): 10.
- **No jump-and-return pairs found.** Checked every pair of non-modal demod
  gaps occurring within 3 fires of each other for `gap1+gap2 ≈ 2×12333`
  (±200): **0 of 105** anomalies pair this way.
- Cross-tab: at the row where each demod gap is anomalous, the nearest tx gap
  is exactly modal (12,333) in **103 of 105 (98.1%)** cases — i.e. the TX
  reference cadence stays clean through almost every demod anomaly.

First 15 non-modal demod gaps (fire index, row range, gap, deviation, nearest tx gap/deviation):
```
 fire_i=58   row 715358-727080    gap=11722 (dev -611)   | tx gap=12333 (dev +0)
 fire_i=94   row 1158735-1169261  gap=10526 (dev -1807)  | tx gap=12333 (dev +0)
 fire_i=142  row 1748912-1758829  gap=9917  (dev -2416)  | tx gap=12333 (dev +0)
 fire_i=225  row 2770135-2792478  gap=22343 (dev +10010) | tx gap=12333 (dev +0)
 fire_i=308  row 3803784-3814541  gap=10757 (dev -1576)  | tx gap=12333 (dev +0)
 fire_i=392  row 4838180-4850360  gap=12180 (dev -153)   | tx gap=12333 (dev +0)
 fire_i=428  row 5282015-5292647  gap=10632 (dev -1701)  | tx gap=12333 (dev +0)
 fire_i=455  row 5613305-5630478  gap=17173 (dev +4840)  | tx gap=12333 (dev +0)
 fire_i=476  row 5877138-5888620  gap=11482 (dev -851)   | tx gap=12333 (dev +0)
 fire_i=493  row 6085948-6110614  gap=24666 (dev +12333, missed marker) | tx gap=12333 (dev +0)
 fire_i=544  row 6727264-6738402  gap=11138 (dev -1195)  | tx gap=12333 (dev +0)
 fire_i=653  row 8070366-8080522  gap=10156 (dev -2177)  | tx gap=12333 (dev +0)
 fire_i=658  row 8129854-8138013  gap=8159  (dev -4174)  | tx gap=11393 (dev -940)
 fire_i=659  row 8138013-8149406  gap=11393 (dev -940)   | tx gap=12333 (dev +0)
 fire_i=743  row 9173045-9184510  gap=11465 (dev -868)   | tx gap=12333 (dev +0)
```
Anomalies recur roughly every ~30-80 fires throughout the entire 67M-row
file — they are spread uniformly across the whole capture, not confined to a
single ~3 s beat window.

## sel5 (67,108,864 rows)

- demod-marker fires: 5,432. Gaps: 5,431. Modal gap = 12,333, count at
  modal = 5,360 (98.69%). Non-modal demod gaps: **71**.
- tx-marker fires: 5,438. Gaps: 5,437. Modal gap = 12,333, count at
  modal = 5,371 (98.79%). Non-modal tx gaps: 66.
- Non-modal demod-gap deviations: min −6,559, max +12,333 (5 doubled/missed
  cases). Median −902, mean +1,627.
  |dev| distribution: <500: 1; 500–2000: 48; 2000–5900: 8;
  near-rung (5900–6800): **1 of 71**; >6800 (excl. doubled): 8.
- **No jump-and-return pairs found**: 0 of 71 anomalies pair as
  gap1+gap2≈2×12333 within 3 fires of each other.
- Cross-tab: nearest tx gap is exactly modal in **67 of 71 (94.4%)** of
  demod-anomaly locations.

First 15 non-modal demod gaps for sel5:
```
 fire_i=567  row 6997076-7021742   gap=24666 (dev +12333, missed marker) | tx gap=12333
 fire_i=1651 row 20378381-20403047 gap=24666 (dev +12333, missed marker) | tx gap=12333
 fire_i=1744 row 21537683-21552387 gap=14704 (dev +2371)  | tx gap=12333
 fire_i=1796 row 22181370-22192028 gap=10658 (dev -1675)  | tx gap=12333
 fire_i=1820 row 22475687-22486671 gap=10984 (dev -1349)  | tx gap=11595 (dev -738)
 fire_i=1821 row 22486671-22498266 gap=11595 (dev -738)   | tx gap=12333
 fire_i=1831 row 22609263-22622219 gap=12956 (dev +623)   | tx gap=12333
 fire_i=1834 row 22646885-22657225 gap=10340 (dev -1993)  | tx gap=21952 (dev +9619)
 fire_i=1835 row 22657225-22679177 gap=21952 (dev +9619)  | tx gap=12333
 fire_i=1940 row 23961809-23983744 gap=21935 (dev +9602)  | tx gap=12333
 fire_i=1977 row 24427732-24439114 gap=11382 (dev -951)   | tx gap=12333
 fire_i=2060 row 25450420-25461179 gap=10759 (dev -1574)  | tx gap=12333
 fire_i=2144 row 26484818-26496130 gap=11312 (dev -1021)  | tx gap=12333
 fire_i=2228 row 27519769-27531129 gap=11360 (dev -973)   | tx gap=12333
 fire_i=2275 row 28098447-28109014 gap=10567 (dev -1766)  | tx gap=12333
```

## Verdict against the pre-registered predictions

**MARKER-moves (SUPPORTED)** requires: non-modal demod gaps come in
jump-then-return pairs at ≈±rung (near 6160), with tx staying clean.
→ NOT observed. 0/105 (sel3) and 0/71 (sel5) non-modal demod gaps form a
jump-return pair. Only 4/105 and 1/71 individual anomalies even land within
±5 rows of a rung magnitude, and none of those participate in a pairing that
sums back to 2×modal. This part of the prediction is refuted.

**DATA-moves / REFUTED** requires: demod gaps uniformly ≈12333 everywhere,
anomalies tiny/random. → NOT observed either. There are far more anomalies
than the pre-registered "6," and their deviations are not tiny — median
|dev| ≈900-1000 rows, with individual cases up to several thousand rows off
(plus 5 per file that are exactly a missed/undetected marker, dev=+12333).
This is not the "clean cadence with negligible noise" picture either.

**INCONCLUSIVE** is the criterion that matches: anomalies exist (105 in
sel3, 71 in sel5) but are neither ≈±rung/jump-return pairs (0 found in
either file) nor tiny/negligible (median deviation ~900-1000 rows, i.e.
roughly 7-8% of a frame, well above measurement noise) — so per the
pre-registered decision tree this test is:

- **sel3: INCONCLUSIVE** (leaning away from MARKER-moves: 0/105 rung
  jump-return pairs; but also not REFUTED since anomalies are far more
  numerous and larger than the "6 tiny" premise assumed).
- **sel5: INCONCLUSIVE**, same reasoning (0/71 rung jump-return pairs).

One robust finding that IS decisive on its own, independent of the
inconclusive verdict above: **the TX-marker (transmitted reference) cadence
stays clean (exactly modal, 12333) at 98.1% (sel3) / 94.4% (sel5) of the
locations where the DEMOD marker gap is anomalous.** The anomalies are
concentrated in the demod/receiver marker, not the tx reference — consistent
with the receiver's marker-detection/timing-offset latch being the noisy
element, but the specific magnitude signature required to confirm
"half-frame rung latch" (paired ∓half-frame jump-and-return) is absent from
both captures at this coarse-tolerance gap analysis.

Caveat: this test only examined markers-that-fired (col==32767 exactly). It
does not rule out sub-frame timing-offset jitter smaller than one full "rung"
that never triggers a full inter-marker-gap deviation of that size, nor does
it examine the DATA plane at all (out of scope for this test per the
pre-registration). The large premise mismatch (6 expected vs 105/71 observed
non-modal gaps) should be resolved before treating this INCONCLUSIVE result
as the final word — it suggests either the earlier §72 count used a
materially different method, or this capture pair differs from the one §72
analyzed.
