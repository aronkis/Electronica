# Task 8 report — flash 146 with the SEQ-BIST image, then stage 3 (fabric-only RF legs)

Driver: Task 8 rig driver. Ledger: `two_jup/sdd_archive/2026-09-03-seqbist/progress.md`.
Every board action ran as a `launch_rig_unit.sh` unit. Every number is **[silicon]**
unless marked **[sim]** or **[inferred]**.

## 0. Headline

**The mission-link loss is reproduced with no host and no DMA anywhere in the path.**
A fabric-only forward leg (146's fabric generator → air → 148's fabric checker, no daemon,
no RX DMA, no tun0 on either board) measures **5.89 % garbage + 0.45 % crc_fail and 5.31 %
gap events** at 148's decoder pins, against the daemon leg a1r2's **8.12 %** host PER on the
same link — and against a fabric **loopback** floor of **0.058 %** (148) / **0.031 %** (146).
A second instrument on the *real* daemon stream (stage 3h, checker in host-frame mode)
returns the same numbers, **and the 26 ms comb: `period_est = 32.24` emitted frames**.

> **Pre-registration resolved:** the defect is in the **fabric / RF chain**. The host and
> the RX DMA path are **not** where the ~8 % lives.

## 1. Flash — SUCCESS, no rollback

| stage | result |
|---|---|
| DRY chain | all six stages resolve; `FLASH_146T_DONE` |
| `[1/6]` A0 gate | `ROLLBACK_BANK` md5 = `6b4744ca73f8` ✓ (**see §6.1 — the default would have FATALed**) |
| `[2/6]` backup + stage | `/root/BOOT.BIN.6b4744ca73f8.bak` created and md5-verified; image staged |
| `[3/6]` readback | booted `3378861d30bd` = expected, **no rollback** |
| `[4/6]` bring-up + NAK rail | `148 nakstat=4` ✓ |
| `[5/6]` health gate on 148 | **PASS first pass**, `fsync=1259 wcnt=1259` |
| exit | `FLASH_146T_DONE`, rc 0, 00:28:45→00:34:57 |

146 now runs `3378861d30bd3d85663b31cfdd9c6296` (WNS +0.166). Rollback `6b4744ca73f8`
remains banked **both** on nemo (`boot_known_good/BOOT.BIN.146.txfixF3vendh.6b4744ca73f8`)
and on the board (`/root/BOOT.BIN.6b4744ca73f8.bak`).

The pre-registered risk — that `[5/6]`'s `wcnt >= 1100` threshold would fire on the very
defect under investigation and roll a good flash back — **did not materialise**: with both
boards armed and the daemons up, the forward byte-word rate was 1259.

## 2. The 146 instrument: SINK=cyclic exercised on silicon for the first time

`POSTFLASH_OK` on 146: image verified, `tgen_rx` ctrl `0x00000000` at rest → `tgen_mode`
**set** (0x20) → checker clear (0x30). All 32 slots read 0 at rest (146 has no legacy
rx_seam/tx_starve witnesses, so the "stuck mux" heuristic is waived — `ZERO_SLOTS_OK`).
**`seqbist_read.py`'s remote script runs on 146**, which is what made the reverse geometry
worth attempting at all.

| leg (146, loopback, GAP=60000) | result |
|---|---|
| clean 60 s | ovf **constant 0→0** (`sink_witness_ok=1`); `chk_frames` tracks 0x104/0x124 to **0.0208 %** (72,032 vs 72,047); `crc_fail` **0**; garbage **50.017 %** vs the filler prediction 50.0 %; `lost_slots` 22 / 36,026 emitted = **0.0305 %**; `int_last` 51/1386/3647 — no 32/33 |
| control `SKIP_EVERY=1000`, 120 s | **PASS**: emitted 72,137, expected 72.1, observed 110, background 40.0 (from the clean leg's own 5.551e-4 events/emitted), corrected **70.0** vs tolerance 25.5 |

Both trials carry the formal verdict `UNINFORMATIVE` for one
reason only — `window_s < 150` — which is what a 60/120 s sanity trial is. They are quoted
as **instrument credit**, not as scored legs.

**146 instrument gap:** `TXCHK` reads `0x9D420000` on 146 but `tx_frames_checked` never
advances, so the TX-pin cleanliness evidence 148 gave in stage 1 is **not available** on 146.

## 3. Stage 3 — fabric-only RF legs

Bring-up: `bringup_fabric_only.sh` (derived from `bringup_r2r3.sh r3`; arm + mission LOs +
SSI + ARMCAUSE double-tap + ROM arm gate; **no daemon, no watchdog, no DMA**; boards left
**armed ROM**). It passed on the first gate try every time it was run (5/5):
148 1240–1243 f/s, 146 1237–1247 f/s.

### 3.1 Forward, GAP=60,000 (filler every other slot) — ABORTED AT THE GATE, and that is a result

`0x124 = 325.0 f/s`, `chk_frames = 279.5`, dev 14.03 %, against the same two boards decoding
each other's ROM at 1242/1247 f/s two minutes earlier. No window spent.

### 3.2 Forward, GAP=45,000 (filler-free) — the leg. 600 s

Gate **PASS**: `0x124 = 1252.4 f/s`, `chk_frames = 1251.3`, dev **0.084 %**.

> Note for anyone reconstructing the campaign: GAP=45,000 was pre-registered as the
> *saturated control* for GAP=60,000. Because 60,000 aborted at its gate (§3.1), the control
> became the **only scored fabric-only leg**. It was not substituted silently.

| quantity | value |
|---|---|
| window / readings | 600 s / 54 |
| `0x104` / `0x124` / `chk_frames` deltas | 734,507 / 734,508 / 733,987 (**0.07 %** agreement) |
| emitted (`chk_last_seq` advance) | 736,528 |
| **garbage (bad magic)** | 43,259 = **5.894 %** |
| **crc_fail** | 3,296 = **0.449 %** |
| **gap_events** | 38,992 = **5.31 %** of received (5.29 % of emitted) |
| gap1 / gap2 / gap3+ | 27,641 (70.9 %) / 8,331 (21.4 %) / 3,020 (7.7 %) |
| dup_or_reorder | 2,858 |
| `int_32` / `int_33` / lt30 / other | 2,432 / 431 / 28,943 / 7,186 → **period_est 32.15 frames** |
| sink witness | ovf constant, `sink_witness_ok=1`; rearms_in_window 0 |

**Filler is the RF-side killer.** Same generator, boards, link and ordering; the only
difference between §3.1 and §3.2 is whether every other air slot is an all-zero
unmodulated frame. It also retires the stage-2 reading: filler-free works perfectly in the
real geometry, so the self-reception collapse was self-reception-specific.

### 3.3 Stage 3h — the checker on the REAL daemon stream (host-frame mode), 400 s

`tgen_mode` cleared by RMW (ctrl 0x30 → 0x10, bit0 untouched), `SINK=none` (the daemon's own
S2MM is the drain), checker cleared after bring-up, restored to 0x30 afterwards.

| quantity | value |
|---|---|
| `0x104` / `0x124` / `chk_frames` | 482,287 / 482,287 / 482,166 (**0.025 %**) |
| garbage | 27,295 = **5.661 %** |
| crc_fail | **10,211** = **2.118 %** |
| gap_events | 25,194 = **5.225 %** (gap1 71.9 %) |
| `int_32` / `int_33` / lt30 / other | 2,235 / 708 / 17,887 / 4,364 → **period_est 32.24 frames = the 26 ms comb** |

The one honest difference from §3.2 is `crc_fail` (0.45 % → 2.12 %): under `tgen_mode` the
CRC field is a constant compare, under host-frame mode it is a real CRC32, so host-frame
mode catches damage the generator mode cannot see — the expected direction.

⚠ The leg carrying this window hit `MID_CAPTURE_WEDGE` at 572 s (`LEGRUN_GATE_FAIL`), so the
leg's **own** host PER is UNINFORMATIVE; the checker window ran 04:07:26–04:14:07, entirely
inside the healthy part (deliver_rate 954 f/s pre and post), ~90 s before the wedge. The
host-vs-checker comparison therefore uses a1r2's 8.12 %, not this leg's.

### 3.4 Reverse — UNINFORMATIVE (three distinct failure modes, all recorded)

| attempt | sink | result |
|---|---|---|
| r1 | cyclic, armed **after** the traffic | `0x124` 1247.5 f/s, `chk_frames` **0**; 146 `0x1B0` ovf **22,936,204** → sustained-drain-stall wedge |
| r2 | cyclic, armed **first** (order fixed, committed) | `0x124` 1246.2 f/s, `chk_frames` **still 0** → **defect D-8-1** |
| d | 146's plain daemon as the downstream sink | checker counts (389.3 f/s) but 146's own frame sync **halves to 531.9 f/s**, dev 26.8 % |

**D-8-1: `SINK=cyclic` is credited for LOOPBACK ONLY.** The identical devmem ring drained
146's seam for 180 s of loopback and does not drain it in the RF-armed state. The DMAC status
window could not be read (see §6.2).

Mode (d) echoes stage 2: on the **receiving** board, having its own daemon live halves its
detection rate.

### 3.5 TX-side DDRCAP (sel8) on 148

Standalone, no receiver needed: 148 put on air as the TGEN byte source at GAP=45,000, then
`ddrcap_during_leg_go.sh SEL=8 SKIP_GOLD=1`. **Credited: 536,870,912 B, capture exit 0**
(`two_jup/comb/runs/20260904_043231_sel8_tx148/sel8_leg.bin`). Desk positive control
`ddrcap2_pc.py --sel 8`: **TIER2 FAIL on `toff_range_steady` only** (d0 = 489); every other
gate PASS, including `tx_marks_present`, `demod_marks_present`, `tref_monotone`,
`tref_cadence` (`tref_drop_stats`: modal_delta 1, frac_at_modal 0.9980, drops 488/1e6). The
desk owns the TX-vs-air question from here.

## 4. What this changes

* The comb and the ~5–6 % damage are **at the fabric decoder pins**, on two independent
  traffic sources, one of which has no host or DMA in the path at all.
* The 8-frame (≈6.4 ms) structure under the 32-frame comb is visible in both instruments
  (`int_last` clusters at 7–9 and 23–25 with a 31–33 tail; `int_hist_lt30` dominates at
  74 % of intervals). The sub-harmonic reading is **[inferred]**.
* Filler frames (all-zero, unmodulated) are lethal **over RF only** — a concrete fix lead
  independent of the comb.
* The checker is now the standing instrument for the fix work: it runs on either board, on
  generator traffic (`tgen_mode=1`) or on real host traffic (`tgen_mode=0`).

## 5. Instrument limits found (each cost or nearly cost a leg)

1. **`lost_slots` is VOID on an RF leg.** A frame with an intact magic and an accepted CRC
   field but a **corrupted seq field** is taken at face value and injects a gap of up to
   2^32 slots: `chk_lost_slots` ran to 3.96e10 and wrapped 25 times in 600 s.
   `seqbist_score.py` now recognises the signature (every negative delta on a seq-VALUE
   counter), keeps the leg instead of discarding it as a mid-window clear, and scores on
   `gap_events/emitted` + garbage + crc_fail. **A checker revision should reject a seq that
   is not `last_seq + k`, k ≤ 64.**
2. **The `0x114` read-back gate was false** — `0x114` is write-only like `0x158`/`0x118`.
   It refused `t8-fwd45k` two seconds after that leg's own on-air gate had PASSED. Removed;
   the arm is verified by effect.
3. **The drain must be up before any traffic exists** (fixed and committed) — necessary, and
   as D-8-1 shows, not sufficient for cyclic.
4. **`no_arm_inflight.sh`'s `arm_guard` is too wide for an in-leg reader**: it refuses while
   `capture_r3.sh` runs, and `capture_r3.sh` runs for the whole leg, so the first 3h reader
   blocked past its own `BRING-UP COMPLETE` and would have read nothing. Narrowed to the
   actual hazard (a profile reload in `bringup_r2r3`/`restore_known_good`).

## 6. Two rig facts worth carrying

### 6.1 The 146 chain's rollback bank default is wrong for this restore point
`flash_146_txfix.sh` defaults `ROLLBACK_BANK` to
`jupiter_byte_tmr146_gates/variants_placement/v_endh/BOOT.BIN`, which is **`ec414d2df8bc`**,
not `6b4744ca73f8`. The A0 gate compares that md5 against `FLASH_BAK` and is **not**
DRY-guarded, so the DRY run does test it. Caught before launch;
`ROLLBACK_BANK=boot_known_good/BOOT.BIN.146.txfixF3vendh.6b4744ca73f8` was passed.

### 6.2 Long multi-line remote command strings return EMPTY from 146
The identical string that 148 executes normally returns nothing from 146, while each of its
fragments works alone. It silently produced two empty probes and swallowed the DMAC status
window in the D-8-1 diagnosis. `seqbist_read.py`'s ~800-byte script is **not** affected
(verified, three clean samples). Keep 146 remote commands short until this is understood.
