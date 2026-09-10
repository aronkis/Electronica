/* ms_src.h -- the data-source vtable. Everything above this line is
 * hardware-free and unit-testable with ms_src_fake; ms_src_hw.c is the only
 * file that opens /dev/mem, /proc, /sys or /dev/shm. */
#ifndef MS_SRC_H
#define MS_SRC_H

#include <stdint.h>
#include <stddef.h>

struct ms_src {
    void *ctx;
    /* One batched pass over n words of a bank. 0 ok, -1 bank unavailable. */
    int (*regs_read)(void *ctx, int bank, const uint16_t *offs, int n, uint32_t *out);
    /* Read a file into buf (NUL-terminated). tail=1 reads the LAST cap-1
     * bytes. Returns bytes read, -1 if absent/unreadable. */
    int (*file_read)(void *ctx, const char *path, char *buf, size_t cap, int tail);
    /* 0 and *mtime_s set, -1 if absent. */
    int (*file_mtime)(void *ctx, const char *path, int64_t *mtime_s);
    /* 1 if the path exists (any type). */
    int (*file_exists)(void *ctx, const char *path);
    /* Enumerate directory entry names; cb returns nonzero to stop. -1 if absent. */
    int (*dir_list)(void *ctx, const char *path, int (*cb)(const char *name, void *arg), void *arg);
    /* First 12 hex chars of md5(/boot/BOOT.BIN) into out[13]; -1 on failure. */
    int (*image_md5)(void *ctx, char *out, size_t cap);
    int64_t (*now_ms)(void *ctx);
    int64_t (*now_wall_s)(void *ctx);
};

#endif
