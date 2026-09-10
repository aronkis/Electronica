#!/bin/bash
# precommit_size_guard.sh -- refuse oversized commits.
#
# WHY: on 2026-08-15 a bulk `git add` of the campaign tree swept the entire capture archive into a
# commit -- 1240 files, 182,828,779 insertions. It was caught before push only by
# reading `git show --stat`, and unwinding it cost a reflog surgery plus two gc
# passes. This guard makes that class of accident fail loudly instead.
#
# Install:  ln -sf ../../tools/precommit_size_guard.sh .git/hooks/pre-commit
# Bypass:   ALLOW_BIG=1 git commit ...   (state why in the commit message)
#
# Note: a symlinked hook covers the main worktree. Each linked worktree has its own
# .git/hooks (or shares one via core.hooksPath); run with `git config core.hooksPath
# tools/githooks` if you want it fleet-wide.
set -u
MAX_FILES=${MAX_FILES:-200}
MAX_BYTES=${MAX_BYTES:-20971520}   # 20 MiB

[ "${ALLOW_BIG:-0}" = "1" ] && exit 0

nfiles=$(git diff --cached --name-only | wc -l)
# sum the blob sizes of everything staged (added/modified), ignoring deletions
nbytes=$(git diff --cached --numstat >/dev/null 2>&1; \
         git diff --cached --name-only --diff-filter=ACMR -z \
         | xargs -0 -r -I{} sh -c 'git cat-file -s "$(git rev-parse :"{}" 2>/dev/null)" 2>/dev/null || echo 0' \
         | awk '{s+=$1} END {print s+0}')

fail=0
if [ "$nfiles" -gt "$MAX_FILES" ]; then
  echo "PRECOMMIT BLOCK: $nfiles files staged (limit $MAX_FILES)." >&2
  fail=1
fi
if [ "$nbytes" -gt "$MAX_BYTES" ]; then
  echo "PRECOMMIT BLOCK: $(( nbytes / 1048576 )) MiB staged (limit $(( MAX_BYTES / 1048576 )) MiB)." >&2
  fail=1
fi

if [ "$fail" = 1 ]; then
  cat >&2 <<'MSG'

  This repo tracks SOURCE. Measurement and sim output belong on local disk
  (see .gitignore) -- bank only the narrow evidence that backs a documented
  claim, as in the runlogs_20260815/ bank.

  Largest staged paths:
MSG
  git diff --cached --name-only --diff-filter=ACMR -z \
    | xargs -0 -r -I{} sh -c 'printf "%10s  %s\n" "$(git cat-file -s "$(git rev-parse :"{}" 2>/dev/null)" 2>/dev/null || echo 0)" "{}"' \
    | sort -rn | head -10 >&2
  echo >&2
  echo "  Intentional? re-run with:  ALLOW_BIG=1 git commit ..." >&2
  exit 1
fi
exit 0
