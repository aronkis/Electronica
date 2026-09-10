// sim_txfix_force.cpp -- TXFIX gate harness (2026-09-03, T0a).  Verbatim copy of
// sim_burst_force_tx.cpp (which is left untouched so every earlier result stays
// reproducible) plus exactly two additions:
//
//   (1) a `popabort READBACK` line -- on the force tick and the 4 following ticks
//       it logs Delay3_out1, the `armed` latch and the pop strobe:
//         # popabort READBACK clk=<n> d3_post=<v> armed=<v> pop=<v>
//       d3_post=0 on the force tick proves the write actually landed in the model,
//       so a NULL result on a FIXED tree (no stall) is non-vacuous: the force was
//       applied and the fix absorbed it, rather than the force having missed.
//
//   (2) sel=latchforce / latchforce_pre -- a single-shot write of the pop-enable
//       latch itself (Unit_Delay_Enabled_Resettable_Synchronous_out1 = 0), which no
//       fix variant can prevent (F1 only stops the RTL from doing it; it does not
//       make the register unwritable).  This is the positive control that keeps the
//       fixed-tree gate honest:
//         latchforce      -- write at sampleCount >= 12314 - 128*k (mid-frame):
//                            expect a sustained non-zero offset and armed 0->1 at
//                            the next frame boundary on EVERY tree, fixed or not.
//         latchforce_pre  -- write inside the preamble window (sampleCount < 26):
//                            expect offset 0 (the latch is reloaded at the boundary
//                            before any payload pop is due).
//
// Every pre-existing sel (t0 / popabort / frcwrap / dstart / nearfull / none) is
// byte-for-byte unchanged.
//
// ---------------------------------------------------------------------------
// sim_burst_force_tx.cpp -- TX-side kick experiment (2026-09-02, TX_KICK_SIM_B).
// Retargeted per TX_ORIGIN_TRACE_A.md (tag archive/pre-cleanup-2026-09-09;
// Track A's RTL trace, commit df3c590), then
// corrected per two rounds of advisor review (2026-09-02): single-shot register forces (a
// hold-for-N-clk window over-forces across multiple enb_1_2_0-gated edges and can re-trigger
// the effect it's supposed to apply once), arm exactly at the TX-frame wrap (not from a stale
// mid-frame read), and readback the actual falsifiable witness -- the `armed` pop-enable latch
// and the pop strobe going quiet -- not just the register we wrote (which the RTL's own clocked
// process reloads on the very next enabled edge regardless of what we forced).
//
// A's read of Bit_Packetizer.v/Data_Bits_FIFO.v: dataStart = (sampleCount==26) & sampleCountValid
// off a MONOTONE free-running counter (HDL_Counter2_out1, wraps 0..24665) -- exactly ONE dataStart
// per 24,666 slots is possible without an async reset (T0 below checks this). A's top-ranked
// mechanism (#1) is a Data_Bits_FIFO POP-ABORT: `armed`
// (Unit_Delay_Enabled_Resettable_Synchronous_out1, Data_Bits_FIFO.v:272-289) clears mid-frame
// when frameCount==0 (compared via the delayed copy Delay3_out1, Data_Bits_FIFO.v:270), stalling
// the RAM read pointer for a partial frame with NO effect on sampleCount/dataStart/preamble/
// markers -- bit-exact data delay, not a timing-plane event.
//
// Same base harness/scoring plumbing as sim_kick_taps.cpp: needs --public-flat-rw over
// wrap_byte_ddrcap.v / Vwrap_byte_ddrcap, writes the same DDR record stream so the UNMODIFIED
// t6_score_large.py (tag archive/pre-cleanup-2026-09-09) + tap3_word_to_offset.tsv apply unchanged.
//
// NOTE ON "K": here K indexes TX FRAMES (delimited by HDL_Counter2_out1 wraps), not decoded
// packets (§76's/KICK_EXPERIMENT_REPORT's K indexed packets_out, which A's own §1 and the KICK
// report show lags the TX frame by a fixed pipeline delay). The two K's are NOT comparable.
//
// argv: NF K sel out_prefix [k=0] [SEL=6] [OUT.bin]
//   sel:
//     t0        -- instrument-only (NO force). Per TX frame, logs the count of
//                  Transmitter_txFrameStart rising edges and, at each edge, ddrcap_fec_mark_now/
//                  _latch and the running ddrcap record index.
//     popabort  -- A's #1. At TX frame K, on the first HDL_Counter2_out1 (sampleCount) sample
//                  >= target = 12314 - 128*k, force Data_Bits_FIFO's Delay3_out1 = 2'b00 for
//                  EXACTLY ONE tick (single write, never re-forced), then read back the `armed`
//                  latch (Unit_Delay_Enabled_Resettable_Synchronous_out1) and the pop strobe
//                  (Logical_Operator_out1) for the next 64 ticks to confirm the abort actually
//                  took (armed -> 0, pop strobe quiet) -- the falsifiable witness, not the forced
//                  register itself (which the RTL reloads on the very next enabled edge).
//     frcwrap   -- A's #2. At TX frame K, force RAM_Frame_Status_Indicator.frameCount = 3 for
//                  EXACTLY ONE tick, then do NOT touch it again -- watch for a self-triggered
//                  3->0 wrap on a later real push and log when/if it happens.
//     dstart    -- bonus (near-zero marginal cost): direct single-tick force of Data_Bits_FIFO's
//                  Delay5_out1(=sampleCount stage)/Delay6_out1(=sampleCountValid) to (26,1),
//                  P=6176 symbols after a natural Transmitter_txFrameStart edge following frame K.
//                  A predicts this is inert without reset -- run to falsify/confirm.
//     none      -- positive control, no force.
//   k: sweep index for popabort (target = 12314 - 128*k), ignored by other sel values.
//   SEL: ddrcap selector (default 6, tap3/symbol-domain)
#include "Vwrap_byte_ddrcap.h"
#include "Vwrap_byte_ddrcap___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#define DBF wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__u_Bit_Packetizer__DOT__u_Data_Bits_FIFO__DOT__
#define FSI wrap_byte_ddrcap__DOT__dut__DOT__u_Transmitter__DOT__u_QPSK_Tx__DOT__u_Bit_Packetizer__DOT__u_Data_Bits_FIFO__DOT__u_RAM_Frame_Status_Indicator__DOT__
#define TFS wrap_byte_ddrcap__DOT__dut__DOT__
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)

static const long CLK_PER_SYMBOL = 16;  // 197328 clk/frame / 12333 symbol/frame, exact
static const long POPABORT_ANCHOR = 12314;
static const long POPABORT_STEP = 128;
static const long WITNESS_WINDOW = 64; // ticks of armed/pop-strobe readback after the force

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: sim_burst_force_tx NF K sel out_prefix [k=0] [SEL=6] [OUT.bin]\n"); return 2; }
    int NF=atoi(argv[1]), K=atoi(argv[2]); std::string sel=argv[3]; const char* pfx=argv[4];
    long kk = (argc>5)? atol(argv[5]) : 0;
    unsigned SEL = (argc>6)? (unsigned)strtoul(argv[6],nullptr,0) : 6u;
    char outbuf[512]; const char* outpath;
    if(argc>7){ outpath = argv[7]; }
    else { snprintf(outbuf,sizeof outbuf,"%s.bin",pfx); outpath = outbuf; }
    char fn[512]; snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");

    Vwrap_byte_ddrcap* t=new Vwrap_byte_ddrcap; auto* R=t->rootp;
    long clk=0; t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=0; t->fixctl=0;
    t->iq_debug_mux = ((SEL & 0xFu) << 16) | 3u;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    long txFrameStartPulses=0; int lastTxFS=0; long lastRisingEdgeClk=-1;
    long txFrameIdx=-1;              // TX-frame index, delimited by HDL_Counter2_out1 wraps
    long prevSC=-1;
    long perFrameTxFS=0;
    long ddrcapRecIdx=0;

    // popabort state
    int paArmedFrame=0, paApplied=0, paDone=0; long paTargetSC=-1;
    long paSCAtArm=-1;
    long paArmedPre=-1, paPopPre=-1;      // armed latch / pop strobe readback, pre-force
    long paWitnessStart=-1;
    int  paSawArmedZero=0; long paArmedZeroClk=-1;
    long paPopQuietRun=0, paPopQuietMax=0;

    // frcwrap state
    int fwArmedFrame=0, fwApplied=0;
    long fwPre=-1, fwPost=-1;
    int fwSawWrap=0; long fwWrapClk=-1; long lastFrameCountSeen=-1;

    // dstart (bonus) state
    long dsArmedClk=-1; int dsArmed=0, dsForced=0; long dsFrameStartClk=-1, dsTargetClk=-1;
    long dsP = 6176;

    // nearfull state (coordinator addendum (a), 2026-09-02): force MATLAB_Function1.count near
    // the 49279 fullRAM threshold at frame 3 (sampleCount==0), single-shot, then watch the walk.
    const long NEARFULL_FRAME = 3;
    long nfTargets[3] = { 49279 - 26*2, 49279 - 26*2 - 8000, 49279 - 26*2 - 16000 };
    int nfArmedFrame=0, nfApplied=0; long nfPre=-1;
    long nfLastFull=-1, nfLastArmed=-1, nfLastFC=-1;
    int nfSawFullOnce=0; long nfFullClk=-1;
    int nfSawPopAbort=0; long nfPopAbortClk=-1;

    // popabort READBACK state (TXFIX addition 1)
    int paRbLeft=0;

    // latchforce / latchforce_pre state (TXFIX addition 2)
    const int isLatch = (sel=="latchforce" || sel=="latchforce_pre");
    int lfArmedFrame=0, lfApplied=0; long lfTargetSC=-1;
    long lfSCAtForce=-1, lfArmedPre=-1, lfPopPre=-1;
    long lfWitnessStart=-1; int lfDone=0;
    int lfSawArmedOne=0; long lfArmedOneClk=-1; long lfArmedOneSC=-1;
    long lfPopQuietRun=0, lfPopQuietMax=0;
    int lfRbLeft=0;

    auto tick=[&](){
        t->clk=0; t->eval();
        {
            int fs = (int)R->CAT(TFS,Transmitter_txFrameStart);
            if(fs && !lastTxFS){ txFrameStartPulses++; lastRisingEdgeClk = clk; perFrameTxFS++;
                fprintf(ff,"# TXFS edge clk=%ld frame=%ld sampleCount=%u mark_now=%u mark_latch=%u ddrcapRecIdx=%ld\n",
                    clk, txFrameIdx, (unsigned)R->CAT(DBF,HDL_Counter2_out1),
                    (unsigned)R->CAT(TFS,ddrcap_fec_mark_now), (unsigned)R->CAT(TFS,ddrcap_fec_mark_latch), ddrcapRecIdx);
            }
            lastTxFS = fs;
            long sc = (long)R->CAT(DBF,HDL_Counter2_out1);
            if(prevSC>=0 && sc < prevSC - 1000){ // wrap detected
                if(txFrameIdx>=0) fprintf(ff,"# FRAME %ld complete: txFrameStart edges=%ld\n", txFrameIdx, perFrameTxFS);
                txFrameIdx++; perFrameTxFS=0;
                // Sec.86-B (coordinator addendum, 2026-09-02): per-frame occupancy/pointer
                // drift, logged once per frame at the sampleCount==0 wrap, for sel=="t0". This
                // is the RATE witness for silicon Sec.87 (Data_Bits_FIFO pop-abort: new_offset =
                // old - L mod 12320) -- if occupancy or (push_ptr-pop_ptr) drifts by a constant
                // d bits/frame, the time to walk from the post-arm level to the abort condition
                // (frameCount wrapping to 0, or occupancy crossing 49279) is the beat period.
                if(sel=="t0"){
                    long occ = (long)R->CAT(DBF,u_MATLAB_Function1__DOT__count);
                    long fc2 = (long)R->CAT(FSI,frameCount);
                    long push = (long)R->CAT(DBF,HDL_Counter_out1);
                    long pop  = (long)R->CAT(DBF,HDL_Counter1_out1);
                    long full = (long)R->CAT(DBF,Delay7_out1);
                    long diff = push - pop; // can be negative across a 49280-wrap; reported raw, unwrapped in post-processing
                    fprintf(ff,"OCC frame=%ld clk=%ld occ=%ld frameCount=%ld push=%ld pop=%ld push_minus_pop=%ld fullRAM=%ld\n",
                        txFrameIdx, clk, occ, fc2, push, pop, diff, full);
                }
                // arm exactly at the wrap, so sc is guaranteed fresh/small here
                if(sel=="popabort" && txFrameIdx==K && !paArmedFrame){
                    paArmedFrame=1; paTargetSC = POPABORT_ANCHOR - POPABORT_STEP*kk;
                    fprintf(ff,"# popabort armed at frame %ld wrap, sc_at_arm=%ld target=%ld (k=%ld)\n", txFrameIdx, sc, paTargetSC, kk);
                }
                if(sel=="frcwrap" && txFrameIdx==K && !fwArmedFrame){
                    fwArmedFrame=1;
                    fprintf(ff,"# frcwrap armed at frame %ld wrap\n", txFrameIdx);
                }
                if(sel=="dstart" && txFrameIdx==K && !dsArmed){
                    dsArmed=1; dsArmedClk=clk;
                }
                if(isLatch && txFrameIdx==K && !lfArmedFrame){
                    lfArmedFrame=1;
                    lfTargetSC = (sel=="latchforce_pre") ? 0 : (POPABORT_ANCHOR - POPABORT_STEP*kk);
                    fprintf(ff,"# %s armed at frame %ld wrap, sc_at_arm=%ld target=%ld (k=%ld)\n",
                        sel.c_str(), txFrameIdx, sc, lfTargetSC, kk);
                }
                if(sel=="nearfull" && txFrameIdx==NEARFULL_FRAME && !nfArmedFrame){
                    nfArmedFrame=1;
                    fprintf(ff,"# nearfull armed at frame %ld wrap\n", txFrameIdx);
                }
            }
            // nearfull: log on any change of fullRAM/armed/frameCount once applied (change-detection,
            // not every tick, to keep the log bounded over a multi-frame walk to threshold)
            if(sel=="nearfull" && nfApplied){
                long full = (long)R->CAT(DBF,Delay7_out1);
                long armed = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
                long fc3 = (long)R->CAT(FSI,frameCount);
                if(full!=nfLastFull){
                    fprintf(ff,"# nearfull fullRAM change clk=%ld frame=%ld %ld -> %ld count=%ld push=%ld pop=%ld\n",
                        clk, txFrameIdx, nfLastFull, full, (long)R->CAT(DBF,u_MATLAB_Function1__DOT__count),
                        (long)R->CAT(DBF,HDL_Counter_out1), (long)R->CAT(DBF,HDL_Counter1_out1));
                    if(full==1 && !nfSawFullOnce){ nfSawFullOnce=1; nfFullClk=clk; }
                    nfLastFull=full;
                }
                if(armed!=nfLastArmed){
                    fprintf(ff,"# nearfull armed-latch change clk=%ld frame=%ld %ld -> %ld\n", clk, txFrameIdx, nfLastArmed, armed);
                    if(armed==0 && !nfSawPopAbort){ nfSawPopAbort=1; nfPopAbortClk=clk; }
                    nfLastArmed=armed;
                }
                if(fc3!=nfLastFC){
                    fprintf(ff,"# nearfull frameCount(local) change clk=%ld frame=%ld %ld -> %ld\n", clk, txFrameIdx, nfLastFC, fc3);
                    nfLastFC=fc3;
                }
            }
            prevSC = sc;

            long fc = (long)R->CAT(FSI,frameCount);
            if(lastFrameCountSeen>=0 && fc!=lastFrameCountSeen){
                fprintf(ff,"# frameCount change clk=%ld frame=%ld %ld -> %ld\n", clk, txFrameIdx, lastFrameCountSeen, fc);
                if(sel=="frcwrap" && fwApplied && lastFrameCountSeen==3 && fc==0 && !fwSawWrap){
                    fwSawWrap=1; fwWrapClk=clk;
                    fprintf(ff,"# frcwrap: SELF-WRAP 3->0 observed at clk %ld (no force at abort instant)\n", clk);
                }
            }
            lastFrameCountSeen = fc;

            // popabort witness window: armed latch + pop strobe, sampled every tick once we've applied
            if(sel=="popabort" && paApplied && !paDone){
                long armed = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
                long pop   = (long)R->CAT(DBF,Logical_Operator_out1);
                if(!paSawArmedZero && armed==0){ paSawArmedZero=1; paArmedZeroClk=clk; }
                if(pop==0) paPopQuietRun++; else paPopQuietRun=0;
                if(paPopQuietRun>paPopQuietMax) paPopQuietMax=paPopQuietRun;
                if(clk - paWitnessStart >= WITNESS_WINDOW){
                    paDone=1;
                    fprintf(ff,"# popabort WITNESS done: saw_armed_zero=%d armed_zero_clk=%ld max_consecutive_pop_quiet=%ld (window=%ld)\n",
                        paSawArmedZero, paArmedZeroClk, paPopQuietMax, WITNESS_WINDOW);
                }
            }

            // latchforce witness: the latch we cleared must come back at the next frame
            // boundary (armed 0->1); the pop strobe stays quiet until it does.
            if(isLatch && lfApplied){
                long armed = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
                long pop   = (long)R->CAT(DBF,Logical_Operator_out1);
                if(!lfSawArmedOne && armed==1){
                    lfSawArmedOne=1; lfArmedOneClk=clk;
                    lfArmedOneSC = (long)R->CAT(DBF,HDL_Counter2_out1);
                }
                if(pop==0) lfPopQuietRun++; else lfPopQuietRun=0;
                if(lfPopQuietRun>lfPopQuietMax) lfPopQuietMax=lfPopQuietRun;
                // the latch reload happens at the NEXT sampleCount==0 boundary, up to a
                // full frame (197,328 clk) away, so this witness runs to the end of the
                // simulation rather than closing after WITNESS_WINDOW ticks.
                if(lfSawArmedOne && !lfDone){
                    lfDone=1;
                    fprintf(ff,"# %s WITNESS armed reload: clk=%ld sampleCount=%ld (%ld clk after the force) max_consecutive_pop_quiet_so_far=%ld\n",
                        sel.c_str(), lfArmedOneClk, lfArmedOneSC, lfArmedOneClk-lfWitnessStart, lfPopQuietMax);
                }
            }
        }
        t->clk=1; t->eval();
        clk++;
    };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    txFrameIdx=0; prevSC=-1; lastFrameCountSeen=-1;

    FILE* fb=fopen(outpath,"wb");
    long total = 100 + (long)(NF+4)*197328;

    while(clk<total){
        t->adc_validIn=(clk&1)?0:1;

        // ---- popabort: single-shot force, applied the instant sampleCount reaches target ----
        if(sel=="popabort" && paArmedFrame && !paApplied){
            long sc = (long)R->CAT(DBF,HDL_Counter2_out1);
            if(sc>=paTargetSC){
                paSCAtArm = sc;
                paArmedPre = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
                paPopPre   = (long)R->CAT(DBF,Logical_Operator_out1);
                R->CAT(DBF,Delay3_out1) = 0;   // single write -- never repeated
                paApplied=1; paWitnessStart=clk;
                fprintf(ff,"# popabort FORCE clk=%ld frame=%ld sampleCount=%ld target=%ld pre_armed=%ld pre_pop=%ld\n",
                    clk, txFrameIdx, sc, paTargetSC, paArmedPre, paPopPre);
                // TXFIX addition 1: read the forced register straight back (d3_post must be 0)
                // plus the two witnesses, on the force tick and the next 4 ticks.
                fprintf(ff,"# popabort READBACK clk=%ld d3_post=%ld armed=%ld pop=%ld\n",
                    clk, (long)R->CAT(DBF,Delay3_out1),
                    (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1),
                    (long)R->CAT(DBF,Logical_Operator_out1));
                paRbLeft=4;
            }
        }

        // ---- latchforce / latchforce_pre: single-shot write of the pop-enable latch ----
        if(isLatch && lfArmedFrame && !lfApplied){
            long sc = (long)R->CAT(DBF,HDL_Counter2_out1);
            int hit = (sel=="latchforce_pre") ? (sc < 26) : (sc >= lfTargetSC);
            if(hit){
                lfSCAtForce = sc;
                lfArmedPre = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
                lfPopPre   = (long)R->CAT(DBF,Logical_Operator_out1);
                R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1) = 0;  // single write
                lfApplied=1; lfWitnessStart=clk;
                fprintf(ff,"# %s FORCE clk=%ld frame=%ld sampleCount=%ld target=%ld pre_armed=%ld pre_pop=%ld\n",
                    sel.c_str(), clk, txFrameIdx, sc, lfTargetSC, lfArmedPre, lfPopPre);
                fprintf(ff,"# %s READBACK clk=%ld armed_post=%ld d3=%ld pop=%ld\n",
                    sel.c_str(), clk,
                    (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1),
                    (long)R->CAT(DBF,Delay3_out1),
                    (long)R->CAT(DBF,Logical_Operator_out1));
                lfRbLeft=4;
            }
        }

        // ---- frcwrap: single-shot force ----
        if(sel=="frcwrap" && fwArmedFrame && !fwApplied){
            fwPre = (long)R->CAT(FSI,frameCount);
            R->CAT(FSI,frameCount) = 3;        // single write -- never repeated
            fwApplied=1;
            fprintf(ff,"# frcwrap FORCE clk=%ld frame=%ld pre_frameCount=%ld\n", clk, txFrameIdx, fwPre);
        }

        // ---- nearfull: single-shot force ----
        if(sel=="nearfull" && nfArmedFrame && !nfApplied){
            nfPre = (long)R->CAT(DBF,u_MATLAB_Function1__DOT__count);
            R->CAT(DBF,u_MATLAB_Function1__DOT__count) = (unsigned)nfTargets[kk];
            nfApplied=1;
            nfLastFull = (long)R->CAT(DBF,Delay7_out1);
            nfLastArmed = (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1);
            nfLastFC = (long)R->CAT(FSI,frameCount);
            fprintf(ff,"# nearfull FORCE clk=%ld frame=%ld variant=%ld pre_count=%ld target=%ld\n",
                clk, txFrameIdx, kk, nfPre, nfTargets[kk]);
        }
        // ---- dstart: bonus single-shot force ----
        if(sel=="dstart" && dsForced && clk==dsTargetClk){
            R->CAT(DBF,Delay5_out1) = 26;
            R->CAT(DBF,Delay6_out1) = 1;
            fprintf(ff,"# dstart FORCE clk=%ld\n", clk);
        }

        tick();

        // TXFIX addition 1: the 4 ticks that follow the force
        if(paRbLeft>0){
            fprintf(ff,"# popabort READBACK clk=%ld d3_post=%ld armed=%ld pop=%ld\n",
                clk, (long)R->CAT(DBF,Delay3_out1),
                (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1),
                (long)R->CAT(DBF,Logical_Operator_out1));
            paRbLeft--;
        }
        if(lfRbLeft>0){
            fprintf(ff,"# %s READBACK clk=%ld armed_post=%ld d3=%ld pop=%ld\n",
                sel.c_str(), clk,
                (long)R->CAT(DBF,Unit_Delay_Enabled_Resettable_Synchronous_out1),
                (long)R->CAT(DBF,Delay3_out1),
                (long)R->CAT(DBF,Logical_Operator_out1));
            lfRbLeft--;
        }

        if(sel=="frcwrap" && fwApplied && fwPost<0){
            fwPost = (long)R->CAT(FSI,frameCount);
            fprintf(ff,"# frcwrap post-tick readback frameCount=%ld (should read the FORCED 3 exactly once, then evolve naturally)\n", fwPost);
        }

        if(t->ddrcap_valid){
            short r[4] = { (short)t->ddrcap_i, (short)t->ddrcap_q, (short)t->ddrcap_mark_demod, (short)t->ddrcap_mark_fec };
            fwrite(r, sizeof r, 1, fb);
            ddrcapRecIdx++;
        }

        if(sel=="dstart" && dsArmed && !dsForced && lastRisingEdgeClk>dsArmedClk){
            dsFrameStartClk = lastRisingEdgeClk;
            dsTargetClk = dsFrameStartClk + dsP*CLK_PER_SYMBOL;
            dsForced=1;
            fprintf(ff,"# dstart armed on natural edge clk=%ld -> target clk=%ld\n", dsFrameStartClk, dsTargetClk);
        }
    }
    if(sel=="popabort"){
        fprintf(ff,"# popabort SUMMARY k=%ld target_sampleCount=%ld sc_at_arm=%ld pre_armed=%ld pre_pop=%ld saw_armed_zero=%d armed_zero_clk=%ld max_pop_quiet=%ld\n",
            kk, paTargetSC, paSCAtArm, paArmedPre, paPopPre, paSawArmedZero, paArmedZeroClk, paPopQuietMax);
    }
    if(isLatch){
        fprintf(ff,"# %s SUMMARY k=%ld target_sampleCount=%ld sc_at_force=%ld pre_armed=%ld pre_pop=%ld saw_armed_one=%d armed_one_clk=%ld armed_one_sampleCount=%ld clk_to_reload=%ld max_pop_quiet=%ld\n",
            sel.c_str(), kk, lfTargetSC, lfSCAtForce, lfArmedPre, lfPopPre,
            lfSawArmedOne, lfArmedOneClk, lfArmedOneSC,
            (lfSawArmedOne? lfArmedOneClk-lfWitnessStart : -1), lfPopQuietMax);
    }
    if(sel=="frcwrap"){
        fprintf(ff,"# frcwrap SUMMARY pre=%ld saw_self_wrap=%d wrap_clk=%ld\n", fwPre, fwSawWrap, fwWrapClk);
    }
    if(sel=="nearfull"){
        fprintf(ff,"# nearfull SUMMARY variant=%ld target=%ld pre_count=%ld saw_full=%d full_clk=%ld saw_pop_abort=%d pop_abort_clk=%ld\n",
            kk, nfTargets[kk], nfPre, nfSawFullOnce, nfFullClk, nfSawPopAbort, nfPopAbortClk);
    }
    if(txFrameIdx>=0) fprintf(ff,"# FRAME %ld (final, possibly partial) txFrameStart edges=%ld\n", txFrameIdx, perFrameTxFS);
    fclose(ff); fclose(fb);
    printf("TXKICK sel=%s SEL=%u NF=%d K=%d k=%ld packets=%u biterr=%u rstcs=%u txFrameStartPulses=%ld txFrameIdx=%ld\n",
        sel.c_str(),SEL,NF,K,kk,t->packets_out,t->bit_errors_out,t->rstcs_count,txFrameStartPulses,txFrameIdx);
    delete t; return 0;
}
