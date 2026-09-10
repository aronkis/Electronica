/* ms_src_fake.h -- in-memory ms_src for x86 unit tests. */
#ifndef MS_SRC_FAKE_H
#define MS_SRC_FAKE_H
#include "ms_src.h"
#include "modem_status.h"

#define FK_MAX_FILES 64

struct fk_file { char path[128]; char *data; size_t len; int64_t mtime; };

struct ms_src_fake {
    uint32_t modem[MS_MAP_LEN / 4], tx[MS_MAP_LEN / 4], rx[MS_MAP_LEN / 4];
    int regs_avail;
    int regs_read_calls;
    struct fk_file files[FK_MAX_FILES];
    int nfiles;
    int64_t now_ms, wall_s;
    char md5[16];
    int md5_fail;
};

void ms_src_fake_init(struct ms_src_fake *f, struct ms_src *s);
void fk_set_file(struct ms_src_fake *f, const char *path, const char *data, int64_t mtime);
void fk_set_file_raw(struct ms_src_fake *f, const char *path, const char *data, size_t len);
void fk_append_file(struct ms_src_fake *f, const char *path, const char *data, int64_t mtime);
void fk_del_file(struct ms_src_fake *f, const char *path);
/* Convenience: a healthy r3 board (regs, daemon, watchdog, radio, procs). */
void fk_populate_healthy(struct ms_src_fake *f);
/* Advance the clock by dt ms and bump the free-running counters by fps frames. */
void fk_tick(struct ms_src_fake *f, int64_t dt_ms, double fps);
#endif
