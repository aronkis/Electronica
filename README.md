# QPSK K5 Jupiter Modem

A bidirectional FDD RF link between two ADALM-Jupiter (ADRV9002) SDRs running a
240 ksym QPSK + K=5 FEC modem with a byte-DMA data plane, carrying IP over `tun0`.
The design flows from a MATLAB/Simulink HDL-Coder model to a deployed `BOOT.BIN`.

**Status:** rxfix K5 byte image deployed to both boards; `-B` BER ~1e-4 both
directions on the quiet pair; `rstcs` reset-storm eliminated.

## Start here

| I want to… | Go to |
|---|---|
| Build the image (model → BOOT.BIN) | [`docs/BUILD.md`](docs/BUILD.md) — one command: `jupiter_240k5_byte/build_image.sh` |
| Test the modem (loopback / BIST / real link) | [`docs/TESTING.md`](docs/TESTING.md) — one command: `two_jup/test.sh` |
| Run / bring up the RF link as an operator | [`two_jup/README_LINK_TEST.md`](two_jup/README_LINK_TEST.md) — `two_jup/link_test.sh` |
| Know which image is on which board | [`docs/PROVENANCE.md`](docs/PROVENANCE.md) |
| Understand the modem architecture | [`jupiter_240k5_byte/README_BYTE.md`](jupiter_240k5_byte/README_BYTE.md) |
| See the bit/packet contract | [`k5_240/PACKET_K5.txt`](k5_240/PACKET_K5.txt) |

## The signal chain (one paragraph)

Two Jupiters (A=`10.0.0.148`, B=`10.0.0.146`) run the ADRV9002 `lvds_1p92_mhz` LVDS
profile at 1.92 MHz SSI. The waveform is π/4-Gray **QPSK at 8 samples/symbol = true
240 ksym** (sqrt-RRC β=0.5) carrying a rate-1/2 **K=5 convolutional code
`poly2trellis(5,[35 23])`, hard Viterbi TB=25**, with a 136×16 block interleaver and
scrambler off both ends. A **byte-DMA data plane** (host bytes → in-fabric K=5 encode →
air, and air → K=5 Viterbi → host bytes) carries arbitrary IP traffic. It runs FDD on
the **quiet pair** — forward 2.00 GHz (146→148), reverse 1.90 GHz (148→146) — to dodge
148's 2.10 GHz Tx-LO leakage. Two fixes make it stable: the **CFO reset-storm fix**
(`CFOChangeDetectThreshold 0.0015625→0.0125`, kills a ~52/s false carrier reset) and the
**phase-ambiguity resolver** (`resolver_lookback_fix`, lets the byte plane carry
arbitrary data). Golden BIST readback is `cap_out = 0x04922282`.

## Canonical directories (the keepers)

| Dir | Role |
|---|---|
| [`jupiter_240k5_byte/`](jupiter_240k5_byte/) | **canonical modem source** kit (model, overlays, gates, `build_image.sh`) |
| `jupiter_byte_rxfix_build/` | deployed build output (BOOT.BIN md5 `8d6b82ff…`; gitignored build tree) |
| [`host_app_k5/`](host_app_k5/) | host userspace app (`qpsk_tun` -B/-F/-T/-l/-e, `qpsk_ber`, `qpsk_frame`) + unit tests |
| [`k5_240/`](k5_240/) | bit contract, ideal float receiver, K5 AWGN BER curve |
| [`two_jup/`](two_jup/) | operator + test kit (`link_test.sh`, `test.sh`, `provision.sh`, `deploy_rxfix.sh`) |
| [`docs/`](docs/) | authoritative docs: `BUILD.md`, `TESTING.md`, `PROVENANCE.md` |

## Everything else is archive

This tree accumulated ~160 experimental snapshot directories during development.
They are **archive** — kept for history, not part of the current design. Do not build
or deploy from them. The lineages:

- `composite_*`, `V*`, `cfc_*`, `descr_*`, `diag_*`, `fracdelay*`, `freeze_*`, `cs_*`,
  `phase_ambig_*`, `start_delay_*`, `rx_thr_*` — the **uncoded composite-modem** debug
  era (May 2026) that motivated adding FEC.
- `fec_*` (`fec_dut`, `fec_jupiter*`, `fec_zed*`) — the **K=7 FEC** bring-up saga
  (June 2026), superseded by the K=5 line.
- `zed_*`, `zed_240k5` — the **ZedBoard** branch, retired by the two-Jupiter pivot.
- `jupiter_{t8*,agcfix,asyncclk,cswide,dither,drift,eps*,fir*,ssdither*,msggenrom*,…}` —
  Jupiter single-feature experiments; `jupiter_240k5` is the byteless precursor of the
  canonical `jupiter_240k5_byte`.

Within `two_jup/`, superseded scripts live in `two_jup/archive/`; and
`jupiter_240k5_byte/rtl_sim/` keeps `sim_byte_iq.cpp` + the golden hex as the load-bearing
harness — its many `sim_*.cpp` variants and `*_rxw.txt`/`*_res.txt` files are regenerable
sweep output.

## Quick start

```bash
# BUILD  (host with MATLAB R2025b + Vivado 2025.1; ~2 h, detached)
cd jupiter_240k5_byte && setsid nohup ./build_image.sh > build_image.log 2>&1 </dev/null &

# DEPLOY  (per board; Jupiter has no remote power — flash is size-checked + backed up)
cd ../two_jup
for ip in 10.0.0.148 10.0.0.146; do
  ./deploy_rxfix.sh $ip                                           # flash /boot + reboot (RETURNS IMMEDIATELY)
  until ./anyssh.sh $ip 'echo up' | grep -q up; do sleep 5; done  # wait for the board to reboot back
  ./provision.sh $ip                                              # only on a fresh board (a reflash keeps /root)
done

# TEST  (dev box up to live link)
./test.sh loopback           # Tier A: self-loopback, no RF
./test.sh ber                # Tier B: real BER, both directions
./test.sh link --radios 2    # Tier C: real data, two-board FDD
```

> **Never modify the repo master** `/home/tcollins/dev/qpsk_ai` (read-only ADI donor).
> All work is under `/mnt/onetb/scratch/qpsk_variants/` (git master, local-only).
