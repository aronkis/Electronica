# Task 5 (T1a) — SEQ-BIST 148 image build — report

Plan `/home/tcollins/.claude/plans/happy-bubbling-owl.md` T1, build half only.
**No flash** (gated on Task 3's sim gate). No board contact (10.0.0.146/148 untouched).
Host: hdl-dev-2 (10.0.0.11), Vivado 2025.1, JOBS=6. 2026-09-03.

## Preflight (hdl-dev-2)

```
ssh hdl-dev-2 'hostname; uptime; df -Pk $HOME; nproc; pgrep -a -f vivado;
               systemctl --user list-units --state=running,active "txfix-build-*" "ddrcap-build-*"'
```
21:06 EDT — load 0.08, **no vivado process**, **no active build unit**,
free 64,431,144 KB = **61 GB** (≥ 40 GB required). Host free → build authorised.

## Commands run

```
two_jup/skidfix/jupiter_byte_seqbist_kit.sh 148          # -> jupiter_byte_seqbist_build
cd jupiter_byte_seqbist_build && IMPL_STRATEGY=explore ./build_txfix.sh --dry
cd jupiter_byte_seqbist_build && IMPL_STRATEGY=explore ./build_txfix.sh
# after TXFIX_BUILD_DONE:
BOARD=148 TXFIX_TAG=seqbist ./jupiter_byte_txfix_fetch.sh jupiter_byte_seqbist_build
```

Kit (21:08:44–21:08:47):
```
SEQBIST_PATCH_OK lineage=148 with_crc=1 ... bytes=15431
SEQBIST_KIT_VERIFY_OK
SEQBIST_KIT_DONE board=148 lineage=148 src_kit=jupiter_byte_txfixF3_build
                 patcher_commit=d9bed752101e4a48daf3a8c21495c4daa1b22a52
```
`SEQBIST_VARIANT`: `148 / d9bed75… / SRC_KIT=jupiter_byte_txfixF3_build /
RTL: qpsk_traffic_gen_v2.v=e085adeed456958354b53bc76d9615e5
rx_seq_checker.v=15aa6c6da8704fcebb8cc0f8a7b7a549 cnt_mux32.v=414ffbf5986992bb403389d54ae138f2 /
WITH_CRC=1`. `TXFIX_VARIANT` = `F3`, carried byte for byte.

## Baseline for the utilisation delta (txfixF3, the flashed 148 image f6a8c3ea119c)

`~/qpsk-builds/jupiter_byte_txfixF3_build/.../impl_1/system_top_utilization_placed.rpt`

| | LUT | LUT as logic | FF | CARRY8 |
|---|---|---|---|---|
| txfixF3 | 45284 (64.18 %) | 39618 | 108605 (76.96 %) | 1476 |

txfixF3 routed WNS **+0.095307** / TNS 0 (log line `TXFIX_ROUTED_WNS`).

## Finding: `SEQBIST_WITH_CRC` did not reach the remote Vivado (fixed)

Task 2's report states the build driver can flip `SEQBIST_WITH_CRC=0` per run without
re-patching the kit. As shipped it could not: `txfix_build.sh.tmpl` threaded only
`PATH/JOBS/IMPL_STRATEGY/VARIANT` through the ssh launch and the four `--setenv=` lines, so
the emitted Tcl's `info exists ::env(SEQBIST_WITH_CRC)` was always false remotely and the
baked default (1) always won. Fixed in `two_jup/skidfix/txfix_build.sh.tmpl` (and in the
kit's installed copy) by threading `SEQBIST_WITH_CRC` through both. An unset value is
passed as the empty string, which the Tcl's `string is integer -strict` rejects, so the
baked default still wins when the knob is not used — behaviour for every existing kit is
unchanged. **This build ran with WITH_CRC=1** (the intended default).

## If the routed-WNS gate fires

`build_txfix.tcl` prints `TXFIX_ROUTED_TIMING_FAIL wns=<w>` and `exit 1`s **before**
bootgen, so no BOOT.BIN exists and nothing is banked (precedent: F3 attempt 2's WNS-failing
image was kept remotely, never banked). The failing paths come from
`.../vivado_prj.runs/impl_1/system_top_timing_summary_postroute_physopted.rpt`
(and `system_top_timing_summary_routed.rpt`), both confirmed present in the F3 baseline run.

## Attempt 1 — BD patch stage (21:09:25 launch, synth launched 21:10:40)

Unit `txfix-build-seqbist_build-1788484165` (systemd-run --user on hdl-dev-2, `timeout 14400`).
Vivado log markers, in order, all present, no `SEQBIST_FAIL`:

```
SEQBIST_WITH_CRC 1
SEQBIST_RETAP_CAPTURED n=9 pins=... /beat_ila/probe15 ...
SEQBIST_RETAP_OK captured=9 reconnected=0
SEQBIST_TGEN_V2_OK
SEQBIST_TXSNOOP_RETAP_OK
SEQBIST_RXSEQ_WITH_CRC 1
SEQBIST_RXSEQ_OK
SEQBIST_CNTMUX32_OK num_mi=17
SEQBIST_WIRE_OK lineage=148
=== synth ===
=== impl strategy: explore ... ===   (expected after the pre-impl timing gate)
```

`reconnected=0` is **correct, not a miss**: the splice deletes only the `byte_breakout`-side
nets, so the surviving `traffic_gen_dut_*` nets keep `tx_checker` / `tx_starve` /
`beat_ila/probe15` / `TxRxCompo_ip_0`; connecting the recreated cell's output to the
TxRxCompo pin merges it onto that same net, so no captured consumer needed an explicit
reconnect. All 9 captured pins were then asserted driven by `sb_require_driven` (a failure
there is a hard `exit 1` before synthesis) — `beat_ila/probe15`, the review C-1 case, among
them.

## Attempt 1 — impl and result (ONE attempt, no retry needed)

| stage | time (EDT) | outcome |
|---|---|---|
| launch | 21:09:25 | unit `txfix-build-seqbist_build-1788484165`, JOBS=6, IMPL_STRATEGY=explore |
| BD patch | 21:09:3x-21:10:40 | all `SEQBIST_*_OK`, no `SEQBIST_FAIL` |
| synth | 21:10:40-21:29 | `TIMING_GATE_WNS modem_dut=1.544 overall=-1.119` → `TIMING_GATE_PASS` (modem_dut identical to the txfixF3 baseline) |
| impl+bit | 21:29-22:24 | explore strategy echo confirmed in the log |
| done | 22:24:18 | **75 min wall** |

```
=== impl strategy: explore (ExtraTimingOpt place, AggressiveExplore route + phys_opt pre/post route) ===
TXFIX_ROUTED_WNS wns=0.112123 tns=0.000000
BYTE_BUILD_DONE md5=a1ff3c876d91f1a0330254cf10902748
TXFIX_BUILD_DONE variant=F3 md5=a1ff3c876d91f1a0330254cf10902748 wns=1.544
```

**Routed WNS +0.112123 ns, TNS 0.000** — passes the gate, and marginally better than the
txfixF3 baseline (+0.095307). Post-synth modem WNS 1.544 ns, unchanged. No
`TXFIX_ROUTED_TIMING_FAIL`, no retry, no `.Xil` clear needed (contrast §2: F3 needed 3).

## Utilisation delta (`system_top_utilization_placed.rpt`, both sides)

| | txfixF3 (f6a8c3ea119c) | seqbist (a1ff3c876d91) | delta |
|---|---|---|---|
| CLB LUTs | 45284 (64.18 %) | **47120 (66.78 %)** | **+1836** |
| LUT as Logic | 39618 | 41470 | +1852 |
| LUT as Memory | 5666 | 5650 | −16 |
| CLB Registers (all FF) | 108605 (76.96 %) | **109761 (77.78 %)** | **+1156** |
| Register as Latch | 0 | **0** | 0 (no latch inference) |
| CARRY8 | 1476 | 1555 | +79 |
| F7 / F8 Muxes | 1204 / 181 | 1250 / 150 | +46 / −31 |

Task 1 estimated ≈ +1,000–1,400 LUT / +1,120 FF for `rx_seq_checker` + `cnt_mux32`.
FF lands on the estimate (+1156); LUT is ~30 % above the top of the band (+1836), consistent
with the unrolled CRC32 tree (`WITH_CRC=1`) plus the doubled mux depth. Not a problem at
+0.112 ns routed WNS and 66.8 % LUT / 77.8 % FF — but it is the number that would justify a
`SEQBIST_WITH_CRC=0` rebuild if a later lineage runs out of margin.

## Banked image

```
BOARD=148 TXFIX_TAG=seqbist ./jupiter_byte_txfix_fetch.sh jupiter_byte_seqbist_build
TXFIX_FETCH_DONE variant=F3 dest=BOOT.BIN.148.seqbist.a1ff3c876d91
                 md5=a1ff3c876d91f1a0330254cf10902748
BOOT.BIN.148.seqbist.a1ff3c876d91: OK      # md5sum -c re-verify
```
* path: `boot_known_good/BOOT.BIN.148.seqbist.a1ff3c876d91`
* md5: `a1ff3c876d91f1a0330254cf10902748`
* `boot_known_good/MD5SUMS` row appended and verified; `boot_known_good/README.md` row
  appended and then **hand-corrected** — the fetch script composes the row text from
  `TXFIX_VARIANT`, which was carried over byte-for-byte from txfixF3 and has no `SRC_KIT=`
  line, so it wrote the historical "fix build from jupiter_byte_ddrcap2_build … via
  txfix_inject.py" wording. The row now names the SEQ-BIST patch, the patcher commit,
  `WITH_CRC=1` and the routed WNS. Marked **BUILT, NOT flashed, sim gate pending**.

## NOT done in this task

* **No flash.** 10.0.0.148 and 10.0.0.146 were never contacted. The flash is a separate
  step gated on Task 3's sim gate; rollback target stays `f6a8c3ea119c`.
* **No 146 build.** Task 2's report also lists a `jupiter_byte_seqbist_kit.sh 146` command;
  out of scope here.

## Notes forward

* **For the 146/T4 driver:** the `SEQBIST_WITH_CRC` passthrough fix landed in
  `two_jup/skidfix/txfix_build.sh.tmpl`, but the vendh kit's *already-installed*
  `build_txfix.sh` predates it, so a 146 seqbist kit derived from that source reproduces the
  gap. Either re-apply the two-line change to the 146 kit's `build_txfix.sh` or bake the
  value with `SEQBIST_WITH_CRC=0 jupiter_byte_seqbist_kit.sh 146`.
* `SEQBIST_VARIANT` is not committed: `jupiter_byte_*_build/` is `.gitignore`d and no kit
  marker has ever been tracked (`git ls-files | grep VARIANT` → none). Its contents are
  transcribed verbatim above.
* hdl-dev-2 free disk: 61 GB before the 148 build, 59 GB after it, 59 GB after the 146 build.


---

# Part (b) — SEQ-BIST 146 image build (vendh lineage)

Same rails, still **no flash**, boards never contacted. hdl-dev-2 re-checked free at 22:25
(59 GB, no vivado, no active build unit) before launching.

## Commands

```
two_jup/skidfix/jupiter_byte_seqbist_kit.sh 146          # -> jupiter_byte_seqbist146_build
cd jupiter_byte_seqbist146_build && env -u IMPL_STRATEGY ./build_txfix.sh --dry
cd jupiter_byte_seqbist146_build && env -u IMPL_STRATEGY ./build_txfix.sh
BOARD=146 TXFIX_TAG=seqbist ./jupiter_byte_txfix_fetch.sh jupiter_byte_seqbist146_build
```
`env -u IMPL_STRATEGY` is deliberate — the vendh build tcl `exit 1`s with
`TXFIX_VENDH_IMPL_STRATEGY_REFUSED` on `explore` because it would overwrite
`PLACE_DESIGN=ExtraNetDelay_high`. The `--dry` output confirmed `IMPL_STRATEGY=''` before
the real launch. The same two-line `SEQBIST_WITH_CRC` passthrough was applied to this kit's
installed `build_txfix.sh` (it was copied from the vendh source kit, which predates the
template fix).

`SEQBIST_VARIANT`: `vendh / d9bed75… / SRC_KIT=jupiter_byte_txfixF3vendh_build / (same three
RTL md5s as the 148 kit) / WITH_CRC=1`. `TXFIX_VARIANT` = `F3`.

## Attempt 1 — ONE attempt, no retry

| stage | time (EDT) | outcome |
|---|---|---|
| launch | 22:26:34 | unit `txfix-build-seqbist146_build-1788488793`, JOBS=6, IMPL_STRATEGY unset |
| BD patch | 22:26:4x-22:27:2x | `SEQBIST_GPIO_OK` ×3, `SEQBIST_RXSEQ_OK`, `SEQBIST_CNTMUX32_OK num_mi=14`, `SEQBIST_WIRE_OK lineage=vendh`; no `SEQBIST_FAIL` |
| synth | 22:27-22:46 | `TIMING_GATE_WNS modem_dut=2.874` → PASS (identical to the vendh baseline) |
| impl+bit | 22:46-23:06 | `TXFIX_VENDH_PLACE_DIRECTIVE ExtraNetDelay_high` |
| done | 23:06:43 | **40 min wall** |

```
SEQBIST_GPIO_OK tgen_ctrl_gpio    offset=0x9D400000 m_port=M11_AXI
SEQBIST_GPIO_OK tgen_rx_ctrl_gpio offset=0x9D410000 m_port=M12_AXI
SEQBIST_GPIO_OK tgen_rx_wit_gpio  offset=0x9D450000 m_port=M13_AXI
SEQBIST_CNTMUX32_OK num_mi=14          # 11 + 3, as asserted by the patcher
SEQBIST_RETAP_OK captured=0 reconnected=0   # expected: the vendh BD has no traffic_gen to re-tap
TXFIX_ROUTED_WNS wns=0.166083 tns=0.000000
BYTE_BUILD_DONE md5=3378861d30bd3d85663b31cfdd9c6296
TXFIX_BUILD_DONE variant=F3 md5=3378861d30bd3d85663b31cfdd9c6296 wns=2.874 place_directive=ExtraNetDelay_high
```

**Routed WNS +0.166083 ns, TNS 0.000** — passes the gate (vendh baseline +0.192528, so
−0.026 ns of margin spent on the instrument). Post-synth modem WNS 2.874 unchanged.

### The 18 `connect_bd_net` ERROR lines — verified benign, and why

Each `sb_gpio` block emitted 6 `ERROR: [BD 41-84] required object is not specified` /
`ERROR: [BD 5-4] running connect_bd_net` pairs; 18 lines over the three GPIOs. Checked
against `patch_seqbist_tcl.py:379-393` rather than assumed:

* the **GPIO's own** `s_axi_aclk` / `s_axi_aresetn` are connected by an **un-`catch`'d**
  `connect_bd_net -net $src [get_bd_pins $name/$sfx]` (source = the nets already driving
  `byte_ctrl_gpio`'s clock/reset). An un-caught `connect_bd_net` failure aborts the Tcl, so
  the fact that each block went on to print `SEQBIST_GPIO_OK` **is** the evidence that both
  connections succeeded. The instrument registers are clocked.
* the 6 errors per block are exactly the **three `catch`'d** attempts at the *interconnect's*
  per-master `M##_ACLK` / `M##_ARESETN` pins (2 error lines each × 3 variants), kept for
  parity with `patch_tgen_tcl.py`. This is an AXI SmartConnect, which has one `aclk` and no
  per-master clock pins, so `get_bd_pins M11_ACLK` returns empty and `connect_bd_net` reports
  "required object is not specified". Master-to-clock association is by connectivity.
* the absence of `SEQBIST_WARN` is consistent with that and not evidence of anything on its
  own: the WARN only fires when a per-master `ACLK` pin **exists** and is unwired. Here no
  such pin exists, so the guard correctly stays silent.

## Utilisation delta (`system_top_utilization_placed.rpt`, both sides)

| | txfixF3vendh (6b4744ca73f8) | seqbist146 (3378861d30bd) | delta |
|---|---|---|---|
| CLB LUTs | 43373 (61.47 %) | **46098 (65.33 %)** | **+2725** |
| LUT as Logic | 38852 | 41572 | +2720 |
| LUT as Memory | 4521 | 4526 | +5 |
| CLB Registers (all FF) | 102316 (72.50 %) | **104912 (74.34 %)** | **+2596** |
| Register as Latch | 0 | **0** | 0 |
| CARRY8 | 1248 | 1337 | +89 |
| F7 / F8 Muxes | 1404 / 163 | 1535 / 226 | +131 / +63 |

Roughly **double the 148 delta** (+1836 LUT / +1156 FF), as expected: on 148 the patch adds
only `rx_seq_checker` + `cnt_mux32`, whereas on vendh it adds the entire chain the BD lacked
— `qpsk_traffic_gen_v2` (with its PN payload generator), the three `axi_gpio`, and the
interconnect ports for them, on top of the checker and the mux.

## Banked image

* path: `boot_known_good/BOOT.BIN.146.seqbist.3378861d30bd`
* md5: `3378861d30bd3d85663b31cfdd9c6296`
* `MD5SUMS` row appended and re-verified (`md5sum -c` → OK); `README.md` row inserted into
  the 146 table and hand-corrected (the fetch script's derived text again named the wrong
  lineage/injector — it read `SRC_KIT=` correctly here but still says "via txfix_inject.py").
  Row records the vendh lineage, the added GPIOs/addresses, `NUM_MI 11→14`, the preserved
  place directive, routed WNS, the "slots 0–15 read 0" caveat, the "not v_endh" caveat, and
  **BUILT, NOT flashed, sim gate pending**.

## Both images at a glance

| board | bank file | md5 | routed WNS / TNS | ΔLUT | ΔFF | wall |
|---|---|---|---|---|---|---|
| 148 | `BOOT.BIN.148.seqbist.a1ff3c876d91` | `a1ff3c876d91f1a0330254cf10902748` | **+0.112123** / 0 | +1836 | +1156 | 75 min |
| 146 | `BOOT.BIN.146.seqbist.3378861d30bd` | `3378861d30bd3d85663b31cfdd9c6296` | **+0.166083** / 0 | +2725 | +2596 | 40 min |

Neither image has been flashed. Rollbacks remain `f6a8c3ea119c` (148) and `6b4744ca73f8` (146).
