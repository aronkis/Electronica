# Run logs — overnight 2026-08-14/15 campaign (primary evidence)

Every PER number, gate verdict and A/B result quoted in `HANDOFF_20260815.md`,
`docs/current-state.rst` and `skidfix/SKID_BUILD.md` traces to a line in one of these
files. They were previously only at repo root, where `.gitignore`'s `*.log` rule made
them invisible — so the docs cited numbers that could not be checked against anything in
the repo. Banked here (96 KB total) to close that gap.

| file | what it proves |
|---|---|
| `rb_baseline.log` | Post-drain-budget-fix baselines: rev 1.20 % (920/76369, UB 1.28 %), fwd 8.22 % (5508/67041, UB 8.43 %). Also the "RX drain budget: 4" deploy confirmation on both boards. |
| `final_matrix.log` | Formal reverse 3-run matrix: 2.25 / 1.49 / 1.43 %, **pooled 1.72 % (3944/228659, CP95-UB 1.78 %)**. First fwd attempt wedged (148-side, budget active) — the one unexplained wedge of the night. |
| `fwd3.log` | Forward 3-run matrix on the v3 image: 8.23 % (5295/64303, UB 8.45 %), 8.32 % (5510/66217, UB 8.53 %), 8.27 % (5464/66057, UB 8.48 %). |
| `fwd_v2_soak.log` | The v2-skid regression: fwd 13.78 %, plus the all-zero `0x9D300008` witness reads that exposed the marker blindness. |
| `fcab.log` | Reverse frozen-cal A/B: all RX tracking cals off → 1.51 %, worse than baseline. Cal state readback before *and* after (restored). |
| `cal_bisect.log` | Reverse 3-way cal bisect: fic-off 1.33 %, rfdc+bbdc-off 4.73 %, agc+rssi-off 1.76 % — no config beats baseline. |
| `cfo_ab.log` | 0x184 CFO poke: register reads back `0x50000` unchanged before and after → the poke is inert on 146's image (canary regs, not loop-gain). |
| `skid_flash.log` / `skid2_flash.log` / `skid3_flash.log` | The three flash chains with their rails: readback verify, NAK=4, two-pass health gate, and (attempts 1–2) automatic rollback to e49c011b. |
| `skid_tb_ab.log` | DMA-contract testbench A/B: m1 naive skid deadlock (wcnt≈0), m0+tick 16/403 corrupt, m2 0/403 with bitwise-identical delivery. |
| `dip_ab.log` | Ready-dip replay legs — **note: run against the Jul-25 netlist, not the flashed generation; provisional pending the rebuild** (see `rtl_sim/build_replay_lock.sh`). |
| `wit_sample.log` | The v2 witness sampling run (6689 samples, single transition) that proved the marker blindness. |

Not banked: the multi-GB capture trees (`r3cap/`, `floatgap_n3/`, `simgen_symsync/`) and
build logs — those stay on local disk.
