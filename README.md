# QPSK K5 Jupiter Modem

A bidirectional FDD RF link between two ADALM-Jupiter (ADRV9002) SDRs running a
240 ksym QPSK + K=5 FEC modem with an in-fabric byte-DMA data plane, carrying IP
over `tun0`. The design flows from a MATLAB/Simulink HDL-Coder model to a deployed
`BOOT.BIN`.

**Status:** shipped image = **lean `dcf5c5fb`** on both boards (a debug-strip of the
P1E-v3 design that keeps every fix + tick compensation). BER on the quiet pair:
**reverse `148→146` ~2e-6 (goal met)**, **forward `146→148` ~1.4e-4** — floored by a
device-side BBDC "tick" on unit 148 (vendor-escalated, not a fabric bug). `rstcs`
reset-storm eliminated. The fabric design is at its engineering limit.

## Start here

| I want to… | Go to |
|---|---|
| **Understand** how the modem works | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (signal chain + register map); FEC/byte internals in [`jupiter_240k5_byte/README_BYTE.md`](jupiter_240k5_byte/README_BYTE.md) |
| **Bring up / operate** the RF link | [`docs/BRINGUP.md`](docs/BRINGUP.md) — `two_jup/link_test.sh` |
| **Debug** a live link | [`docs/DEBUGGING.md`](docs/DEBUGGING.md) — symptom → cause → action |
| **Look up** a term | [`docs/GLOSSARY.md`](docs/GLOSSARY.md) |
| **Build** the image (model → BOOT.BIN) | [`docs/BUILD.md`](docs/BUILD.md) — `jupiter_240k5_byte/build_lean_image.sh` |
| **Deploy** to a fresh pair of boards | [`docs/PORTING.md`](docs/PORTING.md) — `two_jup/deploy_image.sh` |
| **Test** the modem (loopback / BIST / link) | [`docs/TESTING.md`](docs/TESTING.md) — `two_jup/test.sh`, `tests/` |
| Know which **image** is on which board | [`docs/PROVENANCE.md`](docs/PROVENANCE.md) |
| See **link performance** (latency/throughput/SSH) | [`docs/LINK_CHARACTERIZATION.md`](docs/LINK_CHARACTERIZATION.md) |
| See the **bit/packet contract** | [`k5_240/PACKET_K5.txt`](k5_240/PACKET_K5.txt) |
| Read the deep **root-cause logs** | [`two_jup/ERROR_TAXONOMY.md`](two_jup/ERROR_TAXONOMY.md), [`two_jup/ESCALATION_ADI.md`](two_jup/ESCALATION_ADI.md) |

## The signal chain (one paragraph)

Two Jupiters (A=`10.0.0.148`, B=`10.0.0.146`) run the ADRV9002 `lvds_1p92_mhz` LVDS
profile at 1.92 MHz SSI. The waveform is π/4-Gray **QPSK at 8 samples/symbol = true
240 ksym** (sqrt-RRC β=0.5) carrying a rate-1/2 **K=5 convolutional code
`poly2trellis(5,[35 23])`, hard Viterbi TB=25**, with a 136×16 block interleaver and
scrambler off both ends. An **in-fabric byte-DMA data plane** (host bytes → K=5
encode → air, and air → K=5 Viterbi → host bytes) carries arbitrary IP traffic. It
runs FDD on the **quiet pair** — forward 2.00 GHz (146→148), reverse 1.90 GHz
(148→146) — to dodge 148's 2.10 GHz Tx-LO leakage. Golden BIST readback is
`cap_out = 0x04922282`. Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Canonical directories (the keepers)

| Dir | Role |
|---|---|
| [`jupiter_240k5_byte/`](jupiter_240k5_byte/) | **canonical modem source** kit (model, overlays, gates, `build_lean_image.sh`) |
| `jupiter_byte_lean_build/` | deployed build output (BOOT.BIN md5 `dcf5c5fb…`; gitignored build tree) |
| [`host_app_k5/`](host_app_k5/) | host userspace app (`qpsk_tun` -B/-F/-S, `qpsk_ber`, `qpsk_perf`) + the register map `qpsk_hw.h` + unit tests |
| [`k5_240/`](k5_240/) | bit contract (`PACKET_K5.txt`), ideal float receiver, K5 AWGN BER curve |
| [`two_jup/`](two_jup/) | operator + test kit (`link_test.sh`, `test.sh`, `provision.sh`, `deploy_image.sh`) + forensics logs |
| [`docs/`](docs/) | authoritative docs (ARCHITECTURE, BRINGUP, DEBUGGING, BUILD, TESTING, PORTING, PROVENANCE, GLOSSARY) |
| [`tests/`](tests/) | MATLAB `unittest` suite (L1 host-pure / L2 gates / L3 hardware-in-loop) |

Within `two_jup/`, superseded campaign scripts live in
[`two_jup/archive/`](two_jup/archive/) (indexed by its README);
`jupiter_240k5_byte/rtl_sim/` keeps `sim_byte_iq.cpp` + the golden hex as the
load-bearing harness (its many `sim_*.cpp` variants + `*.txt` sweep output are
regenerable and gitignored).

## Quick start

```bash
# BUILD  (host with MATLAB R2025b + Vivado 2025.1; ~2 h, detached). See docs/BUILD.md.
cd jupiter_240k5_byte && setsid nohup ./build_lean_image.sh > build_lean.log 2>&1 </dev/null &

# DEPLOY  (per board; Jupiter has no remote power — flash is size-checked + backed up)
cd ../two_jup
./deploy_image.sh 10.0.0.148        # flash /boot, reboot, wait for the board back
./deploy_image.sh 10.0.0.146        # one board at a time
./provision.sh 10.0.0.148 && ./provision.sh 10.0.0.146   # host app + profile + watchdog

# TEST  (dev box up to live link). See docs/TESTING.md.
./test.sh loopback           # Tier A: self-loopback, no RF
./test.sh bist               # Tier B: on-chip BIST (cap_out = 0x04922282)
./link_test.sh ber -d 90     # Tier C: real OTA BER, both directions
```

Bringing up a **different** pair of boards? See [`docs/PORTING.md`](docs/PORTING.md).

> **Never modify the read-only ADI donor tree** `/home/tcollins/dev/qpsk_ai`. All
> work is in this repo (`/mnt/onetb/scratch/qpsk-jupiter-modem`). The ~160
> experimental snapshot directories from development are **not in this repo** (they
> stay on local disk, gitignored) — do not build or deploy from them.
