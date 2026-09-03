# SLX_RECONCILE — the "dirty" commhdlQPSKTxRx*.slx, reconciled (2026-08-13)

## VERDICT: KEEP (option b). Do NOT revert.

The working-tree delta was the **intentional Track-H framestat as-built** of the
Aug-12 10:17 assemble run — and it has in fact **already been committed**
(b6bc60d, 2026-08-12 10:33, "Track H: f1536 instrument netlist built"). As of
this writing both `.slx` files in the working tree are **byte-identical to
HEAD** (blob a22066d4 / 7cfd1241 both sides); only the derived
`commhdlQPSKTxRxLoopback.slxc` cache remains modified. There is nothing left to
revert, and reverting b6bc60d's model content would discard the lineage of the
CP1 instrument image (md5 e49c011b) that is **currently flashed to 148 and
verified performing identically to pre-flash**. The 5/78 real-IQ replay failure
is a defect of the **sim/harness leg, not the model** (reconciliation below).

Confidence: **high (~90%)** on KEEP; **medium (~70%)** that the replay failure
is sim-side (the exact sim defect is narrowed but not yet pinned).

---

## 1. What exactly differs (HEAD-at-question-time cb53f71 → working tree = b6bc60d)

Method: both `.slx` zips extracted and XML-diffed (scratch dirs; no model
opened, nothing saved).

### commhdlQPSKTxRx.slx — NOTHING functional
The entire `blockdiagram.xml` diff is one line:
`ModelVersionFormat 11.321 → 11.327` (six load/save cycles). Zero block,
parameter, or connectivity changes. Half of the "dirty models" alarm was pure
save-counter churn.

### commhdlQPSKTxRxLoopback.slx — overlay-set swap, exactly the Track-H env
The delta is precisely what `assemble_jupiter_240k5_byte.m` produces with
`QPSK_LEAN=1 QPSK_FRAMESTAT=1` + `loop_gain_axi` (and **without**
`QPSK_LOOP_TUNE` / canary / shadow envs), versus cb53f71's as-built which was
the loop-tune + shadow-forensic instrument configuration:

**REMOVED** (present in cb53f71, gone in working tree):
- The T8.5/T8.7 shadow-forensic instrument set: `Loop Filter Shadow`,
  `ShadowScore`, `AdcForensic`, `AccVoter`, `TaOpsPack`, and their ports
  (`shdw_pdiv_cnt/pdiv_beat/idiv_beat/ip_latch/is_latch`, `strobe_forensic`,
  `beat_counter`, `ta_diag`, `ta_ops`, `stateWord` telemetry packing, p1b
  decision-tap outports).
- The **loop_tune** (`lt_*`-prefixed) LGMux/LGSw/LGProd/RegHold/RegDS plumbing
  (0x1F0–0x204 era) — note: the working tree REMOVES the QPSK_LOOP_TUNE-era
  blocks; the "loop_tune leftover" hypothesis is exactly backwards.

**ADDED** (working tree only):
- FrameStat CP1 instrument: `FrameStatChecksum/Fifo/Probe/WordCnt` subsystems,
  `framestat_head_lo/head_hi/stat/wordcnt` top ports, `framestat_pop` input
  (0x1C0/0x1D0 map). FIFO is drop-newest-on-full (no datapath backpressure).
- `loop_gain_axi` (un-prefixed) `LGMux_/LGProd_/LGSw_/RegHold_/RegDS_*`
  threading of the six runtime gains (`ss/cs prop/integ`, `agc_loop_gain`,
  `cfo_threshold`, 0x170–0x184) into Symbol Sync, Carrier Sync, and the AGC
  loop filter.
- The FsAgcRT rate-isolation fix family (`FsAgcZero`, `FsCfcSi`, `FsRunSi`,
  `adcFor` inport) — commit a3f1902's fix, baked in.

**UNCHANGED** (verified explicitly):
- Frame geometry: k5 (`1120-1` span constants, `24640` counts identical; the
  one lost "1120" is a block Position coordinate). No f1536 residue.
- Rate structure: the generated timing controller `TxRxComposite_tc.v` is
  **byte-identical** (same `enb_1_1_1 / enb_1_2_0 / enb_1_2_1` rails) between
  the Jul-25 netlist and the regen — sps and every clock-rate ratio unchanged.
- Sync datapath interface: `dataIn_re/im, validIn → dataOut_re/im, validOut`,
  one sample per enabled beat, in both.

Symbol Synchronizer subtree: 288 blocks / 20 subsystems → 222 / 16 (shadow
removal + lt_ rename). Carrier Synchronizer: same block count, lt_ rename only.

## 2. Which mechanism dirtied it, and when

The `.slx` files in this kit are **mutable as-built artifacts, not sources**.
`assemble_jupiter_240k5_byte.m` and its overlays call `save_system` **on the
original model in place** (`assemble…m:311`, `rate_240k_overlay.m:169`,
`variant_pre.m:283`, `agc_gain_range_overlay.m:91`, `ss8_fix_overlay.m:103`,
`timing_hardening_overlay.m:128`, `build_composite_local.m:133`, and
`hdlworkflow_loopback.m:16`, all with `OverwriteIfChangedOnDisk`). Every build
re-writes the model to reflect that run's env-var overlay set.

Timeline (file mtimes vs git):
- 10:17:45 / 10:18:17 Aug-12 — both `.slx` saved by the **Track-H
  f1536/framestat assemble** run.
- 10:27:34 — `s1_rtl` netlist regenerated from it (465-line
  `Symbol_Synchronizer.v`).
- 10:33:25 — operator committed the as-builts (b6bc60d), the same deliberate
  pattern as cb53f71 ("commit … the as-built model artifacts", Aug-7).

So the "dirty since Aug-12 morning" state seen overnight was the window between
the 10:17 save and later sessions observing `git status` against a stale
baseline; it was closed by b6bc60d, not left open.

## 3. Does the delta explain the HDL differences? Yes — all of them, benignly

- `Symbol_Synchronizer.v` **652** lines (Jul-25) = shadow/canary-instrumented
  build; **465** (fsv2/LEAN regen) = LEAN + loop_gain — and 465 lines is not
  new: an identical-size LEAN netlist exists from **Jul-23**
  (`.claude/worktrees/agent-a189bb…/…/Symbol_Synchronizer.v`); **578**
  (tmr146) = the lt_ loop-tune set re-added per the asrun_433fd8da manifest
  env. Line counts track overlay sets, not a corrupted core.
- `Carrier_Synchronizer.v` 707 vs 553: same story (shadow taps + lt_ vs plain
  LGMux threading).
- The "**2 lines/sym vs 1**": not a model rate change. The timing controllers
  are identical, the sync module's data interface is identical. The 2×
  observation came from `obj_byte_taps_f1536`'s ss/cfc/cs **tap dumps** — the
  tap harness reading through the re-threaded (LGMux) hierarchy, i.e. a
  harness-side artifact, consistent with the FLOAT_GAP_BUDGET wording ("the
  LGMux threading").

## 4. The replay failure vs the hardware — reconciliation

The contradiction is real and it resolves **against the sim leg**:

- The image flashed to 148 (md5 **e49c011b**, framestat CP1 + cyclic) was built
  from **exactly this b6bc60d model lineage** on Aug-12 (HANDOFF_20260812:
  "built+gated today, b6bc60d"), flashed ~20:30, and verified: wordcnt at
  exactly 1243.7 f/s, production host runs unchanged. A datapath that delivers
  5/78 packets (0 CRC-good) cannot run a production link at full rate —
  impossible, not merely unlikely.
- The "passing 77/78" reference is the **archived Jul-25 netlist**
  (`perframe_f1536` archive) — the generation the replay-harness family was
  developed against. The 12/12 singles-replay exoneration also used that
  archive, so it never exercised the new netlist.
- S1B BIST **passes** on the new netlists (self-consistent TX→RX), and the
  netlist's zero-default gain path is combinationally sound (verified in
  `LGMux_agc_loop_gain.v` / `Loop_Filter.v`: `axi==0 → nz=0 → LGSw` selects the
  original compiled-constant `Gain1` product; unconnected Verilator inputs tie
  to 0). Frame geometry and rails identical. Nothing in the model delta can
  produce a near-total (0 CRC-good) real-IQ failure that hardware doesn't show.

Most probable sim-defect locus (unpinned): the perframe replay harness's
drive/alignment assumptions or its interaction with the re-threaded netlist
(HDL Coder inserted new `stateControl`/`delayMatch` enable-gating around the
LGProd parallel path — benign in steady state, but it changes reset-window
behavior that a fixed `rstCS 400..8400` drive may straddle differently), or the
tap-instrument wrapper. Residual risk (~30%) that an in-loop delay-balancing
subtlety is real but masked by hardware conditions — bounded by the fact that
e49c011b works on the very capture class the replay chunk came from.

## 5. What would firm it up (in order of leverage)

1. **A/B first-divergence trace**: run the Jul-25 archive netlist and the fsv2
   regen on the same 8-frame IQ window with waveform dumps; diff at the RRC →
   AGC → symbol-sync → carrier-sync stage boundaries. First divergent stage
   names the defect (sim drive vs real logic) in one run.
2. Drive the new netlist with the six gain inputs forced to their compiled
   constants (instead of unconnected/0) — if 77/78 returns, the zero-default
   path is the bug; if not, zero-default is exonerated in one run.
3. Sweep `rstcs_end` / warm-up on the new netlist — if pass-rate moves, the
   harness reset-window assumption is the defect.
4. Once green: keep `replay_gate_n2.sh` in the gate suite (it caught a real
   coverage hole in S1B either way).

## 6. Process note

The recurring "dirty slx" alarms are structural: the models are build
artifacts that every assemble mutates in place. Options (pick one, separate
change): commit as-builts under variant names (the
`commhdlQPSKTxRxLoopback_asrun_433fd8da.slx` pattern), or add a
`.gitattributes`/status-ignore convention plus a manifest, or have assemble
work on a copy. Until then: a modified `.slx` after any build is expected, and
"diff the XML before trusting" (this doc's method) is the reconcile procedure.

## The one-paragraph mechanism story

The Aug-12 10:17 Track-H assemble (`QPSK_LEAN=1 QPSK_FRAMESTAT=1`) re-saved
`commhdlQPSKTxRxLoopback.slx` in place — as every assemble does — replacing the
previous as-built (loop-tune `lt_*` + shadow-forensic instruments, cb53f71)
with the framestat/CP1 + `loop_gain_axi` configuration, and touched
`commhdlQPSKTxRx.slx` save-counter only; the operator committed both at 10:33
(b6bc60d). Every observed netlist difference (652 → 465/578 lines, "2
lines/sym" taps) is the overlay-set change, not a broken core: geometry, sps
rails, and the sync data interface are byte-identical across generations. The
5/78 real-IQ replay failure cannot be the model's fault because the e49c011b
image built from this exact lineage runs the production link on 148 at full
rate — it is a sim-harness/interface mismatch against the re-threaded netlist,
to be pinned by an A/B first-divergence trace. KEEP; nothing to revert.
