# Beat sim throughput gate (Task 1, 2026-09-01)

TXMARK netlist (`s1_rtl_txmark`, `s1_rtl_final` + `TXMARK=1 ddrcap_inject.py`), driven by
`sim_beat_long.cpp` on `wrap_byte_ddrcap`. Mode-1 (internal loopback, ROM/BIST TX source),
unforced, no register pokes.

**Correction to the brief's assumed packet cadence**: the brief's `CLKS_PER_FRAME = 197328`
constant in `sim_beat_long.cpp` is left unchanged in source (it only sizes the `--dump-at`/loop
bound), but the netlist actually emits a `packets_out` increment every **98,664 clocks**, i.e.
TWO packets per `CLKS_PER_FRAME` (with the very first packet showing a longer ~198,364-clock
prologue while acquisition locks). All frames/s and projection numbers below are in **packets**,
not `NF` units — `NF=10` produced 26 packets, not 20, because the loop bound is set in units of
the (2x too large) `CLKS_PER_FRAME` constant, not in units of packets.

## Gate as specified (500 frames) — INFEASIBLE, not run to completion

The brief's Step 4 500-frame gate was started and killed after ~10 min once independent timing
showed obj_beat_fast simulates at ~13-15 kclk/s: a 500-"frame" run (per the loop-bound units,
~50M+ clocks) would take on the order of an hour-plus per build and exceed the interactive
budget. Replaced per controller ruling with NF=10 timed runs (below) plus one bounded speedup
attempt, from which the gate verdict is computed analytically.

## NF=10 timed runs (500-frame gate substitute)

| build | flags | wall time (s) | clk | clk/s | packets | packets/s |
|---|---|---:|---:|---:|---:|---:|
| obj_beat_fast | `-O2 --threads 4` | 181.94 | 2,762,692 | 15,185.3 | 26 | 0.15391 |
| obj_beat_flat | `--public-flat-rw --savable --trace-fst -O2` | 712.81 | 2,762,692 | 3,875.6 | 26 | 0.039284 |
| obj_beat_turbo | `--threads 8 -O3 --x-assign fast --x-initial fast --noassert -CFLAGS "-O3 -march=native"` | 219.40 | 2,762,692 | 12,593.2 | 26 | 0.12764 |

obj_beat_fast has exactly one error frame — packet 2, the known 51-bit startup transient — and
zero sustained error frames: `awk '$2>0' beat_runs/gate10_fast_frames.txt` → 1 line
(`2 51 98664 0`); `awk '$2>0 && $1>2' beat_runs/gate10_fast_frames.txt` → 0 lines. obj_beat_flat
shows the identical single transient (biterr=51 total is entirely that packet-2 event, not
sustained error — `BEATLONG ... biterr=51` matches across fast/flat/turbo/restore runs
bit-for-bit, see below).

obj_beat_turbo was run alongside the other systemd units on a loaded host (competing for
cores with the concurrent flat/force builds) and came out SLOWER than obj_beat_fast despite
`-O3 -march=native --threads 8`; it is not the fastest option measured and is not recommended
over obj_beat_fast.

### Projected wall time (packets, at NF=10 measured rate)

| packets | obj_beat_fast | obj_beat_flat | obj_beat_turbo |
|---:|---:|---:|---:|
| 45,000 | 292,382 s = 81.2 h = 3.38 d | 1,145,540 s = 318.2 h = 13.26 d | 352,543 s = 97.9 h = 4.08 d |
| 200,000 | 1,299,455 s = 361.0 h = 15.04 d | 5,091,280 s = 1414.2 h = 58.9 d | 1,566,860 s = 435.2 h = 18.13 d |
| 300,000 | 1,949,183 s = 541.4 h = 22.56 d | 7,636,920 s = 2121.4 h = 88.4 d | 2,350,290 s = 652.9 h = 27.2 d |

### Gate verdict (spec §3.1: >=45,000 frames in <=24 h on either build)

**FAIL on all three builds.** The fastest build (obj_beat_fast) needs ~81.2 h for 45,000
packets, ~3.4x over the 24 h budget. obj_beat_flat is ~13x over budget; obj_beat_turbo (the
one speedup attempt) is ~4.1x over budget. No build measured here clears the gate.

**Long run cancelled by operator 2026-09-01: 45k frames ≈ 4 days is not a useful use of the
host.** No 45,000/200,000/300,000-packet run was launched; this task closes on the measured
NF=10 rates and projections above, per operator direction.

## Speedup attempt: posedge-only eval — REJECTED

Bounded (<45 min) attempt per controller ruling: `-DBEAT_POSEDGE_ONLY` changes
`sim_beat_long.cpp`'s `tick()` from `clk=0;eval();clk=1;eval()` to `clk=1;eval();clk=0` (no
settle eval on the negedge half of the cycle), built as `obj_beat_posedge` (same flags as
obj_beat_fast, `-O2 --threads 4`).

Result: **REJECTED, not bit-identical.** A 10-"frame" run on obj_beat_posedge reached the
same clock target (`clk=2,762,692`) in 0.54 s but produced **`packets=0 biterr=0`** — the
per-frame log (`gate10_posedge_frames.txt`) is empty, versus 26 packets on the two-eval build
in the same clock span. Dropping the negedge settle eval breaks packet detection entirely (not
merely a small timing skew); the design needs the second eval per cycle to propagate
combinational logic before the next posedge. The `#ifdef BEAT_POSEDGE_ONLY` code path is kept
in `sim_beat_long.cpp` (compiles, both builds tested), but obj_beat_posedge / obj_beat_turbo's
speedup is not used for the recommended build.

**Recommended build: obj_beat_fast** (`-O2 --threads 4`, no `--public-flat-rw`/`--savable`/
`--trace-fst`) — fastest measured, zero error frames, no register-dump/checkpoint capability
needed for a plain long run. obj_beat_flat is reserved for checkpoint/dump/trace work where
those features are required, at ~4x the wall-clock cost of obj_beat_fast.

## Checkpoint restore identity check (brief Step 5, reduced size)

- Straight run: `./obj_beat_flat/Vwrap_byte_ddrcap 10 beat_runs/gate10_flat --ckpt-every 8`
  → packets 1-26, checkpoints at packet 8/16/24 (`gate10_flat_ckpt_8.bin`,
  `_ckpt_16.bin`, `_ckpt_24.bin`).
- Restore run: `./obj_beat_flat/Vwrap_byte_ddrcap 10 beat_runs/gate10_restore --restore
  beat_runs/gate10_flat_ckpt_16.bin` → `restored beat_runs/gate10_flat_ckpt_16.bin at clk
  1678324 packet 16`, then continued to `BEATLONG NF=10 packets=26 biterr=51 rstcs=0
  clk=2762692` (identical final tally to the straight run).
- `diff <(awk '$1>16' beat_runs/gate10_flat_frames.txt) beat_runs/gate10_restore_frames.txt`
  → **no diff, 10/10 lines identical** (packets 17-26, errs/clks/rstcs/mu/cnt columns all
  match). **PASS.**

Note: `sim_beat_long.cpp`'s `--savable` serialization block as given in the brief did not
compile as written — `VerilatedContext` must be passed to `operator<<`/`operator>>` as a
pointer (`ctx.get()`), not a dereferenced reference (`*ctx`), and the `long clk`/`lastClk`
locals are ambiguous against the `uint32_t/uint64_t/double/float/bool` operator overload set
in `verilated_save.h` (Verilator 5.020) and needed explicit `(uint64_t)` casts (with `uint64_t`
temporaries on restore). Fixed in `sim_beat_long.cpp`; `--savable` itself verilated cleanly, no
module was rejected — this was strictly a C++ typing fix in the driver, not a `--savable`
netlist incompatibility.

## Forced-kick sanity control (brief Step 6, reduced size: NF=60, K=20)

`Vforce` = `sim_burst_force_txmark.cpp` (copy of `sim_burst_force.cpp` with
`Vwrap_byte_ce`->`Vwrap_byte_ddrcap`, the `wrap_byte_ce__DOT__` prefix ->
`wrap_byte_ddrcap__DOT__`, and `t->iq_debug_mux=3` added to the init line) built against the
TXMARK netlist with `--public-flat-rw`.

- `./obj_beat_force/Vforce 60 20 ss beat_runs/pc_ss` → `BURSTFORCE ... sel=ss NF=60 K=20
  packets=102 biterr=4995 rstcs=0`. `pc_ss_frames.txt` line 21 is a `# FORCED ...` comment
  (not a packet row), so the mean must filter it out by the packet field, not by line number
  (`NR>21` mis-includes it and pulls the mean down to 59.52/n=82). Correct command:
  `awk '$1 !~ /^#/ && $1>21 {s+=$2;n++} END{print s/n, n}' beat_runs/pc_ss_frames.txt` →
  **60.2593** (n=81 packets) — within the expected 47-68 band, framesync intact throughout.
- `./obj_beat_force/Vforce 60 20 none beat_runs/pc_none` → `BURSTFORCE ... sel=none NF=60
  K=20 packets=126 biterr=51 rstcs=0`. Same command on `pc_none_frames.txt`:
  `awk '$1 !~ /^#/ && $1>21 {s+=$2;n++} END{print s/n, n}' beat_runs/pc_none_frames.txt` →
  **0** (n=105 packets) — matches expected 0.0.

This confirms the TXMARK netlist can show the August-characterized ~60 errs/frame burst
signature with framesync intact, so a later clean long run on this netlist is a credited null
result rather than an instrument that can't see a burst even when one is forced.
