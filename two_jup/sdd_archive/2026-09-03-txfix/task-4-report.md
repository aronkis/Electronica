# Task 4 (T0c) report — rig scripts, DRY-only

Status: complete. No board contact at any point (every run DRY=1; ssh/scp PATH-shimmed
and proven uncalled; SENTINEL_STOP mtime verified unchanged before/after every run).

## Files

- `two_jup/skidfix/flash_148_txfix.sh` — copy of `skidfix/flash_148_ddrcap2.sh`. Exactly
  four lines changed (rest byte-identical, comments included):
  ```
  -EXP=${1:?usage: flash_148_ddrcap2.sh <md5-12>}; BAK=1cd0cd752aa6
  +EXP=${FLASH_MD5:?}; BAK=${FLASH_BAK:-638b36de3493}; TAG=${FLASH_TAG:?}
   [[ "$EXP" =~ ^[0-9a-f]{12}$ ]] || { echo "FATAL: <md5-12> must be exactly 12 lowercase hex chars (got: '$EXP')"; exit 1; }
  -BB=$ROOT/boot_known_good/BOOT.BIN.148.ddrcap2.$EXP
  -DRY=${DRY:-0}; LOG=$D/skidfix/ddrcap2_flash_$(date +%Y%m%d_%H%M%S).log
  +BB=$ROOT/boot_known_good/BOOT.BIN.148.$TAG.$EXP
  +DRY=${DRY:-0}; LOG=$D/skidfix/txfix_flash_$(date +%Y%m%d_%H%M%S).log
  ```
  Everything else verbatim: SS_MINE ownership, `poll_md5_nonempty` (360 s), two-pass gate
  (fps ≥ 1120), Tier-2 witness, rollback, no-retry, all DRY guards, all `FLASH_DDRCAP2_*`
  message text (kept as-is per the plan's "everything else verbatim" instruction — these
  strings are stale for a txfix flash but were not on the list of lines to change).
- `two_jup/skidfix/txfix_flash_go.sh` — 2-line exec wrapper; env (`FLASH_MD5`/`FLASH_BAK`/
  `FLASH_TAG`/`DRY`) comes from `launch_rig_unit.sh`'s `--setenv`.
- `two_jup/verify_in_place_txfix.sh` — copy of `verify_in_place_148.sh` with
  `EXP=${FLASH_MD5:?}`, `BAK=${FLASH_BAK:-638b36de3493}`, log renamed `txfix_verify_*.log`.
  **Not exercised in this task**: the parent script has no `DRY` guard at all (it always
  ssh's, same as `flash_148_ddrcap2.sh`'s own comment notes about scripts lacking DRY
  support) — under the "no board contact" rail I created and diffed the file but never ran
  it. Flagged under Concerns below.
- `two_jup/beat_timeline.sh` + `two_jup/beat_timeline_go.sh` — timeline-only observer
  (no arm, no capture, no `0x10C` write): reads `0x20C` once before/after, `SECS` (default
  420) × (`sleep 1`; one bounded (`timeout 30`) `0x108` read), aborts `TIMELINE_ABORT` after
  3 consecutive read failures. Writes `errps.csv` as `t,packets,errs` (packets column unused
  filler=0, since only one register is read per poll; `errs` is the raw cumulative `0x108`
  value — `beat_detect.py`'s `detect_seconds()` diffs consecutive rows' 3rd column itself) and
  `meta.txt` (pre/post capTAP, start/end epoch, gaps>2s count). Prints
  `TIMELINE_OK secs=<n> gaps=<g> pre=<c> post=<c>` then `beat_detect.py --per-second`'s
  `BURSTS n=` line. DRY=1 fabricates a quiet 100/s stream with three synthetic 60,000/s
  bursts of 3 s each, 120 s apart (windows at t=100,220,340) — no sleeps, no ssh.
- `two_jup/txfix_witness_go.sh` — `VAR` env. Real path: `ddrcap2_capture.sh 6 <VAR>` (512 MB)
  → `sel6_stall_geometry.py` → `ddrcap2_pc.py --sel 6`, prints
  `WITNESS_<VAR> stalls=<n> tier2=<PASS|FAIL> credited=<yes|no>`. DRY=1 never calls
  `ddrcap2_capture.sh` (it has no DRY guard of its own) — instead it scores two local
  controls and prints one `WITNESS_<VAR>` line each: the existing
  `two_jup/beatcap/20260902_185552_sel6/mid.bin` (positive control, credited parsed from its
  adjacent `meta.txt`) and a freshly generated synthetic all-quiet 1,048,576-record capture
  (fixed constant hard-decision symbol, periodic demod-mark frame boundaries every 12,320
  records — negative control, `credited=yes` by construction).
- `two_jup/arm148_mode1.sh` — one-line change: `GOLD=BCF94856` → `GOLD=${GOLD:-BCF94856}`.
  Nothing else touched (diffed against HEAD to confirm).
- `two_jup/tests/test_txfix_rig_scripts.py` — 8 pytest tests, all DRY=1, all wrapped with a
  PATH shim replacing `ssh`/`scp` with a logger that exits 1 (asserts the log stays empty —
  proof of zero network contact independent of the script's own `[dry]` prints); asserts
  SENTINEL_STOP mtime is unchanged before/after every subprocess call.

## FINDING — stale figure in the plan text

The plan text says the local positive-control capture
(`two_jup/beatcap/20260902_185552_sel6/mid.bin`) "must report stalls=4". Running the
CURRENT `sel6_stall_geometry.py` against that file (verified twice, once standalone and
once through `txfix_witness_go.sh`) gives **stalls=6**, `n_frames=5446`, `tier2=PASS`. The
pre-existing `mid_stalls.json` sitting next to the .bin (generated earlier, presumably by an
older version of the geometry scorer or a different run) also shows 6, not 4. Tests and the
witness script assert the measured value (6), not the plan's figure. This is a discrepancy
in the plan/prior record, not a bug in the scoring path — flagging per the "never report a
metric without checking measurement code" rail rather than silently matching the plan's
stale number.

## DRY test outputs (evidence)

```
$ python3 -m pytest two_jup/tests/test_txfix_rig_scripts.py -v
test_flash_chain_dry_stage_lines_and_ok PASSED
test_flash_chain_requires_flash_md5_and_flash_tag PASSED
test_flash_bak_default_is_638b PASSED
test_beat_timeline_dry_ok_and_three_bursts PASSED
test_beat_timeline_csv_is_beat_detect_compatible PASSED
test_witness_dry_positive_and_negative_controls PASSED
test_arm148_mode1_gold_is_env_input PASSED
test_sentinel_present PASSED
======================== 8 passed in 16.98s ========================
```

Manual flash-chain DRY run (`FLASH_MD5=<md5 of a throwaway local file>`,
`FLASH_TAG=txfixTEST`):
```
=== [1/5] preconditions ===
[dry] would touch/remove SENTINEL_STOP (DRY never touches it, present or absent, owned or not)
  148 current image: [dry] md5sum ... (expect 638b36de3493)
=== [2/5] stage + flash ===
[dry] scp .../BOOT.BIN.148.txfixTEST.b171809b9f48 root@10.0.0.148:/root/BOOT.BIN.staged
=== [3/5] readback verify ===
  booted image: [dry] ... (expect b171809b9f48)
=== [4/5] two-pass gate ===
[dry] ARM_OK fps=1246   (x2)  GATE_PASS x2
=== [5/5] Tier-2 witness ===
[dry] iio_readdev ...
FLASH_DDRCAP2_OK b171809b9f48 (sentinel untouched -- external hold or DRY)
```
SENTINEL_STOP mtime before and after: `1788385054` (unchanged).

`beat_timeline.sh` (DRY, SECS=420): `TIMELINE_OK secs=420 gaps=0 pre=0xBCF94856
post=0xBCF94856` then `BURSTS n=3 rows=420`.

`txfix_witness_go.sh` (DRY, VAR=testF3):
```
WITNESS_testF3 stalls=6 tier2=PASS credited=yes
WITNESS_testF3 stalls=0 tier2=FAIL credited=yes
```
(tier2=FAIL on the synthetic quiet control is expected — it is not real modulated IQ; the
DRY path only proves the stall-run counter's zero/nonzero discrimination, not Tier-2 on
synthetic data.)

## Exact launch lines the silicon lane (T3) will use

Baseline timeline (positive control, before any flash — T3a):
```
launch_rig_unit.sh txfix-tl-baseline-<ts> two_jup/beat_timeline_go.sh SECS=420
```

Flash F3 (T3b, per image; `<md5>`/`<tag>` from the banked build):
```
launch_rig_unit.sh txfix-flash-F3-<ts> two_jup/skidfix/txfix_flash_go.sh \
  FLASH_MD5=<md5-12> FLASH_BAK=638b36de3493 FLASH_TAG=txfixF3
```

Post-flash timeline:
```
launch_rig_unit.sh txfix-tl-F3-<ts> two_jup/beat_timeline_go.sh SECS=420
```

Witness:
```
launch_rig_unit.sh txfix-wit-F3-<ts> two_jup/txfix_witness_go.sh VAR=F3
```

(Same pattern for F1/F2 with `FLASH_TAG=txfixF1`/`txfixF2` and `VAR=F1`/`F2`.)

## Concerns for the operator / next lanes

1. `verify_in_place_txfix.sh` has no DRY mode (matches its parent `verify_in_place_148.sh`
   exactly, which the plan required) — it was never executed in this task and cannot be
   DRY-tested under the current no-board-contact rail. It is code-reviewed by diff only.
   If the silicon lane wants to use it, that first real invocation IS a board action and
   should be treated as such (full rails, not a "dry check").
2. The plan's "mid.bin must report stalls=4" is stale; the real, current, measured value is
   6 (see FINDING above). If any other planning artifact was built assuming 4, it should be
   corrected.
3. `flash_148_txfix.sh` deliberately keeps every `FLASH_DDRCAP2_*` message string and doc
   comment referencing "ddrcap2" and the old rollback figure (1cd0cd752aa6) verbatim, per the
   plan's explicit "every other line verbatim" instruction — these strings/comments are
   stale for a txfix flash (wrong success/rollback message prefix, wrong image name in the
   header comment) but intentionally left untouched since the plan enumerated only 3 lines
   (4 assignments) to change. Flagging in case the operator wants a follow-up cosmetic fix.
