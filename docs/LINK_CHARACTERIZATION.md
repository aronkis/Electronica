# RF Link Characterization (2026-07-19)

First empirical characterization of the two-Jupiter FDD link carrying real IP
over tun0. Image `0de4d5cba0af` (P1E v3), quiet pair 2.00/1.90 GHz, host
whitener ON both ends, MTU 116. Boards A=10.0.0.148, B=10.0.0.146; forward =
B→A (146→148), reverse = A→B. Bundle: `two_jup/hunt/20260719_085438_linkchar`.

## Headline: SSH over the RF link WORKS (RF-SSH-OK)

The item STATUS.md marked "pending" since 2026-07-10 is closed. An interactive
`ssh` from 146→148 over tun0 (ed25519, minimal-KEX, whitener on) completed the
full login — hostname, kernel, uptime, loadavg all returned over the air, both
boards cleanly LOCKED (drstcs=0). The encrypted (high-entropy) SSH stream is
self-whitening and survives where low-entropy ping traffic does not.

## Latency — retires the "~5 ms" assumption with data

Ping, 60 samples/cell, WHITEN=1. The historical ~5 ms RTT figure was an
assumption and is **physically impossible**: one frame serializes in 4.72 ms,
so a round trip is ≥ ~10 ms before any host/DMA overhead. Measured:

| payload | dir | min | avg | max | loss |
|---|---|---|---|---|---|
| -s8 (1 frame)  | fwd | 68.0 | 101.5 | 193.8 | 5.0% |
| -s32 (1 frame) | fwd | 65.9 |  99.2 | 243.0 | 1.7% |
| -s88 (1 frame) | fwd | 65.2 |  94.1 | 153.9 | 5.0% |
| -s200 (2 frame)| fwd | 98.6 | 157.8 | 295.1 | 11.7% |
| -s32 | rev | 64.7 | 99.3 | 289.9 | 6.7% |
| -s88 | rev | 63.9 | 93.7 | 159.7 | 5.0% |

- **RTT floor ~65 ms, average ~95 ms** for 1-frame payloads — ~7× the
  serialization floor, i.e. dominated by host-side DMA-arm + poll/nap timing
  in `qpsk_tun` on both ends, not by the air.
- Symmetric both directions (~94-100 ms avg).
- **Fragmentation doubles the penalty**: -s200 (2 frames) → 158 ms avg,
  11.7% loss (~loss²), confirming the 1-packet-per-frame MTU-116 design.
- **Category: C (sluggish, 100-250 ms p90).** SSH is usable (proven) with
  noticeable lag; fine for transfers and scripted use.

## Throughput — usable ~50 kbit/s, ceiling ~68 kbit/s

qpsk_perf UDP, -l 88 (1 frame/datagram), 20 s/rung, WHITEN=1:

| offered | fwd delivered | fwd loss | rev delivered | rev loss |
|---|---|---|---|---|
| 50 kbit/s  | ~1385 pkt/20s | 2.5% | ~986 pkt/20s | **0.4%** |
| 100 kbit/s | ~1920 pkt/20s | 24%  | ~1009 pkt/20s | 19% |
| 145 kbit/s | ~1926 pkt/20s | 47%  | — | — |
| 180 kbit/s | ~1974 pkt/20s | 56%  | — | — |

- **~50 kbit/s is the reliable UDP goodput** (single-digit % loss both ways;
  reverse is cleaner, 0.4%).
- Delivered rate saturates at ~96-99 pps forward (~68 kbit/s goodput ceiling)
  regardless of offered rate above the knee — the link's real frame yield is
  **not** 1:1 (keepalive frames, tick-episode losses, no ARQ), so the usable
  goodput is well below the 149 kbit/s theoretical (128 B @ 211.8 fps).
- Above ~50-68 kbit/s, offered load past the ceiling is pure loss (no ARQ =
  every excess datagram dropped).

## TCP / SSH guidance

- Single-stream TCP will be fragile: no ARQ means each loss = an RTO, and the
  BDP (~68 kbit/s × ~95 ms ≈ 800 B ≈ a few MSS at advmss 56) is tiny. Use
  UDP or rate-limited transfers.
- For file transfer over SSH, cap the rate: `scp -l 400` (≈50 kbit/s) stays
  under the clean knee. `rto_min 25ms` (already set in `coldstart_tun`) keeps
  TCP from stalling 200 ms per loss.
- Interactive SSH works; expect ~95 ms echo latency (Category C).

## How to reproduce

```bash
cd two_jup
./link_test.sh preflight                 # readiness, no arm
./link_test.sh ssh  -w                    # RF-SSH-OK
./link_test.sh lat  -w                    # latency matrix -> bundle
./link_test.sh perf -w -k                 # UDP ladder + TCP -> bundle, teardown
```
or `QPSK_HIL=1 matlab -batch "cd tests; runTests('L3')"` for the gated suite.
qpsk_perf is control-free (results log per-board, harvested over the wired
LAN); iperf3 is native on both boards (148: 3.18, 146: 3.9).
