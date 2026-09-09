# Capture manifest — health-gated inventory (2026-08-26)

Produced by `two_jup/sim_repro/health_sweep.sh` → `capture_health_20260826.csv`
(456 captures: every `pair.iq` under `r3cap/`, plus `prewedge/`, `evmcap/raw.iq`,
`floatgap_n3/`, `paired/`). Gate = `check_capture_health.py` (occupied BW
15–30 MHz at −20 dB + envelope autocorr < 0.90). Supplementary −10 dB BW pass
on the wide-BW failures: `sim_repro/capture_health_bw10_20260826.csv`.

## Headline counts

- **HEALTHY: 107** (26 fwd, 72 rev, 9 undirected) — the "only two verified
  captures" premise from KNOWN_HOLES is obsolete; 98 of the healthy captures
  carry `frames.bin` ground truth.
- DEGENERATE: 349, in three distinct modes:
  1. **True #48 stale-DDR ramps: 3** (`romair_20260823_115206`,
     `romair_20260825_220911`, `romair_20260826_083927` — BW 2.88 MHz, env
     0.994–0.9995 at lag 256). Matches the known record exactly.
  2. **BW-low / no-signal: ~12** (BW < 15 MHz, e.g. wedged
     `beatfix_accept_*_ctl0` 0.74 MHz, `areas a4m16_c2` 0.00).
  3. **BW-wide with CLEAN envelope: 334** — the −20 dB occupied-BW measure is
     inflated by the noise floor on low-SNR (mostly reverse) captures. The
     gate was calibrated on the forward reference only. At −10 dB, **139 of
     them re-enter the 15–30 MHz window** (`HEALTHY-NOISEWIDE` in the bw10
     CSV) — usable with a float-decode confirmation; the remaining 183 stay
     wide even at −10 dB and are excluded.

**Gate finding (feeds `check_capture_health.py` maintenance):** the BW upper
bound produces false DEGENERATE verdicts on noise-widened reverse captures;
envelope periodicity separates them perfectly from the real #48 ramps. A
−10 dB threshold variant recovers 139 captures.

## Class-coverage picks (used by the sim-repro campaign)

| capture | dir | verdict | ground truth | role |
|---|---|---|---|---|
| `singles_reread/pair.iq` | fwd | HEALTHY (22.16 MHz / 0.52) | frames.bin, regs_cap | E1/E5 primary (the 08-12 replay reference) |
| `cp1_verdict2/pair.iq` | fwd | HEALTHY | frames.bin + **fslog_148.bin** | E1 replication capture #2 (CP1-instrumented) |
| `cp1_verdict/pair.iq` | fwd | HEALTHY | frames.bin + fslog_148.bin | E1 spare |
| `singles_disc/pair.iq` | fwd | HEALTHY | frames.bin + **txlog_146.bin** | E3 (feeder-gap/mute cross-check) |
| `romair_20260824_221024/pair.iq` | fwd (ROM) | HEALTHY | float_perframe.csv | float-zero control (H-9 leg 1) |
| `evm_swap_A/pair.iq` | fwd | HEALTHY | frames.bin, evm.csv | E6 ladder input |
| `accept_rxq_20260812_160833_r{1,2,3}` | fwd | HEALTHY ×3 | frames.bin | E1 extension / E4 burst search |
| `mab_20260809_*`, `msweep_M*`, `accept_rxq` rev set | rev | HEALTHY (many) | frames.bin | E7 reverse replay pool |
| `bigiq_093328_a3/pair.iq` (320 MB) | rev | HEALTHY | frames.bin | E4/E7 long-window (1.3 s) |
| `prewedge/*` (5 × 320 MB) | ? | DEGENERATE (wide) | — | excluded |
| `revlong`, `bigiq_a1/a2/a4` | rev | DEGENERATE (wide) | — | excluded pending noisewide-confirm |

E4 (burst class) note: healthy windows are ≤1.3 s vs a 2–3 min burst cadence;
whether any healthy capture window overlaps a burst is determined from its
`frames.bin` hole scan, not assumed.

Full data: `capture_health_20260826.csv` (all 456 rows),
`sim_repro/capture_health_bw10_20260826.csv` (334-row recheck at −10 dB).
