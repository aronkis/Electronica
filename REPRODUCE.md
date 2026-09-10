# Reproducing the deployed images (modem-upgrade-2026-07)

This branch upgraded the two-ADALM-Jupiter (ADRV9002) QPSK modem: F1536 frame,
interrupt-driven DMA data plane, and a 30.72/61.44 MSPS rate ladder. This file
pins the deployed artifacts to the commits that build them so the images and HDL
can be regenerated from source.

## Deployed images

| Image | Rung(s) | Fabric clk | sps | Build commit | BOOT.BIN md5 |
|-------|---------|-----------|-----|--------------|--------------|
| A | R0 (1.92) / R1 (15.36) | 30.72 MHz | 8 | `31c859b` (TXMUX merge) | `60193265517d164a440a38d3870d42e3` |
| B | R2 (30.72) / R3 (61.44) | 122.88 MHz | 4 | `8a151cb` (branch HEAD at build time) | `64bb24766032a868bae8a8268986cfb3` |

Both boards (10.0.0.146 / .148) run **Image B** (`64bb2476`) as of the R2/R3 ladder
bring-up. Image A is the deployed fallback (banked on-board as `BOOT.BIN.pre-b2`).
The `BOOT.BIN` binaries themselves are build artifacts and are **not** tracked —
regenerate them from the commits above.

## Rebuild HDL / BOOT.BIN

From a clean checkout of the build commit, in `jupiter_240k5_byte/`:

```
# Image A (f1536, sps8, 30.72 MHz)
QPSK_FRAME=f1536 QPSK_SPS=8 ./build_lean_image.sh
# Image B (f1536, sps4, 122.88 MHz)
QPSK_FRAME=f1536 QPSK_SPS=4 ./build_lean_image.sh
```

Output: `hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`. The flow runs the
QPSK_LEAN gate suite -> MATLAB HDL codegen -> Vivado (`complete_byte_t8.tcl`,
which sources `wire_byte_irqs.tcl`) -> dual-DMA tap (`ch2_build2.tcl`). Vivado
2025.1. Post-route timing at target: Image A WNS +0.214, Image B CH2_IMPL_WNS
+0.391 (TNS 0). Post-build gate: `jupiter_240k5_byte/rtl_sim/run_mm2s_gate.sh`
(SKID_LAG depth must == `qpskByteSkidLag()` = 8 on both generations).

## Device tree

The deployed DTB is the board's base DTB with the UIO overlay merged in:

```
two_jup/deploy_dtb.sh build   # merges boot/qpsk_byte_uio.dtso into the pristine base
```

- Base DTBs (inputs, extracted from the boards): `two_jup/system.dtb.pristine.{146,148}` (tracked)
- UIO overlay source: `jupiter_240k5_byte/boot/qpsk_byte_uio.dtso`, `two_jup/qpsk_byte_uio.sub.dtso` (tracked)
- Merged output `two_jup/system-qpsk.{146,148}.dtb` is regenerated (not tracked).

IRQ SPI cells are 110/111 (GIC SPI 142/143) in both images -> the same merged DTB
serves both; a rebuild does not require a DTB or kernel redeploy.

## Kernel

The deployed kernel (6.12.77, ADI `xlnx/release/v6.12.y-2026r1`) carries `of_id`
via a `CONFIG_CMDLINE_EXTEND` bake (commit `f7c2676`, patch under
`jupiter_240k5_byte/boot/`). Not rebuilt during the ladder work.

## Runtime stack

- Host app: `host_app_k5/` (`qpsk_tun.c` et al.), current through `fb40309`.
  Build on-board with `PATH=/usr/bin:/bin make` (avoid the `~/.local/bin/as` shadow).
- Bring-up: `two_jup/bringup_r2r3.sh <r2|r3>` — deterministic double-tap arm,
  rate-conditional CFO policy, safe SSI-delay protocol, ROM arm-quality gate.
- SSI delay fix: `two_jup/apply_146_ssi_fix.sh` (146 tx0 c3d4; live-read -> full
  cache write-back -> verify). Watchdog: `two_jup/lock_watchdog.sh`.
- ADRV9002 FDD profiles (R2/R3): `two_jup/lvds_{30p72,61p44}_fdd_jupiter.{json,bin}`
  (commit `24ba0a7`). The shipped TDD 30.72/61.44 profiles are unusable for the
  FDD link — use the `_fdd_` variants.

## MAC / boot note

The lab MAC is carried by the boot script, not board-persistent (factory eFUSE MAC
DHCPs to a different address). 148's `boot.scr` sets `ethaddr 00:04:9f:00:00:02`
plus the campaign bootargs; 146 = `...:00:01`. See commit `ce1f547`.

## Measured ladder results

| Rung | Goodput (delivered) | RTT avg | CPU |
|------|---------------------|---------|-----|
| R0 (1.92) | 171-182 kbit/s (79-84% of ceiling) | 668 ms | 0.24% |
| R2 (30.72) | 5.29 / 5.83 Mbit/s | 28/32 ms | 8-10% |
| R3 (61.44) | **12.7 fwd / 13.7 rev Mbit/s** (91-99% of the ~13.9 Mbit/s ceiling) | 9.5/21 ms | 8-10% |

R3 goodput ladder (`perf_ceiling.sh both`, 1400 B, delivered rx):

| offered | FWD delivered / loss | REV delivered / loss |
|---------|----------------------|----------------------|
| 6M  | 5.47 / 8.9%  | 5.90 / 1.6%  |
| 10M | 9.06 / 9.4%  | 6.90 / 17.2% (transient) |
| 12M | 10.55 / 12.1% | 11.86 / 1.2% |
| 15M | 12.73 / 15.1% | 13.72 / 8.6% |

The earlier "5.2 Mbit/s @ 6M" figure was an under-offer artifact, not a link limit — 6M
never reached the knee. The link sustains near the full 1245 f/s x 1400 B x 8 theoretical
rate; loss climbs with offered load (forward higher, tracking 146's intrinsic TX EVM margin).

vs. the pre-campaign K5 link: ~68 kbit/s ceiling, 116 B MTU, ~100% CPU (polled) —
**~185-200x the goodput** at R3.
