# Task 2 fix round (86223a8) — re-review

**Verdict: Approved.**

Scope: `git show 86223a8` against the four Important findings of
`task-2-review.md`. Read-only, no board contact.

1. `comb_census.py:115-127` (`failhdr_window_mask`) clips `fh_arr` to the same
   `[SETTLE_S, live_end)` window as `fail_class_census` before
   `onset_histogram`/`class4_split` run; raw+windowed counts kept in JSON.
   Tested: `test_comb_tools.py:281-298` builds a record before SETTLE_S and
   one after `live_end`, asserts the mask excludes both and that the
   excluded record's `fzo==0` does not leak into `delivery_hole_fzo0`.
2. `--delivered` added (`comb_census.py:225-228`, `joinlog.read_delivered_seqs`);
   `tx_rx_join(..., delivered_seqs=)` classifies decoded seqs absent from the
   set as `DECODED_NOT_DELIVERED`, stays the old placeholder string when
   omitted. Tested: `test_comb_tools.py:303-329` (with/without `--delivered`)
   and `:331-338` (round-trip read).
3. `comb_autocorr.py:2-10` and `common.py:94-101` (`loss_slot_trains`
   docstring) now say "reconstructed TX-slot (host_seq) axis ... ONE ARRAY
   SLOT PER TRANSMITTED-FRAME SEQUENCE NUMBER", explicitly distinguished from
   `frame_taxonomy.py`'s record-position axis.
4. `task-2-report.md:48` adds lag 65 (`+0.670`) to the `fwd_after` row and
   states the `k×32+1` slip observation (lines 63-66); `comb_autocorr.py:42-53,108-113`
   prints top-5 lags with `harmonic_family()` (nearest k×32 and k×33, signed
   slip) for every run.

Minors 5-8 also addressed in this commit (comment fix, softened permutation-null
claim, phase p-value caveat, fail_class×crc_ok cross-tab) — not required for
this gate but present.

`python3 -m pytest two_jup/tests/test_comb_tools.py -q` → **19 passed** (2.34s).
