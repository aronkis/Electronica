// sim_sro.cpp -- [sim] COMB32 SRO reproduction driver (2026-09-03).
//
//   sim_sro txcap  <nsamp> <out.iq>
//       loopback mode (rx_input_select=0, tx_data_source=0 = BIST ROM):
//       dump the Transmitter's int16 I,Q on every enb_1_2_0 beat -- the exact
//       sample stream the RX consumes in loopback. Legal modulated stimulus
//       straight out of the TX RTL, no Python modulator in the trust chain.
//
//   sim_sro rx <iq_file> <nsamp> <rstcs_end> <out_prefix>
//       replay mode (rx_input_select=1, cadence 4 clk/sample, vphase 0).
//       PER-AIR-FRAME aggregation only (no per-symbol dumps): see _frames.txt.
//
// Outputs of rx mode:
//   <p>_deliv.txt   one line per delivered byte-plane frame:
//                   sidx,nwords,hash,user
//   <p>_frames.txt  one line per 49332-sample input frame bucket.
//                   Columns 1..20 unchanged (legacy scorers keep parsing);
//                   T0a (2026-09-04) APPENDS columns 21..30, the TRUE guarded-ring
//                   taps: occTS,occTE,occTmin,occTmax,rhPopEmpty,rhPushFull,
//                   pdPof,pdPopEmpty,pdOccMin,pdOccMax.
//   <p>_anom.txt    one line per strobe interval != 4: sidx,interval
//   <p>_res.txt     summary
#include "Vwrap_byte_sro.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static const long FRSAMP = 49332;   // samples per air frame (12333 sym * 4 sps)

// ---- T7 (task 7): TGEN v2 expected-frame model (qpsk_traffic_gen_v2.v:61-118) ----
// Non-repeating stimulus: header QK / fill_len LE / seq LE / 0x54474E21, then
// fill_len xorshift32 PN bytes seeded (seq ^ 0x9E3779B9), zero pad to 1528 B.
static inline unsigned t7_xs(unsigned x){
    unsigned a = x ^ (x << 13); unsigned b = a ^ (a >> 17); return b ^ (b << 5); }
static void t7_expect(unsigned seq, int fill, unsigned char* out /*1528*/){
    memset(out, 0, 1528);
    out[0]=0x51; out[1]=0x4B; out[2]=(unsigned char)(fill & 0xFF);
    out[3]=(unsigned char)((fill>>8) & 0x0F);
    out[4]=(unsigned char)(seq); out[5]=(unsigned char)(seq>>8);
    out[6]=(unsigned char)(seq>>16); out[7]=(unsigned char)(seq>>24);
    out[8]=0x21; out[9]=0x4E; out[10]=0x47; out[11]=0x54;
    unsigned pn = seq ^ 0x9E3779B9u; if(pn==0) pn=0xDEADBEEFu;
    for(int i=0;i<fill;i++){ pn = t7_xs(pn); out[12+i]=(unsigned char)(pn & 0xFF); }
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 3){ fprintf(stderr,"usage: sim_sro txcap nsamp out.iq | sim_sro rx iq nsamp rstcs_end prefix\n"); return 2; }

    if(!strcmp(argv[1],"txcap")){
        long nsamp = atol(argv[2]);
        const char* outf = argv[3];
        Vwrap_byte_sro* t = new Vwrap_byte_sro;
        t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
        t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0;
        t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
        t->tgen_sel=0; t->tgen_ctrl=0; t->tgen_gap=0;
        auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); };
        for(int i=0;i<100;i++) tick();
        t->reset=0;
        FILE* fo=fopen(outf,"wb"); if(!fo){ fprintf(stderr,"cannot write %s\n",outf); return 2; }
        long n=0; std::vector<short> buf; buf.reserve(1<<20);
        while(n<nsamp){
            tick();
            if(t->railEnb){ buf.push_back((short)t->txI); buf.push_back((short)t->txQ); n++;
                if(buf.size()>=(1u<<20)){ fwrite(buf.data(),2,buf.size(),fo); buf.clear(); } }
        }
        if(!buf.empty()) fwrite(buf.data(),2,buf.size(),fo);
        fclose(fo);
        printf("TXCAP wrote %ld samples to %s (frames=%.3f)\n",n,outf,(double)n/FRSAMP);
        delete t; return 0;
    }

    // ---- T7 (task 7): NON-REPEATING TX capture ----
    //   sim_sro txcap2 <nsamp> <out.iq> <gap_clks> [fill]
    // tx_data_source=1 (byte plane) with the RTL TGEN v2 driving the byte pins:
    // incrementing seq, PN(seq) payload, so no two air frames are alike.
    // Sidecar <out.iq>.frames.txt: one row per 49332-sample air frame with the
    // TGEN seq range and a byte-exact repeat test against the previous frame.
    if(!strcmp(argv[1],"txcap2")){
        long nsamp = atol(argv[2]);
        const char* outf = argv[3];
        long gap  = (argc>4)? atol(argv[4]) : 96700;
        int  fill = (argc>5)? atoi(argv[5]) : 1516;
        Vwrap_byte_sro* t = new Vwrap_byte_sro;
        t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
        t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1;
        t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
        t->tgen_sel=0; t->tgen_ctrl=0; t->tgen_gap=0;
        long clk=0;
        auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
        for(int i=0;i<100;i++){ t->adc_validIn=(clk&1)?0:1; tick(); }
        t->reset=0;
        // arm the TGEN and select it (frame-boundary safe: en_d gates the mux)
        t->tgen_sel=1;
        t->tgen_ctrl = 1u | ((unsigned)(fill & 0xFFF) << 4);
        t->tgen_gap  = (unsigned)gap & 0x07FFFFFFu;
        FILE* fo=fopen(outf,"wb"); if(!fo){ fprintf(stderr,"cannot write %s\n",outf); return 2; }
        char sfn[512]; snprintf(sfn,sizeof sfn,"%s.frames.txt",outf);
        FILE* fs=fopen(sfn,"w");
        fprintf(fs,"# f,seq_at_end,emitted,repeat_of_prev,allzero,nonzero_words\n");
        long n=0, emitted=0, emAtF=0; std::vector<short> buf; buf.reserve(1<<20);
        std::vector<short> cur, prv;                 // one air frame of I,Q
        cur.reserve(2*FRSAMP); prv.reserve(2*FRSAMP);
        long f=0, nrep=0, nzero=0;
        unsigned char pvTgV=0;
        while(n<nsamp){
            t->adc_validIn=(clk&1)?0:1;
            tick();
            if(t->tg_valid && t->tg_ready && t->tg_first) emitted++;
            if(t->railEnb){
                buf.push_back((short)t->txI); buf.push_back((short)t->txQ); n++;
                cur.push_back((short)t->txI); cur.push_back((short)t->txQ);
                if(buf.size()>=(1u<<20)){ fwrite(buf.data(),2,buf.size(),fo); buf.clear(); }
                if((long)cur.size()==2*FRSAMP){
                    int rep = (prv.size()==cur.size() &&
                               !memcmp(prv.data(),cur.data(),cur.size()*2)) ? 1 : 0;
                    long nz=0; for(size_t i=0;i<cur.size();i++) if(cur[i]) nz++;
                    int az = (nz==0)?1:0;
                    if(rep) nrep++; if(az) nzero++;
                    fprintf(fs,"%ld,%u,%ld,%d,%d,%ld\n",f,(unsigned)t->tg_seq,
                            emitted-emAtF,rep,az,nz);
                    emAtF=emitted; prv.swap(cur); cur.clear(); f++;
                }
            }
        }
        if(!buf.empty()) fwrite(buf.data(),2,buf.size(),fo);
        fclose(fo); fclose(fs);
        printf("TXCAP2 wrote %ld samples to %s frames=%.3f emitted=%ld seq=%u "
               "gap=%ld fill=%d repeat_frames=%ld allzero_frames=%ld\n",
               n,outf,(double)n/FRSAMP,emitted,(unsigned)t->tg_seq,gap,fill,nrep,nzero);
        delete t; return 0;
    }

    // ---- T7 controller probe: per-enb-beat RAM-seam window around pop_on_empty ----
    //   sim_sro ramwin <iq> <nsamp> <rstcs_end> <out.txt> [nevents]
    // Dumps EVERY enb beat for +/-64 beats around each rhPopEmpty, with the ring
    // input word, both pointers, the validated push/pop, the TRUE occupancy and
    // the ring output word -- enough to replay the RAM behaviourally and test
    // whether the emitted word is the previous LAP's content.
    if(!strcmp(argv[1],"ramwin")){
        if(argc < 6){ fprintf(stderr,"usage: sim_sro ramwin iq nsamp rstcs_end out.txt [nev]\n"); return 2; }
        const char* iqf=argv[2]; long nsamp=atol(argv[3]); long rstcs_end=atol(argv[4]);
        const char* outf=argv[5]; int nev_max=(argc>6)?atoi(argv[6]):8;
        FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
        std::vector<short> iq(2*nsamp);
        long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
        if(got/2<nsamp) nsamp=got/2;
        FILE* fo=fopen(outf,"w"); if(!fo){ fprintf(stderr,"cannot write %s\n",outf); return 2; }
        fprintf(fo,"# ev,rel,sidx,beat,inI,inQ,wrAddr,rdAddr,vpush,vpop,occ,popEmpty,pushFull,outI,outQ,validOut,tref\n");
        struct Rec { long sidx, beat; int inI,inQ,wr,rd,vp,vq,occ,pe,pf,oI,oQ,vo,tr; };
        const int W=64;
        std::vector<Rec> ring(2*W+1); long nbeat=0; int nev=0; long pend=-1;
        Vwrap_byte_sro* t=new Vwrap_byte_sro;
        long clk=0,sidx=0; int ph=0; const int cadence=2, vphase=0;
        t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
        t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
        t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
        t->tgen_sel=0; t->tgen_ctrl=0; t->tgen_gap=0;
        auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
        for(int i=0;i<100;i++) tick();
        t->reset=0;
        long total = 100 + nsamp*(long)cadence + 200000;
        while(clk<total && nev<nev_max){
            if(ph==vphase){
                if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
                else t->adc_validIn=0;
            } else t->adc_validIn=0;
            ph=(ph+1)%cadence;
            t->rstCS = (clk>400 && clk<rstcs_end)?1:0;
            tick();
            if(!t->railEnb) continue;
            Rec r; r.sidx=sidx; r.beat=nbeat;
            r.inI=(int)(short)t->rhInI; r.inQ=(int)(short)t->rhInQ;
            r.wr=(int)t->fifoPush; r.rd=(int)t->fifoPop;
            r.vp=(int)t->fifoVPush; r.vq=(int)t->fifoVPop; r.occ=(int)t->occTrue;
            r.pe=(int)t->rhPopEmpty; r.pf=(int)t->rhPushFull;
            r.oI=(int)(short)t->rhOutI; r.oQ=(int)(short)t->rhOutQ;
            r.vo=(int)t->rhValidOut; r.tr=(int)t->tref;
            ring[nbeat % ring.size()] = r;
            if(t->rhPopEmpty && pend < 0 && nbeat > W) pend = nbeat;      // arm
            if(pend >= 0 && nbeat == pend + W){                            // window complete
                for(long b = pend - W; b <= pend + W; b++)
                    { const Rec& q = ring[b % ring.size()];
                      fprintf(fo,"%d,%ld,%ld,%ld,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                              nev,b-pend,q.sidx,q.beat,q.inI,q.inQ,q.wr,q.rd,q.vp,q.vq,
                              q.occ,q.pe,q.pf,q.oI,q.oQ,q.vo,q.tr); }
                nev++; pend=-1;
            }
            nbeat++;
        }
        fclose(fo);
        printf("RAMWIN wrote %s events=%d beats=%ld\n",outf,nev,nbeat);
        delete t; return 0;
    }

    if(strcmp(argv[1],"rx")){ fprintf(stderr,"unknown mode %s\n",argv[1]); return 2; }
    if(argc < 6){ fprintf(stderr,"usage: sim_sro rx iq nsamp rstcs_end prefix\n"); return 2; }
    const char* iqf = argv[2];
    long nsamp      = atol(argv[3]);
    long rstcs_end  = atol(argv[4]);
    const char* pfx = argv[5];
    const int cadence = (argc>6)?atoi(argv[6]):2;
    const int vphase  = (argc>7)?atoi(argv[7]):0;

    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;
    long NFR = nsamp/FRSAMP + 1;

    char fn[512];
    auto openout=[&](const char* s)->FILE*{ snprintf(fn,sizeof fn,"%s_%s.txt",pfx,s);
        FILE* f=fopen(fn,"w"); if(!f){ fprintf(stderr,"cannot open %s\n",fn); exit(2);} return f; };
    FILE* fd=openout("deliv"); FILE* ff=openout("frames"); FILE* fa=openout("anom");
    FILE* fm=openout("marks");   // per demod frame-mark: sidx,ss,cfc,cs,pd,corr,pa,con,dem,push,pop,occ
    // T2 TRACE (task 6): per-event epoch record. kind 0=rhPopEmpty, 1=taSync,
    // 2=timingOffsetValid latch, 3=demod start mark.
    // cols: kind,sidx,f,nCorr,nPop,D,pdOcc,psTref,taRef,taAcc,psToff,newpk,armed,sdcAct,rhPhase,nPE,txFS
    FILE* fe=openout("ep");

    struct Bk { long push=0,pop=0; int occS=-1,occE=0,anom=0; int mumin=2000,mumax=-2000; long und=0;
                long ss=0,cfc=0,cs=0,pd=0,corr=0,pa=0,con=0,dem=0;   // valid-chain census
                long dtref0=0,dtref2=0,dtrefB=0;
                // ---- T0a true-tap census (appended columns) ----
                int oS=-1,oE=0,oMin=64,oMax=-1;          // occTrue (0..32)
                long pe=0,pf=0;                          // rh pop_on_empty / push_on_full
                long pdpf=0,pdpe=0;                      // PD FIFO push_on_full / pop_on_empty
                int pdMin=1<<20,pdMax=-1; };
    std::vector<Bk> bk(NFR+2);

    Vwrap_byte_sro* t=new Vwrap_byte_sro;
    long clk=0,sidx=0,nrxw=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    t->tgen_sel=0; t->tgen_ctrl=0; t->tgen_gap=0;   // T7: TGEN idle in rx mode
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // per-frame byte-plane accumulation
    unsigned hash=2166136261u; int nw=0; int fuser=0;
    // T7 seq-aware verification (only meaningful on a TGEN-generated stimulus)
    const int T7_FILL = getenv("T7_FILL")? atoi(getenv("T7_FILL")) : 1516;
    std::vector<unsigned char> fbytes; fbytes.reserve(1600);
    unsigned char t7exp[1528];
    snprintf(fn,sizeof fn,"%s_seq.txt",pfx); FILE* fq=fopen(fn,"w");
    fprintf(fq,"# sidx,nbytes,magic,seq,nbad,ok\n");
    long t7_ok=0, t7_bad=0, t7_nomagic=0;
    // strobe-interval tracking, in Rate_Handle validIn beats
    long validCnt=0, lastPushValid=-1; long nAnom=0;
    long totPush=0, totPop=0;
    long totPE=0, totPF=0, totPDPF=0, totPDPE=0;
    // valid-chain census, per demod frame mark (mark_demod analogue of dtref_census.py)
    long mSS=0,mCFC=0,mCS=0,mPD=0,mCORR=0,mPA=0,mCON=0,mDEM=0,mPUSH=0,mPOP=0;
    long mPE=0,mPF=0,mPDPF=0,mPDPE=0;
    unsigned char prevDemS=0;
    // tref census: tref advances on Correlator.validOut; dtref==0 is a DELETED symbol
    int prevTref=-1; unsigned char prevCorr=0;
    // T2 TRACE cumulative valid counters: nCorr counts the UNDELAYED chain
    // (Peak_Search's input), nPop the PD-FIFO output chain (Timing_Adjust's
    // input).  D = nCorr - nPop is the tick-vs-valid divergence and equals the
    // PD FIFO occupancy; it is constant iff the two epoch spaces stay aligned.
    long nCorr=0, nPop=0, nPE=0;
    unsigned pvR3S=0, pvR3E=0;   // T7: RXFIX_R3 steered-event edges
    unsigned char pvSync=0, pvToff=0;

    long total = 100 + nsamp*(long)cadence + 200000;
    while(clk<total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS = (clk>400 && clk<rstcs_end)?1:0;
        tick();

        long f = sidx/FRSAMP; if(f>NFR) f=NFR;
        if(t->railEnb){
            Bk& b=bk[f];
            int occ = ((int)t->fifoPush - (int)t->fifoPop) & 31;   // legacy pointer metric
            if(b.occS<0) b.occS=occ;
            b.occE=occ;
            // ---- TRUE occupancy and suppression events ----
            int occT = (int)t->occTrue;                 // 0..32, exact
            if(b.oS<0) b.oS=occT;
            b.oE=occT; if(occT<b.oMin) b.oMin=occT; if(occT>b.oMax) b.oMax=occT;
            int pdo = (int)t->pdOcc;
            if(pdo<b.pdMin) b.pdMin=pdo; if(pdo>b.pdMax) b.pdMax=pdo;
            if(t->rhPopEmpty){ b.pe++; totPE++; }
            if(t->rhPushFull){ b.pf++; totPF++; }
            if(t->pdPof)     { b.pdpf++; totPDPF++; }
            if(t->pdPopEmpty){ b.pdpe++; totPDPE++; }
            if(t->rhValidIn) validCnt++;
            if(t->fifoVPush){ b.push++; totPush++;
                if(lastPushValid>=0){ long iv=validCnt-lastPushValid;
                    if(iv!=4){ b.anom++; nAnom++; fprintf(fa,"%ld,%ld,%ld\n",sidx,iv,f); } }
                lastPushValid=validCnt; }
            if(t->fifoVPop){ b.pop++; totPop++; }
            if(t->icUnd) b.und++;
            if(t->rhValidOut){ b.ss++;  mSS++; }
            if(t->cfcV)      { b.cfc++; mCFC++; }
            if(t->csV)       { b.cs++;  mCS++; }
            if(t->pdV)       { b.pd++;  mPD++; }
            if(t->corrV)     { b.corr++;mCORR++; }
            if(t->paV)       { b.pa++;  mPA++; }
            if(t->conV)      { b.con++; mCON++; }
            if(t->demV)      { b.dem++; mDEM++; }
            if(t->fifoVPush) mPUSH++;
            if(t->fifoVPop)  mPOP++;
            if(t->rhPopEmpty) mPE++;
            if(t->rhPushFull) mPF++;
            if(t->pdPof)      mPDPF++;
            if(t->pdPopEmpty) mPDPE++;
            // tref delta census on every Correlator.validOut beat
            if(t->corrV && !prevCorr){
                int tr=(int)t->tref;
                if(prevTref>=0){ int d=tr-prevTref; if(d<0) d+=12333;
                    if(d==0) b.dtref0++; else if(d==2) b.dtref2++; else if(d>2) b.dtrefB++; }
                prevTref=tr;
            }
            prevCorr = t->corrV;
            // ---- T2 TRACE epoch records ----
            if(t->corrV) nCorr++;
            if(t->pdVPop) nPop++;
            if(t->rhPopEmpty) nPE++;
            {
              long f2 = sidx/FRSAMP;
              int kind=-1;
              if(t->rhPopEmpty) kind=0;
              else if(t->r3Skips != pvR3S) kind=4;    // T7: steered pop SKIP
              else if(t->r3Extras != pvR3E) kind=5;   // T7: steered EXTRA pop
              else if(t->taSync && !pvSync) kind=1;
              else if(t->toffVal && !pvToff) kind=2;
              if(kind>=0)
                fprintf(fe,"%d,%ld,%ld,%ld,%ld,%ld,%d,%d,%d,%d,%d,%d,%d,%d,%d,%ld,%u\n",
                        kind,sidx,f2,nCorr,nPop,nCorr-nPop,(int)t->pdOcc,(int)t->tref,
                        (int)t->taRef,(int)t->taAcc,(int)t->psToff,(int)t->psNewpk,
                        (int)t->taArmed,(int)t->sdcAct,(int)t->rhPhase,nPE,
                        (unsigned)t->cnt_frame_start);
            }
            pvSync = t->taSync; pvToff = t->toffVal;
            pvR3S = t->r3Skips; pvR3E = t->r3Extras;
            // per-frame mark record on the demod start pulse
            unsigned char ds=t->demS;
            if(ds && !prevDemS){
                fprintf(fm,"%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%d,"
                           "%d,%ld,%ld,%ld,%ld,%d\n",
                        sidx,mSS,mCFC,mCS,mPD,mCORR,mPA,mCON,mDEM,mPUSH,mPOP,occ,
                        (int)t->occTrue,mPE,mPF,mPDPF,mPDPE,(int)t->pdOcc);
                mSS=mCFC=mCS=mPD=mCORR=mPA=mCON=mDEM=mPUSH=mPOP=0;
                mPE=mPF=mPDPF=mPDPE=0;
            }
            prevDemS=ds;
            int mu=(int)(short)t->icMu; if(mu&0x400) mu-=0x800; mu&=0xFFFF;
            int m=(int)t->icMu; if(m&0x400) m-=0x800;
            if(m<b.mumin) b.mumin=m; if(m>b.mumax) b.mumax=m;
        }
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long w=t->byte_rx_data;
            for(int i=0;i<8;i++){ unsigned char by=(unsigned char)((w>>(8*i))&0xFF);
                hash^=(unsigned)by; hash*=16777619u;
                if(fbytes.size()<1600) fbytes.push_back(by); }
            nw++; nrxw++;
            if(t->byte_rx_user) fuser=1;
            if(t->byte_rx_last){
                fprintf(fd,"%ld,%d,%08x,%d\n",sidx,nw,hash,fuser);
                // ---- T7 seq-aware check ----
                int magic = (fbytes.size()>=12 && fbytes[0]==0x51 && fbytes[1]==0x4B
                             && fbytes[8]==0x21 && fbytes[9]==0x4E
                             && fbytes[10]==0x47 && fbytes[11]==0x54) ? 1 : 0;
                unsigned sq = 0; int nbad = -1;
                if(fbytes.size()>=12)
                    sq = fbytes[4]|(fbytes[5]<<8)|(fbytes[6]<<16)|((unsigned)fbytes[7]<<24);
                if(magic && fbytes.size()==1528){
                    t7_expect(sq, T7_FILL, t7exp);
                    nbad=0; for(int i=0;i<1528;i++) if(fbytes[i]!=t7exp[i]) nbad++;
                }
                int okf = (magic && nbad==0) ? 1 : 0;
                if(okf) t7_ok++; else if(magic) t7_bad++; else t7_nomagic++;
                fprintf(fq,"%ld,%zu,%d,%u,%d,%d\n",sidx,fbytes.size(),magic,sq,nbad,okf);
                fbytes.clear();
                hash=2166136261u; nw=0; fuser=0;
            }
        }
    }
    for(long f=0; f<NFR; f++){ Bk& b=bk[f];
        fprintf(ff,"%ld,%ld,%ld,%d,%d,%d,%d,%d,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld,"
                   "%d,%d,%d,%d,%ld,%ld,%ld,%ld,%d,%d\n",
                f,b.push,b.pop,b.occS,b.occE,b.anom,
                b.mumin==2000?0:b.mumin,b.mumax==-2000?0:b.mumax,b.und,
                b.ss,b.cfc,b.cs,b.pd,b.corr,b.pa,b.con,b.dem,
                b.dtref0,b.dtref2,b.dtrefB,
                b.oS<0?0:b.oS, b.oE, b.oMin==64?0:b.oMin, b.oMax<0?0:b.oMax,
                b.pe,b.pf,b.pdpf,b.pdpe,
                b.pdMin==(1<<20)?0:b.pdMin, b.pdMax<0?0:b.pdMax); }
    fclose(fd); fclose(ff); fclose(fa); fclose(fm); fclose(fe); fclose(fq);
    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld cadence=%d rstcs_end=%ld\n",iqf,nsamp,cadence,rstcs_end);
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u nrxw=%ld\n",
            t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,nrxw);
    fprintf(fo,"pushes=%ld pops=%ld strobe_anomalies=%ld air_frames=%ld\n",
            totPush,totPop,nAnom,nsamp/FRSAMP);
    fprintf(fo,"r3_skips=%u r3_extras=%u\n",t->r3Skips,t->r3Extras);
    fprintf(fo,"t7_ok=%ld t7_bad=%ld t7_nomagic=%ld t7_fill=%d\n",t7_ok,t7_bad,t7_nomagic,T7_FILL);
    fprintf(fo,"rh_pop_on_empty=%ld rh_push_on_full=%ld pd_push_on_full=%ld pd_pop_on_empty=%ld"
               " occTrue_end=%d pdOcc_end=%d\n",
            totPE,totPF,totPDPF,totPDPE,(int)t->occTrue,(int)t->pdOcc);
    fclose(fo);
    printf("SRO_RX %s packets=%u nrxw=%ld pushes=%ld pops=%ld anom=%ld "
           "rhPE=%ld rhPF=%ld pdPof=%ld pdPE=%ld\n",
           pfx,t->packets_out,nrxw,totPush,totPop,nAnom,totPE,totPF,totPDPF,totPDPE);
    delete t; return 0;
}
