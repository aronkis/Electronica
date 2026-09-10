> Evidence ledger, moved verbatim from `two_jup/comb/ATARM_CLASS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# ATARM_CLASS -- the at-arm collapse is the PEER's framelog rotate starving its transmitter (RXFIX Task 35)

Desk audit, 2026-09-05 evening, archived run dirs + repo only; fix round 2 (2026-09-05 late evening)
closes the reviewer's findings (sec 11) and **fix round 3 (2026-09-06) closes the completeness
critic's two blocking findings and four others (sec 12)** -- where sec 11 and sec 12 disagree, sec 12
is the current scoring. No board touched, no rig unit, no subagent. Labels: **[log]**
read from an archived run dir, **[code]** read in the repo, **[silicon]** a prior on-silicon fact cited
from the memory/state files, **[inferred]** arithmetic or reasoning on those.

## 0. Verdict

**The receiver does not die at its own rotate, at the snaps, at the Tap-A grab or at the W1 reader. It
dies at the frame after the PEER's `SIGUSR2`.** `capture_r3.sh:276` sends the rotate to the RX board
first and to the peer one password-ssh round trip later (0.82-1.72 s). On the peer, `framelog_service()`
runs `fclose()` + `fopen(...,"wb")` inline in the single event loop that also feeds the modulator
[code]. In every one of the five 2026-09-05 at-arm events the peer's TX log shows its first post-rotate
submit with the queue empty and a measured **6.0-18.5 ms** silence before it (`gap_ns`, inflight 0)
[log]; the RX framelog's last decoded frame is the one whose seq is that submit's seq minus one, in
5/5 on 09-05 and 3/3 on 09-03 (8/8, the seq join of sec 1.1) [log]. In every surviving leg the peer's
first post-rotate submit found the queue still busy or a gap <= 3.0 ms [log]. Across 09-03/04/05,
pooling both directions (each leg has two rotates, each with a far-end receiver) and counting the
five far-receiver outcomes whose witness cannot be read (sec 9.2's observability rule) as UNKNOWN:
**0/35 collapses when the rotate stall was <= 3 ms, 2/4 at 5.5-6.5 ms, 15/15 at >= 7 ms** [log]
(sec 4.1).

The rotate is **not** the only thing that stalls the transmit feed that long -- the first version of
this document said so and was wrong. The same daemon's `SIGUSR1` ring dump, which `capture_r3.sh:372`
sends to both boards at the pull (after the scored window), is the same inline file I/O in the same
loop and stalls the feed **4-17 ms** in a 25-s at-arm leg and **150-250 ms** in a 700-s leg, once per
board per leg [log+code, sec 4.2]. Scored on the far receiver it collapses it in **23 of 23** observable
cases at >= 13.9 ms -- idle keepalive feed and data feed alike, both boards, both directions -- and in
0/2 at 4.0-5.0 ms [log]. It is the only other >= 3 ms feed stall in any leg apart from four 3.8-6.5 ms
stalls of the RX board's idle feed during the Tap-A window. Inside the scored window the rotate is the
only such stall; that is why it is the at-arm class. Combined dose-response, both sources: **0/37 at
<= 5 ms, 2/4 at 5.5-6.5 ms, 38/38 at >= 7 ms.** The far end's carrier loop then resets at 170-940/s and
never re-locks until the byte double-tap re-arm; that persistence is the known "sync-but-CRC wedge" the
bring-up already re-arms for [silicon], its fabric mechanism is not established here ([inferred], sec 5).

The same thing happens in the other direction: the RX board's own rotate stalled *its* transmitter
7-62 ms in 14 legs and the peer's receiver (the reverse leg) collapsed at that instant in 9 of them --
every one whose far-side witness can be read (2 were already collapsed by the pre-rotate radio poke of
sec 5.1; 3 are unknown: the far side logged nothing at all in 180810 and 182006 and a single failed
slice in 191042, sec 9.2) -- unobserved by any gate because the health gate and the stall
watchdog only read the RX board [log].

Pre-computation expectation (written before the tables): I expected the RX board's *own* rotate to be
the closest preceding event, via the `fclose` flush stalling the RX pump long enough for the S2MM /
ByteRxFifo to overflow (Q2's framing). That is falsified below: the RX's own rotate precedes the onset
by 0.82-1.72 s (the peer's ssh RTT), the RX pump is not the path (sec 4.2 adds the direct test: the RX
host's own 211-238 ms `SIGUSR1` stall leaves its receiver decoding at 92-100 % in 5/5), and the collapse
is a transmit-side starvation seen at the far receiver.

## 1. Q1 -- timing, all five at-arm events

Sources and how each time was obtained (the brief's premises had to be corrected first):

* The daemon does **not** log the rotate and its `stats:` lines carry **no timestamp** [code
  `stats_dump()` qpsk_tun.c:248-281, `framelog_service()` :443-460; log cap/qpsk_tun.log]. The stats
  cadence is 5 s (`dma_tx` +6228 per line = 1245 f/s x 5 s) [log].
* **RX rotate** = `t_real_ns` of record 0 of the pulled `cap/frames.bin`: the rotate truncates the
  file, so its first record is the first frame scored after the rotate (within one 0.803 ms frame)
  [code framelog_service; qpsk_join.h:155 struct frame_rec].
* **Peer rotate** = the peer's `txlog_peer.bin` is also reset by the rotate (`instr_rotate_rings()`
  sets `txlog_head = 0` [code :769-774]), so its record 0 is the first frame the peer submitted after
  its rotate; that seq is looked up in the RX framelog (decoded `host_seq`, or extrapolated at 0.803 ms
  from the last decoded seq before it, always 1-4 frames away) -> the peer's rotate on the RX clock,
  accurate to ~1 ms and independent of the boards' wall clocks (which are only NTP-close, 146 runs UTC).
* S1/S2/CAP_START/CAP_END/POST from `regs_pre.txt`, `capture_r3.log`, `regs_post.txt` (board `date`).
* Reader: `reader.log` ("opening the reader window" is a log line only, no board access; the first
  board access is the "checker ctrl" RMW), `w1_read.log` first sweep, `chk.jsonl`, `rssi.jsonl` (nemo
  wall clock, 1 s resolution). Not present for the legB leg (no reader).
* **Onset** = first framelog record after which the next 50 records contain < 5 `crc_ok`, having seen
  >= 200 good records after the rotate. The last good record before it and the seq gap are in sec 1.1.

### 1.0 Event table (seconds relative to the RX collapse onset; negative = before)

| event | 064010 legB_rev_before1 (146 RX) | 073935 w1_air (148 RX) | 090214 w1_hostfix_off (148 RX) | 152645 w1_t29_judge3 (146 RX) | 161309 w1_t32b (148 RX) |
|---|---|---|---|---|---|
| onset wall (nemo local) | 06:42:20.911 | 07:41:56.242 | 09:05:27.013 | 15:28:56.978 | 16:15:19.631 |
| RX-board rotate (frames.bin rec 0) | **-0.884** | **-1.480** | **-1.719** | **-0.820** | **-1.387** |
| **PEER rotate, first post-rotate frame at the RX** [inferred, see note] | **+0.001** | **+0.002** | **+0.003** | **+0.003** | **+0.003** |
| peer's TX-feed gap before that frame (`gap_ns`, inflight 0) | 18.32 ms | 18.54 ms | 8.16 ms | 5.97 ms | 15.41 ms |
| reader window open (log line only) | -- | +0.757 | +0.987 | +0.022 | +0.368 |
| snap S1 (5 DRA reads) | +2.317 | +2.195 | +5.262 | +2.336 | +1.858 |
| snap S2 | +5.673 | +5.522 | +9.901 | +5.692 | +4.732 |
| CAP_START (Tap-A rx2 DMA, 4 M samples) | +7.039 | +6.837 | +12.522 | +7.086 | +5.616 |
| CAP_END | +7.185 | +6.964 | +12.653 | +7.238 | +5.744 |
| reader's first board access (checker-ctrl RMW) | -- | +9.757 | +14.987 | +9.022 | +8.368 |
| first W1 sweep (16-18 DRA reads) | -- | +9.757 | +16.987 | +9.022 | +8.368 |
| first seqbist read | -- | +11.757 | +24.987 | +10.022 | +9.368 |
| first RSSI read | -- | +13.757 | +27.987 | +12.022 | +10.368 |
| daemon "NO DELIVERY -- re-arming" (recovery #2) | ~+10 (10 s watchdog) | ~+10 | ~+10 | ~+10 | ~+10 |

Note on the PEER-rotate row: the peer's first post-rotate frame (seq S) was never decoded, so its RX
time is `t(S-1) + 0.803 ms`, one frame period after the last decoded record; the onset record is the
next record the daemon wrote. The "+0.001..+0.003 s" is therefore the seq join (k = 1) restated as
time, not an independently measured 1-3 ms spread. The measured facts are: last decoded seq = S-1 in
8/8 events, then a 9.6-33.7 ms `t_mono` delivery hole [log].

**Always before the onset and closest:** the peer's rotate. The RX's own rotate is 0.82-1.72 s earlier
(spread = the ssh round trip to the peer, S2-S1-2 = 0.87-2.64 s in these legs); everything else is
1.9-28 s *after*.

### 1.1 The onset frame by frame [log]

| leg | last good seq (RX) | peer's first post-rotate seq | onset record | first post-onset classes |
|---|---|---|---|---|
| 064010 | 26235 (rec 1089, rstcs 0) | 26236 | rec 1090 fail_class 1, then 4 more decodes to 26235, then class 4 (all-zero) | 8 all-zero slices, then class 1 (MAGIC garbage) at ~450 slices/s |
| 073935 | 26378 (rec 1848) | 26379 | rec 1849 class 4, all-zero header | 12 all-zero, then class 1 |
| 090214 | 32937 (rec 2168) | 32938 | rec 2169 class 4, rstcs 0->2 | 3 all-zero, then class 1 |
| 152645 | 26071 (rec 1060) | 26072 | rec 1061 class 4, rstcs 0->17 | 2 all-zero, then class 1 |
| 161309 | 24953 (rec 1733) | 24954 | rec 1734 class 4 | 6 all-zero, then class 1 |

The RX decodes the frame *before* the peer's first post-rotate submit and nothing after it. The first
post-onset slices are all-zero carve slots (`first_zero_off == 0`, header 00..00) -- "a slot the DMA never
filled" per qpsk_join.h -- i.e. the byte plane delivered nothing for a few slots at the instant the far
transmitter went silent, then class-1 garbage at ~450 slices/s for the rest of the run while `0x104`
kept counting at ~480/s and `rstcs` climbed at 170-940/s (frames.bin per-record `reg_rstcs`).
Post-onset failhdr census, all five: class 1 = 99.9 % (18911/18924, 16870/16885, 31268/31273,
18859/18868, 13602/13609), class 4 only in the first ~10 ms.

## 2. Q2 -- what the rotate does in the daemon [code]

`SIGUSR2` -> `on_usr2()` sets a flag (:224). `framelog_service()` (:443-460) is called at the top of
every event-loop iteration (`tun` loop :2976, echo :2534, ber :2603) and does, in order:
1. `instr_rotate_rings()` :769-774: `failhdr_head = 0; txlog_head = 0; memset(tx_log_cnt)` -- memory only.
2. `rxresync_rotate()` :1131-1138: five counter snapshots -- memory only.
3. `fclose(framelog_fp)` -- **flushes the 1 MiB stdio buffer** (`setvbuf(..., _IOFBF, 1u<<20)` at
   :3546 and :457) to /dev/shm synchronously; then `fopen(path, "wb")` -- **truncates the 2-3 MB
   pre-rotate file** (freeing its tmpfs pages) and reopens; `setvbuf` again.

That is all. It does **not** reopen failhdr/txlog (rings dumped only on SIGUSR1/exit), does not touch
the RX byte cursor, resync state, RXQ ring, DMA registers or any modem register, takes no mutex (the
daemon is single-threaded: zero `pthread` references). The one thing it does is put a file flush + a
file truncate inline into the only loop that feeds the TX DMA: `tx_send()` keeps at most `max_inflight`
transfers queued -- 2 in polled mode; in the IRQ mode these legs run (`irq mode: uio2/uio1`) the cap
is `TX_SLOTS` = 8 but the pacing loop (:3145-3160, one credit per `frame_period_s`) keeps the queue
1-2 deep in steady state (txlog `inflight` = 1-2 at every post-rotate submit in the surviving legs), so
the host-side cushion is ~0.8-1.6 ms of air; the fabric byte FIFO adds the rest (sec 4: <= 3 ms is
absorbed, >= 7 ms is fatal). The daemon runs `chrt -f 50` (bringup_r2r3.sh:174), so the stall
is in-kernel file I/O (tmpfs write of up to 1 MiB + truncate of ~3 MB) coinciding with the sshd/pkill
session on the same board, not user-space preemption. Its duration is bimodal in the logs: ~2 ms
(most rotates) or ~16-24 ms (11 rotates), once 61.6 ms [log]; why is not resolved here (the residual in
the 1 MiB buffer at the instant of the rotate is the obvious variable and is not recorded).

`gap_ns` semantics [code txgap_note :621-645]: at a submit that found the queue empty after the reap,
`gap = now - (prev_submit + prev_frames x frame_period)` -- an estimated lower bound on the air silence.
Recorded per submit in txlog (qpsk_join.h:190, `QPSK_GAP_NONE` when the queue was busy).

### 2.1 The other inline file I/O in the same loop: the `SIGUSR1` ring dump [code]

`SIGUSR1` -> `on_usr1()` sets `dump_req` (:223); the loop services it as `instr_usr1_dump()` (:776-787):
`framelog_flush()` (fflush of the 1 MiB buffer), `failhdr_dump()` (:367-390: `fopen("wb")` + up to
65,536 x 32 B = 2 MiB in two bulk `fwrite`s + `fclose`) and, **because every leg's daemons are launched
with `QPSK_TXLOG_USR1=1`** (legrun_go.sh:59 `SINK_ENV`), `txlog_dump()` (:689-720: `fopen("wb")` + up to
1 M x 32 B = 32 MiB + `fclose`). The code's own comment at :709 and :776-780 anticipated the problem:
"a per-record fwrite loop over 1 M records is ~100 ms of dead time, which at a 2-deep TX queue would
itself starve the fabric if this ever ran on SIGUSR1". It runs on SIGUSR1 in every leg: `capture_r3.sh:372`
sends it to the RX board and then to the peer (`sleep 0.5` in between) at step 8, after the stall
watchdog and the post-rate read, before the pulls. The archived `txlog.bin` is the daemon's exit dump
(it contains the SIGUSR1 stall itself and 10-40 s after it), so the SIGUSR1 txlog dump is not what the
archive is built from; the failhdr dump and the framelog flush are what the pull needs.

**The "NO DELIVERY -> re-arming" recovery** (`rx_pump_queued` :1830-1840, `rx_arm_queued()` :1625-1660)
writes only the RX AXI-DMAC (`DMAC_CONTROL` 0/1, `IRQ_MASK`, two submits) -- **no modem register**, so
it cannot cause the carrier-reset storm; it fires 10 s (`rx_q_deliv_wdog_s`) after delivery stopped,
i.e. ~10 s after the onset [code+log]. Effect, not cause. It does **not** fire during an idle tail:
`rx_q_delivered` is stamped on idle frames too (`qpsk_tun.c:1933` `if (m == 0) { st.idle_rx++;
rx_q_delivered = now_s(); continue; }   /* idle frame = delivery too (H-6 fix v2) */`), which is what
WEDGE_TIMER_AUDIT.md sec 1.3 reads off the same line and what its sec 7 Q5 pre-registers [code].
Counted: **exactly one** `re-arming` line in `cap/qpsk_tun.log` on each of the eight 600/480-s legs
(064400, 075030, 084623, 091549, 105153, 142322, 143845, 153825) despite 20-27 s idle tails, i.e. two
or more watchdog periods -- that one line is the bring-up `recovery #1`, not an in-leg event. The
**4-8 lines per leg** appear only on the at-arm legs (064010 4, 073935 4, 090214 8, 152645 4,
161309 4), where delivery genuinely stopped [log]. The first version of this document called that
range an idle-tail effect and was wrong.

## 3. Q3 -- the alternatives, ruled out by time

| candidate | earliest occurrence relative to onset (5 events) | verdict |
|---|---|---|
| Tap-A grab (rx2 DDR tap DMA, 65 ms at 61.44 Msps) | CAP_START +5.6 .. +12.5 s | after the onset in 5/5 -- out |
| snap S1 / S2 (5 DRA reads each through the shared address-select) | +1.9 .. +5.3 s / +4.7 .. +9.9 s | after in 5/5 -- out |
| reader's checker-ctrl RMW at window open | +8.4 .. +15.0 s (4/4 w1 legs; none in legB) | after -- out |
| W1 sweep / seqbist / RSSI reads | +8.4 .. +28 s | after -- out |
| DRA address-select collision with the daemon | the daemon does not use `direct_reg_access` at all: it mmaps the modem BAR, reads 5 status words inline (qpsk_tun.c:303-345) and writes one register in the RX path, the fslog pop token `0x1DC` (:1438/:1522/:1920) -- none of it on the rotate path; no harness DRA reader is active until +1.9 s | no collision path before the onset -- out |
| RX board's own rotate (RX-pump stall -> S2MM/ByteRxFifo overflow) | -0.82 .. -1.72 s; its measured TX-feed gap on the RX board was 2.3-2.4 ms in 4/5 (21.8 ms in judge3, which collapsed the *peer*, not the RX) | the RX kept decoding 1000-2100 frames after it, at 100 % -- not the trigger of the RX collapse |
| RX-side host stall at the peer's rotate instant | nothing runs on the RX board at that instant (the RX's ssh session ended ~1 s earlier, the next ssh is S1 at +1.9 s); and sec 4.2: the RX host's own 211-238 ms SIGUSR1 stall does not collapse its receiver (5/5) | out |
| ssh session alone | crc_health / deliver_rate / S1 / S2 / CAP each open a session on the RX board and none collapses anything; the rotate session is the only one that also triggers inline file I/O in the daemon | ssh is not sufficient |

## 4. Q4 -- why healthy arms survive: the peer's rotate stall was short

Peer's first post-rotate submit (`txlog_peer.bin` record 0), all 2026-09-05 full legs [log]:

| leg | peer TX-feed gap at its rotate | inflight after reap | RX outcome |
|---|---|---|---|
| 064010 legB_before1 | 18.32 ms | 0 | collapse |
| 073935 w1_air | 18.54 ms | 0 | collapse |
| 090214 hostfix_off | 8.16 ms | 0 | collapse |
| 152645 t29_judge3 | 5.97 ms | 0 | collapse |
| 161309 t32b | 15.41 ms | 0 | collapse |
| 084623 hostfix_on | 2.88 ms | 0 | survived |
| 163044 t30_pc | 3.00 ms | 0 | survived (RX side) |
| 064400, 075030, 091549, 105153, 142322, 143845, 153825, 161957 | none (queue still busy) | 1-2 | survived |

Nothing on the RX side separates the two groups: RX buffer occupancy is not instrumented on 148 (no
`-DQPSK_RXQ_STAT`), the RX board's own rotate gap is 1.5-2.6 ms in 11 of these 15 legs (2.44, 2.37,
2.42, 1.51, 1.90, 2.60, 2.30, 1.94, 2.34, 1.78, 1.60) and 21-22 ms in 4 (21.79, 21.27, 21.39, 21.83)
with no relation to the RX outcome, txgap on the RX board shows the usual 1.1-2.4 ms drain-boundary
gaps a few times per 5 s in collapsed and surviving legs alike, and the traffic (qpsk_perf 15 Mbit)
is identical. The health gate passed in all 15 (CRC 95-100 %, gate reading 988-2076). Those are
**not frame rates** and are not quoted as such here: `deliver_rate()` differences the daemon's last
5-s stats line across a 6-s sleep, so the printed number is k x (one 5-s delta) / 6 with k in {1, 2}
-- 988-1038 is one line over 6 s and the "2076" on the t32b pair is two; the true delivered rate, measured from the
per-line `dma_rx_ok` deltas, varies leg to leg and is NOT uniformly high: 064400 runs at a median
1,104 f/s (min 1,085, max 1,204; 107 of 148 lines below 1,190) and 105153 at a median 1,188, while
the healthiest legs reach 1,246 -- so the range across the 15 is about **1,085-1,246 f/s**, and
WEDGE_TIMER_AUDIT.md sec 6b's reading of 064400 (~1,150 f/s) is consistent with it [code + log]. The one variable that predicts the outcome is the length of the transmit-feed silence
the far end's rotate produced.

### 4.1 Dose-response of the rotate stall, both days, both directions [log]

Every full capture_r3 leg of 2026-09-03/04/05 with a txlog on both sides (**32 legs, 64 rotate events**;
the first version of this document and its review both said 33 -- sec 9 has 32 rows). Each rotate
stalls the rotating board's TX and is scored on the OTHER board's receiver. The peer's receiver is
scored from `frames_peer.bin`: `reg_rstcs` of its first post-rotate record and its slope over the next
2 s, back-extrapolated to the storm onset -- **only where the far-side witness satisfies the
observability rule of sec 9.2**. Five outcomes are **UNKNOWN** under it. In 180810 (RX-rotate stall
21.03 ms), 182006 (16.60 ms) and 064010 (2.44 ms) `frames_peer.bin` is 0 bytes and `failhdr_peer.bin`
is a valid dump with `n_records = 0, total = 0` -- the 148 side scored zero frames in the whole window
(in the same-configuration leg 064400 the 148 side logged 55,855 frames / 59,951 failhdr records), so
"148 logged no failures" is vacuous there, not a survival. In 191042 (7.32 ms) and 073935 (2.42 ms)
`frames_peer.bin` holds **one** 48-B record and `failhdr_peer.bin` reports `total = 1`: the 146 side
logged a single failed slice across the whole post-rotate window and nothing else, which is the same
evidential state, not a survival (sec 9.2). The first version of this document scored those two
"healthy (rstcs0 = 0, no storm)" off that one record; that is withdrawn. "Pre-collapsed" = the far
receiver was already in a storm before the rotate in question (excluded from the ratio; 4 of the 5 are the
radio-poke legs of sec 5.1). Full per-leg table: sec 9.

| rotate stall (`gap_ns` at first post-rotate submit) | far receiver collapses | unknown | excluded (already collapsed) |
|---|---|---|---|
| queue still busy, or <= 3.0 ms | **0 / 35** | 2 (064010 2.44, 073935 2.42) | 3 |
| 5.5 - 6.5 ms (5.51 / 5.97 / 6.35 / 6.47) | **2 / 4** (5.97, 6.35 collapse; 5.51, 6.47 survive) | 0 | 0 |
| >= 7 ms (7.3 .. 61.6) | **15 / 15** (one of the 15, the 61.6 ms case, placed by rstcs back-extrapolation without a seq join) | 3 (180810 21.03, 182006 16.60, 191042 7.32) | 2 |

**Every observable >= 7 ms rotate stall collapsed the far receiver: 15 / 15, no exception.** The first
version reported 15 / 16 and named 7.32 ms (191042, 148's TX -> 146) as the one non-collapse and the
lowest dose in the band; that survival call rested on a single 48-B record and is withdrawn (sec 9.2),
so the band has no non-collapse and no lowest-observed-dose survivor. The lowest dose that is
*observed* to be survivable is now the 6.47 ms case in the band above. The first version's paragraph
about "either the hazard is probabilistic near 20 ms (~80 %) or idle-frame streams are more robust"
rested on the two unknown 16.6-21.0 ms outcomes and is withdrawn; sec 4.2 answers the idle-vs-data
question directly (idle-feed silences are just as fatal).

Mid-window control: between the rotate and the step-8 `SIGUSR1` there is **no** peer TX-feed gap
>= 3 ms in any of the 32 legs (~20 M submits) [log, `midwindow_gaps.py` / `review35_repro2.py`]; on the
RX board's own (idle) feed the only ones are four 3.8-6.5 ms stalls inside the Tap-A window (sec 4.2).
The bring-up's own txgap lines never exceed 2.4 ms in any 5-s window outside those events. Inside the
scored window the rotate is the only >= 3 ms transmit silence; outside it there is exactly one more per
board per leg, the `SIGUSR1` dump, and it is the subject of the next section.

### 4.2 The second dose: the step-8 `SIGUSR1` ring dump, 4-246 ms, once per board per leg [log+code]

The review found a 150-250 ms TX-feed silence in every leg's txlog on both boards (`gap_ns` with
inflight 0, then the same 0->7 catch-up burst), skipped by `midwindow_gaps.py` as "after traffic end".
Located [log, `usr1_gap.py` / `usr1_table.py`, evidence in t35_evidence/]:

* It is `capture_r3.sh` step 8: the RX board's gap record is 0.5-1.3 s before the peer's (the
  `pkill -USR1 ... ; sleep 0.5` loop, RX first) and both are 10-40 s (typically 13-14 s) before the exit dump that ends the
  txlog (pair.iq / frames.bin / frames_peer.bin pulls + quiesce), in all 32 legs. The RX framelog's last
  record precedes the RX board's gap record by exactly the gap length (e.g. 224.6 ms gap, last record
  -0.233 s; 235.2 / -0.249; 233.9 / -0.242; 184.0 / -0.204): the `framelog_flush()` at the top of
  `instr_usr1_dump()` is the last thing written before the stall, as sec 2.1 predicts.
* Its length scales with the ring content the dump writes: 4-17 ms in the at-arm legs (25-30 s of txlog
  ~1 MB), 29-36 ms at 55-125 s (090214, 161957), 147-152 ms at 480 s (163044), 172-246 ms in the 600-s
  legs. On the RX board the feed is idle keepalives before and after (repeated seq -- `tx_seq` is not
  incremented for idles, qpsk_tun.c:3172-3190); on the peer it is data before and after when the
  traffic was still live at the dump (the at-arm legs, 180810, 183520, the 09-03/04 148-RX legs 191410,
  192933, 165420, 201814, and the post-Task-32 legs 161957, 163044) and idle when the -t 740 deadline had
  already stopped it 20-27 s earlier (the 09-05 morning/afternoon legs, Task 32's deadline artefact).
* Timing of the receiver's response (50-ms bins, t = 0 at the first post-stall submit): rstcs is flat
  through the 3 s before, the framelog logs nothing during the silence (the delivery hole), and the
  first post-stall bin already carries 4-67 resets, climbing at 170-300/s (148) or 790-930/s (146) from
  then on for as long as the framelog extends (3-12 s) -- the same shape as the rotate onsets of sec
  1.1. In 105153 the 146 receiver's counter starts moving in the last 150 ms of the silence (2, 4, 18)
  and jumps at the resumption (67). Under data traffic the decode stops at the START of the silence
  (163044: 52/53 crc_ok in the bin before, 0/14 in the bin the silence begins in) and the storm starts
  at its END.

Far-receiver outcome of every >= 3 ms post-rotate feed stall other than the rotate (both boards; the
RX board's stall is scored on `frames_peer.bin` via the rotate seq join, the peer's on `frames.bin`;
per-event table in sec 9.1):

| stall length | feed | far receiver collapses | not scorable |
|---|---|---|---|
| 4.0 ms (231005 SIGUSR1) and 5.0 ms (165420 Tap-A window), 148's idle feed -> 146 | idle | **0 / 2** | 3.8 and 6.5 ms Tap-A stalls: far receiver already collapsed |
| 13.9 ms (161309 SIGUSR1, 148 idle -> 146) | idle | **1 / 1** | the 7-17 ms SIGUSR1 stalls of the other at-arm legs: far receiver already collapsed (12), unobservable (2), no records (1) |
| 34.3 / 35.7 ms (161957, both directions) | data / idle | **2 / 2** | 28.8 / 29.7 ms (090214): both already collapsed |
| 147-246 ms (all 600-s legs, 153825, 163044) | idle x 15, data x 5 | **20 / 20** | 11 unobservable (framelog ends before the stall), 8 already collapsed, 2 no records, 1 confounded (180810: 146 had stopped decoding 21 s earlier with rstcs flat; the storm began at 148's stall) |

**23 / 23 at >= 13.9 ms, 0 / 2 at <= 5 ms.** Idle-feed silences (17/17) and data-feed silences (6/6)
collapse the far receiver alike; 148's receiver (11/11) and 146's (12/12) alike. The question the review
raised -- whether the post-gap content or something concurrent on the RX host is part of the trigger --
is answered: neither. The review's "3 of 12 storm, 6/6 un-poked 146-RX legs survive" was a scoring
artefact, in two different ways. In **five** of the six legs (064400, 142322, 143845, 153825, 175236)
the 146 framelog ENDS 1.56-2.59 s BEFORE the peer's stall (it ends at 146's own `SIGUSR1` flush and, at
16-40 idle-failure records/s, the 1 MiB stdio buffer never refills before the pull), so the "flat
rstcs" it read is pre-stall. The sixth, **105153, is the opposite case and the first version of this
document wrongly put it in that list**: its `cap/frames.bin` does extend past the peer's stall and it
carries `reg_rstcs` **0 -> 4,453 over its last 5.15 s** [log, re-measured], i.e. the 146 receiver
collapsed outright -- which is what sec 9.1's row for it already scored (+4402 over 5.0 s, 880/s) and
what the bullet above describes frame by frame. Either way the review's "6/6 survive" fails. The
witness that does extend past the stall in those legs is `frames_peer.bin` (148 in a storm logs ~5,000
records/s and refills its buffer every ~4 s), and it shows 148 collapsing at 146's stall in 5/5
(175236, 064400, 105153, 142322, 153825) with 143845 already collapsed by its rotate.

Two more things this stall shows:

* **The RX host's own stall does not collapse its own receiver.** In the 148-RX legs the 148 receiver
  went through its own 211-238 ms `SIGUSR1` stall and kept decoding at 92-100 % crc_ok (58-63 per
  50-ms bin) for the 0.5 s until the PEER's stall, then died at the peer's stall in 5/5 (191410, 192933,
  165420, 201814, 161957 at 35.7 ms); the 146 receiver in 184803 and 105153 likewise held rstcs flat
  through its own stall until 148's. (In 105153 the 146 host's delivery did fail after its own stall --
  failure records at ~620/s with rstcs still 0 -- a delivery-plane effect, not the fabric storm; the
  storm came 0.5 s later at 148's stall.) This is the direct test of the pre-computation expectation
  and of Q2's RX-pump framing: a 200 ms RX-side host stall is survivable; a 14 ms TX-side one is not.
* **Every 600-s leg has ended with BOTH receivers collapsed at the pull**, invisible to every gate
  (the post rate is read before step 8, the quiesce follows the pulls). Harmless for the archived
  window; relevant for `capture_r3.sh -k` (keep link up), which would hand back a double-collapsed
  link, and for the failhdr/txlog tails (the last 10-40 s of every txlog are a storm).

## 5. Ranked mechanism

1. **[log] Any transmit-feed silence of >= ~7 ms collapses the far receiver; inside the scored window
   the only such silence is the peer's rotate.** The harness rotates the peer's daemon 0.82-1.72 s after
   the RX's; the peer's rotate stalls its TX feed 6-19 ms (5/5 collapses) and the RX receiver's last
   decoded frame is the one before the peer's first post-rotate submit (8/8 by seq join). [code] The
   stall is `fclose` (<= 1 MiB flush) + `fopen("wb")` (truncate of a 2-3 MB tmpfs file) executed inline
   in the single loop that paces `tx_send()`, with 1-2 frames (0.8-1.6 ms) of air queued. The same loop's
   `SIGUSR1` ring dump (2.1) is the same defect outside the window and reproduces the collapse 23/23.
2. **[silicon, cited] A transmit-feed underrun makes the modulator free-run all-zero filler frames at
   line rate** (memory: TGEN instrument facts, 2026-08-18) **and "filler (all-zero) frames ... break OTA
   sync"** (memory: SEQ-BIST facts, 2026-09-04). Those facts were measured with 50 % filler streams and
   on underrun; their extrapolation to a 6-19 ms burst is now supported in-archive by sec 4.2 (13.9 ms
   to 246 ms bursts, 23/23) and by the 5.5-6.5 ms band (2/4). [log] The far receiver's `rstcs` (0x150)
   starts climbing at the resumption and `0x104` drops from 1245/s to ~480/s.
3. **[inferred] The far receiver does not re-lock when frames resume, data or idle**: after the rotate
   stalls (data resumes) and after the 150-250 ms `SIGUSR1` stalls (idle keepalives resume in 15 of the
   20 cases, data in 5) the storm runs for as long as any framelog extends and, in the at-arm legs, until
   the byte double-tap re-arm (0x000/0x158/0x118/0x114 + TX 0x418/0x458/0x044 + 0x110) -- the same
   "sync-but-CRC wedge" `capture_r3.sh:rearm_byte()` documents as clearable by that sequence and that
   the ROM arm gate re-arms for [silicon, capture_r3.sh comments; RXFIX_STATE.md "arm lottery"]. The
   fabric state that latches (carrier loop / Peak_Search / deframer) is NOT identified here and is the
   open question the rig A/B does not need answered to remove the trigger.
4. **[inferred] The dose threshold (<= 5 ms safe 0/37, ~6 ms 50 %, >= 7 ms 38/38) is the fabric TX byte
   FIFO depth plus the 1-2 queued host frames**, i.e. roughly 6-8 air frames of cover. Not measured
   directly; the forward-PER note already places the ByteWordBuffer at 16 words ("~16-28 us cover")
   for the *intra*-transfer path, so the inter-transfer cover measured here is a different, larger
   buffer (the DMA-side FIFO) [inferred]. Above the threshold the hazard does not fall off with length
   (13.9 ms .. 246 ms all fatal); no upper bound was observed.

### 5.1 The pre-rotate class is the radio poke: a second natural experiment [log+code]

Five of the 64 rotate-side observations had the far receiver already in a storm before the rotate. The
first version said "nothing the harness does on the far board at that time is known". Wrong: between
the health gate (`capture_r3.sh:173-192`) and the rotate (:276) the harness runs the optional ADRV9002
attribute pokes -- `RX_ATTR_POKE` (:233-253, on the RX board: five 1-s pre-reads, the writes, three
1-s post-reads, so the writes land ~3.5-4.5 s before the RX rotate) and `PEER_ATTR_POKE` (:260-272, on
the peer, no sleeps, ~1-2 s before the RX rotate). Six of the 32 legs poked:

| leg | poke (board) | attributes | receiver listening to the poked board | pre-rotate storm? |
|---|---|---|---|---|
| 221742 probeA_pA | RX_ATTR_POKE (148) | gain_control_mode=spi, hardwaregain=@keep | 146 | no (146 collapsed later, at 148's 21.63 ms rotate stall, -0.00 s) |
| 222141 probeA_pAr2 | RX_ATTR_POKE (148) | same | 146 | no (healthy, rstcs0 = 39) |
| 223721 probeB_pB | RX_ATTR_POKE (148) | agc/bbdc_rejection/rfdc/rssi/quadrature_fic `_tracking_en=0` | 146 | **yes**: storm back-extrapolated to **-4.35 s** before 148's rotate (rstcs0 = 4896 at 841/s) |
| 230437 probeC_pCr2 | RX_ATTR_POKE (148) | gain pair + the five tracking cals | 146 | **yes**: **-4.35 s** (rstcs0 = 4647 at 810/s) |
| 231005 probeD_pD | PEER_ATTR_POKE (146) | gain pair + the five tracking cals | 148 (the RX) | **yes**: 148 PRE-COLLAPSED at its own rotate, rstcs 356 at record 0 (~1.4 s of storm at 148's ~250/s) |
| 163044 w1_t30_pc | RX_ATTR_POKE (146) | gain pair + the five tracking cals | 148 | **yes**: **-4.84 s** before 146's rotate (rstcs0 = 1099 at 192/s) |

Tracking-cal pokes: 4/4 collapse the receiver on the OTHER board, at the instant of the writes;
gain-only pokes: 0/2; the 26 un-poked legs: 1 pre-rotate case (174902, 146's receiver ~1.9 s before
its rotate, the far 148 at 146's 61.6 ms rotate stall). Why the difference [code, ADI kernel tree copy
at ~/tick-kernel-2026r1, drivers/iio/adc/navassa/adrv9002.c, HEAD 40201abd7 -- not verified to be the
flashed kernel's exact revision]: every `*_tracking_en` write goes through
`adrv9002_update_tracking_calls()` (:1506-1545), which moves **all channels, RX and TX, to CALIBRATED**,
calls `adi_adrv9001_cals_Tracking_Set` and restores them -- five RF_ENABLED -> CALIBRATED -> RF_ENABLED
round trips of the poked board's transmitter in a row; `gain_control_mode` (`adrv9002_set_agc_mode`
:1139-1178) and `hardwaregain` (:2480-2506) transition no channel. The poked board's own host feed is
not involved: its `txgap` 5-s maxima in the poke windows are 1047/1286/1384 us (probeB/probeC, the
next window carries the rotate's 21033/24167) and <= 1395 us in t30_pc [log, RX qpsk_tun.log], and its
own receiver keeps decoding (probeB's 148 ran to the deadline). So this is a transmit-side RF
interruption on board X collapsing the receiver on board Y -- the same direction of causation as the
rotate, by a different actuator -- and it is removed from the A/B by not poking, not by the daemon fix.
Sec 9 marks the four rows.

## 6. Ruled out, with a number

* Tap-A grab: after the onset by 5.6-12.5 s in 5/5. (Its 3.8-6.5 ms stall of the RX board's idle feed,
  seen in 4 legs, did not collapse the one observable far receiver, sec 4.2.)
* Snaps S1/S2: after by 1.9-9.9 s in 5/5.
* W1 reader (any board access): after by 8.4-28 s in 4/4 w1 legs; absent in the legB leg.
* RX board's own rotate as the RX collapse trigger: precedes the onset by 0.82-1.72 s in 5/5 with
  1000-2100 frames decoded at 96-100 % in between; its own TX-feed stall was 2.3-2.4 ms in 4/5.
* The RX host stalling its own RX pump: a 211-238 ms host stall leaves the receiver decoding at
  92-100 % in 5/5 (sec 4.2).
* The daemon's re-arm as the cause of the rstcs storm: writes only DMAC registers [code]; fires 10 s
  after the onset [code+log].
* RF/level: **not excluded by an RSSI reading -- there is no pre-collapse RSSI sample on any at-arm
  leg.** 073935's `rssi.jsonl` holds **48** reads spanning 07:42:10-07:49:59, rssi **27.22-27.715 dB**,
  gain 34.000 dB on 48/48; the **first** read is **+13.76 s after** that leg's 07:41:56.242 onset (it is
  the sec 1.0 "first RSSI read" row). So the reads show the level flat for the 7.8 min *after* the
  collapse and say nothing about the instant of it. The first version of this document said "27.22-27.65
  dB ... flat across the collapse in 073935 (14 reads)": the range, the count and the word "across" were
  all wrong, and the reviewer's check line repeated them. What does the excluding is the timing: the
  collapse is bit-aligned to a host event on the other board in 5/5 (sec 1.1), and an RF-level cause has
  no mechanism that fires within one frame of the far board's `SIGUSR2`.
* Post-gap content: idle keepalives 17/17 and data 6/6 both collapse the far receiver (sec 4.2).
* The 09-03 "legB wedged 6/6": 1 at-arm before the rotate (174902), 2 genuine mid-window events at
  +521 s / +547 s (180810, 183520; peer TX gaps at those instants: none >= 3 ms, so a different class),
  3 traffic-deadline artefacts (WEDGE_TIMER_AUDIT.md). Not six of one thing.
* Base rate on 09-05: 5 at-arm collapses in 15 full capture_r3 arms (33 %); 2/8 on 146-RX arms, 3/7 on
  148-RX arms -- not a 146-only class. On 09-03/04: 5 of 17 (3 rotate-timed, 2 pre-rotate: 174902
  un-poked, 231005 poked).

## 7. Proposed diffs (NOT applied -- capture_r3.sh / w1leg_go.sh / qpsk_tun.c / legrun_go.sh are
## deployed to both boards on every run; nothing below is committed until the operator schedules the A/B)

### 7.1 Daemon: rotate without inline file I/O (removes the cause in both directions)

`host_app_k5/qpsk_tun.c`, `framelog_service()`. Pre-open the next file at startup; on rotate swap the
name and the pointer (a `rename()` is a metadata operation), and hand the old `FILE*` -- with its
<= 1 MiB unflushed tail and the 2-3 MB of pages the close will free -- to a helper thread at
`SCHED_OTHER`. The event loop then does no write, no truncate, no page-free at the rotate.

```c
/* PROPOSED (Task 35), not applied: pre-opened successor file + deferred close. */
static FILE *framelog_next = NULL;
static char  framelog_next_path[PATH_MAX];
static void *framelog_closer(void *arg) { fclose((FILE *)arg); return NULL; }
static void framelog_preopen(void)
{
    snprintf(framelog_next_path, sizeof framelog_next_path, "%s.next", framelog_path);
    framelog_next = fopen(framelog_next_path, "wb");          /* new inode: no truncate cost */
    if (framelog_next) setvbuf(framelog_next, NULL, _IOFBF, 1u << 20);
}
static void framelog_service(void)
{
    if (!framelog_rotate_req) return;
    framelog_rotate_req = 0;
    instr_rotate_rings();
    rxresync_rotate();
    if (framelog_fp && framelog_next) {
        FILE *old = framelog_fp;
        if (rename(framelog_next_path, framelog_path) == 0) {    /* atomic: the pulled name now IS the new file */
            framelog_fp = framelog_next; framelog_next = NULL;
            pthread_t th; pthread_attr_t at; struct sched_param sp = { .sched_priority = 0 };
            pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
            pthread_attr_setinheritsched(&at, PTHREAD_EXPLICIT_SCHED);
            pthread_attr_setschedpolicy(&at, SCHED_OTHER); pthread_attr_setschedparam(&at, &sp);
            if (pthread_create(&th, &at, framelog_closer, old) != 0) fclose(old);  /* fallback: inline */
            pthread_attr_destroy(&at);
            framelog_preopen();                                   /* ready for the next rotate; fopen of a
                                                                   * fresh name is cheap, but move it to the
                                                                   * closer thread too if measured otherwise */
        }
    }
    fprintf(stderr, "framelog: rotate serviced t_mono=%.6f\n", now_s());   /* the log line that never existed */
}
```
Plus `framelog_preopen()` after the startup `fopen(framelog_path,"ab")` (:3542) and `-lpthread` in the
capture_r3.sh build line. The rings' reset and the resync snapshot are unchanged, so every offline
joiner keeps its one-window semantics. Risk: the framelog record path is untouched (same `fwrite`
into the same 1 MiB buffer); the only new work in the loop is one `rename()` and one `pthread_create`
per rotate. capture_r3.sh rebuilds and redeploys qpsk_tun on every run (step 1), so no flash and no
manual deploy is involved -- which is also why this change must not land on the branch until the
operator schedules it: the next leg would carry it silently.

**Same treatment for `instr_usr1_dump()` (sec 2.1, 4.2)**: hand the framelog flush and both ring dumps
to the same helper (the helper snapshots the ring -- a torn 32-B record at the head is acceptable for a
diagnostic ring -- and writes it at `SCHED_OTHER`). Dropping `QPSK_TXLOG_USR1` from `legrun_go.sh:59`
alone is not enough: the archived txlog is already the exit dump, but the 2 MiB failhdr dump and the
1 MiB framelog flush that remain are a 4-17 ms stall (the at-arm legs' numbers), still above the
threshold. Until then the step-8 stall is outside the scored window and only costs the `-k` case.

Cheaper variant if a thread is unwanted: keep the inline path but `setvbuf(..., 64u << 10)` (16x
smaller worst-case flush) and replace `fopen("wb")` by `rename()` + `fopen()` of a new name so the
truncate never runs in the loop. Does not bound the flush to < 1 ms by construction; the thread does.

### 7.2 Harness: make a rotate-induced collapse visible and gated (belt and braces, both directions)

`two_jup/capture_r3.sh`, step order around :276. Today: health gate -> rotate both -> sleep 1 -> S1 ->
S2 -> CAP. Proposed: rotate both -> sleep 2 -> **health gate (crc_health + deliver_rate on the RX
board AND `FWD_GATE=1` fwd_health on the peer)** -> on failure `rearm_byte` both and re-gate *without
another rotate* -> S1/S2/CAP. The pulled frames.bin then contains the 12-14 s gate window; the
acceptance window already starts at t >= 15 s ("post-rotate transient" comment at :283), the txlog ring
holds 840 s, and the failhdr ring (65,536) only wraps in a leg that is already a loss. Also record the
rotate and the dump: `echo "ROTATE_RX t=$(date +%s.%N)"` / `ROTATE_PEER` / `USR1_RX` / `USR1_PEER`
into capture_r3.log via the same ssh session as the `pkill` (board `date`), so the next audit does not
have to reconstruct them from a txlog join. Any radio poke stays where it is but is written into the
log with a board `date` for the same reason. `w1leg_go.sh` needs no change (its reader opens on
"link healthy", which moves with the gate).

7.1 alone removes the trigger; 7.2 alone converts a collapse into a re-arm and adds the reverse-leg
gate but leaves the 4/15 peer-side collapses as a 12-s cost per event. The A/B below tests 7.1.

## 8. The one rig A/B (pre-registered)

**Question.** Does removing the inline file I/O from the daemon's SIGUSR2 rotate (7.1) remove the
at-arm collapse class?

**Arms.** A = today's `qpsk_tun.c` (inline `fclose`/`fopen`); B = 7.1. Everything else fixed: same
pair of images as 2026-09-05 afternoon (148 `9f13705d9fb0`, 146 `9acbe2ebe1db`), `capture_r3.sh` as
committed in 21d0dd3 (unchanged step order, so the rotate stays 0.8-1.7 s apart on the two boards), no
`RX_ATTR_POKE` / `PEER_ATTR_POKE` / `LOOP_POKE`, `DUR=60` (the event is at the rotate; a 60-s window is
enough to see the 12-s stall-abort or its absence), alternating A,B,A,B,... on the same leg direction
(LEG=A, 148 RX, the direction with the richer 09-05 sample), one r3 bring-up per arm exactly as today
(each arm IS an arm-lottery draw).

**Primary outcome per arm:** at-arm collapse = `CAPTURE_ABORTED_WEDGED: MID_CAPTURE_WEDGE after
<= 20s` in capture_r3.log AND `frames.bin` onset within 3 s of record 0 (the sec 1 detector). Secondary
(mechanistic, both directions): (i) `gap_ns` of record 0 of `txlog.bin` and `txlog_peer.bin` -- B
predicts <= 1.0 ms (or NONE) on every arm, A reproduces the 2 ms / 16-24 ms bimodal set; (ii) the far
receiver's `reg_rstcs` on record 0 of `frames_peer.bin` -- B predicts 0 on every arm, A reproduces
>= 170 in 4 of the 13 09-05 legs whose far-side witness is observable (064010 and 073935 are not,
sec 9.2). **Precondition, from sec 9.2: an arm whose `frames_peer.bin` holds <= 1 record does not
test this prediction and must be reported UNKNOWN, not as "rstcs 0 = pass"** -- scoring it as a pass
is exactly the error this document's fix round 3 removed; (iii) **the step-8 `SIGUSR1` stall as a
free dose point in every arm, A and B alike**:
its `gap_ns` in both txlogs (with a 60-s window the rings hold ~75 s, ~3 MB, so ~20-35 ms is expected,
cf. 161957's 34-36 ms at 125 s) and the far receiver's `reg_rstcs` slope over the records that follow
it (`frames_peer.bin` for the RX board's stall; `frames.bin` for the peer's only if it extends past
the stall, sec 10). Sec 4.2 predicts a collapse at every step-8 stall >= 7 ms in both arms -- a
per-arm positive control of the dose threshold that costs no rig time; a B arm whose far receiver
survives a >= 7 ms step-8 stall is a dose point against the threshold, not a verdict on 7.1. Traffic
is still live at step 8 under the current `PERF_T = DUR + 400`, so this point is data-fed on the peer
side and idle-fed on the RX side, like 161957.

**Base rate and N.** A: 5/15 on 09-05 (p0 = 0.33; the brief's "5 of ~9" counts only the afternoon
arms). Residual expected under B: the pre-rotate class of sec 5.1 minus the pokes, i.e. **1 of the 26
un-poked legs (3.8 %)**, 0 of 14 un-poked on 09-05; budget p1 <= 0.10 as the conservative bound.
Binomial: with **15 B arms**, observing <= 1 at-arm collapse has probability 0.019 under p0 = 1/3
(0 events: 0.002), 0.55 under p1 = 0.10 and 0.89 under p1 = 1/26 -- so the decision rule is **B <= 1 of
15 -> rotate stall is the cause (reject p0 at 2 %)**; **B >= 3 of 15 -> not the cause (or not the only
one), stop**; B = 2 -> ambiguous, add 6 arms (<= 2 of 21 rejects p0 at **1.3 %**; P(<= 2 | 21, 1/3) =
0.0128). The 15 interleaved A arms are the positive control: >= 3 at-arm events expected with
probability 0.92 (>= 2: 0.98); if A shows <= 1 the base rate has moved and the read is void. Secondary
(i) must hold on 15/15 B arms; a single B arm with a rotate gap >= 3 ms and no collapse is
informative, not disqualifying (it is a dose point). Cost: 30 arms x ~6 min (bring-up ~3 min + gate
12 s + 60 s + pull) ~ 3 h of rig time; each arm's pull is the standard run dir, and the scripts of sec 10
score it without board access.

**Falsifiers written down now.** If B collapses at the rotate with `gap_ns` <= 1 ms on record 0 of the
peer's txlog, the transmit-feed silence is not the cause and mechanism step 1 is wrong. If B collapses
with the peer's rotate gap still >= 6 ms, the deferred close did not remove the stall (the `rename` or
`pthread_create` is the new stall) -- then the 64 KiB-buffer variant is the next A/B, not a conclusion.

## 9. Per-leg table, both days [log] (generated by `dose.py`; poke and UNKNOWN annotations added by hand)

| leg | RX board | RX-board rotate: its TX-feed gap [ms] | peer (far) receiver outcome | PEER rotate: its TX-feed gap [ms] | RX receiver outcome | capture_r3 verdict |
|---|---|---|---|---|---|---|
| 20260903_174902_legB_m16 | 146 (peer 148) | 61.59 | COLLAPSE ~1.0 s before peer rotate = at RX rotate [back-extrapolated, no seq join] (rstcs0=262, 265/s) | busy | PRE-COLLAPSED (rstcs 1648 at RX rotate; un-poked leg, the one residual case) | AT-ARM(12s) |
| 20260903_175236_legB_m16r2 | 146 (peer 148) | 2.53 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260903_180810_legB_m8 | 146 (peer 148) | 21.03 | **UNKNOWN** (frames_peer.bin 0 B, failhdr_peer n=0 total=0: the 148 side scored nothing) | 2.94 | survived (mid-window event at +521 s) | ran |
| 20260903_182006_legB_m8r2 | 146 (peer 148) | 16.60 | **UNKNOWN** (same, 0 B / n=0) | busy | survived | ran |
| 20260903_183520_legB_m8rx | 146 (peer 148) | 20.40 | COLLAPSE at RX rotate (-0.06 s; rstcs0=243, 264/s) | busy | survived (mid-window event at +547 s) | ran |
| 20260903_184803_legB_m8rxr2 | 146 (peer 148) | 16.93 | COLLAPSE at RX rotate (-0.03 s; rstcs0=206, 238/s) | 5.51 | survived | ran |
| 20260903_191042_legA_a1 | 148 (peer 146) | 7.32 | **UNKNOWN** (frames_peer.bin 1 record, failhdr_peer total=1 over the 24.8 s from 146's rotate to its own SIGUSR1: one class-4 all-zero slice at 19:12:50.646, rstcs 0, then nothing -- sec 9.2) | 17.83 | COLLAPSE at peer rotate (-0.004 s) | AT-ARM(12s) |
| 20260903_191410_legA_a1r2 | 148 (peer 146) | 1.69 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260903_192933_legA_a2 | 148 (peer 146) | 21.31 | COLLAPSE at RX rotate (+0.08 s; rstcs0=1052, 824/s) | 1.05 | survived | ran |
| 20260903_221742_probeA_pA | 148 (peer 146) | 21.63 | COLLAPSE at RX rotate (-0.00 s; rstcs0=1133, 826/s) [gain-only poke on 148: no pre-collapse] | 6.35 | COLLAPSE at peer rotate (-0.003 s) | AT-ARM(12s) |
| 20260903_222141_probeA_pAr2 | 148 (peer 146) | 1.35 | healthy (rstcs0=39, no storm) [gain-only poke on 148] | busy | survived | ran |
| 20260903_223721_probeB_pB | 148 (peer 146) | 21.03 | PRE-COLLAPSED (-4.35 s before RX rotate; rstcs0=4896) **[tracking-cal RX_ATTR_POKE on 148, sec 5.1]** | 1.26 | survived | ran |
| 20260903_230437_probeC_pCr2 | 148 (peer 146) | 24.17 | PRE-COLLAPSED (-4.35 s before RX rotate; rstcs0=4647) **[tracking-cal RX_ATTR_POKE on 148]** | 9.37 | COLLAPSE at peer rotate (-0.002 s) | AT-ARM(12s) |
| 20260903_231005_probeD_pD | 148 (peer 146) | 1.85 | healthy (rstcs0=0, no storm) | busy | PRE-COLLAPSED (rstcs 356 at RX rotate) **[tracking-cal PEER_ATTR_POKE on 146]** | AT-ARM(12s) |
| 20260904_005624_legA_whiten | 148 (peer 146) | 1.02 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260904_165420_w1_air | 148 (peer 146) | busy | healthy (rstcs0=0, no storm) | 6.47 | survived | ran |
| 20260904_201814_w1_air | 148 (peer 146) | busy | healthy (rstcs0=0, no storm) | 1.11 | survived | ran |
| 20260905_064010_legB_rev_before1 | 146 (peer 148) | 2.44 | **UNKNOWN** (frames_peer.bin 0 B, failhdr_peer n=0 total=0) | 18.32 | COLLAPSE at peer rotate (-0.001 s) | AT-ARM(12s) |
| 20260905_064400_legB_rev_before2 | 146 (peer 148) | 2.37 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_073935_w1_air | 148 (peer 146) | 2.42 | **UNKNOWN** (frames_peer.bin 1 record, failhdr_peer total=1 over the 29.2 s from 146's rotate to its own SIGUSR1: one class-1 slice at 07:41:56.259, rstcs 0, then nothing -- sec 9.2) | 18.54 | COLLAPSE at peer rotate (-0.002 s) | AT-ARM(12s) |
| 20260905_075030_w1_air2 | 148 (peer 146) | 1.51 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_084623_w1_hostfix_on | 148 (peer 146) | 21.79 | COLLAPSE at RX rotate (+0.06 s; rstcs0=1264, 899/s) | 2.88 | survived | ran |
| 20260905_090214_w1_hostfix_off | 148 (peer 146) | 21.27 | COLLAPSE at RX rotate (-0.02 s; rstcs0=1632, 937/s) | 8.16 | COLLAPSE at peer rotate (-0.003 s) | AT-ARM(12s) |
| 20260905_091549_w1_hostfix_off2 | 148 (peer 146) | 1.90 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_105153_w1_t19_witness | 146 (peer 148) | 2.60 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_142322_w1_t22_judge1 | 146 (peer 148) | 2.30 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_143845_w1_t22_judge2 | 146 (peer 148) | 21.39 | COLLAPSE at RX rotate (-0.05 s; rstcs0=202, 201/s) | busy | survived | ran |
| 20260905_152645_w1_t29_judge3 | 146 (peer 148) | 21.83 | COLLAPSE at RX rotate (-0.17 s; rstcs0=170, 171/s) | 5.97 | COLLAPSE at peer rotate (-0.003 s) | AT-ARM(12s) |
| 20260905_153825_w1_t29_judge3b | 146 (peer 148) | 1.94 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_161309_w1_t32b | 148 (peer 146) | 2.34 | healthy (rstcs0=0, no storm) | 15.41 | COLLAPSE at peer rotate (-0.003 s) | AT-ARM(12s) |
| 20260905_161957_w1_t32b2 | 148 (peer 146) | 1.78 | healthy (rstcs0=0, no storm) | busy | survived | ran |
| 20260905_163044_w1_t30_pc | 146 (peer 148) | 1.60 | PRE-COLLAPSED (-4.84 s before RX rotate; rstcs0=1099) **[tracking-cal RX_ATTR_POKE on 146]** | 3.00 | survived | ran |

"RX board" in the w1 rows follows LEG (A -> 148 RX); the t19/t22/t29 judge legs were LEG=B (146 RX)
per their run.log. "survived" for the RX includes the traffic-deadline stop at +707..+721 s (Task 32).
The `whiten` leg's peer-side seq join is invalid (whitened seqs) and is excluded from the seq-timed
columns but its gaps are real. 32 rows, 64 rotate events; 10 AT-ARM, 22 ran.

### 9.1 Per-event table of the other >= 3 ms feed stalls (generated by `usr1_table.py`) [log]

Stall = `gap_ns` of the first submit after the silence; "at rot+" on the stalling board's txlog clock;
feed content from the seq pattern of the 40 submits either side (idle = repeated seq). The far
receiver is scored 3 s before / 5 s after the stall's end: "pre-collapsed" = rstcs already >= 50/s
before; "unobservable" = its framelog ends before +1 s (it ends at its own SIGUSR1 flush unless the
1 MiB buffer refilled before the pull), which is the sec 9.2 rule applied to this window; "no join" =
no rotate seq join. **Three** legs -- six rows -- carry "no join" in the tool output
(`t35_evidence/usr1_table.txt`: 174902's two rows, probeD's two, whiten's two) and were scored by
CLOCK_REALTIME instead (sec 10): 174902 both directions pre-collapsed (rstcs 234/s and 820/s before
the stall); whiten 227 ms 148->146 COLLAPSE (rstcs 0->0 before, 23->4187 after); probeD 4.0 ms
148->146 survived (0->0). The first version of this preamble said "the two such legs" and named only
whiten and probeD.

| leg | stalled TX (board) | stall [ms] | at rot+ [s] / before txlog end [s] | feed | far receiver | far-receiver outcome |
|---|---|---|---|---|---|---|
| 20260903_174902_legB_m16 | 146 (RX) SIGUSR1 dump | 11.7 | +28.2 / 13.0 | idle | 148 | pre-collapsed (realtime-scored: rstcs 234/s before) |
| 20260903_174902_legB_m16 | 148 (peer) SIGUSR1 dump | 13.0 | +28.8 / 13.0 | data | 146 | pre-collapsed (realtime-scored: 820/s before) |
| 20260903_175236_legB_m16r2 | 146 (RX) SIGUSR1 dump | 224.6 | +740.0 / 13.8 | idle | 148 | COLLAPSE (rstcs +1391 over 5.0 s, 279/s) |
| 20260903_175236_legB_m16r2 | 148 (peer) SIGUSR1 dump | 229.2 | +740.5 / 13.8 | idle | 146 | unobservable (framelog ends -1.63 s) |
| 20260903_180810_legB_m8 | 146 (RX) SIGUSR1 dump | 172.1 | +542.1 / 13.7 | idle | 148 | NO RECORDS |
| 20260903_180810_legB_m8 | 148 (peer) SIGUSR1 dump | 175.1 | +542.7 / 13.6 | data | 146 | confounded: 146 not decoding since +521 s with rstcs flat; storm (rstcs +4110, 846/s) began at this stall |
| 20260903_182006_legB_m8r2 | 146 (RX) SIGUSR1 dump | 235.2 | +745.2 / 13.7 | idle | 148 | NO RECORDS |
| 20260903_182006_legB_m8r2 | 148 (peer) SIGUSR1 dump | 233.9 | +745.7 / 13.7 | idle | 146 | unobservable (framelog ends -1.63 s) |
| 20260903_183520_legB_m8rx | 146 (RX) SIGUSR1 dump | 186.0 | +573.9 / 13.8 | idle | 148 | pre-collapsed (rstcs 266/s before) |
| 20260903_183520_legB_m8rx | 148 (peer) SIGUSR1 dump | 193.1 | +574.5 / 13.7 | data | 146 | pre-collapsed (rstcs 804/s before) |
| 20260903_184803_legB_m8rxr2 | 146 (RX) SIGUSR1 dump | 239.0 | +744.7 / 13.9 | idle | 148 | pre-collapsed (rstcs 251/s before) |
| 20260903_184803_legB_m8rxr2 | 148 (peer) SIGUSR1 dump | 244.9 | +745.3 / 13.9 | idle | 146 | COLLAPSE (rstcs +4182 over 4.9 s, 852/s) |
| 20260903_191042_legA_a1 | 148 (RX) SIGUSR1 dump | 15.7 | +24.3 / 13.1 | idle | 146 | unobservable (frames_peer.bin's only record is at 146's rotate, 24 s before this stall; sec 9.2) |
| 20260903_191042_legA_a1 | 146 (peer) SIGUSR1 dump | 16.2 | +24.8 / 9.8 | data | 148 | pre-collapsed (rstcs 245/s before) |
| 20260903_191410_legA_a1r2 | 148 (RX) SIGUSR1 dump | 227.2 | +718.1 / 13.5 | idle | 146 | COLLAPSE (rstcs +4050 over 5.0 s, 811/s) |
| 20260903_191410_legA_a1r2 | 146 (peer) SIGUSR1 dump | 213.8 | +718.6 / 10.2 | data | 148 | COLLAPSE (rstcs +824 over 3.2 s, 253/s; crc_ok 2970/3217 in 3 s before -> 0/366 in 1 s after) |
| 20260903_192933_legA_a2 | 148 (RX) SIGUSR1 dump | 238.2 | +716.9 / 13.8 | idle | 146 | pre-collapsed (rstcs 797/s before) |
| 20260903_192933_legA_a2 | 146 (peer) SIGUSR1 dump | 238.7 | +717.4 / 10.5 | data | 148 | COLLAPSE (rstcs +798 over 3.4 s, 233/s; crc_ok 2932/3176 -> 0/352) |
| 20260903_221742_probeA_pA | 148 (RX) SIGUSR1 dump | 16.9 | +29.3 / 21.8 | idle | 146 | pre-collapsed (rstcs 836/s before) |
| 20260903_221742_probeA_pA | 146 (peer) SIGUSR1 dump | 15.2 | +29.9 / 17.8 | data | 148 | pre-collapsed (rstcs 256/s before) |
| 20260903_222141_probeA_pAr2 | 148 (RX) SIGUSR1 dump | 226.1 | +731.7 / 14.3 | idle | 146 | COLLAPSE (rstcs +3938 over 5.0 s, 788/s) |
| 20260903_222141_probeA_pAr2 | 146 (peer) SIGUSR1 dump | 221.4 | +732.0 / 10.9 | idle | 148 | unobservable (framelog ends -2.12 s) |
| 20260903_223721_probeB_pB | 148 (RX) Tap-A window | 6.5 | +10.5 / 733.3 | idle | 146 | pre-collapsed (rstcs 806/s before; the poke) |
| 20260903_223721_probeB_pB | 148 (RX) SIGUSR1 dump | 242.1 | +728.6 / 15.1 | idle | 146 | pre-collapsed (rstcs 834/s before) |
| 20260903_223721_probeB_pB | 146 (peer) SIGUSR1 dump | 243.7 | +729.0 / 11.8 | idle | 148 | COLLAPSE (rstcs +1177 over 4.0 s, 295/s; 148 tracking-poked) |
| 20260903_230437_probeC_pCr2 | 148 (RX) SIGUSR1 dump | 7.5 | +25.5 / 13.9 | idle | 146 | pre-collapsed (rstcs 823/s before) |
| 20260903_230437_probeC_pCr2 | 146 (peer) SIGUSR1 dump | 7.7 | +26.0 / 10.5 | data | 148 | pre-collapsed (rstcs 255/s before) |
| 20260903_231005_probeD_pD | 148 (RX) SIGUSR1 dump | 4.0 | +25.4 / 14.0 | idle | 146 | **survived** (realtime-scored: rstcs 0->0 across +6.6 s) |
| 20260903_231005_probeD_pD | 146 (peer) SIGUSR1 dump | 3.2 | +25.7 / 10.6 | data | 148 | pre-collapsed (realtime-scored: 223/s before; the poke) |
| 20260904_005624_legA_whiten | 148 (RX) SIGUSR1 dump | 227.0 | +732.7 / 14.6 | idle | 146 | COLLAPSE (realtime-scored: rstcs 0->0 before, 23->4187 in 7.1 s after) |
| 20260904_005624_legA_whiten | 146 (peer) SIGUSR1 dump | 222.6 | +733.1 / 11.3 | idle | 148 | unobservable (framelog ends -2.1 s) |
| 20260904_165420_w1_air | 148 (RX) Tap-A window | 5.0 | +7.0 / 724.3 | idle | 146 | **survived** (rstcs +0 over 4.8 s) |
| 20260904_165420_w1_air | 148 (RX) SIGUSR1 dump | 222.5 | +718.1 / 13.2 | idle | 146 | COLLAPSE (rstcs +3953 over 5.0 s, 792/s) |
| 20260904_165420_w1_air | 146 (peer) SIGUSR1 dump | 221.9 | +718.6 / 10.0 | data | 148 | COLLAPSE (rstcs +761 over 3.1 s, 246/s; crc_ok 2976/3241 -> 0/384) |
| 20260904_201814_w1_air | 148 (RX) SIGUSR1 dump | 211.3 | +715.5 / 13.2 | idle | 146 | COLLAPSE (rstcs +4064 over 5.0 s, 814/s) |
| 20260904_201814_w1_air | 146 (peer) SIGUSR1 dump | 223.3 | +716.0 / 10.0 | data | 148 | COLLAPSE (rstcs +721 over 3.1 s, 231/s; crc_ok 3236/3240 -> 0/368) |
| 20260905_064010_legB_rev_before1 | 146 (RX) SIGUSR1 dump | 16.3 | +28.2 / 13.5 | idle | 148 | NO RECORDS |
| 20260905_064010_legB_rev_before1 | 148 (peer) SIGUSR1 dump | 14.0 | +28.7 / 13.5 | data | 146 | pre-collapsed (rstcs 841/s before) |
| 20260905_064400_legB_rev_before2 | 146 (RX) SIGUSR1 dump | 233.9 | +745.9 / 38.8 | idle | 148 | COLLAPSE (rstcs +1189 over 5.0 s, 239/s) |
| 20260905_064400_legB_rev_before2 | 148 (peer) SIGUSR1 dump | 219.3 | +747.2 / 39.7 | idle | 146 | unobservable (framelog ends -2.59 s) |
| 20260905_073935_w1_air | 148 (RX) SIGUSR1 dump | 16.8 | +28.7 / 18.0 | idle | 146 | unobservable (frames_peer.bin's only record is at 146's rotate, 29 s before this stall; sec 9.2) |
| 20260905_073935_w1_air | 146 (peer) SIGUSR1 dump | 14.5 | +29.2 / 13.9 | data | 148 | pre-collapsed (rstcs 239/s before) |
| 20260905_075030_w1_air2 | 148 (RX) SIGUSR1 dump | 219.2 | +750.9 / 22.8 | idle | 146 | COLLAPSE (rstcs +4474 over 5.0 s, 893/s) |
| 20260905_075030_w1_air2 | 146 (peer) SIGUSR1 dump | 232.2 | +751.7 / 18.6 | idle | 148 | unobservable (framelog ends -32.3 s) |
| 20260905_084623_w1_hostfix_on | 148 (RX) SIGUSR1 dump | 229.7 | +745.0 / 16.8 | idle | 146 | pre-collapsed (rstcs 924/s before) |
| 20260905_084623_w1_hostfix_on | 146 (peer) SIGUSR1 dump | 246.3 | +745.6 / 13.1 | idle | 148 | unobservable (framelog ends -26.2 s) |
| 20260905_090214_w1_hostfix_off | 148 (RX) Tap-A window | 4.1 | +14.3 / 69.9 | idle | 146 | pre-collapsed (rstcs 879/s before) |
| 20260905_090214_w1_hostfix_off | 148 (RX) SIGUSR1 dump | 29.7 | +54.2 / 30.0 | idle | 146 | pre-collapsed (rstcs 851/s before) |
| 20260905_090214_w1_hostfix_off | 146 (peer) SIGUSR1 dump | 28.8 | +54.8 / 25.6 | data | 148 | pre-collapsed (rstcs 188/s before) |
| 20260905_091549_w1_hostfix_off2 | 148 (RX) SIGUSR1 dump | 216.1 | +730.4 / 13.4 | idle | 146 | COLLAPSE (rstcs +4245 over 5.0 s, 852/s) |
| 20260905_091549_w1_hostfix_off2 | 146 (peer) SIGUSR1 dump | 220.1 | +730.9 / 10.2 | idle | 148 | unobservable (framelog ends -10.9 s) |
| 20260905_105153_w1_t19_witness | 146 (RX) SIGUSR1 dump | 224.9 | +740.8 / 13.8 | idle | 148 | COLLAPSE (rstcs +1000 over 4.9 s, 202/s) |
| 20260905_105153_w1_t19_witness | 148 (peer) SIGUSR1 dump | 230.1 | +741.3 / 13.7 | idle | 146 | COLLAPSE (rstcs +4402 over 5.0 s, 880/s) |
| 20260905_142322_w1_t22_judge1 | 146 (RX) SIGUSR1 dump | 226.9 | +740.1 / 13.8 | idle | 148 | COLLAPSE (rstcs +977 over 5.0 s, 196/s) |
| 20260905_142322_w1_t22_judge1 | 148 (peer) SIGUSR1 dump | 230.8 | +740.7 / 13.7 | idle | 146 | unobservable (framelog ends -1.71 s) |
| 20260905_143845_w1_t22_judge2 | 146 (RX) Tap-A window | 3.8 | +8.2 / 747.1 | idle | 148 | pre-collapsed (rstcs 194/s before; 146's rotate) |
| 20260905_143845_w1_t22_judge2 | 146 (RX) SIGUSR1 dump | 235.0 | +741.1 / 14.1 | idle | 148 | pre-collapsed (rstcs 180/s before) |
| 20260905_143845_w1_t22_judge2 | 148 (peer) SIGUSR1 dump | 241.7 | +741.7 / 14.0 | idle | 146 | unobservable (framelog ends -2.13 s) |
| 20260905_152645_w1_t29_judge3 | 146 (RX) SIGUSR1 dump | 16.9 | +28.2 / 12.8 | idle | 148 | pre-collapsed (rstcs 178/s before) |
| 20260905_152645_w1_t29_judge3 | 148 (peer) SIGUSR1 dump | 16.4 | +28.7 / 12.8 | data | 146 | pre-collapsed (rstcs 907/s before) |
| 20260905_153825_w1_t29_judge3b | 146 (RX) SIGUSR1 dump | 184.0 | +621.9 / 13.5 | idle | 148 | COLLAPSE (rstcs +946 over 5.0 s, 190/s) |
| 20260905_153825_w1_t29_judge3b | 148 (peer) SIGUSR1 dump | 182.6 | +622.3 / 13.5 | idle | 146 | unobservable (framelog ends -1.56 s) |
| 20260905_161309_w1_t32b | 148 (RX) SIGUSR1 dump | 13.9 | +24.4 / 13.0 | idle | 146 | COLLAPSE (rstcs +4512 over 5.0 s, 909/s) |
| 20260905_161309_w1_t32b | 146 (peer) SIGUSR1 dump | 11.4 | +24.9 / 9.8 | data | 148 | pre-collapsed (rstcs 180/s before; the at-arm event) |
| 20260905_161957_w1_t32b2 | 148 (RX) SIGUSR1 dump | 35.7 | +124.3 / 13.2 | idle | 146 | COLLAPSE (rstcs +4411 over 5.0 s, 888/s) |
| 20260905_161957_w1_t32b2 | 146 (peer) SIGUSR1 dump | 34.3 | +124.8 / 9.9 | data | 148 | COLLAPSE (rstcs +535 over 2.8 s, 187/s; crc_ok 3691/3691 -> 0/396) |
| 20260905_163044_w1_t30_pc | 146 (RX) SIGUSR1 dump | 147.4 | +486.9 / 13.7 | idle | 148 | pre-collapsed (rstcs 202/s before; the poke) |
| 20260905_163044_w1_t30_pc | 148 (peer) SIGUSR1 dump | 152.4 | +487.4 / 13.7 | data | 146 | COLLAPSE (rstcs +4497 over 4.8 s, 934/s; crc_ok 3324/3431 -> 0/464; 146 tracking-poked 8 min earlier) |

### 9.2 The observability rule for far-receiver outcomes, and the two legs it re-scores [log + code]

**One rule, used in sec 4.1, 9 and 9.1 alike.** A far-receiver outcome is scored only when its witness
(a) covers the window being scored in time **and** (b) carries enough records inside that window for
`reg_rstcs` to have a slope -- which is what sec 9's method asks for ("its slope over the next 2 s").
Anything else is **UNKNOWN**. `reg_rstcs` is cumulative, so one sample of it is not a rate and cannot
distinguish "no storm" from "no observation".

**Applied to sec 9, it moves exactly two rows.** 20260903_191042_legA_a1 and 20260905_073935_w1_air:
`cap/frames_peer.bin` is **48 B = one record** in both. The single record is `crc_ok = 0`,
`reg_rstcs = 0`, class 4 (all-zero header, `first_zero_off = 0`) at 19:12:50.646 on 191042 and class 1
(MAGIC garbage) at 07:41:56.259 on 073935 -- the latter 17 ms after that leg's own onset, i.e. at
146's rotate. Sec 9 scored both "healthy (rstcs0 = 0, no storm)" off that one record while sec 9.1
called the same two files "unobservable"; the doc cannot hold both readings, and the one that survives
the evidence is UNKNOWN.

**The window those files cover is known, and it is not short.** `framelog_service()` performs
`instr_rotate_rings()` (`txlog_head = 0`, `failhdr_head = 0`) and the framelog `fclose` +
`fopen(..., "wb")` in the **same call** [code :443-460, :769-774], so the peer-rotate instant that
`txlog_peer.bin` record 0 fixes IS the instant the peer's framelog was truncated. The file therefore
holds everything the far receiver logged from its own rotate to its own step-8 `SIGUSR1` flush:
**24.8 s** on 191042 and **29.2 s** on 073935 (sec 9.1's "at rot+" column). "One record" is not a
0.5-s peek.

**A second, independent witness says the same thing.** `failhdr_head` is reset by that same
`instr_rotate_rings()` and `failhdr_dump()` writes it out as `total` [code :367-390]; `legrun_go.sh:102-104`
pulls `failhdr*.bin` **after** `capture_r3.sh` returns, so the archived file is the daemon's **exit**
dump (`atexit(failhdr_dump)`, :3530) and covers the rotate to the quiesce -- a longer window than the
framelog's, and one that does not pass through the framelog's 1 MiB stdio buffer. Measured:
`total = 1` on both legs.

**What one record is not: "no storm".** The comparison class is the other at-arm legs, same 25-30 s
shape, far-side witness read the same way [log]:

| leg | far receiver | frames_peer records | failhdr_peer `total` | sec 9 verdict |
|---|---|---|---|---|
| 20260903_191042_legA_a1 | 146 | **1** | **1** | UNKNOWN (was "healthy") |
| 20260905_073935_w1_air | 146 | **1** | **1** | UNKNOWN (was "healthy") |
| 20260903_231005_probeD_pD | 146 | 1,085 | 1,294 | healthy |
| 20260905_161309_w1_t32b | 146 | 3,677 | 6,258 | healthy at the rotate (collapses at +24.4 s, sec 9.1) |
| 20260905_152645_w1_t29_judge3 | 148 | 12,493 | 14,952 | COLLAPSE at the RX rotate |
| 20260903_221742_probeA_pA | 146 | 16,524 | 21,888 | COLLAPSE at the RX rotate |
| 20260905_090214_w1_hostfix_off | 146 | 33,045 | 38,576 | COLLAPSE at the RX rotate |
| 20260905_064010_legB_rev_before1 | 148 | 0 | 0 | UNKNOWN |

A *healthy* far receiver on one of these legs logs **43-52 failure records/s** (probeD 1,085 / ~25 s;
the 146-as-far-receiver 740-s legs run 60-156 records/s over their whole
window: 191410 44,925, 222141 48,661, 165420 45,579, 201814 48,900, 075030 116,482 records), because
the far end is decoding an idle keepalive
feed and a fraction of those slices never frame. One record in 24.8 s is **1,000x below that
baseline**, not above it -- the two files look like the three 0-byte legs, not like probeD. A receiver
that delivered no slices at all logs nothing either, and nothing in the archive separates the two.

**The buffer-refill argument, and why it is rejected.** It would run: a storming receiver logs
~5,000 records/s, so a 48-B file is itself evidence of no storm. The premise is true and the
conclusion still does not follow, because the healthy state on these legs is not "0 records" -- it is
43-52 records/s. The observation is below **both** hypotheses' predictions, which is the definition of
an unobserved outcome. This document does not use that argument anywhere.

**Why the rule does not rescue sec 9.1's "unobservable" rows.** Those rows score a different window:
the step-8 `SIGUSR1` stall, which lands **0.3-2.6 s before** the far board's own `SIGUSR1` -- i.e.
inside the 5-s scoring window, where both witnesses end. The failhdr `total` cannot fill the gap: it
is a whole-window aggregate with no time resolution, decisive only when it is *small* (as here) and
useless for localising a 5-s window at rot+740 s, where the same legs' totals run 14,000-360,000.
So **23 / 23 at >= 13.9 ms (sec 4.2) is unchanged by this rule**, and so is every sec 1 result on the
RX side (5/5 onsets, the 8/8 seq join): this section re-scores the far-receiver column only.

## 10. Method notes / caveats

* Clocks: every RX-side time is the RX board's CLOCK_REALTIME (frames.bin) or its `date`
  (snaps/CAP); the peer's rotate is placed on the RX clock through the frame seq, never through the
  peer's clock. The reader/RSSI times are nemo's clock at 1 s resolution; nemo and the boards agree to
  within ~1 s (CAP_START vs reader.log ordering is consistent in all four w1 legs). The two boards'
  CLOCK_REALTIME clocks agree to within 19 ms at the peer rotate in all 26 legs with a seq join
  (RX-real minus peer-real: -0.019 .. +0.016 s), which is what licenses the realtime scoring of the
  two no-join legs in sec 9.1 at the 50-ms level.
* `gap_ns` is a lower-bound estimate (sec 2) and only exists when the queue drained; "busy" means the
  rotate's I/O finished inside one frame period (< 0.8 ms).
* The onset detector needs 200 decoded frames after the rotate; a receiver already in a storm at its
  own rotate is reported as PRE-COLLAPSED, not as an onset.
* The peer-receiver back-extrapolation (rstcs0 / slope) assumes a constant storm rate; on 146 the rate
  is 800-940/s, on 148 170-300/s [log], both stable over the 2-s fit windows (the first 50-100 ms run
  faster, 400-700/s, sec 4.2).
* Framelog observability after the pull's `SIGUSR1`: `instr_usr1_dump()` flushes the stdio buffer and
  the file is scp'd a few seconds later; records written in between reach the file only if the 1 MiB
  buffer (21,845 records) refills first. So `frames.bin` ends at the RX's own stall in every idle-tail
  leg (16-40 records/s) and extends 3-5 s past it in the data-fed 148-RX legs (1,160 records/s);
  `frames_peer.bin` is pulled later and a storming 148 logs ~5,000 records/s, so it extends 5-12 s past.
  Any far-receiver claim about the step-8 stall must check that its witness actually extends past the
  stall (sec 9.1's "unobservable" rows); the review's 6/6 "survivals" did not. The general form of that
  check -- covers the window in time AND carries a slope -- is the rule of sec 9.2, and it is what
  re-scores 191042 and 073935 to UNKNOWN in sec 9.
* Frame-period arithmetic uses 0.803 ms; the per-leg measured period from decoded seqs agrees to
  < 0.1 %.
* Scripts (session scratchpad, copies in `two_jup/sdd_archive/2026-09-04-rxfix/t35_evidence/`):
  `dose.py` (sec 9), `harness_events.py` / `atarm_timing.py` (sec 1), `peer_rotate.py` (sec 1.1),
  `midwindow_gaps.py` (sec 4.1), `usr1_gap.py` / `usr1_table.py` (sec 4.2, 9.1; outputs
  `usr1_gap.txt`, `usr1_table.txt`, `usr1_fine.txt`). All read only the archived run dirs.
* Nothing here identifies the fabric state that makes the far receiver's storm persistent (sec 5
  step 3). The A/B removes the trigger; the persistence is a separate fabric question (the ROM-arm
  "arm lottery" class may be the same latch reached by a different starvation).

## 11. Fix round 2 -- what changed against the review (2026-09-05 late evening)

*Historical record of that round. The scoring numbers in the first bullet (0/36, 2/4, 15/16; three
UNKNOWN outcomes) and in the third (0/38, 2/4, 38/39) were superseded by fix round 3; see sec 12.*

* Scoring: the three far-receiver outcomes with an empty 148-side framelog (180810, 182006, 064010)
  are UNKNOWN; rotate dose-response is 0/36, 2/4, 15/16; the "probabilistic near 20 ms / idle streams
  more robust" paragraph is withdrawn (sec 4.1, 9).
* Harness: the pre-rotate class is the tracking-cal attribute poke (capture_r3.sh:233/:260 between the
  gate and the rotate), 4/4 vs 0/2 gain-only vs 1/26 un-poked, with the driver's all-channel state
  transition as the actuator [code] and the poked board's txgap as the no-host-stall witness [log];
  sec 9 rows annotated; the A/B residual is re-derived from 1/26 (sec 5.1, 8).
* Mechanism: "the rotate is the only thing that stalls the feed that long" retracted. The 150-250 ms
  silence is the step-8 `SIGUSR1` ring dump (same loop, same defect, the code comment predicted it),
  located to the record; scored on the far receiver with a witness that extends past the stall it
  collapses it 23/23 at >= 13.9 ms (idle and data feeds alike) and 0/2 at <= 5 ms; the review's 3/12
  was read from framelogs that end before the stall. The receiver's own 200 ms host stall does not
  collapse it (5/5). Combined dose-response 0/38, 2/4, 38/39. Steps 1-4 rewritten; 7.1 extended to the
  dump; A/B secondary (iii) added (sec 0, 2.1, 4.2, 5, 7.1, 8, 9.1, 10).
* Numbers: P(<= 2 of 21 | 1/3) = 1.3 %; 11 of 15 legs at 1.5-2.6 ms; 14 RSSI reads in 073935; the
  daemon's one modem write (0x1DC fslog pop token) in the DRA row; 32 legs / 64 events, not 33 / 66;
  09-03/04 = 5 of 17.
* Label: the "+0.001..+0.003 s" onset-vs-peer-rotate row is the seq join restated (k = 1) and is
  labelled [inferred] with the note under sec 1.0.
* Nothing applied: qpsk_tun.c / capture_r3.sh / legrun_go.sh / w1leg_go.sh / qpsk_join.h untouched;
  the diffs of sec 7 are text.

## 12. Fix round 3 -- what changed against the completeness critic (2026-09-06, desk only)

The bullets of sec 11 are the fix-round-2 record and are superseded where they conflict with this
list; sec 11's "0/36, 2/4, 15/16" and "three far-receiver outcomes" are history, not the current
scoring.

* **One observability rule, stated and applied everywhere (new sec 9.2).** Sec 9 had scored
  20260903_191042 and 20260905_073935 "healthy (rstcs0 = 0, no storm)" from a `frames_peer.bin`
  holding one 48-B record while sec 9.1 called the same two files unobservable. Both are now
  **UNKNOWN**, with the window they cover established from the code (rotate rings and the framelog
  truncate are one call, so the txlog-fixed rotate instant is the truncation instant: 24.8 s / 29.2 s)
  and with a second witness (`failhdr_peer.bin` exit dump, `total = 1`) and the 43-52 records/s
  healthy baseline that shows one record is below *both* hypotheses. The buffer-refill argument that
  would have licensed the survival calls is stated and rejected, so no sec 9.1 "unobservable" row is
  rescued and **23/23 stands**.
* **Consequences carried through everywhere the numbers appear**: rotate dose-response **0/35, 2/4,
  15/15** (sec 0, 4.1); combined with the `SIGUSR1` doses **0/37, 2/4, 38/38** (sec 0, 5 step 4); the
  ">= 7 ms band has one non-collapse at 7.32 ms" claim withdrawn (sec 0, 4.1); the reverse-direction
  count is now 9/9 observable with 3 unknown (sec 0); the A/B's secondary (ii) gains the observability
  precondition and its base rate is re-denominated to 4 of 13 (sec 8). Nothing on the RX side moves:
  the five onsets, the 8/8 seq join and sec 4.2's 23/23 are untouched.
* **The RXQ watchdog claim in sec 2.1 corrected.** It said the watchdog "also fires every 10 s during
  any idle tail -- `rx_q_delivered` is stamped on delivered data frames only". `qpsk_tun.c:1933` stamps
  it on idle frames too, and the log agrees: exactly one `re-arming` line on each of the eight
  600/480-s legs despite 20-27 s idle tails; the 4-8 lines belong to the five at-arm legs, where
  delivery genuinely stopped. This is what WEDGE_TIMER_AUDIT.md sec 1.3 and sec 7 Q5 already said.
* **Sec 6's RSSI exclusion rewritten.** "27.22-27.65 dB ... flat across the collapse in 073935 (14
  reads)" was wrong in range, count and claim: the file holds 48 reads at 27.22-27.715 dB and the first
  is +13.76 s after the onset, so there is no pre-collapse sample on any at-arm leg. The exclusion now
  rests on the timing argument alone.
* **Sec 4.2's rebuttal no longer over-generalises.** 105153 is removed from the "the 146 framelog ends
  1.6-2.6 s before the peer's stall" list (five legs, 1.56-2.59 s) and given its own reason: its
  framelog does extend past the stall and carries rstcs 0 -> 4,453 over its last 5.15 s. The review's
  "6/6 survive" fails either way.
* **Sec 9.1's preamble** now counts three realtime-scored legs / six rows (174902, probeD, whiten), as
  the banked `t35_evidence/usr1_table.txt` marks them; it had said two.
* **Sec 4's health-gate reading** is no longer quoted as a frame rate (WEDGE sec 6b's rule): the gate
  prints k x (one 5-s delta) / 6, so 988-2076 is a gate reading and 1,190-1,246 f/s is the rate.
* Nothing applied here either: no script, no source file and no board was touched in this round.
