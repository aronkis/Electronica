# Session state — 2026-08-28 07:00 handoff (overnight campaign; RESULTS SECTION FILLED AS THEY LAND)

Read `SINGLES_CAMPAIGN.md` (dated sections 08-27) for evidence; this file is
the decision queue. Standing goal (PER < 1 % both directions, ARQ off): NOT
MET. Forward best measured **8.73 / 8.89 %** (queued mode, shipped); reverse
**1.39 %** (queued mode + the +40 kHz LO default shipped tonight; residual = E5
tracking defect in the signal). Under simultaneous bidirectional load: fwd
8.7–10.4 %, rev 1.8 %.

## Shipped today (stand on their own, no flash)

1. **Queued RX mode default** (`bringup_r2r3.sh` RXQ 0 → 1): 13.93/13.98 % →
   8.73/8.89 % forward, same protocol, 4 legs; verdict doc
   `QUEUED_RX_MODE_VERDICT.md`. Reversible with `RXQ=0`.
2. **148 no-ping hang root-caused + guarded**: nemo-side `direct_reg_access`
   read during the ADRV9002 profile reload hangs the PS (known on-board
   hazard since 08-04, never guarded on the host side). Guard =
   `sim_repro/no_arm_inflight.sh` on every reader + single-actor
   `RIG_LOCK` (`sim_repro/riglock.sh`). Clean arms under the guard: 9+, zero
   hangs since 20:25 on 08-27 (scorecard in the fault doc). `RIG_NOPING_FAULT.md`.
3. Sentinel fixed (log path, systemd unit + keeper, post-reboot recovery);
   fan-control gpio base fixed on both boards (334 → 516).
3b. **Reverse LO default +2.5 kHz → +40 kHz** (7-point sweep, 1.391 % / CP95UL
   1.469 vs 1.994 % / 2.088; `bringup_r2r3.sh`, reversible via LO_B_RX).
3c. **Daemon delivery watchdog fixed** (H-6; `qpsk_tun.c` 5b6eea0, deployed both
   boards 03:55, accepted: no spurious re-arms on the idle link).
4. Forward comb root-caused (E9): 64-word ByteRxFifo overflow at every S2MM
   transfer boundary (16 frames @ -M16). Fix = 4096-word BRAM FIFO, image
   `e09fdb32e375`/v3 (`boot_known_good/BOOT.BIN.148.rxfifo4k.*`), sim-gated;
   **silicon status: see results** (attempt 3 delivered zero bytes; v3 adds
   a BRAM read/write-collision bypass).

## Overnight results (filled in by the campaign)

- Track A (FIFO diagnostic flash): v3 rejected at build (LUTRAM); **v4 (e45df7741369, WNS +0.230, BRAM 66.5) flashed under the rails: ARM GATE PASS, then 10-s census = packets 5046 / words 0 / overflow +879,462 → words enqueued, never accepted (handshake side)**; rolled back. No 4th flash overnight. **v5 DEBUG image built: `602b26c25c35`** (banked in boot_known_good, BRAM 66.5, timing met) — one approved diagnostic flash + one 0x1B0 read pins the dead side (bit map in the ledger 04:04). FIFO A/B NOT MEASURED.
- Track B (reverse LO sweep): default +2.5k 1.994 % (CP95UL 2.088) | −20k 1.599 % (1.683) | +20k 1.778 % (1.867) | **+40k 1.391 % (1.469)**; +60k wedged, +80k 1.750 % (1.838), −40k 1.485 % (1.582). **SHIPPED: reverse default LO_B_RX +2.5k → +40k** (CP95UL 1.469 vs 2.088). Reverse now 1.39 %.
- Track C (E5 localisation): DONE — the deletion episode is Peak_Search reporting a +32 false timingOffset (frames 36/47 at −15k; never at +15k); on captured IQ the offset tracks the strobe deficit exactly (4546 → 4518 after the −28 mute). Peak_Search is a free-running 0..12332 symbol counter latched at the correlation peak; fix target = its early-peak/wrap handling (RTL patch + existing ±15k and captured-IQ A/B is the morning item; harness `wrap_byte_taps_e5.v` ready).
- Track D4 (bidirectional): **SURVIVED 236 s both ways** (fwd 10.37 % CP95UL 10.48; rev 8.05 % CP95UL 8.15) under the single-actor/guarded protocol — the 4 earlier collapses are no longer considered intrinsic to the load (N=2: repeat 01:06 — fwd 8.68 % wedge-truncated at 55 s, rev **1.79 %** with the new +40k default; no collapse either time).
- Rig state 03:55 (verified after the v2 daemon deploy): 148 on **fe5bd8a4fe19** (readback), fsync 1256 / wcnt 1256 (12/12 clean); 146 v_endh ec414d2df8bc, 1261/1261 (12/12); daemons = H-6 v2 build (5b6eea0); defaults RXQ=1, LO_A_RX +20k, LO_B_RX +40k; sentinel keeper-managed and guarded; no rig work queued after this point (v5 DEBUG build is offline).

- Track D2 (H-6 wedge snapshots): two real snapshots read. (a) Delivery-plane wedge
  (13:23): watchdog-invisible by design; the daemon's own delivery watchdog was
  neutralised by a completion stamp — fixed (v1 03:00 was wrong on an idle link and
  was retracted; v2 5b6eea0 deployed 03:55 and accepted). (b) Post-reboot reset
  storm (20:55): the on-board watchdog detects it but its fabric re-arm cannot
  clear it (needs the profile reload) — escalation is a morning script change.

## Decision queue for the operator

1. **FIFO image (E9 fabric half)**: approve ONE diagnostic flash of the v5 DEBUG
   image `602b26c25c35` (built, banked) — a single 0x1B0 read
   after the arm shows rdyRun / ready_1 / valid_i / raw ready / pointers and
   pins the dead side (suspect: my 2-cycle-later `valid` vs the DMAC's tready
   window; fix would be same-cycle valid via the original's `nxt != rd`
   compare on a registered-read RAM, i.e. a 1-word prefetch). Rails as before.
2. **Reverse default +40 kHz**: shipped on a 7-point single-leg sweep; a 3-leg
   confirmation at +40k vs +2.5k is the cheap follow-up (≈10 min rig).
3. **E5 fix**: Peak_Search early-peak/wrap handling — RTL patch + the existing
   ±15k/captured-IQ A/B harness (`wrap_byte_taps_e5.v`); no image needed to
   validate the mechanism.
4. **Bidirectional**: no longer collapses under the guarded protocol (N=2);
   reverse under load 1.79 %, forward 8.7–10.4 % — the forward comb is now the
   dominant term in every mode; the FIFO is the lever.
5. Hardware: attach a serial console to 148 (tron ttyUSB1 serves neither
   Jupiter; HOSTS.md ttyACM0 stale); TX-side ByteWordBuffer (16 words) follow-up.

## Traps (do not re-learn)

- Never read modem/ADC-core registers on a board while it is being armed.
- Plain `setsid nohup` children die with the session; use `systemd-run --user`.
- Never key automation on log tokens that persist across runs (`CHAIN_STOP`).
- `pgrep -f` with the pattern in your own command line matches yourself.
- zsh: a failed glob aborts the whole command line (`rm -f a.* b` runs nothing).
- Reverse captures need the 148 TX map `[2 0 1 3]`; forward per-capture
  (`[1 3 2 0]` / `[3 2 0 1]`) — calibrate by float CRC per capture.

## 07:01 UPDATE — FIFO A/B done (read this first)
- v5 FIFO image works on silicon but gives **no PER gain** (RXQ=0 14.18/14.14 % vs 13.93/13.98; RXQ=1 8.63/8.63 vs 8.73/8.89). E9 mechanism corrected: DMAC `SYNC_TRANSFER_START` discard at every transfer handoff (tready high), FIFO depth irrelevant. See SINGLES_CAMPAIGN 07:01.
- **Decision 1 (new):** 148 is on v5 `602b26c25c35` (healthy, equivalent). Roll back to `fe5bd8a4fe19` or leave — your call; I did not reboot it.
- **Decision 2 (new):** approve Option E build — fabric gates `tuser` by a `byte_ctrl_gpio` bit (like TLAST), host syncs the first transfer then disables sync; keeps the 4096 FIFO. Expected to remove the ~1 frame/boundary comb (≈6 pp at −M16) — the first credible path to forward < 1 % together with −M32.
- Rig released 07:00:38; sentinel running (ok 1153/s); locks clear.

## 17:05 UPDATE — end of the 08-28 day campaign (read this first)
- Delivery plane (DMAC/DDR/host) exonerated for well-formed frames: injector matrix 0 lost of 4×70k; real-DMAC sim 0 %.
- Forward comb = two defects: (A) TX byte-in plane, ~5 % no-RF, netlist-proven ByteWordBuffer starvation mid-transfer; trigger not host silence (witness), host batching invalid. (B) RXQ=0-only 5.9 % = host rate deficit, RX FIFO full — explained, moot with RXQ=1.
- FIFO-4k image: no gain (confirmed twice). Test B (TGEN TX) withdrawn (format mismatch).
- Rig: 148 on probe-3 `686ac144563d` (v5 FIFO + injector v2 + witness + decoder-output CRC checker); both boards run the daemon with the `txgap` line (legacy behaviour, batching off); RXQ=1 default; link up, released, sentinel running. 146 never flashed. Rollback binaries `qpsk_tun.pre_txq`.
- Decision queue: (1) approve the in-fabric ByteWordBuffer underrun witness build (~2 h, instrument only); (2) after its numbers, the sized fix build (both boards' images eventually — 146 needs a flash policy decision); (3) reverse leg 1.39 % unchanged; E5 patch still pending.
- Traps today: sed -i on live logs; pkill -f self-match; smartconnect M17+ bus error; -DQPSK_CARVE_2MB; TGEN 191- vs 385-word format.
