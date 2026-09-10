# Beat localisation by DDR tap capture vs bit-true and float models — design

Date: 2026-09-01. Branch: `per-under-1pct-2026-07`. Scope: the 120.2 s periodic "beat" burst (bursts alternate large/small, so the full pattern repeats every ~239.5 s) in 148
mode-1 internal loopback (ROM/BIST source). On-air bursts (146<->148 comb, TX starvation) are
OUT of scope for this spec.

## 1. Goal and finish line

Find the source of the beat, reproduce it in simulation, fix it, and validate the fix on 148.
The campaign ends when all of the following hold:

1. A named mechanism (register/arithmetic) reproduces the hardware signature in sim: ~50 BIST
   errors per frame for ~3 s, framesync intact, carrier-reset count 0, onset near 34 s after
   arm, second burst near 154 s.
2. A hardware DDR tap capture confirms the named block (displacement appears at the tap
   immediately downstream, absent immediately upstream).
3. A fix image on 148 shows no beat over three full ~240 s two-burst cycles (six burst slots, 750 s), with frame rate and BIST
   floor unchanged.
4. The Simulink fixed-point model, run on the replay window around onset with and without the
   fix, agrees with the netlist result (independent check, run last).

Every claim is labelled **proven on silicon / reproduced in sim / inferred**.

## 2. What exists and is reused (no rebuild)

- DDRCAP on the flashed 148 image `BOOT.BIN.148.txmark.1cd0cd752aa6`: selector `0x10C`
  (`(sel<<16)|dbgcap_tap`, write-only, verify by effect via `0x20C`). Taps: sel0 raw input,
  sel1 AGC (witness-dead), sel2 RRC (index-dead), sel3 postSymbolSync, sel4 postCoarseFreq,
  sel5 postCarrierSync, sel6 demod in, sel8 TX dataOut, sel9/10 demod bits, sel11 TX scrambler.
  Record = `[I | Q | demod marker | TX marker]`, 16-bit each; free-running valid, window set by
  host `iio_readdev -s N`. 512 MB = 67.1 M records ~= 1.09 s in the sample domain.
- Verilator build of the flashed netlist, `jupiter_240k5_byte/rtl_sim/obj_burst`
  (driver `sim_burst_force.cpp`), ROM loopback, per-frame BIST/rstcs/FIFO-witness log.
  Only ever run ~260-400 frames; unforced control = 0 errors/frame.
- `jupiter_240k5_byte/rtl_sim/wrap_byte_ddrcap.v`: sim wrapper exposing the five ddrcap
  ports as real ports (no hierarchical refs) — the golden tap-waveform generator.
- Float reference receiver `k5_240/decode_ref_k5.m` (RRC MF, Gardner, 4th-power CFO,
  carrier sync, hard Viterbi), scores vs the `-B` ROM reference.
- Capture rails: `two_jup/arm148_mode1.sh`, `two_jup/sel5_capture.sh` (one arm, two captures,
  1 s polls, golden `capTAP=0xBCF94856` before/after, board file deleted after host size check).
- Captures on disk: `two_jup/pair/20260901_155752/sel3.bin` (+`sel5.bin`) — DISPLACED [SILICON],
  the positive-control input; `two_jup/pair/20260901_161157_sel2b/sel2.bin` — index-dead.
- Ranked candidate list: `rtl_sim/BURST120_SIM_RESULTS.md` §1 (timing-plane integrators,
  interpolator NCO/`countReg`, Peak_Search/Timing_Adjust reference).

Geometry sanity: 12,320 symbols/frame, 12,333 marker gap, 197,328 clks/frame, ~49,349
sample-domain records/frame; sample/symbol ~= 4, symbol/bit-word ~= 8.

## 3. Leg A — simulation

### 3.1 Throughput gate (first action, blocks everything in Leg A)
Timed 500-frame unforced run on (a) the existing `obj_burst` flat build, (b) a rebuilt
`-O2 --threads N` build WITHOUT `--public-flat-rw`. Record frames/s. Decision:
- ≥ 45,000 frames in ≤ 24 h on either build → proceed with that build.
- Otherwise → report the rate as a finding; fallback is the flat build with periodic state
  snapshots (Verilator `--savable`) so a multi-day run survives teardown and resumes.
Long runs are launched as `systemd-run --user` transient units, never harness tasks
(reaped ~60 min); progress checked by background file probes.

### 3.2 Long unforced run
Driver = `sim_burst_force.cpp` with `sel=none`, frame count as the only knob. Milestones
45,000 → 200,000 → 300,000 frames. Per-frame log unchanged. Burst detector: ≥ 20 BIST
errors/frame for ≥ 200 consecutive frames with `rstcs` unchanged and packets advancing.
- **Bursts** → dump all timing-plane candidate registers (BURST120 §1 table) at clean frame
  K-100, K-1, K, K+1; diff; name the drifting state. Then forced-state reproduction: force that
  state to the pre-onset value at frame 80 and require the same signature. Hardware confirms
  per §5.
- **Clean through 300,000** → netlist exonerated *as simulated* [reproduced in sim]. Remaining
  suspects are what the sim does not model: reset phase vs `clk_enable`/`enb_1_2_0`, the IP
  wrapper and AXI regs, the input mux path. Leg B result decides the next step.

### 3.3 Golden tap streams
New driver on `wrap_byte_ddrcap.v`: for each of sel0, sel2, sel3, sel5 (and sel8, sel11 on
demand), set `iq_debug_mux`, run ≥ 200 frames after reset, write every `ddrcap_valid` record
as the 4×int16 DDR record format to `rtl_sim/golden_taps/sel<N>.bin`. Also log the sim frame
index of each TX-marker rise, so the stream is frame-indexed without the hardware marker.

## 4. Leg B — hardware DDR captures (148, mode 1, current image, no flash)

### 4.1 Capture shape
`sel5_capture.sh` generalised to `beat_tap_capture.sh SEL`: one arm, then
- capture 1 launched at T_arm + 33 s so the 1.09 s window straddles onset (~34 s), and
- capture 2 at T_arm + 36 s (mid-burst),
each 512 MB, `0x10C` set AFTER the arm, selector verified by effect via `0x20C` before and
after, 1 s polls, host-side `stat` size check before any board-side delete. If onset timing
proves wider than the window, the second arm uses two overlapping windows shifted ±1 s;
timing is tuned from the `0x108` delta log, not guessed.
Rig rules unchanged: no retry loop, never kill a restore, 146 never touched, rig units via
`two_jup/agents/launch_rig_unit.sh`.

### 4.2 Anchor-free scoring (derived unit — needs its own positive control)
`two_jup/score_tapvs_golden.py CAPTURE GOLDEN`:
1. Coarse align by cross-correlating the I channel of a clean stretch of the capture against
   the golden stream (frame-length search, then ±64 samples fine).
2. Walk the capture record by record against the aligned golden; report per-frame the offset
   that maximises match (0 = aligned), the first frame whose offset changes, and whether the
   change is a jump (one step to a new constant) or a walk (monotone drift).
3. Emit `first_divergence_record`, `offset_after`, `jump|walk`, and the per-frame offset CSV.
Controls, in order, before any new capture is quoted:
- Positive: sel3 capture on disk must reproduce the §72 displacement (a non-zero offset in the
  displaced stretch, matching the known rung set 6176/6240/6299/6363/6432 up to the
  sample/symbol factor).
- Negative: sel5 clean stretch must score offset 0 throughout.
- Then the sel2 capture on disk (no rig time) — may close §75 outright.

### 4.3 Tap order
sel0 first (raw input: if displaced, the TX/mux side of the loop is implicated and the receiver
search stops). Then sel2 if sel0 is clean. sel3 already known. Each new tap costs one arm at
the known ~40 % hang risk; captures are never repeated on the same arm beyond two.

### 4.4 Float column
`k5_240/decode_ref_k5.m` (or a thin wrapper) decodes each hardware capture window as int16 IQ
against the ROM reference: per-frame CRC/bit errors and EVM. Question answered: does an ideal
receiver on the identical samples also burst? Yes → the samples carry the defect (TX side or
upstream of the tap). No → receiver state downstream of the tap.

## 5. Decision tree (fixed in advance)

| Sim long run | sel0 | sel2/sel3 | Conclusion and next step |
|---|---|---|---|
| bursts | — | — | Mechanism hunt in sim (§3.2). One confirming arm at the tap just downstream of the named block; expected displacement at the sim onset frame ± reset-phase tolerance. |
| clean | diverges | — | TX/mux side of the loop. Move to sel8/sel11 and the modulator; float column decides framing shift vs corruption. |
| clean | clean | diverges | Receiver block between last clean and first divergent tap. Sim forcing on that block's state. Triggers the paired-tap instrument flash (§6.1) because the two taps must be seen on ONE arm. |
| clean | clean | clean, decoder still bursts | Contradicts §69/§72. STOP and re-examine the instrument; no fourth tap. |

## 6. Flashes (both on 148 only, full rails: banked restore point, readback verify, two-pass
health gate, auto-rollback, no retry loop)

### 6.1 Instrument flash — conditional
Only if §5 row 3 is reached. One image recording TWO taps per DDR record on the same clock
(from `jupiter_240k5_byte/bd_tap_dualdma.tcl`) plus a sample-domain frame counter. Two
revisions maximum; a third means the approach is written up as a question.

### 6.2 Fix flash
Prerequisites, in order: mechanism reproduced in sim; fix removes the burst at the onset frame
in sim with packets/s and BIST floor unchanged (sim gate); Simulink fixed-point model replay of
the onset window with and without the fix agrees with the netlist (§1 item 4). Validation on
148: three full 240 s cycles, beat absent by the §3.2 detector, arm health numbers (fps ≥ 1120
gate, `capTAP` golden, errps floor) unchanged.

## 7. Testing and controls summary

- Sim: throughput gate; 500-frame unforced = 0 errors; forced `ss` kick reproduces the August
  ~60/frame signature before the long run counts.
- Scoring: sel3 positive control, sel5 negative control, then sel2 on disk.
- Captures: health gates unchanged; host size check before board delete; selector verified by
  effect before and after each window.
- Fix: sim gate → Simulink replay check → three-cycle hardware soak.

## 8. Deliverables

- `rtl_sim/beat_longrun.sh`, throughput numbers, long-run frame log and verdict.
- `rtl_sim/golden_taps/sel*.bin` + generator driver.
- `two_jup/beat_tap_capture.sh`, `two_jup/score_tapvs_golden.py`, control results.
- Float-column MATLAB wrapper and per-window results.
- Findings appended to `two_jup/SESSION_20260830_AUTONOMOUS.md` as new sections, each
  labelled silicon / sim / inferred.
- If reached: instrument image, fix image, soak log, Simulink comparison.

## 9. Out of scope

On-air bursts, the S2MM boundary comb, TX byte-plane starvation, anything on 146, anything
touching `Rate_Handle` without a decision-tree row calling for it.
