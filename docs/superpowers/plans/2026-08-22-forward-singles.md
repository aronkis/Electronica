# Forward Singles-Comb Campaign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Root-cause and fix the forward singles-comb class (~12.4 % delivered PER, 146→148, ARQ off) by reproducing it off-air and in simulation, then verifying a fix.

**Architecture:** Four phases. Phase 0 makes results citable (netlist provenance matched to the flashed image; baseline re-anchor). Phase 1 asks whether the class exists in FPGA-internal loopback — the mode just measured healthy at 1246 f/s with zero carrier resets — which would take the whole campaign off-air. Phase 2 reproduces the class in a provenance-matched, backpressure-faithful Verilator sim, swept in parallel across the x86 fleet, with a mandatory planted-fault positive control. Phase 3 tests the cyclic-RX-DMA fix, which needs no build and no flash.

**Tech Stack:** Bash harnesses over `anyssh.sh`, Python 3 + NumPy analyzers (`frame_taxonomy.py`, `loss_ledger.py`), Verilator C++ testbenches (`jupiter_240k5_byte/rtl_sim/`), on-board C daemon `host_app_k5/qpsk_tun.c`, AXI register access via `busybox devmem` and `direct_reg_access`.

**Spec:** `docs/superpowers/specs/2026-08-22-forward-singles-design.md`

## Global Constraints

- **146 is NEVER flashed.** Forward-only instrumentation and fixes. 146 = TMR `433fd8dab393`, frozen.
- **No flash of 148 without separate explicit operator authorization.** Builds may be banked.
- **At most ONE Vivado build** this campaign, and only if Task 5 cannot resolve the backpressure waveform from existing counters.
- **Metrics rule:** never report a PER/BER target as met without (1) the exact command, (2) the sample count, (3) explicit confirmation that dropped/lost frames are in the denominator. State plainly when a target is NOT confirmed.
- **Verdict rules are stated in the script/doc BEFORE the run.** A green sim is a sufficiency proof only; it never closes a question.
- **The rig is a hard mutex.** Never run two rig harnesses concurrently. Restore after every session.
- **Watcher discipline:** never `pgrep`/`pkill` a pattern that appears in the watcher's own command line — bracket it (`[l]ock_watchdog`) or use explicit PIDs from `ps`.
- **Long builds** run under `setsid nohup … & disown` with an explicit post-check, never as a foreground poll.
- **Never hardcode vendor paths** (Vivado/MATLAB roots). Discover at runtime, fail loudly if absent.
- **Git:** commit with `git commit -s`. "Commit" implies commit AND push.
- Flashed image under test: **`fe5bd8a4fe19`** (BEATFIX v3) on 148. `fixctl` @ `0x208` defaults to 0 = byte-identical legacy behaviour.
- **Known blocker:** the reverse RF leg (148 TX → 146 RX) is broken (~6 dB short; 146 RX pinned ~510 f/s on air, 1246 f/s in loopback). Air-dependent steps are gated on operator bench repair. All other tasks proceed.

---

## File Structure

| file | responsibility |
|---|---|
| `two_jup/NETLIST_PROVENANCE.md` | (create) names the netlist bit-matched to `fe5bd8a4fe19`, its md5s and cadence; retires the stale `sim_byte_dip` exoneration |
| `jupiter_240k5_byte/rtl_sim/build_replay_v3.sh` | (create) thin wrapper pinning `build_replay_lock.sh` to the v3 netlist + cadence |
| `two_jup/singles_cadence.py` | (create) the scorer: classifies singles/doubles, tests cadence-lock to the DMA boundary period, self-tests on synthetic data |
| `two_jup/singles_loopback.sh` | (create) Phase-1 harness: `-M` sweep in FPGA-internal loopback, legacy and cyclic legs, `-G` positive control |
| `two_jup/backpressure_probe.sh` | (create) Phase-2.1: measures the real transfer-boundary/ready waveform from existing counters |
| `jupiter_240k5_byte/rtl_sim/sweep_backpressure.py` | (create) Phase-2.3 fleet fan-out runner + result aggregation |
| `two_jup/SINGLES_CAMPAIGN.md` | (create) the running evidence ledger for this campaign |
| `host_app_k5/qpsk_tun.c` | (modify, only if Task 4 finds a defect) existing `QPSK_RX_CYCLIC` path |

Existing files this plan **reuses without modification**: `two_jup/loopback_s_test.sh`, `two_jup/frame_taxonomy.py`, `two_jup/loss_ledger.py`, `two_jup/accept_analyze.py`, `two_jup/paired_report.py`, `two_jup/anyssh.sh`, `two_jup/restore_known_good.sh`, `jupiter_240k5_byte/rtl_sim/build_replay_lock.sh`, `jupiter_240k5_byte/rtl_sim/sim_byte_inject.cpp`.

---

## Task 1: Netlist provenance matched to the flashed image

The whole sim campaign is uncitable until the netlist under simulation is proven to be the one on the board. Prior sim verdicts used the Jul-25 netlist (drive **cadence 4**) while 148 runs a post-Jul-29 generation (**cadence 2**) — getting the cadence wrong yields 0 CRC-good frames and looks like a broken datapath.

**Files:**
- Create: `two_jup/NETLIST_PROVENANCE.md`
- Create: `jupiter_240k5_byte/rtl_sim/build_replay_v3.sh`
- Modify: `two_jup/FWD_SINGLES_ROOT_CAUSE.md` (add the retirement banner)

**Interfaces:**
- Produces: `V3_NETLIST_DIR` = `jupiter_240k5_byte/rtl_sim/s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback`; `V3_CADENCE` = `2`; and `build_replay_v3.sh [driver.cpp] [objdir]`, which later tasks call to compile any driver against that netlist with the `wrap_byte_bf2.v` wrapper (top module `wrap_byte_ce`).

**NAMING TRAP — read before choosing a directory.** `s1_rtl_beatfix2` looks like the
obvious match for `jupiter_byte_beatfix2_build`, but it is a distinct generation roughly
90 minutes older. Only the `Created:` header timestamp inside the netlist discriminates
them reliably. The correct directory is **`s1_rtl_beatfix3`**, independently corroborated
two ways: (1) it matches the netlist extracted from the flashed image's ipcore zip, and
(2) it is the `-y` path recorded in `obj_byte_bf3/Vwrap_byte_ce__verFiles.dat`, i.e. the
netlist the v3 pre-flash gate actually simulated before that image was flashed.

**Background the implementer needs:** `build_replay_lock.sh` already documents the provenance method — the DUT netlist actually synthesized into an image is recoverable from that build's `hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip`, member `hdl/TxRxCompo_ip_src_TxRxComposite.v`. Compare that against on-disk candidates by line-diff, not md5 alone: regenerated netlists differ in a filename/timestamp header even when functionally identical, so a small diff (≤ ~10 lines, all header) means *same generation*, and a large diff (100+ lines) means *different generation*.

- [ ] **Step 1: Confirm which build produced the flashed image**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
md5sum jupiter_byte_beatfix2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN | cut -c1-12
```

Expected: `fe5bd8a4fe19` — the image flashed on 148. If it differs, STOP and report: the flashed image's build directory is not the one assumed, and every downstream path in this task is wrong.

- [ ] **Step 2: Extract the synthesized DUT netlist from that build's ipcore**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
mkdir -p /tmp/v3prov && \
unzip -o -j jupiter_byte_beatfix2_build/hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip \
  'hdl/TxRxCompo_ip_src_TxRxComposite.v' -d /tmp/v3prov
md5sum /tmp/v3prov/TxRxCompo_ip_src_TxRxComposite.v
```

Expected: one file extracted. If the member name is not found, list the archive (`unzip -l …`) and use the actual path of the file whose basename ends `TxRxComposite.v`.

- [ ] **Step 3: Diff the synthesized netlist against every on-disk candidate**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
for d in jupiter_byte_beatfix2_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback \
         jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback \
         jupiter_byte_fsv2_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback \
         jupiter_byte_tmr146_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback \
         jupiter_byte_wit3_gates/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback; do
  f="$d/TxRxComposite.v"
  if [ -f "$f" ]; then
    n=$(diff "$f" /tmp/v3prov/TxRxCompo_ip_src_TxRxComposite.v | grep -c '^[<>]' || true)
    echo "$n  $d"
  else
    echo "--  $d (no TxRxComposite.v)"
  fi
done
```

Expected: exactly one candidate with a small diff (≤ ~10 lines). Record every number — they go in the provenance doc.

- [ ] **Step 4: Write the provenance document**

Create `two_jup/NETLIST_PROVENANCE.md`:

```markdown
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

| candidate | diff lines vs synthesized | verdict |
|---|---|---|
| (fill in from Step 3, every candidate, exact numbers) | | |

A small diff (header only: filename/timestamp/model version) means SAME generation.
A 100+ line diff means a DIFFERENT generation and MUST NOT be simulated against.

## Path trap (cost a wrong "no netlist found" census on 2026-08-22)

The `*_gates` directories store netlists at `s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`.
The beatfix lineage stores them at `hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`.
A census that globs only the former reports "NONE" for the v3 builds, which is wrong.

## RETIRED RESULT — do not cite

`sim_byte_dip.cpp`'s "26 scheduled `byte_rx_ready` dips produce bit-identical output,
therefore brief DMA backpressure is exonerated" is **RETIRED**, for two independent
reasons:

1. **Provenance** — it ran against the Jul-25 netlist (cadence 4); the flashed image is
   a later generation at cadence 2.
2. **Fidelity** — its dip profile was an ASSUMED waveform. The real S2MM boundary
   involves `SYNC_TRANSFER_START` re-sync and `tuser`, and was never measured.

It may be cited again only after being re-run against `V3_NETLIST_DIR` at `V3_CADENCE`
with the measured waveform from the campaign's backpressure probe.
```

- [ ] **Step 5: Create the pinned build wrapper**

**Use the harness that is PROVEN against this netlist generation.** `sim_byte_lock.cpp` /
`wrap_byte_lock.v` are stale: the wrapper reaches into `Loop_Filter_stateP/I` on
`Symbol_Synchronizer`/`Carrier_Synchronizer`, hierarchical paths that exist only in the
retired Jul-25 netlist, so it fails to compile against every current-generation netlist.
Do not try to repair it.

The working pair is **`wrap_byte_bf2.v` + `sim_byte_ce.cpp`** — the exact combination the
v3 pre-flash netlist gate used against this netlist, producing `FLASH_GATE_PASS` on the
image that was then flashed. It also exposes `byte_rx_ready` as a **wrapper input**,
which is precisely the port Phase 2 needs for backpressure injection.

Create `jupiter_240k5_byte/rtl_sim/build_replay_v3.sh`:

```bash
#!/bin/bash
# build_replay_v3.sh -- build the byte-plane harness against the netlist BIT-MATCHED TO
# THE FLASHED IMAGE fe5bd8a4fe19 (see two_jup/NETLIST_PROVENANCE.md).
#
# Every build_*.sh in this directory defaults to $KIT/s1_rtl, a DIFFERENT generation from
# the flashed image. And wrap_byte_lock.v is stale -- it references Loop_Filter_stateP/I
# hierarchical paths that exist only in the retired Jul-25 netlist, so it will not
# compile here. Use wrap_byte_bf2.v + sim_byte_ce.cpp: the pair the v3 pre-flash gate
# used against this exact netlist.
#
# Drive cadence for this netlist is 2 (NOT the Jul-25 archive's 4).
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
V3=$R/s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback
DRV=${1:-sim_byte_ce.cpp}
OBJ=${2:-obj_$(basename "$DRV" .cpp)_v3}
export PATH=/usr/local/bin:/usr/bin:/bin

[ -f "$V3/TxRxComposite.v" ] || {
  echo "FATAL: v3 netlist missing at $V3 -- re-read two_jup/NETLIST_PROVENANCE.md" >&2
  exit 1; }

cd "$R"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --public-flat-rw -CFLAGS "-O2 -DHAVE_FLAT_RW -DHAVE_BF2" \
  --cc wrap_byte_bf2.v -y "$V3" --exe "$DRV" -Mdir "$OBJ" --top-module wrap_byte_ce
make -s -C "$OBJ" -f Vwrap_byte_ce.mk Vwrap_byte_ce
echo "BUILD_REPLAY_V3_DONE driver=$DRV cadence=2 bin=$R/$OBJ/Vwrap_byte_ce"
echo "  netlist : $V3"
```

- [ ] **Step 6: Build it**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
chmod +x jupiter_240k5_byte/rtl_sim/build_replay_v3.sh
jupiter_240k5_byte/rtl_sim/build_replay_v3.sh sim_byte_ce.cpp 2>&1 | tail -5
```

Expected: `BUILD_REPLAY_V3_DONE driver=sim_byte_ce.cpp cadence=2 bin=…/obj_sim_byte_ce_v3/Vwrap_byte_ce`.

If Verilator reports unresolved hierarchical references, you are building the wrong
wrapper — re-read Step 5. Do not "fix" the netlist.

- [ ] **Step 7: Golden-hash sanity check (the real cadence gate)**

`wrap_byte_bf2.v` drives the DUT from the in-fabric BIST ROM loopback source, so this
needs no capture file, and it exposes two hashes with **known golden values**:

    cap_in  (FEC-wrapper input hash)  golden 0x5216F3E2
    cap_out (decoder output hash)     golden 0x04922282

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
./obj_sim_byte_ce_v3/Vwrap_byte_ce 2>&1 | tail -20
```

Expected: `cap_in = 0x5216F3E2` and `cap_out = 0x04922282`, with a nonzero
`cnt_frame_start`.

**This is a far stronger gate than a frame count** — it is a bit-exact comparison against
values the same harness produced during the v3 pre-flash gate. If either hash differs, or
`cnt_frame_start` is zero, **STOP**: the netlist selection or cadence is wrong. Do not
write the provenance document and do not commit. Report the observed values.

- [ ] **Step 8: Add the retirement banner to the root-cause doc**

Insert at the top of `two_jup/FWD_SINGLES_ROOT_CAUSE.md`, immediately after the H1 line:

```markdown
> **PARTIALLY SUPERSEDED (2026-08-22).** The mechanism section below ("inter-transfer
> DMAC backpressure reaching the ByteSerializer") is the campaign's leading hypothesis
> but is NOT established. The `sim_byte_dip` result once cited against it is RETIRED —
> see `two_jup/NETLIST_PROVENANCE.md`. The fix path below (cyclic RX) is being tested
> under `docs/superpowers/plans/2026-08-22-forward-singles.md`.
```

- [ ] **Step 9: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/NETLIST_PROVENANCE.md jupiter_240k5_byte/rtl_sim/build_replay_v3.sh two_jup/FWD_SINGLES_ROOT_CAUSE.md
git commit -s -m "provenance: pin byte-plane sims to the netlist bit-matched to flashed fe5bd8a4fe19

Recovered the synthesized DUT netlist from the beatfix2 build's ipcore zip and
line-diffed it against every on-disk candidate. build_replay_v3.sh pins that path at
cadence 2. Retires the sim_byte_dip backpressure exoneration (wrong generation +
assumed dip profile)."
git push origin per-under-1pct-2026-07
```

---

## Task 2: Singles-cadence scorer with synthetic self-tests

Phase 1 and Phase 3 both need one scorer that answers: *are the losses singles/doubles, and is their spacing locked to the DMA transfer-boundary period?* Building it first, against synthetic data with a known answer, means the hardware runs are scoreable the moment they finish — and means a zero is trustworthy.

This repo already establishes the idiom: `frame_taxonomy.py:synth()` fabricates a `frames.bin` with a known signature and asserts the tool recovers it, with no hardware. Follow it.

**Files:**
- Create: `two_jup/singles_cadence.py`

**Interfaces:**
- Consumes: `two_jup/frame_taxonomy.py` — `read_frames(path)` returns a structured array with fields `t_mono_ns` (`<u8`), `host_seq` (`<u4`), `crc_ok` (`<u4`), `reg_packets` (`<u4`), `reg_biterr` (`<u4`), `reg_rstcs` (`<u4`).
- Produces: `classify(frames, m) -> dict` with keys `n_frames`, `n_bad`, `per`, `singles`, `doubles`, `longer`, `boundary_locked` (bool), `boundary_hit_frac` (float), `spacing_hist` (dict int→int); and CLI `singles_cadence.py <frames.bin> --M <int>`.

**Definitions the implementer must use exactly:**
- A **bad** frame is one with `crc_ok == 0`, OR a `host_seq` value absent from the record stream (a hole). Both count — dropped frames must be in the denominator.
- A **run** is a maximal consecutive group of bad `host_seq` values. `singles` = runs of length 1, `doubles` = length 2, `longer` = length ≥ 3.
- **Boundary-locked** — read this carefully; the obvious formulation does not work.

  The DMA transfer boundary is counted by the **hardware packet counter `reg_packets`**,
  NOT by `host_seq`. Measured on the banked ground-truth capture:

  | residue basis | corrupt-frame boundary fraction | all-frame base | enrichment |
  |---|---|---|---|
  | `host_seq % 16` | 0.1217 | 0.1250 (chance) | **1.00× — no signal** |
  | `reg_packets % 16` | 0.2460 | 0.1461 | **1.68×** |
  | `reg_packets % 32` | 0.1101 | 0.0742 | **1.48×** |

  Scoring on `host_seq` reports "not boundary-locked" on data that demonstrably *is*,
  because `host_seq` is the host's own frame counter and is not aligned to transfers.

  Two further corrections that follow from the same measurement:
  - Compare against the **observed all-frame residue rate**, not the theoretical `2/M`.
    Frames are not uniformly distributed over residues (0.1461 observed vs 0.1250
    theoretical at `M=16`), so a `2/M` baseline overstates enrichment.
  - Score **delivered CRC-failed records**, not run starts. A hole has no record and
    therefore no `reg_packets` value; forward-filling one from the previous record
    injects an artifact — doing so drops the measured enrichment from 1.68× to 0.92×,
    i.e. it manufactures a null. Holes still count in `n_bad` and the denominator; they
    are simply not usable for the residue test, and the code must say so.

  So: `boundary_locked` is true when at least 200 delivered CRC-failed records are
  available and their boundary-residue fraction is **≥ 1.4×** the all-frame
  boundary-residue fraction, both computed on `reg_packets % M` ∈ {0, M-1}. Both
  residues count because a boundary landing inside a frame can damage the frame before
  or after it. Report the enrichment ratio itself, not only the boolean.

  **Reconciliation of the enrichment magnitude (2026-08-22).** Three defensible variants
  of the baseline give materially different ratios on the same capture:

  | baseline variant | M=16 | M=32 |
  |---|---|---|
  | (a) all in-range records | 1.68× | 1.49× |
  | (b) CRC-good records only | 1.72× | 1.51× |
  | (c) per-unique `reg_packets` | 2.01× | 1.77× |

  **Every variant clears the 1.4× threshold at both M, so the BOOLEAN is robust and safe
  to gate on. The MAGNITUDE is not a physical constant and must never be quoted as one**
  — say "enrichment 1.7–2.0× depending on baseline definition", and always state which
  variant produced a number. Variant (a) is the one the code implements.

  **OPEN QUESTION — do not build an argument on the magnitude until this is settled.**
  `reg_packets` is flat across up to **16 consecutive records** (40.6 % of consecutive
  record pairs share a value), and 16 is exactly `M`. That is consistent with the counter
  advancing once per DMA *transfer* rather than once per frame — in which case
  `reg_packets % M` indexes *which transfer* mod M, not a position *within* a transfer,
  and the enrichment would mean "every Mth transfer is damaged", a super-period rather
  than a boundary effect. `FWD_SINGLES_ROOT_CAUSE.md` reads the counter the other way
  ("every 0x10/0x20 packets"). The two readings are not reconciled. Resolve it by direct
  observation — read `0x104` against a known frame count on hardware — before any claim
  rests on what the residue *means*. The lock's existence does not depend on this; its
  interpretation does.

- [ ] **Step 1: Write the failing tests**

Create `two_jup/singles_cadence.py` containing ONLY this test block for now (the module is self-testing, matching `frame_taxonomy.py`'s pattern — run with `python3 singles_cadence.py --selftest`):

```python
#!/usr/bin/env python3
"""singles_cadence.py -- score a frames.bin for the forward singles-comb class.

Answers two questions the campaign turns on:
  1. Are the losses singles/doubles (the comb) or longer bursts (a different class)?
  2. Is the spacing of bad runs LOCKED to the -M DMA transfer boundary?

Self-test: `python3 singles_cadence.py --selftest` synthesizes frames.bin content with
a KNOWN signature and asserts recovery. No hardware needed. A scorer that has never
caught a planted fault is not trusted with a negative result.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import DTYPE, read_frames


def _synth(n, m, kind, seed=7):
    """Fabricate a frames.bin-shaped array with a known loss signature."""
    rng = np.random.default_rng(seed)
    fr = np.zeros(n, dtype=DTYPE)
    fr["t_mono_ns"] = (np.arange(n) * 803_000).astype(np.uint64)  # 803 us/frame
    fr["host_seq"] = np.arange(n, dtype=np.uint32)
    fr["reg_packets"] = np.arange(n, dtype=np.uint32)
    ok = np.ones(n, dtype=bool)
    if kind == "boundary_singles":
        # one bad frame at every transfer boundary -- the class we are hunting
        ok[np.arange(0, n, m)] = False
    elif kind == "random_singles":
        # same PER, boundary-blind
        ok[rng.choice(n, size=n // m, replace=False)] = False
    elif kind == "bursts":
        for onset in range(m, n - 10, 7 * m):
            ok[onset:onset + 5] = False
    elif kind == "clean":
        pass
    else:
        raise ValueError(kind)
    fr["crc_ok"] = ok.astype(np.uint32)
    return fr


def _selftest():
    n, m = 20000, 16
    r = classify(_synth(n, m, "boundary_singles"), m)
    assert r["singles"] > 0 and r["longer"] == 0, r
    assert r["boundary_locked"] is True, r

    r = classify(_synth(n, m, "random_singles"), m)
    assert r["boundary_locked"] is False, r

    r = classify(_synth(n, m, "bursts"), m)
    assert r["longer"] > 0 and r["singles"] == 0, r

    r = classify(_synth(n, m, "clean"), m)
    assert r["n_bad"] == 0 and r["per"] == 0.0 and r["boundary_locked"] is False, r

    # holes must count as bad: delete 1 record and confirm the denominator is intact
    fr = _synth(n, m, "clean")
    r = classify(np.delete(fr, 500), m)
    assert r["n_bad"] == 1 and r["n_frames"] == n, r
    print("SINGLES_CADENCE_SELFTEST_OK")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="?")
    ap.add_argument("--M", type=int, default=16)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        _selftest()
    else:
        r = classify(read_frames(a.frames), a.M)
        for k in ("n_frames", "n_bad", "per", "singles", "doubles", "longer",
                  "boundary_hit_frac", "boundary_locked"):
            print(f"{k:>18} : {r[k]}")
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup && python3 singles_cadence.py --selftest
```

Expected: `NameError: name 'classify' is not defined`.

- [ ] **Step 3: Implement `classify`**

Insert into `two_jup/singles_cadence.py`, above `_selftest`:

```python
def classify(frames, m):
    """Score a frames array for the singles-comb signature at -M = m."""
    seq = frames["host_seq"].astype(np.int64)
    crc = frames["crc_ok"].astype(np.int64)
    lo, hi = int(seq.min()), int(seq.max())
    n_frames = hi - lo + 1

    # bad = delivered-but-CRC-failed, PLUS every seq that never arrived (a hole).
    # Holes are losses and belong in the denominator; excluding them is the exact
    # mistake the -B accounting made.
    bad = np.zeros(n_frames, dtype=bool)
    present = np.zeros(n_frames, dtype=bool)
    idx = seq - lo
    present[idx] = True
    bad[idx[crc == 0]] = True
    bad |= ~present

    n_bad = int(bad.sum())
    per = n_bad / n_frames if n_frames else 0.0

    # maximal consecutive runs of bad frames
    padded = np.concatenate(([False], bad, [False]))
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    starts, ends = edges[0::2], edges[1::2]
    lens = ends - starts
    singles = int((lens == 1).sum())
    doubles = int((lens == 2).sum())
    longer = int((lens >= 3).sum())

    # boundary lock: does a run start on a transfer edge more often than chance?
    if len(starts):
        res = (starts + lo) % m
        hits = int(((res == 0) | (res == m - 1)).sum())
        frac = hits / len(starts)
    else:
        frac = 0.0
    locked = bool(len(starts) >= 20 and frac > 3.0 * (2.0 / m))

    hist = {}
    if len(starts) > 1:
        for d in np.diff(starts):
            hist[int(d)] = hist.get(int(d), 0) + 1

    return {"n_frames": n_frames, "n_bad": n_bad, "per": per,
            "singles": singles, "doubles": doubles, "longer": longer,
            "boundary_hit_frac": frac, "boundary_locked": locked,
            "spacing_hist": hist}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup && python3 singles_cadence.py --selftest
```

Expected: `SINGLES_CADENCE_SELFTEST_OK`.

- [ ] **Step 5: Score a real banked capture as a smoke test**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
python3 singles_cadence.py r3cap/singles_reread/frames.bin --M 16
```

Expected: a nonzero `n_bad` with `singles` dominating and `longer` small — this capture is the one from which 12 corrupt singles were replayed. Record the output in the commit message. If `singles` is zero here, the scorer disagrees with the banked hardware ground truth and must be fixed before use.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/singles_cadence.py
git commit -s -m "singles_cadence.py: comb scorer with synthetic self-tests

Classifies bad-frame runs (singles/doubles/longer) and tests boundary-lock against -M.
Holes count as bad so dropped frames stay in the denominator. Self-test plants four
known signatures (boundary singles, random singles, bursts, clean) and asserts recovery."
git push origin per-under-1pct-2026-07
```

---

## Task 3: Phase 1 — does the comb exist off-air?

The highest information-per-minute experiment in the campaign, and it runs **today** despite the broken RF leg: FPGA-internal loopback was just measured at 1246 f/s with `rstcs=0` on both boards.

**Files:**
- Modify: `two_jup/loopback_s_test.sh` (small additive `FRAMELOG` opt-in — see Step 1)
- Create: `two_jup/singles_loopback.sh`
- Create: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: `two_jup/loopback_s_test.sh` (env knobs `BOARD`, `M`, `DUR`; arms `0x158=1`, `0x118=0`, `0x114=0`; stops the watchdog; runs a mandatory `-G` positive control as ARM A and the `-S` measurement as ARM B), `two_jup/singles_cadence.py` (`classify`, CLI).
- Produces: run directories `two_jup/r3cap/singlesloop_<ts>_M<m>/` each containing `A_G_loopback.log`, `B_S_loopback.log`, and `frames.bin`.

**MODE CORRECTION (2026-08-22, measured — supersedes the `-S` + `FRAMELOG` pairing below).**
The first run of this task was INVALID: `QPSK_FRAMELOG` fills `crc_ok`/`host_seq` only in
tun/echo/`-B` modes (`qpsk_tun.c:272`; every `framelog_record(1, seq)` success site is in
those paths). Under `-S` all 5003 records logged `crc_ok=0` with `host_seq` unset. A
direct probe of `-B` + `QPSK_FRAMELOG` in loopback on 148 settled what to use instead:

| field | `-S` arm | `-B` arm (measured, 35,022 records) |
|---|---|---|
| `crc_ok` | all 0 — unusable | **34,363 good / 659 bad — VALID** |
| `host_seq` | unset | only 4 unique garbage values — **still unusable** (`-B` is BER mode; it carries no per-frame sequence) |
| `reg_packets` | populated | **1 … 35,022 over 35,022 records — exactly 1 per frame, monotonic** |

So the loopback arm runs **`-B`**, exactly as `capture_paired.sh:89` already does
(`QPSK_FRAMELOG=/dev/shm/frames.bin ./qpsk_tun -B -d $DUR`), and **`reg_packets` is the
sequence**, not `host_seq`. Runs of consecutive bad frames are runs of consecutive
`reg_packets`; a hole is a missing `reg_packets` value; the boundary phase is
`reg_packets % M`. This is more direct than the air path, not a workaround.

**Bonus finding — it partly answers the open `reg_packets` question.** In this loopback
capture the counter advances exactly 1 per frame. The flatness seen in the air capture
(up to 16 records sharing a value) is therefore a property of *host drain batching* on
the record-writing side, not of the counter itself. That supports the "counts frames"
reading over "counts transfers", but it is **one capture in one mode** — do not close the
question on it; the direct `0x104`-vs-known-frame-count observation still stands.

**Also measured, worth noting but NOT yet a result:** that probe showed 659 / 35,022
(1.88 %) frames scored not-clean **with `BER = 0.000e+00`** — zero bit errors. Frame-level
loss with a bit-exact datapath, in pure FPGA-internal loopback, no radio. That may be a
startup/alignment transient rather than the singles class; the sweep exists to find out.
Do not report it as a reproduction until the real run scores it.

**Two facts about `loopback_s_test.sh` the implementer must not get wrong** (both verified by reading it, 2026-08-22):

1. It writes **`A_G_loopback.log`** and **`B_S_loopback.log`**, and scores from the `-S` daemon's `ok=`/`junk=` lines. **It does NOT produce a `frames.bin`.** `singles_cadence.py` needs per-frame `host_seq`/`crc_ok` records, so the `-S` arm must be given `QPSK_FRAMELOG=/dev/shm/frames.bin` — a passthrough env on the daemon command line (`qpsk_tun.c:2909`; `capture_r3.sh` uses it the same way). When unset, every logger hook is a no-op, so the opt-in is backwards compatible.
2. The positive-control verdict is printed as `ARM A  -G loopback : idle_rx = <N>` (control passes when `N > 0`), and failure prints a line beginning `>>> VOID.`. It uses **`idle_rx`, not `dma_rx_ok`** — `-G` with no peer transmits only idle frames, so `dma_rx_ok` is structurally zero and an earlier version of this control declared a working config VOID by reading it. Detect the control by parsing `idle_rx`, never by grepping for the phrase "positive control", which appears only in the script's comments and is never printed.

**Verdict rule — write this into the script header BEFORE running it:**

| outcome | meaning | campaign consequence |
|---|---|---|
| **REPRODUCES** — singles/doubles dominate, `boundary_locked` true at every `M`, and PER within 3× of the air value | class exists with no RF involved | channel exonerated; campaign moves off-air; fix verification becomes minutes-per-iteration |
| **DOES NOT REPRODUCE** — PER ≤ 0.5 % and `boundary_locked` false at every `M` | class needs the air or SSI path | re-run over SSI near-end loopback to split "needs RF" from "needs the SSI clock chain"; re-scope Phase 2 |
| **PARTIAL** — present at a materially different rate | duty-cycle- or rate-dependent | record the ratio; it constrains the mechanism |
| **VOID** — the `-G` positive control does not frame | the loopback config is wrong | discriminates nothing; must not be reported as a result |

- [ ] **Step 1a: Add the backwards-compatible `FRAMELOG` opt-in to `loopback_s_test.sh`**

This is a proven harness that produced the Layer-B results — make the smallest additive
change that works, and do not restructure it.

Add near the other env defaults (beside `M=${M:-32}`):

```bash
# FRAMELOG=1 adds the per-frame telemetry logger to ARM B so singles_cadence.py can
# score host_seq/crc_ok. Default 0 -> the daemon command line is unchanged and every
# logger hook in qpsk_tun.c is a no-op (byte-identical behaviour to prior runs).
FRAMELOG=${FRAMELOG:-0}
FLENV=""; [ "$FRAMELOG" = 1 ] && FLENV="QPSK_FRAMELOG=/dev/shm/frames.bin"
```

Change the ARM B launch string to carry it (ARM A, the `-G` control, is left alone):

```bash
run_arm "B_S_loopback" \
  "$FLENV QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -S -M $M -r 15360 -d $((DUR+20))" \
  "^seq: t="
```

And pull the file back immediately after that `run_arm` call:

```bash
if [ "$FRAMELOG" = 1 ]; then
  $W $B 'cat /dev/shm/frames.bin' 2>/dev/null > "$OUT/frames.bin"
  echo "  frames.bin: $(stat -c %s "$OUT/frames.bin" 2>/dev/null || echo 0) bytes"
fi
```

Verify the default path is untouched:

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup && bash -n loopback_s_test.sh && echo SYNTAX_OK
git diff --stat two_jup/loopback_s_test.sh
```

Expected: `SYNTAX_OK`, and a diff touching only the lines described above.

- [ ] **Step 1b: Write the sweep harness**

Create `two_jup/singles_loopback.sh`:

```bash
#!/bin/bash
# =============================================================================
# singles_loopback.sh -- Phase 1: does the forward singles-comb exist OFF AIR?
#
# Runs the RX chain in FPGA-internal loopback (0x114=0) through the REAL host DMA
# path, sweeping -M. The cadence-lock to the DMA transfer boundary -- not the
# absolute rate -- is the class fingerprint, which is why -M is swept.
#
# This mode was measured at 1246 f/s with rstcs=0 on both boards (two_jup/lb_discrim.sh,
# 2026-08-22), so it runs even while the reverse RF leg is broken.
#
# VERDICT RULE (stated before the run -- do not revise it afterwards):
#   REPRODUCES   singles+doubles dominate AND boundary_locked at every M AND PER
#                within 3x of the air value  -> channel exonerated, campaign off-air
#   NOT REPRO    PER <= 0.5% AND boundary_locked false at every M
#                -> re-run over SSI near-end loopback to split RF vs SSI clock chain
#   PARTIAL      present at a materially different rate -> record the ratio
#   VOID         the -G positive control does not frame -> config wrong, no verdict
#
# ONE RIG HARNESS AT A TIME. Restore afterwards: two_jup/restore_known_good.sh
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
BOARD=${BOARD:-10.0.0.148}
DUR=${DUR:-120}
MS=${MS:-"16 32 64"}
STAMP=$(date +%Y%m%d_%H%M%S)
LEDGER=$D/r3cap/singlesloop_${STAMP}_summary.txt

echo "=== singles_loopback on $BOARD, M in [$MS], ${DUR}s each -> $LEDGER ==="
: > "$LEDGER"

for M in $MS; do
  OUT=$D/r3cap/singlesloop_${STAMP}_M${M}
  echo "--- M=$M ---" | tee -a "$LEDGER"
  BOARD=$BOARD M=$M DUR=$DUR FRAMELOG=1 "$D/loopback_s_test.sh" > "$OUT.log" 2>&1
  rc=$?
  # loopback_s_test.sh writes into its own timestamped dir; adopt the newest one
  SRC=$(ls -1dt "$D"/r3cap/loopback_* 2>/dev/null | head -1)
  mkdir -p "$OUT"; [ -n "$SRC" ] && cp -a "$SRC"/. "$OUT"/ 2>/dev/null

  # POSITIVE CONTROL. The verdict block prints "ARM A  -G loopback : idle_rx = <N>";
  # the control PASSES when N > 0. Use idle_rx, never dma_rx_ok (-G with no peer sends
  # only idle frames, so dma_rx_ok is structurally zero and once voided a good config).
  IDLE=$(sed -n 's/.*ARM A .*idle_rx = \([0-9][0-9]*\).*/\1/p' "$OUT.log" | tail -1)
  if grep -q '^\s*>>> VOID\.' "$OUT.log" 2>/dev/null || [ -z "$IDLE" ] || [ "$IDLE" -le 0 ]; then
    echo "  M=$M VOID -- -G control did not frame (idle_rx=${IDLE:-unparsed}, exit=$rc)" | tee -a "$LEDGER"
    continue
  fi
  if [ ! -s "$OUT/frames.bin" ]; then
    echo "  M=$M NO DATA -- frames.bin missing/empty (exit=$rc); see $OUT.log" | tee -a "$LEDGER"
    continue
  fi
  echo "  control OK (idle_rx=$IDLE)" | tee -a "$LEDGER"
  python3 "$D/singles_cadence.py" "$OUT/frames.bin" --M "$M" | tee -a "$LEDGER"
done

echo "SINGLES_LOOPBACK_DONE stamp=$STAMP" | tee -a "$LEDGER"
echo "Apply the verdict rule in this script's header to the table above."
```

- [ ] **Step 2: Confirm the rig is free and healthy before touching it**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
ps -eo pid,cmd | grep -E '[c]apture_r3|[l]oopback_|[r]estore_known_good|[r]xseam' || echo "NO RIG HARNESS RUNNING"
./anyssh.sh 10.0.0.148 'busybox devmem 0x9D000104' 2>&1 | tail -1
```

Expected: no rig harness running. If one is, WAIT — the rig is a hard mutex.

- [ ] **Step 3: Run the sweep detached with a marker-based watcher**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
chmod +x singles_loopback.sh
setsid nohup env BOARD=10.0.0.148 DUR=120 MS="16 32 64" ./singles_loopback.sh \
  > /tmp/singlesloop.log 2>&1 < /dev/null & disown
```

Wait for the strict terminal marker `SINGLES_LOOPBACK_DONE` in `/tmp/singlesloop.log`. Do NOT poll in the foreground and do NOT match on intermediate lines.

- [ ] **Step 4: Restore the rig**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
setsid nohup ./restore_known_good.sh > /tmp/restore_after_loop.log 2>&1 < /dev/null & disown
```

The arm gate is expected to FAIL while the reverse RF leg is broken (148 ~1243 f/s, 146 ~510 f/s). That is the known blocker, not a new fault — record it and move on.

- [ ] **Step 5: Record the verdict**

Create `two_jup/SINGLES_CAMPAIGN.md` with the pre-stated rule, the per-`M` table from the summary file, and the verdict — naming which branch fired and, if NOT REPRODUCES, what the SSI follow-up is. Include the exact command, the per-`M` frame counts, and explicit confirmation that holes were counted in the denominator.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/singles_loopback.sh two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "Phase 1: off-air singles reproduction in FPGA-internal loopback

Sweeps -M in loopback with the -G positive control mandatory. Verdict rule stated in
the script header before the run. See two_jup/SINGLES_CAMPAIGN.md for the outcome."
git push origin per-under-1pct-2026-07
```

---

## Task 4: Cyclic RX DMA leg — the zero-build fix candidate

Cyclic mode has **no transfer boundaries at all**, so it is simultaneously the cheapest fix candidate and a sharp mechanism test. Two facts make it nearly free, both verified 2026-08-22:

- `host_app_k5/qpsk_tun.c` **already implements** the whole path — `rx_arm_cyclic()`, `rx_pump_cyclic()`, content-based freshness via the `0x1C0` write pointer, and the lap guard — behind `QPSK_RX_CYCLIC=1`.
- The flashed image's build log contains `CYCLIC_RXBYTE_OK rx_byte_dma CONFIG.CYCLIC=true`, so the deployed bitstream supports it.

**Danger the implementer must respect:** on a `CYCLIC=0` bitstream, `FLAGS` bit0 is masked to 0 and the cyclic arm **silently no-ops** — the daemon runs, delivers data, and looks fine while testing nothing. Step 1 exists to make that failure loud. Separately, cyclic converts overflow from a lossless stall into a **silent overwrite**, so the lap-guard counters are not optional telemetry.

**Files:**
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append the cyclic section)
- Modify: `host_app_k5/qpsk_tun.c` — **only if Step 1 or Step 4 exposes a defect.** Do not refactor the existing cyclic path.

**Interfaces:**
- Consumes: `singles_cadence.py::classify`, `two_jup/loopback_s_test.sh`, env `QPSK_RX_CYCLIC=1`.

**Verdict rule — write it into `SINGLES_CAMPAIGN.md` BEFORE running (from `STAGED_CYCLIC_RX.md`):**

| outcome | meaning |
|---|---|
| **loss → ~0 under cyclic** | the per-transfer boundary IS the mechanism, confirmed directly; cyclic is a real fix, not a mask |
| **loss persists at a period near the ring depth** | the boundary is not the mechanism; cyclic merely relocates it |
| **loss unchanged** | boundaries are irrelevant; the backpressure hypothesis is badly weakened and Phase 2 must widen to `ByteWordBuffer` internal state |

- [ ] **Step 1: Prove cyclic actually armed (guard against the silent no-op)**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
grep -m1 CYCLIC_RXBYTE_OK jupiter_byte_beatfix2_build/build_byte_vivado.log
```

Expected: `CYCLIC_RXBYTE_OK rx_byte_dma CONFIG.CYCLIC=true`.

Then confirm on the running board that the write pointer at `0x1C0` advances while cyclic is armed but no completion interrupt fires — the positive signature of cyclic mode:

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
./anyssh.sh 10.0.0.148 'a=$(busybox devmem 0x9D0001C0); sleep 2; b=$(busybox devmem 0x9D0001C0); echo "0x1C0 delta=$((b-a))"'
```

Expected: a delta of roughly `2 × 1245` frames' worth of words. **A delta of exactly 0 while the daemon is delivering data means cyclic did not arm — STOP, do not run the A/B, and report.**

- [ ] **Step 2: Read the lap-guard and overflow counters before the run**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
./anyssh.sh 10.0.0.148 'for a in 0x9D0001B0 0x9D0001C0; do printf "%s=" $a; busybox devmem $a; done'
```

`0x1B0` is the `byte_rxfifo_overlay` overflow counter and **must be 0**. Nobody has checked it recently. A nonzero value invalidates any downstream loss attribution and must be reported before proceeding.

- [ ] **Step 3: Run the paired legacy/cyclic A/B in loopback**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
for arm in 0 1; do
  OUT=r3cap/cyclic_ab_$(date +%Y%m%d_%H%M%S)_cyc${arm}
  QPSK_RX_CYCLIC=$arm BOARD=10.0.0.148 M=16 DUR=120 ./loopback_s_test.sh > "$OUT.log" 2>&1
  SRC=$(ls -1dt r3cap/loopback_* | head -1); mkdir -p "$OUT"; cp -a "$SRC"/. "$OUT"/
  echo "=== arm cyclic=$arm ==="
  python3 singles_cadence.py "$OUT/frames.bin" --M 16
done
```

Run both arms back to back in the same session so the config is otherwise identical. Both legs must pass the `-G` positive control or the pair is VOID.

- [ ] **Step 4: Re-read the lap-guard counters after the run**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
./anyssh.sh 10.0.0.148 'for a in 0x9D0001B0 0x9D0001C0; do printf "%s=" $a; busybox devmem $a; done'
```

If `0x1B0` moved off zero during the cyclic arm, the ring overflowed and **silently overwrote** data. Any apparent PER improvement in that leg is then an artifact of lost-but-uncounted frames, not a fix. Report it as such — this is exactly the failure mode the metrics rule exists to catch.

- [ ] **Step 5: Record the verdict**

Append a **Cyclic RX leg** section to `two_jup/SINGLES_CAMPAIGN.md`: the pre-stated rule, both arms' `singles_cadence` output, the `0x1B0`/`0x1C0` readings before and after, exact commands, frame counts, and which branch fired.

State explicitly, in one sentence: **does cyclic fix the fault, or mask a trigger that still fires?** Per the spec, cyclic is a *fix* only if the boundary is confirmed as the mechanism; if Phase 2 later falsifies backpressure, cyclic is a mask at best and must not ship on a PER delta alone.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "Phase 3A: cyclic RX DMA A/B in loopback (zero build, zero flash)

Deployed image fe5bd8a4fe19 has rx_byte_dma CONFIG.CYCLIC=true and qpsk_tun.c already
implements the ring. Lap-guard 0x1B0 read before and after: a cyclic ring that overflows
overwrites silently, so an unguarded PER win would be an artifact."
git push origin per-under-1pct-2026-07
```

---

## Task 5: Measure the real backpressure waveform

Every existing byte-plane harness holds `byte_rx_ready` high by construction, which is precisely why this class has never appeared in simulation. Phase 2 cannot be faithful until the real waveform is measured rather than assumed.

**Files:**
- Create: `two_jup/backpressure_probe.sh`
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append the measurement)

**Interfaces:**
- Produces: `two_jup/r3cap/bpprobe_<ts>/waveform.csv` with columns `t_s,words,boundary_gap_words,ready_duty` — the input Task 6 replays.

- [ ] **Step 1: Write the probe**

Create `two_jup/backpressure_probe.sh`:

```bash
#!/bin/bash
# =============================================================================
# backpressure_probe.sh -- measure the REAL transfer-boundary / byte_rx_ready
# behaviour at the RX byte seam, from counters already present in the flashed image.
#
# WHY: every sim harness holds byte_rx_ready high, so the singles class has never
# reproduced. sim_byte_dip's dip profile was ASSUMED. This measures it instead.
#
# Counters: 0x1C0 = CP1 word count (verified counting at line rate, 1243.7 f/s)
#           0x1B0 = byte_rxfifo overflow counter (MUST be 0)
# A 191-word frame at 1245 f/s = 237,795 words/s. Sampling at 100 Hz gives ~2378
# words per bucket; a transfer boundary that stalls the seam shows as a bucket deficit.
#
# If the boundary gap cannot be resolved from these counters -- i.e. the per-bucket
# word deltas are uniform to within counting noise across all -M -- then this probe
# has FAILED to resolve the waveform and that is the documented trigger for the ONE
# authorized probe build (debugI/Q1 overlay + XVC ILA). Say so plainly; do not
# report an unresolved waveform as "no backpressure observed".
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
BOARD=${BOARD:-10.0.0.148}
M=${M:-16}
DUR=${DUR:-60}
OUT=$D/r3cap/bpprobe_$(date +%Y%m%d_%H%M%S)_M${M}; mkdir -p "$OUT"

echo "=== backpressure_probe on $BOARD, M=$M, ${DUR}s -> $OUT ==="
"$D/anyssh.sh" "$BOARD" "
  n=\$(( $DUR * 100 ))
  : > /dev/shm/bp.csv
  i=0
  while [ \$i -lt \$n ]; do
    printf '%s,%s,%s\n' \"\$(date +%s.%N)\" \"\$(busybox devmem 0x9D0001C0)\" \"\$(busybox devmem 0x9D0001B0)\" >> /dev/shm/bp.csv
    i=\$((i+1))
  done" > "$OUT/probe.log" 2>&1

"$D/anyssh.sh" "$BOARD" 'cat /dev/shm/bp.csv' > "$OUT/raw.csv" 2>/dev/null
wc -l < "$OUT/raw.csv"
echo "BP_PROBE_DONE $OUT"
```

- [ ] **Step 2: Run it at both `-M` values**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
chmod +x backpressure_probe.sh
for m in 16 32; do BOARD=10.0.0.148 M=$m DUR=60 ./backpressure_probe.sh; done
```

Expected: two `bpprobe_*` directories, each `raw.csv` with roughly `DUR × 100` rows. A row count far below that means the on-board sampling loop could not keep up at 100 Hz — reduce the rate and record the actual rate achieved rather than pretending it was 100 Hz.

- [ ] **Step 3: Derive the waveform and decide whether it resolved**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
python3 - <<'PY'
import glob, numpy as np
for d in sorted(glob.glob("r3cap/bpprobe_*")):
    try:
        a = np.genfromtxt(f"{d}/raw.csv", delimiter=",")
    except Exception as e:
        print(d, "UNREADABLE", e); continue
    if a.ndim != 2 or len(a) < 10:
        print(d, "TOO FEW ROWS", a.shape); continue
    t, w, ovf = a[:, 0], a[:, 1], a[:, 2]
    dw = np.diff(w)
    dw = dw[dw >= 0]                      # drop counter wraps
    cv = dw.std() / dw.mean() if dw.mean() else float("nan")
    print(f"{d}: n={len(dw)} mean={dw.mean():.1f} std={dw.std():.1f} "
          f"cv={cv:.3f} min={dw.min():.0f} overflow_moved={bool(ovf.max() != ovf.min())}")
PY
```

**Decision rule, stated before looking:** if `cv` is below ~0.05 at every `-M` — word delivery uniform to within counting noise, no bucket deficits — the counters **cannot resolve** the boundary waveform. That is the documented trigger for the one authorized probe build. If `cv` is materially higher with a visible deficit population, the waveform IS resolved and Task 6 uses it directly.

- [ ] **Step 4: Record the measurement or the escalation**

Append a **Backpressure waveform** section to `two_jup/SINGLES_CAMPAIGN.md` with the per-`M` statistics, the achieved sample rate, the `0x1B0` verdict, and either:
- the derived boundary-gap distribution that Task 6 will replay, **or**
- an explicit statement that the counters did not resolve it, plus the probe-build scope: pack `{byte_rx_ready, byte_rx_user, ByteWordBuffer fill, ByteSerializer state}` into the `debugI/Q1` taps using the env-gated overlay pattern from `beatobs_overlay.m` (byte-identical model when the gate is unset), read out over the working XVC ILA path. **Build only — flashing requires separate explicit authorization. Stop and ask.**

- [ ] **Step 5: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/backpressure_probe.sh two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "Phase 2.1: measure the real byte_rx_ready / transfer-boundary waveform

Replaces sim_byte_dip's assumed dip profile with a measurement from 0x1C0/0x1B0.
Includes the pre-stated rule for when the counters fail to resolve it, which is the
documented trigger for the single authorized probe build."
git push origin per-under-1pct-2026-07
```

---

## Task 6: Teach the proven harness to stall `byte_rx_ready`

**This is the crux of the whole campaign.** `sim_byte_ce.cpp:105` sets
`t->byte_rx_ready = 1` once, at init, and never lowers it. That single line is *why* the
singles class has never reproduced in simulation: the harness holds the seam's
backpressure signal high by construction, so the condition under investigation cannot
occur. Task 6 removes that limitation.

`wrap_byte_bf2.v` already exposes `byte_rx_ready` as a **wrapper input** (line 24, wired
through at line 46), so no Verilog change is needed — this is a C++-side change to the
driver plus a new flag.

**Why this harness rather than `sim_byte_inject.cpp`:** the BIST-ROM-driven harness needs
no IQ capture file, is deterministic run-to-run, and — decisively — carries **golden
hashes** (`cap_in = 0x5216F3E2`, `cap_out = 0x04922282`). Corruption detection is
therefore a bit-exact hash comparison, not a CRC-failure count. `sim_byte_inject.cpp`
uses the `wrap_byte_taps.v` wrapper and an `--iq` capture, and is not proven to build
against this netlist generation.

**Files:**
- Modify: `jupiter_240k5_byte/rtl_sim/sim_byte_ce.cpp` (add `--stallready`)
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append the sim section)

**Interfaces:**
- Consumes: `build_replay_v3.sh` (Task 1) → `obj_sim_byte_ce_v3/Vwrap_byte_ce`; invocation form `Vwrap_byte_ce <nclk> <out_prefix> [flags…]`; existing flags are parsed in a `for(int a=3;a<argc;)` loop at `sim_byte_ce.cpp:59`.
- Produces: flag `--stallready S E` — deassert `byte_rx_ready` for clock cycles in `[S, E)`; and `--stallrepeat PERIOD` — repeat that stall every `PERIOD` clocks, which is how a *train* of DMA transfer boundaries is modelled rather than a single one.
- Produces: `<prefix>_frames.csv` columns unchanged (`frame_idx,clk,cnt_frame_start,cap_in,cap_out,bit_errors_out,golden`), so Task 7 scores the `golden` column.

**Reference values, measured on this exact harness+netlist in Task 1 (use as the clean baseline):** 14 frames over 1.6 M clocks, frame cadence exactly **98,664 clocks**, `cap_in = 5216f3e2` on every frame, `cap_out = 04922282` and `golden = 1` on frames 1–13. Frame 0 has `cap_out = 00000000` / `golden = 0` — decoder pipeline fill, always expected, never counted as a hit.

**Hit signature — all of these, stated before the sweep:** one or more frames with
`golden = 0` **after frame 0**, recovering to `golden = 1` within ≤2 frames, at a
stall-locked position. A permanent loss of `golden` is a *different* failure (the harness
never re-locks) and must not be scored as the singles class.

- [ ] **Step 1: Record the clean baseline as a regression fixture**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
./obj_sim_byte_ce_v3/Vwrap_byte_ce 1600000 /tmp/ce_base
cat /tmp/ce_base_res.txt
```

Expected: `cap_in_final=5216f3e2 cap_out_final=04922282 cnt_frame_start=15`. This run
takes ~8 minutes — the build is `--public-flat-rw`, which disables most Verilator
optimisation. Run it in the background with a PID-based wait, never a foreground poll,
and never a `pgrep` pattern that matches your own command line.

- [ ] **Step 2: Add the `--stallready` flag**

In `sim_byte_ce.cpp`, add to the option variables near the other injection state:

```cpp
    long stallS = -1, stallE = -1;   // --stallready S E : byte_rx_ready low in [S,E)
    long stallRep = 0;               // --stallrepeat P  : repeat that window every P clks
```

Add to the argument loop that begins at line 59 (match the surrounding style exactly):

```cpp
        else if(!strcmp(argv[a],"--stallready") && a+2<argc){ stallS=atol(argv[a+1]); stallE=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--stallrepeat") && a+1<argc){ stallRep=atol(argv[a+1]); a+=2; }
```

Replace the single init `t->byte_rx_ready=1;` at line 105 with a per-cycle drive inside
the main clock loop, immediately before the clock edge is evaluated:

```cpp
        /* byte_rx_ready is the RX byte seam's backpressure input. It was pinned to 1
         * for the life of the run, which is precisely why the DMA-boundary singles
         * class could never reproduce here. Drive it per cycle instead. */
        int stalled = 0;
        if(stallS >= 0){
            long c = clk;
            if(stallRep > 0) c = (clk >= stallS) ? stallS + ((clk - stallS) % stallRep) : clk;
            stalled = (c >= stallS && c < stallE);
        }
        t->byte_rx_ready = stalled ? 0 : 1;
```

Use whatever the loop's actual cycle-counter variable is named — read the surrounding
code and match it; do not introduce a second counter.

- [ ] **Step 3: Rebuild**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
jupiter_240k5_byte/rtl_sim/build_replay_v3.sh sim_byte_ce.cpp 2>&1 | tail -3
```

Expected: `BUILD_REPLAY_V3_DONE`.

- [ ] **Step 4: Negative control — the flag, unused, must change nothing**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
./obj_sim_byte_ce_v3/Vwrap_byte_ce 1600000 /tmp/ce_noflag
diff /tmp/ce_base_frames.csv /tmp/ce_noflag_frames.csv && echo NEGATIVE_CONTROL_OK
```

Expected: byte-identical to the Step 1 baseline, and `NEGATIVE_CONTROL_OK`. **If the
files differ, the edit changed behaviour when it should have been inert — fix that before
going further.** An injection harness whose "off" state is not the original behaviour
poisons every result taken with it.

- [ ] **Step 5: Positive control — a long stall must break `golden`**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
./obj_sim_byte_ce_v3/Vwrap_byte_ce 1600000 /tmp/ce_pos --stallready 400000 450000
grep -c ',0$' /tmp/ce_pos_frames.csv
```

A 50,000-clock stall is half a frame time and should be impossible for the seam to
absorb. Expected: at least one frame beyond frame 0 with `golden = 0`. **If a 50k-cycle
stall changes nothing, `byte_rx_ready` is not reaching the DUT — STOP and report; the
port may be tied off inside the wrapper.** That is a finding, not a nuisance, and it
would mean the seam cannot be back-pressured at all.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add jupiter_240k5_byte/rtl_sim/sim_byte_ce.cpp two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "sim_byte_ce: drive byte_rx_ready per cycle (--stallready/--stallrepeat)

byte_rx_ready was pinned to 1 at init and never lowered -- the structural reason the
DMA-boundary singles class has never reproduced in simulation. Negative control asserts
the unused flag is byte-identical to the prior baseline; positive control asserts a
50k-clock stall breaks the golden hash."
git push origin per-under-1pct-2026-07
```

---

## Task 7: Parallel backpressure sweep across the x86 fleet

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/sweep_backpressure.py`
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append the sweep result)

**Interfaces:**
- Consumes: `obj_sim_byte_ce_v3/Vwrap_byte_ce` with `--stallready S E` and `--stallrepeat P` (Task 6); hosts from `~/.claude/HOSTS.md`: `nemo`, `mini2`, `nuc` (`10.0.0.121`), `tron` (`10.0.0.52`), `lablp`, `bq`.
- Produces: `jupiter_240k5_byte/rtl_sim/sweep_results.csv` with columns `host,stall_start,stall_len,stall_rep,frames_total,frames_bad,max_run,hit`.

**Sweep axes:** **stall phase** within the 98,664-clock frame (stepped in 24 increments, so every landing point inside the delivery burst and the ~50 % zero-pad slack is covered) × **stall duration** (short enough to be absorbable through clearly not: 200 / 1,000 / 5,000 / 20,000 clocks) × **repeat period** (single-shot, and repeating every frame to model a boundary train).

**`-M` is deliberately NOT a sim axis.** `-M` is a *host* DMA parameter setting how many frames share a transfer, i.e. how *often* boundaries occur. Its simulation analogue is the stall's phase and repeat period, not a value passed to the binary. Sweeping an `m` column that never reaches the simulation would make the results CSV look three times larger than the space actually explored. `-M` is swept on **hardware**, in Task 3.

**Cost warning:** each leg is ~8 minutes (`--public-flat-rw`). 24 phases × 4 durations × 2 repeat modes = 192 legs ≈ 26 hours serial. Across 5 fleet hosts that is ~5 hours. **Reduce `nclk` to 600,000** (≈5 frames, still several frames past the pipeline-fill frame) for sweep legs — that cuts each leg to ~3 minutes and the fleet total to under 2 hours. Re-run any hit at the full 1.6 M to confirm.

- [ ] **Step 1: Probe the fleet before promising parallelism**

```bash
for h in nemo mini2 nuc tron lablp bq; do
  printf "%-8s " "$h"
  timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" \
    'which verilator >/dev/null 2>&1 && verilator --version || echo NO_VERILATOR' 2>&1 | tail -1
done
```

Record which hosts have Verilator. **Do not silently drop a host** — one lacking the
toolchain is excluded loudly and named in the results. If only the local host qualifies,
run the sweep locally and say so; a serial sweep reported honestly beats a parallel one
that quietly ran on one machine.

Also confirm each qualifying host can see the repo at the same absolute path (it is on
shared storage at `/mnt/onetb`, but verify rather than assume):

```bash
for h in <qualifying hosts>; do
  printf "%-8s " "$h"
  ssh -o BatchMode=yes "$h" 'ls /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/obj_sim_byte_ce_v3/Vwrap_byte_ce >/dev/null 2>&1 && echo BIN_OK || echo NO_BIN'
done
```

A host with Verilator but no visible binary is excluded too — and named.

- [ ] **Step 2: Write the runner**

Create `jupiter_240k5_byte/rtl_sim/sweep_backpressure.py`:

```python
#!/usr/bin/env python3
"""sweep_backpressure.py -- fan the byte_rx_ready stall sweep across the x86 fleet.

Each leg is one Vwrap_byte_ce run with a distinct (stall_start, stall_len, stall_rep).
Legs are independent, so this is embarrassingly parallel; the only shared state is the
read-only binary on shared storage.

Scoring uses the GOLDEN column of <prefix>_frames.csv, not a CRC count: the harness is
BIST-ROM driven with known-good hashes, so corruption detection is bit-exact.
Frame 0 always has golden=0 (decoder pipeline fill) and is EXCLUDED from scoring.

Hosts without verilator, or without the binary visible, are EXCLUDED LOUDLY and named --
never silently dropped, and never counted as clean legs.
"""
import argparse
import concurrent.futures as cf
import csv
import os
import subprocess

BIN = "obj_sim_byte_ce_v3/Vwrap_byte_ce"
FRAME_CLKS = 98_664          # measured, Task 1
BASE = 200_000               # start well past acquisition


def score(path):
    """Return (frames_total, frames_bad, max_run) from a _frames.csv, skipping frame 0."""
    if not os.path.exists(path):
        return (0, -1, -1)
    bad, run, mx, total = 0, 0, 0, 0
    with open(path) as fh:
        for row in csv.DictReader(fh):
            if int(row["frame_idx"]) == 0:      # pipeline fill -- never a hit
                continue
            total += 1
            if row["golden"].strip() == "0":
                bad += 1; run += 1; mx = max(mx, run)
            else:
                run = 0
    return (total, bad, mx)


def run_leg(host, start, length, rep, repo, nclk):
    pfx = f"/tmp/bpsweep_{start}_{length}_{rep}"
    inner = (f"cd {repo}/jupiter_240k5_byte/rtl_sim && ./{BIN} {nclk} {pfx} "
             f"--stallready {start} {start + length}")
    if rep:
        inner += f" --stallrepeat {rep}"
    cmd = inner if host == "local" else \
        f"ssh -o BatchMode=yes -o ConnectTimeout=10 {host} '{inner}'"
    row = {"host": host, "stall_start": start, "stall_len": length, "stall_rep": rep}
    try:
        subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=3600)
    except subprocess.TimeoutExpired:
        row.update(frames_total=-1, frames_bad=-1, max_run=-1, hit="TIMEOUT")
        return row
    total, bad, mx = score(f"{pfx}_frames.csv")
    # HIT = at least one post-frame-0 golden break that RECOVERS within 2 frames.
    # A permanent loss of golden means the harness never re-locked: a different
    # failure, not the self-healing singles class.
    row.update(frames_total=total, frames_bad=bad, max_run=mx,
               hit=bool(bad > 0 and 0 < mx <= 2))
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hosts", required=True, help="comma-separated, or 'local'")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--nclk", type=int, default=600_000)
    ap.add_argument("--out", default="sweep_results.csv")
    a = ap.parse_args()

    hosts = [h.strip() for h in a.hosts.split(",") if h.strip()]
    legs = [(BASE + k * (FRAME_CLKS // 24), L, rep)
            for k in range(24)
            for L in (200, 1_000, 5_000, 20_000)
            for rep in (0, FRAME_CLKS)]
    print(f"{len(legs)} legs across {len(hosts)} host(s): {', '.join(hosts)}")

    rows = []
    with cf.ThreadPoolExecutor(max_workers=len(hosts) * 2) as ex:
        futs = [ex.submit(run_leg, hosts[i % len(hosts)], s, L, rep, a.repo, a.nclk)
                for i, (s, L, rep) in enumerate(legs)]
        for f in cf.as_completed(futs):
            r = f.result(); rows.append(r)
            if r["hit"] is True:
                print(f"HIT start={r['stall_start']} len={r['stall_len']} "
                      f"rep={r['stall_rep']} bad={r['frames_bad']} max_run={r['max_run']}")

    with open(a.out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    hits = sum(1 for r in rows if r["hit"] is True)
    to = sum(1 for r in rows if r["hit"] == "TIMEOUT")
    print(f"SWEEP_DONE legs={len(rows)} hits={hits} timeouts={to} -> {a.out}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run the sweep detached**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
setsid nohup python3 sweep_backpressure.py \
  --hosts <qualifying hosts from Step 1, comma-separated> \
  --repo /mnt/onetb/scratch/qpsk-jupiter-modem \
  --nclk 600000 \
  > /tmp/bpsweep.log 2>&1 < /dev/null & disown
```

Wait for the strict terminal marker `SWEEP_DONE`. Do not poll in the foreground.

- [ ] **Step 4: Apply the verdict rule**

- **HIT** — re-run each hit at the full `--nclk 1600000` to confirm it survives a longer
  run, then record the exact `(stall_start, stall_len, stall_rep)`. This is the first sim
  positive control this class has ever had; it becomes the regression case any fabric fix
  must zero, and it gates the Phase-3B branch.
- **CLEAN SWEEP** — backpressure-into-serializer is **falsified**. That is a result, not
  a failure. Redirect to `ByteWordBuffer` internal state: pointer/counter phases reachable
  only after long uptime, which reset-state replay structurally cannot reach. This is the
  same blind spot that hid the 119.75 s beat for weeks. Say so explicitly and re-scope
  rather than widening the sweep indefinitely.

Report how many legs ran, on how many hosts, and name every leg that timed out or was
excluded. A sweep that silently covered less than it claims is the failure mode the
metrics rule exists to prevent.

- [ ] **Step 5: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add jupiter_240k5_byte/rtl_sim/sweep_backpressure.py jupiter_240k5_byte/rtl_sim/sweep_results.csv two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "Phase 2.3: parallel byte_rx_ready stall sweep across the x86 fleet

Stall phase x duration x repeat period, scored bit-exactly on the golden hash column
(frame 0 excluded as pipeline fill). Hosts lacking verilator or the binary are excluded
loudly and named. Verdict rule pre-stated: a hit is the first sim positive control for
this class; a clean sweep FALSIFIES backpressure and redirects to ByteWordBuffer state."
git push origin per-under-1pct-2026-07
```

---

## Task 8: Air verification and baseline re-anchor

**Blocked** until the operator repairs the reverse RF leg (148 TX → 146 RX, ~6 dB short). Do not attempt; do not report air numbers from a degraded link. Every earlier task is independent of this one.

**Files:**
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append the air section)
- Modify: `OVERNIGHT_LOG.md` (append the campaign checkpoint)

**Interfaces:**
- Consumes: `two_jup/capture_r3.sh` (`SIDE=A` = 146 TX → 148 RX), `two_jup/accept_analyze.py` (host_seq-gap metric), `two_jup/paired_report.py` (per-run reporting; it deliberately refuses a pooled headline because losses are bursty and the independence assumption fails).

- [ ] **Step 1: Confirm the rig is genuinely healthy first**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
setsid nohup ./restore_known_good.sh > /tmp/restore_air.log 2>&1 < /dev/null & disown
```

Gate: `ARM GATE PASS` with **both** boards ≥1120 f/s, daemons up, watchdogs up. Restore is often two passes. **Do not proceed on a failed gate** — that is the state that produced the whole 2026-08-22 blockage.

- [ ] **Step 2: Re-anchor the baseline (three runs)**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
for i in 1 2 3; do
  ./capture_r3.sh A -d 68 -k -o r3cap/baseline_$(date +%Y%m%d_%H%M%S)_r$i
done
for d in r3cap/baseline_*; do python3 accept_analyze.py "$d"; done
```

Record forward PER with CP95 bounds, the exact command, the sample count, and explicit confirmation that dropped frames are in the denominator. This measures the unexplained 8.3 % → 12.4 % drift and separates channel degradation from the comb.

- [ ] **Step 3: Capture an RF health snapshot alongside**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
for ip in 10.0.0.146 10.0.0.148; do
  echo "--- $ip"
  ./anyssh.sh $ip 'for f in /sys/bus/iio/devices/iio:device*/in_voltage0_rssi \
     /sys/bus/iio/devices/iio:device*/in_voltage0_hardwaregain; do
     echo -n "$f "; cat $f 2>/dev/null; done'
done
```

The 2026-08-22 reference for comparison: 146 RSSI 28.8 dB, 148 22.8 dB, both gains 34 dB — a ~6 dB reverse asymmetry.

- [ ] **Step 4: Run the winning fix arm on air, alternating**

Only if Task 4 or Task 7 produced a fix candidate. Alternate arms run-by-run to control channel drift, and report per-run:

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
python3 paired_report.py r3cap/baseline_* r3cap/<fix-arm dirs>
```

- [ ] **Step 5: Write the campaign checkpoint**

Append to `OVERNIGHT_LOG.md` a checkpoint in the established format: headline, what is verified on hardware, the PER truth table with denominators, any retractions, rig state, instrument inventory, refuted ledger, and next steps.

State plainly whether the <1 % target is met. If it is not, say so — per the metrics rule, an unconfirmed target is reported as unconfirmed.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/SINGLES_CAMPAIGN.md OVERNIGHT_LOG.md two_jup/r3cap/baseline_*/
git commit -s -m "Phase 0.3 + air verification: re-anchored baseline and fix-arm A/B

Per-run reporting via paired_report.py (no pooled headline -- losses are bursty).
Dropped frames in the denominator. RF health snapshot recorded alongside."
git push origin per-under-1pct-2026-07
```

---

## Self-Review

**Spec coverage:**

| spec section | task |
|---|---|
| 0.1 rig restore | Task 3 Step 4, Task 8 Step 1 |
| 0.2 netlist provenance | Task 1 (all steps) |
| 0.3 baseline re-anchor | Task 8 Steps 2–3 |
| Phase 1 off-air repro + verdict rule | Tasks 2 (scorer) and 3 (harness) |
| Phase 2.1 measure backpressure | Task 5 |
| Phase 2.2 replay matched | Task 6 (BIST-ROM harness; no IQ capture needed) |
| Phase 2.3 parallel sweep | Task 7 |
| Phase 2.4 positive control | Task 6 Steps 4–5 (negative AND positive); Task 2 self-tests |
| Phase 3A cyclic RX | Task 4 |
| Phase 3B fabric elastic buffer | **Deliberately not planned.** Gated on a Task 7 hit; scoping it now would violate the spec's own gate ("not built until the positive control exists"). It gets its own plan if Task 7 hits. |
| Metrics discipline | Global Constraints; Tasks 2, 4, 8 |
| Parallelism/mutexes | Global Constraints; Task 3 Step 2, Task 7 Step 1 |

**Placeholder scan:** the remaining angle-bracket substitutions are all *outputs of an earlier step*, not unspecified work: `<qualifying hosts from Step 1>` (Task 7 Steps 1 and 3). Each names its source step explicitly. Tasks 6 and 7 no longer depend on a measured length from Task 5 — the stall durations are a fixed ladder (200 / 1,000 / 5,000 / 20,000 clocks), so Phase 2 can proceed even if Task 5's counters fail to resolve the waveform; Task 5's measurement then selects *which* rung matches hardware rather than gating the sweep.

**Type consistency (re-checked after the Task 6/7 rewrite):** `build_replay_v3.sh [driver] [objdir]` is defined in Task 1 and called with that signature in Tasks 6 and 7; it produces `obj_sim_byte_ce_v3/Vwrap_byte_ce` (top module `wrap_byte_ce`), which is the exact binary path Tasks 6 and 7 invoke. `--stallready S E` and `--stallrepeat P` are defined in Task 6 and consumed with those exact spellings in Task 7. The `_frames.csv` column set (`frame_idx,clk,cnt_frame_start,cap_in,cap_out,bit_errors_out,golden`) is measured in Task 1 and parsed by name in Task 7's `score()`. `classify(frames, m)` is defined in Task 2 and called with that signature in Tasks 3 and 4. `V3_NETLIST_DIR` / `V3_CADENCE=2` are produced in Task 1 and consumed in Tasks 6 and 7. `--stallready S E` and `--eatvalid SAMPLE COUNT` were verified present in `sim_byte_inject.cpp` before being written into Tasks 6 and 7. `read_frames` / `DTYPE` field names match `frame_taxonomy.py` exactly.
