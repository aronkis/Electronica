// sim_byte.cpp -- S1B netlist byte gate driver (Verilator, wrap_byte.v).
// Internal loopback (rx_input_select=0), tx_data_source=1, 1-in-2
// adc_validIn cadence (Tx pacing), skip_count=0. A registered-handshake AXIS
// byte source feeds the golden frame words (word file, one hex per line);
// the start index emulates the cyclic-DMA word phase (0 = aligned).
//
// FRAME-AGNOSTIC (RXALIGN task, 2026-07-25): the source word count NW is read
// from the hex file (k5=35, f1536=385); rotation is mod NW. This is the sole
// geometry dependency in the driver (frame clks come in via total_clks). k5
// behaviour is byte-identical (NW resolves to 35).
//
// argv: tx_words.hex total_clks rot out_prefix
//   tx_words.hex : NW lines, 16-hex-digit uint64 (LSB byte = first byte)
//   total_clks   : sim length in clk cycles (k5 frame=18128 clks, f1536=197328)
//   rot          : source start index 0..NW-1 (word phase rotation)
//   out_prefix   : writes <prefix>_sym.csv  (modI,modQ per valid symbol)
//                         <prefix>_rxw.txt (accepted byte-rx words: hex,last,user)
//                         <prefix>_res.txt (final regs + steady-state error check)
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 5){ fprintf(stderr,"usage: sim_byte tx_words.hex total_clks rot out_prefix\n"); return 2; }
    // load the frame source words (NW read from file: k5=35, f1536=385)
    std::vector<unsigned long long> words;
    { FILE* f=fopen(argv[1],"r"); if(!f){ fprintf(stderr,"no %s\n",argv[1]); return 2; }
      char ln[128];
      while(fgets(ln,sizeof ln,f)){ if(ln[0]=='\n') continue;
          words.push_back(strtoull(ln,nullptr,16)); }
      fclose(f); }
    const unsigned NW = (unsigned)words.size();
    if(NW==0){ fprintf(stderr,"empty word file %s\n",argv[1]); return 2; }
    long total=atol(argv[2]); int rot=atoi(argv[3]);
    char fn[512];
    snprintf(fn,sizeof fn,"%s_sym.csv",argv[4]); FILE* fs=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_rxw.txt",argv[4]); FILE* fr=fopen(fn,"w");
    Vwrap_byte* t=new Vwrap_byte;
    long clk=0; unsigned idx=(unsigned)rot;
    unsigned errLate=0, pkLate=0; long lateAt=(long)(0.70*(double)total);
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0;
    t->tx_data_source=1;
    t->byte_valid=1; t->byte_rx_ready=1;
    t->byte_data=words[idx]; t->byte_first=(idx==0);
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    long nsym=0, nrxw=0;
    while(clk<total){
        // AXIS byte source: registered handshake -- advance on ready&&valid
        // sampled at the PREVIOUS posedge outputs (legal AXIS: accept happens
        // on the beat where both are high).
        if(t->byte_ready && t->byte_valid){
            idx = (idx+1)%NW;
        }
        t->byte_data=words[idx]; t->byte_first=(idx==0); t->byte_valid=1;
        // 1-in-2 adc_validIn cadence (Tx pacing via DS_TxValid)
        t->adc_validIn = (clk&1)?0:1;
        tick();
        // modulator symbol stream (one line per constellation symbol)
        if(t->railEnb && t->modValid){
            fprintf(fs,"%d,%d\n",(int)(short)t->modI,(int)(short)t->modQ); nsym++;
        }
        // accepted byte-rx beats (ready tied 1 -> one beat per word)
        if(t->byte_rx_valid && t->byte_rx_ready){
            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,
                    (int)t->byte_rx_last,(int)t->byte_rx_user); nrxw++;
        }
        if(clk==lateAt){ errLate=t->bit_errors_out; pkLate=t->packets_out; }
    }
    fclose(fs); fclose(fr);
    snprintf(fn,sizeof fn,"%s_res.txt",argv[4]); FILE* fo=fopen(fn,"w");
    fprintf(fo,"rot=%d total=%ld nsym=%ld nrxw=%ld\n",rot,total,nsym,nrxw);
    fprintf(fo,"packets=%u biterr=%u errLate=%u pkLate=%u frameStart=%u\n",
            t->packets_out,t->bit_errors_out,errLate,pkLate,t->cnt_frame_start);
    fprintf(fo,"capout=%08x rstcs=%u cfc_est=%d\n",t->cap_out,t->rstcs_count,
            (int)((t->cfc_est&0x100000)?(int)(t->cfc_est|0xFFE00000):(int)(t->cfc_est&0x1FFFFF)));
    fclose(fo);
    printf("S1B rot=%d packets=%u biterr=%u errLate=%u capout=%08x nsym=%ld nrxw=%ld\n",
           rot,t->packets_out,t->bit_errors_out,errLate,t->cap_out,nsym,nrxw);
    delete t; return 0;
}
