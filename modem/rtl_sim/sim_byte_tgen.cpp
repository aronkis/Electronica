// sim_byte_tgen.cpp -- short-fill wedge reproduction driver (2026-08-18 D0 task).
// Internal loopback (rx_input_select=0, tx_data_source=1), cadence-2 adc_validIn
// TX pacing (sim_byte.cpp idiom), FLASHED-generation netlist via wrap_byte_tgen.v.
//
// Stimulus replicates qpsk_traffic_gen.v bit-exactly: 1528-byte frames =
// 12B header (0x51 0x4B, len LE, seq LE from 1, CRC-const 0x54474E21 LE)
// + fill PN bytes (xorshift32, x=seq^0x9E3779B9, 0->0xDEADBEEF; per byte
// x^=x<<13,x^=x>>17,x^=x<<5, byte=x&0xFF) + zero pad. One 64-bit word per
// handshake beat (LSB byte first), byte_first on word 0, an 8-clk build
// bubble per word (the tgen S_BUILD cadence), programmable inter-frame gap.
//
// Scoring: delivered byte_rx words are framed by byte_rx_last AND the raw
// byte stream is magic-scanned for tgen frames (content compare against the
// generator model). Timeline windows record delivery rate, pdSync rate, and
// the Preamble Detector FIFO state (numEntries min/max, pop_on_empty,
// push_on_full) -- the suspected wedge stage.
//
// argv: fill nframes gap out_prefix [max_mclks] [drain_clks]
#include "Vwrap_byte_tgen.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>

static const int PKT_BYTES = 1528;
static const int NWORDS = PKT_BYTES/8;   // 191

static inline uint32_t xs32(uint32_t x){ x^=x<<13; x^=x>>17; x^=x<<5; return x; }

// bit-exact qpsk_traffic_gen frame content
static void gen_frame(uint32_t seq, int fill, uint8_t* b){
    memset(b, 0, PKT_BYTES);
    b[0]=0x51; b[1]=0x4B;
    b[2]=(uint8_t)(fill&0xFF); b[3]=(uint8_t)((fill>>8)&0x0F);
    b[4]=(uint8_t)(seq); b[5]=(uint8_t)(seq>>8); b[6]=(uint8_t)(seq>>16); b[7]=(uint8_t)(seq>>24);
    b[8]=0x21; b[9]=0x4E; b[10]=0x47; b[11]=0x54;   // 0x54474E21 LE
    uint32_t x = seq ^ 0x9E3779B9u; if(x==0) x=0xDEADBEEFu;
    for(int i=0;i<fill;i++){ x=xs32(x); b[12+i]=(uint8_t)(x&0xFF); }
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 5){
        fprintf(stderr,"usage: sim_byte_tgen fill nframes gap out_prefix [max_mclks] [drain_clks]\n");
        return 2;
    }
    int fill = atoi(argv[1]); if(fill>1516) fill=1516; if(fill<0) fill=0;
    long nframes = atol(argv[2]);
    long gap = atol(argv[3]);
    const char* pfx = argv[4];
    long max_clks = (argc>5? atol(argv[5]) : 60) * 1000000L;
    long drain    = (argc>6? atol(argv[6]) : 500000L);
    // QSIM_TGEN_BUBBLE: clks of deasserted valid between words (tgen S_BUILD
    // emulation). Default 8 (silicon tgen cadence). 0 = continuous valid
    // (sim_byte.cpp idiom).
    int bubble = 8;
    { const char* e=getenv("QSIM_TGEN_BUBBLE"); if(e) bubble=atoi(e); }
    long dbgclks = 0;   // QSIM_DBGCLKS: per-clk ingestion-seam trace window
    { const char* e=getenv("QSIM_DBGCLKS"); if(e) dbgclks=atol(e); }
    FILE* fd=nullptr;

    char fn[512];
    snprintf(fn,sizeof fn,"%s_timeline.txt",pfx); FILE* ft=fopen(fn,"w");
    snprintf(fn,sizeof fn,"%s_frames.txt",pfx);   FILE* ff=fopen(fn,"w");
    if(!ft||!ff){ fprintf(stderr,"cannot open outputs %s_*\n",pfx); return 2; }
    fprintf(ft,"# clk txsent rxlastframes okframes badframes pdsync_w fsync_cnt packets_out "
               "fifo_now fifo_min_w fifo_max_w pope_cum ponf_cum byteovf biterr\n");
    fprintf(ff,"# rxframe clk nbytes verdict seq  (verdict: OK/BAD/NOMAGIC/SHORTLONG)\n");
    if(dbgclks>0){ snprintf(fn,sizeof fn,"%s_dbg.txt",pfx); fd=fopen(fn,"w");
        fprintf(fd,"# clk drv_valid drv_first widx pin_ready bwbCount bwbReadyNext bwbAvail popEdge accept\n"); }
    // per-event preamble-sync log: every Preamble_Detector syncPulse and every
    // Peak_Search done beat with its success flag + timing offset + FIFO state
    snprintf(fn,sizeof fn,"%s_sync.txt",pfx); FILE* fsy=fopen(fn,"w");
    fprintf(fsy,"# clk kind(S=syncPulse D=done) success timingOffset fifoEntries taArmed\n");

    Vwrap_byte_tgen* t = new Vwrap_byte_tgen;
    long clk=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0;
    t->tx_data_source=1;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;

    // TX FSM state
    uint8_t fb[PKT_BYTES];
    uint32_t seq=1; gen_frame(seq, fill, fb);
    long txsent=0;        // completed frames
    int widx=0;           // next word index to send
    int build=bubble;     // build-bubble countdown before first word
    long gapcnt=0;
    bool tx_done=false;
    auto word_of=[&](int w)->uint64_t{
        uint64_t v=0; for(int i=0;i<8;i++) v |= ((uint64_t)fb[8*w+i])<<(8*i); return v; };

    // RX capture
    std::vector<uint8_t> rxbytes; rxbytes.reserve(4u<<20);
    std::vector<long> rxbyte_clk_mark;      // clk at each frame delimiter
    long cur_frame_bytes=0; long rxframes=0, okframes=0, badframes=0, oddframes=0;
    std::vector<uint8_t> curf; curf.reserve(4096);
    uint8_t exp[PKT_BYTES];

    // instrumentation accumulators
    long pdsync_w=0; long pope_cum=0, ponf_cum=0;
    int fifo_min_w=0x3FFF, fifo_max_w=0;
    bool pope_prev=false, ponf_prev=false;
    const long WIN=100000; long next_win=WIN;
    long drain_left=-1;

    auto score_last_frame=[&](){
        long nb=(long)curf.size();
        const char* v="SHORTLONG"; long s=-1;
        if(nb==PKT_BYTES){
            if(curf[0]==0x51 && curf[1]==0x4B){
                uint32_t fseq = curf[4] | (curf[5]<<8) | (curf[6]<<16) | ((uint32_t)curf[7]<<24);
                int flen = curf[2] | ((curf[3]&0x0F)<<8);
                gen_frame(fseq, flen>1516?1516:flen, exp);
                if(memcmp(curf.data(), exp, PKT_BYTES)==0 && flen==fill){ v="OK"; okframes++; }
                else { v="BAD"; badframes++; }
                s=fseq;
            } else { v="NOMAGIC"; badframes++; }
        } else oddframes++;
        fprintf(ff,"%ld %ld %ld %s %ld\n", rxframes, clk, nb, v, s);
        rxframes++;
        curf.clear();
    };

    while(clk < max_clks){
        // ---- TX byte source (registered handshake, sim_byte.cpp idiom) ----
        bool acc = (t->byte_valid && t->byte_ready);
        static int dbg_prev_cnt=-1;
        if(fd && clk<dbgclks && (acc || t->bwbPopEdge || (int)t->bwbCount!=dbg_prev_cnt) && (dbg_prev_cnt=(int)t->bwbCount, 1))
            fprintf(fd,"%ld v=%d f=%d widx=%d pinrdy=%d cnt=%d rdyN=%d avail=%d pop=%d acc=%d hf=%d hw=%016llx\n",
                clk,(int)t->byte_valid,(int)t->byte_first,widx,(int)t->byte_ready,
                (int)t->bwbCount,(int)t->bwbReadyNext,(int)t->bwbAvail,(int)t->bwbPopEdge,(int)acc,
                (int)t->bwbWordFirst,(unsigned long long)t->bwbWord);
        if(t->byte_valid && t->byte_ready){
            // word accepted at the upcoming posedge
            t->byte_valid=0; t->byte_first=0;
            widx++;
            if(widx==NWORDS){
                txsent++; widx=0;
                if(txsent>=nframes){ tx_done=true; drain_left=drain; }
                else { gapcnt=gap; seq++; gen_frame(seq, fill, fb); }
            }
            build=bubble;
        }
        if(!tx_done && !t->byte_valid){
            if(gapcnt>0) gapcnt--;
            else if(build>0) build--;
            else { t->byte_data=word_of(widx); t->byte_first=(widx==0); t->byte_valid=1; }
        }
        // cadence-2 TX pacing (DS_TxValid)
        t->adc_validIn = (clk&1)?0:1;
        tick();

        // ---- instrumentation (rail-gated) ----
        if(t->railEnb){
            if(t->pdV && t->pdSync) pdsync_w++;
            if(t->pdSync) fprintf(fsy,"%ld S %d %d %d %d eg=%d taref=%d dbfw=%d dbfr=%d\n",
                clk,(int)t->psSuccess,(int)t->psTimingOffset,(int)t->pdFifoEntries,(int)t->taArmed,
                (int)t->egCount,(int)t->tarefCount,(int)t->dbfWrCount,(int)t->dbfRdCount);
            if(t->psDone) fprintf(fsy,"%ld D %d %d %d %d eg=%d taref=%d dbfw=%d dbfr=%d\n",
                clk,(int)t->psSuccess,(int)t->psTimingOffset,(int)t->pdFifoEntries,(int)t->taArmed,
                (int)t->egCount,(int)t->tarefCount,(int)t->dbfWrCount,(int)t->dbfRdCount);
            if(t->egRst) fprintf(fsy,"%ld R 0 0 0 0 eg=%d taref=%d dbfw=%d dbfr=%d\n",
                clk,(int)t->egCount,(int)t->tarefCount,(int)t->dbfWrCount,(int)t->dbfRdCount);
            if(t->egEnd) fprintf(fsy,"%ld E 0 0 0 0 eg=%d taref=%d dbfw=%d dbfr=%d\n",
                clk,(int)t->egCount,(int)t->tarefCount,(int)t->dbfWrCount,(int)t->dbfRdCount);
            int ne=t->pdFifoEntries;
            if(ne<fifo_min_w) fifo_min_w=ne;
            if(ne>fifo_max_w) fifo_max_w=ne;
            bool pe=t->pdPopOnEmpty, pf=t->pdPushOnFull;
            if(pe && !pope_prev) pope_cum++;
            if(pf && !ponf_prev) ponf_cum++;
            pope_prev=pe; ponf_prev=pf;
        }

        // ---- RX capture ----
        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            for(int b=0;b<8;b++){ uint8_t by=(uint8_t)(w>>(8*b)); rxbytes.push_back(by); curf.push_back(by); }
            if(t->byte_rx_last) score_last_frame();
        }

        if(clk>=next_win){
            fprintf(ft,"%ld %ld %ld %ld %ld %ld %u %u %d %d %d %ld %ld %u %u\n",
                clk, txsent, rxframes, okframes, badframes, pdsync_w,
                t->cnt_frame_start, t->packets_out,
                (int)t->pdFifoEntries, fifo_min_w, fifo_max_w==0?0:fifo_max_w,
                pope_cum, ponf_cum, t->byte_fifo_ovf, t->bit_errors_out);
            fflush(ft);
            pdsync_w=0; fifo_min_w=0x3FFF; fifo_max_w=0; next_win+=WIN;
        }
        if(drain_left>=0 && --drain_left==0) break;
    }

    // magic-scan score over the raw delivered byte stream (framing-agnostic)
    long scan_ok=0, scan_bad=0;
    {
        const uint8_t* p=rxbytes.data(); long n=(long)rxbytes.size();
        for(long i=0;i+PKT_BYTES<=n;){
            if(p[i]==0x51 && p[i+1]==0x4B &&
               p[i+8]==0x21 && p[i+9]==0x4E && p[i+10]==0x47 && p[i+11]==0x54){
                uint32_t fseq = p[i+4]|(p[i+5]<<8)|(p[i+6]<<16)|((uint32_t)p[i+7]<<24);
                int flen = p[i+2]|((p[i+3]&0x0F)<<8);
                gen_frame(fseq, flen>1516?1516:flen, exp);
                if(memcmp(p+i, exp, PKT_BYTES)==0){ scan_ok++; i+=PKT_BYTES; continue; }
                scan_bad++; i++;
            } else i++;
        }
    }

    fclose(ft); fclose(ff); fclose(fsy);
    snprintf(fn,sizeof fn,"%s_rxbytes.bin",pfx);
    { FILE* fb2=fopen(fn,"wb"); fwrite(rxbytes.data(),1,rxbytes.size(),fb2); fclose(fb2); }
    snprintf(fn,sizeof fn,"%s_res.txt",pfx); FILE* fo=fopen(fn,"w");
    fprintf(fo,"fill=%d nframes=%ld gap=%ld clk_end=%ld tx_done=%d\n",
            fill,nframes,gap,clk,(int)tx_done);
    fprintf(fo,"txsent=%ld rxlastframes=%ld ok=%ld bad=%ld odd=%ld scan_ok=%ld scan_bad=%ld\n",
            txsent,rxframes,okframes,badframes,oddframes,scan_ok,scan_bad);
    fprintf(fo,"packets=%u biterr=%u fsync=%u byteovf=%u pope=%ld ponf=%ld fifo_end=%d\n",
            t->packets_out,t->bit_errors_out,t->cnt_frame_start,t->byte_fifo_ovf,
            pope_cum,ponf_cum,(int)t->pdFifoEntries);
    fclose(fo);
    printf("TGEN fill=%d txsent=%ld rxframes=%ld ok=%ld bad=%ld scan_ok=%ld scan_bad=%ld "
           "fsync=%u pope=%ld ponf=%ld clk=%ld\n",
           fill,txsent,rxframes,okframes,badframes,scan_ok,scan_bad,
           t->cnt_frame_start,pope_cum,ponf_cum,clk);
    delete t; return 0;
}
