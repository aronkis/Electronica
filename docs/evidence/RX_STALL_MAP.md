> Evidence note, moved verbatim from `jupiter_240k5_byte/RX_STALL_MAP.md` on 2026-09-09.

# RX_STALL_MAP — everything that can gate/mute packet delivery (f1536, sps=4)

Scope: map of the RX delivery-gating chain for the sporadic 5–100-frame packet-delivery
freeze (0x104 frozen, rstcs=0, input clean, SSI cadence perfect, cold bit-true replay
decodes clean). Evidence base = the freshly generated f1536 netlist
`s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (created 2026-08-01, model 11.324 — frame
constants confirm f1536: Peak window wrap 12332, End span 12320, deint pairs 12296,
RxAlign span 12292) plus the T8.x campaign docs.

Key structural fact first: **0x104 (`packets_out`) increments only on a `valid && start`
beat of the DECODED bit rail** (`MATLAB_Function.v:186-207`, instanced by
`Capture_Data_Bits.v:76-85`; `Receiver.v:376-386`). That rail is
`FEC_Decoder_Wrapper.startOut` = `RxAlign.startOut`, the same nets the ByteSerializer
taps. Therefore a frozen 0x104 means **the per-frame `start` pulses stopped upstream of
the byte plane** — the WPP framer, byte FIFO, DMA and host are all DOWNSTREAM of the
frozen counter and are exonerated as causes of this particular freeze (consistent with
the 2026-07-15 byte-plane exoneration, `docs/evidence/ERROR_TAXONOMY.md:283-299`).

---

## 1. Delivery-gating diagram (symbol stream → byte delivery)

```
ADC/SSI → AGC → RRC(decim) →
SYMBOL SYNCHRONIZER (Symbol_Synchronizer.v)
  Gardner_TED → Loop_Filter_block1 (P+I, IntegClamp ±0.06: Loop_Filter_block1.v:329)
  → Interpolation_Control (Rice mod-1 ctr; T8.4 anti-wedge Delta clamp ±255/1024:
    Interpolation_Control.v:126-141) → Underflow strobe → Farrow interp
  → Rate_Handle (Rate_Handle.v): small elastic FIFO_block, push=strobe,
    pop=every 4th input-valid → SYMBOL VALID rail (this is where TX/RX clock
    drift becomes ±1 valid-cadence slips)
→ CFC (CFO_step_change_detector → rstCS pulse + 0x150 counter — did NOT fire)
→ CARRIER SYNCHRONIZER (PLL; library DDS/NCO with own internal valid pipe)
→ PREAMBLE DETECTOR (Preamble_Detector.v)
  ├─ Correlator (13-sym Barker FIR; adaptive threshold = moving-sum energy,
  │   Correlator.v:114-137, floor via ThresholdLimiter)
  ├─ thresholdExceeded = corr > threshold   (Preamble_Detector.v:163-165)
  ├─ PEAK SEARCH (Peak_Search.v)  — per-window argmax, window = 12333 valids
  │   state: tref ctr 0..12332 (:83-107), runningMax (:113-130, cleared at
  │   window end), timingOffset hold (:136-148), success latch (:152-171)
  │   outputs once per window: done (tref==12332&valid), success, timingOffset
  ├─ data FIFO (FIFO.v, 16384-deep RAM) : push=every valid; pop=push delayed
  │   EXACTLY 49332 enb cycles (Delay10_reg, Preamble_Detector.v:301-314)
  │   ≈ one frame of look-back so the whole window is searched before release
  └─ TIMING ADJUST (Timing_Adjust.v) — THE frame gatekeeper
      state: own tref ctr 0..12332 (:111-139, lock-step with Peak ctr),
      accepted-offset hold (:141-151; enable=timingOffsetValid — the
      timing_adjust_fix_overlay re-target fix IS in this netlist),
      armed flag (:183-200; set on timingOffsetValid, cleared only after fire)
      SyncPulse := armed && valid && (tref == acceptedOffset)  (:202,216)
→ PHASE AMBIGUITY EST/CORR (pure pipeline; syncPulse passthrough delay,
  Phase_Ambiguity_Estimation_and_Correction.v:250,320,400; resolver_lookback_fix)
→ PACKET CONTROLLER (Packet_Controller.v)
  ├─ start gate SR (MATLAB_Function_block.v:77-86): set by syncPulse, emits ONE
  │   valid-beat start, self-clears. NO syncPulse ⇒ NO start ⇒ frame muted.
  ├─ End_Generator (End_Generator.v:54-91): free-running mod-12320 valid
  │   counter, re-phased (rst) by each start; endOut = count==12319
  └─ sample_discard_controller (sample_discard_controller.v:120-141):
      active SR: set on startIn, cleared on endIn; validOut=validIn&&active.
      active==0 ⇒ **all downstream valid muted**
→ QPSK demod (start/end/valid passthrough)
→ FEC DECODER WRAPPER (FEC_Decoder_Wrapper.v)
  ├─ RxDeint (RxDeint.v): rdGate set by startIn (:279-294), pcnt 0..12296
  │   (:297-322) ⇒ deintValid pairs; vitReset at pcnt==0 (:985-1012);
  │   ping-pong bank RAMs (rdBank :432-462) — reads PREVIOUS frame's bank
  ├─ VitGate → Viterbi (K5, TB25) — free-running, gated by deintValid
  └─ RxAlign (RxAlign.v:132-172): on frameStart&deintValid: o=0, started=1,
      skip=skipCount+41; then emits 12292 bits with startOut at o==0.
      NO frameStart ⇒ o stays saturated at 12292 ⇒ validOut/startOut SILENT.
→ recBit/recBitValid/recStart rail
  ├─ Capture_Data_Bits → 0x104 packets_out (start&valid), 0x108 bit_errors
  └─ ByteSerializer (qpskByteSerializer.m; WPP=191 for f1536,
      frame_config_k5.m:67,111-125) → SerWord/Tog/Last/First
      → ByteRxFifo (byte_rxfifo_overlay.m: 64-deep drop-oldest, ovf@0x1B0,
        f1536 SOF-guard rdyRun≥6) → byte_rx AXIS → S2MM DMA → host
```

**Single funnel**: every delivery-mute path collapses onto one signal —
`Timing_Adjust.SyncPulse`. If it fires, a full 12320-symbol span is delivered and
0x104 increments once; if it does not fire in a frame, that frame is silently
absent (no partial delivery, no error strobe, nothing else changes).

---

## 2. Per-mechanism state / mute / recovery table

| # | Mechanism | Live state held | What mutes delivery | Re-arm / recovery | Timescale, fit vs 5–100 var. frames |
|---|---|---|---|---|---|
| A | **Peak Search no-success window** | tref ctr, runningMax, success latch | `success`=0 for a whole 12333-valid window (corr never > adaptive threshold) ⇒ no `done&success` ⇒ Timing Adjust never armed ⇒ no SyncPulse | next window in which any corr sample crosses threshold; success latch auto-clears each window | 1 frame per no-peak window; **N consecutive bad windows = N-frame stall — the only mechanism that natively spans 5–100 variably**. Needs peak suppression (timing/phase displacement), not absence of signal |
| B | **Timing Adjust arm/fire equality miss** | armed flag, acceptedOffset, tref | armed set but `tref==offset` already passed this wrap (report latched at tref≈0-2 with offset just below/behind); fire waits a full wrap; a re-latch that again lands "just passed" repeats the miss | counter sweeps all 12333 values per frame → fires within ≤1 frame of a stable target | 1–2 frames per event; **chains to N frames only while the reported offset keeps MOVING every frame** (i.e. during a displacement burst) — amplifier of A/C, not standalone. NB: the stale-offset variant was already named THE Class-1 mechanism (P1B census, `timing_adjust_fix_overlay.m:4-11`) and the re-target fix is in this netlist (Timing_Adjust.v:147 enable=timingOffsetValid) |
| C | **CS-hop symbol-strobe eater (library DDS/NCO valid pipe)** | NCO internal valid pipeline (uninstrumentable) | eats EXACTLY 2 symbol strobes per device tick strictly inside CFC→CS (mode-2/mode-5 bisect, `ERROR_TAXONOMY.md:243-271`); displaces the Barker peak −2 counts in the Peak/TA counters ⇒ triggers A/B re-hunt ("2-symbol slip → 10–14-frame Barker re-hunt") | none needed in the eater itself (it self-restores); the re-hunt is the recovery | trigger, not the mute: Poisson (device tick ~1/1.5 s ≈ obs. 1/2–3 s), absent in fabric loopback (disturbance enters via clock/SSI domain), rstcs stays 0 (exonerated over ~800 ticks). **Excellent trigger fit** |
| D | **Symbol-timing loop excursion (Gardner/LF/IC)** | LF integrator (clamped ±0.06), IC countReg/muReg (Delta clamped ±255/1024) | strobe cadence slows/warps → eye closes → corr peak drops → A | loop re-convergence (loop-BW-limited, variable) | tens of frames, variable — good shape; BUT T8.5/T8.6 shadows proved LF+IC state NEVER diverges through ~300 episodes (`ERROR_TAXONOMY.md:189-194`), and hardening removed the permanent wedge (tb_timing_wedge WEDGED→RECOVERED) without changing episode severity — so the loop is a victim of input wobble (T8.7 #3: 25–40 ms bursts whip mu ±0.3–0.4 sym), not corrupt |
| E | **Preamble-detector data FIFO walk** (FIFO.v + Validate_Input_Push_Pop.v:121-139) | push/pop ctrs mod 12333, occupancy | pop-on-empty is suppressed (silent sample loss ⇒ 1-symbol framing shift); push-on-full dropped | none — occupancy is structurally pinned (pop = push delayed fixed 49332 enb cycles; occupancy = #valids in the last 49332 cycles ≈ 12333 of 16384) | can't wander to empty/full in normal operation; only reachable via state corruption of a counter — would cause a persistent shift (self-heals via A-recovery). Poor primary fit, plausible one-shot victim |
| F | **End_Generator span** (End_Generator.v) | mod-12320 valid ctr | none by itself — free-runs; spurious endOut during mute is ignored (sample_discard inactive ⇒ endOutReg_next=0, sample_discard_controller.v:138-140) | re-phased by every start | fixed span (12320 = dataBitsPerPacket/2); worst case truncates ONE frame after re-lock. No multi-frame mute possible |
| G | **RxDeint/RxAlign/Viterbi framing** | rdGate, pcnt, rdBank ping-pong, RxAlign o/started/skip | all counters idle without startIn/deintValid; `started` persists but `o` saturates at 12292 ⇒ silent | first fresh frameStart fully re-initializes (o=0, skip=sc+41) | pure follower of SyncPulse — recovery in exactly 1 frame after sync returns. rdBank parity flip on a missed/extra start ⇒ ≤1 garbage frame (bank holds stale data), self-heals next start |
| H | **WPP=191 ByteSerializer** (qpskByteSerializer.m:10-23) | acc/bitIdx/wordCnt | NEVER stalls the receiver (drop-on-!ready by design); a start mid-word discards the partial word — self-heals at every packet boundary | every recStart resets bit+word counters | downstream of 0x104 ⇒ **cannot cause this freeze**. A mis-span only shifts host framing for ≤1 frame |
| I | **ByteRxFifo** (byte_rxfifo_overlay.m:12-16,127-151) | 64×{word,flags} ring, wr/rd, ovfCnt, rdyRun | full ⇒ drop-OLDEST + count at 0x1B0 (never blocks); f1536 SOF-guard only delays presentation ≤6 cycles per ready-rise | continuous | downstream of 0x104 ⇒ not this freeze; ovf==0 requirement separately monitored |
| J | **CFO-step detector / rstCS** (CFO_step_change_detector.v → Carrier_Synchronizer manualRst/internalRst) | detector history, 0x150 counter | rstCS resets the carrier PLL (re-pull transient could suppress corr peaks) | PLL re-lock | **measured NOT firing** (0x150 stable through stalls, and 1/session across ~800 ticks) — exonerated as trigger; important negative: whatever mutes delivery does so WITHOUT tripping the CFO-step path |

---

## 3. Drift-boundary analysis (10 ppm TX/RX clock offset)

- The Symbol Synchronizer converts sample-clock offset into valid-cadence slips: the
  recovered-symbol strobe rate tracks the TX clock, so the Barker peak position in the
  Peak/TA valid-counters moves by `12333 × 4 × 1e-5 ≈ 0.49 samples/frame ≈ 0.123
  symbol counts/frame` → `timingOffset` steps ±1 every ~8 frames. Each step is benign:
  Peak Search re-measures per window and (post-TA-fix) Timing Adjust re-targets on
  every report.
- **Wrap boundary (offset 12332 → 0)**: crossed once per `12333/0.123 ≈ 100k frames ≈
  80 s` per direction. At the crossing, (i) a window can contain two threshold-crossing
  peaks or a split peak (runningMax picks either; window edge cuts the correlation
  plateau), and (ii) the TA arm happens at tref≈1-2 (2 pipeline beats after done at
  12332, Preamble_Detector.v:183-207), so an accepted offset in {0,1,2} can already be
  "passed" when armed ⇒ the fire waits a full wrap ⇒ 1 frame late/skipped. So the
  boundary produces occasional **1–2-frame** hiccups every ~80 s — real, but the wrong
  rate (observed ~1/2–3 s) and the wrong duration (observed 5–100) to be the primary.
- The primary drift-related hazard is therefore not the slow wrap but **step
  displacements** of the peak position (2-strobe eats, timing-wobble bursts): each
  displacement forces mechanism A/B to re-acquire, and the stall length = how long the
  reported peak keeps moving + the 1-frame arm/fire quantization. A 25–40 ms wobble
  burst at 1245 fps = **31–50 frames**, squarely inside the observed 5–100 band;
  single clean 2-strobe eats gave the historical 10–14-frame re-hunts.

---

## 4. Ranked stall candidates

1. **Frame-sync re-acquisition after a peak-position displacement — Peak Search
   `success` starvation + Timing Adjust arm/fire quantization (A+B), triggered by the
   CS-hop 2-strobe eater or an input timing-wobble burst (C/D).**
   Mechanism: a displacement moves the Barker peak within (or across the edge of) the
   12333-count window; while the displacement persists, either the window records no
   threshold crossing (success=0 ⇒ TA never armed) or the accepted offset lands behind
   the free-running tref (fire missed for a full wrap). Every such frame is silently
   undelivered — exactly a frozen 0x104 with **no rstcs, clean samples, perfect valid
   cadence**. Recovery is a search process ⇒ variable 5–100 frames. Cold replay decodes
   clean because the stall needs the LIVE counter/arm phase relationship (tref vs
   offset vs FIFO look-back), which a cold start regenerates benignly.
2. **The CS library DDS/NCO valid-pipeline upset (the "2-strobe eater") as the Poisson
   trigger.** Named by the mode-2/mode-5 bisect: exactly 2 symbol strobes vanish inside
   the CFC→CS hop per device tick; samples stay phase-coherent; every register shadow
   (LF, IC, carrier LF, path canaries) stays zero-divergent; rstcs silent. It cannot
   mute delivery by itself (2 strobes ≈ 130 ns of symbol flow) — its damage is entirely
   the displacement it hands to candidate 1. Absent in fabric loopback because the
   disturbance enters via the SSI/clock domain, not the sample values.
3. **Symbol-timing-loop excursion within the hardened clamps (D).** The T8.4/T8.7 work
   proved the loop's registers are never corrupted and the permanent wedge is
   impossible post-hardening, but a live mu/strobe-cadence excursion (input timing
   wobble, ±0.3–0.4 symbol, 25–40 ms) closes the eye and can hold `success`=0 for the
   burst duration — same downstream signature as candidate 1 and matching the long
   (30–100-frame) tail of the distribution. Ranked third because sim reproduces the mu
   whip yet decodes through it (≤1 lost frame per 485), so it likely needs candidate
   1's arm/counter state to become a multi-frame outage.

Poor fits (for the record): End_Generator (fixed span, no lock state), WPP=191
serializer and ByteRxFifo (downstream of the frozen counter; both self-healing),
preamble-FIFO occupancy (structurally pinned), rstCS path (measured silent), host/DMA
plane (exonerated 2026-07-15).

---

## 5. Canary/telemetry cross-reference (what is already known, and what to read next time)

- **T8.5** (`canary_instrumentation_overlay.m`, regs 0x170–0x188, `qpsk_hw.h:96-106`):
  shadow timing loop-filter — pdiv/idiv **flat zero through ~300 episodes** ⇒
  loop-filter registers not corrupted; random-register-corruption model rejected.
- **T8.6/T8.6.3** (`canary2_overlay.m`, 0x18C–0x1A0, `qpsk_hw.h:108-115`): IC shadow
  (compensated), carrier-LF shadow, 4 graduated critical-path canaries — **all zero**
  during episodes ⇒ no margin-erosion upsets in monitored state.
- **T8.7** state-injected replay (`sim_byte_inject.cpp` protocol): input timing-wobble
  bursts real and sim-reproducible; live decode collapse remains live-only; corruption
  cornered in the un-monitored FTS decision registers / NCO valid pipe.
- **canary4** (`canary4_validcensus_overlay.m`, 0x1A0/0x1A4/0x1A8): CS-hop valid
  census — the instrument that names the 2-strobe eater beat-exactly.
- **FEC counter ladder 0x120–0x134** (`fec_counters_overlay.m:15-31`): during a live
  stall, the first frozen counter localizes the mute: 0x124 `cnt_frame_start` frozen
  while 0x120 `cnt_descr_in` also frozen ⇒ FTS validOut muted (sample_discard
  inactive ⇒ SyncPulse missing) — the predicted signature of candidate 1.
- **FRAMESTAT** (`framestat_overlay.m` / `FRAMESTAT_NOTES.md`): per-frame
  `corr_strength` (runningMax MSB) + `sync_low_margin` + `frame_seq` (=0x104 low byte)
  is precisely the discriminator between "peak vanished" (corr_strength collapses
  during stall frames ⇒ candidate 1 via success-starvation / candidate 3) and "peak
  present but fire missed" (corr_strength healthy, frame_seq frozen ⇒ candidate 1 via
  the arm/equality miss). Ship it and read it during a stall.

---

## 6. Injection hooks available (`rtl_sim/sim_byte_inject.cpp`)

Verilated netlist replay (`wrap_byte_taps`), built `--public-flat-rw`; register map
auto-generated by `gen_inject_map.py` over the flat root, default prefixes =
`u_Automatic_Gain_Control, u_Symbol_Synchronizer, u_Coarse_Frequency_Compensator,
u_Carrier_Synchronizer, u_Preamble_Detector, u_Phase_Ambiguity_Estimation_and_Correction,
u_Packet_Controller` (shadow/canary instances excluded). Hooks:

- `--inject FILE SAMPLE` — one-shot force of any "name hexvalue" list into the model at
  an enb-aligned input-sample index. Reaches ALL the candidate state: Peak_Search
  `timing_Reference_out1` / `Unit_Delay_Enabled_Resettable_Synchronous_out1`
  (runningMax) / success latch; Timing_Adjust `timing_Reference_out1`,
  `Unit_Delay_Enabled_Synchronous3_out1` (accepted offset), `State_Register_out1`
  (armed); preamble FIFO Push/Pop counters; IC countReg/muReg; LF integrator; AGC;
  Packet Controller start SR.
- `--dump FILE SAMPLE` — full INJ_TABLE state dump (repeatable) for S(T1) compares.
- `--eatvalid SAMPLE N` — suppress N Carrier Synchronizer output valid strobes
  (forces `u_Carrier_Synchronizer__DOT__Delay7_out1`→0 at strobes) — a faithful
  replica of the 2-strobe eater, at any chosen frame phase.
- `--stallready S E` — deassert `byte_rx_ready` over a sample window (byte-plane
  stall experiments; not relevant to the 0x104 freeze but kept for completeness).
- `--trace SUBSET OUT IV [--tracewin S E]` — periodic register trace of any INJ_TABLE
  subset (e.g. tref/offset/armed/success per beat).
- `iq_perturb.py` — sample-domain stimulus: `--cfo`, `--phase`, `--gain`, `--drop L
  [--insert]` (splice/delete samples = clock-slip emulation at the input).

### The discriminating experiment
Replay a clean capture and sweep `--eatvalid F N` (N=1..4) versus the frame phase of F
(mid-window, near offset≈tref, near the 12332→0 wrap), tracing
`Timing_Adjust.{timing_Reference,Unit_Delay_Enabled_Synchronous3,State_Register}` +
`Peak_Search.{runmax,success}` + startOut census:
- stall length ≈ N-independent, multi-frame, maximized near the wrap / when the new
  offset lands just behind tref ⇒ **candidate 1** (arm/equality re-acquisition);
- any 2-eat anywhere reproduces a 10+-frame 0x104 freeze ⇒ **candidate 2 suffices**;
- eats never stall >2 frames but `--inject` of a mu/LF excursion (or `iq_perturb
  --drop/--insert` clock-slip bursts of 25–40 ms) reproduces 30–100-frame
  success-starvation ⇒ **candidate 3**.
Complementary silicon read: FRAMESTAT corr_strength during a live stall (Section 5).
