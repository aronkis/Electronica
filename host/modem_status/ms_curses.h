/* ms_curses.h -- ncurses front end (panels with box-drawing dividers). */
#ifndef MS_CURSES_H
#define MS_CURSES_H
#include "modem_status.h"
int  ms_curses_enter(void);                 /* 0 ok, -1 no tty */
void ms_curses_leave(void);
void ms_curses_draw(const struct ms_view *v, int page);
int  ms_curses_key(int timeout_ms);         /* key, -1 timeout, -2 resize */
#endif
