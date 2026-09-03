# Netlist provenance for the flashed BEATFIX v3 image

**Flashed image:** `fe5bd8a4fe19` on 148 (BEATFIX v3, `fixctl`@0x208 default 0 = legacy).
**Producing build:** `jupiter_byte_beatfix2_build/` (BOOT.BIN md5 verified, Task 1 Step 1).

## The matched netlist

    V3_NETLIST_DIR = jupiter_240k5_byte/rtl_sim/s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback
    V3_CADENCE     = 2
    HARNESS        = wrap_byte_bf2.v + sim_byte_ce.cpp  (top module wrap_byte_ce)

Method (same as `build_replay_lock.sh`): the DUT netlist actually synthesized into the
image was recovered from `vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip`
(`hdl/TxRxCompo_ip_src_TxRxComposite.v`) and line-diffed against every on-disk candidate.

## Diff census

The brief's original five-directory candidate list:

| candidate | diff lines vs synthesized | verdict |
|---|---|---|
| `jupiter_byte_beatfix2_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback` | `--` under a literal `TxRxComposite.v` check | filename-convention artifact (see below), NOT "no netlist"; direct compare of its actual file (`TxRxCompo_ip_src_TxRxComposite.v`) against the extracted zip member is a 0-line diff (tautological — it *is* the zipped source) |
| `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |
| `jupiter_byte_fsv2_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback` | 443 | different generation |
| `jupiter_byte_tmr146_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback` | 1074 | different generation |
| `jupiter_byte_wit3_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback` | 443 | different generation |

Extended candidate list (staged copies under `jupiter_240k5_byte/rtl_sim/s1_rtl_*`, needed
because `*_build`'s own hdlsrc directory uses ipcore-packaged filenames, not the plain
names that Verilator's `-y` module search and `build_replay_lock.sh`-style tooling
require):

| candidate | diff lines vs synthesized | verdict |
|---|---|---|
| `jupiter_240k5_byte/rtl_sim/s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback` | **32** | **SAME generation — the match** |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_beatfix2/hdlsrc/commhdlQPSKTxRxLoopback` | 36 | different (older) generation — NAMING TRAP, see below |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_beatobs/hdlsrc/commhdlQPSKTxRxLoopback` | 121 | different generation |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_rhfix/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_rhfix2/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_rhfix3/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_fix/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |
| `jupiter_240k5_byte/rtl_sim/s1_rtl_pcfix/hdlsrc/commhdlQPSKTxRxLoopback` | 421 | different generation |

A small diff (header only: filename/timestamp/model version, or in this case also the
IP-packaging module-instance renaming — read line-by-line and confirmed to carry zero
logic change) means SAME generation. A 100+ line diff means a DIFFERENT generation and
MUST NOT be simulated against.

## The winning candidate, verified two independent ways

`s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v` diffs at 32 lines against
the netlist extracted from the flashed build's ipcore zip. Every line is either the
`File Name:` header comment, the module declaration/end comment (`TxRxComposite` vs
`TxRxCompo_ip_src_TxRxComposite`), or one of 15 submodule instantiation lines renamed with
the same `TxRxCompo_ip_src_` prefix — the standard Vivado IP-packaging renaming applied to
every submodule instance, zero functional difference.

1. **`Created:` header byte-identity.** The `Created: 2026-08-21 23:31:06` timestamp
   inside the file header is byte-identical between `s1_rtl_beatfix3` and the netlist
   extracted from the flashed image's ipcore zip. A spot-check of a full submodule file
   (`Receiver.v`, of 165 total `.v` files present in the directory) against its
   IP-packaged counterpart came back at 12 diff lines, all the same renaming pattern.
2. **`-y` path recorded in the v3 pre-flash gate.**
   `jupiter_240k5_byte/rtl_sim/obj_byte_bf3/Vwrap_byte_ce__verFiles.dat` records the
   Verilator command line of the v3 pre-flash netlist gate; its `-y` path is exactly
   `.../s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback`. That gate produced
   `FLASH_GATE_PASS` on the image that was then flashed — i.e. this is the netlist
   actually validated pre-flash, not merely a text match.

## NAMING TRAP — read before choosing a directory

`s1_rtl_beatfix2` looks like the obvious match for `jupiter_byte_beatfix2_build`, but it
is a **distinct, older generation**: `Created: 2026-08-21 22:02:07`, about 90 minutes
before the netlist that actually synthesized into the flashed image
(`Created: 2026-08-21 23:31:06`). There is no `s1_rtl_beatfix2_build` directory to check
against — the `s1_rtl_*` staging-copy names under `jupiter_240k5_byte/rtl_sim/` do NOT
correspond 1:1 with `jupiter_byte_*_build/` names. **The header `Created:` timestamp is
the only reliable key.** Matching by directory name alone would have silently pinned
every downstream task to the wrong generation. The correct directory is `s1_rtl_beatfix3`.

## Path trap (cost a wrong "no netlist found" census on 2026-08-22)

The `*_gates` directories store netlists at `s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`.
The beatfix lineage stores them at `hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`.
A census that globs only the former reports "NONE" for the v3 builds, which is wrong.

## Harness trap: `wrap_byte_lock.v` / `sim_byte_lock.cpp` are stale — do not use, do not repair

The originally-assumed driver pair for the cadence sanity check
(`wrap_byte_lock.v` + `sim_byte_lock.cpp`, via `build_replay_lock.sh`) fails to compile
against `s1_rtl_beatfix3` AND against `build_replay_lock.sh`'s own documented default
netlist (`$KIT/s1_rtl`), with identical Verilator elaboration errors on both:

```
%Error: wrap_byte_lock.v:81:100: Can't find definition of 'Loop_Filter_stateP' in dotted variable:
  'dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Symbol_Synchronizer.Loop_Filter_stateP'
```
(plus three more of the same shape, for `Loop_Filter_stateI` and the `Carrier_Synchronizer`
equivalents). `wrap_byte_lock.v`'s own header states it is "Jul-25 f1536 netlist ONLY...
the current regen is a known regression." In that retired cadence-4 generation,
`Loop_Filter_stateP/I` are promoted directly onto `Symbol_Synchronizer`/
`Carrier_Synchronizer`; in every current-generation netlist that state lives one level
deeper, inside the `Loop_Filter_block1` submodule instance, under different register
names. `sim_byte_lock.cpp` actively consumes those four taps per decoded frame, so they
are not vestigial and cannot be stubbed without changing what the harness measures.
`wrap_byte_lock.v` is also shared by the `sim_byte_{dip,qtick,tickfix}` driver family, so
it was not patched.

**Use `wrap_byte_bf2.v` + `sim_byte_ce.cpp` (top module `wrap_byte_ce`)** — the exact pair
the v3 pre-flash gate used against this netlist (Corroboration 2 above). It drives the DUT
from the in-fabric BIST ROM loopback source (no capture file needed) and exposes
`byte_rx_ready` as a wrapper input, which later backpressure-injection phases need.

## Cadence sanity gate — RESULT: PASS

Build:
```
cd /mnt/onetb/scratch/qpsk-jupiter-modem
jupiter_240k5_byte/rtl_sim/build_replay_v3.sh sim_byte_ce.cpp
```
→ `BUILD_REPLAY_V3_DONE driver=sim_byte_ce.cpp cadence=2 bin=.../obj_sim_byte_ce_v3/Vwrap_byte_ce`

Run (1,600,000 clocks, the documented clean-run length for this harness family per
`two_jup/MODEL1_ENABLE_INJECT.md`):
```
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
./obj_sim_byte_ce_v3/Vwrap_byte_ce 1600000 /tmp/ce_v3_gate
```

Result: 14 decoded frames, `cnt_frame_start=15` (nonzero). Golden = 1 iff
`cap_in==0x5216F3E2 && cap_out==0x04922282`, evaluated per settled frame:

| frame_idx | cap_in | cap_out | golden |
|---|---|---|---|
| 0 | 5216f3e2 | 00000000 | 0 (expected — pre-settlement transient, per the driver's own re-arm-at-`cnt_frame_start` comment) |
| 1-13 | 5216f3e2 | 04922282 | **1** (13 of 14 frames) |

Final/summary line: `cap_in_final=5216f3e2 cap_out_final=04922282 cnt_frame_start=15
bit_errors=51 packets=15`, `firstGoldClk=296599`. Both golden hashes match exactly on
every settled frame. Frame cadence is exactly 98,664 clocks between successive
`cnt_frame_start` events (197935, 296599, 395263, …) — dead regular. **Gate PASSES** —
this netlist/cadence/harness combination is confirmed correct.

Note: `bit_errors_out` reads a constant `51` on every one of the 14 frames, including
the golden==1 frames. A constant value alongside bit-exact golden hashes on every settled
frame indicates that counter is either latched from an early transient or free-running
in this wrapper, rather than tracking per-frame decode errors — it is not evidence of a
real decode error rate and should not be cited as one. Not chased further in this task.

## RETIRED RESULT — do not cite

`sim_byte_dip.cpp`'s "26 scheduled `byte_rx_ready` dips produce bit-identical output,
therefore brief DMA backpressure is exonerated" is **RETIRED**, for two independent
reasons:

1. **Provenance** — it ran against the Jul-25 netlist (cadence 4); the flashed image is
   a later generation at cadence 2.
2. **Fidelity** — its dip profile was an ASSUMED waveform. The real S2MM boundary
   involves `SYNC_TRANSFER_START` re-sync and `tuser`, and was never measured.

It may be cited again only after being re-run against `V3_NETLIST_DIR` at `V3_CADENCE`
with the measured waveform from the campaign's backpressure probe. Note also that
`sim_byte_dip.cpp`'s driver/wrapper family (shared with `wrap_byte_lock.v`) is itself
stale against the current netlist generation (see "Harness trap" above) — any re-run
needs a harness update, not just a netlist swap.
