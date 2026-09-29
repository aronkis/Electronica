/* qpsk_fec -- systematic erasure FEC for the QPSK byte link.  See qpsk_fec.h
 * for the wire format, the erasure-vs-error argument and the ordering rule. */
#include "qpsk_fec.h"
#include <string.h>
#include <stdlib.h>

/* ---- GF(256), primitive polynomial 0x11D, generator 2 ------------------- */
static unsigned char gf_exp[512];
static unsigned char gf_log[256];
static unsigned char gen_m[QPSK_FEC_RMAX][QPSK_FEC_KMAX];
static int gf_ready = 0;

static unsigned char gf_mul(unsigned char a, unsigned char b)
{
    if (!a || !b) return 0;
    return gf_exp[(int)gf_log[a] + (int)gf_log[b]];
}
static unsigned char gf_inv(unsigned char a)      /* a != 0 */
{
    return gf_exp[255 - (int)gf_log[a]];
}

void qpsk_fec_init(void)
{
    unsigned x = 1;
    int i, j;

    if (gf_ready) return;
    for (i = 0; i < 255; i++) {
        gf_exp[i] = (unsigned char)x;
        gf_log[x] = (unsigned char)i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11Du;
    }
    for (i = 255; i < 512; i++) gf_exp[i] = gf_exp[i - 255];
    gf_log[0] = 0;                       /* never dereferenced: callers guard */

    /* Cauchy: g[j][i] = 1/(x_j + y_i) with x_j = j, y_i = RMAX + i.  The two
     * node sets are disjoint and internally distinct, so every square
     * submatrix is invertible.  Then normalise each COLUMN by its row-0 entry:
     * that scales each submatrix determinant by a nonzero constant (so they
     * all stay invertible) and makes row 0 the all-ones vector, i.e. parity
     * row 0 is a plain XOR with no multiplies at all -- the R=1 default. */
    for (i = 0; i < QPSK_FEC_KMAX; i++) {
        unsigned char c0 = gf_inv((unsigned char)(0 ^ (QPSK_FEC_RMAX + i)));
        unsigned char ic = gf_inv(c0);
        for (j = 0; j < QPSK_FEC_RMAX; j++) {
            unsigned char g = gf_inv((unsigned char)(j ^ (QPSK_FEC_RMAX + i)));
            gen_m[j][i] = gf_mul(g, ic);
        }
    }
    gf_ready = 1;
}

unsigned char qpsk_fec_gen(int j, int i)
{
    if (j < 0 || j >= QPSK_FEC_RMAX || i < 0 || i >= QPSK_FEC_KMAX) return 0;
    qpsk_fec_init();
    return gen_m[j][i];
}

/* dst ^= c * src, over n bytes.  c==1 is the XOR fast path (parity row 0). */
static void gf_maddr(unsigned char *dst, const unsigned char *src, int n,
                     unsigned char c)
{
    const unsigned char *lt;
    int i;

    if (c == 0) return;
    if (c == 1) { for (i = 0; i < n; i++) dst[i] ^= src[i]; return; }
    lt = &gf_exp[(int)gf_log[c]];
    for (i = 0; i < n; i++)
        if (src[i]) dst[i] ^= lt[(int)gf_log[src[i]]];
}

static void gf_scale(unsigned char *v, int n, unsigned char c)
{
    const unsigned char *lt;
    int i;

    if (c == 1) return;
    if (c == 0) { memset(v, 0, (size_t)n); return; }
    lt = &gf_exp[(int)gf_log[c]];
    for (i = 0; i < n; i++)
        if (v[i]) v[i] = lt[(int)gf_log[v[i]]];
}

/* Gauss-Jordan on an e x e GF(256) system whose right-hand sides are L-byte
 * vectors.  Row swaps permute the rhs pointer array with the matrix, so on
 * return rhs[b] holds unknown b.  e <= QPSK_FEC_RMAX (4), so this is tiny. */
static int gf_solve(unsigned char M[][QPSK_FEC_RMAX], int e,
                    unsigned char **rhs, int L)
{
    int c, r, k, piv;

    for (c = 0; c < e; c++) {
        piv = -1;
        for (r = c; r < e; r++) if (M[r][c]) { piv = r; break; }
        if (piv < 0) return -1;                 /* singular: cannot happen */
        if (piv != c) {
            unsigned char *tp;
            for (k = 0; k < e; k++) {
                unsigned char t = M[c][k]; M[c][k] = M[piv][k]; M[piv][k] = t;
            }
            tp = rhs[c]; rhs[c] = rhs[piv]; rhs[piv] = tp;
        }
        {
            unsigned char iv = gf_inv(M[c][c]);
            for (k = 0; k < e; k++) M[c][k] = gf_mul(M[c][k], iv);
            gf_scale(rhs[c], L, iv);
        }
        for (r = 0; r < e; r++) {
            unsigned char f = M[r][c];
            if (r == c || !f) continue;
            for (k = 0; k < e; k++) M[r][k] ^= gf_mul(M[c][k], f);
            gf_maddr(rhs[r], rhs[c], L, f);
        }
    }
    return 0;
}

/* ---- little-endian helpers ---------------------------------------------- */
static void put16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)(v & 0xFF); p[1] = (unsigned char)((v >> 8) & 0xFF);
}
static void put32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v & 0xFF);         p[1] = (unsigned char)((v >> 8) & 0xFF);
    p[2] = (unsigned char)((v >> 16) & 0xFF); p[3] = (unsigned char)((v >> 24) & 0xFF);
}
static unsigned get16(const unsigned char *p)
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8);
}
static uint32_t get32(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
/* wrap-safe "a is newer than b" */
static int seq_gt(uint32_t a, uint32_t b) { return (int32_t)(a - b) > 0; }

/* ---- encoder ------------------------------------------------------------ */
struct qpsk_fec_enc {
    int K, R, maxp, lcap;
    int n;                              /* data frames in the open group */
    int L;                              /* longest payload so far         */
    uint32_t base;
    uint32_t seqs[QPSK_FEC_KMAX];
    int      lens[QPSK_FEC_KMAX];
    unsigned char *d;                   /* K * maxp, zero-padded           */
};

qpsk_fec_enc *qpsk_fec_enc_new(int K, int R, int max_payload)
{
    qpsk_fec_enc *e;

    if (K < 1 || K > QPSK_FEC_KMAX) return NULL;
    if (R < 1 || R > QPSK_FEC_RMAX) return NULL;
    if (max_payload <= QPSK_FEC_HDR(K) + 16) return NULL;   /* nothing to protect */
    qpsk_fec_init();
    e = (qpsk_fec_enc *)calloc(1, sizeof *e);
    if (!e) return NULL;
    e->K = K; e->R = R; e->maxp = max_payload;
    e->lcap = max_payload - QPSK_FEC_HDR(K);
    e->d = (unsigned char *)calloc((size_t)K, (size_t)max_payload);
    if (!e->d) { free(e); return NULL; }
    return e;
}

void qpsk_fec_enc_free(qpsk_fec_enc *e)
{
    if (!e) return;
    free(e->d);
    free(e);
}

void qpsk_fec_enc_reset(qpsk_fec_enc *e) { if (e) { e->n = 0; e->L = 0; } }
int qpsk_fec_enc_pending(const qpsk_fec_enc *e) { return e ? e->n : 0; }
int qpsk_fec_enc_maxprot(const qpsk_fec_enc *e) { return e ? e->lcap : 0; }

int qpsk_fec_enc_add(qpsk_fec_enc *e, uint32_t seq,
                     const unsigned char *payload, int len)
{
    unsigned char *slot;

    if (!e || !payload || len <= 0) return -1;
    /* Too long to protect: the parity container could not carry L bytes plus
     * its own header inside one frame.  The caller flushes the open group and
     * sends this frame unprotected -- abandoning the whole group instead would
     * throw away protection for the frames already in it. */
    if (len > e->lcap) return -1;
    if (e->n == 0) e->base = seq;
    /* deltas are uint16 on the wire; a group that spans more than 65535 frame
     * slots (52 s at the R3 rate) cannot be described.  Treat like "too long". */
    if (e->n > 0 && (uint32_t)(seq - e->base) > 0xFFFFu) return -1;

    slot = e->d + (size_t)e->n * (size_t)e->maxp;
    memcpy(slot, payload, (size_t)len);
    memset(slot + len, 0, (size_t)(e->maxp - len));   /* zero pad: parity is
                                                       * over L >= len bytes */
    e->seqs[e->n] = seq;
    e->lens[e->n] = len;
    if (len > e->L) e->L = len;
    e->n++;
    return e->n >= e->K ? 1 : 0;
}

int qpsk_fec_enc_parity(qpsk_fec_enc *e, int j, unsigned char *out, int outcap)
{
    int K, L, hdr, i;
    unsigned char *p;

    if (!e || !out || j < 0 || j >= e->R || e->n <= 0) return -1;
    K = e->n;                      /* a flushed short group codes its real K */
    L = e->L;
    hdr = QPSK_FEC_HDR(K);
    if (hdr + L > outcap) return -1;

    out[0] = QPSK_FEC_MAGIC0; out[1] = QPSK_FEC_MAGIC1;
    out[2] = (unsigned char)QPSK_FEC_VER;
    out[3] = (unsigned char)QPSK_FEC_T_PARITY;
    out[4] = (unsigned char)K;
    out[5] = (unsigned char)e->R;
    out[6] = (unsigned char)j;
    out[7] = 0;
    put32(out + 8, e->base);
    put16(out + 12, (unsigned)L);
    for (i = 0; i < K; i++) {
        put16(out + 14 + 2 * i,         (unsigned)(e->seqs[i] - e->base));
        put16(out + 14 + 2 * K + 2 * i, (unsigned)e->lens[i]);
    }
    p = out + hdr;
    memset(p, 0, (size_t)L);
    for (i = 0; i < K; i++)
        gf_maddr(p, e->d + (size_t)i * (size_t)e->maxp, L, gen_m[j][i]);
    return hdr + L;
}

/* ---- container sniffing -------------------------------------------------- */
int qpsk_fec_is_parity(const unsigned char *buf, int len)
{
    int K, L;

    if (!buf || len < QPSK_FEC_HDR(1)) return 0;
    if (buf[0] != QPSK_FEC_MAGIC0 || buf[1] != QPSK_FEC_MAGIC1) return 0;
    if (buf[2] != QPSK_FEC_VER || buf[3] != QPSK_FEC_T_PARITY) return 0;
    K = buf[4]; L = (int)get16(buf + 12);
    if (K < 1 || K > QPSK_FEC_KMAX) return 0;
    if (buf[5] < 1 || buf[5] > QPSK_FEC_RMAX) return 0;
    if (buf[6] >= buf[5]) return 0;
    if (L < 1) return 0;
    return QPSK_FEC_HDR(K) + L == len;
}

/* ---- decoder ------------------------------------------------------------ */
struct dslot {
    uint32_t seq;
    int      len;
    double   t;
    unsigned char st;          /* 0 free, 1 held, 2 released (data retained) */
    unsigned char *buf;
};

#define PCACHE 8
struct pent {
    int used, K, R, j, L;
    uint32_t base;
    double t;
    uint16_t delta[QPSK_FEC_KMAX];
    uint16_t plen[QPSK_FEC_KMAX];
    unsigned char *par;
};

struct qpsk_fec_dec {
    int nslots, maxp, hiwater;
    double hold;
    struct dslot *s;
    unsigned char *pool;
    struct pent p[PCACHE];
    unsigned char *ppool;
    int have_rel;
    uint32_t rel;
    double tick;                          /* last `now` seen, for eviction   */
    struct qpsk_fec_stats st;
};

qpsk_fec_dec *qpsk_fec_dec_new(int slots, int max_payload, double hold_s)
{
    qpsk_fec_dec *d;
    int i;

    if (slots < 8 || slots > 4096 || max_payload < 16) return NULL;
    qpsk_fec_init();
    d = (qpsk_fec_dec *)calloc(1, sizeof *d);
    if (!d) return NULL;
    d->nslots = slots; d->maxp = max_payload;
    d->hold = hold_s > 0 ? hold_s : 0.040;
    d->hiwater = slots / 2;               /* forces release before the ring
                                           * can fill with held frames      */
    if (d->hiwater < 4) d->hiwater = 4;
    d->s = (struct dslot *)calloc((size_t)slots, sizeof *d->s);
    d->pool = (unsigned char *)calloc((size_t)slots, (size_t)max_payload);
    d->ppool = (unsigned char *)calloc((size_t)PCACHE, (size_t)max_payload);
    if (!d->s || !d->pool || !d->ppool) { qpsk_fec_dec_free(d); return NULL; }
    for (i = 0; i < slots; i++) d->s[i].buf = d->pool + (size_t)i * (size_t)max_payload;
    for (i = 0; i < PCACHE; i++) d->p[i].par = d->ppool + (size_t)i * (size_t)max_payload;
    return d;
}

void qpsk_fec_dec_free(qpsk_fec_dec *d)
{
    if (!d) return;
    free(d->s); free(d->pool); free(d->ppool); free(d);
}

void qpsk_fec_dec_hold(qpsk_fec_dec *d, double hold_s)
{
    if (d && hold_s > 0) d->hold = hold_s;
}

const struct qpsk_fec_stats *qpsk_fec_dec_stats(const qpsk_fec_dec *d)
{
    return d ? &d->st : NULL;
}

static struct dslot *find_slot(qpsk_fec_dec *d, uint32_t seq)
{
    int i;
    for (i = 0; i < d->nslots; i++)
        if (d->s[i].st && d->s[i].seq == seq) return &d->s[i];
    return NULL;
}

/* A free slot, or the lowest-seq RELEASED slot (its data is only kept as
 * solving history).  Never evicts a held frame: that would silently drop a
 * payload the caller has not seen yet. */
static struct dslot *take_slot(qpsk_fec_dec *d)
{
    struct dslot *best = NULL;
    int i;

    for (i = 0; i < d->nslots; i++) if (!d->s[i].st) return &d->s[i];
    for (i = 0; i < d->nslots; i++) {
        if (d->s[i].st != 2) continue;
        if (!best || seq_gt(best->seq, d->s[i].seq)) best = &d->s[i];
    }
    return best;
}

static int insert_data(qpsk_fec_dec *d, uint32_t seq, const unsigned char *p,
                       int len, double now)
{
    struct dslot *s;

    if (len <= 0 || len > d->maxp) return -1;
    if (d->have_rel && !seq_gt(seq, d->rel)) { d->st.dups++; return -1; }
    if (find_slot(d, seq))                  { d->st.dups++; return -1; }
    s = take_slot(d);
    if (!s) { d->st.overflow++; return -1; }
    s->seq = seq; s->len = len; s->t = now; s->st = 1;
    memcpy(s->buf, p, (size_t)len);
    return 0;
}

/* Try to rebuild the missing members of the group described by pent *pe,
 * using every cached parity row that belongs to the same group. */
static void try_recover(qpsk_fec_dec *d, const struct pent *pe, double now)
{
    struct dslot *have[QPSK_FEC_KMAX];
    int missing[QPSK_FEC_KMAX];
    const struct pent *rows[QPSK_FEC_RMAX];
    unsigned char *rhs[QPSK_FEC_RMAX];
    unsigned char M[QPSK_FEC_RMAX][QPSK_FEC_RMAX];
    unsigned char work[QPSK_FEC_RMAX][QPSK_PKT_MAXP_GUARD];
    int K = pe->K, L = pe->L, e = 0, nr = 0, i, a, b;

    if (L > QPSK_PKT_MAXP_GUARD) return;
    for (i = 0; i < K; i++) {
        uint32_t sq = pe->base + pe->delta[i];
        have[i] = find_slot(d, sq);
        if (!have[i]) {
            if (e < QPSK_FEC_KMAX) missing[e] = i;
            e++;
        }
    }
    if (e == 0) return;
    for (i = 0; i < PCACHE && nr < QPSK_FEC_RMAX; i++)
        if (d->p[i].used && d->p[i].base == pe->base && d->p[i].K == K &&
            d->p[i].L == L)
            rows[nr++] = &d->p[i];
    if (e > nr) {
        if (e > pe->R) d->st.unrecoverable++;   /* no row count could fix it */
        return;
    }

    /* RHS_a = P_{j_a} XOR sum_{i present} g[j_a][i] * D_i   (D_i zero-padded) */
    for (a = 0; a < e; a++) {
        memcpy(work[a], rows[a]->par, (size_t)L);
        rhs[a] = work[a];
        for (i = 0; i < K; i++) {
            if (!have[i]) continue;
            {
                unsigned char tmp[QPSK_PKT_MAXP_GUARD];
                int dl = have[i]->len;
                if (dl > L) dl = L;
                memcpy(tmp, have[i]->buf, (size_t)dl);
                memset(tmp + dl, 0, (size_t)(L - dl));
                gf_maddr(rhs[a], tmp, L, gen_m[rows[a]->j][i]);
            }
        }
        for (b = 0; b < e; b++)
            M[a][b] = gen_m[rows[a]->j][missing[b]];
    }
    if (gf_solve(M, e, rhs, L) != 0) return;

    for (b = 0; b < e; b++) {
        int idx = missing[b];
        uint32_t sq = pe->base + pe->delta[idx];
        int ln = pe->plen[idx];
        if (ln <= 0 || ln > L) continue;
        /* Ordering rule: a rebuild whose slot has already been released must
         * be thrown away.  Delivering it now would splice stale bytes into an
         * MPEG-TS stream that has already moved past them. */
        if (d->have_rel && !seq_gt(sq, d->rel)) { d->st.too_late++; continue; }
        if (find_slot(d, sq))                   { continue; }
        if (insert_data(d, sq, rhs[b], ln, now) == 0) d->st.recovered++;
    }
}

int qpsk_fec_dec_rx(qpsk_fec_dec *d, uint32_t seq, const unsigned char *payload,
                    int len, double now)
{
    struct pent *pe = NULL;
    int K, L, i;

    if (!d || !payload || len <= 0) return 0;
    d->tick = now;
    if (!qpsk_fec_is_parity(payload, len)) {
        if (insert_data(d, seq, payload, len, now) == 0) d->st.data_in++;
        return 0;
    }
    K = payload[4]; L = (int)get16(payload + 12);
    if (L > d->maxp) { d->st.parity_bad++; return 1; }

    for (i = 0; i < PCACHE; i++)
        if (d->p[i].used && d->p[i].base == get32(payload + 8) &&
            d->p[i].j == payload[6] && d->p[i].K == K) { d->st.dups++; return 1; }
    for (i = 0; i < PCACHE; i++)
        if (!d->p[i].used) { pe = &d->p[i]; break; }
    if (!pe) {                                  /* evict the oldest */
        pe = &d->p[0];
        for (i = 1; i < PCACHE; i++) if (d->p[i].t < pe->t) pe = &d->p[i];
    }
    pe->used = 1; pe->K = K; pe->R = payload[5]; pe->j = payload[6];
    pe->L = L;   pe->base = get32(payload + 8); pe->t = now;
    for (i = 0; i < K; i++) {
        pe->delta[i] = (uint16_t)get16(payload + 14 + 2 * i);
        pe->plen[i]  = (uint16_t)get16(payload + 14 + 2 * K + 2 * i);
    }
    memcpy(pe->par, payload + QPSK_FEC_HDR(K), (size_t)L);
    d->st.parity_in++;
    try_recover(d, pe, now);
    return 1;
}

int qpsk_fec_dec_pop(qpsk_fec_dec *d, unsigned char *out, int outcap,
                     uint32_t *seq, double now)
{
    struct dslot *lo = NULL;
    int held = 0, i, n;

    if (!d || !out) return 0;
    d->tick = now;
    for (i = 0; i < d->nslots; i++) {
        if (d->s[i].st != 1) continue;
        held++;
        if (!lo || seq_gt(lo->seq, d->s[i].seq)) lo = &d->s[i];
    }
    if (!lo) return 0;
    /* Release the oldest held frame when its hold expires, or early if the
     * ring is filling up.  Until then it waits for the parity that may still
     * rebuild the frames in front of it. */
    if (now - lo->t < d->hold && held < d->hiwater) return 0;
    n = lo->len;
    if (n > outcap) n = outcap;
    memcpy(out, lo->buf, (size_t)n);
    if (seq) *seq = lo->seq;
    lo->st = 2;                                 /* keep the data for solving */
    d->rel = lo->seq; d->have_rel = 1;
    d->st.released++;
    return n;
}

void qpsk_fec_dec_flush(qpsk_fec_dec *d)
{
    int i;
    if (!d) return;
    for (i = 0; i < d->nslots; i++) d->s[i].st = 0;
    for (i = 0; i < PCACHE; i++) d->p[i].used = 0;
    d->have_rel = 0;
}
