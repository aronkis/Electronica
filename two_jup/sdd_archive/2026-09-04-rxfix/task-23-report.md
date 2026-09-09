# Task 23 — the forward residual 0.224 %: what class is it? (desk, banked data)

Branch `per-under-1pct-2026-07`. Ledger `Task 23:` lines and `HEARTBEAT task23`
in `progress.md`. **No board contact of any kind.** Every number below comes from
files already on disk; the commands are quoted where they are used.

Deliverable: **`two_jup/comb/FWD_RESIDUAL_0p22.md`** — the class, the answers, the
next instrument. This report carries the method, the statistics, the prereg scoring
and the concerns.

---

## 0. Headline

**The class is a byte-alignment cascade in the receive delivery path, triggered by a
single decode error at the decoder pins and rate-modulated at 8.140 s.** One
CRC-failed frame costs the host 8.59 frames instead of 1: the frame immediately after
it is destroyed, and the following ~6–15 frames arrive **displaced by a fixed 568
bytes** inside the host's carve slice until the stream resyncs.

The prereg's label — *delivery/stall* — **fails**, and so does its "no single period".
The five 4-s delivery flatlines and the six ~10 % census dips are both **instrument
artifacts**, and neither is the burst class.

| | number |
|---|---|
| PER, live window (reproduced) | **0.224 %** — `accept_analyze.py` prints `1956/871805` (its denominator is the seq *span*); `common.loss_slot_trains` counts 871,806 slots → 0.2244 %. Same 1,956 losses, 213 loss runs |
| share of the residual in the 5–20 bin | **93.25 %** (1,824 slots, 161 events) |
| loss **events**: host vs fabric checker, common window | **143 vs 144** (r = +0.935) |
| lost **slots** per event: host vs pins | **8.59 vs 2.15** |
| class-1 failures carrying the frame magic at offset **568 B** | **1,259 of 1,543** (chance floor 2.3 %) |
| NEVER_SENT | **0 of 1,956** |
| ZEROTAIL / delivery holes | **0**, with `RXQ_ZEROHDR` confirmed off |
| `reg_rstcs` (carrier/AGC resets) | **0 on all 871,598 in-window records** |
| the periodic component | **8.140 s**, p < 2.5 × 10⁻⁴, coherent across 4 checks |

---

## 1. What was analysed, and three checks made before any number was believed

Primary: `two_jup/comb/runs/20260904_201814_w1_air` (Task 13's air leg; 148 =
W1+R4B `9f13705d9fb0`, 146 = `3378861d30bd`, forward 146→148, capture 721 s, host
live window 15–715 s, one wedge). Baseline: `two_jup/comb/runs/20260904_165420_w1_air`
(Task 10's W1 leg, PER 8.309 %).

**(a) Which `txlog` is the transmitter's.** On a forward leg 146 is the TX, so the
join must use `cap/txlog_peer.bin` — and `comb_census.py`'s own docstring records
that using the wrong one already bit this campaign once. Verified, not assumed:

```
txlog.bin      : |good_rx_seqs|=891027 |txseqs|=5      overlap=0      (0.00 %)
txlog_peer.bin : |good_rx_seqs|=891027 |txseqs|=896501 overlap=889318 (99.81 %)
```

**(b) The zerohdr mode, because it decides what MAGIC *means*.** `README_hostlog.md`
§2: with `QPSK_RXQ_ZEROHDR` on, an unfilled DMA slot lands in class 1 (MAGIC); with it
off, `rx_pump_queued` zeroes the whole carve (`qpsk_tun.c:1461/1466`) and an unfilled
slot lands in class 4 with `first_zero_off == 0`. `cap/qpsk_tun.log` carries
`RX queued-request mode ON` but **no** `RXQ EXPERIMENT: header-only pre-submit zero`
line, so **zerohdr was off**. Therefore ZEROTAIL = 0 is a real null on delivery holes,
and MAGIC here means *garbage content*, not an unfilled slot. The prereg's inference
"MAGIC-dominated → delivery/stall" only ever held in the other mode.

**(c) Dump completeness (`README_hostlog.md` §5.6).** `cap/failhdr.bin` declares
`n_records = 5439` — **the brief's 5,440 is one out** — 174,080 B = 32 + 32 × 5,439,
`wrapped = False`, `total = 5439`, so no events were lost. `cap/failhdr_peer.bin` *is*
wrapped (65,536 of 66,172) and was not used. `frames.bin` = 893,975 × 48 B.

**Clock axes.** `chk.jsonl`'s `ts_mono` starts at 883,116.8 s while `frames.bin`'s
`t_mono_ns` starts at 887.3 s — **not the same clock**; `ts_mono` is the reader host's.
Every cross-instrument cut in this report is on wall time (`t_real_ns` ↔ `ts_wall`);
`t_mono_ns` is used only within `frames.bin` + `failhdr.bin`, which do share 148's clock.

---

## 2. The one tool change: `accept_analyze.py --burst-times`

The brief asked for per-burst timestamps "if it lacks them — a new option, tested".

`analyze(path, settle_s=15.0, burst_times=False)` now optionally returns
`r['bursts']`, one entry per **loss run** (the same runs the run-length bins count)
with `onset_seq`, `run_len`, `t_s`, `t_mono_ns`, `t_real_ns`; the CLI writes them as
a CSV. Design constraints honoured:

* **The default path did not move.** `sweep_report.py` imports `analyze` and the
  campaign compares PER across legs by re-running this tool, so with the flag absent
  every printed number and every returned key is byte-identical
  (`test_no_bursts_key_and_identical_numbers_when_off`,
  `test_cli_without_the_flag_prints_no_burst_line`). The leg re-scores to exactly
  Task 13's `PER=0.224% (1956/871805) CP95UL=0.235% lag33=-0.000 bins={…}`.
* **No new reconstruction and no new windowing.** It reuses the `runs` list
  `analyze()` already builds for the lag-33 train, and interpolates the onset time
  against the clean frames' own `(host_seq, timestamp)` anchors — a lost slot has no
  record of its own. Both clocks are emitted, with the docstring saying `t_real_ns`
  is the only cross-host-comparable one.
* **No new dependency.** `comb/common.py` deliberately duplicates
  `accept_analyze.analyze()`'s window rule verbatim; importing it back from the
  top-level acceptance tool would couple the campaign's headline PER tool to the comb
  package. Instead the two implementations are **pinned to each other by a test**:
  `test_agrees_with_comb_common_interp` asserts the emitted `t_mono_ns` equal
  `common.interp_t_mono_ns()` to the nanosecond on the same data.

`two_jup/tests/test_accept_burst_times.py`, **7 tests, all pass**. Every one plants
bursts at known slots and times in a synthesized `frames.bin` and asserts recovery —
the repo's own rule (`singles_cadence.py`: "a scorer that has never caught a planted
fault is not trusted with a negative result"). Writing it caught a real property that
had to be pinned rather than worked around: a `crc_ok == 0` record occupies its slot
but does not *place* it, so an in-window CRC-failed frame is correctly counted as a
lost slot (`test_in_window_crc_fail_counts_as_a_loss`). `test_comb_tools.py` still
passes 20/20.

---

## 3. Q1 — clustered, periodic, or Poisson?

**Answer: CLUSTERED, with one coherent 8.140 s rate line. Not Poisson. Not a single
strict period.**

```
python3 two_jup/accept_analyze.py --burst-times \
        two_jup/sdd_archive/2026-09-04-rxfix/t23_evidence/r4b_bursts.csv \
        two_jup/comb/runs/20260904_201814_w1_air/cap/frames.bin
```
→ 213 loss runs, 1,956 slots, PER 0.224 %.

| bin | events | rate | slots | share of residual | mean gap |
|---|---|---|---|---|---|
| 1 | 18 | 0.0257 /s | 18 | 0.92 % | 38.9 s |
| 2 | 1 | 0.0014 /s | 2 | 0.10 % | — |
| 3–4 | 33 | 0.0471 /s | 112 | 5.73 % | 21.2 s |
| **5–20** | **161** | **0.2300 /s** | **1,824** | **93.25 %** | **4.35 s** |
| 21–100 / >100 | 0 | | 0 | 0 % | |

Longest run in the entire live window: **17 slots = 13.65 ms**.

**Not Poisson.** Inter-arrival mean 3.209 s, **median 0.730 s**, sd 7.935 s,
**CV = 2.473**; KS vs exponential D = 0.3668, **p = 4.5 × 10⁻²⁶**.

**Clustered.** Fano factor 3.233 / 4.025 / 4.302 in 10 / 20 / 35 s bins; χ² vs
uniform in 10 s bins = 223.1 on 69 dof, **p = 3.9 × 10⁻¹⁸**; 25 of 70 bins empty,
max 11. On the 5–20 subset alone: CV 2.625, KS p = 1.4 × 10⁻¹⁹, Fano 2.953.

Grouping at gap > 3 s gives **50 clusters** of 4.26 events / 39.1 slots. The *cluster
onsets* are uniform in time — χ² = 45.2 on 69 dof, **p = 0.988**, Fano 0.655 — so the
over-dispersion is entirely within-cluster.

**Periodic component: 8.140 s (0.1229 Hz).** Rayleigh scan over 1–120 s at 0.02 s
resolution on the 50 cluster onsets: **R = 0.5499 at P = 8.140 s**, family-wise
p **< 2.5 × 10⁻⁴** against a uniform null (N = 4,000 draws, max-over-band) and
**p = 0.0003** against a **gap-shuffled null that preserves the clustering** — the
null that matters, because clustering alone beats a uniform null. 86 cycles in the
700 s window, so it is well inside the ≥ 20-cycle interpretability bar this task set
before scanning. Four independent confirmations:

| check | result |
|---|---|
| split-half phase coherence, all 213 onsets | R = 0.4876, φ = 0.587, **\|Δφ\| = 0.059 cyc** |
| … 5–20 onsets | R = 0.5333, φ = 0.592, **\|Δφ\| = 0.037 cyc** |
| … 50 cluster onsets | R = 0.5499, φ = 0.442, **\|Δφ\| = 0.066 cyc** |
| … the **independent `failhdr` ring** (n = 1,738, 148's clock) | R = 0.5287, φ = 0.578, **\|Δφ\| = 0.047 cyc** |
| reader-off control (reader ran only t = 8–478 s of 15–715) | reader on: R = 0.480 φ = 0.569, **rate 0.3045 /s**; reader off: R = 0.520 φ = 0.620, **rate 0.3039 /s** |
| present in the W1 baseline's 5–20 class | R = 0.357, coherent (\|Δφ\| = 0.057) |
| absent from W1's singles and 3–4 classes | R = 0.0035 / 0.0149, both incoherent, both below null |

It is a **rate modulation, not a pulse train**: R(P/2) = 0.070, R(P/3) = 0.010 — no
harmonic power, which is what a smooth ~sinusoidal envelope gives and a periodic delta
train does not.

**Reported but not claimed:** the strongest full-band peak is 106.8 s (R 0.54–0.62 in
every subset), reproducing at 106.55 s on the W1 leg. At 6.6 cycles it is below the
≥ 20-cycle bar, and both legs' windows are ~700 s so a slow drift would peak near
W/6.5 in both. **Unresolved low-frequency component, not a measured period.** The
periodicity claim rests on 8.140 s alone.

---

## 4. Q2 — fail class and the NEVER_SENT share

**Answer: MAGIC-dominated (88.8 %), zero delivery holes, NEVER_SENT = 0.00 %.**

```
python3 two_jup/comb/comb_census.py two_jup/comb/runs/20260904_201814_w1_air/cap/frames.bin \
  --failhdr …/cap/failhdr.bin --txlog …/cap/txlog_peer.bin --out t23_evidence/r4b_census.json
```

| | R4B residual | W1 baseline |
|---|---|---|
| records in live window | 871,598 | 872,947 |
| OK | 869,860 | 802,641 |
| **MAGIC** | **1,543 (88.8 % of failures)** | 51,224 (74.0 %) |
| LEN | **0** | 2,143 (3.1 %) |
| CRC | 195 (11.2 %) | 16,939 (24.5 %) |
| **ZEROTAIL** | **0** | 0 |
| onset histogram | **n_have = 0**, n_none = 1,738 | n_have = 0, n_none = 61,469 |
| class-4 `delivery_hole(fzo==0)` | **0** | 0 |
| **NEVER_SENT** | **0 / 1,956 (0.00 %)** | **0 / 72,738 (0.00 %)** |
| SENT_NOT_DECODED | 1,956 (100 %) | 72,738 (100 %) |

`unjoinable_time` = 1,956 (all) — expected and **not interpreted**: the two boards'
`CLOCK_MONOTONIC` are different clocks, exactly as `comb_census.py` warns at runtime.

Consequences, stated with the mode from §1(b):

* **No host TX starvation on 146.** Every one of the 1,956 lost seqs was submitted.
* **No RX delivery holes.** With zerohdr off an unfilled carve slot must read back as
  class 4 / `fzo == 0`. There are none, in either leg.
* **No ALIGNLOSS.** Not one of the 1,738 failed frames had a zero tail of any kind.
* **1,738 of 1,956 lost slots (88.9 %) reached the host as a slice that failed to
  parse; 218 (11.1 %) produced no host record at all.**

### 4.1 The finding the census does not print: `magic_off`

`README_hostlog.md` §3.3 keeps `magic_off` (offset of the first `0x51 0x4B` in the
slice) as informational, with a ~2.3 % chance floor, "worth recording only because a
*large* excess would be a genuinely new observation". This is that excess.

| | R4B residual | W1 baseline (comb) |
|---|---|---|
| class-1 failures in window | 1,543 | 44,805 |
| **carrying the frame magic somewhere** | **1,305 (84.6 %)** | 8,301 (18.5 %) |
| **dominant offset** | **568 B — 1,259 records** | **64 B — 4,816 records** |
| next offsets | 376 (25), **1,136 = 2 × 568** (14) | 952 (1,302), 1,144 (161) |

**1,259 of 1,543 class-1 failures (81.6 %) are a whole frame sitting at exactly byte
568 of the slice.** The frame is not damaged — it is displaced. And the residual's
signature is *not* the comb's (offset 64, and mostly no magic at all).

### 4.2 The internal structure of a burst

Joining `failhdr` records to burst time-windows (1,645 of 1,738 records, 94.6 %, fall
inside one), by position within the run — 159 bursts:

| position | n | fail class | `magic_off = 568` | no magic anywhere |
|---|---|---|---|---|
| **0** | 159 | **157 CRC**, 2 MAGIC | 0.6 % | 1 |
| **1** | 159 | **159 MAGIC** | 1.3 % | **151** |
| 2 | 159 | 159 MAGIC | **72.3 %** | 39 |
| 3 | 159 | 159 MAGIC | **96.2 %** | 0 |
| 4 | 150 | 150 MAGIC | **95.3 %** | 1 |
| 5 | 138 | 138 MAGIC | **96.4 %** | 0 |
| ≥ 6 | 721 | 721 MAGIC | **97.2 %** | 2 |
| outside any burst | 93 | 55 MAGIC / 38 CRC | 11.8 % | 44 |

**One CRC error → one destroyed frame → a fixed 568-byte displacement that holds for
the rest of the run.** Banked verbatim in `t23_evidence/r4b_magicoff.txt`.

---

## 5. Q3 — reconciling 0.053 % at the pins with 0.224 % at the host

**Answer: the events are born at or upstream of the decoder pins, one-for-one;
74.8 % of the lost *frames* are added downstream of them.**

Common window = the 46 `chk.jsonl` intervals lying entirely inside the host live
window: **20:20:44 → 20:28:24, 460.0 s**, both series cut on wall time.

| | fabric checker (decoder pins) | host | ratio |
|---|---|---|---|
| frames / reconstructed slots | 572,520 → **1,244.6 f/s** | 572,901 → **1,245.4 slots/s** | **0.9993** |
| lost slots | **309 → 0.0540 %** | **1,229 → 0.2145 %** | 3.97× |
| loss **events** | **144** | **143** | **1.01×** |
| slots per event | **2.15** | **8.59** | 4.0× |
| **CRC-fail frames** | **129** | **128** | **1.01×** |
| **garbage / magic-unparseable** | **164** | **956** | **5.83×** |

The denominators agree to 0.9993, so this is like-for-like — that was the point of
cutting on the 46 whole intervals rather than the nominal 470/715 s windows.

**The checker is internally consistent**, so the 5.83× is a real difference and not a
broken counter: garbage + crc_fail = 293 against `chk_lost_slots` = 309 (0.948), and
the gap-derived slot count g1 + 2·g2 + 3·g3 = 15 + 188 + 105 = 308 ≈ 309. The two
instruments also use the *same* definition for that row — `rx_seq_checker.v:56`,
"`cnt2 garbage` — magic/len not parseable, counted at header".

**The two series are the same events.** Over the 46 intervals: host loss events vs
checker gap events **Pearson r = +0.935 (p = 1.8 × 10⁻²¹)**, Spearman ρ = +0.949;
host slots vs `chk_lost_slots` r = +0.920; host slots vs `chk_crc_fail` r = +0.941.
**0** intervals where the checker saw a gap and the host lost nothing; 1 the other
way; 16 where neither saw anything. Per-interval series banked in
`t23_evidence/checker_host_intervals.csv`.

Slot budget of the 1,229:

| | slots | share |
|---|---|---|
| already bad at the pins (129 CRC + 164 garbage) | 293 | **23.8 %** |
| magic-bad **created** between the pins and the host buffer | 791 | **64.4 %** |
| no host record at all | 145 | 11.8 % |

So "74.8 % downstream" is arithmetically right and must **not** be read as a second,
independent downstream defect: every burst has a fabric-side seed the checker sees,
and the delivery path multiplies its cost ~4×. §4.2 says how.

---

## 6. Q4 — the five 4-s flatlines and the six ~10 % census dips

**Answer: neither is the bursts; both are instrument artifacts.**

**The five `!! delivery stalled 4s` lines.** A 4-s flatline is ~4,980 consecutive lost
slots; the longest run in the live window is 17 and the `21-100`/`>100` bins are empty,
so no such event is in the host data. Three independent confirmations:

* **Per-second clean-frame rate from `frames.bin`**: no second below 626 f/s (half
  the 1,253 peak) anywhere in the live window; **minimum 4-second clean-frame sum =
  4,883** against the watchdog's `< 200` threshold; **0** four-second windows below 200.
* **The mechanism.** `capture_r3.sh:325` polls `dma_rx_ok` by grepping the **last
  `stats:` line** of `/dev/shm/qpsk_tun.log`, every `sleep 4` plus one ssh. The daemon
  writes that line every **5.00 s** (median Δ = 6,227 frames at 1,245 f/s over 155
  lines). A ~4.8 s effective poll against a 5.00 s log cadence re-reads the same line
  a few percent of the time — 5 of ~145 polls is what that predicts.
* **The polled counter never flatlined.** `dma_rx_ok`'s own series has zero-deltas
  only at line indices 0, 2, 3 (before delivery started) and 153 (after quiesce):
  **0 zero-deltas in the steady state**.
* The W1 baseline leg produced **4** of the same warnings at PER 8.31 %, so the
  warning count is uncorrelated with PER.

**The six ~10 % census dips** — `w1_reads.csv` rows at 20:21:03, 20:22:03, 20:23:03,
20:24:33, 20:26:13, 20:27:33 with `d_frames` below 0.95 × median (12,598):

| | `d_frames` | `d_r4b_skips` | skips/frames | `dt_s` | host events / slots per 10 s |
|---|---|---|---|---|---|
| the 6 dips | 11,376 | 357.0 | 0.03138 | 10.000 | **3.50 / 29.3** |
| the other 41 | 12,613 | 396.0 | 0.03140 | 10.000 | **2.93 / 25.3** |
| ratio | **0.9019** | **0.9015** | **0.9995** | 1.000 | — |

Every counter scaled down by the same 10 % in the same interval (ratio-of-ratios
0.9995) — a short read, not lost frames. The host agrees: the dip intervals are
statistically indistinguishable from the rest, and **three of the six contain zero
host loss events at all**. This confirms and explains Task 13 §4.7's observation that
`r4b_skips` Δ fell to 355–360 on exactly those rows.

---

## 7. Q5 — RSSI / hardwaregain

**Answer: UNANSWERED. 0 of 3 candidate replicate runs carry board data.**

The brief expected a T17 replicate leg with RSSI columns. It does not exist. The
three later `*_w1_air` directories are **`dry=1` rehearsals**, not aborted legs:
`dur=1`, `run.log` full of `[dry]` lines, `meta.txt`
`image=[dry] md5sum /boot/BOOT.BIN | cut -c1-12`, `verdict.txt` 103 B of
`[dry] would score …`. There is no `*fwd-after2*` directory, and **no `w1_reads.csv`
anywhere in the repository has an `rssi` or `hardwaregain` column**. The prereg's
"AGC railed at 34.0 dB, RSSI flat" is **untested**, and nothing here should be read
as having tested it.

Substitute RF evidence, from `frames.bin`'s own witnesses over 871,598 in-window
records:

| witness | value | reading |
|---|---|---|
| `reg_rstcs` | **0 on every record** | zero carrier/AGC resets, zero re-lock events |
| `reg_cfc` | span 810 counts, sd 108.0; near a burst onset (±0.25 s) mean −3424.5 vs −3425.4 elsewhere | **0.008 sd**; Mann-Whitney p = 0.0128 on n = 97,260 vs 774,338 — detectable only because the sample is huge, effect size nil |
| `reg_biterr` Δ/record | 58.8 near a burst onset vs 58.0 elsewhere | **+1.4 %**, and 0x108 sees only the first 120 of 2,240 bits, so even this is frame-start damage |

No AGC excursion, no re-lock, no graded fade. The RF-attributable part of the class is
the **trigger** — 157 of 159 burst-position-0 frames are CRC-fail at the pins — which
is ~1 frame in 8.6.

---

## 8. Is it a new class? No — the pre-existing one, 25 % smaller

Both legs through the same reconstruction (`comb_census.py` +
`common.loss_slot_trains`; the R4B side reproduces `accept_analyze`'s 1,956 / 213 /
bins / 0.2244 % exactly through that path, which is the cross-implementation check):

| bin | W1 events (/s) | W1 slots | W1 PER pp | R4B events (/s) | R4B slots | R4B PER pp |
|---|---|---|---|---|---|---|
| 1 | 37,288 (53.04) | 37,288 | 4.2597 | 18 (0.0257) | 18 | 0.0021 |
| 2 | 15,731 (22.38) | 31,462 | 3.5941 | 1 (0.0014) | 2 | 0.0002 |
| 3–4 | 500 (0.7112) | 1,521 | 0.1738 | 33 (0.0471) | 112 | 0.0128 |
| **5–20** | **220 (0.3129)** | **2,440** | **0.2787** | **161 (0.2300)** | **1,824** | **0.2092** |
| 21–100 | 1 | 27 | 0.0031 | 0 | 0 | 0 |
| max run | 27 | | | 17 | | |
| **total** | | **72,738** | **8.3093** | | **1,956** | **0.2244** |

The 5–20 class's rate fell **−27 %** and its PER contribution **−25 %** (0.2787 →
0.2092 pp); its run-length shape is unchanged (mean 11.09 vs 11.33, near-uniform over
5..17) and it already carried the 8.140 s line under W1. **R4B removed the
singles/doubles comb and took a quarter off this class as a side effect; it did not
create it.** Task 13 §4.8 F-C's reading is confirmed, with the one correction that the
class is not merely "lower than before" by accident — its *rate* moved.

---

## 9. The prereg, scored item by item and quoted verbatim

> ~93 % of residual frames in the 5–20 bin

**HOLDS.** 93.25 % (1,824 of 1,956 slots; 161 of 213 events).

> ~one event per 4.4 s

**HOLDS.** 4.35 s mean gap for the 5–20 class over the 700 s window.

> no single period

**FAILS.** A coherent line at **8.140 s**, family-wise p < 2.5 × 10⁻⁴ (uniform null)
and p = 0.0003 (clustering-preserving null), split-half coherent in three RX subsets
and in the independent `failhdr` ring, present in the W1 baseline's 5–20 class,
surviving the reader-off control. §3.

> MAGIC-dominated

**HOLDS** — 88.8 % — **but not with the meaning the prereg attached to it.** With
`RXQ_ZEROHDR` off, MAGIC means *garbage content in a delivered slice*, not an
unfilled slot; an unfilled slot would be class 4, and there are none. §1(b), §4.

> RSSI flat

**UNTESTED.** No leg with an RSSI column exists. §7.

> most of the residual downstream of the pins

**AMBIGUOUS — the arithmetic holds, the mechanism it implies is falsified.** 74.8 % of
the lost *frames* are added downstream of the decoder pins, but the *events* match the
pins one-for-one (143 vs 144, r = +0.935) and every delivery-plane mechanism the label
implies is excluded by measurement (no holes, no flatlines, no −M alignment). §5.

> → delivery/stall class

**FAILS.** The class is a byte-alignment cascade seeded by a decode error, not a
delivery stall. The five flatlines that motivated the label are an artifact of a 4 s
poll against a 5.00 s log cadence. §6.

---

## 10. Concerns

1. **`magic_off = 568` is a strong new observation on one leg.** It is 1,259 records
   at one offset against a 2.3 % chance floor, cross-checked against a baseline leg
   that shows a different offset — but it is one 12-minute capture, and the sign of
   the displacement (568 B gained, or 1,528 − 568 = 960 B lost) is *not* determined by
   any measurement here. The proposed instrument's "byte count since the last frame"
   field is what settles it.
2. **The recovery point of the cascade was not identified.** Run onsets and ends are
   unaligned to any −M block on the reconstructed TX-slot axis (onset χ² p = 0.45 /
   0.037 / 0.0012 for mod 8 / 16 / 32; **end p = 0.945 / 0.999 / 0.345**; runs entirely
   inside one block at exactly the random expectation). But the host's carve phase
   drifts against that axis *inside* a burst — each lost slot shifts it — so this test
   bounds the onset, not the recovery. A near-uniform run length over 5..17 with a hard
   ceiling at 17 is what recovery at a boundary a uniform distance away looks like; the
   boundary itself is unidentified.
3. **The 106.8 s peak is the largest number in the periodicity scan and is not
   claimed.** It reproduces across two independent legs (106.55 / 106.80 s), which is
   the only real evidence for it; both windows are ~700 s, so a slow drift peaks near
   W/6.5 in both. It is reported as unresolved. If it is real it is a *bigger* signal
   than the 8.140 s line and a longer capture would settle it in one leg.
4. **`chk.jsonl`'s `ts_mono` is the reader host's clock, not the board's** (883,116 s
   vs 887 s). Nothing in the checker's own files says so, and a future joiner that
   assumes otherwise will silently misalign by ten days. It is worth a line in
   `README_hostlog.md`.
5. **The checker/host event correspondence is at 10 s resolution.** r = +0.935 on 46
   intervals is strong, but it is a *count* correlation, not an event-by-event join —
   the checker exposes no per-event timestamp. That is precisely the gap the proposed
   instrument closes, and until it does, "one-for-one" is an inference from matched
   totals (143 vs 144) plus a per-interval correlation, not a match of individual events.
6. **Both legs lost one wedge** (715/721 s and 718/723 s), so neither is a pristine
   link; the comparison is like-for-like but the W1↔R4B 5–20 rate difference (−27 %)
   is a two-sample comparison with no error bar. Two more legs on each image would
   give one.
7. **The brief's `failhdr.bin` figure (5,440) is one out** (the header declares 5,439)
   and its three "T17 replicate" candidates are dry runs. Neither changes a conclusion,
   but both were taken from the brief rather than from the files, and this task took
   them from the files.
8. **`accept_analyze.py` is slow on a high-loss leg.** The R4B run scores in ~200 s;
   the W1 baseline had not finished in 25 minutes (the `np.correlate` lag-33 train over
   ~875 k slots is O(n²)). The W1 bins here therefore come from `comb_census.py` +
   `common.loss_slot_trains`, which is the same reconstruction — and R4B was scored
   through *both* paths and agrees exactly (1,956 / 213 / identical bins). No tool was
   changed to make it faster; the duplication of the window rule is deliberate
   (`common.py`'s own docstring) and was left alone.

---

## 11. Evidence

Banked under `two_jup/sdd_archive/2026-09-04-rxfix/t23_evidence/` (derived artifacts
only; the raw captures stay under `two_jup/comb/runs/*/cap/` per the precommit rule):

| file | what |
|---|---|
| `r4b_bursts.csv` | 213 loss runs — onset `host_seq`, run length, `t_s`, `t_mono_ns`, `t_real_ns` |
| `r4b_census.json` / `w1_census.json` | full `comb_census.py` output for both legs |
| `r4b_magicoff.txt` | the `magic_off` census and the within-burst position table (§4.1, §4.2) |
| `checker_host_intervals.csv` | the 46 common intervals — checker and host side by side, plus the reader's `d_frames` |

Tool changes: `two_jup/accept_analyze.py` (`--burst-times`),
`two_jup/tests/test_accept_burst_times.py` (7 tests). Deliverable:
`two_jup/comb/FWD_RESIDUAL_0p22.md`.
