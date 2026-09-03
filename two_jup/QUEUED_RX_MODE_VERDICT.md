# Queued-request RX mode (QPSK_RX_QUEUED=1) — separately shippable host-only change

**Verdict (2026-08-27): VALIDATED on the full forward protocol. Forward
delivered PER 13.93/13.98 % → 8.73/8.89 % (CP95UL 14.16/14.20 % → 8.92/9.08 %),
one env-var change on the RX daemon, no flash, no fabric change. Reverse is
not expected to move (reverse loss is signal-level, `ERROR_SOURCES_SIM_REPRO.md` E7).**

## What it is

`qpsk_tun` already implements two multi-frame RX modes on the CURRENT
bitstream: the deployed default (`QPSK_RX_QUEUED=0`, "reset-per-transfer":
after every 16-frame S2MM transfer the host resets the DMAC engine, zeroes
the landing area and re-submits; the engine captures nothing in between) and
the queued mode (`QPSK_RX_QUEUED=1`: the axi_dmac's native one-request-ahead
queue keeps the next transfer armed in hardware; no host action at the
boundary). `two_jup/bringup_r2r3.sh` passes it as `RXQ` (default 0).

## Measurement (same discipline as the baseline)

Protocol: `GATE_DIR=A capture_r3.sh A -d 68 -k` (forward saturated
`qpsk_perf` 15 Mbit, per-frame framelog on 148), scored with
`accept_analyze.py` (wedge-aware live windows, drops in the denominator,
Clopper–Pearson 95 % upper). Image fe5bd8a4fe19 (BEATFIX v3, fixctl=3) on
148, v_endh on 146, +20 kHz forward LO default, same afternoon.

| mode | leg | live frames | PER | CP95UL | bins 1 / 2 / 3-4 / 5-20 |
|---|---|---|---|---|---|
| RXQ=0 (default) | r1 | 88,882 | 13.975 % | 14.204 % | 3019 / 1851 / 1635 / 59 |
| RXQ=0 | r2 | 89,993 | 13.927 % | 14.155 % | 7408 / 1937 / 291 / 27 |
| RXQ=0 | r3 | — | UNUSABLE (wedged, live 14 s/45 s) | | |
| **RXQ=1** | r1 | — | UNUSABLE (bring-up healthy at 951 f/s / 92 % CRC, then MID_CAPTURE_WEDGE 12 s into saturating traffic: delivery flatlined, `dma_rx_ok` frozen — the known delivery-wedge class) | | |
| **RXQ=1** | r2 | 82,984 | **8.887 %** | **9.083 %** | 3587 / 1538 / 98 / 35 |
| **RXQ=1** | r3 | 84,301 | **8.732 %** | **8.924 %** | 3647 / 1523 / 115 / 30 |
| (discriminator legs, same protocol) RXQ=1 | — | 91,868 | 8.724 % | 8.909 % | 3907 / 1714 / 107 / 29 |
| RXQ=1 + QPSK_RX_AREAS=4 | — | 90,015 | 8.750 % | 8.936 % | 3832 / 1639 / 124 / 37 |

Four queued-mode legs (~349k live frames) sit in 8.72–8.89 %; two reset-mode
legs (~179k) in 13.93–13.98 %. One leg in each set wedged (the known hourly
delivery-wedge class), i.e. no wedge-rate difference is visible at this
sample size (1/3 vs 1/3). Queued-mode watchdog re-arms during the legs: 0.

## Mechanism confirmation — the comb does NOT thin; each event gets smaller

Framelog CRC-fail cadence (live window, events = clusters of ≤2 records):

| mode | events/s | inter-event median | share in 12–14 ms | 3–4-frame holes per leg |
|---|---|---|---|---|
| RXQ=0 | 75.6 / 74.1 | 13.10 / 13.65 ms | 45 / 49 % | 1635 / 291 |
| RXQ=1 | 77.8 / 77.2 | 12.85 / 12.85 ms | 50 / 48 % | 98 / 115 |

The once-per-S2MM-transfer signature (12.85 ms = 16 frames at −M16; 26 ms
= 32 frames at −M32 on the reverse -M32 logs; the earlier "8-frame comb"
was a half-period artefact from counting doubles) is UNCHANGED in event
rate. What queued mode removes is the host-side part of each boundary
gap: the multi-frame holes (3–4 and 5–20 bins) collapse and the loss per
event drops to ~1–2 frames. Live 0x1B0 (ByteRxFifo overflow = dropped
words): ≈0.8–0.9 words per transfer in queued mode (190 words / 202–237
transfers), i.e. the residual gap is just over the 64-word (0.25 ms)
cover; in reset mode it is longer (bigger holes). So: **two stacked gap
sources at every boundary — host re-arm (removed by queued mode, ≈5.1 pp)
and a residual axi_dmac-internal transfer-switch gap of ≈0.25–0.3 ms
(remains, ≈8.8 pp)**. Whether the deepened ByteRxFifo removes the
residual is exactly what the FIFO A/B measures; the two fixes attack the
same boundary from opposite ends and their gains must NOT be assumed
additive.

## Cost / safety review

- No fabric change; same bitstream; host CPU and memory unchanged
  (2 areas × 16 slots; the pump naps identically).
- Why it was not the default: no recorded reason — a conservatism default
  when the mode was added ("legacy path remains the fallback"); commit
  e6fa5f0 (2026-08-11) already credited it with removing the "~2 % DMA
  boundary" loss, and the entire 08-12 acceptance/CP1 campaign ran in it.
- Error containment / descriptor lifetime: one request queued ahead in the
  regmap, handed over at SOT; each request still gates on the frame-sync
  tuser; carve_zero-before-submit keeps the "valid CRC = fresh slice"
  invariant. Unchanged vs reset mode.
- Wedge recovery: queued mode has its own no-progress watchdog (3 s engine /
  10 s delivery) that re-arms via a full reset — it degrades to the legacy
  behaviour rather than stalling. Fired 0 times in today's five queued
  legs; on 08-12 it fired once per run at bring-up before frames arrive
  (benign).
- The 08-12 wedge fix (drain budget, `QPSK_RX_DRAIN_BUDGET`, "0/3 vs 6/7
  wedges") is implemented in the queued pump; the hourly sentinel wedges of
  08-25/26 all happened in reset mode, so queued mode is not implicated in
  that class. Today: 1 wedge in 3 legs in each mode.
- 146 bidirectional collapse (H-5b): one queued-mode bidirectional soak
  attempt is running; result appended below when it lands.

## Recommendation

Ship `RXQ=1` as the bring-up default (`two_jup/bringup_r2r3.sh`: change
`QPSK_RX_QUEUED=${RXQ:-0}` → `${RXQ:-1}`), independently of the FIFO image.
It is a one-line, host-only, reversible change with a measured −5.1 pp on
the forward leg and no observed downside. The FIFO A/B runs on RXQ=0 first
(to measure the FIFO alone), then RXQ=1 + FIFO for additivity.

## Bidirectional interaction (appended 13:2x)

`RXQ=1 GATE_DIR=A GATE_TRIES=12 soak_bidir.sh A -d 200 -k` (both daemons
queued; simultaneous saturating qpsk_perf both ways): bring-up healthy
(949 f/s, 91 % CRC), then **MID_CAPTURE_WEDGE 12 s into traffic**, both
directions unusable — identical to the 3/3 reset-mode attempts of
08-25/26 (≤15 s to dead). Queued mode neither fixes nor worsens the 146
bidirectional collapse (H-5b); that class is mode-independent and stays
open. Watchdog re-arms on both boards: 0 (the collapse is not an engine
no-progress event the daemon can see, consistent with the host-delivery
hypothesis).

## Shipped

`two_jup/bringup_r2r3.sh`: `QPSK_RX_QUEUED=${RXQ:-1}` (was `:-0`), with an
in-line note. Reversible with `RXQ=0`. The FIFO A/B's "FIFO-alone" arm
passes `RXQ=0` explicitly so it measures the image change against the
13.9 % reset-mode baseline; a second arm at the new default measures the
combination.

## Addendum 2026-08-28

Reverse under the queued default: 1.994 % at the old +2.5 kHz LO point and
**1.391 %** at the new +40 kHz default (sweep in `SINGLES_CAMPAIGN.md`);
under simultaneous bidirectional load: reverse 1.79 %, forward 8.7–10.4 %,
no collapse (N=2, guarded single-actor protocol). Queued mode remains the
standing default; it is the host half of the E9 fix, the fabric half (FIFO)
is not yet validated on silicon.
