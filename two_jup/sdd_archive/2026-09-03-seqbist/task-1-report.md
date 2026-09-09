# Task 1 (T0a RTL) report — SEQ-BIST

Status: **complete, unit gate green** (`SEQBIST_UNIT_EXIT=0`). Desk only — no board
contact, no push, no subagents. All numbers below are **[sim]**.

## Deliverables

| file | what |
|---|---|
| `jupiter_240k5_byte/rtl_sim/rx_seq_checker.v` | new frame sequence/loss checker (16 counters) |
| `jupiter_240k5_byte/rtl_sim/cnt_mux32.v` | 32:1 readout mux, drop-in superset of `cnt_mux16` |
| `jupiter_240k5_byte/rtl_sim/qpsk_traffic_gen_v2.v` | TGEN + `skip_every` / `corrupt_every` |
| `two_jup/seqbist/gen_frames.py` | frame builder + golden counter model for the sims |
| `jupiter_240k5_byte/rtl_sim/seqbist_unit/tb_rx_seq_checker.v` | checker unit sim (6 phases; also run with `-DNOCRC`) |
| `jupiter_240k5_byte/rtl_sim/seqbist_unit/tb_tgen_v2.v` | v1/v2 equivalence + skip/corrupt cadence |
| `jupiter_240k5_byte/rtl_sim/seqbist_unit/tb_cnt_mux32.v` | slot mapping + cnt_mux16 compatibility |
| `jupiter_240k5_byte/rtl_sim/seqbist_unit/run_unit.sh` | the gate; last line `SEQBIST_UNIT_EXIT=<code>` |

Originals (`jupiter_byte_txfixF3_build/rx_seam_checker.v`, `tx_seam_checker.v`,
`qpsk_traffic_gen.v`, `jupiter_240k5_byte/rtl_sim/cnt_mux16.v`) are **untouched**.

## Port lists (binding for the Task 2 BD patch)

```verilog
rx_seq_checker #(parameter integer WITH_CRC = 1) (
  input  clk, rst_n, en, freeze, tgen_mode,
  input  [63:0] data, input valid, user, ready,          // snoop-only
  output [31:0] cnt0 .. cnt15);                          // -> cnt_mux32 c16..c31

cnt_mux32 (
  input clk, input [4:0] sel,
  input [31:0] c0 .. c31,
  output reg [31:0] q);

qpsk_traffic_gen_v2 (                                    // same ports as v1
  input clk, resetn, input [31:0] ctrl, gap,
  input [63:0] host_data, input host_valid, host_first, output host_ready,
  output [63:0] dut_data, output dut_valid, dut_first, input dut_ready);
```

Wiring, per the interface contract:
`en` = tgen_rx ctrl @0x9D410000 (spare bit — Task 2 picks; contract fixes only
`freeze` = **bit 3**), `freeze` = 0x9D410000 bit 3, `sel` = tgen_rx gap word
@0x9D410008 **bits [31:27]** (one bit wider than the old `[31:28]`), output on
tgen_rx_wit_gpio ch2 @0x9D450008. `data/valid/user/ready` = the same DUT RX byte
pins `rx_seam_checker` already taps (`two_jup/sim_repro/resynth_probe3.tcl:17`).

## Fix round 2 (review I-1 / I-2 / I-3, M-1, M-2) — ports UNCHANGED

Task 2's `create_bd_cell -reference rx_seq_checker` and its port list are
untouched; the only addition is a **parameter**, which the BD patcher passes as
a cell property.

**I-1 — 2-FF synchronizers on `en`, `freeze`, `tgen_mode`.** `clk` is
`axi_adrv9001/adc_1_clk` while the three control bits come from
`tgen_rx_ctrl_gpio` on the PS AXI clock. All three are now taken through
`reg [1:0] en_s/fr_s/tm_s` inside the module and every use is of the
synchronized copy (`en_q`, `fr_q`, `tm_q`) — the edge detector, `acc`, the
freeze hold and the CRC-mode mux. ~6 FFs. Without this a metastable `en`
sample fires the edge detector and silently wipes all 16 counters mid-run,
which the host scorer cannot distinguish from a quiet link.
**M-1** is folded in: `en_d` now has its own reset (`if (!rst_n) en_d <= 1'b0`)
and is driven from `en_q`, so there is no `X` at t=0 and no second driver.
*Host consequence:* `en`, `freeze` and `tgen_mode` need ~3 `adc_1_clk` cycles to
take effect. At the mission rate that is sub-microsecond, far below any devmem
round trip, so no host-side delay is required — but a readout script must not
assume the same-instant effect of a register write.

**I-2 — `parameter WITH_CRC = 1`, a compile-time escape hatch.** With
`WITH_CRC = 0` the CRC32 accumulator, the 64-bit-parallel combinational tree and
its register are inside a `generate` that is **not instantiated**;
`tgen_mode = 1` still works in full (the check is just
`crc_field == 0x54474E21`), and with `tgen_mode = 0` there is nothing to check
against, so the verdict is skipped and **both `good` and `crc_fail` read 0**.
Runtime gating would have removed nothing from the netlist — `crc <= crc64(...)`
ran unconditionally — which is why the plan's risk-table row ("drop the payload
PN scorer / drop the CRC at runtime") is not implementable and should be
replaced by "build with `WITH_CRC=0`". Every tgen_mode stage (fabric loopback,
RF self-reception, both RF legs) is unaffected by `WITH_CRC=0`.
Verified: `run_unit.sh` lints **both** parameterisations and runs the whole
6-phase checker testbench twice, once per build (`tb_rx_seq_checker` and
`tb_rx_seq_checker_nocrc`); every tgen_mode phase is bit-identical and phase 4
reports `good=0 crc_fail=0` under `WITH_CRC=0` exactly as specified.

**I-3 — `corrupt_every` blinds `tx_seam_checker`.** `tx_seam_checker.v:94` arms
only on a good magic (`first && hdr_magic_ok && hdr_fill_hi_ok`), and TGEN v2's
`corrupt_every = M` flips header byte 0. So during a `corrupt_every` run the TX
checker **skips every M-th frame**: its `frames_checked` runs short by ⌊F/M⌋ and
its `bit_errors` never covers those frames. **Any Task 3 gate or Task 4 scorer
identity of the form "TX `frames_checked` == RX `frames`" will fail spuriously
under this positive control.** Either subtract ⌊F/M⌋ or assert the TX checker
only in phases where `corrupt_every = 0`. Documented in the RTL header as well.

Not changed (accepted as notes): **M-3** `used_bytes` is latched on magic-bad
frames too — inherited verbatim from `rx_seam_checker.v:80`, harmless because the
verdict is gated on `hdr_ok`, and changing it would diverge from the parent.
**M-4** the `gap` 27-bit narrowing, already documented. **M-5** the three reset
conventions (`rst_n` / `resetn` / none), which `patch_seqbist_tcl.py`'s
`sb_require_driven` lists must keep matching exactly.

## Counter semantics (cnt_mux32 slots 16..31)

| slot | cnt | meaning | resolved at |
|---|---|---|---|
| 16 | frames | user-marked words accepted | header word |
| 17 | good | magic ok AND crc ok AND in-order | verdict |
| 18 | garbage | magic/len not parseable | header word |
| 19 | crc_fail | magic ok, crc check failed | verdict |
| 20 | lost_slots | Σ (seq − expected) over forward gaps | header word |
| 21 | gap_events | forward gaps (seq > expected) | header word |
| 22 | gap1 | gaps of exactly 1 slot | header word |
| 23 | gap2 | gaps of exactly 2 slots | header word |
| 24 | gap3plus | gaps of ≥ 3 slots | header word |
| 25 | dup_or_reorder | seq ≤ last_seq on a good-magic frame | header word |
| 26 | last_seq | raw seq of the last good-magic frame | header word |
| 27 | int_last | interval of the most recent binned gap event | header word |
| 28 | int_hist_lt30 | intervals < 30 | header word |
| 29 | int_32 | intervals == 32 | header word |
| 30 | int_33 | intervals == 33 | header word |
| 31 | int_other | intervals 30, 31 or ≥ 34 | header word |

Rulings made and implemented (documented in the RTL header too):

- Only frames with a **good magic** take part in seq tracking. `exp = last_seq+1`.
  `last_seq <= seq` in **every** case, duplicates included, so a duplicate does not
  poison the next comparison. A genuine reorder therefore shows as
  2 `gap_events` + 1 `dup_or_reorder`, not as one reorder.
- The first good-magic frame after a clear only seeds `last_seq` and counts as
  in-order.
- Seq **wraparound is not handled** (2^32 frames ≈ 40 days at 1245 f/s).
- **`frames != good + garbage + crc_fail`.** The frame that follows a gap is
  magic-ok, crc-ok and *not* in-order, so it is in none of the three. Do not
  write that identity as a gate assertion.
- `garbage` is counted at the header word (so it stays consistent with the seq
  logic); `crc_fail`/`good` at the verdict, ~191 words later. A frame truncated
  by a short-frame event is counted in `frames` (and possibly `garbage`) but
  never reaches a verdict.
- A **clear (en rising edge) wipes both the live counters and the shadow
  registers**, even while `freeze` is asserted, so a clear issued inside a host
  freeze→read→unfreeze window is never silently dropped.
- `freeze=0` → shadows track the live counters with one clock of latency;
  `freeze=1` → the 16 outputs hold while the live counters keep running.

### Interval units — EMITTED frames (operator ruling 2026-09-03, fix round 1)

The interval of a gap event is the **header seq delta** between it and the
previous gap event:

```
interval = seq(this gap's revealing frame) - seq(previous gap's revealing frame)
```

where the revealing frame is the good-magic frame whose seq exceeded the
expected one. One extra 32-bit register (`prev_gap_seq`) holds the reference;
no new mux slot. The first gap after a clear only sets the reference — it is
not binned and does not update `int_last`.

This is in **emitted-frame units and needs no loss correction**: a comb that
drops one frame every 32 emitted frames reads `int_last = 32` regardless of how
many frames were received in between, and regardless of how many other frames
were lost or arrived magic-corrupted inside the period. It is therefore
directly comparable with the 32.4-frame on-air comb, which will split between
`int_32` and `int_33` as the plan's prereg expects. (The earlier
received-frame definition would have read ~31.4 and put the comb's mass in
`int_other`; that is now gone.)

Boundary that remains: the contract's old name `int_hist_30_35` is gone —
intervals of **30 and 31 land in `int_other`**, not in `int_hist_lt30`. With
emitted-frame intervals the interesting neighbourhood is 32.4, so **`int_other`
is bimodal**: near-comb intervals (30, 31) sit in the same bin as far ones
(>= 34). A non-zero `int_other` is therefore NOT by itself evidence of noise,
and T2's flatness prereg must not read it that way. To resolve a period near
the boundary, the host scorer should sample **`int_last` (slot 27) across
successive freezes** and build the distribution host-side, rather than relying
on the four-bin histogram alone.

**Positive-control calibration — VERIFIED end-to-end on the RTL** (not merely
derived): `tb_rx_seq_checker` phases 5 and 6 drive the exact frame streams
TGEN v2 emits for `skip_every = 5` and `corrupt_every = 8` through the real
checker and assert every counter. The two controls differ, because
`skip_every` removes a seq number without removing a frame from the stream:

| control | emitted interval `int_last` reads | gap size |
|---|---|---|
| `skip_every = N` | **`N + 1`** (N emitted frames plus the skipped seq value) | 1 (`gap1`) |
| `corrupt_every = M` | **`M`** exactly | 1 (`gap1`) |
| real loss, period p | **`p`** | as lost |

Measured [sim]: `skip_every=5` over 60 frames -> `frames=60 gap_events=11
gap1=11 int_last=6 lost_slots=11 garbage=0`; `corrupt_every=8` over 60 frames
-> `frames=60 garbage=7 gap_events=7 gap1=7 int_last=8`.

The plan's T2 text ("interval histogram peaked at N" for `skip_every = N`)
must read **N+1**; `corrupt_every = M` peaks at `M`. Both must be run before
any null is credited, and `corrupt_every` is the one whose interval equals its
control value directly.

### Enable discipline

`en` is a level, not a pulse: **it must stay HIGH for the whole run.** The
clear happens on the rising edge only; while `en` is low the checker counts
nothing (`acc = valid && ready && en`). The host tool therefore drives `en`
low → high **once, after TGEN is armed** (TGEN restarts seq at 1 on its own
enable rise, so clearing before that yields a spurious `dup_or_reorder`), and
leaves it high. Confirmed against the RTL: `wire clr = en && !en_d`, and every
counter is gated on `acc`.

### `good` is not a CRC pass rate

`good` folds in-order into the verdict, so a clean-CRC frame that follows a gap
is not counted. Derive the pass rate instead:

```
crc_ok = frames - garbage - crc_fail - truncated
```

There is **no `short_frm` counter** in the 16 (no slot budget). On 148 the old
slots 1..6 (`rx_seam_checker`) still give the truncation cross-check; Task 2's
patch ties 146's slots 0..15 to a zero constant, so on the reverse leg the
checker has no truncation witness at all — `truncated` must be assumed 0 there
and the derivation stated as such.

## TGEN v2 control-word encoding

```
ctrl @0x9D400000   [0] enable
                   [15:4] fill_len (0..1516; fill <= 47 wedges the link — use >= 100)
                   [31:16] N = skip_every    when gap[27] == 0
                           M = corrupt_every when gap[27] == 1
                           0 in either mode = OFF
gap  @0x9D400008   [26:0] gap in clocks, frame end -> next frame start
                   [27]   mode: 0 = ctrl[31:16] is skip_every, 1 = corrupt_every
                   [31:28] reserved, must be 0
```

- `skip_every = N`: every N-th generated frame is the last before a deliberately
  skipped sequence number — the *following* frame is emitted with seq advanced by
  2. Over F frames the checker must see ⌊(F−1)/N⌋ `gap_events`, all `gap1`, and
  `int_last == N + 1` -- skip_every removes a seq NUMBER but not a stream
  slot, so the emitted seq delta between consecutive gaps is N+1, not N (see
  the interval-units section; the plan's T2 text says N and must be corrected).
- `corrupt_every = M`: every M-th generated frame has header byte 0 (the 0x51
  magic) XORed with 0xFF (→ 0xAE). seq/PN/pad untouched, so the checker must
  count exactly ⌊F/M⌋ in `garbage` — and, because the corrupted frame drops out
  of seq tracking, an accompanying `gap1` per corrupted frame, with
  `int_last == M` exactly. The extra gap1 per corrupted frame is expected and
  the host scorer must not read it as real loss.
- The two fields are mutually exclusive by construction (one mode bit, one
  cadence counter): a run exercises one control at a time so its count is
  unambiguous.
- `gap` is 27 bits in v2 (32 in v1). 27 bits = 134 M clocks ≈ 1.3 s at 100 MHz,
  far beyond any usable frame period. This is the **only** behavioural
  difference from v1 with the new fields at 0.

The only edit on the seq/PN path is `wire [31:0] seq_next = seq + (skip_lat ? 2 : 1)`
substituted into both the `seq <=` and the `pn <=` expressions in `S_GAP`, so
bit-identity at `skip_every = 0` is structural, not hoped-for. Proven anyway:
`tb_tgen_v2` phase A compares v1 and v2 `{dut_data, dut_valid, dut_first,
host_ready}` on **every clock** across the pass-through phase and 200 complete
frames under a shared pseudorandom `dut_ready` — 0 mismatches, 36 380 accepted
words. A mutation run (skip_every forced to 7 in phase A) produced 37 197
mismatches, so the comparator is live.

## Test summary  [sim]

`jupiter_240k5_byte/rtl_sim/seqbist_unit/run_unit.sh` → `SEQBIST_UNIT_EXIT=0`
(iverilog 12 + verilator 5.020; both present on this host).

- **lint** `verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL
  -Wno-UNUSEDPARAM -Wno-VARHIDDEN -Wno-BLKSEQ -Wno-WIDTHEXPAND` on all three new
  modules, plus an explicit refusal of LATCH / ALWCOMBORDER / CASEINCOMPLETE:
  all clean. BLKSEQ/WIDTHEXPAND are waived because the *originals* raise exactly
  those two classes (`rx_seam_checker`: 3 BLKSEQ, 4 WIDTHEXPAND, 2 WIDTHTRUNC;
  `qpsk_traffic_gen`: 2 BLKSEQ, 5 WIDTHEXPAND). `rx_seq_checker` is strictly
  cleaner than its parent — the 2 WIDTHTRUNC are gone.
- **tb_rx_seq_checker** — 137 scripted frames driven **back-to-back** (zero idle
  cycles, which exercises the verdict / next-user-word same-cycle path), all 16
  counters compared exactly against the Python golden model:
  `frames=137 good=128 garbage=1 crc_fail=1 lost_slots=15 gap_events=7 gap1=3
  gap2=2 gap3plus=2 dup_or_reorder=1 last_seq=150 int_last=40 int_lt30=2
  int_32=1 int_33=1 int_other=2` — i.e. lost-1 / lost-2 / lost-5, a duplicate, a
  magic-corrupted frame, a CRC-corrupted frame, and gap events at emitted
  intervals 6, 30, 2, 32, 33, 40, landing one in **each** of the four interval
  bins. **The interval-32 case is built with two intervening lost frames**, so
  it lands in `int_32` only because the interval is a seq delta and not a
  received-frame count — the discriminating case the ruling asks for. Then:
  freeze atomicity (7 more frames driven with `freeze=1`, all 16 outputs held,
  then caught up on release), clear-on-enable, `en` asserted **mid-frame** (the
  partial frame's tail correctly ignored, the next 3 whole frames counted), and
  a `tgen_mode=0` pass over real host-CRC32 frames **with idle bubbles**
  (`frames=11 good=9 crc_fail=1 lost_slots=2 gap2=1`). Negative control:
  perturbing one expected value produced
  `TB_FAIL phase1 slot29 (int_32): got 1 want 9`.
- **tb_rx_seq_checker phases 5/6 (positive-control calibration, end-to-end)** —
  the exact frame streams TGEN v2 emits for `skip_every=5` and
  `corrupt_every=8`, driven through the real checker, all 16 counters exact:
  `skip_every=5 frames=60 gapev=11 gap1=11 int_last=6 lost=11` (i.e. N+1) and
  `corrupt_every=8 frames=60 garbage=7 gapev=7 gap1=7 int_last=8` (i.e. M).
  This makes the calibration Task 3's G2/G4 gates preregister against a tested
  number rather than a hand derivation.
- **tb_tgen_v2** — equivalence as above; `skip_every=5`: 39 `+2` steps and 160
  `+1` steps over 200 frames, every `+2` exactly on the 5-frame cadence, first
  seq 1; `corrupt_every=4`: 50 of 200 corrupted, all on the 4-frame cadence, seq
  contiguous 1..200.
- **tb_rx_seq_checker_nocrc** — the same 6 phases against the `WITH_CRC=0`
  build: phases 1, 2, 3, 5, 6 (all `tgen_mode=1`) bit-identical to the
  `WITH_CRC=1` run, and phase 4 (`tgen_mode=0`) reports
  `frames=11 good=0 crc_fail=0 lost_slots=2 gap2=1` — the verdict correctly
  skipped, every non-CRC counter unaffected.
- **tb_cnt_mux32** — all 32 slots return their own input, and slots 0..15 match a
  parallel `cnt_mux16` instance bit-for-bit (the BD-swap compatibility claim).

Vectors, `.vvp` files and `run_unit.log` are regenerated by the runner and
git-ignored (`seqbist_unit/.gitignore`).

## Resource estimate (reasoning, no synthesis run)

**The plan's risk-table figure of ≈300 LUTs is too low.** Per instance:

- `rx_seq_checker`: 16 live + 16 shadow 32-bit counters = **1024 FFs**, plus
  ~90 FFs of parse state (widx, crc, crc_field, used_bytes, magic_frames,
  prev_gap_mark, flags) ≈ **1120 FFs**. Logic: 16 32-bit incrementers
  (~16×32 = 512 LUTs, most of them narrow), one 32-bit subtract for `gap_size`,
  one for `ival`, three 32-bit comparators, and the **CRC32 datapath** — 8
  unrolled byte steps in `crc64`, i.e. a 64-bit-wide CRC32 combinational tree,
  which on this lineage is the single largest and slowest block (order
  **400–600 LUTs** and the deepest path). Total ≈ **1000–1400 LUTs / ~1120 FFs**.
- `cnt_mux32`: 32:1 on 32 bits = 32 × (32:1 mux) ≈ **160 LUT6** + 32 FFs; it
  replaces a 16:1 (~80 LUT6), so the delta is small.
- `qpsk_traffic_gen_v2` vs v1: +16-bit `mcnt` + 2 flag FFs + one 16-bit
  comparator + one 16-bit incrementer ≈ **+25 FFs / +40 LUTs**. Negligible.

Shape correction from the review: the CRC is **combinational over the full
64-bit word** (`crc64` unrolls 8 `crc8b` calls, each 8 shift/XOR steps), i.e. one
64-bit-parallel CRC32 tree in a register-to-register feedback loop. A parallel
CRC32 is a linear function that maps to roughly 3 LUT6 levels, so the risk here
is **utilisation and congestion, not path depth** — and on 148 this is the
*second* such tree, because `patch_seqbist_tcl.py` keeps `rx_checker`
(`rx_seam_checker`) instantiated on slots 1..6.

**If routed WNS or utilisation goes negative, build with `WITH_CRC=0`** (fix
round 2, I-2). That is now a real compile-time removal; runtime gating on
`tgen_mode` removes nothing, because the accumulator ran unconditionally. It
costs nothing in any `tgen_mode` stage. The PN scorer is already not present.

## Payload PN scorer: NOT delivered (by the contract's own condition)

All 16 checker outputs are seq/interval counters, so a PN scorer would need
extra mux slots, and the contract makes it conditional on costing none. It is
deferred, as ruled ("seq counters first"). `tx_seam_checker.v`'s popcount
scorer remains the TX-side reference if it is wanted later; it would need its
own GPIO channel (txchk_gpio ch1/ch2), not a cnt_mux32 slot.

## What the Task 2 (BD patch) author must know

1. **`sel` widens from `gap[31:28]` to `gap[31:27]` at 0x9D410008.** That steals
   bit 27 from the tgen_rx (`qpsk_traffic_gen_rx2`) gap word, whose documented
   layout is ctrl `[31:16] word_gap` / gap `[31:28] mux select` — confirm bit 27
   of *that* word is genuinely unused before wiring, and note that any host
   script writing a 4-bit select at [31:28] now reads slots 0..15 only when it
   also leaves bit 27 clear. `two_jup/loopchk_run.sh:12-14` is the idiom to fix.
2. **Slots 0..15 must keep their existing sources.** `tb_cnt_mux32` asserts
   cnt_mux32 == cnt_mux16 for sel 0..15, so the swap is safe *if* c0..c15 are
   re-wired identically (0 acc_user, 1 frames, 2 crc_ok, 3 crc_fail, 4 magic_bad,
   5 short, 6 orphan, 7 acc_beats, 8..15 tx_starve_witness).
3. **Arming order on silicon:** TGEN restarts seq at 1 on its enable rise, so the
   host must pulse the checker's `en` **after** arming TGEN — otherwise the first
   read shows a spurious `dup_or_reorder = 1` (and possibly a bogus gap). Worth
   putting in `seqbist_run.sh` (Task 4) as a hard ordering.
4. `rx_seq_checker` is **snoop-only**: it drives nothing, so it can hang off the
   existing DUT RX byte pins with no seam and no back-pressure risk. `ready` is
   an input (the DUT-side ready), not driven.
5. The 146 vendh variant needs `qpsk_traffic_gen_v2` (not v1) plus tgen_ctrl_gpio
   at the same 0x9D400000/0x9D400008 addresses, or `skip_every`/`corrupt_every`
   positive controls will not exist on that board.
6. Task 2 placed `en` / `tgen_mode` on 0x9D410000 bits 4/5, which on 148 alias
   `qpsk_traffic_gen_rx2`'s `fill_len[1:0]`. Documented there, but it means any
   existing host write to that word (`two_jup/loopchk_run.sh:12-14`) will clobber
   the checker's `en` mid-run and silently clear every counter. Task 4's
   `seqbist_run.sh` must own that word for the whole run.
7. Reset polarity differs between the modules by inheritance:
   `rx_seq_checker` takes **`rst_n`** (contract), `qpsk_traffic_gen_v2` keeps v1's
   **`resetn`**, `cnt_mux32` has no reset. Same active-low net, different names.
