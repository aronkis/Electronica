# DDR Raw Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the raw 16-bit I/Q of any selected datapath block into DDR, alongside the demodulator's and the FEC decoder's frame markers, so the "did the marker move or did the values change" question can be answered directly.

**Architecture:** Repoint the idle `util_adc_2_pack` → `axi_adrv9001_rx2_dma` → DDR chain at a widened debug mux inside the modem IP. Four packer channels carry: selected block I, selected block Q, demod frame marker, FEC frame marker. Runtime block selection via the existing `iq_debug_mux` register at 0x10C. Captures read back through the standard libiio buffer on `axi-adrv9002-rx2-lpc`.

**Tech Stack:** Verilog (modem IP, source edits), Vivado 2025.1 block design + MATLAB HDL Coder flow, Verilator (sim gates), Python 3 + pytest (analysis), libiio (host capture).

**Spec:** `docs/superpowers/specs/2026-08-31-ddr-raw-capture-design.md`

## Global Constraints

- **Board 148 only may be flashed. 146 is never flashed or touched**, except by the standard gated restore.
- **No retry loop.** A flash failing after touching the board ⇒ roll back, write `RIG_HALT`, stop.
- **Full flash rails:** restore point banked and named, readback verify, two-pass health gate, auto-rollback. Query the live `BAK_MD5` with `two_jup/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'`; pass `BB` as an ABSOLUTE path.
- **§0 positive control:** no witness produces a null until shown capable of a non-null. This applies to the capture path itself (Task 5).
- **Rig access is serialised** by `two_jup/agents/rigmutex.sh`. Acquire before any hardware step; never export a temp `RIG_DIR` in a shell that touches the rig.
- Markers are full 16-bit words (`0x0000` / `0x7FFF`), never packed bits — a dropped strobe reads as a lag jump and would fake the result under test.
- **RX1's chain must remain untouched** — the link and its existing capture path keep working.
- Commit with `git commit -s`. Repo root `/mnt/onetb/scratch/qpsk-jupiter-modem`. Run shell work under `bash`.

---

### Task 1: Characterise the RX1 IQ "ramp" — GATE before any build

**Files:**
- Create: `two_jup/ramp_probe.sh`
- Create: `two_jup/ramp_findings.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a verdict recorded in `ramp_findings.md` — whether the documented ramp originates in the **ADC source** (this plan proceeds) or in the **packer/DMAC configuration** (this plan is invalid as designed and stops).

`boot_known_good/README.md` records the rx-lpc IQ capture tap as *"STRUCTURALLY a ramp on this lineage — no IQ captures possible."* This plan assumes that fault lives in RX1's ADC source and is bypassed by feeding RX2's packer from internal fabric. **If instead it lives in the packer or DMAC, this design inherits it and a 2-hour build is wasted.** Fifteen minutes here protects that.

- [ ] **Step 1: Write the probe**

Create `two_jup/ramp_probe.sh`:

```bash
#!/bin/bash
# Characterise the documented rx-lpc IQ "ramp" on the CURRENT image, before
# committing a BD change that assumes the fault is ADC-side.
set -u
D=$(cd "$(dirname "$0")" && pwd)
. "$D/sim_repro/riglock.sh" 2>/dev/null || true
. "$D/agents/rigmutex.sh"
B=10.0.0.148
OUT=$D/rampprobe/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
rig_acquire ramp_probe 1800 || { echo "ACQUIRE FAILED rc=$?"; exit 1; }
trap 'rig_release' EXIT
"$D/anyssh.sh" $B 'cat /sys/bus/iio/devices/iio:device3/name 2>/dev/null; ls /sys/bus/iio/devices/ | head' 2>/dev/null | tee "$OUT/devices.txt"
# grab a short RX1 buffer via iio and dump the first samples as hex
"$D/anyssh.sh" $B 'cd /tmp && timeout 30 iio_readdev -b 4096 -s 4096 axi-adrv9002-rx-lpc voltage0 voltage1 2>/dev/null | xxd -g2 | head -40' 2>/dev/null | tee "$OUT/rx1_raw.txt"
echo "RAMP_PROBE_DONE $OUT"
```

- [ ] **Step 2: Run it and classify the pattern**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
chmod +x two_jup/ramp_probe.sh && bash two_jup/ramp_probe.sh
```
Classify from `rx1_raw.txt`, and record which in `ramp_findings.md`:
- **monotonically incrementing counter** ⇒ a synthetic test pattern from the ADC interface ⇒ ADC-side ⇒ **proceed**;
- **all zeros / constant** ⇒ nothing driving the packer ⇒ inconclusive, investigate before proceeding;
- **plausible modulated I/Q** ⇒ the ramp note is stale and RX1 capture works ⇒ **proceed, and correct the README**.

- [ ] **Step 3: Record the verdict and commit**

```bash
git add two_jup/ramp_probe.sh two_jup/ramp_findings.md
git commit -s -m "Characterise the rx-lpc IQ ramp before committing to the DDR capture BD change"
```

**STOP CONDITION:** if the evidence points at the packer or DMAC rather than the ADC source, do not start Task 2. Report to the operator.

---

### Task 2: RTL — widened mux, marker sources, bit packing

**Files:**
- Create: `two_jup/skidfix/ddrcap_inject.py`
- Create: `jupiter_240k5_byte/rtl_sim/sim_ddrcap.cpp`
- Modify (via injector, all copies): `TxRxCompo_ip_src_QPSK_Rx.v`, `TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v`, `TxRxCompo_ip_src_TxRxComposite.v`

**Interfaces:**
- Consumes: the FINAL lineage RTL (`jupiter_240k5_byte/rtl_sim/s1_rtl_final/`), which already carries DBGCAP, TXCAP and DEMODCAP — all of which must survive.
- Produces: four new top-level IP outputs `ddrcap_i`, `ddrcap_q`, `ddrcap_mark_demod`, `ddrcap_mark_fec`, each 16-bit, plus `ddrcap_valid`. These are consumed by Task 3's BD change.

**This task adds TOP-LEVEL IP ports, so it is NOT a source-only resynth** — that is why Task 3 exists.

- [ ] **Step 1: Write the injector**

Create `two_jup/skidfix/ddrcap_inject.py` following the established pattern of `dbgcap_inject.py` (read it first). It must:
- widen the `iq_debug_mux` decode in `QPSK_Rx.v` from 4 to 12 selectors per the spec's §4.2 table;
- add a `postCoarseFreq_re/im` output port to `Frequency_and_Time_Synchronizer.v` and wire it up in `QPSK_Rx.v` — that module already exports `postSymbolSync`/`postCarrierSync`, so follow that exact pattern;
- pack bit-domain selectors (9, 10, 11) 16 bits per word;
- drive `ddrcap_mark_demod` = `QPSK_Demodulator_startOut ? 16'h7FFF : 16'h0000` and `ddrcap_mark_fec` = `startSel ? 16'h7FFF : 16'h0000`;
- expose all five signals as top-level ports through `Receiver.v` and `TxRxComposite.v`;
- be idempotent and patch **all four loose HDL copies and both `TxRxCompo_ip_v1_0.zip` files**, verifying each.

- [ ] **Step 2: Sim-gate it**

Create `jupiter_240k5_byte/rtl_sim/sim_ddrcap.cpp` modelled on `sim_final.cpp`. For each selector 0–11, run a clean mode-1 loopback and assert:
- `ddrcap_i/q` are not identically zero (the QPSK_Modulator tap failure mode — see `.superpowers/.../agent-txint-report.md`);
- `ddrcap_mark_demod` pulses exactly once per frame;
- `ddrcap_mark_fec` pulses exactly once per frame.

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim
rm -rf s1_rtl_ddrcap && cp -a s1_rtl_final s1_rtl_ddrcap
python3 ../../two_jup/skidfix/ddrcap_inject.py s1_rtl_ddrcap
verilator --cc --exe --build -O2 -Wno-fatal --top-module wrap_byte_ce -Mdir obj_ddrcap \
  -y s1_rtl_ddrcap/hdlsrc/commhdlQPSKTxRxLoopback -y . wrap_byte_dbgcap.v sim_ddrcap.cpp -o Vwrap_byte_ce
./obj_ddrcap/Vwrap_byte_ce 10
```
Expected: every selector reports non-zero data and exactly one pulse per frame on both markers.

- [ ] **Step 3: Positive control in sim**

For at least three selectors spanning the domains (one sample-domain, one symbol-domain, one bit-domain), force a change and confirm `ddrcap_i/q` changes. Report before/after values. **A selector that cannot be shown to move is dead — report it and do not carry it into the build.**

- [ ] **Step 4: Commit**

```bash
git add two_jup/skidfix/ddrcap_inject.py jupiter_240k5_byte/rtl_sim/sim_ddrcap.cpp
git commit -s -m "DDR capture RTL: widened 12-way tap mux, postCoarseFreq port, dual frame markers, bit packing"
```

---

### Task 3: Block-design change — repoint the RX2 packer

**Files:**
- Create: `two_jup/skidfix/ddrcap_bd.tcl`
- Modify: the BD in a fresh build tree only (never `jupiter_byte_final_build/` in place)

**Interfaces:**
- Consumes: Task 2's five new IP ports.
- Produces: a build tree whose `util_adc_2_pack` is fed from the modem IP.

- [ ] **Step 1: Write the BD patch script**

Create `two_jup/skidfix/ddrcap_bd.tcl` which, against the opened project:
- disconnects `util_adc_2_pack/fifo_wr_data_0..3` from `axi_adrv9001/adc_2_data_*` and `GND_16`;
- connects them to `TxRxCompo_ip_0/ddrcap_i`, `ddrcap_q`, `ddrcap_mark_demod`, `ddrcap_mark_fec`;
- disconnects `util_adc_2_pack/clk` from `axi_adrv9001_adc_2_clk` and connects it to `axi_adrv9001_adc_1_clk`;
- drives all four `util_adc_2_pack/enable_*` from `TxRxCompo_ip_0/ddrcap_valid` rather than `GND_1`;
- leaves `util_adc_1_pack`, `axi_adrv9001_rx1_dma` and every RX1 net untouched;
- prints `DDRCAP_BD_WIRE_OK` on success.

- [ ] **Step 2: Apply and validate the BD**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
cp -a jupiter_byte_final_build jupiter_byte_ddrcap_build
python3 two_jup/skidfix/ddrcap_inject.py jupiter_byte_ddrcap_build
# then, in the build tree's vivado_ip_prj, source ddrcap_bd.tcl and validate_bd_design
```
Expected: `DDRCAP_BD_WIRE_OK` and a clean `validate_bd_design`.

- [ ] **Step 3: Commit**

```bash
git add two_jup/skidfix/ddrcap_bd.tcl
git commit -s -m "BD patch: repoint util_adc_2_pack at the modem IP capture ports, clock it from adc_1_clk"
```

---

### Task 4: Build the image

**Files:**
- Create: `jupiter_byte_ddrcap_build/build_ddrcap.sh`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `BOOT.BIN` banked as `boot_known_good/BOOT.BIN.148.ddrcap.<md5-12>`, plus its post-impl WNS.

- [ ] **Step 1: Write the build runner and launch it**

Model on `jupiter_byte_final_build/build_final.sh`, but this build regenerates the BD, so it must run the full flow rather than `resynth_*.tcl`. Build on **hdl-dev-2** (`/opt/Xilinx/2025.1/Vivado`, `~/qpsk-builds/`) to leave nemo free. Launch it so it survives, then poll until `BOOT.BIN` exists.

- [ ] **Step 2: Check timing and bank the image**

```bash
awk '/Design Timing Summary/{f=1} f&&/WNS\(ns\)/{getline;getline;print;exit}' <impl timing rpt>
```
Expected: **WNS > 0 and zero failing endpoints.** A negative WNS is a stop condition — report, do not flash.

```bash
cp <BOOT.BIN> boot_known_good/BOOT.BIN.148.ddrcap.<md5-12>
git add boot_known_good/BOOT.BIN.148.ddrcap.* && git commit -s -m "Bank the DDR-capture image"
```

---

### Task 5: Flash and prove the capture path — the §0 gate

**Files:**
- Create: `two_jup/ddrcap_pc.sh`

**Interfaces:**
- Consumes: Task 4's image.
- Produces: a pass/fail on whether the capture path can produce a non-null. **No capture is interpreted until this passes.**

- [ ] **Step 1: Flash with full rails**

Query the live md5 for `BAK_MD5`, pass `BB` absolute, use `two_jup/skidfix/flash_148_stagesig.sh` under the rig lock. Rollback and `rig_halt_set` on failure; no retry.

- [ ] **Step 2: Run the four-part capture-path positive control**

Create `two_jup/ddrcap_pc.sh` asserting, in mode-1 loopback:
1. **Liveness** — a buffer captured at any selector is neither constant nor a monotonic ramp.
2. **Selector proof** — buffers captured at two different `0x10C` values differ. A selector that changes nothing is the `iq_debug_mux` failure repeated.
3. **Cross-check** — at selector 6 (constellation), hard decisions derived from the raw samples match DBGCAP tap 3's digest for the same frames. Disagreement means one of them is wrong; neither may be used until resolved.
4. **Marker spacing** — `ddrcap_mark_demod` pulses appear at the expected spacing (~49,349 words for sample-domain selectors, ~12,337 for symbol-domain), which also self-identifies the tap's domain.

- [ ] **Step 3: Restore, release, commit**

`RXM=16 RXQ=1 GATE_TRIES=12 two_jup/bringup_r2r3.sh r3`, confirm `ARM GATE PASS`, restart both watchdogs, `rig_release`, then commit the script and results.

**STOP CONDITION:** any part failing ⇒ report `WITNESS-DEAD` for the capture path and collect no measurements.

---

### Task 6: First measurement — marker versus data through a burst

**Files:**
- Create: `two_jup/ddrcap_run.sh`, `two_jup/score_ddrcap.py`

**Interfaces:**
- Consumes: a Task-5-validated capture path.
- Produces: the answer to position-versus-values, written to `chain.json` by the governor.

- [ ] **Step 1: Capture into a predicted burst**

The beat is phase-locked to reset — measured onsets 87/206/323 s after arm across four arms on two days. Arm mode-1 loopback, wait, and capture ~200 frames (≈39 MB) spanning a predicted onset, at selector 0 (RX input) and again at selector 6 (constellation).

- [ ] **Step 2: Score marker-to-data lag per frame**

`two_jup/score_ddrcap.py` must, for each frame in the buffer: locate the demod marker pulse, locate the FEC marker pulse, correlate the data against the first frame's data to find its true offset, and report the lag between marker and data.

- [ ] **Step 3: Report the verdict**

- **lag constant across the burst** ⇒ the marker is stable ⇒ the deviation is in values; the position hypothesis dies.
- **lag jumps during the burst** ⇒ the marker moves relative to bit-identical data ⇒ position confirmed, shift measured in samples.
- **demod and FEC markers diverge from each other** ⇒ the shift is localised between the demodulator and the FEC decoder.

Governor writes the outcome to `chain.json` with `positive_control=True` only if Task 5 passed.

---

## Self-Review

**Spec coverage:** §3 idle chain → Tasks 1, 3. §4.1 channel allocation → Tasks 2, 3. §4.2 selector map → Task 2. §4.3 bit packing → Task 2. §4.4 markers as the measurement → Tasks 2, 5, 6. §5 sizing → Task 6. §6 work required → Tasks 2–4. §7 verification → Task 5. §8 ramp risk → **Task 1, deliberately first and cheap**.

**Placeholder scan:** Task 3 Step 2 and Task 4 Step 1 describe the Vivado invocation rather than quoting it verbatim, because the BD flow's exact commands depend on the build tree layout the implementer will inspect. Every acceptance criterion is concrete.

**Type consistency:** the five port names (`ddrcap_i`, `ddrcap_q`, `ddrcap_mark_demod`, `ddrcap_mark_fec`, `ddrcap_valid`) are identical across Tasks 2, 3 and 5. Selector numbering matches the spec's §4.2 table throughout. Marker encoding `0x7FFF`/`0x0000` is stated identically in the Global Constraints, Task 2 and Task 5.
