// sim_w1_census.cpp -- [sim] Task 9: standalone unit test of rh_w1_census, the
// RXFIX_W1 witness/census block, extracted VERBATIM from the patched
// Frequency_and_Time_Synchronizer.v by build_w1_census.sh.
//
// Tests, in order:
//   T1 reset clears every output
//   T2 counters advance ONLY on enb (a beat with enb=0 must not count)
//   T3 each of the six valid inputs increments its own counter and no other
//   T4 witA packs {16'b0, occ[5:0], pushPtr[4:0], popPtr[4:0]}
//   T5 witB packs {pushFullCount[31:16], popEmptyCount[15:0]}
//   T6 FREEZE: while freeze=1 every shadow word HOLDS while the live counters
//      keep running; on release every word jumps to the value the live counters
//      reached.  This is the semantics w1_read.sh depends on for a coherent
//      eight-word snapshot, and it cannot be tested through the full DUT (the
//      s1_rtl Verilator lineage has no fixctl register to drive).
//   T7 the 16-bit edge counters wrap rather than saturate (documented behaviour)
#include "Vrh_w1_census.h"
#include "verilated.h"
#include <cstdio>
static int fails=0;
static void chk(const char* what, unsigned got, unsigned want){
    if(got!=want){ printf("FAIL %-38s got=%u want=%u\n",what,got,want); fails++; }
    else          printf("ok   %-38s %u\n",what,got); }

int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    Vrh_w1_census* t=new Vrh_w1_census;
    auto set0=[&](){ t->enb=0; t->freeze=0; t->occ=0; t->pushPtr=0; t->popPtr=0;
                     t->popEmpty=0; t->pushFull=0;
                     t->vSS=0; t->vRH=0; t->vCFC=0; t->vCS=0; t->vPD=0; t->vPC=0; };
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); };
    set0(); t->reset=1; tick(); tick(); t->reset=0; tick();

    // T1
    chk("T1 witA after reset", t->witA, 0);
    chk("T1 witB after reset", t->witB, 0);
    chk("T1 cSS after reset",  t->cSS, 0);
    chk("T1 cPC after reset",  t->cPC, 0);

    // T2: enb low must not count
    set0(); t->vSS=1; t->vPC=1; t->enb=0;
    for(int i=0;i<10;i++) tick();
    chk("T2 cSS with enb=0", t->cSS, 0);
    chk("T2 cPC with enb=0", t->cPC, 0);

    // T3: each valid drives exactly its own counter
    set0(); t->enb=1;
    t->vSS=1;  for(int i=0;i<3;i++) tick(); t->vSS=0;
    t->vRH=1;  for(int i=0;i<5;i++) tick(); t->vRH=0;
    t->vCFC=1; for(int i=0;i<7;i++) tick(); t->vCFC=0;
    t->vCS=1;  for(int i=0;i<11;i++) tick(); t->vCS=0;
    t->vPD=1;  for(int i=0;i<13;i++) tick(); t->vPD=0;
    t->vPC=1;  for(int i=0;i<17;i++) tick(); t->vPC=0;
    tick();   // let the last shadow catch up
    chk("T3 cSS",  t->cSS,  3);
    chk("T3 cRH",  t->cRH,  5);
    chk("T3 cCFC", t->cCFC, 7);
    chk("T3 cCS",  t->cCS, 11);
    chk("T3 cPD",  t->cPD, 13);
    chk("T3 cPC",  t->cPC, 17);

    // T4: witA packing.  occ=32 (FULL) must be distinguishable from occ=0.
    set0(); t->enb=1; t->occ=32; t->pushPtr=17; t->popPtr=5; tick(); tick();
    chk("T4 witA occ=32 push=17 pop=5", t->witA, (32u<<10)|(17u<<5)|5u);
    t->occ=0; tick(); tick();
    chk("T4 witA occ=0  push=17 pop=5", t->witA, (0u<<10)|(17u<<5)|5u);

    // T5: witB packing
    set0(); t->enb=1;
    t->popEmpty=1; for(int i=0;i<4;i++) tick(); t->popEmpty=0;
    t->pushFull=1; for(int i=0;i<9;i++) tick(); t->pushFull=0;
    tick();
    chk("T5 witB {pof,poe}", t->witB, (9u<<16)|4u);

    // T6: FREEZE holds every shadow while the live counters keep running
    set0(); t->enb=1; t->occ=7; t->pushPtr=1; t->popPtr=2;
    t->vSS=1; t->vPC=1; for(int i=0;i<4;i++) tick();
    unsigned fA=t->witA, fSS=t->cSS, fPC=t->cPC;
    t->freeze=1;
    t->occ=31; t->pushPtr=30; t->popPtr=29;      // ring state moves under freeze
    for(int i=0;i<50;i++) tick();                 // 50 more counted beats
    chk("T6 witA held under freeze", t->witA, fA);
    chk("T6 cSS  held under freeze", t->cSS,  fSS);
    chk("T6 cPC  held under freeze", t->cPC,  fPC);
    t->freeze=0; tick(); tick();
    // the shadow lags the live counter by exactly one enb beat, so after 50
    // frozen beats plus two release beats it must have advanced by 52.
    chk("T6 cSS  after release", t->cSS,  fSS+52);
    chk("T6 cPC  after release", t->cPC,  fPC+52);
    chk("T6 witA after release", t->witA, (31u<<10)|(30u<<5)|29u);

    // T7: the 16-bit edge counters WRAP (deltas stay valid; they do not stick)
    set0(); t->enb=1; tick(); tick();
    unsigned poe0 = t->witB & 0xFFFFu;      // whatever the earlier tests left
    t->popEmpty=1;
    const int NW = 65541;                   // > 2^16, so it must wrap
    for(int i=0;i<NW;i++) tick();
    t->popEmpty=0; tick();                  // let the shadow catch the live count
    chk("T7 poe wraps at 65536", t->witB & 0xFFFFu, (poe0 + NW) & 0xFFFFu);

    printf("W1CENSUS_UNIT %s failures=%d\n", fails?"FAIL":"PASS", fails);
    delete t; return fails?1:0;
}
