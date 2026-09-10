# images — banked BOOT.BIN images for the two-Jupiter rig

Canonical bank of the load-bearing boot images (ADALM Jupiter, ZynqMP, f1536 /
61.44 MSPS byte-plane modem). Filenames carry board + lineage + md5-12; verify
against `MD5SUMS` before any flash. All images 7,203,552 bytes, bootgen
`-arch zynqmp -w`. Evidence for every claim: `docs/evidence/SINGLES_CAMPAIGN.md`
(dated sections) and `docs/evidence/NETLIST_PROVENANCE.md`.

## 146 (10.0.0.146 — TMR lineage, byte-plane TX under study)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` | `9acbe2ebe1db` | **RXFIX candidate for 146: W1 + R4D + R1 — and it is a 148-LINEAGE IMAGE.** Source kit `jupiter_byte_seqbist_build` (the **148** SEQ-BIST tree, `a1ff3c876d91`), injector `10b27b7`, kit `jupiter_byte_rxfixr4dr1_build`, `IMPL_STRATEGY=explore`. Fix content: R4D = R4B's structural pcEnd window plus a FULL-side extra pop armed at occ >= 24; R1 = the Preamble_Detector realignment FIFO's pop becomes occupancy-indexed (`Delay10_full = FIFO_numEntries == 14'd12333`), without which that FIFO deletes the extra (Task 14). Sim gate: Task 20 S1, +10 ppm loss **0.00 %** (baseline 4.99 %, R4B 6.65 %, R4D alone 70.28 %), `rh_push_on_full` 0, `pdOcc` pinned at 12,333. **Modem-clock intra-clock routed WNS +0.620 ns**, TNS 0, 0 failing endpoints. R1 trims the 49,332-deep `Delay10_reg`: **CLB Registers 110,550 -> 61,331 (-49,219)**, **SRLC32E 2,977 -> 1,435 (-1,542)**. Witness words 0x234 (R4B's layout) and **0x238** (`{16'b0, extras[15:0]}`, unread by any tool in-repo yet). **FLASHED on 146 2026-09-05 14:11 and CURRENT (role B in CURRENT.txt).** Reverse PER 0.191 % (09-06, DP cable out), 0.06–0.09 % on 2026-09-09 with whitening (level-limited). On-board rollback `BOOT.BIN.146.w1x148.2728dab3979a` (`/root/BOOT.BIN.2728dab3979a.bak`). |
| `BOOT.BIN.146.w1x148.2728dab3979a` | `2728dab3979a` | **On-board rollback bank for 146**, banked here as `w1x148` because the content is a 148-lineage W1-only image (originally `BOOT.BIN.148.rxfixw1.2728dab3979a`, superseded on 148 by R4B `9f13705d9fb0`) that was cross-flashed to 146 ahead of `rxfixr4dr1` as its verified `.bak`. W1 = the Rate_Handle-only fix, no R4B/R4D/R1/BS on top. Do not treat as a 146-native lineage image; see the `rxfixr4dr1` row for the confound history. |

Note (2026-08-26): the comb is CFO-sign-asymmetric and requires cross-board
clocks; per-image PER deltas may be receiver-side sensitivity — see
`docs/evidence/KNOWN_HOLES.md` H-1/H-3 before spending flashes on placement draws.

## 148 (10.0.0.148 — RX/tap board)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` | `bf2a7305bbe0` | **RXFIX W1 + R4B + BS + PAD (F4: ByteSerializer pads truncated frames to 191 words).** Kit `jupiter_byte_rxfixpad_build` from the SEQ-BIST tree, injector f75d522, `IMPL_STRATEGY=explore`; modem-clock intra-clock routed WNS **+0.105 ns** / TNS 0 (overall 1.544). Sim gate §47.8 PASS (truncation control 418×191-word frames, 0 orphans; identity byte-identical). Built 2026-09-08 17:10 on hdl-dev-2. Flash/result: ledger FWD_CRC_REGRESSION_0907 §47.9–§47.10. **FLASHED on 148 2026-09-08 17:12 and CURRENT (role A in CURRENT.txt);** forward PER 0.008 % with WHITEN=1 (§47.24, §48.3). Rollback `BOOT.BIN.148.rxfixbs.dec007ae70dd` on-board. |
| `BOOT.BIN.148.rxfixbs.dec007ae70dd` | `dec007ae70dd` | **On-board rollback bank for 148.** W1 + R4B + BS (byte-seam census), the lineage immediately before PAD/F4: kit `jupiter_byte_rxfixbs_build`, injector `e95a013`. Flashed on 148 2026-09-07 18:14 under full rails, GATE_PASS x2 (`fps=1248`, `capTAP=0xBCF94856`), Tier-2 witness clean; superseded on-board by `rxfixpad` on 2026-09-08 and kept as that image's verified `.bak`. |

## Kernel Image and device trees (added 2026-09-09)

The boot set per board is BOOT.BIN + `/boot/Image` + `/boot/system.dtb`. All
three are banked; identities below were read back from both rig boards on
2026-09-09 and match.

| file | identity | what it is |
|---|---|---|
| `Image.6.12.77-uio.a1ba00b51431.gz` | raw `Image` sha256 `a1ba00b514319d8006d9555815e48427840c9291d785868da986feb5cbffe0b5` (`SHA256SUMS.Image`), 48,239,104 B; gz md5 in `MD5SUMS` | UIO kernel, `6.12.77-gcfe32235a832-dirty`: ADI `xlnx/release/v6.12.y-2026r1` @ `cfe32235` + `modem/boot/kernel-arm64-cmdline-extend.patch` (`CONFIG_UIO_PDRV_GENIRQ=y`, `uio_pdrv_genirq.of_id=generic-uio` baked in). Same file on 148 and 146. `gunzip -k` it (the raw `Image.6.12.77-uio.a1ba00b51431` is gitignored); `sha256sum -c SHA256SUMS.Image` and `ops/deploy_kernel.sh check <Image>` both verify the sha256. |
| `system-qpsk.148.dtb.1da3a9cf05a0` | md5-12 | qpsk dtb for **148**: pristine base + `qpsk_byte_uio.sub.dtso` (pre-cleanup tree; see tag `archive/pre-cleanup-2026-09-09`) (2 MB carve @ `0x7FE00000`, 3 UIO nodes, SPI cells 110/111). Live on 148. |
| `system-qpsk.146.dtb.19e974098b6e` | md5-12 | qpsk dtb for **146**, same overlay on 146's own base. Live on 146. |
| `system.dtb.pristine.148.3334673acf50` | md5-12 | Reference (stock ADI) `system.dtb` 148 shipped with; rollback + `BASE_DTB` for `deploy_dtb.sh build`. |
| `system.dtb.pristine.146.dba6d8f74aac` | md5-12 | Reference (stock ADI) `system.dtb` 146 shipped with. |

Deploy order per board: `deploy_kernel.sh <ip> <Image>` → `deploy_dtb.sh <ip> <qpsk dtb>` →
`deploy_image.sh <ip> A|B`, one board at a time (`docs/build-and-flash.rst`, `docs/setup-prebuilt.rst` Step 0).

## Deployment (all scripts tracked in `ops/`)

- Flash under full rails (md5 precondition, on-board + repo rollback banks,
  readback verify, full bring-up, two-pass reset-aware health gate
  fsync>=1100 AND wcnt>=1100 on 148, auto-rollback, NO retry):
  - 148: `ops/skidfix/flash_148_beatfix2.sh <md5-12>`
  - 146: `ops/skidfix/flash_146_vendh.sh <md5-12>` (carries the 2026-08-26
    rails amendment: pre-flash 148 liveness/health precondition; adapt BB/
    BAK_MD5 header vars per target image), also `flash_146_tmrfresh.sh`,
    `flash_146_rollback433.sh`
- Bring-up / restore: `ops/restore_known_good.sh` (full both-board restore:
  profile arm, ROM double-tap, stream-first byte flip, daemons, watchdogs),
  `ops/bringup_r2r3.sh r3`. Forward RX LO default is +20k off-null
  (2026-08-26, comb 13%->6%), env-overridable via `LO_A_RX`.
- Health: `ops/health_probe_reset_aware.sh <ip> 12` (the trusted probe).
- Watchdog: `ops/lock_watchdog.sh` (hardened build, deployed to
  `/root/lock_watchdog.sh` on both boards; restart via ISOLATED ssh calls).
- Flash discipline: stop the nemo sentinel first
  (`touch ~/modem-status/SENTINEL_STOP`), relaunch after; one flash event per
  board per session unless operator-gated; rollback flashes end the lane.

`MD5SUMS` in this directory is authoritative — `md5sum -c MD5SUMS` before use.

Images removed on 2026-09-09 are on tag `archive/pre-cleanup-2026-09-09` under the image bank's pre-cleanup path.
