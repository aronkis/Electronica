// sim_byte_stall.cpp -- IQ replay through the FLASHED-generation byte plane
// (wrap_byte_bf2.v / wrap_byte_ce, cadence 2) with a periodic byte_rx_ready
// STALL model (axi_dmac inter-transfer backpressure emulation). E9 fix gate.
// argv: iq nsamp vphase cadence rstcs_end skip out_prefix [fixctl] [stall_period_samp stall_len_clk stall_phase_samp]
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){ fprintf(stderr,"usage: sim_byte_stall iq nsamp vphase cadence rstcs_end skip pfx [fixctl] [period len phase]\n"); return 2; }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vphase=atoi(argv[3]); int cadence=atoi(argv[4]);
    long rstcs_end=atol(argv[5]); unsigned skip=(unsigned)atol(argv[6]); const char* pfx=argv[7];
    unsigned fixctl=(argc>8)?(unsigned)strtoul(argv[8],nullptr,0):0u;
    long stPeriod=(argc>9)?atol(argv[9]):0, stLen=(argc>10)?atol(argv[10]):0, stPhase=(argc>11)?atol(argv[11]):0;
    long stNext=stPeriod>0?stPhase:-1, stUntil=-1, nStalls=0;
    // RDYMODE env: 0 = ready always high (legacy gate); 1 = DMAC-like: ready LOW until the first
    // byte_rx_valid is seen, then high (SYNC_TRANSFER_START handshake order); 2 = ready toggles
    // every 3 clks (pulsed acceptance) after the first valid.
    int rdymode = getenv("RDYMODE") ? atoi(getenv("RDYMODE")) : 0; int seenValid=0;
    if(cadence<1) cadence=1; if(vphase<0||vphase>=cadence) vphase=0;
    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp); long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    char fn[512]; snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");
    Vwrap_byte_ce* t=new Vwrap_byte_ce;
    long clk=0,sidx=0,nrxw=0,nstallcyc=0; int ph=0;
    t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip; t->tx_data_source=0; t->fixctl=fixctl;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    long total=100+nsamp*(long)cadence+60000;
    while(clk<total){
        if(ph==vphase){ if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; } else t->adc_validIn=0; }
        else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400&&clk<rstcs_end)?1:0;
        if(stNext>=0 && sidx>=stNext){ stUntil=clk+stLen; stNext+=stPeriod; nStalls++; }
        { int r=(clk<stUntil)?0:1;
          if(rdymode==1){ if(t->byte_rx_valid) seenValid=1; if(!seenValid) r=0; }
          if(rdymode==2){ if(t->byte_rx_valid) seenValid=1; if(!seenValid) r=0; else if((clk%3)!=0) r=0; }
          t->byte_rx_ready=r; }
        tick();
        if(t->byte_rx_valid && !t->byte_rx_ready) nstallcyc++;
        if(t->byte_rx_valid && t->byte_rx_ready){ fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,(int)t->byte_rx_last,(int)t->byte_rx_user); nrxw++; }
    }
    fclose(fr);
    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u fixctl=%u\n",iqf,nsamp,vphase,cadence,rstcs_end,skip,fixctl);
    fprintf(fo,"stall_period=%ld stall_len=%ld stall_phase=%ld nstalls=%ld stall_valid_cycles=%ld\n",stPeriod,stLen,stPhase,nStalls,nstallcyc);
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u nrxw=%ld\n",t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,nrxw);
    fclose(fo);
    printf("STALL nsamp=%ld packets=%u nrxw=%ld nstalls=%ld\n",nsamp,t->packets_out,nrxw,nStalls);
    delete t; return 0;
}
