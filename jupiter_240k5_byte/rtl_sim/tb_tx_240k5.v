// tb_tx_240k5.v -- S1 Tx-air ground truth for jupiter_240k5_byte.
// Adapted from zed_msggenrom_prbs/rtl_sim/tb_tx_base.v.
// T8 RATE FIX (Rsym=1.92e6, sps8, master commit 270227a): the Transmitter
// rail moved ONE RUNG UP to 15.36e6 model = the generated module's
// enb_1_2_0 (1-in-2 cadence) = 1.92 Msps physical -> TRUE 240 ksym on air.
// Drives that cadence and dumps, per Transmitter-rail beat:
//   beat, dataOutI, dataOutQ (the 8-sps air), modValid, modI, modQ
//   (the true QPSK constellation symbol stream inside QPSK Tx).
// >= 28 frames of 9064 rail beats (25-frame gate + margin).
`timescale 1 ns / 1 ns
module tb_tx_240k5;
  reg clk=0, reset=1, enb_1_2_0=0;
  wire signed [15:0] dataOutI, dataOutQ;
  always #5 clk=~clk;
  reg tog=0;
  always @(posedge clk) begin
    if(reset) begin tog<=0; enb_1_2_0<=0; end
    else begin tog<=~tog; enb_1_2_0<=tog; end
  end
  // jupiter_240k5_byte: the Transmitter carries the byte-path boundary
  // (extWord/extWordAvail/extBitSel/extWordFirst in, extWordPop out).
  // Tie the inputs OFF (extBitSel=0 selects the ROM branch structurally =
  // the tx_data_source=0 regression condition); leave extWordPop open.
  Transmitter dut(.clk(clk),.reset(reset),.enb_1_2_0(enb_1_2_0),
                  .extWord(64'd0),.extWordAvail(1'b0),
                  .extBitSel(1'b0),.extWordFirst(1'b0),
                  .dataOutI(dataOutI),.dataOutQ(dataOutQ),
                  .extWordPop());
  wire modValid            = dut.u_QPSK_Tx.QPSKConstellationValid;
  wire signed [15:0] modI  = dut.u_QPSK_Tx.QPSKConstellationPoints_re;
  wire signed [15:0] modQ  = dut.u_QPSK_Tx.QPSKConstellationPoints_im;
  integer fd; integer beat=0;
  initial begin
    fd=$fopen("tx_240k5_trace.csv","w");
  end
  always @(posedge clk) if(!reset && enb_1_2_0) begin
    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d",beat,dataOutI,dataOutQ,modValid,modI,modQ);
    beat=beat+1;
  end
  initial begin
    repeat(40) @(posedge clk); @(negedge clk); reset=0;
    // 28 frames x 9064 rail beats x 2 clk/beat + margin
    repeat(2*28*9064 + 8000) @(posedge clk);
    $fclose(fd); $display("TB_TX_240K5_DONE beats=%0d",beat); $finish;
  end
endmodule
