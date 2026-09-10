> Evidence ledger, moved verbatim from `two_jup/rxfix/W1_REGMAP.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_W1 register map — ring witness + per-stage valid census (148)

Task 9, 2026-09-04. Applies to any image built from `jupiter_byte_rxfixw1_build`
(kit script `two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148`, injector variant
`RXFIX_W1` in `two_jup/skidfix/rxfix_inject.py`). **Not present on the currently
flashed 148 image `a1ff3c876d91`** — every address below reads `const_0` there.

Reader: `two_jup/rxfix/w1_read.sh` (direct_reg_access, one sweep per ≥10 s).

## 1. Read registers

`address_select_level1 = addr_read[7:0]` is a WORD index; the byte address the
host uses is `4 × word` (`TxRxCompo_ip_addr_decoder.v:199`). All eight words are
**read-only** and all eight are **shadowed behind one freeze level**, so a single
sweep is a coherent snapshot.

| byte | word | name | fields | width | notes |
|---|---|---|---|---|---|
| 0x214 | 0x85 | `W1_WITA` | `[31:16]` zero · `[15:10]` occTrue · `[9:5]` pushPtr · `[4:0]` popPtr | 32 | occTrue is the **true** registered ring occupancy 0…32 (`Validate_Input_Push_Pop_block.v` `Delay_out1`). 32 (FULL) and 0 (EMPTY) are distinct — the pointer delta in `BeatObs` and in `sim_sro.cpp:115` cannot tell them apart |
| 0x218 | 0x86 | `W1_WITB` | `[31:16]` push_on_full count · `[15:0]` pop_on_empty count | 32 | both 16-bit, **wrapping** (not saturating): read as deltas. `push_on_full` is the only place Rate_Handle deletes a symbol; `pop_on_empty` is a skipped valid slot with no data loss |
| 0x21C | 0x87 | `W1_CNT_SS` | Symbol_Synchronizer strobe count | 32 | census stage (a) = the ring **push request** (`Delay2_out1`, the interpolator Underflow delayed 14 ticks) |
| 0x220 | 0x88 | `W1_CNT_RH` | Rate_Handle `validOut` count | 32 | census stage (b); identical net to `Symbol_Synchronizer.validOut` |
| 0x224 | 0x89 | `W1_CNT_CFC` | Coarse_Frequency_Compensator `validOut` count | 32 | census stage (c) |
| 0x228 | 0x8A | `W1_CNT_CS` | Carrier_Synchronizer `validOut` count | 32 | census stage (d) |
| 0x22C | 0x8B | `W1_CNT_PD` | Preamble_Detector `validOut` count | 32 | census stage (e) |
| 0x230 | 0x8C | `W1_CNT_PC` | Packet_Controller `validOut` count | 32 | census stage (f), **after** `sample_discard_controller` |

All six census counters are 32-bit free-running and **wrap**; they are meant to be
subtracted, never read as absolutes.

Every counter and every shadow is clocked on `enb_1_2_0` (the clk/8 tick that is
one ADC sample at 4 samples/symbol), the same gate every other instrument in this
tree uses. Counting raw `clk` would break the 12,333·K arithmetic below.

## 2. Freeze

| byte | access | field | meaning |
|---|---|---|---|
| 0x208 | **write-only** | `fixctl[4]` | 1 = hold every shadow word; 0 = shadows track the live counters each `enb` beat |

`fixctl` bit allocation on this lineage — bits 0…3 are `FixCtlDec`'s
`enContract`/`enSerAnchor`/`enGridPace`/`enSlack` (`FixCtlDec.v:38-41`), bit 12 is
TXCAP's read-back mux (`TxRxComposite.v:1975,2003`), bit 13 is DEMODCAP's
(`QPSK_Rx.v:816,818`). **Bit 4 was free** and is now W1's freeze.

**0x208 is WRITE-ONLY and cannot be read back** — it is one of the known
write-only registers, alongside 0x158/0x114/0x118/0x10C, which all read `const_0`.

**A freeze write therefore sets the WHOLE 32-bit fixctl word, not just bit 4.**
There is no read-modify-write available. A naive `write 0x208 = 0x10` sets
`enSlack` (bit 3) to 0, and sets the TXCAP mux (bit 12) and the DEMODCAP mux
(bit 13) to 0 as well — i.e. it silently disarms the Preamble_Detector FIFO slack
fix and flips 0x20C/0x210 back to the DBGCAP (not DEMODCAP/TXCAP) source. Every
other bit of fixctl goes to 0 with them.

So `w1_read.sh` takes the value the operator knows is currently armed as
`FIXCTL_BASE` (default 0) and writes `FIXCTL_BASE|0x10` to freeze and
`FIXCTL_BASE` to release. **Getting `FIXCTL_BASE` wrong silently changes the
receiver's arm state for the duration of the leg.** Check what is armed before
using FREEZE=1 on a live leg; FREEZE=0 writes 0x208 not at all.

Freeze is verified **by effect**, never by read-back. `w1_read.sh` reads all eight
words twice inside one freeze window; the freeze is effective iff **all eight
deltas between the two sweeps are exactly 0**, which the script reports per
reading as `freeze_effective`. A `freeze_effective:false` reading must be
discarded — its eight words are not a coherent snapshot and the 12,333·K
arithmetic below does not apply to them.

## 3. How to use it (Task 7 report §6.3)

Take two frozen sweeps K air frames apart (K ≈ 2000) and subtract. Expected:

* every stage delta **upstream of the deframer** = 12,333·K;
* `W1_CNT_PC` delta = 12,320·K (the 13-symbol inter-frame guard that
  `sample_discard_controller` discards);
* **the first stage whose delta falls short is the deleting stage.**

Pre-registered prediction at the measured 2.5 ppm (task-7-report.md §6.4):
`pop_on_empty` increments once per ~32.4 air frames (the PER comb period), every
delta downstream of Rate_Handle is short by exactly that count, upstream deltas
are exact, and both `push_on_full` counters stay 0.

Falsifier: if every delta is exact while frames keep dying at the comb period,
the loss is **not** a symbol deletion and the SRO → Rate_Handle → symbol-sync path
is exonerated on silicon. Equally, `pop_on_empty` = 0 across several comb periods
means every edge-directed fix (R1, R2, R3 and any successor) is aimed at the wrong
place.

## 4. What W1 deliberately does NOT touch

* **0x20C / 0x210** — owned by DBGCAP/DEMODCAP (`QPSK_Rx.v:816,818`) and
  overridden by TXCAP (`TxRxComposite.v:1975,2003`); the addr_decoder still
  decodes them as `read_reg_beatfix_viol_count`/`_latch` (case `8'b10000011` /
  `8'b10000100`). The kit script asserts that decode survives.
* **write-only 0x158 / 0x114 / 0x118 / 0x10C** — W1 adds a READ decode only, plus
  one previously-unused bit of the existing 0x208 write register.
* **the data path** — every W1 signal is a read-only tap. No existing net is
  redefined, which is why the s = 0 bit-identity gate is structural.
* **the BD and component.xml** — W1 adds no `TxRxCompo_ip` top-level port, so
  `cnt_mux32`, `rx_seq_checker` and the 0x9D4x GPIOs are untouched.

---

# 5. W1 + R4B: the NINTH word at 0x234  [Task 12b; built for silicon by Task 13]

**Status (Task 13).** The kit `RXFIX_VARIANTS='W1 R4B'
two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148` → `jupiter_byte_rxfixr4b_build` builds
this word into a real image; `w1_read.sh R4B=1` sweeps it and `w1_score.py` decodes and
scores it (`r4b_locked` / `r4b_skips` / `r4b_opens`, per-interval deltas, wrap horizons
and the Task 13 pre-registration). `R4B=0` is the default everywhere, so a W1-only image
is read exactly as Task 10 read it.

When the netlist carries **both** `RXFIX_W1` and `RXFIX_R4B` (Task 13's build; apply
**W1 first**, then R4B), one further read word appears. R4B's steering witnesses have
no other way out of the IP — R4B adds no `TxRxCompo_ip` top-level port either — so they
ride W1's read path. **If W1 is absent the witnesses stay internal and 0x234 reads
`const_0` as before**; the injector prints `r4b_witness=off` in that case.

| byte | word | contents |
|---|---|---|
| **0x234** | 0x8D | `{r4b_locked, r4b_skips[15:0], r4b_window_opens[14:0]}` |

* **bit 31** `r4b_locked` — 1 once **eight `pcEnd` pulses** have been seen since reset.
  Sticky: cleared only by reset, so it survives a loss of lock.
* **bits 30:15** `r4b_skips` — steered pop skips, free-running, wraps.
* **bits 14:0** `r4b_window_opens` — structural skip windows opened, i.e. **one per
  deframed packet**. Free-running; wraps every 32,768 windows.

  **Correction (Task 13, before the first silicon read):** the "≈ 136 s at 240 f/s"
  written here when the word was cut is not this rig's number. Task 10's own air leg
  measured 0x104 advancing ~12,600 per 10 s = **~1,260 f/s** (task-10-report §4.1), so
  the real horizon is `2^15 / 1260` ≈ **26 s**. That makes `r4b_window_opens` **the
  fastest-wrapping quantity in the whole instrument** — faster than the 32-bit census
  (279 s) and far faster than the 16-bit edge counters (1,659 s). At the mandated 10 s
  cadence a delta is unambiguous with 2.6× to spare and one dropped read (20 s) still
  is; **two consecutive dropped reads alias silently**. `w1_score.py` checks every
  interval against this horizon (`R4B_OPENS_WRAP_S`) and names any that reach it.

**Deviation from the Task 12b brief, recorded.** The brief asked for
`{r4b_prefilled, r4b_armed, r4b_skips[15:0], r4b_window_opens[15:0]}` = 34 bits, which
does not fit a 32-bit read word. `r4b_prefilled` no longer exists at all (the
controller's 17:07 ruling dropped the pre-fill: the ~34-entry acquisition deficit is
larger than the 32-deep ring, so no pre-fill depth survives it), and in the R4B design
`armed` **is** `locked` — so one flag suffices and only `window_opens` is narrowed, to
15 bits. It is the field that wraps fastest and is read as a delta anyway.

## 5.1 The eight existing words are untouched

`w1_reg[0:7]`, `w1_hit` (words 0x85..0x8C), `w1_idx` and `w1_reg_process` are
**byte-identical** in the injected text with and without R4B. The only W1 line R4B
rewrites is the single `assign data_read` — there is exactly one in the module and a
ninth word has to come from somewhere — and a test asserts that this is the *only*
W1-injected line that changes:

```verilog
  assign data_read = (r4b_hit ? r4b_reg :
              (w1_hit ? w1_reg[w1_idx] : mux_out0_level1));  // RXFIX_R4B
```

The ninth word is **not** behind W1's freeze level and does not need to be: it is one
word, so a single AXI read is already coherent. W1's own eight stay coherent under
`fixctl[4]` exactly as in §2.

## 5.2 Changed at-rest expectations once R4B is in the netlist

R4B steers the ring **off** the EMPTY edge, so the quantities §3 tells you to read move:

* **`W1_OCC` (occupancy) after arm ≈ 9–10**, not 0–2. R4B's predicate is `occ ≤ 8`, so
  the ring self-centres just above the threshold: at 0 ppm it ratchets 1 → 9 over ~8
  frames after lock and then sits flat. On a **burst arm** the acquisition transient can
  leave it as high as **31** (task 7's `b_m10` air frame 2 goes 1 → 31 with
  `push_on_full = 17`); R4B does not pull it back down, it only prevents the drain to
  EMPTY, so a reading of ~31 on a burst arm is expected and is **not** a fault.
* **`W1_POE` (pop_on_empty) after arm may be 0 and that is the SUCCESS case**, not a
  dead counter. Under R4B the EMPTY edge is what the steering exists to prevent, so
  `pop_on_empty` stopping is the fix working. **`W1_POE` is therefore no longer a
  liveness control.**
* **The liveness positive control under R4B is the ninth word**: `r4b_locked = 1` and
  `r4b_window_opens` **advancing at the frame rate** (≈ 240 /s on the shipped rig). If
  `window_opens` is static the deframer is not producing `pcEnd` and no skip can ever
  fire — which distinguishes "steering is idle because the ring is healthy"
  (`window_opens` advancing, `r4b_skips` static) from "steering is dead"
  (`window_opens` static). Those two look identical on `r4b_skips` alone.
* `W1_PUF` (push_on_full) is unchanged in meaning: R4B does nothing on the FULL side.

---

# 6-R4E. The TENTH read word, 0x238 — RXFIX_R4E (Task 21)  [sim only at this writing]

R4E is R4B's EMPTY-side skip **plus** a FULL-side **dropped push**. It keeps R4B's ninth
word at **0x234** byte-for-byte and adds a tenth at **0x238** (word 0x8E). `r4eWit` is a
**64-bit** bus, R4D's shape: `{word_0x238, word_0x234}` — bits [63:32] are the 0x238 word,
bits [31:0] the 0x234 word, and the decoder maps bus word *i* to address 0x8D+*i*
(`r4e_idx`, Task 33 — the same fix as R4D's; **no R4E image was ever built**, so the
9acbe2ebe1db silicon exception of §6-R4D.2 below does not apply to R4E).

| word | bits | field | meaning |
|---|---|---|---|
| **0x234** | 31 | `r4e_locked` | 8 `pcEnd` pulses seen |
| | 30:15 | `r4e_skips[15:0]` | EMPTY-side steered pop skips (R4B's counter) |
| | 14:0 | `r4e_window_opens[14:0]` | structural windows opened |
| **0x238** | 15:0 | `r4e_drops[15:0]` | **dropped pushes** |
| | 19:16 | `r4e_land_last[3:0]` | landing slot of the most recent drop |
| | 23:20 | `r4e_land_min[3:0]` | smallest landing slot seen (resets to 15) |
| | 27:24 | `r4e_land_max[3:0]` | largest landing slot seen (resets to 0) |
| | 31:28 | `r4e_land_out[3:0]` | saturating count of drops landing **outside [1,13]** |

## 6-R4E.1 The deviation, stated

The brief asked for a **landing-slot histogram** in the tenth word. A 13-bin histogram
does not fit beside a 16-bit counter, so the on-silicon form is the **order statistic** —
last / min / max / out-of-window count. Slot **0** encodes "landed at or before the
pcEnd" and **15** encodes "≥ 15"; both are counted in `land_out`. The full 13-bin
histogram is produced in **sim** by `wrap_byte_sro4e.v`'s per-event trace, where it is
affordable. W1's eight words and R4B's 0x234 layout are untouched; the only W1-injected
line R4E rewrites is the single `assign data_read`, exactly as R4B's §5.1 describes, and a
test asserts that it is the only one.

## 6-R4E.2 What the landing slot IS, and why it is the number to read

R4E's drop is taken **12–31 validated pops before** the `pcEnd` it is aimed at (the push
side leads the pop side by the ring occupancy), so at the instant it acts the RTL cannot
yet know where the deleted symbol would have come out. The witness therefore reports a
**measured** quantity, resolved at that `pcEnd`:

> `k = occupancy_at_the_drop + 1 − (validated pops from the drop to the pcEnd)`

derived in `two_jup/comb/RXFIX_R4E_SIM_GATE.md` §1 from `FIFO_block`'s pointer arithmetic.
**`k ∈ [1,13]` means the vanished symbol was a guard-band symbol.** So:

* **`r4e_land_out = 0` with `r4e_land_min ≥ 1` and `r4e_land_max ≤ 13` is the pass.**
  Design target is `k ≈ 7–11`.
* **`r4e_land_out ≠ 0` is the silicon falsifier**: the schedule mis-predicted a `pcEnd`
  and a drop deleted a payload symbol. Expect a lost frame beside it.

## 6-R4E.3 Changed at-rest expectations under R4E

* **`W1_PUF` (`push_on_full`) after arm should be 0 on a positive-SRO link** and that is
  the **success** case, not a dead counter: R4E's whole purpose is to take the FULL-edge
  deletion deliberately, in the guard band, before the ring reaches 32. `W1_PUF` is
  therefore no longer a liveness control on that direction.
* **`W1_OCC` (occupancy) on a positive-SRO link parks at 22/23**, not 31/32: the drop
  fires whenever occupancy reaches 24 and ratchets it back down.
* **`r4e_drops` advancing at ≈ one per 8 frames at 10 ppm** is the FULL-side liveness
  positive control (rate ≈ |SRO| × 12,333 per frame). Static `r4e_drops` with
  `window_opens` advancing and occupancy below 24 means the ring is healthy; static
  `r4e_drops` with occupancy at 31/32 means the steering is **dead**.
* R4B's §5.2 expectations are unchanged for the EMPTY side (occupancy 9–10 after arm,
  `pop_on_empty = 0` is success, `window_opens` is the liveness control).

---

# 6-R4D. W1 + R4D: a TENTH word at 0x238  [Task 20 sim gate; built for silicon by Task 22; word order fixed in the injector by Task 33; readers fail closed since Task 33 fix1]

R4D is R4B plus the **FULL-side** half: the same structural window after `pcEnd`, but
with an **extra** pop armed at `occ ≥ 24` alongside the skip armed at `occ ≤ 8`. It is
the candidate for **146**, whose receiver sits on the positive-SRO side where the ring
*fills* rather than drains. It is paired with **R1**, which makes the Preamble_Detector
realignment FIFO's pop occupancy-indexed — without R1 the extra `+1` valid is deleted by
that FIFO and framing collapses (Task 14; Task 20 §1).

Kit: `RXFIX_VARIANTS='W1 R4D R1' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148` →
`jupiter_byte_rxfixr4dr1_build`.

## 6-R4D.1 The canonical layout (every image built from injector commit ≥ Task 33)

**Controller ruling (Task 33, binding):** 0x234 keeps R4B's layout on every image;
0x238 = extras.

| byte | word | contents |
|---|---|---|
| **0x234** | 0x8D | `{r4d_locked, r4d_skips[15:0], r4d_window_opens[14:0]}` — **identical in layout to R4B's** |
| **0x238** | 0x8E | `{16'b0, r4d_extras[15:0]}` — the FULL-side extra pops |

* **0x234 is unchanged from §5**, field for field, so `w1_read.sh R4B=1` and
  `w1_score.py` decode an R4D image's first witness word with no edit. The names differ
  in the RTL (`r4d_*` rather than `r4b_*`) but the bit positions do not.
* **0x238 is new.** `r4d_extras` counts the extra pops taken — the mirror of
  `r4d_skips`. It is 16-bit and free-running; bits **31:16 are hard zero** in the RTL,
  which is the reader's fail-closed check (below). At the measured ~387 per 10 s it
  wraps in ~1,690 s.
* **How the two words get there.** Rate_Handle assembles the 64-bit `r4dWit` as
  `{{16'b0, r4d_extras}, {r4d_locked, r4d_skips, r4d_opens}}` — in Verilog the leftmost
  element is the most significant, so **`r4dWit[31:0]` = word 0 = 0x234** and
  **`r4dWit[63:32]` = word 1 = 0x238**. `TxRxCompo_ip_addr_decoder` latches
  `r4d_reg[i] <= read_r4d_wit[32*i +: 32]` and selects with
  `r4d_idx = (address_select_level1 == 8'h8E)`, i.e. **bus word *i* answers address
  0x8D+*i*** — the same convention as W1's own `w1_idx = address − 0x85`.
  `test_164_r4d_words_land_at_the_canonical_addresses` resolves this table from the
  generated Verilog text of both files and pins it (`test_166` checks that the same
  resolver reproduces the silicon exception below from the first cut's index rule).
* Both words come out of the **same** `read_r4d_wit` bus
  (`r4d_hit = (address_select_level1 == 8'h8D) || (address_select_level1 == 8'h8E)`), and
  like R4B's ninth word they are **outside** W1's freeze shadow — each is one word,
  coherent on a single AXI read.
* **What Task 33 (and its fix1) changed in the generated text, precisely** (measured,
  pre-Task-33 injector commit `10b27b7` against the current one, on three tree shapes;
  `test_167` in `test_rxfix_inject.py` pins it). The functional change is the read-mux
  index in `TxRxCompo_ip_addr_decoder.v` (`r4d_idx` and its `wire`) — an IP-kit file a
  `--sim-tree` does not have. (a) On the **R4D+R1 `--sim-tree`**, the shape the sim gate
  ran (no W1, so no witness text is emitted at all), every generated file is
  **byte-identical** — which is why the banked `R4DR1` sim gate stands and no re-gate
  was needed. (b) On **any tree with W1 applied** — the kit-shaped W1+R4D tree that
  built `9acbe2ebe1db`, or a W1+R4D `--sim-tree` — exactly **four files differ, in
  comment lines only**: `Rate_Handle.v` (the witness assign's header and the `r4dWit`
  port comment) and the three witness-carry wrappers `QPSK_Rx.v`, `Receiver.v`,
  `TxRxComposite.v` (the pass-through comment). `Symbol_Synchronizer.v`,
  `TxRxCompo_ip_dut.v` and `TxRxCompo_ip_axi_lite.v` are byte-identical; the
  `assign r4dWit = {{16'b0, r4d_extras}, {r4d_locked, r4d_skips, r4d_opens}}` and every
  other non-comment line are unchanged. So "Rate_Handle text unchanged" is true of the
  gated sim tree and false, **by comments alone**, of the kit tree.

## 6-R4D.2 ⚠ Silicon exception — image `9acbe2ebe1db` (146, flashed 2026-09-05 14:11)

The **one** image built before Task 33 returns the two words **swapped**. Its decoder
(injector commit ≤ Task 22) selected with `r4d_reg[address_select_level1[0]]`: the
address LSB is **1** for word 0x8D and **0** for word 0x8E, so the lower address
answered with the *higher* bus word:

| byte | AXI word | LSB | returns on `9acbe2ebe1db` |
|---|---|---|---|
| **0x234** | 0x8D | 1 | **`{16'b0, r4d_extras[15:0]}`** |
| **0x238** | 0x8E | 0 | **`{r4d_locked, r4d_skips[15:0], r4d_window_opens[14:0]}`** |

Measured by Task 22 and confirmed three independent ways: 0x234's upper half is 0 on
every reading (the `{16'b0,…}` signature) while under the canonical mapping 0x238's
upper half reads a constant `0x800C`; 0x238 shows `locked=1` with a static `skips`
(occupancy sits at 22–23, so the `occ<=8` skip cannot fire); and 0x238's `window_opens`
deltas (14278/14269/14325) track the `0x104` frame deltas (14277/14266/14327) to within
two counts, conclusive since `window_opens` advances once per deframed packet. This is
an instrument indexing bug, **not** a defect in the R4D steering; the data is all
present, at the other address. **R4B-only images are unaffected** (R4B has a single-word
assign whose 0x234 layout Task 13 verified on silicon). The flashed image stays the
reference for today's readers — no rebuild for this.

**Reader rule (Task 33).** The swap is keyed on the image, never assumed:

* `w1_read.sh R4D=1` takes `R4D_SWAP=auto|0|1` (default `auto`) and `EXP=<md5-12>`.
  `auto` → **swapped iff `EXP` starts with `9acbe2ebe1db`**, canonical for any other
  `EXP`. It stamps `r4d_order=swapped|canonical` on **every reading** (`readings.jsonl`
  field, `run.log` line, `meta.txt`) and always records the raw words **by address**
  (`words.r4bWit` = 0x234, `words.r4dWit` = 0x238). With `EXP` unset and no explicit
  `R4D_SWAP=0|1`, `auto` stamps **`r4d_order=UNKNOWN`** — the words are still recorded
  raw, and nothing downstream guesses (controller ruling, Task 33 fix1: **fail closed**).
* `w1_score.py` applies, in precedence: `--r4d-swap 0|1` (explicit) → the `r4d_order`
  stamped on the readings (every R4D reading must carry the same `swapped|canonical`
  stamp) → `--exp <md5-12>` → **`UNKNOWN`**. There is **no default order**: under
  `UNKNOWN` the verdict prints `r4d_order=UNKNOWN`, lists the two words raw by address,
  and derives **no** locked/skips/opens/extras field, **no** `r4d_extras` rate and **no**
  T19′ verdict from them (it says so and names the knobs; the eight W1 words are still
  scored). Disagreement between a stamped order and `--exp`, or between stamps, is a
  `DECODE_FAIL` — no rate is quoted.
* `w1_ctl.py` (the `MODE=ctrl` headline verdict that `w1leg_go.sh` writes to
  `verdict.txt`) takes the same `--exp` / `--r4d-swap`, resolves the order per read-set
  through the same `resolve_r4d_order()`, labels every R4B row with the address the
  fields came from (`0x234[31]` canonical, `0x238[31]` on `9acbe2ebe1db`), and under
  `UNKNOWN` prints one `NO VERDICT (r4d_order=UNKNOWN)` row carrying the raw words in
  place of every R4B/R4D row.
* **Fail-closed either way:** bits 31:16 of the word taken as extras must be zero.
  Under the wrong order that word is `{locked, skips, opens}` with `locked=1`, so its
  upper half is ≥ `0x8000` and `w1_score.py` **refuses to quote a rate**.
* `w1leg_go.sh` passes `EXP` and `R4D_SWAP` explicitly to `w1_read.sh` and `--exp` /
  `--r4d-swap` to every `w1_score.py` and `w1_ctl.py` call (it already refuses `R4D=1`
  without an explicit `EXP`, and always has an `EXP`, so the `UNKNOWN` path is never
  taken from the driver).

Pinned by `test_w1_score_r4d_word_swap_matches_silicon` (the real words read off
`9acbe2ebe1db`, scored with `--exp 9acbe2ebe1db`), `test_w1_score_r4b_only_image_is_not_swapped`,
`test_w1_score_canonical_order_for_any_other_image`, `test_w1_score_wrong_order_is_refused_not_quoted`,
`test_w1_score_unknown_order_gives_no_r4d_rate_or_verdict` (the fail-closed path, both
scorers with `test_w1_ctl_unknown_order_gives_no_r4d_verdict`) and
`test_w1_ctl_r4d_order_is_keyed_on_exp` (swapped for `9acbe2ebe1db`, canonical for another md5).

## 6-R4D.3 Reader/scorer status

`w1_read.sh R4D=1` sweeps 0x234 **and** 0x238 in both frozen sweeps (R4D=1 implies R4B=1);
`w1_score.py` carries `r4d_extras` / `d_r4d_extras` / `r4d_hi` columns and the T19′
pre-registration block (Task 19 prep, Task 22). The other reader of these addresses,
`w1_ctl.py`, decodes `readings.jsonl` itself through `w1_score.decode()` (it does **not**
read the CSV); since Task 33 fix1 it is image-keyed exactly as `w1_score.py` is
(§6-R4D.2), adds an informational `r4d_extras` row on an R4D image, judges occupancy
against the R4D band 22–24 (§6-R4E.3) instead of R4B's 8–10, and refuses the R4B/R4D
rows when the extras word's upper half is non-zero under the resolved order.

**What R1 changes that has no register at all.** R1 removes the only reader of the
49,332-flop `Delay10_reg` shift register and replaces it with a 14-bit compare against
`FIFO_numEntries`. There is no witness for it: the evidence that R1 is in the image is
the netlist (`assign Delay10_full = FIFO_numEntries == 14'd12333;` and
`assign Delay10_out1 = Delay8_out1 & Delay10_full;`, with the tick-indexed
`Delay10_reg[49331]` pop **gone**) plus the utilisation drop it must cause, both of
which the kit script and the build report check.

---

# 7-BS. The byte-seam census, 0x23C–0x258 — RXFIX_BS (Task 46)  [sim-gated; no image built]

BS is an **instrument**, not a fix: eight read-only counters on the byte plane — the
stretch from the `ByteSerializer`'s word emitter to the `ByteRxFifo`'s egress — riding
W1's AXI read path at bytes **0x23C…0x258** (words 0x8F…0x96), **behind W1's existing
freeze level `fixctl[4]`**. Design: `two_jup/comb/BYTESEAM_INSTRUMENT.md` §2.
Pre-registration and gate: `two_jup/comb/RXFIX_BS1_SIM_GATE.md`. Injector variant `BS`
in `two_jup/skidfix/rxfix_inject.py`, whose header records every deviation from §2.

Kit: `RXFIX_VARIANTS='W1 R4B BS' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148`.
**Apply W1 (and R4B/R4D/R4E) FIRST**, then BS: BS's decoder hunk wraps the single
`assign data_read` those variants also rewrite, and applied the other way round W1 fails
loudly on its own missing anchor (`test_181`).

**If BS is absent every address below reads `const_0`**, exactly as W1's did before Task 9.

## 7-BS.1 Read registers

`address_select_level1 = addr_read[7:0]` is a WORD index; the host byte address is
`4 × word`. All eight words are read-only and all eight are **shadowed behind
`fixctl[4]`**, W1's level, so **one freeze window is a coherent snapshot across the W1
symbol-plane census AND the BS byte-plane census** — which is the whole point of reusing
the bit.

| byte | word | name | fields | wrap horizon |
|---|---|---|---|---|
| 0x23C | 0x8F | `BS_WORDS` | `[31:0]` words emitted by `ByteSerializer` (`wv`) | 5.0 h |
| 0x240 | 0x90 | `BS_STARTS` | `[31:0]` `RxAlign.startOut` pulses (frame boundaries) | 39.9 d |
| 0x244 | 0x91 | `BS_PUSH` | `[31:0]` `ByteRxFifo` pushes (tog edges taken) | 5.0 h |
| 0x248 | 0x92 | `BS_POP` | `[31:0]` `ByteRxFifo` pops (`valid_i && ready_1`) | 5.0 h |
| 0x24C | 0x93 | `BS_DROP` | `[31:0]` `ByteRxFifo` drop-oldest events | 5.0 h |
| 0x250 | 0x94 | `BS_MARKS` | `[31:16]` `bs_lasts` (words carrying `wordLast`) · `[15:0]` `bs_markpush` (pushes with `wFirst`) | **52.6 s** |
| 0x254 | 0x95 | `BS_EVT` | `[31:24]` `bs_trunc_last` · `[23:16]` `bs_trunc_min` · `[15:8]` `bs_trunc_max` · `[7:0]` `bs_dropmax` | saturating |
| 0x258 | 0x96 | `BS_CNT` | `[31:16]` `bs_trunc` · `[15:8]` `bs_q24` · `[7:0]` **reserved, hard 0** | 73 h / saturating |

Every 32-bit counter and the two 16-bit fields of `BS_MARKS` **wrap** and are read as
deltas. `bs_q24`, `bs_dropmax` and the three `BS_EVT` order statistics **saturate** and
are read as absolutes; `bs_trunc_min` resets to **191** and `bs_trunc_max` to **0**, so
the first truncation sets both.

**Why `BS_STARTS` gets a whole 32-bit word.** It is the denominator of every identity BS
exists to test, and §5.2's own correction records that a frame-rate counter in a 15-bit
field wraps in ~26 s and that "two consecutive dropped reads alias silently". The two
remaining frame-rate fields (`bs_lasts`, `bs_markpush`) are cross-checks, not
denominators; at 52.6 s they are 5.3× the 10 s cadence and survive one dropped read.
**`w1_score.py` must flag any interval whose `dt` reaches 40 s.**

## 7-BS.2 `bs_bits` is NOT here — it is already in silicon, and it SATURATES

§2.2/§2.3 of the design list a ninth word `BS_BITS` at 0x25C. **It is not built**, because
the counter already exists on every image of this lineage: `FEC_Decoder_Wrapper`
instantiates `FecCounters` with `e5 = RxAlign.validOut` and `e6 = RxAlign.startOut`, and
the decoder decodes them at

| byte | word | existing name | is |
|---|---|---|---|
| **0x130** | 0x4C | `cnt_dec_bits` | **`bs_bits`** — decoded info bits emitted by `RxAlign` |
| **0x134** | 0x4D | `cnt_bist_start` | **an independent-hardware `bs_starts`** |

**0x25C reads `const_0` and that is the expected value**, not a fault.

**⚠ `FecCounters` SATURATES, it does not wrap** (`FecCounters.v:232-239`,
`if (e5 && (k5 < 32'd4294967295))` then clamp). At 15.26 M s⁻¹ `cnt_dec_bits` pins at
`0xFFFFFFFF` after **~281 s** of run time and is **constant** thereafter — which would
make P8 ("`bs_bits / bs_starts` constant to ±64") pass **trivially**. **The reader must
refuse to score P8 when 0x130 reads all-ones**, and must say so rather than quoting a
pass. 0x134 saturates in ~39.9 d and is safe.

**Use 0x134 as a positive control, not as the denominator.** It is a genuinely
independent witness of `BS_STARTS` — different flops, different module, present on images
that have no BS at all — so `Δ0x134 == ΔBS_STARTS` is the strongest control in the set.
But 0x134 is **not** behind `fixctl[4]`, so it carries the read skew §0(4) of
`BYTESEAM_INSTRUMENT.md` fought; the shadowed `BS_STARTS` stays the denominator.

## 7-BS.3 What BS deliberately does NOT touch

* **W1's eight words (0x214–0x230), R4B's 0x234 and R4D/R4E's 0x238** — byte-identical in
  the injected text with and without BS. The only line BS rewrites is the single
  `assign data_read`, and `test_174` asserts that it is the only one.
* **0x20C / 0x210** — DBGCAP/TXCAP; both decodes survive (`test_173`).
* **the write-only registers** `0x4, 0x10C, 0x110, 0x114, 0x118, 0x138, 0x158, 0x170,
  0x174, 0x178, 0x17C, 0x180, 0x184, 0x1DC, 0x208` — BS adds a **READ** decode only, and
  `test_173` asserts the injected decoder contains exactly as many `addr_write`
  occurrences as the un-injected one.
* **the data path** — every BS signal is a read-only tap; no existing `assign` in
  `ByteSerializer.v` or `ByteRxFifo.v` is redefined (`test_176`, `test_178`), which is
  why the `s = 0` identity gate is structural.
* **the BD and component.xml** — no `TxRxCompo_ip` top-level port is added (`test_173`).

**`FIXCTL_BASE` must be stated on every read.** A freeze write sets the WHOLE 32-bit
`fixctl` word (§2): `w1_read.sh` writes `FIXCTL_BASE|0x10` to freeze and `FIXCTL_BASE` to
release. Getting it wrong silently disarms `enSlack` (bit 3) and flips the TXCAP/DEMODCAP
muxes (bits 12/13) for the leg. This is unchanged by BS — BS rides the *same* bit — but
it now governs **sixteen** shadowed words instead of eight.

## 7-BS.4 The read-mux index, and why the fail-closed field check is not enough

Task 33's bug class is an **index rule** (`W1_REGMAP` §6-R4D.2: image `9acbe2ebe1db`
returned two words swapped because the decoder selected on the address LSB). BS has
**eight** words on a range decode, where the plausible error is not a swap but a
**rotation**: `bs_reg[address_select_level1[2:0]]` — the `- 3'd7` forgotten — makes every
address return a real counter, one word off.

**A rotation survives every fail-closed field check the reader can make.** Under it,
byte 0x258 (whose reserved low byte the reader tests for zero) returns `BS_EVT`, whose low
byte is `bs_dropmax` — **zero on any leg with no FIFO overflow**. The check passes and the
rotation goes unnoticed.

So the map is pinned **from the generated Verilog text of both files**, the way the
hardware resolves it, by `test_170_bs_words_land_at_the_canonical_addresses` in
`two_jup/skidfix/test_rxfix_inject.py`: it reads the 8-element `assign bus = {...}`
concatenation out of `bs_seam_census` (leftmost = MSB = bus word 7), follows each shadow
register to its `wire [31:0] wN = <fields>;`, reads the decoder's latch
(`bs_reg[i] <= read_bs_bus[32*i +: 32]`) and its index rule, and asserts the resulting
address→field table against a **longhand** canonical table. `test_171` is the test of the
test: the same resolver applied to the rotated index rule must report exactly the rotated
table, and it also asserts that the rotated 0x258 is the `BS_EVT` word — i.e. it records
in code why the reserved-byte check cannot stand in for the resolver.

**Reader rules, fail closed.**

* `BS_CNT[7:0]` must be **0** in every reading, and `bs_trunc_last/min/max` must all be
  `<= 191`. A violation is `DECODE_FAIL`: no rate, no verdict, raw words only.
* `0x25C` must read **0** (there is no ninth word).
* Any interval whose `dt` reaches **40 s** is flagged (the `BS_MARKS` pair wraps at 52.6 s).
* `cnt_dec_bits` (0x130) reading `0xFFFFFFFF` ⇒ **P8 is not scored**.

## 7-BS.5 Domains and freeze — measured off the netlist, not assumed

`BYTESEAM_INSTRUMENT.md` §3 risk 2 called the serializer/FIFO split "an enable-domain
crossing … [that] must be declared and the `cdc_exceptions.xdc` in the kit reviewed".
Read off the netlist it is not a crossing at all: `ByteSerializer` is
`always @(posedge clk)` gated by `enb_1_2_0_gated` and `ByteRxFifo` is
`always @(posedge clk)` gated by `enb_gated`. **One clock, two clock enables. No CDC and
no `cdc_exceptions.xdc` change.**

BS exploits it: every shadow word is latched on **every `clk` edge** while freeze is low —
*not* on an enb tick, as `rh_w1_census` does — so one frozen sweep is coherent across both
enables to a single clk edge. That is strictly stronger than W1's shadow and is why the
byte-plane and symbol-plane counts can be compared in one window (`test_180`).

`BYTESEAM_INSTRUMENT.md` §3 risk 1 (hierarchy depth 4, `bs_bits`/`bs_starts` inside
`…/FEC_Decoder_Wrapper/RxAlign`) **does not exist either**: `ByteSerializer` and
`ByteRxFifo` are instantiated **directly in `TxRxComposite`**, and `RxAlign.startOut`
arrives there as `Receiver_recStart`. The witness carry chain is four wrapper files —
`TxRxComposite → TxRxCompo_ip_dut → TxRxCompo_ip → TxRxCompo_ip_axi_lite →
TxRxCompo_ip_addr_decoder` — and no RTL level below `TxRxComposite` is touched at all.
