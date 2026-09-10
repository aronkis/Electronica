/* ms_term.c -- termios raw mode, size, key polling. libc only, no curses. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <poll.h>
#include <termios.h>
#include <sys/ioctl.h>
#include "ms_term.h"

static struct termios saved;
static int entered;
static volatile int winch;
volatile int ms_term_quit;

static void on_sig(int sig)
{
    if (sig == SIGWINCH) winch = 1;
    else ms_term_quit = 1;
}

void ms_term_leave(void)
{
    if (!entered) return;
    entered = 0;
    (void)!write(STDOUT_FILENO, "\x1b[0m\x1b[?25h\x1b[?1049l", 19);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
}

int ms_term_enter(void)
{
    struct termios t;
    struct sigaction sa;
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return -1;
    if (tcgetattr(STDIN_FILENO, &saved) != 0) return -1;
    t = saved;
    t.c_lflag &= ~(ICANON | ECHO | ISIG);
    t.c_iflag &= ~(IXON | ICRNL);
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &t) != 0) return -1;
    entered = 1;
    atexit(ms_term_leave);
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sig;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGWINCH, &sa, NULL);
    (void)!write(STDOUT_FILENO, "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J", 20);
    return 0;
}

void ms_term_size(int *cols, int *rows)
{
    struct winsize ws;
    *cols = 80; *rows = 24;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
        *cols = ws.ws_col; *rows = ws.ws_row;
    }
}

int ms_term_key(int timeout_ms)
{
    struct pollfd pfd = { STDIN_FILENO, POLLIN, 0 };
    unsigned char ch;
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc < 0) {
        if (errno == EINTR) { if (winch) { winch = 0; return -2; } return ms_term_quit ? 'q' : -2; }
        return -1;
    }
    if (rc == 0) return -1;
    if (read(STDIN_FILENO, &ch, 1) != 1) return -1;
    if (ch == 3) return 'q';   /* ^C with ISIG off */
    return ch;
}
