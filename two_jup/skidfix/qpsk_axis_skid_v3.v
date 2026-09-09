// qpsk_axis_skid_v3 -- TRANSPARENT WIRE + marker-free GAP WITNESS.
//
// Lessons encoded (see SKID_BUILD.md):
//   v1: masked true readiness -> SYNC deadlock (silicon wcnt=0).
//   v2: guard-preserving capture, TLAST/TUSER-framed witness -> on silicon in
//       production -M mode the stream carries NEITHER marker (tlast_en=0
//       gates TLAST at the breakout; TUSER never fires), so the witness was
//       blind and the unsupervised capture ADDED ~5.6 pp forward PER
//       (13.8-13.9% vs 8.2%, replicated).
// v3 therefore: NO capture at all -- every signal is a combinational
// pass-through (bit-identical datapath to direct/e49c011b wiring) -- and the
// witness needs no frame markers: a word superseded by the DUT's
// drop-on-stall appears at this boundary as an inter-beat gap of ~2x the
// word cadence. v3 measures exactly that:
//   [15:0]  beats        rolling count of accepted beats
//   [23:16] onegap       rolling count of gaps in (1.5x, 2.5x] nominal
//                        (= exactly one word superseded)
//   [30:24] multigap     rolling count of gaps > 2.5x nominal
//   [31]    alive        toggles on every witness update (sampler sanity)
// Nominal inter-beat gap is self-calibrated: a slow EMA of observed gaps,
// so the meter works at any line rate without parameters. Counters ROLL
// (no saturation); the host samples fast and diffs.
// Readout: byte_ctrl_gpio ch2 @ 0x9D300008, as before.

`timescale 1ns/1ps

module qpsk_axis_skid_v3 (
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
  input  wire        aclk,
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
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

  output reg  [31:0] witness
);

  // pure wire -- the datapath is the direct (e49c011b) wiring, verbatim
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tuser  = s_axis_tuser;
  assign s_axis_tready = m_axis_tready;

  wire fire = s_axis_tvalid && m_axis_tready;

  // ---- gap witness ----
  reg [23:0] gap;               // clk since last accepted beat
  reg [23:0] nom;               // EMA of inter-beat gap (self-calibrating)
  reg        nom_seeded;
  reg [15:0] beats;
  reg [7:0]  onegap;
  reg [6:0]  multigap;
  reg        alive;

  // thresholds: 1.5*nom and 2.5*nom (integer, headroom-widened)
  wire [26:0] gap_w   = {3'b0, gap};
  wire [26:0] thr_1p5 = {3'b0, nom} + {4'b0, nom[23:1]};
  wire [26:0] thr_2p5 = {2'b0, nom, 1'b0} + {4'b0, nom[23:1]};
  wire [26:0] nom_x8  = {1'b0, nom, 3'b0};

  always @(posedge aclk) begin
    if (!aresetn) begin
      gap <= 0; nom <= 0; nom_seeded <= 0;
      beats <= 0; onegap <= 0; multigap <= 0; alive <= 0;
      witness <= 32'd0;
    end else begin
      if (fire) begin
        beats <= beats + 16'd1;
        alive <= ~alive;
        if (!nom_seeded) begin
          if (gap != 0) begin nom <= gap; nom_seeded <= 1'b1; end
        end else begin
          if (gap_w > thr_2p5)      multigap <= multigap + 7'd1;
          else if (gap_w > thr_1p5) onegap   <= onegap + 8'd1;
          // EMA over plausible gaps only (ignore idle stretches > 8x nominal)
          if (gap_w < nom_x8)
            nom <= nom + (gap >> 4) - (nom >> 4);
        end
        witness <= {alive, multigap, onegap, beats};
        gap <= 24'd1;
      end else if (gap != 24'hFFFFFF) begin
        gap <= gap + 24'd1;
      end
    end
  end

endmodule
