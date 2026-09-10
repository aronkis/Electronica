// sim_byte_txplane_taps.cpp -- TAPS variant (needs --public-flat-rw): logs TX byte-in plane events.
// <p>_ev.txt: clk kind fields --  START clk bufcount aligned avail first bitIdx | ALIGNLOSS clk bufcount avail first bitIdx start
// sim_byte_txplane.cpp -- TX byte-in plane reproduction on the FLASHED-generation netlist
// (wrap_byte_bf2.v / wrap_byte_ce, s1_rtl_beatfix3, cadence 2). Internal loopback
// (rx_input_select=0), tx_data_source=1, byte source = multi-frame word file with byte_first on
// word 0 of every frame (the MM2S/TLAST contract), ARRIVAL MODEL selectable:
//   cont            source always valid (DUT ready paces)
//   rate R [J]      frame k is released at clk k*FRAMECLKS/R, R = source rate as a FRACTION of the modem line
//                   rate (1.0 = exactly one 385-word transfer per air frame), + uniform jitter 0..J clks; within a
//                   released frame words are offered back-to-back (DMA burst); frames never overlap
//                   (a late frame is released as soon as the previous one drained)
//   gap G           after each frame's last word, valid low for G clks
// argv: words.hex NWF NF mode [p1 p2] out_prefix
// out: <p>_rxw.txt (hex,last,user of accepted byte-rx words), <p>_src.txt (frame k: release clk,
//      first-word-accept clk, last-word-accept clk, stall clks), <p>_res.txt
#include "Vwrap_byte_ce.h"
#include "Vwrap_byte_ce___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 6){ fprintf(stderr,"usage: sim_byte_txplane words.hex NWF NF mode [p1 [p2]] out_prefix\n"); return 2; }
    const char* wf=argv[1]; int NWF=atoi(argv[2]); int NF=atoi(argv[3]); std::string mode=argv[4];
    double p1 = (argc>6)?atof(argv[5]):0, p2 = (argc>7)?atof(argv[6]):0; const char* pfx=argv[argc-1];
    std::vector<unsigned long long> words;
    { FILE* f=fopen(wf,"r"); if(!f){ fprintf(stderr,"no %s\n",wf); return 2; } char ln[128];
      while(fgets(ln,sizeof ln,f)){ if(ln[0]=='\n') continue; words.push_back(strtoull(ln,nullptr,16)); } fclose(f); }
    if((int)words.size() < NWF*NF){ fprintf(stderr,"word file short: %ld < %ld\n", (long)words.size(), (long)NWF*NF); return 2; }
    char fn[512]; snprintf(fn,sizeof fn,"%s_rxw.txt",pfx); FILE* fr=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_src.txt",pfx); FILE* fsrc=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_ev.txt",pfx); FILE* fev=fopen(fn,"w"); int prevStart=0, prevAligned=0; long nStart=0, nLoss=0;
    Vwrap_byte_ce* t=new Vwrap_byte_ce;
    long clk=0; long nrxw=0;
    t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1; t->fixctl=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    // frame release schedule
    long frameClks = getenv("TXPLANE_FRAMECLKS") ? atol(getenv("TXPLANE_FRAMECLKS")) : 98664;   // measured (r_src): one 385-word transfer consumed per 98,664 clks
    std::vector<long> rel(NF, 0);
    if(mode=="rate"){ double R=p1, J=p2; unsigned s=12345u;
        for(int k=0;k<NF;k++){ s = s*1103515245u+12345u; double j = J>0 ? (double)((s>>8)%100000)/100000.0*J : 0; rel[k]=(long)(100 + k*(double)frameClks/R + j); } }
    long total = 100 + (long)(NF+8)*frameClks;
    if(mode=="rate" && p1>0){ long tr = rel[NF-1] + 8*frameClks; if(tr>total) total=tr; }
    int k=0, w=0; bool frameOpen=false; long gapUntil=0; long stallClks=0, firstAcc=-1;
    bool valid=false;
    while(clk<total){
        // registered AXIS handshake: outputs sampled after previous tick
        if(valid && t->byte_ready){                 // accepted word (k,w)
            if(w==0) firstAcc=clk;
            if(w==NWF-1){ fprintf(fsrc,"%d %ld %ld %ld %ld\n",k,rel[k],firstAcc,clk,stallClks); k++; w=0; stallClks=0; frameOpen=false; if(mode=="gap") gapUntil=clk+(long)p1; }
            else w++;
        } else if(valid) stallClks++;
        // decide next offer
        valid=false;
        if(k<NF){
            bool avail=true;
            if(mode=="rate") avail = (clk>=rel[k]) || frameOpen;
            if(mode=="gap")  avail = (clk>=gapUntil);
            if(avail){ valid=true; frameOpen=true; t->byte_data=words[(size_t)k*NWF+w]; t->byte_first=(w==0); }
        }
        t->byte_valid=valid?1:0; if(!valid){ t->byte_first=0; }
        t->adc_validIn=(clk&1)?0:1;
        tick();
        { auto* R=t->rootp; int st=R->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__Message_Generator_start;
          int al=R->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__u_ByteBitShifter__DOT__state_aligned;
          int bc=R->wrap_byte_ce__DOT__dut__DOT__u_ByteWordBuffer__DOT__state_count;
          int av=R->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__extWordAvail;
          int fi=R->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__extWordFirst;
          int bi=R->wrap_byte_ce__DOT__dut__DOT__u_Transmitter__DOT__u_Input_Data__DOT__u_ByteBitShifter__DOT__state_bitIdx;
          if(st && !prevStart){ nStart++; fprintf(fev,"START %ld buf=%d aligned=%d avail=%d first=%d bitIdx=%d srcframe=%d srcword=%d\n",clk,bc,al,av,fi,bi,k,w); }
          if(prevAligned && !al){ nLoss++; fprintf(fev,"ALIGNLOSS %ld buf=%d avail=%d first=%d bitIdx=%d start=%d srcframe=%d srcword=%d\n",clk,bc,av,fi,bi,st,k,w); }
          prevStart=st; prevAligned=al; }
        if(t->byte_rx_valid && t->byte_rx_ready){ fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,(int)t->byte_rx_last,(int)t->byte_rx_user); nrxw++; }
    }
    fclose(fr); fclose(fsrc); fclose(fev);
    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"words=%s NWF=%d NF=%d mode=%s p1=%g p2=%g total=%ld sent_frames=%d\n",wf,NWF,NF,mode.c_str(),p1,p2,total,k);
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u frameStart=%u nrxw=%ld\n",t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,t->cnt_frame_start,nrxw);
    fclose(fo);
    printf("TXPLANE mode=%s NF=%d sent=%d packets=%u nrxw=%ld frameStart=%u starts=%ld alignloss=%ld\n",mode.c_str(),NF,k,t->packets_out,nrxw,t->cnt_frame_start,nStart,nLoss);
    delete t; return 0;
}
