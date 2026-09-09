// wrap_byte_seqbist.v -- SEQ-BIST T0c full-loop sim gate top (2026-09-03).
//
// wrap_byte_tgen.v extended so that the *RTL* traffic generator
// (qpsk_traffic_gen_v2) drives the DUT TX byte pins -- the C++ driver no longer
// regenerates frames -- and rx_seq_checker + cnt_mux32 snoop the DUT RX byte
// pins exactly as two_jup/skidfix/patch_seqbist_tcl.py wires them in the block
// design:
//
//   qpsk_traffic_gen_v2 .dut_{data,valid,first} -> TxRxComposite .byte_{data,valid,first}
//                       .dut_ready              <- TxRxComposite .byte_ready
//   rx_seq_checker .{data,valid,user}           <- TxRxComposite .byte_rx_{data,valid,user}
//                  .ready                       <- byte_rx_ready (the DUT-side ready)
//                  .{en,freeze,tgen_mode}       <- tgen_rx ctrl bits (host GPIO on silicon)
//   cnt_mux32 .c16..c31                         <- rx_seq_checker .cnt0..cnt15
//             .sel                              <- tgen_rx gap word [31:27] on silicon
//
// Internal (fabric) loopback: rx_input_select = 0, tx_data_source = 1, and the
// harness must be paced at cadence 2 (adc_validIn high on even clocks) because
// TxRxComposite.v:480 ties MUX_RxValid_out1 = 1.
//
// SIM-ONLY DIFFERENCES from the block design, all deliberate:
//  * cnt_mux32 slots 0..15 on silicon carry rx_seam_checker (0..7) and
//    tx_starve_witness (8..15).  Neither instance exists in this harness, so
//    slots 0..3 are wired to sim-visible modem counters (count_out,
//    packets_out, cnt_frame_start, byte_fifo_ovf) purely so the mux datapath is
//    exercised end-to-end, and slots 4..15 read 0.  Only slots 16..31 are
//    scored by the gate.
//  * `tx_stall` is a harness-only input with no silicon equivalent: while it is
//    high the TGEN->DUT valid is masked AND the ready returned to the TGEN is
//    masked, so the generator simply pauses mid-frame and the DUT's
//    ByteWordBuffer drains.  That is the G4 forced-starvation mechanism: TX
//    starvation is directly producible by withholding TX data, so a wrapper
//    port is the honest force and needs no --public-flat-rw build (unlike the
//    RX-side accumulator pokes in sim_burst_force.cpp, which have no
//    data-plane equivalent).
//  * bwbCount / bwbAvail / bwbReadyNext / bwbWordFirst are exported so the G4
//    scorer can prove the force actually landed (ByteWordBuffer reached 0)
//    rather than passing vacuously on a stall that was too short.
`timescale 1 ns / 1 ns
module wrap_byte_seqbist
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   // ---- TGEN v2 control (the two devmem words at 0x9D400000 / 0x9D400008) ----
   input  wire [31:0] tgen_ctrl,        // [0] en, [15:4] fill, [31:16] skip_every/corrupt_every
   input  wire [31:0] tgen_gap,         // [26:0] gap clks, [27] 0=skip_every 1=corrupt_every
   input  wire        tx_stall,         // harness-only: starve the ByteWordBuffer
   // ---- checker control (tgen_rx ctrl bits on silicon) ----
   input  wire        chk_en,           // rising edge clears; gates the snoop
   input  wire        chk_freeze,       // bit 3 of 0x9D410000
   input  wire        chk_tgen_mode,
   input  wire [4:0]  mux_sel,          // 0x9D410008 [31:27]
   // ---- RX byte sink ----
   input  wire        byte_rx_ready,
   output wire [63:0] byte_rx_data,
   output wire        byte_rx_valid, byte_rx_last, byte_rx_user,
   // ---- readout ----
   output wire [31:0] mux_q,            // tgen_rx_wit_gpio ch2 @0x9D450008
   output wire [31:0] k16, k17, k18, k19, k20, k21, k22, k23,
   output wire [31:0] k24, k25, k26, k27, k28, k29, k30, k31,
   // ---- modem witnesses ----
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_out, rstcs_count, cfc_est,
   output wire [31:0] byte_fifo_ovf,
   output wire        railEnb,
   // ---- TX seam (emitted-frame accounting + G4 evidence) ----
   output wire        tg_valid, tg_first, tg_ready,
   output wire [31:0] tg_seq,
   output wire [7:0]  bwbCount,
   output wire        bwbReadyNext, bwbAvail, bwbWordFirst, bwbPopEdge);

  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1,ncTI,ncTQ; wire ncV,ncTV;

  // ---------------- TGEN v2 -> DUT TX byte pins ----------------
  wire [63:0] tg_data_raw; wire tg_valid_raw, tg_first_raw;
  wire        byte_ready;                       // DUT-side ready
  wire        tg_ready_in = byte_ready && !tx_stall;
  wire [63:0] dut_byte_data  = tg_data_raw;
  wire        dut_byte_valid = tg_valid_raw && !tx_stall;
  wire        dut_byte_first = tg_first_raw;

  qpsk_traffic_gen_v2 u_tgen (
    .clk(clk), .resetn(!reset),
    .ctrl(tgen_ctrl), .gap(tgen_gap),
    .host_data(64'd0), .host_valid(1'b0), .host_first(1'b0), .host_ready(),
    .dut_data(tg_data_raw), .dut_valid(tg_valid_raw), .dut_first(tg_first_raw),
    .dut_ready(tg_ready_in));

  assign tg_valid = dut_byte_valid;
  assign tg_first = dut_byte_first;
  assign tg_ready = byte_ready;
  assign tg_seq   = u_tgen.seq;

  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(dut_byte_data), .byte_valid(dut_byte_valid),
    .tx_data_source(tx_data_source), .byte_first(dut_byte_first),
    .byte_rx_ready(byte_rx_ready),
    .framestat_pop(32'd0),
    .count_out(count_out), .packets_out(packets_out), .bit_errors_out(bit_errors_out),
    .debugI(ncI), .debugQ(ncQ), .debugValid(ncV), .debugI1(ncI1), .debugQ1(ncQ1),
    .tx_dataOutI(ncTI), .tx_dataOutQ(ncTQ), .tx_validOut(ncTV),
    .cnt_descr_in(nc0), .cnt_frame_start(cnt_frame_start),
    .cnt_vit_reset(nc1), .cnt_deint_valid(nc2),
    .cnt_dec_bits(nc3), .cnt_bist_start(nc4), .dbg_sentinel(nc5),
    .cap_in(nc6), .cap_deint(nc7), .cap_out(cap_out), .cap_cad(),
    .rstcs_count(rstcs_count), .cfc_est(cfc_est),
    .byte_ready(byte_ready),
    .byte_rx_data(byte_rx_data), .byte_rx_valid(byte_rx_valid),
    .byte_rx_last(byte_rx_last), .byte_rx_user(byte_rx_user),
    .byte_fifo_ovf(byte_fifo_ovf));

  // ---------------- rx_seq_checker on the DUT RX byte pins ----------------
  rx_seq_checker u_chk (
    .clk(clk), .rst_n(!reset),
    .en(chk_en), .freeze(chk_freeze), .tgen_mode(chk_tgen_mode),
    .data(byte_rx_data), .valid(byte_rx_valid), .user(byte_rx_user),
    .ready(byte_rx_ready),
    .cnt0(k16), .cnt1(k17), .cnt2(k18),  .cnt3(k19),
    .cnt4(k20), .cnt5(k21), .cnt6(k22),  .cnt7(k23),
    .cnt8(k24), .cnt9(k25), .cnt10(k26), .cnt11(k27),
    .cnt12(k28), .cnt13(k29), .cnt14(k30), .cnt15(k31));

  cnt_mux32 u_mux (
    .clk(clk), .sel(mux_sel),
    .c0(count_out), .c1(packets_out), .c2(cnt_frame_start), .c3(byte_fifo_ovf),
    .c4(32'd0),  .c5(32'd0),  .c6(32'd0),  .c7(32'd0),
    .c8(32'd0),  .c9(32'd0),  .c10(32'd0), .c11(32'd0),
    .c12(32'd0), .c13(32'd0), .c14(32'd0), .c15(32'd0),
    .c16(k16), .c17(k17), .c18(k18), .c19(k19),
    .c20(k20), .c21(k21), .c22(k22), .c23(k23),
    .c24(k24), .c25(k25), .c26(k26), .c27(k27),
    .c28(k28), .c29(k29), .c30(k30), .c31(k31),
    .q(mux_q));

  // T8 rate fix: the rail = 15.36e6 model = enb_1_2_0 (see wrap_byte.v:50)
  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  // ByteWordBuffer ingestion seam (G4 force evidence)
  assign bwbCount     = dut.u_ByteWordBuffer.state_count;
  assign bwbReadyNext = dut.readyNext;
  assign bwbAvail     = dut.avail;
  assign bwbWordFirst = dut.wordFirst;
  assign bwbPopEdge   = dut.PopEdge_out1;
endmodule
