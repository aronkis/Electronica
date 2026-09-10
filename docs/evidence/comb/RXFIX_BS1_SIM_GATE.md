> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_BS1_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_BS — sim gate PRE-REGISTRATION  [sim, desk only]

**RXFIX Task 46.** The byte-seam census instrument of `BYTESEAM_INSTRUMENT.md` §2, cut
as injector variant **`BS`** and gated in Verilator. **NO board contact, no Vivado, no
flash.** Every prediction in §3–§6 was written and this file md5-stamped **before any
scored leg was launched**; `runall_bs.sh` echoes that md5 into every leg log at launch
(`BS_PREREG_MD5`), which is how a single commit can still show the order. The **only**
runs that preceded it are (a) a 25-air-frame plumbing smoke on `n_p000` that checked the
dump file appears and parses, and (b) the injector unit tests — neither contributes a
number to §3–§6.

Companions: `BYTESEAM_INSTRUMENT.md` (the design and the pre-registration this extends),
`two_jup/rxfix/W1_REGMAP.md` §7-BS (the register map), `RXFIX_R4D_SIM_GATE.md` and
`RXFIX_S1_SIM_GATE.md` (the gate shape this copies), `two_jup/skidfix/rxfix_inject.py`
(the `RXFIX_BS` header, where every deviation from §2 is recorded).

---

## 0. What this gate is for, and what it cannot do

BS is an **instrument**, not a fix. The gate therefore has to answer three questions and
no others:

1. **Does it change the receiver?** It must not. (§3, the identity legs.)
2. **Do the counters count what they claim?** Against a recount the harness makes from
   nets that pass through no BS logic. (§4.)
3. **Can each counter be made to fire on demand?** The campaign's binding rule: a
   counter with no positive control cannot produce a null result. (§5, §6.)

**What it cannot do.** It cannot close **O1** (which `ByteRxFifo` is in the *flashed*
image); nothing at a desk can. It cannot tell you where the host's `k × 192 B` byte
deficit is manufactured — that is downstream of the pins and outside both the instrument
and this harness. And it is **not** an air leg: the stimulus is banked `n_*.iq`, so the
event `short_frm`/`orphan_w` fire on in air legs is **not** present here. What §6 does is
strictly narrower and has never been done anywhere: it **synthesises** a deletion of a
known size and shows the pin counters and the word budget respond to it.

## 1. The three binaries, and why there are three

| object dir | RTL tree | define | what it is for |
|---|---|---|---|
| `obj_byte_sro_bs_gen` | `s1_rtl_bs_gen` — **verbatim** `s1_rtl` (generated 64-deep `ByteRxFifo`) | — | **wrapper transparency.** Its `n_p000` leg must be byte-identical to task 7's banked `b_p000_frames.txt`, which the SAME driver produced on the SAME RTL through a DIFFERENT wrapper |
| `obj_byte_sro_bs_base` | `s1_rtl_bs_base` — `s1_rtl` + the v5 BRAM drop-in `ByteRxFifo` | — | the **baseline** for the identity legs |
| `obj_byte_sro_bs` | `s1_rtl_bs` — the same tree **+ `RXFIX_BS`** | `+define+RXFIX_BS` | the instrument |

One wrapper (`wrap_byte_bs.v`) and one driver (`sim_sro.cpp`, task 7's, **unmodified**)
across all three. That is what makes the identity legs a test of the RTL patch and of
nothing else — and it is also why the third binary is needed: the base/BS pair *share*
the wrapper, so a non-transparent wrapper would cancel between them and leave the
identity legs looking clean.

**Why the drop-in FIFO is in the gated trees, stated as the scope limit it is.**
`RXFIX_BS` taps `ByteRxFifo`'s `push`/`pop`/`drop` wires, which exist only in the v5 BRAM
drop-in — the module **every build tree in this lineage carries**
(`jupiter_240k5_byte/rxfifo_inject.sh`; `TxRxCompo_ip_src_ByteRxFifo.v` in
`jupiter_byte_seqbist_build` and `jupiter_byte_rxfixr4dr1_build`, `DEPTH = 4096`). The
HDL-Coder-generated 64-deep module names none of them. Gating on the generated module
would mean gating a **different tap expression from the one the build ships**, so the
injector refuses it outright and both gated trees carry the drop-in at `DEPTH = 4096`.
**This matches the BUILD tree. Whether the build tree matches the FLASHED image is O1
and is untouched by this gate.**

## 2. The legs

Stimulus, sample counts and `rstcs_end` are task 7's, unchanged: `n_p000.iq` /
`n_m10.iq` / `n_p10.iq`, `nsamp = 21,114,096` (428 air frames), `rstcs_end = 8400`,
cadence 2, vphase 0.

| leg | binary | plusargs | purpose |
|---|---|---|---|
| `bsw_p000` | gen | — | wrapper transparency vs banked `b_p000` |
| `bsb_p000` `bsb_m10` `bsb_p10` | base | — | identity reference |
| `bs1_p000` `bs1_m10` `bs1_p10` | bs | — | identity + the census |
| `bs1_k1536` | bs | `+bsskip=1536 +bsskip_at=20000` | truncation control, **on** the 24 lattice |
| `bs1_k1024` | bs | `+bsskip=1024 +bsskip_at=20000` | truncation control, **off** the 24 lattice |
| `bs1_dA` | bs | `+bsstall_at=20000 +bsstall_n=4200` | bounded stall / release |
| `bs1_dB` | bs | `+bsstall_at=20000 +bsstall_n=4440` | the same, **240 pushes longer** |

`bsstall_at` / `bsskip_at` are **harness** push indices, counted in the wrapper from
`SerTogRT_out1` transitions — a DUT net that passes through no `RXFIX_BS` logic. Push
20,000 is air frame ≈ 105, well past lock (frame 13 on `n_p000`).

## 3. Identity — the instrument must change nothing

Read-only taps, no net redefined, so this is **structural**; it is gated anyway because
"structural" is an argument and a diff is a measurement.

| # | prediction |
|---|---|
| **I1** | `bs1_p000_frames.txt` == `bsb_p000_frames.txt`, byte for byte |
| **I2** | `bs1_m10_frames.txt` == `bsb_m10_frames.txt`, byte for byte |
| **I3** | `bs1_p10_frames.txt` == `bsb_p10_frames.txt`, byte for byte |
| **I4** | the same for all three `_res.txt` (packets, biterr, capout, nrxw, pushes, pops, anom, rhPE, rhPF, pdPof, pdPE) |
| **I5** | `bsw_p000_frames.txt` == the **banked** `two_jup/comb/sro_sim/b_p000_frames.txt`, byte for byte — the wrapper is transparent |
| **I6** | the two binaries' md5s differ (asserted by `build_sro_bs.sh`), and every leg log carries `WRAPBS_FILE`/`WRAPBS_DEFINE`; no other `wrap_byte_sro*.v` appears in any verilate log |

**A failure of I1–I4 refutes the cut.** A failure of I5 alone means the *wrapper* is not
transparent and every leg here has to be re-run against a fixed wrapper; it does not by
itself say anything about the RTL patch.

## 4. The counters read what the harness independently knows

Scored on the **final record** of `bs1_p000_census.txt` (and the same on `m10`/`p10`).
The harness recount is taken from the **pin** side (`byte_rx_valid && byte_rx_ready`,
`byte_rx_user`) and from `SerTogRT_out1`; the census counts the **serializer** side
(`wv`) and the FIFO's own `push`/`pop`/`drop`. No net is shared between the two, which is
the discipline `wrap_byte_sro4d.v` set and the one §6 concern 3 of
`BYTESEAM_INSTRUMENT.md` records a lesson about.

| # | prediction | why it is a bet |
|---|---|---|
| **C1** | `bs_words == h_push` **exactly** | census counts `wv` under `enb_1_2_0_gated`; the harness counts `SerTogRT_out1` transitions on raw `clk`. Different net, different enable, one number |
| **C2** | `bs_push == bs_words` **exactly** | the four `Ser*RT` rate-transition registers are lossless: every emitted word is offered to the FIFO |
| **C3** | `bs_drop == 0` and `bs_dropmax == 0` on every no-stall leg | at `DEPTH = 4096` with `ready` held high the FIFO never fills |
| **C4** | `0 <= bs_push − bs_pop − bs_drop <= 4095` | that expression **is** the FIFO occupancy; anything outside the ring is an arithmetic fault |
| **C5** | `abs(bs_pop − h_acc) <= 8` | the FIFO pops on `valid && ready` delayed 4, the pin presents `valid` delayed 4 against the raw `ready`: the same events, offset by the output pipeline |
| **C6** | `abs(bs_markpush − bs_lasts) <= 1` | `wordFirst` is the word **after** a `wordLast`, so the two differ by at most the frame in flight |
| **C7** | `ck_frames == h_accmark` **exactly** | the in-fabric checker's `frames` is by definition accepted `user` words |
| **C8a** | `bs_trunc == 0` on `bs1_p000` | at `skipCount = 0` RxAlign emits `12,255` bits/frame = 191 words + 31 bits, so the next `start` finds `state_wordCnt` already back at 0. **`n_p000` has 4 of 428 air frames that are not clean, so a `bs_trunc` of 1…4 is a benign miss, not a defect**; it is scored separately from C8b for exactly that reason |
| **C8b** | `191 × bs_lasts <= bs_words <= 191 × bs_lasts + 190 × bs_trunc + 190` | the word-conservation range, which holds whatever `bs_trunc` turns out to be |
| **C11** | on the same stimulus, `bsb_p000`'s `h_push`, `h_acc`, `h_accmark` and `ck_frames` equal `bs1_p000`'s **exactly** | the baseline binary writes a census too (its `bs_*` columns are structurally 0). A second identity leg at zero cost, on the harness recount rather than on the delivered frames |
| **C9** | `abs(bs_starts − bs_lasts − bs_trunc) <= 1` | every `start` either follows a completed frame or truncates one |
| **C10** | `BS_CNT[7:0] == 0` and `bs_trunc_min`, `bs_trunc_max`, `bs_trunc_last` all `<= 191` in every record | the fail-closed contract the reader enforces |

## 5. The truncation control — `bs_trunc`, its three order statistics, and `bs_q24`

`skip_count` is a **wrapper input port**, so §2.4's control (on silicon a write to the
write-only register `0x138`) is directly drivable here. It has never been run anywhere.

RxAlign emits `min(12292, 12255 − sc)` bits per frame (`RxAlign.v:129-160`: skip
`sc + 41` of the 12,296 `deintValid` beats, clamp `o < 12292`), so:

| leg | `sc` | bits/frame | words/frame | `191 − words` | on the 24 lattice? |
|---|---|---|---|---|---|
| `bs1_k1536` | 1536 | 10,719 | **167** | **24** | **yes** |
| `bs1_k1024` | 1024 | 11,231 | **175** | **16** | **no** |

**`bs1_k1024` exists because `bs1_k1536` alone only ever exercises `bs_q24`'s TRUE
branch.** A `q24` mistakenly wired to `bs_trunc`'s own enable would pass the 1536 leg.

| # | prediction |
|---|---|
| **T1** | `bs1_k1536`: after push 20,000, `bs_trunc` advances at the frame rate, and `bs_trunc_last == bs_trunc_min == bs_trunc_max == 167` in the final record |
| **T2** | `bs1_k1536`: `bs_q24` advances with `bs_trunc` and saturates at 255 |
| **T3** | `bs1_k1024`: `bs_trunc_last == bs_trunc_min == bs_trunc_max == 175` and **`bs_q24` stays at 0** for the whole leg |
| **T4** | both k-legs: `bs_lasts` and `bs_markpush` **stop advancing** after the poke (no frame reaches 191 words, so `wordLast` never fires) and `ck_frames` stops with them — §2.4's "saturated control: byte delivery halts" |
| **T5** | both k-legs: `bs_starts` keeps advancing at the frame rate throughout — the deframer is untouched, which is what makes T4 a truncation and not a loss of sync |
| **T6** | both k-legs: `bs_drop == 0` — a truncation deletes nothing in the FIFO |

**F6 (from `BYTESEAM_INSTRUMENT.md` §4) fires here if T1 fails**: the truncation counter
is dead and no null from it is quotable.

## 6. The injected deletion — a known size, and §2.4's bounded stall/release

This is the leg the task exists for: a deletion whose size is **fixed by construction**,
not read off the counter under test.

**Construction.** `bs1_dA` and `bs1_dB` are identical in every respect up to harness push
20,000 — same binary, same stimulus, same driver, same seed-free deterministic RTL — so
the FIFO's free capacity `C` at that instant is **the same number** in both. Holding
`ready` low for `N` further pushes drops `N − C` words (the drop-oldest fires on every
push once `wr+1 == rd`). Therefore

```
bs_drop(dB) − bs_drop(dA) = (4440 − C) − (4200 − C) = 240,   exactly, whatever C is.
```

`C` is never needed and is never assumed. 240 words is also **10 × 24**, the byte-plane
quantum `BYTESEAM_INSTRUMENT.md` §1.1 derives (192 B = 24 words).

| # | prediction |
|---|---|
| **D1** | `bs_drop(dA) > 0`, and `bs_dropmax(dA) == bs_drop(dA)` (one contiguous run) unless it saturates at 255 |
| **D2** | **`bs_drop(dB) − bs_drop(dA) == 240`, exactly.** The known-size injected deletion |
| **D3** | `bs_push(dA) == bs_push(dB)`, **exactly** — the stall does not change what the serializer emits |
| **D4** | `bs_pop(dA) − bs_pop(dB) == 240`, **exactly** — 240 more words deleted is 240 fewer words popped |
| **D5** | `h_acc(dA) − h_acc(dB) == 240 ± 8` — the same 240 words, counted at the **pins** by the harness, through no BS logic |
| **D6** | `bs_markpush(dA) == bs_markpush(dB)` exactly, while `ck_frames(dB) <= ck_frames(dA)`: the mark chain `bs_lasts → bs_markpush → ck_frames` is **broken at the FIFO hop and only there** |
| **D7** | both legs: `ck_short + ck_orphan` strictly greater than on `bs1_p000`. **§2.4's release-side control, run for the first time** |
| **D8** | the pin word budget moves by the deletion: `[h_acc − 191 × ck_frames](dA) − [h_acc − 191 × ck_frames](dB) == 240 ± 191`. **This is F8**: if D7 passes and D8 fails, the word budget does not measure word loss, and `BYTESEAM_INSTRUMENT.md` §0(4) cannot be used to rank §1.4 at all |

**What D7/D8 are and are not.** They are a *synthesis* of the anomaly class on a
deletion this harness made, at a size this harness chose. They are **not** a
reproduction of the silicon event: the silicon event is `Δshort = 1, Δorphan ≈ 71` with
**no** word loss (§0(4)), and nothing here produces that. What they establish is that
`short_frm`/`orphan_w` and the `acc_beats − 191 × frames` budget **can be made to move
by a known cause** — the thing §2.4 and §6 concern 2 record as never having been
established. The silicon-side control remains un-run and every §0 conclusion stays
provisional until it is.

## 6b. ADDENDUM — written while the legs were running, before any leg produced a number

**Recorded as the deviation it is.** §0–§6 above were md5-stamped into every leg log as
`BS_PREREG_MD5 70395df445346ca0e71b5dfca6f1aca0` at launch (2026-09-06 20:16). This
section, §6b, the unit gate §U, the timing section §7 and the C8 split were written
**after launch and before any census file was read**. They **tighten** predictions and
add rows; not one prediction is loosened, and D2 — the load-bearing one — is untouched.
The stamped md5 no longer matches the file, deliberately: the stamp records what was
fixed at launch, and this paragraph records what was added after. Both are needed to read
§9 honestly.

**D1 is a PRECONDITION of D2, not a peer row.** D2's exactness needs **both** legs to have
driven the FIFO past full. At `DEPTH = 4096` the free capacity `C` at push 20,000 is
expected to be ~4,094 (with `ready` held high the drop-in drains as fast as it fills), so
`drop(dA) ≈ 4200 − 4094 ≈ 106` — a **2.5 % margin**. If the standing occupancy is larger
than expected and `drop(dA)` comes out 0, then `drop(dB) − drop(dA)` reads **346, not
240**, and D2 is **VOID, not FAIL**: the pair re-runs with `bsstall_n` raised, and **the
prediction 240 is not adjusted to fit**. Stating that now is pre-registration; stating it
after the numbers land would not be.

**D4 and D5 carry an assumption D2 does not** — that the FIFO's final occupancy is the
same in both legs. **D2 is the deletion measurement**; if D4 or D5 misses by one or two
words while D2 is exact, the deletion measurement stands and §9 says which is which.

**D7′ — the sharp form of D7, which the construction already delivers.** Work the
drop-oldest through: at push 20,000 the FIFO is near-empty; it fills over ~4,094 pushes;
every further push then evicts the **earliest** entry. After `N` pushes the FIFO holds
pushes `N−4094…N` and the first `D = N − C` are gone. That is **one contiguous hole of D
words at the start of the stall window** — exactly the shape §2.4 pre-registers, and on
`dA` with `D < 191`. So, keyed on the measured `bs_drop` (no advance knowledge of `D`
needed), and with `bs1_p000` reading `ck_short = ck_orphan = 0` so deltas are absolutes:

> **D7′ (dA):** `(ck_short, ck_orphan)` is **either** `(1, 0)` — the mark survived and the
> short carries `191 − widx = D` — **or** `(0, 191 − bs_drop(dA))` — the mark was
> swallowed. **Nothing else.** A single contiguous deletion producing **both** a short and
> an orphan run would falsify §1.4's whole enumeration.

D7 (the weak inequality) is kept and scored as well, because it is the row that was
stamped; D7′ is the row that means something.

**D8′ — the exact identity, which D8's ±191 window cannot express.** `D(dB) ≈ 346 > 191`,
so `dB` **must** lose at least one whole mark, and each lost mark moves the raw budget by
+191 — which can break a ±191 window for a reason that is not a defect. The invariant that
holds on **every** leg and in **both** the survived and the swallowed case is

```
Z  ≡  (h_acc − 191 × ck_frames)  +  bs_drop  −  191 × (bs_markpush − ck_frames)   ==  0   (± 191 endpoint)
```

— clean leg: `0 + 0 − 0`; `dA` mark-survived: `(−D) + D − 0`; `dA` mark-swallowed:
`(191 − D) + D − 191`. `bs_markpush − ck_frames` is the mark-chain break D6 already
predicts, so **D8′ ties the deletion, the pin word budget and the broken hop into one
number**, and it is what F8 actually tests.

## U. The unit gate on `bs_seam_census` — two things the legs structurally cannot test

`jupiter_240k5_byte/rtl_sim/tb_bs_census.v`, run by `build_bs_census_tb.sh`, which
**extracts the module from the patched tree** (`s1_rtl_bs/TxRxComposite.v`, `module
bs_seam_census` … `endmodule`) rather than re-typing it. Iverilog; seconds.

| # | what the legs cannot do | what the TB does |
|---|---|---|
| **U1** | **`bs_trunc_min` / `bs_trunc_max` have no control in the leg gate.** Both k-legs truncate every frame at the SAME word count (167, then 175), so `min == max == last` is satisfied trivially — an implementation in which both are copies of `tLast`, or in which the two comparators are swapped, passes T1 and T3 identically | drives four truncations of **different** sizes (143, 167, 95, 100) and asserts `min` falls, `max` rises and `last` follows; asserts `wcnt = 0` and `wcnt = 191` are **not** truncations |
| **U2** | **`bs_q24` is exercised at one lattice value per leg** | the same four sizes give `191 − wcnt` = 48, 24, 96, **91** — three on the lattice, one off — and `bs_q24` must read exactly 3 |
| **U3** | **the FREEZE level is never exercised anywhere.** On the Verilator lineage `TxRxComposite` has no `fixctl` port, so the injector ties `bs_freeze` to `1'b0` and the `if (~freeze)` shadow hold — the mechanism the "one coherent sweep across both enables" claim rests on — is dead in every leg | raises `freeze`, runs four beats of **both** enables, asserts all four scored words HOLD, releases, and asserts the shadow catches up by **exactly** four — i.e. the live counters never stopped |
| **U4** | `bs_dropmax`'s RUN semantics: the leg gate only ever produces one contiguous run | drives 3 drops, a clean push, then 2 drops, and asserts `dropmax == 3` — a clean push breaks the run |
| **U5** | reset values | `bs_trunc_min` resets to **191** and `bs_trunc_max` to **0** (so the first event sets both), and `BS_CNT[7:0]` is 0 at reset and after every event |

## 7. Timing risk and the trim ladder — stated before the build, as the build gate

**Flop count, corrected.** `BYTESEAM_INSTRUMENT.md` §3 estimated "≈ 260 flops". The cut
is larger, and it is the honest number that goes to the build:

| block | flops |
|---|---|
| census live counters (5 × 32 + 3 × 16 + 6 × 8) | **256** |
| census shadow (8 × 32) | **256** |
| `bs_reg[0:7]` in the addr_decoder (8 × 32) | **256** |
| **total** | **≈ 768**, plus one 8-way 32-bit read mux and seven 8-bit comparators for `bs_q24` |

**The real risk is not the flops, it is the 256-bit bus** fanning through four wrapper
levels (`TxRxComposite → TxRxCompo_ip_dut → TxRxCompo_ip → TxRxCompo_ip_axi_lite →
TxRxCompo_ip_addr_decoder`) to the decoder. Everything else is local.

**Two named risks are CLOSED by the netlist, not carried:**

* §3 risk 1 (hierarchy depth 4) — **does not exist.** `ByteSerializer` and `ByteRxFifo`
  are instantiated directly in `TxRxComposite` and `RxAlign.startOut` arrives there as
  `Receiver_recStart`; no RTL level below `TxRxComposite` is touched at all. W1's own
  carry chain is five RTL levels deeper than BS's.
* §3 risk 2 (domain crossing) — **is not a crossing.** Both taps are `always @(posedge
  clk)` with different clock **enables**. No CDC, no `cdc_exceptions.xdc` change.

**§3 risk 3 (the read-mux index) is real and is closed by `test_170`/`test_171`**, not by
the build (§7-BS.4 of `W1_REGMAP.md`).

**The build gate.** The **modem-clock intra-clock post-route WNS**, as for R4B and R4D —
**not** the overall `TXFIX_ROUTED_WNS`, which is the vendor IDELAYCTRL path. Precedents on
this lineage: W1 **+0.169**, SEQ-BIST **+0.227**, R4B **+0.437**, R4D+R1 **+0.620** ns.
**Pass = WNS ≥ 0 on that clock**, with the R4B/R4D witnesses unchanged.

**The trim ladder, revised.** §2.3's ladder nominated `BS_BITS` as the first cut; it no
longer exists (already in silicon at 0x130, free). So:

1. **8 → 7: drop `BS_POP`.** Loses the ability to see word loss that is **not** counted as
   a drop — S4's missed `tog` edge and S6's `ready_1` skew — leaving `bs_drop` alone to
   speak for the FIFO. Saves 32 live + 32 shadow + 32 decoder flops and one bus slice.
2. **7 → 6: drop `BS_MARKS`.** Loses the `bs_lasts → bs_markpush → frames` mark chain,
   i.e. the W-rule's `M`, which makes branches (iii) and (iv) indistinguishable. Only if
   forced.

**Do NOT trim `BS_STARTS`, `BS_WORDS`, `BS_DROP` or `BS_CNT`:** P5, the discriminator, is
unreadable without all four.

**An alternative that is NOT recommended:** dropping the 256-flop shadow and reading the
live counters. It halves the census's flops and costs read coherence — the eight words
would then be sampled ~6 `devmem` forks apart, which is the read skew `BYTESEAM_INSTRUMENT.md`
§0(4) spends a section fighting, and it would break the whole point of riding `fixctl[4]`.

## 8. Scoring

`two_jup/comb/sro_sim/bs_score.py` reads the `_census.txt`, `_frames.txt` and `_res.txt`
files and prints one PASS/FAIL row per prediction above, with the measured number beside
the predicted one. **Fail closed**: a missing leg is a FAIL, never a skip; a
`BS_CNT[7:0] != 0` or an out-of-range order statistic is `DECODE_FAIL` and no other row
from that leg is quoted.

## 9. Results — **BS_GATE 65/72 PASS**

Fourteen legs (eleven launched 2026-09-06 20:16 with
`BS_PREREG_MD5 70395df445346ca0e71b5dfca6f1aca0` stamped into every log before the leg
started; three re-run legs launched 22:15, see below). Reproduce with
`two_jup/comb/sro_sim/bs_score.py`.

### 9.1 What passed, and what it establishes

* **Every identity row (I1–I6).** `bs1_*` and `bsb_*` `_frames.txt` and `_res.txt` are
  **byte-identical** on all three offsets, and `bsw_p000_frames.txt` is **byte-identical
  to task 7's banked `b_p000_frames.txt`** — so the wrapper is transparent and the
  instrument changes nothing. The read-only claim is now a diff, not an argument.
* **Every counter row (C1–C11) except one benign miss.** The census's own numbers equal
  the harness's independent recount **exactly**: `bs_words == h_push` (80,350 / 80,621 /
  80,732 on p000 / m10 / p10), `bs_push == bs_words`, `ck_frames == h_accmark`,
  `bs_push − bs_pop − bs_drop == 0` on every leg, and `bs_pop − h_acc == 0` on every
  no-stall leg. `bsb_p000`'s harness recount equals `bs1_p000`'s **exactly** (C11).
* **Every truncation row (T1–T6), both branches of `bs_q24`.** `k1536`:
  `bs_trunc_last = min = max = 167`, `bs_q24` advances to saturation, marks stop
  (`bs_lasts` 105 against p000's 420) while `bs_starts` is **unchanged** (Δ = 0) and
  `bs_drop = 0`. `k1024`: `167 → 175` and **`bs_q24` stays at 0**. §2.4's truncation
  control, run for the first time anywhere, on demand, with the predicted number.
* **THE LOAD-BEARING ROW, D2: `bs_drop(dB) − bs_drop(dA) == 240`, exactly.** The
  injected deletion is measured, not inferred: 240 is fixed by the harness's own push
  count and never appears in any BS counter's derivation. D1: `bs_drop = 105 =
  bs_dropmax` on `dA` — one contiguous run, and `< 191` as the construction requires.
* **The five cross-leg rows, at a common window (D3′–D8′).** `bs_pop` differs by
  **exactly 240**, `h_acc` by **exactly 240**, `bs_markpush` is **equal** (418/418) while
  `ck_frames` is 417 against 416 — **the mark chain is broken at the FIFO hop and only
  there**, by exactly the number of marks inside the deleted run.
* **The unit gate (U1–U5), 38/38.** `bs_trunc_min`/`max` update direction, `bs_q24` on
  both branches, `bs_dropmax`'s run semantics, and **the freeze level** — none of which
  any leg can exercise.

### 9.2 The seven FAILs, each named rather than smoothed over

**(1) C8a on `bs1_m10`: `bs_trunc = 1`, predicted 0.** A benign miss, and the row was
split from C8b for exactly this reason before the numbers existed: `n_m10` has air
frames that are not clean, and one of them truncated. **C8b — the conservation range,
which is the row that matters — passes on all three legs.**

**(2)–(6) D3, D4, D5, D6, D8 — VOID, not refuted: the two legs' last records are at
different times.** `sim_sro.cpp` never calls Verilator's `final()`, so the wrapper's
end-of-run record never fired and "the final record" is the last **periodic** one; and a
stall-edge emit re-phases the periodic tick. `dA`'s last record is at clk **41,994,527**
and `dB`'s at **42,118,279** — **123,752 clks apart**, in which
`123,752 × 0.0019131 = 237` words arrive. That is the whole of D3's "240". D2 was immune
because `bs_drop` stops advancing when the stall ends, which is why it alone was
scoreable. **The instrument is not implicated; the harness's dump cadence is.**

The response was to fix the cadence and re-run **the same stimulus, the same RTL and the
same predicted numbers** — `bs1_p0002` / `bs1_dA2` / `bs1_dB2` against
`obj_byte_sro_bs2`, whose only difference is a record every 4,096 pushes (a separate
object dir; the first run's binary is untouched). At the largest push index the three
legs share, **`h_push = 79,760`, all five pass with the pre-registered numbers**
(D3′–D8′ above). The first-run rows are left standing as FAIL rather than deleted.

**(7) D7′ on `dA`: `(ck_short, ck_orphan) = (0, 85)`, predicted `(0, 86)`. Off by one —
and the instrument itself says why.** The shape is right (mark swallowed, no short), the
size is one word short, and the missing word is visible in the census: **`bs_pop − h_acc`
is 0 on every no-stall leg and 1 on BOTH stall legs.** One word is popped by the FIFO and
never accepted at the pin, at the stall edge — the FIFO pops on `ready` delayed 4 while
the pin presents `valid` delayed 4, which is **seam S6, the `ready_1` skew**
(`BYTESEAM_INSTRUMENT.md` §1.3, verdict DISFAVOURED, "≤ 4 words per `ready` fall"). The
corrected identity closes **exactly**, on both legs, and is registered forward as
post-hoc rather than quoted as a pre-registered pass:

```
ck_orphan  ==  M x 191  -  (bs_drop  +  (bs_pop - h_acc))     M = bs_markpush - ck_frames
dA2:  85  ==  1 x 191 - (105 + 1)                             M = 1
dB2:  36  ==  2 x 191 - (345 + 1)                             M = 2
```

**What that buys and what it does not.** It is a *synthesis*: §2.4's bounded
stall/release control fires `short_frm`/`orphan_w` on demand, at a known size, for the
first time anywhere, and the pin word budget moves with it (D8′). It is **not** the
silicon event, which is `Δshort = 1, Δorphan ≈ 71` with **no** word loss. And it is
**not** the silicon control: `short_frm`/`orphan_w` on a flashed image still have none,
so **every §0 conclusion of `BYTESEAM_INSTRUMENT.md` stays provisional** and §6 concern 2
stays open.

### 9.2b What was edited AFTER the first run, and therefore is not pre-registered

`bs_score.py` postdates the first run. Recorded here so nobody has to reconstruct it by
diffing the committed scorer against the stamped `BS_PREREG_MD5`:

* **`I6`'s predicate was WIDENED after the fact**, from `banner == 11 logs` to `every log
  carries the banner and a prereg md5`, because the re-run added three logs and the
  literal 11 then failed for a bookkeeping reason. This is a genuine post-hoc relaxation.
  The substance is unchanged and it is the only prediction in this file that was loosened
  at any point.
* **§6c (D3′–D8′), D7′, D8′ and the POSTHOC orphan identity were written after the first
  run** — D7′/D8′ in the §6b addendum before any census was read, §6c and the POSTHOC row
  after. §6c re-scores the **same** predicted numbers at a common window; the POSTHOC row
  is labelled POSTHOC in the scorer's own output and is registered forward, not quoted as
  a pass.
* **`D2` is scored on the FIRST-RUN pair (`bs1_dA` / `bs1_dB`) only.** The re-run legs
  re-establish it implicitly but the D2 row reads the original legs — which is the point:
  `bs_drop` stops advancing when the stall ends, so D2 is window-immune and needed no
  re-run. "We re-ran the deletion legs" must not be read as "D2 came from the re-run".
* **`obj_byte_sro_bs2` is not a record-for-record re-run of `obj_byte_sro_bs`.** Its extra
  emit sits in the same `if` chain that reloads `bs_tick`, so the **clk** grid is
  re-phased as well: `bs1_dA2`'s records are **not** at `bs1_dA`'s clk times. The two runs
  are comparable at `h_push`, not at `clk`, and anyone diffing them by clk stamp will find
  a mismatch that is the dump trigger, not the RTL.

### 9.3 The scorer's output, verbatim

```
PASS I1 bs1_p000 frames == bsb_p000 frames                                           predicted byte-identical                     measured identical
PASS I2 bs1_m10 frames == bsb_m10 frames                                             predicted byte-identical                     measured identical
PASS I3 bs1_p10 frames == bsb_p10 frames                                             predicted byte-identical                     measured identical
PASS I4 all three _res.txt bodies equal                                              predicted identical                          measured identical
PASS I5 bsw_p000 frames == banked b_p000 frames                                      predicted byte-identical                     measured identical
PASS I6 EVERY leg log carries the wrapper banner and a prereg md5                    predicted all of them                        measured 14/14 banner, 14/14 prereg
PASS C1 bs1_p000 bs_words == h_push                                                  predicted equal                              measured 80350 vs 80350
PASS C2 bs1_p000 bs_push == bs_words                                                 predicted equal                              measured 80350 vs 80350
PASS C3 bs1_p000 bs_drop == 0, bs_dropmax == 0                                       predicted 0, 0                               measured 0, 0
PASS C4 bs1_p000 occupancy in [0,4095]                                               predicted 0..4095                            measured 0
PASS C5 bs1_p000 |bs_pop - h_acc| <= 8                                               predicted <= 8                               measured 0
PASS C6 bs1_p000 |bs_markpush - bs_lasts| <= 1                                       predicted <= 1                               measured 1
PASS C7 bs1_p000 ck_frames == h_accmark                                              predicted equal                              measured 421 vs 421
PASS C8a bs1_p000 bs_trunc == 0                                                      predicted 0                                  measured 0
PASS C8b bs1_p000 80220 <= bs_words <= 80410                                         predicted 80220..80410                       measured 80350
PASS C9 bs1_p000 |bs_starts - bs_lasts - bs_trunc| <= 1                              predicted <= 1                               measured 1
PASS C10 bs1_p000 fail-closed fields                                                 predicted rsv 0, stats <= 191                measured ok
PASS C1 bs1_m10 bs_words == h_push                                                   predicted equal                              measured 80621 vs 80621
PASS C2 bs1_m10 bs_push == bs_words                                                  predicted equal                              measured 80621 vs 80621
PASS C3 bs1_m10 bs_drop == 0, bs_dropmax == 0                                        predicted 0, 0                               measured 0, 0
PASS C4 bs1_m10 occupancy in [0,4095]                                                predicted 0..4095                            measured 0
PASS C5 bs1_m10 |bs_pop - h_acc| <= 8                                                predicted <= 8                               measured 0
PASS C6 bs1_m10 |bs_markpush - bs_lasts| <= 1                                        predicted <= 1                               measured 1
PASS C7 bs1_m10 ck_frames == h_accmark                                               predicted equal                              measured 422 vs 422
FAIL C8a bs1_m10 bs_trunc == 0                                                       predicted 0                                  measured 1
PASS C8b bs1_m10 80411 <= bs_words <= 80791                                          predicted 80411..80791                       measured 80621
PASS C9 bs1_m10 |bs_starts - bs_lasts - bs_trunc| <= 1                               predicted <= 1                               measured 1
PASS C10 bs1_m10 fail-closed fields                                                  predicted rsv 0, stats <= 191                measured ok
PASS C1 bs1_p10 bs_words == h_push                                                   predicted equal                              measured 80732 vs 80732
PASS C2 bs1_p10 bs_push == bs_words                                                  predicted equal                              measured 80732 vs 80732
PASS C3 bs1_p10 bs_drop == 0, bs_dropmax == 0                                        predicted 0, 0                               measured 0, 0
PASS C4 bs1_p10 occupancy in [0,4095]                                                predicted 0..4095                            measured 0
PASS C5 bs1_p10 |bs_pop - h_acc| <= 8                                                predicted <= 8                               measured 0
PASS C6 bs1_p10 |bs_markpush - bs_lasts| <= 1                                        predicted <= 1                               measured 1
PASS C7 bs1_p10 ck_frames == h_accmark                                               predicted equal                              measured 423 vs 423
PASS C8a bs1_p10 bs_trunc == 0                                                       predicted 0                                  measured 0
PASS C8b bs1_p10 80602 <= bs_words <= 80792                                          predicted 80602..80792                       measured 80732
PASS C9 bs1_p10 |bs_starts - bs_lasts - bs_trunc| <= 1                               predicted <= 1                               measured 1
PASS C10 bs1_p10 fail-closed fields                                                  predicted rsv 0, stats <= 191                measured ok
PASS C11 bsb_p000 h_push/h_acc/h_accmark/ck_frames == bs1_p000                       predicted equal                              measured h_push 80350/80350 h_acc 80350/80350 h_accmark 421/421 ck_frames 421/421
PASS T1/T2 bs1_k1536 trunc order stats == 167                                        predicted (167,167,167)                      measured (167, 167, 167)
PASS T1/T2 bs1_k1536 bs_trunc advances                                               predicted > 0                                measured 315
PASS T1/T2 bs1_k1536 bs_q24 advances                                                 predicted > 0                                measured 255
PASS T3 bs1_k1024 trunc order stats == 175                                           predicted (175,175,175)                      measured (175, 175, 175)
PASS T3 bs1_k1024 bs_trunc advances                                                  predicted > 0                                measured 315
PASS T3 bs1_k1024 bs_q24 STAYS 0                                                     predicted == 0                               measured 0
PASS T4 bs1_k1536 marks stop (lasts, markpush, ck_frames < p000)                     predicted all three lower                    measured lasts 105/420 markpush 106/421 frames 106/421
PASS T5 bs1_k1536 bs_starts unchanged (within 2)                                     predicted |d| <= 2                           measured 0
PASS T6 bs1_k1536 bs_drop == 0                                                       predicted 0                                  measured 0
PASS T4 bs1_k1024 marks stop (lasts, markpush, ck_frames < p000)                     predicted all three lower                    measured lasts 105/420 markpush 106/421 frames 106/421
PASS T5 bs1_k1024 bs_starts unchanged (within 2)                                     predicted |d| <= 2                           measured 0
PASS T6 bs1_k1024 bs_drop == 0                                                       predicted 0                                  measured 0
PASS D1 bs_drop(dA) > 0 and == bs_dropmax (or 255)                                   predicted one contiguous run                 measured drop 105 dropmax 105
PASS D2 bs_drop(dB) - bs_drop(dA) == 240                                             predicted 240                                measured 240
FAIL D3 bs_push(dA) == bs_push(dB)                                                   predicted equal                              measured 80339 vs 80579
FAIL D4 bs_pop(dA) - bs_pop(dB) == 240                                               predicted 240                                measured 0
FAIL D5 h_acc(dA) - h_acc(dB) == 240 +- 8                                            predicted 240 +- 8                           measured 0
FAIL D6 markpush equal, ck_frames(dB) <= ck_frames(dA)                               predicted chain broken at the FIFO hop       measured markpush 421/422 frames 420/420
PASS D7 ck_short+ck_orphan > the no-stall leg                                        predicted > 0                                measured dA 85 dB 36
FAIL D8 word budget moves by the deletion: (dA)-(dB) == 240 +- 191                   predicted 240 +- 191                         measured 0 (13 - 13)
FAIL D7' dA (ck_short,ck_orphan) is (1,0) or (0,86)                                  predicted (1,0) or (0,86)                    measured (0,85) with bs_drop 105
PASS D8' dA  Z = (h_acc-191*frames) + drop - 191*(markpush-frames) == 0              predicted 0 +- 191                           measured -73
PASS D8' dB  Z = (h_acc-191*frames) + drop - 191*(markpush-frames) == 0              predicted 0 +- 191                           measured -24
PASS D8' p000 (no stall) Z == 0                                                      predicted 0 +- 191                           measured -61
PASS D3' both legs: bs_push == h_push == 79760 at the common window                  predicted 79760                              measured 79760, 79760
PASS D4' bs_pop(dA2) - bs_pop(dB2) == 240                                            predicted 240                                measured 240
PASS D5' h_acc(dA2) - h_acc(dB2) == 240 +- 8                                         predicted 240 +- 8                           measured 240
PASS D6' markpush equal, ck_frames(dB2) <= ck_frames(dA2)                            predicted chain broken at the FIFO hop       measured markpush 418/418 frames 417/416
PASS D8' word budget (dA2)-(dB2) == 240 +- 191                                       predicted 240 +- 191                         measured 49 (7 - -42)
PASS POSTHOC bs1_dA2 orphan == 1*191 - (drop 105 + ready_1 skew 1)                   predicted 85                                 measured 85
PASS POSTHOC bs1_dB2 orphan == 2*191 - (drop 345 + ready_1 skew 1)                   predicted 36                                 measured 36
PASS U1-U5 tb_bs_census (min/max direction, q24 both branches, FREEZE, dropmax run)  predicted 0 FAIL                             measured 0 FAIL, 38 PASS

BS_GATE 65/72 PASS
```
