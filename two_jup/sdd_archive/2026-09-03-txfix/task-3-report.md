# Task 3 (T0b) report — build kit + build script

## Status
Complete. All four deliverables written, tested, and present in git HEAD:
`jupiter_byte_txfix_kit.sh` (root, kit-maker), `jupiter_byte_txfix_fetch.sh`
(root, fetch/bank), `two_jup/skidfix/txfix_build.sh.tmpl` +
`two_jup/skidfix/txfix_build.tcl.tmpl` (generic build scripts installed into
each kit), `two_jup/skidfix/txfix_kit_readme.md.tmpl` (per-kit README,
variant-substituted). The F3 kit (`jupiter_byte_txfixF3_build/`) is built,
injected, independently verified, and `build_txfix.sh --dry` runs clean.
`jupiter_byte_txfix_fetch.sh` was written but not run (no build exists yet,
per instructions). No board contact at any point (10.0.0.148/146 never
touched); hdl-dev-2 touched read-only except for the kit sync itself
(rsync of the F3 kit tree, which is the intended, non-destructive action of
`build_txfix.sh`/`--dry`).

## Concurrency note
This repo is shared, unisolated working-tree state across the parallel
lane agents (T0a/T0b/T0c/T4 all committing to the same checkout). My staged
`jupiter_byte_txfix_kit.sh` fix (see below) was swept into two other lanes'
commits (`4fa993c`, `dfa16d3`) before my own `git commit -s` could land —
each of my own commit attempts found "nothing to commit" because the file
was already committed with identical content. Verified byte-for-byte
(`git diff HEAD -- <file>` empty) for all five files I own before writing
this report; no content was lost or overwritten.

## Commit hashes touching my files
- `4fa993c` — "txfix: txfix_lint.sh -- lenient 5-top + strict -Wall gate for
  the variant trees" (Task 2's commit; incidentally carries the first
  versions of `jupiter_byte_txfix_kit.sh`, `jupiter_byte_txfix_fetch.sh`,
  and the three `.tmpl` files, which I had already written in the working
  tree at that point).
- `dfa16d3` — "txfix: sim_txfix_force.cpp harness + TREE/OBJ/HARNESS params
  on the build scripts" (Task 2's commit; carries my composite-tree bugfix
  to `jupiter_byte_txfix_kit.sh`, made after I discovered the injector
  needs the whole `hdl_prj_jupiter_composite` tree, not just
  `ipcore/TxRxCompo_ip_v1_0`, because the two `TxRxCompo_ip_v1_0.zip`
  members live at different paths under the composite tree).

I made no independent commit of my own — every attempt raced a concurrent
commit that had already captured the identical staged content.

## Dry-run output (`build_txfix.sh --dry` on the F3 kit)
```
TXFIX_BUILD preflight start 2026-09-03T10:05:26-04:00 kit=jupiter_byte_txfixF3_build variant=F3 jobs=6
TXFIX_BUILD preflight disk free=66GB
TXFIX_BUILD sync start 2026-09-03T10:05:26-04:00
TXFIX_BUILD sync done 2026-09-03T10:05:40-04:00
TXFIX_BUILD_DRY unit=txfix-build-txfixF3_build-1788444340 remote_dir=/home/tcollins/qpsk-builds/jupiter_byte_txfixF3_build jobs=6 variant=F3
TXFIX_BUILD_DRY would run: ssh hdl-dev-2 "REMOTE_DIR='/home/tcollins/qpsk-builds/jupiter_byte_txfixF3_build' UNIT='txfix-build-txfixF3_build-1788444340' JOBS='6' VARIANT='F3' bash -s" <<'REMOTE' ... REMOTE (systemd-run --user --unit=txfix-build-txfixF3_build-1788444340 ... timeout 14400 vivado -mode batch -notrace -source $REMOTE_DIR/build_txfix.tcl > $REMOTE_DIR/build_txfix_vivado.log 2>&1)
TXFIX_BUILD_DRY log would be at: /home/tcollins/qpsk-builds/jupiter_byte_txfixF3_build/build_txfix_vivado.log
```
(`--dry` still performs the rsync preflight/sync per the plan's contract —
only the remote `systemd-run` launch is skipped. Confirmed on hdl-dev-2:
`build_txfix.sh`/`.tcl`/`TXFIX_VARIANT` present under
`~/qpsk-builds/jupiter_byte_txfixF3_build/`, 1.5 GB synced.)

## F3 kit build/verify output (`jupiter_byte_txfix_kit.sh F3`)
```
TXFIX_INJECT variant=F3 loose=12 missing=[] zips=2 zips_verified=2
TXFIX_KIT_VERIFY loose_v_hits=6 marker=TXFIX_F3
TXFIX_KIT_VERIFY zips=2 zips_with_marker=2
TXFIX_KIT_DONE variant=F3 kit=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_txfixF3_build injector_commit=07f3badcda89968936cfa27b90115f3bdcec8e67
```
Re-run against the same kit correctly refuses:
`TXFIX_KIT_REFUSE_ALREADY_TAGGED ... already has TXFIX_VARIANT: F3 07f3bad...`.

## hdl-dev-2 disk numbers
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       492G  400G   67G  86% /
```
Kits present: `jupiter_byte_ddrcap2_build` (1.9G), `jupiter_byte_ddrcap_build`,
`jupiter_byte_stagesig3_build`, `jupiter_byte_txint_build`,
`jupiter_byte_txmark_build`. After the F3 kit's dry-run sync:
`jupiter_byte_txfixF3_build` present, 1.5G. 66 GB free reported by the
preflight check (>= 25 GB gate passes).

## Design notes / bug caught before flight
The injector (`two_jup/skidfix/txfix_inject.py`) recurses over whatever
directory it's given. The plan's literal invocation
(`txfix_inject.py <kit>/hdl_prj_jupiter_composite <VARIANT>`) is required,
not the narrower `ipcore/TxRxCompo_ip_v1_0` subdir the first draft of
`jupiter_byte_txfix_kit.sh` used — the two `TxRxCompo_ip_v1_0.zip` members
live at different paths (`ipcore/TxRxCompo_ip_v1_0/TxRxCompo_ip_v1_0.zip`
and `vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip`), so pointing only at the
former would silently find one zip instead of two and fail the "zips=2"
gate. Confirmed fixed and working on the F3 kit (see build/verify output
above).

## Concerns
- Shared, unisolated working tree across parallel lane agents makes commit
  provenance noisy (see Concurrency note) — no data loss observed, but
  attribution in `git log` does not line up 1:1 with which agent authored
  which hunk.
- `jupiter_byte_txfix_kit.sh` and `jupiter_byte_txfix_fetch.sh` live at repo
  root, which `.gitignore`'s `/*` rule ignores by default; both required
  `git add -f`. Future edits to either file must remember this or they will
  silently stay untracked.
- F1/F2 kits, and the real (non-`--dry`) build launch, are explicitly out of
  scope for this task (F1/F2 kits "when asked later"; real launch is Task 6,
  gated on F3's sim lint going green) — not done here, by design.
- `jupiter_byte_txfix_fetch.sh` is untested end-to-end (no finished build to
  fetch yet); its `scp`/banking/README-append logic should get a dry pass
  against a real `TXFIX_BUILD_DONE` remote log before Task 6/T3 relies on it.
