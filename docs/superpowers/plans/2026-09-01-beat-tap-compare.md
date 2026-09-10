# Beat Localisation by DDR Tap Capture vs Bit-True and Float Models — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find the source of the ~239.5 s "beat" burst in 148 mode-1 loopback by running the bit-true netlist unforced past the burst onset (sim leg) and by scoring DDR tap captures anchor-free against netlist-generated golden tap streams and the float receiver (hardware leg), then fix it and validate on 148.

**Architecture:** Two legs share one Verilator build of the netlist that matches the flashed TXMARK image. Leg A runs that netlist for hundreds of thousands of frames with a checkpoint/restore driver and a burst detector; Leg B generates golden per-tap DDR record streams from the same netlist and cross-correlates hardware captures against them, with the float receiver decoding the same sample-domain windows. A fixed decision table (spec §5) routes the results to the conditional instrument flash and the fix flash.

**Tech Stack:** Verilator 5.020 (C++ drivers), Python 3 + numpy + pytest, bash on nemo, MATLAB R2025b (`float_baseline_f1536.m`, Simulink `commhdlQPSKTxRxLoopback`), 148 via `two_jup/anyssh.sh` and `direct_reg_access`, `systemd-run --user` for anything longer than a few minutes.

**Spec:** `docs/superpowers/specs/2026-09-01-beat-tap-compare-design.md`

## Global Constraints

- 146 is never touched. All rig work is 148, mode-1 internal loopback, current image `BOOT.BIN.148.txmark.1cd0cd752aa6`, unless a task says "flash".
- Register polls on 148 are 1 s minimum; one register read per poll where possible; never kill a restore mid-arm; rig-holding units start only via `two_jup/launch_rig_unit.sh`.
- `0x10C` is write-only. Set it AFTER the arm (the `0x000` soft reset clears it). Verify by effect: `0x20C` must read golden `0xBCF94856` with the low nibble = 3.
- Host-side `stat` of the transferred file BEFORE any board-side `rm`. Never re-run a transfer into an existing path without `stat`-ing it first.
- §0 POSITIVE CONTROL RULE: no instrument or derived scoring method produces a credited null until it has produced a non-null. Two revisions per instrument maximum.
- Label every reported claim **proven on silicon / reproduced in sim / inferred**.
- Long jobs (> 5 min) run as `systemd-run --user` transient units, never as harness background tasks (reaped at ~60 min). Progress is checked by reading files, never by foreground polling loops.
- Geometry: 12,320 symbols/frame, 12,333 marker gap, 197,328 clks/frame, ~49,349 sample-domain records/frame, ~12,337 symbol-domain records/frame. Rungs (symbol domain): 6176, 6240, 6299, 6363, 6432 plain; 6489, 6548 I/Q-swapped. Sanity: sample/symbol ≈ 4.
- DDR record = four little-endian int16: `[I, Q, demod_marker, tx_marker]`, markers `0x7FFF`/`0x0000`.
- Commits: `git commit -s`, message ends with `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`. Commit locally (the branch is unpushed by operator direction).
- Sim netlist for this campaign = `s1_rtl_final` + `TXMARK=1 ddrcap_inject.py` (the recipe that built the flashed image). `s1_rtl_beatfix3`/`obj_burst` are NOT the flashed lineage and are not used.

---

## File map

| Path | Responsibility |
|---|---|
| `jupiter_240k5_byte/rtl_sim/build_beat_sim.sh` | Create `s1_rtl_txmark` netlist, build `obj_beat_fast` (ports only, threaded) and `obj_beat_flat` (`--public-flat-rw --savable --trace-fst`) |
| `jupiter_240k5_byte/rtl_sim/sim_beat_long.cpp` | Long unforced ROM-loopback run: per-frame log, checkpoint/restore, register dump and FST trace around chosen frames (flat build only) |
| `jupiter_240k5_byte/rtl_sim/sim_golden_taps.cpp` | Write the DDR record stream of one selector to disk + frame index file |
| `jupiter_240k5_byte/rtl_sim/beat_longrun.sh` | Launch a long run as a systemd user unit with milestones and a status file |
| `two_jup/beat_detect.py` | Burst detector for sim frame logs and for hardware per-second soak CSVs |
| `two_jup/score_tapvs_golden.py` | Anchor-free per-frame offset scoring of a capture vs a golden stream |
| `two_jup/ddr_to_iq.py` | Cut a window of DDR records into an interleaved int16 IQ file for MATLAB |
| `two_jup/beat_tap_capture.sh` | One arm, burst-phased captures (mid-burst + predicted onset) for one selector |
| `two_jup/beat_soak.sh` | 1 s poll of 0x104/0x108 for N seconds to CSV, then detector |
| `k5_240/float_tap_window.m` | Float receiver on one IQ window, per-frame CSV + one summary line |
| `jupiter_240k5_byte/sim_replay_window_f1536.m` | Simulink replay of an IQ window through the model's external ADC port |
| `two_jup/tests/*.py`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` | Tests and dry-run stubs |
| `two_jup/SESSION_20260830_AUTONOMOUS.md` | Findings appended as §76+ |

---

### Task 1: Netlist + two Verilator builds + throughput gate

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/build_beat_sim.sh`
- Create: `jupiter_240k5_byte/rtl_sim/sim_beat_long.cpp`
- Test: timed runs (recorded in `jupiter_240k5_byte/rtl_sim/beat_runs/THROUGHPUT.md`)

**Interfaces:**
- Consumes: `two_jup/skidfix/ddrcap_inject.py` (env `TXMARK=1`), `rtl_sim/wrap_byte_ddrcap.v`, `rtl_sim/s1_rtl_final/`.
- Produces: `obj_beat_fast/Vwrap_byte_ddrcap`, `obj_beat_flat/Vwrap_byte_ddrcap`; driver CLI `sim_beat_long NF OUT_PREFIX [--ckpt-every N] [--restore FILE] [--dump-at k1,k2,..] [--trace-at K --trace-frames N]`; per-frame log `OUT_PREFIX_frames.txt` with columns `packet errs clks rstcs` (+ `mu cnt` on the flat build).

- [ ] **Step 1: Write the build script**

```bash
#!/bin/bash
# build_beat_sim.sh -- netlist matching the flashed TXMARK image + two Verilator builds.
#   obj_beat_fast : ports only, -O2, --threads 4         (long unforced run)
#   obj_beat_flat : --public-flat-rw --savable --trace-fst (state dump / checkpoint / trace)
# Run from jupiter_240k5_byte/rtl_sim. Idempotent: skips a build whose binary exists unless FORCE=1.
set -eu
cd "$(dirname "$0")"
VD=s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback
if [ ! -d s1_rtl_txmark ] || [ "${FORCE:-0}" = 1 ]; then
  rm -rf s1_rtl_txmark && cp -a s1_rtl_final s1_rtl_txmark
  TXMARK=1 python3 ../../two_jup/skidfix/ddrcap_inject.py s1_rtl_txmark
  grep -q "Transmitter_txFrameStart" "$VD/TxRxComposite.v" || { echo "TXMARK marker not injected"; exit 1; }
fi
COMMON="-O2 -Wno-fatal --cc --exe --build --top-module wrap_byte_ddrcap -y $VD -y . wrap_byte_ddrcap.v"
# one driver (one main) per verilator call / per -Mdir
if [ ! -x obj_beat_fast/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --threads 4 -CFLAGS "-O2" -Mdir obj_beat_fast \
    sim_beat_long.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
if [ ! -x obj_beat_flat/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --public-flat-rw --savable --trace-fst -CFLAGS "-O2 -DBEAT_FLAT" -Mdir obj_beat_flat \
    sim_beat_long.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
ls -la obj_beat_fast/Vwrap_byte_ddrcap obj_beat_flat/Vwrap_byte_ddrcap
```

- [ ] **Step 2: Write the long-run driver**

```cpp
// sim_beat_long.cpp -- long UNFORCED ROM/BIST mode-1 loopback run on the TXMARK netlist.
// Per-frame log (same first four columns as burst_runs/*_frames.txt): packet errs clks rstcs.
// Flat build (-DBEAT_FLAT): adds mu/cnt columns, --dump-at register dumps, --ckpt-every /
// --restore checkpoints (Verilator --savable), --trace-at/--trace-frames FST trace.
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#ifdef BEAT_FLAT
#include "Vwrap_byte_ddrcap___024root.h"
#include "verilated_save.h"
#include "verilated_fst_c.h"
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define RXP wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
static const long CLKS_PER_FRAME = 197328;
int main(int argc, char** argv){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);
    if(argc < 3){ fprintf(stderr,"usage: sim_beat_long NF OUT_PREFIX [--ckpt-every N] [--restore F] [--dump-at k,k,..] [--trace-at K --trace-frames N]\n"); return 2; }
    long NF = atol(argv[1]); std::string pfx = argv[2];
    long ckptEvery = 0; std::string restore; std::vector<long> dumpAt; long traceAt = -1, traceFrames = 3;
    for(int i = 3; i < argc; i++){
        std::string a = argv[i];
        if(a == "--ckpt-every" && i+1 < argc) ckptEvery = atol(argv[++i]);
        else if(a == "--restore" && i+1 < argc) restore = argv[++i];
        else if(a == "--dump-at" && i+1 < argc){ char* s = argv[++i]; for(char* t = strtok(s, ","); t; t = strtok(nullptr, ",")) dumpAt.push_back(atol(t)); }
        else if(a == "--trace-at" && i+1 < argc) traceAt = atol(argv[++i]);
        else if(a == "--trace-frames" && i+1 < argc) traceFrames = atol(argv[++i]);
    }
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()};
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0; t->fixctl = 0;
    t->iq_debug_mux = 3; t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
#ifdef BEAT_FLAT
    auto* R = t->rootp;
    VerilatedFstC* tfp = nullptr;
    if(traceAt >= 0){ ctx->traceEverOn(true); tfp = new VerilatedFstC; t->trace(tfp, 99); }
#endif
    auto tick = [&](){ t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
#ifdef BEAT_FLAT
        if(tfp && tfp->isOpen()) tfp->dump(clk);
#endif
    };
    unsigned lastPk = 0, lastErr = 0; long lastClk = 0;
    if(!restore.empty()){
#ifdef BEAT_FLAT
        VerilatedRestore is; is.open(restore.c_str()); is >> *ctx; is >> *t; is >> clk; is >> lastPk; is >> lastErr; is >> lastClk; is.close();
        fprintf(stderr, "restored %s at clk %ld packet %u\n", restore.c_str(), clk, lastPk);
#else
        fprintf(stderr, "--restore needs the flat build\n"); return 2;
#endif
    } else { for(int i = 0; i < 100; i++) tick(); t->reset = 0; }
    std::string fn = pfx + "_frames.txt"; FILE* ff = fopen(fn.c_str(), restore.empty() ? "w" : "a");
    std::string st = pfx + "_status.txt";
    long total = 100 + (NF + 4) * CLKS_PER_FRAME; size_t dumpIdx = 0;
    while(clk < total){
        t->adc_validIn = (clk & 1) ? 0 : 1;
        tick();
        unsigned pk = t->packets_out;
        if(pk != lastPk){
            unsigned err = t->bit_errors_out;
            fprintf(ff, "%u %u %ld %u", pk, err - lastErr, clk - lastClk, t->rstcs_count);
#ifdef BEAT_FLAT
            fprintf(ff, " mu=%d cnt=%d",
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg) << 5)) >> 5,
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg) << 5)) >> 5);
#endif
            fprintf(ff, "\n");
            lastErr = err; lastClk = clk; lastPk = pk;
            if((pk & 255) == 0){ fflush(ff); FILE* fs = fopen(st.c_str(), "w"); if(fs){ fprintf(fs, "packet=%u errs=%u clk=%ld\n", pk, err, clk); fclose(fs);} }
#ifdef BEAT_FLAT
            if(ckptEvery > 0 && pk % ckptEvery == 0){
                char cf[512]; snprintf(cf, sizeof cf, "%s_ckpt_%u.bin", pfx.c_str(), pk);
                VerilatedSave os; os.open(cf); os << *ctx; os << *t; os << clk; os << lastPk; os << lastErr; os << lastClk; os.close();
            }
            if(dumpIdx < dumpAt.size() && (long)pk == dumpAt[dumpIdx]){
                dumpIdx++;
                char df[512]; snprintf(df, sizeof df, "%s_dump_%u.txt", pfx.c_str(), pk); FILE* fd = fopen(df, "w");
                fprintf(fd, "packet %u clk %ld errs_total %u\n", pk, clk, err);
                fprintf(fd, "cs_integ %llx\n", (unsigned long long)R->CAT(FTS,u_Carrier_Synchronizer__DOT__u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1));
                fprintf(fd, "ss_delay2_0 %llx\nss_delay2_1 %llx\n", (unsigned long long)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[0], (unsigned long long)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[1]);
                fprintf(fd, "ss_mu %d\nss_cnt %d\n", (int)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg), (int)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg));
                fprintf(fd, "agc_delay2_re_0 %llx\nagc_delay2_re_1 %llx\n", (unsigned long long)R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[0], (unsigned long long)R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[1]);
                fprintf(fd, "cfe_integ_re %x\ncfe_integ_im %x\n", (unsigned)R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_re), (unsigned)R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_im));
                fprintf(fd, "ps_ref %u\nta_ref %u\nps_offset %u\n", (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Timing_Adjust__DOT__timing_Reference_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1));
                fprintf(fd, "fifo_push %u\nfifo_pop %u\nfifo_occ %u\n", (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg));
                fclose(fd);
            }
            if(tfp && (long)pk == traceAt){ char tf[512]; snprintf(tf, sizeof tf, "%s_trace_%u.fst", pfx.c_str(), pk); tfp->open(tf); }
            if(tfp && tfp->isOpen() && (long)pk == traceAt + traceFrames){ tfp->close(); }
#endif
        }
    }
    fclose(ff);
#ifdef BEAT_FLAT
    if(tfp){ if(tfp->isOpen()) tfp->close(); delete tfp; }
#endif
    printf("BEATLONG NF=%ld packets=%u biterr=%u rstcs=%u clk=%ld\n", NF, t->packets_out, t->bit_errors_out, t->rstcs_count, clk);
    delete t; return 0;
}
```

Notes for the implementer: if `--savable` rejects a module, the build log names it; report it and drop `--savable` from the flat build (checkpointing then falls back to "rerun to frame K", which the throughput numbers will price). The register paths are the ones already compiled in `sim_burst_force.cpp`; a rename in the TXMARK netlist shows up as a compile error naming the member, and the fix is to grep `obj_beat_flat/Vwrap_byte_ddrcap___024root.h` for the new name.

- [ ] **Step 3: Build**

Run: `cd jupiter_240k5_byte/rtl_sim && bash build_beat_sim.sh 2>&1 | tail -20`
Expected: both binaries listed by `ls -la`, no `%Error`.

- [ ] **Step 4: Throughput gate (500 frames each, timed)**

```bash
cd jupiter_240k5_byte/rtl_sim && mkdir -p beat_runs
/usr/bin/time -f "fast %e s" ./obj_beat_fast/Vwrap_byte_ddrcap 500 beat_runs/gate_fast 2>&1 | tail -2
/usr/bin/time -f "flat %e s" ./obj_beat_flat/Vwrap_byte_ddrcap 500 beat_runs/gate_flat --ckpt-every 250 2>&1 | tail -2
awk '$2>0' beat_runs/gate_fast_frames.txt | wc -l      # must be 0 error frames
ls -la beat_runs/gate_flat_ckpt_250.bin beat_runs/gate_flat_ckpt_500.bin
```
Expected: `BEATLONG ... packets=50x biterr=0 rstcs=0`, zero error frames on both, two checkpoint files. Record in `beat_runs/THROUGHPUT.md`: frames/s per build and the projected wall time for 45,000 / 200,000 / 300,000 frames. Decision rule from spec §3.1: ≥ 45,000 frames in ≤ 24 h on either build → proceed with that build; otherwise report the numbers as a finding before continuing.

- [ ] **Step 5: Checkpoint restore test**

```bash
./obj_beat_flat/Vwrap_byte_ddrcap 600 beat_runs/gate_restore --restore beat_runs/gate_flat_ckpt_250.bin
tail -1 beat_runs/gate_restore_frames.txt        # packet number ends near 600
awk '$1==400' beat_runs/gate_flat_frames.txt beat_runs/gate_restore_frames.txt   # both lines identical
```
Expected: the frame-400 line (errs, clks) is identical in the straight run and the restored run.

- [ ] **Step 6: Forced-kick sanity (proves the netlist can show a burst)**

The August result: an `ss` kick gives ~60 errors/frame with framesync intact. Reproduce it on the flat build so a later clean long run is a credited null: temporarily run the OLD driver against the new netlist:

```bash
verilator -O2 -Wno-fatal --cc --exe --build --public-flat-rw --top-module wrap_byte_ddrcap \
  -y s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback -y . wrap_byte_ddrcap.v sim_burst_force_txmark.cpp \
  -Mdir obj_beat_force -o Vforce 2>&1 | tail -2
./obj_beat_force/Vforce 260 80 ss beat_runs/pc_ss; ./obj_beat_force/Vforce 260 80 none beat_runs/pc_none
awk 'NR>85{s+=$2;n++}END{print "ss mean errs/frame", s/n}' beat_runs/pc_ss_frames.txt
awk 'NR>85{s+=$2;n++}END{print "none mean errs/frame", s/n}' beat_runs/pc_none_frames.txt
```
`sim_burst_force_txmark.cpp` = `sim_burst_force.cpp` with `Vwrap_byte_ce` → `Vwrap_byte_ddrcap` (three occurrences) and the two `#define` prefixes changed from `wrap_byte_ce__DOT__` to `wrap_byte_ddrcap__DOT__`; the wrapper needs `t->iq_debug_mux = 3` added to the init line. Expected: `ss` ≈ 47–68/frame, `none` = 0.0/frame.

- [ ] **Step 7: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/build_beat_sim.sh jupiter_240k5_byte/rtl_sim/sim_beat_long.cpp \
        jupiter_240k5_byte/rtl_sim/sim_burst_force_txmark.cpp jupiter_240k5_byte/rtl_sim/beat_runs/THROUGHPUT.md
git commit -s -m "Beat sim leg: TXMARK netlist, fast+flat Verilator builds, long-run driver with checkpoint/dump, throughput gate

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 2: Golden tap stream generator

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/sim_golden_taps.cpp`
- Modify: `jupiter_240k5_byte/rtl_sim/build_beat_sim.sh` (add the `obj_golden` build call)
- Test: `two_jup/ddrcap_pc_large.py` parts 1 and 4 on the output; record counts

**Interfaces:**
- Produces: `sim_golden_taps SEL NF OUT.bin` → `OUT.bin` (DDR 4×int16 records, every `ddrcap_valid` beat after frame 20) and `OUT.frames.txt` (lines `frame_index record_index` at each `ddrcap_mark_fec` rise, i.e. the TX marker). Files consumed by Task 3 and Task 6. Directory convention: `jupiter_240k5_byte/rtl_sim/golden_taps/sel<N>.bin`.

- [ ] **Step 1: Write the generator**

```cpp
// sim_golden_taps.cpp -- write one selector's DDR record stream from the TXMARK netlist in mode-1
// ROM loopback. Record = int16 [I, Q, mark_demod, mark_fec], little-endian, one per ddrcap_valid beat,
// starting after WARM frames. Frame index file: one line per TX-marker rise: "<cnt_frame_start> <record_index>".
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <memory>
static const long CLKS_PER_FRAME = 197328;
int main(int argc, char** argv){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);
    if(argc < 4){ fprintf(stderr, "usage: sim_golden_taps SEL NF OUT.bin [WARM=20]\n"); return 2; }
    unsigned sel = (unsigned)atoi(argv[1]); long NF = atol(argv[2]); const char* out = argv[3];
    long WARM = argc > 4 ? atol(argv[4]) : 20;
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()};
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0; t->fixctl = 0;
    t->iq_debug_mux = ((sel & 0xFu) << 16) | 3u;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    long clk = 0; auto tick = [&](){ t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for(int i = 0; i < 100; i++) tick(); t->reset = 0;
    FILE* fb = fopen(out, "wb"); char fn[512]; snprintf(fn, sizeof fn, "%s.frames.txt", out); FILE* fi = fopen(fn, "w");
    long total = 100 + (NF + 4) * CLKS_PER_FRAME; unsigned long rec = 0; bool prevMark = false; unsigned long nonzero = 0;
    while(clk < total){
        t->adc_validIn = (clk & 1) ? 0 : 1;
        tick();
        if(t->cnt_frame_start < (unsigned)WARM) continue;
        if(t->ddrcap_valid){
            short r[4] = { (short)t->ddrcap_i, (short)t->ddrcap_q, (short)t->ddrcap_mark_demod, (short)t->ddrcap_mark_fec };
            fwrite(r, sizeof r, 1, fb);
            if(r[0] || r[1]) nonzero++;
            bool m = (t->ddrcap_mark_fec == 0x7FFF);
            if(m && !prevMark) fprintf(fi, "%u %lu\n", (unsigned)t->cnt_frame_start, rec);
            prevMark = m; rec++;
        }
    }
    fclose(fb); fclose(fi);
    printf("GOLDEN sel=%u frames=%u records=%lu nonzero=%lu packets=%u biterr=%u\n", sel, (unsigned)t->cnt_frame_start, rec, nonzero, t->packets_out, t->bit_errors_out);
    delete t; return 0;
}
```

- [ ] **Step 2: Add the build call and build**

Append to `build_beat_sim.sh` (same `$COMMON`, no threads needed):
```bash
if [ ! -x obj_golden/Vgolden ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON -CFLAGS "-O2" -Mdir obj_golden sim_golden_taps.cpp -o Vgolden 2>&1 | tail -3
fi
```
Run: `bash build_beat_sim.sh 2>&1 | tail -5` → `obj_golden/Vgolden` exists.

- [ ] **Step 3: Generate and check the four campaign taps**

```bash
cd jupiter_240k5_byte/rtl_sim && mkdir -p golden_taps
for s in 0 2 3 5; do ./obj_golden/Vgolden $s 220 golden_taps/sel$s.bin | tee -a golden_taps/GEN.log; done
for s in 0 2 3 5; do python3 ../../two_jup/ddrcap_pc_large.py golden_taps/sel$s.bin golden_taps/sel$((s==0?3:0)).bin | grep -E "LIVENESS|MARKERS|PASS|FAIL"; done
for s in 0 2 3 5; do echo -n "sel$s frames.txt lines: "; wc -l < golden_taps/sel$s.bin.frames.txt; done
```
Expected: `biterr=0` on every line of GEN.log; liveness PASS (not constant, not a ramp); marker spacing sample-domain (~49,349) for sel0/sel2 and symbol-domain (~12,337) for sel3/sel5; ~200 frame lines each. Record the exact modal spacings in `golden_taps/GEN.log` — Task 3 uses them as the period P.

- [ ] **Step 4: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/sim_golden_taps.cpp jupiter_240k5_byte/rtl_sim/build_beat_sim.sh jupiter_240k5_byte/rtl_sim/golden_taps/GEN.log
git commit -s -m "Beat: golden per-tap DDR record streams from the TXMARK netlist (sel0/2/3/5)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```
(`golden_taps/*.bin` are ~40 MB each; add `jupiter_240k5_byte/rtl_sim/golden_taps/*.bin` to `.gitignore` in this commit.)

---

### Task 3: Anchor-free scorer + controls

**Files:**
- Create: `two_jup/score_tapvs_golden.py`
- Create: `two_jup/tests/test_score_tapvs_golden.py`
- Test: pytest (synthetic), then sel3 positive control, sel5 negative control, sel2 on disk

**Interfaces:**
- CLI: `score_tapvs_golden.py CAPTURE.bin GOLDEN.bin [--period P] [--max-frames N] [--out PREFIX]` → prints a summary and writes `PREFIX.csv` (`frame,offset,swap,score`) and `PREFIX.json` (`{"period":P,"frames":n,"modal_offset":o,"states":{offset:count},"first_divergence_frame":f|null,"first_divergence_record":r|null,"offset_after":d|null,"kind":"jump"|"walk"|null,"unmatched":u}`).
- Python API used by tests: `score(cap: np.ndarray, gold: np.ndarray, period: int) -> dict` with the same keys, where `cap`/`gold` are `(N,4)` int16 arrays.

- [ ] **Step 1: Write the failing tests**

```python
# two_jup/tests/test_score_tapvs_golden.py
import numpy as np, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from score_tapvs_golden import score

P = 1000
def golden(nframes, seed=1):
    rng = np.random.default_rng(seed)
    frame = rng.integers(-8000, 8000, size=(P, 2)).astype(np.int16)
    g = np.zeros((nframes * P, 4), dtype=np.int16)
    g[:, :2] = np.tile(frame, (nframes, 1))
    g[::P, 3] = 0x7FFF
    return g

def test_aligned_capture_scores_zero_offset_everywhere():
    g = golden(30)
    cap = g.copy()
    r = score(cap, g, P)
    assert r['modal_offset'] == 0 and r['first_divergence_frame'] is None and r['unmatched'] == 0

def test_jump_displacement_is_found_at_the_right_frame():
    g = golden(40)
    cap = g.copy()
    cap[20 * P:, :2] = np.roll(g[20 * P:, :2], 137, axis=0)      # one-step shift from frame 20 on
    r = score(cap, g, P)
    assert r['first_divergence_frame'] == 20
    assert r['offset_after'] == 137 and r['kind'] == 'jump'

def test_walk_is_classified_as_walk():
    g = golden(40)
    cap = g.copy()
    for k in range(1, 6):                                          # offset grows 1 record per frame, frames 20..24
        f = 20 + k - 1
        cap[f * P:(f + 1) * P, :2] = np.roll(g[f * P:(f + 1) * P, :2], k, axis=0)
    cap[25 * P:, :2] = np.roll(g[25 * P:, :2], 5, axis=0)
    r = score(cap, g, P)
    assert r['first_divergence_frame'] == 20 and r['kind'] == 'walk'

def test_iq_swap_and_rotation_do_not_break_alignment():
    g = golden(30)
    cap = g.copy()
    I, Q = g[:, 0].astype(np.int32), g[:, 1].astype(np.int32)
    cap[:, 0], cap[:, 1] = Q, -I                                   # rotate by 90 degrees then swap rails
    cap[:, 0], cap[:, 1] = cap[:, 1].copy(), cap[:, 0].copy()
    r = score(cap, g, P)
    assert r['first_divergence_frame'] is None and r['unmatched'] == 0

def test_start_offset_is_folded_into_the_anchor():
    g = golden(30)
    cap = g[311:].copy()                                           # capture starts mid-frame
    r = score(cap, g, P)
    assert r['modal_offset'] == 0 and r['first_divergence_frame'] is None
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd two_jup && python3 -m pytest tests/test_score_tapvs_golden.py -q`
Expected: FAIL / ImportError (`score_tapvs_golden` does not exist).

- [ ] **Step 3: Write the scorer**

```python
#!/usr/bin/env python3
"""score_tapvs_golden.py -- anchor-free per-frame displacement of a DDR tap capture vs a
netlist-generated golden stream of the same selector (spec §4.2).

Method: take one reference frame R (length P) from the golden stream. For every capture
window W_n = cap[c0 + n*P : c0 + (n+1)*P], circular complex cross-correlation
|ifft(fft(W) * conj(fft(R)))| gives the lag that best matches; the magnitude is invariant to a
fixed phase rotation and gain, so no quadrant search is needed. Rail swap (I<->Q) is a
conjugation, which is NOT rotation-invariant, so both W and its rail-swapped form are tried and
the better one kept. The anchor c0 is chosen so that the MODAL lag over the whole capture is 0:
the majority state is called "aligned", every other state is reported relative to it (§72
convention: aligned 2,722 frames vs displaced 1,452). A window whose normalised peak is below
MINSCORE is 'unmatched' (None), never counted as a state.

Derived unit under §0: run the sel3 positive control and the sel5 negative control before
crediting any number from a new tap.
"""
import argparse, collections, json, sys
import numpy as np

MARK = 0x7FFF
MINSCORE = 0.5
MINRUN = 3          # a state must persist this many frames to count as a divergence

def load(path):
    a = np.fromfile(path, dtype='<i2')
    return a[:(len(a) // 4) * 4].reshape(-1, 4)

def period_from_markers(gold):
    m = np.flatnonzero(gold[:, 3] == MARK)
    if len(m) < 3:
        m = np.flatnonzero(gold[:, 2] == MARK)
    if len(m) < 3:
        return None
    d = np.diff(m)
    vals, cnts = np.unique(d, return_counts=True)
    return int(vals[cnts.argmax()])

def _cx(a):
    return a[:, 0].astype(np.float64) + 1j * a[:, 1].astype(np.float64)

def _best_lag(w, R_fft, R_norm, P):
    """Return (lag, score, swapped) for window w (complex, length P)."""
    best = (0, -1.0, 0)
    for swapped, ww in ((0, w), (1, np.conj(w) * 1j)):     # rail swap == multiply conj by j
        n = np.linalg.norm(ww)
        if n == 0:
            continue
        xc = np.abs(np.fft.ifft(np.fft.fft(ww) * R_fft))
        k = int(np.argmax(xc))
        s = float(xc[k] / (n * R_norm))
        if s > best[1]:
            best = (k, s, swapped)
    return best

def score(cap, gold, period, max_frames=None):
    P = int(period)
    gm = np.flatnonzero(gold[:, 3] == MARK)
    r0 = int(gm[min(2, len(gm) - 1)]) if len(gm) else 0
    R = _cx(gold[r0:r0 + P])
    R_fft = np.conj(np.fft.fft(R)); R_norm = np.linalg.norm(R)
    c = _cx(cap)
    nfr = (len(c) - P) // P
    if max_frames:
        nfr = min(nfr, max_frames)
    lags, scores, swaps = [], [], []
    for n in range(nfr):
        k, s, sw = _best_lag(c[n * P:(n + 1) * P], R_fft, R_norm, P)
        lags.append(k if s >= MINSCORE else None); scores.append(s); swaps.append(sw)
    placed = [k for k in lags if k is not None]
    if not placed:
        return {'period': P, 'frames': nfr, 'modal_offset': None, 'states': {}, 'first_divergence_frame': None,
                'first_divergence_record': None, 'offset_after': None, 'kind': None, 'unmatched': nfr, 'rows': []}
    modal = collections.Counter(placed).most_common(1)[0][0]
    rel = [None if k is None else (k - modal) % P for k in lags]
    rel = [None if k is None else (k - P if k > P // 2 else k) for k in rel]   # signed, |offset| <= P/2
    states = collections.Counter(k for k in rel if k is not None)
    first_f = first_r = after = kind = None
    n = 0
    while n < len(rel):
        if rel[n] is not None and rel[n] != 0:
            run = [rel[m] for m in range(n, min(n + MINRUN, len(rel))) if rel[m] is not None]
            if len(run) == MINRUN:
                first_f = n; first_r = n * P
                if len(set(run)) == 1:
                    after = run[0]; kind = 'jump'
                else:
                    d = np.diff(run)
                    kind = 'walk' if (np.all(d > 0) or np.all(d < 0)) else 'jump'
                    j = n
                    while j + 1 < len(rel) and rel[j + 1] is not None and rel[j + 1] != rel[j]:
                        j += 1
                    after = rel[j]
                break
        n += 1
    rows = [(i, rel[i], swaps[i], round(scores[i], 4)) for i in range(nfr)]
    return {'period': P, 'frames': nfr, 'modal_offset': 0, 'states': {int(k): int(v) for k, v in states.items()},
            'first_divergence_frame': first_f, 'first_divergence_record': first_r, 'offset_after': after,
            'kind': kind, 'unmatched': sum(1 for k in lags if k is None), 'rows': rows}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('capture'); ap.add_argument('golden')
    ap.add_argument('--period', type=int); ap.add_argument('--max-frames', type=int); ap.add_argument('--out')
    a = ap.parse_args()
    cap, gold = load(a.capture), load(a.golden)
    P = a.period or period_from_markers(gold)
    if not P:
        print('no period: golden has no markers and --period not given'); return 2
    r = score(cap, gold, P, a.max_frames)
    rows = r.pop('rows')
    print(f"period {P}: {r['frames']} frames, unmatched {r['unmatched']}, states {dict(sorted(r['states'].items(), key=lambda kv: -kv[1])[:8])}")
    print(f"first divergence: frame {r['first_divergence_frame']} record {r['first_divergence_record']} offset_after {r['offset_after']} kind {r['kind']}")
    if a.out:
        with open(a.out + '.json', 'w') as f: json.dump(r, f, indent=1)
        with open(a.out + '.csv', 'w') as f:
            f.write('frame,offset,swap,score\n')
            for i, o, sw, s in rows: f.write(f"{i},{'' if o is None else o},{sw},{s}\n")
    return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run the tests**

Run: `cd two_jup && python3 -m pytest tests/test_score_tapvs_golden.py -q`
Expected: 5 passed. (The rotation test: a fixed 90° rotation is invisible to the magnitude correlation, and the swap branch catches the rail swap.)

- [ ] **Step 5: Positive control on the sel3 capture already on disk**

```bash
cd two_jup && python3 score_tapvs_golden.py pair/20260901_155752/sel3.bin ../jupiter_240k5_byte/rtl_sim/golden_taps/sel3.bin --out pair/20260901_155752/sel3_vsgolden
python3 - <<'EOF'
import json
r = json.load(open('pair/20260901_155752/sel3_vsgolden.json'))
P = r['period']; rungs = {6176, 6240, 6299, 6363, 6432, 6489, 6548}
disp = {int(k): v for k, v in r['states'].items() if int(k) != 0}
hits = [k for k in disp if abs(k) in rungs or (P - abs(k)) in rungs]   # offsets are signed and modulo P
print('displaced states', sorted(disp.items(), key=lambda kv: -kv[1])[:6], 'kind', r['kind'])
print('PC', 'PASS' if hits and r['kind'] == 'jump' else 'FAIL', 'rung hits', hits)
EOF
```
Expected (from §72, symbol domain): displaced states at 6363 (~1,232 frames) and 6240 (~220 frames), modulo the period and sign convention, `kind == jump`, unmatched frames ≈ the §72 "None" frames plus the 1,259-frame third-state run. **If PC fails, the scorer gets ONE revision (record what changed); a second failure ends the scoring approach and is written up as a question.**

- [ ] **Step 6: Negative control on the sel5 capture**

```bash
python3 score_tapvs_golden.py pair/20260901_155752/sel5.bin ../jupiter_240k5_byte/rtl_sim/golden_taps/sel5.bin --max-frames 1000 --out pair/20260901_155752/sel5_vsgolden_first1000
```
Expected: a clean stretch (choose `--max-frames` to stop before the first §74 displacement; if the capture opens mid-burst, score the aligned run identified in the §74 table instead) reports one state at 0 and `first_divergence_frame None`.

- [ ] **Step 7: Score the sel2 capture on disk (closes or reopens §75, zero rig time)**

```bash
python3 score_tapvs_golden.py pair/20260901_161157_sel2b/sel2.bin ../jupiter_240k5_byte/rtl_sim/golden_taps/sel2.bin --out pair/20260901_161157_sel2b/sel2_vsgolden
```
Expected: one of (a) a displaced state at a rung × 4 (sample domain) with `jump` → displacement exists at RRC output; (b) a single state at 0 across ≥ 2 burst-lengths of frames (≥ 3,000 frames) → RRC output is clean and the fault is between RRC output and symbol-sync output; (c) unmatched fraction > 30 % → tap not readable by this method either; report as such. Append §76 to `two_jup/SESSION_20260830_AUTONOMOUS.md` with the three control results and the sel2 verdict, each labelled [SILICON] (the capture) / [inferred] (the scoring).

- [ ] **Step 8: Commit**

```bash
git add two_jup/score_tapvs_golden.py two_jup/tests/test_score_tapvs_golden.py two_jup/pair/20260901_155752/*_vsgolden*.json two_jup/pair/20260901_161157_sel2b/*_vsgolden*.json two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat: anchor-free tap scorer vs golden stream; sel3 positive control, sel5 negative control, sel2 verdict (§76)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 4: Burst detector

**Files:**
- Create: `two_jup/beat_detect.py`
- Create: `two_jup/tests/test_beat_detect.py`

**Interfaces:**
- CLI: `beat_detect.py FILE [--per-second]` → prints one line per burst `BURST start=<frame|sec> end=<..> frames=<n> mean_errs=<x> rstcs_delta=<d>` and a final `BURSTS n=<count>`; exit 0.
- API: `detect_frames(rows) -> list[dict]` where rows are `(packet, errs, rstcs)`; `detect_seconds(rows) -> list[dict]` where rows are `(t, packets, errs)` cumulative counters.
- Sim rule (spec §3.2): errs ≥ 20 for ≥ 200 consecutive frames, `rstcs` unchanged across the run. Hardware rule: err/s delta ≥ 5,000 for ≥ 2 consecutive seconds (floor is 51 err/s; a burst is ~20k err/s).

- [ ] **Step 1: Write the failing tests**

```python
# two_jup/tests/test_beat_detect.py
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from beat_detect import detect_frames, detect_seconds

def test_clean_run_has_no_burst():
    rows = [(i, 0, 0) for i in range(1, 5000)]
    assert detect_frames(rows) == []

def test_burst_of_250_frames_is_found_with_bounds():
    rows = [(i, 50 if 1000 <= i < 1250 else 0, 0) for i in range(1, 3000)]
    b = detect_frames(rows)
    assert len(b) == 1 and b[0]['start'] == 1000 and b[0]['end'] == 1249 and b[0]['frames'] == 250

def test_short_blip_is_ignored():
    rows = [(i, 50 if 1000 <= i < 1100 else 0, 0) for i in range(1, 3000)]
    assert detect_frames(rows) == []

def test_rstcs_change_is_reported_not_hidden():
    rows = [(i, 50 if 1000 <= i < 1300 else 0, 1 if i >= 1100 else 0) for i in range(1, 3000)]
    b = detect_frames(rows)
    assert len(b) == 1 and b[0]['rstcs_delta'] == 1

def test_seconds_mode_uses_cumulative_deltas():
    rows = []
    p = e = 0
    for t in range(0, 300):
        p += 1250; e += 20000 if 150 <= t < 155 else 51
        rows.append((t, p, e))
    b = detect_seconds(rows)
    assert len(b) == 1 and b[0]['start'] == 150 and b[0]['end'] == 154
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd two_jup && python3 -m pytest tests/test_beat_detect.py -q` → ImportError.

- [ ] **Step 3: Write the detector**

```python
#!/usr/bin/env python3
"""beat_detect.py -- burst detector shared by the sim leg and the hardware soak.
Sim frame log (sim_beat_long / burst_runs format): columns packet errs clks rstcs ...
  burst = errs >= 20 for >= 200 consecutive frames.
--per-second CSV (beat_soak.sh): t,packets,errs cumulative -> burst = d(errs) >= 5000 for >= 2 s.
"""
import sys

def _runs(flags):
    out, start = [], None
    for i, f in enumerate(flags + [False]):
        if f and start is None: start = i
        if not f and start is not None: out.append((start, i - 1)); start = None
    return out

def detect_frames(rows, thresh=20, minlen=200):
    flags = [r[1] >= thresh for r in rows]
    res = []
    for s, e in _runs(flags):
        if e - s + 1 >= minlen:
            errs = [rows[i][1] for i in range(s, e + 1)]
            res.append({'start': rows[s][0], 'end': rows[e][0], 'frames': e - s + 1,
                        'mean_errs': sum(errs) / len(errs), 'rstcs_delta': rows[e][2] - rows[s][2]})
    return res

def detect_seconds(rows, thresh=5000, minlen=2):
    d = [(rows[i][0], rows[i][2] - rows[i - 1][2]) for i in range(1, len(rows))]
    flags = [x[1] >= thresh for x in d]
    res = []
    for s, e in _runs(flags):
        if e - s + 1 >= minlen:
            errs = [d[i][1] for i in range(s, e + 1)]
            res.append({'start': d[s][0], 'end': d[e][0], 'frames': e - s + 1,
                        'mean_errs': sum(errs) / len(errs), 'rstcs_delta': 0})
    return res

def main():
    path = sys.argv[1]; per_sec = '--per-second' in sys.argv
    rows = []
    for l in open(path):
        if l.startswith('#') or l.startswith('t,') or not l.strip(): continue
        p = l.replace(',', ' ').split()
        rows.append((int(p[0]), int(p[1]), int(p[2])) if per_sec else (int(p[0]), int(p[1]), int(p[3]) if len(p) > 3 else 0))
    b = detect_seconds(rows) if per_sec else detect_frames(rows)
    for x in b:
        print(f"BURST start={x['start']} end={x['end']} frames={x['frames']} mean_errs={x['mean_errs']:.1f} rstcs_delta={x['rstcs_delta']}")
    print(f"BURSTS n={len(b)} rows={len(rows)}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run the tests** → `5 passed`.

- [ ] **Step 5: Commit**

```bash
git add two_jup/beat_detect.py two_jup/tests/test_beat_detect.py
git commit -s -m "Beat: burst detector for sim frame logs and hardware per-second soaks

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 5: Long unforced run (Leg A)

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/beat_longrun.sh`
- Output: `jupiter_240k5_byte/rtl_sim/beat_runs/long1_frames.txt`, `long1_status.txt`, `long1.log`

**Interfaces:**
- Consumes: the build chosen in Task 1 Step 4 (`BUILD=fast|flat`), `beat_detect.py`.
- Produces: the frame log; milestone lines in `long1.log`: `MILESTONE 45000 bursts=<n>` etc.

- [ ] **Step 1: Write the launcher**

```bash
#!/bin/bash
# beat_longrun.sh -- launch the long unforced run as a systemd user unit (survives session teardown).
# Usage: beat_longrun.sh NAME NF [BUILD=fast|flat] [extra driver args...]
# Progress: cat beat_runs/NAME_status.txt ; detector: python3 ../../two_jup/beat_detect.py beat_runs/NAME_frames.txt
set -eu
cd "$(dirname "$0")"
NAME=$1; NF=$2; BUILD=${3:-fast}; shift 3 || shift $#
BIN=obj_beat_$BUILD/Vwrap_byte_ddrcap; [ -x "$BIN" ] || { echo "no $BIN -- run build_beat_sim.sh"; exit 1; }
mkdir -p beat_runs
EXTRA=""; [ "$BUILD" = flat ] && EXTRA="--ckpt-every 5000"
cat > beat_runs/$NAME.run.sh <<EOS
#!/bin/bash
cd $(pwd)
echo "START \$(date -Is) NF=$NF BUILD=$BUILD" >> beat_runs/$NAME.log
./$BIN $NF beat_runs/$NAME $EXTRA $* >> beat_runs/$NAME.log 2>&1
echo "END \$(date -Is) rc=\$?" >> beat_runs/$NAME.log
echo "FINAL \$(python3 ../../two_jup/beat_detect.py beat_runs/${NAME}_frames.txt | tail -1)" >> beat_runs/$NAME.log
EOS
systemd-run --user --unit="beat-$NAME-$(date +%H%M%S)" -p TimeoutStopSec=60 --collect /bin/bash beat_runs/$NAME.run.sh
echo "launched; watch beat_runs/${NAME}_status.txt"
```

- [ ] **Step 2: Smoke-test the launcher at 300 frames**

Run: `bash beat_longrun.sh smoke 300 fast && sleep 60 && cat beat_runs/smoke_status.txt beat_runs/smoke.log`
Expected: `packet=256 ...` then `END ... rc=0` and `FINAL BURSTS n=0 rows=3xx`.

- [ ] **Step 3: Launch the real run**

Run: `bash beat_longrun.sh long1 300000 <BUILD from THROUGHPUT.md>`
Then check progress ONLY by reading `beat_runs/long1_status.txt` (a `Monitor`/background file probe, never a foreground sleep loop). At each milestone (packet ≥ 45,000; ≥ 200,000; end) run:
```bash
python3 ../../two_jup/beat_detect.py beat_runs/long1_frames.txt | tail -3
```
and append a `MILESTONE <packet> bursts=<n>` line to `beat_runs/long1.log`.

- [ ] **Step 4: Verdict**

- **Bursts found** → record `start` frames; compare to hardware (first onset ≈ 42,000 frames at 1,250 f/s, second ≈ 192,000). Proceed to Task 8 (mechanism hunt). Label: **reproduced in sim**.
- **Clean to 300,000** → the netlist as simulated does not beat. Append §77 with the exact run length, frames/s, and the sentence "netlist exonerated as simulated; remaining suspects: reset phase vs clk_enable/enb_1_2_0, the AXI/IP wrapper, the input mux path" [reproduced in sim]. Leg B decides the next step (spec §5).

- [ ] **Step 5: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/beat_longrun.sh jupiter_240k5_byte/rtl_sim/beat_runs/long1.log two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat: long unforced netlist run (long1) launcher and verdict

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```
(`beat_runs/*_frames.txt` for 300k frames is ~10 MB: commit it; `*_ckpt_*.bin` go in `.gitignore`.)

---

### Task 6: DDR window → IQ file, and the float column

**Files:**
- Create: `two_jup/ddr_to_iq.py`
- Create: `two_jup/tests/test_ddr_to_iq.py`
- Create: `k5_240/float_tap_window.m`
- Create: `two_jup/float_score_window.sh`

**Interfaces:**
- `ddr_to_iq.py IN.bin OUT.iq [--start REC] [--count N]` → interleaved little-endian int16 I,Q (the format `float_baseline_f1536` reads).
- `float_tap_window(iqfile, outcsv)` → writes `res.perFrame` to CSV and prints `FLOAT_WINDOW frames=%d bitErrors=%d ber=%.3g frameRecovery=%.3f hypStable=%d`.
- `float_score_window.sh CAPTURE.bin START COUNT OUTDIR` → runs both and leaves `OUTDIR/window.iq`, `OUTDIR/float.csv`, `OUTDIR/float.log`.
- Applies to sample-domain taps only (sel0, sel2, sel8): the float receiver does its own timing recovery at 4 sps.

- [ ] **Step 1: Failing test for the cutter**

```python
# two_jup/tests/test_ddr_to_iq.py
import numpy as np, subprocess, sys, os, tempfile
HERE = os.path.dirname(__file__)
def test_cut_writes_only_iq_columns_in_order():
    a = np.arange(40, dtype=np.int16).reshape(10, 4)      # records: [0 1 2 3], [4 5 6 7], ...
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, 'in.bin'), os.path.join(d, 'out.iq')
        a.tofile(src)
        subprocess.check_call([sys.executable, os.path.join(HERE, '..', 'ddr_to_iq.py'), src, dst, '--start', '2', '--count', '3'])
        out = np.fromfile(dst, dtype='<i2')
        assert out.tolist() == [8, 9, 12, 13, 16, 17]
```

- [ ] **Step 2: Run → fails (no script).**

- [ ] **Step 3: Write the cutter**

```python
#!/usr/bin/env python3
"""ddr_to_iq.py -- cut [I,Q] out of DDR 4-word records into the interleaved int16 IQ file
float_baseline_f1536.m reads. --start/--count are in RECORDS (one record = one sample)."""
import argparse, numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('dst')
ap.add_argument('--start', type=int, default=0); ap.add_argument('--count', type=int, default=None)
a = ap.parse_args()
r = np.fromfile(a.src, dtype='<i2'); r = r[:(len(r) // 4) * 4].reshape(-1, 4)
end = len(r) if a.count is None else a.start + a.count
r[a.start:end, :2].astype('<i2').tofile(a.dst)
print(f"wrote {end - a.start} samples from record {a.start}")
```

- [ ] **Step 4: Run → passes.**

- [ ] **Step 5: Write the MATLAB wrapper and the shell wrapper**

```matlab
function res = float_tap_window(iqfile, outcsv)
%FLOAT_TAP_WINDOW  Float receiver (float_baseline_f1536) on one DDR tap window.
% Per-frame CSV + one summary line. Sample-domain taps only (raw input / RRC out).
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here, '..', 'evm'));
res = float_baseline_f1536(iqfile);
writetable(res.perFrame, outcsv);
fprintf('FLOAT_WINDOW frames=%d bitErrors=%d ber=%.3g frameRecovery=%.3f hypStable=%d cfoHz=%.0f\n', ...
    res.nFrames, res.bitErrors, res.ber, res.frameRecovery, res.hypStable, res.cfoAppliedHz);
end
```

```bash
#!/bin/bash
# float_score_window.sh CAPTURE.bin START COUNT OUTDIR -- float column for one sample-domain window.
set -eu
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
CAP=$1; START=$2; COUNT=$3; OUT=$4; mkdir -p "$OUT"
python3 "$D/ddr_to_iq.py" "$CAP" "$OUT/window.iq" --start "$START" --count "$COUNT"
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "cd('$ROOT/k5_240'); float_tap_window('$OUT/window.iq','$OUT/float.csv')" 2>&1 | tee "$OUT/float.log" | grep -E "FLOAT_WINDOW|Error"
```

- [ ] **Step 6: Positive control for the float column: the sim golden sel0 stream decodes clean**

```bash
cd two_jup && bash float_score_window.sh ../jupiter_240k5_byte/rtl_sim/golden_taps/sel0.bin 0 2000000 float_pc_sel0
```
Expected: `FLOAT_WINDOW frames≈40 bitErrors=0 ... hypStable=1`. If bitErrors > 0 on the clean sim stream, the float receiver's mapping or the ROM reference disagrees with the netlist's loopback input; stop and report before scoring any hardware window (this is the G1-class gate of `gates_float_baseline_f1536.m`, applied to the tap format).

- [ ] **Step 7: Commit**

```bash
git add two_jup/ddr_to_iq.py two_jup/tests/test_ddr_to_iq.py k5_240/float_tap_window.m two_jup/float_score_window.sh two_jup/float_pc_sel0/float.log
git commit -s -m "Beat: DDR window to IQ cutter and float-receiver column with sim positive control

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 7: Burst-phased capture script (Leg B, hardware)

**Files:**
- Create: `two_jup/beat_tap_capture.sh`
- Create: `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh`
- Test: dry run with the fakes, then `bash -n` and `shellcheck`

**Interfaces:**
- `beat_tap_capture.sh SEL` with env `B` (default 10.0.0.148), `SZ` (records, default 134217728 = 512 MB), `PERIOD` (s, default 120.2), `LEAD` (s, default 1.5), `THRESH` (err/s, default 3000), `OUT` (default `two_jup/beatcap/<timestamp>_sel<SEL>`), `W` (ssh wrapper), `ARM` (arm script).
- Produces in `OUT/`: `run.log`, `errps.csv` (`t,errps` at 1 s during the wait), `mid.bin` (mid-burst capture), `onset.bin` (predicted-onset capture), `meta.txt` (`T_trigger`, `T_onset_pred`, selector, sizes, pre/post capTAP).

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# beat_tap_capture.sh SEL -- ONE arm on 148 (mode 1), TWO burst-phased 512 MB DDR captures of one selector:
#   mid.bin   : triggered when 0x108 delta > THRESH (guaranteed in-burst, as sel5_capture.sh)
#   onset.bin : launched at T_trigger + PERIOD - LEAD so the ~1.09 s window straddles the NEXT onset
# Rules (each learned the hard way, see sel5_capture.sh): 0x10C set AFTER the arm and verified by
# effect on 0x20C; 1 s polls, one register per poll; capTAP golden before/after each capture or the
# capture is not credited; host-side stat BEFORE the board-side rm; no retry loop.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; ARM=${ARM:-$D/arm148_mode1.sh}; B=${B:-10.0.0.148}
SEL=${SEL:-${1:?usage: beat_tap_capture.sh SEL  (or SEL=n via launch_rig_unit.sh)}}
SZ=${SZ:-134217728}; PERIOD=${PERIOD:-120.2}; LEAD=${LEAD:-1.5}
THRESH=${THRESH:-3000}; GOLD=BCF94856; OUT=${OUT:-$D/beatcap/$(date +%Y%m%d_%H%M%S)_sel$SEL}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
rd(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }
wr(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '$1 $2' > $DRA" >/dev/null 2>&1; }
capture(){ # $1 = name
  local C0 C1 GOT; C0=$(rd 0x20C)
  [ "$(norm "$C0")" = "$GOLD" ] || { log "ABORT $1: capTAP $C0 != golden"; return 4; }
  $W $B "cd /tmp && rm -f g.bin && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/g.bin" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
  [ -e "$OUT/$1.bin" ] && { log "REFUSE: $OUT/$1.bin exists ($(stat -c %s "$OUT/$1.bin") bytes) -- not overwriting"; return 5; }
  $W $B "cat /tmp/g.bin" > "$OUT/$1.bin" 2>/dev/null
  GOT=$(stat -c %s "$OUT/$1.bin" 2>/dev/null || echo 0)
  if [ "$GOT" -ge $(( SZ*4*9/10 )) ]; then $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1; else log "SHORT $1: $GOT bytes -- board file kept"; fi
  C1=$(rd 0x20C); log "$1: $GOT bytes pre=$C0 post=$C1"; echo "$1 bytes=$GOT pre=$C0 post=$C1" >> "$OUT/meta.txt"
  [ "$(norm "$C1")" = "$GOLD" ] || log "WARN $1: post capTAP $C1 not golden -- capture not credited"
}
log "=== beat_tap_capture sel$SEL -> $OUT"
$ARM 2>&1 | tee -a "$OUT/run.log" | grep -q ARM_OK || { log "ARM failed -- stop (no retry)"; exit 3; }
wr 0x10C "0x$(printf %X $(( (SEL<<16) | 3 )))"; sleep 2
C=$(rd 0x20C); [ "$(norm "$C")" = "$GOLD" ] || { log "selector set but capTAP $C != golden -- stop"; exit 4; }
echo "sel=$SEL mux=0x$(printf %X $(( (SEL<<16) | 3 )))" > "$OUT/meta.txt"
echo "t,errps" > "$OUT/errps.csv"; e0=$(( $(rd 0x108) )); T0=$(date +%s.%N); TRIG=""
for w in $(seq 1 300); do
  sleep 1; e1=$(( $(rd 0x108) )); E=$(( (e1-e0)&0xFFFFFFFF )); e0=$e1
  echo "$w,$E" >> "$OUT/errps.csv"
  [ "$E" -gt "$THRESH" ] && { TRIG=$(date +%s.%N); log "TRIGGER errps=$E at +${w}s"; break; }
done
[ -n "$TRIG" ] || { log "no burst in 300 s -- stop"; exit 6; }
echo "T_trigger=$TRIG" >> "$OUT/meta.txt"
capture mid || exit $?
TON=$(python3 -c "print($TRIG + $PERIOD - $LEAD)"); echo "T_onset_pred=$TON" >> "$OUT/meta.txt"
log "waiting $(python3 -c "print(round($TON - $(date +%s.%N), 1))")s for predicted onset (PERIOD=$PERIOD LEAD=$LEAD)"
while [ "$(python3 -c "print(int($(date +%s.%N) < $TON))")" = 1 ]; do sleep 1; done
capture onset || exit $?
log "=== done"
```

- [ ] **Step 2: Write the dry-run fakes**

```bash
#!/bin/bash
# tests/fake_anyssh.sh HOST CMD -- canned 148 for beat_tap_capture.sh dry runs. State in $FAKE_STATE.
S=${FAKE_STATE:-/tmp/fake148}; mkdir -p "$S"; CMD=$2
case "$CMD" in
  *"echo 0x104 >"*) n=$(( $(cat "$S/p" 2>/dev/null || echo 0) + 2500 )); echo $n > "$S/p"; echo $n ;;
  *"echo 0x108 >"*) k=$(( $(cat "$S/k" 2>/dev/null || echo 0) + 1 )); echo $k > "$S/k"
                     e=$(cat "$S/e" 2>/dev/null || echo 0); [ $k -ge 4 ] && e=$((e+20000)) || e=$((e+51)); echo $e > "$S/e"; echo $e ;;
  *"echo 0x20C >"*) echo 0xBCF94856 ;;
  *iio_readdev*)     echo "BOARD $(( ${SZ:-134217728}*4 ))" ;;
  *"cat /tmp/g.bin"*) head -c $(( ${SZ:-1024}*4 )) /dev/zero ;;
  *) : ;;
esac
```
```bash
#!/bin/bash
# tests/fake_arm.sh -- stands in for arm148_mode1.sh in dry runs.
echo "ARM_OK profile=fake fps=1250 capTAP=0xBCF94856"
```

- [ ] **Step 3: Dry run**

```bash
cd two_jup && chmod +x tests/fake_anyssh.sh tests/fake_arm.sh beat_tap_capture.sh && rm -rf /tmp/fake148
W=$PWD/tests/fake_anyssh.sh ARM=$PWD/tests/fake_arm.sh SZ=1024 PERIOD=6 LEAD=1 OUT=/tmp/beatcap_dry bash beat_tap_capture.sh 3
cat /tmp/beatcap_dry/meta.txt; ls -la /tmp/beatcap_dry/
bash -n beat_tap_capture.sh && shellcheck -S warning beat_tap_capture.sh || true
```
Expected: `TRIGGER` on the 4th poll, `mid.bin` and `onset.bin` of 4096 bytes each, `meta.txt` with `T_trigger` and `T_onset_pred`, no `REFUSE`/`ABORT`; second dry run into the same OUT must print `REFUSE` for `mid.bin` (stat-before-overwrite rule).

- [ ] **Step 4: Commit**

```bash
git add two_jup/beat_tap_capture.sh two_jup/tests/fake_anyssh.sh two_jup/tests/fake_arm.sh
git commit -s -m "Beat: burst-phased one-arm DDR capture script (mid-burst + predicted onset) with dry-run fakes

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 8: Hardware captures sel0 then sel2, scored three ways

**Files:**
- Output: `two_jup/beatcap/<ts>_sel0/`, optionally `<ts>_sel2/`; `two_jup/SESSION_20260830_AUTONOMOUS.md` §78

**Interfaces:**
- Consumes: Task 7 script, Task 3 scorer (controls PASSED), Task 6 float column, `golden_taps/sel0.bin`, `golden_taps/sel2.bin`.

- [ ] **Step 1: Pre-flight (read-only, ≤ 3 register reads)**

```bash
cd two_jup && ./anyssh.sh 10.0.0.148 "uptime; ls /tmp/g.bin 2>/dev/null; df /tmp | tail -1"
cat /home/tcollins/modem-status/sentinel.log | tail -3; ls /home/tcollins/modem-status/{RIG_LOCK,SENTINEL_STOP,HALT} 2>/dev/null
```
Expected: no `/tmp/g.bin`, no lock files. If a lock file exists, stop and report.

- [ ] **Step 2: sel0 arm via the sanctioned launcher**

```bash
cd two_jup && bash launch_rig_unit.sh beatcap-sel0-$(date +%H%M%S) beat_tap_capture.sh SEL=0 OUT=$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel0
```
(`SEL` is read from the environment when set, so the `launch_rig_unit.sh` env form works.) Monitor by reading `run.log`; the whole arm is ≈ 6–8 min (70 s arm settle, up to 300 s to the trigger burst, 120 s to the predicted onset, two 512 MB transfers). Expected: two credited captures ≥ 90 % of 512 MB with golden pre/post capTAP.

- [ ] **Step 3: Score sel0**

```bash
G=../jupiter_240k5_byte/rtl_sim/golden_taps/sel0.bin; C=beatcap/<ts>_sel0
python3 score_tapvs_golden.py $C/onset.bin $G --out $C/onset_vsgolden
python3 score_tapvs_golden.py $C/mid.bin   $G --out $C/mid_vsgolden
bash float_score_window.sh $C/onset.bin 0 20000000 $C/float_onset      # ~400 frames around onset
bash float_score_window.sh $C/mid.bin   0 20000000 $C/float_mid
```
Read-out per capture: the scorer's states / first divergence / kind (hardware vs netlist), and `FLOAT_WINDOW bitErrors` (ideal receiver on the same samples).

- [ ] **Step 4: Decide per spec §5**

- sel0 diverges (a displaced state at a rung × 4, jump) → row 2: TX/mux side. Float column: `bitErrors == 0` on the displaced window means framing shift, not corruption. Stop Leg B here; next taps are sel8 and sel11 (write §78 and ask the operator; those arms are not in this plan's budget).
- sel0 clean (single state, unmatched < 10 %) over both captures → run Step 2–3 again with `SEL=2` on a fresh arm. sel2 diverges → row 3 (fault between RRC out and symbol-sync out; Task 10 instrument flash is triggered). sel2 clean → contradiction with §72 unless the sel3 positive control (Task 3) still stands; re-read §75 and report.
- unmatched > 30 % on sel0 → the tap is not readable by this method; ONE scorer revision allowed (Task 3 rule); otherwise report.

- [ ] **Step 5: Write §78 and commit**

```bash
git add two_jup/beatcap/*/{run.log,meta.txt,errps.csv,*_vsgolden.json,float_*/float.log,float_*/float.csv} two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat §78: sel0 (and sel2) burst-phased captures scored vs netlist golden and float receiver

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 9: Mechanism hunt in sim (only if Task 5 found bursts)

**Files:**
- Output: `jupiter_240k5_byte/rtl_sim/beat_runs/onset_dump_*.txt`, `onset_trace_*.fst`, `beat_runs/MECHANISM.md`
- Modify: `jupiter_240k5_byte/rtl_sim/sim_burst_force_txmark.cpp` (add the named force)

- [ ] **Step 1: Dump state around the onset frame K (from the detector)**

Using the flat build and the nearest checkpoint ≤ K−200 (`long1_ckpt_*.bin` if long1 ran on flat; otherwise rerun flat to K with `--ckpt-every 5000` — priced by THROUGHPUT.md):
```bash
./obj_beat_flat/Vwrap_byte_ddrcap $((K+300)) beat_runs/onset --restore beat_runs/long1_ckpt_<n>.bin \
   --dump-at $((K-100)),$((K-1)),$K,$((K+1)),$((K+50)) --trace-at $((K-1)) --trace-frames 3
diff beat_runs/onset_dump_$((K-100)).txt beat_runs/onset_dump_$((K-1)).txt
diff beat_runs/onset_dump_$((K-1)).txt beat_runs/onset_dump_$K.txt
```
Expected: the dumps differ in at most a few of the timing-plane registers (`ss_*`, `ps_ref`, `ta_ref`, `fifo_*`). The FST (3 frames, open with `gtkwave` or `fst2vcd | grep`) shows the beat of the first wrong symbol.

- [ ] **Step 2: Name the state and reproduce it by forcing**

Add a `sel == "beat"` case to `sim_burst_force_txmark.cpp` that sets the named register to its K−1 value at frame 80, rebuild `obj_beat_force`, run 260 frames:
```bash
./obj_beat_force/Vforce 260 80 beat beat_runs/repro_beat; ./obj_beat_force/Vforce 260 80 none beat_runs/repro_none
python3 ../../two_jup/beat_detect.py beat_runs/repro_beat_frames.txt   # detector needs 200 frames: run 400 if borderline
```
Expected: errs/frame ≈ 50 with framesync intact and `rstcs` unchanged from frame 81; `none` = 0. Write `beat_runs/MECHANISM.md`: the register, its drift rate per frame from the dumps (K−100 → K−1), the predicted period from that rate vs the measured ~150,000 frames, and the label **reproduced in sim**.

- [ ] **Step 3: Hardware confirmation of the named block (one arm)**

Choose the ddrcap selector immediately downstream of the named block (sel3 if symbol sync/interpolator, sel2 if RRC, sel6 if Peak_Search/Timing_Adjust) and run Task 7 + Task 3 scoring on it. Expected: displacement present at that tap at onset, absent at the tap immediately upstream (already known from §72/§75/Task 8). Label **proven on silicon**.

- [ ] **Step 4: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/beat_runs/MECHANISM.md jupiter_240k5_byte/rtl_sim/beat_runs/onset_dump_*.txt jupiter_240k5_byte/rtl_sim/sim_burst_force_txmark.cpp two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat §79: mechanism named and reproduced by forcing; hardware confirmation tap

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 10: Instrument flash — DECISION GATE (spec §6.1, only on decision-tree row 3)

This task is reached only if the sim ran clean, sel0 is clean, and sel2 or sel3 diverges. It requires a paired-tap image whose exact tap pair depends on that result, so its design is not written here. **Stop and re-run `superpowers:brainstorming` for the instrument** with these fixed inputs: base = `jupiter_240k5_byte/bd_tap_dualdma.tcl` + `two_jup/skidfix/ddrcap_inject.py`; record layout must carry both taps on the same clock; full rails (`boot_known_good/` restore point, readback verify, two-pass health gate, auto-rollback, no retry loop); two revisions maximum. Do not build it speculatively.

---

### Task 11: Fix flash + soak (spec §6.2)

**Files:**
- Create: `two_jup/beat_soak.sh`
- Fix location: if the mechanism is in HDL-Coder-generated logic, the fix goes into the Simulink model (`jupiter_240k5_byte/*_overlay.m` pattern, then `build_variant_byte.m`/`build_image.sh`); if in wrapper/injector logic, into `ddrcap_inject.py`-style netlist injection. Either way the netlist copy in `rtl_sim/s1_rtl_beatfixN` is what the sim gate runs.

- [ ] **Step 1: Sim gate for the fix**

Build `obj_beat_fix_fast` exactly as `obj_beat_fast` but with `-y s1_rtl_beatfixN/...`, then:
```bash
./obj_beat_fix_force/Vforce 400 80 beat beat_runs/fix_force      # forced state must now be harmless
python3 ../../two_jup/beat_detect.py beat_runs/fix_force_frames.txt    # BURSTS n=0
bash beat_longrun.sh fixlong $((K+20000)) fast                      # unforced past the original onset
```
Expected: `BURSTS n=0` on both; packets/s and the between-burst BIST floor identical to long1.

- [ ] **Step 2: Write the soak script**

```bash
#!/bin/bash
# beat_soak.sh DUR_S OUT.csv -- 1 s poll of 0x104/0x108 on 148 (two reads per second, the minimum for a
# frame-rate/error-rate pair), then the burst detector. Three beat cycles = 750 s.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=${B:-10.0.0.148}; DUR=${1:-750}; OUT=${2:-$D/beatsoak_$(date +%Y%m%d_%H%M%S).csv}
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
echo "t,packets,errs" > "$OUT"
for t in $(seq 0 "$DUR"); do
  R=$($W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo 0x104 > $DRA; cat $DRA; echo 0x108 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -2 | tr '\n' ' ')
  set -- $R; echo "$t,$(( ${1:-0} )),$(( ${2:-0} ))" >> "$OUT"; sleep 1
done
python3 "$D/beat_detect.py" "$OUT" --per-second | tee "${OUT%.csv}.verdict"
```
Dry run: `W=tests/fake_anyssh.sh bash beat_soak.sh 8 /tmp/soak.csv` → the fake's error step produces `BURSTS n=1` (the detector sees the fake's 20k/s step), proving the soak can show a non-null.

- [ ] **Step 3: Flash on 148 with full rails**

Follow `two_jup/skidfix/SKID_BUILD.md` flash chain: bank the current image as `boot_known_good/BOOT.BIN.148.txmark.1cd0cd752aa6` (already banked), copy the new image, readback md5 verify, reboot, two-pass health gate via `arm148_mode1.sh` (ARM_OK twice), auto-rollback on failure, NO retry loop.

- [ ] **Step 4: Three-cycle soak**

```bash
cd two_jup && bash launch_rig_unit.sh beatsoak-$(date +%H%M%S) beat_soak.sh 750 $PWD/beatsoak_fix.csv
```
Expected after ~13 min: `BURSTS n=0 rows=751`, mean packets/s ≥ 1120, errps floor ≈ 51. Also run the same soak once on the pre-fix image for the positive control of the detector on hardware (expected `BURSTS n≥3`). Label **proven on silicon**.

- [ ] **Step 5: Commit**

```bash
git add two_jup/beat_soak.sh two_jup/beatsoak_*.csv two_jup/beatsoak_*.verdict two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat §80: fix image soak, three cycles burst-free; pre-fix soak as detector positive control

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 12: Simulink fixed-point double check (spec §1 item 4, runs last)

**Files:**
- Create: `jupiter_240k5_byte/sim_replay_window_f1536.m`
- Consumes: `build_beat_harness` (local function in `sim_beat_f1536.m`, lines 212–367: the DUT's `adc_dataInI/Q` are driven by `c_adcI/c_adcQ` constants at sample time `1/30.72e6`, `rx_input_select` by `c_rxsel`), an onset IQ window from Task 8 (`ddr_to_iq.py` output), the pre-fix and post-fix model.

- [ ] **Step 1: Copy the harness builder into its own file**

Extract `build_beat_harness` and its helpers (`connect_in`, the `om`/`im` port maps) from `sim_beat_f1536.m` lines 212–367 into `jupiter_240k5_byte/build_beat_harness.m` unchanged, and make `sim_beat_f1536.m` call the file version. Run the existing calibration-only path to prove nothing moved:
```bash
cd jupiter_240k5_byte && BEAT_CAL_ONLY=1 BEAT_FPS=0.07 QPSK_FRAME=f1536 QPSK_SPS=4 /mnt/onetb/MATLAB/R2025b/bin/matlab -batch "run('sim_beat_f1536.m')" 2>&1 | grep -E "CAL_DONE|Error"
```
Expected: `SIM_BEAT_F1536_CAL_DONE mode=rapid ...`.

- [ ] **Step 2: Write the replay script**

```matlab
% sim_replay_window_f1536.m -- replay a captured sample-domain IQ window through the Simulink
% fixed-point model's EXTERNAL ADC port (rx_input_select = true) and log bit_errors_out per frame.
% Usage: IQ=/path/window.iq OUT=/path/replay.csv matlab -batch "run('sim_replay_window_f1536.m')"
KITDIR = fileparts(mfilename('fullpath'));
setenv('QPSK_FRAME','f1536'); setenv('QPSK_SPS','4');
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m'); addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);
cfg = frame_config_k5(); assert(strcmp(cfg.Frame,'f1536'));
sys = 'commhdlQPSKTxRxLoopback'; loop = [sys '/TxRxComposite'];
load_system(sys); set_param(0,'CurrentSystem',sys); evalin('base', get_param(sys,'InitFcn'));
h = build_beat_harness(sys, loop, cfg);
% --- replace the constant ADC drive with the captured window ---
fid = fopen(getenv('IQ'),'r'); raw = fread(fid, Inf, 'int16'); fclose(fid);
I = int16(raw(1:2:end)); Q = int16(raw(2:2:end)); n = numel(I);
Ts = 1/30.72e6;                       % the harness's ADC constant sample time (build_beat_harness: c_adcI)
% One capture record per ADC valid beat: VGen toggles adc_validIn 1-in-2 at 30.72 M, so a sample
% must be presented on every OTHER Ts tick. Hold each sample for two ticks.
tI = timeseries(repelem(I,2), (0:2*n-1)'*Ts); tQ = timeseries(repelem(Q,2), (0:2*n-1)'*Ts);
assignin('base','adcI_ts',tI); assignin('base','adcQ_ts',tQ);
for nm = {'c_adcI','c_adcQ'}, delete_line(h, [nm{1} '/1'], get_param([h '/' nm{1}],'PortConnectivity')); end
delete_block([h '/c_adcI']); delete_block([h '/c_adcQ']);
add_block('simulink/Sources/From Workspace',[h '/adcI'],'VariableName','adcI_ts','SampleTime',num2str(Ts),'OutDataTypeStr','int16','Position',[150 200 220 230]);
add_block('simulink/Sources/From Workspace',[h '/adcQ'],'VariableName','adcQ_ts','SampleTime',num2str(Ts),'OutDataTypeStr','int16','Position',[150 250 220 280]);
im = containers.Map; for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Inport'),1,[]), im(get_param(b{1},'Name')) = struct('port', str2double(get_param(b{1},'Port'))); end
add_line(h,'adcI/1',sprintf('DUT/%d',im('adc_dataInI').port),'autorouting','on');
add_line(h,'adcQ/1',sprintf('DUT/%d',im('adc_dataInQ').port),'autorouting','on');
set_param([h '/c_rxsel'],'Value','true');           % EXTERNAL input
set_param(h,'SimulationMode','rapid','StopTime',num2str(2*n*Ts));
so = sim(h); L = so.logsout;
pk = L.get('packets_out').Values; er = L.get('bit_errors_out').Values;
p = double(pk.Data(:)); e = double(er.Data(:)); [~,ia] = unique(p,'first'); ia = ia(p(ia)>0);
T = table(p(ia), [e(ia(1)); diff(e(ia))], 'VariableNames', {'packet','errs'});
writetable(T, getenv('OUT'));
fprintf('REPLAY_WINDOW frames=%d totalErrs=%d framesWithErrs=%d\n', height(T), sum(T.errs), nnz(T.errs));
```
The `delete_line` call must use the destination port handle form if `PortConnectivity` does not resolve; the equivalent is `delete_line(h, 'c_adcI/1', sprintf('DUT/%d', im('adc_dataInI').port))` after building `im` first (move the `im` block above the deletes).

- [ ] **Step 3: Calibrate the valid-beat count (proves the drive rate is right before trusting a verdict)**

Run the script on the first 5 frames of the sim golden sel0 stream (`ddr_to_iq.py golden_taps/sel0.bin g5.iq --count 250000`) and compare `frames` in `REPLAY_WINDOW` with the 5 frames of input: expected 4–5 decoded frames with `totalErrs=0`. If the frame count is off by 2× or 4×, the hold factor (`repelem(I,2)`) is wrong for this harness's VGen rate; fix the factor to make the count match (and record the measured valid beats per frame ≈ 49,349) before Step 4.

- [ ] **Step 4: The check**

Same onset window (Task 8 `float_onset/window.iq`, ~400 frames ≈ 1.5 h at 0.07 f/s) through (a) the pre-fix model and (b) the post-fix model; and the same window through the pre-fix and post-fix Verilator replays (`rtl_sim/replay_capture.sh` drive, `rx_input_select=1`):
```bash
IQ=$PWD/two_jup/beatcap/<ts>_sel0/float_onset/window.iq OUT=$PWD/two_jup/beatcap/<ts>_sel0/simulink_prefix.csv /mnt/onetb/MATLAB/R2025b/bin/matlab -batch "run('jupiter_240k5_byte/sim_replay_window_f1536.m')" | grep REPLAY_WINDOW
```
Expected: per-frame `errs` columns agree frame-for-frame between Simulink and Verilator for both images (bit-true), and the post-fix pair shows no ~50-error frames where the pre-fix pair does. A Simulink/Verilator disagreement is itself a finding (spec §1): report it, do not adjust either to match.

- [ ] **Step 5: Commit**

```bash
git add jupiter_240k5_byte/build_beat_harness.m jupiter_240k5_byte/sim_beat_f1536.m jupiter_240k5_byte/sim_replay_window_f1536.m two_jup/beatcap/*/simulink_*.csv two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "Beat §81: Simulink fixed-point replay of the onset window agrees with the netlist pre- and post-fix

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

## Ordering and parallelism

1. Task 1 → Task 2 (sim build first; everything else needs the binaries or the golden streams).
2. Task 5 (long run) launches as soon as Task 1's gate passes and runs in the background for hours/days.
3. Tasks 3, 4, 6, 7 are independent of each other once Task 2's golden streams exist; they can run in parallel.
4. Task 8 needs Tasks 3 (controls PASSED), 6, 7. Task 9 needs Task 5's bursts. Task 10 is a gate. Task 11 needs Task 9. Task 12 needs Task 11.

## Findings log

Every task that produces a verdict appends a numbered section (§76 onward) to `two_jup/SESSION_20260830_AUTONOMOUS.md` with: the command, sample counts, and the label proven on silicon / reproduced in sim / inferred.
