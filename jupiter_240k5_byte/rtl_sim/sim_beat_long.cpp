// sim_beat_long.cpp -- long UNFORCED ROM/BIST mode-1 loopback run on the TXMARK netlist.
// Per-frame log (same first four columns as burst_runs/*_frames.txt): packet errs clks rstcs.
// Flat build (-DBEAT_FLAT): adds mu/cnt columns, --dump-at register dumps, --ckpt-every /
// --restore checkpoints (Verilator --savable), --trace-at/--trace-frames FST trace.
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#ifdef BEAT_FLAT
#include "Vwrap_byte_ddrcap___024root.h"
#include "verilated_save.h"
#include "verilated_fst_c.h"
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define RXP wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
// Loop-bound unit only: the netlist actually emits a packets_out increment every 98,664
// clocks (2x smaller), so each unit of NF buys ~2 packets, not 1 -- see beat_runs/THROUGHPUT.md.
static const long CLKS_PER_FRAME = 197328;
int main(int argc, char** argv){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);
    if(argc < 3){ fprintf(stderr,"usage: sim_beat_long NF OUT_PREFIX [--ckpt-every N] [--restore F] [--dump-at k,k,..] [--trace-at K --trace-frames N]\n"); return 2; }
    long NF = atol(argv[1]); std::string pfx = argv[2];
    long ckptEvery = 0; std::string restore; std::vector<long> dumpAt; long traceAt = -1, traceFrames = 3;
    for(int i = 3; i < argc; i++){
        std::string a = argv[i];
        if(a == "--ckpt-every" && i+1 < argc) ckptEvery = atol(argv[++i]);
        else if(a == "--restore" && i+1 < argc) restore = argv[++i];
        else if(a == "--dump-at" && i+1 < argc){ char* s = argv[++i]; for(char* t = strtok(s, ","); t; t = strtok(nullptr, ",")) dumpAt.push_back(atol(t)); }
        else if(a == "--trace-at" && i+1 < argc) traceAt = atol(argv[++i]);
        else if(a == "--trace-frames" && i+1 < argc) traceFrames = atol(argv[++i]);
    }
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()};
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0; t->fixctl = 0;
    t->iq_debug_mux = 3; t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
#ifdef BEAT_FLAT
    auto* R = t->rootp;
    VerilatedFstC* tfp = nullptr;
    if(traceAt >= 0){ ctx->traceEverOn(true); tfp = new VerilatedFstC; t->trace(tfp, 99); }
#endif
#ifdef BEAT_POSEDGE_ONLY
    // 2026-09-01 controller-directed speedup attempt: posedge-only eval (skip the
    // negedge settle eval). Only used if a bit-identical check against the
    // two-eval build passes -- see THROUGHPUT.md.
    auto tick = [&](){ t->clk = 1; t->eval(); t->clk = 0; clk++;
#ifdef BEAT_FLAT
        if(tfp && tfp->isOpen()) tfp->dump((uint64_t)clk);
#endif
    };
#else
    auto tick = [&](){ t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
#ifdef BEAT_FLAT
        if(tfp && tfp->isOpen()) tfp->dump((uint64_t)clk);
#endif
    };
#endif
    unsigned lastPk = 0, lastErr = 0; long lastClk = 0;
    if(!restore.empty()){
#ifdef BEAT_FLAT
        VerilatedRestore is; is.open(restore.c_str()); is >> ctx.get(); is >> *t;
        uint64_t clk64 = 0, lastClk64 = 0; is >> clk64; is >> lastPk; is >> lastErr; is >> lastClk64; is.close();
        clk = (long)clk64; lastClk = (long)lastClk64;
        fprintf(stderr, "restored %s at clk %ld packet %u\n", restore.c_str(), clk, lastPk);
#else
        fprintf(stderr, "--restore needs the flat build\n"); return 2;
#endif
    } else { for(int i = 0; i < 100; i++) tick(); t->reset = 0; }
    std::string fn = pfx + "_frames.txt"; FILE* ff = fopen(fn.c_str(), restore.empty() ? "w" : "a");
    std::string st = pfx + "_status.txt";
    long total = 100 + (NF + 4) * CLKS_PER_FRAME; size_t dumpIdx = 0;
    while(clk < total){
        t->adc_validIn = (clk & 1) ? 0 : 1;
        tick();
        unsigned pk = t->packets_out;
        if(pk != lastPk){
            unsigned err = t->bit_errors_out;
            fprintf(ff, "%u %u %ld %u", pk, err - lastErr, clk - lastClk, t->rstcs_count);
#ifdef BEAT_FLAT
            fprintf(ff, " mu=%d cnt=%d",
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg) << 5)) >> 5,
                (int)(short)((R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg) << 5)) >> 5);
#endif
            fprintf(ff, "\n");
            lastErr = err; lastClk = clk; lastPk = pk;
            if((pk & 255) == 0){ fflush(ff); FILE* fs = fopen(st.c_str(), "w"); if(fs){ fprintf(fs, "packet=%u errs=%u clk=%ld\n", pk, err, clk); fclose(fs);} }
#ifdef BEAT_FLAT
            if(ckptEvery > 0 && pk % ckptEvery == 0){
                char cf[512]; snprintf(cf, sizeof cf, "%s_ckpt_%u.bin", pfx.c_str(), pk);
                VerilatedSave os; os.open(cf); os << ctx.get(); os << *t;
                os << (uint64_t)clk; os << lastPk; os << lastErr; os << (uint64_t)lastClk; os.close();
            }
            if(dumpIdx < dumpAt.size() && (long)pk == dumpAt[dumpIdx]){
                dumpIdx++;
                char df[512]; snprintf(df, sizeof df, "%s_dump_%u.txt", pfx.c_str(), pk); FILE* fd = fopen(df, "w");
                fprintf(fd, "packet %u clk %ld errs_total %u\n", pk, clk, err);
                fprintf(fd, "cs_integ %llx\n", (unsigned long long)R->CAT(FTS,u_Carrier_Synchronizer__DOT__u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1));
                fprintf(fd, "ss_delay2_0 %llx\nss_delay2_1 %llx\n", (unsigned long long)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[0], (unsigned long long)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Loop_Filter__DOT__Delay2_reg)[1]);
                fprintf(fd, "ss_mu %d\nss_cnt %d\n", (int)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg), (int)R->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__countReg));
                fprintf(fd, "agc_delay2_re_0 %llx\nagc_delay2_re_1 %llx\n", (unsigned long long)R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[0], (unsigned long long)R->CAT(RXP,u_Automatic_Gain_Control__DOT__u_Loop_Filter__DOT__Delay2_reg_re)[1]);
                fprintf(fd, "cfe_integ_re %x\ncfe_integ_im %x\n", (unsigned)R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_re), (unsigned)R->CAT(FTS,u_Coarse_Frequency_Compensator__DOT__u_Coarse_Frequency_Estimator__DOT__u_Integrator__DOT__Integ_Reg_out1_im));
                fprintf(fd, "ps_ref %u\nta_ref %u\nps_offset %u\n", (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Timing_Adjust__DOT__timing_Reference_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1));
                fprintf(fd, "fifo_push %u\nfifo_pop %u\nfifo_occ %u\n", (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Push_Counter_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__Pop_Counter_out1), (unsigned)R->CAT(FTS,u_Preamble_Detector__DOT__u_FIFO__DOT__u_Validate_Input_Push_Pop__DOT__u_MATLAB_Function__DOT__countReg));
                fclose(fd);
            }
            if(tfp && (long)pk == traceAt){ char tf[512]; snprintf(tf, sizeof tf, "%s_trace_%u.fst", pfx.c_str(), pk); tfp->open(tf); }
            if(tfp && tfp->isOpen() && (long)pk == traceAt + traceFrames){ tfp->close(); }
#endif
        }
    }
    fclose(ff);
#ifdef BEAT_FLAT
    if(tfp){ if(tfp->isOpen()) tfp->close(); delete tfp; }
#endif
    printf("BEATLONG NF=%ld packets=%u biterr=%u rstcs=%u clk=%ld\n", NF, t->packets_out, t->bit_errors_out, t->rstcs_count, clk);
    delete t; return 0;
}
