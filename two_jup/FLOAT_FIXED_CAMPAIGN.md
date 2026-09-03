# Float-vs-Fixed BER Campaign — findings log

Goal: drive the deployed two-Jupiter link BER < 0.01% (1e-4) by comparing
capture data between the floating-point reference receiver and the bit-true
fixed-point design, fixing the fixed point where it falls short of float.
Method + phase gates: `~/.claude/plans/` campaign plan (2026-07-11); instruments
in `jupiter_240k5_byte/rtl_sim/` (`build_replay_iq.sh`, `replay_capture.sh`,
`iq_prep.py`, `wrap_byte_taps.v`, `sim_byte_taps.cpp`) and
`k5_240/hybrid_ladder_k5.m`.

## The two legs (both score vs the known TX `-B` reference, never vs each other)

- **Float**: `k5_240/decode_ref_k5.m` — ideal float Rx (RRC MF, Gardner
  `comm.SymbolSynchronizer`, 4th-power CFO [`cfomax` now ±15 kHz — the legacy
  hardwired ±5 kHz sat exactly at the quiet pair's ~4.7 kHz nominal-LO offset],
  `comm.CarrierSynchronizer`, genie global quadrant, hard Viterbi).
- **Fixed**: `rtl_sim/obj_byte_iq/Vwrap_byte` — Verilator replay of the FULL
  generated `TxRxComposite` netlist via the external-ADC port
  (`rx_input_select=1`, int16 @1.92 Msps, cadence 2). Validated **bit-exact**
  against the archive fx batch (`ab_modem_d2`: packets=44 biterr=51
  capout=04922282 nrxw=704 cfc=-4). `replay_capture.sh` adds zero-run splice
  (float-leg parity) + a rot×vphase sweep + `score_rxw_ref` verdict.

## P0.5 free discriminator (archived captures, zero board time) — 2026-07-11

| capture (live HW truth) | float BER | fixed (bit-true netlist) BER | fixed error positions |
|---|---|---|---|
| `floor_148.iq` (live 1.9e-3, CLEAN 71%) | **0** (43/43 CLEAN, EVM 20.1%) | **8.9e-3** (43/43 aligned, 392 errs) | bytes 11-12 (108/149), 21-22 (63/59), rest ZERO |
| `esrc_148_long.iq` (live ~1.35e-3) | **0** (22/22 CLEAN, EVM 21.0%) | **2.0e-3** (20/21, 41 errs) | **all 41 at bytes 21-22** (~1 bit/frame/byte — the documented live hotspot signature) |

DC-removal A/B: 8.74e-3 vs 8.90e-3 — DC ruled out. The prior floor_148 replay's
100%-PHASE confound is gone (scored vs `-B` with the sweep); the fabric
resolver handles input rotation (all 4 rotations decode identically).

**Verdict: fixed-point implementation gap CONFIRMED on identical samples; the
replay reproduces the live per-offset hotspot signature (error-position
harness-validation criterion met on archived data).**

## P3 localization — the hybrid decode ladder

Stage taps (`wrap_byte_taps.v` hierarchical assigns; AGC/RRC/symbol-sync/CFC/
carrier-sync/preamble/resolver/constellation/demod-bits/FEC-bits) + float tail
per rung (`k5_240/hybrid_ladder_k5.m`) on the floor_148 taps:

- **Every rung decodes CLEAN (43/44)** — float tail recovers the data from the
  fixed AGC output, the fixed RRC output, ... and even from the fixed chain's
  OWN recovered constellation. The whole sync chain is exonerated.
- Split-point decode: float deint+Viterbi on the **fabric demod bits** = 393
  errors, hot bytes 12(144) 11(106) 21(63) 22(59) — the exact full-fabric
  pattern; the fabric FEC bits match it 1:1. **Fabric deint+Viterbi and
  byte-pack are bit-exact vs float. The damage is entirely in the DEMOD BITS.**
- Demod forensics: 3062/98560 bits (3.1%) differ from float-slicing the same
  constellation, at 99 deterministic within-frame positions (top sites fire in
  44/44 frames); mismatch symbols are NOT near the 45°-grid boundaries
  (median min|I|,|Q| = 9384) but **100.00% lie past 59.32°**;
  replicating the netlist's exact rotate-then-slice arithmetic reproduces the
  fabric bits **0/98560 mismatched**.

## ROOT CAUSE (P3, 2026-07-11)

`s1_rtl/.../QPSK_Demodulator_Baseband.v` derotates by
`(28183, -16718)/2^15 = exp(-j·30.68°)` before axis-slicing — decision
boundaries at 59.32°+90k instead of 90k ⇒ **14.3° decision margin instead of
45°** against a constellation clustered at 45.5°±8.4° (20% EVM). At that spread,
~3% of coded bits flip deterministically by content ⇒ ~11 info-bit errors/frame
at fixed byte positions ⇒ the whole ~2–3e-3 pattern-dependent floor (and the
SSH blocker). Clean symbols still slice correctly at 14.3° margin, so every
loopback/golden gate stayed green.

**Why:** `assemble_jupiter_240k5_byte.m:185` used `for pi = 1:numel(paefix)`
(the resolver_lookback_fix gate loop — a SCRIPT, so `pi=1` persists in the
workspace). `checkhdl_gate_240k5_byte.m` runs assemble then makehdl in the SAME
session; the demod library mask `Ph = pi/4` compiled as **0.25 rad** →
derotation π/4−0.25 = 30.68°. The 27 archived pre-byte netlists all have a pure
sign-slicer (no multiply): the poison shipped WITH the resolver fix. Same
mechanism hit the carrier-sync loop-filter masks `fi(g/(2*pi),0,16,16)`:
netlist Prop gain = **307 = fi(g/2)** vs correct **98 = fi(g/(2π))** — the
deployed carrier loop runs 3.14× hotter than designed (matches the previously
unexplained BnTs 0.005→~0.0077+ observation). ROM-golden-on-air also accrues
errors under this mechanism (any content has phase-marginal symbols) —
resolving the pattern-dependence vs payload-independence contradiction.

## P4 fix (one-line root fix + three guard layers)

1. `assemble_jupiter_240k5_byte.m`: loop var `pi`→`pk`, `clear pk`, and a
   pi-integrity assert at end of assemble.
2. `checkhdl_gate_240k5_byte.m`: pi-integrity assert immediately before
   Update/checkhdl/makehdl (the compile whose workspace matters).
3. `run_full_gates_t8.sh` / `run_netlist_gates.sh`: **PI_GATE** — generated
   `QPSK_Demodulator_Baseband.v` must contain NO derotation multiply
   (`gain_mul_temp`; with Ph=π/4 the factor is 1.0 and HDL Coder elides it,
   as in every pre-byte kit) and `Loop_Filter_block.v` must not carry the
   poisoned 307 constant.

Expected after regen: fixed replay = float = 0 errors on the archived corpus;
carrier loop back at design bandwidth. Then full 6-gate suite → Vivado build →
staged deploy → HW acceptance (3×120 s `-B` windows ≤5e-5 point estimate per
direction + 15-min soak <1e-4, CLEAN ≥95%, rstcs~0) → fresh paired captures to
close the sim↔HW loop.

## Verification log

- 2026-07-11 regen with pi fix: checkhdl nErr=0; PI_GATE conditions verified on
  the fresh netlist — demod derotation multiply **elided** (pure sign-slicer),
  carrier loop-filter Prop gain **98** (= fi(g/2π), was 307).
- 2026-07-11 **corpus replay on the fixed netlist: FLOAT PARITY.**
  `floor_148`: BER **0**, 43/43 CLEAN, 0 bit errors (was 8.9e-3 / 392) — all
  8 rot×vphase hypotheses. `esrc_148_long`: BER **0**, 20/21 aligned CLEAN,
  0 bit errors (was 2.0e-3 / 41; the 1 PHASE frame is the cold-start
  acquisition frame, same as float). Sim exit criterion met: fixed = float = 0
  on every capture where float = 0.
- 2026-07-11 full 6-gate suite + PI_GATE: ALL PASS. Vivado build
  `jupiter_byte_pifix_build` → BOOT.BIN md5 `5c85af2cf62d25c6c0b4d350e2944019`
  (7203552 B); consumed IP sources verified clean; routed timing profile equals
  the working baseline (pre-existing pseudo-violations, TNS improved).
- 2026-07-11 **DEPLOYED to both boards** (staged 148→146, backups
  `/boot/BOOT.BIN.prepifix`). HW acceptance, quiet pair, 3×120 s `-B`:
  - **REVERSE 148→146 @1.90 GHz: PASS — BER 2.09e-6 / 2.03e-6 / 1.38e-6**
    (25× under the 1e-4 target; was ~2-3e-3 durable floor). GOAL MET.
  - FORWARD 146→148 @2.00 GHz: 2.1e-4 / 1.9e-4 steady (one window failed to
    acquire — watchdog thrash, rstcs +549; separate bring-up robustness item).
- 2026-07-11 **paired capture closes the loop on the forward residual**
  (`capture_paired.sh A`, Tap-A during a live 1.46e-4 window, CFO −6.3 kHz —
  inside the widened float window, would have been zeroed by the legacy 5 kHz
  gate): float = **BER 0** (219/220), bit-true fixed = **~0** (216/220 CLEAN,
  0–3 bits by hypothesis). **Fixed point is at float parity on live air; the
  forward residual is a LIVE effect, not numerics.**
- 2026-07-11 live-effect discrimination (`gain_pin_test.sh`): pinning 148's
  Rx analog gain (`spi` @ the auto-picked 34 dB) halves the forward residual
  2.2e-4 → **1.06e-4**; the per-5s trace shows the first ~30 s at **2.6-4.3e-6**
  (= reverse-grade!) then a t≈35 s onset of step/fade events (NOISY+PHASE+MISS
  climbing together, per-offset map spread randomly — the deterministic
  byte-hotspot signature is GONE). Forward is CAPABLE of target; a
  time-triggered RF-path effect (thermal drift / tracking-cal class, 148-Rx@2.00
  specific — reverse is unaffected) degrades it after warmup. → Contingency B
  stop-point: further RF-side chase is a separate mini-plan.
- 2026-07-11 240 s pinned-gain run (started warm, back-to-back): **saturates**
  at 1.4–1.6e-4 from t=30 s (does not keep ramping); warm steady-state forward
  ≈ 1.4e-4 pinned / ~2e-4 auto. The earlier cold-start 30 s at 2.6-4.3e-6
  brackets the thermal component.

## Where this leaves the goal (<1e-4 both directions)

- **Reverse 148→146: MET** (1.4–2.1e-6, 25× margin).
- **Forward 146→148: 1.4e-4 warm / 3e-6 cold** — no longer numerics-limited
  (fixed = float = 0 on live-air captures). Remaining levers are RF-side
  (Contingency B, user's call): thermal/tracking-cal investigation on the
  148-Rx / 146-Tx @2.00 GHz path, slow-loop gain re-trim (pin helps 2×),
  frequency plan (reverse's 1.90 GHz path is clean), antenna isolation,
  acquisition-robustness (one 120 s window failed to lock — watchdog thrash).

## Error-hunt campaign (loss-proof -S accounting; 2026-07-11/12)

The -S sequence-streaming census (unique seq+PRBS frame per transmission, raw
scoring before the CRC gate, every seq accounted OK/BITERR/LOST) exposed what
-B structurally could not:
- Baseline (pifix, quiet pair, gain-pinned): fwd 1.9% LOST + 0.7% BITERR
  (BER 7.5e-4 incl. burst frames); rev 0.5% LOST (2.1e-4). -B's frames_scored
  rate had silently run ~1.2% under the air rate — the same losses, unbucketed.
- **Error episodes are PERIODIC at ~1.57 s on BOTH directions** (median
  spacing 333/332 frames; fwd episodes ~4 frames, rev ~1; episode structure =
  BROAD/TAIL/MID word-runs + junk + losses).
- Ring-captured error windows (error_hunt.sh): trigger frames' IQ decodes
  PERFECTLY in float AND in bit-true fixed replay; rstcs=0 the whole run;
  rssi/cfc stable → the live corruption never touched the air samples or the
  modem numerics.
- RT+pinning (SCHED_FIFO 80, dedicated core): NO effect → host scheduling
  exonerated.
- **Disabling the ADRV9002 background tracking cals post-lock KILLED the
  periodicity**: fwd BER 1.8e-5, rev 6.5e-6 while the link lived — but
  agc/bbdc tracking are load-bearing (link died at ~32 s: DC drift on the
  high-DC Rx1 without bbdc; 146's automatic gain without agc), so the final
  fix is the minimal guilty subset (bisect in progress: rssi first).
=> ROOT CAUSE of the residual error floor + frame losses: **periodic ADRV9002
background tracking-calibration activity disturbing reception every ~1.57 s**,
NOT numerics (closed by pifix), NOT host scheduling, NOT the air channel.

## RF residual chase (Contingency B, sanctioned + executed 2026-07-11)

Driver: `exp_forward.sh` (verified-lock loop: 6 s -B probe + retry — acquisition
is stochastic, ~1/3 of arms need a re-sync; TX-side `qpsk_tun -B` must run as
the radiator or the peer transmits idle filler and everything scores PHASE).

| Lever | Result (warm, pinned, 120 s unless noted) | Verdict |
|---|---|---|
| Rx gain pin (`spi`@auto-value, post-lock) | 2.2e-4 → ~1.4e-4 median | **ADOPTED** (~2×) |
| 148-Tx park (self-interference test) | 1.51e-4 vs 1.46e-4 armed | ruled out |
| QEC/FIC/RFDC tracking cals at arm | 100% PHASE (scrambles past resolver lock); 1.75e-4 resynced | **do NOT enable** |
| LO survey 1.50–2.10 GHz (60 s each, Tx parked) | 2.00 ctrl 9.8e-5; 1.60–2.05 all 1.1–1.6e-4; 2.10 = 1.0e-2; 1.50 = 3.0e-3 | keep 2.00/1.90 |
| CFO trim (split LOs ±6.3 kHz, both polarities) | 1.39e-4 / no-lock | no benefit |
| Rx port swap (RX1B) | attr not exposed by profile | unavailable |

Forward warm scatter at the adopted config: 0.98–2.4e-4 over 9 runs (median
~1.45e-4) — environment/path-margin-limited (148 Rx1 artifact floor + link
budget; auto gain rails at 34 dB max, rssi 17–19 dB). The remaining decisive
levers are PHYSICAL: bench-check 148 Rx1 SMA/cable (the RESULTS_channels.md
recommendation), antenna gain/placement, or moving the modem to channel 2
(148's Rx2 is documented-clean — needs a BD/HDL channel remap).

**FINAL ACCEPTANCE (2026-07-11, 22 min continuous -B, verified-lock +
148 gain pin, ~276k frames/direction):**
- REVERSE 148→146 @1.90: **BER 2.094e-6** over 281.8 Mbit, CLEAN 99.4%,
  rstcs ~0 — **<0.01% GOAL MET, 48× margin** (was 2–3e-3 pre-campaign).
- FORWARD 146→148 @2.00: **BER 1.421e-4** over 278.9 Mbit, CLEAN 97.6% —
  steady 1.2–1.5e-4 in every 120 s window; software-complete,
  ~1.5 dB of physical path margin short of sustained <1e-4.
Operational discipline encoded in accept_final.sh / BRINGUP.md: radiators on
air BEFORE any lock attempt (locking on idle filler PHASE-wedges the resolver;
recovery = in-place rstCS pulse while frames flow), gain pin only post-lock.
