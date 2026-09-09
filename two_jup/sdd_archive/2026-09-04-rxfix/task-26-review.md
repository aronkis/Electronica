# Task 26 review — the RX carve re-anchor (host resync fix)

**VERDICT: PASS.**

**First line for Task 27 (deploy + judge on 148):** (a) the judge leg must run
with `QPSK_RXQ_ZEROHDR` **unset** — it is the default, but nothing in
`qpsk_tun.c` enforces or even warns when it is combined with the new
`QPSK_RX_RESYNC=1` default (Finding 1); (b) do not trust any ad-hoc script that
does a bare `tail -1 /dev/shm/qpsk_tun.log` for `crc_drop=` or similar during
this leg (`loop_sweep.sh`, `timing_fullarm.sh`, `arq_tune_ab.sh`,
`arq_engage_probe.sh`, `arq_per_ab.sh`) — the new `rxresync:` line is now the
true last line every interval and none of those scripts filter on `stats:`
first (Finding 5). This is pre-existing fragility (the deployed
`-DQPSK_RXQ_STAT` build already inserts `rxqstat:`/`rxqexp:`/`rxqstall:` lines
after `stats:`), one line worse after this change. The judge leg's own
pipeline (`capture_r3.sh` via `w1leg_go.sh`) is **not** affected — it greps
`"stats:"` before `tail -1` everywhere (verified below) — so P1–P13 are
readable as registered.

Findings: **0 blocking, 0 medium, 5 low/informational** (numbered below).
Everything the report and pre-registration claim was reproduced.

---

## What was reproduced (all from a pristine `git archive HEAD` tree, `c05126ce1eaf`)

1. **Full `make test`, unmodified sources**, in a scratch dir separate from the
   working tree:
   ```
   frame tests: 578 run, 0 failed
   k5 tests: 89 run, 0 failed
   qpsk_ber_selftest OK / whiten tests: OK / qpsk_seq_selftest OK
   txq tests: 25 run, 0 failed
   txlog/join tests: 25 run, 0 failed
   test_rxresync: 40 checks, 0 failures
   ```
   Every count matches `task-26-report.md` §5 exactly.

2. **The deployed build line**, reproduced verbatim from
   `two_jup/comb/deploy_daemon_go.sh:91` (`gcc -O2 -Wall -DQPSK_CARVE_2MB
   $NAKKEEP -DQPSK_RXQ_STAT $FLAGS -o qpsk_tun ...`) with `NAKKEEP=
   -DQPSK_ARQ_NAKSTAT`:
   ```
   strings qpsk_tun | grep -c nakstat   -> 4   (matches)
   strings qpsk_tun | grep -c rxqstat   -> 1   (matches)
   strings qpsk_tun | grep -c rxresync  -> 1   (matches)
   md5sum qpsk_tun                       -> 023d7bfd6db5706e37465ea0ce7bd967
   size                                  -> 97768 B, ELF 64-bit x86-64 PIE
   ```
   All four numbers and the md5 match `task-26-report.md` §6 and
   `RXFIX_HOSTFIX_PREREG.md` §"Binary under test" exactly.

3. **The pre-change md5**, built the same way from commit `8849a1b` (the
   commit immediately before the fix): `b722021d61970b1aa71127071e87f259`,
   matching the report's "pre-change build" line exactly.

4. **`test_rxresync` under the full deployed flag set**
   (`-DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT`, in addition to `-DQPSK_CARVE_2MB`):
   builds `-Wall -Wextra -Werror` clean, 40/40 pass — matches report §6's
   closing claim.

5. **`test_k5` pristine-tree pre-existing failure**: building `git archive
   8849a1b^` (i.e. HEAD before the `test_k5` repair) reproduces both
   `AXR_HOLE_SZ`/`AXR_RENAK` undeclared errors, confirming the breakage
   predates Task 26 and Task 26's own work.

---

## 1–2. Geometry and the 568-byte displacement

Verified against the actual source, not just the report's prose:

* `F1536_PKT_BYTES = 1528`, `F1536_TX_XFER_BYTES = 3080`
  (`host_app_k5/qpsk_frame.h:45-46`); `SLOT_BYTES` resolves to `2048` under
  `-DQPSK_CARVE_2MB` (`qpsk_hw.h:146`) and is used only for `tx_slot_stride`
  (`qpsk_tun.c:202`, TX-side addressing at `qpsk_tun.c:840`) — never in the RX
  drain.
* `rx_pump_queued`'s drain reads at `rx_dscan*pkt_bytes` (+ the new
  `rx_dphase`), confirmed at `qpsk_tun.c:1764-1765`; `DMAC_X_LENGTH =
  rx_multi*pkt_bytes - 1` at `qpsk_tun.c:1524` (16×1528 = 24448, matches the
  report's table).
* `bringup_r2r3.sh:171` is `RXM_EFF=${RXM:-16}` verbatim, confirming `-M 16`
  is indeed the deployed default and the ceiling arithmetic (`rx_multi + 1 =
  17`) is grounded in the actual launch script, not an assumption.
* The 2.3 % `magic_off` chance floor is independently documented in
  `two_jup/comb/README_hostlog.md` §3.3 ("chance floor of ~2.3 % ... 1527 ×
  2^-16"), which the report cites correctly.
* **The "split across two slots" claim was independently re-derived** by
  hand-tracing `fill_area()`'s byte layout in `test_rxresync.c` (a 960 B
  deletion at frame 5 of 16, `PB=1528`): the fixed-stride parser's slot 5 does
  contain frame 5's true header + 568 B of its payload, spliced to the first
  960 B of frame 6's bytes — a 12-byte header check alone cannot see this, a
  full-frame CRC check correctly rejects it, and check **1b** (a one-slice
  window, `n == PB`, must return `d < 0`) is a real, load-bearing falsifier
  for this claim, not a decorative check.
* Arithmetic re-verified independently: `438/572901 = 0.076453 %`,
  `293/143 = 2.049`, `791/143 = 5.531`, `145/143 = 1.014` (sum 8.594, matches
  "8.59 frames"), `309/572520 = 0.05397 %`, `1229/572901 = 0.21452 %`,
  `1956/871805 = 0.22436 %`. All match the report and `FWD_RESIDUAL_0p22.md`
  to stated precision.

## 3. Safety of the fix

* **Bounded scan.** `qpsk_frame_resync()` (`qpsk_frame.c:181`) internally
  re-clamps `lim` to `pkt_bytes - QPSK_RESYNC_STEP` regardless of what
  `max_shift` the caller passes (`qpsk_frame.c` lines just before the scan
  loop) — this is defensive beyond the documented "callers must pass
  max_shift < pkt_bytes" contract; even a hypothetical future caller that
  violates it cannot make the scan "find" the ordinary next slot. Verified by
  check 1c (a frame at exactly `+pkt_bytes` returns `d < 0`).
* **8-byte-aligned volatile loads only.** `qpsk_frame_resync` refuses any
  `pkt_bytes % QPSK_RESYNC_STEP != 0` geometry outright (`qpsk_frame.c`), and
  `rx_resync_try` (`qpsk_tun.c:1667`) re-checks the same thing before ever
  touching the carve. Confirmed by check 1g and 1d.
* **Re-anchor after logging.** In `rx_pump_queued`, `st.crc_drops++` and
  `framelog_record_fail(slice, pkt_bytes)` (`qpsk_tun.c:1831-1832`) run
  strictly before `rx_resync_try(...)` is called (`qpsk_tun.c:1839-1846`).
  `qpsk_join.h` is untouched (`git diff a00ab93^ a00ab93 --
  host_app_k5/qpsk_join.h` is empty) — the on-disk `failhdr` ABI is
  unmodified.
* **Queued drain only.** The full `qpsk_tun.c` diff for commit `a00ab93` is
  exactly 10 hunks, all inside: the new static block + `rxresync_dump()`
  (`qpsk_tun.c:1038-1093`), `rx_arm_queued`'s reset (`:1569`),
  `rx_q_on_complete`'s reset (`:1633`), the new `rx_resync_try` function
  (`:1640-1706`), and three edits inside `rx_pump_queued` itself
  (`:1753-1846`), plus the `main()` env-var block (`:3287-3297`). The legacy
  drain (`rx_pump_frame`, `qpsk_tun.c:1903-1985`, reads at plain
  `rx_dscan*pkt_bytes`, no `rx_dphase` anywhere) and the cyclic ring
  (`rx_pump_cyclic`, `:1374`) are untouched — confirmed by direct inspection,
  not just by the report's claim. The eager scan (`rx_fscan`,
  `qpsk_tun.c:1859-1866`, inside the SAME function as the changed drain) also
  still uses the plain fixed stride, confirmed unchanged.
* **Counter logic has no double-counting.** Traced by hand and cross-checked
  against the actual (executed) test values: `rxr_recovered` increments in
  exactly two mutually exclusive places — inside `rx_resync_try` on a
  successful scan (the first recovered frame of a burst) and at
  `qpsk_tun.c:1828` (`if (m >= 0 && rx_dphase) rxr_recovered++`) for every
  later frame decoded successfully while still displaced — and these two
  sites can never both fire for the same slice in the same iteration (one
  requires `m < 0`, the other `m >= 0`). `test_rxresync` 2c's
  `rxr_recovered == 10` (1 direct hit + 9 subsequent displaced-but-successful
  decodes, for a synthetic burst that recovers frames 6–15) is consistent with
  this trace and was independently confirmed by re-running the test.
* **The `tail_lost` `break` is not a new hazard.** It exits the `while
  (rx_dscan < rx_multi)` loop with `rx_dscan` still `< rx_multi` — new,
  because the loop previously only ever ended by exhaustion. Read
  `qpsk_tun.c:1848-1855`: the post-loop cleanup (`rx_drain = -1;` then
  `rx_q_submit`/`rx_clean_mask` bookkeeping) runs unconditionally after the
  loop regardless of which exit path was taken, so the area is still
  correctly retired and there is no re-entry into a half-drained area.
* **`QPSK_RXQ_ZEROHDR` interaction — Finding 1 (LOW, actionable for Task
  27).** Confirmed by reading the code: `rxq_zerohdr` defaults to `0`
  (`qpsk_tun.c:1205`), and with it off, `rx_q_submit` fully zeros the entire
  transfer area before each transfer (`carve_zero(rx_area_virt(area),
  rx_multi*pkt_bytes)`, `qpsk_tun.c:1523`), so no stale bytes from an earlier
  lap exist anywhere inside `rx_dlimit` for the scanner to find. Under
  `QPSK_RXQ_ZEROHDR=1`, only the first 8 bytes of each nominal
  `pkt_bytes`-aligned slot are cleared (`carve_zero_hdr`, `qpsk_tun.c:1498`),
  leaving up to `pkt_bytes-8` stale bytes per slot from the previous lap; the
  new sub-slot-granularity scanner (8-byte steps across a
  non-slot-aligned window) could in principle validate a stale frame at a
  non-zero sub-slot offset that a slot-aligned parser never would have seen.
  This is exactly what the report and pre-registration disclose and direct
  the judge leg to avoid (zerohdr off, its default). **What is missing:
  nothing in `qpsk_tun.c`'s env-var parsing (`:3288-3297` for
  `QPSK_RX_RESYNC`, `:3325-3329` for `QPSK_RXQ_ZEROHDR`) warns or refuses when
  both are set together.** Not a blocker — the shipped default combination is
  safe and the judge leg is explicitly directed away from the dangerous
  combination — but Task 27 must not set `QPSK_RXQ_ZEROHDR=1` on this leg, and
  a follow-up hardening (refuse-at-startup or auto-disable) would close the
  gap for good.
* **`rx_raw_tap` bypass confirmed.** `rx_raw_tap` is called only at
  `qpsk_tun.c:1791`, inside the direct per-slice read path, never inside
  `rx_resync_try`. The report's disclosed limitation ("a future `-S`
  raw-scorer leg would miss every recovered frame") is accurate, not merely
  asserted.

## 4. Test quality

* `test_rxresync.c` has **40 `CHECK()` invocations** (41 occurrences of the
  string `CHECK(` minus the macro's own `#define` line) — matches the
  report's "40 checks" exactly.
* Check **1a** constructs a whole frame at exactly the measured 568 B phase
  inside a `2*PB` window and confirms it decodes with its own seq/len; check
  **1b** is the falsifier proving a one-slice window can never validate the
  same displaced frame (see above) — together these are a real test of the
  "split across two slots" claim, not just an assertion.
* The drain-level test (**2b/2c**) constructs an actual displaced-by-568
  synthetic burst (`fill_area(5)`, a 960 B deletion) and drives the real
  deployed `rx_pump_queued()` against it: resync OFF loses 11 of 16 slots,
  resync ON loses exactly 1 (the destroyed frame) and recovers the other 10 —
  a genuine before/after recovery proof, run against the shipped drain
  function via the same `#define main qpsk_tun_main` / `#include
  "qpsk_tun.c"` trick `test_k5.c`/`test_txq.c` already use.
* **Negative control present and correct** (**2e**): W1-baseline-style comb
  garbage (high-entropy bytes with a magic at offset 64, matching the real
  W1 leg's dominant offset) is confirmed to still classify as `QPSK_FC_MAGIC`
  with `magic_off == 64` via the actual `qpsk_fail_class`/`qpsk_first_magic_off`
  functions, does not trigger `resync_568`/`resync_other`, and gives
  byte-identical accounting with resync ON and OFF.
* **The "hit at exactly +pkt_bytes is not a re-anchor" test exists** (**1c**)
  and is distinct from the phase-568 test.
* **Finding 2 (LOW, coverage gap, not correctness).** All 40 checks run
  `drain_all()` with `rx_drain_budget = 0` ("unbounded"); the deployed default
  is `4` (`qpsk_tun.c:1044`, `QPSK_RX_DRAIN_BUDGET`). The path where
  `rx_pump_queued` returns 0 mid-burst on budget exhaustion and resumes on a
  later call — with `rx_dphase` carried across the pause as file-scope state
  — is therefore not exercised by the committed suite. **I checked this
  independently**: copying `test_rxresync.c` into a scratch build and
  changing only `rx_drain_budget = 0` to `rx_drain_budget = 4` (the deployed
  value) still gives `test_rxresync: 40 checks, 0 failures` — the
  pause/resume path preserves `rx_dscan`/`rx_dphase` correctly, as expected
  since both are ordinary file-scope statics recomputed fresh into `rx_doff`
  on re-entry. Not a blocker; recommend adding this as a permanent case (rerun
  2c with `rx_drain_budget=4`, same asserted totals) in a follow-up so this
  isn't re-verified by hand each time.

## 5. Pre-registration

* **P1 floor recomputed independently**: `(293+145)/572901 = 0.076453 %`
  against the registered bound of `0.08 %` — matches the report's
  "0.0764 %... ~5 % of headroom" exactly.
* **F1–F5 are each concretely falsifiable** (each names a specific counter
  combination and a disposition — REPORT/PARTIAL/discard-and-rerun/re-open) and
  are not overlapping in a way that would make an outcome ambiguous. **Finding
  3 (LOW, non-blocking, per advisor review — do not inflate this).** There is
  no named falsifier for "`resync_568` stays far below the predicted event
  rate while PER also stays roughly flat" (a variant of "the fix barely
  engages" short of full F1). In practice this shows up as P4 failing on its
  own and would be reported as an anomaly against the registered predictions;
  it does not undermine F1–F5's coverage of the main risk scenarios (recovery
  fails entirely, recovery partial, cursor bug, contamination, wrong dominant
  offset).
* **P12/P13 are correctly labeled informational, not falsifiers** — verified
  they do not appear in the `## 3. Falsifiers` section and are explicitly
  called out as "neither outcome falsifies the fix" / "not a broken
  instrument."
* **The same-binary A/B control is real**: `QPSK_RX_RESYNC=0` forces
  `rx_resync = 0`, and `rx_resync_try` returns `-1` immediately when it is
  false (`qpsk_tun.c:1675-1676`), so `rx_dphase` can never leave 0 — verified
  by test 2b (`rx_dphase == 0` throughout with resync off) and by direct
  reading.
* **Log-consumer check (done at the advisor's suggestion, not in the original
  6 items).** `capture_r3.sh` (which `w1leg_go.sh` calls for the judge leg's
  own health gate) uses `grep "stats:" $L | tail -1` at every site that reads
  `qpsk_tun.log` (`capture_r3.sh:76,86,94,322,325`) — robust to the new
  trailing `rxresync:` line. `capture_r3.sh:363` `scpput`s the whole log file
  to `cap/qpsk_tun.log`, so the `rxresync:` counters the pre-registration
  reads (P4/P5/P6/P12) are captured intact. **Finding 5 (LOW, informational,
  first line above).** Several *other*, non-judge-leg scripts
  (`loop_sweep.sh:63`, `timing_fullarm.sh:62,64`, `arq_tune_ab.sh:39`,
  `arq_engage_probe.sh:32`, `arq_per_ab.sh:39`) do a bare `tail -1
  /dev/shm/qpsk_tun.log` (sometimes piped to `grep -oE 'crc_drop=...'`) with
  no `stats:` filter. This was already fragile before Task 26 (the deployed
  `-DQPSK_RXQ_STAT` build already appends `rxqstat:`/`rxqexp:`/`rxqstall:`
  after `stats:`, none of which carry `crc_drop=`), and Task 26 adds one more
  trailing line, marginally worse but not a new class of bug, and not on the
  judge leg's critical path.

## 6. The `test_k5` repair (commit `8849a1b`)

* Confirmed **mechanical and minimal**: exactly six identifier renames
  (`AXR_HOLE_SZ`→`axr_hole_sz`, `AXR_RENAK`→`axr_renak`) in `test_k5.c`, no
  other lines touched (`git show 8849a1b -- host_app_k5/test_k5.c`, 6
  insertions/6 deletions).
* Confirmed the renamed variables exist with the claimed defaults:
  `axr_hole_sz = 512u` and `axr_renak = 64u` (`qpsk_tun.c:2122,2124`),
  matching "the live table size the old constant named" / "the re-NAK
  interval."
* Confirmed the breakage predates this session: commit `0822e3e` (31 Jul, an
  unrelated cross-link ARQ commit) is what turned the `#define` constants
  into runtime variables without updating the test; building `git archive
  0822e3e` (or any commit up to `8849a1b^`) reproduces both undeclared-symbol
  errors.
* Confirmed `test_k5` passes 89/89 after the rename, both under `-Wall
  -Wextra -Werror` (via `make test`) and standalone.
* Committed separately from the Task 26 diff (verified: `a00ab93`'s own
  7-file diff does not touch `test_k5.c`), matching the stated rail
  ("committed separately... reviewable on its own").

---

## Summary table

| # | severity | area | finding |
|---|---|---|---|
| 1 | LOW | safety | `QPSK_RX_RESYNC=1` + `QPSK_RXQ_ZEROHDR=1` is an unguarded, disclosed-but-not-enforced risk; Task 27 must not set zerohdr on the judge leg |
| 2 | LOW | test coverage | committed tests all use `rx_drain_budget=0`; the deployed default (4) is untested in-repo, though verified by hand to behave identically |
| 3 | LOW | pre-registration | falsifier set has no explicit entry for "resync_568 far below prediction, PER flat"; subsumed by P4 failing, not a real gap |
| 4 | — | — | (reserved; no 4th independent issue found — the diff, ABI, and scope-confinement claims all checked out exactly as written) |
| 5 | LOW | tooling | several ad-hoc (non-judge-leg) scripts do a bare `tail -1` on `qpsk_tun.log`; pre-existing fragility, one line worse now, judge leg itself unaffected |

No MEDIUM or HIGH findings. The build, the strings fingerprints, both md5s,
the geometry arithmetic, the scope confinement (queued-drain-only), the
counter bookkeeping, the falsifiability of the pre-registration, and the
`test_k5` repair all reproduce exactly as `task-26-report.md` and
`RXFIX_HOSTFIX_PREREG.md` state them.
