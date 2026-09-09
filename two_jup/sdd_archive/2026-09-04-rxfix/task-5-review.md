# Task 5 (T1) review -- fixctl slack-bit A/B legs on silicon

Read-only review against the pre-registration (happy-bubbling-owl.md, T1) and its
Verification line ("both legs credited (rate gate 900 f/s, no relaunch, window >= 150 s),
pre-registered prediction/falsifier quoted verbatim; checker gap_events + host PER +
comb_period_ms per leg"). No boards touched (no ssh), no files edited other than this one.

## 1. Legs credited (legrun's gate)

From the run dirs' `meta.txt` (`two_jup/rxfix/runs/20260904_093052_slack0_t1-control/`,
`.../20260904_094543_slack1_t1-slackon/`), confirmed directly (no `two_jup/comb/runs/`
tree exists for these legs -- the dashboard's glob pattern in the task brief is stale/
generic; the report's own paths are the real location and match the ledger and
RXFIX_STATE.md pointers):

- `capture_r3_exit=0` both legs
- `deliver_rate_gate_pass=1`, rates 1911 f/s (A) and 954 f/s (B), both >= 900
- `watchdog_relaunch_rx=0 watchdog_relaunch_peer=0` both legs
- `wedge_verdict=healthy` both legs, `leg_exit=0` both
- No re-run performed on either leg (single run dir each, `run.log` shows one pass)

**PASS**, exactly as reported.

## 2. fixctl write path

`capture_r3.log:29` on both legs: `LOOP_POKE on 10.0.0.148: 0x208=0x0` (leg A) /
`0x208=0x8` (leg B), fired on the `wedge verdict:` marker at line 28, i.e. before the
framelog rotate / traffic window. `peer_poke.log` on both legs: 146 write triggered on
the same marker, `write exit=0` one second later. `run.log` on both legs: `RESTORE 1/2`
(146), `RESTORE 2/2` (148), `RESTORE ISSUED on both boards (exit 0; UNVERIFIED -- 0x208
is write-only, no readback exists)`. All four log lines match the report's audit table
verbatim, including the honest "UNVERIFIED" qualifier (0x208 has no read path in
`TxRxCompo_ip_addr_decoder.v` -- confirmed `write_fixctl` only, no `read_fixctl`).

**PASS** -- write-before-window and restore-with-caveat both evidenced as claimed.

## 3. Scoring reproduced from raw data

Recomputed independently from the receiving board's (148) raw `frames.bin`
(48-byte `frame_rec`, `<QQIIIIIIII`, per `host_app_k5/qpsk_join.h`), gap method
(lost frames in the denominator), live-window/settle logic copied from
`two_jup/accept_analyze.py`, and lag-32 autocorrelation of the loss indicator on the
seq (host_seq) axis:

| | leg A (slack0) | leg B (slack1) | report |
|---|---|---|---|
| PER | 8.351 % (73,003/874,137) | 8.426 % (73,773/875,537) | 8.351 % / 8.426 % -- exact match |
| lag-32 autocorr | +0.3974 | +0.3231 | +0.397 / +0.323 -- exact match |
| live window | 717/722 s | 718/723 s | matches |
| loss-run bins {1,2,3-4,5-20} | 37,931/15,760/549/170 | 37,405/16,303/576/176 | exact match |

Also ran `two_jup/accept_analyze.py` directly on both `frames.bin` files: identical
PER/CP95UL/bins, POOLED PER 8.389 % (146,776/1,749,674).

Checker (s3h) numbers cross-checked against `s3h/score.json` in each run dir:
`tot_gap_events`/`emitted_frames` = 35,321/663,457 = 5.324 % (A) and 35,758/667,671 =
5.356 % (B) -- matches the report exactly; `garbage_pct` 5.8956 %/5.8870 %, `crc_fail_pct`
2.0230 %/2.0781 %, `int_32/int_33/int_other/lt30` = 1277/29/8896/25119 (A) and
1251/9/9543/24955 (B), `n_readings=49`, `window_s=540` both legs -- all exact matches.
`score.json` verdict is `UNINFORMATIVE` on both (25-27 negative `chk_lost_slots` deltas,
i.e. mid-window re-arm), which is exactly why the report scopes its use of the checker
to `gap_events/emitted`, `garbage %`, `crc_fail %` and `int_last`, not the headline
`seqbist_score.py` verdict -- consistent with its own stated caveat.

**PASS** -- every quoted number reproduces from the raw artifacts, not just from the
report's own derived files.

## 4. Verdict wording

The report and `RXFIX_STATE.md` T1 section both quote the falsifier verbatim
("falsifier: unchanged -> the deletion is upstream (Rate_Handle full edge or elsewhere)
and T2 proceeds on the sim's localisation") and read the null correctly: PER and lag-32
both moved in the wrong direction for confirmation (B slightly worse, not toward the
~0.06 % floor / lag-32 < 0.1), `COMB_LINE=present` unchanged, 32-frame intervals still in
both histograms. The scope claim -- enSlack gates only `push_on_full` of the
Preamble_Detector realignment FIFO -- checks out in RTL:
- `FixCtlDec.v:44` (build dir `jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_FixCtlDec.v`): `assign enSlack = (ctl & 32'd8) != 32'd0;` -- write-only, no readback port, matches.
- `Validate_Input_Push_Pop.v:136` (generic module, e.g. `jupiter_240k5_byte/rtl_sim/s1_rtl_txfix_F1/.../Validate_Input_Push_Pop.v` and the equivalent in the flashed build tree): `assign push_on_full_FIFO = Logical_Operator5_out1 & Compare_To_Constant1_y & ( ~ enSlack);  // 2026-08-29: slack arm` -- exact line, exact text, exact comment.
- Rate_Handle's `FIFO_block`/`Validate_Input_Push_Pop_block` instantiation (`TxRxCompo_ip_src_Rate_Handle.v`) carries no `enSlack` port -- confirmed, the port list has no such signal.

Minor, non-substantive: the report's intermediate hop citations `QPSK_Rx.v:243`/`:276`
(FixCtlDec -> Frequency_and_Time_Synchronizer wiring) don't line up at those exact line
numbers in every generated copy checked (line numbers shift across build variants); the
two load-bearing citations above (the bit's source and its one gated use) are exact.
Doesn't affect the conclusion -- the verdict does not overreach; "falsifier met" is the
correct, narrowly-scoped call and the report explicitly declines to over-generalize to
"one of the two guarded FIFOs."

**PASS**, with one cosmetic citation note.

## 5. Rig hand-back

`systemctl --user list-units` shows `sentinel-100708.service` and
`sentinelkeeper-100708.service` both `loaded active running`, matching the report's
close-out (`sentinel-100708` + `sentinelkeeper-100708` running). No `SENTINEL_STOP` or
`RIG_LOCK` files found. `~/modem-status/sentinel.log` tail shows a clean recovery/arm
sequence after close-out (`ARM GATE PASS`, `BRING-UP COMPLETE`, `recovery chain done`,
`ok rate=1160/s`) -- no stuck state, no error tail.

**PASS**.

## Overall verdict

**CONFIRMED.** All five checks pass. The credit gate, the fixctl write/restore audit
trail, the scored PER/lag-32/checker numbers (reproduced independently from raw
`frames.bin` and `score.json`, not just re-quoted), the RTL scope citations, and the rig
hand-back all check out exactly as the report and `RXFIX_STATE.md` T1 section state.
The one nit (two intermediate-hop line citations that don't resolve in every build
variant checked) does not touch the falsifier conclusion. T1's "falsifier met" verdict
and its handoff to T2 (pop-on-empty valid-density path, not push-on-full at either FIFO)
stand as reported.
