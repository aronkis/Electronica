# Task 6/7 report — flash 148 with the SEQ-BIST image, stage 1 (fabric loopback), stage 2 (OTA self-reception)

Driver: Task 6 rig driver. Ledger: `two_jup/sdd_archive/2026-09-03-seqbist/progress.md`.
Every board action ran as a `launch_rig_unit.sh` unit with a `watch_unit.sh --spawn` watcher.
Every number is **[silicon]** unless marked **[sim]** or **[inferred]**.

## 1. Flash — SUCCESS, no rollback

| stage | result |
|---|---|
| pre-flash arm probe (`t6-prearm-148`) | **ARM_OK fps=1248 capTAP=0xBCF94856 golden**, first attempt |
| `[2/5]` flash | `FLASHED a1ff3c876d91` 00:06:22 |
| `[3/5]` readback | verified, **no rollback** |
| `[4/5]` two-pass gate | `GATE_PASS x2` |
| `[5/5]` sel-6 witness | decoded: 524,288 records, 42 demod/tx marks, toff min=max=mode=12314 |
| exit | `FLASH_DDRCAP2_OK a1ff3c876d91`, SENTINEL_STOP untouched, rc=0 |

148 now runs `a1ff3c876d91f1a0330254cf10902748` (WNS +0.112). Task-8a §9.1 warned the arm
had collapsed to 764–830 f/s; it had **not** persisted, and the one allowed pre-flash
re-arm was not spent.

Two notes for the next flash driver:
* The chain never echoes the gate's own fps (it pipes it into `tee | grep`), so only
  `GATE_PASS x2` is recoverable. The two passing fps values are not in the log.
* `[5/5]`'s DDRCAP sel-6 witness **does** decode on the seqbist lineage — I had flagged it
  as possibly uninterpretable. It is post-gate and non-fatal either way.

## 2. Post-flash — and the defect that would have voided every stage-1 leg

`POSTFLASH_OK`: image verified, mux select returns distinct per-slot values (not a stuck
bus), new slots 16–31 zero at rest, `0x9D410000` wrote/read back `0x00 → 0x20 → 0x30`.

**`tgen_mode` (0x9D410000 bit 5) was set by nothing in the toolchain.**
`rx_seq_checker.v:121` accepts the CRC field only when it equals `0x54474E21` — the constant
`qpsk_traffic_gen` writes into every frame — *if* tgen_mode = 1. The reset state, i.e. the
state right after a flash, is 0, so the checker would CRC32-check those frames and count
**every TGEN frame as `crc_fail`**; the stage-1 prereg `crc_fail = 0` could never have been
met. `seqbist_run.sh` and `seqbist_read.py` both carefully *preserve* bit 5 in their RMWs;
neither *sets* it. `postflash_check.sh` now sets it once, verified, before any leg.
Confirmed working: `crc_fail = 0` on every subsequent leg.

## 3. Stage 1 — fabric loopback

### 3.1 The RX-seam sink (coordinator ruling; the enabling fact for the whole stage)
`rx_seq_checker` counts `valid && ready` at the DUT RX byte pins. With no daemon and no DMA
armed the seam's `ready` is LOW, the ByteRxFifo never drains, and **every** checker counter
reads 0 while 0x104 runs at line rate. Measured as leg `ctrlA` att.1: 0x104 **+179,274** over
144 s (1245 f/s) while `chk_frames`, legacy `frames` and `acc_beats` all stayed **exactly 0**.
`loopchk_run.sh:45` already said it. RTL confirms: `qpsk_traffic_gen_rx2.v:114`
`assign dut_ready = en_d ? 1'b1 : dma_ready;` — enabling the injector holds `dut_ready` HIGH
and consumes+discards the DUT stream, switching only at frame boundaries (`:134`).
`SINK=tgenrx` implements it; witness in every meta: `acc_beats` delta 0 and `0x1B0`
byte_fifo_ovf constant.

### 3.2 The operating point is slot-quantised
The TGEN rate can only be an air-slot divisor, so "N % under saturation" does not exist and
my ≥4 % acceptance was unsatisfiable by construction.

| gap | emit/s | air/s | filler | loss% of emitted | gap1 | gap2 | g3+ | family |
|---|---|---|---|---|---|---|---|---|
| 0 | 1870.1 | 1245.5 | — | 33.29 | 0 | 109785 | 359 | gap2 (3.00× over-supply) |
| 18629 | 1245.2 | 1245.2 | 0.00 % | 0.0289 | 0 | 32 | 8 | gap2 |
| 20471 | 1245.4 | 1245.4 | 0.00 % | 0.0289 | 0 | 32 | 8 | gap2 |
| 31894 | 1245.7 | 1245.7 | 0.00 % | 0.0296 | 0 | 33 | 8 | gap2 |
| 45000 | 1245.8 | 1245.8 | 0.00 % | 0.0291 | **0** | 17 | 3 | gap2 (saturated control) |
| 60000 | 622.7 | 1245.3 | 50.00 % | 0.0582 | **17** | 3 | 0 | **gap1 (operating point)** |
| 73384 | 622.9 | 1245.7 | 50.00 % | 0.0582 | **17** | 3 | 0 | gap1 |

GAP 60000 and 73384 land on the identical point 40 min apart — the gap1 rate is reproducible.
**`gap1 = 0` at every-slot and `gap1 = 17` at every-other-slot**, same generator, sink and TX
path: the candidate-loss family appears only when filler is interleaved with data.

### 3.3 Legs at the operating point (GAP=60000)
* **clean 600 s**: emitted 377,161, `lost_slots` 217 = **0.058 %**, gap1 143 / gap2 37,
  `crc_fail` **0**, `int_last` carries **no 32/33** (int_other 175, lt30 4) → **no 26 ms comb**.
* **ctrlB** (CORRUPT_EVERY=1000): 175 − 54 background = 121 vs expected 116 (tol 32),
  `int_last` = 1000 → **PASS** on the seq axis.
* **ctrlA-m** (SKIP_EVERY=1000, GAP=73384): emitted 110,208, expected 110.2, observed 164,
  background 64.1, corrected 99.9, tol 31.5 → **PASS**; gap1 151 of 164; 9/17 `int_last` at 1001±2.
* **TX pins clean on every leg**: `d_tx_bit_errors = 0`, `tx_frames_checked` advancing
  (+160,878 / +161,207 / +161,124 / +379,212) → frames leave the TX byte plane intact; any
  loss is **downstream** (modulator / demod / deframer).

**Stage-1 verdict:** the fabric's own loss floor in loopback is **0.058 %** (gap1 family,
filler-adjacent), with **no 26 ms structure**. The on-air 8 % is **not** a fabric-loopback
property.

## 4. Stage 2 — OTA self-reception: UNINFORMATIVE (and why that is a result)

146 keyed off (`out_voltage0_ensm_mode=calibrated`) under a restore trap on every attempt;
`146_RESTORE_VERIFIED=1` every time, including both aborted paths.

Three-stage gate (splitting a0/a1 from b is what makes this readable):

| leg | a0 (0x114=0, ROM, no radio) | a1 (0x114=1, ROM, on air) | b (TGEN, on air) |
|---|---|---|---|
| GAP=60000 | 1246 PASS | 1246 PASS | **FAIL** 0x124 390.8, chk 328.8, dev 15.9 % |
| GAP=45000 | 1247 PASS | 1247 PASS | **FAIL** 0x124 493.4, chk 368.0, dev 25.4 % |

ROM self-couples perfectly; the TGEN byte-plane stream does not — while the *same* stream
decodes at full rate in digital loopback (dev 0.011 %).

### 4.1 CFO / entropy probes (gate-only, 30 s each, no 600 s leg spent)
```
probe              lo_rx        fill    0x124f/s   chk f/s    dev%
P1_cfo0            2000000000   1516      617.1     426.6   30.868
P2_p5k             2000005000   1516      621.8     430.1   30.836
P3_p20k            2000020000   1516      462.1     352.3   23.767
P4_m20k            1999980000   1516      541.3     393.9   27.230
P5_p20k_fill100    2000020000    100      208.9     186.5   10.739
P6_p20k_ctrl       2000020000   1516      618.1     426.9   30.934
                                 (ROM self-couples at 1246)
```
* **Entropy hypothesis falsified in the opposite direction**: low-entropy FILL=100 is the
  **worst** point (209 f/s), consistent with long runs of zeros = constant symbols starving
  the symbol-timing loop — not with payload-induced false preamble detections.
* **P3 vs P6 are the same setting and differ by ~150 f/s.** That is the run-to-run
  instability, so no pair separated by less than that can be ranked — including P1/P2/P6.
  **CFO shows no effect across 0 / +5 k / +20 k.** Without this within-sweep control I would
  have read P1-vs-P3 as a 155 f/s CFO effect and been wrong.
* The `d_rstcs` column in this sweep is **void** (see §5).

### 4.2 TX attenuation probes
```
probe            txatten  fill   a0(int)  a1(rom)  0x124f/s   chk f/s    dev%  rstcs_gate
P7_atten20       -20      1516      1246     1247     626.0       0.0*  100.0*          1
P8_atten40       -40      1516      1247       31        NA        NA      NA         NA
P9_rom_atten20   -20      TGEN      1247     1246     575.0     408.0   29.04           0
```
* **Attenuation does not recover frame sync**: −20 dB gives 626 / 575 f/s against 0 dB's 617.
* **P8 −40 dB**: self-coupling too weak (a1 = 31 f/s) — the probe, not the hypothesis, failed.
* **P9 confirms attenuation does not break ROM** (a0/a1 1247/1246) and, because it ran a
  TGEN gate at −20 dB, supplies the valid chk number P7 lost: 408 f/s, dev 29.0 %, matching
  the 0 dB pattern (426.6, 30.9 %).
* **In-gate rstcs = 0 and 1** — with the corrected method there are **no reset storms**.
* `*` P7's `chk = 0.0` is an **instrument fault**, not a measurement: 0x124 ran at 626 f/s
  while the checker saw nothing, i.e. the seam was not draining for that probe. P9 at the
  same attenuation gives chk = 408, so the fault is transient and **not root-caused**. P7's
  0x124 stands; P7's chk does not.

**Stage-2 verdict: UNINFORMATIVE.** In self-reception every byte-plane stream is received at
roughly half the frame rate regardless of CFO, payload entropy or TX power, while the ROM
path — which uses `Input_Data` and bypasses the byte plane entirely — is received fully.
The plan's prediction (comb present ⇒ 148's own chain; flat ⇒ needs 146) **cannot be
evaluated**, because the bring-up gate never passed. The discriminating fact is recorded:
**half-rate detection with stable sync** (no reset storms) suggests every other frame's
preamble is swallowed — consistent with the sim's framing slip, but self-reception is not the
mission geometry, so stage 3 is the decisive test.

## 5. Corrections to my own claims (each caught by data, not review)

1. **`0x158`/`0x114`/`0x118` are WRITE-ONLY** (`BIST_SEQ_SURVEY.md:29`;
   `TxRxCompo_ip_addr_decoder.v:602-604` returns const_0). I refused a leg on "arm did not
   stick (0x158=0)". Unit `t6-probe158` read 0x158 = 0x0 immediately after writing 0x1, after
   1 s, after a 0x110 pulse, after a full arm, and after writing 0x0 — five reads, one value,
   while 0x104 ran at 1247–1248 f/s. My probe's "control" register 0x10C is **also**
   write-only and also read 0; the only real evidence the read path works is 0x104 counting.
   Read-back verification replaced by `verify_arm_by_effect`.
2. **`ctrlA` att.1's null had ONE cause, not two.** I claimed the missing sink *and* a failed
   arm; the latter was the write-only artefact above.
3. **`rstcs` deltas straddling an arm are meaningless** — 0x150 is reset by the arm's `0x000`
   pulse, and P2 returned `d_rstcs = −9034`, a negative count. My "233 resets/s" for P1 was
   an artefact. Corrected method (both reads after the last arm) shows **0–1 resets** in-gate.
4. **The gap sweep collapsed**: GAPs 31894/20471/18629 all sat at the ceiling (emitted == 0x104,
   filler 0.00 %), so it measured one point three times. My `F` model predicted 1200 f/s at
   GAP=20471 and delivered 1245. I then compared the 0.029 % and 0.058 % figures as a
   silence trend — invalid, because `gap1 = 0` at saturation means those are different
   mechanisms (over-supply vs candidate fabric loss).
5. **Filler alone did not explain the stage-2 abort** — a filler-free GAP=45000 stream failed
   the same way.
6. **`legrun_go.sh`'s `deliver_rate ≥ 1000 f/s` gate is now systematically unmeetable**: the
   whitening leg measured 952 f/s pre and post, and task-8a §9.1 records 949–955 f/s on every
   armed leg since 22:17. The threshold predates that degradation; it will fail every daemon
   leg on merit-neutral grounds until re-baselined.

## 6. Defects found and fixed (tooling)

* **stage-2 path never armed the sink** — `stage2_self_go.sh` and `arm148_rf_self.sh` both
  omitted it. The bring-up gate would have reported FAIL on a good radio link, or the 600 s
  leg would have returned an all-zero `int_last` reading exactly like "flat, no comb" — one
  of the two verdicts stage 2 exists to distinguish. Caught before the leg ran.
* **scorer false positives**: `chk_int_last` (a re-latching point sample, `−950`),
  `starve_clk` (free-running, wraps, `−3812923438`), `max_len` (a MAX latch reading
  0xFFFFFFFF) and `ep_gt*` were all in the mid-window-clear detector, making **every** real
  leg UNINFORMATIVE. Collected in `NON_CUMULATIVE`.
* **control scoring** rewritten per ruling: emitted denominator, background-corrected,
  tolerance `max(2, 3·√expected)`, positive interval evidence required, `garbage − filler`
  demoted to report-only (filler is exact only at zero loss).
* **whitening could not survive a watchdog relaunch** — `bringup_r2r3.sh:209` omits
  `QPSK_WHITEN` from the relaunch string; added a `WHITEN_DENV` hook. Relaunches were 0/0, so
  it never bit, but it would have silently reverted the treatment mid-leg.
* **`probe_pwr_go.sh`'s TX-gain restore trap silently failed** — it read
  `out_voltage0_hardwaregain` as `"0.000000 dB"` and wrote that string *back*, which sysfs
  rejects, so the trap logged `148_TXGAIN_RESTORE_VERIFIED=0 *** left at -20.000000 dB ***`.
  The read-back check is what caught it — a trap that wrote and did not verify would have
  handed over a board still 20 dB down. `final_restore.sh` writes a bare `0` and verified
  `txgain=0.000000 dB`. **Lesson: never write a sysfs value back in the form it was read;
  strip the unit.** The same pattern would bite any attribute with a unit suffix.
* **DRY runs write into the same `two_jup/comb/runs/` tree as real legs** and appeared in a
  results table with fabricated values. `knee_report.py` now refuses `dry=1` dirs; three stray
  DRY dirs removed. The durable fix (separate DRY output tree) is **not** done — recommended.
* **`NEEDS_ARM` diagnosis + `armed_legs_go.sh`**: `MODE=loopback` writes only the
  `loopchk_run.sh:31-33` triple, which is not a full arm; every working leg had *inherited*
  the armed state from the flash gate, and `capture_r3.sh`'s quiesce zeroes 0x9D000000 /
  0x9D000114. A full `arm148_mode1.sh` (ARM_OK required) now precedes any post-quiesce leg.

**Process failures of mine:** I edited `seqbist_run.sh` while a unit was executing it, killing
`ctrlA` att.1 (the coordinator's frozen-snapshot launcher closes the hole); I let heartbeats
lapse 01:02→02:16 while parked on monitors; and I used `pkill -f` with a pattern matching my
own shell, killing my own command chain — the same self-match trap the codebase documents for
`lock_watchdog`.

## 7. Rig state at the end [silicon] — unit `t6-final-restore`

```
148: txgain=0.000000 dB  rxgain=34.000000 dB  tgen=0x00000000  tgenrx=0x00000030  no daemons, no watchdog
146: ensm=rf_enabled     txgain=0.000000 dB                                        no daemons, no watchdog
148_TXGAIN_VERIFIED=1   148_TGEN_OFF_VERIFIED=1   146_RESTORE_VERIFIED=1
```
TGEN off, sink disarmed (bit0 = 0; checker en + tgen_mode left set at 0x30, harmless and
correct for the next leg). Both boards armed-ROM, no traffic. `~/modem-status/SENTINEL_STOP`,
`RIG_LOCK` and `.keeper_hold_created` all still present and untouched (dated 17:27).
**The 1,800 s soak was not run** (time went to the stage-2 probes, per ruling).

## 8. What stage 3 should know
* Fabric loopback loss floor is 0.058 %, gap1 family, filler-adjacent, no 26 ms line.
* TX byte pins are clean (`tx_bit_errors = 0`) — loss is downstream of them.
* Host whitening is a **null** (PER 8.170 %, lag32 +0.68, verified both ends).
* Self-reception cannot receive any byte-plane stream; do **not** re-derive stage 2 without a
  cabled attenuator. Two-board fabric-only legs at normal link levels are the decisive test.
* Operating point for a two-board fabric leg: `GAP=60000` (gap1 measurable) with `GAP=45000`
  as the saturated control; `SINK=tgenrx` on 148, `SINK=cyclic` implemented but **never
  silicon-exercised** for 146.
