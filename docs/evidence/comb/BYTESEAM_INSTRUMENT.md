> Evidence ledger, moved verbatim from `two_jup/comb/BYTESEAM_INSTRUMENT.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# The byte seam: where a 192-byte unit can vanish, and the instrument that decides

**RXFIX Task 41 (byteseam). Desk task — NO BOARD CONTACT of any kind, no build, no
flash, no rig unit.** Every number below comes either from source in this tree
(labelled **[netlist]**) or from capture files already banked under
`two_jup/comb/runs/*/` (labelled **[silicon, banked]** — measured on the rig by an
earlier task, re-scored here). **[inferred]** is arithmetic or a derivation.
**[sim]** is the Verilator/Icarus harnesses. **[unverified]** is a claim this desk
could not close.

**Revision: fix round 1 (2026-09-06).** One `[silicon, banked]` claim in §0 was found
not to be in the data and has been **retracted in place** rather than deleted silently
(§0, last bullet); §0 gains a fourth result, the pin word budget, which changes the
headline; §1.4 is no longer a tie; §2.4's positive control for `short_frm`/`orphan_w`
was withdrawn as structurally impossible and replaced with a bounded one that has not
been run; §4's P6/P5/F5 are replaced by a single scoring rule. Each change says in the
text what it replaced.

Companions: `RXFIX_STATE.md` (campaign), `FWD_RESIDUAL_0p22.md` (Task 23, the class),
`FWD_RESIDUAL_PHASE.md` (Task 28, the 192-byte lattice), `REV_RESIDUAL_20ms.md` §0
(reverse numbers), `two_jup/rxfix/W1_REGMAP.md` (the read-window pattern this design
extends), `two_jup/SEQBIST_STATE.md` (the checker/cnt_mux path).

Reproduce §0(1)–(3) and §1: `python3 two_jup/comb/byteseam_pins.py` (output banked at
`two_jup/comb/byteseam/pins_shortorphan.txt`). §0(4)'s word budget, §0(1)'s sub-window
spread and the §0 retraction's corpus scan are **not** produced by that script; each
carries its own inline command or its own arithmetic from the fields it names, all of
which are in the same banked `chk.jsonl` / `cap/failhdr.bin` files.

---

## 0. Headline — §5's cheapest experiment was run at this desk, and it moves the localisation

The task asked (§5) whether a cheaper desk or sim experiment could rule out a
candidate seam before any build. One could, it cost no board time, and it has been
run: **two counters that already exist in silicon on both flashed images, and that
are already recorded in every banked `chk.jsonl`, have never been scored.** They are
`rx_seam_checker`'s `short_frm` (cnt_mux32 slot 5) and `orphan_w` (slot 6), and they
tap the **DUT RX byte pins** — upstream of the seam injector, the breakout, the
axi_dmac, DDR and the host (`two_jup/comb/BIST_SEQ_SURVEY.md:12-13,20`;
`jupiter_240k5_byte/rtl_sim/rx_seam_checker.v:1-8,73-82`).

Four results, all **[silicon, banked]**, and one **retraction**. Nine legs; the nine
`chk.jsonl` spans sum to **3,872.4 s**, not the 3,400 s the first draft of this
section claimed (per-leg spans, rounded: 470.0, 470.6, 470.7, 470.3, 350.9, 470.0,
470.3, 349.1, 350.6).

**(1) `short_frm` fires at the host's `failhdr` event rate — to the ~10 % that is the
legs' own non-stationarity, and no better.**

| forward leg | `short_frm` rate (fabric, `chk.jsonl` span) | `failhdr` event rate (host, live window) | ratio |
|---|---|---|---|
| T13 `20260904_201814` | 0.253 s⁻¹ (119 / 470.0 s) | 0.2486 s⁻¹ (174 events / 700 s) | 1.02 |
| T27 leg B `20260905_091549` | 0.223 s⁻¹ (105 / 470.7 s) | 0.2221 s⁻¹ (157 events / 707 s) | 1.00 |
| T27 leg A `20260905_084623` | 0.266 s⁻¹ (125 / 470.6 s) | 0.2649 s⁻¹ (187 events / 706 s) | 1.00 |

**The 1.004–1.018 ratios of the first draft were spurious precision and are withdrawn.**
The two series are on **different clocks over different windows**: the fabric shorts are
counted over the ~470 s `chk.jsonl` span, whose timebase is the *reader host's*
`time.monotonic()` (`two_jup/seqbist/seqbist_read.py:137`), while the `failhdr` events
are counted over the ~700–707 s live window on the *board's* `CLOCK_MONOTONIC`. The two
windows are not co-registered and the fabric window is an unidentified subset of the
host window. Re-scored here: sliding a 470-s window across each leg's host event series
in 5-s steps gives **0.2149–0.2745 (T13), 0.2277–0.2936 (T27 leg A), 0.1872–0.2426
(T27 leg B)** — a **24–26 % peak-to-peak spread, ±12 % about the mean**, which is the
leg's own non-stationarity. Quoting agreement at 0.4–1.8 % against a quantity that
varies by ±12 % window to window is not defensible. **The defensible statement is that
the two rates agree at the ~10 % level, i.e. within the legs' own window-to-window
variability**; and a rate match is not an event-level match, so "one for one" is *not*
established by this table. The event-level claim is carried by (2), (3) and (4).
Consequence: §1.4's third reading — the shorts as an unrelated ~0.25 s⁻¹ background —
is **less disfavoured than the first draft implied**, and stays registered as F4.

**(2) The event is visible AT THE PINS as a paired mark anomaly, on every leg.**
`short_frm` and `orphan_w` co-occur in **every** 10-s interval of **every** leg:
across nine legs, **0 intervals with a short and no orphan, 0 with an orphan and no
short**, r(Δshort, Δorphan) = +0.879 … +0.996.

**(3) The orphan-run length IS the host's `magic_off`, divided by 8.**
In intervals holding exactly one `short_frm`, the orphan delta is one orphan-run
length with no averaging:

| leg | host `magic_off` mode | predicted run = `magic_off`/8 | measured single-short orphan values | on the 24-word lattice |
|---|---|---|---|---|
| T27 leg B (fix OFF) | 568 | 71 | **71, 71, 71, 71, 71, 71** | 6/6 |
| T13 (R4B) | 568 (376 second mode) | 71 (47) | **47, 71, 71** | 3/3 |
| T27 leg A (fix ON) | 952 | 119 | **119, 119, 238** | 2/3 |
| **T10 (W1, same board 148, same direction)** | **unusable — see below** | — | **113, 119, 119, 131, 142, 143, 143, 144, 156, 238** | **4/10** |
| **all four forward legs** | | | | **15/22** |

**T10 was omitted from the first draft of this table and should not have been.** It is
a forward leg on the same board, it is in this document's own nine-leg set
(`two_jup/comb/runs/20260904_165420_w1_air`, `meta.txt`: `dir=fwd rx=10.0.0.148`), and
it carries **ten** single-short intervals — more than the three quoted legs combined.
Scoring it changes the headline of this row from **11/12 (92 %)** to **15/22 (68 %)**
on the lattice, and it must be quoted that way.

*What is legitimately excluded, and what is not.* T10's **host** log is unusable: its
`failhdr` ring is **WRAPPED** (`flags & 1 = 1`, 65,536 of 75,817 records retained), so
no host event rate and no `magic_off` mode can be quoted from it — its in-window census
has no clean mode (`magic_off` 65,535 × 36,504 = "no magic found", 0 × 16,664,
64 × 4,816, 952 × 1,302). The leg is also badly degraded at the pins: 30,861
`chk_gap_events` and a pin bad fraction (same definition as the §0(4) table) of **7.88 %** against
0.055–0.068 % on the other three forward legs. **But the fabric-side lattice test in this row does not use
the host log at all**, so the exclusion covers T10's `magic_off` column and nothing
else; its ten fabric values stay in the table.

*What T10 does to the identity: it weakens it.* T10's ten single-short values have no unique mode
(119 × 2 and 143 × 2, both on lattice), their median 142.5 is **off** lattice by one,
and **6 of the 10 are off lattice** (113, 131, 142, 144, 156, 238) — which is the 4/10
in the table above, and the reason the four-leg total is 15/22 rather than the
three-leg 11/12. `magic_off = 8 × orphan_run` is therefore quoted from
**three** legs, not four, and the pre-registered P4 threshold (≥ 80 % of single-short
intervals on the lattice) would **FAIL on T10 at 40 %** — which is the right way for a
pre-registration to behave, and is left standing rather than re-tuned.

`magic_off = 8 × orphan_run` remains a **cross-instrument** relation between a fabric
counter in 148's RX byte plane and a host-side byte offset in DDR, with no shared code
path. It is **not** billed as a clean identity any more: (4) below shows it cannot be
read as "8 × the words deleted in that gap", because no words are deleted at the pins
at all.

**(4) NO WORDS ARE MISSING AT THE PINS. The accepted stream carries 191.00 words per
accepted mark.** *(Post-hoc — see "not pre-registered" below.)*

An exact identity, straight out of the checker RTL: every accepted word is a mark
(`frames`), an orphan (`orphan_w`), or a body word, and a frame that is **not** cut
short contributes exactly 190 body words (`jupiter_240k5_byte/rtl_sim/rx_seam_checker.v:74-93`).
Therefore, over any window, **[netlist]**

```
D1  ≡  191 × frames + orphan − acc_beats  =  Σ over shorts of (191 − widx at that short)
```

— the total words the checker did not see in the gaps that ended in a short, bounded
by `1 × short ≤ D1 ≤ 190 × short`. `acc_beats` is the right term to use here: with the
seam injector disabled (its reset state, and `acc_user − frames` = −2 / 0 / −1 / 0 over
~585 k frames on the four legs confirms it), `qpsk_traffic_gen_rx2` is pure
pass-through — `assign dma_valid = en_d ? s_valid : dut_valid` and
`assign dut_ready = en_d ? 1'b1 : dma_ready`
(`jupiter_byte_rxfixr4dr1_build/qpsk_traffic_gen_rx2.v:99,114`) — so `acc_beats`
(`:119-125`, `dma_valid && dma_ready`) increments on **the same combinational condition
in the same cycle** as the checker's `acc = valid && ready` (`rx_seam_checker.v:40`).
It is the *same accept event*, not "a different tap in a different place"; §6 concern 3's
dismissal is withdrawn on that ground.

Four 148 **forward** legs — the lineage on which `acc_beats`' wiring is verified (see
the provenance caveat below):

| leg | `frames` | `acc_beats` | `acc_beats − 191 × frames` | `orphan` | `short` | `D1` | `D1 / orphan` |
|---|---|---|---|---|---|---|---|
| T13 | 585,248 | 111,783,606 | **+1,238** | 8,376 | 119 | 7,138 | 0.85 |
| T27 leg A | 585,925 | 111,913,176 | **+1,501** | 15,970 | 125 | 14,469 | 0.91 |
| T27 leg B | 586,081 | 111,941,685 | **+214** | 7,739 | 105 | 7,525 | 0.97 |
| T10 | 584,053 | 111,554,650 | **+527** | 20,832 | 168 | 20,305 | 0.98 |
| **pooled** | **2,341,307** | **447,193,117** | **+3,480 (7.8 ppm)** | **52,917** | **517** | **49,437** | **0.93** |

**The reconciliation §0(2) and §0(3) force — the arithmetic the first draft did not
do.** **[netlist + inferred]** §0(2) says every event carries **exactly one short**, and
a short means a mark arrived at `widx < 191` (`rx_seam_checker.v:76`), i.e. the
mark-bearing gap that ended in that short was `D1ₑ = 191 − widx` words short of a frame.
§0(3) says every event also carries **one orphan run** of `L` words, i.e. a *second* gap
that is `D2ₑ = 191 − L` words short. The host reads a **fixed 1528-B stride**
(`host_app_k5/qpsk_tun.c:1565-1571`), so *every* missing byte moves the carve phase: if
both anomalies are real word losses the host must see `8 × (D1ₑ + D2ₑ)` per event. What
§0(3) reports the host seeing is `8 × D2ₑ` alone — `magic_off = 8L`, hence
`1528 − magic_off = 8 (191 − L)`. **The document's own two headline numbers are therefore
consistent only if `D1 = 0`: only if the short costs no words at all.**

Worked on T13: `D1 / short` = 60.0 words and `L` = 71 ⇒ `D2ₑ` = 120, total 180 words per
event ⇒ `magic_off` would have to be `8 × (191 − 180)` = **88 B**. The measured mode is
**568 B**. Two readings of the same event, 480 bytes apart.

So the banked counters already answer the question §1.4 declared open:

| reading | what it requires of `D1` | measured |
|---|---|---|
| **the short is a real word deletion** — H-FIFO's mark-surviving burst, and N2 read as an equality | `D1 = 0` | **`D1` = 49,437 words, with a 5.7σ dependence on `Δshort`** |
| **the short costs no words** — a mark arrived on the wrong word and the checker re-based on it | `D1 = orphan` **identically**, i.e. `acc_beats = 191 × frames` | **`D1 / orphan` = 0.93 pooled; slope on `Δorphan` = 1.11 ± 0.18, consistent with 1.0; `acc_beats − 191 × frames` = +3,480 on 447 M accepted words (7.8 ppm) against ±1,860 of endpoint jitter** |

**The second reading is what the data says, and it is the one §1.4 did not list.** A
third way out exists and is named rather than buried: §0(3)'s `magic_off = 8 ×
orphan_run` could be a **coincidence** across three legs and 12 single-short intervals,
in which case the first row is rescued and nothing is decided. That is F4's territory,
it is **not** excluded, and §0(1)'s honest ~10 % rate agreement makes it slightly less
remote than the first draft allowed. What is *not* available is the first draft's own
position — quoting §0(3) as a clean cross-instrument identity **and** presenting §1.4 as
tied. Those two statements are arithmetically incompatible, and the desk had the number
that shows it.

**Read skew is the error term, and it is bounded.** Slots 0–7 are **not** frozen:
`tgen_rx_ctrl` bit 3 drives only `rx_seq/freeze`
(`two_jup/skidfix/patch_seqbist_tcl.py:248-251`), so `frames`, `orphan` and `acc_beats`
are sampled ~6 `devmem` forks apart within each sweep. A *constant* skew cancels in a
delta; only its jitter survives, and only at the two window endpoints. Per-interval
`D1` accordingly has s.d. 733–1,190 words per leg and goes **negative** in individual
intervals — impossible for a sum of non-negative terms — so **no per-interval value is
quoted**, and the pooled endpoint band above is the root-sum-square of the four legs'
per-interval s.d. **That band is a conservative floor, not an error bar** — the
per-interval s.d. contains real event-to-event variance as well as jitter — and the
residual it brackets is **small and systematic, not noise**: `acc_beats − 191 × frames`
comes out **positive on 8 of the 9 legs** (+214 … +2,224; only T22 is negative, at
−320), which pure jitter would not do. The right reading of +3,480 is therefore "a
small one-sided residual of order 10³ words in 4 × 10⁸, of unresolved origin", **not**
"zero". It does not touch the discriminating comparison, which is `D1` = 49,437 against
the `D1 = 0` a real word deletion would require. Three skew-robust readings, all pooled
over the four legs' 188 intervals:

* `D1 = 111.2 (± 19.6) × Δshort − 42.9 (± 83.2)` — slope **5.7σ** from zero, intercept
  consistent with zero, which is what a skew-only budget would be obliged to give.
* `D1 = 1.110 (± 0.176) × Δorphan − 49.6 (± 79.6)` — slope **consistent with 1.0**
  (0.6σ) and **6.3σ from 0**.
* Intervals with no short (n = 72): mean `D1` = **−100 ± 90**. Intervals with a short
  (n = 116): **+488 ± 90**.

**What this does to the headline — stated as the change it is, and bounded.** The pins
*do* see the event: `short_frm` and `orphan_w` fire, 1:1, at the host's rate, and the
word budget's dependence on `Δshort` is 5.7σ over 517 shorts. But what the pins see is
**a mark landing on the wrong word**, not words going missing: to the precision of this
measurement (7.8 ppm of 447 M accepted words) **the accepted word count at the pins is
conserved at 191 words per mark.**

**Exactly what that does and does not exclude — the assumption named.** `acc_beats =
191 × frames` is a statement about words *relative to marks*, so it excludes word loss
**between the `ByteSerializer` output (c) and the pins (f)** — seams S4, S5, S6, i.e.
the H-FIFO branch — and it does **not** exclude a deletion *upstream* of the serializer.
`wordLast` fires when the serializer has **counted** 191 words and `start` clears
`wordCnt` (§1.1(c)), so a frame whose *content* is short by D words — S1's `deintValid`
hole, S2's emit window, S3's early `start` — still produces marks 191 **emitted** words
apart, and this budget would read exactly 191.00 while content was missing. That is
**H-UPSTREAM, and it is still LIVE in §1.3.** Separating it is precisely what `bs_bits`
and P8 exist for, and it is why this section does **not** make BS1 redundant. The
honest scope of §0(4) is therefore: **no words are lost between the serializer output
and the pins** — which is the branch §1.4 was tied on, and nothing wider.

Within that scope, the `k × 192 B` byte deficit the host reconstructs from `magic_off`
is **not** present at the pins as words absent from the mark-to-mark stream. That is a
*different* localisation from "the deletion is born at or upstream of the pins": what
is born at or upstream of the pins is a **mark displacement**; where the host's byte
deficit is manufactured is **not measured by this document**. **[inferred]**

The obvious candidate for the second half of that chain is `rx_byte_dma`'s
`SYNC_TRANSFER_START = 1` (§1.1(h)): every queued transfer gates its start on a `tuser`
beat, so a mark arriving D words early starts the transfer D words early and the host's
fixed 1528-B carve then finds the next magic at `8D` — which is `magic_off = 8 ×
orphan_run`, §0(3)'s relation, **with no byte ever deleted**. This reading is
**[unverified]** and must not be quoted as a result: it is post-hoc; this desk has not
read `SYNC_TRANSFER_START`, `CYCLIC` or `X_LENGTH` behaviour out of the BD (the same gap
§3's O2 admits for `MAX_BYTES_PER_BURST`); and the *direction* of the displacement
(early rather than late) is fixed only by which of `8L` and `1528 − 8L` matches the
measured `magic_off` — an argument, not a measurement. What does **not** depend on any
of that is the conserved word count, which stands on counter arithmetic alone.

**This is the pin-side sibling of F5, not F5.** F5 tests *serializer* conservation
(`bs_words` vs `bs_starts`) and needs the BS1 build; this is *pin* conservation and
needed only banked data. It closes for the same reason F5 would: a loss that removed
words **and** marks in the exact 191 : 1 ratio would be whole-frame deletion, which
produces neither shorts nor orphans — and both are present, in every interval of every
leg.

**Not pre-registered.** §4's P1–P9 and F1–F6 were written before this budget was
computed. It is a post-hoc finding on banked data and is labelled as one; it is
registered forward as **P10 / F7** (§4) so the next leg tests it instead of re-deriving
it.

**Provenance caveat — why the table is four legs and not nine.** The same budget on the
five *reverse* legs gives `acc_beats − 191 × frames` of −320…+2,224 and `D1/orphan`
0.89–1.02: the same answer. It is deliberately **not** quoted as evidence, because
`patch_seqbist_tcl.py:71` states "On 146 `traffic_gen_rx` does not exist" and `:428`
wires slots 0–15 to a hard zero on the `vendh` lineage — yet those legs read
`acc_beats` ≈ 83 M and `acc_user` ≈ `frames`. Either that patch block is stale or 146
carries an image the block never applied to; this desk cannot tell which without board
contact. A number whose wiring is contradicted by its own patch script is exactly the
kind of number the retraction below is about. **[unverified]** — closed by E2.

**Positive control: there is none for this budget either.** A real word deletion must
drive `acc_beats − 191 × frames` **negative**, and nothing in the shipped image has ever
been made to delete a word on demand. §2.4's bounded stall/release is the positive
control for this number as much as for `short_frm`/`orphan_w`. Until it is run, §0(4)
is a strong internal-consistency argument on banked counters, **not** a controlled
measurement, and every conclusion drawn from it is provisional.

**Corroboration that costs nothing: the pin-health cross-check.** Independently of all
of the above, the checker's verdict counters agree with the host and with themselves
**[silicon, banked]**:

| forward leg | `crc_fail` | `magic_bad` | un-verdicted (`frames` − verdicts) | pin bad fraction | `short` |
|---|---|---|---|---|---|
| T13 | 129 | 148 | 118 | 0.0675 % | 119 |
| T27 leg A | 143 | 54 | 125 | 0.0550 % | 125 |
| T27 leg B | 110 | 138 | 105 | 0.0602 % | 105 |

Against a host PER of **0.079 %** on the same legs. And the un-verdicted count equals
`short` **exactly** on T27 legs A and B, and 118 against 119 on T13 (one frame in
flight at a window edge) — which is forced: a frame cut short never reaches
`widx = 191`, so it never gets a verdict (`rx_seam_checker.v:96-101`). This is a
tighter cross-check than either rate quoted in (1), and it is recorded here as support
for the *site* claim.

**What this buys, and what it costs the standing story.**

* **A mark anomaly — not a word deletion — is born at or upstream of the DUT RX byte
  pins.** `qpsk_traffic_gen_rx2`, `rx_byte_breakout`, `axi_dmac` `rx_byte_dma`, the DDR
  carve and `qpsk_tun.c` are **excluded as the site at which the `wordFirst` mark goes
  wrong**, by direct measurement rather than argument, because the anomaly is already
  present at the pins. They are **NOT excluded as the cause of the host's byte
  deficit**: §0(4) shows the mark-to-mark word count at the pins is conserved, so
  whatever converts a displaced mark into a `k × 192 B` carve step happens **downstream
  of them**, and `rx_byte_dma`'s `SYNC_TRANSFER_START` is the leading candidate. (A
  *silent* deletion upstream of the `ByteSerializer` — H-UPSTREAM, §0(4)'s stated scope
  — would be invisible to both the budget and the checker; it is P8's job, not this
  bullet's.) The site/cause
  distinction is load-bearing everywhere in this document and any summary sentence that
  drops it ("the delivery plane is EXCLUDED BY MEASUREMENT") is wrong.
  `FWD_RESIDUAL_0p22.md`'s class name ("a byte-alignment cascade **in the receive
  delivery path**") is therefore **more nearly right than the first draft allowed**: the
  cascade (8.6 host frames per event) is in the delivery path, the *seed* is a mark that
  arrives at the pins on the wrong word, and the step between them is still in the
  delivery path.
* **`short_frm > 0` proves that two marks arrived at the pins less than 191 words
  apart** — see §1's netlist argument N1. N1 admits two causes: words lost between (c)
  and (f), **or** a `wordFirst` bit corrupted in (d)/(e). §0(4)'s word budget excludes
  the first, which leaves the second. A pure "early frame boundary at RxAlign" story
  still cannot be the whole event.
* **The 192-byte quantum is really a 24-word quantum, and `≡ 23 (mod 24)` is not an
  independent fact.** `FWD_RESIDUAL_PHASE.md` §1.3 reports four offsets whose word
  index is ≡ 23 (mod 24) as a second coincidence. It is not: the frame is
  **191 words** (`frame_config_k5.m` f1536 `WordsPerPacketRx = 191`) [netlist], the
  deficit is 24k words, and 191 − 24k ≡ 23 (mod 24) automatically. One fact, not
  two. The lattice claim is unchanged in strength; its statement is now
  "**the host's carve step is a whole number of 24-word units**" — "deficit" is the
  wrong word for it after §0(4), and 4 of the 22 forward single-short intervals are off
  that lattice (§0(3)).
* **RETRACTED — "k = 1 and k = 4 exist" was never in the data.** The first draft of
  this section carried, under the **[silicon, banked]** label, the claim that "the pin
  counter adds runs of 95 (k = 4, T10 leg) and 167 (k = 1, T29 leg, read as 168 across
  a read boundary), so the absence of k = 4 was small-N." **Neither number is in the
  bank, and the bullet is deleted.** Every per-10-s `orphan_w` delta in **all 22**
  banked `chk.jsonl` files was re-scanned at this desk:
  * an orphan delta of **95** occurs **exactly once in the whole corpus** — in
    `two_jup/comb/runs/20260906_092251_w1_t36_dpoff2`, a **reverse** leg on
    **10.0.0.146** (`meta.txt`: `dir=rev rx=10.0.0.146`; `chk.jsonl` `board`
    = `10.0.0.146`) — in an interval whose **`Δshort` is 2**. It is therefore a
    two-event aggregate, not an orphan-run length. It does **not** occur in T10, in any
    forward leg, or in any single-short interval anywhere in the corpus. T10's ten
    single-short values are `[113, 119, 119, 131, 142, 143, 143, 144, 156, 238]`.
  * **167** occurs **nowhere** as an orphan delta. The value on T29 is **168**, and
    "read as 168 across a read boundary" was a post-hoc rescue of an off-lattice number
    rather than a measurement — as was reading T27 leg A's 238 as "2 × 119" in §0(3),
    which the 1:1 short/orphan pairing forbids (one short cannot carry two runs). T29
    is in any case a leg this campaign had **already** marked unusable: its own
    `meta.txt` records `capture_r3_exit=3`,
    `wedge_verdict=MID_CAPTURE_WEDGE after 456s -- NOT usable data` and
    `deliver_rate_gate_pass=0`.

  **The measured set is `FWD_RESIDUAL_PHASE.md` §1.3's, unchanged: k ∈ {2, 3, 5, 6}**
  (from `magic_off` 1144 / 952 / 568 / 376, of which the 1144 record is a single record
  that document itself calls "consistent with, not evidence for"). **This desk adds no
  k, and the absence of k = 4 stands.**

  This is recorded here, in the document, rather than edited away silently: a
  fabricated number under a `[silicon, banked]` label is the most serious thing this
  campaign can produce, and the correction has to be visible to the next reader. One
  command reproduces the absence over the whole bank:

  ```
  python3 - <<'EOF'
  import json, glob, os
  for p in sorted(glob.glob('two_jup/comb/runs/*/chk.jsonl')):
      r = [json.loads(l) for l in open(p) if l.strip()]
      hits = [(b['short'] - a['short'], b['orphan'] - a['orphan'])
              for a, b in zip(r, r[1:])
              if 0 < b['ts_mono'] - a['ts_mono'] <= 30
              and (b['orphan'] - a['orphan']) in (95, 167)]
      if hits:
          print(os.path.basename(os.path.dirname(p)), '(dshort, dorphan) =', hits)
  print('scanned', len(glob.glob('two_jup/comb/runs/*/chk.jsonl')), 'chk.jsonl files')
  EOF
  ```

  Output, in full: `20260906_092251_w1_t36_dpoff2 (dshort, dorphan) = [(2, 95)]` and
  `scanned 22 chk.jsonl files`.

---

## 1. WHERE a 192-byte unit can vanish — the seams, with the evidence

### 1.1 The chain, as built [netlist]

Citations are to `jupiter_byte_rxfixr4dr1_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`
unless another path is given.

| # | stage | file | domain |
|---|---|---|---|
| (a) | `RxDeint` — ping-pong deinterleave RAM, 1537 × 16 = 24,592 coded bits, emits 12,296 `deintValid` pairs/frame plus `frameStart`/`frameEnd` | `TxRxCompo_ip_src_RxDeint.v:322,402,507` | clk/4 RAM, clk/8 out |
| (b) | `RxAlign` — on `deintValid && frameStart`: `o = 0`, `sk = skipCount + 41`; then emits `validOut`/`dataOut` while `o < 12292`; `startOut = (o == 0)` | `TxRxCompo_ip_src_RxAlign.v:129-160` | `enb_1_2_0` (15.36 MHz) |
| (c) | `ByteSerializer` — packs 64 `bitValid` beats into a word; **`start` clears `acc`, `bitIdx` AND `wordCnt` and discards the partial word**; `wordLast` when `wordCnt ≥ 191` (then `wordCnt = 0`); `wordFirst` = the word *after* a `wordLast`; `wordTog` flips once per emitted word | `TxRxCompo_ip_src_ByteSerializer.v:243-300` | `enb_1_2_0` |
| (d) | `SerWordRT` / `SerTogRT` / `SerLastRT` / `SerFirstRT` — four **separate** 15.36 → 30.72 MHz rate transitions | `jupiter_240k5_byte/byte_plumbing_overlay_k5.m:216-229` | 15.36 → 30.72 |
| (e) | `ByteRxFifo` — push on every `tog` edge; pop on `valid_i && ready_1` (`ready` delayed 4 by `delayMatch_reg`); `valid` gated by the SOF-prime guard `rdyRun ≥ 6`; **full ⇒ drop the OLDEST entry** + `ovfCnt`; registered write-through bypass on a read/write collision | `TxRxCompo_ip_src_ByteRxFifo.v:60-100`; source `jupiter_240k5_byte/rxfifo_bram/ByteRxFifo_v4.v` | clk, `enb_gated` |
| (f) | **DUT pins** `dut_byte_{data,valid,last,user}_out` / `dut_byte_ready_in` — `rx_seam_checker` + `rx_seq_checker` snoop here | `two_jup/sim_repro/resynth_probe3.tcl:17` | clk |
| (g) | `qpsk_traffic_gen_rx2` (seam injector; **pass-through while `ctrl[0] = 0`**, its reset state) → `rx_byte_breakout` (TLAST gate, Option-E tuser mask) | base wiring `jupiter_240k5_byte/complete_byte_t8.tcl:104-108`, which connects `dut_byte_*_out` **directly** to `rx_byte_breakout`; the injector is spliced into that path later, on the SEQ-BIST lineage, by `two_jup/skidfix/patch_seqbist_tcl.py` | clk |
| (h) | `axi_dmac` `rx_byte_dma` @0x9D200000 — `SYNC_TRANSFER_START = 1`, `CYCLIC = 1`, 64/64, TYPE_SRC = 1 (stream), TYPE_DEST = 0 (MM) | `complete_byte_t8.tcl:86`; parameter set quoted by `jupiter_240k5_byte/rtl_sim/DMAC_SIM_RESULTS.md` | clk / sys_250m |
| (i) | DDR carve → `qpsk_tun.c` drain, fixed 1528-byte stride, `X_LENGTH = 16 × 1528 − 1` | `host_app_k5/qpsk_tun.c:1565-1571` | host |

*Citation corrected.* The first draft cited `complete_byte_t8.tcl:95-101` for row (g);
those lines are the close of the `bconn` proc and the **three TX-side** `bconn` calls.
The RX wiring is at `:104-108` and shows `dut_byte_*_out` going straight to
`rx_byte_breakout` with no injector in that file at all, so the first draft's
"(g) `qpsk_traffic_gen_rx2` → `rx_byte_breakout`" ordering was not supported by the
file it named. The ordering is nevertheless correct on the flashed lineage, which is
why the splice is now cited where it actually happens.

**Geometry [netlist].** f1536: `InfoBits = 12292 = 192 × 64 + 4`, `PayloadBits =
24640`, `WordsPerPacketRx = 191` (`frame_config_k5.m`). A frame is **191 × 64-bit
words = 1528 bytes**; `pkt_bytes = 1528` on the host. So **192 B = 24 words**, and
24 words = **1536 decoded info bits**; at the 15.36 MHz `enb_1_2_0` rail that is
**exactly 100.0 µs** [inferred]. `k = 2,3,5,6` therefore means 200/300/500/600 µs of
byte-plane content. *The 100 µs figure is offered as a lead, not a claim: it is a
consequence of 1536 and 15.36 MHz, and nothing in this task tests it.*

### 1.2 Two netlist facts that do the discriminating

**N1 — `short_frm` at the pins can only be caused by word loss downstream of the
`ByteSerializer`. [netlist]** `wordFirst` is asserted only on the word *following* a
`wordLast` (`ByteSerializer.v:290-296`: `heldFirst = firstNext; firstNext = wl`), and
`wordLast` fires only when `wordCnt` reaches 191, after which `wordCnt` resets to 0.
A `start` reset can only *delay* the next `wordLast`. **Two `wordFirst` marks
emitted by the serializer are therefore always ≥ 191 words apart**, so the
checker's `short_frm` condition (a `user` word while `widx ∈ [1,190]`,
`rx_seam_checker.v:74`) can never be produced by the serializer, however badly its
frame boundary is disturbed. It requires words to disappear between (c) and (f), or
a `wordFirst` bit to be corrupted in (d)/(e).

**N2 — DOWNGRADED. An orphan run of length L is consistent with the byte stream having
lost (191 − L) words at that point, but the pins say it did not. [netlist + inferred]**
The first draft read N2 as an equality: a missing `wordFirst` merges two frames at the
checker, so `L = 191 − D` with `D` the words removed from the mark-bearing gap; the
host's carve then shows the next magic at `8L`; therefore "the byte deficit per event =
8 × (191 − orphan_run) = 192k B, and the pin counter reads it directly".

**That last step does not survive §0(4).** A merge-by-deletion event produces an orphan
run and **no short** (the next mark arrives with `widx` already at 191), so the model
makes a checkable prediction at the pins: `D1 = 0`, equivalently
`acc_beats − 191 × frames = orphan`. The four forward legs give **`D1` = 49,437 words
at 5.7σ** (`acc_beats − 191 × frames` = +3,480 where the model needs +52,917). The same run length `L` is produced with **no** word loss by a
`wordFirst` that lands D = L words away from where it belongs (§1.4, H-MOVE), and that
shape also produces the paired short which the deletion model cannot
(§1.4). So N2 is retained as **one** reading of an orphan run, not as an inference from
it, and the phrase "the pin counter reads the byte deficit directly" is **withdrawn**:
what the pin counter reads directly is a **mark displacement of L words**. Whether that
displacement also costs bytes is a question about the stage that consumes `tuser`, and
this document does not answer it.

### 1.3 The seams, ranked

Verdicts: **EXCLUDED** = ruled out by a number; **LIVE** = still standing;
**DISFAVOURED** = argued against but not measured out.

| # | seam | what would vanish | for | against | verdict |
|---|---|---|---|---|---|
| **S1** | `RxDeint` `frameStart` displaced, or a `deintValid` hole | (b) emits fewer bits ⇒ (c) emits fewer words | the quantum is a *bit-count* quantum (1536 bits = 24 words), which is natural where bits are counted; the campaign's own frame-sync jumps live here | cannot produce `short_frm` (N1), and shorts fire 1:1 with the orphan runs on all nine legs | **LIVE** (as the driver of S3, insufficient alone) |
| **S2** | `RxAlign` emit window: `sk = skipCount + 41`, clamp `o < 12292` | same as S1 | `skipCount` (0x138) is a live, writeable input to this arithmetic (§2.4) | `skipCount` is static on both boards; same N1 objection | **LIVE, low** |
| **S3** | `ByteSerializer` word-count truncation by an early `start` | 24k words of that frame | reproduces the orphan run of `191 − 24k` exactly; the `start` reset explicitly *discards* the partial word (`ByteSerializer.v:250-254`) | N1: cannot make the shorts; no 24-word literal exists anywhere in (b)/(c) | **LIVE** |
| **S4** | (d) the four **separate** rate transitions: `tog`, `word`, `wLast`, `wFirst` cross 15.36 → 30.72 MHz on independent RT blocks | a mis-attached or corrupted mark (no word loss), or a missed push | a corrupted `wFirst` explains a short *without* word loss, which is the one shape that closes the short/orphan pairing with no second burst | words are ~129 fast cycles apart, so a 1-cycle skew cannot merge or drop a `tog` edge; never simulated | **LIVE** |
| **S5** | `ByteRxFifo` drop-oldest overflow (`ovfCnt` → AXI **0x1B0**) | a contiguous run of oldest words | the only structure in the plane that deletes words by design; the real-egress DMAC sim reproduces the *signature* (holes at slot 0) once the ready-low interval exceeds the FIFO depth [sim, `DMAC_SIM_RESULTS.md` §2] | the first draft's threshold (≈ 280 µs at 64 words) is **wrong for the images in this lineage**: every build tree from `txfixF3` on carries the v5-DEBUG drop-in with `parameter DEPTH = 4096` (`jupiter_byte_rxfixr4dr1_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_ByteRxFifo.v:29`), i.e. **17.2 ms** of buffering at 237,795 words/s, so the stall needed to delete D = 120 words is **≈ 17.7 ms, not ≈ 0.77 ms** — a **23×** move in the very threshold this column turns on. The same file's header puts S2MM backpressure at 0.25–2 ms with a tail to ~16 ms, which straddles both depths, so **neither depth cleanly excludes S5**. Drop lengths are still not quantised at 24 by anything in the RTL. **O1 is a prerequisite of this row, not an open item** (§3, closed by E2) | **LIVE** |
| **S6** | `ByteRxFifo` pop/ready skew: pop uses `ready_1` = pin `ready` delayed 4 clk, while `valid` is presented from FIFO state (`ByteRxFifo.v:68-72`) | ≤ 4 words per `ready` fall | a genuine handshake asymmetry in the shipped RTL | one `ready` fall per DMA transfer (≈ 78/s) × a 4/129 window ⇒ ~2.4 words/s, wrong shape and not quantised | **DISFAVOURED** |
| **S7** | `qpsk_traffic_gen_rx2` seam injector / `rx_byte_breakout` TLAST gate / Option-E tuser mask | whole beats | it is the only *deliberate* skip/corrupt engine in the plane | **downstream of the pins**; the deletion is measured *at* the pins (§0) | **EXCLUDED** |
| **S8** | `axi_dmac` S2MM: burst memory, resize, address generator, sync-transfer discard | a burst | the historic suspect | downstream of the pins (§0). Independently: the deletion is 24 beats of 64 bits = 192 B and no power-of-two burst size divides 192, so it is not a whole number of bursts at `MAX_BYTES_PER_BURST = 128` (16 beats) [sim-harness parameter set, **unverified against the BD**, which inherits everything but `CONFIG.CYCLIC` from TransceiverToolbox `matlab_processors.tcl:1061`] | **EXCLUDED** |
| **S9** | DDR carve / `qpsk_tun.c` drain | host frames | — | downstream of the pins; already excluded by Task 23 Q2/Q3 (ZEROTAIL = 0, `fzo == 0` count 0, events 1:1 at the pins) and Task 27 P7 | **EXCLUDED** |

**S7, S8 and S9 are one argument applied three times, not three verdicts.** All three
EXCLUDED rows rest on the single §0 pin measurement; they are **correlated, not
confirmatory**, and **S7 carries no number of its own at all** — under the brief's rule
that an excluded candidate must carry a number, S7's verdict is earned by §0 and by
nothing else. §0(4) has now changed what §0 says. The pins exclude all three as the
site at which the **`wordFirst` mark** goes wrong; they exclude **nothing** about where
the host's **byte deficit** is manufactured, because no bytes are missing at the pins to
begin with. In particular:

* **S8 is re-opened as a *cause*.** `rx_byte_dma`'s `SYNC_TRANSFER_START = 1` is the
  mechanism by which a displaced `tuser` becomes a carve-phase step (§0(4)), and that
  step is what `FWD_RESIDUAL_PHASE.md` reads back as a `k × 192 B` deletion. The
  verdict on S8 as the site of a **word** loss is unchanged; the verdict on S8 as the
  cause of the **host's** byte deficit is **LIVE**.
* **S5's drop-oldest, if it ever fires, is upstream of the pins but *driven* by
  `axi_dmac` ready-low at S2MM transfer boundaries** — this campaign's own recorded
  forward-comb mechanism (`comb-is-receiver-sro-defect`). Site and cause sit on
  opposite sides of the pins in that row too.
* Any summary that compresses this to "`qpsk_traffic_gen_rx2`, `rx_byte_breakout`,
  `axi_dmac rx_byte_dma`, the DDR carve and `qpsk_tun.c` are EXCLUDED BY MEASUREMENT"
  drops the site/cause distinction and is **wrong**. **The delivery plane is excluded
  as a site, not as a cause**, and the re-scoping of `FWD_RESIDUAL_0p22.md`'s class
  name must say so.

### 1.4 The one thing that did not close — and why it is no longer tied

**No single mechanism in the §1.3 table produces both a short and an orphan run per
event.** That much of the first draft stands: S3 (and S1/S2 through it) gives an orphan
run and no short (N1); S5/S6 give a short *or* an orphan run per burst, never both — a
contiguous drop of `D < 191` words that swallows a `wordFirst` gives an orphan run of
`191 − D` and no short, and one that does not gives a short with `191 − widx = D` and no
orphan. Yet the pairing is **1:1 in every interval of every leg**.

The first draft offered two ways out and called them tied. There is a **third** shape it
did not list, and §0(4)'s word budget — banked data, no build — separates all three.
Each is written here with the `acc_beats − 191 × frames` signature it is obliged to
produce, which is what makes them scoreable today:

* **H-FIFO** — each event is *two* word-loss bursts in (e)/(d), one swallowing a mark
  and one not. Predicts `bs_drop` advancing in pairs at 0.25 s⁻¹ (forward) and
  `bs_words` (serializer) conserved. **At the pins it additionally requires `D1 = 0`**:
  the mark-surviving burst's missing words would otherwise shift the host's carve phase
  on top of the mark-swallowing burst's, and §0(3)'s `magic_off = 8 × orphan_run` could
  not hold (§0(4), worked on T13: 88 B predicted against 568 B measured). **Measured
  `D1` = 49,437 words at 5.7σ: DISFAVOURED on banked data, before any build** — unless
  §0(3) is itself a coincidence, which is F4.
* **H-MARK (mark *added*)** — one deletion plus a **spurious extra** `wordFirst` in
  (d)/(e), which is how the first draft phrased it. A spurious *extra* mark costs no
  words but re-bases the checker **twice**, so on its own it makes **two** shorts and
  **no** orphan run — `D1 = 191` per spurious mark, contributing nothing to `orphan`,
  which drives `D1 / orphan` well above 1 and `Δshort` toward even counts. **Pooled
  `D1 / orphan` is 0.93 and single-short intervals are common (22 across the four
  forward legs): DISFAVOURED in this form.**
* **H-MOVE (mark *moved*) — new, and the shape the banked data picks out.** A single
  `wordFirst` displaced by D words with **no** word loss: the checker then records
  exactly one short (`191 − widx = D`) **and** exactly one orphan run (`L = D`) per
  event — which is §0(2)'s 1:1 pairing — and `D1 = orphan` identically, which is
  §0(4)'s measurement (`D1 / orphan` = 0.93 ± , slope on Δorphan 1.11 ± 0.18). It
  predicts, on BS1, `bs_words = 191 × bs_starts`, `bs_push = bs_pop`, `bs_drop = 0`,
  `bs_lasts = bs_starts`, and the mark chain broken at exactly one hop
  (`bs_lasts → bs_markpush → frames`).

**The tie is broken by data already on disk, and §4 must stop pretending otherwise.**
H-FIFO requires `D1 = 0` and `D1` is 49,437 words at 5.7σ; H-MARK-as-addition requires
`D1 / orphan` ≫ 1 and it is 0.93; **H-MOVE, which requires `D1 = orphan`, is the
surviving reading**. P5 therefore stops being "the
only registered item that decides it" and becomes a **confirmation** of a branch the
banked data has already ranked — which is a weaker role, and the honest one. Two
caveats kept in front of the reader: this ranking is **post-hoc** (§0(4)), and
`short_frm`/`orphan_w` still have **no positive control** (§2.4), so it is provisional.

A fourth possibility — the relation `magic_off = 8 × orphan_run` holding while the
shorts turn out to be an unrelated ~0.25 s⁻¹ background — is disfavoured by the 1:1
co-occurrence, is **not** excluded, and is *less* disfavoured than the first draft
implied now that §0(1)'s rate agreement is quoted at the ~10 % level rather than at
0.4–1.8 %. It stays registered as falsifier F4 in §4.

---

## 2. The instrument — RXFIX_BS1

### 2.1 Design rules it obeys

* Ride the **existing** W1 AXI read window and its single freeze bit; add no
  `TxRxCompo_ip` top-level port, no BD change, no GPIO segment (the cnt_mux32
  slots are **all 32 taken** — `cnt_mux32.v:1-9`, `SEQBIST_STATE.md` §0 — so the
  BD path is not available without a BD edit, which this design refuses).
* Read-only taps on existing nets. No net is redefined ⇒ the `s = 0` bit-identity
  sim gate stays structural, exactly as `W1_REGMAP.md` §4 argues for W1.
* Every counter differential (free-running, wrapping, read as deltas).
* Every counter has a positive control that fires on demand (§2.4).
* Fail closed: reserved bits are hard zero and the reader refuses to score if they
  are not — the rule that caught the R4D word swap (`W1_REGMAP.md` §6-R4D.2).

### 2.2 Counters

Seven taps in **`enb_1_2_0`** (clk/8, 15.36 MHz) and five in **`clk` gated by
`enb_gated`** (the ByteRxFifo's own domain). Nothing new is clocked on raw `clk`.

| name | width | tap | domain | rate | wrap horizon |
|---|---|---|---|---|---|
| `bs_words` | 32 | `ByteSerializer` `wv` (words emitted) | enb | 237,795 s⁻¹ | 5.0 h |
| `bs_starts` | 32 | `RxAlign.startOut` pulses (frame boundaries) | enb | 1,245 s⁻¹ | 39.9 d |
| `bs_push` | 32 | `ByteRxFifo` `push` (tog edges taken) | clk/enb_gated | 237,795 s⁻¹ | 5.0 h |
| `bs_pop` | 32 | `ByteRxFifo` `pop` (`valid_i && ready_1`) | clk/enb_gated | 237,795 s⁻¹ | 5.0 h |
| `bs_drop` | 32 | `ByteRxFifo` `drop` (drop-oldest) | clk/enb_gated | ≤ word rate | 5.0 h |
| `bs_lasts` | 16 | `ByteSerializer` `wl` (words carrying `wordLast`) | enb | 1,245 s⁻¹ | **52.6 s** |
| `bs_markpush` | 16 | pushes with `wFirst = 1` | clk/enb_gated | 1,245 s⁻¹ | **52.6 s** |
| `bs_trunc` | 16 | `start` pulses arriving with `1 ≤ state_wordCnt ≤ 190` — a **truncated frame** | enb | ~0.25 s⁻¹ | 73 h |
| `bs_trunc_last/min/max` | 8+8+8 | `state_wordCnt` at that `start` (0…191; `min` resets to 191, `max` to 0) | enb | — | — |
| `bs_q24` | 8 sat | truncations with `(191 − wordCnt) mod 24 == 0` | enb | — | saturates |
| `bs_dropmax` | 8 sat | longest contiguous `drop` run since reset | clk/enb_gated | — | saturates |
| `bs_bits` | 32 | `RxAlign.validOut` beats (decoded info bits emitted) — **optional, first to cut** | enb | 15.26 M s⁻¹ | 281 s |

**Widths are set by the horizon, deliberately.** `bs_starts` is the denominator of
every identity in §4 (P1, P6), so it gets a full 32-bit word rather than a packed
16-bit field: `W1_REGMAP.md` §5.2's own correction records that a counter at the
frame rate in a 15-bit field wraps in ~26 s and that "two consecutive dropped reads
alias silently", and the banked legs analysed in §0 *do* contain dropped reads (the
scorer discards intervals with `dt > 30 s`). The two remaining 16-bit frame-rate
fields (`bs_lasts`, `bs_markpush`) wrap in **52.6 s** — 5.3× the 10 s cadence and
still unambiguous across two consecutive dropped reads — and both are cross-checks,
not denominators. `w1_score.py` must flag any interval whose `dt` reaches 40 s.

Existing counters that complete the census and need **no new hardware**:
`frames`, `short`, `orphan`, `acc_user`, `acc_beats` (cnt_mux32 slots 0–7, already
in every `chk.jsonl`), the W1 census `cnt_SS…cnt_PC` (0x21C–0x230), and
`read_byte_fifo_ovf` at **0x1B0** (word 108 is a real read decode —
`TxRxCompo_ip_addr_decoder.v:168,444,604`).

### 2.3 Register map — nine read words, on the W1 read path

`address_select_level1 = addr_read[7:0]` is a **word** index; the host byte address
is `4 × word` (`TxRxCompo_ip_addr_decoder.v:227`). Occupied today: every literal
decode ≤ `0x84` (byte 0x210), plus `w1_hit = 0x85 … 0x8C` (0x214–0x230) and
`r4d_hit = 0x8D, 0x8E` (0x234, 0x238) — `addr_decoder.v:654-677`. **`0x8F` onward is
free**, verified by reading the decoder's own hit expressions.

| byte | word | name | fields |
|---|---|---|---|
| 0x23C | 0x8F | `BS_WORDS` | `[31:0]` `bs_words` |
| 0x240 | 0x90 | `BS_STARTS` | `[31:0]` `bs_starts` |
| 0x244 | 0x91 | `BS_PUSH` | `[31:0]` `bs_push` |
| 0x248 | 0x92 | `BS_POP` | `[31:0]` `bs_pop` |
| 0x24C | 0x93 | `BS_DROP` | `[31:0]` `bs_drop` |
| 0x250 | 0x94 | `BS_MARKS` | `[31:16]` `bs_lasts` · `[15:0]` `bs_markpush` |
| 0x254 | 0x95 | `BS_EVT` | `[31:24]` `bs_trunc_last` · `[23:16]` `bs_trunc_min` · `[15:8]` `bs_trunc_max` · `[7:0]` `bs_dropmax` |
| 0x258 | 0x96 | `BS_CNT` | `[31:16]` `bs_trunc` · `[15:8]` `bs_q24` · `[7:0]` **reserved, hard 0** |
| 0x25C | 0x97 | `BS_BITS` | `[31:0]` `bs_bits` — **optional** |

**Nine words, and a stated trim ladder.** The census needs five 32-bit counters at
the word rate or as a denominator (§2.2), so nine is the honest floor for the
questions §4 asks. If the build must shrink: **9 → 8** drop `BS_BITS` (loses P8, the
"bit hole vs early boundary" split, i.e. S1 vs S3 within the LIVE upstream branch);
**8 → 7** drop `BS_POP` (loses the ability to see word loss that is *not* counted as
a drop — S4's missed `tog` edge and S6's `ready_1` skew — leaving `bs_drop` alone to
speak for the FIFO). Do **not** trim `BS_STARTS`, `BS_WORDS`, `BS_DROP` or `BS_CNT`:
P5, the discriminator, is unreadable without all four.

**Marks at the pins need no new counter.** `frames` (cnt_mux32 slot 1) already
counts accepted `user` words at the DUT pins and is in every `chk.jsonl`. The mark
chain is therefore `bs_lasts` (emitted by the serializer) → `bs_markpush` (entering
the FIFO) → `frames` (accepted at the pins), which localises a mark that is lost or
invented to one of the two hops.

**Freeze.** All nine ride **W1's existing shadow level, `fixctl[4]` = 0x208 bit 4**
(`W1_REGMAP.md` §2), so one sweep is a coherent snapshot across the W1 census *and*
the byte-seam census — which is the whole point (the symbol-plane and byte-plane
counts must be compared in the same window). R4B/R4D's 0x234/0x238 stay outside the
shadow, unchanged.

**Write-only registers — restated, with one addition.** `0x158` (source),
`0x114` (rx_input_select), `0x118`, `0x10C` and `0x208` (fixctl) are write-only and
read `const_0`. This desk found a sixth: **`0x138` = `skip_count`**, decoded at
`addr_write == 14'b00000001001110` (word 78) with **no read decode**
(`addr_decoder.v:778-794`). The full write-only word list on this lineage is
`0x4, 0x10C, 0x110, 0x114, 0x118, 0x138, 0x158, 0x170, 0x174, 0x178, 0x17C, 0x180,
0x184, 0x1DC, 0x208`. **`FIXCTL_BASE` must be stated on every read**: a freeze write
sets the *whole* 32-bit fixctl word, so `w1_read.sh` writes `FIXCTL_BASE|0x10` to
freeze and `FIXCTL_BASE` to release; getting it wrong silently disarms `enSlack`
(bit 3) and flips the TXCAP/DEMODCAP muxes (bits 12/13) for the leg.

### 2.4 Positive control for EVERY counter — the campaign rule

No null is quoted without one. Controls are ordered as the W1/R4B legs order them:
loopback Step-2 controls first, then the air leg.

| counter | positive control | expected |
|---|---|---|
| `bs_bits`, `bs_words`, `bs_starts`, `bs_lasts` | **loopback leg, arithmetic identity**: per frame `bs_starts` +1, `bs_lasts` +1, `bs_words` +191, `bs_bits` +12,255 ± 1 | ratios exact; proves each counter and the AXI decode |
| `bs_trunc`, `bs_trunc_last/min/max`, `bs_q24` | **`skip_count` poke, 0x138 = 1536, loopback only, 2 s, then restore 0** [netlist-derived]: `RxAlign` then skips `1536 + 41` beats and emits 12,255 − 1536 = 10,719 bits ⇒ **167 words/frame** | `bs_trunc` at the frame rate, `bs_trunc_last = 167`, `bs_q24` advancing (191 − 167 = 24). **Saturated control — with every frame truncated, `wordLast` never fires, so tuser stops and byte delivery halts for the poke window. Loopback with the daemon down, bounded, explicit restore, never on a credited air leg.** |
| `bs_push`, `bs_drop`, `bs_dropmax` | **stall the seam**: disarm the drain (`SINK` off) or leave the RX DMA un-armed while the modem receives — `SEQBIST_STATE.md` §6 measured exactly this ("without a drain the seam stalls and every counter reads 0") | `bs_push` keeps advancing at the word rate, `bs_pop` stops, `bs_drop` starts at the word rate once the FIFO is full, `bs_dropmax` saturates |
| `bs_pop` | the same control, released: `bs_pop` resumes and `bs_push − bs_pop − bs_drop` returns to the standing occupancy | |
| `bs_markpush` | loopback: advances at exactly the frame rate and equals `bs_lasts`, and equals `frames` at the pins (slot 1) | any inequality in loopback is an instrument fault, reported before the air leg |
| `short`, `orphan` (existing), and §0(4)'s word budget | **NONE TODAY.** The drain-stall control proposed in the first draft cannot fire them — see the note below. A **bounded** stall/release can, and is specified below, but has never been run | — |
| `0x1B0` | read it in the same sweep; **its meaning must be established first** (§3, open item O1) | |

**The drain-stall control for `short_frm`/`orphan_w` cannot work, and its own citation
says so.** The first draft's row offered "a ready-low burst must produce shorts and
orphans at the pins", citing `SEQBIST_STATE.md` §6. That citation
(`two_jup/SEQBIST_STATE.md:282-283`) actually reads: *"Without a drain the seam stalls and
every counter reads 0 while 0x104 runs at line rate (measured: 0x104 +179,274 with
`chk_frames` 0)."* `rx_seam_checker.v:40` gates **every** checker counter on
`acc = valid && ready`; while `ready` is low **nothing is accepted**, so `short_frm` and
`orphan_w` are **structurally frozen at 0** for the whole stall. The cited measurement
is the *proof that the control cannot fire them*, not support for it. Withdrawn. (The
same stall remains a valid control for `bs_push`/`bs_drop`/`bs_dropmax`, which live in
the FIFO's own domain and are not gated on the pins' `ready`.)

**What could work: a BOUNDED stall, scored on the RELEASE side.** Hold the drain off for
T ms, release, and score the **first sweep after release**, never the stall itself:

* the deletion is created *during* the stall by the `ByteRxFifo` drop-oldest once the
  FIFO fills, and its size is `D ≈ (T − DEPTH / R) × R` words at `R = 237,795 words/s`.
  **`DEPTH` is open item O1** — 64 words ⇒ the threshold is 0.27 ms, 4096 ⇒ 17.2 ms —
  so **O1 must be closed before the control can even be sized**. That is why O1 is a
  prerequisite of §1.3/S5 and why E2 comes first.
* **release-side prediction, pre-registered here:** for a single contiguous deletion of
  `D < 191` words the pins must show **exactly one** anomaly, not two —
  `Δshort = 1, Δorphan = 0` (the mark survived, and `191 − widx = D`) **or**
  `Δshort = 0, Δorphan = 191 − D` (the mark was swallowed) — and the word budget must go
  **negative** by exactly the deletion: `Δacc_beats − 191 × Δframes = −D` in the first
  case and `= 191 − D` in the second. A stall that produces **both** a short and an
  orphan run from one deletion would falsify §1.4's whole enumeration.
* **rails:** `T ≤ 50 ms`, fabric loopback with the daemon down, explicit release, a
  verified-by-effect check that delivery resumes, and **never on a credited air leg** —
  a *sustained* drain stall is the #48 wedge trigger
  (`qpsk_traffic_gen_rx2.v:8-10,108-114`), which is exactly why the control has to be
  bounded and why the first draft's unbounded version was unsafe as well as inert.

**Until that is run, `short_frm` and `orphan_w` have NO positive control, and every
conclusion in this document that rests on them is PROVISIONAL** — that is §0(1), §0(2),
§0(3), §0(4), the S7/S8/S9 verdicts in §1.3, and §1.4's ranking. What *is* established is
**liveness** (they fire on all nine legs, at the host's event rate) plus one exact
internal cross-check (`frames` − verdicts = `short`, §0(4)). What is **not** established
is that they can be made to fire by a known cause, which is the campaign's standing
rule, and §6 concern 2 has been open since the counters were first read. The same
bounded control is the **only** positive control for §0(4)'s word budget, whose
falsifiable signature is `acc_beats − 191 × frames` going negative under a known
deletion.

**The remaining gap, stated rather than solved.** There is still no on-demand control
that produces a *single* 24-word event, because nothing in the shipped image can inject
one: the `skip_count` control saturates (every frame) and the stall control is not
quantised at 24. So a null on `bs_trunc` with `bs_drop` advancing is informative, and a
null on **both** is a "counters did not increment" report, not a finding — exactly the
wording Task 10 used for `push_on_full`.

### 2.5 How it composes with the readers in `two_jup/rxfix/`

* **`w1_read.sh`** gains `BS=1` (default 0). With `BS=1` the freeze window sweeps
  0x23C–0x25C alongside W1's eight words and R4B/R4D's, in **both** frozen sweeps,
  and the existing `freeze_effective` test (all words' deltas exactly 0 between the
  two sweeps) extends to them for free. `FIXCTL_BASE` and `EXP` are already
  mandatory arguments; `BS=1` additionally requires `EXP` (image-keyed, like
  `R4D_SWAP`).
* **`w1_score.py`** gains `bs_*` and `d_bs_*` columns, the wrap horizons of
  §2.2 (the tight pair is the 16-bit `bs_lasts`/`bs_markpush` at **52.6 s**; the
  reader must flag any interval whose `dt` reaches 40 s), and the three conservation
  identities of §4. It **fails closed**: `BS_CNT[7:0]` is hard zero in the RTL and
  `BS_EVT`'s three order-statistic bytes are bounded by 191; a non-zero reserved
  field or an out-of-range order statistic gives `DECODE_FAIL` with no rate quoted
  — the check that caught the R4D word swap.
* **`w1_ctl.py`** gains one BS verdict block (the §4 predictions, pass/fail per row).
* **`w1leg_go.sh`** passes `BS`/`EXP` through, as it already does for `R4B`/`R4D`.
* **The chk reader is unchanged** — `short`, `orphan`, `frames`, `acc_user`,
  `acc_beats` are already in `chk.jsonl`. Add one line to sweep `0x1B0`.
* **Address-map pinning**: a `test_bs_words_land_at_the_canonical_addresses` that
  resolves the map from the *generated Verilog text* (the shape of
  `test_164_r4d_words_land_at_the_canonical_addresses`), because the read-mux index
  is this campaign's proven bug class — `r4d_reg[address_select_level1[0]]` swapped
  two words on a flashed image (`W1_REGMAP.md` §6-R4D.2).

---

## 3. What it costs

**Build.** The R4B/R4D chain, unchanged:

```
# injector must be committed first -- the kit refuses a dirty rxfix_inject.py
RXFIX_VARIANTS='W1 R4B BS1' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148
#   -> jupiter_byte_rxfixbs1_build, from SRC jupiter_byte_seqbist_build
#      (jupiter_byte_rxfix_kit.sh:67), i.e. the F3 -> SEQ-BIST -> W1 lineage
# then the kit's build_txfix.{tcl,sh} on hdl-dev-2, IMPL_STRATEGY=explore
```

`two_jup/skidfix/rxfix_inject.py` gains an `RXFIX_BS1` variant: eight counters, one
64-bit-per-word witness bus, the witness-carry chain, and one rewrite of the single
`assign data_read` in `TxRxCompo_ip_addr_decoder.v` (the R4B/R4D pattern,
`W1_REGMAP.md` §5.1). ~1 h of build wall time, matching Task 13/22.

**Timing risk — moderate, and higher than R4B's.** Precedent gates, all on the
**modem-clock intra-clock post-route WNS** (the overall `TXFIX_ROUTED_WNS` is the
vendor IDELAYCTRL path and is *not* the gate): W1 **+0.169**, SEQ-BIST **+0.227**,
R4B **+0.437**, R4D+R1 **+0.620** ns. BS1 adds ≈ 260 flops (four 32-bit counters,
four 16-bit, four 8-bit) plus an 8-way read mux. Three named risks:

1. **Hierarchy depth.** `bs_bits`/`bs_starts` tap inside
   `Receiver/QPSK Rx/FEC Decoder Wrapper/RxAlign` — **hierarchy level 4**, one
   deeper than R4B's Rate_Handle witness, so the carry chain is
   `RxAlign → FEC_Decoder_Wrapper → QPSK_Rx → Receiver → TxRxComposite → IP`.
   Mitigation: drop `BS_BITS` (§2.3) and the chain shortens to R4B's depth.
2. **Domain crossing.** `bs_push/pop/drop/markpush` are in the FIFO's
   `clk`+`enb_gated` domain and the rest in `enb_1_2_0`; the shadow registers are
   sampled in one domain. Both are `clk`-synchronous with different enables, so this
   is an enable-domain crossing, not a true CDC — but it must be declared and the
   `cdc_exceptions.xdc` in the kit reviewed rather than assumed.
3. **Read-mux index.** The Task 33 bug class. Pinned by the generated-text test
   (§2.5) before the build is credited.

**Utilisation.** Negligible against R1's saving (R1 retired a 49,332-flop shift
register on the 146 lineage).

**Flash.** A new image **needs an operator-run flash** — the controller's flash
path is blocked by the permission classifier (`RXFIX_STATE.md` Day 2, Task 36).
148 first (the forward leg is the cleaner measurement: 0.079 % and no display
comb). Rails: the standard chain, GATE_PASS ×2, rollback **`9f13705d9fb0`** banked
and on-board for 148 (**`9acbe2ebe1db`** for 146). BS1 changes no data-path net, so
the fix behaviour of R4B is unchanged by construction and the flash is a pure
instrument flash.

**Open items this desk could not close.**

* **O1 — which `ByteRxFifo` is in the flashed images.** Every build tree in the
  lineage (`txfixF3` → `seqbist` → `rxfixw1` → `rxfixr4b` → `rxfixr4dr1`) carries the
  injected **v5-DEBUG** drop-in (4096-word BRAM, and **0x1B0 repurposed from a
  32-bit `ovf` count to a handshake-state word**: `[31:24] rdyRun, [23] ready_1,
  [22] valid_i, [21] ready, [20] stateControl_2, [19] enb, [18] nonempty,
  [17] byp_sel, [16] ovfCnt!=0, [15:8] wr[7:0], [7:0] rd[7:0]`), all with the same
  rsync-preserved mtime 2026-08-28 03:03:46 — but the same file's own header says
  the v4 diagnostic flash showed "the read side is dead on silicon", which cannot be
  true of a working link. **[unverified]** — mtimes cannot date the injection
  relative to the F3 bitstream. Cheap test, no build: read 0x1B0 on 148 once. A v5
  debug word has `[31:24]` pinned at 0xFF (saturated `rdyRun`) and a low half that
  is a pair of pointers; a generated-FIFO `ovf` is a small monotonic count.
  **O1 is a PREREQUISITE, not an open item to carry past a build.** The first draft
  said "the BS1 design deliberately does not depend on the answer". That is true of the
  **counters** — `bs_drop`, `bs_push` and `bs_pop` are BS1's own, not a re-read of
  0x1B0 — and **false of the ranking**: §1.3's S5 row turns on a stall threshold that
  moves by **23×** between the two candidate depths (0.27 ms at 64 words vs 17.2 ms at
  4096), and §2.4's bounded-stall control cannot be *sized* without it. O1 is therefore
  promoted to a prerequisite of §1.3 and of §2.4, and E2 is the action that closes it.
* **O2** — the `MAX_BYTES_PER_BURST = 128` figure used in §1.3/S8 is the sim
  wrapper's self-description, not read out of the BD. S8's exclusion as the **site of a
  word loss** does not depend on it (no power-of-two burst divides 192, and the pin
  measurement settles it). S8 as the **cause of the host's byte deficit** is a different
  question, is **LIVE** after §0(4), and *does* now want the BD read — specifically
  `SYNC_TRANSFER_START`, `CYCLIC` and `X_LENGTH`, none of which this desk has read out
  of the BD. **[unverified]**

---

## 4. Pre-registered predictions for the first BS1 silicon read

Registered **before any BS1 build exists**. Leg shape: 148 on
`W1+R4B+BS1`, forward 146 → 148, `w1leg_go.sh MODE=air LEG=A BOARD=148 DUR=600
BS=1 R4B=1 EXP=<md5-12> FIXCTL_BASE=0x0`, reads every 10.000 s, PER by
`accept_analyze.py` with lost frames in the denominator, plus the Step-2 loopback
controls of §2.4 first. Reference numbers are the T13/T27 forward legs:
0.25 events/s, `magic_off` mode on the 192-lattice, PER 0.079 %.

| # | prediction | why it is a bet |
|---|---|---|
| **P1** | Loopback: `bs_words / bs_starts = 191.0 ± 0.01`, `bs_lasts = bs_starts ± 1`, `bs_bits / bs_starts = 12,255 ± 2`, `bs_push = bs_words ± 1`, `bs_pop = bs_push ± 32`, `bs_drop = 0`, `bs_trunc = 0`, `bs_markpush = bs_lasts = frames ± 1` | the whole instrument's credit; any failure stops the leg |
| **P2** | `skip_count = 1536` control: `bs_trunc` at the frame rate, `bs_trunc_last = bs_trunc_min = bs_trunc_max = 167`, `bs_q24` advancing, and byte delivery halts (no `wordLast` ⇒ no tuser) and resumes on restore | a falsifiable, on-demand synthesis of the truncation class |
| **P3** | Air leg: `Δshort ≥ 1` and `Δorphan ≥ 47` in the same 10-s interval, **never one without the other** — reproducing §0(2) on a fresh leg | the observation this task rests on; a fresh-leg replicate |
| **P4** | `191 − (Δorphan per single-short interval)` is a **multiple of 24** in ≥ 80 % of single-short intervals | the 24-word lattice, measured in the fabric rather than inferred from `magic_off`; prior on a random run length is ~1/24. **The threshold is left at 80 % deliberately.** Denominators, stated: scored over the single-short intervals of the four 148 forward legs (T13 3 + T27 leg A 3 + T27 leg B 6 + T10 10 = **22 intervals**, of which 15 are on the 24-word lattice = **68 %**); over **T10's 10 intervals alone**, 4/10 = **40 %**; over the three legs the first draft quoted, 11/12 = 92 % (§0(3)). So P4 as written would FAIL on today's four-leg data and pass on the first draft's three, and it is not re-tuned to fit |
| **P5** | **THE DISCRIMINATOR.** Exactly one of: <br>**(a) H-FIFO** — `bs_drop` advances at **2 × the event rate** (≈ 0.5 s⁻¹ forward), `bs_dropmax ≥ 24`, `bs_trunc = 0`, and `bs_words = 191 × bs_starts` (serializer conserved); <br>**(b) H-MARK / H-MOVE** — `bs_drop = 0`, `bs_push = bs_pop` to within the standing occupancy, `frames` (pins) ≠ `bs_markpush` ≠ `bs_lasts` (marks not conserved along the chain), and `bs_trunc` **either** at the event rate with `(191 − bs_trunc_last) mod 24 == 0` (a deletion plus a mark fault, H-MARK) **or at 0** (a mark moved and nothing deleted, H-MOVE — §1.4's surviving branch, which §0(4) already favours); <br>**(c) H-UPSTREAM** — `bs_trunc` at the event rate with `bs_drop = 0` **and** marks conserved, i.e. the shorts come from somewhere this instrument does not see | separates §1.4's readings on one leg. **Restated in fix round 1:** it is no longer the *only* item that can, and it is no longer a tie-breaker between equals — §0(4) has already ranked H-MOVE above H-FIFO on banked data, so P5's job is to **confirm or overturn** that ranking. Its `bs_trunc` split within (b) is the part that is genuinely new |
| **P6** | **Conditional on the W-rule below selecting branch (i).** *On that branch only*, `bs_words − 191 × bs_starts` per 10 s equals `−24 × (the number of events) × k̄` to within ±24, with the same sign as the host's deletion. On branches (ii)–(iv) P6 is **not** scored | the word-plane deficit, measured in the fabric, must equal the host's `1528 − magic_off` budget — but only if there *is* a word-plane deficit, which §0(4) says there may not be |
| **P7** | W1's symbol-plane census (`cnt_SS … cnt_PD`) stays conserved (0 of N stage-readings short) across the same events — as it did on the R4B leg | the byte-seam event is **not** a symbol deletion; if it were, Task 10's census would already have caught it |
| **P8** | `bs_bits / bs_starts` is **constant to ±64** across the events | separates "a hole in the decoded-bit stream" (S1) from "an early frame boundary" (S3): a hole shortens `bs_bits`, an early boundary does not change bits per start by more than one word |
| **P9** | PER, comb and R4B witnesses are unchanged from the T13/T27 legs (PER 0.06–0.10 %, `r4b_skips` 394 ± 60 per 10 s, `pop_on_empty` 0, occupancy 8–10) | BS1 is read-only; a change means the instrument perturbed the receiver |
| **P10** | **§0(4) replicates on a fresh leg**: `acc_beats − 191 × frames` stays within ±2,000 words per ~470 s with events present (pooled forward reference: +3,480 over 447 M words, 7.8 ppm), the pooled regression `D1` on `Δorphan` keeps a slope consistent with 1.0, and `bs_push − bs_pop − bs_drop` returns to the standing occupancy | §0(4) is **post-hoc**; this is its forward registration. It is also the one prediction whose failure re-opens the H-FIFO branch |

**The W-rule — one reading of one measurement, replacing three conflicting ones.**
The first draft assigned three different verdicts to the same quantity: P6 declared
`bs_words − 191 × bs_starts` to *be* the deficit unconditionally, P5(a) predicted that
same expression to be **zero** under H-FIFO, and F5 declared that same zero, with host
displacements still present, a **falsifier of the whole story**. A leg returning
`bs_words = 191 × bs_starts` therefore failed P6, confirmed P5(a) and tripped F5 at
once: the pre-registration was not scoreable. It is replaced by a single rule. Define

```
W ≡ bs_words − 191 × bs_starts   (per 10 s)
M ≡ the mark chain  bs_lasts → bs_markpush → frames  (conserved / broken, and at which hop)
```

and score **W once**, with `M`, `bs_drop` and `bs_dropmax` read in the same frozen sweep:

| | observed | branch | consequence |
|---|---|---|---|
| **(i)** | `W ≈ −24 k̄ × events` | **H-UPSTREAM** — the deficit is in or before the serializer (S1/S2/S3) | **P6 is scored and must pass.** P5 returns (c) |
| **(ii)** | `W ≈ 0`, `bs_drop` at ≈ 2 × the event rate, `bs_dropmax ≥ 24` | **H-FIFO** — deletion downstream of the serializer, in the FIFO | P5 returns (a). P6 is not scored. **F5 does NOT fire** |
| **(iii)** | `W ≈ 0`, `bs_drop = 0`, `M` **broken** at exactly one hop | **H-MARK / H-MOVE** — §1.4's surviving branch and §0(4)'s reading | P5 returns (b). P6 is not scored. **F5 does NOT fire** |
| **(iv)** | `W ≈ 0`, `bs_drop = 0`, `M` **conserved** | nothing this instrument can see | **F5 fires** — and only here |

So: **`W ≈ 0` is not by itself a falsifier**; it is a falsifier only when the mark chain
is *also* conserved, because that is the only combination in which the instrument has
looked everywhere it can look and found nothing. F5 below is restated to say exactly
that, and P6 above is restated as conditional on branch (i). §0(4) has already made
branch (iii) the favourite from banked data, which is a **second, independent** reason
the original three-verdict wording could not be scored: it presented as undecided a
question the desk's own data had already ranked.

**Falsifiers.**

* **F1 — every BS1 counter reads 0 on the air leg while the loopback controls
  passed.** The taps are on the wrong nets; report as "counters did not increment"
  and re-cut, do not report a null.
* **F2 — `Δshort` and `Δorphan` decouple** (intervals with one and not the other,
  > 10 % of intervals). §0(2) does not replicate; the paired-anomaly model of §1.4
  is withdrawn and the seam list must be re-ranked from P5 alone.
* **F3 — `191 − Δorphan` is off the 24 lattice in > 50 % of single-short
  intervals.** The 24-word quantisation is not a property of the fabric event, and
  `FWD_RESIDUAL_PHASE.md` §1.3's lattice must be re-read as a host-side artefact.
* **F4 — `bs_trunc = 0` and `bs_drop = 0` on a leg with events present.** The
  deletion is in neither the serializer nor the FIFO: the surviving sites are the
  four rate transitions (S4) and the FIFO's collision/bypass path, and the next cut
  is a beat-level trace, not a counter.
* **F5 (restated) — `bs_words = 191 × bs_starts` while the host still sees k × 192 B
  displacements AND the mark chain `bs_lasts → bs_markpush → frames` is conserved AND
  `bs_drop = 0`.** That is branch (iv) of the W-rule, and only branch (iv). No words are
  missing at the serializer output and no mark is lost or invented anywhere the
  instrument can see, so either the deficit is created somewhere BS1 does not tap or the
  §0 relation is coincidence; re-open S4/S5 and re-check `magic_off = 8 × orphan_run` on
  the new leg before anything else. `bs_words = 191 × bs_starts` **with** the mark chain
  broken is **not** F5 — it is the predicted result on §1.4's surviving branch.
* **F6 — the loopback control `skip_count = 1536` does not move `bs_trunc`.** The
  truncation counter is dead; no null from it is quotable.
* **F7 — `acc_beats − 191 × frames` on the next forward leg is ≈ `−(events × 24 k̄)` or
  ≈ `+orphan`, not ≈ 0.** §0(4)'s word conservation does not replicate; the
  word-deletion shapes are back, §0(4) is **withdrawn**, §1.4 reverts to tied, and the
  headline reverts to "the deletion is born at or upstream of the pins".
* **F8 — the bounded stall/release control (§2.4) fires `short_frm`/`orphan_w` but does
  NOT drive `acc_beats − 191 × frames` negative by the known deletion size.** Then the
  word budget does not measure word loss and §0(4) cannot be used to rank §1.4 at all.

**A falsifier that can actually move the top conclusion — and it has already fired.**
Walking F1–F6 against the first draft's headline ("the k × 192 B deletion is born at or
upstream of the DUT RX byte pins; `qpsk_traffic_gen_rx2` / `rx_byte_breakout` /
`axi_dmac` / the DDR carve / `qpsk_tun.c` are EXCLUDED BY MEASUREMENT") shows that **not
one of them can put the deletion downstream of the pins**: F1 is instrument failure,
F2 and F3 withdraw §0(2) and §0(3) as sub-claims, F4 and F6 re-rank *among upstream
sites*, and F5 re-opens S4/S5 — also upstream. That was a real hole in the
pre-registration: a set of falsifiers none of which can touch the claim they are
attached to.

The measurement that **can** move it is the pin word budget, and it needed no build:
**if `acc_beats = 191 × frames` while the host still reports a `k × 192 B` deficit,
then no words are lost between the `ByteSerializer` output and the pins, and the host's
byte deficit — for the events the pins do see — is manufactured downstream of them.** It is obtainable entirely from banked data, it *was* obtained (§0(4)), and it
fired: `acc_beats − 191 × frames` = **+3,480 over 447 M accepted words (7.8 ppm)** —
i.e. `D1 = orphan` to 7 % — where a real word deletion, given §0(3), would require
`D1 = 0`. The top conclusion is therefore already re-scoped —
from *"the k × 192 B deletion is born at or upstream of the pins"* to **"a mark
displacement is born at or upstream of the pins; the host's byte deficit is downstream
of them and its site is not yet measured"** — and it is registered forward as P10/F7 so
the next leg can move it back.

**And BS1 tests the ranking, not the localisation.** Every outcome of the proposed BS1
leg re-ranks sites *within* the upstream branch; none of them can place the mark anomaly
downstream of the pins, because the pins are where it is already measured. §5's ordering
ruling (E2 and E3 before a build) is unaffected and stands.

---

## 5. Cheaper experiments before any build

Ranked by cost. **The first has already been run; the second and third need no
build and no flash.**

**E1 — the banked pin counters. DONE at this desk (§0).** Cost: one Python pass over
files already on disk. Result, as corrected in fix round 1: a **mark anomaly** is at or
upstream of the DUT byte pins, which excludes S7/S8/S9 as the **site** of that anomaly;
and the pins' word budget (§0(4)) shows the mark-to-mark word count **conserved between
the serializer output and the pins**, which **re-opens the delivery plane as the cause**
of the host's byte deficit and disfavours
the H-FIFO branch of §1.4 before any build (H-FIFO needs `D1 = 0`; `D1` is 49,437 words
at 5.7σ). `python3
two_jup/comb/byteseam_pins.py`, plus the §0(4) arithmetic on the same `chk.jsonl`
fields. Both results are **provisional**: the two counters they rest on still have no
positive control (§2.4).

**E2 — read `0x1B0` and slots 0–7 on one ordinary leg. No build, no flash, no image
change.** `short`/`orphan`/`acc_user`/`acc_beats` are already in `chk.jsonl`; the
only addition is one `direct_reg_access` read of `0x1B0` per sweep. This closes
**O1** (which `ByteRxFifo` is in the image, from the bit shape of the word) and, if
0x1B0 is a genuine `ovf` count, it **answers half of P5 before any build**: an `ovf`
delta at ~0.5 s⁻¹ on a forward leg is H-FIFO; a flat `ovf` with events present sends
S5 to DISFAVOURED. Cost: one line in the reader and one credited leg. **This is the
single highest-value action available today**, and fix round 1 gives it two more jobs:
it closes the **146 provenance question** §0(4) had to caveat (does `acc_beats` on 146
come from a `traffic_gen_rx` that `patch_seqbist_tcl.py:71` says does not exist?), and
its `0x1B0` word sizes the **bounded stall/release control** of §2.4, which cannot be
run until `DEPTH` is known.

**E3 — the real-egress DMAC sim, `jupiter_240k5_byte/rtl_sim/run_dmac_sim_rtl.sh`.**
The harness contains the **real** byte-RX egress RTL — the `_tc` clock-enable block,
the four `Ser*RT` registers, the real `ByteRxFifo` (both the original 64-word and the
BRAM drop-in), the 4-stage `delayMatch` chains, the breakout TLAST gate and the
Option-E tuser mask — plus the real `axi_dmac` and a host model that replays
`qpsk_tun.c` (`DMAC_SIM_RESULTS.md`). It can therefore test **S4, S5 and S6**
directly: instrument the harness's pin monitor with the `short_frm`/`orphan_w`
logic (`rx_seam_checker.v` is already in `rtl_sim/`, and `tb_rx_seam_checker.v`
exists), then sweep the ready-low stall duration and ask **which stall lengths
produce a 1:1 short/orphan pair with an orphan run on the 24 lattice**. If no stall
profile reproduces the pairing, H-FIFO is refuted in sim before a single flop is
built. **§0(4) sharpens the target**: the harness must be scored on
`acc_beats − 191 × frames` as well as on the pairing, because a stall-driven deletion
must drive that quantity **negative** while the silicon holds it at zero. A sim that
reproduces the pairing but not the word conservation has reproduced the wrong event.
The same sweep is the sim-side rehearsal of §2.4's bounded control. Cost: a few hours
of desk work, no board.
**Limit, stated:** the harness **emulates** the serializer ("word held, tog flips
once per word, never backpressured") and contains **no `RxAlign` and no
deinterleaver**, so it **cannot** test S1/S2/S3 at all. That is a limit of the
harness, not a step to skip.

**E4 — the `skip_count = 1536` poke on the shipped image, loopback only.** No build,
no flash. It synthesises the truncation class on demand and lets the *existing* pin
counters and the *existing* host `magic_off` census be checked against a known
answer: with 167 words per frame the marks stop entirely, so the sharper variant is
a poke of `skip_count` chosen to leave `wordLast` intact — **and there is none**,
because any `skipCount > 0` drops the frame below 191 words. So E4 is a
*saturated* control only: it proves the causal chain
`skip → fewer bits → fewer words → no wordLast → no tuser → delivery stops`, which
is worth having before trusting `bs_trunc`, and it must be run in fabric loopback
with the daemon down, bounded in time, with an explicit restore of `0x138 = 0` and a
verified-by-effect check (delivery resumes). **Not on a credited air leg, and not
while a validation leg is on the rig.**

**Ordering recommendation.** E2 first (one leg; closes O1, closes the 146 provenance
caveat, sizes §2.4's control, and pre-tests P5), E3 in parallel at the desk, E4 only if
E2/E3 leave the §1.4 branches still tied. Build BS1 only after E2 and E3 have reported —
on the current evidence a build is *not* yet the cheapest next step, and after §0(4) it
is less so: the branch BS1 was designed to discriminate has already been ranked from
banked data, and what is missing is a **positive control** (§2.4) rather than more
counters.

---

## 6. Concerns

1. **§0(3) rests on 22 single-short intervals across four forward legs** (6 + 3 + 3 +
   10), of which **15 are on the 24-word lattice**, not the 11/12 the first draft
   quoted from three legs. The aggregate `orphan/short` ratios (70.4 / 73.7 / 127.8 /
   124.0 against `magic_off/8` = 71 / 71 / 119 / —) support the relation on the
   47-interval totals of the three legs with a usable host log, but the exact lattice
   values come from the small single-short subset, and T10 would fail P4's 80 %
   threshold at 40 %. P3/P4 re-test it on a fresh leg.
2. **`orphan_w` and `short_frm` have never had a positive control — and the fix
   proposed in the first draft could not have provided one.** They fired on nine air
   legs, which is liveness; no test has ever *made* them fire on demand, and the
   drain-stall control cited to close this concern is structurally incapable of it
   (§2.4). The bounded stall/release specified in §2.4 is the replacement and has not
   been run. **This concern is not closed, and every §0 conclusion is marked provisional
   because of it.**
3. **WITHDRAWN — "`acc_beats` is a different tap in a different place" is false.** The
   first draft declined to quote the word budget `191 × frames + orphan − acc_beats` on
   the ground that slot 7 is `qpsk_traffic_gen_rx2`'s counter rather than the pins'.
   With the injector disabled — its reset state, and `acc_user ≈ frames` on every leg
   confirms it — the injector is pure pass-through and `acc_beats` increments on
   **the same combinational condition in the same cycle** as the checker's
   `acc = valid && ready` (`qpsk_traffic_gen_rx2.v:99,114,119-125` against
   `rx_seam_checker.v:40`). The budget is an exact identity at the pins, it is now
   §0(4), and it changes §1.4's ranking. The lesson recorded rather than smoothed over:
   **the desk had a falsifier, ran it, got an answer that contradicted its headline, and
   set it aside on a premise its own netlist disproves.**
4. **The reverse legs are not clean enough for the single-short test** — the
   display-off leg has no single-short intervals in 35, and the display-on legs mix
   in the 20.38 ms comb. Every §0(3) number is forward-leg only. §0(4) is also
   forward-leg only, for a **different** reason: the provenance of `acc_beats` on the
   146 lineage is contradicted by `patch_seqbist_tcl.py:71,428` and is unresolved.
5. **Nothing here identifies the mechanism**, only the site and the shape. §1.4 is an
   honest non-closure — but it is **no longer a tie**: §0(4) disfavours H-FIFO from
   banked data (it needs `D1 = 0`; `D1` is 49,437 words at 5.7σ), so §4's P5 is a
   **confirmation** of the H-MOVE branch rather than
   "the only registered item that resolves it". The first draft's claim that P5 was the
   sole discriminator is withdrawn.
6. **The strongest support for the site claim is not in §0(1) or §0(3), it is the
   pin-health cross-check** (§0(4), last table): pin bad fractions of 0.0675 / 0.0550 /
   0.0602 % against a host PER of 0.079 %, and un-verdicted frames equal to `short`
   exactly on two legs and 118 against 119 on the third. That is a tighter agreement
   than either rate quoted in §0(1), and it is recorded as support.
7. **§0(4) is post-hoc.** It was computed after §4's P1–P9 and F1–F6 were written, on
   the same banked legs that motivated them. It is registered forward as P10/F7 and must
   not be quoted as a pre-registered result. The `SYNC_TRANSFER_START` re-phasing story
   that would complete it is **[unverified]** and is not quoted as a finding at all.
