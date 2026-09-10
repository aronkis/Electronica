# STAGE A' — burst-length study: sample-slip size vs frames-to-recover (R3/f1536)

Question: can a SINGLE ADC-delivery/SSI sample slip (insertion or deletion, the
family of the proven forward-link 256-sample tick on board 148) reproduce the
reverse-link "26-frame burst" signature — 5–100 consecutive frame losses while
the captured input IQ stays pristine (float EVM flat ~4%)?

Method: splice one disturbance of {4, 32, 64, 128, 256, 512} samples (plus a
2-sample half-symbol bonus row), insert AND delete, mid-frame into a 10 M-sample
segment of the REAL R3 reverse capture
`two_jup/r3cap/hunt_auto_20260731_211829/pair.iq` (genuine link IQ, ~202 frames,
float-decodes clean), then run the float receiver and count frames after the
splice that are (a) MISSED — no preamble sync at the 12333-symbol cadence, the
hardware CRC-hard-fail analog — or (b) EVM-DEGRADED, before 3 consecutive clean
frames.

## Files
- `bs_front_end.m` — float front end (parameterized copy of `evm/evm_ideal_ref.m`
  stages; that file is untouched) returning per-frame starts / preamble corr /
  EVM instead of only aggregates.
- `bs_perturb.m`   — in-memory insert ('repeat' content, per
  `tick_repro/make_spliced_iq.m`) / delete splice.
- `bs_score.m`     — frame-slot walker: missed + degraded until 3 clean frames.
- `run_burst_study.m` — driver; writes `burst_study_results.mat`, prints the table.
- `RESULTS.md`     — the table + verdict.
- `run_log.txt`    — full MATLAB log of the recorded run.

## Run
```
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch \
  "cd('tick_repro_r3/burst_study'); run_burst_study"
```
