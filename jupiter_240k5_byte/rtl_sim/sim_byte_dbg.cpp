// sim_byte_dbg.cpp -- instrument the byte-TX chain. Drives like sim_byte.cpp
// (byte source, tx_data_source=1, 1-in-2 adc_validIn) and, per air frame
// (delimited by frameStart), accumulates the infoBit stream (at infoValid)
// MSB-first per byte and prints the first 8 bytes of each frame -- so the
// shifter's delivered info can be compared to the pushed frame's word0.
// argv: tx_words.hex total_clks rot
#include "Vwrap_byte_dbg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 4){ fprintf(stderr,"usage: sim tx_words.hex total_clks rot\n"); return 2; }
    std::vector<unsigned long long> words;
    { FILE* f=fopen(argv[1],"r"); char ln[128];
      while(fgets(ln,sizeof ln,f)){ if(ln[0]=='\n') continue; words.push_back(strtoull(ln,nullptr,16)); }
      fclose(f); }
    if(words.size()!=35){ fprintf(stderr,"need 35 words, got %zu\n",words.size()); return 2; }
    long total=atol(argv[2]); int rot=atoi(argv[3]);
    Vwrap_byte_dbg* t=new Vwrap_byte_dbg;
    long clk=0; unsigned idx=(unsigned)rot;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1;
    t->byte_valid=1; t->byte_rx_ready=1;
    t->byte_data=words[idx]; t->byte_first=(idx==0);
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    // per-frame info + coded accumulation
    unsigned char frbytes[160]; int nib=0; int frame=-1;
    unsigned int codedLo=0; int ncoded=0;   // first 32 coded bits, LSB-first (g0,g1 per pair)
    unsigned int airLo=0; int nair=0;        // first 32 interleaver-output (air) bits, LSB-first
    auto flush=[&](){
        if(frame>=1 && frame<=4){
            printf("FRAME %d info:", frame);
            for(int b=0;b<8 && b*8<nib; b++){
                int v=0; for(int j=0;j<8;j++){ int bit=b*8+j; if(bit<nib && (frbytes[bit])) v|=(1<<(7-j)); }
                printf(" %02x", v);
            }
            printf(" | enc_coded32=%08x tx_air32=%08x\n", codedLo, airLo);
        }
    };
    while(clk<total){
        if(t->byte_ready && t->byte_valid) idx=(idx+1)%35;
        t->byte_data=words[idx]; t->byte_first=(idx==0); t->byte_valid=1;
        t->adc_validIn=(clk&1)?0:1;
        tick();
        if(t->railEnb){
            if(t->frameStart){ flush(); frame++; nib=0; codedLo=0; ncoded=0; airLo=0; nair=0; }
            if(t->frameValid && frame>=0){
                if(t->infoValid){
                    if(nib<160) frbytes[nib]= (t->infoBit)?1:0;
                    nib++;
                    if(ncoded<32 && t->cp0) codedLo|=(1u<<ncoded); ncoded++;
                    if(ncoded<32 && t->cp1) codedLo|=(1u<<ncoded); ncoded++;
                }
                if(nair<32 && t->encBit) airLo|=(1u<<nair); nair++;
            }
        }
    }
    printf("FINAL cap_in=%08x cap_deint=%08x cap_out=%08x packets=%u biterr=%u\n",
           t->cap_in, t->cap_deint, t->cap_out, t->packets_out, t->bit_errors_out);
    delete t; return 0;
}
