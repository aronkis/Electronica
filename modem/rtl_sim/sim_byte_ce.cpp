// sim_byte_ce.cpp -- Model-1 ENABLE-INJECT positive control driver.
// Drives the TxRxComposite from its IN-FABRIC BIST ROM loopback source
// (rx_input_select=0, tx_data_source=0 -- NO ADC IQ), runs to steady lock,
// then injects an enable-phase disturbance one of three ways and logs a
// PER-FRAME CSV of cap_in / cap_out / cadence so the "holds constant-wrong"
// (repro) vs "heals in ~1 frame" (fix) signatures are directly visible.
//
// argv: sim_byte_ce <nclk> <out_prefix> [inject...]
//   inject (one of):
//     --flip-count2  CLK   XOR TxRxComposite_tc.count2 at clock CLK (phase swap
//                          with a 1-cycle double-enable transient)
//     --flip-serctr  CLK   XOR QPSK Serializer HDL_Counter_out1 at clock CLK
//                          (LOCAL demapper coded-bit-order swap)
//     --drop-ce      CLK   hold clk_enable=0 for exactly clock CLK (glitch-free
//                          global enable-phase swap: the literal root-cause event)
//   (no inject arg -> Gate-0 clean run: prove loopback reaches golden)
// Per-frame CSV <prefix>_frames.csv columns:
//   frame_idx,clk,cnt_frame_start,cap_in,cap_out,bit_errors_out,golden
//     golden = 1 iff cap_in==0x5216F3E2 && cap_out==0x04922282
#include "Vwrap_byte_ce.h"
#ifdef HAVE_FLAT_RW
#include "Vwrap_byte_ce___024root.h"
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <utility>

static const unsigned CAP_OUT_GOLD = 0x04922282u;
static const unsigned CAP_IN_GOLD  = 0x5216F3E2u;

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 3){
        fprintf(stderr,"usage: sim_byte_ce nclk out_prefix "
                "[--flip-count2 CLK | --flip-serctr CLK | --drop-ce CLK]\n");
        return 2;
    }
    long nclk = atol(argv[1]);
    const char* pfx = argv[2];
    long flipCount2=-1, flipSerctr=-1, dropCe=-1;
    long dropSymval=-1; int dropSymvalN=1;   // --drop-symval CLK [N]: MODEL-3
    long rotNco=-1;    int rotNcoQ=1;        // --rot-nco CLK Q : MODEL-4 carrier DDS phase +Q*90deg
    long rotAvgest=-1; int rotAvgestQ=1;     // --rot-avgest CLK Q : MODEL-4 rotate held ambiguity latch
    long pokeMu=-1; long pokeMuVal=0;        // --poke-mu CLK VAL : MODEL-4 interp mu/timing state
    std::vector<std::pair<long,int>> setRhctrs; // --set-rhctr CLK V (repeatable) : MODEL-6 Rate_Handle mod-4 pop pacer
    long shiftMarkerFrom=-1; int shiftMarkerK=0; // --shift-marker CLK K : MODEL-7 persistent marker displacement (K beats)
    std::vector<std::pair<long,unsigned>> fixctlWr; // --fixctl CLK VAL (repeatable) : BEATFIX2 control writes
    std::vector<std::pair<long,int>> stepPops; // --step-pop CLK K (repeatable) : MODEL-6 FIFO pop-pointer step
    long dropAdcValid=-1, insAdcValid=-1;
    long delayValid=-1; int delayValidN=1;   // --delay-valid CLK N : MODEL-5 mid-run train delay
    long dbg1S=-1, dbg1E=-1; const char* dbg1F=nullptr; // --dbg1dump S E FILE : per-clk dbg1I hex dump
    int  vphase0=0;                          // --vphase P : initial valid-train phase from reset
    int  dropN=1;                   // --drop-adcvalid CLK [N]: N consecutive valid-slots
    long perStart=-1, perStride=0, perCount=0;  // --drop-periodic START STRIDE COUNT
    int  adcLoop=0, adcCadence=2;   // --adc-loopback [CADENCE]: route TX->adc port
    for(int a=3;a<argc;){
        if(!strcmp(argv[a],"--flip-count2") && a+1<argc){ flipCount2=atol(argv[a+1]); a+=2; }
        else if(!strcmp(argv[a],"--flip-serctr") && a+1<argc){ flipSerctr=atol(argv[a+1]); a+=2; }
        else if(!strcmp(argv[a],"--drop-symval") && a+1<argc){ dropSymval=atol(argv[a+1]);
            if(a+2<argc && argv[a+2][0]!='-'){ dropSymvalN=atoi(argv[a+2]); a+=3; } else a+=2; }
        else if(!strcmp(argv[a],"--rot-nco") && a+2<argc){ rotNco=atol(argv[a+1]); rotNcoQ=atoi(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--rot-avgest") && a+2<argc){ rotAvgest=atol(argv[a+1]); rotAvgestQ=atoi(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--poke-mu") && a+2<argc){ pokeMu=atol(argv[a+1]); pokeMuVal=strtol(argv[a+2],nullptr,0); a+=3; }
        else if(!strcmp(argv[a],"--set-rhctr") && a+2<argc){ setRhctrs.push_back({atol(argv[a+1]),atoi(argv[a+2])}); a+=3; }
        else if(!strcmp(argv[a],"--step-pop") && a+2<argc){ stepPops.push_back({atol(argv[a+1]),atoi(argv[a+2])}); a+=3; }
        else if(!strcmp(argv[a],"--shift-marker") && a+2<argc){ shiftMarkerFrom=atol(argv[a+1]); shiftMarkerK=atoi(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--fixctl") && a+2<argc){ fixctlWr.push_back({atol(argv[a+1]),(unsigned)strtoul(argv[a+2],nullptr,0)}); a+=3; }
        else if(!strcmp(argv[a],"--drop-ce") && a+1<argc){ dropCe=atol(argv[a+1]); a+=2; }
        else if(!strcmp(argv[a],"--adc-loopback")){ adcLoop=1;
            if(a+1<argc && argv[a+1][0]!='-'){ adcCadence=atoi(argv[a+1]); a+=2; } else a+=1; }
        else if(!strcmp(argv[a],"--drop-adcvalid") && a+1<argc){ dropAdcValid=atol(argv[a+1]);
            if(a+2<argc && argv[a+2][0]!='-'){ dropN=atoi(argv[a+2]); a+=3; } else a+=2; }
        else if(!strcmp(argv[a],"--ins-adcvalid") && a+1<argc){ insAdcValid=atol(argv[a+1]); a+=2; }
        else if(!strcmp(argv[a],"--delay-valid") && a+2<argc){ delayValid=atol(argv[a+1]); delayValidN=atoi(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--dbg1dump") && a+3<argc){ dbg1S=atol(argv[a+1]); dbg1E=atol(argv[a+2]); dbg1F=argv[a+3]; a+=4; }
        else if(!strcmp(argv[a],"--vphase") && a+1<argc){ vphase0=atoi(argv[a+1]); a+=2; }
        else if(!strcmp(argv[a],"--drop-periodic") && a+3<argc){ perStart=atol(argv[a+1]);
            perStride=atol(argv[a+2]); perCount=atol(argv[a+3]); a+=4; }
        else { fprintf(stderr,"bad arg %s\n",argv[a]); return 2; }
    }
    if(adcCadence<1) adcCadence=1;

    char fn[512];
    snprintf(fn,sizeof fn,"%s_frames.csv",pfx);
    FILE* fc=fopen(fn,"w");
    if(!fc){ fprintf(stderr,"cannot open %s\n",fn); return 2; }
    fprintf(fc,"frame_idx,clk,cnt_frame_start,cap_in,cap_out,bit_errors_out,golden\n");

    Vwrap_byte_ce* t = new Vwrap_byte_ce;

    // static config. Default: INTERNAL ROM/BIST loopback (rx_input_select=0).
    // --adc-loopback: rx_input_select=1 and route the model's own TX pulse-shaped
    //   output back through the adc_dataIn/adc_validIn FRONT port, so adc_validIn
    //   is in the sample path and a dropped/inserted pulse is a one-tick cadence
    //   slip vs the free-running clk/2 enable grid (the physically-real trigger).
    t->reset=1; t->clk_enable=1;
    t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0;
    t->rx_input_select = adcLoop ? 1 : 0;
    t->tx_data_source=0;       // <-- in-fabric ROM/BIST frame source
    t->skip_count=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
#ifdef HAVE_BF2
    t->fixctl=0;
#endif

    // direct-poke register handles (Verilator --public-flat-rw flat root)
#ifdef HAVE_FLAT_RW
    auto* R = t->rootp;
    CData* pCount2  = &R->wrap_byte_ce__DOT__dut__DOT__u_TxRxComposite_tc__DOT__count2;
    CData* pSerctr  = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_QPSK_Demodulator__DOT__u_Serializer__DOT__HDL_Counter_out1;
    // MODEL-3: In2 to the demapper Serializer (= symbol validIn delayed). Zeroing
    // it for one symbol drops that symbol's coded-bit pair while startIn/frame
    // markers (separate Delay6 pipeline) keep flowing -> a HELD coded-bit stream
    // slip vs the frame marker (misframing the FEC input).
    CData* pSymIn2  = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_QPSK_Demodulator__DOT__Delay5_out1;
    long dropSymvalLeft = 0;
    // MODEL-4 handles:
    //  carrier DDS phase accumulator (sfix21; full circle 2^21 -> 90deg = 2^19*... = 524288)
    IData* pCsNco   = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Carrier_Synchronizer__DOT__u_Direct_Digital_Synthesis__DOT__u_NCO__DOT__accphase_reg;
    //  held phase-ambiguity resolution latch (avgEst, sfix24_En16 x2)
    IData* pAvgRe   = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Phase_Ambiguity_Estimation_and_Correction__DOT__u_Average_Estimates__DOT__Unit_Delay_Enabled_Synchronous_out1_re;
    IData* pAvgIm   = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Phase_Ambiguity_Estimation_and_Correction__DOT__u_Average_Estimates__DOT__Unit_Delay_Enabled_Synchronous_out1_im;
    //  interpolation fractional-timing state (sfix11)
    SData* pMuReg   = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg;
    // MODEL-6 handles: Rate_Handle mod-4 pop pacer + FIFO_block pointer pair
    CData* pRhCtr   = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__HDL_Counter_out1;
    // MODEL-7: demod start pipeline stage-1 reg (marker displacement injection)
    CData* pMkStage = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_QPSK_Demodulator__DOT__Delay2_out1;
    long mkSetAt=-1; long mkHoldoff=-1;
    CData* pPopCtr  = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__u_FIFO__DOT__Pop_Counter_out1;
    CData* pPushCtr = &R->wrap_byte_ce__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__u_FIFO__DOT__Push_Counter_out1;
#else
    if(flipCount2>=0 || flipSerctr>=0 || dropSymval>=0 || rotNco>=0 || rotAvgest>=0 || pokeMu>=0 || !setRhctrs.empty() || !stepPops.empty()){
        fprintf(stderr,"FATAL: register-poke legs need the HAVE_FLAT_RW build\n");
        return 4;
    }
#endif

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); };

    // reset
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // The FecCapture cap_in/cap_out registers RE-ARM (read 0) exactly at each
    // startIn/cnt_frame_start increment and only HOLD the frame's settled hash
    // partway through the frame. So we don't sample AT the frame boundary; we
    // schedule the log SETTLE_DELAY clocks after each frame start, well before
    // the next start (frame period ~98.6k clk here), when the hash is stable.
    const long SETTLE_DELAY = 70000;
    long frame_idx=0;
    unsigned prevFS=0; bool haveFS=false;
    long firstGoldClk=-1;
    long pendingLogClk=-1; unsigned pendingFS=0; long pendingStartClk=0;
    short prevTxI=0, prevTxQ=0;
    int adcPh = (adcCadence - (vphase0 % adcCadence)) % adcCadence;  // --vphase initial train phase
    long delayLeft=0;                                               // --delay-valid stall countdown
    long dropLeft=0; long perNextDrop=perStart; long perDone=0; bool perArmed=false;
    for(long clk=0; clk<nclk; clk++){
        // --- ADC-loopback front feed (route TX output back through adc port) ---
        if(adcLoop){
            t->adc_dataInI = prevTxI;
            t->adc_dataInQ = prevTxQ;
            // MODEL-5 mid-run TRAIN DELAY: at delayValid, freeze the train-phase
            // counter for N clocks (valid suppressed, phase NOT advanced). No
            // samples are lost; every subsequent valid lands N clocks later ->
            // the STANDING OFFSET between the valid train and the free-running
            // clk/2 enable grid is stepped by N and HELD (vs drop/insert, which
            // preserve the train's standing clk-parity).
            if(delayValid>=0 && clk==delayValid){
                delayLeft=delayValidN;
                fprintf(stderr,"INJECT delay valid-train +%d clk @clk %ld\n",delayValidN,clk);
                delayValid=-2;
            }
            if(delayLeft>0){
                t->adc_validIn = 0;
                delayLeft--;
                // adcPh frozen: do NOT advance the train phase this clock
                goto adc_done;
            }
            {
            int validSlot = (adcPh==0);
            // BURST drop: suppress the next dropN valid-slots from dropAdcValid on
            if(dropAdcValid>=0 && clk>=dropAdcValid && dropLeft==0 && dropAdcValid!=-2){
                dropLeft=dropN;
                fprintf(stderr,"INJECT drop %d adc_validIn slots from clk %ld\n",dropN,clk);
                dropAdcValid=-2;
            }
            if(dropLeft>0 && validSlot){ validSlot=0; dropLeft--; }
            // PERIODIC silent drop: 1 valid-slot every perStride, perCount times
            if(perStart>=0 && clk>=perNextDrop && perDone<perCount && validSlot){
                validSlot=0; perDone++; perNextDrop=clk+perStride;
                if(perDone==1||perDone==perCount)
                    fprintf(stderr,"INJECT periodic drop #%ld @clk %ld (stride %ld)\n",perDone,clk,perStride);
            }
            if(insAdcValid>=0 && clk==insAdcValid){ validSlot=1;               // INSERT a sample
                fprintf(stderr,"INJECT insert adc_validIn @clk %ld\n",clk); insAdcValid=-2; }
            t->adc_validIn = validSlot;
            adcPh = (adcPh+1)%adcCadence;
            }
            adc_done: ;
        }
        (void)perArmed;
        // --- injection at this clock, applied BEFORE eval ---
        t->clk_enable = (dropCe>=0 && clk==dropCe) ? 0 : 1;
#ifdef HAVE_FLAT_RW
        if(flipCount2>=0 && clk==flipCount2){ *pCount2 ^= 1u; t->eval();
            fprintf(stderr,"INJECT count2 flip @clk %ld\n",clk); flipCount2=-2; }
        if(flipSerctr>=0 && clk==flipSerctr){ *pSerctr ^= 1u; t->eval();
            fprintf(stderr,"INJECT serctr flip @clk %ld\n",clk); flipSerctr=-2; }
#endif
        if(dropCe>=0 && clk==dropCe) fprintf(stderr,"INJECT drop clk_enable @clk %ld\n",clk);
#ifdef HAVE_BF2
        for(auto& fw : fixctlWr){
            if(fw.first>=0 && clk==fw.first){
                t->fixctl=fw.second; t->eval();
                fprintf(stderr,"FIXCTL <= 0x%x @clk %ld (viol=%u latch=%08x)\n",
                        fw.second,clk,t->bfViol,t->bfLatch);
                fw.first=-2;
            }
        }
        if((clk % 200000)==0)
            fprintf(stderr,"  [bf2] clk=%ld viol=%u latch=%08x\n",clk,t->bfViol,t->bfLatch);
        if(clk==nclk-1)
            fprintf(stderr,"BF2: final viol=%u latch=%08x\n",t->bfViol,t->bfLatch);
#endif
#ifdef HAVE_FLAT_RW
        // MODEL-3 symbol-valid drop: zero In2 (Delay5) for the next N symbol
        // cycles (where it is 1) at/after dropSymval -- one symbol per drop.
        if(dropSymval>=0 && clk>=dropSymval && dropSymvalLeft==0 && dropSymval!=-2){
            dropSymvalLeft=dropSymvalN;
            fprintf(stderr,"INJECT drop %d demapper symbol-valids from clk %ld\n",dropSymvalN,clk);
            dropSymval=-2;
        }
        if(dropSymvalLeft>0 && *pSymIn2){ *pSymIn2=0; t->eval(); dropSymvalLeft--; }
        // MODEL-4 candidate injections (one-shot)
        if(rotNco>=0 && clk==rotNco){
            uint32_t v=*pCsNco;
            *pCsNco = (v + (uint32_t)rotNcoQ*524288u) & 0x1FFFFFu;   // +Q*90deg (2^21 circle)
            t->eval();
            fprintf(stderr,"INJECT carrier NCO phase +%d*90deg @clk %ld (accphase %05x->%05x)\n",
                    rotNcoQ,clk,v,*pCsNco); rotNco=-2;
        }
        if(rotAvgest>=0 && clk==rotAvgest){
            // rotate (re,im) by Q*90deg: 90deg: (re,im)->(-im,re); sfix24 two's complement in 24 bits
            int32_t re=(int32_t)((*pAvgRe)<<8)>>8, im=(int32_t)((*pAvgIm)<<8)>>8;
            for(int q=0;q<rotAvgestQ;q++){ int32_t nre=-im, nim=re; re=nre; im=nim; }
            uint32_t oldRe=*pAvgRe, oldIm=*pAvgIm;
            *pAvgRe=(uint32_t)re & 0xFFFFFFu; *pAvgIm=(uint32_t)im & 0xFFFFFFu;
            t->eval();
            fprintf(stderr,"INJECT avgEst rot %d*90deg @clk %ld (re %06x->%06x im %06x->%06x)\n",
                    rotAvgestQ,clk,oldRe,*pAvgRe,oldIm,*pAvgIm); rotAvgest=-2;
        }
        if(pokeMu>=0 && clk==pokeMu){
            uint16_t v=*pMuReg;
            *pMuReg=(uint16_t)pokeMuVal & 0x7FFu; t->eval();
            fprintf(stderr,"INJECT muReg %03x->%03x @clk %ld\n",v,*pMuReg,clk); pokeMu=-2;
        }
        // MODEL-6: force the Rate_Handle mod-4 pop pacer (repeatable, for the staircase)
        for(auto& sr : setRhctrs){
            if(sr.first>=0 && clk==sr.first){
                uint8_t v=*pRhCtr;
                *pRhCtr=(uint8_t)sr.second & 0x3u; t->eval();
                fprintf(stderr,"INJECT Rate_Handle HDL_Counter %d->%d @clk %ld\n",v,*pRhCtr,clk);
                sr.first=-2;
            }
        }
        // MODEL-7: persistent marker displacement -- every frame, catch the start
        // pulse in the demod start pipeline stage-1, suppress it, re-inject it K
        // enb-beats later. Data path untouched -> value-clean framing shift (the
        // silicon-confirmed fault class).
        if(shiftMarkerFrom>=0 && clk>=shiftMarkerFrom){
            static long mkClr=-1; static long mkShifted=0;
            if(mkSetAt>=0 && (clk==mkSetAt || clk==mkSetAt+1)){
                *pMkStage=1; t->eval();
                if(clk==mkSetAt+1) mkSetAt=-1;
            }
            else if(clk==mkClr && *pMkStage){ *pMkStage=0; t->eval(); mkClr=-1; }
            else if(*pMkStage && clk>mkHoldoff && mkSetAt<0){
                *pMkStage=0; t->eval();
                mkClr=clk+1; mkSetAt=clk+2L*shiftMarkerK; mkHoldoff=clk+2L*shiftMarkerK+6;
                if(mkShifted<3 || (mkShifted%50)==0)
                    fprintf(stderr,"INJECT marker shift +%d beats @clk %ld (event %ld)\n",
                            shiftMarkerK,clk,mkShifted);
                mkShifted++;
            }
        }
        // MODEL-6: step the FIFO pop pointer by K relative to push (persistent by construction)
        for(auto& sp : stepPops){
            if(sp.first>=0 && clk==sp.first){
                uint8_t v=*pPopCtr;
                *pPopCtr=(uint8_t)((v + sp.second) & 0x1Fu); t->eval();
                fprintf(stderr,"INJECT FIFO pop ptr %+d @clk %ld (pop %02x->%02x, push %02x)\n",
                        sp.second,clk,v,*pPopCtr,*pPushCtr);
                sp.first=-2;
            }
        }
#endif
        tick();
        prevTxI = (short)t->txOutI; prevTxQ = (short)t->txOutQ;
        // per-clk dbg1I dump window (golden coded-bit sequence extraction)
        if(dbg1F && clk>=dbg1S && clk<dbg1E){
            static FILE* fd=nullptr;
            if(!fd){ fd=fopen(dbg1F,"w"); if(!fd){ fprintf(stderr,"cannot open %s\n",dbg1F); return 5; } }
            fprintf(fd,"%04x\n",(uint16_t)t->dbg1I);
            if(clk==dbg1E-1){ fclose(fd); fd=nullptr; fprintf(stderr,"dbg1dump done -> %s\n",dbg1F); }
        }
#ifdef HAVE_PC
        // MODEL-7 phase-contract instrumentation (wrap_byte_pc.v builds only)
        {
            static int po=0,pd=0; static long nO=0,nD=0,sameBeat=0; static long lastO=-1,lastD=-1;
            int o=t->pcStartOrig, d=t->pcStartDrv;
            if(o&&!po){ nO++; lastO=clk; }
            if(d&&!pd){ nD++; lastD=clk;
                static int logged=0;
                // log derived pulses with no orig within the same beat (unmatched)
                if(logged<12 && !(o) && (lastO<0 || clk-lastO>4)){
                    fprintf(stderr,"PC-EXTRA derived pulse @clk %ld (lastOrig %ld)\n",clk,lastO);
                    logged++;
                }
            }
            if(o&&!po && lastD==clk) sameBeat++;
            else if(o&&!po && lastD>=0 && clk-lastD<=2) sameBeat++; // same enb beat window
            po=o; pd=d;
            if(clk==nclk-1)
                fprintf(stderr,"PC: viol=%u delta=%d nStartOrig=%ld nStartDrv=%ld sameBeat=%ld lastO=%ld lastD=%ld\n",
                        t->pcViol,(short)t->pcDelta,nO,nD,sameBeat,lastO,lastD);
        }
#endif
        // debugI1/Q1 liveness probe (BEATOBS overlay packed state vector):
        // count bit0 toggles and distinct bits[6:5] values seen (post-lock)
        {
            static uint16_t d1p=0; static long d1tog=0; static int rhSeen=0; static bool d1i=false;
            uint16_t d1=(uint16_t)t->dbg1I;
            if(d1i && ((d1^d1p)&1u)) d1tog++;
            rhSeen |= 1<<((d1>>5)&3u);
            d1p=d1; d1i=true;
            if(clk==nclk-1)
                fprintf(stderr,"DBG1: dbg1I=%04x dbg1Q=%04x bit0_toggles=%ld rh_bits65_seen=%x\n",
                        d1,(uint16_t)t->dbg1Q,d1tog,rhSeen);
        }
        if((clk % 200000)==0)
            fprintf(stderr,"  [progress] clk=%ld fs=%u cap_in=%08x cap_out=%08x pkts=%u\n",
                    clk,t->cnt_frame_start,t->cap_in,t->cap_out,t->packets_out);

        unsigned fs = t->cnt_frame_start;
        if(!haveFS){ prevFS=fs; haveFS=true; }
        if(fs != prevFS){
            // schedule a settled sample for this new frame
            pendingLogClk = clk + SETTLE_DELAY;
            pendingFS = fs; pendingStartClk = clk;
            prevFS = fs;
        }
        if(pendingLogClk>=0 && clk==pendingLogClk){
            unsigned ci=t->cap_in, co=t->cap_out, be=t->bit_errors_out;
            int gold = (ci==CAP_IN_GOLD && co==CAP_OUT_GOLD) ? 1 : 0;
            if(gold && firstGoldClk<0) firstGoldClk=pendingStartClk;
            fprintf(fc,"%ld,%ld,%u,%08x,%08x,%u,%d\n",
                    frame_idx,pendingStartClk,pendingFS,ci,co,be,gold);
            frame_idx++;
            pendingLogClk=-1;
        }
    }
    fclose(fc);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx);
    FILE* fo=fopen(fn,"w");
    fprintf(fo,"nclk=%ld frames=%ld firstGoldClk=%ld\n",nclk,frame_idx,firstGoldClk);
    fprintf(fo,"cap_in_final=%08x cap_out_final=%08x cnt_frame_start=%u bit_errors=%u packets=%u\n",
            t->cap_in,t->cap_out,t->cnt_frame_start,t->bit_errors_out,t->packets_out);
    fprintf(fo,"golden_ref: cap_in=%08x cap_out=%08x\n",CAP_IN_GOLD,CAP_OUT_GOLD);
    fclose(fo);
    printf("CE nclk=%ld frames=%ld cap_in=%08x cap_out=%08x fs=%u biterr=%u firstGold@%ld\n",
           nclk,frame_idx,t->cap_in,t->cap_out,t->cnt_frame_start,t->bit_errors_out,firstGoldClk);
    delete t;
    return 0;
}
