# BEATILA — burst-onset ILA + XVC overlay design

Target: ZU3EG (xczu3eg-sfva625-2-e), Vivado 2025.1, `complete_byte_t8.tcl` BD build
(lineage `jupiter_byte_lean_build` / `jupiter_byte_tgenrx_build`). Purpose: capture the
onset of the strictly periodic error bursts (119.75 s period, 6–8 s long) seen by the
in-fabric post-Viterbi comparator, with an ILA reachable over XVC (no JTAG pod on the rig).

Deliverables this doc pairs with:
- RTL: `jupiter_240k5_byte/rtl_sim/burst_onset_det.v`
- Splice: `two_jup/skidfix/patch_beatila_tcl.py` (marker `BEATILA_WIRE_OK`)

DESIGN ONLY — nothing here has been run through Vivado.

## 1. Ground truth from the survey

- DUT cell: `TxRxCompo_ip_0` (HDL Coder IP `TxRxCompo_ip` v1.0), set as
  `$HDLCODERIPINST` at line 49 of `complete_byte_t8.tcl`.
- DUT clock: `axi_adrv9001/adc_1_clk` (SSI-derived). Image A rung re-times the fabric
  to **30.72 MHz** (`image_a_3072_clocks.xdc`, applied when `QPSK_FRAME=f1536` and
  `QPSK_TARGET_MHZ<60`). All rate math below assumes 30.72 MHz.
- DUT reset: `rx_rstn_inverter/Res` (active-low resetn).
- Comparator: `TxRxCompo_ip_src_Capture_Data_Bits` inside
  `.../u_TxRxCompo_ip_dut_inst/u_TxRxCompo_ip_src_TxRxComposite/u_Receiver/u_Capture_Data_Bits`;
  outputs `count_out`, `packets_out`, `bit_errors_out` (uint32). These reach software
  through the DUT AXI4-Lite (`0x9D000000`; frame count at +0x104, `bit_errors_out`
  at +0x108) but are **not** DUT top-level ports.
- DUT top-level ports of interest (all BD-reachable, all in the adc_1_clk domain):
  - RX byte plane out: `dut_byte_data_out[63:0]`, `dut_byte_valid_out`,
    `dut_byte_last_out`, `dut_byte_user_out` (= `outFirst`, frame-first marker —
    NOTE memory: markers are absent in -M mode; treat as best-effort, use valid-gap
    witness for frame cadence), `dut_byte_ready_in`.
  - TX byte plane in: `dut_byte_data_in[63:0]`, `dut_byte_valid_in`,
    `dut_byte_first_in`, `dut_byte_ready_out`.
  - IQ debug taps: `dut_data_out_0_rx/1_rx` = `debugI1/Q1` = receiver input IQ;
    `dut_data_out_2_rx/3_rx` = `debugI/Q` = **software-muxed** internal tap
    (`iq_debug_mux` AXI register, see §5): 0=AGC out, 1=post symbol-sync
    (timing-loop output), 2=post carrier-sync, 3=constellation decisions,
    >=4=P1c phase-detector telemetry. `dut_data_valid_out_rx` qualifies them.
  - ADC-side samples: `dut_data_in_0_rx/1_rx` + `dut_data_valid_in_rx`.

## 2. Probe list (system_ila `beat_ila`, NATIVE, clk = adc_1_clk)

| # | Signal (BD net of)                       | Width | Why |
|---|------------------------------------------|-------|-----|
| 0 | `burst_det/trig`                         | 1     | Trigger source; marks onset instant |
| 1 | `burst_det/status` (win count/trig/latch)| 32    | Rolling 1 ms error-window count at onset |
| 2 | `TxRxCompo_ip_0/dut_byte_valid_out`      | 1     | RX byte cadence; valid-gap witness for decoder stall |
| 3 | `TxRxCompo_ip_0/dut_byte_last_out`       | 1     | Frame end marker (when present) |
| 4 | `TxRxCompo_ip_0/dut_byte_user_out`       | 1     | Frame first marker (when present; blind in -M mode) |
| 5 | `TxRxCompo_ip_0/dut_byte_ready_in`       | 1     | Backpressure from rx_byte_breakout/DMA (FIFO-swallow class) |
| 6 | `TxRxCompo_ip_0/dut_byte_data_out[63:0]` | 64    | Payload at error time (single-bit magic flips vs scramble) |
| 7 | `TxRxCompo_ip_0/dut_data_valid_out_rx`   | 1     | Qualifier for IQ taps; storage-qualification pin (§4) |
| 8 | `TxRxCompo_ip_0/dut_data_out_0_rx`       | 16    | debugI1 = receiver input I |
| 9 | `TxRxCompo_ip_0/dut_data_out_1_rx`       | 16    | debugQ1 = receiver input Q |
|10 | `TxRxCompo_ip_0/dut_data_out_2_rx`       | 16    | debugI = muxed loop tap (timing/carrier/constellation via `iq_debug_mux`) |
|11 | `TxRxCompo_ip_0/dut_data_out_3_rx`       | 16    | debugQ = same, Q |
|12 | `TxRxCompo_ip_0/dut_data_in_0_rx`        | 16    | Raw SSI/ADC I — is the burst already on the air/analog side? |
|13 | `TxRxCompo_ip_0/dut_data_in_1_rx`        | 16    | Raw SSI/ADC Q |
|14 | `TxRxCompo_ip_0/dut_data_valid_in_rx`    | 1     | SSI valid cadence (clock/valid dropout hypothesis) |
|15 | `TxRxCompo_ip_0/dut_byte_valid_in`       | 1     | TX-side cadence (rules TX in/out at onset) |

Total data width ≈ 187 bits.

## 3. ILA configuration

One `system_ila`:
- `C_MON_TYPE NATIVE`, `C_NUM_OF_PROBES 16`, `C_DATA_DEPTH 4096`,
  `C_ADV_TRIGGER TRUE`, `C_EN_STRG_QUAL TRUE`, `C_INPUT_PIPE_STAGES 2`
  (CLB tiles are at 99.4 % — give the placer slack), `ALL_PROBE_SAME_MU_CNT 2`.
- BRAM cost: 187 b x 4096 ≈ 21–24 RAMB36 — comfortably inside the 179 free tiles.

Dual capture strategy (same core, two run recipes):
1. **Native raw**: no capture qualification, trigger `probe0 == 1`, trigger position
   ~3072/4096 (75 % pre-store). Window = 4096 cycles @ 30.72 MHz = **133 µs** of
   full-rate context straddling the trigger — the fine-grain onset shot.
2. **Qualified slow context**: enable capture control, storage qualifier
   `probe7 (dut_data_valid_out_rx) == 1`, same trigger. At ~240 ksym/s effective
   tick rate 4096 stored samples ≈ **17 ms** of symbol-rate context — shows loop
   state (via `iq_debug_mux`) walking into the burst. Byte-plane probes are
   incoherent in this mode; read only probes 7–11.

Take run 1 and run 2 on consecutive burst periods (period is 119.75 s and stable, so
re-arming between periods is cheap; `burst_det` re-arms by toggling GPIO arm bit).

## 4. Burst-onset trigger (`burst_onset_det.v`)

- Clock: adc_1_clk, assumed **30.72 MHz**; `WIN_CYCLES = 30720` = 1.000 ms rolling
  window implemented as two half-window buckets (detect latency <= 1 ms, no BRAM).
- Input `err_cnt[31:0]`: a free-running error counter; increments extracted
  internally (delta capped at 255/cycle), so a 1-pulse-per-error strobe also works.
- `trig = arm & (window_count > THRESH | soft_force)`, THRESH parameter (default 32).
  `trig_latched` sticky until disarm — software can see a hit even if it missed the ILA.
- Control/status via `beat_arm_gpio` (dual AXI GPIO @ **0x9D430000**):
  ch1 (outputs): bit0 = arm (schedulable — software raises it only in the window
  where triggering is wanted), bit1 = soft_force. ch2 (inputs): live
  `{latched, trig, win_count[15:0]}`.
- **err_cnt source caveat**: see §5 — in a stock IP build the pin is tied 0 and the
  hardware trigger runs from soft_force / ILA-side triggers only.

## 5. The unreachable signals — stated explicitly, with fallbacks

Not present at the DUT boundary (BD level cannot reach them):
`bit_errors_out` / `count_out` / `packets_out` (Capture_Data_Bits), the framesync
pulse (`recStart` / `cnt_frame_start`), the timing-loop control word
(interpolator/resampler state inside `Frequency_and_Time_Synchronizer`), the carrier
loop integrator, `fs_runmax`.

Fallbacks, in preference order:

1. **Already-built escape hatch — `iq_debug_mux`**: AXI register on the DUT selects
   what drives probes 10/11: `1` = post symbol-sync IQ (timing-loop output), `2` =
   post carrier-sync IQ, `3` = decisions, `>=4` = P1c phase-detector telemetry.
   Loop *behavior* (not the raw control word) is therefore BD-visible today.
2. **mark_debug on synthesized nets** (constraint-only, no HDL edit): add an XDC with
   `set_property MARK_DEBUG true [get_nets ...]` on
   - `*/TxRxCompo_ip_0/*/u_TxRxCompo_ip_dut_inst/u_TxRxCompo_ip_src_TxRxComposite/u_Receiver/Capture_Data_Bits_bit_errors_out*`
   - `.../u_Receiver/QPSK_Rx_cnt_frame_start*` and the `recStart`/`startOut` net
   - `.../u_Receiver/u_QPSK_Rx/u_Frequency_and_Time_Synchronizer/*` (loop-state
     registers; exact post-synth names to be picked from the synthesized netlist)
   then attach them to a netlist ILA at the synthesis checkpoint. This feeds ILA
   probes only — it cannot feed `burst_onset_det`.
3. **Smallest DUT change** (regeneration, not hand-edit): a MATLAB model overlay in
   the established pattern (`p1d_pd_telemetry_overlay.m`, `fec_counters_overlay.m`)
   that maps the existing `bit_errors_out` wire to a new DUT output port
   `dut_bit_err_out[31:0]`. The patch script auto-detects that port and wires it to
   `burst_det/err_cnt`; absent the port it ties 0 and prints
   `BEATILA_ERRSRC: NONE`. This is the only path that gives the *hardware* burst
   trigger a true post-Viterbi error source.

## 6. XVC debug bridge and address map

`ad_ila_setup_xvc` (from `projects/common/xilinx/adi_xilinx_ila.tcl`) instantiates
`debug_bridge_0` (AXI→BSCAN, `C_DEBUG_MODE 2`, XVC HW id 0x0002) + `debug_bridge_1`
(BSCAN→DebugHub, `C_DEBUG_MODE 1`) on `sys_cpu_clk`/`sys_cpu_resetn` (both nets exist
by name in the saved BD) and calls `ad_cpu_interconnect` — whose backend
`ad_hpmx_interconnect` recovers its index from the live `axi_hpm0_lpd_interconnect`
(smartconnect, NUM_MI currently 14 in the tgenrx build), so it is safe in the
re-opened project. The splice wraps it in `catch` with a raw-command fallback that
mirrors the proven TGEN interconnect-attach pattern.

Address map (HPM0_LPD, existing + new):

| Addr        | Cell               | Note |
|-------------|--------------------|------|
| 0x9D000000  | TxRxCompo_ip_0     | DUT AXI4-Lite (64K) |
| 0x9D200000  | byte-plane S2MM DMA| existing |
| 0x9D300000  | byte_ctrl_gpio     | existing |
| 0x9D400000  | tgen_ctrl_gpio     | existing (tgenrx variant) |
| 0x9D410000  | tgen_rx_ctrl_gpio  | existing (tgenrx variant) |
| 0x9D420000  | txchk_gpio         | existing (tgenrx variant) |
| **0x9D430000** | **beat_arm_gpio**  | new — arm/soft-force + status |
| **0x9D440000** | **debug_bridge_0** | new — XVC endpoint (64K) |

Host use: run `xvcserver` on the ARM against 0x9D440000 (UIO or /dev/mem), then in
Vivado HW manager `open_hw_target -xvc_url <board>:2542`.

Clocking caveat: adc_1_clk is SSI-derived — it only runs while an ADRV9002 profile is
loaded and the SSI is up. `beat_ila` and `burst_det` are dead (and the debug hub may
report the core as "waiting for clock") until the profile is up; this matches the
measurement regime (bursts observed during live traffic). The debug hub itself sits
on the XVC/BSCAN path via debug_bridge_1 (clocked at sys_cpu_clk); only the ILA core
needs adc_1_clk. If `dbg_hub` gets auto-tied to adc_1_clk at implementation, force it
to the free-running domain with a late XDC:
`connect_debug_port dbg_hub/clk [get_nets -hier *sys_cpu_clk*]`.

## 7. Utilization budget vs measured headroom

Post-place, tgenrx build
(`jupiter_byte_tgenrx_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_utilization_placed.rpt`):

| Resource     | Used    | Avail   | Util   |
|--------------|---------|---------|--------|
| CLB LUTs     | 42 891  | 70 560  | 60.8 % |
| CLB Registers| 100 846 | 141 120 | 71.5 % |
| Block RAM    | 36.5    | 216     | 16.9 % |
| CLB tiles    | 8 767   | 8 820   | **99.4 %** |

Overlay adds (estimates): system_ila 187 b x 4096 ≈ 21–24 BRAM, ~4–6 k LUT,
~6–9 k FF; debug_bridge pair ≈ 1.5 k LUT / 2 k FF; burst_onset_det + GPIO ≈ 0.3 k.

**Verdict: TIGHT but expected to fit.** LUT/FF/BRAM all have clear headroom
(post-overlay ≈ 70 % LUT, ≈ 79 % FF, ≈ 28 % BRAM), but CLB tile occupancy is already
99.4 %, i.e. the placer is spreading; adding ~8 % more FFs forces denser packing.
Mitigations already in the config: 2 input pipe stages, depth capped at 4096 (do NOT
go to 8192/16384), single ILA. The design clock is only 30.72 MHz, so timing risk
from dense packing is low; the sys_cpu_clk (AXI, 100 MHz class) side is small. If
place fails, first drop probes 12/13 (raw ADC IQ, −32 b) and/or halve probe 6 to
`[31:0]`.

## 8. Exact splice points in complete_byte_t8.tcl

The BD-mutation region of the tcl runs from the IP instantiation (line ~49,
`set HDLCODERIPINST TxRxCompo_ip_0`) to `validate_bd_design` (line 273 in the tgenrx
variant / after `BYTE_WIRE_OK` line 113 in the lean variant). The BEATILA block must
land inside that region, after all byte-plane/TGEN wiring exists:

- tgenrx variant: **immediately after `puts "TXCHK_WIRE_OK"`** (line 271) — last
  instrument block, just before `validate_bd_design`.
- lean variant: **immediately after `puts "BYTE_WIRE_OK"`** (line 113).

`patch_beatila_tcl.py` implements exactly that anchor preference and is
idempotent-guarded on the `BEATILA_WIRE_OK` marker (refuses double-patch). The
unpatched tcl is untouched — the build remains byte-identical unless the patch is
run. Prereq: copy `jupiter_240k5_byte/rtl_sim/burst_onset_det.v` into the build kit
dir next to `complete_byte_t8.tcl` (same convention as `qpsk_traffic_gen.v`).

## 9. Grep-able build markers

`BEATILA_XVC_ADI_OK` | `BEATILA_XVC_RAW_OK`, `BEATILA_ERRSRC: ...`,
`BEATILA_NOTE: ...`, `BEATILA_FAIL: ...` (exits 1), final `BEATILA_WIRE_OK`.
