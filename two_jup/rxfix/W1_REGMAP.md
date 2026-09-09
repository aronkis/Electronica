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

# 6. The TENTH read word, 0x238 — RXFIX_R4E (Task 21)  [sim only at this writing]

R4E is R4B's EMPTY-side skip **plus** a FULL-side **dropped push**. It keeps R4B's ninth
word at **0x234** byte-for-byte and adds a tenth at **0x238** (word 0x8E). `r4eWit` is a
**64-bit** bus, R4D's shape: `{word_0x238, word_0x234}`.

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

## 6.1 The deviation, stated

The brief asked for a **landing-slot histogram** in the tenth word. A 13-bin histogram
does not fit beside a 16-bit counter, so the on-silicon form is the **order statistic** —
last / min / max / out-of-window count. Slot **0** encodes "landed at or before the
pcEnd" and **15** encodes "≥ 15"; both are counted in `land_out`. The full 13-bin
histogram is produced in **sim** by `wrap_byte_sro4e.v`'s per-event trace, where it is
affordable. W1's eight words and R4B's 0x234 layout are untouched; the only W1-injected
line R4E rewrites is the single `assign data_read`, exactly as R4B's §5.1 describes, and a
test asserts that it is the only one.

## 6.2 What the landing slot IS, and why it is the number to read

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

## 6.3 Changed at-rest expectations under R4E

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

# 6. W1 + R4D: a TENTH word at 0x238  [Task 20 sim gate; built for silicon by Task 22]

R4D is R4B plus the **FULL-side** half: the same structural window after `pcEnd`, but
with an **extra** pop armed at `occ ≥ 24` alongside the skip armed at `occ ≤ 8`. It is
the candidate for **146**, whose receiver sits on the positive-SRO side where the ring
*fills* rather than drains. It is paired with **R1**, which makes the Preamble_Detector
realignment FIFO's pop occupancy-indexed — without R1 the extra `+1` valid is deleted by
that FIFO and framing collapses (Task 14; Task 20 §1).

Kit: `RXFIX_VARIANTS='W1 R4D R1' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148` →
`jupiter_byte_rxfixr4dr1_build`.

| byte | word | contents |
|---|---|---|
| 0x234 | 0x8D | `{r4d_locked, r4d_skips[15:0], r4d_window_opens[14:0]}` — **identical in layout to R4B's** |
| **0x238** | **0x8E** | `{16'b0, r4d_extras[15:0]}` — the FULL-side extra pops |

* **0x234 is unchanged from §5**, field for field, so `w1_read.sh R4B=1` and
  `w1_score.py` decode an R4D image's first witness word correctly with no edit. The
  names differ in the RTL (`r4d_*` rather than `r4b_*`) but the bit positions do not.
* **0x238 is new.** `r4d_extras` counts the extra pops taken — the mirror of
  `r4d_skips`, and the quantity a **reverse** leg's pre-registration should predict at
  the same ~394-per-10 s drift rate the forward leg showed for skips. It is 16-bit and
  free-running: at 394 per 10 s it wraps in ~1,663 s, the same horizon as `r4b_skips`.
* Both words come out of the **same** `read_r4d_wit` bus and are decoded together
  (`r4d_hit = (address_select_level1 == 8'h8D) || (address_select_level1 == 8'h8E)`),
  and like R4B's ninth word they are **outside** W1's freeze shadow — each is one word,
  coherent on a single AXI read.

**Reader/scorer status, stated so nobody assumes coverage that does not exist.**
`w1_read.sh R4B=1` sweeps **0x234 only**; nothing in this repo reads **0x238** yet, and
`w1_score.py` has no `r4d_extras` column. That is deliberate for Task 22 (bank-only, no
board contact) but it means **the FULL-side witness is unread until a reverse-leg task
adds it** — the natural change is an `R4D=1` mode that appends 0x238 and a scorer row
mirroring `r4b_skips`. Until then, an R4D image read with `R4B=1` reports its skip
counter and silently ignores its extras counter.

**What R1 changes that has no register at all.** R1 removes the only reader of the
49,332-flop `Delay10_reg` shift register and replaces it with a 14-bit compare against
`FIFO_numEntries`. There is no witness for it: the evidence that R1 is in the image is
the netlist (`assign Delay10_full = FIFO_numEntries == 14'd12333;` and
`assign Delay10_out1 = Delay8_out1 & Delay10_full;`, with the tick-indexed
`Delay10_reg[49331]` pop **gone**) plus the utilisation drop it must cause, both of
which the kit script and the build report check.
