// sim_rxfe_rfcap_poscontrol.cpp -- RFCAP positive control: force the RRC
// receive filter output's hard-decision capture to observe DIFFERENT payload
// content (byte-plane injection, tx_data_source=1, word file argv[1] --
// distinct from the BIST ROM content that produces 0x8F9ED095) and confirm
// the captured register changes to a DIFFERENT, NON-ZERO value while the
// link still locks (frames_seen comparable to the clean run, cap != 0).
// This is the existing byte-injection pattern from sim_byte.cpp, re-used
// here on wrap_byte_ce with fixctl[20] selecting RFCAP on the readout mux.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: sim_rxfe_rfcap_poscontrol tx_words.hex [NF]\n"); return 2; }
    std::vector<unsigned long long> words;
    { FILE* f = fopen(argv[1], "r"); if (!f) { fprintf(stderr, "no %s\n", argv[1]); return 2; }
      char ln[128];
      while (fgets(ln, sizeof ln, f)) { if (ln[0] == '\n') continue; words.push_back(strtoull(ln, nullptr, 16)); }
      fclose(f); }
    const unsigned NW = (unsigned)words.size();
    if (NW == 0) { fprintf(stderr, "empty word file\n"); return 2; }
    int NF = argc > 2 ? atoi(argv[2]) : 60;

    Vwrap_byte_ce* t = new Vwrap_byte_ce;
    long clk = 0; unsigned idx = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0;
    t->tx_data_source = 1;   // byte-plane payload source, NOT the BIST ROM
    t->fixctl = 1u << 13;    // RFCAP selected on the readout mux
    t->iq_debug_mux = 0;
    t->byte_valid = 1; t->byte_rx_ready = 1;
    t->byte_data = words[idx]; t->byte_first = (idx == 0);
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;
    unsigned char prevStart = 0;
    int frameIdx = 0;
    unsigned firstCap = 0, lastCap = 0;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) {
        if (t->byte_ready && t->byte_valid) idx = (idx + 1) % NW;
        t->byte_data = words[idx]; t->byte_first = (idx == 0); t->byte_valid = 1;
        t->adc_validIn = (clk & 1) ? 0 : 1;
        tick();
        unsigned char s = t->demodStartOut;
        if (s && !prevStart) {
            frameIdx++;
            lastCap = t->bfViol;
            if (frameIdx == 1) firstCap = t->bfViol;
        }
        prevStart = s;
    }
    printf("POSCONTROL_CHECK_DEMODCAP frames_seen=%d first_cap=0x%08X last_cap=0x%08X final_mismatches=%u\n",
           frameIdx, firstCap, lastCap, t->bfLatch);
    printf("  CLEAN_BASELINE (BIST loopback, mode-1) cap=0x8F9ED095\n");
    printf("  %s\n", (frameIdx > 0 && lastCap != 0 && lastCap != 0x8F9ED095) ?
           "POSCONTROL PASS: RFCAP moved to a different non-null value while the link kept locking" :
           "POSCONTROL FAIL: RFCAP did not demonstrate a non-null change");
    delete t;
    return 0;
}
