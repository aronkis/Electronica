// sim_byte_taps.cpp -- P3 localization driver: sim_byte_iq.cpp + per-stage tap
// logging (wrap_byte_taps.v). Replays a raw int16 I,Q capture through the
// bit-true TxRxComposite Rx and dumps every stage-boundary stream so the
// float-vs-fixed hybrid decode ladder can attribute the BER loss to a stage.
//
// argv: sim_byte_taps <iq_file> <nsamp> <vphase> <cadence> <rstcs_end> <skip> <out_prefix> [dumpsamp]
//   dumpsamp: 1 -> also dump the sample-rate taps (agc/rrc; big), default 0.
//
// Outputs (one line per valid beat, raw stored-integer values):
//   <p>_rxw.txt  hex,last,user               decoded byte words (as sim_byte_iq)
//   <p>_ss.txt   I,Q                         symbol-sync out       (sfix16_En14)
//   <p>_cfc.txt  I,Q,freqEst                 coarse-freq-comp out  (+sfix21_En21)
//   <p>_cs.txt   I,Q                         carrier-sync out      (sfix16_En14)
//   <p>_pd.txt   I,Q,sync                    preamble-detector out (+syncPulse)
//   <p>_pa.txt   I,Q,sync                    resolver out          (+syncPulseOut)
//   <p>_con.txt  I,Q                         recovered constellation
//   <p>_dem.txt  bit,start                   demod hard bits
//   <p>_agc.txt  I,Q      (dumpsamp)         AGC out               (sfix16_En14)
//   <p>_rrc.txt  I,Q      (dumpsamp)         RRC MF out            (sfix16_En12)
//   <p>_res.txt  final regs (as sim_byte_iq)
#include "Vwrap_byte_taps.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){
        fprintf(stderr,"usage: sim_byte_taps iq_file nsamp vphase cadence rstcs_end skip out_prefix [dumpsamp]\n");
        return 2;
    }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    int  vphase     = atoi(argv[3]);
    int  cadence    = atoi(argv[4]);
    long rstcs_end  = atol(argv[5]);
    unsigned skip   = (unsigned)atol(argv[6]);
    const char* pfx = argv[7];
    int dumpsamp    = (argc > 8) ? atoi(argv[8]) : 0;
    if(cadence < 1) cadence = 1;
    if(vphase < 0 || vphase >= cadence) vphase = 0;

    FILE* fi = fopen(iqf,"rb");
    if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi);
    fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    char fn[512];
    auto openout=[&](const char* suf)->FILE*{
        snprintf(fn,sizeof fn,"%s_%s.txt",pfx,suf);
        FILE* f=fopen(fn,"w");
        if(!f){ fprintf(stderr,"cannot open %s\n",fn); exit(2); }
        return f;
    };
    FILE* fr  = openout("rxw");
    FILE* fss = openout("ss");
    FILE* fcf = openout("cfc");
    FILE* fcs = openout("cs");
    FILE* fpd = openout("pd");
    FILE* fpa = openout("pa");
    FILE* fco = openout("con");
    FILE* fde = openout("dem");
    FILE* ffe = openout("fec");
    FILE* fag = dumpsamp ? openout("agc") : nullptr;
    FILE* frr = dumpsamp ? openout("rrc") : nullptr;

    Vwrap_byte_taps* t = new Vwrap_byte_taps;
    long clk=0, sidx=0, nrxw=0;
    int  ph=0;
    // 21-bit signed sign-extension for cfcFreq / cfc_est
    auto sx21=[](unsigned v)->int{ int x=v&0x1FFFFF; if(x&0x100000) x-=0x200000; return x; };

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0;
    t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    long total = 100 + nsamp*(long)cadence + 60000;
    while(clk < total){
        if(ph==vphase){
            if(sidx<nsamp){
                t->adc_dataInI = iq[2*sidx];
                t->adc_dataInQ = iq[2*sidx+1];
                t->adc_validIn = 1;
                sidx++;
            } else t->adc_validIn = 0;
        } else t->adc_validIn = 0;
        ph = (ph+1)%cadence;

        t->rstCS = (clk>400 && clk<rstcs_end) ? 1 : 0;
        tick();

        if(t->byte_rx_valid && t->byte_rx_ready){
            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,
                    (int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++;
        }
        // stage taps: one line per valid RAIL beat (the DSP chain lives in the
        // enb_1_2_0 = clk/2 domain -- a valid beat spans 2 clks; gate on railEnb
        // so each beat logs exactly once), raw stored integers
        if(t->railEnb){
            if(t->ssV)  fprintf(fss,"%d,%d\n",(int)(short)t->ssI,(int)(short)t->ssQ);
            if(t->cfcV) fprintf(fcf,"%d,%d,%d\n",(int)(short)t->cfcI,(int)(short)t->cfcQ,sx21(t->cfcFreq));
            if(t->csV)  fprintf(fcs,"%d,%d\n",(int)(short)t->csI,(int)(short)t->csQ);
            if(t->pdV)  fprintf(fpd,"%d,%d,%d\n",(int)(short)t->pdI,(int)(short)t->pdQ,(int)t->pdSync);
            if(t->paV)  fprintf(fpa,"%d,%d,%d\n",(int)(short)t->paI,(int)(short)t->paQ,(int)t->paSync);
            if(t->conV) fprintf(fco,"%d,%d\n",(int)(short)t->conI,(int)(short)t->conQ);
            if(t->demV) fprintf(fde,"%d,%d\n",(int)t->demB,(int)t->demS);
            if(t->fecV) fprintf(ffe,"%d,%d\n",(int)t->fecB,(int)t->fecS);
            if(dumpsamp){
                if(t->agcV) fprintf(fag,"%d,%d\n",(int)(short)t->agcI,(int)(short)t->agcQ);
                if(t->rrcV) fprintf(frr,"%d,%d\n",(int)(short)t->rrcI,(int)(short)t->rrcQ);
            }
        }
    }
    fclose(fr); fclose(fss); fclose(fcf); fclose(fcs);
    fclose(fpd); fclose(fpa); fclose(fco); fclose(fde); fclose(ffe);
    if(fag) fclose(fag);
    if(frr) fclose(frr);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u dumpsamp=%d\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip,dumpsamp);
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u cfc_est=%d nrxw=%ld\n",
            t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,sx21(t->cfc_est),nrxw);
    fclose(fo);
    printf("TAPS nsamp=%ld packets=%u capout=%08x nrxw=%ld cfc=%d\n",
           nsamp,t->packets_out,t->cap_out,nrxw,sx21(t->cfc_est));
    delete t;
    return 0;
}
