// sim_byte_iq.cpp -- IQ-REPLAY driver for the deployed byte-modem RTL
// (wrap_byte.v -> TxRxComposite). Feeds a captured raw ADC I/Q file through the
// ADC path (rx_input_select=1) and captures the DECODED byte_rx output words +
// BIST registers -- proving the RTL injection path is bit-exact (unlike the
// sibling sim_jup.cpp which reads counters only, never decoded bytes).
//
// argv: sim_byte_iq <iq_file> <nsamp> <vphase> <cadence> <rstcs_end> <skip> <out_prefix>
//   iq_file    : interleaved int16 I,Q,I,Q,...
//   nsamp      : max complex samples to feed (clamped to file length)
//   vphase     : which phase slot in [0,cadence) carries a valid ADC sample
//   cadence    : adc_validIn duty -- one ADC sample every <cadence> clks
//                (byte kit receiver runs at enb_1_2_0 = clk/2 -> primary=2)
//   rstcs_end  : assert rstCS=1 for clk in (400, rstcs_end), else 0
//   skip       : skip_count value
//   out_prefix : writes <prefix>_rxw.txt (hex,last,user per accepted beat)
//                       <prefix>_res.txt (final regs + steady-state check)
//
// Golden-word match: if ./rx_words_golden.hex (16 words) is present in cwd, the
// driver counts byte_rx beats that equal golden[0] ("ADI Hell"), golden[1]
// ("o World"), and any golden word -- the "ADI Hello World" locked BIST stream.
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){
        fprintf(stderr,"usage: sim_byte_iq iq_file nsamp vphase cadence rstcs_end skip out_prefix\n");
        return 2;
    }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    int  vphase     = atoi(argv[3]);
    int  cadence    = atoi(argv[4]);
    long rstcs_end  = atol(argv[5]);
    unsigned skip   = (unsigned)atol(argv[6]);
    const char* pfx = argv[7];
    if(cadence < 1) cadence = 1;
    if(vphase < 0 || vphase >= cadence) vphase = 0;

    // --- load interleaved int16 I/Q (clamp to file length) ---
    FILE* fi = fopen(iqf,"rb");
    if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi);
    fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    // --- optional golden-word reference (./rx_words_golden.hex, 16 words) ---
    std::vector<unsigned long long> gold;
    { FILE* fg=fopen("rx_words_golden.hex","r");
      if(fg){ char ln[128];
        while(fgets(ln,sizeof ln,fg)){ if(ln[0]=='\n') continue;
            gold.push_back(strtoull(ln,nullptr,16)); }
        fclose(fg); } }
    std::set<unsigned long long> goldset(gold.begin(),gold.end());
    unsigned long long gold0 = gold.size()>0 ? gold[0] : 0ULL;
    unsigned long long gold1 = gold.size()>1 ? gold[1] : 0ULL;

    // --- outputs ---
    char fn[512];
    snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");

    Vwrap_byte* t = new Vwrap_byte;
    long clk=0, sidx=0, nrxw=0;
    int  ph=0;
    long ngold0=0, ngold1=0, ngoldAny=0, nuser=0;
    unsigned errLate=0, pkLate=0;
    // cap_out (BIST info word) tracking. FecCapture re-arms on each frame startIn
    // and holds the last frame's first-32 decoded bits; golden = 0x04922282.
    const unsigned CAPGOLD = 0x04922282u;
    unsigned capPrev = 0xFFFFFFFFu, capLast = 0;
    long capGoldFrames=0, capNonzFrames=0, capGoldClks=0;
    bool capEverGold=false;

    // static input config: ADC/air path, byte-TX source disabled
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0;
    t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    // 21-bit signed sign-extension for cfc_est
    auto sx=[](unsigned v)->int{ int x=v&0x1FFFFF; if(x&0x100000) x-=0x200000; return x; };

    for(int i=0;i<100;i++) tick();
    t->reset=0;

    long total = 100 + nsamp*(long)cadence + 60000;
    long lateAt = (long)(0.70*(double)total);
    while(clk < total){
        // feed one ADC sample on the vphase slot of each cadence window
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

        // cap_out (BIST) running-golden tracker: count clks it holds golden.
        { unsigned cap = t->cap_out;
          if(cap==CAPGOLD){ capGoldClks++; capEverGold=true; }
          capLast=cap; (void)capPrev; }

        // accepted byte-rx beats (ready tied 1 -> one beat per decoded word)
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long w = (unsigned long long)t->byte_rx_data;
            fprintf(fr,"%016llx,%d,%d\n",w,(int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++;
            if(t->byte_rx_user) nuser++;
            if(!gold.empty()){
                if(w==gold0) ngold0++;
                if(w==gold1) ngold1++;
                if(goldset.count(w)) ngoldAny++;
            }
            // sample the BIST cap_out once per completed output frame (byte_rx_last)
            // -> clean "N of M frames golden" alignment with the byte stream.
            if(t->byte_rx_last){
                capNonzFrames++;               // total completed output frames
                if(t->cap_out==CAPGOLD) capGoldFrames++;
            }
        }
        if(clk==lateAt){ errLate=t->bit_errors_out; pkLate=t->packets_out; }
    }
    fclose(fr);

    unsigned capout = t->cap_out;
    unsigned biterr = t->bit_errors_out;
    unsigned packets= t->packets_out;
    // steady-state errors = total - value at 70% mark (acquisition errors are
    // front-loaded; the known-good loopback carries biterr=102 all before 70%).
    unsigned errSteady = (biterr>=errLate) ? (biterr-errLate) : biterr;
    int cfc = sx(t->cfc_est);
    // BIST lock = the cap_out register held the golden info word 0x04922282 on
    // at least one completed frame during the run (it re-arms every frame).
    bool goldLock = capEverGold;
    double capGoldFrac = capNonzFrames>0 ? (double)capGoldFrames/(double)capNonzFrames : 0.0;

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip);
    fprintf(fo,"packets=%u biterr=%u errLate=%u errSteady=%u pkLate=%u frameStart=%u\n",
            packets,biterr,errLate,errSteady,pkLate,t->cnt_frame_start);
    fprintf(fo,"capout_final=%08x capEverGolden=%d capGoldFrames=%ld/%ld (%.1f%%) capGoldClks=%ld\n",
            capout,(int)capEverGold,capGoldFrames,capNonzFrames,100.0*capGoldFrac,capGoldClks);
    fprintf(fo,"rstcs=%u cfc_est=%d nrxw=%ld nuser=%ld\n",
            t->rstcs_count,cfc,nrxw,nuser);
    fprintf(fo,"goldHdr=%ld gold1=%ld goldAny=%ld goldLOCK=%d\n",
            ngold0,ngold1,ngoldAny,(int)goldLock);
    fclose(fo);

    printf("IQ nsamp=%ld vphase=%d cadence=%d packets=%u biterr=%u capout=%08x nrxw=%ld cfc=%d"
           " | errLate=%u errSteady=%u capEverGold=%d capGoldFrames=%ld/%ld goldHdr=%ld gold1=%ld goldAny=%ld nuser=%ld goldLOCK=%s\n",
           nsamp,vphase,cadence,packets,biterr,capLast,nrxw,cfc,
           errLate,errSteady,(int)capEverGold,capGoldFrames,capNonzFrames,
           ngold0,ngold1,ngoldAny,nuser,goldLock?"YES":"no");
    delete t;
    return 0;
}
