/* cyclic_ring_sim.c -- exercise the CYCLIC RX lap-detection guard in userspace.
 *
 * WHY. rx_pump_cyclic()'s overrun guard (st.seq_gaps, the "host fell >=1 full lap
 * behind" test) has NEVER executed a single frame on this rig: the deployed bitstream
 * is CONFIG.CYCLIC=0, so the probe got dma_rx_ok=0 and the path never ran. Flashing a
 * CYCLIC=1 build would put untested host code on the critical path AND make true
 * overflow structurally possible for the first time -- today an area is resubmitted
 * only after its drain completes, so the DMA can never overwrite an undrained slot.
 *
 * WHAT THIS TESTS, and what it CANNOT.
 *   CAN: rx_pump_cyclic is a pure function of the carve contents plus its own ring
 *   state -- it touches no DMA registers (only rx_arm_cyclic does). So the REAL
 *   function can be driven with an emulated DMA writer and the guard observed firing.
 *   CANNOT: whether the axi_dmac actually re-issues in cyclic mode. That is the
 *   CONFIG.CYCLIC=1 synthesis parameter itself, and no DMA-engine model exists here.
 *   Pre-flash that half is unprovable -- it is what the flash would test.
 *
 * Banked I/Q captures are deliberately NOT used: they drive the demod (samples ->
 * bits), whereas this guard sits above that, consuming DMA-written slices.
 *
 * Scenarios:
 *   1 KEEPUP   writer stays behind the reader   -> expect seq_gaps == 0, frames flow
 *   2 OVERRUN  writer laps the reader           -> expect seq_gaps > 0, guard fires
 *   3 EXACT    writer exactly one lap ahead     -> boundary: >= ring_slots must trip
 */
#define main qpsk_tun_main_unused
#include "qpsk_tun.c"
#undef main

#include <assert.h>

/* emulate the DMA writing frame `seq` into ring slot `slot` */
static void dma_write_slot(unsigned slot, uint32_t seq)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char payload[64];
    int i;
    for (i = 0; i < (int)sizeof payload; i++)
        payload[i] = (unsigned char)(seq + i);
    qpsk_frame_encode(pkt, pkt_bytes, payload, (int)sizeof payload, seq);
    memcpy(rxbuf + (size_t)slot * (size_t)pkt_bytes, pkt, (size_t)pkt_bytes);
}

static void reset_ring(unsigned slots)
{
    rx_ring_slots = slots;
    rx_ring_scan  = 0;
    rx_cyc_last   = 0;
    rx_cyc_have   = 0;
    memset(&st, 0, sizeof st);
    memset(rxbuf, 0, (size_t)slots * (size_t)pkt_bytes);
    rx_active = 1;          /* skip rx_arm_cyclic (it would touch DMA registers) */
}

int main(void)
{
    unsigned char out[QPSK_PKT_BYTES_MAX];
    uint32_t seq;
    const unsigned SLOTS = 16;
    int fail = 0;

    pkt_bytes = 1400;
    rxbuf = calloc(SLOTS + 4, pkt_bytes);
    assert(rxbuf);

    /* ---- 1. KEEP-UP: reader consumes each slot before the writer wraps ---- */
    reset_ring(SLOTS);
    {
        unsigned delivered = 0;
        uint32_t s;
        for (s = 1; s <= 200; s++) {
            dma_write_slot((s - 1) % SLOTS, s);
            if (rx_pump_cyclic(out, &seq) > 0) delivered++;
        }
        printf("1 KEEPUP : delivered=%u  seq_gaps=%llu  (expect gaps=0, delivered>0)\n",
               delivered, (unsigned long long)st.seq_gaps);
        if (st.seq_gaps != 0) { printf("   FAIL: guard fired with no overrun\n"); fail = 1; }
        if (delivered == 0)   { printf("   FAIL: cyclic path delivered NOTHING\n"); fail = 1; }
    }

    /* ---- 2. OVERRUN: writer laps the reader; guard must fire ---- */
    reset_ring(SLOTS);
    {
        unsigned delivered = 0;
        uint32_t s;
        /* prime: reader consumes a few in step */
        for (s = 1; s <= 4; s++) {
            dma_write_slot((s - 1) % SLOTS, s);
            if (rx_pump_cyclic(out, &seq) > 0) delivered++;
        }
        /* writer races a full lap ahead while the reader is stalled */
        for (s = 5; s <= 4 + 2 * SLOTS; s++)
            dma_write_slot((s - 1) % SLOTS, s);
        /* reader resumes: the next slot holds a seq a full lap beyond the last */
        if (rx_pump_cyclic(out, &seq) > 0) delivered++;
        printf("2 OVERRUN: delivered=%u  seq_gaps=%llu  (expect gaps>=1 -- guard fires)\n",
               delivered, (unsigned long long)st.seq_gaps);
        if (st.seq_gaps == 0) {
            printf("   FAIL: writer lapped the reader and the guard did NOT fire\n");
            fail = 1;
        }
    }

    /* ---- 3. EXACT boundary: a jump of exactly ring_slots must count ---- */
    reset_ring(SLOTS);
    {
        uint32_t s;
        for (s = 1; s <= 2; s++) {
            dma_write_slot((s - 1) % SLOTS, s);
            (void)rx_pump_cyclic(out, &seq);
        }
        /* place seq exactly SLOTS beyond rx_cyc_last in the next slot to be scanned */
        dma_write_slot(rx_ring_scan, rx_cyc_last + SLOTS);
        (void)rx_pump_cyclic(out, &seq);
        printf("3 EXACT  : seq_gaps=%llu  (jump == ring_slots must count as overrun)\n",
               (unsigned long long)st.seq_gaps);
        if (st.seq_gaps == 0) { printf("   FAIL: boundary jump not counted\n"); fail = 1; }
    }

    printf("\n%s\n", fail ? "CYCLIC_RING_SIM: FAIL" : "CYCLIC_RING_SIM: PASS");
    return fail;
}
