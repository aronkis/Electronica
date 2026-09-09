# Task 9 (T5 write-up) — report

**Status: complete.** Host-only, no board contact, no subagents.

## Deliverables
| # | Path | Commit |
|---|---|---|
| 1 | `two_jup/SESSION_20260830_AUTONOMOUS.md` §91 | `724eb03` |
| 2 | `two_jup/NEXT_STEPS.md` (rewritten) | `c997e40` |
| 3 | `two_jup/sdd_archive/2026-09-03-txfix/RULINGS.md` (10 rulings) | `4ab441b` |
| 4 | §91 part 7 "Facts a future session must know" (memory line) | in `724eb03` |

`TXFIX_STATE.md` was not modified (controller-owned).

## §91 contents
Variants in RTL terms with file:line (from `TXFIX_STATE.md` §1); injector description +
full G0-G14 gate matrix table (from `beat_runs/txfix_gate_summary.txt`, final exit-gated
numbers); G6 parked-control and G12 scoped notes; F1's G8 disqualification and the F2/F3
difference (fullRAM only); Vivado history incl. the attempt-2 tx_checker routed-WNS
failure, the `explore` strategy and the new routed-WNS bootgen gate; silicon acceptance
(baseline n=7 → flash → GATE_PASS ×2 → timeline n=0 → 512 MB witness stalls=0 /
5,449 frames at offset 0 / tOff steady); the 0x108 liveness caveat; the claim boundary
(entitled / not entitled); six open items; the memory facts line.
Every claim carries `[silicon]`/`[sim]`/`[RTL]`/`[vivado]`/`[inferred]`. A counter-discipline
note at the top binds every 0x108 figure on BOTH images to "1 s delta of a 120-bit-window
bit-error counter" — never a frame error rate, PER or BER.

## Judgement calls made
- **Witness scope separated explicitly.** 5,449 frames × 802.93 µs ≈ **4.4 s of air time**;
  the multi-period coverage (792 s, > 6 beat periods) comes from the 0x108 timeline alone.
  Both halves of the pre-registered conjunction were met, so the PASS is unaffected, but
  §91 parts 4 and 5 (Silicon acceptance / Claim boundary) keeps the two scopes in separate sentences so no reader infers the content-level
  check spans the beat periods.
- **Frame-identity limit paired with what closes it.** The tap3 map is injective mod 12,320,
  so "all frames at offset 0" does not alone exclude a whole-frame stall (the F1/G8 mode).
  §91 states the geometry half closes it: a whole-frame stall is a ~12,320-symbol constant
  run; measured max run is 7, zero runs > 50.
- **G13 labelled `[sim, derived]`** — it is scored from G11's log, not an independent run,
  and its evidence is an empty sequence.

## Inconsistencies found between sources
1. **G12 underflow direction.** Raw `beat_runs/txfix_gate_summary.txt` G12 F1/F2 lines still
   read `underrun_toward_65536=True wrap_step_seen=True min_count=0`, and the ledger's 12:35
   HEARTBEAT says "min_count=0 confirms the underflow-toward-zero defect is real". The
   reviewed `TXFIX_SIM_GATE.md` (fix round, commit `1d36163`) and `TXFIX_STATE.md` say the
   direction is **unresolved** (`near_65536_seen=False` on every line; 2 samples in the NF=8
   trim; `min_count=0` is a normal FIFO drain floor).
   **Followed: `TXFIX_SIM_GATE.md` as corrected.** §91 records that the raw summary lines
   predate the fix round and that the 12:35 heartbeat is superseded, and carries the
   unresolved direction as open item 5 (part 6).
2. **Frame count in the sel6 witness.** The 12:55 Ruling line says "~5445 frames"; the Task 8
   completion line and `TXFIX_STATE.md` §5 say **5,449**. **Followed: 5,449.**
3. **Frame time.** §90's body says 3.21172 ms; the §90 correction (09-03 09:25), the plan and
   `TXFIX_STATE.md` say **802.93 µs**. **Followed: 802.93 µs**, and §91 notes the supersession
   explicitly because it sits directly below the stale text.
4. **Premature-scoring numbers.** The 11:05 interim heartbeat quotes G0 at 77 frames (later 89);
   the final exit-gated scorer gives **106**. **Followed: the final exit-gated numbers**
   throughout; the premature figures appear only in the "two scoring bugs" narrative.
5. **DRY-test constant.** The plan text says mid.bin must report `stalls=4`; Task 4 measured
   **6** and flagged it. Not load-bearing for §91; noted here for completeness.

No inconsistency was found that changes any verdict. F3's PASS, F1's disqualification, and
the F2 bank-only ruling are consistent across every source.

## Not done (by design)
`NEXT_STEPS.md` carries an explicit `F2 md5: __TBD__ · routed WNS: __TBD__` placeholder — the
F2 Vivado build was still running at write-up time and the controller appends the md5 when it
lands, plus a `BUILT, NOT flashed` row in `boot_known_good/README.md`.
