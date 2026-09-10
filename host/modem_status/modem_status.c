/* modem_status.c -- on-board modem data-link status TUI (see modem_status.h
 * for the safety contract).
 *
 *   modem_status                 full-screen, 1 s refresh, keys q r p 1 2 3
 *   modem_status --once          two samples 1 s apart, plain text, exit
 *   modem_status --json          same, one JSON object
 *   --fps N        expected frame rate (default 1245, the r3 profile)
 *   --bist         score cap_out/biterr (ROM source, tx_data_source=0)
 *   --no-regs      never open /dev/mem (file-sourced fields only)
 *   --pause-file P flag file that pauses register reads (default
 *                  /dev/shm/modem_status.pause)
 *   --name S       board label in the header (default hostname)
 *   --plain        VT100 fallback UI instead of ncurses
 *
 * Build on the board: make modem_status   (gcc, libc only; per-board build,
 * 148 is arm64 and 146 is armhf). Host tests: make test_modem_status.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include "modem_status.h"
#include "ms_src_hw.h"
#include "ms_collect.h"
#include "ms_delta.h"
#include "ms_health.h"
#include "ms_render.h"
#include "ms_term.h"
#include "ms_curses.h"

static void usage(void)
{
    fprintf(stderr, "usage: modem_status [--once|--json] [--fps N] [--bist] [--no-regs] "
                    "[--pause-file P] [--name S] [--plain]\n");
    exit(2);
}

static void wall_hms(int64_t wall_s, char out[9])
{
    time_t t = (time_t)wall_s;
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(out, 9, "%H:%M:%S", &tm);
}

static void draw(const struct ms_view *v, int page, int plain, char *out, size_t cap)
{
    if (plain) {
        int cols, rows;
        size_t n;
        ms_term_size(&cols, &rows);
        n = ms_render_tui(v, out, cap, cols, rows, 1, page);
        (void)!write(STDOUT_FILENO, out, n);
    } else ms_curses_draw(v, page);
}

static void sleep_until(int64_t target_ms)
{
    struct timespec ts;
    int64_t now;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    now = (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    if (target_ms > now) {
        ts.tv_sec = (target_ms - now) / 1000;
        ts.tv_nsec = ((target_ms - now) % 1000) * 1000000;
        nanosleep(&ts, NULL);
    }
}

int main(int argc, char **argv)
{
    struct ms_cfg cfg;
    struct ms_src src;
    struct ms_collect_state st;
    static struct ms_sample samp[2];
    static struct ms_delta dl;
    static struct ms_health h;
    struct ms_view v;
    static char out[65536];
    int once = 0, json = 0, page = 1, cur = 0, have_prev = 0, plain = 0;
    int64_t tick = 0, t0, reset_ms = 0;

    memset(&cfg, 0, sizeof cfg);
    cfg.expected_fps = MS_DEFAULT_FPS;
    cfg.pause_path = MS_PAUSE_PATH_DEFAULT;
    cfg.r4d_swapped = -1;
    if (gethostname(cfg.name, sizeof cfg.name) != 0) strcpy(cfg.name, "?");
    cfg.name[sizeof cfg.name - 1] = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--json")) json = once = 1;
        else if (!strcmp(argv[i], "--bist")) cfg.bist = 1;
        else if (!strcmp(argv[i], "--no-regs")) cfg.no_regs = 1;
        else if (!strcmp(argv[i], "--plain")) plain = 1;
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) cfg.expected_fps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--pause-file") && i + 1 < argc) cfg.pause_path = argv[++i];
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) snprintf(cfg.name, sizeof cfg.name, "%s", argv[++i]);
        else usage();
    }
    if (cfg.expected_fps <= 0) usage();

    if (ms_src_hw_open(&src, !cfg.no_regs) != 0) {
        fprintf(stderr, "modem_status: cannot map the modem BAR (root? /dev/mem?); try --no-regs\n");
        return 1;
    }
    ms_collect_image(&src, &cfg);
    memset(&st, 0, sizeof st);

    if (!once && (plain ? ms_term_enter() : ms_curses_enter()) != 0) {
        fprintf(stderr, "modem_status: stdin/stdout is not a tty; use --once or --json (ssh -t for the TUI)\n");
        return 1;
    }

    t0 = src.now_ms(src.ctx);
    v.cfg = &cfg;
    for (;;) {
        int key;
        ms_collect(&src, &cfg, &st, &samp[cur]);
        ms_delta_compute(have_prev ? &samp[cur ^ 1] : NULL, &samp[cur], &dl);
        ms_health_eval(&cfg, &samp[cur], &dl, &h);
        v.cur = &samp[cur]; v.dl = &dl; v.h = &h; v.tick = tick;
        v.since_reset_s = (samp[cur].t_ms - (reset_ms ? reset_ms : t0)) / 1000;
        wall_hms(samp[cur].wall_s, v.wall);

        if (once) {
            if (have_prev) {
                size_t n = json ? ms_render_json(&v, out, sizeof out) : ms_render_once(&v, out, sizeof out);
                fwrite(out, 1, n, stdout);
                break;
            }
        } else {
            draw(&v, page, plain, out, sizeof out);
        }

        have_prev = 1; cur ^= 1; tick++;
        if (once) { sleep_until(t0 + tick * MS_TICK_MS); continue; }

        /* wait for the next tick, servicing keys (never re-reading registers) */
        for (;;) {
            int64_t now = src.now_ms(src.ctx), target = t0 + tick * MS_TICK_MS;
            if (now >= target) break;
            key = plain ? ms_term_key((int)(target - now)) : ms_curses_key((int)(target - now));
            if (key == 'q' || ms_term_quit) {
                if (plain) ms_term_leave(); else ms_curses_leave();
                ms_src_hw_close(&src); return 0;
            }
            if (key == 'r') { have_prev = 0; reset_ms = now; }
            else if (key == 'p') st.user_pause = !st.user_pause;
            else if (key >= '1' && key <= '3') { page = key - '0'; draw(&v, page, plain, out, sizeof out); }
            else if (key == -2) draw(&v, page, plain, out, sizeof out);
        }
    }
    ms_src_hw_close(&src);
    return 0;
}
