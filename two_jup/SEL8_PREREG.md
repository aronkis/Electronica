# SEL8_PREREG.md -- does the TX sample stream itself restart a frame at the extra `Transmitter_txFrameStart` pulse?

Pre-registered BEFORE any sel8 arm. Board 148 only. Instrument: DDRCAP-v2 (flashed, verified),
selector 8 = `Transmitter_dataOutI/Q` (TX modulator output, sample domain, 4 records/symbol,
valid `enb_1_2_0`, same regime as sel13-15: the rx2 DMA drops 20-40% of records in bursts, so
record INDEX is not a time base -- see `ddrcap2_pc.py`'s `tref_cadence` rule and
`ddrcap2_txmark_scan.py`'s module docstring). ch2/ch3 (mark_demod, mark_fec, toff, slot/side/tref)
are present on every DDRCAP-v2 selector (`ddrcap2_decode.py`) regardless of the I/Q payload.

## Background (already established, sel6, [silicon])
Every data-plane departure (0->rung transition, 7/7) at sel6 is immediately preceded (by exactly
one record) by an anomalous EXTRA `mark_fec` pulse, while the regular TX cadence (one pulse every
12320 records, 48 records ahead of each `mark_demod`) continues undisturbed
(SESSION_20260830_AUTONOMOUS.md sec82 addendum). That was measured on the symbol-domain tap
(1 record/symbol, no DMA-drop confound). This pre-registration asks whether the pulse itself
coincides with the TX MODULATOR OUTPUT actually restarting mid-frame, using the sample-domain tap.

## Why record-index cadence-chaining (ddrcap2_txmark_scan's `find_regular_and_extra`) is NOT used here
That algorithm assumes a fixed record-count period between consecutive `mark_fec` positions. It
already FAILED its own positive control on every full-rate (enb-domain) capture scanned so far
(sel13/14/15: modal offset covers only 86.7-89.2% of pulses, not >=99%) because DMA record drops
between two real pulses shrink the observed record gap -- exactly the effect that would fabricate
or hide "extra" pulses in a chain-based scan. Sel8 is the same DMA/record regime, so that scanner's
cadence-chaining output on sel8 is not trusted here; per the task brief, `mark_fec`/`mark_demod`
bits are used ONLY to LOCATE candidate records, and classification uses the sidecar `tref` field
(a hardware symbol counter captured on every slot==1 record, immune to record drops because it
counts real time, not DMA-transferred records) instead of record index.

**Symbol-time reconstruction.** Each group of 4 consecutive records (slot 0,1,2,3 =
heldts_lo,tref,runmax_hi,corrthr_hi) belongs to one modulator sample tick. For record `i` with
`slot(i)`, the slot==1 (tref) record of its own group is predicted at `j = i + (1 - slot(i))`.
The prediction is ACCEPTED only if `slot(j)==1` and `tref(j)>=0` at that exact index (i.e. no drop
disturbed this specific 4-record group); otherwise `i`'s symbol-time is UNKNOWN and it is excluded.
This gives a per-record time base that does not depend on any assumption about a global periodic
chain, so it is not subject to the txmark_scan positive-control failure mode above.

**Regular vs extra classification.** For every `mark_fec` record with a known symbol-time, compute
the symbol-time gap to the immediately preceding `mark_fec` record that also has a known symbol-time
(unwrapped, since `tref` wraps mod 12333). The MODAL such gap across the capture is the regular TX
cadence period (expected ~12333, one pulse per frame). A `mark_fec` record is EXTRA iff its gap to
the previous known-time `mark_fec` is small (< half the modal period) -- i.e. it is a genuine
close-in-time doublet with a real neighboring pulse, not merely off the aggregate modal offset
(which drops alone can produce). `p` = that small gap, in tref units. Per `ddrcap2_pc.py`'s own
tref-cadence comment, tref advances at a fixed rate per symbol on enb-domain (sample-domain) taps
(unlike sel6, symbol-domain, where the offset-map's RUNGS are expressed directly in symbols); this
capture's own regular-pulse-to-regular-pulse modal gap is measured and reported as the local
symbol-per-tref-unit calibration so `p` (or `frame_period - p`) can be compared with the sel6 RUNGS
set (6176/6240/6299/6363/6432/6489/6548 symbols) on a like-for-like (symbol) basis -- reported, not
assumed.

## P-TX (positive claim under test)
Within a few symbols after each extra `mark_fec` pulse record (located as above), the TX SAMPLE
stream shows a fresh frame start -- i.e. it matches the template the transmitter emits at every
REGULAR frame start.

**Template construction (positive control on the method itself).** For every REGULAR `mark_fec`
record (per the classification above, credited windows only), take the raw (I,Q) samples in the
N=52 records (13 symbols x 4) immediately following it. If these 52-record snippets are IDENTICAL
(exact sample match) across >=90% of the regular pulses in a credited window (the ROM plays a fixed
short preamble/frame-start pattern, so exact equality, not mere correlation, is the a-priori
expectation), that snippet is the TEMPLATE and the positive control PASSES. If fewer than 3 regular
pulses are found with a full 52-record window in the capture, or fewer than 90% agree, the template
positive control FAILS and P-TX is UNSCOREABLE on that capture (falls to UNINFORMATIVE below).

**Scoring each extra pulse.** Take the 52-record snippet immediately following the extra pulse.
- MATCH-TEMPLATE: exact equality (or, if sample-domain noise prevents exact equality even among
  regular pulses, whichever similarity threshold the template positive control itself established
  as "identical" -- reported explicitly, not silently loosened) to the template -> supports a restart.
- CONTINUATION CHECK (falsifier data): compare the same 52-record snippet against the 52 records at
  the SAME in-frame symbol-time position exactly one regular frame period earlier (i.e. what the
  interrupted frame's own ROM content would show at that point, since frames are otherwise
  bit-identical -- frame-identity limit below). If the extra-pulse snippet matches THIS instead of
  the template, the stream is continuous through the pulse (falsifier).
- `p` (distance from the previous regular pulse, in tref units and converted to symbols via the
  calibration above) is recorded and compared against the RUNGS set (or `frame_period_symbols - p`),
  tolerance +/-4 symbols, matching the sel6 convention.

## Falsifier
The TX sample stream is CONTINUOUS through the extra pulse: no template match, and the snippet after
the extra pulse instead matches the same in-frame position one regular frame earlier (continuation
hypothesis). If this holds for the extra pulses found, the extra `mark_fec` pulse is a SYMPTOM (a
marker-generation artifact), not a stream restart, and the mover is downstream of the TX modulator.

## UNINFORMATIVE
Any of: no extra `mark_fec` pulse found with a known symbol-time inside a credited window; Tier-2
(`ddrcap2_pc.py --sel 8`) FAILS on the capture; the template positive control (regular frame-start
snippets not mutually identical/similar above threshold) fails; fewer than 3 regular pulses available
to build the template; the extra pulse's own 52-record window runs past the end of the capture file.

## Negative control
At a RANDOM regular in-frame position with no `mark_fec` pulse nearby (chosen far from any pulse,
same in-frame offset range used for scoring), the 52-record snippet does NOT match the template
(same equality/similarity test used for extra pulses). This must hold, or the template itself is not
discriminating (e.g. it is silence/DC and would "match" anything), and the whole method is
UNINFORMATIVE regardless of what happens at the extra pulses.

## Frame-identity limit
The transmitter plays a fixed, ROM-driven frame content (per sec82's finding that regular frames are
bit-identical): P-TX's "matches the template" test can establish that a restart occurred and roughly
WHERE in the frame it restarted from (via `p`), but it cannot distinguish "this is frame N restarting"
from "this is frame N-1 (or N+k) restarting" -- restart identity is knowable only modulo one frame
period, exactly as already noted for sel6 in the background campaign.

## Deviation-reporting rule
Any change to this method after arming (thresholds, sample count N, similarity metric) will be
recorded as a deviation in the write-up, not silently applied.

---

## Addendum 1 (pre-scoring, before any decode/score of the sel8 arm at 21:28): P-TX' added per Track A's RTL trace

Filed BEFORE scoring the just-completed sel8 arm (`beatcap/20260902_212830_sel8`, mid.bin +
onset.bin, both credited: pre/post capTAP 0xBCF94856 on both). `two_jup/TX_ORIGIN_TRACE_A.md` sec0
and sec6 (read-only RTL trace, no board contact, filed separately) changes the expected TX signature
and adds a second, top-ranked mechanism. Recorded here as an addendum, not a rewrite, per this
file's own deviation-reporting rule.

### Why P-TX as originally written should now FALSIFY
`TX_ORIGIN_TRACE_A.md` sec1 [RTL fact]: `Bit_Packetizer_dataStart` (`= Transmitter_txFrameStart`,
`QPSK_Tx.v:118`) has exactly ONE condition, `sampleCount==26 && sampleCountValid`, off a monotone,
free-running, unresettable-except-by-top-level-async-reset `sampleCount` counter (`HDL_Counter2`,
`Data_Bits_FIFO.v:190-218`, wraps 0..24665). A second assertion mid-cycle is provably impossible
without a `reset` reaching `u_Data_Bits_FIFO` -- and a `reset` would also re-zero `sampleCount` and
move the whole marker cadence, which silicon does not show (sec82's finding: the regular TX cadence
continues undisturbed through every extra pulse). Sec0/sec6's reading: the "extra `mark_fec` pulse"
in DDRCAP records is a **sticky-latch recording artefact**
(`s1_rtl_ddrcap2/TxRxComposite.v:2164-2179`: `ddrcap_fec_mark_now = Transmitter_txFrameStart |
ddrcap_fec_mark_latch`, held pending until the next `ddrcap_valid_beat` and cleared on it), combined
with the ~20% rx2-DMA record drop already established on enb-domain taps
([[ddrcap-fullrate-dma-drops]]) -- a real, single pulse can land recorded one record early/adjacent
to its usual slot with no second physical `txFrameStart` event at all. **P-TX is kept exactly as
pre-registered above (still scored, still falsifiable on its own terms) but is now EXPECTED to
FALSIFY** -- a fresh-frame-start template match after the extra `mark_fec` record would contradict
sec1's proof and (per sec6's T0) would mean sec1's proof itself is wrong, not merely that P-TX' is
also true. Both are scored; the two are not mutually exclusive to test, only to explain.

### P-TX' (new, TX_ORIGIN_TRACE_A.md sec6 #1, top-ranked mechanism)
`Data_Bits_FIFO.v:270` (`frameCount==0` compare, `Delay3_out1`), `:272-289` (the ungated clear of the
pop-enable latch `Unit_Delay_Enabled_Resettable_Synchronous_out1`, `armed`), `:291` (the pop gate),
`RAM_Frame_Status_Indicator.v:70-75` (`frameCount`, unguarded ufix2, ±1, no saturation).

**Claim:** `armed` (the RAM read-pointer pop-enable latch) is cleared mid-frame when `frameCount==0`.
Pops stop; the RAM read pointer freezes; the modulator re-reads and re-emits the SAME RAM bit for the
rest of the frame (a stall: constant, non-progressing symbols), with NO effect on `sampleCount`,
`dataStart`, the preamble, or any marker cadence. At the next frame, popping resumes exactly where it
left off -- the data is delayed bit-exact by the pop deficit, matching sec82's data-plane rung
displacement. Rung arithmetic: 6176 symbols <=> abort after 12,288 pops (1536 bytes read of the
24,640-bit/12,320-symbol payload half); each 64-symbol rung step (6176, 6240, 6299(*), 6363, 6432,
6489, 6548) <=> 128 fewer pops before the abort. ((*) 6299 is not itself on a clean 64-symbol lattice
from 6176 -- reported as a fact, not resolved here; TX_ORIGIN_TRACE_A.md sec4 discusses the +16..388
symbol / ~64-symbol-step arithmetic in more depth and is not re-derived in this addendum.)

**Sel8 prediction:** within a credited window containing a departure, the TX SYMBOL stream (sel8 I/Q
decimated 4 records/symbol -> 1 sample/symbol by tref/slot phase, then hard-decided to a symbol
value) shows a STALL segment -- constant or repeating symbols, distinguishable from normal
(pseudorandom-looking, ROM-driven but non-constant) payload -- starting mid-frame near symbol
~6144-6160 of the frame and running to the frame end (length ~= 6176 + 64*k symbols for the observed
k), while: (a) the next frame's preamble and `mark_fec`/`mark_demod` markers land exactly on the
regular cadence (no marker shift), and (b) the payload that follows the stall (into the next frame)
is the CONTINUATION of the interrupted frame -- compare bit/symbol-for-symbol against the same
in-frame position of the previous, complete (non-stalled) frame: post-stall payload should equal
that previous frame's payions from the stall point onward, shifted forward by the pop deficit.

**Falsifier (P-TX'):** no stall segment (no constant/repeating run distinguishable from normal
payload) found in any frame of the credited windows, while the same arm shows sel6-style departure
evidence (this arm's mid.bin pre-read capTAP was already a rung/golden word at arm time, established
above -- both captures credited). If P-TX' also fails to show a stall, TX_ORIGIN_TRACE_A.md sec6's
own T0 test (RTL-only, not run here) is the next step, not a silicon conclusion drawn from absence.

**Positive control (stall detector):** inject a synthetic constant run of 6176 symbols into an
otherwise normal (non-constant, ROM-like) frame of the SAME capture and confirm the detector finds
it (length and location). **Negative control:** quiet/normal frames (no injected run, no known
departure nearby) report no stall. **Indexing:** tref-based (per this file's original method, immune
to rx2 DMA record drops), not raw record index. **Search scope:** locate candidate frames first at
the extra-`mark_fec` records (per the original method above), but scan every frame in each credited
window for a stall regardless of whether an extra mark was found nearby, since P-TX' predicts NO
marker anomaly at all near a stall -- the extra `mark_fec` pulse (if it is instrument artefact, sec1
reading 1a) may or may not co-locate with a P-TX' stall, and that co-location (or lack of it) is
itself data to report, not assumed.

### Scoring plan (applies to the already-armed captures, decoded and scored after this addendum)
Both P-TX (original) and P-TX' (this addendum) are scored on the same two credited captures
(mid.bin, onset.bin). Report: which of the two verdicts (P-TX CONFIRMED/FALSIFIED/UNINFORMATIVE,
P-TX' CONFIRMED/FALSIFIED/UNINFORMATIVE) is supported; stall length(s) found vs the rung set; whether
stall content is constant, repeating, or something else; whether an extra `mark_fec` record was found
co-located with any found stall.

### Deviation note
This addendum was filed after the sel8 arm's captures completed but BEFORE either file was decoded
or scored (no decode, no Tier-2, no detector run against real data has occurred as of this addendum),
per the coordinator's explicit instruction and this file's own deviation-reporting rule.
