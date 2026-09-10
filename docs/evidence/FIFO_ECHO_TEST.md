> Evidence ledger, moved verbatim from `two_jup/FIFO_ECHO_TEST.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# FIFO_ECHO_TEST — hardware check of the tick-fix sim's stale-echo prediction

Date: 2026-08-14. Pure offline analysis of `two_jup/r3cap/echo_test_seqraw.log`
(17 MB, fresh loopback `-S` corrupt-slice RAW dumps from 148, f1536 geometry,
1528 B / 191×64-bit words per frame). Analyzer: C harness compiled against the
host sources themselves (`host_app_k5/qpsk_seq.c` + `qpsk_frame.c`), so the
expected wire stream is bit-identical by construction (session scratchpad
`echo/echo_an.c`, `echo/hamm.c`, `echo/detail.c`).

## The prediction under test (TICK_FIX_SIM.md §3)

If the air/loopback corrupt-singles generator is a write-swallow at the
platform 1536-word byte FIFO, then a corrupt WORD delivered at stream position
`p = seq*191 + w` must be BIT-EQUAL to the delivered stream at `p − 1536`
(= word `(w−8) mod 191` of frame `seq−8`, with the borrow). In sim, 111/120
swallowed words matched this echo exactly.

## What the capture actually contains

5488 RAW lines, t = 0.03–45.0 s, **all class=junk — zero `class=biterr`,
zero `TORN_*` dumps** (the scorer dumps every biterr raw; none occurred).
Whitening OFF (confirmed: 13 slices carry plain `QK` at offset 0; zero carry
whitened magic).

| population | n | note |
|---|---|---|
| no `QK` anywhere, non-zero | 5040 | demod-noise junk, the WEDGE_JUNK_CLASS class-(d) morphology |
| all-zero | 336 | unfilled/zeroed DMA buffers (WEDGE class-(a)-adjacent) |
| chance `QK` at interior offsets | 99 | ≈2.3%/slice chance rate — not frames |
| `QK` at offset 0, len=64, sane seq | 13 | the only attributable slices |

The 13 headered slices are one **periodic series, one frame every ~2.02 s**
(hdrseq step ≈2512 ≈ the 1245 fps f1536 rate × 2.02 s), with monotonically
degrading quality: wrong-word count 11 → 24 → 36 → 56 → 92 → 115 → 142 → 162 →
180 → 183 → 187 → 190 → 190 (of 191), while the scorer's accounting lag
(hdrseq − logged next_expect) shrinks 533 → 312. Per-word corruption starts at
**3–5 wrong bits per wrong word** and drifts toward coin-flip. This is a
progressive demod SNR/lock collapse ending in the terminal wedge at
next_expect 47674 (1275 junk dumps, t≈31–45 s) — not the CLASS-B
corrupt-singles population (full-length CRC-fail singles, self-heal ≤2,
~4%/frame) that the sim's prediction targets.

## The echo test

CLASS-B-like gate per the method: header parses valid AND a minority of the
191 words wrong AND not all-zero. Attribution tried both the parsed header seq
and a +66-frame window around the logged next_expect (window attribution found
nothing; all candidates came from valid headers). **5 slices qualified, 219
wrong 64-bit words tested** (every word's −3072 reference in range; 0
degenerate sources where stream(p−1536) == expected(p)).

Bit-equality of the observed corrupt word vs the analytic delivered stream:

| offset (words) | meaning | matches |
|---|---|---|
| **−1536** | **FIFO-wrap echo (the hypothesis)** | **0 / 219 (0.0%)** |
| −1528 | exactly 8 frames | 0 / 219 |
| −1544 | 8 frames + 16 words | 0 / 219 |
| −1535, −1537 | ±1 word off the hypothesis | 0 / 219 |
| −1520, −1552 | ±2 words wider | 0 / 219 |
| −191, −382 | 1, 2 frames | 0 / 219 |
| −1 | previous word | 0 / 219 |
| +1536 | forward wrap (sanity) | 0 / 219 |
| −3072 | 2 wraps | 0 / 219 |

Bit-distance forensics (the stronger form — a *noisy* echo would still sit
near its source):

- Hamming(observed, expected(seq) at w): **mean 5.38 bits** of 64.
- Hamming(observed, stream at p−1536): **mean 32.15 bits, min 22, full
  chance-distribution 22..40** — statistically indistinguishable from an
  unrelated 64-bit word.

Wrong-word geometry: 219 wrong words fall in 131 separate runs; **no slice is
a single contiguous run** (max run 10, only in the heavily-degraded tail).
The swallow model predicts contiguous EATW-length runs of wholesale-replaced
words (~32 wrong bits each); observed words are scattered, 3–5-bit-wrong —
symbol-decision errors, not word substitution. No word in any attributable
slice was a wholesale replacement.

## VERDICT

**INCONCLUSIVE for the FIFO-swallow mechanism — the target event class did
not occur in this capture; for the corruption that DID occur, the echo is
cleanly REFUTED (0/219 at −1536, chance bit-distance to the echo source).**

Two findings, kept separate:

1. **This 45 s loopback run produced zero CLASS-B corrupt singles** — no
   class=biterr dumps, no full-length frame with wholesale-wrong words. Its
   corrupt slices are (i) demod-noise junk + zeroed buffers (the wedge
   morphology of WEDGE_JUNK_CLASS.md, here on 148) and (ii) a ~2 s-periodic
   series of progressively bit-errored frames tracking an SNR/lock collapse
   into a terminal wedge. The sim's fingerprint cannot be checked against a
   capture in which the fingerprinted event class is absent.
2. **The words that were corrupt are unambiguously NOT stale-FIFO content**:
   few-bit demod errors (mean 5.4 bits from expected), at pure chance distance
   from the −1536 stream position and every control offset. Whatever corrupted
   these frames acted in the signal/decision domain, not the byte-FIFO domain.

## Next step for a real test

Re-run the capture on a session that exhibits the actual air-singles class
(scorer classifies them `biterr`, so they land in the same RAW log with
class=biterr) and rerun the same harness — it gates on minority-wrong-word
slices automatically. A run that wedges at t≈15 s cannot bank the ~4%/frame
pair-beat singles; the previous singles campaigns (PAIR_RECURRENCE.md) banked
them in healthy multi-minute runs.

## 2026-08-14 RE-TEST — the true class-B population (echo_test_biterr.log)

Data: `two_jup/r3cap/echo_test_biterr.log` — the 9 `class=biterr` (8) /
`class=biterr-hdr` (1) RAW slices from a healthy 235 s drain-budget loopback
run on 148 (no wedge). These are exactly the scorer-attributed
minority-bit-fraction CRC-fail singles the first pass said were missing.
Same harness, same exact expected stream (host C sources), whitening OFF.

### What the 9 slices are (vs expected(attributed seq))

| sub-class | n | morphology |
|---|---|---|
| single-bit header flip | 2 | exactly **1 wrong bit** in the whole 1528 B frame — **the same bit both times**: byte 0 bit 6, magic 0x51→0x11 (t=56.2 s seq 65438; t=181.6 s seq 218545) |
| body-scrambled, header intact | 7 | word 0 (magic+len+seq) bit-perfect, the other 190 words ALL wrong at a uniform **30.5–34.9% bit-error fraction** (3725–4270 of 12224 bits — just under the scorer's 0.35 attribution gate). The `biterr-hdr` one carries an intact header for **seq−4** (stale header, garbage body). |

Event timing: two bursts of 4–5 events, consecutive events **2209–2238
frames (~1.78 s) apart** — a periodic beat, not the 8-frame pair offset;
rate 9/~292k frames ≈ 0.003%/frame, three orders below the air class's
~4%/frame. So even this healthy-run loopback population is morphologically
NOT the air pair-beat singles class.

### Echo test — all 1333 wrong 64-bit words, all offsets

| offset (words) | matches |
|---|---|
| **−1536 (hypothesis)** | **0 / 1333 (0.0%)** |
| −1528, −1544, −1535, −1537, −1520, −1552 | 0 / 1333 each |
| −191, −382, −1, +1536, −3072 | 0 / 1333 each |

Bit-distance forensics:

- Wrong words vs the −1536 stream position: **mean 31.74 bits of 64
  (min 17, max 43)** — pure chance; not even a noisy echo.
- The 2 single-bit words: 1 bit from expected, 30/36 bits from the −1536
  source.
- The 7 scrambled bodies: no global bit-shift (best over ±8 bits is shift 0),
  no inversion, no match to any neighbor seq ±16 — signal/decision-domain
  scrambling, with the striking structural feature that the first 64-bit
  word survives intact (P(word 0 intact | uniform 33% errors) ≈ 6e-12 —
  the header's survival is structural, not luck).

### RE-TEST VERDICT

**Echo REFUTED for this loopback class-B population**: 0/1333 wrong words
match the −1536 prediction (sim: 111/120 = 92.5%), at chance bit-distance
from the echo source, controls all null. The corrupt singles this loopback
link produces are not stale-FIFO content: they are (i) a repeated
single-bit flip of the same header bit and (ii) a ~2210-frame-periodic
body-scrambling event that spares word 0. Standing caveat: this is the
*loopback* singles population; it differs in period, rate, and morphology
from the banked *air* pair-beat class (8/24-frame alternation, ~4%/frame,
PAIR_RECURRENCE.md), so the FIFO-swallow hypothesis for the AIR class is
still untested against air-captured biterr bytes — but for loopback singles
the mechanism is excluded.

## Repro

- `scratchpad/echo/echo_an.c` — parser + attribution + word-level echo/controls
  (compiled with `-I host_app_k5 qpsk_seq.c qpsk_frame.c`).
- `scratchpad/echo/hamm.c` — bit-distance of wrong words vs expected and vs
  the −1536 source.
- `scratchpad/echo/detail.c` — per-slice wrong-word / per-word-bit histograms
  of all 13 headered slices.
