> Evidence ledger, moved verbatim from `two_jup/comb/WEDGE_TIMER_AUDIT.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# WEDGE_TIMER_AUDIT -- what fires at WAITED 508-560 s in every 600-s leg (RXFIX Task 32)

Desk audit, 2026-09-05 15:2x, archived logs + scripts only; **revised 2026-09-05 20:4x (fix round 1,
desk only)** and **2026-09-06 (fix round 2, desk only -- section 5's per-prediction
reading of the two check legs, section 9)** after the adversarial review -- labels and numbers
corrected (sections 0, 1.2, 2, 3.1,
4, 7, 9), the verdict unchanged, and the fix that has since landed recorded in section 6b. No board
was touched in either pass. Every claim is labelled **[code]** (read in the repo), **[log]** (read
in an archived run dir), or **[inferred]** (arithmetic on the two).

Line references of the form `capture_r3.sh:NNN` are to the PRE-fix file (commit 58df053, the
parent of the fix commit 21d0dd3); the fix moved them (PERF_T is now :164, the stall loop
:331-354, the post-rate read :356-366).

## 0. Verdict

**The "wedge" is the traffic generator's own deadline.** `capture_r3.sh` launches the UDP client as
`qpsk_perf -c ... -t $((DUR+140))` = **740 s** [code capture_r3.sh:162-164] and then waits out the
window in a loop whose counter `WAITED` advances **4 s per poll while each poll actually takes
4 s + one password-ssh round trip (~1.2-1.4 s)** [code capture_r3.sh:323-325; log iteration times
5.23-5.76 s]. The loop therefore needs ~780 s of wall clock to reach WAITED=584, the client stops
sending at ~712-714 s after CAP_START, `dma_rx_ok` (payload frames only) goes flat, and after three
empty polls the script prints `MID_CAPTURE_WEDGE after <WAITED>s`. The WAITED spread 508-560 is
entirely the ssh-RTT spread: in **wall clock the event sits at 729-739 s after CAP_START in all six
flagged legs**, and the last payload frame in every leg's frames.bin lands **-0.03..+0.98 s from
the predicted `-t 740` deadline, seven legs of seven** (including the "non-wedged" 091549; full-
precision table in 1.2 -- the first write of this audit said "+0.3..+1.7 s" because its T_end
column had been truncated to whole seconds). The link never stalled: the fabric deframer counter
0x104 kept advancing at 1245 f/s through the whole "wedge", and the receiver daemon's `idle_rx`
rose at exactly the frame rate -- the peer was sending idle frames because it had nothing to send.

This is a harness artefact, not a link event. Nothing "recovered": `deliver_rate_post` in every
meta.txt is a copy of the PRE-window health line (legrun_go.sh:94-95 both grep `health try`), so the
"recovered to 1023-1036 f/s" evidence in the brief is the pre-window number re-read.

**Status (20:4x):** the harness fix is applied (commit 21d0dd3, 16:06) and checked on two legs;
the deadline verdict was confirmed on silicon by Task 29 leg 3b before the fix went in. Section 6b.

## 1. The arithmetic

### 1.1 Sequence inside capture_r3.sh [code, pre-fix file 58df053]

| step | line | action | wall cost (RTT = one anyssh round trip) |
|---|---|---|---|
| 4 | 163-164 | `qpsk_perf -s` on RX board; `qpsk_perf -c $TUN -b 15M -l 1400 -t $((DUR+140))` on peer -> **T_perf** | 2 RTT |
| 4 | 166 | settle | 4 s |
| 5 | 176-177 | `crc_health` (sleep 6 inside) + `deliver_rate` (sleep 6 inside) | 12 s + 2 RTT |
| -- | 274-276 | SIGUSR2 rotate both boards, sleep 1, snap S1, sleep 2, snap S2 | 3 s + 4 RTT |
| 6 | 298-303 | Tap-A window: `CAP_START` ... `CAP_END` (0.15 s) | 1 RTT |
| 7 | 310 | `LEFT = DUR - 20` = 580 | -- |
| 7 | 322 | `PREV` read (1 ssh) -> **loop start** | 1 RTT |
| 7 | 323-339 | `while WAITED < LEFT+4: sleep 4; WAITED+=4; NOW=$(ssh grep dma_rx_ok)`; `<200` frames in a poll -> `STALL+=4`; `STALL>=12` -> `MID_WEDGE` | **146 polls x (4 s + RTT)** |
| 8-9 | 348-371 | SIGUSR1 flush, scp, meta, **`pkill -x qpsk_perf`** (the intended end of traffic) | -- |

From S1/S2 in `regs_pre.txt` (sleep 2 between them) the per-leg RTT is `S2 - S1 - 2` [log]. Working
back from S1: `T_perf = S1 - (4 + 12 + 1 + 5*RTT)` [inferred]; the client's deadline is
`T_end = T_perf + 740` [code qpsk_perf.c:166,170: `deadline = t0 + secs*1e9; for (...; now_ns() <
deadline; ...)`; on expiry it prints `PERF_CLI_DONE` and exits]. The `snap` timestamps are taken
ON THE BOARD (`t=$(date +%s.%N)` inside the ssh command, capture_r3.sh:65-66), so S1, S2,
CAP_START and the post snap are the RX board's CLOCK_REALTIME, the same clock that stamps
`t_real_ns` in its frames.bin [code]. The model's own uncertainty is about +/-1 RTT (S1 is
stamped mid-round-trip; the two qpsk_perf launches carry their own connect times), i.e. +/-1.0-1.4 s.

### 1.2 Per-leg table [log + inferred] -- full-precision epochs (fix round 1)

Wall clocks are nemo local (-04:00), printed to 0.01 s from the epoch values. `LAST_OK` is the
`t_real_ns` of the last `crc_ok==1` record in `cap/frames.bin` (struct frame_rec, qpsk_join.h:155).
`plateau` is the 5-s stats line in `cap/qpsk_tun.log` (qpsk_tun.c:2553 `if (now_s()-tlast >=
5.0)`) where `dma_rx_ok` goes flat and `idle_rx` starts rising. `det` = wall of the post-loop snap
(`regs_post.txt`) minus one RTT. Columns 5-10 recomputed from the epoch fields at full precision
(scratch script over regs_pre/regs_cap/regs_post/frames.bin; the first write had truncated T_end to
whole seconds and LAST_OK to 0.1 s, which manufactured the "+0.3..+1.7 s" residual).

| run (RX board) | RTT s | poll s (obs) | WAITED | T_end pred | **LAST_OK** | **LAST_OK - T_end** | LAST_OK - CAP_START | det - CAP_START | det - T_end | ok frames in last 5 s before LAST_OK | plateau line / total | live (accept.txt) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 064400 legB_rev_before2 (146) | 1.41 | 5.76 | 508 | 06:58:09.44 | 06:58:10.31 | **+0.87** | 711.9 | 733.8 | +22.8 | 5544 | 155/166 | -- |
| 075030 w1_air2 (148) | 1.28 | 5.54 | 532 | 08:04:44.87 | 08:04:45.66 | **+0.79** | 712.9 | 739.0 | +26.9 | 6223 | 155/163 | 721/721 |
| 084623 hostfix_on (148) | 1.18 | 5.23 | 560 | 09:00:43.32 | 09:00:43.35 | **+0.04** | 712.7 | 734.2 | +21.6 | 6222 | 155/161 | 721/721 |
| **091549 hostfix_off2 (148)** | **0.98** | ~4.98 | **none** | 09:30:02.77 | 09:30:02.74 | **-0.03** | 714.1 | loop ended 720.9 | +6.8 | 6201 | 154/158 | 722/721 |
| 105153 t19_witness (146) | 1.35 | 5.35 | 544 | 11:06:04.63 | 11:06:05.40 | **+0.77** | 712.3 | 729.8 | +18.3 | 5962 | 154/160 | 718/747 |
| 142322 t22_judge1 (146) | 1.39 | 5.35 | 544 | 14:37:33.12 | 14:37:34.11 | **+0.98** | 712.3 | 729.1 | +17.8 | 6130 | 154/160 | 719/740 |
| 143845 t22_judge2 (146) | 1.39 | 5.35 | 544 | 14:52:57.32 | 14:52:58.24 | **+0.92** | 712.2 | 730.0 | +18.7 | 6153 | 154/160 | 719/740 |

Silicon prediction test, added after the fact (not one of the seven; DUR=480 -> `-t 620`, section 4;
same columns):

| run (RX board) | RTT s | poll s (obs) | WAITED | T_end pred | **LAST_OK** | **LAST_OK - T_end** | LAST_OK - CAP_START | det - CAP_START | det - T_end | ok frames in last 5 s | plateau | live (accept.txt) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 153825 t29_judge3b (146) | 1.37 | ~5.4 | 456 | 15:50:35.07 | 15:50:35.96 | **+0.89** | 592.3 | 610.9 | +19.6 | -- | -- | 598/622 |

Reading the table:

* **Seven of seven** legs stop delivering payload within **-0.03..+0.98 s** of the predicted
  `-t 740` expiry (146-RX legs +0.77..+0.98, 148-RX legs -0.03..+0.79) -- inside the model's own
  +/-1-RTT uncertainty, i.e. consistent with zero. The payload rate in the final 5 s before the
  stop is the full 1100-1245 f/s -- a step, not a ramp. A link wedge ramps through CRC failures;
  a deadline does not. [log]
* In **wall clock** the watchdog fires 729-739 s after CAP_START in every wedged leg. The
  WAITED values 508/532/544/560 are `wall / (4+RTT) * 4` -- e.g. 729 s / 5.35 s = 136 polls =
  WAITED 544; 734 s / 5.76 s = 127 polls = WAITED 508; 734 s / 5.23 s = 140 polls = WAITED 560.
  **WAITED is not seconds.** [inferred, matches observed to +/-1 poll]
* Detection lag `det - T_end` = 17.8-26.9 s = 3 zero polls (+ up to one partial poll such as
  064400's "+72 frames in 4s") at 5.2-5.8 s per poll. [log]
* The **"non-wedged" 091549 is the same event**: its frames.bin stops at 09:30:02.74 (deadline
  09:30:02.77), its daemon log shows the identical plateau (line 154/158), and its capture_r3.log has
  three separate `!! delivery stalled 4s (+0 frames in 4s)` lines that never accumulated to 12 s
  because the RTT that leg was 0.98 s -> 146 polls x 4.98 s = 727 s -> the loop exited 6.8 s after
  the deadline. The flag's threshold is `146*(4+RTT) > ~710 + 3*(4+RTT)`, i.e. **RTT > ~0.97 s**;
  today's 146-side RTTs are 1.35-1.41 s, 148-side 0.98-1.33 s. [log + inferred]
* The `live 719/740` figures: 740 = frames.bin span (SIGUSR2 rotate at CAP_START-8.5 s to the
  SIGUSR1 flush after the post snap); 719 = T_end - rotate = 740 - 21. `accept_analyze.py` calls a
  capture wedged when the clean-rate collapses > 3 s before the end of the file
  (accept_analyze.py:87-99); on 148 legs the idle tail leaves no frames.bin records at all (148's
  idle frames all pass CRC), so the file ends at LAST_OK and the leg is NOT called wedged
  (721/721) -- consistent, and a second reason the flag looked direction-dependent. [code + log]

### 1.3 The link was alive throughout the "wedge" [log]

judge1 `cap/qpsk_tun.log`, 5-s stats lines 153-160 (RX board 146):

```
153 dma_rx_ok=908210 idle_rx=23927 crc_drop=19658 dma_tx=952884
154 dma_rx_ok=913473 idle_rx=24797 crc_drop=19752 dma_tx=959112   <- payload stops, idle begins
155 dma_rx_ok=913473 idle_rx=30947 crc_drop=19830 dma_tx=965340   (+6150 idle / 5 s = 1230 f/s)
156 dma_rx_ok=913473 idle_rx=37097 crc_drop=19905 dma_tx=971568
157 dma_rx_ok=913473 idle_rx=43234 crc_drop=19999 dma_tx=977796
```

`idle_rx` is incremented for a decoded frame with no payload (qpsk_tun.c:1933 `if (m == 0) {
st.idle_rx++; rx_q_delivered = now_s(); continue; }` -- idle frames count as delivery for the RXQ
watchdog, "H-6 fix v2") [code]. `idle_rx + dma_rx_ok + crc_drop` advances ~6228 per 5 s before and
after the plateau: same frame rate, different frame type. frames.bin agrees: 0x104 (`reg_packets`)
advanced from LAST_OK to the last record by 24,461 in 19.6 s on judge1 (1248 f/s), 25,194 in
20.2 s on judge2 (1247 f/s), 31,689 in 25.5 s on 064400 (1243 f/s), 23,486 to the post snap in
18.9 s on T19 (1246 f/s), 26,666 in 21.4 s on leg 3b (1246 f/s) [log]. No `re-arming` line appears
in any leg's tail (the only one per log is the bring-up `recovery #1`) [log]. Same signature in all
seven logs (section 1.2, `plateau` column).

## 2. Ranked candidates

1. **qpsk_perf client deadline `-t $((DUR+140))` expiring under a stall loop that under-counts wall
   time** -- CONFIRMED. What confirmed it, precisely [log + inferred unless marked]:
   * **Timing coincidence, 7/7 within 1 s:** LAST_OK - T_end = -0.03..+0.98 s on all seven 600-s
     legs (table 1.2), with the RTT slope in the predicted direction -- WAITED 560 at RTT 1.18 s,
     532 at 1.28 s, 544 at 1.35-1.39 s, 508 at 1.41 s, and no flag at all at 0.98 s (the threshold
     is RTT > ~0.97 s).
   * **The idle-at-frame-rate signature:** in every leg `dma_rx_ok` goes flat on one 5-s stats
     line while `idle_rx` starts rising by ~6150 per 5 s and 0x104 keeps advancing at 1243-1248 f/s
     (section 1.3) -- the receiver decoding a peer that has nothing to send, not a stalled link.
   * **The silicon prediction test (after this audit's first write):** Task 29 leg 3b (DUR=480,
     `-t 620`, RX=146, RTT 1.37 s) flagged `MID_CAPTURE_WEDGE after 456s` at ~15:50:50, inside the
     452-456 band pre-registered in section 4; LAST_OK - T_end = +0.89 s; 0x104 at 1246 f/s
     through the post snap (rstcs 0). [log run 153825_w1_t29_judge3b; ledger progress.md:1136,1147]
   * **The fix's check legs:** with the wall-clock loop and `-t DUR+400` (commit 21d0dd3) the
     same harness ran the full window with no stall line on t32b2 (DUR=120 fwd, `-t 520`: "stall
     watchdog done: wall 108s of 104, poll_read_failures=0", "post rate 1038 f/s", exit 0,
     gate_pass=1) and t30_pc (DUR=480 rev on 146, `-t 880`: "wall 468s of 464,
     poll_read_failures=0", "post rate 1016 f/s", exit 0, gate_pass=1); on both, `idle_rx` is
     constant on every post-health stats line (29/29, 104/104) and LAST_OK sits 2.8 s AFTER the
     post snap, i.e. payload flowed until step 9's pkill. The two "post rate" figures are quoted
     as the log lines they are: they carry the 6-s/5-s quantisation of section 6b and are **not**
     frame rates (the true rate on both legs is ~1,220-1,245 f/s from the per-line deltas). Both
     legs also carry accept_analyze's `[WEDGE truncated]` end-of-file label, which section 5's
     P-B reading now states. [log]
   * **NOT banked:** the direct on-board witness -- `/dev/shm/perf_cli.log` with `PERF_CLI_DONE
     ... dur=740.0` on the peer -- was not fetched for any of the seven 600-s legs (no run dir of
     2026-09-05 contains a perf_cli.log, 0 of 40; the only PERF_CLI_DONE read today is leg 3's
     `dur=59.7`, an at-arm leg, quoted in the ledger). The file is overwritten per leg, so only the
     last leg's instance ever survives; Q2 in section 7 remains open for that reason. The
     confirmation above rests on the timing, the signature and the prediction test, not on the
     client's own exit line. [log + inferred]
2. (none). Every other candidate below is ruled out by the same data.

## 3. Ruled out, and why

| candidate | why not |
|---|---|
| In-window readers (w1_read.sh, seqbist_read.py, RSSI read; w1leg_go.sh reader_bg) | Window is 48 x 10 s opened after the health gate: judge1 14:25:43 -> 14:33:36, tgen_mode restore 14:33:44; T_end 14:37:33. Every leg: reader closes 3 min 50 s - 4 min 25 s BEFORE the stop (T19 11:02:15 vs 11:06:04; judge2 14:49:07 vs 14:52:57; 075030 08:00:57 vs 08:04:44; 084623 08:56:55 vs 09:00:43; 091549 09:26:10 vs 09:30:02). The readers touch 0x208 (freeze), tgen ctrl 0x9D410000 (RMW bit3/bit5) and sysfs rssi -- none near 700 s. [log] |
| Fixed-size buffers in qpsk_tun.c | TXLOG ring 1,048,576 x 32 B wraps at 838 s ("a 600 s leg never wraps", qpsk_tun.c:678) and is a ring anyway; FAILHDR ring 65,536 x 32 B is a ring (2,097,184 B cap = header + full ring, no behavioural effect; brief already shows no correlation); framelog is an unbounded append to /dev/shm (43 MB at 740 s; no cap constant); stats every 5.0 s; RXQ no-progress 3.0 s / no-delivery 10.0 s watchdogs did not fire in any tail. No 5xx/6xx-second constant exists in the file (grep). [code] |
| Board lock_watchdog | Killed at step 3 on both boards (`wd stopped` x2 in every capture_r3.log); watchdog logs contain only STARTING/LOCKED lines. [log] |
| nemo periodic actors | `systemctl --user list-timers`: render-pipeline 5 min, stall-detector 5 min, pipeline-dash 30 min -- all run `two_jup/agents/*.py` renderers with no board contact; system timers (sysstat 10 min, chatdb-sync ~17 min, anacron, fwupd...) touch no board; `crontab -l`: none. delivery_sentinel.sh cycles at 10 + 290 s reading 148's log over ssh, exits on SENTINEL_STOP, and its only action is a full `bringup_r2r3.sh r3` -- which would restart the daemon (not observed: all daemon logs are one contiguous 158-166-line series). collect.sh (60 s) reads log tails only. Hold files were present during every leg (heartbeats `hold=yes`; keeper_hold.sh). No 540/600-s cadence anywhere. [code + local host state] |
| Carrier-reset storm | rstcs = 0 through the judge legs' windows and post snaps (judge1/judge2/3b: 0 at S1, S2, CAP_START, CAP_END, every frames.bin record and the post snap; T19: 0 at the post snap); the at-arm 12-s wedges (064010, 073935, 090214, 152645; WAITED=12) are a separate class and are excluded as the brief directs. **064400 is the exception -- see 3.1: rstcs 0 -> 1162 in-window, a real event on that leg, not the deadline.** [log] |
| Receiver-side self-recovery | There was nothing to recover from. `deliver_rate_post` == `deliver_rate_pre` by construction (see section 6, defect D2). [code] |
| Direction dependence | Both directions stop at T_perf+740; the 148 legs merely leave no crc-fail tail in frames.bin. [log] |

### 3.1 Observations in the same data that do NOT affect the verdict (fix round 1) [log + inferred]

* **064400 legB_rev_before2 (RX 146, baseline image 3378861d..., the pre-fix "before" leg): a real
  carrier-reset event in-window.** rstcs (0x150, frame_rec.reg_rstcs) is 0 at S1, S2, CAP_START,
  CAP_END and on every frames.bin record until **06:49:27.2 = CAP_START + 188.9 s** (framelog
  t = 197.2 s from the first record; record #245438), where it steps 0 -> 2 -> 25 -> 101 -> 165 -> 167
  over four seconds and then climbs steadily at ~1-5/s (4-48 per 10-s bin, median ~19) for the rest
  of the leg:
  **1154 at LAST_OK** (06:58:10.3), **1162 = 0x48A at the post snap**, whose `fx` (0x15C
  adc_forensic) also changed 0xC010180 -> 0xD010180 from the pre snaps. The CRC-fail rate had
  already stepped ~7 s earlier, from ~48/s (bins +150..+180 s: 467-485 fails per 10 s) to
  ~130-140/s from 06:49:20-21 (CAP_START + ~182 s) onward: fail share 3.96 % before the onset
  (9,726 / 245,438 records over 197 s) vs 11.94 % after (78,101 / 653,952 over 549 s), delivered
  1196 -> 1050 ok f/s. This is a link-quality change on that leg (the reverse leg on the old image,
  health "rev 96 %"), 522 s before its deadline, and it is unrelated to the deadline: LAST_OK -
  T_end = +0.87 s on 064400 as on the other six, and 0x104 ran at 1243 f/s after LAST_OK. The first
  write of this audit omitted it (it only read rstcs at the snaps of the judge legs). It does not
  change the verdict; it does belong to whoever owns the 146 reverse-leg residual (REV_RESIDUAL_20ms.md).
* **Post-snap rstcs bursts on T19 and t32b2, outside every window.** T19 (RX 146): rstcs 0 at the
  post snap (11:06:24.25), then 0 -> 4453 between 11:06:27.1 and the last frames.bin record
  11:06:32.3 (CAP_START + 734.1..739.2 s; that bin has 0 ok / 4115 fail records). t32b2 (RX 148,
  after the fix): 0 at the post snap (16:24:09.15), then 0 -> 535 between 16:24:12.0 and the last
  record 16:24:14.9. Both begin **2.9 s after the post snap**, which is when step 8's SIGUSR1
  flush reaches the PEER (post + RTT + 0.5 s + RTT, capture_r3.sh:348 pre-fix; the flush also dumps
  the 32-MiB txlog inline, `QPSK_TXLOG_USR1=1`) -- timing coincidence only, mechanism not
  verified from the desk. After LAST_OK, after the post snap, after the loop: no bearing on this
  verdict; noted for Task 35 (the peer's SIGUSR2 rotate class is the same shape). The other legs'
  frames.bin end 1.0-2.1 s after the post snap and cannot show it.

## 4. Consequence for Task 29 (DUR=480, LEG=B, RX=146) -- written before leg 3b, the first Task 29 leg that went live

Provenance, from the ledger and git (fix round 1): Task 29's prereg was written 15:24:54 and leg 3
launched 15:26:45 (progress.md:1117,1121); leg 3 wedged AT ARM at WAITED=12 (~15:29:33, the
at-arm class, never live) and was ledgered as WEDGED and SCORED-UNINFORMATIVE (progress.md:1123,
1125). This audit, including this section's 452-456 prediction, was committed at **15:33:06**
(commit 2591279, the same commit that carries those two ledger lines and the "Task 32: complete"
line progress.md:1126) -- i.e. AFTER leg 3 had launched, wedged and been ledgered, and BEFORE
**leg 3b**, launched 15:38:25 (progress.md:1131, committed 15:38:33), which is the first Task 29
leg whose traffic window opened (~15:40:45) and the only one the prediction could be tested on.
The earlier heading called this "pre-registered before its first live leg"; the precise statement
is: written before leg 3b, after leg 3. Leg 3b's flag came at ~15:50:50 (progress.md:1136,
committed 15:57:30).

Task 29 chose DUR=480 "traffic 460 s, below the 508-560 s wedge time". That premise is the WAITED
scale, not wall clock. Arithmetic for DUR=480 [inferred from the model above]:

* PERF_T = 620; T_end - CAP_START = 620 - 28.7 = **~591 s**; LAST_OK expected at CAP_START + ~592 s.
* LEFT = 460 -> the loop runs 116 polls; at the 146-side RTT of 1.35-1.41 s that is
  116 x 5.38 = **624 s** of wall clock -> the loop OUTLASTS the traffic by ~33 s.
* Detection at T_end + 18-23 s = CAP_START + 609-614 s -> poll 113-114 ->
  **`MID_CAPTURE_WEDGE after 452-456s`** (exit 3, legrun gate fail, wedge-truncated label,
  live ~ 599 s of ~620). If the RTT that hour is 1.15-1.30 s the flag does not reach 12 s but
  `!! delivery stalled 4s/8s` lines appear; only RTT <= ~0.95 s gives a clean log.
* **Prediction: Task 29's P1 ("no wedge in-window") FAILS for this benign reason on both legs,
  with LAST_OK within ~2 s of T_perf + 620.** Under the operative credit rule (live >= 300 s,
  rates >= 900 f/s, zero relaunches) the legs remain creditable, exactly as judge 1/2 were.
* DUR that avoids the flag with today's RTT and NO script change: the loop wall
  `((DUR-16)/4) x 5.4` must end before `DUR + 140 - 30.5`, i.e. **DUR <= ~380 s** (DUR=360:
  86 polls x 5.4 = 464 s < 469.5 s). Not recommended over the fix in section 6, but it is the
  zero-edit option.

**Outcome [log]:** leg 3b (RTT 1.37 s) flagged at **WAITED=456**, LAST_OK - CAP_START = 592.3 s,
LAST_OK - T_end = +0.89 s, det - T_end = +19.6 s, 0x104 at 1246 f/s to the post snap, rstcs 0 --
every number inside the band above. Leg 4 was not run (Task 29 stopped on its PER falsifier).

## 5. The ONE split test (pre-registered 15:33; NOT run as written -- superseded by section 6b)

**Test.** One 600-s reverse leg, byte-identical to judge1/judge2 (`w1leg_go.sh MODE=air LEG=B
BOARD=146 DUR=600 R4D=1 RSSI=1 EXP=9acbe2ebe1db FIXCTL_BASE=0x0`), with exactly one change: the
qpsk_perf deadline lengthened to cover the loop, `PERF_PAD=340` (-> `-t 940`) via the one-line
env knob in D1 below. Control arm = today's seven 600-s legs (deadline 740 s, LAST_OK at
T_perf+740 in 7/7). Cost: one leg (~16 min) after Task 29 releases the rig and the controller
applies D1.

**Predictions (all must hold).**
* P-A: capture_r3.log has ZERO `!! delivery stalled` lines and no `MID_CAPTURE_WEDGE`; the loop
  exits at WAITED=584 and the run ends `CAPTURE_R3_DONE` (exit 0), legrun gate PASS.
* P-B: frames.bin LAST_OK is within 5 s of the post-loop snap (payload flowing until step 9's
  `pkill -x qpsk_perf`); accept_analyze reports live == full span, no `[WEDGE truncated]`.
* P-C: the receiver daemon's `idle_rx` is CONSTANT from the first post-health stats line to the
  last stats line before the SIGUSR1 flush (delta = 0), while `dma_rx_ok` advances 6100-6230 per
  5-s line throughout.
* P-D: PER within the judge1/judge2 band (0.97-1.34 %) -- the "wedge" contributed nothing.

**Falsifiers.**
* F1: `MID_CAPTURE_WEDGE` still fires at WAITED 508-560 AND LAST_OK ~ T_perf + 740 -> something
  other than `-t` ends the traffic at 740 s; the deadline explanation is wrong.
* F2: a stall in which `reg_packets` (0x104 in frames.bin / snap) or `idle_rx` ALSO stops
  advancing -> a genuine link stall exists that today's artefact was masking. This would be a real
  finding and would re-open the timer hunt with the receiver, not the harness, as the suspect.

**What happened instead (fix round 1, corrected in fix round 2) [log]:** the controller applied a
different form of D1 (section 6b) and checked it on a 120-s forward leg (t32b2,
`20260905_161957_w1_t32b2`) and a 480-s reverse leg (t30_pc, `20260905_163044_w1_t30_pc`), not on a
600-s LEG=B leg with PERF_PAD=340. The fix-round-1 text said "on both check legs P-A, P-B and P-C
held as written"; **that is wrong for P-B, whose second clause failed on both legs, and P-A's WAITED
clause is untestable at DUR 120/480.** Per prediction, as the archive reads:

* **P-A -- held in the clauses that apply, one clause not testable.** Zero `!! delivery stalled`
  lines and no `MID_CAPTURE_WEDGE` in either `capture_r3.log`; both end `CAPTURE_R3_DONE` with
  `capture_r3_exit=0` and the legrun gate passed. The prediction's "the loop exits at WAITED=584" is
  a DUR=600 number and cannot be tested on these legs; what they show is the new wall-clock exit line,
  `stall watchdog done: wall 108s of 104` (t32b2) and `wall 468s of 464` (t30_pc), with
  `poll_read_failures=0` on both.
* **P-B -- clause 1 held, clause 2 FAILED on both legs.** Clause 1 ("frames.bin LAST_OK within 5 s of
  the post-loop snap"): LAST_OK = post snap **+2.82 s** (t32b2) and **+2.85 s** (t30_pc). Clause 2
  ("accept_analyze reports live == full span, no `[WEDGE truncated]`") failed twice: t30_pc's
  `accept.txt` reads `cap: live 486s/493s [WEDGE truncated]  PER=2.667% (15644/586601)` with
  `wedges during captures: 1` and `GATE ... NOT MET`; t32b2 has **no `accept.txt` in its run dir at
  all**, and the ledger entry for it (progress.md:1173) records `accept_analyze live 124 s / 129 s`
  and that "accept_analyze prints `[WEDGE truncated]` for a clean-rate drop in the last ~5 s of the
  file". Both are the end-of-file flush/quiesce artefact, not a link event -- the ledger verifies it
  on t32b2 against 0x104 (+145,548 over 116.4 s = 1,250 f/s) and rstcs 0 at every snap, and
  REV_RESIDUAL_20ms.md section 8 does the same census for t30_pc ("Every scorer prints it") -- but
  the prediction as written asked for the label's **absence**, and the label is present. P-B is
  therefore **not** met on either leg; the artefact means the failure does not overturn the verdict,
  and this document had quietly restated only clause 1.
* **P-C -- clause 1 held, clause 2 FAILED on t30_pc.** As pre-registered (l.265-267): `idle_rx`
  CONSTANT (delta = 0) **and** `dma_rx_ok` advancing **6,100-6,230 per 5-s line throughout**.
  Clause 1 held: `idle_rx` delta 0 on **29/29** post-health stats lines (t32b2) and **104/104**
  (t30_pc). Clause 2 held on t32b2 (6,207-6,228) and **failed on t30_pc: only 5 of its 102 steady
  post-health lines fall inside the predicted band; 97 are below it (min 5,963, max 6,112)**
  [log, `cap/qpsk_tun.log`]. The predicted band stands as written -- it is not re-cut to the
  measured one -- and the miss is stated, exactly as P-B's is. Neither miss overturns the verdict
  (the deadline mechanism does not depend on the delivered rate), but P-C is **not** met on t30_pc.
* **P-D -- not testable** on those legs (different DUR/direction; t30_pc's PER 2.667 % is the
  arm-lottery band leg 3b had already shown under the old harness, 2.825 %).

Neither F1 nor F2 fired anywhere: no `MID_CAPTURE_WEDGE` at all, and `0x104` / `idle_rx` never stop
advancing on either leg.

## 6. Script defects found at 15:33 (diffs PROPOSED then; see 6b for what was actually applied at 16:06)

**D1 -- capture_r3.sh: traffic must outlive the stall loop; WAITED must be seconds; a traffic end
must not be reported as a link wedge.**

```diff
--- a/two_jup/capture_r3.sh
+++ b/two_jup/capture_r3.sh
@@ -159,7 +159,12 @@
 # 4. saturating traffic: qpsk_perf UDP, peer -> target tun (server sinks on the
 #    target, client paces near the R3 ceiling). Runs long enough to cover the
 #    wedge-check re-arms + settle + the Tap window + DUR.
-PERF_T=$(( DUR + 140 ))
+# The stall loop below spends (LEFT/4+1) polls of 4 s + one ssh round trip (1.0-1.8 s measured)
+# each, i.e. up to ~1.45 x DUR of wall clock; a deadline of DUR+140 expired UNDER the loop on
+# every 600-s leg of 2026-09-05 and was reported as MID_CAPTURE_WEDGE (WEDGE_TIMER_AUDIT.md).
+# Size the client to outlive the loop for any RTT <= 2 s; step 9's pkill is what ends traffic.
+# PERF_PAD is the split-test knob (default reproduces the historical DUR+140 only if set to 140).
+PERF_T=$(( DUR + ${PERF_PAD:-$(( DUR / 2 + 140 ))} ))
@@ -319,11 +324,15 @@
 if [ $LEFT -gt 0 ]; then
   echo "  ${LEFT}s traffic remaining (stall watchdog: abort after ${STALL_MAX}s flatline) ..."
-  MID_WEDGE=0; STALL=0; WAITED=0
-  PREV=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null)
+  MID_WEDGE=0; TRAFFIC_ENDED=0; STALL=0; WAITED=0; T0=$(date +%s)
+  rdst(){ $W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -oE "(dma_rx_ok|idle_rx)=[0-9]*" | cut -d= -f2 | tr "\n" " "' 2>/dev/null; }
+  set -- $(rdst); PREV=${1:-0}; PREVI=${2:-0}
   while [ $WAITED -lt $((LEFT + 4)) ]; do
-    sleep 4; WAITED=$((WAITED + 4))
-    NOW=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null)
-    DFRAMES=$(( ${NOW:-0} - ${PREV:-0} )); PREV=$NOW
+    sleep 4; WAITED=$(( $(date +%s) - T0 ))          # wall-clock seconds, not poll count
+    set -- $(rdst); NOW=${1:-0}; NOWI=${2:-0}
+    DFRAMES=$(( NOW - PREV )); DIDLE=$(( NOWI - PREVI )); PREV=$NOW; PREVI=$NOWI
     if [ "$DFRAMES" -lt 200 ] 2>/dev/null; then
       STALL=$((STALL + 4))
-      echo "    !! delivery stalled ${STALL}s (+${DFRAMES} frames in 4s)"
-      if [ $STALL -ge $STALL_MAX ]; then MID_WEDGE=1; break; fi
+      echo "    !! delivery stalled ${STALL}s (+${DFRAMES} payload, +${DIDLE} idle frames this poll)"
+      # idle frames still arriving at the frame rate = the LINK is up and the PEER has nothing
+      # to send: the generator ended (harness fault), not a wedge.
+      if [ $STALL -ge $STALL_MAX ]; then
+        if [ "$DIDLE" -ge 200 ] 2>/dev/null; then TRAFFIC_ENDED=1; else MID_WEDGE=1; fi; break
+      fi
     else
       STALL=0
     fi
   done
   if [ "$MID_WEDGE" = 1 ]; then
     WEDGE_NOTE="MID_CAPTURE_WEDGE after ${WAITED}s (delivery flatlined ${STALL}s) -- NOT usable data"
     echo "CAPTURE_ABORTED_WEDGED: $WEDGE_NOTE"
+  elif [ "$TRAFFIC_ENDED" = 1 ]; then
+    WEDGE_NOTE="TRAFFIC_ENDED after ${WAITED}s (qpsk_perf deadline expired; link up, idle frames flowing) -- harness fault, data usable to this point"
+    echo "CAPTURE_TRAFFIC_ENDED: $WEDGE_NOTE"
   fi
 fi
```

(The `case "${WEDGE_NOTE:-}"` at the end should then map `TRAFFIC_ENDED*` to a distinct exit code,
e.g. 4, so legrun_go.sh can label rather than discard.)

**D2 -- legrun_go.sh: `deliver_rate_post` is not post.** Both `RATE_PRE` and `RATE_POST` grep
`health try` lines (legrun_go.sh:94-95), and capture_r3.sh emits those only in the PRE-window gate
(step 5). Every meta.txt today has pre == post (1036/1036, 1023/1023). Proposed: derive the post
rate from the last two 5-s stats lines of `cap/qpsk_tun.log` that precede the plateau, or from
frames.bin's final 10 s of `crc_ok` records:

```diff
--- a/two_jup/comb/legrun_go.sh
+++ b/two_jup/comb/legrun_go.sh
@@ -93,3 +93,9 @@
   RATE_PRE=$(grep -m1 "health try" "$OUT/capture_r3.log" | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
-  RATE_POST=$(grep "health try" "$OUT/capture_r3.log" | tail -1 | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
+  # POST must be measured AFTER the window. capture_r3.sh prints "health try" only in the
+  # pre-window gate, so the old grep returned the PRE number twice (WEDGE_TIMER_AUDIT.md sec 6).
+  # Use the receiver daemon's last two 5-s stats lines: delta dma_rx_ok / 5.
+  RATE_POST=$(grep "stats:" "$OUT/cap/qpsk_tun.log" 2>/dev/null | tail -2 \
+              | grep -oE "dma_rx_ok=[0-9]+" | cut -d= -f2 | paste -sd' ' \
+              | awk 'NF==2{printf "%d", ($2-$1)/5} NF!=2{print 0}')
```

Until D2 lands, no report may cite `deliver_rate_post` as evidence of post-event health.
(D2 has landed -- 6b -- but with a quantisation caveat of its own, also in 6b.)

## 6b. Fix applied (commit 21d0dd3, 2026-09-05 16:06, controller) and what remains [code + log]

**Applied, in `two_jup/capture_r3.sh` (now :161-164, :324-366) and `two_jup/comb/legrun_go.sh`
(:94-98):**

* `PERF_T=$(( DUR + 400 ))` (was DUR+140): a fixed pad instead of D1's `PERF_PAD` knob. The loop
  is wall-clock now (below), so it ends at ~LEFT+4 s plus one poll for any RTT, while the client
  runs to CAP_START + ~DUR+371 s: at DUR=600 the traffic outlives the loop by ~380 s regardless of
  RTT; step 9's `pkill -x qpsk_perf` is what ends it. **D1's first defect (traffic must outlive
  the loop): done.**
* `WAITED=$((NOW_T - T_LOOP0))` -- wall seconds since the loop started, not 4 x poll count; the
  flatline test is `DFRAMES < 50 * DT` over the real poll interval DT, and STALL accumulates DT.
  The exit line `stall watchdog done: wall ${WAITED}s of $((LEFT + 4)), poll_read_failures=N` is
  new. **D1's second defect (WAITED must be seconds): done.**
* A failed ssh read (`NOW` empty) is counted in `POLLFAIL`, printed as `?? delivery poll read
  failed (ssh) at ${WAITED}s -- not counted as a stall`, and skipped -- an addition beyond D1.
* Post-window rate, a real measurement: after the loop capture_r3.sh reads `dma_rx_ok` from the
  daemon's last stats line, sleeps 6 s, reads again and prints `post rate $(((P1-P0)/6)) f/s`;
  legrun_go.sh's `RATE_POST` now greps that line (0 if absent). **D2: done** -- `deliver_rate_post`
  is post-window from t32b2 onward (2076/1038 on t32b2, 1011/1016 on t30_pc; every earlier
  meta.txt still carries pre == post and must be read as such).
* NOT adopted from D1: the idle-frame discrimination (`TRAFFIC_ENDED` vs `MID_CAPTURE_WEDGE`) and
  the distinct exit code. With `-t DUR+400` the generator cannot expire under the loop, so the
  case it labelled no longer arises by construction; a client that dies early would still be
  reported as a wedge. Acceptable; noted.

**Check legs [log]:** `20260905_161957_w1_t32b2` (LEG=A fwd, RX 148, DUR=120, `-t 520`, RTT
0.86 s): `100s traffic remaining` -> `stall watchdog done: wall 108s of 104, poll_read_failures=0`
-> `post rate 1038 f/s (6 s dma_rx_ok delta after the traffic window)` -> `CAPTURE_R3_DONE`,
`capture_r3_exit=0`, meta `deliver_rate_pre=2076 deliver_rate_post=1038 deliver_rate_gate_pass=1`,
zero `!! delivery stalled` lines, LAST_OK 16:24:11.97 = post snap + 2.82 s, idle_rx delta 0 on
29/29 post-health stats lines. `20260905_163044_w1_t30_pc` (LEG=B rev, RX 146, DUR=480, `-t 880`):
`stall watchdog done: wall 468s of 464, poll_read_failures=0`, `post rate 1016 f/s`, DONE, exit 0,
`deliver_rate_pre=1011 deliver_rate_post=1016 deliver_rate_gate_pass=1`, zero stall lines, LAST_OK =
post snap + 2.85 s, idle_rx delta 0 on 104/104. (The pair.iq of t32b2 was DEGENERATE -- the IQ tap,
not the frame plane; irrelevant here.)

**What remains (known, NOT fixed):**

* **The pre-window `deliver_rate()` quantisation artefact** (capture_r3.sh:86-90 pre-fix, unchanged
  by 21d0dd3): it differences the daemon's `dma_rx_ok` from the LAST 5-s stats line across a 6-s
  sleep and divides by the 1-s-resolution wall delta, so the numerator is k x (one 5-s delta) with
  k in {1, 2} depending on where the 6-s window falls against the 5-s stats cadence, and the
  printed "rate" is 5/6 or 10/6 of the true rate. t32b2's health line `rate 2076 f/s` is
  2 x 6228 / 6 (true 6228 / 5 = 1245.6 f/s); every 995-1036 f/s health figure today is one line
  over 6 s (judge1 1036 = 6216/6 with per-line deltas 6209-6214, i.e. ~1243 f/s; leg 3b 1009 =
  6054/6, deltas 6053-6067, ~1212 f/s; 064400 995 = 5970/6 with deltas 5509-5995, ~1150 f/s).
  The >= 300 and >= 900 f/s gates still discriminate a live link from a flatline, but the
  numbers in `health try` and `deliver_rate_pre` are not frame rates and must not be quoted as
  such. [code + log]
* **The new post-rate read has the same quantisation** (it reads the same stats line over the
  same 6 s): t32b2 `post rate 1038` = 6228/6, t30_pc `1016` = 6096/6 -- both one line, true
  ~1220-1245 f/s. Direction-correct for the gate; not a rate. The D2 proposal above (delta of two
  consecutive stats lines / 5, or frames.bin's last 10 s of `crc_ok` records) would remove it.
* `deliver_rate_post` in every meta.txt written BEFORE 16:06 (all seven legs of table 1.2, leg 3b,
  and everything older) is still the pre-window copy; no report may cite those as post-window.
* Section 7's board queries: Q2 (the peer's `perf_cli.log`) was never run and the file has been
  overwritten by every leg since; Q1 now serves only to read 146's zone setting (section 7).

## 7. Post-Task-29 board queries (controller runs these after the rig is released; log reads
only, no register access; 1-s poll rule irrelevant since each is a single ssh)

Clock note first (corrected, fix round 1). The first write of this audit said "146's system clock
appears to run 5 h ahead (UTC)" because 146's `/dev/shm/watchdog.log` stamps `STARTING 19:25:02`
where 148's stamps `14:25:05` for the same bring-up [log judge1 cap/watchdog_rx.log vs
watchdog_peer.log]. **That is a rendering difference, not a clock offset.** What is actually true:

* 146's CLOCK_REALTIME agrees with nemo's and 148's to within ~1 s. Three independent witnesses
  [log + inferred]: (a) LAST_OK, stamped by 146's daemon (`t_real_ns`), lands -0.03..+0.98 s from a
  deadline computed from S1 (146's `date +%s.%N`, capture_r3.sh:65-66) and expiring on 148 -- on
  all four 146-RX legs and all three 148-RX legs alike (table 1.2); a 5-h offset on either board
  would put the residual at +/-18,000 s. (b) 146's snap epochs sit in nemo's timeline in order:
  judge1 CAP_START t=1788632741.83 = 14:25:41.83 EDT on 146, and nemo's reader logged its first
  board contact at 14:25:43 (reads/i1/run.log), the post snap 14:37:52.35 preceded nemo's meta.txt
  `ts=14:38:04`. (c) Ten nemo-stamped 0x104 readings (chk.jsonl `ts_wall`, stamped BEFORE the
  ~1.4-s ssh round trip at 1-s resolution, seqbist_read.py:136) map to frames.bin records stamped
  +1.43..+2.14 s later on 146's clock on judge1 and T19 -- the read latency, not an offset.
* The watchdog lines are written by `lock_watchdog.sh` with `date +%H:%M:%S` on each board
  (lock_watchdog.sh:21,64), i.e. the (correct) epoch rendered in that board's configured zone.
  146 renders 5 h ahead of 148/nemo (EDT, UTC-4) on every leg today -- 11:45:37 vs 06:45:41,
  15:53:33 vs 10:53:36, 19:25:02 vs 14:25:05, 19:40:25 vs 14:40:29, 20:40:03 vs 15:40:06,
  21:32:23 vs 16:32:26 -- so 146 renders local time as UTC+1 and 148 as EDT. (The 3-4 s between
  the two STARTING stamps is the bring-up order, 146 armed first.) Whether 146's rendering comes
  from /etc/localtime or from a TZ in the watchdog's environment cannot be read from the desk; Q1
  keeps that purpose only. Do NOT add
  5 h to anything: read 146's journal with `-o short-unix` (or `--utc`) and convert, never by
  offsetting the local rendering.

| # | board | command | expected if the deadline explanation is right |
|---|---|---|---|
| Q1 | both | `date -Is; date -u -Is; date +%s; cat /etc/timezone; ls -l /etc/localtime; uptime; journalctl --list-boots \| tail -2` | epoch within ~1 s of nemo's on both; 146's zone shows as UTC+1 (explains the watchdog rendering); no reboot since 06:44 (journal intact) |
| Q2 | TX/peer of the LAST completed leg | `cat /dev/shm/perf_cli.log; stat -c '%y' /dev/shm/perf_cli.log` | `PERF_CLI_DONE ... dur=<PERF_T>.0` for whatever leg ran last (the file is overwritten per leg; the seven 600-s legs' instances are gone). Post-fix legs end by pkill, so `dur` will be < PERF_T and the mtime ~ the leg's quiesce time -- still the direct witness that `-t` is the client's clock |
| Q3 | RX board | `tail -5 /dev/shm/perf_srv.log` | server summary, no error |
| Q4 | both | `journalctl --no-pager -o short-unix --since @<T-60> --until @<T+60>` and `dmesg -T` around T for T = the T_end epochs of table 1.2 (1788605889, 1788609885, 1788613243, 1788615003, 1788620765, 1788633453, 1788634377) | no axi-dmac / iio / adrv9002 / uio messages inside any window. Any DMA reset or timeout inside a window re-opens the hunt |
| Q5 | RX board | `grep -c 're-arming' /dev/shm/qpsk_tun.log` | 1 (the bring-up `recovery #1` only) -- the RXQ no-delivery watchdog must not fire on idle frames (qpsk_tun.c:1933) |

## 8. Files read

First write: `two_jup/capture_r3.sh` (393 lines, as of 58df053), `two_jup/comb/legrun_go.sh`,
`two_jup/rxfix/w1leg_go.sh`, `two_jup/rxfix/w1_read.sh`, `two_jup/seqbist/seqbist_read.py`,
`two_jup/accept_analyze.py`, `host_app_k5/qpsk_tun.c` (3830 lines; grep for constants, rings,
watchdogs, idle_rx), `host_app_k5/qpsk_perf.c` (client loop), `host_app_k5/qpsk_join.h`
(frame_rec), `~/modem-status/delivery_sentinel.sh`, `~/modem-status/collect.sh`,
`two_jup/comb/keeper_hold.sh`, `two_jup/sim_repro/sentinel_keeper.sh`; run dirs
`two_jup/comb/runs/20260905_{064010,064400,073935,075030,084623,090214,091549,105153,142322,143845}_*`
(capture_r3.log, run.log, reader.log, meta.txt, accept.txt, cap/{regs_pre,regs_cap,regs_post,
meta}.txt, cap/qpsk_tun.log, cap/frames.bin, reads/i*/run.log, rssi.jsonl, chk.jsonl); nemo
`systemctl --user list-timers`, `systemctl list-timers`, `crontab -l`, `systemctl --user list-units`.

Fix round 1 (20:xx, desk): `git show 21d0dd3` (capture_r3.sh, legrun_go.sh), `git show
58df053:two_jup/capture_r3.sh` (line refs), `git blame` of progress.md:1117-1148, `two_jup/lock_watchdog.sh`
(:21,64), `two_jup/seqbist/seqbist_read.py` (:136); run dirs `153825_w1_t29_judge3b`,
`161957_w1_t32b2`, `163044_w1_t30_pc` (capture_r3.log, meta.txt, cap/regs_*.txt, cap/frames.bin,
cap/qpsk_tun.log) and the seven legs' cap/regs_*.txt, cap/frames.bin, cap/watchdog_{rx,peer}.log,
chk.jsonl re-read at full precision. Scratch scripts (not banked): per-leg RTT from S1/S2, T_perf
back-computed, T_end = T_perf + PERF_T, LAST_OK / rstcs / 0x104 walk of frames.bin, nemo-vs-146
cross-clock via 0x104 matching.

## 9. Revision record

* 15:33 -- first write (commit 2591279): verdict, table 1.2 at whole-second T_end, section 4
  prediction, D1/D2 proposed.
* 16:06 -- harness fix applied by the controller (commit 21d0dd3) after leg 3b confirmed the
  prediction; not this document.
* 2026-09-06 -- fix round 2 (desk only), from the completeness critic: section 5's "on both check
  legs P-A, P-B and P-C held as written" replaced by a per-prediction reading of the two check legs'
  own files -- P-B's second clause FAILED on both (t30_pc `live 486s/493s [WEDGE truncated]`,
  `wedges during captures: 1`; t32b2 has no accept.txt, ledger:1173 records `live 124 s / 129 s` with
  the same label), P-A's WAITED=584 clause is untestable at DUR 120/480, P-C re-measured
  (29/29, 104/104; dma_rx_ok 5,963-6,228 per line, widening 6b's stated band). No number in
  sections 0-4 or 6b changed; the deadline verdict is untouched.
* 20:4x -- fix round 1, from the adversarial review: (1) section 4 heading
  reworded to what the ledger shows (written after leg 3, before leg 3b); (2) section 7's "5 h
  ahead" withdrawn -- rendering zone, not clock; (3) table 1.2 recomputed at full precision,
  residual -0.03..+0.98 s (was "+0.3..+1.7 s"); (4) 064400's in-window rstcs 0 -> 1162 event
  added (3.1), verdict unaffected; (5) section 2's "CONFIRMED" now says what confirmed it and that
  perf_cli.log was never banked; (6) section 6b records the applied fix, its check legs and the
  deliver_rate() 6-s/5-s quantisation that remains. Also noted en route: the post-snap rstcs
  bursts on T19/t32b2 (3.1, outside every window).
