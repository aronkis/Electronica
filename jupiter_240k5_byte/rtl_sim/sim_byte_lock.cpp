// sim_byte_lock.cpp -- STAGE-1 instrumentation driver (2026-08-13 staged task).
// IQ replay through the Jul-25 f1536 bit-true netlist (wrap_byte_lock.v) with a
// PER-FRAME framestat mirror + loop-state dump:
//   <p>_frames.txt : one line per delivered frame (byte_rx_last):
//     outframe clk nwords cksum16 cfc_est ss_err_rms cs_err_rms
//     ssIntP ssIntI csIntP csIntI pdsync nssv ncsv
//   ss_err_rms  = RMS of Gardner_TED_e over the frame's ssV beats (LSB, En24)
//   cs_err_rms  = RMS of PhaseError    over the frame's csV beats (LSB, En10)
//   integrators sampled AT the frame boundary (byte_rx_last beat)
//   cksum16     = 16-bit sum of all delivered bytes of the frame
//   <p>_rxw.txt : delivered words (hex,last,user) for offline CRC verdicts
//   <p>_ss.txt / _cs.txt / _con.txt (dumptaps=1): stage streams for the
//     first-divergent-word comparator (clean vs injected).
// argv: <iq> <nsamp> <vphase> <cadence> <rstcs_end> <skip> <out_prefix> [dumptaps]
#include "Vwrap_byte_lock.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <vector>

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){
        fprintf(stderr,"usage: sim_byte_lock iq nsamp vphase cadence rstcs_end skip out_prefix [dumptaps]\n");
        return 2;
    }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); int vphase=atoi(argv[3]);
    int cadence=atoi(argv[4]); long rstcs_end=atol(argv[5]); unsigned skip=(unsigned)atol(argv[6]);
    const char* pfx=argv[7];
    int dumptaps=(argc>8)?atoi(argv[8]):0;
    if(cadence<1)cadence=1; if(vphase<0||vphase>=cadence)vphase=0;

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
    fprintf(ff,"# outframe clk nwords cksum16 cfc_est ss_err_rms cs_err_rms ssIntP ssIntI csIntP csIntI pdsync nssv ncsv\n");
    FILE* fr=openout("rxw");
    FILE* fss=dumptaps?openout("ss"):nullptr;
    FILE* fcs=dumptaps?openout("cs"):nullptr;
    FILE* fco=dumptaps?openout("con"):nullptr;

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

    // per-frame accumulators
    double ssq=0.0, csq=0.0; long nssv=0, ncsv=0, pdsync=0;
    unsigned cks=0; long nwords=0;

    long total=100 + nsamp*(long)cadence + 60000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();

        if(t->railEnb){
            if(t->ssV){
                double e=(double)sx(t->ssErr,40); ssq+=e*e; nssv++;
                if(fss) fprintf(fss,"%d,%d\n",(int)(short)t->ssI,(int)(short)t->ssQ);
            }
            if(t->csV){
                double e=(double)sx(t->csErr,13); csq+=e*e; ncsv++;
                if(fcs) fprintf(fcs,"%d,%d\n",(int)(short)t->csI,(int)(short)t->csQ);
            }
            if(t->conV && fco) fprintf(fco,"%d,%d\n",(int)(short)t->conI,(int)(short)t->conQ);
            if(t->pdV && t->pdSync) pdsync++;
        }

        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)w,(int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++; nwords++;
            for(int b=0;b<8;b++) cks=(cks+((w>>(8*b))&0xFF))&0xFFFF;
            if(t->byte_rx_last){
                double ssr=nssv?sqrt(ssq/nssv):0.0, csr=ncsv?sqrt(csq/ncsv):0.0;
                fprintf(ff,"%ld %ld %ld %u %lld %.1f %.3f %lld %lld %lld %lld %ld %ld %ld\n",
                        outframe, clk, nwords, cks, sx(t->cfc_est,21), ssr, csr,
                        sx(t->ssIntP,30), sx(t->ssIntI,30),
                        sx(t->csIntP,29), sx(t->csIntI,39),
                        pdsync, nssv, ncsv);
                outframe++;
                ssq=csq=0.0; nssv=ncsv=pdsync=0; cks=0; nwords=0;
            }
        }
    }
    fclose(ff); fclose(fr);
    if(fss)fclose(fss); if(fcs)fclose(fcs); if(fco)fclose(fco);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u dumptaps=%d\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip,dumptaps);
    fprintf(fo,"packets=%u biterr=%u frameStart=%u rstcs=%u cfc_est=%lld nrxw=%ld outFrames=%ld\n",
            t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->rstcs_count,
            sx(t->cfc_est,21),nrxw,outframe);
    fclose(fo);
    printf("LOCK iq=%s nsamp=%ld packets=%u outFrames=%ld nrxw=%ld cfc=%lld\n",
           iqf,nsamp,t->packets_out,outframe,nrxw,sx(t->cfc_est,21));
    delete t; return 0;
}
