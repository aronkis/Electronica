// sim_stagewin.cpp -- [sim] Task 11 falsifier dump driver (2026-09-04).
//
//   sim_stagewin <iq> <nsamp> <rstcs_end> <out.txt> [nevents] [W] [arm]
//     arm = "skip" (default) -> arm on a change of r3Skips  (an R3S steered SKIP)
//     arm = "hole"           -> arm on rhPopEmpty           (a baseline EMPTY edge)
//
// The brief's falsifier: if the frames still die around the steered skip, dump +/-W
// enb_1_2_0 beats around ONE skip at EVERY stage output and report which stage's
// behaviour first differs from a frame with no skip.  So each event emits TWO
// windows:
//
//   win=1   the +/-W beats around the event itself;
//   win=0   the +/-W beats at the SAME intra-frame phase exactly ONE AIR FRAME
//           (49,332 enb beats) earlier -- a matched no-skip reference, because
//           skips are >= 2 air frames apart on every leg in the gate.
//
// Comparing win=0 and win=1 row by row is the measurement; nothing here is scored.
//
// This is a NEW file, deliberately: Task 7's sim_sro.cpp is used UNMODIFIED for the
// gate legs, which is what makes the n_p000 md5 identity gate a test of the RTL.
#include "Vwrap_byte_sro.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static const long FRSAMP = 49332;      // input samples per air frame
static const long FRBEAT = 49332;      // enb_1_2_0 beats per air frame (1 per sample)

struct Rec {
    long sidx, beat;
    int occ, vpush, vpop, popEmpty, pushFull, phase;   // Rate_Handle ring
    int rhOutI, rhOutQ, rhVOut;                        // Rate_Handle out
    int cfcI, cfcQ, cfcV; int cfcEst;                  // CFC
    int csI, csQ, csV;                                 // Carrier_Synchronizer
    int pdI, pdQ, pdV;                                 // Preamble_Detector out
    int corrV; long corrD, corrT, psRmax;              // Correlator
    int tref, psTrefRaw, psToff, psNewpk, toffVal;     // Peak_Search
    int taRef, taAcc, taArmed, taSync;                 // Timing_Adjust
    int pcI, pcQ, pcV, pcS, pcE, sdcAct;               // Packet_Controller
    unsigned r3sk, r3ar; int guard;                    // R3S witnesses
};

static void emit(FILE* fo, int ev, int win, long rel, const Rec& q) {
    fprintf(fo,
        "%d,%d,%ld,%ld,%ld,"
        "%d,%d,%d,%d,%d,%d,"
        "%d,%d,%d,"
        "%d,%d,%d,%d,"
        "%d,%d,%d,"
        "%d,%d,%d,"
        "%d,%ld,%ld,%ld,"
        "%d,%d,%d,%d,%d,"
        "%d,%d,%d,%d,"
        "%d,%d,%d,%d,%d,%d,"
        "%u,%u,%d\n",
        ev, win, rel, q.sidx, q.beat,
        q.occ, q.vpush, q.vpop, q.popEmpty, q.pushFull, q.phase,
        q.rhOutI, q.rhOutQ, q.rhVOut,
        q.cfcI, q.cfcQ, q.cfcV, q.cfcEst,
        q.csI, q.csQ, q.csV,
        q.pdI, q.pdQ, q.pdV,
        q.corrV, q.corrD, q.corrT, q.psRmax,
        q.tref, q.psTrefRaw, q.psToff, q.psNewpk, q.toffVal,
        q.taRef, q.taAcc, q.taArmed, q.taSync,
        q.pcI, q.pcQ, q.pcV, q.pcS, q.pcE, q.sdcAct,
        q.r3sk, q.r3ar, q.guard);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) {
        fprintf(stderr, "usage: sim_stagewin iq nsamp rstcs_end out.txt [nev] [W] [skip|hole]\n");
        return 2;
    }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    long rstcs_end  = atol(argv[3]);
    const char* outf = argv[4];
    int nev_max = (argc > 5) ? atoi(argv[5]) : 2;
    long W      = (argc > 6) ? atol(argv[6]) : 64;
    const char* armk = (argc > 7) ? argv[7] : "skip";
    // RXFIX_R4E (task 21): a THIRD arm mode.  The K8 falsifier fired -- every one of the
    // 37 scheduled push DROPS on n_p10 is aligned to a lost frame -- and the dump has to
    // be triggered on the DROP, which the harness carries on r3Extras (r4e_drops), not on
    // r3Skips (the EMPTY-side skip) or rhPopEmpty.  The two pre-existing modes are
    // untouched, so a "skip"/"hole" run of this binary is the task-11 driver.
    const int arm_on_drop = strcmp(armk, "drop") == 0;
    const int arm_on_skip = (!arm_on_drop) && strcmp(armk, "hole") != 0;

    FILE* fi = fopen(iqf, "rb");
    if (!fi) { fprintf(stderr, "cannot open %s\n", iqf); return 2; }
    std::vector<short> iq(2 * nsamp);
    long got = fread(iq.data(), 2, 2 * nsamp, fi); fclose(fi);
    if (got / 2 < nsamp) nsamp = got / 2;

    FILE* fo = fopen(outf, "w");
    if (!fo) { fprintf(stderr, "cannot write %s\n", outf); return 2; }
    fprintf(fo, "# ev,win,rel,sidx,beat,"
                "occ,vpush,vpop,popEmpty,pushFull,rhPhase,"
                "rhOutI,rhOutQ,rhValidOut,"
                "cfcI,cfcQ,cfcV,cfcEst,"
                "csI,csQ,csV,"
                "pdI,pdQ,pdV,"
                "corrV,corrD,corrThr,psRunmax,"
                "psTref,psTrefRaw,psToff,psNewpk,toffVal,"
                "taRef,taAcc,taArmed,taSync,"
                "pcI,pcQ,pcV,pcStart,pcEnd,sdcAct,"
                "r3sSkips,r3sArmed,guard\n");
    fprintf(fo, "# win=1 the event window; win=0 the SAME intra-frame phase one air "
                "frame (%ld enb beats) earlier, i.e. a matched no-event reference\n", FRBEAT);

    // rolling history: one air frame + 2W + slack, so the matched window is in reach
    const long HIST = FRBEAT + 4 * 64 + 8 + 2 * 64;
    std::vector<Rec> ring((size_t)(FRBEAT + 4 * (W + 4) + 16));
    const long RN = (long)ring.size();
    (void)HIST;

    Vwrap_byte_sro* t = new Vwrap_byte_sro;
    long clk = 0, sidx = 0, nbeat = 0; int ph = 0;
    const int cadence = 2, vphase = 0;
    t->reset = 1; t->adc_validIn = 0; t->adc_dataInI = 0; t->adc_dataInQ = 0;
    t->rstCS = 0; t->rx_input_select = 1; t->skip_count = 0; t->tx_data_source = 0;
    t->byte_valid = 0; t->byte_first = 0; t->byte_data = 0; t->byte_rx_ready = 1;
    t->tgen_sel = 0; t->tgen_ctrl = 0; t->tgen_gap = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); clk++; };
    for (int i = 0; i < 100; i++) tick();
    t->reset = 0;

    unsigned pvSk = 0, pvEx = 0; long pend = -1; int nev = 0;
    long total = 100 + nsamp * (long)cadence + 200000;
    while (clk < total && nev < nev_max) {
        if (ph == vphase) {
            if (sidx < nsamp) { t->adc_dataInI = iq[2 * sidx]; t->adc_dataInQ = iq[2 * sidx + 1];
                                t->adc_validIn = 1; sidx++; }
            else t->adc_validIn = 0;
        } else t->adc_validIn = 0;
        ph = (ph + 1) % cadence;
        t->rstCS = (clk > 400 && clk < rstcs_end) ? 1 : 0;
        tick();
        if (!t->railEnb) continue;

        Rec r;
        r.sidx = sidx; r.beat = nbeat;
        r.occ = (int)t->occTrue; r.vpush = (int)t->fifoVPush; r.vpop = (int)t->fifoVPop;
        r.popEmpty = (int)t->rhPopEmpty; r.pushFull = (int)t->rhPushFull;
        r.phase = (int)t->rhPhase;
        r.rhOutI = (int)(short)t->rhOutI; r.rhOutQ = (int)(short)t->rhOutQ;
        r.rhVOut = (int)t->rhValidOut;
        r.cfcI = (int)(short)t->cfcI; r.cfcQ = (int)(short)t->cfcQ; r.cfcV = (int)t->cfcV;
        r.cfcEst = (int)t->cfcEst;
        r.csI = (int)(short)t->csI; r.csQ = (int)(short)t->csQ; r.csV = (int)t->csV;
        r.pdI = (int)(short)t->pdI; r.pdQ = (int)(short)t->pdQ; r.pdV = (int)t->pdV;
        r.corrV = (int)t->corrV; r.corrD = (long)(int)t->corrD; r.corrT = (long)(int)t->corrT;
        r.psRmax = (long)(int)t->psRmax;
        r.tref = (int)t->tref; r.psTrefRaw = (int)t->psTrefRaw; r.psToff = (int)t->psToff;
        r.psNewpk = (int)t->psNewpk; r.toffVal = (int)t->toffVal;
        r.taRef = (int)t->taRef; r.taAcc = (int)t->taAcc; r.taArmed = (int)t->taArmed;
        r.taSync = (int)t->taSync;
        r.pcI = (int)(short)t->pcI; r.pcQ = (int)(short)t->pcQ; r.pcV = (int)t->pcV;
        r.pcS = (int)t->pcS; r.pcE = (int)t->pcE; r.sdcAct = (int)t->sdcAct;
        r.r3sk = t->r3Skips; r.r3ar = t->r3Extras; r.guard = (int)t->r3Guard;
        ring[(size_t)(nbeat % RN)] = r;

        int fire = arm_on_drop ? (t->r3Extras != pvEx)
                 : arm_on_skip ? (t->r3Skips != pvSk) : (int)t->rhPopEmpty;
        // the matched reference window must still be inside the ring
        if (fire && pend < 0 && nbeat > FRBEAT + W + 4) pend = nbeat;
        if (pend >= 0 && nbeat == pend + W) {
            for (long b = pend - FRBEAT - W; b <= pend - FRBEAT + W; b++)
                emit(fo, nev, 0, b - (pend - FRBEAT), ring[(size_t)(b % RN)]);
            for (long b = pend - W; b <= pend + W; b++)
                emit(fo, nev, 1, b - pend, ring[(size_t)(b % RN)]);
            nev++; pend = -1;
        }
        pvSk = t->r3Skips; pvEx = t->r3Extras;
        nbeat++;
    }
    fclose(fo);
    printf("STAGEWIN wrote %s events=%d beats=%ld arm=%s W=%ld\n",
           outf, nev, nbeat, arm_on_drop ? "drop" : arm_on_skip ? "skip" : "hole", W);
    delete t; return 0;
}
