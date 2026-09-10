> Evidence ledger, moved verbatim from `two_jup/WEDGE_JUNK_CLASS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# WEDGE JUNK CLASSIFICATION — what the post-wedge RX slices actually contain

Date: 2026-08-12. Board: 10.0.0.146, loopback `-S` wedge repro
(`two_jup/r3cap/wedgeck_20260812_095205/`, 4/4 wedges). Source data:
`/dev/shm/seq_raw.log` on the board (770 MB of `RAW t=.. seq=.. class=junk hex=..`
lines, 1528-byte slices). Whitening was OFF for these runs (launch env in
`wedge_ckpt.sh` sets `QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1
QPSK_CKPT=..` — no `QPSK_WHITEN`).

## Question

After the wedge the RX delivers ~254 slices/s that fail PN matching. Which is it:

| class | hypothesis |
|---|---|
| (a) | all/mostly zeros — TX FIFO underrun airing zeros |
| (b) | expected xorshift32 PN stream at a bit/byte shift — framing misalignment |
| (c) | valid PN frame for a different/old seq — stale replay |
| (d) | high-entropy garbage uncorrelated with PN — demod delivering random decisions |
| (e) | structured non-PN patterns (repeating words, counter-like) |

## Method

1. **Samples, not the 770 MB**: fetched 379 junk slices over ssh — first 120
   lines of the log (run startup, t≈0.16–0.7 s, pre-lock), 40 each at byte
   offsets 100/250/400/550/700 MB, and the last 60 of the final rep
   (t≈74.8–75.0 s, steady post-wedge). Saved under the session scratchpad.
2. **Exact frame model**: reimplemented `qpsk_seq_expected()` in Python
   (QK magic, len=64, seq LE32, CRC32 over first 76 bytes, 64-byte xorshift32
   payload seeded `seq^0x9E3779B9`, PN9 (x^9+x^5+1) pad seeded `seq&0x1FF` for
   bytes 76..1527) and **verified bit-identical** against a C harness compiled
   from `host_app_k5/qpsk_seq.c` + `qpsk_frame.c`.
3. **Per slice**: zero fraction; byte entropy; `QK` magic at any offset;
   FFT bit-level cross-correlation against `expected(seq-2..seq+2)` at **all**
   byte shifts 0..1527 and bit shifts 0..7 (one circular xcorr covers both);
   the 8 QPSK phase-ambiguity transforms (I/Q swap x invert-I x invert-Q, both
   pair phases) and differential (XOR-adjacent-bits) views, re-correlated;
   bit-level autocorrelation for internal periodicity; consecutive-slice
   identity and cross-correlation.
4. **Universal frame detector**: the PN9 pad is 1452/1528 bytes of every frame
   and is a *phase of the single 511-bit PN9 cycle* regardless of seq; the
   whitener XORs another PN9 phase, and PN9^PN9-shifted is again a PN9 phase
   (shift-and-add). So circular correlation of a slice against the 511-bit PN9
   cycle detects ANY frame content — any seq, any byte/bit shift, whitened or
   not — in one measurement. Sanity: `expected(12345)` scores **0.949**;
   1528 random bytes score 0.027 (noise floor for max over 511 lags ≈ 0.03–0.05).

## Results

### Per-sample class fractions (classification of each slice)

zero = >95% zero bytes; periodic = period-6-byte motif covers >50%;
hi-entropy = byte entropy >7.0 bits; other = mixed/partial structure.

| sample (log region) | n | zero | periodic | hi-entropy | other | PN xcorr max (any shift/seq±2/ambiguity) | PN9-cycle corr max |
|---|---|---|---|---|---|---|---|
| startup t=0.2–0.7 s (pre-lock) | 120 | 0.07 | 0.10 | 0.57 | 0.27 | 0.047 | 0.037 |
| offset 100 MB | 40 | 0.00 | 0.00 | 1.00 | 0.00 | 0.047 | 0.046 |
| offset 250 MB | 39 | 0.15 | 0.00 | 0.79 | 0.05 | 0.047 | 0.044 |
| offset 400 MB | 40 | 0.03 | 0.00 | 0.85 | 0.12 | 0.046 | 0.033 |
| offset 550 MB | 40 | **1.00** | 0.00 | 0.00 | 0.00 | 0.007 | — |
| offset 700 MB | 40 | 0.03 | 0.03 | 0.95 | 0.00 | 0.047 | 0.037 |
| last rep t=74.8–75.0 s (steady post-wedge) | 60 | 0.15 | 0.02 | 0.82 | 0.02 | 0.046 | 0.033 |

The extreme-value noise floor for the PN xcorr (max |corr| over ~61k lags,
12224-bit frames) is ≈0.044–0.047 — every observed peak sits exactly on the
noise floor. **Zero of 379 slices matched the PN stream at any shift.**

### Other measurements

- **`QK` magic**: found anywhere in 4/379 slices. Chance expectation for a
  random 1528-byte buffer is 1-(1-2^-16)^1527 ≈ 2.3%/slice — observed 1.1%,
  i.e. at/below chance. No buried frame headers.
- **Shift-0 BER vs expected(seq)**: 0.493–0.504 (coin-flip) on every slice
  tested.
- **Consecutive nonzero slices are independent**: mean |xcorr| 0.035, max
  0.065 (noise floor ~0.04). They are not identical (except the all-zero runs)
  and not shifted copies of one another.
- **Byte statistics of steady post-wedge junk**: entropy ≈ 7.5–7.85 bits/byte
  per slice, ones-fraction 0.4724, byte-histogram chi²/dof = 149 (uniform
  would be ≈1) — high-entropy but measurably *biased* random: excess 0x00 and
  a few motif bytes. Exactly the signature of hard slicer decisions on a
  non-signal input, not of a scrambled data stream (which would be flat).
- **All-zero sub-population**: 100% of the 550 MB region and 3–15% elsewhere;
  arrives in identical consecutive runs (39/39 identical at 550 MB, 59/59 in a
  mid-log burst at t≈11.6 s of some rep). These are zeroed/unfilled DMA
  buffers, not demodulated air: an actual TX-underrun airing a constant would
  present the RX a tone, and a tone produces *periodic* slicer output (below),
  not zeros. (The seam checkpoint in the same runs showed cp2==cp3 checksums —
  the zeros were already zero at carve, upstream of the host copy.)
- **Periodic sub-population** (mostly at startup/transitions, ~2–10%): a
  repeating 6-byte / 24-QPSK-symbol motif, e.g. `b6 15 59 85 84 3d` tiling a
  slice. A 24-symbol cycle is what a free-running slicer emits when fed a
  tone/limit-cycle whose residual carrier offset is symbol_rate/24 — i.e. the
  demod chewing on an unmodulated or unlocked input.

## Verdict

**Class (d): the junk is demodulator output with no signal lock — high-entropy,
slightly biased random decisions, uncorrelated with the PN stream in any form —
with a secondary class-(a)-adjacent sub-population of all-zero (unfilled/zeroed)
DMA buffers delivered in identical runs, and a small class-(e) fringe of
periodic 24-symbol tone/limit-cycle patterns at transitions.**

Classes (b) framing misalignment and (c) stale replay are **excluded**:

- Strongest single piece of evidence: **the PN9-cycle circular correlation.**
  Any real frame — any seq ever transmitted, at any byte or bit shift, whitened
  or not — scores ≈0.95 on this detector (95% of the frame is PN9-cycle
  content). Every one of the 379 junk slices scores ≤0.047, the mathematical
  noise floor. The junk contains no fragment of any transmitted frame.
- (c) additionally: an intact stale frame would pass CRC in the scorer
  (`qpsk_frame_decode` is seq-agnostic) and be counted `dup`, never `junk`.

Implication for the wedge mechanism: after the wedge the RX datapath keeps
delivering slices at ~254/s, but what reaches the demod is not the TX signal —
the receiver is slicing noise (and sometimes handing back unwritten, zeroed
buffers). The junk is manufactured at/into the RX, not a misframed or delayed
copy of the TX stream; TX "airing zeros" is also excluded for the high-entropy
majority (zeros without whitening would radiate a tone, giving the periodic
signature, which is only a fringe class).

## Repro

- Sample fetch: `./anyssh.sh 10.0.0.146 'grep -m 120 "class=junk" /dev/shm/seq_raw.log'`
  (+ `tail -c +OFFSET | grep -m 40` at 100/250/400/550/700 MB, + last 400 KB).
- Analysis scripts (session scratchpad): `analyze.py` (frame model, verified
  vs C `genref`), `analyze2.py` (partitioned stats), `analyze3.py` (class
  fractions, ambiguity transforms, motifs), `analyze4.py` (PN9-cycle detector,
  inter-slice independence).
