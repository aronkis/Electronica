# BUILD — HDL-Coder → BOOT.BIN for the K5 QPSK Jupiter modem

Authoritative, reproducible path from the MATLAB/Simulink model to a deployed
`BOOT.BIN` on an ADALM-Jupiter (ADRV9002) board. The canonical modem source kit is
[`jupiter_240k5_byte/`](../jupiter_240k5_byte/README_BYTE.md); the deployed image is
the **lean** build (`build_lean_image.sh`, md5 `dcf5c5fb`) — a debug-strip of P1E-v3
carrying `rxfix` + `resolver_lookback_fix` + the acquisition/tick fixes.

---

## Pipeline at a glance

```
 MATLAB / Simulink model  (commhdlQPSKTxRxLoopback.slx, DUT = .../TxRxComposite)
 assembled from overlays  (assemble_jupiter_240k5_byte.m: donor RD + byte/FEC overlays)
        │
        │  ── GATES (run_full_gates_t8.sh) ─────────────────────────────
        │      assemble → model oracle (sim_byte_gate_k5) → checkhdl+makehdl
        │      → golden byte vectors → S1B Verilator → S1 iverilog
        ▼
 HDL Coder "IP Core Generation" workflow  (hdlworkflow_loopback.m)
        │      → generated Verilog + packaged IP  (TxRxCompo_ip_v1_0.zip)
        │      NOTE: the RunTaskCreateProject task FAILS BY DESIGN (insert-path
        │            bug); the project is finished by the Tcl below.
        ▼
 Vivado completion  (complete_byte_t8.tcl)
        │      insert IP → wire 9 byte DUT↔breakout pins → stock DAC wiring
        │      → validate_bd → synth_1 → impl_1 (write_bitstream)
        ▼
 bootgen  (boot/zynq.bif: fsbl + pmufw + bl31 + u-boot + system_top.bit)
        ▼
 BOOT.BIN  →  deploy_image.sh <ip>  →  provision.sh <ip>  →  link_test.sh ber
```

**One command** builds the shipped **lean** image (the model→BOOT.BIN half):

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
setsid nohup ./build_lean_image.sh > build_lean.log 2>&1 </dev/null &   # ~2 h, detached
grep -E 'LEAN_IMAGE_DONE|LEAN_.*FAIL' build_lean.log                    # watch for the marker
```

`build_lean_image.sh` = **`QPSK_LEAN=1` gates → Vivado image → dual-DMA tap BD step**,
producing `jupiter_byte_lean_build/.../BOOT.BIN` and the line
`LEAN_IMAGE_DONE md5=<32hex> size=<n>`. This is the recipe that produced the deployed
`dcf5c5fb` (see [PROVENANCE.md](PROVENANCE.md)).

> The older `build_image.sh [TARGET_DIR]` builds the **pre-lean rxfix lineage** (no
> `QPSK_LEAN`, no tap step) and defaults `TARGET_DIR` to `jupiter_byte_rxfix_build` —
> kept for provenance, but it does **not** reproduce the shipped image; use
> `build_lean_image.sh`. Image md5 is not reproducible across Vivado rebuilds;
> equivalence is by the gates + BIST golden `cap_out=0x04922282`, not md5.

---

## Prerequisites (host)

| Need | Path / value |
|---|---|
| MATLAB | `/mnt/onetb/MATLAB/R2025b/bin/matlab` (HDL Coder + Simulink) |
| Vivado | `/tools/Xilinx/2025.1/Vivado/bin/vivado` |
| Verilator / iverilog | on `PATH` (S1B / S1 netlist gates) |
| ADI byte reference design (READ-ONLY donor) | `/home/tcollins/dev/qpsk_ai/TransceiverToolbox/hdl/vendor/AnalogDevices/+AnalogDevices/+jupiter/plugin_rd_rxtx_byte.m` ("JUPITER (RX & TX, BYTE DMA)") |
| ADI build env | `build_env_jupiter.sh` (ADI_* caches/jobs; **NO** `ADI_PERF_TIMING` — Jupiter closes at +2 ns, perf directives waste ~20 min) |

Device target: Zynq UltraScale+ `xczu3eg-sfva625-2-e`.

**Never modify the repo master** `/home/tcollins/dev/qpsk_ai` — it is the read-only
donor. All build work happens under `/mnt/onetb/scratch/qpsk-jupiter-modem/`.

---

## Step 1 — GATES (`run_full_gates_t8.sh`)

Six stages; strict (`set -e -o pipefail`, each greps its own PASS marker); prints
`FULL_GATES_T8_DONE`. `build_image.sh` runs this and additionally asserts the stamp
files say `result: PASS`.

| # | Stage | Entry | Stamp / marker |
|---|---|---|---|
| 1 | assemble the composite from overlays | `run_assemble_byte.m` | `ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK` |
| 2 | model-level byte oracle (4 runs: aligned / rotated / alt-PN / ROM) | `sim_byte_gate_k5.m` | `SIM_BYTE_GATE_K5.txt` (`result: PASS`) |
| 3 | `checkhdl` + `makehdl` → `s1_rtl/hdlsrc` | `checkhdl_gate_240k5_byte.m` | `CHECKHDL_240K5_BYTE.txt` |
| 4 | golden byte vectors | `gen_byte_vectors_k5.m` | `tx_words_golden.hex` |
| 5 | S1B byte netlist (Verilator, rot0 + rot17) | `sim_byte.cpp` → `s1b_analyze_byte.m` | `S1B_GATE.txt` (`result: PASS`) |
| 6 | S1 ROM-path (iverilog `tb_tx_240k5.v`) | `s1_analyze_240k5.m` | `S1_GATE.txt` (`result: PASS`) |

The oracles are the real safety net: stage 2 run C (alt-PN pad) proves the air comes
from the **in-fabric encoder fed by the bytes**, not a stuck ROM; the golden
`cap_out = 0x04922282` recurs throughout. Stages 5/6 prove the generated **netlist**
(not just the model) reproduces the golden air stream bit-exactly.

> Stage 1 re-assembles `commhdlQPSKTxRxLoopback.slx` in place, so `git status` will
> show the `.slx` (and the refreshed `*_GATE.txt` stamps) as modified. That is a
> re-assembly timestamp artifact, not a source change — do a **targeted** `git add`
> of only the files you intend to commit.

## Step 2 — IMAGE (`build_byte_image.sh TARGET`)

Four internal stages; output `TARGET/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`:

1. **Fresh kit copy** — `rsync` the kit → `TARGET` (excludes `hdl_prj_*`, `slprj`, logs).
2. **KITDIR repoint** — `sed` the kit's absolute paths in `*.m` from `KIT` → `TARGET`.
3. **MATLAB `build_variant_byte`** — `assemble_jupiter_240k5_byte.m` + HDL Coder IP-core
   workflow (`hdlworkflow_loopback.m`). **The `RunTaskCreateProject` task raises a MATLAB
   error — this is EXPECTED and benign** (an ADI `add_ip` insert-path bug). The build
   guards on the real artifacts instead: `vivado_prj.xpr` exists, `TxRxCompo_ip_v1_0.zip`
   exists, and the block design contains `byte_breakout` (else "wrong reference design").
4. **Vivado completion** — `complete_byte_t8.tcl`: insert the packaged IP, wire the 9
   byte DUT↔breakout pins (`BYTE_WIRE_OK`), keep stock DAC wiring (no "gather"),
   `validate_bd`, `launch_runs synth_1` → `impl_1 -to_step write_bitstream`, then
   `bootgen -arch zynqmp -image zynq.bif -o BOOT.BIN`. Prints `BYTE_IMAGE_BUILD_DONE md5=…`.

`zynq.bif` packages the PS boot chain with the PL bitstream: `pmufw.elf`, `fsbl.elf`,
`system_top.bit` (destination_device=pl), `bl31.elf`, `u-boot.elf`. There is **no XSA/HDF
export** — the flow goes Vivado project → `write_bitstream` → `bootgen` directly.

> **md5 is NOT reproducible across rebuilds.** Vivado place/route and `bootgen` embed
> timestamps and non-deterministic placement, so a functionally-identical rebuild
> produces a *different* `BOOT.BIN` md5. Equivalence is established by the **gates**
> (green) and the on-chip **BIST golden** (`cap_out = 0x04922282`), not by md5 equality.
> Record each build's md5 in [`PROVENANCE.md`](PROVENANCE.md).

---

## Step 3 — DEPLOY (three explicit steps, board-side)

Jupiter has **no remote power**: a bad flash = physical reflash+reboot only. The flash
is size-checked and backed up.

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
./deploy_image.sh 10.0.0.148                                      # 1. flash board A (size>6MB, backs up .pregeneric) + reboot + wait
./deploy_image.sh 10.0.0.146                                      #    then board B, one at a time
./provision.sh 10.0.0.148 && ./provision.sh 10.0.0.146           # 2. install qpsk_tun + lvds + watchdog (fresh board only)
./link_test.sh ber -d 90                                         # 3. acceptance: OTA -B BER both directions + rstcs
```

- **`deploy_image.sh <ip> [BOOT.BIN]`** — the generic flash tool (defaults to the lean
  image; pass a path or set `$BOOT` for another). Backs up the current `/boot/BOOT.BIN`
  → `/boot/BOOT.BIN.pregeneric`, stages to `/root` with a size re-check, then `cp` +
  `sync` + `reboot` + waits for the board back. Flash **one board at a time**. (The
  frozen `deploy_pifix.sh`/`deploy_rxfix.sh`/`deploy_tap.sh`/`deploy_ch2.sh` are
  image-specific variants kept for provenance.)
- **`provision.sh <ip>`** — installs the files `link_test.sh preflight` requires but the
  flash does not: builds `qpsk_tun` on-board from the `host_app_k5` sources, and copies
  the LVDS profile + watchdog. Only needed on a **fresh/wiped board** (a BOOT.BIN reflash
  leaves `/root` intact) or whenever `preflight` reports a missing file. Wait for the
  reboot to finish first; compiling on-board is safe (never arms/DMAs).
- **`link_test.sh ber`** — reads `-B` BER + `rstcs`/`cfc`/`level`/rssi to confirm health.

After deploy+provision, verify with `./link_test.sh preflight` (both boards PASS).
See [TESTING.md](TESTING.md) for the full acceptance ladder.

---

## The two fixes in the shipped image

| Fix | Where | Effect |
|---|---|---|
| **CFO reset-storm ("rxfix")** | `commhdlQPSKTxRxParameters.m:45` — `CFOChangeDetectThreshold = 0.0125` (was `0.0015625`) | ±5577 Hz deadband; kills the ~52/s false carrier-loop reset (`rstcs` 52/s→0, frame yield 40%→93.5%) |
| **Phase-ambiguity resolver** | `resolver_lookback_fix` (git `8033363`), integrated by `assemble_jupiter_240k5_byte.m` | preamble-based full-quadrant resolution → byte plane carries **arbitrary** data (99.9% HW), not golden-only |

Both are in the source kit and the shipped `BOOT.BIN` (md5 `dcf5c5fb…`).

## Troubleshooting

| Symptom | Cause / action |
|---|---|
| MATLAB error at "Create Project" | **Expected/benign** — the Tcl finishes the project. Only a real failure is `FATAL: no vivado project produced` (guarded). |
| `FATAL: BD has no byte_breakout` | Wrong reference design — the ADI byte RD wasn't applied. Check the HDL Coder `ReferenceDesign` = "JUPITER (RX & TX, BYTE DMA)". |
| A gate stamp not `PASS` | Do not build. Re-run `run_full_gates_t8.sh` and read the failing stage's `.txt`/`.out`. |
| Rebuild md5 ≠ shipped `dcf5c5fb` | Normal (Vivado non-determinism). Validate functionally: gates PASS + BIST golden. |
| Board won't boot after flash | Restore `/boot/BOOT.BIN.prerxfix` (the backup) via reflash; no remote power. |
