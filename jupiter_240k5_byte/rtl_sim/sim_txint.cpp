// sim_txint.cpp -- gate + positive control for the TX-side taps added by
// txint_inject.py: Bit_Packetizer (fixctl[14]), HDL_Data_Scrambler
// (fixctl[15]), QPSK_Modulator (fixctl[16]), RRC_Transmit_Filter (fixctl[17]).
// PRE-REGISTERED: every witness must be frame-invariant (bfLatch==0) on a
// clean run.
//
// Positive control: a single-cycle clk_enable drop (the Model-1 "--drop-ce"
// technique) was tried first and produced ZERO movement on every witness,
// INCLUDING the already-silicon-validated TXCAP -- because every TX-side
// stage here shares one enable domain (enb_1_2_0), so a uniform one-cycle
// pause delays the whole pipeline without changing its content. That is a
// negative result about the injection method, not about the witnesses, and
// is reported as such below; it is not used as the positive control.
//
// The control actually used: XOR one bit of Message_Generator's ROM index
// counter (a genuine internal REGISTER, not a recomputed combinational net)
// for a single clock, mid-run, via Verilator --public-flat-rw. This
// corrupts which ROM bits get serialized into the frame from that point on
// -- a real content change upstream of all four new taps and of TXCAP --
// and the four new taps plus TXCAP are compared clean vs corrupted.
#include "Vwrap_byte_ce_txint.h"
#include "Vwrap_byte_ce_txint___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

struct Cfg { const char* name; unsigned fixctl; };

static void tick(Vwrap_byte_ce_txint* t, long& clk) {
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
}

static void driveIdle(Vwrap_byte_ce_txint* t) {
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int NF = argc > 1 ? atoi(argv[1]) : 10;

    Cfg cfgs[] = {
        {"BitPacketizer  (fixctl[14])", 1u << 14},
        {"Scrambler      (fixctl[15])", 1u << 15},
        {"QPSK_Modulator (fixctl[16])", 1u << 16},
        {"RRC_Tx_Filter  (fixctl[17])", 1u << 17},
    };
    int bad = 0;
    printf("== GATE: clean-run frame-invariance ==\n");
    for (auto& c : cfgs) {
        Vwrap_byte_ce_txint* t = new Vwrap_byte_ce_txint;
        long clk = 0;
        driveIdle(t);
        t->fixctl = c.fixctl; t->iq_debug_mux = 0;
        for (int i = 0; i < 100; i++) tick(t, clk);
        t->reset = 0;
        long total = 100 + (long)(NF + 4) * 197328;
        while (clk < total) tick(t, clk);
        printf("  %-30s cap=0x%08X mismatches=%u%s\n",
               c.name, t->bfViol, t->bfLatch, t->bfLatch ? "  <== NOT INVARIANT" : "");
        if (t->bfLatch) bad++;
        delete t;
    }
    printf("TXINT_GATE %s (%d/4 witnesses not frame-invariant)\n", bad ? "FAIL" : "PASS", bad);

    // ---- Positive control ----
    printf("\n== POSITIVE CONTROL: ROM index-counter bit flip (true register), one clock mid-run ==\n");
    unsigned cleanCap[5], dirtyCap[5];
    const unsigned pcFixctl[5] = {1u<<14, 1u<<15, 1u<<16, 1u<<17, 1u<<12};
    const char* pcName[5] = {"BitPacketizer","Scrambler","QPSK_Modulator","RRC_Tx_Filter","TXCAP"};
    long flipClk = 100 + (long)3 * 197328 + 50000; // mid-run, well past warm-up ref frame

    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 5; i++) {
            Vwrap_byte_ce_txint* t = new Vwrap_byte_ce_txint;
            long clk = 0;
            driveIdle(t);
            t->fixctl = pcFixctl[i]; t->iq_debug_mux = 0;
            for (int k = 0; k < 100; k++) tick(t, clk);
            t->reset = 0;
            long total = 100 + (long)8 * 197328;
            while (clk < total) {
                if (pass == 1 && clk == flipClk) {
                    t->rootp->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__u_Message_Generator__DOT__u_MATLAB_Function__DOT__indexCount
                        ^= 0x8u;
                }
                tick(t, clk);
            }
            unsigned cap = t->bfViol;
            if (pass == 0) cleanCap[i] = cap; else dirtyCap[i] = cap;
            delete t;
        }
    }
    int moved = 0;
    for (int i = 0; i < 5; i++) {
        bool diff = cleanCap[i] != dirtyCap[i];
        printf("  %-15s clean=0x%08X corrupted=0x%08X %s\n",
               pcName[i], cleanCap[i], dirtyCap[i], diff ? "MOVED" : "same");
        if (diff) moved++;
    }
    printf("TXINT_PC %s (%d/5 witnesses moved under forced fault)\n",
           moved == 5 ? "PASS" : "PARTIAL", moved);
    return (bad || moved < 4) ? 1 : 0;
}
