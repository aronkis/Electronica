# Forward singles (the 8.5% class) — root-cause chain and mechanism

> **PARTIALLY SUPERSEDED (2026-08-22).** The mechanism section below ("inter-transfer
> DMAC backpressure reaching the ByteSerializer") is the campaign's leading hypothesis
> but is NOT established. The `sim_byte_dip` result once cited against it is RETIRED —
> see `two_jup/NETLIST_PROVENANCE.md`. The fix path below (cyclic RX) is being tested
> under `docs/superpowers/plans/2026-08-22-forward-singles.md`.

## 2026-08-12 evening; instrument image live on 148

## The class

Forward (146→148) delivered PER 8.55% (acceptance soaks), dominated by
single-frame CRC failures at ~50/s plus doubles at ~20/s, zero large bursts,
run-to-run repeatability 8.53/8.60/8.53%. Reverse carries the same *shape* at
~20× lower rate (its knife-edge 0.95%).

## The discriminator chain (all measured 2026-08-12, in order)

| step | instrument | result |
|---|---|---|
| 1 | TXLOG on 146 | feeder is a metronome (65,536 submits @1245/s, 43 gaps vs 3,372 events) — TX exonerated |
| 2 | framelog hole census | 3,322/3,372 singles are **delivered-but-corrupt** (crc=0 record in the hole) |
| 3 | `QPSK_RXQ_REREAD` | 0/23,740 re-reads rescue — bytes **stably corrupt in the DMA buffer**, not a torn read |
| 4 | bit-true netlist replay | **12/12 corrupt seqs decode CRC-GOOD** from 148's own captured IQ (`SINGLES_REPLAY.md`) |
| 5 | event cadence | spacing locks to the DMA area period: 13/26 ms at `-M 16`, **25–26/51 ms at `-M 32`** — boundary-locked at both M |
| 6 | `-M 32` rate test | singles rate UNCHANGED (~52/s) — **not** proportional to re-arm count (per-MMIO-disturbance hypothesis falsified); events-per-boundary doubles instead |
| 7 | **CP1 (framestat) comparator** on the new instrument image | on paired CRC-fail slices, **fabric ByteSerializer-output checksum == host checksum 107/117 (91.4%)** (tag-advance 98.3%; chance = 1/65536) |

## The mechanism (consistent with every step)

**Inter-transfer DMAC backpressure reaching the ByteSerializer.** Each RX DMA
transfer covers M frames; between transfers the S2MM engine re-syncs
(`SYNC_TRANSFER_START=1`). The demod chain cannot stall — samples keep
streaming — so when a transfer boundary lands inside a frame's 191-word
delivery burst, words are lost/mangled AT the serializer output (hence CP1's
checksum matches the corrupt host bytes). A boundary landing in the frame's
~50% zero-pad slack is harmless — which sets the rate:

- cadence locks to the area period at any M (steps 5),
- rate is ~constant vs M (more vulnerable window per boundary at larger M
  cancels fewer boundaries — step 6),
- the netlist never reproduces it (the sim's DMA model holds `byte_rx_ready`
  high — step 4),
- 146 shows the same class ~20× rarer (different image build/timing phase
  between burst window and boundary),
- reread can't fix it and the host is blameless (steps 2–3).

## The fix path

**Cyclic mode — no transfer boundaries at all.** `rx_byte_dma` in 148's new
image is CYCLIC-capable (opt-in via FLAGS bit0; `CYCLIC_RXBYTE_OK` in the
build). With cyclic on, `TRANSFER_DONE`/EOT die (DMA_SG_TRANSFER=0), so
qpsk_tun must move to content-based completion — the design already exists:
`two_jup/cyclic_dma_patch/HOST_RING_REWRITE.md` §3 (written against the wrong
IP name, mechanics valid). Next session's work:

1. Implement the host ring (content-based freshness detection) behind
   `QPSK_RX_CYCLIC=1` for the f1536 path.
2. Loopback validation on 148 (CP1 wordcnt + fslog as the oracle: corrupt
   singles should vanish).
3. On-air forward acceptance re-run: predict the ~50/s singles class → ~0,
   forward PER from 8.55% toward the reverse's structure (<1%).
4. If reverse's residual smalls are the same mechanism (shape says yes),
   flash 146 with a cyclic-capable image and repeat — both directions should
   then clear the <1% no-ARQ gate with margin.

## Instrument notes

- `QPSK_FSLOG` (qpsk_tun): drain-path comparator; pop = CHANGED-token write to
  0x1DC (level-gated) — the first run omitted the pop (fixed, c9a10e0/…).
- Eager-path slices are not hooked — good-slice pairing comes only from drain
  leftovers; fine for the CRC-fail question, extend if good-slice coverage is
  ever needed.
- CP1 wordcnt (0x1C0) verified counting at exactly line rate (1243.7 f/s).
- 148 rollback: `/root/BOOT.BIN.64bb2476.bak` on-board + host copies.
