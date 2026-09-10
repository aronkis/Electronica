// sim_kick_taps.cpp -- forced symbol-sync kick experiment (2026-09-01 beat-tap-compare, Task "kick").
// Same forcing machinery as sim_burst_force_txmark.cpp (needs --public-flat-rw), PLUS a DDR record
// stream (record = int16 [ddrcap_i, ddrcap_q, ddrcap_mark_demod, ddrcap_mark_fec], one per
// ddrcap_valid beat) written exactly as in sim_golden_taps.cpp, so the existing scorer
// (t6_score_large.py, tag archive/pre-cleanup-2026-09-09) and the tap3 offset map apply unchanged.
// argv: NF K sel out_prefix [SEL=6] [OUT.bin]
//   sel: none | cs | ss | agc | integ | ps | ta | slip1 | slipm1 | slip32 | edge | xp1 | xm1 |
//        bit1 | sym1 | sym2 | sym8 | start1 | start2 | fpush | fpop | focc | foccp1
//   SEL: ddrcap selector (default 6, tap3/symbol-domain, matches offsetmap/tap3_word_to_offset.tsv)
//   OUT.bin: DDR record output path (default <out_prefix>.bin)
#include "Vwrap_byte_ddrcap.h"
#include "Vwrap_byte_ddrcap___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#define RXP wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: sim_kick_taps NF K sel out_prefix [SEL=6] [OUT.bin]\n"); return 2; }
    int NF=atoi(argv[1]), K=atoi(argv[2]); std::string sel=argv[3]; const char* pfx=argv[4];
    unsigned SEL = (argc>5)? (unsigned)strtoul(argv[5],nullptr,0) : 6u;
    char outbuf[512];
    const char* outpath;
    if(argc>6){ outpath = argv[6]; }
    else { snprintf(outbuf,sizeof outbuf,"%s.bin",pfx); outpath = outbuf; }
    char fn[512]; snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    Vwrap_byte_ddrcap* t=new Vwrap_byte_ddrcap; auto* R=t->rootp;
    long clk=0; t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0; t->fixctl=0;
    t->iq_debug_mux = ((SEL & 0xFu) << 16) | 3u;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    FILE* fb=fopen(outpath,"wb");
    unsigned lastPk=0, lastErr=0; int forced=0; long lastClk=0; int pendX=0;
    long total = 100 + (long)(NF+4)*197328;
    while(clk<total){
        t->adc_validIn=(clk&1)?0:1;
        if(pendX!=0){ auto& d8=R->CAT(FTS,u_Preamble_Detector__DOT__Delay8_reg); if(pendX>0 && !(d8&1)){ d8|=1; pendX=0; fprintf(ff,"# XP1 injected extra push strobe at clk %ld\n",clk);} else if(pendX<0 && (d8&1)){ d8&=~1u; pendX=0; fprintf(ff,"# XM1 deleted a push strobe at clk %ld\n",clk);} }
        tick();
        // ---- DDR record stream (identical to sim_golden_taps.cpp) ----
        if(t->ddrcap_valid){
            short r[4] = { (short)t->ddrcap_i, (short)t->ddrcap_q, (short)t->ddrcap_mark_demod, (short)t->ddrcap_mark_fec };
            fwrite(r, sizeof r, 1, fb);
        }
        unsigned pk=t->packets_out;
        if(pk!=lastPk){
            unsigned err=t->bit_errors_out;
            fprintf(ff,"%u %u %ld %u %d witA=%08x witB=%08x occ=%u mu=%d cnt=%d push=%u pop=%u\n", pk, err-lastErr, clk-lastClk, t->rstcs_count, forced, (unsigned)t->bfViol, (unsigned)t->bfLatch,
                (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg),
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg)<<5))>>5,
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg)<<5))>>5,
                (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1),(unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1));
            lastErr=err; lastClk=clk; lastPk=pk; fflush(ff);
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
                if(sel=="slip1"||sel=="slipm1"||sel=="slip32"||sel=="edge"){
                    auto& a=R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1);
                    auto& b=R->CAT(FTS,u_Preamble_Detector__DOT__u_Timing_Adjust__DOT__timing_Reference_out1);
                    unsigned off=R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1);
                    int d = (sel=="slip1")?1:(sel=="slipm1")?12332:(sel=="slip32")?32:0;
                    if(sel=="edge"){ d = (int)((12333u + 12332u - off) % 12333u); }
                    a=(a+d)%12333; b=(b+d)%12333;
                    fprintf(ff,"# offset_before=%u shift=%d\n", off, d);
                }
                if(sel=="xp1") pendX=1;
                if(sel=="xm1") pendX=-1;
                if(sel=="fpush"){ auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1); r=(r+1)%12333; }
                if(sel=="fpop"){  auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1);  r=(r+1)%12333; }
                if(sel=="focc"){  R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg) = 12333; }
                if(sel=="foccp1"){ auto& r=R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg); r=r+1; }
                { auto* Rr=R; fprintf(ff,"# FORCED %s at packet %u clk %ld fifo push=%u pop=%u occ=%u\n", sel.c_str(), pk, clk,
                   (unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1),(unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1),
                   (unsigned)Rr->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg)); }
            };
            if((int)pk==K && !forced && sel!="none"){ forced=1; apply(sel); }
        }
    }
    fclose(ff); fclose(fb);
    printf("KICKTAPS sel=%s SEL=%u NF=%d K=%d packets=%u biterr=%u rstcs=%u\n",sel.c_str(),SEL,NF,K,t->packets_out,t->bit_errors_out,t->rstcs_count);
    delete t; return 0;
}
