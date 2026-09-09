# Demod-slicer investigation — bit-true R3 netlist replay (analysis only, no hardware)

Date: 2026-08-11. Off-hardware throughout; the link was never taken.

## Headline

Replaying the **identical captured samples** through the bit-true fixed-point f1536
netlist separates the R3 frame losses into **two distinct fault classes**:

| hardware event | frames | netlist on the same samples | class |
|---|---|---|---|
| isolated loss A (seq 53877–53878, k=300–301) | 2 | **k=300 fails CRC** (delivered, 191 words) | **reproduces → demod/decision path** |
| isolated loss B (seq 53909, k=332) | 1 | decodes CRC-good — **but see caveat** | unsupported, see below |
| **the 26-frame burst** (seq 54174–54199, k=597–622) | 26 | **25 decode CRC-good, all 191 words, seq contiguous 54175→54200; 1 (k=609) not covered by any chunk** | **does not reproduce → host/DMA delivery seam** |

**On the 26th frame.** k=609 is `delivered=0, words=0` — it is `chunk_540_609`'s payload
end, and as established below the chunk overlap does not in fact cover chunk tails, so
**k=609 was never decoded by anything**. It is uncovered-by-construction, not a decode
failure. The burst evidence is therefore **25 frames clean with one hole**, not 25/26
with one failure. Closing the hole is one `run_region.sh` invocation (k=609 sits in
`chunk_610_679`'s warm-up region, w0=602) and is owed before this is called settled.

Do not score these with an `okn < n` test — a single tail artifact flips such a verdict,
which is the same defect shape as the anchor-control verdict function that could not
distinguish "constant" from "floored".

**Caveat on isolated loss B.** k=332 falls inside the seq-mismatch run that starts at
k=322 with offset +1, so the frame the sim decoded at k=332 may be the neighbour of the
frame the hardware lost. That row is **not supported** until the anchor is re-derived
from decoded seq. It does not affect the two-class conclusion.

The burst is not an air or decode event. The netlist recovers the whole run from the
same I/Q, contiguously and bit-exactly, while the hardware delivered none of it. That
matches the host-side signature already noted in `tap_replay_study/RESULTS.md`: 25 reads
of garbage inside a single frame period with `reg_packets` frozen.

Conversely the isolated single-frame losses **do** reproduce in fixed point. `k=300`
is delivered with a full 191-word payload and fails the host-contract CRC — the frame
arrives, the bits are wrong. That is the demod/decision-path fault, and it is now
reproducible offline on banked samples, which makes it localisable by the hybrid-ladder
method that found the 307 poison.

## Why this is a real separation and not an artifact

Of the 11 CRC failures in the map, 9 are **chunk-tail artifacts**: `delivered=0`,
`words=0`, sitting on a chunk's payload end (312, 350, 469, 539, 609, 679, 749, 810,
plus 809 adjacent). The sim tail is only 60k clks, so each chunk's last frame is never
delivered, and the intended overlap does not in fact cover it — every bad frame is
spanned by exactly one chunk. Only **k=300 and k=330** are `delivered=1, words=191`
and CRC-failing, i.e. genuine decode failures.

The burst verdict rests on each frame's own embedded CRC and its decoded seq, both read
out of the frame payload — independent of the `SEQBASE + k` anchor. So the anchor's
known drift does not touch it.

## Instrument defect found (the eighth)

`aggregate.py` silently merged chunks from **two different captures**. Three chunk
slices dated Aug 9 — `chunk_600_669`, `chunk_670_739`, `chunk_740_800` — are **not
slices of `pair.iq`**; `run_region.sh` skips regeneration when `$tag.iq` already exists
(`if [ ! -s $tag.iq ]`) and takes `CAP` from the environment, so a later run against a
different capture wrote same-named files into the same directory.

Verified byte-for-byte against `pair.iq` at each chunk's expected offset:

```
chunk_540_609_r0: matches pair.iq@frame532?  True
chunk_600_669_r0: matches pair.iq@frame592?  False   <- foreign
chunk_610_679_r0: matches pair.iq@frame602?  True
chunk_670_739_r0: matches pair.iq@frame662?  False   <- foreign
chunk_740_800_r0: matches pair.iq@frame732?  False   <- foreign
chunk_750_810_r0: matches pair.iq@frame742?  True
```

Symptom that exposed it: decoded seq jumped **−2590** at k=609 (54186 → 51596) with
every frame still CRC-good. A decode fault cannot produce valid CRCs on a different seq
run; a spliced-in foreign capture can.

The three foreign chunks are quarantined in
`tap_replay_study/foreign_notpair/` (moved, not deleted). All numbers above are from
the re-aggregated map over the eight verified `pair.iq` chunks. The pre-quarantine map
is preserved for comparison.

**Fix owed to `run_region.sh`:** stamp the source capture (path + md5 + offset) into each
`chunk_*.iq` sidecar and have `aggregate.py` refuse to merge chunks whose stamps
disagree. The `[ ! -s $tag.iq ]` reuse guard is only safe if it also checks provenance.

## Also corrected

`obj_byte_iq_f1536/Vwrap_byte` is **mislabeled** — its compiled internals are k5/240k
geometry (16-word frames), not f1536. `RESULTS.md` had already caught this; the working
R3 fixed-point leg is `obj_byte_f1536/Vwrap_byte__ALL.a` driven by `perframe_f1536`.
`replay_capture.sh` hardcodes the 240k object and cannot be pointed at R3 as written.

## Error hypothesis and candidate fix

Two faults, and the campaign has been conflating them:

1. **Burst losses — host/DMA delivery seam.** Not fixable in the PHY; the samples are
   good. This is what Layer B exists to characterise.
2. **Isolated single-frame losses — a STATIC CARRIER-PHASE STEP in the received
   signal.** (Renamed 2026-08-11; see `LADDER_K300_FINDING.md`.) `k=300` reproduces
   offline, but the cause is NOT the decision path and NOT fixed-point: the float front
   end shows the following frame carrying a flat ~11.7 deg static rotation that accounts
   for its 21% EVM exactly (2*sin(theta/2) = 20.4%, plus the 4.9% floor in quadrature =
   20.97% vs 21.0% measured), with frame cadence exactly nominal (no splice). Because the
   FLOAT model sees it, it is in the signal, not in the arithmetic. The hybrid ladder is
   the wrong instrument here and should not be run on this frame. Candidate fix path: run the hybrid float/fixed ladder over the k=300 frame
   to find the first stage whose fixed-point output diverges from float, exactly as the
   307 poison was localised. This needs no hardware and no flash.

**Confidence.** The burst result is strong: 25 independent frames, each CRC-validated on
its own embedded checksum.

**k=300 IS CORROBORATED (2026-08-11).** It was `n=1` and could have been a chunk-alignment
artifact, so it was re-cut at a different alignment: `chunk_270_339` (w0=262) against the
original `chunk_294_312` (w0=286) — a 24-frame different warm-up history, an independently
generated slice, provenance-stamped.

```
k=299 : crc_ok=1  words=191  seq=53876
k=300 : crc_ok=0  words=191  seq=-1     <- FAILS UNDER BOTH ALIGNMENTS
k=301 : crc_ok=1  words=191  seq=53877
k=330 : crc_ok=0  words=191  seq=-1
```

Delivered with a full 191-word payload and failing CRC in **2/2 independent alignments**.
Not an alignment artifact — a genuine fixed-point decode failure, reproducible offline.

The same run also **confirmed the tail-artifact diagnosis**: `k=312` was previously "bad"
purely as `chunk_294_312`'s uncovered payload end, and once `chunk_270_339` spanned it, it
decoded clean and dropped off the failure list. Remaining failures are now `300, 330`
(real: `delivered=1, words=191`) plus `350, 469, 539, 609, 679, 749, 809, 810` (all chunk
tails).

**Anchor caveat, unchanged and now sharper.** The decoded seq runs `k=299→53876`,
`k=301→53877`, i.e. there is an off-by-one against `SEQBASE+k` in this region. So *which
hardware event* k=300 corresponds to still needs the anchor re-derived from decoded seq.
The **reproduction** is corroborated independently of the anchor; the **identification**
with a named hardware loss is not.

Subject to that, do not merge the two into one PER number again — the evidence so far
says they have different causes and different fixes.

## Next step (analysis, no link)

Hybrid-ladder localisation on k=300 (and k=330) against the float leg. Before that,
land the provenance stamp in `run_region.sh`/`aggregate.py` so no later merge can
repeat the defect above.

## Artifacts

- `jupiter_240k5_byte/rtl_sim/tap_replay_study/framemap.csv` — re-derived, pair.iq only
- `jupiter_240k5_byte/rtl_sim/tap_replay_study/foreign_notpair/` — quarantined chunks
