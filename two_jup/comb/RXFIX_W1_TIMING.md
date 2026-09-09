# RXFIX_W1 — routed timing diagnosis  [netlist]

Task 9b, 2026-09-04. Read-only inspection of the Task 9 Vivado build on hdl-dev-2
(`/home/tcollins/qpsk-builds/jupiter_byte_rxfixw1_build/`), compared against the
SEQ-BIST build beside it (`jupiter_byte_seqbist_build/`, the lineage that produced
the flashed 148 image `a1ff3c876d91`).

**No Vivado was launched and nothing in either build directory was modified.** Every
number below is read out of files the build itself wrote.

---

## 0. Headline — the premise of this task is stale, and the headline WNS is a red herring

The Task 9b brief was written while the router was at global iteration 1 with
"WORSENING intermediate timing". **The build has since completed and met timing.**

```
INFO: [Route 35-61] The design met the timing requirement.
INFO: [Route 35-20] Post Routing Timing Summary | WNS=0.071 | TNS=0.000 | WHS=0.009 | THS=0.000
TXFIX_ROUTED_WNS wns=0.071224 tns=0.000000
TXFIX_BUILD_DONE variant=F3 md5=2728dab3979a54616f1ad67f1ac8e8a7 wns=1.544
```

Finished 16:18:20, 0 errors, 0 critical warnings.

More important than that: **the reported WNS of both builds is not a modem path at
all, so the "+0.112 → +0.071" comparison in the brief compares the wrong number.**
In both builds the overall WNS is the *same vendor reset-recovery path*:

| | W1 | SEQ-BIST |
|---|---|---|
| Slack | 0.071 ns | 0.112 ns |
| Source | `axi_adrv9001/inst/i_core/i_delay_cntrl_rx1/i_delay_rst_reg/rst_reg/C` | *identical* |
| Destination | `axi_adrv9001/inst/i_if/i_rx_1_phy/i_serdes/i_delay_ctrl/RST` | *identical* |
| Path group | `**async_default**` (Recovery, `clk_pl_2`, 2.000 ns) | *identical* |
| Logic levels | **0** | **0** |
| Data path delay | 1.355 ns (logic 0.079, route 1.276) | 1.318 ns (logic 0.079, route 1.239) |

It is a **zero-logic-level, two-node reset net inside the ADRV9001 vendor IP**, on
the 500 MHz PS clock, with no connection to the modem IP whatsoever. The entire
0.041 ns "loss" is 0.037 ns of extra route delay on that one vendor net — placement
noise, not a consequence of W1. Nothing can be hardened in W1 that would move it.

**The number that actually matters for W1 is the modem clock's intra-clock WNS:**

| `axi_adrv9001_adc_1_clk` (8.000 ns) | W1 | SEQ-BIST | Δ |
|---|---|---|---|
| WNS | **0.169 ns** | **0.227 ns** | **−0.058** |
| TNS / failing endpoints | 0.000 / 0 | 0.000 / 0 | — |
| WHS | +0.009 | +0.010 | −0.001 |
| Total endpoints | 184,782 | 183,608 | +1,174 |

So W1 costs the modem clock **0.058 ns**, and closes with 0.169 ns in hand.

---

## 1. The question the brief asked: is it W1 logic, or pre-existing paths?

**Answer: pre-existing paths, made worse by placement pressure. Not W1 logic.**

The single strongest piece of evidence:

> **Not one W1 net appears anywhere in the routed timing summary report.**
>
> ```
> grep -c "w1_reg\|rh_w1_census\|w1_bus\|w1Bus\|w1_cSS\|u_rh_w1" system_top_timing_summary_routed.rpt
> 0
> ```

That report is `report_timing_summary -max_paths 10 -routable_nets
-report_unconstrained` — the ten worst paths of **every** path group and **every**
clock pair, 8.0 MB of them. The AXI read mux, the six 32-bit counters, the census
taps, the occupancy word and the 256-bit `w1Bus` are all absent from every one of
them.

### 1.1 What the modem clock's worst path actually is

W1's worst modem path (slack **0.169 ns**, 12 logic levels, **83 % route delay**):

```
Source:      .../u_Receiver/u_Capture_Data_Bits/delayMatch_reg_reg[0]/C
  -> u_QPSK_Rx/u_FEC_Decoder_Wrapper/u_RxDeint/delayMatch_reg_reg_n_0_[0]_alias
  -> u_QPSK_Rx/u_FEC_Decoder_Wrapper/u_RxAlign/frameStart_1        (fo=34)
  -> u_QPSK_Rx/u_FEC_Decoder_Wrapper/u_RxAlign/startOut_last_value_i_2_n_0
  -> u_FrameStatProbe/rec_r_reg[45]_0                              (fo=31)
  -> u_FrameStatFifo/mem_reg[16][51]_0                             (fo=95)
  -> u_FrameStatFifo/wr_temp[13]
  -> u_FrameStatFifo/rd[15]_i_16_n_0
  -> u_FrameStatFifo/rd_temp1                                      (fo=50)
  -> u_FrameStatFifo/rd_temp[2]                    (fo=466, 1.618 ns route!)
  -> MUXF7 -> u_FrameStatFifo/delayMatch37_reg_reg[0][5]_i_7_n_0
Destination: .../u_TxRxCompo_ip_src_TxRxComposite/delayMatch37_reg_reg[0][5]/D
Data Path Delay: 7.703ns  (logic 1.321ns 17.2%, route 6.382ns 82.8%)
```

Every cell on it is **pre-existing**: the FEC deinterleaver/aligner and the
FrameStat probe/FIFO. The dominant single term is a **1.618 ns route on a fanout-466
net** (`u_FrameStatFifo/rd_temp[2]`). This is a congestion-limited, high-fanout
pre-existing path.

SEQ-BIST's worst modem path is a **different path entirely** (slack 0.227 ns,
25 logic levels, a 5-deep CARRY8 chain):

```
Source:      i_system_wrapper/system_i/tx_checker/inst/fill_reg[3]/C
Destination: i_system_wrapper/system_i/tx_checker/inst/bit_errors_reg[31]/D
```

i.e. the SEQ-BIST checker's own bit-error accumulator.

**The ranking changed, the path did not degrade in place.** The
`Capture_Data_Bits → FrameStatFifo/delayMatch37` family appears **7 times** in W1's
ten worst modem paths and **0 times** in SEQ-BIST's — it was not among SEQ-BIST's
ten worst at all. W1's extra cells pushed a pre-existing route-dominated path up
past the checker's logic-dominated one.

### 1.2 Corroboration from synthesis — W1 adds no logic depth

Post-synthesis, at the real 8.000 ns constraint, **both builds report identical
numbers**:

| | W1 | SEQ-BIST |
|---|---|---|
| `TIMING_GATE_WNS modem_dut` | **1.544** | **1.544** |
| `overall` | **−1.119** | **−1.119** |

`timing_gate.tcl:73-75` scopes `modem_dut` as
`get_timing_paths -setup -to [get_cells -hierarchical -filter {NAME =~ *TxRxCompo_ip_0*}]`
— **paths ending anywhere inside the modem IP, which includes
`TxRxCompo_ip_addr_decoder` and hence the AXI read mux.** So this identity is not a
scoping artefact: it says that post-synthesis, every W1-added path — read mux,
counters and census taps alike — has **≥ 1.544 ns of slack**. W1 adds no logic
depth. The 0.058 ns appears only after placement.

### 1.3 The mechanism: congestion

| | W1 | SEQ-BIST |
|---|---|---|
| `[Route 35-445]` CLBs with high **pin** utilisation | **74** | **58** |
| `[Route 35-443]` CLB **routing** congestion events | 1 | 1 |

+16 congested CLBs (+28 %). With the worst modem path already 83 % route delay,
that is a sufficient mechanism for 0.058 ns without any W1 cell being on the path.

### 1.4 The router excursion in the brief was normal

| stage | W1 | SEQ-BIST | Δ |
|---|---|---|---|
| post-synth `modem_dut` | 1.544 | 1.544 | 0.000 |
| Post Placement | 0.179 | 0.269 | −0.090 |
| Post Physical Optimization | 0.474 | 0.564 | −0.090 |
| Route, pre-iteration | 0.451 | 0.541 | −0.090 |
| Route global iteration 0 | **−0.317** | **−0.021** | — |
| Route global iteration 1 | **−0.598** | +0.031 | — |
| Route global iteration 2 | +0.071 | +0.112 | — |
| Route global iteration 3/4 | +0.071 | +0.112 | — |
| **Post Routing (final)** | **+0.071** | **+0.112** | −0.041 |

The negative excursions the brief reacted to are **intermediate states with
unresolved node overlaps**, printed before the router has legalised the design.
SEQ-BIST went negative at iteration 0 too (−0.021). W1's excursion is deeper,
consistent with its higher congestion, and it recovered at iteration 2 exactly as
SEQ-BIST did. **An intermediate `WNS` from `[Route 35-416]` is not a prediction of
the final result and should not be used as a gate.**

The uniform, invariant **−0.090 ns** at all three pre-route milestones is the
placement-quality cost; the router then recovered part of it in both builds.

---

## 2. Utilisation delta

### 2.1 Post-implementation (authoritative) — `system_top_utilization_placed.rpt`

| resource | W1 | SEQ-BIST | Δ |
|---|---|---|---|
| **CLB LUTs** | 47,242 | 47,120 | **+122** |
| **CLB Registers** | 110,473 | 109,761 | **+712** |
| LUT as Logic | 41,571 | 41,470 | +101 |
| LUT as Memory | 5,671 | 5,650 | +21 |
| CARRY8 | 1,583 | 1,555 | +28 |
| F7 Muxes | 1,277 | 1,250 | **+27** |
| F8 Muxes | 150 | 150 | 0 |
| Block RAM Tile | 66.5 | 66.5 | **0** |
| DSPs | 178 | 178 | **0** |
| **CLB (occupied)** | **8,820 / 8,820 = 100.00 %** | **8,820 / 8,820 = 100.00 %** | 0 |

These `+122 / +712` are the numbers to quote as W1's cost on the device.

**The last row is the whole congestion story.** Both builds already occupy
**100.00 % of the device's 8,820 CLBs** — every CLB on the xczu3eg holds at least
one cell before W1 adds anything. W1's 712 extra registers therefore cannot claim
fresh CLBs; they must pack into CLBs that are already in use, which raises pins-per-CLB
rather than area. That is precisely the quantity `[Route 35-445]` reports, and it went
**58 → 74**. A part at 100 % CLB occupancy converts *any* addition into local routing
pressure, whatever the addition is and wherever it sits.

### 2.2 Post-synthesis cell usage (`Report Cell Usage`), for the breakdown

Different report, different stage — these are pre-placement inferred cells, and they
are what allows each term to be attributed. They do **not** contradict §2.1; the
post-synthesis totals are lower because placement packs and re-maps.

| cell | W1 | SEQ-BIST | Δ |
|---|---|---|---|
| FDCE | 75,759 | 75,058 | **+701** |
| FDRE / FDSE / FDPE | 35,216 / 1,588 / 394 | 35,216 / 1,588 / 394 | **0** |
| LUT1…LUT6 (total) | 51,838 | 51,734 | **+104** |
| CARRY8 | 1,416 | 1,388 | **+28** |
| MUXF7 | 1,277 | 1,250 | **+27** |
| MUXF8 | 150 | 150 | 0 |
| RAMB36E2 / RAMB18E2 | 65 / 3 | 65 / 3 | **0** |
| SRLC32E / SRL16E / CFGLUT5 | 2,136 / 1,363 / 876 | 2,136 / 1,363 / 876 | **0** |
| DSP (all) | 178 | 178 | **0** |

Well inside the brief's "a few hundred LUTs" ceiling, and every term is accounted
for (LUT1…LUT6 sum to +104 here against +122 CLB LUTs post-place — the difference is
placement re-mapping, chiefly the +21 LUT-as-Memory):

* **CARRY8 +28** = exactly 6 × 4 (the six 32-bit counters) + 2 × 2 (the two 16-bit
  edge counters). Synthesis inferred the intended adders and nothing more.
* **FDCE +701** ≈ 192 live counters + 192 census shadows + 32 edge counters + 48
  witA/witB shadow bits + 256 decoder-side `w1_reg[0:7]`, less bits trimmed as
  constant. No hidden replication.
* **MUXF7 +27** is the signature of `w1_reg[w1_idx]` — the 32-bit **8:1
  array-indexed read** in the address decoder. It is the only W1 structure that
  shows up as a distinctive primitive (see §4.3).
* No BRAM, DSP, SRL or CFGLUT5 movement: nothing was displaced.

---

## 3. Verdict

**The failing/critical endpoints are pre-existing paths (FEC deinterleave →
FrameStat probe/FIFO → `delayMatch37`) made worse by placement pressure and
congestion on a device already at 100 % CLB occupancy. They are not the W1 AXI read
mux, not the 32-bit counters, not the census taps and not the occupancy word.**

**W1 as built is flashable on its own gate**: routed WNS +0.071 (TNS 0, WHS +0.009,
THS 0), modem clock 0.169 ns, `md5=2728dab3979a54616f1ad67f1ac8e8a7`.

---

## 4. Independent view: does Task 9's "vendor path variance" reading hold?

Asked for explicitly by the controller. This was reached independently — from the
two builds' `report_timing_summary` files and cell-usage tables — before Task 9's
reading was known to me.

**It holds for the claim it makes, and it must not be extended past that.**

### 4.1 Where I confirm it — completely

The headline-WNS claim is correct and I reproduce it exactly. The overall WNS path
is byte-for-byte the same net in both builds: source
`axi_adrv9001/inst/i_core/i_delay_cntrl_rx1/i_delay_rst_reg/rst_reg/C`, destination
`axi_adrv9001/inst/i_if/i_rx_1_phy/i_serdes/i_delay_ctrl/RST`, path group
`**async_default**`, a Recovery check on `clk_pl_2`, **0 logic levels**, ~94 % route.
The 0.112 → 0.071 movement is 1.239 → 1.276 ns of route delay on one two-node vendor
reset net. No W1 cell is on it, none could be, and no change to W1 or any successor
can move it. Treating that number as a modem-timing regression would be a mistake.

I also confirm the supporting facts: **no W1 net appears anywhere in the 8 MB routed
timing report** (§1), and the post-synthesis `modem_dut` WNS is identical at
**1.544 ns** in both builds. And I confirm that identity is *not* a scoping artefact —
`timing_gate.tcl:73-75` scopes to paths `-to` any cell matching `*TxRxCompo_ip_0*`,
which includes `TxRxCompo_ip_addr_decoder`, so it exonerates the AXI read mux as well
as the census.

### 4.2 Where the reading needs a boundary — one substantive correction

**"Modem-scoped WNS identical at 1.544 ns" is a post-*synthesis* number, and the
post-*route* modem number is not identical.**

| `axi_adrv9001_adc_1_clk` intra-clock WNS | W1 | SEQ-BIST | Δ |
|---|---|---|---|
| post-synthesis (`modem_dut`, scoped) | 1.544 | 1.544 | 0.000 |
| **post-route (intra-clock table)** | **0.169** | **0.227** | **−0.058** |

So the two claims are not the same claim. W1 adds **no logic depth** (that is what
1.544/1.544 establishes) but it does cost the modem clock **0.058 ns** once placed
and routed, and that cost is real, reproducible in the reports, and mediated by
congestion (58 → 74 high-pin CLBs) on a part at 100.00 % CLB occupancy.

The over-reading to avoid is: *"the delta is vendor path variance, therefore W1 is
free."* It is not free; it is **0.058 ns on the modem clock**, paid in placement
quality rather than logic. Every pre-route milestone shows it as a flat, invariant
**−0.090 ns** (§1.4) — too consistent across three independent stages to be variance.
What is variance is the *headline* number, because that number belongs to a vendor
reset path nobody is optimising.

### 4.3 What follows for Task 12

Task 12 (W1 + R3S on the same tree) inherits 0.169 ns, not 0.227 ns, and adds
steering logic to the same receiver region on a device with no spare CLBs. The
guidance this analysis supports:

* Gate Task 12 on the **modem clock's intra-clock WNS**, not on the reported overall
  WNS — the latter is dominated by a vendor path that moves ±0.04 ns for free.
* Expect the same mechanism (congestion, not logic depth) if it tightens, so read
  `[Route 35-445]`'s congested-CLB count as the leading indicator.
* **Do not gate on an intermediate `[Route 35-416]` WNS.** Both builds went negative
  mid-route and recovered; W1 reached −0.598 at iteration 1 and still met timing.
* If Task 12 does miss, the cheapest lever found here is the address decoder: W1's
  `w1_reg[w1_idx]` 8:1 array read is the **+27 F7 Muxes**, and folding the eight
  words into the existing `case (address_select_level1)` would remove that plus the
  tail 2:1 mux on `data_read` and the `- 3'd5` index subtract, at no cost to the
  register map. That is a known, pre-scoped fallback — **not needed for W1 itself**,
  which meets timing as built.

---

## 5. Limitations, stated

* **The brief asked for "the route log's worst-path names".** The route log does
  not contain path names — `[Route 35-416]` prints only aggregate WNS/TNS. The names
  above come from `report_timing_summary`, which `build_txfix.tcl` runs after
  routing and writes to
  `hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_timing_summary_routed.rpt`
  in each build directory. That report is *post-route final*, so it names the paths
  that were critical **at the end**, not the ones the router was fighting at
  iteration 1. The iteration-1 endpoints are not recoverable from any artefact on
  disk and no post-place checkpoint was written; if they are ever wanted, the build
  script would have to be changed to `report_timing -max_paths N` after
  `place_design`. **This document does not claim to know which endpoints were
  negative at iteration 1.**
* The `-max_paths 10` limit means "no W1 net appears" is precisely: no W1 net is
  among the ten worst paths of any path group or clock pair. A W1 path at, say,
  1.0 ns of slack would not appear and would not matter.
* Cell usage is post-synthesis (`Report Cell Usage`), not post-implementation
  utilisation; `report_utilization` is not in either log.
