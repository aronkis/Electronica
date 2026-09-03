# 15.36 MSPS scaling: `-M` SIGBUS root cause + fix proposal

Read-only investigation, 2026-07-21. Boards A=10.0.0.148, B=10.0.0.146.
No writes to board registers, no processes killed, live RF demo left untouched.
The `-M` crash was **not** reproduced live (demo in progress); the root cause below is
a *static* determination — the address baked into the deployed binary cross-checked
against the deployed bitstream's actual AXI address map. Confidence is high because those
two lines of evidence agree cleanly.

---

## 1. Root cause of the `qpsk_tun -F -M K` SIGBUS (exit 135 = 128 + SIGBUS/7)

**The deployed lean bitstream exposes no functional, driver-mapped `byte_ctrl_gpio` at
`0x9D300000`. `qpsk_tun -M` maps that address and does a 32-bit WRITE (`gpio_regs[0]=0`,
qpsk_tun.c:616-617) — the fault site is certain (see below); the reported symptom is a
synchronous external abort → SIGBUS from that store hitting a PL address with no properly
described AXI slave.**

**Certain vs. inferred.** The *fault site* is established: the offset-0 GPIO store is the
only access after `map_phys` (which cannot itself SIGBUS — it `exit(1)`s on `MAP_FAILED`),
and the disasm pins it exactly (§a). What is *inferred* (not directly confirmed, because the
crash cannot be reproduced during the live demo) is the precise failure mode — a clean AXI
decode error on the write. There is one data point that cuts against a clean decode error and
must be resolved by the T0 repro: see the board-B `0x00000001` anomaly in §(c). Either way,
the structural conclusion below (no described/mapped GPIO on the deployed image) holds; only
the exact hardware response to the write is open.

### Evidence

**(a) The binary's GPIO base is correct — this is NOT a mis-build (Branch "stale binary"
ruled out).**
Deployed `/root/host_app_k5/qpsk_tun`, disassembled on board A (aarch64), shows the exact
`-M` code path with the ZynqMP base immediate:
```
3244:  d2820002   mov  x2, #0x1000          ; map_phys len = 4096
3248:  52b3a601   mov  w1, #0x9d300000      ; GPIO_BASE
324c:  97ffff75   bl   3020 <map_phys>
3250:  b900001f   str  wzr, [x0]            ; *** gpio_regs[0] = 0  -> the faulting store
```
Board B (armhf build) carries the same literal in its pool (`.word 0x9d300000`).
`0x43C30000` (the ZedBoard base) has **zero hits** in disasm or strings on either board.
So `QPSK_GPIO_BASE` resolves to the intended `0x9D300000` (qpsk_hw.h:53) — the build is
not a ZED build and not a stale pre-GPIO build. mmap itself cannot be the fault:
`map_phys()` (qpsk_tun.c:176-185) calls `exit(1)` with a clean message on `MAP_FAILED`,
so a SIGBUS can only come from the subsequent access — the `str wzr,[x0]` above.

**(b) Nothing is mapped at `0x9D300000` in the deployed image.**
`/proc/iomem` (both boards) claims exactly one region in the 0x9D00_0000 window:
```
9d000000-9d00fffe : 9d000000.mwipcore
```
That is the MathWorks IP core (`compatible = mathworks,mwipcore-v3.00`), **64 KB only**,
ending at `0x9D00FFFE`. `0x9D300000` is **3 MB above** it and is **not a claimed Linux
resource**. The device tree has no gpio/axi-gpio node at or near `0x9D300000` (the only
GPIO in DT is the hard PS controller `ff0a0000.gpio`); `dmesg` shows no `axi-gpio` driver
bind; `/sys/class/fpga_manager/fpga0/state = operating` with no named overlay. On board B,
`dmesg` even shows two failed PL GPIO sysfs exports (`export_store: invalid GPIO 479 / 348`)
— something tried to reach PL GPIO lines that the running fabric does not present.

**(c) Reads there succeed, which is exactly why the existing guard is fooled.**
Safe `devmem` READs (no writes performed):
```
              0x9D300000    0x9D300004    0x9D30000C
Board A:      0x00000000    0xFFFFFFFF    0xFFFFFFFF
Board B:      0x00000001    0xFFFFFFFF    0xFFFFFFFF
```
No bus error on reads. The `0xFFFFFFFF` at +4/+C is the classic "no slave / read decode
default" pattern for an *unmapped* window. **Open anomaly (must be resolved by T0):** offset 0
differs per board (A=`0x0`, B=`0x1`) while +4/+C are uniformly `0xFFFFFFFF` on both. A purely
undecoded window would read a *uniform* default; a per-board, sticky offset-0 value that
happens to equal what `busybox devmem 0x9D300000 32 0x1` writes (board B was armed with that
line) suggests offset 0 may be a real 1-bit register retaining last-written state. If so, an
offset-0 *write* could succeed rather than decode-error — which would mean the failure mode on
some images is **not** a SIGBUS at all but a write that lands on a register **gating nothing**
(the TLAST gate is not wired into the DUT in the lean fabric) → `-M` would run and lose
packets silently instead of crashing. This does not change the structural conclusion (no DT
node, no driver, no iomem claim — §b), but it means the SIGBUS-vs-silent-dead-gate mechanism
is image-dependent and unconfirmed. Read-vs-write asymmetry is otherwise normal on ZynqMP PL:
an unmapped address can answer reads with a default while a write raises a decode error. Either
way, the read-based `-M` guard is fooled — this is precisely the trap
in `qpsk_net_setup.sh:58`, whose `-M` guard is a **read** probe
(`$DEVMEM 0x9D300000 32 >/dev/null 2>&1`): it returns success even though no GPIO exists,
so any path that then issues the write crashes. (`two_jup/link_test*.sh:141`'s
`busybox devmem 0x9D300000 32 0x1` is wrapped in `2>/dev/null; echo armed`, so its write
error — if any — is swallowed and it always prints "armed". "The arm works" is therefore
not evidence the GPIO is backed.)

**(d) `byte_ctrl_gpio` DOES exist in the full byte reference design — it was dropped from
what is deployed.** `jupiter_240k5_byte/complete_byte_t8.tcl:50` asserts the BD cells
`{byte_breakout rx_byte_breakout tx_byte_dma rx_byte_dma byte_ctrl_gpio}` are all present
(hard `exit 1` if any is missing). So the design *has* a `byte_ctrl_gpio`. But the bitstream
currently running on the boards presents only `mwipcore` (64 KB) on that interconnect — the
lean/stock image being run is not the full byte design, or its `byte_ctrl_gpio` AXI-Lite
port is not mapped at `0x9D300000` / not described in this DT. Net effect on the host is
the same: no writable slave at `0x9D300000`.

### One caveat to confirm during the fix (does not change the diagnosis)
The MathWorks `mwipcore` aperture in a full ADI reference design can be larger than the
64 KB the deployed DT advertises, and `byte_ctrl_gpio` could in principle be a sub-region of
the core's AXI aperture rather than a standalone AXI-GPIO. The deployed DT caps it at 64 KB
(`...00 00 ff ff`), so on *this* image `0x9D300000` is out of range regardless. Whoever
rebuilds the bitstream should read the generated address map (`.hwh`/`xsa` `assign_bd_address`)
to confirm the real base/aperture of `byte_ctrl_gpio` — the `0x9D300000` in `qpsk_hw.h:53`
is a header constant, not something I could verify against a generated address map in-repo.

---

## 2. Even with a working `-M`, can the host hit ~1.2 Mbit/s IP goodput at 15.36?

`-M` fixes the *CPU* bottleneck (spin → nap), but it is **not sufficient by itself** for
reliable 1.2 Mbit/s video. Two structural limits remain; both are tied to the 128-byte K5
frame geometry in fabric, not to a host knob.

**Frame geometry (from source):** K5 frame = 128 B = 12 B header + **116 B max payload**
(qpsk_tun.c:112 `K5_PKT_BYTES=128`, qpsk_frame.h:27-30). Initial frame period
`K5_FRAME_S = 4.72e-3` (qpsk_tun.c:114) ⇒ ~212 fps at 1.92 MSPS, ~**1680 fps at 15.36 (8×)**.

**Throughput ceiling.** 1680 fps × 116 B × 8 = **~1.56 Mbit/s** of payload if *every* frame
carried a full 116-byte data payload. 1.2 Mbit/s is ~**77 %** of that ceiling — a thin margin,
before any loss or per-frame IP/UDP overhead.

**Secondary bottleneck A — MTU-116 fragmentation amplifies loss (the big one).**
The tun MTU is `pkt - 12 = 116` (qpsk_net_setup.sh:61; qpsk_tun.c:897). A typical ~1400-byte
video packet fragments into **~13 IP fragments**, each = one 128-byte QPSK frame. IP
reassembly drops the **entire** datagram if **any one** fragment is lost, so datagram loss ≈
1 − (1 − p_frame)^13. Even p_frame = 1 % ⇒ ~12 % *datagram* loss. This is structural: the
116-byte MTU follows from the fabric frame size, not a host setting.

**Secondary bottleneck B — `-M` has structural per-transfer loss.**
`qpsk_net_setup.sh:48-49` and the `rx_pump_frame` design (qpsk_tun.c:438-454) note `-M`
loses ~1 packet per transfer at the S2MM rearm (the `SYNC_TRANSFER_START` realign);
`QPSK_SPIN_W` (default 6, qpsk_tun.c:313) spins the last W packets to mitigate but does not
eliminate it. Loss fraction ≈ 1/K, so large K helps loss — but large K raises latency and,
combined with fragmentation, still bounds usable video goodput. There is a real
loss-vs-CPU-vs-latency trade to tune (`-M K`, `QPSK_SPIN_W`, `QPSK_NAP_US`).

**Not bottlenecks (checked, ruled out):**
- *Idle-frame flooding* (qpsk_tun.c:1062-1076): the `while (tx_capacity())` idle fill runs at
  the *bottom* of the loop; real tun data is read and `tx_send`-ed at the *top*
  (qpsk_tun.c:962-988) with priority, so data preempts idle. Idle only fills slack to keep the
  modulator fed. Not a goodput killer.
- *`poll(..., timeout=0)`* (qpsk_tun.c:963): non-blocking busy-poll, but bounded by the
  `usleep(rx_nap_us)` nap (qpsk_tun.c:1087-1088, default 60 µs) whenever `-M` is not spinning —
  low CPU in multi mode.
- *TX depth* `MAX_INFLIGHT=2` (qpsk_tun.c:79): at ~596 µs/frame with a ≤60 µs reap cadence,
  2-deep is adequate; not the limiter.

**Bottom line:** the rearm cadence (CPU) is the *primary* bottleneck and `-M` is the right
fix for it, but MTU-116 fragmentation × residual per-transfer loss is a genuine *secondary*
bottleneck that `-M` alone does not solve. Success criterion must be measured **end-to-end IP
goodput**, not merely "`-M` stopped crashing."

---

## 3. Fix proposal — ordered cheap→expensive / high→lower confidence

### Fix 0 (immediate, zero-risk): stop the crash — make `-M` fail safe, not SIGBUS
The daemon writes the GPIO *blind* (qpsk_tun.c:615-617). Two independent hardening steps:

1. **Replace the false-positive read-probe with a real presence check.** The read probe in
   `qpsk_net_setup.sh:58` passes on unmapped PL. Gate `-M` on the *device tree / iomem*
   instead, e.g. require a claimed resource or a known-good marker before passing `-M`:
   ```sh
   # only enable -M if a real slave is mapped there (read defaults don't count)
   if [ "$MULTI" -gt 0 ] && grep -qi '9d300000' /proc/iomem; then
       DFLAGS="-p $PKT -M $MULTI"
   fi
   ```
   (Adjust the marker to whatever the corrected bitstream actually publishes — see Fix 2.)

2. **Make the daemon require positive presence, not merely survive a fault.** A `SIGBUS`
   handler is *insufficient on its own*: per the §(c) anomaly, on some images the offset-0
   write may **succeed** while gating nothing (the TLAST gate not wired into the DUT in lean
   fabric) — the handler never fires and `-M` runs with a dead gate, producing **silent packet
   loss** instead of a crash. So the daemon must gate `-M` on a **positive presence** check
   (a claimed DT/iomem resource, or a verified read-modify-write register behavior), and only
   *additionally* wrap the write in a `SIGBUS`-fallback for the decode-error case:
   ```c
   if (rx_multi) {
       if (!gpio_present())            /* DT/iomem claim at GPIO_BASE, NOT a bare read */
           { fprintf(stderr, "byte_ctrl_gpio not present; -M disabled\n"); rx_multi = 0; }
       else {
           gpio_regs = map_phys(memfd, GPIO_BASE, 0x1000);
           if (gpio_write_verify(gpio_regs) != 0)  /* SIGBUS-guarded + read-back check */
               { fprintf(stderr, "byte_ctrl_gpio not writable/effective; -M disabled\n");
                 rx_multi = 0; }
           else gpio_regs[0] = 0;      /* TLAST off */
       }
   }
   ```
   This turns both failure modes (hard SIGBUS *and* silent dead-gate) into a logged fallback to
   legacy. It does **not** deliver the scaling win — it just prevents the crash and the silent
   loss.

### Fix 1 (verify the address): confirm `byte_ctrl_gpio`'s real base in the deployed design
Before rebuilding anything, read the generated address map of whatever bitstream is
*supposed* to be deployed (the `.hwh` / `xsa` `assign_bd_address` for `byte_ctrl_gpio`, or
`show_bd_addr_seg` in the Vivado project from `complete_byte_t8.tcl`). If it is **not**
`0x9D300000`, the one-line fix is a corrected `QPSK_GPIO_BASE` in `qpsk_hw.h:53` (or a build
override `make CFLAGS+='-DQPSK_GPIO_BASE=0x....u'`) plus redeploy — cheap, no bitstream work.
Given the deployed DT shows *no* AXI-GPIO node anywhere, this alone is unlikely to be
sufficient, but it must be checked first because it is nearly free.

### Fix 2 (the real fix): deploy a bitstream that exposes `byte_ctrl_gpio`
The full byte reference design (`jupiter_240k5_byte/complete_byte_t8.tcl`) instantiates
`byte_ctrl_gpio`. The boards are currently running a lean/stock image that presents only
`mwipcore` (64 KB) on that interconnect. To get `-M`, the deployed bitstream must:
- instantiate the `byte_ctrl_gpio` AXI-GPIO (register 0 = per-packet TLAST gate: 1 = legacy
  per-packet TLAST, 0 = TLAST off so one S2MM transfer spans K packets),
- map its AXI-Lite port at the base the host expects (`0x9D300000`, or update `qpsk_hw.h:53`
  to match), and
- describe it in the device tree so `/proc/iomem` claims it (this is also what makes Fix 0's
  presence check reliable).

**This requires a Vivado bitstream rebuild + reflash and is explicitly out of scope for this
read-only investigation — do NOT flash during the demo.** It is the only path that actually
enables the CPU-scaling fix.

### Fix 3 (independent of the above): address the fragmentation ceiling for video
Even with `-M` working, do not expect reliable 1.2 Mbit/s video at MTU 116 without attention
to fragmentation (§2). Options for the human to weigh:
- Prefer an application/codec packetization that fits payloads to ≤116 B (avoid IP-layer
  fragmentation), or run a small MTU-aware UDP relay so a single lost frame drops only one
  media packet, not a 13-fragment datagram.
- If the fabric can be rebuilt anyway (Fix 2), consider a larger `DataBitsPerPacket` (bigger
  frame ⇒ larger MTU ⇒ fewer fragments) as part of the same bitstream change — this attacks
  the fragmentation ceiling at its structural source.
- Tune `-M K` / `QPSK_SPIN_W` / `QPSK_NAP_US` on the measured loss-vs-CPU curve.

---

## 4. Test plan (for a human to run **after the demo** — several steps are NOT read-only)

> DO NOT run any of this while the live RF demo is up. `link_test_1536.sh` arms radios and
> starts `qpsk_tun`; it must only run on an idle link. Nothing below should run during the demo.

**T0a — Confirm the diagnosis, read-only, CAN RUN NOW (no RF, no processes started):**
- On each board: `cat /proc/iomem | grep -i 9d3` → expect **no** claim at `0x9D300000` on the
  current lean image (confirms absence).
- `find /proc/device-tree -iname '*gpio*'` → expect only the PS `ff0a0000.gpio`.
- These greps do not touch RF, do not start `qpsk_tun`, and do not write registers.

**T0b — Reproduce/characterize the fault (POST-DEMO ONLY, idle link — do NOT run now):**
- Do **not** launch a second `qpsk_tun` while the live daemon is up: it contends for the
  singleton byte-DMA engines and, if the write does *not* fault (§c anomaly), execution falls
  through to `dmac_init()` (qpsk_tun.c:189, `DMAC_CONTROL=0` engine reset) + `rx_arm()`,
  resetting the DMA mid-demo — a live-link restart, which is forbidden.
- On an idle link only: run `/root/host_app_k5/qpsk_tun -F -M 16 -i tun0` and record whether it
  exits 135 (SIGBUS at the GPIO store) **or** starts and silently loses packets. This is the
  test that resolves the §(c) SIGBUS-vs-dead-gate open item, and it is why the daemon guard
  (Fix 0.2) must be positive-presence, not fault-catching alone.

**T1 — After the bitstream fix (Fix 2), verify the GPIO is real:**
- `cat /proc/iomem | grep -i 9d3` → now shows a claimed AXI-GPIO region.
- `devmem 0x9D300000` read returns a sane value AND (crucially) a write no longer faults:
  `busybox devmem 0x9D300000 32 0x1` completes without SIGBUS (do this on an idle link).
- `qpsk_tun -F -M 16` now starts and stays up instead of exiting 135.

**T2 — CPU-scaling check at 15.36 (idle link, then loopback/RF):**
- Arm the 15.36 profile via `two_jup/link_test_1536.sh` (idle link only). Run `-F` legacy vs
  `-F -M 16`; compare one-core CPU (`top`/`pidstat -p $(pgrep qpsk_tun)`) — expect legacy near
  100 %, `-M` a few %.

**T3 — End-to-end IP goodput (the real acceptance test):**
- With `-M` working at 15.36, measure sustained one-way IP goodput and loss with the built-in
  instrument `qpsk_perf` (host_app_k5/Makefile:26) or `iperf3 -u` sized to the video bitrate.
- Test at BOTH the tun MTU (116-byte payloads, no fragmentation) and at video-sized packets
  (~1400 B, ~13 fragments) to expose the fragmentation-amplified datagram loss from §2.
- Acceptance: sustained ≥1.2 Mbit/s IP goodput with datagram loss low enough for the codec.
  If T3 fails at ~1400 B but passes at ≤116 B, the residual limiter is fragmentation (Fix 3),
  not the rearm cadence.
- Sweep `-M K` (e.g. 8/16/32), `QPSK_SPIN_W`, `QPSK_NAP_US` to find the CPU/loss knee.

---

## Key file:line references
- `host_app_k5/qpsk_tun.c:615-617` — the `-M`-only GPIO map+write (the SIGBUS site).
- `host_app_k5/qpsk_tun.c:176-185` — `map_phys` (exits cleanly on mmap fail; not the fault).
- `host_app_k5/qpsk_hw.h:52-54` — `QPSK_GPIO_BASE 0x9D300000` (ZynqMP default; correct in binary).
- `host_app_k5/qpsk_net_setup.sh:58` — the false-positive `-M` read-probe guard.
- `host_app_k5/qpsk_net_setup.sh:34-37` — modem regs are mwipcore-only (not devmem); context.
- `two_jup/link_test_1536.sh:141` — `busybox devmem 0x9D300000 32 0x1`, error swallowed.
- `jupiter_240k5_byte/complete_byte_t8.tcl:50` — full byte design DOES instantiate `byte_ctrl_gpio`.
- `host_app_k5/qpsk_tun.c:112,114` — `K5_PKT_BYTES=128`, `K5_FRAME_S=4.72e-3` (geometry/goodput).
- `host_app_k5/qpsk_tun.c:1062-1076` — idle keepalive (ruled out as goodput limiter).
- Deployed `/root/host_app_k5/qpsk_tun` disasm: `mov w1,#0x9d300000; bl map_phys; str wzr,[x0]`.
- Deployed `/proc/iomem`: `9d000000-9d00fffe : 9d000000.mwipcore` (64 KB; nothing at 0x9D300000).
