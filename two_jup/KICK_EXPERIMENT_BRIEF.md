# Forced-kick displacement experiment — brief (operator-directed, 2026-09-01 19:55)

## Question (pre-registered BEFORE any run)
On hardware the beat is a DISPLACEMENT: at the demod input (ddrcap sel6) each frame's 16-symbol word
at marker+1 either maps to offset 0 or JUMPS in a single frame onto one of the known rungs
{6176, 6240, 6299, 6363, 6432 plain; 6489, 6548 I/Q-swapped}, with no intermediate offsets, the data
bit-exact at the new offset (the word is FOUND in the injective map), and the marker unmoved.
Does a forced symbol-sync kick in the netlist reproduce THAT, or only produce bit errors?

Predictions, written now:
- **A (kick = beat mechanism):** after the force, ≥ 3 consecutive frames map to a SINGLE known rung d
  (found in the map), the transition from 0 to d happens between two consecutive frames, and no frame
  maps to an offset strictly between 0 and 6176.
- **B (kick ≠ beat):** frames after the force are `None` (word not in the map = corrupted data) for
  most frames, OR map to a non-rung offset, OR walk through intermediate offsets.
- **Positive control (must pass before A or B is read):** the unforced run (`none`) maps EVERY frame
  after frame 8 to offset 0 with the tap3 map. If it does not, the map does not apply to this netlist
  build and the result is VOID (report that; do not reinterpret).
- Comparators run alongside: `ps` (Peak_Search reference +32), `ta` (Timing_Adjust reference +32),
  `slip1` (joint reference +1). The August table says ps/ta give a CONSTANT ~48-68 errs/frame; the
  question is whether those look like a rung displacement too, which discriminates "kick into the
  timing loop" from "frame reference shift".

## Method (all local, no board, no flash)
Working dir: `jupiter_240k5_byte/rtl_sim`. Build already present: `obj_beat_force/Vforce` (flat
`--public-flat-rw` build of the TXMARK netlist with `wrap_byte_ddrcap.v`, driver
`sim_burst_force_txmark.cpp`). Netlist = `s1_rtl_txmark`.

1. Copy `sim_burst_force_txmark.cpp` → `sim_kick_taps.cpp` and add: (a) argv[5] = ddrcap selector
   (default 6), setting `t->iq_debug_mux = ((sel & 0xF) << 16) | 3`; (b) argv[6] = output .bin path;
   on every clock where `t->ddrcap_valid` is 1, `fwrite` a record of four little-endian int16
   `{ddrcap_i, ddrcap_q, ddrcap_mark_demod, ddrcap_mark_fec}` (see `sim_golden_taps.cpp` in the plan
   brief task-2 for the exact record code). Keep the existing per-frame log and the forcing code
   unchanged. Note the existing FIXCTL/K2/sel2 optional args shift — simplest: put SEL and OUT as
   argv[5] and argv[6] and drop FIXCTL/K2/sel2 (not needed here).
2. Build: `verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap
   -y s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback -y . wrap_byte_ddrcap.v sim_kick_taps.cpp
   -Mdir obj_kick -o Vkick`.
3. Run FIVE cases concurrently (each single-threaded, ~4 kclk/s, ~20 min): NF=20, K=12 (force at
   packet 12), sel=6, into `beat_runs/kick_<case>.bin` + `beat_runs/kick_<case>_frames.txt`:
   `none`, `ss`, `ps`, `ta`, `slip1`. Launch each under
   `systemd-run --user --unit=kick-<case>-$(date +%H%M%S) --collect -p WorkingDirectory=$PWD bash -c './obj_kick/Vkick 20 12 <case> beat_runs/kick_<case> 6 beat_runs/kick_<case>.bin > beat_runs/kick_<case>.log 2>&1'`.
   Poll with `sleep 120` (max) between checks of the frames files; never one long wait.
4. Score each .bin with the EXISTING scorer, unchanged:
   `python3 ../../two_jup/t6_score_large.py beat_runs/kick_<case>.bin 1 | tee beat_runs/kick_<case>.score`
   (skew 1 = the §36 marker+1 anchoring). Also produce the per-frame offset sequence: add `--seq`
   is NOT available — instead write a 15-line `kick_seq.py` beside it that reuses `t6_score_large.load_map`
   and prints `frame offset` per marker (same 16-word packing, skew 1) so the transition frame is visible.
5. Cross-check the frame log: the packet at which errs first ≥ 20 must equal the frame at which the
   offset leaves 0 (± 1 frame).

## Report (write to .superpowers/sdd/2026-09-01-beat-tap-compare/kick-report.md)
Per case: positive-control verdict, per-frame offset sequence around the force (frames 8..44),
counts aligned / on-rung (which rung) / intermediate / None, transition type (single-frame jump or
not), first-error packet vs first-displacement frame, and the label **reproduced in sim**. Then the
overall verdict against predictions A/B exactly as pre-registered, and one sentence on what the
comparators say. Do NOT reinterpret a failed positive control. Return the short status contract.
