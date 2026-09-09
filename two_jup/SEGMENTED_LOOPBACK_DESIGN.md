# Segmented known-payload loopback — DESIGN ONLY (2026-08-11)

Localise the 26-frame burst at the host/DMA seam by placing **byte-accurate checkpoints
at three boundaries** and reading a `(byte_count, running_checksum)` pair at each. No
code written, nothing built, nothing flashed. This is the spec for review at 07:00.

## The discrimination this buys

| observation at a checkpoint | mode | meaning |
|---|---|---|
| checksum wrong, count right | **wrong bytes** | slicer / arithmetic / torn write |
| count frozen | **wedge / starve** | nothing is arriving at all |
| count advancing but slow | **feeder underfeed** | supply-side, not a loss |

**The first hop that shows corruption OR a stalled count localises the burst.** That is
the whole point: today the burst is only visible *after* the fact, as 25 host reads of
garbage in one frame period with `reg_packets` frozen — which is consistent with several
mechanisms and distinguishes none of them.

Prerequisite already satisfied: the burst **does not reproduce** in the bit-true netlist
on the identical samples (25 frames decode CRC-good, seq contiguous), so it is not an air
or decode event. It enters at or after the fabric→DMA handoff — exactly the span these
three checkpoints bracket.

---

## Checkpoint 1 — FABRIC OUT, before the DMA

**Tap point:** the `byte_rx` AXI-stream handshake, `byte_rx_valid && byte_rx_ready`, at
the ByteSerializer output — the last point inside the fabric before `axi_dmac` takes the
data. Signals already exist and are already surfaced on the tap wrapper
(`rtl_sim/wrap_byte_taps.v`): `byte_rx_data[63:0]`, `byte_rx_valid`, `byte_rx_last`,
`byte_rx_ready`, `byte_ready`.

**What exists today**

| counter | reg | counts |
|---|---|---|
| `packets_out` | `0x104` | framesyncs (advances even when every frame fails CRC) |
| `bit_errors_out` | `0x108` | BIST bit errors |
| `cap_out` | `0x144` | golden-pattern capture word |
| `rstcs_count` | `0x150` | carrier-sync resets |
| `cnt_frame_start` | — | frame starts (not surfaced to a mapped reg) |

**None of these is a byte count and none is a payload checksum.** `packets_out` counts
frame *starts*, so it cannot distinguish "frame emitted intact" from "frame emitted
short", and it is the counter that already fooled `lock_watchdog` into reporting LOCKED
through a total outage.

**What must be added** — and most of it is already drafted:

`jupiter_240k5_byte/framestat_overlay.m` (written, never built) already latches a 64-bit
per-frame record into a **64-deep side FIFO at unmapped `0x1D0–0x1DC`**, whose top field
is a **16-bit checksum over the delivered ByteSerializer words**. That is checkpoint 1's
checksum, already specified, with the register window already chosen to avoid collisions
(shipped regs end at `0x1B0`; `loop_gain` occupies `0x170–0x184` LEAN-only; P1B census
`0x1B4–0x1C8`).

Two additions to that overlay:

1. **A 32-bit word counter** on `byte_rx_valid && byte_rx_ready`, free-running, exposed at
   a new mapped register (proposed `0x1C0`). The user's requirement is *count AND
   checksum*; the overlay currently carries only the checksum. A free-running counter is
   also the cheapest possible wedge detector — frozen count is unambiguous.
2. **Widen the checksum to 32 bits** if a register is free. 16 bits misses a corruption
   1 in 65536; over 1245 frames/s that is a miss every ~53 s, which is the same order as
   the phenomenon being hunted.

**Cost:** requires an HDL rebuild and a flash. This is the only checkpoint that does.
It is therefore the one to **stage and review, not to build speculatively** — checkpoints
2 and 3 are host-side and may localise the burst without it.

---

## Checkpoint 2 — POST-DMA, before software touches the buffer

**Important correction to the framing of "in the driver":** there is no kernel driver in
this path. `qpsk_tun` mmaps the DMA buffer directly through `/dev/mem`
(`QPSK_TUN_RX_BUF_PHYS`), and the modem RX DMAC is at `0x9D200000` — *not* the ADI
`axi_adrv9001_rx1_dma` at `0x44A30000`. So checkpoint 2 is "the DMA-completed area, read
before any consuming code runs", not a driver hook.

**Tap point:** immediately after the completion test
(`dmac_rd(&rxd, DMAC_TRANSFER_DONE) & 1`, `qpsk_tun.c:792`) and **before**
`carve_copy_from()` (`qpsk_tun.c:1030`) copies the slice out.

**What exists today**

| counter | source | counts |
|---|---|---|
| `DMAC_TRANSFER_DONE` | `0x428` | per-transfer completion bit |
| `rxq_completions` | host | completed areas |
| `rxq_backlog_max/_sum` | host | ring occupancy |
| `rxq_zerohdr`, `rxq_zero_n` | host | slices that read back as never-written |
| `rxq_engine_gaps` | host | (known structurally unable to fire — see §5 of the handoff) |

So the **count** side of checkpoint 2 already exists (`rxq_completions` × slots-per-area
gives bytes). The **checksum** does not.

**What must be added:** a running checksum over the DMA'd area, computed *in place* on
the mapped buffer before `carve_copy_from`. Host-side only, no rebuild of the FPGA.

---

## Checkpoint 3 — TOP OF THE SOFTWARE RX QUEUE

**Tap point already exists.** `rx_raw_tap` was added for Layer B and sits at
`qpsk_tun.c:1032`, on the raw slice immediately before `qpsk_frame_decode` — pre-CRC,
pre-de-whiten. It is a function pointer, default NULL, so it is zero-cost when unset.

**What exists:** the PN scorer behind it (`qpsk_seq.c`) already classifies
`torn_zero / torn_stale / scattered / batch_drop` and reports `seq_span` vs `accounted`.

**What must be added:** just the `(byte_count, checksum)` pair alongside, so checkpoint 3
is directly comparable to 1 and 2 rather than being a different kind of measurement.

---

## Reading it without perturbing timing

This matters more than usual here: the campaign has already demonstrated that work added
in the drain path changes the behaviour under study — `rxq_drain_delay_us` was built
precisely to inject drain latency, and a 1500 µs/slice drain moved the failure mode.
A checksum in the same loop is exactly that kind of perturbation if done naively.

**Rules for the implementation:**

1. **Cheap checksum, no libraries.** A 64-bit XOR-fold with a rotate (`h = rotl(h,1) ^ w`)
   over the already-loaded 64-bit words. One ALU op per word on data that is being
   touched anyway. **Do not use CRC32** at checkpoints 2/3 — it is ~10× the cost and the
   goal is corruption *detection*, not error correction.
2. **Never allocate, never format, never syscall in the path.** Accumulate into a
   preallocated per-area struct; format only in the 5 s stats line or on `SIGUSR1`.
   The existing `rxq_stats_dump()` forward-declaration idiom already does this.
3. **Sample, don't saturate.** Checksum every Nth area (`N` from env, default 1 while
   hunting, raise if timing shifts). Report the sampling rate in the output so a partial
   count is never read as a total — the `crc_health`-is-a-ratio lesson.
4. **Measure the perturbation, don't assume it away.** The A/B is free: run with the
   checksum enabled and disabled and compare `rxq_pump_us_max` / `rxq_loop_us_max`, which
   already exist. If the max loop time moves materially, the instrument is changing the
   experiment and the sampling rate must come down.
5. **Checkpoint 1 costs nothing at runtime** — it is fabric-side, in parallel hardware,
   and is read out of a FIFO. That asymmetry is a reason to prefer it *if* a flash is
   authorised.
6. **DRA is a single address latch.** Any register reads for checkpoint 1 must be the
   only reader — stop `lock_watchdog` first. Two concurrent readers silently corrupt each
   other; that is how `biterr` once read back `cap_out`'s constant.

## Alignment across the three checkpoints

The three counters must be comparable or the whole scheme collapses into three unrelated
numbers. **Anchor on the frame sequence number, not on wall-clock and not on the counter
values themselves.** The PN payload carries `seq` in its header, and the `tap_replay_study`
work already had to re-anchor by seq rather than by `reg_packets` because the iio capture
started ~72 ms after the register read — a +89..90 frame offset. Same trap here.

## Payload

Use the **existing xorshift32 PN** from `qpsk_seq.c` rather than a counter: it is already
implemented, already scored, and catches stuck bits that a counter's low-entropy high
bytes would hide. `qpsk_seq_expected(seq)` regenerates any frame's expected bytes on
demand, so every checkpoint can verify independently without shipping a reference.

**Caveat carried forward:** the `-S` feeder currently sources ~55–59% of the air rate even
after the MMIO fix. Until that is closed, checkpoint 1 will legitimately see ~40% of slots
carrying frames the feeder never wrote. That is *expected* and must not be read as loss —
which is precisely why the count and the checksum must be reported as a pair.

---

## Build order (cheapest discriminating step first)

1. **Checkpoints 2 + 3, host-side only.** No FPGA work, no flash. If the checksum is
   already wrong at checkpoint 2, the corruption is at or before the DMA write and
   checkpoint 1 is needed. If checkpoint 2 is clean and 3 is wrong, it is in the host
   copy/drain path and checkpoint 1 is **not** needed at all.
2. **Checkpoint 1 only if 2 and 3 both come back clean** — that is the case that requires
   knowing what the fabric actually emitted, and only then is a flash justified.

This ordering matters: it can resolve the burst with **zero FPGA risk** in the two cases
out of three where the fault is at or after the DMA write.

## Open question for 07:00

Checkpoint 1 needs an HDL rebuild + flash of 146. The cyclic-mode work is already staged
and blocked on the same gate (the modem DMAC instantiation is still unidentified). If a
flash is going to happen, these two should be batched into one image and one netlist-gate
pass rather than two.
