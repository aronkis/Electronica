# boot_known_good — banked BOOT.BIN images for the two-Jupiter rig

Canonical bank of the load-bearing boot images (ADALM Jupiter, ZynqMP, f1536 /
61.44 MSPS byte-plane modem). Filenames carry board + lineage + md5-12; verify
against `MD5SUMS` before any flash. All images 7,203,552 bytes, bootgen
`-arch zynqmp -w`. Evidence for every claim: `two_jup/SINGLES_CAMPAIGN.md`
(dated sections) and `two_jup/NETLIST_PROVENANCE.md`.

## 146 (10.0.0.146 — TMR lineage, byte-plane TX under study)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.146.tmr.433fd8dab393` | `433fd8dab393` | The long-standing 146 TMR image. Best measured overall: saturated 10.62% / idle 9.33% (2026-08-25 A4 ladder, stock LO). Rail census DEFECT (ebbf4eb signature) yet outperforms census-CLEAN draws. |
| `BOOT.BIN.146.tmrfresh.4be9286ca111` | `4be9286ca111` | Fresh-placement TMR rebuild (A1/A2 gates PASS incl. tmr_attr_inject). Saturated 13.76% / idle 9.65%. **Currently flashed on 146.** |
| `BOOT.BIN.146.vendh.ec414d2df8bc` | `ec414d2df8bc` | v_endh placement variant (ExtraNetDelay_high; best timing margins of the six banked variants). Saturated 11.46% / idle 13.02% (single-window; burst caveat). RTL-identical to tmrfresh by construction. |
| `BOOT.BIN.146.txfixF3vendh.6b4744ca73f8` | `6b4744ca73f8` | TXFIX F3 on the 146 lineage: fix build from source kit jupiter_byte_tmr146_build via txfix_inject.py, fetched from hdl-dev-2 kit jupiter_byte_txfixF3vendh_build. **PROVENANCE — read before treating this as a vendh successor: this is tmrfresh RTL (`4be9286ca111`) + F3, RE-SYNTHESIZED, placed `ExtraNetDelay_high` — it is NOT built on vendh's checkpoint.** `ec414d2df8bc` has no RTL of its own: it was a `copy_run` off jupiter_byte_tmr146_build's `synth_1` differing only in that place directive (`vivado_prj.runs/v_endh/system_top.tcl:221`), and injecting the F3 patch invalidates that checkpoint, so only the DIRECTIVE carries forward — the vendh placement, and the byte-plane margins that made v_endh rank 1 in the 2026-08-25 placement study (BP_SETUP 1.847 / CE_SETUP 3.944), are NOT reproduced here. Routed WNS +0.193 ns, TNS 0; post-synth modem WNS 2.874 ns; no IMPL_STRATEGY (explore would have overwritten the place directive). Any PER comparison against the `ec414d2df8bc` baseline confounds the F3 fix with a fresh placement, and placement alone moved 146's legs >2 pp on 2026-08-26. **BUILT, NOT flashed, sim gate pending.** **FLASHED on 146 2026-09-03 15:06 (re-run after a stale-daemon-fingerprint rollback at 15:04); readback OK, both-board bring-up + reset-aware health gate PASS (fsync=1259 wcnt=1259); currently flashed on 146. Rollback bank vendh ec414d2df8bc (on-board .bak created+verified).** |
| `BOOT.BIN.146.seqbist.3378861d30bd` | `3378861d30bd` | SEQ-BIST on the 146 vendh lineage: source kit `jupiter_byte_txfixF3vendh_build` (flashed image `6b4744ca73f8`) + BD patch `patch_seqbist_tcl.py` @ d9bed75 (lineage vendh, `WITH_CRC=1`): adds the WHOLE instrument chain the 146 BD lacked - `qpsk_traffic_gen_v2`, `rx_seq_checker`, `cnt_mux32` and three axi_gpio at 0x9D400000 / 0x9D410000 / 0x9D450000 (NUM_MI 11->14); slots 0-15 read 0 on this lineage. `IMPL_STRATEGY` UNSET, place directive `ExtraNetDelay_high` preserved, routed WNS +0.166 ns / TNS 0. NOTE: this image is "tmrfresh + TXFIX-F3 + SEQBIST @ ExtraNetDelay_high", **not** v_endh - do not quote v_endh byte-plane margins for it. **BUILT, NOT flashed, sim gate pending.** |

Note (2026-08-26): the comb is CFO-sign-asymmetric and requires cross-board
clocks; per-image PER deltas may be receiver-side sensitivity — see
`two_jup/KNOWN_HOLES.md` H-1/H-3 before spending flashes on placement draws.

## 148 (10.0.0.148 — RX/tap board)

| file | md5-12 | what it is |
|---|---|---|
| `BOOT.BIN.148.beatfix3.fe5bd8a4fe19` | `fe5bd8a4fe19` | BEATFIX v3 (fixctl@0x208, viol counters 0x20C/0x210; tgen + beat-ILA instruments). **Currently flashed on 148**, fixctl=3 armed. CAVEAT: the rx-lpc IQ capture tap is STRUCTURALLY a ramp on this lineage — no IQ captures possible. |
| `BOOT.BIN.148.lean.e49c011b7a75` | `e49c011b7a75` | 08-13 lean image. WORKING IQ tap (the only image that can feed the float/BER oracles). No BEATFIX/fixctl. The standing rollback bank for 148 flashes. |

## Deployment (all scripts tracked in `two_jup/`)

- Flash under full rails (md5 precondition, on-board + repo rollback banks,
  readback verify, full bring-up, two-pass reset-aware health gate
  fsync>=1100 AND wcnt>=1100 on 148, auto-rollback, NO retry):
  - 148: `two_jup/skidfix/flash_148_beatfix2.sh <md5-12>`
  - 146: `two_jup/skidfix/flash_146_vendh.sh <md5-12>` (carries the 2026-08-26
    rails amendment: pre-flash 148 liveness/health precondition; adapt BB/
    BAK_MD5 header vars per target image), also `flash_146_tmrfresh.sh`,
    `flash_146_rollback433.sh`
- Bring-up / restore: `two_jup/restore_known_good.sh` (full both-board restore:
  profile arm, ROM double-tap, stream-first byte flip, daemons, watchdogs),
  `two_jup/bringup_r2r3.sh r3`. Forward RX LO default is +20k off-null
  (2026-08-26, comb 13%->6%), env-overridable via `LO_A_RX`.
- Health: `two_jup/health_probe_reset_aware.sh <ip> 12` (the trusted probe).
- Watchdog: `two_jup/lock_watchdog.sh` (hardened build, deployed to
  `/root/lock_watchdog.sh` on both boards; restart via ISOLATED ssh calls).
- Flash discipline: stop the nemo sentinel first
  (`touch ~/modem-status/SENTINEL_STOP`), relaunch after; one flash event per
  board per session unless operator-gated; rollback flashes end the lane.

`MD5SUMS` in this directory is authoritative — `md5sum -c MD5SUMS` before use.

## BOOT.BIN.148.rxfifo4k.e09fdb32e375 (added 2026-08-27)

BEATFIX v3 (`fe5bd8a4fe19`) with exactly one module replaced: `ByteRxFifo`
deepened from 64 words (K5-era sizing, ~0.25 ms of S2MM backpressure cover
at f1536) to 4096 words in block RAM (17.2 ms cover). Built by Vivado
resynthesis of the fe5bd8a4fe19 tree (`jupiter_240k5_byte/rxfifo_inject.sh`
+ `build_rxfifo_image.sh`); routed timing all constraints met (WNS +0.073 ns),
BRAM tiles 59 → 66.5, registers/LUTs lower than the base image. Sim-gated
(Verilator, real air data: 0 frames lost at 0.41/1.22/8 ms per-transfer
stalls vs 10/20/105 on the base image). Same instruments as BEATFIX v3
(fixctl@0x208, tgen, beat-ILA); the ByteRxFifo overflow counter stays at
AXI 0x1B0. A/B verdict vs the base image: see `two_jup/SINGLES_CAMPAIGN.md`
2026-08-27. Rollback = `BOOT.BIN.148.beatfix3.fe5bd8a4fe19`.

### Status update 2026-08-28 (FIFO images)

`BOOT.BIN.148.rxfifo4k.e09fdb32e375` (v2) and the later v4 (`e45df7741369`, not
banked) both boot, arm cleanly and pass readback/fingerprint, but **deliver no
bytes on silicon** (diagnostic census: demod packets advancing, 0x1C0 accepted
words frozen, 0x1B0 overflow climbing at the full word rate — words enqueued,
never accepted). Do not deploy either for traffic. A v5 DEBUG variant exposing
the handshake state on 0x1B0 is built for one more diagnostic flash. Rollback
for 148 remains `BOOT.BIN.148.beatfix3.fe5bd8a4fe19`.

`BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35` (2026-08-28): v4 FIFO + handshake
state on AXI 0x1B0 ({rdyRun[7:0], ready_1, valid_i, ready, stateControl, enb,
nonempty, byp_sel, ovf!=0, wr[7:0], rd[7:0]}) — DIAGNOSTIC ONLY; one approved
flash + one register read localises why the BRAM FIFO delivers no bytes on
silicon. Not for traffic. Rollback `BOOT.BIN.148.beatfix3.fe5bd8a4fe19`.


2026-08-28 07:01: `BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35` boots, gate-passes and delivers (14.1 %/8.6 % = same as comb image). Safe for traffic but NOT the default; 0x1B0 is a debug word on it. Default remains `BOOT.BIN.148.beatfix3.fe5bd8a4fe19`.
| `BOOT.BIN.148.ddrcap2.638b36de3493` | `638b36de3493` | DDRCAP-v2: joint tOff/markers/sidecar record + sel12-15 (spec 2026-09-02). Built from txmark tree + ddrcap2_inject. **FLASHED on 148 2026-09-02 17:27, verified in place 17:42 (gate x2 golden, witness decoded; §81). Currently flashed on 148.** Rollback bank: txmark 1cd0cd752aa6 (on-board copy verified). |
| `BOOT.BIN.148.txfixF3.f6a8c3ea119c` | `f6a8c3ea119c` | TXFIX F3: fix build from jupiter_byte_ddrcap2_build (DDRCAP-v2 instrument unchanged) via txfix_inject.py, fetched from hdl-dev-2 kit jupiter_byte_txfixF3_build. **FLASHED on 148 2026-09-03 12:36 under full rails; GATE_PASS x2 (fps=1248, capTAP golden); 420-row 0x108 timeline BURSTS n=0; 512 MB sel6 witness stalls=0, 5,449/5,449 frames at offset 0. VERIFIED — the 120.2 s beat is absent (within §91's claim boundary: 792 s 0x108 timeline + 4.4 s content witness + two phase-timed 4.4 s witnesses at ARM_OK+76/+196 s, 2026-09-03). Currently flashed on 148. Rollback bank: ddrcap2 638b36de3493 (on-board .bak verified).** |
| `BOOT.BIN.148.txfixF2.5e3f58955f02` | `5e3f58955f02` | TXFIX F2 (= F1 + saturating frameCount, no fullRAM throttle): attribution build, routed WNS +0.056 ns, IMPL_STRATEGY=explore. **BANK-ONLY by ruling 2026-09-03 12:57 — NOT flashed, not to be flashed (F3 passed; sim G12 shows F2 keeps the fullRAM runaway).** |
| `BOOT.BIN.148.seqbist.a1ff3c876d91` | `a1ff3c876d91` | SEQ-BIST on the TXFIX-F3 lineage (148): source kit `jupiter_byte_txfixF3_build` (flashed image `f6a8c3ea119c`) + BD patch `patch_seqbist_tcl.py` @ d9bed75 (lineage 148, `WITH_CRC=1`): adds `rx_seq_checker`, `cnt_mux32` (16 new counter slots 16-31), swaps `traffic_gen` -> `qpsk_traffic_gen_v2` (skip_every / corrupt_every). Built on hdl-dev-2 from kit `jupiter_byte_seqbist_build`, `IMPL_STRATEGY=explore`, routed WNS +0.112 ns / TNS 0. **BUILT, NOT flashed, sim gate pending.** |
