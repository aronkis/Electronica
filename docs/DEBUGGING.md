# DEBUGGING — symptom → cause → action

Operational triage for a live two-Jupiter link. Start here when something looks
wrong; follow the pointers for depth. For the architecture see
[ARCHITECTURE.md](ARCHITECTURE.md); for terms [GLOSSARY.md](GLOSSARY.md); for the
full root-cause case histories the deep log is
[`../two_jup/ERROR_TAXONOMY.md`](../two_jup/ERROR_TAXONOMY.md).

> The **acceptance ladder** (host loopback → on-chip BIST → OTA `-B` → real data)
> lives in [BRINGUP.md §5](BRINGUP.md) — run it first to localize *where* in the
> chain the problem is. This doc is for interpreting what you see.

## First: what "healthy" looks like

| Signal | Where | Healthy |
|---|---|---|
| `cap_out` (`0x144`) | `measure_ber.sh` / BIST | **`0x04922282`** |
| `packets_out` (`0x104`) | any reg read | **advancing** (≈212/s locked) |
| `rstcs` (`0x150`) delta | `link_test.sh ber` | **~0** over the run |
| `-B` bucket mix | `link_test.sh ber` | CLEAN ≫ PHASE/MISS; reverse ~2e-6, forward ~1.4e-4 |
| tap mux (`0x10C`) modes 0-3 | `tap_smoke.sh` | non-zero RMS on each mode |

## Symptom → cause → action

| Symptom | Likely cause | Action |
|---|---|---|
| **Never locks** (`frames_scored=0`, `packets_out` flat) | Acquisition wedge, or peer not radiating | Run the **verified-lock loop** (BRINGUP §3): watchdog → probe `-B` → if 0 aligned, pulse CS-reset `0x110` 1→0, re-arm byte DMA (`devmem 0x9D300000 32 0x1`), retry ×3. Confirm the peer is running `-B` (a parked peer transmits idle filler → every frame PHASE). ~1/3 of cold arms need one retry — this is expected stochastic acquisition, already automated by `exp_forward.sh`. |
| **All frames PHASE / ROTATED** | Quadrant mis-lock (phase-ambiguity), or tracking cals mis-converged | Redo verified-lock (BRINGUP §3). Confirm you did **not** enable ADRV9002 `quadrature_w_poly/fic/rfdc` tracking cals at arm — they scramble the constellation past the resolver's one-time lock (BRINGUP §2). |
| **`rstcs` (`0x150`) growing fast** | CFO-step reset storm = **wrong/old image** (pre-`rxfix`) | You are not on the shipped image. Reflash the lean image (`deploy_image.sh`), then `provision.sh`. `rxfix` keeps `rstcs`≈0. |
| **`cap_out` ≠ `0x04922282`** on BIST | Wrong image, or not locked to the ROM source | Confirm `tx_data_source` (`0x158`) = 0 for BIST; confirm image md5 vs [PROVENANCE.md](PROVENANCE.md). A stable wrong `cap_out` (e.g. `0x231d481c`) = the historic pre-resolver quadrant bug — you are on a pre-`8033363` image. |
| **Forward BER floored ~1.4e-4, periodic MISS ~0.4%** | The **BBDC "tick"** on unit 148 (device-side, ~1.5 s) | Expected on 148; not fixable in fabric (already compensated to the mosaic floor). This is the vendor/RMA item — see [`../two_jup/ESCALATION_ADI.md`](../two_jup/ESCALATION_ADI.md). Do **not** chase it with HDL. |
| **High BER but no tick pattern** | Thin link budget / SNR, or Rx AGC stepping mid-frame | Pin the Rx gain after lock (BRINGUP §4, `spi` mode). Check `rssi`/`level` (`0x15C`). Re-survey the quiet-pair frequency for your hardware (PORTING.md). |
| **Board unreachable after flash** | Boot in progress, or bad image | Wait ~30 s for boot. If >5 min, a physical power-cycle is required (Jupiter has **no remote power**). If the image is bad but boot works, roll back: `cp /boot/BOOT.BIN.prelean /boot/BOOT.BIN; sync; reboot`. |
| **Tap dead (`tap_smoke` RMS=0)** | Provision/image mismatch, or lean image (state-pairs stripped) | The lean image keeps mux modes 0-3 (`0x10C`) but **strips** state-pairs `0x160-0x16C` — that's expected (`LEAN=1 tap_smoke` skips them). If mux modes are also dead, the dual-DMA tap BD step was skipped in the build. |
| **Link up but `tun0` ping fails / SSH garbles** | Whitener mismatch, or MTU/route | The host whitener (`QPSK_WHITEN`) must be set the **same on both ends** — low-entropy payloads get RF-corrupted without it. Confirm MTU 116 / advmss 56 (set by `coldstart_tun`). See [LINK_CHARACTERIZATION.md](LINK_CHARACTERIZATION.md). |
| **Rx S2MM capture wedges the board** | >512 KB modem-S2MM DMA capture | Never do that. Use the **Tap-A `iio_readdev`** path for captures (safe). Recovery = power cycle. |

## How to observe (the taps)

- **Register reads** (all `0x1NN`): the full map is in [ARCHITECTURE.md](ARCHITECTURE.md#register--tap-map-code-verified).
- **IQ taps** (`0x10C` mux → 2nd rx-DMA channel): `0` AGC-out, `1` post-SS, `2` post-CS, `3` constellation. Use `tap_smoke.sh` to exercise them; a stage that's flat-zero while upstream flows localizes a wedge (e.g. post-SS frozen = symbol-sync wedge, ARCHITECTURE/ERROR_TAXONOMY Class 4).
- **Offline forensics:** capture via `capture_paired.sh` (archived), replay bit-true with `jupiter_240k5_byte/rtl_sim/replay_capture.sh`, ideal-float decode with `k5_240/decode_ref_k5.m` (CFO search ±15 kHz — never narrow it).

## The error taxonomy (deep dives)

The running root-cause log [`../two_jup/ERROR_TAXONOMY.md`](../two_jup/ERROR_TAXONOMY.md)
classifies every failure mode seen in the campaign — use it as the case-history
reference behind the table above:

| Class | What | Status |
|---|---|---|
| **Class 1** | Steady-state periodic loss = the BBDC tick episodes (~1.5 s) | Compensated in fabric to the mosaic floor; source is device-side (ESCALATION_ADI). |
| **Class 2** | Between-episode residual scatter | Forward ~1.8e-5 (under target). |
| **Class 3** | Rare air-level frame mangling | Rare; some are capture-side drops during Class-1. |
| **Class 4** | Acquisition wedge (bring-up, not steady-state) | Deterministic timing-loop wedge **fixed** (`timing_hardening`); residual ~1/3 retry is stochastic SNR-margin, auto-handled by `exp_forward.sh`. |

Related deep logs: `ESCALATION_ADI.md` (the BBDC tick, vendor package),
`FLOAT_FIXED_CAMPAIGN.md` (float-vs-fixed method + case history). Historical
analyses are under [`../two_jup/archive/`](../two_jup/archive/).
