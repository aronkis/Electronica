#ifndef MS_SRC_HW_H
#define MS_SRC_HW_H
#include "ms_src.h"
/* want_regs=0 (--no-regs) skips /dev/mem entirely. */
int  ms_src_hw_open(struct ms_src *s, int want_regs);
void ms_src_hw_close(struct ms_src *s);
#endif
