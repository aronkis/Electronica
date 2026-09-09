// sim_rxfe_rfcap_adc.cpp -- RFCAP positive control, ADC-entry variant.
// The byte-plane payload perturbation (tx_data_source=1) was checked against
// DEMODCAP (a witness with an ESTABLISHED, content-sensitive golden value)
// and produced ZERO change there too -- proving that knob does not reach the
// modulated content in this composite/wrapper, not that RFCAP is inert. This
// harness instead replays the existing recorded RF capture
// s1_tx_air_240k5.iq through the REAL ADC front door (rx_input_select=1,
// paced cadence, per the existing sim_byte_taps_e5.cpp pattern) as a
// genuinely different signal entry (AGC operates on real quantized samples
// rather than the ideal internal digital loopback), looping the buffer to
// cover the requested frame count.
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* iqf = argc > 1 ? argv[1] : "s1_tx_air_240k5.iq";
    int cadence = argc > 2 ? atoi(argv[2]) : 4;
    int NF = argc > 3 ? atoi(argv[3]) : 10;
    FILE* fi = fopen(iqf, "rb");
    if (!fi) { fprintf(stderr, "cannot open %s\n", iqf); return 2; }
    fseek(fi, 0, SEEK_END); long bytes = ftell(fi); fseek(fi, 0, SEEK_SET);
    long nsamp = bytes / 4; // 2 int16 per sample
    std::vector<short> iq(2 * nsamp);
    long got = fread(iq.data(), 2, 2 * nsamp, fi); fclose(fi);
    if (got / 2 < nsamp) nsamp = got / 2;
    if (nsamp < 1) { fprintf(stderr, "empty iq file\n"); return 2; }

    Vwrap_byte_ce* t = new Vwrap_byte_ce;
    long clk = 0, sidx = 0; int ph = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 1; t->skip_count = 0; t->tx_data_source = 0;
    t->fixctl = 1u << 20; t->iq_debug_mux = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;
    unsigned char prevStart = 0;
    int frameIdx = 0; unsigned lastCap = 0;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) {
        if (ph == 0) {
            t->adc_dataInI = iq[2 * (sidx % nsamp)];
            t->adc_dataInQ = iq[2 * (sidx % nsamp) + 1];
            t->adc_validIn = 1;
            sidx++;
        } else t->adc_validIn = 0;
        ph = (ph + 1) % cadence;
        tick();
        unsigned char s = t->demodStartOut;
        if (s && !prevStart) { frameIdx++; lastCap = t->bfViol; }
        prevStart = s;
    }
    printf("ADC_POSCONTROL_RFCAP frames_seen=%d last_cap=0x%08X final_mismatches=%u\n",
           frameIdx, lastCap, t->bfLatch);
    printf("  CLEAN_BASELINE (BIST internal loopback, mode-1) cap=0x5EA9540A\n");
    printf("  %s\n", (frameIdx > 0 && lastCap != 0 && lastCap != 0x5EA9540A) ?
           "POSCONTROL PASS: RFCAP moved to a different non-null value under a different signal entry path" :
           "POSCONTROL INCONCLUSIVE/FAIL");
    delete t;
    return 0;
}
