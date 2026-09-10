// txrate_probe.cpp -- TX_RATE_E: find the NATURAL trigger of the Data_Bits_FIFO pop-abort
// and its period.  Host-only, no board.  Built against s1_rtl_txmark by build_txrate_sim.sh.
//
// Hypothesis under test (see TX_RATE_E.md, tag archive/pre-cleanup-2026-09-09):
//   RAM_Frame_Status_Indicator.v:66-92 keeps frameCount = (#pushCount wraps) - (#popCount wraps)
//   in an UNGUARDED ufix2.  Per air frame the producer pushes 24,666 bits (50% duty of 49,332
//   enb_1_2_0 ticks, Bit_Packetizer.v:150-176 dataReady toggle) but only 24,640 are popped
//   (Data_Bits_FIFO.v:222,291 pop window slots 26..24665).  pushCount therefore wraps
//   24,666/24,640 = 1.001055 times per frame and popCount exactly once, so every
//   24,640/26 = 947.69 frames there is ONE EXTRA push wrap and the frameCount base ratchets +1.
//   Base walks 1 -> 2 -> 3 -> 0; when the base is 3 the extra push wrap makes frameCount read 0
//   mid-frame (at the push-wrap position), Data_Bits_FIFO.v:270-289 clears `armed` and pops stop.
//
// sel:
//   census   -- instrument only.  Per-frame census: occ, frameCount, pushCount, popCount,
//               pushes/frame, pops/frame, fullRAM, bit-packetizer pace toggle.  No force.
//   nfprobe  -- force MATLAB_Function1.count near the 49279 fullRAM threshold at frame K and
//               then COUNT pushes and pops per frame, to settle whether fullRAM actually
//               throttles the producer (nf_v0 suggested it does not).
//   fcbase3  -- single-tick force of RAM_Frame_Status_Indicator.frameCount = 3 taken ONLY in the
//               LOW window (pre must read 1; the run aborts loudly otherwise).  This sets the
//               base to 3 -- the state the natural 947-frame drift reaches on its own -- and then
//               NOTHING is forced: the next natural push wrap must do 3->0 by itself.
//   fcbase2  -- negative control: identical, but force 2 (base 2, pair 2<->3, zero unreachable).
//   phase2   -- no frameCount force at all.  Two single-tick forces of FSI.pushCount only (the
//               PRODUCER PHASE), at frames K and K+2, each placing the push wrap a few pushes
//               ahead so an extra push wrap occurs -- exactly what the 26 slot/frame drift does
//               every 947.69 frames, done twice.  Base walks 1->2->3 and the third (natural)
//               push wrap drives 3->0 with no force at the abort instant.
//
// argv: NF K sel out_prefix [arg=0] [SEL=6] [OUT.bin]
#include "Vwrap_byte_ddrcap.h"
#include "Vwrap_byte_ddrcap___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#define TFS wrap_byte_ddrcap__DOT__dut__DOT__
#define BP  wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__u_Bit_Packetizer__DOT__
#define DBF wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__u_Bit_Packetizer__DOT__u_Data_Bits_FIFO__DOT__
#define FSI wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__u_Bit_Packetizer__DOT__u_Data_Bits_FIFO__DOT__u_RAM_Frame_Status_Indicator__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)

static const long FRAME_CLK = 98664;   // harness clk per air frame (measured, = 49332 enb ticks)

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: txrate_probe NF K sel out_prefix [arg] [SEL] [OUT.bin]\n"); return 2; }
    int NF=atoi(argv[1]), K=atoi(argv[2]); std::string sel=argv[3]; const char* pfx=argv[4];
    long ARG = (argc>5)? atol(argv[5]) : 0;
    unsigned SEL = (argc>6)? (unsigned)strtoul(argv[6],nullptr,0) : 6u;
    char outbuf[512]; const char* outpath;
    if(argc>7) outpath=argv[7]; else { snprintf(outbuf,sizeof outbuf,"%s.bin",pfx); outpath=outbuf; }
    char fn[512]; snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    setvbuf(ff,nullptr,_IOLBF,0); setvbuf(stdout,nullptr,_IOLBF,0);
    bool wantBin = (sel!="census");

    Vwrap_byte_ddrcap* t=new Vwrap_byte_ddrcap; auto* R=t->rootp;
    long clk=0; t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0; t->fixctl=0;
    t->iq_debug_mux = ((SEL & 0xFu) << 16) | 3u;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    long txFrameIdx=-1; long prevSC=-1; long frameStartClk=0;
    long prevPushCnt=-1, prevPopCnt=-1; long pushesThisFrame=0, popsThisFrame=0;
    long prevFC=-1, prevArmed=-1;
    long pushWrapClk=-1, popWrapClk=-1;      // last wrap positions, clk within frame
    long zeroEvents=0, firstZeroClk=-1, firstZeroFrame=-1;
    long armedDropClk=-1; long popQuietRun=0, popQuietMax=0; long popsLostTotal=0;
    int  forced=0, armedFrameSeen=0; long forcePre=-1;
    int  phaseStage=0;                        // phase2: 0,1 -> two pushCount forces
    long lastPushWrapAbs=0, lastPopWrapAbs=0;

    auto tick=[&](){
        t->clk=0; t->eval();
        long sc  = (long)R->CAT(DBF,HDL_Counter2_out1);
        long fc  = (long)R->CAT(FSI,frameCount);
        long d3  = (long)R->CAT(DBF,Delay3_out1);
        long pu  = (long)R->CAT(FSI,pushCount);
        long po  = (long)R->CAT(FSI,popCount);
        long arm = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
        long pop = (long)R->CAT(DBF,Logical_Operator_out1);

        if(prevPushCnt>=0){
            if(pu!=prevPushCnt){ pushesThisFrame++; if(pu==0){ pushWrapClk=clk; lastPushWrapAbs++; } }
            if(po!=prevPopCnt){ popsThisFrame++;  if(po==0){ popWrapClk=clk;  lastPopWrapAbs++; } }
        }
        prevPushCnt=pu; prevPopCnt=po;

        if(prevSC>=0 && sc < prevSC-1000){    // air-frame wrap
            if(txFrameIdx>=0){
                long occ  = (long)R->CAT(DBF,u_MATLAB_Function1__DOT__count);
                long full = (long)R->CAT(DBF,Delay7_out1);
                long pace = (long)R->CAT(BP,HDL_Counter_out1);
                fprintf(ff,"CEN frame=%ld clk=%ld occ=%ld fc=%ld pushCount=%ld popCount=%ld "
                           "pushes=%ld pops=%ld fullRAM=%ld pace=%ld armed=%ld "
                           "pushWrapPos=%ld popWrapPos=%ld pushWraps=%ld popWraps=%ld\n",
                    txFrameIdx, clk, occ, fc, pu, po, pushesThisFrame, popsThisFrame, full, pace, arm,
                    pushWrapClk<0?-1:(pushWrapClk-frameStartClk), popWrapClk<0?-1:(popWrapClk-frameStartClk),
                    lastPushWrapAbs, lastPopWrapAbs);
            }
            txFrameIdx++; frameStartClk=clk; pushesThisFrame=0; popsThisFrame=0;
            pushWrapClk=-1; popWrapClk=-1;
            if(txFrameIdx==K && !armedFrameSeen) armedFrameSeen=1;
        }
        prevSC=sc;

        if(prevFC>=0 && fc!=prevFC){
            if(fc==0){
                zeroEvents++;
                if(firstZeroClk<0){ firstZeroClk=clk; firstZeroFrame=txFrameIdx; }
                fprintf(ff,"ZERO clk=%ld frame=%ld posInFrame=%ld sampleCount=%ld prevFC=%ld "
                           "pushCount=%ld popCount=%ld via=%s\n",
                    clk, txFrameIdx, clk-frameStartClk, sc, prevFC, pu, po,
                    (prevFC==3)?"PUSHWRAP_3to0":((prevFC==1)?"POPWRAP_1to0":"OTHER"));
            } else if(zeroEvents>0 || sel!="census"){
                fprintf(ff,"FC clk=%ld frame=%ld posInFrame=%ld %ld -> %ld\n", clk, txFrameIdx, clk-frameStartClk, prevFC, fc);
            }
        }
        prevFC=fc;
        if(prevArmed>=0 && arm!=prevArmed){
            fprintf(ff,"ARMED clk=%ld frame=%ld posInFrame=%ld sampleCount=%ld %ld -> %ld fc=%ld d3=%ld\n",
                clk, txFrameIdx, clk-frameStartClk, sc, prevArmed, arm, fc, d3);
            if(arm==0 && armedDropClk<0) armedDropClk=clk;
        }
        prevArmed=arm;
        if(armedDropClk>=0){ if(pop==0) popQuietRun++; else { if(popQuietRun>popQuietMax) popQuietMax=popQuietRun; popQuietRun=0; } }

        t->clk=1; t->eval();
        clk++;
    };

    for(int i=0;i<100;i++) tick(); t->reset=0;
    txFrameIdx=0; prevSC=-1; prevFC=-1; prevArmed=-1; prevPushCnt=-1; prevPopCnt=-1;
    lastPushWrapAbs=0; lastPopWrapAbs=0;

    FILE* fb = wantBin? fopen(outpath,"wb") : nullptr;
    long total = 100 + (long)(NF+4)*FRAME_CLK;

    while(clk<total){
        t->adc_validIn=(clk&1)?0:1;

        if(armedFrameSeen && !forced){
            if(sel=="nfprobe"){
                forcePre=(long)R->CAT(DBF,u_MATLAB_Function1__DOT__count);
                R->CAT(DBF,u_MATLAB_Function1__DOT__count) = (unsigned)(49279-52);
                forced=1;
                fprintf(ff,"# FORCE nfprobe clk=%ld frame=%ld count %ld -> %d\n",clk,txFrameIdx,forcePre,49279-52);
            } else if(sel=="fcbase3" || sel=="fcbase2"){
                long fc=(long)R->CAT(FSI,frameCount);
                long sc=(long)R->CAT(DBF,HDL_Counter2_out1);
                // LOW window only: frameCount must read 1 and we must be well clear of both wraps
                if(sc>4000 && sc<20000){
                    if(fc!=1){
                        fprintf(ff,"# FORCE ABORTED: expected pre frameCount==1 in the low window, read %ld at sampleCount=%ld\n",fc,sc);
                        fprintf(stdout,"TXRATE_FORCE_ABORT pre_fc=%ld\n",fc); fclose(ff); if(fb)fclose(fb); return 3;
                    }
                    long v = (sel=="fcbase3")?3:2;
                    R->CAT(FSI,frameCount) = (unsigned)v;   // single write, never repeated
                    forcePre=fc; forced=1;
                    fprintf(ff,"# FORCE %s clk=%ld frame=%ld sampleCount=%ld frameCount %ld -> %ld (single tick, nothing else forced)\n",
                        sel.c_str(),clk,txFrameIdx,sc,fc,v);
                }
            } else if(sel=="phase2"){
                // Add ONE EXTRA push wrap inside a frame that has already had its natural one --
                // exactly what the +26 slot/frame drift does on its own every 947.69 frames.
                // Only FSI.pushCount (the producer phase) is written; frameCount is never touched.
                if(pushWrapClk>=0 && clk>pushWrapClk+16){
                    long pu=(long)R->CAT(FSI,pushCount);
                    R->CAT(FSI,pushCount) = 24639;
                    fprintf(ff,"# FORCE phase2 stage=%d clk=%ld frame=%ld sampleCount=%ld pushCount %ld -> 24639 (extra wrap in a frame that already wrapped at posInFrame=%ld) fc=%ld\n",
                        phaseStage,clk,txFrameIdx,(long)R->CAT(DBF,HDL_Counter2_out1),pu,pushWrapClk-frameStartClk,(long)R->CAT(FSI,frameCount));
                    phaseStage++;
                    if(phaseStage>=2) forced=1; else { armedFrameSeen=0; K=K+2; }
                }
            } else if(sel=="census"){ forced=1; }
        }
        if(sel=="phase2" && !forced && txFrameIdx==K) armedFrameSeen=1;

        tick();
        if(fb && t->ddrcap_valid){
            short r[4]={(short)t->ddrcap_i,(short)t->ddrcap_q,(short)t->ddrcap_mark_demod,(short)t->ddrcap_mark_fec};
            fwrite(r,sizeof r,1,fb);
        }
    }
    if(popQuietRun>popQuietMax) popQuietMax=popQuietRun;
    fprintf(ff,"# SUMMARY sel=%s K=%d NF=%d zeroEvents=%ld firstZeroClk=%ld firstZeroFrame=%ld "
               "armedDropClk=%ld maxPopQuietClk=%ld pushWrapsTotal=%ld popWrapsTotal=%ld framesRun=%ld\n",
        sel.c_str(),K,NF,zeroEvents,firstZeroClk,firstZeroFrame,armedDropClk,popQuietMax,lastPushWrapAbs,lastPopWrapAbs,txFrameIdx);
    fclose(ff); if(fb) fclose(fb);
    printf("TXRATE sel=%s NF=%d K=%d zeroEvents=%ld firstZeroFrame=%ld armedDropClk=%ld maxPopQuiet=%ld packets=%u biterr=%u frames=%ld\n",
        sel.c_str(),NF,K,zeroEvents,firstZeroFrame,armedDropClk,popQuietMax,t->packets_out,t->bit_errors_out,txFrameIdx);
    delete t; return 0;
}
