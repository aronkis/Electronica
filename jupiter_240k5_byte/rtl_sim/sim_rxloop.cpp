// sim_rxloop.cpp -- [sim] Task 8d: closed-loop RX-front-end driver (2026-09-04).
//
// Runs wrap_byte_rxloop.v with the air loop closed IN THE DRIVER:
//   every railEnb (enb_1_2_0) beat produces one TX sample (txI,txQ);
//   the driver rotates it by the CFO, adds AWGN, rounds to int16 and presents
//   it on adc_dataIn{I,Q} with adc_validIn=1 on the NEXT clock.
// Exactly one adc sample is injected per TX sample by construction -- there is
// no rate-matching FIFO that could drift and manufacture a periodicity.  The
// loop latency is a constant one sample; the RX epoch is free-running so a
// constant delay is invisible to it (RX_WINDOW_RTL.md section 3).
//
// usage:
//   sim_rxloop <nepochs> <pfx> <esn0_dB|none> <cfo_Hz> <seed> <gap> <fill>
//              [max_minutes]
//
// Noise convention, verbatim from two_jup/comb/sro_sim/gen_sro_stim.py:
//   Es = mean|x|^2 * SPS (4 sps), N0 = Es/10^(EsN0/10) spread over the full
//   61.44 MHz complex bandwidth, sigma = sqrt(N0/2) per component.
// mean|x|^2 is measured over PWR_EPOCHS whole epochs of the noiseless warm-up
// and then frozen; noise and CFO are switched on together at that instant.
//
// outputs
//   <pfx>_epochs.txt  one line per Peak_Search epoch (12333 samples):
//        ep,clk,heldts,dheldts,toff,accoff,runmax_epochmax,thr,nxcd,nnewpk,nsync,
//        pkts,rxframes
//   <pfx>_frames.txt  one line per delivered byte-plane frame:
//        rxframe,clk,nbytes,ok,allzero,seq,hdr16
//   <pfx>_summary.txt key=value
#include "Vwrap_byte_rxloop.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <ctime>
#include <string>
#include <vector>
#include <random>

static const int  PKT_BYTES   = 1528;
static const long EPOCH_SAMP  = 12333;   // Peak_Search epoch, in RX samples
static const double FS        = 61.44e6; // Hz, per gen_sro_stim.py
static const int  SPS         = 4;
static const long PWR_EPOCHS  = 4;       // noiseless epochs used to measure Es
static const long WARM_EPOCHS = 8;       // impairment switches on after this many

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){
        fprintf(stderr,"usage: sim_rxloop nepochs pfx esn0|none cfo_Hz seed gap fill [max_min]\n");
        printf("RXLOOP_RUN_EXIT=2\n"); return 2;
    }
    long nepochs   = atol(argv[1]);
    const char* pfx= argv[2];
    bool  noisy    = strcmp(argv[3],"none")!=0;
    double esn0    = noisy? atof(argv[3]) : 0.0;
    double cfo     = atof(argv[4]);
    unsigned seed  = (unsigned)atol(argv[5]);
    long gap       = atol(argv[6]);
    int  fill      = atoi(argv[7]); if(fill>1516) fill=1516; if(fill<0) fill=0;
    double maxmin  = (argc>8)? atof(argv[8]) : 1e9;

    char fn[512];
    snprintf(fn,sizeof fn,"%s_epochs.txt",pfx); FILE* fe=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    if(!fe||!ff){ fprintf(stderr,"cannot open outputs for %s\n",pfx); printf("RXLOOP_RUN_EXIT=2\n"); return 2; }
    fprintf(fe,"# ep clk heldts dheldts toff accoff runmax thr nxcd nnewpk nsync pkts rxframes\n");
    fprintf(ff,"# rxframe clk nbytes ok allzero seq hdr16\n");

    Vwrap_byte_rxloop* t = new Vwrap_byte_rxloop;
    long clk=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=1;
    t->tgen_ctrl=0; t->tgen_gap=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    // arm the TGEN (silicon order: generator first)
    t->tgen_ctrl = 1u | ((uint32_t)(fill & 0xFFF) << 4);
    t->tgen_gap  = ((uint32_t)gap & 0x07FFFFFFu);

    std::mt19937_64 rng(seed);
    std::normal_distribution<double> gauss(0.0,1.0);

    // ---- loop / impairment state ----
    long nsamp=0;                 // TX samples produced (= adc samples injected)
    long ninj=0;                  // adc_validIn pulses actually issued
    double pw_acc=0.0; long pw_n=0; bool pw_done=false; double sigma=0.0;
    double theta=0.0; const double dtheta = 2.0*M_PI*cfo/FS;
    long nclip=0;
    bool pend=false; double pI=0,pQ=0;   // sample awaiting injection next clk

    // ---- per-epoch accumulation ----
    long ep=-1; int prev_tref=-1; long nxcd=0,nnewpk=0,nsync=0; long rmax=0;
    uint32_t prev_heldts=0; bool have_prev_ts=false;
    long settle=-1;               // countdown of railEnb beats after a wrap

    // ---- RX framing ----
    std::vector<uint8_t> curf; curf.reserve(PKT_BYTES+64);
    long rx_frames=0, rx_good=0, rx_filler=0;
    time_t t0=time(nullptr);
    long last_check=0;
    bool timeout=false;

    while(ep < nepochs){
        // present the sample produced on the previous railEnb beat
        if(pend){
            double sI=pI, sQ=pQ;
            if(noisy && pw_done){ sI += sigma*gauss(rng); sQ += sigma*gauss(rng); }
            long qI=lround(sI), qQ=lround(sQ);
            if(qI>32767){qI=32767;nclip++;} if(qI<-32768){qI=-32768;nclip++;}
            if(qQ>32767){qQ=32767;nclip++;} if(qQ<-32768){qQ=-32768;nclip++;}
            t->adc_dataInI=(int16_t)qI; t->adc_dataInQ=(int16_t)qQ;
            t->adc_validIn=1; ninj++; pend=false;
        } else t->adc_validIn=0;
        tick();

        if(t->railEnb){
            // ---- TX sample out, impaired, queued for the next clock ----
            double xI=(double)(int16_t)t->txI, xQ=(double)(int16_t)t->txQ;
            if(!pw_done){
                // measure Es over whole epochs [WARM-PWR, WARM) of the noiseless warm-up
                if(nsamp >= (WARM_EPOCHS-PWR_EPOCHS)*EPOCH_SAMP){ pw_acc += xI*xI + xQ*xQ; pw_n++; }
                if(nsamp+1 >= WARM_EPOCHS*EPOCH_SAMP && pw_n>0){
                    double meanp = pw_acc/(double)pw_n;
                    double es = meanp*(double)SPS;
                    double n0 = noisy? es/pow(10.0,esn0/10.0) : 0.0;
                    sigma = sqrt(n0/2.0);
                    pw_done=true;
                    fprintf(stderr,"[rxloop] %s meanp=%.1f Es=%.1f sigma=%.2f at clk=%ld\n",
                            pfx,meanp,es,sigma,clk);
                }
            }
            double cI=xI, cQ=xQ;
            if(pw_done && cfo!=0.0){
                double c=cos(theta), s=sin(theta);
                cI = xI*c - xQ*s; cQ = xI*s + xQ*c;
                theta += dtheta; if(theta>2*M_PI) theta-=2*M_PI; if(theta<-2*M_PI) theta+=2*M_PI;
            }
            pI=cI; pQ=cQ; pend=true; nsamp++;

            // ---- epoch bookkeeping on the RX side ----
            int tref=(int)t->psTref;
            if(prev_tref>=0 && tref < prev_tref){        // epoch wrapped
                settle=3;                                 // let the end-of-epoch latches settle
            }
            prev_tref=tref;
            if(t->corrXcd && t->corrValid) nxcd++;
            if((int)t->psRunmax > rmax) rmax=(int)t->psRunmax;
            if(t->psNewpk) nnewpk++;
            if(t->pdSync)  nsync++;
            if(settle>=0 && --settle<0){
                ep++;
                uint32_t ts=(uint32_t)t->psHeldts;
                long dts = have_prev_ts? (long)(uint32_t)(ts-prev_heldts) : -1;
                if(ep>=0)
                    fprintf(fe,"%ld %ld %u %ld %u %u %ld %d %ld %ld %ld %u %ld\n",
                            ep,clk,ts,dts,(unsigned)t->psToff,(unsigned)t->taAccoff,
                            rmax,(int)t->corrThr,nxcd,nnewpk,nsync,
                            t->packets_out,rx_frames);
                prev_heldts=ts; have_prev_ts=true;
                nxcd=nnewpk=nsync=0; rmax=0;
                if((ep & 63)==0) fflush(fe);
            }
        }

        // ---- RX byte plane ----
        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            for(int b=0;b<8;b++) curf.push_back((uint8_t)(w>>(8*b)));
            if(t->byte_rx_last){
                bool ok = (curf.size()==(size_t)PKT_BYTES) && curf[0]==0x51 && curf[1]==0x4B
                          && curf[8]==0x21 && curf[9]==0x4E && curf[10]==0x47 && curf[11]==0x54;
                bool az=true; for(size_t b=0;b<curf.size();b++) if(curf[b]){ az=false; break; }
                rx_frames++; if(ok) rx_good++; if(az) rx_filler++;
                uint32_t s=0;
                if(curf.size()>=8) s = curf[4]|(curf[5]<<8)|(curf[6]<<16)|((uint32_t)curf[7]<<24);
                fprintf(ff,"%ld %ld %zu %d %d %u ",rx_frames,clk,curf.size(),(int)ok,(int)az,s);
                for(size_t b=0;b<16 && b<curf.size();b++) fprintf(ff,"%02x",curf[b]);
                fprintf(ff,"\n");
                if((rx_frames & 15)==0) fflush(ff);
                curf.clear();
            }
        }

        if(clk - last_check > 20000000L){
            last_check=clk;
            if(difftime(time(nullptr),t0)/60.0 > maxmin){ timeout=true; break; }
        }
    }

    snprintf(fn,sizeof fn,"%s_summary.txt",pfx); FILE* fs=fopen(fn,"w");
    fprintf(fs,"pfx=%s\nnepochs_target=%ld\nepochs=%ld\nclk_end=%ld\ntimeout=%d\n",
            pfx,nepochs,ep,clk,(int)timeout);
    fprintf(fs,"esn0=%s\ncfo_hz=%.1f\nseed=%u\ngap=%ld\nfill=%d\n",
            noisy?argv[3]:"none",cfo,seed,gap,fill);
    fprintf(fs,"tx_samples=%ld\nadc_injected=%ld\nloop_balance=%ld\n",
            nsamp,ninj,nsamp-ninj);
    fprintf(fs,"sigma=%.4f\nclipped=%ld\nclip_frac=%.3e\n",
            sigma,nclip,nsamp? (double)nclip/(2.0*nsamp):0.0);
    fprintf(fs,"rx_frames=%ld\nrx_good=%ld\nrx_filler=%ld\n",rx_frames,rx_good,rx_filler);
    fprintf(fs,"packets_out=%u\ncnt_frame_start=%u\nbit_errors=%u\nbyte_fifo_ovf=%u\ntg_seq=%u\n",
            t->packets_out,t->cnt_frame_start,t->bit_errors_out,t->byte_fifo_ovf,t->tg_seq);
    fclose(fs); fclose(fe); fclose(ff);
    printf("RXLOOP %s epochs=%ld rx=%ld good=%ld filler=%ld pkts=%u tg_seq=%u clk=%ld "
           "sigma=%.3f clip=%ld bal=%ld timeout=%d\n",
           pfx,ep,rx_frames,rx_good,rx_filler,t->packets_out,t->tg_seq,clk,
           sigma,nclip,nsamp-ninj,(int)timeout);
    printf("RXLOOP_RUN_EXIT=%d\n", timeout?3:0);
    fflush(stdout);
    delete t; return timeout?3:0;
}
