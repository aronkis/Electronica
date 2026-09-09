# comb_lagcheck.md — lag UNITS in accept_analyze.py / analyze_comb_census.py

Grep-level check requested by T0b: is "lag 32" (the periodicity the E3 facts
call dominant) 32 frames, 32 records, or 32 loss-events? Two different tools
in this repo compute something called a "lag" over an error/loss train, and
they use two DIFFERENT axes. `analyze_comb_census.py` does not compute a lag
at all — see below.

## `two_jup/accept_analyze.py` — lag units: **transmitted-frame slots (host_seq)**

```
81:    ci = np.flatnonzero(clean)
82:    ct = ts[ci]; cseq = fr['host_seq'][ci].astype(np.int64)
86:    cw = cseq[np.flatnonzero(w)]
96:    lo_ = cw[0]
97:    pres = np.zeros(cw[-1]-lo_+1, dtype=np.int8); pres[cw-lo_] = 1
103:    sp = np.zeros(cw[-1]-lo_+1)
108:        spc = sp - sp.mean(); ac = np.correlate(spc, spc, 'full')[len(spc)-1:]
109:        ac33 = float(ac[33]/ac[0])
```

`cw` is the `host_seq` value of every CLEAN (`crc_ok==1`) frame in the live
window (lines 81/86). `pres` is an array of length `cw[-1]-cw[0]+1`, indexed
by `host_seq - cw[0]` (line 97): **one array slot per transmitted frame
sequence number**, not per logged record and not per loss episode. A gap in
`host_seq` between two clean frames is by construction exactly the count of
frames that never decoded in between (CRC-verified `host_seq` values are
trustworthy; see `two_jup/comb/common.py:loss_slot_trains` docstring). `sp`
(line 103) marks only the isolated (run-length==1) losses on that same
host_seq axis, and `ac[33]/ac[0]` (line 109) is the FFT^-equivalent
autocorrelation of that 0/1 train at **lag 33 host_seq units = 33
transmitted frames**.

Two consequences worth stating:
* This axis SKIPS positions with no clean frame at either end of a gap
  smaller than the sanity window, but never skips a genuine loss — every
  `host_seq` integer between two clean frames gets an array slot whether or
  not any record (good or bad) was ever logged for it. So "lag 32" here means
  32 TX-frame slots elapsed, independent of how many of those slots got a
  bad/magic-bad record logged at RX vs. no record at all.
* `two_jup/comb/comb_autocorr.py` reproduces this axis and this exact
  singles-only construction (`common.py:loss_slot_trains`'s `singles` array);
  its singles-only lag33 values on `two_jup/r3cap/ballpark_*` (fwd −0.035,
  fwd_after 0.204, rev2 0.018) match `accept_analyze.py`'s printed `lag33=`
  values to 3 decimal places on all three usable captures (`rev` is
  UNUSABLE/WEDGED under both tools).

## `two_jup/frame_taxonomy.py` — lag units: **logged RECORD position** (a different axis)

```
118:    err_idx = np.flatnonzero(err)
119:    ei = err.astype(np.float64)
125:    max_lag = min(n // 3, 5000)
128:    if max_lag >= 4 and np.any(ei):
129:        ac = np.correlate(ei, ei, mode="full")[n - 1:]
131:        lag = int(np.argmax(ac[3:max_lag])) + 3
```

`err` (and hence `ei`) is built over `n` = every RECORD read from
`frames.bin` in file order (`fr` is the full structured array, `n = len(fr)`
— see the docstring at the top of the file: "the error-train signatures
... over record index"). This is a DIFFERENT axis from `accept_analyze.py`'s:
it is the position of a LOGGED record (received frame, good or bad) within
the file, not the reconstructed TX host_seq slot. A "lag 32" here means 32
logged records apart — approximately 32 transmitted frames too WHEN the
clean-frame rate is near 100 % (record position and host_seq slot advance
1:1), but the two axes diverge as soon as any frame is entirely unlogged
(never pulled off the ring at all) — record position simply has no entry for
those, while `accept_analyze.py`'s slot axis still reserves a position for
them. At today's residual PER (~3.9–11 %, `two_jup/COMB_STATE.md` /
`two_jup/TXFIX_STATE.md` §8) the two axes are close but not identical.

## `two_jup/analyze_comb_census.py` — no lag concept at all

```
$ grep -n lag two_jup/analyze_comb_census.py
(no matches)
```

This script computes a register-delta bit-error-rate census (`framesync`,
`biterr_rate`, `big_events` = count of `dbe > 5000` samples) from a CSV of
`direct_reg_access` polls — it has no autocorrelation, no lag, and no notion
of frame position at all. The plan's cross-reference to it for "lag units"
does not resolve to any code in this file; treat any historical "lag-N per
`analyze_comb_census.py`" claim as **not traceable to this script** and
prefer `accept_analyze.py` (transmitted-frame-slot units) as the source of
truth for what "lag 33" / "lag 32" means in this campaign's numbers.

## Verdict

"Lag 32" in the E3 facts, sourced from `accept_analyze.py`-family tooling
(and reproduced by `comb_autocorr.py` here), is **32 transmitted-frame
slots** (host_seq units), not 32 logged records and not 32 loss-events. A
separate tool (`frame_taxonomy.py`) uses a record-position axis that is
numerically close but not identical when frames are entirely unlogged.
Neither tool indexes by "loss-event number" (i.e., the Nth loss regardless of
how many good frames separate consecutive losses) — that third
interpretation is not implemented anywhere in this repo.

## RXQ=1 two-request-slot heavy-boundary question — **[inferred]**

Plan citation: `host_app_k5/qpsk_tun.c ~480-500, 615-632, carve_zero
~1268-1277`. Those exact line numbers are from before Task 1's COMB
instrumentation edit landed in this working tree and have shifted; the
current locations for the same logic (grepped 2026-09-03, post-Task-1):

* `carve_zero()` helper: line 478.
* RX_QUEUED (`RXQ=1`) design comment and state: lines 960-990 — "keep TWO
  transfers outstanding: when the fill transfer completes, the other area's
  transfer is ALREADY queued in hardware and starts at the next frame sync
  with no host action" (line 967-968); `rx_nareas = 2` (line 978, "2 =
  legacy behaviour"); `rx_qd` = "area submitted-but-not-yet-running, or -1"
  (line 979); `rx_clean_mask` = "areas drained and free to submit" (line
  980); `rx_q_defer` = "area whose submit awaits the pending slot, or -1"
  (line 983).
* The per-completion host bookkeeping (carve_zero + resubmit for the area
  that just freed) is at lines 1415-1454 (`carve_zero_hdr`/`carve_zero` at
  1419/1438/1443, `rx_q_id[area] = rx_q_nsub++ & 3u` at 1449, `rx_q_defer`
  cleared at 1453-1454) and the drain/re-arm dispatch is at ~1510-1553
  (`rx_fill = (rx_qd >= 0) ? ... : (completed ^ 1u)` at 1524, the
  `rx_clean_mask` / `rx_qd` state machine at 1540-1553).

Reading available from the code alone (grep-level, **not traced through a
runtime execution or measured with a witness**): with `rx_nareas = 2`
(RXQ=1's default), there are exactly two RX areas cycling; each transfer
boundary (every `rx_multi` = `-M` frames, e.g. every 16 frames at `-M 16`)
completes one area and the OTHER area's transfer is already queued and
running (that is the whole point of the design per the comment at
960-968). The host's per-boundary work (`carve_zero` the freed area + submit
it, lines 1438/1443/1449) happens on EVERY boundary, not every other one —
the design comment does not describe alternating light/heavy boundaries, it
describes avoiding a host round-trip AT ALL on the "heavy" boundary (the
other transfer starts with zero host action) while the "light" bookkeeping
(carve+resubmit of the just-freed area) still happens once per boundary,
same cost every time. So on a **grep-level reading**, RXQ=1's two-area design
does NOT obviously make every second 16-frame transfer boundary heavier than
the other in a way visible from the state machine alone — both areas run the
identical carve_zero/submit sequence when they complete. If a lag-32 (=
2×`rx_multi` for `-M 16`) comb exists BECAUSE of an every-other-boundary
asymmetry, the asymmetry would have to come from something not visible in
this state machine (e.g. a timing/scheduling effect, or an interaction with
`rx_q_defer`/`rx_clean_mask` when the pool is momentarily short an area) —
this reading cannot confirm or rule that out, and no witness/measurement was
taken here. **[inferred, code-reading only]**.
