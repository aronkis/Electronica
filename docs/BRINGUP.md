# MODEM BRINGUP — the two-Jupiter QPSK K5 link, from BOOT.BIN to data

The single operator-facing procedure to bring the deployed modem link up from
cold boards and verify it, incorporating every campaign finding (pi-fix /
PI_GATE, verified-lock acquisition, Rx gain pinning, frequency plan). For
building the image see [BUILD.md](BUILD.md); for the test-tier reference see
[TESTING.md](TESTING.md); image identities in [PROVENANCE.md](PROVENANCE.md).

Boards: **A = 10.0.0.148**, **B = 10.0.0.146** (wired mgmt LAN; all access via
`two_jup/anyssh.sh`, password auth). Boards have **no remote power** — the only
remote recovery is reflash + reboot; treat `/boot/BOOT.BIN` as precious
(size-check >6 MB + backup before any overwrite; the deploy scripts enforce it).

> **Bringing up a DIFFERENT pair of boards** (other IPs / other RF environment)?
> Read [PORTING.md](PORTING.md) first — it is the thin delta over this procedure
> (set `A_IP`/`B_IP`, obtain the image, then re-survey the §2 frequency plan and
> §4 gain for your hardware). The numbers in this doc are specific to boards A/B.

## 0. What should be running

| Item | Value |
|---|---|
| Image | **lean** BOOT.BIN, kit `jupiter_byte_lean_build/` (debug-strip of P1E-v3; current md5 `dcf5c5fb…`, but identity is by BIST golden not md5 — see [PROVENANCE.md](PROVENANCE.md) for the authoritative current image) |
| Interface profile | `lvds_1p92_mhz.{bin,json}` → 1.92 Msps, 8 sps @ 240 ksym |
| Frequency plan | FORWARD 146→148 @ **2.00 GHz**, REVERSE 148→146 @ **1.90 GHz** (quiet pair; survey-confirmed for boards A/B — see §2. **A different pair must re-survey**, PORTING.md) |
| Rx gain | `automatic` during acquisition, then **pin 148's Rx gain** (`spi` mode) post-lock — §4 |
| Host tool | `/root/host_app_k5/qpsk_tun` (built on-board from `host_app_k5/`) |

## 1. Flash + provision (once per image change)

```sh
cd two_jup
# deploy_image.sh: generic flash tool (defaults to the current lean image; pass a
# path or set $BOOT to flash a different one). Backs up /boot -> .pregeneric,
# flashes, reboots, and waits for the board back. Flash ONE at a time.
./deploy_image.sh 10.0.0.148          # board A
./deploy_image.sh 10.0.0.146          # board B (after A confirmed back up)
./provision.sh 10.0.0.148 && ./provision.sh 10.0.0.146
```

(`deploy_pifix.sh` / `deploy_rxfix.sh` / `deploy_tap.sh` are frozen image-specific
variants kept for provenance; `deploy_image.sh` supersedes them for new work.)

Verify: `anyssh.sh <ip> 'md5sum /boot/BOOT.BIN'` matches PROVENANCE; both boards
report the profile files and `qpsk_tun` present (provision does this).

## 2. Arm (per session)

The canonical arm sequence lives in `link_test.sh` (and verbatim copies in
`capture_paired.sh` / `exp_forward.sh`): load the LVDS profile,
ENSM `calibrated`, front-end GPIOs, `tx_a` port, Tx LO + 0 dB attenuation +
`rf_enabled`, Rx LO + `rf_enabled` + `automatic` gain, modem regfile reset,
`0x158=1` (byte Tx), `0x118=0`, `0x114=1` (Rx=air), DAC mux, rstCS pulse,
byte-DMA arm (`devmem 0x9D300000 32 0x1`).

**Frequency plan (final, 2026-07-11 RF survey):** fwd 2.00 GHz / rev 1.90 GHz.
The survey (1.50–2.10 GHz, 60 s -B per carrier, warm, gain-pinned, peer Tx
parked) found every carrier in 1.60–2.05 GHz equivalent (~1.1–1.6e-4 warm on
the forward path); **2.10 GHz is polluted** (1.0e-2 — the historical 148 Tx-LO
leakage band) and **1.50 GHz is weak** (3.0e-3, rssi rails, antenna roll-off).
Forward quality is limited by the 146→148 physical path (148's Rx1 documented
artifact floor + thin link budget: auto gain rails at max, rssi ~17–19 dB),
not by carrier choice. Also ruled out on data: 148-Tx self-interference
(parking its Tx changes nothing), inter-board CFO trim (±6.3 kHz LO offset
splits — no effect), extra QEC/RFDC tracking cals (counterproductive, §2 note).

**Do NOT enable ADRV9002 tracking cals beyond the profile defaults** —
`quadrature_w_poly/fic/rfdc` tracking enabled at arm time mis-converges and
scrambles the constellation past the resolver's one-time lock (proven
2026-07-11: 100% PHASE frames). The profile ships with the correct cal set.

## 3. Acquisition — verified lock (acquisition is stochastic)

An "armed-before-signal" board can wedge in a never-locks state, and roughly
1-in-3 arms needs a nudge. The procedure that makes lock DETERMINISTIC:

1. Start `lock_watchdog.sh` on the receiving board(s) (`setsid`, detached).
2. Wait ~12 s, kill the watchdog (`pkill -f '[l]ock_watchdog'`).
   Never leave it running through a measurement or capture — a mid-window
   re-arm pulses reset and corrupts the run.
3. **Probe**: 6 s `qpsk_tun -B` — require `aligned(clean+noisy) > 100`.
4. If the probe shows 0 aligned: pulse carrier-sync reset (`0x110` 1→0), re-arm
   byte DMA (`devmem 0x9D300000 32 0x1`), repeat from step 1 (3 tries).

`exp_forward.sh` implements this loop; fold it into any new runner.

## 4. Rx gain pinning (post-lock)

The ADRV9002 hardware AGC's gain steps mid-frame cost ~2× in BER on the
margin-limited direction. After verified lock:

```sh
G=$(anyssh <rx_ip> 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain')
anyssh <rx_ip> "echo spi > .../in_voltage0_gain_control_mode; echo ${G%%.*} > .../in_voltage0_hardwaregain"
```

Notes: the manual-gain mode token is **`spi`** (`manual` is silently rejected);
pin only AFTER verified lock so the captured value is the settled operating
point; leave `automatic` during acquisition.

## 5. Verify — the acceptance ladder

| Tier | Command | Healthy |
|---|---|---|
| A host unit tests | `test.sh loopback` | all PASS, internal-loopback BER≈0 |
| B on-chip BIST | `test.sh bist` | `cap_out=0x04922282`, low counter BER |
| B/C OTA -B | `test.sh ber -d 120` | see table below |
| C real data | `link_test.sh tun` / `ssh` | tun0 ping / SSH over RF |

Healthy numbers **for boards A/B specifically** (final acceptance 2026-07-11:
22 min continuous -B, ~276k frames/direction, verified-lock + 148 gain pin;
re-confirmed on the current lean image). **These are NOT universal** — a
different pair, antennas, or RF path will differ. See PORTING.md before treating
them as targets:

| Direction | BER | CLEAN | rstcs |
|---|---|---|---|
| REVERSE 148→146 @1.90 | **2.1e-6** (282 Mbit) | 99.4% | ~0 |
| FORWARD 146→148 @2.00 | **1.4e-4** sustained warm (3e-6 first ~30 s cold) | 97.6% | ~0 |

Forward is physical-path-limited (148 Rx1 artifact floor + thin budget: gain
rails at 34 dB max, rssi 17–19 dB) — every software lever is already applied
(see §2). To close the last ~1.5 dB to <1e-4 sustained: bench-check 148's Rx1
SMA/cable/antenna (the RESULTS_channels.md recommendation), improve antenna
gain/alignment, or remap the modem datapath to channel 2 (148's Rx2 measured
cleaner than Rx1; needs a BD edit + rebuild, and a check that the Rx2 port has
an antenna).

A growing `rstcs` (0x150) delta = reset storm = wrong/old image. All-PHASE
buckets = quadrant mis-lock → redo §3. `frames_scored=0` = no lock → redo §3.

## 6. Offline forensics (when something looks off)

- Paired capture (Tap-A during a live scored window): `capture_paired.sh A|B`.
- Bit-true fixed-point replay of any capture: `jupiter_240k5_byte/rtl_sim/replay_capture.sh <iq>`.
- Ideal float reference: `k5_240/decode_ref_k5.m` (CFO search ±15 kHz default —
  nominal LOs drift several kHz; never re-narrow it).
- Per-stage localization: `sim_byte_taps` + `k5_240/hybrid_ladder_k5.m`.
- Method + case history: `two_jup/FLOAT_FIXED_CAMPAIGN.md`.

## 7. Recovery quick-reference

| Symptom | Action |
|---|---|
| Board unreachable after flash | wait (boot ~30 s); if >5 min, physical power-cycle required |
| Bad image flashed | boot still works: `cp /boot/BOOT.BIN.prepifix /boot/BOOT.BIN; sync; reboot` |
| Never locks (repeated §3 failures) | re-arm from scratch (full arm sequence), check peer is radiating (`-B` running on TX side feeds the byte-TX DMA — without it the peer transmits idle filler and every frame lands PHASE) |
| Rx S2MM capture wedge | NEVER request >512 KB via the modem S2MM path; Tap-A `iio_readdev` is the safe capture route; wedge recovery = power cycle |
