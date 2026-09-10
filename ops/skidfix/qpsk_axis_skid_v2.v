// qpsk_axis_skid_v2 -- GUARD-PRESERVING skid for the modem byte-plane write
// port (SKID_BUILD.md redesign spec, after flash attempt 2's unconfounded
// silicon fail of the naive v1 skid: fsync=1252 with wcnt=0).
//
// Why v1 failed (named defect): the DUT<->axi_dmac byte handshake is NOT
// plain AXIS. The DUT presents beats while ready is LOW so the DMA's
// SYNC_TRANSFER_START logic can OBSERVE tvalid&&tuser before raising ready,
// and supersedes (drop-on-stall) unaccepted beats so a stale word never
// freezes at the DMA input; the DUT's SOF-prime guard masks valid around
// ready rises because the DMA replicates a held beat x5 during its
// per-descriptor prime. v1 masked true readiness and froze a stale tuser=0
// beat at the DMA input -> sync never observed -> total byte-plane stall.
//
// v2 principles:
//   1. TRANSPARENT unless repairing: when the FIFO is empty, every signal --
//      including s_axis_tready -- is a combinational pass-through, so the
//      DUT's guard, supersede, and the DMA's TUSER observation behave
//      exactly as with direct wiring (e49c011b behavior).
//   2. CAPTURE only the real hazard: a beat presented during a mid-packet
//      ready stall (the control-plane tick). Eligibility: recent downstream
//      acceptance (engaged) AND the last accepted beat was not TLAST (so
//      per-packet descriptor boundaries stay transparent and re-sync on the
//      DUT's live, superseding presentation).
//   3. ANTI-PRIME at the skid: while draining, the held beat is presented
//      during ready-low (observation-safe) but masked for RISE_MASK cycles
//      after every ready rise -- the same discipline as the DUT's own guard.
//   4. NO-FREEZE invariant: any held beat that fails to drain within
//      STALE_WIN cycles is flushed (counted), returning to transparent.
//      Bounded loss identical to today's drop-on-stall; deadlock impossible.
//
// Witness (same 32-bit layout as v1, at byte_ctrl_gpio ch2 0x9D300008):
//   [15:0] beats of last completed frame (expect 191), [23:16] beat-parity
//   mismatches (sat), [30:24] skid captures = repaired would-be drops (sat),
//   [31] sticky alarm. Flush drops are counted in flush_drops (sim-visible;
//   fold into telemetry at next register-map revision).

`timescale 1ns/1ps

module qpsk_axis_skid_v2 #(
  parameter EXPECTED_BEATS = 191,
  parameter DEPTH_LOG2     = 2,    // FIFO depth 4
  parameter ENGAGE_WIN     = 4096, // cycles since last m_fire to stay engaged
  parameter STALE_WIN      = 4096, // held-beat flush watchdog
  parameter RISE_MASK      = 8     // anti-prime valid mask after ready rise
)(
  input  wire        aclk,
  input  wire        aresetn,

  input  wire [63:0] s_axis_tdata,
  input  wire        s_axis_tvalid,
  output wire        s_axis_tready,
  input  wire        s_axis_tlast,
  input  wire        s_axis_tuser,

  output wire [63:0] m_axis_tdata,
  output wire        m_axis_tvalid,
  input  wire        m_axis_tready,
  output wire        m_axis_tlast,
  output wire        m_axis_tuser,

  output reg  [31:0] witness,
  output reg  [31:0] flush_drops
);
  localparam DEPTH = (1 << DEPTH_LOG2);

  reg [65:0] fifo [0:DEPTH-1];          // {user,last,data}
  reg [DEPTH_LOG2:0] count;
  reg [DEPTH_LOG2-1:0] rd, wr;
  wire empty = (count == 0);
  wire full  = (count == DEPTH);

  // engagement: streaming recently, and not at a packet boundary
  reg [15:0] since_fire;                // saturating
  reg        last_fire_was_tlast;
  wire engaged = (since_fire < ENGAGE_WIN[15:0]) && !last_fire_was_tlast;

  // anti-prime rise mask on the downstream ready
  reg [7:0] rise_cnt;
  wire rise_masked = m_axis_tready && (rise_cnt < RISE_MASK[7:0]);

  // ---- combinational datapath ----
  wire [65:0] head = fifo[rd];
  assign m_axis_tdata  = empty ? s_axis_tdata  : head[63:0];
  assign m_axis_tlast  = empty ? s_axis_tlast  : head[64];
  assign m_axis_tuser  = empty ? s_axis_tuser  : head[65];
  // present while ready low (TUSER observation), mask around rises (prime)
  assign m_axis_tvalid = empty ? (s_axis_tvalid && !rise_masked)
                               : !rise_masked;

  // capture eligibility: repairing a mid-packet stall only. CRITICAL: tready
  // must NOT depend on s_axis_tvalid -- a combinational valid->ready path
  // forms an unstable loop against the DUT guard (valid depends on ready);
  // found as a zero-delta oscillation in tb_dma_contract. Registered-state
  // sources only (engaged/full/empty are regs; m_axis_tready is registered
  // in axi_dmac).
  wire capture_win = engaged && !full;
  assign s_axis_tready = empty ? (m_axis_tready || capture_win) : capture_win;

  wire m_fire = m_axis_tvalid && m_axis_tready;
  wire s_fire = s_axis_tvalid && s_axis_tready;
  wire s_to_fifo = s_fire && (!empty || !m_axis_tready);

  // staleness watchdog
  reg [15:0] since_pop;

  integer i;
  always @(posedge aclk) begin
    if (!aresetn) begin
      count <= 0; rd <= 0; wr <= 0;
      since_fire <= 16'hffff; last_fire_was_tlast <= 1'b0;
      rise_cnt <= 0; since_pop <= 0; flush_drops <= 0;
    end else begin
      // rise mask tracking
      if (m_axis_tready) begin
        if (rise_cnt != 8'hff) rise_cnt <= rise_cnt + 8'd1;
      end else rise_cnt <= 8'd0;

      // engagement tracking
      if (m_fire) begin
        since_fire <= 16'd0;
        last_fire_was_tlast <= m_axis_tlast;
      end else if (since_fire != 16'hffff) since_fire <= since_fire + 16'd1;

      // fifo push/pop
      if (s_to_fifo) begin
        fifo[wr] <= {s_axis_tuser, s_axis_tlast, s_axis_tdata};
        wr <= wr + 1'b1;
      end
      if (m_fire && !empty) rd <= rd + 1'b1;
      case ({s_to_fifo, (m_fire && !empty)})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase

      // no-freeze invariant: flush a wedged fifo
      if (!empty && !(m_fire)) begin
        since_pop <= since_pop + 16'd1;
        if (since_pop >= STALE_WIN[15:0]) begin
          flush_drops <= flush_drops + count;
          count <= 0; rd <= 0; wr <= 0; since_pop <= 0;
        end
      end else since_pop <= 16'd0;
    end
  end

  // ---- beat-parity witness (s side = what the DUT actually handed over) ----
  reg [15:0] beatcnt;
  reg [7:0]  mism;
  reg [6:0]  capcnt;
  reg        sticky, frame_open;
  wire [7:0] mism_next = (mism == 8'hff) ? 8'hff : (mism + 8'd1);

  always @(posedge aclk) begin
    if (!aresetn) begin
      beatcnt <= 0; mism <= 0; capcnt <= 0; sticky <= 0; frame_open <= 0;
      witness <= 32'd0;
    end else begin
      if (s_to_fifo && capcnt != 7'h7f) capcnt <= capcnt + 7'd1;
      if (s_fire) begin
        if (s_axis_tuser) begin
          if (frame_open && beatcnt != EXPECTED_BEATS[15:0]) begin
            mism <= mism_next; sticky <= 1'b1;
            witness <= {1'b1, capcnt, mism_next, beatcnt};
          end else witness <= {sticky, capcnt, mism, beatcnt};
          beatcnt <= 16'd1; frame_open <= 1'b1;
        end else if (beatcnt != 16'hffff) beatcnt <= beatcnt + 16'd1;
      end
    end
  end

endmodule
