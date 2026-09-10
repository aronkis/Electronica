# Parallel datapath-block investigation with subagents — design

**Date:** 2026-08-31
**Status:** approved in brainstorming, pending spec review
**Governor:** the interactive Claude session on nemo
**Related:** `two_jup/SESSION_20260830_AUTONOMOUS.md` (§0 standing rule, §5, §8, §20–§24),
`two_jup/RESUME_20260831.md`, `two_jup/SINGLES_CAMPAIGN.md`

---

## 1. Purpose

Continue localising the source of the QPSK modem's periodic burst ("the beat") by instrumenting the
remaining datapath blocks, using parallel subagents for builds and analysis while serialising all hardware
access through a single arbiter.

The campaign's binding constraint is not compute — it is **one modem rig and one board that may be
flashed** (148). A flash-measure-restore cycle is ~25 minutes of exclusive board time. Parallelism buys
overlapping builds and analysis; it cannot shorten the hardware queue.

The campaign's binding *risk* is not board damage — it is **believing a broken instrument**. Two witnesses
fooled us on 2026-08-30, both producing clean, plausible, welcome results (§20 → §22). Every structural
choice below is aimed at that failure mode.

---

## 2. State at the time of writing

**Established on silicon** (see the session file for full provenance):

- The start-pulse hypothesis is dead: 1.0000 startIn / vitReset / startOut per frame through 801k bit errors.
- The BIST comparator scores only the first 120 of 2240 bits; this dissolved the 0.24 % vs 0.09 % header
  discrepancy (§5). **Closed — not to be reopened.**
- The SSI/LVDS path is exonerated for beat and floor.
- The beat is deterministic and phase-locked to reset, ~239.5 s two-state cycle.
- `FecCapture` (cap_in 0x13C / cap_deint 0x140 / cap_out 0x144) is the one witness reliable throughout:
  99.3–100 % golden quiet, 42–52 % in bursts, on every run.

**New, 2026-08-31 08:20** — `two_jup/multitap/20260831_074947`, image `0f203cf887d3`, capTAP
golden-constancy, all four taps K1-PASS:

| stage | quiet % golden | burst % golden |
|---|---|---|
| AGC out | 100.0 % | **50.0 %** |
| postSymbolSync | 99.7 % | **48.0 %** |
| postCarrierSync | 100.0 % | **47.4 %** |
| QPSKConstellation (demod in) | 99.7 % | **46.2 %** |
| cap_in / cap_deint / cap_out | 99.3–99.8 % | 47.8–48.9 % |

**Every instrumented RX stage deviates during bursts, including the first one.** The error is present at
or before the AGC output — i.e. at the RX chain input, which under mode-1 internal loopback *is the
transmitter's output*. The RX chain is therefore exonerated as the **origin**; each stage merely inherits
damage that arrives already present.

**Withdrawn:** §20's per-stage localisation (dead counters). Any run that swept `iq_debug_mux` mid-poll has
void DBGCAP columns.

**Consequence for this design:** the TX is now the frontier. Priority shifts to TXCAP and the TX internals;
the RX front-end blocks drop to cross-validation.

---

## 3. Decisions taken (brainstorming, 2026-08-31)

| # | Decision | Chosen |
|---|---|---|
| 1 | Agent authority over hardware | **Agents flash**, owning a block end-to-end |
| 2 | Failed flash | **Global halt** — rollback, rig-wide stop, all agents freeze |
| 3 | Work granularity | **One agent per image**, several blocks each |
| 4 | Dashboard | **Live HTML at nemo:8090** from per-agent JSON fragments |
| 5 | Governor | **This session** |
| 6 | Agent depth | **One cycle, then report**; iteration is a fresh agent |

---

## 4. Architecture

### 4.1 Topology

Governor (this session) spawns one-shot worker agents, receives reports, applies the §0 gate, and is the
**sole writer** of settled knowledge.

| agent | build host | scope |
|---|---|---|
| **MEASURE** | none | No build, no flash. Capture-constancy on the flashed image: TXCAP (`fixctl[12]`), DEMODCAP (`fixctl[13]`). |
| **TX-INT** | hdl-dev-2 | New image: QPSK_Modulator output, TX RRC output. |
| **RX-FE** | nemo | New image: RRC receive filter output, coarse frequency compensator output. |

Build hosts: **nemo** (this host, 12 cores, Vivado `/tools/Xilinx/2025.1`) and **hdl-dev-2** = 10.0.0.11
(8 cores, Vivado `/opt/Xilinx/2025.1/Vivado`, builds in `~/qpsk-builds/`). hdl-dev-2 is absent from
HOSTS.md and should be added.

### 4.2 The rig arbiter

`riglock.sh` is not reusable for multiple actors: it does check-then-write on a plain file (TOCTOU race)
and `exit 3`s the loser instead of queueing. Replaced by a **directory mutex** (`mkdir` is atomic on POSIX):

```
/home/tcollins/modem-status/RIG_MUTEX.d/     acquire = mkdir; fails if held
    owner        agent, PID, phase (flashing|measuring|restoring), acquired-at
    heartbeat    touched every 60 s by the holder
/home/tcollins/modem-status/RIG_HALT         global stop flag, checked BEFORE every acquire
```

Rules, in priority order:

1. **`RIG_HALT` beats everything.** Any agent seeing it refuses to acquire and exits `blocked`. A failed
   flash writes it after rolling back. Only the operator or the governor clears it.
2. **The critical section is the whole cycle** — flash, measure, restore under one acquisition. No agent
   ever measures on an image another agent flashed.
3. **A stale lock is never auto-stolen.** Heartbeat older than 10 min ⇒ report to governor and exit. A
   stale lock means something died mid-cycle, precisely when a second actor must not start flashing.
4. **The holder also writes the legacy `RIG_LOCK` and `SENTINEL_STOP`**, so the sentinel and every existing
   script (`bringup_r2r3.sh`, the flash rails, `multitap_run.sh`) keep working and cannot collide.

Waiting agents poll with backoff and a hard budget; if the rig does not free in time they report
`unstarted` rather than queueing forever.

### 4.3 Agent contract

Fixed eight-step cycle, each step gating the next:

1. **Design the instrument** — bounded capture, armed by a frame marker, scored by golden-constancy.
   No rolling signatures; no reliance on an on-chip reference latch.
2. **Sim-gate** — Verilator, clean loopback, every witness frame-invariant. Fail ⇒ no flash.
3. **Positive control in sim** — force a non-null. Fail ⇒ no rig.
4. **Acquire the rig** — check `RIG_HALT`, then `mkdir`.
5. **Flash with full rails** — restore point banked and named, readback verify, two-pass health gate,
   auto-rollback, **no retry**. Fail ⇒ rollback, write `RIG_HALT`, release, report.
6. **Positive control on silicon** — before the real measurement. This is the step that would have caught
   the dead DBGCAP counters.
7. **Measure**, restore the link with the gated bring-up, release the mutex.
8. **Report and exit.**

**MEASURE runs a reduced contract.** It has no build and no flash, so it executes steps 4, 6, 7 and 8
only: acquire, silicon positive control, measure and restore, report. Steps 1–3 and 5 do not apply. Its
positive control is the tap-switch test — park, confirm flat; switch, confirm it climbs — which is the same
test that exposed the §23 faults. If its positive control fails, it reports and does **not** collect the
measurement, exactly as a build agent would.

**New images are additive**: branch from the FINAL RTL and keep DBGCAP, TXCAP and DEMODCAP while adding new
taps. Working instruments are never traded away, and every image can re-check an earlier block.

### 4.4 Liveness supervision

Each agent writes a state fragment atomically (temp file + rename — never a partial read):

```
/home/tcollins/modem-status/agents/<agent>.json
    agent, host, blocks, phase, rig_held, started, last_heartbeat,
    step_status[1..8], findings, provenance
```

Updated at each phase transition and at least every 60 s. One write serves both liveness and the dashboard,
so there is no second bookkeeping channel to drift.

**Governor sweep, every 10 minutes:**

| condition | action |
|---|---|
| heartbeat < 10 min | healthy, silent |
| stale, agent does **not** hold the rig | mark dead, free slot, report, requeue block as a fresh agent |
| stale, agent **holds** the rig | **write `RIG_HALT`**, verify 148 pings and which image it runs, freeze all rig work, alert operator |
| `RIG_HALT` present | report which agent set it and why |
| rig held, no live owner, board unreachable | alert loudly — the dark-board case |

Implemented as a Monitor poll loop, silent when healthy, emitting only anomaly rows plus one hourly
heartbeat so the supervisor's own liveness is visible.

---

## 5. Dashboard

Two sources, one page, served at `nemo:8090` beside the existing modem status page:

- `two_jup/chain.json` — settled knowledge, one entry per block. **Governor-only writer.** Committed.
- `/home/tcollins/modem-status/agents/*.json` — live per-agent progress.

### 5.1 Status vocabulary

| status | meaning |
|---|---|
| `UNTESTED` | no instrument exists |
| `INSTRUMENTED` | witness built, not yet validated on silicon |
| `WITNESS-DEAD` | instrument failed its positive control — results void |
| `MEASURED-CLEAN` | positive control passed **and** holds golden through bursts ⇒ exonerated |
| `MEASURED-DEVIATES` | positive control passed and deviates in bursts ⇒ error present at or before here |
| `WITHDRAWN` | prior claim retracted, with reason |

### 5.2 Hard render gate

Every row carries a `positive_control` field. **The renderer refuses to display `MEASURED-CLEAN` without
it** — a block whose witness was never shown to move renders as `WITNESS-DEAD`, not clean. This is §0 made
structural rather than remembered, and it is the single check that would have prevented §20. Confirmed by
the operator as a hard gate, not advisory, accepting that it will occasionally look pedantic.

Rows also carry the provenance label (`[SILICON]` / `[SIM]` / `[INFERRED]`), the run directory that
established the claim, and the date.

### 5.3 Day-one contents

| block | status | note |
|---|---|---|
| Bit_Packetizer, scrambler | `UNTESTED` | — |
| QPSK_Modulator, TX RRC | `UNTESTED` | → TX-INT |
| Transmitter output (TXCAP) | `INSTRUMENTED` | → MEASURE — **critical path** |
| AGC out | `MEASURED-DEVIATES` | `[SILICON]` 100.0 → 50.0 % golden, multitap 08:20 |
| RRC receive filter out | `UNTESTED` | → RX-FE |
| postSymbolSync | `MEASURED-DEVIATES` | `[SILICON]` 99.7 → 48.0 % |
| Coarse freq compensator | `UNTESTED` | → RX-FE |
| postCarrierSync | `MEASURED-DEVIATES` | `[SILICON]` 100.0 → 47.4 % |
| Preamble delay FIFO | `MEASURED-CLEAN` | `[SILICON]` displacement/push-on-full falsified 08-30 |
| Constellation (demod in) | `MEASURED-DEVIATES` | `[SILICON]` 99.7 → 46.2 % |
| Demod slice/serialise | `INSTRUMENTED` | DEMODCAP → MEASURE |
| FEC start / Viterbi reset | `MEASURED-CLEAN` | `[SILICON]` 1.0000 per frame through 801k errors |
| BIST comparator | `MEASURED-CLEAN` | `[SILICON]` 120-bit window characterised (§5) |
| §20 per-stage claims | `WITHDRAWN` | dead counters (§22) |

---

## 6. Execution order

Forced by one fact: the FINAL image (`0f203cf887d3`) is on 148 now, and the first build-agent flash
destroys it. No-flash work therefore runs first.

1. **Governor** creates `chain.json` and populates it from the results in §2, including the four
   `MEASURED-DEVIATES` rows. Not yet done — the file does not exist at the time of writing; §2 records the
   measurements, not the artefact.
2. **MEASURE takes the rig** — TXCAP and DEMODCAP capture-constancy on the current image. Zero flash cost,
   and given §2 this is now the campaign's critical path: it tests the transmitter directly.
3. **TX-INT and RX-FE build in parallel** (hdl-dev-2, nemo), ~50 min, touching no hardware; they sim-gate
   and run their in-sim positive control while MEASURE holds the rig.
4. **They queue for the rig in completion order.** TX-INT has priority over RX-FE given §2.

---

## 7. Arbiter validation — before any worker runs

The arbiter gets its own positive control. An exclusion mechanism that has never been observed to exclude
is exactly a counter that has never been seen to increment.

Two throwaway agents contend on a no-op cycle; the governor verifies:

- one acquires and one waits — **not both acquire**;
- the waiter honours `RIG_HALT` when set by hand;
- a killed holder leaves a stale lock that is **reported, not stolen**;
- release removes `RIG_MUTEX.d`, `RIG_LOCK` and `SENTINEL_STOP`, and the sentinel returns.

**If the mutex cannot be shown to exclude, no worker runs.**

---

## 8. Error handling

| event | response |
|---|---|
| Flash fails after touching the board | Rollback, write `RIG_HALT`, release, report. **No retry.** |
| Flash refused at precondition (nothing staged) | Not a failed flash; fix the invocation and proceed. |
| Sim gate or positive control fails | No flash. Block marked `WITNESS-DEAD`. |
| Agent crashes holding the rig | Sweep writes `RIG_HALT`, verifies the board, alerts. |
| Agent crashes not holding the rig | Marked dead, block requeued as a fresh agent. |
| Two agents claim the rig | Impossible by construction; if observed, halt and treat the arbiter as broken. |
| Anything ambiguous | Governor stops and asks the operator rather than guessing. |

**146 is never flashed or touched**, except by the standard gated restore.

---

## 9. Testing

- **Arbiter dry-run** (§7) before any worker.
- **Per-instrument**: sim gate, sim positive control, silicon positive control.
- **Cross-validation**: every silicon claim checked against `cap_in`/`cap_deint`/`cap_out`, stable across
  every run this week and serving as the reference witness.
- **Additive images** let a later agent re-measure an earlier agent's block, so disagreement between two
  independently built images is detectable — the check that exposed the dead counters.

---

## 10. Out of scope

- The header discrepancy (closed, §5) and the start-pulse hypothesis (dead, §8). Neither is reopened.
- Any change to 146.
- BD-level changes: all instruments are source-only resynth (no MATLAB regeneration). The `beat_ila` in the
  image probes the byte plane, not the DSP chain, and repointing it is out of scope.
- Fixing the beat. This campaign locates the source; remediation is a separate effort.
