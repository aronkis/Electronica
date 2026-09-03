# TX_RATE_E — the natural trigger of the `Data_Bits_FIFO` pop-abort, and its rate

Host-only (Verilator + RTL reading). No board contact. Labels: **[RTL fact]** (file:line),
**[sim]** (measured in this pass), **[silicon]** (cited, not re-measured), **[inferred]**.

Primary tree: `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (shipped lineage);
simulated tree `jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/`
(identical for every module named below).
New sources: `jupiter_240k5_byte/rtl_sim/txrate_probe.cpp`, `build_txrate_sim.sh`,
`build_txrate_sim2.sh`. Outputs: `jupiter_240k5_byte/rtl_sim/beat_runs/txrate_*`.

---

## 0. Answer in two sentences

**Trigger.** The producer pushes 24,666 bits per air frame but only 24,640 are popped, so
`pushCount` (mod 24,640) wraps 24,666/24,640 = 1.001055 times per frame while `popCount` wraps
exactly once; every 24,640/26 = **947.69 frames** there is therefore ONE EXTRA push-wrap, and
because `frameCount = (#push-wraps − #pop-wraps)` is an **unguarded ufix2**
(`RAM_Frame_Status_Indicator.v:66-92`) its baseline ratchets 1 → 2 → 3 → 0.
**When the baseline reaches 3, the next natural push-wrap makes `frameCount` read 0 mid-frame**
— at the push-wrap position, which is itself sweeping backwards through the frame at 26 slots per
frame — and `Data_Bits_FIFO.v:270-289` (the clear is evaluated on *every* `enb_1_2_0` tick, not
only at a frame boundary) drops the pop-enable latch, freezing the RAM read pointer from there to
the end of the frame and through the whole following frame.

**Second, equally important result.** The *natural* abort produces **zero net displacement**: it is
followed one frame later by a second abort (`popCount` wrapping 1→0) that completes exactly the
frame the first one interrupted, and the measured total pop deficit is precisely 2 × 24,640 bit
slots ⇒ offset ≡ 0 (mod 12,320) ⇒ invisible in the offset map after one frame (§3c). So the
free-running drift is falsified not only as the *rate* mechanism (§2) but as the mechanism for the
**sustained rung state** silicon reports: `TX_KICK_SIM_B.md`'s permanent rung came from a single
artificial clear that has **no natural analogue found here**. Anything built on `§89` should start
from that.

---

## 1. RTL: the push side, exactly

| fact | file:line |
|---|---|
| `frameCount` is `reg [1:0]` (ufix2), **no saturation** | `RAM_Frame_Status_Indicator.v:43` |
| `frameCount_temp = frameCount + 1` **iff** `pushCount == 24639 && push` | `RAM_Frame_Status_Indicator.v:69-71` |
| `frameCount_temp = frameCount_temp − 1` **iff** `popCount == 24639 && pop` | `:72-74` |
| `pushCount`/`popCount` are ufix15 wrapping at **24,639** (mod 24,640) | `:75-91` |
| `out_1 = frameCount_temp` — **combinational**, so a transient value is exported the same tick | `:89-92` |
| the pop gate sees `Delay3_out1` = `out` registered one `enb_1_2_0` tick later | `Data_Bits_FIFO.v:248-256` |
| `Compare_To_Constant1_out1 = (Delay3_out1 == 2'b00)` | `Data_Bits_FIFO.v:258` |
| `armed` is **cleared on every tick** with `frameCount==0`; the reload is gated on `sampleCount==0`, the **clear is not gated at all** | `Data_Bits_FIFO.v:272-289` |
| pop strobe `= Delay4 & armed & Delay1` | `Data_Bits_FIFO.v:291` |
| pop window = slots 26..24665, i.e. **24,640 pops/frame** | `Data_Bits_FIFO.v:222,291` |
| frame = 24,666 slots (`sampleCount` wraps at 24,665) | `Data_Bits_FIFO.v:200` |
| push = `txValid` = `Message_Generator.valid` = its `enable` | `Input_Data.v:143`, `MATLAB_Function_block3.v` (`valid_1 = 1'b1` while enabled) |
| `enable` = `dataReady` delayed one tick | `Transmitter.v:103-116,122` |
| `dataReady` = a 1-bit toggle advancing on every `enb_1_2_0` tick **while `!fullRAM`**, frozen when `fullRAM` | `Bit_Packetizer.v:144-178` |
| ⇒ 50 % duty: **24,666 pushes per 49,332 `enb_1_2_0` ticks per frame** | derived; **[sim] confirmed** |
| occupancy `count` is **uint16**, `full = count_temp > 49279`, no push guard anywhere | `MATLAB_Function1.v:57-67`; `Data_Bits_FIFO.v:100-128` writes unconditionally on `push` |
| `fullRAM` = `full` registered once | `Data_Bits_FIFO.v:403-415` |

**Producer surplus [sim, `beat_runs/txrate_cen6_frames.txt`]** — every frame from frame 1 on:
`pushes=24666 pops=24640`, `occ` +26/frame (24665, 24692, 24718, 24744, 24770, 24796), and the
push-wrap position inside the frame moves **−104 harness clk = −26 bit slots per frame**
(`pushWrapPos` 98662 → 98458 → 98354 → 98250 → 98146 → 98042) while the pop-wrap sits fixed at
+2 clk after the frame start. This is the whole clock of the mechanism.

### 1a. `fullRAM` back-pressure is broken — it *doubles* the push rate [sim, new]

`beat_runs/txrate_nf_frames.txt` (`sel=nfprobe`: single-tick force of `MATLAB_Function1.count` to
49,227 at frame 3, nothing else touched):

```
CEN frame=4 occ=49279 pushes=24666 pops=24640 fullRAM=0 pace=0
CEN frame=5 occ=1     pushes=40898 pops=24640 fullRAM=0 pace=1   <-- runaway + uint16 wrap
CEN frame=9 occ=105   pushes=24666 pops=24640 fullRAM=0 pace=1
```

When `count` crosses 49,279 the `Bit_Packetizer` pace toggle freezes at **1**
(`Bit_Packetizer.v:161`, hold when `fullRAM`), so `dataReady` sticks HIGH and the producer pushes
on **every** `enb_1_2_0` tick instead of every other one. `count` then runs away — 16,232 extra
pushes measured in frame 5, predicted 16,239 = (65,536−49,280)/2 — until the **uint16 `count`
wraps at 65,536**, `full` deasserts, and 50 % pacing resumes with the occupancy counter reading
~0 while the RAM has actually been over-written by 16,256 bits. This also explains the
previously-unexplained one-off jump of the push-wrap position in `txkick_nf_v0_frames.txt`
(98,146 → 49,026 clk). **There is no working back-pressure in this design**; `fullRAM` is a
0.66-frame data-destroying excursion, not a throttle.

---

## 2. Arithmetic

Frame = 24,666 bit slots = 12,333 symbols = 197,328 sample clocks = **3.21172 ms**
(197,328 / 61.44 MHz; the 802.93 µs in `TX_ORIGIN_TRACE_A.md` §3 is 4× too small and every period
computed from it there is wrong by 4×).

| quantity | frames | seconds |
|---|---|---|
| one extra push-wrap (base +1) = 24,640 / 26 | **947.69** | **3.0437** |
| first `frameCount==0` after arm (base 1→2→3) | 1895.38 | **6.087** |
| full mod-4 return of the base | 3790.77 | 12.175 |
| `fullRAM` excursion cycle (49,280 / 26) | 1895.38 | 6.087 |

**Versus silicon: this is a falsification, not a match.** Silicon shows the first burst ~110 s
after arm and a 120.2 s recurrence with a 239.5 s big/small alternation. The free-running drift
predicts the first zero-read at **6.09 s** (18.1× too early) and a recurrence of 3.04 s
(39.49× too fast). Residuals, stated as residuals and not as explanations:
120.2 / 3.0437 = 39.49; 120.2 / 12.175 = 9.873; 110 / 6.087 = 18.07 — none integer.
Equivalently, the observed 120.2 s would require an **effective** relative drift of
24,640 / (120.2 s / 3.21172 ms) = **0.658 slots per frame**, i.e. 1/39.5 of the structural +26.

**What else must gate it [inferred].** The abort is not a free-running event: it changes the very
phase that produced it. When `armed` drops, no further pops occur for the rest of that frame and
(§4 below) for the whole next frame, so `popCount` is left **D ≈ 12,000–37,000 slots behind** where
it would have been — a permanent one-shot shift of the pop phase equal to the observed rung
displacement. D ≈ 12,352 slots is ≈ 475 frames of drift, i.e. **half an era**, so successive
events are iterates of a return map on the (push-wrap position, base) state, not a periodic
sequence at 3.04 s. On top of that every `fullRAM` excursion (§1a) injects a further ~16,240-push
jump and flips the push/pop `enb` phase parity (§4a). Deriving that map's return period requires
~150,000 frames of simulation (≈ 1.5·10^10 harness clk; the flat model runs at **4.4 kclk/s**
measured, so ~40 CPU-days) and is **not attempted here**. What can be said from the RTL is that
120.2 s is **not** any structural cadence, wrap or clock ratio in the TX plane — confirming
`TX_ORIGIN_TRACE_A.md` §3's negative result while replacing its arithmetic.

**Stall-onset positions.** The abort lands at the push-wrap position, which sweeps backwards
through the frame at 26 slots/frame; over the 947.69-frame era it sweeps the whole 24,640-slot
window once. Silicon's 5760–6550 symbols = 11,520–13,100 slots is 47–53 % of the frame — i.e. the
observed events cluster in a 1,580-slot band, only 6.4 % of the sweep, which the free-running
model does not explain either. The **128-slot (64-symbol) quantum is left unexplained**: 26 does
not divide 128 and there is no 128-slot structure on the mode-1 ROM path
(`TX_ORIGIN_TRACE_A.md` §4 already flags the tap3 offset-map word granularity as the alternative).

---

## 3. Sim demonstration — the abort fires with NO forced clear

Harness `jupiter_240k5_byte/rtl_sim/txrate_probe.cpp` (built by `build_txrate_sim.sh` /
`build_txrate_sim3.sh`, flat `--public-flat-rw` model of `wrap_byte_ddrcap` over
`s1_rtl_txmark`, mode-1 ROM, `tx_data_source=0`). Every force below is a **single write to one
register on one tick**, never repeated, and **nothing is written at or after the abort instant**.

### 3a. `fcbase3` — set only the frameCount BASE, then let the design abort itself [sim, PASS]

`beat_runs/txrate_fc3_frames.txt` (`./obj_txrate/Vtxrate 50 40 fcbase3 beat_runs/txrate_fc3`).
At frame 40, in the LOW window (the run aborts loudly if `frameCount` does not read 1 there),
one write `frameCount 1 -> 3` — the state the 947.69-frame drift reaches on its own. Then nothing:

```
# FORCE fcbase3 clk=3962664 frame=40 sampleCount=4001 frameCount 1 -> 3 (single tick, nothing else forced)
ZERO  clk=4041062 frame=40 posInFrame=94402 sampleCount=23600 prevFC=3 pushCount=0 popCount=23574 via=PUSHWRAP_3to0
ARMED clk=4041064 frame=40 posInFrame=94404 sampleCount=23601 1 -> 0 fc=0 d3=0
CEN frame=40 pushes=24666 pops=23575 armed=0   <- 1,065 pops lost, stall runs to the frame end
CEN frame=41 pushes=26822 pops=0     armed=0 fullRAM=1   <- whole extra frame stalled
ARMED clk=4143990 frame=42 sampleCount=0 0 -> 1
ZERO  clk=4148358 frame=42 posInFrame=4370 sampleCount=1092 prevFC=1 popCount=0 via=POPWRAP_1to0
ARMED clk=4148360 frame=42 1 -> 0
CEN frame=42 pushes=31171 pops=1066  armed=0
CEN frame=43 pushes=24666 pops=24639 armed=1   <- recovered
# SUMMARY zeroEvents=2 firstZeroFrame=40 armedDropClk=4041064 maxPopQuietClk=103032
```

**The abort fired 78,398 clk (0.79 frame) after the force, at a genuine unforced push-wrap**
(`pushCount` reaching 24,639 with `push`), `frameCount` 3→0, `Delay3_out1`→0, the `armed` latch
dropped two clk later and the pop strobe stayed quiet for **103,032 clk = 1.04 frames**. Both
routes to zero appeared: the primary `PUSHWRAP_3to0` at frame 40 and, one frame later, the
secondary `POPWRAP_1to0` (§3c).

**Negative control `fcbase2`** — identical run, identical instant, the single write is `1 -> 2`
instead of `1 -> 3` (base 2, pair 2↔3, zero unreachable): `beat_runs/txrate_fc2_frames.txt`,
`zeroEvents=0 armedDropClk=-1 maxPopQuietClk=0`, `armed` never leaves 1 over 53 frames. One
changed integer, opposite outcome.

### 3b. `phase2` — touch ONLY the producer pointer [sim, PASS]

`beat_runs/txrate_ph4_frames.txt`. No `frameCount` write at all: two single-tick writes of
`FSI.pushCount = 24639`, each placed in a frame that had *already* taken its natural push-wrap, so
each adds exactly one extra push-wrap — literally what the +26 slot/frame drift does by itself
every 947.69 frames:

```
# FORCE phase2 stage=0 frame=6 pushCount 4 -> 24639 (frame already wrapped at posInFrame=97938) fc=2
# FORCE phase2 stage=1 frame=8 pushCount 4 -> 24639 (frame already wrapped at posInFrame=97750) fc=3
ZERO  clk=887182 frame=8 posInFrame=97770 prevFC=3 via=PUSHWRAP_3to0
ARMED clk=887184 frame=8 1 -> 0
ZERO  clk=987742 frame=10 posInFrame=1002 prevFC=1 via=POPWRAP_1to0
```

The frameCount base ratchets +1 per extra push-wrap (fc reads 2 after the first force, 3 after the
second) and the ufix2 then wraps 3→0 on a push-wrap. Weaker than 3a as a *hands-off* demo (here
the zero lands on the forced wrap itself, 3 clk later), stronger as a demonstration that the
**producer phase alone** is sufficient. `SUMMARY zeroEvents=2 armedDropClk=887184
maxPopQuietClk=99664`; `kick_seq.py` (`beat_runs/txrate_ph4_offsets.txt`) gives offset **12208** at
frame 8 and 0 in the other 22 frames — the same "visible for one frame, then self-cancelled"
shape as 3a. (`beat_runs/txrate_ph2*` and `txrate_ph3*` are superseded dead ends of this
experiment, kept only for provenance: `ph2` repositioned the push-wrap inside a frame that had not
yet wrapped, which adds no wrap at all — it netted only +1 base from two forces; `ph3`'s
`pushCount<4000` guard was never satisfied and it never forced. Neither is a result.)

### 3c. What the demonstration also falsifies: the natural abort self-cancels to offset 0

Scored with the unmodified `kick_seq.py` against `two_jup/offsetmap/tap3_word_to_offset.tsv`
(`beat_runs/txrate_fc3_offsets.txt`, `txrate_fc2_offsets.txt`):

| run | per-frame offset sequence |
|---|---|
| `fcbase3` | 0 ×40, **11787** at frame 40, then 0 for frames 41–50 |
| `fcbase2` | 0 for all 52 frames |
| `phase2` | 0 ×8, **12208** at frame 8, then 0 for frames 9–22 |

So the abort is unmistakably visible (frame 40 jumps to a non-zero rung, the control never does),
but it is **not sustained** — unlike the artificial single-tick clear of `TX_KICK_SIM_B.md`, which
gave a permanent rung. The reason is structural and is a new result:

* the first abort (`3→0`) freezes `popCount` at q mid-frame;
* when pops resume, `frameCount` reads 1 (one push-wrap lifted it off 0), so the **first pop-wrap
  after the resume decrements 1→0 and aborts again** — and that pop-wrap is by construction
  exactly the completion of the frame the first abort interrupted;
* total pop deficit measured: 1,065 + 24,640 + 23,574 + 1 = **49,280 = exactly two whole frames**
  ⇒ displacement ≡ 0 (mod 12,320) ⇒ back to offset 0.

**What a sustained silicon rung would require — and the one candidate, already failing its first
test.** A partial-frame (visible, persistent) displacement requires the follow-on `POPWRAP_1to0`
to be suppressed, i.e. `frameCount` must reach **2** before that pop-wrap, which needs a *second*
push-wrap inside the stall. The only RTL mechanism that can produce two push-wraps in one frame is
the `fullRAM` runaway of §1a. **That candidate failed its first test in this very run**: frame 41
had `fullRAM=1` and `pushes=26822` (runaway active) yet `pushWraps` advanced 41 → 42 → 43 across
frames 40–42 — **+1 per frame, not +2**, because 26,822 pushes is barely more than one 24,640-push
wrap — and the second abort fired anyway. So this is a **conjecture with a failed first test**, not
the gate. **No mechanism producing a sustained rung is identified in this pass.**

---

## 4. Two secondary questions, answered from the RTL

### 4a. Why a stall is sometimes an ODD number of bit slots (§88's Q-one-symbol-late)

The delay imposed on the payload equals **D = the number of pops that did not happen**, in *bit*
slots. Two consecutive bits form one QPSK symbol, so an even D is a pure whole-symbol delay
(I and Q both shift by D/2 symbols) and an **odd D re-pairs the bit stream**: I keeps the
golden bit at symbol n while Q takes the bit that belonged to symbol n+1 — exactly §88's
"I-channel bit-exact at the predicted offset, Q-channel bit-exact one symbol later". [inferred,
from the pairing; the mapper is downstream of `Bit_Packetizer.bitsOut`]

D's parity is set by **which of the two `enb_1_2_0` phases the `armed` clear lands on**
[RTL fact]. Pops occur only on the phase where `Delay4_out1` is high
(`Data_Bits_FIFO.v:236-246,291`, off the divide-by-2 `HDL_Counter3` at `:164-188`), but the clear
is evaluated on **every** tick (`Data_Bits_FIFO.v:272-283` — the clear branch has no `enb`-phase
or `sampleCount` qualifier), so a clear landing on a pop phase kills one more pop than a clear
landing on the other phase.

**What sets that phase is not established [open].** The one natural abort measured here gave an
even D (1,065 + 24,640 + 23,574 + 1 = 49,280) and `kick_seq.py` returned a mapped offset, not
`None` — i.e. no I/Q skew — which is a single sample and settles nothing. No mechanism that flips
the parity is identified; in particular the `fullRAM` runaway does **not** do it reliably (§3c
shows it failing to change even the push-wrap count per frame).

### 4b. Why a stall sometimes continues for one whole extra frame (§87 frames 831/3126/5420)

Once `armed` drops, `pop` is 0, so **`popCount` stops** and can no longer wrap. `frameCount`
therefore *stays* at 0 across the frame boundary. At the next `sampleCount==0` the reload branch
(`Data_Bits_FIFO.v:284-287`) loads `Compare_To_Constant2_out1 = (Delay3_out1 != 2'b00)` — which
reads 0 — so **`armed` reloads as 0 and the entire next frame is stalled too**. The only escape is
the next *push*-wrap (`frameCount` 0→1), after which pops resume at the following
`sampleCount==0`. Hence:

* stall length D = (24,666 − p) + 24,666 slots when the push-wrap position p is such that the next
  push-wrap falls after that frame's `sampleCount==0` — the whole-extra-frame case;
* D = (24,666 − p) only if `frameCount` is lifted off 0 *before* the next `sampleCount==0`, which
  requires a second push-wrap inside the residue of the same frame.

**Measured [sim]:** in `txrate_fc3` the abort frame lost 1,065 pops and frame 41 had `pops=0` —
the whole extra frame, exactly as the RTL predicts. **What produces the 5-of-9 silicon cases with
*no* whole extra frame is not identified.** The obvious candidate (a `fullRAM` runaway supplying
the second push-wrap) was active in that very frame — `fullRAM=1`, `pushes=26822` — and still
delivered only **one** push-wrap (`pushWraps` 41 → 42 → 43 across frames 40–42), so it does not
explain them. Open.

---

## 5. Honest limits

* The 120.2 s / 110 s / 239.5 s rates are **not** reproduced. §2 gives 3.04 s / 6.09 s from the
  RTL numbers and states the discrepancy (39.5× / 18.1×) as a falsification of the free-running
  drift model as the *rate* mechanism. The trigger mechanism itself is demonstrated (§3).
* The 128-bit-slot rung quantum remains unexplained (26 ∤ 128).
* The clustering of silicon onsets in 5760–6550 symbols (6.4 % of the sweep) is unexplained.
* §1a's `fullRAM` runaway is a **new, separate defect** found in this pass. It destroys RAM
  content (16,256 bits over-written per excursion) every time occupancy crosses 49,280, which the
  free-running model says happens 3.04 s after every arm. It is not the beat, but any fix to the
  pop-abort must also guard this.
