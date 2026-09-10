/* ms_render.h -- render an ms_view into a caller buffer. No terminal calls.
 * With colour=0 the output is plain text; with colour=1 the same text carries
 * SGR sequences and per-line clear-to-EOL, so stripping escapes from the
 * coloured output yields the plain output byte for byte. */
#ifndef MS_RENDER_H
#define MS_RENDER_H
#include "modem_status.h"

/* page 1 overview, 2 base registers, 3 instrument words + DMAC + daemon */
size_t ms_render_tui(const struct ms_view *v, char *buf, size_t cap,
                     int cols, int rows, int colour, int page);
size_t ms_render_once(const struct ms_view *v, char *buf, size_t cap);
size_t ms_render_json(const struct ms_view *v, char *buf, size_t cap);
/* helper for tests: remove ESC[...m / ESC[K / ESC[H / ESC[J sequences in place */
void ms_strip_sgr(char *s);
/* shared formatting helpers (used by the ncurses front end too) */
void ms_reg_rate(const struct ms_view *v, int idx, char *o, size_t cap);
enum ms_level ms_age_level(int64_t age, int cadence);
void ms_fmt_age(char *o, size_t cap, int64_t age);
enum ms_level ms_byte_extra(const struct ms_view *v, int row, char *o, size_t cap);
#endif
