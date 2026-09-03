# DEPLOY — the f1536 / UIO-DMA upgrade, one board at a time

The ordered runbook for deploying the interrupt-driven-DMA + 1536 B-frame
(f1536) upgrade to a Jupiter board. This supersedes the plain-K5 flash in
[BRINGUP.md](BRINGUP.md) §1 **only** for boards being moved to the UIO/f1536
stack; the RF arm/verify procedure (BRINGUP.md §2 onward) is unchanged.

Boards have **no remote power** — a bad `/boot/Image`, `system.dtb`, `BOOT.BIN`,
or `uEnv.txt` is a physical SD reflash to recover. Every step below backs up
what it overwrites and has a rollback. **Do one board at a time, confirm healthy
before the next** — the per-step backups at `$SUFFIX` are overwritten each run,
so a second board's deploy destroys the first board's rollback point only if you
reuse the host-side artifacts, not the on-board backups (those are per board).

## Artifact identities (verify before deploying)

| Artifact | Identity | Notes |
|---|---|---|
| UIO kernel `Image` | sha256 `a1ba00b514319d8006d9555815e48427840c9291d785868da986feb5cbffe0b5` | 6.12.77, `CONFIG_UIO_PDRV_GENIRQ=y` (built-in) **and** `CONFIG_CMDLINE_EXTEND` baking `uio_pdrv_genirq.of_id=generic-uio`. ARM64 magic `ARMd` @ 0x38. `uname -r` = `6.12.77-gcfe32235a832-dirty` (`-dirty` = the tracked Kconfig delta below; verify greps `6.12.77`). Path `/mnt/onetb/scratch/adi-linux-jupiter/linux/arch/arm64/boot/Image`. **Reproducible via the kernel-provenance section below.** Pre-bake Image was `f7ad5079…d1d2089`. |
| **Image A** BOOT.BIN | md5 `29b322c4f1299eec0b5f6470152faa6e` | f1536 fabric @ **30.72 MHz**. **DEPLOY DISCIPLINE: load ONLY ≤ 15.36 MSPS ADRV9002 LVDS profiles** (1.92 / 15.36). A faster profile clocks the fabric above 30.72 MHz where the modem does not meet timing → silent datapath corruption. |
| **Image B** BOOT.BIN | md5 `f0efafb3e5ae001d98349c842b80c431` | f1536 fabric @ 122.88 MHz (pipelined TX FIR); no ≤15.36 restriction. |
| qpsk `system.dtb` | built per board by `deploy_dtb.sh build` | 2 MB carve @ `0x7FE00000`, 3 qpsk UIO nodes; SPI cells 110 / 111 (`BYTE_IRQ_MAP`). |

`deploy_kernel.sh check` and `deploy_dtb.sh check` run these identity/structure
gates read-only before any board is touched.

### Kernel provenance — how `uio_pdrv_genirq.of_id=generic-uio` is delivered

`CONFIG_UIO_PDRV_GENIRQ=y` is **built-in**, so `modprobe.d` / `modules-load.d`
are ignored — generic-uio binds only if the kernel command line carries
`uio_pdrv_genirq.of_id=generic-uio`. Bring-up recon (2026-07-24) established that
on **these** boards the effective `/proc/cmdline` comes from **U-Boot's compiled
default env**, not from `uEnv.txt` and not from the on-disk `system.dtb`
`/chosen/bootargs` (U-Boot rewrites `/chosen` at `bootm`). Evidence, all read-only:

- on-disk dtb `/chosen/bootargs` = `earlycon` (both boards) — yet
- live `/proc/cmdline` = `earlycon clk_ignore_unused root=/dev/mmcblk0p2 rw rootwait`
  — matching **neither** the dtb nor `uEnv.txt`'s `bootargs=` line;
- persistent U-Boot env (`/dev/mtd1`) is **invalid** (`fw_printenv` → "Cannot read
  environment, using default"), so U-Boot falls back to its built-in default.

So editing `uEnv.txt` or baking of_id into the dtb `/chosen` would **not** reach
the kernel. Instead of_id is **compiled into the kernel** and appended to whatever
the bootloader passes, via `CONFIG_CMDLINE` + `CONFIG_CMDLINE_EXTEND` — the append
is done by the generic `drivers/of/fdt.c early_init_dt_scan_chosen`
(`#if defined(CONFIG_CMDLINE_EXTEND)` → bootloader args + `" "` + `CONFIG_CMDLINE`).
This survives the BOOT.BIN swap at step 4 and is independent of uEnv/mtd/chosen.
`deploy_kernel.sh` therefore **does not touch `uEnv.txt`**.

**arm64 caveat:** this xlnx 6.12 tree's `arch/arm64/Kconfig` cmdline choice exposes
only `CMDLINE_FROM_BOOTLOADER` and `CMDLINE_FORCE` — no `CMDLINE_EXTEND` menu entry
(the backing code in `drivers/of/fdt.c` exists regardless). A 3-line Kconfig delta
adds the entry; it is saved as
[`jupiter_240k5_byte/boot/kernel-arm64-cmdline-extend.patch`](../jupiter_240k5_byte/boot/kernel-arm64-cmdline-extend.patch).
`CMDLINE_FORCE` was **rejected** — it replaces the whole cmdline (dropping
`root=`/`rootwait` unless perfectly replicated → brick risk on a no-power board);
`CMDLINE_EXTEND` only appends, so a failed append still boots (of_id just absent,
caught at the step-2 verify) — graceful failure.

**Reproduce the of_id-baked Image** (from `/mnt/onetb/scratch/adi-linux-jupiter/linux`,
toolchain env from `adi-linux-jupiter/build_env.sh` — Xilinx 2025.1
`aarch64-linux-gnu-` / gcc 13.3.0, the exact env that built the pre-bake Image):

```sh
source /mnt/onetb/scratch/adi-linux-jupiter/build_env.sh   # ARCH=arm64, CROSS_COMPILE, PATH
git apply jupiter_240k5_byte/boot/kernel-arm64-cmdline-extend.patch   # into the kernel tree
./scripts/config --set-str CMDLINE "uio_pdrv_genirq.of_id=generic-uio" \
                 --disable CMDLINE_FROM_BOOTLOADER --disable CMDLINE_FORCE --enable CMDLINE_EXTEND
make ARCH=arm64 olddefconfig
grep -E '^CONFIG_CMDLINE' .config    # expect CONFIG_CMDLINE_EXTEND=y + the of_id string; NO FROM_BOOTLOADER
make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image
sha256sum arch/arm64/boot/Image      # expect a1ba00b5…cbffe0b5
strings vmlinux | grep uio_pdrv_genirq.of_id=generic-uio   # embedded proof
```

## Deploy order (per board)

Run each step, confirm PASS, only then the next. Every script takes the board IP
and reboots the target; all board access is via `two_jup/anyssh.sh`.

### 1. Pristine base dtb → build the qpsk dtb

The qpsk dtb is `fdtoverlay`-merged onto the board's **own** pristine
`system.dtb`. Pull it read-only first, keep a copy, then build:

```sh
cd two_jup
scp root@<ip>:/boot/system.dtb ./system.dtb.pristine        # via anyssh creds
BASE_DTB=./system.dtb.pristine ./deploy_dtb.sh build 110 111 # -> system-qpsk.dtb
./deploy_dtb.sh check system-qpsk.dtb                        # 3 nodes, single 2 MB carve
```

- **Rollback:** none needed — build is host-side, writes no board.

### 2. Kernel Image + generic-uio bootargs

`CONFIG_UIO_PDRV_GENIRQ=y` is **built-in**, so `modprobe.d` / `modules-load.d`
are ignored — the generic-uio bind is driven by the kernel command line, and
`uio_pdrv_genirq.of_id=generic-uio` is **baked into this kernel** (see *Kernel
provenance* above). This step swaps `/boot/Image` only; it **does not touch
`uEnv.txt`** (the of_id no longer rides uEnv/dtb-chosen).

```sh
./deploy_kernel.sh check                       # sha256 + ARM64 magic (read-only)
./deploy_kernel.sh <ip>                         # Image swap, reboots
```

- Verify (the script does this): `uname -r` contains `6.12.77` (**hard**), and
  `uio_pdrv_genirq.of_id=generic-uio` appears in `/proc/cmdline` (**hard** — it
  is compiled in and appended by `CONFIG_CMDLINE_EXTEND`, so it **must** be
  present; absence = the wrong Image booted, not a cmdline-source problem).
- The qpsk UIO nodes are **not** expected yet (old dtb still live) — the verify
  reports them as INFO, never FAIL.
- **Rollback:** `./deploy_kernel.sh rollback <ip>` — restores `/boot/Image` from
  the `$SUFFIX` (`.preuio`) backup, reboots. (uEnv.txt is never modified.)

### 3. qpsk system.dtb

```sh
./deploy_dtb.sh <ip> system-qpsk.dtb            # backup + stage + reboot + verify
```

- Verify (the script does this): `9d300000` claimed in `/proc/iomem`; the three
  `qpsk_tx_dma` / `qpsk_rx_dma` / `qpsk_byte_gpio` UIO nodes present; qpsk dma
  interrupts registered. With step 2's baked-in generic-uio cmdline in place, the
  nodes now bind — if they are missing here, confirm the step-2 verify actually
  showed `of_id … present in /proc/cmdline` (the correct Image booted).
- **Rollback:** `./deploy_dtb.sh rollback <ip>` — restores `/boot/system.dtb`.

### 4. BOOT.BIN (bitstream)

Pick the image for the board's role and **honour the Image A profile limit**.

```sh
./deploy_image.sh <ip> <path/to/BOOT.BIN>       # backup + stage + reboot
```

- Image A boards (`29b322c4…`): provisioning/LVDS-profile step MUST refuse any
  profile above 15.36 MSPS (see `jupiter_240k5_byte/image_a_3072_clocks.xdc`).
- Image B boards (`f0efafb3…`): no profile restriction.
- **Rollback:** `SUFFIX=.pregeneric` copy — `cp /boot/BOOT.BIN.pregeneric
  /boot/BOOT.BIN; sync; reboot` (deploy_image.sh backs it up before flashing).

### 5. Provision the 2 MB host build

**Only after step 3's verify PASSed** — the 2 MB carve must be reserved in the
live dtb first. The 2 MB host binary maps `0x7FE00000`; on a board still
reserving only the old 1 MB it would let the S2MM engine scribble kernel RAM.
Two backstops make this safe: this ordering, and the binary's **startup carve
guard** (`qpsk_tun.c`, `-DQPSK_CARVE_2MB` only), which parses `/proc/iomem` and
**refuses to start** unless a `reserved` region covers the whole 2 MB carve.

```sh
QPSK_CARVE_2MB=1 ./provision.sh <ip>            # on-board gcc gets -DQPSK_CARVE_2MB
# host-side equivalent (for a cross-built / tested binary):
#   make -C ../host_app_k5 qpsk_tun_2mb          # keeps -Wall -Wextra -Werror
```

- The `qpsk_tun_2mb` make target uses a target-specific `CFLAGS +=
  -DQPSK_CARVE_2MB` on purpose: `make CFLAGS+=-DQPSK_CARVE_2MB` on the command
  line *replaces* CFLAGS and silently drops `-Werror`.
- Default `provision.sh <ip>` (no flag) keeps the 1 MB-carve K5 build.
- **Rollback:** rebuild without the flag (`./provision.sh <ip>`), or the guard
  simply refuses to run — no board state is corrupted either way.

## After a full deploy

Both boards on kernel `6.12.77`, qpsk dtb (2 MB carve + UIO nodes bound), the
role-appropriate BOOT.BIN, and the 2 MB `qpsk_tun`. Continue with the RF arm /
lock / verify procedure in [BRINGUP.md](BRINGUP.md) §2, using the f1536 link
test (`link_test_1536.sh`) and the profile matching the image (Image A: ≤ 15.36
MSPS only).
