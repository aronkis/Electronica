// dump the QPSK_Rx input sample stream (value sampled on the beat the gated enable fires)
#include "Vrx_probe_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]);
    int period=atoi(argv[3]); unsigned skip=(unsigned)atol(argv[4]);
    long dumpN = argc>5 ? atol(argv[5]) : 4000;
    const char* out = argc>6 ? argv[6] : "probe.csv";
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    FILE* fo=fopen(out,"w"); fprintf(fo,"idx,di,dq,qv\n");
    Vrx_probe_jup* t=new Vrx_probe_jup;
    t->reset=1;t->rx_input_select=1;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0; long ndump=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick(); t->reset=0;
    long total=100+(long)nsamp*period+60000;
    while(clk<total){
        int v=0;
        if((clk%period)==0 && sidx<nsamp) v=1;
        if(v){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
        else t->adc_validIn=0;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick();
        // after the edge, if the gated enable fired this beat, record the sample QPSK_Rx latched
        if(t->qEn && ndump<dumpN){ fprintf(fo,"%ld,%d,%d,%d\n",ndump,(int)t->qdI,(int)t->qdQ,(int)t->qV); ndump++; }
    }
    fclose(fo);
    printf("PROBE period=%d dumped=%ld packets=%u biterr=%u cap=%08x\n",period,ndump,t->packets_out,t->bit_errors_out,t->cap_out);
    delete t; return 0;
}
