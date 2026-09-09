# Task 10 — W1 on silicon: flash 148 under rails, control legs, one witnessed air leg (rig driver)

Precondition: Task 9 DONE with a banked image `boot_known_good/BOOT.BIN.148.rxfixw1.<md5>` (routed WNS ≥ 0), `two_jup/rxfix/W1_REGMAP.md` and `two_jup/rxfix/w1_read.sh` (DRY-tested). Read task-9-report.md and W1_REGMAP.md first, then two_jup/RXFIX_STATE.md "Campaign brief" §2–§4 (predictions, falsifiers, the edge-counter gap), two_jup/seqbist/postflash_check.sh and two_jup/rxfix/slackleg_go.sh (the leg + in-window reader pattern to copy).

## Purpose
Answer on silicon, with pre-registered predictions, (a) whether the Rate_Handle ring on 148 sits at its EMPTY edge on the forward air leg and suppresses pops at the comb rate, and (b) which stage of the receiver valid chain first goes short — or whether none does while frames still die.

## Numbers that bind the predictions (derive, do not assume; from RXFIX_STATE §3)
- Drift = 12,333 × 2.575e-6 = 0.0318 entries/frame; at ~1,247 f/s that is ≈ 39.6 entries/s. So the ring reaches its edge within ~1 s of the arm and then sits PINNED there; each suppressed pop is one event per ≈ 25.3 ms → **≈ 395 pop_on_empty per 10 s** on the forward air leg (± 15 % for the ppm spread 2.5–2.6).
- Loopback (one clock): drift 0 → pop_on_empty delta **0** per 10 s after acquisition, occupancy constant.

## Step 0 — desk, DRY (before any board contact)
`two_jup/rxfix/w1leg_go.sh` (K=V env, DRY=1 default, ssh shim tests in tests/test_rxfix_rig_scripts.py): bring-up → arm → in-window reads every 10 s via w1_read.sh (freeze → read witA/witB + all census slots → unfreeze, one sweep per read, never faster than 10 s) → checker read (stage3h_reader.sh) → PER via capture_r3 (legrun_go.sh LEG=A DUR=600, RATE_GATE 900). Output: `two_jup/comb/runs/<ts>_w1_<leg>/` with meta.txt (legs table auto-renders), w1_reads.csv (t, occ, push_ptr, pop_ptr, push_on_full, pop_on_empty, census[6] — cumulative AND delta columns), verdict.txt.

## Step 1 — flash 148 under the full rails
keeper hold (`DRY=0 two_jup/comb/keeper_hold.sh hold`), then `two_jup/launch_rig_unit.sh flash148-w1 <abs>/two_jup/skidfix/txfix_flash_go.sh FLASH_MD5=<w1md5> FLASH_BAK=a1ff3c876d91 FLASH_TAG=rxfixw1 DRY=0` with watch_unit.sh; the chain verifies the on-board .bak, readback-verifies, runs the two-pass gate (ARM_OK fps ≥ 1120, capTAP golden) and auto-rolls-back on failure — never kill it mid-flash or mid-arm, no retry loop; one re-arm attempt allowed via arm148_mode1.sh (not ad hoc). Post-flash: `postflash_check.sh` pattern plus a W1 read at rest.

## Step 2 — positive controls and nulls for EVERY new tap (standing rule; this closes the edge-counter gap)
Run in 148 digital loopback (mode 1, arm148_mode1.sh, SINK=tgenrx as in seqbist_run.sh), three reads 10 s apart, then ONE re-arm and three more reads:
- **Census counters (6 stages): positive control** = each delta over 10 s equals the emitted-frame count × 12,333 within ±1 frame (frames from the checker / 0x104), all six equal to each other. Falsifier: any slot reading 0 or not advancing → that tap is dead; it is excluded from the air-leg verdict and reported.
- **Freeze path**: with freeze held for 10 s, every counter's delta is exactly 0; on release they advance. Proves the readout discipline the deltas rely on.
- **Edge counters — liveness positive control** = the ARM TRANSIENT. The ring starts empty at reset and pops are attempted before it fills, so pop_on_empty MUST read > 0 immediately after every arm (sim: 34 pop_on_empty and 17 push_on_full inside the first three frames of acquisition). Pre-registered: after the re-arm, pop_on_empty cumulative jumps by ≥ 1 relative to the pre-re-arm value (or restarts from a nonzero value if the counter clears on reset — W1_REGMAP says which), and push_on_full likewise ≥ 1 if acquisition overshoots as in sim (push_on_full = 0 after the arm is NOT a failure; only pop_on_empty is required). If pop_on_empty is 0 after two arms the counter is DEAD and the air leg cannot use it — report, do not proceed to Step 3 verdicts on that counter.
- **Edge counters — null**: in steady loopback (reads 2 and 3), pop_on_empty and push_on_full deltas are 0 and witA occupancy is constant (sel15 on 09-02 showed occupancy pinned at 1 in loopback; a constant 0–2 is expected).
- **witA occupancy — positive control** = it is nonzero and changes across the arm (acquisition) and is constant afterwards; the pointer fields advance mod 32 between reads (they always do while symbols flow).
- **Cross-check that no tap is stuck-at**: witA/witB and each census slot must differ between at least two of the reads in the set. Any word that never changes across all six reads is reported STUCK.
Ruling to apply: a zero on an edge counter is only ever reported as "did not increment in <window>" together with the occupancy word from the same read; "no holes" is claimed only if the counter also passed the arm-transient control in the same session.

## Step 3 — the forward air leg (146 TX → 148 RX), the measurement
bringup_r2r3.sh defaults (shipped LOs, RXQ=1, plain daemons), keeper hold kept, legrun_go.sh LEG=A DUR=600 with the W1 reader and stage3h checker in the window; RATE_GATE 900, no watchdog relaunch, window ≥ 150 s, one re-run on a wedge then UNINFORMATIVE.
Pre-registered (all [silicon] once read):
- P1: witA occupancy pinned at the EMPTY edge (0–1) on every in-window read; pop_on_empty delta ≈ 395 ± 60 per 10 s; push_on_full delta 0.
- P2 (corrected 14:45 from the Task 9 sim gate — the tiled −10 ppm W1 leg shows cSS = cRH = 2,614,900 with 21 pop_on_empty events, i.e. a suppressed pop is a skipped TIME slot, not a lost symbol): per 10 s, symbol-sync strobe delta = Rate_Handle-out delta EXACTLY, every downstream stage delta equal to it (the fixed pipeline offsets cPD ≈ −12,340 and cPC ≈ −40,400 seen in sim are constants, not per-event losses), and strobe delta = 12,333 × (TX frames in the window) ± 1 frame. I.e. the sim's prediction is that NO stage is short in valid count while pop_on_empty runs at ≈ 395 per 10 s.
- P2-alt (the deletion reading, what the DDRCAP census was taken to mean): some stage's delta is short by the pop_on_empty delta. Whichever of P2 / P2-alt holds is the finding; both are reported with the raw deltas.
- P3: checker gap events per 10 s ≈ 1–2 × pop_on_empty delta; capture_r3 PER within 8 ± 1 % with a lag-32 comb; comb_period_ms ≈ 25–26 ms.
Falsifiers (each one a finding that redirects the campaign, not a fix):
- F1: pop_on_empty delta ≈ 0 while occupancy is NOT pinned at 0 and frames still die at the comb rate → the hole is not at the ring; report the first stage whose census goes short.
- F2 (now the sim-EXPECTED outcome, P2): occupancy pinned at 0 AND pop_on_empty delta ≈ 395 AND every census delta equal → the suppressed pop removes nothing from the valid stream; if frames still die at the comb rate the death is a TIME-domain effect (a consumer that counts enb ticks rather than valids — the Preamble_Detector tick-delayed pop, or an epoch/timing path), not a symbol deletion. Report this as the localisation, with the checker's gap-event rate against the pop_on_empty rate.
- F3: all census deltas exact and pop_on_empty ≈ 0 with frames dying at the comb → the entire symbol-rate path is exonerated on silicon; the comb's origin is elsewhere.
- Any counter that failed its Step-2 control is excluded from P/F evaluation and the leg is labelled PARTIAL.

## Step 4 — hand back
Restore plain daemons (bringup_r2r3.sh), verify 148 daemon nakstat fingerprint = 4, release the hold, restart the sentinel (systemd unit), leave 148 on W1 (it contains F3 + SEQ-BIST + the checker; rollback a1ff3c876d91 banked and on-board) unless a gate failed, in which case the chain has rolled back — say which image is on the board at the end, from a readback.

## Rails
Every rig step a launch_rig_unit.sh unit with watch_unit.sh; never edit a script a live unit runs; polls ≥ 1 s; verify arms by effect (0x158/0x114/0x118/0x10C/0x208 are write-only); one re-run per wedge then UNINFORMATIVE; positive controls before nulls (Step 2 before Step 3, no exceptions); labels [silicon]/[sim]/[netlist]/[inferred]; HEARTBEAT task10 every ≤ 5 min including while parked on a unit; ledger lines `Task 10:`; commit -s + trailer `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`, commit implies push; results to files (run dir + two_jup/RXFIX_STATE.md "W1 on silicon" section); no subagents. Report: two_jup/sdd_archive/2026-09-04-rxfix/task-10-report.md (control table per tap, air-leg table with cumulative+delta, P/F verdicts each quoted verbatim, image on the board at the end). Return only status, commits, one-line summary, concerns.
