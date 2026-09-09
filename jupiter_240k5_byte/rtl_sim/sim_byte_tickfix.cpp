// sim_byte_tickfix.cpp -- TICK-FIX A/B driver (2026-08-13 staged task).
//
// IQ replay through the Jul-25 f1536 bit-true netlist (wrap_byte_lock.v) with a
// BEHAVIORAL model of the platform-side 1536-word byte FIFO (the prime suspect
// of PAIR_RECURRENCE.md -- it sits OUTSIDE the HDL netlist, between the
// ByteSerializer output and the RX byte DMA) inserted at the byte_rx interface.
//
// FAULT PRIMITIVE (the corrected upstream-of-packing morphology per
// TICK_CAMPAIGN.md): a "swallowed write beat" at the FIFO write port -- the
// write POINTER advances but the memory write is suppressed (a control-plane
// tick steals the port for that cycle). The delivered stream keeps full
// framing (byte_rx_last passes through untouched -> 191 words per frame), but
// the swallowed positions carry STALE content: whatever the ring held from
// 1536 words (= 8.04 frames) earlier. Wrong content, full length, CRC fail,
// self-healing at the next frame -- the hardware morphology. This is NOT the
// sim_byte_qtick output-eat primitive (which shortened frames to 188 words, a
// length-fail tautology).
//
// SCHEDULE (deterministic two-scale structure per PAIR_RECURRENCE.md): hits
// are scheduled in WRITE-BEAT (word) units: every SUPER words (default 6144 =
// 4 FIFO wraps = 32.17 frames) a PAIR of hits, PAIROFF words apart (default
// 1536 = 1 wrap = 8.04 frames). Each hit is gated by an independent Bernoulli
// draw p = hitp_milli/1000 (the refractory-gate / occupancy term that sets the
// ~4%/frame scale and the measured 73-86% pair-up fraction). A gated-in hit
// swallows EATW consecutive write beats.
//
// GUARD (mode 2): behavioral model of the proposed RTL guard -- a 1-deep SKID
// buffer on the FIFO write port. A swallowed beat's word is captured in the
// skid register and the write retried on the NEXT clk (the port is free: byte
// beats are many clks apart -- min inter-beat gap is measured and reported as
// mingap). The deferred write completes ~1 clk after the fault, i.e. >1000 clk
// before that ring address is next read (occupancy >= 1 word), so delivered
// content is exact. A skid OVERFLOW (next write beat arriving before the retry
// slot, gap < 2 clk) would be the guard's failure mode -- counted and
// reported; with measured gaps it never fires.
//
// modes: 0 = clean (FIFO passthrough, no injection)
//        1 = inject, UNGUARDED (positive control)
//        2 = inject, GUARDED (skid repair)
//
// argv: iq nsamp vphase cadence rstcs_end skip out_prefix mode
//       super_words pairoff_words start_word eatw hitp_milli seed
#include "Vwrap_byte_lock.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static inline uint32_t xs32(uint32_t& s){ s^=s<<13; s^=s>>17; s^=s<<5; return s; }

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 15){
        fprintf(stderr,"usage: sim_byte_tickfix iq nsamp vphase cadence rstcs_end skip out_prefix "
                       "mode super_words pairoff_words start_word eatw hitp_milli seed\n");
        return 2;
    }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vphase=atoi(argv[3]);
    int cadence=atoi(argv[4]); long rstcs_end=atol(argv[5]); unsigned skip=(unsigned)atol(argv[6]);
    const char* pfx=argv[7];
    int mode=atoi(argv[8]);
    long super_w=atol(argv[9]);      // 6144 = 4 wraps
    long pairoff_w=atol(argv[10]);   // 1536 = 1 wrap
    long start_w=atol(argv[11]);     // phase of the first pair, in words
    int eatw=atoi(argv[12]);
    int hitp_milli=atoi(argv[13]);
    uint32_t seed=(uint32_t)strtoul(argv[14],nullptr,0);
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
    fprintf(ff,"# outframe clk nwords cksum16 cfc_est sw stale rep\n");
    FILE* fr=openout("rxw");
    FILE* fh=openout("hits");
    fprintf(fh,"# hitword clk gated frame\n");

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

    // ---- behavioral platform byte-FIFO (shadow, content-equivalent) ----
    const long FDEPTH=1536;
    std::vector<uint64_t> mem(FDEPTH,0);
    long wp=0;
    // hit schedule state
    long next_pair = start_w;         // word index of next pair's first hit
    int  pair_leg = 0;                // 0 = first hit, 1 = second hit
    long next_hit = next_pair;
    long swallow_pending=0;
    long nhits_sched=0, nhits_gated=0, nsw_total=0, nstale_total=0, nrepair=0, noverflow=0;
    // inter-beat gap measurement
    long last_beat_clk=-1, mingap=1L<<60;
    long skid_retry_clk=-1;           // clk at which a pending skid write lands

    // per-frame accumulators
    unsigned cks=0; long nwords=0; long sw_frame=0, stale_frame=0, rep_frame=0;

    long total=100 + nsamp*(long)cadence + 60000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();

        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            // gap census
            if(last_beat_clk>=0){ long g=clk-last_beat_clk; if(g<mingap) mingap=g; }
            // guard failure check: a beat arriving while the deferred skid
            // write has not yet landed would collide (never fires in practice)
            if(mode==2 && skid_retry_clk>=0 && clk<=skid_retry_clk) noverflow++;
            last_beat_clk=clk;

            // schedule: does a hit start on THIS word index?
            while(mode>=1 && nrxw>=next_hit){
                nhits_sched++;
                int gated = ((xs32(seed)>>8)%1000) < (unsigned)hitp_milli;
                if(gated){ swallow_pending += eatw; nhits_gated++; }
                fprintf(fh,"%ld %ld %d %ld\n",next_hit,clk,gated,outframe);
                if(pair_leg==0){ pair_leg=1; next_hit=next_pair+pairoff_w; }
                else { pair_leg=0; next_pair+=super_w; next_hit=next_pair; }
            }

            uint64_t delivered;
            bool sw = (mode>=1 && swallow_pending>0);
            if(sw){
                swallow_pending--; nsw_total++; sw_frame++;
                if(mode==1){
                    // UNGUARDED: pointer advances, memory write suppressed ->
                    // deliver the STALE ring content (word from 1536 beats ago)
                    delivered = mem[wp];
                    nstale_total++; stale_frame++;
                } else {
                    // GUARDED: skid captures w; deferred write lands next clk,
                    // long before this address is read again -> content exact
                    mem[wp]=w; delivered=w;
                    nrepair++; rep_frame++;
                    skid_retry_clk = clk+1;
                }
            } else {
                mem[wp]=w; delivered=w;
            }
            wp=(wp+1)%FDEPTH;

            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)delivered,
                    (int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++; nwords++;
            for(int b=0;b<8;b++) cks=(cks+((delivered>>(8*b))&0xFF))&0xFFFF;
            if(t->byte_rx_last){
                fprintf(ff,"%ld %ld %ld %u %lld %ld %ld %ld\n",
                        outframe, clk, nwords, cks, sx(t->cfc_est,21),
                        sw_frame, stale_frame, rep_frame);
                outframe++;
                cks=0; nwords=0; sw_frame=stale_frame=rep_frame=0;
            }
        }
    }
    fclose(ff); fclose(fr); fclose(fh);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u mode=%d\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip,mode);
    fprintf(fo,"super_w=%ld pairoff_w=%ld start_w=%ld eatw=%d hitp_milli=%d seed=0x%x\n",
            super_w,pairoff_w,start_w,eatw,hitp_milli,seed);
    fprintf(fo,"nhits_sched=%ld nhits_gated=%ld nsw=%ld nstale=%ld nrepair=%ld noverflow=%ld mingap=%ld\n",
            nhits_sched,nhits_gated,nsw_total,nstale_total,nrepair,noverflow,
            (mingap==(1L<<60))?-1:mingap);
    fprintf(fo,"packets=%u outFrames=%ld nrxw=%ld cfc_est=%lld\n",
            t->packets_out,outframe,nrxw,sx(t->cfc_est,21));
    fclose(fo);
    printf("TICKFIX mode=%d iq=%s outFrames=%ld nrxw=%ld hits=%ld/%ld sw=%ld stale=%ld rep=%ld ovf=%ld mingap=%ld\n",
           mode,iqf,outframe,nrxw,nhits_gated,nhits_sched,nsw_total,nstale_total,
           nrepair,noverflow,(mingap==(1L<<60))?-1:mingap);
    delete t; return 0;
}
