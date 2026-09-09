# Task 9b — report

**Status: COMPLETE (downscoped by controller ruling to item 1 only).**

Deliverable: `two_jup/comb/RXFIX_W1_TIMING.md`.

## Scope actually executed

The task was dispatched as a four-item fallback preparation (timing diagnosis +
RXFIX_W1L variant + its sim gate + kit wiring). Mid-task the controller downscoped
it to **item 1 only**, on the grounds that no W1 net is on any reported timing path.
That ruling is consistent with what this task independently found.

**RXFIX_W1L was never cut.** No W1L code, test, harness or marker was added to
`two_jup/skidfix/rxfix_inject.py`, `test_rxfix_inject.py`, `W1_REGMAP.md` or the kit
script at any point. The injector is exactly as Task 9 (and Task 11) left it — no
removal was required and none was made. Items 2, 3 and 4 were not started; no sim
legs were launched, so no `t9b_*` units exist. `t9bhb` was the only unit this task
ran.

Rails held: **no Vivado launched, no board contact, nothing in either build
directory on hdl-dev-2 modified** (read-only `ssh` inspection only), no subagents.

## Findings

1. **The task premise was stale.** The W1 build completed at 16:18:20 and **met
   timing**: `[Route 35-61] The design met the timing requirement`,
   `TXFIX_ROUTED_WNS wns=0.071224 tns=0.000000`, WHS +0.009, THS 0,
   `md5=2728dab3979a54616f1ad67f1ac8e8a7`. The −0.317 / −0.598 the brief reacted to
   were pre-legalisation router states; SEQ-BIST went negative at iteration 0 too
   (−0.021). An intermediate `[Route 35-416]` WNS is not a prediction and must not
   be used as a gate.

2. **The headline WNS is not a modem path in either build**, so "+0.112 → +0.071"
   compares the wrong number. Both builds' overall WNS is the *same* vendor net:
   `axi_adrv9001/.../i_delay_rst_reg/rst_reg/C` →
   `axi_adrv9001/.../i_serdes/i_delay_ctrl/RST`, path group `**async_default**`, a
   Recovery check on `clk_pl_2`, **0 logic levels**, ~94 % route. The whole 0.041 ns
   is route variance on a two-node vendor reset net.

3. **Answer to the question asked — pre-existing paths, not W1 logic.** Decisive
   evidence: a grep of the 8.0 MB routed `report_timing_summary` (top 10 paths of
   *every* path group and clock pair) for `w1_reg|rh_w1_census|w1_bus|w1Bus|u_rh_w1`
   returns **zero hits**. W1's worst modem path is
   `Capture_Data_Bits/delayMatch_reg → FEC_Decoder_Wrapper/RxDeint → RxAlign →
   FrameStatProbe → FrameStatFifo/wr_temp → rd_temp[2]` (fanout 466, 1.618 ns of
   route on that net alone) `→ MUXF7 → delayMatch37_reg` — 12 levels, 83 % route,
   every cell pre-existing. SEQ-BIST's worst modem path is a *different* path
   (`tx_checker/fill_reg → bit_errors_reg`, 25 levels, CARRY8×5). The
   `Capture_Data_Bits/FrameStatFifo` family appears 7× in W1's ten worst and 0× in
   SEQ-BIST's: **the ranking changed, the path did not degrade in place.**

4. **Utilisation delta**, both stages reported and reconciled:
   post-implementation (`system_top_utilization_placed.rpt`) **+122 CLB LUTs,
   +712 CLB Registers**, +28 CARRY8, +27 F7 Muxes, **0 BRAM, 0 DSP** — these match
   the figures the controller quoted. Post-synthesis cell usage gives the
   attribution: +701 FDCE, +104 LUT1…6, +28 CARRY8 (= exactly 6×4 + 2×2, the six
   32-bit counters and two 16-bit edge counters), +27 MUXF7 (the signature of
   `w1_reg[w1_idx]`, the 8:1 array read).

5. **Mechanism, and a fact worth carrying forward: both builds sit at 100.00 % CLB
   occupancy (8,820 / 8,820).** Every CLB on the xczu3eg is already in use before W1
   adds anything, so its 712 extra registers pack into occupied CLBs and raise
   pins-per-CLB rather than area — which is exactly what `[Route 35-445]` measures,
   and it went **58 → 74**. On a part at 100 % CLB occupancy any addition converts
   into local routing pressure.

## Independent view on Task 9's "vendor path variance" reading

Requested by the controller; reached independently before Task 9's reading was known
here. **It holds for the claim it makes, and should not be extended past it.**

* **Confirmed:** the headline-WNS delta is vendor-path variance, exactly as stated —
  same net, 0 logic levels, no W1 cell on it, unmovable by any change to W1. Also
  confirmed: no W1 net anywhere in the routed report, and post-synth `modem_dut`
  identical at 1.544 ns. That identity is *not* a scoping artefact —
  `timing_gate.tcl:73-75` scopes to paths `-to *TxRxCompo_ip_0*`, which includes
  `TxRxCompo_ip_addr_decoder`, so it exonerates the AXI read mux too.

* **One boundary to add:** "modem-scoped WNS identical at 1.544 ns" is a
  post-**synthesis** number. The post-**route** modem-clock intra-clock WNS is **not**
  identical — **0.169 ns (W1) vs 0.227 ns (SEQ-BIST), a real −0.058 ns**. So W1 adds
  no *logic depth* (which is what 1.544/1.544 establishes) but does cost the modem
  clock 0.058 ns in *placement quality*. Every pre-route milestone shows this as a
  flat, invariant −0.090 ns across three independent stages — too consistent to be
  variance. The over-reading to avoid is "vendor variance, therefore W1 is free".

## Guidance for Task 12 (W1 + R3S)

* Task 12 inherits **0.169 ns**, not 0.227 ns, and adds logic to the same receiver
  region on a device with no spare CLBs.
* **Gate on the modem clock's intra-clock WNS**, not on the reported overall WNS —
  the latter belongs to a vendor reset path that moves ±0.04 ns for free.
* **Do not gate on an intermediate `[Route 35-416]` WNS**; W1 reached −0.598 at
  iteration 1 and still met timing.
* Leading indicator if it tightens: `[Route 35-445]`'s congested-CLB count.
* Cheapest pre-scoped lever if it ever misses: the address decoder. W1's
  `w1_reg[w1_idx]` 8:1 array read is the +27 F7 Muxes; folding the eight words into
  the existing `case (address_select_level1)` removes that, the tail 2:1 mux on
  `data_read` and the `- 3'd5` index subtract, with no change to the register map.
  Not needed for W1 itself.

## Concerns

* **The iteration-1 endpoints are not recoverable.** `build_txfix.tcl` writes no
  post-place timing report and no post-place checkpoint. The path names above come
  from the *post-route final* `report_timing_summary`, so they name what was critical
  at the end, not what the router was fighting at iteration 1. This report makes no
  claim about the latter. If that visibility is ever wanted, the build script needs a
  `report_timing -max_paths N` after `place_design`.
* `-max_paths 10` bounds the "no W1 net appears" claim to: no W1 net is among the ten
  worst paths of any path group or clock pair.
* The 100 % CLB occupancy is a standing constraint on this lineage, not a W1
  property. Every future instrument pays the same congestion tax.
