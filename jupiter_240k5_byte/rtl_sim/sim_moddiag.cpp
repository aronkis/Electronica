#include "Vwrap_byte_ce_moddiag.h"
#include "verilated.h"
#include <cstdio>
static void tick(Vwrap_byte_ce_moddiag* t, long& clk) {
    t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++;
}
int main() {
    Vwrap_byte_ce_moddiag* t = new Vwrap_byte_ce_moddiag;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    t->fixctl = 1u << 14; t->iq_debug_mux = 0;
    for (int i = 0; i < 100; i++) tick(t, clk);
    t->reset = 0;
    long modValidCount = 0;
    unsigned lastI = 0, lastQ = 0;
    long frameStarts = 0;
    long total = 100 + (long)3 * 197328;
    while (clk < total) {
        tick(t, clk);
        if (t->cnt_frame_start != frameStarts) { frameStarts = t->cnt_frame_start; }
        if (t->modValid) {
            modValidCount++;
            if (modValidCount <= 20 || (modValidCount % 5000)==0)
                printf("  clk=%ld modValidCount=%ld modI=%d modQ=%d txOutI=%d txOutQ=%d dbg1I=%d dbg1Q=%d\n", clk, modValidCount, (int)t->modI, (int)t->modQ, (int)t->txOutI, (int)t->txOutQ, (int)t->dbg1I, (int)t->dbg1Q);
        }
    }
    printf("TOTAL modValidCount=%ld over %ld clocks, frameStarts(cnt)=%ld\n", modValidCount, total, frameStarts);
    delete t;
    return 0;
}
