> Evidence ledger, moved verbatim from `two_jup/comb/MIDWINDOW_CLASS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# MIDWINDOW_CLASS — the mid-window collapse is a receiver-side loss of lock on 146, with no host
# and no peer-transmit precursor; the latched state is the at-arm class's (RXFIX Task 40)

Desk audit, 2026-09-06, archived run dirs + repo only. No board touched, no rig unit, no subagent.
Labels: **[log]** read from an archived run dir, **[code]** read in the repo, **[silicon]** a prior
on-silicon fact cited from the memory/state files, **[inferred]** arithmetic or reasoning on those.
Method and detectors are deliberately the ones ATARM_CLASS.md sec 1/4.1/9.2 used, so the two classes
are scored on the same instruments.

## 0. Verdict

**The mid-window collapse is not a starvation event of any kind.** In all three collapses the first
anomaly in time is on the receiving board itself and it is a carrier-loop event: `reg_rstcs` (0x150)
and `reg_cfc` (0x154) move in the **same framelog record**, from a receiver that was at 99.9 %
`crc_ok` and `rstcs = 0` in every one of the preceding 0.2-s bins for at least 3 s. Decode dies
**47–95 ms later**, the storm runs at **824–896 resets/s** (sec 4's three per-leg slopes; the
“824–904” this document quoted before was a merge across fit windows — sec 8) and never stops [log].

Nothing else moved first. The peer's transmit feed had **zero** gaps ≥ 3 ms in the whole pre-onset
window — the largest gap it ever measured was **0.312 ms / 0.008 ms / 0.137 ms** (t37_a / t37_b /
183520), i.e. 22× to 875× below the 7 ms dose that collapses a far receiver in 38/38 cases
[log, ATARM sec 4.1]. The peer's one gap ≥ 3 ms in each leg is its step-8 `SIGUSR1` dump, landing
**+24.2 / +24.2 / +28.0 s AFTER** the onset. The RX board's own event loop shows the same: its only
≥ 3 ms feed gap before the onset is its own rotate, 150–547 s earlier, and the framelog's `t_mono`
hole across the onset is **11.9 / 0.05 / 0.05 ms** [log]. There is **no fade**: the receiver's own RSSI, measured
inside the ADRV9002, spans 23.88–25.59 dB over the whole leg, 24.07 dB at −6.1 s and 25.11 dB at
+2.8 s [log — the first pre-collapse RSSI samples in the archive]. But it is not *nothing*: in 2/2 the
reading that straddles the onset carries a **+1.0 dB step in `rssi` and `decpwr` and an AGC gain-index
step 34.000 → 33.000 dB**, against 34.000 dB on 49/49 pre-onset readings. That 1 dB step is the only
thing in the archive that moves with the onset besides the receiver itself, and it is unresolved
(sec 5.2).

**All five mid-window events on disk are on 146 as the receiver; 148-as-receiver has 8,677 s of
mid-window exposure and zero** (p = 0.029 under an equal hazard) [log+inferred]. The events span
three different 146 images (`6b4744ca73f8`, `3378861d30bd`, `9acbe2ebe1db`), so the image is not the
variable; the direction is confounded with the board and is the main open caveat (sec 6).

Ranked mechanism (sec 5). **The latched state is not specific to this trigger.** The W1 census puts
the mid-window storm at `cSS` = **0.812 × nominal** — window `i16→i18`, the last one that ends before
the harness quiesce (sec 2, sec 8) — with `occ → 0`, `pop_on_empty` storming and the FULL-side
steering (`r4d_extras`) frozen; the one archived leg whose census straddles a **starvation-induced**
step-8 collapse (`161957`, 148 as receiver, a different image) gives **0.776–0.799** on the same six
counters with the same ring signature [log]. Two demonstrably different triggers reach the same
attractor, so the latch is trigger-independent and lives in the receive chain at or upstream of
`Symbol_Synchronizer`. A **sustained FULL-edge** Rate_Handle deletion is excluded — but by the ring
occupancy, **not** by `push_on_full`, which cannot fire at all on the image all three collapses ran
on and is retired as evidence here (sec 2.1). What
remains open is (i) **where** that latch is — modem fabric (sec 5.1) or the 146 ADRV9002→FPGA RX SSI
(sec 5.3) — which sec 7's 36-board-minute ladder separates, and (ii) **what triggers it mid-window**,
for which the 1 dB AGC/RSSI step is the only candidate on offer.

## 1. Q1 — the timing table

Clocks. Every RX-side time is the RX board's `CLOCK_REALTIME` (`frames.bin` `t_real_ns`) expressed
relative to `CAP_START` from `cap/regs_cap.txt` (taken with `date` **on the board**, so the same
clock) [code capture_r3.sh:65-66]. The peer's `txlog_peer.bin` is on the peer's `CLOCK_MONOTONIC` and
is placed on the RX clock by the **seq join** of ATARM sec 1: 186,079 / 446,267 / 655,682 matching
`(seq → t_real)` pairs give a peer-mono→RX offset with **sd 0.9–2.2 ms** [log]. The nemo-side readers
(`reads/`, `rssi.jsonl`, `chk.jsonl`) are placed on the RX clock by joining their `0x104` reading to
the framelog's `reg_packets`; `chk.jsonl` carries a nanosecond `ts_mono` and gives **sd 17–18 ms**,
the `reads/` timestamps are `date`-truncated to the second and give ±0.5 s [log].

### 1.0 Event table — seconds relative to the RX collapse onset (negative = before)

Onset = the first framelog record of a run of ≥ 20 consecutive failures, i.e. the record after the
last `crc_ok`. "First reset" = the first `reg_rstcs` increment after t = 60 s.

| event | t37_a (146 RX) | t37_b (146 RX) | 183520 legB_m8rx (146 RX) |
|---|---|---|---|
| onset, CAP_START-relative | **+142.597 s** | **+351.792 s** | **+539.517 s** |
| onset record | rec 187401 | rec 447926 | rec 681442 |
| **first `rstcs` increment** | **−0.095** | **−0.055** | **−0.053** |
| **first \|cfc\| > 20,000** | **−0.095** (same record) | **−0.000** | **−0.053** (same record) |
| last `crc_ok` | −0.012 | −0.000 | −0.000 |
| `t_mono` hole across the onset | 11.895 ms | 0.047 ms | 0.046 ms |
| RX board's own rotate (framelog rec 0) | −150.5 | −359.8 | −547.4 |
| RX board's own TX-feed gap at that rotate | 15.46 ms | 15.11 ms | 20.40 ms |
| **peer's nearest TX-feed gap ≥ 3 ms** | **+24.24** (64.20 ms) | **+24.17** (128.54 ms) | **+27.90** (193.05 ms) |
| peer's largest measured gap BEFORE the onset | **0.312 ms** (26 measured) | **0.008 ms** (40 measured) | **0.137 ms** (114 measured) |
| RX board's step-8 `SIGUSR1` | +23.7 | +23.6 | +27.4 |
| W1 reader sweep, nearest preceding | coincident, \|Δ\| ≤ 0.5 s | **−8.3 ± 0.5** | (no reader on this leg) |
| RSSI/gain read, nearest preceding | −6.1 (24.07 dB, gain 34.000) | −5.3 (24.21 dB, gain 34.000) | (none) |
| RSSI/gain read, nearest following | +2.8 (25.11 dB, **gain 33.000**) | +4.7 (25.14 dB, **gain 33.000**) | (none) |
| daemon "NO DELIVERY — re-arming" | ~+10, +20, +30 (3 in-leg) | ~+10, +20, +30 | ~+10, +20, +30 |
| capture_r3 `MID_CAPTURE_WEDGE` abort | wall 162 s of 464 | wall 371 s of 464 | wall 420 s (600-s leg) |
| post snap `rstcs` (`regs_post.txt`) | 0x4BB4 = **19,380** at +21.2 | 0x4C46 = **19,526** at +21.0 | — |

**Always first and by a clear margin: the RX board's own carrier loop.** Everything the harness or
the peer does is ≥ 5.3 s away (RSSI read) or ≥ 23.6 s away (any transmit-feed gap on either board).

### 1.1 The onset frame by frame [log]

t37_a, records 187,393–187,408 (0.803 ms/frame, batched pump so `dtmono` is ~0.05 ms within a batch):

```
rec 187396 t=142.5844 seq=212594 crc=1 rstcs=   38 cfc= 127559     <- cfc already excursing
rec 187400 t=142.5847 seq=212598 crc=1 rstcs=   39 cfc=  58897     <- LAST GOOD FRAME
rec 187401 t=142.5966 dtmono=11.895ms seq=4077313569 crc=0 fc=1 rstcs=54 cfc=-27143
rec 187402 t=142.5967 dtmono= 0.088ms seq=1686790092 crc=0 fc=1 rstcs=54 cfc=-27143
```

Two things separate this from the at-arm class, both with a number:

* **Post-onset class census: `fail_class` 1 (MAGIC garbage) = 39,722/39,722 (t37_a), 40,942/40,944
  (t37_b), 30,952/30,994 (183520). Class 4 (all-zero slice, "a slot the DMA never filled") = 0 in all
  three** [log]. Every at-arm event begins with 2–12 class-4 slices before the class-1 garbage
  (ATARM sec 1.1) because the far transmitter had genuinely gone silent. Here the transmitter never
  stopped, so there is no delivery hole — only garbage.
* **`cfc` is the leading indicator, and it is a step, not a ramp.** Over the 140 s before the onset
  t37_a's CFO estimate sits at −4,770 ± 600 with **zero** records outside ±20,000; within one record
  it reaches ±262,000 and 42–81 % of all records are outside ±20,000 for the rest of the leg [log].
  Per 2-s bin the transition is: 100 % `crc_ok`, 0 resets, 0 excursions in every bin of [−3.0, −0.2] s
  → 27–67 `crc_ok`, 112–344 resets, 32–103 excursions in the bin the onset falls in.

## 2. Q2 — the fabric receive chain was still delivering; the host was not stalled

Split with numbers, t37_a (the only leg whose W1 reader window extends past the onset):

| witness | healthy | during the storm |
|---|---|---|
| `0x104` packets_out (fabric deframer) [log reads/] | 1,196–1,327 /s | **458–504 /s** across the `i16→i18` census window; **309 /s** across `i18→i19` as the daemons die, 0 thereafter (sec 8) |
| framelog records written | 1,244 /s | 392–482 /s for 22 s, then 4,980 /s |
| `dma_rx_ok` (host, delivered payload frames) [log `cap/qpsk_tun.log` `stats:` lines, code qpsk_tun.c:256] | 1,238–1,251 /s | **frozen at 212,247 / 236,263** |
| `crc_drop` (host, classified-and-dropped slices) [same source] | ~2,000 per 5-s line | **18,282 → 20,362 → 21,402 → 33,578 → 57,314** |
| `magic_bad` / `orphan` / `short` (host byte-plane) [log chk.jsonl] | 11,576 / 7,461 / 99 | **21,266 / 454,842 / 708** (orphan ≈ 15,000 /s) |
| W1 `occTrue` ring occupancy | 22–23 on 14/14 readings | **0–1 on 5/5 pre-quiesce storm readings** (i15–i19), and on 22/22 counting the 17 post-quiesce ones |
| W1 `pop_on_empty` (16-bit, wrapping) | **54, unchanged for 134 s** | ≥ 39,305 in the first bin; wraps every reading thereafter (≈ 4,000 /s, lower bound) |
| W1 `r4d_extras` (R4D's FULL-side steered extra pops) | **≈ 38–42 /s on 14/14 healthy intervals** (382–424 counts on the thirteen 10-s ones, 362 over the 9-s i14→i15) | **frozen at 7,361 from reading i15 — delta exactly 0 on every interval thereafter** |
| W1 `push_on_full` | **0 — and it cannot be otherwise on this image** | **0 on 36/36, carrying no information** (sec 2.1) |

`dma_rx_ok` freezing is the *definition* of the "delivery flatline"; the four counters below it prove
the DMA kept completing and the host kept classifying. **This is not a host or DMA stall**: the RX
board's own txlog has no ≥ 3 ms gap between its rotate and its step-8 dump (232,817 / 493,499 /
731,775 submits), and the framelog's `t_mono` hole across the onset is 0.05–11.9 ms. It is also not
the queued-RX watchdog: it fires 3 times in-leg, and its re-arm path `rx_arm_queued()` writes only
AXI-DMAC registers — no `modem_regs` write anywhere in it or in the `rx_q_submit()` it calls [code
qpsk_tun.c:1845-1875 and :1808-1840] — and does not clear the storm. (The `:1625-1660` cited here
before spans `rx_arm_cyclic()` and `fslog_note()`, and `fslog_note` **does** write
`modem_regs[0x1DC/4]`; it is not the watchdog path.)

**Per-stage census** (`W1_CNT_*`, all clocked on `enb_1_2_0`; rates from cumulative counters divided by
the actual reading-timestamp difference, which is ±1 s quantised → ±0.8 % over the 121-s healthy
baseline and ±5.0 % over the 20-s storm window) [log]:

| window | cSS | cRH | cCFC | cCS | cPD | cPC |
|---|---|---|---|---|---|---|
| t37_a healthy, i2→i14 (121 s) | 15.319 M/s | 15.319 | 15.319 | 15.319 | 15.319 | 15.298 |
| t37_a storm, **i16→i18** (20 s) | **12.432 M/s** | 12.432 | 12.432 | 12.432 | 12.432 | **5.385** |
| ratio | **0.812** | 0.812 | 0.812 | 0.812 | 0.812 | **0.352** |

**The storm window is `i16→i18`, not the `i16→i19` an earlier revision used.** The harness quiesce
kills both daemons at CAP+171.4 s — 11.5 s inside `i19` — so `i16→i19` violates this document's own
sec 8 rule and dilutes both ratios: it gives 0.794 and **0.311**, the `cPC` row worst, because `cPC`'s
post-quiesce rate is exactly 0. Sec 8 carries the two witnesses for the daemon death and the residual
contamination of `i16→i18` itself.

The healthy row reproduces W1_REGMAP sec 3 exactly (15.319 vs the 15.360 M/s nominal symbol rate;
`cPC` short by 0.14 %, predicted 0.105 % for the 13-symbol guard). In the storm **every stage from the
symbol synchroniser's push request onward is short by the same 18.8 %**, and the deframer output is
short by a further 57 %. Because the shortfall is already present at the FIRST stage of the census,
the census cannot locate a *deleting* stage inside the chain: whatever is wrong is **at or upstream of
`Symbol_Synchronizer`** [log+inferred] — which is where RXFIX_STATE.md's own localisation had already
arrived from a different direction [silicon]. A Rate_Handle symbol deletion is **not** excluded by
`push_on_full` here — see sec 2.1, which retires that counter on this image and rebuilds the
exclusion on the ring occupancy and on R4D's own FULL-side witness.

Two caveats stated: (i) `cPD` is a per-sample valid strobe, not a preamble-detection event, so
"cPD still counting" means samples are flowing, **not** that the demod is locked; (ii) `W1_CNT_PC` is
sampled **after** `sample_discard_controller`, so `cPC` at 0.352 of its healthy rate does not separate a
Packet_Controller failure from a discard-controller storm. t37_b's reader window closed 2.2 s after
its onset (36 readings, `read_window_s=360`), so it contributes one post-onset reading only:
`occ = 1`, `pop_on_empty` 24 → 41,622, `push_on_full = 0`, `rstcs = 2,557`.

### 2.1 `push_on_full` is retired on this image; the FULL-edge exclusion is rebuilt on the occupancy

**The counter has no positive control on `9acbe2ebe1db`, the image TWO of the three collapses ran on (the third, 183520, ran on `6b4744ca73f8` — §4's roster), and
cannot have one.** Archive-wide audit of every `w1_reads.csv` in the tree: 53 files, of which 22 are
byte-identical top-level copies of a run's own `reads/` CSV (checked, 22/22), leaving **31 distinct
read-sets and 890 distinct readings** [log]:

| image | reader read | read-sets | readings | `occTrue` | `push_on_full` |
|---|---|---|---|---|---|
| `2728dab3979a` (W1 only) | 146 | 1 (`105153_w1_t19_witness`) | 48 | **31–32** | **non-zero on 48/48, max 20,331** |
| (W1 only, `rxfix/runs/t19_w1probe_146`) | 146 | 1 | 3 | **32** | **non-zero on 3/3, max 11,573** |
| **`9acbe2ebe1db` (W1+R4D+R1)** | **146** | **12 legs** | **456** | 22–24 healthy, 0–1 collapsed | **0 on 456/456** |
| `9f13705d9fb0` (W1+R4B) | 148 | 8 air legs | 310 | 8–10 healthy, 0–1 collapsed | **0 on 310/310** |
| remainder (`2728dab3979a` on 148; the four `w1_ctrl` pre/post triples; `atrest_164541`; `t22_step2_146`) | 148 / 146 | 9 | 73 | 0–1, 8–9, 22–23 | **0 on 73/73** |

(48 + 3 + 456 + 310 + 73 = 890.) Across all 890 distinct readings the association is exact: **`push_on_full` is
non-zero on 51/51 readings with `occTrue ≥ 31` and on 0/839 readings with `occTrue ≤ 24`** [log]. So
the counter is demonstrably *wired* — it fires, hard, whenever the ring actually reaches FULL — and
its zero on `9acbe2ebe1db` is a statement about the occupancy, not about the instrument.

**The RTL says why, and forecloses the obvious objection.** In the tree that built `9acbe2ebe1db`:

```verilog
assign Constant_out1          = 6'b100000;             // Compare_To_Constant1_block.v:36
assign Logical_Operator5_out1 = push & Logical_Operator8_out1;               // :153  = push & ~valid_pop (:151, :163)
assign push_on_full_FIFO      = Logical_Operator5_out1 & Compare_To_Constant1_y;  // :155  -> fires iff occ == 32
assign w1Occ                  = Delay_out1;   // RXFIX_W1                    // :167
```

[code `TxRxCompo_ip_src_Validate_Input_Push_Pop_block.v`, `..._Compare_To_Constant1_block.v`]. The
counter fires **only at occupancy exactly 32**, and `Delay_out1` is the *same register* that leaves
the block as `w1Occ` — the occupancy this document reads and the predicate that fires the counter are
one flop, so "the occupancy tap might be misreading" is not an available objection. R4D then holds
that flop off 32 by construction: `r4d_occ_ge24 <= (r4d_occ >= 6'b011000)` (`Rate_Handle.v:234`) arms
an **extra pop** (`:280-281`) whenever occupancy reaches 24, ratcheting it back. That is exactly what
W1_REGMAP predicts and what the archive shows: `occTrue` reads 22–24 on every healthy reading of 10 of
the image's 12 legs, and the other two (`152645_w1_t29_judge3`, `091332_w1_t36_dpoff`) read 0–1 on
every reading. W1_REGMAP sec 6-R4D.3 imports sec 6-R4E.3's expectations for R4D
images explicitly ("judges occupancy against the R4D band 22–24"), and sec 6-R4E.3 states the
consequence: "`W1_PUF` (`push_on_full`) after arm should be 0 … that is the **success** case, not a
dead counter … `W1_PUF` is therefore **no longer a liveness control on that direction**" [code].
(Sec 6-R4E.3 sits under the R4E heading and W1_REGMAP records that **no R4E image was ever built**;
sec 6-R4D.3's import is what makes that sentence apply to `9acbe2ebe1db`.)

**So `push_on_full = 0` on 36/36 is neither "no deletions occurred" nor "the counter is dead": it is
the arithmetic of a ring R4D parks at 22–23 and the collapse drives to 0–1.** This is the same
epistemic position sec 8 already retires `reg_adcforensic` into, and it is treated the same way.

**What does exclude a FULL-edge Rate_Handle deletion here, and what does not** [log+code]:

* **No sustained FULL-edge condition.** `occTrue` is 22–23 on 14/14 healthy readings and 0–1 on 22/22
  post-onset ones (5/5 of them pre-quiesce) — never within 9 of the `== 32` the RTL requires.
* **The FULL-side steering is witnessed engaging, then witnessed idle.** `r4d_extras` runs at
  38–42 /s all through the healthy window — occupancy reaching 24 and being ratcheted back ~40 times
  a second — and its delta is **exactly 0** from `i15` on (frozen at 7,361 for readings 15…36). Over
  `i15→i19`, the whole storm span the reader covers before the fabric freezes, the deframer opened
  **12,705** R4D guard windows (per-interval `r4d_opens` deltas 3,407 / 3,656 / 3,376 / 2,266; 7,032
  of them inside the `i16→i18` census window) and **not one** of them saw `occ ≥ 24`. Both fields are
  decoded through the `9acbe2ebe1db` word swap of W1_REGMAP sec 6-R4D.2 — the reader stamped
  `r4d_order=swapped` on all 36 readings and the fail-closed check `r4d_hi = 0` passes 36/36 [log].
* **The EMPTY edge is positively witnessed in the same readings.** `pop_on_empty_FIFO` requires
  `Delay_out1 == 6'b000000` exactly (`Validate_Input_Push_Pop_block.v:145` +
  `Compare_To_Constant_block.v:36`)
  and it storms — so the ring really is sitting on the edge *opposite* the one `push_on_full` watches.
* **NOT excluded: a transient FULL-edge excursion inside the payload body.** R4D's window is 13
  nominal pop slots after each `pcEnd` (≈ 0.1 % of slots), so `r4d_extras` does not see the other
  99.9 %, and each `occTrue` is one frozen snapshot at a 10-s cadence. The only instrument with
  continuous coverage of a transient push-on-full is `push_on_full` itself, which R4D has disabled by
  construction on this image. **Closing that needs a different image or a new witness, and this
  document does not close it.**

**Downstream.** Every claim in this document that leaned on `push_on_full` has been restated: sec 0's
ranked-mechanism paragraph, sec 2's witness table and prose, sec 5.0's table (both rows — see there
for why the two rows do **not** get the same treatment), sec 5.1, sec 6's exclusion bullet, sec 7's
premise and sec 8's wrapping-counter note.

## 3. Q3 — nothing periodic or scheduled fires at the onsets

| candidate | evidence | verdict |
|---|---|---|
| W1 reader sweep (10 s; each reading **writes** `0x208 = FIXCTL_BASE\|0x10` then `FIXCTL_BASE`, a write-only whole-word register [code W1_REGMAP sec 2]) | **3 of the 5 events are on legs with no reader at all** (175236, 183520, 064400 have no `reads/`, no `w1_reads.csv`, no `reader.log`). On the two that have one, t37_a's onset is −0.1 ± 0.5 s from a sweep and **t37_b's is −8.3 ± 0.5 s**, i.e. mid-interval. Rate with a reader = 2 events / 5,482 s = 1.31/h; without = 3 / 2,990 s = **3.61/h** | not necessary, not associated with a higher rate — **out** |
| RSSI / seqbist reads (same 10-s reader loop, sequential) | onsets are −6.1 s and −5.3 s from the nearest RSSI read | out |
| daemon 5-s `stats:` lines and its `txgap`/`rxresync` dumps | `stats_dump()` touches no board register and opens no session [code qpsk_tun.c:248-281]; onsets mod 5 s = 2.60, 1.79, 4.52 — no grid | out |
| capture_r3 stall-watchdog poll (one ssh per ~5 s, reads `/dev/shm/qpsk_tun.log`) | no register access [code capture_r3.sh:336-368]; ATARM sec 3 already showed an ssh session alone collapses nothing | out |
| daemon `SIGUSR2` rotate / step-8 `SIGUSR1` | rotate is −150.5/−359.8/−547.4 s; SIGUSR1 is +23.6/+23.7/+27.4 s | out |
| a fixed onset time (a harness deadline) | `PERF_T = DUR + 400` on the 09-06 legs [code :164] = 880 s, 400 s past the end of a 480-s window; the three onsets are 142.6 / 351.8 / 539.5 s, not one value | out |
| the DisplayPort / 20.38 ms comb | both t37 legs ran `dp_quiet=1`, `connector=disconnected`, `crtc_active=0`, `dpdma_irq_rate=0` [log dp_state.txt] | out |

## 4. Q4 — the onset distribution is a constant hazard, not a threshold

**Roster.** The class marker is the first mid-window `|cfc| > 20,000` excursion (≥ 5 records in a 2-s
bin) more than 2 s away from the leg's step-8 `SIGUSR1`. Run over every archived leg with ≥ 50,000
framelog records (57 legs), it fires **within ±2 s of the leg's step-8 `SIGUSR1` in 42 legs** (the known ATARM sec 4.2
class — the marker's positive control) and **mid-window in exactly five**:

| leg | RX board | image | onset (CAP-rel) | `crc_ok` before → after | `rstcs` rate after | outcome |
|---|---|---|---|---|---|---|
| 20260903_175236_legB_m16r2 | 146 | 6b4744ca73f8 | +380 s | 96.26 % → 95.88 % | 4 /s | **PARTIAL** |
| 20260903_183520_legB_m8rx | 146 | 6b4744ca73f8 | +538 s | 96.50 % → 0.00 % | 824 /s | **COLLAPSE** |
| 20260905_064400_legB_rev_before2 | 146 | 3378861d30bd | +184 s | 95.89 % → 88.80 % | 7 /s | **PARTIAL** |
| 20260906_100227_w1_t37_a | 146 | 9acbe2ebe1db | +142.5 s | 99.92 % → 0.00 % | 884 /s | **COLLAPSE** |
| 20260906_102454_w1_t37_b | 146 | 9acbe2ebe1db | +351.7 s | 99.90 % → 0.00 % | 896 /s | **COLLAPSE** |

The two PARTIALs are the same signature at a sub-collapse dose: 064400's CFO estimator starts
excursing at +184 s, the PER steps from 3.8 % to 11.4 % **permanently** for the remaining 550 s, and
`rstcs` climbs at 2–7/s to 1,162 by the pull — the leg then ran to the `-t 740` deadline and was
scored a deadline artefact [log, WEDGE_TIMER_AUDIT sec 1.2]. This is the event the brief called
"~189 s, rstcs 0 → 1,154" on 064400: **it is real, it is the same family, and it is not a collapse** —
the receiver kept delivering ~1,100 f/s. The third collapse in the class is 183520, not 064400.

**Two legs are explicitly NOT in the class**, with the number that excludes them:
* `20260903_180810_legB_m8` — decode stops at +513.1 s with **`rstcs` flat at 0** and `0x104` falling
  to **37.7/s**; its `rstcs` storm at +535.3 s is 0.3 s from 148's `SIGUSR1` (175.05 ms), i.e. the
  ATARM sec 4.2 dose. A mid-window *delivery* failure with no carrier-loop event: a different class.
* every `MID_CAPTURE_WEDGE after 5xx s` row of the 600-s legs — 10 of them have **no `rstcs`
  increment anywhere in the leg** [log], which is the deadline artefact's signature.

**Exposure.** Per leg, the at-risk interval is `[20 s, min(step-8 SIGUSR1, framelog end, onset))`;
legs whose RX was already collapsed at t = 20 s (174902, t38_ctl_01) are dropped. 55 legs qualify:

| stratum | exposure | collapses | partials |
|---|---|---|---|
| RX = 146, no reader | 2,990 s | 1 | 2 |
| RX = 146, reader on | 5,482 s | 2 | 0 |
| RX = 148, no reader | 5,121 s | 0 | 0 |
| RX = 148, reader on | 3,556 s | 0 | 0 |
| **total** | **17,150 s (4.76 h)** | **3** | **2** |

(146 total 8,472 s; 148 total 8,677 s. These are censored at each leg's FIRST event of either
kind; the collapse-hazard denominator below re-opens the two PARTIAL legs, giving 146 = 9,377 s.)

* Collapse hazard, 146 as receiver. The right denominator censors a leg at its **collapse** only:
  a PARTIAL leg kept delivering and stayed at risk (175236 for a further 352 s, 064400 for 554 s), so
  those seconds belong in it. 146 collapse exposure = **9,377 s**, 3 collapses = **1.152 /h**
  (Poisson 95 % CI 0.24–3.37 /h), mean time-to-collapse 3,126 s, **p = 0.137 per 460-s leg**.
* Any-event hazard (first event of either kind), which *does* censor at the partial: 5 / 8,472 s =
  **2.125 /h**, **p = 0.238** per 460-s leg — the "≈ 3 legs in 10" of the brief.
* **Board asymmetry** (any-event denominators, first-event censored): 146 = 8,472 s, 148 = 8,677 s
  (49.4 % / 50.6 %), all 5 events on 146 → P(all 5 on 146 | equal hazard) = 0.494⁵ = **0.029**. On the
  collapse denominators (9,377 s vs 8,677 s) the 3 collapses alone give 0.519³ = 0.140. The two
  comparisons deliberately use different denominators; neither is a re-use of the other.
  Not an image effect: three different 146 images, and 146-RX legs on the same images ran clean.

**Constant hazard vs accumulator.** On the 146-only cumulative-exposure scale the three collapses sit
at u = **0.222, 0.579, 0.845** (mean 0.549 vs 0.5 expected under a constant hazard); per 100-s band
from t = 20 s the 146 exposure is 1,700 / 1,622 / 1,600 / 1,532 / 1,297 / 826 / 700 s with
0 / 1 / 0 / 1 / 0 / 1 / 0 events. With n = 3 this has no power to reject anything, but there is no clustering and no rising
trend. The decisive evidence against a threshold is the **natural experiment already on disk**:
`t37_a` collapsed at 142.5 s and its identical-configuration rerun 10 minutes later (`t37_a2`) ran the
full 460 s clean; `t37_b` collapsed at 351.7 s and `t37_b2` ran clean. Five 146-RX 480-s legs
(163044, 092251, 101204, 103512, 140355 — the last four all on the same `9acbe2ebe1db` image as the
two collapses) completed their windows with zero mid-window excursions. A deterministic accumulator that resets at bring-up would have re-fired at the
same time; a per-arm random draw would not [log+inferred].

## 5. Ranked mechanism

### 5.0 What the census settles, and what it does not [log]

| leg | receiver | image | trigger | `cSS` storm / healthy | `cPC` / healthy | ring |
|---|---|---|---|---|---|---|
| t37_a | 146 | 9acbe2ebe1db | **mid-window (unknown)** | **0.812** (i16→i18; i16→i17 lies entirely between the onset and the host daemon's death and gives 0.850, so the pair is 0.812/0.850, not a single value — i16→i18 runs ~1.45 s past the last framelog record, which is stated in §8 and is immaterial to the ratio) | **0.352** (i16→i18) | occ 22–23 → 0–1, `pop_on_empty` storming, `r4d_extras` frozen; `push_on_full` 0 **but structurally unable to fire — R4D holds the ring off 32 (sec 2.1)** |
| 161957 | 148 | 9f13705d9fb0 | **step-8 `SIGUSR1`, 34.3 ms peer TX silence** | 0.776 (i13→i14) / 0.799 (i12→i14) — **no quiesce-free window exists on this leg** | 0.196 / 0.419 | occ 8–10 → 0–1, `pop_on_empty` 44 → 47,292 then wrapping; `push_on_full` 0 — on an **R4B-only** image, where W1_REGMAP sec 5.2 says the counter is unchanged in meaning, so it is meaningful *in principle* but **uncontrolled**: 0 on 310/310 readings across all 8 legs on this image, with no non-zero reading anywhere on it |

161957 is the only archived leg whose W1 reader window straddles a step-8 collapse (18 readings,
`SIGUSR1` at +117.3 s, onset +119.2 s); its reader read **148**, so this is a cross-board comparison
and 148's storm rate (170–300 /s) differs from 146's, which ATARM_CLASS.md gives as **790–930 /s**
(`:283`) and **800–940 /s** (`:765`) over two different fit windows — quoted separately because
neither source says "790–940" [log].

**Two further asymmetries, stated rather than smoothed.** (i) The two sides are not equally clean:
t37_a's window is re-cut to be quiesce-free (sec 2), while 161957 has **no** quiesce-free window —
`i13→i14` is its only fully-post-onset interval and it already carries its own wind-down (0x104 at
265 /s against 1,254 /s healthy, frozen by `i15`). (ii) The `push_on_full` cells of the two rows are
**not** the same observation (sec 2.1): on 146/`9acbe2ebe1db` the counter cannot fire, on
148/`9f13705d9fb0` it can but was never seen to. With those caveats: **a collapse whose trigger is
unambiguously a transmit-feed silence reaches the same latched state on every W1 witness that is
comparable across the two images.** Three consequences, all of which change the ranking:

* The 20 % symbol-strobe shortfall is a property of the **latched state**, not of the trigger. It
  localises the latch (at or upstream of `Symbol_Synchronizer`) but it does **not** discriminate
  between mechanisms, and in particular it is **not** evidence for an SSI fault, because the 161957
  instance has no SSI involvement whatsoever.
* Sec 7's premise — that an induced collapse reads the same latch — is verified on silicon rather
  than assumed.
* The parsimonious reading is that the receive chain has a single attractor that *any* sufficient
  disturbance drops it into, and that the mid-window class differs from the at-arm class only in the
  disturbance. That demotes the board-specific SSI hypothesis to a trigger hypothesis (5.3).

### 5.1 Rank 1 — [log+inferred] the latch is a trigger-independent false lock in the receive chain

First in time by 5.3 s (nearest harness event) and 23.6 s (nearest transmit-feed gap on either board);
`rstcs` and `cfc` move in the same record; decode dies 47–95 ms later; the storm runs at 824–896 /s
for as long as the leg lasts, through three DMAC-only re-arms, and is cleared only by the byte
double-tap or the next bring-up [log+code]. The fabric keeps running through it: `0x104` at
458–504 /s, all six W1 stages counting, and the ring pinned at the EMPTY edge (`occ` 0–1,
`pop_on_empty` storming, `r4d_extras` frozen — sec 2.1). Because the shortfall is already present
at the FIRST census stage, the census cannot name a deleting stage inside the chain — the state is at
or upstream of `Symbol_Synchronizer` (an interpolator NCO parked ~20 % slow is a wrong lock point)
[inferred]. This is the same "sync-but-CRC wedge" the bring-up already re-arms for [silicon,
capture_r3.sh:67-73], and sec 5.0 shows it is reached from at least two different directions.

### 5.2 Rank 2 — [log] the mid-window trigger: an ADRV9002 receive-path step of ~1 dB

`hardwaregain` reads **34.000 dB on 49/49 pre-onset readings** across the two legs that have RSSI
logging, and **33.000 dB in the reading that straddles the onset in 2/2**, with `rssi` +1.04/+0.93 dB
and `decpwr` +1.00 dB. This is the only actuator the archive offers for the mid-window class, and it
is genuinely unresolved:

* It is **not the latch**: in t37_a the gain is back at 34.000 dB by +22.8 s and stays there for the
  remaining 20 readings while the storm continues [log].
* Its **order** relative to the onset cannot be settled at a 10-s cadence. Sec 7's second
  instrumentation ask fixes that for no board time.
* Which of the two is primary is also open. `rssi` and `decpwr` are computed **inside** the
  ADRV9002; the AGC moving 1 dB is a loop *response*, so the more primitive observation is the 1 dB
  power step, and nothing in the archive says whether that step is in the air, in the analog front
  end, or an artefact of the gain change itself. A 1 dB step is an order of magnitude below any fade
  that would threaten a link running at 99.9 % `crc_ok`, so the fade exclusion of sec 6 stands — but
  "too small to be a fade" is not "explained".

### 5.3 Rank 3 — [inferred] a marginal, per-arm rx0 SSI delay row on 146 as the trigger

This is the only mechanism in the repo that predicts a **board-specific, per-arm, receive-side**
fragility, which is what the 5/5-on-146 asymmetry (p = 0.029) and the clean identical reruns look
like. `apply_146_ssi_fix.sh` records that "**the receive side re-runs auto-tune every arm while only
tx0 was ever pinned**" and that the 16-arm experiment showed rx0 is "left at whatever this boot's
auto-tune chose" [code]. The script's "the PRBS test can pick a **word-boundary-slip** clk row that
mission traffic cannot use" sentence is about **tx0** on 146 — it is the known precedent for a
marginal SSI row on this unit, and extending it to rx0 is **[inferred]**, not documented.

Two things weigh against it and are stated here rather than buried: (i) a delay row is a **static**
configuration written at profile load — it does not drift out of the eye 142 / 352 / 538 s into a leg
that ran at 99.9 % `crc_ok`, so 5.3 is incomplete without a trigger, and 5.2's gain step (a receive-path
reconfiguration, exactly the sort of event that can slip framing on a marginal row) is the only one
available; and (ii) sec 5.0 shows the identical latched state is reached with no SSI involvement at
all. 5.3 therefore survives as a **compound** hypothesis — marginal rx0 row **plus** the 5.2 trigger —
not as a standalone one, and sec 7 tests only its latch half.

### 5.4 Rank 4 — [silicon, cited] the same latch the at-arm class reaches

Sec 5.0 makes this a measurement rather than an analogy: `rstcs` 824–896 /s on 146 (sec 4's per-leg
slopes) against ATARM's own two 146 figures, 790–930 /s (`ATARM_CLASS.md:283`) and 800–940 /s
(`:765`); `0x104` at ~40 % of nominal; class-1 garbage; the same W1 ring and stage signature;
cleared only by the byte double-tap. The **trigger** is demonstrably different (sec 6): no starvation
anywhere in the pre-onset window, and no class-4 delivery hole at the onset (0 of 111,660 post-onset
records, against 2–12 in every at-arm event, ATARM sec 1.1).

## 6. Ruled out, with a number

* **Peer transmit-feed starvation (the ATARM mechanism)** — 0 gaps ≥ 3 ms on `txlog_peer.bin` before
  the onset in 3/3; largest measured pre-onset gap **0.312 / 0.008 / 0.137 ms** against a 7 ms
  threshold that is fatal 38/38 [log + ATARM sec 4.1]. Nearest peer gap +24.2/+24.2/+27.9 s after.
* **RX-side host or DMA stall** — RX board's own txlog: 0 gaps ≥ 3 ms in 232,817 / 493,499 / 731,775
  submits between its rotate and its step-8 dump; framelog `t_mono` hole 11.9 / 0.05 / 0.05 ms;
  `crc_drop` +39,032, `orphan` +447,381, `magic_bad` +9,690, `short` +609 while `dma_rx_ok` was frozen.
* **The queued-RX watchdog re-arm as a cause** — the watchdog check is `qpsk_tun.c:2051-2062` and its
  re-arm `rx_arm_queued()` (`:1845-1875`, with the `rx_q_submit()` at `:1808-1840`) writes **only**
  AXI-DMAC registers: no `modem_regs` write anywhere in either [code]. It fires at ~+10 s and 3 in-leg
  re-arms per leg fail to clear the storm in 3/3.
* **RF level / fade** — 146's `rssi` across the whole t37_a leg 23.879–25.590 dB (36 reads), t37_b
  23.923–25.144 dB (36 reads); last pre-onset sample 24.07 / 24.21 dB, first post 25.11 / 25.14 dB.
  These are the **first pre-collapse RSSI samples in the archive** (ATARM sec 6 had none). A *fade*
  is excluded; the +1.0 dB step at the onset is **not** excluded and is sec 5.2.
* **W1 reader / any harness cadence** — sec 3: 3 of 5 events on legs with no reader; t37_b's onset
  8.3 ± 0.5 s from the nearest sweep; counting all five events the 146 hazard is 2.8× *lower*
  with a reader (1.31/h on 5,482 s vs 3.61/h on 2,990 s).
* **The traffic deadline (WEDGE_TIMER_AUDIT)** — `PERF_T = DUR + 400` = 880 s on the 09-06 legs
  [code capture_r3.sh:164], 400 s past the end of a 480-s window; and the 10 archived long legs that
  ran to a deadline (or past it) carry **zero `rstcs` increments anywhere in the leg** [log], which is
  what the artefact looks like and is not what any of the five events looks like.
* **The 20.38 ms comb / DisplayPort** — both t37 legs ran with the DP connector disconnected,
  `crtc_active=0`, DPDMA IRQ rate 0 [log dp_state.txt], and 183520 predates the DP work entirely.
* **A sustained FULL-edge Rate_Handle symbol deletion** — excluded, but **not** on `push_on_full`,
  which cannot fire on `9acbe2ebe1db` (sec 2.1). On the ring occupancy the same flop drives:
  `occTrue` 22–23 healthy and 0–1 in the storm against the `== 32` the RTL requires, plus
  `r4d_extras` delta exactly 0 across the 12,705 R4D guard windows of `i15→i19` after running at
  38–42 /s all through the healthy window [log+code]. **NOT excluded:** a transient FULL-edge
  excursion inside the payload body — no live instrument on this image covers it (sec 2.1).
* **A deterministic accumulator / threshold** — sec 4: identical-configuration reruns 10 minutes later
  ran the full 460 s clean, 2/2, and five 146-RX 480-s legs completed clean.
* **NOT excluded — the direction/board confound.** LEG=B always means 146 receives *and* 148
  transmits the data; LEG=A the reverse. So "146 as receiver" is inseparable in this archive from
  "148 as the data transmitter" and from the reverse RF path. Nothing here rules out a 148
  transmit-side origin except that 148's own transmit feed is clean (sec 1.0) and ATARM's dose data
  already show 146's receiver is the fragile end. Sec 7's test interrogates the latch on 146's
  receiver and does not depend on which end originated the event, so it is unaffected by this.
* **NOT excluded — the Tap-A capture as an early marker.** `pair.iq` is `DEGENERATE` in t37_a
  (occupied BW 3.84 MHz, envelope autocorrelation 0.9990 at lag 256 = the #48 stale-DDR-replay
  signature) at CAP_START, 142.5 s **before** the onset — but it is equally degenerate (BW 3.84 MHz,
  autocorrelation 0.9986–0.9991 at lag 256) in the three clean reruns t37_a2, t37_b2 and t36_dpoff2,
  so it is the known-broken rx2 tap and carries no information about this class [log].

## 7. The one rig test — the recovery ladder on a collapsed 146 receiver

**Question.** Is the trigger-independent latch of sec 5.1 in the **modem fabric** (sec 5.1) or in the
146 **RX SSI deserialiser** (sec 5.3's latch half)?

**Why this and not an A/B on the trigger.** The mid-window collapse is rare — p = 0.137 per 460-s leg,
on sec 4's corrected roster of **3 collapses and 2 partials** (the ~189 s event on 064400 is a PARTIAL,
not a collapse, and the third collapse is 183520) — so
a trigger A/B needs ~20 legs per arm ≈ 8.6 h of rig time. The *latch* can be interrogated on a
collapse that is **free and deterministic**: a `SIGUSR1` to the peer's daemon stalls its transmit feed
and collapses the far receiver in 38/38 observed doses ≥ 7 ms [log, ATARM sec 4.1 + 4.2], and this
audit's own marker scan finds that collapse at step 8 in **42 of the 52 legs that reach it** — the
other 10 are legs whose framelog ends at or before their own `SIGUSR1` flush, i.e. unobserved rather
than absent (ATARM sec 10's observability note; measured here as framelog end minus `SIGUSR1`
= −30.1…+0.1 s in 10/10).

**The premise is verified, not assumed.** Sec 5.0 measures the W1 census across an induced step-8
collapse (161957) and across a mid-window one (t37_a) and finds the same latched state:
`cSS` 0.776 (161957's only fully-post-onset window, `i13→i14`; 0.799 over `i12→i14`, which straddles
its onset) vs **0.812** (t37_a, `i16→i18`); `cPC` short by a further **75 %** (161957, `i13→i14`) vs
**57 %** (t37_a) — the 48 % that `i12→i14` gives is not the collapsed state, it is diluted by the
pre-onset traffic inside that window; `occ` 0–1,
`pop_on_empty` storming. Three caveats, none of them softened: 161957's reader read **148**, so the
comparison is cross-board; **161957 has no quiesce-free census window** (sec 8) while t37_a's is now
re-cut to one, so the two sides are not equally clean; and `push_on_full` is **not** part of the
comparison, because it cannot fire on t37_a's image (sec 2.1).

**Procedure.** Standard r3 bring-up, `LEG=B` (146 RX), no `RX_ATTR_POKE`/`PEER_ATTR_POKE`/`LOOP_POKE`,
DP disconnected, `DUR=120`. At t ≈ 100 s send `SIGUSR1` to the 148 daemon — at that ring depth the
archive's scaling (161957: 34.3/35.7 ms at 125 s) predicts a ~30 ms dose, 4× the threshold. Read the
delivered dose back from `txlog_peer.bin` record 0's `gap_ns` afterwards; **a trial whose dose comes
out < 7 ms and whose receiver survives is a dose point, not a failed test** — repeat it later in the
window. Confirm the collapse (`rstcs` slope ≥ 500 /s over 3 s **and** `deliver_rate` = 0). Then,
**on 146 only**, run the rungs in
this fixed order, reading `deliver_rate`, a 3-s `0x150` slope **and one `w1_read.sh BOARD=146 N=1`
sweep** (~2 s, `FIXCTL_BASE=0x0`) after each, plus one sweep immediately after the collapse is
confirmed. The sweep costs ~10 s per trial and makes the test self-diagnosing: if the induced collapse's `cSS` ratio comes out ≈ 1.00 instead of
0.78–0.81, the induced state is **not** this latch and the trial must be discarded rather than
scored.

| rung | action | touches |
|---|---|---|
| **S0** | wait 5 s, no writes at all | nothing (null control) |
| **S1** | `apply_146_ssi_fix.sh` protocol (a)–(e) with the **live values written back verbatim**, `echo 1 > ssi_delays` — **stopping before its `0x000` pulse** | ADRV9002 SSI delays only |
| **S2** | same, with rx0 clk row ±1, then restored | ADRV9002 SSI delays only |
| **S3** | `rearm_byte 146` (`0x000` pulse, `0x158/0x118/0x114`, tx-lpc `0x418/0x458/0x044`, `0x110`) | modem regfile |

**Pre-registered predictions.** 4 trials.
* **SSI latch (sec 5.3):** S1 **or** S2 restores ≥ 900 f/s, `rstcs` slope → 0 and `cSS` → nominal
  in **≥ 3 of 4**.
* **Fabric latch (sec 5.1):** S1 and S2 leave delivery at 0 f/s with `rstcs` at 800–950 /s and `cSS`
  at 0.78–0.81 × nominal in **4 of 4**, and S3 restores all three in ≥ 3 of 4.
* **S0 fails 4/4** under both (the archive shows the storm runs unaided for ≥ 28.9 s, 3/3).

**Falsifiers.** (i) If S0 recovers in ≥ 1 of 4, there is no latch and the whole framing is wrong.
(ii) If S3 also fails in ≥ 2 of 4 — only a full bring-up clears it — both 5.1 and 5.3 are wrong and the
latch is in the ADRV9002 profile/state machine, not in the SSI delays or the modem regfile.
(iii) If S1 fails but S2 succeeds in ≥ 3 of 4, the latch is in the SSI but re-writing identical delay
values does not re-initialise the deserialiser — a known risk of this design (`echo 1 > ssi_delays`
applies the cached struct; whether it re-runs alignment is not established in the repo), and S2 is
then the operative rung.

**Cost.** 4 trials × (bring-up ~3 min + 120-s window + induce + ladder ~2 min + gate 12 s) ≈
**36 board-minutes**. No flash, no image change, no new instrumentation.

**Two zero-cost instrumentation asks to fold into the next 146-RX leg** (they change no receiver
state and cost no extra board time): (i) drop the 146 `rssi`/`gain`/`decpwr` read cadence from 10 s to
1 s, so the next natural event orders sec 5.2's gain step against a 1-ms onset; (ii) raise
`read_window_s` from 360 s to the full window — t37_b's W1 reader closed 2.2 s after its onset and
cost the class its second stage census.

## 8. Method notes / caveats

* Onset detector: first record of a run of ≥ 20 consecutive `crc_ok == 0`, cross-checked against the
  ATARM sec 1 detector (≥ 200 good records, then < 5 `crc_ok` in the next 50) — they agree to within
  1–4 records on all three legs.
* Class marker (sec 4): first 2-s bin with ≥ 5 records at `|cfc| > 20,000`. Over 57 legs it
  partitions cleanly: **42 fire within ±2 s of that leg's step-8 `SIGUSR1`** (offsets −0.3…+1.9 s —
  the known ATARM sec 4.2 class, and this marker's positive control), **10 never fire**, and
  **5 fire mid-window** (sec 4's roster). There is no intermediate case. The 10 that never fire are
  not counter-examples to the step-8 class: their framelogs end −30.1…+0.1 s relative to their own
  `SIGUSR1` (10/10), so the stall is outside the witness, exactly as ATARM sec 10 warns.
* `gap_ns` is a lower-bound estimate and exists only when the TX queue drained: `txgap_last_ns` is
  reset to `QPSK_GAP_NONE` on every call and only filled when `inflight_after_reap == 0` [code
  qpsk_tun.c:804 and `txgap_note()` at :830], and it reaches the record only for the first frame of a
  transfer (`r->gap_ns = i == 0 ? txgap_last_ns : QPSK_GAP_NONE`, :965). (The `:621-645` this document
  cited before is the framelog rotate / deferred-close path and has nothing to do with `gap_ns`; the
  claim was right, the citation was not.) So "no gap ≥ 3 ms" means "no measurable silence ≥ 3 ms"
  **over the 29 / 46 / 116 peer submits that carry a measurement at all, out of 233,383 / 494,066 /
  732,361 — 0.0124 / 0.0093 / 0.0158 % coverage** [log]. The word "zero" in sec 0 and sec 6 is bounded
  by that coverage. It is the same instrument ATARM's 0/35 and 38/38 are scored on.
* `pop_on_empty` and `push_on_full` are 16-bit **wrapping** counters [code W1_REGMAP sec 1]; every
  rate derived from `pop_on_empty` in sec 2 is a lower bound. `push_on_full = 0` is exact — a wrap
  would have to land on 0 in all 36 readings — but **exactness was never the question**: on
  `9acbe2ebe1db` the counter cannot fire at all (sec 2.1), so its reading is a fact about R4D's
  operating point and not about Rate_Handle. It is retired as evidence here, alongside
  `reg_adcforensic` below.
* W1 census rates are cumulative-counter differences divided by `date`-truncated timestamps: ±0.8 %
  over the 121-s healthy baseline and **±5.0 % over the 20-s `i16→i18` storm window** (it was ±3.3 %
  on the 30-s window this document used before the re-cut). The 18.8 % shortfall is 3.8× that error
  bar. All 36 readings report `freeze_effective: true`.
* `frames_peer.bin` is **not** a usable far-side witness on any of these legs: 148's receiver was
  already in a storm at record 0 (`rstcs` 666 / 698, 0 % `crc_ok` for the whole window), i.e.
  PRE-COLLAPSED under ATARM sec 9.2's rule. The mid-window instant is UNKNOWN on that board.
* `reg_adcforensic` (0x15C) reads 0x00000000 on every record of every 146 leg, before and during the
  storm — it carries no information on this image.
* The registers freezing at t ≈ +181 s in t37_a (`0x104` at 250,208, `rstcs` at 33,135) are the
  harness **quiesce** killing both daemons after the pulls, not a fabric latch. Any census window must
  end before it — and **the `i16→i19` window an earlier revision of sec 2 used did not.** Two
  independent witnesses put the daemon death inside it: (a) `frames.bin`'s last record is at
  **CAP+171.446 s** (`reg_packets` 246,425, `reg_rstcs` 25,971), 11.5 s before `i19` closes; and
  (b) the reader's own aux series winds down inside the last interval — `0x104` at 473.6 / 504.4 /
  458.0 /s over `i15→i16` / `i16→i17` / `i17→i18`, then **308.9 /s** over `i18→i19` and **0.0 /s**
  from `i19→i20`, with `0x104` frozen at 250,208 and `0x150` at 33,135 for `i20`…`i36` [log]. The
  census window is therefore **`i16→i18`** (CAP+152.7…+172.9 s) throughout this document, and the
  re-cut also repairs the `458–504 /s` range quote, which had silently dropped the 308.9 /s interval
  the old index span included. **Residual, stated:** `i18` lands ≈ 1.5 s past the host's last framelog
  record. That does not contaminate the census — `cSS`…`cPC` count fabric strobes on `enb_1_2_0`, not
  host deliveries, and the daemon's death reaches them only as deframer-output backpressure on
  `0x104`, which shows no wind-down signature inside `i17→i18` (458 /s against 504 and 474 /s). The
  per-reading censuses that span the whole file (`occ` 0–1 on 22/22, `pop_on_empty` wrapping every
  reading) include the 17 post-quiesce readings; the pre-quiesce counts are `occ` 0–1 on 5/5.
* **The other side of the sec 5.0 comparison has no clean window at all.** 161957's `i13→i14` is its
  only fully-post-onset interval and it is already winding down (`0x104` at 265 /s against 1,254 /s
  healthy, and frozen by `i15`), while `i12→i14` straddles the onset. So sec 5.0 compares a
  quiesce-free 146 measurement against a wind-down-contaminated 148 one. That **sharpens** the
  cross-board caveat; it does not remove it, and nothing here should be read as if it did.
* The `rstcs` storm slope is fit-window sensitive, and no single pair of bounds survives across legs:
  sec 4's roster gives **824 / 884 / 896 /s** (183520 / t37_a / t37_b), while one fixed window,
  onset+1…+11 s, gives **835 / 901 / 912 /s** [log]. The "824–904 /s" this document quoted in sec 0,
  sec 5.1 and sec 5.4 matched no stated window and was a merge across two; the roster's own range
  (824–896 /s) is used instead. ATARM's 146 figure is quoted the same way, as its two separate
  numbers (790–930 /s at `ATARM_CLASS.md:283`, 800–940 /s at `:765`) rather than the merged
  "790–940 /s" that appeared here before.
* Exposure definitions (sec 4) — two, deliberately: the **any-event** denominator censors each leg
  at its first event of either kind (146 = 8,472 s) and is what the 5-vs-0 board comparison uses; the
  **collapse** denominator censors only at a collapse, because a PARTIAL leg kept delivering and
  stayed at risk (146 = 9,377 s), and is what the 1.152 /h hazard and the u values use. Mixing them
  would inflate the hazard to 1.275 /h; that number does not appear in this document.
* The sec 5.0 comparison is cross-board (161957's reader read **148**, image `9f13705d9fb0`; the
  mid-window census is 146, image `9acbe2ebe1db`). It is the only step-8 collapse in the archive that
  a W1 reader window covers: the other five reader legs are 600-s legs whose 51-reading window
  (510 s) ends 200 s before their `SIGUSR1`.
* Scripts (session scratchpad; all read only archived run dirs, no board access): `mwlib.py`
  (record readers + onset detector), `scan.py`, `rstcs.py`, `cfcscan.py` (sec 4 roster), `fine.py` /
  `fine2.py` (sec 1), `txscan.py` (sec 1/6), `clockjoin.py` + `census.py` / `census2.py` (sec 2),
  `chkrssi.py` (sec 2/6), `census2.py` (sec 5.0), `exposure.py` / `hz2.py` / `hz3.py` (sec 4).
* Nothing was applied: no source file, no harness script, no board, no rig unit.
