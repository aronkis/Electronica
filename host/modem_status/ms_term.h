#ifndef MS_TERM_H
#define MS_TERM_H
int  ms_term_enter(void);                 /* raw mode + alt screen; 0 ok */
void ms_term_leave(void);                 /* idempotent; also atexit/signal */
void ms_term_size(int *cols, int *rows);
/* Wait up to timeout_ms for a key; returns the key or -1 on timeout, -2 on
 * SIGWINCH/EINTR (caller re-queries size). */
int  ms_term_key(int timeout_ms);
extern volatile int ms_term_quit;         /* set by SIGINT/SIGTERM */
#endif
