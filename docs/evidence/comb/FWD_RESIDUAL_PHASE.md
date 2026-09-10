> Evidence ledger, moved verbatim from `two_jup/comb/FWD_RESIDUAL_PHASE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# The forward residual's displacement phase, re-measured on three captures

**RXFIX Task 28. Desk task — NO BOARD CONTACT of any kind.** Every number below
comes from files already on disk under `two_jup/comb/runs/*/`; the commands and
the parsing rules are quoted where they are used. Nothing here was measured on
silicon by this task.

Companion report: `two_jup/sdd_archive/2026-09-04-rxfix/task-28-report.md`.
Predecessors: `FWD_RESIDUAL_0p22.md` (Task 23, the class),
`RXFIX_HOSTFIX_PREREG.md` (Task 26, the pre-registration),
`task-27-report.md` (the silicon judge that fired F5).

---

## 0. Headline

**The 568-byte phase is real and reproduces. The hard-coded counter that looked
for it is what was wrong.**

Task 27 read `resync_568 = 0, resync_other = 171` on the fix-ON leg and
concluded "the pre-registered *mechanism* is wrong … the 568-byte phase is not
the displacement on this leg". Re-measured on the banked captures:

| capture | daemon | dominant `magic_off` | share of magic-carrying class-1 |
|---|---|---|---|
| `20260904_201814_w1_air` (Task 13, T23's source) | pre-fix | **568** | 1,259 / 1,305 = **96.5 %** |
| `20260905_091549_w1_hostfix_off2` (T27 leg B, control) | fixed, `QPSK_RX_RESYNC=0` | **568** | 1,062 / 1,127 = **94.2 %** |
| `20260905_084623_w1_hostfix_on` (T27 leg A, judged) | fixed, re-anchor ON | **952** | 179 / 188 = **95.2 %** |

The two populations are **disjoint**: leg A carries zero records at 568, and
T13 and leg B carry zero at 952. Each leg's mode is **stationary** — the same
value dominates all seven ~100 s sub-windows of the live window (§1.2).

So the phase is a **per-leg constant, not a universal one**. `resync_568 = 0`
on leg A is not evidence about 568; it is evidence that leg A's phase was 952.
The class description of `FWD_RESIDUAL_0p22.md` — *a byte-alignment cascade in
the receive delivery path, seeded by one decode error, holding a fixed
sub-frame phase until the next DMA transfer re-anchors* — **survives intact**.
What does not survive is `QPSK_RESYNC_OFF_568`, a counter split on one leg's
measured value.

Two further corrections to the Task 27 reading, both from the daemon log that
was already banked:

* **`resync_fail = 9,757` is 97.1 % pre-link.** The `rxr_*` counters are
  cumulative from daemon start and — alone among the instruments — are **not**
  rotated by SIGUSR2. 9,478 of the 9,757 failed scans happened before the link
  delivered its first frame. In the measurement window the scan succeeded
  **169 times against 279 failures — a 37.7 % hit rate**, not 1.7 % (§2.1).
* **Pre-registered P12 is not moot; it resolves.** Windowed,
  `resync_fail : re-anchors = 279 : 169 = 1.65 : 1`, which is the "≈ 2:1"
  branch — **the burst-head model is confirmed**: one or two frames per event
  are destroyed at or upstream of the decoder pins, their scans correctly find
  nothing, and the third slice re-anchors (§2.4).

And one new structural fact:

* **Every dominant displacement measured in this campaign is a whole multiple
  of 192 bytes.** 568 → deletion 960 B = 5 × 192; 952 → 576 B = 3 × 192;
  376 → 1,152 B = 6 × 192; 1,144 → 384 B = 2 × 192. In words: 71, 119, 47, 143,
  all ≡ 23 (mod 24). The legs do not "disagree" — they are the same quantised
  defect with a different multiplier (§1.3).

---

## 1. Q1 — the phase census, and what the banked records cannot tell us

### 1.1 What is and is not recoverable from the banked artifacts

Asked first, because it bounds every answer below.

`README_hostlog.md` §3.3: a `failhdr.bin` record is 32 B —
`t_mono_ns`, `host_seq` (raw, garbage on a magic-bad frame), `first_zero_off`,
`fail_class`, `pad`, **`magic_off` = the offset of the FIRST `0x51 0x4B` in the
slice**, and `hdr[12]`, the first twelve raw bytes. `frames.bin` is 48 B of
per-frame telemetry with **no payload at all**. `pair.iq` is RF IQ, not host
bytes.

| question | recoverable from the bank? |
|---|---|
| the first magic in a failed slice | **yes** — `magic_off` |
| its first 12 raw bytes | **yes** — `hdr[12]` |
| the zero-tail onset, the class, the time | **yes** |
| **any second or later magic in the same slice** | **NO** |
| the slice payload, byte-exact content | **NO** |
| the offset the daemon actually re-anchored to | **NO** — only the 568/other split |

**This is the instrument gap that made Task 28 necessary and that §3.4 closes.**
The brief's question — "enumerate all magics in each failed slice" — cannot be
answered from banked data on any of the three captures. What §2.3 does instead
is close the inference with the *counters*, which is sound but is inference, not
observation.

One consequence worth stating: the T23 caveat that "position 0's
`magic_off = 0` does not rule out a second magic at 568 in the same slice" still
stands and still cannot be checked offline. It is settled here only indirectly,
by counting (§2.3).

### 1.2 The census

Reader: `two_jup/comb/joinlog.read_failhdr` on `cap/failhdr.bin`; window rule
`comb.common.live_window` (settle 15 s, wedge-guard), the same rule
`accept_analyze.py` uses. All three dumps are **complete and un-wrapped**
(`filesize == 32 + 32 × n_records`, `flags & 0x1 == 0`) — checked, per
`README_hostlog.md` §5.6, before any number was believed:

| | T13 | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|---|
| `n_records` / `total` / wrapped | 5,439 / 5,439 / no | 1,524 / 1,524 / no | 482 / 482 / no |
| live window | 15–715 s | 15–722 s | 15–721 s |
| records in window | 1,738 | 1,524 | 479 |
| `fail_class` | {1: 1543, 3: 195} | {1: 1349, 3: 175} | {1: 274, 3: 203, 4: 2} |
| class-1 carrying a magic | 1,305 (84.6 %) | 1,127 (83.5 %) | 188 (68.6 %) |
| **dominant offset** | **568 × 1,259** | **568 × 1,062** | **952 × 179** |
| next offsets | 376 (25), 1136 (14), 330 (3) | 1136 (48), 1448 (14) | 376 (4), 188 (2), 1144 (1) |
| offsets that are multiples of 8 | 1,298 / 1,305 | 1,124 / 1,127 | 184 / 188 |
| chance floor (`README_hostlog.md` §3.3) | 2.3 % | 2.3 % | 2.3 % |

**Stationarity.** Splitting each live window into seven equal sub-windows, the
mode is the same value in every one:

```
T13     568 in 156/160, 162/172, 172/177, 209/210, 157/170, 207/216, 196/200
leg B   568 in 164/178, 154/171, 178/185,  71/ 76, 200/208, 145/159, 150/150
leg A   952 in  22/ 25,  30/ 32,  28/ 29,  26/ 27,  28/ 29,  19/ 19,  26/ 27
```

Every non-mode record shares its timestamp with the other records of one event
(e.g. all 14 of leg B's `1448` records are one event at t = 40.9 s; all 25 of
T13's `376` records are five events). **A leg has one phase; individual events
occasionally have another.**

### 1.3 The 192-byte lattice

`magic_off` is the slot phase; the byte-count anomaly that produced it is
`Δ = −(magic_off) mod 1528` (`task-26-report.md` §1.3). Converting:

| `magic_off` | words (÷8) | words mod 24 | deletion `1528 − off` | ÷192 | where |
|---|---|---|---|---|---|
| 568 | 71 | 23 | 960 B | **5** | T13 mode, leg B mode |
| 952 | 119 | 23 | 576 B | **3** | leg A mode |
| 376 | 47 | 23 | 1,152 B | **6** | T13 #2, leg A tail |
| 1,144 | 143 | 23 | 384 B | **2** | leg A tail (1 record) |

Four distinct offsets, four exact multiples of 192 B, all with the same word
residue. **Reported exceptions, not smoothed over:**

* **1,136** (T13 ×14, leg B ×48). 142 words, residue 22, `1528 − 1136 = 392`
  which is not a multiple of 192. It *is* `2 × 568 mod 1528` (71 + 71 = 142
  words), i.e. two k = 5 events stacked inside one transfer — which is how
  `task-26-report.md` §1.3 already read it, and it is consistent with 1,136
  appearing only on the two legs whose k is 5.
* **1,448** (leg B ×14, one event at t = 40.9 s). 181 words, residue 13,
  `1528 − 1448 = 80 B`. **Fits nothing.** One event out of 157; recorded as an
  outlier, not explained.
* The handful of non-multiple-of-8 offsets (7 of 1,305 on T13, 3 of 1,127 on
  leg B, 4 of 188 on leg A) are at or below the 2.3 % chance floor and are
  consistent with random `0x51 0x4B` pairs in garbage.

**How surprising is that?** Of the 190 offsets the scan can even reach
(8 … 1520, step 8), exactly **7 are on the lattice** — 184, 376, 568, 760, 952,
1144, 1336 — a prior of **3.68 %**. Three independent strong modes landing on
it is p ≈ 5 × 10⁻⁵.

**And trimmed honestly: the lattice rests on three offsets, not four.** 568 has
2,321 records across two captures, 952 has 179, 376 has 29. **1,144 is a single
record** on a leg where the 2.3 % chance floor predicts ~4 spurious hits in 188
class-1 failures — it is *consistent with* the lattice, it is not evidence for
it. The claim stands on 568 / 952 / 376.

192 B = 24 × 64-bit words = 1,536 bits = 768 QPSK symbols. **What produces that
quantum is a fabric question and is not answered here.** It is offered as the
shape the fabric-side instrument should be built to detect: the campaign has
been looking for "a 960-byte deletion" when the thing to look for is
"k × 192 bytes". The one-grep question for whoever picks up the fabric side is
whether 192 B (or 24 words, or 768 symbols) matches a known depth in the
`Preamble_Detector` realignment path — the candidate deleting stage the
residual-loss localisation already points at. **No mechanism is asserted here.**

### 1.4 The legs were in different states at the decoder pins, too

The obvious follow-up to "the two legs have different phases" is "were they the
same link?" They were not identical, and the difference is visible **upstream of
anything host-side** — `rx_seq_checker`'s own event counter, in the 460 s
common window (§3.1's cut):

| | T13 | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|---|
| φ | 568 | 568 | 952 |
| checker `chk_gap_events` / 460 s | 144 (T23 §5) | **120** | **150** |
| checker lost slots | 309 (0.0540 %) | 267 (0.0466 %) | 208 (0.0363 %) |
| `failhdr` events, full window | 174 (0.249 s⁻¹) | 157 (0.222 s⁻¹) | 187 (0.265 s⁻¹) |

**A 25 % spread in the event rate at the pins across three captures of the same
rig.** The checker is in the fabric, so the host-side fix cannot have moved it
(that is Task 27's P7, which held) — the legs genuinely differ upstream.

**What this does and does not support.** It supports "a per-leg phase is
physical, because the legs are in measurably different states"; it makes k a
property of a link episode rather than a mystery. It does **not** support "the
event rate tracks k": T13 (φ = 568) sits at 144 and leg A (φ = 952) at 150,
while leg B (φ = 568) is the outlier at 120. Whatever varies between legs is
not read off the event rate.

---

## 2. Q2 — what the 171 re-anchors did, and why 9,757 scans failed

### 2.1 The failed scans are 97 % pre-link — a counter-window artifact

`cap/qpsk_tun.log` prints the `rxresync:` line on every `-s` interval: **161
samples on leg A**. That series was not read by Task 27, and it is decisive.

| log sample | `dma_rx_ok` | `crc_drop` | `resync_568` | `resync_other` | `resync_fail` | `recovered` | `tail_lost` |
|---|---|---|---|---|---|---|---|
| 0 | 0 | 6,224 | 0 | 0 | 5,835 | 0 | 0 |
| 3 | 1 | 10,110 | 0 | 2 | **9,478** | 6 | 2 |
| 5 (last before delivery) | 2 | 10,110 | 0 | 2 | **9,478** | 6 | 2 |
| 6 (delivery starts) | 5,440 | 10,110 | 0 | 2 | 9,478 | 6 | 2 |
| 153 (last live) | 920,264 | 10,592 | 0 | **171** | **9,757** | 1,237 | 165 |

**In-window deltas (sample 5 → 153): `resync_fail +279`, `resync_other +169`,
`recovered +1,231`, `tail_lost +163`, `crc_drop +482`.**

So **9,478 of 9,757 (97.1 %) of the failed scans ran during link acquisition**,
when the drain was reading unlocked garbage out of the carve and no scan could
possibly succeed. The counters are cumulative from daemon start and, unlike
`frames.bin` / `failhdr.bin` / `txlog.bin`, are **not** reset by the SIGUSR2
rotate `capture_r3.sh:218` sends at the window start. Task 27's concern #2 —
"98 % of scans find nothing … the scan is mostly missing" — is an artifact of
reading a cumulative counter against a windowed one.

**In the measurement window the scan succeeds 169 times in 448 attempts =
37.7 %.**

Two arithmetic checks that the acquisition segment is exactly what it looks
like:

* Acquisition `crc_drop` 10,110 against 9,478 scans: difference **632**, and
  `10,110 / 16 = 631.9`. The last slice of every 16-slice transfer is not
  scanned at all — `rx_resync_try` returns before counting when
  `span = limit − off = 1,528 < pkt_bytes + 8 = 1,536`. **Exactly 1 slice in 16,
  confirmed to the unit.**
* In-window the same rule predicts `482 / 16 = 30.1` unscanned slices; the
  record residual is `479 − 169 − 279 = 31`. (The ±3 is the two windows: 482 is
  a delta between log samples, 479 is `failhdr` records inside
  `[15 s, live_end)`. No attempt is made to reconcile them.)

**The control leg is unaffected and stays a clean control**: leg B's line reads
`on=0 phase=0 resync_568=0 resync_other=0 resync_fail=0 recovered=0
tail_lost=0` for the whole capture, exactly as `RXFIX_HOSTFIX_PREREG.md` §4
requires.

### 2.2 The event shapes

Grouping in-window `failhdr` records into events at an inter-record gap > 50 ms
(the frame period is 0.8 ms; events are seconds apart), by position in the
event, `class@magic_off` (`-` = no magic anywhere):

| | T13 (no fix) | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|---|
| events / records | 174 / 1,738 | 157 / 1,524 | **187 / 479** |
| records per event | 9.99 | 9.71 | **2.56** |
| pos 0 | `3@0` ×174 | `3@0` ×157 | `3@0` ×185, `4@-` ×2 |
| pos 1 | `1@-` ×168 | `1@-` ×153 | **`1@952` ×98**, `1@-` ×76 |
| pos 2 | `1@568` ×110, `1@-` ×42 | `1@568` ×102, `1@-` ×40 | `1@952` ×65, `3@0` ×8 |
| pos ≥ 3 | `1@568` ×1,149 | `1@568` ×960 | `1@952` ×16 |
| top signature | `3@0,1@-,1@568,1@568` ×100 | `3@0,1@-,1@568,1@568` ×96 | **`3@0,1@952` ×89** |
| 2nd signature | `3@0,1@-,1@-,1@568` ×34 | `3@0,1@-,1@-,1@568` ×33 | `3@0,1@-,1@952` ×58 |

Leg B reproduces T13 record-for-record in shape. Leg A is the same skeleton
with the cascade truncated by the re-anchor — and with 952 wherever the other
two carry 568.

**The obvious objection, answered from data.** "Leg A only shows event *heads*,
leg B shows whole cascades, so the two are not comparable." They are: on leg B
the **head** record of the cascade — pos 2, the first record that carries a
magic at all — is already 568 in 102 of 143, and on T13 110 of 158. The
comparison is head-to-head, and the values differ.

### 2.3 The offsets the 171 re-anchors used: **952 B**, established by counting

The daemon records only the 568/other split, so the offset is inferred. The
inference is closed, not assumed:

1. **The 952 records are the re-anchor sites.** 179 in-window records carry
   `magic_off = 952`, in 164 of the 187 events; the position of the first such
   record inside its event is 1 (×98), 2 (×65), 3 (×1) — **never 0**. Successes
   in the same window: 169. `169 / 179 = 94.4 %` of 952-bearing slices
   converted, and the ~10 that did not are the last-slot cases §2.1 counted.
2. **Exactly one scan succeeds per event.** Two per event would be
   `2 × 187 = 374` re-anchors against the 169 counted. Refuted by the counter.
3. **Therefore the successful scan runs from an *aligned* slice** (`rx_dphase`
   is 0 until a re-anchor moves it, and it is reset in `rx_q_on_complete` and
   `rx_arm_queued`), so the offset it finds is the slice's own first magic:
   **d = 952**.
4. **Corroboration that does not depend on the signature bookkeeping:**
   `tail_lost / re-anchors = 163 / 169 = 0.96`. A re-anchor that lands on the
   true phase runs cleanly to the end of its transfer and burns exactly one
   straddling frame; two re-anchors per event would give ≈ 0.5.
5. **The last surviving alternative — one success per event but at *position
   0*, at some d₀ ≠ φ, with the 952-records being the misaligned reads that
   follow — is refuted by the record count.** A re-anchor to the wrong phase
   leaves the cursor misaligned for the **rest of the transfer**, so every
   remaining slice of that transfer fails and is recorded: the event would
   produce 8–16 records, not the 2 and 3 actually observed
   (`3@0,1@952` ×89, `3@0,1@-,1@952` ×58; leg A's whole event-length
   histogram is `{1:7, 2:101, 3:59, 4:13, 5:2, 6:4, 7:1}`, with **nothing above
   7**). A wrong-phase re-anchor is exactly the leg-B cascade shape, and leg A
   does not have it.

So `resync_other = 171` is **171 re-anchors at 952 bytes**, and
`resync_568 = 0` carries no information about 568 beyond "not on this leg".

### 2.4 Why 279 in-window scans failed — decomposed, hypothesis by hypothesis

| hypothesis | verdict | the number |
|---|---|---|
| **scan bound too small** | **NO — not binding** | `max_shift = pkt_bytes − 8 = 1,520` covers every offset observed on any leg: 376, 568, 952, 1,136, 1,144, 1,448. Not one measured phase is outside it. |
| **two-slot split not covered** | **NO — covered by construction** | the window is `min(limit − off, 2 × 1528) = 3,056 B`; a frame at 952 ends at 2,480, one at 568 ends at 2,096. `test_rxresync` 1b is the falsifier and it passes. |
| **transfer tail not scanned** | **yes, but tiny and known** | exactly 1 slice in 16 (`span 1,528 < 1,536`) — 632 of the acquisition's 10,110, ~31 of the window's 479. Counted as neither fail nor success. |
| **corrupt content** | **YES — this is the whole of the 279** | see below |

Per event, the first record is `class 3 @ 0`: an *aligned* frame whose header
parses and whose CRC fails — the frame the byte anomaly cut. Its scan window
contains the next frame, which the event also destroyed, so the scan correctly
finds nothing. In 58 of 187 events a second frame is destroyed too and the
second scan also fails. That gives `1 fail + 1 success` (89 events) or
`2 fails + 1 success` (58 events), i.e.

```
resync_fail : re-anchors = 279 : 169 = 1.65 : 1
```

**This is `RXFIX_HOSTFIX_PREREG.md` P12's "≈ 2:1" branch, and it confirms the
burst-head model** (`task-26-report.md` §1.5): the re-anchor fires at burst
position 2, after failed scans on the one or two frames that were already
destroyed at or upstream of the decoder pins. Task 27 scored P12 "moot"; it is
not moot, it resolves, and it resolves the way the model predicted.

Cross-instrument confirmation, on the 46 whole `chk.jsonl` intervals lying
inside leg A's live window (460.0 s, T23's Q3 method):

* checker `chk_crc_fail = 143`; host `failhdr` class-3 records in the same
  window = **141**. A one-for-one match, and the tightest cross-instrument
  agreement this campaign has produced.
* checker `chk_garbage = 56`; host class-1 records with **no magic anywhere**
  ≈ 60 in that window. Also one-for-one.

The failed scans are not the scan missing. They are the frames the fabric
destroyed, correctly declined.

---

## 3. Q3 — what to change, what it is worth, and what to log

### 3.1 The loss budget after the fix, from leg A's own instruments

Full live window (706 s), PER 0.079 % = **692 lost slots**, 187 `failhdr`
events:

| | slots | per event | share |
|---|---|---|---|
| `failhdr` records — slices delivered and unparseable | 479 | 2.56 | 69.2 % |
| `tail_lost` — the frame straddling the DMA transfer boundary | 163 | 0.87 | 23.6 % |
| no host record and not a straddler | **50 ± 10** | 0.27 | 7.2 % |
| **total** | **692** | **3.70** | |

The residual row carries a real uncertainty and is not an exact count: the
three terms come from three different windows — 692 from `accept_analyze`'s
live window, 479 from `failhdr` records inside `[15 s, live_end)`, 163 from a
delta between log samples. **±10 is the scale of that mismatch** (the same
mismatch that puts §2.1's unscanned-slice residual at 31 against a predicted
30.1). No attempt is made to reconcile the three windows.

**Class-4 on leg A, checked because T23 made its absence load-bearing.** Leg A
carries **2** class-4 records where T13 and leg B carry zero, and
`README_hostlog.md` §2 says a class-4 count of zero is a real null against a
frame-losing ALIGNLOSS. Both records read `first_zero_off == 0` with an
all-zero 12-byte header — i.e. an **all-zero carve slice, a delivery hole**
(`rx_pump_queued` zeroes the carve before each arm), which is the split
`README_hostlog.md` §2 requires before attributing anything. They are the
single `rx_q_resets = 1` both legs recorded, **not** ALIGNLOSS and not a
fix-induced artifact. T23's class-4 null is undisturbed.

Checker cut, 46 whole intervals (T23's Q3 method), **recomputed on each leg's
own `chk.jsonl` rather than carried over from T23**:

| | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|
| common window | 461.0 s | 460.0 s |
| checker lost slots | 267 (**0.0466 %**) | 208 (**0.0363 %**) |
| checker gap events | 120 | 150 |
| host lost slots | 1,055 (**0.1838 %**) | 474 (**0.0827 %**) |
| **host / pins lost-slot ratio** | **3.95×** | **2.28×** |
| host loss runs | 116 | 259 |
| `failhdr` events | 93 | 127 |

Leg B reproduces T23's 3.97× to two figures on an independent capture. The fix
takes the host-side multiplication from 3.95× down to 2.28×.

### 3.2 Ranked scan changes, with the number attached

1. **A larger `max_shift`, or a wider window: ~0 slots.** The bound is not
   binding (§2.4) and the window already covers `φ + pkt_bytes` for every φ
   measured. Stated explicitly so it is not re-litigated.
2. **Re-trying the ~10 unconverted 952-bearing slices: ≤ 10 slots ≤ 0.001 pp.**
   They are the transfer-tail cases, where there is genuinely no whole frame
   left before the DMA-written limit. Negligible.
3. **An offset histogram: 0 slots, and it is the change worth making.** It buys
   no PER; it buys the ability to *name* the phase, which cost this campaign a
   judge leg (§3.4).
4. **Carrying the straddler across the transfer boundary: 163 slots =
   0.0185 pp (0.079 % → ~0.060 %) — the only host-side lever of measurable
   size, and it is probably not available.** `task-26-report.md` §8 flagged
   that it needs the fabric to stream continuously across the transfer gap.
   It does not: `request_sync_transfer_start` (rr.v:161) hard-gates each
   transfer's request on a frame-sync tuser, so the next area *starts on a
   frame boundary* and the straddling frame's remaining bytes are discarded in
   the fabric, not delivered at the head of the next area. **The prediction is
   that a carry-across recovers nothing**; this is registered as a falsifiable
   claim (§4, P11) rather than proposed as a change.

**Honest total: the host-side scan is at its ceiling.** The residual after the
fix is the frames the event destroyed (2.5 per event, matched one-for-one to
the checker's `crc_fail` + `garbage`) plus one straddler per event lost inside
the DMA plane. Neither is scan-recoverable. **Expected gain in frames per event
from any scan change: 0.05, against the 7.36 the fix already recovered
(9.17 → 1.81 slots/event).** Further reduction of the forward residual is a
fabric problem — stop the k × 192 B anomaly — not a host one.

### 3.3 What the next leg should log per re-anchor

The fields that would have settled this task in one grep instead of an
inference chain:

```
t_mono_ns   the same axis as frames.bin / failhdr.bin (join key)
d           THE OFFSET -- the whole point
phase_before the cursor phase before the move (0 => this is the event's first
             re-anchor; non-zero => a second one, which refutes 2.3 step 2)
slot        position within the transfer (tests the uniform-position model)
area, off   provenance
seq, len    which frame was recovered
fails_since failed scans since the previous hit -> P12's ratio, per event
```

### 3.4 The instrument change made (implemented, tested, **NOT deployed**)

`host_app_k5/qpsk_tun.c` + `host_app_k5/test_rxresync.c`. Two defects, both
fixed by **adding** output — the `qpsk_tun rxresync:` line and all five
counters behind it are byte-for-byte unchanged, so every banked capture stays
comparable and any existing parser keeps working.

**(a) An offset histogram** — `rxr_hist[]`, indexed by `d / 8` (191 bins), plus
`off_last`, `off_mode`, `off_mode_n` and the top four bins. This replaces
nothing; `resync_568` / `resync_other` keep counting exactly as they did.

**(b) A SIGUSR2 baseline** — `rxresync_rotate()`, called from
`framelog_service()` beside `instr_rotate_rings()`, snapshots the five counters
so a **window-scoped** view can be printed alongside the cumulative one. It
never clears a cumulative counter. This is what stops the next leg repeating
§2.1's misreading.

New line, emitted after the unchanged one. **This is what it WOULD have printed
on leg A** (the numbers are §2.1's in-window deltas and §2.3's inferred offset,
not an observed output — nothing was run on a board):

```
qpsk_tun rxresync2: win_568=0 win_other=169 win_fail=279 win_recovered=1231 \
                    win_tail=163 off_last=952 off_mode=952 off_mode_n=169 \
                    top=952:169,376:1
```

**(c) `QPSK_RX_RESYNC_LOG=1`, default OFF** — one stderr line per *successful*
re-anchor with the §3.3 fields. Unset, `rxr_log` is 0 and the drain path is
byte-for-byte what it was; set, it costs one `fprintf` at ~0.24 Hz. (Failed
scans print nothing, so even an unlocked-link acquisition phase is silent.)

Tests: `test_rxresync` goes **40 → 66 checks, 0 failures**, including check 3b,
which plants leg A's own geometry — a 576 B deletion giving a 952 B phase — and
asserts that the deployed drain re-anchors identically there (15 delivered, 1
lost), that it counts as `resync_other`, and that the histogram names 952.
`make test` is green end-to-end: `test_frame` 578, `test_k5` 89, `test_ber`,
`test_whiten`, `test_seq`, `test_txq` 25, `test_txlog` 25, `test_rxresync` 66 —
0 failures. Also builds `-Wall -Wextra -Werror` clean with the full deployed
flag set.

**Deploy fingerprints** (`README_hostlog.md` §5.1/§5.3): `nakstat` **4**
(the 148 deploy gate — unchanged), `rxqstat` **1** (unchanged). `rxresync` goes
**1 → 3**; no script in the repository greps that string (checked), only prose,
so no gate moves. **Nothing was deployed and no board was contacted.**

---

## 4. Q4 — does the 8.140 s rate line survive?

Method reproduced from `FWD_RESIDUAL_0p22.md` §3: Rayleigh scan over
P ∈ [1, 120] s at 0.02 s, split-half phase coherence, and a family-wise
max-over-band null from 1,000 draws — both a **uniform** null and the
**gap-shuffled** null that preserves the clustering (the null that matters).
T23 used 4,000 draws, so p-values here are resolved to 1/1000, not 1/4000.

**The implementation reproduces T23 exactly on the T13 capture**: cluster onsets
(gap > 3 s) give R = **0.5499** with the best peak at **P = 8.140 s** — T23's
figures to four decimals — and the 213 host loss-run onsets give R = 0.4876 at
8.140 s against T23's 0.4876.

**The confound that must not be ignored:** leg A has 383 host loss runs against
leg B's 188, because the fix *splits* runs (prereg P13, scored by Task 27). Host
loss runs are therefore **not** a like-for-like onset set across the two legs.
The comparable series is the **`failhdr` event onsets** — the physical events,
on 148's own clock, and the independent ring T23 already validated for this test
(it gave R = 0.5287 on T13).

### 4.1 Answer: **yes — same period, same amplitude, on both new captures.**

**Cluster onsets** (host loss runs grouped at gap > 3 s, T23's primary series):

| | T13 | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|---|
| n | 50 | 52 | 53 |
| **best peak in 1–120 s** | **8.140 s** | **8.160 s** | **8.160 s** |
| R at that peak | 0.5499 | 0.5409 | **0.5923** |
| R at 8.140 s exactly | 0.5499 | 0.4931 | 0.5566 |
| split-half \|Δφ\| | 0.055 cyc | 0.123 cyc | 0.102 cyc |
| p (uniform null, family-wise) | < 0.001 | 0.0020 | < 0.001 |
| p (gap-shuffled null) | 0.0010 | 0.0020 | < 0.001 |

8.140 → 8.160 s is **one grid step** of the 0.02 s scan — 86.0 against 85.8
cycles in a ~700 s window, indistinguishable.

**`failhdr` event onsets** — the physical events, on 148's own clock, the
independent series and the one that is like-for-like across the two builds:

| | T13 | leg B (fix OFF) | leg A (fix ON) |
|---|---|---|---|
| n / rate | 174 / 0.2486 s⁻¹ | 157 / 0.2221 s⁻¹ | 187 / 0.2649 s⁻¹ |
| **R at 8.140 s** | **0.4892** | **0.4943** | **0.4960** |
| split-half \|Δφ\| | 0.048 cyc | 0.061 cyc | 0.087 cyc |
| p (uniform, fw) | < 0.001 | < 0.001 | < 0.001 |
| p (gap-shuffled) | 0.0250 | 0.0210 | 0.0060 |

**The amplitude is flat to 1.5 % across all three captures** (0.489 / 0.494 /
0.496), and the split-half phase is coherent everywhere. The event *rate* is
also unchanged (0.249 / 0.222 / 0.265 s⁻¹).

**Host loss-run onsets** are reported for completeness with the confound named:
n = 213 / 188 / **383**, because the fix splits runs. R at 8.140 s = 0.4876 /
0.4697 / 0.4716, p (gap-shuffled) 0.0010 / 0.0020 / 0.0030 — the line is there
in all three, but leg A's 383 is not a like-for-like onset count and no
amplitude comparison should be drawn from that row.

### 4.2 What it means

The 8.140 s rate modulation is a property of the **event** process, not of the
host's accounting of it: it is present at the same period and the same
amplitude on a capture with the fix off and a capture with the fix on, from the
same binary on an unchanged fabric, and it is equally present in the
independent `failhdr` ring. That is exactly what a host-side change downstream
of the decoder pins must do — **it is a control that passed**, and it is
consistent with Task 27's P7/P9 (the fabric witnesses did not move).

**Still unexplained, and untouched by this task.** Nothing here says what the
8.140 s line *is*. It is worth noting that it is now a three-capture
observation rather than a one-capture one.

**The 106.8 s peak reproduces for the third and fourth time** and is still not
claimed: it is the largest thing in the `failhdr` and host-loss-run scans on
every capture (106.68 / 106.98 / 106.70 s), but at ~6.6 cycles in a ~700 s
window it stays below T23's ≥ 20-cycle interpretability bar, and a slow drift in
a fixed-length window peaks near W/6.5 by construction. One capture of ≥ 40 min
would settle it, and if it is real it is a *bigger* signal than the 8.14 s line.

---

## 5. Pre-registered predictions for the next judge leg

Registered here, before any leg runs, on a daemon carrying §3.4's instrument
(`QPSK_RX_RESYNC_LOG=1`, `QPSK_RXQ_ZEROHDR` off, forward leg 146 → 148, 600 s).
The fix itself is unchanged, so this is a *phase* measurement, not a re-judge.

| # | prediction |
|---|---|
| P1 | `off_mode` is a **single value**, ≥ 90 % of `win_568 + win_other` in one histogram bin |
| P2 | `off_mode` is **on the 192-byte lattice**: `(1528 − off_mode) mod 192 == 0`, equivalently `off_mode / 8 ≡ 23 (mod 24)`. Only **7 of the 190 reachable offsets** qualify (184, 376, 568, 760, 952, 1144, 1336) — **a 3.68 % prior**, so this is a real bet, not a description |
| P3 | `off_mode` is **not predicted to be 568 or 952**. Any lattice value passes. This is the whole point: the value is a per-leg constant and the prediction is about its *form* |
| P4 | `off_mode` is **stationary** — the same mode in each quarter of the window |
| P5 | `win_fail : (win_568 + win_other)` in **1.2 – 2.2** (leg A: 1.65) |
| P6 | `win_tail : (win_568 + win_other)` in **0.85 – 1.15** (leg A: 0.96) |
| P7 | `phase_before == 0` in ≥ 90 % of per-hit log lines (one re-anchor per event, from an aligned cursor) |
| P8 | `fails_since` ∈ {1, 2} in ≥ 85 % of per-hit lines |
| P9 | `win_fail` ≤ `resync_fail / 10` if the leg includes an acquisition phase (§2.1) |
| P10 | forward PER **0.06 – 0.10 %**; host/pins lost-slot ratio **2.0 – 2.6** |
| P11 | `tail_lost / event` stays at **0.85 – 1.15** — the straddler is lost in the fabric at the tuser-gated transfer boundary and no host change can move it (§3.2 item 4) |
| **P12** | **THE DISCRIMINATOR.** On a leg with a **deliberate re-lock at mid-window** (a `bringup_r2r3.sh r3` restore, or any forced re-acquisition, at t ≈ 350 s of a 700 s window): `off_mode` computed on `[15, 350)` and on `[350, end)` separately gives **two different lattice values**, each ≥ 90 % pure inside its own half. That is "k is latched at link acquisition". A single value across the boundary says k is a property of the *rig*, and 952 was an excursion; two values *within* a half says k drifts and F2 fires |

**Falsifiers.**

* **F1 — `off_mode` off the lattice** (`(1528 − off_mode) mod 192 != 0`). The
  192 B quantisation is wrong; §1.3 is coincidence across four offsets and must
  be withdrawn.
* **F2 — two distinct modes each > 20 % of the re-anchors, or a mode that
  changes between the halves of the window.** The phase is not a per-leg
  constant; the "one multiplier per lock episode" reading is wrong and the
  fabric anomaly is varying within a leg.
* **F3 — `phase_before != 0` in > 25 % of hits.** More than one re-anchor per
  event; §2.3 step 2's counting argument is wrong and the offsets inferred for
  leg A must be withdrawn.
* **F4 — `win_fail : re-anchors` < 0.5.** The head frames are *not* destroyed;
  a pure byte deletion applies and the re-anchor should have fired at burst
  position 0. That would refute the burst-head model §2.4 confirms, and would
  mean the 0.076 % floor in `RXFIX_HOSTFIX_PREREG.md` §2 is too high.
* **F5 — `off_mode` equals 568 on a leg whose `resync_568` is 0, or vice
  versa.** The instrument is miscounting; do not read anything else from the
  leg.

**Why P12 is the one that matters.** P1–P4 pass on *any* lattice value, so a
leg that returns 568 again adds a fourth data point and discriminates nothing.
P12 is the only registered item that separates the three live readings —
*k latched at acquisition* / *k a rig property with 952 an excursion* / *k
drifts* — and it costs one extra `bringup_r2r3.sh r3` inside an otherwise
ordinary leg. §1.4 is the reason to expect it to bite: the legs are already
measurably different at the decoder pins.

---

## 6. Concerns

1. **The leg-A offsets are inferred, not observed.** §2.3 closes the inference
   with three independent counts (169 vs 179 candidates; 2-per-event refuted by
   169 < 374; `tail_lost / success = 0.96`), but the daemon never recorded the
   offset and the banked `failhdr` cannot show a second magic in a slice
   (§1.1). Until a leg runs with §3.4's histogram, "952" is a strong inference,
   not a measurement. **It should not be hard-coded anywhere** — that is the
   mistake this task exists to correct.
2. **N = 1 per phase value.** 568 appears on two captures, 952 on one. Whether k
   is latched at lock, drifts slowly, or is drawn per event is untested; §5's
   re-lock experiment is the cheap test.
3. **1,448 fits no model** (leg B, one event, 14 records). Left as an outlier.
4. **The 106.8 s peak is still the largest thing in the periodicity scan and is
   still not claimed** — 6.6 cycles in a ~700 s window, below T23's ≥ 20-cycle
   bar, and it reproduces at ~106–107 s on every capture, which is what a slow
   drift in a fixed-length window does.
5. **The `rxr_*` counters were never rotated, and every previously banked
   capture has the same defect.** Any earlier `resync_*` number quoted from a
   leg that included an acquisition phase is contaminated the same way. Only
   leg A has the counters at all, so the blast radius is one leg — but the
   `rxqstat` / `nakstat` / `txgap` lines share the design (cumulative, not
   rotated) and should be read with the same care.
6. **`chk.jsonl`'s `ts_mono` is the reader host's clock** (T23 concern #4,
   still unfixed in `README_hostlog.md`). Every cross-instrument cut here is on
   wall time for that reason.
