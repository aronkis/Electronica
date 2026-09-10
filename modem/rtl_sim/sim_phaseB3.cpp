// sim_phaseB3.cpp -- T8.1 valid-pattern perturbation harness (external-ADC
// replay of the fixed netlist at the /2-rail cadence, like sim_phaseB2, but
// with controlled irregularities in the adc_validIn placement).
//
// argv: iq nsamp skip mode P1 P2 [seed]
//   mode 0: static parity, vph = P1 (baseline; == sim_phaseB2 vph knob)
//   mode 1: single 1-cycle SLIP at sample index P1 (one extra idle clk is
//           inserted once; every later valid lands on the OPPOSITE parity).
//           P2 unused. Start parity 0.
//   mode 2: every P1 samples, a P2-cycle GAP (no valids), stream resumes on
//           whatever parity the gap ends on (P2 odd => parity flips each gap;
//           regularizer-underflow emulation). Start parity 0.
//   mode 3: every P1 samples, one DOUBLE-BEAT: two valids on consecutive clks
//           (burst-2), then a 3-clk pause so the long-term rate stays 1-in-2.
//           Start parity 0. P2 unused.
//   mode 4: random start parity from seed (P1,P2 unused) -- run twice with
//           different seeds to emulate unknown reset-release phase.
//
// Telemetry: PROG lines every 400k clks + final PHB3_DONE with packets,
// biterr, frameStart, vitrst, bist, rstcs_count, cap_out, cap_cad, cfc_est.
#include "Vrx_wrap_jup.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    const char* iqf=argv[1]; long nsamp=atol(argv[2]);
    unsigned skip=(unsigned)atol(argv[3]);
    int mode=atoi(argv[4]);
    long P1 = argc>5 ? atol(argv[5]) : 0;
    long P2 = argc>6 ? atol(argv[6]) : 0;
    unsigned seed = argc>7 ? (unsigned)atol(argv[7]) : 1;
    FILE* fi=fopen(iqf,"rb"); std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi); if(got/2<nsamp) nsamp=got/2;
    Vrx_wrap_jup* t=new Vrx_wrap_jup;
    t->reset=1;t->rx_input_select=1;t->rstCS=0;t->adc_validIn=0;t->skip_count=skip;
    long sidx=0,clk=0;
    auto tick=[&](){t->clk=0;t->eval();t->clk=1;t->eval();clk++;};
    for(int i=0;i<100;i++)tick();
    t->reset=0;
    auto sx=[](unsigned v)->int{int x=v&0x1FFFFF; if(x&0x100000)x-=0x200000; return x;};
    // schedule state
    long nextValid = 0;              // clk (post-reset counter) of next valid
    if(mode==0) nextValid = P1&1;
    if(mode==4){ srand(seed); nextValid = rand()&1; }
    long slipDone=0, burstPend=0;
    long total=100+(long)nsamp*2+(long)nsamp/2+80000;  // headroom for gaps
    long rel=0;                      // clk counter relative to reset release
    while(clk<total){
        int v=0;
        if(sidx<nsamp && rel==nextValid){
            v=1;
            long step=2;
            if(mode==1 && !slipDone && sidx==P1){ step=3; slipDone=1; }        // 1-cycle slip
            else if(mode==2 && P1>0 && sidx>0 && (sidx%P1)==0){ step=2+P2; }   // gap
            else if(mode==3 && P1>0 && (sidx%P1)==(P1-1) && !burstPend){ step=1; burstPend=1; } // double-beat
            else if(mode==3 && burstPend){ step=3; burstPend=0; }              // repay the beat
            nextValid = rel + step;
        }
        if(v){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
        else t->adc_validIn=0;
        t->rstCS=(clk>400&&clk<8400)?1:0;
        tick(); rel++;
        if((clk%400000)==0)
            printf("PROG clk=%ld samp=%ld pkts=%u ferr=%u fstart=%u rstcs=%u cfc=%d capout=%08x capcad=%08x bist=%u\n",
                clk,sidx,t->packets_out,t->bit_errors_out,t->cnt_frame_start,
                t->rstcs_count,sx(t->cfc_est),t->cap_out,t->cap_cad,t->cnt_bist_start);
    }
    printf("PHB3_DONE mode=%d P1=%ld P2=%ld seed=%u samples=%ld packets=%u biterr=%u frameStart=%u vitrst=%u bist=%u rstcs=%u capout=%08x capcad=%08x cfc_est=%d\n",
        mode,P1,P2,seed,sidx,t->packets_out,t->bit_errors_out,t->cnt_frame_start,
        t->cnt_vit_reset,t->cnt_bist_start,t->rstcs_count,t->cap_out,t->cap_cad,sx(t->cfc_est));
    delete t; return 0;
}
