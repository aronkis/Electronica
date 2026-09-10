/* ms_src_hw.c -- the ONLY file that touches hardware and the filesystem.
 * /dev/mem is opened O_RDONLY and every mapping is PROT_READ (modem_status.h
 * contract item 1). It never maps the byte-DMA GPIO at QPSK_GPIO_BASE and
 * never opens /sys/kernel/debug. Build with -D_FILE_OFFSET_BITS=64: on the
 * armhf board (146) 0x9D000000 exceeds a 32-bit off_t and mmap fails EINVAL. */
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "modem_status.h"
#include "ms_src.h"
#include "ms_src_hw.h"

struct hw {
    int memfd;
    volatile uint8_t *bank[3];
};

static const uint64_t bank_base[3] = { QPSK_MODEM_BASE, QPSK_TX_DMA_BASE, QPSK_RX_DMA_BASE };

static int hw_regs_read(void *ctx, int bank, const uint16_t *offs, int n, uint32_t *out)
{
    struct hw *h = ctx;
    if (bank < 0 || bank > 2 || !h->bank[bank]) return -1;
    for (int i = 0; i < n; i++)
        out[i] = *(volatile uint32_t *)(h->bank[bank] + offs[i]);
    return 0;
}

static int hw_file_read(void *ctx, const char *path, char *buf, size_t cap, int tail)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t n;
    (void)ctx;
    if (fd < 0) return -1;
    if (tail) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > (off_t)(cap - 1))
            lseek(fd, st.st_size - (off_t)(cap - 1), SEEK_SET);
    }
    n = read(fd, buf, cap - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    return (int)n;
}

static int hw_file_mtime(void *ctx, const char *path, int64_t *mtime_s)
{
    struct stat st;
    (void)ctx;
    if (stat(path, &st) != 0) return -1;
    *mtime_s = (int64_t)st.st_mtime;
    return 0;
}

static int hw_file_exists(void *ctx, const char *path)
{
    (void)ctx;
    return access(path, F_OK) == 0;
}

static int hw_dir_list(void *ctx, const char *path, int (*cb)(const char *, void *), void *arg)
{
    DIR *d = opendir(path);
    struct dirent *e;
    (void)ctx;
    if (!d) return -1;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        if (cb(e->d_name, arg)) break;
    }
    closedir(d);
    return 0;
}

static int hw_image_md5(void *ctx, char *out, size_t cap)
{
    FILE *p = popen("md5sum " MS_BOOT_BIN " 2>/dev/null", "r");
    char line[128];
    (void)ctx;
    if (!p) return -1;
    if (!fgets(line, sizeof line, p) || strlen(line) < 12) { pclose(p); return -1; }
    pclose(p);
    if (cap < 13) return -1;
    memcpy(out, line, 12); out[12] = 0;
    return 0;
}

static int64_t hw_now_ms(void *ctx)
{
    struct timespec ts;
    (void)ctx;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int64_t hw_now_wall_s(void *ctx)
{
    (void)ctx;
    return (int64_t)time(NULL);
}

int ms_src_hw_open(struct ms_src *s, int want_regs)
{
    struct hw *h = calloc(1, sizeof *h);
    if (!h) return -1;
    h->memfd = -1;
    if (want_regs) {
        h->memfd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
        if (h->memfd < 0) { perror("/dev/mem"); free(h); return -1; }
        for (int b = 0; b < 3; b++) {
            void *p = mmap(NULL, MS_MAP_LEN, PROT_READ, MAP_SHARED, h->memfd, (off_t)bank_base[b]);
            if (p == MAP_FAILED) {
                fprintf(stderr, "mmap 0x%llx: %s\n", (unsigned long long)bank_base[b], strerror(errno));
                h->bank[b] = NULL;
            } else h->bank[b] = p;
        }
        if (!h->bank[0]) { close(h->memfd); free(h); return -1; }
    }
    s->ctx = h;
    s->regs_read = hw_regs_read;
    s->file_read = hw_file_read;
    s->file_mtime = hw_file_mtime;
    s->file_exists = hw_file_exists;
    s->dir_list = hw_dir_list;
    s->image_md5 = hw_image_md5;
    s->now_ms = hw_now_ms;
    s->now_wall_s = hw_now_wall_s;
    return 0;
}

void ms_src_hw_close(struct ms_src *s)
{
    struct hw *h = s->ctx;
    if (!h) return;
    for (int b = 0; b < 3; b++)
        if (h->bank[b]) munmap((void *)h->bank[b], MS_MAP_LEN);
    if (h->memfd >= 0) close(h->memfd);
    free(h);
    s->ctx = NULL;
}
