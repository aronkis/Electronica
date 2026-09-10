> Evidence ledger, moved verbatim from `two_jup/comb/RX_WINDOW_RTL.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RX_WINDOW_RTL — is the receiver's frame detection gated by the transmitter?

**VERDICT: FREE-RUNNING.** The hypothesis "the RX frame-detect / packet controller is
gated or windowed relative to the TX frame start" is **falsified at the netlist level**.
No transmitter signal reaches any receiver control. The receiver *is* windowed, but the
window is a free-running mod-12333 epoch anchored only to global `reset`, and it is a
**winner-take-all argmax with at most one detection reported per epoch** — which is a
different and sufficient defect.

All paths below are relative to
`jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`.
Labels: **[netlist]** = read directly from the generated Verilog; **[inferred]** = reasoning
on top of it; **[silicon]/[sim]** = carried in from OVERNIGHT_20260904_SEQBIST.md and
sdd_archive/2026-09-03-seqbist/task-3b-report.md.

---

## 1. Every Transmitter → Receiver crossing inside TxRxComposite [netlist]

Exhaustive. `u_Transmitter` is instantiated at `TxRxCompo_ip_src_TxRxComposite.v:665-682`,
`u_Receiver` at `:797-873`. Comparing the two port lists, the **only** wires produced by
the transmitter that are consumed by the receiver are the two I/Q data words:

| TX output | consumed at | by |
|---|---|---|
| `Transmitter_dataOutI` | `TxRxComposite.v:738` `MUX_RxI_out1 = (rx_input_select_1==0 ? Transmitter_dataOutI : AdcStabI_out1_1)` | `u_Receiver.dataInI` (`:802`) |
| `Transmitter_dataOutQ` | `TxRxComposite.v:794` (same form) | `u_Receiver.dataInQ` (`:803`) |

Nothing else. The enumeration is closed — the transmitter's five remaining outputs
(`TxRxComposite.v:678-682`) all terminate in instrumentation or in the DAC path, never in
`u_Receiver`: `Transmitter_modOut_re/im`, `Transmitter_modValid`, `Transmitter_scramBit`,
`Transmitter_scramValid` appear **only** inside the DDRCAP selector mux
(`:2057-2058, :2072-2073, :2087, :2099, :2103`); `Transmitter_extWordPop` goes only to
`PopRT_out1` (`:630`), i.e. back to the TX-side `ByteWordBuffer`; and `Transmitter_dataOutI/Q`
additionally feed `u_REP_TxI` / `u_REP_TxQ` (`:1100-1105`, `:1170-1174`), which drive
`tx_dataOutI/Q` to the DAC, plus the `txcap` debug shifter (`:1969`) and DDRCAP sel 8
(`:2058, :2073`). **[netlist]**

Specifically:

- **`txFrameStart` never reaches the receiver.** Its complete fan-out is
  `TxRxComposite.v:1954` (a debug/telemetry counter) and `:2165`
  (`ddrcap_fec_mark_now = Transmitter_txFrameStart | ddrcap_fec_mark_latch`, the DDRCAP
  TXMARK). Both are instrumentation. It is generated at `QPSK_Tx.v:118`
  (`txFrameStart = Bit_Packetizer_dataStart`). **[netlist]**
- **`ByteSel` / `tx_data_source` is TX-only.** `ByteSel_out1 = tx_data_source != 0`
  (`TxRxComposite.v:579`) goes to exactly one place: `u_Transmitter.extBitSel`
  (`:672`), thence `Transmitter.v:137` → `Input_Data.v:138-141`. **The receiver has no
  knowledge whatsoever of the TX source select.** **[netlist]**
- **The RX valid is a hard constant in both modes** — closing the last mode-dependent
  hole: `TxRxComposite.v:531-556`,
  `IntValidConst_out1 = 1'b1`, `RxValidConst_out1 = 1'b1`,
  `MUX_RxValid_out1 = (rx_input_select==0 ? IntValidConst_out1 : RxValidConst_out1)`.
  Both arms are `1'b1`; `rx_input_select` (modem reg `0x114`) changes **only which I/Q
  pair is muxed in**, not any timing, enable, or reset. **[netlist]**
- `clk`, `reset`, `enb`, `enb_1_2_0`, `enb_1_2_1` are the common HDL-Coder clock/enable
  tree from `u_TxRxComposite_tc` (`:558-564`), shared by *every* block including the
  transmitter's own; they carry no frame information.

**Consequence [inferred, strong]:** a static TX→RX propagation delay (the RF path,
µs-scale) cannot by itself break frame detection, because the detector's decision rule
(§2) is an argmax over a free-running epoch and is therefore **phase-invariant**: shifting
the whole received stream by any constant number of samples shifts `timingOffset` by the
same constant and the pipeline realigns. The hypothesis's own predicted failure mode does
not exist in this netlist.

---

## 2. How the receiver decides a frame start [netlist]

Chain (`Frequency_and_Time_Synchronizer.v:176-275`):
`Symbol_Synchronizer` → `Coarse_Frequency_Compensator` → `Carrier_Synchronizer` →
`Preamble_Detector` → `Phase_Ambiguity_Estimation_and_Correction` → `Packet_Controller`.

### 2a. Correlator and threshold — adaptive, energy-normalised
`Preamble_Detector.v:172-185`: `Correlator` (matched to the 13-symbol/26-bit Barker
preamble) emits `dataOut` (`sfix32_En26`) and its own `threshold`;
`Relational_Operator_out1 = (corr<<2) > threshold`.
`Correlator.v:110-177`: `threshold` is `Magnitude_Squared_and_Moving_Sum.E1` — a
**63-sample running energy sum** — passed through `ThresholdLimiter.v:34-37`, which only
imposes a tiny absolute floor. **The threshold tracks received energy**, so it is
invariant to TX attenuation and to AGC gain. **[netlist]**
→ This directly explains the silicon result that **−20 dB TX attenuation changed nothing**
(P7/P8) and that CFO 0/±5 k/±20 k changed nothing (the correlator sits *after* the
carrier synchronizer, `Freq_and_Time_Sync.v:230-232`). **[inferred]**

### 2b. Peak_Search: one argmax per free-running 12333-sample epoch
`TxRxCompo_ip_src_Peak_Search.v`:

- `:79-114` — `timing_Reference` is a **count-limited counter, 0…12332**
  (`need_to_wrap = tref == 14'b11000000101100` = 12332), incremented on every
  `validIn`. **Its only reset is the global `reset` (`:105-107`).** No re-arm from any
  event, TX or RX. **This is the window, and it is free-running.** **[netlist]**
- `:116-137` — `runmax` (`Unit_Delay_Enabled_Resettable_Synchronous`) is cleared at the
  epoch boundary (`Logical_Operator_out1 = validIn & (tref==12332)`) and otherwise loaded
  with `corr` whenever `Logical_Operator4_out1 = (corr > runmax) & thresholdExceeded`.
- `:139-153` — `timingOffset` latches `tref` on that same `Logical_Operator4_out1`.
- `:155-176` — `success` is a sticky "anything crossed threshold this epoch", cleared at
  the boundary. `done = validIn & (tref==12332)` (`:118`, `:157`).

**What one "sample" is, and why the epoch equals exactly one air frame [inferred].**
`validIn` here is `Correlator_validOut`, i.e. the post-symbol-sync sample stream clocked by
`enb_1_2_0`, which is the `clk/8` tick of the HDL-Coder rate tree
(`TxRxComposite.v:558-564`). The air-frame period measured in the sim is **98,664 clocks**
**[sim, task-3b-report.md]**, and 98,664 / 8 = **12,333 exactly** — the wrap constant. That
identity is what makes the whole scheme work: with at most one detection per epoch, the
observed **1,246 f/s in digital loopback [silicon]** is only achievable if the epoch is one
frame period, not several. So the epoch is the frame period by construction, and the
12,333 − 12,320 = **13-sample guard** is all the slack the receiver has between the end of
one receive window and the start of the next epoch. (The coincidence with the 13-symbol
Barker length is suggestive but not load-bearing; the guard arithmetic stands on its own.)

So the report rule is: **within each fixed 12333-sample epoch, take the single largest
above-threshold correlation, whoever it is, and emit it once at the end of the epoch.**
There is no "true vs false" discrimination and **no capacity for a second detection in the
same epoch**. Window width = 12333; peaks "outside it" do not exist — every sample is
inside some epoch — but a peak that is *not the epoch maximum is silently discarded*.
**[netlist]**

### 2c. Timing_Adjust: the detection is applied one epoch later
`TxRxCompo_ip_src_Timing_Adjust.v` (offsets are file line numbers):

- `:114-140` — a **second** free-running 0…12332 counter (`timing_Reference`), same
  wrap constant, same reset-only anchoring.
- `:142-152` — `accoff` latches `timingOffset` on `timingOffsetValid`
  (= `Delay12_out1` = registered `done & success`, `Preamble_Detector.v:215-227`).
- `:184-200` — `State_Register` arms on `timingOffsetValid`, disarms on the pulse.
- `:202,216` — `SyncPulse` fires when `State_Register & validIn & (tref == accoff)`, i.e. at
  **the next occurrence of that phase — one full 12333 epoch after the detecting epoch.**
- `Preamble_Detector.v:107,321-334` — the data path is delayed by
  `Delay10_reg[49331:0]` = **49332 = 4 × 12333 samples**, plus a 12333-deep FIFO
  (`FIFO.v:125,160`, wrap 12332) and the 20+6 pipeline delays (`:91-106`).

**[inferred]** The design therefore assumes the arriving frame period is *exactly* 12333
samples: a detection made in epoch *N* is applied to the data emerging from a 4-epoch
delay line. It is a hard periodic assumption, not a search.

### 2d. Byte plane vs ROM path at the RX side — identical [netlist]
There is no RX-side difference at all (§1). And at the **TX** side the two paths share the
same framing engine: `Input_Data.v:138-141`
```
assign BitMux_out1 = (extBitSel_1 == 1'b0 ? Message_Generator_out_1 : FEC_Tx_Encoder_K5_encBit);
assign txData  = BitMux_out1;
assign txValid = Message_Generator_valid;          // <-- both paths
```
`start`/`stop`/`valid` all come from `u_Message_Generator` (`:89-98`) in **both** modes;
`ByteBitShifter` and `FEC_Tx_Encoder_K5` are clocked by the same `Message_Generator_start`
(`:110-133`). Frame length/period is set by `Bit_Packetizer`/`Data_Bits_FIFO`
(`Bit_Packetizer.v:128-141`, `dataStart` at `sampleCount == 26` =
`Compare_To_Constant_block1.v:33-35`; `Data_Bits_FIFO.v:103,193,302` wraps 49279 = 4×12320
and 24665 = 2×12333) and is **identical for ROM and byte plane**.

**This is the decisive filter.** Any candidate mechanism that is about *timing, epoch
phase, valid cadence, frame period or RF delay* applies equally to the ROM stream — and
the ROM stream self-receives over the air at the full 1,246 f/s **[silicon]**. All such
candidates are therefore excluded. **The only thing that differs between the two streams
is the bit pattern that reaches the modulator.**

---

## 3. The "61 symbols" relation [inferred]

`mark_demod − mark_fec = 61`, zero drift, digital loopback. This is **pipeline latency,
not gating**, and it proves nothing about TX coupling. It is the sum of the
detector/realigner delays modulo the epoch: `Delay10` 49332 = 4×12333 ≡ 0 (mod 12333),
the FIFO 12333 ≡ 0, and the residue is the fixed small pipeline (`Preamble_Detector.v:91-106`
20+6 taps, `Packet_Controller.v:66-110` 4+4 taps, `Timing_Adjust.v:79-109` 1 tap,
`Correlator` internals). Its constancy in loopback simply confirms the frame period is
exactly one epoch there.

**Would an RF delay of 2–10 µs push a preamble outside a window? No. [inferred]** Per §1
and §2b the epoch is free-running and the rule is an argmax; a constant delay merely moves
`timingOffset`. The only genuinely delay-sensitive case is a peak landing on the boundary
sample `tref == 12332`, where `Peak_Search.v:118-131` clears `runmax` and `:155-171` clears
`success` **in the same cycle as the latch**, so that frame's detection is lost — but that
is a measure-zero phase, it would apply to the ROM stream too, and it would be all-or-
nothing, not a stable 50 %.

---

## 4. Can the receive window swallow the next frame? YES — and this is the 2,400-byte delivery [netlist]

`Packet_Controller.v:113-160`:
- `u_MATLAB_Function` (`MATLAB_Function_block.v:66-92`) turns `syncPulse` into a level:
  `Reg_next = 1` on `syncPulse`, cleared on the next `valid`. → `startIn`.
- `u_End_Generator` (`End_Generator.v:107-131`) is a **counter reset by that same start**
  (`count_2 = rst ? 0 : count_1`, `rst = Logical_Operator_out1`) that counts to **12319**
  and emits `endOut`.
- `u_sample_discard_controller` (`sample_discard_controller.v:170-196`):
  `if (startIn) active = 1;` … `if (endIn) begin endOutReg_next = active; active = 0; end`.

So a frame start opens a **12320-sample window inside a 12333-sample epoch — 99.89 % duty,
13 samples of guard** (12333 − 12320 = 13 = the Barker preamble length in symbols).

**Mechanism for the missing `user` mark [inferred]:** if a *false* peak anywhere in epoch
*N* out-scores the true preamble, `Peak_Search` reports the false offset, `Timing_Adjust`
issues `SyncPulse` at that phase, `sample_discard_controller` goes `active`, and the
window runs 12320 samples from there — **straight over the position of the next true
preamble**. `Peak_Search` cannot report it (≤1 argmax per epoch, and it is not the max
either). The receiver therefore emits one long mis-framed burst with no start mark for
the following frame, and the following frame's bytes are appended to it.
This is exactly the sim observation: rx frame 269 = **2,400 B = 872 B of filler then
seq 134's full 1,528 B header at intra-frame offset 872, with no `user` mark of its own**
**[sim, task-3b-report.md]**.

---

## 5. The mechanism that survives every constraint

**Argmax theft by a payload-induced false correlation peak.**

Run every candidate through the four filters:

| observation | timing/epoch/RF-delay story | argmax-theft story |
|---|---|---|
| ROM self-receives OTA at 1,246 f/s, byte plane at ~620 **[silicon]** | **excluded** — identical TX framing (§2d) | survives: differs only in bit content |
| CFO 0/±5 k/±20 k all fail equally **[silicon]** | n/a | survives: correlator is post-carrier-sync |
| TX atten −20 dB no change **[silicon]** | n/a | survives: threshold is running-energy (§2a) |
| FILL=100 (low entropy) **worse** (209 f/s) **[silicon]** | n/a | survives: zeros starve symbol sync → true peak degrades further |
| loopback perfect, OTA half | **excluded** (phase-invariance, §3) | survives: on the exact modulator output the true peak is maximal; the RF/ADC path degrades it toward the false-peak floor |
| sim slip needs **both** content and phase **[sim]** | n/a | survives: that is the signature of a peak at the decision margin |
| filler-free run at GAP=45,000 still fails (493 f/s) **[silicon, 02:48]** | — | filler generation independently excluded as the cause |
| 2,400 B delivery with a lost `user` mark **[sim]** | n/a | survives: §4 |

The exact aggravator for the byte plane vs ROM: `HDL_Data_Scrambler` is **hard-disabled**
(`EnableScrambling_out1 = 1'b0`, noted in task-3b-report.md **[sim]**), so a
high-entropy byte-plane payload passes through `ConvEncK5` + `TxInterleaveK5` unwhitened
and can produce Barker-like runs in the coded stream; the ROM message is a short fixed
low-entropy pattern that cannot. **[inferred]**

Note this is a **defect of the detector's decision rule**, not of gating: the RTL provides
no mechanism to reject a false peak (no minimum peak-to-sidelobe ratio, no expected-phase
prior, no second-best comparison, no per-epoch multi-peak list). A single stronger
impostor per epoch costs a whole frame, and — via §4 — often the next one too.

**Residual uncertainty (why this is not stamped as proven):** the netlist proves the
*vulnerability* exhaustively; it cannot prove that a false peak is *actually winning* on
silicon. The stable ~50 % (rather than a random loss fraction) is not explained by the RTL
alone and needs the measurement in §6.

---

## 6. Cheapest silicon test — no new bitstream required

DDRCAP-v2 already brings the whole decision out of the fabric:
`Frequency_and_Time_Synchronizer.v:314-320` exports
`dc_corr`, `dc_corrthr`, `dc_runmax`, `dc_heldts`, `dc_tref`, `dc_corrvalid`
(sourced from `Peak_Search` `p1c_*` at `Preamble_Detector.v:196-200`), routed to the
`Receiver_ddrcap_dc_*` ports at `TxRxComposite.v:864-869`. `dc_heldts` is
`Peak_Search.p1c_heldts` — the **32-bit absolute timestamp of the winning peak**
(`Peak_Search.v:196-215`).

**The test.** Run the *same* TGEN byte-plane stream twice on 148 — once at `0x114=0`
(digital loopback), once at `0x114=1` (self-reception) — and capture the `dc_*` selector.
Then, per epoch, difference successive `dc_heldts`:

- **Loopback (control):** `heldts` differences ≡ 12333 exactly, `dc_tref` of the winner
  constant, `dc_runmax` ≫ `dc_corrthr` with a wide margin.
- **Argmax theft confirmed if OTA shows:** `heldts` differences **scattered off 12333**
  (the winner jumping to a different phase within the epoch) on roughly half the epochs,
  with `dc_runmax` only marginally above `dc_corrthr` on the frames that are lost.
- **Argmax theft refuted if OTA shows:** `heldts` differences still ≡ 12333 and `runmax`
  healthy, i.e. the detector is picking the right peak and the loss is downstream
  (FEC/deinterleave/byte plane) — in which case re-open at `Receiver.v` /
  `Capture_Data_Bits` and the byte-plane delivery.

This is one gated DDRCAP capture per mode on a single board with 146 keyed off — the same
rig posture as the 02:45–03:00 probes. No RTL change, no rebuild.

**Second, even cheaper, if a gate-only counter is preferred:** `0x124` (frame-sync count)
vs `cnt_frame_start` / `cnt_bist_start` (`TxRxComposite.v:821,825`) — if the byte-plane
OTA leg shows `0x124` ≈ half while the *correlator* threshold-crossing rate is unchanged,
peaks are being found and discarded, which is the argmax rule.

---

## Appendix: the arithmetic constants, all [netlist]

| constant | value | where |
|---|---|---|
| peak-search epoch | 12333 (`0…12332`) | `Peak_Search.v:83-95`, `:116` |
| sync-pulse re-anchor epoch | 12333 | `Timing_Adjust.v:114-140` |
| preamble-detector FIFO depth | 12333 | `FIFO.v:125,160` |
| data delay line | 49332 = 4×12333 | `Preamble_Detector.v:107,321-334` |
| receive-window length | 12320 (`0…12319`) | `End_Generator.v:107-118` |
| guard (epoch − window) | **13** samples | derived |
| epoch ≡ air-frame period | 98,664 clk / 8 = 12,333 | `TxRxComposite.v:558-564` + [sim] |
| TX `dataStart` at bit | 26 (= 13 symbols preamble) | `Bit_Packetizer.v:128-132`, `Compare_To_Constant_block1.v:33-35` |
| TX frame buffer wraps | 49279 = 4×12320; 24665 = 2×12333 | `Data_Bits_FIFO.v:103,193,302` |
| correlator threshold | 63-sample running energy, floored | `Correlator.v:110-177`, `ThresholdLimiter.v:34-37` |
