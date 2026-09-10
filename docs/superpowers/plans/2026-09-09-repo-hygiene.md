# Repo Hygiene (cleanup sub-project 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the campaign workspace into a product tree: seven top-level directories, under 700 tracked files, one Sphinx doc set, a truthful README, with everything dropped recoverable from an archive tag.

**Architecture:** Tag first, then rename and prune directory by directory, each as its own commit with a verification command that proves nothing load-bearing broke. Path references are found by grep, never by memory. Rig behaviour is proven unchanged at the end with a dry deploy, a live bring-up, and the health gate.

**Tech Stack:** git, bash, GNU coreutils, python3 (3.12), MATLAB R2025b (`tests/runTests.m`), Sphinx 9.1.0 + myst-parser 5.1.0 + adi-doctools 0.4.41 in a venv, gcc + ncurses for `host/`.

**Spec:** `docs/superpowers/specs/2026-09-09-repo-and-design-cleanup-design.md` (sub-project 1 section). Read it first.

## Global Constraints

- Branch: `per-under-1pct-2026-07`. Every commit is `git commit -s`, then `git push origin per-under-1pct-2026-07`.
- The pre-commit size guard (`tools/precommit_size_guard.sh`) blocks >200 files. Moves and mass deletes are expected to trip it; use `ALLOW_BIG=1` and say why in the commit body. Never bypass it for an add of untracked files.
- Never `git add -A` or `git add <dir>` on an untracked directory. Stage with explicit paths or `git mv` / `git rm`.
- Do not touch the boards until Task 13. Never run a register poll faster than 1 s. Never edit a script a live rig unit is running.
- Old-path names to grep for after every move: `jupiter_240k5_byte`, `host_app_k5`, `two_jup`, `k5_240`, `boot_known_good`. The grep scope is always `git ls-files` output, not the working tree, because the working tree has 81 GB of build trees.
- Scratch files go under `/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/*/scratchpad/` or `/mnt/onetb/scratch/qpsk-build-trees/`, never in the repo.
- Rule for "is this file evidence or output": a file stays tracked only if a docs page, a cited ledger, a test, or an operator script reads it by path. Everything else is output and goes to the tag.
- Rule for "is this script operator kit": it is named in `docs/*.rst`, `README.md`, or called by a script that is. Everything else in `two_jup/` is campaign material.
- Tag name: `archive/pre-cleanup-2026-09-09`. Every deletion commit message ends with `Recoverable from tag archive/pre-cleanup-2026-09-09.`

---

## File map

| Action | Path |
|---|---|
| Create | `docs/evidence/README.md`, `docs/evidence/<26 ledgers + rxfix/comb ledgers>` |
| Create | `docs/glossary.rst`, `docs/bringup.rst`, `docs/provenance.rst`, `docs/testing.rst`, `docs/performance.rst` |
| Create | `modem/rtl_sim/evidence/` (moved gate logs) |
| Create | `host/modem_status/`, `host/tests/` |
| Create | `ops/README.md`, `ops/profiles/` |
| Create | `tools/check_paths.sh`, `tools/harvest_build_trees.sh` |
| Rename | `jupiter_240k5_byte/` → `modem/`, `host_app_k5/` → `host/`, `two_jup/` (kit only) → `ops/`, `k5_240/` → `contract/`, `boot_known_good/` → `images/` |
| Modify | `tests/helpers/modem_paths.m`, `tests/*.m` path strings, `host/Makefile`, `ops/*.sh` path constants, `docs/conf.py`, `docs/index.rst`, `docs/*.rst`, `README.md`, `.gitignore`, `.github/workflows/docs.yml` |
| Delete (to tag) | `docs/*.md`, `REPRODUCE.md`, `OVERNIGHT_LOG.md`, `2026-07-01-bidir-240k-k5-design.md`, `plans/`, `docs_session/`, `evm/`, `tick_repro/`, `tick_repro_r3/`, `jupiter_byte_ddrcap2_build/`, `jupiter_byte_txfix_kit.sh`, `jupiter_byte_txfix_fetch.sh`, campaign material in `two_jup/`, sweep dirs in `rtl_sim/`, `run_*.m` in `k5_240/`, 28 BOOT.BINs |

---

### Task 1: Baseline, archive tag, branch prune

**Files:**
- Create: `/mnt/onetb/scratch/qpsk-build-trees/baseline.txt` (outside repo)

**Interfaces:**
- Produces: tag `archive/pre-cleanup-2026-09-09` on both remotes; every later commit message cites it.

- [ ] **Step 1: Record the baseline**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
mkdir -p /mnt/onetb/scratch/qpsk-build-trees
{ echo "commit $(git rev-parse HEAD)"; echo "tracked $(git ls-files | wc -l)"; git ls-files | cut -d/ -f1 | sort | uniq -c | sort -rn; echo "git_dir $(du -sh .git | cut -f1)"; } > /mnt/onetb/scratch/qpsk-build-trees/baseline.txt
cat /mnt/onetb/scratch/qpsk-build-trees/baseline.txt | head -5
```
Expected: `tracked 2861` (2860 plus the spec commit; any number near that is fine).

- [ ] **Step 2: Confirm the working tree has no tracked modifications**

```bash
git status --short | grep -v '^??' ; echo "exit=$?"
```
Expected: only the spec amendment from the brainstorm session (`docs/superpowers/specs/...`) or nothing. If anything else is modified, stop and report.

- [ ] **Step 3: Commit the spec amendment if present**

```bash
git add docs/superpowers/specs/2026-09-09-repo-and-design-cleanup-design.md
git commit -s -m "docs: cleanup spec, defer modem/ split to sub-project 2, harvest build-tree scripts" || true
```

- [ ] **Step 4: Tag and push the tag to both remotes**

```bash
git tag -a archive/pre-cleanup-2026-09-09 -m "Full campaign workspace before the 2026-09 cleanup. Every path removed by the cleanup is recoverable from this tag: git checkout archive/pre-cleanup-2026-09-09 -- <path>"
git push origin archive/pre-cleanup-2026-09-09
git push upstream archive/pre-cleanup-2026-09-09
git ls-remote --tags origin | grep pre-cleanup
git ls-remote --tags upstream | grep pre-cleanup
```
Expected: both `ls-remote` lines print the tag. If `upstream` push is refused, report it and continue; origin is sufficient for recovery.

- [ ] **Step 5: Verify every worktree-agent branch is merged, then delete**

```bash
for b in $(git branch --list 'worktree-agent-*' | sed 's/^[*+ ]*//'); do
  if git merge-base --is-ancestor "$b" HEAD; then echo "merged $b"; else echo "NOT-MERGED $b"; fi
done
```
Expected: 10 lines, all `merged`. If any is `NOT-MERGED`, leave that branch alone and list it in the commit body of Task 2.

```bash
for w in $(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep '/.claude/worktrees/agent-'); do git worktree remove --force "$w"; done
git worktree prune
for b in $(git branch --list 'worktree-agent-*' | sed 's/^[*+ ]*//'); do git merge-base --is-ancestor "$b" HEAD && git branch -D "$b"; done
git branch --list 'worktree-agent-*' | wc -l
git worktree list
```
Expected: `0` agent branches; worktree list shows only the main tree and the named ones (`build-a2`, `build-b2`, `firpipe-imageB`, `txmux-g0base`, `txmux-localize`). Leave those; they are named work.

---

### Task 2: Harvest and delete the untracked build trees and root logs

**Files:**
- Create: `tools/harvest_build_trees.sh`
- Create (outside repo): `/mnt/onetb/scratch/qpsk-build-trees/harvest/*.tar.gz`, `/mnt/onetb/scratch/qpsk-build-trees/delete_list.txt`

**Interfaces:**
- Produces: `/mnt/onetb/scratch/qpsk-build-trees/jupiter_byte_rxfixpad_build/` (whole tree of the current 148 image) and the harvest tarballs. Sub-project 2 reads the harvest.

- [ ] **Step 1: Write the harvest script**

```bash
cat > tools/harvest_build_trees.sh <<'EOF'
#!/bin/bash
# harvest_build_trees.sh -- tar the hand-written scripts out of every untracked
# jupiter_byte_*_build / _gates tree before the tree is deleted.
#
# WHY: some scripts the shipped images were built with (build_txfix.sh,
# build_final.sh, rxfix_*.m) were generated INTO the build trees and never
# tracked. The archive tag cannot hold them. This keeps them, small, outside the
# repo, so sub-project 2 can trace the chain.
#
# Usage: tools/harvest_build_trees.sh <dest_dir>
set -eu
DEST=${1:?dest dir}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$DEST"
cd "$ROOT"
n=0
for t in jupiter_byte_*_build jupiter_byte_*_gates; do
  [ -d "$t" ] || continue
  find "$t" \( -path "*/hdl_prj*" -o -path "*/slprj" -o -path "*/ipcore" -o -path "*/.Xil" -o -path "*/vivado_prj*" -o -path "*/.runs" \) -prune -o \
       -type f \( -name "*.sh" -o -name "*.py" -o -name "*.tcl" -o -name "*.m" -o -name "*.xdc" -o -name "*.tmpl" -o -name "*.toml" -o -name "*.md" -o -name "*.txt" -o -name "*.log" -o -name "*.status" \) -size -4M -print0 \
    | tar --null -czf "$DEST/$t.tar.gz" -T -
  n=$((n+1))
  echo "harvested $t -> $DEST/$t.tar.gz ($(tar tzf "$DEST/$t.tar.gz" | wc -l) files)"
done
echo "HARVEST_DONE trees=$n"
EOF
chmod +x tools/harvest_build_trees.sh
```

- [ ] **Step 2: Run it and check one tarball for a known untracked-only script**

```bash
tools/harvest_build_trees.sh /mnt/onetb/scratch/qpsk-build-trees/harvest 2>&1 | tail -3
tar tzf /mnt/onetb/scratch/qpsk-build-trees/harvest/jupiter_byte_rxfixpad_build.tar.gz | grep -E "build_txfix.sh|build_final.sh"
```
Expected: `HARVEST_DONE trees=62`; the grep prints both script paths.

- [ ] **Step 3: Move the current 148 build tree out whole**

```bash
mv jupiter_byte_rxfixpad_build /mnt/onetb/scratch/qpsk-build-trees/
ls /mnt/onetb/scratch/qpsk-build-trees/jupiter_byte_rxfixpad_build | head -3
```
Expected: directory listing (e.g. `adc_forensic_overlay.m`).

- [ ] **Step 4: Write the delete list and report counts**

```bash
{ ls -d jupiter_byte_*_build jupiter_byte_*_gates 2>/dev/null | grep -v ddrcap2;
  git status --short --ignored | awk '$1=="!!"{print $2}' | grep -E '^[^/]+\.(log|jou|status|txt)$';
  ls -d .Xil .pytest_cache vivado.log vivado.jou 2>/dev/null; } > /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt
echo "entries $(wc -l < /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt)"
du -shc $(cat /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt) 2>/dev/null | tail -1
grep -c "" /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt
```
Expected: about 61 dirs plus ~150 files, ~80 GB. Every entry must be untracked: verify with the next step before deleting.

- [ ] **Step 5: Prove nothing on the list is tracked, then delete**

```bash
while read p; do git ls-files --error-unmatch "$p" >/dev/null 2>&1 && echo "TRACKED $p"; done < /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt; echo "check done"
```
Expected: only `check done`. `jupiter_byte_ddrcap2_build` is excluded from the list because it has two tracked files; it is handled in Task 3.

```bash
xargs -d '\n' rm -rf < /mnt/onetb/scratch/qpsk-build-trees/delete_list.txt
ls | wc -l
```
Expected: about 20 entries at the root.

- [ ] **Step 6: Commit the harvest tool**

```bash
git add tools/harvest_build_trees.sh
git commit -s -m "tools: harvest_build_trees.sh, keeps never-tracked build scripts before build trees are deleted

Ran against 62 trees; tarballs in /mnt/onetb/scratch/qpsk-build-trees/harvest/.
jupiter_byte_rxfixpad_build (current 148 image) moved whole to /mnt/onetb/scratch/qpsk-build-trees/."
git push origin per-under-1pct-2026-07
```

---

### Task 3: Root-level tracked clutter to the tag

**Files:**
- Delete: `REPRODUCE.md`, `OVERNIGHT_LOG.md`, `2026-07-01-bidir-240k-k5-design.md`, `plans/`, `docs_session/`, `evm/`, `tick_repro/`, `tick_repro_r3/`, `jupiter_byte_ddrcap2_build/`, `jupiter_byte_txfix_kit.sh`, `jupiter_byte_txfix_fetch.sh`
- Modify: `.gitignore` (remove the corresponding `!/...` lines)

**Interfaces:**
- Consumes: nothing.
- Produces: `REPRODUCE.md` content is needed by Task 11 (fold into `measurement-discipline.rst`). Read it before deleting: `git show HEAD:REPRODUCE.md` works after deletion too, so no copy is needed.

- [ ] **Step 1: Check which of these anything tracked references**

```bash
git ls-files | xargs grep -l -E "REPRODUCE\.md|OVERNIGHT_LOG|bidir-240k-k5-design|docs_session/|/plans/|tick_repro|jupiter_byte_txfix_kit|jupiter_byte_txfix_fetch|\bevm/" 2>/dev/null | grep -v "^docs/superpowers" | sort
```
Expected: a short list (README.md, maybe `docs/*.rst`, `two_jup/*.md`). For each hit that is NOT in `two_jup/` (which is deleted in Task 8) note the line; Tasks 11 and 12 fix README and docs. `jupiter_byte_txfix_kit.sh` and `jupiter_byte_txfix_fetch.sh` are the TXFIX kit builders; they are the seed of `modem/fixes/` in sub-project 2 and are on the tag. Record any `two_jup/skidfix` script that calls them (grep output) in the commit body.

- [ ] **Step 2: Delete**

```bash
git rm -q -r REPRODUCE.md OVERNIGHT_LOG.md 2026-07-01-bidir-240k-k5-design.md plans docs_session evm tick_repro tick_repro_r3 jupiter_byte_ddrcap2_build jupiter_byte_txfix_kit.sh jupiter_byte_txfix_fetch.sh
git status --short | grep -c '^D'
```
Expected: about 100 deletions.

- [ ] **Step 3: Trim `.gitignore` whitelist lines**

```bash
sed -i -E '/^!\/(2026-07-01-bidir-240k-k5-design\.md|docs_session\/|evm\/|plans\/|tick_repro\/|tick_repro_r3\/)$/d' .gitignore
grep -n "^!/" .gitignore
```
Expected: the remaining `!/` lines are `.gitignore .github README.md build_env_jupiter.sh docs host_app_k5 jupiter_240k5_byte k5_240 two_jup boot_known_good boot_known_good/** tests tools` plus the evidence re-includes. `.gitignore` is rewritten wholesale in Task 12; this step only stops the deleted paths from being silently re-addable.

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -s -m "root: retire campaign notes, plans, evm, tick_repro, the txfix kit wrappers

REPRODUCE.md folds into docs/measurement-discipline.rst (Task 11 of the hygiene plan).
jupiter_byte_txfix_kit.sh / _fetch.sh are the TXFIX kit seed for sub-project 2 (modem/fixes/).
Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 4: `jupiter_240k5_byte/` → `modem/`, prune rtl_sim output

**Files:**
- Rename: `jupiter_240k5_byte/` → `modem/`
- Create: `modem/rtl_sim/evidence/` (moved from `rtl_sim/beat_runs/*.log`, `rtl_sim/golden_taps/GEN.log`, `rtl_sim/txfix_gate_runs.txt`, `rtl_sim/beat_runs/THROUGHPUT.md`)
- Delete: `modem/rtl_sim/{s1_rtl_pdwit,tap_replay_study,e5fix_ab,e5fix_runs,e5fix_runs2,dmac_runs,dmac_runs_rtl,rxloop_runs,burst_runs}/`, `modem/rtl_sim/beat_runs/*_frames.txt`, `modem/rtl_sim/beat_runs/*.bin` (if tracked)
- Modify: `tests/helpers/modem_paths.m`, `tests/*.m`, `.gitignore`

**Interfaces:**
- Produces: `p.kit` in `modem_paths.m` now resolves to `<root>/modem`. Field name stays `kit` so `tests/*.m` keep working.

- [ ] **Step 1: Rename**

```bash
git mv jupiter_240k5_byte modem
git ls-files modem | wc -l
```
Expected: `883`.

- [ ] **Step 2: Find what reads each rtl_sim subdir before deleting it**

```bash
for d in s1_rtl_pdwit tap_replay_study e5fix_ab e5fix_runs e5fix_runs2 dmac_runs dmac_runs_rtl rxloop_runs burst_runs dmac_src seqbist_unit; do
  n=$(git ls-files | grep -v "^modem/rtl_sim/$d/" | xargs grep -l "rtl_sim/$d\b" 2>/dev/null | grep -v "^two_jup/\|^docs/superpowers" | wc -l)
  echo "$d readers=$n"
done
```
Expected: `dmac_src` and `seqbist_unit` may have readers (they are source, keep them). The run-output dirs should show `readers=0`. If a run dir shows a reader outside `two_jup/`, keep that dir and note it.

- [ ] **Step 3: Delete run-output dirs, move evidence**

```bash
cd modem/rtl_sim
git rm -q -r s1_rtl_pdwit tap_replay_study e5fix_ab e5fix_runs e5fix_runs2 dmac_runs dmac_runs_rtl rxloop_runs burst_runs
git rm -q beat_runs/*_frames.txt beat_runs/*.bin 2>/dev/null || true
mkdir -p evidence
git mv beat_runs/*.log evidence/ 2>/dev/null; git mv beat_runs/THROUGHPUT.md evidence/ 2>/dev/null; git mv golden_taps/GEN.log evidence/golden_taps_GEN.log; git mv txfix_gate_runs.txt evidence/
git ls-files beat_runs | wc -l; git ls-files evidence | wc -l
cd ../..
```
Expected: `beat_runs` near 0 tracked (any remaining are `ddrcap2_sel12_mag.txt`-type evidence; move them too), `evidence` about 25.

- [ ] **Step 4: Fix references to the moved evidence files**

```bash
git ls-files | xargs grep -n -E "beat_runs/(ddrcap2_[a-z0-9_]+\.log|txfix_gate_[A-Za-z0-9_]+\.log|THROUGHPUT\.md)|golden_taps/GEN\.log|rtl_sim/txfix_gate_runs\.txt" 2>/dev/null | grep -v "^two_jup/\|^docs/superpowers\|^\.gitignore"
```
For every hit, replace the old path with `rtl_sim/evidence/<name>` (and `evidence/golden_taps_GEN.log` for GEN.log). Scripts under `modem/rtl_sim/*.sh` that WRITE to `beat_runs/` are unchanged; only readers of the tracked evidence change.

- [ ] **Step 5: Update `modem_paths.m` and tests**

```bash
sed -i "s#'jupiter_240k5_byte'#'modem'#; s#p.kit       jupiter_240k5_byte/#p.kit       modem/#" tests/helpers/modem_paths.m
grep -rn "jupiter_240k5_byte" tests/ | cut -c1-120
```
For each remaining hit in `tests/*.m`, replace `jupiter_240k5_byte` with `modem`. Expected after: `grep -rn jupiter_240k5_byte tests/` prints nothing.

- [ ] **Step 6: Update `.gitignore` rtl_sim rules**

```bash
sed -i 's#jupiter_240k5_byte/#modem/#g; s#^!/jupiter_240k5_byte/#!/modem/#' .gitignore
sed -i -E '/^!\/modem\/rtl_sim\/(golden_taps\/GEN\.log|beat_runs\/[A-Za-z0-9_*]+\.log|txfix_gate_runs\.txt)$/d' .gitignore
printf '%s\n' '!/modem/rtl_sim/evidence/**' >> .gitignore
git check-ignore -v modem/rtl_sim/evidence/ddrcap2_gate.log; echo "exit=$?"
```
Expected: `exit=1` (not ignored). If `exit=0`, the negation is above an ignoring rule; move the `!/modem/rtl_sim/evidence/**` line to the end.

- [ ] **Step 7: Grep for stale kit references in tracked non-campaign files**

```bash
git ls-files | grep -v "^two_jup/\|^docs/superpowers\|^docs/.*\.md$\|^README.md\|^boot_known_good" | xargs grep -l "jupiter_240k5_byte" 2>/dev/null
```
Expected: only files inside `modem/` itself (self-references in build scripts and comments) and `docs/*.rst`. Fix `modem/*.sh` and `modem/*.m` hits with `sed -i 's#jupiter_240k5_byte#modem#g'` on each listed file, then re-run the grep; `docs/*.rst` is fixed in Task 11. Leave `modem/README_BYTE.md` prose alone.

- [ ] **Step 8: Run the L1 MATLAB suite**

```bash
cd tests && matlab -batch "r = runTests('L1'); disp(table(r)); assert(all([r.Passed]))" 2>&1 | tail -15; cd ..
```
Expected: all rows `Passed true`. If MATLAB is not on PATH here, run via `/mnt/onetb/MATLAB/R2025b/bin/matlab -batch ...`.

- [ ] **Step 9: Commit**

```bash
git add -u; git add modem/rtl_sim/evidence .gitignore tests
ALLOW_BIG=1 git commit -s -m "modem/: rename jupiter_240k5_byte, keep harness + gate evidence, drop sim sweep output

ALLOW_BIG: directory rename (883 paths) plus deletion of 9 rtl_sim run-output dirs.
Tracked gate evidence moved to modem/rtl_sim/evidence/. tests/helpers/modem_paths.m p.kit -> modem/.
Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 5: `host_app_k5/` → `host/`, split modem_status and tests

**Files:**
- Rename: `host_app_k5/` → `host/`
- Create: `host/modem_status/` (all `ms_*.c`, `ms_*.h`, `modem_status.c`, `modem_status.h`, `test_modem_status.c`), `host/tests/` (all `test_*.c`, `test_loopback.sh`, `test_tap_loopback.sh`, `cyclic_ring_sim.c`, `dma_class_test.c`)
- Delete: `host/zed/`, `host/OVERNIGHT_FINDINGS_SCRATCH.md`, `host/TXQ_DEPLOY.md` (fold one line into `docs/host-software.rst` in Task 11 if it says something the page lacks)
- Modify: `host/Makefile`, `tests/helpers/modem_paths.m`, `tests/TestHostAppC.m`, `tests/TestTapLoopbackHost.m`, `tests/TestTunLoopbackHost.m`, `.gitignore`, `ops/provision.sh` (Task 8 handles ops)

**Interfaces:**
- Produces: `make -C host all test` builds every binary and runs every C test. `p.host` = `<root>/host`.

- [ ] **Step 1: Rename and check what `zed/` and `xvc_server.c` are for**

```bash
git mv host_app_k5 host
git ls-files host/zed | head; git ls-files | xargs grep -l "xvc_server\|host_app_k5/zed" 2>/dev/null | grep -v "^two_jup/\|^host/"
```
Expected: `zed/` is the ZedBoard-era port; if no reader outside `two_jup/` and `host/`, delete it. `xvc_server.c` is referenced by `host/XVC_README.md`; keep both (XVC is the JTAG-over-network path the ILA work used). Delete `zed/` only if the grep is empty.

- [ ] **Step 2: Move sources into subdirs**

```bash
cd host
mkdir -p modem_status tests
git mv modem_status.c modem_status.h ms_*.c ms_*.h test_modem_status.c modem_status/
git mv test_frame.c test_ber.c test_whiten.c test_seq.c test_txq.c test_txlog.c test_rxresync.c test_k5.c test_qsim.c test_loopback.sh test_tap_loopback.sh cyclic_ring_sim.c dma_class_test.c tests/
git rm -q -r zed OVERNIGHT_FINDINGS_SCRATCH.md 2>/dev/null || true
rm -f *.o modem_status test_modem_status test_rxresync qpsk_tun qpsk_perf qpsk_ringwrite ref_dump seq_dump test_frame test_ber test_k5 test_seq test_whiten test_txq test_txlog test_qsim
ls
cd ..
```
Expected: `host/` shows sources, `Makefile`, `modem_status/`, `tests/`, `qpsk_hw.h`, `XVC_README.md`, `xvc_server.c`, `qpsk_net_setup.sh`, `TXQ_DEPLOY.md`.

- [ ] **Step 3: Update the Makefile paths**

Open `host/Makefile`. For every rule that names a moved file, prefix the directory: `ms_%.c` → `modem_status/ms_%.c`, `modem_status.c` → `modem_status/modem_status.c`, `test_%.c` → `tests/test_%.c`, `test_modem_status.c` → `modem_status/test_modem_status.c`. Object files for `ms_*` go to `modem_status/*.o`. Add `-I.` to CFLAGS if not present so `#include "qpsk_hw.h"` from subdirs resolves. Add `-Imodem_status` for `test_modem_status`. Update the `clean` target to remove `modem_status/*.o tests/*.o` and the binaries in their new places. Keep the output binary names and locations (`host/qpsk_tun`, `host/modem_status/modem_status`) because `ops/provision.sh` copies them; if the Makefile put `modem_status` at `host/modem_status` (the directory name now), change the binary output to `host/modem_status/modem_status` and note it for Task 8.

- [ ] **Step 4: Build and run the C tests**

```bash
make -C host clean all test 2>&1 | tail -20
```
Expected: every `test_*` prints its PASS line and `make` exits 0. `ms_safety_check` target must still pass (it greps the modem_status sources for a write to the register window; update its path to `modem_status/`).

- [ ] **Step 5: Update MATLAB test paths**

```bash
sed -i "s#'host_app_k5'#'host'#; s#p.host      host_app_k5/#p.host      host/#" tests/helpers/modem_paths.m
grep -rn "host_app_k5\|test_loopback.sh\|test_tap_loopback.sh" tests/*.m | cut -c1-140
```
For each hit replace `host_app_k5` with `host` and, where a test invokes `test_loopback.sh` or `test_tap_loopback.sh` via `p.host`, point it at `fullfile(p.host,'tests',...)`. Then:

```bash
cd tests && matlab -batch "r = runTests('L1'); assert(all([r.Passed])); disp('L1 PASS')" 2>&1 | tail -3; cd ..
```
Expected: `L1 PASS`.

- [ ] **Step 6: `.gitignore` host binaries**

```bash
sed -i -E '/^host_app_k5\//d' .gitignore
sed -i 's#^!/host_app_k5/#!/host/#' .gitignore
cat >> .gitignore <<'EOF'
host/qpsk_tun
host/qpsk_capture
host/qpsk_ringwrite
host/qpsk_perf
host/ref_dump
host/seq_dump
host/xvc_server
host/modem_status/modem_status
host/modem_status/test_modem_status
host/tests/test_*
!host/tests/test_*.c
!host/tests/test_*.sh
*.o
EOF
git status --short host | grep '^??' ; echo "untracked-in-host exit=$?"
```
Expected: `exit=1` (nothing untracked shows after a build).

- [ ] **Step 7: Commit**

```bash
git add -u; git add host .gitignore tests
ALLOW_BIG=1 git commit -s -m "host/: rename host_app_k5, split modem_status/ and tests/, Makefile paths

ALLOW_BIG: directory rename. make -C host all test passes; tests/runTests L1 passes.
Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 6: `k5_240/` → `contract/`, drop sweep scripts

**Files:**
- Rename: `k5_240/` → `contract/`
- Delete: `contract/run_*.m`, `contract/build_both_v3.*`, `contract/arm_zed.sh`, `contract/tel_*.py`, `contract/t87_*.py`, `contract/gen_hdlD2.py`, `contract/probe.py`, `contract/score_splice.py`, `contract/soak_*.m`, `contract/soak_results_k5.csv`, `contract/__pycache__`, `contract/hunt_verdict_k5.m`, `contract/hybrid_ladder_k5.m`, `contract/tick_localize_k5.m`, `contract/PREFLIGHT.txt`, `contract/RXROOT.txt`, `contract/build_both_v3.out`
- Modify: `tests/helpers/modem_paths.m`, `tests/*.m`, `host/Makefile` comment, `.gitignore`

**Interfaces:**
- Produces: `p.k5` = `<root>/contract`. Field name unchanged.

- [ ] **Step 1: Rename and list what tests and docs read**

```bash
git mv k5_240 contract
git ls-files | grep -v "^two_jup/\|^docs/superpowers\|^contract/" | xargs grep -oh "k5_240/[A-Za-z0-9_.]*" 2>/dev/null | sort | uniq -c | sort -rn
```
Expected: `PACKET_K5.txt`, `golden_k5.mat`, `decode_ref_k5.m`, `seq_frame_bytes_k5.m`, `selftest_decode_k5.m`, `awgn_k5.m`, `packet_k5.m`, `PACKET_F1536.txt`, `golden_f1536.mat`, `f1536_ref_bits.m`, `float_baseline_f1536.m`, `gates_float_baseline_f1536.m`, `test_f1536_ref_bits.m`. Anything read by a test or doc stays. Also keep `decode_con_k5.m`, `decode_seq_k5.m`, `seq_crc32_k5.m`, `packet_f1536.m`, `synth_f1536_waveform.m`, `float_tap_window.m`, `pd_harness_k5.m`, `dump_ref.m`, `ref_paysym.txt`, `ref_presym.txt`, `rom_words_*.txt`, `arm_jupiter.sh`, `bist_read.sh` (used by `ops/test.sh bist`).

- [ ] **Step 2: Delete the sweep scripts**

```bash
cd contract
git rm -q run_*.m soak_*.m soak_results_k5.csv hunt_verdict_k5.m hybrid_ladder_k5.m tick_localize_k5.m tel_*.py t87_*.py gen_hdlD2.py probe.py score_splice.py build_both_v3.sh build_both_v3.out arm_zed.sh PREFLIGHT.txt RXROOT.txt 2>&1 | grep -v "did not match" ; rm -rf __pycache__
git ls-files . | wc -l
cd ..
```
Expected: about 30 tracked files remain.

- [ ] **Step 3: Update references**

```bash
sed -i "s#'k5_240'#'contract'#; s#p.k5        k5_240/#p.k5        contract/#" tests/helpers/modem_paths.m
sed -i 's#k5_240/#contract/#g' host/Makefile
grep -rn "k5_240" tests/*.m modem/*.sh modem/*.m contract/*.m contract/*.sh 2>/dev/null | cut -c1-120
```
Replace every hit's `k5_240` with `contract` (in `modem/` scripts that load `golden_k5.mat` by relative path, and in `contract/*.m` self-references). Re-run the grep: expected empty.

- [ ] **Step 4: Verify**

```bash
cd tests && matlab -batch "r = runTests('L1'); assert(all([r.Passed])); disp('L1 PASS')" 2>&1 | tail -3; cd ..
sed -i 's#^!/k5_240/#!/contract/#; s#!/k5_240/golden_k5.mat#!/contract/golden_k5.mat#' .gitignore
git check-ignore -v contract/golden_k5.mat; echo "exit=$?"
```
Expected: `L1 PASS`; `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add -u; git add contract .gitignore tests host/Makefile
git commit -s -m "contract/: rename k5_240, keep the bit contract + float reference, drop the run_* sweeps

Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 7: `boot_known_good/` → `images/`, prune to current + rollback

**Files:**
- Rename: `boot_known_good/` → `images/`
- Keep: `BOOT.BIN.148.rxfixpad.bf2a7305bbe0`, `BOOT.BIN.148.rxfixbs.dec007ae70dd` (148 on-board rollback), `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db`, `BOOT.BIN.146.w1x148.2728dab3979a` (146 on-board rollback), `Image.6.12.77-uio.a1ba00b51431.gz`, `SHA256SUMS.Image`, `system-qpsk.148.dtb.*`, `system-qpsk.146.dtb.*`, `system.dtb.pristine.*`, `daemon/`, `CURRENT.txt`, `MD5SUMS`, `README.md`
- Delete: every other `BOOT.BIN.*` (28 files) and the raw `Image.6.12.77-uio.a1ba00b51431`
- Modify: `images/CURRENT.txt`, `images/README.md`, `images/MD5SUMS`, `.gitignore`

**Interfaces:**
- Produces: `images/CURRENT.txt` unchanged in format (`ROLE FILE MD5 NOTE`); `ops/deploy_image.sh` reads it via `$ROOT/images` after Task 8.

- [ ] **Step 1: Rename, confirm the four keepers exist and match MD5SUMS**

```bash
git mv boot_known_good images
cd images
for f in BOOT.BIN.148.rxfixpad.bf2a7305bbe0 BOOT.BIN.148.rxfixbs.dec007ae70dd BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db BOOT.BIN.146.w1x148.2728dab3979a; do
  have=$(md5sum "$f" | cut -c1-12); want=$(echo "$f" | sed 's/.*\.//'); [ "$have" = "$want" ] && echo "ok $f" || echo "MD5-MISMATCH $f have=$have"
done
git ls-files daemon | head -3
cd ..
```
Expected: four `ok` lines. If `BOOT.BIN.148.rxfixbs.dec007ae70dd` is untracked (it is in the untracked list at session start), `git add -f images/BOOT.BIN.148.rxfixbs.dec007ae70dd` because it is the on-board rollback for 148.

- [ ] **Step 2: Delete the rest**

```bash
cd images
ls BOOT.BIN.* | grep -v -E "rxfixpad\.bf2a7305bbe0|rxfixbs\.dec007ae70dd|rxfixr4dr1\.9acbe2ebe1db|w1x148\.2728dab3979a" > /mnt/onetb/scratch/qpsk-build-trees/images_dropped.txt
wc -l < /mnt/onetb/scratch/qpsk-build-trees/images_dropped.txt
while read f; do git ls-files --error-unmatch "$f" >/dev/null 2>&1 && git rm -q "$f" || rm -f "$f"; done < /mnt/onetb/scratch/qpsk-build-trees/images_dropped.txt
rm -f Image.6.12.77-uio.a1ba00b51431
ls BOOT.BIN.* | wc -l
cd ..
```
Expected: about 30 dropped; `4` remain.

- [ ] **Step 3: Rewrite CURRENT.txt, MD5SUMS, README**

`images/CURRENT.txt` becomes exactly:

```
# role  file (relative to images/)  md5  note   -- read by ops/deploy_image.sh <ip> A|B
A BOOT.BIN.148.rxfixpad.bf2a7305bbe0 bf2a7305bbe0e0e38b3529d09edddaef W1+R4B+byte-seam census+PAD; on rig 148 since 2026-09-08 17:12; forward PER 0.070-0.079 % (WHITEN=1)
B BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db 9acbe2ebe1dbf280e030952fc4fc23d8 W1+R4D+R1; on rig 146 since 2026-09-05; reverse PER 0.191 % pooled (level-limited)
# On-board rollbacks (.bak on each board), also banked here:
#   148: BOOT.BIN.148.rxfixbs.dec007ae70dd   146: BOOT.BIN.146.w1x148.2728dab3979a
# SRO-sign caveat for a FRESH pair: A wants the receiver oscillator FASTER (negative sample-rate
# offset), B wants it SLOWER. Measure the RX-LO residual sign first (docs/bringup.rst).
# Kernel + dtbs: Image.6.12.77-uio.a1ba00b51431.gz, system-qpsk.{148,146}.dtb.*; deploy_kernel.sh /
# deploy_dtb.sh BEFORE deploy_image.sh on a fresh board. Older images: tag archive/pre-cleanup-2026-09-09.
```

Then regenerate MD5SUMS and cut README to the rows that remain:

```bash
cd images
md5sum BOOT.BIN.* Image.*.gz system*.dtb* > MD5SUMS
grep -n -E "^\| " README.md | grep -v -E "bf2a7305bbe0|dec007ae70dd|9acbe2ebe1db|2728dab3979a" | cut -d: -f1 > /tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/*/scratchpad/readme_drop_lines.txt 2>/dev/null || true
cd ..
```
Edit `images/README.md` by hand: keep the header paragraph, the table header, and the four image rows; add one line "Images removed on 2026-09-09 are on tag `archive/pre-cleanup-2026-09-09` under `boot_known_good/`." Keep the kernel/dtb section.

- [ ] **Step 4: `.gitignore`**

```bash
sed -i 's#boot_known_good#images#g' .gitignore
git check-ignore -v images/BOOT.BIN.148.rxfixpad.bf2a7305bbe0; echo "exit=$?"
git check-ignore -v images/Image.6.12.77-uio.a1ba00b51431; echo "raw-image-ignored exit=$?"
```
Expected: first `exit=1` (tracked image not ignored), second `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add -u; git add images .gitignore
git commit -s -m "images/: rename boot_known_good, keep current pair + on-board rollbacks + kernel/dtbs

28 superseded BOOT.BINs dropped. Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 8: `two_jup/` → `ops/` (operator kit), `docs/evidence/` (ledgers), rest to tag

**Files:**
- Create: `ops/`, `ops/profiles/`, `ops/README.md`, `ops/skidfix/` (staged whole for sub-project 2), `docs/evidence/`, `docs/evidence/README.md`, `tools/check_paths.sh`
- Delete: everything else under `two_jup/`
- Modify: `ops/*.sh` path constants, `tests/helpers/modem_paths.m`, `tests/hil/*.m`, `.gitignore`

**Interfaces:**
- Consumes: `images/CURRENT.txt` (Task 7), `host/` layout (Task 5).
- Produces: `ops/<script>` for every script the docs name; `docs/evidence/<LEDGER>.md`; `tools/check_paths.sh` exits non-zero if any tracked file outside `docs/evidence` and `docs/superpowers` names an old directory.

- [ ] **Step 1: Build the operator-kit list by closure**

```bash
cd two_jup
seed="anyssh.sh askpass.sh deploy_image.sh deploy_kernel.sh deploy_dtb.sh provision.sh health_probe_reset_aware.sh link_test.sh mux_test.sh rate_probe.sh test.sh bringup_r2r3.sh capture_r3.sh accept_analyze.py launch_rig_unit.sh sim_repro/no_arm_inflight.sh sim_repro/riglock.sh"
echo "$seed" | tr ' ' '\n' > /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt
for i in 1 2 3; do
  for f in $(cat /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt); do
    [ -f "$f" ] || continue
    grep -ohE '[A-Za-z0-9_./-]+\.(sh|py|m|tcl|json|txt)' "$f" | sed 's#^\./##; s#^\$[A-Z_]*/##' | while read r; do [ -f "$r" ] && echo "$r"; done
  done >> /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt
  sort -u -o /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt
done
wc -l < /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt; cat /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt
cd ..
```
Expected: 35 to 60 paths. Read the list. Remove anything that is clearly a campaign one-off pulled in by a comment (e.g. `deploy_pifix.sh`, `deploy_rxfix.sh`, `link_test_f1536.sh` if only mentioned in comments). Add `lvds_*.json` profiles, `chain.json`, `tasks.json`, `lock_watchdog.sh`, `frame_taxonomy.py`, `check_capture_health.py`, `recovery_windows.py`, `align_frames.py`, `arq_r3.sh`, `ber_loopback_gate.sh`, `measure_ber.sh`, `rf_loopback.sh`, `apply_146_ssi_fix.sh` if the closure found them (they are called at runtime). Also add every `flash_*.sh` in `skidfix/` that `images/CURRENT.txt` or PROVENANCE names as the flash rail (`flash_148_txfix.sh`, `txfix_flash146_go.sh` if present); those move with `skidfix/` anyway.

- [ ] **Step 2: Move the kit**

```bash
mkdir -p ops/profiles ops/sim_repro
for f in $(cat /mnt/onetb/scratch/qpsk-build-trees/ops_kit.txt); do
  case "$f" in
    lvds_*.json) git mv "two_jup/$f" ops/profiles/ ;;
    sim_repro/*) git mv "two_jup/$f" ops/sim_repro/ ;;
    *) git mv "two_jup/$f" ops/ ;;
  esac
done
git mv two_jup/skidfix ops/skidfix
git mv two_jup/tests ops/tests
git ls-files ops | wc -l
```
Expected: kit count + 99 (skidfix) + 30 (tests). `ops/skidfix/` is a staging exception: sub-project 2 turns it into `modem/fixes/` and `modem/instruments/`. `ops/tests/` holds the fake-anyssh fixtures the python tests use; check `git ls-files ops/tests` and drop any that no test imports.

- [ ] **Step 3: Move the ledgers to `docs/evidence/`**

```bash
mkdir -p docs/evidence/comb docs/evidence/rxfix
for f in BRINGUP_SEQUENCER DMAC_IDENTIFIED ERROR_TAXONOMY ESCALATION_ADI FIFO_ECHO_TEST FLOAT_FIXED_CAMPAIGN FLOAT_GAP_BUDGET FWD_SINGLES_ROOT_CAUSE HANDOFF_20260812 HANDOFF_20260813 HANDOFF_20260815 HARNESS_AB KNOWN_HOLES LAYERB_RUN_RESULT LOSS_LEDGER PAIR_RECURRENCE RIG_NOPING_FAULT RXFIX_STATE SINGLES_CAMPAIGN SINGLES_REPLAY SLX_RECONCILE TICK_FIX_SIM WEDGE_JUNK_CLASS WEDGE_ROOT_CAUSE; do git mv "two_jup/$f.md" docs/evidence/; done
git mv two_jup/comb/*.md docs/evidence/comb/
git mv ops/skidfix/SKID_BUILD.md docs/evidence/
for f in $(git ls-files two_jup/rxfix | grep '\.md$'); do git mv "$f" docs/evidence/rxfix/; done
git mv two_jup/W1_REGMAP.md docs/evidence/ 2>/dev/null || true
for f in two_jup/TXFIX_STATE.md two_jup/RXFIX_LEDGER.md; do [ -f "$f" ] && git mv "$f" docs/evidence/; done
git ls-files docs/evidence | wc -l
```
Expected: about 60. Then prepend a provenance line to each:

```bash
for f in $(git ls-files docs/evidence | grep '\.md$'); do
  old=$(echo "$f" | sed 's#^docs/evidence/#two_jup/#; s#^two_jup/SKID_BUILD.md#two_jup/skidfix/SKID_BUILD.md#')
  printf '> Evidence ledger, moved verbatim from `%s` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.\n\n' "$old" | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
head -2 docs/evidence/RXFIX_STATE.md
```

Write `docs/evidence/README.md`:

```markdown
# Evidence ledgers

These are the investigation ledgers the documentation cites. They are moved verbatim
from `two_jup/` and are not edited after the move; when a doc page and a ledger
disagree, the ledger wins (it carries the command, the sample count, and the run
directory). Paths inside a ledger refer to the tree at tag
`archive/pre-cleanup-2026-09-09`, where the run directories, capture data, and
one-off scripts they name still exist.

| Ledger | What it establishes |
|---|---|
| `RXFIX_STATE.md` | Forward comb root cause and the R4B/R4D/R1 ring fixes, PER credited both legs |
| `comb/*.md` | 2026-09 comb campaign: BS census, PAD, WHITEN, CRC regression 09-07, morning reports |
| `rxfix/*.md` | RXFIX sub-ledgers and the W1 register map (witness-word field order correction) |
| `ERROR_TAXONOMY.md` | Loss classes 1-4 with silicon signatures |
| `WEDGE_ROOT_CAUSE.md`, `WEDGE_JUNK_CLASS.md` | Acquisition wedge dissection |
| `LOSS_LEDGER.md`, `KNOWN_HOLES.md` | Running loss accounting and open holes |
| `FLOAT_FIXED_CAMPAIGN.md`, `FLOAT_GAP_BUDGET.md`, `TICK_FIX_SIM.md` | Float-vs-fixed parity and the BBDC tick |
| `SINGLES_*.md`, `FWD_SINGLES_ROOT_CAUSE.md`, `PAIR_RECURRENCE.md` | Forward singles/doubles campaign |
| `DMAC_IDENTIFIED.md`, `FIFO_ECHO_TEST.md`, `LAYERB_RUN_RESULT.md`, `HARNESS_AB.md` | Delivery-plane exoneration |
| `RIG_NOPING_FAULT.md`, `BRINGUP_SEQUENCER.md` | Rig operating hazards and the bring-up order |
| `HANDOFF_2026081[235].md`, `ESCALATION_ADI.md`, `SLX_RECONCILE.md`, `SKID_BUILD.md` | Handoffs, vendor escalation, model reconciliation, skid build |
```
Adjust rows to the files that actually moved (`git ls-files docs/evidence`).

- [ ] **Step 4: Delete the rest of `two_jup/`**

```bash
git ls-files two_jup | wc -l
git rm -q -r two_jup
rm -rf two_jup
ls two_jup 2>&1 | head -1
```
Expected: about 1400 deletions; `ls` reports no such directory.

- [ ] **Step 5: Fix path constants in the kit**

```bash
grep -n -E "boot_known_good|host_app_k5|jupiter_240k5_byte|k5_240|two_jup|skidfix/" $(git ls-files ops | grep -E '\.(sh|py)$') | grep -v "^ops/skidfix/" | cut -c1-160
```
For every hit: `boot_known_good` → `images`, `host_app_k5` → `host`, `jupiter_240k5_byte` → `modem`, `k5_240` → `contract`, `two_jup/X` → `ops/X`, `lvds_*.json` → `profiles/lvds_*.json`. Where a script computes `ROOT=$(dirname $0)/..`, that still works. `deploy_image.sh` line 38 becomes `BKG=$ROOT/images`. `provision.sh` copies `host/qpsk_tun` and the modem_status binary; point it at `host/modem_status/modem_status` if Task 5 moved the binary. `bringup_r2r3.sh` line 77 reads `/root/$PROF.json` on the board (unchanged) but the local copy source path changes to `ops/profiles/`. Leave `ops/skidfix/` untouched (sub-project 2 owns it), but do sed `two_jup/skidfix` → `ops/skidfix` inside it so flash rails still resolve their own dir.

- [ ] **Step 6: Write `tools/check_paths.sh` and run it**

```bash
cat > tools/check_paths.sh <<'EOF'
#!/bin/bash
# check_paths.sh -- fail if any tracked file outside the evidence/spec areas still
# names a pre-cleanup directory. Run from the repo root; used by hand and by CI.
set -u
cd "$(dirname "$0")/.."
hits=$(git ls-files | grep -v -E '^docs/evidence/|^docs/superpowers/|^ops/skidfix/|^tools/check_paths.sh$|^images/CURRENT.txt$|^images/README.md$' \
  | xargs grep -n -E '\b(jupiter_240k5_byte|host_app_k5|two_jup|k5_240|boot_known_good)\b' 2>/dev/null)
if [ -n "$hits" ]; then echo "$hits"; echo "CHECK_PATHS_FAIL $(echo "$hits" | wc -l) hits"; exit 1; fi
echo "CHECK_PATHS_OK"
EOF
chmod +x tools/check_paths.sh
tools/check_paths.sh | tail -5
```
Expected at this point: hits only in `docs/*.rst`, `docs/*.md`, `README.md`, `modem/README_BYTE.md`, `.gitignore`. Those are fixed in Tasks 11 and 12. Hits anywhere else must be fixed now.

- [ ] **Step 7: MATLAB paths and HIL tests**

```bash
sed -i "s#'two_jup'#'ops'#; s#p.two_jup   two_jup/#p.two_jup   ops/#" tests/helpers/modem_paths.m
grep -rn "two_jup" tests/ | cut -c1-140
```
Replace hits with `ops` (keep the struct field name `two_jup` to avoid touching every test; add a comment `% field name kept for history; points at ops/`). Then:

```bash
cd tests && matlab -batch "r = runTests('L1'); assert(all([r.Passed])); disp('L1 PASS')" 2>&1 | tail -3; cd ..
python3 -m pytest ops/tests -q 2>&1 | tail -3
```
Expected: `L1 PASS`; pytest passes or reports only tests that need the boards (skipped).

- [ ] **Step 8: `ops/README.md`**

```markdown
# ops/ — operator kit

Scripts that touch the rig. Each one is named by a docs page; nothing here is a
campaign one-off. Profiles the boards load are in `profiles/`. `skidfix/` is the
netlist fix-injection and flash-rail kit, staged here until cleanup sub-project 2
moves it under `modem/`.

| Script | Purpose | Doc |
|---|---|---|
| `deploy_kernel.sh`, `deploy_dtb.sh`, `deploy_image.sh` | Flash kernel, dtb, BOOT.BIN (size-checked, backed up) | setup-prebuilt |
| `provision.sh` | Host app, profiles, watchdog onto a board | setup-prebuilt |
| `bringup_r2r3.sh r3` | Profile, LO plan, ROM double-tap, daemons, watchdogs on both boards | bringup |
| `health_probe_reset_aware.sh <ip> <n>` | Two-pass health gate; healthy = fsync 1245 | bringup |
| `capture_r3.sh`, `accept_analyze.py` | Credited PER window, lost frames in the denominator | measurement-discipline |
| `launch_rig_unit.sh` | Run a rig script as a frozen copy under a systemd user unit | measurement-discipline |
| `test.sh loopback|bist`, `link_test.sh` | Tier A/B/C tests | testing |
| `sim_repro/riglock.sh`, `sim_repro/no_arm_inflight.sh` | Rig mutex and arm guard | bringup |
```
Fill in the remaining rows from `git ls-files ops | grep -v skidfix`.

- [ ] **Step 9: `.gitignore` and commit**

```bash
sed -i -E '/^two_jup\//d; /^!\/two_jup\//d' .gitignore
printf '%s\n' '!/ops/' '!/docs/evidence/**' 'ops/evmcap/' 'ops/*.log' >> .gitignore
git add -u; git add ops docs/evidence tools/check_paths.sh .gitignore tests
ALLOW_BIG=1 git commit -s -m "ops/ + docs/evidence/: operator kit out of two_jup, cited ledgers banked, campaign material retired

ALLOW_BIG: ~1400 deletions plus ~200 moves. ops/skidfix staged whole for sub-project 2.
tests/runTests L1 passes; tools/check_paths.sh remaining hits are docs (Tasks 11-12).
Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 9: Sphinx toolchain locally, baseline build

**Files:**
- Create (outside repo): `/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/`

**Interfaces:**
- Produces: `sphinx-build -W -b html docs docs/_build/html` runnable locally with the CI-pinned versions.

- [ ] **Step 1: Create the venv with the exact versions from `.github/workflows/docs.yml`**

```bash
python3 -m venv /mnt/onetb/scratch/qpsk-build-trees/sphinx-venv
/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/pip install -q "sphinx==9.1.0" "myst-parser==5.1.0" "adi-doctools==0.4.41"
which dot || echo "graphviz missing: sudo apt-get install -y graphviz"
```

- [ ] **Step 2: Build once before touching docs**

```bash
rm -rf docs/_build && /mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | tail -5
```
Expected: `build succeeded`. If it fails on a `two_jup/` link, that is expected after Task 8; note the failing references, they are the Task 11 worklist.

---

### Task 10: Fold `docs/*.md` into the Sphinx pages: structure

**Files:**
- Create: `docs/glossary.rst`, `docs/bringup.rst`, `docs/provenance.rst`, `docs/testing.rst`, `docs/performance.rst`
- Modify: `docs/index.rst` (toctree), `docs/conf.py` (drop the `.md` exclude list)

**Interfaces:**
- Produces: five new pages in the toctree, each with a one-paragraph lead and headings that Task 11 fills.

- [ ] **Step 1: Create the five pages with leads and headings**

`docs/glossary.rst`:
```rst
Glossary
========

Terms used across this documentation, in the sense this project uses them.
Source: the retired ``docs/GLOSSARY.md`` (tag ``archive/pre-cleanup-2026-09-09``).

.. glossary::
   :sorted:
```

`docs/bringup.rst`:
```rst
Bring-up and porting
====================

How to take a provisioned pair of boards from power-on to a credited link, and
what changes when the pair is not the lab pair (10.0.0.148 / 10.0.0.146).

Sequence
--------

SRO sign on a fresh pair
------------------------

Health gate
-----------

Porting to another pair
-----------------------
```

`docs/provenance.rst`:
```rst
Provenance
==========

Which image is on which board, what it carries, and the lineage that led there.
Identity is by BIST golden ``cap_out = 0x04922282`` and the gate stamps, not md5.

Current images
--------------

Lineage
-------

Gate evidence
-------------
```

`docs/testing.rst`:
```rst
Testing
=======

Tier A (self-loopback, no RF), Tier B (on-chip BIST), Tier C (over the air), and
the MATLAB unit suite ``tests/runTests.m`` (L1 host-pure, L2 gates, L3 hardware).

Tiers
-----

The MATLAB suite
----------------

Host C tests
------------
```

`docs/performance.rst`:
```rst
Link performance
================

Credited PER, throughput, latency, and the EVM budget on the deployed rung.

Packet error rate
-----------------

Throughput and latency
----------------------

EVM budget
----------
```

- [ ] **Step 2: Add to the toctree and drop the exclude list**

In `docs/index.rst`, find the `.. toctree::` and add `bringup`, `provenance`, `testing`, `performance`, `glossary` in that order after the existing entries. In `docs/conf.py`, replace the `exclude_patterns` list with:

```python
exclude_patterns = [
    "_build",
    "superpowers",  # campaign working plans/specs, not user documentation
    "evidence",     # verbatim ledgers, linked by path, not rendered
]
```

- [ ] **Step 3: Build**

```bash
/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | grep -E "warning|error|succeeded" | head
```
Expected: `build succeeded` or only warnings about empty sections (fix by adding one sentence under each heading, e.g. "Filled in below.").

- [ ] **Step 4: Commit**

```bash
git add docs/glossary.rst docs/bringup.rst docs/provenance.rst docs/testing.rst docs/performance.rst docs/index.rst docs/conf.py
git commit -s -m "docs: five new Sphinx pages (bringup, provenance, testing, performance, glossary), evidence excluded from render"
git push origin per-under-1pct-2026-07
```

---

### Task 11: Fold `docs/*.md` content, fix every `two_jup` reference, delete the `.md` set

**Files:**
- Modify: all `docs/*.rst`
- Delete: `docs/ARCHITECTURE.md docs/BRINGUP.md docs/BRINGUP_F1536_RESULTS.md docs/BUILD.md docs/DEBUGGING.md docs/DEPLOY_F1536.md docs/EVM_BUDGET.md docs/GLOSSARY.md docs/LINK_CHARACTERIZATION.md docs/PORTING.md docs/PROVENANCE.md docs/TESTING.md`, `host/TXQ_DEPLOY.md`, `modem/README_BYTE.md` (fold into `byte-plane.rst`), `modem/FIFO_DRIFT_FINDING.md`, `modem/FRAMESTAT_NOTES.md`, `modem/RX_STALL_MAP.md` (to `docs/evidence/`)

**Interfaces:**
- Consumes: the five pages from Task 10.
- Produces: a doc set where every path named exists in the tree, and `tools/check_paths.sh` has no `docs/` hits.

Fold rule, applied per `.md`: for every H2/H3 heading in the `.md`, either (a) the equivalent content is already in the target `.rst` (skip), (b) it is still true and missing (convert to rst under the mapped heading), or (c) it is stale (drop, and list the heading in the commit body with one reason). "Still true" means it agrees with `docs/evidence/RXFIX_STATE.md` Task 37 and `images/CURRENT.txt`. Numbers: forward PER 0.070–0.079 %, reverse 0.191 % pooled, both with lost frames in the denominator; rung r3 = 61.44 MSPS, 15.36 Msym/s, 4 sps; WHITEN=1 both ends; images per `images/CURRENT.txt`.

- [ ] **Step 1: Per-file fold** (do them in this order, building after each)

| `.md` | Target `.rst` | Notes |
|---|---|---|
| GLOSSARY | glossary | every term becomes a `.. glossary::` entry |
| ARCHITECTURE | system-overview | register map table goes to `byte-plane.rst` if not already there |
| BRINGUP, PORTING, DEPLOY_F1536, BRINGUP_F1536_RESULTS | bringup, setup-prebuilt | F1536 pages are the 1.92 MSPS legacy rung: one paragraph under "Porting" saying it exists on the tag, nothing more |
| BUILD | build-and-flash | the current honest statement: "the deployed images were built by the kit chain in `ops/skidfix/`; sub-project 2 replaces it with `modem/build_image.sh`". Name `build_lean_image.sh` only as the model-to-netlist step |
| PROVENANCE | provenance | current-image section from `images/CURRENT.txt`; lineage table copied as-is with `boot_known_good/` paths rewritten to "tag `archive/pre-cleanup-2026-09-09`" |
| DEBUGGING | debug-instruments | symptom → cause → action table; every action must name an `ops/` script that exists |
| TESTING | testing | |
| LINK_CHARACTERIZATION, EVM_BUDGET | performance | |
| README_BYTE (modem/) | byte-plane | |
| TXQ_DEPLOY (host/) | host-software | one paragraph on the TXQ env knobs if the page lacks them |
| REPRODUCE (from tag: `git show archive/pre-cleanup-2026-09-09:REPRODUCE.md`) | measurement-discipline | the credited-run recipe |

After each fold: `git rm docs/<FILE>.md` and build:

```bash
/mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | grep -E "warning|error|succeeded"
```
Expected each time: `build succeeded`.

- [ ] **Step 2: Rewrite every remaining old path in `docs/*.rst`**

```bash
grep -n -E "two_jup/|host_app_k5|jupiter_240k5_byte|k5_240|boot_known_good" docs/*.rst | cut -c1-140 | wc -l
```
For each hit apply: `two_jup/<LEDGER>.md` → `` `docs/evidence/<LEDGER>.md` ``; `two_jup/comb/X.md` → `docs/evidence/comb/X.md`; `two_jup/<script>` → `ops/<script>` if the script is in `ops/`, else the sentence is rewritten to say the script is on the tag; other dirs per the rename table. Then:

```bash
tools/check_paths.sh | grep -v "^README.md\|^\.gitignore\|^modem/README_BYTE" | tail -3
```
Expected: `CHECK_PATHS_OK` or only README/.gitignore hits.

- [ ] **Step 3: Move the three modem notes to evidence**

```bash
git mv modem/FIFO_DRIFT_FINDING.md modem/FRAMESTAT_NOTES.md modem/RX_STALL_MAP.md docs/evidence/
for f in FIFO_DRIFT_FINDING FRAMESTAT_NOTES RX_STALL_MAP; do printf '> Evidence note, moved verbatim from `jupiter_240k5_byte/%s.md` on 2026-09-09.\n\n' "$f" | cat - "docs/evidence/$f.md" > t && mv t "docs/evidence/$f.md"; done
```
Add three rows to `docs/evidence/README.md`.

- [ ] **Step 4: Final docs build and CI file**

```bash
sed -i 's#branches: \[master, per-under-1pct-2026-07\]#branches: [master, per-under-1pct-2026-07]#' .github/workflows/docs.yml
rm -rf docs/_build && /mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | tail -2
ls docs/_build/html/*.html | wc -l
```
Expected: `build succeeded`; about 18 html pages.

- [ ] **Step 5: Commit**

```bash
git add -u; git add docs
git commit -s -m "docs: single Sphinx set; markdown pages folded, stale claims corrected, ledgers linked at docs/evidence

Dropped headings (stale): <list them here, one per line, with the reason>.
Recoverable from tag archive/pre-cleanup-2026-09-09."
git push origin per-under-1pct-2026-07
```

---

### Task 12: README, `.gitignore` rewrite, precommit hook, CI path check

**Files:**
- Modify: `README.md` (rewrite), `.gitignore` (rewrite), `.github/workflows/docs.yml` (add a `paths` job running `tools/check_paths.sh`)
- Modify: `tools/precommit_size_guard.sh` header (install path unchanged)

**Interfaces:**
- Produces: `tools/check_paths.sh` runs in CI on every push.

- [ ] **Step 1: Rewrite `README.md`**

Structure, in this order, with the facts from `images/CURRENT.txt` and `docs/evidence/RXFIX_STATE.md` Task 37:

```markdown
# QPSK K5 Jupiter Modem

Bidirectional FDD link between two ADALM-Jupiter (ADRV9002) SDRs: π/4 QPSK at
15.36 Msym/s (61.44 MSPS, 4 sps), rate-1/2 K=5 convolutional code, an in-fabric
byte-DMA data plane, IP over `tun0`. Simulink/HDL Coder model to BOOT.BIN.

**Status (2026-09-09):** both legs under the 1 % PER target with lost frames in the
denominator. Forward 0.070–0.079 %, reverse 0.191 % pooled. Images per
`images/CURRENT.txt`. Docs: https://tfcollins.github.io/qpsk-jupiter-modem/

## Layout

| Dir | Role |
|---|---|
| `modem/` | Simulink model, overlays, HDL/sim gates, rtl_sim harness and gate evidence |
| `host/` | Linux host daemon (`qpsk_tun`), tools, `modem_status/` TUI, C tests |
| `ops/` | Operator kit: deploy, provision, bring-up, health gate, credited capture. `skidfix/` is the netlist fix kit (moving under `modem/` in the next cleanup step) |
| `contract/` | Bit and packet contract, golden vectors, float reference receiver |
| `images/` | Current BOOT.BIN pair, on-board rollbacks, kernel, device trees |
| `docs/` | Sphinx docs; `docs/evidence/` holds the investigation ledgers the pages cite |
| `tests/` | MATLAB unittest suite (L1 host-pure, L2 gates, L3 hardware-in-loop) |

## Quick start
(the four blocks from the old README: deploy, provision, bring up, test, with `ops/` and `images/` paths)

## Rules
- Never modify the read-only ADI donor tree `/home/tcollins/dev/qpsk_ai`.
- Flash one board at a time; the rollback `.bak` must exist on-board first.
- Any PER number carries the command, the sample count, and the statement that lost frames are in the denominator.

## History
Everything removed in the 2026-09 cleanup (campaign scripts, capture output, 28 superseded images, ~160 build trees' scripts) is on tag `archive/pre-cleanup-2026-09-09`; `git checkout archive/pre-cleanup-2026-09-09 -- <path>` restores any of it.
```

- [ ] **Step 2: Rewrite `.gitignore` as a short allowlist**

```gitignore
# Allowlist: seven top-level dirs plus root files. Everything else at the root is
# ignored (build trees, campaign logs). Derived artifacts inside kept dirs follow.
/*
!/.gitignore
!/.github/
!/README.md
!/build_env_jupiter.sh
!/contract/
!/docs/
!/host/
!/images/
!/modem/
!/ops/
!/tests/
!/tools/

# derived / output
*.iq
*.mat
!/contract/golden_k5.mat
!/contract/golden_f1536.mat
*.log
*.out
*.jou
*.pyc
*.vvp
*.vvpout
*.autosave
*.slxc
*.o
hdl_prj_*/
slprj/
obj_*/
.Xil/
ipcore/
s1_rtl/
__pycache__/
tests/results/
docs/_build/
docs/superpowers/*
!docs/superpowers/specs/
!docs/superpowers/plans/

# modem sim output (evidence is tracked under rtl_sim/evidence/)
modem/rtl_sim/*.txt
modem/rtl_sim/*.csv
modem/rtl_sim/*.bin
modem/rtl_sim/diag/
modem/rtl_sim/replay/
modem/rtl_sim/beat_runs/
modem/rtl_sim/golden_taps/*.bin
modem/rtl_sim/golden_taps/*.frames.txt
modem/rtl_sim/s1_rtl_txmark/
!modem/rtl_sim/evidence/**

# host binaries
host/qpsk_tun
host/qpsk_capture
host/qpsk_ringwrite
host/qpsk_perf
host/ref_dump
host/seq_dump
host/xvc_server
host/modem_status/modem_status
host/modem_status/test_modem_status
host/tests/test_*
!host/tests/test_*.c
!host/tests/test_*.sh

# ops output
ops/evmcap/
ops/*.dtb
ops/*.dtbo

# images: only the banked files are tracked; raw gunzip of the kernel is not
*BOOT.BIN
*BOOT.BIN.*
!/images/BOOT.BIN.*
/images/Image.6.12.77-uio.a1ba00b51431
```

Then prove nothing tracked became ignored and nothing wanted is untracked:

```bash
git ls-files -i -c --exclude-standard | head; echo "tracked-but-ignored above (expect none)"
git status --short | grep '^??' | head; echo "untracked above (expect none or build output only)"
```

- [ ] **Step 3: Install the hook and add the CI check**

```bash
ln -sf ../../tools/precommit_size_guard.sh .git/hooks/pre-commit
```
In `.github/workflows/docs.yml` add a job before `build`:

```yaml
  paths:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: tools/check_paths.sh
```
and remove the `paths:` filter under `on.push` so the workflow runs on every push to the two branches (`workflow_dispatch` stays).

- [ ] **Step 4: Full verification**

```bash
tools/check_paths.sh | tail -1
git ls-files | wc -l
make -C host clean all test 2>&1 | tail -3
cd tests && matlab -batch "r = runTests('L1'); assert(all([r.Passed])); disp('L1 PASS')" 2>&1 | tail -2; cd ..
rm -rf docs/_build && /mnt/onetb/scratch/qpsk-build-trees/sphinx-venv/bin/sphinx-build -W -b html docs docs/_build/html 2>&1 | tail -1
```
Expected: `CHECK_PATHS_OK`; tracked count under 700; make exits 0; `L1 PASS`; `build succeeded`. If the tracked count is above 700, list the largest remaining directories (`git ls-files | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head`) and report; `ops/skidfix` (99) is expected and allowed.

- [ ] **Step 5: Commit**

```bash
git add README.md .gitignore .github/workflows/docs.yml tools
git commit -s -m "README, .gitignore allowlist, CI path check; hygiene sub-project complete apart from rig verification"
git push origin per-under-1pct-2026-07
gh run list --branch per-under-1pct-2026-07 --limit 2
```
Expected: CI run triggered; both jobs green within a few minutes (check with `gh run watch` in the background, not a foreground poll).

---

### Task 13: Rig verification, unchanged behaviour

**Files:** none modified. Read-only against the rig plus one bring-up.

**Interfaces:**
- Consumes: `ops/deploy_image.sh`, `ops/bringup_r2r3.sh`, `ops/health_probe_reset_aware.sh`, `ops/launch_rig_unit.sh`.

Rules: resolve `10.0.0.148` and `10.0.0.146` against `~/.claude/HOSTS.md` before use. Poll at 1 s or slower. No flash in this task. If a sentinel or keeper unit is running, do not kill it; `systemctl --user list-units 'sentinel*' 'keeper*'` first and report.

- [ ] **Step 1: Dry deploy resolves the images**

```bash
DRY=1 ops/deploy_image.sh 10.0.0.148 A 2>&1 | tail -3
DRY=1 ops/deploy_image.sh 10.0.0.146 B 2>&1 | tail -3
```
Expected: each prints the image path under `images/` and its md5 matching `CURRENT.txt`, and stops before any scp. If `deploy_image.sh` has no `DRY` knob, read its header and use the flag it documents; if none, skip this step and say so.

- [ ] **Step 2: Confirm the boards already run the images CURRENT.txt names**

```bash
for ip in 10.0.0.148 10.0.0.146; do ops/anyssh.sh $ip "md5sum /boot/BOOT.BIN | cut -c1-12; ls /root/*.bak"; done
```
Expected: `bf2a7305bbe0` with `/root/BOOT.BIN.dec007ae70dd.bak`; `9acbe2ebe1db` with `/root/BOOT.BIN.2728dab3979a.bak`.

- [ ] **Step 3: Live bring-up under a frozen unit copy**

```bash
ops/launch_rig_unit.sh ops/bringup_r2r3.sh r3 2>&1 | tail -3
```
Then wait for the unit with a background monitor (not a foreground loop): `systemd-run --user` unit name from the launch output; check `systemctl --user is-active <unit>` every 30 s for up to 10 min.

- [ ] **Step 4: Health gate both legs**

```bash
ops/health_probe_reset_aware.sh 10.0.0.148 12 2>&1 | tail -4
ops/health_probe_reset_aware.sh 10.0.0.146 12 2>&1 | tail -4
```
Expected: `fsync≈1245 wcnt≈1245 clean=12/12` on each. This is the same gate the pre-cleanup README named; passing it proves the operator kit still drives the rig.

- [ ] **Step 5: Record and report**

Append to `docs/provenance.rst` under "Current images" one line: "2026-09-09: operator kit relocated to `ops/`; bring-up and health gate re-run on both boards, fsync/wcnt 1245, clean 12/12 (commands in the hygiene plan Task 13)." Commit:

```bash
git add docs/provenance.rst
git commit -s -m "docs: provenance note, ops/ kit verified against the rig after the cleanup"
git push origin per-under-1pct-2026-07
```

---

### Task 14: Memory and handoff

**Files:** `/home/tcollins/.claude/projects/-mnt-onetb-scratch-qpsk-jupiter-modem/memory/` (outside repo)

- [ ] **Step 1: Update memory notes that name old paths**

```bash
grep -l -E "two_jup|host_app_k5|jupiter_240k5_byte|k5_240|boot_known_good" /home/tcollins/.claude/projects/-mnt-onetb-scratch-qpsk-jupiter-modem/memory/*.md
```
For each: add a line at the top of the body: "Paths renamed 2026-09-09: two_jup→ops, host_app_k5→host, jupiter_240k5_byte→modem, k5_240→contract, boot_known_good→images; campaign files are on tag archive/pre-cleanup-2026-09-09." Do not rewrite the notes' content.

- [ ] **Step 2: Write one new memory**

`repo-layout-2026-09.md`, type `project`: the seven-directory layout, the tag name, the `tools/check_paths.sh` rule, the fact that `ops/skidfix` is staged for sub-project 2, and the `/mnt/onetb/scratch/qpsk-build-trees/` harvest location. Add its line to `MEMORY.md`.

- [ ] **Step 3: Final report**

Report: tracked-file count before and after, `.git` size (unchanged, by design), the tag name on both remotes, CI status, the health-gate numbers with the commands, and the list of stale headings dropped in Task 11. State explicitly that no PER window was run in this sub-project (none is needed; nothing on the boards changed) and that sub-project 2 starts from `ops/skidfix/` plus the harvest tarballs.
