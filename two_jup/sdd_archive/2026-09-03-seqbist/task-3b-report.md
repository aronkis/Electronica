# Task 3b — is the G1 framing slip content-locked or timing-locked?

**VERDICT: CONTENT-LOCKED (marginal) — the slip requires BOTH frame 134's
payload content AND a sub-air-frame TX/RX phase alignment; removing either one
removes it. Sync-word collision offset: NOT LOCALISED.**

Both single-cause hypotheses are falsified by the run matrix below: the event is
not pure timing (blanking the payload with `fill=100` removes it at an unchanged
cadence) and not pure content (a 333,333-clock start-phase shift removes it with
the payload untouched). It behaves like a correlation peak sitting *at* the
detector threshold — either perturbation drops it below.

All numbers **[sim]**, harness `wrap_byte_seqbist` on the flashed-148 netlist
snapshot, `rx_seq_checker` 90d5430.

## What the slip actually is (byte-level, from the RX dump)

Delivered byte stream around the event (run E, `beat_runs/t3b_E_rxbytes.bin`):

| rx frame | bytes | content |
|---|---|---|
| 268 | 1528 | frame **seq 133**, perfect |
| 269 | **2400** | 872 bytes of all-zero filler **then frame seq 134's full 1528 bytes** — its header sits at intra-frame offset **872**, with no `user` mark of its own |
| 270 | 1528 | garbage (non-zero, no magic) |
| 271 | 1528 | frame **seq 135**, perfect; clean from here on |

So the defect is **a lost frame-start (`user`) mark plus a 656-byte (82-word)
data deficit**: across the span from frame 133 to frame 135 the byte plane
delivered 3,928 bytes where 4,584 were due. Sequence number 134 is never
presented as a frame start, which is exactly why the checker books it as
1 `garbage` + 1 `lost_slots` + 1 `gap1` — the instrument is right.

This is the delivery-plane damage class the COMB campaign is chasing, produced
here with **no radio, no DMA and no host** in the path.

## The three experiments

All runs: 350 checker frames (~175 emitted), gap 150,000, internal loopback.

| run | payload | TGEN start delay | slip? | where |
|---|---|---|---|---|
| A | fill 1516 | 0 | yes | seq 133→135, rx frame 269, clk 26,794,606, 2400 B |
| E | fill 1516 (separate build, +RX dump) | 0 | yes | **bit-identical to A** |
| D | fill **1200** (different len field + 316 payload bytes) | 0 | yes | **identical to A**: same seq, same rx frame, same clk, same 2400 B |
| C | fill 1516 | **1,234,567 clks** | yes | **same seq 134**, clk 27,978,574 — shifted by **1,183,968 = 12 × 98,664**, i.e. exactly 12 air-frame periods |
| B | fill 1516 | **333,333 clks** (3.38 air frames) | **no** | none through seq 180 |
| F | fill **100** (payload almost entirely zeros) | 0 | **no** | none through seq 150 |

Reading:

- **Not absolute-time-locked.** C's slip moved with the start delay, by exactly
  the integer part of it in air-frame periods.
- **Content is necessary.** F zeroed the payload from byte 100 on — the frame
  build cadence, frame size and gap are all unchanged, only the bytes differ —
  and the event vanished. D, which left payload bytes 0..1199 intact and only
  zeroed the tail, reproduced it *bit-identically*, so the trigger pattern lives
  in payload bytes ~100..1200 of the seq-134 frame.
- **Phase is also necessary.** B shifted the generator's start by 3.38 air-frame
  periods — not one payload byte changed — and the event vanished through 180
  frames, while C's 12.5-air-frame shift kept it on the same sequence number.
- Therefore **neither cause alone**: the event needs the data pattern *and* the
  alignment. That is the signature of a marginal correlation peak, not of a
  hard collision.

## Mechanism: a marginal false preamble detection fits, once the timing is read carefully

The TX chain is byte plane → `ByteBitShifter` → `FEC_Tx_Encoder_K5`
(`ConvEncK5` + `TxInterleaveK5`) → `Bit_Packetizer` → `HDL_Data_Scrambler`
(**hard-disabled**, `EnableScrambling_out1 = 1'b0`) → `QPSK_Modulator`. The
preamble the receiver keys on is in `Preamble_Bits_Store.v`: the 32-entry table
is `11111111110000111100110011` + 6 zero pad — the 26-bit (13-symbol,
Barker-13) sequence, prepended **after** FEC/interleave, so a data-dependent
false correlation would have to appear in the *coded, interleaved* stream.
That mechanism is real, the disabled scrambler is exactly what would have
prevented it, and the content dependence measured above says it is in play.

The *missing* frame start is not an argument against it once the frame timing is
read properly: a false detection late in the preceding (filler) frame starts a
receive window that spans frame 134's real preamble, so the true preamble is
never searched for — the receiver is busy — and frame 134's bytes are appended
to the frame already in progress. That is precisely the observed shape: the
filler is cut short at 872 bytes, frame 134 is delivered inside it with no
`user` mark, one garbled frame follows while the receiver re-acquires, and
frame 135 is clean.

**What is NOT established:** the offset of the colliding pattern. Localising it
needs a tap on the coded/interleaved bit stream and on the correlator magnitude
(`Peak_Search` `thresholdExceeded`), which the current harness does not export.
The phase co-factor is consistent with the free-running receiver timing chain —
`Preamble_Detector`'s 12,333-state timing reference against the
`Packet_Controller` `End_Generator`'s 12,320 states, the near-commensurate pair
already implicated in the SRO/interpolator work — setting where in the symbol
the correlator samples, hence whether the marginal peak clears the threshold.

## What this changes for the campaign

1. **`lost_slots` on a fabric-loopback leg is not automatically a real defect
   nor automatically an artefact**: this rail loses ~1 frame per 500 by itself.
   Any T2 null must be quoted against this baseline, and any T2 excess must be
   compared with a start-phase-shifted repeat before it is called a finding.
   Because the trigger is payload-dependent, a TGEN run and a mission-traffic
   run are **not** interchangeable evidence for this defect class.
2. **A start-phase sweep is a cheap, powerful discriminator on silicon too**:
   re-arm the TGEN at a different moment and see whether the loss moves with the
   frame index, stays at the same wall-clock offset, or vanishes. That
   distinguishes a content defect, a periodic radio process (the 26.0 ms comb)
   and a phase/beat defect with no build required.
3. **The disabled TX scrambler is now a live suspect, not a background fact.**
   `HDL_Data_Scrambler.v` has `EnableScrambling_out1 = 1'b0` and there is no host
   whitening on the fabric path, so payload bytes reach the modulator
   un-randomised — and a payload-dependent frame loss is exactly what this task
   measured. Re-enabling the scrambler (or turning host WHITEN on for a leg that
   allows it) is a cheap falsifier for the comb hunt: if a data-dependent false
   sync contributes to the 26.0 ms comb, whitening the payload must move or
   reduce it.

## Method notes

- `QSIM_TGEN_START_DELAY` (new, driver-only) holds the TGEN disabled for N
  clocks after reset: it moves the generator's phase against the free-running
  air-frame cadence **without changing a single payload byte**, which is what
  makes the content/timing separation clean.
- `QSIM_RXDUMP=1` (new, driver-only) saves every delivered RX byte for the
  byte-level forensics above.
- Neither touches Task 1's RTL; `qpsk_traffic_gen_v2.v`, `rx_seq_checker.v` and
  `cnt_mux32.v` are unmodified.

## Addendum — the decisive content test landed and reversed the interim verdict

The first version of this report (commit `5ea5ab0`) recorded **TIMING-LOCKED**
on the strength of runs A–E and explicitly flagged that run F, then still in
flight, would settle it and that the verdict must be revisited if F moved. F
(`fill=100`, payload zeroed from byte 100, everything else identical to A) ran
to 149 good frames with **no slip**, so content is necessary after all and the
verdict above is the corrected one. Recorded here rather than silently
overwritten: the interim call was made on incomplete evidence, and the run that
was pre-registered to test it is the run that overturned it.
