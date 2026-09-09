// sim_byte_qtick.cpp -- QUICK-LOOK driver (2026-08-13): gated byte/control-plane
// tick on top of the sim_byte_lock replay. Every TICK_PERIOD clk (fractional
// accumulator, default 8.04 frames) a PRNG draws gate probability p; a gated-IN
// tick EATS the next EATW delivered words at the byte_rx (ByteSerializer
// output) interface -- the harness-side equivalent of an eat-valid disturbance
// at the byte/serializer control plane. Every tick is logged {clk,gated} and
// every frame line carries the count of words eaten inside that frame, so
// attribution is exact (no baseline run needed).
// argv: iq nsamp vphase cadence rstcs_end skip out_prefix tick_clk_milli p_milli seed eatw
//   tick_clk_milli: tick period in MILLI-clk (8.04 frames = 1586517120)
//   p_milli:        gate probability x1000 (350 = 0.35)
#include "Vwrap_byte_lock.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static inline uint32_t xs32(uint32_t& s){ s^=s<<13; s^=s>>17; s^=s<<5; return s; }

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 12){
        fprintf(stderr,"usage: sim_byte_qtick iq nsamp vphase cadence rstcs_end skip out_prefix tick_clk_milli p_milli seed eatw\n");
        return 2;
    }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vphase=atoi(argv[3]);
    int cadence=atoi(argv[4]); long rstcs_end=atol(argv[5]); unsigned skip=(unsigned)atol(argv[6]);
    const char* pfx=argv[7];
    double tick_period = atoll(argv[8]) / 1000.0;   // clk
    int p_milli = atoi(argv[9]);
    uint32_t seed = (uint32_t)strtoul(argv[10],nullptr,0);
    int eatw = atoi(argv[11]);
    if(cadence<1)cadence=1; if(vphase<0||vphase>=cadence)vphase=0;
    if(!seed) seed=1;

    FILE* fi=fopen(iqf,"rb"); if(!fi){fprintf(stderr,"cannot open %s\n",iqf);return 2;}
    std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2<nsamp) nsamp=got/2;

    char fn[512];
    auto openout=[&](const char* suf)->FILE*{
        snprintf(fn,sizeof fn,"%s_%s.txt",pfx,suf);
        FILE* f=fopen(fn,"w"); if(!f){fprintf(stderr,"cannot open %s\n",fn);exit(2);} return f;
    };
    FILE* ff=openout("frames");
    fprintf(ff,"# outframe clk nwords cksum16 cfc_est eaten\n");
    FILE* fr=openout("rxw");
    FILE* ft=openout("ticks");
    fprintf(ft,"# clk gated eat_pending\n");

    Vwrap_byte_lock* t=new Vwrap_byte_lock;
    long clk=0,sidx=0,nrxw=0,outframe=0; int ph=0;
    auto sx=[](uint64_t v,int b)->long long{
        uint64_t m=(1ULL<<b)-1; long long x=(long long)(v&m);
        if(x&(1LL<<(b-1))) x-=(1LL<<b); return x; };

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    double next_tick = tick_period;    // first tick one period in
    int eat_pending = 0;
    long nticks=0, ngated=0, neaten_total=0;
    unsigned cks=0; long nwords=0; int eaten_this_frame=0;

    long total=100 + nsamp*(long)cadence + 60000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();

        if((double)clk >= next_tick){
            next_tick += tick_period;
            nticks++;
            int gated = ((xs32(seed)>>8) % 1000) < (unsigned)p_milli;
            if(gated){ eat_pending += eatw; ngated++; }
            fprintf(ft,"%ld %d %d\n",clk,gated,eat_pending);
        }

        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            if(eat_pending>0){
                eat_pending--; eaten_this_frame++; neaten_total++;
                // word EATEN: not recorded, not checksummed, not counted --
                // but a lost byte_rx_last must not merge frames unnoticed;
                // honor the boundary (frame closes short).
            } else {
                fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)w,(int)t->byte_rx_last,(int)t->byte_rx_user);
                nrxw++; nwords++;
                for(int b=0;b<8;b++) cks=(cks+((w>>(8*b))&0xFF))&0xFFFF;
            }
            if(t->byte_rx_last){
                fprintf(ff,"%ld %ld %ld %u %lld %d\n",
                        outframe, clk, nwords, cks, sx(t->cfc_est,21), eaten_this_frame);
                outframe++;
                cks=0; nwords=0; eaten_this_frame=0;
            }
        }
    }
    fclose(ff); fclose(fr); fclose(ft);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip);
    fprintf(fo,"tick_period_clk=%.2f p_milli=%d eatw=%d nticks=%ld ngated=%ld neaten=%ld\n",
            tick_period,p_milli,eatw,nticks,ngated,neaten_total);
    fprintf(fo,"packets=%u outFrames=%ld nrxw=%ld cfc_est=%lld\n",
            t->packets_out,outframe,nrxw,sx(t->cfc_est,21));
    fclose(fo);
    printf("QTICK iq=%s outFrames=%ld nticks=%ld ngated=%ld neaten=%ld packets=%u\n",
           iqf,outframe,nticks,ngated,neaten_total,t->packets_out);
    delete t; return 0;
}
