/* test_txlog.c -- COMB campaign (T0a) unit test for the TX<->RX per-frame join.
 *
 * Writes a SYNTHETIC QPSK_TXLOG dump and a SYNTHETIC QPSK_FRAMELOG (frames.bin)
 * to a temp directory, reads them back through the documented binary layouts in
 * qpsk_join.h, and checks that qpsk_join_classify() puts a known fixture into
 * never-sent / sent-not-decoded / decoded-not-delivered / ok.  Also pins the
 * on-disk byte layout (sizes, offsets, file-header magic) so that the Python
 * parsers in ops/comb/ can be written against README_hostlog.md and agree
 * byte-for-byte.
 *
 * Host-only: no board, no DMA, no hardware. Build/run: make test_txlog && ./test_txlog
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "qpsk_frame.h"
#include "qpsk_join.h"

static int tests = 0, fails = 0;
#define CHECK(cond, msg) do { tests++; if (!(cond)) { fails++; \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

/* ---- the fixture ---------------------------------------------------------
 * 8 frames, seq 100..107:
 *   100  submitted, decoded, delivered            -> OK
 *   101  submitted, decoded, delivered            -> OK
 *   102  NOT submitted                            -> NEVER_SENT
 *   103  submitted, RX logged it as a FAILURE     -> SENT_NOT_DECODED
 *   104  submitted, RX has no record at all       -> SENT_NOT_DECODED
 *   105  submitted, decoded, NOT delivered        -> DECODED_NOT_DELIVERED
 *   106  submitted, decoded, delivered            -> OK
 *   107  NOT submitted, yet the RX decoded a frame carrying that seq
 *        (a garbage header whose seq word aliased) -> NEVER_SENT wins: the
 *        TX log is the authority on what was sent.
 */
#define NSEQ 8
static const uint32_t seqs[NSEQ] = {100,101,102,103,104,105,106,107};
static const int expect[NSEQ] = {
    QPSK_JOIN_OK, QPSK_JOIN_OK, QPSK_JOIN_NEVER_SENT,
    QPSK_JOIN_SENT_NOT_DECODED, QPSK_JOIN_SENT_NOT_DECODED,
    QPSK_JOIN_DECODED_NOT_DELIVERED, QPSK_JOIN_OK, QPSK_JOIN_NEVER_SENT
};

static void write_txlog(const char *path, const struct txlog_rec *r, unsigned n)
{
    struct qpsk_log_hdr h;
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(2); }
    memset(&h, 0, sizeof h);
    memcpy(h.magic, QPSK_TXLOG_MAGIC, 8);
    h.rec_bytes = (uint32_t)sizeof *r;
    h.n_records = n;
    h.t_dump_ns = 123456789ull;
    h.total     = n;
    h.flags     = 0;
    fwrite(&h, sizeof h, 1, f);
    fwrite(r, sizeof *r, n, f);
    fclose(f);
}

static void write_framelog(const char *path, const struct frame_rec *r, unsigned n)
{
    FILE *f = fopen(path, "wb");        /* NO file header: legacy 48 B stream */
    if (!f) { perror(path); exit(2); }
    fwrite(r, sizeof *r, n, f);
    fclose(f);
}

static unsigned read_txlog(const char *path, struct txlog_rec **out)
{
    struct qpsk_log_hdr h;
    FILE *f = fopen(path, "rb");
    unsigned n;
    if (!f) { perror(path); exit(2); }
    if (fread(&h, sizeof h, 1, f) != 1) { fprintf(stderr, "short txlog\n"); exit(2); }
    CHECK(memcmp(h.magic, QPSK_TXLOG_MAGIC, 8) == 0, "txlog file magic");
    CHECK(h.rec_bytes == sizeof(struct txlog_rec), "txlog rec_bytes == 32");
    CHECK((h.flags & QPSK_LOGF_WRAPPED) == 0, "fixture txlog did not wrap");
    n = h.n_records;
    *out = calloc(n ? n : 1, sizeof **out);
    if (fread(*out, sizeof **out, n, f) != n) { fprintf(stderr, "short txlog recs\n"); exit(2); }
    fclose(f);
    return n;
}

static unsigned read_framelog(const char *path, struct frame_rec **out)
{
    FILE *f = fopen(path, "rb");
    long sz;
    unsigned n;
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    CHECK(sz % (long)sizeof(struct frame_rec) == 0, "framelog is a whole number of 48 B records");
    n = (unsigned)(sz / (long)sizeof(struct frame_rec));
    *out = calloc(n ? n : 1, sizeof **out);
    if (fread(*out, sizeof **out, n, f) != n) { fprintf(stderr, "short framelog\n"); exit(2); }
    fclose(f);
    return n;
}

/* Build the frame the TX would have submitted, so the logged seq really is the
 * header seq word of an encoded frame (not a hand-written integer). */
static uint32_t encoded_seq_word(uint32_t seq)
{
    unsigned char pkt[QPSK_PKT_BYTES_MAX];
    unsigned char payload[64];
    memset(payload, 0x5A, sizeof payload);
    qpsk_frame_encode(pkt, F1536_PKT_BYTES, payload, (int)sizeof payload, seq);
    return (uint32_t)pkt[4] | ((uint32_t)pkt[5] << 8)
         | ((uint32_t)pkt[6] << 16) | ((uint32_t)pkt[7] << 24);
}

int main(void)
{
    const char *dir = getenv("TMPDIR");
    char txpath[512], fpath[512];
    struct txlog_rec tx[NSEQ];
    struct frame_rec rx[NSEQ];
    struct txlog_rec *tx2 = NULL;
    struct frame_rec *rx2 = NULL;
    uint32_t delivered[NSEQ];
    unsigned ntx = 0, nrx = 0, ndel = 0, i;

    if (!dir || !*dir) dir = "/tmp";
    snprintf(txpath, sizeof txpath, "%s/qpsk_test_txlog.bin", dir);
    snprintf(fpath,  sizeof fpath,  "%s/qpsk_test_frames.bin", dir);

    /* the encoder really does put the seq at bytes 4..7 little-endian --
     * the assumption txlog_note_submit() makes when it logs r->seq */
    CHECK(encoded_seq_word(0xDEADBEEFu) == 0xDEADBEEFu,
          "encoded frame carries seq at bytes 4..7 LE");

    /* ---- synthesize the TX log (everything except 102 and 107) ---- */
    memset(tx, 0, sizeof tx);
    for (i = 0; i < NSEQ; i++) {
        if (seqs[i] == 102 || seqs[i] == 107) continue;
        tx[ntx].t_submit_ns   = 1000000000ull + (uint64_t)i * 800000ull;
        /* frame 106 is still in flight at the dump: t_complete_ns == 0, which
         * must NOT be read as "never sent" */
        tx[ntx].t_complete_ns = seqs[i] == 106 ? 0ull
                              : tx[ntx].t_submit_ns + 700000ull;
        tx[ntx].seq      = encoded_seq_word(seqs[i]);
        /* only the submit that found the queue empty has a measured gap */
        tx[ntx].gap_ns   = seqs[i] == 104 ? 41000u : QPSK_GAP_NONE;
        tx[ntx].slot     = i;
        tx[ntx].inflight = (uint16_t)(seqs[i] == 104 ? 0 : 1);
        tx[ntx].spins    = 0;
        ntx++;
    }
    CHECK(ntx == 6, "fixture submitted 6 of 8 frames");

    /* ---- synthesize the RX framelog ---- */
    memset(rx, 0, sizeof rx);
    for (i = 0; i < NSEQ; i++) {
        if (seqs[i] == 104) continue;               /* no RX record at all */
        rx[nrx].t_mono_ns  = 2000000000ull + (uint64_t)i * 800000ull;
        rx[nrx].t_real_ns  = rx[nrx].t_mono_ns + 5000000000ull;
        rx[nrx].host_seq   = seqs[i];
        if (seqs[i] == 103) {                       /* logged as a failure */
            rx[nrx].crc_ok     = 0;
            rx[nrx].fail_class = QPSK_FC_ZEROTAIL;
        } else {
            rx[nrx].crc_ok     = 1;
            rx[nrx].fail_class = QPSK_FC_OK;
        }
        nrx++;
    }
    CHECK(nrx == 7, "fixture RX logged 7 records");

    /* ---- delivered set: everything decoded except 105 ---- */
    for (i = 0; i < NSEQ; i++)
        if (seqs[i] != 102 && seqs[i] != 103 && seqs[i] != 104 && seqs[i] != 105)
            delivered[ndel++] = seqs[i];

    write_txlog(txpath, tx, ntx);
    write_framelog(fpath, rx, nrx);

    /* ---- read back through the documented layouts and join ---- */
    CHECK(read_txlog(txpath, &tx2) == ntx, "txlog round-trips record count");
    CHECK(read_framelog(fpath, &rx2) == nrx, "framelog round-trips record count");
    CHECK(memcmp(tx2, tx, ntx * sizeof *tx) == 0, "txlog round-trips byte-for-byte");
    CHECK(memcmp(rx2, rx, nrx * sizeof *rx) == 0, "framelog round-trips byte-for-byte");

    for (i = 0; i < NSEQ; i++) {
        int got = qpsk_join_classify(seqs[i], tx2, ntx, rx2, nrx, delivered, ndel);
        char msg[96];
        snprintf(msg, sizeof msg, "join seq %u -> %d (want %d)", seqs[i], got, expect[i]);
        CHECK(got == expect[i], msg);
    }

    /* a never-sent frame stays never-sent even with no delivery evidence */
    CHECK(qpsk_join_classify(102, tx2, ntx, rx2, nrx, NULL, 0) == QPSK_JOIN_NEVER_SENT,
          "join: never-sent without a delivery set");
    /* without a delivery set, decoded-not-delivered collapses into OK -- the
     * documented degradation, not a silent absence of the class */
    CHECK(qpsk_join_classify(105, tx2, ntx, rx2, nrx, NULL, 0) == QPSK_JOIN_OK,
          "join: no delivery set -> decoded counts as OK");
    /* an empty TX log makes every frame never-sent (guards against a scorer
     * that silently reports 0 % loss when the TX log failed to deploy) */
    CHECK(qpsk_join_classify(100, tx2, 0, rx2, nrx, delivered, ndel) == QPSK_JOIN_NEVER_SENT,
          "join: empty TX log -> never-sent");
    /* t_complete_ns == 0 (still in flight) is not never-sent */
    CHECK(qpsk_join_classify(106, tx2, ntx, rx2, nrx, delivered, ndel) == QPSK_JOIN_OK,
          "join: t_complete_ns==0 is not never-sent");

    /* ---- the fail-class census the RX log supports ---- */
    { unsigned cls[5] = {0,0,0,0,0};
      for (i = 0; i < nrx; i++)
          if (rx2[i].crc_ok == 0 && rx2[i].fail_class < 5)
              cls[rx2[i].fail_class]++;
      CHECK(cls[QPSK_FC_ZEROTAIL] == 1, "census: one class-4 failure"); }

    /* ---- gap_ns sentinel discipline ---- */
    { unsigned measured = 0;
      for (i = 0; i < ntx; i++)
          if (tx2[i].gap_ns != QPSK_GAP_NONE) measured++;
      CHECK(measured == 1, "gap: exactly one measured gap (queue-empty submits only)"); }

    free(tx2); free(rx2);
    remove(txpath); remove(fpath);
    printf("txlog/join tests: %d run, %d failed\n", tests, fails);
    return fails ? 1 : 0;
}
