# RATE_HANDLE_FIX_SURVEY — netlist survey for a receiver rate-handling fix (2026-09-04, desk only, [netlist])

Paths relative to `jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`, module files prefixed `TxRxCompo_ip_src_`. Written by the controller from the read-only Explore agent's return (verbatim content, lightly formatted).

## 0. Headline — the premise "unguarded ring" is wrong
Rate_Handle's 32-entry ring HAS a full/empty guard, one level down in `Validate_Input_Push_Pop_block.v` (instantiated `FIFO_block.v:104-112`):

| function | file:line |
|---|---|
| occupancy counter, 6-bit up/down, 0…32 | `MATLAB_Function_block2.v:86-136` (`enb_1 = valid_push ^ valid_pop` at `VIPP_block.v:92`; `dir = ~valid_pop` at `:89`) |
| registered occupancy | `Validate_Input_Push_Pop_block.v:103-113` (`Delay_out1 <= count`) |
| empty = occupancy 0 | `Compare_To_Constant_block.v:36` |
| full = occupancy 32 | `Compare_To_Constant1_block.v:36` |
| `pop_on_empty_FIFO = empty & pop` | `Validate_Input_Push_Pop_block.v:119` |
| `valid_pop = pop & ~pop_on_empty_FIFO` | `:121,123` |
| `push_on_full_FIFO = push & ~valid_pop & full` | `:125,127,129` |
| `valid_push = push & ~push_on_full_FIFO` | `:131,133` |
| outputs | `:135,137`; consumed at `FIFO_block.v:131,166,192,202` |

Consequences: (1) underflow produces neither garbage nor a repeat nor a deletion — a pop into an empty ring is suppressed (`valid_pop=0` → `FIFO_block.v:202` → `Rate_Handle.v:137 validOut=0`): a skipped valid slot, stream intact; (2) overflow DOES delete — a push into a full ring is suppressed (`VIPP_block.v:129,133`), the only place Rate_Handle loses a symbol; (3) the guard is exact (combinational next-state `MATLAB_Function_block2.v:134-135`, registered identically `VIPP_block.v:109-111`); (4) nothing re-centres the ring: `Rate_Handle.v:116` `Constant_out1 = 1'b0` → `FIFO_block.reset_1` (`:125`); `reset_1` is flush-to-empty (`FIFO_block.v:122,134,157,169`; `MATLAB_Function_block2.v:94-96`) — never pulse it.

Documents this corrects: COMB32_RTL_HUNT.md §1a A1 / §2 #1; COMB32_SRO_SIM_2p5.md verdict; OVERNIGHT_20260904_SEQBIST.md :19/:189. At the EMPTY edge (which the −2.5 ppm sim leg reaches) the netlist loses no data — so either the sim's `occ==0` was the FULL edge misread (its metric cannot tell 0 from 32, §6) or the frame-killing step is elsewhere.

## 1. Push/pop conditions and occupancy arithmetic
- Clock/enable: `clk` with `enb_1_2_0` (clk/8 tick, `TxRxComposite.v:558-564`) = one ADC sample at 4 sps; the 1-in-4 is a counter, not an enable.
- Pop: `Rate_Handle.v:74-102` mod-4 counter advanced by `validIn` (`:89`); `:104-110` `u_BfGridPace` (earlier injection; `bfGridEn=0` → same mod-4 phase); `:112,114` `pop = validIn & (y == 0)`; `validIn` = `Symbol_Synchronizer.v:475 Delay6_out1` = module validIn delayed 14 ticks (`:437-467`) = constant 1 in both RX modes (`TxRxComposite.v:531-556`) → pops every 4th tick, forever.
- Push: `Rate_Handle.v:123 .push(strobe)` ← `Symbol_Synchronizer.v:474 .strobe(Delay2_out1)` = `Interpolation_Control.Underflow` delayed 14 ticks (`:275-312,419-429`).
- Ring: `FIFO_block.v:114-147` Push_Counter (to 31), `:149-182` Pop_Counter, `:184-196` `SimpleDualPortRAM_generic #(.AddrWidth(5), .DataWidth(16))`, `wr_en = valid_push` (`:192`), `wr_addr = Push_Counter_out1` (`:191`), `rd_addr = Pop_Counter_out1` (`:193`); data `sfix16_En14` complex (`Rate_Handle.v:43-49`) from `Symbol_Synchronizer.v:415-416`.
- Occupancy: `MATLAB_Function_block2.v:86-136` (+1 push-only, −1 pop-only; wrap branches `:99-101`, `:113-115` unreachable thanks to the guard).
- Observability today: pointers only (`FIFO_block.v:204-206` → `Rate_Handle.v:141-143` → `Symbol_Synchronizer.v:493-495`); true occupancy / `pop_on_empty_FIFO` / `push_on_full_FIFO` are NOT exported.

## 2. The 12,320-of-12,333 window (13-SYMBOL guard)
Units are symbols. `Packet_Controller.v:115-123` (syncPulse → startIn level; `Logical_Operator_out1 = validIn & out`); `:140-147` `u_End_Generator(.validIn(Delay1_out1), .rst(start))`; `End_Generator.v:54-105` counter to 12319 advanced by `validIn` (`:71`), reset by `rst` (`:74`), `endOut = (count==12319) & validIn` (`:91`); `Packet_Controller.v:148-158` `u_sample_discard_controller(.validIn, .startIn, .endIn)`; `sample_discard_controller.v:120-148`: `startIn → active=1` (`:125-127`), pass-through while active else data 0 / `validOut=0` (`:128-137`), `endIn → endOutReg=active; active=0` (`:138-141`). So there IS a per-frame guard of 13 symbol slots where the deframer consumes nothing. sample_discard_controller is a gate (discards whole runs outside the window), no counter of its own; trigger = `Timing_Adjust.SyncPulse` (`Timing_Adjust.v:184-200,202,216`). A slip steered into the guard never reaches the deframer, but is NOT sufficient alone: `Peak_Search.timing_Reference` (`Peak_Search.v:79-107`), `Timing_Adjust.timing_Reference` (`:113-136`) and End_Generator's counter (`:71`) all count valids, so a deleted symbol slips all three epochs by one; the applied `timingOffset` (latched epoch N, applied at `tref == accoff` one epoch later, `Timing_Adjust.v:153,202`, against a 4-epoch `Delay10_reg[49331:0]` data delay, `Preamble_Detector.v:321-334`) is then wrong by one symbol for frames in flight. Steering bounds the damage; it does not remove it without an epoch correction.

## 3. The interpolator DOES track the SRO
`Interpolation_Control.v:104-196`: Rice modulo-1 NCO, `counter = (countReg & 0x3FF) − Delta − 0.25` (`:138-143`), `Underflow` when negative (`:147-148`), `mu` (`:149-158`); `Delta` = Gardner-TED loop filter output (`Symbol_Synchronizer.v:328-356,370-377`; gains from AXI `ss_prop_gain`/`ss_integ_gain`, `:219-241`). At lock the strobe rate equals the TRUE received symbol rate: pushes at the true rate, pops at local/4 — mismatch = 12,333·SRO entries per air frame. The "T8.4 anti-wedge clamp" (`:128-137`, ±0.2490) is far from a 2.5 ppm bias.

## 4. Downstream consumers
Chain (`Frequency_and_Time_Synchronizer.v:176-274`): Symbol_Synchronizer → Coarse_Frequency_Compensator (`:198-210`) → Carrier_Synchronizer (`:212-225`) → Preamble_Detector (`:227-248`) → Phase_Ambiguity (`:250-261`) → Packet_Controller (`:263-275`), each valid-qualified.

| block | counts | file:line |
|---|---|---|
| Peak_Search epoch `timing_Reference` (mod 12333) | valids | `Peak_Search.v:94,109-111`; inst `Preamble_Detector.v:187-200` |
| Peak_Search `timing_Reference_Long` (heldts) | valids | `Peak_Search.v:182-195` |
| Timing_Adjust `timing_Reference` | valids | `Timing_Adjust.v:126,130-136` |
| End_Generator (mod 12320) | valids | `End_Generator.v:71` |
| Preamble_Detector realignment FIFO (12333 deep) | push = valid | `Preamble_Detector.v:338-352` |
| **Preamble_Detector.Delay10_reg[49331:0]** | **enb_1_2_0 ticks** | **`Preamble_Detector.v:321-334`** |

An occupancy-driven, valid-qualified pop is legal for everything except `Delay10_reg`, which delays the VALID bit by 49,332 enb ticks and uses the delayed copy as the pop of the 12,333-deep FIFO (`:338,344`): 49,332 ticks ≡ 12,333 valids only if valid density is exactly 1/4, so the FIFO runs permanently at its full mark (`Compare_To_Constant1.v:36 = 14'd12333`, `FIFO.v:104-120`). Already patched: `Validate_Input_Push_Pop.v:136` `push_on_full_FIFO = … & (~enSlack)` (raw event kept `:138 push_on_full_raw`), `enSlack` = fixctl bit 3 (`FixCtlDec.v:34,42`), fixctl = write address 0x208 (`addr_decoder.v:869`), fan-out `QPSK_Rx.v:189,333,385` → `Frequency_and_Time_Synchronizer.v:58,79,240` → `Preamble_Detector.v:42,48,349` → `FIFO.v:31,48,118`. Witness `FIFO.v:214-253` (`wit_pof_count` `:233,251-252`) read `push_on_full = 0` on the BEAT-era legs (OVERNIGHT_20260830.md:11, BEAT_STATE_HANDOFF.md:147, SINGLES_CAMPAIGN.md:3806-3823), never on a 32-frame comb leg. Rate_Handle's ring has no equivalent witness — mirroring the FIFO.v:214-253 pattern into `Validate_Input_Push_Pop_block.v` is the smallest useful change.

## 5. Injector rails
`two_jup/skidfix/txfix_inject.py`: exactly-once anchors (`:36-41`), per-file markers (`:250-256`, variant markers `:305-308`), prefix handling (`:259-278`), patch all loose mirrors then BOTH `TxRxCompo_ip_v1_0.zip` members then `verify_zip` (`:337-361`, `nloose % len(want) == 0`, `nz == 2`, `nv == nz`). `Rate_Handle.v`, `FIFO_block.v`, `Validate_Input_Push_Pop_block.v`, `Interpolation_Control.v` are present in three loose copies (hdlsrc/, ipcore/TxRxCompo_ip_v1_0/hdl/, vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl/) and both zips (the 08-29 slack patch demonstrably reached the zip members). Build/flash: txfix_build.sh/.tcl templates (vendh variant for 146), flash_148_txfix.sh / flash_146_txfix.sh, kit/fetch scripts, boot_known_good/. Routed WNS: +0.112 ns (148 seqbist) / +0.166 (146) — a fix must be a few LUTs off the critical path.

## 6. The SRO sim harness and the one change that settles the mechanism
Files: `jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v`, `sim_sro.cpp`, `build_sro.sh`; legs/scoring under `two_jup/comb/sro_sim/` (`gen_sro_stim.py`, `runall.sh`, `runall2.sh`, `score_sro2.py`; outputs `q_m2p5_*`, `q_p2p5_*`, `q_m10_*`, `r_p000_*`). Taps (`wrap_byte_sro.v:65-87`): icMu, icUnd, rhStrobe, rhValidIn, rhPop, rhValidOut, fifoPush/fifoPop (POINTERS), fifoVPush/fifoVPop (guarded valids), the valid chain to Correlator_validOut, tref. Stimulus sign `gen_sro_stim.py:72-73`: negative ppm → pushes slower than pops → ring drains toward EMPTY (so `q_m2p5` reaches the benign edge). Harness defect: `sim_sro.cpp:115` `occ = (fifoPush − fifoPop) & 31` cannot distinguish 0 from 32; `score_sro2.py:107` inherits it; `:112` `exc = pushes − 12333·nframes` is not pushes−pops. Minimum change: tap `…u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.Delay_out1` (occTrue), `.pop_on_empty_FIFO`, `.push_on_full_FIFO`, and `…u_Preamble_Detector.u_FIFO.Validate_Input_Push_Pop_pushOnFullRaw` (pdPof); re-run q_m2p5 → outcomes: pushFull > 0 (ring at FULL, sign misread; fix = slack/steer at VIPP_block.v:129) / popEmpty > 0 and pushFull = pdPof = 0 (no deletion anywhere — re-open) / pdPof > 0 (Preamble_Detector FIFO deletes; fixctl bit 3 already fixes it, no rebuild). Variant trees: inject into a copy of `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (`build_sro.sh:5`), gate {−10, −2.5, 0, +2.5} × {baseline, fix}, 0.00 % loss + clean biterr on fix legs, s=0 bit-identical; extend +2.5 ppm past ~876 frames (its first FULL edge).

## 7. On-silicon judges
SEQ-BIST checker at the decoder pins (`two_jup/seqbist/stage3h_reader.sh`, host-frame mode during a daemon leg; lost_slots void on RF legs — bound the seq step); capture_r3.sh A/B PER (frame_taxonomy.py / align_frames.py, lost frames in the denominator); free instruments in the image: FIFO.v:251-252 witA/witB (confirm 0x20C/0x210 ownership on the flashed md5 — dbgcap re-purposed them 08-30, `QPSK_Rx.v:715-730`), Symbol_Synchronizer.v:497-502 DDRCAP exports (dc_countreg/mu/underflow/interp), Preamble_Detector.v:196-200 p1c_* exports.

## 8. ADRV9002 device-clock trim — none
No `dcxo`/trim/ppm attribute in the 502-node enumeration on either board; only `dev_clkout_div` (clock-OUT divider). Device clock = fixed external 38.4 MHz (`deviceClock_kHz: 38400`, `clkPllVcoFreq_daHz: 884736000`, `refClockOutEnable: true`). Removing the offset at source = hardware (shared reference). Free cross-check: the sim loses at one SRO sign only; silicon shows forward 8.4 % vs reverse 3.7 % with identical radio configs — does the losing direction map onto the losing sign?

## Decision lines (15)
1. Rate_Handle's ring HAS a full/empty guard — do not "add the missing guard".
2. The guard is exact, not stale.
3. Empty edge = skipped valid slot, no loss; only the FULL edge deletes.
4. COMB32_RTL_HUNT §1a/§2, COMB32_SRO_SIM_2p5 verdict, OVERNIGHT :19/:189 are wrong as written — retract before cutting RTL.
5. Survivor: occupancy never re-centres; reset_1 is flush-to-empty.
6. −2.5 ppm drains to EMPTY (benign) — the sim's 4.11 % is not explained by the netlist at that edge.
7. sim_sro.cpp:115 cannot tell empty from full; 5 lines to fix.
8. Gate any fix on the true taps first (three decisive outcomes).
9. The interpolator tracks the true symbol rate; mismatch = strobe rate vs rigid pop.
10. Peak_Search/Timing_Adjust/End_Generator count valids → a valid-qualified pop is legal.
11. Except Preamble_Detector.Delay10_reg (enb-tick cadence) which holds the 12,333 FIFO at full.
12. enSlack = fixctl bit 3 at 0x208 already exists, default OFF, never read on a comb leg — free test.
13. Injector rails ready (3 mirrors + both zips).
14. Routed WNS ≈ +0.11 / +0.17 ns — small fix only.
15. No ADRV9002 clock trim; hardware share only; free sign cross-check available.
