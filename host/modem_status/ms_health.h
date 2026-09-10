#ifndef MS_HEALTH_H
#define MS_HEALTH_H
#include "modem_status.h"
void ms_health_eval(const struct ms_cfg *cfg, const struct ms_sample *cur,
                    const struct ms_delta *dl, struct ms_health *h);
const char *ms_level_str(enum ms_level l);
#endif
