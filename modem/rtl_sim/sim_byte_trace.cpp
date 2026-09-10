// sim_byte_trace.cpp -- drive the byte path (tx_data_source=1) and trace the
// Phase Ambiguity resolver boundary for golden vs arbitrary vectors.
// argv: tx_words.hex total_clks rot label
#include "Vwrap_byte_trace.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 5){ fprintf(stderr,"usage: sim tx_words.hex total_clks rot label\n"); return 2; }
    std::vector<unsigned long long> words;
    { FILE* f=fopen(argv[1],"r"); if(!f){fprintf(stderr,"no %s\n",argv[1]);return 2;}
      char ln[128];
      while(fgets(ln,sizeof ln,f)){ if(ln[0]=='\n') continue; words.push_back(strtoull(ln,nullptr,16)); }
      fclose(f); }
    if(words.size()!=35){ fprintf(stderr,"need 35 words, got %zu\n",words.size()); return 2; }
    long total=atol(argv[2]); int rot=atoi(argv[3]); const char* lab=argv[4];
    int armSync=(argc>5)?atoi(argv[5]):1;   // arm capture window at the armSync-th sync pulse
    Vwrap_byte_trace* t=new Vwrap_byte_trace;
    long clk=0; unsigned idx=(unsigned)rot;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1;
    t->byte_valid=1; t->byte_rx_ready=1;
    t->byte_data=words[idx]; t->byte_first=(idx==0);
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    int syncsSeen=0; long armAt=-1; int nrec=0; const int MAXREC=120;
    short lastZI=0x7fff, lastZQ=0x7fff; int zprints=0;
    int pvin=0, pvout=0, psync=0;   // previous-cycle values for edge detect
    // ring buffer of last RB valid-symbol dataIn values (to see PRE-sync preamble)
    const int RB=28; long rbclk[RB]; int rbI[RB], rbQ[RB]; int rbn=0; int dumped=0;
    int ncorr=0;
    while(clk<total){
        if(t->byte_ready && t->byte_valid) idx=(idx+1)%35;
        t->byte_data=words[idx]; t->byte_first=(idx==0); t->byte_valid=1;
        t->adc_validIn=(clk&1)?0:1;
        tick();
        int vin=t->pa_vin, vout=t->pa_vout, sync=t->pa_sync;
        // maintain ring buffer of valid-symbol dataIn (on vin rising edge)
        if(vin && !pvin){ int s=rbn%RB; rbclk[s]=clk; rbI[s]=(int)(short)t->pa_inI; rbQ[s]=(int)(short)t->pa_inQ; rbn++; }
        // count sync pulses (rising edge); arm capture window at the armSync-th sync
        if(sync && !psync){ syncsSeen++; if(armAt<0 && syncsSeen>=armSync) armAt=clk; }
        // on arm, dump the ring buffer (PRE-sync symbols) once
        if(armAt>=0 && !dumped){ dumped=1;
            printf("[%s] --- PRE-SYNC dataIn (last %d valid symbols before/at sync clk=%ld) ---\n", lab, (rbn<RB?rbn:RB), armAt);
            int cnt=(rbn<RB?rbn:RB);
            for(int k=0;k<cnt;k++){ int s=(rbn-cnt+k)%RB; if(s<0)s+=RB;
                printf("[%s]   pre clk=%ld in=(%d,%d)\n", lab, rbclk[s], rbI[s], rbQ[s]); }
        }
        // print every Z update (once per frame)
        if((short)t->pa_zI!=lastZI || (short)t->pa_zQ!=lastZQ){
            lastZI=(short)t->pa_zI; lastZQ=(short)t->pa_zQ;
            if(zprints++ < 12)
              printf("[%s] Zupd clk=%ld  Z=(%d,%d)\n", lab, clk,(int)(short)t->pa_zI,(int)(short)t->pa_zQ);
        }
        // capture on RISING edge of vin/vout, or on a sync pulse, after first sync
        int edge = (vin&&!pvin) || (vout&&!pvout) || (sync&&!psync);
        if(armAt>=0 && nrec<MAXREC && edge){
            printf("[%s] clk=%ld sync=%d vin=%d in=(%d,%d) Z=(%d,%d) vout=%d out=(%d,%d)\n",
                lab, clk, sync, vin,
                (int)(short)t->pa_inI,(int)(short)t->pa_inQ,
                (int)(short)t->pa_zI,(int)(short)t->pa_zQ,
                vout,(int)(short)t->pa_outI,(int)(short)t->pa_outQ);
            nrec++;
        }
        // dump estimator correlation steps (est_scnt rising) after arm
        static int pscnt=0; int scnt=t->est_scnt;
        if(armAt>=0 && scnt && !pscnt && ncorr<40){
            int ii=(int)(short)t->est_inI, iq=(int)(short)t->est_inQ;
            const char* typ = ((ii>0)==(iq>0))?"DIAG(preamble?)":"ANTI(payload!)";
            printf("[%s] CORR clk=%ld cnt=%d in=(%d,%d) %s ref=(%d,%d)\n",
                lab, clk, (int)t->est_cnt, ii, iq, typ,
                (int)(short)t->est_refI,(int)(short)t->est_refQ);
            ncorr++;
        }
        pscnt=scnt;
        pvin=vin; pvout=vout; psync=sync;
    }
    printf("[%s] FINAL cap_in=%08x cap_deint=%08x cap_out=%08x packets=%u biterr=%u syncs=%d\n",
           lab, t->cap_in, t->cap_deint, t->cap_out, t->packets_out, t->bit_errors_out, syncsSeen);
    delete t; return 0;
}
