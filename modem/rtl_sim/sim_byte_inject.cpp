// sim_byte_inject.cpp -- T8.7 STATE-INJECTED replay driver: sim_byte_taps plus
// (a) mid-flight register forcing at a chosen input-sample index and (b) full
// state dumps at chosen sample indices, via the generated INJ_TABLE
// (gen_inject_map.py over the Verilated flat root; build with
// --public-flat-rw so no register is optimized away).
//
// argv: sim_byte_inject <iq_file> <nsamp> <vphase> <cadence> <rstcs_end> <skip>
//                       <out_prefix> [--inject FILE SAMPLE] [--dump FILE SAMPLE]...
//   --inject FILE SAMPLE : at input-sample index SAMPLE (immediately BEFORE
//        feeding that sample, on an enb-aligned boundary), force every
//        "name hexvalue" line in FILE into the model (names = INJ_TABLE
//        names; unknown names are fatal). One-shot.
//   --dump FILE SAMPLE   : write "name hexvalue" of ALL INJ_TABLE entries at
//        that sample index (repeatable; use for S(T1) prediction compares).
//
// Protocol (STATE_CAPTURE_PLAN.md): start the input ~8k samples before the
// injection point so RAM/FIR/valid pipelines warm from true data; injection
// then corrects the never-forgetting state to the live-captured words.
#include "Vwrap_byte_taps.h"
#include "Vwrap_byte_taps___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include "inject_map.h"

struct DumpReq { std::string file; long sample; };

static const InjEntry* find_entry(const char* n){
    for(int i=0;i<INJ_N;i++) if(!strcmp(INJ_TABLE[i].name,n)) return &INJ_TABLE[i];
    return nullptr;
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 8){
        fprintf(stderr,"usage: sim_byte_inject iq nsamp vphase cadence rstcs_end skip pfx [--inject F S] [--dump F S]\n");
        return 2;
    }
    const char* iqf = argv[1];
    long nsamp      = atol(argv[2]);
    int  vphase     = atoi(argv[3]);
    int  cadence    = atoi(argv[4]);
    long rstcs_end  = atol(argv[5]);
    unsigned skip   = (unsigned)atol(argv[6]);
    const char* pfx = argv[7];
    std::string injFile; long injSample = -1;
    std::vector<DumpReq> dumps;
    std::string trSubset, trOut; long trIv = 0; long trS = 0, trE_ = -1;
    long eatAt = -1; int eatN = 0;   // --eatvalid SAMPLE COUNT: suppress CS validOut at COUNT strobes from SAMPLE
    long stS = -1, stE = -1;         // --stallready S E: deassert byte_rx_ready during [S,E]
    for(int a=8;a+2<=argc;){
        if(!strcmp(argv[a],"--inject") && a+2<argc){ injFile=argv[a+1]; injSample=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--dump") && a+2<argc){ dumps.push_back({argv[a+1],atol(argv[a+2])}); a+=3; }
        else if(!strcmp(argv[a],"--trace") && a+3<argc){ trSubset=argv[a+1]; trOut=argv[a+2]; trIv=atol(argv[a+3]); a+=4; }
        else if(!strcmp(argv[a],"--tracewin") && a+2<argc){ trS=atol(argv[a+1]); trE_=atol(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--eatvalid") && a+2<argc){ eatAt=atol(argv[a+1]); eatN=atoi(argv[a+2]); a+=3; }
        else if(!strcmp(argv[a],"--stallready") && a+2<argc){ stS=atol(argv[a+1]); stE=atol(argv[a+2]); a+=3; }
        else { fprintf(stderr,"bad arg %s\n",argv[a]); return 2; }
    }
    if(cadence < 1) cadence = 1;
    if(vphase < 0 || vphase >= cadence) vphase = 0;

    // preload injection list
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
            pokes.push_back({e, (uint64_t)vv & e->mask});
        }
        fclose(f);
        fprintf(stderr,"inject: %zu pokes armed at sample %ld\n",pokes.size(),injSample);
    }

    // trace subset: list of names, one per line
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

    FILE* fi = fopen(iqf,"rb");
    if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp);
    long got = fread(iq.data(),2,2*nsamp,fi);
    fclose(fi);
    if(got/2 < nsamp) nsamp = got/2;

    char fn[512];
    auto openout=[&](const char* suf)->FILE*{
        snprintf(fn,sizeof fn,"%s_%s.txt",pfx,suf);
        FILE* f=fopen(fn,"w"); if(!f){ fprintf(stderr,"cannot open %s\n",fn); exit(2);} return f;
    };
    FILE* fr  = openout("rxw");
    FILE* fco = openout("con");

    Vwrap_byte_taps* t = new Vwrap_byte_taps;
    long clk=0, sidx=0, nrxw=0;
    int  ph=0;
    auto sx21=[](unsigned v)->int{ int x=v&0x1FFFFF; if(x&0x100000) x-=0x200000; return x; };

    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=skip;
    t->tx_data_source=0; t->byte_valid=0; t->byte_first=0; t->byte_data=0;
    t->byte_rx_ready=1;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    auto dump_state=[&](const char* file){
        FILE* f=fopen(file,"w");
        for(int i=0;i<INJ_N;i++)
            fprintf(f,"%s %llx\n",INJ_TABLE[i].name,
                    (unsigned long long)(inj_get(t->rootp, INJ_TABLE[i]) & INJ_TABLE[i].mask));
        fclose(f);
        fprintf(stderr,"dumped %d regs -> %s at sample %ld\n",INJ_N,file,sidx);
    };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    long total = 100 + nsamp*(long)cadence + 60000;
    while(clk < total){
        if(ph==vphase){
            if(sidx==injSample && !pokes.empty()){
                for(auto& p:pokes) inj_set(t->rootp, *p.e, p.v);
                t->eval();
                fprintf(stderr,"inject: %zu regs forced at sample %ld (clk %ld)\n",pokes.size(),sidx,clk);
                pokes.clear();
            }
            for(auto it=dumps.begin(); it!=dumps.end();){
                if(sidx==it->sample){ dump_state(it->file.c_str()); it=dumps.erase(it); }
                else ++it;
            }
            t->byte_rx_ready = (stS>=0 && sidx>=stS && sidx<=stE) ? 0 : 1;
            if(eatN>0 && eatAt>=0 && sidx>=eatAt){
                static const InjEntry* eatReg = nullptr;
                if(!eatReg){
                    for(int ii=0;ii<INJ_N;ii++)
                        if(strstr(INJ_TABLE[ii].name,"u_Carrier_Synchronizer__DOT__Delay7_out1")){ eatReg=&INJ_TABLE[ii]; break; }
                    if(!eatReg){ fprintf(stderr,"eatvalid: reg not found\n"); eatN=0; }
                }
                if(eatReg && inj_get(t->rootp,*eatReg)){
                    inj_set(t->rootp,*eatReg,0);
                    t->eval();
                    eatN--;
                    fprintf(stderr,"eatvalid: strobe suppressed at sample %ld (%d left)\n",sidx,eatN);
                }
            }
            if(ftr && trIv>0 && (sidx % trIv)==0 && sidx>=trS && (trE_<0 || sidx<=trE_)){
                fprintf(ftr,"%ld",sidx);
                for(auto e:trE) fprintf(ftr," %llx",(unsigned long long)(inj_get(t->rootp,*e)&e->mask));
                fprintf(ftr,"\n");
            }
            if(sidx<nsamp){
                t->adc_dataInI = iq[2*sidx];
                t->adc_dataInQ = iq[2*sidx+1];
                t->adc_validIn = 1;
                sidx++;
            } else t->adc_validIn = 0;
        } else t->adc_validIn = 0;
        ph = (ph+1)%cadence;
        t->rstCS = (clk>400 && clk<rstcs_end) ? 1 : 0;
        tick();
        if(t->byte_rx_valid && t->byte_rx_ready){
            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,
                    (int)t->byte_rx_last,(int)t->byte_rx_user);
            nrxw++;
        }
        if(t->railEnb && t->conV)
            fprintf(fco,"%d,%d\n",(int)(short)t->conI,(int)(short)t->conQ);
    }
    if(ftr) fclose(ftr);
    fclose(fr); fclose(fco);
    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u cfc_est=%d nrxw=%ld\n",
            t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,sx21(t->cfc_est),nrxw);
    fclose(fo);
    printf("INJECT nsamp=%ld packets=%u capout=%08x nrxw=%ld\n",nsamp,t->packets_out,t->cap_out,nrxw);
    delete t;
    return 0;
}
