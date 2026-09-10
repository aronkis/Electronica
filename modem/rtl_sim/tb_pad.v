`timescale 1ns/1ns
// tb_pad.v -- unit test of the RXFIX_PAD ByteSerializer: frames A (full), B (truncated at
// word 119 by an early start), C (full), D (truncated at 143), E (full).  Checks that every
// gap between wordFirst marks is exactly 191 words, that wordLast rides word 191 of each
// frame, that real words are never lost or reordered, and that filler words are zero.
module tb;
  reg clk=0, reset=1, enb=0, bitIn=0, bitValid=0, start=0, ready=1;
  wire [63:0] word; wire wordTog, wordLast, wordFirst;
  wire bsWv, bsWl, bsStart; wire [15:0] bsWordCnt; wire bsEnb;
  ByteSerializer dut(.clk(clk),.reset(reset),.enb_1_2_0(enb),.bitIn(bitIn),.bitValid(bitValid),
     .start(start),.ready(ready),.word(word),.wordTog(wordTog),.wordLast(wordLast),.wordFirst(wordFirst),
     .bsWv(bsWv),.bsWl(bsWl),.bsStart(bsStart),.bsWordCnt(bsWordCnt),.bsEnb(bsEnb));
  always #5 clk=~clk;
  // enb_1_2_0 = one beat every 2 clk
  reg tog_prev=0; integer nwords=0, since_first=0, nfill=0, nreal=0, errs=0, fr=0;
  integer expect_gap [0:15]; reg [63:0] lastw;
  // word content: real words are a counter value so order can be checked
  reg [63:0] seqw=1; integer seq_seen=0;
  always @(posedge clk) if (!reset) begin
    if (wordTog != tog_prev) begin
      tog_prev <= wordTog; nwords = nwords+1;
      if (wordFirst) begin
        if (fr>0 && since_first != 191) begin $display("FAIL frame %0d gap=%0d (want 191)", fr, since_first); errs=errs+1; end
        fr=fr+1; since_first=0;
      end
      since_first = since_first+1;
      if (wordLast && since_first != 191) begin $display("FAIL wordLast at word %0d of frame %0d", since_first, fr); errs=errs+1; end
      if (word==64'd0) nfill=nfill+1; else begin nreal=nreal+1;
        if (word != seq_seen+1) begin $display("FAIL order: got %0d expected %0d", word, seq_seen+1); errs=errs+1; end
        seq_seen = word; end
    end
  end
  // drive one 64-bit real word (MSB-first within byte, byte-0-first: word bit pos = byteIdx*8 + 7 - bitInByte)
  task send_word(input [63:0] v, input first);
    integer i, byteIdx, bitInByte, pos;
    begin
      for (i=0;i<64;i=i+1) begin
        byteIdx=i/8; bitInByte=i%8; pos=byteIdx*8+7-bitInByte;
        @(negedge clk); enb=1; bitValid=1; bitIn=v[pos]; start=(first && i==0);
        @(negedge clk); enb=0; bitValid=0; start=0;
      end
    end
  endtask
  task send_frame(input integer nw);   // nw words then (if nw<191) the next frame's start truncates it
    integer k; begin for (k=0;k<nw;k=k+1) begin send_word(seqw, k==0); seqw=seqw+1; end end
  endtask
  initial begin
    #40 reset=0; #40; repeat (4) begin @(negedge clk); enb=1; @(negedge clk); enb=0; end
    send_frame(191);   // A
    send_frame(119);   // B truncated: 72 fillers expected
    send_frame(191);   // C
    send_frame(143);   // D truncated: 48 fillers expected
    send_frame(191);   // E
    send_frame(191);   // F (closes E's accounting)
    // flush a few beats
    repeat (400) begin @(negedge clk); enb=1; @(negedge clk); enb=0; end
    $display("frames_seen=%0d words=%0d real=%0d fill=%0d (want fill=120, real=%0d) errs=%0d", fr, nwords, nreal, nfill, 191*4+119+143, errs);
    if (nfill!=120 || nreal!=191*4+119+143 || errs!=0) $display("TB_PAD_FAIL"); else $display("TB_PAD_PASS");
    $finish;
  end
endmodule
