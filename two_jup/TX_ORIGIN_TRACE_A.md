# TX_ORIGIN_TRACE_A — netlist/RTL root-cause trace of the 120.2 s re-anchor beat

Read-only netlist trace. No board contact. Every claim is labelled **[RTL fact]** (with file:line),
**[silicon]** (from the handed-over evidence or session notes), or **[inferred]**.

Primary tree: `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (shipped lineage).
Instrumented tree with the `txFrameStart` port: `jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/`.
Paths below are relative to those directories unless stated.

---

## 0. The one structure that matters (read this first)

**[RTL fact]** The whole TX frame/marker/data plane hangs off ONE module:
`Data_Bits_FIFO.v` inside `Bit_Packetizer` inside `QPSK_Tx`
(`QPSK_Tx.v:57-67` instantiates `u_Bit_Packetizer`; `Bit_Packetizer.v:72-82` instantiates `u_Data_Bits_FIFO`).

Its three free-running counters and one latch are:

| register | file:line | width | wrap | what it is |
|---|---|---|---|---|
| `HDL_Counter3_out1` | `Data_Bits_FIFO.v:174-184` | 1 bit | toggles every `enb_1_2_0` | bit-slot half-rate tick |
| `HDL_Counter2_out1` (`sampleCount`) | `Data_Bits_FIFO.v:190-218` | ufix15 | 0..**24665** | **the air-frame slot counter** |
| `HDL_Counter_out1` (RAM wr ptr) | `Data_Bits_FIFO.v:100-128` | uint16 | 0..**49279** | write address, +1 per push |
| `HDL_Counter1_out1` (RAM rd ptr) | `Data_Bits_FIFO.v:293-321` | uint16 | 0..**49279** | read address, +1 per pop |
| `Unit_Delay_Enabled_Resettable_Synchronous_out1` (`armed`) | `Data_Bits_FIFO.v:272-289` | 1 bit | — | **the pop enable latch** |
| `frameCount` | `RAM_Frame_Status_Indicator.v:50-94` | **ufix2** | 0..3, unguarded ±1 | frames resident in the RAM |

**[RTL fact]** `sampleCount` = 24,666 slots per cycle (`Data_Bits_FIFO.v:200`, wrap value
`15'b110000001011001` = 24665). Of those, slots 0..25 emit preamble and slots 26..24665 emit RAM data
(`Data_Bits_FIFO.v:222` `>= 26`; `Bit_Packetizer.v:121-124` Switch). So **24,640 data bits + 26 preamble
bits = 24,666 bits = 12,333 symbol slots = one air frame**, which is exactly the frame the observers
call "12,320 symbols" (12,320 data symbols) and "197,328 clocks" (12,333 × 16).
The RAM is `49,280 = 2 × 24,640` bits deep — exactly two frames of payload.

---

## 1. Every condition under which `Bit_Packetizer_dataStart` asserts

**[RTL fact]** `Bit_Packetizer.v:126-132`:

```
Compare_To_Constant_block1 u_Compare_To_Constant (.u(Data_Bits_FIFO_sampleCount), .y(Compare_To_Constant_y));
assign Logical_Operator_out1 = Compare_To_Constant_y & Data_Bits_FIFO_sampleCountValid;
assign dataStart = Logical_Operator_out1;
```
`Compare_To_Constant_block1.v:35-39`: `y = (u == 15'b000000000011010)` = **sampleCount == 26**.
`Data_Bits_FIFO.v:391-393`: `sampleCount = Delay5_out1`, `sampleCountValid = Delay6_out1`.

So there is exactly **one** condition: `sampleCount == 26 && sampleCountValid`.
`QPSK_Tx.v:118` (`s1_rtl_ddrcap2`) `assign txFrameStart = Bit_Packetizer_dataStart;` — confirmed, the
observed marker is this and nothing else.

**Which one can fire mid-frame while the regular cadence continues? [RTL fact + inferred] NONE.
This signal is provably incapable of an extra pulse.** Proof from the netlist:

* `sampleCount` is `Delay5` = `HDL_Counter2` delayed twice (`Data_Bits_FIFO.v:349-371`).
* `sampleCountValid` is `Delay6` = `Compare_To_Constant5_y` delayed twice (`:236-246`, `:375-385`).
* `Compare_To_Constant5_y = (HDL_Counter3_out1 == 1)` (`:186-188`), a strict divide-by-2 of `enb_1_2_0`.
* `HDL_Counter2` advances **only** when `Compare_To_Constant5_y` is high (`:205`), i.e. on exactly the
  alternate ticks, and only ever `+1` or wrap-to-0 at 24665 (`:198-206`). It is monotone; it has no
  synchronous load, no clear, no external reset input.
* Therefore each counter value is presented for exactly two `enb_1_2_0` ticks, and because both delay
  chains are the same depth, exactly ONE of those two ticks has `sampleCountValid` high.
  **⇒ exactly one `dataStart` per 24,666-slot cycle, unconditionally.**
* Clock-enable gating cannot inject a pulse (everything pauses together). The only register in the
  chain with a clear is the async `reset` (`:211`, `:352`, `:377`), and a `reset` would re-zero
  `HDL_Counter2` and therefore **move the whole marker cadence** — which the silicon says does not
  happen.

**[inferred — load-bearing contradiction, flagged for the sim agent]** The silicon report of "an extra
`Transmitter_txFrameStart` pulse one record before every data departure" **cannot be an extra assertion
of this net**. Two readings survive:

* **(1a) It is a mark placed one record EARLY by the instrument.** `s1_rtl_ddrcap2/TxRxComposite.v:2165`
  `wire ddrcap_fec_mark_now = Transmitter_txFrameStart | ddrcap_fec_mark_latch;` and `:2168-2179` — the
  FEC/TX marker written into a DDRCAP record is a **sticky latch** that holds a pending pulse until the
  next `ddrcap_valid_beat` and clears on it. The record index at which a mark appears is therefore a
  function of the mark/valid phase, not of the pulse time. Combined with the known ~20 % record drop at
  the rx2 DMA on enb-domain taps ([[ddrcap-fullrate-dma-drops]]), a mark can land one record before its
  usual slot without any change in the pulse train. **This is the most likely reading.**
* **(1b) A genuine second pulse ⇒ an async `reset` (or reset-equivalent) reached `u_Data_Bits_FIFO`.**
  `TxRxComposite.v:590-591` wires the Transmitter's `.reset(reset)` straight from the top-level reset;
  there is no local TX reset. This reading predicts the *marker cadence must jump too* — directly
  testable and directly contradicted by the handed-over evidence.

Discriminating (1a) vs (1b) is test **T0** in §6 and should be run first: it is cheap and it decides
whether the marker anomaly is signal or instrument.

**State machine / counter that drives it:** none — it is a pure comparator on the free-running
`HDL_Counter2` frame-slot counter (`Data_Bits_FIFO.v:190-218`). There is no FSM.

---

## 2. What feeds the packetizer bytes in mode 1

**[RTL fact]** TX source select: `TxRxComposite.v:504`
`assign ByteSel_out1 = tx_data_source != 32'd0;` → `TxRxComposite.v:597` `.extBitSel(ByteSel_out1)`
→ `Input_Data.v:138-141`:
```
assign BitMux_out1 = (extBitSel_1 == 1'b0 ? Message_Generator_out_1 : FEC_Tx_Encoder_K5_encBit);
assign txData = BitMux_out1;
```
**[RTL fact]** `rtl_sim/wrap_byte_ddrcap.v:4` — "ROM/BIST frame generator (`tx_data_source=0`)".
**[silicon]** every capture in the handed-over evidence and in `SESSION_20260830_AUTONOMOUS.md` §4/§39/§76
is "mode 1 … ROM BIST".

> ### ⇒ **In these captures the byte plane is OUT OF CIRCUIT for the data.**
> With `tx_data_source == 0` the mux selects `Message_Generator_out_1` and the entire
> `ByteWordBuffer → ByteBitShifter → FEC_Tx_Encoder_K5` branch is dead-ended at `Input_Data.v:138`.
> **The `ByteWordBuffer` `readyNext = count<=6` starvation defect named in the brief cannot move the
> data in a mode-1 ROM run.** The "64 symbols = 128 bits = 16 bytes ≈ one buffer word" coincidence is
> **numerology, not causation**, for these captures. It becomes live only if `tx_data_source != 0`.

**[RTL fact]** What actually feeds the packetizer in mode 1: `Message_Generator` →
`MATLAB_Function_block3.v`, a **fixed 24,640-bit pre-coded ROM** (`msgbits[24639:0]`,
`MATLAB_Function_block3.v:67`; header comment at the logic block: "FIXED pre-coded K=5 packet ROM
(rom_words_770_f1536.txt, 24640 bits) … info(12292)+tail(4) → 24592 bits, 1537×16 block-interleaved,
+ 48-bit PN9 filler"). Chart logic (`MATLAB_Function_block3.v`, logic block after the ROM table):
`start = (indexCount==0)`, `stop = (indexCount==24639)`, `valid = 1` while enabled; `stop` is registered
in `Input_Data.v:78-88` and fed back as `reset_1`, giving **one dead slot per 24,640 pushes**
(chart period = 24,641 enabled steps).

**Does the byte path have a buffer whose underrun/overrun restarts a packet/frame? Yes — two,
both out of circuit in mode 1:**

* **[RTL fact] `ByteWordBuffer.v`** — 16-deep 64-bit skid FIFO. `:314` `state_readyReg_1 = newCount <= 8'd6`
  (DEPTH−MARGIN = 6); `:254-255` push is gated on `readyAtPin = state_readyHist_1[7]` (ready delayed 8
  beats) **and** `state_count < 16`; `:233` `avail = state_count > 0`; `:256` `popp = popReq && avail`.
  On underrun it simply drops `avail`; it does not itself restart anything.
* **[RTL fact] `ByteBitShifter.v:180-200` — this is where an underrun restarts the frame.**
  ```
  else if (start || (state_bitIdx >= 8'd64)) begin
      if ((start && extWordAvail) && (!extWordFirst)) begin   // word-phase error
          pop=1; a1_0=0; a1=64; state_aligned_1=0;            // discard + realign
      end else if (extWordAvail) begin a1_0=extWord; pop=1; a1=0;
      end else begin                                          // UNDERFLOW
          a1_0=0; a1=64; state_aligned_1=0;                   // emit zeros, drop alignment
      end
  end
  ```
  and once unaligned (`:159-178`) it **discards one whole 64-bit word per enabled step** until a
  `extWordFirst`-marked head arrives. So a `ByteWordBuffer` underrun ⇒ a zero frame + word discards ⇒ a
  permanent word-phase change in **whole 64-bit words**. `64 info bits → rate-1/2 → 128 coded bits →
  64 QPSK symbols`, which is why the 64-symbol rung quantum is *suggestive* of this path — but see the
  box above: in mode-1 ROM it is not connected.

**[RTL fact] The buffer that IS in circuit in mode 1 and that does restart the frame:
`Data_Bits_FIFO`'s pop-enable latch.** `Data_Bits_FIFO.v:272-291`:
```
if (Compare_To_Constant1_out1 == 1'b1)            // frameCount == 0   -- CHECKED EVERY TICK
     armed <= 1'b0;
else if (Compare_To_Constant3_out1)               // sampleCount == 0
     armed <= Compare_To_Constant2_out1;          // frameCount != 0
...
assign Logical_Operator_out1 = Delay4_out1 & (armed & Delay1_out1);   // = pop
```
`Compare_To_Constant1_out1` (`:270`) is `Delay3_out1 == 2'b00`, i.e. `frameCount == 0`, and it is
evaluated on **every** `enb_1_2_0` tick — **not** only at the frame boundary. The arm/reload is gated on
`sampleCount == 0` (`:220`), but the **clear is not gated at all**.

**⇒ [inferred] The instant `frameCount` reads 0, pops stop mid-frame, the read pointer freezes, the
remainder of the frame emits stale RAM content, and at the next `sampleCount == 0` the data resumes from
exactly where it stopped. No bits are lost or duplicated: the data stream is delayed, bit-exact, by the
number of pops that did not happen — an arbitrary partial-frame re-anchor — while `sampleCount`,
`dataStart` and every marker keep their cadence untouched.** This is the only structure in the TX plane
that produces the observed signature.

`frameCount` is **ufix2 with unguarded arithmetic** (`RAM_Frame_Status_Indicator.v:70-75`):
`frameCount+1` at push-wrap and `frameCount-1` at pop-wrap, no saturation — so it reaches 0 either by
the producer falling two frames behind **or by wrapping 3→0** on a fourth uncompensated push-wrap.

---

## 3. Every periodic cadence in the TX plane, and the beat arithmetic

**[RTL fact] Clock structure.** `TxRxComposite_tc.v:20-23`: `enb = enb_1_1_1 = clk_enable`;
`enb_1_2_0` and `enb_1_2_1` are the two phases of a divide-by-2 of `clk_enable`
(`TxRxComposite_tc.v:63-108`). There is **one clock domain**; `enb_1_2_0` is the TX bit-plane beat.
Frame anchor used below: **12,333 symbol slots / frame at 15.36 Msym/s = 802.93 µs**, which is the same
thing as "197,328 clocks" (16 clocks per symbol) and "98,664" (8 per symbol) — *those two numbers are
the same period counted in two different domains, not two distinct cadences* [inferred].

| cadence | value | units | file:line |
|---|---|---|---|
| air frame / `sampleCount` cycle | **24,666** bit slots = 12,333 symbols = 197,328 clk = 802.93 µs | free-running | `Data_Bits_FIFO.v:200` (wrap 24665) |
| bit-slot tick | 2 × `enb_1_2_0` | — | `Data_Bits_FIFO.v:164-188` |
| preamble window | slots 0..25 (26 bits = 13 symbols) | per frame | `Compare_To_Constant2.v:35`, `Data_Bits_FIFO.v:222` |
| data-pop window | slots 26..24665 = **24,640 pops** | per frame | `Data_Bits_FIFO.v:222,291` |
| `dataStart` / `txFrameStart` | slot **26** | 1 per frame | `Compare_To_Constant_block1.v:35` |
| `dataEnd` | slot **24,665** | 1 per frame | `Compare_To_Constant1_block1.v:35` |
| RAM depth (wr/rd ptr wrap) | **49,280** bits = 2 frames | — | `Data_Bits_FIFO.v:110,303` |
| FIFO-full threshold | occupancy **> 49,279** | — | `MATLAB_Function1.v:65` |
| frame-status push/pop wrap | **24,640** | — | `RAM_Frame_Status_Indicator.v:70,73` |
| `frameCount` | **2 bits**, 0..3, unguarded | — | `RAM_Frame_Status_Indicator.v:43,70-75` |
| ROM message length | **24,640** bits + 1 dead slot = **24,641** chart steps | — | `MATLAB_Function_block3.v:67`, logic `indexCount==24639` |
| `msgCount` (BIST 1..9) | 9 ROM messages | — | `MATLAB_Function_block3.v` logic `msgCount >= 9` |
| pacing toggle (`dataReady`) | 1-bit, freezes on `fullRAM` | — | `Bit_Packetizer.v:144-178` |
| TxGateK5 beat counter (byte path only) | 0..**24,639**, info 0..12,291, tail ..12,295 | per FEC frame | `TxGateK5.v:100-116` |
| `ByteWordBuffer` | depth **16** × 64 bit, ready threshold **≤ 6**, ready lag **8** | byte path only | `ByteWordBuffer.v:53,255,314,254` |
| `ByteBitShifter` word | **64 bits** = 64 symbols coded | byte path only | `ByteBitShifter.v:180-200` |

### The arithmetic

Producer vs consumer, per frame:
* pops = **24,640** (`Data_Bits_FIFO.v:291`, window 26..24665).
* push opportunities = 24,666 bit slots × (24,640/24,641 duty from the ROM chart's dead reset slot)
  = **24,665.0**.
* surplus = **+25 bits per frame** ⇒ the producer is chronically throttled by `fullRAM`
  (`Bit_Packetizer.v:144,161`), i.e. the RAM sits pinned at 2 frames, `frameCount == 2` [inferred].

Candidate beats, all computed against a 802.93 µs frame:

| pair | beat | period |
|---|---|---|
| lcm(24,666 pop cycle, 24,641 ROM chart cycle) | 24,641 frames | **19.78 s** |
| lcm(24,666, 24,640)/2 | 12,320 frames | **9.89 s** |
| free 25 bit/frame slip over one frame (24,666/25) | 986.6 frames | **0.79 s** |
| RAM span / surplus (49,280/25) | 1,971 frames | **1.58 s** |
| 16-bit `MATLAB_Function1.count` roll (65,536−49,280)/25 | 650 frames | **0.52 s** |
| 2^32 `enb_1_2_0` ticks (30.72 MHz) | — | 139.8 s |
| 2^32 sample clocks (61.44 MHz) | — | 69.9 s |
| 2^32 symbol clocks (15.36 MHz) | — | 279.6 s (telemetry only — `BURST120_SIM_RESULTS.md` §1) |

Target: 120.2 s = **149,708.6 frames** (not an integer number of frames); 239.5 s = **298,281 frames**.

> ### ⇒ **NO cadence pair, counter wrap or clock-domain ratio in the TX plane beats at 120.2 s.**
> The nearest structural candidates are 19.78 s (residual ×6.08, not integer) and 139.8 s (2^32
> `enb_1_2_0` ticks, +16 % off). `BURST120_SIM_RESULTS.md` §1 reached the same conclusion for the RX
> plane by exhaustive enumeration. **[inferred]** The recurrence rate is therefore **not** set by a
> clock ratio; it is set by a slow accumulation whose rate is a small residual (occupancy drift under
> the `fullRAM` throttle), which is consistent with the 239.5 s two-state BIG/sml cycle: one slow
> accumulator producing two *unequal* events per wrap, not a 120.2 s periodicity.

---

## 4. Why the restart lands at half a frame + 16..388 symbols in ~64-symbol steps

**[inferred, arithmetic on the silicon rungs]** Under the §2 mechanism the data delay equals the pop
deficit. Rung `R` symbols ⇒ delay `2R` bits ⇒ pops completed before the abort `P = 24,640 − 2R`:

| rung R (sym) | 2R (bits) | P = pops before abort | P as bytes (blank = NOT on the 16-byte lattice) | ΔP from 12,288 |
|---|---|---|---|---|
| 6176 | 12,352 | **12,288** | **1536 B** | 0 |
| 6240 | 12,480 | 12,160 | 1520 B | −128 |
| 6299 | 12,598 | 12,042 | — | −246 |
| 6363 | 12,726 | 11,914 | — | −374 |
| 6432 | 12,864 | 11,776 | 1472 B | −512 |
| 6489 | 12,978 | 11,662 | — | −626 |
| 6548 | 13,096 | 11,544 | — | −744 |

Readings:

* The **k = 0 rung is an abort at exactly 12,288 pops = 1536 bytes** — the model's declared payload
  (`TxRxComposite.v:73` model description "frame=**f1536**"; `MATLAB_Function_block3.v` ROM comment
  "rom_words_770_**f1536**.txt … info(**12292**)+tail(4)"). 12,288 is also `24,640/2 − 32`, i.e. the
  half-frame point — this is where "half a frame" comes from: **the pop abort at the midpoint of the
  24,640-bit pop window**, not from any half-frame counter.
* Successive rungs are aborts **128 bit slots = 64 symbols = 16 bytes earlier** each. Observed ΔP steps
  are 128, 118, 128, 138, 114, 118 — mean **124**, i.e. 128 ± ~8 % scatter, which is within the noise of
  an offset map read through a record stream that drops ~20 % of records
  ([[ddrcap-fullrate-dma-drops]]). **[inferred]** The quantum is 128 bit slots.
* **Counter mapping [inferred]:** the abort instant is set by when `frameCount` reads 0 relative to
  `popCount` (`RAM_Frame_Status_Indicator.v:84-91`), i.e. by the **push/pop pointer phase**. The
  128-bit quantum is 2 × 64 bits; there is **no 128-bit structure on the ROM path** — the only 64-bit
  granule in the design is the `ByteWordBuffer`/`ByteBitShifter` word (`ByteWordBuffer.v:39`,
  `ByteBitShifter.v:180-200`), which is out of circuit in mode 1. **This is the single weakest link in
  the chain and the sim agent should treat the quantum as unexplained**, not as evidence for the byte
  path. A defensible alternative: the quantum is an artefact of the tap3 offset-map word granularity
  and the true abort positions are continuous.

---

## 5. Why phase-locked to the arm

**[RTL fact]** Every register in the chain is async-reset by the single top-level `reset`
(`TxRxComposite.v:591` `.reset(reset)` into `u_Transmitter`; `Data_Bits_FIFO.v:118-128, 174-184,
190-218, 208-218, 258-268, 272-289, 311-321`; `RAM_Frame_Status_Indicator.v:50-64`;
`MATLAB_Function1.v:45-55`; `MATLAB_Function_block3.v:91-112`). The arm's modem soft reset (0x000)
drives it.

**[RTL fact + inferred]** In mode 1 with `tx_data_source == 0` the entire TX plane is a **closed
deterministic system with no external input**: a fixed 24,640-bit ROM, fixed counters, a fixed pacing
toggle, one clock. After the reset releases, `sampleCount`, `indexCount`, the RAM pointers, the
occupancy counter and `frameCount` all start from a known state and evolve by a fixed rule. Therefore
**every subsequent event, including the occupancy drift that reaches the abort condition, occurs at a
fixed number of frames after reset** — the first at ~110 s, then at the beat interval, with a
deterministic BIG/sml alternation because the abort position (and hence the rung, hence the damage) is
a deterministic function of the pointer phase at the wrap. This is exactly why the silicon sees the
same "BIG sml BIG sml BIG" parity across four arms, two days and two signal paths
([[beat-120s-status]], `SESSION_20260830_AUTONOMOUS.md` §4). A loop-integrator or RF mechanism would
not be bit-reproducible across arms; a closed deterministic TX counter system is.

---

## 6. Ranked mechanisms, one forced-sim test each

Verilator flat naming — **verified present in the built flat model**
(`grep -oh 'u_Data_Bits_FIFO__DOT__[A-Za-z0-9_]*' rtl_sim/obj_ddrcap2/*.h`, 2026-09-02): the hierarchy
is NOT inlined, every register below exists verbatim.

```c
#define TXP  "wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__"
#define DBF  TXP "u_Bit_Packetizer__DOT__u_Data_Bits_FIFO__DOT__"
#define FSI  DBF "u_RAM_Frame_Status_Indicator__DOT__"
// verified members:
//   DBF "Delay3_out1"              (frameCount, delayed -- what :270 compares)
//   DBF "Delay5_out1"  DBF "Delay6_out1"   (sampleCount, sampleCountValid)
//   DBF "HDL_Counter2_out1"        (the raw frame-slot counter)
//   DBF "HDL_Counter_out1" / "HDL_Counter1_out1"   (RAM wr / rd pointers)
//   DBF "Unit_Delay_Enabled_Resettable_Synchronous_out1"   (the `armed` latch)
//   DBF "Logical_Operator_out1"    (the pop strobe)
//   FSI "frameCount"  FSI "pushCount"  FSI "popCount"
//   DBF "u_MATLAB_Function1__DOT__count"   (uint16 occupancy)
// composite-level marker net (PRIMARY tap for T0):
//   wrap_byte_ddrcap__DOT__dut__DOT__Transmitter_txFrameStart
```
(substitute the wrapper module name actually built — `wrap_byte_ce`, `wrap_byte_ddrcap` and
`wrap_byte_taps` all instantiate the DUT as `dut`; only `wrap_byte_ddrcap` was name-verified.)

Scoring for every test: the demod-input (sel6) word against the injective tap3 offset map, exactly as
§76 of `SESSION_20260830_AUTONOMOUS.md`. Positive result = **word FOUND bit-exact at a non-zero offset
(a rung), with `Transmitter_txFrameStart` cadence and the demod marker gaps unchanged**. §76 established
that all timing-plane kicks give a *corrupted* (not-found) word instead — so "found at an offset" is a
clean discriminator.

---

### **T0 (run first, cheap, decides §1). Is the "extra txFrameStart" real or an instrument artefact?**
* **Force:** nothing. Instrument only.
* **Do:** log the composite-level net `wrap_byte_ddrcap__DOT__dut__DOT__Transmitter_txFrameStart`
  (verified to exist; prefer it — `Bit_Packetizer.Logical_Operator_out1` is a wire and is not a member)
  on every `enb_1_2_0` tick for ≥ 5 frames, alongside
  `ddrcap_fec_mark_now` / `ddrcap_fec_mark_latch`
  (`s1_rtl_ddrcap2/TxRxComposite.v:2164-2179`) and the record index.
* **Expect:** exactly 1 `dataStart` per 24,666 slots, always at `sampleCount==26`, and the *recorded*
  mark landing at a record index that varies with the mark/valid phase.
* **Kills:** if a second `dataStart` ever appears without `reset`, §1's proof is wrong and the whole
  trace must be redone. If not, the silicon "extra pulse" is the sticky-latch/record-drop artefact
  (reading 1a) and the sim agent should stop treating it as a TX event.

---

### **#1 — `Data_Bits_FIFO` pop-abort: `armed` cleared mid-frame by `frameCount == 0`. [top-ranked]**
`Data_Bits_FIFO.v:270` (`frameCount==0` compare), `:272-289` (the ungated clear),
`:291` (the pop gate), `RAM_Frame_Status_Indicator.v:70-75` (unguarded ufix2 ±1).

Why it is first: it is the **only** structure found in the whole TX plane that delays the data by an
arbitrary partial frame, **bit-exact**, with **no effect on `sampleCount`, `dataStart`, the preamble or
any marker** — precisely the silicon signature, and precisely what every killed hypothesis
([[beat-120s-status]]: delay-FIFO displacement, spurious start pulses, timing-loop drift) failed to
produce.

* **Force:** at a chosen frame `K`, mid-frame (pick `sampleCount ≈ 12,314`, i.e. 12,288 pops done),
  set `R->CAT(FSI, frameCount) = 0` and `R->CAT(DBF, Delay3_out1) = 0` for **one** `enb_1_2_0` tick,
  then release. (Forcing `Delay3_out1` alone is sufficient — it is what `:270` compares — and is the
  cleaner one-signal force.)
* **Expected signature:** from frame `K` on, the sel6 word is **found in the offset map at a rung of
  ≈ +6,176 symbols** (= (24,640 − 12,288)/2), **bit-exact**, marker cadence unmoved, and the rung is
  **persistent** (a state, not a transient) — matching §39's "displacement is a STABLE state".
* **Sweep to confirm the geometry:** repeat with the force at 12,288 − 128·k pops for k = 0..6; the
  measured rung must track 6,176 + 64·k symbols.
* **Kills it if:** the demod word comes back *corrupted / not found in the map* (the §76 signature), or
  the rung self-heals within a frame, or the marker cadence moves.

### **#2 — `frameCount` ufix2 wrap 3→0 (the mechanism that *reaches* #1's condition).**
`RAM_Frame_Status_Indicator.v:43,70-72` — `frameCount + 2'b01` with no saturation, in a RAM only 2
frames deep, throttled by a **≥ 3-tick-latency** backpressure loop
(`MATLAB_Function1.v:65` → `Data_Bits_FIFO.v:403-415` `Delay7` → `Bit_Packetizer.v:144,161` toggle →
`Input_Data.v` enable → push). A 4th uncompensated push-wrap wraps 3→0 and fires #1 with no producer
stall at all.
* **Force:** set `R->CAT(FSI, frameCount) = 3` at frame `K` and let the design run — do **not** force
  the clear. If the design then wraps to 0 on its own at the next push-wrap and produces a rung, the
  wrap is a live path.
* **Expected:** identical rung signature to #1, but arriving one push-wrap after the force, with no
  external force at the abort instant. **Kills it if:** `frameCount` saturates or never reaches the
  push-wrap while at 3.

### **#3 — RAM occupancy overshoot past `fullRAM` (the drift that sets the 120 s rate).**
`MATLAB_Function1.v:57-67`: `count` is **uint16** and `full = count_temp > 49,279` — the compare is
`>` on a counter that can legally exceed the threshold during the 3-tick loop latency, and that wraps
at 65,536. There is **no push guard anywhere** in `Data_Bits_FIFO` (`:115-116` writes unconditionally
on `push`).
* **Force:** ramp `R->CAT(DBF, u_MATLAB_Function1__DOT__count)` toward 65,535 over a run and observe
  whether `fullRAM` deasserts, the producer free-runs, and the pointers lap.
* **Expected:** a rung *and* a bit-error burst; if the rung is not bit-exact this is not the beat.
* **Note:** this is the candidate for **when**, not **what** — §3 shows no clean 120.2 s arithmetic,
  so measuring the actual occupancy drift rate in a long sim is the direct way to test 120.2 s.

### **#4 — async `reset` reaching `u_Data_Bits_FIFO` (reading 1b of §1).**
`TxRxComposite.v:591`. Explains a genuinely extra `dataStart`, but predicts a marker jump.
* **Force:** pulse `reset` into the Transmitter for one clock at frame `K`.
* **Expected:** an extra `dataStart` **and** a shifted `sampleCount`/marker cadence.
* **Kills it if** (and it should): the marker cadence moves, contradicting the silicon.

### **#5 — `ByteWordBuffer` starvation / `ByteBitShifter` realign. [last — out of circuit in mode 1]**
`ByteWordBuffer.v:314` (`readyNext = count<=6`), `ByteBitShifter.v:180-200` (underflow → zeros +
`state_aligned=0`), `:159-178` (one-word-per-step discard). Produces whole-64-bit-word (= 64-symbol)
phase steps, which is why the rung quantum *looks* like it — but `TxRxComposite.v:504` /
`Input_Data.v:138` put it behind a mux that is **off** for `tx_data_source == 0`.
* **Force:** run with `tx_data_source = 1` and stall the DMA source to empty the buffer at frame `K`.
* **Expected:** one zero frame, then a persistent word-phase offset in whole 64-symbol steps.
* **Relevance gate:** only if a beat capture is ever taken with `tx_data_source != 0`. For the mode-1
  ROM captures on the table, **this mechanism is excluded by the mux, and any 64-symbol coincidence
  with it is numerology.**

---

## 7. Honest limits

* The 128-bit-slot rung quantum (§4) is **not** mapped to a counter on the ROM path. Stated as
  unexplained.
* No 120.2 s arithmetic exists in the TX plane (§3). Stated as a negative result, with residuals.
* The "extra `txFrameStart` pulse" is **contradicted by the RTL** (§1). The report does not assume it
  happened; T0 decides.
* Everything in §2/§4/§5 about the pop-abort is **[inferred]** from the RTL structure — it has not been
  simulated. Test #1 is the whole point of this document.
