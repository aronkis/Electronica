# QPSK K5 Jupiter Modem

Bidirectional FDD link between two ADALM-Jupiter (ADRV9002) SDRs: π/4 QPSK at
15.36 Msym/s (61.44 MSPS, 4 sps), rate-1/2 K=5 convolutional code, an in-fabric
byte-DMA data plane, IP over `tun0`. Simulink/HDL Coder model to BOOT.BIN.

**Status (2026-09-09):** both legs under the 1 % PER target with lost frames in the
denominator. Forward 0.070–0.079 %, reverse 0.191 % pooled. Images per
`images/CURRENT.txt`. Docs: https://tfcollins.github.io/qpsk-jupiter-modem/

## Layout

| Dir | Role |
|---|---|
| `modem/` | Simulink model, overlays, HDL/sim gates, rtl_sim harness and gate evidence |
| `host/` | Linux host daemon (`qpsk_tun`), tools, `modem_status/` TUI, C tests |
| `ops/` | Operator kit: deploy, provision, bring-up, health gate, credited capture. `skidfix/` is the netlist fix kit (moving under `modem/` in the next cleanup step) |
| `contract/` | Bit and packet contract, golden vectors, float reference receiver |
| `images/` | Current BOOT.BIN pair, on-board rollbacks, kernel, device trees |
| `docs/` | Sphinx docs; `docs/evidence/` holds the investigation ledgers the pages cite |
| `tests/` | MATLAB unittest suite (L1 host-pure, L2 gates, L3 hardware-in-loop) |

## Quick start

```bash
# DEPLOY  (per board; Jupiter has no remote power -- flash is size-checked and
# the current /boot/BOOT.BIN is backed up first). Images + roles: see images/CURRENT.txt
cd ops
./deploy_image.sh 10.0.0.148 A      # role A image from images/CURRENT.txt
./deploy_image.sh 10.0.0.146 B      # role B; one board at a time

# PROVISION  (host app + radio profiles + watchdog, built on-board from host/ sources)
./provision.sh 10.0.0.148
./provision.sh 10.0.0.146

# BRING UP  (the deployed rung: 61.44 MSPS / 15.36 Msym/s, both radios, daemons up)
./bringup_r2r3.sh r3

# TEST  (thin dispatcher over the proven tiers; see docs/testing.rst)
./test.sh loopback           # Tier A: self-loopback, no RF
./test.sh bist                # Tier B: on-chip BIST (expect cap_out = 0x04922282)
./test.sh ber -d 90           # Tier C: two-board FDD link, host full-packet PER/BER
```

Bringing up a **different** pair of boards? See `docs/bringup.rst`.

## Rules

- Never modify the read-only ADI donor tree `/home/tcollins/dev/qpsk_ai`.
- Flash one board at a time; the rollback `.bak` must exist on-board first.
- Any PER number carries the command, the sample count, and the statement that lost
  frames are in the denominator.

## History

Tracked material removed in the 2026-09 cleanup (campaign scripts, capture
output, 30 superseded images) is on tag `archive/pre-cleanup-2026-09-09`;
`git checkout archive/pre-cleanup-2026-09-09 -- <path>` restores it. The 62
untracked build trees are harvested (one tarball each) under
`.../qpsk-build-trees/harvest/`; current-148 stays intact, unharvested, beside it.
