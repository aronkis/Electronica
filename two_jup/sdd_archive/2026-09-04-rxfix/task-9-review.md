# Task 9 review — RXFIX_W1 silicon ring-witness + per-stage valid census

Scope: commits `2c661e6`, `71b4422`, `e51e467` on `per-under-1pct-2026-07`. Read-only
review — no board contact, no sims, no builds; all evidence below is either a
direct read of committed files, a re-run of the committed pytest suite, an md5/
arithmetic check against committed data, or a diff against real RTL trees already
on disk (`jupiter_240k5_byte/s1_rtl/…`, `jupiter_byte_seqbist_build/…`,
`jupiter_byte_rxfixw1_build/…`).

## Verdict: CONDITIONAL

The RTL, injector, tests, sim gate and kit are correct and reproduce exactly as
claimed — this is solid, well-gated instrument work. But `W1_REGMAP.md` is the
document Task 10 will run the air leg from, and it is missing three facts a rig
driver needs before a multi-minute live leg: how to obtain the fixctl value that
must be OR'd into a freeze write (§2 gives no method, and the register cannot be
read back), the wrap period of both counter families (only a generic "wraps"
warning exists), and which commit the banked image actually came from (the
recorded provenance hash is stale). None of these are RTL defects — the banked
image is exactly what it claims to be — but Task 10 should not start the air leg
against `W1_REGMAP.md` as currently written without these added.

**Note on scope drift found mid-review:** `two_jup/rxfix/w1_read.sh` and
`two_jup/rxfix/w1leg_go.sh` were modified/created on disk during this review
(uncommitted; `w1leg_go.sh` is untracked). This is evidently concurrent Task 10
work in the same tree, not part of Task 9. This review is against the
git-committed state of `w1_read.sh` at `e51e467` (confirmed identical to what was
read before the on-disk change: md5 `10d80c549cba823773c61c92ab8b06eb`). Findings
2 and 3 below concern gaps in Task 9's own deliverable regardless of what Task 10
is independently doing about them.

## Claims reproduced directly

1. **Injector safety pattern + tests.** `python3 -m pytest two_jup/skidfix/test_rxfix_inject.py -q`
   → **74 passed** (current HEAD, which also carries Task 11's later R3S
   additions); `-k TestW1` → **17 passed, 0 skipped** — both real source trees
   (`jupiter_240k5_byte/s1_rtl/…`, `jupiter_byte_seqbist_build/…`) are present on
   disk so the patchers ran against real files, not stubs. At Task 9's own final
   commit (`e51e467`) the suite was 74 tests total (confirmed via
   `git show e51e467:two_jup/skidfix/test_rxfix_inject.py`), matching the
   report's "56 (39+17)" figure from the earlier `71b4422` snapshot before
   Task 11's R3S tests (added concurrently, `79e7015`/`e98a925`, both ancestors
   of `e51e467`) landed on the branch. Exactly-once anchors (`_span`/`_sub`,
   `rxfix_inject.py:83-87,319-332`), per-variant marker, 3 loose mirrors + both
   zip members + `verify_zip`, `--sim-tree`, and idempotence (`fn(p)` →
   `'patched'` then `'already'`) are all exercised by `TestW1` and pass.
2. **Read-only claim.** `test_52_w1_touches_no_data_path_assign` asserts every
   pre-existing `assign` survives patching; independently confirmed by reading
   `Validate_Input_Push_Pop_block.v:49,57,61,106,110,115,119,121,129,131` (real
   file, `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`) — `Delay_out1`
   (`reg [5:0]`), `pop_on_empty_FIFO`, `push_on_full_FIFO` exist exactly as W1
   taps them, and the addr_decoder's `data_read` becomes
   `(w1_hit ? w1_reg[w1_idx] : mux_out0_level1)` with the generated mux kept as
   fallback (`rxfix_inject.py:1211-1226`) — the one documented exception, and it
   adds a mux input rather than redefining one.
3. **Address-decode arithmetic, hand-verified.** `w1_idx = address_select_level1[2:0] - 3'd5`
   (3-bit modular subtraction) correctly maps words `0x85..0x8C` to indices
   `0..7` in order (witA, witB, cSS, cRH, cCFC, cCS, cPD, cPC) — checked by hand
   for all eight words. Independently grepped the real
   `TxRxCompo_ip_addr_decoder.v` (`jupiter_byte_seqbist_build/…`) for
   `8'b10000101` .. `8'b10001100`: **zero hits**, confirming words 0x85-0x8C are
   genuinely free before the patch (same thing `test_50` asserts).
4. **Ownership-check substance.** `TxRxCompo_ip_src_BeatObs.v:80-86` in the real
   kit tree confirmed: `s_4={16'b0,pushc}`, `s_6={16'b0,popc}`,
   `sub_temp=s_5-s_7`, `fill8=cast&255` — a pointer delta with no `numEntries` or
   `push_on_full` anywhere in the file (grepped, 0 hits for both). The report's
   §1.1 correction to task-7-report.md §6.1 ("the counters already exist") is
   verified correct.
5. **Sim gate data.** Recomputed from the committed files in
   `two_jup/comb/sro_sim/w1gate/`, not re-run:
   - `md5sum base_p000_deliv.txt w1_p000_deliv.txt` → both
     `555fbb25362f14a3d36b60f6797152af`, 164 lines each.
   - `md5sum base_m10_deliv.txt w1_m10_deliv.txt` → both
     `91680b59e9cebdae3b285953fea203ef`, 209 lines each.
   - `w1_p000_res.txt` / `w1_m10_res.txt`: `compared_beats=8239781 mismatches=0`
     and `compared_beats=10459721 mismatches=0`, matching the report exactly.
   - `w1_m10_w1.txt`: frame 41 row is `1,1,...` (poe_ref=1,poe_w1=1), frame 73
     row is `...,5,5,...`, last row (`f=-1`, end-of-leg sentinel) is
     `witA=0x00000294` fields (occ 0, push 20, pop 20), `witB` fields (poe 21,
     pof 0) — all match the report verbatim.
   All four numbers the report leads with are real, not transcribed wrong.
6. **Kit script.** Read `two_jup/skidfix/jupiter_byte_rxfix_kit.sh` in full: it
   refuses a source kit without `rx_seq_checker`/`IMPL_STRATEGY`/routed-WNS gate
   (`:47-53`), independently re-verifies the marker in all three loose mirrors
   and both zip members rather than trusting the injector's own printout
   (`:84-114`), and asserts post-patch that `read_reg_beatfix_viol_count` and the
   `fixctl` write decode (`decode_sel_fixctl_1_1`) both survive (`:124-127`).
   This substantiates "the kit preserved the SEQ-BIST judge and the routed-WNS
   gate."
7. **Banked artifact.** `md5sum boot_known_good/BOOT.BIN.148.rxfixw1.2728dab3979a`
   → `2728dab3979a54616f1ad67f1ac8e8a7`, 7,203,552 bytes — matches the report and
   the filename's md5 suffix exactly. Only one binary was added across the three
   commits (`git show --stat` on each); no other large binaries.
8. **No board contact.** Grepped every `Task 9:` ledger line and every
   `HEARTBEAT task9` line in `progress.md` (lines 328-483) for `10.0.0.148`,
   `10.0.0.146`, `ssh 10.`, `scp`, `devmem`, `flash`, `reboot` — zero hits.
9. **Reader mechanics, reproduced by direct execution (DRY only, per this
   review's own no-board-contact rail).** Ran the committed `w1_read.sh`
   (`git show e51e467:two_jup/rxfix/w1_read.sh`) three ways: `DRY=1` emits N
   lines with `dry:true` and zero ssh calls, spaced exactly 10 s apart;
   `PERIOD=1` is clamped to 10 with a logged `WARN`; and `DRY=0` against a fake
   ssh shim (`FIXCTL_BASE=8`) produced the remote script
   `wr 0x208 0x18; <16 reads>; wr 0x208 0x8` — exactly the freeze-on/read-twice/
   freeze-restore sequence the report describes, and `freeze_effective` correctly
   computed `false` when the shim returned two different 8-word sweeps. This
   reproduces the never-read-modify-write claim, the ≥10 s floor, and the DRY/shim
   test path.
10. **WNS/timing.** Not independently re-derived — no hdl-dev-2 access, per this
    review's own rail. The banked md5/size (item 7) and the kit's preservation of
    the SEQ-BIST judge and `TXFIX_ROUTED_TIMING_FAIL` gate (item 6) are locally
    verified; the WNS/endpoint numbers themselves are corroborated by Task 9b's
    independent re-read of the same routed `report_timing_summary`
    (`two_jup/comb/RXFIX_W1_TIMING.md`, a second task, same numbers) but that is
    corroboration, not reproduction, and should be read as such.

## Findings

### Critical
None.

### Important

**I1. `W1_REGMAP.md` §2 tells the operator to "check what is armed" but gives no
method, and the register that would answer the question cannot be read.**
(`two_jup/rxfix/W1_REGMAP.md:49-59`; report concern #4,
`task-9-report.md:348-354`.) `fixctl` (0x208) is write-only and reads back
`const_0`. A freeze write via `w1_read.sh` sets the *whole* 32-bit word
(`w1_read.sh:92-93,96-98` at `e51e467`); over a planned 600 s leg at 10 s cadence
(`task-10-brief.md` Step 3, `DUR=600`) that is roughly 120 whole-word writes to
0x208 during the measurement. `freeze_effective` (the reader's own self-check)
cannot catch a wrong `FIXCTL_BASE`: it only compares W1's two internal sweeps,
which hold correctly regardless of what else the write clobbered. So a wrong
`FIXCTL_BASE=0` on a leg that actually has `enSlack` (bit 3) or the TXCAP/DEMODCAP
mux bits (12/13) armed silently disarms them for the whole leg while every W1
indicator — including `freeze_effective:true` — stays green. The report names the
symptom (concern #4) but stops at "wants an explicit FIXCTL_BASE in whatever
runbook the flash task writes" — that defers the derivation rather than closing
it. `W1_REGMAP.md` §2 should instead state the derivation directly: which arming
scripts write 0x208 and with what value (i.e. trace it the way one would need to,
through `arm148_mode1.sh`, `bringup_r2r3.sh`, `capture_r3.sh` — the point is this
belongs in the regmap, not left for the next task to reconstruct from source).

**I2. Neither counter family's wrap period is computed, and Task 10's own
600 s leg exceeds the tighter one by ~2×.** `W1_REGMAP.md` states both families
"wrap" (`:20,28`) but never gives a period, and no document in the chain
(`task-9-report.md`, `RXFIX_W1_SIM_GATE.md`, `RXFIX_STATE.md`, `task-10-brief.md`)
computes one, despite this exact kind of computation being standard practice
elsewhere in the campaign (`two_jup/comb/SRO_SEL13_DESK.md:105-107` states a wrap
period for a comparable counter in the same units).
- **32-bit census counters** (cSS/cRH/cCFC/cCS/cPD/cPC) run at
  `enb_1_2_0` ≈ 1,247 f/s × 12,333 valids/frame ≈ 15.38 M/s (the rate
  `task-10-brief.md:9` itself uses). `2^32 / 15.38 M ≈ 279 s ≈ 4.65 min`.
- **16-bit edge counters** (`push_on_full`/`pop_on_empty` halves of witB) run at
  the predicted forward-leg rate ≈ 395 pop_on_empty per 10 s
  (`task-10-brief.md:9`) = 39.5/s. `2^16 / 39.5 ≈ 1,660 s ≈ 27.7 min`.
- `task-10-brief.md` Step 3 specifies `DUR=600` (10 min) for the air leg — **more
  than 2× the 32-bit census rollover period.** Consecutive 10 s-apart deltas stay
  safe (a 10 s window's true delta ≈ 154 M, one modular subtraction recovers it
  correctly across at most one wrap), which is presumably why the brief's
  `w1_reads.csv` design calls for delta columns. But the brief also specifies a
  **cumulative** column and a whole-window check (P2: "strobe delta = 12,333 ×
  (TX frames in the window)" over the full 600 s). Worked example: true 600 s
  census delta ≈ 1,247 × 600 × 12,333 ≈ 9.228×10⁹ = 2.15 × 2³²; a naive
  first-minus-last unsigned subtraction returns ≈ 0.638×10⁹ — off by a factor of
  ~14, which would likely be caught as obviously wrong rather than misread as a
  genuine deletion (the true P2-alt shortfall, ~23,700 events, is six orders of
  magnitude smaller). The more realistic hazard is the raw **cumulative** column
  itself: it will visibly wrap ~2 times across a single 600 s leg, appearing as a
  sudden drop toward zero in the middle of an otherwise-healthy tap's time
  series — in a campaign built specifically around treating counter anomalies as
  evidence, that is a plausible source of a false "this tap looks broken" call on
  a leg that later runs longer than 279 s, or on a multi-leg session. None of
  this is stated anywhere; it should be, in `W1_REGMAP.md` §3, alongside the
  existing `K ≈ 2000` example (which is itself safe — ≈1.6 s of census — but
  doesn't warn against longer windows).

**I3. The `injector_commit` recorded for the banked build is stale — it names a
commit that does not contain RXFIX_W1.** `task-9-report.md:229-231` and the
banked `RXFIX_VARIANT` file both record
`injector_commit=b5c39a10367a1bbe3a84d955eefee75765e000c5`. That hash resolves
(`git rev-parse` confirms) to `b5c39a1`, Task 7's R3-injector commit — the *prior*
commit to touch `rxfix_inject.py`, which has no `W1` variant at all
(`git log --oneline --follow -- two_jup/skidfix/rxfix_inject.py` shows only
`79e7015 → 2c661e6 → b5c39a1 → e08a2f4`). Timeline: the ledger's own heartbeat at
`13:58:44-04:00` already shows the Vivado build active ("Waiting for synth_1 to
finish"), while the commit that adds W1 to `rxfix_inject.py` (`2c661e6`) lands a
minute later at `13:59:56-04:00`. So the kit script's
`git log -1 --format=%H -- two_jup/skidfix/rxfix_inject.py`
(`jupiter_byte_rxfix_kit.sh:142`) ran against an **uncommitted working tree**
and correctly, but unhelpfully, reported the last *committed* touch — one commit
too old. Confirmed with content, not just inference: the `rh_w1_census` module
actually built into `jupiter_byte_rxfixw1_build/hdl_prj_jupiter_composite/hdlsrc/
commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v` is
byte-for-byte identical (`diff`, 68/68 lines) to the `W1_CENSUS_MODULE` string in
`git show 2c661e6:two_jup/skidfix/rxfix_inject.py` — so **2c661e6, not the
recorded b5c39a1, is the commit that matches what was actually built.** Anyone
auditing the banked image later via the recorded `injector_commit` would check
out a commit with no W1 support and be unable to reproduce it. Low functional
risk (the banked image itself is correct and independently verified by marker +
md5), but a real provenance gap worth a one-line correction in the report/ledger.

### Minor

**M1. Line-number citations for the 0x20C/0x210 ownership finding are off by
~11 lines in the final report** (not in the ledger). `task-9-report.md:20-23`
cites `TxRxCompo_ip_addr_decoder.v:583-586` for case `8'b10000011` and `:587-590`
for `8'b10000100`. Reading the real file
(`jupiter_byte_seqbist_build/hdl_prj_jupiter_composite/hdlsrc/
commhdlQPSKTxRxLoopback/TxRxCompo_ip_addr_decoder.v`), those case arms are
actually at lines 594-597 and 598-601; lines 583-586 are the tail of the
*previous* case (`8'b01110101`, `read_reg_framestat_head_hi`). The ledger's own
citation for the same finding (`progress.md:336`, `"505,595-604"`) is accurate —
505 is the `case (address_select_level1)` line, 595-604 spans both real arms. The
underlying conclusion (0x20C/0x210 = beatfix_viol_count/_latch, owned by
DBGCAP/TXCAP, not touched by W1) is correct in both places; only the report
table's specific numbers need fixing.

**M2. W1's freeze and the pre-existing SEQ-BIST checker's freeze are two
independent, non-atomic mechanisms, and nothing says so.** W1's freeze is
`fixctl[4]` at AXI-lite `0x208` (IP-internal). `rx_seq_checker`'s own freeze is a
**separate**, pre-existing mechanism: `tgen_rx_ctrl_gpio` bit `[3]` at BD GPIO
`0x9D410000` (`two_jup/skidfix/patch_seqbist_tcl.py:56,247-251`,
`sb_conn sb_freeze_slice/Dout rx_seq/freeze`). Freezing one does not freeze or
even touch the other; `w1_read.sh`'s `freeze_effective` says nothing about
whether the checker's own 16 counters were held at the same instant. Neither
`W1_REGMAP.md` nor `task-9-report.md` mentions this distinction anywhere (grepped
for "checker"/"9D41"/"GPIO" in both — no hits beyond the generic "cnt_mux32 /
rx_seq_checker / 0x9D4x GPIOs are untouched" line,
`W1_REGMAP.md:100`, which states non-interference with the checker's *logic* but
not the freeze-independence fact). Kept Minor rather than Important because
Task 10's actual planned use (`task-10-brief.md` P3: "checker gap events per 10 s
≈ 1-2 × pop_on_empty delta") is a rate correlation over matching ~10 s windows,
which tolerates a few milliseconds of freeze skew between the two mechanisms —
but it should still be one sentence in `W1_REGMAP.md` so a future tighter,
frame-exact correlation attempt doesn't assume a single coherent snapshot across
both instrument families.

## Checked, not a finding

- **Marker-check substring pattern.** At the time of Task 9's commits, every
  variant (R1/R2/R3 and the new W1) checked "already patched" with a plain
  `MARKER in s` substring test (verified: `git show b5c39a1:…rxfix_inject.py` —
  R3 used plain `in` too, pre-Task-9). The token-boundary-safe `_has()` helper
  (guarding against a variant whose marker string is a prefix of another, e.g. a
  future `RXFIX_W1L`) was introduced later, in Task 11's `79e7015`, and applied
  **repository-wide** to R1/R2/R3/W1 together for the `RXFIX_R3S`-vs-`RXFIX_R3`
  collision it actually hit. This is not something Task 9 got wrong relative to
  its peers — it matched the prevailing pattern and was fixed for everyone at
  once. Noted only so it isn't re-litigated as a Task 9 defect.
- **Address aliasing with DBGCAP/other decoded words.** Independently confirmed
  (finding-reproduction item 3 above): words `0x85..0x8C` are absent from the
  real generated decoder before patching. No aliasing.
- **`ddrcap_sel=12` skip and the no-`cnt_mux32` deviation.** Both are stated
  plainly in the report and the ledger (controller ruling,
  `progress.md:359`, `13:58:09-04:00`) and are reasoned, not hidden. Concur with
  the reasoning: `cnt_mux32` is genuinely a BD cell with no free slots, and eight
  AXI-lite read words is the lower-risk path.
- **No large binaries other than the banked image; no board contact.** Confirmed
  (reproduction items 7-8 above).

## What Task 10 must know before the air leg

1. **[I1] There is no way to read back the currently-armed `fixctl` value —
   `FIXCTL_BASE` must be derived from the arming chain (which scripts write
   0x208 and with what value) before the first live `FREEZE=1` sweep, and that
   derivation is not written into `W1_REGMAP.md`.**
2. **[I2] The 32-bit census counters wrap in ~279 s (~4.65 min) and the 16-bit
   edge counters in ~28 min at the predicted forward-leg rate. The planned 600 s
   leg crosses the census rollover ~2×. Always accumulate from consecutive ≥10 s
   reads (safe); never subtract a leg-start cumulative value from a leg-end one.
   Expect the raw cumulative columns to show a visible sawtooth reset partway
   through the leg — that is arithmetic, not a hardware fault.**
3. **[I3] The image's provenance record points at the wrong commit
   (`b5c39a1`, no W1 support); the commit that actually matches the banked build
   is `2c661e6` (confirmed by diffing the built `rh_w1_census` module against
   the commit's `W1_CENSUS_MODULE` — byte-identical).**
