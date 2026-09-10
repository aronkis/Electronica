> Evidence ledger, moved verbatim from `two_jup/comb/CLOCK_OFFSET_OPTIONS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# CLOCK_OFFSET_OPTIONS — removing the ≈2.5 ppm inter-board SRO at the source (2026-09-04, read-only survey; nothing written to either board)

System-level alternative to the RTL fix. Written by the controller from the read-only Explore agent's return.

## 0. With one clock the defect does not occur — already measured
- 09-02 sel13 files (digital loopback, 148 hearing its own transmitter): 0 deletions (OVERNIGHT_20260904_SEQBIST.md, COMB_STATE.md); self-reception "both LOs off the same XO" (SEQBIST_STATE.md).
- Sim: −2.5 ppm → 4.11 % loss, period 32.375; +2.5 ppm → 0.00 % (COMB32_SRO_SIM_2p5.md).

## 1. What clock each board uses (both boards identical; DTBs byte-identical in the clock subtree)
| fact | evidence |
|---|---|
| ADRV9002 reference is external to the chip, `adrv9002_ext_refclk` | `adrv9002-phy@0 { clocks = <0x25>; clock-names = "adrv9002_ext_refclk"; }` (decompiled dts ~1350) |
| source = GPIO-selected 2:1 mux of two on-board FIXED oscillators | `clk-mux { compatible = "gpio-mux-clock"; clocks = <0x32 0x33>; select-gpios = <0x1c 0x4f 0x00>; }` (dts ~1958-1964) |
| mux input 0 = 30.72 MHz, input 1 = 38.4 MHz | dts ~1941-1954 |
| 38.4 MHz in use | every profile `"deviceClock_kHz": 38400` (lvds_61p44_fdd_jupiter.json:3) |
| VCO `clkPllVcoFreq_daHz = 884736000` (8.84736 GHz) | json:4 |
| RX sample rate 61.44 MHz | `in_voltage0_sampling_frequency` |
Both mux inputs are `fixed-clock` nodes: flipping the GPIO swaps WHICH local XO (30.72 vs 38.4, changing every rate by 25 %), never WHOSE. No dev_clk/clkin/ref-clk-in node exists; HOSTS.md records no clock cabling.

## 2. Software DCXO / device-clock trim — NO
- `grep -ri dcxo two_jup/` → 0 hits; 0 hits in the 502-line sysfs+debugfs enumerations (comb/knobs_148/knobs.txt, knobs_146); no dcxo key in any profile; no kernel source tree on nemo.
- The only clock-shaped debugfs node is `dev_clkout_div` (knobs.txt:276 on both) — a clock-OUT divider, integer granularity, not a reference trim.
- Profile fields someone will be tempted by: `deviceClock_kHz` steps 1 kHz = 26 ppm (10× too coarse, and it mis-tells the PLL rather than trimming an oscillator); `clkPllVcoFreq_daHz` steps 10 Hz = 0.0011 ppm (resolution fine) but the TES-generated json/bin pair passes an on-device validator and the repo has hung boards on bad profile traffic — unvalidated, speculative, wedge risk with no remote power.

## 3. The measured offset, and why the LO trim does not fix it
Device clock feeds both the digital chain and the RF PLLs, so CFO ppm = SRO ppm:
| source | figure | ppm |
|---|---|---|
| bringup_r2r3.sh:15 — 148 RX LO plain residual −5.15 kHz @ 2.0 GHz | 2.575 |
| exp_forward.sh:25 — ~−6.3 kHz @ 2.0 GHz (older) | 3.15 |
| symbol-deletion census 09-04 sel8 / 09-03 sel13 | 2.57 / 2.51 |
Also SESSION_STATE_20260826.md:14 (≈2.6 ppm), ERROR_SOURCES_SIM_REPRO.md:235 (period 33 frames ⇒ 2.5 ppm). The deliberate LO offsets (bringup_r2r3.sh:55 146 Rx +40 kHz; :58 148 Rx +20 kHz) retune a synthesiser downstream of the XO: CFO trims only, sample clock untouched. Corollary: the RX-LO CFO residual is a free SRO meter.

Trap: trimming one board's clock by 2.5 ppm moves BOTH legs' residual CFO by ≈5 kHz against the +20 k/+40 k off-null margins; bringup_r2r3.sh:9-16 documents the residual-CFO≈0 dead zone as FATAL at R2/R3 and 146 RX LO 1900000000 as BISTABLE. Any clock trim mandatorily requires re-tuning LO_A_RX/LO_B_RX and re-running the off-null sweep.

## 4. Hardware reference share — unresolved (schematic question)
`refClockOutEnable: true` and `padRefClkDrv: 0` in all six profiles; `dev_clkout_div` in debugfs on both boards → the part CAN drive its device clock out a pad. Whether that pad reaches a connector on the ADALM-Jupiter and whether a clk-mux input is externally routable is not determinable from the DT. Requires the schematic or an operator eyeball. No 10 MHz / external-ref jack / clock cable appears anywhere in the repo.

## 5. Prior attempts: none
Only proposals (NEXT_STEPS.md, OVERNIGHT fix (b)); MODEL2_CLKEN_SOURCE.md:280-286 dismissed a "single coherent clock" for the AIR path — a WIRED share bypasses that argument. The only clock-adjacent thing ever written to a board is the SSI delay tuning (apply_146_ssi_fix.sh:58-59), unrelated to oscillator frequency.

## Decision lines
1. No software clock trim exists.
2. `deviceClock_kHz` resolution (26 ppm/step) kills the obvious substitute.
3. `clkPllVcoFreq_daHz` is a speculative candidate (0.0011 ppm/step) with wedge risk.
4. The clk-mux GPIO is not an option (swaps local oscillators, 25 % rate change).
5. A hardware share is open, not absent — one schematic lookup decides it.
6. If routable: one coax + a DT override → offset exactly zero on both legs; else board rework (out of scope).
7. Any share/trim costs a CFO re-tune (≈5 kHz shift into the FATAL dead zone).
8. The fix is proven to work if applicable (0 deletions in shared-clock self-reception; +2.5 ppm sim 0 loss).
9. Free instrument: the RX-LO CFO residual reads the same ppm as the SRO.
10. Bottom line (and the operator's decision 2026-09-04): fix it in the RTL — the only costed, sim-proven path, and the only one that survives a rig where the boards cannot share a clock.
