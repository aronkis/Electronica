# Repo and design cleanup — design

Date: 2026-09-09. Branch: `per-under-1pct-2026-07`. Status: approved in brainstorming, awaiting spec review.

## Why now

Both legs are under the 1 % PER target (forward 0.070–0.079 %, reverse 0.191 %
pooled, lost frames in the denominator; ledger `two_jup/RXFIX_STATE.md` Task 37).
The repository that got there is a campaign workspace, not a product tree:

- 2860 tracked files, 1712 of them in `two_jup/` (296 markdown ledgers, 377 shell,
  395 txt, 145 csv, 115 log). The operator kit the docs point at is ~40 of these.
- The deployed images are built by a chain nothing in the tree names end to end:
  Simulink model → 34 overlay scripts → HDL Coder → Python netlist injectors in
  `two_jup/skidfix/` (W1, R4B, R4D, R1, PAD, BS census, SEQ-BIST) → Vivado. The
  `.slx` knows nothing about the shipped fixes.
- The two boards run different images because the ring fix depends on the sign of
  the sample-rate offset (R4B on 148, R4D+R1 on 146). A fresh pair has an unknown
  sign; PROVENANCE carries a trap note about it.
- Two parallel doc sets (`docs/*.md` and the Sphinx `docs/*.rst` that CI publishes),
  a stale README status line, `.git` at 5.3 GB, ~60 gitignored 1.5–3 GB build trees
  and ~150 loose logs at the root, 10 stale `worktree-agent-*` branches.

## Decisions taken (with the user, 2026-09-09)

| Question | Decision |
|---|---|
| Scope | Hygiene **and** design consolidation |
| Git history | Forward-only. No rewrite, no fresh repo. |
| Where the fixes live | Promote the injectors first (sub-project 2), then back-port into the model (sub-project 3) |
| SRO sign | One image, runtime select via a fixctl bit |
| Campaign material | Split and archive out: operator kit stays, cited ledgers move to `docs/evidence/`, everything else lives on an archive tag |
| Directory renames | Yes |

## Structure: three sub-projects

Each is its own plan and commit series. Each leaves the repo buildable and the rig
deployable. Order is fixed: 1 → 2 → 3.

1. **Repo hygiene.** Tree restructure, evidence archive, docs unification, README
   truth-up. No fabric change, no build.
2. **Fix layer promotion.** The netlist injectors become a documented stage of one
   canonical build script. Proven by a rebuild that passes the sim gates and BIST
   golden, then a silicon window against the banked images.
3. **Model back-port with runtime SRO select.** The fixes are reimplemented in the
   Simulink design behind one fixctl bit. Injectors are deleted once the new image
   matches on silicon.

---

## Sub-project 1: repo hygiene

### Archive first

Before any move or delete:

1. Tag `archive/pre-cleanup-2026-09-09` on the current HEAD of
   `per-under-1pct-2026-07`; push the tag to `origin` and `upstream`.
2. Delete the 10 `worktree-agent-*` branches after checking each with
   `git branch --merged` or confirming its tip is reachable from the tag. Remove
   their worktrees with `git worktree prune`.

Everything dropped below is recoverable by path from the tag. The README says so.

### Target layout

| New path | Old path | Contents |
|---|---|---|
| `modem/` | `jupiter_240k5_byte/` | renamed whole in sub-project 1; `rtl_sim/` keeps the harness sources and moves tracked gate evidence to `rtl_sim/evidence/`, sweep-output dirs go to the tag. The `model/` split, overlay pruning, `build_image.sh`, and `fixes/` arrive in sub-project 2, which is where the shipped chain is traced end to end. |
| `host/` | `host_app_k5/` | daemon and tools; `modem_status/` subdirectory for the `ms_*` sources; `tests/` for the C unit tests; `zed/` and `xvc_server.c` to the archive tag unless a doc cites them |
| `ops/` | `two_jup/` | operator kit only: bringup, deploy, provision, health probe, flash chains, capture, link test, `sim_repro/riglock.sh` and `no_arm_inflight.sh`. Target ~40 files. |
| `contract/` | `k5_240/` | `PACKET_K5.txt`, `PACKET_F1536.txt`, `golden_k5.mat`, `golden_f1536.mat`, the float reference receiver and its tests. The ~30 `run_*.m` sweep scripts leave. |
| `images/` | `boot_known_good/` | `CURRENT.txt`, `MD5SUMS`, the two current images and their on-board rollbacks, kernel `.gz`, dtbs, `daemon/`. The other ~28 BOOT.BINs go to the tag. |
| `docs/` | `docs/` | Sphinx only. Each `docs/*.md` folds into the `.rst` page that covers it (table below). `docs/evidence/` holds the 26 ledgers the docs cite, moved verbatim with a header line naming the tag. `docs/superpowers/{specs,plans}` unchanged. |
| `tests/` | `tests/` | unchanged MATLAB suite, paths updated |
| root | | `README.md`, `.gitignore`, `.github/`, `tools/`, `build_env_jupiter.sh`. `REPRODUCE.md`, `OVERNIGHT_LOG.md`, `2026-07-01-bidir-240k-k5-design.md`, `plans/`, `docs_session/`, `evm/`, `tick_repro*/` go to the tag or fold into docs. |

Root disk hygiene (untracked, not in git): the ~150 loose logs and `.jou` files and
the 62 `jupiter_byte_*_build` / `_gates` trees (81 GB) are deleted from disk. Two
exceptions. (1) The build tree behind the current 148 image
(`jupiter_byte_rxfixpad_build`) moves whole to `/mnt/onetb/scratch/qpsk-build-trees/`
(the 146 image was built on the lab host; its kit is not on this disk). (2) Before
any tree is deleted, every hand-written script and config in it (`*.sh *.py *.tcl
*.m *.xdc *.tmpl *.toml *.md *.txt` outside `hdl_prj*/ slprj/ ipcore/ .Xil/`) is
tarred into `/mnt/onetb/scratch/qpsk-build-trees/harvest/<tree>.tar.gz`, because
some of those scripts (`build_txfix.sh`, `build_final.sh`, `rxfix_*.m`) were
generated into the trees and never tracked. The delete list is written to a file
and its counts are reported before the delete runs.

### Which markdown folds where

| `docs/*.md` | Sphinx page |
|---|---|
| ARCHITECTURE, GLOSSARY | `system-overview.rst`, new `glossary.rst` |
| BRINGUP, PORTING, DEPLOY_F1536, BRINGUP_F1536_RESULTS | `setup-prebuilt.rst`, new `bringup.rst` |
| BUILD, PROVENANCE | `build-and-flash.rst`, new `provenance.rst` (lineage table kept) |
| DEBUGGING | `debug-instruments.rst` |
| TESTING | new `testing.rst` |
| LINK_CHARACTERIZATION, EVM_BUDGET | new `performance.rst` |
| REPRODUCE (root) | `measurement-discipline.rst` |

Stale claims are corrected while folding (README status line, "shipped image =
lean dcf5c5fb", "1.92 MSPS" wording where the deployed rung is 61.44 MSPS).

### `.gitignore`

Rewritten as a short allowlist of the seven top-level directories plus root files,
with the derived-artifact rules (`*.log`, `*.mat`, build trees, sim output) after
it. The per-file evidence re-includes disappear because the evidence now lives in
`docs/evidence/` and `modem/rtl_sim/evidence/`, which are tracked wholesale.

### Path references

`grep` for every old directory name across scripts, Makefiles, tests, docs, and
`tools/precommit_size_guard.sh`; update or delete. `tests/runTests.m` must pass
L1 after the move. Memory notes that name old paths are updated in the same
session.

### Done when

- `git ls-files | wc -l` is under 700.
- `sphinx-build -W` passes locally with the CI-pinned versions.
- `tests/runTests.m` L1 passes.
- `ops/deploy_image.sh`, `ops/bringup_r2r3.sh r3`, and
  `ops/health_probe_reset_aware.sh` run against the rig unchanged in behaviour
  (one dry pass, one live pass, health gate exactly 1245 both legs).
- README quick start is correct as written.

---

## Sub-project 2: fix layer promotion

### Goal

A fresh clone builds the role-A and role-B images from one command with the
injectors as a visible stage.

### Stages in `modem/`

| Stage | Where | What |
|---|---|---|
| 1 model | `modem/model/` | .slx, parameters, shipped overlays. Overlays no shipped image uses go to the tag. |
| 2 hdl | `build_image.sh` | HDL Coder, checkhdl gate, sim gate on the pristine netlist |
| 3 fixes | `modem/fixes/` | `rxfix_inject.py`, `txfix_inject.py`, their unit tests, `apply_fixes.py` driver, `fixes.toml` manifest |
| 4 sim gate | `modem/rtl_sim/` | beat and txfix gate matrices, driven from the manifest |
| 5 vivado | `build_image.sh` | synth, timing gate (intra-clock post-route WNS on the modem clock), bootgen |

`build_image.sh --role A|B` runs all five. `--stop-after <stage>` and `--from
<stage>` exist for iteration. Every stage writes a stamp file with the manifest
hash and commit.

### The manifest

`fixes.toml` lists, per fix: name, injector and function, control bits (fixctl bit
index and meaning), witness registers (address, field layout, order), which role
enables it, and the gate rows that prove it. It is the single source for:

- `apply_fixes.py` (which patches to apply for a role),
- the sim gate list (which rows must run),
- `host/qpsk_hw.h` and `host/modem_status/ms_regmap.c` via a generator
  `tools/gen_regmap.py`, so the R4D witness-word swap recorded in RXFIX_STATE
  cannot recur. Generated files carry a "do not edit" header and a CI check
  regenerates and diffs them.

### Instruments

Capture and probe injectors (ddrcap, ddrcap2, dbgcap, stagesig, stagesig3, txcap,
demodcap, rxfe, txint) are instruments, not fixes. They move to
`modem/instruments/<name>/` with the injector, its tcl/xdc, and a one-paragraph
README stating what it captures, which register window it uses, and the image it
was last built into. They are not part of the default build; `build_image.sh
--instrument <name>` adds one.

### Verification

1. Build both roles on the lab host under `systemd-run --user` with a timeout
   and a post-check on the artifact (CLAUDE.md long-build rule).
2. Gate: sim gates pass, BIST golden `cap_out = 0x04922282`, timing gate passes.
3. Flash one board at a time under the existing rails (`ops/flash_*` chain,
   `FLASH_BAK` = current image). Two-pass health gate. Credited 10-minute PER
   window per leg via `capture_r3.sh` + `accept_analyze.py`, lost frames in the
   denominator, compared with forward 0.070–0.079 % and reverse 0.191 %.
   Acceptance: within 2× of those numbers on each leg with no new comb line.
4. Rollback is the current banked image, already on-board as `.bak`.

### Docs

`build-and-flash.rst` rewritten around the five stages. `provenance.rst` current
rows name the manifest hash and commit, not a build directory.

### Done when

- `build_image.sh --role A` and `--role B` from a fresh clone produce images that
  pass step 3.
- `images/CURRENT.txt` points at those images.
- `two_jup/skidfix` no longer exists; nothing in the tree references it.

---

## Sub-project 3: model back-port with runtime SRO select

### Goal

The Simulink model emits the fixed receiver directly. HDL Coder output passes the
sim gates with no injectors, one image serves both roles, `modem/fixes/` is deleted.

### What moves into the model

| Group | Fixes | Locus |
|---|---|---|
| Rate_Handle ring | R4B (EMPTY-edge skip steering), R4D (FULL-edge extra pop), W1 witness counters | ring wrapper around Rate_Handle |
| Preamble_Detector | R1 (valid-indexed pop; retires the Delay10 shift register) | PD realignment FIFO |
| ByteSerializer | PAD (pad truncated frames to 191 words) | byte-plane TX serializer |
| Instruments | BS byte-seam census, SEQ-BIST | byte plane, behind the existing fixctl freeze bit |

### Runtime SRO select

One new fixctl bit, `sro_sign`, muxes between the R4B and R4D steering decisions.
R1 and PAD are unconditional. Witness words stay at 0x234 and 0x238 with the
corrected field order from the manifest. Bring-up measures the RX-LO residual
sign (the sign cross-check in RXFIX_STATE) and writes the bit; `bringup_r2r3.sh`
does this. modem_status shows the bit and the active steering edge.

### Gates, each blocking the next

1. **Netlist equivalence.** HDL Coder output with `sro_sign` forced each way
   replays the beat and txfix gate matrices at 0, ±2.5, ±10 ppm and matches the
   injected netlist's loss numbers within the run-to-run spread recorded in the
   gate logs.
2. **Timing.** Intra-clock post-route WNS on the modem clock must not fall more
   than 0.1 ns below the rxfixpad image's margin. If it does, fall back to the
   sub-project-2 build with `--role`; the runtime select is dropped, not
   squeezed.
3. **Silicon.** Flash 148 with `sro_sign` = EMPTY, two-pass health gate, credited
   PER window. Then 146 with `sro_sign` = FULL. Then swap the bit on one board
   and confirm the comb returns and clears again.

### Stated risk

The injected fixes were validated against Verilog HDL Coder emitted. Rebuilt as
Simulink blocks, HDL Coder re-times and re-pipelines around them, so a bit-exact
netlist is not the target; gate-equivalent loss behaviour is. If gate 1 diverges
and the cause is not found in two iterations, the sub-project stops with the
sub-project-2 build as the shipped state and the divergence is written up in
`docs/evidence/`.

### Cleanup at the end

Injectors, `modem/fixes/`, `modem/instruments/` entries that only existed for the
injected flow, and the netlist gate variants specific to injection are deleted.
`byte-plane.rst` and `debug-instruments.rst` updated. The archive tag holds the
old flow.

### Done when

- One image, built by `build_image.sh` with no `--role`, is on both boards.
- Gate 3 passed, including the bit-swap test.
- `modem/fixes/` does not exist.

---

## Out of scope

- Git history rewrite (decided against; may be revisited once the tree is settled).
- Any DSP change beyond moving the existing fixes. The reverse-leg lag-25 comb
  and the 148 antenna replacement are separate work.
- Symbol-rate or profile changes.

## Rules that apply throughout

- Flash chains run under the existing rails and are pre-authorised (memory:
  flashes-preauthorized). Rollback image on-board before any flash.
- Long builds run under `systemd-run --user` with a timeout and artifact
  post-check. Never polled in the foreground.
- Never edit a script a live rig unit is running; launch frozen copies.
- Any PER number reported carries the command, the sample count, and the
  statement that lost frames are in the denominator.
- Commits are signed off (`git commit -s`) and pushed.
