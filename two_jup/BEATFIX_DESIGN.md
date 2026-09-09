# BEATFIX — two fix designs for the confirmed coherent-shift mechanism (DESIGN ONLY)

Operator direction (2026-08-21): design BOTH in parallel — explicit downstream phase
contract PRIMARY, enb-grid-anchored pacing SECONDARY/fallback. No builds, no rig time.
For each: the change, resource cost on the ~full die, trigger-independence flag, and
failure mode if the mechanism steps anyway. TRIGGER remains UNKNOWN (what steps the
offset every ~149,100 frames); this document flags per-design whether that matters.

Confirmed mechanism (STAGE_LOCALIZED.md, silicon 2026-08-20): the coded-bit stream is
value-perfect but held at a shifted sequence position relative to the frame marker —
i.e. the marker path (preamble-detect -> startIn) and the data path (Rate_Handle FIFO
-> demap -> serializer -> FEC bitsIn) carry "position in frame" INDEPENDENTLY, and a
stepping event changes the data path's bit-latency without the marker following.
cap_in's held-wrong-constant = the FEC hashing bits [N..N+31] instead of [0..31].
No in-band reference can re-anchor it (6b/6c: marker, occupancy, push strobe all move
with the fault or with legitimate Gardner dither).

---
## PRIMARY — explicit downstream phase contract ("position is data")

**Change.** Stop carrying sequence position implicitly. Attach a position tag at the
earliest point the frame decision exists — the preamble-detector/symbol-sync output,
UPSTREAM of the entire suspect boundary — and make every downstream consumer derive
framing from the tag, never from counting valids after a marker:

1. Producer: a symbol-index-in-frame counter (13 b covers 4,586 sym/frame at f1536),
   reset by the preamble-detect decision, attached to each symbol.
2. Transport: the tag travels WITH the sample through the Rate_Handle FIFO (widen the
   FIFO word 32 b -> ~45 b) and the demod pipeline (matched delays alongside IQ).
3. Consumer: the FEC wrapper computes bit position = 2*tag + serializer-bit and derives
   its frame alignment from tag==0; `startIn` becomes a derived, checked signal.
4. CONTRACT CHECK: the consumer verifies tag continuity (+1 per symbol, mod frame).
   Any discontinuity: (a) re-aligns framing to the tag immediately (damage <= the
   frames in flight, self-healing), (b) increments an AXI violation counter and
   latches {frame_seq, tag_delta} — the stepping event becomes DETECTABLE and
   COUNTABLE for the first time.

**Trigger-independence: FIXES WITHOUT KNOWING THE TRIGGER** for the confirmed fault
class. Any latency step at/downstream of the attach point moves data and tag together,
so framing follows the data and decode stays correct; the event is logged instead of
silently corrupting ~1 s of traffic. This is the property Travis named: position
carried as real data makes a future re-host/re-time violation visible and countable
rather than silent — the failure class of the last weeks cannot recur unobserved.

**Failure modes if the mechanism steps anyway.**
- Step at/downstream of attach (the confirmed class): tag shifts with data ->
  correct decode + counted event. Damage bounded at <= in-flight frames.
- Step that duplicates/drops a whole FIFO entry (IQ+tag together): tag continuity
  breaks -> visible violation + one-frame-bounded damage + self-heal at next tag.
- Step UPSTREAM of the attach point (inside preamble detect / symbol-sync proper):
  tag inherits the shift -> NOT fixed, and the counter stays silent. This is the
  residual exposure; it is exactly why the attach point must be the preamble decision
  itself, upstream of the rate boundary the evidence names. The silicon capture
  bounds the confirmed fault to at/below that boundary.

**Resource cost (die: CLB 99.7 %, BRAM 16.9 %, honest assessment).**
- FIFO widening +13 b: memory cost lands in BRAM/LUTRAM — BRAM has 5x headroom; NOT
  the binding constraint.
- Logic: tag counter + pipeline matching (~60 FF), consumer position math + compare +
  AXI counter/latch (~150-250 LUT/FF), derived-startIn glue (~40). Total order
  300-500 LUT/FF — small in absolute terms but real placement pressure on a 99.7 %
  CLB die. Empirical precedent says it should place: the BEATOBS overlay (same-order
  logic: MLFB packer + cross-hierarchy taps) placed with ZERO overlap iterations and
  routed clean (WNS 2.874 post-synth). If placement fails: the fix image may drop
  instruments the product does not need (TGEN injectors ~ hundreds of LUTs, framestat
  FIFO) — instruments are sacrificable in a fix image; say so in the build recipe.
- The REAL cost is model-surgery breadth: this overlay touches Preamble Detector /
  Symbol Synchronizer / Rate Handle / FIFO / QPSK Demodulator / FEC wrapper — the
  widest overlay of the campaign. Env-gated (QPSK_PHASECONTRACT), byte-identical
  when off, full G2 oracle gates, and a sim positive control BEFORE any build:
  re-run the Model-6 pop-early injections on the patched netlist — expected result:
  decode stays golden AND the violation counter counts each injection.

## SECONDARY / FALLBACK — enb-grid-anchored pacing

**Change.** One absolute free-running beat counter (3 b, clocked by enb_1_2_0,
conditioned on nothing) replaces the local pacer in Rate_Handle AND the serializer's
local phase bit; both derive their phase from the same absolute count. With
`validIn` const-1 this is bit-identical to nominal by construction (Model-6c analysis).

**Trigger-independence: DOES NOT fix without knowing the trigger — masking only.**
It removes one stepping class (data-side transients desynchronizing the two local
pacers from each other) by making producer/consumer agreement implicit-but-shared.
If the trigger is an SEU/glitch on the shared counter, an event upstream in
symbol-sync, or an implementation artifact in the re-hosted enable network, the step
still occurs, still holds, and still CANNOT BE SEEN — the exact silent-failure class
just spent weeks on, preserved. That is why it is fallback only.

**Failure mode if the mechanism steps anyway:** identical to today — held coherent
shift, invisible, ~1 s windows — unchanged damage profile, possibly reduced rate.

**Resource cost:** trivial (<50 LUT/FF, one counter + two 2-bit phase taps). Places
on any die. Smallest possible model edit (Rate Handle + Serializer only).

---
## VERIFICATION (both designs) — the beat law makes this cheap and decisive

The beat is schedulable (arm + 34.75 s + n*119.75 s, 10 ms-exact), so the fix is
verified against SCHEDULED burst slots, not statistics-hunting:

1. **Positive control (fix OFF):** flash the fix image with the gate off ->
   `layerA_stage_poll.sh` (zero rebuild) must show the canonical bursts at the
   scheduled slots (proves the beat exists on this image; guards against accidental
   masking by unrelated build deltas).
2. **Fix ON acceptance:** 3x 340 s stage polls spanning >= 6 scheduled slots.
   PASS = `cap_in` golden at every sample through every slot AND `bit_errors_out`
   flat at the ~51 floor. Reported per the metrics discipline: exact command, sample
   count, all slots enumerated, no dropped-frame exclusions.
3. **PRIMARY-specific (the decisive extra):** the violation counter read across the
   same slots. Expected: counted events AT the scheduled slot times with ZERO decode
   errors — the fix decouples detection from damage, and the counter's
   {count, timing, tag_delta} record is free trigger forensics (magnitude and
   periodicity of the stepping event, previously invisible). Pre-stated alternative
   outcomes: counter counts + errors gone = fix working, trigger characterized;
   counter silent + errors gone = investigate (either the trigger moved or the tag
   shares the shift — discriminated by one BEATOBS capture in a scheduled slot);
   counter counts + errors persist = contract wiring bug (sim control should have
   caught it).
4. **Long-horizon:** 2x 30-min soaks + standard PER acceptance; the forward-class
   PER contribution of the beat should vanish from the ledger.
5. **Capture spot-check:** one BEATOBS capture in a scheduled slot (the image keeps
   the state vector; PRIMARY should add the tag low bits to spare debugI1 bits) —
   direct waveform of a counted, harmless stepping event.
