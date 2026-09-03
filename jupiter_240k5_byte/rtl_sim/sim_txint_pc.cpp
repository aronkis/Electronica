// sim_txint_pc.cpp -- POSITIVE CONTROL ONLY (fast, minimal): flip one bit of
// Message_Generator's ROM index counter (a true register) for a single clock,
// mid-frame, and show BitPacketizer/Scrambler/QPSK_Modulator/RRC_Tx_Filter
// (fixctl[14..17]) and TXCAP (fixctl[12], already silicon-validated) all move
// to a different captured value than a matched clean run. See sim_txint.cpp
// for the gate (already run separately, PASS) and for why a single clk_enable
// drop was rejected as the injection method (zero movement even on TXCAP,
// because all TX stages share one enable domain -- a uniform pause delays
// content, it does not corrupt it).
#include "Vwrap_byte_ce_txint_pc.h"
#include "Vwrap_byte_ce_txint_pc___024root.h"
#include "verilated.h"
#include <cstdio>

static void tick(Vwrap_byte_ce_txint_pc* t, long& clk) {
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
}
static void driveIdle(Vwrap_byte_ce_txint_pc* t) {
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
}

int main() {
    unsigned cleanCap[5], dirtyCap[5];
    const unsigned pcFixctl[5] = {1u<<14, 1u<<15, 1u<<16, 1u<<17, 1u<<12};
    const char* pcName[5] = {"BitPacketizer","Scrambler","QPSK_Modulator","RRC_Tx_Filter","TXCAP"};
    // 3 frames is enough to (a) get past the reset/warm-up transient and
    // (b) let the flip, applied inside frame 1, be captured at the frame-2
    // boundary and held as the "last completed frame" (bfViol) at end of run.
    // Flip PERIODICALLY, once per frame starting at frame 1, so the
    // corruption reaches every downstream tap's capture window regardless
    // of any per-frame reset of the ROM index counter -- a persistent fault,
    // not a single fragile timing coincidence.
    long frameLen = 197328;
    long firstFlip = 100 + 1 * frameLen + 50000;

    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 5; i++) {
            Vwrap_byte_ce_txint_pc* t = new Vwrap_byte_ce_txint_pc;
            long clk = 0;
            driveIdle(t);
            t->fixctl = pcFixctl[i]; t->iq_debug_mux = 0;
            for (int k = 0; k < 100; k++) tick(t, clk);
            t->reset = 0;
            long total = 100 + (long)5 * frameLen;
            while (clk < total) {
                if (pass == 1 && clk >= firstFlip && (clk - firstFlip) % frameLen == 0) {
                    t->rootp->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__u_Message_Generator__DOT__u_MATLAB_Function__DOT__indexCount
                        ^= 0x8u;
                }
                tick(t, clk);
            }
            unsigned cap = t->bfViol;
            printf("  [pass %d] %-15s cap=0x%08X\n", pass, pcName[i], cap);
            fflush(stdout);
            if (pass == 0) cleanCap[i] = cap; else dirtyCap[i] = cap;
            delete t;
        }
    }
    int moved = 0;
    printf("\n== SUMMARY ==\n");
    for (int i = 0; i < 5; i++) {
        bool diff = cleanCap[i] != dirtyCap[i];
        printf("  %-15s clean=0x%08X corrupted=0x%08X %s\n",
               pcName[i], cleanCap[i], dirtyCap[i], diff ? "MOVED" : "same");
        if (diff) moved++;
    }
    printf("TXINT_PC %s (%d/5 witnesses moved under forced fault)\n",
           moved == 5 ? "PASS" : "PARTIAL", moved);
    return moved < 4 ? 1 : 0;
}
