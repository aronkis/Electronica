// qpsk_axis_skid -- 1-deep AXIS skid buffer + beat-parity witness for the
// modem byte-plane write port (TICK_FIX_SIM.md section 2, hardware form).
//
// Sits between rx_byte_breakout/m_axis (the ByteSerializer AXIS master) and
// rx_byte_dma/s_axis (the platform byte-FIFO/DMA write port). The sim-
// validated guard: a downstream write-port stall (tready low for a beat)
// no longer reaches the DUT's drop-on-stall decision -- the beat is captured
// in the skid register and retried; s_axis_tready only drops while the skid
// is occupied (<= the stall length, and byte-plane beats are >= ~512 clk
// apart at line rate, so the skid always drains long before the next word).
//
// Beat-parity witness (TICK_FIX_SIM section 2.2): per-frame accepted-beat
// count on the DUT side, delimited by TUSER (packet-start marker, present in
// both tlast_en modes). Expected EXPECTED_BEATS words per frame; a mismatch
// increments a saturating counter and sets a sticky alarm. The 32-bit
// witness word is latched once per frame (stable ~800 us between updates,
// so the async GPIO read cannot tear mid-count in practice):
//   [15:0]  beat count of the last completed frame (expect 191 = 0x00BF)
//   [23:16] frame beat-parity mismatch count (saturating)
//   [30:24] skid capture events = would-be swallowed beats (saturating)
//   [31]    sticky alarm (any mismatch since reset)
// Readout: byte_ctrl_gpio channel 2 data reg = 0x9D300008.

`timescale 1ns/1ps

module qpsk_axis_skid #(
  parameter EXPECTED_BEATS = 191
)(
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
  input  wire        aclk,
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire        aresetn,

  // slave side: from rx_byte_breakout (the DUT's serialized word stream)
  input  wire [63:0] s_axis_tdata,
  input  wire        s_axis_tvalid,
  output wire        s_axis_tready,
  input  wire        s_axis_tlast,
  input  wire        s_axis_tuser,

  // master side: to rx_byte_dma s_axis (the platform write port)
  output reg  [63:0] m_axis_tdata,
  output reg         m_axis_tvalid,
  input  wire        m_axis_tready,
  output reg         m_axis_tlast,
  output reg         m_axis_tuser,

  output reg  [31:0] witness
);

  // ---------------- skid datapath ----------------
  reg [63:0] skid_data;
  reg        skid_last, skid_user, skid_valid;

  assign s_axis_tready = ~skid_valid;
  wire s_fire   = s_axis_tvalid & s_axis_tready;
  wire m_fire   = m_axis_tvalid & m_axis_tready;
  wire out_free = m_fire | ~m_axis_tvalid;

  always @(posedge aclk) begin
    if (!aresetn) begin
      m_axis_tvalid <= 1'b0;
      skid_valid    <= 1'b0;
    end else begin
      if (out_free) begin
        if (skid_valid) begin
          // drain the skid first (ordering preserved: s_axis_tready is low
          // while the skid holds a beat, so no younger beat can slip past)
          m_axis_tdata  <= skid_data;
          m_axis_tlast  <= skid_last;
          m_axis_tuser  <= skid_user;
          m_axis_tvalid <= 1'b1;
          skid_valid    <= 1'b0;
        end else if (s_fire) begin
          m_axis_tdata  <= s_axis_tdata;
          m_axis_tlast  <= s_axis_tlast;
          m_axis_tuser  <= s_axis_tuser;
          m_axis_tvalid <= 1'b1;
        end else begin
          m_axis_tvalid <= 1'b0;
        end
      end else if (s_fire) begin
        // output stalled with a beat in flight: capture instead of exposing
        // the stall to the DUT (the swallow this module exists to prevent)
        skid_data  <= s_axis_tdata;
        skid_last  <= s_axis_tlast;
        skid_user  <= s_axis_tuser;
        skid_valid <= 1'b1;
      end
    end
  end

  // ---------------- beat-parity witness ----------------
  reg [15:0] beatcnt;
  reg [7:0]  mism;
  reg [6:0]  skidcnt;
  reg        sticky, frame_open;

  wire skid_capture = s_fire & ~out_free;
  wire [7:0] mism_next = (mism == 8'hff) ? 8'hff : (mism + 8'd1);

  always @(posedge aclk) begin
    if (!aresetn) begin
      beatcnt    <= 16'd0;
      mism       <= 8'd0;
      skidcnt    <= 7'd0;
      sticky     <= 1'b0;
      frame_open <= 1'b0;
      witness    <= 32'd0;
    end else begin
      if (skid_capture && skidcnt != 7'h7f)
        skidcnt <= skidcnt + 7'd1;

      if (s_fire) begin
        if (s_axis_tuser) begin
          // frame boundary: score the frame that just closed
          if (frame_open && beatcnt != EXPECTED_BEATS[15:0]) begin
            mism    <= mism_next;
            sticky  <= 1'b1;
            witness <= {1'b1, skidcnt, mism_next, beatcnt};
          end else begin
            witness <= {sticky, skidcnt, mism, beatcnt};
          end
          beatcnt    <= 16'd1;
          frame_open <= 1'b1;
        end else if (beatcnt != 16'hffff) begin
          beatcnt <= beatcnt + 16'd1;
        end
      end
    end
  end

endmodule
