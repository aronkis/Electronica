// sim_byte_iq_cfclog.cpp -- sim_byte_iq.cpp + STEADY-STATE coarse-CFO-estimate jitter
// instrumentation. Logs the first-difference of the top-level cfc_est (sign-extended
// sfix21_En21 = SAME units/scale as the CFO_step_change_detector's In1 and its 3277
// threshold) over the post-acquisition window, and reports max|dcfc| and the count of
// updates that would exceed +/-3277 (i.e. would fire the detector). Same argv as sim_byte_iq.
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){ fprintf(stderr,"usage: sim_byte_iq_cfclog iq nsamp vphase cadence rstcs_end skip out_prefix\n"); return 2; }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    int  vphase     = atoi(argv[3]);
    int  cadence    = atoi(argv[4]);
    long rstcs_end  = atol(argv[5]);
    unsigned skip   = (unsigned)atol(argv[6]);
    const char* pfx = argv[7];
    if(cadence < 1) cadence = 1;
    if(vphase < 0 || vphase >= cadence) vphase = 0;

    FILE* fi = fopen(iqf,"rb");
    if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi);
    fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    std::vector<unsigned long long> gold;
    { FILE* fg=fopen("rx_words_golden.hex","r");
      if(fg){ char ln[128]; while(fgets(ln,sizeof ln,fg)){ if(ln[0]=='\n') continue; gold.push_back(strtoull(ln,nullptr,16)); } fclose(fg); } }
    std::set<unsigned long long> goldset(gold.begin(),gold.end());
    unsigned long long gold0 = gold.size()>0 ? gold[0] : 0ULL;

    char fn[512];
    snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");

    Vwrap_byte* t = new Vwrap_byte;
    long clk=0, sidx=0, nrxw=0;
    int  ph=0;
    long ngold0=0, ngoldAny=0, nuser=0;
    const unsigned CAPGOLD = 0x04922282u;
    long capGoldFrames=0, capNonzFrames=0;
    bool capEverGold=false;

    // --- cfc_est first-difference (steady-state) instrumentation ---
    const long CFO_THRESH = 3277;      // detector constant (En21)
    long maxdcfc = 0, wouldfire = 0, ncfcupd = 0;
    int  prevcfc = 0; bool firstcfc = true;
    long steadyStart = rstcs_end + 2000; // exclude acquisition transient
    snprintf(fn,sizeof fn,"%s_cfctrace.txt",pfx); FILE* fc=fopen(fn,"w");

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    auto sx=[](unsigned v)->int{ int x=v&0x1FFFFF; if(x&0x100000) x-=0x200000; return x; };

    for(int i=0;i<100;i++) tick();
    t->reset=0;

    long total = 100 + nsamp*(long)cadence + 60000;
    while(clk < total){
        if(ph==vphase){
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();

        // cfc_est first-difference tracker (steady-state window only)
        int cfcnow = sx(t->cfc_est);
        if(clk > steadyStart){
            if(firstcfc){ prevcfc=cfcnow; firstcfc=false; }
            else if(cfcnow != prevcfc){
                long d = labs((long)cfcnow - (long)prevcfc);
                ncfcupd++;
                if(d > maxdcfc) maxdcfc = d;
                if(d > CFO_THRESH) wouldfire++;
                if((ncfcupd % 50)==0) fprintf(fc,"%ld %d %ld\n", clk, cfcnow, d);
                prevcfc = cfcnow;
            }
        }

        unsigned cap = t->cap_out; if(cap==CAPGOLD) capEverGold=true;
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long w=(unsigned long long)t->byte_rx_data;
            fprintf(fr,"%016llx,%d,%d\n",w,(int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++; if(t->byte_rx_user) nuser++;
            if(!gold.empty()){ if(w==gold0) ngold0++; if(goldset.count(w)) ngoldAny++; }
            if(t->byte_rx_last){ capNonzFrames++; if(t->cap_out==CAPGOLD) capGoldFrames++; }
        }
    }
    fclose(fr); fclose(fc);

    unsigned packets=t->packets_out, biterr=t->bit_errors_out;
    int cfc=sx(t->cfc_est);
    double capGoldFrac = capNonzFrames>0 ? (double)capGoldFrames/(double)capNonzFrames : 0.0;

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u\n",iqf,nsamp,vphase,cadence,rstcs_end,skip);
    fprintf(fo,"packets=%u biterr=%u capGoldFrames=%ld/%ld (%.1f%%)\n",packets,biterr,capGoldFrames,capNonzFrames,100.0*capGoldFrac);
    fprintf(fo,"rstcs=%u cfc_est=%d nrxw=%ld nuser=%ld capEverGold=%d\n",t->rstcs_count,cfc,nrxw,nuser,(int)capEverGold);
    fprintf(fo,"CFCJITTER: steady_updates=%ld max_abs_dcfc=%ld would_fire(>3277)=%ld  [thresh=3277 En21]\n",
            ncfcupd,maxdcfc,wouldfire);
    fclose(fo);

    printf("CFCLOG iq=%s nsamp=%ld packets=%u rstcs=%u capGoldFrames=%ld/%ld cfc_final=%d | "
           "steady_updates=%ld MAX|dcfc|=%ld would_fire(>3277)=%ld goldAny=%ld\n",
           iqf,nsamp,packets,t->rstcs_count,capGoldFrames,capNonzFrames,cfc,ncfcupd,maxdcfc,wouldfire,ngoldAny);
    delete t; return 0;
}
