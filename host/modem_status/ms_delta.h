#ifndef MS_DELTA_H
#define MS_DELTA_H
#include "modem_status.h"
/* prev may be NULL (first tick): dl->valid = 0. */
void ms_delta_compute(const struct ms_sample *prev, const struct ms_sample *cur,
                      struct ms_delta *dl);
#endif
