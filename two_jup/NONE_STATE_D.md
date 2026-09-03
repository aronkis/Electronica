# NONE_STATE_D: what IS the "None" state content at the sel6 demod-input tap?

Host-only analysis, no board contact. Script: `two_jup/none_state_analysis.py`. Inputs:
`two_jup/beatcap/20260902_185552_sel6/{onset,mid}.bin` (unchanged captures, §87/§86-C-addendum-2's
own arm). Output: `two_jup/beatcap/20260902_185552_sel6/none_state_result.json`. Frame anchor and
record-index-as-time-base per `two_jup/ddrcap2_decode.py` (`load`, `decode`) and
`two_jup/ddrcap2_beat_analysis.py` (`per_frame_offsets`), as directed. All findings below are
**[silicon]** (measured directly from the two capture files) unless marked **[inferred]**.

## Answer

**The "None" state is the correct golden ROM frame, resumed exactly where §87 predicts (offset
6490 in onset.bin, 6548 in mid.bin) -- but with the Q-channel (quadrature) hard-decision stream
displaced by exactly +1 symbol relative to the I-channel (in-phase) stream, which itself is a
bit-exact, zero-error match to the golden frame at the predicted offset.** This is not garbage,
not noise, and not a different ROM region: it is the right payload, correctly recovered on I,
with Q read one symbol early/late relative to I -- a fixed one-symbol I/Q channel skew.

This single fact explains everything that made the None state look opaque under the whole-symbol
(paired I,Q) view used in §87/§72:
- **The 16-symbol demod-mark word (`0xBFED37AC`) matches no map entry** because
  `offsetmap/tap3_word_to_offset.tsv` is built assuming I[n] and Q[n] are sampled at the same
  symbol time n; in the None state the effective pairing is I[n] with Q[n+1], which is not a word
  that exists anywhere in a correctly-paired ROM frame under any of the 4 QPSK rotations tested in
  §87 (a per-symbol I/Q skew, unlike a whole-frame delay, is not a cyclic shift of the paired-word
  stream and so cannot appear in the offset map at any shift).
- **The symbol marginal statistics look like normal data (25% each, max run 8)** because I really
  is real, correctly-demodulated payload data (which has ~50/50, low-run-length statistics on its
  own), and Q, when paired against the wrong-time I sample, looks close to independent of it --
  four combinations near-uniformly populated.
- **The whole-frame bit correlation against a golden (quiet, offset==0) frame of the same capture
  peaks at exactly the predicted post-stall offset (even bit-shift, matching the §87 `new = old -
  L` prediction to within the same residual skew as every other clean rung transition), but only
  at ~75.5% bit agreement, not ~100%** -- because that is precisely `(I: 100% + Q: ~50%)/2` when Q
  is compared to golden Q at zero skew. Splitting the correlation by plane and re-searching a
  small per-symbol skew on each plane separately finds I locked at skew 0 (100.0% agreement) and
  Q locked at skew +1 symbol (100.0% agreement) in **both** captures, independently measured.

## Evidence, in the order of the coordinator's four tests

**Test 1 (bit-level cyclic cross-correlation, FFT over all 24,640 cyclic bit shifts, both I/Q
pairings x 4 rotations x conjugation = 16 variants).**
- Positive control, golden vs golden (two different quiet frames of the same capture, offset==0):
  peak shift 0, peak magnitude 24640/24640 (bit-exact), z-score ~156 against the noise floor.
  Confirms the correlation machinery and that the "golden" ROM frame really does repeat
  bit-exactly frame to frame.
- Positive control, rung-state frame (onset.bin frame 1900, offset 6363; mid.bin frame 1050,
  offset 6432) vs golden: peak magnitude 24640/24640 (bit-exact) at shift 11914 (onset) /
  11776 (mid) -- both equal `2 x (12320 - offset)` exactly, i.e. an even shift, matching the
  pre-registered prediction and confirming the rotation/pairing search recovers a pure symbol
  delay when one is present.
- None-state frame (onset.bin frame 4795, mid.bin frame 3910 -- representative frames well inside
  each episode) vs golden: best variant (I-then-Q pairing, 270 deg rotation + conjugation --
  a constellation-labelling artifact of the sign-bit convention, not evidence of anything
  physical) peaks at shift 11662 (onset, matches `2x(12320-6490)=11660` to within 2 bits, i.e.
  well inside the residual-skew tolerance already established for clean transitions) and 11544
  (mid, matches `2x(12320-6548)=11544` exactly). Peak magnitude 12544/24640 = 75.45% bit
  agreement, z-score ~79 (astronomically above the noise floor -- not a chance artifact) but well
  short of the ~100% a pure delay gives. This partial-but-highly-significant match is what drove
  test 2/3.

**Test 2/3 (structure of the imperfect match; per-plane, per-symbol re-pairing search).**
Splitting the best-shift-aligned test frame into its I-plane (even bit positions) and Q-plane (odd
bit positions) and comparing each separately to golden's I-plane and Q-plane:
- I-plane: 100.0% agreement at zero symbol skew, in both captures.
- Q-plane: 50.9% agreement at zero skew (chance level) but **100.0% agreement at a +1-symbol
  skew** (`Q_test[n] == Q_golden[n+1]`), in both captures, independently measured.
- The None-state frame is bit-exact periodic within its own episode (Hamming distance 0 between
  frame 4795 and frame 4173 in onset.bin's episode; 0 between frame 3910 and frame 3283 in mid.bin's).
- The None-state content is bit-exact identical **between the two independent captures**
  (onset.bin's None frame vs mid.bin's None frame): whole-frame correlation peak 24640/24640 at
  shift 24522 -- essentially the full 24640-bit frame, at a shift consistent with the ~58-symbol
  (116-bit) difference between the two episodes' predicted offsets (6548-6490=58; 24640-24522=118,
  within the same few-bit residual seen elsewhere). This rules out the "coincidental partial match"
  reading: the same fixed +1-symbol Q skew, against the same golden reference, reproduces exactly
  across two independently-triggered beat events roughly 15s apart in the same arm.
- XOR(None, golden) at the whole-frame best shift has mean 0.2455 (not 0.5, confirming real
  structure, consistent with 1 of 4 bit-pairs differing on average -- the Q-plane skew) and is
  itself periodic (top autocorrelation peaks at multiples related to the frame's own repeat
  structure), consistent with a deterministic per-symbol skew rather than independent noise.

**Test 4 (§87 stall geometry recap + where None-state content begins).**
Recomputed directly from the already-generated `sel6_stall_geometry.py` JSON
(`onset_stalls.json`, `mid_stalls.json`; unchanged, not re-run):
- onset.bin: stall at frame 4166, `pos_in_frame=6489`, `length=5830` (matches §87 exactly);
  predicted post-stall offset 6490. The immediately preceding frame (4165) has **no** stall row --
  1040 normal (quiet, offset==0) frames separate this stall from the previous stall event (the
  frame-3126 full-frame stall that returned the offset to 0). **A whole-frame stall does not
  immediately precede the None-triggering stall.**
- mid.bin: stall at frame 3278, `pos_in_frame=6547`, `length=5772` (matches §87 exactly);
  predicted post-stall offset 6548. Immediately preceding frame (3277) has no stall row; 1022
  normal frames separate it from the prior event. Same conclusion.
- None-state content begins at record `stall.start + stall.length` in both files, which is exactly
  **1 symbol before the frame end** (`pos_in_frame + length = 12319` of 12320 in both captures) --
  i.e. the frozen run covers the whole rest of the frame bar its last symbol, and normal-looking
  (but Q-skewed) content resumes for that last symbol and continues into the next frame.

## What this does and doesn't close

**Closes:** the None state is not a mystery ROM region, not corrupted/garbage data, and not
noise -- it is the correctly-resumed golden payload (I-channel bit-exact at the §87-predicted
offset) with a fixed +1-symbol Q-channel skew relative to I, reproducible bit-for-bit across two
independent episodes. **[silicon]**

**Does not close (open, [inferred] or unaddressed here):**
- *Why* only these two of the nine measured transitions produce a Q skew while every other
  transition (rung-to-rung, rung-to-zero) resumes with I and Q both correctly paired. One
  candidate explanation consistent with §87's RTL reading (`TX_ORIGIN_TRACE_A.md` §0/§6,
  `Data_Bits_FIFO.v`) is that these two stalls are the ones whose predicted offset (6490, 6548)
  sits closest to the other rungs' half-symbol/parity boundary in the `Data_Bits_FIFO` pop-count
  arithmetic, such that the abort recovers with the FIFO's I and Q read pointers one pop apart
  instead of synchronized -- but this repo's DDRCAP-v2 sel6 tap has no direct visibility into that
  FIFO's internal I/Q pointer state, so this is **[inferred]**, not measured.
- Whether this is a transmitter-side (TX FIFO/mux) or receiver-side (sel6 tap's own I/Q demux)
  effect is not distinguished by this analysis alone; sel6 is the demod-input tap, downstream of
  both, so a symbol-skew fault anywhere upstream of it would look identical here.

## Commands / reproduction

```
python3 two_jup/none_state_analysis.py
```

Reads `beatcap/20260902_185552_sel6/{onset,mid}.bin` + `onset_stalls.json`/`mid_stalls.json`,
writes `beatcap/20260902_185552_sel6/none_state_result.json`, ~9s on this host.
