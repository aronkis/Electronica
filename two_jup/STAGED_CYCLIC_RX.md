# STAGED (not built, not flashed): cyclic-ring RX needs `CONFIG.CYCLIC=1`

**For review 2026-08-10 07:00.** Nothing here was built or flashed. The overnight rails
were host-side only, and this is the one experiment that cannot be done host-side.

## Why it came up

The overnight brief asked to *"hold M=32 while deepening the ring to test the
headroom-vs-race hypothesis."* **That axis does not exist in the queued RX path.**

In `QPSK_RX_QUEUED` the ring is exactly **two areas of M slots** (`rx_q_id[2]`,
`rx_area_phys(area) = RX_BUF_PHYS + area*RX_MULTI_MAX*SLOT_BYTES`), and the axi_dmac
holds **one request ahead**. So ring depth is `2 x M` — the same knob as `-M`, not an
independent one. Adding more areas would not add outstanding depth either, because only
one request can be pending in the regmap; it would only add host drain slack.

The genuinely deeper ring already exists in the host app: `QPSK_RX_CYCLIC=1`
(`rx_arm_cyclic`/`rx_pump_cyclic`), one arm forever, `rx_ring_slots =
2*RX_MULTI_MAX*SLOT_BYTES / pkt_bytes` — and, critically, **no per-batch boundary at
all**. Since the measured loss is periodic *at the batch boundary*, a mode with no
boundaries is the decisive test of the mechanism, not just another sweep point.

## What the probe found

Ran it on the deployed image (host-side, no flash):

```
RX cyclic-ring mode ON -- REQUIRES a CONFIG.CYCLIC 1 bitstream
qpsk_tun stats: ... dma_rx_ok=0 crc_drop=0 ...
```

`dma_rx_ok=0` **and** `crc_drop=0` — nothing lands at all, not even corrupt frames. That
is the documented CYCLIC-0 behaviour: `FLAGS` bit0 is masked to 0, so the engine runs
one transfer and stops. The link gate saw `rev -1%` for all 12 tries while `fwd` stayed
100%, i.e. the failure is confined to the board running cyclic.

**Conclusion: the deployed bitstream is `CONFIG.CYCLIC=0`.**

## Register map (for your review)

Modem RX DMAC, offsets as used by `qpsk_tun.c`:

| offset | name | note |
|---|---|---|
| 0x080 | `IRQ_MASK` | re-applied per reset |
| 0x084 | `IRQ_PENDING` | W1C |
| 0x088 | `IRQ_SOURCE` | diagnostic |
| 0x400 | `CONTROL` | bit0 enable; 0 then 1 = reset |
| 0x404 | `TRANSFER_ID` | 0 after reset |
| 0x408 | `SUBMIT` | bit0 = request pending (one-deep) |
| 0x40C | `FLAGS` | **bit0 = CYCLIC**, bit1 = TLAST |
| 0x410 | `DEST_ADDRESS` | |
| 0x418 | `X_LENGTH` | bytes-1 |
| 0x428 | `TRANSFER_DONE` | per-ID completion bitmap, cleared at SOT, set at EOT |

**`FLAGS` bit0 is the only register bit involved, and it is already written** by
`rx_arm_cyclic()`. Nothing in the host register map needs to change. The gate is the
**synthesis parameter** `CONFIG.CYCLIC` on the `axi_dmac` instance, which masks bit0 to 0
when 0.

## Why it was not built

The `axi_dmac` instance is **not in this repo** — no `CONFIG.CYCLIC` appears anywhere in
`jupiter_240k5_byte/*.tcl`. It comes from the ADI reference design that provides
`axi_adrv9001`/`axi_dmac`, so flipping it is a **base-platform rebuild**, not an overlay
tweak like the loop-tune or TMR overlays. That is well outside "stage it, don't flash
it", so it was not attempted.

## What it would buy, and the honest caveat

- **If cyclic loss goes to ~0**: the mechanism is the per-batch boundary, confirmed
  directly, and cyclic (not small M) is the real fix — it removes boundaries entirely
  instead of just making them more frequent and individually cheaper.
- **If cyclic loss persists at a period near the ring depth**: the boundary is not the
  mechanism and the batch periodicity is a symptom of something else.

Caveat worth weighing before spending a build on it: cyclic mode changes the freshness
invariant. With no per-arm `carve_zero`, "valid CRC" no longer means "fresh slice" —
`rx_pump_cyclic` has to track freshness by sequence number and detect lap-overrun
(`st.seq_gaps`). That path is written but, on this rig, **has never executed a single
frame**. So a CYCLIC=1 build is testing new-to-hardware host code at the same time as
the hypothesis.

## Cheaper alternative already covered tonight

The `RXQ=0` legacy multi path re-arms per transfer and is a genuinely different
architecture. It is in the overnight rotation at M=16/32, which bounds how much of the
loss is specific to the queued path — without any rebuild. See the ranked table in
`RX_CONFIG_SWEEP_RESULTS.md`.


---

# Update 2026-08-10: the evidence now makes cyclic the *targeted* fix, not a curiosity

When this was first staged, cyclic mode was "the deep-ring arm we cannot reach". Overnight
measurement changed its standing: cyclic is now the option that directly removes the
mechanism we actually identified.

## What the mechanism turned out to be

Loss happens **only when the host stalls at a batch boundary**. No good frame in any
capture follows a >4 ms gap (0.00%); good frames arrive in exact 0.803 ms lockstep with
the fabric; 80-85% of loss episodes begin immediately after a multi-ms gap; and max
episode size equals M exactly, so damage never crosses a batch.

Crucially it is **starvation, not overflow**:
1. *Structurally* the DMA cannot overwrite an undrained slot -- an area is resubmitted
   only after its drain completes. Overflow is unreachable, not merely unobserved.
2. The failed slices read back as the `carve_zero` pattern (`host_seq==0`), i.e. **nothing
   was written**. An overwrite would have delivered a decodable frame with the wrong seq,
   not a CRC failure.
3. Forcing the drain slower raised PER **1.324% -> 5.945%**. Drain latency is causally on
   the critical path; a capacity problem would not care about drain *speed*.

## Why that points at cyclic specifically

The chain is: drain latency -> late re-arm -> engine unarmed -> frames arrive with no
destination -> zeros.

**Cyclic mode deletes the third link.** `rx_arm_cyclic()` arms **once** and the engine
re-issues forever with no host action in the transfer gap. There is no re-arm to be late
for, at any M. Every other mitigation only shortens the window:

| approach | what it does to the window | cost |
|---|---|---|
| `-M 16` (measured, 0.695%) | fewer/shorter boundaries | none; but window still exists |
| 4 areas (Task 1, running) | decouples re-arm from drain | none (4x16 < 2x32 carve) |
| **cyclic** | **removes the window entirely** | **base-platform FPGA rebuild** |

So cyclic is the only one that addresses the mechanism rather than its exposure -- which
is why it is worth the rebuild, and why it should be judged against the 4-area result:
if 4 areas already recovers most of the gap, cyclic buys the remainder plus robustness at
larger M.

## The honest caveat, restated and now more important

Cyclic changes the freshness invariant. Without the per-arm `carve_zero`, "valid CRC" no
longer means "fresh slice", so `rx_pump_cyclic` tracks freshness by sequence number and
detects lap-overrun via `st.seq_gaps`. **That path has never executed a single frame on
this rig** -- the probe showed `dma_rx_ok=0`, so it has never even been exercised once.

And note this cuts against the starvation finding in one specific way: cyclic is the ONE
mode where true **overflow becomes possible**, because the engine keeps writing whether
or not the host has drained. Today overflow is structurally impossible; under cyclic it
is structurally possible and is guarded only by `seq_gaps` bookkeeping that has never
run. A CYCLIC=1 build therefore trades a well-understood starvation failure for an
untested overflow failure. That is a real trade, not a free win, and it is the main
reason to review before flashing.

## Netlist survival gate

`run_netlist_gates.sh` is the mandatory pre-flash gate (no Vivado, no flashing):
checkhdl + makehdl -> golden byte vectors -> S1 ROM-path iverilog regression -> S1B
byte-path Verilator gate, plus the PI-shadowing netlist checks (no demod derotation
multiply, no poisoned 307 CS gain). Result recorded below.
