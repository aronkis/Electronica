// wrap_byte_tgen.v -- short-fill wedge reproduction wrapper (2026-08-18 D0 task).
// Clone of wrap_byte.v (S1B internal-loopback byte gate) for the FLASHED
// generation netlist ($KIT/s1_rtl, cadence 2), plus taps on the suspected
// wedge stage: the Preamble Detector delay FIFO and its
// Validate_Input_Push_Pop guard (pop_on_empty_FIFO / push_on_full_FIFO /
// numEntries), Peak_Search done/success, and Timing_Adjust arm state.
// Tap mechanism = the same Verilator hierarchical-reference assigns
// wrap_byte_taps.v / wrap_byte_lock.v use.
`timescale 1 ns / 1 ns
module wrap_byte_tgen
  (input  wire clk, input wire reset,
   input  wire adc_validIn,
   input  wire signed [15:0] adc_dataInI, input wire signed [15:0] adc_dataInQ,
   input  wire rstCS, input wire rx_input_select,
   input  wire [31:0] skip_count,
   input  wire [31:0] tx_data_source,
   input  wire [63:0] byte_data, input wire byte_valid, input wire byte_first,
   input  wire byte_rx_ready,
   output wire byte_ready,
   output wire [63:0] byte_rx_data,
   output wire byte_rx_valid, output wire byte_rx_last, output wire byte_rx_user,
   output wire [31:0] count_out, packets_out, bit_errors_out,
   output wire [31:0] cnt_frame_start, cap_out, rstcs_count, cfc_est,
   output wire [31:0] byte_fifo_ovf,
   output wire railEnb,
   // ---- Preamble Detector taps ----
   output wire pdV, output wire pdSync,
   output wire [13:0] pdFifoEntries,      // FIFO numEntries (ufix14)
   output wire pdPopOnEmpty,              // Validate_Input_Push_Pop.pop_on_empty_FIFO
   output wire pdPushOnFull,              // Validate_Input_Push_Pop.push_on_full_FIFO
   output wire pdFifoPush, output wire pdFifoPop,
   output wire psDone, output wire psSuccess,
   output wire [13:0] psTimingOffset,
   output wire taArmed,
   // ---- ByteWordBuffer (TX ingestion skid FIFO) debug taps ----
   output wire [7:0] bwbCount,
   output wire bwbReadyNext, output wire bwbAvail, output wire bwbWordFirst,
   output wire bwbPopEdge,
   output wire [63:0] bwbWord,
   // ---- counter-beat taps (2026-08-18 aliasing task) ----
   output wire [13:0] egCount,       // RX Packet_Controller End_Generator (12320 states, sync-slaved)
   output wire egEnd, output wire egRst,
   output wire [13:0] tarefCount,    // Timing_Adjust timing_Reference (12333 states)
   output wire [15:0] dbfWrCount,    // TX Data_Bits_FIFO write counter (49280 states)
   output wire [14:0] dbfRdCount);   // TX Data_Bits_FIFO 24666-state counter
  wire [31:0] nc0,nc1,nc2,nc3,nc4,nc5,nc6,nc7;
  wire signed [15:0] ncI,ncQ,ncI1,ncQ1,ncTI,ncTQ; wire ncV,ncTV;
  TxRxComposite dut(
    .clk(clk), .reset(reset), .clk_enable(1'b1),
    .adc_validIn(adc_validIn), .adc_dataInI(adc_dataInI), .adc_dataInQ(adc_dataInQ),
    .rstCS(rstCS), .iq_debug_mux(32'd0), .rx_input_select(rx_input_select),
    .host_txI(16'sd0), .host_txQ(16'sd0), .host_txValid(1'b0),
    .tx_source_select(32'd0), .skip_count(skip_count),
    .byte_data(byte_data), .byte_valid(byte_valid),
    .tx_data_source(tx_data_source), .byte_first(byte_first),
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
  // T8 rate fix: the rail = 15.36e6 model = enb_1_2_0 (see wrap_byte.v:50)
  assign railEnb = dut.u_TxRxComposite_tc.enb_1_2_0;
  // Preamble Detector stage (hierarchy as wrap_byte_lock.v)
  assign pdV    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_validOut;
  assign pdSync = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.Preamble_Detector_syncPulse;
  assign pdFifoEntries = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.numEntries;
  assign pdPopOnEmpty  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.pop_on_empty_FIFO;
  assign pdPushOnFull  = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_FIFO.u_Validate_Input_Push_Pop.push_on_full_FIFO;
  assign pdFifoPush    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay8_out1;
  assign pdFifoPop     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Delay10_out1;
  assign psDone        = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.done;
  assign psSuccess     = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.success;
  assign psTimingOffset = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Peak_Search_timingOffset;
  assign taArmed       = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.Timing_Adjust_p1c_armed;
  // counter-beat taps
  assign egCount    = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.u_End_Generator.HDL_Counter_out1;
  assign egEnd      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.End_Generator_endOut;
  assign egRst      = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Packet_Controller.Logical_Operator_out1;
  assign tarefCount = dut.u_Receiver.u_QPSK_Rx.u_Frequency_and_Time_Synchronizer.u_Preamble_Detector.u_Timing_Adjust.timing_Reference_out1;
  assign dbfWrCount = dut.u_Transmitter.u_QPSK_Tx.u_Bit_Packetizer.u_Data_Bits_FIFO.HDL_Counter_out1;
  assign dbfRdCount = dut.u_Transmitter.u_QPSK_Tx.u_Bit_Packetizer.u_Data_Bits_FIFO.HDL_Counter2_out1;
  // ByteWordBuffer ingestion seam
  assign bwbCount     = dut.u_ByteWordBuffer.state_count;
  assign bwbReadyNext = dut.readyNext;
  assign bwbAvail     = dut.avail;
  assign bwbWordFirst = dut.wordFirst;
  assign bwbPopEdge   = dut.PopEdge_out1;
  assign bwbWord      = dut.word;
endmodule
