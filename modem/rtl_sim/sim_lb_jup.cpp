// sim_cad.cpp -- replay with parametric valid cadence.
// argv: iq nsamp period_clks skip [burst_mode]
//   period_clks: clocks between adc_validIn pulses (4 = 1 beat/sample, 8 = 2 beats/sample,
//                16 = 4 beats/sample, 52/53 alternating if period=52, ...)
//   burst_mode 1: bursty -- 4 valids on consecutive rail beats then a long gap (same avg rate)
#include "Vrx_wrap_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]);
    int period=atoi(argv[3]); unsigned skip=(unsigned)atol(argv[4]);
    int burst = argc>5 ? atoi(argv[5]) : 0;
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    Vrx_wrap_jup* t=new Vrx_wrap_jup;
    t->reset=1;t->rx_input_select=0;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0; long acc=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick(); t->reset=0;
    long total=100+(long)nsamp*period+60000;
    int bcnt=0; long bgap=0;
    while(clk<total){
        int v=0;
        if(!burst){ if((clk%period)==0 && sidx<nsamp) v=1; }
        else {
            // bursty: groups of 4 samples on consecutive 4-clk beats, then gap of 4*period-16 clks
            long pos = clk % (4*period);
            if((pos%4)==0 && pos<16 && sidx<nsamp) v=1;
        }
        if(v){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
        else t->adc_validIn=0;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick();
    }
    printf("CAD period=%d burst=%d samples=%ld packets=%u biterr=%u frameStart=%u rstcs=%u cfc_est=%d capout=%08x\n",
        period,burst,sidx,t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->rstcs_count,
        (int)((t->cfc_est&0x100000)?(int)(t->cfc_est|0xFFE00000):(int)(t->cfc_est&0x1FFFFF)),t->cap_out);
    delete t; return 0;
}
