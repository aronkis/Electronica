# OVERNIGHT 2026-08-28/29 — the 120.2-s burst. READ THIS FIRST (written 06:45, operator returns 07:00)

## §0 Does the rig need your hands? **NO.**
Both boards up and healthy: 148 on probe-4 `02e8c97d6181` (v5 4k FIFO + injector v2 + decoder-output CRC
checker + TX-starvation witness), 146 on `ec414d2df8bc` (v_endh, **never flashed**), link up with the
shipped defaults, framesync 1244/s, sentinel running. **No flash was performed overnight** — every test
was register-level on the already-flashed images. One housekeeping fix at 06:30: `/dev/shm` on 148 was
100 % full (965 MB `seq_raw.log` written by the `-S` scorer during the night's ROM-loopback series),
which truncated the daemon's stats line and made the sentinel probe fail from ~06:00; cleared on both
boards, link unaffected throughout (fsync 1244/s). See §6 for two things that need your decision.

## §1 What the burst is
The already-known **"119.75-s beat"** (08-19…08-22 campaign), re-found today from the other end. On
silicon it is a **coherent one-symbol sequence shift** between the data path and the frame marker inside
the modem RX: value-perfect coded bits at a shifted position (ILA-confirmed 08-20). Effect: ~3–7 s of
≈50 bit errors per frame every **120.2 s**, phase-locked to the arm (first at ~34–45 s), two deterministic
species (**215,285** and **293,433** BIST errors), framesync intact, zero carrier resets.
**Where it is NOT**: host, DMA, TX byte plane, RF, ADRV9002 tracking cals, image lineage, board.
Excluded by measurement today — no-daemon loopback, ROM/BIST source loopback, lean image, 146, cals off.
**Candidate trigger (netlist)**: the `Preamble_Detector` one-frame delay FIFO runs **exactly full**
(occupancy 12,333 = the FULL constant — now confirmed in sim, `occ=12333` every frame), so any one-symbol
excursion desynchronises its push/pop address counters, and the data path is thereafter one symbol out
against the marker path.

## §2 Proven vs inferred
**Proven (measurement, this session):**
- Burst is deterministic to the bit and independent of: host+DMA (no-daemon ROM loopback: 215,285 @34.2 s),
  image lineage (clean 08-13 lean image: 215,285 @34.3 s), board (146: 215,386 @36.1 s), tracking cals
  (all off: 215,285 @33.6 s), timing/carrier loop integral gains (5 settings: identical counts),
  RX -M and RXQ mode, and TX source (fabric ROM/BIST shows it).
- **`fixctl` (0x208) is INERT against the beat on the shipped lineage.** Four orderings/bit-splits
  (single-tap→3 = the exact 08-21 idiom, 3-before-reset, =1, =2): all give 215,285 @34.2 s and
  293,336 @156 s. On air with fixctl=3: checker windows 10.5 / 6.2 / 13.6 % — indistinguishable from
  legacy. The 08-21 "zero errors through six slots" was on BEATFIX **v1** `198ade9f234a`; on the v3
  lineage it had only ever been "verified by effect" (H-11), never by BIST slots. **The ~3 pp burst
  component is live on everything we have flashed.**
- In the netlist: forcing the delay-FIFO **push** counter +1 → **42 errors/frame**, forcing **pop** +1 →
  ≈56 errors/frame, both persistent, framesync intact, rstcs=0 — the hardware's per-frame magnitude
  (≈50) and character. Forcing only the **occupancy** counter (occ→12,334) → **zero errors**.
**Inferred (not yet proven):** that the silicon's excursion is *caused* by a push-on-full drop (rather
than by something else that desynchronises the same counters); and that the timing-NCO limit cycle is what
supplies one excursion per 120.2 s (no counter/scheduler with that period was found in the netlist).

## §3 What the silicon evidence says (and the one gap)
The pre-registered witness (`DELAYFIFO_WITNESS_PREREG.md`, written *before* the A/B, as you asked) needs
`PdTelemetry` decoded from the debug-IQ stream. **The data is captured**: `r3cap/witness1_20260828_215332/`
— 4 M-sample snippets at T0+20 s (baseline), t31 (**burst onset inside the capture**: BIST 1,641→69,593),
t32 (mid-burst, 124 k→216,925), t33…t38 (post-burst). The decoder was not finished (both sim agents died
at ~22:30 on the Fable-5 usage limit, which also killed the E5-patch A/B before it reached its injection
frame). **Decoding those five files is the single highest-value next step and needs no rig time.**
Predictions on record: `fifoEnt` steady at 12,333; a push-on-full/`vPop` anomaly at onset; `tOff` jumping
and returning at burst end. Falsifiers on record: `fifoEnt` ≠ 12,333 steady, or no anomaly at onset, kills
the FIFO-drop trigger.

## §4 Fix status
- **Trigger removal (delay-FIFO slack)** is the only live candidate: RAM is 16,384 words; FULL at
  12,333+N with pop-before-push priority. Sim support so far: occupancy-only perturbation is harmless,
  push/pop desync is fatal — consistent, but the slack fix itself has **not** been A/B'd yet (agents died).
- **Damage masking (`fixctl`) is dead on this lineage** — measured, four ways.
- **E5 `Peak_Search` window patch** (`s1_rtl_e5fix`, peak-anchored search window) is written and builds;
  its A/B never reached the injection frame. Note the sim persistence **mismatch** to state plainly: on
  silicon the burst self-heals after 3–7 s; in sim the forced desync persists to the end of the run
  (326 frames). Something re-anchors on hardware that the forced-sim does not model — so the sim
  reproduces the *magnitude and character*, not yet the *recovery*.
- **No build was started.** Sequencing you set (sim A/B → hardware witness → build) is intact.

## §5 Defects A and B (unchanged, still separate)
- **A — TX byte-in plane**: matrix complete; arrival-only (content irrelevant); netlist vulnerability real
  (16-word `ByteWordBuffer`, threshold 2000–2250 clk ≈ 18 µs) but **does not occur on silicon** (input
  never starves; probe-4 witness); true no-RF floor **0.24 %**. PARKED, no build.
- **B — RXQ=0-only 5.9 %**: host rate deficit under reset-per-transfer (FIFO full, 200/200 samples
  tready=0; absent at −M32). PARKED, moot under the RXQ=1 default. Not absorbed into the burst work.

## §6 Decisions / things for you
1. **Model limit**: both sim agents died on the Fable-5 usage limit at ~22:30, which is why stages 3–4 are
   incomplete. Session is now on Opus 5.
2. **Sentinel bug (dead safety net)**: in `~/modem-status/delivery_sentinel.sh` the post-reboot recovery
   path can never fire — `[ -n "$r" ] && PF=0` tests a *stale* `r` from an earlier successful cycle, so
   the failed-probe counter resets every loop. Tonight it logged "probe failed" 6× in 30 min and never
   recovered (harmless here — the link was fine, tmpfs was full). One-line fix (`r=""` at loop top); I did
   **not** change it, because making that path live changes automation behaviour while you are working.
3. **Serial console**: what to attach and the logger units are written up in `SERIAL_CONSOLE_SETUP.md`.
4. **Flash cycle**: measured budget + two-tier proposal in `FLASH_CYCLE_BUDGET.md`; per-stage timestamps,
   the quick tier (`TIER=quick`) and an md5-verified restore-point skip are now in the rail. Full rails
   remain the default and nothing quotable uses quick.
