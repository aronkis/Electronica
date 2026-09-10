// sim_corr.cpp -- [sim] task 6: dump the correlator magnitude at every
// threshold-exceeding beat, to characterise the peak 32 symbols from the true
// one.  usage: sim_corr <iq> <nsamp> <rstcs_end> <prefix> [cadence] [vphase]
// output <prefix>_corr.txt : sidx,frame,tref,corr,thr,thrExceeded
#include "Vwrap_corr.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
static const long FRSAMP = 49332;
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: sim_corr iq nsamp rstcs_end prefix [cad] [vph]\n"); return 2; }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); long rstcs_end=atol(argv[3]);
    const char* pfx=argv[4]; int cadence=(argc>5)?atoi(argv[5]):2; int vphase=(argc>6)?atoi(argv[6]):0;
    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2<nsamp) nsamp=got/2;
    char fn[512]; snprintf(fn,sizeof fn,"%s_corr.txt",pfx);
    FILE* fo=fopen(fn,"w"); if(!fo){ fprintf(stderr,"cannot write %s\n",fn); return 2; }
    Vwrap_corr* t=new Vwrap_corr;
    long clk=0,sidx=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    long total=100+nsamp*(long)cadence+200000;
    unsigned char pv=0;
    while(clk<total){
        if(ph==vphase){ if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1];
                t->adc_validIn=1; sidx++; } else t->adc_validIn=0; } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400&&clk<rstcs_end)?1:0;
        tick();
        if(t->railEnb){
            // dump EVERY correlator beat whose epoch index lies in the window
            // [0,90] -- this brackets both the true preamble position (tref 30)
            // and the +32 competitor (tref 62) -- so we can see, per epoch,
            // whether the true peak falls or the threshold rises.
            if(t->psCorrV && !pv){
                int tr=(int)t->tref;
                if(tr<=90)
                    fprintf(fo,"%ld,%ld,%d,%d,%d,%d\n", sidx, sidx/FRSAMP, tr,
                            (int)t->psCorr, (int)t->psThr, (int)t->psThrEx);
            }
            pv = t->psCorrV;
        }
    }
    fclose(fo); printf("CORRDUMP %s done\n",pfx); delete t; return 0;
}
