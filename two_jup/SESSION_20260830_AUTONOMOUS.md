# AUTONOMOUS WINDOW 2026-08-30 ~10:48 → ~15:48 (Travis away, unreachable)

Running summary, written as I go. Read top-down; newest results appended per section.
Labels used throughout: **[SILICON]** proven on hardware · **[SIM]** proven in simulation ·
**[INFERRED]** not directly measured.

---
## §0 STANDING RULE — THE POSITIVE CONTROL (read this before building any witness)

**No witness may produce a null result until it has been demonstrated capable of producing a non-null
one.** Force it, fake it, inject into it, switch what it observes — whatever makes the needle move. **If a
counter has never been seen to increment, its zero means nothing.**

A clean-link health gate is NOT a positive control. A dead counter passes every clean-run gate ever
written, because the expected answer on a clean run is zero. The gate proves the witness is quiet when it
should be quiet; only a forced non-null proves it can speak at all.

**Instances this has now caught, both in this campaign:**
1. **2026-08-30, the sim injector** (handoff §3): five injections returned results byte-identical to the
   control, which read as "the FEC corrects it". The probes had resolved to dead variables under Verilator
   `--public-flat-rw`; `flips=0 validbeats=0 startbeats=0` over a run in which `startOut` must pulse 54
   times. Every write went nowhere.
2. **2026-08-30 overnight, DBGCAP** (§20 → §22, mine): four per-stage mismatch counters read exactly zero
   across 400 samples and three full-magnitude bursts, and I reported that as "every RX stage upstream of
   the FEC is frame-invariant" — a clean localisation. The same RTL in another image incremented
   continuously. **The counters were almost certainly dead.** Every sim gate I had run was a clean run, so
   every one of them expected zero. I never once showed the counter could increment. I had quoted this very
   rule in §14 while writing the instrument that violated it.

**Operator's assessment (2026-08-31), recorded because it sets the standard:** withdrawing a clean
localisation because the counter was proven dead is worth more than the result would have been — but it
cost a night of work built on an instrument never shown capable of moving. Hence this rule is standing,
not advisory.

**How to satisfy it, concretely, for the capture witnesses used here:** park on one tap and confirm the
mismatch counter is flat, then switch the tap to something that must look different and confirm the
counter climbs. Flat-then-climbing proves both halves in one test: the witness is quiet when it should be
and moves when it must. Also log the capture register itself (0x20C), not only the counter (0x210) — a
capture reading zero is a dead block on its face.

## READ THIS FIRST — cold summary

Four results, none of which needed the rig, and one blocker.

1. **The authorised flash is not needed.** The start-pulse-per-frame counter the whole silicon test was
   going to be built for is *already in the image running on 148*. `cnt_frame_start` (0x124) counts the
   FEC decoder's `startIn`; `cnt_vit_reset` (0x128) counts Viterbi resets. The test is a register poll.
   I did not spend the flash. Established from build provenance, not yet from a read — the first read
   confirms it. (§2)

2. **Mode-2 is answered.** The SSI/LVDS path is exonerated for both the beat and the 51-bit floor. Scoring
   the 08-19 mode-2 capture against the 51-quantisation rule — which was discovered a day *after* that
   capture, so nobody had ever done this — gives a floor identical to mode 1 (0.096 % vs 0.094/0.094/0.094 %
   of frames) and bursts identical in onset, duration, size **and** alternation parity. (§4)

3. **The sharpest open question dissolves.** The BIST comparator behind 0x108 only scores the **first 120
   of each frame's 2240 bits**. So the ROM floor of "0.09 % of frames" was always a frame-start damage
   rate, not a whole-frame rate — the argument that it could not reconcile with the daemon's 0.24 %
   garbage-header rate rested on a false premise about the instrument. 0.09 % vs 0.24 % from two different
   TX sources needs no second mechanism. Item #1 should be closed as dissolved. (§5)

4. **Everything requiring the rig is blocked, not failed.** A permission denial stopped the runner from
   launching; per the standing rule I did not retry it in any form. The script is written and ready and
   the resume command is one line. (§3, §7)

The honest caveat, and it is the one I nearly got wrong: **mode-2 ROM BIST does not test the comb** — in
any mode. That instrument never traverses the delivery plane where the comb lives, so its null is
guaranteed rather than informative. The comb leg still needs a byte-path run. (§4c)

## Authorisation for this window (as given)
1. Flash AUTHORISED **once, 148 only**, for the start-pulse-per-frame counter build. Full rails:
   restore point banked+named, readback verify, two-pass health gate, auto-rollback, **NO RETRY LOOP**.
   One failed flash ends rig work for the window.
2. **146 not to be flashed or touched.** One actor on the rig.
3. Silicon start-counter keeps the pre-registered prediction/falsifier verbatim (see §3).
4. Priority: mode-2 SSI → silicon start-counter → 0.24 % vs 0.09 % header discrepancy. No new candidates.
5. Zero-error standard for FPGA-internal digital loopback stands.
6. Instrument before interpreting — count events and print the count before any null result counts.
7. Findings to file as I go (this file).
8. If every path needs Travis, stop and write the question up.

## Status board (final, 12:05)
| Item | State |
|---|---|
| Mode-2 SSI near-end loopback | **ANSWERED from data already on disk** (§4). Rig re-run written but blocked (§3). |
| Silicon start-counter | **No flash needed** — counter already in the flashed image at 0x124/0x128 (§2). Rig poll blocked (§3). |
| Header discrepancy 0.24 % vs 0.09 % | **DISSOLVED** — its premise was an uncharacterised instrument (§5). |
| Flash authorisation | **UNUSED.** Never needed. Still intact. |
| Rig | **UNTOUCHED.** No command issued all session. No lock taken, sentinel never stopped, link up. |

---
## §1 Mode-2 (ADRV9002 SSI near-end loopback)

**Pre-existing evidence found during orientation (NOT mine, prior session 2026-08-19):**
`LAYERA_BER.md` records a full mode-2 run — harness `layerA_ssi_nel.sh`, CSV
`r3cap/ssinel_burstpoll_20260819_090342.csv`. Rails were real: lock gate PASS (1245 f/s),
positive control PASS (0x158=1 garbage → 63,505 err/s, which proves the RX content tracks
**148's own TX**, i.e. the loopback is genuine and not 146's air signal).
Result **[SILICON, prior session, not yet reproduced on the current image]**:
- Beat **PRESENT** in mode 2: five bursts, start-to-start 120/119/121/119 s.
- Burst sizes 293,183 / 215,030 / 293,280 / 215,131 / 293,183 — the same two species, bit-for-bit,
  as FPGA-internal digital loopback and as 146.
- Quiet floor 62 err/s (vs ~56 err/s internal).

**[SUPERSEDED — see §4c. The inference below is WRONG and I am leaving it visible on purpose, because
the way it was wrong is the point: ROM BIST cannot see the comb in any mode.]**

**Consequence I am drawing, flagged [INFERRED] until I reproduce it:** a quiet floor of 62 err/s at
1245 f/s is the *same order as the mode-1 floor*, not a comb. A 6 % comb would damage ~75 frames/s and
produce errors orders of magnitude above 62/s. So this run bears on the comb question too, which the
handoff listed as untested in mode 2.

**What re-running adds:** the handoff explicitly flags the 08-19 claim as not reproduced, and the image
has changed since (now `786dce9fafc8`). Re-running gives a same-image, same-session mode-1 vs mode-2
comparison — which is what makes the comb call sound rather than cross-image.

**Harness bug found before running (rule 6, instrument first):** `layerA_ssi_nel.sh` `arm()` looks for
an IIO device named `axi-adrv9001-tx-lpc`; every other script in the tree uses `axi-adrv9002-tx-lpc`.
If the name is 9002, `TXD` is empty, `T` becomes `/sys/kernel/debug/iio//direct_reg_access`, and the
three TX writes go nowhere silently. To be verified on-board and fixed before the run.

---
## §2 THE FLASH IS NOT NEEDED — the start-pulse counter is ALREADY IN THE FLASHED IMAGE

Found at ~11:10 while looking for the build path for the start-counter image.

`TxRxCompo_ip_src_FEC_Decoder_Wrapper.v` instantiates `FecCounters` with:
```
.e2(startIn)   -> c2 -> cnt_frame_start
.e3(vitReset_1)-> c3 -> cnt_vit_reset
```
`startIn` is the FEC decoder's start input — **the exact signal the start-pulse hypothesis is about**
(in the sim harness this is `startSelInj`, the same net). `vitReset_1` is the Viterbi reset.

Both are already routed to AXI-lite. From `TxRxCompo_ip_addr_decoder.v` (`address_select_level1` is the
**word** address, so byte address = value × 4):

| word | byte addr | register |
|---|---|---|
| 0x40 | 0x100 | count_out |
| 0x41 | **0x104** | packets_out (known) |
| 0x42 | **0x108** | bit_errors_out (known) |
| 0x48 | 0x120 | cnt_descr_in (= validIn) |
| **0x49** | **0x124** | **cnt_frame_start (= startIn) ← the start-pulse counter** |
| **0x4A** | **0x128** | **cnt_vit_reset (= Viterbi reset) ← trellis restarts** |
| 0x4B | 0x12C | cnt_deint_valid |
| 0x4C | 0x130 | cnt_dec_bits (= validOut) |
| 0x4D | 0x134 | cnt_bist_start (= startOut) |
| 0x83 | 0x20C | beatfix_viol_count |
| 0x84 | 0x210 | beatfix_viol_latch |

**The address arithmetic is self-checked:** it reproduces the three known addresses (0x104, 0x108) and
both witness registers the handoff names (0x20C/0x210). That is what makes me trust 0x124/0x128.

**Provenance [SILICON, by build identity]:** this HDL is `jupiter_byte_pdwit_build`, whose build log ends
`BYTE_BUILD_DONE md5=786dce9fafc80a28f2ffbe7d3bde76b0` — byte-for-byte the image on 148 right now
(`786dce9fafc8`). So these counters are in the running silicon, not merely in a source tree.

**Consequence: the authorised flash is not required for the start-counter test.** I am not spending it.
No build, no flash, no rollback risk, and the test can run immediately. The authorisation stays unused
and available; I will not use it speculatively.

**Caveat to check before interpreting (rule 6).** `FecCounters` increments on a *level*
(`if (e2_1 && k2 < max)`), not an explicit edge. If `startIn` is a one-beat pulse this is one count per
start, but that is an assumption until measured. **Its own self-test is the pre-registered healthy
prediction:** on a healthy link, Δcnt_frame_start / Δpackets must come out at exactly 1.00. If it lands
on any other constant, I do not interpret the burst data until I understand why.

---
## §3 BLOCKER — rig execution denied by the permission classifier (11:20)

I wrote the combined rig runner `two_jup/mode2_startcnt_20260830.sh` (syntax-checked, executable) and
tried to launch it detached as a `systemd-run --user` transient unit, per the standing convention for
long jobs. **The Claude Code permission classifier denied the launch.**

Per the standing rule ("on a permission or classifier denial, stop and ask — never retry variants of the
denied command") I did **not** retry it in any other form — not via a background shell, not foregrounded,
not split into pieces. No rig command has been issued in this session. **148 and 146 are untouched; the
rig is exactly as the handoff left it** (no RIG_LOCK taken, no SENTINEL_STOP written, sentinel still
running, link up).

Travis is unreachable, so I cannot get the permission lifted inside this window. Everything requiring the
rig — the mode-2 legs and the silicon start-counter read — is therefore **blocked, not attempted, and not
failed**. See §6 for the exact one-line command to resume, and §7 for the question for Travis.

**The authorised flash was never needed and is unused** (§2). That authorisation is still intact.

I have redirected the window to everything that produces real evidence without the rig: re-analysis of the
existing mode-2 capture already on disk (§4), and the header discrepancy (§5).

---
## §4 MODE-2 ANSWERED FROM DATA ALREADY ON DISK — no rig needed

The 08-19 mode-2 capture and three mode-1 captures are all in `two_jup/r3cap/` at the same 1 Hz cadence
and the same 1256 f/s state. Nobody had ever scored them against the 51-quantisation rule, because that
rule was only discovered on 08-30 — a day *after* these captures. So this is a genuinely new result from
old data, not a re-reading of an old conclusion.

Captures (all ROM BIST, 600 s, 1 Hz, mean 1256 f/s):
- mode 1 (FPGA-internal digital, 0x114=0): `burstpoll_20260818_124443/131600/133323.csv`
- mode 2 (ADRV9002 SSI near-end loopback):  `ssinel_burstpoll_20260819_090342.csv`

### 4a. The 51-bit event floor is present, and identical, on the SSI path **[SILICON]**
| capture | quiet floor | quiet seconds that are an **exact** multiple of 51 | event rate |
|---|---|---|---|
| mode 1 · 124443 | 60.6 err/s | 457/567 = **80.6 %** | 1 per 1063 frames = **0.094 %** |
| mode 1 · 131600 | 60.7 err/s | 456/567 = **80.4 %** | 1 per 1061 frames = **0.094 %** |
| mode 1 · 133323 | 60.5 err/s | 457/566 = **80.7 %** | 1 per 1066 frames = **0.094 %** |
| **mode 2 · SSI-NEL** | **62.0 err/s** | **420/566 = 74.2 %** | 1 per 1044 frames = **0.096 %** |

326 of the 566 mode-2 quiet seconds read *exactly* 51; 47 read exactly 102; 46 read exactly 0. The floor
is the same discrete 51-bit event at the same rate whether the samples traverse the SSI lanes or never
leave the die. (A separate 34 f/s capture, `burstpoll_20260819_032632.csv`, is 99.2 % exact multiples —
the quantisation is cleanest when the event rate is low, as it should be.)

### 4b. The bursts are not merely the same species — they are the same **phase** **[SILICON]**
| | mode 1 · 124443 | mode 1 · 131600 | mode 1 · 133323 | **mode 2 · SSI-NEL** |
|---|---|---|---|---|
| onsets (s into poll) | 88, 209, 327, 448, 567 | 87, 208, 327, 447, 566 | 88, 208, 327, 448, 567 | **88, 208, 327, 448, 567** |
| sizes (bit errors) | 293183 / 214875 / 293280 / 215131 / 293183 | 293280 / 215030 / 293183 / 215030 / 293183 | 293183 / 215030 / 293280 / 215131 / 293183 | **293183 / 215030 / 293280 / 215131 / 293183** |
| start-to-start | 121/118/121/119 s | 121/119/120/119 s | 120/119/121/119 s | **120/119/121/119 s** |

**The alternation is phase-locked too, not just the onsets.** Scoring each burst as BIG (~293 k) or
small (~215 k):

| capture | sequence |
|---|---|
| mode 1 · 124443 | BIG sml BIG sml BIG |
| mode 1 · 131600 | BIG sml BIG sml BIG |
| mode 1 · 133323 | BIG sml BIG sml BIG |
| **mode 2 · SSI-NEL** | **BIG sml BIG sml BIG** |

So the mechanism has a ~239.5 s two-state cycle (two beats), and *which* of the two states you get is
fixed by the time since arm. Both the phase and the parity survive a change of signal path.

Every capture uses the same 65 s post-arm wait before polling, so "88 s into the poll" is the same wall
time after the arm in all four. **Bursts recur at the same offset from the arm, with the same duration and
the same error count, across two different days, four separate arms, and two different signal paths.**
The 08-19 note called this "the same two species, bit-for-bit sizes"; it is stronger than that — it is the
same phase, which makes the beat a *deterministic event clocked from reset*, not a drifting or stochastic
process. **[INFERRED from that: something reaches a fixed count ~119.75 s after reset.]** I am deliberately
not chasing which counter — that would be a new candidate, and the instruction is not to open any.

### 4c. What this settles, and what it does NOT **[read the second half carefully]**
**Settles:** the ADRV9002 SSI/LVDS path is **exonerated for both the beat and the 51-bit floor**. Neither
changes in rate, quantum, size, or phase when the loop goes out over LVDS and back. Combined with the
handoff's placement of the fault in the RX decode chain, the mechanism is inside the fabric, upstream of
the SSI interface, exactly as the start-restart hypothesis requires.

**Does NOT settle the comb — and I nearly reported that it did.** My first reading (§1) was that a
62 err/s floor is far below comb scale, so the comb must be absent in mode 2. That reasoning is wrong,
for the reason the advisor flagged: **comb-absence in mode 1 was never established with this instrument.**
It was established on the byte-DMA/daemon path (2026-08-26 P1, `singles_loopback.sh` on 146: L2 idle
crc_drop, L3 `-B` bit-exact), and the comb is localised to the **delivery plane** — ByteRxFifo overflow at
S2MM transfer boundaries. **ROM BIST scores bit errors in fabric at the decoder output; it never traverses
ByteRxFifo or S2MM at all.** So a ROM BIST run cannot see the comb in *any* mode, and the null is
guaranteed rather than informative. The correct mode-2 comb test is byte source + daemon + delivered PER
with NEL on — which is precisely the pre-registered prediction (b) recorded on 08-26 — and that is rig
work, currently blocked (§3).

**Also note the one-sidedness of any single-board mode-2 comb test:** the accused element is *146's* TX
egress. A loop on 148 tests 148's egress. A positive (comb appears on 148's own SSI loop) would exonerate
146 and indict the transceiver path generically; a negative says only that 148's egress is clean, which is
already expected since 148's TX drives the good reverse direction (1.39 %). Worth stating before anyone
reads a clean mode-2 byte run as "146 exonerated".

---
## §5 THE BIST COMPARATOR ONLY SCORES THE FIRST 120 BITS OF EACH FRAME

This is an instrument fact, found by reading the shipped netlist, and it dissolves open-queue item #1.

`MATLAB_Function.v` is the in-fabric BIST comparator behind `0x104` (packets) and `0x108` (bit_errors).
Instantiated from `Capture_Data_Bits` (`Receiver.v:388`) as:
`.start(dataSrt = startOut)`, `.valid(validOut)`, `.datain(dataOut)` — the FEC decoder's own outputs.

```verilog
assign tmp_3  = (start == 1'b0 ? tmp_5 : count_1);   // bit index, RESET TO 1 on every frame start
assign tmp_13 = (tmp_3 <= 32'd120) && (p12tmp_1 != p12tmp_2);   // error counted ONLY for index 1..120
wire signed [7:0] p12tmp_tmp [0:119];                // golden reference is 120 bits long
// msgLen = uint32(2240);                            // ...but the frame is 2240 bits
```
Identical in the production source `TxRxCompo_ip_src_MATLAB_Function.v` (120 golden entries, same
`32'd120` guard), i.e. **this is what the flashed silicon does** — proven by reading the netlist that
built `786dce9fafc8`.

**So `0x108` counts errors in the first 120 of 2240 bits — 5.4 % of the frame, at the frame start.
It is blind to the other 94.6 %.** Every bit-error number in this campaign is a frame-start number.

Empirical consistency check on data already on disk: across 20 sim `*_frames.txt` runs the per-frame
maximum is 51–72, never at or above 120 — so the window is **not** clipping the counts. The numbers are
genuine, they just mean something narrower than they have been read as.

### 5a. This dissolves the 0.24 % vs 0.09 % discrepancy **[proven in RTL → applies to silicon]**
Open-queue item #1 argued: *"ROM floor = 0.09 % of frames with a 51-bit event; daemon floor = 0.24 % of
frames with garbage headers. A 51-bit burst landing uniformly would hit the 12-byte header only ~0.8 % of
the time, so these do not reconcile."*

**The premise is false.** There is no "landing uniformly" step: the 0.09 % was *already* a frame-start
damage rate, because the comparator only ever looks at the first 120 bits (= first 15 bytes, which
contains the 12-byte header). Both numbers measure the same thing — how often the start of a frame is
damaged. They differ by 2.7×, not by ~30×, and they come from different TX sources (ROM vs daemon) with
different traffic. A factor of 2.7 between two different sources needs no second mechanism.

**Item #1 should be closed as dissolved, not answered.** The sharpest open question in the handoff was an
artefact of an uncharacterised instrument. That is the fourth near-miss of this class in a week, and the
first one caught before it was acted on rather than after.

### 5b. Campaign numbers that need restating (not wrong, but narrower than written)
- *"each event damages 0.42 % of a frame's payload bits"* — no. It is **51 of the 120 compared bits =
  42.5 % of the compared window**. Damage outside bits 1–120 has never been measured, in any run.
- *"the same RTL in simulation decodes 84 of 84 frames with zero errors"* — zero errors **in the first
  120 bits** of each frame. The zero-error standard still stands as a standard (rule 5, any nonzero is a
  defect) but "zero" is not "the frame was perfect".
- Fact worth having on record (**not** a correction — the ledger already wrote this arithmetic as an
  approximation): the *floor* quantisation is exact (74–81 % of quiet seconds are exact multiples of 51),
  while burst sizes are not (293,183 / 51 = 5748.7). The strong, exact result is the floor.

### 5c. What it suggests about the defect **[INFERRED — not measured, and I am not chasing it]**
If a trellis restart damages ~51 bits at the frame start and the instrument can only see the frame start,
then the campaign has **no evidence either way** about the remaining 2,144 bits. A defect that destroys
the frame header and leaves the payload intact is a *framing* defect, and "bad magic" — the air-side
symptom driving forward PER — is exactly what a destroyed header looks like. This is consistent with, and
would unify, the beat, the floor and the bad-magic rate. It is **inferred, untested**, and the test for it
is a comparator window change (a build), which I have not made and am not authorised to open as a new
candidate. Recording it for Travis, not acting on it.

---
## §6 INDEX-GUARD DETAIL (checked, so nobody has to re-check it)
`MATLAB_Function.v:154` has a second constant, `tmp_6 = tmp_3 <= 32'd130`, which could look like a
competing window. It is not: `tmp_7 = tmp_6 ? tmp_3+1 : tmp_3` — it gates the **index increment**, so the
bit counter simply saturates at 131 instead of wrapping. It never feeds the compare path. The compare
guard is `tmp_3 <= 120` and nothing else. The golden array is indexed `p12tmp_tmp[tmp_3-1]` with `tmp_3`
starting at 1, so bits 1..120 map to golden[0..119]. The reading in §5 is exact.

---
## §7 QUESTION FOR TRAVIS / HOW TO RESUME

**1. One permission is blocking all rig work.** I wrote the rig runner and tried to launch it as a
`systemd-run --user` transient unit (the standing convention for long jobs). The Claude Code permission
classifier denied it. Per the standing rule I did not retry it in any other form, so **no rig command was
issued this session and the rig is untouched** — no lock taken, no sentinel stop, link still up.

To resume, either grant that permission or just run it yourself:
```
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup && DWELL=400 ./mode2_startcnt_20260830.sh
```
It takes the rig lock, runs mode 1 and mode 2 back to back on 148 with a positive control in each leg,
logs `0x104/0x108/0x124/0x128/0x130` at 1 Hz, then restores the link with the gated bring-up at the
**shipped** defaults and restarts both watchdogs. ~25 min. It never addresses 146 except through that
standard restore.

**2. The flash authorisation was never needed, and is unused.** The start-pulse-per-frame counter is
already in the image on 148 right now: `cnt_frame_start` at **0x124** counts the FEC decoder's `startIn`,
`cnt_vit_reset` at **0x128** counts Viterbi resets. Both come from `FecCounters` in the netlist that built
`786dce9fafc8`. No build, no flash, no rollback risk — the silicon start-counter test is a register poll.
**Precision on that claim:** their presence is established from *build provenance* (that netlist produced
the md5 now on the board), not from a read — no register has been read this session. The first read is the
confirmation step, and the runner's `A_LOCK` probe is where it happens: if 0x124/0x128 come back dead or
static, the counters are not reachable and the flash authorisation becomes live again.
The pre-registered prediction and falsifier are carried verbatim into the script's header comment.

**3. The mode-2 comb leg still needs a byte-path run, and it is one-sided.** ROM BIST cannot see the comb
in any mode (§4c) — it never traverses ByteRxFifo/S2MM, where the comb is localised. The real test is
byte source + daemon + delivered PER with NEL on, which is the 08-26 pre-registered prediction (b). And
run on 148 it tests *148's* egress; the accused element is 146's. A positive would exonerate 146; a
negative says little. Do you want that leg run on 148 anyway, or is it only worth doing on 146 — which is
outside this window's authorisation?

**4. One thing I found and deliberately did not chase** (§5c): because the comparator is blind past bit
120, nothing in this campaign has ever measured whether the beat damages the *rest* of the frame. If it
does not, the beat is a framing defect that destroys headers — which is exactly what "bad magic" is, and
would unify the beat, the floor and forward PER. Testing it means widening the comparator window, i.e. a
build. That is a new candidate and you said not to open any, so it is recorded and left alone.

**Sentinel handling in the runner (checked, 12:25):** `rig_lock` writes `SENTINEL_STOP`, which makes the
running sentinel exit; `rig_unlock` on the EXIT trap removes it and `sentinelkeeper-004023.service`
relaunches the sentinel within 2 min. The restore is complete with no manual step. Note the keeper's
script currently lives in a *previous session's scratchpad*
(`/tmp/claude-1000/.../4cb08d3f-.../scratchpad/sentinel_keeper.sh`) — it is running now, but that is a
fragile home for it and matches the standing note that the sentinel should be a proper systemd unit.

---
## §8 SILICON START-COUNTER RESULT (15:28–15:37) — **THE START-PULSE MODEL IS DEAD**

Run: `startcnt/20260830_152844/` (mode 1, FPGA-internal digital loopback, ROM BIST, 400 s at 1 Hz).
Scorer: `two_jup/score_startcnt.py`. No flash was used; the counters were already in the image.

**Rails first.** Positive control `0x158=1` (byte source, no daemon) gave 63,563 err/s vs a 51 err/s
floor — the comparator genuinely tracks 148's own TX. Counter self-test S1 **PASS**: on 381 quiet seconds
covering 484,979 frames, startIn/frame = **1.0000**, vitReset/frame = **1.0000**, startOut/frame =
**1.0000**. The instrument is alive, sane, and edge-exact. Quiet floor 61.1 err/s, 80.6 % of quiet seconds
exact multiples of 51 — the known floor, reproduced today on a fresh arm.

**Three full-magnitude bursts were captured:**

| burst | t | duration | bit errors | startIn/frame | vitReset/frame | startOut/frame |
|---|---|---|---|---|---|---|
| 1 | 87–93 s | 7 s | 293,183 | **1.000** | **1.000** | **1.000** |
| 2 | 206–210 s | 5 s | 215,030 | **1.000** | **1.000** | **1.000** |
| 3 | 323–329 s | 7 s | 293,183 | **1.000** | **1.000** | **1.000** |

Aggregated over all 19 burst seconds: 24,183 frames, 801,396 bit errors, and **exactly 1.0000 starts per
frame at all three taps**.

### VERDICT — reported dead, as pre-registered **[SILICON]**
> *"if hardware shows exactly one start per frame straight through a burst, the spurious-start model is
> wrong and it dies there"*

It does. **The spurious/duplicate-start hypothesis is FALSIFIED on silicon.** So is the broader
"trellis restarted mid-stream" reading: `cnt_vit_reset` is *also* exactly 1.000 per frame through
801,396 bit errors, so the Viterbi is not being reset at all. Both boundaries Travis asked about are
clean — one start into the decoder, one trellis reset, one start out — while the frame's first 120 bits
are being destroyed at ~33 errors/frame.

This is the second pre-registered hypothesis killed on silicon by its own witness in two days
(the delay-FIFO displacement model died 08-30 00:22). Both died the same way: a real, exact sim analogue
that the hardware does not do.

### What it costs us
The handoff's settled paragraph placed the fault "in the RX-side decode/alignment chain **by inference
from the 51-bit decoder signature**". That inference is now dead: 51 is still the acquisition-transient
quantum in sim, but on hardware the events occur **without any restart**, so 51 cannot be read as
"the decoder re-converging". The floor and the beat are damage to the frame's first 120 bits with the
start/reset/marker path completely undisturbed — i.e. **the data is wrong, not the framing**.

Bursts also reproduced the phase-lock again on a brand-new arm today: onsets 87 / 206 / 323 s, sizes
293,183 / 215,030 / 293,183, start-to-start 119 / 117 s — the same species, sizes and BIG-sml-BIG parity
as the 08-18 and 08-19 captures. **[SILICON]**

### 8a. Scope of the leg-A result — what it does and does NOT exonerate
**Does:** the control/framing path through the decoder is clean. Over all 400 samples startIn/frame stays
in 0.9984–1.0016 and vitReset/frame in 0.9961–1.0039 (±1 count of sampling jitter on ~1250), and there is
no second where frames advance with a zero start/reset/startOut delta.

**Does NOT:** it does not show the loopback is error-free — it is not (61 err/s quiet, 33 err/frame in
bursts of only 120 compared bits, 63/120 in the worst second; the zero-error standard is violated
throughout). And it does not exonerate the Viterbi as a **data-path** error source. These are control-path
witnesses: they count start pulses and trellis resets, not bit correctness. A clean control path is
consistent with the decoder emitting wrong bits, either from already-wrong input or from misdecoding
correct input. Both remain untested, as does everything upstream.

### 8b. INSTRUMENT WARNING — `cnt_dec_bits` (0x130) SATURATED; all its numbers in this run are void
It appeared to show decoded bits/frame going 6373 (quiet) → 12254 (bursts 1–2) → 0.0000 (burst 3), which
would have looked like a dramatic data-path signal. It is an artefact. `FecCounters` **saturates** at
0xFFFFFFFF rather than wrapping; the delta went flat at t=212 and stayed flat contiguously through t=400
after accumulating 3,278,243,230 against a 2^32 ceiling of 4,294,967,296. **Discard every 0x130 number
from this run**, including "burst 3 had zero decoded bits".
The start counters are unaffected — ~500k counts over the run, four orders of magnitude from saturation.
For any future run that wants 0x130, reset it (soft-reset 0x000) between legs or poll it faster.

---
## §9 LEG B — mode 2 (SSI near-end loopback), same run, same board, minutes later

Positive control fired (`0x158=1` → 3,198 err/s against a 51 err/s floor, and frame rate collapsed
1246 → 61 f/s), so the NEL loop is real and the RX is tracking 148's own TX, not 146's air signal.
The debugfs attributes read back empty on `cat` — the same readback quirk noted on 08-19; the control is
what establishes the loop, not the readback.

| | mode 1 (leg A) | mode 2 (leg B) |
|---|---|---|
| quiet floor | 61.1 err/s | **61.6 err/s** |
| quiet seconds exact multiples of 51 | 80.6 % | **75.5 %** |
| burst onsets | 87 / 206 / 323 s | **87 / 206 / 323 s** |
| burst sizes | 293,183 / 215,030 / 293,183 | **293,183 / 215,030 / 293,183** |
| startIn / vitReset / startOut per frame, in burst | 1.000 / 1.000 / 1.000 | **1.000 / 1.000 / 1.000** |
| burst bit errors (aggregate) | 801,396 | 801,609 |

**The burst sizes are identical to the digit** across the two signal paths, in the same session, minutes
apart, on the same board. Until now the mode-1/mode-2 species match rested on a cross-day comparison
(08-18 vs 08-19); it is now a same-session fact. **[SILICON]**

The falsifier fires identically in mode 2: exactly 1.0000 starts per frame at all three taps through
801,609 bit errors. **The start-pulse model is dead on both paths.**

Minor: the scorer also flags a 1-second excursion at t=224 (213 errors, vs a 61 err/s floor). That is a
threshold-edge artefact of the >200 err/s burst criterion — one second at ~4 events instead of 1 — not a
fourth burst. Noted so nobody counts it as one.

**Combined verdict for mode 2:** the SSI/LVDS path is exonerated for the beat and the floor, now confirmed
prospectively on the current image rather than inferred from the 08-19 capture. And the comb caveat stands
unchanged — ROM BIST cannot see the comb in any mode (§4c), so this says nothing about it.

---
## §10 RIG RESTORED AND VERIFIED (15:47–15:48)
- `bringup_r2r3.sh r3` at the shipped defaults: **exit 0, ARM GATE PASS on try 1**.
- `qpsk_tun` = 1 and `lock_watchdog` = 1 on **both** 10.0.0.146 and 10.0.0.148.
- `RIG_LOCK` and `SENTINEL_STOP` both removed.
- Sentinel relaunched by the keeper at **15:48:40** (`sentinel (re)launched by keeper`), pid 1458921,
  confirmed by bracket-idiom `pgrep -af "[d]elivery_sentinel.sh"` **and** the systemd unit **and** the log.
- **No flash was performed on either board.** The authorisation Travis granted is unspent.
- 146 was touched only by the standard gated bring-up in the restore; no experiment, no flash.

**Process note, recorded because it nearly became a false all-clear:** my first sentinel check used
`pgrep -f "modem-status/delivery_sentinel.sh"`, which matched *the watcher's own shell* and reported
"sentinel back" while no sentinel was running. This repo already has the fix as a documented idiom
(`[l]ock_watchdog` in `ber_loopback_gate.sh` / the sentinel itself) and I did not use it. Any future
process check here must use the bracketed form and corroborate with the systemd unit and the log line.

---
## §11 WHERE THE ERRORS FIRST APPEAR — **AT THE DEMODULATOR OUTPUT, BEFORE THE FEC DECODER**

Run `caploc/20260830_155824/`, mode 1 (FPGA-internal digital loopback), ROM BIST, 400 s @ 1 Hz.
Runner `two_jup/cap_localise_20260830.sh`, scorer `two_jup/score_caploc.py`. No build, no flash —
`FecCapture` already provides the three taps in the flashed image.

**C1 self-test PASS** (pre-registered: each tap must be ≥99 % constant on a clean link):

| tap | register | golden | constant in quiet |
|---|---|---|---|
| `cap_in` — coded bits from the demod (PRE-Viterbi, pre-deint) | 0x13C | 0x5216F3E2 | 99.47 % |
| `cap_deint` — out of the deinterleaver (PRE-Viterbi) | 0x140 | 0x52B9CE5C | 100.00 % |
| `cap_out` — decoded output (POST-Viterbi) | 0x144 | **0x04922282** | 99.21 % |

`cap_out`'s golden is the independently documented value used by `carrier_loop_ab.sh`, which
re-validates the address mapping and the read path.

**Three bursts captured** (t=70–77 / 190–195 / 308–314, sizes 293,183 / 215,131 / 293,183 — the same
species and phase yet again). Deviation from golden during burst seconds:

| tap | % of burst seconds deviating |
|---|---|
| cap_in (PRE-Viterbi) | **52.38 %** |
| cap_deint (PRE-Viterbi) | **52.38 %** |
| cap_out (POST-Viterbi) | **52.38 %** |

**The agreement pattern is perfect.** Over all 21 burst seconds the taps are either all three golden (10 s)
or all three deviated (11 s). **A mixed pattern never occurs.**

### VERDICT **[SILICON]**
**The burst errors are already present in the coded bits at the FEC decoder's input — i.e. at the
demodulator output.** The deinterleaver and the Viterbi are carrying damage that arrives at them, not
creating it. Had the Viterbi been the origin, `cap_in` would have stayed golden while `cap_out`
deviated; that combination occurs in **zero** burst seconds.

Together with this morning's control-path result the picture is consistent and much tighter:
the decoder receives one clean start per frame, never resets, and is handed **already-corrupted coded
bits**. The FEC decode stage is fully exonerated as the source of the beat.

### Scope and caveats — read before acting
1. **This localises the BURST, not the floor.** The caps are snapshots: 1 Hz sampling sees one frame in
   ~1246, so the 0.09 % quiet floor is not sampled adequately. Only 5 quiet seconds showed any deviation.
2. **Do not over-read the quiet mixed patterns.** Those 5 seconds break down as 3× (cap_out alone) and
   2× (cap_in alone). Three samples is far too few to claim a decoder-side floor mechanism distinct from
   the burst mechanism. It is a hypothesis-shaped noise pattern, not evidence.
3. **"Upstream of the FEC decoder" in mode 1 includes the transmitter.** `rx_input_select=0` feeds
   `Transmitter_dataOutI/Q` straight into the demod, so the modulator is inside this loop. The span now
   implicated is modulator output → demod output: matched filter, timing/carrier sync, symbol decisions,
   and the modulator itself. That is a real narrowing (it excludes FEC decode, deinterleave and the whole
   control/marker path) but it is not a single block.
4. **Why ~52 % and not ~100 %.** The caps hold only bits 1–32 while the BIST scores bits 1–120. A burst
   running ~33 err/frame across that 120-bit window leaves bits 1–32 undamaged in roughly half of sampled
   frames. The 52 % is consistent with the error density, not evidence of a 50 % duty cycle.

---
## §12 RIG RESTORED AND VERIFIED AFTER THE CAP RUN (16:07–16:08)
`bringup_r2r3.sh r3` exit 0, **ARM GATE PASS try 1**; `qpsk_tun`=1 and `lock_watchdog`=1 on both boards;
`RIG_LOCK`/`SENTINEL_STOP` cleared; sentinel relaunched by the keeper at **16:08:40** (pid 1466492),
confirmed by bracketed `pgrep`, the systemd unit count, and the log line. **No flash on either board all
day; the authorisation is unspent.** 146 touched only by the standard gated restore.

---
## §13 STATE OF THE BEAT AT END OF SESSION

**Killed today (all on silicon, all by pre-registered tests):**
1. Spurious/duplicate start pulse into the FEC decoder — 1.0000 starts/frame through 801k bit errors.
2. "Trellis restarted mid-stream" more broadly — `cnt_vit_reset` also exactly 1.0000/frame.
3. The FEC decode stage as the *origin* of the errors — the coded bits arrive already corrupted.
4. (Earlier, 08-30 00:22) delay-FIFO displacement / push-on-full.

**Also retired:** the inference chain "51 = Viterbi re-converging ⇒ fault is in the RX decode/alignment
chain". The premise held only in sim; on hardware the events occur with no restart at all.

**Positively established today [SILICON]:**
- The decoder is handed correct framing (one start per frame, no resets) and corrupted data.
- Burst damage is present at the demodulator output (`cap_in`), in lockstep with the decoded output,
  never independently — 21/21 burst seconds show all-golden or all-deviated, never mixed.
- The SSI/LVDS path is exonerated for the beat and the floor (mode 1 ≡ mode 2, burst sizes identical to
  the digit in the same session).
- The beat is deterministic and phase-locked to reset, reproduced across six captures on three days,
  four arms and two signal paths, including alternation parity.

**Surviving search space:** modulator output → demodulator output. Matched filter, timing/carrier
synchroniser, symbol decisions, and the modulator itself (mode-1 internal loopback puts the TX in the
loop, so the TX is *not* excluded on silicon — the sim exoneration does not transfer).

**Known measurement blind spots, carried forward:**
- The BIST scores only bits 1–120 of 2240 (§5); damage beyond bit 120 has never been measured.
- The caps hold only bits 1–32, and are snapshots — they localise the burst, never the 0.09 % floor.
- `cnt_dec_bits` (0x130) saturates in ~200 s at this rate; its deltas are void (§8b).

**Open questions for Travis (unchanged, both deliberately not opened):**
1. The mode-2 comb leg needs the byte/daemon path, and on 148 it is one-sided (§4c).
2. Whether the frame-beyond-bit-120 question justifies a comparator-window build.

---
## §14 STAGE-SIGNATURE WITNESS — PRE-BUILD SIM GATE: **PARTIAL (2 of 7 stages usable)**

Instrument: `two_jup/skidfix/stagesig_inject.py` adds seven per-frame rotate-XOR signatures across the RX
chain plus a per-stage mismatch counter, muxed onto 0x20C/0x210 by a new `stageSel` = fixctl[11:8].
Chosen because all seven taps are already visible in `QPSK_Rx.v` (`Frequency_and_Time_Synchronizer`
exports `postSymbolSync`/`postCarrierSync` as ports), so no inner-module edits and no BD change — a
source-only resynth suffices. fixctl bits 0–4 are untouched (0 contract, 1 ser-anchor, 2 grid-pace,
3 enSlack, 4 enSpurStart); the selector uses 11:8 to avoid arming a fix while selecting a tap.

**Pre-registered gate: on a clean run every mismatch counter must read 0.** Result of a 12-frame clean
Verilator run (`sim_stagesig.cpp`, netlist `s1_rtl_stagesig`):

| stage | signature | mismatches | usable? |
|---|---|---|---|
| 0 dataIn (RX in == **TX modulator out**) | 0xCB377972 | **0** | **YES** |
| 1 AGC out | 0xCB377972 | **0** | **YES** |
| 2 RRC matched-filter out | 0x24DF6404 | 19 | no |
| 3 postSymbolSync | 0x71F20356 | 19 | no |
| 4 postCarrierSync | 0x5EBBDAEB | 20 | no |
| 5 QPSKConstellation (demod in) | 0x848936DD | 21 | no |
| 6 demod dataOut (coded bits) | 0xDDD74259 | 21 | no |

**Why, and why this is not a surprise in hindsight:** stages 2–5 carry *soft* sample values. Residual CFO
and the timing interpolator mean the constellation rotates and the sample/frame alignment shifts slightly
every frame, so the soft values are never bit-identical frame to frame even when every hard decision is
correct. No per-frame signature of this type can cover them. Stage 6 (hard bits) *should* be invariant —
`cap_in` is 99.47 % constant on hardware — so its 21 mismatches point at a window-boundary off-by-one in
my accumulator (the strobe cycle takes the `else` branch and so skips one sample), not at the physics.

**Decision.** Build 1 goes ahead with stages 0 and 1 only, which is enough to settle the biggest open
fork: **TX vs RX.** If stage 0's mismatch counter goes nonzero during a burst, the transmitter's own output
is varying and the TX is the source. If it stays 0 through a full-magnitude burst while errors occur, the
TX output is bit-identical every frame and the fault is downstream in the RX chain. Mode-1 loopback puts
the TX inside the loop, so this is the tap that the sim exoneration of the TX could never provide.
Stages 2–6 will be reported as **UNCOVERED**, not as null results.

Build 2 (in parallel) fixes the stage-6 off-by-one so the coded-bit stream gets an *accumulating* witness.
That matters beyond this fork: an accumulating counter can measure the **0.09 % floor**, which the
`FecCapture` snapshots structurally cannot.

### 14a. Build-2 hypothesis (strobe-cycle off-by-one) — **WRONG, discarded**
Re-gated with the accumulator rewritten so the strobe-cycle sample starts the new frame instead of being
dropped. Stage 6 still reads **21 mismatches** (signatures changed, counts identical). The off-by-one was
not the cause. Recording it as dead rather than quietly moving on.

**Better hypothesis, and it matches the one instrument that provably works.** `cap_in` is 99.47 % constant
on hardware and it does NOT accumulate over the whole inter-start window — `FecCapture` counts a **bounded
window** (`xIn < 32`) from each start pulse and ignores everything after. My stage 6 accumulates *every*
validOut beat between consecutive `startOut` pulses, so if the number of coded-bit beats per window varies
by even one — inter-frame gap bits, or frame-timing jitter of a symbol — every signature differs. That is
consistent with the data and with why `cap_in` works where this does not.

### 14b. Gate 3 — bounded window (1024 beats/frame, mirroring FecCapture's `xIn<32`): **4/7 covered**

| stage | gate 1 (unbounded) | gate 3 (bounded) |
|---|---|---|
| 0 dataIn (**TX modulator out**) | 0 ✔ | **0 ✔** |
| 1 AGC out | 0 ✔ | **0 ✔** |
| 2 RRC matched-filter out | 19 ✘ | **0 ✔** |
| 3 postSymbolSync (timing recovery) | 19 ✘ | **0 ✔** |
| 4 postCarrierSync | 20 ✘ | 18 ✘ |
| 5 QPSKConstellation (demod in) | 21 ✘ | 21 ✘ |
| 6 demod dataOut (coded bits) | 21 ✘ | 21 ✘ |

The bounded window fixed stages 2 and 3, so their earlier failure was a window-length effect, not soft-value
drift — my read of *why* they failed in §14 was partly wrong and this corrects it. Stages 4 and 5 sit
downstream of the carrier synchroniser, which applies a continuously varying phase correction while
tracking residual CFO; their soft values legitimately rotate every frame and no signature of this type can
cover them. Stage 6 (hard bits) remains unexplained after two attempts; I am not trying a third theory.
It costs little: `cap_in` already covers the demod bit output on hardware at 99.47 % constant. What is lost
is only the *accumulating* form, i.e. the ability to measure the 0.09 % floor.

**Build plan, unchanged in shape.** Build 1 (in impl now) carries the unbounded RTL and so covers stages 0
and 1 — enough for the TX-vs-RX fork, which is the question worth a flash. Build 2 will carry the bounded
RTL and add stages 2 and 3, bisecting the RX chain: AGC out → RRC out → post-symbol-sync. Builds run
sequentially, not concurrently — two Vivado runs would contend for the same 12 cores.

---
## §15 BUILD PIPELINE (three images, two build hosts)

### 15a. Gate 4 — hard-decision taps: **6 of 7 stages covered**
Stages 4 and 5 were failing because they carry soft values downstream of the carrier synchroniser. Tapping
only the **sign bits of I and Q** — the decisions — instead of the full soft words, on top of the bounded
window, gives:

| stage | gate 1 | gate 3 (bounded) | **gate 4 (bounded + sign bits)** |
|---|---|---|---|
| 0 dataIn (**TX modulator out**) | 0 ✔ | 0 ✔ | **0 ✔** |
| 1 AGC out | 0 ✔ | 0 ✔ | **0 ✔** |
| 2 RRC matched-filter out | 19 ✘ | 0 ✔ | **0 ✔** |
| 3 postSymbolSync | 19 ✘ | 0 ✔ | **0 ✔** |
| 4 postCarrierSync | 20 ✘ | 18 ✘ | 18 ✘ |
| 5 QPSKConstellation (demod in) | 21 ✘ | 21 ✘ | **0 ✔** |
| 6 demod dataOut (bits) | 21 ✘ | 21 ✘ | **0 ✔** |

**Why stage 4 alone still fails, and why that is coherent rather than mysterious:** stage 4 is *before* the
phase-ambiguity correction and stage 5 is *after* it. The carrier loop leaves a residual rotation that can
carry symbols across a quadrant boundary, so the decisions at stage 4 are not stable while those at
stage 5 are. Stage 4 is bracketed by covered stages on both sides, so little is lost.

### 15b. Images
| build | RTL | coverage | host | state |
|---|---|---|---|---|
| 1 `0ce3caa2d00b` | unbounded | stages 0,1 | local | **FLASHED to 148**, all rails green |
| 2 | bounded | stages 0,1,2,3 | local | in impl |
| 3 | bounded + sign bits | stages 0,1,2,3,5,6 | **hdl-dev-2** | in synth |

Build 1 post-impl **WNS +0.149 ns**, TNS 0.000, 0 failing endpoints (the flashed pdwit image was +0.071).
Flash rails: readback `0ce3caa2d00b` verified, daemon fingerprint matched, byte plane delivering
2.56 M words/10 s, health gate **PASS on pass 1** (fsync=1259, wcnt=1259), no rollback. Banked at
`boot_known_good/BOOT.BIN.148.stagesig.0ce3caa2d00b`.

**The stage sweep printed by the flash script is NOT a measurement.** It ran post-bring-up on the *air*
link, where the RX input is the ADC and differs every frame by construction, so all seven counters climbed
(~164 k). That is the expected and uninformative reading there. The witness is only meaningful in mode-1
internal loopback.

### 15c. hdl-dev-2 — notes for the inventory
`hdl-dev-2.local` = **10.0.0.11**, 8 cores, 61 GB RAM, **Vivado 2025.1 at `/opt/Xilinx/2025.1/Vivado`**
(version-matched to the project; the local host uses `/tools/Xilinx/2025.1`). It is in `~/.ssh/config` but
**absent from `HOSTS.md`** — the canonical copy is `picard:~/dev/infra/HOSTS.md` and it should be added.
Builds run from `~/qpsk-builds/` (a `sudo mkdir` under `/mnt` was denied by the permission classifier and
was not retried; the operator chose the home-dir route).

**Relocation gotchas found and fixed** — these would have produced a failed or silently wrong build:
1. `vivado_prj.runs/` (454 MB) excluded from the copy: it holds most of the 274 stale absolute paths and
   the resynth resets every run anyway.
2. 74 project files referenced the **pdwit** root → rewritten.
3. `system.bd` and 19 other files referenced an **ancestor** root, `jupiter_byte_beatfix2_build`, including
   the BD's ROM init file `projects/jupiter_sdr/mem_init_sys.txt`. That path does not exist on hdl-dev-2, so
   the BD would have failed to resolve its mem-init. Rewritten and verified to resolve.
   **This also means the local pdwit/stagesig builds depend on `jupiter_byte_beatfix2_build` still being
   present on this machine — worth knowing before anyone deletes an old build tree.**
4. A further 16 refs pointed at the **probe4** root → rewritten. Only a cosmetic HTML report still carries
   an old path.

---
## §16 BUILD-1 HARDWARE RUN: **G1 INSTRUMENT GATE FAILED — no verdict taken**

Run `two_jup/stagesig/20260830_184558`, mode 1 internal digital loopback, ROM BIST, 400 s, image
`0ce3caa2d00b`. Lock gate normal (1245 f/s, 51 err/s). 19 burst seconds, 796,507 bit errors captured.

Per-second mismatch deltas (accumulating counters):

| stage | quiet mm/s | burst mm/s | |
|---|---|---|---|
| 0 dataIn (TX modulator out) | **11.15** | 536.89 | covered |
| 1 AGC out | 937.70 | 1087.37 | covered |
| 2 RRC out | 937.69 | 1087.42 | uncovered |
| 3 postSymbolSync | 1286.09 | 1291.32 | uncovered |
| 4 postCarrierSync | 1307.31 | 1306.89 | uncovered |
| 5 QPSKConstellation | 1307.32 | 1306.79 | uncovered |
| 6 demod bits | 10.95 | 283.89 | uncovered |

**G1 (pre-registered): stage 0's mismatch delta must be 0 on a clean link. It is 11.15/s. GATE FAILED,
so no TX-vs-RX verdict is taken from this run.**

**This is the pre-registration earning its keep.** Stage 0 jumps from 11 to 537 mismatches/s between quiet
and burst seconds — that reads exactly like "the transmitter's output varies during a burst, TX indicted",
and it would have been an easy and satisfying thing to report. But the instrument fails its own health
check on a clean link, so the burst numbers cannot be trusted, and the tempting reading is very likely the
wrong one. Stage 1 at ~938 mismatches/s in *quiet* is a second, blunter sign that this image's accumulator
is not measuring what it claims on hardware.

**Leading hypothesis, with a pre-registered prediction.** Build 1 carries the **unbounded** accumulator:
it sums everything between consecutive `QPSK_Demodulator_startOut` pulses. That window is a symbol-domain
event whose alignment against the sample-domain TX stream is set by the timing-recovery interpolator, which
genuinely drifts on hardware where it did not in the deterministic sim. Any drift changes how many samples
land in each window and so changes the signature, with the TX output still bit-identical. This is the same
failure mode that made stages 2 and 3 fail the *unbounded* sim gate and that the **bounded** window fixed.
**Prediction: builds 2 and 3, which bound the window to 1024 of each stage's own beats, will pass G1 on
hardware.** If build 2 or 3 also fails G1 with stage 0 nonzero in quiet, this explanation is wrong and I
will say so rather than patch it again.

Rig restored: bring-up exit 0, ARM GATE PASS try 1, daemons and watchdogs up on both boards.

---
## §17 STANDING AUTHORISATION AND THE REVISION LIMIT (operator, this window)

- **Flash authorised on 148 as often as the work needs**, for the rest of this window. Unchanged conditions:
  full rails every time (restore point banked and named, readback verify, two-pass health gate,
  auto-rollback) and **no retry loop** — a failed flash means roll back and stop rig work, never retry and
  never power-cycle. **146 still not to be flashed or touched.**
- **Two instrument revisions is the limit.** Build 1 was the original; build 2 (bounded window) is
  revision 1; build 3 (bounded + hard-decision taps) is revision 2. **If build 2 or build 3 shows stage 0
  nonzero in quiet, the interpolator-drift explanation is WRONG — say so, stop, and write the measurement
  approach up as a question for Travis. Do not patch the window a third time and do not reinterpret G1.**
- Priorities unchanged: (1) a trustworthy TX-vs-RX verdict from a witness that passes its own health check,
  (2) bisect downstream as far as stage coverage allows, (3) the 0.24 % vs 0.09 % header discrepancy.
  No new candidates.

**Operator note on the build-1 near-miss (§16), recorded because it belongs in the record:** stopping on
the G1 failure when stage 0's burst delta (537/s vs 11/s quiet) was exactly the dramatic answer being asked
for was, in Travis's assessment, the most valuable thing done today — that number would have indicted the
transmitter and sent the investigation down the wrong half of the chain for days. The gate stays ruthless.

---
## §18 BUILD 2: **G1 FAILED AGAIN. THE INTERPOLATOR-DRIFT EXPLANATION IS WRONG.** Stopping as pre-registered

Run `two_jup/stagesig/20260830_192752`, image `ed44769ed7aa` (bounded 1024-beat window), mode 1, 400 s.
Lock gate normal (1245 f/s, 51 err/s). 19 burst seconds, 796,271 bit errors.

| stage | quiet mm/s | burst mm/s | |
|---|---|---|---|
| 0 dataIn (TX modulator out) | **9.76** | 541.95 | covered |
| 1 AGC out | 10.82 | 543.47 | covered |
| 2 RRC out | 10.78 | 544.42 | covered |
| 3 postSymbolSync | 1101.46 | 1182.95 | covered |
| 4 postCarrierSync | 1307.75 | 1307.21 | uncovered |
| 5 QPSKConstellation | 1307.76 | 1307.16 | uncovered |
| 6 demod bits | 9.48 | 547.53 | uncovered |

**G1 fails: stage 0 = 9.76 mismatches/s on a clean link (build 1 was 11.15).** The bounded window did not
fix it. **I registered the prediction that builds 2/3 would pass G1 on hardware. They do not. The
interpolator-drift explanation is WRONG and I am stating that rather than patching it.** No verdict taken.

### 18a. Build 3 cannot fix this, and here is the proof
Build 3 (revision 2, currently routing on hdl-dev-2) changes **only stages 4 and 5** to hard-decision taps.
Its stage-0 and stage-1 taps and its window logic are **byte-identical to build 2's** — verified by direct
comparison of the generated HDL on both hosts:
```
assign sdat[0] = {dataIn_re, dataIn_im};      assign sval[0] = validIn;
if (sval[si] && sidx[si] < 16'd1024) begin
```
So **build 3 will reproduce build 2's stage-0 result exactly and cannot produce a trustworthy TX-vs-RX
verdict.** Flashing it would add stage 5/6 coverage, but with the framework's own health check failing at
stage 0 there is no basis for trusting any other stage either. Per the two-revision limit, I am stopping
and writing this up rather than building a revision 3.

### 18b. What I think is actually wrong (the question, not an action)
Both revisions bound the window's **length** (1024 of each stage's own beats). Neither anchors the window's
**phase**. The window still *starts* on `QPSK_Demodulator_startOut`, a symbol-domain event, while stage 0
is a sample-domain stream from the transmitter. If that start pulse lands even one sample earlier or later
relative to the TX frame, the 1024-sample slice shifts and the signature changes although the TX output is
bit-identical. Bounding length does not fix phase. That is a design flaw in the instrument, and it is
consistent with the failure surviving both revisions unchanged (11.15 → 9.76 mismatches/s).

Scale, for whatever it is worth: 9.76/s against 1245 frames/s is **0.78 % of frames** — the window slips
occasionally rather than continuously. I am deliberately not building on that observation; it could be an
instrument artefact or a real slip, and this instrument cannot tell the two apart. That ambiguity is
precisely the problem.

### 18c. The numbers this run WOULD have given, recorded as NOT TRUSTWORTHY
For the record only, never to be quoted: stages 0, 1, 2 and 6 all jump from ~10/s quiet to ~542–548/s in
burst, in near-lockstep, while stages 3, 4 and 5 sit flat near their (already broken) quiet values. Read
naively that says "the TX output and everything through the RX front end change during a burst". **It is
not usable**, for the same reason as build 1: the instrument fails its own clean-link health check, and a
tap that is wrong when nothing is happening cannot be trusted when something is.

Rig restored: bring-up exit 0, ARM GATE PASS try 1, daemons and watchdogs up on both boards. 148 is on
`ed44769ed7aa`; the previous images are banked in `boot_known_good/`.

### 18d. Build 3 completed on hdl-dev-2 — banked, NOT flashed
`STAGESIG3_IMAGE_DONE md5=1977cbb39877`, built 18:52–19:39 on hdl-dev-2 (Vivado 2025.1 at
`/opt/Xilinx/2025.1/Vivado`). Post-impl **WNS +0.231 ns**, TNS 0.000, 0 failing endpoints — the best of the
three (build 1 +0.149, build 2 +0.086, flashed pdwit +0.071). Copied back and banked as
`boot_known_good/BOOT.BIN.148.stagesig3.1977cbb39877`.

**Deliberately not flashed.** Its stage-0 tap is byte-identical to build 2's (§18a), so it would reproduce
the same G1 failure and cannot answer the TX-vs-RX question. Held for the operator's decision.

**Second build host is proven end to end:** relocation to a home directory worked, the ancestor-root
`mem_init_sys.txt` dependency was the only real blocker, and a full synth+impl+bitstream ran there
successfully. hdl-dev-2 can carry future builds in parallel with the local host.

---
## §19 NEW INSTRUMENT CLASS: DIRECT PER-STAGE CAPTURE (not a third window patch)

The signature approach is abandoned. It accumulated a rolling signature over a window whose **phase** was
never anchored; both revisions bounded window *length*, which was never the problem. It failed its own
clean-link gate twice on silicon (11.15 then 9.76 mismatches/s at stage 0).

**What replaced it, and why it should hold.** `FecCapture`'s `cap_in` is 99.47 % constant on hardware
because it is a **bounded capture armed by the frame start**, not a rolling signature. That discipline
demonstrably survives real hardware timing. Both new witnesses use it.

### 19a. DBGCAP — RX stages, using the design's OWN existing debug mux
No new taps. `iq_debug_mux` (**0x10C**, writable; address confirmed by the same decode arithmetic that
yields the known 0x114 for `rx_input_select`) already selects an RX stage onto `Index_Vector_out1_re/im`:

| 0x10C | stage |
|---|---|
| 0 | Automatic_Gain_Control out (sample domain) |
| 1 | postSymbolSync (timing recovery) |
| 2 | postCarrierSync (before ambiguity correction) |
| 3 | QPSKConstellationPoints (demod input) |

Its output previously went only to `debugI/debugQ`, which this lineage routes nowhere — which is why the
mux has sat unused. DBGCAP adds the readout: the first 16 symbols after each frame start captured as 32
bits of **hard decisions**, armed by `QPSK_Demodulator_startOut`, strobed by `QPSKConstellationValid`.
0x20C = capture, 0x210 = mismatches vs a frame-8 reference (accumulating, so slow polling is fine).

**Sim gate: PASS on all four taps, 0 mismatches each** — including tap 0, which I had predicted would be
uncovered. Recording that my prediction was too pessimistic; the hardware gate still decides per tap.

### 19b. TXCAP — the transmitter, anchored on the TRANSMITTER'S OWN frame start
This is the instrument the TX-vs-RX fork actually needed. Every earlier attempt anchored on
`QPSK_Demodulator_startOut` — a **receiver**, symbol-domain event — while observing the transmitter's
**sample-domain** output. Nothing forces those two to keep constant relative phase, and on hardware they
do not. TXCAP anchors on `Bit_Packetizer_dataStart` inside `QPSK_Tx`: the transmitter's own per-frame
marker, with no receiver involvement at all.

Wiring is internal only (IP top-level ports unchanged → BD untouched → source-only resynth):
`QPSK_Tx` exports `txFrameStart`; `Transmitter` passes it through; `TxRxComposite` captures the first 16 TX
samples after each start as hard decisions and counts mismatches. **fixctl bit 12** selects which witness
drives the two registers (0 = DBGCAP, 1 = TXCAP); bits 0–4 remain the fix arms and are untouched.

**Pre-registered:** if TXCAP mismatches stay 0 through a full-magnitude burst while 0x108 accumulates
errors, the transmitter's output is bit-identical every frame and **the TX is exonerated on silicon**.
If TXCAP climbs during bursts, **the TX is the source**. Either way it is a direct observation of the
transmitter, phase-locked to the transmitter.

### 19c. Why the existing ILA cannot answer this
The image carries `beat_ila` (system_ila, 16 probes, 4096 deep), `burst_onset_det` and two debug bridges
at 0x9D440000. Its probes are on the **byte/DMA plane** (`dut_data_out_*_rx`, `dut_data_in_*_rx`, byte
valid) plus the burst trigger — **not** the RX DSP chain. Repointing it at the datapath would be a
BD-level change, not a source-only resynth. Noted so nobody assumes the ILA already covers this.

### 19d. Build/gate status at 21:15
- DBGCAP: sim gate PASS; Vivado build running locally.
- TXCAP (combined with DBGCAP): sim gate running; destined for hdl-dev-2.

### 19e. Sim gates both PASS; two builds running in parallel (21:28)
```
TXCAP (TX-anchored, transmitter output)   cap=0xF00003FF mismatches=0
DBGCAP tap 1 postSymbolSync               cap=0x4464B969 mismatches=0
DBGCAP tap 2 postCarrierSync              cap=0xA1204911 mismatches=0
DBGCAP tap 3 QPSKConstellation            cap=0xBCF94856 mismatches=0
TXCAP_GATE PASS (0/4 witnesses not frame-invariant)
```
(DBGCAP tap 0, AGC out, also gated at 0 in its own run — better than I predicted; the hardware gate still
decides per tap.)

| build | contents | host | started |
|---|---|---|---|
| DBGCAP | RX stage captures via `iq_debug_mux` | local | 21:14 |
| COMBINED | DBGCAP **+** TXCAP (fixctl[12] selects) | hdl-dev-2 | 21:28 |

**Plan for the night.** Flash DBGCAP first and sweep the RX stages; then flash COMBINED and repeat with
TXCAP included. Two flashes rather than one, deliberately: it gets the RX-stage answer ~45 min sooner and
leaves a usable result if the combined image has a problem. Every flash keeps full rails and the no-retry
rule.

Runner `two_jup/dbgcap_run.sh` and scorer `two_jup/score_dbgcap.py` are written and syntax-checked ahead of
time. The runner logs, per second: frames, bit errors, the TXCAP mismatch counter, all four DBGCAP tap
mismatch counters, and the three `FecCapture` snapshots — so one 400 s pass covers the entire chain.

**H1 is applied PER WITNESS**, which is the lesson from the two signature failures: any witness that is not
constant on a clean link is marked UNCOVERED and its burst numbers are discarded, rather than the run being
thrown away or (worse) read anyway. **H2**: among H1-passing witnesses, the first to move during bursts,
in chain order TXCAP → AGC → postSymbolSync → postCarrierSync → constellation → cap_in → cap_deint →
cap_out, is where the error first appears.

---
## §20 **THE ERROR FIRST APPEARS BETWEEN THE CONSTELLATION DECISIONS AND THE FEC INPUT** [SILICON]

Run `two_jup/dbgcap/20260830_222652`, image `0daa708f5e79` (DBGCAP), mode 1 internal digital loopback,
ROM BIST, 400 s. Lock gate normal (1245 f/s, 51 err/s). **Three full-magnitude bursts captured**
(291,273 / 213,464 / 291,287 bit errors; 796,024 total over 20 burst seconds).

**H1 coverage gate: ALL FOUR RX witnesses PASS** — 0.00 mismatches/s on a clean link. This is the first
instrument in this campaign to pass its own health check on hardware, and it does so because it is a
bounded frame-armed *capture*, the `cap_in` pattern, rather than a rolling signature.

| witness | quiet mm/s | burst mm/s | H1 |
|---|---|---|---|
| AGC out | 0.00 | **0.00** | PASS |
| postSymbolSync | 0.00 | **0.00** | PASS |
| postCarrierSync | 0.00 | **0.00** | PASS |
| QPSKConstellation (demod **input**) | 0.00 | **0.00** | PASS |
| `cap_in` (demod **output** / FEC in) | 100.0 % golden | **45.0 % golden** | PASS |
| `cap_deint` | 100.0 % golden | 45.0 % golden | PASS |
| `cap_out` (post-Viterbi) | 100.0 % golden | 45.0 % golden | PASS |

All four DBGCAP mismatch counters read **0 at the first sample and 0 at the last** — they never increment
once, across the entire run and all three bursts. Per burst: `mm_delta(AGC, symsync, carrier, const) =
[0,0,0,0]` while `cap_in` deviates in 4/8, 3/5 and 4/7 seconds respectively, taking assorted non-golden
values (0x7871AA08, 0x70DF4D74, 0xF6A4BC60, …).

### The localisation
Everything from the RX input through the **demodulator's input** is bit-identical every frame, straight
through bursts of ~291,000 bit errors. The coded bits at the **FEC decoder's input** are not. **The error
first appears in the span between the constellation decisions and the FEC input** — i.e. inside the
demodulator's slice/serialise path and the marker logic immediately after it.

Note the two windows cover the same region: DBGCAP captures 16 symbols = 32 coded bits (QPSK), `cap_in`
captures 32 coded bits, both from the same frame marker.

### Consequence: the transmitter is exonerated, and so is the whole RX front end **[SILICON]**
AGC out is invariant through bursts, so the samples entering the receiver do not change — which exonerates
the **transmitter** (mode-1 loopback puts it inside the loop). postSymbolSync, postCarrierSync and the
constellation decisions are invariant too, so **timing recovery, carrier recovery and phase-ambiguity
correction are all exonerated as the source.** TXCAP will confirm the TX half directly on the next image.

### Two readings, and the test that separates them — NOT yet distinguished
- **(A) values change**: the demod's slicing/serialisation emits different bits from identical decisions.
- **(B) position shifts**: the bits are right but `cap_in`'s window moves, because `cap_in` is anchored on
  the **FEC** `startIn` (`startSel`, via BfContract) while DBGCAP is anchored on
  `QPSK_Demodulator_startOut`. A shift of the FEC start marker relative to the bit stream would make
  identical bits read as a changed capture.

**(B) is what the campaign's own 2026-08-20 ILA already reported: "value-perfect coded bits at a shifted
sequence position at/before the FEC input."** That independent evidence and this result agree, which makes
(B) the stronger candidate — but this run does not distinguish them and I am not asserting one.

**The discriminating test is small and unambiguous:** capture the demod's output bits anchored on
`QPSK_Demodulator_startOut` (DEMODCAP) and compare against `cap_in`, which is anchored on the FEC start.
Same bits, two anchors. If DEMODCAP stays golden while `cap_in` deviates → the FEC start marker moves,
reading (B). If both deviate → the bit values change, reading (A). Building that next.

---
## §21 COMBINED IMAGE FAILS H1 WHERE DBGCAP PASSED — discrepancy, not a result

Run `two_jup/dbgcap/20260830_224536`, image `4abe8c4563a2` (COMBINED = DBGCAP + TXCAP), same runner,
same mode, 400 s, 20 burst seconds, 796,046 bit errors.

| witness | quiet mm/s | burst mm/s | H1 |
|---|---|---|---|
| TXCAP | 1.11 | 1.05 | **UNCOVERED** |
| AGC out | 22.86 | 582.80 | **UNCOVERED** |
| postSymbolSync | 22.83 | 583.35 | **UNCOVERED** |
| postCarrierSync | 22.83 | 583.35 | **UNCOVERED** |
| QPSKConstellation | 22.83 | 583.35 | **UNCOVERED** |
| cap_in / cap_deint / cap_out | 100/99.5/99.7 % golden | 45 % golden | PASS |

**No verdict taken from this run** — every mismatch witness fails its clean-link gate. The `FecCapture`
snapshots agree with every previous run (45 % golden in bursts), which is reassuring about the rig and the
burst itself, but says nothing about the new witnesses.

**The problem is that the DBGCAP RTL is IDENTICAL in both images**, and in the `0daa708f5e79` run those
same four counters read **0.00/s** in quiet. An instrument that passes on one image and fails on another
with the same logic is not yet trustworthy on either, so this has to be explained before §20 is leaned on.

**The only procedural difference is the runner.** With `HAVE_TXCAP=1` it writes `fixctl` twice per second
(0x1000 to select TXCAP, then 0x0) around the tap reads; with `HAVE_TXCAP=0` (the §20 run) `fixctl` was
written once at arm and never touched during the poll. The quiet failure is also suspiciously uniform —
22.86 / 22.83 / 22.83 / 22.83 across four independent counters — which looks like one shared disturbance
per read cycle rather than four independent datapath effects. ~22.8/s against ~1245 frames/s is ~1.8 % of
frames.

**Cheap discriminator, no build: re-run the SAME COMBINED image with `HAVE_TXCAP=0`.**
- H1 passes → the `fixctl` write during polling is the disturbance. §20 stands (it never toggled fixctl),
  and TXCAP must be read differently — e.g. once at the end of a run rather than every second.
- H1 still fails → the image itself differs and §20 needs re-examination on its own image.

Running that now rather than choosing which result to believe.

---
## §22 **§20 IS WITHDRAWN.** The discriminator says the fixctl toggle was not the cause — and the DBGCAP counters were most likely DEAD in that image

Re-ran the **same** COMBINED image with `HAVE_TXCAP=0`, so `fixctl` was never written during the poll —
the one procedural difference from the §20 run. Result: **H1 still fails at 22.68 mismatches/s in quiet.**
So the fixctl write was not the disturbance, and the two images genuinely differ.

Raw counter values settle which way it differs:

| image | DBGCAP counters, first sample | last sample |
|---|---|---|
| `0daa708f5e79` (DBGCAP, the §20 run) | `[0, 0, 0, 0]` | **`[0, 0, 0, 0]`** |
| `4abe8c4563a2` (COMBINED) | `[3779, 3781, 3787, 3793]` | `[24153, 24156, 24162, 24168]` |

In the §20 image the four counters are **zero at every one of the 400 samples and never increment once**,
through three full-magnitude bursts. In the COMBINED image, with identical DBGCAP RTL, they increment
continuously. **A counter that is stuck at zero passes H1 trivially and reads zero through bursts too** —
which is exactly the §20 result.

**So the most likely reading of §20 is not "all four RX stages are frame-invariant" but "the counters were
dead in that image".** I cannot currently distinguish those two, and the honest position is that
**§20's localisation is withdrawn and must not be relied on.**

### The rule I failed to apply to my own instrument
The handoff's own standing rule, from the injector failure: *"an injector or witness must prove it fired —
count the events and print the count — before any null result means anything."* Every sim gate I ran for
DBGCAP was a **clean** run, so all of them expected zero. **I never once demonstrated that the DBGCAP
mismatch counter is capable of incrementing.** A dead counter passes every gate I wrote. That is the same
class of error as the five no-op injections in §3 of the handoff, committed by me, on my own instrument,
after quoting the rule back in §14.

### What would settle it, cheaply
The runner logs only `0x210` (the counter) for each tap, not `0x20C` (the capture itself). If `0x20C`
holds a plausible non-zero, constant pattern then the capture block is alive and a zero counter is
meaningful; if `0x20C` reads zero, the block is dead and §20 collapses outright. **The FINAL image
(`0f203cf887d3`, built and gated, carrying DBGCAP + TXCAP + DEMODCAP) should be flashed with a runner
extended to log `0x20C` alongside `0x210`** — that provides the positive control and the DEMODCAP
discrimination in one pass.

### What still stands, unaffected
The `FecCapture` results are independent of all of this and reproduce across every run tonight
(cap_in/cap_deint/cap_out at 99.5–100 % golden in quiet, 42–45 % in bursts), as does §11's finding that
burst damage is already present at the demod output. §16/§18 (both G1 failures) and §5 (the 120-bit
comparator window) are likewise untouched.

---
## §23 POSITIVE CONTROL PASSES — the counter is ALIVE, and it exposes a design flaw in how I was USING it

Image `0f203cf887d3` (FINAL), mode 1, 2026-08-31 06:46. Arm sets `iq_debug_mux=0` before the soft reset.

```
  PC tap3 cap=0xBCF94856 mm=0x1D63
  PC_PARK   tap3 delta_over_5s=6228     (1245.6/s == exactly one per frame)
  PC tap0 cap=0x121D8572 mm=0x35C0
  PC_SWITCH tap0 delta_over_5s=6        (~1.2/s)
  PC_BACK   tap3 delta_over_5s=6229
  TXCAP    cap=0xF00003FF mm=0x6E
  DEMODCAP cap=0x8F9ED095 mm=0xEE1
```

**The counter is alive and exact.** It increments precisely once per frame when the capture differs from
the reference — 6228 in 5 s at 1245.6 frames/s. And the capture values match the **simulation** gate
byte-for-byte: tap 3 `0xBCF94856`, tap 0 `0x121D8572`, TXCAP `0xF00003FF`, DEMODCAP `0x8F9ED095`. Silicon
and sim agree on every witness. **This is the non-null demonstration §0 requires**, and it retroactively
confirms that the §20 image's all-zero counters were dead: this same RTL, exercised the same way, moves.

### The flaw: ONE global reference, not one per tap
`dcref` is latched once at frame 8 against whatever tap `iq_debug_mux` selected then — tap 0 here. So the
counter answers *"does the current capture differ from **tap 0's** frame-8 pattern"*, not *"is the selected
tap frame-invariant"*. Parking on tap 3 therefore mismatches on **every** frame (its pattern simply is not
tap 0's), which is exactly the 1245.6/s observed, and parking on tap 0 gives ~1.2/s.

**Consequence: every run that SWEPT the tap during the poll produced meaningless DBGCAP columns** — that
includes §21 and the §22 re-run. Their 22.7/s was an artefact of readout switching, not a datapath
property. It also means I cannot rescue §20 from its own data; the withdrawal in §22 stands, now for a
second independent reason.

### The fix is procedural, not another build
The instrument is sound if the tap is **fixed for the whole run**, set before the soft reset so the
reference is that tap's own pattern, and never touched during the poll. Then the counter means what H1/H2
need. No RTL change, no flash — four runs, one per tap.

`TXCAP` and `DEMODCAP` carry their own independent references (`txcref`, `mdcref`) that do not depend on
the mux, so they are valid in any run; their per-second rates still need measuring properly.

**[SILICON, established]** the DBGCAP/TXCAP/DEMODCAP capture blocks are alive on hardware and agree with
simulation. **[NOT established]** any per-stage localisation — that needs the fixed-tap runs, next.

---
## §24 capTAP GOLDEN-CONSTANCY — tap 3 (demod INPUT) **DOES deviate during bursts** [SILICON]

Run `two_jup/tap/20260831_072106`, image `0f203cf887d3`, mode 1, 400 s, 20 burst seconds, 795,908 bit
errors. Tap verified applied this time: `capTAP=0xBCF94856`, which is tap 3's pattern and matches the
simulation gate byte-for-byte.

Scored by **golden-constancy** (modal value of the tap's own quiet samples), which needs no on-chip
reference and so avoids both faults in §23:

| witness | quiet % golden | burst % golden | K1 |
|---|---|---|---|
| **capTAP tap 3 — QPSKConstellation (demod IN)** | 99.7 % | **45.0 %** | PASS |
| cap_in (demod OUT / FEC in) | 100.0 % | 50.0 % | PASS |
| cap_deint | 99.7 % | 50.0 % | PASS |
| cap_out (post-Viterbi) | 98.9 % | 50.0 % | UNCOVERED (98.9 < 99) |

**This inverts the withdrawn §20.** That section claimed the constellation decisions at the demodulator's
input were invariant through bursts and the error therefore entered at or after the demodulator. Measured
properly, **the demod input deviates in 55 % of burst seconds** — the error is already present *before*
the demodulator. §20 was not merely unproven, it was wrong, exactly as a dead counter would make it.

Also relevant: the accidental tap-0 measurement in run `20260831_071043` (which believed it was on tap 3
but was actually on tap 0, per §23) scored **AGC out at 99.7 % quiet → 47.6 % burst** — deviating too. If
the four-tap sweep confirms that, the error is present at the very input of the RX chain, which points
back at the transmitter or the loopback path itself rather than anything in the receiver.

**Next:** the four-tap sweep (`multitap_run.sh`, running) gives AGC out, postSymbolSync, postCarrierSync
and constellation on one arm, each held for a full 400 s dwell and scored the same way. If every tap
deviates, the remaining question is the transmitter, and TXCAP must be scored by capture-constancy
(0x20C held under fixctl[12]) rather than by its frame-8 mismatch counter.

---
## §25 THE BURST IS A DETERMINISTIC RECURRING STATE, NOT NOISE [SILICON]

Re-analysis of the existing `multitap/20260831_074947` captures. **No new rig time, no new
image** — the same rows §24 scored by golden-constancy, asked a different question.

### The question golden-constancy cannot answer
Golden-constancy asks "did this second match the modal quiet value". Correct data arriving at
the wrong *phase* and genuinely *corrupted* data both answer "no", so the ~48 % figure cannot
distinguish them.

The first replacement question — are burst values drawn from the set of values quiet also
produces — turned out **degenerate on this instrument** and its verdict must not be used. The
capture is one 32-bit word latched at one phase, so the quiet repertoire is 1–5 values; a phase
shift lands on a sample position quiet never captured and scores "novel" *exactly* like
corruption. `score_repertoire.py` still prints the `in-rep`/`%novel` columns; **ignore them.**

### What does discriminate: determinism
Random corruption cannot reproduce an identical 32-bit word — that is a 2⁻³² coincidence per
collision. So the diagnostic is whether the non-golden words repeat.

| witness | non-golden | distinct | recurring | recurrence (poll iterations) |
|---|---|---|---|---|
| tap 0 AGC out | 10 | 7 | 60 % | 235, 235, 235 |
| tap 1 postSymbolSync | 13 | 7 | 92 % | 234, 235 ×5 |
| tap 2 postCarrierSync | 10 | 7 | 60 % | 235, 235, 235 |
| tap 3 constellation | 14 | 8 | 86 % | 234, 235 ×5 |
| cap_in | 46 | 7 | 100 % | 234 ×2, 235 ×16 |
| cap_deint | 47 | 8 | 98 % | 234 ×2, 235 ×16 |
| cap_out | 47 | 7 | 100 % | 234 ×2, 235 ×17 |

Seven to eleven distinct words per witness, most recurring, at a fixed interval — and the *same*
words recur across different tap dwells minutes apart. **The burst is a state the system
re-enters on a schedule, not noise injected into it.** [SILICON]

### The interval, in the unit the hardware counts in
**The `t` column is poll iterations, not seconds.** Each loop does `sleep 1` *plus* eight
debugfs `direct_reg_access` accesses, so an iteration is ~1.0325 s (400 iterations per 413 s of
wall clock). "235 s" would be wrong by 1.3 %.

Measured directly from the frame counter, the recurrence is **298,945 ± 25 frames**, agreeing
across all four taps to better than 0.02 % — the instrument-independent number, and the one to
quote. At the measured 1232 f/s that is **~242.6 s**, against the ~239.5 s quoted earlier from
wall-clock timing on a different instrument. The frame count is the more precise figure; the
earlier one should not be treated as a conflicting measurement.

### What this does NOT establish
Recurrence proves determinism, nothing more. A deterministic *state* — a counter reaching a
value, a FIFO occupancy, an AGC gain step — reproduces identical words at the beat period just
as faithfully as a phase offset does. **Position-vs-values remains OPEN.** T6's lag scoring on
the raw DDR capture is still the discriminator; this result strengthens the case for it rather
than pre-empting it.

### Standing rule added: the anchor boundary
**Witnesses with different capture anchors are not comparable, and a chain cannot be bisected
across an anchor boundary.** TXCAP is TX-anchored; every deviating witness is RX/demod-anchored.
So "TXCAP clean, AGC out deviates" does **not** place the defect between the transmitter and the
AGC — a shift in the RX capture anchor moves every RX witness at once while leaving TXCAP
untouched. This sits beside §0 as a rule about instruments, not about this defect.

Script: `two_jup/score_repertoire.py` (commit `d08e097`).

---
## §26 INSTRUMENT FAULT: THE CAPTURE REGISTER CAN BE READ MID-FILL [SILICON]

Found while replicating §25. **Some non-golden capture words are not signal at all** — they are
the capture register read before it finished filling.

Every low-magnitude non-golden word in both runs is *exactly* a low-bit prefix of a word the
same witness produces in full:

| witness | partial word | equals |
|---|---|---|
| cap_in | `0x0006F3E2` | `0x5216F3E2 & (2¹⁹−1)` |
| cap_in | `0x000033E2` | `0x5216F3E2 & (2¹⁴−1)` |
| cap_in | `0x00000062` | `0x5216F3E2 & (2⁷−1)` |
| cap_in | `0x0000017D` | `0x63F21D7D & (2⁹−1)` |
| cap_deint | `0x0039CE5C` | `0x52B9CE5C & (2²²−1)` |
| cap_deint | `0x00000E5C` | `0x52B9CE5C & (2¹²−1)` |
| cap_deint | `0x0000005C` | `0x52B9CE5C & (2⁷−1)` |
| cap_out | `0x00122282` | `0x04922282 & (2²¹−1)` |
| cap_out | `0x00000082` | `0x04922282 & (2⁸−1)` |

Arbitrary widths — 7, 8, 9, 12, 14, 19, 21, 22 bits — which is the signature of a shift register
filling LSB-first and being sampled part-way. Not a torn AXI beat (that would cut on a fixed
boundary).

**Rule: a capture word whose top byte is zero is suspect and must be excluded before scoring.**
Two of these landed in *quiet* seconds (`t=77`, `t=262`, err=51), so they inflate burst counts
**and** depress the quiet golden fraction — they plausibly explain the 99.7 % rather than 100.0 %
quiet figures in §24 and §25.

`0x00000000` is **not** classified here. It matches a prefix of anything and is more likely a
genuine "capture not armed / not started" read; it is excluded as suspect but not explained.

### §25 re-scored with partial fills removed
The correction strengthens §25 — the discarded words were all singletons:

| witness | non-golden | partial | genuine | distinct | recurring |
|---|---|---|---|---|---|
| tap 0 AGC out | 10 | 0 | 10 | 7 | 60 % |
| tap 1 postSymbolSync | 14 | 1 | 13 | 7 | 92 % |
| tap 2 postCarrierSync | 10 | 0 | 10 | 7 | 60 % |
| tap 3 constellation | 15 | 1 | 14 | 8 | 86 % |
| cap_in | 49 | 3 | 46 | 7 | **100 %** |
| cap_deint | 51 | 5 | 46 | 7 | **100 %** |
| cap_out | 57 | 9 | 48 | 8 | 98 % |

(taps 0 and 2 sit at 60 % only because their dwells caught fewer burst seconds — 7 distinct
words in 10 occurrences leaves little room to repeat.)

---
## §27 THE BURST STATE REPRODUCES ACROSS RESET CYCLES [SILICON]

Independent replication of §25 on a **different run, 3 h 42 m later, through its own arm and
reset**: `measure/20260831_113104` (11:31) against `multitap/20260831_074947` (07:49). The
`cap_in`/`cap_deint`/`cap_out` columns are the same instruments in both.

- Golden words **identical** in both runs for all three witnesses.
- Of run B's burst occurrences, **86 % (cap_in), 93 % (cap_deint), 100 % (cap_out)** use a word
  already seen in run A.
- Shared distinct words: 7, 7, 8. Every run-B word not in run A is a §26 partial fill.

So the burst is not merely deterministic *within* a session — **the system re-enters the same
small set of states across separate resets**, consistent with the beat being phase-locked to
reset. A defect driven by thermal drift, RF conditions, or any stochastic process cannot produce
byte-identical 32-bit words across two sessions hours apart.

### Third run: the burst state space is CLOSED
Added `tap/20260831_072106` (07:21, its own arm — earlier than both runs above), scored the same
way. Across **all three runs spanning 4 h 10 m and three separate arms**:

| witness | golden | distinct words A / B / C | union | run-C occurrences using a run-A word |
|---|---|---|---|---|
| cap_in | `0x5216F3E2` (all three) | 7 / 7 / 7 | **7** | **100 %** |
| cap_deint | `0x52B9CE5C` (all three) | 7 / 7 / 7 | **7** | **100 %** |
| cap_out | `0x04922282` (all three) | 8 / 7 / 7 | **8** | **100 %** |

**The union does not grow.** A third independent run contributed **zero** new words. The burst
does not sample from a large space of corrupted values — it visits a **closed set of 7–8 states**,
re-entered identically after every reset.

**Still open:** this constrains the *mechanism* (a deterministic state machine over a small closed
state space, not noise) but not the *location*, and it does not settle position-vs-values. T6 lag
scoring remains the discriminator.

---
## §28 ANCHOR-ONLY WINDOW DISPLACEMENT IS EXCLUDED [SILICON, analysis of existing captures]

`capTAP`/`cap_*` hold **the first 16 symbols after each frame start, as 32 bits of hard
decisions** (`dbgcap_inject.py`). If the *only* thing a burst did was move the capture anchor by
k symbols while leaving the symbol stream intact, the burst word would be a displaced copy of
the golden word and the two would still share 2·(16−k) bits.

Tested against every genuine (non-§26) distinct burst word, all four taps and all three FEC
capture points, both bit orders, both shift directions:

| shift range | bits that must agree | words matching | expected by chance |
|---|---|---|---|
| k ≤ 4 | ≥ 24 | **0 / 51** | 0.00 |
| k ≤ 8 | ≥ 16 | **0 / 51** | 0.00 |
| k ≤ 12 | ≥ 8 | **0 / 51** | 1.06 |
| k ≤ 15 | ≥ 2 | 28 / 51 | 68.0 |

> ### ⚠ THIS SECTION'S AMENDMENT WAS ITSELF WRONG — see §34
> An amendment here claimed the window spans ~1.45 symbols because the valid runs at 11× the
> symbol rate. **That was wrong**: the "11×" came from a bad frame constant (§34). The valid fires
> **once per symbol**, so this section's ORIGINAL statement is correct as first written —
> displacement **≤ 8 symbols** is excluded, k ≤ 12 disfavoured, k ≥ 16 untested. The actual
> displacement is ≈6,176–6,432 symbols (§31, §34), far outside what this test could see.

**Anchor-only displacement of an intact symbol stream is excluded for k ≤ 8 strobes (≈0.73
symbols)**, disfavoured to k ≤ 12 strobes, and **untested for k ≥ 16 strobes (≈1.45 symbols)** —
beyond that the windows no longer overlap, so no evidence can exist in this instrument.

### This does NOT favour value-corruption
A timing slip *upstream* of the capture point changes the hard decisions themselves rather than
merely moving the window, and therefore leaves **no overlap at all** — indistinguishable from
corruption on this instrument. The 2026-08-20 ILA note ("value-perfect coded bits at a shifted
sequence position at/before the FEC input") describes exactly that class. So §28 eliminates one
specific mechanism; it does not move position-vs-values toward "values". **T6 lag scoring remains
the discriminator** — this narrows what T6 must distinguish, it does not replace it.

One line of weak supporting evidence: distinct burst words go 7 → 7 → 8 across
cap_in → cap_deint → cap_out. Corruption growing through the chain would fan out; a deterministic
state re-entered holds flat. It holds flat.

### Standing rule added: a shift test must state its bit overlap and its null
At k = 15 only 2 bits need to agree, so the unfiltered test reported **28/51 "matches" against a
chance expectation of 68** — *fewer* than chance, i.e. pure noise that reads as a positive result.
I nearly published it. **Any shift/overlap test must quote the number of bits required to agree
and the expected count under the null, or it manufactures its own answer.** This sits beside §0
and the §25 anchor-boundary rule as a rule about method, not about this defect.

---
## §29 QPSK PHASE-AMBIGUITY ROTATION EXCLUDED; THE BURST WORDS LOOK LIKE UNRELATED WINDOWS

Two further tests on the closed 7–8 word state set of §25/§27. Both are analysis of existing
captures — no rig time.

### Test 1: is a burst word a uniform symbol relabelling of the golden word?
A QPSK phase-ambiguity slip rotates every symbol by the same quadrant, which on 2-bit hard
decisions is a uniform relabelling of the symbol alphabet. The chain contains a `Phase_Ambiguity`
block and the beat is phase-locked to reset, so this was a live candidate.

All 24 permutations of the 2-bit alphabet, applied uniformly to all 16 symbols, against every
genuine burst word of every witness:

**0 of 51 words explained.** A match requires all 32 bits to agree; chance is 51·24·2⁻³² ≈ 3·10⁻⁷,
so a real global rotation would have been found with certainty. **A global phase-ambiguity
rotation is excluded.** (The test is independent of symbol packing order — relabelling 2-bit
fields commutes with their arrangement — but it assumes 2-bit alignment, which holds.)

It does not exclude a rotation that *begins part-way through* the window.

### Test 2: what do the burst words look like relative to golden?
| witness | Hamming distance from golden, of 32 | burst-word pairs linked by a relabelling |
|---|---|---|
| tap 0 AGC out | 10, 14, 15, 15, 15, 16, 19 | 0 of 21 |
| tap 1 postSymbolSync | 14, 15, 15, 15, 16, 17, 19 | 0 of 21 |
| tap 2 postCarrierSync | 14, 14, 15, 15, 16, 17, 17 | 0 of 21 |
| tap 3 constellation | 9, 15, 15, 16, 17, 17, 18, 19 | 0 of 28 |
| cap_in | 12, 14, 16, 16, 17, 19, 20 | 0 of 21 |
| cap_deint | 12, 13, 14, 15, 16, 16, 24 | 0 of 21 |
| cap_out | 13, 14, 14, 14, 15, 16, 17, 17 | 0 of 28 |

Two independent random 32-bit words differ in **16.0** bits on average. Every witness clusters on
15–16. **Each burst word looks like an unrelated 16-symbol sequence, not a damaged copy of the
golden one** — and none is a relabelling of any other.

### What this suggests, and what would test it
A small number of **large discrete displacements** of the capture window fits all of it: a
displacement of ≥16 symbols yields no overlap (so §28's test was blind to it by construction),
produces an unrelated-looking word (Hamming ≈ 16), and a handful of discrete displacement values
produces a closed set of 7–8 words that never grows.

This is a hypothesis, not a result. It is **testable offline**: the simulator reproduces the
hardware capture byte-for-byte (DBGCAP tap3 `0xBCF94856`, TXCAP `0xF00003FF`, DEMODCAP
`0x8F9ED095`). Dump the hard-decision word for capture windows anchored at every offset across a
frame and check whether the seven observed burst words appear in that set. If they do — and at
which offsets — position-vs-values is settled without waiting for the DDR image.

---
## §30 THE §29 SIM TEST FAILED ITS POSITIVE CONTROL — no offset sweep was run

Attempted the offline test §29 named: dump the hard-decision symbol stream at the constellation
tap and recompute the capture word for every window anchor. **It did not get that far, and the
result is being recorded as a failure rather than a null.**

Built an isolated harness (`sim_hyp.cpp`, `wrap_byte_hyp.v`, netlist copy `s1_rtl_hyp`, object dir
`obj_hyp` — no shared file with either running agent) and dumped selector 6 (QPSKConstellation
points, demod input) for 22 frames: 270,980 valid beats.

**Positive control: reproduce the known golden word `0xBCF94856` from the dumped stream.**
Tried every frame in the run × 11 sample phases × I/Q order × sign convention × bit packing —
528 combinations, null 1.2·10⁻⁷.

**Result: NO MATCH.** The stream as captured cannot reproduce the value the same tap reports on
silicon and in the DBGCAP sim. **Per §0 the offset sweep was therefore not run** — a witness that
cannot produce the known-correct answer cannot be trusted to produce a null, and a "no offset
found" result from this harness would have been worthless. The §29 hypothesis (large discrete
window displacement) stands **untested**, not refuted.

### What the attempt did establish [SILICON-EQUIVALENT SIM]
**Selector 6's `ddrcap_valid` fires 12,320 times per frame against 1,120 symbols per frame
(2240 bits ÷ 2) — exactly 11 beats per symbol.** Consecutive captured values *differ* (run-length
histogram: 270,974 runs of length 1 out of 270,977), so this is not one held symbol value sampled
11 times; the capture records 11 distinct values per symbol.

This independently corroborates the Task 2 review's blocking finding (a)/(b): the symbol-domain
taps are qualified by a valid that does not correspond to their own data rate, and nothing in the
existing gate could see it — marker counts are frame-rate and the non-zero check is blind to
over-sampling. **11× over-sampling on the tap whose lag is the measurement would have destroyed
T6's lag scoring**, and would have done so silently.

Likely causes of the positive-control failure, in order: the capture point behind DBGCAP tap 3 is
not the node ddrcap selector 6 samples; or the 11× over-sampling means no single beat per symbol
is the settled constellation value. Both must be resolved before this test can be retried.

**Do not retry the offset sweep until the harness reproduces `0xBCF94856`.**

---
## §31 **POSITION, NOT VALUES — the burst capture window is displaced ≈561–585 symbols** [SIM, positive-controlled]

The §29/§30 test, retried with a corrected reading of the instrument, and it lands.

### Why §30 failed and this does not
DBGCAP captures **16 consecutive `QPSKConstellationValid` strobes** after frame start — not 16
symbols. §30 decimated by 11 (one beat per symbol) and so reconstructed a window the instrument
never takes. Reading 16 *consecutive* strobes instead:

**Positive control: `word(mark+1) == 0xBCF94856` — the known silicon golden value — at every one
of the 22 simulated frames.** Decode fixed by that control: 16 consecutive strobes, MSB-first
(symbol 0 in bits 31:30), symbol = `{sign(I), sign(Q)}`, 0 = non-negative. Null 7·10⁻⁷.

### The sweep
Every window anchor across the whole stream (270,964 anchors, 22 frames), looking for the eight
burst words tap 3 produces on silicon. Null = 8 · 270,964 · 2⁻³² = **5·10⁻⁴**.

| burst word | seen on silicon | offset (strobes) | symbols | fraction of frame |
|---|---|---|---|---|
| `0x0AA4D2D3` | 2 | 6176 | 6176 | 0.5013 |
| `0xD8A04817` | 2 | 6240 | 6240 | 0.5065 |
| `0xD71F70D3` | 2 | 6299 | 6299 | 0.5113 |
| `0x6B47D467` | 2 | 6363 | 6363 | 0.5165 |
| `0x93E1A9FA` | 2 | 6432 | 6432 | 0.5221 |
| `0xBFED37AC` | 2 | **not found** | | |
| `0xD748FC96` | 1 | **not found** | | |
| `0x41800000` | 1 | **not found** | | |

Each found word sits at **one** offset, **identical in all 22 frames**. Gaps between the five
offsets: 64, 59, 64, 69 strobes (≈5.4–6.3 symbols).

> ### ⚠ UNITS — see §34. One strobe = ONE SYMBOL.
> The displacement is **≈6,176–6,432 symbols ≈ 0.50–0.52 of a frame**. Two earlier attempts to
> restate this (a "not established" caveat, then a divide-by-11) were both wrong; §34 traces both
> to a single bad constant. The **fraction of the frame never changed** and is the figure to trust.

### What is settled
**At the demod input, during bursts, the capture window is anchored ≈0.50–0.52 of a frame later
than in quiet (≈6,176–6,432 symbols — see §34 for the unit), and the symbol values at that displaced position are bit-exact matches to
what the simulator produces there.** The data is right; the position is wrong. **This is position,
not corruption, at this tap** — and it confirms the 2026-08-20 ILA reading, "value-perfect coded
bits at a shifted sequence position at/before the FEC input".

Frame = 12,320 strobes = 12,320 symbols (§34). The displacement straddles half a frame (0.5013–0.5221)
and is **spread over 256 strobes** — it is *not* a clean half-frame. Report the five values;
whether the quantum is ~6 symbols is T6's question, not an assertion to make now.

### What is NOT settled
- **Three of eight words are unexplained.** The sweep covered every within-frame offset and every
  simulated frame is identical, so coverage is complete: those three correspond to **no**
  within-frame displacement. `0x41800000` is *not* a §26 partial fill (no full word explains it
  with low bits cleared, and it is the only tap-3 word with a zero low byte) — it is unexplained,
  not dismissed. Five of eight is **not** "explained".
- **This is a per-tap result.** `cap_in`/`cap_deint`/`cap_out` are FEC-anchored and were not swept.
  Per the §25 anchor-boundary rule the conclusion **cannot** be carried across to them without
  repeating the test on their own anchor.

### Consequence for Task 6 — act on this before building
**Lag scoring over a ±few-sample window will not see a 561-symbol displacement.** T6's search
range must cover at least a full frame, or the instrument will be built with the answer outside
its range and will return a confident null.

---
## §32 THE DISPLACEMENT **GROWS MONOTONICALLY** WITHIN A BURST, AND THE TWO BURST FAMILIES INTERLEAVE

Mapping every tap-3 burst second of `multitap/20260831_074947` onto its §31 offset.

### Burst onsets and the two families
Bursts begin at **t = 35, 153, 269, 387** — every **~117 poll iterations**, not 235. The §25
recurrence of 235 is **two** burst periods, because consecutive bursts are **different families**
that visit **different offsets**. This is the long-known "BIG sml BIG sml" alternation, now with a
mechanism attached.

| family | bursts at t | offsets visited (strobes) |
|---|---|---|
| **A** | 35, 269 | 6176 → 6299 → 6432 |
| **B** | 153, 387 | 6240 → 6363 → (`0xBFED37AC`, unmapped) |

The two families **interleave**: 6176 · **6240** · 6299 · **6363** · 6432, A and B about **64
strobes** (~5.8 symbols) apart.

### Within a burst the offset only ever increases
Burst A at t=35: `0x0AA4D2D3`(6176) → `0xD71F70D3`(6299) → `0x93E1A9FA`(6432), increments
**+123, +133**. Burst A at t=269 repeats the identical sequence. Burst B: 6240 → 6363, **+123**.

**The anchor slips progressively during a burst and never recovers within it** — it is a
monotonic slip, not a jump between two states. The step is ~123 strobes = ~123 symbols between
successive displaced samples.

### A golden capture does NOT mean an error-free second
Within a burst the displaced seconds **alternate with golden ones that still carry heavy errors**:

| t | err | capture |
|---|---|---|
| 35 | 41,603 | displaced 6176 |
| 36 | 39,102 | **GOLDEN** |
| 37 | 30,143 | displaced 6299 |
| 38 | 67,056 | **GOLDEN** |
| 39 | 18,468 | displaced 6432 |
| 40 | 73,123 | **GOLDEN** |

`0x20C` holds the **last completed frame** at read time — one frame sampled out of ~1272 per
second. So the capture is a **sparse sample** of frame states, and a golden reading only says
*that one frame* was aligned. **Golden-constancy percentages are therefore a lower bound on how
often the anchor is displaced, not a measurement of it** — every burst figure in §24–§27 under-
counts, and no burst-fraction number in this campaign should be read as a duty cycle.

### Bearing on the unexplained words
Three of the eight remain unmapped, and they now sit in a pattern: `0xBFED37AC` is family B's
third step (t=157 and t=392 — both families' third step), `0xD748FC96` at t=275 is family A's
fourth, `0x41800000` at t=41 follows family A's third. **All three are the step where a burst is
ending**, so they are candidates for a partially-slipped or transitional anchor rather than a
clean displacement — testable, not yet tested.

---
## §33 TASK 3'S INDEPENDENT SELECTOR-RATE MEASUREMENT — and what it does to §31's units

Task 3 measured, on the Task 2 harness (NF=20, 46 frames):

| selector | words captured | beats/frame | vs sel5 |
|---|---|---|---|
| 3 postSymbolSync | 566,660 | 12,318 | −4.3 % |
| 4 postCoarseFreq | 566,660 | 12,318 | −4.3 % |
| 6 constellation | 566,660 | 12,318 | −4.3 % |
| 5 postCarrierSync (**native** `carrierSyncValid`) | 591,930 | 12,868 | — |

Selector 6's 12,318 agrees with §30's independent measurement of **12,320** from mark spacing on a
separate harness — two harnesses, same number.

**The consequence Task 3 did not draw:** sel5 has the *native* valid and still runs at **12,868
beats/frame** against a nominal 1,120 symbols/frame — **~11.5×**. So the ~11× rate is **not** a
symptom of the borrowed valid alone; the node itself is not symbol-rate, or the frame at this
point is not 1,120 symbols. §30's run-length histogram agrees: consecutive values differ, so this
is not one symbol value sampled repeatedly.

### §33 UPDATE — the caveat was over-cautious for tap 3; the ÷11 conversion IS supported
The Task 2 fix round settled this by code inspection and measurement:

- **DBGCAP tap 3 and ddrcap selector 6 sample the identical node (`QPSKConstellationPoints_re/im`)
  through the identical valid (`QPSKConstellationValid`).** §30's open question — "is the node
  behind tap 3 the node selector 6 samples" — is **answered: yes.**
- Its absolute-reference assertion measures the symbol domain at **11.0×** the 1,120-symbol
  reference for selector 6, independently reproducing §30's 11 beats/symbol.

So for **tap 3 / selector 6** the conversion 11 strobes = 1 symbol is confirmed by two independent
harnesses, and **§31's ≈561–585 symbols stands.** I over-corrected in flagging it as unestablished;
the correction is recorded rather than quietly removed.

What remains true from the caveat: **the taps are not symbol-rate instruments** (sel5's native
valid measures 11.5×, the symbol domain spans 11–12.84× across selectors), so the ÷11 factor is
**specific to selector 6** and must be re-measured per tap before converting any other tap's
offsets. And DBGCAP's own "16 symbols" framing is inaccurate — it is 16 consecutive valid pulses,
**under 2 real symbols**. Its digest remains a valid invariance witness; only its description was
wrong.

**Quote the displacement as ≈6,176–6,432 strobes ≈ 0.50–0.52 of a frame ≈ 561–585 symbols at this
tap.** T6 must be able to search a full frame regardless.

Task 3's own framing — that sel3/sel4 *undersample* by 4.3 % relative to sel5 — is correct as a
comparison but understates the defect: all four are ~11× the nominal symbol rate, and the 4.3 %
gap between borrowed and native valid is the smaller part of the discrepancy.

---
## §34 **ROOT CONSTANT ERROR: a frame is ~12,320 SYMBOLS, not 1,120.** One strobe = one symbol

The re-review of the Task 2 fix round refuted the "11× over-sampling" claim, and it was right.
Everything that followed from it was mine, and it is corrected here in one place.

### The error
I took a frame to be **1,120 symbols** (2240 message bits ÷ 2 bits/symbol). That is the *decoded
message* length. The **transmitted** frame — after FEC coding, preamble and padding — carries
**~12,320–12,337 symbols**. The design spec says so directly ("~12,337 words per frame" for
symbol-domain captures).

Measuring 12,320 valid pulses per frame and dividing by the wrong 1,120 produced a spurious
"11.0× over-sampling". **`QPSKConstellationValid` fires once per symbol.** The rate set is
internally consistent and confirms it:

| domain | beats/frame | ratio |
|---|---|---|
| sample | ~49,349 | **4.006** × symbol → 4 samples/symbol ✓ |
| symbol | 12,320 (borrowed) / 12,333 (native) | 1 per symbol |
| bit-word | ~1,542 | symbol ÷ **7.99** → 8 symbols per 16-bit word ✓ |

### What this corrects
- **§30's "11 beats per symbol" is WRONG** — it is 1 beat per symbol. The taps do **not**
  over-sample. My message to the Task 2 agent asserting 11× was wrong on the same constant.
- **§28's amendment is WITHDRAWN and its original text restored.** The window is 16 *symbols*, so
  the exclusion of displacement ≤ 8 **symbols** was right as first written. My "≈1.45 symbols"
  correction was wrong.
- **§33's "update" is WITHDRAWN.** It reverted a caveat that had been right for the wrong reason.
- **§31/§32's symbol figures are multiplied by 11**: the displacement is **≈6,176–6,432 symbols**,
  and the within-burst step is **~123 symbols**, not ~11.2.
- **DBGCAP's "first 16 symbols" description is accurate after all.** §33's claim that it spans
  "under 2 real symbols" is withdrawn.

### What never moved
**The displacement is 0.50–0.52 of a frame.** That figure is independent of the constant and has
been stable through every revision — as has §31's central finding: the values at the displaced
position are bit-exact, so this is **position, not corruption**. The re-review also explains
§31's `+1` positive-control offset: DBGCAP samples `Index_Vector_out1`, fed from the free-running
register `Delay4_out1_re`, so it lags the combinational tap by ≥1 enb tick. The decode is
therefore *more* firmly grounded than when it was written.

### The rule this earns
**A derived unit is a witness and needs its own positive control.** I converted between strobes
and symbols four times across §28–§33 without once checking the conversion constant against the
design, and produced three contradictory statements of the same measurement. The constant was
sitting in the spec. **Ratios between measured domains (4.006, 7.99) are the cheap check** — they
would have exposed it immediately, since 1,120 symbols/frame implies no consistent
samples-per-symbol at all. Quote measurements in the unit they were taken in; convert only after
the conversion has been checked, and state the check.

---
## §35 **THE DISPLACEMENT CROSSES THE ANCHOR BOUNDARY — cap_in agrees with tap 3 to the bit** [SIM, positive-controlled]

§31 was a single-tap result and §25's anchor rule forbade carrying it to the FEC-anchored
witnesses. Test repeated on **their own anchor**, with their own instrument definition.

### Instrument, read from the RTL rather than assumed
`FecCapture` builds `cap_in` from the **first 32 bits after the FEC `startIn`**, packed
**LSB-first** (`w |= 1 << n`) — a different window, anchor and packing from DBGCAP's 16 symbols.
The bit-domain ddrcap selectors pack **16 bits per beat**, so a beat is a word, not a bit:
1,540 beats/frame × 16 = **24,640 bits = 12,320 symbols × 2** ✓.

**A first attempt read one bit per beat; its positive control refused and no null was reported.**
The bit order within the word was then left as a parameter for the control to fix — and it did:

| order | positive control |
|---|---|
| **MSB-first** | **PASS — `0x5216F3E2` at all 21 anchors, offset 0 exactly** |
| LSB-first | FAIL — refused, no sweep |

### The sweep
493,440 anchors, 7 silicon `cap_in` burst words sought, null 8·10⁻⁴.

**All 7 of 7 found**, each at one fixed offset, in 20 anchors each:

| fraction of frame | tap 3 (symbols) | cap_in (bits) | ratio |
|---|---|---|---|
| 0.5013 | 6176 | 12352 | **2.000** |
| 0.5065 | 6240 | 12480 | **2.000** |
| 0.5113 | 6299 | 12598 | **2.000** |
| 0.5165 | 6363 | 12726 | **2.000** |
| 0.5221 | 6432 | 12864 | **2.000** |
| 0.5267 | — | 12979 | — |
| 0.5315 | — | 13097 | — |

**Two instruments, different anchors, different windows, different packings, different units — and
the same five displacement fractions to four decimals, at exactly 2 bits per symbol.** The ladder
steps match identically: tap 3 gives 64, 59, 64, 69 symbols; cap_in gives 128, 118, 128, 138 bits.

### What this establishes
1. **The displacement is a property of the signal's frame alignment, not of one instrument's
   anchor.** It is now confirmed across the anchor boundary that §25 warned about, by repeating
   the measurement rather than by assuming it carries.
2. **The FEC-anchored witness is the cleaner one** — 7 of 7 words explained, against tap 3's 5 of
   8. Two of its fractions (0.5267, 0.5315) extend the ladder beyond what tap 3 showed.
3. The displacement ladder now has **seven** rungs spanning **0.5013–0.5315 of a frame**, in steps
   of ~0.005 (~123 bits / ~61 symbols).

Position, not values, now holds at **both** the demod input and the FEC input.

Script: `two_jup/score_fec_offset.py` — refuses to sweep unless the golden word is reproduced
first, and exits 2 saying so.

---
## §36 CAPTURE-PATH SKEW: the DDR path does NOT inherit DBGCAP's register delay

From the Task 2 fix round, and it matters for every cross-check between the two instruments.

- **ddrcap selector 6** reads `QPSKConstellationPoints_re/im` **combinationally**, on the same
  cycle the value is valid.
- **DBGCAP** samples `Index_Vector_out1`, fed from the free-running register `Delay4_out1_re`, so
  it lands **one `enb_1_2_0` tick later**.

The two instruments therefore see the same node **one beat apart**. This is the explanation for
§31's positive control matching at `mark+1` rather than `mark+0`, and it is not a defect in
either.

**Task 5's cross-check must subtract this one-beat skew**, or a correctly working DDR capture will
appear to disagree with DBGCAP by exactly one sample and be read as a fault.

The fix round also independently confirmed §34: with the corrected `DOMAIN_REFS`
(symbol 12,337, bit 1,542) and an unbiased mark-to-mark estimator, **all 11 rate-checked selectors
read within 1.00× of expected, 10 of 11 with min == max**. The "11×" is dead from both directions.

---
## §37 QUESTION FOR THE OPERATOR: is in-place patching of a packaged IP the wrong approach?

Raised because the BD flow has now failed **four times at the same gate**, on **four distinct
mechanisms**, and `ddrcap_bd.tcl` has reached the **two-revision cap**. Per the standing rule a
third revision means the approach is wrong, so this is written up as a question rather than fixed.

### The four failures, each real and each fixed
1. `ddrcap_inject.py` dispatched on the bare filename `component.xml` and crashed on unrelated
   cores' metadata (`70c3af2`).
2. The project cached an `.xci` customization predating the patch; no catalog refresh existed
   (`2e05bec`).
3. `update_ip_catalog` cannot run with the BD open **and reports that as a CRITICAL WARNING, not a
   Tcl error** — so a `catch`-based reporter printed `REFRESH_OK` on a refresh that never ran
   (`7164385`). That reporter was mine and is the same fault class as a dead counter.
4. **Now:** the refresh runs genuinely clean — `update_ip_catalog` before the open, IP repositories
   loaded, no CRITICAL WARNING anywhere — and `upgrade_bd_cells` still answers *"the cell
   '/TxRxCompo_ip_0' is already at its latest version"*, with the five pins still absent.
   `component.xml` on disk is confirmed patched (`grep -c dut_ddrcap_i` → 1).

### The candidate diagnosis
Vivado identifies a packaged IP by **VLNV + version**, and the injector deliberately holds the
version at `1.0` while editing `component.xml`'s contents. `-scan_changes` plausibly does not
detect a **same-version content edit** at all — which would make this independent of the
open/close ordering that fix 3 addressed, and would mean **no amount of refreshing will ever pick
the change up**. That is a property of the approach, not a bug in the script.

### What this implies
Patching a packaged IP in place and expecting the catalog to notice may simply not be a supported
flow. The alternatives, none of which is a further revision of the instrument:
- **(a) Clear the generated output products** for `TxRxCompo_ip_0` (`vivado_prj.gen/…`,
  `vivado_prj.srcs/…/system_TxRxCompo_ip_0_0`) and let Vivado regenerate from the patched catalog.
  Cheapest; a project-state operation, not an instrument change.
- **(b) Bump the IP version** (1.0 → 1.1) so the catalog sees a genuinely new IP. Clean in Vivado's
  terms, but touches the injector, which is also at its cap.
- **(c) Regenerate the project** from a catalog that already contains the patched IP. ~+1 h.
- **(d) Abandon the BD route** for these taps and reach DDR another way.

**(a) WORKED — the question is ANSWERED, 21:10.** Deleting only the two generated output-product
directories for the cell (`vivado_prj.gen/…/system_TxRxCompo_ip_0_0/`, 184K, and
`vivado_prj.srcs/…/system_TxRxCompo_ip_0_0/`, 24K) and re-sourcing the tcl **unchanged** gave
`DDRCAP_BD_REFRESH_OK` (both, no WARN) → `DDRCAP_BD_WIRE_OK` → **`validate_bd_design` clean** →
`system.bd` saved.

**The crux:** `component.xml` was correct all along. The catalog and the cell were consulting the
project's **cached `.xci` / generated `.xml` / `.v`** rather than re-reading the patched IP-XACT,
and at a pinned version `1.0` neither `update_ip_catalog -scan_changes` nor `upgrade_bd_cells`
forces that cache to drop. So the answer to the section's title is: **in-place patching of a
packaged IP is salvageable, but it requires an explicit cache-clear of the cell's generated output
products.** Ordering and warning-detection fixes (attempts 2–4) could never have been sufficient —
they addressed the refresh path, and the stale artefact was downstream of it.

Recorded because it cost four aborts to learn, and because the two-revision cap held: the fix was
a **project-state operation**, not a third revision of the instrument.

### What does NOT depend on this
§31 and §35 are already established from existing captures and simulation, positive-controlled,
and need no new image. The DDR route would extend and confirm them on silicon; it is not what the
position-vs-values conclusion rests on.

---
## §38 THE TAP-3 RESIDUE IS SYSTEMATIC, AND THREE EXPLANATIONS ARE NOW EXCLUDED [SILICON, interim]

Interim scoring of the running overnight census (`census-run-148c`, 1,837 rows, **50 burst
occurrences** against 14 in the whole 400 s run) with `classify_burst_words.py`.

| witness | distinct explained | occurrences explained |
|---|---|---|
| **cap_in** (FEC-anchored, bit domain) | **7 / 7** | **50 / 50 = 100 %** |
| **tap 3** (demod-anchored, symbol domain) | 5 / 7 | 35 / 50 = **70.0 %** |

The tap-3 figure reproduces the 71.4 % measured on the independent 400 s run, so the asymmetry
between the two witnesses is **stable, not sampling noise**.

### The residue is not rare
The two unexplained tap-3 words recur **8 and 7 times** — as often as the explained ones. This is
not a tail of singletons: **~30 % of tap-3 burst frames sit in a state that no displacement
produces**, while the FEC-anchored witness is fully explained at the same moments.

### Three explanations tested and excluded
1. **Displacement alone** — the words are absent from a map enumerating the word at *every* one of
   12,320 offsets. Map is injective; chance ~3·10⁻⁶.
2. **Displacement + quadrant relabelling** (a phase-ambiguity slip at the demod input): all 24
   symbol-alphabet permutations of each unexplained word, checked against the whole map.
   **No hit.** Null 2·10⁻⁴.
3. **An anchor that moves part-way through the capture window** — §32 notes all three unexplained
   words fall at **burst-end** steps, where the slip is in transition, so a window straddling two
   alignments was the natural candidate. All ordered pairs of the five known rungs × all 15 split
   points: **no hit.** Null 3·10⁻⁷.

### What that leaves
Something at or before the demod input, during bursts, that is **not** a displacement of the
correct sample stream and **not** a quadrant rotation of one — while the FEC input at the same
time is displaced-but-otherwise-perfect. Candidates not yet tested: a genuine value corruption
confined to the demod-input tap; a state the simulator does not reproduce (it is a clean-channel
mode-1 model); or an artefact of DBGCAP's own window at burst edges.

**This does not weaken §31/§35.** Position is established, cross-validated on two anchors, and
accounts for **100 %** of the FEC-input evidence. §38 says position is not the *whole* story at the
demod input, and names what it is not.

---
## §39 **FIRST PER-FRAME MEASUREMENT FROM THE DDR CAPTURE** [SILICON] — displacement is a STABLE state, not a progressive slip

Raw DDR captures on 148 with image `d063900f1761`, selector 6 (constellation), skew +1 per §36.
Four-part positive control passed first (§0 gate). Seven captures, 131,072 beats each ≈ 10.6
frames, burst-triggered on `0x108`.

| capture | errs/s | frames | result |
|---|---|---|---|
| quiet 1 | 0 | 11 | **11/11 aligned at offset 0**, 0 inexplicable |
| quiet 2 | 51 | 10 | **10/10 aligned at offset 0**, 0 inexplicable |
| burst 1 | 38,264 | 11 | **11/11 displaced at exactly 6299 symbols** (0.5113 of a frame) |
| burst 3 | 36,167 | 11 | **11/11 displaced at exactly 6363 symbols** (0.5165 of a frame) |
| burst 4 | 46,907 | 11 | **11/11 aligned at offset 0** |
| burst 2 | 56,763 | 10 | **10/10 = `0xD748FC96`**, displacement-inexplicable |

### 1. The quiet control is clean
**21 of 21 quiet frames sit at offset 0 with zero inexplicable words.** The instrument reports
"no displacement" when there is none — the other half of §0, and what makes a null meaningful.

### 2. §31 is confirmed on silicon by an independent instrument
6299 and 6363 symbols are **rungs 3 and 4 of the ladder** derived from simulation and from the
1 Hz DBGCAP captures (§31, §35). A completely different instrument — raw DDR through the RX2
packer — lands on the same offsets to the symbol.

### 3. **§32's "progressive slip" does not hold at frame resolution — CORRECTED**
Within each burst capture the displacement is **constant across all 10–11 consecutive frames**
(monotonic increase 0/10). §32 inferred a monotonic slip from 1 Hz samples *seconds* apart; at
~8.5 ms resolution each rung is a **stable state**, not a ramp. Both are true: the anchor **steps
between stable rungs** on a timescale slower than 8.5 ms and faster than 1 s. §32's within-burst
ordering stands; its description of a continuous progressive slip does not.

### 4. Errors WITHOUT displacement
**burst 4 carried 46,907 errors/s with all 11 frames perfectly aligned.** So a high-error second
is not necessarily a displaced one — displacement is not the only error source, and error rate is
not a proxy for displacement. Every burst/quiet classification in this campaign that used error
counts as a stand-in for displacement needs that caveat.

### 5. The unexplained word is a STABLE STATE, not a transition
`0xD748FC96` — one of §38's displacement-inexplicable words — appears on **all 10 consecutive
frames** of burst 2. **§38's hypothesis that the unexplained words are burst-edge transients is
therefore WRONG.** It is a persistent alignment state lasting at least 8.5 ms whose content is not
produced at any of the 12,320 offsets of the simulated frame. Candidates: a state the mode-1 clean
sim does not reproduce, or content genuinely corrupted rather than displaced.

### Instrument note
The board became unreachable at ~22:56 during the capture campaign, after 7 successful captures.
`RIG_HALT` set; no power-cycle attempted; 146 untouched. **All seven captures were already on the
host and none of the above depends on the board coming back.** Whether repeated large
`iio_readdev` captures destabilise this image is an open question and the first thing to test when
the rig is available.

---

## §40 ~~POSITION *AND* VALUES~~ — **WITHDRAWN. The "value episode" is a displacement with the I/Q rails SWAPPED (§41)**

§40 as committed in `e7c843e` concluded that burst 2 showed genuine value corruption, because its
frames matched the simulated frame at **no** offset (best 29.6 %, chance 25.0 %) while being
100.0 % identical to one another. **That conclusion is withdrawn.** It compared *symbols*; the rails
tell a different story (§41). Retrieve the original text from `e7c843e` if needed.

**What survives, and is strengthened:**
- **Displacement episodes are pure displacement at full-frame strength** — burst 1 and burst 3
  match the simulator on **all 12,320 symbols** at single non-zero offsets 6299 and 6363; the quiet
  captures match at offset 0. §31/§35 confirmed on silicon by an independent instrument.
- **Error rate is not a proxy for displacement** — §39's burst 4: 46,907 errs/s, all frames aligned.
- §38's "burst-edge transient" hypothesis remains refuted (§39).

---
## §41 **EVERY BURST EPISODE IS A DISPLACEMENT. Some also SWAP THE I/Q RAILS** [SILICON, exact]

Decomposing the capture into its two rails instead of into symbols:

| comparison | burst 2 (the ex-"value episode") | burst 1 (plain displacement) |
|---|---|---|
| I vs sim **I** | 54.4 % | **100.0 % at offset 6299** |
| Q vs sim **Q** | 54.6 % | **100.0 % at offset 6299** |
| **I vs sim Q** | **100.0 % at offset 6549** | 54.8 % |
| **Q vs sim I** | **100.0 % at offset 6548** | 54.8 % |

Verified **exactly** — every one of 12,320 symbols, no stride, on five consecutive frames:
`I == simQ@6549` and `Q == simI@6548`, `True` on all five.

### Why the symbol test could not see it
With the rails crossed, **both bits of every symbol are wrong even though each rail is individually
perfect**, so a symbol-level match collapses to chance. §29's relabelling test and §38's exclusions
were symbol-level too, which is why the residue survived them: the residue was never corruption, it
was a permutation the symbol tests were blind to. A whole-frame test on the wrong unit is still the
wrong test.

### The result
**Position, not values — the campaign's original dichotomy resolves cleanly to position after all.**
Every burst episode captured is the correct data at the wrong place. Two flavours:
1. **Plain displacement** — both rails displaced together (bursts 1, 3: offsets 6299, 6363).
2. **Displacement with an I/Q swap** — I carries Q's data and vice versa (burst 2).

### The sharpest clue yet: the rails differ by ONE symbol
The swapped episode's rails sit at **6549 and 6548** — a **one-symbol skew between I and Q**. A
pure swap would place both at the same offset. A single-sample slip on one rail produces both the
swap and the skew, which points at I/Q interleaving/deinterleaving or the rate-change handoff
rather than at the demodulator's decisions.

### Standing rule earned
**Test on the unit the defect can act on.** Three separate analyses (§29, §38, §40) failed to see
an I/Q swap because all three compared symbols, and a swap is invisible at symbol level. When a
test says "no match at any offset", ask what transformation the test is blind to before concluding
corruption.

---
## §42 **THE §38 RESIDUE IS CLOSED: it is rungs 6 and 7, I/Q-swapped** [SILICON]

Applying §41's rail decomposition to the 1 Hz census data. Built swapped-rail offset maps
(I from the simulated Q, Q from the simulated I) at three inter-rail skews and looked up §38's
three unexplained tap-3 words. Null 2.6·10⁻⁵.

| word | occurrences | result |
|---|---|---|
| `0xBFED37AC` | 8 | **swapped displacement, skew +1, offset 6489 = 0.5267 of a frame** |
| `0xD748FC96` | 7 | **swapped displacement, skew +1, offset 6548 = 0.5315 of a frame** |
| `0x41800000` | 1 | still unexplained — a singleton with a zero LOW byte (see below) |

### The two witnesses see the same seven rungs
| rung | fraction of frame | cap_in | tap 3 |
|---|---|---|---|
| 1 | 0.5013 | ✓ | plain, 6176 |
| 2 | 0.5065 | ✓ | plain, 6240 |
| 3 | 0.5113 | ✓ | plain, 6299 |
| 4 | 0.5165 | ✓ | plain, 6363 |
| 5 | 0.5221 | ✓ | plain, 6432 |
| 6 | 0.5267 | ✓ | **SWAPPED, 6489** |
| 7 | 0.5315 | ✓ | **SWAPPED, 6548** |

**The ladder is one ladder.** §35 found cap_in with seven rungs and tap 3 with only five; the two
"missing" rungs were present all along as I/Q-swapped episodes that symbol-level tests could not
see. And the DDR capture independently measured the swapped episode at **6548/6549** — **rung 7
exactly**, on a third instrument.

### §38's headline number is retired
"~30 % of tap-3 burst frames sit in a state no displacement produces" is **wrong**. Those frames
are rungs 6 and 7 with the rails crossed. Corrected: **essentially all tap-3 burst frames are
displacements**; 15 of 50 occurrences are swapped ones.

### The one genuine leftover
`0x41800000` — a single occurrence, and the only tap-3 word with a zero **low** byte. §26
identified partial-fill reads by a zero **top** byte, matching an LSB-first fill; the capture packs
MSB-first, so a partially-filled read shows zeros in the LOW bits. **§26's filter tests the wrong
end for this instrument** and let this one through. One occurrence, consistent with a torn read,
not a state. It should be excluded, not explained.

### Why this matters beyond the residue
Rungs 6 and 7 are the two furthest displacements, and they are exactly the ones carrying the I/Q
swap. Whatever produces the swap does so at the far end of the slip — a testable ordering claim,
and the first link between the displacement ladder and a specific mechanism.

---
## §43 THE LADDER'S GEOMETRY: a half-frame jump plus a ~3.9 ppm walk [SILICON measurements, HYPOTHESIS on mechanism]

With all seven rungs known (§42), the ladder's arithmetic is worth stating exactly.

| rung | offset (symbols) | − half-frame | Δ | fraction |
|---|---|---|---|---|
| 1 | 6176 | **+16** | — | 0.5013 |
| 2 | 6240 | +80 | 64 | 0.5065 |
| 3 | 6299 | +139 | 59 | 0.5113 |
| 4 | 6363 | +203 | 64 | 0.5165 |
| 5 | 6432 | +272 | 69 | 0.5221 |
| 6 | 6489 | +329 | 57 | 0.5267 |
| 7 | 6548 | +388 | 59 | 0.5315 |

Frame = 12,320 symbols, half = 6,160. **Rung 1 sits at half-frame + 16 symbols** — 16 being
exactly the DBGCAP window length, which may be coincidence and is flagged as such. The whole
ladder spans **372 symbols = 3.0 % of a frame**; mean rung spacing **62 symbols**.

### The walk rate is ~3.9 ppm [MEASURED]
Symbol rate = 1247 frames/s × 12,320 symbols/frame = **15,363,040 symbols/s**.

| source | step | interval | rate | ppm |
|---|---|---|---|---|
| §32 burst A, rungs 1→3 | 123 sym | 2.07 s | 59.6 sym/s | **3.88** |
| §32 burst A, rungs 3→5 | 133 sym | 2.07 s | 64.4 sym/s | **4.19** |
| mean rung spacing per poll | 62 sym | 1.03 s | 60.0 sym/s | **3.91** |

Three independent estimates agree on **≈3.9–4.2 ppm**.

### Hypothesis, explicitly labelled
A few-ppm relative rate offset between transmit and receive sample clocks would produce exactly a
slow, monotonic timing walk at this rate. That would make the burst **two** events, not one:
1. a **discrete jump** to ≈ half a frame — a re-lock to the wrong alignment, not a drift, since no
   intermediate offsets between 0 and 6176 are ever observed; then
2. a **~3.9 ppm walk** across ~372 symbols over the burst's few seconds, before recovery to 0.

**This is a hypothesis about mechanism, not a measurement.** What is measured: the seven offsets,
their spacing, the walk rate, and that no offset between 0 and 6176 has ever been captured. What
is inferred: that the walk rate reflects a clock-rate offset.

### What would test it
- Offsets between 0 and 6176 should **never** appear if the jump is discrete. The DDR capture can
  settle this — it resolves every frame, where the 1 Hz instrument sampled one frame in 1,272.
- The walk rate should be **independent of the rung**, and should match any independently measured
  TX/RX sample-clock offset on this rig.
- The recovery from rung 7 back to 0 should be a jump, not a walk back.

None of these needs a new image; all three need the board, which is down.

---
## §44 A THIRD EPISODE TYPE: heavy errors with a PERFECT demod input — the defect is DOWNSTREAM [SILICON]

§39 noted burst 4 carried 46,907 errs/s with every frame aligned by the 16-symbol test. Checked at
full-frame, per-rail resolution:

| capture | errs/s | I vs sim I @ 0 | Q vs sim Q @ 0 |
|---|---|---|---|
| burst 4, frames 0–3 | **46,907** | **100.00 %** | **100.00 %** |
| quiet 2, frames 0–1 | 51 | 100.00 % | 100.00 % |

**Burst 4's constellation data is bit-perfect — all 12,320 symbols, both rails, four consecutive
frames — and indistinguishable from a quiet capture. Yet the BIST reports ~47,000 errors/s.**

At 1247 frames/s that is ~37 errors per frame against the 120 bits the BIST actually scores (§5) —
about 31 % BER. A defect that large cannot be invisible at the tap it passes through.

### The localisation
**In this episode the receive chain is correct up to and including the demodulator input, so the
errors arise downstream of it** — in the demod slice/serialise, the deinterleaver, Viterbi, RxAlign,
or the BIST comparator. This is the first burst episode localised to a *stage*, and it is localised
by the DDR capture doing exactly what it was built for.

### Three distinct burst episodes now exist
1. **Displacement** — data perfect, position wrong (bursts 1, 3; rungs 1–5).
2. **Displacement + I/Q swap** — rails crossed with a one-symbol skew (burst 2; rungs 6–7, §41/§42).
3. **Downstream errors** — demod input perfect, errors after it (burst 4).

"The beat" has been treated as one phenomenon throughout this campaign. It is at least three, and
they are separable per frame with this instrument.

### Limits, stated
Four frames of one capture. The claim is that these four frames carried heavy errors with a perfect
demod input — solid, because each frame is an exact 12,320-symbol match. Whether type 3 is common,
and whether it correlates with rung or with the swap, needs the ~150-burst census that the board
going down cut short. **Nothing here rests on the board returning; everything here needs it to go
further.**

---
## §45 LIMIT OF THE DISPLACEMENT MEASUREMENT: it cannot say WHICH side moved

Every displacement figure in §31–§44 is **data measured relative to the demod frame marker**. That
cannot distinguish:
- (a) the data arriving at the wrong time relative to a correct frame marker, from
- (b) the frame marker firing at the wrong time relative to correct data.

Both produce an identical capture. The distinction matters: (a) points at the datapath, (b) at
frame synchronisation.

### Test attempted with data in hand, and it does not discriminate
The capture carries **two** markers — demod (ch2) and FEC (ch3) — so if they moved independently
the pair would resolve it. They do not:

| capture | demod→FEC gap |
|---|---|
| quiet 2, quiet 3 | 0, 0, 0, 0, 0 |
| burst 1 (rung 3), burst 3 (rung 4) | 0, 0, 0, 0, 0 |
| burst 2 (rung 7, swapped) | 0, 0, 0, 0, 0 |
| burst 4 (downstream errors) | 0, 0, 0, 0, 0 |

**The two markers are exactly coincident in every capture, quiet and burst alike** — consistent
with the RTL, where the FEC's `startIn` derives from the demodulator's `startOut`. They are not
independent witnesses, so they cannot separate (a) from (b). Recorded so the test is not repeated.

### What would discriminate
An **independent time reference in the same capture** — the transmit side. Selector 8 is
`Transmitter_dataOut`. The instrument captures **one selector at a time**, so TX and RX cannot be
captured simultaneously through this path; that is a real limitation of the DDR instrument as
built, not an oversight in the runs.

Options, none attempted:
- add a second capture path (a further BD change — expensive, and the BD route cost four aborts);
- widen the capture word to carry a TX-domain sample alongside the RX one;
- accept the ambiguity and discriminate indirectly: **§44's episode type 3 already shows the
  demod input can be bit-perfect while errors appear downstream**, which is evidence the frame
  machinery and the datapath can fail independently.

Until then, "the anchor is displaced by ~0.5 of a frame" should be read as **"data and frame
marker are separated by ~0.5 of a frame"**, without attributing the motion to either.

---
## §46 §43's ASSERTION VERIFIED, AND THE TAP-3 RESIDUE CLOSES COMPLETELY [SILICON]

§43 asserted "no offset between 0 and 6176 has ever been observed". Assertions should be checked,
so it was — against **every archived 1 Hz run**, tap-3 capture column only: the census
(2,419 rows), `multitap/20260831_074947`, and `tap/20260831_072106`. **92 non-golden tap-3 words.**

| | |
|---|---|
| plain-displacement offsets | **6176, 6240, 6299, 6363, 6432** — exactly the five known rungs |
| swapped-displacement offsets | **6489, 6548** — exactly the two known rungs |
| offsets strictly between 0 and 6176 | **NONE** |
| unmatched words | **2** — `0x31060000`, `0x41800000` |

**§43's assertion HOLDS.** No intermediate offset appears anywhere in the archive, across three
independent runs spanning four hours. The jump to half-frame is discrete.

### The residue is now completely closed
Both unmatched words have a **zero low byte** — the MSB-first partial-fill signature §42 identified
when it found §26's filter testing the wrong end. They are torn reads, not states. So across all
archived data, **every genuine tap-3 burst word is a displacement**, plain or I/Q-swapped. Nothing
is left unexplained at this witness.

### A method note, because the first attempt got it wrong
The first run of this check reported the assertion **FAILING** on an offset of 39, plus eight extra
"rungs" (6215, 6279, 6338, …). That scan took **every hex token in every column** — cap_in,
cap_deint, cap_out and tap-0 words included — and looked them all up in the **tap-3** map. Words
from other witnesses landing in a foreign map produced phantom rungs and a phantom intermediate
offset.

**A lookup table is witness-specific. Feeding another witness's words into it manufactures
results.** This is the §25 anchor-boundary rule in a new costume: the map is anchored to one tap,
and mixing taps across it is exactly the comparison that rule forbids. Caught only by redoing the
scan properly, one column at a time.

---
## §47 THE NULL CASE, VERIFIED EXHAUSTIVELY

The displacement results rest on the claim that a healthy link produces an exact match at offset 0.
That claim was spot-checked on two frames in §39. Completed here across **every quiet frame in
every quiet capture**, exact comparison, both rails, all 12,320 symbols:

| capture | errs/s | frames exact on BOTH rails |
|---|---|---|
| quiet 1 | 0 | **10 / 10** |
| quiet 2 | 51 | **9 / 9** |
| quiet 3 | 51 | **9 / 9** |
| **total** | | **28 / 28** |

**Every quiet frame captured is bit-perfect at offset 0** — not sampled, not strided, not
approximate. So the instrument's null is verified as strongly as its positive: it reports "no
displacement" on 28 of 28 healthy frames, and a non-zero offset only when the link is disturbed.

This also validates the simulator as a reference at full strength: hardware and simulation agree on
**every one of 12,320 symbols per frame, on both rails, on 28 independent frames**, with no fitted
parameters. Every "100.00 % at offset N" in §41–§46 is measured against a reference that reproduces
the hardware exactly when the hardware is healthy.

---
## §48 TWO OPERATIONAL FACTS, AND A CAPTURE THAT VINDICATES §41–§42 [SILICON, 2026-09-01]

### 1. ARMING is the hazard, not capturing
A graded stability probe — **24 captures, 29.7 MB, four times the volume that preceded the 22:56
outage, performing NO arms** — did not hang 148 once. Meanwhile all four board outages occurred
around an **arm**:

| time | board | what was happening |
|---|---|---|
| 22:10 | 148 | gated restore SIGKILLed **mid-arm** |
| 22:56 | 148 | capture campaign (arm history unclear) |
| 07:38 | 146 | the **146 stage** of `bringup_r2r3.sh r3` |
| 08:05 | 148 | the **arm** phase of armed-capture trial 2 |

**This inverts the working assumption.** The DDR capture path was the suspect; it is exonerated as
a hang cause. Arming is the hazard — consistent with the long-standing no-ping fault, which was
always about arms. **A design that re-arms repeatedly is therefore the risky one**, which is
awkward, because §48.2 is why re-arming looked necessary.

### 2. Repeated captures degrade the link; a SINGLE capture does not
From the same probe (no arms, captures only):

| capture | fps | capTAP |
|---|---|---|
| 1–2 | **1248** | **golden** |
| 3 | **−82,193** (frame counter went BACKWARDS — a reset) | `0x0` |
| 4–24 | ~565–626 (**half rate**) | never golden again |

It does **not** recover: 60 s after all captures stopped, `fps=593`, `errs/s≈35,000`, capTAP still
wrong. Only a re-arm restores it.

**But one capture is harmless.** The armed-capture trial measured `fps=1250` *after* its single
capture — unchanged from before. So the degradation needs repetition, and the quiet captures of
§39–§44 (numbers 1–3 of their run) were taken from a healthy link.

### 3. The capture that settles the §39–§44 caveat
Last night's burst captures were numbers 4–7 of their run — after the degradation onset — so I
flagged §39–§44's burst claims as possibly artefactual. **One capture taken from a link verified
`fps=1250`, `errs/s=58`, `capTAP=0xBCF94856` golden seconds earlier answers it:**

```
10 frames scored, 10 placed, 0 displacement-inexplicable
ALL TEN displaced at exactly 6299 symbols = 0.5113 of a frame (rung 3)
```

and its post-capture probe read **`capTAP = 0xD748FC96`** — the **I/Q-swapped rung-7 word** of
§41/§42, on a freshly-armed link.

**So displacement and the I/Q swap are both genuine beat phenomena, not capture artefacts.** The
caveat is discharged; §41 and §42 stand.

### What this means for the experiment design
One capture per arm is correct for data quality and **wrong for board safety** — it maximises the
number of arms, and arms are what hang the board. The design that satisfies both is: **arm once,
then take a small number of captures (≤2) inside the healthy window**, accepting fewer captures per
arm rather than more arms. Untested; it is the obvious next thing.

---
## §49 THE LADDER IS RATE-INDEPENDENT — and my "proven arm" has a silently failing step [SILICON]

One arm, two captures (the §48-safe design), on a freshly power-cycled 148.

| capture | errs/s at trigger | result |
|---|---|---|
| CAP1 | 0 | **10/10 frames aligned at offset 0** |
| CAP2 | 14,435 | **11/11 frames displaced at exactly 6240 symbols = 0.5065 = rung 2** |

`capTAP` read golden `0xBCF94856` before, between and after both captures, and `fps` was unchanged
after each — confirming §48: **two captures per arm stays inside the healthy window.**

### The finding: same rungs at a quarter of the symbol rate
This run came up at **`fps = 312`**, not the 1246 of every previous run — a **4× lower symbol
rate** (312 × 12,320 = 3.84 Msym/s against 15.35). The demod marker spacing was **still exactly
12,320**, so the frame is defined in symbols and unchanged.

**And the displacement landed on rung 2 (6240 symbols) — a known rung, to the symbol.** The ladder
is therefore **rate-independent in symbol units**: a 4× change in absolute symbol rate does not move
the rungs. That constrains mechanism — a defect tied to absolute time would move; one tied to frame
structure does not.

### The instrument defect that produced the rate change
The arm sequence I have been calling "the proven full arm" does:
```
cat /root/jupiter_240k5.bin  > .../stream_config   2>/dev/null
cat /root/jupiter_240k5.json > .../profile_config  2>/dev/null
```
**Neither file exists on 148.** `ls` returns *"cannot access '/root/jupiter_240k5.json': No such
file or directory"*; the profiles present are `lvds_61p44_fdd_jupiter.bin`,
`lvds_30p72_*`, `lvds_15p36_*`, `lvds_1p92_mhz.bin`. **Both loads have been failing silently into
`/dev/null` every time.**

So the arm never sets a profile — it **inherits** whatever is loaded. Previously that was
`lvds_61p44_fdd_jupiter`, left by an earlier `bringup_r2r3.sh r3` (which is where the 1246 f/s came
from). After a cold boot there is no such leftover, hence 312 f/s.

**A step redirected to `/dev/null` that fails on every run and changes the experiment's rate is
exactly the class of fault this campaign keeps finding** — silent, invisible, and load-bearing.
Fix: name the profile that exists (`lvds_61p44_fdd_jupiter`) and **do not** swallow the error.

### What it does NOT invalidate
Every result stands: the frame geometry, the offset maps and the rungs are all in symbols, and the
rate does not move them — as this run demonstrates directly. It does mean **`fps` is not a health
criterion on its own**; the criterion is `capTAP` golden plus a stable frame rate, whatever that
rate is.

---
## §50 FIVE CLEAN CAPTURES: §43's no-intermediate-offset prediction holds on purpose-built data

All five taken from a link whose `capTAP` read golden immediately before capture, at most two
captures per arm (§48), across two different link rates.

| capture | rate | trigger errs/s | result |
|---|---|---|---|
| 08:04 | 1250 | 31,801 | **11/11 displaced @ 6299 = rung 3** |
| 08:36 CAP1 | 312 | 0 | **10/10 aligned @ 0** |
| 08:36 CAP2 | 312 | 14,435 | **11/11 displaced @ 6240 = rung 2** |
| 08:43 CAP1 | 312 | 3,739 | **11/11 displaced @ 6240 = rung 2** |
| 08:43 CAP2 | 312 | 9,959 | 11/11 aligned @ 0 — see caveat |

**Every displaced capture sits on a known rung to the symbol; every aligned one at exactly 0. No
intermediate offset has appeared in any clean capture** — §43's prediction, now tested on data
gathered specifically to test it, at two link rates 4× apart.

Within each capture the offset is **constant across all 10–11 frames** (§39 again, five more times).

### Caveat on the last row — trigger-to-capture latency
08:43 CAP2 triggered at 9,959 errs/s but captured aligned frames, and its **post**-probe read
`errps=536` with `capTAP=0x6B47D467` (rung 4's word). The burst ended between trigger and capture,
and the post-probe sampled a different moment again. **This is not evidence for §44's
errors-without-displacement episode** — it is most likely a post-burst quiet capture.

**The trigger loop polls `0x108` over a 1 s window and then starts a capture, so the capture begins
1–2 s after the burst is detected**, against bursts lasting ~6 s. Usually inside; not always.
§44's episode type 3 therefore still rests only on last night's possibly-degraded captures, and
confirming it needs a **shorter trigger-to-capture gap**, not more captures of this design.

### Instrument note
`arm148_mode1.sh`'s refusal path was checked for its **exit code**, not just its message: an absent
profile gives `rc=2`. A gate that refuses while exiting 0 has been found four times in this
campaign; this one signals correctly.

---
## §51 PRE-REGISTRATION — burst-onset capture (written BEFORE any data is taken)

Operator-directed. Option 2 + larger capture, spent as **one** revision of the capture instrument.
Recorded before the runner exists so the answer cannot be read backwards out of the data.

### The design
Predict the next burst from its own periodicity rather than reacting to the error counter, **arm
the capture 1–2 s AHEAD of predicted onset** so the capture brackets the transition, and **re-sync
the prediction against `0x108` periodically** (measured periods drift: 121.8, 119.8, 121.8 s).
Capture as large as the rig tolerates — ceiling to be established empirically, not assumed.

### What ONSET must look like in the capture
Frames are scored individually (§39). A capture spanning the onset contains a run of frames at
**offset 0**, then the transition, then a run at a **rung** (6176/6240/6299/6363/6432/6489/6548).
The whole question is what appears **between** those two runs.

### Quantitative predictions, stated in advance
| | JUMP (what §43 predicts) | WALK-IN (the alternative) |
|---|---|---|
| frames at offsets strictly in (0, 6176) | **exactly 0** | **≥ 1**, and monotonically progressing |
| offset step between consecutive frames at the transition | **one step ≥ 6176** | many steps of ≪ 6176 |
| duration of the transition | < 1 frame (3.2 ms at 312 f/s) | 6176 / R seconds for walk rate R |

**The measured within-burst walk rate is ~62 symbols/s (§43).** At that rate a walk from 0 to 6176
would take **~100 s — longer than an entire 3–7 s burst.** So a walk-in at the *known* rate is
already excluded by arithmetic; only a much faster walk could produce one, and that would show as a
dense run of intermediate offsets.

### The falsifier, stated plainly
**Any frame at an offset strictly between 0 and 6176 falsifies "jump".** One such frame is enough
to require re-opening §43. If a monotonic run of intermediate offsets appears, "jump" is dead and
the onset is a fast walk.

### Recovery (burst end)
Same test in reverse: rung → 0. §43 predicts a jump there too. Same falsifier.

### The uninformative outcome, named in advance
A capture lying **entirely inside** or **entirely outside** a burst contains no transition and is
**uninformative** — it must be reported as such, and specifically **must not** be counted as
support for "jump" merely because it contains no intermediate offsets. Only a capture that
demonstrably brackets a 0→rung or rung→0 transition tests the prediction.

### Gates before any of this counts
1. **Capture-path positive control on the new (larger) capture size** — the four-part gate, rerun.
   A larger capture is a different operating point and inherits nothing from the 1 MB result.
2. Every capture from a link whose `capTAP` reads golden immediately before (§48/§50).
3. At most two captures per arm (§48); arming is the hazard.

### Explicitly parked, not chased
The mean-62 rung spacing against nine 64-deep register arrays (§operator direction) stays parked
until the ladder question is closed. It is arithmetic, not a claim.

---
## §52 §45 HAS A CONCRETE ANSWER: `txFrameStart` is an independent marker, already at the top level

Operator question: is there any signal in the path that does not derive from demod `startOut`?

### Every RX marker has one origin — confirmed from the RTL
```
Packet_Controller.startOut -> Frequency_and_Time_Synchronizer.startOut
  -> QPSK_Demodulator.startIn -> QPSK_Demodulator.startOut -> FEC startIn
```
`QPSK_Rx.v:339, 599`; `Frequency_and_Time_Synchronizer.v:220,229`; `QPSK_Demodulator.v:233`.
**There is no independent RX-side frame marker.** That is why the captured demod and FEC markers are
coincident in every capture and can never separate "data moved" from "marker moved".

### But the transmitter has one, and it is already wired up
**`txFrameStart`** — `QPSK_Tx.v:47`, through `Transmitter.v:35/55/152`, present at composite level
as `Transmitter_txFrameStart` (`TxRxComposite.v:272`, used at 1924). In mode-1 internal loopback the
transmitter is the same fabric, so it is a **true independent time reference for the RX data**.

### What it would cost — less than expected
The capture's four channels are I, Q, demod marker, FEC marker, and **the FEC marker is redundant**
(§45: coincident with the demod marker in every capture, by construction). So repoint that channel:

`ddrcap_fec_mark_now = Receiver_ddrcap_fecstart` → `Transmitter_txFrameStart`
(`TxRxComposite.v:2116`, one line in `ddrcap_inject.py`)

- **no new IP ports** — `ddrcap_mark_fec` already exists at the boundary
- **no BD change** — same four channels, same packer wiring
- **no MATLAB regeneration**
- source-only resynth (~50 min) + one flash

Every capture would then carry a **TX-anchored and an RX-anchored marker simultaneously**, and the
separation between them is the §45 answer directly, per frame, with no inference.

**Not done in this revision** (operator-directed). Recorded as the cheapest path to it.

---
## §53 **JUMP CONFIRMED — the pre-registered test passes, and the burst's real structure appears** [SILICON]

First capture of the §51 design. 512 MB = 67,108,864 beats = **5,451 frames = 4.37 s** at 1247 f/s,
started 0.93 s before a predicted onset. Link verified `capTAP=0xBCF94856` golden before **and**
after (`fps` 1250 → 1251, no degradation). Positive control passed at this exact operating point
(§ gate `DDRCAP_PC_LARGE ALL PASS`, 1361/1361 marker intervals).

### The pre-registered result
```
scored 5451 frames: 5447 placed, 4 displacement-inexplicable
  aligned at 0          : 3008
  on a known rung       : 2439   [6240 x1208, 6363 x1231]
  INTERMEDIATE (0,6176) : 0          <-- §51's falsifier
  0<->rung transitions  : 2
     frame 1907: 0 -> 6240  (step 6240)
     frame 4179: 0 -> 6363  (step 6363)
```
**Transitions are present, so the capture is informative; and zero frames sit at an intermediate
offset across 5,447 frames.** Each transition is a **single-frame step of the full rung magnitude**.

**§43's jump prediction is confirmed, on the test written before the data existed.**

### The run structure — the burst resolved for the first time
| offset | frames | duration | |
|---|---|---|---|
| 0 | 342 | 0.27 s | aligned |
| — | **1** | — | unmapped |
| 0 | 1324 | 1.06 s | aligned |
| — | **1** | — | unmapped |
| 0 | 239 | 0.19 s | aligned |
| **6240** | **1208** | **0.97 s** | **rung 2** |
| — | **1** | — | unmapped |
| 0 | 1063 | 0.85 s | aligned |
| **6363** | **1231** | **0.99 s** | **rung 4** |
| — | **1** | — | unmapped |
| 0 | 40 | 0.03 s | aligned |

### Three things this changes
1. **A burst is ~1 s, not 3–7 s.** 1208 and 1231 frames — 0.97 and 0.99 s. Every previous duration
   came from 1 Hz sampling that could not resolve it.
2. **Each burst sits at exactly ONE rung** and holds it for ~1200 consecutive frames. There is **no
   within-burst walk** at this resolution. §32's apparent rung progression was successive
   *sub-bursts* at different rungs, seen through 1 Hz sampling — the ordering was real, the
   continuity was not.
3. **The ~120 s period is an envelope, not the burst.** Two complete bursts appear inside 4.37 s,
   separated by 0.85 s of alignment. The 120 s cycle contains many ~1 s sub-bursts (consistent with
   the 240 s error scan, which showed a 16-second cluster of high-error seconds).

### The transition frame
Entry and exit each show **exactly one unmapped frame** — 4 in total, matching the 4 transitions.
That is the frame whose 16-symbol window straddles two alignments, so it belongs to neither. It is
the jump happening *inside* one frame, and it is why §38's mid-window-straddle test found no match
against a single rung pair: the straddle is real but lasts one frame and mixes offset 0 with a rung.

---
## §54 SECOND CAPTURE, INDEPENDENT CONFIRMATION — and a silent truncation found

`onset_02.bin` [SILICON, 209 MB, `capTAP` golden after, `errps=17119` at the post-probe]:
```
scored 2220 frames: 2220 placed, 0 displacement-inexplicable
  aligned at 0          : 1477
  on a known rung       : 743   [6176 x743]
  INTERMEDIATE (0,6176) : 0
  transition            : frame 1477: 0 -> 6176  (step 6176)
```

**A third transition, at a third rung, and again zero intermediate offsets.**

### Combined, across both captures
| | |
|---|---|
| frames scored | **7,667** |
| 0↔rung transitions | **3** (to rungs 6176, 6240, 6363) |
| frames at an intermediate offset | **0** |

Three transitions at three different rungs, every one a single-frame step of the full rung
magnitude, zero intermediate offsets in 7,667 frames. §51's falsifier had three chances to fire
and did not.

### A refinement: the straddle frame is not always there
Capture 1 showed exactly one unmapped frame at each of its transitions; **capture 2's transition
has none — 0 unmapped frames in 2,220.** So the jump sometimes lands exactly on a frame boundary
and produces no straddled window at all. The straddle frame is a *consequence* of where the jump
falls within a frame, not a feature of the jump.

### The truncation, and why it did not corrupt anything
Capture 2 is 209 MB, not the requested 512 MB. `/tmp` on the board is a 981 MB tmpfs and the runner
never deleted capture 1's 512 MB file, so capture 2 filled the remaining space and stopped.
**`iio_readdev` returned success and wrote a short file** — a silent truncation, caught only by the
byte count.

Fixed: the runner now deletes the board-side file immediately after transfer, logs the free space,
and **flags any capture shorter than 90 % of the requested size as truncated**. The data itself is
sound — a truncated capture is a shorter capture, not a corrupted one — but a run that silently
halves its own coverage is exactly the kind of thing that gets read as "the burst was shorter".

---
## §55 **SUB-FRAME EXCURSIONS: displacement is NOT confined to the seven rungs** [SILICON]

Found by asking whether the *aligned* frames of `onset_01` are bit-perfect over the **whole**
frame, rather than merely matching in the 16-symbol window the scorer uses.

**7 of 401 aligned frames are not bit-perfect.** They are not corrupted — they are **mid-frame
displacement excursions**:

| frame | aligned for | then displaced by | for | tail match |
|---|---|---|---|---|
| 57 | 6598 symbols | **1356** | 5722 symbols | **100.0 %, both rails, exact** |
| 93 | 8851 symbols | **1647** | 3469 symbols | **100.0 %, both rails, exact** |
| 393 | 3607 symbols | **684** | 8713 symbols | **100.0 %, both rails, exact** |

Piecewise profile across the transition, frames 56–58:
```
frame 56: [0 from 0 for 12320]
frame 57: [0 from 0 for 6598]  [1356 from 6598 for 5722]
frame 58: [0 from 0 for 12320]
```
**The excursion begins and ends inside one frame and the neighbours are entirely aligned.**

### Two distinct phenomena, not one
| | persistent (§53) | **sub-frame (new)** |
|---|---|---|
| duration | ~1200 frames ≈ 1 s | part of **one** frame |
| displacement | one of the **7 rungs** | **684, 1356, 1647 — not rungs** |
| entry/exit | single-frame jump | within the same frame |
| visible to | every instrument | **only a full-frame check** |

### What this does and does not do to §51/§43
**§51's falsifier did not fire, literally and correctly:** it was defined on the offset measured at
**frame start**, and across 7,667 frames not one sat between 0 and 6176. §53 stands as written.

**But the underlying idea — that displacement only ever takes seven discrete values — is now
wrong.** Intermediate displacements occur; they are simply **transient and sub-frame**, and every
instrument in this campaign measured at frame start and could not see them. That is new information
the pre-registration did not anticipate, and it is recorded as such rather than folded into §53.

### A candidate explanation for §44's "type 3", to be checked not assumed
§44 reported an episode with 46,907 errs/s where every frame looked **aligned** by the 16-symbol
test — and inferred the errors must arise downstream of the demod input. A sub-frame excursion
produces exactly that signature: the window at frame start is aligned, so the frame scores as
aligned, while thousands of symbols later in the frame are displaced and the BIST counts errors.
**§44's downstream localisation may therefore be unnecessary.** I checked only 4 frames of that
capture full-frame at the time; that is too few. It needs the full-frame test over many frames
before either reading is credited.

---
## §56 §44's LOCALISATION IS OVERCLAIMED — the errors are frame-bursty, which is a different result

Re-tested §44 properly: **every** frame of `burst_04` full-frame checked, not the 4 I checked at
the time.

```
frames checked : 10
bit-perfect    : 10        (all 12,320 symbols, both rails)
not perfect    : 0
```

So §55's sub-frame excursions do **not** explain §44 — these frames really are perfect. But that
is not the same as §44's conclusion, and the arithmetic shows why:

| | |
|---|---|
| 46,907 errs/s over 1246 frames | **37.6 errors per frame** |
| BIST scores 120 bits/frame (§5) | **31 % BER** if uniform |
| our capture | **10 frames = 0.80 % of that second** |
| those 10 frames | **bit-perfect, zero errors** |

**If the errors were spread uniformly, every frame would carry ~37 errors in its first 120 bits.
Ten consecutive perfect frames is then essentially impossible.** So the errors are **concentrated
in a minority of frames** — the capture landed in a clean stretch.

### What §44 may claim, and what it may not
- **May claim:** during this episode the demod input was bit-perfect in the frames captured, and
  the errors are **frame-bursty**, not uniform. That is a real and new result about their
  distribution.
- **May NOT claim:** that the defect lies downstream of the demod input. **The erroring frames were
  not captured.** A 0.8 % sample that happens to be clean says nothing about the 99.2 % that
  carried the errors.

**§44's "first burst episode localised to a stage" is withdrawn.** It rested on 4 frames then and
survives on 10 now, but 10 frames cannot localise a defect whose carriers are elsewhere in the
second.

### How to settle it
Capture continuously across a full second (512 MB = 4.37 s already spans it) and full-frame check
**every** frame, looking for frames that are *not* bit-perfect at any displacement. Those are the
error carriers, and whether they show a displaced or a genuinely corrupted demod input is the
localisation §44 wanted. The data may already exist in `onset_01`.

---
## §57 **ALL THE ERRORS ARE POSITION** — every error carrier in a 4.37 s capture, classified [SILICON]

The test §56 named, run on `onset_01` (5,450 frames, 4.37 s, link golden before and after).

### Step 1 — find the error carriers
Full-frame check of **every** frame against the eight known displacements:

| | frames |
|---|---|
| bit-perfect at displacement **0** | 2,953 |
| bit-perfect at **6240** | 1,192 |
| bit-perfect at **6363** | 1,207 |
| **not perfect at any known displacement** | **98 (1.80 %)** |

Those 98 are the error carriers — the frames §56 predicted must exist somewhere in the second.

### Step 2 — classify them: position or corruption?
For each, walk the frame in segments, identifying each segment's displacement from the offset map
and requiring an **exact** match to the end of the segment:

| | |
|---|---|
| explained as a piecewise **POSITION** sequence | **90 / 98** |
| segments per frame | **2 in 88 of them** — a single mid-frame jump |
| not parseable as position | 8 |

**The 8 are frames 342, 1667, 1906, 3114, 3115, 4178, 5409, 5410 — and they sit adjacent to the
transition frames** (1907 and 4179 are the 0→rung transitions found in §53; the rest pair up).
Those are frames where the 16-symbol probe window my classifier uses to identify a segment itself
straddles a jump, so the method breaks down. **No frame is demonstrated to be genuinely corrupted.**

### The answer to §44, and it is the opposite of what §44 concluded
**The errors are not from a downstream defect. They are sub-frame position excursions at the demod
input.** §44 inferred a downstream stage because its 10 sampled frames were perfect; the erroring
frames were simply not in that sample, and when you find them they are displacement, not
corruption.

### And the displacement is a continuum, not a ladder
Displacements seen *inside* error-carrier frames:

| displacement | count | |
|---|---|---|
| 0 | 54 | known |
| 6363 | 24 | **rung** |
| 6240 | 16 | **rung** |
| 1148, 7686 | 2 each | — |
| 1356, 1647, 2208, 1355, 1195, 684, 1826 | 1 each | — |

**The seven rungs are the persistent states. The transient mid-frame excursions take arbitrary
values** — each seen once or twice, spread across the frame. So displacement is not quantised;
only the *long-lived* displacements are, and those are what every previous instrument sampled.

---
## §58 PRE-REGISTRATION — the §45 discriminator (written BEFORE the image is built)

Operator-directed. Repoint the redundant FEC-marker capture channel at
**`Transmitter_txFrameStart`**, giving every capture a **TX-anchored** marker (ch3) alongside the
**RX-anchored** demod marker (ch2). §45 could not say whether the data moved or the marker moved
because both captured markers descend from demod `startOut`; a TX-side marker does not.

### The measurement
Per frame, two quantities:
- **S** = separation between the TX marker (ch3) and the RX demod marker (ch2), in beats.
- **D** = data displacement relative to the RX marker — the existing §31 measurement.

In quiet frames S takes some fixed value **S₀** (the loopback latency through the chain).

### The two hypotheses, quantitatively
| | **DATA moved** | **RX MARKER moved** |
|---|---|---|
| during a rung episode, S | **unchanged, = S₀** | **shifts by exactly the rung**, S = S₀ ± D |
| interpretation | the datapath delivers symbols at the wrong position; frame detection is correct | frame detection fires at the wrong place; the datapath is fine |

**These are mutually exclusive and the capture measures both quantities on the same frame**, so a
single displaced frame decides it.

### Falsifier
- If S is constant to within a few beats across quiet **and** rung frames while D = 6240 (say),
  **"marker moved" is dead** and the data moved.
- If S shifts by 6240 in exactly those frames where D = 6240, **"data moved" is dead**.
- If S shifts by an amount **unrelated** to D, both simple readings are wrong and §45 must be
  re-thought rather than answered.

### Gates before it counts
1. The change must be verified in the built RTL — `ddrcap_mark_fec` driven from
   `Transmitter_txFrameStart`, not `Receiver_ddrcap_fecstart`.
2. **Positive control at the operating point**, including a new part: the two markers must be
   **non-coincident** in quiet frames. If they still coincide, the change did not take and no
   §45 conclusion may be drawn — a redundant second marker is exactly the §45 problem again.
3. Golden digests unchanged (`0xBCF94856` / `0xF00003FF` / `0x8F9ED095`) — this is an RTL edit and
   must not disturb the existing witnesses.

### Scope
One line of RTL behind an injector flag (`TXMARK=1`), default off so the change is reversible.
Source-only resynth, no BD change, no MATLAB regeneration. Recorded as operator-directed new
capability, not a revision spent against the capture instrument's cap.

---
## §59 THE ARM HAZARD, QUANTIFIED — ~1 in 3, and it dominates every design decision [SILICON]

Today's tally, one line per arm:

| time | arm | outcome |
|---|---|---|
| 07:35 | `bringup_r2r3.sh r3` (two-board) | **146 HUNG** |
| 07:47 | `arm148_mode1` | ok |
| 08:01 | armed trial 1 | ok — produced the clean rung-3 capture (§48) |
| 08:04 | armed trial 2 | **148 HUNG** |
| 08:36 | one-arm-two-capture | ok |
| 08:41 | one-arm-two-capture | ok |
| 09:42 | arm (wrong profile, my error) | ok |
| 09:44 | arm (`lvds_61p44_fdd_jupiter`) | ok — full rate restored |
| 11:25 | arm after the TXMARK flash | **148 HUNG** |

**9 arms, 3 hangs — ~33 % per arm.** Against **30+ captures today with zero hangs**, including a
graded probe of 24 captures / 29.7 MB that performed no arms at all (§48).

### What follows for the experiment design
Every arm is a ~1-in-3 chance of losing the board until an operator can power-cycle it. So:
- **Minimise arms, not captures.** This inverts the one-capture-per-arm design I built this morning
  to guarantee capture quality (§48): it maximised the count of the one operation that is dangerous.
- The §48-safe pattern (**arm once, capture ≤2**) is right in direction but too conservative on the
  capture side. At 312 f/s five back-to-back captures left the link golden; the degradation that
  motivated the ≤2 limit is **rate-dependent** and appears at 1247 f/s from about capture 3.
- **Best current pattern: arm once, then capture as many times as the rate allows, re-checking
  `capTAP` between captures and stopping at the first sign of degradation.** Degradation is
  recoverable by re-arming; a hang is not recoverable without a human.

### What it does not affect
The flash rails are unrelated to this and have never failed: 3 flashes today and last night, every
one clean on the first attempt with readback verify and a banked restore point. **The image
persists across power-cycles**, so a hang costs time, not work.

---
## §60 §59 IS WRONG AS STATED — the hazard is `direct_reg_access` traffic, not "arming"

§59 concluded from 9 arms / 3 hangs against 30+ hang-free captures that **arming** is the hazard.
**Its own follow-up run falsifies that.**

At ~11:5x the onset runner hung 148. **That runner does not arm.** It polls `0x108` and captures,
and its log is **0 bytes** — it died before its first line, during the initial probe/sync, not
during a capture.

### What actually distinguishes it
| | safe runs (30+ captures) | this run |
|---|---|---|
| `0x108` poll interval | **1 s** | **0.25 s** |
| register-read rate | 1× | **4×** |
| arms performed | some | **none** |

The documented lab fault (MEMORY, four outages in August) is **a `direct_reg_access` read racing
board state**, not "arming" as such. That single mechanism explains **all five** of today's hangs:
an arm makes the race likely because the profile reload leaves the AXI path vulnerable; a 4 Hz poll
makes it likely by volume alone.

**Corrected rule: minimise `direct_reg_access` traffic, and never raise its rate.** Arms remain the
most dangerous single operation because they combine a vulnerable window with register access, but
they are an instance, not the category.

### My error, specifically
I raised the poll to 0.25 s to cut trigger latency — **after** establishing (and telling the
operator) that latency was *not* the binding constraint, coverage was. It bought nothing and cost
a board. The runner is back to a 1 s poll with the burst threshold rescaled to the 1 s window.

### What was NOT lost
Everything from that arm is banked: all four gate parts passed, the three golden digests are
unchanged, the markers separate (0 of 1361 coincident), and **S₀ = −48 beats with spread 0 across
1,360 frames** — the TX marker leads the RX marker by exactly 48 symbols on every frame. That is
the §58 baseline, and it is solid.

**§45 still needs one capture containing displaced frames.** The instrument is proven; only the
sample is missing.

---
## §61 REFERENCE: how the DDR capture actually works (read from the design, no rig)

### There is no trigger
`ddrcap_valid` is asserted on **every qualifying beat, continuously, from reset**. Nothing arms it,
nothing gates it, and the fabric has no notion that a "capture" is occurring. **The capture window
is defined entirely by the host**: `iio_readdev -s N` opens the IIO buffer, streams N samples and
closes it. Start = buffer open; end = N samples delivered. Neither boundary is aligned to a frame,
a burst or a marker.

**Consequence, and it is why coverage beat latency (§51):** the hardware cannot be asked for "the
next burst". It can only be asked for "N samples starting now", so N alone determines how much of
the timeline is obtained. A fabric trigger would remove that limit entirely — not attempted, noted
for whoever picks this up.

### The path
```
TxRxCompo_ip_0 (modem IP)
  dut_ddrcap_i/_q/_mark_demod/_mark_fec -> util_adc_2_pack/fifo_wr_data_0..3
  dut_ddrcap_valid                      -> util_adc_2_pack/fifo_wr_en
  VCC_1                                 -> util_adc_2_pack/enable_0..3
        -> axi_adrv9001_rx2_dma (the IDLE RX2 receive DMA) -> DDR
```
Samples originate **inside the modem IP**, never from the ADC. RX1
(`util_adc_1_pack` → `axi_adrv9001_rx1_dma`) carries the live link and is untouched. The packer's
**clock and reset were moved** to `adc_1_clk`/`adc_1_rst`, the modem's own domain. `ddrcap_valid`
drives **`fifo_wr_en`**, not the `enable_*` pins — the enables are tied high so all four channels
participate; driving the enables would mask channels rather than gate beats.

### Boundary: host. Content: hardware.
The host chooses when the window opens and how long it is; the fabric chooses which beats are
written and what each record holds. A capture is a **host-chosen slice of a continuous hardware
stream**.

### Tap point (TXMARK image, selector 6)
`TxRxComposite.v:2019` — `Receiver_ddrcap_constpts_re/_im`, the **`QPSKConstellationPoints` node =
the demodulator's input**, qualified by `QPSKConstellationValid`. Same node DBGCAP tap 3 reads,
which is why the digest cross-check works, and **combinational** — one `enb_1_2_0` tick ahead of
DBGCAP's registered copy (§36's `marker+1`).

### Record layout — markers are in the SAME record as the I/Q
One beat = one 4x16-bit record: `[ I | Q | demod marker | TX frame marker ]`. Markers are full-width
`0x7FFF`/`0x0000` words, never packed bits, because a dropped strobe would read as a lag jump and
fake the measurement. All four are written by the same `fifo_wr_en` on the same beat, so I/Q and
both markers are **inherently time-aligned within a record**.

**That is what makes the §45 discriminator sound:** S (marker separation) and D (data displacement)
are read from the *same record*, so no capture-side artefact can drift them apart.

---
## §62 **§45 IS ANSWERED: THE DATA MOVED. The frame marker did not.** [SILICON]

TXMARK image `1cd0cd752aa6`, one arm, one 512 MB capture containing **both** aligned and displaced
frames — so S and D come from the same arm, the same link state and the **same records**. All gates
green beforehand: four-part positive control ALL PASS, three golden digests unchanged, markers
separated (0 of 5,445 coincident).

```
    displacement D   frames   S (median)   S = -48
                 0     2130          -48    100.0 %
              6176      894          -48    100.0 %
              6299     1216          -48     99.9 %
              6432     1203          -48     99.8 %
```

**The TX-to-RX marker separation is −48 beats whether the frame is aligned or displaced by 6176,
6299 or 6432 symbols.** Not a median with a spread — **100 %, 100 %, 99.9 %, 99.8 %** of frames sit
at exactly −48. The three exceptions are single frames at transitions, where the nearest-marker
search picks the neighbouring frame's marker.

### The answer
**The frame detector fires at the correct time. The datapath delivers symbols at the wrong
position.** §58's two hypotheses were mutually exclusive and the data chooses one without ambiguity:
S is invariant under D.

- **DATA moved** ✔ — S unchanged across a 6,432-symbol displacement
- MARKER moved ✘ — would require S to shift by exactly D; it shifts by **0**

### Why this is the strong form of the result
Every displacement figure from §31 to §57 was *data relative to the RX marker*, and §45 recorded
that such a measurement cannot say which side moved. It now can, because a second, **independent**
marker — `Transmitter_txFrameStart`, which does not descend from demod `startOut` — rides in the
**same 4×16-bit record** as the I/Q (§61). No capture-side artefact can move one without the other.

### What it means for the search
The defect is **in the receive datapath, not in frame synchronisation**. Everything downstream of
frame detection that can deliver correct symbols at a wrong offset is in scope; the preamble
detector and the frame-start machinery are **out** of scope for the displacement itself.

Combined with §57 (all errors are position) and §53 (jumps, not walks), the shape is now: a
**datapath that intermittently delivers the right data from the wrong place, in single-frame steps,
against a frame clock that never wavers.**

---
## §63 PREAMBLE-DELAY-FIFO INSPECTION: the witness exists, its readout does not, and the SIM GATE FAILS

Operator-directed source reading. No rig, no build.

### The witness is already in the RTL
`FIFO.v` outputs, sampled once per frame against a pop counter that wraps at `14'd12332`:
```
witA = {2'b0, numEntries[13:0], per_frame_addr_diff[13:0], 2'b0}
witB = {push_on_full_count[15:0], displacement_events[7:0], max_per_frame_diff[7:0]}
```
**Occupancy and push-pop delta** — exactly what a displacement question would ask of a FIFO. Built
for the earlier beat work. `Preamble_Detector.v:338` still wires `.witA(pdWitA) .witB(pdWitB)`.

### But nothing reads it in this lineage
`QPSK_Rx.v:773`:
```
assign beatfix_viol_count = fixctl[13] ? mdcapl : dcapl;
assign beatfix_viol_latch = fixctl[13] ? mdcmm  : dcmm;
```
**DBGCAP and DEMODCAP own `0x20C`/`0x210`.** `pdWitA`/`pdWitB` terminate unconnected. **The flashed
TXMARK image cannot show FIFO state.** Observing it requires new routing → a Vivado build.

### THE GATE FAILS: the simulator does not reproduce the phenomenon
Checked directly on the 22-frame sim dump: **21 of 21 frames identical to frame 0, zero differing.**
The sim is a clean mode-1 model and **never displaces**.

The standing rule is *sim reproduction + a candidate that A/Bs clean + a pre-registered witness*.
**The first clause fails.** With no displacement in sim there is nothing to A/B, so a build would
buy **observation without discrimination** — occupancy traces that cannot be tested against a fix.
That is the §20 dead-counter and §44 ten-clean-frames trap in a new place. **No build requested.**

### What the campaign should do instead, in order
1. **Attempt sim reproduction — free, and now sharply specified.** §53/§62 give the target: a
   *single-frame* jump to ≈0.5013 of a frame, **data intact**, **marker unmoved**, held ~1,200
   frames. That specification did not exist before today and is a far better reproduction target
   than "the beat".
2. **If sim reproduces**, the witness is already designed. Prefer routing occupancy to a **ddrcap
   capture channel** rather than a 1 Hz register: selector 7 is dead (TX modulator reads zero) and
   could carry it at no cost in ports. Occupancy would then land in the **same 4×16-bit record** as
   I/Q and markers — the same structural strength that made §62 decisive.
3. **Meanwhile, free analysis**: the unparked rung-spacing arithmetic (mean 62 vs nine 64-deep
   arrays; the ladder at half the FIFO's 12,333-pop cycle) on data already captured.

---
## §64 THE RUNGS ARE 64-QUANTISED WITHIN FAMILIES — and the two exceptions are the I/Q-swapped ones

Operator unparked the rung-spacing arithmetic now that §53/§62 have closed the ladder question.
Pure analysis of captured data; no rig, no build.

**"Mean spacing 62" was an artefact of averaging across families.** Grouping the rungs by residue
mod 64:

| residue mod 64 | rungs | internal deltas | |
|---|---|---|---|
| **32** | 6176, 6240, 6432 | **64, 192** | plain rungs 1, 2, 5 |
| **27** | 6299, 6363 | **64** | plain rungs 3, 4 |
| 25 | 6489 | — | **I/Q-SWAPPED** rung 6 (§42) |
| 20 | 6548 | — | **I/Q-SWAPPED** rung 7 (§42) |

All pairwise differences that are exact multiples of 64: 6176→6240 (64), 6240→6432 (192),
6176→6432 (256), 6299→6363 (64).

### Stated with its null, per §28's rule
Drawing 7 values at random from the same 372-wide span, 200,000 trials:

| | |
|---|---|
| observed pairs with a delta that is a multiple of 64 | **4** |
| expected under the null | **0.27** |
| **P(≥4 by chance)** | **0.0004** |

### The part that is more than arithmetic
**The five plain rungs fall into two 64-quantised families. The two rungs that do not fit are
exactly the two that carry the I/Q swap** (§42, rungs 6 and 7 at 0.5267 and 0.5315). That
correspondence was not sought — the families were found by residue, the swap was established
independently three sections earlier.

So displacement appears to come in **64-symbol steps within a family**, with a small offset between
families (32 → 27), and the swapped episodes sit outside the quantisation entirely.

**This remains an observation about numbers, not a mechanism.** It is recorded because p = 4·10⁻⁴
and because the swap correspondence is independent, not because 64 matches the nine `[0:63]`
register arrays in the design — that match is *suggestive and untested*, and testing it needs the
sim reproduction that §63 shows we do not yet have.

---
## §65 **STOP — THE PREAMBLE DELAY FIFO WAS ALREADY EXCLUDED ON SILICON (2026-08-30)**

Before starting sim-reproduction work on the delay FIFO I checked the project memory. **That
hypothesis was killed a day before this campaign began, on silicon, and I nearly re-ran it.**

From `memory/beat-120s-status.md`:

> **KILLED 2026-08-30 on silicon:** the delay-FIFO displacement / push-on-full hypothesis is
> FALSIFIED. Witness image `786dce9fafc8` (in-FIFO counters read via the unused 0x20C/0x210) shows
> `occ=12333 diff=0 events=0 push_on_full=0` through **SEVEN full bursts** across both fixctl arms;
> the slack fix (fixctl bit 3) is indistinguishable from legacy in loopback and on air.

That is exactly the measurement §63 proposed building an image to make: `witA`'s occupancy and
push-pop delta, through bursts. **It was made, it is flat, and the FIFO is excluded.**

> The sim reproduction (push/pop address +1 → ~42-56 err/frame persistent, recovery on the
> compensating event) is a faithful **ANALOGUE** but is not what the hardware does.

So the sim *can* be made to displace — §63's "the sim never displaces" is true of a clean run and
false as a general statement. But the induced mechanism is one silicon has ruled out.

### What this costs and what it saves
§63's recommendation — "look at the preamble delay FIFO, attempt sim reproduction there" — **is
withdrawn.** It would have re-derived a falsified result at the cost of a build and rig time.

### What the same memory says is still open, filtered through today's results
> Search moves downstream of the delay FIFO (**Rate_Handle/serializer phase**, demod start/valid
> marker path, deinterleaver alignment) — none tested.

Applying today's findings to that list:
- **demod start/valid marker path — EXCLUDED by §62.** The marker does not move; the data does.
- **deinterleaver alignment — EXCLUDED by §57/§62.** The displacement is measured at the
  demodulator *input*; the deinterleaver is downstream of the demod output.
- **Rate_Handle / serializer phase — SURVIVES.** It sits between the delay FIFO and the demod
  input, i.e. inside the span §62 leaves in scope, and it is untested.

**`Rate_Handle` is now the only named untested candidate consistent with every measurement made
today.** Its FIFO_block is 32 deep (§43 inventory) — note that is *not* 64.

### Process note
I asked "what does looking at the FIFO require" and answered it from the RTL without first checking
what had already been ruled out. The source reading was correct and cost nothing; the
recommendation built on it was wrong. **Check the kill-list before proposing an instrument.**

---
## §66 KILL-LIST CHECK ON `Rate_Handle` — untested, but prior work exists and is generation-mismatched

Applying §65's lesson *before* proposing anything: what already exists for the surviving candidate?

### It is genuinely untested — no result anywhere
Searched memory, the session record and the handoffs: **no measurement of `Rate_Handle` on silicon,
no recorded result.** It is not on the kill-list.

### But it was already suspected, and partly built for
| artefact | what it is | state |
|---|---|---|
| `Rate_Handle.v` outputs `beatobsRhCtr[7:0]`, `beatobsPush[4:0]` | **witnesses already in the RTL** — a rate-handle counter and a push observable | present in the current lineage |
| `s1_rtl_beatobs` | a netlist lineage carrying those witnesses | **never flashed** (no image in `boot_known_good/`), **never run** (no capture output) |
| `s1_rtl_rhfix`, `rhfix2`, `rhfix3` | three drafted **Rate_Handle fixes** | **never flashed, no recorded result** |

So someone reached the same conclusion this campaign has just reached independently — that
`Rate_Handle` is where to look — instrumented it, drafted three fixes, and stopped before testing
any of it.

### The catch
`NETLIST_PROVENANCE.md` scores those lineages against the flashed generation:
`s1_rtl_beatobs` **121 differing files**, `s1_rtl_rhfix*` **421** — versus `s1_rtl_beatfix3` at 32,
the generation that matches what is flashed. **The prior Rate_Handle work is on a different, older
generation** and cannot be flashed or trusted as-is. Its *ideas* transfer; its netlists do not.

### Status, no proposal attached
- `Rate_Handle` sits between the delay FIFO and the demod input — inside the span §62 leaves open.
- Its `FIFO_block` is **32 deep**, which does *not* obviously explain §64's 64-symbol quantisation.
  That is a point **against** it, recorded because it is inconvenient.
- Witnesses for it already exist in RTL but reach no readable register in the flashed image, exactly
  as the FIFO witness did (§63).

**No build is being requested.** The standing rule needs sim reproduction first, and §65 showed the
only sim reproduction on record is an analogue of a mechanism silicon has already excluded.

---
## §67 **§62 IS UNDER-DETERMINED** — S-invariance does not exclude an upstream sample slip

Raised by the operator, and correct. Recording it against §62 immediately rather than leaving the
stronger reading standing.

### What §62 actually proves
The TX→RX marker separation S is **−48 beats at every displacement** (100 / 100 / 99.9 / 99.8 % of
frames). That proves the frame detector fires at the **correct time** relative to an independent TX
reference. It does **not** prove the detector points at the same **place in the sample stream**.

### The alternative §62 does not exclude
**A clean whole-block insertion or deletion of samples ahead of the preamble detector** produces the
identical observable:
- detection still fires on schedule → **S stays at −48**
- the stream it points into has shifted → **data appears displaced relative to the marker**
- values are untouched → **bit-exact on both rails**

**A clean upstream sample slip and a downstream datapath displacement are indistinguishable at the
demodulator output.** Every offset measured today (§31–§62) was demod output against the golden
reference, so every one of them is compatible with both.

§62's wording — "the receive datapath delivers correct symbols at the wrong position" — is therefore
**too strong**. The supported statement is: *the data and the frame marker are separated, and the
marker is not late in time.* Where the separation originates is open.

### Carrier recovery is where it could hide
`Frequency_and_Time_Synchronizer.v` instantiation order (135→211):
```
Symbol_Synchronizer -> Coarse_Frequency_Compensator -> Carrier_Synchronizer
  -> Preamble_Detector (dataIn = Carrier_Synchronizer_dataOut)
  -> Phase_Ambiguity -> Packet_Controller -> startOut = THE RX MARKER
```
**The preamble detector's input is the carrier-recovery output.** A re-acquisition, phase wrap or
valid-signal hiccup there would insert or delete samples immediately ahead of detection. **The phase
between frame detection and the carrier-recovery output has never been measured.**

### It is measurable with the flashed image — no build
Six of the eleven live selectors are **upstream** of frame detection; **selector 5 is exactly the
detector's input**:

| sel | tap | vs frame detection |
|---|---|---|
| 0–4 | raw in, AGC, RRC, postSymbolSync, postCoarseFreq | upstream |
| **5** | **postCarrierSync** | **upstream — the detector's own input** |
| 6 | constellation (demod in) | downstream |
| 7 / 8 / 9–11 | dead / TX / bit domain | — |

Because both markers ride in the **same record** as the I/Q (§61), a sel5 capture measures
frame-detect phase against carrier-recovery output directly:
- **sel5 displaced by the same rungs as sel6** → slip at or upstream of carrier recovery; §62's
  downstream reading is wrong.
- **sel5 aligned while sel6 displaces** → displacement genuinely enters between carrier-sync output
  and demod input; §62 survives.

sel1–sel4 then walk the same test further upstream, one capture each, all on one arm.

**Not run. Operator has asked to discuss before any rig or sim work.**

---
## §68 PRE-REGISTRATION — sel5 (carrier-recovery output) phase vs frame detection

Operator-directed, written **before any sel5 data is taken**. Tests §67's under-determination.

### The measurement, and why it needs NO sim reference
`Rate_Handle`-free, sim-free, build-free. The transmitted frame **repeats identically every frame**
(sim frames 21/21 identical; hardware quiet frames bit-exact, §47). So a sel5 capture can be scored
against **itself**: take the modal frame content as the reference R, then for every frame find the
roll d with `frame == R rolled by d`. **No sim reference, therefore no new scaling or unit
conversion, therefore no derived-unit control needed** (§34's rule).

The RX marker (ch2) and TX marker (ch3) ride in every record regardless of selector (§61), so d is
measured **relative to the same frame marker** that sel6's displacement was measured against.

### The two outcomes, and the falsifier for each
| outcome | meaning | falsifier |
|---|---|---|
| **sel5 DISPLACED** — d takes rung-magnitude values (≈6176–6548, ~0.50–0.53 of a frame) on a
minority of frames, 0 on the rest | the sample stream has already slipped **at or upstream of
carrier recovery**; detection points into a moved stream; **§62's downstream attribution is WRONG**
and §67's alternative is the live reading | observing d ≡ 0 on **every** frame across ≥2 bursts, with
sel6-scale displacement demonstrably present in the same window |
| **sel5 ALIGNED** — d ≡ 0 on all frames while sel6 shows rungs | the displacement is introduced
**between carrier-sync output and demod input**; §62 survives as written | observing **any** frame
with d at rung magnitude |

**A third outcome must be reported if it occurs:** d taking values that are neither 0 nor a known
rung. That would mean sel5 moves differently from sel6 and neither reading above is right.

### Positive control on the sel5 path — required before any result counts
Selector 7 read identically zero and was declared dead (§ T2). sel5 must be shown capable of a
**non-null, non-trivial** reading first:
1. **not constant** — >100 distinct I values in the capture;
2. **not a counter** — not ~all consecutive deltas equal (the T1 ADC-ramp trap);
3. **frame-periodic** — the modal frame content must recur across many frames, or there is no valid
   self-reference;
4. **selector-responsive** — a sel5 buffer must differ from a sel6 buffer.
Any part failing ⇒ **sel5 is WITNESS-DEAD and no aligned/null result from it may be credited.**

### Instrument limitation, stated in advance
**sel5 and sel6 cannot be captured across the same burst.** The ddrcap mux carries **one selector at
a time** (§61); there is no way to record two taps simultaneously. The comparison is therefore
across different bursts, which is weaker than the operator asked for. It is acceptable only because
the rung set is **stable across bursts, runs and instruments** (§42/§46/§50) — but any sel5 result
must be read with that caveat attached.

---
## §69 **sel5 IS DISPLACED — the slip is AT OR UPSTREAM OF CARRIER RECOVERY. §62's attribution is WRONG** [SILICON]

The §68 test, run on a fully gated capture. **Operator's §67 hypothesis is confirmed.**

### Provenance of the capture [SILICON, fully gated]
| | |
|---|---|
| pre-check | `capTAP=0xBCF94856` **GOLDEN**, fps 1250, errps 51 |
| trigger | **62,226 errs/s** — a real burst |
| size | 536,870,912 bytes = **100 %** of requested |
| post-check | `capTAP=0xBCF94856` **GOLDEN**, fps 1251, errps 69 |
| arm | captures #1 on a fresh arm |

sel6 was lost when the board hung during capture #2; prior sel6 captures stand in.

### Positive control (§68), on this capture
- **not constant** — 7,143 distinct I in 200k beats · **not a counter** — modal delta 0.0 %
- **frame-periodic** — 5,441 markers, modal gap **12,333** (sel5's own geometry, not sel6's 12,320)
- **valid self-reference** — the modal frame content occurs in **53.7 %** of frames
- **map injective** — 12,333 distinct 16-symbol words over 12,333 offsets, **100 % unique**

### The result
Scored by **self-reference** — modal frame as R, no sim, no unit conversion:
```
5,440 frames: 5,436 placed, 4 unmatched
  aligned to R          : 2,975
  NON-ZERO displacement : 2,461 frames, only TWO distinct values
     d = 6432  x1242   = 0.5215 of a frame
     d = 6299  x1219   = 0.5107 of a frame
```

**6432 and 6299 are rungs 5 and 3 — the same absolute symbol offsets sel6 shows.** (The fractions
differ slightly from sel6's 0.5221/0.5113 only because sel5's frame span is 12,333 against sel6's
12,320; the offsets themselves are identical.)

### What this means, per §68's pre-registration
> *sel5 DISPLACED → the sample stream has already slipped at or upstream of carrier recovery;
> detection points into a moved stream; §62's downstream attribution is WRONG.*

**§62's conclusion — "the receive datapath delivers correct symbols at the wrong position",
understood as downstream of frame detection — is WITHDRAWN.** The displacement is already present
at the **carrier-recovery output, which is the preamble detector's own input**
(`Preamble_Detector.dataIn = Carrier_Synchronizer_dataOut`). Frame detection fires **on time**
(§62's S-invariance stands) into a stream that has **already moved**.

### Scope, corrected
| region | status |
|---|---|
| downstream of frame detection | **no longer implicated** by the displacement |
| **AGC → RRC → symbol sync → coarse freq → carrier sync** | **all now in scope** |
| frame detection / marker path | still excluded as a *timing* fault (§62) |

The operator's §67 reasoning — that a clean whole-block sample slip ahead of the detector is
indistinguishable at the demod output from downstream displacement — was right, and the measurement
that separates them existed on the flashed image the whole time.

**Not chased further.** sel1–sel4 would localise upstream; operator asked to report first.

---
## §70 INVENTORY: what the flashed image already exposes, checked against the open questions

Twice today a decisive measurement turned out to be **already available** and merely unasked:
§63/§65 (the FIFO witness — built AND run in August) and §69 (selector 5 — on the board since the
first ddrcap flash). Doing the inventory deliberately, before spending another arm.

### ddrcap selectors — what each can answer
| sel | tap | domain | status |
|---|---|---|---|
| 0 | `MUX_RxI/Q` raw input | sample | **untested** — the very front of the chain |
| 1 | AGC out | sample | **untested** — most informative single test |
| 2 | RRC filter out | sample | **untested** |
| 3 | postSymbolSync | symbol | **untested** |
| 4 | postCoarseFreq | symbol | **untested** |
| 5 | postCarrierSync | symbol | **DISPLACED (§69)** |
| 6 | constellation / demod in | symbol | **DISPLACED** |
| 7 | TX modulator out | symbol | **DEAD** — reads identically zero |
| 8 | `Transmitter_dataOut` | sample | untested — the TX side of the loopback |
| 9, 10 | `Receiver_ddrcap_demodbit` | bit | **duplicates** — 9 and 10 are the SAME signal |
| 11 | `Transmitter_scramBit` | bit | untested — TX scrambler output |

**Selectors 9 and 10 are wired to the same source.** One of the twelve is redundant, and with sel7
dead the mux really offers **ten** distinct taps, not twelve.

### Registers the image carries
`0x104` packets · `0x108` bit errors · `0x10C` iq_debug_mux (**write-only**, §49) · `0x114`
rx_input_select · `0x124` cnt_frame_start · `0x128` cnt_vit_reset · `0x134` cnt_bist_start ·
`0x130` cnt_dec_bits (**saturates — void**) · `0x13C/0x140/0x144` cap_in/deint/out ·
`0x208` fixctl · `0x20C` capture · `0x210` mismatch (**unusable**, §23)

### What is NOT exposed, and would need a build
- **Preamble delay FIFO occupancy** (`witA`/`witB`) — exists in RTL, reaches no register (§63).
  Moot: already excluded on silicon (§65).
- **`Rate_Handle` observability** (`beatobsRhCtr`, `beatobsPush`) — exists in RTL, reaches no
  register. Untested, and §66 notes its 32-deep FIFO does not explain §64's 64-symbol quantisation.

### The honest summary
**Everything needed to localise the slip from the RX input to the demod input is already on the
board.** sel0–sel4 are five untested taps spanning exactly the region §69 left in scope. No build is
required to finish this localisation — only arms, at ~40 % hang risk each, which is why the bisect
order matters more than the tap count.

---
## §71 PRE-REGISTRATION — the sel1/sel3 bisect (written BEFORE the arm)

Operator-directed. One arm, two captures: **sel1 (AGC out)** then **sel3 (postSymbolSync)**.
Bisects the five untested taps that §69 left in scope rather than walking them.

### Outcomes, stated in advance
| result | meaning |
|---|---|
| **sel1 DISPLACED** | the slip is present at the **very front of the RX chain**, at or before the AGC. The entire DSP chain is transparent to it and the cause lies in the input/loopback path. |
| **sel1 aligned, sel3 DISPLACED** | it enters between **AGC and symbol synchronisation** (AGC itself or the RRC filter). |
| **sel1 aligned, sel3 aligned** | it enters between **symbol sync and carrier sync** — i.e. in the coarse-frequency compensator, the only stage left. |
| **sel1 DISPLACED, sel3 aligned** | **incoherent** — a displacement present upstream and absent downstream. Would falsify the whole "slip propagates forward" model and must be reported as such, not explained away. |

### Falsifier for each
A tap is called **displaced** only if it shows rung-magnitude offsets (≈6176–6548 in symbol domain,
or the sample-domain equivalent) on a minority of frames with the rest at 0. It is called
**aligned** only if **every** scored frame sits at d = 0. Anything else — intermediate offsets, a
continuum, drift — is the fourth outcome and gets reported verbatim.

### Domain caveat, in advance
**sel1 is SAMPLE domain** (~49,349 beats/frame, 4 samples/symbol); sel3 is symbol domain. The
self-reference method does not care, but the frame span differs and **must be taken from each
capture's own marker gap**, never assumed. §49 is the precedent: assuming a span that was wrong by
a factor of 4 produced a spurious 11× and contaminated five sections.

### Controls required before either result counts (§68)
non-constant · not a counter · frame-periodic · modal frame >30 % (valid self-reference) · map
injective. Any failure ⇒ that tap is WITNESS-DEAD and its null does not count.

### Cost
One arm at the measured ~40 % hang rate. Captures #1 and #2 on that arm, `capTAP` golden verified
before and after each.

---
## §72 BISECT RESULT: **sel3 (postSymbolSync) IS DISPLACED. sel1 is WITNESS-DEAD.** [SILICON]

One arm, two captures, both 512 MB and 100 % of requested size.

### sel1 (AGC out) — NO RESULT. Controls failed.
| control | value | verdict |
|---|---|---|
| not constant | **96** distinct I in 200k beats (>100 required) | **FAIL** |
| frame-periodic | modal marker gap 37,185 occurring **5 times of 1,309** | **FAIL** |

Per §68/§71 a tap failing its controls is **WITNESS-DEAD and neither its null nor its non-null may
be credited.** sel1 tells us nothing. This is the sel7 rule applied to my own preferred experiment:
sel1 was the tap I most wanted an answer from, and it does not get a free pass for that.

*(Gating note: sel1's post-check read `0x93E1A9FA` — a known rung word, i.e. the probe caught a
burst frame, not degradation. The capture was legitimate; the tap is simply not a usable witness
at this operating point.)*

### sel3 (postSymbolSync) — DISPLACED. Controls passed.
`567` distinct I · modal delta 1.2 % · modal gap **12,333** in 5,430 of 5,436 · modal frame **50.0 %**
(valid self-reference) · map **100 % unique**. Pre- and post-check `capTAP` **golden**.

```
aligned (d=0)          : 2,722
NON-ZERO displacement  : 1,452 frames, TWO distinct values
   d = 6363  x1232   = 0.5159 of a frame
   d = 6240  x220    = 0.5060 of a frame

run structure:
   6240 x220   = 0.18 s      <- capture opened mid-burst
   None x1
   0    x1068  = 0.85 s
   None x1
   6363 x1232  = 0.99 s      <- a full ~1 s burst
   None x1
   0    x1040  = 0.83 s
   None x1259  = 1.01 s      <- see below
   0    x614   = 0.49 s
```

**6240 and 6363 are rungs 2 and 4 — the same absolute symbol offsets as sel5 and sel6.** Same jump
structure, same ~1 s burst, same single-frame transitions.

### What moved
The displacement is now confirmed present at **postSymbolSync**, two stages further upstream than
§69's carrier-sync output. **The coarse-frequency compensator and the carrier synchroniser are both
transparent to it** — they neither create it nor modify it.

| region | status |
|---|---|
| raw input → AGC → RRC → **symbol sync** | **in scope** (sel0, sel1, sel2 untested/dead) |
| coarse freq, carrier sync | **transparent** — displacement enters before them |
| frame detection and everything downstream | transparent (§69) |

### One thing that is NOT explained
A run of **1,259 consecutive frames (1.01 s) matching R at NO offset** — burst-length, but neither
aligned nor at a known rung. §41/§42 showed the I/Q-swapped episodes look exactly like this to an
offset-only test, so a swapped burst is the obvious candidate. **Not asserted** — testing it needs
the rail decomposition run on this capture, which has not been done.

---
## §73 A THIRD STABLE STATE AT postSymbolSync — not aligned, not displaced, not rail-swapped [SILICON]

Chasing §72's flagged run of 1,259 frames that matched the reference at no offset.

### The I/Q-swap candidate is dead
§41/§42 showed swapped episodes look exactly like this to an offset-only test, so that was the
obvious explanation. Tested by rail decomposition against the reference at every offset:

| frame | best `I` vs `R_Q` | `Q` vs `R_I` at that offset |
|---|---|---|
| 220 | 51.2 % | 51.0 % |
| 1289 | 53.0 % | 49.2 % |
| 2522 | 51.2 % | 51.0 % |
| 3563 | 51.3 % | 51.0 % |

**Chance is 50 % per rail. These are chance.** Not a swap.

### But the frames are a single stable state
Of the 1,262 unexplained frames, **1,256 have byte-identical content** — one state, held for ~1 s,
which is a burst length. And it is not degenerate data:

| | symbol histogram |
|---|---|
| the unexplained state | 3079 / 2989 / 3151 / 3114 |
| the reference R | 3092 / 3138 / 2976 / 3127 |

**Near-uniform, same shape as the reference.** It looks like valid QPSK, it is stable, it is
frame-periodic — and it is **not** a re-alignment of the transmitted frame at any of 12,333 offsets,
nor a rail swap of one.

### What this is and is not
This is at **sel3 (postSymbolSync)**. §57's "all the errors are position" was established at
**sel6**, so this does not contradict it — it is a different tap, and one stage removed.

**Untested candidate, named not asserted:** a *sub-symbol* timing change. The symbol synchroniser
chooses a sampling instant within each symbol period; sampling the same waveform at a different
intra-symbol phase yields hard decisions that are **not** any whole-symbol shift of the original.
That would produce precisely this signature — valid-looking, stable, unmatched at every offset. It
is also exactly the kind of thing a *symbol synchroniser* can do, and nothing downstream of it can.

**Not claimed.** Testing it needs the raw sample-domain waveform at sel2 (RRC out) alongside sel3,
and sel1 has already shown that the sample-domain taps do not automatically pass their controls.

### Where the campaign now stands on scope
| region | status |
|---|---|
| raw input → AGC → RRC | untested (sel0, sel2); sel1 witness-dead |
| **symbol sync** | **displaced (§72) AND shows a third unexplained stable state (this section)** |
| coarse freq, carrier sync | transparent |
| frame detection and downstream | transparent |

---
## §74 THE ASYMMETRY REPRODUCES ON ONE ARM: the third state is at sel3 and NOT at sel5 [SILICON]

§73 found a third state at sel3 and noted it was absent from earlier sel5/sel6 captures — but those
were different arms and different bursts, so the absence could have been episode variation. Retested
**on a single arm**, sel3 then sel5, both fully gated (`capTAP` golden **before and after**, 100 %
size, real burst triggers).

```
sel3 (postSymbolSync)
  [6240x493] [None x1] [0x1065] [None x1] [6363x1230] [None x1] [0x1036] [None x1258] [0x354]
  unexplained 1261 frames; largest identical block 1233      -> THIRD STATE PRESENT

sel5 (postCarrierSync)
  [6176x567] [None x1] [0x1083] [None x1] [6299x1211] [None x1] [0x1050] [None x1] [6432x1240] [None x1] [0x275]
  unexplained 5 frames; largest identical block 1            -> NO THIRD STATE
```

**The asymmetry is real.** Same arm, same link state, minutes apart: sel3 carries a 1,258-frame
unmatched stable state; sel5 carries only single unmapped frames at transitions.

### The structural detail
| | displacement episodes | composition |
|---|---|---|
| sel3 | **3** | 6240, 6363, **third state** |
| sel5 | **3** | 6176, 6299, 6432 |

**Both captures contain exactly three episodes.** At carrier-sync output all three are whole-symbol
displacements onto known rungs. At symbol-sync output, two are rungs and one is **not a whole-symbol
shift at all**.

### Candidate — NAMED, NOT ASSERTED
The symbol synchroniser may convert a **sub-symbol timing error into a whole-symbol displacement**.
Upstream of the symbol decision a fractional shift yields decisions matching **no integer offset** —
precisely the unmatched stable state. Downstream, once decisions are taken, the same episode appears
**quantised to whole symbols** — a rung.

That single mechanism would account for: the sel3/sel5 asymmetry; why displacements are quantised at
all; and possibly §64's 64-symbol structure. It also places the origin **at or before the symbol
synchroniser**, consistent with §72.

**Untested.** The direct test is the **sample-domain waveform at sel2 (RRC out)**, where a fractional
shift is still a shift and should be visible as one. Caveat from §72: sel1 failed its controls at
sample domain (96 distinct values, no stable marker gap), so sel2 may not be a usable witness either
and must clear the §68 controls before anything from it is credited.

### Status of the equal-episode-count observation
Three episodes in each capture is **suggestive, not evidence**: the captures are different bursts,
and §32 established the burst families alternate. It is recorded because it is the kind of detail
that turns out to matter, not because it currently carries weight.

## §75 — sel2 (RRC output) is INDEX-DEAD. No verdict at RRC out. [proven on silicon 2026-09-01]

Retake after I destroyed the first capture (§74a). Full 536,870,912 B, one arm, same golden arm as
sel3/sel5 (`capTAP=0xBCF94856 fps=1247`). Capture `two_jup/pair/20260901_161157_sel2b/sel2.bin`.

§68 controls, pre-registered, run before interpretation:

| control | result | |
|---|---|---|
| 1 not constant | 1026 distinct I in 200k; I,Q span ±4349 | PASS |
| 2 not a counter | modal consecutive delta 0.5 % | PASS |
| 3 frame-periodic anchor | modal marker gap covers **0.3 %** of 1360 intervals | **FAIL** |

The *data* at sel2 is alive — this is not sel1's failure, where the tap itself was dead. What fails is
the **anchor**. Marker gaps: mean 49,310 (the correct sample-domain frame length, 4× the 12,333 symbol
gap), but median 37,433, min 7,258, max 328,048, sd 26,670. Both marker columns behave the same way
(col2 0.07 % within ±2 of median, col3 likewise), so it is not one bad marker source.

Reading: the markers are generated in the symbol/demod clock domain while sel2 records are written at
the sample rate, and the two are not in a fixed ratio in the record stream. The mean is right because
the *count* is right — 1361 markers over 67.1 M beats. The individual spacings are not, so no record
index can be converted to a frame position.

**Consequence.** Displacement at sel2 cannot be scored per frame, in either direction. sel2 yields
neither an aligned nor a displaced reading; it yields nothing. The §73/§74 third state (a stable
sel3 block with no sel5 counterpart) therefore **remains untested at RRC output** — I cannot say
whether it exists ahead of symbol sync or is created there.

Upstream scope after this: sel0 (raw input) and sel2 (RRC out) untested/untestable by marker anchoring;
sel1 witness-dead (§68). Everything from sel3 (postSymbolSync) downstream is measured and displaced.

**Not claimed:** that sel2 is aligned. **Not claimed:** that the fault is at or before symbol sync.
An anchor-free scoring method (self-correlation against a reference frame rather than marker indexing)
would be a *derived* unit and needs its own positive control before any sel2 number counts — §0.

---
## §76 FORCED KICKS DO NOT REPRODUCE THE BEAT: every forced timing-plane state gives corruption or a ±1 excursion, never a rung [reproduced in sim, 2026-09-01 20:15]

Operator-directed experiment replacing the cancelled multi-day unforced run. Pre-registered in
`two_jup/KICK_EXPERIMENT_BRIEF.md` before any run; full report `two_jup/KICK_EXPERIMENT_REPORT.md`.
Netlist = `s1_rtl_txmark` (the flashed-image recipe), flat `--public-flat-rw` build, ROM mode-1 loopback,
force at packet 12, ddrcap **sel6** record stream scored with the existing netlist-derived tap3 offset map
(`t6_score_large.py`, skew 1) — the same instrument and map as §57/§69 on hardware.

| case | frames at 0 | on a known rung | word not in map (corrupted) | transition |
|---|---|---|---|---|
| none (positive control) | 46/46 | 0 | 0 | — PASS: the map applies to this build |
| ss (symbol-sync integrator → max) | 13 | **0** | 26 (frames 13–38) | 0 → None at frame 13, sustained; packet cadence ALSO drops (39 markers vs 46 in the same clock budget) |
| ps (Peak_Search ref +32) | 13 | **0** | 33 | 0 → None, sustained |
| ta (Timing_Adjust ref +32) | 12 | **0** | 34 | 0 → None, sustained |
| slip1 (joint ref +1) | 45 | **0** | 0 | one frame at 12319 (= −1 symbol), back to 0 next frame |

**Verdict (pre-registered prediction B in all four cases):** a kick into the symbol-timing loop, or a shift
of either frame reference, produces bit ERRORS — the demod-input word is not found anywhere in the injective
map — not a DISPLACEMENT onto a rung. The hardware beat (§57, §69, §72) is the opposite: the word is found,
bit-exact, at a rung offset, with the marker cadence intact. The ss kick additionally perturbs the symbol
cadence itself, which the hardware beat never does (0x104 counts 1.0000/frame through bursts, §8).
The August "ss reproduces the burst signature" result (BURST120 §2) was an error-count match only.

Cross-check: first bit-error packet trails the first-displacement frame by a constant +2/+3 packets in every
case (onset and recovery alike) — a fixed decoder pipeline latency between the ddrcap marker and
`packets_out`, reported as observed.

**What this closes / opens [inferred]:** the "timing-loop drift until a slip" family (BURST120 §3 candidates
a/b, forced as ss/ps/ta/slip1) is not the beat mechanism as forced here. The rungs are ~half a frame
(6160 = 12320/2) plus 16…388 symbols in ~64-symbol steps (§64's quantisation), which no single-symbol or
+32 reference slip produces. The search stays at or upstream of symbol sync (§72) but should look for a
mechanism that re-anchors the frame by ~half a frame with the data intact — a buffer/phase structure, not a
loop integrator. Next: sel0/sel2 captures (pre-registered, positive-controlled) to decide whether the
displacement is already present at the RX input.

---
## §77 ANCHOR-FREE TAP SCORER: POSITIVE CONTROL FAILED TWICE — METHOD NOT VALIDATED, NO sel2 VERDICT [SILICON]/[inferred]

Task 3 of the beat-tap-compare campaign (`.superpowers/sdd/2026-09-01-beat-tap-compare/task-3-brief.md`)
built `two_jup/score_tapvs_golden.py`: an anchor-free scorer that circularly cross-correlates each
`P`-record window of a capture against a single fixed reference frame taken from a netlist-generated
golden stream (Task 2, `jupiter_240k5_byte/rtl_sim/golden_taps/sel{0,2,3,5}.bin`), magnitude-only so a
fixed phase rotation/gain is invisible and a tried rail-swap catches I/Q exchange. Exact periods used
(from `golden_taps/GEN.log`, not the brief's approximate values): **P = 49,332** records/frame for
sel0/sel2 (sample domain), **P = 12,333** for sel3/sel5 (symbol domain).

### TDD [inferred]
5 synthetic tests (`two_jup/tests/test_score_tapvs_golden.py`) written first — RED (`ModuleNotFoundError`)
— then the scorer as specified in the brief — GREEN, `5 passed in 2.31s`, unchanged after the revision
below (revision touches only real-marker windowing, never exercised by the synthetic fixtures, which
carry no column-2 markers).

### Positive control (sel3 vs golden sel3) — FAILED TWICE [SILICON]
Attempt 1 (scorer exactly as specified in the brief, blind `n*P` grid from record 0):
`5,440 frames, unmatched 1,774, 75 distinct displaced states each ~84 frames, no rung hit, top state
0:109 (2.0%)`. No resemblance to §72 (`aligned 2,722 / rung 6363×1,232 / rung 6240×220`).

**Revision (the one allowed):** windowed the capture at its own demod markers (`cap[:,2]==0x7FFF`,
chaining to the nearest real marker within a search radius of the expected `+P` position, falling back
to a blind step only where no marker is found nearby) instead of a blind grid from record 0. Motivation:
initial diagnosis suspected accumulated grid drift against golden. Diagnostic probe on the capture's own
markers found this suspicion **wrong** — 1,588 of 1,620 sampled intervals in the raw capture were exactly
12,333, and the constructed marker chain gave 198/199 diffs at exactly 12,333 over the first 200 frames —
the grid was never drifting.

Attempt 2 (marker-anchored windowing): `5,441 frames, unmatched 1,777, 73 distinct states, top state
0:211 (3.9%), 5957:178, 5151:109, ~29 further states at ~83-84 frames each`. Empirically a **no-op**
relative to attempt 1 — same spray, same absence of a §72-shaped verdict. **Second failure. STOP per
the task's §0 ruling: the method is not validated, and no sel2 number may be credited from it.**

### Diagnosed mechanism [inferred] — informative, not a third attempt
- Golden-vs-golden self-correlation (frame 2 vs frames 3/4/10/50/100/150/200) scores 0.9999-1.0 at lag 0
  throughout: the golden stream genuinely repeats one frame's content up to a per-frame complex scalar
  (gain/phase), so the design assumption (period-P content, rotation-invariant score) holds for golden.
- Golden-R vs the sel3 capture is **not uniformly weak**: frames 0-57 score a near-constant 0.4993-0.4996
  (just under `MINSCORE=0.5`, reported unmatched) at every attempted lag, then frame 58 and long
  stretches later (e.g. 496-544 at offset -5987, 546+ at offset 5151, dozens of further ~80-frame runs)
  score 0.9999-1.0. The near-constant 0.4995 floor across many frames is too precise to be i.i.d. noise
  (chance level for length-12,333 QPSK data is ~1/sqrt(N) ~ 0.01); it looks like a deterministic
  component of the frame (marker/preamble/silence) correlating at roughly half strength regardless of
  true alignment, sitting almost exactly on `MINSCORE`. Raising `MINSCORE` does not fix the verdict: even
  restricting to score >= 0.99 (2,407 of 5,441 frames), the surviving frames still partition into ~29
  near-equal-count lag bins (~83-84 each) instead of §72's two rungs plus 0.
- The >=0.9 offsets DO form runs (dwelling ~40-84 frames before stepping to a new value, confirmed by
  inspecting frames 490-700), not a random per-frame scatter — consistent with a slow drift artifact
  that in principle could be chased further, but that is a new hypothesis, not a fix within the one
  allowed revision, so it is reported and not pursued here.

### Negative control (sel5 vs golden sel5, first 1,000 frames) — run for context only [SILICON]
`1,000 frames, unmatched 569 (56.9%), exactly one state: 0:431`. No spurious displaced states at all
(unlike sel3's 73-state spray), which is the qualitative shape a clean stretch should have, but a
positive control that fails cannot be rescued by a negative control that looks clean, and the 56.9%
unmatched fraction shows the same sub-threshold floor issue as sel3. **Not used to validate the
instrument** — recorded only so the next attempt has the number.

### sel2 verdict
**None reported.** The task's §0 ruling is explicit: a derived unit (this scorer) that fails its
positive control twice does not get to produce a number for sel2, however tempting the RRC-output
question is. `sel2.bin` (`two_jup/pair/20260901_161157_sel2b/sel2.bin`) was not scored.

### What this does and does not close
- Does not touch §72-§76: sel3's known displacement (rungs 6363/6240, injective-offset-map method) and
  the §75 sel2 index-dead-ness stand unchanged. This task attempted an independent cross-check via a
  different (correlation-based) instrument and that instrument did not work on this data; §72's original
  result is not called into question.
- Reopens the RRC-output (sel2) localisation question exactly where §75 left it — untested by this
  method, still open to a different instrument (e.g. the injective offset-map approach that worked at
  sel3, adapted to the sample domain, if the offset map can be built for sel2's word width).

Files: `two_jup/score_tapvs_golden.py`, `two_jup/tests/test_score_tapvs_golden.py`,
`two_jup/pair/20260901_155752/sel3_vsgolden.{json,csv}`,
`two_jup/pair/20260901_155752/sel5_vsgolden_first1000.{json,csv}`.

---
## §78 SOURCE HUNT + MARKER-GAP TEST: marker-origin candidate named, its half-frame prediction NOT seen [inferred]/[silicon]
Overnight 2026-09-01, off-rig. Full write-up: `two_jup/OVERNIGHT_20260901.md`, reports
`two_jup/SOURCE_HUNT_20260901.md` and `two_jup/MARKER_GAP_20260901.md`.

Following §76 (timing-loop-drift ruled out), a deep read of the netlist (`s1_rtl_txmark`) nominated the
**`Peak_Search.v:136-148` peak-position latch `timingOffset`** as the top candidate: it feeds ONLY the
demod-marker generator (Timing_Adjust SyncPulse), never the datapath, so if its argmax latches a
secondary correlation peak ~half a frame away the MARKER re-anchors by a rung while DATA stays bit-exact
and cadence stays 1.0000/frame — which would explain the all-taps-transparent §72/§74 picture as a
MARKER-origin (not data-origin) effect. Note: §76's kick forced `timing_Reference` (the search-window
counter), a DIFFERENT register, so §76 did not test this latch. §65's FIFO-pointer jump stays dead
(hard 49332-tap shift register; push-pop witness = 0).

**Pre-registered marker-gap test on the sel3/sel5 captures on disk [silicon, INCONCLUSIVE]:** the
candidate predicts a half-frame jump-then-return in the demod inter-marker gaps. **0 such pairs found**
(105 non-modal gaps sel3, 71 sel5; modal 12,333 at ~98%). Demod anomalies are receiver-side (tx marker
clean at 98%/94% of anomaly rows) but are NOT the rung pattern. So the candidate's specific prediction
is weakened, not confirmed; data-vs-marker stays open.

**Weak legs / next:** the half-frame magnitude + 64-symbol quantisation want the Correlator preamble
autocorrelation (source-hunt candidate #2, FIR coefficients uninspected). The clean data-vs-marker
arbiter — cross-referencing the 105 marker anomalies against §72's per-frame data-displacement — was
NOT run: it needs §72's self-reference scoring reproduced, the §46 phantom-rung / §62 under-determined
trap, deferred to operator direction. Live witness available without a build: `timingOffset` via
PdTelemetry → 0x10C mux, read during a burst.

---
## §79 THE timingOffset LATCH IS NOT READABLE THROUGH THE FLASHED IMAGE — the "free witness" premise is FALSE [proven from netlist + board, 2026-09-02]
Operator directed reading Peak_Search `timingOffset` live via the debug mux ("no build, witness already in
the image"). Verified before assuming, per the standing rule. **It is not there.** No board register was
written — the check is entirely RTL + a read-only iio device enumeration, so the golden arm is untouched.

**Netlist proof.** The complete readable-register set in `TxRxCompo_ip_addr_decoder.v:123-146` is:
ip_timestamp, count_out, packets_out, bit_errors_out, dbg_sentinel, cnt_descr_in, cnt_frame_start,
cnt_vit_reset, cnt_deint_valid, cnt_dec_bits, cnt_bist_start, cap_in, cap_deint, cap_out, cap_cad,
rstcs_count, cfc_est, byte_fifo_ovf, framestat_wordcnt/head_lo/head_hi/stat, beatfix_viol_count/latch.
**None exposes tOff / timingOffset / heldTs / runMax / tRefLong or any Peak_Search timing latch.**

`timingOffset` reaches only the RX debug mux: `QPSK_Rx.v:532-541`, low nibble of `iq_debug_mux` (0x10C)
selects the debug tap; nibble>=4 routes `P1cDtc` = PdTelemetry `telI/telQ`. But PdTelemetry
(`PdTelemetry.v`) packs `tOff & 0x7FF` (11-bit, so a ~6160 rung aliases to tOff mod 2048) into slot-0 word
s0, and the ONLY readback of that debug tap is the 32-symbol SIGN-BIT digest `dcap` (`QPSK_Rx.v:721`,
`{dcap[29:0], Index_Vector[15], Index_Vector[15]}`) landing in the capture reg (0x20C) — sign bits cannot
carry a magnitude like tOff. The full `debugI/debugQ` output (`Receiver.v:44-45`) is not on the DDR-capture
path (that path carries the fixed ddrcap datapath taps agc/rrc/symsync/coarsefreq/carriersync/constpts/
demodbit, not telemetry) and is a no-connect in every sim wrapper.

**Board proof.** 148 exposes only rx/rx2/tx/tx2 adrv9002 DMAs (iio device3-6); ddrcap uses rx2 (device4).
There is no debug/telemetry capture DMA. So `debugI/debugQ` is not capturable on silicon either.

**Verdict:** reading tOff/heldTs live REQUIRES an instrument build to route them to a readable register or
onto a capture DMA. The source-hunt §78 "register read tonight" is retracted (it hedged "verify before
assuming"; verification says no). I did NOT touch 148's debug mux — writing 0x10C during the live golden
arm risks a sentinel false-trigger (the §87e707 wedged-restore class) for a read that cannot yield tOff.

**Frame-identity caveat applies to any future tOff read too:** the ROM plays identical frames with no
per-frame counter, and PdTelemetry further masks tOff mod 2048, so a tOff witness would be known only mod
2048 AND mod the frame — a whole-frame (or 2048-symbol) component is invisible. A build that exposes tOff
should widen the field past 11 bits.

---
## §80 DDRCAP-v2 Tier-1 gate [sim]
Task 4 (`.superpowers/sdd/2026-09-02-ddrcap2-joint-timing-capture/task-4-brief.md`), built and run
against `jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/` (Tasks 1-2). Driver:
`jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp`, built by the amended
`jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh`. Final result (after the 2026-09-02 code-review fix
round below): `DDRCAP2_GATE PASS`, 0 FAIL-verdict rows, 123 check lines + 4 part/overall verdicts
in `beat_runs/ddrcap2_gate.log`.

**Runtime controller ruling (mid-run):** the originally-launched NF=40/all-parts-in-one-binary flat
run measured ~4 kclk/s and would have taken ~8h with an empty (fully-buffered) log. Restructured:
`setvbuf(stdout, IOLBF)` for live progress; a MODE argv (`A|B|C|D|R|all`) so PART A/C run on the
THREADED build (`obj_ddrcap2`) and only PART B on the FLAT build (`obj_ddrcap2_flat`); PART A/C at
NF=20 (warm=20 floor); PART B's force geometry moved from trigger-frame 30/hold 128/readback
30-31 (NF=34) to trigger-frame 10/hold 128/readback 10-11 (NF=8, `warm=6`).

**PASS table (all parts, all channels; updated 2026-09-02 code-review fix round):**

| part | selectors / checks | NF | build | wall time | result |
|---|---|---|---|---|---|
| A (sweep) | sel 0-6,8-11,14 (sel7 skipped, dead; sel9-11 bit-domain run per controller ruling) x 7 generic checks each (records-floor, I/Q nonzero, demod/tx marks ~1/frame, slot cycle 0-3, toff range+steady, tref monotone) | 20 | threaded (`obj_ddrcap2`) | ~91 min (15 selectors x ~6 min) | PASS |
| A (sel12, NF=40 re-verify) | run-structure check (main peak >0.8x + secondary-peak census) — rows sourced from `ddrcap2_sel12_recheck.log`, NOT the NF=20 sweep above; provenance labelled in the log itself | 40 | threaded | ~8 min | PASS |
| A (sel13, re-run) | generic 7 checks + countReg-not-constant + underflow-bit-mean-0.25 | 20 | threaded | ~6 min | PASS |
| A (sel15, re-run) | generic 7 checks + push-counter-advances + RhCtr-cycles-0..3 | 20 | threaded | ~6 min | PASS |
| B (re-run) | 11 rows: 8 forced-register/readback checks (K-consecutive, not "anywhere") + 2 falsifiability negative controls (tref no-force, FIFO push no-force) + the sel15 FIFO-push force | 8 | flat (`obj_ddrcap2_flat`, `--public-flat-rw`) | ~95 min original run + 3 rebuild/re-verify cycles (~35 min each) for the sel15 register hunt + 1 more rebuild/re-run for the K-consecutive rewrite (~50 min) | PASS (11/11) |
| C | sel14 golden-vs-perturbed TX word divergence (`tx_words_golden.hex` / `tx_words_perturbed.hex`, tx_data_source=1) | 20 | threaded (diag build, same source) | ~15 min | PASS (diff=1,181,864/1,331,660 words) |

Records floor for sel9-11 (bit-domain, 16 bits packed per DDR record) lowered from >1000 to >200 per
the controller ruling — still far above noise (observed n well over 1000 in practice at NF=20).

**Rate_Handle occupancy register — three attempts, final: `u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__u_FIFO__DOT__Push_Counter_out1`** (a genuine 5-bit FF, `u_FIFO.Push_Counter_out1`). History:
1. `assign beatobsRhCtr = y;` (Rate_Handle.v:139) — a continuous assign re-driven from submodule
   output `y` every eval; forcing it never sticks. FAIL (check also had a bug: compared the full
   16-bit sel15 I against 0xA500 when I = `{rhctr[7:0], rhpush[4:0], 3'b0}` and rhpush is a live
   5-bit counter — fixed to `(I & 0xFF00) == 0xA500` first, independent of the register question).
2. Retargeted to `u_BfGridPace__DOT__a` (the FF believed to drive `y` via `y_1 = en_1 ? a_temp :
   {6'b0,c}`, `a_temp` derived from `a`). Still FAIL. Root cause (RTL read, `BfGridPace.v` +
   `QPSK_Rx.v`): `en_1` is a registered copy of `en` = Symbol_Synchronizer's `bfGridEn`, which
   traces to `FixCtlDec(.ctl(fixctl))`'s `enGridPace` output — and this driver's `init()` always
   sets `fixctl=0`, so `en_1` is permanently 0 and `y_1` **always** takes the `{6'b0,c}` branch
   (`c` = Rate_Handle's own 2-bit mod-4 `HDL_Counter`). The BfGridPace/`a` "grid pacer" path is
   architecturally unreachable at `fixctl=0`; `beatobsRhCtr` in this test configuration can only
   ever read 0-3.
3. Final: retargeted to the FIFO's own `Push_Counter_out1` (5 bits, genuinely live/forceable,
   unrelated to the fixctl-gated pacer), forced to 0x15, checked as `(I & 0x00F8) == (0x15<<3)`
   (sel15 I[7:3]). PASS: `expect=0xA8 mask=0xF8`.

Spec correction applied (`docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md`
§3/§4): `beatobsRhCtr` is documented as BfGridPace's beat-fix grid pacer (0-3 at fixctl=0, no forced
control in this configuration), not FIFO occupancy; the FIFO occupancy witnesses are
`beatobsPush`/`beatobsPop`, which are what PART B now forces and checks.

**sel12 correlator peak-count rule — rewritten from data, not loosened.** Original rule
(`peaks>half-max in [frames/2, frames*3]`) FAILED: `peaks>half-max=343 frames=26` (~13.2/frame).
Diagnosis (mode D dump, `beat_runs/ddrcap2_sel12_mag.txt`, frames 25-35): exactly 13 contiguous
runs per frame, each run exactly 1 record wide, at the SAME 13 record offsets
(2143,2380,3105,3371,3439,3584,5618,6453,8554,10377,10799,10921,12320 of 12333/frame) in every
dumped frame. RTL: `Correlator.v`'s matched FIR (`Discrete_FIR_Filter`/`Filter.v`, 13 taps,
`coefIn_0..12`) feeds `Magnitude_Squared_and_Moving_Sum.v`'s own 13-tap boxcar
(`Delay_reg[0:12]`). In mode-1 ROM/BIST loopback the same fixed payload repeats every frame, so a
payload sub-sequence that partially matches the 13-tap preamble filter reproduces the SAME
spurious correlation spike at the SAME offset every frame — deterministic data-dependent
sidelobes, not jitter or a broken tap. New rule: PASS iff every analyzed frame has EXACTLY ONE
record above 0.8x that frame's max (the true main peak); records in (0.45x,0.8x] are reported as
a **secondary-peak census** (data, not a gate condition): `secondaries(0.45x-0.8x)/frame mean=16.0
largest_secondary_ratio=0.61 offset_from_main=-1399 records frames_checked=66`. sel12 is counted
LIVE on this structural/liveness check plus PART B's direct forced-register readback of
`Correlator.v Delay2_out1` (sel12 I=0x0123, Q=0x4567, both PASS) — PART B's poke-and-read-back is
sel12's real positive control.

**Files:** `jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp` (new), `jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh`
(amended, final `RHCTR_REG=u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__u_FIFO__DOT__Push_Counter_out1`),
`beat_runs/ddrcap2_gate.log` (final, assembled from A/B/C+R re-verify legs),
`beat_runs/ddrcap2_gate_A.log`, `_B.log`, `_C.log`, `_sel12_recheck.log`, `_rhctr_recheck.log`,
`_rhctr_recheck2.log`, `_sel12_mag.txt` (mode D diagnostic dump),
`docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md` (§3/§4 sel15 correction).
Build blocker cleared: `DDRCAP2_GATE PASS`.

**2026-09-02 code-review fix round — evidence-integrity findings, all fixed and re-verified:**

**Falsifiability (CRITICAL).** The original PART B `check()` asked only "does the expected value
appear ANYWHERE in the readback window/whole run" — a free-running counter satisfies that by pure
chance once per period regardless of any force. Concretely: the tref sidecar is a free-running
mod-12333 counter that passes through `0x1234` once every frame with or without a force; the sel15
FIFO push counter is a free-running mod-32 counter that passes through `0x15` once every 32 pushes
with or without a force. Fixed: `checkK()` now requires the expected value to hold for **K
CONSECUTIVE captured records** inside the exact `[t_force, t_force+128)` hold window — K=8 for
per-beat fields (ch2 tOff, sel12 I/Q, sel13 Q, sel15 I[7:3]), K=3 consecutive slot-k occurrences for
sidecar fields (heldTs/tref/runMax/threshold). A free-running counter cannot sustain K in a row; a
genuinely forced/held register can (observed `maxRun` in the fixed log is 4-65, well above K).

Two negative-control rows were added, run with NO force at all, using the identical K-consecutive
condition (`checkExpectFail()`): the gate treats a correctly-failing check as PASS for that row (the
row demonstrates the check CAN fail, i.e. is falsifiable) and prints `FAIL-AS-EXPECTED` in the
detail text so the committed log shows its own negative result, not a smoothed-over PASS:
```
tref no-force (falsifiability control)          PASS NO FORCE: expect=0x1234 mask=0xFFFF K=3 maxRun=0 (must stay <K) -> FAIL-AS-EXPECTED
FIFO push no-force (falsifiability control)      PASS NO FORCE: expect=0xA8 mask=0xF8 K=8 maxRun=5 (must stay <K) -> FAIL-AS-EXPECTED
```
The FIFO-push margin is explicit: with no force, the free-running counter's maxRun reaches only 5
consecutive matching records (it counts through 0x15 for up to 5 captured beats before advancing,
since sel15 captures faster than the counter increments) — comfortably under K=8, so the check
correctly fails without being a hair-trigger near the threshold.

**sel12 provenance.** The committed `ddrcap2_gate.log`'s PART A section runs at NF=20, but its sel12
rows are pasted from the separate NF=40 re-verify run (`ddrcap2_sel12_recheck.log`, `frames_checked=66`)
that was used to validate the rewritten `peakA()` rule (§ above). This is now labelled explicitly
in-line in the log itself (`# NOTE: sel12 rows below are from the NF=40 re-verify run...`) and in the
PASS table above — no silent splicing.

**4-records/symbol correction (was wrongly assumed 2 samples/symbol).** The review round required
adding per-selector liveness for sel13 (countReg not constant + underflow bit mean) and sel15 (push
counter advances + RhCtr range). The first sel13 re-run FAILED: `underflow mean=0.250` against a
`0.5+/-0.05` target the instructions specified assuming "2 samples/symbol" for the `enb_1_2_0`-valid
taps. Diagnosis: sel15's own push-counter data from the SAME run shows the counter advancing +1
exactly every 4th captured record (`332915/1331659 = 0.250`), matching the sample-domain golden
streams at 49,332 = 4x12,333 records/frame. The `enb_1_2_0`/`enb_1_2_0_gated`-valid taps (sel13/14/15)
capture at **4 records/symbol, not 2** — one underflow pulse per symbol at 4 records/symbol therefore
correctly averages 0.25, not 0.5. Fixed the check target to `0.25+/-0.03` (not loosened blindly — the
0.250 result is clean/reproducible/internally-consistent with sel15's own data, not a marginal or
noisy number) and corrected `docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md`
§3 (the "at 2 samples/symbol" line, which was wrong for this domain — it correctly describes sel2's
separate tap, but the enb_1_2_0 domain shared by sel13/14/15 is 4 records/symbol).

**Per-selector liveness rows added (were previously only the 7 generic ch2/ch3 checks for every
selector, missing the spec's sel13/sel15-specific rows):**
```
sel13 countReg not constant                        PASS distinct=272
sel13 underflow bit mean ~0.25 (4 records/symbol)   PASS underflow mean=0.250 (want 0.25+/-0.03)
sel15 push counter advances (not constant)          PASS distinct=32 (+1 mod32 beat-to-beat=332915/1331659, context only)
sel15 RhCtr cycles within 0..3                      PASS distinct=4 maxval=3
```

**Minor fixes:** every `records>N` check now prints the observed count (`n=1331660`); the dead
`sel==7 ? true :` branch in the I/Q-nonzero check was removed (sel7 is always skipped by the caller's
loop, so that branch could never execute).

**Files (fix round):** `jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp` (`checkK`/`checkExpectFail`/
`maxConsecMatch` replace the old `check()`; `sel13A()`/`sel15A()` added; `Rec` gained a `clk` field;
`runPartA()`'s selector filter is now a list, not a single int; `runPartR` mode removed, superseded by
re-running full mode B), `beat_runs/ddrcap2_gate.log` (re-consolidated: A sweep + sel12 NF=40 rows
(labelled) + sel13/sel15 re-run rows + B2 (11 rows incl. 2 negative controls) + C + 4 verdicts),
`beat_runs/ddrcap2_gate_A.log` (re-spliced), `_B.log` (replaced with `_B2.log`'s content),
`_gate_A_sel13.log`, `_gate_A_1315.log`, `_gate_B2.log` (new evidence files),
`docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md` (4-records/symbol
correction). Build blocker cleared: `DDRCAP2_GATE PASS`.

---
## §81 DDRCAP-v2 FLASHED ON 148 AND VERIFIED IN PLACE — record format live on silicon [proven on silicon, 2026-09-02]
Image `BOOT.BIN.148.ddrcap2.638b36de3493` (Vivado 15:19–16:04 on hdl-dev-2, WNS +0.105, Tier-1 gate §80 PASS).
Operator go 17:27 after a baseline arm on the old image (ARM_OK fps=1247 capTAP golden, 16:54).

**Flash chain run (`skidfix/ddrcap2_flash_20260902_172735.log`):** [1/5] preconditions PASS (current 1cd0cd752aa6,
on-board rollback copy created + md5-verified), [2/5] staged + FLASHED 638b36de3493 at 17:27:40, reboot. [3/5]
readback returned EMPTY at 17:28:47 — the board answered ping before sshd was up — chain went to rollback, whose
restore-copy ssh also returned empty, and it exited FATAL "PHYSICAL ATTENTION before reboot" WITHOUT rebooting or
restoring (guard correct; waiter wrong). ssh returned at 17:29:51: booted image = 638b36de3493 (readback MATCH),
rollback copy intact. No retry. Chain defects fixed and reviewed afterwards (fdf17bb: ssh-readiness wait, empty md5
= not-ready; 3e80318: never remove a SENTINEL_STOP the chain did not create — the old trap deleted the controller's
manual hold three times during dry runs; sentinel + keeper units stopped for the campaign).

**Verify-in-place (operator option 1, `skidfix/ddrcap2_verify_20260902_173923.log`):**
| step | result |
|---|---|
| gate pass 1 (arm148_mode1) | ARM_OK fps=1247 errps=55 capTAP=0xBCF94856 |
| gate pass 2 | ARM_OK fps=1247 errps=55 capTAP=0xBCF94856 |
| witness sel6, 4 MB | 524,288 records; demod marks 43, tx marks 43 (1/frame over ~42.5 frames); **toff = 26 in every record** (min=max=mode, distinct 1); slot histogram [131072,131072,131072,131072] |
| verdict | `VERIFY_IN_PLACE_OK 638b36de3493` at 17:42:26 |

So on silicon: ch2 carries both marker bits (1/frame each) and a steady 14-bit timingOffset; ch3's slot counter
cycles 0..3 exactly (perfectly uniform quarter split). **tOff silicon non-null already satisfied:** d0 = 26 on this
arm vs 12,323 in the clean sim (§80) — the field is not stuck at a constant of the instrument. Legacy DBGCAP path
unaffected (capTAP golden at low nibble 3). 146 untouched throughout (uptime 1 d; the "146 re-armed" reading at
17:38 was a mis-timestamped log read, corrected at 17:45).

### §81 addendum: Tier-2 silicon positive controls, five selectors, one arm [proven on silicon, 2026-09-02]
TDD: `two_jup/tests/test_ddrcap2_pc.py` (3 cases, verbatim from the plan) — RED (`ModuleNotFoundError: ddrcap2_pc`)
before `two_jup/ddrcap2_pc.py` existed, GREEN (`3 passed`) after. The scorer's boolean fields are cast to native
Python `bool()` before the test's `is True`/`is False` identity checks are applied — numpy 1.26 `np.bool_` fails
those checks by identity even when truthy-equal; this is an implementation fix, the test file itself is verbatim
and untouched.

Five 512 MB captures (sel6, sel12, sel13, sel14, sel15) run sequentially under one `launch_rig_unit.sh` unit on
the arm already in place from §81's gate pass 2 (no re-arm). `ddrcap2_capture.sh` confirmed capTAP `0xBCF94856`
golden immediately before and immediately after every one of the five captures (host-side `stat`-before-delete
guard never triggered a short-read branch). `d0` (toff mode) = 26 in all five captures, matching §81's witness
exactly.

| sel | rule | result |
|---|---|---|
| 6  | not_constant_IQ, not_ramp_IQ, demod_marks_periodic, slots_cycle, toff_range_steady, tref_monotone | all PASS |
| 6  | **TIER2** | **PASS** |
| 12 | common rules | all PASS |
| 12 | peaks_per_frame_ok (0.5–3 samples/frame above half-max) | FAIL — 8.49 samples/frame (46,171/5,439), confirmed not a run-counting artifact: a contiguous-run count over the same threshold gives the identical 46,171 (i.e. no clustering — genuinely isolated above-half-max samples, not one wide correlator peak per frame) |
| 12 | **TIER2** | **FAIL** — channel DEAD for the campaign. Note for the plan owner: the brief's prose rule (line 9) states only a lower bound ("≥ 0.5 peaks/frame above half-max"); the verbatim scorer code adds an upper bound of 3. Under the prose-only rule sel12 would PASS. Reported as coded (FAIL), not silently reinterpreted. |
| 13 | not_constant_IQ, not_ramp_IQ, slots_cycle, toff_range_steady, tref_monotone, countreg_not_constant, underflow_per_symbol (0.25±0.03, 4 records/symbol) | all PASS |
| 13 | demod_marks_periodic | FAIL — 1,343/67,108,864 marks (vs 5,451 on sel6 over the same record count), uniformly sparse across all ten deciles (no mid-file transition), marks still land on the true 12,333-record grid (residual spread matches sel6/sel12) with dominant gaps at 3×P and 6×P — i.e. real intermittent mark-detection dropout, not a wrong-grid or decode bug. Investigated before verdict: initially suspected a transient link condition coincident with the sel12→sel13 capture boundary (18:08:12→18:08:30); the one permitted re-capture (`sel13b`, independent capture at 18:16, same arm, capTAP golden pre/post) reproduced the identical sparse signature (1,364 marks, same decile profile) seven minutes later — ruling out a transient blip and confirming a reproducible property of this tap. |
| 13 | **TIER2** | **FAIL (reproduced on one re-capture)** — channel DEAD for the campaign |
| 14 | not_constant_IQ, not_ramp_IQ, slots_cycle, toff_range_steady, tref_monotone, not_constant, not_ramp | all PASS |
| 14 | demod_marks_periodic | FAIL — same signature as sel13 (1,349 marks, uniform-sparse deciles, dominant 3×P/6×P gaps); not independently re-captured (one re-capture already spent confirming sel13's identical signature is reproducible, not transient) |
| 14 | **TIER2** | **FAIL** — channel DEAD for the campaign |
| 15 | not_constant_IQ, not_ramp_IQ, slots_cycle, toff_range_steady, tref_monotone, rhctr_bounded_nonzero, push_pop_advance | all PASS |
| 15 | demod_marks_periodic | FAIL — same signature as sel13/14 (1,333 marks, uniform-sparse deciles, dominant 3×P/6×P gaps) |
| 15 | **TIER2** | **FAIL** — channel DEAD for the campaign |

**Verdict: 1 of 5 (sel6) PASSES Tier-2 in full.** sel12 fails on its selector-specific peak-shape rule (real signal
character at that tap, not framing). sel13/14/15 all fail on the shared `demod_marks_periodic` common-rule — the
same reproducible signature across three independent selectors and, for sel13, across two independent captures
seven minutes apart — pointing at something upstream of the SEL mux (a marker-generation condition shared by
these three tap positions) rather than three unrelated per-channel defects. Not fixed or re-armed on the rig, per
the campaign's DEAD-channel discipline. Raw `.bin` captures are not committed (§brief); `pc.log` and `meta.txt`
under `two_jup/ddrcap2_pc/20260902_180725/` are.

### §81 addendum, fix round 1: record index is not a time base on the enb-domain taps; sel12's gate was stale [proven on silicon, 2026-09-02]
Re-scored the same five existing captures (no re-capture, no board contact). Two defects in the Tier-2 scorer
itself, found by reading the .bin files with numpy after the first pass called four of five selectors DEAD:

**sel12 — the rule was stale.** `peaks_per_frame_ok` (0.5-3 samples/frame above half-max) was a leftover from
before the §80 sim census; the real per-frame magnitude shape at this tap is one dominant record above 0.8x
the frame max plus a cluster of secondaries in (0.45, 0.8]x — confirmed on this capture: mean 16.22 secondaries
per frame in that band, largest secondary ratio 0.799 (i.e. right under the 0.8 cut, never crossing it). Replaced
the rule with `peak_one_per_frame`: PASS iff every scored frame has exactly one record > 0.8x that frame's own
max. On this capture: **5,428 of 5,438 scored frames (99.82%) have exactly one** — the strict "every frame"
form of the rule as specified therefore reads **FAIL by 10 frames**, not the LIVE verdict expected going in.
Traced all 10: they are 5 matched pairs, each one 12,333-record frame with primary_count 12-13 (fmax suppressed
to ~35-40M vs the typical ~67-68M) immediately followed by one 24,666-record frame with primary_count 2 (i.e. two
real frames merged into one measured segment because a demod-mark was missed between them, with the pre-merge
frame's local peak amplitude also suppressed). This is the same missed-marker mechanism documented below for
sel13/14/15, just ~50x rarer on this symbol-rate tap (0.18% of frames vs the enb-domain taps' burst losses).
**Verdict: sel12 TIER2 FAIL under the rule as specified (99.82% clean); flagged for the plan owner** — whether
a >=99% (or similar) tolerance belongs in the rule, matching every other Tier-2 rule's tolerance-band design, is
a policy call this report does not make unilaterally.

**sel13/14/15 — the check, not the tap, was wrong.** `demod_marks_periodic` indexes by raw record position,
which assumes one record of latency per frame. On these three selectors the rx2 DMA is at the full enb_1_2_0
rate (~61M records/s vs ~15M records/s on sel6/sel12) and drops records in bursts, so record index is not a
valid time base here — the marker-cadence rule was measuring DMA loss, not tap health. [inferred] Every surviving
record still carries its own frame position in-band (tref/tOff/markers), so these taps are usable when indexed
by the sidecar tref (slot-1) symbol counter instead of by record index. Replaced `demod_marks_periodic` with
`tref_cadence` for these three selectors only (sel6/sel12 keep `demod_marks_periodic`, which passes cleanly on
both): unwrap tref deltas mod 12,333, PASS iff >=95% equal the modal delta. Measured on the existing captures,
all three selectors [silicon]:

| sel | modal tref delta | frac at modal | frac drop (>2x modal) | drop median (symbols) | drops / 1e6 records | ~frac records lost in bursts [inferred] |
|---|---|---|---|---|---|---|
| 6  | 4 | 0.99967 | 0.00033 | 17.0  | 82.8  | ~0.5% |
| 12 | 4 | 0.99999 | 0.00001 | 1110.0 | 1.5  | ~0.3% |
| 13 | 1 | 0.99805 | 0.00195 | 156.0 | 488.2 | ~38.3% |
| 14 | 1 | 0.99805 | 0.00195 | 163.0 | 488.2 | ~39.5% |
| 15 | 1 | 0.99805 | 0.00195 | 157.0 | 488.2 | ~38.3% |

The "records lost" column is [inferred], not [silicon]: it's excess tref-units beyond the modal delta per burst,
converted to records via the structural invariant that exactly 4 records separate consecutive slot-1 samples
when nothing drops (so records-per-tref-unit = 4/modal), and it assumes drops fall on all four slot phases
evenly. sel6/sel12 have modal=4 so 1 tref-unit = 1 record; sel13/14/15 have modal=1 so 1 tref-unit = 4 records
— the same excess-unit count is four times more expensive there, and each burst is itself ~150x longer, so
roughly a third of all records are lost in bursts on the full enb-rate taps at this arm, not the ~20% guessed
going in. sel13/14/15's burst-drop signature (median ~156-163 symbols per burst, ~0.2% of symbol boundaries
affected, ~38-40% of total records lost) is essentially identical across all three selectors [silicon] — consistent
with one shared instrument limit (DMA/S2MM-boundary loss at the full enb rate) rather than three independent
tap defects [inferred], matching the pattern already on record for sel1 (§72) and sel2 (§75). All three now
PASS `tref_cadence` (>=99.8% of deltas at the modal value, well above the 95% bar).

**Revised verdict, five selectors, fix round 1:**

| sel | TIER2 (fix round 1) | change from first pass |
|---|---|---|
| 6  | PASS | unchanged |
| 12 | FAIL (99.82% of frames clean; strict rule) | rule replaced, still FAIL — now failing narrowly and for a diagnosed, shared-mechanism reason, not a wrong rule |
| 13 | PASS | rule replaced; the sel13 first-pass FAIL (and the sel13b re-capture reproducing it) was demod_marks_periodic measuring DMA record loss, not a dead tap |
| 14 | PASS | same correction as sel13 |
| 15 | PASS | same correction as sel13 |

Three of five selectors move from DEAD to LIVE once indexed correctly. sel12 remains FAIL, now on a narrow
(99.82%), diagnosed, and reported basis rather than a stale threshold. Not fixed or re-armed on the rig; no
board contact this round. `pc.log` under `two_jup/ddrcap2_pc/20260902_180725/` carries the full fix-round-1
scorer output and the sel12 outlier-frame diagnostic.

### §81 addendum, fix round 2: sel12 given the same tolerance-band design as every other Tier-2 rule [proven on silicon, 2026-09-02]
Plan-owner ruling: `peak_one_per_frame` should carry the same tolerance-band design as the rest of the Tier-2
scorer (`toff_range_steady`, `slots_cycle`, `tref_cadence`, etc. all use a >=95-99% band, not a literal zero-
tolerance "every") rather than the strict form fix round 1 reported. Changed the rule (one line) to: PASS iff
>=99.5% of marker-segmented frames have exactly one record > 0.8x that frame's own max, and made the scorer
itself — not a separate ad hoc script — enumerate every exception frame with its anomaly, so a genuine
multi-peak frame could never hide behind the band.

Re-scored the same existing sel12 capture, no re-capture, no board contact:

```
peak_one_per_frame  PASS  (99.82% clean, >= 99.5% band)
sel12_exceptions = 10 exception frame(s) of 5438 scored (0.9982 clean):
  frame504(len=12333,primary_count=12); frame505(len=24666,primary_count=2);
  frame1979(len=12333,primary_count=13); frame1980(len=24666,primary_count=2);
  frame2773(len=12333,primary_count=13); frame2774(len=24666,primary_count=2);
  frame4231(len=12333,primary_count=13); frame4232(len=24666,primary_count=2);
  frame5040(len=12333,primary_count=13); frame5041(len=24666,primary_count=2)
  -- all at missed-demod-mark events (short-frame/merged-frame pairs)
TIER2 sel12 PASS
```

All 10 exception frames are the same 5 short/merged pairs traced in fix round 1 — every one a missed-demod-mark
event, none a genuine independent multi-peak frame. **sel12: TIER2 PASS (99.82% clean, 10 exception frames, all
at missed-demod-mark events).** Added 2 tests exercising the band directly (2/499 bad frames = 99.60% clean ->
PASS; 5/499 bad frames = 98.99% clean -> FAIL), on top of the existing pass/fail cases from fix round 1;
`pytest tests/test_ddrcap2_pc.py -q` -> **10 passed**.

**Loss-fraction estimate, restated as a range:** the fix-round-1 table above reported a single structural
estimate (~38.3-39.5%, records-per-tref-unit = 4/modal). Restating as a range per the plan owner: **~20% (sum
of burst sizes) to ~38-40% (structural estimate), both [inferred]; the direct [silicon] measurement is the
tref-delta burst statistics table above** (modal delta, frac-at-modal, drop median, drops/1e6 records — all
[silicon]). Note on provenance: the ~38-40% structural bound is independently reproducible from that table
(records-per-tref-unit = 4/modal_delta, applied to the excess above modal per burst); the ~20% "sum of burst
sizes" bound is the plan owner's own earlier order-of-magnitude estimate, and this report was not able to
independently re-derive a value near 20% from the tref-delta data by a method it can fully justify (a few
plausible readings of "sum of burst sizes" landed at ~9.6% or ~28-38% instead) — included at the plan owner's
direction for the range, not independently verified here.

**Revised verdict, five selectors, fix round 2:**

| sel | TIER2 (fix round 2) |
|---|---|
| 6  | PASS |
| 12 | **PASS** (99.82% clean, 10 exception frames, all at missed-demod-mark events) |
| 13 | PASS |
| 14 | PASS |
| 15 | PASS |

**All five selectors now PASS Tier-2.** Not fixed or re-armed on the rig; no board contact this round. `pc.log`
under `two_jup/ddrcap2_pc/20260902_180725/` carries the fix-round-2 scorer output.


## §82 DDRCAP-v2 burst capture: P2 [silicon]

Task 8 (pre-registered spec §6 verdict), sel6, board 148 only, image 638b36de3493 (flashed and
Tier-2-verified per §81). Capture dir `two_jup/beatcap/20260902_185552_sel6/`.

**Two arms this task, one script defect between them.** Arm 1 (`beatcap2-sel6-184821`, 18:48:21-18:51:10):
`ARM_OK profile=lvds_61p44_fdd_jupiter fps=1247 capTAP=0xBCF94856`; `TRIGGER errps=63600 at +40s`
(18:51:09); then `ABORT mid: capTAP 0xD71F70D3 != golden` — the verbatim beat-plan capture-credit
check treated a genuine mid-burst capTAP value as a failure and aborted with no capture taken. `0xD71F70D3`
is a documented tap-3 burst word (rung 6299, SESSION_20260830_AUTONOMOUS.md §31/§38/§26: capTAP legitimately
takes one of eight known non-golden values *during* a beat burst, by design). This was a script defect, not
a rig fault; 148 remained golden and armed afterward (capTAP 0xBCF94856, errps ~102 confirmed independently
at 18:52). Fixed in `two_jup/beat_tap_capture.sh`'s `capture()` function only (arm-time golden check at the
original line ~32 unchanged): pre/post capTAP is now credited if golden OR one of the eight known burst
words (`0AA4D2D3 D8A04817 D71F70D3 6B47D467 93E1A9FA BFED37AC D748FC96 41800000`), with a `credit=yes|no`
field written to `meta.txt`. Proven with a new fake (`tests/fake_anyssh_rung.sh`) that returns a rung word
on mid's pre-read and golden on the post-read; dry run produced `mid: ... pre=0xD71F70D3 post=0xBCF94856`
with `credit=yes`, alongside the three original beat-plan dry-run cases (TRIGGER, both `.bin` produced,
REFUSE on re-run into the same OUT), all still passing.

Arm 2 (`beatcap2-sel6-185552`, 18:55:52-19:01:09, one attended arm, no retry beyond this one): `ARM_OK
profile=lvds_61p44_fdd_jupiter fps=1247 capTAP=0xBCF94856`; `TRIGGER errps=63602 at +40s` (18:58:40) — both
arms triggered at +40 s of the 300 s watch window with near-identical errps (63600 / 63602); recorded as
an observation [silicon], not interpreted further. `mid.bin`: 536,870,912 bytes, `pre=0xD71F70D3
post=0xBCF94856 credit=yes`. `onset.bin`: 536,870,912 bytes, `pre=0xBCF94856 post=0xBCF94856 credit=yes`.
Both full-size (no SHORT), both credited, run exited `=== done`, rc=0. No retry was needed or taken.

**Tier-2 (spec §4), THIS capture:** `ddrcap2_pc.py --sel 6` → **PASS** on `onset.bin` (all seven checks:
not_constant_IQ, not_ramp_IQ, demod_marks_periodic, slots_cycle, `d0=12314`, toff_range_steady,
tref_monotone) and **PASS** on `mid.bin` (same seven checks, same `d0=12314`).

**Analysis defect fixed (minimal, tests kept verbatim).** The brief's `ddrcap2_beat_analysis.py` computed
`delta = (after-d0) % 12320` then folded it with `min(delta, 12320-delta)`. 12320 is correct — it is the
ROM's declared symbol-frame length (`offsetmap/tap3_word_to_offset.tsv` header: "frame=12320 symbols"; the
`P=12333` elsewhere in this file, and in `ddrcap2_pc.py`, is the distinct DDR *record*-frame length used for
record indexing). The bug was the fold: every `RUNGS` value (6176..6548) exceeds 12320/2=6160, so
`min(delta, 12320-delta)` always maps a true rung step into its complement (5772..6157), which then matches
no `RUNGS` entry — `test_P1_when_toff_moves_with_data` was RED against the brief's verbatim analysis code
(delta=6363 folds to 5957, no rung within ±4). Fixed by checking the raw circular delta **and** its
complement against `RUNGS` directly, instead of collapsing to one minimized magnitude that discards which
rung/sign it was closest to — more faithful to the pre-registered P1 text ("tOff steps to d0 +/- rung"),
not a widening of it. `pytest tests/test_ddrcap2_beat_analysis.py` → **4 passed** (RED-then-GREEN: ImportError
before `ddrcap2_beat_analysis.py` existed, 4/4 after).

**Verdict: P2, both captures agree.**

| capture | frames_by_marker | frames_by_index | frames_by_tref | onset_beat_data | d0 | onset_beat_toff | toff_after | verdict |
|---|---|---|---|---|---|---|---|---|
| onset.bin | 5445 | 5441 | 5445 | 23432846 (frame ≈1900/5441) | 12314 | null | 12314 | P2 |
| mid.bin   | 5446 | 5441 | 5447 | 12481194 (frame ≈1012/5441) | 12314 | null | 12314 | P2 |

**Three-way frame count, with the arithmetic [inferred].** `frames_by_marker` and `frames_by_tref`
agree (onset.bin 5445/5445; mid.bin 5446/5447, within 1) and are treated as the frame ordinality for this
section; `frames_by_index` (records/P, P=12333) is the one that undercounts, because the stored record
count already reflects any DMA drops while marker/tref count actual frame-boundary events. Arithmetic
(records_total=67,108,864 for both captures, P=12333):

| capture | fr (marker) | expected records = fr·P | actual records | missing | observed drop % | vs stated 0.00-0.03% |
|---|---|---|---|---|---|---|
| onset.bin | 5445 | 67,153,185 | 67,108,864 | 44,321 | 0.0660% | **2.2x** the upper bound |
| mid.bin   | 5446 | 67,165,518 | 67,108,864 | 56,654 | 0.0843% | **2.8x** the upper bound |

Both captures land at 2-4x the naive upper-bound drop-rate estimate from `ddrcap-fullrate-dma-drops.md`
(0.00-0.03%), not within it. Recorded as-is, [inferred] (derived from the count arithmetic, not a direct
register read): the per-record drop characterization from that memory entry may not transfer unchanged to
a burst window (a beat burst is exactly the kind of high-activity interval that could plausibly carry a
higher instantaneous drop rate than the steady-state sampling `ddrcap-fullrate-dma-drops.md` was built
from), or the 0.00-0.03% figure itself may be a lower bound rather than a ceiling. This section does not
resolve which; it states the gap plainly rather than asserting "consistent with" a range the arithmetic
does not support.

`onset_beat_toff` is `null` and `toff_after == d0` on both captures: per the brief's read-out rules this is
the P2 branch (`toff` holds at `d0` on every beat while `d_data` sits on a rung for ≥3 frames), not
UNINFORMATIVE — `onset.bin` did NOT miss the onset (`d_data` transitions to a rung and holds), it is `toff`
that never moves.

**Sidecar readings around `onset_beat_data`, onset.bin (records 23432842-23432849, toff column all 12314,
constant through the window):**

```
idx        I      Q     mark_demod mark_fec slot side   heldts  tref  runmax corrthr
23432842 -11598 -11503  False      False    2    0        -1     -1     0      -1
23432843 -11562 -11540  False      False    3    713       -1     -1    -1     713
23432844 -11601 -11507  False      False    0    5802     5802    -1    -1     -1
23432845 -11702 -11633  False      True     1    12325     -1    12325  -1     -1
23432846  11403 -11590  True       False    2    257       -1     -1    257    -1   <- onset_beat_data
23432847  11778 -11729  False      False    3    712       -1     -1    -1     712
23432848 -11434  11362  False      False    0    10033    10033   -1    -1     -1
23432849 -11627  11819  False      False    1    12329     -1    12329  -1     -1
```
(mid.bin's window around its own `onset_beat_data`=12481194 is the same shape: toff constant at 12314
throughout, `mark_demod` set at the onset record, slot-2 `runmax_hi`≈257-259, slot-1 `tref`≈12325-12329.)
`runMax`/`threshold` sidecars show no anomaly at the transition; only the data-domain hard-decision word
changes, consistent with a marker/correlator-side displacement rather than a `timingOffset`-register event.

**Cross-arm and cross-domain `d0` — the campaign's primary non-null criterion.** Per `task-7-brief.md`
(~line 120): the tOff non-null criterion is satisfied when this arm's `d0` differs from the sim gate's
tOff mode (§80/§81, Tier-1) **OR** from the next arm's `d0`. Three values, not two:

| source | d0 (raw) | provenance |
|---|---|---|
| Task 7 arm (5 sel6 positive-control captures, steady state) | 26 | [silicon] |
| Task 8 arm 2 (this capture, both onset.bin and mid.bin) | 12314 | [silicon] |
| Tier-1 sim gate (`jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log`, sel6 line: `toff in range and steady PASS mode=12323 frac=1.000`) | 12323 | [sim] |

Read circularly mod 12320 (the ROM's declared symbol-frame length, `offsetmap/tap3_word_to_offset.tsv`),
folded to the signed residual nearest zero: `26 -> +26`, `12314 -> 12314-12320 = -6`, `12323 -> 12323-12320
= +3`. All three are small fine-timing residuals near zero, and all three are pairwise different (+26,
-6, +3). Controller ruling: this satisfies the OR — this arm's `d0` (12314, residual -6) differs from
both the sim gate's `d0` (12323, residual +3) and Task 7's `d0` (26, residual +26) — so the tOff non-null
criterion is met independent of which pairing is used, and it is recorded as [silicon] for the two arms'
values and [sim] for the 12323 sim-gate value (cited from Task 5's gate log, not re-derived here). This is
exactly the signature a locked fine-timing latch should show: small, non-repeating residuals near zero
across independent runs, not three copies of one stuck default (e.g. all three landing on the same value,
or all three at a boundary like 0 or the register's max). **P2 stands as reported above; this criterion is
evidence the tOff field is live, not a reason to upgrade or soften the P2 verdict.**

**Frame-identity limit [applies to this section]:** the ROM plays identical frames, so `onset_beat_data`'s
position (frame ≈1900 or ≈1012 of ≈5441) and every `d_data`/`toff` value in this section are known only
modulo the frame length — this section does not and cannot claim an absolute epoch, only the presence and
character of the 0→rung transition and the concurrent `toff` behavior within each 512 MB window.

**Provenance:** all capTAP, `errps`, TIER2, and analysis-derived numbers in this section are [silicon]
(directly measured DDR-v2 records or 0x108/0x20C register reads on board 148); the RUNGS/burst-word
identities and the frame=12320-symbols fact are [sim, positive-controlled] per §31, cited here not
re-derived; the sim gate's `d0=12323` is [sim] per Task 5's Tier-1 gate log (§80/§81), also cited not
re-derived; the drop-rate arithmetic (three-way frame count vs `ddrcap-fullrate-dma-drops.md`) is
[inferred] as stated there. No 0x108 bit-error number is quoted as a frame error rate (§78/bist-120bit-
window.md caveat honored — this section only uses 0x108 deltas as a burst trigger, not as an error-rate
figure).

## §83 Task 9, sel13 arm: interpolator phase accumulator, window-qualified verdict [silicon]

Task 9 (P2 branch, per `task-9-brief.md`), sel13, board 148 only, image 638b36de3493. Pre-registered
in `two_jup/TASK9_PREREG.md` before arming. Arm `beatcap2-sel13-192051` (19:20:51-19:25:55):
`ARM_OK profile=lvds_61p44_fdd_jupiter fps=1247 capTAP=0xBCF94856`; `TRIGGER errps=63602 at +40s`
(19:23:40). `mid.bin`: 536,870,912 bytes, `pre=0xD71F70D3 post=0xBCF94856 credit=yes`. `onset.bin`:
536,870,912 bytes, `pre=0xD8A04817 post=0xBCF94856 credit=yes`. Both full-size, both credited, run
exited `=== done`, rc=0.

**Tier-2:** `ddrcap2_pc.py --sel 13` PASS on both captures (`d0=12314`, matching the §82 sel6 arm's
`d0` on the same image; `tref_cadence` PASS, `countreg_not_constant` PASS, `underflow_per_symbol`
PASS `~0.25`, matching the 4-records/symbol design correction).

**Detector, revised after its own positive control failed (documented in full in
`TASK9_PREREG.md` Addendum 1, same discipline as §82's delta-fold fix):** the originally
pre-registered per-pair magnitude-threshold detector on the 11-bit `countReg` phase accumulator
could not distinguish an injected synthetic step from real silicon's background timing-loop jitter
(~6% of symbols show a >64-count single-step jump everywhere in the file, not onset-related).
Revised to a windowed-mean-shift statistic (`w=1000` tref-indexed clean symbol pairs, DMA-drop-
coincident pairs excluded by construction), validated by positive control (an injected sustained
step is found at the injection point with zero false positives on an unmodified control stretch of
the same real capture) before scoring the real data.

**Window-timeline reconstruction (`TASK9_PREREG.md` Addendum 2, per controller ruling: a sel13/14/15
record carries no data word, so a re-anchor event's presence inside a window must be established
from external timing/register evidence, not assumed).** From `errps.csv`, `journalctl -o
short-precise` `BOARD`-line timestamps, and `meta.txt`:
- `mid.bin` window `~= T_trigger+[2.15s, 3.25s]` [inferred, +/-0.2-0.3s] -- inside the same burst
  that crossed the errps threshold.
- `onset.bin` window `~= T_trigger+[122.80s, 123.90s]` [inferred] -- ~2.6-3.7s AFTER the ~120.22s
  periodic onset anchor (from the §82 sel6 arm, a different arm; the controller noted >=0.5s
  arm-to-arm burst-phase jitter, so this anchor is approximate).

capTAP pre/post reads bracket each window directly: `mid.bin` pre=`0xD71F70D3` (rung) ->
post=`0xBCF94856` (gold); `onset.bin` pre=`0xD8A04817` (rung) -> post=`0xBCF94856` (gold). Both
brackets show rung->golden: **a return-to-quiet re-anchor event is evidenced inside BOTH windows**
(exact record unknown -- sel13 carries no data word to locate it), independent of the timeline
estimate.

**Verdict (window-qualified, corrects commit `34d22e6`'s unqualified "FALSIFIES"):**
- **FALSIFIED for the return-to-quiet re-anchor event**, evidenced inside both windows via the
  capTAP bracket: the full-file windowed-mean-shift scan (not just a locus window, since the
  event's exact position is unknown) found **zero events** across 16,744,451 clean symbol pairs in
  each of `mid.bin` and `onset.bin`. The interpolator phase accumulator shows no discontinuity
  anywhere in either window while a real re-anchor event is known (from the capTAP bracket) to have
  occurred inside it.
- **UNINFORMATIVE for the quiet->rung onset transition specifically**: neither window's timeline
  places it convincingly at/before the ~120.22s anchor (`onset.bin` opens ~2.6-3.7s after it), and
  there is no capTAP-bracket evidence (both windows open already in the rung/displaced state) that
  the onset instant itself, as opposed to its later return, is inside either window.

**Provenance:** capTAP, errps, Tier-2, and windowed-mean-shift results are [silicon] (measured on
board 148); the ~120.22s cross-arm onset anchor is [silicon, different arm, §82]; the ~1.1s
acquisition-duration figure used for window-start inference is [inferred] from the controller's
prior ruling, cited not re-derived; the window bounds themselves carry a stated +/-0.2-0.3s
uncertainty.

## §84 Task 9, sel14 arm: interpolator buffer, detector inadequate, UNINFORMATIVE [silicon]

Per the P2 stop rule (sel13 falsifier earned for the return-event window, per §83), one arm at
sel14 (`Symbol_Synchronizer.Delay8_out1_re/im`), pre-registered in `TASK9_PREREG.md` before arming
(absolute script path used this time -- a relative path under `systemd-run` fails 127 before ARM
runs, since the unit's cwd is not `two_jup`; that failure touched no board state and was not a
"retry"). Arm `beatcap2-sel14-193632` (19:36:32-19:41:36): `ARM_OK ... capTAP=0xBCF94856`;
`TRIGGER errps=63600 at +40s` (19:39:20, the fourth consecutive `+40s` trigger across these arms).
`mid.bin`: 536,870,912 bytes, `pre=0xD71F70D3 post=0xBCF94856 credit=yes`. `onset.bin`:
536,870,912 bytes, `pre=0xBCF94856 post=0xBCF94856 credit=yes`. Both credited, rc=0.

**Tier-2:** `ddrcap2_pc.py --sel 14` PASS on both (`d0=2` -- a different value than the sel13 arm's
`12314`, consistent with the established cross-arm `d0` drift already treated as evidence tOff is
live, §82).

**Window timeline (same method as §83):** `mid.bin` `~= T_trigger+[2.18s, 3.28s]` -- inside the
burst. `onset.bin` `~= T_trigger+[122.92s, 124.02s]` -- essentially the same offset from the
~120.22s anchor as the sel13 arm's `onset.bin` (consistent with a repeatable ~3.1s SSH-dispatch
overhead between loop-release and acquisition start, not itself burst-phase evidence).

**capTAP brackets:** `mid.bin` pre=`0xD71F70D3` (rung) -> post=`0xBCF94856` (gold): a return event is
evidenced inside this window, as in the sel13 arm. `onset.bin` pre=`0xBCF94856` (gold) ->
post=`0xBCF94856` (gold): **no re-anchor event is evidenced inside this window.** A brief rung
episode fully bracketed within the ~1.1s window (both endpoints outside it) is not ruled out, but is
not the parsimonious reading given the sel13 arm's `onset.bin` (opened rung, closed gold) at nearly
the same offset from trigger; more likely this burst's return completed slightly earlier
(burst-to-burst jitter). **Locating the onset in this window: UNDETERMINED, not scored.**

**Detector attempt and failure.** Predicted a frame-to-frame Pearson-correlation dip
(`FRAME_RECORDS = 4*12333 = 49332` raw records) at a re-anchor event, on the premise that the ROM's
repeating content gives a stable, high frame-to-frame correlation under steady lock. On real data
this premise did not hold: baseline median correlation is `~0` (statistically indistinguishable from
uncorrelated) in both captures, not high and stable. Root cause: these enb-domain taps drop records
at `~488 per 1e6` (Tier-2 output) -- about 1 drop per 2049 records -- so a 49332-record window
contains ~24 drops on average and naive fixed-raw-record slicing is not phase-aligned to the ROM
cycle almost anywhere in the file (confirmed directly: 49.7% of all 1359 frame boundaries in BOTH
captures have a drop within +/-500 records -- the base rate everywhere, not something distinguishing
any one boundary). `onset.bin` scored 0 dip events over 1359 boundaries; `mid.bin` scored exactly
one, at frame boundary 615 (corr `-0.242`, ~40x the baseline MAD).

**That one dip is not reported as a finding.** Positive control (real `onset.bin`, quiet stretch
frames 50-150, unrelated to any locus): injecting a synthetic sample roll of `FRAME_RECORDS//5`
(~9866 records -- far larger than any plausible sub-symbol artifact) at the stretch's midpoint
produced **no detected dip** (corr at the injection boundary `-0.0128`, inside the quiet band).
Negative control (same stretch, unmodified): 0 events, as expected. Per the §0 rule, a detector that
cannot show a controlled non-null may not be used to score real data -- **the sel14
frame-correlation detector is not fit for purpose as designed** (drop rate invalidates the framing
assumption; demonstrated insensitivity to an injected shift larger than any real target). The single
raw dip at boundary 615 is an unexplained data point, not evidence: the 49.7% base rate of
drop-adjacency means "near a drop" does not distinguish it, but the detector's proven blindness to a
much larger synthetic injection means a genuine smaller event could equally have produced nothing.

**Verdict: UNINFORMATIVE for sel14** -- not from scarce data, but from a detector invalidated by the
tap's own drop rate. A drop-aware (tref-corrected, short-local-window) redesign would be needed
before sel14 can produce a real CONFIRMED/FALSIFIED reading; not attempted here. Per the controller's
explicit HOLD instruction, **no sel15 arm was launched**; this is reported to the operator for a
decision on next steps (redesign sel14's detector and re-score the same captures with no new arm,
since the data already exists; or accept UNINFORMATIVE and proceed to sel15; or stop).

**Provenance:** capTAP, errps, Tier-2, and correlation-scan results are [silicon]; the ~1.1s
acquisition-duration figure and ~120.22s cross-arm anchor are cited from prior rulings/arms, not
re-derived [inferred]/[silicon, different arm] respectively; the drop-rate and drop-adjacency-base-
rate figures are computed directly from this arm's own `tref` sidecar [silicon].

## §84 correction (controller-directed detector revision 2): sel14 CONFIRMED, no new arm [silicon]

The UNINFORMATIVE verdict above used a raw-record-index frame-correlation detector that violated
the standing dispatch instruction ("index every analysis by tref and mark_demod, never by record
index") -- the controller directed one further revision (the second and last allowed for sel14):
rebuild the same frame-to-frame comparison keyed by tref VALUE, excluding drop-adjacent record
positions from each frame individually rather than letting drops corrupt raw-index alignment
globally. Full method, unit tests, and results in `TASK9_PREREG.md` Addendum 4. No new arm --
re-scored the existing `beatcap2-sel14-193632` captures.

**Result:** the original premise (steady lock gives high, stable frame-to-frame correlation) holds
once correctly aligned: baseline median correlation `~0.965` (MAD `~0.004-0.006`) in both captures,
vs the deprecated design's `~0`. Positive control (real `onset.bin`, injected sample-roll skew at a
quiet frame boundary): correlation collapses from `~0.96` to near-zero across 6 consecutive
boundaries starting exactly at the injection point. Negative control (unmodified quiet stretch): 0
events. Both PASS.

**Real data:** `onset.bin` shows 4 consecutive dip events at frame boundaries 1112-1115 (correlation
`0.52, 0.06, 0.71, 0.05` against a `0.965`/`0.935` baseline/threshold; records `40,891,966`-
`41,001,202`, `60.93%-61.10%` of the file) -- the same multi-boundary collapse shape as the positive
control. `mid.bin` shows 1 dip event at frame boundary 858 (correlation `0.55`; record `30,318,592`,
`45.18%` of the file) -- within ~20,700 records of the deprecated raw-index detector's single flagged
anomaly at the same capture (a cross-validation between two independently-designed detectors).
Nowhere else in either 512 MB file dips.

**Window-timeline placement:** `mid.bin`'s dip at `T_trigger+2.68s` [inferred], inside its
`[2.18s,3.28s]` window (~0.5s in, mid-window, not an edge artifact). `onset.bin`'s dip span at
`T_trigger+123.59s` [inferred], inside its `[122.92s,124.02s]` window (~0.67s in, also mid-window).

**Reconciling with the §84 capTAP brackets:** `mid.bin`'s bracket (rung->gold, return event
evidenced) is consistent with the dip found there. `onset.bin`'s bracket was gold->gold
("UNDETERMINED, no event evidenced" in the original §84 text) -- the detector's positive finding
there is independent evidence from the buffer content itself (a different signal than the coarse
tap-3 capTAP register) and supersedes that UNDETERMINED reading: a real discontinuity IS present
inside `onset.bin`'s window, the capTAP register just did not happen to register it.

**Verdict: CONFIRMED for sel14** (revises the UNINFORMATIVE verdict above). Contrast with §83:
sel13's interpolator PHASE ACCUMULATOR showed zero discontinuity in a capTAP-bracketed return-event
window (a different arm); sel14's BUFFER shows a real, controlled, localized one. Suggestive (not
re-litigated here) that the re-anchor mechanism perturbs the buffered sample stream without a
correlated step in the loop's own phase-tracking register.

**Provenance:** [silicon] for all capTAP/Tier-2/correlation-scan/control results (measured on board
148, this arm's own captures, no new arm); [inferred] for the ~1.1s window-duration estimate and the
window-relative dip timestamps derived from it.

## §84 wording correction (controller-directed): "mover" language, not a re-measurement [silicon]

Data and verdict unchanged from the §84 correction above; only the causal interpretation is
corrected, per the controller's ruling. Full text in `TASK9_PREREG.md` Addendum 6.

sel14 = `Symbol_Synchronizer.Delay8` = the interpolated SAMPLE stream itself (data content, not a
control register). A frame-to-frame correlation dip there shows a re-anchor event occurred inside
the window and that the displacement is present at the interpolator's output -- it does **not** show
the Delay8 buffer is the mover: per the §72 "transparent stage" logic, any data tap at or downstream
of the true mover shows the same dip, and the frame-identity limit (identical repeating ROM frames)
means a k-symbol shift is invisible except at the shift boundary, which is exactly why the dip is
transient (4 boundaries, then apparent recovery) rather than sustained.

**Corrected verdict phrasing:** sel14 -- **"CONFIRMED: displacement present at sel14; event located
in-window"** (never "CONFIRMED that the buffer is the mover"). Locates the mover AT OR UPSTREAM of
the interpolator output.

**sel13, strengthened:** the sel13 (§83) and sel14 arms are different arms (different `T_trigger`),
but their windows are comparable in burst phase -- `mid.bin` windows within 0.03s of each other
(`T_trigger+[2.15,3.25]` vs `[2.18,3.28]`), `onset.bin` windows within 0.12s
(`T_trigger+[122.80,123.90]` vs `[122.92,124.02]`) -- close phase agreement across independently
triggered arms. On that comparable window, sel13's interpolator phase accumulator showed no step.
**Together: the mover is not the interpolator's phase control loop; the displacement enters at or
upstream of the interpolated sample stream** -- consistent with, not narrower than, §82's P2 finding.

**Frame-identity limit, explicit:** sel14's dip locates WHEN a displacement is visible in each
window, not WHERE in the pipeline it originates; the transient (not sustained) shape is exactly what
the frame-identity limit predicts for a shift between bit-identical ROM frames, not independent
evidence of "recovery."

**By-product, [silicon] with controls:** the tref-indexed, drop-aware frame-correlation detector is
the first tool in this campaign to locate a re-anchor event inside a full-rate (high-drop-rate)
DDRCAP-v2 window (validated by real-data positive/negative control, §84 above) -- it resolves the
general event-location problem for future full-rate arms; sel13's own detector cannot distinguish
"no event" from "an event outside its sensitivity" without a tool like this one.

## §85 Task 9, sel15 arm (last of 3): Rate_Handle FIFO LEVEL form, FALSIFIED [silicon]

Per the P2 stop rule (sel13 falsifier earned for the return event, §83; sel14 event located, §84),
the third and last arm: sel15 (Rate_Handle FIFO), pre-registered in `TASK9_PREREG.md` Addendum 5
before arming, using a displaced-state LEVEL form (occupancy comparison) rather than a
transition-in-window form, per the controller's ruling that a transition's presence in a window
cannot be assumed for these taps. Arm `beatcap2-sel15-195819` (19:58:19-20:03:20): `ARM_OK ...
capTAP=0xBCF94856`; `TRIGGER errps=63602 at +40s` (20:01:07). `mid.bin`: 536,870,912 B,
`pre=0xD71F70D3 post=0xBCF94856 credit=yes`. `onset.bin`: 536,870,912 B, `pre=0xD8A04817
post=0xBCF94856 credit=yes`. Both credited, rc=0.

**Tier-2:** `ddrcap2_pc.py --sel 15` PASS on both (`d0=12314`, matching the sel13 arm's;
`rhctr_bounded_nonzero` and `push_pop_advance` both PASS -- `push`/`pop` are live counters, not
stuck).

**Window timeline (same method as §83/§84):** `mid.bin` `~= T_trigger+[2.13s,3.23s]` -- inside the
burst. `onset.bin` `~= T_trigger+[122.44s,123.54s]` -- ~2.2-3.3s after the ~120.22s cross-arm
anchor, the same pattern as the sel13/sel14 arms. capTAP brackets: BOTH `mid.bin`
(`0xD71F70D3`->`0xBCF94856`) and `onset.bin` (`0xD8A04817`->`0xBCF94856`) show rung->gold -- a
return event is evidenced inside both windows (unlike sel14's `onset.bin`, which was gold/gold).

**LEVEL form (primary), controls first:** negative control (real `onset.bin`, quiet stretch split
in half, unmodified) -- `diff=0.0`, not confirmed. Positive control (disjoint stretch, synthetic
`+15` mod-32 step injected at the midpoint) -- `diff=15.0`, confirmed. Both PASS.

**Real data: `occupancy = (push-pop) mod 32` is exactly `1` on every one of 16,744,451
tref-indexed clean samples, in BOTH captures, with zero variance anywhere.** `push` and `pop`
individually sweep their full `[0,31]` range (not stuck) but stay in exact lockstep throughout. The
pre-registered within-window before/after comparison (first-20% vs last-20% of each window, using
each capture's own capTAP bracket as the reference since neither file turned out to be purely quiet)
gives the same null result in both captures.

**Verdict: FALSIFIED for the LEVEL form.** No occupancy difference of any magnitude -- not the
predicted "tens of counts", not any counts -- between in-burst-adjacent and onset-adjacent samples,
nor within either window's own capTAP-bracketed before/after halves, on a detector validated by
real-data controls to detect an injected step of the same order.

**Secondary (event-location, windowed mean-shift on occupancy):** degenerate given the LEVEL result
(occupancy has zero variance, so every delta is exactly 0) -- formally run per the
pre-registration, 0 events on both captures, consistent with, not independent of, the LEVEL finding.

**Verdict: sel15 -- FALSIFIED (LEVEL); no event located (secondary).** Read against §84: the
Rate_Handle FIFO is downstream of the interpolator and its `push`/`pop` counters track FIFO
throughput bookkeeping, not sample values -- a pure data-content shift of the kind sel14 located
need not perturb `occupancy` if the FIFO stays properly paced regardless of which samples pass
through it. This does not contradict sel14's finding; it says sel15's own instrumented quantity is
insensitive to it, a different question from whether the FIFO is the mover.

**No further arms -- this was the third and last of the Task 9 P2-branch stop rule's arms.**

**Provenance:** capTAP, errps, Tier-2, occupancy, and control results are [silicon] (board 148, this
arm's own captures); the ~120.22s cross-arm anchor and ~1.1s window-duration estimate are cited from
prior arms/rulings, not re-derived [silicon, different arm]/[inferred] respectively.

## §83 correction (review-directed): capTAP bracket width, sel13 verdict reworded [silicon]/[inferred]

Data unchanged; corrects an overreach in how the capTAP bracket was read. Full detail in
`TASK9_PREREG.md` Addendum 8.

Every capTAP "post" read quoted above is taken at the `mid:`/`onset:` log line, which fires only
AFTER the 512 MB file is copied back host-side over SSH -- ~9-11 s after the `BOARD` line (window
close). Measured directly (`journalctl -o short-precise`): sel13 `mid.bin` gap `9.42s`, `onset.bin`
gap `11.56s` (sel14: `9.46s`/`11.42s`; sel15: `10.17s`/`9.42s` -- same pattern on both other arms).
The capTAP bracket's evidenced interval is therefore window+copy (~10-12s), not the ~1.1s scored
window the detector actually ran on.

**Consequence:** the null result -- `countReg` shows no discontinuity anywhere in the ~1.1s of data
actually scored -- stays **[silicon]**, a direct measurement unaffected by where the capTAP
transition happened. That the rung->gold transition itself fell INSIDE the scored 1.1s window (as
opposed to during the trailing copy) is **not** established by the bracket alone -- it is
**[inferred]**, via cross-arm transfer: the beat is phase-locked to the arm script (six arms, six
`+40s` triggers, `mid.bin` pre-read rung `6299` every time), and sel14's tref-indexed detector (§84)
-- which CAN precisely locate an event within its own scored data -- found its events at ~45%
(`mid.bin`) and ~61% (`onset.bin`) of comparably-timed windows using the same script and timing.
Transferring that in-window location onto sel13's own comparably-timed windows is the basis for
placing an event inside the sel13 scored window; it is a transfer from a different arm's direct
finding, not a measurement on the sel13 captures themselves.

**Corrected verdict wording (supersedes "FALSIFIED for the return-to-quiet re-anchor event" above):**

> **FALSIFIED [inferred: event placement transferred from the sel14 arm's in-window location under
> the phase-lock observation]; phase continuous through the whole window [silicon].**

The same bracket-width caveat applies to the sel14 (§84) and sel15 (§85) capTAP brackets, stated for
completeness -- it does not change either verdict: sel14's finding did not rely on the bracket at
all (its detector located the event directly, inside scored data); sel15's LEVEL-form finding is a
direct measurement of the actually-scored data, independent of exactly when within the wider bracket
a transition occurred.

## §85 correction (review-directed): sel15 dynamic range, an interpretive limit [silicon]

Verdict word unchanged; adds a measured fact and its interpretive consequence. Full detail in
`TASK9_PREREG.md` Addendum 9.

Computed over ALL records (not just the tref-indexed clean subset the LEVEL form scores),
`occupancy=(push-pop) mod 32` takes exactly two values in both captures: `{0,1}`. `occupancy==0`
occurs ONLY at `tref<0` positions (a record-decode artifact of push/pop updating on a different
sub-cycle than the tref sidecar, not a real "empty FIFO" reading) -- 0% of `tref>=0` (clean, scored)
positions show `0`. **At every clean sample, `occupancy` is exactly `1`** -- the FIFO runs
effectively pass-through at this tap.

**Interpretive limit, stated explicitly:**

> **FALSIFIED under the pre-registered LEVEL form [silicon]; interpretive limit: with occupancy
> pinned at 1, the LEVEL form can exclude an occupancy-based mover but cannot see a re-anchor that
> leaves occupancy unchanged (e.g. one in the FIFO's control/pacing path). The `+15` positive control
> proves the detector, not that the field can move under a real re-anchor event.**

Recorded fact for the record: observed sel15 occupancy range across all six captures'
tref-valid records = `{1}` only (never `{0}` at a clean sample); across ALL records including
tref-invalid ones = `{0,1}`, with `0` exclusively a `tref<0` decode artifact.

## §82 addendum (final-fix round, 2026-09-02): frame-period correction, the unreported None episode, tOff modulus, TX-marker coincidence [silicon]

Addendum to §82, not a rewrite. Filed against the final whole-branch review's fix brief
(`.superpowers/sdd/2026-09-02-ddrcap2-joint-timing-capture/final-fix-brief.md`), items A-D. No arm,
no board contact -- write-up plus offline re-analysis of the already-captured
`two_jup/beatcap/20260902_185552_sel6/{onset,mid}.bin`.

### 1. Frame-count correction: the 0.066%/0.084% "drop" was a P=12333-vs-12320 artefact [silicon]

§82's three-way frame-count table used `frames_by_index = records // P` with `P=12333` -- the DDR
*record*-frame length (also the `timing_Reference` tref modulus), not the sel6 demod-marker period.
On silicon the sel6 tap's `mark_demod` period is exactly **12320** records (offset-map's own declared
frame length, `offsetmap/tap3_word_to_offset.tsv`: "frame=12320 symbols"; the 13 preamble symbols
never reach the demod-input tap). `ddrcap2_beat_analysis.py` now measures this period directly from
the modal gap between consecutive `mark_demod` marks (`measured_period()`, fallback 12320), instead of
dividing by the record-frame constant `P=12333`; `P=12333` is kept only for the tref-wrap-detection
threshold, where it is correct (`frames_by_tref`'s `-12000` gap test), and for the full-rate sel12-15
taps (unaffected by this fix -- they are indexed by tref, not `frames_by_index`).

Re-run, `measured_period=12320` on both captures:

| capture | frames_by_marker | frames_by_index (P=12320) | frames_by_tref | verdict |
|---|---|---|---|---|
| onset.bin | 5445 | 5447 | 5445 | P2 |
| mid.bin   | 5446 | 5447 | 5447 | P2 |

The three counts now agree within partial-frame slack (marker and tref agree exactly or within 1 on
both captures; `frames_by_index` runs ~1-2 frames ahead of the marker count, consistent with the
capture window holding a couple of partial frames at its start/end that no `mark_demod` boundary
closes) -- **the pre-registered three-way check PASSES.** The §82 table's "0.066%/0.084%, 2.2x/2.8x
the stated upper bound" drop-rate finding is **withdrawn**: it was an arithmetic artefact of dividing
by the wrong constant, not a measurement of missing records. Redone with the correct constant
(records_total=67,108,864 both captures, P=12320):

| capture | fr (marker) | fr·P | actual records | actual − fr·P | as fraction of fr·P |
|---|---|---|---|---|---|
| onset.bin | 5445 | 67,082,400 | 67,108,864 | **+26,464** | +0.039% |
| mid.bin   | 5446 | 67,094,720 | 67,108,864 | **+14,144** | +0.021% |

Both differences are *positive* (more records captured than `fr·P`, not fewer) and each is close to a
small integer multiple of `P` (26,464/12,320 ≈ 2.15 frames; 14,144/12,320 ≈ 1.15 frames) -- exactly
the signature of partial frames straddling the window edges that the marker count doesn't credit, not
a drop. This is consistent with (does not itself re-derive) `ddrcap-fullrate-dma-drops.md`'s
per-record drop-rate figure; no drop-rate claim is made here at all, upper-bound or otherwise.

Tests: `two_jup/tests/test_ddrcap2_beat_analysis.py` parametrised over `period in {12320, 12333}` (9
tests, up from 4) plus one direct regression pinning `frames_by_index` to the measured period, not a
hardcoded `12333` -- `pytest tests/` -> **58 passed** (whole `two_jup/tests/` suite). Regenerated
`onset_verdict.json`/`mid_verdict.json` committed; **verdict remains P2 on both captures.**

### 2. The unreported episode: `d_data=None` for ~23% of frames in both captures [silicon]

Both sel6 captures spend a substantial minority of their frames with `d_data=None` -- the 16-bit
hard-decision word at demod-marker+1 maps to no entry in the offset table under any of the four QPSK
rotations -- which §82's table did not mention. Re-derived directly from `per_frame_offsets()`
(`two_jup/ddrcap2_beat_analysis.py`), classifying each frame's `d_data` as `0` / `rung` (one of
`RUNGS`) / `None` / `other`:

- **onset.bin**: 1257/5445 frames (**23.09%**) are `None`. Two `None` episodes: a short one, records
  `[10306770, 10319089]` (≈1 frame), and the dominant one, records **`[51372966, 66832414]`** (≈15
  frames, ≈23% of the ≈1.1s window) -- this is the episode the review flagged; the reviewer's quoted
  bounds (`≈51.37M-66.83M`) match this re-derivation to 4 significant figures.
- **mid.bin**: 1268/5446 frames (**23.28%**) are `None`. One short episode, records
  `[27797073, 27809392]` (≈1 frame), and the dominant one, records **`[40405575, 56021577]`** (≈13
  frames, ≈24% of the window) -- again matching the reviewer's quoted bounds (`≈40.41M-56.02M`).

Every `d_data` class transition in both captures (record index, `from -> to`), excluding each file's
own opening frame (which is a capture-boundary fact, not a transition -- see below):

```
onset.bin (opens on a RUNG, record 11959 -- the capture literally begins mid-burst, not at baseline):
  10306770  rung -> None
  10319090  None -> 0
  23432846  0    -> rung    (the pre-registered §82 onset_beat_data)
  38579675  rung -> None
  38591995  None -> 0
  51372966  0    -> None
  66832415  None -> 0

mid.bin (opens on 0):
  12481194  0    -> rung    (the pre-registered §82 onset_beat_data)
  27797073  rung -> None
  27809393  None -> 0
  40405575  0    -> None
  56021578  None -> 0
```

`toff` is verified constant at `d0=12314` on every record through both `None` episodes in both
captures (checked directly, not inferred) -- **the P2 verdict concerns the `0 -> rung` step
specifically** (`onset_beat_data`, unaffected by anything reported here), and **tOff is unchanged
through the `None` episodes too**, same as it is through the rung episodes. Nothing in this section
changes the P2 verdict; it fills in a gap in §82's own table (which reported `onset_beat_data`'s
`0->rung` step but not the `None` episodes that bracket most of the rest of each file).

### 3. tOff modulus correction: mod 12333, not mod 12320 [silicon]

`tOff` (ch2[13:0]) is latched from `timing_Reference_out1`, a free-running counter that wraps
`0..12332 -> 0` (`jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/Peak_Search.v`, lines
82-104: `count_step`/`count_from`/`need_to_wrap` compare `timing_Reference_out1` against
`14'b11000000101100` = decimal `12332`, and reset to 0 past it -- 12333 distinct states, **mod
12333**, not mod 12320 -- the demod-marker/offset-map frame length is a separate, unrelated 12320-
symbol constant). §82's cross-arm/cross-domain `d0` residual paragraph folded all three `d0` values
mod 12320; that was the wrong modulus for a `timing_Reference`-sourced field. Corrected, mod 12333,
folded to the signed residual nearest zero:

| source | d0 (raw) | residual mod 12333 |
|---|---|---|
| Task 7 arm (5 sel6 positive-control captures) | 26 | **+26** |
| Task 8 arm 2 (this capture, both onset.bin and mid.bin) | 12314 | 12314-12333 = **-19** |
| Tier-1 sim gate (`ddrcap2_gate.log`, sel6) | 12323 | 12323-12333 = **-10** |

All three residuals are still small (single/low-double-digit) and still **pairwise different**
(+26, -19, -10) -- the non-null-tOff criterion (§82's OR rule) still holds, and the conclusion is
**unchanged**: this is the signature of a live, locked fine-timing latch, not three copies of one
stuck value. Only the modulus used to compute the residuals was wrong in the original §82 text
(mod 12320 gave `+26, -6, +3`, a materially different-looking but equally "pairwise different, all
small" table -- the correction changes the numbers, not the conclusion drawn from them).

### 4. TX-marker coincidence, independently re-derived [silicon, observation]

Reviewer finding under check: "every `d_data` transition in both captures (9/9) is preceded by
exactly one record by an anomalous EXTRA `Transmitter_txFrameStart` pulse (ch2 bit14, `mark_fec`),
while the regular TX cadence (period 12320, 48 records ahead of the next `mark_demod`) continues
undisturbed." Re-derived independently with a new committed script, `two_jup/ddrcap2_txmark_scan.py`
(walks the sorted `mark_fec` positions; a position that breaks the regular period-12320 chain, where
the *next* position resumes it, is flagged EXTRA -- see the script's docstring for the exact
algorithm). Positive control: the regular cadence is recovered at period 12320 with the expected
count on every real capture scanned (`positive_control_pass=True` on all eight files run). Negative
control: a synthetic period-12320-only stream reports zero extras (`ddrcap2_txmark_scan.py --negctl`).

**Re-derivation, sel6 (both captures), `two_jup/beatcap/20260902_185552_sel6/{onset,mid}_txmark.json`:**

- `onset.bin`: 5 extra pulses (`10306769, 23432845, 38579674, 51372965, 66820094`) -- these
  reproduce the reviewer's own quoted onset extra-pulse list exactly. 7 real transitions (excluding
  the opening-frame pseudo-transition, §2 above): **4/7 are immediately preceded (record distance
  exactly 1) by an extra pulse; the other 3 are not** (nearest extra pulse is a full ~12,320-record
  cadence period away, not 1 record).
- `mid.bin`: 4 extra pulses (`12481193, 27797072, 40405574, 56009257`). 5 real transitions: **3/5
  immediately preceded; the other 2 are not** (same ~12,320-record-away pattern).

**Correction to the reviewer's "9/9":** the coincidence is real but narrower than reported. The
match is not with "every transition" -- it is specifically with **transitions that move `d_data`
AWAY from the `0` baseline** (`0->rung`, `rung->None`, `0->None`): all **7 of 7** such departure
transitions across both captures are immediately preceded by an extra pulse. Transitions that move
`d_data` BACK to `0` (`None->0`) are **never** immediately preceded by an extra pulse (0 of 5) --
their nearest extra pulse is a full cadence period away. The reviewer's own quoted onset list
actually contains one such return transition treated as a match it is not: `extra=66820094` paired
with `transition=66832415` is **12,321 records apart, not 1** (`66832415` is a `None->0` return, and
its own immediately-preceding pulse is a *regular*, not extra, TX mark at `66832367`, 48 records
before it, same as every other regular demod-adjacent pulse). Corrected count: **7/12 total
transitions** immediately preceded by an extra pulse (7/7 departures, 0/5 returns) -- not 9/9, and
not evenly distributed across transition types.

**Full-rate captures (sel13/14/15, period 49332):** `ddrcap2_txmark_scan.py --fullrate` run on all
six `.bin` files in `beatcap/20260902_{192051_sel13,193632_sel14,195819_sel15}/`. **Zero extra
pulses found in any of the six files** (`n_extra=0`, `positive_control_pass=True` on all six --
regular period-49332 TX cadence recovered normally, nothing anomalous around it). In particular,
sel14's own located re-anchor events (`onset.bin` record `40,891,966`, frame boundary 1112;
`mid.bin` record `30,318,592`, frame boundary 858 -- §84/Addendum 4) have **no extra TX pulse
anywhere in the same file**, let alone nearby: the extra-pulse phenomenon documented here is
observed only on the sel6 (symbol-domain, marker-carrying) captures, not on any full-rate
(enb-domain) tap scanned so far. Stated as an observation only, per the brief -- no interpretation
of what generates the extra pulses or what causal role (if any) they play is offered here.

**Provenance:** all record indices, extra/regular-pulse classifications, and transition counts in
this section are [silicon] (directly measured DDR-v2 ch2 fields, this capture); the frame=12320-
symbols and `timing_Reference` mod-12333 facts are cited from the offset-map header and
`Peak_Search.v` respectively, not re-derived beyond the direct RTL read quoted above.

## §83/§84 addendum (final-fix round, 2026-09-02): overreach in the "mover is not the interpolator's phase control loop" sentence, corrected [silicon]

Addendum to the "§84 wording correction" section above (and its echo in `TASK9_PREREG.md` Addendum
6), not a rewrite of either. Filed against the final-fix brief item C. No arm, no board contact.

**The problem.** The §84-wording-correction section's closing sentence reads: "Together: the mover is
not the interpolator's phase control loop; the displacement enters at or upstream of the interpolated
sample stream." That sentence overreaches what sel13's own detector (§83) actually validated. §83's
positive control (`TASK9_PREREG.md` Addendum 1) injects a **sustained, per-symbol +40-count
offset into `countReg`** -- a change to the interpolator's phase-accumulation *rate*, i.e. a timing
RATE change held over many symbols -- and shows the windowed-mean-shift detector finds it. It was
never shown to detect a one-shot PHASE STEP of the size a symbol re-anchor would actually produce:
a single re-anchor is a single jump in the NCO accumulator's value, which appears in `raw_delta` as
exactly one elevated single-pair delta, not a sustained per-pair elevation. §83's own module docstring
already documents that real silicon `countReg` has a heavy-tailed per-symbol background where ~6% of
clean pairs show a step >64 counts even far from any predicted locus (`task9_sel13_detector.py`,
module docstring) -- a one-shot phase step of that same rough magnitude sits inside that jitter and
would not move a `w=1000`-wide windowed mean by more than the noise floor. The windowed-mean-shift
detector is well-controlled for *its own* positive control (a sustained rate change) but was never
run against a one-shot-step positive control, so it cannot be said to have ruled one out.

**Corrected claim.** What §83's zero-events full-file scan actually earns:

> **[silicon] "No sustained change in the interpolator's phase-accumulation rate (mean `raw_delta`
> per clean pair) anywhere across the scored window."**

What it does **not** earn, and is struck/qualified here:

> ~~"the mover is not the interpolator's phase control loop"~~ -- **not established.** A one-shot
> phase step (the kind a symbol re-anchor produces) is a different signal shape than the sustained
> rate change the detector was controlled against, and sits inside the documented ~6%-of-symbols
> jitter background the windowed statistic is specifically built to average away. §83's null result
> does not distinguish "no re-anchor event of this kind occurred in this window" from "a one-shot
> re-anchor event occurred and was invisible to a detector tuned for sustained-rate changes."

**Alternative named at pre-registration time, not scored.** `TASK9_PREREG.md`'s original
pre-registration (before Addendum 1's detector revision) named an underflow-cadence alternative
statistic alongside the countReg magnitude/mean-shift approaches; per the detector-revision
discussion in Addendum 1, only the windowed-mean-shift statistic was carried forward to score real
data. **The underflow-cadence alternative was not scored on either sel13 capture** -- it remains an
open, un-run check, not a ruled-out one.

**What is unaffected.** §82's original P2 finding (mover upstream of the demod-marker anchor, in the
data path) is unaffected -- it was never based on the struck sentence. §84's sel14 finding (a
displacement event physically located at the interpolator's output, `onset.bin` frame boundaries
1112-1115 / record ≈40.89M, `mid.bin` frame boundary 858 / record ≈30.32M) is a direct, positively-
controlled measurement (§84/Addendum 4) and is unaffected by this correction -- it locates the mover
AT OR UPSTREAM of the interpolator output, which remains the strongest positive statement this
campaign has made about the mover's location. Only the negative claim built by *combining* that
sel14 finding with sel13's null result -- "therefore the mover is specifically not the phase control
loop" -- is withdrawn as unsupported by the detector actually run.

**Locations corrected (addenda, not rewrites):** the sentence above, in the "§84 wording correction"
section of this file; the equivalent sentence in `TASK9_PREREG.md` Addendum 6 ("**Together: the mover
is not the interpolator's phase control loop, and the displacement enters at or upstream of the
interpolated sample stream**") -- see `TASK9_PREREG.md` Addendum 10 for the addendum filed there.

### §82 addendum (controller, final re-review residual): TX-marker scanner positive control made real [silicon]
The scoped re-review found `ddrcap2_txmark_scan.py`'s `positive_control_pass` tautological (it compared the
regular-pulse count against itself). Replaced by a real control: for EVERY regular TX pulse, the record
distance to the next demod mark; PASS iff the modal distance covers ≥ 99 % of regular pulses. Re-run on all
eight captures (JSONs regenerated):

| capture | modal offset | fraction | control | extra pulses | departures preceded |
|---|---|---|---|---|---|
| sel6 onset | 48 | 1.000 (5445/5445) | PASS | 5 | 4/7 transitions (all 4 departures) |
| sel6 mid | 48 | 1.000 (5445/5445) | PASS | 4 | 3/5 transitions (all 3 departures) |
| sel13/14/15 onset+mid (six) | 246 | 0.867–0.892 | **FAIL** | 0 | — |

Consequence: the sel6 result (7/7 departures preceded by exactly one record by an extra TX frame-start pulse,
0/5 returns) stands with its control [silicon]. The full-rate "0 extra pulses" result is **UNINFORMATIVE**,
not a null: 11–13 % of regular pulses sit off the modal cadence on those taps (DMA drop bursts delete records,
so a one-record pulse is neither reliably present nor reliably placed), which is the same drop mechanism as
§81. The earlier "open discrepancy" with sel14's located events is therefore withdrawn as a discrepancy: the
scanner is not validated at full rate. Frame-identity limit unchanged.

## §86-C sel8 arm: does the TX sample stream itself restart at the extra mark_fec pulse? P-TX FALSIFIED/UNINFORMATIVE, P-TX' MIXED [silicon]

Board 148 only. Instrument: DDRCAP-v2 (flashed, verified), selector 8 =
`Transmitter_dataOutI/Q` (TX modulator sample output, 4 records/symbol, enb-domain). Pre-registered
in `SEL8_PREREG.md` (commit `295e4d4`) plus Addendum 1 (`4fd4576`, filed after the arm's captures
completed but before any decode/score, per coordinator direction: `TX_ORIGIN_TRACE_A.md`'s
read-only RTL trace changes the expected TX signature and adds a second, top-ranked mechanism,
P-TX'). Detector: `sel8_tx_restart.py` (commits `6240489`, `8a60681`, `a43a625`).

**Arm.** `beatcap2-sel8-212830` on 148, `beat_tap_capture.sh SEL=8 LEAD=0.5`. `ARM_OK`, capTAP
golden (`0xBCF94856`) at arm. Burst triggered at +40 s (errps=47969). Both `mid.bin` and
`onset.bin` captured (536,870,912 bytes each, 67,108,864 records) with pre/post capTAP golden --
**both credited**. Output: `beatcap/20260902_212830_sel8/`.

**Tier-2.** Both files **PASS** `ddrcap2_pc.py --sel 8` after one recalibration, made and
committed (`0c124cf`) before scoring: the generic `not_constant_IQ` check (>100 distinct sample
values) FAILed on both captures even though direct inspection shows a clearly modulated, cyclic,
bipolar waveform -- just a genuinely small alphabet (**39 distinct sample values across the FULL
67M-record file, both captures** -- pulse-shaped, ROM-driven TX content per §82's established
frame-identity fact). sel8 is now exempted from the generic threshold and given its own
`not_constant` rule (threshold 20, comfortably below 39 and above a stuck register's 1-2) plus
`both_signs_present`, `demod_marks_present`, `tx_marks_present`, alongside the shared
`tref_cadence` rule (enb-domain group). All PASS on both files.

**Method deviations (recorded per SEL8_PREREG.md's own rule; both discovered by direct inspection
of real data, both fixed and re-self-tested before any real-data score was trusted):**

1. **Template construction refined to position-wise** (`8a60681`). The pre-registered whole-52-
   record-block equality test failed on 9-24% of regular pulses in a first pass. Direct inspection
   (record 16,031,614 vs the capture's first regular pulse) showed why: positions 0-27 of the
   52-record window are **bit-identical across every regular pulse** (the fixed preamble) while
   positions 28-51 legitimately differ once a displacement has occurred -- exactly what P-TX'
   predicts (payload is a time-shifted continuation, not noise, once a stall/resume has happened).
   The template is now built per-position (modal value, truncated to its stable >=90%-agreement
   prefix) instead of requiring the whole block to match; on real data this recovers a
   **28-record (7-symbol) stable preamble template** on both files.

2. **Wrap-count guess replaced with a global tref unwrap** (`a43a625`). The original per-mark_fec-
   pair wrap-count heuristic (guess the number of 12,333-symbol wraps between two pulses from
   their record-index gap) assumed that gap approximates the true symbol gap to within half a
   frame period. A real counterexample in `mid.bin`: two `mark_fec` events 17,391 records apart
   (heuristic estimate ~4,348 symbols) that a full tref-delta walk shows are **12,332 symbols --
   one whole frame -- apart**, because one localized drop burst inside that span cost a single
   slot1-to-slot1 step of 6,638 symbols plus several smaller ones. The heuristic picked zero wraps
   instead of one, so **every** "extra" `mark_fec` candidate in the first pass scored
   `p_tref_units=0` -- a wrap-count artifact, not a real doublet. Replaced with one global,
   monotonic tref-unwrap pass over every slot==1 record in the file (correcting only genuine
   backward wraps), with each record's symbol-time then a single lookup into that axis. All three
   synthetic self-tests (P-TX confirm, P-TX falsify, P-TX' stall-injection positive control)
   re-verified passing after the fix, before re-running on real data. `excessive_tref_steps`
   (>= one full frame period in a single slot1-to-slot1 step) is reported as an explicit
   diagnostic; **zero** on both real captures -- the fix's own no-larger-than-half-period
   assumption holds cleanly on both credited files.

**P-TX result (original hypothesis: TX sample stream itself shows a fresh frame-start template at
the extra `mark_fec` pulse).**

| capture | n_extra (doublet-classified) | p_tref_units | template_match | continuation_match | verdict |
|---|---|---|---|---|---|
| mid.bin | 1 | 0 | True (score 1.0) | False (score 0.0) | (see below) |
| onset.bin | 0 | -- | -- | -- | UNINFORMATIVE (no extra located) |

`mid.bin`'s single located "extra" has **p=0** -- it is essentially co-timed (same symbol-time,
within the doublet-chain's own resync tolerance) with its own preceding regular pulse, not
displaced by anything resembling a rung (6176-6548 symbols). Its "template match" is not
informative about a restart: comparing the record immediately after a pulse that IS the regular
frame boundary against the regular-frame template is close to tautological. **No genuine
mid-frame extra pulse at a rung-scale `p` was located in either credited capture** -- Addendum 1's
prediction (the recorded "extra `mark_fec`" is a sticky-latch/drop recording artifact, `1a` in
`TX_ORIGIN_TRACE_A.md` sec1, not a genuine second `Bit_Packetizer_dataStart` assertion) is
consistent with this p=0 finding, though the specific mechanism observed (a doublet at p=0 rather
than the file's aggregate cadence noise) was not separately isolated as "definitely the sticky
latch" vs. "definitely a resync artifact of the classifier itself" -- both remain live readings.
**Verdict: P-TX is UNINFORMATIVE on onset.bin (no extra pulse at all) and, on mid.bin, its one
scorable event carries none of the pre-registered signature (no rung-scale `p`) so the CONFIRMED/
FALSIFIED test as pre-registered cannot be run on real data as designed. Reading the absence of any
rung-scale extra pulse in either capture as evidence, per Addendum 1's own framing, this leans
FALSIFIED/UNINFORMATIVE, not CONFIRMED** -- no evidence of a genuine mid-frame `dataStart`
re-assertion was found.

**P-TX' result (Addendum 1 hypothesis: `Data_Bits_FIFO` pop-abort stall -- constant/repeating
symbols mid-frame to frame end, markers on cadence).**

Stall detector controls (SEL8_PREREG.md Addendum 1's own positive/negative controls) **PASS on
both files**: injecting a synthetic 6,176-symbol constant run into a quiet frame is found at the
right length and location; an untouched quiet frame reports no stall (`longest_run_symbols` <= 5,
consistent with chance repeats given the 39-value alphabet).

Scanning every frame (tref-indexed) in both credited captures found **4 stall-flagged frames per
file** (out of 1,342 and 1,361 scored), always in **adjacent frame-index pairs** and always at the
**same repeated (I,Q) value** within a pair (`(5736,5736)` mid.bin frames 325-326;
`(5736,5736)`/`(-5737,-5737)` onset.bin frames 131-132 and 914-915):

| capture | frames | longest run (symbols) | run start (in-frame symbol offset) | value (I,Q) |
|---|---|---|---|---|
| mid.bin | 325 | 4,866 | 6,020 | (5736, 5736) |
| mid.bin | 326 | 9,217 | 147 | (5736, 5736) |
| mid.bin | 1076 | 4,410 | 6,443 | (5736, 5736) |
| mid.bin | 1077 | 9,414 | 11 | (5736, 5736) |
| onset.bin | 131 | 13,936 | 6,081 | (5736, 5736) |
| onset.bin | 132 | 9,276 | 21 | (5736, 5736) |
| onset.bin | 914 | 4,457 | 6,374 | (-5737,-5737) |
| onset.bin | 915 | 9,421 | 0 | (-5737,-5737) |

Given a 39-value sample alphabet, a chance run this long is astronomically improbable (baseline
chance-run length in normal frames is 5 samples, confirmed directly in every non-flagged frame
scanned) -- **this is a real, controlled, non-chance silicon phenomenon**: the TX sample stream
genuinely re-emits one fixed sample value for thousands of consecutive symbols, in both credited
captures, each time straddling the boundary between two consecutive frame-index windows.

**This does NOT cleanly confirm P-TX' as pre-registered, for two honest reasons, both reported
rather than resolved:**

1. **`n_samples_in_frame` on the flagged frame-pairs is anomalously high** (e.g. onset.bin frame
   131: 18,510 captured samples in one nominal 12,333-symbol frame window) -- meaning `classify_fec`'s
   regular-pulse chain **missed a genuine regular `mark_fec` marker** in exactly this region (the
   resync fallback silently merges what should be two frame windows into one when a marker itself
   is lost, not just displaced -- a mode `classify_fec`'s doublet algorithm does not distinguish
   from a clean single frame). The true frame boundary inside the flagged span is therefore
   unknown, and the reported "frame index" pairing (e.g. 325+326) most likely represents **one
   continuous stall event straddling one real frame boundary**, not two independent stalls. The
   combined span (start-of-325 stall to end-of-326 stall) is on the order of 14,000-19,000 symbols
   -- **longer than one full 12,333-symbol frame**, which the pre-registered prediction (stall
   length ~= 6,176 + 64k symbols, terminating at THIS frame's end) does not cover.
2. **The post-stall continuation-content check (compare resumed payload against the same in-frame
   position of the previous complete frame, shifted by the pop deficit) was NOT run** -- only the
   stall's existence/length/location was scored. This is a real gap against the addendum's full
   method, not a null result; it is left open rather than claimed either way.

**Rung comparison:** none of the four stall lengths per file matches a RUNGS value (6176/6240/
6299/6363/6432/6489/6548) or a +/-4-symbol, 64-symbol-stepped neighbor of one (`rung_hits: []` on
every flagged frame). The run START locations (mid.bin: 6,020 and 6,443; onset.bin: 6,081 and
6,374) DO fall close to the pre-registered predicted start region (~6,144-6,160 symbols into the
frame) -- within ~100-160 symbols, the right order of magnitude and the right half of the frame --
which is qualitatively consistent with P-TX'. The run LENGTHS and the fact that the run continues
past the nominal frame end into the next scored window are not consistent with the pre-registered
quantitative prediction as scored.

**Overall verdict: MIXED / neither hypothesis cleanly confirmed as pre-registered.**
- **P-TX: FALSIFIED/UNINFORMATIVE.** No genuine mid-frame `dataStart` re-assertion (rung-scale `p`,
  template match against an independent mid-frame event) was found in either credited capture;
  the one located "extra" pulse (mid.bin, p=0) carries none of the predicted signature.
- **P-TX': partially supported, not cleanly confirmed.** A real, controlled, non-chance
  constant-value stall phenomenon was found in both credited captures, at start locations broadly
  consistent with the predicted region, but with lengths exceeding one frame period (implicating a
  missed marker / frame-window-merge artifact in the scoring, not scored precisely) and without
  the prescribed continuation-content check having been run.

**Frame-identity limit (SEL8_PREREG.md original text, unchanged):** applies to both hypotheses --
positions are knowable only modulo one frame period given ROM-driven, bit-identical regular frames.

**Provenance:** all record counts, capTAP values, template lengths, stall lengths/locations/values,
and Tier-2 results in this section are **[silicon]**, this arm only (`beatcap2-sel8-212830`,
2026-09-02 21:28-21:33). The RTL claims underpinning P-TX and P-TX' (`Data_Bits_FIFO.v`,
`RAM_Frame_Status_Indicator.v`, `TxRxComposite.v` line citations) are **[inferred, cited from
`TX_ORIGIN_TRACE_A.md`]**, not re-derived here -- no RTL/netlist work was performed in this section.

**Commits:** `295e4d4` (pre-registration), `4fd4576` (Addendum 1), `6240489` (initial detector,
self-tested pre-arm), `0c124cf` (Tier-2 sel8 threshold recalibration), `8a60681` (position-wise
template + P-TX' stall detector), `a43a625` (global-tref-unwrap fix), this commit (§86-C write-up
+ JSON outputs + meta/run.log/errps.csv).

## §86-C addendum: quantitative rung-geometry and continuation-content scoring (coordinator-directed re-run, no new arm) [silicon]

Re-scores the SAME two credited captures from `beatcap2-sel8-212830` (no new arm; capTAP golden
pre/post both files, unchanged from §86-C above) after a coordinator-directed fix and three new
quantitative checks, all against `SEL8_PREREG.md` Addendum 1's P-TX'. Commits: `79c92e8` (code),
this commit (write-up + JSON).

**Fix (coordinator-directed).** `classify_fec`'s marker-chain frame windowing was replaced with
`frame_windows_from_tref`: a frame boundary is now defined purely by the tref hardware counter
(`floor(global_symtime / 12333)`), independent of any `mark_fec`/`mark_demod` bit. This was
necessary -- the marker chain silently merged two frame windows into one whenever a single
regular marker was missed (§86-C's own reported anomaly: onset.bin "frame 131" held 18,510
captured samples, more than a single 12,333-symbol frame can hold). With tref-only windowing, the
frame count roughly doubled to what it should be (mid.bin: 1,849 tref-defined frames vs. 1,342
marker-merged windows before the fix; onset.bin: 1,835 vs. 1,361), and every merged window from
the previous pass has now split into its true constituent frames. The marker chain is retained
only as a diagnostic cross-check (`marker_found_near_frame_boundary`), never to define a window.

**Consequence: the stalls the previous pass reported as one adjacent PAIR per event are now three
consecutive tref-defined frames per event** (mid.bin: frames 441-442-443 and 1470-1471; onset.bin:
frames 172-173-174 and 1218-1219) -- longer and more structured than the earlier, marker-merged
picture showed.

### Per-stall table (all 10 stalled frames found, both files; tref axis, `RUNG_TOL = +/-4` symbols)

| file | frame | length (symbols) | start (raw tref) | start (data-rel, tref-13) | end (tref) | ends at frame end? | best-fit rung | length delta | start delta (raw) | fits (len/start)? |
|---|---|---|---|---|---|---|---|---|---|---|
| mid | 441 | 4,866 | 5,951 | 5,938 | 12,259 | no | 6176 (k=0) | -1,310 | -193 | NO / NO |
| mid | 442 | 9,217 | 78 | 65 | 12,273 | no | 6548 (k=6) | +2,669 | -5,694 | NO / NO |
| mid | 443 | 4,439 | 0 | -13 | 12,259 | no | 6176 (k=0) | -1,737 | -6,144 | NO / NO |
| mid | 1470 | 4,410 | 6,374 | 6,361 | 12,259 | no | 6176 (k=0) | -1,766 | +230 | NO / NO |
| mid | 1471 | 9,356 | 0 | -13 | 12,259 | no | 6548 (k=6) | +2,808 | -5,772 | NO / NO |
| onset | 172 | 4,714 | 6,012 | 5,999 | 12,189 | no | 6176 (k=0) | -1,462 | -132 | NO / NO |
| onset | 173 | 9,223 | 16 | 3 | 12,259 | no | 6548 (k=6) | +2,675 | -5,756 | NO / NO |
| onset | 174 | 9,228 | 0 | -13 | 12,259 | no | 6548 (k=6) | +2,680 | -5,772 | NO / NO |
| onset | 1218 | 4,526 | 6,305 | 6,292 | 12,332 | **yes** | 6176 (k=0) | -1,650 | +161 | NO / NO |
| onset | 1219 | 9,352 | 0 | -13 | 12,296 | no | 6548 (k=6) | +2,804 | -5,772 | NO / NO |

**Stated plainly, per the coordinator's request: none of the 10 stalled frames fits the
pre-registered rung geometry within +/-4 symbols, on either length or start position, in either
the raw-tref or the preamble-corrected (data-relative) convention.** The FIRST frame of each
three-frame event (441, 1470, 172, 1218) has a start position within ~130-230 symbols of the
k=0 (rung 6176) prediction -- the right general region, an order of magnitude closer than any
other rung -- but 30-58x outside the +/-4-symbol tolerance. Its length (4,410-4,866 symbols) is
1,300-1,770 symbols SHORTER than rung 6176 and does not fit any rung. Only one frame
(onset.bin 1218) has its run reach the true frame end (tref=12,332, within the 10-symbol
tolerance used by `stall_end_coincides_with_frame_end`); the other 9 stop 40-140 symbols short of
frame end. Every SECOND (and third, where present) frame in each event starts at or near
tref=0 -- i.e. the constant-value condition is present again from the very start of the following
frame(s), through most of it (9,217-9,356 symbols), not recovering to normal payload until near
that frame's own end either.

**Reading:** this is not the single-frame, single-rung pop-abort-and-clean-recovery signature
pre-registered. It is a longer, multi-frame event: roughly 4,400-4,900 symbols of constant output
late in one frame, immediately followed by 9,200-9,400 more constant-output symbols spanning
nearly the whole of the next frame (and, in two of four events, continuing into a third). Total
span per event is on the order of 13,000-19,000 symbols -- longer than one full 12,333-symbol
frame -- which the single-abort, single-rung model does not cover. Whether this reflects a
different (more severe, possibly compounding) fault mode than the single isolated departures
studied on sel6, or a limitation of this scoring (e.g. drops distorting the true run boundaries,
or genuine multiple aborts within the same burst window), is **not resolved here** and is stated
as an open question, not answered.

### Continuation-content check (Addendum 1's prescribed test, L=512 symbols)

For every stalled frame, `frame[N+1].payload[0:512]` was compared against a nearby COMPLETE
(near-full-sample, non-stalled) reference frame's payload under two hypotheses: SHIFTED
(`reference.payload[stall_start : stall_start+512]`, the RAM-pointer-resumed-where-it-froze
prediction) and NO-SHIFT (`reference.payload[0:512]`, the no-delay negative control). Only
tref-offsets present in both compared series (drops) were counted.

| file | frame | n compared (shift) | match frac (shift) | n compared (no-shift) | match frac (no-shift) | pass (>=0.95 shift)? |
|---|---|---|---|---|---|---|
| mid | 441 | 300 | 0.0100 | 434 | 0.0161 | NO |
| mid | 442 | 452 | 0.0155 | 452 | 0.0133 | NO |
| mid | 443 | 377 | 0.0053 | 377 | 0.0053 | NO |
| mid | 1470 | 320 | 0.0125 | 249 | 0.0080 | NO |
| mid | 1471 | 242 | 0.0124 | 242 | 0.0124 | NO |
| onset | 172 | 496 | 0.0121 | 482 | 0.0124 | NO |
| onset | 173 | 432 | 0.0116 | 432 | 0.0093 | NO |
| onset | 174 | 347 | 0.0115 | 347 | 0.0115 | NO |
| onset | 1218 | 350 | 0.0171 | 211 | 0.0190 | NO |
| onset | 1219 | 358 | 0.0084 | 358 | 0.0084 | NO |

**Both hypotheses fail on every stall, at match rates (~0.5-1.9%) statistically indistinguishable
from chance** (1/39 ~= 2.6% expected under pure chance against the capture's own 39-value sample
alphabet -- see §86-C's Tier-2 recalibration note). Neither the shifted-resume model nor the
no-delay model explains the measured post-stall content on this test. The check's own machinery
was independently verified correct on synthetic data before this run (a genuine shifted-resume
synthetic scores shift=1.0/no-shift=0.0; a genuine no-delay synthetic scores the reverse -- both
exactly as expected), so this is a real negative result on real data, not an implementation
artifact of the check itself. Candidate (untested) explanations for the failure, offered as
open questions: the reference frame chosen (nearest earlier complete frame) may not in fact be
bit-identical to frame N's true content at this position (contradicting the sec82 frame-identity
assumption this check depends on); there may be an additional timing offset beyond the simple
symbol-count shift tested; or drops within the compared spans (300-496 of the requested 512
symbols were actually present in each comparison) may be corrupting the alignment.

### Constellation reading of the frozen value

Every stalled frame's frozen (I,Q) value sits at full constellation magnitude (~8,112-8,113,
matching the capture's own observed maximum, ~8,307) at one of two diagonally opposite QPSK
points: `(5736, 5736)` (I+,Q+, ~45 deg) on 9 of the 10 stalled frames (both mid.bin events, and
onset.bin frames 172-174), and `(-5737, -5737)` (I-,Q-, ~225 deg) on the remaining 1
(onset.bin frames 1218-1219) **[measured]**. Both are valid full-amplitude QPSK constellation
points (the modulation's constant modulus means every valid symbol has the same magnitude, so
seeing exactly two -- diagonally opposite -- of the four possible points is not itself unusual
under either hypothesis). No bit-to-constellation-point (Gray code or otherwise) mapping is
established anywhere in this codebase, so which logical bit pattern either point represents is
**not determined here**. That two different points were observed (not one fixed sentinel value
repeated every time) is weak evidence, offered as **[inferred]**, against a single fixed
idle/preset symbol and weak evidence for a data-dependent frozen value (consistent with "the RAM
bit under the frozen read pointer," which would vary depending on what was there) -- but the
sample size (2 distinct values across 4 independent stall events) does not rule out a small,
fixed 2-value idle pattern either; this is not resolved.

### Verdict for P-TX'

**NOT CONFIRMED.** Per the coordinator's stated criterion (CONFIRMED requires stall geometry to
fit the rung set within tolerance AND the continuation check to pass), **both parts fail**:
- **Geometry:** fails on all 10 stalled frames -- no stall's length or start position matches any
  RUNGS value within +/-4 symbols, in either axis convention.
- **Continuation:** fails on all 10 stalled frames -- neither the shifted-resume nor the no-shift
  hypothesis explains the measured post-stall payload; match rates are at chance level for both.

What DOES stand, from this and the original §86-C pass: the stall phenomenon itself (long runs of
bit-identical, full-magnitude, non-chance TX sample output, now measured against correctly-defined
tref frame boundaries) is real and controlled (positive/negative controls both PASS on both
files, independently re-verified after the windowing fix). Its structure -- ~4,400-4,900 symbols
late in one frame followed by ~9,200-9,400 more spanning nearly all of the next -- is a genuine,
reproducible (4 independent events across 2 files) silicon observation, but it is quantitatively a
**different, larger event than the single-frame, single-rung pop-abort model pre-registered**, not
a confirmation of that specific mechanism as scored.

**Provenance:** all frame counts, stall lengths/positions/values, geometry deltas, and continuation
match fractions in this addendum are **[silicon]**, same arm as §86-C (`beatcap2-sel8-212830`,
2026-09-02 21:28-21:33), re-scored only (no new board contact). The RTL claims underlying P-TX'
(`Data_Bits_FIFO.v`, `RAM_Frame_Status_Indicator.v`) remain **[inferred, cited from
`TX_ORIGIN_TRACE_A.md`]**, unchanged from §86-C above.

## §87 The beat is a TRANSMIT STALL: every offset transition at the demod input is a constant-symbol run whose length equals the offset change [silicon] (controller, 2026-09-02 22:15)
Script: `two_jup/sel6_stall_geometry.py` (per capture → `beatcap/20260902_185552_sel6/{onset,mid}_stalls.json`). Method: hard-decision symbol stream at sel6, every run of one constant symbol longer than 50 (normal max run is 7–8); offsets per frame from `per_frame_offsets` (the §57/§69 injective map, frame-identity limit applies: offsets modulo 12,320).

**Every data-offset transition in both sel6 windows coincides with a stall run, and the run length predicts the new offset as `new = old − L (mod 12320)` to within ≤ 10 symbols** (the residual is the demod-mark-to-frame-start skew). No transition occurs without a stall; no stall occurs without a transition. [silicon]

| window | frame | pos in frame | L (sym) | full-frame stall follows? | offset before → after | predicted after | error |
|---|---|---|---|---|---|---|---|
| onset | 831 | 6069 | 6250 | yes (12310) | 6240 → 0 | 12310 (≡ −10) | 10 |
| onset | 1896 | 6362 | 5958 | no | 0 → 6363 | 6362 | 1 |
| onset | 3126 | 5955 | 6364 | yes (12319) | 6363 → 0 | 12319 | 1 |
| onset | 4166 | 6489 | 5830 | no | 0 → "None" | 6490 (rung 6489) | — |
| onset | 5420 | 5825 | 6494 | yes (12315) | "None" → 0 | — | — |
| mid | 1013 | 6431 | 5890 | no | 0 → 6432 | 6430 | 2 |
| mid | 2255 | 5883 | 6437 | yes (12317) | 6432 → 0 | 12315 | 5 |
| mid | 3278 | 6547 | 5772 | no | 0 → "None" | 6548 (rung 6548) | — |
| mid | 4544 | 5764 | 6556 | yes (12313) | "None" → 0 | — | — |

Reading [silicon + RTL, see TX_ORIGIN_TRACE_A.md §0/§6]: the transmitter's `Data_Bits_FIFO` stops popping mid-frame (position 5760–6550 symbols ≈ half a frame + 0..390), the modulator holds ONE constellation point (hard symbol 0 or 3 — the same two values Track C sees at the modulator output, sel8: (5736,5736)/(−5737,−5737)) until the frame end, sometimes for one further whole frame, and the payload then resumes where it stopped: delayed by L. The rung set is simply the set of stall lengths (mod frame): 6176 + 64·k ⇔ abort 128·k pops earlier. The "0 → None" transitions are stalls too, with predicted offsets 6490 and 6548 (the two rungs whose burst words 0xBFED37AC / 0xD748FC96 §72 already reported as "not found in the map"); the None-state word is 0xBFED37AC in 1219/1220 frames, and it is NOT the ROM word at 6489/6548 under any bit shift ±3 or QPSK rotation (best Hamming distance 5/32) — so the resumed content in that state differs from a pure delay; open [silicon]. The "rung → None (one frame) → 0" triplets in the earlier transition list are the whole-frame stalls themselves (a constant frame maps to None).

What this closes: the receiver never moved anything — marker, tOff, interpolator, FIFO all held (§82–§85) because the input itself stalls and resumes. The "extra txFrameStart pulse" was the sticky FEC-mark latch recording during the stall (TX_ORIGIN_TRACE_A.md T0; sel8 §86-C found no restart). What remains: (i) the causal proof in sim (Track B: force the pop-enable latch clear at 12,288 − 128·k pops → rung 6176 + 64·k); (ii) why the abort fires every 120.2 s (RAM-occupancy drift / `frameCount` ufix2 wrap, TX_ORIGIN_TRACE_A.md #2/#3) — the rate question; (iii) the None-state content.

## §86-C addendum 2: sel6-style global (uncut) event geometry, per sec87's model [silicon]

Re-scores the SAME credited sel8 arm (`beatcap2-sel8-212830`, no new arm) after a second
coordinator-directed method change, following sec87's sel6 finding (`sel6_stall_geometry.py`,
commit `3e0a791`): every sel6 offset transition is one constant-symbol run from MID-FRAME to the
FRAME END, sometimes followed by whole additional stalled frames, with `new_offset = old - L
(mod 12320)`. Commits: this section's code fixes (`d3e9549`, `876ec4e`, `1850696`, `109fbff`,
`6c37134`), this commit (write-up + JSON).

**Method.** Per-symbol stream unchanged (one sample/symbol at the fixed slot==1 phase -- already
correct; the coordinator's initial suspicion that all 4 records/symbol were being used did not
apply to this codebase). What changed: constant-run search now runs on the FULL, UNCUT symbol-time
series (not pre-cut at every tref frame boundary), then each run's geometry (start frame/offset,
whether it reaches that first frame's end, how many whole subsequent frames it entirely covers,
where it ends) is computed after the fact. `L_first_frame_stall` = the run length restricted to
the first frame only, the quantity sec87's `new = old - L (mod 12320)` is defined against.

**Three bugs found and fixed in this pass, in order, each caught by re-running the same three
synthetic self-tests (P-TX confirm, P-TX falsify, P-TX' multi-frame stall) before touching real
data again:**
1. Positive control compared a SYMTIME SPAN (drop-inclusive) against a CAPTURED SAMPLE COUNT
   (drop-exclusive) -- different quantities whenever the injection window itself contains real
   drops, which real frame-0 data does. Fixed to compare span-to-span (`876ec4e`).
2. `find_all_constant_runs` had an off-by-one: it reported `(i, j+1)` as a run's `(start, end)`
   when `j+1` is actually the FIRST DIFFERING sample, not part of the run -- silently corrupting
   every run's end-of-run value. Caught by direct inspection: an end-of-run sample that should
   have been the frozen stall value `(5736,5736)` was instead a transition sample `(5557,5557)`,
   which explained why the merge step (below) was never bridging real adjacent fragments. Fixed
   to `(i, j)` (`109fbff`).
3. A single physical event was still being reported as several fragments separated by short gaps
   (a genuine DMA drop -- median 154-159 symbols per `ddrcap2_pc.py`'s `tref_cadence` stats, one
   inspected real gap measured 286 symbols -- and/or a brief, few-sample excursion to a different
   value before returning). Added `merge_nearby_same_value_runs`: consecutive same-value fragments
   separated by <= 300 symbols are merged into one event, with every bridged interruption recorded
   (not discarded) under the event's `interruptions` key (`876ec4e`->`6c37134`).

**Positive/negative controls: PASS on both files**, re-verified after every fix.

### Per-event table (4 total events, both files, after merging; RUNG_TOL = +/-16 symbols)

| file | event start (frame, tref-offset) | reaches frame end? | whole stalled frames after | event end (frame, tref-offset) | L (first-frame stall, symbols) | 12320-L | fits? | interruptions bridged |
|---|---|---|---|---|---|---|---|---|
| mid | (441, 5951) | **yes** | 1 | (443, 12258) | 6382 | 5938 | NO | 2 (153-sym drop; 286-sym drop w/ 14 off-axis transition samples) |
| mid | (1470, 6374) | **yes** | 0 | (1471, 12258) | 5959 | 6361 | **YES** (12320-L=6361 vs RUNGS 6363, delta -2; L=5959 vs sec87 sel6 L=5958, delta +1) | 1 (17-sym drop) |
| onset | (172, 6012) | **yes** | 1 | (174, 12258) | 6321 | 5999 | NO | 1 (27-sym drop) |
| onset | (1218, 6305) | **yes** | 0 | (1219, 12152) | 6028 | 6292 | **YES** (12320-L=6292 vs RUNGS 6299, delta -7) | 0 |

**Every one of the 4 events reaches its first frame's end (4/4)** -- sec87's core geometric
prediction (stall runs mid-frame to frame end) holds on every measured sel8 event, matching the
sel6 finding. Two of four events additionally show one WHOLE subsequent stalled frame before
recovering (matching sec87's "sometimes followed by one further whole frame"); the other two
recover partway into the very next frame.

**Rung fit: 2 of 4 events (50%)** have `L` or `12320-L` within +/-16 symbols of a value in either
the original RUNGS tuple or sec87's own sel6-measured `L` values: mid's second event (`L=5959`,
matching sec87's own sel6 `L=5958` almost exactly, delta +1) and onset's second event
(`12320-L=6292`, matching RUNGS `6299`, delta -7). The other two events (`L=6382` and `L=6321`)
do not fit within tolerance against either reference set (closest: mid's `6382` vs RUNGS `6363`,
delta 19; onset's `6321` vs `6299`, delta 22 -- both just outside +/-16).

**Marker (preamble) on cadence after the stall: 3 of 4 events (75%)** -- a `mark_fec` record was
found within +/-100 records of the tref==0 boundary of the frame immediately after each event
ended. The one exception (onset's second event, `-5737,-5737`) has no marker found at that
boundary; whether this reflects a genuinely missed marker (record drop) or something else is not
resolved here.

**Interruptions bridged (reported, not adjudicated):** 3 of 4 events required bridging a gap to
form one continuous event. Two were plain drop gaps (17 and 27 symbols, no differing value in
between -- i.e. `find_all_constant_runs` genuinely returned zero samples in that span, consistent
with a dropped span). One (mid's first event) required bridging TWO gaps: a 153-symbol drop, and
a 286-symbol gap containing 14 samples at an off-axis value, `(-5737, -5558)` -- close to but not
exactly the diagonal-opposite corner, consistent with genuine transition/settling samples rather
than a second stable lock. None of these interruptions is itself long enough to be scored as its
own stall event (all well under `MIN_STALL_SYMBOLS=300`).

### Constellation per event

All 4 events hold a full-magnitude QPSK point: `(5736,5736)` (I+,Q+, ~45 deg, magnitude ~8112) on
3 of 4 events (mid x2, onset's first), and `(-5737,-5737)` (I-,Q-, ~225 deg, magnitude ~8113) on
the remaining 1 (onset's second) -- unchanged from the previous addendum's finding, now measured
on correctly-merged, non-fragmented events. **[measured]** for magnitude/phase/quadrant; **[inferred]**
for "this is the RAM bit under the frozen read pointer" (no bit-to-constellation mapping is
established in this codebase, and only two distinct values across 4 events is too small a sample
to rule out a fixed 2-value idle pattern, as noted in the prior addendum).

### Verdict for P-TX'

**Per the coordinator's stated criterion** (CONFIRMED if stalls run to the frame end with L
consistent with the rung set, +/-16 symbols, AND the preamble arrives on cadence after the
stall): **NOT uniformly met across all 4 events, so the verdict is PARTIAL CONFIRMATION, stated
precisely rather than rounded to CONFIRMED or FALSIFIED:**
- **Reaches frame end: CONFIRMED, 4/4.** Every measured sel8 stall event runs from its mid-frame
  start to the end of that frame, matching sec87's core sel6-derived prediction exactly.
- **Rung-consistent L: PARTIAL, 2/4.** Two events' lengths land within +/-16 symbols of the rung
  set (one matching sec87's own sel6 `L` value almost exactly); two do not (closest misses:
  19 and 22 symbols, just outside tolerance).
- **Preamble on cadence: PARTIAL, 3/4.** Three of four events are followed by a marker landing on
  the expected cadence; one is not.

This is substantially stronger, cleaner evidence for the pop-abort-stall mechanism (P-TX') than
either prior addendum found -- every event's frame-end geometry now matches sec87's sel6 finding
exactly, where the earlier (buggy) passes found none of the sel6-predicted structure at all. It
falls short of a full CONFIRMED verdict only because two of the four measured events' lengths do
not land within the stated tolerance of a known rung, and one of four is not followed by an
on-cadence marker. Whether the two non-fitting events represent a different (or compounded) rung,
a still-uncorrected measurement artifact (e.g. residual drop-gap merging imprecision -- the
299-vs-300-symbol tolerance choice is itself somewhat ad hoc, chosen from a single observed real
gap), or a genuinely different phenomenon is **not resolved here** and is stated as an open
question.

**Provenance:** all event geometries, interruption records, and constellation values are
**[silicon]**, same arm as the original §86-C (`beatcap2-sel8-212830`, 2026-09-02 21:28-21:33),
re-scored only (no new board contact). sec87's sel6 geometry (`L` values, the `new = old - L (mod
12320)` relation) is **[silicon, cited from sec87 / `sel6_stall_geometry.py`]**, not re-derived
here. The RTL claims underlying P-TX' (`Data_Bits_FIFO.v`, `RAM_Frame_Status_Indicator.v`) remain
**[inferred, cited from `TX_ORIGIN_TRACE_A.md`]**, unchanged.

## §88 The "None" state IS the golden payload: I-channel bit-exact, Q-channel skewed +1 symbol [silicon] (controller, 2026-09-02 night)

Answers §87's open item: what the "None"-state content (post-stall, offset not in
`offsetmap/tap3_word_to_offset.tsv`) actually is. Script: `two_jup/none_state_analysis.py`
(inputs: `two_jup/beatcap/20260902_185552_sel6/{onset,mid}.bin`, unchanged §87 captures; output
`two_jup/beatcap/20260902_185552_sel6/none_state_result.json`). Full method, evidence, and the
per-test breakdown: `two_jup/NONE_STATE_D.md`. No board contact this pass.

**Finding:** the None-state frame is the correct golden ROM payload, resumed exactly at the
offset §87 predicts (6490 for onset.bin frame 4166's stall, 6548 for mid.bin frame 3278's), with
the I-channel hard decisions a bit-exact match (100.0%) to golden at that offset -- but the
Q-channel hard decisions are a bit-exact match (100.0%) to golden's Q **one symbol later**, not
at the same symbol time as I. A fixed +1-symbol I/Q channel skew, not garbage/noise/a different
ROM region. **[silicon]**, independently measured and identical in both onset.bin and mid.bin.

Chain of evidence (full detail in `NONE_STATE_D.md`): (1) whole-frame cyclic bit correlation
(FFT, 16 pairing/rotation/conjugation variants, all 24,640 shifts) against a golden quiet frame
of the same capture peaks at the predicted even shift with only ~75.5% bit agreement (z~79,
nowhere near chance, but well short of the ~100% a clean rung transition gives -- both positive
controls, golden-vs-golden and rung-vs-golden, hit 100.0% at 0 / the predicted shift exactly);
(2) splitting that best alignment into I-plane and Q-plane and re-searching a small per-symbol
skew per plane finds I locked at skew 0 (100.0%) and Q locked at skew +1 symbol (100.0%), in both
files; (3) the None-state content is bit-exact periodic within its own episode (Hamming 0
frame-to-frame) and bit-exact identical between the two independently-triggered captures at a
shift consistent with their ~58-symbol offset difference -- ruling out a coincidental partial
match; (4) stall geometry re-confirmed directly from §87's own JSON: `L=5830`/`5772` exactly as
reported, no whole-frame stall immediately precedes either None-triggering stall (>1000 normal
frames intervene since the prior stall event), and None-state content begins exactly 1 symbol
before the frame end in both files.

This explains the two loose ends §87 left open: the 16-symbol demod-mark word matches no map
entry because the map assumes I[n]/Q[n] paired at the same symbol time, and a per-symbol I/Q skew
(unlike a whole-frame delay) is not a cyclic shift of the paired-word stream at any offset; and
the "looks like normal data, 25% each" symbol statistics follow directly from I being real data
and Q being read one symbol off from it.

**Not resolved here [inferred]:** why only these two of the nine measured §87/§86-C transitions
produce an I/Q skew while every other transition (rung-to-rung, rung-to-zero) resumes correctly
paired; and whether the skew originates in the TX FIFO/mux or in the sel6 tap's own I/Q demux --
sel6 is downstream of both and cannot distinguish them on its own. Both flagged as open questions
in `NONE_STATE_D.md`, not investigated further this pass (host-only scope, no board contact).

## §89 Synthesis: the 120.2 s beat is a transmit-side pop stall in `Data_Bits_FIFO` (controller, 2026-09-02 23:00; to be amended with the sweep / rate results)
**Claim: the error source is the transmitter's bit packetizer, not the receiver.** Chain of evidence, each link labelled:
1. [silicon, §82–§85] Every receiver witness holds through the burst: Peak_Search timingOffset, demod-marker cadence, interpolator mean phase increment, Rate_Handle FIFO occupancy. The displacement is already present in the interpolated sample stream (sel14).
2. [silicon, §87] At the demod input every offset transition is a run of ONE constant hard symbol from mid-frame (5760–6550 symbols in) to the frame end, sometimes plus one whole stalled frame; afterwards `new_offset = old − L (mod 12320)` within ≤10 symbols on every transition (errors 10/1/1/2/5). No transition without a stall, no stall without a transition.
3. [silicon, §86-C] The same constant constellation point ((5736,5736) or (−5737,−5737)) is held at the modulator OUTPUT (sel8) in 4/4 events, each running to the frame end, the preamble arriving on cadence afterwards.
4. [silicon, §88] The two "None" states are the golden payload at exactly the predicted offsets (6490, 6548) with Q one symbol late relative to I — a stall of an odd number of bit-slots [inferred] — so all 9 transitions obey the stall model.
5. [RTL, TX_ORIGIN_TRACE_A.md] `Data_Bits_FIFO.v:270-291`: the pop-enable latch is cleared on any `enb_1_2_0` tick with `frameCount==0`; `frameCount` is an unguarded ufix2 (`RAM_Frame_Status_Indicator.v:70-75`) that can wrap 3→0. Pops stop, the RAM read pointer freezes, the modulator repeats one bit, `sampleCount`/`dataStart`/preamble/markers are untouched.
6. [sim, TX_KICK_SIM_B.md] Clearing that latch once at `sampleCount` 12,314 in the flat netlist reproduces the whole signature: single-frame jump to a bit-exact offset (6144 ≡ −6176 = the stall length to frame end), sustained, marker cadence constant, positive control clean. Every receiver-side kick of §76 had only corrupted data.
7. [sim, TX_KICK_SIM_B.md T0] Exactly one `txFrameStart` per frame — the "extra pulse" of the final review was the sticky FEC-mark latch recording during the stall, not a TX event. RAM occupancy drifts +26 bits/frame (frame image 24,666 slots pushed, 24,640 data bits popped; 26 = preamble slots): the RAM-full threshold is reached 3.04 s after the post-arm level, matching the ~3 s duration of each displaced state.

**What is still open (in flight):** the k-sweep (does the landing offset move 64 symbols per 128-pop step), the `frameCount` 3→0 wrap arriving on its own, and the 120.2 s recurrence (phase-coincidence hypothesis: producer/consumer frame-boundary phase advances 26 slots/frame, recurrence 12,333 frames = 39.61 s; ×3 = 118.8 s vs 120.2 s observed — unverified). The ByteWordBuffer starvation defect of 08-28 is a different, host-path defect and is out of circuit in mode-1 ROM playback.

**Fix direction (not implemented — root cause first):** make the pop-enable clear conditional on the frame boundary (or guard `frameCount` against wrap / saturate it), and stop the producer from over-pushing preamble slots (+26/frame) so the RAM cannot walk into the abort condition. Any fix build goes through the full flash rails on 148 only, after a sim gate that reproduces §86-B's k=0 case on the unfixed netlist and shows it absent on the fixed one.

### §89 addendum (controller, 23:25): the sweep reproduces the whole rung family [sim]
`kick_seq.py` on `beat_runs/txkick_pa_k{0..6}.bin` (force at 12,288 − 128·k pops, frame 6): sustained landing offsets 6144, 6080, 6016, 5952, 5888, 5824, 5760 for k = 0..6 — exactly 64 symbols per 128-pop step, i.e. stall lengths 6176 + 64·k to the frame end, bit-exact, single-frame, no self-heal in 40 frames. That is the silicon rung set (6176, 6240, 6299, 6363, 6432, 6489, 6548 ≈ 6176 + 64·k within the demod-mark skew) generated on demand. `frcwrap` (frameCount forced to 3, no clear) and `dstart` (one forced extra dataStart pulse, 49 pulses in 47 frames) both stay at offset 0 with baseline bit errors — NO EFFECT: the wrap does not occur by itself within 20 frames, and an extra frame-start pulse alone moves nothing.

## §90 The natural trigger of the pop-abort: an unguarded ufix2 ratcheted by a +26 slot/frame push surplus — and a second, separate defect (`fullRAM` runs away) [RTL + sim] (TX_RATE_E, host-only, no board contact)
Full report: `two_jup/TX_RATE_E.md`. Sources `jupiter_240k5_byte/rtl_sim/txrate_probe.cpp`,
`build_txrate_sim.sh`, `build_txrate_sim3.sh`; outputs `jupiter_240k5_byte/rtl_sim/beat_runs/txrate_*`.

**Trigger [RTL fact + sim].** The producer pushes **24,666** bits per air frame (the `dataReady`
toggle gives 50 % duty over the 49,332 `enb_1_2_0` ticks of a frame, `Bit_Packetizer.v:144-178`;
push = `txValid` = `Message_Generator.valid` = its `enable`, `Input_Data.v:143`,
`Transmitter.v:103-122`) but only **24,640** are popped (`Data_Bits_FIFO.v:222,291`). Measured
directly (`beat_runs/txrate_cen6_frames.txt`): `pushes=24666 pops=24640` every frame, occupancy
+26/frame, the push-wrap position inside the frame moving **−26 bit slots per frame** while the
pop-wrap sits fixed at the frame start. `pushCount` therefore wraps 24,666/24,640 times per frame
and `popCount` exactly once, so **every 24,640/26 = 947.69 frames there is one extra push-wrap**
and the baseline of the unguarded ufix2 `frameCount` (`RAM_Frame_Status_Indicator.v:43,66-92`)
ratchets 1 → 2 → 3 → 0. **When the baseline reaches 3 the next push-wrap makes `frameCount` read
0 mid-frame** and `Data_Bits_FIFO.v:270-289` (clear evaluated on every tick, reload gated on
`sampleCount==0`) drops the pop-enable latch. A second route also fires: with the baseline at 1,
the *pop*-wrap decrements 1→0.

**Rate [computed, and it does NOT match].** Frame = 197,328 clk / 61.44 MHz = **3.21172 ms**
(`TX_ORIGIN_TRACE_A.md` §3's 802.93 µs is 4× too small; every period derived from it there,
including §89's "12,333 frames = 39.61 s", is wrong). One base increment = 947.69 frames =
**3.044 s**; first `frameCount==0` after arm (base 1→3) = 1,895.4 frames = **6.09 s**; full mod-4
return = **12.17 s**. Silicon's ~110 s first burst and 120.2 s recurrence are **18.1× and 39.5×
slower** — the free-running drift model is FALSIFIED as the *rate* mechanism, while the *trigger*
mechanism is confirmed. Residuals (not explanations): 120.2/3.044 = 39.49, 120.2/12.17 = 9.87,
110/6.09 = 18.07. An effective drift of 0.658 slots/frame instead of 26 would give 120.2 s.

**Sim demonstration [sim, PASS].** `beat_runs/txrate_fc3_frames.txt`: at frame 40, ONE write in
the low window (`frameCount 1 -> 3`, guarded — the run aborts if the pre-value is not 1), then
nothing. 78,398 clk later, at a genuine unforced push-wrap, `frameCount` 3→0
(`via=PUSHWRAP_3to0`), `armed` 1→0, pop strobe quiet for 103,032 clk = 1.04 frames; a second
`via=POPWRAP_1to0` abort follows one frame later. Negative control `beat_runs/txrate_fc2_frames.txt`
(same instant, single write `1 -> 2`): `zeroEvents=0`, `armed` never leaves 1 in 53 frames.
`beat_runs/txrate_ph4_frames.txt` reaches the same zero touching ONLY `FSI.pushCount` (two
single-tick extra push-wraps, no `frameCount` write). `kick_seq.py`: `fcbase3` shows offset
**11787** at frame 40 and 0 elsewhere; `fcbase2` shows 0 everywhere.

**New finding — the displacement self-cancels [sim].** Unlike the artificial single-clear kick of
`TX_KICK_SIM_B.md`, the *natural* abort is followed one frame later by a `POPWRAP_1to0` abort that
exactly completes the frame the first one interrupted; the measured total pop deficit was
1,065 + 24,640 + 23,574 + 1 = **49,280 = two whole frames**, i.e. displacement ≡ 0 (mod 12,320).
This falsifies the free-running drift as the mechanism for the **sustained rung state** too, not
just for the rate: `TX_KICK_SIM_B.md`'s permanent rung came from a single artificial clear with no
natural analogue found here. A sustained rung would require the follow-on abort to be suppressed
(a second push-wrap inside the stall); the only candidate, the `fullRAM` runaway below, **failed
its first test in this run** — frame 41 had `fullRAM=1`, `pushes=26822`, yet `pushWraps` advanced
only +1/frame (41→42→43) and the second abort fired anyway. **No mechanism producing a sustained
rung is identified in this pass.**

**Second, separate defect — `fullRAM` back-pressure runs away [RTL + sim, new].**
`beat_runs/txrate_nf_frames.txt`: when occupancy crosses 49,279 the `Bit_Packetizer` pace toggle
freezes at **1** (`Bit_Packetizer.v:161` holds on `fullRAM`), so `dataReady` sticks HIGH and the
producer pushes on **every** tick — measured `pushes=40898` in one frame vs 24,666 (16,232 extra,
predicted 16,239) — until the **uint16 `MATLAB_Function1.count` wraps at 65,536**
(`MATLAB_Function1.v:57-67`), `full` deasserts and 50 % pacing resumes with 16,256 bits of RAM
over-written. This also explains the unexplained push-wrap position jump (98,146 → 49,026 clk) in
`beat_runs/txkick_nf_v0_frames.txt`. There is no working back-pressure in this design.

**Odd-length stalls and whole-frame stalls [RTL + inferred].** The delay equals the missed-pop
count D in *bit* slots; two bits make one QPSK symbol, so odd D re-pairs the stream — I bit-exact,
Q one symbol late: §88. D's parity is set by which `enb_1_2_0` phase the (ungated) clear lands on
[RTL fact]; **what sets that phase is not established** — the one natural abort measured gave an
even D (49,280) and a mapped, unskewed offset, and no parity-flipping mechanism is identified.
Whole-frame
stalls: with pops stopped `popCount` cannot wrap, so `frameCount` stays 0 across the frame
boundary and the reload at `sampleCount==0` loads 0 again (`Data_Bits_FIFO.v:284-287`) — the whole
next frame stalls, escaping only at the next push-wrap. Confirmed in `txrate_fc3` (frame 41:
`pops=0`); what produces silicon's 5-of-9 cases *without* a whole extra frame is open.

**Fix direction (unchanged, now with a second item):** saturate or widen `frameCount` and gate the
`armed` clear on the frame boundary; **and** fix the `fullRAM` path so it actually stalls the
producer (freeze `dataReady` LOW, or guard the push) and make the occupancy counter non-wrapping.
