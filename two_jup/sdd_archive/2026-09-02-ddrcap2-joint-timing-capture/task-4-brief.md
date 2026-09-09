### Task 4: Tier-1 sim gate (positive controls for every channel) — MUST PASS before the build

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp`
- Output: `jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log`; §80 appended to the session log

**Interfaces:**
- Consumes: `s1_rtl_ddrcap2` (Task 2), `wrap_byte_ddrcap.v` (unchanged), `build_ddrcap2_sim.sh` (Task 1). Flat build defines `DDRCAP2_FLAT`.
- Produces: a binary printing per-check `PASS|FAIL` lines and a final `DDRCAP2_GATE PASS|FAIL`; the log is the Tier-1 evidence.

- [ ] **Step 1: Write the gate driver**

```cpp
// sim_ddrcap2.cpp -- DDRCAP-v2 Tier-1 gate (spec sec 4). Mode-1 ROM loopback.
// PART A (both builds): for sel 0..15 (7 skipped=dead, 9-11 bit-domain): I/Q not all-zero (where expected),
//   exactly one demod + one TX marker bit per frame, slot cycles 0,1,2,3 on consecutive captured beats,
//   toff in [0,12332] and steady (one modal value >= 95% after frame 20) in clean loopback,
//   tref slot increments mod 12333, sel12 shows one dominant peak per frame.
// PART B (flat build only): hold-force each field for 128 clks and require the exact readback.
// PART C (both builds): sel14 differs between golden and perturbed TX word files (tx_data_source=1).
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#ifdef DDRCAP2_FLAT
#include "Vwrap_byte_ddrcap___024root.h"
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>
#include <map>
static const long CPF = 197328;
struct Rec { short i, q; unsigned short c2, c3; };
struct Run { std::vector<Rec> r; std::vector<unsigned> frame_of; unsigned frames = 0; };

static void init(Vwrap_byte_ddrcap* t, unsigned sel, unsigned txsrc){
    t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0; t->rstCS=0;
    t->rx_input_select=0; t->skip_count=0; t->tx_data_source=txsrc; t->fixctl=0;
    t->iq_debug_mux=((sel&0xF)<<16)|3; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
}
static std::vector<unsigned long long> words(const char* p){ std::vector<unsigned long long> w; FILE* f=fopen(p,"r"); char l[128];
    while(f && fgets(l,sizeof l,f)) if(l[0]!='\n') w.push_back(strtoull(l,nullptr,16)); if(f) fclose(f); return w; }

// Runs NF frames; optional TX word feed; optional force callback per clk (flat only).
template<class F> static Run run(unsigned sel, int NF, const std::vector<unsigned long long>* wf, F force){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()}; init(t, sel, wf?1:0);
    unsigned idx=0; long clk=0; auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    Run R; long total=100+(long)(NF+4)*CPF;
    while(clk<total){
        if(wf){ if(t->byte_ready && t->byte_valid) idx=(idx+1)%wf->size(); t->byte_data=(*wf)[idx]; t->byte_first=(idx==0); t->byte_valid=1; }
        t->adc_validIn=(clk&1)?0:1;
        force(t, clk, t->cnt_frame_start);
        tick();
        if(t->ddrcap_valid && t->cnt_frame_start>=20){
            R.r.push_back({(short)t->ddrcap_i,(short)t->ddrcap_q,(unsigned short)t->ddrcap_mark_demod,(unsigned short)t->ddrcap_mark_fec});
            R.frame_of.push_back(t->cnt_frame_start);
        }
    }
    R.frames=t->cnt_frame_start; delete t; return R;
}
static bool pr(const char* what, bool ok, const char* detail=""){ printf("  %-58s %s %s\n", what, ok?"PASS":"FAIL", detail); return ok; }

static bool partA(unsigned sel, const Run& R){
    char nm[96]; bool ok=true; unsigned n=R.r.size();
    snprintf(nm,sizeof nm,"sel%u records>0",sel); ok&=pr(nm,n>1000);
    if(n<1000) return false;
    unsigned nz=0, md=0, mf=0, slotok=0; std::map<unsigned,unsigned> toffh; int prevslot=-1; unsigned trefok=0, trefn=0; int prevtref=-1;
    for(unsigned k=0;k<n;k++){ const Rec& x=R.r[k]; if(x.i||x.q) nz++; if(x.c2>>15) md++; if((x.c2>>14)&1) mf++;
        toffh[x.c2&0x3FFF]++; int s=x.c3>>14; if(prevslot>=0 && s==((prevslot+1)&3)) slotok++; prevslot=s;
        if(s==1){ int tr=x.c3&0x3FFF; if(prevtref>=0){ trefn++; if(tr>prevtref || (prevtref>12000 && tr<400)) trefok++; } prevtref=tr; } }
    unsigned fr=R.frame_of.back()-R.frame_of.front();
    snprintf(nm,sizeof nm,"sel%u I/Q not all zero",sel); ok&=pr(nm, sel==7 ? true : nz>n/100);
    snprintf(nm,sizeof nm,"sel%u demod marks per frame ~1",sel); ok&=pr(nm, md+1>=fr && md<=fr+1);
    snprintf(nm,sizeof nm,"sel%u tx marks per frame ~1",sel);    ok&=pr(nm, mf+1>=fr && mf<=fr+1);
    snprintf(nm,sizeof nm,"sel%u slot cycles 0..3",sel);          ok&=pr(nm, slotok>=n-2);
    unsigned best=0,bestc=0; for(auto& kv:toffh) if(kv.second>bestc){best=kv.first;bestc=kv.second;}
    char d[64]; snprintf(d,sizeof d,"mode=%u frac=%.3f",best,(double)bestc/n);
    snprintf(nm,sizeof nm,"sel%u toff in range and steady",sel);  ok&=pr(nm, best<=12332 && bestc>=n*95/100, d);
    snprintf(nm,sizeof nm,"sel%u tref slot monotone mod 12333",sel); ok&=pr(nm, trefn>0 && trefok>=trefn*95/100);
    return ok;
}
static bool peakA(const Run& R){ // sel12: one dominant magnitude peak per frame
    unsigned n=R.r.size(); std::vector<unsigned> mag(n); unsigned mx=0;
    for(unsigned k=0;k<n;k++){ mag[k]=((unsigned)(unsigned short)R.r[k].i<<16)|(unsigned short)R.r[k].q; if(mag[k]>mx) mx=mag[k]; }
    unsigned peaks=0; for(unsigned k=0;k<n;k++) if(mag[k]>mx/2) peaks++;
    unsigned fr=R.frame_of.back()-R.frame_of.front();
    char d[64]; snprintf(d,sizeof d,"peaks>half-max=%u frames=%u",peaks,fr);
    return pr("sel12 one dominant correlator peak per frame", peaks>=fr/2 && peaks<=fr*3, d);
}

int main(int argc, char** argv){
    int NF = argc>1 ? atoi(argv[1]) : 40; bool all=true;
    auto nof=[](Vwrap_byte_ddrcap*, long, unsigned){};
    printf("=== PART A: liveness / markers / slots / toff / tref (NF=%d) ===\n",NF);
    for(unsigned sel=0; sel<16; sel++){ if(sel==7||sel==9||sel==10||sel==11) continue;   // 7 dead; 9-11 bit-domain covered by v1 gate
        Run R=run(sel,NF,nullptr,nof); all&=partA(sel,R); if(sel==12) all&=peakA(R); }
#ifdef DDRCAP2_FLAT
    printf("=== PART B: forced non-null per field (flat build) ===\n");
    struct FC { const char* name; unsigned sel; int chan; unsigned expect; int slot; };
    // chan: 2 = ch2[13:0], 3 = ch3 side at slot, 0 = I, 1 = Q
    // hold the force for the first 128 clks after cnt_frame_start reaches 30 (frame edges are not CPF-aligned)
    auto hold=[&](auto setter){ auto st=std::make_shared<long>(-1); return [=](Vwrap_byte_ddrcap* t, long clk, unsigned f){ if(f==30 && *st<0) *st=clk; if(*st>=0 && clk<*st+128) setter(t); }; };
    auto check=[&](const char* name, const Run& R, int chan, unsigned expect, int slot){
        bool seen=false; for(unsigned k=0;k<R.r.size();k++){ if(R.frame_of[k]<30||R.frame_of[k]>31) continue; const Rec& x=R.r[k];
            unsigned v = chan==2 ? (x.c2&0x3FFF) : chan==3 ? ((int)(x.c3>>14)==slot ? (x.c3&0x3FFF) : 0xFFFFFFFF) : chan==0 ? (unsigned short)x.i : (unsigned short)x.q;
            if(v==expect){ seen=true; break; } }
        char d[64]; snprintf(d,sizeof d,"expect=0x%X",expect); return pr(name, seen, d); };
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1)=0x2ABC; }));
      all&=check("force timingOffset=0x2ABC -> ch2[13:0]",R,2,0x2ABC,-1); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous1_out1)=0x12345; }));
      all&=check("force heldTs=0x12345 -> slot0 = 0x2345",R,3,0x2345,0); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1)=0x1234; }));
      all&=check("force tref=0x1234 -> slot1",R,3,0x1234,1); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Resettable_Synchronous_out1)=0x2AAC0000u; }));
      all&=check("force runMax=0x2AAC0000 -> slot2 = 0x0AAB",R,3,0x0AAB,2); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay5_out1)=0x15540000u; }));
      all&=check("force threshold=0x15540000 -> slot3 = 0x0555",R,3,0x0555,3); }
    { Run R=run(12,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay2_out1)=0x01234567u; }));
      all&=check("force corr=0x01234567 -> sel12 I=0x0123",R,0,0x0123,-1); all&=check("... sel12 Q=0x4567",R,1,0x4567,-1); }
    { Run R=run(13,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg)=0x155; }));
      all&=check("force muReg=0x155 -> sel13 Q",R,1,0x0155,-1); }
    { Run R=run(15,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,RHCTR_REG)=0xA5; }));
      all&=check("force Rate_Handle ctr=0xA5 -> sel15 I[15:8]",R,0,0xA500,-1); }
#endif
    printf("=== PART C: sel14 differs golden vs perturbed TX words ===\n");
    { auto g=words("tx_words_golden.hex"), p=words("tx_words_perturbed.hex");
      Run A=run(14,30,&g,nof), B=run(14,30,&p,nof); unsigned diff=0, n=std::min(A.r.size(),B.r.size());
      for(unsigned k=0;k<n;k++) if(A.r[k].i!=B.r[k].i||A.r[k].q!=B.r[k].q) diff++;
      char d[64]; snprintf(d,sizeof d,"diff=%u/%u",diff,n); all&=pr("sel14 golden vs perturbed differ",diff>n/50,d); }
    printf("DDRCAP2_GATE %s\n", all?"PASS":"FAIL"); return all?0:1;
}
```
`RHCTR_REG` is the Rate_Handle occupancy register; it is discovered in Step 2 and defined with `-DRHCTR_REG=...` (the plan does not guess its name).

- [ ] **Step 2: Discover the Rate_Handle occupancy register name and build**

```bash
cd jupiter_240k5_byte/rtl_sim
grep -n "assign beatobsRhCtr" s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/Rate_Handle.v     # names the driving reg, e.g. "assign beatobsRhCtr = occ_reg;"
bash build_ddrcap2_sim.sh 2>&1 | tail -4      # first build attempt; the flat build fails on RHCTR_REG until defined:
REG=$(grep -o "u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__<the reg name from the grep above>" obj_ddrcap2_flat/Vwrap_byte_ddrcap___024root.h | head -1)
# then rebuild the flat object with the define:
sed -i 's|-DDDRCAP2_FLAT"|-DDDRCAP2_FLAT -DRHCTR_REG='"$REG"'"|' build_ddrcap2_sim.sh
FORCE=1 bash build_ddrcap2_sim.sh 2>&1 | tail -3
```
Expected: both binaries exist; record the reg name in the report.

- [ ] **Step 3: Run the gate (under systemd-run; ~40 min flat)**

```bash
cd jupiter_240k5_byte/rtl_sim && mkdir -p beat_runs
systemd-run --user --unit=ddrcap2-gate-$(date +%H%M%S) --collect -p WorkingDirectory=$PWD \
  bash -c './obj_ddrcap2_flat/Vwrap_byte_ddrcap 40 > beat_runs/ddrcap2_gate.log 2>&1'
# poll: sleep 240 between `tail -3 beat_runs/ddrcap2_gate.log`
```
Expected: every line `PASS`, final `DDRCAP2_GATE PASS`. A FAIL on any line is a build blocker: fix the injector or the check (the check only if the expectation itself is wrong and you can say why from the RTL), re-run, and report both the failure and the fix. Two revisions maximum.

- [ ] **Step 4: Record §80 and commit**

Append to `two_jup/SESSION_20260830_AUTONOMOUS.md`: `## §80 DDRCAP-v2 Tier-1 gate [sim]` with the full PASS table and the Rate_Handle register name.
```bash
git add jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 Tier-1 gate: forced non-null for every field, liveness/markers/slots for sel 0-15 (§80)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

