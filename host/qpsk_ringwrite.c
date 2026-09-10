/* qpsk_ringwrite -- continuous IQ ring buffer + error-triggered window save.
 *
 * WRITER:  <producer> | qpsk_ringwrite <ringfile> <ring_bytes[K|M|G]>
 *   Reads stdin (e.g. iio_readdev streaming int16 I/Q) and writes it
 *   circularly into <ringfile> after a 4 KiB header. The header's
 *   total_written counter is monotonic, so any consumer can map a trigger
 *   instant to a byte position and know how much history survives.
 *
 * SAVER:   qpsk_ringwrite --save <ringfile> <out> <pre[K|M]> <post[K|M]>
 *   Snapshot the ring at invocation (the trigger point), wait until `post`
 *   more bytes have been written, then copy [trigger-pre, trigger+post) into
 *   <out> (linearized) + <out>.meta (byte offsets, times, rate). Exits 3 with
 *   "TORN" if the writer lapped the requested window while saving.
 *
 * The ring lives in tmpfs (/dev/shm); at the K5 Tap rate (7.7 MB/s per
 * complex channel) a 512M ring holds ~33 s of 4-channel or ~66 s of
 * 2-channel history. Header fields are aligned u64s -- single-word updates,
 * safe to poll from the saver without locks.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define HDR_BYTES 4096
#define MAGIC 0x3152514951ull   /* "QIQR1" */

struct ring_hdr {
    uint64_t magic;
    uint64_t ring_bytes;
    uint64_t total_written;     /* monotonic bytes since start */
    uint64_t t0_ns;             /* CLOCK_MONOTONIC at writer start */
    uint64_t last_ns;           /* CLOCK_MONOTONIC at last write */
    uint64_t rate_bps;          /* EWMA bytes/s (informational) */
};

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint64_t parse_size(const char *s)
{
    char *end = NULL;
    double v = strtod(s, &end);
    uint64_t m = 1;
    if (end && *end) {
        if (*end == 'K' || *end == 'k') m = 1024;
        else if (*end == 'M' || *end == 'm') m = 1024 * 1024;
        else if (*end == 'G' || *end == 'g') m = 1024ull * 1024 * 1024;
    }
    return (uint64_t)(v * (double)m);
}

static int writer(const char *path, uint64_t ring_bytes)
{
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror(path); return 1; }
    if (ftruncate(fd, (off_t)(HDR_BYTES + ring_bytes)) != 0) {
        perror("ftruncate"); return 1;
    }
    unsigned char *map = mmap(NULL, HDR_BYTES + ring_bytes,
                              PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    volatile struct ring_hdr *h = (volatile struct ring_hdr *)map;
    unsigned char *ring = map + HDR_BYTES;

    h->magic = 0;               /* not valid until fields are set */
    h->ring_bytes = ring_bytes;
    h->total_written = 0;
    h->t0_ns = now_ns();
    h->last_ns = h->t0_ns;
    h->rate_bps = 0;
    h->magic = MAGIC;

    static unsigned char buf[1 << 18];   /* 256 KiB */
    uint64_t rate = 0, win_bytes = 0, win_t0 = h->t0_ns;
    for (;;) {
        ssize_t n = read(0, buf, sizeof buf);
        if (n == 0)
            break;                        /* producer ended */
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read"); break;
        }
        uint64_t off = h->total_written % ring_bytes;
        uint64_t first = (uint64_t)n;
        if (off + first > ring_bytes)
            first = ring_bytes - off;
        memcpy(ring + off, buf, first);
        if ((uint64_t)n > first)
            memcpy(ring, buf + first, (uint64_t)n - first);
        h->total_written += (uint64_t)n;   /* publish AFTER the data lands */
        uint64_t t = now_ns();
        h->last_ns = t;
        win_bytes += (uint64_t)n;
        if (t - win_t0 > 500000000ull) {   /* 0.5 s rate window */
            uint64_t inst = win_bytes * 1000000000ull / (t - win_t0);
            rate = rate ? (rate * 7 + inst * 3) / 10 : inst;
            h->rate_bps = rate;
            win_bytes = 0;
            win_t0 = t;
        }
    }
    fprintf(stderr, "qpsk_ringwrite: producer ended, total=%llu bytes\n",
            (unsigned long long)h->total_written);
    return 0;
}

static int saver(const char *path, const char *out, uint64_t pre, uint64_t post)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < HDR_BYTES) {
        fprintf(stderr, "bad ring file\n"); return 1;
    }
    unsigned char *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED,
                              fd, 0);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }
    volatile struct ring_hdr *h = (volatile struct ring_hdr *)map;
    if (h->magic != MAGIC) { fprintf(stderr, "no writer header\n"); return 1; }
    const unsigned char *ring = map + HDR_BYTES;
    uint64_t ring_bytes = h->ring_bytes;
    if (pre + post > ring_bytes * 8 / 10) {
        fprintf(stderr, "window %llu > 80%% of ring %llu\n",
                (unsigned long long)(pre + post),
                (unsigned long long)ring_bytes);
        return 2;
    }

    uint64_t trig_total = h->total_written;
    uint64_t trig_ns = now_ns();
    uint64_t pre_have = trig_total < pre ? trig_total : pre;
    uint64_t start_total = trig_total - pre_have;

    /* wait for the post-window to land (bounded: 30 s or writer stall) */
    uint64_t deadline = trig_ns + 30ull * 1000000000ull;
    while (h->total_written < trig_total + post) {
        if (now_ns() > deadline) {
            fprintf(stderr, "post-window timeout (writer stalled?)\n");
            post = h->total_written - trig_total;   /* save what exists */
            break;
        }
        usleep(20000);
    }
    uint64_t end_total = trig_total + post;

    FILE *fo = fopen(out, "wb");
    if (!fo) { perror(out); return 1; }
    uint64_t len = end_total - start_total;
    for (uint64_t p = start_total; p < end_total; ) {
        uint64_t off = p % ring_bytes;
        uint64_t chunk = end_total - p;
        if (off + chunk > ring_bytes)
            chunk = ring_bytes - off;
        if (fwrite(ring + off, 1, (size_t)chunk, fo) != chunk) {
            perror("fwrite"); fclose(fo); return 1;
        }
        p += chunk;
    }
    fclose(fo);

    /* torn check: did the writer lap our start while we copied? */
    int torn = (h->total_written > start_total + ring_bytes);

    char metapath[1024];
    snprintf(metapath, sizeof metapath, "%s.meta", out);
    FILE *fm = fopen(metapath, "w");
    if (fm) {
        fprintf(fm,
            "trig_total=%llu start_total=%llu end_total=%llu len=%llu\n"
            "pre_have=%llu post=%llu trig_off_in_file=%llu\n"
            "trig_mono_ns=%llu writer_t0_ns=%llu rate_bps=%llu torn=%d\n",
            (unsigned long long)trig_total, (unsigned long long)start_total,
            (unsigned long long)end_total, (unsigned long long)len,
            (unsigned long long)pre_have, (unsigned long long)post,
            (unsigned long long)pre_have,
            (unsigned long long)trig_ns, (unsigned long long)h->t0_ns,
            (unsigned long long)h->rate_bps, torn);
        fclose(fm);
    }
    fprintf(stderr, "saved %llu bytes -> %s (trigger at +%llu)%s\n",
            (unsigned long long)len, out, (unsigned long long)pre_have,
            torn ? " TORN" : "");
    return torn ? 3 : 0;
}

int main(int argc, char **argv)
{
    if (argc == 6 && strcmp(argv[1], "--save") == 0)
        return saver(argv[2], argv[3], parse_size(argv[4]), parse_size(argv[5]));
    if (argc == 3)
        return writer(argv[1], parse_size(argv[2]));
    fprintf(stderr,
        "usage: <producer> | %s <ringfile> <ring_bytes[K|M|G]>\n"
        "       %s --save <ringfile> <out> <pre[K|M]> <post[K|M]>\n",
        argv[0], argv[0]);
    return 2;
}
