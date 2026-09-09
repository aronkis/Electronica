# Overnight link investigation — 2026-07-30

Goal: reduce delivered PER < 1% on the R3 reverse link. This is a consolidated,
honest summary of the overnight autonomous investigation. Every number here is on the
**reliable metric** (see below), not the earlier framelog headline.

## 0. The metric was wrong; here is the right one

The framelog "headline PER" (errored records / total) and everything derived from
`reg_packets` (0x104) are **unreliable**: `reg_packets` is an async register snapshot,
not a per-packet tag, and the multi-drain logs ~5 records per real error event. This
inflated the "residual" ~5×.

**Reliable metric:** gaps in the delivered TX sequence number (`host_seq` on CRC-clean
frames — dense, monotonic, zero aliasing). A missing `host_seq` = a genuinely
undelivered packet.

## 1. True operational PER and its taxonomy (M32, +20k off-null)

| window | delivered PER |
|---|---|
| overall (60 s capture) | 8.25% |
| first ~13 s (bring-up transient) | ~22% |
| **steady-state (t>15 s) = operational** | **4.19%** |

- **Bring-up transient** (~half the headline): 3 radio-settling outages (~1 s each) at
  fixed times 7.9/9.7/11.5 s, reproduced across all captures, then clean. A one-time
  bring-up cost (initial ADRV9002 cals), **not** steady-state. The capture's
  framelog-rotate didn't wait long enough to exclude it. Fix: analyze t>15 s only.
- **Steady-state 4.19%** (n=1 per config; arm quality is the dominant run-to-run
  confound — treat ±1% as noise) splits into:
  - **~2% "singles" — host/DMA boundary loss (CONFIRMED).** 84% `host_seq=0` (never
    captured), autocorrelates at lag = M. Root cause: RX DMA `CONFIG.CYCLIC 0` +
    `SYNC_TRANSFER_START 1` — after each transfer the host must reset+resubmit the
    single S2MM engine, and a late resubmit **misses the next frame sync** → ~1 frame
    lost per transfer boundary. Architectural — host reorder does NOT fix it (tested).
  - **~2% "bursts" — ATTRIBUTED by the internal-loopback control (2026-07-31).** Ran
    `qpsk_tun -G -e -M 32` in internal loopback (`rx_input_select=0`, byte src) on 146
    = the **same modem+DMA path with NO RF channel**, incrementing `tx_seq` (verified:
    RX `host_seq` starts at 0 = echo frames, not ROM). The bursts split into two:
    - **Mid-bursts (5–100 frames) = PHY / RF-channel.** Loopback steady (excl.
      dropouts) has **0**; air steady has ~35. The RF channel is the only difference →
      these are bursty reception errors (fades/glitches). Fix: robust estimator / RF /
      ARQ. NOT `CYCLIC=1`.
    - **Big ~1 s dropouts (>100 frames) = ONE-TIME RF-ENABLE-LOCKED CHIP WARMUP.**
      Root-caused (2026-07-31): a cluster of 3 ~1250-frame dropouts ~1.8 s apart that
      fires **~30–35 s after RF-enable/arm, once**, then never recurs. NOT tracking
      cals (persists with agc/bbdc/rfdc/quadrature/rssi all disabled). NOT echo/host-
      locked — a 45 s pre-echo wait makes it fire during the wait and the echo window
      is **clean (0 dropouts, 0.40 %)**. **Fix: wait ~40 s after arm before using the
      link** (or lengthen the capture settle before the framelog rotate) — no rebuild,
      no cal change. This is what the air "bring-up transient" actually was (the
      capture rotate at ~10–20 s post-arm was too early to exclude the ~30–35 s warmup).
    Caveats: loopback is CFO=0 (air was +20k off-null); echo's tight host loop differs
    from the tun daemon (so it under-shows the DMA-boundary singles — see above).

## 2. Root-cause efforts ("root-cause both")

### Effort 1 — carrier-loop tuning (runtime, no rebuild) — MARGINAL
- **loop_gain AXI regs 0x170-0x184 are LIVE** on the deployed LEAN image (confirmed:
  cs_prop=300 → golden 96.7→81.3%, BIST 480→14624/s). Runtime-tunable, no rebuild.
- Best config: **`cfo_threshold`(0x184)=0** → ROM golden 96.7→99.3%, BIST 480→268/s
  (halved). `cs_prop`(0x170)=24-49 also good; higher `cs_prop` wedges.
- Byte-mode validation: steady PER 4.19% → 3.74%, **rstcs=0 (safe, no reset storm)**.
  But the gain is ~0.5% and within single-run arm-quality variance. **Carrier tuning
  does NOT approach <1%.** Kept as a runtime `LOOP_POKE="0x184=0"` candidate, not committed.

### Effort 2 — structural DMA fix — SCOPED, needs supervised rebuild
- Clean fix: **`CONFIG.CYCLIC 1` on `axi_adrv9001_rx1_dma`** (system_bd.tcl) so the
  engine auto-restarts (no reset/sync race) → eliminates the ~2% boundary loss.
- Cost: one-line HDL change + **full bitstream rebuild** (Vivado composite, ~hours) +
  redeploy, plus a host RX rewrite to cyclic ring-buffer completion semantics. **Not
  safe to deploy a new bitstream to the remote boards unsupervised** (brick risk) —
  prepared for your go.

### Wedge / off-null — NOT off-null-fixable, arm-quality-dependent
- Wedges (spontaneous loss-of-lock) are the dominant **bring-up transient** loss (the
  ~1 s outages); in **steady state on a clean arm they are absent** (byte captures'
  steady max burst was ~34 frames = ~27 ms, not 1 s).
- Wedge-rate vs RX off-null (ROM, 60 s/pt): **flat ~3/min from +20k to +320k**
  (golden 94-95%; +80k blip = arm-quality). Off-null margin does NOT reduce wedges →
  they are **not** dead-zone re-entry. These sweep arms were semi-degraded
  (~3900 BIST/s vs a clean arm's 480), so the wedge/PHY-floor tracks **arm quality**
  (the degraded-arm lottery / ARMCAUSE), which no off-null or loop-gain setting fixes.
- Deployable takeaway: off-null stays at +20k (more doesn't help); the lever for the
  PHY floor is arm-quality reliability, already largely addressed in bring-up.

## 3. Recommendation

Every path to <1% needs supervised or non-trivial work — no further host-only
autonomous win exists beyond the marginal `cfo_threshold=0`:

- **Carrier tuning** — marginal (~0.5%), does not approach <1%.
- **~2% DMA boundary** — root fix is `CONFIG.CYCLIC 1` + host ring rewrite +
  **bitstream rebuild** (supervised; brick risk unsupervised).
- **~2% bursts — UNATTRIBUTED (host/DMA vs PHY).** The framelog cannot resolve it;
  needs the byte-mode internal-loopback capture (above). Note: no TX power headroom
  (verified: 148 TX `hardwaregain=0` dB is the rail — write +6 rejected, −10 accepted),
  so if it proves PHY, RF power isn't the lever.
- **ARQ** — **NOT a simple enable** for the two-radio link. The in-process ARQ is
  meaningless across two radios (qpsk_tun.c:1524); it replays a *local* `tx_hist`, but
  the board that detects a loss isn't the sender. Reaching <1% via retransmit needs a
  **new cross-link NAK protocol** (RX seq gap → NAK over reverse link → peer
  retransmits from `tx_hist`) — an implementation, not a tune. Not attempted
  autonomously. **Cheap measurement first:** `-A` (`arq_force`) forces the existing
  ARQ on in a single-process loopback, which measures what retransmit *would* buy
  before committing to the protocol.

The 4.19% steady is now attributed (internal-loopback control):
- **~2% DMA-boundary singles → `CONFIG.CYCLIC 1` rebuild** (host-side, HDL config +
  ring rewrite). Fixes the dominant steady component.
- **~1% mid-bursts (5–100) → PHY / RF-channel** — robust estimator / RF-path / ARQ.
- **Big ~1 s dropouts → modem cal** (channel-independent, appears in loopback) —
  investigate the ADRV9002 tracking-cal schedule; largely a one-time-per-arm cost.

**`CYCLIC=1` is more than a flag flip** (patch prepared in `two_jup/cyclic_dma_patch/`,
grounded in the axi_dmac RTL): simple (non-SG) cyclic mode raises **no completion IRQ
and never sets `DMAC_TRANSFER_DONE`** (DMA_SG_TRANSFER=0 in this build), so the host
cannot use hardware completion — it must detect fresh frames by **seq-number
monotonicity** and handle ring-overwrite/overrun (seq jump ≥ ring length). A leftover
`rx_done()` gate would hang RX. Good news: the `CYCLIC=1` bitstream is **backward-
compatible** (permissive), so a `QPSK_RX_CYCLIC` env-flag enables a staged rollout.
Expect an orders-of-magnitude drop in the boundary singles, not a guaranteed zero.

Suggested order:
1. `CONFIG.CYCLIC 1` rebuild + host ring rewrite (see `cyclic_dma_patch/`) — kills the
   ~2% DMA boundary at the root (your go; brick risk unsupervised). Gets steady ~4%→~2%.
   Free interim mitigation: **wait ~40 s after arm** to skip the chip-warmup dropout cluster.
2. For the remaining ~1% PHY mid-bursts + the modem-cal dropouts: robust estimator /
   cal-schedule tuning, or a cross-link NAK-ARQ (host) to absorb both. To *measure*
   what ARQ would buy first, force `-A`/`arq_force` in single-process loopback.
3. `cfo_threshold=0` as a free runtime tweak (safe, ~0.5%, within noise) — optional.

**Confidence:** the DMA-boundary half is solid (lag-M autocorr contrast, n=1324). The
burst attribution is now from a **clean control** (loopback removes RF: mid-bursts
vanish, modem dropouts persist), not from re-reading one capture. Caveats: loopback
CFO=0 vs air +20k; echo's tight loop under-shows the workload-sensitive singles. All
air numbers n=1/config; arm quality a dominant confound.

## Artifacts / tooling added this session
- `carrier_loop_sweep.sh` — runtime loop-gain sweep in ROM (golden/BIST/cfc/rstcs).
- `wedge_offnull_sweep.sh` — wedge-rate vs RX off-null.
- `capture_r3.sh` — `LOOP_POKE="0x184=0 ..."` hook (pokes loop regs after wedge-check).
- `bringup_r2r3.sh` — `RXM` env (override -M), `LO_B_RX` env (RX off-null).
- Captures under `r3cap/` (residual_*, resid_M16/M64, cfo0_M32, fix_M32_v1).
- Full ledger: `.superpowers/sdd/progress.md`.
