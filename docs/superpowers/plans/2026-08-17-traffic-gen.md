# In-Fabric Traffic Generator (`qpsk_traffic_gen`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runtime-configurable in-fabric packet generator (fill length, inter-frame gap) at the TX byte mux, scored by the existing Layer B `-S` scorer, to measure where the modem datapath breaks across rate/gap/length.

**Architecture:** Platform-side Verilog module spliced in the BD between `byte_breakout` and the DUT byte-TX pins (TX mirror of the proven skid splice); pass-through by default, generator on an AXI enable. DUT netlist untouched. Config via a new dual-channel `axi_gpio` at `0x9D400000`. Golden-vector TB gate before any Vivado build.

**Tech Stack:** Verilog-2001 + iverilog (TB), C (golden vectors, linking the real `qpsk_seq.c`), Vivado 2025.1 batch TCL, bash harnesses, existing `-S` scorer.

## Global Constraints

- Build recipe (verbatim, from the spec): `QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_FRAMESTAT=1`; base kit `jupiter_byte_lean_build`; fresh dir `jupiter_byte_tgen_build`.
- Frame geometry: 1528 B = 191 × 64-bit words; header per `host_app_k5/qpsk_frame.h`: `[0..1]`=magic `0x51 0x4B`, `[2..3]`=payload length LE, `[4..7]`=seq LE, `[8..11]`=CRC32 → **constant `0x54474E21` in generated frames** (never computed).
- PN: xorshift32, `x = seq ^ 0x9E3779B9; if (x==0) x=0xDEADBEEF;` then per byte `x^=x<<13; x^=x>>17; x^=x<<5; byte=x&0xFF` — must stay bit-identical to `qpsk_seq_payload()` (`host_app_k5/qpsk_seq.c:5`).
- Byte→word packing: byte *k* of the frame occupies bits `[8*(k%8)+7 : 8*(k%8)]` of word `k/8` (little-endian lanes, matching MM2S).
- `fill_len` clamp: 0–1516. Seq starts at 1 on each enable rising edge. Enable-off mid-frame completes the frame first.
- All long builds `setsid nohup … & disown` with a single watcher. Commits: `git commit -s`, add ONLY named files (pre-commit size guard is armed).
- Rig rails: 146 is never flashed; e49c011b rollback stays banked on 148; every on-rig step's health gate asserts framesync AND `0x1C0` advance; harness exits restore enable=0 + daemons + watchdogs.
- Register writes to `0x9D40000x` go through `/dev/mem` (`devmem`), not the modem DRA latch.

---

### Task 1: Golden-vector utility (the contract, executable)

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/tgen_golden.c`
- Test: its own `--selftest` (header fields + PN spot values)

**Interfaces:**
- Produces: `tgen_golden <seq> <fill_len> <out.bin>` → exactly 1528 bytes: the frame `qpsk_traffic_gen` must emit for that (seq, fill). Also `tgen_golden --selftest`.
- Consumes: `qpsk_seq_payload()` from `host_app_k5/qpsk_seq.c` (linked, not copied).

- [ ] **Step 1: Write the utility**

```c
/* tgen_golden.c -- golden frames for the qpsk_traffic_gen TB.
 * Contract mirror of the RTL: real PN via the ACTUAL qpsk_seq_payload(),
 * header per qpsk_frame.h, CRC field CONSTANT (generator never computes CRC;
 * the -S scorer is pre-CRC). Build:
 *   gcc -O2 -I../../host_app_k5 -o tgen_golden tgen_golden.c ../../host_app_k5/qpsk_seq.c ../../host_app_k5/qpsk_frame.c
 * (qpsk_seq.c pulls qpsk_frame.h helpers; link qpsk_frame.c for qpsk_frame_encode
 *  used elsewhere in seq.c -- we call only qpsk_seq_payload here.) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "qpsk_seq.h"

#define PKT 1528
#define HDR 12
#define TGEN_CRC_CONST 0x54474E21u

static void build(unsigned char *f, uint32_t seq, int fill)
{
    memset(f, 0, PKT);
    f[0] = 0x51; f[1] = 0x4B;                       /* "QK" */
    f[2] = (unsigned char)(fill & 0xFF);            /* payload len LE */
    f[3] = (unsigned char)((fill >> 8) & 0xFF);
    f[4] = (unsigned char)(seq & 0xFF);             /* seq LE */
    f[5] = (unsigned char)((seq >> 8) & 0xFF);
    f[6] = (unsigned char)((seq >> 16) & 0xFF);
    f[7] = (unsigned char)((seq >> 24) & 0xFF);
    f[8]  = (unsigned char)(TGEN_CRC_CONST & 0xFF); /* constant CRC LE */
    f[9]  = (unsigned char)((TGEN_CRC_CONST >> 8) & 0xFF);
    f[10] = (unsigned char)((TGEN_CRC_CONST >> 16) & 0xFF);
    f[11] = (unsigned char)((TGEN_CRC_CONST >> 24) & 0xFF);
    qpsk_seq_payload(f + HDR, fill, seq);           /* the real PN */
}

int main(int argc, char **argv)
{
    unsigned char f[PKT];
    if (argc == 2 && !strcmp(argv[1], "--selftest")) {
        build(f, 1, 1516);
        if (f[0] != 0x51 || f[1] != 0x4B) { puts("FAIL magic"); return 1; }
        if (f[2] != 0xEC || f[3] != 0x05) { puts("FAIL len"); return 1; }   /* 1516 */
        if (f[4] != 1 || f[7] != 0)       { puts("FAIL seq"); return 1; }
        /* PN spot check: seq=1 -> x0 = 1^0x9E3779B9 = 0x9E3779B8; after one
         * round x = ((x^=x<<13),(x^=x>>17),(x^=x<<5)); byte0 = x&0xFF.
         * Computed with the same code path, so assert self-consistency: */
        unsigned char p[4]; qpsk_seq_payload(p, 4, 1);
        if (f[HDR] != p[0] || f[HDR+3] != p[3]) { puts("FAIL pn"); return 1; }
        build(f, 7, 0);
        for (int i = HDR; i < PKT; i++)
            if (f[i]) { puts("FAIL fill0 pad"); return 1; }
        puts("SELFTEST_OK");
        return 0;
    }
    if (argc != 4) { fprintf(stderr, "usage: %s <seq> <fill> <out.bin> | --selftest\n", argv[0]); return 2; }
    uint32_t seq = (uint32_t)strtoul(argv[1], 0, 0);
    int fill = atoi(argv[2]);
    if (fill < 0) fill = 0; if (fill > 1516) fill = 1516;
    build(f, seq, fill);
    FILE *o = fopen(argv[3], "wb");
    if (!o || fwrite(f, 1, PKT, o) != PKT) { perror("write"); return 3; }
    fclose(o);
    return 0;
}
```

- [ ] **Step 2: Build and run the selftest**

Run: `cd jupiter_240k5_byte/rtl_sim && gcc -O2 -I../../host_app_k5 -o tgen_golden tgen_golden.c ../../host_app_k5/qpsk_seq.c ../../host_app_k5/qpsk_frame.c && ./tgen_golden --selftest`
Expected: `SELFTEST_OK`

- [ ] **Step 3: Emit the golden set the TB will consume**

Run: `for s in 1 2 3 4; do ./tgen_golden $s 1516 golden_s${s}_f1516.bin; done; ./tgen_golden 1 100 golden_s1_f100.bin; ./tgen_golden 1 0 golden_s1_f0.bin; ls -la golden_*.bin`
Expected: six 1528-byte files.

- [ ] **Step 4: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/tgen_golden.c
git commit -s -m "tgen: golden-vector utility (real qpsk_seq_payload PN, constant-CRC header contract)"
```
(Do NOT commit the `.bin` outputs — `*.bin` is gitignored by design.)

---

### Task 2: `qpsk_traffic_gen.v` RTL

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/qpsk_traffic_gen.v`

**Interfaces:**
- Produces module `qpsk_traffic_gen` with ports (exact, later tasks depend on them):
  `clk, resetn, ctrl[31:0], gap[31:0], host_data[63:0], host_valid, host_first, host_ready(out), dut_data[63:0](out), dut_valid(out), dut_first(out), dut_ready(in)`.
  `ctrl[0]`=enable, `ctrl[15:4]`=fill_len. Pass-through when enable=0.

- [ ] **Step 1: Write the module**

```verilog
// qpsk_traffic_gen -- in-fabric programmable packet source at the TX byte mux.
// Spec: docs/superpowers/specs/2026-08-17-traffic-gen-design.md
// Pass-through (enable=0, reset default): host pins wired straight through.
// Generate (enable=1): drives {data,valid,first} under the DUT's real ready;
// holds host_ready low so host TX stalls harmlessly at the DMA.
// Frame: 12B header (QK, len LE, seq LE, CRC const 0x54474E21) + fill_len PN
// bytes (xorshift32, bit-compatible with qpsk_seq_payload) + zero pad = 1528B.
// One payload byte per clk; a 64-bit word every 8 clks; 191 words/frame.
// Enable-off mid-frame completes the frame. Seq restarts at 1 on enable rise.
`timescale 1ns/1ps
module qpsk_traffic_gen (
  input  wire        clk,
  input  wire        resetn,
  input  wire [31:0] ctrl,          // [0] enable, [15:4] fill_len
  input  wire [31:0] gap,           // clks frame-end -> next frame-start
  // host side (from byte_breakout)
  input  wire [63:0] host_data,
  input  wire        host_valid,
  input  wire        host_first,
  output wire        host_ready,
  // DUT side
  output wire [63:0] dut_data,
  output wire        dut_valid,
  output wire        dut_first,
  input  wire        dut_ready
);
  localparam integer PKT_BYTES = 1528;
  localparam integer HDR_BYTES = 12;
  localparam [31:0] CRC_CONST = 32'h54474E21;
  localparam S_IDLE = 2'd0, S_BUILD = 2'd1, S_SEND = 2'd2, S_GAP = 2'd3;

  wire        en       = ctrl[0];
  wire [11:0] fill_raw = ctrl[15:4];
  wire [11:0] fill_len = (fill_raw > 12'd1516) ? 12'd1516 : fill_raw;

  reg [1:0]  st;
  reg        en_d;
  reg [31:0] seq;
  reg [31:0] pn;                    // xorshift32 state
  reg [10:0] bidx;                  // byte index 0..1527
  reg [63:0] wreg;                  // word being assembled
  reg [63:0] sreg;                  // word being sent
  reg        s_valid, s_first;
  reg [31:0] gapcnt;
  reg [11:0] fill_lat;              // fill latched per frame

  // one xorshift round (matches qpsk_seq_payload byte step)
  function [31:0] xs; input [31:0] x; reg [31:0] a, b;
    begin a = x ^ (x << 13); b = a ^ (a >> 17); xs = b ^ (b << 5); end
  endfunction
  wire [31:0] pn_seed  = (seq ^ 32'h9E3779B9);
  wire [31:0] pn_init  = (pn_seed == 32'd0) ? 32'hDEADBEEF : pn_seed;

  // current header/pad/PN byte for bidx
  reg [7:0] cb;
  always @* begin
    case (bidx)
      11'd0:  cb = 8'h51;  11'd1: cb = 8'h4B;
      11'd2:  cb = fill_lat[7:0];        11'd3: cb = {4'b0, fill_lat[11:8]};
      11'd4:  cb = seq[7:0];   11'd5: cb = seq[15:8];
      11'd6:  cb = seq[23:16]; 11'd7: cb = seq[31:24];
      11'd8:  cb = CRC_CONST[7:0];   11'd9:  cb = CRC_CONST[15:8];
      11'd10: cb = CRC_CONST[23:16]; 11'd11: cb = CRC_CONST[31:24];
      default: cb = (bidx < (HDR_BYTES + {1'b0,fill_lat})) ? xs(pn)[7:0] : 8'h00;
    endcase
  end

  assign dut_data   = en_d ? sreg    : host_data;
  assign dut_valid  = en_d ? s_valid : host_valid;
  assign dut_first  = en_d ? s_first : host_first;
  assign host_ready = en_d ? 1'b0    : dut_ready;   // stall host while generating

  wire s_fire = s_valid && dut_ready;

  always @(posedge clk) begin
    if (!resetn) begin
      st <= S_IDLE; en_d <= 1'b0; seq <= 32'd1; s_valid <= 1'b0; s_first <= 1'b0;
      bidx <= 11'd0; gapcnt <= 32'd0; fill_lat <= 12'd0;
    end else begin
      // en_d switches the mux only at frame boundaries (never mid-frame)
      if (st == S_IDLE || st == S_GAP) en_d <= en;
      case (st)
        S_IDLE: if (en) begin
          seq <= 32'd1; fill_lat <= fill_len; pn <= pn_init;
          bidx <= 11'd0; st <= S_BUILD;
        end
        S_BUILD: begin                       // 8 bytes -> one word
          wreg[8*(bidx[2:0]) +: 8] <= cb;
          if (bidx >= HDR_BYTES && bidx < (HDR_BYTES + {1'b0,fill_lat}))
            pn <= xs(pn);                    // consume one PN step per payload byte
          if (bidx[2:0] == 3'd7) st <= S_SEND;
          bidx <= bidx + 11'd1;
        end
        S_SEND: begin
          if (!s_valid) begin
            sreg <= wreg; s_valid <= 1'b1;
            s_first <= (bidx == 11'd8);      // word 0 just completed
          end else if (s_fire) begin
            s_valid <= 1'b0; s_first <= 1'b0;
            if (bidx == PKT_BYTES[10:0]) begin   // 1528: frame done
              gapcnt <= gap; st <= S_GAP;
            end else st <= S_BUILD;
          end
        end
        S_GAP: begin
          if (!en && gapcnt == 32'd0) st <= S_IDLE;        // clean stop point
          else if (gapcnt != 32'd0) gapcnt <= gapcnt - 32'd1;
          else begin                                        // next frame
            seq <= seq + 32'd1; fill_lat <= fill_len;
            pn <= ((seq + 32'd1) ^ 32'h9E3779B9) == 32'd0 ? 32'hDEADBEEF
                                                          : ((seq + 32'd1) ^ 32'h9E3779B9);
            bidx <= 11'd0; st <= S_BUILD;
          end
        end
      endcase
      if (st == S_IDLE && !en) seq <= 32'd1;   // re-arm: seq restarts on next rise
    end
  end
endmodule
```

- [ ] **Step 2: Lint**

Run: `cd jupiter_240k5_byte/rtl_sim && iverilog -g2005 -Wall -tnull qpsk_traffic_gen.v`
Expected: no errors (warnings about unused `host_*` in generate mode acceptable).

- [ ] **Step 3: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/qpsk_traffic_gen.v
git commit -s -m "tgen: qpsk_traffic_gen RTL (pass-through mux + seq/PN frame source, fill+gap knobs)"
```

---

### Task 3: TB with golden compare + positive control

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/tb_tgen.v`
- Create: `jupiter_240k5_byte/rtl_sim/run_tgen_tb.sh`

**Interfaces:**
- Consumes: module ports from Task 2; `golden_*.bin` from Task 1.
- Produces: `TGEN_TB_PASS` line; positive-control leg must print `TGEN_TB_MISMATCH` when told to corrupt.

- [ ] **Step 1: Write the TB** (drives ready=1 with periodic stalls; captures 4 frames at fill=1516 then 1 at fill=100 and 1 at fill=0 via re-enable; writes `tb_frames.bin`; compares against concatenated goldens; `+corrupt=1` flips one bit of frame 2 before compare)

```verilog
`timescale 1ns/1ps
module tb_tgen;
  reg clk=0, resetn=0; always #4 clk=~clk;           // 8 ns
  reg [31:0] ctrl=0, gap=0;
  reg [63:0] hd=64'hDEAD_DEAD_DEAD_DEAD; reg hv=0, hf=0;
  wire hr; wire [63:0] dd; wire dv, df; reg dr=1;
  integer corrupt; integer fd; integer nby; integer i, fcnt, stall;
  reg [7:0] mem [0:6*1528-1];

  qpsk_traffic_gen dut(.clk(clk), .resetn(resetn), .ctrl(ctrl), .gap(gap),
    .host_data(hd), .host_valid(hv), .host_first(hf), .host_ready(hr),
    .dut_data(dd), .dut_valid(dv), .dut_first(df), .dut_ready(dr));

  // capture accepted words into mem, with adversarial ready stalls
  always @(posedge clk) begin
    stall = stall + 1;
    dr <= !(stall % 13 == 0);                        // 1-in-13 stall cycles
    if (dv && dr) begin
      for (i = 0; i < 8; i = i + 1)
        mem[nby + i] = dd[8*i +: 8];
      nby = nby + 8;
    end
  end

  task run_frames(input [11:0] fill, input integer n);
    integer target;
    begin
      target = nby + n*1528;
      ctrl = {16'b0, 4'b0, fill, 3'b0, 1'b1};        // wrong slice on purpose? NO:
      ctrl = 32'b0; ctrl[15:4] = fill; ctrl[0] = 1;  // explicit field writes
      wait (nby >= target);
      ctrl[0] = 0;                                   // completes current frame
      repeat (2000) @(posedge clk);
      // full re-arm so seq restarts at 1 for the next fill setting
      resetn = 0; repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    end
  endtask

  initial begin
    corrupt = 0; void'($value$plusargs("corrupt=%d", corrupt));
    nby = 0; stall = 0; fcnt = 0;
    repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
    run_frames(12'd1516, 4);                         // frames seq 1..4 @1516
    run_frames(12'd100, 1);                          // frame seq 1 @100
    run_frames(12'd0, 1);                            // frame seq 1 @0
    if (corrupt) mem[2*1528 + 700] = mem[2*1528 + 700] ^ 8'h01;
    fd = $fopen("tb_frames.bin", "wb");
    for (i = 0; i < nby; i = i + 1) $fwrite(fd, "%c", mem[i]);
    $fclose(fd);
    $display("TB_CAPTURED bytes=%0d frames=%0d", nby, nby/1528);
    $finish;
  end
endmodule
```

- [ ] **Step 2: Write the runner** (`run_tgen_tb.sh`)

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"
gcc -O2 -I../../host_app_k5 -o tgen_golden tgen_golden.c \
    ../../host_app_k5/qpsk_seq.c ../../host_app_k5/qpsk_frame.c
./tgen_golden --selftest
for s in 1 2 3 4; do ./tgen_golden $s 1516 golden_s${s}_f1516.bin; done
./tgen_golden 1 100 golden_s1_f100.bin
./tgen_golden 1 0   golden_s1_f0.bin
cat golden_s1_f1516.bin golden_s2_f1516.bin golden_s3_f1516.bin \
    golden_s4_f1516.bin golden_s1_f100.bin golden_s1_f0.bin > golden_all.bin
iverilog -g2005 -o tb_tgen_vvp tb_tgen.v qpsk_traffic_gen.v
vvp tb_tgen_vvp | tail -2
cmp golden_all.bin tb_frames.bin && echo TGEN_TB_PASS || { echo TGEN_TB_FAIL; exit 1; }
vvp tb_tgen_vvp +corrupt=1 >/dev/null
cmp -s golden_all.bin tb_frames.bin && { echo "POSITIVE_CONTROL_FAILED (corruption not caught)"; exit 1; } \
                                    || echo TGEN_TB_MISMATCH_AS_EXPECTED
echo TB_GATE_GREEN
```

- [ ] **Step 3: Run it; iterate the RTL until green**

Run: `bash jupiter_240k5_byte/rtl_sim/run_tgen_tb.sh`
Expected final lines: `TGEN_TB_PASS`, `TGEN_TB_MISMATCH_AS_EXPECTED`, `TB_GATE_GREEN`.
(The PN pipeline in S_BUILD is the likely first-failure spot — byte-off-by-one between `cb` and the `pn <=` update. Fix in RTL, not in the golden: the golden IS the contract.)

- [ ] **Step 4: Commit**

```bash
git add jupiter_240k5_byte/rtl_sim/tb_tgen.v jupiter_240k5_byte/rtl_sim/run_tgen_tb.sh
git commit -s -m "tgen: TB with golden byte-compare + corruption positive control (build gate)"
```

---

### Task 4: `QPSK_SEQ_RXONLY` host patch

**Files:**
- Modify: `host_app_k5/qpsk_tun.c` (in `seq_run`, ~line 2160; TX call sites 2209 and 2234)

**Interfaces:**
- Produces: env `QPSK_SEQ_RXONLY` (nonzero ⇒ `-S` never submits TX). Banner line `LAYER B: TX DISABLED (QPSK_SEQ_RXONLY) -- pure scorer`.

- [ ] **Step 1: Patch** — in `seq_run` after the `QPSK_SEQ_BATCH` block add:

```c
    /* TGEN (2026-08-17): pure-scorer mode. The in-fabric traffic generator owns
     * TX and holds the byte path's ready low toward the host, so -S TX submits
     * would push against an intentionally stalled DMA. */
    static int seq_rxonly;
    { const char *e = getenv("QPSK_SEQ_RXONLY"); seq_rxonly = (e && *e != '0'); }
    if (seq_rxonly)
        fprintf(stderr, "LAYER B: TX DISABLED (QPSK_SEQ_RXONLY) -- pure scorer\n");
```

and guard both call sites:

```c
        if (!seq_rxonly) seq_tx_fill(&tx_seq, batchf, payload, &tx_next);
```

- [ ] **Step 2: Syntax check**

Run: `gcc -fsyntax-only -Ihost_app_k5 host_app_k5/qpsk_tun.c`
Expected: rc=0.

- [ ] **Step 3: Commit**

```bash
git add host_app_k5/qpsk_tun.c
git commit -s -m "qpsk_tun: QPSK_SEQ_RXONLY -- -S as pure scorer for the in-fabric traffic generator"
```

---

### Task 5: BD splice script `patch_tgen_tcl.py`

**Files:**
- Create: `two_jup/skidfix/patch_tgen_tcl.py`

**Interfaces:**
- Consumes: a fresh build dir's `complete_byte_t8.tcl` (anchor: `puts "BYTE_WIRE_OK"`, same as the skid patcher).
- Produces: idempotent insertion, marker `TGEN_WIRE_OK`; new BD cells `traffic_gen` (module ref) and `tgen_ctrl_gpio` (`axi_gpio`, dual, all-outputs, `0x9D400000`).

- [ ] **Step 1: Write it** (modeled on `patch_complete_tcl.py`; the block below is the payload)

```python
#!/usr/bin/env python3
"""Insert the traffic-gen splice into a fresh complete_byte_t8.tcl. Idempotent."""
import sys

BLOCK = r'''
# ---- TGEN (spec 2026-08-17): qpsk_traffic_gen between byte_breakout and the
# ---- DUT byte-TX pins; config via tgen_ctrl_gpio @0x9D400000 (dual, outputs).
puts "=== TGEN: splice qpsk_traffic_gen into the TX byte path ==="
add_files -norecurse [file join [file dirname [info script]] qpsk_traffic_gen.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference qpsk_traffic_gen traffic_gen
# break the four direct breakout->DUT nets made by bconn above, keep pin handles
foreach {bo dut tg_h tg_d} {
  byte_data  dut_byte_data_in  host_data  dut_data
  byte_valid dut_byte_valid_in host_valid dut_valid
  byte_first dut_byte_first_in host_first dut_first
} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/$bo]]
  if {[llength $n]} { delete_bd_objs $n }
  connect_bd_net [get_bd_pins byte_breakout/$bo]     [get_bd_pins traffic_gen/$tg_h]
  connect_bd_net [get_bd_pins traffic_gen/$tg_d]     [get_bd_pins $HDLCODERIPINST/$dut]
}
set n [get_bd_nets -quiet -of_objects [get_bd_pins byte_breakout/byte_ready]]
if {[llength $n]} { delete_bd_objs $n }
connect_bd_net [get_bd_pins traffic_gen/host_ready] [get_bd_pins byte_breakout/byte_ready]
connect_bd_net [get_bd_pins $HDLCODERIPINST/dut_byte_ready_out] [get_bd_pins traffic_gen/dut_ready]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins axi_adrv9001/adc_1_clk]] [get_bd_pins traffic_gen/clk]
connect_bd_net -net [get_bd_nets -of_objects [get_bd_pins rx_rstn_inverter/Res]]   [get_bd_pins traffic_gen/resetn]
# config GPIO: dual-channel, all outputs, defaults 0 (pass-through at reset)
create_bd_cell -type ip -vlnv [get_ipdefs -filter {NAME == axi_gpio}] tgen_ctrl_gpio
set_property -dict [list CONFIG.C_IS_DUAL 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_ALL_OUTPUTS_2 1 \
  CONFIG.C_GPIO_WIDTH 32 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_DOUT_DEFAULT 0x00000000 \
  CONFIG.C_DOUT_DEFAULT_2 0x00000000] [get_bd_cells tgen_ctrl_gpio]
connect_bd_net [get_bd_pins tgen_ctrl_gpio/gpio_io_o]  [get_bd_pins traffic_gen/ctrl]
connect_bd_net [get_bd_pins tgen_ctrl_gpio/gpio2_io_o] [get_bd_pins traffic_gen/gap]
# attach to the same interconnect that carries byte_ctrl_gpio (0x9D300000):
set bc_intf [get_bd_intf_pins -quiet -of_objects \
  [get_bd_intf_nets -of_objects [get_bd_intf_pins byte_ctrl_gpio/S_AXI]] \
  -filter {MODE == Master}]
set icell [get_bd_cells -of_objects $bc_intf]
set nmi [get_property CONFIG.NUM_MI $icell]
set_property CONFIG.NUM_MI [expr {$nmi + 1}] $icell
set newm [format "M%02d_AXI" $nmi]
connect_bd_intf_net [get_bd_intf_pins $icell/$newm] [get_bd_intf_pins tgen_ctrl_gpio/S_AXI]
# clock/reset for the new M port + gpio: mirror byte_ctrl_gpio's
foreach p {ACLK ARESETN} sfx {s_axi_aclk s_axi_aresetn} {
  set src [get_bd_nets -of_objects [get_bd_pins byte_ctrl_gpio/$sfx]]
  connect_bd_net -net $src [get_bd_pins tgen_ctrl_gpio/$sfx]
  catch { connect_bd_net -net $src [get_bd_pins $icell/${newm}_[string tolower $p]] }
  catch { connect_bd_net -net $src [get_bd_pins $icell/[format "M%02d" $nmi]_[string tolower $p]] }
}
assign_bd_address -target_address_space /sys_ps8/Data \
  [get_bd_addr_segs tgen_ctrl_gpio/S_AXI/Reg] -offset 0x9D400000 -range 64K
if {![llength [get_bd_cells -quiet traffic_gen]]} { puts "TGEN_FAIL: cell missing"; exit 1 }
puts "TGEN_WIRE_OK"
'''

ANCHOR = 'puts "BYTE_WIRE_OK"'

def main():
    path = sys.argv[1]
    src = open(path).read()
    if 'TGEN_WIRE_OK' in src:
        print('patch_tgen: already patched'); return 0
    if ANCHOR not in src:
        print('patch_tgen: FATAL anchor missing'); return 1
    open(path, 'w').write(src.replace(ANCHOR, ANCHOR + '\n' + BLOCK, 1))
    print('patch_tgen: inserted'); return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 2: Dry-run on a scratch copy + idempotency**

Run: `cp jupiter_byte_lean_build/complete_byte_t8.tcl "$HOME/.claude/jobs/"*/tmp/tgen_test.tcl 2>/dev/null || cp jupiter_byte_lean_build/complete_byte_t8.tcl /tmp/tgen_test.tcl; python3 two_jup/skidfix/patch_tgen_tcl.py /tmp/tgen_test.tcl && python3 two_jup/skidfix/patch_tgen_tcl.py /tmp/tgen_test.tcl && grep -c TGEN_WIRE_OK /tmp/tgen_test.tcl`
Expected: `inserted`, then `already patched`, count `1`.

Known-risk note for the implementer: the interconnect clock/reset pin naming (`M0x_ACLK` vs per-port suffixes) varies by interconnect type; the two `catch` lines cover both spellings, and **`validate_bd_design` downstream is the real gate** — a mis-wired port fails validation loudly in the build log, before synthesis.

- [ ] **Step 3: Commit**

```bash
git add two_jup/skidfix/patch_tgen_tcl.py
git commit -s -m "tgen: BD splice patcher (traffic_gen module + tgen_ctrl_gpio @0x9D400000, TGEN_WIRE_OK marker)"
```

---

### Task 6: Build driver + build

**Files:**
- Create: `two_jup/skidfix/run_tgen_build.sh` (clone `run_skid_build3.sh`; deltas below)

- [ ] **Step 1: Create the driver** — copy `run_skid_build3.sh` and change exactly: `FRESH=$ROOT/jupiter_byte_tgen_build`; marker prefix `TGEN_`; the copy step becomes `cp "$KITRTL/qpsk_traffic_gen.v" "$FRESH/"` where `KITRTL=$ROOT/jupiter_240k5_byte/rtl_sim`; the patch step calls `patch_tgen_tcl.py`; the grep gate expects `TGEN_WIRE_OK`. Keep the env recipe, timing gate, and the DCP rail-census step verbatim (PARITY_OK vs lean is REQUIRED — DUT is untouched).

- [ ] **Step 2: Gate: TB must be green first**

Run: `bash jupiter_240k5_byte/rtl_sim/run_tgen_tb.sh | tail -1`
Expected: `TB_GATE_GREEN`. If not green, STOP — do not spend the build.

- [ ] **Step 3: Launch reap-proof + watcher**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
setsid nohup bash two_jup/skidfix/run_tgen_build.sh > tgen_build.log 2>&1 & disown
# one watcher, report once:
# for i in $(seq 1 480); do grep -qE 'TGEN_BUILD_DONE|TGEN_BUILD_FAILED|TIMING_GATE_FAIL' tgen_build.log && break; sleep 30; done; grep -E 'TGEN_WIRE_OK|VALIDATE|TIMING_GATE_(PASS|FAIL)|RAIL_GATE|TGEN_IMAGE_MD5|DONE|FAILED' tgen_build.log
```
Expected: `TGEN_WIRE_OK`, `VALIDATE_OK`, `TIMING_GATE_PASS` (modem_dut WNS ≈ +2.874, lean-identical), `RAIL_GATE ... PARITY_OK`, `TGEN_BUILD_DONE md5=<12>`.

- [ ] **Step 4: Commit driver + bank the md5 in the build log line of the commit message**

```bash
git add two_jup/skidfix/run_tgen_build.sh
git commit -s -m "tgen: build driver (lean recipe, TB gate precondition, TGEN_WIRE_OK + timing + rail-census gates); image <md5> banked"
```

---

### Task 7: Flash + pass-through equivalence (silicon gate 1)

**Files:**
- Create: `two_jup/skidfix/flash_148_tgen.sh` (clone `flash_148_skid2.sh`; `BB=$ROOT/jupiter_byte_tgen_build/...`; takes md5 arg; keep readback/NAK/two-pass health gate/rollback rails; ADD to the health gate: assert `0x1C0` delta > 0 over the probe window)

- [ ] **Step 1: Flash under rails**

Run: `setsid nohup bash two_jup/skidfix/flash_148_tgen.sh <md5-from-task-6> > tgen_flash.log 2>&1 & disown` (+ the standard watcher).
Expected: readback = new md5, NAK=4, `HEALTH_GATE_PASS` incl. `0x1C0` advancing. Any rail failure ⇒ automatic rollback to e49c011b; STOP and report.

- [ ] **Step 2: Pass-through equivalence run** — with `tgen_ctrl_gpio` untouched (reset defaults = pass-through), run one standard forward acceptance point:

Run: `SIDE=A bash two_jup/acceptance_rxq.sh 1`
Expected: PER within the lean band (8.2–8.4 % at last measurement). If materially different, the splice changed passive behavior ⇒ rollback and STOP.

- [ ] **Step 3: Bank both results in `two_jup/skidfix/SKID_BUILD.md`-style note + commit**

```bash
git add two_jup/skidfix/flash_148_tgen.sh two_jup/TGEN_SWEEP.md
git commit -s -m "tgen: flashed <md5> under rails; pass-through equivalence PASS (fwd PER <x>% vs lean band)"
```

---

### Task 8: Generate-mode smoke (silicon gate 2)

- [ ] **Step 1: Loopback + scorer up** — on 148: quiesce watchdog; `0x114 <- 0` via the bringup-sequenced idiom (NOT an ad-hoc mid-stream poke — use the same DRA write batch bringup uses, TX source untouched); start `-S` scorer: `QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 ./qpsk_tun -S -M 16 -r 15360 -d 60`.

- [ ] **Step 2: Enable the generator, benign point** —

```bash
# fill=1516, gap=200000 clks (~1.6 ms => ~415 f/s offered), enable
devmem 0x9D400008 32 200000
devmem 0x9D400000 32 $(( (1516 << 4) | 1 ))
devmem 0x9D400000 32          # readback-verify ctrl
devmem 0x9D400008 32          # readback-verify gap
```

- [ ] **Step 3: Read the verdict** — after the 60 s scorer window: SEQRX line must show `ok` ≈ offered × 60 (±few %), `lost` ≈ 0, buckets 0/0/0/0; `0x1C0` delta ≈ ok × 191. Then `devmem 0x9D400000 32 0` (disable) and confirm `0x1C0` stops advancing within one frame time.
Expected on failure: STOP, bank the SEQRX line + register snapshot, do not proceed to sweeps — this is the point where the word-packing assumption would surface (frames arrive but PN mismatches ⇒ byte-lane order wrong ⇒ fix RTL packing, re-run TB, rebuild).

- [ ] **Step 4: Commit the smoke evidence note** (append to `two_jup/TGEN_SWEEP.md`).

---

### Task 9: Sweep harness + first characterization

**Files:**
- Create: `two_jup/tgen_sweep.sh`

- [ ] **Step 1: Write the harness**

```bash
#!/bin/bash
# tgen_sweep.sh [dwell_s] -- walk {fill,gap} on 148 loopback; one CSV row per point.
# Per point: write regs -> READBACK-VERIFY -> enable -> dwell -> disable -> collect.
# Health gate per point: 0x104 advancing AND 0x1C0 advancing. Exit restores
# enable=0, daemons, watchdogs. Requires the tgen image (Task 7) on 148.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; A=10.0.0.148
DWELL=${1:-60}
GAPS=${GAPS:-"400000 200000 100000 50000 20000 8000 2000 0"}
FILLS=${FILLS:-"1516 700 100 1"}
STAMP=$(date +%Y%m%d_%H%M%S); CSV=$D/tgen_sweep_$STAMP.csv
echo "fill,gap,offered_fps,ok,lost,biterr,torn_zero,torn_stale,scattered,batch_drop,d104,d108,d1C0" > "$CSV"
restore(){ $W $A 'devmem 0x9D400000 32 0' 2>/dev/null
  $W $A 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & exit 0' 2>/dev/null; }
trap restore EXIT
$W $A 'pkill -9 -f "[l]ock_watchdog"; exit 0' 2>/dev/null
for f in $FILLS; do for g in $GAPS; do
  $W $A "devmem 0x9D400008 32 $g; devmem 0x9D400000 32 \$(( ($f << 4) | 1 ))" 2>/dev/null
  RB=$($W $A "echo \$(devmem 0x9D400000 32) \$(devmem 0x9D400008 32)" 2>/dev/null)
  echo "point fill=$f gap=$g readback: $RB"
  case "$RB" in *$(printf '0x%08X' $(( (f << 4) | 1 )))*) : ;; *) echo "READBACK MISMATCH -- abort"; exit 1;; esac
  R=$($W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
    p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); w0=\$((\$(rd 0x1C0)))
    cd /root/host_app_k5 && QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 \
      ./qpsk_tun -S -M 16 -r 15360 -d $DWELL 2>&1 | grep -E 'SEQRX|SEQDMA' | tail -2
    p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108))); w1=\$((\$(rd 0x1C0)))
    echo DELTAS \$((p1-p0)) \$((e1-e0)) \$((w1-w0))" 2>/dev/null)
  $W $A 'devmem 0x9D400000 32 0' 2>/dev/null
  echo "$R" | sed 's/^/  /'
  # parse SEQRX/SEQDMA/DELTAS into the CSV row (awk left concrete in the file)
  echo "$R" | awk -v f=$f -v g=$g -v dw=$DWELL '
    /SEQRX/  { for(i=1;i<=NF;i++){split($i,kv,"="); v[kv[1]]=kv[2]} }
    /SEQDMA/ { for(i=1;i<=NF;i++){split($i,kv,"="); v[kv[1]]=kv[2]} }
    /DELTAS/ { d104=$2; d108=$3; d1c0=$4 }
    END { off = 125000000/(100400+g);
      printf "%s,%s,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", f,g,off,
        v["ok"],v["lost"],v["biterr"],v["torn_zero"],v["torn_stale"],
        v["scattered"],v["batch_drop"],d104,d108,d1c0 }' >> "$CSV"
done; done
echo "SWEEP_DONE $CSV"
```

- [ ] **Step 2: Run sweep 1 (rate axis)** — `GAPS="400000 100000 20000 2000 0" FILLS="1516" bash two_jup/tgen_sweep.sh 60`; the knee where `ok/dwell` diverges from `offered_fps` (or buckets/`0x1C0`-freeze fire) is the rate break-point. Bank the CSV path into `two_jup/TGEN_SWEEP.md` with the knee called out.

- [ ] **Step 3: Run sweep 2 (length axis)** at one safe gap; append findings.

- [ ] **Step 4: Restore rig, final commit**

```bash
bash two_jup/restore_known_good.sh
git add two_jup/tgen_sweep.sh two_jup/TGEN_SWEEP.md two_jup/tgen_sweep_*.csv
git commit -s -m "tgen: sweep harness + first rate/length characterization (knee at <gap> clk / <fps> fps)"
```

---

## Self-Review (done at write time)

- **Spec coverage:** architecture/splice (T5–6), registers+readback (T5, T8, T9), frame contract+PN (T1–3), FSM semantics incl. finish-frame-on-disable (T2, TB re-arm covers restart), RXONLY (T4), harness+methodology (T9), rails (T7–9), validation order (T6 gate → T7 pass-through → T8 smoke → T9 sweeps), out-of-scope list untouched. No gaps found.
- **Placeholder scan:** the one intentionally-open detail is interconnect clock-pin naming in T5, which is stated as a named risk with `validate_bd_design` as the hard gate — not a TBD.
- **Type consistency:** module port names in T2 == splice pin names in T5 == TB in T3; `ctrl[15:4]`/`gap[31:0]` consistent across T2/T5/T8/T9; `TGEN_CRC_CONST 0x54474E21` identical in T1 and T2.
