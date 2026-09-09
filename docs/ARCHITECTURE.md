# ARCHITECTURE — how the QPSK K5 Jupiter modem works

The one place to build a mental model of the modem before you read code. For the
operator procedure see [BRINGUP.md](BRINGUP.md); to build the image
[BUILD.md](BUILD.md); to debug a live link [DEBUGGING.md](DEBUGGING.md); for the
jargon [GLOSSARY.md](GLOSSARY.md).

## What it is

A bidirectional FDD RF link between two ADALM-Jupiter (ADRV9002) SDRs. Each board
runs a 240 ksym π/4-Gray **QPSK** modem with a rate-1/2 **K=5 convolutional FEC**
and an **in-fabric byte-DMA data plane** that carries arbitrary IP traffic over a
Linux `tun0` interface. The whole modem is generated from a MATLAB/Simulink model
through HDL Coder into a Zynq-UltraScale+ `BOOT.BIN`.

- **Board A** = `10.0.0.148`, **Board B** = `10.0.0.146` (wired management LAN).
- **FDD "quiet pair":** forward `146→148` @ 2.00 GHz, reverse `148→146` @ 1.90 GHz
  (dodges 148's 2.10 GHz Tx-LO leakage — board-specific, see PORTING.md).
- **SSI rate** 1.92 MHz, **8 samples/symbol** ⇒ true **240 ksym**.

## The signal chain, end to end

```
   HOST (userspace qpsk_tun)                         AIR                    HOST
   IP packet on tun0                                                   IP packet on tun0
        │                                                                     ▲
        ▼   1 IP pkt = 1×128 B frame (MTU 116)                                │
   ┌─────────────┐   byte-DMA    ┌──────────────── FPGA FABRIC ─────────────┐ │
   │ frame + CRC │──64b AXIS────▶│ TxRxComposite (the modem IP, 0x9D000000) │ │
   └─────────────┘               │                                          │ │
                                 │  TX:  bytes → K=5 encode → interleave →   │ │
                                 │       π/4 QPSK map → sqrt-RRC ×8 → DAC ───┼─┼──▶ ADRV9002 Tx → RF
                                 │                                          │ │
   RF ──▶ ADRV9002 Rx ───────────┼──▶ RX:  AGC → coarse freq comp (CFC) →   │ │
                                 │       symbol sync (SS, Gardner) →         │ │
                                 │       carrier sync (CS, PLL+DDS) →        │ │
                                 │       phase-ambiguity resolve → demod →   │ │
                                 │       deinterleave → K=5 Viterbi (TB=25)→ │ │
                                 │       byte serialize → byte-RX DMA ───────┼─┘
                                 └──────────────────────────────────────────┘
```

**Transmit (host → air):** the host daemon frames each IP packet (128 B + CRC),
pushes it over the Tx byte-DMA as 64-bit AXIS words; in fabric the `ByteBitShifter`
serializes bytes to bits, the **K=5 [35 23] encoder** (rate-1/2, TB via zero tail)
codes them, a **136×16 block interleaver** spreads them, they are π/4-Gray QPSK
mapped, pulse-shaped by a **sqrt-RRC (β=0.5) ×8 interpolator**, and streamed to the
ADRV9002 DAC. A 13-symbol Barker preamble precedes each frame. **No scrambler** —
both Tx and Rx descrambling are bypassed (the air contract is un-whitened; the host
applies an optional software whitener, see GLOSSARY `whitener`).

**Receive (air → host):** the ADRV9002 delivers baseband IQ; the modem runs
**AGC → Coarse Frequency Compensator (CFC) → Symbol Synchronizer (SS, Gardner) →
Carrier Synchronizer (CS, a PLL whose NCO/DDS derotates) → phase-ambiguity
resolver → QPSK demod → 136×16 deinterleave → K=5 Viterbi decode (traceback 25) →
byte serialize → byte-RX DMA** back to the host, which reassembles the IP packet.

## Frame / bit / byte contract

(authoritative: [`k5_240/PACKET_K5.txt`](../k5_240/PACKET_K5.txt))

| Quantity | Value |
|---|---|
| Symbol rate | 240 ksym/s (1.92 MHz SSI ÷ 8 sps) |
| Modulation | π/4-Gray QPSK, sqrt-RRC β=0.5, 8 sps |
| FEC | rate-1/2 K=5 convolutional `poly2trellis(5,[35 23])`, hard Viterbi TB=25 |
| Interleaver | 136×16 block, ping-pong (air frame N carries encode(byte frame N−1)) |
| Preamble | 13-symbol Barker |
| Air frame | 2240 payload bits (2176 coded + 64-bit PN9 filler) = **1133 symbols/frame** |
| Frame time | 1133 sym ÷ 240 ksym ≈ **4.72 ms** (≈211.8 frames/s) |
| Host TX transfer | 35×uint64 = 280 B (one 2240-bit air frame) |
| Host RX packet | 16×uint64 = 128 B (the first 1024 of 1084 decoded info bits) |
| BIST golden | `cap_out = 0x04922282` |

**Asymmetry gotcha:** the TX byte transfer is 280 B (35 words) but the RX packet is
128 B (16 words). They are *not* the same size — the historic "zeros bug" was
`qpsk_tun` using 128 B for both. See `README_BYTE.md` §HW bring-up.

## The byte data plane (why arbitrary IP works)

The modem carries three selectable Tx bit sources, chosen by `tx_data_source`
(reg `0x158`): **0 = in-FPGA pre-coded ROM (BIST)**, **1 = byte-DMA data**. The ROM
source radiates a fixed golden vector for bring-up (readback `cap_out=0x04922282`);
the byte source carries live host bytes. The encoder advances its shift register
**only on `infoValid`** (the anti-zero-stuff gate — the "encoder fix" class), and
resets state at each frame boundary, so per-frame encoding is bit-exact to
`convenc` for arbitrary payloads. Arbitrary data works only because of the
**phase-ambiguity resolver** (below) — without it the RX locks to the wrong QPSK
quadrant for any non-golden payload.

## The two shipped fixes (why the link is stable)

| Fix | Locus | What it does |
|---|---|---|
| **CFO reset-storm fix** ("rxfix") | `commhdlQPSKTxRxParameters.m:45` — `CFOChangeDetectThreshold 0.0015625→0.0125` | Stops a ~52/s false carrier-sync reset (the "reset storm"); `rstcs` 52/s → 0, frame yield 40% → 93.5%. |
| **Phase-ambiguity resolver** | `resolver_lookback_fix.m` (git `8033363`) | Restores preamble-based full-quadrant phase resolution so the byte plane carries **arbitrary** data (99.9% on HW), not just the golden vector. |

Plus the acquisition-hardening (`timing_hardening_overlay`) and the tick
compensation (`p1e_comp_overlay`, below) carried in the current lean image.

## The forward-BER floor: the "tick" (device-side, not fabric)

The forward direction (into board 148) floors at ~1.4e-4 because 148's ADRV9002
**BBDC rejection tracking cal fires every ~1.5 s and inserts 256 samples
(= +32 symbols) into the RX stream delivered to the modem** — a per-unit,
chip-level artifact, present on both of 148's RX paths, absent on 146, and absent
in fabric loopback. Fabric compensates it as far as information theory allows
(`p1e_comp_overlay` recovers the displaced frame; the physically-inserted window
is unrecoverable). Removing it requires an ADI fix or replacing 148 — it is **not**
a fabric bug. Full evidence: [`../two_jup/ESCALATION_ADI.md`](../two_jup/ESCALATION_ADI.md).
Reverse (into the clean 146) meets ~2e-6.

## Register + tap map (code-verified)

Modem regfile base `0x9D000000` (Jupiter/ZynqMP; ZedBoard `0x43C00000`). On-board
access is via the ADRV9002 debug `direct_reg_access` on `iio:device0` — e.g.
`echo 0x150 > .../direct_reg_access; cat .../direct_reg_access`. Offsets below are
cross-checked against `host_app_k5/qpsk_hw.h`, the live pokes in
`two_jup/link_test.sh`/`tap_smoke.sh`/`measure_ber.sh`, and `README_BYTE.md`.

| Offset | R/W | Meaning |
|---|---|---|
| `0x000` | W | Soft reset — pulsed 1→0 at arm (clears modem state). |
| `0x104` | R | `packets_out` — frame counter; **advancing = locked** (liveness). |
| `0x108` | R | `bit_errors` — BIST bit-error counter (locks flat when BIST is correct). |
| `0x10C` | W | `iq_debug_mux` tap selector — `0` AGC-out · `1` post-SS · `2` post-CS · `3` constellation (tap-enabled images; routes to the 2nd rx-DMA channel). |
| `0x110` | W | Carrier-sync (CS) reset — pulsed 1→0 at arm. |
| `0x114` | W | `rx_input_select` — `1` = air, `0` = internal loopback. |
| `0x118` | W | Arm-time datapath select (held `0`; see the `link_test.sh` arm sequence). |
| `0x144` | R | `cap_out` — BIST golden readback; **`0x04922282` = correct**. |
| `0x150` | R | `rstcs` — carrier-reset firing counter; **~0 healthy, growing = reset storm / wrong image**. |
| `0x154` | R | `cfc` — coarse frequency (CFO) estimate. |
| `0x158` | W | `tx_data_source` — `0` = ROM/BIST, `1` = byte-DMA data. |
| `0x15C` | R | `level` — Rx level / ADC forensic. |
| `0x160`/`0x164`/`0x168`/`0x16C` | R | Loop-state pairs (AGC in/out, CS in/out), packed I/Q — tap-enabled images only. |
| `0x170`–`0x1A0` | R | Canary/shadow instrumentation (debug builds only — **stripped in the lean image**). |

**GPIO / arm:** the byte-DMA is armed by `devmem 0x9D300000 32 0x1` (GPIO base
`0x9D300000`); front-end `agpio4-7` writes at arm are **load-bearing** for lock.
The arm sequence also pokes ADRV9002 *chip* registers (`tx-lpc` `0x418/0x458/0x044`)
— those are ADRV9002-internal, not the modem regfile. The canonical, do-not-
paraphrase arm sequence lives in `two_jup/link_test.sh` (`arm_ber`/`coldstart_tun`).

## Where the source lives (kit map)

| Path | Role |
|---|---|
| [`jupiter_240k5_byte/`](../jupiter_240k5_byte/) | **Canonical modem source.** `commhdlQPSKTxRxLoopback.slx` (model, DUT `TxRxComposite`), `assemble_jupiter_240k5_byte.m` (applies donor phases + all overlays — the authoritative build recipe), the overlay `.m` files, gate scripts + stamps, `build_lean_image.sh` (the shipped-image build). See [`README_BYTE.md`](../jupiter_240k5_byte/README_BYTE.md). |
| [`k5_240/`](../k5_240/) | Bit/packet contract (`PACKET_K5.txt`), ideal float receiver (`decode_ref_k5.m`), golden payload (`golden_k5.mat`), K5 AWGN BER curve. |
| [`host_app_k5/`](../host_app_k5/) | Host userspace data plane (`qpsk_tun`, `qpsk_ber`, `qpsk_frame`, `qpsk_seq`, `qpsk_perf`) + the register map header `qpsk_hw.h` + C unit tests. |
| [`two_jup/`](../two_jup/) | Operator + deploy + test kit (`link_test.sh`, `provision.sh`, `deploy_image.sh`, `test.sh`) and the forensics logs (`ERROR_TAXONOMY.md`, `ESCALATION_ADI.md`). |
| [`tests/`](../tests/) | MATLAB `unittest` suite (L1 host-pure / L2 gates / L3 hardware-in-loop). See [TESTING.md](TESTING.md). |

The design flows model → HDL Coder IP core → Vivado (`complete_byte_t8.tcl`) →
`bootgen` → `BOOT.BIN`; the one-command build is `build_lean_image.sh` (see
[BUILD.md](BUILD.md)). Image identities are tracked in [PROVENANCE.md](PROVENANCE.md).
