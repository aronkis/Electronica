# FILLER-ADJACENCY desk test — does host TX starvation make the loss?

**VERDICT: CONTRADICTS** — for the *host-submit-gap-mediated* route the hypothesis
operationalises. The host TX queue runs dry on **1.5e-4 … 3.5e-4** of submits
(132 / 907,508 on the credited forward leg) and produces **1–5 dry periods
longer than one air frame per 600 s leg**, against **71,090** lost slots on that
same leg. The lost-vs-dry association is real but tiny — odds ratio **1.9–3.8**,
attributable fraction **≤ 0.08 %** of losses — and that is measured against a
deliberately over-broad exposure; the hypothesis's own criterion (dry ≥ one air
frame) is met **1–5 times per 600 s leg**, i.e. ~70,000× too rare on the forward
leg, with too few events to test at all. The host cadence *does* carry a
strong 25.69 ms line on 3 of 6 legs (autocorr **0.63–0.70** at lag 32, null p95
0.004) — but the RX loss comb at that same lag is present on **all six** legs,
including the three whose host cadence has **no** line at all (m8rx: cadence
lag-32 = −0.000, RX singles lag-32 = **0.689**). The comb is therefore **not**
host-cadence-made. Forward/reverse goes the wrong way too: the reverse leg has
**more** host starvation and **half** the PER.

Everything below is **[silicon]** (captured dumps from flashed boards) unless
labelled **[inferred]**. No board was touched for this analysis.

---

## Exact commands

```sh
cd /mnt/onetb/scratch/qpsk-jupiter-modem
python3 two_jup/comb/filler_adjacency.py \
    two_jup/comb/runs/20260903_191410_legA_a1r2 \
    two_jup/comb/runs/20260904_005624_legA_whiten \
    two_jup/comb/runs/20260903_175236_legB_m16r2 \
    two_jup/comb/runs/20260903_183520_legB_m8rx \
    two_jup/comb/runs/20260903_182006_legB_m8r2 \
    two_jup/comb/runs/20260903_184803_legB_m8rxr2 \
    --json /tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/785fd3d6-90df-49f2-afd7-023e28044472/scratchpad/filler_all.json
```

(~6 min CPU, single core. `--txlog` defaults to `txlog_peer.bin`, which is the
**transmitting** board's log on every one of these legs: legA rx=148/peer=146
forward, legB rx=146/peer=148 reverse.) `filler_adjacency.py` reuses
`joinlog.read_txlog` / `read_failhdr`, `frame_taxonomy.read_frames` and
`common.loss_slot_trains` — no new parsers.

PER / lag-33 baselines quoted below come from the runs' own
`score.txt` / `per_146.txt` (`accept_analyze`), unchanged.

---

## Sample-count and validity preamble (read before any number)

| item | status |
|---|---|
| `txlog_peer.bin` ring wrapped | **no** on all six legs (`n_records == total`) — the submit census is complete, not a tail |
| `failhdr.bin` wrapped | **yes** on `legA_a1r2` (65,536 kept of 73,817) — its failhdr arm is a sample, not a census; the other legs are complete |
| capture wedge | all six legs are wedge-truncated; `loss_slot_trains` windows to `[15 s, live_end)` (live 546–719 s) and nothing past `live_end` is analysed |
| TX↔RX join axis | **seq**, clipped to `[max(tx_lo,rx_lo), min(tx_hi,rx_hi)]`. The two boards keep independent `CLOCK_MONOTONIC`, so README_hostlog §5.5's time-clip is **not** usable across boards |
| `20260904_005624_legA_whiten` | its txlog logs the **whitened** seq word (0xCFA00000…0xCFAFFFFF, non-monotone) ⇒ **Q2 and the seq-axis join are [invalid]** on that leg; Q1 and a duplicate-collapsed record-axis Q3 stand. Its `fail_class`/failhdr arm is [invalid] for the same reason (README_hostlog §2) |
| duplicate submits | 2,967–49,546 per leg (same seq submitted twice). Collapsed to the first submit on the seq axis and **not** used as an exposure variable: with `-DQPSK_ARQ_NAKSTAT` in the build they are plausibly retransmits, i.e. *caused by* loss (reverse causation) |

**Free result, all four joinable legs: `NEVER_SENT = 0`.** Every seq in the
analysed span has a submit record. No loss in this campaign is a host that
failed to submit; all of it is post-submit. [silicon]

---

## Q1 — TX submit-gap census: how often does the host actually starve the modulator?

**The brief's literal criterion is a trap and must not be used.** "inter-submit
gap > one air frame (802.93 µs)" gives **50.2 %**, and that number is an
artefact: `tx_send()` blocks on DMA slot availability, so the submit cadence is
slaved to the air rate and `dt`'s median *is* the frame period (802,931 ns vs
802,930 ns). Half of anything exceeds its own median. Quoting 50 % here would
turn a contradiction into a false SUPPORTS.

The two real dry-queue indicators are `inflight == 0` (queue empty *before* the
submit) and `gap_ns != QPSK_GAP_NONE` (`txgap_note()` fires only when
`inflight_after_reap == 0`). They are independent fields and **agree exactly on
every leg** — the strongest evidence in this document.

| leg | dir | submits | `dt` median (ns) | `dt` p99 | **`dt`>1F (uninformative)** | `dt`>2F | **`inflight==0`** | **`gap_ns` measured** | of those, gap>1F | max gap (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| legA_a1r2 | fwd | 907,508 | 802,931 | 910,033 | 50.18 % | 1 | **132** (1.45e-4) | **132** | **1** | 213.8 |
| legA_whiten | fwd | 926,873 | 802,898 | 958,240 | 49.19 % | 7 | **7** (7.6e-6) | **7** | **5** | 222.6 |
| legB_m16r2 | rev | 939,203 | 802,902 | 903,554 | 49.89 % | 1 | **217** (2.31e-4) | **217** | **1** | 229.2 |
| legB_m8rx | rev | 732,361 | 802,932 | 936,224 | 50.58 % | 1 | **116** (1.58e-4) | **116** | **1** | 193.1 |
| legB_m8r2 | rev | 945,542 | 802,932 | 817,002 | 50.49 % | 2 | **332** (3.51e-4) | **332** | **1** | 233.9 |
| legB_m8rxr2 | rev | 945,263 | 802,932 | 936,314 | 50.94 % | 1 | **184** (1.95e-4) | **184** | **2** | 244.9 |

`spins == 0` on every record of every leg — the daemon never once waited for a
TX slot.

**Reading.** A filler air frame is inserted when the modulator runs dry *for at
least one air frame*. By the daemon's own detector the queue empties at all only
~1.5e-4 of the time, and the dry periods long enough to span a whole air frame
number **1–5 per leg**, the largest 193–245 ms — i.e. **the mid-capture wedge
itself**, not a routine starvation. A 61 ns or 14 µs dry period inserts no
filler.

Two ways to count the available mechanism on the credited forward leg, both
fatal to it:

* **Hypothesis-faithful** (dry ≥ 1 air frame ⇒ a filler really is inserted):
  **1** event against 71,090 losses = 1.4e-5, **~70,000× too rare**.
* **Deliberate upper bound** (credit *every* queue-empty event as a filler,
  including the ~131 that are far shorter than an air frame): **132** against
  71,090 = 0.19 %, **~540× too rare**.

Every number in Q2 below uses the upper bound, because the faithful exposure has
1–5 exposed slots per leg and no statistical power whatsoever. [silicon]

---

## Q2 — adjacency: are lost slots next to dry submits?

Exposure = "the submit at this seq, or the one immediately before it, was dry"
(`inflight==0 | gap_ns` measured). Null = 200 circular shifts of the loss
positions against the fixed dry train (preserves both marginals and the loss
train's own run structure).

**This exposure is deliberately over-broad and is NOT the hypothesis's
variable.** It fires on all 132 queue-empty events, ~131 of which are far
shorter than an air frame and insert no filler at all. The hypothesis-faithful
exposure (`gap_ns > 802,930`) has **1–5 exposed slots per leg** — no test is
possible against it, and that impossibility is itself the finding. What follows
therefore measures "is loss weakly enriched near *any* queue-empty event", a
strictly easier bar than "does loss follow filler insertion", and the mechanism
fails even that.

| leg | outcome | n slots | n lost | n dry | **a** (lost ∧ dry) | P(dry\|lost) | P(dry) | **OR** | **attributable frac** | null p95 | > null? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| legA_a1r2 | all_loss | 875,376 | 71,090 | 136 | 19 | 2.67e-4 | 1.55e-4 | **1.88** | **0.027 %** | 2.12e-4 | yes |
| legA_a1r2 | singles | 875,376 | 35,342 | 136 | 11 | 3.11e-4 | 1.55e-4 | **2.18** | **0.031 %** | 2.26e-4 | yes |
| legA_a1r2 | failhdr class-3 | 875,376 | 13,819 | 136 | 3 | 2.17e-4 | 1.55e-4 | 1.63 | 0.022 % | 3.62e-4 | **no** |
| legB_m16r2 | all_loss | 875,543 | 32,763 | 211 | 17 | 5.19e-4 | 2.41e-4 | **2.32** | **0.052 %** | 3.36e-4 | yes |
| legB_m16r2 | singles | 875,543 | 19,901 | 211 | 15 | 7.54e-4 | 2.41e-4 | **3.39** | **0.075 %** | 3.52e-4 | yes |
| legB_m8rx | all_loss | 661,327 | 24,281 | 125 | 14 | 5.77e-4 | 1.89e-4 | **3.41** | **0.058 %** | 2.88e-4 | yes |
| legB_m8rx | singles | 661,327 | 15,404 | 125 | 10 | 6.49e-4 | 1.89e-4 | **3.81** | **0.065 %** | 3.25e-4 | yes |
| legB_m8r2 | all_loss | 876,788 | 33,184 | 305 | 16 | 4.82e-4 | 3.48e-4 | 1.45 | 0.048 % | 4.52e-4 | marginal |
| legB_m8rxr2 | all_loss | 876,788 | 32,396 | 190 | 15 | 4.63e-4 | 2.17e-4 | **2.30** | **0.046 %** | 3.09e-4 | yes |

Corrupt-at-host frames (failhdr, `fail_class == 3` = magic+len parse, CRC fail,
so the seq word is trustworthy) show **no** association above the null on any
leg (a = 0–3). Classes 1/2/4 are excluded: their `host_seq` is raw garbage
bytes (README_hostlog §2) and cannot index a slot.

**Reading — the two numbers that must be quoted together.** There *is* a real
association: dry submits are 1.9–3.8× enriched among lost slots, above a
shuffle null, consistently signed on five legs. And it explains **≤ 0.08 %** of
the loss. A dry queue is a (weak) hazard; it is not the defect. Odds ratio
answers "is there any association"; attributable fraction answers "does it
explain 8 %", and the answer to the second is no by three orders of magnitude.
[silicon]

---

## Q3 — is the host submit cadence periodic at the 26 ms comb period?

Autocorrelated on the **continuous** `dt` series on the seq axis (a ~130-event
binary dry train has no usable spectrum; its `dry_ac_*` fields are reported by
the script only to show they are unusable). Lag 32 × 802.93 µs = **25.69 ms**.
Two mechanics matter and both flip the answer if skipped:

* **Outlier clip.** Each leg contains one ~200 ms inter-submit gap (the wedge).
  Zero-mean autocorrelation is variance-weighted, so that single sample crushes
  every real line to ~0.01. `dt` is clipped to `[0, 2 air frames]` first.
* **Duplicate collapse.** A duplicated seq inserts an extra sample and shifts
  every later one, desynchronising the lag axis (whiten leg: 0.015 → 0.680 at
  lag 32).

| leg | PER | **host cadence** lag-32 | lag-1 | lag-64 | lag-96 | perm null p95 | **RX loss comb** (all_loss lag-32) | RX singles lag-32 | `accept_analyze` lag-33 |
|---|---|---|---|---|---|---|---|---|---|
| legA_a1r2 | 8.121 % | **0.695** | −0.385 | 0.638 | 0.558 | 0.0037 | 0.526 | 0.317 | 0.268 |
| legA_whiten | 8.168 % | **0.680** | −0.345 | 0.607 | 0.592 | 0.0040 | 0.682 | 0.510 | (not scored) |
| legB_m16r2 | 3.742 % | **0.631** | −0.344 | 0.491 | 0.378 | 0.0038 | 0.388 | 0.290 | 0.379 |
| legB_m8rx | 3.672 % | **−0.000** | −0.190 | −0.001 | −0.000 | 0.0041 | **0.750** | **0.689** | −0.015 |
| legB_m8r2 | 3.785 % | **−0.006** | −0.476 | −0.001 | −0.014 | 0.0054 | **0.658** | **0.600** | −0.021 |
| legB_m8rxr2 | 3.695 % | **−0.001** | −0.193 | 0.001 | −0.001 | 0.0036 | **0.618** | **0.556** | 0.123 |

**Reading — this is the sharpest result in the document, and it cuts against
the hypothesis.** The host submit cadence genuinely carries a 25.69 ms line on
three legs, enormously above the null, with harmonics at 64/96/128 — a real,
previously unreported host-cadence periodicity. But the RX loss comb at that
same lag is **strong on all six legs, and strongest exactly on the three legs
where the host cadence line is absent**. Those three legs are not
structureless — their cadence still has strong short-lag structure (lag-1 =
−0.19/−0.48/−0.19) — the **25.69 ms line specifically** is what is gone, while
the RX comb at that lag is at its strongest. Presence and absence dissociate
cleanly: the comb survives a host whose cadence has no 26 ms component at all.
**The comb is not host-cadence-made.** [silicon]

(Incidental, worth a line: the cadence line's presence tracks a knob on the
**transmitting** board — it is present on the two legs whose TX-board daemon ran
default/`RXM_A=16` and absent on the three `RXM=8` legs. That is a host-side
observation about the cadence, not about the loss. [inferred])

---

## Q4 — forward vs reverse against the filler fraction

| direction | leg | PER (lost in denominator) | denominator | dry fraction | dry periods > 1 air frame |
|---|---|---|---|---|---|
| forward (146→148) | a1r2 | **8.121 %** (71,090/875,376) | 875,376 slots | 1.45e-4 | 1 |
| forward, whitened | whiten | **8.168 %** (71,720/878,038) | 878,038 slots | **7.6e-6** | 5 |
| reverse (148→146) | m16r2 | 3.742 % (32,763/875,543) | 875,543 slots | 2.31e-4 | 1 |
| reverse | m8rx | 3.672 % (24,281/661,327) | 661,327 slots | 1.58e-4 | 1 |
| reverse | m8r2 | 3.785 % (33,184/876,788) | 876,788 slots | 3.51e-4 | 1 |
| reverse | m8rxr2 | 3.695 % (32,396/876,788) | 876,788 slots | 1.95e-4 | 2 |

The reverse legs carry **1.1–2.4× more** host starvation than the forward leg
and **half** its PER. The relationship is anti-correlated, not correlated.

Two further falsifiers fall out of the same table:

* **The whitening fix candidate failed.** `legA_whiten` (`QPSK_WHITEN=1` both
  daemons) scores **8.168 %** against the unwhitened `a1r2`'s **8.121 %** — no
  movement, well outside the pre-registered "≲ 1 %". The pre-registered
  falsifier for the content-locked false-sync hypothesis is met. [silicon]
* That same whiten leg has the **lowest** starvation of all six legs (7 dry
  submits in 926,873, a 19× reduction vs a1r2 — it ran at 952 f/s, gate_pass=0)
  and **identical** PER. Starvation moved 19×; PER moved 0.6 %.

---

## What is contradicted, and what is not

**Contradicted [silicon]:** the route the brief operationalises — *host*
inter-submit gaps → modulator dry → filler air frame → false preamble → next
frame swallowed. It is ~70,000× too rare on the hypothesis's own terms (1 filler-capable dry
period vs 71,090 losses on the forward leg), and still 540×–2,000× too rare
under an upper bound that credits every sub-air-frame queue-empty event to account for the observed PER on
either leg, is anti-correlated with PER across directions, and its
26 ms-periodicity leg (Q3) dissociates from the RX comb.

**Not touched by this analysis:** the fabric-only BIST result (filler
interleaving at GAP=60,000) stands on its own evidence — nothing here speaks to
it. The host txlog sees only the DMA submit path; **fabric-level starvation
between the DMA queue and the modulator (the ByteWordBuffer path already on
record as ~5 % forward) is invisible to it** and remains the live residual for
"where does the filler actually come from on the RF link". Naming it here; not
opening it here. [inferred]

**Also not established:** that the RX lag-32 comb is a single mechanism. It is
present on all six legs at 0.39–0.75, but Q3 only shows it is *not* the host
cadence.

## Next falsifiable step (not run)

The T2 drain-budget probes d1/d0 were never run. The one-line discriminator this
desk pass suggests instead: a leg with the TX daemon's submit cadence
deliberately de-periodised (jitter the write size away from 35 × 1400 B) should
leave the RX lag-32 comb **unchanged** if Q3's dissociation is real — and that
prediction is already half-confirmed by `m8rx`/`m8r2`/`m8rxr2`, which are that
experiment by accident.
