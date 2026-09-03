// sim_fec_taps.cpp -- tapped FEC harness (2026-08-30). Answers operator test (a) with taps that are REAL
// wrap ports (hierarchical refs, the wrap_byte_taps_e5 mechanism) instead of Verilator flat-rw pokes, which
// silently wrote dead variables in five earlier attempts.
// Pre-registered: healthy == exactly ONE start pulse per frame; a spurious start costs ~51 decoded bits in
// that frame and zero after. Falsifier: ~0 (absorbed) or corruption to end-of-frame kills the hypothesis.
// argv: sim_fec_taps NF K out_prefix     (K = frame at which one spurious start is injected; 0 = none)
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    if(argc<4){ fprintf(stderr,"usage: sim_fec_taps NF K prefix\n"); return 2; }
    int NF=atoi(argv[1]), K=atoi(argv[2]); const char* pfx=argv[3];
    char fn[512]; snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    Vwrap_byte_ce* t=new Vwrap_byte_ce;
    long clk=0; t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0; t->fixctl=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    unsigned lastPk=0,lastErr=0; long startsThisFrame=0,validsThisFrame=0,totStarts=0,totValids=0;
    int injected=0; long injClk=0;
    long total=100+(long)(NF+4)*197328;
    int prevStart=0;
    while(clk<total){
        tick();
        if(t->fecStartIn && !prevStart){ startsThisFrame++; totStarts++; }
        prevStart = t->fecStartIn;
        if(t->demodValidOut) { validsThisFrame++; totValids++; }
        if((int)t->packets_out==K && !injected){          // one spurious start, mid-frame, via fixctl bit4
            injected=1; injClk=clk; t->fixctl=16; tick(); tick(); t->fixctl=0;
            fprintf(ff,"# INJECT spurious start at packet %u clk %ld\n",t->packets_out,clk);
        }
        if(t->packets_out!=lastPk){
            fprintf(ff,"%u %u starts=%ld valids=%ld\n",t->packets_out,t->bit_errors_out-lastErr,startsThisFrame,validsThisFrame);
            lastPk=t->packets_out; lastErr=t->bit_errors_out; startsThisFrame=0; validsThisFrame=0;
        }
    }
    printf("FECTAPS NF=%d K=%d packets=%u biterr=%u totStarts=%ld totValids=%ld injected=%d\n",
           NF,K,t->packets_out,t->bit_errors_out,totStarts,totValids,injected);
    fclose(ff); delete t; return 0;
}
