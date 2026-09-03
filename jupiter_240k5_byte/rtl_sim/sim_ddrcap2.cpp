// sim_ddrcap2.cpp -- DDRCAP-v2 Tier-1 gate (spec sec 4). Mode-1 ROM loopback.
// PART A (threaded build): for sel 0..15 (7 skipped=dead; 9-11 bit-domain taps run too, per the
//   Task 4 controller ruling -- every channel needs a control, and the v1 gate's marker==0x7FFF
//   check does not apply after the repack): I/Q not all-zero (where expected), exactly one demod
//   + one TX marker bit per frame, slot cycles 0,1,2,3 on consecutive captured beats, toff in
//   [0,12332] and steady (one modal value >= 95% after frame 20) in clean loopback, tref slot
//   increments mod 12333, sel12 shows one dominant peak per frame.
//   sel 9-11 pack 16 bits/record so a short NF yields far fewer captured beats than the
//   sample/symbol taps; their records floor is lowered to 200 (noted in the report) instead of 1000.
// PART B (flat build only): hold-force each field for 128 clks and require the exact readback.
//   Runtime controller ruling (2026-09-02, after the NF=40/all-parts-in-one-binary launch measured
//   ~4 kclk/s flat and would have taken ~8h): PART B now runs standalone on the flat build at
//   NF=8, force-triggered at cnt_frame_start==10 (was 30) and read back from frames 10..11 (was
//   30..31); the run() "warm" floor (minimum captured cnt_frame_start) is a parameter so PART B
//   can use warm=6 while PART A/C keep warm=20. Same checks/expectations, only the run lengths
//   moved to fit a short, fast forced-region window instead of a full free-run acquisition.
// PART C (threaded build): sel14 differs between golden and perturbed TX word files (tx_data_source=1).
//
// argv[1] = MODE: A | B | C | all (default: all)
// argv[2] = NF (default: 20). For PART A/C this is the frame count run past the warm=20 floor.
//           PART B's force geometry (trigger frame 10, 128-clk hold, readback frames 10-11) is
//           independent of NF as long as NF covers those frames; NF is still honoured as the
//           total-frame budget so a caller can lengthen the PART B run if ever needed.
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#ifdef DDRCAP2_FLAT
#include "Vwrap_byte_ddrcap___024root.h"
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>
#include <map>
#include <algorithm>
static const long CPF = 197328;
struct Rec { short i, q; unsigned short c2, c3; long clk; };
struct Run { std::vector<Rec> r; std::vector<unsigned> frame_of; unsigned frames = 0; };

static void init(Vwrap_byte_ddrcap* t, unsigned sel, unsigned txsrc){
    t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0; t->rstCS=0;
    t->rx_input_select=0; t->skip_count=0; t->tx_data_source=txsrc; t->fixctl=0;
    t->iq_debug_mux=((sel&0xF)<<16)|3; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
}
static std::vector<unsigned long long> words(const char* p){ std::vector<unsigned long long> w; FILE* f=fopen(p,"r"); char l[128];
    while(f && fgets(l,sizeof l,f)) if(l[0]!='\n') w.push_back(strtoull(l,nullptr,16)); if(f) fclose(f); return w; }

// Runs NF frames past a "warm" cnt_frame_start floor; optional TX word feed; optional force
// callback per clk (flat only). warm defaults to 20 (PART A/C's acquisition-settled floor);
// PART B passes warm=6 to work inside its much shorter NF=8 window.
template<class F> static Run run(unsigned sel, int NF, const std::vector<unsigned long long>* wf, unsigned warm, F force){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()}; init(t, sel, wf?1:0);
    unsigned idx=0; long clk=0; auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    Run R; long total=100+(long)(NF+4)*CPF;
    while(clk<total){
        if(wf){ if(t->byte_ready && t->byte_valid) idx=(idx+1)%wf->size(); t->byte_data=(*wf)[idx]; t->byte_first=(idx==0); t->byte_valid=1; }
        t->adc_validIn=(clk&1)?0:1;
        force(t, clk, t->cnt_frame_start);
        tick();
        if(t->ddrcap_valid && t->cnt_frame_start>=warm){
            R.r.push_back({(short)t->ddrcap_i,(short)t->ddrcap_q,(unsigned short)t->ddrcap_mark_demod,(unsigned short)t->ddrcap_mark_fec,clk});
            R.frame_of.push_back(t->cnt_frame_start);
        }
    }
    R.frames=t->cnt_frame_start; delete t; return R;
}
static bool pr(const char* what, bool ok, const char* detail=""){ printf("  %-58s %s %s\n", what, ok?"PASS":"FAIL", detail); return ok; }

// PART B falsifiability rewrite (2026-09-02 review): the original check only asked "does the
// expected value appear ANYWHERE in the readback window", which a free-running counter can
// satisfy by pure chance as it counts through the target value once -- e.g. a mod-12333 tref
// counter passes through 0x1234 once every frame with or without any force, and a mod-32 push
// counter passes through 0x15 once every 32 counts. Fixed: require the expected value to hold for
// >= K CONSECUTIVE captured records inside the force hold window (or, for the two negative
// controls below, K consecutive records ANYWHERE with no force applied at all) -- a value that is
// merely counted through cannot sustain K in a row, but a genuinely forced/held register can.
// chan: 0=I, 1=Q, 2=ch2[13:0], 3=ch3 sidecar at `slot` (only records at that slot are considered,
// so "K consecutive" for a sidecar field means K consecutive OCCURRENCES of that slot, i.e. K
// consecutive frames, since the slot cycles 0,1,2,3 once per captured beat).
// winLen<0 means "no window filter" (used by the negative controls, which search the whole run).
static unsigned maxConsecMatch(const Run& R, int chan, unsigned expect, int slot, long winStart, long winLen, unsigned mask){
    unsigned maxRun=0, cur=0;
    for(unsigned k=0;k<R.r.size();k++){ const Rec& x=R.r[k];
        if(winLen>=0 && (x.clk<winStart || x.clk>=winStart+winLen)) continue;
        if(chan==3 && (int)(x.c3>>14)!=slot) continue;
        unsigned v = chan==2 ? (x.c2&0x3FFF) : chan==3 ? (x.c3&0x3FFF) : chan==0 ? (unsigned short)x.i : (unsigned short)x.q;
        if((v&mask)==(expect&mask)){ cur++; if(cur>maxRun) maxRun=cur; } else cur=0; }
    return maxRun;
}
static bool checkK(const char* name, const Run& R, int chan, unsigned expect, int slot, long winStart, long winLen, unsigned K, unsigned mask=0xFFFF){
    unsigned mr=maxConsecMatch(R,chan,expect,slot,winStart,winLen,mask);
    char d[140]; snprintf(d,sizeof d,"expect=0x%X mask=0x%X K=%u maxRun=%u window=[%ld,%ld)",expect,mask,K,mr,winStart,winStart+winLen);
    return pr(name, mr>=K, d);
}
// Negative control: run WITHOUT force, then verify the SAME K-consecutive condition correctly
// FAILS anywhere in the whole run (no window). PASS for this row means "the check is falsifiable"
// (it correctly failed with no force); FAIL here would mean the check can never discriminate a
// real force from a free-running counter, i.e. the check itself is broken.
static bool checkExpectFail(const char* name, const Run& R, int chan, unsigned expect, int slot, unsigned K, unsigned mask=0xFFFF){
    unsigned mr=maxConsecMatch(R,chan,expect,slot,0,-1,mask);
    bool correctlyFails = mr<K;
    char d[160]; snprintf(d,sizeof d,"NO FORCE: expect=0x%X mask=0x%X K=%u maxRun=%u (must stay <K) -> %s",
             expect,mask,K,mr, correctlyFails?"FAIL-AS-EXPECTED":"UNEXPECTEDLY REACHED K (check not falsifiable!)");
    return pr(name, correctlyFails, d);
}

static bool partA(unsigned sel, const Run& R){
    char nm[96]; bool ok=true; unsigned n=R.r.size();
    // sel 9-11 are bit-domain taps: 16 bits packed per DDR record, so a clean short run captures
    // far fewer records than the sample/symbol-domain selectors. Controller ruling: lower the
    // floor for these three to 200 (still well above noise) instead of the default 1000.
    unsigned floor = (sel>=9 && sel<=11) ? 200 : 1000;
    char d0[32]; snprintf(d0,sizeof d0,"n=%u",n);
    snprintf(nm,sizeof nm,"sel%u records>%u",sel,floor); ok&=pr(nm,n>floor,d0);
    if(n<=floor) return false;
    unsigned nz=0, md=0, mf=0, slotok=0; std::map<unsigned,unsigned> toffh; int prevslot=-1; unsigned trefok=0, trefn=0; int prevtref=-1;
    for(unsigned k=0;k<n;k++){ const Rec& x=R.r[k]; if(x.i||x.q) nz++; if(x.c2>>15) md++; if((x.c2>>14)&1) mf++;
        toffh[x.c2&0x3FFF]++; int s=x.c3>>14; if(prevslot>=0 && s==((prevslot+1)&3)) slotok++; prevslot=s;
        if(s==1){ int tr=x.c3&0x3FFF; if(prevtref>=0){ trefn++; if(tr>prevtref || (prevtref>12000 && tr<400)) trefok++; } prevtref=tr; } }
    unsigned fr=R.frame_of.back()-R.frame_of.front();
    snprintf(nm,sizeof nm,"sel%u I/Q not all zero",sel); ok&=pr(nm, nz>n/100); // sel7 is never reached here (skipped in runPartA's loop), so the old "sel==7 ? true :" branch was dead
    snprintf(nm,sizeof nm,"sel%u demod marks per frame ~1",sel); ok&=pr(nm, md+1>=fr && md<=fr+1);
    snprintf(nm,sizeof nm,"sel%u tx marks per frame ~1",sel);    ok&=pr(nm, mf+1>=fr && mf<=fr+1);
    snprintf(nm,sizeof nm,"sel%u slot cycles 0..3",sel);          ok&=pr(nm, slotok>=n-2);
    unsigned best=0,bestc=0; for(auto& kv:toffh) if(kv.second>bestc){best=kv.first;bestc=kv.second;}
    char d[64]; snprintf(d,sizeof d,"mode=%u frac=%.3f",best,(double)bestc/n);
    snprintf(nm,sizeof nm,"sel%u toff in range and steady",sel);  ok&=pr(nm, best<=12332 && bestc>=n*95/100, d);
    snprintf(nm,sizeof nm,"sel%u tref slot monotone mod 12333",sel); ok&=pr(nm, trefn>0 && trefok>=trefn*95/100);
    return ok;
}
// sel12: correlator magnitude run-count/consistency check.
// History (2026-09-02): the original rule ("peaks>half-max in [frames/2, frames*3]") FAILED at
// peaks>half-max=343 over frames=26 (~13.2/frame). Controller ruling: diagnose as data, not a
// threshold tweak. A per-frame dump (mode D, beat_runs/ddrcap2_sel12_mag.txt, frames 25-35) shows
// EXACTLY 13 contiguous runs per frame, each run exactly 1 record wide, at the SAME 13 record
// offsets in every one of the 11 dumped frames (offsets 2143,2380,3105,3371,3439,3584,5618,6453,
// 8554,10377,10799,10921,12320 out of 12333 records/frame; see beat_runs/ddrcap2_sel12_mag.txt).
// RTL derivation: Correlator.v's matched filter (Discrete_FIR_Filter/Filter.v, coefIn_0..12 = 13
// taps) is matched to the preamble, followed by Magnitude_Squared_and_Moving_Sum.v's OWN 13-tap
// boxcar (Delay_reg[0:12]). A single ideal correlation impulse smeared by a 13-tap boxcar would
// be expected to widen to multiple adjacent records above half-max, not stay 1-record wide -- so
// the observed width=1 says the underlying (pre-boxcar) correlation is itself impulse-like at
// EVERY one of these 13 offsets, not just at the true preamble alignment. In mode-1 ROM/BIST
// loopback the same fixed payload repeats every frame, so a payload sub-sequence that happens to
// partially match the 13-tap preamble filter reproduces the SAME spurious correlation spike at
// the SAME offset every frame -- deterministic data-dependent sidelobes, not jitter or a broken
// tap. This is exactly the "multi-run structure" the controller ruling anticipated as a genuine,
// reportable observation rather than a bug: sel12 is counted LIVE on the strength of its other
// PART A checks (all PASS: nonzero, marks, slots, toff, tref) plus PART B's direct forced
// readback of the correlator register (Correlator.v Delay2_out1, sel12 I/Q, both PASS) -- PART
// B's poke-and-read-back is sel12's real positive control; this check is a structural/liveness
// observation on top of it.
static bool peakA(const Run& R){
    unsigned n=R.r.size();
    std::map<unsigned, std::vector<unsigned>> byFrame; // frame -> mags, in capture order
    for(unsigned k=0;k<n;k++){
        unsigned mag=((unsigned)(unsigned short)R.r[k].i<<16)|(unsigned short)R.r[k].q;
        byFrame[R.frame_of[k]].push_back(mag);
    }
    // Use only frames with a full record set (matches the common/modal count -- a partial frame
    // at the very start/end of the capture window can't be mistaken for a peak-count anomaly).
    std::map<unsigned,unsigned> cnth; for(auto& kv:byFrame) cnth[kv.second.size()]++;
    unsigned modalCount=0,modalC=0; for(auto& kv:cnth) if(kv.second>modalC){modalC=kv.second;modalCount=kv.first;}
    // Coordinator ruling (2026-09-02, after reviewing beat_runs/ddrcap2_sel12_mag.txt dumped by
    // mode D): the original threshold (0.5x max) FAILED because it also catches a dense,
    // deterministic ~50% sidelobe floor -- ~16 secondary peaks/frame at fixed positions, ratios
    // 0.48-0.61 (largest 0.60), none within 60 symbols of a known rung {6176,6240,6299,6363,
    // 6432,6489,6548}, at the SAME offsets every frame (mode-1 ROM/BIST loopback repeats the
    // identical payload every frame, so a reproducible correlator reproduces the identical
    // sidelobe pattern). The MAIN peak is exactly one record wide at ratio 1.0. New rule: PASS
    // iff every analyzed frame has EXACTLY ONE record above 0.8x that frame's max (the main
    // peak); records in (0.45x,0.8x] are reported as a census (data, not a gate condition).
    const double MAIN_FRAC = 0.8, SEC_LO_FRAC = 0.45;
    bool mainOk = true;
    unsigned framesChecked = 0;
    unsigned long secCountSum = 0;
    double maxSecRatio = 0.0;
    long maxSecOffset = 0; // signed, mod modalCount, relative to the main peak
    for(auto& kv:byFrame){
        auto& mags=kv.second; if(mags.size()!=modalCount) continue;
        unsigned mx=0; for(unsigned m:mags) if(m>mx) mx=m;
        double mainThresh = MAIN_FRAC*mx, secLo = SEC_LO_FRAC*mx;
        unsigned mainCount=0; long mainIdx=-1; unsigned secCount=0;
        for(unsigned i=0;i<mags.size();i++){
            double v=mags[i];
            if(v>mainThresh){ mainCount++; mainIdx=i; }
            else if(v>secLo){
                secCount++;
                double ratio=(double)mags[i]/mx;
                if(ratio>maxSecRatio){ maxSecRatio=ratio; maxSecOffset=(long)i; } // offset fixed up below once mainIdx is known
            }
        }
        if(mainCount!=1) mainOk=false;
        // fix up the offset of THIS frame's best-so-far secondary relative to THIS frame's main peak
        if(mainIdx>=0){
            for(unsigned i=0;i<mags.size();i++){
                double v=mags[i];
                if(v<=mainThresh && v>secLo && (double)v/mx==maxSecRatio){
                    long off=(long)i-mainIdx;
                    long half=(long)modalCount/2;
                    if(off>half) off-=modalCount; else if(off<-half) off+=modalCount;
                    maxSecOffset=off;
                }
            }
        }
        secCountSum += secCount;
        framesChecked++;
    }
    if(framesChecked==0) return pr("sel12 correlator single main peak (>0.8x max)", false, "no full frames captured");
    double secMean = (double)secCountSum/framesChecked;
    char census[160];
    snprintf(census,sizeof census,"secondaries(0.45x-0.8x)/frame mean=%.1f largest_secondary_ratio=%.2f offset_from_main=%+ld records frames_checked=%u",
             secMean, maxSecRatio, maxSecOffset, framesChecked);
    pr("sel12 secondary-peak census (data, not a gate)", true, census);
    char d[64]; snprintf(d,sizeof d,"frames_checked=%u",framesChecked);
    return pr("sel12 correlator single main peak (>0.8x max)", mainOk, d);
}

// sel13: interpolator phase accumulator liveness (spec sec 4 sel13 row). I packs
// {underflow_sticky, 4'b0, countReg[10:0]}. countReg must not be constant (it sweeps its modulo
// range every symbol); the underflow-sticky bit (I[15]) must average ~0.25 across captured beats.
// CORRECTED 2026-09-02 (review re-run): the spec's "2 samples/symbol" wording for this
// enb_1_2_0-valid tap was wrong -- the sel15 re-run's own push-counter data (same NF/config)
// shows the counter advancing +1 exactly every 4th captured record (332915/1331659 = 0.250),
// matching the sample-domain golden streams at 49,332 = 4x12,333 records/frame: these
// enb_1_2_0-gated taps capture FOUR records per symbol, not two. One underflow pulse per symbol
// at 4 records/symbol therefore averages 0.25, not 0.5. Target is 0.25+/-0.03.
static bool sel13A(const Run& R){
    unsigned n=R.r.size(); if(!n) return pr("sel13 countReg not constant", false, "no records");
    std::map<unsigned,unsigned> h; unsigned ufSum=0;
    for(auto& x:R.r){ unsigned cr=(unsigned short)x.i & 0x7FF; h[cr]++; if(((unsigned short)x.i>>15)&1) ufSum++; }
    char d1[48]; snprintf(d1,sizeof d1,"distinct=%zu",h.size());
    bool ok1=pr("sel13 countReg not constant",h.size()>1,d1);
    double ufMean=(double)ufSum/n;
    char d2[64]; snprintf(d2,sizeof d2,"underflow mean=%.3f (want 0.25+/-0.03)",ufMean);
    bool ok2=pr("sel13 underflow bit mean ~0.25 (4 records/symbol)", ufMean>0.22 && ufMean<0.28, d2);
    return ok1 && ok2;
}

// sel15: FIFO push counter (I[7:3]) liveness and RhCtr (I[15:8]) range (spec sec 4 sel15 row,
// corrected 2026-09-02 -- see the RHCTR_REG history comment in runPartB()). The push counter is
// a genuinely live, forceable 5-bit FIFO occupancy counter; "advances" is gated on non-constancy
// (the modulo-32 +1 cadence is reported as context, not separately gated, since captured beats
// for sel15 are enb_1_2_0-gated and need not land on every push). RhCtr is architecturally a
// BfGridPace grid-pacer value bounded to 0..3 at this driver's fixctl=0 baseline -- "cycles
// within 0..3" is gated on (a) every observed value in range and (b) more than one distinct
// value seen (i.e. it genuinely cycles rather than sitting stuck at one value).
static bool sel15A(const Run& R){
    unsigned n=R.r.size(); if(!n) return pr("sel15 push counter advances", false, "no records");
    std::map<unsigned,unsigned> pushh, rhh; unsigned incOk=0, incN=0; int prevPush=-1;
    for(auto& x:R.r){ unsigned push=((unsigned short)x.i>>3)&0x1F; unsigned rh=((unsigned short)x.i>>8)&0xFF;
        pushh[push]++; rhh[rh]++;
        if(prevPush>=0){ incN++; if(((push + 32u - (unsigned)prevPush)%32u)==1u) incOk++; }
        prevPush=(int)push; }
    char d1[80]; snprintf(d1,sizeof d1,"distinct=%zu (+1 mod32 beat-to-beat=%u/%u, context only)",pushh.size(),incOk,incN);
    bool ok1=pr("sel15 push counter advances (not constant)",pushh.size()>1,d1);
    bool rhInRange=true; for(auto&kv:rhh) if(kv.first>3) rhInRange=false;
    unsigned rhMax=0; for(auto&kv:rhh) if(kv.first>rhMax) rhMax=kv.first;
    char d2[64]; snprintf(d2,sizeof d2,"distinct=%zu maxval=%u",rhh.size(),rhMax);
    bool ok2=pr("sel15 RhCtr cycles within 0..3",rhInRange && rhh.size()>1,d2);
    return ok1 && ok2;
}

// selFilter empty = run the full 0-15 (minus dead sel7) sweep; otherwise run only the listed
// selectors (used for the sel12-only and, per the 2026-09-02 review fix round, sel13/sel15-only
// re-verify runs, without paying for a full PART A sweep).
static bool runPartA(int NF, const std::vector<int>& selFilter={}){
    bool all=true;
    auto nof=[](Vwrap_byte_ddrcap*, long, unsigned){};
    printf("=== PART A: liveness / markers / slots / toff / tref (NF=%d%s) ===\n",NF, selFilter.empty()?"":" sel filter");
    for(unsigned sel=0; sel<16; sel++){ if(sel==7) continue;   // 7 is the only dead selector; 9-11 (bit-domain) run per the controller ruling
        if(!selFilter.empty() && std::find(selFilter.begin(),selFilter.end(),(int)sel)==selFilter.end()) continue;
        Run R=run(sel,NF,nullptr,20,nof); all&=partA(sel,R);
        if(sel==12) all&=peakA(R);
        else if(sel==13) all&=sel13A(R);
        else if(sel==15) all&=sel15A(R); }
    printf("DDRCAP2_GATE_A %s\n", all?"PASS":"FAIL");
    return all;
}

static bool runPartC(int NF){
    bool all=true;
    auto nof=[](Vwrap_byte_ddrcap*, long, unsigned){};
    printf("=== PART C: sel14 differs golden vs perturbed TX words ===\n");
    { auto g=words("tx_words_golden.hex"), p=words("tx_words_perturbed.hex");
      Run A=run(14,NF,&g,20,nof), B=run(14,NF,&p,20,nof); unsigned diff=0, n=std::min(A.r.size(),B.r.size());
      for(unsigned k=0;k<n;k++) if(A.r[k].i!=B.r[k].i||A.r[k].q!=B.r[k].q) diff++;
      char d[64]; snprintf(d,sizeof d,"diff=%u/%u",diff,n); all&=pr("sel14 golden vs perturbed differ",diff>n/50,d); }
    printf("DDRCAP2_GATE_C %s\n", all?"PASS":"FAIL");
    return all;
}


// mode "D": diagnostic dump of sel12 (correlator magnitude) records for frames 25..35, one
// line per captured record: record_index frame mag_hex mag_dec. Added 2026-09-02 to investigate
// the PART A "one dominant peak per frame" FAIL (peaks>half-max=343 over frames=26, i.e. ~13.2
// records/frame above half-max) -- diagnosis, not a threshold loosening.
static void runPartD(int NF){
    auto nof=[](Vwrap_byte_ddrcap*, long, unsigned){};
    Run R = run(12, NF, nullptr, 20, nof);
    FILE* f = fopen("beat_runs/ddrcap2_sel12_mag.txt", "w");
    fprintf(f, "# record_index frame mag_hex mag_dec\n");
    for(unsigned k=0;k<R.r.size();k++){
        if(R.frame_of[k] < 25 || R.frame_of[k] > 35) continue;
        unsigned mag = ((unsigned)(unsigned short)R.r[k].i<<16) | (unsigned short)R.r[k].q;
        fprintf(f, "%u %u 0x%08X %u\n", k, R.frame_of[k], mag, mag);
    }
    fclose(f);
    printf("DDRCAP2_GATE_D wrote beat_runs/ddrcap2_sel12_mag.txt (%zu records total, frames 25-35 filtered)\n", R.r.size());
}

#ifdef DDRCAP2_FLAT
static bool runPartB(int NF){
    bool all=true;
    printf("=== PART B: forced non-null per field (flat build, NF=%d) ===\n",NF);
    // chan: 2 = ch2[13:0], 3 = ch3 side at slot, 0 = I, 1 = Q
    // hold the force for the first 128 clks after cnt_frame_start reaches 10 (frame edges are not
    // CPF-aligned); readback window is frames 10..11 (moved from 30/30..31 per the runtime
    // controller ruling so PART B fits in NF=8 instead of NF=34).
    // hold() takes an external `st` (shared_ptr<long>) so the caller can read the force-start clk
    // back out after run() completes, to build the exact [st,st+128) window checkK() needs
    // (2026-09-02 review fix: the check used to search the WHOLE run for the expected value
    // "anywhere", which any free-running counter satisfies once per period regardless of any
    // force -- not falsifiable. checkK()/maxConsecMatch() require K CONSECUTIVE matches inside
    // this exact hold window instead).
    auto hold=[&](std::shared_ptr<long> st, auto setter){ return [=](Vwrap_byte_ddrcap* t, long clk, unsigned f){ if(f==10 && *st<0) *st=clk; if(*st>=0 && clk<*st+128) setter(t); }; };
    // K=8 consecutive captured beats for per-beat fields (chan 0/1/2); K=3 consecutive
    // OCCURRENCES of the target slot for sidecar fields (chan 3) -- see checkK()'s comment.
    { auto st=std::make_shared<long>(-1);
      Run R=run(6,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1)=0x2ABC; }));
      all&=checkK("force timingOffset=0x2ABC -> ch2[13:0]",R,2,0x2ABC,-1,*st,130,8); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(6,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous1_out1)=0x12345; }));
      all&=checkK("force heldTs=0x12345 -> slot0 = 0x2345",R,3,0x2345,0,*st,130,3); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(6,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1)=0x1234; }));
      all&=checkK("force tref=0x1234 -> slot1",R,3,0x1234,1,*st,130,3); }
    { // NEGATIVE CONTROL (2026-09-02 review): tref is a free-running mod-12333 counter -- with NO
      // force at all it passes through 0x1234 once every frame, which the OLD "anywhere in the
      // readback window" check could not tell apart from a real force. Run sel6 with no force and
      // verify the SAME checkK() (K=3 consecutive slot-1 occurrences) correctly fails: a
      // free-running counter hits the target for exactly 1 frame, never 3 in a row.
      Run R=run(6,NF,nullptr,6,[](Vwrap_byte_ddrcap*, long, unsigned){});
      all&=checkExpectFail("tref no-force (falsifiability control)",R,3,0x1234,1,3); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(6,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Resettable_Synchronous_out1)=0x2AAC0000u; }));
      all&=checkK("force runMax=0x2AAC0000 -> slot2 = 0x0AAB",R,3,0x0AAB,2,*st,130,3); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(6,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay5_out1)=0x15540000u; }));
      all&=checkK("force threshold=0x15540000 -> slot3 = 0x0555",R,3,0x0555,3,*st,130,3); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(12,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay2_out1)=0x01234567u; }));
      all&=checkK("force corr=0x01234567 -> sel12 I=0x0123",R,0,0x0123,-1,*st,130,8);
      all&=checkK("... sel12 Q=0x4567",R,1,0x4567,-1,*st,130,8); }
    { auto st=std::make_shared<long>(-1);
      Run R=run(13,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg)=0x155; }));
      all&=checkK("force muReg=0x155 -> sel13 Q",R,1,0x0155,-1,*st,130,8); }
    // RHCTR_REG history (2026-09-02), full root cause: (1) first tried
    // u_Rate_Handle__DOT__beatobsRhCtr, a continuous `assign beatobsRhCtr = y;`
    // (Rate_Handle.v:139) re-driven from y every eval -- a force on it never sticks (FAIL).
    // (2) Retargeted one level deeper at BfGridPace's `a` (the FF behind y_1's a_temp path) --
    // STILL FAILED, because BfGridPace.v's `always @(a, c, en_1)` selects `y_1 = en_1 ? a_temp :
    // {6'b0, c}`, and en_1 is a registered copy of `en` = Symbol_Synchronizer's bfGridEn, which
    // traces to QPSK_Rx.v's FixCtlDec(.ctl(fixctl)) output enGridPace -- and this driver always
    // runs with fixctl=0 (init()), so en_1 is permanently 0 and y_1 ALWAYS takes the {6'b0,c}
    // branch. The "RhCtr" byte at fixctl=0 is really BfGridPace's beat-fix grid pacer output
    // (c, Rate_Handle's 2-bit mod-4 HDL_Counter, values 0..3) -- NOT FIFO occupancy as the
    // original spec wording assumed, and `a` is architecturally unreachable in this
    // configuration. sel15's genuinely forceable, positively-controlled witness fields are the
    // FIFO push/pop counters instead (u_FIFO__DOT__Push_Counter_out1 / Pop_Counter_out1, packed
    // into I[7:3]/Q[15:11]) -- RHCTR_REG now points at the push counter.
    { auto st=std::make_shared<long>(-1);
      Run R=run(15,NF,nullptr,6,hold(st,[](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,RHCTR_REG)=0x15; }));
      all&=checkK("force Rate_Handle FIFO push=0x15 -> sel15 I[7:3]",R,0,0x15<<3,-1,*st,130,8,0x00F8); }
    { // NEGATIVE CONTROL (2026-09-02 review): the FIFO push counter is a free-running mod-32
      // counter -- with NO force it passes through 0x15 once every 32 pushes, indistinguishable
      // from a real force under the OLD "anywhere" check. Run sel15 with no force and verify
      // checkExpectFail() (K=8 consecutive beats) correctly fails.
      Run R=run(15,NF,nullptr,6,[](Vwrap_byte_ddrcap*, long, unsigned){});
      all&=checkExpectFail("FIFO push no-force (falsifiability control)",R,0,0x15<<3,-1,8,0x00F8); }
    printf("DDRCAP2_GATE_B %s\n", all?"PASS":"FAIL");
    return all;
}
#endif

int main(int argc, char** argv){
    setvbuf(stdout, nullptr, _IOLBF, 0); // line-buffer so beat_runs/ddrcap2_gate_*.log show progress live under systemd-run
    const char* mode = argc>1 ? argv[1] : "all";
    int NF = argc>2 ? atoi(argv[2]) : 20;
    // argv[3], mode "A" only: comma-separated selector list to run instead of the full 0-15
    // sweep (e.g. "12" or "13,15") -- used for targeted re-verify runs without paying for a full
    // PART A sweep.
    std::vector<int> selFilter;
    if(argc>3 && !strcmp(mode,"A")){
        char buf[64]; snprintf(buf,sizeof buf,"%s",argv[3]);
        for(char* tok=strtok(buf,","); tok; tok=strtok(nullptr,",")) selFilter.push_back(atoi(tok));
    }
    bool all=true; bool ran=false;
    if(!strcmp(mode,"D")){ runPartD(NF); return 0; } // diagnostic dump, not a gate check
    if(!strcmp(mode,"A") || !strcmp(mode,"all")){ all&=runPartA(NF, selFilter); ran=true; }
#ifdef DDRCAP2_FLAT
    if(!strcmp(mode,"B") || !strcmp(mode,"all")){ all&=runPartB(NF); ran=true; }
#else
    if(!strcmp(mode,"B")){ fprintf(stderr,"PART B requires the flat (--public-flat-rw) build\n"); return 2; }
#endif
    if(!strcmp(mode,"C") || !strcmp(mode,"all")){ all&=runPartC(NF); ran=true; }
    if(!ran){ fprintf(stderr,"unknown MODE '%s' (want A|B|C|D|all)\n", mode); return 2; }
    if(!strcmp(mode,"all")) printf("DDRCAP2_GATE %s\n", all?"PASS":"FAIL");
    return all?0:1;
}
