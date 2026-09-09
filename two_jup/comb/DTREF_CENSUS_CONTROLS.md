# DTREF_CENSUS_CONTROLS — negative control (loopback) + attempted second positive

Desk-only. Tool: `two_jup/comb/tx_sel8_desk/dtref_census.py FILE.bin [--i15]` (found at
that path, not `two_jup/comb/dtref_census.py`). It censuses consecutive `slot==1` groups
of the DDRCAP-v2 sidecar word (`ddrcap_mark_fec = {ddrcap2_slot_r, ddrcap2_side}`,
`TxRxComposite.v` per `two_jup/skidfix/ddrcap2_inject.py:237-264`) and counts
`dtref==0` (deletion), `dtref==2` (insertion) between consecutive recovered-symbol
updates.

## 0. Does the tool "support" sel6/sel9? No — checked, not assumed [silicon+netlist]

The sidecar word is unconditional (packed for every capture regardless of selector), but
its update *cadence* is gated by `ddrcap_valid_beat`, which is selector-dependent
(`two_jup/skidfix/ddrcap_inject.py:520`):

```
wire ddrcap_valid_beat = (ddrcap_sel_r <= 4'd8) ? ddrcap_mux_valid : ddrcap_bitword_rdy;
```

Only sel 8/12/13/14/15 tie this to a rate the census's "4 records = 1 recovered symbol"
assumption matches (`enb_1_2_0` sample domain, or `dc_corrvalid` for sel12; confirmed for
sel8/13 in `TX_SEL8_DESK.md` §1). **sel6 (≤8, old raw mux valid) and sel9 (>8,
`ddrcap_bitword_rdy`, packet-level) run on unrelated valid domains** — the tool's grouping
does not correspond to symbol time for either. This is visible directly in the runs below:
100 % of "slot==1" adjacent pairs land in the `>2` (\"DMA drop burst\") bucket for both,
with implausible frame counts (sel6: 5461 frames in a span where sel13 sees 1890; sel9c:
43582 frames) and `--i15` histograms that are flat/binomial rather than the sparse
sel13-only interpolator-strobe shape — i.e. garbage, not a measurement. **Verdict on
applicability: tool supports {8,12,13,14,15} only; sel6 and sel9 results below are void,
not zero.**

## 1. Negative control — sel13, digital loopback on 148, 2026-09-02 [silicon]

| file | groups | dtref==0 | ==1 | ==2 | net | rate |
|---|---|---|---|---|---|---|
| `beatcap/20260902_192051_sel13/mid.bin` | 16,777,216 | **0** | 16,744,451 | **0** | 0 | **0.000 ppm** |
| `beatcap/20260902_192051_sel13/onset.bin` | 16,777,216 | **0** | 16,744,451 | **0** | 0 | **0.000 ppm** |

Zero deletions and zero insertions on both segments — not one-sided-but-small, exactly
none. No event series exists, so inter-event spacing and lag-32 autocorrelation are **N/A
(no events)**, which is itself the expected loopback signature (contrast with the on-air
sel13/sel8 files in `TX_SEL8_DESK.md`: 39–59 deletions, lag-32 autocorrelation +0.824 vs a
p95 null of 0.136). `--i15` on these two: strobe histogram sparse and centered at count=1
(mid: {0:511, 1:16,749,579, 2:2,580}), consistent with a real, quiet interpolator — not
the flat/binomial shape seen on sel6/sel9c below.

## 2. Attempted second on-air positive — void, not a result [silicon]

- `beatcap/20260902_185552_sel6/mid.bin`: **void per §0** (100 % >2 bucket, 5461
  implausible "frames", flat I[15] histogram). Not usable as sel6-negative-control either.
- `comb/runs/20260903_191410_legA_a1r2/ddrcap_sel9c/sel9_leg.bin` (a1r2, on-air):
  **void per §0** (100 % >2 bucket, 43,582 implausible "frames"). Also separately flagged
  by its own `run.log`: `post capTAP not golden -- capture not credited`, so it would be
  disqualified as evidence even if sel9 were in the supported set.

No valid second positive control was obtained; only the two prior on-air files already in
`TX_SEL8_DESK.md` §3 stand.

## VERDICT

**CONTROL SUPPORTS.** [silicon] The negative control (sel13, digital loopback, no
inter-node clock offset) shows **0 deletions / 0 insertions / 0.000 ppm** on both
segments — exactly the "balanced or none" prediction, and qualitatively different from
the strictly one-sided ~2.5 ppm seen on-air. The attempted sel6/sel9c additions are
**inapplicable to this tool** (valid-domain mismatch, confirmed from the netlist, not
merely inferred from noisy output) and are reported void rather than folded into either
side of the verdict.
