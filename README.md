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

From a clean clone and two stock boards, run the five stages below in order,
once. **After a reboot go straight to BRING UP** -- Step 0 and PROVISION persist
across reboots (the dtb is on the SD card, the binaries in `/root/host_app_k5`)
and repeating them is not free: the flash steps force an extra warm reboot, which
accumulates stuck ADRV9002/AXI state that only a physical cold cycle clears, and
PROVISION runs gcc on the board -- doing that redundantly saturated 146's SD card
on 2026-09-04 and stalled its block layer for 15 minutes. Redo Step 0 only if the
kernel or dtb changed, and PROVISION only if `host/` sources changed.

```bash
# STEP 0  (ONCE per fresh board, or after a rollback to stock -- SKIP otherwise.)
# The modem BOOT.BIN is inert without these: qpsk_tun maps a 2 MB DMA carve and
# binds three UIO nodes that the stock kernel and dtb do not provide. Order per
# board is kernel -> dtb -> BOOT.BIN, one board at a time, confirming each reboot.
# Skip when `uname -r` on the board already reads 6.12.77 AND /sys/class/uio lists
# qpsk_tx_dma, qpsk_rx_dma and qpsk_byte_gpio. Full envelope: docs/setup-prebuilt.rst
cd images && md5sum -c MD5SUMS && gunzip -kf Image.6.12.77-uio.a1ba00b51431.gz && cd ../ops
./deploy_kernel.sh 10.0.0.148 ../images/Image.6.12.77-uio.a1ba00b51431   # backs up /boot/Image, reboots, verifies
./deploy_dtb.sh    10.0.0.148 ../images/system-qpsk.148.dtb.1da3a9cf05a0
# ...then the same pair of commands for 146 with system-qpsk.146.dtb.19e974098b6e

# DEPLOY  (per board; Jupiter has no remote power -- flash is size-checked and
# the current /boot/BOOT.BIN is backed up first). Images + roles: see images/CURRENT.txt
cd ops
./deploy_image.sh 10.0.0.148 A      # role A image from images/CURRENT.txt
./deploy_image.sh 10.0.0.146 B      # role B; one board at a time

# PROVISION  (host app + radio profiles + watchdog + per-board watchdog.conf,
# built on-board from host/ sources). Watch its first line: it probes the board's
# UIO nodes and prints "-> 2 MB-carve build" or "-> 1 MB-carve build". The 1 MB
# line means Step 0 has not taken on that board -- fix that before bringing up,
# because the link comes up measurably worse rather than failing outright.
./provision.sh 10.0.0.148
./provision.sh 10.0.0.146

# BRING UP  (the deployed rung: 61.44 MSPS / 15.36 Msym/s, both radios, daemons up)
./bringup_r2r3.sh r3

# TEST  (thin dispatcher over the proven tiers; see docs/testing.rst)
./test.sh loopback           # Tier A: self-loopback, no RF
./test.sh bist                # Tier B: on-chip BIST (expect cap_out = 0x04922282)
./test.sh ber -d 90           # Tier C: two-board FDD link, host full-packet PER/BER
```

Or drive the whole sequence from one place:

```bash
./setup_from_zero.sh                 # probe both boards read-only, print exactly
                                     #   what is still missing and what would run
./setup_from_zero.sh run --yes       # execute step0..provision, asserting the
                                     #   precondition between every pair of stages
```

It calls the same scripts above rather than reimplementing them, skips whatever a
board already has, and stops at the first stage whose result does not verify. The
two RF stages (`bringup`, `test`) sit outside its default range and run only when
you name them with `--to bringup` / `--to test`.

### Live video (camera on 148 -> RF hop -> relay on 146 -> this PC)

Once the link is up, two more steps give you video. The statically linked
aarch64 ffmpeg ships in the repo, so the boards need no internet and no apt:

```bash
cd ops
./install_board_media.sh 10.0.0.148   # static ffmpeg + board_webcam.py -> /usr/local/bin
./install_board_media.sh 10.0.0.146   # once per board; skips the transfer if identical
./stream_board2pc.sh                  # encode on 148, -c copy relay on 146, ffplay here
./stream_board2pc.sh --check          # health readout only
./stream_board2pc.sh --stop           # tear down
```

148 is the camera end because 148 -> 146 is the healthy RF direction; 146 only
remuxes and serves TCP :5010, and this PC connects out to it (the boards cannot
open a connection into a NAT'd WSL2 host).

Bringing up a **different** pair of boards? See `docs/bringup.rst` (and
`A_IP=... B_IP=... ./setup_from_zero.sh`).

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
