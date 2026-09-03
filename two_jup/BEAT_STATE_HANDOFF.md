# BEAT — HANDOFF FOR A FRESH SESSION (written 2026-08-30 10:40)

You are picking up a hunt for the "120.2-s beat" on a two-board ADALM-Jupiter QPSK link.
This file is self-contained: it is enough to build the next experiment correctly without reading the
1,200-line campaign ledger. Deeper detail is in `two_jup/SINGLES_CAMPAIGN.md` (dated entries, newest last).
**Campaign goal (still NOT met): delivered PER < 1 % both directions, ARQ off. Forward is ~10 %.**

---
## 1. THE SETTLED PARAGRAPH (verbatim, every claim labelled)

Remaining forward loss is TWO things, not five: a **steady comb ~6 %** and a **periodic beat contributing
~4 pp**. They are not the same phenomenon — the comb is **absent entirely** from FPGA-internal digital
loopback while the beat is **present** there, so the comb needs the transceiver, the analog path or 146's
transmitter, and the beat needs none of them (**proven on silicon**). The beat and the loopback error floor
**are one mechanism**: the floor is quantised at **exactly 51 bit errors per event** at ~0.09 % of frames,
and every burst divides by 51 into **one event per frame for 2.8–3.1 s**, matching the observed duration
(**proven on silicon**). The correct target for that loopback is **exactly zero** — the same RTL in
simulation decodes **84 of 84 frames with zero errors** — so both the floor and the beat are **defects, not
noise**, and no legitimate mechanism in the RTL produces nonzero errors in a purely digital loop (**proven in
sim**). **What 51 means:** the only nonzero frame in the clean sim is the acquisition frame, at exactly 51
bits — the Viterbi converging from an unknown state — so 51 is a **decoder-side** quantity and the hardware
event is **the decoder's trellis being restarted mid-stream** (**proven in sim** as of 2026-08-30 10:30; see
§2 — it was *inferred* before that). **TX/RX boundary:** in sim the transmitter is exonerated (84/84
bit-exact through the full loop, so correct symbols correctly paced, **proven in sim**); the sim has no fault,
so this does not transfer to silicon, where the TX/RX split is **untested**. The fault is placed in the
RX-side decode/alignment chain **by inference from the 51-bit decoder signature**.

Numbers behind it: air windows 5.86–6.62 % bad-magic (burst-free) vs 10.6–12.3 % (burst-containing); the
arithmetic 0.92·6 + 0.08·100 ≈ 13.8 % reproduces a burst-containing window. Loopback floor 510/561/612/663
bit errors per 10 s = exactly 51 × 10/11/12/13. Bursts 194,049 / 196,306 / 206,409 / 211,279 errors ÷ 51 ÷
1,356 frames·s⁻¹ = 2.81 / 2.84 / 2.98 / 3.06 s.

---
## 2. THE START-PULSE HYPOTHESIS — now CONFIRMED IN SIM

**Claim.** A spurious/duplicate pulse on the FEC decoder's `startIn` restarts the Viterbi trellis; the
decoder re-converges and loses ~51 decoded bits, once per spurious start.

**Why 51 is decoder-side.** In a clean FPGA-internal digital loopback the *only* nonzero frame is the
acquisition frame, and it costs exactly 51 bits — the decoder converging from an unknown state. 51 is
therefore a property of this K=5 code's convergence/traceback, not of any channel disturbance.

**Why it explains the floor AND the beat.** One restart = one ~51-bit frame, then full recovery. Floor =
~1 spurious start per 1,100 frames (0.09 % of frames). Beat = a spurious start on nearly every frame for
~3 s, every 120.2 s. Same event, different duty — which is exactly what the 51-quantisation showed.

**Why it explains the delay-FIFO witness reading zero.** The start-marker path is separate from the data
path. The FIFO witness (occupancy, push/pop address difference, push-on-full) watched the *data* path and
correctly read flat through seven bursts. A start-marker fault is invisible to it. That is consistency, not
contradiction.

**Why it explains `fixctl` being inert.** On the v3 lineage `BfContract` falls back to `legacyStart` when
the tag is invalid, so a spurious start still reaches the decoder.

**SIM EVIDENCE (2026-08-30 10:30, tapped harness, flashed-lineage netlist):**
- Tap sanity: `totStarts=50/51`, `totValids=2,463,751` — taps see one start per frame and every coded beat.
- Control: 50 packets, **51 total bit errors**, `starts=1` on every frame, zero errors on every frame except
  the acquisition frame.
- One spurious start injected at frame 14: **68 bit errors in one frame (frame 17), then zero**. Both
  pre-registered falsifiers excluded (not ~0 = absorbed; not corruption to end-of-frame).
- **68 vs 51 is a residual detail, not a match — do not paper over it.** Same class: acquisition (51)
  restarts an empty trellis; a mid-stream restart (68) additionally discards bits in flight through the
  traceback. Hardware floor quantises at exactly 51.

---
## 3. THE INJECTOR FAILURE MODE — DO NOT REPEAT

Five injections (`bit1`, `sym1`, `sym2`, `sym8`, `start1`, `start2`) in `sim_burst_force.cpp` returned
results **byte-identical to the control**, which looked like "the FEC corrects it" — a comfortable and
completely wrong conclusion.

Signals probed, via Verilator flat-rw member access:
`CAT(RXP, u_QPSK_Demodulator__DOT__Delay9_out1)` (validOut) and `..._Delay10_out1` (startOut), where
`RXP = wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__`.

These **compile** but Verilator resolved them to members that are **not the live datapath signals** under
`--public-flat-rw`. Instrumenting the driver proved it: **`flips=0 validbeats=0 startbeats=0`** over a
24-frame run in which `startOut` must pulse 54 times. Every write went into a dead variable.

**This was the third uninstrumented measurement in this campaign to nearly report something comfortable and
wrong** (the others: a witness counter that saturated on healthy traffic and would have "passed" a weak
gate; a scorer whose filename-slice key collision printed "missing data" on a run that had actually passed).
**Rule for the fresh session: an injector or witness must prove it fired — count the events and print the
count — before any null result means anything. Use hierarchical references from the wrapper, never flat-rw
member-name guessing.**

---
## 4. THE TAPPED HARNESS (built and working — reuse it, do not rebuild from scratch)

Precedent to copy: `jupiter_240k5_byte/rtl_sim/wrap_byte_taps_e5.v`, which taps with Verilog **hierarchical
references from the wrapper** (`assign ssV = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Symbol_Synchronizer_validOut;`).

Already written and building clean:
- `jupiter_240k5_byte/rtl_sim/wrap_byte_fec.v` — copy of `wrap_byte_bf2.v` plus four tap ports:
  `fecStartIn` (= `dut.u_Receiver.u_QPSK_Rx.startSelInj`, what the FEC decoder actually sees as start),
  `demodStartOut`, `demodValidOut`, `fecBitsIn`.
- `jupiter_240k5_byte/rtl_sim/sim_fec_taps.cpp` — driver; argv `NF K prefix` (K = frame at which one
  spurious start is injected, 0 = none). Prints `FECTAPS ... totStarts= totValids= injected=` and writes
  `<prefix>_frames.txt` with `packet errors starts= valids=` per frame.
- Injection is **in RTL, not in C++**: `fixctl` **bit 4** decodes in
  `s1_rtl_pdwit/hdlsrc/commhdlQPSKTxRxLoopback/FixCtlDec.v` to `enSpurStart`, and a one-beat pulse is ORed
  into the FEC `startIn` in `QPSK_Rx.v` (`spur_pulse`, `startSelInj`). No new ports through the hierarchy.
- Build: `verilator --cc --exe --build -O2 -Wno-fatal --top-module wrap_byte_ce -Mdir obj_fectaps
  -y s1_rtl_pdwit/hdlsrc/commhdlQPSKTxRxLoopback -y . wrap_byte_fec.v sim_fec_taps.cpp -o Vwrap_byte_ce`
- Run: `./obj_fectaps/Vwrap_byte_ce 22 14 e5fix_ab/f_k14` (~20 min/run; ~7 s per simulated frame).

Netlist working copy: `s1_rtl_pdwit` = `s1_rtl_beatfix3` (the FLASHED lineage) + the beat witness inlined in
`FIFO.v` + `enSlack` (fixctl bit3) + `enSpurStart` (fixctl bit4). `diff -rq` against `s1_rtl_beatfix3` shows
exactly: FIFO.v, Validate_Input_Push_Pop.v, Preamble_Detector.v, Frequency_and_Time_Synchronizer.v,
QPSK_Rx.v, FixCtlDec.v.

---
## 5. PRE-REGISTERED PREDICTION AND FALSIFIER (for the SILICON test, not yet run)

**Prediction:** healthy operation is **exactly one start pulse per frame**; during a beat burst the counter
reads **2 per frame** (or one at the wrong position).
**Falsifier — report it dead, do not reinterpret:** if hardware shows exactly one start per frame straight
through a burst, the spurious-start model is wrong and dies there, the same way the delay-FIFO displacement
model died on 2026-08-30 00:22.
**Sim prediction already tested and CONFIRMED:** one spurious start costs a single frame of ~51–68 decoded
bit errors and then zero. (If a fresh session re-runs it and gets ~0 or end-of-frame corruption, the
hypothesis is dead — say so.)
**Instrument for silicon:** a start-pulse-per-frame counter. Far simpler than the FIFO witness. It needs a
Vivado build (~1 h on the proven injection path) and one flash. **NOT approved — ask Travis first.**

---
## 6. RIG STATE (as of 2026-08-30 10:35) AND STANDING RULES

- **148** (board A, forward RX): image `786dce9fafc8` = beat-witness build (in-FIFO witness read via the
  otherwise-unused `beatfix_viol` registers 0x20C/0x210; `fixctl` bit3 = FIFO slack, default OFF; at
  fixctl=0 it is behaviourally identical to probe-4). Daemon running, up ~10 h.
- **146** (board B, reverse RX): image `ec414d2df8bc` (v_endh). **Never flashed. Keep it that way unless a
  test truly requires it.** Daemon running.
- Link up on the shipped defaults (RXQ=1, fwd LO +20 k, rev LO +40 k). Sentinel running, "ok rate=1744/s".
  No `RIG_LOCK`, no `SENTINEL_STOP`.
- Restore points in `boot_known_good/`: `BOOT.BIN.148.probe4.02e8c97d6181` (the rollback for 148),
  `BOOT.BIN.148.pdwit.786dce9fafc8` (current), `BOOT.BIN.148.beatfix3.fe5bd8a4fe19`,
  `BOOT.BIN.148.lean.e49c011b7a75` (only image with a working IQ tap).
- **Standing rules:** ONE actor on the rig at a time (`sim_repro/riglock.sh`; note `rig_lock`/`rig_unlock`
  only match within the SAME shell, so take and release inside one script). Full rails for anything quoted:
  pre-flash health precondition, restore point banked, md5 readback, full bring-up, two-pass reset-aware
  health gate, auto-rollback, **no retry loops** — one failed flash ends rig work. **Never read modem
  registers while a board is arming** (that is the H-7 PS-hang class; use `sim_repro/no_arm_inflight.sh`).
  Long jobs as `systemd-run --user` units. **No flash without asking Travis.** Every PER claim needs the
  exact command, frame counts, drops in the denominator and CP95UL.
- **Killed hypotheses — do not revive:** delay-FIFO displacement / push-on-full (falsified on silicon across
  7 bursts and both fixctl arms: `occ=12333 diff=0 events=0 push_on_full=0` through 194k-error bursts);
  `fixctl` as a beat mitigation (inert on hardware AND in the model, all four orderings); the E5
  `Peak_Search` window patch as a beat fix (fixes a different failure mode, regresses under a disturbed
  loop); ByteRxFifo depth (no gain — wrong block); host TX batching `QPSK_TX_QUEUED` (violates the
  per-air-frame TLAST contract: 81–97 % bad).
- **Defects A and B are parked and MUST stay distinct from the beat work.** A: TX byte-in plane, netlist-only
  vulnerability that does not occur on silicon, no-RF floor 0.24 %, no build. B: RXQ=0-only 5.9 % loss
  between framesync and the ByteRxFifo push = host rate deficit under reset-per-transfer (absent at −M32),
  moot under the RXQ=1 default.

---
## 7. OPEN QUEUE (nothing here is started)

1. **Daemon-vs-ROM header discrepancy.** ROM-source loopback floor = 0.09 % of frames with a 51-bit event;
   daemon-source loopback floor = 0.24 % of frames with *garbage headers*. A 51-bit burst landing uniformly
   would hit the 12-byte header only ~0.8 % of the time, so these do not reconcile. Either the events sit at
   a fixed offset (frame start — which would also make them framing) or there is a second low-rate mechanism
   in the daemon path. **Unexplained; sharpest open question.** Needs error-position data (contiguous at a
   fixed offset = framing; scattered = bit errors).
2. **Mode-2 test (SSI near-end loopback).** Costs rig time only. Does the comb appear when the loop goes out
   to the ADRV9002 over LVDS and back, with no analog? Separates transceiver-digital from analog/RF.
3. **Mode-4 test (RF cable loopback on ONE board).** TX SMA → 30–40 dB attenuator → RX SMA, `0x114=1`, RX LO
   set equal to TX LO. **Pending Travis fitting a cable and attenuator.** If the comb appears here it is the
   transceiver/analog path and 146's transmitter is exonerated without ever involving 146.
4. **`fixctl` v1-vs-v3 model test.** v1 (`198ade9f234a`) reportedly gave zero BIST errors through six slots
   on 2026-08-21; v3 is inert both on hardware and in the model. v3 added an edge qualifier
   (`vEdge = vout && !voutPrev`) that v1/v2 lacked. The v1 netlist generation is **not in the tree**, so this
   needs it recovered before the comparison can be made.
5. **Sentinel recovery.** The one-line fix (`r=""` per loop iteration) plus a 3-attempt cap is **already
   applied and proven in an off-rig harness** (old: 8 probe failures → 0 recoveries; fixed: recovery fires
   after the 2nd consecutive failure; cap logs "operator attention" after 3). Remaining: nothing, unless
   Travis wants the cap removed.
6. **Loopback taxonomy correction already made:** all burst tests to date used mode 1 (FPGA-internal digital:
   `rx_input_select=0` selects `Transmitter_dataOutI/Q` directly, `TxRxComposite.v:679/735`). "RF excluded"
   means "the beat occurs with RF absent, therefore RF is not necessary" — NOT "RF was tested and found
   irrelevant".
