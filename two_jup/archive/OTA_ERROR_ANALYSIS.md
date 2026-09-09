# OTA Full-Packet BER — Error-Source Analysis

Instrument: `qpsk_tun -B` full-packet scorer (`host_app_k5/qpsk_ber.c`). Compares
every raw received 128-byte (1024-bit) packet against a fixed known reference,
per-frame alignment-locked and classified (CLEAN / NOISY / PHASE / ROTATED /
MISS). Only aligned frames (CLEAN+NOISY) count toward BER; acquisition/cycling
frames are excluded, so the reported BER is the **true post-lock rate**.

**Calibration (mandatory gate, PASSED):** on internal loopback the tool reads
**BER = 0.000e+00 over 4.33 M bits, 99.9 % CLEAN** — byte-order, endianness and
reference generation are correct, and the tool reads *true zero* on a clean
path. The `-e` echo path (whole-frame CRC) independently read 99.9 %, and the
tool's PHASE bucket (4) matched echo's CRC drops (5) frame-for-frame. So every
number below is the link, not the instrument.

## Run: FDD, watchdog-bootstrapped, 60 s each direction

| Direction (link into board) | BER | CLEAN | NOISY | PHASE | MISS | ROTATED | rstcs |
|---|---|---|---|---|---|---|---|
| **148 ← 146 @ 2.00 GHz** | **3.46e-3** | 47.0 % | 48.1 % | 4.3 % | 0.6 % | 0 % | ~8.8 /s |
| **146 ← 148 @ 2.10 GHz** | **2.28e-2** | 8.1 % | 61.9 % | 16.1 % | 13.8 % | 0 % | ~44 /s |

(148: 9026 frames, 8578 aligned, 30 395 bit errors. 146: 6297 frames, 4412
aligned, 103 118 bit errors. rstcs from modem reg 0x150 delta over the run.)

## Finding 1 — the BER floor is SYSTEMATIC and POSITION-LOCKED, not AWGN

The per-offset error map is sharply spiked, not flat. On the clean direction
(148 ← 146):

```
byte:   8    9   10   11   12  ...   20    21    22   23  ... 32..127
errs: 1603 1206 1050 2844 3879 ...  412  7617  8255  221 ...  mostly <60
```

- Bytes **21–22 carry ~7600–8300 errors over 8578 aligned frames ≈ ~1 bit per
  frame** — a *near-deterministic* error at a fixed position.
- Bytes **8–12** are the second cluster.
- Bytes **32–127 are nearly clean** (<60 errors each).

AWGN/thermal noise would spread errors uniformly across all 128 bytes. A spike
that recurs every frame is a **structural / systematic** error, not thermal
noise. The pattern-vs-position experiment (Finding 5) pins it down: it is
**data-pattern-dependent**, not a fixed hardware hot-spot.

### This is exactly why the old BIST was misleading
`cap_out` (0x144) checks **bytes 0–3**, which are **99.9 % clean** here (47/8578
errors on 148). So the legacy 32-bit BIST reads **golden = PASS while bytes
21–22 are ~96 % corrupt.** Even the deeper 120-bit `bit_errors` counter (bytes
0–14) only partially overlaps the 8–12 cluster and misses the 20–22 spike
entirely. Full-packet verification surfaces an error mode the sliver-checks
structurally cannot.

**Implication:** this floor is a near-threshold coded-link behaviour where
specific data patterns fail (Finding 5), on already-high-entropy payloads. It is
reduced by more **margin** (SNR / loop), NOT by whitening — whitening only
rescues pathological *low-entropy* payloads (Finding 6); it does not lower this
random-data floor.

## Finding 2 — carrier-loop cycle slips (PHASE frames) scale with rstcs

PHASE = a whole-frame ~50 % scramble = a gross phase slip. Its rate tracks the
carrier-sync reset counter almost exactly:

- 148 ← 146: PHASE 4.3 % ↔ rstcs ~8.8 /s
- 146 ← 148: PHASE 16.1 % ↔ rstcs ~44 /s

So the second error source is **carrier-loop instability** — the 2.10 GHz
direction slips 5× more often. These are excluded from the BER (they are not
aligned-clean), but they are lost frames end-to-end.

## Finding 3 — direction/carrier asymmetry: 2.10 GHz is ~6.6× worse

146 ← 148 @ 2.10 GHz: BER 2.28e-2, only 8 % CLEAN, 13.8 % MISS (intermittent
lock loss). 148 ← 146 @ 2.00 GHz: BER 3.46e-3, 47 % CLEAN, 0.6 % MISS. The
2.10 GHz carrier is consistently the weak/cycling side (raw BER, lock stability,
and cycle-slip rate all worse). Prior sessions saw the same 2.10 GHz weakness.

## Finding 4 — framing is solid; bursts are short

ROTATED = 0 in both directions → no word/frame slips; the byte aligner is
robust. The burst-length histogram is dominated by isolated single bits and
pairs (len 1–2), with a short tail (max len 10–11) — consistent with the
position-locked pattern plus occasional carrier slips, **not** long noise bursts
or extended unlock.

## Finding 5 — the floor is PATTERN-dependent (root cause)

Re-ran the clean direction (148 ← 146) with a different reference seed
(`QBER_SEED=0xC4`, identical on both ends). The error map **moved with the
pattern**:

```
seed 0x1A5 (default): spike at bytes 20-22 (7617/8255); bytes 32-127 clean
seed 0xC4           : bytes 20-22 -> ~0; new spikes at bytes 0, 7-8, 14
```

The error *positions* follow the *data pattern*, not the byte position. So the
floor is **not** a fixed interleaver/frame hot-spot — it is **data-pattern /
context-dependent decode failure**: specific transmitted bit sequences (and the
inter-frame loop state their neighbours leave behind) fail to decode. This is
the classic signature of **low-transition-density symbol runs stressing the
carrier/timing recovery** near the link margin — some patterns hold the loops on
a near-constant phase long enough to slip a bit, and those patterns land at
fixed positions *for a fixed payload* but move when the payload changes.

This directly explains the prior "idle keepalives pass but data frames fail /
~5 % loss" observation: real varying traffic keeps hitting *different* bad
sub-patterns, so errors scatter and every so often a frame carries a
loop-stressing run.

## Error-source breakdown (this link, this run)

1. **Data-pattern-dependent decode floor** — dominant, ~BER 2–3.5e-3 on the good
   direction, ~1 bit/frame concentrated at payload-dependent positions. Root
   cause: loop-stressing (low-transition) patterns near threshold, NOT uniform
   noise and NOT a fixed hardware hot-spot.
2. **Carrier cycle slips** (PHASE ↔ rstcs) — worse at 2.10 GHz (16 % vs 4 %).
3. **Intermittent lock loss** (MISS, 13.8 % on the weak 2.10 side) → link margin.
4. **Framing**: healthy (ROTATED 0 both directions).

## Finding 6 — host whitener rescues LOW-ENTROPY payloads (a SEPARATE problem from Finding 5)

This addresses a **different** phenomenon than Finding 5. Finding 5 is the
random-data floor (already-high-entropy payloads, margin-limited). Finding 6 is
the **low-entropy extreme**: a near-constant symbol run that prevents lock
entirely. The whitener fixes the latter and does **not** touch the former.

Archaeology: the modem HAS a scrambler/descrambler (`HDL_Data_Scrambler.v`) but
it was **deliberately removed** on both ends (`fec_nodescr_overlay.m` +
`fec_remove_scrambler`, gate asserts `EnableScrambling=false`) during a debug
hunt for the (now-fixed) FEC-encoder and phase-ambiguity bugs. So the deployed
air is **un-scrambled** — low-entropy payloads radiate near-constant symbols.

Rather than re-enable the fraught HDL scrambler (risky reflash), a **host-side
frame-synchronous whitener** was added (`qpsk_whiten`, PN9, self-inverse;
integrated into `qpsk_frame_encode`/`decode`, env `QPSK_WHITEN`, default off).
Zero board risk. Demonstrated OTA on a **pathological all-zero payload** (148 ←
146 direction):

| all-zero payload | frames aligned | CLEAN | PHASE |
|---|---|---|---|
| **whitener OFF** | **0** | 0 % | **100 %** (link dead — every frame phase-scrambled) |
| **whitener ON**  | **7939** | 88.0 % | 1.9 % (link decodes again) |

The defensible result is **0 aligned frames → the link decodes again**: without
whitening the constant-symbol run gives the carrier loop no phase to lock, so
every decoded frame is scrambled. Entropy check (host-side): a zero payload has
44 bit-transitions/1023; whitened, 522 (≈ the PN baseline 499). The ON run
measured BER 3.7e-4, but that is *below* the baseline PN floor (3.46e-3) and so
reflects run-to-run variation on this time-varying link (or PN(0x1FF) being a
benign pattern), **not** a whitener BER gain — the honest claim is "rescued a
dead link", not a lower BER. Control: the 146 direction barely moved
(1.4e-2 → 1.6e-2), confirming *its* limiter is carrier-slip margin, not entropy.

Why it matters: real TCP/IP traffic is full of zero-runs and repeated headers —
exactly the low-entropy case. Without the whitener those specific frames are
catastrophic (like the all-zero test); with it they decode at the link's normal
(margin-limited) floor. It is a **robustness** fix, not a floor reduction.

## Recommendations (in priority order)

1. **DONE — host whitener** (`QPSK_WHITEN=1` on both ends). Rescues the
   **low-entropy catastrophe** (zero-runs / repeated headers); does **not** lower
   the random-data floor. No reflash. Remaining (flagged): the decode-side
   de-whiten is unit-tested (`test_whiten`) but not yet exercised on hardware —
   `-B` uses encode-whiten + raw compare and never calls decode. End-to-end proof
   is a `tun0` run with `QPSK_WHITEN=1` on both ends + ping/loss re-measure.
2. **Improve margin on the 2.10 GHz direction** — it is 6.6× worse and slips 5×
   more, and the whitener does NOT help it (margin-limited, not entropy-limited).
   Fresh CFO trim (trims were days stale — the untended `-B` never self-acquired),
   antenna isolation/position, Rx gain, Tx power. This is what lowers the ~2-3e-3
   floor toward SSH-usable; a 1024-bit packet at 3e-3 still averages ~3 bit
   errors → CRC drop, so the floor (not entropy) is the SSH blocker.
3. **Carrier-loop margin** — the cycle-slip rate (rstcs) is the second-order
   source (PHASE ↔ rstcs); loop-bandwidth tuning helps hold lock.
4. **Optional HDL** — re-enable the in-fabric scrambler (now that its upstream
   bugs are fixed) to whiten *all* traffic in fabric, and/or the on-chip
   full-packet BIST counter. Deferred: higher risk (dual reflash), and the host
   whitener + `-B` tool already cover the need.

## How to reproduce
- Calibrate first: `two_jup/ber_loopback_gate.sh <ip>` must read BER~0 (green).
- OTA: `two_jup/ber_ota.sh` (env `DUR`, `SEED`, `TXA/FA/TXB/FB`). `SEED` sets the
  reference (identical both ends) to re-test pattern dependence.
