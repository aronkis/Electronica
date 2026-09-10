// sim_byte_mm2s.cpp -- ADVERSARIAL netlist byte gate driver (TXMUX task).
// Models the REAL axi_dmac MM2S drive that sim_byte.cpp abstracts away:
//   * per-TRANSFER framing: NTW-word transfers with tlast on the final beat;
//     byte_first is regenerated exactly like util_axis_byte_breakout.v
//     (first_r=1 out of reset; after every ACCEPTED beat it takes that
//     beat's tlast)
//   * host padding: words 0..NDW-1 carry DISTINCT per-frame TAGGED content,
//     words NDW..NTW-1 are the host's zero pad (qpsk_tun tx_xfer_bytes pad)
//   * arm phase: the DMA starts delivering only after arm_clks (the fabric
//     free-runs from reset; the host arms mid-frame)
//   * inter-transfer gap: after each tlast beat is accepted, byte_valid
//     drops for gap_clks (empty descriptor queue / keepalive cadence)
//   * intra-transfer tvalid duty: valid deasserted unless (beat % dnum)<dden
//
// Tag scheme (survives encode->air->decode verbatim): word j of transfer n =
//   0xT0_0000_0000_0000 | (n&0xFFFF)<<32 | (j&0xFFFF)   with T=0xB.
// Any RX word therefore identifies (transfer, word-index) exactly; a constant
// word-phase offset, a replayed frame, or zero-fill is directly readable.
//
// argv: NTW NDW total_clks arm_clks gap_clks dnum dden out_prefix [rxgap_beats rxgap_clks]
//   rxgap_beats/rxgap_clks: every rxgap_beats accepted byte-rx beats, drop
//   byte_rx_ready for rxgap_clks (per-descriptor S2MM gap emulation); 0=off
//   NTW: words per transfer (k5 35, f1536 385); NDW: data words (k5 35, f1536 191)
// outputs: <prefix>_rxw.txt (hex,last,user per accepted byte-rx beat)
//          <prefix>_res.txt (regs summary)
#include "Vwrap_byte.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 9){ fprintf(stderr,"usage: sim_byte_mm2s NTW NDW total_clks arm_clks gap_clks dnum dden out_prefix\n"); return 2; }
    const unsigned NTW=(unsigned)atoi(argv[1]);
    const unsigned NDW=(unsigned)atoi(argv[2]);
    long total=atol(argv[3]);
    long arm=atol(argv[4]);
    long gap=atol(argv[5]);
    long dnum=atol(argv[6]); long dden=atol(argv[7]);
    if(dnum<1){dnum=1;dden=1;}
    long rxgapN = (argc>9)? atol(argv[9])  : 0;
    long rxgapC = (argc>10)? atol(argv[10]) : 0;
    char fn[512];
    snprintf(fn,sizeof fn,"%s_rxw.txt",argv[8]); FILE* fr=fopen(fn,"w");
    Vwrap_byte* t=new Vwrap_byte;
    long clk=0;
    unsigned xfer=0, widx=0;      // current transfer number / word index
    long gap_left=0, beat_ctr=0;
    int first_r=1;                 // util_axis_byte_breakout first_r replica
    auto word_of=[&](unsigned n,unsigned j)->unsigned long long{
        if(j>=NDW) return 0ULL;    // host zero pad
        return (0xB000000000000000ULL)|((unsigned long long)(n&0xFFFF)<<32)|(j&0xFFFF);
    };
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0;
    t->tx_data_source=1;
    t->byte_valid=0; t->byte_rx_ready=1;
    long rxbeats=0, rxoff=0;
    t->byte_data=0; t->byte_first=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    long nrxw=0;
    while(clk<total){
        // source state advance based on PREVIOUS posedge outputs (legal AXIS)
        if(t->byte_valid && t->byte_ready){
            int was_last = (widx==NTW-1);
            first_r = was_last;               // breakout: first_r <= tlast on accept
            if(was_last){ widx=0; xfer++; gap_left=gap; }
            else widx++;
        }
        beat_ctr++;
        int armed = (clk>=arm);
        int duty  = ((beat_ctr%dnum)<dden);
        int v = armed && duty && (gap_left<=0);
        if(gap_left>0) gap_left--;
        t->byte_data  = word_of(xfer,widx);
        t->byte_valid = v;
        t->byte_first = first_r;
        t->adc_validIn = (clk&1)?0:1;
        // RX-ready cadence: per-descriptor gap emulation
        if(rxgapN>0){
            if(rxoff>0){ rxoff--; t->byte_rx_ready=0; }
            else t->byte_rx_ready=1;
        }
        tick();
        if(t->byte_rx_valid && t->byte_rx_ready){
            if(rxgapN>0 && (++rxbeats % rxgapN)==0) rxoff=rxgapC;
            fprintf(fr,"%016llx,%d,%d\n",(unsigned long long)t->byte_rx_data,
                    (int)t->byte_rx_last,(int)t->byte_rx_user); nrxw++;
        }
    }
    fclose(fr);
    snprintf(fn,sizeof fn,"%s_res.txt",argv[8]); FILE* fo=fopen(fn,"w");
    fprintf(fo,"NTW=%u NDW=%u total=%ld arm=%ld gap=%ld duty=%ld/%ld nrxw=%ld xfers=%u\n",
            NTW,NDW,total,arm,gap,dnum,dden,nrxw,xfer);
    fprintf(fo,"packets=%u biterr=%u capout=%08x rstcs=%u frameStart=%u\n",
            t->packets_out,t->bit_errors_out,t->cap_out,t->rstcs_count,t->cnt_frame_start);
    fclose(fo);
    printf("MM2S nrxw=%ld xfers=%u packets=%u capout=%08x\n",nrxw,xfer,t->packets_out,t->cap_out);
    delete t; return 0;
}
