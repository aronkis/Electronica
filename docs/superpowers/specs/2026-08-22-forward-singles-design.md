# Forward singles-comb campaign — design

**Date:** 2026-08-22
**Branch:** `per-under-1pct-2026-07`
**Status:** design approved (operator "Go go", 2026-08-22)

## Goal

Root-cause and fix the **forward singles-comb class** — currently the entire forward
packet-loss problem at ~12.4 % delivered PER (146→148, ARQ off) — using simulation as
the fast verification loop and hardware only where it is the sole oracle.

Campaign target unchanged and NOT met: delivered PER < 1 % both directions, ARQ off.

## Scope

**In scope:** the forward (146→148) singles-comb class, its sim reproduction, and its
fix; the netlist-provenance and baseline work that makes any result citable.

**Explicitly out of scope** (deferred, each with a pointer, none silently dropped):

| deferred | why | where it lives |
|---|---|---|
| Reverse direction / 146 fixes | 146 stays frozen — operator decision, standing never-flash policy | `OVERNIGHT_LOG.md` checkpoint, item 3 |
| 1.57 s device-tick class | separate mechanism, host/radio-side | `ERROR_TAXONOMY.md` Class 1 |
| Class-B 1.00 s outages | localized to the TX byte-ingestion seam | `TGEN_SWEEP.md` |
| Short-fill wedge (#48) | has a deterministic trigger + sim positive control already | `SIM_WEDGE_REPRO.md` |
| Overrun swallow | reproducible with two register writes; understood | `TGEN_SWEEP.md` |
| 119.75 s beat | SOLVED, fixed, verified, PER-neutral | `STAGE_LOCALIZED.md` |

## Why this class, and where it lives

The beat fix (BEATFIX v3, image `fe5bd8a4fe19`) is verified correct on its own
mechanism — zero errors through six scheduled slots with `fixctl=3` — but PER-neutral.
The v3 A/B showed 12.370 / 12.488 % (legacy) vs 12.222 / 13.211 % (fix), clean fractions
identical at ~87.9 %, gap bins singles-dominated with zero burst-class runs in any leg.
The singles comb is therefore **proven independent of the beat** and is the whole
forward problem.

### The stage is already bounded — by three measurements that only look contradictory

| evidence | source | what it says |
|---|---|---|
| 12/12 hardware-corrupt seqs decode **CRC-good** from 148's own captured IQ; the harness taps `byte_rx_*`, i.e. the **ByteSerializer output** | `SINGLES_REPLAY.md`, `sim_byte_iq_perframe.cpp` | with `byte_rx_ready` held high, the serializer output is CLEAN |
| CP1 comparator on silicon: fabric ByteSerializer-output checksum **==** the corrupt host bytes, 107/117 (chance 1/65536) | `FWD_SINGLES_ROOT_CAUSE.md` | on hardware the serializer output is ALREADY CORRUPT |
| TGEN RX seam: bit-exact zero-loss at 620–16,520 f/s, fills 0–1516, `lost=0` everywhere | `TGEN_SWEEP.md` | the path DOWNSTREAM of the serializer (breakout → DMA → host) is CLEAN |

The same tap yields opposite verdicts, and the only difference between the two
conditions is **real DMA backpressure**. The TGEN RX generator splices downstream of the
serializer, so it exonerates nothing inside the suspect window; all three results are
consistent. Combined with the `-M`-locked event cadence (13/26 ms at `-M 16`,
25–26/51 ms at `-M 32`), the target is:

> **`ByteWordBuffer` → `ByteSerializer`, under real `byte_rx_ready` / transfer-boundary
> behaviour** — a condition no simulation has ever modelled faithfully.

### Why the existing "backpressure exonerated" result does not close this

`sim_byte_dip.cpp` scheduled 26 `byte_rx_ready` dips at the 8-frame cadence and produced
bit-identical output. That verdict is **retired, not cited**, for two independent
reasons:

1. **Provenance.** It ran against the Jul-25 netlist (drive cadence 4) while 148 now
   runs BEATFIX v3 `fe5bd8a4fe19` (cadence 2) — two generations later.
2. **Fidelity.** Its dip profile was an *assumed* waveform. The real S2MM boundary
   involves `SYNC_TRANSFER_START` re-sync and `tuser`, and was never measured.

Both are fixed by Phase 0.2 and Phase 2.1 respectively.

## Architecture — four phases, each with a pre-stated verdict rule

Standing epistemology (unchanged): a green sim is a **sufficiency proof only**. No sim
match closes a question; hardware confirms.

### Phase 0 — Make results citable (blocking)

**0.1 Rig restore.** Return both boards to ~1245 f/s with daemons up.

> **Known blocker as of 2026-08-22:** three restore passes failed the arm gate. 148 RX
> 1235–1243 f/s every try; 146 RX pinned 498–528 f/s (need ≥1120). A 146 power cycle did
> NOT clear it, refuting the kernel/arm-wedge hypothesis. The `lb_discrim` run showed
> **146 rx = 1246 f/s, rstcs = 0 in FPGA-internal loopback** on both boards, versus
> carrier-resetting failure on air, with 146 RSSI 28.8 dB vs 148 22.8 dB at equal 34 dB
> gain (~6 dB short on the reverse leg). **146's demod and fabric are healthy; the
> reverse RF chain is the fault.** This is a bench-side action under the operator's RF
> hold. Phases 0.2, 1 (via 148 internal loopback) and 2 are unaffected.

**0.2 Netlist provenance.** Determine which on-disk netlist corresponds to the flashed
v3 image and pin every byte-plane harness to it.

Known layout trap, already found: the `*_gates` dirs use
`s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`, while the beatfix lineage uses
`hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/`. A census that looks only at
the former reports "no netlist" for the v3 builds, which is wrong. Current `_gates`
census (`TxRxComposite.v`, first 12 hex of md5):

```
23162f683a8c  jupiter_byte_fsv2_gates
8a1b4062e824  jupiter_byte_tmr146_gates
0805db58bcdd  jupiter_byte_wit3_gates
06bbc92c2f6d  jupiter_240k5_byte/s1_rtl
```

- **Deliverable:** `two_jup/NETLIST_PROVENANCE.md` naming the matched netlist, its md5s,
  its drive cadence, and the reasoning that ties it to `fe5bd8a4fe19`; plus a build
  script that *pins* that path rather than hardcoding `$KIT/s1_rtl`.
- **If no on-disk netlist matches:** regenerate from the beatfix lean lineage with
  `QPSK_BEATFIX` set (HDL Coder run, ~1 h, **no Vivado build, no flash**).
- **Gate:** no simulation result from the byte-plane family is cited anywhere until this
  passes. This includes retiring the `sim_byte_dip` exoneration in the docs.

**0.3 Baseline re-anchor.** Three forward acceptance runs on the restored rig plus an RF
health snapshot (RSSI, gains, EVM), to separate the unexplained 8.3 % → 12.4 % drift
from the comb itself.

- **Deliverable:** current forward PER with exact command, sample count, CP95 bounds, and
  explicit confirmation that dropped frames are in the denominator.
- **Blocked by 0.1.** Everything else proceeds without it.

### Phase 1 — Does the comb exist off-air? (zero build; the campaign accelerator)

Run the RX chain in **FPGA-internal loopback** (`0x114=0`) through the *real* host DMA
path at `-M 16`, scored with `-S` loss-proof accounting (every transmitted frame ends
OK / BITERR / LOST exactly once). Sweep the `-M` axis (16 / 32 / 64) — the cadence-lock,
not the absolute rate, is the class fingerprint.

This mode was just measured healthy at 1246 f/s with zero carrier resets on both boards,
so it runs even with the air link down.

**Verdict rule, stated before running:**

- **REPRODUCES** — singles at ~50/s at the `-M`-locked DMA cadence with no RF involved:
  the channel is exonerated, baseline drift becomes irrelevant to *fix* verification, and
  the campaign moves off-air at minutes-per-iteration. This branch pays for everything
  downstream.
- **DOES NOT REPRODUCE** — the class needs the air or SSI path. Re-run over **SSI
  near-end loopback** (the beat campaign's proven discriminator) to split "needs RF" from
  "needs the SSI clock chain", and re-scope Phase 2 accordingly.
- **PARTIAL** — present but at a different rate: record the rate ratio; it constrains the
  mechanism (a duty-cycle-dependent boundary effect predicts a specific ratio).

### Phase 2 — Sim reproduction: provenance-matched AND backpressure-faithful

**2.1 Measure the real backpressure waveform.** Obtain the transfer-boundary gap
distribution and `byte_rx_ready` duty at `-M 16` and `-M 32` from the DMAC registers plus
the existing `framestat` / CP1 word counters (`0x1C0`), and read `0x1B0`
(`byte_rxfifo_overlay` overflow counter) in the same pass — it must be zero and has not
been checked recently.

- **If the existing counters cannot resolve the waveform, this is the trigger for the one
  authorized probe build:** pack `{byte_rx_ready, byte_rx_user, ByteWordBuffer fill,
  ByteSerializer state}` into the `debugI/Q1` taps using the proven env-gated overlay
  pattern (`beatobs_overlay.m` idiom — byte-identical model when the gate is unset), read
  out over the working XVC ILA path. Build only; **flashing requires separate explicit
  authorization.**

**2.2 Replay** the banked `two_jup/r3cap/singles_reread/pair.iq` through the
provenance-matched netlist at the correct cadence, with the measured ready waveform
applied — reusing `sim_byte_inject.cpp`'s existing `--stallready S E` and
`--eatvalid SAMPLE COUNT` knobs where they fit, so the stall study needs a rebuild, not
new harness code.

**2.3 Sweep in parallel** across the x86 fleet (nemo, mini2, nuc, tron, lablp, bq —
toolchain probed per host first, failing loudly if absent, per the no-hardcoded-vendor-
paths rule):

- boundary phase within the frame (the ~50 % zero-pad slack is the hypothesised safe zone)
- `-M` ∈ {16, 32, 64}
- ready-deassert duration
- `SYNC_TRANSFER_START` / `tuser` re-sync model on/off

**Verdict rule, stated before running:** a **hit** is a full-length 191-word
wrong-content frame at the serializer output, self-healing within ≤2 frames, at a
boundary-locked cadence — matching the hardware signature on all four counts. That is the
first sim positive control this class has ever had, and it gates Phase 3B.

A **clean sweep across the entire space falsifies** backpressure-into-serializer. The
campaign then redirects to `ByteWordBuffer` internal state (pointer/counter phase reached
only after long uptime), which reset-state replay structurally cannot reach — the same
gap that hid the beat for weeks.

**2.4 Positive control (mandatory before believing any zero).** Deliberately corrupt one
word at one tap in sim and confirm the scorer flags exactly that tap, with zero false
positives on the clean leg. No instrument that has never caught a planted fault is
trusted with a negative result.

### Phase 3 — Fix, cheapest first

**3A — Cyclic RX DMA (host-only; no build, no flash).** The originally-designed fix that
was never executed. `rx_byte_dma` is cyclic-capable via FLAGS bit0 (`CYCLIC_RXBYTE_OK` in
the build); the host ring design exists at
`two_jup/cyclic_dma_patch/HOST_RING_REWRITE.md` — §2(c) is the content-based completion
mechanism (reading completed segments behind the write pointer without a reset), §2(d)
its risks, §2(e) the non-cyclic fallback. Cyclic mode has **no transfer
boundaries at all**, so if the mechanism is boundary-locked this eliminates it for the
price of a `qpsk_tun` patch behind `QPSK_RX_CYCLIC=1`.

- **Trigger-independence flag:** 3A is a *fix*, not a mask, **iff** Phase 2 confirms the
  boundary as the mechanism. If Phase 2 falsifies backpressure, 3A becomes a mask at best
  and must not be shipped on the strength of a PER delta alone.
- **Known cost:** cyclic converts overflow from lossless-stall into silent overwrite. The
  lap-guard (already exercised in userspace, observed firing) is **mandatory**, and
  `TRANSFER_DONE`/EOT die under cyclic, so completion must be content-based.
- **Verify** in the Phase-1 loopback first (fast, channel-independent), then on air.

**3B — Fabric elastic buffer at the serializer.** Only if 3A is refuted or blocked.

- **Hard gate:** skid v1 and v2 already failed at this exact stage (v1 silicon deadlock,
  v2 +5.6 pp harm). 3B is not built until the Phase-2.3 positive control exists AND the
  proposed fix zeroes it in sim.
- Resource honesty required at design time: the die is effectively full (CLB
  8796/8820 = 99.73 % on skid4). State plainly if it will not place.

Every fix carries the standing flag: **does it fix the fault, or mask a trigger that will
still fire?**

## Verification and metrics discipline

- **Fast gate:** Phase-1 FPGA-internal loopback with `-S` loss-proof accounting —
  channel-independent, so it is valid even while the reverse RF leg is broken.
- **Delivered number:** air PER via `capture_r3.sh` + `accept_analyze.py` host_seq-gap
  metric, alternating A/B arms to control channel drift, dropped frames in the
  denominator, CP95 upper bounds, measured against the Phase-0.3 re-anchored baseline.
- **No claim without:** exact command, sample count, and explicit confirmation that
  dropped/lost frames are counted in the denominator.
- **Per-run reporting** via `paired_report.py`, which refuses a pooled headline because
  losses are bursty and the independence assumption fails.

## Parallelism and mutexes

| resource | discipline |
|---|---|
| The rig | **hard mutex** — one harness at a time, never two concurrently. Restore after every session. |
| Verilator legs | free fan-out across the x86 fleet; the singles replay already ran 3 chunks concurrently |
| Vivado | the long pole; **at most one build**, gated on Phase 2.1 failing to resolve the waveform |
| MATLAB / HDL Coder | needed only if 0.2 forces a netlist regen |

Watcher discipline (has cost real time repeatedly): never `pgrep`/`pkill` a pattern
present in the watcher's own command line — bracket it or use explicit PIDs. Watchers
trigger on strict terminal markers only. Long builds run under `setsid nohup … & disown`.

## Risks and honest limits

1. **Phase 1 may not reproduce off-air**, leaving the campaign air-bound and therefore
   blocked behind the RF repair. Mitigation: the SSI near-end loopback split.
2. **The reverse RF leg is broken and is an operator/bench action.** Air verification of
   any fix is blocked until it is repaired. The design is deliberately structured so that
   only the final delivered number needs air.
3. **Provenance may force a netlist regen**, adding ~1 h before any sim result is citable.
4. **Phase 2 may falsify the leading mechanism.** This is a real possibility and the plan
   states the redirect explicitly rather than treating a null as failure.
5. **Baseline drift is unexplained** (8.3 % → 12.4 %) and may itself be RF, in which case
   part of the "singles" growth is channel, not fabric. Phase 0.3 exists to measure this
   before any fix takes credit.

## Definition of done

The forward singles class is **named by observation** — a stage, a mechanism, and a
reproduction — and a fix is verified first in the channel-independent loopback gate and
then in delivered air PER against a re-anchored baseline, with the trigger-independence
question answered explicitly.
