// sim_hyp.cpp -- OFFLINE hypothesis test for SESSION §29.
//
// Dumps the raw hard-decision symbol stream at one selector, with the demod
// frame markers, so the 32-bit DBGCAP capture word can be recomputed for a
// capture window anchored at ANY offset. §28 could only test window shifts
// small enough to leave overlap with the golden word; this covers the whole
// frame and its neighbours.
//
// Output: one line per valid beat -- "<idx> <I> <Q> <markDemod> <markFec>".
// Scoring, window packing and the null are all done in Python.
#include "Vwrap_byte_hyp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned sel = argc > 1 ? (unsigned)atoi(argv[1]) : 6;
    int NF       = argc > 2 ? atoi(argv[2]) : 8;

    Vwrap_byte_hyp* t = new Vwrap_byte_hyp;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->fixctl = 0; t->iq_debug_mux = (sel & 0xFu) << 16;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    long total = 100 + (long)(NF + 4) * 197328;
    long idx = 0;
    while (clk < total) {
        tick();
        if (t->ddrcap_valid) {
            printf("%ld %d %d %u %u\n", idx++, (int)(short)t->ddrcap_i, (int)(short)t->ddrcap_q,
                   (unsigned)t->ddrcap_mark_demod, (unsigned)t->ddrcap_mark_fec);
        }
    }
    fprintf(stderr, "beats=%ld frames=%u\n", idx, t->cnt_frame_start);
    delete t;
    return 0;
}
