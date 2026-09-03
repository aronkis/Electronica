// sim_dbgcap.cpp -- PRE-BUILD GATE for DBGCAP: sweep iq_debug_mux and check that
// each symbol-domain tap's decision capture is frame-invariant on a clean run.
// PRE-REGISTERED: taps 1,2,3 must show 0 mismatches. Tap 0 is sample-domain and
// strobed by a symbol-rate valid -> UNCOVERED by construction, never interpreted.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
static const char* T[5] = {"0 AGC out (SAMPLE domain - uncovered by construction)",
                           "1 postSymbolSync (timing recovery)",
                           "2 postCarrierSync (pre ambiguity fix)",
                           "3 QPSKConstellation (demod input)",
                           "4 P1c telemetry"};
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: sim_dbgcap NF prefix\n"); return 2; }
    int NF = atoi(argv[1]); const char* pfx = argv[2];
    char fn[512]; snprintf(fn, sizeof fn, "%s_frames.txt", pfx); FILE* ff = fopen(fn, "w");
    int bad = 0;
    for (int tap = 0; tap < 4; tap++) {
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
        printf("  tap %-52s cap=0x%08X mismatches=%u%s\n", T[tap], t->bfViol, t->bfLatch,
               (t->bfLatch && tap >= 1) ? "   <== NOT FRAME-INVARIANT" : "");
        fprintf(ff, "# TAP %d cap=0x%08X mm=%u packets=%u biterr=%u\n",
                tap, t->bfViol, t->bfLatch, t->packets_out, t->bit_errors_out);
        if (t->bfLatch && tap >= 1) bad++;
        delete t;
    }
    printf("DBGCAP_GATE %s  (%d/3 symbol-domain taps not frame-invariant)\n", bad ? "FAIL" : "PASS", bad);
    fclose(ff); return 0;
}
