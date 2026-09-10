/* ms_collect.h -- collectors: one ms_sample per tick from an ms_src. */
#ifndef MS_COLLECT_H
#define MS_COLLECT_H

#include "modem_status.h"
#include "ms_src.h"

struct ms_collect_state {
    char radio_dev[24];        /* cached "iio:deviceN", "" = unresolved */
    int  radio_tried;
    int  clear_ticks;          /* consecutive ticks with no pause reason */
    int  paused;
    int64_t paused_since_ms;
    int  user_pause;           /* 'p' key */
};

/* Fill cfg->image_md5 / r4d_swapped once at startup. */
void ms_collect_image(const struct ms_src *s, struct ms_cfg *cfg);

/* One tick. Never reads registers while paused. */
void ms_collect(const struct ms_src *s, const struct ms_cfg *cfg,
                struct ms_collect_state *st, struct ms_sample *out);

/* Parsers exposed for tests. */
int ms_parse_stats_line(const char *line, uint64_t st[MS_ST_N]);
int ms_find_last_stats(const char *log, char *line, size_t cap, int *arq_on);
void ms_parse_wd_tail(const char *tail, struct ms_watchdog *wd);
double ms_parse_num(const char *s, double dflt);

#endif
