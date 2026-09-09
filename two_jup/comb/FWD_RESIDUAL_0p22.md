# The forward residual, 0.224 % — what class is it?

Desk analysis on banked data (RXFIX Task 23). No board contact.
Primary run: `two_jup/comb/runs/20260904_201814_w1_air` — 148 on W1+R4B
`9f13705d9fb0`, 146 on `3378861d30bd`, forward 146→148, capture 721 s,
live window 15–715 s. Baseline for comparison: `two_jup/comb/runs/20260904_165420_w1_air`
(Task 10's W1 leg, PER 8.309 %).

---

## Headline

**The residual is not RF margin, not a host/DMA delivery stall, and not a
scheduled process. It is a byte-alignment cascade in the receive delivery path:
one decode error at the decoder pins costs the host 8.6 frames instead of 1,
because the frames after it are displaced by a fixed 568 bytes inside the host's
carve slice and stay displaced until the stream resyncs.**

Every burst has the same internal structure, measured on 159 bursts:

| position in the burst | n | what it is | `magic_off` = 568 |
|---|---|---|---|
| 0 (first failed frame) | 159 | **157 of 159 are CRC-fail** (class 3) — a real decode error | 0.6 % |
| 1 | 159 | 159 of 159 MAGIC (class 1), **151 with no frame magic anywhere** — destroyed | 1.3 % |
| 2 | 159 | MAGIC | **72.3 %** |
| 3 | 159 | MAGIC | **96.2 %** |
| 4 | 150 | MAGIC | **95.3 %** |
| 5 | 138 | MAGIC | **96.4 %** |
| ≥ 6 | 721 | MAGIC | **97.2 %** |

One CRC error → one destroyed frame → a fixed 568-byte displacement that persists
for the rest of the run. `magic_off` is the offset of the first `0x51 0x4B` in the
slice; its chance floor is ~2.3 % (`README_hostlog.md` §3.3, which asks for exactly
this: "a *large* excess would be a genuinely new observation"). Over the whole live
window **1,305 of 1,543 class-1 failures (84.6 %) contain the frame magic, and 1,259
of those sit at exactly offset 568** — with 25 at 376 and 14 at 1,136 (= 2 × 568).
The W1 baseline's comb failures do *not* look like this: only 18.5 % carry a magic
at all and the dominant offset there is 64, not 568.

Reproduce: `two_jup/sdd_archive/2026-09-04-rxfix/t23_evidence/r4b_magicoff.txt`.

---

## The five questions, each with a number and a label

### Q1 — burst timestamps: clustered, periodic, or Poisson?

**Label: CLUSTERED, with one coherent 8.140 s rate line. Not Poisson. Not a single
strict period.**

`accept_analyze.py --burst-times` (new option, tested) on the leg gives 213 loss
runs / 1,956 slots, PER **0.2244 %** — the same `1956/871805`, `bins={'1':18,'2':1,
'3-4':33,'5-20':161,'21-100':0,'>100':0}` Task 13 reported.

| quantity | value |
|---|---|
| share of residual frames in the 5–20 bin | **93.25 %** (1,824 of 1,956 slots, 161 events) |
| mean gap between 5–20 events | **4.35 s** |
| longest run in the whole live window | **17 slots** (13.65 ms) |
| inter-arrival, all 213: mean / median / CV | 3.209 s / **0.730 s** / **2.473** |
| KS vs exponential | D = 0.3668, **p = 4.5 × 10⁻²⁶** → **not Poisson** |
| Fano factor, 10 / 20 / 35 s bins | 3.233 / 4.025 / 4.302 |
| χ² vs uniform, 10 s bins (dof 69) | 223.1, **p = 3.9 × 10⁻¹⁸** → **clustered** |

Grouping events separated by more than 3 s gives **50 clusters** of 4.26 events /
39.1 slots. The *cluster onsets* are uniform in time (χ² = 45.2, dof 69, p = 0.988;
Fano 0.655) — the clustering is entirely within-cluster.

**The 8.140 s line.** Rayleigh scan 1–120 s on the 50 cluster onsets: best
**P = 8.140 s (0.1229 Hz), R = 0.5499**, family-wise p **< 2.5 × 10⁻⁴** against a
uniform null (N = 4,000) and **p = 0.0003** against a gap-shuffled null that
preserves the clustering. 86 cycles in the window. It survives four independent
checks:

* **split-half phase coherence** |Δφ| = 0.059 (all 213 onsets), 0.037 (5–20 onsets),
  0.066 (cluster onsets) cycles;
* **an independent instrument** — the `failhdr` ring (n = 1,738, 148's own
  `CLOCK_MONOTONIC`): R(8.140) = 0.5287, |Δφ| = 0.047;
* **the reader-off control** — the register reader was active only for t = 8–478 s.
  With it off (478–715 s) R(8.140) = 0.520 at phase 0.620, against 0.480 at phase
  0.569 while it ran, and the event rate is identical (0.3039 vs 0.3045 /s). The
  line is not the reader's `direct_reg_access` traffic;
* **it is already in the W1 baseline's 5–20 class** (R = 0.357, coherent, |Δφ| =
  0.057) and **absent from W1's singles and 3–4 classes** (R = 0.0035 / 0.015, both
  incoherent).

It is a **rate modulation**, not a pulse train: R(P/2) = 0.070 and R(P/3) = 0.010,
i.e. no harmonic power.

**Not claimed:** the strongest full-band peak is at 106.8 s (R 0.54–0.62), and it
reproduces on the W1 leg at 106.55 s. With only 6.6 cycles in a 700 s window this is
below the ≥ 20-cycle bar this task set itself before scanning, and both windows are
the same length, so a slow drift would peak near W/6.5 in both. **Reported as an
unresolved low-frequency component, not as a measured period.**

### Q2 — fail class of the residual, and the NEVER_SENT share

**Label: MAGIC-dominated garbage-on-slice; zero delivery holes; zero TX starvation.**

`comb_census.py cap/frames.bin --failhdr cap/failhdr.bin --txlog cap/txlog_peer.bin`
over the live window (n = 871,598 records):

| class | count | note |
|---|---|---|
| OK | 869,860 | |
| **MAGIC** (1) | **1,543** | **88.8 %** of the 1,738 failures |
| LEN (2) | 0 | |
| CRC (3) | 195 | 11.2 % |
| **ZEROTAIL** (4) | **0** | |

* **NEVER_SENT = 0 of 1,956 (0.00 %)**; `sent_not_decoded` = 1,956 (100 %).
  **No host TX starvation on 146.** The TX log is `cap/txlog_peer.bin` — verified,
  not assumed: 99.81 % of 148's good `host_seq` appear in it, against 0.00 % in
  148's own `cap/txlog.bin` (which holds 5 distinct seqs).
* **ZEROTAIL = 0, and `class4 delivery_hole(fzo==0) = 0`.** `QPSK_RXQ_ZEROHDR` was
  **off** on this leg — `cap/qpsk_tun.log` carries no `RXQ EXPERIMENT: header-only
  pre-submit zero` line, so `rx_pump_queued` zeroed the whole carve
  (`qpsk_tun.c:1461/1466`). An RX slot the DMA never filled would therefore
  *necessarily* read back as class 4 with `first_zero_off == 0`. There are none.
  **Zero RX delivery-plane holes**, and this is the mode-dependent reading
  `README_hostlog.md` §2 demands: MAGIC here means *garbage content*, not an
  unfilled slot.
* **Onset histogram: `n_have = 0`, `n_none = 1,738`** — not one failed frame had a
  zero tail of any kind. No ALIGNLOSS.
* **1,738 of 1,956 lost slots (88.9 %) reached the host as a slice that failed to
  parse; 218 (11.1 %) produced no host record at all.**
* Dump completeness (`README_hostlog.md` §5.6): `failhdr.bin` declares
  **n_records = 5,439** — not the 5,440 in the brief — 174,080 B = 32 + 32 × 5,439,
  `wrapped = False`, `total = 5,439`, so no events were lost. (`failhdr_peer.bin`
  *is* wrapped, 65,536 of 66,172, and was not used.)

### Q3 — reconciling the checker's 0.053 % with the host's 0.224 %

**Label: the events are born at or upstream of the decoder pins, one-for-one;
74.8 % of the lost *frames* are added downstream of them.**

Common window = the 46 checker intervals falling entirely inside the host live
window, **2026-09-04T20:20:44 → 20:28:24, 460.0 s**. `chk.jsonl`'s `ts_mono` is the
*reader host's* clock (883,116 s) not 148's (887 s), so wall time is the only shared
axis; both series were cut on `ts_wall` / `t_real_ns`.

| | at the decoder pins (fabric checker) | at the host | ratio |
|---|---|---|---|
| frames / slots | 572,520 (1,244.6 f/s) | 572,901 (1,245.4 slots/s) | **0.9993** |
| lost slots | **309 → 0.0540 %** | **1,229 → 0.2145 %** | **3.97×** |
| loss **events** | **144** | **143** | **1.01×** |
| slots per event | 2.15 | 8.59 | 4.0× |
| CRC-fail frames | 129 | 128 | **1.01×** |
| garbage / magic-unparseable | 164 | 956 | **5.83×** |

The two instruments use the same definition for that last row —
`rx_seq_checker.v:56`, "`cnt2 garbage` — magic/len not parseable, counted at header".
The checker is internally consistent on this window (garbage + crc_fail = 293 against
`chk_lost_slots` = 309, ratio 0.948; the gap-derived slot count
g1 + 2·g2 + 3·g3 = 308 ≈ 309), so the 5.83× is a real difference, not a broken counter.

**The event counts match one-for-one and the two series track interval by interval:**
Pearson r = **+0.935** (p = 1.8 × 10⁻²¹), Spearman ρ = +0.949 over the 46 intervals;
0 intervals where the checker saw a gap and the host lost nothing; 16 where neither
saw anything. Per-interval series in `t23_evidence/checker_host_intervals.csv`.

Slot budget of the 1,229 host-lost slots:

| | slots | share |
|---|---|---|
| already bad at the decoder pins (129 CRC + 164 garbage) | 293 | **23.8 %** |
| magic-bad **created** between the pins and the host buffer | 791 | **64.4 %** |
| no host record at all | 145 | 11.8 % |

So the naive "74.8 % downstream" split is arithmetically right but must not be read
as "a second, independent downstream defect". Every burst has a fabric-side seed that
the checker sees; the delivery path then multiplies its cost ~4×.

### Q4 — are the five 4-s flatlines and the six ~10 % census dips the same events?

**Label: no. Both are instrument artifacts; neither is a link event.**

**The five `!! delivery stalled 4s` lines are artifacts.**

* Per-second clean-frame rate from `frames.bin`: **no second below 626 f/s** anywhere
  in the live window; the **minimum 4-second clean-frame sum is 4,883** against the
  watchdog's `< 200` threshold, and **0** four-second windows fall below 200. A real
  4-s flatline would be ~4,980 consecutive lost slots; the longest run in the whole
  window is 17.
* The watchdog (`capture_r3.sh:325`) polls `dma_rx_ok` by grepping the **last
  `stats:` line** of `/dev/shm/qpsk_tun.log` every `sleep 4` + one ssh. The daemon
  writes that line every **5.00 s** (median Δ = 6,227 frames at 1,245 f/s over 155
  lines). Two consecutive polls therefore re-read the same line and report
  `+0 frames`. The daemon's own counter — the very one being polled — has
  **zero zero-deltas in the steady state** (they occur only at line indices 0, 2, 3,
  before delivery started, and 153, after quiesce).
* The W1 baseline leg emitted **4** of the same warnings at PER 8.31 %. The warning
  count is uncorrelated with PER.

**The six ~10 % census dips are a reader sampling deficit.** They are the
`w1_reads.csv` rows at 20:21:03, 20:22:03, 20:23:03, 20:24:33, 20:26:13 and 20:27:33
where `d_frames` < 0.95 × median (12,598).

| | `d_frames` | `d_r4b_skips` | skips/frames | `dt_s` |
|---|---|---|---|---|
| the 6 dips | 11,376 | 357.0 | 0.03138 | 10.000 |
| the other 41 | 12,613 | 396.0 | 0.03140 | 10.000 |
| ratio | **0.9019** | **0.9015** | **0.9995** | 1.000 |

Every counter scaled down by the same 10 % in the same interval — a short read
window, not lost frames. And the host agrees: **3.50 events / 29.3 slots per 10 s**
in the dip intervals against **2.93 / 25.3** elsewhere, and **three of the six dips
contain zero host loss events at all**.

### Q5 — RSSI / hardwaregain vs bursts

**Label: UNANSWERED. 0 of 3 candidate replicate runs carry board data.**

The three later `*_w1_air` directories (`20260904_205036`, `_211034`, `_211522`) are
`dry=1` rehearsals — `dur=1`, `meta.txt` records
`image=[dry] md5sum /boot/BOOT.BIN | cut -c1-12`, `verdict.txt` is 103 B of
`[dry] would score …`. No `*fwd-after2*` directory exists and **no `w1_reads.csv` in
the repository has an `rssi` or `hardwaregain` column**. The prereg's "AGC railed at
34.0 dB, RSSI flat" is untested.

What the banked leg *can* say about the RF side, from `frames.bin`'s own witnesses
over 871,598 in-window records:

* **`reg_rstcs` = 0 on every record** — zero carrier/AGC resets, zero re-lock events.
* **`reg_cfc`** spans 810 counts (sd 108.0). Within ±0.25 s of a burst onset the mean
  is −3424.5 against −3425.4 elsewhere: **0.008 sd**. Mann-Whitney p = 0.0128 on
  n = 97,260 vs 774,338, i.e. detectable only because the sample is huge; the effect
  size is nil.
* **`reg_biterr`** delta per record 58.8 near a burst onset vs 58.0 elsewhere
  (**+1.4 %**) — and 0x108 sees only the first 120 of 2,240 bits, so even that is
  frame-start damage, not a graded fade.

No AGC excursion, no re-lock, no fade signature. The burst *trigger* is a genuine
CRC-fail at the pins (157 of 159 burst positions 0), which is the RF/decode-attributable
part — about 1 frame in 8.6.

---

## Is it a new class? No — it is the pre-existing one, 25 % smaller

Same reconstruction (`comb_census.py` / `common.loss_slot_trains`) on both legs:

| bin | W1 events (/s) | W1 slots | W1 PER pp | R4B events (/s) | R4B slots | R4B PER pp |
|---|---|---|---|---|---|---|
| 1 | 37,288 (53.04) | 37,288 | 4.2597 | 18 (0.026) | 18 | 0.0021 |
| 2 | 15,731 (22.38) | 31,462 | 3.5941 | 1 (0.001) | 2 | 0.0002 |
| 3–4 | 500 (0.711) | 1,521 | 0.1738 | 33 (0.047) | 112 | 0.0128 |
| **5–20** | **220 (0.3129)** | **2,440** | **0.2787** | **161 (0.2300)** | **1,824** | **0.2092** |
| 21–100 | 1 | 27 | 0.0031 | 0 | 0 | 0 |
| **total** | | 72,738 | **8.3093** | | 1,956 | **0.2244** |

The 5–20 class's rate fell 0.3129 → 0.2300 events/s (**−27 %**) and its PER
contribution 0.2787 → 0.2092 pp (**−25 %**); its run-length shape is unchanged
(mean 11.09 vs 11.33, near-uniform over 5..17). It carried the 8.140 s line under W1
too. **R4B removed the singles/doubles comb and took a quarter off this class as a
side effect; it did not create it.** Task 13's reading ("the pre-existing burst class
the campaign already knew about") is confirmed, with the correction that it is not
unchanged.

---

## The class

> **A byte-alignment cascade in the receive delivery path (decoder pins → host carve
> buffer), triggered by a single decode error at the pins and rate-modulated at
> 8.140 s.** One CRC-fail costs the host 8.59 frames instead of 1: the frame after it
> is destroyed, and the following ~6–15 frames arrive displaced by a fixed 568 bytes
> inside the slice until the stream resyncs. 93.25 % of the residual sits in that
> tail.

Excluded, each with its number:

| candidate | verdict | evidence |
|---|---|---|
| host/DMA **delivery stall** | **excluded** | min 4-s clean sum 4,883 vs a <200 threshold; 0 flatline seconds; longest run 17 slots; the 5 warnings are a 4 s poll against a 5.00 s log cadence |
| RX **delivery hole** (unfilled carve slot) | **excluded** | ZEROTAIL = 0 and fzo == 0 count = 0, with `RXQ_ZEROHDR` off so such a slot would land there by construction |
| host **TX starvation** on 146 | **excluded** | NEVER_SENT = 0 / 1,956 |
| **RF margin** (AGC rail, re-lock, fade) | **excluded as the class** | rstcs = 0 on 871,598 records; CFO shift 0.008 sd; biterr +1.4 %. It *is* the trigger — 157 of 159 burst-position-0 frames are CRC-fail — but only ~1 frame in 8.6 |
| a **scheduled process** | **excluded** | reader-off control: identical event rate (0.3039 vs 0.3045 /s) and the same 8.140 s line with the reader stopped |
| **DMA transfer-boundary** (the old comb mechanism) | **excluded** | run onsets/ends unaligned mod 8/16/32 on the TX-slot axis (onset p = 0.45/0.037/0.001, end p ≈ 1, in-block fraction at random expectation). Caveat: the host's carve phase drifts against that axis *inside* a burst, so this test bounds the onset, not the recovery point |

Still open: what sets **568 bytes**, and what ends the cascade (the near-uniform
run-length distribution over 5..17 with a hard ceiling at 17 is what a recovery at a
boundary a uniform distance away looks like, but the boundary was not identified);
and what drives the **8.140 s** modulation.

---

## Next instrument

**A per-event trace at the decoder pins, keyed to the host's `failhdr` ring.**

The question that decides the fix is narrow and now precisely stated: *for each of
the ~144 events per 460 s, was the frame already unparseable at the pins, or only
after the delivery path?* Today nothing can answer it — `chk.jsonl` is a 10 s
aggregate (it cannot even resolve the 8.140 s line), its `ts_mono` is the reader
host's clock, and the full-rate DDRCAP taps drop ~20 % of records at the rx2 DMA.

Proposal: extend `rx_seq_checker` (`jupiter_240k5_byte/rtl_sim/rx_seq_checker.v`)
with a small on-chip **event ring** — for each gap/garbage/crc event, record
`{frame index, verdict (good/garbage/crc), sequence step, byte count since the last
frame}` — read out over the existing W1/R4B register path that Task 13 already
built and proved (`0x214`–`0x234`). 64 entries × 8 B covers 3 minutes of events at
the measured rate. Two things fall straight out:

1. joining the ring to the host's `failhdr` records by frame index tests, per event,
   whether the 791 downstream-created MAGIC frames were intact at the pins — which
   is the whole 74.8 %;
2. the "byte count since the last frame" field measures the 568 B directly in the
   fabric, and says whether the byte stream **gained** 568 B or **lost** 960 B
   (= 1,528 − 568) at the event — the sign that distinguishes an inserted burst from
   a dropped one.

Cheap prerequisite, no build: rerun the leg with `QPSK_RXQ_ZEROHDR=1`. Under
zerohdr only the first 8 bytes of each slot are zeroed, so a slice whose header is at
568 keeps its magic and the host's own class-1 census gains a control arm — and the
`magic_off = 568` population must survive unchanged if the displacement is upstream
of the carve.

**No fix is proposed here.** Nothing in this task was measured on a board.

---

## Reproducing every number

All from the two banked run directories; the raw captures stay under `cap/` per the
repo's precommit rule.

```
# Q1 (adds --burst-times; default path unchanged)
python3 two_jup/accept_analyze.py --burst-times t23_evidence/r4b_bursts.csv \
        two_jup/comb/runs/20260904_201814_w1_air/cap/frames.bin
python3 -m unittest two_jup.tests.test_accept_burst_times      # 7 tests

# Q2 (note: txlog_PEER -- 146 is the transmitter on a forward leg)
python3 two_jup/comb/comb_census.py \
        two_jup/comb/runs/20260904_201814_w1_air/cap/frames.bin \
        --failhdr two_jup/comb/runs/20260904_201814_w1_air/cap/failhdr.bin \
        --txlog   two_jup/comb/runs/20260904_201814_w1_air/cap/txlog_peer.bin \
        --out t23_evidence/r4b_census.json
# same for two_jup/comb/runs/20260904_165420_w1_air -> w1_census.json
```

Banked derived artifacts, `two_jup/sdd_archive/2026-09-04-rxfix/t23_evidence/`:
`r4b_bursts.csv` (213 loss runs with onset seq, run length and both clocks),
`r4b_census.json`, `w1_census.json`, `r4b_magicoff.txt` (the `magic_off` and
within-burst tables), `checker_host_intervals.csv` (the 46 common intervals, checker
and host side by side). Method notes and the statistics are in
`two_jup/sdd_archive/2026-09-04-rxfix/task-23-report.md`.
