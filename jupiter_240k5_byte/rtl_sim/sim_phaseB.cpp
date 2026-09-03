// sim_phaseB.cpp -- external-ADC replay at the correct /2-rail cadence.
// The deployed jupiter composite (CADENCE FIX v6) ingests one ADC sample per
// enb_1_2_0 beat (IPCORE clk 3.84 MHz, /2 rail = 1.92 MHz = SSI rate), so the
// stimulus (the decimate-by-2 modem-rate capture) is driven with adc_validIn
// once every 2 clks. rx_input_select=1 (external ADC path).
// argv: iq nsamp skip [vph]
//   vph: which of the two clk phases carries the valid (0 or 1), default 0
#include "Vrx_wrap_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]);
    unsigned skip=(unsigned)atol(argv[3]);
    int vph = argc>4 ? atoi(argv[4]) : 0;
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    Vrx_wrap_jup* t=new Vrx_wrap_jup;
    t->reset=1;t->rx_input_select=1;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick();
    t->reset=0;
    auto sx=[](unsigned v)->int{int x=v&0x1FFFFF; if(x&0x100000)x-=0x200000; return x;};
    long total=100+(long)nsamp*2+60000;
    while(clk<total){
        if(((clk&1)==(long)vph) && sidx<nsamp){
            t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1];
            t->adc_validIn=1; sidx++;
        } else t->adc_validIn=0;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick();
    }
    printf("PHB_DONE skip=%u vph=%d samples=%ld packets=%u biterr=%u frameStart=%u vitrst=%u rstcs=%u capout=%08x cfc_est=%d cfcHz=%.1f\n",
        skip,vph,sidx,t->packets_out,t->bit_errors_out,t->cnt_frame_start,
        t->cnt_vit_reset,t->rstcs_count,t->cap_out,sx(t->cfc_est),
        sx(t->cfc_est)*240000.0/2097152.0);
    delete t; return 0;
}
