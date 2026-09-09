# Task 3 (T0c full-loop sim gate) report — SEQ-BIST

Status: **complete — 3 of 6 runs PASS; G1 (and its two gap-sweep variants) FAIL
on a real rail defect, not on the instrument.** Desk only: host CPU, no board
contact, no subagents, no push. Every number below is **[sim]**.

## Deliverables

| file | what |
|---|---|
| `jupiter_240k5_byte/rtl_sim/wrap_byte_seqbist.v` | gate top: TGEN v2 on the DUT TX byte pins, `rx_seq_checker` + `cnt_mux32` on the DUT RX byte pins |
| `jupiter_240k5_byte/rtl_sim/sim_byte_seqbist.cpp` | driver: freeze/mux readout, CSV every 100 frames, summary, exit trailer |
| `jupiter_240k5_byte/rtl_sim/build_seqbist_gate.sh` | Verilator build under `systemd-run --user`; stamps rtl sha + interval units |
| `jupiter_240k5_byte/rtl_sim/seqbist_gate_runs.txt` | the G1–G4 (+G1B/G1C) manifest |
| `jupiter_240k5_byte/rtl_sim/seqbist_gate_launch.sh` | one transient unit per gate; wrapper prints `SEQBIST_GATE_RUN_EXIT=` |
| `jupiter_240k5_byte/rtl_sim/seqbist_gate_score.py` | scorer → `beat_runs/seqbist_gate_summary.txt` |
| `two_jup/tests/test_seqbist_gate_score.py` | 36 scorer unit tests on synthetic files |

Commits `53c9168`, `99858d5`, `8fd64fa` (+ the pre-results G1 tightening).
Build **44 s** (Verilator 5.020 `-O2`), netlist
`rtl_sim/s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback`, `-y` on that
directory **and** `rtl_sim/` (the three SEQ-BIST modules are not in the
netlist). Built against `rx_seq_checker.v` **90d5430** (fix round 2:
`WITH_CRC` + CDC synchronisers), `int_units=seqdelta`, re-checked unchanged at
scoring time.

The harness puts the *real* `qpsk_traffic_gen_v2` on the DUT TX byte pins (the
C++ no longer regenerates frames) and reads every counter the way the host
will: `freeze=1` → sweep `mux_sel` 16..31 → sample `mux_q` → `freeze=0`, with
`packets_out` sampled **inside** the same freeze window. Checker `en` is pulsed
after the TGEN is flowing (task-1 arming rule; the fix-round-2 synchronisers add
2 clocks, which this ordering absorbs).

## Gate table  [sim] — 1,002 checker frames per run, exit-gated

| gate | config | result | numbers |
|---|---|---|---|
| **G1** clean | gap 96,000 | **FAIL** | frames 1002, good_magic 501, emitted 501, garbage 501, **lost_slots 1, gap_events 1** (gap1), crc_fail 0, dup 0, int_* all 0, packets_delta 1003 |
| **G2** skip_every=50 | gap 96,000 | **PASS** | gap_events **10** = ⌊501/50⌋, gap1 10, gap2/gap3plus 0, lost_slots 10, **int_last 51** (= N+1, seq-delta units), int_other 9 = gap_events−1, all other bins 0, garbage 501, crc_fail 0, dup 0 |
| **G3** corrupt_every=40 | gap 96,000 | **PASS** | garbage 513 = 501 filler + **12** corrupted = ⌊501/40⌋, gap_events 13 (= one per corrupted frame ±1), gap1 13, lost_slots 13, **int_last 40** (= M), crc_fail 0, dup 0 |
| **G4** over-run force | 2 M clks at emitted frame 100 | **PASS** | force landed: **30 frames emitted into a 10.14-air-frame window**; damage counted: **lost_slots 20, gap_events 10, all gap2**, int_last 3; recovery: **702 frames** after the event with **0** new gap_events / dup / lost and garbage growth = filler only |
| **G1B** clean | gap 150,000 | **FAIL** | identical to G1: emitted 501, lost_slots 1, gap_events 1 |
| **G1C** clean | gap 190,000 | **FAIL** | under-supplied (emitted 334, filler 0.668), **lost_slots 2, gap_events 2**, int_last 103 |

Event counts behind the ±1 checks are small — G2 10 gap events, G3 12
corruptions — because of the runtime below. Read them as exact-cadence
confirmations, not as high-confidence rate estimates.

## The clean null does not exist on this rail (answers the coordinator's question)

**There is no TGEN gap at which G1 reads `lost_slots=0` *and* `garbage=0`, and
both halves fail for rail reasons, not instrument reasons:**

- `garbage=0` is **structurally impossible** here: the netlist emits a
  `packets_out` increment every **98,664 clks** but consumes one host frame per
  **197,328 clks** (the 2× packets artefact already in
  `beat_runs/THROUGHPUT.md`), so every other delivered byte-plane frame is an
  **all-zero filler** that the checker correctly counts as `garbage`. Measured
  `garbage == frames − emitted` exactly (±0) in every run. The gate accounts for
  it rather than hiding it (`expect_filler=1`).
- `lost_slots=0` failed at **all three** gaps swept (96,000 / 150,000 /
  190,000). The loss is **not** over-supply: it is a **byte-plane framing slip**
  — one delivered frame of **2,400 bytes** instead of 1,528, immediately
  followed by one garbled 1,528-byte frame, then clean resynchronisation — and
  it lands on the **same frame (seq 134) in G1 and G1C at completely different
  pacings**, i.e. it is content/state-locked, not rate-locked. Rate ≈ **1 event
  per 500 emitted frames** (G1/G1B 1 in 501; G1C 2 in 334). G2 and G4 saw none
  in their 501 frames.

**Pacing numbers for T2.** The byte plane saturates at **one host frame per
197,328 clks** for any gap ≲ 150,000 (both 96,000 and 150,000 gave exactly
501 emitted frames in 1,002 air frames); at gap = 190,000 the generator
under-supplies (334 frames in 1,002, ≈ one per 296,000 clks). 197,328 clks is
**1,245 f/s if the fabric clock is 245.76 MHz** — exactly the mission frame
rate, which is the sanity check that the sim rail is running at the real
consumption rate. A gap of ~**96,000 clks** is the recommended operating point
(saturating but not over-driving); the generator's effective period is
`gap + ~100,000 clks` of back-pressured handover, which is why gaps below
saturation do not increase the delivered rate.

**This finding is the campaign-relevant one:** a frame is lost, and one garbled
frame delivered, in **pure fabric internal loopback with no radio, no DMA and no
host** in the path. It is the same class of damage the COMB campaign is chasing
(detected, delivered, garbage) and the SEQ-BIST instrument counted it exactly
right — 1 garbage + 1 lost slot + 1 gap1. Whether the silicon rail does the
same is **unverified from here**.

## Rail facts the T1/T2/T3 authors must not get wrong

1. **`starve` (withholding TX data) loses nothing.** Stalling the TGEN
   mid-frame — a full frame period, ByteWordBuffer visibly empty — only
   *delays* frames: the byte plane back-pressures, the generator resumes with
   the same seq, and the checker correctly reports `lost_slots=0`. Anyone
   expecting TGEN under-run to show as `lost_slots` on silicon will misread a
   null. Kept in the harness as the negative control.
2. **Over-supply is what loses sequence numbers**, and the coordinator's
   silicon ctrlA-r3 observation (seq +~1.5 per received frame, garbage 50 %,
   gap2 dominant) is the same signature this harness produces at gap = 0. That
   makes **matching `gap` to the consumption rate a precondition for any
   fabric-loopback null on silicon** — at the wrong gap the checker reports loss
   that is the generator's fault.
3. **`bwb_min`/`bwbAvail` are not force evidence.** The ByteWordBuffer reaches
   0 in every run, forced or not (`bwb_min_global=0` even in G1), so G4's
   "the force landed" test is the emitted-frame count inside the force window.
4. **Interval units.** The harness stamps the units the compiled RTL implements
   and the scorer refuses a mismatch, so a stale build cannot pass with the
   wrong constant. Confirmed on silicon-bound RTL: `skip_every=50` → `int_last`
   **51**, `corrupt_every=40` → `int_last` **40**. The 50 → 51 change against
   the original brief is the expected consequence of the ruling.
5. TX/RX frame identity must **not** be asserted under `corrupt_every` (the
   TX-side checker arms only on a good magic); this harness does not assert it.

## Runtime

Measured **~11–15 kclk/s** for this DUT (matches `beat_runs/THROUGHPUT.md`), so
one emitted frame costs ~13–18 s of wall time. The brief's 2,000 frames would be
~3.7 h per gate. Runs were sized at **1,000 checker frames = ~500 emitted
frames ≈ 1 h 50 m each**, six units in parallel on 12 cores (21:35 → 00:41).
Scaling up is purely a wall-clock decision: the same manifest with
`nframes=4000` is a ~7 h soak and would put the ~1-in-500 framing slip on a
firmer footing.

## Re-running

```
cd jupiter_240k5_byte/rtl_sim
./build_seqbist_gate.sh --wait          # ~44 s, stamps rtl sha + int units
./seqbist_gate_launch.sh                # or: ./seqbist_gate_launch.sh G2 G4
python3 seqbist_gate_score.py           # -> beat_runs/seqbist_gate_summary.txt
```
Rebuild and re-run after any `rx_seq_checker.v` change. The 146 vendh lineage is
**not** sim-gated by this task: point `SEQBIST_NETLIST=` at its snapshot and
re-run the same manifest.
