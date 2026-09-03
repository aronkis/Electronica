// sim_byte_dmac.cpp -- REAL axi_dmac (wrap_byte_dmac.v) driven by a clean seq-numbered
// 64-bit word stream at the modem's cadence, with a host model that replays
// qpsk_tun.c's register sequences (RXQ=0 reset-per-transfer / RXQ=1 one-ahead queue)
// and an always-ready DDR write slave. Scores frames from the DDR image exactly like
// the air legs (seq holes, drops in the denominator, hole bins) and reconciles word
// counts: offered == fifo_dropped + accepted; accepted == ddr_written + in_flight.
//
// env knobs (defaults = shipped f1536 -M16 configuration):
//   MODE=rxq0|rxq1      host RX mode                     M=16        frames per transfer
//   NFRAMES=1000        frames offered                   PERIOD=545  clk per word (modem cadence)
//   UPSTREAM=wait|fifo  wait = upstream holds the word until accepted (infinite buffer, schedule
//                       preserved); fifo = ByteRxFifo-like drop-head-on-overflow model, depth DEPTH
//   DEPTH=64            fifo depth (64 = shipped comb image, 4096 = rxfifo4k image)
//   RDYRUN=6            fifo mode: valid needs ready high for RDYRUN clks first (ByteRxFifo rdyRun>=6)
//   POLL=245            clk between host TRANSFER_DONE polls (2 us @122.88 MHz)
//   AXILAT=40           extra clk per host register access (LPD round trip ~0.3 us)
//   REARM=2458          rxq0: clk from DONE seen to the reset+program+submit burst (carve_zero etc., 20 us)
//   DRAIN=1229          rxq1: clk from DONE seen to the re-submit of the drained area (10 us)
//   MASKUSER=0          Option E: 1 = force tuser=0 after the first accepted beat of each armed engine
//   PREARM=3000         clk of stream before the host arms (sets the arm phase within a frame)
//   JITTER_EVERY=0      every Nth frame is emitted with WPF+JITTER_DELTA words (0 = all frames exactly 191)
//   JITTER_DELTA=1
// NOTE (RTL fidelity): ByteRxFifo drives outFirst/outWord from the HEAD word whether or not valid is
// asserted (rdyRun>=6 gate only masks valid), so the DMAC's has_sync sees the head's wFirst while idle.
// The model mirrors that: s_axis_user = head.first whenever the upstream is non-empty.
//   VERBOSE=0
#include "Vwrap_byte_dmac.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <deque>
#include <map>
#include <string>
#include <algorithm>

static Vwrap_byte_dmac* T;
static long clk = 0;
static long envl(const char* n, long d){ const char* v=getenv(n); return v? atol(v): d; }
static std::string envs(const char* n, const char* d){ const char* v=getenv(n); return v? v: d; }

// ---- configuration
static std::string MODE, UPSTREAM;
static long M, NFRAMES, PERIOD, DEPTH, RDYRUN, POLL, AXILAT, REARM, DRAIN, MASKUSER, VERBOSE, PREARM, JITTER_EVERY, JITTER_DELTA;
static const long WPF = 191;                 // words per frame (1528 B)
static const long PKT_BYTES = 1528;
static const uint64_t RX_BASE = 0x40000000ULL;
static const long AREA_SPAN = 64 * 2048;     // RX_MULTI_MAX * SLOT_BYTES (rx_area_span)

// ---- stream generator / upstream model
static long gen_next_frame = 1;              // seq of next frame to generate (starts at 1)
static long gen_word = 0;                    // word index within the frame being generated
static long gen_due = 0;                     // clk at which the next word is due
static long gen_offered = 0, gen_done = 0;
static long fifo_dropped = 0;
static long acc_words = 0, acc_user = 0;
static bool user_mask = false;
struct W { uint64_t d; bool u; };
static std::deque<W> q;                      // upstream buffer (wait: unbounded; fifo: DEPTH)
static long rdyRun = 0;
static bool pres_valid = false; static W pres;

static inline uint64_t mkword(long seq, long j){
    if (j == 0) return (0x514B000000000000ULL) | (uint64_t)(uint32_t)seq;
    return ((uint64_t)(uint32_t)seq << 32) | (uint64_t)(uint32_t)j;
}
static void gen_step(){
    // produce words on schedule (may produce several if stalled -- schedule never slips)
    while (gen_next_frame <= NFRAMES && clk >= gen_due) {
        long wpf = WPF + ((JITTER_EVERY > 0 && gen_next_frame % JITTER_EVERY == 0) ? JITTER_DELTA : 0);
        W w{ mkword(gen_next_frame, gen_word), gen_word == 0 };
        gen_offered++;
        if (UPSTREAM == "fifo" && (long)q.size() >= DEPTH) { q.pop_front(); fifo_dropped++; pres_valid = false; } // ByteRxFifo: drop OLDEST (head, even if presented), keep new
        q.push_back(w);
        gen_due += PERIOD;
        if (++gen_word == wpf) { gen_word = 0; gen_next_frame++; }
    }
    if (gen_next_frame > NFRAMES) gen_done = 1;
}

// ---- DDR model
static std::vector<uint64_t> mem(2 * AREA_SPAN / 8, 0);
static std::vector<long> mem_t(2 * AREA_SPAN / 8, -1);   // clk of last write per word (fresh-vs-stale)
static long ddr_written = 0, ddr_bad_addr = 0;
static uint64_t cur_waddr = 0; static bool have_aw = false; static std::deque<uint64_t> awq;
static int bvalid_pend = 0;

// ---- witness / timing stats
static long prev_active = 0, t_active_fall = -1, t_active_rise = -1, first_beat_pending = 0;
static std::vector<long> handoff_lat, sync_wait;
static long blocked_sync_cycles = 0;   // valid && !ready && needs_sync (upstream held while engine waits for a frame start)
static long blocked_idle_cycles = 0;   // valid && !ready && !active

static void tick(){
    // ---- drive stream inputs for this edge
    gen_step();
    bool can_present;
    if (UPSTREAM == "fifo") can_present = !q.empty() && rdyRun >= RDYRUN;
    else                    can_present = !q.empty();
    if (!pres_valid && can_present) { pres = q.front(); pres_valid = true; }
    T->s_axis_valid = pres_valid;
    T->s_axis_data  = pres_valid ? pres.d : 0;
    T->s_axis_user  = (!q.empty() && q.front().u && !user_mask) ? 1 : 0;   // head flag, valid-independent (RTL)
    T->s_axis_last  = 0;
    // DDR slave: always ready
    T->m_awready = 1; T->m_wready = 1; T->m_bvalid = bvalid_pend > 0;
    T->clk = 0; T->eval();
    bool ready = T->s_axis_ready;
    bool aw = T->m_awvalid, wv = T->m_wvalid, wl = T->m_wlast, br = T->m_bready;
    uint64_t awaddr = T->m_awaddr, wdata = T->m_wdata;
    bool needs_sync = T->wit_needs_sync, active = T->wit_active;
    // ---- rising edge
    T->clk = 1; T->eval(); clk++;
    // stream handshake
    if (pres_valid && ready) {
        acc_words++; if (pres.u && !user_mask) acc_user++;
        q.pop_front(); pres_valid = false;
        if (first_beat_pending) { sync_wait.push_back(clk - t_active_rise); first_beat_pending = 0; if (MASKUSER) user_mask = true; }
    } else if (pres_valid && !ready) {
        if (needs_sync && active) blocked_sync_cycles++;
        else if (!active) blocked_idle_cycles++;
    }
    rdyRun = ready ? std::min(rdyRun + 1, 255L) : 0;
    // DDR
    if (aw) awq.push_back(awaddr);
    if (wv) {
        if (!have_aw && !awq.empty()) { cur_waddr = awq.front(); awq.pop_front(); have_aw = true; }
        if (have_aw) {
            long idx = (long)((cur_waddr - RX_BASE) / 8);
            if (cur_waddr >= RX_BASE && idx < (long)mem.size()) { mem[idx] = wdata; mem_t[idx] = clk; } else ddr_bad_addr++;
            cur_waddr += 8; ddr_written++;
            if (wl) { have_aw = false; bvalid_pend++; }
        } else ddr_bad_addr++;
    }
    if (bvalid_pend > 0 && br && T->m_bvalid) bvalid_pend--;
    // witness edges
    if (active && !prev_active) { t_active_rise = clk; if (t_active_fall >= 0) handoff_lat.push_back(clk - t_active_fall); first_beat_pending = 1; }
    if (!active && prev_active) { t_active_fall = clk; }
    prev_active = active;
}
static void ticks(long n){ while (n-- > 0) tick(); }

// ---- AXI-Lite master (blocking, ticks the world)
static void axi_w(uint32_t addr, uint32_t data){
    ticks(AXILAT);
    T->s_axi_awvalid = 1; T->s_axi_awaddr = addr & 0x7FF; T->s_axi_wvalid = 1; T->s_axi_wdata = data; T->s_axi_bready = 1;
    bool awd=false, wd=false;
    for (int i=0;i<200;i++){
        T->clk=0; T->eval();
        bool awr = T->s_axi_awready, wr = T->s_axi_wready;
        tick();
        if (!awd && awr) { awd=true; T->s_axi_awvalid=0; }
        if (!wd && wr)   { wd=true;  T->s_axi_wvalid=0; }
        if (awd && wd) break;
    }
    for (int i=0;i<200;i++){ T->clk=0; T->eval(); bool b=T->s_axi_bvalid; tick(); if (b) break; }
    T->s_axi_bready = 0;
}
static uint32_t axi_r(uint32_t addr){
    ticks(AXILAT);
    T->s_axi_arvalid = 1; T->s_axi_araddr = addr & 0x7FF; T->s_axi_rready = 1;
    for (int i=0;i<200;i++){ T->clk=0; T->eval(); bool ar=T->s_axi_arready; tick(); if (ar) { T->s_axi_arvalid=0; break; } }
    uint32_t d=0;
    for (int i=0;i<200;i++){ T->clk=0; T->eval(); bool rv=T->s_axi_rvalid; d=T->s_axi_rdata; tick(); if (rv) break; }
    T->s_axi_rready = 0;
    return d;
}
// regmap (qpsk_tun.c:105-115)
enum { R_IRQ_MASK=0x080, R_CONTROL=0x400, R_TRANSFER_ID=0x404, R_SUBMIT=0x408, R_FLAGS=0x40C, R_DEST=0x410, R_XLEN=0x418, R_DONE=0x428 };

// ---- host-side scoring (mirrors the air-leg scorer: seq holes, drops in denominator)
static long sc_expected = 1, sc_good = 0, sc_lost = 0, sc_junk = 0, sc_dup = 0, sc_transfers = 0, sc_first_seq = -1, sc_last_seq = -1;
static std::map<long,long> hole_bins;          // hole length -> count
static std::map<long,long> hole_pos;           // slot index (within transfer) where a hole begins -> count
static std::map<long,long> junk_pos;
static long area_phys(int area){ return RX_BASE + (long)area * AREA_SPAN; }
static void carve_zero(int area){ long b=(long)area*AREA_SPAN/8; for (long i=0;i<M*WPF;i++){ mem[b+i]=0; mem_t[b+i]=-1; } }
static void score_area(int area, long t_done){
    sc_transfers++;
    long b=(long)area*AREA_SPAN/8;
    for (long k=0;k<M;k++){
        uint64_t w0 = mem[b+k*WPF];
        bool magic = (w0 >> 32) == 0x514B0000ULL;
        long seq = (long)(uint32_t)w0;
        // frame body check: words 1..190 must carry the same seq (catches a slot assembled from two frames)
        bool body_ok = magic;
        if (magic) for (long j=1;j<WPF;j++){ uint64_t wj=mem[b+k*WPF+j]; if ((long)(wj>>32)!=seq || (long)(uint32_t)wj!=j){ body_ok=false; break; } }
        if (!magic || !body_ok) { sc_junk++; junk_pos[k]++; continue; }
        if (sc_first_seq < 0) { sc_first_seq = seq; sc_expected = seq; }
        if (seq < sc_expected) { sc_dup++; continue; }
        if (seq > sc_expected) { long h = seq - sc_expected; sc_lost += h; hole_bins[h]++; hole_pos[k]++; }
        sc_good++; sc_expected = seq + 1; sc_last_seq = seq;
    }
    (void)t_done;
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    MODE=envs("MODE","rxq1"); UPSTREAM=envs("UPSTREAM","wait");
    M=envl("M",16); NFRAMES=envl("NFRAMES",1000); PERIOD=envl("PERIOD",545); DEPTH=envl("DEPTH",64); RDYRUN=envl("RDYRUN",6);
    POLL=envl("POLL",245); AXILAT=envl("AXILAT",40); REARM=envl("REARM",2458); DRAIN=envl("DRAIN",1229); MASKUSER=envl("MASKUSER",0); VERBOSE=envl("VERBOSE",0); PREARM=envl("PREARM",3000); JITTER_EVERY=envl("JITTER_EVERY",0); JITTER_DELTA=envl("JITTER_DELTA",1);
    T = new Vwrap_byte_dmac;
    T->resetn = 0; T->s_axi_awvalid=0; T->s_axi_wvalid=0; T->s_axi_arvalid=0; T->s_axi_bready=0; T->s_axi_rready=0;
    ticks(50); T->resetn = 1; ticks(20);
    // stream starts immediately (the modem never stops); the host arms a little later, like bring-up
    gen_due = clk + 100;
    ticks(PREARM); // stream already flowing before the arm (arm phase within a frame = PREARM/PERIOD mod 191)

    const uint32_t XLEN = (uint32_t)(M * PKT_BYTES) - 1;
    long last_progress = clk;
    if (MODE == "rxq0") {
        auto rx_arm = [&](int area){
            carve_zero(area);
            axi_w(R_CONTROL,0); axi_w(R_CONTROL,1); axi_w(R_IRQ_MASK,3);
            axi_w(R_DEST,(uint32_t)area_phys(area)); axi_w(R_XLEN,XLEN); axi_w(R_FLAGS,0); axi_w(R_SUBMIT,1);
            user_mask = false;
        };
        int fill = 0; rx_arm(0);
        while (!(gen_done && q.empty() && !pres_valid) || sc_transfers*M < NFRAMES - 2*M) {
            ticks(POLL);
            if (axi_r(R_DONE) & 1) {
                long t_done = clk;
                ticks(REARM);
                int completed = fill; fill ^= 1;
                rx_arm(fill);                    // "rearm before decoding" (rx_pump_multi)
                score_area(completed, t_done);
                last_progress = clk;
            }
            if (clk - last_progress > 200L * WPF * PERIOD) { printf("STALL: no completion for 200 frame-times\n"); break; }
            if (gen_done && clk - gen_due > 4L*M*WPF*PERIOD) break;
        }
    } else {
        unsigned nsub = 0; int q_id[2] = {0,0};
        auto submit = [&](int area){
            int spins = 64; while ((axi_r(R_SUBMIT) & 1) && --spins > 0) ;
            if (spins <= 0) { printf("SUBMIT_DEFER area=%d\n", area); }
            carve_zero(area);
            axi_w(R_DEST,(uint32_t)area_phys(area)); axi_w(R_XLEN,XLEN); axi_w(R_FLAGS,0); axi_w(R_SUBMIT,1);
            q_id[area] = (int)(nsub++ & 3u);
        };
        axi_w(R_CONTROL,0); axi_w(R_CONTROL,1); axi_w(R_IRQ_MASK,3);
        nsub = 0; submit(0); submit(1);
        int fill = 0;
        while (!(gen_done && q.empty() && !pres_valid) || sc_transfers*M < NFRAMES - 2*M) {
            ticks(POLL);
            uint32_t done = axi_r(R_DONE);
            if ((done >> q_id[fill]) & 1) {
                long t_done = clk;
                int completed = fill; fill ^= 1;
                // drain (host consumes the completed area), then re-queue it
                score_area(completed, t_done);
                ticks(DRAIN);
                submit(completed);
                last_progress = clk;
            }
            if (clk - last_progress > 200L * WPF * PERIOD) { printf("STALL: no completion for 200 frame-times\n"); break; }
            if (gen_done && clk - gen_due > 4L*M*WPF*PERIOD) break;
        }
    }
    // ---- report
    long offered_frames = (sc_last_seq > 0 && sc_first_seq > 0) ? (sc_last_seq - sc_first_seq + 1) : 0;
    long lost_total = offered_frames - sc_good;      // drops (holes) + anything after a junk slot
    double per = offered_frames ? 100.0 * lost_total / offered_frames : -1;
    printf("RESULT mode=%s upstream=%s depth=%ld M=%ld period=%ld maskuser=%ld nframes=%ld prearm=%ld jitter=%ld/%ld\n", MODE.c_str(), UPSTREAM.c_str(), DEPTH, M, PERIOD, MASKUSER, NFRAMES, PREARM, JITTER_EVERY, JITTER_DELTA);
    printf("SCORE transfers=%ld offered=%ld good=%ld lost=%ld junk_slots=%ld dup=%ld PER=%.3f%% lost_per_transfer=%.3f\n",
           sc_transfers, offered_frames, sc_good, lost_total, sc_junk, sc_dup, per, sc_transfers ? (double)lost_total/sc_transfers : 0.0);
    printf("HOLE_BINS"); for (auto& kv : hole_bins) printf(" %ld:%ld", kv.first, kv.second); printf("\n");
    printf("HOLE_POS(slot in transfer)"); for (auto& kv : hole_pos) printf(" %ld:%ld", kv.first, kv.second); printf("\n");
    printf("JUNK_POS(slot in transfer)"); for (auto& kv : junk_pos) printf(" %ld:%ld", kv.first, kv.second); printf("\n");
    long inflight = acc_words - ddr_written;
    printf("RECON offered_words=%ld fifo_dropped=%ld accepted=%ld ddr_written=%ld in_flight(acc-written)=%ld bad_addr=%ld upstream_backlog=%zu user_beats_accepted=%ld\n",
           gen_offered, fifo_dropped, acc_words, ddr_written, inflight, ddr_bad_addr, q.size(), acc_user);
    printf("WITNESS blocked_cycles_waiting_for_sync=%ld blocked_cycles_engine_idle=%ld (word period %ld clk)\n", blocked_sync_cycles, blocked_idle_cycles, PERIOD);
    auto stats=[&](const char* n, std::vector<long>& v){ if (v.empty()){ printf("%s n=0\n", n); return; } long mn=v[0],mx=v[0]; double s=0; for(long x:v){ mn=std::min(mn,x); mx=std::max(mx,x); s+=x; } printf("%s n=%zu min=%ld mean=%.1f max=%ld clk\n", n, v.size(), mn, s/v.size(), mx); };
    stats("HANDOFF(active fall -> next active rise)", handoff_lat);
    stats("SYNCWAIT(active rise -> first accepted beat)", sync_wait);
    delete T;
    return 0;
}
