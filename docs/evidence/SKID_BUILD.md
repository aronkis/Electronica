> Evidence ledger, moved verbatim from `two_jup/skidfix/SKID_BUILD.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

> **OUTCOME SUMMARY (2026-08-15) — the skid fix class is DEAD.**
> 1. **v1** flashed → silicon deadlock, fsync 1252 / wcnt=0; reproduced in `tb/tb_dma_contract.v` (frozen tuser=0 beat blocks SYNC_TRANSFER_START).
> 2. **v2** (guard-preserving, sim-bit-exact) flashed → forward PER **+5.6 pp WORSE**, replicated (13.78/13.93% vs 8.22%); its witness was blind because in `-M` production mode the stream carries **neither** frame marker (tlast_en=0 gates TLAST; TUSER never fires).
> 3. **Backpressure exonerated**: 26 scheduled `byte_rx_ready` dips at the exact 8-frame cadence → bit-identical output. (Scope: run on the Jul-25 cadence-4 netlist, not the flashed generation — re-run there before closing the class formally.)
> 4. **v3** = transparent wire + marker-free gap witness, flashed and running on 148 (`6c06ecb7e888`, PER-identical to e49c011b). The witness is **not a working instrument**: onegap=0/s over 8744 samples, multigap 1743/s vs 1245/s structural.
> 5. Forward class remains OPEN at ~8.3%. See `../HANDOFF_20260815.md` and `docs/current-state.rst`. The body below is the dated archive.

# SKID_BUILD — skid-buffer fix image, BANKED (BUILD ONLY, not flashed)

2026-08-14, operator directive (A): build the skid-buffer fix image
(TICK_FIX_SIM.md §2 hardware form), reap-proof, HARD STOP before flash.

## Image bank

- BOOT.BIN: `/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_skid_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`
- md5: **c9d3e1ece983** (full: c9d3e1ece983…, size 7203552 — same size class as wit3/lean)
- lineage: fresh kit copy of `jupiter_byte_lean_build` (the exact tree that
  produced **e49c011b**, proven line-rate on 148), env recipe verbatim from
  HANDOFF_20260813.md:208: `QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4
  QPSK_FRAMESTAT=1`. DUT MATLAB/HDL stages untouched by the fix.
- build: PID 1680053 (detached, setsid/PPID=1), 12:18→13:35 EDT,
  log `skid_build.log`; driver `two_jup/skidfix/run_skid_build.sh`.

## The fix (platform-side only — DUT netlist recipe identical to e49c011b)

`qpsk_axis_skid` (two_jup/skidfix/qpsk_axis_skid.v, iverilog-clean) spliced
into the BD between `rx_byte_breakout/m_axis` (the ByteSerializer AXIS master;
its stock source documents the DUT's **drop-on-stall** decision at this port)
and `rx_byte_dma/s_axis` (the platform byte-FIFO/DMA write port):

1. **1-deep skid stage** ({tdata64, tlast, tuser} + valid): a downstream
   tready stall can no longer reach the DUT's drop decision; ordering
   preserved (s_tready low only while the skid holds a beat), ≤1-clk retry,
   word cadence ≥ ~512 clk ⇒ skid always drains. This is the sim-validated
   guard of TICK_FIX_SIM (m2: zero injected corruption, bitwise-clean).
2. **Beat-parity witness** latched once per frame at the TUSER packet-start:
   `[15:0]` last frame's accepted beats (expect 191=0x00BF), `[23:16]`
   mismatch count (sat), `[30:24]` skid-capture events = would-be swallowed
   beats (sat), `[31]` sticky alarm. Readout: **0x9D300008** (byte_ctrl_gpio
   flipped dual-channel, ch2 32-bit all-input; ch1/tlast_en at 0x9D300000
   unchanged). No DUT AXI change ⇒ no rail-rehosting exposure by construction.

Splice implemented by `patch_complete_tcl.py` on the fresh copy's
complete_byte_t8.tcl (marker-gated, idempotent). Known-benign BD warning:
gpio2_io_i member-pin connected by plain net (BD 41-1306).

## Gate matrix (attempt 3 — all green)

| gate | result |
|---|---|
| recipe markers | sps=4 ACTIVE, LEAN stripping banner, framestat overlay applied |
| SKID_WIRE_OK + VALIDATE_OK | PASS (splice validated in BD) |
| pre-impl timing gate | PASS — modem_dut WNS **+2.874 ns** @ real 8 ns clk (identical to lean's own +2.874; overall −1.119 also identical to lean) |
| impl + bitstream + bootgen | BYTE_BUILD_DONE |
| DCP rail census vs lean routed DCP | **PARITY_OK** — TC_CELLS 100=100; `enb_1_2_0` GLOBAL_CLOCK FO=60789 identical; `enb_1_2_0_gated` SIGNAL FO=515 identical; full dump diff = 8 lines, all small FO deltas (e.g. IPCORE_CLK 81766 vs 81843) from the added skid loads/placement — no re-hosting, no const-folding |
| axis_skid presence | generated in BD (`Generation completed for … axis_skid`) |

## Failed-attempt ledger (kept logs)

- attempt 1 `skid_build_attempt1_fat.log`: no env ⇒ fat canary stack ⇒
  TIMING_GATE_FAIL (WNS −8.143 on u_CanaryLfsr→u_CanaryFast, 61 logic levels).
  Not the splice. Gate stopped it pre-impl.
- attempt 2 `skid_build_attempt2_sps8.log`: QPSK_LEAN=1 only ⇒ sps=8, no
  framestat ⇒ built (0317705eca0a) but RAIL_GATE PARITY_MISMATCH (tc 148 vs
  100) — a *recipe* artifact, not synthesis re-hosting. Image discarded from
  flash consideration.

## Status & next (operator's call — NOTHING flashed)

Image c9d3e1ece983 is flash-eligible by every static gate. On flash (separate
authorization, standard rails: readback verify, full bring-up, health gate
fsync≥1100 && wordcnt≥1100, rollback to e49c011b on any fail):

- loopback + air runs read the witness at 0x9D300008: skid-capture counter
  `[30:24]` > 0 with beat-parity mismatches `[23:16]` = 0 ⇒ the write-port
  swallow exists and the skid is repairing it (the TICK_FIX_SIM mechanism
  confirmed on silicon); air-singles rate should drop toward the ~0.26%-class
  baseline if the modeled fault is the generator.
- witness all-zero with the air class persisting ⇒ the fault is not at this
  port (read-side/pointer variant) — the 0x1C4 fsv2-class witness question
  and the budget-enabled -S air echo test remain the discriminators.

## FLASH ATTEMPT 1 (2026-08-14 16:03–16:11 EDT) — rolled back; verdict INCONCLUSIVE (bring-up transient, not the image)

Operator authorized "Flash". Chain `flash_148_skid.sh` (log `skid_flash.log`):
readback PASS (c9d3e1ece983 booted) → bring-up PASS (ARM GATE try 1) →
NAK=4 PASS → reset-aware health gate **FAIL** (fsync=466 wcnt=0 vs ≥1100) →
automatic rollback to e49c011b + full restore, verified. Rails all held.

**The fail is confounded — measured negative controls:**

| state | bring-up passes | fsync | wcnt | clean |
|---|---|---|---|---|
| skid image c9d3e1ece983 | 1 | 466 | 0 | 11/12 |
| e49c011b post-rollback   | 1 | 420 | 369 | 11/12 |
| e49c011b, 2nd bring-up   | 2 (ARM GATE try 2) | **1254** | **1254** | 12/12 |
| 146 TMR (throughout)     | — | 1260 | 0 (no 0x1C0 on TMR) | 12/12 |

The PROVEN image showed the same degraded forward link after its first
post-reboot bring-up and recovered to full line rate on a second pass. The
skid image received only ONE bring-up pass before its gate ran. Its health
fail therefore does not implicate the skid splice; wcnt=0 under fsync=466
with ~total crc_drop is byte-plane starvation from the degraded link, not
separable evidence. The witness at 0x9D300008 was never reached (gate exits
before step 6).

**Rig state left healthy:** 146=433fd8dab393 fsync=1260, 148=e49c011b
fsync=wcnt=1254, daemons + watchdogs PID-verified, 12/12 clean intervals.

**Proposed retest (needs fresh operator authorization — the no-retry rail is
consumed):** re-flash c9d3e1ece983 with the gate amended to allow one
re-bring-up on first health fail (fail → restore_known_good.sh again →
re-probe → only then rollback), matching what e49c011b itself needed today.

## FLASH ATTEMPT 2 (2026-08-14 17:13–17:25 EDT) — UNCONFOUNDED FAIL of the skid image; rolled back; rig healthy

Fresh operator authorization; amended two-pass gate. Chain (log
`skid_flash.log`, attempt-1 log `skid_flash_attempt1.log`): readback PASS →
bring-up PASS (ARM GATE try 1) → NAK=4 PASS → gate pass 1 fsync=540 wcnt=0 →
amendment re-bring-up (ARM GATE try 1) → **gate pass 2: fsync=1252 wcnt=0,
0 resets, 12/12 clean** → rollback → e49c011b readback verified → restore.
Post-rollback control: e49c011b reads fsync=1259 **wcnt=1258** on the same
probe. The confound is gone:

- **Verdict: the skid splice as-built stalls byte delivery COMPLETELY on
  silicon** — modem at full line rate, zero byte words accepted at the DUT
  output over 12 s — while e49c011b under identical conditions delivers
  wcnt≈fsync. This is a real image defect, not a bring-up transient.

### Named defect analysis (to be proven in sim before any rebuild)

Root cause class: the DUT↔axi_dmac byte handshake is deliberately NOT plain
AXIS, and an AXIS-compliant register slice was inserted between two
non-compliant endpoints:

1. **SOF-prime guard defeat** (byte_rxfifo_overlay.m): the DUT presents
   `byte_valid` only after `byte_ready` has been continuously high >5 cycles,
   because the axi_dmac S2MM replicates a HELD first beat ×5 during its
   per-descriptor SOF prime. The skid masks true DMA readiness
   (`s_tready = ~skid_valid` is high whenever the skid is empty, regardless
   of the DMA), so the guard's precondition is evaluated against the wrong
   signal — and the skid itself holds `tvalid` across prime windows, the
   exact held-beat condition the guard exists to prevent.
2. **Deadlock path consistent with wcnt=0**: during a DMA descriptor-idle
   window the two skid stages fill, `tready` to the DUT then stays low until
   the DMA drains; with SYNC_TRANSFER_START (TUSER) semantics and prime
   replication interacting with the held output beat, the pair can mutually
   wait — byte plane frozen at zero accepted beats from the first frame on.

### Redesign spec (guard-preserving skid) + sim gate

- `byte_ready` to the DUT must be the TRUE `m_axis_tready` (combinational
  pass-through) so the SOF-prime guard keeps observing real DMA readiness.
- The skid register engages ONLY on the swallow hazard (a beat presented in
  the cycle ready falls), retrying it when ready returns — transparent
  otherwise; never holds tvalid into a prime window that the DUT-side guard
  hasn't already cleared.
- REQUIRED before any rebuild/flash: an RTL testbench modeling the axi_dmac
  s_axis contract (descriptor gaps, 5-beat SOF prime held-beat replication,
  SYNC_TRANSFER_START) that (a) reproduces today's total stall with the
  current skid as the positive control, and (b) shows the redesign delivering
  the byte stream bit-exactly with the guard semantics intact.
- Process lesson: on any future gate fail, read the 0x9D300008 witness BEFORE
  rolling back (today's fail path skipped step 6, losing the deadlock's
  direct signature).

**Rig state left healthy (verified):** 146=433fd8dab393 fsync=1260;
148=e49c011b fsync=1259 wcnt=1258, 0 resets, daemons + watchdogs up.

## DMA-CONTRACT TESTBENCH + SIM A/B (2026-08-14 evening) — v1 deadlock REPRODUCED, v2 guard-preserving skid VALIDATED

Operator-directed sim gate (pure sim, no rig). `tb/tb_dma_contract.v` models
the handshake contract, each element sourced: DUT presenter (drop-on-stall
supersede; TUSER/TLAST framing; SOF-prime guard = valid masked GUARD=8 cycles
after each ready rise, PRESENTED while ready low so the DMA can observe
tvalid&&tuser); axi_dmac sink (queued per-packet-TLAST descriptors;
SYNC_TRANSFER_START = ready low until tvalid&&tuser OBSERVED; 5-cycle SOF
prime inside ready-high recording any held-valid beat = the +32B replication
bug); the tick = mid-descriptor ready stall (4.5 word-gaps), pair schedule
(2 hits 8 frames apart / 32-frame super-period, LFSR p≈0.69). Cold start
mid-frame (widx=57). 400 frames per cell.

### A/B matrix (`skid_tb_ab.log`, TB_AB_DONE 19:07)

| cell | wcnt (0x1C0 analog) | drops | corrupt/slices | deadlock | witness |
|---|---|---|---|---|---|
| m0 direct, clean | 77029 | 134 (cold-start pre-sync only) | 0/403 | no | — |
| m0 direct, tick | 76981 | 182 (+48 = 3/hit × 16 hits) | **16/403 = 3.97%/frame ≈ 49/s scaled** | no | — |
| m1 naive v1, ±tick | **2 ≈ 0** | 77160 (everything) | 0 delivered at all | **YES** | 00000000 |
| m2 guarded v2, clean | 77029 | 134 | 0/403 | no | 000000BF |
| m2 guarded v2, tick | **77029** | **134 (zero tick drops)** | **0/403** | no | **400000BF** |

Bitwise: m2_clean == m0_clean IDENTICAL (77029/77029 words); **m2_tick ==
m0_clean IDENTICAL** — the fix delivers the exact clean stream under the
full fault schedule.

### Verdicts (the three required)

1. **Positive control, silicon deadlock: REPRODUCED.** The naive v1 skid
   accepts 2 beats then freezes a stale tuser=0 word at the DMA input;
   SYNC_TRANSFER_START never observes a frame start, ready never rises —
   wcnt=0, exactly flash attempt 2's fsync=1252/wcnt=0. v1 witness reads
   all-zero in this state (no completed frame crosses it), matching what the
   lost silicon witness read would have shown.
2. **Positive control, the tick class: REPRODUCED at the boundary.** With
   direct (e49c011b) wiring the pair-beat ready stall makes the DUT supersede
   exactly 3 words/hit → 16 corrupt frames/403 = **≈49/s scaled** (the ~57/s
   air-singles class), full-length-wrong-content at the host slice level,
   self-heal at next descriptor sync.
3. **Fix: the ~49/s class → ZERO, datapath bit-exact.** v2 repairs all 64
   would-be-swallowed beats (witness capcnt=0x40=64 = 16 hits × 4 beats,
   0 parity mismatches, 0 flushes, alarm clear) and the delivered stream is
   bitwise identical to clean.

### v2 design deltas over v1 (all forced by named failures)

- Transparent-when-empty INCLUDING tready (preserves guard/supersede/sync
  observation — kills the v1 deadlock; m1 cold-start passes in v2 cells).
- Capture window = engaged (recent m_fire) AND last accepted beat not TLAST
  (descriptor boundaries stay transparent; only mid-packet stalls repaired).
- Anti-prime RISE_MASK=8 on re-presentation (same discipline as the DUT).
- No-freeze invariant: STALE_WIN flush of any wedged FIFO (never fired).
- tready sourced from REGISTERED state only: the first v2 draft's
  combinational tvalid→tready capture term formed a zero-delta valid↔ready
  oscillation against the guard (caught by this TB as a sim hang,
  `skid_tb_ab_run1_oscbug.log`) — a defect that would have been
  timing-dependent flakiness on silicon.

### Status

v2 is sim-validated at the contract level. NOT built into an image, NOTHING
flashed (hard stop honored). Next on operator authorization: rebuild the
image with qpsk_axis_skid_v2 (same lean recipe + rail gates), then the
railed flash + witness chain — reading 0x9D300008 BEFORE any rollback.

## OVERNIGHT 2026-08-14→15 — silicon campaign ledger (authorized full autonomy)

### Shipped tonight
- **rx_drain_budget DEFAULT 4** (`bf2398a`): the causally-proven wedge fix was
  env-gated only and had never reached production bring-up — both first
  baseline attempts wedged on exactly the old class (146 delivery 0 f/s).
  With it shipped: **reverse 9.12% (banked 08-12 run) → 1.20–1.54%** across
  4 replicates tonight. This is the single largest PER win of the night.

### Reverse levers measured and REFUTED
- 146 RX tracking-cal freeze (all + 3-way bisect): no config beats baseline
  (all-off 1.51%, fic-off 1.33%, rfdc+bbdc-off 4.73% w/ two >100-frame
  bursts, agc+rssi-off 1.76%); 633-flagged counts flat (16–32) in every
  config → **the reverse tick family is NOT 146 RX tracking cals**. All cals
  restored (readback-verified). Its ~1.79 s super-period matches the
  loopback class-B beat on 148 → prime suspect is a 148-TX-side digital
  generator (characterization owed, not tonight-fixable).
- 0x184 CFO poke: INERT on 146's 433fd8da image — the write does not take
  (0x170–0x184 are the read-only T8.5 canary regs on this lineage, not the
  loop-gain block). The FLOAT_GAP_BUDGET poke needs a loop-gain image.
- TX power: 148 TX already at 0 dB atten (max). RX: AGC ch0 both boards.
- RXM: bring-up default is already 16 (the acceptance header's "-M 32" is
  stale).

### v2 skid ON SILICON: replicated regression, witness blind
- v2 image c85b06938fdd flashed under rails (gate passed on pass 2 —
  fsync=1255/wcnt=1183; the two-pass amendment is now standard).
- Forward on v2, queued mode: **13.78% / 13.93%** (two runs) vs 8.22% on
  e49c011b same night — v2's capture is net harmful, +5.6 pp.
- Witness root-cause of blindness, measured: after the capture's bring-up
  reset the witness stays EXACTLY 0 for the whole run (6689 samples, single
  transition) while 65k frames flow ⇒ **in -M production mode the stream
  carries NEITHER frame marker**: tlast_en=0 gates TLAST at the breakout
  and TUSER never fires on silicon. v2's TLAST-keyed boundary guard was
  inert and its TUSER-framed witness never latched.
- Cyclic-mode escape (RXCYC_A=1, runtime): engages correctly on the v2
  image but the AIR capture wedges in 12 s (cyclic reader validated only on
  loopback) — cyclic remains a gap, not a lever, tonight.

### v3 (building): transparent wire + marker-free GAP witness
Datapath = verbatim direct wiring (e49c011b-equivalent by construction; the
capture path is DELETED). Witness needs no markers: a DUT drop-on-stall
supersede appears at this boundary as an inter-beat gap ≈2× the word
cadence; v3 counts beats (rolling 16b), one-word gaps (1.5–2.5×, rolling
8b), multi-word gaps (>2.5×, rolling 7b), alive toggle bit 31; nominal gap
self-calibrates (EMA). Host samples 0x9D300008 fast and diffs. Smoke-tested
in sim (onegap/multigap classify correctly). Purpose: measure the forward
comb's drop mechanism ON SILICON with zero datapath risk.

### v3 ON SILICON (6c06ecb7e888, flashed 23:24) — production-equivalent, witness live
- Health gate PASS on pass 1 (fsync=wcnt=1258 — first first-pass pass of the
  night). Forward PER **8.39%** = e49c011b's 8.22% (v2's +5.6 pp harm gone).
  148 left running v3: proven datapath + live gap witness. Rollback to
  e49c011b remains banked on-board.
- Witness rates under air traffic: onegap=0/s; multigap=1743/s = 1245/s
  structural inter-frame gaps + ~500/s excess (frame-internal cadence
  structure; threshold semantics need the frame-structural gaps excluded
  before the excess is interpretable).

### BACKPRESSURE EXONERATED at the netlist level (dip replay, 00:00)
`sim_byte_dip.cpp` (obj_byte_dip_f1536_jul25): the lock replay with an
env-scheduled byte_rx_ready dip generator — the ONE input silicon replay had
never varied (`byte_rx_ready=1` hardwired). Healthy 202-frame IQ shard,
cadence-4 contract:
| leg | dips | result |
|---|---|---|
| base | 0 | 201 frames, 191 words each, clean |
| dip 8-frame cadence, ~3 word-times | 26 | **bit-identical to base** (0 short, 0 checksum diffs) |
| dip 8-frame cadence, ~1 word-time | 26 | bit-identical to base |
The DUT's own 64-deep ByteRxFifo absorbs short ready stalls exactly as
designed. **Conclusion: brief DMA-side backpressure cannot produce the
air-singles class in the RTL — the entire skid/backpressure fix class is
dead.** Triangulation (CP1 checksum-matched corruption inside the DUT +
replay-clean on corrupt-frame IQ + dip immunity) now points the forward
class at an IMPLEMENTATION-level effect in 148's silicon byte plane (the
same altitude as the wit-build rail-rehosting forensic) — the next
discriminators are implemented-netlist scrutiny of e49c011b's own byte-plane
CE/rail paths (dcp_rail_dump already covers the census; need the glitch-path
analysis) and/or an on-die ILA on the ByteSerializer→FIFO path.

## D0 (2026-08-15): backpressure exoneration RE-VERIFIED on the flashed netlist

The original dip result (§ "BACKPRESSURE EXONERATED") was run against the **Jul-25**
netlist, which is **not** the generation in the flashed image — and at cadence 4, that
generation's contract. Provenance was re-established first:

- The flashed image's DUT RTL is not on disk as a loose netlist; it is packaged inside
  `jupiter_byte_skid3_build/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip`
  as `hdl/TxRxCompo_ip_src_TxRxComposite.v`. Extracted and de-prefixed, it differs from
  `jupiter_240k5_byte/s1_rtl` by **8 lines** (file-name comment, timestamp, model version
  11.331 vs 11.330) whitespace-insensitively, with an **identical module-instantiation
  census** — vs 136 lines (fsv2_gates) and 1270 lines (Jul-25 worktree).
  ⇒ **`jupiter_240k5_byte/s1_rtl` is the flashed generation.**
- Independent structural confirmation: `wrap_byte_lock.v`'s deep probes
  (`Loop_Filter_stateI/P`, `Gardner_TED_e`, `Phase_Error_Detector_PhaseError`) **do not
  exist** in the flashed generation — the Symbol/Carrier Synchronizer subtree was
  restructured exactly as `SLX_RECONCILE.md` records. `wrap_byte_dip.v` ties those six
  probes off; the port list is unchanged so the driver is untouched.
- New `rtl_sim/build_replay_lock.sh` makes this family reproducible for the first time
  (previously no build script existed and every `build_*.sh` hardcoded `$KIT/s1_rtl`).

**Re-run (flashed netlist, cadence 2, same 202-frame shard, `dipab_flashed/`):**

| leg | dips | frames | short | full-length wrong-checksum |
|---|---|---|---|---|
| base | 0 | 200 | 0 | — |
| dip 8-frame cadence, ~3 word-times | 26 | 200 | 0 | **0** |
| dip 8-frame cadence, ~1 word-time | 26 | 200 | 0 | **0** |

Base decodes cleanly at cadence 2 (`packets=201`, `cfc_est=-105`), which also validates
the cadence contract for this generation. **Verdict: the exoneration STANDS, now on the
RTL that is actually running on 148 — brief DMA-side backpressure cannot produce the
air-singles class.** The result is no longer provisional; the skid/backpressure fix class
is closed on correct evidence.

## 2026-08-15 C1 session: a NEW 148-side wedge class, caught live

Attempting the C1 BIST discriminator surfaced something more useful than the
discriminator itself.

**Signature (observed directly, registers + host stats):**
- `0x104` advancing 1240/s, framesync 1251, **zero** carrier resets — the modem is
  decoding at full line rate.
- `0x1C0` byte-word counter **completely frozen** across repeated 3 s samples.
- Host: `dma_rx_ok=2`, `crc_drop=689116` — nothing delivered.

**Localization:** a `qpsk_tun` restart alone cleared it (`0x1C0` resumed advancing)
with no fabric reset and no reflash ⇒ **the fault is in the host/DMA arming path,
not the fabric byte plane.**

**It is NOT the class `rx_drain_budget=4` fixed** — the budget was confirmed active
in the daemon log (`RX drain budget: 4 slices/pump call`) while the wedge was in
progress. Shipping the budget default closed one wedge class, not the category.

**The watchdog is structurally blind to it:** `lock_watchdog.sh` keys on
`0x104`/framesync, both of which read perfectly healthy throughout. That is why this
state can persist silently through a measurement — and it is the likely explanation
for the single unexplained 148-side wedge at 01:37 in the overnight acceptance matrix
(`runlogs_20260815/final_matrix.log`).

**Actions:**
1. Add a byte-plane stall detector to `lock_watchdog.sh`: sample `0x1C0`, and if it
   fails to advance while `0x104` IS advancing, re-arm (restart the daemon). That
   asymmetry — decoder healthy, byte plane frozen — is the precise fingerprint.
2. Any acceptance run should assert `0x1C0` advance in its health gate, not just
   framesync. The current two-pass gate would have passed this wedge.

**Method note (self-inflicted instability):** the C1 restore path wrote `0x158=1`
directly to 146. `bringup_r2r3.sh` warns that flipping the byte source before the
daemon's TX stream is flowing starts the modulator mid-stream; repeated carrier
resets followed. Source-mux changes must go through bringup's sequencing, never an
ad-hoc register poke. The C1 BER number (5.27e-3) was taken during that degraded
window and on an uncontrolled instrument, and is therefore DISCARDED, not reported.
