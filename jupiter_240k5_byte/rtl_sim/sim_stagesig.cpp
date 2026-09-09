// sim_stagesig.cpp -- PRE-BUILD GATE for the stage-signature witness (2026-08-30).
//
// The witness adds seven per-frame rotate-XOR signatures across the RX chain plus a
// per-stage mismatch counter, read back on beatfix_viol_count/latch (0x20C/0x210) and
// selected by fixctl[11:8]. All seven counters accumulate simultaneously; only the
// readout is muxed, so one sweep at the end reads every stage.
//
// PRE-REGISTERED GATE (this run): on a CLEAN loopback every mismatch counter must be 0.
// A stage that is nonzero when healthy has no frame-invariant signature and therefore
// gets NO coverage on hardware -- it must be reported as uncovered, never interpreted.
// Stages 3 and 4 (postSymbolSync / postCarrierSync) carry loop state and are the ones
// genuinely at risk; 0/1/2 and 5/6 should be invariant if the loopback is deterministic.
//
// argv: sim_stagesig NF prefix
#include "Vwrap_byte_ce.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static const char* SNAME[7] = {
    "0 dataIn      (RX in == TX modulator out)",
    "1 AGC out",
    "2 RRC matched-filter out",
    "3 postSymbolSync (timing recovery)",
    "4 postCarrierSync (carrier recovery)",
    "5 QPSKConstellation (FTS out == demod in)",
    "6 demod dataOut (coded bits)"
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: sim_stagesig NF prefix\n"); return 2; }
    int NF = atoi(argv[1]); const char* pfx = argv[2];
    char fn[512]; snprintf(fn, sizeof fn, "%s_frames.txt", pfx); FILE* ff = fopen(fn, "w");

    Vwrap_byte_ce* t = new Vwrap_byte_ce;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0; t->fixctl = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    unsigned lastPk = 0, lastErr = 0;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) {
        tick();
        if (t->packets_out != lastPk) {
            fprintf(ff, "%u %u\n", t->packets_out, t->bit_errors_out - lastErr);
            lastPk = t->packets_out; lastErr = t->bit_errors_out;
        }
    }

    // ---- sweep the readout selector: fixctl[11:8] = stage ----
    printf("STAGESIG NF=%d packets=%u biterr=%u\n", NF, t->packets_out, t->bit_errors_out);
    printf("  %-44s %-12s %s\n", "stage", "signature", "mismatches");
    int bad = 0;
    for (int s = 0; s < 7; s++) {
        t->fixctl = (unsigned)s << 8;
        for (int i = 0; i < 4; i++) tick();      // settle the combinational mux
        unsigned sig = t->bfViol, mm = t->bfLatch;
        printf("  %-44s 0x%08X   %u%s\n", SNAME[s], sig, mm, mm ? "   <== NOT FRAME-INVARIANT" : "");
        fprintf(ff, "# STAGE %d sig=0x%08X mm=%u\n", s, sig, mm);
        if (mm) bad++;
    }
    t->fixctl = 0;
    printf("STAGESIG_GATE %s  (%d/7 stages not frame-invariant on a clean run)\n",
           bad ? "PARTIAL" : "PASS", bad);
    fclose(ff); delete t; return 0;
}
