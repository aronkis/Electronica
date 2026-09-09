// tb_clken_beat.v  -- two-clock / rate-reconciliation model of the 119.75 s beat.
// Sim/analysis only; no hardware.
//
// SIM 1 (mechanism): instantiates the REAL in-tree RTL
//     TxRxCompo_ip_src_TxRxComposite_tc   (free-running enb_1_2 phase grid)
//     TxRxCompo_ip_src_Serializer         (the QPSK coded-bit-pair serializer)
//   and drives the serializer with a deterministic coded-symbol stream.  It
//   shows that a ONE-tick slip of the symbol cadence relative to the free-
//   running enb_1_2_0 grid permanently shifts the serial coded-bit stream
//   (a coded-bit slip) -> ~50% wrong coded bits vs the canonical frame stream,
//   held until the next slip.  The symbol DECISIONS are untouched -> models a
//   pristine constellation with a dirty cap_in (STAGE_LOCALIZED signature).
//
//   clk_enable into the tc is hardwired 1'b1 -- faithful to the silicon, where
//   clk_enable = dut_enable = write_axi_enable, a register that RESETS TO 1 and
//   is never rewritten during a poll (addr_decoder.v:576; stage_poll.sh does
//   not touch it).  So count2 free-runs and enb_1_2_0/1 are pure clk/2 phases.
//
// SIM 2 (root-fix a): instantiates the REAL util_valid_regularizer and measures
//   the PARITY of its output valid (pop) relative to a free-running clk/2 grid,
//   under (i) bounded input jitter and (ii) sustained input-rate surplus.  It
//   shows the fix holds pop-parity invariant under jitter (absorbs the slip)
//   but its unguarded 3-bit fill overflows under a >1-in-2 surplus (fix fails).
//
// Plusargs: +MODE=1|2  +SLIP_AT=t  +NCYC=t  +INJ=<jitter|surplus|clean>

`timescale 1ns/1ps
module tb_clken_beat;
  reg clk = 0; always #5 clk = ~clk;      // 100 MHz stand-in for adc_1_clk
  reg reset = 1;

  integer MODE, SLIP_AT, NCYC;
  reg [127:0] INJ;
  integer cyc = 0; reg run = 0;
  always @(posedge clk) if (run) cyc <= cyc + 1;

  wire clk_enable = 1'b1;                  // static held enable (silicon-faithful)

  // ---- REAL tc : free-running enb_1_2 grid -----------------------------
  wire enb, enb_1_1_1, enb_1_2_0, enb_1_2_1;
  TxRxCompo_ip_src_TxRxComposite_tc u_tc (
    .clk(clk), .reset(reset), .clk_enable(clk_enable),
    .enb(enb), .enb_1_1_1(enb_1_1_1),
    .enb_1_2_0(enb_1_2_0), .enb_1_2_1(enb_1_2_1));

  // =====================================================================
  // SIM 1 : coded-bit slip through the REAL Serializer
  // =====================================================================
  // canonical coded-bit stream: 2 bits per symbol from a maximal LFSR so
  // consecutive bits are ~random (worst case for a bit-slip => ~50%).
  reg [15:0] lfsr = 16'hACE1;
  function bit_next; input dummy; begin end endfunction

  // symbol source pointer, advanced on enb_1_2_0; a one-tick slip stalls it
  reg        src_bit0 = 0, src_bit1 = 0;   // the two coded bits of current symbol
  reg        in2 = 0;
  reg        slip_done = 0;
  reg        stall = 0;

  // reference: canonical serial coded-bit sequence R[n], n = emitted-bit index
  // (feed the serializer u_0=bit0,u_1=bit1; it emits bit0 then bit1 per symbol)
  reg        Rbit = 0;                      // canonical next coded bit
  reg [1:0]  sub  = 0;                      // 0->emit bit0, 1->emit bit1

  // advance canonical stream + drive serializer inputs, gated to enb_1_2_0
  always @(posedge clk) begin
    if (reset) begin
      lfsr<=16'hACE1; src_bit0<=0; src_bit1<=0; in2<=0; sub<=0; Rbit<=0;
      slip_done<=0; stall<=0;
    end else if (enb_1_2_0) begin
      // one-shot single-symbol stall = a one coded-bit slip in the stream
      if (SLIP_AT!=0 && cyc>=SLIP_AT && !slip_done) begin
        slip_done<=1; stall<=1;
      end
      if (stall) begin
        stall<=0;                 // hold source one tick: serializer re-emits
        in2<=1;                   // (In2 stays 1, as validIn is const-1 in HW)
      end else begin
        // pull the next symbol's two coded bits from the LFSR
        src_bit0 <= lfsr[0];
        src_bit1 <= lfsr[1];
        lfsr     <= {lfsr[0]^lfsr[2]^lfsr[3]^lfsr[5], lfsr[15:1]};
        in2      <= 1'b1;
      end
    end
  end

  // REAL Serializer.v : coded-bit-pair serializer, bit select locked to grid
  wire ser_out, ser_vld;
  TxRxCompo_ip_src_Serializer u_ser (
    .clk(clk), .reset(reset), .enb_1_2_0(enb_1_2_0),
    .u_0(src_bit0), .u_1(src_bit1), .In2(in2),
    .Out1(ser_out), .Out2(ser_vld));

  // canonical reference serializer: identical REAL Serializer, but its source
  // pointer NEVER slips -> its Out1 is the golden frame-aligned coded stream
  reg [15:0] glfsr = 16'hACE1;
  reg gb0=0, gb1=0, gin2=0;
  always @(posedge clk) begin
    if (reset) begin glfsr<=16'hACE1; gb0<=0; gb1<=0; gin2<=0; end
    else if (enb_1_2_0) begin
      gb0<=glfsr[0]; gb1<=glfsr[1];
      glfsr<={glfsr[0]^glfsr[2]^glfsr[3]^glfsr[5], glfsr[15:1]};
      gin2<=1'b1;
    end
  end
  wire gser_out, gser_vld;
  TxRxCompo_ip_src_Serializer u_gser (
    .clk(clk), .reset(reset), .enb_1_2_0(enb_1_2_0),
    .u_0(gb0), .u_1(gb1), .In2(gin2),
    .Out1(gser_out), .Out2(gser_vld));

  // =====================================================================
  // SIM 2 : REAL util_valid_regularizer pop-parity under jitter / surplus
  // =====================================================================
  reg        rin_valid = 0;
  reg [15:0] rsamp = 0;
  reg [7:0]  jphase = 0;
  always @(posedge clk) begin
    if (reset) begin rin_valid<=0; rsamp<=0; jphase<=0; end
    else begin
      jphase <= jphase + 1;
      rin_valid <= 1'b0;
      if (INJ=="surplus") begin
        rin_valid <= 1'b1;                       // every cycle: >1-in-2 budget
      end else if (INJ=="jitter") begin
        // avg 1-in-2 but bursty: pattern 1,0,1,1,0,0 (mean 1/2), phase-jittered
        rin_valid <= (jphase%6==0)||(jphase%6==2)||(jphase%6==3);
      end else begin
        rin_valid <= (jphase[0]==1'b0);          // clean regular 1-in-2
      end
      if (rin_valid) rsamp <= rsamp + 1;
    end
  end
  wire        rpop; wire [15:0] rpop_data;
  util_valid_regularizer #(.DATA_WIDTH(16)) u_reg (
    .clk(clk), .rstn(~reset), .in_valid(rin_valid),
    .in_data_0(rsamp), .in_data_1(0), .in_data_2(0), .in_data_3(0),
    .out_valid(rpop), .out_data_0(rpop_data),
    .out_data_1(), .out_data_2(), .out_data_3());
  wire [2:0] rfill = u_reg.wr_ptr - u_reg.rd_ptr;
  wire       roverflow = (rfill > 3'd4);
  // pop-parity = which clk-parity the pop lands on (the thing count2 sees)
  reg pop_parity_seen = 0; reg pop_parity_change = 0; reg prev_pop_par = 1'bx;

  // ---- accounting ------------------------------------------------------
  integer win_bits, win_err, tot_bits, tot_err, last_rep;
  integer pops, pop_par0, pop_par1, ovf_cnt;
  initial begin win_bits=0;win_err=0;tot_bits=0;tot_err=0;last_rep=0;
                pops=0;pop_par0=0;pop_par1=0;ovf_cnt=0; end

  always @(posedge clk) if (!reset && run) begin
    if (MODE==1 && ser_vld && gser_vld) begin
      win_bits=win_bits+1; tot_bits=tot_bits+1;
      if (ser_out!==gser_out) begin win_err=win_err+1; tot_err=tot_err+1; end
      // BYPASS falsification: compare the RAW source bits (serializer removed).
      // If this also steps to ~50%, the 50% is a stream-slip consequence, NOT
      // something the serializer/grid selection specifically produces.
      if (enb_1_2_0) begin
        if (src_bit0!==gb0) ovf_cnt=ovf_cnt+1;   // reuse ovf_cnt as raw-err tally
        pops=pops+1;                             // reuse pops as raw-bit tally
      end
      if (cyc-last_rep>=2000 && win_bits>0) begin
        $display("cyc=%0d  serializer_path_err=%0d/%0d (%0d%%)  raw_bypass_err=%0d/%0d (%0d%%)",
                 cyc, win_err, win_bits, (100*win_err)/win_bits,
                 ovf_cnt, pops, pops? (100*ovf_cnt)/pops:0);
        win_bits=0; win_err=0; last_rep=cyc; pops=0; ovf_cnt=0;
      end
    end
    if (MODE==2) begin
      if (rpop) begin
        pops=pops+1;
        if (cyc[0]) pop_par1=pop_par1+1; else pop_par0=pop_par0+1;
      end
      if (roverflow) ovf_cnt=ovf_cnt+1;
      if (cyc-last_rep>=4000) begin
        $display("cyc=%0d  pops=%0d  pop_on_parity0=%0d parity1=%0d  overflow_cyc=%0d",
                 cyc, pops, pop_par0, pop_par1, ovf_cnt);
        last_rep=cyc;
      end
    end
  end

  initial begin
    if(!$value$plusargs("MODE=%d",MODE)) MODE=1;
    if(!$value$plusargs("SLIP_AT=%d",SLIP_AT)) SLIP_AT=0;
    if(!$value$plusargs("NCYC=%d",NCYC)) NCYC=40000;
    if(!$value$plusargs("INJ=%s",INJ)) INJ="clean";
    $display("== MODE=%0d SLIP_AT=%0d NCYC=%0d INJ=%0s ==",MODE,SLIP_AT,NCYC,INJ);
    repeat(8) @(posedge clk); reset=0; run=1;
    wait(cyc>=NCYC);
    if (MODE==1)
      $display("FINAL coded_bit_err=%0d/%0d (%0d%%)  [slip@%0d]",
               tot_err,tot_bits, tot_bits?(100*tot_err)/tot_bits:0, SLIP_AT);
    else
      $display("FINAL pops=%0d parity0=%0d parity1=%0d overflow_cyc=%0d",
               pops,pop_par0,pop_par1,ovf_cnt);
    $finish;
  end
endmodule
