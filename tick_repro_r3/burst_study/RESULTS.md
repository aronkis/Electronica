# STAGE A' results — sample-slip size vs frames-to-recover (R3/f1536, float receiver)

Run: 2026-07-31, `run_burst_study.m` (log: `run_log.txt`, data:
`burst_study_results.mat`). Substrate: first 10 M samples (~202 frames) of the
REAL R3 reverse capture `two_jup/r3cap/hunt_auto_20260731_211829/pair.iq`
(genuine link IQ @ 61.44 MSPS; the clean region before the hardware burst).

- Baseline (unperturbed): 202 frames, CFO 7 Hz, frame EVM median 4.11 %,
  sigma 1.55 %, zero missed frame slots.
- Injection: one splice per run, mid-frame of baseline frame 50 (raw sample
  n0 = 2 432 064, ~6 000 symbols from either preamble), 152 frames of
  post-injection observation.
- Failure tests per frame slot (walked until 3 consecutive clean frames):
  MISSED = no preamble detection at the 12333-symbol cadence;
  DEGRADED = frame EVM > 11.87 % or preamble corr < 0.5;
  CRC-FAIL = hard-decision payload differs from the baseline run's
  same-ordinal frame (mismatch > 1e-3) — the hardware-CRC-equivalent test,
  required because hard-decision EVM is blind to displaced-but-valid QPSK
  content.

## Table: displacement -> frames-to-recover

| Slip | Samples | Symbols (sps=4) | Frames missed (sync) | Frames degraded (EVM) | Frames CRC-fail (payload) | **Frames to recover** | Peak frame EVM |
|---|---|---|---|---|---|---|---|
| insert | 2 | 0.5 (bonus) | 0 | 0 | 1 | **1** | 7.6% |
| delete | 2 | 0.5 (bonus) | 0 | 0 | 1 | **1** | 7.7% |
| insert | 4 | 1 | 0 | 0 | 1 | **1** | 5.1% |
| delete | 4 | 1 | 0 | 0 | 1 | **1** | 5.1% |
| insert | 32 | 8 | 0 | 0 | 1 | **1** | 5.1% |
| delete | 32 | 8 | 0 | 0 | 1 | **1** | 5.1% |
| insert | 64 | 16 | 0 | 0 | 1 | **1** | 5.1% |
| delete | 64 | 16 | 0 | 0 | 1 | **1** | 5.1% |
| insert | 128 | 32 | 0 | 0 | 1 | **1** | 5.1% |
| delete | 128 | 32 | 0 | 0 | 1 | **1** | 5.1% |
| insert | 256 | 64 | 0 | 0 | 1 | **1** | 5.4% |
| delete | 256 | 64 | 0 | 0 | 1 | **1** | 5.4% |
| insert | 512 | 128 | 0 | 0 | 1 | **1** | 7.3% |
| delete | 512 | 128 | 0 | 0 | 1 | **1** | 7.7% |

The one CRC-failed frame is always the frame CONTAINING the splice (payload
symbol mismatch ~0.37 = the displaced second half of that frame); the very
next frame already matches baseline bit-for-bit (mismatch 0.000) with clean
EVM and on-cadence preamble sync.

## Verdict

**A single sample-domain slip does NOT reproduce the 5–100-frame burst
signature in the float receiver: every size from 2 to 512 samples (0.5 to 128
symbols), insertion or deletion, costs exactly ONE frame, so no slip size
matches the observed 26-frame burst (or any of the observed 5–33-frame burst
lengths).** The float chain absorbs the displacement within the frame it lands
in: peak frame EVM never exceeds 7.7 % (baseline 4.1 %, threshold 11.9 %), no
preamble detection is ever missed, and payload content re-matches baseline
from the next frame onward. If the hardware bursts ARE slip-triggered, the
5–100-frame extent must come from the fixed-point/RTL receiver's own re-lock
dynamics (FTS/Peak-Search flywheel, CFO-change detector, AGC/carrier state
corruption) — i.e. a STAGE B RTL question — or the trigger is not a single
slip at all (e.g. the previously identified 146 RX carrier-tracking/CFO-dither
instability, or repeated/sustained delivery errors), because no receiver-loop
reconvergence mechanism in the float model stretches a one-shot displacement
across tens of frames. This is consistent with, and quantifies, the earlier
STAGE A observation that the float synchronizers absorb the discontinuity, and
with the 240k RTL result of only a ~2-frame loss per +256-sample tick.

## Caveats

- Float-receiver ceiling, not an RTL measurement: frame detection here is a
  global differential-Barker search that re-acquires instantly; a hardware FTS
  with a predictive flywheel and slower Peak-Search correction can only be
  slower. So "1 frame" is a LOWER bound on the hardware loss per slip — but
  nothing in the float loop dynamics (symbol-sync and carrier-loop time
  constants are ~100–1000 symbols, i.e. <10 % of one 12333-symbol frame)
  can stretch recovery to tens of frames.
- Hard-decision EVM is structurally blind to slips (displaced QPSK symbols
  still sit on constellation points) — hence the hardware seeing pristine ~4 %
  float EVM through the burst is EXPECTED even if slips are occurring, and
  EVM-flatness does not rule the slip hypothesis out. The CRC-equivalent
  payload-mismatch metric is the right instrument (task item 5) and was used
  for the table.
- Single mid-frame events only. A slip landing ON a preamble would destroy at
  most one extra frame. Slip sizes ≥4 are multiples of sps=4 (no fractional
  timing-phase step); the 2-sample bonus rows cover the worst-case
  half-symbol timing-phase jolt and are absorbed just as fast.
- The insert content was 'repeat' (the proven tick's statistically-normal
  signature); make_spliced_iq's other modes were shown content-independent in
  the 240k study.
