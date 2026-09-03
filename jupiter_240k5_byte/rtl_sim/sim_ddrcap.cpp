// sim_ddrcap.cpp -- DDR raw-capture sim gate (Task 2 of the DDR raw capture
// plan, docs/superpowers/plans/2026-08-31-ddr-raw-capture.md).
//
// Modelled on sim_final.cpp (frame-invariance gate) and sim_rxfe_democheck.cpp
// (byte-plane positive-control pattern). Exercises the 12-way ddrcap tap mux
// added by ddrcap_inject.py, driven purely through REAL top-level ports on
// wrap_byte_ddrcap.v (no Verilator hierarchical references), per the TX-INT
// report's finding that hierarchical refs can read dead copies.
//
// PART A -- per-selector sim gate (0-11), clean mode-1 BIST loopback:
//   - ddrcap_i/q not identically zero across the whole run (a tap reading
//     zero is the exact TX-INT QPSK_Modulator failure mode -- selector 7 is
//     PRE-WARNED to reproduce it and is reported honestly, not patched over).
//   - ddrcap_mark_demod and ddrcap_mark_fec each show exactly one CAPTURED
//     high beat per frame, counted only on cycles where ddrcap_valid is
//     asserted (per the Global Constraints: a strobe that lands on a
//     non-captured cycle and is silently dropped is the exact failure this
//     build exists to prevent). cnt_frame_start (already an existing,
//     trusted top-level counter) is the ground truth for frame count.
//
// PART B -- positive control, three selectors spanning sample/symbol/bit
// domains (0 dataIn, 6 constellation, 11 scrambler out): true register poke
// (tx_data_source select between the golden and perturbed byte-plane word
// files, same mechanism as sim_rxfe_democheck.cpp's RFCAP positive control)
// rather than a recomputed net. Reports before/after captured values.
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cmath>

static std::vector<unsigned long long> load_words(const char* path) {
    std::vector<unsigned long long> w;
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "no %s\n", path); return w; }
    char ln[128];
    while (fgets(ln, sizeof ln, f)) {
        if (ln[0] == '\n') continue;
        w.push_back(strtoull(ln, nullptr, 16));
    }
    fclose(f);
    return w;
}

struct GateResult {
    bool any_nonzero = false;
    unsigned frames_final = 0;
    unsigned demod_marks_captured = 0;
    unsigned fec_marks_captured = 0;
    unsigned valid_beats = 0;
    // Beats between consecutive CAPTURED demod-marker pulses, i.e. exact
    // per-frame beat counts with the acquisition prologue (before the first
    // marker) excluded. Re-review finding 4: valid_beats/frames_final is
    // prologue-biased -- a free-running chain valid accumulates thousands of
    // beats before its first marker while a packet-gated valid accumulates
    // almost none, so the SAME true rate reads very differently depending on
    // which valid a selector happens to use. Mark-to-mark spacing has no
    // such bias and should be exactly constant frame to frame (min == max).
    std::vector<unsigned> mark_intervals;
};

// Runs a clean mode-1 BIST loopback at the given selector for NF frames.
static GateResult run_gate(unsigned sel, int NF) {
    GateResult r;
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->fixctl = 0; t->iq_debug_mux = (sel & 0xFu) << 16;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    unsigned beats_since_mark = 0;
    bool seen_first_mark = false;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) {
        tick();
        if (t->ddrcap_valid) {
            r.valid_beats++;
            beats_since_mark++;
            if ((short)t->ddrcap_i != 0 || (short)t->ddrcap_q != 0) r.any_nonzero = true;
            bool demod_hit = (t->ddrcap_mark_demod == 0x7FFF);
            if (demod_hit) {
                r.demod_marks_captured++;
                if (seen_first_mark) r.mark_intervals.push_back(beats_since_mark);
                seen_first_mark = true;
                beats_since_mark = 0;
            }
            if (t->ddrcap_mark_fec == 0x7FFF) r.fec_marks_captured++;
        }
    }
    r.frames_final = t->cnt_frame_start;
    delete t;
    return r;
}

struct PcResult {
    bool ok = false;
    int diverge_idx = -1;
    unsigned short golden_i = 0, golden_q = 0;
    unsigned short pert_i = 0, pert_q = 0;
    bool golden_alive = false, pert_alive = false;
};

// Captures the first NCAP valid ddrcap_i/q words after a warm-up of NWARM
// frames, using byte-plane injection from `words` (tx_data_source=1).
static void capture_words(unsigned sel, const std::vector<unsigned long long>& words,
                           int NWARM, int NCAP, std::vector<unsigned short>& outI,
                           std::vector<unsigned short>& outQ) {
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap;
    long clk = 0; unsigned idx = 0;
    const unsigned NW = (unsigned)words.size();
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0;
    t->tx_data_source = 1;
    t->fixctl = 0; t->iq_debug_mux = (sel & 0xFu) << 16;
    t->byte_valid = 1; t->byte_rx_ready = 1;
    t->byte_data = words[idx]; t->byte_first = (idx == 0);
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    unsigned frameIdx = 0, prevFrames = 0;
    // Bounded independent of NCAP (NCAP counts WORDS, not frames) so a
    // selector that never asserts ddrcap_valid degrades to "fewer than
    // NCAP words captured" rather than an effectively unbounded run.
    long total = 100 + (long)(NWARM + 24) * 197328;
    while (clk < total && (int)outI.size() < NCAP) {
        if (t->byte_ready && t->byte_valid) idx = (idx + 1) % NW;
        t->byte_data = words[idx]; t->byte_first = (idx == 0); t->byte_valid = 1;
        tick();
        frameIdx = t->cnt_frame_start;
        if (frameIdx > (unsigned)NWARM && t->ddrcap_valid) {
            outI.push_back((unsigned short)t->ddrcap_i);
            outQ.push_back((unsigned short)t->ddrcap_q);
        }
        prevFrames = frameIdx;
    }
    (void)prevFrames;
    delete t;
}

static PcResult run_poscontrol(unsigned sel, const char* golden_path, const char* pert_path) {
    PcResult r;
    auto golden = load_words(golden_path);
    auto pert = load_words(pert_path);
    if (golden.empty() || pert.empty()) return r;

    std::vector<unsigned short> gi, gq, pi, pq;
    // NCAP must be large enough to run past the frame preamble/sync-word
    // region, which is IDENTICAL in both the golden and perturbed word
    // files -- an early sim run with NCAP=8 found NO divergence for the
    // sample-domain (sel0) and bit-domain (sel11) taps for exactly this
    // reason (both capture at the very start of the frame, still inside the
    // fixed preamble), while the symbol-domain tap (sel6, post-synchronizer,
    // preamble already stripped) diverged immediately. NCAP=4000 covers
    // several times the sample-domain preamble length while still being a
    // small fraction of a sample-domain frame (~49k words), so the capture
    // window reaches into payload for every domain without materially
    // increasing runtime (the loop exits as soon as NCAP words are seen).
    const int NWARM = 8, NCAP = 4000;
    capture_words(sel, golden, NWARM, NCAP, gi, gq);
    capture_words(sel, pert, NWARM, NCAP, pi, pq);

    for (auto v : gi) if (v != 0) r.golden_alive = true;
    for (auto v : gq) if (v != 0) r.golden_alive = true;
    for (auto v : pi) if (v != 0) r.pert_alive = true;
    for (auto v : pq) if (v != 0) r.pert_alive = true;

    int n = (int)std::min(gi.size(), pi.size());
    for (int i = 0; i < n; i++) {
        if (gi[i] != pi[i] || gq[i] != pq[i]) {
            r.diverge_idx = i;
            r.golden_i = gi[i]; r.golden_q = gq[i];
            r.pert_i = pi[i]; r.pert_q = pq[i];
            break;
        }
    }
    r.ok = (r.diverge_idx >= 0) && r.golden_alive && r.pert_alive;
    return r;
}

static const char* SEL_NAME[12] = {
    "dataIn (TX loopback, sample)", "AGC out (sample)", "RRC rx filter out (sample)",
    "postSymbolSync (symbol)", "postCoarseFreq (symbol)", "postCarrierSync (symbol)",
    "QPSKConstellationPoints (symbol, demod in)", "QPSK_Modulator out (TX, symbol)",
    "TX RRC out (sample)", "demod coded bits (bit, packed)", "FEC bitsIn (bit, packed)",
    "Bit_Packetizer/Scrambler out (TX, bit, packed)"
};

// Per-selector beats-per-frame assertion against the domain's OWN a priori
// expected rate (review finding 4), using an UNBIASED mark-to-mark estimator
// rather than valid_beats/frames_final.
//
// CORRECTION (fix round 2): the constants in the original version of this
// check (symbol=1,120, bit=140) were wrong by ~11x -- they used the DECODED
// MESSAGE length (2,240 payload bits) as if it were the TRANSMITTED FRAME's
// symbol count. The plan's own spec states the real number directly
// (docs/superpowers/plans/2026-08-31-ddr-raw-capture.md:220): "~49,349
// words for sample-domain selectors, ~12,337 for symbol-domain" -- the
// transmitted frame carries far more symbols than the decoded message after
// FEC/preamble/padding are accounted for. The "11x oversampling" this
// assertion originally reported was that single wrong constant, not a
// property of any signal; RETRACTED (see the fix-round-2 report). Every
// downstream-of-the-decimator valid in this design is structurally a shift
// register of the one above it and cannot pulse faster than the symbol
// rate; three independent lines of evidence (structural, arithmetic ratios
// immune to any frame-count bias, and the spec's own stated number) all
// converge on ONE beat per symbol.
//
// The estimator was ALSO biased: valid_beats/frames_final counts the
// acquisition prologue (all beats before the very first marker) as part of
// the frame average, and that prologue is selector-dependent -- a
// free-running chain valid (e.g. the old sel5) accumulates thousands of
// beats before its first marker, a packet-gated valid (sel6) accumulates
// almost none, so the SAME true rate reads very differently depending on
// which valid a selector uses. Mark-to-mark spacing (beats strictly BETWEEN
// two consecutive captured demod-marker pulses) has no such bias and is
// exactly constant frame to frame in a clean loopback (min == max).
struct DomainRef { unsigned sel; const char* domain; double expected_per_frame; double tol; };
static DomainRef DOMAIN_REFS[] = {
    {0,  "sample",  49349.0, 0.10}, {1,  "sample",  49349.0, 0.10},
    {2,  "sample",  49349.0, 0.10}, {8,  "sample",  49349.0, 0.10},
    {3,  "symbol",  12337.0, 0.10}, {4,  "symbol",  12337.0, 0.10},
    {5,  "symbol",  12337.0, 0.10}, {6,  "symbol",  12337.0, 0.10},
    {9,  "bit",       1542.0, 0.15}, {10, "bit",       1542.0, 0.15},
    {11, "bit",       1542.0, 0.15},
    // sel7 excluded: already declared dead (identically zero), a rate check
    // on a dead tap is meaningless.
};

static bool check_domain_rates(const GateResult results[12]) {
    bool all_ok = true;
    for (auto& r : DOMAIN_REFS) {
        const GateResult& g = results[r.sel];
        const auto& iv = g.mark_intervals;
        double rate = 0.0;
        unsigned mn = 0, mx = 0;
        bool exact = false;
        if (!iv.empty()) {
            mn = mx = iv[0];
            unsigned long sum = 0;
            for (unsigned v : iv) { if (v < mn) mn = v; if (v > mx) mx = v; sum += v; }
            rate = (double)sum / iv.size();
            exact = (mn == mx);
        }
        double dev = r.expected_per_frame > 0 ? fabs(rate - r.expected_per_frame) / r.expected_per_frame : 1.0;
        bool ok = !iv.empty() && dev <= r.tol;
        if (!ok) all_ok = false;
        printf("  sel%-2u %-7s mark-to-mark=%9.1f/frame (n=%zu min=%u max=%u %s) expected=%9.1f/frame ratio=%5.2fx  %s\n",
               r.sel, r.domain, rate, iv.size(), mn, mx, exact ? "EXACT" : "VARIES",
               r.expected_per_frame, r.expected_per_frame > 0 ? rate / r.expected_per_frame : 0.0,
               ok ? "PASS" : "FAIL");
    }
    return all_ok;
}

// PART C (review finding 5): both iq_debug_mux nibbles nonzero at once,
// demonstrating that the legacy [3:0] DBGCAP decode and the new [19:16]
// ddrcap decode really do run simultaneously off the same register, which
// is what Task 5's ddrcap-sel-6-vs-DBGCAP-tap-3 cross-check depends on.
// Low nibble = 3 (DBGCAP tap3, the golden-digest selector from sim_final.cpp);
// high nibble = 6 (ddrcap constellation). Runs long enough to pass the
// frame-8 reference/mismatch-latch acquisition transient DBGCAP itself uses.
static bool run_dual_nibble_case(int NF) {
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap;
    long clk = 0;
    t->reset = 1; t->clk_enable = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 0; t->skip_count = 0; t->tx_data_source = 0;
    t->fixctl = 0;
    // low nibble (DBGCAP legacy) must be written AFTER the reset the same
    // way the AXI register would be, per the runbook's own documented
    // footgun -- but this is a fresh Verilator instance driven from t=0, so
    // simply asserting it once reset deasserts is equivalent and simpler.
    t->iq_debug_mux = (6u << 16) | 3u;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    bool ddrcap_nonzero = false;
    unsigned ddrcap_demod_marks = 0, ddrcap_fec_marks = 0;
    long total = 100 + (long)(NF + 4) * 197328;
    while (clk < total) {
        tick();
        if (t->ddrcap_valid) {
            if ((short)t->ddrcap_i != 0 || (short)t->ddrcap_q != 0) ddrcap_nonzero = true;
            if (t->ddrcap_mark_demod == 0x7FFF) ddrcap_demod_marks++;
            if (t->ddrcap_mark_fec == 0x7FFF) ddrcap_fec_marks++;
        }
    }
    unsigned frames = t->cnt_frame_start;
    unsigned dbgcap_mismatches = t->bfLatch;
    unsigned dbgcap_capture = t->bfViol;
    delete t;

    bool ddrcap_ok = ddrcap_nonzero && frames > 0 &&
        (ddrcap_demod_marks + 1 >= frames) && (ddrcap_demod_marks <= frames + 1) &&
        (ddrcap_fec_marks + 1 >= frames) && (ddrcap_fec_marks <= frames + 1);
    // re-review finding 5: bfLatch==0 alone is non-discriminating -- a [3:0]
    // narrowing bug that silently redirects DBGCAP onto its P1cDtc fallback
    // tap would ALSO read frame-invariant (mismatches stay 0 on a stuck/dead
    // tap just as readily as on a working one), so that alone cannot tell
    // "narrowing works" from "narrowing quietly selects the wrong tap" --
    // exactly what this test exists to demonstrate. Assert the actual
    // captured digest equals the known golden value instead (a null not yet
    // shown capable of a non-null does not count, per the standing rule).
    bool dbgcap_ok = (dbgcap_mismatches == 0) && (dbgcap_capture == 0xBCF94856u);
    printf("  low nibble=3 (DBGCAP tap3, legacy): cap=0x%08X (want 0xBCF94856) mismatches=%u vs frame-8 reference  %s\n",
           dbgcap_capture, dbgcap_mismatches, dbgcap_ok ? "PASS" : "FAIL");
    printf("  high nibble=6 (ddrcap constellation): nonzero=%s frames=%u demod_marks=%u fec_marks=%u  %s\n",
           ddrcap_nonzero ? "yes" : "NO", frames, ddrcap_demod_marks, ddrcap_fec_marks,
           ddrcap_ok ? "PASS" : "FAIL");
    return ddrcap_ok && dbgcap_ok;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int NF = argc > 1 ? atoi(argv[1]) : 10;

    printf("=== PART A: per-selector sim gate (NF=%d) ===\n", NF);
    int gate_bad = 0;
    GateResult results[12];
    for (unsigned sel = 0; sel < 12; sel++) {
        GateResult r = run_gate(sel, NF);
        results[sel] = r;
        // allow +/-1 frame slack around start/end transients
        bool demod_ok = r.frames_final > 0 &&
            (r.demod_marks_captured + 1 >= r.frames_final) && (r.demod_marks_captured <= r.frames_final + 1);
        bool fec_ok = r.frames_final > 0 &&
            (r.fec_marks_captured + 1 >= r.frames_final) && (r.fec_marks_captured <= r.frames_final + 1);
        bool ok = r.any_nonzero && demod_ok && fec_ok;
        if (!ok) gate_bad++;
        printf("  sel%-2u %-45s nonzero=%-3s frames=%u demod_marks=%u fec_marks=%u valid_beats=%u  %s\n",
               sel, SEL_NAME[sel], r.any_nonzero ? "yes" : "NO",
               r.frames_final, r.demod_marks_captured, r.fec_marks_captured, r.valid_beats,
               ok ? "PASS" : "FAIL");
        fflush(stdout);
    }
    printf("PART_A_GATE %s (%d/12 selectors failed)\n", gate_bad ? "SOME_FAIL" : "ALL_PASS", gate_bad);

    printf("\n=== PART A2: per-selector beats-per-frame vs absolute domain reference rate ===\n");
    bool domain_ok = check_domain_rates(results);
    printf("PART_A2_DOMAIN_RATE %s\n", domain_ok ? "PASS" : "FAIL");
    fflush(stdout);

    printf("\n=== PART B: positive control (true register poke via tx_data_source) ===\n");
    struct PcCase { unsigned sel; const char* domain; };
    PcCase cases[] = {
        {0, "sample-domain"},
        {6, "symbol-domain"},
        {11, "bit-domain"},
    };
    int pc_bad = 0;
    for (auto& c : cases) {
        PcResult r = run_poscontrol(c.sel, "tx_words_golden.hex", "tx_words_perturbed.hex");
        if (!r.ok) pc_bad++;
        printf("  sel%-2u %-13s %-45s %s\n", c.sel, c.domain, SEL_NAME[c.sel], r.ok ? "PASS" : "FAIL");
        if (r.diverge_idx >= 0) {
            printf("    diverged at capture[%d]: golden I/Q=0x%04X/0x%04X  perturbed I/Q=0x%04X/0x%04X\n",
                   r.diverge_idx, r.golden_i, r.golden_q, r.pert_i, r.pert_q);
            fflush(stdout);
        } else {
            printf("    NO DIVERGENCE OBSERVED (golden_alive=%d pert_alive=%d) -- selector did not move\n",
                   r.golden_alive, r.pert_alive);
            fflush(stdout);
        }
    }
    printf("PART_B_POSCONTROL %s (%d/3 cases failed)\n", pc_bad ? "SOME_FAIL" : "ALL_PASS", pc_bad);

    printf("\n=== PART C: simultaneous-decode demonstration (both iq_debug_mux nibbles nonzero) ===\n");
    bool dual_ok = run_dual_nibble_case(NF);
    printf("PART_C_DUAL_NIBBLE %s\n", dual_ok ? "PASS" : "FAIL");
    fflush(stdout);

    bool overall_fail = gate_bad || !domain_ok || pc_bad || !dual_ok;
    printf("\nDDRCAP_GATE %s\n", overall_fail ? "FAIL" : "PASS");
    return overall_fail ? 1 : 0;
}
