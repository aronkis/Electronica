# Beat displacement — RTL source hunt for the half-frame re-anchor
Read-only netlist analysis, 2026-09-01. Base: `jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/`

## The single structural fact that reframes everything: the demod marker is generated DOWNSTREAM
`Frequency_and_Time_Synchronizer.v` wires the RX chain in this order (lines 135-223):

```
dataIn -> Symbol_Synchronizer -> Coarse_Frequency_Compensator -> Carrier_Synchronizer
       -> Preamble_Detector (Correlator + Peak_Search + Timing_Adjust + delay FIFO)
       -> Phase_Ambiguity -> Packet_Controller -> startOut (the demod frame marker)
```

The **frame marker the capture measures displacement against is produced by the Preamble Detector**
(`Timing_Adjust.SyncPulse` -> `Preamble_Detector.syncPulse` -> Packet_Controller `startOut`), which sits
**downstream of every tap that has ever been scored** (sel3 postSymbolSync, sel5 postCarrierSync, sel6
demod-input). Per §45 the measurement is "data vs marker" and *cannot say which side moved*; §75 states
explicitly "**Not claimed: that the fault is at or before symbol sync.**" So a defect that moves the
*marker* would appear as an identical displacement at **every** tap when each is windowed by that common
marker — which is exactly the §72/§74 picture (same rung at sel3 AND sel5, all stages "transparent"). The
task's premise "at or upstream of symbol sync" is **not established**; a marker-origin defect fits all the
sel3/sel5 evidence and additionally explains why the stages between them add nothing.

This makes the frame-reference / peak-pick structures in the Preamble Detector — not the upstream datapath
— the prime suspects, even though they are physically downstream.

---

## RANKED candidates

### #1 — Peak_Search `timingOffset` latch onto a wrong Correlator peak → Timing_Adjust re-anchors SyncPulse
**Files:** `Peak_Search.v:132-148` (peak argmax + `timingOffset` latch `Unit_Delay_Enabled_Synchronous_out1`),
fed by `Correlator.v` (matched-filter magnitude `dataOut` = `corr`); consumed by
`Timing_Adjust.v:147-153,202,216` (`SyncPulse` fires when `timing_Reference == timingOffset`).

**What it is.** Peak_Search runs a running-max argmax over one full frame (`timing_Reference` counts
0..12332, `Peak_Search.v:83-107`). Whenever `corr > runmax && thresholdExceeded` it latches the *current
frame position* into `timingOffset` (`:136-148`). At frame end (`done`, `tref==12332`) that latched position
is the frame phase. Timing_Adjust then emits one `SyncPulse` per frame at `timing_Reference == timingOffset`.

**Mechanism for a half-frame re-anchor with data intact.** `timingOffset` is a *pointer into the frame*,
span 0..12332; **half its span = 6166 ≈ the rungs.** Critically, `timingOffset` feeds **only** the SyncPulse
equality comparator in Timing_Adjust — it never gates, delays, or addresses the data. The data path in
Timing_Adjust is a bare 1-sample `Delay4` (`:79-95`). Therefore if the argmax latches a *different*
correlation peak roughly half a frame away (a preamble-autocorrelation sidelobe, or an adjacent frame's
preamble briefly winning during the slow beat), the **only** effect is that SyncPulse — and every downstream
frame boundary — re-anchors by that offset. The data emerges bit-exact; the marker moves. Windowed against
that moved marker, all taps read "displaced by ~half a frame." When the true peak re-wins (~3 s later),
it re-anchors back. Discrete because argmax picks one discrete slot; self-healing/transient by nature.

**Score:**
| criterion | verdict |
|---|---|
| half-frame magnitude | **PARTIAL** — half-span of the 12333 pointer makes half-frame the natural scale, but *why it lands there specifically* is not from the argmax; it requires a Correlator sidelobe near half-frame (candidate #2). |
| 64-symbol quantisation | **NOT explained by this candidate alone** — must come from 64-spaced structure in the preamble matched filter (candidate #2). Not asserted. |
| data bit-exact | **STRONG** — `timingOffset` touches only the SyncPulse comparator; data path is an untouched 1-sample delay. |
| marker cadence intact | **STRONG (with a testable caveat)** — one SyncPulse per frame regardless of phase (reference still wraps mod 12333), so the per-frame-averaged 0x104 count stays 1.0000. The transition frame alone has one anomalous inter-marker interval of 12333±~6160 — a *prediction*, see witness. |
| discrete jump (not walk) | **STRONG** — argmax selects one discrete slot. |
| two-state (big/small) alternation | **WEAK** — plausibly two near-equal peaks trading dominance as the slow beat phase crosses threshold twice per cycle; not derived. |
| NOT refuted by §76 | **YES — with evidence (below).** §76 forced `timing_Reference_out1`, a *different* register, one-shot and permanently. It never perturbed the `timingOffset` latch. |

**Why §76 does not refute it (evidence, not hand-wave).** `sim_burst_force_txmark.cpp:67-68` deposits
`timing_Reference_out1 = (r+32)%12333` — the **free-running frame-reference counter**, and `:95` applies it
**once** (`if(pk==K && !forced){forced=1; apply(sel);}`), never released. Consequences that are categorically
different from candidate #1: (a) it is the wrong register — the *search-window* counter, not the peak-position
latch; (b) a one-shot +32 permanently de-phases that counter against the FIFO delay line and against the
`==12332` frame-boundary detector (`Peak_Search.v:89,109`), so the search window is misaligned every frame
thereafter and the argmax degrades → sustained corruption, no recovery (exactly §76's "0→None sustained");
(c) it cannot self-heal, whereas a Correlator-driven re-latch returns to the true peak. §76 therefore tests
"permanent free-running-counter phase slip," not "transient argmax picks a real secondary peak." The map is
injective over all offsets (`t6_score_large.py:32`, `span=max(values)+1`), so §76's "None" means the forced
data was genuinely *torn*, not cleanly shifted — confirming the reference-counter force corrupts alignment,
unlike a clean marker re-anchor which would land *in* the map at a rung.

### #2 — Correlator preamble matched-filter sidelobe structure (the CAUSE feeding #1)
**File:** `Correlator.v` (`Discrete_FIR_Filter` matched filter -> `Magnitude_Squared` -> `dataOut`=corr;
moving-sum `threshold`). This is not a separate re-anchor mechanism — it is *where the half-frame magnitude
and the 64-symbol quantisation must actually originate*. A bare argmax has no preferred offset; the observed
clustering (always half-frame **+16..+388**, never below, in ~64-symbol steps within families, §64) is a
property of the preamble's autocorrelation: secondary peaks at specific lags, 64-spaced, with the two
non-64 rungs being the I/Q-swapped episodes (§64). **This report did not inspect the FIR coefficients**
(the coeff ROM is split across `Discrete_FIR_Filter_out1_re/_im.v`); confirming a ~half-frame, 64-spaced
sidelobe there is the one cheap read that would upgrade #1's PARTIAL/NOT rows to explained. Scores as #1 on
the datapath criteria (it is the same signal chain); it is ranked #2 only because #1 names the specific
latch that re-anchors.

### #3 — Preamble delay FIFO pointer half-span jump — REFUTED TWICE (directly answers the §65 question)
**File:** `FIFO.v:132-190` (Push_Counter / Pop_Counter, both 0..12332, RAM addr; occupancy tracked
separately in `Validate_Input_Push_Pop.v`).

The task asks whether a *half-span pointer jump* survives §65's exclusion. **It does not, on two independent
grounds:**
1. **§65's witness would have caught it.** The witness (`FIFO.v:224-252`) samples `(Push−Pop) mod 12333`
   **once per frame** and read `diff=0` through **seven bursts** (image `786dce9fafc8`, `occ=12333 diff=0
   events=0`). A half-span jump would have read `diff≈6166`, held for the ~3 s (thousands of frames) of a
   burst — well within the once-per-frame sampling. §65 excluded not just "push-on-full" but *any* sustained
   pointer divergence, half-span included.
2. **The FIFO delay is structurally incapable of jumping.** In `Preamble_Detector.v:309-341` the pop strobe
   `Delay10_out1` is the push strobe `Delay8_out1` delayed by a **hard 49332-tap shift register**
   (`Delay10_reg[49331:0]`, 49332 = 4×12333 = exactly one frame at 4 samples/symbol). Occupancy is pinned at
   one frame by construction; the read pointer cannot leave the write pointer by anything but that fixed
   delay. There is no path for a pointer to wrap by half its span.

So the half-span-pointer hypothesis the task flagged is genuinely dead. (This is *why* candidate #1 moves the
suspicion to the peak-*position* latch, which the FIFO witness does not observe at all.)

### #4 — Symbol Synchronizer "Rate Handle" FIFO_block (32-deep) — explains the THIRD state, not the rungs
**Files:** `FIFO_block.v` (Push/Pop 0..31, `beatobsPush/beatobsPop`), `Interpolation_Control.v`,
`Interpolation_Filter.v`. This is the surviving §65/§66 candidate and the §73/§74 "third stable state"
(sub-symbol resample producing hard decisions matching no integer offset, present at sel3 and NOT sel5).
**But its span is 32; half-span 16 — it cannot produce a ~6160 half-frame displacement** (§66 already flagged
32≠64). It is the mechanism for the *sub-symbol third state* (a distinct episode type, §44), not for the
rungs. Scores NO on half-frame; explains the sel3-only third state that #1 does not.

### #5 — Timing_Adjust / Peak_Search free-running reference +32-class slip — REFUTED by §76
**Files:** `Peak_Search.v:97-107`, `Timing_Adjust.v:129-139`. Directly forced in §76 (ps/ta) → sustained
corruption, never a rung. Dead as the mechanism. (Note this is the register §76 tested; candidate #1 is a
*different* register in the same module.)

---

## Top candidate: the register that differs during a burst, and the witness
**Register:** `Peak_Search.timing_Reference_out1`-latched **`timingOffset`** =
`Unit_Delay_Enabled_Synchronous_out1` (`Peak_Search.v:136-148`), equivalently the winning-peak timestamp
`heldTs` = `Unit_Delay_Enabled_Synchronous1_out1` (`:203-215`). During a plain (non-beat) period `timingOffset`
sits at a steady value d0. **Prediction: during a burst `timingOffset` jumps to d0 ± ~6160 (a rung offset),
holds for ~3 s, and returns.** The winning-peak timestamp `heldTs`/`runMax` (`p1c_heldts`, `p1c_runmax`) will
show the argmax landing on a different correlation lobe (a second `runmax` peak of comparable magnitude).

**Witness that confirms or kills it:**
- **Already routed** — `timingOffset` (`tOff`), `heldTs`, `runMax` are packed by `PdTelemetry.v` (`s4=runMax`,
  `s5=heldTs`, `t_5={0,tOff}`) into `telI/telQ` → `QPSK_Rx.v:529-530` `P1cDtc` → the RX debug mux near **0x10C**.
  Whether a readable telemetry slot is selectable from a register in the *flashed* image must be confirmed
  against the 0x10C slot map (caveat: §70 found the *FIFO* witA/witB reach no register — PdTelemetry uses a
  different, more-connected path, but verify before assuming). If a slot exposes `tOff`/`heldTs`, this is a
  **register read tonight**; if not, the minimal new observation is a one-signal capture of `timingOffset`.
- **CONFIRM:** `timingOffset` steps to a rung offset in lockstep with the sel-tap displacement and recovers.
- **KILL:** `timingOffset` stays at d0 through a burst while the data displaces → the marker did not move,
  candidate #1 is wrong, and suspicion returns to a data-side mechanism at/above symbol sync.
- **Cleanest independent discriminator (resolves §45):** capture the **demod inter-marker interval** across a
  burst onset. Candidate #1 uniquely predicts a *single* anomalous interval of 12333±~6160 at the onset frame
  (and the inverse at recovery), even though the per-frame-averaged cadence (0x104) stays 1.0000. A pure
  data-side defect predicts no marker-interval anomaly at all. This distinguishes "marker moved" from "data
  moved" with existing instrumentation.

## What §65 actually excluded (explicit)
§65 excluded the **preamble delay-FIFO occupancy / push-pop pointer divergence** (incl. push-on-full), proven
by a per-frame `(Push−Pop)` witness reading 0 through seven bursts. It did **not** touch `Peak_Search`'s
`timingOffset`/`heldTs` peak-position latch or the `Correlator` peak selection — those are invisible to that
witness, and the FIFO's own delay is hard-wired (49332-tap shift reg), so the pointer cannot be the mover.
The half-span-pointer variant the task asked about does **not** survive §65. The surviving half-frame mover is
the **peak-position latch**, one module over.
