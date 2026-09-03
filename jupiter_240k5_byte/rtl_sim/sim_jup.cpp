// argv: iq nsamp vphase skip
#include "Vrx_wrap_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vph=atoi(argv[3]);
    unsigned skip=(unsigned)atol(argv[4]);
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    Vrx_wrap_jup* t=new Vrx_wrap_jup;
    t->reset=1;t->rx_input_select=1;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0,beat=0; int ph=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick();
    t->reset=0;
    auto sx=[](unsigned v)->int{int x=v&0x1FFFFF; if(x&0x100000)x-=0x200000; return x;};
    while(clk<100+nsamp*4+40000){
        if(ph==vph){if(sidx<nsamp){t->adc_dataInI=iq[2*sidx];t->adc_dataInQ=iq[2*sidx+1];t->adc_validIn=1;sidx++;}else t->adc_validIn=0;}
        else t->adc_validIn=0;
        ph=(ph+1)&3;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick();
        if(t->enb14&&!t->reset){beat++;
            if(beat%400000==0) printf("PROGRESS beat=%ld packets=%u biterr=%u cfcEstHz=%.1f\n",
                beat,t->packets_out,t->bit_errors_out,sx(t->cfcEst)*240000.0/2097152.0);
        }
    }
    printf("JUP_DONE skip=%u packets=%u biterr=%u frameStart=%u capout=%08x cfc_est=%d\n",
        skip,t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->cap_out,sx(t->cfc_est));
    delete t; return 0;
}
