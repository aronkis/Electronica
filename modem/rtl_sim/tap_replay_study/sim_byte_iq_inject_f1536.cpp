// sim_byte_iq_inject_f1536.cpp -- f1536 per-frame replay driver + STATE INJECTION.
//
// Merge of sim_byte_iq_perframe.cpp (per-frame decode verdict on the preserved
// f1536 netlist archive) and sim_byte_inject.cpp's perturbation primitives, for
// reproducing the RX delivery stall (5-100-frame packet freeze with clean input,
// locked carrier loop, self-recovery) by perturbing internal state mid-run.
//
// argv: <iq> <nsamp> <vphase> <cadence> <rstcs_end> <skip> <out_prefix>
//       [--inject FILE SAMPLE]   poke named regs (name hexvalue per line) at sample
//       [--dump FILE SAMPLE]     dump ALL regs (name hexvalue) at sample
//       [--trace SUBSET OUT IV]  trace listed regs every IV samples
//       [--tracewin S E]         limit trace to sample window
//       [--stallready S E]       deassert byte_rx_ready in [S,E]
//
// Emits <pfx>_frames.txt (outframe clk cap_out golden user frameStart rstcs),
// <pfx>_rxw.txt, <pfx>_res.txt -- identical scoring to perframe_f1536, PLUS
// <pfx>_pkt.txt: one line per input FRAME PERIOD (49332 samples) with the
// packets_out counter -> a frozen-counter window in sim == the hardware stall
// signature (0x104 frozen), directly comparable.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include "Vwrap_byte.h"
#include "Vwrap_byte___024root.h"
#include "verilated.h"
#include "inject_map_f1536.h"

static const int INJ_N_ = sizeof(INJ_TABLE)/sizeof(INJ_TABLE[0]);
static const InjEntry* find_entry(const char* n){
    for(int i=0;i<INJ_N_;i++) if(!strcmp(INJ_TABLE[i].name,n)) return &INJ_TABLE[i];
    return nullptr;
}
struct DumpReq { std::string file; long sample; };

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){ fprintf(stderr,"usage: sim_byte_iq_inject_f1536 iq nsamp vphase cadence rstcs_end skip pfx [--inject F S] [--dump F S] [--trace SUB OUT IV] [--tracewin S E] [--stallready S E]\n"); return 2; }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    int  vphase     = atoi(argv[3]);
    int  cadence    = atoi(argv[4]);
    long rstcs_end  = atol(argv[5]);
    unsigned skip   = (unsigned)atol(argv[6]);
    const char* pfx = argv[7];

    std::string injFile; long injSample = -1;
    std::vector<DumpReq> dumps;
    std::string trSubset, trOut; long trIv = 0, trS = 0, trE_ = -1;
    long stS = -1, stE = -1;
    long eatAt = -1; int eatN = 0;   // --eatvalid SAMPLE COUNT: suppress CS validOut strobes
    for(int a=8;a+2<=argc;){
        if(!strcmp(argv[a],"--inject") && a+2<argc){ injFile=argv[a+1]; injSample=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--dump") && a+2<argc){ dumps.push_back({argv[a+1],atol(argv[a+2])}); a+=3; }
        else if(!strcmp(argv[a],"--trace") && a+3<argc){ trSubset=argv[a+1]; trOut=argv[a+2]; trIv=atol(argv[a+3]); a+=4; }
        else if(!strcmp(argv[a],"--tracewin") && a+2<argc){ trS=atol(argv[a+1]); trE_=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--stallready") && a+2<argc){ stS=atol(argv[a+1]); stE=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--eatvalid") && a+2<argc){ eatAt=atol(argv[a+1]); eatN=atoi(argv[a+2]); a+=3; }
        else { fprintf(stderr,"bad arg %s\n",argv[a]); return 2; }
    }
    if(cadence < 1) cadence = 1;
    if(vphase < 0 || vphase >= cadence) vphase = 0;

    struct Poke { const InjEntry* e; uint64_t v; };
    std::vector<Poke> pokes;
    if(injSample >= 0){
        FILE* f=fopen(injFile.c_str(),"r");
        if(!f){ fprintf(stderr,"cannot open %s\n",injFile.c_str()); return 2; }
        char nm[512]; unsigned long long vv;
        while(fscanf(f,"%511s %llx",nm,&vv)==2){
            if(nm[0]=='#'){ char buf[1024]; if(!fgets(buf,sizeof buf,f)) break; continue; }
            const InjEntry* e=find_entry(nm);
            if(!e){ fprintf(stderr,"INJECT_FATAL unknown reg: %s\n",nm); return 3; }
            pokes.push_back({e,(uint64_t)vv & e->mask});
        }
        fclose(f);
        fprintf(stderr,"inject: %zu pokes armed at sample %ld\n",pokes.size(),injSample);
    }
    std::vector<const InjEntry*> trE;
    FILE* ftr = nullptr;
    if(trIv > 0){
        FILE* f=fopen(trSubset.c_str(),"r");
        if(!f){ fprintf(stderr,"cannot open %s\n",trSubset.c_str()); return 2; }
        char nm[512];
        while(fscanf(f,"%511s",nm)==1){
            if(nm[0]=='#') continue;
            const InjEntry* e=find_entry(nm);
            if(!e){ fprintf(stderr,"TRACE_FATAL unknown reg: %s\n",nm); return 3; }
            trE.push_back(e);
        }
        fclose(f);
        ftr=fopen(trOut.c_str(),"w");
        fprintf(stderr,"trace: %zu regs every %ld samples -> %s\n",trE.size(),trIv,trOut.c_str());
    }

    FILE* fi=fopen(iqf,"rb");
    if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2<nsamp) nsamp=got/2;

    char fn[512];
    snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    fprintf(ff,"# outframe clk cap_out golden user frameStart rstcs\n");
    snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_pkt.txt",pfx); FILE* fp=fopen(fn,"w");
    fprintf(fp,"# inframe sample packets_out frameStart rstcs\n");

    Vwrap_byte* t=new Vwrap_byte;
    long clk=0,sidx=0,nrxw=0; int ph=0;
    const unsigned CAPGOLD=0x04922282u;
    long outframe=0,capGoldFrames=0,capNonzFrames=0; bool capEverGold=false;
    long nuser=0;
    const long SPF=49332;                 // samples per f1536 frame at sps=4
    long nextPkLog=SPF;

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    auto sx=[](unsigned v)->int{int x=v&0x1FFFFF; if(x&0x100000)x-=0x200000; return x;};
    auto dump_state=[&](const char* file){
        FILE* f=fopen(file,"w");
        for(int i=0;i<INJ_N_;i++)
            fprintf(f,"%s %llx\n",INJ_TABLE[i].name,
                    (unsigned long long)(inj_get(t->rootp,INJ_TABLE[i]) & INJ_TABLE[i].mask));
        fclose(f);
        fprintf(stderr,"dumped %d regs -> %s at sample %ld\n",INJ_N_,file,sidx);
    };

    for(int i=0;i<100;i++) tick();
    t->reset=0;

    long total=100 + nsamp*(long)cadence + 60000;
    while(clk<total){
        if(ph==vphase){
            if(sidx==injSample && !pokes.empty()){
                for(auto& p:pokes) inj_set(t->rootp,*p.e,p.v);
                t->eval();
                fprintf(stderr,"inject: regs forced at sample %ld (clk %ld)\n",sidx,clk);
                pokes.clear();
            }
            for(auto it=dumps.begin(); it!=dumps.end();){
                if(sidx==it->sample){ dump_state(it->file.c_str()); it=dumps.erase(it); }
                else ++it;
            }
            if(ftr && trIv>0 && (sidx%trIv)==0 && sidx>=trS && (trE_<0 || sidx<=trE_)){
                fprintf(ftr,"%ld",sidx);
                for(auto e:trE) fprintf(ftr," %llx",(unsigned long long)(inj_get(t->rootp,*e)&e->mask));
                fprintf(ftr,"\n");
            }
            if(sidx>=nextPkLog){
                fprintf(fp,"%ld %ld %u %u %u\n",sidx/SPF,sidx,t->packets_out,t->cnt_frame_start,t->rstcs_count);
                nextPkLog+=SPF;
            }
            if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1]; t->adc_validIn=1; sidx++; }
            else t->adc_validIn=0;
        } else t->adc_validIn=0;
        ph=(ph+1)%cadence;
        t->byte_rx_ready=(stS>=0 && sidx>=stS && sidx<=stE)?0:1;
        t->rstCS=(clk>400 && clk<rstcs_end)?1:0;
        tick();
        if(eatN>0 && eatAt>=0 && sidx>=eatAt){   /* per-CLK: catch the strobe at any phase */
            static const InjEntry* eatReg = nullptr;
            static bool eatInit=false;
            if(!eatInit){ eatInit=true;
                for(int ii=0;ii<INJ_N_;ii++)
                    if(strstr(INJ_TABLE[ii].name,"u_Carrier_Synchronizer__DOT__Delay7_out1")){ eatReg=&INJ_TABLE[ii]; break; }
                if(!eatReg) fprintf(stderr,"eatvalid: reg not found\n");
            }
            if(eatReg && inj_get(t->rootp,*eatReg)){
                inj_set(t->rootp,*eatReg,0);
                t->eval();
                eatN--;
                fprintf(stderr,"eatvalid: strobe suppressed at sample %ld clk %ld (%d left)\n",sidx,clk,eatN);
            }
        }

        unsigned cap=t->cap_out; if(cap==CAPGOLD) capEverGold=true;
        if(t->byte_rx_valid && t->byte_rx_ready){
            unsigned long long w=(unsigned long long)t->byte_rx_data;
            fprintf(fr,"%016llx,%d,%d\n",w,(int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++; if(t->byte_rx_user) nuser++;
            if(t->byte_rx_last){
                unsigned c=t->cap_out; int g=(c==CAPGOLD)?1:0;
                fprintf(ff,"%ld %ld %08x %d %d %u %u\n",
                        outframe,clk,c,g,(int)t->byte_rx_user,t->cnt_frame_start,t->rstcs_count);
                capNonzFrames++; if(g) capGoldFrames++;
                outframe++;
            }
        }
    }
    fclose(ff); fclose(fr); fclose(fp);
    if(ftr) fclose(ftr);

    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"iq=%s nsamp=%ld vphase=%d cadence=%d rstcs_end=%ld skip=%u inject=%s@%ld\n",
            iqf,nsamp,vphase,cadence,rstcs_end,skip,injFile.c_str(),injSample);
    fprintf(fo,"packets=%u biterr=%u frameStart=%u rstcs=%u cfc_est=%d\n",
            t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->rstcs_count,sx(t->cfc_est));
    fprintf(fo,"outFrames=%ld capGoldFrames=%ld/%ld nrxw=%ld nuser=%ld capEverGold=%d\n",
            outframe,capGoldFrames,capNonzFrames,nrxw,nuser,(int)capEverGold);
    fclose(fo);
    printf("INJECTF1536 packets=%u frameStart=%u outFrames=%ld capGold=%ld/%ld rstcs=%u\n",
           t->packets_out,t->cnt_frame_start,outframe,capGoldFrames,capNonzFrames,t->rstcs_count);
    delete t; return 0;
}
