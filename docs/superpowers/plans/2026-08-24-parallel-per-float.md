# Parallel PER-Localization + Float-Baseline Campaign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize the ~13.1 % forward singles comb to a named stage while restoring IQ capture on 148 and completing the float baseline — two lanes sharing one flash event.

**Architecture:** Lane B (offline MATLAB) diagnoses the float receiver's moderate-SNR cliff and stamps a validated-SNR floor. Lane A runs tap-independent discriminators first (ROM-air comb census, conditional SSI-NEL), then flashes the banked `tgenrx` image under full rails (operator go required), takes the binary tap verdict, and — on PASS — runs the convergence experiment: one ROM-on-air signal scored by BIST counters, register anchors, and the float receiver per-frame.

**Tech Stack:** Bash harnesses over `anyssh.sh`, on-board `busybox devmem`/`direct_reg_access` polling, Python 3 + NumPy analyzers, MATLAB R2025b headless (`/mnt/onetb/MATLAB/R2025b/bin/matlab -batch`), existing flash rails (`two_jup/skidfix/flash_148_tgenrx.sh`).

**Spec:** `docs/superpowers/specs/2026-08-24-parallel-per-float-design.md`

## Global Constraints

- **The rig is a hard mutex** — one harness at a time, never two concurrently. Restore/re-verify after every session.
- **146 is NEVER touched** beyond normal link bring-up. Never flashed. (TMR `433fd8dab393`.)
- **The flash (Task 3) waits for the operator's explicit go at execution time.** Everything before it must not assume the flash happened.
- **Metrics rule:** no PER/BER claim without (1) the exact command, (2) sample/frame count, (3) confirmation of what is in the denominator. BER and frame recovery reported separately.
- **Verdict rules are pre-stated and not revised after seeing data.** A mis-specified rule is reported as mis-specified, not silently patched.
- **Watcher discipline:** never `pgrep`/`pkill` a pattern present in your own command line — bracket it (`[q]psk_tun`) or use explicit PIDs. Wait on strict terminal markers.
- **MATLAB** at `/mnt/onetb/MATLAB/R2025b/bin/matlab`, headless `-batch "<scriptname>"`. `Trial License` banner is normal. Inline multi-line `-batch` strings are unreliable through this harness: write a temporary `.m` inside `k5_240/`, run by name, delete after.
- **Every IQ capture is gated by `two_jup/check_capture_health.py`** (occupied BW ~22 MHz AND envelope autocorr at lag>200 < 0.9). A FAIL capture produces no conclusions.
- Git: `git commit -s`; commit implies push to `per-under-1pct-2026-07`.
- **The recurring defect class** (5 instances so far): correct K5-era values becoming incorrect at f1536. Assume each task contains one and look for it.

## Reference values (measured; use verbatim)

```
Forward delivered PER (tun/byte-DMA TX): 13.107 % (10181/77674, CP95UL 13.347 %)  host framelog
Forward air BIST error rate (ROM TX):    315 errs / 156 frames / 125 ms  ~= 2,520 err/s  (post-Viterbi)
Comb-present prediction for ROM-air:     163 corrupt frames/s x ~12,000 errs  ~= 2e6 err/s
Line rate: 1245 f/s.  Frame: 24640 payload bits, 12333 symbols, 49332 samples at 61.44 MSPS.
Float receiver: G1-clean; AWGN ladder clean at >=12 dB Es/N0, chance at <=9 dB.
Air Es/N0 is UNKNOWN and plausibly 7-12 dB (8.2e-5 is POST-FEC; channel BER is higher).
  => Lane B's floor work is the critical path for A3, not polish.
Banked image: tgenrx 87355641f018 (gates green 08-18, never flashed, predates beat overlays).
Rollback on 148: /root/BOOT.BIN.e49c011b.bak (verified present).
```

---

## File Structure

| file | responsibility |
|---|---|
| `k5_240/float_baseline_f1536.m` | (modify) G2 diagnostics, `res.snrEstDb`, `VALIDATED_ESN0_FLOOR_DB`, possible intra-frame phase-tracking fix |
| `k5_240/gates_float_baseline_f1536.m` | (modify) ladder emits the measured floor; G2 pass criterion tied to the floor, not to a fixed 1e-4 |
| `two_jup/rom_air_comb_census.sh` | (create) long-dwell ROM-air BIST census — the TX-source discriminator |
| `two_jup/analyze_comb_census.py` | (create) census scorer with pre-stated thresholds |
| `two_jup/skidfix/flash_148_tgenrx.sh` | (reuse, unmodified) flash rails |
| `two_jup/capture_rom_air.sh`, `two_jup/layerA_ssi_nel.sh`, `two_jup/tgen_sweep.sh` | (reuse, unmodified) |
| `two_jup/SINGLES_CAMPAIGN.md` | (modify) every task appends its result |

---

## Task 1 (Lane B, offline — start immediately): G2 bounded diagnosis + validated-SNR floor

**Files:**
- Modify: `k5_240/float_baseline_f1536.m`
- Modify: `k5_240/gates_float_baseline_f1536.m`

**Interfaces:**
- Consumes: `synth_f1536_waveform(nFrames, opts)` (`opts.esn0_db`, noise independent, Es/N0 verified = per-sample SNR + 6.02 dB), `f1536_ref_bits()`, existing `res` fields.
- Produces: `res.snrEstDb` (EVM-based Es/N0 estimate on locked payload symbols, double, NaN if no lock); `res.errPosProfile` (1x10 double, fraction of bit errors per within-frame decile); constant `VALIDATED_ESN0_FLOOR_DB` at the top of `float_baseline_f1536.m`; gate runner prints `FLOOR_DB=<n>`.

**Why this is the critical path:** the air Es/N0 is plausibly 7–12 dB (see reference values). If the floor stays at 12, A3 may be unable to produce a valid verdict at all. The strongest suspect is **intra-frame phase drift**: the receiver derotates each frame once from its 13-symbol preamble, adequate at K5's ~1100 payload symbols, questionable at f1536's 12,320 — the same K5→f1536 defect class as the previous five instances. A residual CFO/phase error rotates the constellation progressively across the frame, so errors should concentrate in late deciles.

- [ ] **Step 1: Add the two diagnostics (no behavior change)**

In `float_baseline_f1536.m`, after per-frame decode, compute and attach:

```matlab
% --- diagnostics (added Task 1, 2026-08-24) ---
% errPosProfile: where within the frame do bit errors fall? A tail-heavy profile
% is the signature of intra-frame phase drift (single preamble derotation over
% 12320 payload symbols -- 11x K5's span, the suspected K5->f1536 defect).
edges = round(linspace(0, INFO, 11));
prof = zeros(1,10);
for d = 1:10
    seg = (edges(d)+1):edges(d+1);
    prof(d) = prof(d) + sum(dec(seg) ~= REF.info(seg));
end
% accumulate across frames; normalize at the end: res.errPosProfile = prof/sum
```

```matlab
% snrEstDb: EVM-based Es/N0 on the derotated payload symbols of ACCEPTED frames.
% evm^2 ~= 1/(Es/N0) for QPSK at unit ref power.
ev = payD_derot./abs(payD_derot) - nearestConstPoint;   % use existing decision vars
evm2 = mean(abs(payD_derot - hardDecisionSyms).^2) / mean(abs(hardDecisionSyms).^2);
res.snrEstDb = -10*log10(evm2);   % NaN if no accepted frames
```

(Adapt variable names to the file's actual locals — the formulas are the contract; read the decode loop and attach at the point where derotated payload symbols and hard decisions coexist.)

- [ ] **Step 2: Run the drift diagnostic at 9 dB**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
cat > t1diag_tmp.m <<'EOF'
r9  = float_baseline_f1536(synth_f1536_waveform(6, struct('esn0_db', 9)));
rInf= float_baseline_f1536(synth_f1536_waveform(6));
fprintf('DIAG 9dB  ber=%.3e snrEst=%.1f profile=[%s]\n', r9.ber, r9.snrEstDb, num2str(r9.errPosProfile,'%.2f '));
fprintf('DIAG Inf  ber=%.3e snrEst=%.1f\n', rInf.ber, rInf.snrEstDb);
EOF
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "t1diag_tmp" 2>&1 | grep '^DIAG'; rm -f t1diag_tmp.m
```

Read the profile. **Tail-heavy** (last 3 deciles carry most errors) → phase drift confirmed, go to Step 3. **Flat** → drift refuted; test the second suspect (`precorrthresh` — count frames rejected vs accepted at 9 dB) and the loop bandwidths; report what you find and go to Step 4 with whatever floor the ladder gives.

- [ ] **Step 3: If drift confirmed — blockwise decision-directed phase tracking (the bounded fix)**

Replace the single per-frame derotation with per-block re-estimation. Concept (adapt to the file's structure):

```matlab
% Blockwise DD phase tracking: split the 12320 payload symbols into NB blocks.
% Block 1 uses the preamble rotation r0. Each subsequent block refines the
% rotation from the PREVIOUS block's hard decisions (decision-directed):
%   phi_k = angle( sum( y_prev .* conj(d_prev) ) )
% Applied rotation for block k = accumulated phi. NB=16 -> 770 syms/block,
% small enough that residual drift within a block is negligible at any CFO the
% coarse stage lets through (bound: 623 Hz -> 0.015 rad/block at 15.36 Msym/s).
NB = 16;
```

Rules: the tracker must be **bypassable** (`opts` flag, default ON) so G1 can be re-run both ways; G1 must still give **exactly 0 bit errors**; the planted-fault gate (G3) must still pass (DD tracking must not "fix" planted bit flips — they are data, not phase).

- [ ] **Step 4: Re-run the full ladder; stamp the floor**

Extend the ladder in `gates_float_baseline_f1536.m` to Es/N0 = [0 3 6 8 9 10 12] and define: **floor = lowest rung with zero bit errors across 6 frames**. Print `FLOOR_DB=<n>` as a strict marker. Write the result into `float_baseline_f1536.m` as:

```matlab
VALIDATED_ESN0_FLOOR_DB = <measured>;   % AWGN ladder, gates_float_baseline_f1536, 2026-08-24
```

Run: `matlab -batch "gates_float_baseline_f1536"` → expect `GATES_PASS` and `FLOOR_DB=` printed. **Timebox:** if after Steps 2–3 the floor has not improved below 12, stop — 12 dB is the floor, record why, and move on. Do not iterate loop constants beyond the named suspects.

- [ ] **Step 5: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add k5_240/float_baseline_f1536.m k5_240/gates_float_baseline_f1536.m
git commit -s -m "float receiver: G2 diagnosis, snrEstDb, validated-SNR floor

errPosProfile diagnostic + EVM-based snrEstDb. [Describe drift verdict and fix here
per actual findings.] Ladder extended; VALIDATED_ESN0_FLOOR_DB stamped. Air Es/N0 is
plausibly 7-12 dB (8.2e-5 is post-FEC), so the floor is the gate A3 lives or dies by."
git push origin per-under-1pct-2026-07
```

---

## Task 2 (Lane A, rig, pre-flash): ROM-air comb census — the TX-source discriminator

**Files:**
- Create: `two_jup/rom_air_comb_census.sh`
- Create: `two_jup/analyze_comb_census.py`
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: `rearm_rom` sequence and framesync gate (copy from `capture_rom_air.sh`, which is proven), `anyssh.sh`.
- Produces: `r3cap/combcensus_<ts>/census.csv` (columns `t_s,pkts,biterr`), verdict line `COMB_CENSUS_VERDICT=<PRESENT|ABSENT|ANOMALOUS>`.

**Why first and why pre-flash:** the banked 125 ms anchor already hints the comb vanishes when 146 transmits ROM instead of byte-DMA tun over the *same* air path (2,520 err/s observed vs ~2e6 predicted-if-present). Confirming that statistically re-localizes the comb away from RF/SSI/ingress entirely — with no tap, no flash, no float. It runs on the current image today.

**Pre-stated verdict rule:**
- mean biterr rate **> 1e5/s** → **PRESENT**: comb lives in RF/SSI/ingress (TX-source-independent). Next: SSI-NEL (Step 4) splits RF from SSI.
- mean biterr rate **< 1e4/s** → **ABSENT**: comb requires the byte-DMA TX source / host traffic path on 146. RF/SSI/ADC-ingress substantially exonerated for the comb. SSI-NEL is then **skipped** (superset already clean); the re-aimed suspect list is 146's byte-TX datapath and host submission, and the follow-on discriminator is recorded for the next spec (fabric-pattern TX on 146 needs no flash: `0x158` write — noted, not executed here).
- between → **ANOMALOUS**: report raw series, no verdict.

- [ ] **Step 1: Write the census harness**

Create `two_jup/rom_air_comb_census.sh`:

```bash
#!/bin/bash
# rom_air_comb_census.sh -- does the 13.1% comb exist when 146 transmits ROM over air?
# TX-source discriminator: same RF, same SSI, same ingress, same demod as the tun-mode
# 13.107% measurement -- only the TX data source differs (ROM vs byte-DMA).
# Pre-stated verdict: biterr>1e5/s PRESENT ; <1e4/s ABSENT ; else ANOMALOUS.
# Predictions: comb-present ~2e6 err/s ; comb-absent ~2.5e3 err/s (banked 125ms anchor).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DWELL=${DWELL:-120}
OUT=$D/r3cap/combcensus_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
echo "=== ROM-air comb census: 146 ROM -> 148 RX, ${DWELL}s ==="

for ip in $B $A; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
done

rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
rearm_rom $B; rearm_rom $A; sleep 3
rearm_rom $B; rearm_rom $A; sleep 4

FS=$($W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA)
  echo $(( (p1-p0)/5 ))' 2>/dev/null)
echo "  148 ROM framesync = ${FS:-0} f/s (gate >= 1120)"
[ "${FS:-0}" -ge 1120 ] || { echo "ABORT: forward ROM leg not at rate"; exit 1; }

$W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  : > /dev/shm/census.csv
  n=\$(( $DWELL * 20 ))
  i=0
  while [ \$i -lt \$n ]; do
    printf '%s,%s,%s\n' \"\$(date +%s.%N)\" \"\$(rd 0x104)\" \"\$(rd 0x108)\" >> /dev/shm/census.csv
    i=\$((i+1))
  done" 2>/dev/null
$W $A 'wc -l /dev/shm/census.csv; cat /dev/shm/census.csv' 2>/dev/null | { read hdr; echo "  samples: $hdr"; cat > "$OUT/census.csv"; }
python3 "$D/analyze_comb_census.py" "$OUT/census.csv" | tee "$OUT/verdict.txt"
echo "COMB_CENSUS_DONE $OUT"
```

- [ ] **Step 2: Write the scorer**

Create `two_jup/analyze_comb_census.py`:

```python
#!/usr/bin/env python3
"""analyze_comb_census.py census.csv -- pre-stated verdict on the ROM-air comb census.
PRESENT  if mean biterr rate > 1e5/s  (comb prediction ~2e6/s)
ABSENT   if                 < 1e4/s  (clean anchor ~2.5e3/s)
ANOMALOUS otherwise. Counters are cumulative; wraps/resets (negative deltas) dropped."""
import sys
import numpy as np

rows = np.genfromtxt(sys.argv[1], delimiter=",",
                     converters={1: lambda s: int(s, 16), 2: lambda s: int(s, 16)})
t, pk, be = rows[:, 0], rows[:, 1], rows[:, 2]
dt, dpk, dbe = np.diff(t), np.diff(pk), np.diff(be)
ok = (dt > 0) & (dpk >= 0) & (dbe >= 0)
span = t[-1] - t[0]
fps = dpk[ok].sum() / dt[ok].sum()
eps = dbe[ok].sum() / dt[ok].sum()
# time structure: per-sample biterr deltas; a comb single is ~12k errs in one bucket
big = int((dbe[ok] > 5000).sum())
print(f"CENSUS span={span:.1f}s samples={len(t)} framesync={fps:.0f} f/s "
      f"biterr_rate={eps:.3g}/s big_events={big}")
print(f"  denominators: {dpk[ok].sum():.0f} frames, {dbe[ok].sum():.0f} bit errors, "
      f"{dt[ok].sum():.1f} s counted (wrap-dropped: {int((~ok).sum())})")
v = "PRESENT" if eps > 1e5 else ("ABSENT" if eps < 1e4 else "ANOMALOUS")
print(f"COMB_CENSUS_VERDICT={v}")
```

- [ ] **Step 3: Confirm the rig is free, run it, restore**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
ps -eo pid,cmd | grep -E '[c]apture_r3|[l]oopback|[r]estore_known|[t]gen_sweep|[c]omb_census' || echo RIG_FREE
chmod +x rom_air_comb_census.sh analyze_comb_census.py
setsid nohup env DWELL=120 ./rom_air_comb_census.sh > /tmp/combcensus.log 2>&1 < /dev/null & disown
# wait on the strict marker COMB_CENSUS_DONE, PID-based
```

Afterwards restore the link: `setsid nohup env GATE_DIR=A GATE_TRIES=8 ./bringup_r2r3.sh r3 ...` then restart watchdogs on both boards (isolated ssh calls, verify UP).

- [ ] **Step 4: Conditional SSI-NEL (ONLY on PRESENT)**

If and only if the verdict is PRESENT: run the existing `layerA_ssi_nel.sh` (`DWELL=300`), which removes RF but keeps SSI + ingress. Comb in NEL → SSI/ingress; absent in NEL → RF. On ABSENT, skip and record why (superset already clean).

- [ ] **Step 5: Record + commit**

Append to `SINGLES_CAMPAIGN.md`: exact commands, the census table (span, frames, errors, denominators), the verdict, and — on ABSENT — the explicit re-localization statement and the follow-on suspect list. Commit `-s`, push.

---

## Task 3 (Lane A, rig): flash the banked tgenrx image + binary tap verdict

**Files:**
- Reuse: `two_jup/skidfix/flash_148_tgenrx.sh` (unmodified)
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: banked BOOT.BIN md5 `87355641f018`; rollback `/root/BOOT.BIN.e49c011b.bak` (verified on 148); `check_capture_health.py`; the gated-capture pattern (bring-up with `GATE_DIR=A`, framesync ≥ 1120 verified at capture time).
- Produces: `TAP_VERDICT=<PASS|FAIL>` recorded in `SINGLES_CAMPAIGN.md`; on PASS, Task 4's A3 branch is unlocked.

- [ ] **Step 1: STOP — obtain the operator's explicit go for the flash.** Do not proceed past this line without it. Present: image md5 `87355641f018`, rails (readback, two-pass health gate fsync≥1100 AND wcnt≥1100, rollback to `e49c011b` on any failure, TGEN GPIOs must read 0), and the named regression (BEATFIX removed, PER-neutral, re-flashable from the banked v3 image).

- [ ] **Step 2: Flash under rails**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/skidfix
setsid nohup ./flash_148_tgenrx.sh 87355641f018 > /tmp/flash_tgenrx.log 2>&1 < /dev/null & disown
# wait on FLASH_SKID_DONE / FLASH_SKID_FATAL strict markers
```

On FATAL: the script rolls back itself; verify 148 boots the rollback, report, STOP.

- [ ] **Step 3: Tap verdict — one gated capture, pre-stated and binary**

Bring up (`GATE_DIR=A`), verify framesync ≥ 1120 at capture time, clear `0x10C`, capture 1.5 M samples from `axi-adrv9002-rx-lpc`, fetch with the `SSH_ASKPASS` form, then:

```bash
python3 two_jup/check_capture_health.py <capture>; echo "TAP_VERDICT_EXIT=$?"
```

- exit 0 → **TAP_VERDICT=PASS**: IQ restored; ramp convicted as beat-overlay-lineage. Task 4 A3 unlocked.
- exit 1 → **TAP_VERDICT=FAIL**: ramp predates the beat overlays — record (it re-aims any future ramp diagnosis); float thread falls back to Aug-12-capture scope; Task 4 runs its FAIL branch. **No reinterpretation.**

- [ ] **Step 4: Record + commit** (verdict, flash log gates, exact commands) to `SINGLES_CAMPAIGN.md`.

---

## Task 4 (Lane A, rig): A3 convergence experiment — or the FAIL-branch record

**Files:**
- Reuse: `two_jup/capture_rom_air.sh` (health gate + fixed scp already wired), `k5_240/float_baseline_f1536.m` (Task 1 version), `two_jup/tgen_sweep.sh`
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: `TAP_VERDICT` (Task 3), `VALIDATED_ESN0_FLOOR_DB` + `res.snrEstDb` (Task 1), `COMB_CENSUS_VERDICT` (Task 2).
- Produces: the A3 per-frame table and discriminator verdict, or the FAIL-branch record.

**PASS branch:**

- [ ] **Step 1: ROM-on-air capture** via `capture_rom_air.sh` (it gates on framesync, logs CAP_START/CAP_END register anchors, health-checks the capture, fails loudly on empty fetch). A health-FAIL capture → record, stop, no verdict.

- [ ] **Step 2: Float decode with validity gates**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
cat > a3_tmp.m <<'EOF'
r = float_baseline_f1536('<capture>/pair.iq');
fprintf('A3 frames=%d ber=%.3e frameRecovery=%.4f snrEst=%.1f floor=%d hypStable=%d margin=%d\n', ...
  r.nFrames, r.ber, r.frameRecovery, r.snrEstDb, VALIDATED_ESN0_FLOOR_DB, r.hypStable, r.hypMargin);
writetable(r.perFrame, '<capture>/float_perframe.csv');
EOF
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "a3_tmp"; rm -f a3_tmp.m
```

Validity gates (all required, any miss → run invalid, recorded as such): capture health PASS; `r.snrEstDb >= VALIDATED_ESN0_FLOOR_DB`; `hypStable=1` with margin reported. **If `snrEstDb` is below the floor, that is itself a finding** — the air link runs below the receiver's validated region — record it with both numbers; do not score.

- [ ] **Step 3: The three-scorer comparison**

Hardware truth for the same window: `biterr`/`pkts` deltas from CAP_START/CAP_END anchors (aggregate over ~156 frames). Float truth: per-frame errors from `float_perframe.csv`. Verdict, pre-stated:
- hardware shows losses/errors in the window AND float decodes those frames clean → **implementation gap** (ADC-ingress/demod named).
- float error positions match hardware's rate → **channel/RF**; fabric exonerated at f1536 air conditions.
- G4 invariant still binds: float BER must be ≤ the hardware's window BER; float-worse → instrument fault, not a channel finding.
- If Task 2 returned ABSENT, expect a near-clean window; then A3's deliverable is the completed float baseline (float-vs-hardware BER on the same air signal) rather than comb forensics — say so plainly.

- [ ] **Step 4: TGEN loopback regression point** (one point, `KEEPM=1 RXM=16`, gap=20000): confirms the new image reproduces Task 3b's ~0.6 % at line rate. Deviation > 2× → flag before any further use of this image.

**FAIL branch:** record that the float thread is limited to the Aug-12 capture (EVM bound only), run Step 4's regression point (tap-independent), and the campaign's localization verdict rests on Task 2/Task 2-Step-4 results.

- [ ] **Step 5: Record + commit.**

---

## Task 5: Synthesis — the localization verdict

**Files:**
- Modify: `two_jup/SINGLES_CAMPAIGN.md`, `OVERNIGHT_LOG.md`, `/home/tcollins/modem-status/focus.txt`

- [ ] **Step 1: Write the evidence table** — every leg (13.107 % tun-air baseline; 0.62 % batched loopback; census verdict; NEL verdict if run; A3 verdict if run) with commands, counts, denominators.

- [ ] **Step 2: State the localization** as far as the evidence carries it — and no further. The template: "the comb requires {X}; {Y,Z} are exonerated by {legs}; the next discriminator is {named experiment}." If legs conflict, say so; do not harmonize.

- [ ] **Step 3: Update `OVERNIGHT_LOG.md`** with a campaign checkpoint (headline, verified-on-hardware list, retraction-free this time or listed, rig state, next steps) and refresh `focus.txt`. Commit `-s`, push.

---

## Self-Review

**Spec coverage:** A1→Task 3 Steps 1–2; A2→Task 3 Step 3; A3→Task 4 Steps 1–3; A4 SSI-NEL→Task 2 Step 4 (made conditional — justified refinement: NEL is uninformative if the ROM-air superset is already clean; the spec's intent is localization, and the census is the stronger first split); A4 TGEN points→Task 4 Step 4 (reduced to a regression point — full rate ladders on the new image add nothing to localization; forward-air TGEN is impossible without flashing 146, which is forbidden); B1→Task 1; B2 stretch→correctly absent. Spec's "host framelog" scorer in A3: on the ROM path no daemon runs, so delivery truth comes from the BIST frame counter + register anchors — stated in Task 4 Step 3 rather than silently substituted.

**Placeholder scan:** the one bracketed item is Task 1 Step 5's commit-message insert, which depends on the diagnostic outcome and says so. Task 4's `<capture>` is the Task-4-Step-1 output path, named at point of use.

**Type consistency:** `res.snrEstDb`/`res.errPosProfile`/`VALIDATED_ESN0_FLOOR_DB` defined in Task 1, consumed with identical spellings in Task 4. `COMB_CENSUS_VERDICT` produced Task 2, consumed Task 4. `TAP_VERDICT` produced Task 3, consumed Task 4. Census CSV columns match between harness and scorer (`t,pkts,biterr`, hex converters in the scorer because `direct_reg_access` prints hex — verified format assumption flagged for the implementer to confirm on first sample).

**Known weak point, stated:** `analyze_comb_census.py` assumes `direct_reg_access` reads print hex (`0x...`); if the on-board output is decimal the converters must be adjusted — the implementer must check the first CSV lines before trusting the scorer, and the scorer's frame-rate output doubles as the sanity check (should read ~1245).
