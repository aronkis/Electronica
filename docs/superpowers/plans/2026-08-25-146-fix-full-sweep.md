# 146 TX Byte-Plane Fix + Full-Sweep Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the localized forward defect (146 TX byte-plane, ~10.6% PER) via a fresh-placement TMR rebuild flashed to 146 for the first time, restore BEATFIX on 148, harden lock_watchdog against the #48 delivery wedge, and close with a both-direction <1% CP95UL acceptance soak plus a BER tap-ladder on the residual.

**Architecture:** Four lanes per spec `docs/superpowers/specs/2026-08-25-146-fix-full-sweep-design.md`. Lane A gates: bank rollback image → provenance → rail census kill gate → flash → pre-stated ladder verdict. Lane B orders all capture-tap work before the 148 flash. Lane C is host-script-only. Lane D is measurement only.

**Tech Stack:** bash over `two_jup/anyssh.sh`, Vivado tcl (`two_jup/dcp_rail_dump.tcl`), existing capture/census/scoring instruments, MATLAB float receiver.

## Global Constraints

- Rig is a hard mutex. Before ANY rig-touching step: `touch /home/tcollins/modem-status/SENTINEL_STOP` and verify `pgrep -f "[d]elivery_sentinel"` returns nothing. After the step (until Task 8 retires it): `rm -f .../SENTINEL_STOP` and relaunch `setsid nohup /home/tcollins/modem-status/delivery_sentinel.sh >/dev/null 2>&1 & disown`.
- **One flash event per board maximum.** Rollback flashes (restoring a banked image after a failed gate) do not count against the budget but end that board's lane pending operator direction.
- Flash rails, verbatim: md5 precondition on the exact image file; readback verify; full bring-up (`restore_known_good.sh` / `bringup_r2r3.sh r3`); two-pass health gate fsync≥1100 AND wcnt≥1100; auto-rollback to the banked image on failure; NO retry.
- Every PER/BER claim: exact command, sample count, dropped/lost frames confirmed in the denominator. Verdict rules pre-stated, never revised after data.
- Long builds/soaks: `setsid nohup … & disown` + one background watcher. No foreground polling.
- Never pgrep/pkill a pattern present in your own cmdline — bracket the pattern (`[d]elivery`) or use explicit PIDs.
- 0x114/0x118/0x158 are WRITE-ONLY — verify by effect, never readback.
- Watchdog (re)starts on boards use ISOLATED ssh calls: separate `anyssh.sh` invocations for pkill / chmod+truncate / nohup / verify. A bundled single-ssh nohup dies.
- Commits: `git commit -s`; commit implies push. All results appended to `two_jup/SINGLES_CAMPAIGN.md` with a dated section header.
- Boards: 146 = 10.0.0.146 (TMR 433fd8dab393, TX under test), 148 = 10.0.0.148 (e49c011b7a75, working IQ tap). `D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup`.

---

### Task 1: Bank 146's live BOOT.BIN (hard gate A0)

**Files:**
- Create: `jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak`
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append)

**Interfaces:**
- Produces: the rollback image path above; md5 12-prefix MUST equal `433fd8dab393`. Tasks 5 (flash rollback target) and later depend on this exact path.

- [ ] **Step 1: Locate the boot partition file on 146.** Jupiter boots from the FAT boot partition mounted on the board. Find it:

```bash
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
$D/anyssh.sh 10.0.0.146 'mount | grep -i -e fat -e mmcblk; ls -la /boot 2>/dev/null; ls -la /mnt 2>/dev/null' 
$D/anyssh.sh 10.0.0.146 'find / -maxdepth 3 -name "BOOT.BIN" 2>/dev/null | head'
```
Expected: one BOOT.BIN path (typically `/boot/BOOT.BIN` or a FAT mount). If none found (boot partition not mounted), mount it read-only: `$D/anyssh.sh 10.0.0.146 'mkdir -p /mnt/bootp && mount -o ro /dev/mmcblk0p1 /mnt/bootp && ls /mnt/bootp'`.

- [ ] **Step 2: md5 on the board BEFORE copying:**

```bash
$D/anyssh.sh 10.0.0.146 'md5sum <BOOTBIN_PATH>'
```
Expected: `433fd8dab393…`. **If the md5 prefix is NOT 433fd8dab393: STOP the entire Lane A, report BLOCKED** — the identity of 146's running image is in question and the operator must rule.

- [ ] **Step 3: Copy to nemo via the SSH_ASKPASS scp pattern** (plain scp silently yields 0-byte files — proven footgun):

```bash
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
mkdir -p $ROOT/jupiter_byte_tmr146_gates/boot
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  root@10.0.0.146:<BOOTBIN_PATH> $ROOT/jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak
```

- [ ] **Step 4: Verify the copy:** `md5sum $ROOT/jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak` must match the board md5 exactly, and `stat -c%s` must be >10,000,000 bytes (a 0-byte or truncated copy fails the task).

- [ ] **Step 5: Append to ledger + commit:** add a dated "A0: 146 rollback image banked" section to `two_jup/SINGLES_CAMPAIGN.md` with both md5 outputs, then:

```bash
git add two_jup/SINGLES_CAMPAIGN.md && git commit -s -m "A0: bank 146 running image 433fd8dab393 as rollback (hard gate for first-ever 146 flash)" && git push
```
(The .bak itself is gitignored by the `*BOOT.BIN*`-adjacent rules; do NOT force-add it.)

---

### Task 2: Provenance-verify the 08-18 TMR rebuild (A1)

**Files:**
- Read: `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/` (generated HDL + BOOT.BIN), `jupiter_byte_tmr146_gates/asrun_433fd8da/` (asrun sources), `jupiter_byte_tmr146_gates/hdlsrc/` if present
- Modify: `two_jup/SINGLES_CAMPAIGN.md` (append verdict)

**Interfaces:**
- Consumes: nothing from Task 1 (parallel-safe).
- Produces: PASS/FAIL verdict line `A1_PROVENANCE PASS|FAIL` in the ledger, and on PASS the flash-candidate path `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` with its md5-12 (expected `4be9286ca111` — re-measure, do not trust the note). On FAIL, Task 3 builds the candidate instead.

- [ ] **Step 1: Confirm candidate image identity:**

```bash
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem
md5sum $ROOT/jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
```
Record the md5-12; this string is the candidate ID used in every later gate.

- [ ] **Step 2: Locate both generated-HDL trees.** The build dir's generated RTL lives under `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/` (confirm with `find $ROOT/jupiter_byte_tmr146_build -name "TxRxComposite.v"`). The reference lineage RTL for the flashed image: `find $ROOT/jupiter_byte_tmr146_gates -name "TxRxComposite.v"`. If the gates dir has no hdlsrc, regenerate nothing — instead compare against the asrun model by codegen: this is the FAIL path (Step 4 rule).

- [ ] **Step 3: Bit-compare the RTL set.** Compare every `.v`/`.vhd` under the two `hdlsrc/commhdlQPSKTxRxLoopback` trees, ignoring the known header-only differences (timestamp/version comment lines):

```bash
for f in $(cd <BUILD_HDLSRC> && ls *.v); do
  diff <(grep -v -e "^// Created:" -e "^// Generated by" -e "^// Simulink" <BUILD_HDLSRC>/$f) \
       <(grep -v -e "^// Created:" -e "^// Generated by" -e "^// Simulink" <REF_HDLSRC>/$f) >/dev/null 2>&1 \
    || echo "DIFF $f"
done
```
Also confirm the byte-plane module set explicitly present and identical: `TxRxComposite.v`, `ByteWordBuffer.v`, `ByteSerializer.v`, `ByteRxFifo.v`, `RxAlign.v` (names per `two_jup/NETLIST_PROVENANCE.md`).

- [ ] **Step 4: Verdict rule (pre-stated).** Zero non-header DIFF lines → `A1_PROVENANCE PASS`. Any DIFF, or missing reference tree, or missing candidate BOOT.BIN → `A1_PROVENANCE FAIL` (Task 3 runs). No judgment calls: a header-only diff is one whose only changed lines match the grep-excluded patterns; anything else fails.

- [ ] **Step 5: Ledger + commit:** append the verdict, file counts compared, and candidate md5 to `SINGLES_CAMPAIGN.md`; `git commit -s -m "A1: TMR rebuild provenance <PASS|FAIL> (candidate <md5-12>)" && git push`.

---

### Task 3: Rebuild TMR from asrun (only if A1 FAILED)

**Files:**
- Create: `tmr146_rebuild.status`, `tmr146_rebuild.log` (repo root, gitignored pattern `*.log`)
- Read: `jupiter_byte_tmr146_gates/asrun_433fd8da/` (`commhdlQPSKTxRxLoopback_asrun_433fd8da.slx`, `asrun_workspace.mat`, `init_data.mat`, `MANIFEST.txt`)

**Interfaces:**
- Consumes: `A1_PROVENANCE FAIL`.
- Produces: a new candidate BOOT.BIN + md5-12 recorded as `A1B_CANDIDATE <md5-12> <path>` in the ledger; Task 4 consumes the candidate path either way.

- [ ] **Step 1: Read `MANIFEST.txt`** in the asrun dir — it names the exact codegen recipe/env for this lineage. Follow it verbatim; if it names a build script, use that script. If MANIFEST names no runnable entry point, reuse the recipe that produced `jupiter_byte_tmr146_build` (its top-level build script — `ls $ROOT/jupiter_byte_tmr146_build/*.sh $ROOT/jupiter_byte_tmr146_build/*.tcl`) pointed at the asrun .slx.
- [ ] **Step 2: Launch detached** (~3 h, MATLAB codegen + Vivado):

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
setsid nohup bash <BUILD_ENTRYPOINT> > tmr146_rebuild.log 2>&1 < /dev/null &
disown
echo "TMR146_REBUILD_RUNNING pid=$!" > tmr146_rebuild.status
```
Start ONE background watcher polling for the build's terminal marker or BOOT.BIN appearing; no foreground waits. Note: `~/.local/bin/as` shadows the assembler on nemo (memory: nemo-build-footguns) — ensure PATH excludes it for the build shell if the entry point compiles firmware.
- [ ] **Step 3: On completion,** md5 the produced BOOT.BIN, write `TMR146_REBUILD_DONE md5=<md5-12>` to the status file, append `A1B_CANDIDATE` to the ledger, commit -s + push. On build failure, diagnose from the log; if unresolvable in two attempts, report BLOCKED.

---

### Task 4: Pre-flash rail census on the candidate DCP (A2 kill gate)

**Files:**
- Read: `jupiter_byte_tmr146_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/system_top_routed.dcp` (or the Task-3 rebuild's equivalent path), `two_jup/dcp_rail_dump.tcl`, prior witness dumps referenced in ledger section for commit ebbf4eb
- Create: `two_jup/railcensus_146candidate.txt`
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: candidate identity from Task 2 (or 3).
- Produces: `A2_RAILCENSUS CLEAN|DEFECT` ledger line. CLEAN (or signature differs from witness defect) → Task 5 may flash. DEFECT (same re-hosting signature) → STOP Lane A, report BLOCKED with the census diff (a reseeded/rail-guarded rebuild is a new operator decision).

- [ ] **Step 1: Run the dump on a Vivado host.** Vivado is NOT on nemo (preflight); use a lab build host from HOSTS.md (mini2 / hdl-dev-2 10.0.0.11) or run inside the build dir's own environment:

```bash
vivado -mode batch -source two_jup/dcp_rail_dump.tcl \
  -tclargs <ROUTED_DCP> two_jup/railcensus_146candidate.txt
```
- [ ] **Step 2: Score against the named defect.** The ebbf4eb finding: the byte-plane rail/enable network re-hosted into the AXI addr decoder. In the dump, check (a) no `enb*`/`ce_out*`/`clk_enable*` net inside TxRxComposite has TYPE POWER/GROUND (const-folded); (b) the rail nets' driver cells live under the timing controller hierarchy, not under the AXI decoder hierarchy; (c) BUFGCE CE pins are VCC (matching the known-good `glitch_probe_skid3.txt` shape). Write the three checks and their pass/fail into the census file footer.
- [ ] **Step 3: Verdict per the pre-stated rule** (Produces block). Append `A2_RAILCENSUS <verdict>` + the three check results to the ledger; commit -s + push (`two_jup/railcensus_146candidate.txt` included — it is small text).

---

### Task 5: Flash 146 (A3 — first 146 flash of the campaign)

**Files:**
- Create: `two_jup/skidfix/flash_146_tmrfresh.sh` (clone of `flash_148_beatfix2.sh` retargeted)
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: Task 1 rollback image (`jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak`), candidate BOOT.BIN + md5-12 (Task 2/3), `A2_RAILCENSUS CLEAN`.
- Produces: 146 running the candidate image, verified; `A3_FLASH OK md5=<md5-12>` ledger line. On any gate failure: 146 restored to 433fd8dab393 via rollback, `A3_FLASH ROLLED_BACK reason=<...>` and Lane A ends pending operator direction.

- [ ] **Step 1: Write `flash_146_tmrfresh.sh`** by cloning `two_jup/skidfix/flash_148_beatfix2.sh` with these exact deltas: `A=10.0.0.146`; `BB=<candidate BOOT.BIN path>`; rollback image path = the Task-1 .bak; remove the 148-specific witness-register step (the tgen GPIO readback) — replace with a no-op comment; keep verbatim: md5 precondition arg, SSH_ASKPASS scp put, on-board md5 verify after copy, readback verify, sync+reboot, full bring-up via `bringup_r2r3.sh r3` with `GATE_DIR=A GATE_TRIES=8`, two-pass health gate fsync≥1100 AND wcnt≥1100, rollback-on-failure with witness read before rollback, NO retry.
- [ ] **Step 2: Dry-check the script:** `bash -n` clean; grep confirms `10.0.0.148` appears nowhere except comments; rollback path exists on disk.
- [ ] **Step 3: Stop the sentinel** (Global Constraints procedure) and verify both watchdogs' state is known (they will be killed/restarted by bring-up).
- [ ] **Step 4: Execute detached with a watcher:**

```bash
setsid nohup two_jup/skidfix/flash_146_tmrfresh.sh <candidate-md5-12> \
  > /tmp/flash146_tmrfresh.log 2>&1 < /dev/null & disown
```
Watcher waits on the script's terminal marker. Health-gate PASS → proceed. FAIL → the script rolls back itself; verify 146 is back on 433fd8dab393 by on-board md5 + bring-up, ledger `ROLLED_BACK`, STOP Lane A.
- [ ] **Step 5: Post-flash state record:** on-board md5 of the new BOOT.BIN, bring-up log tail, health-gate numbers → ledger; commit -s + push script + ledger. Restart sentinel.

---

### Task 6: Byte-source ladder verdict on new 146 (A4)

**Files:**
- Read/run: `two_jup/rom_air_comb_census.sh`, `two_jup/analyze_comb_census.py`, `two_jup/capture_r3.sh`, `two_jup/skidfix/ab_score.py`, wedge-aware scorer used in the 08-24 legs
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: Task 5 `A3_FLASH OK`.
- Produces: `A4_VERDICT FIXED|UNCHANGED|CHANGED` + numbers. FIXED → Task 9/10 proceed. UNCHANGED → run the A/B closure step (Step 5) then STOP for operator. CHANGED → STOP for operator (iterate-placement decision).

**Pre-stated verdict rule (copy to ledger BEFORE running leg 1):** ROM leg PRESENT (>1e5 events/s) → regression, immediate rollback flash + `A4_VERDICT REGRESSED`. Else: saturated-tun live-window PER CP95UL <1% → FIXED; PER in 9–12% → UNCHANGED; anything else → CHANGED. Denominator = live-window frames with drops counted; wedge-contaminated windows discarded before interpretation per the 08-24 discipline (delivery-health gate: idle_rx delta >500/s over 12 s before each leg).

- [ ] **Step 1: Sentinel OFF; delivery-health gate; ROM census leg** (60 s, `rom_air_comb_census.sh` with the fixed `sleep 0.05` sampler): expect ABSENT (<1e4/s).
- [ ] **Step 2: Idle-only byte-DMA leg:** 60 s stats delta on 148 exactly as the 08-24 leg (record S0/S1 stats lines; loss rate from crc_drop/idle_rx deltas). Baseline to beat: 9.33%.
- [ ] **Step 3: Saturated-tun leg:** `capture_r3.sh` ≥75k live-window frames, wedge-aware scoring, CP95 bound via the existing `accept_analyze.py` path. Baseline: 10.62% (8,332/78,461).
- [ ] **Step 4: Verdict per the pre-stated rule**; ledger with all commands/counts; commit -s + push; sentinel back ON.
- [ ] **Step 5 (UNCHANGED only): A/B closure.** Flash the banked 433fd8dab393 back (rollback path, not a new budget event), re-run the saturated-tun leg once, confirm ~10.6% reproduces → the discriminator is closed as board-level. Ledger + commit; STOP for operator.

---

### Task 7: lock_watchdog delivery criterion (Lane C, parallel-safe from start)

**Files:**
- Modify: `two_jup/lock_watchdog.sh`
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: nothing (runs any time the rig is free; coordinate the mutex).
- Produces: deployed watchdogs on both boards that self-recover the #48 wedge; positive-control PASS line; prerequisite for Task 8.

- [ ] **Step 1: Diagnose why 7 wedges escaped.** The repo `two_jup/lock_watchdog.sh` ALREADY contains a BYTE-PLANE WEDGE detector (0x1C0 frozen) and a HOST-WEDGE backstop (dma_rx_ok frozen). First diff deployed vs repo: `$D/anyssh.sh 10.0.0.148 'md5sum /root/lock_watchdog.sh'` vs `md5sum two_jup/lock_watchdog.sh`, and pull `/dev/shm/lock_watchdog.log` from 148 covering a wedge window (sentinel.log timestamps 09:52 give the window). Determine which branch failed: stale deployed copy, `DAEMON_CMD` unset (restart path skipped), 0x1C0 NOT frozen in this class (crc_drop advances → plausible), or `$DAEMON_LOG` stats-line format mismatch. Record the named cause in the ledger — do not patch blind.
- [ ] **Step 2: Patch `two_jup/lock_watchdog.sh`** per the named cause. If the cause is "0x1C0 advances while host delivery is dead", add an idle_rx-delta criterion to the HOST-WEDGE backstop (busybox ash, keying on the daemon stats line):

```sh
  # DELIVERY-WEDGE (2026-08-25, #48 class): idle_rx frozen across a window while
  # dpkt at rate => host DMA delivery dead though modem decodes. Restart daemon
  # (proven recovery), escalate to full re-arm if a restart doesn't move it.
  if [ "$locked" = 1 ] && pgrep -x qpsk_tun >/dev/null 2>&1 && [ -r "$DAEMON_LOG" ]; then
    irx=$(tail -1 "$DAEMON_LOG" 2>/dev/null | tr " " "\n" | awk -F= '$1=="idle_rx"{print $2+0}')
    if [ -n "${prev_irx:-}" ] && [ "$irx" = "$prev_irx" ] && [ "$irx" -gt 0 ] && [ "$dpkt" -ge "$PKT_MIN" ]; then
      log "DELIVERY-WEDGE (idle_rx frozen at $irx, dpkt=$dpkt)"
      if [ -n "$DAEMON_CMD" ]; then
        pkill -x qpsk_tun; sleep 2; ( eval "$DAEMON_CMD" ) >/dev/null 2>&1 &
        sleep "$HOLDOFF"
      else
        locked=0
      fi
    fi
    prev_irx=$irx
  fi
```
Adjust to the actual named cause (e.g. if the deployed copy is stale, deployment IS the fix; if `DAEMON_CMD` is unset by bring-up, fix `bringup_r2r3.sh`'s launch line to pass it — locate with `grep -n lock_watchdog two_jup/bringup_r2r3.sh two_jup/restore_known_good.sh`).
- [ ] **Step 3: Deploy to BOTH boards with isolated ssh calls** (four separate `anyssh.sh` invocations per board: pkill; scp-put via SSH_ASKPASS + chmod; nohup launch; `ps` verify).
- [ ] **Step 4: Positive control (planted fault).** Sentinel OFF. With the link healthy, freeze delivery deliberately on 148: `$D/anyssh.sh 10.0.0.148 'kill -STOP $(pgrep -x qpsk_tun)'`. Watchdog must log the DELIVERY-WEDGE branch and recover (restart clears SIGSTOP by replacing the process) within 2 poll windows (~20 s at PERIOD=5 + debounce). If it does not: `kill -CONT` manually, diagnose, repeat once. A watchdog that hasn't caught a planted fault is not trusted.
- [ ] **Step 5: Ledger (named cause + control result) + `git commit -s -m "C: lock_watchdog delivery-wedge criterion (named cause: <X>) + planted-fault control PASS" && git push`. Sentinel ON (until Task 8).**

---

### Task 8: Retire the nemo sentinel (C3)

**Files:**
- Modify: `/home/tcollins/modem-status/focus.txt` (banner update), `two_jup/SINGLES_CAMPAIGN.md`
- Preserve: `/home/tcollins/modem-status/sentinel.log` (wedge-interval dataset — copy to `two_jup/soak_notes/sentinel_wedge_intervals_20260825.log` and commit)

**Interfaces:**
- Consumes: Task 7 deployed + control PASS, then ≥2 h of link operation with zero UNRECOVERED wedges (sentinel.log shows only "ok" lines, or watchdog logs show self-recovery).

- [ ] **Step 1:** After the 2 h observation window (a background watcher checks `sentinel.log` tail hourly — reuse the hourly cron read), confirm the criterion held.
- [ ] **Step 2:** `touch /home/tcollins/modem-status/SENTINEL_STOP`; verify process exit within one cycle (`pgrep -f "[d]elivery_sentinel"` empty after ≤6 min); archive the log copy; update focus.txt banner ("sentinel retired, watchdog owns delivery"); refresh dashboard.
- [ ] **Step 3:** Ledger + commit -s + push.

---

### Task 9: BEATFIX back on 148 + reverse re-baseline (Lane B)

**Files:**
- Read: `jupiter_byte_beatfix2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN` (md5 measured today: `fe5bd8a4fe19…` — re-verify), `two_jup/skidfix/flash_148_beatfix2.sh`, ledger sections naming the validated BEATFIX image
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: **ORDERING GATE B2 — all capture-tap-dependent work complete first**: Task 6 (uses 148's capture path for IQ health gates) and Task 10 Step 1 (BER capture) MUST be done before this flash, OR the post-flash tap must pass `check_capture_health.py` before Task 10 runs. `A4_VERDICT FIXED` is NOT required — reverse re-baseline is valuable regardless.
- Produces: 148 on the validated BEATFIX image with fixctl=3; reverse PER re-baseline vs <1% CP95UL.

- [ ] **Step 1: Identify the VALIDATED image.** Grep the ledger/docs for the BEATFIX validation md5 (`grep -in "beatfix" two_jup/SINGLES_CAMPAIGN.md two_jup/*.md | grep -i -e md5 -e valid`). The validated recipe is the one from the on-air zero-error run (task #69/70 era). If the banked `fe5bd8a4fe19` BOOT.BIN matches that ledger md5 → flash candidate. If the ledger names a different (v3) md5 with no on-disk image → report BLOCKED with options (rebuild vs flash fe5bd8a4fe19 as the last validated) — operator picks.
- [ ] **Step 2: Flash under rails** using `flash_148_beatfix2.sh <md5-12>` unchanged (it already targets 148, banks e49c011b as rollback, and carries the full gate set). Sentinel OFF during; detached + watcher; rollback semantics as scripted, NO retry.
- [ ] **Step 3: Arm fixctl=3** per the validated recipe (write-only reg — verify by effect: the marker-shift error class absent over a 10-min observation, scored the same way as the validation run).
- [ ] **Step 4: Reverse re-baseline:** 3 independent runs × ≥75 k frames, reverse direction, wedge-aware scoring, drops in denominator, per-run + pooled CP95 via the same `accept_analyze.py` path as the 1.72% baseline. Pre-stated: <1% CP95UL per-run on all 3 → reverse gate MET; else record honestly.
- [ ] **Step 5: Ledger (commands/counts/denominators) + commit -s + push.**

---

### Task 10: Acceptance soak + BER tap-ladder (Lane D)

**Files:**
- Read/run: `two_jup/capture_r3.sh`, `k5_240/float_baseline_f1536.m`, `k5_240/gates_float_baseline_f1536.m`, tap-ladder scripts from the N3 budget work, `two_jup/check_capture_health.py`
- Modify: `two_jup/SINGLES_CAMPAIGN.md`, `/home/tcollins/modem-status/focus.txt`

**Interfaces:**
- Consumes: Task 6 FIXED (for the goal claim), Task 9 complete, Task 7 deployed (soak must run under the hardened watchdog).
- Produces: the campaign verdict — goal MET/NOT MET with full evidence; BER residual stage named or bounded.

- [ ] **Step 1 (may run BEFORE Task 9 flash — tap ordering): BER capture leg.** Health-gated IQ capture on the working tap; run `float_baseline_f1536` (expect 0 errors) and the fixed-point tap ladder on the same capture; name the first stage where hardware diverges from float (baseline residual 8.2e-5). Ledger the stage name + per-stage numbers.
- [ ] **Step 2: Both-direction acceptance soak.** ≥200 k frames per direction, ARQ OFF, simultaneous, wedge-aware; exact commands recorded. Pre-stated: goal MET iff BOTH directions CP95UL <1% with drops in denominator.
- [ ] **Step 3: Final report:** ledger closing section + focus.txt/dashboard update + commit -s + push. If NOT MET, the section states exactly which direction/number failed and the surviving hypothesis list.

---

## Self-review notes
- Spec coverage: A0→T1, A1→T2, A1-fail→T3, A2→T4, A3→T5, A4→T6, C1/C2→T7, C3→T8, B1–B4→T9, D1/D2→T10. Sentinel discipline + flash budget in Global Constraints. No gaps found.
- Interfaces consistent: rollback path (T1→T5), candidate md5 (T2/3→T4/5), verdict tokens (`A1_PROVENANCE`, `A2_RAILCENSUS`, `A3_FLASH`, `A4_VERDICT`) used identically across tasks.
- Placeholders: `<BOOTBIN_PATH>`, `<BUILD_ENTRYPOINT>`, `<ROUTED_DCP>` etc. are discovery outputs of an earlier step in the SAME task, each with the discovery command given — not deferred work.
