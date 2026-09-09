// sim_w1.cpp -- [sim] RXFIX_W1 instrument gate driver (Task 9, 2026-09-04).
//
// NEW FILE.  sim_sro.cpp is Task 7's and is running live legs; nothing here
// touches it.
//
//   sim_w1 rx <iq_file> <nsamp> <rstcs_end> <out_prefix> [cadence] [vphase]
//
// Replays an int16 I/Q file into the receiver exactly as sim_sro.cpp's rx mode
// does (cadence 2 clk per sample, vphase 0, rstCS pulse window), and writes:
//
//   <p>_deliv.txt  one line per delivered byte-plane frame: sidx,nwords,hash,user
//                  -- the DATA-PATH witness.  The s = 0 bit-identity gate is a
//                  byte-for-byte diff of this file between the W1 build and a
//                  baseline build of the same wrapper.
//   <p>_w1.txt     one line per air frame: the eight W1 register words beside an
//                  INDEPENDENT reference computed in this driver from the raw
//                  hierarchical taps.  The COMPARISON, however, is made on EVERY
//                  enb_1_2_0 beat, not only on the logged rows -- a one-beat hole
//                  event would otherwise fall between rows and go unchecked.  The
//                  row file is a readable sample of a continuous test.
//   <p>_res.txt    summary + PASS/FAIL verdict lines.
//
// SAMPLING CONVENTION (this is the whole subtlety).  A Verilator tap read after
// tick k carries the POST-edge value; the RTL counter that ticked on edge k used
// the PRE-edge value.  And the W1 shadow lags its live counter by one enb beat.
// Composing the two: the shadow read at beat k equals the live counter after beat
// k-1, i.e. the sum of the taps as sampled at beats 1..k-1.  So the reference is
// advanced by the PREVIOUS beat's sampled taps (`last*`), one beat behind the
// read -- that makes shadow and reference exactly equal, with no fudge factor,
// and any residual difference is a real instrument fault.
#include "Vwrap_byte_w1.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static const long FRSAMP = 49332;   // samples per air frame (12333 sym * 4 sps)

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 6 || strcmp(argv[1],"rx")){
        fprintf(stderr,"usage: sim_w1 rx <iq> <nsamp> <rstcs_end> <prefix> [cadence] [vphase] [base]\n");
        return 2; }
    const char* iqf = argv[2];
    long nsamp      = atol(argv[3]);
    long rstcs_end  = atol(argv[4]);
    const char* pfx = argv[5];
    const int cadence = (argc>6)?atoi(argv[6]):2;
    const int vphase  = (argc>7)?atoi(argv[7]):0;
    // "base" = a build of this wrapper against the UNPATCHED tree: the W1 ports
    // read 0 by construction, so the register comparison is skipped and the leg
    // exists only to produce the _deliv.txt the s = 0 bit-identity gate diffs.
    const int base    = (argc>8 && !strcmp(argv[8],"base"));

    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    char fn[512];
    auto openout=[&](const char* s)->FILE*{ snprintf(fn,sizeof fn,"%s_%s.txt",pfx,s);
        FILE* f=fopen(fn,"w"); if(!f){ fprintf(stderr,"cannot open %s\n",fn); exit(2);} return f; };
    FILE* fd=openout("deliv");
    FILE* fw=openout("w1");
    fprintf(fw,"# f,occ_ref,occ_w1,push_ref,push_w1,pop_ref,pop_w1,"
               "poe_ref,poe_w1,pof_ref,pof_w1,"
               "cSS_ref,cSS_w1,cRH_ref,cRH_w1,cCFC_ref,cCFC_w1,"
               "cCS_ref,cCS_w1,cPD_ref,cPD_w1,cPC_ref,cPC_w1\n");

    Vwrap_byte_w1* t=new Vwrap_byte_w1;
    long clk=0,sidx=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // ---- independent reference counters, on the same enb beats ----
    unsigned rSS=0,rRH=0,rCFC=0,rCS=0,rPD=0,rPC=0;
    unsigned short rPOE=0,rPOF=0;
    // the previous beat's sampled taps (see SAMPLING CONVENTION above)
    unsigned lSS=0,lRH=0,lCFC=0,lCS=0,lPD=0,lPC=0,lPOE=0,lPOF=0;
    unsigned lOcc=0,lPush=0,lPop=0;
    long ndeliv=0, nframe=0, nmis=0, nrows=0;
    // per-frame byte-plane accumulation (the data-path witness)
    unsigned hash=2166136261u; int nw=0; int fuser=0;
    long lastF=-1;

    auto check=[&](long f, int emit_row){
        // W1 words as the AXI decoder would read them
        unsigned wA=t->w1A, wB=t->w1B;
        unsigned occ_w1=(wA>>10)&0x3F, push_w1=(wA>>5)&0x1F, pop_w1=wA&0x1F;
        unsigned poe_w1=wB&0xFFFF, pof_w1=(wB>>16)&0xFFFF;
        unsigned occ_r=lOcc, push_r=lPush, pop_r=lPop;
        int bad = base ? 0 : (occ_w1!=occ_r)||(push_w1!=push_r)||(pop_w1!=pop_r)
                ||(poe_w1!=rPOE)||(pof_w1!=rPOF)
                ||(t->w1cSS!=rSS)||(t->w1cRH!=rRH)||(t->w1cCFC!=rCFC)
                ||(t->w1cCS!=rCS)||(t->w1cPD!=rPD)||(t->w1cPC!=rPC);
        if(bad) nmis++;
        nrows++;
        if(!emit_row) return;
        fprintf(fw,"%ld,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u\n",
                f,occ_r,occ_w1,push_r,push_w1,pop_r,pop_w1,
                (unsigned)rPOE,poe_w1,(unsigned)rPOF,pof_w1,
                rSS,(unsigned)t->w1cSS, rRH,(unsigned)t->w1cRH,
                rCFC,(unsigned)t->w1cCFC, rCS,(unsigned)t->w1cCS,
                rPD,(unsigned)t->w1cPD, rPC,(unsigned)t->w1cPC);
    };

    long total = 100 + nsamp*(long)cadence + 200000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS = (clk>400 && clk<rstcs_end)?1:0;
        tick();

        long f = sidx/FRSAMP;
        if(t->railEnb){
            // compare BEFORE this beat's reference update: the RTL registers
            // sampled now already contain the effect of every PREVIOUS enb beat,
            // and the reference has been advanced over exactly those beats.
            // compare on EVERY enb beat; log a row once per air frame
            int newframe = (f!=lastF);
            check(f, newframe);
            if(newframe){ lastF=f; nframe++; }
            // advance the reference by the PREVIOUS beat's taps, then latch this
            // beat's taps as the next "previous"
            rSS+=lSS; rRH+=lRH; rCFC+=lCFC; rCS+=lCS; rPD+=lPD; rPC+=lPC;
            rPOE=(unsigned short)(rPOE+lPOE); rPOF=(unsigned short)(rPOF+lPOF);
            lSS=t->rhStrobe; lRH=t->rhValidOut;
            lCFC=t->cfcV; lCS=t->csV; lPD=t->pdV; lPC=t->pcV;
            lPOE=t->rhPopEmpty; lPOF=t->rhPushFull;
            lOcc=t->occTrue; lPush=t->fifoPush; lPop=t->fifoPop;
        }
        // byte-plane delivered stream (data-path witness)
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long d=t->byte_rx_data;
            for(int b=0;b<8;b++){ hash^=(unsigned)((d>>(8*b))&0xFF); hash*=16777619u; }
            nw++;
            if(t->byte_rx_user) fuser=1;
            if(t->byte_rx_last){
                fprintf(fd,"%ld,%d,%08x,%d\n",sidx,nw,hash,fuser);
                ndeliv++; hash=2166136261u; nw=0; fuser=0;
            }
        }
    }
    // one final comparison at the end of the run
    check(-1, 1);

    FILE* fr=openout("res");
    fprintf(fr,"W1GATE prefix=%s iq=%s nsamp=%ld frames=%ld delivered=%ld\n",
            pfx,iqf,nsamp,nframe,ndeliv);
    fprintf(fr,"W1GATE ref cSS=%u cRH=%u cCFC=%u cCS=%u cPD=%u cPC=%u poe=%u pof=%u\n",
            rSS,rRH,rCFC,rCS,rPD,rPC,(unsigned)rPOE,(unsigned)rPOF);
    fprintf(fr,"W1GATE w1  cSS=%u cRH=%u cCFC=%u cCS=%u cPD=%u cPC=%u witA=%08x witB=%08x\n",
            (unsigned)t->w1cSS,(unsigned)t->w1cRH,(unsigned)t->w1cCFC,
            (unsigned)t->w1cCS,(unsigned)t->w1cPD,(unsigned)t->w1cPC,
            (unsigned)t->w1A,(unsigned)t->w1B);
    fprintf(fr,"W1GATE mode=%s compared_beats=%ld mismatches=%ld verdict=%s\n",
            base?"baseline":"w1", nrows,nmis, base?"SKIP":(nmis?"FAIL":"PASS"));
    fclose(fr); fclose(fd); fclose(fw);
    printf("W1GATE %s mode=%s frames=%ld delivered=%ld compared_beats=%ld mismatches=%ld %s\n",
           pfx, base?"baseline":"w1", nframe,ndeliv,nrows,nmis,
           base?"SKIP":(nmis?"FAIL":"PASS"));
    delete t; return nmis?1:0;
}
