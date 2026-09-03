// sim_burst_force.cpp -- 120-s burst hunt: FPGA-internal loopback with the ROM/BIST TX source (as the hardware
// ROM run), per-decoded-frame BIST bit-error log, and a FORCED register state at frame K to emulate a wrap/slip
// of a candidate accumulator (needs --public-flat-rw). argv: NF K sel out_prefix
//   sel: none | cs (carrier-sync loop-filter integrator sfix39 -> max) | ss (symbol-sync loop-filter integrator
//        sfix40 -> max) | agc (AGC complex-gain integrator re -> max) | integ (CFE 4097-sample integrator -> max)
//        | ps (Peak_Search timing reference +32) | ta (Timing_Adjust timing reference +32)
#include "Vwrap_byte_ce.h"
#include "Vwrap_byte_ce___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#define RXP wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__
#define FTS wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: sim_burst_force NF K sel out_prefix\n"); return 2; }
    int NF=atoi(argv[1]), K=atoi(argv[2]); std::string sel=argv[3]; const char* pfx=argv[4];
    unsigned FIXCTL = (argc>5)? (unsigned)strtoul(argv[5],nullptr,0) : 0u;   // 2026-08-29: exercise the BEATFIX contract in sim
    int K2 = (argc>6)? atoi(argv[6]) : -1;                 // 2026-08-29: optional SECOND event (recovery test)
    std::string sel2 = (argc>7)? argv[7] : "";             //   e.g. fpush at K then fpop at K2 = the compensating excursion
    char fn[512]; snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    Vwrap_byte_ce* t=new Vwrap_byte_ce; auto* R=t->rootp;
    long clk=0; t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0; t->fixctl=FIXCTL;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    unsigned lastPk=0, lastErr=0; int forced=0; long lastClk=0; int pendX=0; int pendFlip=0, pendStart=0; long nFlips=0, nValidSeen=0, nStartSeen=0, nStartInj=0;
    long total = 100 + (long)(NF+4)*197328;
    while(clk<total){
        t->adc_validIn=(clk&1)?0:1;
        if(pendX!=0){ auto& d8=R->CAT(FTS,u_Preamble_Detector__DOT__Delay8_reg); if(pendX>0 && !(d8&1)){ d8|=1; pendX=0; fprintf(ff,"# XP1 injected extra push strobe at clk %ld\n",clk);} else if(pendX<0 && (d8&1)){ d8&=~1u; pendX=0; fprintf(ff,"# XM1 deleted a push strobe at clk %ld\n",clk);} }
        tick();
        unsigned pk=t->packets_out;
        if(pk!=lastPk){
            unsigned err=t->bit_errors_out; 
            fprintf(ff,"%u %u %ld %u %d witA=%08x witB=%08x occ=%u mu=%d cnt=%d push=%u pop=%u\n", pk, err-lastErr, clk-lastClk, t->rstcs_count, forced, (unsigned)t->bfViol, (unsigned)t->bfLatch,
                (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg),
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg)<<5))>>5,
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg)<<5))>>5,
                (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1),(unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1));
            lastErr=err; lastClk=clk; lastPk=pk; fflush(ff);
            // 2026-08-30: single coded-bit / single-symbol corruption at the FEC decoder input, to measure
            // what ONE bad symbol costs at the decoder output (the operator's test (a) for the 51-bit signature).
            // pendFlip counts how many consecutive VALID coded-bit beats still have to be inverted.
            { auto v = t->rootp->CAT(RXP,u_QPSK_Demodulator__DOT__Delay9_out1);
              auto st = t->rootp->CAT(RXP,u_QPSK_Demodulator__DOT__Delay10_out1);
              if(v) nValidSeen++; if(st) nStartSeen++; }
            if(pendStart > 0){ t->rootp->CAT(RXP,u_QPSK_Demodulator__DOT__Delay10_out1) = 1; pendStart--; nStartInj++; }
            if(pendFlip > 0 && t->rootp->CAT(RXP,u_QPSK_Demodulator__DOT__Delay9_out1)){
                auto& b = t->rootp->CAT(RXP,u_QPSK_Demodulator__DOT__Delay8_out1);
                b = b ? 0 : 1; pendFlip--; nFlips++;
            }
            auto apply=[&](const std::string& sel){
                if(sel=="cs")   R->CAT(FTS,u_Carrier_Synchronizer__DOT__u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1) = 0x3FFFFFFFFFULL;
                if(sel=="ss"){  R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[0] = 0x7FFFFFFFFFULL;
                                R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[1] = 0x7FFFFFFFFFULL; }
                if(sel=="agc"){ R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[0] = 0x1FFFFFFFFULL;
                                R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[1] = 0x1FFFFFFFFULL; }
                if(sel=="integ"){ R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_re) = 0x7FFFFFFFu;
                                  R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_im) = 0x7FFFFFFFu; }
                if(sel=="ps"){  auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1); r=(r+32)%12333; }
                if(sel=="ta"){  auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_Timing_Adjust__DOT__timing_Reference_out1); r=(r+32)%12333; }
                // joint slips: BOTH reference counters move together (what a strobe deletion/insertion does on hardware)
                if(sel=="slip1"||sel=="slipm1"||sel=="slip32"||sel=="edge"){
                    auto& a=R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1);
                    auto& b=R->CAT(FTS,u_Preamble_Detector__DOT__u_Timing_Adjust__DOT__timing_Reference_out1);
                    unsigned off=R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1);
                    int d = (sel=="slip1")?1:(sel=="slipm1")?12332:(sel=="slip32")?32:0;
                    if(sel=="edge"){ d = (int)((12333u + 12332u - off) % 12333u); }   // move the peak onto window index 12332 (the done slot)
                    a=(a+d)%12333; b=(b+d)%12333;
                    fprintf(ff,"# offset_before=%u shift=%d\n", off, d);
                }
                if(sel=="xp1") pendX=1;
                if(sel=="xm1") pendX=-1;
                if(sel=="bit1"){ pendFlip=1; }
                if(sel=="sym1"){ pendFlip=2; }
                if(sel=="sym2"){ pendFlip=4; }
                if(sel=="sym8"){ pendFlip=16; }
                if(sel=="start1"){ pendStart=1; }
                if(sel=="start2"){ pendStart=2; }
                if(sel=="fpush"){ auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1); r=(r+1)%12333; }
                if(sel=="fpop"){  auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1);  r=(r+1)%12333; }
                if(sel=="focc"){  R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg) = 12333; }
                if(sel=="foccp1"){ auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg); r=r+1; }
                { auto* Rr=R; fprintf(ff,"# FORCED %s at packet %u clk %ld fifo push=%u pop=%u occ=%u\n", sel.c_str(), pk, clk,
                   (unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1),(unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1),
                   (unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg)); }
            };
            if((int)pk==K && !forced){ forced=1; apply(sel); }
            if(K2>0 && (int)pk==K2 && forced==1 && !sel2.empty()){ forced=2; apply(sel2); }

        }
    }
    fclose(ff);
    printf("BURSTFORCE flips=%ld validbeats=%ld startbeats=%ld startinj=%ld sel=%s NF=%d K=%d packets=%u biterr=%u rstcs=%u\n",nFlips,nValidSeen,nStartSeen,nStartInj,sel.c_str(),NF,K,t->packets_out,t->bit_errors_out,t->rstcs_count);
    delete t; return 0;
}
