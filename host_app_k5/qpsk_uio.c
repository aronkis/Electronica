/* qpsk_uio.c -- UIO /sys scan + /dev/uioN fd ops for qpsk_tun (Task B2).
 *
 * This module deliberately owns NO DMA-register knowledge: the IRQ_PENDING
 * W1C ack is done by qpsk_tun.c through its existing dmac register accessor,
 * and only the UIO-fd re-enable (qpsk_uio_irq_enable) lives here. That keeps
 * the layering clean -- the /sys scan and fd lifetime are the only concern.
 */
#include "qpsk_uio.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>

/* Return the numeric index N of the /sys/class/uio/uioN whose "name" file
 * EXACTLY equals `name`, or -1 if none matches. Does not open anything. */
static int uio_lookup(const char *name)
{
    DIR *d = opendir("/sys/class/uio");
    if (!d)
        return -1;
    struct dirent *de;
    int idx = -1;
    while ((de = readdir(d)) != NULL) {
        if (strncmp(de->d_name, "uio", 3) != 0)
            continue;
        char path[sizeof "/sys/class/uio//name" + sizeof de->d_name];
        snprintf(path, sizeof path, "/sys/class/uio/%s/name", de->d_name);
        FILE *f = fopen(path, "r");
        if (!f)
            continue;
        char line[128];
        char *got = fgets(line, sizeof line, f);
        fclose(f);
        if (!got)
            continue;
        line[strcspn(line, "\r\n")] = '\0';   /* the name file is newline-terminated */
        /* uio_pdrv_genirq renders the UIO "name" from the DT node either as the
         * bare node-name ("qpsk_tx_dma") OR, on the kernel actually deployed
         * here (6.12.77), WITH the @unit-address ("qpsk_tx_dma@9d100000") -- a
         * node with a `reg` MUST carry a unit-address, so the '@' form is the
         * real one. Accept BOTH: exact match, or `name` immediately followed by
         * '@'. (The tx/rx/byte_gpio names share no prefix, so this cannot
         * cross-match.) */
        size_t nl = strlen(name);
        if (strcmp(line, name) == 0 ||
            (strncmp(line, name, nl) == 0 && line[nl] == '@')) {
            idx = atoi(de->d_name + 3);        /* "uio7" -> 7 */
            break;
        }
    }
    closedir(d);
    return idx;
}

int qpsk_uio_open(const char *name)
{
    int idx = uio_lookup(name);
    if (idx < 0)
        return -1;
    char dev[64];
    snprintf(dev, sizeof dev, "/dev/uio%d", idx);
    return open(dev, O_RDWR | O_CLOEXEC);
}

int qpsk_uio_irq_enable(int fd)
{
    uint32_t one = 1;
    ssize_t w = write(fd, &one, sizeof one);
    return (w == (ssize_t)sizeof one) ? 0 : -1;
}

int qpsk_gpio_present(void)
{
    /* positive evidence 1: a UIO node named qpsk_byte_gpio */
    if (uio_lookup("qpsk_byte_gpio") >= 0)
        return 1;

    /* positive evidence 2: a claimed region based at 9d300000 in /proc/iomem.
     * iomem lines read like "  9d300000-9d30ffff : qpsk_byte_gpio"; the range
     * start is what identifies the peripheral. We accept an optional leading
     * zero-padding (e.g. "009d300000-") so a wider address column still matches. */
    FILE *f = fopen("/proc/iomem", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            const char *p = line;
            while (*p == ' ' || *p == '\t' || *p == '0')
                p++;                            /* skip indent + zero pad */
            if (strncmp(p, "9d300000-", 9) == 0) {
                fclose(f);
                return 1;
            }
        }
        fclose(f);
    }
    return 0;
}

int qpsk_iomem_reserved_covers(const char *path, uint64_t base, uint64_t top)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    char line[256];
    int covered = 0;
    while (fgets(line, sizeof line, f)) {
        /* iomem lines: "  <start>-<end> : <label>" (hex, no 0x prefix). */
        const char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;                                  /* skip indent only */
        char *endp = NULL;
        uint64_t start = strtoull(p, &endp, 16);
        if (endp == p || *endp != '-')            /* need "<hex>-" */
            continue;
        const char *q = endp + 1;
        uint64_t end = strtoull(q, &endp, 16);
        if (endp == q)                            /* need a second hex value */
            continue;
        /* label follows " : "; require it to be exactly "reserved" (the
         * empirically-confirmed descriptor for a no-map reserved-memory carve
         * -- a driver-claimed region would name the peripheral instead). */
        const char *lbl = strstr(endp, ": ");
        if (!lbl)
            continue;
        lbl += 2;
        while (*lbl == ' ')
            lbl++;
        size_t n = strcspn(lbl, " \t\r\n");
        if (n != 8 || strncmp(lbl, "reserved", 8) != 0)
            continue;
        if (start <= base && end >= top) {
            covered = 1;
            break;
        }
    }
    fclose(f);
    return covered;
}
