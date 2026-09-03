# f1536 bring-up results — lab session 2026-07-24/25

Hardware deployment + performance verification of the f1536 / UIO-DMA upgrade to
both Jupiter boards, per [DEPLOY_F1536.md](DEPLOY_F1536.md). Boards:
A = 10.0.0.148 (Debian trixie, glibc 2.41), B = 10.0.0.146 (Kuiper bullseye,
glibc 2.31). Transport `two_jup/anyssh.sh`. No remote power.

## Artifacts deployed (identities verified before every copy)

| Artifact | Identity | Notes |
|---|---|---|
| Kernel `Image` | sha256 `a1ba00b514319d8006d9555815e48427840c9291d785868da986feb5cbffe0b5` | 6.12.77 + `CONFIG_CMDLINE_EXTEND` baking `uio_pdrv_genirq.of_id=generic-uio`. Rebuilt this session (of_id delivery, below). |
| Image A `BOOT.BIN` | md5 `29b322c4f1299eec0b5f6470152faa6e` | 30.72 MHz fabric; 1.92 / 15.36 profiles only. Both boards. |
| qpsk `system.dtb` | per board (`system-qpsk.146.dtb` md5 `19e974098b6e`, `system-qpsk.148.dtb` md5 `1da3a9cf05a0`) | 2 MB carve @0x7FE00000, 3 qpsk UIO nodes, SPI cells 110/111. |
| host `qpsk_tun` | 2 MB-carve build (`-DQPSK_CARVE_2MB`), device-safe carve fix | built on-board per board. |

## Deployment — PHASE 1 (146) and PHASE 2 (148): COMPLETE + VERIFIED

Per-board full stack, one board fully verified before the next. Every reboot met
its post-reboot ssh window; rollbacks present at each step (`/boot/Image.preuio`,
`/boot/system.dtb.preqpsk`, `/boot/BOOT.BIN.pregeneric`).

| Check | 146 | 148 |
|---|---|---|
| kernel `uname -r` = 6.12.77 | PASS | PASS |
| `uio_pdrv_genirq.of_id=generic-uio` in `/proc/cmdline` | PASS | PASS |
| 2 MB carve `7fe00000-7fffffff` reserved | PASS | PASS |
| 3 qpsk UIO nodes bound (`qpsk_tx_dma@9d100000` etc.) | PASS | PASS |
| SPI 142 (tx) / 143 (rx) in `/proc/interrupts` | PASS | PASS |
| Image A `BOOT.BIN` md5 `29b322c4…` live | PASS | PASS |
| BIST `cap_out(0x144)` == golden `0x4922282` (read-only, no arm) | PASS | PASS |
| `rstcs(0x150)` == 0 | PASS | PASS |
| 2 MB carve guard (real 2 MB passes, synth 1 MB refused) | PASS | PASS |

## Three integration bugs found + fixed on hardware (all committed `-s`)

1. **of_id delivery** (`f7c2676`). These boards' effective `/proc/cmdline` comes
   from U-Boot's compiled default env — NOT `uEnv.txt`, NOT the on-disk dtb
   `/chosen/bootargs` (U-Boot rewrites `/chosen` at `bootm`; persistent mtd1 env
   invalid). Both runbook delivery mechanisms were dead. Fixed by compiling of_id
   into the kernel via `CONFIG_CMDLINE` + a new arm64 `CONFIG_CMDLINE_EXTEND`
   Kconfig entry (patch `jupiter_240k5_byte/boot/kernel-arm64-cmdline-extend.patch`),
   appended to the bootloader cmdline by `drivers/of/fdt.c`. `uEnv.txt` untouched.

2. **UIO name contract** (`bdf8b61`). Kernel 6.12.77's `uio_pdrv_genirq` names the
   UIO device WITH the @unit-address (`qpsk_tx_dma@9d100000`), not the bare
   node-name the campaign assumed. `uio_lookup`/`gpio_present`/`deploy_dtb.sh`
   did exact-match on the bare name → missed every device → qpsk_tun SILENTLY fell
   back to polled mode. Fixed to match name-exactly-or-followed-by-`@`. (Dropped
   deploy_dtb's `9d300000`-in-/proc/iomem check: generic-uio never
   `request_mem_region`s its maps.)

3. **Device-memory carve access** (`b492401`). The 2 MB DMA carve is mapped
   non-cacheable (`/dev/mem` O_SYNC = ARM64 Device memory). glibc ≥ ~2.34
   `memset`/`memcpy` emit `dc zva` / unaligned SIMD, illegal on Device memory →
   SIGBUS. Board 148 (glibc 2.41) faulted in `dma_open`→`rx_arm` right after "irq
   mode"; 146 (glibc 2.31) survived by luck. TX already used an aligned volatile
   word loop; gave the RX side + rx_arm the same via `carve_zero`/`carve_copy_*`.
   Verified: objdump of the 148 aarch64 binary shows no `bl mem*` / `dc zva` in the
   accessors; 148 reaches "irq mode" + READY with no SIGBUS.

## PHASE 3 — R0 over-air (Image A, 1.92 profile, both boards)

### f1536 upgrade wins — CONFIRMED
- Both boards enter **IRQ mode** on the live radio (`irq mode: uio2/uio1`), READY,
  tun0 at **MTU 1516**, watchdogs LOCKED (`drstcs=0`, no reset storm).
- **CPU: `qpsk_tun` = 0.6 %** on 146 — vs the OLD polled baseline ~100 %. This is
  the interrupt-driven-DMA **rearm win**: the old ~100 % was the poll-spin that IRQ
  mode genuinely removes. NOTE it was measured with `dma_rx_ok=0` (see deframe issue
  below), so it is the IRQ-mode idle/rearm cost, not a full-RX-decode-load figure —
  re-measure under a decoding link once the deframe issue is fixed. Still a decisive
  demonstration of the poll→IRQ CPU reduction (the headline goal).
- No SIGBUS under sustained traffic (carve fix holds); rearm stable.

### R0 link quality — BLOCKED: f1536 byte-deframe mismatch (RF/demod delivering)
| Test | Result |
|---|---|
| f1536 `-G` over-air (both boards) | RF **LOCKED** (watchdogs LOCKED, `drstcs=0`, no reset storm), `dma_tx` counting, but **`dma_rx_ok=0`, `crc_drop` climbing → 100 % CRC fail, 0 goodput**. |
| Raw RX frames — `QPSK_ATOMDBG=3` (both boards) | Every RX frame: **`magoff=-1 good_word_rot=-1`** — the 12-byte-header magic `0x51 0x4B` is **never found at any offset or rotation**. Raw hex shows **5 identical 8-byte words** at the frame start, then a periodic sequence that **repeats bit-slipped by 4 bits per period** (e.g. `163acb3c7dd06b6e` → `63acb3c7dd06b6ec`). |

**Interpretation:** the RF/demod IS delivering data — bytes arrive intact through
the (now-fixed) carve path — but the received bytes do **not** carry the f1536
byte-frame the host expects: no header magic, and a progressive per-period bit
slip. This is an **f1536 host↔fabric deframe / byte-alignment / frame-length
mismatch** (A2 RX-framing territory), **not** an RF/EVM problem and **not** the
carve fix. The first on-silicon exercise of the f1536 delivery contract
(WPP=191, 12-byte header at delivered byte 0, 68-bit discard seam).

**Why the K5 controls were discarded:** Image A's fabric is hardwired f1536
(f1536 message ROM / 1537×16 interleaver / EndGen span), so K5 host mode (`-F`
128 B, or `-B` replaying K5 goldens) mismatches the fabric **by construction** —
K5 "0 % clean / 100 % PHASE bucket" and K5-tun `dma_rx_ok=0` are expected
artifacts of that mismatch, not evidence about link health. Likewise a tun-mode
internal-loopback (0x114=0) is not a valid calibration (tun RX needs peer
framing; `-B` is the designed loopback scorer, and it is K5-only). The ATOM
raw-frame dump above is the valid, direct signal.

Suspects to chase (deframe layer), for the A2/RX-framing owners:
- host frame-parse offset vs the WPP=191 delivered-byte-0 / 68-bit-discard seam;
- f1536 frame length the RX DMA reads (`pkt_bytes=1528`) vs the fabric's true
  per-frame byte count (the 4-bit/period slip smells like a length/rate seam);
- whitening/endianness of the header path (magic never appears even rotated).
Quantitative RF confirmation if wanted: `two_jup/capture_evm.sh` tap → EVM ≈ the
C2 ~20 % floor would independently confirm "demod healthy, fault is deframe".
(Baselines when resolved: K5 ~68 kbit/s ceiling / ~65 ms RTT; f1536 envelope
~1.9 Mbit/s at 15.36.)

## Status at session pause
- Deployment (Phases 1-2) COMPLETE + verified on both boards; f1536 IRQ-DMA + CPU
  win demonstrated (the deployment mission is done).
- R0 clean-link acceptance BLOCKED on an **f1536 byte-deframe mismatch** (RF/demod
  proven delivering) → A2/RX-framing investigation, not RF/EVM.
- Did NOT run Phase 4 (15.36) or Phase 5 (Image B) — R0 must be understood first,
  and Image B is a coordinator/operator decision (hard stop).
- Both boards left quiesced, idle, healthy, on the full f1536 stack with rollbacks.

Backlog (future, non-blocking): kernel-provided coherent DMA buffer to replace the
`/dev/mem` O_SYNC + hand-rolled Device-memory access discipline.

## R0 over-air decode — ROOT CAUSE (session 2026-07-25, task-R0RF)

The R0 `magoff=-1` blocker was run down against hypotheses H1 (new adrv9002 driver),
H2 (constellation/EVM), H3 (framer at f1536 length), H4 (arm-state). **Root cause:
the f1536 OVER-AIR byte-frame delivery seam — a fixed 4-bit-per-frame byte-alignment
drift**, NOT an RF/driver/CFO fault. Discriminating on-hardware evidence:

- **EVM/CFO (mode-3 tap + software float demod on raw rx input, nemo MATLAB):** the
  raw receiver input carries a **fixed, dead-stable inter-board CFO** — reverse
  +4861 Hz, forward −5112 Hz, i.e. **+2.56 ppm** both directions (identical, scales
  exactly with carrier). Amplitude is fine (magEVM ~16%); the apparent EVM
  degradation is that CFO rotation. A clean antisymmetric ppm offset is a
  **reference-clock (crystal) difference** — 148 runs +2.56 ppm vs 146.
- **H1 (driver) REFUTED — two ways:** (1) both boards run the identical new driver, so
  any driver effect is common-mode and cancels in the board-to-board CFO — a driver
  cannot create a clean antisymmetric ppm offset. (2) A no-reboot **LO-trim** that
  nulled the reverse CFO (146 RX LO +4861 → CFO +4861→+10 Hz, carrier LOCKED:
  `cfc 0xA9E7→0x558`, `rstcs 0x1→0x0`) **did NOT restore decode** — `magoff` stayed
  −1. So the CFO is a real carrier stressor but **not the decode blocker**. The kernel
  rollback was therefore unnecessary (ppm math already exonerates the driver) and was
  not taken (brick-adjacent, no remote power).
- **Decode oracle (`qpsk_tun -G`, `QPSK_ATOMDBG=3`), the ground truth:** untrimmed AND
  CFO-nulled both give `magoff=-1`, `dma_rx_ok=0`, `idle_rx=0` (even idle frames fail
  to parse). The delivered bytes are a **coherent, periodic** bitstream (demod bits are
  consistent — low BER, not noise) whose **byte-word boundary drifts a constant 4 bits
  per frame period**. 4 bits / 64-bit word = 6.25% — three orders of magnitude larger
  than 2.56 ppm ⇒ **structural**, the arithmetic of the f1536 **68-bit discard seam**
  (68 = 64+4) against the 64-bit (8-byte) delivery word. The over-air frame-sync →
  `recStart` reference lands the byte serializer 4 bits off the byte boundary and the
  seam is not corrected, so alignment is never held; magic `0x514B` never lands
  byte-aligned.
- **Why the netlist "byte-rx golden" (RXALIGN) does not cover this:** that gate ran
  INTERNAL LOOPBACK (clean in-fabric framing) and never exercised the **over-air
  preamble-detect → frameStart/recStart** path that establishes byte alignment on air.
  This is the first on-silicon exercise of that path.

**Fix — needs an A2/RX-framing MODEL change + rebuild (HARD STOP).** No runtime
register/attr/driver fix exists (strongest candidates — init-cal, LO-trim CFO null —
tested and refuted). Spec for the RX-framing owner: build a **frame-sync-inclusive** RX
gate (not internal loopback) that drives preamble-detect → frameStart → recStart →
`qpskByteSerializer` with the 68-bit seam and asserts `recStart` lands on the byte
boundary and HOLDS across frames (no 4-bit/frame drift); audit where the 68-bit seam is
discarded in `fecRxAlign`/`recStart` vs the 64-bit word delivery. A **host-side bit-level
de-seam** in `qpsk_tun` (track+remove the fixed 4-bit/frame slip before
`qpsk_frame_decode`) is a candidate runtime mitigation but was NOT validated (injected
tun traffic did not traverse the down link, so no real over-air DATA frames were
captured). Secondary, non-blocking: the +2.56 ppm CFO is a genuine carrier stressor
(148 fwd RX `rstcs` storms) — once framing is fixed, confirm the fabric carrier loop
holds 2.56 ppm across 51 ms f1536 frames or widen acquisition.

Boards left QUIESCED (no qpsk_tun/watchdog; tun0 flushed), full f1536 stack intact,
rollbacks banked. Full evidence + capture artifacts: `scratchpad/task-R0RF-report.md`.

## R0 CORRECTION — the frame-start replication is a SEPARATE, HOST-MITIGABLE defect (task-PRIME, 2026-07-25)

The R0RF root-cause section above folds TWO distinct defects into one "68-bit discard
seam" story. On-hardware runtime experiments on board 148 (ROM internal loopback,
direct devmem of the frozen carve; `scratchpad/task-PRIME-report.md`) separate them:

- **The frame-start "5 identical 8-byte words" (the W0x5) is NOT the 68-bit seam.** It
  is a **byte-EGRESS artifact**: the axi_dmac S2MM re-samples the serializer wrapper's
  intentionally-held first beat (`byte_plumbing_overlay_k5.m` L181-193, "ADI S2MM source
  style", `ready=true`) **once per descriptor prime**, writing word[0] a fixed **5×**
  before its stream pointer advances (a 32-byte payload shift on clean 8-byte boundaries).
  It reproduces in **clean ROM loopback with NO CFO and NO over-air framing**, so it is
  independent of the air path. Structurally it is a **whole-64-bit-word** replication and
  therefore CANNOT be the **4-bit sub-byte** slip — the two are different mechanisms that
  merely **co-occur** in the over-air dump (this doc's own line 79: "5 identical 8-byte
  words at the frame start, THEN a periodic sequence bit-slipped 4 bits per period").

- **The W0x5 is per-descriptor-prime and rate-controllable at runtime.** Proven by the
  `-M` (packets-per-descriptor) cadence, with the gpio/TLAST confound isolated by `-M1`:
  | mode | prime cadence | gpio TLAST | dup |
  |---|---|---|---|
  | `-G` (legacy `-M0`) | every packet | on | **every frame ×5** |
  | `-G -M1` | every packet | off | **every frame ×5** |
  | `-G -M8` | 1 per 8 | off | **only slice 0 of each 8** (slices 1-7 clean) |
  | `-G -M32` | 1 per 32 | off | **only slice 0 of each 32** |
  `-M1` vs `-M8` share TLAST-off and differ only in prime cadence, so the dup tracks
  **prime cadence, not TLAST**. Silicon's "every frame" is simply legacy `-M0` priming
  every frame; it does **not** imply a fabric-intrinsic per-packet dup.

- **Mitigation ladder.** Runtime (no reflash): large `-M` amortizes the dup to `1/K` and
  the corrupt packet is deterministically slice 0 of each descriptor (reconstructable —
  drop the 4 stale word[0] copies). Complete fix (every packet clean) = **fabric**, at the
  L181-193 seam: qualify the wrapper's first-beat re-offer on an **accepted** beat
  (`valid&&ready` edge), not `valid`-held (one DDR write per FIFO dequeue at SOF).

- **HONEST LIMIT — necessary, not proven sufficient.** Removing W0x5 (via `-M`) did NOT
  restore `dma_rx_ok` in byte-source internal loopback (stayed 0 at `-M8/-M32`). That test
  is **inconclusive** on end-to-end decode (tun-mode internal loopback is not a
  designed-valid decode path — needs peer framing — and R0RF's separate over-air 4-bit
  body slip may co-exist). So: **W0x5 is necessary-to-fix and rate-controllable; it is NOT
  proven to be the sole R0 over-air blocker.** The periodic 4-bit body slip remains a
  distinct, over-air-only effect (R0RF's 68-bit-seam framing OR a carrier cycle-slip
  artifact — unresolved). Both should be addressed; fixing one does not presume the other.

Full evidence + captures: `scratchpad/task-PRIME-report.md` (board 148, quiesced after).
