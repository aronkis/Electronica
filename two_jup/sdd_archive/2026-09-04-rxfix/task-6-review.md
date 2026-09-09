# Task 6 (T2) review [desk, read-only]

Reviewer commit under review: HEAD (`1846cef`, branch `per-under-1pct-2026-07`); T2 work spans
`2205695..1846cef`.

## Verdict: PASS

Injector is safe and matches `txfix_inject.py`'s shape exactly (exactly-once anchors, per-variant
markers, 3 loose mirrors + both `TxRxCompo_ip_v1_0.zip` members + `verify_zip`, `--sim-tree`
skips zips entirely, idempotent). `python3 -m pytest two_jup/skidfix/test_rxfix_inject.py -q` →
**39 passed**. Confirmed against the real flashed txfixF3 kit (3 loose mirrors present under
`jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/{hdlsrc,ipcore/TxRxCompo_ip_v1_0/hdl,
vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl}` + 2 zips). Reproduced from committed data: R1
`f_m10` loss 23.04% with lost indices byte-identical to `q_m10` baseline; R2 `g_m10` 34.80%;
s=0 `_deliv.txt` byte-identical for both variants against `r_p000`; the threshold-path table in
COMB32_SRO_FIX_SIM.md §1.3.3 (277,556,084 → 1,768,964 at tref 30, 277,691,012/277,822,324 at
tref 62, threshold ≈208M) reproduces exactly (raw `d_m10_corr.txt` column ×4) from
`d_m10_corr.txt`; strobe-spacing claim (62,500 strobes, 3/4/5-sample spacing, 62,353 at 4)
reproduces exactly from `e_m10_ring.txt`. No large/binary files committed in the T2 diff, no
`.iq`/board-contact evidence.

**Note on the tiled-stimulus caveat**: mid-review the branch tip advanced from `498c3f3` to
`1846cef` (commits `655666b`/`1846cef`, same session) which withdrew the "32-symbol alignment
ambiguity is present at all times" claim as a binning artifact of the tiled stimulus
(`gen_sro_stim.py:64-68` tiles one TX frame). At current HEAD the caveat is present and, in
fact, stronger than a caveat — the claim is withdrawn outright, in both
`COMB32_SRO_FIX_SIM.md` §1.3.5 and `task-6-report.md`, each citing `gen_sro_stim.py:64-68`. The
remaining "+32 excursion frames decode correctly" claim (§1.3.3 row C) is not itself withdrawn,
but the report's R2 control argument (predicted rise confirmed at 11.84%/34.80% vs baseline)
is a genuine, tiling-independent check against the "any offset hashes the same" objection, so
that claim is adequately supported.

## Important

- None outstanding at HEAD. (The tiled-stimulus omission observed against an earlier commit in
  this branch's history no longer applies — see note above.)

## Minor

- `task-6-report.md` deliverables table (line 15) still says the injector test suite has
  "(28)" tests; the Rails section (line 91) correctly says "39 tests green" and the actual
  count (`pytest` output) is 39. Stale number from before the R2 tests (11 more) were added;
  cosmetic, no functional impact.
- `rxfix_inject.py`'s docstring header comment says "Loose .v files are patched in place..." and
  the R1 fix-variant description block is long-form prose duplicated near-verbatim inside the
  Verilog comment it injects (`PD_ASSIGN_NEW`) — harmless (matches `txfix_inject.py`'s style of
  self-documenting patches) but worth trimming if the injected comment block grows further.

## Not checked

- Vivado build/place-route (task states none was run; resource/timing note in
  COMB32_SRO_FIX_SIM.md §4 is explicitly [inferred], consistent with the report's own framing).
- Silicon/board legs (task states none; commit messages and diff confirm no board-contact
  evidence).
