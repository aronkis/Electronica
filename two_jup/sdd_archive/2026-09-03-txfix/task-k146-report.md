# Task K — 146 fix-flash preparation (TXFIX phase 2, item 4)

Agent: K (146 lane). NO board contact at any point: nothing in this task ssh'd to
10.0.0.146 or 10.0.0.148. hdl-dev-2 (build host) was used read-only for inspection
and to run the Vivado build. Commit: `d6ea0c2` (+ this report).

## 1. Vendh kit identification (evidence)

**The image 146 runs, `ec414d2df8bc`, has no RTL kit of its own.**

| fact | evidence |
|---|---|
| the flashed artefact | `two_jup/skidfix/flash_146_vendh.sh:26` — `BB=$ROOT/jupiter_byte_tmr146_gates/variants_placement/v_endh/BOOT.BIN` |
| that file IS ec414d2df8bc | `md5sum` = `ec414d2df8bce7da6eaf232bf9f0613c` (measured this session) |
| how it was made | `two_jup/SINGLES_CAMPAIGN.md:1290-1310` ("2026-08-25 — A4-CHANGED option (c) groundwork, WAVE 1: placement-only variants of 4be9286ca111"): opened `jupiter_byte_tmr146_build/.../vivado_prj.xpr`, verified `synth_1` COMPLETE + `NEEDS_REFRESH=0`, then `copy_run` from `impl_1` — "5 new impl runs differing ONLY in place_design directive. No codegen, no re-synth" |
| the directive | `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/v_endh/system_top.tcl:221` — `place_design -directive ExtraNetDelay_high` |
| variant table row | `two_jup/SINGLES_CAMPAIGN.md:1370` — `| 1 | v_endh | ExtraNetDelay_high | ec414d2df8bc | CLEAN | 0.102/0.010 | ... |` |
| the RTL kit behind it | `jupiter_byte_tmr146_build` — its own `hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` measures `4be9286ca111be4865c6f2c8fe849705`, i.e. the `tmrfresh` image; README `boot_known_good/README.md:15` states v_endh is "RTL-identical to tmrfresh by construction" |
| TMR guard is in that tree | `dont_touch = "true"` present ×6 in every copy of `TxRxCompo_ip_src_Magnitude_Squared_and_Moving_Sum.v` and in both `TxRxCompo_ip_v1_0.zip` members (measured) — the load-bearing T8.9 guard described in `jupiter_byte_tmr146_gates/tmr_attr_inject.sh` |
| the vendh flow has no build script of its own | there is no `build_vendh.*`; the placement variants were made interactively by `copy_run`. `jupiter_byte_tmr146_build` does carry `timing_gate.tcl` and `tmr_attr_inject.sh` at top level, and `timing_gate.tcl` is byte-identical to `jupiter_byte_ddrcap2_build/timing_gate.tcl` (`diff` clean) |

**Consequence, and the headline caveat of this task.** Injecting the F3 RTL patch
invalidates the `synth_1` checkpoint that v_endh was `copy_run` off. The vendh
*placement* therefore cannot be reproduced — only the *directive* carries forward.
What is being built is:

> **tmrfresh RTL (`4be9286ca111` lineage) + TXFIX F3, re-synthesized, placed with
> `ExtraNetDelay_high`** — not "vendh + F3".

The byte-plane margins that made v_endh rank 1 in the 2026-08-25 placement study
(BP_SETUP 1.847 / CE_SETUP 3.944, matching the good 433fd8da anchor) were measured on
that one placement of that one netlist and do **not** transfer to a fresh synthesis.
The `txfixF3vendh` bank name is retained for traceability to the lineage, but the
README row and any PER comparison must carry this qualifier.

## 2. Kit generalisation

`jupiter_byte_txfix_kit.sh` gained four env knobs; **every default reproduces the
previous ddrcap2 behaviour**:

| env | default | effect |
|---|---|---|
| `SRC_KIT` | `jupiter_byte_ddrcap2_build` | source kit dir |
| `KIT_NAME` | `jupiter_byte_txfix<VARIANT>_build` | output kit dir (validated against `build_txfix.sh`'s `jupiter_byte_txfix*_build` requirement) |
| `TCL_TMPL` | `two_jup/skidfix/txfix_build.tcl.tmpl` | build tcl installed into the kit |
| `TMR_ATTR` | `0` | `1` = run the source kit's `tmr_attr_inject.sh` after injection, require `TMR_ATTR_OK` |

Also: `--exclude 'vivado_prj.runs/v_*/'` added to the kit copy and to
`txfix_build.sh.tmpl`'s rsync (the tmr146 project carries nine multi-GB
placement-variant impl runs; ddrcap2 has no `vivado_prj.runs` at all, so this is a
no-op for F1/F2/F3). `TXFIX_VARIANT` gained a third line `SRC_KIT=<name>`; `head -1`
still yields the variant so `build_txfix.sh` is unaffected.

**Kit made** (`SRC_KIT=jupiter_byte_tmr146_build KIT_NAME=jupiter_byte_txfixF3vendh_build
TCL_TMPL=two_jup/skidfix/txfix_build_vendh.tcl.tmpl TMR_ATTR=1 ... F3`):

- ipcore layout **differs from the ddrcap2 kit**: the tmr146 composite holds the target
  `.v` files in **four** trees, not three — `hdlsrc/commhdlQPSKTxRxLoopback/`,
  `ipcore/TxRxCompo_ip_v1_0/hdl/`, `vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl/` **and**
  `vivado_ip_prj/vivado_prj.gen/sources_1/bd/system/ipshared/0383/hdl/` (the already-extracted
  copy Vivado actually synthesizes). The injector walks by basename, so it handled all four
  with no change: `TXFIX_INJECT variant=F3 loose=16 missing=[] zips=2 zips_verified=2`
  (16 = 4 files × 4 trees; its `nloose % len(want) == 0` assertion still holds).
- both zip members patched and verified: `TXFIX_KIT_VERIFY zips=2 zips_with_marker=2`,
  `loose_v_hits=8` (`TXFIX_F3` marker).
- `TMR_ATTR_OK annotated 6 file(s)/zip(s)` — the four loose copies were already annotated
  (idempotent skip) and both zips were re-patched/verified **after** the injector's zip
  rewrite, which is the point of the check.
- `TXFIX_KIT_DONE variant=F3 kit=jupiter_byte_txfixF3vendh_build src_kit=jupiter_byte_tmr146_build injector_commit=5731dccffe5d`

## 3. Build flow: `two_jup/skidfix/txfix_build_vendh.tcl.tmpl`

Derived from `txfix_build.tcl.tmpl`, keeping `timing_gate.tcl`, the
`TXFIX_ROUTED_TIMING_FAIL` routed-WNS gate, bootgen, `BYTE_BUILD_DONE md5=` and
`TXFIX_BUILD_DONE`. Three vendh-specific additions:

1. **`place_design -directive ExtraNetDelay_high` set unconditionally** — this is the
   whole of the vendh identity.
2. **`IMPL_STRATEGY=explore` is REFUSED, not merely unused.** Its first action is
   `set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt`, which would
   *overwrite* `ExtraNetDelay_high`; and the campaign's own wave-1 finding
   (`SINGLES_CAMPAIGN.md:1296-1300`) is that `ExtraTimingOpt` is placement-**bit-identical**
   to Default on this design when timing is already met. So it would buy nothing while
   discarding vendh. **No `IMPL_STRATEGY` was used for this build.** If routed WNS comes
   back negative the fallback is stronger PHYS_OPT/ROUTE directives, never a different
   place directive.
3. **The nine `v_*` impl runs are deleted before `reset_run synth_1`, and that reset is
   no longer swallowed by `catch`.** They are all parented on `synth_1` (verified by an
   open-only pre-check on hdl-dev-2 before the real launch: `PRECHECK delete_run v_expl
   parent=synth_1` … ×9, `PRECHECK leftover_v:` empty, `PRECHECK synth_1 status: Not started`,
   `PRECHECK_OK`). Without this, `txfix_build.tcl`'s `catch {reset_run synth_1}` could have
   silently swallowed a refusal and produced a build that passes the WNS gate on a **stale
   netlist**.
4. **`TXFIX_IPSHARED_VERIFY`** after `generate_target all`: `generate_target` re-extracts
   the packaged IP zip into `vivado_prj.gen/.../ipshared/<h>/hdl/` — i.e. *after* the
   kit-maker's verification has already passed — and per `tmr_attr_inject.sh`'s measured
   2026-08-06 lesson that extracted copy is what synthesis reads. The tcl greps it for the
   variant's markers and exits 1 on a miss. Live result: `TXFIX_IPSHARED_VERIFY_OK
   variant=F3 files_checked=4`.

## 4. Build

- Launched 14:16:13 via `two_jup/launch_rig_unit.sh txfix-kitbuild-F3vendh-141613
  <kit>/build_txfix.sh JOBS=6 IMPL_STRATEGY=`.
- Watcher: `bash two_jup/agents/watch_unit.sh --spawn txfix-kitbuild-F3vendh-141613
  two_jup/sdd_archive/2026-09-03-txfix/progress.md` → unit `watch-txfix-kitbuild-F3vendh-141613`.
- Preflight: hdl-dev-2 free **61 GB** (≥ 25 GB gate), no concurrent build units.
- **Remote build unit: `txfix-build-txfixF3vendh_build-1788459374` on hdl-dev-2.**
- **Remote log: `/home/tcollins/qpsk-builds/jupiter_byte_txfixF3vendh_build/build_txfix_vivado.log`**
- Remote tree: `/home/tcollins/qpsk-builds/jupiter_byte_txfixF3vendh_build`
- JOBS=6, IMPL_STRATEGY unset.

RESULT: see §7.

## 5. 146 flash chain

`two_jup/skidfix/flash_146_txfix.sh` (+ 2-line wrapper `txfix_flash146_go.sh`),
derived from `flash_146_vendh.sh`. Full diff banked at
`two_jup/sdd_archive/2026-09-03-txfix/flash146-vendh-to-txfix.diff`.

### Rails carried VERBATIM
`A=10.0.0.146` / `RX=10.0.0.148`; the 2026-08-26 RAILS AMENDMENT pre-flash liveness
check of 148 **before 146 is touched**; on-board backup created and verified before
staging; staged-copy md5 verify with `/boot/BOOT.BIN` untouched on failure; reboot +
readback verify with rollback on mismatch; FULL bring-up via `restore_known_good.sh`
and the `nakstat == 4` re-check on 148; the reset-aware **two-pass** health gate
measured **on 148** (`fsync>=1100 AND wcnt>=1100 AND clean>=4 AND raw_0x1C0_delta>0`)
with exactly ONE re-bring-up between passes; rollback on gate failure; **no retry**;
step `[6/6]` intentionally empty (no witness gpio on the TMR lineage).

### Changed lines
1. **Interface.** `EXP=${1:?...}` → `EXP=${FLASH_MD5:?...}`; added `BAK=${FLASH_BAK:-ec414d2df8bc}`,
   `TAG=${FLASH_TAG:?...}`, `ROLLBACK_BANK=${ROLLBACK_BANK:-.../variants_placement/v_endh/BOOT.BIN}`,
   `DRY=${DRY:-0}`, and 12-lowercase-hex regex validation of `FLASH_MD5`/`FLASH_BAK`
   (matches `flash_148_txfix.sh`). Removed `BAK_MD5=4be9286ca111`.
2. **Image source.** `BB=$ROOT/jupiter_byte_tmr146_gates/variants_placement/v_endh/BOOT.BIN`
   → `BB=$ROOT/boot_known_good/BOOT.BIN.146.$TAG.$EXP`.
3. **A0 bank gate FIXED (defect in the original).** The vendh script's `[1/6]` checked only
   that `jupiter_byte_tmr146_build/.../boot/BOOT.BIN` **exists** — and that file measures
   `4be9286ca111`, i.e. it is **not** the rollback image for a chain whose restore point is
   `ec414d2df8bc`. Now `$ROLLBACK_BANK` must exist **and** `md5sum | cut -c1-12` must equal
   `$BAK`, printed and asserted, before anything is touched.
4. **On-board `.bak` creation is now verify-first.** 146 has `.bak` files for `433fd8da`
   and `4be9286c` but **none for `ec414d2df8bc`**. `[2/6]` runs, in one remote command:
   Placement note: the brief called this a "precondition stage" step; it lives in `[2/6]`
   rather than `[1/6]` because that is where the vendh chain does its own backup and the
   instruction was to keep the 146 rails verbatim. It is still strictly **before any
   staging** -- the `scpput` is the next statement -- so the ordering guarantee is
   unchanged. Also: the remote output is now `tee`'d to stderr before the `grep -q BAK_OK`,
   so a `LIVE_MD5_BAD` abort ("146 is not running $BAK") explains itself in the log instead
   of surfacing as a generic FATAL.
   `md5sum /boot/BOOT.BIN | grep -q ^${BAK}` (abort `LIVE_MD5_BAD` otherwise) → `cp` to
   `/root/BOOT.BIN.${BAK}.bak` → re-verify the copy → `echo BAK_OK`. Any failure aborts
   with `/boot` untouched. `rollback()` restores from the same parameterised path.
5. **DRY=1 added** (the vendh chain had none), modelled on `flash_148_txfix.sh`: new `brd()`
   wrapper for every `$W $A` call, guarded `scpput`/`wait_back`, and — the ones easy to miss
   — guarded `bringup()` (`restore_known_good.sh`), `health_rx()`
   (`health_probe_reset_aware.sh`) and `read1c0()` (the `0x1C0 direct_reg_access` reads on
   148). Those three open their **own** ssh sessions, so a `$W`-only guard would still touch
   both boards. Identity comparisons (`CUR`/`BOOT`/`NAK`) are skipped under DRY.
6. **Marker rename** `FLASH_146V_*` → `FLASH_146T_*` throughout (so the two 146 chains are
   distinguishable in logs); `FLASH_146T_DONE` on success.
7. **Bring-up logging.** `bash "$D/restore_known_good.sh" 2>&1 | tail -15` in `rollback()`
   became `bringup /tmp/flash146_rollback_bringup.log; tail -15 ...` so the DRY guard has a
   single choke point.

### Gate: it NEEDS THE PEER — operator note
The 146 chain's gate is **not** a mode-1 arm of 146. It is `restore_known_good.sh` (a FULL
**both-board** bring-up) followed by health numbers read **on 148** — 146's TX health is
only observable at 148's RX, which is the entire point of the flash. Consequences the
operator must plan for:
- 148 will be **re-armed as a side effect** of this chain; 148's verified mode-1
  configuration must be restored afterwards (`baseline_arm148.sh`).
- The sentinel must stay **stopped** for the whole window (its r3 recovery re-arms both
  boards).
- 148 being "idle" is fine and expected; 148 being *down* is not — `[1/6]` aborts before
  touching 146 if the 148 instrument is unreachable (that rail exists because attempt 1 of
  the vendh flash was voided exactly that way on 2026-08-26).

### DRY proof
Manual run with the tests' ssh/scp PATH shim: all stages `[1/6]`..`[6/6]`,
`HEALTH_GATE_PASS fsync=1259 wcnt=1259 raw_0x1C0_delta=1 (pass 1)`, `FLASH_146T_DONE`,
**shim log empty** = zero network calls.

### Tests
7 new tests in `two_jup/tests/test_txfix_rig_scripts.py`, all DRY=1 + shim:
`test_flash146_dry_all_stages_and_ok`, `test_flash146_requires_flash_md5_and_flash_tag`,
`test_flash146_default_bak_is_ec414d2df8bc`, `test_flash146_a0_gate_rejects_wrong_rollback_bank`
(asserts it aborts *before* `[2/6]`), `test_flash146_creates_the_missing_bak_after_verifying_the_live_image`
(asserts verify → copy → re-verify ordering), `test_flash146_no_unguarded_helper_invocations`
(each of the three ssh-opening helpers appears exactly once, inside a DRY-checking wrapper,
above the first stage marker), `test_flash146_rails_carried_from_vendh_chain`.
**15/15 pass** in that file.

## 6. Fetch/bank generalisation

`jupiter_byte_txfix_fetch.sh` gained `BOARD` (default `148`, validated 146|148) and
`TXFIX_TAG` (default `txfix<VARIANT>`; needed because `F3` alone would collide with the
148 ddrcap2-lineage image of the same letter). Bank name is now
`BOOT.BIN.$BOARD.$TAG.$MD5_12`. For `BOARD=146` the README row is **inserted after the
last `BOOT.BIN.146.*` row** (the 146 table is at the top of README.md) rather than
appended after the 148 material; `BOARD=148` keeps the previous append-at-end behaviour
byte for byte. The row description now reads the `SRC_KIT=` line of `TXFIX_VARIANT` when
present, falling back to the historical ddrcap2 wording for older kits.

## 7. Build result and bank

**Build: PASSED the routed-WNS gate on the first attempt, no IMPL_STRATEGY.**

| item | value |
|---|---|
| remote unit | `txfix-build-txfixF3vendh_build-1788459374` (hdl-dev-2) |
| remote log | `/home/tcollins/qpsk-builds/jupiter_byte_txfixF3vendh_build/build_txfix_vivado.log` |
| local launch unit / watcher | `txfix-kitbuild-F3vendh-141613` / `watch-txfix-kitbuild-F3vendh-141613` |
| synth | 14:16 -> 14:35 (~19 min), JOBS=6 |
| impl + bitstream | 14:35 -> 14:54:28 (~19 min) |
| pre-impl timing gate | `TIMING_GATE_PASS modem_dut WNS=2.874ns` (post-synth, real 8.000 ns adc clock) |
| **routed timing (authoritative)** | `TXFIX_ROUTED_WNS wns=0.192528 tns=0.000000` -> **+0.193 ns, TNS 0**, gate PASS |
| place directive | `ExtraNetDelay_high` (`TXFIX_VENDH_PLACE_DIRECTIVE`, echoed back from the run property) |
| IMPL_STRATEGY | **none** (see §3.2 — `explore` is refused by this tcl) |
| ipshared re-verify | `TXFIX_IPSHARED_VERIFY_OK variant=F3 files_checked=4` |
| placement-variant runs | all nine `v_*` deleted, `PRECHECK leftover_v:` empty, `reset_run synth_1` succeeded unswallowed |
| bitstream | `BYTE_BUILD_DONE md5=6b4744ca73f8a6e959f8dcd17eb93353` |
| final marker | `TXFIX_BUILD_DONE variant=F3 md5=6b4744ca73f8a6e959f8dcd17eb93353 wns=2.874 place_directive=ExtraNetDelay_high` |

Margin comparison (all the same 8.000 ns constraint):

| image | post-synth modem WNS | routed WNS | how |
|---|---|---|---|
| 148 ddrcap2-lineage F3 (`f6a8c3ea119c`) | 1.544 ns | +0.095 ns | needed `IMPL_STRATEGY=explore`, closed on attempt 3 |
| 148 ddrcap2-lineage F2 (`5e3f58955f02`) | — | +0.056 ns | `explore` |
| unmodified tmr146 @ `ExtraNetDelay_high` (`ec414d2df8bc`) | — | +0.102 ns | 2026-08-25 `copy_run` |
| **this build (`6b4744ca73f8`)** | **2.874 ns** | **+0.193 ns** | first attempt, no `IMPL_STRATEGY` |

The 146 lineage closed timing with roughly twice the routed margin of the 148 F3 build and
without needing a stronger strategy — consistent with it being a leaner tree (no DDRCAP-v2
instrument). The post-synth figure is not comparable across lineages (different netlists);
the routed number is the one the gate acts on.

**Banked** by the coordinator as `boot_known_good/BOOT.BIN.146.txfixF3vendh.6b4744ca73f8`
(commit `dbe13f4`); `md5sum -c` on the new MD5SUMS row re-run here: **OK**
(`6b4744ca73f8a6e959f8dcd17eb93353`, 7,203,552 B — the same size as every other 146 image).

**README 146 row** now carries the §1 provenance qualifier explicitly: tmrfresh RTL
`4be9286ca111` + F3, re-synthesized, placed `ExtraNetDelay_high`, **not** built on vendh's
checkpoint, with the "PER comparison confounds fix with placement" warning attached.

The 146 flash was launched separately by the coordinator using this chain
(unit `txfix-flash-146-145545`, readback matched, bring-up gate in progress at the time of
writing). Its outcome is recorded in the campaign ledger, not here — this task made no board
contact at any point.

## 8. Concerns

1. **Provenance (the big one).** See §1: this is *not* "vendh + F3". The vendh placement
   is unreproducible once the RTL changes; only the directive survives. Any PER comparison
   of the new 146 image against the `ec414d2df8bc` baseline confounds the F3 fix with a
   fresh placement, and the placement axis is known to move 146's forward PER by
   >2 pp (the 2026-08-26 v_endh verdict: "MOVED, both legs >2pp, OPPOSITE directions").
   A clean attribution would need a no-fix rebuild of the same tree at the same directive
   as a control — one extra ~45 min Vivado run, not done here.
2. **The 146 gate re-arms 148.** §5. Schedule accordingly; sentinel stays stopped.
3. **The F3 sim gate matrix was scored on the ddrcap2 lineage netlist**, not this one. The
   RTL patch text is byte-identical (same `txfix_inject.py`, commit `5731dccffe5d`), and
   the four target modules are generated Simulink HDL that both lineages share, but the
   sim gate has not been re-run against the tmr146 tree.
4. **G6 caveat inherited.** The F3 flash-eligibility ruling carried an open G6
   (latchforce) scoring-criterion question; it applies here unchanged.
5. **`jupiter_byte_tmr146_build`'s local project still declares the nine `v_*` runs**, whose
   directories are excluded from the kit copy. The build tcl deletes the declarations in the
   *kit's* copy only; the original tree is untouched, so the 2026-08-25 audit trail survives.
6. **No control for the byte-DMA TX path on 146.** The 13:36 finding on 148 (91 % whole-frame
   swallow is a property of the gate/arm, not of F3) was measured on the ddrcap2 lineage;
   nothing equivalent exists for 146.
