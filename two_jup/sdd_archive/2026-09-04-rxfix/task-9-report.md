# Task 9 — RXFIX_W1: silicon ring-witness + per-stage valid census for 148

Branch `per-under-1pct-2026-07`. Ledger `Task 9:` lines in
`two_jup/sdd_archive/2026-09-04-rxfix/progress.md`.
**No board contact. No flash. No subagents.** Labels: [netlist] [sim].

---

## 1. Ownership check — who owns 0x20C / 0x210  [netlist]

Read in the SEQ-BIST kit tree that produced the flashed 148 image
`a1ff3c876d91` (`jupiter_byte_seqbist_build/hdl_prj_jupiter_composite/hdlsrc/
commhdlQPSKTxRxLoopback/`).

The read decoder takes a **word** index: `TxRxCompo_ip_addr_decoder.v:199`
`assign address_select_level1 = addr_read[7:0];` — the byte address is `4 × word`.
(Cross-checked twice: word `0x42` → byte `0x108` = `bit_errors_out`, the known
BIST register; word `0x83` → byte `0x20C`, Task 3's finding.)

| byte | word | decoder case | net |
|---|---|---|---|
| 0x20C | 0x83 | `TxRxCompo_ip_addr_decoder.v:583-586`, case `8'b10000011` | `read_reg_beatfix_viol_count` |
| 0x210 | 0x84 | `TxRxCompo_ip_addr_decoder.v:587-590`, case `8'b10000100` | `read_reg_beatfix_viol_latch` |

Those two nets are driven, in order:

* `TxRxCompo_ip_src_QPSK_Rx.v:816` `assign beatfix_viol_count = fixctl[13] ? mdcapl : dcapl;`
* `TxRxCompo_ip_src_QPSK_Rx.v:818` `assign beatfix_viol_latch = fixctl[13] ? mdcmm : dcmm;`
  — the 2026-08-30 **DBGCAP** per-stage decision capture (`dcap*`) and **DEMODCAP**
  (`mdcap*`), selected by `fixctl[13]`;
* then overridden one level up at
  `TxRxCompo_ip_src_TxRxComposite.v:1975` `assign beatfix_viol_count = fixctl[12] ? txcapl : Receiver_beatfix_viol_count_1;`
  and `:2003` `assign beatfix_viol_latch = fixctl[12] ? txcmm : Receiver_beatfix_viol_latch_1;`
  — **TXCAP**, selected by `fixctl[12]`.

**Answer: DBGCAP / DEMODCAP / TXCAP own 0x20C and 0x210. The ring witness does
not.** This confirms Task 3's finding and the analysis already written into
`two_jup/rxfix/witness_read.sh:83-100`. The in-tree comment at
`QPSK_Rx.v:719-721` that claims those addresses are the beat witness read-back is
**stale** — it predates the 2026-08-30 DBGCAP patch that sits ten lines below it.

### 1.1 Correction to task-7-report.md §6.1 — the logic did NOT already exist

§6.1 says "most of it is already in the flashed image — what is missing is a free
read-back address pair, not the logic", and "the counters already exist; only the
address decode moves." **That is wrong, and it matters, because it is the
difference between a no-rebuild read and the build this task ran.**

`TxRxCompo_ip_src_BeatObs.v` takes `dOut, sOut, vOut, decis_0, decis_1, rhc,
pushc, popc` (`:26-45`) and computes, at `:80-86`:

```
assign s_4 = {16'b0, pushc};  assign s_6 = {16'b0, popc};
assign sub_temp = s_5 - s_7;
assign cast = (sub_temp[32] == 1'b1 ? 32'd0 : sub_temp[31:0]);
assign fill8 = cast & 32'd255;
```

That is a **pointer delta**, and it is packed into `dbgI1/dbgQ1` (`:111-112`) which
`QPSK_Rx.v:713-717` routes to `beatobsI1/Q1` — the RX I/Q **sample stream to the
DMA**, not an AXI register. `BeatObs` has **no `numEntries` input and no
`push_on_full` counter anywhere in the file.**

A push−pop pointer delta on a 32-entry ring cannot distinguish occupancy 0 from
occupancy 32 — precisely the `sim_sro.cpp:115` defect the survey names in §6, and
precisely the ambiguity the whole campaign is stuck on. The survey's §1 says the
same thing independently: "true occupancy / `pop_on_empty_FIFO` /
`push_on_full_FIFO` are NOT exported."

**So the quantity that matters was never in the image.** W1 adds the counters and
eight new read addresses.

---

## 2. RXFIX_W1 — what it is

A read-only instrument in `two_jup/skidfix/rxfix_inject.py` (variant `W1`,
alongside R1/R2/R3, same exactly-once-anchor discipline, same three-loose-mirror
+ both-zip-members + `verify_zip` rails). **12 files** on a Vivado kit, **8** on a
`--sim-tree` (the Verilator lineage has no `TxRxCompo_ip_*` wrapper):

| # | file | what W1 adds |
|---|---|---|
| 1 | `Validate_Input_Push_Pop_block.v` | `w1Occ[5:0]` = `Delay_out1` (TRUE occupancy 0…32), `w1PopEmpty` = `pop_on_empty_FIFO`, `w1PushFull` = `push_on_full_FIFO` |
| 2 | `FIFO_block.v` | pass-through + `w1PushPtr`/`w1PopPtr` = `Push_Counter_out1`/`Pop_Counter_out1` |
| 3 | `Rate_Handle.v` | pass-through |
| 4 | `Symbol_Synchronizer.v` | pass-through + `w1Strobe` = `Delay2_out1` (the ring PUSH request) |
| 5 | `Frequency_and_Time_Synchronizer.v` | the `rh_w1_census` block (defined in the same file), fed by `w1Strobe`, `Symbol_Synchronizer_validOut`, `Coarse_Frequency_Compensator_validOut`, `Carrier_Synchronizer_validOut`, `Preamble_Detector_validOut`, `Packet_Controller_validOut`; exports `w1Bus[255:0]` |
| 6 | `QPSK_Rx.v` | `w1_freeze = fixctl[4]` (or `1'b0` where the lineage has no `fixctl`), bus pass-through |
| 7 | `Receiver.v` | pass-through |
| 8 | `TxRxComposite.v` | pass-through |
| 9 | `TxRxCompo_ip_dut.v` | `w1_bus` out of the DUT wrapper |
| 10 | `TxRxCompo_ip_axi_lite.v` | `read_w1_bus` in |
| 11 | `TxRxCompo_ip_addr_decoder.v` | eight free read words + the hit/fallback `data_read` |
| 12 | `TxRxCompo_ip.v` | one internal wire joining 9 and 10 |

Every W1 signal is a tap. **No existing net is redefined and no existing `assign`
is removed** — which is why the s = 0 bit-identity claim is structural, not merely
measured. The one exception is by design and is the instrument's whole point:
`assign data_read` in the addr_decoder becomes
`(w1_hit ? w1_reg[w1_idx] : mux_out0_level1)`, with the generated mux kept as the
fallback, so nothing already decoded moves. Pinned by `test_50`.

### 2.1 Register map (full detail in `two_jup/rxfix/W1_REGMAP.md`)

| byte | word | name | fields |
|---|---|---|---|
| 0x214 | 0x85 | `W1_WITA` | `[15:10]` occTrue (0…32) · `[9:5]` pushPtr · `[4:0]` popPtr |
| 0x218 | 0x86 | `W1_WITB` | `[31:16]` push_on_full count · `[15:0]` pop_on_empty count (both wrap) |
| 0x21C | 0x87 | `W1_CNT_SS` | Symbol_Synchronizer strobe (ring push request) |
| 0x220 | 0x88 | `W1_CNT_RH` | Rate_Handle `validOut` |
| 0x224 | 0x89 | `W1_CNT_CFC` | Coarse_Frequency_Compensator `validOut` |
| 0x228 | 0x8A | `W1_CNT_CS` | Carrier_Synchronizer `validOut` |
| 0x22C | 0x8B | `W1_CNT_PD` | Preamble_Detector `validOut` |
| 0x230 | 0x8C | `W1_CNT_PC` | Packet_Controller `validOut` (after `sample_discard_controller`) |

Words `0x85`…`0x8C` were verified absent from the generated read mux before use
(`test_50` asserts it on the real seqbist decoder). Freeze = `fixctl` bit 4,
write-only register 0x208; bits 0…3 are `FixCtlDec`'s, 12 is TXCAP's, 13 is
DEMODCAP's, so bit 4 was free. All eight words are shadowed behind that one
freeze level, so one sweep is a coherent snapshot. Every counter and shadow is
gated by `enb_1_2_0`, as `dbgcap_process` and `ddrcap_sel_process` are — counting
raw `clk` would break the 12,333·K arithmetic the census exists to test.

### 2.2 Two deviations from the brief, both deliberate

**(a) The census does NOT go through `cnt_mux32`.** Reasons, in order:

1. `cnt_mux32` has **no free slots** on the 148 lineage. `cnt_mux32.v:2-5` and
   `patch_seqbist_tcl.py:28-43`: slots 0…15 are the BD counters
   (`acc_user`, frames, crc_ok/fail, magic_bad, short, orphan, acc_beats,
   8…15 `tx_starve_witness`), slots 16…31 are `rx_seq_checker`'s `cnt0…cnt15`.
2. More fundamentally, `cnt_mux32` is a **BD cell** while every W1 tap is inside
   the IP. Reaching it needs new `TxRxComposite` → `TxRxCompo_ip` top-level ports,
   and those land in `component.xml`. Verified on the kit: `ddrcap_*` **is** in
   `component.xml` (DDRCAP genuinely added top-level ports), `beatfix_viol_count`
   is **not** (AXI-lite read registers are IP-internal). W1 follows the second
   pattern, so `component.xml`, the BD tcl and `patch_seqbist_tcl.py` are all
   untouched, and the SEQ-BIST judge/`cnt_mux32`/0x9D4x GPIOs survive unchanged.
3. Eight free AXI read words cost a few hundred LUTs and no build-system change.

Adding a second `cnt_mux32` on a free select field would have meant BD tcl edits
for strictly less capability. Ruled acceptable by the controller
(ledger 13:58:09).

**(b) `ddrcap_sel = 12` skipped.** The brief allows skipping it if it threatens
WNS. It would add logic at `enb` rate into the DDRCAP mux with +0.11 ns routed
margin, and it would break the purely structural s = 0 bit-identity argument
(a data-path mux gains an input). The full-rate occupancy time series is a
nice-to-have; the census is the decisive reading. Skipped, and said so.

---

## 3. Sim gate

Full detail and the leg table: `two_jup/comb/RXFIX_W1_SIM_GATE.md`.

**GATE PASSED.** Four full-length legs on the tiled stimuli, comparing the eight
W1 register words against an independent reference computed in the driver from the
raw hierarchical taps **on every `enb_1_2_0` beat** — not only at the logged
per-frame rows, so a one-beat hole event cannot slip between samples.

| leg | stimulus | frames | delivered | beats compared | mismatches | verdict |
|---|---|---|---|---|---|---|
| `w1_p000` | `s_p000.iq`, 0 ppm, 8,139,780 samples | 165 | 164 | 8,239,781 | **0** | PASS |
| `w1_m10` | `s_m10.iq`, −10 ppm tiled, 10,359,720 samples | 211 | 209 | 10,459,721 | **0** | PASS |
| `base_p000` / `base_m10` | same stimuli, unpatched tree, same wrapper | 165 / 211 | 164 / 209 | — | — | data-path reference |

* **s = 0 bit identity:** `base_p000_deliv.txt` and `w1_p000_deliv.txt` are
  byte-identical, md5 `555fbb25362f14a3d36b60f6797152af`, 164 delivered frames.
  Free bonus: the −10 ppm pair is byte-identical too
  (`91680b59e9cebdae3b285953fea203ef`, 209 frames).
* **Edge events present, as the controller required:** the −10 ppm leg reaches the
  ring's EMPTY edge — `pop_on_empty` first fires at air frame 41 and ends at
  **21**, and the W1 register tracked the reference through every one of those
  events (frame 41 `1/1`, frame 73 `5/5`, end of leg `21/21`).
* **End-of-leg words, W1 vs reference, −10 ppm:** `cSS` 2,614,900 / 2,614,900 ·
  `cRH` 2,614,900 / 2,614,900 · `cCFC` 2,614,892 / 2,614,892 · `cCS` 2,614,889 /
  2,614,889 · `cPD` 2,602,549 / 2,602,549 · `cPC` 2,574,481 / 2,574,481 ·
  `witA` `0x00000294` (occ 0, push 20, pop 20) · `witB` `0x00000015` (poe 21,
  pof 0).
* **`push_on_full` stayed 0 on every RTL-in-loop leg** — these stimuli drain
  toward EMPTY and never reach FULL, so the FULL-edge half of `witB` is gated only
  by the unit test (T5). Said plainly rather than implied by the clean verdict.
* The AXI decode itself is **not** exercised in sim: the Verilator lineage has no
  `TxRxCompo_ip_*` wrapper, so the harness reads `QPSK_Rx.w1Bus` and slices it
  exactly as the decoder does. The decoder is covered by `test_50` and by Vivado
  elaboration.

---

## 4. Kit and build

### 4.1 Kit

`two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148` — derived from
`jupiter_byte_seqbist_kit.sh`, sourcing the SEQ-BIST kit
(`jupiter_byte_seqbist_build`, the tree that produced the flashed
`a1ff3c876d91`) so the `rx_seq_checker` judge, `cnt_mux32` and the three 0x9D4x
GPIOs stay in the image, and applying **W1 only** on top. It refuses a source kit
without `rx_seq_checker`, `IMPL_STRATEGY` or the routed-WNS gate; it re-verifies
the marker independently of the injector's own printout (3 loose mirrors × 12
files, plus both zip members enumerated by name); it asserts `0x20C`'s decode and
`fixctl`'s write decode survived; and it carries `TXFIX_VARIANT` and
`SEQBIST_VARIANT` over byte for byte, writing a new `RXFIX_VARIANT` beside them.

```
RXFIX_KIT_VERIFY_OK
RXFIX_KIT_DONE board=148 kit=…/jupiter_byte_rxfixw1_build
               src_kit=jupiter_byte_seqbist_build
               injector_commit=b5c39a10367a1bbe3a84d955eefee75765e000c5
```

Belt-and-braces before spending Vivado time: `verilator --lint-only --top-module
TxRxCompo_ip` on the patched kit netlist — clean.

### 4.2 Build

`build_txfix.sh` with `IMPL_STRATEGY=explore`, run **on hdl-dev-2** as a remote
`systemd-run --user` unit (`txfix-build-rxfixw1_build-1788544650`), launched from
a local `systemd-run --user` step — never a harness background job. Elapsed
01:55:51.

| | value |
|---|---|
| **routed WNS (the gate)** | **+0.071224 ns**, TNS 0.000, **0 failing endpoints** of 342,217 |
| routed WHS / THS | +0.009 ns / 0.000, 0 failing endpoints |
| `report_timing_summary` verdict | *All user specified timing constraints are met.* |
| modem-scoped WNS (`TIMING_GATE_WNS modem_dut`) | **1.544 ns** |
| BOOT.BIN md5 | **`2728dab3979a54616f1ad67f1ac8e8a7`** |
| banked as | `boot_known_good/BOOT.BIN.148.rxfixw1.2728dab3979a` (7,203,552 B, md5 re-verified after transfer) |

**The gate passed, and the margin change is not W1's.** The SEQ-BIST baseline
`a1ff3c876d91` closed at +0.112123 ns; W1 closes at +0.071224 ns, 41 ps tighter.
The critical path is the same one in both builds and it is **inside the vendor
`axi_adrv9001` IP**:

```
Source:      …/axi_adrv9001/inst/i_core/i_delay_cntrl_rx1/i_delay_rst_reg/rst_reg/C
Destination: …/axi_adrv9001/inst/i_if/i_rx_1_phy/i_serdes/i_delay_ctrl/RST
Path Group:  **async_default**   Path Type: Recovery, clk_pl_2 (2.000 ns / 500 MHz)
```

— a recovery check on the IDELAYCTRL reset, 94 % route delay, which W1 does not
touch and cannot influence except through global placement pressure. Two further
facts pin it: **no W1 net appears anywhere in the routed timing summary's reported
paths** (grep for `w1_reg` / `rh_w1_census` / `w1Bus` returns 0), and the
**modem-scoped post-synth WNS is identical between the two builds at 1.544 ns** —
i.e. W1 added exactly nothing to the modem clock domain's critical path.

Utilisation delta vs the SEQ-BIST baseline, whole design:

| | seqbist `a1ff3c876d91` | rxfixw1 `2728dab3979a` | delta |
|---|---|---|---|
| CLB LUTs | 47,120 (66.78 %) | 47,242 (66.95 %) | **+122** |
| CLB Registers | 109,761 (77.78 %) | 110,473 (78.28 %) | **+712** |
| Block RAM Tile | 66.5 | 66.5 | 0 |

+122 LUTs and +712 FFs, inside the brief's "a few hundred LUTs" ceiling. The FF
count is what an 8-word shadow bank (256), six 32-bit counters (192), two 16-bit
edge counters (32), the addr_decoder's eight registered read words (256) and the
plumbing add up to.

**STOPPED BEFORE FLASH, as briefed.** No board contact occurred at any point in
this task.

---

## 5. Reader script

`two_jup/rxfix/w1_read.sh` — K=V env, one sweep per **≥ 10 s** (a lower `PERIOD`
is clamped up with a logged warning), one JSON line per reading.

```
BOARD=148 N=6 DRY=1                     w1_read.sh     # zero board contact
BOARD=148 N=6 DRY=0 FIXCTL_BASE=0x8     w1_read.sh     # live, enSlack armed
BOARD=148 N=2 DRY=0 SSH=<shim> FREEZE=1 w1_read.sh     # offline shim test
```

* **Mechanism corrected from the brief.** The brief said "ssh devmem". Modem
  registers are not devmem-addressable on these images: every in-repo modem read
  goes through the IIO debugfs `direct_reg_access` node
  (`two_jup/seqbist/seqbist_run.sh:122-132`), and devmem is for the 0x9D4x BD
  GPIOs. `w1_read.sh` uses `direct_reg_access`, with that precedent cited in its
  header.
* **Freeze is never read-modify-written.** 0x208 is write-only; a freeze write
  sets the whole 32-bit `fixctl` word, so `FIXCTL_BASE` must carry whatever is
  currently armed (`enSlack` bit 3, TXCAP bit 12, DEMODCAP bit 13). The script
  writes `FIXCTL_BASE|0x10` to freeze and `FIXCTL_BASE` to release, and
  `W1_REGMAP.md` §2 spells out what a wrong `FIXCTL_BASE` silently clears.
* **Freeze is verified by effect.** Each reading sweeps all eight words **twice**
  inside the freeze window; `freeze_effective` is true iff all eight deltas are
  exactly 0. A `freeze_effective:false` reading is not a coherent snapshot and
  must be discarded.
* DRY tests: `DRY=1` emits N lines with zero ssh; `DRY=0 SSH=<shim>` exercises the
  real code path against a shim (verified: the shim received the expected
  `wr 0x208 0x18` / reads / `wr 0x208 0x8` script with `FIXCTL_BASE=8`).

Rig rules carried: keep polling at ≥ 1 s and never poll during an arm
(`direct_reg_access` traffic racing board state is what hangs these boards); the
10 s floor is well inside that.

---

## 6. Tests

| suite | count | result |
|---|---|---|
| `two_jup/skidfix/test_rxfix_inject.py` | 56 (39 pre-existing R1/R2/R3 + 17 new W1) | all pass |
| `rh_w1_census` RTL unit test (`build_w1_census.sh` → `obj_w1_census/Vrh_w1_census`) | 21 assertions incl. freeze hold/release, occ 32 vs 0, wrap | `W1CENSUS_UNIT PASS failures=0` |

The 17 new tests run the real patchers against **both real lineages** (`s1_rtl`
and the flashed seqbist tree), pin the free-address claim on the real decoder,
assert `TxRxCompo_ip`'s port list is byte-identical after patching (so
`component.xml` stays valid), assert no existing `assign` is lost in any of the
eight RTL files, and assert the per-file loose-copy count catches a tree that is
short exactly one file (the failure mode the old `nloose % len(want)` check could
mask now that W1 mixes prefixed and unprefixed basenames).

---

## 7. Concerns

1. **The routed margin is +0.071 ns, 41 ps tighter than the SEQ-BIST baseline's
   +0.112.** The gate passed with 0 failing endpoints and all constraints met, and
   §4.2 shows the path is a vendor `axi_adrv9001` IDELAYCTRL recovery check that is
   *the same worst path in the baseline build*, with no W1 net anywhere in the
   reported paths and an unchanged modem-scoped WNS. So the honest reading is
   placement variance on a vendor path, not W1 logic. It is still 41 ps less
   headroom than the image on the board today, and this design has a history of
   marginal closure — worth the controller knowing before the flash.

2. **`push_on_full` is not exercised RTL-in-loop.** Both sim legs drain toward the
   EMPTY edge (negative ppm on tiled stimuli), so the FULL-edge counter stayed 0
   and is gated only by the `rh_w1_census` unit test. On silicon, a `witB` upper
   half that stays 0 will therefore be *consistent with* both "no FULL-edge event"
   and "the counter does not work" — the falsifier in task-7-report §6.4 leans on
   `pop_on_empty`, which IS exercised, so this does not weaken the decisive
   reading, but it should not be over-read either.

3. **The AXI read decode is not exercised in simulation at all.** The Verilator
   lineage has no `TxRxCompo_ip_*` wrapper, so the harness reads `QPSK_Rx.w1Bus`
   and slices it exactly as the decoder does. The decode itself is covered by
   `test_50` (asserted against the real seqbist decoder, including that words
   0x85…0x8C are genuinely undecoded today) and by Vivado elaboration — but the
   first real proof that `0x214` returns `witA` will be the first board read.

4. **Freeze is the operational hazard, not the logic.** `fixctl` at 0x208 is
   write-only, so a freeze write sets the whole 32-bit word. Running
   `w1_read.sh FREEZE=1` with the default `FIXCTL_BASE=0` on a leg that has
   `enSlack` armed will silently disarm it (and flip the TXCAP/DEMODCAP mux bits)
   for the duration. `W1_REGMAP.md` §2 says this in as many words and the reader
   reports `freeze_effective` per reading, but it is a foot-gun that wants an
   explicit `FIXCTL_BASE` in whatever runbook the flash task writes.

5. **The 0 ppm leg shows `pop_on_empty` = 16 over 165 frames.** Not a W1 concern —
   the instrument agreed with the taps on every beat — but worth flagging to
   whoever reads the first silicon sweep: at nominal rate the ring still touches
   its EMPTY edge on this stimulus, so a non-zero `pop_on_empty` on the board is
   not by itself evidence of an SRO. The rate is what matters, against the
   pre-registered 1 per ~32.4 air frames.

6. **`sim_w1.cpp`'s reference is one enb beat behind by construction** (the
   post-edge tap read vs the pre-edge register sample, composed with the shadow's
   one-beat lag). That is derived and documented in the file header and in
   `RXFIX_W1_SIM_GATE.md` §1, and it is what makes the agreement exact rather than
   approximate — but it is the one place where a future edit could quietly turn a
   real fault into an apparent pass. Anyone changing that loop should re-derive it.

7. **Reader mechanism differs from the brief's wording** (`direct_reg_access`, not
   `devmem`). Justified in §5 against the in-repo precedent; flagged so it is not
   mistaken for drift.
