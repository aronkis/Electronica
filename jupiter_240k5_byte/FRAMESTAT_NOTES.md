# FRAMESTAT -- per-frame RX status telemetry (handoff spec)

`framestat_overlay.m` emits ONE 64-bit status record per RX frame, latched at the
frame strobe and buffered in a 64-deep side FIFO exposed at AXI **0x1D0-0x1DC**.
The record carries the internal RX state at frame completion so the host can
localize *which* frame each error hit and, via the payload checksum, discriminate
**post-decode transport corruption** from **upstream channel/decode** loss.

This file is the handoff spec for the host workstream (`host_app_k5/qpsk_tun.c`,
`qpsk_hw.h`) -- which this overlay does NOT touch.

---

## 1. Record bit-layout (64-bit, little-word split LO=[31:0], HI=[63:32])

| bits    | field              | source / meaning                                             |
|---------|--------------------|--------------------------------------------------------------|
| [7:0]   | `frame_seq`        | low 8 bits of `packets_out` (0x104) -- host frame-align tag   |
| [8]     | `cs_reset_in_frame`| `rstcs_count` (0x150) changed since the previous strobe       |
| [9]     | `stall_in_frame`   | `framestat_stallcnt` (0x1C4) changed since the previous strobe = a `byte_rx_valid && !byte_rx_ready` stall cycle hit this frame's delivery window (direct backpressure witness) |
| [10]    | `txur_in_frame`    | `framestat_txurcnt` (0x1C8) changed since the previous strobe = a TX ByteBitShifter underflow reload (modulator starved, zeros aired) in the window |
| [11]    | `sync_low_margin`  | quantized Peak Search `runningMax` < `CORR_FLOOR`             |
| [15:12] | reserved (0)       |                                                              |
| [23:16] | `corr_strength`    | quantized Peak Search `runningMax` = MSB position (0..32)     |
| [31:24] | `agc_level`        | `adc_forensic` levelLog (0x15C [31:24], 0..16); **0 in LEAN** |
| [47:32] | `cfc_snapshot`     | `cfc_est` (0x154) bits [20:5] (top-16 of sfix21_En21)         |
| [63:48] | `payload_checksum` | 16-bit sum of the bytes of the delivered RX 64-bit words      |

`corr_strength` quantization = bit-position of the MSB of the `runningMax`
stored-integer (SI of sfix32_En26), i.e. `floor(log2(runMax))+1`, range 0..32.
`sync_low_margin` fires when that position `< CORR_FLOOR` (default **20**,
TUNABLE at the top of `framestat_overlay.m`; refine against on-air peak levels).

`cfc_snapshot` host decode: take the 16-bit field as `int16`, then
`normEst ~= double(int16(cfc_snapshot)) / 2^16` (sfix16_En16 -- bits [20:5] of the
sfix21_En21 estimate; low 5 fractional bits dropped). NOTE: `cfc_est` (0x154) is
a signed estimate carried as a stored integer; the overlay SI-reinterprets it to
ufix32 then slices [20:5], so the field's bit15 is the estimate's sign bit. The
sign handling (whether the 0x154 register is sign-extended above bit 20) MUST be
confirmed in the sim gate before trusting the sign on silicon -- do not decode it
blindly. `agc_level` in LEAN is pinned 0 (adc_forensic/0x15C is stripped there).

---

## 2. AXI access protocol (0x1D0-0x1DC)

| offset | dir  | name               | semantics                                            |
|--------|------|--------------------|------------------------------------------------------|
| 0x1D0  | R    | `framestat_head_lo`| record[31:0] of the FIFO head. **Non-popping.**      |
| 0x1D4  | R    | `framestat_head_hi`| record[63:32] of the FIFO head. **Non-popping.**     |
| 0x1D8  | R    | `framestat_stat`   | `{overflow_count[31:16] | level[15:0]}`               |
| 0x1DC  | W    | `framestat_pop`    | write a **changed** token to advance the read pointer|
| 0x1C0  | R    | `framestat_wordcnt`| FREE-RUNNING 32-bit count of accepted byte_rx words (`byte_rx_valid && byte_rx_ready`), wraps mod 2^32 |
| 0x1C4  | R    | `framestat_stallcnt`| FREE-RUNNING 32-bit count of byte_rx STALL cycles (`byte_rx_valid && !byte_rx_ready`), wraps mod 2^32 -- the DIRECT witness of inter-transfer DMAC backpressure (`two_jup/FWD_SINGLES_ROOT_CAUSE.md`) |
| 0x1C8  | R    | `framestat_txurcnt`| FREE-RUNNING 32-bit count of TX byte-FIFO underrun EVENTS (ByteBitShifter underflow reload: aligned, at a reload point, FIFO empty -> zeros aired, alignment dropped), wraps mod 2^32 -- the ~72 us TX-mute witness. One event ~= one zero-aired frame remainder (event count, not cycle count: the shifter's underflow branch fires once, then the realign sequence idles). |

`framestat_wordcnt` (0x1C0) is checkpoint-1's word COUNT
(`two_jup/SEGMENTED_LOOPBACK_DESIGN.md`): the host differences successive reads
to get words-delivered-per-interval; a frozen count is an unambiguous wedge
verdict. **0x1C0/0x1C4/0x1C8 collide with `p1b_pc_w1`/`p1b_pc_w2`/`p1b_pa_w1`
in non-LEAN debug builds** (the p1b census 0x1B4-0x1C8 is the only other
claimant of these offsets in `hdlworkflow_loopback.m`) -- `framestat_overlay`
hard-asserts p1b absence, so framestat builds must be LEAN (the instrument
images are).

Witness rails (N2 2026-08-12): `framestat_stallcnt` counts on the SAME
30.72M composite rails as the word counter, condition inverted
(`valid && !ready`); the per-record `stall_in_frame`/`txur_in_frame` bits do
NOT use a clear-on-strobe sticky (cross-rate clear/latch race) -- FrameStatProbe
latches each counter through a RateTransition and compares
changed-since-last-strobe, the same idiom as `cs_reset_in_frame`. A stall
landing in the RT-latency cycles at a frame edge attributes to the next record
(bounded boundary skew; the free-running counters are skew-free ground truth).
The TX underrun tap is inside the ByteBitShifter wrapper (env-gated chart
edit): underflow reload = the only aligned->unaligned transition WITHOUT a pop
(`qpskByteBitShifterStrict.m`), so `txur = wasAligned && ~aligned && ~pop`. Checksum width stays **16-bit**: the 64-bit record
has only 4 reserved bits left ([15:12]; [10:9] became the N2 stall/txur
witnesses), so the design doc's "widen to 32-bit
if the record layout allows" is not realizable without evicting a field; the
0x1C0 counter covers the drop/wedge class instead.

`level` = current FIFO fill (0..63). `overflow_count` saturates at 65535; it
increments each time a record arrives while the FIFO is full (drop-**newest**, so
the oldest un-drained records survive for in-order draining).

### Per-EOT drain (host side)
```
stat  = rd32(0x1D8);
level = stat & 0xFFFF;
for (i = 0; i < level; i++) {
    lo = rd32(0x1D0);
    hi = rd32(0x1D4);
    record = ((uint64_t)hi << 32) | lo;     // parse per the layout above
    wr32(0x1DC, ++pop_token);               // advance to the next record
}
// (stat >> 16) is the overflow count -- nonzero => host fell behind the FIFO
```

### CAVEAT -- "0x1D4 read pops" is NOT realizable in-DUT
The brief specified 0x1D4 as a READ that pops the FIFO. HDL Coder AXI4-Lite
**mapped outports are sampled readbacks -- a read produces NO strobe back into
the fabric** (confirmed by every reference overlay; the JUPITER regmap is a
unified space where an offset is either a read outport or a write inport, never
both). So the pop is instead an explicit **write to 0x1DC** (`framestat_pop`),
edge-detected on token change inside `FrameStatFifo`. If the reference-design AXI
wrapper is later enhanced to emit a 1-cycle strobe on the 0x1D4 read transaction,
drive `framestat_pop` from that wrapper strobe and free 0x1DC; the DUT already
advances on any change of that input, so no model change is needed.

`framestat_pop` (0x1DC) is an ADDITION beyond the brief's 3-offset transport --
see the deviation note in the report. 0x1CC is left free.

---

## 3. Checksum contract (the load-bearing field)

`payload_checksum` is computed **in fabric over the DELIVERED RX 64-bit words**,
tapped at the `ByteSerializer` output (the `word` + `wordTog` stream). On each
emitted word, the fabric adds the word's **eight bytes** into a 16-bit modular
accumulator; the accumulator resets each frame at the strobe. If the byte FIFO /
DMA / bus / host transport corrupts or drops a delivered word, the host's
checksum over the received bytes will NOT match the fabric's -- that mismatch
localizes **transport** corruption/loss; a match with a byte error localizes it
**upstream** (channel/decode).

Algorithm (host MUST mirror exactly), per frame:
```
acc = 0;
for each received 64-bit word w:
    for bpos in {0,8,16,24,32,40,48,56}:
        acc = (acc + ((w >> bpos) & 0xFF)) & 0xFFFF;   // sum the 8 bytes
// compare acc to FS_PAYLOAD_CKSUM(record) for this frame_seq
```

### Why the delivered words, NOT `recBit` (deliberate deviation)
The brief's deliverable-1 said "checksum over `recBit`", but the record-layout
prose said "over the delivered RX 64-bit words" -- and they are **not the same
data**: `ByteSerializer` delivers only the **first `WordsPerPacketRx*64` = 1024
(k5) of the 1084** decoded info bits (the trailing 60 are dropped by start-reset;
see the `ByteSerializer` chart header). A checksum over all `recBit` would cover
60 bits the host never receives, so it would mismatch on **every clean frame**
and the discriminator would be worthless. Checksumming the delivered words is (a)
verbatim the record-layout prose, (b) byte-order-agnostic (whole 64-bit words --
no MSB/LSB-packing ambiguity to reconcile against `qpskByteSerializer`), and (c)
also catches `ByteRxFifo` drops as transport loss (with the shipped FIFO fix,
`byte_fifo_ovf`/0x1B0 == 0, no drops, checksums match). The `sim_byte_inject`
gate (Section 6) is still the source of truth that fabric and host agree.

### Whitener caveat (moot in k5)
The brief's note ("fabric sees WHITENED wire bytes; host de-whitens after") does
**NOT apply to this k5 kit**: the scrambler AND descrambler are both removed
(`fec_remove_scrambler` + `fec_nodescr`; `README_BYTE.md` confirms whitening is
inactive). The delivered words equal the decoded payload -- **the host checksums
the raw received bytes, NO de-whitening**. If a future config re-enables
whitening, the fabric already checksums the whitened wire words the host
receives, so the host still checksums its RAW **pre-de-whiten** buffer to match.

---

## 4. QPSK_FRAMESTAT env gate + G0 story

The whole overlay is gated by the `QPSK_FRAMESTAT` env var, with an **early
return** at the top of `framestat_overlay.m` (before any block op). With it unset
the assembled model is **byte-identical to today** (G0). It is orthogonal to
LEAN/debug: 0x1D0-0x1DC are free in both images, so framestat can ship in the
LEAN production image AND coexist with the debug telemetry -- and never collides
with `loop_gain_axi_overlay` (0x170-0x184, LEAN-only). Applied at assemble Phase
2.19, AFTER `byte_rxfifo_overlay` and `loop_gain_axi_overlay`, so the composite
port set and the p1d `runningMax` tap are stable. `agc_level` is
**block-existence-guarded**: it branches `adc_forensic` when present (debug) and
pins 0 in LEAN (adc_forensic 0x15C is stripped there).

---

## 5. Host side (`qpsk_hw.h`, the OTHER workstream must add)

```c
/* --- framestat per-frame telemetry FIFO (0x1D0-0x1DC) --- */
#define QPSK_REG_FRAMESTAT_HEAD_LO 0x1D0u  /* R, non-popping, record[31:0]  */
#define QPSK_REG_FRAMESTAT_HEAD_HI 0x1D4u  /* R, non-popping, record[63:32] */
#define QPSK_REG_FRAMESTAT_STAT    0x1D8u  /* R, {ovf[31:16]|level[15:0]}   */
#define QPSK_REG_FRAMESTAT_POP     0x1DCu  /* W, write changed token = pop  */
#define QPSK_REG_FRAMESTAT_WORDCNT 0x1C0u  /* R, free-running accepted byte_rx
                                              word count, wraps mod 2^32.
                                              LEAN-only (0x1C0 = p1b_pc_w1 in
                                              non-LEAN debug builds) */
#define QPSK_REG_FRAMESTAT_STALLCNT 0x1C4u /* R, free-running byte_rx STALL
                                              cycle count (valid && !ready),
                                              wraps mod 2^32. LEAN-only
                                              (0x1C4 = p1b_pc_w2 non-LEAN) */
#define QPSK_REG_FRAMESTAT_TXURCNT 0x1C8u  /* R, free-running TX byte-FIFO
                                              underrun EVENT count (shifter
                                              underflow reload -> zeros aired),
                                              wraps mod 2^32. LEAN-only
                                              (0x1C8 = p1b_pa_w1 non-LEAN) */

/* record field masks/shifts (apply to the 64-bit reassembled record) */
#define FS_FRAME_SEQ(r)      ((uint8_t)((r) & 0xFFu))
#define FS_CS_RESET(r)       (((r) >> 8)  & 0x1u)
#define FS_STALL_IN_FRAME(r) (((r) >> 9)  & 0x1u)
#define FS_TXUR_IN_FRAME(r)  (((r) >> 10) & 0x1u)
#define FS_SYNC_LOW(r)       (((r) >> 11) & 0x1u)
#define FS_CORR_STRENGTH(r)  (((r) >> 16) & 0xFFu)
#define FS_AGC_LEVEL(r)      (((r) >> 24) & 0xFFu)
#define FS_CFC_SNAPSHOT(r)   ((int16_t)(((r) >> 32) & 0xFFFFu))
#define FS_PAYLOAD_CKSUM(r)  ((uint16_t)(((r) >> 48) & 0xFFFFu))

/* STAT accessors */
#define FS_STAT_LEVEL(s)     ((s) & 0xFFFFu)
#define FS_STAT_OVERFLOW(s)  (((s) >> 16) & 0xFFFFu)
```

Per-EOT drain: read STAT, drain `level` records (LO then HI, then bump the
`framestat_pop` token per record) as in Section 2. The host recomputes the
16-bit checksum over the received info-bit stream (Section 3 algorithm) and
compares to `FS_PAYLOAD_CKSUM` for the frame identified by `FS_FRAME_SEQ`.

---

## 6. Gate plan (run LATER -- NOT run here; a shared MATLAB is in use)

1. **G0 bit-identical (env-unset).** With `QPSK_FRAMESTAT` unset, assemble +
   `checkhdl` + generate; the RTL must be byte-identical to the pre-framestat
   baseline (the early return proves it structurally; the gate proves it in the
   emitted sources). Run `SIM_BYTE_GATE_K5` / `checkhdl_gate_240k5_byte` unset.
2. **Record-correctness gate (env-set).** With `QPSK_FRAMESTAT=1`, in
   `rtl_sim/sim_byte_inject.cpp` inject a known error class and assert the
   matching field:
   - post-decode transport corruption (flip a delivered byte AFTER `recBit`) ->
     `payload_checksum` mismatches the host recompute, all other fields nominal;
   - forced carrier-sync reset -> `cs_reset_in_frame == 1` on the hit frame;
   - low-SNR / no-lock burst -> `sync_low_margin == 1`, `corr_strength` drops;
   - confirm `frame_seq` == the injected frame's `packets_out & 0xFF`, and that
     the FIFO drains in order with `overflow_count == 0` when kept up with.
   This gate also LOCKS the checksum bit-order (fabric vs host) -- verify it here
   before trusting the field on silicon.
3. **checkhdl / codegen (env-set).** `checkhdl` clean; confirm the 4 ports map to
   0x1D0/0x1D4/0x1D8/0x1DC and that `framestat_pop` is NOT erased (non-dangling).
   Watch for rate-domain warnings on the `FrameStatProbe` inputs (the composite
   register taps vs the recBit rail rate) -- all are expected in the 15.36 MHz
   enb domain; a rate-transition warning here means a tap needs isolation.

---

## 7. BUILD RESULTS -- f1536 instrument netlist, 2026-08-12 (Track H, off-hardware)

Both runs: `QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4` (Image-B geometry),
`checkhdl_gate_240k5_byte.m` (assemble + Update + checkhdl + makehdl + HDL greps).

| run | env | checkhdl | makehdl | geometry evidence |
|---|---|---|---|---|
| baseline | FRAMESTAT unset | 0 err / 1 warn | 149 .v | End_Generator `count to 12319`; ByteSerializer `16'd191`; RxDeint/TxInterleaveK5 carry 1537; ROM word0 1204774986; zero k5 leftovers |
| instrument | `QPSK_FRAMESTAT=1` | 0 err / 1 warn | 153 .v | same geometry greps PASS; ports `framestat_head_lo/hi/stat/pop/wordcnt` all in `TxRxComposite.v` (pop NOT erased) |

**Additive-delta proof (G0 supporting evidence):** vs the baseline netlist,
144/149 files are byte-identical modulo the `// Created:` date header; the only
changed files are exactly the fs_runmax surfacing chain + composite
(`Frequency_and_Time_Synchronizer.v Preamble_Detector.v QPSK_Rx.v Receiver.v
TxRxComposite.v`) and the 4 new modules (`FrameStatChecksum/Probe/Fifo/WordCnt.v`).
G0 proper (env-unset build identical to pre-framestat) additionally holds
structurally: with `QPSK_FRAMESTAT` unset the overlay is never invoked by
assemble, and the workflow mappings are block-existence-guarded.

**S1B netlist byte gate (gate a):** frame-aware suite per RXALIGN, sps4 clk
budget `100 + 16*(13+12320)*4*2` (the historical 12-frame budget is 1 frame
short of the `packets >= pkLate+4` steady-state margin at sps4 startup).
BASELINE netlist: rot0 + rot17 PASS -- cap_out golden 0x04922282, 12 golden
191-word byte-rx packets, magoff=gwr=0, air oracle N/A (known dead modulator
tap in f1536 netlists, RXALIGN dead-tap rule; correctness rests on
cap_out(BIST)+byte-rx). INSTRUMENT netlist: same runs repeated -- see
`S1B_GATE.txt` (final on-disk = instrument run).

**Tap netlist at R3 (Track-H blocker closed):** `rtl_sim/obj_byte_taps_f1536/
Vwrap_byte_taps` verilated from the instrument f1536 netlist (0 errors; all
`wrap_byte_taps.v` hierarchical stage-tap references elaborated). The S1
iverilog ROM regression stays DEFERRED at f1536 (k5-ROM-locked TB, per
`run_full_gates_t8.sh`).

Deviation from the design doc: word counter landed (0x1C0); checksum stays
16-bit (record layout has only 6 reserved bits -- see Section 2 note).

---

## 8. N2 WITNESS IMAGES v2 -- build+gate results, 2026-08-12/13 (overnight, NO flash)

Both images carry BOTH witnesses (stall 0x1C4 + TX underrun 0x1C8, record bits
[9]/[10]) from the single KIT overlay. Builds: `build_cyclic_image.sh` with
`QPSK_BUILD_DIR` override, separate fresh dirs. The initial Vivado runs were
killed externally mid-impl; both were resumed surgically (impl+bit+bootgen +
the verbatim dual-DMA steps) -- resume logs `n2_*_resume*.log`.

| image | env delta | BOOT.BIN (untracked) | md5 |
|---|---|---|---|
| 148-v2 LEAN | QPSK_LEAN=1 QPSK_FRAMESTAT=1 | `jupiter_byte_fsv2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` | `f2e22135b134cf021ce9258c8221cfde` |
| 146 TMR-mirror | + CANARY_T85=1 LOOP_GAIN_AXI=0 CANARY_TAOPS=1 MOVSUM_TMR=1 LOOP_TUNE=1 ADC_FORENSIC=1 (asrun_433fd8da MANIFEST env) | `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` | `4be9286ca111be4865c6f2c8fe849705` |

Gate matrix (per image): checkhdl **0 errors** both; S1B (sps4 16-frame
budget) **PASS** both; `CYCLIC_RXBYTE_OK` CONFIG.CYCLIC=true both;
DUALDMA_VALIDATE_OK + CH2_BUILD_DONE both; overlay banners (stall/TXUR/DONE)
in both matlab logs. **REAL-IQ REPLAY GATE: FAIL on BOTH (5/78 packets, 0
CRC-good** on the pinned hunt chunk 270-339 vs Jul-25 netlist 77/78) --
the pre-existing dirty-slx Symbol/Carrier Synchronizer regression, identical
signature to `two_jup/floatgap_n3` (S1B does not cover it). **NEITHER IMAGE
IS FLASH-ELIGIBLE** until the model reconciliation (morning item).
Rate fix shipped this run: FsAgcRT isolates the full-rate adc_forensic feed
into FrameStatProbe (first non-LEAN framestat build died at model init
without it).
