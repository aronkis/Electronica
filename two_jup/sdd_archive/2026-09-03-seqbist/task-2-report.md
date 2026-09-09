# Task 2 (T0b) — SEQ-BIST block-design patch — report

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` (T0b). Desk-only: no board
contact, no Vivado run, no push. 2026-09-03.

## Deliverables

| file | what |
|---|---|
| `two_jup/skidfix/patch_seqbist_tcl.py` | idempotent Tcl patcher (marker `SEQBIST_PATCH_V1`), `--lineage 148\|vendh` |
| `two_jup/skidfix/jupiter_byte_seqbist_kit.sh` | `<148\|146>` → derives `jupiter_byte_seqbist_build` / `jupiter_byte_seqbist146_build` |
| `two_jup/tests/test_patch_seqbist.py` | 45 tests (text + a tclsh netlist-model execution of the re-tap), **45 passed**, no Vivado |

## Where the patch goes, and why

`patch_seqbist_tcl.py` edits the kit's **`build_txfix.tcl`**, inserting a marked block
immediately after `report_ip_status -quiet` (IP catalog rebuilt → `get_ipdefs` works;
still before `generate_target all [get_files system.bd]` → the edited BD is regenerated).

It does **not** patch `complete_byte_t8.tcl` (which `patch_tgen_tcl.py` targets). That
file only runs inside a full MATLAB HDL-Coder regeneration, is never sourced by the kit
build, and on 148 does not even describe the BD in the kit: `cnt_mux`, `rx_checker`,
`sel_slice`, `tgen_rx_wit_gpio` were added incrementally by `resynth_probe{2,3,4}.tcl` /
`resynth_dmacprobe.tcl` and exist only in `system.bd`. Patching the build tcl is the only
edit that reaches the bitstream. One Vivado run still does BD edit → synth → impl →
bootgen, and the `IMPL_STRATEGY` hook plus the routed-WNS gate
(`TXFIX_ROUTED_WNS` / `TXFIX_ROUTED_TIMING_FAIL`) are untouched (asserted by the tests
and re-verified by the kit script).

## Lineage 148 (`jupiter_byte_txfixF3_build` → `jupiter_byte_seqbist_build`)

Cells **added**: `rx_seq` (`rx_seq_checker`), `sb_freeze_slice`, `sb_en_slice`,
`sb_mode_slice` (xlslice, 1 bit each).
Cells **replaced**: `traffic_gen` (`qpsk_traffic_gen` → `qpsk_traffic_gen_v2`),
`cnt_mux` (`cnt_mux16` → `cnt_mux32`).
Cell **reconfigured**: `sel_slice` `DIN_FROM 31 DIN_TO 28 DOUT_WIDTH 4` →
`31 / 27 / 5`.
**No** new AXI slave: `NUM_MI` stays **17** — the patch asserts this at run time
(`SEQBIST_FAIL(148) NUM_MI changed`). No `assign_bd_address` on this lineage.

Nets: `rx_seq/{data,valid,user,ready}` tap the same four DUT RX nets `rx_checker` uses
(`dut_byte_data_out / valid_out / user_out / ready_in`); `clk` = `axi_adrv9001/adc_1_clk`
net, `rst_n` = `rx_rstn_inverter/Res` net; `cnt_mux/q` → `tgen_rx_wit_gpio/gpio2_io_i`;
`sel_slice/Dout` → `cnt_mux/sel`.

**Re-runnability:** every `create_bd_cell` in the emitted block is preceded by a guarded
delete (or, for the 146 GPIOs, an "already exists → skip" branch), so re-running the
patched `build_txfix.tcl` against an already-patched project — a rebuild after a failed
synth, or Task 5's `--dry` → real sequence — does not hard-error. The vendh cross-lineage
guard probes `rx_checker`/`tx_checker`/`tx_starve`/`traffic_gen_rx` (cells only 148 has and
this patch never creates), never the cells it adds itself. A test enforces both.

**Load-bearing detail (review C-1, fixed in fix round 1).** A module-ref cell's reference
cannot be retargeted in place, so `traffic_gen` is deleted and recreated — which destroys
every net it drives and orphans *every other consumer* of those nets. On the live 148 BD
`traffic_gen_dut_valid` has **five** pins: `traffic_gen/dut_valid`,
`TxRxCompo_ip_0/dut_byte_valid_in`, `tx_checker/valid`, **`beat_ila/probe15`** (system_ila)
and `tx_starve/valid`. The first version re-tapped a hard-coded six pins and would have
silently dropped `beat_ila/probe15` — and `save_bd_design` persists that into the kit's own
`system.bd`.

The re-tap is now **generic**: before the delete the block enumerates every pin on every net
the cell drives (`get_bd_pins -of_objects [get_bd_nets -of_objects traffic_gen/<out>]`,
excluding `traffic_gen`'s own pins), and after the recreate re-connects them all and asserts
each driven (`SEQBIST_RETAP_CAPTURED n=…` / `SEQBIST_RETAP_OK captured=… reconnected=…`).
It needs no cell list, so lineages without `beat_ila` / `tx_checker` / `tx_starve` just
capture fewer pins, and a future consumer is covered for free. On 148 the consumers known at
review time — including `beat_ila/probe15` — are additionally named in an existence-guarded
`sb_require_driven` sweep so losing any one of them fails the build.

This is verified by **executing** the emitted capture/restore Tcl under `tclsh` against a
stub BD model with a six-pin valid net (incl. a `future_probe`): all 10 captured consumers
come back on the driver's net.

## Lineage vendh / 146 (`jupiter_byte_txfixF3vendh_build` → `jupiter_byte_seqbist146_build`)

Confirmed by netlist inspection: the vendh `system.bd` has **none** of the chain (only
`byte_breakout`, `rx_byte_breakout`, `byte_ctrl_gpio`, the two byte DMAs), and its
`complete_byte_t8.tcl` stops at `BYTE_WIRE_OK`.

Cells added: `traffic_gen` (`qpsk_traffic_gen_v2`, spliced at the TX byte pins exactly as
`patch_tgen_tcl.py` does), `rx_seq`, `cnt_mux` (`cnt_mux32`), `sel_slice`, the three
1-bit slices, `sb_zero32` (xlconstant, 32'h0), and three `axi_gpio`:

| GPIO | address | config | use |
|---|---|---|---|
| `tgen_ctrl_gpio` | **0x9D400000** | dual, all outputs | TGEN v2 ctrl / gap |
| `tgen_rx_ctrl_gpio` | **0x9D410000** | dual, all outputs | SEQBIST ctrl bits + mux select |
| `tgen_rx_wit_gpio` | **0x9D450000** | dual, all inputs | ch1 = 0, ch2 = `cnt_mux/q` |

Same addresses as 148. `NUM_MI` **11 → 14** (asserted: `expected +3`). Omitted on 146 as
allowed: `tx_checker`/`txchk_gpio` (0x9D420000 unused), `traffic_gen_rx`, `tx_starve`.
Therefore **cnt_mux32 slots 0–15 are tied to `sb_zero32` and read back 0 on 146** — Task 4's
`seqbist_read.py` and Task 5's scorer must be lineage-aware.

## Control-bit map (identical on both lineages)

```
0x9D400000 tgen_ctrl   -> traffic_gen(v2).ctrl : [0] en, [15:4] fill, [31:16] skip/corrupt
0x9D400008 tgen_gap    -> traffic_gen(v2).gap  : [26:0] gap clks, [27] skip|corrupt mode
                                                 ([31:28] unused by v2 — a spare word)
0x9D410000 tgen_rx_ctrl: [3] rx_seq freeze
                         [4] rx_seq en        (RISING EDGE clears all counters)
                         [5] rx_seq tgen_mode (1 = accept CRC field 0x54474E21)
0x9D410008 tgen_rx_gap : [31:27] cnt_mux32 select (was [31:28]); [26:0] gap clks
0x9D450000 wit ch1     : traffic_gen_rx.acc_beats (148) / 0 (146)
0x9D450008 wit ch2     : cnt_mux32.q   <-- the 32-slot readout
```

Slot map: **0–15 unchanged** from `resynth_probe4.tcl` (0 acc_user, 1 frames, 2 crc_ok,
3 crc_fail, 4 magic_bad, 5 short_frm, 6 orphan_w, 7 acc_beats, 8–15 tx_starve) — a test
diffs the source-pin→slot mapping against `resynth_probe4.tcl` itself.
**16–31 = `rx_seq/cnt0..cnt15`** in the Task-1 interface-contract order.

### Two aliasing facts the host tools must respect
1. **148 only:** the 0x9D410000 word also drives `qpsk_traffic_gen_rx2.ctrl`
   (`[0] en [1] last_en [2] user_mask [15:4] fill_len [31:16] word_gap`). Bit 3 is
   genuinely spare, but **bits 4 and 5 alias `fill_len[1:0]`**. Harmless while the Layer-B
   RX generator is disabled (`ctrl[0]=0`, its reset state) — the two instruments are
   **mutually exclusive**; never run them in the same window. No aliasing on 146.
   (Alternative if this ever bites: `tgen_gap[31:28]` at 0x9D400008 is genuinely unused by
   `qpsk_traffic_gen_v2` and could carry en/tgen_mode instead — a one-line patcher change.)
2. The mux select widened to `gap[31:27]`, so the gap value at **0x9D410008 must stay
   below 2^27** (134 M clks). Every value in use is ≤ 2e5.

## What Task 5 (build driver) must run

```
two_jup/skidfix/jupiter_byte_seqbist_kit.sh 148     # -> jupiter_byte_seqbist_build
cd jupiter_byte_seqbist_build && IMPL_STRATEGY=explore ./build_txfix.sh [--dry]

two_jup/skidfix/jupiter_byte_seqbist_kit.sh 146     # -> jupiter_byte_seqbist146_build
cd jupiter_byte_seqbist146_build && ./build_txfix.sh        # IMPL_STRATEGY *UNSET*
```
* **146 must NOT set `IMPL_STRATEGY`** — the vendh template deliberately `exit 1`s
  (`TXFIX_VENDH_IMPL_STRATEGY_REFUSED`) because `explore` would overwrite
  `PLACE_DESIGN=ExtraNetDelay_high`, the only thing that carries the vendh lineage.
* The kit script widens `build_txfix.sh`'s `case "$KIT"` guard to accept
  `jupiter_byte_seqbist*_build` (the original only accepts `jupiter_byte_txfix*_build`);
  `REMOTE_DIR` and the systemd unit still derive from the kit basename, and the unit still
  matches the `txfix-build-*` concurrency preflight.
* `TXFIX_VARIANT` is carried over byte for byte (`F3`) — `build_txfix.sh` reads line 1 and
  the vendh `TXFIX_IPSHARED_VERIFY` exits 1 on an unknown variant. `SEQBIST_VARIANT`
  (lineage / patcher commit / src kit / RTL md5s) is a new marker beside it.
* Success markers in the Vivado log, in order: `SEQBIST_TGEN_V2_OK`,
  `SEQBIST_TXSNOOP_RETAP_OK` (148), `SEQBIST_GPIO_OK ×3` (146), `SEQBIST_RXSEQ_OK`,
  `SEQBIST_CNTMUX32_OK num_mi=`, `SEQBIST_WIRE_OK lineage=`, then the usual
  `TIMING_GATE_WNS`, `TXFIX_ROUTED_WNS`, `BYTE_BUILD_DONE md5=`, `TXFIX_BUILD_DONE`.
  Any `SEQBIST_FAIL*` is a hard `exit 1` before synthesis.

## Verification done

* `python3 -m pytest two_jup/tests/test_patch_seqbist.py -q` → **29 passed**
  (idempotence byte-for-byte; cells/addresses exactly once; slots 0–15 diffed against
  `resynth_probe4.tcl`; slots 16–31 = cnt0..cnt15; rails survive; NUM_MI guards;
  TX-snoop re-tap; every `create_bd_cell` guarded so the Tcl is re-runnable; the vendh
  cross-lineage guard probes only 148-exclusive cells; **every `<cell>/<pin>` the Tcl
  emits for `rx_seq` / `cnt_mux` / `traffic_gen` is checked against the port list parsed
  out of the three `.v` files**; refusals on missing file / anchor / rails / wrong lineage;
  a lineage mismatch on an already-patched file is an error, not a silent no-op; and two
  `tclsh` tests that execute the re-tap regions against a stub netlist model — a
  6-consumer net yields 10 captured pins all re-driven, and a BD with no `traffic_gen`
  is a clean `captured=0 reconnected=0` no-op).
* `jupiter_byte_seqbist_kit.sh 148` executed for real against the live kit → `SEQBIST_KIT_DONE`,
  `SEQBIST_KIT_VERIFY_OK`; the resulting kit dir was then **deleted** because its
  `SEQBIST_VARIANT` recorded `patcher_commit=UNCOMMITTED`. Task 5 recreates it post-commit.
* Both lineages executed against a stub `REPO` (real build tcl/sh + TXFIX_VARIANT + RTL,
  no GB copy) → `SEQBIST_KIT_VERIFY_OK` / `SEQBIST_KIT_DONE` for 148 and 146; re-run correctly refuses (`SEQBIST_KIT_REFUSE_ALREADY_TAGGED`);
  with `RTL_SRC` pointed at a missing dir it fails loudly (`SEQBIST_KIT_NO_RTL`).
* Task-1 RTL landed during this task and the ports match the contract exactly:
  `rx_seq_checker(clk,rst_n,en,freeze,tgen_mode,data[63:0],valid,user,ready → cnt0..cnt15)`,
  `cnt_mux32(clk,sel[4:0],c0..c31 → q)`, `qpsk_traffic_gen_v2` = same ports as
  `qpsk_traffic_gen`.
* **Not** verified: no Vivado ran. `validate_bd_design`, the actual net stitching,
  utilisation and timing are unproven until T1's build.

## Fix round 1 (review `task-2-review.md`, 2026-09-03)

* **C-1 fixed** — generic consumer capture/restore around the `traffic_gen` delete (above),
  plus a named existence-guarded assertion list on 148 that includes `beat_ila/probe15`.
* **M-1 fixed** — the precedent's `TGEN_WARN` diagnostic is restored in the vendh `sb_gpio`
  `M##_ACLK` block as `SEQBIST_WARN: <M##_AXI> clock unwired` (the three `catch`'d variants
  are kept for parity; on this smartconnect they are expected to miss).
* **M-2 fixed** — both preamble guard lists now include `TxRxCompo_ip_0`, `axi_adrv9001`,
  `rx_rstn_inverter` and `axi_hpm0_lpd_interconnect`, so a wrong BD fails with a
  `SEQBIST_FAIL` line instead of a raw Vivado error. A test enforces the coverage.
* **M-3 fixed** — `--lineage X` against a file already patched for lineage Y now exits 1
  with `already patched for lineage 'Y'`, instead of a silent `SEQBIST_PATCH_NOOP`.
* **I-1 not actioned here** — the missing CDC synchronizer on `{en, freeze, tgen_mode}`
  crossing `sys_cpu_clk` → `adc_1_clk` is RTL, owned by Task 1. Flagged onward: `en` is
  *edge*-detected in `rx_seq_checker.v`, so two flops in the checker are needed; a BD-level
  fix would be a `xpm_cdc_array_single` between the slices and the checker if Task 1 declines.

## Fix round 2 (2026-09-03) — `WITH_CRC` cell property

Task 1 gave `rx_seq_checker` `parameter integer WITH_CRC = 1`; `0` omits the CRC32
datapath entirely (the compile-time escape hatch for a routed-WNS / utilisation failure —
every `tgen_mode` stage works without it). The patcher now sets it as a module-reference
cell property on `rx_seq`, on **both** lineages:

```tcl
set _sb_with_crc <baked-in default>            ;# from --with-crc, default 1
if {[info exists ::env(SEQBIST_WITH_CRC)] && ...} { set _sb_with_crc $::env(SEQBIST_WITH_CRC) }
set_property CONFIG.WITH_CRC $_sb_with_crc [get_bd_cells rx_seq]
```

* `patch_seqbist_tcl.py --with-crc 0|1` bakes the default (1).
* `jupiter_byte_seqbist_kit.sh` threads `SEQBIST_WITH_CRC` (default 1) into the patch,
  verifies the baked value landed, and records `WITH_CRC=` as line 5 of `SEQBIST_VARIANT`.
* **The build driver (Task 5) can flip it per run with `SEQBIST_WITH_CRC=0` without
  re-patching the kit** — the emitted Tcl reads the env at build time and prints
  `SEQBIST_WITH_CRC <v>` / `SEQBIST_RXSEQ_WITH_CRC <v>`. A bad value is a `SEQBIST_FAIL`.
* Idempotence is unchanged: a second patch run is a no-op even with a different
  `--with-crc` (the marker wins; the env knob is the way to change it afterwards).

Also noted: Task 1 landed two-flop synchronizers on `{en, freeze, tgen_mode}`
(`rx_seq_checker.v` "control synchronizers (PS AXI clock -> adc_1_clk)"), which closes
review item **I-1**; no BD-level CDC is needed.

## Risks

| risk | severity | response |
|---|---|---|
| **Timing.** `rx_seq_checker` carries an unrolled 64-bit CRC32 on the DUT RX clock — the same structure as `rx_seam_checker`, which closes on 148, but this is *additive* on a lineage with thin WNS margins. `cnt_mux32` also doubles the mux depth. | high | 148 builds with `IMPL_STRATEGY=explore`; routed-WNS gate refuses to produce BOOT.BIN at WNS < 0. If it fails, drop the CRC path (`tgen_mode` = magic-only) before touching placement. On **146 the place directive is fixed** (`ExtraNetDelay_high`) — the only levers are PHYS_OPT/ROUTE directives. |
| `traffic_gen` delete/recreate silently orphaning consumers (`tx_checker`, `tx_starve`, **`beat_ila/probe15`**, anything added later) — and `save_bd_design` persisting the damage | high (closed) | generic capture-before-delete / restore-after-recreate of every consumer of every net the cell drives, each asserted driven; verified by executing the Tcl under `tclsh` against a stub netlist |
| 146 image is **"tmrfresh + TXFIX-F3 + SEQBIST @ ExtraNetDelay_high"**, not vendh — the v_endh placement cannot be reproduced once the BD changes | med | already stated in `txfix_build_vendh.tcl.tmpl`; the BD change makes it doubly true. Do not quote v_endh byte-plane margins for this image. |
| 148 ctrl bits 4/5 alias `traffic_gen_rx` `fill_len[1:0]` | med | documented above; instruments are mutually exclusive; 146 is clean. Fallback: `tgen_gap[31:28]`. |
| 146 slots 0–15 read 0 (no rx_checker / tx_starve / tgen_rx) | med | host tools must be lineage-aware; `SEQBIST_VARIANT` line 1 says which |
| `cnt_mux32` module-ref cell has 33 inputs; a mis-typed pin name would only surface in Vivado | low (closed) | `test_tcl_pin_names_match_the_rtl` parses the port lists out of `rx_seq_checker.v`, `cnt_mux32.v`, `qpsk_traffic_gen_v2.v` and asserts every pin the Tcl types exists — a desk-time failure, not a build-time one. Still run the 148 build first and read the `SEQBIST_*_OK` markers before the 146 build. |
| Adding 3 AXI slaves on 146 (NUM_MI 11→14) can perturb the interconnect's own timing | low | asserted `+3`; the same pattern is already in the flashed 148 image |
