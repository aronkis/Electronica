// sim_rxfe.cpp -- gate for the RX-FE image: RRC receive filter output
// (fixctl[20]) + coarse frequency compensator output (fixctl[21]), on top of
// the carried-forward TXCAP (fixctl[12]) + DEMODCAP (fixctl[13]) + DBGCAP
// (iq_debug_mux) witnesses. PRE-REGISTERED: all must be frame-invariant
// (0 mismatches) on a clean run, else that witness is uncovered.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
struct Cfg { const char* name; unsigned fixctl; unsigned mux; };
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int NF = argc > 1 ? atoi(argv[1]) : 10;
    Cfg cfgs[] = {
        {"TXCAP     (transmitter, TX-anchored)", 1u << 12, 0},
        {"DEMODCAP  (demod bits, demod-anchored)", 1u << 13, 0},
        {"RFCAP     (RRC receive filter out)", 1u << 20, 0},
        {"CFCAP     (coarse freq compensator out)", 1u << 21, 0},
        {"DBGCAP    tap3 constellation", 0, 3},
    };
    int bad = 0;
    for (auto& c : cfgs) {
        Vwrap_byte_ce* t = new Vwrap_byte_ce;
        long clk = 0;
        t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
        t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
        t->fixctl = c.fixctl; t->iq_debug_mux = c.mux;
        t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
        auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
        for (int i = 0; i < 100; i++) tick();
        t->reset = 0;
        long total = 100 + (long)(NF + 4) * 197328;
        while (clk < total) tick();
        printf("  %-40s cap=0x%08X mismatches=%u  cap_in=0x%08X%s\n",
               c.name, t->bfViol, t->bfLatch, t->cap_in, t->bfLatch ? "  <== NOT INVARIANT" : "");
        if (t->bfLatch) bad++;
        delete t;
    }
    printf("RXFE_GATE %s (%d/5 witnesses not frame-invariant)\n", bad ? "FAIL" : "PASS", bad);
    return 0;
}
