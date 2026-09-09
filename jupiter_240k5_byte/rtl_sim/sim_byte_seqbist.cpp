// sim_byte_seqbist.cpp -- SEQ-BIST T0c full-loop sim gate driver (2026-09-03).
//
// Drives wrap_byte_seqbist.v: the RTL qpsk_traffic_gen_v2 makes the frames (the
// driver no longer regenerates them), the DUT runs in internal fabric loopback
// (rx_input_select=0, tx_data_source=1, cadence-2 adc_validIn), and
// rx_seq_checker + cnt_mux32 snoop the DUT RX byte pins.  Every counter value
// the driver records is read the way the host reads it on silicon:
//   freeze=1 -> sweep mux_sel 16..31 -> sample mux_q -> freeze=0,
// with packets_out sampled INSIDE the same freeze window (the plan's silicon
// rule: read 0x104/0x124 inside the freeze window; packets_out free-runs from
// reset, so only deltas from the checker-enable instant are meaningful).
//
// Ordering matches the silicon arming rule from task-1-report: TGEN is armed
// first, then the checker's `en` is pulsed -- here after WARMUP consecutive
// good-magic frames have been delivered, because the modem's startup emits a
// few filler/NOMAGIC frames (4 in wedge_repro/leg_ctl1516, and seq 1 was lost).
//
// usage:
//   sim_byte_seqbist <nframes> <skip_every> <corrupt_every> <fill> <gap>
//                    <out_prefix> [force_spec] [max_mclks]
//     force_spec : none
//                | starve:<emitted_frame>:<clks>   TX stalled mid-frame (word 95)
//                | overrun:<emitted_frame>:<clks>  TGEN gap forced to 0 (G4)
//
// G4 mechanism note.  `starve` (withholding TX data) turns out NOT to damage
// anything on this rail: the byte plane back-pressures, so the generator simply
// pauses and resumes with the SAME seq -- frames are delayed, none is lost, and
// the checker correctly reports no gap.  `overrun` is the force that models the
// real ByteWordBuffer defect: with the TGEN gap driven to 0 the generator
// offers ~3 frames per 2 air frames, the TX chain accepts them and drops what
// it cannot transmit, and whole SEQUENCE NUMBERS go missing -- which is exactly
// what the checker must count (lost_slots / gap3plus) and then recover from.
//
// outputs: <pfx>_csv.txt   (a mux-read counter row every CSVSTEP frames)
//          <pfx>_summary.txt (key=value; scored by seqbist_gate_score.py)
//          stdout: SEQBIST_GATE_SUMMARY ... and SEQBIST_GATE_RUN_EXIT=<code>
#include "Vwrap_byte_seqbist.h"
#include "verilated.h"
#include "seqbist_build_stamp.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

static const int PKT_BYTES = 1528;
static const long AIR_FRAME_CLKS = 98664;   // measured: wedge_repro/*_res.txt
static const int  WARMUP_GOOD = 3;          // consecutive good frames before en
static const long CSVSTEP = 100;

int main(int argc, char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc < 7){
        fprintf(stderr,"usage: sim_byte_seqbist nframes skip_every corrupt_every fill gap "
                       "out_prefix [none|starve:<frame>:<clks>] [max_mclks]\n");
        printf("SEQBIST_GATE_RUN_EXIT=2\n");
        return 2;
    }
    long nframes  = atol(argv[1]);
    int  skip_ev  = atoi(argv[2]);
    int  corr_ev  = atoi(argv[3]);
    int  fill     = atoi(argv[4]); if(fill>1516) fill=1516; if(fill<0) fill=0;
    long gap      = atol(argv[5]);
    const char* pfx = argv[6];
    std::string force = (argc>7)? argv[7] : "none";
    long max_clks = (argc>8? atol(argv[8]) : 400) * 1000000L;

    if(skip_ev && corr_ev){
        fprintf(stderr,"skip_every and corrupt_every are mutually exclusive (one mode bit)\n");
        printf("SEQBIST_GATE_RUN_EXIT=2\n");
        return 2;
    }
    long force_frame = -1, force_clks = 0;
    int  force_kind = 0;                 // 0 none, 1 starve (stall TX), 2 overrun
    if(force.rfind("starve:",0)==0){
        force_kind = 1;
        if(sscanf(force.c_str(),"starve:%ld:%ld",&force_frame,&force_clks)!=2){
            fprintf(stderr,"bad force spec '%s'\n",force.c_str());
            printf("SEQBIST_GATE_RUN_EXIT=2\n"); return 2;
        }
    } else if(force.rfind("overrun:",0)==0){
        force_kind = 2;
        if(sscanf(force.c_str(),"overrun:%ld:%ld",&force_frame,&force_clks)!=2){
            fprintf(stderr,"bad force spec '%s'\n",force.c_str());
            printf("SEQBIST_GATE_RUN_EXIT=2\n"); return 2;
        }
    } else if(force!="none"){
        fprintf(stderr,"bad force spec '%s'\n",force.c_str());
        printf("SEQBIST_GATE_RUN_EXIT=2\n"); return 2;
    }

    char fn[512];
    // QSIM_RXDUMP=1: save every delivered RX byte (Task 3b byte-level forensics)
    FILE* fbin=nullptr;
    { const char* e=getenv("QSIM_RXDUMP");
      if(e && atoi(e)){ snprintf(fn,sizeof fn,"%s_rxbytes.bin",pfx); fbin=fopen(fn,"wb"); } }
    snprintf(fn,sizeof fn,"%s_frames.txt",pfx); FILE* ff=fopen(fn,"w");
    if(ff) fprintf(ff,"# rxframe clk nbytes magic seq crcfield hdr16\n");
    snprintf(fn,sizeof fn,"%s_csv.txt",pfx); FILE* fc=fopen(fn,"w");
    if(!fc){ fprintf(stderr,"cannot open %s\n",fn); printf("SEQBIST_GATE_RUN_EXIT=2\n"); return 2; }
    fprintf(fc,"# clk,frames,good,garbage,crc_fail,lost_slots,gap_events,gap1,gap2,gap3plus,"
               "dup_or_reorder,last_seq,int_last,int_lt30,int_32,int_33,int_other,"
               "packets_delta,emitted,rx_frames,bwb_min_win,stalled\n");

    Vwrap_byte_seqbist* t = new Vwrap_byte_seqbist;
    long clk=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=0; t->skip_count=0; t->tx_data_source=1;
    t->tgen_ctrl=0; t->tgen_gap=0; t->tx_stall=0;
    t->chk_en=0; t->chk_freeze=0; t->chk_tgen_mode=1; t->mux_sel=0;
    t->byte_rx_ready=1;

    // RX framing state
    std::vector<uint8_t> curf; curf.reserve(PKT_BYTES+64);
    long rx_frames=0, rx_good=0, warm_run=0;
    bool en_done=false; long en_clk=0; uint32_t packets_at_en=0; uint32_t seq_at_en=0;
    long emitted=0, emitted_at_en=0;
    int  bwb_min_global=255, bwb_min_win=255, bwb_min_force=255;
    bool avail_low_in_force=false, force_done=false, force_active=false;
    long force_start_clk=-1, force_end_clk=-1, force_end_emitted=-1, force_word=-1;
    long emitted_at_force=0, emitted_in_force=0;
    long stall_left=0;
    long txwidx=0; bool in_tx_frame=false;   // word index inside the emitted frame
    long next_csv=CSVSTEP;
    long last_csv_frames=0;
    uint32_t cnt[16]; memset(cnt,0,sizeof cnt);
    uint32_t packets_now=0;
    long drain_left=-1;
    bool tx_started=false;

    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++){ t->adc_validIn=(clk&1)?0:1; tick(); }
    t->reset=0;

    // QSIM_TGEN_START_DELAY: hold the TGEN disabled for N clocks after reset.
    // Task 3b start-phase control: it moves the generator's phase relative to
    // the free-running air-frame cadence WITHOUT changing a single payload
    // byte, so a defect that follows the frame CONTENT stays on the same seq
    // while a defect that follows the TIMING moves.
    { const char* e=getenv("QSIM_TGEN_START_DELAY");
      long d = e? atol(e) : 0;
      for(long i=0;i<d;i++){ t->adc_validIn=(clk&1)?0:1; tick(); } }

    // arm the TGEN (silicon order: TGEN first, checker `en` after)
    uint32_t nth = (uint32_t)(skip_ev? skip_ev : corr_ev);
    t->tgen_ctrl = 1u | ((uint32_t)(fill & 0xFFF) << 4) | (nth << 16);
    t->tgen_gap  = ((uint32_t)gap & 0x07FFFFFFu) | (corr_ev? (1u<<27) : 0u);

    // one freeze->sweep->unfreeze readout, exactly as the host does it
    auto freeze_read=[&](){
        t->chk_freeze=1;
        for(int i=0;i<4;i++){ t->adc_validIn=(clk&1)?0:1; tick(); }
        packets_now = t->packets_out;              // sampled INSIDE the freeze window
        for(int s=0;s<16;s++){
            t->mux_sel = 16+s;
            for(int i=0;i<3;i++){ t->adc_validIn=(clk&1)?0:1; tick(); }
            cnt[s] = t->mux_q;
        }
        t->chk_freeze=0;
        for(int i=0;i<2;i++){ t->adc_validIn=(clk&1)?0:1; tick(); }
    };
    auto csv_row=[&](){
        long pdelta = (long)packets_now - (long)packets_at_en;
        fprintf(fc,"%ld,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%ld,%ld,%ld,%d,%d\n",
            clk,cnt[0],cnt[1],cnt[2],cnt[3],cnt[4],cnt[5],cnt[6],cnt[7],cnt[8],
            cnt[9],cnt[10],cnt[11],cnt[12],cnt[13],cnt[14],cnt[15],
            pdelta, emitted-emitted_at_en, rx_frames, bwb_min_win, (int)force_done);
        fflush(fc);
        bwb_min_win=255;
    };

    while(clk < max_clks){
        // ---- G4 force: withhold TX data for force_clks clocks ----
        // The stall must land MID-FRAME (word FORCE_WORD of 191).  A stall that
        // lands in the inter-frame gap merely DELAYS a frame -- the generator
        // resumes with the same seq, nothing is damaged and nothing is lost --
        // whereas a mid-frame stall drains the ByteWordBuffer while an air
        // frame is being transmitted, which is the defect G4 exists to model.
        if(!force_done && force_frame>=0 && en_done && (emitted-emitted_at_en)>=force_frame
           && !force_active
           && (force_kind==2 || (in_tx_frame && txwidx>=95))){
            force_active=true; stall_left=force_clks; force_start_clk=clk; force_word=txwidx;
            bwb_min_force=255; avail_low_in_force=false; emitted_at_force=emitted;
            if(force_kind==1) t->tx_stall=1;
            else              t->tgen_gap = (t->tgen_gap & 0xF8000000u);   // gap -> 0
        }
        if(force_active){
            if(--stall_left<=0){
                t->tx_stall=0;
                t->tgen_gap = ((uint32_t)gap & 0x07FFFFFFu) | (corr_ev? (1u<<27) : 0u);
                force_active=false; force_done=true;
                force_end_clk=clk; force_end_emitted=emitted-emitted_at_en;
                emitted_in_force=emitted-emitted_at_force;
            }
        }

        t->adc_validIn = (clk&1)?0:1;
        tick();

        // ---- TX seam ----
        if(t->tg_valid && t->tg_ready){
            if(!tx_started) tx_started=true;
            if(t->tg_first){ emitted++; txwidx=0; in_tx_frame=true; }
            else { txwidx++; if(txwidx>=190) in_tx_frame=false; }
        }
        {
            int bc = (int)t->bwbCount;
            if(bc<bwb_min_global) bwb_min_global=bc;
            if(bc<bwb_min_win)    bwb_min_win=bc;
            if(force_active){
                if(bc<bwb_min_force) bwb_min_force=bc;
                if(!t->bwbAvail) avail_low_in_force=true;
            }
        }

        // ---- RX byte capture / framing (for the warm-up gate only) ----
        if(t->byte_rx_valid && t->byte_rx_ready){
            uint64_t w=(uint64_t)t->byte_rx_data;
            for(int b=0;b<8;b++){ uint8_t by=(uint8_t)(w>>(8*b)); curf.push_back(by);
                                  if(fbin) fputc(by,fbin); }
            if(t->byte_rx_last){
                bool ok = (curf.size()==(size_t)PKT_BYTES) && curf[0]==0x51 && curf[1]==0x4B
                          && curf[8]==0x21 && curf[9]==0x4E && curf[10]==0x47 && curf[11]==0x54;
                rx_frames++; if(ok) rx_good++;
                if(ff && rx_frames<=4000){
                    uint32_t s=0,c=0;
                    if(curf.size()>=12){
                        s = curf[4]|(curf[5]<<8)|(curf[6]<<16)|((uint32_t)curf[7]<<24);
                        c = curf[8]|(curf[9]<<8)|(curf[10]<<16)|((uint32_t)curf[11]<<24);
                    }
                    fprintf(ff,"%ld %ld %zu %d %u %08x ",rx_frames,clk,curf.size(),(int)ok,s,c);
                    for(size_t b=0;b<16 && b<curf.size();b++) fprintf(ff,"%02x",curf[b]);
                    fprintf(ff,"\n");
                }
                if(!en_done){
                    // The internal-loopback rail delivers TWO byte-plane frames
                    // per real frame -- one real, one all-zero filler (the
                    // 2x-packets artefact of beat_runs/THROUGHPUT.md) -- so
                    // "N consecutive good frames" never happens.  Wait for N
                    // good frames to have arrived, then enable right after a
                    // FILLER frame so the first frame the checker sees is a
                    // real one (and its seq seeds last_seq cleanly).
                    if(ok) warm_run++;
                    if(warm_run>=WARMUP_GOOD && !ok){
                        // pulse en on a frame boundary: rising edge clears the checker
                        t->chk_en=1;
                        en_done=true; en_clk=clk;
                        packets_at_en=t->packets_out; seq_at_en=t->tg_seq;
                        emitted_at_en=emitted;
                    }
                }
                curf.clear();
            }
        }

        // ---- periodic freeze read + CSV ----
        if(en_done && (long)t->k16 >= next_csv){
            freeze_read(); csv_row();
            last_csv_frames = cnt[0];
            next_csv = ((long)t->k16 / CSVSTEP + 1) * CSVSTEP;
        }

        if(en_done && drain_left<0 && (long)t->k16 >= nframes) drain_left = 2*AIR_FRAME_CLKS;
        if(drain_left>0 && --drain_left==0) break;
    }

    // ---- final atomic read ----
    freeze_read(); csv_row();
    long pdelta = (long)packets_now - (long)packets_at_en;
    long em_win = emitted - emitted_at_en;
    bool complete = ((long)cnt[0] >= nframes);

    snprintf(fn,sizeof fn,"%s_summary.txt",pfx); FILE* fs=fopen(fn,"w");
    fprintf(fs,"pfx=%s\n",pfx);
    { const char* e=getenv("QSIM_TGEN_START_DELAY"); fprintf(fs,"start_delay=%s\n", e?e:"0"); }
    fprintf(fs,"rtl_sha=%s\n",SEQBIST_RTL_SHA);
    fprintf(fs,"int_units=%s\n",SEQBIST_INT_UNITS);
    fprintf(fs,"nframes_target=%ld\nskip_every=%d\ncorrupt_every=%d\nfill=%d\ngap=%ld\n",
            nframes,skip_ev,corr_ev,fill,gap);
    fprintf(fs,"force=%s\nforce_frame=%ld\nforce_clks=%ld\n",force.c_str(),force_frame,force_clks);
    fprintf(fs,"clk_end=%ld\nen_clk=%ld\ncomplete=%d\n",clk,en_clk,(int)complete);
    fprintf(fs,"frames=%u\ngood=%u\ngarbage=%u\ncrc_fail=%u\n",cnt[0],cnt[1],cnt[2],cnt[3]);
    fprintf(fs,"lost_slots=%u\ngap_events=%u\ngap1=%u\ngap2=%u\ngap3plus=%u\n",
            cnt[4],cnt[5],cnt[6],cnt[7],cnt[8]);
    fprintf(fs,"dup_or_reorder=%u\nlast_seq=%u\nint_last=%u\n",cnt[9],cnt[10],cnt[11]);
    fprintf(fs,"int_lt30=%u\nint_32=%u\nint_33=%u\nint_other=%u\n",cnt[12],cnt[13],cnt[14],cnt[15]);
    fprintf(fs,"packets_delta=%ld\npackets_at_en=%u\n",pdelta,packets_at_en);
    fprintf(fs,"emitted_total=%ld\nemitted_in_window=%ld\nseq_at_en=%u\n",emitted,em_win,seq_at_en);
    fprintf(fs,"rx_frames=%ld\nrx_good=%ld\nbyte_fifo_ovf=%u\ncnt_frame_start=%u\n",rx_frames,rx_good,t->byte_fifo_ovf,t->cnt_frame_start);
    fprintf(fs,"bwb_min_global=%d\nbwb_min_force=%d\navail_low_in_force=%d\n",
            bwb_min_global,bwb_min_force,(int)avail_low_in_force);
    fprintf(fs,"force_word=%ld\nforce_start_clk=%ld\nforce_end_clk=%ld\nforce_end_emitted=%ld\n",
            force_word,force_start_clk,force_end_clk,force_end_emitted);
    fprintf(fs,"force_kind=%d\nemitted_in_force=%ld\nframes_per_force_window=%.2f\n",
            force_kind,emitted_in_force,(double)force_clks/197328.0);
    fprintf(fs,"csv_last_frames=%ld\n",last_csv_frames);
    fclose(fs); fclose(fc); if(ff) fclose(ff); if(fbin) fclose(fbin);

    printf("SEQBIST_GATE_SUMMARY pfx=%s frames=%u good=%u garbage=%u crc_fail=%u lost=%u "
           "gapev=%u gap1=%u int_last=%u emitted=%ld packets_delta=%ld rx=%ld complete=%d "
           "units=%s rtl=%s clk=%ld\n",
           pfx,cnt[0],cnt[1],cnt[2],cnt[3],cnt[4],cnt[5],cnt[6],cnt[11],
           em_win,pdelta,rx_frames,(int)complete,SEQBIST_INT_UNITS,SEQBIST_RTL_SHA,clk);
    int rc = complete ? 0 : 3;
    printf("SEQBIST_GATE_RUN_EXIT=%d\n", rc);
    fflush(stdout);
    delete t; return rc;
}
