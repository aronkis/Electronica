# COMB32 — desk RTL/netlist hunt for a 32-frame period

Date 2026-09-03 · desk only, no board contact · scope: `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`
(the built 148 lineage; every module cited is byte-identical in 146's tree under `jupiter_byte_tmr146_gates/`),
`host_app_k5/`, `two_jup/*.json` profiles, `two_jup/comb/baseline_20260903/`, `two_jup/beatcap/*_sel13/`.
Labels: **[netlist]** = read out of a built file at the cited line. **[measured]** = computed on this desk from
capture files already here. **[inferred]** = arithmetic or reasoning on top.

**Bottom line up front.** The only exact-32 arithmetic in the whole tree is a **modulus of 32 in a
domain where the frame length is odd or ≡ ±1**. Exactly two such structures could have existed: a
32-entry symbol-domain ring, and a 32-word / 256-byte boundary in the DMA path. I found both ends:

* the symbol-domain ring **exists and is unique** — `FIFO_block.v` (inside `Rate_Handle`, inside
  `Symbol_Synchronizer`) holds the **only mod-32 counters in the entire design**; they ARE full/empty
  guarded one level down (`Validate_Input_Push_Pop_block.v:119-137` — empty stalls a pop, full deletes
  a push) but never re-centred, and 12333 ≡ 13 (mod 32) puts their frame-relative phase on an exact
  32-frame cycle. *[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]*
* the 256-byte DMA boundary **does not exist**: every `axi_dmac` in the shipped image is
  `MAX_BYTES_PER_BURST = 128` (§2 #2) → 16 words → **16 frames**, and lag-16 is measured flat.

So the field is now one candidate wide. §4 reports a desk attempt to measure the ring's occupancy drift
from the sel13 captures; it finds no cumulative bias, but the observable is partly self-referential and
the captures drop records every 8188, so it **bounds but does not settle** the candidate. The
highest-value next action is a DDRCAP-v2 selector exporting `Push_Counter_out1 − Pop_Counter_out1`.

---

## 0. What "period 32" is a period *in*

**(a) The air-frame cadence is fabric-locked, exactly.** [measured]
`two_jup/comb/sro_sel13_desk/mark_drift.py` over `two_jup/beatcap/20260902_192051_sel13/{mid,onset}.bin`
(67.1 M records each) gives `mark_demod` and `mark_fec` spacing = **12333.000000 symbols**, least-squares
slope residual σ = 1.5e-9 symbols over 1889 frames. The fabric emits and recovers frames back-to-back at
a rigid 12333 symbols; host pacing does not enter (free-run filler model, cf. `tgen-instrument-usage`).

**(b) The comb's period in *host-seq* index is not integer-stable across runs.** [silicon, from the
baseline JSONs already on this desk — no new capture]

| capture | autocorrelation top peaks | implied period |
|---|---|---|
| `baseline_20260903/autocorr_rev2.json` | 32 (.699), 64 (.653), 96 (.606), 128 (.553) | **exactly 32** |
| `baseline_20260903/autocorr_fwd.json` | 32 (.698), 64 (.595), 127 (.534), 95 (.508), 96 (.502) | ≈ **31.8** |
| `baseline_20260903/autocorr_fwd_after.json` | 97 (.712), 65 (.670), 32 (.575), 33 (.416) | ≈ **32.3** |

The phase histograms agree: `phase_fwd.json` p = 1.4e-7 (argmax 0) but `phase_fwd_after.json`
p = 0.99999 (argmax 16) and `phase_rev2.json` p = 0.948 (argmax 25).
**There is no stable phase lock in host-seq index** — one significant run in three, a smooth ±5 %
undulation, wandering argmax. Correct reading [inferred]: the period is exact in *air* frames and is
smeared by ±1.5 % when re-expressed in *host-submitted* frames, because the host↔air frame-index
mapping is not 1:1 (host pacer ~1244 f/s against 1245.4 f/s of air capacity, and the delivered rate
wanders run to run — the logs show 960–1244 f/s).

> **What this does and does not prune.** It applies to *every* fabric candidate equally — TX byte plane,
> RX byte plane and symbol plane are all air-locked, so all of them inherit the same host-seq wander.
> It is therefore **not** a discriminator between the byte and symbol domains. (An earlier draft of this
> document claimed it excluded the byte plane; that was wrong and is retracted.) What it does establish
> is that the search target is a structure periodic in **32 air frames = 394,656 symbols = 1,578,624
> samples = 25.72 ms of fabric time**, and that arguing from the host-seq number 32 alone is unsafe.

**The beat rule** used throughout: a free-running mod-`M` counter advancing `L` steps per air frame
repeats its frame-relative phase every `M / gcd(L, M)` frames. Frame geometries:

| domain | frame length | note |
|---|---|---|
| symbols | 12333 = 3 × 4111 | **odd** |
| bit-slots | 24666 | 2 × odd |
| samples (4 sps) | 49332 | 4 × odd |
| 64-bit words, air (3080 B) | **385** = 5·7·11 | **odd**, and 385 ≡ 1 (mod 32) |
| 64-bit words, logical (1528 B) | **191** prime | **odd**, and 191 ≡ −1 (mod 32) |

All three geometries are odd in their natural word, so every power-of-two modulus beats at close to its
own value. **`12333 ≡ 13 (mod 32)`, gcd(13,32) = 1 → a mod-32 symbol-domain structure beats at exactly
32 frames.** **`385 ≡ 1`, `191 ≡ −1 (mod 32)` → a 32-word (256 B) boundary beats at exactly 32 frames on
*both* geometries.** Those are the only two ways to get 32.

Systematic width check — no counter *width* is commensurate with any frame length:

| 2^n | ÷12333 | ÷24666 | ÷49332 | ÷394656 | verdict |
|---|---|---|---|---|---|
| 2^16 = 65 536 | 5.31 | 2.66 | 1.33 | 0.166 | no |
| 2^20 = 1 048 576 | 85.03 | 42.51 | 21.26 | 2.66 | no |
| 2^22 = 4 194 304 | 340.1 | 170.1 | 85.03 | 10.63 | no |
| 2^24 = 16 777 216 | 1360.5 | 680.2 | 340.1 | 42.51 | no |

An exhaustive sweep of HDL-Coder counter moduli in the built RTL
(`grep -h "count to value  = " *.v | sort | uniq -c`) returns only: 1 (×11), **12332** (×4, = mod 12333,
frame-locked), 49279 (×2), **31** (×2, both in `FIFO_block.v`), 24665, 12319, 4096, 7, 3, 2.
**`FIFO_block.v` holds the only mod-32 counters in the design.**

---

## 1. Candidate table

### 1a. RX symbol/sample domain

| # | candidate | file:line | modulus / clock | period | verdict |
|---|---|---|---|---|---|
| A1 | **`Rate_Handle` FIFO push/pop counters** | `FIFO_block.v:113`, `:148` (`count to value = 31`), `:180` (`AddrWidth(5)`) | mod **32**, 16-bit-complex ring; push = symbol `strobe`, pop = `validIn & mod-4==0` | 12333 ≡ 13 (mod 32) → **32 frames exactly** | **MATCHES 32 EXACTLY** — the only mod-32 in the design; the ring IS full/empty guarded (`Validate_Input_Push_Pop_block.v:119-137`) — empty stalls a pop (no loss), full suppresses a push (deletes); §4 bounds but does not settle which edge is hit. *[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]* |
| A2 | `Rate_Handle` ring never flushed | `Rate_Handle.v:97` `Constant_out1 = 1'b0`; `:106` `.reset_1(Constant_out1)` | — | occupancy free-runs for the life of the link; guarded at both full and empty edges (`Validate_Input_Push_Pop_block.v:119-137`) — earlier text here read "no full/empty guard on either counter", which was wrong. *[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]* | supporting [netlist] |
| A3 | `Rate_Handle` rate divider | `Rate_Handle.v:66` `count to value = 3` | mod 4 samples | 49332 ≡ 0 (mod 4) → period 1 | no (it is what makes the pop cadence rigid) |
| A4 | `Phase_Ambiguity_Estimation_and_Correction` delay line | `Phase_Ambiguity_…v:56` `Delay_reg_re [0:31]` | 32-deep **tapped delay**, not a modular counter | no wrap event exists | no |
| A5 | `HDL_CMA_core` quadrant-control delay | `HDL_CMA_core.v:305` `DelayQC_Control_reg [0:31]` | 32-deep tapped delay | no wrap event exists | no |
| A6 | `Data_Bits_FIFO` counters / RAM | `Data_Bits_FIFO.v:103`, `:193`, `:296` (49279, 24665), `:335` `AddrWidth(16)` | frame-locked (24666 bits / 49280) | **1 frame** | no |
| A7 | `MATLAB_Function_block3` data-bit index | `MATLAB_Function_block3.v:962-966` (`indexCount == 24639`) | mod 24640 bits | 1 frame | no |
| A8 | `ByteSerializer` bit position | `ByteSerializer.v:253` `pos <= 32'd63` | mod 64 bits = 8 B; 3080 ≡ 0 (mod 8) | 1 frame | no |
| A9 | mod-4097 counter | `count to value = 4096` (1 instance) | mod 4097; 12333 ≡ 42, gcd 1 | 4097 frames | no |
| A10 | `Interpolation_Control` `countReg`/`mu` | sel13; `SRO_SEL13_DESK.md` §4 | mod 1024 | **0 wraps in 1.52 s**; \|SRO\| < 0.066 ppm | **CLOSED** — not re-opened here |

### 1b. Byte / delivery plane

| # | candidate | file:line | modulus | period | verdict |
|---|---|---|---|---|---|
| B1 | `ByteRxFifo` ring | `ByteRxFifo.v:64` `mem [0:63]` (64 × 64-bit = 512 B) | mod 64 words; 191 ≡ −1 (mod 64) | **64 frames** | **near miss** — cannot produce a lag-32 peak; kept as §2 #3, a possible *separate* comb |
| B2 | `ByteRxFifo` ready-run guard | `ByteRxFifo.v` (`rdyRun >= 8'd6`) | 6 cycles | not frame-related | no |
| B3 | `ByteWordBuffer` state buffer | `ByteWordBuffer.v:53` `state_buf [0:15]` (16 × 64-bit = 128 B) | mod 16 words; 385 ≡ 1 (mod 16) | **16 frames** | **no** — and measured out: autocorr lag 16 = **0.145** (all-loss) / **−0.042** (singles) against 0.70 at lag 32 |
| B4 | a 32-word / 256 B DMA burst boundary | — | would be mod 32 words; 385 ≡ 1, 191 ≡ −1 | would be **32 frames exactly, on both geometries** | **NO — settled on desk. Every `axi_dmac` in the shipped image is `MAX_BYTES_PER_BURST = 128` (B7).** |
| B7 | **`axi_dmac` burst boundary (actual)** | `jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.srcs/sources_1/bd/system/ip/system_{rx,tx}_byte_dma_0/*.xci` — `"MAX_BYTES_PER_BURST": 128`, `DMA_DATA_WIDTH_SRC/DEST: 64` (identical on all six DMAs: rx1/rx2/tx1/tx2/rx_byte/tx_byte) | 128 B = **16** 64-bit beats; 385 ≡ 1, 191 ≡ −1 (mod 16) | **16 frames** | **no** — and lag-16 autocorrelation is flat (0.145 / −0.042) |
| B8 | `axi_dmac` internal store-and-forward FIFO | same `.xci`, `"FIFO_SIZE": 8` (units of MAX_BYTES_PER_BURST) → 8 × 128 B = 1024 B = 128 words | mod 128 words; 385 ≡ 1, 191 ≡ 63 (gcd 1) | **128 frames** | no — but note lag 128 = 0.553 in `autocorr_rev2` |
| B9 | `sample_discard_controller`, `Packet_Controller` | `sample_discard_controller.v` (215 lines, no counter), `Packet_Controller.v:57,61` (`[3:0]` delay regs only) | none | — | no — neither module holds a modular counter |
| B5 | `RAM_Frame_Status_Indicator` frame counter | `RAM_Frame_Status_Indicator.v:43` `reg [1:0] frameCount` | mod **4** frames | 4 frames | no |
| B6 | `FrameStatProbe` window | `FrameStatProbe.v:192` `pktCnt & 32'd255` | mod **256** frames | 256 frames | no — instrument only |

### 1c. Host daemon (`host_app_k5/qpsk_tun.c`) — the class already falsified on silicon (`COMB_STATE.md:36`)

| # | candidate | file:line | period | verdict |
|---|---|---|---|---|
| H1 | TX batch `n * tx_xfer_bytes` MM2S transfer | `qpsk_tun.c:895-896`, `:932`; `TX_BATCH 8` `:878`; `QPSK_TX_BATCH_STRIDE 16384u` `qpsk_hw.h:147` | **n = 16384 / 3080 = 5** frames per transfer — that is the `n` in the question | no (5) |
| H2 | TX slot ring | `qpsk_hw.h:152` `QPSK_TX_SLOTS 8u`; `qpsk_tun.c:920` `tx_slot % TX_SLOTS` | 8 batches = **40 frames** at n=5 (8 frames at n=1) | near miss (40), not 32 |
| H3 | RX cyclic ring wrap | `qpsk_tun.c:1258` `(2u*64*2048)/1528` | **171 frames** | no |
| H4 | RX queued transfer boundary (`-M`) | `qpsk_tun.c:1202-1209` `span * pkt_bytes` | = `-M` frames (16 / 8) | **no — falsified on silicon**: halving `-M` on either board left the comb at 32 |
| H5 | seq plausibility window | `qpsk_seq.h:38` `QPSK_SEQ_WINDOW 64` | 64 frames | no — a range test, not a periodic process |
| H6 | ARQ re-NAK timer | `qpsk_tun.c:1967` `axr_renak = 64u` rx_ticks | 64 validated rx frames | near miss (64); ARQ is off on these legs |
| H7 | ARQ hole table / history ring | `qpsk_tun.c:1965` `axr_hole_sz = 512u`, `:1845` `HIST_SZ 1024u` | 512 / 1024 frames | no |
| H8 | ARQ gap clamp | `qpsk_tun.c:1968` `axr_gap_clamp = 128u` | 128 frames | near miss (128 is a comb harmonic); ARQ off | 
| H9 | stats window, tun read, `rx_tick` | 1 s stats line; `rx_tick` advances per validated rx frame (`qpsk_tun.c:1871`) | ~1244 frames | no |

### 1d. ADRV9002 profile — no periodic process of any kind

`two_jup/lvds_61p44_fdd_jupiter.json` (and `lvds_61p44_jupiter.json`) contain **no** tracking-cal interval,
AGC timer, DC-offset/QEC update-rate or LVDS/SSI-resync period field. The profile carries rates
(`rx…rxOutputRate_Hz` / `tx…txInputRate_Hz` = 61 440 000), `lnaConfig` settling/delay values that are all
`0`, gain-table selects and PFIR coefficients only; tracking cals are armed through a separate API mask
that is not in this file. **Verdict: no — nothing at 25.7 ms / 38.9 Hz.**

---

## 2. Ranked mechanisms

### #1 — `Rate_Handle`'s 32-deep, never-flushed, **guarded** rate FIFO  [netlist; the only mod-32 in the design]

> **[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]** This section originally called the ring
> "unguarded" and said both edges lose data. That is wrong. `Validate_Input_Push_Pop_block.v:119-137`
> implements an exact 6-bit occupancy counter (`MATLAB_Function_block2.v:86-136`, empty = 0, full = 32)
> with `pop_on_empty_FIFO` and `push_on_full_FIFO` guards: the EMPTY edge suppresses a pop (a skipped
> output valid slot, no data loss); only the FULL edge suppresses a push (the one place this ring
> deletes a symbol). See `RATE_HANDLE_FIX_SURVEY.md` §0-§1 for the full citation chain. The description
> below is retained for the never-flushed / free-running-occupancy argument, which still stands, but
> "no full/empty guard" and "both edges lose data" should be read as guarded / full-edge-only.

`Symbol_Synchronizer` → `Rate_Handle` → `FIFO_block` is a 32-entry circular buffer of 16-bit complex
samples. Push is the irregular interpolator symbol `strobe`; pop is `validIn & (mod-4 counter == 0)`, a
rigid one-in-four-samples cadence (`Rate_Handle.v:66,86-95`). Both pointers wrap at 31 independently
(`FIFO_block.v:113,148`, `AddrWidth(5)` at `:180`); the ring IS full/empty guarded one level down
(`Validate_Input_Push_Pop_block.v:119-137` — see correction note above), and `reset_1` is tied to
constant `0` (`Rate_Handle.v:97,106`) so the ring is **never re-centred** after the initial reset —
occupancy = (push − pop) mod 32 free-runs for the life of the link, guarded at 0 and 32. An exhaustive
sweep of every HDL-Coder counter modulus in the built design returns mod-32 **only here** (§0).

Because 12333 ≡ 13 (mod 32) with gcd 1, the frame-relative phase of any occupancy wrap steps by 13
entries per air frame and returns every **32 frames exactly** — matching the fundamental, the 64/96/128
harmonics, the identical behaviour on both legs (same module, byte-identical in the 146 `tmr` tree),
independence from every host knob, and the §0(b) host-seq wander (the ring runs on the fabric symbol
clock, so it inherits the air↔host-seq mapping wobble). A wrap landing in the 26-slot preamble/header
window corrupts the header rather than a few payload symbols, which is the natural account of the
**84 % garbage-header** share — an observable this mechanism was not fitted to.

*Two open joints, both stated as assumptions:*
1. It sits inside the clean internal loopback path (1 bad in 817 k). The escape is that a noiseless,
   jitter-free loopback strobe never lets occupancy walk. Plausible, **unverified**.
2. §4's desk measurement finds no cumulative push/pop bias — but the observable is partly
   self-referential and the usable windows are 0.2 frames long, so it bounds rather than settles.

**Confirming observable.** Nothing currently exported carries occupancy. The ask is a DDRCAP-v2 selector
exporting `FIFO_block.Push_Counter_out1 − Pop_Counter_out1` (5 bits, one nibble of a ch2/ch3 field)
alongside the existing `mark_demod`. Prediction: occupancy walks and wraps mod 32, and each wrap
coincides within one frame with a loss onset; the losses' phase mod 32 locks to the wrap phase in
*air*-frame index (not host-seq — §0). Falsifier: occupancy is static or wraps at a period other than
~32 frames.

### #2 — The `axi_dmac` burst geometry, now **settled on desk and negative**  [netlist]

Recorded as a ranked entry because it was the other exact-32 arithmetic and it is now closed. Every
`axi_dmac` instance in the shipped image — `rx1`, `rx2`, `tx1`, `tx2`, **`rx_byte`, `tx_byte`** — carries
`MAX_BYTES_PER_BURST = 128` and `DMA_DATA_WIDTH_SRC/DEST = 64`
(`jupiter_byte_txfixF3_build/…/bd/system/ip/system_rx_byte_dma_0/*.xci:35`, and the same line in each of
the other five). 128 B = 16 × 64-bit words. With 385 ≡ 1 and 191 ≡ −1 (mod 16) the burst boundary walks
by exactly one word per frame and returns every **16 frames** — and lag 16 is measured **flat**
(0.145 all-loss, −0.042 singles, against 0.70 at lag 32). A 256 B burst would have been 32 beats on this
bus and would have given exactly 32 on *both* frame geometries; it is not what is built. **The 256-byte
hypothesis is dead, on the netlist, with no board contact.**

`FIFO_SIZE = 8` (8 × 128 B = 1024 B = 128 words) gives **128 frames**, which is a comb harmonic
(lag 128 = 0.553 in `autocorr_rev2`) and worth remembering, but is not the fundamental.

### #3 — `ByteRxFifo`'s 64-word ring, as a *second, separate* comb at 64  [netlist + inferred]

`ByteRxFifo.v:64` is 64 × 64-bit = 512 B and the logical frame is 191 words, 191 ≡ −1 (mod 64), giving a
frame-relative phase that returns every **64 frames**. This cannot be the fundamental — lag 32 is the
largest peak in every capture — but `autocorr_rev2` puts lag 64 at **0.653**, high for a pure harmonic of
a 32-comb, so a superposed 64-frame component is consistent with the data and would be the residue of the
known S2MM-boundary defect (memory: `comb-is-receiver-sro-defect`).

**Confirming observable:** `ByteRxFifo` already exports `ovfCnt` on its `ovf` port (`ByteRxFifo.v:35`
port list, `:64-77` counter). Read it per-frame from the host log alongside the loss series; 64-frame-
strided overflow events coexisting with the 32-comb means two defects and two fixes, not one.

---

## 3. What this rules out

- **The SRO reading** — closed by `SRO_SEL13_DESK.md` (|SRO| < 0.066 ppm, 0 interpolator wraps). Not re-derived.
- **A 256 B / 32-word DMA boundary** — **closed on the netlist**: all six `axi_dmac` instances are 128 B (§2 #2).
- **Every host-daemon period** — none is 32 (§1c); P1/P1b already falsified the class on silicon; the `n` in `n * tx_xfer_bytes` is **5** (16384 / 3080).
- **The ADRV9002 profile** — contains no periodic-process field at all (§1d).
- **`ByteWordBuffer`, the 128 B DMA burst, and the whole 16-frame family** — arithmetic gives 16, and lag-16 autocorrelation is flat.
- **Every counter width `2^n`** — none is commensurate with 12333 / 24666 / 49332 / 394656 (§0 table).
- **`sample_discard_controller` and `Packet_Controller`** — neither contains a modular counter at all.
- **The earlier "the host-seq wander excludes the byte plane" argument** — retracted in §0; the byte plane is air-locked too, and inherits the same wander.

---

## 4. Desk measurement: `Rate_Handle` occupancy drift  [measured, 2026-09-03 — bounds, does not settle]

Method (reproducible, no board contact): decode `two_jup/beatcap/20260902_192051_sel13/{mid,onset}.bin`
with `two_jup/ddrcap2_decode.py`. `I[15]` is `underflow_sticky`, the interpolator symbol strobe = the
`Rate_Handle` **push**; sel13 is a full-rate enb-domain tap at 4 records/symbol, so one pop falls every
4 records. Occupancy drift over a span = `strobes − records/4`. The rx2 DMA drops records in bursts, so
the span is split into drop-free runs identified by `tref` (the in-record mod-12333 symbol counter)
advancing by exactly 1.

| file | drop-free runs | median run | records analysed | Σ drift | drift rate |
|---|---|---|---|---|---|
| `mid.bin` | 32 765 | 2048 rec | 67 108 863 | **+27.25** | +1.6e-6 /symbol |
| `onset.bin` | 32 765 | 2048 rec | 67 108 862 | **−49.5** | −3.0e-6 /symbol |

Per-run drift never exceeds ±2 entries and is quantised to ±0.25/±0.5 (run-boundary phase artefacts), so
quantisation alone random-walks to ≈ ±90 over 32 765 runs: **+27 and −50 are inside that noise, and the
defensible statement is that no cumulative push/pop bias is observable.** Supporting:
`strobes-between-consecutive-tref` is 1 in 93.6 % of intervals with the residue split symmetrically
3176 × 0 against 3175 × 2 — a ±1-record dither that balances, i.e. no cumulative bias at the sample level.

**Three limits, stated plainly so nobody re-runs this expecting more:**
1. **The observable is partly self-referential.** sel13's records *are* the enb-domain sample stream, so
   "pop = records/4" is counted against the same clock the push is counted against — this is the same
   class of trap `SRO_SEL13_DESK.md` §4 flagged for `mu`. It measures strobe-rate vs record-rate, which a
   tracking loop holds flat by construction.
2. **The usable windows are 0.2 frames long.** The rx2 DMA drops records every **8188** records
   (longest drop-free run in the whole 67 M-record file: 8188 records = 0.2 frames). **No per-frame
   quantity can be counted from these captures at all** — the "strobes per frame should be 12332/12334 at
   a wrap" test is *not runnable* on this data. Do not attempt it.
3. Therefore a wrap rate of one per 32 frames is excluded **only if** the drift is genuinely unbiased at
   scales longer than a run. Taking the raw figures at face value gives ≥ 890 frames per wrap; on the
   noise bound, ≥ 520 frames.

**Verdict: no supporting drift measurable on desk; the candidate is bounded, not falsified.** Settling it
needs the occupancy tap named in §2 #1.
