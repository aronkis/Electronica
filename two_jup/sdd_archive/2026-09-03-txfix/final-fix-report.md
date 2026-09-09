# TXFIX campaign — final documentation fix round (2026-09-03)

> **State as of 2026-09-03 ~13:30, host-only.** A rig unit was operating on 148 concurrently with
> this round and appending to `progress.md` throughout it. In particular the ledger shows a **control
> reflash of the unfixed `638b36de3493` launched 13:24** (BAK `f6a8c3ea119c`) and a PER run exiting
> `code=4`. This round made **no board contact** and had no mandate to track live rig state, so
> `NEXT_STEPS.md`'s "Current state" block — including "**148 is running F3 `f6a8c3ea119c`** …
> Currently flashed on 148" — is a snapshot that was true when read and **may already be stale**. Do
> not treat it as verified-current; re-check the ledger and the board before acting on it. Nothing in
> the corrections below depends on which image is currently flashed.

Host-only, no board contact, no subagents. Behaviour-preserving except where noted.
Scope: the seven findings from the whole-branch final review (ledger `progress.md:181`).
The engineering result is **unchanged** — every correction here is about how the result was
*described*, not what it was.

## The one correction that matters: `0x108` was never "zero"

**Claim as written (wrong):** "`0x108` read exactly zero" / "`0x108` = 0 throughout".
**Verified evidence:** `two_jup/beattl/20260903_124118/errps.csv` — 420 data rows, `errs` column
holds the **constant cumulative value 67 on every row** (`sort -u` on the column returns the single
value `67`).
**Correct wording, used everywhere now:** *cumulative 67, constant → delta 0.*

**The verdict is unaffected.** `BURSTS n=0` is computed from the *delta*, and the delta is zero over
the full 792 s. Nothing about F3's PASS moves. Only the description of the register moved.

### Reset semantics — settled from primary sources

`two_jup/arm148_mode1.sh` was read end to end. In the arm path it writes exactly one BIST-adjacent
register — `0x10C 0x60003` (the iq_debug_mux select) — and then **reads** `0x104` and `0x108` twice
to compute `fps` and `errps` as differences. **Nothing writes `0x108`. Nothing resets the BIST.**

The two timelines corroborate this independently:

| run | image | first row `errs` | preceding events |
|---|---|---|---|
| `beattl/20260903_101818` (baseline) | `638b36de3493` | **222,137** (rising to 2,087,524) | arm at 10:16, timeline from 10:18 |
| `beattl/20260903_124118` (F3) | `f6a8c3ea119c` | **67** (constant) | boot 12:37, two gate arms, timeline from 12:41 |

A counter that were arm-reset would start both runs near zero. The baseline starts at 222k two
minutes after its arm. **The counter is free-running and not reset by the arm.**

### Conclusion, labelled

**[silicon, weak but real]** Because the counter is not arm-reset, the **67 counts on F3 accumulated
between the 12:37 boot and the 12:41 timeline start**, through the post-boot arm transients. The
counter therefore **did count on `f6a8c3ea119c`** — a counter stuck dead at reset reads 0, not 67.
This is **weak** evidence (a small sample taken during transients, not a controlled injection) but
it is **real**, and the previous flat statement that liveness was "never demonstrated" overstated
the gap.

**[silicon] Still open:** `beat_timeline.sh` populates no packets column on either image, so a
*low-rate* counter fault and a clean link are still not fully separated by this instrument, and no
known error was ever injected on the fixed image. **Ruling [12:55] stands unchanged:** the sel6
witness is the primary silicon evidence; the `0x108` null is corroboration.

## Finding 2 — the caveat is now tied to the tx_checker timing

The paths that failed timing in **F3 attempt 2** — `fill_reg[3]` → `bit_errors`/`frame_errs`, routed
WNS **−0.392 ns**, TNS −17.7, 56 endpoints, 24-25 logic levels — **are the `0x108` feed**: they are
the tx_checker instrument counters that drive it. That image was **never flashed** (the
no-flash-on-routed-WNS-fail rule). The flashed attempt-3 image closes the same paths at
**+0.095 ns**, and — the fact that makes the tie-in load-bearing — the unfixed comparison image
`638b36de3493` closed them at **+0.105 ns** (`progress.md:104`).

So the `0x108` feed is **timing-clean on both images in the n=7 vs n=0 comparison**. The difference
between the two timelines cannot be a setup-violation artefact on the instrument. This is now stated
in the §91 caveat and in the `TXFIX_STATE.md` addendum.

## Finding 3 — "245.76 MHz" is refuted; the arithmetic survives

The 10:38 ledger line is the primary source: `timing_gate.tcl` constrains the modem fabric to the
**8.000 ns `axi_adrv9001_adc_1_clk`, i.e. 125 MHz**. The "197,328 clocks per frame" are therefore
**sim ticks, not fabric clocks**, and no fabric frequency can be inferred from them — which is
exactly what §90's correction line had done (`197,328 / 16 → 245.76 MHz = 4 × 61.44 MSPS`).

Three sites corrected in `SESSION_20260830_AUTONOMOUS.md`: the §90 origin inference (~:5241), §91's
rate arithmetic (~:5429), and §91's memory line (~:5493). Each now quotes the **measured 802.93 µs
per frame (1247-1248 f/s)** and either drops the MHz figure or states **125 MHz with the
`timing_gate.tcl` source**.

**What survives untouched:** every period derived in §90 (0.761 s base increment, 1.52 s first
`frameCount==0`, 3.04 s mod-4 return, 120.2 s = 149,708 frames) comes from the *measured* 802.93 µs,
not from the MHz figure. The arithmetic was not edited. The 4×-wrong 3.21 ms figures remain flagged.

Out of scope and deliberately untouched: `SINGLES_CAMPAIGN.md`, `TX_RATE_E.md`, `TX_KICK_SIM_B.md`,
`TX_ORIGIN_TRACE_A.md` — different campaigns.

## Finding 4 — the branch is not pushed

`git rev-list --count origin/per-under-1pct-2026-07..HEAD` returned **38** (the review said 37; the
count grows with every commit, including this round's). `NEXT_STEPS.md` follow-up 6 now reads **NOT
pushed, nothing merged**, and carries the verification command rather than a number that goes stale
the moment anything is committed.

**F2 line: filled.** At the start of this round `boot_known_good/README.md` had no `txfixF2` row and
the placeholder would have stayed. The rig unit added the row mid-round
(`BOOT.BIN.148.txfixF2.5e3f58955f02`, routed WNS **+0.056 ns**, `IMPL_STRATEGY=explore`, **BANK-ONLY
by Ruling 12:57**), so the `__TBD__` placeholders were filled from that row.

## Finding 5 — README qualifier

The `txfixF3` row's "VERIFIED — the 120.2 s beat is absent" now carries its claim boundary inline:
*(within §91's claim boundary: 792 s 0x108 timeline + 4.4 s content witness + two phase-timed 4.4 s
witnesses at ARM_OK+76/+196 s, 2026-09-03)*.

## Finding 6 — minor code and test items (all behaviour-preserving)

**`skidfix/txfix_inject.py`.** A comment was added explaining that both arms of the F1 patch's inner
`if (Compare_To_Constant1_out1 == 1'b1)` assign the same value (`C2 === ~C1`, both compare
`Delay3_out1` against `2'b00`) and that the two-branch shape is kept **deliberately**, so the F1 diff
reads as "wrap the existing body in the frame-boundary guard" and nothing else.

**The comment is a Python `#` comment placed *above* the `DBF_NEW = """..."""` assignment, not a
Verilog comment inside it.** The patch text is the byte source of the flashed image and was not
touched. Verified by hashing the strings before and after the edit:

- `DBF_NEW` md5 `3148bbf07985c1bd91713f9198d0bbea` — **unchanged**
- `DBF_OLD` md5 `5a94e86d2e14ad6a756493a315f28c83` — **unchanged**

A `DO NOT EDIT THE PATCH TEXT BELOW` warning naming `f6a8c3ea119c` was added alongside.

**`tests/test_txfix_rig_scripts.py`.** The tautological assert
`src.count('GOLD=') == 1 or 'GOLD=${GOLD:-BCF94856}' in src` (the right operand is guaranteed by the
preceding line, so it could never fail) is replaced by the real check `src.count('GOLD=') == 1` with
a message — measured as exactly 1 in `arm148_mode1.sh`.

Sentinel coupling: a missing `~/modem-status/SENTINEL_STOP` is a rig-state precondition, not a
defect, so `test_sentinel_present` carries a `pytest.mark.skipif` and `_run` calls a
`_require_sentinel()` guard that **skips** before doing any work. The **pre/post mtime comparison
keeps its hard assert** — if the sentinel is present when a run starts it must still be present and
unchanged when it ends, so a sentinel that disappears mid-run still fails loudly rather than
skipping.

**`txfix_witness_go.sh`.** The credit rule was capTAP-only; a short read still produces a scorable
`.bin`, and `stalls=0` on a truncated capture is evidence of nothing. `credited=` now requires
**both** golden pre/post capTAP **and** `bytes=536870912` parsed from the capture `meta.txt`
(format confirmed against `txfixwit/20260903_125517_F3/cap/meta.txt`:
`F3 sel=6 bytes=536870912 pre=0xBCF94856 post=0xBCF94856`; `SZ=134217728` samples × 4 B). A
non-credited short read is logged with both byte counts. The header comment at `:3`, which stated
the old capTAP-only rule, was updated to match.

The stale comment at `~:70` claimed `ddrcap2_capture.sh` "makes its own subdir under OUT". It does
not when `OUT` is passed (it writes `$CAPOUT/$VAR.bin` and `$CAPOUT/meta.txt` directly; the
timestamped subdir only appears when `OUT` is unset). The comment now says so and notes that the
recursive `find` below it is a no-op in this call path — **the `find` itself was left alone**, since
this round is behaviour-preserving.

**Ledger placeholder.** `HEARTBEAT task5 2026-09-03T00:00:00-04:00` carries a zeroed time-of-day. A
correction line was **appended** to `progress.md` (never edited in place — a rig unit is writing to
that file) bounding the real time by the commit that round produced, `1d36163` @ 12:44:27 -0400.

**`TXFIX_STATE.md`.** An addendum (§6) was **appended**; §5 and §3 were left exactly as written and
the addendum names the two stale phrases explicitly ("0x108 = 0 throughout" in §5, "total errors over
the window = 0" in §3) as meaning *delta* 0 with a constant cumulative 67. It also carries the
timing tie-in and the note that **"frameCount pinned at 3" describes the pre-throttle state only —
once fullRAM throttles, the counter oscillates 2↔3.**

## Finding 7 — added to §91 open items

Two items were appended:

7. **The task5 heartbeat gaps were caught, not avoided.** `progress.md` logs
   `STALL agent=task5 age=27.8` at 11:11:48 and `age=26.8` at 11:31:49. The stall *detector* worked;
   the cadence discipline did not — the agent twice went ~27 min against a ≤ 15 min instruction and
   only the timer surfaced it. Credit the detector, not the process.
8. **The stall-detector timer must be disabled once the campaign closes.** It is campaign-scoped, not
   a standing service. **Not disabled by this round** — a rig unit was still appending to the ledger
   at write-up, so this was deliberately left to whoever closes the campaign.

## Verification

`cd two_jup && python3 -m pytest tests/test_txfix_rig_scripts.py tests/test_txfix_inject.py -q`
→ **33 passed**, 0 failed, **0 skipped**. Zero skips is the intended result here: `SENTINEL_STOP` is
present on this host, so the new skip guards are inert and the sentinel-hold coverage still ran. If
a future run reports these as skipped, the operator has lifted the hold — that is expected, not a
regression, but it does mean those assertions no longer have a subject.

`bash -n txfix_witness_go.sh` → clean. `DBF_OLD`/`DBF_NEW` md5s → unchanged (above).

## Could not verify / deliberately not done

- **"frameCount pinned at 3" was not found anywhere in `TXFIX_STATE.md`.** A repo-wide grep for the
  phrase hits only the review's own finding text at `progress.md:181`. The clarification was appended
  to the addendum anyway (it stands alone and is correct), but there was no stale sentence to point
  at in that file.
- **The stall-detector timer was not disabled**, per instruction — a rig unit is still running.
- **Nothing was pushed.** Pushing would falsify the finding-4 correction; the branch is intentionally
  left unpushed and local.
- **Live rig state was not tracked.** A concurrent rig unit reflashed 148 during this round (see the
  "State as of" note at the top). Statements in `NEXT_STEPS.md` about which image is *currently*
  flashed were not re-verified and may be stale.
- **No board contact of any kind** was made; the `errps.csv` files, `meta.txt`, and the ledger were
  read from the repo as already-captured artefacts.
