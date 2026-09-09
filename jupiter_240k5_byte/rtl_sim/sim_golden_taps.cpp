// sim_golden_taps.cpp -- write one selector's DDR record stream from the TXMARK netlist in mode-1
// ROM loopback. Record = int16 [I, Q, mark_demod, mark_fec], little-endian, one per ddrcap_valid beat,
// starting after WARM frames. Frame index file: one line per TX-marker rise: "<cnt_frame_start> <record_index>".
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <memory>
static const long CLKS_PER_FRAME = 197328;
int main(int argc, char** argv){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->commandArgs(argc, argv);
    if(argc < 4){ fprintf(stderr, "usage: sim_golden_taps SEL NF OUT.bin [WARM=20]\n"); return 2; }
    unsigned sel = (unsigned)atoi(argv[1]); long NF = atol(argv[2]); const char* out = argv[3];
    long WARM = argc > 4 ? atol(argv[4]) : 20;
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()};
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0; t->fixctl = 0;
    t->iq_debug_mux = ((sel & 0xFu) << 16) | 3u;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    long clk = 0; auto tick = [&](){ t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for(int i = 0; i < 100; i++) tick(); t->reset = 0;
    FILE* fb = fopen(out, "wb"); char fn[512]; snprintf(fn, sizeof fn, "%s.frames.txt", out); FILE* fi = fopen(fn, "w");
    long total = 100 + (NF + 4) * CLKS_PER_FRAME; unsigned long rec = 0; bool prevMark = false; unsigned long nonzero = 0;
    while(clk < total){
        t->adc_validIn = (clk & 1) ? 0 : 1;
        tick();
        if(t->cnt_frame_start < (unsigned)WARM) continue;
        if(t->ddrcap_valid){
            short r[4] = { (short)t->ddrcap_i, (short)t->ddrcap_q, (short)t->ddrcap_mark_demod, (short)t->ddrcap_mark_fec };
            fwrite(r, sizeof r, 1, fb);
            if(r[0] || r[1]) nonzero++;
            bool m = (t->ddrcap_mark_fec == 0x7FFF);
            if(m && !prevMark) fprintf(fi, "%u %lu\n", (unsigned)t->cnt_frame_start, rec);
            prevMark = m; rec++;
        }
    }
    fclose(fb); fclose(fi);
    printf("GOLDEN sel=%u frames=%u records=%lu nonzero=%lu packets=%u biterr=%u\n", sel, (unsigned)t->cnt_frame_start, rec, nonzero, t->packets_out, t->bit_errors_out);
    delete t; return 0;
}
