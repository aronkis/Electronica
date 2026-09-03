// tb_dma_contract.v -- DUT<->axi_dmac byte-plane HANDSHAKE CONTRACT testbench
// (SKID_BUILD.md sim gate, 2026-08-14). Pure sim, no netlist needed: the
// question is the handshake contract, not the modem math.
//
// Models, each sourced from the codebase:
//  * DUT presenter (util_axis_byte_breakout_m.v + byte_rxfifo_overlay.m):
//    one fresh 64-bit word every GAP cycles; unaccepted beats are SUPERSEDED
//    (drop-on-stall, counted); TUSER on word 0, TLAST on word 190 of each
//    191-word frame; SOF-prime guard = valid MASKED for GUARD cycles after
//    every ready rise, but PRESENTED while ready is low (this is what lets
//    the DMA observe tvalid&&tuser to sync -- required for e49c011b to work
//    at all under SYNC_TRANSFER_START).
//  * axi_dmac S2MM sink: descriptor engine (queued, per-packet TLAST mode);
//    SYNC_TRANSFER_START: ready stays LOW until tvalid&&tuser is OBSERVED at
//    the input; 5-cycle SOF prime after sync in which a held-valid input
//    beat is RECORDED each cycle (the +32B replication bug byte_rxfifo's
//    guard exists to dodge); then word-counted acceptance until the frame's
//    TLAST; short inter-descriptor gap.
//  * the tick: a mid-descriptor ready stall of TICK_STALL cycles on the
//    pair-beat schedule (two hits 8 frames apart per 32-frame super-period,
//    LFSR-gated p~0.7) -- the FWD_SINGLES generator class as seen from this
//    boundary: with direct wiring the DUT supersedes ~2-3 words per hit and
//    the slice delivers full-length WRONG content.
//
// MODE plusarg: 0=direct (e49c011b wiring)  1=naive skid v1  2=guarded v2.
// +tick=0/1, +frames=N, +coldwidx=W (DUT starts mid-frame at word W).
// Scoreboard: wcnt (accepted beats at DUT pins = the 0x1C0 analog), drops,
// prime replicas, per-slice corruption vs expected pattern, deadlock flag,
// and the delivered word stream dumped to +dump=<file> for bitwise A/B.

`timescale 1ns/1ps

// ------------------------------------------------------------------ DUT side
module dut_presenter #(
  parameter GAP   = 64,
  parameter GUARD = 8,
  parameter WPF   = 191
)(
  input  wire clk, rstn,
  input  wire ready,
  output wire valid,
  output wire [63:0] data,
  output wire last, user,
  output reg  [31:0] wcnt,
  output reg  [31:0] drops,
  input  wire [15:0] start_widx
);
  reg [15:0] frame_no, widx;
  reg [31:0] cyc;
  reg        pending;
  reg [63:0] pdata; reg plast, puser;
  reg        started;

  // guard: mask valid for GUARD cycles after each ready rise; present while low
  reg [7:0] rise_cnt;
  wire masked = ready && (rise_cnt < GUARD[7:0]);
  assign valid = pending && !masked;
  assign data = pdata; assign last = plast; assign user = puser;
  wire fire = valid && ready;

  wire [63:0] pat = {16'hBEEF, frame_no, widx, ~widx};

  always @(posedge clk) begin
    if (!rstn) begin
      frame_no <= 0; widx <= start_widx; cyc <= 0; pending <= 0;
      wcnt <= 0; drops <= 0; rise_cnt <= 0; started <= 0;
    end else begin
      if (ready) begin if (rise_cnt != 8'hff) rise_cnt <= rise_cnt + 1; end
      else rise_cnt <= 0;

      if (fire) begin wcnt <= wcnt + 1; pending <= 0; end

      cyc <= cyc + 1;
      if (cyc % GAP == GAP-1) begin
        // new word from the serializer: supersede any unaccepted beat
        if (pending && !fire) drops <= drops + 1;
        pdata  <= pat;
        puser  <= (widx == 0);
        plast  <= (widx == WPF-1);
        pending <= 1'b1;
        if (widx == WPF-1) begin widx <= 0; frame_no <= frame_no + 1; end
        else widx <= widx + 1;
      end
    end
  end
endmodule

// ------------------------------------------------------------------ DMA side
module dma_model #(
  parameter PRIME      = 5,
  parameter WPF        = 191,
  parameter GAP_CYC    = 4,      // inter-descriptor gap (queued M=16: tiny)
  parameter MEMW       = 1 << 21
)(
  input  wire clk, rstn,
  input  wire tvalid,
  input  wire [63:0] tdata,
  input  wire tlast, tuser,
  output wire tready,
  input  wire tick_en,
  input  wire [31:0] gap_cyc_dut,     // DUT word gap, for the stall length
  output reg [31:0] words_rec, descs, prime_reps, stalls_done
);
  // prime = the FIRST PRIME cycles of ready-high after sync (the overlay's
  // "SOF_GUARD cycles (> the 5-cycle prime)" places it INSIDE ready-high,
  // which is exactly what lets the DUT guard mask it).
  localparam S_GAP = 0, S_SYNC = 1, S_RUN = 3;
  reg [1:0] st;
  reg [15:0] gcnt, pcnt;
  reg [31:0] wcnt_desc;

  // recorded stream + per-descriptor boundaries (the host's slice view)
  reg [63:0] mem [0:MEMW-1];
  reg [31:0] wptr;
  reg [31:0] dstart [0:8191];
  reg [31:0] dlen   [0:8191];

  // tick scheduler: per 32-frame super-period (in ACCEPTED words), two hits
  // 8 frames apart, LFSR-gated p=0.7 (11/16), stall = 2.5 DUT word gaps.
  reg [15:0] lfsr;
  reg [31:0] since_sp;                  // accepted words since super-period start
  reg [31:0] stall_cnt;
  reg        hit1_armed, hit2_armed, hit1_go, hit2_go;
  wire [31:0] SP    = 32 * WPF;
  wire [31:0] OFF1  = 5 * WPF + 40;     // mid-frame offsets inside the SP
  wire [31:0] OFF2  = 13 * WPF + 40;    // pair: 8 frames later
  wire [31:0] STALL = (gap_cyc_dut * 9) / 2;

  wire stalled = (stall_cnt != 0);
  assign tready = (st == S_RUN) && !stalled;

  wire fire = tvalid && tready;

  always @(posedge clk) begin
    if (!rstn) begin
      st <= S_GAP; gcnt <= GAP_CYC[15:0]; pcnt <= 0; wcnt_desc <= 0;
      wptr <= 0; words_rec <= 0; descs <= 0; prime_reps <= 0;
      lfsr <= 16'hACE1; since_sp <= 0; stall_cnt <= 0; stalls_done <= 0;
      hit1_armed <= 1; hit2_armed <= 1; hit1_go <= 0; hit2_go <= 0;
    end else begin
      if (stalled) stall_cnt <= stall_cnt - 1;
      case (st)
        S_GAP: begin
          if (gcnt != 0) gcnt <= gcnt - 1;
          else st <= S_SYNC;
        end
        S_SYNC: begin
          // SYNC_TRANSFER_START: OBSERVE tvalid&&tuser, no acceptance
          if (tvalid && tuser) begin
            st <= S_RUN; pcnt <= 0;
            dstart[descs] <= wptr;
          end
        end
        S_RUN: begin
          // SOF prime: first PRIME cycles of ready-high -- a beat HELD valid
          // here is recorded each cycle (replication bug). The DUT guard
          // (valid masked 8 > 5 cycles after the rise) keeps this window
          // empty with direct wiring; a skid that holds tvalid does not.
          if (pcnt < PRIME[15:0]) begin
            pcnt <= pcnt + 1;
            if (tvalid && !fire) begin
              mem[wptr] <= tdata; wptr <= wptr + 1;
              prime_reps <= prime_reps + 1;
            end
          end
          if (fire) begin
            mem[wptr] <= tdata; wptr <= wptr + 1;
            words_rec <= words_rec + 1;
            wcnt_desc <= wcnt_desc + 1;
            // tick schedule bookkeeping (accepted-word clock)
            since_sp <= since_sp + 1;
            if (since_sp + 1 == SP) begin
              since_sp <= 0; hit1_armed <= 1; hit2_armed <= 1;
              lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
              hit1_go <= (lfsr[3:0] < 11);  // p ~ 0.69
              hit2_go <= (lfsr[7:4] < 11);
            end
            if (tick_en && hit1_armed && hit1_go && since_sp + 1 == OFF1) begin
              stall_cnt <= STALL; hit1_armed <= 0; stalls_done <= stalls_done + 1;
            end
            if (tick_en && hit2_armed && hit2_go && since_sp + 1 == OFF2) begin
              stall_cnt <= STALL; hit2_armed <= 0; stalls_done <= stalls_done + 1;
            end
            // per-packet TLAST mode: descriptor completes at frame end
            if (tlast) begin
              st <= S_GAP; gcnt <= GAP_CYC[15:0];
              dlen[descs] <= wptr + 1 - dstart[descs];
              descs <= descs + 1;
              wcnt_desc <= 0;
            end
          end
        end
      endcase
    end
  end
endmodule

// ------------------------------------------------------------------ top
module tb_dma_contract;
  reg clk = 0, rstn = 0;
  always #5 clk = ~clk;

  integer MODE, TICK, FRAMES, COLDW;
  reg [1023:0] DUMPF;
  integer dumpfd, mode_has_dump;

  localparam GAP = 64, WPF = 191, GUARD = 8;

  // DUT presenter
  wire d_valid, d_last, d_user; wire [63:0] d_data; wire d_ready;
  wire [31:0] wcnt, drops;
  dut_presenter #(.GAP(GAP), .GUARD(GUARD), .WPF(WPF)) u_dut (
    .clk(clk), .rstn(rstn), .ready(d_ready),
    .valid(d_valid), .data(d_data), .last(d_last), .user(d_user),
    .wcnt(wcnt), .drops(drops), .start_widx(COLDW[15:0]));

  // DMA sink
  wire m_valid, m_last, m_user, m_ready; wire [63:0] m_data;
  wire [31:0] words_rec, descs, prime_reps, stalls_done;
  reg  tick_en;
  dma_model #(.PRIME(5), .WPF(WPF), .GAP_CYC(4)) u_dma (
    .clk(clk), .rstn(rstn),
    .tvalid(m_valid), .tdata(m_data), .tlast(m_last), .tuser(m_user),
    .tready(m_ready), .tick_en(tick_en), .gap_cyc_dut(GAP),
    .words_rec(words_rec), .descs(descs), .prime_reps(prime_reps),
    .stalls_done(stalls_done));

  // ---- mode wiring ----
  // v1 naive skid
  wire v1_sready, v1_mvalid, v1_mlast, v1_muser; wire [63:0] v1_mdata;
  wire [31:0] v1_wit;
  qpsk_axis_skid u_v1 (.aclk(clk), .aresetn(rstn),
    .s_axis_tdata(d_data), .s_axis_tvalid(d_valid && MODE==1),
    .s_axis_tready(v1_sready), .s_axis_tlast(d_last), .s_axis_tuser(d_user),
    .m_axis_tdata(v1_mdata), .m_axis_tvalid(v1_mvalid),
    .m_axis_tready(m_ready && MODE==1), .m_axis_tlast(v1_mlast),
    .m_axis_tuser(v1_muser), .witness(v1_wit));
  // v2 guarded skid
  wire v2_sready, v2_mvalid, v2_mlast, v2_muser; wire [63:0] v2_mdata;
  wire [31:0] v2_wit, v2_flush;
  qpsk_axis_skid_v2 #(.ENGAGE_WIN(4096), .STALE_WIN(4096), .RISE_MASK(8))
  u_v2 (.aclk(clk), .aresetn(rstn),
    .s_axis_tdata(d_data), .s_axis_tvalid(d_valid && MODE==2),
    .s_axis_tready(v2_sready), .s_axis_tlast(d_last), .s_axis_tuser(d_user),
    .m_axis_tdata(v2_mdata), .m_axis_tvalid(v2_mvalid),
    .m_axis_tready(m_ready && MODE==2), .m_axis_tlast(v2_mlast),
    .m_axis_tuser(v2_muser), .witness(v2_wit), .flush_drops(v2_flush));

  assign d_ready = (MODE==0) ? m_ready : (MODE==1) ? v1_sready : v2_sready;
  assign m_valid = (MODE==0) ? d_valid : (MODE==1) ? v1_mvalid : v2_mvalid;
  assign m_data  = (MODE==0) ? d_data  : (MODE==1) ? v1_mdata  : v2_mdata;
  assign m_last  = (MODE==0) ? d_last  : (MODE==1) ? v1_mlast  : v2_mlast;
  assign m_user  = (MODE==0) ? d_user  : (MODE==1) ? v1_muser  : v2_muser;

  // deadlock detector: no DMA acceptance for 40 frames' worth of cycles
  integer last_rec_cyc; integer cyc;
  reg deadlock;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (words_rec != 0 && $time > 0) begin end
  end
  integer words_prev;
  always @(posedge clk) begin
    if (!rstn) begin last_rec_cyc <= 0; deadlock <= 0; words_prev <= 0; end
    else begin
      if (words_rec != words_prev) begin words_prev <= words_rec; last_rec_cyc <= cyc; end
      else if (cyc - last_rec_cyc > 40*WPF*GAP) deadlock <= 1;
    end
  end

  // ---- scoring ----
  integer f, w, base, nslices, ncorrupt, ok;
  reg [63:0] mw;
  integer expfr, expwx;
  integer runcycles;

  initial begin
    if (!$value$plusargs("mode=%d", MODE))   MODE = 0;
    if (!$value$plusargs("tick=%d", TICK))   TICK = 0;
    if (!$value$plusargs("frames=%d", FRAMES)) FRAMES = 200;
    if (!$value$plusargs("coldwidx=%d", COLDW)) COLDW = 57;
    mode_has_dump = $value$plusargs("dump=%s", DUMPF);
    tick_en = (TICK != 0);
    cyc = 0;
    rstn = 0; repeat (10) @(posedge clk); rstn = 1;

    runcycles = (FRAMES + 4) * WPF * GAP;
    repeat (runcycles) @(posedge clk);

    // per-descriptor scoring = the host's per-slice CRC view: a descriptor
    // is corrupt if it did not record exactly WPF words in perfect sequence.
    nslices = 0; ncorrupt = 0;
    for (f = 0; f < u_dma.descs; f = f + 1) begin
      base = u_dma.dstart[f];
      ok = (u_dma.dlen[f] == WPF);
      mw = u_dma.mem[base];
      expfr = mw[47:32];
      if (ok) begin
        for (w = 0; w < WPF; w = w + 1) begin
          mw = u_dma.mem[base + w];
          if (mw[63:48] !== 16'hBEEF || mw[47:32] !== expfr[15:0] ||
              mw[31:16] !== w[15:0]  || mw[15:0]  !== ~w[15:0]) ok = 0;
        end
      end
      nslices = nslices + 1;
      if (!ok) ncorrupt = ncorrupt + 1;
    end

    if (mode_has_dump) begin
      dumpfd = $fopen(DUMPF, "w");
      for (w = 0; w < u_dma.wptr; w = w + 1)
        $fwrite(dumpfd, "%016x\n", u_dma.mem[w]);
      $fclose(dumpfd);
    end

    $display("RESULT mode=%0d tick=%0d frames=%0d coldwidx=%0d", MODE, TICK, FRAMES, COLDW);
    $display("RESULT wcnt=%0d expected_words=%0d drops=%0d", wcnt, FRAMES*WPF, drops);
    $display("RESULT words_rec=%0d descs=%0d prime_reps=%0d stalls=%0d", words_rec, descs, prime_reps, stalls_done);
    $display("RESULT slices=%0d corrupt=%0d deadlock=%0d", nslices, ncorrupt, deadlock);
    if (MODE==1) $display("RESULT witness_v1=%08x", v1_wit);
    if (MODE==2) $display("RESULT witness_v2=%08x flush_drops=%0d", v2_wit, v2_flush);
    $finish;
  end
endmodule
