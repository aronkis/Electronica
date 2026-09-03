// sim_txcap.cpp -- PRE-BUILD GATE for the combined TXCAP + DBGCAP image.
// fixctl[12]=1 selects TXCAP on the beatfix_viol registers; 0 selects DBGCAP.
// PRE-REGISTERED: on a clean run TXCAP mismatches must be 0, and the DBGCAP
// symbol-domain taps (1,2,3) must be 0.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int NF = argc > 1 ? atoi(argv[1]) : 10;
    int bad = 0;
    // --- TXCAP ---
    {
        Vwrap_byte_ce* t = new Vwrap_byte_ce;
        long clk = 0;
        t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
        t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
        t->fixctl = (1u << 12); t->iq_debug_mux = 0;
        t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
        auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
        for (int i = 0; i < 100; i++) tick();
        t->reset = 0;
        long total = 100 + (long)(NF + 4) * 197328;
        while (clk < total) tick();
        printf("  TXCAP (TX-anchored, transmitter output)   cap=0x%08X mismatches=%u%s\n",
               t->bfViol, t->bfLatch, t->bfLatch ? "   <== NOT FRAME-INVARIANT" : "");
        printf("        packets=%u biterr=%u\n", t->packets_out, t->bit_errors_out);
        if (t->bfLatch) bad++;
        delete t;
    }
    // --- DBGCAP taps still reachable in the same image ---
    for (int tap = 1; tap <= 3; tap++) {
        Vwrap_byte_ce* t = new Vwrap_byte_ce;
        long clk = 0;
        t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
        t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
        t->fixctl = 0; t->iq_debug_mux = tap;
        t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
        auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
        for (int i = 0; i < 100; i++) tick();
        t->reset = 0;
        long total = 100 + (long)(NF + 4) * 197328;
        while (clk < total) tick();
        printf("  DBGCAP tap %d                              cap=0x%08X mismatches=%u%s\n",
               tap, t->bfViol, t->bfLatch, t->bfLatch ? "   <== NOT FRAME-INVARIANT" : "");
        if (t->bfLatch) bad++;
        delete t;
    }
    printf("TXCAP_GATE %s  (%d/4 witnesses not frame-invariant)\n", bad ? "FAIL" : "PASS", bad);
    return 0;
}
