# OVERNIGHT 2026-08-29/30 — READ THIS FIRST (written 00:30, operator back 09:00)

## §0 Does the rig need your hands? **NO.**
148 is on the new witness image `786dce9fafc8` (full rails, health gate pass 1, WNS +0.071 ns); 146 untouched;
rollback `02e8c97d6181` banked on-board and in `boot_known_good/`. One flash, no retry, no rollback needed.
The chain finishes with a bring-up restore and releases the rig; if anything failed after this was written it
is in §6.

## §1 Headline: the delay-FIFO hypothesis is **KILLED on silicon**
A full burst (194,049 bit errors) fired at t=33.5 s with the witness completely flat:
`occ=12333 diff=0 events=0 max=0 push_on_full=0` — occupancy exactly full, push/pop addresses in perfect
step, no push-on-full, no displacement event. Scored against the pre-registration as written:
**P1 FAILED** (0 events, not 2) · **P2 FAILED** (difference constant 0, no ±1 step) · **P3 precondition never
arose**. The witness is trustworthy for this call: the same counters read events=2/max=1 on a forced
displacement in the pre-build gates and 0 on healthy traffic.
**Therefore: the Preamble_Detector delay-FIFO drop is not the beat trigger, and the slack fix is not
justified.** The sim reproduction remains an exact analogue of the hardware signature but is not what the
silicon does. This is the FIFO-depth lesson repeated — and this time caught by a pre-registered witness
*before* any PER number was credited.

## §1b Confirmed across five bursts and both arms (added 00:45)
Arm A (`fixctl`=0) bursts at **33.5 s (194,049) / 153.4 s (196,306) / 273.3 s (116,151)** — exactly 120 s
apart — witness flat through every one. Arm B (`fixctl`=8, the slack arm) bursts at **33.6 s (206,409)**,
same phase, same magnitude, witness flat. The slack arm is indistinguishable from legacy, which is the
predicted outcome once P3 failed: it gates an event that never occurs. No sampling accident, no arm
difference, no ambiguity.

## §1c Air A/B, both arms off the one image (added 01:10)
Decoder-output checker, 60-s windows, `bad-magic / frames`:
| window | legacy `fixctl`=0 | slack `fixctl`=8 |
|---|---|---|
| burst-containing | 10.64 %, 12.32 % | 10.61 % |
| burst-free | 6.62 % | 6.21 %, 5.86 % |
Window for window the two arms are indistinguishable, and every window's fabric total
(`crc_fail`+`magic_bad`) tracks the host's `crc_drop` to within 0.5 pp as it always has. **The slack fix
changes nothing on air, which is the required consequence of P3 failing.** The burst-free windows
(5.86–6.62 %) are the steady comb; the burst-containing ones (10.6–12.3 %) are comb + beat duty.

## §2 What is proven / reproduced / inferred
**Proven on silicon (this session):** the beat is not a delay-FIFO displacement and not a push-on-full drop;
the FIFO runs exactly full (occ=12,333) at all times including through a burst; `fixctl` is inert against the
beat in all four orderings AND in the model; the beat is independent of host, DMA, TX byte plane, RF,
tracking cals, image lineage, board, loop gains and RX mode.
**Reproduced in sim (analogue only):** a one-symbol push/pop address displacement gives persistent ~42–56
err/frame, framesync intact, no carrier reset, and recovers within two frames of the compensating event.
**Inferred (unchanged, untested):** what actually displaces the coded-bit sequence relative to the frame
marker every 120.2 s. The 08-20 ILA (value-perfect bits at a shifted sequence position at/before the FEC
input) still stands, so the shift is produced **downstream of the preamble delay FIFO**.

## §2b Decomposition of the remaining forward loss (operator item 4) — from tonight's data
**The beat and the comb are different phenomena with different homes, and the loopback/air contrast proves it:**
- **In FPGA-internal loopback (no RF, no far TX): the steady comb does not exist.** Baseline BIST error rate
  between bursts is ~561 per 10 s over ~13,560 frames = **0.04 errors per frame** — essentially clean. The only
  loss in loopback is the beat.
- **On air the steady comb is ~6 %** of frames (checker windows on 08-28/29: 6.18 / 6.19 / 6.28 % in
  burst-free minutes) and is **framing, not bit errors**: `magic_bad` (garbage header) 6–10 % versus
  `crc_fail` (header parses, CRC wrong) 0.3–0.8 %. It is measured **at the decoder output pins**, so it is
  produced at or before the decoder — not in the byte plane, DMA or host.
- **Arithmetic of a burst-containing air window:** baseline 6 % for ~92 % of a 60-s window plus near-total
  loss for the ~5 s of a burst gives 0.92·6 + 0.08·100 ≈ 13.8 %, which is what a burst-containing window
  actually reads (13.61 %); a burst-free window reads 6.18 %. So the split is **≈6 pp steady comb + ≈4 pp
  beat duty**, and removing the beat entirely takes forward from ~10 % to ~6 %.
**Labels:** loopback-vs-air contrast — *proven on silicon tonight*. Comb is framing not bit errors — *proven
on silicon* (checker, 08-28/29). Comb requires RF or the far transmitter — *proven by absence in loopback*;
which of the two is *not yet determined* (146's TX and the RF path have never been separated for the comb).

## §3 Defects A and B — parked and distinct, not absorbed
- **A — TX byte-in plane:** arrival-only in the netlist, does not occur on silicon (input never starves);
  no-RF floor 0.24 %. PARKED, no build.
- **B — RXQ=0-only 5.9 %:** host rate deficit under reset-per-transfer (FIFO full, absent at −M32).
  PARKED, moot under the RXQ=1 default. **Untouched by tonight's work.**

## §4 The five witness designs (each veto is a measured fact, not a false start)
v1 count changes of (push−pop) → 12,336 changes in 2 frames: the difference toggles every symbol.
v2 occupancy == difference → saturated on a clean run: the two are on different pipeline stages.
v3 same, "settled" qualifier → 12,335: settled is true both before and after each pop.
v4 range test (diff ≥ 2) → fired on a clean run: the initial FILL sweeps 0…12,332.
v5 own frame strobe, per-frame sample, skip the fill → **PASS** (0 on healthy, 2 on the forced displacement).
Two scoring bugs of mine also surfaced and were fixed (an `awk -F,` on space-separated data; a filename-slice
key collision that printed "missing data" on a run that had actually passed).

## §5 Next search space (NOT started — question for you in §6)
Downstream of the delay FIFO, consistent with the 08-20 ILA: (a) Rate_Handle / serializer phase — the
Model-6 class the earlier campaign flagged; (b) the demodulator start/valid marker path (`legacyStart` into
BfContract); (c) deinterleaver input alignment. Each needs its own witness; none is tested.

## §6 Decisions for you
1. **Which of §5 (a)/(b)/(c) do you want witnessed first?** Each is one more instrumented build on the same
   pattern (~1 h build now that the injection path is proven, one flash). I have not picked one.
2. The witness image can stay on 148 indefinitely (`fixctl`=0 is behaviour-identical to probe-4) or be rolled
   back to `02e8c97d6181` — your call; I left it in place.
3. Forward budget is unchanged tonight: ~6 % steady comb + ~3 % periodic beat. Nothing was fixed, one wrong
   fix was prevented.
