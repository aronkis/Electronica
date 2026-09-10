> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_HOSTFIX_PREREG.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX host-fix pre-registration — the RX carve re-anchor (Task 26)

**Registered before any deploy. No board was touched to write this file.**
Written 2026-09-05 by RXFIX Task 26 (desk). The change under test is host-side
only: `host_app_k5/qpsk_frame.[ch]` (a pure scanner) and `host_app_k5/qpsk_tun.c`
(the queued-RX drain cursor). **Nothing in the fabric changes**; the bitstream on
148 stays `9f13705d9fb0` (W1 + R4B).

---

## 1. What is being tested

Task 23 named the forward residual: a **byte-alignment cascade in the receive
delivery path**. One decode error at the decoder pins costs the host 8.59 frames
instead of ~2, because the frames after it arrive at a fixed **568-byte phase**
inside the host's carve slice and stay there until the next DMA transfer
re-anchors on a frame-sync tuser (`two_jup/comb/FWD_RESIDUAL_0p22.md`).

Task 26's fix makes the drain cursor a **byte offset** into the DMA area instead
of a slot index, and on a parse failure scans forward — over the contiguous
carve, not inside one slice — for the next offset at which a whole frame
validates (magic + len + CRC32). See `two_jup/sdd_archive/2026-09-04-rxfix/task-26-report.md`
for the geometry and the design.

**Binary under test.** Built locally from the Task 26 sources with
`deploy_daemon_go.sh`'s line, NAKKEEP resolved:

```
gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_ARQ_NAKSTAT -DQPSK_RXQ_STAT \
    -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c
strings qpsk_tun | grep -c nakstat   -> 4   (the 148 deploy gate)
strings qpsk_tun | grep -c rxqstat   -> 1
md5(qpsk_tun) = 023d7bfd6db5706e37465ea0ce7bd967        x86-64, 97,768 B
```

That md5 is the **local x86-64 build fingerprint of these exact sources and
flags**, *not* a deploy fingerprint: `deploy_daemon_go.sh` compiles on the board
and will produce a different (aarch64) md5. Compare sources and flags, never the
two md5s.

**Judge leg.** `deploy_daemon_go.sh BOARD=148` then `w1leg_go.sh MODE=air LEG=A`
(forward, 146 → 148), the same shape as `runs/20260904_201814_w1_air`, with
`QPSK_RXQ_ZEROHDR` **off** (its default — under zerohdr only 8 B per slot are
pre-zeroed, which leaves stale frames from an earlier lap in the carve at
displaced phases and could in principle admit a false re-anchor).

---

## 2. Predictions (registered before the leg)

| # | quantity | prediction | where it is read |
|---|---|---|---|
| P1 | forward PER, live window | **≤ 0.08 %** (from 0.2244 %) | `accept_analyze.py` on `cap/frames.bin` |
| P2 | loss **events** per second | **unchanged, ~0.30 /s** | `comb_census.py` / `--burst-times` |
| P3 | slots per event | **8.59 → ~3** | 1,956/213 today |
| P4 | `resync_568` | **≈ the event count** (~0.30 /s, ~140 in a 460 s window) | `qpsk_tun rxresync:` line in `cap/qpsk_tun.log` |
| P5 | `recovered` | **≈ 5.5 × `resync_568`** | same line |
| P6 | `resync_other` | **≪ `resync_568`** (the 376 and 1136 populations only, ~3 %) | same line |
| P7 | checker gap events | **unchanged, ~3 per 10 s** | `chk.jsonl` |
| P8 | checker lost slots | **unchanged, ~0.054 %** | `chk.jsonl` |
| P9 | r4b witnesses (`d_r4b_skips`/`d_frames`) | **unchanged, ~0.0314** | `w1_reads.csv` |
| P10 | run-length ceiling | **17 → ~3** (the 5–20 bin drains) | `--burst-times` |
| P11 | `rx_q_resets` | **0** (no watchdog re-arm) | `qpsk_tun rxqstat:` line |
| P12 | `resync_fail` : `resync_568` | **either ~2:1 or ~0:1** — see below; both pass, and which one it is settles the burst-head model | `qpsk_tun rxresync:` line |
| P13 | failure **records** per event | **drops faster than lost slots** (~7.6 -> ~1-2) — see below; not a broken instrument | `failhdr.bin` / `comb_census.py` |

P7–P9 are the **control arm**: the fix is downstream of the decoder pins, so if
any fabric-side witness moves, the leg is contaminated and P1 must not be read.

### P12 — the row that tests the burst-head model

The 0.0764 % floor assumes the re-anchor fires at burst **position 2**, after
two failed scans on positions 0 and 1 (the two frames Task 23 shows are already
destroyed at the pins). The banked data cannot actually distinguish that from
the re-anchor firing at position **0**: `magic_off` records only the *first*
magic in a slice, so position 0 reporting `magic_off = 0` in 99.4 % of bursts
does **not** rule out a second magic at 568 in that same slice — which is
exactly what a pure 960-byte deletion predicts.

Both pictures give the same PER, because the checker's 293 bad slots per event
*at the pins* is independent evidence and pins the floor either way. They differ
only in the internals, and `resync_fail` separates them for free:

* **`resync_fail` ≈ 2 × `resync_568`** → the burst-head model holds: two failed
  scans, then a hit at position 2.
* **`resync_fail` ≈ 0** → the re-anchor fires at position 0; the two head frames
  are lost as delivered-garbage rather than as scan failures.

Neither outcome falsifies the fix. Not registering the row means the two cannot
be told apart afterwards. Note that Task 23's position 1 — "no frame magic
anywhere" in 151 of 159 bursts — is **not** explained by a pure deletion either
way, so the burst-head model is genuinely incomplete here and this is the cheap
measurement that says which way it is wrong.

### P13 — the failure-record census changes shape, and that is not a regression

Today ~7.6 `failhdr` records are written per event against 8.59 lost slots
(0.89 records per lost slot). After the fix the re-anchor **skips** slices that
used to be read and recorded, and the tail `break` records nothing at all, so
expect ~1–2 records against ~3 lost slots (~0.4 per slot). PER is measured from
`host_seq` gaps and is unaffected, but `comb_census.py`'s class census and the
`n_have` / `n_none` onset histogram **will** shift shape. That is the fix
working, not the instrument breaking. Compare PER and the `rxresync:` counters;
do not compare raw class-1 counts across the two builds.

### The arithmetic behind P1 — and a caveat the controller should see

Task 23's 460 s common window: 1,229 host-lost slots on 143 events, split
(FWD_RESIDUAL_0p22.md Q3) as

| | slots | per event | recoverable by a host resync? |
|---|---|---|---|
| already bad at the decoder pins (129 CRC + 164 garbage) | 293 | 2.05 | **no** — unparseable before the host sees them |
| magic-bad created between the pins and the host buffer | 791 | 5.53 | **yes** — these are the displaced-but-intact frames |
| no host record at all | 145 | 1.01 | **no** — the frame straddling the transfer boundary |

So the floor a perfect host-side resync can reach is `293 + 145 = 438` slots:

```
438 / 572,901 slots = 0.0764 %
```

**The prediction is 0.076 %, against a registered bound of 0.08 % — about 5 %
of headroom.** That is thin, and it is thin for a real reason: the brief's
"cost per event → ~1 frame" is optimistic. Two frames per event are destroyed
at or upstream of the decoder pins (that *is* the checker's 0.0540 %) and one
more straddles the DMA transfer boundary; no host-side change can recover any
of the three. If the fix recovers 90 % rather than ~100 % of the 791, PER lands
at 0.0902 % and **P1 fails while the fix is working correctly**. Read P1
together with P4/P5, which measure the mechanism directly and do not depend on
the margin.

---

## 3. Falsifiers

**F1 — the brief's falsifier (the fix does not recover).**
`resync_568` counts at ~the event rate but PER stays at ~0.22 % and `recovered`
is ~0. → The displaced frames are **corrupted, not merely shifted**; the
byte-alignment reading is wrong about their content and the residual is a
content defect. REPORT, do not iterate.

**F2 — the fix recovers but PER lands in 0.08–0.10 %.**
`resync_568` ≈ events, `recovered` ≈ 5.5 × `resync_568`, PER falls from 0.224 %
to 0.08–0.10 %. → The **mechanism is confirmed and the bound is wrong**, not the
fix: the residual is at the 0.076 % floor plus whatever the recovery misses.
This is the outcome §2's caveat says is plausible. Report as PARTIAL: mechanism
confirmed, registered bound missed, remaining loss is at/upstream of the pins.

**F3 — the fix makes it worse.**
PER rises, or `rx_q_resets` > 0, or `crc_drop` rises without `resync_568`
rising. → A stale cursor phase is leaking across transfers (the highest-risk
bug in the change: `rx_dphase` must be cleared in both `rx_q_on_complete` and
`rx_arm_queued`; `test_rxresync` 2d pins both). Set `QPSK_RX_RESYNC=0` — the
same binary then behaves byte-for-byte as before — and report.

**F4 — a fabric witness moves.**
P7, P8 or P9 changes by more than its run-to-run spread. → The leg is not a
clean A/B; the fix is host-side and cannot touch them. Discard P1 and re-run.

**F5 — `resync_other` ≳ `resync_568`.**
→ The 568 phase is not the dominant displacement on this leg, contradicting the
1,259-of-1,305 measurement. Re-open the class before crediting the fix.

---

## 4. The same-binary control

`QPSK_RX_RESYNC=0` disables the re-anchor from the **same binary**: the cursor
can then never leave phase 0 and every carve address is the historical
`rx_dscan * pkt_bytes`. A paired A/B on one deploy (resync ON leg, resync OFF
leg) is therefore available and is the strongest form of this judge if the rig
has time for two legs. `test_rxresync` 2b/2e pin that the OFF path reproduces
the historical accounting exactly.

---

## 5. What is NOT claimed

* Nothing here was measured on a board. The 40 checks in
  `host_app_k5/test_rxresync.c` are synthetic and model **one** deletion of
  960 B; on silicon two frames per event are already destroyed before the
  parser sees them, which is why the synthetic result ("1 lost, not 11") and
  the silicon prediction ("~3 lost, not 8.59") are different numbers for the
  same fix.
* The fabric-side cause of the 960-byte deletion (or 568-byte insertion) is
  **not** addressed and not claimed to be. This fix caps the *cost* of the
  event at what the decoder pins already lose; it does not reduce the event
  rate, and P2 registers that explicitly.
* The 8.140 s rate modulation is untouched and unexplained.
* Recovered frames are decoded from the scanner's window copy and therefore
  **bypass `rx_raw_tap`**. Irrelevant to a tun-mode judge leg, but a future
  `-S` raw-scorer leg would miss every recovered frame and get a silently wrong
  denominator. Run an `-S` leg with `QPSK_RX_RESYNC=0`, or wire the tap first.
* Only the **queued** drain (`QPSK_RX_QUEUED=1`, the deployed default) is
  changed. The legacy multi drain and the cyclic ring are byte-for-byte
  unchanged, deliberately, so the RXQ=0 FIFO A/B control keeps its historical
  baseline.
