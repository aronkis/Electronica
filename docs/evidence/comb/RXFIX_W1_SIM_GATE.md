> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_W1_SIM_GATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX_W1 — sim gate  [sim]

Task 9, 2026-09-04. Gate for the RXFIX_W1 silicon instrument
(`two_jup/skidfix/rxfix_inject.py` variant `W1`; register map
`two_jup/rxfix/W1_REGMAP.md`). Everything below is **[sim]** — no board contact.

## 0. What is being gated, and what these legs can and cannot say

W1 is a read-only instrument. Two properties have to hold:

1. **It does not disturb the receiver.** Gated by a byte-for-byte diff of the
   delivered byte-plane frame stream between a W1 build and a baseline build of
   the *same* wrapper on the *unpatched* tree.
2. **Its eight registers report the truth.** Gated against an INDEPENDENT
   reference computed in the driver from the raw hierarchical taps
   (`occTrue`, `fifoPush/Pop`, `pop_on_empty_FIFO`, `push_on_full_FIFO`, and the
   six stage valids), on **every `enb_1_2_0` beat** of the leg — not only at the
   logged per-frame rows. A one-beat hole event cannot slip between samples.

What these legs cannot say: nothing about the AXI decode itself. The Verilator
lineage (`jupiter_240k5_byte/s1_rtl/…`) has no `TxRxCompo_ip_*` wrapper, so the
harness reads `QPSK_Rx.w1Bus` and slices it exactly as
`TxRxCompo_ip_addr_decoder.v` does. The decoder is covered by the injector unit
tests (`test_50`) and by Vivado elaboration, not here. Stated, not hidden.

## 1. Harness

| file | role | note |
|---|---|---|
| `jupiter_240k5_byte/rtl_sim/wrap_byte_w1.v` | wrapper | NEW. `wrap_byte_sro.v` is Task 7's and had live legs running out of `obj_byte_sro`; nothing here touches it or that obj dir |
| `jupiter_240k5_byte/rtl_sim/sim_w1.cpp` | driver | NEW |
| `jupiter_240k5_byte/rtl_sim/build_sro_w1.sh` | `w1` → `obj_byte_w1` (patched tree, `+define+RXFIX_W1`); `base` → `obj_byte_w1_base` (unpatched `s1_rtl`) | |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_W1/` | the patched Verilator tree | `rxfix_inject.py … W1 --sim-tree`, 8 files |
| `sim_w1_census.cpp` / `build_w1_census.sh` | standalone unit test of `rh_w1_census`, extracted VERBATIM from the patched FTS on every build | the only place freeze is exercised in RTL |

**Sampling convention** (the one subtlety): a Verilator tap read after tick *k*
carries the POST-edge value, while the counter that ticked on edge *k* used the
PRE-edge value; and the W1 shadow lags its live counter by one `enb` beat.
Composing the two, the shadow read at beat *k* equals the sum of the taps as
sampled at beats 1…*k−1*. The driver therefore advances its reference by the
PREVIOUS beat's taps. There is no fudge factor: any residual difference is a real
instrument fault.

## 2. Freeze — RTL unit test (`obj_w1_census/Vrh_w1_census`)

Freeze cannot be driven through the full DUT on this lineage: `s1_rtl`'s
`QPSK_Rx` has no `fixctl` port at all (it predates it), so the injector ties
`w1_freeze` to `1'b0` there and uses `fixctl[4]` on the flashed lineage. The
freeze semantics are therefore gated on the extracted module instead.

| test | what it pins | result |
|---|---|---|
| T1 | reset clears every output | ok |
| T2 | a beat with `enb = 0` counts nothing | ok |
| T3 | each of the six valids drives its own counter and no other (3/5/7/11/13/17) | ok |
| T4 | `witA` packing; **occ = 32 and occ = 0 are distinct words** (the defect `BeatObs` and `sim_sro.cpp:115` both have) | ok |
| T5 | `witB` = `{pushFullCount, popEmptyCount}` | ok |
| T6 | **FREEZE**: every shadow holds across 50 counted beats and jumps to the live value on release; `witA` too | ok |
| T7 | the 16-bit edge counters WRAP rather than saturate (so deltas stay valid) | ok |

`W1CENSUS_UNIT PASS failures=0` (21 assertions).

## 3. Legs

### 3.1 The four legs

All four use the tiled stimuli Task 6/7 already have on disk, replayed at the
standard cadence 2 / vphase 0 with the standard `rstcs_end = 8400`, at the FULL
file length. `w1` = `obj_byte_w1` (patched tree); `base` = `obj_byte_w1_base`
(unpatched `s1_rtl`, same wrapper, W1 ports tied to 0 by `ifdef`).

| leg | stimulus | nsamp | air frames | delivered | enb beats compared | mismatches | verdict |
|---|---|---|---|---|---|---|---|
| `w1_p000` | `s_p000.iq` (0 ppm) | 8,139,780 | 165 | 164 | **8,239,781** | **0** | PASS |
| `base_p000` | `s_p000.iq` | 8,139,780 | 165 | 164 | 8,239,781 | n/a | SKIP (baseline) |
| `w1_m10` | `s_m10.iq` (−10 ppm, tiled) | 10,359,720 | 211 | 209 | **10,459,721** | **0** | PASS |
| `base_m10` | `s_m10.iq` | 10,359,720 | 211 | 209 | 10,459,721 | n/a | SKIP (baseline) |

### 3.2 Gate A — the data path is untouched at 0 ppm (and at −10 ppm too)

| pair | delivered frames | md5 of `_deliv.txt` | result |
|---|---|---|---|
| `base_p000` vs `w1_p000` | 164 | `555fbb25362f14a3d36b60f6797152af` (both) | **byte-identical** |
| `base_m10` vs `w1_m10` | 209 | `91680b59e9cebdae3b285953fea203ef` (both) | **byte-identical** |

The 0 ppm identity is the gate the brief asked for. The −10 ppm identity was not
required and is reported because it is free and stronger: the instrument does not
perturb the receiver even on a leg that reaches a ring edge.

### 3.3 Gate B — the eight W1 words equal the harness taps

End-of-leg totals, W1 register value vs independent reference:

| leg | `cSS` | `cRH` | `cCFC` | `cCS` | `cPD` | `cPC` | `witA` | `witB` |
|---|---|---|---|---|---|---|---|---|
| `w1_p000` ref | 2,059,920 | 2,059,920 | 2,059,912 | 2,059,909 | 2,047,585 | 2,020,480 | occ 0, push 16, pop 16 | poe 16, pof 0 |
| `w1_p000` W1 | 2,059,920 | 2,059,920 | 2,059,912 | 2,059,909 | 2,047,585 | 2,020,480 | `0x00000210` | `0x00000010` |
| **`w1_m10` ref** | **2,614,900** | **2,614,900** | **2,614,892** | **2,614,889** | **2,602,549** | **2,574,481** | **occ 0, push 20, pop 20** | **poe 21, pof 0** |
| **`w1_m10` W1** | **2,614,900** | **2,614,900** | **2,614,892** | **2,614,889** | **2,602,549** | **2,574,481** | **`0x00000294`** | **`0x00000015`** |

Exact on every word on both legs, and exact on **every one of the 10,459,721 enb
beats** of the −10 ppm leg, not merely at the end.

**The −10 ppm leg reaches the ring's EMPTY edge, which is what makes it the
non-vacuous one.** `pop_on_empty` first fires at air frame 41 and reaches 21 by
end of leg — `w1gate/w1_m10_w1.txt` shows the reference and the W1 register moving
together through every one of those events (frame 41 `poe_ref=1, poe_w1=1`; frame
73 `5, 5`; end of leg `21, 21`), with the occupancy field draining to 0 exactly as
`gen_sro_stim.py`'s sign convention and the survey's §1 predict.

`push_on_full` is **0 on both legs** — the tiled stimulus at negative ppm drains
toward EMPTY and never reaches FULL, so the FULL-edge counter is **not exercised
RTL-in-loop by these legs**. It is covered by the unit test (T5 above) and by
construction (the same 16-bit counter on the sibling event). Stated plainly rather
than implied by the clean verdict.

### 3.4 What the numbers say about the receiver (incidental, not the gate)

The census itself is already informative on the stimuli in hand: at 0 ppm
`cSS − cRH = 0` and `cCS − cPD = 12,324` (the Preamble_Detector pipeline depth),
`cPD − cPC = 27,105`; the six deltas move together. Nothing here is a silicon
claim — these are Verilator legs on tiled stimuli, the very thing Task 7 put in
doubt. The instrument's job is to make the same reading on the board.


## 4. Verdict

**GATE PASSED.**

| requirement (brief item 3) | result |
|---|---|
| at 0 ppm the data path is byte-identical to baseline | **PASS** — `_deliv.txt` identical, md5 `555fbb25362f14a3d36b60f6797152af`, 164 frames |
| witness words read back equal to the harness taps (occupancy, pop_on_empty, push_on_full) | **PASS** — exact on all 8,239,781 + 10,459,721 compared beats |
| per-stage valid counts equal to the harness taps | **PASS** — same |
| over a tiled −10 ppm leg with edge events present | **PASS** — `pop_on_empty` = 21 (> 0), first event at air frame 41 |
| exit-gated scoring | the driver returns non-zero on any mismatch; all four legs returned 0 |

Caveat carried forward, not buried: `push_on_full` stayed 0 on every RTL-in-loop
leg (these stimuli drain to EMPTY), so the FULL-edge half of `witB` is gated only
by the unit test. And the AXI decode is not exercised here at all — the Verilator
lineage has no `TxRxCompo_ip_*` wrapper; it is covered by `test_50` and by Vivado
elaboration.

