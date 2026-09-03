// sim_byte_iq_perframe.cpp -- IQ replay + PER-FRAME decode verdict.
// Same drive sequence as sim_byte_iq.cpp (rx_input_select=1, cadence, rstCS arm)
// but at every byte_rx_last it emits one line to <prefix>_frames.txt:
//   outframe , clk , cap_out(hex) , golden(0/1) , user , frameStart , rstcs
// so the caller can map each delivered output frame to a capture frame index
// (capture frame ~ (clk - accq_latency)/samples_per_frame_in_clks) and compare
// the fixed-point per-frame golden verdict against the float per-frame EVM grid.
// argv: <iq> <nsamp> <vphase> <cadence> <rstcs_end> <skip> <out_prefix>
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <set>

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){ fprintf(stderr,"usage: sim_byte_iq_perframe iq nsamp vphase cadence rstcs_end skip out_prefix\n"); return 2; }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vphase=atoi(argv[3]);
    int cadence=atoi(argv[4]); long rstcs_end=atol(argv[5]); unsigned skip=(unsigned)atol(argv[6]);
    const char* pfx=argv[7];
    if(cadence<1)cadence=1; if(vphase<0||vphase>=cadence)vphase=0;

    FILE* fi=fopen(iqf,"rb"); if(!fi){fprintf(stderr,"cannot open %s\n",iqf);return 2;}
    std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2<nsamp) nsamp=got/2;

    std::vector<unsigned long long> gold;
    { FILE* fg=fopen("rx_words_golden.hex","r");
      if(fg){char ln[128]; while(fgets(ln,sizeof ln,fg)){if(ln[0]=='\n')continue; gold.push_back(strtoull(ln,nullptr,16));} fclose(fg);} }
    std::set<unsigned long long> goldset(gold.begin(),gold.end());

    char fn[512];
    snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    fprintf(ff,"# outframe clk cap_out golden user frameStart rstcs\n");
    snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");

    Vwrap_byte* t=new Vwrap_byte;
    long clk=0,sidx=0,nrxw=0; int ph=0;
    const unsigned CAPGOLD=0x04922282u;
    long outframe=0, capGoldFrames=0, capNonzFrames=0; bool capEverGold=false;
    long ngoldAny=0, nuser=0;

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    auto sx=[](unsigned v)->int{int x=v&0x1FFFFF; if(x&0x100000)x-=0x200000; return x;};

    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // HARNESS_AB 2026-08-13: drain tail scaled by cadence and sized > 2 frames
    // (was fixed 60000 clk) so the final capture frame drains fully at any drive
    // cadence -- at cadence=2 the fixed tail truncated the last frame (154
    // trailing words without last). 2 frames = 2*SPF*cadence ~= 99k*cadence clk.
    long total=100 + nsamp*(long)cadence + 120000L*(long)cadence;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();

        unsigned cap=t->cap_out; if(cap==CAPGOLD) capEverGold=true;
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long w=(unsigned long long)t->byte_rx_data;
            fprintf(fr,"%016llx,%d,%d\n",w,(int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++; if(t->byte_rx_user) nuser++;
            if(!gold.empty() && goldset.count(w)) ngoldAny++;
            if(t->byte_rx_last){
                unsigned c=t->cap_out; int g=(c==CAPGOLD)?1:0;
                fprintf(ff,"%ld %ld %08x %d %d %u %u\n",
                        outframe, clk, c, g, (int)t->byte_rx_user, t->cnt_frame_start, t->rstcs_count);
                capNonzFrames++; if(g) capGoldFrames++;
                outframe++;
            }
        }
    }
    fclose(ff); fclose(fr);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u\n",iqf,nsamp,vphase,cadence,rstcs_end,skip);
    fprintf(fo,"packets=%u biterr=%u frameStart=%u rstcs=%u cfc_est=%d\n",
            t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->rstcs_count,sx(t->cfc_est));
    fprintf(fo,"outFrames=%ld capGoldFrames=%ld/%ld nrxw=%ld nuser=%ld goldAny=%ld capEverGold=%d\n",
            outframe,capGoldFrames,capNonzFrames,nrxw,nuser,ngoldAny,(int)capEverGold);
    fclose(fo);

    printf("PERFRAME iq=%s nsamp=%ld packets=%u frameStart=%u outFrames=%ld capGoldFrames=%ld/%ld nrxw=%ld goldAny=%ld capEverGold=%d\n",
           iqf,nsamp,t->packets_out,t->cnt_frame_start,outframe,capGoldFrames,capNonzFrames,nrxw,ngoldAny,(int)capEverGold);
    delete t; return 0;
}
