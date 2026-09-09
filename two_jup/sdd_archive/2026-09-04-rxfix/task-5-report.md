# Task 5 (T1) -- the fixctl slack-bit A/B legs on silicon

Rig driver report. Campaign: happy-bubbling-owl T1. Branch `per-under-1pct-2026-07`.

## Pre-registration (quoted verbatim from happy-bubbling-owl.md, T1)

> **T1 — rig, ~40 min, no build (the cheapest decisive test):** keeper hold; forward leg with enSlack OFF (control, expect ~8 %, comb present at the pins via the checker's interval series and comb_period_ms on the host log) then enSlack ON (fixctl 0x208 = 0x8). PREREG: if the deleting stage is the Preamble_Detector FIFO, enSlack ON removes the comb (checker gap_events and host PER drop toward the loopback floor ~0.06 %, lag-32 < 0.1); falsifier: unchanged → the deletion is upstream (Rate_Handle full edge or elsewhere) and T2 proceeds on the sim's localisation. Also read the witnesses on both legs (push_on_full / pop_on_empty counts per 10 s vs the loss rate). Wedges: one re-run then UNINFORMATIVE. Restore fixctl, release the hold at the end of the rig day.

## Pre-committed reading rules (written BEFORE leg A's numbers were scored)

1. **Binary prereg.** Confirmation requires the comb gone AND PER toward the ~0.06 % floor (lag-32 < 0.1, no 32/33 interval family). An intermediate result (e.g. 8 % -> 4 %) is **PARTIAL / UNINFORMATIVE**: with one arm per leg it cannot be resolved against arm-to-arm variance.
2. **Write-only caveat.** 0x208 has no readback (`TxRxCompo_ip_addr_decoder.v`, no `read_fixctl`). Leg A writes 0x0, which is the rail default, so the control leg does not prove the write path has *effect*. "Unchanged on leg B" therefore cannot fully separate "enSlack does nothing" from "the write never landed". The mechanical evidence that the write path fires is the `LOOP_POKE ... 0x208=<val>` line in each leg's own `capture_r3.log` and the `exit=0` in `peer_poke.log`.
3. **Falsifier branch, pre-committed.** If leg B is unchanged: falsifier met; and per T0a [sim] the Rate_Handle-FULL sub-branch is separately disfavoured (`push_on_full=0`), so the residual hypothesis for T2 is the **pop-on-empty valid-density path** (T0a: 21 pop_on_empty events at -10 ppm, 95 % with a loss within +/-1 frame), not a FULL-edge symbol delete.
4. **Confirmation branch, pre-committed.** If leg B improves: this is in **tension with T0a**, and the tension must be stated, not smoothed. The SRO harness leaves `fixctl` undriven (`wrap_byte_sro.v` never drives it), so `enSlack = 0` in every harness leg and `pdPof` (`wrap_byte_sro.v:104`, tapped on the **gated** net `push_on_full_FIFO`) measured the ungated event -- it never fired. The harness therefore *cannot* exhibit the mechanism enSlack suppresses, and T2's sim gate must drive `fixctl` before it can gate anything.

## Scope of the slack bit [netlist]

`enSlack` (fixctl bit 3, `FixCtlDec.v:44`) has exactly **one** consumer:
`QPSK_Rx.v:243` (FixCtlDec) -> `QPSK_Rx.v:276` Frequency_and_Time_Synchronizer -> `Frequency_and_Time_Synchronizer.v:184` Preamble_Detector -> `FIFO.v:118` -> `Validate_Input_Push_Pop.v:136`
`assign push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y & ( ~ enSlack);`
i.e. it gates push-on-full of the 12,333-deep realignment FIFO only. `Rate_Handle.v:118` instantiates `FIFO_block` -> `Validate_Input_Push_Pop_block`, which has **no `enSlack` port at all**. So a positive T1 result localises to the Preamble_Detector realignment FIFO specifically, not to "one of the two guarded FIFOs".

## Results

(filled in after the legs)

Both legs are forward (LEG=A, 146 TX -> 148 RX), `capture_r3.sh ... -d 600`, shipped LOs/RXQ, run as systemd units under `launch_rig_unit.sh` with the keeper hold in force (`SENTINEL_STOP` + `RIG_LOCK` created 09:30:43, sentinel/keeper stopped, `lock_watchdog` killed on both boards).

### Credit gate (legrun_go.sh, RATE_GATE=900) -- both legs CREDITED

| | leg A `rxfix-slack0` (SLACK=0) | leg B `rxfix-slack1` (SLACK=1) |
|---|---|---|
| run dir | `two_jup/rxfix/runs/20260904_093052_slack0_t1-control` | `two_jup/rxfix/runs/20260904_094543_slack1_t1-slackon` |
| `capture_r3_exit` | 0 | 0 |
| `wedge_verdict` | healthy crc=92% rate=1911f/s | healthy crc=92% rate=954f/s |
| `deliver_rate_pre/post` | 1911 / 1911 | 954 / 954 |
| `deliver_rate_gate_pass` | 1 | 1 |
| watchdog relaunches (rx/peer) | 0 / 0 | 0 / 0 |
| unit exit | success code=0 @09:45:25 | success code=0 @10:00:47 |
| `fixctl_restored` | 1 (issued+exit0 both boards) | 1 (issued+exit0 both boards) |

No wedge, no relaunch, no re-run needed on either leg.

### fixctl audit trail (the write path, per leg) [silicon]

| | leg A | leg B |
|---|---|---|
| health-gate marker (`capture_r3.log:28`) | `wedge verdict: healthy crc=92% rate=1911f/s` | `wedge verdict: healthy crc=92% rate=954f/s` |
| 148 write (`capture_r3.log:29`, 5b LOOP_POKE, pre-window) | `LOOP_POKE on 10.0.0.148: 0x208=0x0` | **`LOOP_POKE on 10.0.0.148: 0x208=0x8`** |
| 146 write (`peer_poke.log`) | 09:33:00 trigger, `write exit=0` 09:33:01 | 09:47:56 trigger, `write exit=0` 09:47:57 |
| checker taken (s3h `run.log`) | 09:32:45 clear pulse | 09:47:42 clear pulse |
| restore | 09:45:20 146, 09:45:21 148, both exit 0 | 10:00:22 146, 10:00:23 148, both exit 0 |

Both boards' writes landed on the same `wedge verdict:` event that fires 148's own in-script hook, i.e. strictly before the framelog rotate / Tap-A capture / traffic window. 0x208 has no readback (`TxRxCompo_ip_addr_decoder.v:869-885` has `write_fixctl` only, no read path; the `fx=` field in `regs_*.txt` is register 0x15C, not 0x208), so "restored" means the write was issued and exited 0.

### Side by side [silicon]

| metric | leg A -- enSlack **OFF** (control) | leg B -- enSlack **ON** (0x208=0x8) | change |
|---|---|---|---|
| host PER (`accept_analyze`, lost frames in the denominator) | **8.351 %** (73,003 / 874,137) CP95UL 8.410 | **8.426 %** (73,773 / 875,537) CP95UL 8.484 | +0.075 pp (worse, within noise) |
| live window | 717 s / 722 s | 718 s / 723 s | -- |
| lag-32 autocorr, ALL-LOSS (`comb_autocorr.py`) | **+0.3974** | **+0.3231** | comb intact (prereg wanted < 0.1) |
| lag-33 / lag-16 (ALL-LOSS) | -0.0235 / -0.0867 | -0.0452 / -0.0874 | -- |
| lag-32, SINGLES-ONLY | +0.1858 | +0.0855 | -- |
| comb period (`comb_period_ms.py`) | **31.307 frames = 25.14 ms**, band R 0.1397 | **31.250 frames = 25.09 ms**, band R 0.2208 | same line, stronger on B |
| `COMB_LINE` verdict | **present** | **present** | unchanged |
| loss-run bins {1, 2, 3-4, 5-20} | 37,931 / 15,760 / 549 / 170 | 37,405 / 16,303 / 576 / 176 | unchanged |
| checker `gap_events` / emitted (stage 3h, decoder pins, 148) | **35,321 / 663,457 = 5.324 %** | **35,758 / 667,671 = 5.356 %** | +0.032 pp |
| checker `garbage %` | 5.896 % | 5.887 % | -- |
| checker `crc_fail %` | 2.023 % | 2.078 % | -- |
| checker interval histogram int_32 / int_33 / int_other / <30 | 1,277 / 29 / 8,896 / 25,119 | 1,251 / 9 / 9,543 / 24,955 | 32-frame intervals still present |
| checker `int_last` series (median / min) | 23 / 5 | 23 / 6 | unchanged |
| s3h readings / window | 49 / 540 s | 49 / 540 s | -- |

Notes on the checker numbers: `lost_slots` is void on an RF leg (the counter wraps/clears against the daemon's own stream; both legs' `seqbist_score.py` headline verdict is `UNINFORMATIVE` for exactly that reason -- 27 and 25 negative `chk_lost_slots` deltas), so per the brief only `gap_events/emitted`, `garbage %`, `crc_fail %` and the `int_last` series are quoted. Both readers were anchored on the leg's own `BRING-UP COMPLETE` marker, not on launch time, so the two windows are directly comparable despite leg A's reader having been launched ~75 s later than leg B's (see Deviations).

### Verdict against the pre-registration: **FALSIFIER MET (unchanged)**

The pre-registration reads, verbatim: *"PREREG: if the deleting stage is the Preamble_Detector FIFO, enSlack ON removes the comb (checker gap_events and host PER drop toward the loopback floor ~0.06 %, lag-32 < 0.1); falsifier: unchanged → the deletion is upstream (Rate_Handle full edge or elsewhere) and T2 proceeds on the sim's localisation."*

Nothing moved. PER 8.351 % -> 8.426 % (both CP95ULs overlap; the prereg's target was ~0.06 %). lag-32 +0.397 -> +0.323, never near the < 0.1 threshold. `COMB_LINE=present` on both, at the same 25.1 ms / ~31.3-frame line. Checker `gap_events/emitted` 5.324 % -> 5.356 %, with 32-frame intervals still in the histogram on both legs. This is not the "intermediate result" case that pre-committed rule 1 would call PARTIAL -- it is a null of the flattest kind, with leg B marginally *worse* on every axis.

**Conclusion:** with `enSlack` asserted on both boards, the Preamble_Detector realignment FIFO's push-on-full suppression is disabled and the comb is completely unaffected. Per the netlist scope above, the bit reaches only that FIFO, so the deleting stage is **not** the Preamble_Detector realignment FIFO's push-on-full path.

**T2 input (pre-committed rule 3):** the falsifier's named sub-branch (Rate_Handle FULL edge) is separately disfavoured by T0a [sim] (`push_on_full = 0` on every scored leg), so the residual hypothesis is the **pop-on-empty valid-density path** (T0a [sim]: 21 `pop_on_empty` events at -10 ppm, 95 % with a loss within +/-1 frame), not a FULL-edge symbol delete. T2 should not be cut against a push-on-full deletion in either FIFO.

### Caveats and limits

1. **The write is unverifiable by readback** (pre-committed rule 2). What is verified: the write path fired with the intended value on both boards, pre-window, on both legs (`0x208=0x0` / `0x208=0x8` in each leg's own `capture_r3.log:29`, plus `exit=0` on 146). What is *not* verified: that fabric register 0x208 holds 0x8 during leg B's window. A null therefore cannot fully exclude "the write never reached the register", only "the write was issued correctly". This is inherent to a write-only register and is the strongest form the test can take without an RTL readback.
2. **Delivery-rate asymmetry between the arms.** Leg A's health line read 1911 f/s and leg B's 954 f/s. Both clear the 900 f/s gate and both windows delivered ~874-876 k frames over ~718 s, so the scored windows are comparable; the difference is in the pre-window health probe, not the window. It is a reason not to read the +0.075 pp PER difference as signal.
3. **The within-leg step control was not resolvable.** The checker was cleared 14 s before the poke on leg B (09:47:42 vs 09:47:56), giving only ~1 pre-poke 10 s reading -- too few to test for a step at the poke timestamp. The aggregate matching leg A is the evidence; no step was sought in a 1-sample baseline.
4. **The FIFO witnesses were not read.** Task 3 established `witness_read.sh` returns `NOT_AVAILABLE` on this image: 0x20C/0x210 carry the 2026-08-30 DBGCAP per-stage registers (`QPSK_Rx.v:816,818`), not `pdWitA`/`pdWitB` (dead nets), and Rate_Handle's `beatobs` pointers route to the RX I/Q DMA stream, not an AXI-lite address. The prereg's "read the witnesses on both legs" is therefore not satisfiable on the flashed image; no rig time was spent on it.
5. **[sim]/[silicon] tension, per pre-committed rule 4:** does not arise. The harness leaves `fixctl` undriven (`wrap_byte_sro.v` never drives it), so `enSlack = 0` there and `pdPof` (`wrap_byte_sro.v:104` at the time of reading, tapped on the gated net `...u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO`) measured the ungated event as zero. Sim and silicon agree: that path does not fire.

6. **No fabric-register activity between the poke and the window.** Leg B's `capture_r3.log` between the `LOOP_POKE ... 0x208=0x8` line and the window's first `580s traffic remaining` shows only the `loop regs now:` readback (0x170/0x174/0x184), the `CAP_START`/`CAP_END` register pair and the Tap-A capture -- no arm, profile reload or reset step that could have zeroed 0x208 after the write. Caveat 1 is therefore limited to "the register cannot be read back", not "a later step may have cleared it".
7. **`CAPTURE_HEALTH` on the Tap-A IQ snapshot reads `DEGENERATE` on BOTH legs, identically** (occupied BW 2.88 MHz, envelope periodicity 0.9995 at lag 256 -- the #48 stale-DDR-replay signature). This is the `cap/pair.iq` IQ-DMA tap only. Every number in this report comes from the host framelog (`cap/frames.bin`, ~875 k delivered frames per leg over ~718 s) and from the fabric checker on 148, neither of which uses `pair.iq`; both legs' delivery gates passed. The condition is symmetric across the A/B pair, so it cannot generate the null. No conclusion here is drawn from `pair.iq`.

### Deviations from the brief (both discovered on silicon, neither reachable by the DRY tests)

1. **`two_jup/seqbist/stage3h_reader.sh` was mode 644, not executable.** `slackleg_go.sh:200` launches it directly, so on leg A the inline launch died instantly with `Permission denied` (recorded in `stage3h_wrapper.log`) and the primary judge would have been lost. Fixed with `chmod +x` (a real mode change to a tracked file, included in this commit) and the reader relaunched for leg A as its own unit against the same `LEGLOG`/`OUT`. Leg B used the repaired inline path (single reader; a second unit would have raced the same checker's bit-4 clear).
2. **The first relaunch (`rxfix-slack0-s3h`) was given relative paths** and, since a systemd unit does not inherit the caller's cwd, wrote to `~/two_jup/...` and could never have found the leg log. It had taken no board action (still in its pre-`BRING-UP COMPLETE` wait loop), so it was stopped and relaunched with absolute paths as `rxfix-slack0-s3hb`; the stray directory was removed. Leg A's checker series (49 readings / 540 s) comes from that unit.

### Close-out

`fixctl` restore issued and exit-0 on both boards at the end of each leg (`RESTORE ISSUED on both boards` in both `run.log`s; leg A also ran with the rail default 0x0 throughout). Hold released 10:07:08: `SENTINEL_STOP` and `RIG_LOCK` removed, `sentinel-100708` + `sentinelkeeper-100708` running, sentinel log shows `sentinel (re)launched by keeper`. Heartbeat unit `hb-task5` stopped.
