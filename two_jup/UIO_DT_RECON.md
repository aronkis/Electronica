# Task B0 — Read-only DT/UIO Recon for interrupt-driven-DMA upgrade

Both boards reachable via `two_jup/anyssh.sh` (password-auth ssh, `PreferredAuthentications=password`,
`PubkeyAuthentication=no`, root@). All commands below were read-only: `cat`, `ls`, `find`, `dtc -I fs`
(dumps live /proc/device-tree, no writes), `zcat /proc/config.gz`, `lsmod`. No devmem, no writes, no
reboots, no service restarts were issued. Raw transcripts saved alongside this file:
`board146_raw.txt`, `board146_uio.txt`, `board148_raw.txt`, `board148_uio.txt`.

---

## Board 10.0.0.146

### 1. OS / kernel
- `Kuiper GNU/Linux 11.2 (bullseye)` (ID=raspbian, ID_LIKE=debian) — ADI Kuiper image.
- `Linux analog 6.12.0-ga14dd7c6dea2 #1 SMP Tue May 19 11:23:17 EDT 2026 aarch64`
- hostname: `analog`

### 2. Boot artifacts
- `/boot` is a FAT boot partition holding **many BOOT.BIN snapshots** (`BOOT.BIN.V15`…`V42`,
  `.prelean`, `.pretap`, `.prerxfix`, etc. — clearly campaign history from this repo's iteration),
  the live `BOOT.BIN` (Jul 20 13:03), `system.dtb` (+ `.bak`, `.bak.1779397173`), `Image` (kernel),
  `uEnv.txt`, `kuiper.json`, plus a large library of *unrelated* stock ADI dtbs for other carriers
  (zynqmp-zcu102-*, socfpga-*, versal-*, zynq-zc706-*, etc. — this is the generic Kuiper `/boot`
  overlay tree, not specific to this design).
- No `/boot/extlinux` directory (empty ls, no `extlinux.conf`).
- `fw_printenv` produced no output (either not installed/no U-Boot env device exposed, or empty) —
  boot env instead comes from **`/boot/uEnv.txt`**:
  ```
  uenvcmd=run adi_sdboot
  adi_sdboot=... fatload mmc 0 0x3000000 ${kernel_image} && fatload mmc 0 0x2A00000 ${devicetree_image} && ...
  bootargs=console=ttyPS0,115200 root=/dev/mmcblk0p2 rw earlycon rootfstype=ext4 rootwait clk_ignore_unused cpuidle.off=1
  ```
- **Boot flow**: U-Boot (SPL from BOOT.BIN) → uEnv.txt `adi_sdboot` → loads `Image` (kernel) to RAM at
  0x3000000, **`system.dtb` to 0x2A00000** from the SD FAT partition → `bootm`. So the deployed DTB
  file is **`/boot/system.dtb`** (confirmed matching live `/proc/device-tree` dump byte-for-byte in
  structure). BOOT.BIN carries FSBL+PMUFW+bitstream+u-boot; system.dtb is a separate FAT file, not
  baked into BOOT.BIN.
- Live `/proc/device-tree/chosen/bootargs` differs slightly from uEnv's `bootargs=`:
  `earlycon clk_ignore_unused root=/dev/mmcblk0p2 rw rootwait` (no `console=`, `rootfstype`, or
  `cpuidle.off=1` — likely u-boot appends/overrides some of these, or system.dtb `chosen` node has
  its own baked bootargs that take precedence over uEnv's). Also present:
  `u-boot,version = "2023.01-00003-gb768132db26"`.

### 3. Kernel UIO support
```
CONFIG_UIO=y
CONFIG_UIO_PDRV_GENIRQ=m      <- module, NOT built-in
CONFIG_UIO_DMEM_GENIRQ=m      <- module, NOT built-in
CONFIG_UIO_XILINX_APM=y       <- built-in (this is what's bound today)
```
`/lib/modules/$(uname -r)/kernel/drivers/uio` — **ls produced no output** (dir absent or empty in
this rootfs's module tree — modules for `uio_pdrv_genirq`/`uio_dmem_genirq` were not found there;
they exist in the kernel config as `=m` but the corresponding `.ko` was not located at the expected
path — worth a second look with `find` if pursuing this further, but at minimum it is **not loaded**:
`lsmod | grep -i uio` → empty).
- `/sys/bus/platform/drivers/` has **no uio driver directory bound** (`ls | grep -i uio` → empty).
- Currently active UIO devices are `uio0..uio3`, all `name=axi-pmon` (Xilinx AXI Performance Monitors,
  via the built-in `CONFIG_UIO_XILINX_APM=y` driver, not genirq), mapped at `0xffa00000`, `0xfd0b0000`,
  `0xfd490000`, `0xffa10000` — matches the 4 `perf-monitor@*` DT nodes. **No genirq-class UIO device
  exists today.**

### 4. Deployed devicetree
- `dtc` is present (`/usr/bin/dtc`) and a full `dtc -I fs -O dts /proc/device-tree` dump succeeded
  (saved in `board146_raw.txt`).
- Top-level node names under `/proc/device-tree/`: standard ZynqMP set (`axi`, `axi_pl`,
  `reserved-memory`, `chosen`, `cpus`, `firmware`, `zynqmp-ipi`, clocks, thermal-zones, etc.) — no
  `amba` node exists on this platform (that's a Zynq-7000-ism); ZynqMP uses `axi` (PS peripherals)
  and `axi_pl` (PL/FPGA-fabric peripherals).
- `axi_pl` node contains the design's custom cores:
  - `mwipcore@9D000000` — `compatible = "mathworks,mwipcore-v3.00"`, `reg = <0x9d000000 0xffff>`
    (i.e. 64KB @ 0x9D00_0000). **Has NO `interrupts` property in the DT at all** — this is the qpsk
    core (Simulink HDL Coder generated) and it is currently a pure poll/register-access peripheral
    with no PL→PS IRQ wired.
  - `axi-adrv9002-rx-lpc@84A00000`, `axi-adrv9002-rx2-lpc@84A02000`,
    `axi-adrv9002-tx-lpc@84A04000`, `axi-adrv9002-tx2-lpc@84A06000` — ADI ADRV9002 RX/TX
    AXI-ADC/DAC front-ends (no `interrupts` property either; they reference DMA channels via
    `dmas = <phandle chan>`).
  - Four `dma-controller@84A3xxxx..84A6xxxx` nodes, `compatible = "adi,axi-dmac-1.00.a"`, each **with**
    an `interrupts` cell — these are the ADI streaming DMACs feeding rx/rx2/tx/tx2.
  - `axi-sysid-0@85000000` — `adi,axi-sysid-1.00.a` (build ID core, no IRQ).
- No `find ... -iname '*9d0*' -o -iname '*dma*'` targeted-read output was needed since the full dtc
  dump already covers it; `/proc/device-tree/amba*` glob matched nothing (no such node, as noted).
- `chosen/bootargs` read via `cat` (dtc dump already renders it as plain string; hexdump not needed).

### 5. /proc/iomem, /proc/interrupts, /proc/cmdline, /proc/meminfo
- `/proc/iomem` (PL region excerpt):
  ```
  7ff00000-7fffffff : reserved                                    <- the DMA carve
  84a00000-84a05fff : 84a00000.axi-adrv9002-rx-lpc  axi-adrv9002-rx-lpc@84A00000
  84a09000-84a09fff : 84a09000.axi-adrv9002-rx2-lpc axi-adrv9002-rx2-lpc@84A02000
  84a30000-84a3ffff : 84a30000.dma-controller        dma-controller@84A30000
  84a40000-84a4ffff : 84a40000.dma-controller        dma-controller@84A40000
  84a50000-84a5ffff : 84a50000.dma-controller        dma-controller@84A50000
  84a60000-84a6ffff : 84a60000.dma-controller        dma-controller@84A6000
  85000000-8500ffff : 85000000.axi-sysid-0           axi-sysid-0@85000000
  9d000000-9d00fffe : 9d000000.mwipcore                            <- the qpsk core, no IRQ line
  ```
- `/proc/interrupts` (PL-relevant lines):
  ```
  22:  ...  GICv2 141 Level  84a30000.dma-controller
  23:  ...  GICv2 139 Level  84a50000.dma-controller
  24:  ...  GICv2 140 Level  84a40000.dma-controller
  25:  ...  GICv2 138 Level  84a60000.dma-controller
  32:  ...  GICv2  57 Level  axi-pmon, axi-pmon
  33:  ...  GICv2 155 Level  axi-pmon, axi-pmon
  ```
  `mwipcore` does **not** appear in `/proc/interrupts` (consistent with having no `interrupts` DT
  property).
- `/proc/cmdline`: `earlycon clk_ignore_unused root=/dev/mmcblk0p2 rw rootwait`
- `/proc/meminfo`: MemTotal 2006852 kB, MemFree 1496880 kB, MemAvailable 1747292 kB.

### 6. How the 0x7FF00000 DMA carve is reserved
Via a `reserved-memory` DT node, **not** a `mem=` bootarg (bootargs have no `mem=`):
```
reserved-memory {
    #address-cells = <2>; #size-cells = <2>; ranges;
    memory@3ed00000 { reg = <0x0 0x3ed00000 0x0 0x40000>; no-map; };
    qpsk_byte_buf@7ff00000 { reg = <0x0 0x7ff00000 0x0 0x100000>; no-map; };   <- 1 MiB @ 0x7FF00000
    memory@3ef00000 { reg = <0x0 0x3ef00000 0x0 0x40000>; no-map; };
};
```
Confirmed against `/proc/iomem`: `7ff00000-7fffffff : reserved` (1 MiB span, matches
`0x100000` size). This is a static `no-map` carve baked into `system.dtb` at build time (named
`qpsk_byte_buf`), not a runtime CMA/dma-buf pool and not driven by kernel cmdline.

### 7. GIC SPI numbering evidence (pl_ps_irq → GIC SPI)
DT `interrupts = <0x00 IRQ 0x04>` cells use type=SPI(0), IRQ=cell2, flags=4(level-high). Cross-checked
against the live `/proc/interrupts` GIC column, giving a clean, consistent **`GIC SPI = DT-cell + 32`**:
| DT node | DT irq cell (dec) | GIC SPI (proc/interrupts) |
|---|---|---|
| dma-controller@84A30000 (rx-lpc DMA) | 109 (0x6d) | 141 |
| dma-controller@84A40000 (rx2-lpc DMA) | 108 (0x6c) | 140 |
| dma-controller@84A50000 (tx-lpc DMA) | 107 (0x6b) | 139 |
| dma-controller@84A60000 (tx2-lpc DMA) | 106 (0x6a) | 138 |
| axi-pmon (perf-monitor@ffa10000) | 0x57=87 wait see raw (155 shown) | 155 |
| axi-pmon (perf-monitor@ff a00000-ish) | 25 (0x19)→ | 57 |

(First four rows are the clean, load-bearing evidence: PL DMA SPI+32 mapping is exact and repeatable
across all 4 ADI DMA channels.) **`mwipcore` has no interrupt line today** — for the planned
interrupt-driven-DMA upgrade, a new `interrupts = <0x00 N 0x04>` property will need to be added to
(or a new node created alongside) `mwipcore@9D000000` in `system.dtb`, picking an SPI number not
already in use in the PL ID range (the ADI DMACs currently occupy GIC SPI 138–141, i.e. DT cells
106–109; PL IRQs on ZynqMP typically run DT-cell 89–116 / GIC SPI 121–148 for the 16 `pl_ps_irq`
lines routed through the PS-GPU/PL fabric — an unused cell in that range, e.g. one of the cells not
listed above, would be the natural pick, but the exact free set should be verified against the full
Vivado block-design IRQ concat before committing).

### 8. UIO devices
```
/sys/class/uio: uio0 uio1 uio2 uio3   (all name=axi-pmon; addrs 0xffa00000, 0xfd0b0000, 0xfd490000, 0xffa10000)
```

---

## Board 10.0.0.148

### 1. OS / kernel — SURPRISE
- **`Debian GNU/Linux 13 (trixie)`** (ID=debian, DEBIAN_VERSION_FULL=13.5) — **not** the Kuiper/raspbian
  image that .146 runs. Same kernel build though: `Linux analog 6.12.0-ga14dd7c6dea2 #1 SMP Tue May 19
  11:23:17 EDT 2026 aarch64` (identical kernel binary/version string to .146 — same `Image`/kernel
  built once and deployed to both, but a different userspace rootfs distro on .148).
- hostname: `analog` (same as .146 — no per-board hostname differentiation).

### 2. Boot artifacts
- `/boot` layout is the same style FAT partition (fewer stock DTB files — Debian's `/boot` doesn't
  carry the full ADI Kuiper reference-dtb library that .146's Kuiper `/boot` does, but has newer
  Raspberry Pi DTBs e.g. `bcm2712-rpi-5-b.dtb` — again unrelated stock content, not project-specific).
- `system.dtb` present, dated Jul 4 14:11 (vs .146's Jun 12 00:38 — **different timestamps, but see
  below: content is structurally identical**).
- `uEnv.txt` **byte-identical** to .146's (same `adi_sdboot` U-Boot script, same `bootargs=` line).
- No `/boot/extlinux`, `fw_printenv` empty — same as .146.
- Same boot flow: U-Boot → uEnv.txt → load `Image` + `system.dtb` from FAT → `bootm`.

### 3. Kernel UIO support
Identical to .146:
```
CONFIG_UIO=y
CONFIG_UIO_PDRV_GENIRQ=m
CONFIG_UIO_DMEM_GENIRQ=m
CONFIG_UIO_XILINX_APM=y
```
No `uio_pdrv_genirq`/`uio_dmem_genirq` module loaded (`lsmod` empty for uio), no uio driver bound
under `/sys/bus/platform/drivers/`. Same 4 `axi-pmon` UIO devices at the same addresses.

### 4. Deployed devicetree
Full `dtc -I fs -O dts` dump matches .146 **structurally node-for-node**: same `axi_pl` block with
`mwipcore@9D000000` (no `interrupts` property), same 4 ADI `dma-controller@84A3/4/5/6xxxx` nodes with
the same `interrupts` cells (0x6a–0x6d), same `axi-adrv9002-*` front-ends, same `reserved-memory` with
`qpsk_byte_buf@7ff00000` sized `0x100000`. This confirms both boards run the **same PL bitstream /
system.dtb design** (same qpsk HDL build), just packaged onto two different root filesystems.

### 5. /proc/iomem, /proc/interrupts, /proc/cmdline, /proc/meminfo
Identical addresses and GIC SPI numbers to .146 for every PL peripheral (`7ff00000-7fffffff:
reserved`; dma-controllers at GIC SPI 138/139/140/141; `mwipcore` absent from `/proc/interrupts`).
`/proc/cmdline` identical string. Memory total not separately recorded but rootfs is otherwise a
match.

### 6. DMA carve
Identical mechanism and node to .146 — `reserved-memory/qpsk_byte_buf@7ff00000`, `no-map`, 1 MiB,
static in `system.dtb`, no `mem=` bootarg involved.

### 7. GIC SPI evidence
Same exact 4-row DT-cell → GIC-SPI (+32) mapping as .146 (109→141, 108→140, 107→139, 106→138) —
cross-board consistency confirms this is a fixed platform property of the shared bitstream/DTB, not
per-board drift.

### 8. UIO devices
Same as .146: `uio0..uio3`, all `axi-pmon`.

---

## Summary (answers a–e)

**(a) DTB file location + boot flow:** The deployed DTB is `/boot/system.dtb` on the SD FAT boot
partition (identical structure on both boards, different mtimes — .146 Jun 12, .148 Jul 4). Boot
flow is U-Boot (from `BOOT.BIN`) → `uEnv.txt`'s `adi_sdboot` script → `fatload` of `Image` (kernel)
to 0x3000000 and `system.dtb` to 0x2A00000 from the SD card → `bootm`. No extlinux, and `fw_printenv`
returned nothing on either board (env is file-based via `uEnv.txt`, not a U-Boot env partition/NAND).

**(b) uio_pdrv_genirq availability:** Built as a **kernel module** (`CONFIG_UIO_PDRV_GENIRQ=m`,
`CONFIG_UIO_DMEM_GENIRQ=m`) on both boards — not built-in, and **not currently loaded** (`lsmod`
empty, no driver bound in sysfs). Only `CONFIG_UIO_XILINX_APM=y` is built-in and active today,
backing the 4 existing `axi-pmon` UIO devices. Enabling generic-UIO IRQ delivery for the mwipcore
core will require the module to load (either via a DT node with `compatible = "generic-uio"`
triggering auto-load, or explicit `modprobe`) — a state-changing step, out of scope for this
read-only pass.

**(c) How the carve is reserved:** A static DT `reserved-memory` node named `qpsk_byte_buf@7ff00000`,
`reg = <0x0 0x7ff00000 0x0 0x100000>` (1 MiB), `no-map`. Confirmed against `/proc/iomem`
(`7ff00000-7fffffff : reserved`). No `mem=` cmdline argument is used; identical on both boards.

**(d) pl_ps_irq → GIC SPI evidence:** All four ADI `axi-dmac-1.00.a` DMA controllers feeding the
ADRV9002 rx/rx2/tx/tx2 datapaths show a clean, reproducible **GIC SPI = DT-cell + 32** relationship
(DT cells 106–109 → GIC SPI 138–141), confirmed identically on both boards via cross-reference of
the `dtc` dump against `/proc/interrupts`. Critically, **`mwipcore@9D000000` (the qpsk core) has no
`interrupts` property in the DT at all today** — it is not wired to any PL→PS IRQ line. Any
interrupt-driven DMA upgrade must add a new `interrupts = <0x00 N 0x04>` cell to this node (or a
new HDL-Coder-generated IRQ concat output) in `system.dtb`, choosing an SPI/cell not already
claimed by the 4 DMACs (cells 106–109) — exact free-slot enumeration needs the Vivado PL IRQ concat,
not visible from Linux alone.

**(e) Surprises:**
1. **.148 runs Debian trixie, .146 runs Kuiper/raspbian bullseye** — different userspace distros on
   what's otherwise the same hardware/bitstream/kernel build. Not something to assume symmetric in
   future scripting (e.g. package manager, `/etc/os-release` parsing, apt vs whatever Kuiper uses).
2. `mwipcore` (the qpsk HDL core the whole project is about) has **zero interrupt wiring** in the
   currently deployed DTB on both boards — the interrupt-driven-DMA upgrade is not a "flip a flag"
   change, it needs new DT content plus (likely) a PL bitstream regenerate to expose the IRQ pin,
   unless an existing unused concat input can be repurposed at the DT level.
2b. `uio_pdrv_genirq`/`uio_dmem_genirq` are compiled as modules but the actual `.ko` files were not
   found at the expected `/lib/modules/$(uname -r)/kernel/drivers/uio` path in either quick check —
   worth a `find / -name 'uio_pdrv_genirq*'` follow-up (still read-only) before assuming modprobe
   will "just work".
3. Both boards' `/boot` directories carry large libraries of **unrelated stock ADI/Raspberry-Pi
   DTBs** (fmcomms, zcu102, socfpga, versal boards, various rpi models) alongside the one that
   matters (`system.dtb`) — noise to filter out, not signal.
4. `/boot` on .146 contains dozens of `BOOT.BIN.<label>` snapshots (`.prelean`, `.pretap`,
   `.prerxfix`, `V15`…`V42`, etc.) confirming this is a live iteration/campaign board matching the
   git history in this repo — read-only recon did not touch/rename any of these.
5. Live `/proc/device-tree/chosen/bootargs` does not exactly match `uEnv.txt`'s `bootargs=` line
   (missing `console=ttyPS0,115200`, `rootfstype=ext4`, `cpuidle.off=1`) on both boards — some
   bootarg assembly/override is happening between uEnv and what lands in the DT chosen node; worth
   understanding before relying on either as ground truth for a future change.
