// sim_rxfe_cfcap_dbg.cpp -- diagnostic: is CFCAP's mismatch count a startup
// transient (frame-8 reference latched during acquisition, same failure mode
// documented for other witnesses in this campaign) or a persistent defect?
// Selects fixctl[21] only, prints bfLatch at every RX frame-start strobe
// (demodStartOut) so we can see WHEN mismatches occur.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int NF = argc > 1 ? atoi(argv[1]) : 60;
    Vwrap_byte_ce* t = new Vwrap_byte_ce;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->fixctl = 1u << 21; t->iq_debug_mux = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    unsigned char prevStart = 0;
    unsigned lastLatch = 0;
    int frameIdx = 0;
    auto tick = [&]() {
        t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
        unsigned char s = t->demodStartOut;
        if (s && !prevStart) {
            frameIdx++;
            if (t->bfLatch != lastLatch) {
                printf("  frame %4d: bfLatch %u -> %u  cap=0x%08X\n", frameIdx, lastLatch, t->bfLatch, t->bfViol);
                lastLatch = t->bfLatch;
            }
        }
        prevStart = s;
    };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) tick();
    printf("DONE frames_seen=%d final_bfLatch=%u final_cap=0x%08X\n", frameIdx, t->bfLatch, t->bfViol);
    delete t;
    return 0;
}
