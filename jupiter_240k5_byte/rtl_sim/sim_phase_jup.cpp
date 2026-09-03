// replay with adc_validIn at (clk%period)==phase  (test ingress-phase sensitivity)
// argv: iq nsamp period skip phase
#include "Vrx_wrap_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]);
    int period=atoi(argv[3]); unsigned skip=(unsigned)atol(argv[4]);
    int phase = argc>5 ? atoi(argv[5]) : 0;
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    Vrx_wrap_jup* t=new Vrx_wrap_jup;
    t->reset=1;t->rx_input_select=1;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick(); t->reset=0;
    long total=100+(long)nsamp*period+60000;
    while(clk<total){
        int v=0;
        if((clk%period)==phase && sidx<nsamp) v=1;
        if(v){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
        else t->adc_validIn=0;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick();
    }
    printf("PHASE period=%d phase=%d samples=%ld packets=%u biterr=%u frameStart=%u cfc_est=%d capout=%08x\n",
        period,phase,sidx,t->packets_out,t->bit_errors_out,t->cnt_frame_start,
        (int)((t->cfc_est&0x100000)?(int)(t->cfc_est|0xFFE00000):(int)(t->cfc_est&0x1FFFFF)),t->cap_out);
    delete t; return 0;
}
