# Design: eliminating the RX DMA transfer-boundary loss

## Problem (established)

The RX byte path loses ~1 frame per K-packet DMA transfer (~2% PER at `-M 32`; the
miss-train autocorrelates at lag = M, n=1324, peak 0.60; losses are `host_seq=0`
never-captured frames).

Mechanism: `axi_adrv9001_rx1_dma` is a single S2MM engine with
`SYNC_TRANSFER_START 1`. The current driver (`rx_arm`, qpsk_tun.c) does, per
transfer:

```
transfer N completes ──► host observes done ──► CONTROL 0/1 (reset)
                         ──► program regs ──► SUBMIT ──► wait frame-sync tuser
```

The whole host round-trip sits between "engine finished N" and "engine armed for
N+1". The byte source has **no backpressure** (`DMA_TYPE_SRC 2` = fifo-write
interface, no tready), so any frame that starts during that window is simply not
captured. A late resubmit misses the next `SYNC_TRANSFER_START` marker → the
engine waits a further full frame.

Prior attempt: `CONFIG.CYCLIC 1` (engine auto-restart). The rebuilt bitstream
**broke byte delivery entirely** (0 rx_ok even in legacy mode) and also regressed
the forward air link; cause unresolved (the flag itself vs. fresh-build delta —
the deployed image `64bb247` was never reproducible bit-for-bit from this tree).
Lesson applied below: prefer designs that avoid a blind bitstream swap, and
validate every hardware-behavior claim against the IP source.

## What the axi_dmac ACTUALLY supports (verified in this build's RTL)

1. **One-ahead request queueing is native.** `up_dma_req_valid` is set by SUBMIT
   and cleared on **start-of-transfer** (`axi_dmac_regmap_request.v:177-179`),
   not end. So while transfer N is in flight, the host may program
   DEST/LENGTH and SUBMIT N+1; the request is latched in the regmap and handed
   to the transfer core the moment it can accept it — the N→N+1 handoff becomes
   a few fabric cycles, with **no host action in the gap**.
2. **Every queued request still frame-syncs.** `request_sync_transfer_start`
   is hard-tied 1 when the IP is built with `SYNC_TRANSFER_START`
   (`axi_dmac_regmap_request.v:161`) — per-request, not per-enable. Alignment
   is preserved without the reset.
3. **Completions are ID-tracked 4 deep.** `TRANSFER_ID` (0x404) names the next
   submission; `TRANSFER_DONE` (0x428) is a per-ID bitmap
   (`up_transfer_done_bitmap`, regmap_request.v:375-377) — designed precisely
   for multiple outstanding transfers.
4. The per-transfer `CONTROL 0/1` reset in the current driver is **not a
   documented IP requirement** — the comment dates to the original K5 port
   (commit a2a41b3) and mirrors the older single-shot capture tool. (It may
   still encode an undocumented wedge — treat as a validation risk, below.)

## Option A (RECOMMENDED): queued-request driver — host-only, no bitstream change

Replace reset-per-transfer with a standing two-slot pipeline:

```
arm:    reset once; program area0; SUBMIT (ID=0); program area1; SUBMIT (ID=1)
steady: DONE[i] set ──► drain area i ──► program area i (next address); SUBMIT
        (engine is ALREADY running transfer i+1; the new request queues behind it)
```

- The engine always has the next transfer pre-queued: when N ends, the core
  latches N+1 immediately and waits (armed) for the next frame-sync marker.
  The loss window collapses from a host round-trip (~100s of µs incl. nap
  jitter) to the hardware request-handoff (cycles).
- Frame-sync alignment per transfer is retained (fact 2) — this keeps the
  existing "transfer starts on a frame boundary" invariant the eager-scan
  relies on, unlike CYCLIC which changed the data-layout contract.
- Completion tracking: match DONE bitmap bits to submitted IDs (mod-4);
  `carve_zero` before each re-submit keeps the "valid CRC = fresh" invariant
  (unlike CYCLIC, nothing about content freshness changes).
- Driver shape: `rx_arm_queued()` (once) + a small change in `rx_pump_frame`'s
  completion branch: on DONE[i], **first** program+SUBMIT the NEXT transfer for
  area i (2-area ping-pong as today), **then** hand area i to the drainer.
  The eager-scan path is unchanged.

Why this is the strongest option here:
- **Zero bitstream risk** — runs on the CURRENT deployed image (and on the
  rollback image on 146). No flash, no Vivado, deployable today.
- **Unit-testable off-hardware** — test_k5's fake-DMA regfile can model the
  SOT-clears-SUBMIT semantics and assert "next transfer already queued when
  DONE observed" (the exact property that kills the loss).
- **Falsifiable on-hardware in minutes** — the lag-M autocorrelation of the
  miss-train is a sharp pass/fail: peak ~0.6 today → noise if fixed.

Risks / open questions:
- The historical reset may mask an undocumented wedge (e.g. a stuck partial
  transfer). Mitigation: keep the reset path as fallback (`QPSK_RX_QUEUED=0`),
  auto-fall-back on a watchdog (no DONE progress for >2 frame periods →
  reset+rearm, count it).
- SUBMIT while running is exercised silicon on the TX side (tx_send already
  queues by ID without reset — same regfile logic), which derisks the RX use.

## Option B: elastic frame FIFO in fabric (drop → delay)

Insert ~2-frame buffering between the modem byte output and the DMA so frames
arriving during any dead window queue instead of drop.

- Because `DMA_TYPE_SRC 2` has no backpressure, this needs either
  (a) a `util_wfifo`-style adapter gated by `fifo_wr_xfer_req`, or
  (b) flipping the DMA source to AXIS (`DMA_TYPE_SRC 1`) + `axis_data_fifo`
      (native tready backpressure; sync via tuser).
- Depth: 2 × 1528 B ≈ 3 KB — one BRAM; fits even the 102%-placer-tight ZU3EG.
- Host completely unchanged. Robust to ANY host latency (covers scheduling
  stalls too, which Option A does not).
- Cost/risk: a BD wiring change + bitstream rebuild — currently the risky part
  (the fresh-build-vs-deployed delta that burned the CYCLIC attempt is still
  unresolved). Do this only after a control build re-establishes a known-good
  fresh baseline.

## Option C: ping-pong dual DMA engines (rx1+rx2 alternating)

A stream switch alternates frames between two S2MM engines; one is always armed.
Rejected: rx2_dma is already claimed by the 0x10C capture tap, the switch adds
real fabric complexity on a tight part, and Options A/B achieve the same window
collapse far cheaper.

## Option D: CYCLIC auto-restart (attempted, shelved)

Broke byte delivery on hardware even in legacy mode; also regressed forward air.
Shelve until a control build (fresh, CYCLIC reverted) isolates flag-vs-build.
If the control build's byte path is ALSO broken, the fresh-build delta — not
CYCLIC — was the culprit, and B/D reopen.

## Verification plan (including in-simulation)

1. **Model the fault in sim first** (ties to the fixed-point/Simulink loop):
   the boundary loss is reproducible in the RTL/netlist sim by gating
   `adc_valid` low for the rearm window every K frames (iq_perturb-style valid
   dropout) — confirm 1-frame-per-K loss appears; then confirm the fix's
   invariant (Option A: no valid-gap → no loss; Option B: FIFO absorbs).
2. **Unit tests**: extend test_k5's fake DMA with SOT-clears-SUBMIT semantics;
   assert next-transfer-queued-before-drain and DONE-ID matching.
3. **Hardware**: byte echo internal loopback (echo_loopback.sh) then air
   capture; pass = gap-based delivered PER singles collapse AND the lag-M
   autocorrelation peak (0.60 today) drops to noise; watchdog fallback count 0.

## Rollout

1. Roll 146 back to the known-good image (pending go).
2. Implement Option A behind `QPSK_RX_QUEUED` (default off), unit-test, then
   validate on hardware (echo loopback → reverse air capture).
3. If A hits the undocumented-wedge risk: control build to re-baseline fresh
   builds, then Option B.
