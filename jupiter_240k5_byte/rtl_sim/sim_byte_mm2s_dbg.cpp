// sim_byte_mm2s_dbg.cpp -- run-B repro with accept/pop tracing (TXMUX)
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const unsigned NTW=385, NDW=191;
    long total=atol(argv[1]); long arm=atol(argv[2]);
    FILE* fa=fopen("dbg_accepts.txt","w");
    FILE* fr=fopen("dbg_rxw.txt","w");
    Vwrap_byte* t=new Vwrap_byte;
    long clk=0; unsigned xfer=0, widx=0; int first_r=1;
    auto word_of=[&](unsigned n,unsigned j)->unsigned long long{
        if(j>=NDW) return 0ULL;
        return (0xB000000000000000ULL)|((unsigned long long)(n&0xFFFF)<<32)|(j&0xFFFF);
    };
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1;
    t->byte_valid=0; t->byte_rx_ready=1; t->byte_data=0; t->byte_first=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    while(clk<total){
        if(t->byte_valid && t->byte_ready){
            fprintf(fa,"%ld %u %u\n",clk,xfer,widx);
            int wl=(widx==NTW-1); first_r=wl;
            if(wl){widx=0;xfer++;} else widx++;
        }
        t->byte_data=word_of(xfer,widx);
        t->byte_valid=(clk>=arm);
        t->byte_first=first_r;
        t->adc_validIn=(clk&1)?0:1;
        tick();
        if(t->byte_rx_valid && t->byte_rx_ready)
            fprintf(fr,"%ld %016llx\n",clk,(unsigned long long)t->byte_rx_data);
    }
    fclose(fa); fclose(fr);
    printf("DBG done accepts+rxw written\n");
    delete t; return 0;
}
