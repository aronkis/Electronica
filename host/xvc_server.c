/*
 * xvc_server.c -- Xilinx Virtual Cable (XVC v1.0) server for a Xilinx
 * debug_bridge IP ("AXI to BSCAN" / XVC mode, PG245) reached purely via
 * /dev/mem mmap.  No kernel driver, no deps beyond libc.
 *
 * Target: ZU3EG (ZynqMP) minimal ADI Linux; built on-board like the other
 * host tools:   gcc -O2 -Wall -Wextra -o xvc_server xvc_server.c
 *
 * Usage:   ./xvc_server <bridge_phys_addr> [port]
 *   bridge_phys_addr : PS address of the debug_bridge AXI window (hex ok)
 *   port             : TCP listen port, default 2542
 *
 * Vivado side (via hw_server):  open_hw_target -xvc_url <board_ip>:2542
 *
 * PG245 AXI-to-BSCAN XVC register map (32-bit registers):
 *   0x00  LENGTH  number of bits to shift this word (1..32)
 *   0x04  TMS     TMS vector word
 *   0x08  TDI     TDI vector word
 *   0x0C  TDO     TDO vector word (read after shift completes)
 *   0x10  CTRL    write 1 = start shift; self-clears (bit0) when done
 *
 * XVC v1.0 protocol (TCP, all lengths little-endian):
 *   "getinfo:"                          -> "xvcServer_v1.0:<max_vec_bytes>\n"
 *   "settck:" u32 period_ns             -> u32 period_ns (echoed)
 *   "shift:"  u32 nbits, TMS[], TDI[]   -> TDO[]   (vectors are ceil(n/8) B)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/mman.h>
#include <sys/socket.h>

#define XVC_VECTOR_LEN   2048u          /* max shift vector bytes we accept */
#define MAP_LEN          4096u

#define REG_LENGTH       (0x00u / 4)
#define REG_TMS          (0x04u / 4)
#define REG_TDI          (0x08u / 4)
#define REG_TDO          (0x0Cu / 4)
#define REG_CTRL         (0x10u / 4)

#define SHIFT_TIMEOUT_MS 100            /* per 32-bit word */

static volatile uint32_t *g_regs = NULL;
static int g_tap = 0;      /* JTAG TAP state, reset per client connection */
static int g_ircap = -1;   /* IR-capture spoof bit index */
static void              *g_map  = MAP_FAILED;
static int                g_lfd  = -1;
static int                g_cfd  = -1;
static volatile sig_atomic_t g_stop = 0;

static void on_sigint(int sig)
{
    (void)sig;
    g_stop = 1;
    /* close fds so blocking accept()/read() return */
    if (g_lfd >= 0) close(g_lfd);
    if (g_cfd >= 0) close(g_cfd);
}

/* ---- robust socket I/O ------------------------------------------------ */

static int read_full(int fd, void *buf, size_t len)
{
    uint8_t *p = buf;
    while (len) {
        ssize_t r = read(fd, p, len);
        if (r < 0) {
            if (errno == EINTR && !g_stop) continue;
            return -1;
        }
        if (r == 0) return -1;          /* peer closed */
        p += r; len -= (size_t)r;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR && !g_stop) continue;
            return -1;
        }
        p += w; len -= (size_t)w;
    }
    return 0;
}

/* ---- debug_bridge access ---------------------------------------------- */

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* Shift up to 32 bits through the bridge; returns 0 on success. */
static int bridge_shift_word(uint32_t nbits, uint32_t tms, uint32_t tdi,
                             uint32_t *tdo)
{
    g_regs[REG_LENGTH] = nbits;
    g_regs[REG_TMS]    = tms;
    g_regs[REG_TDI]    = tdi;
    g_regs[REG_CTRL]   = 1u;            /* start; bit0 self-clears when done */

    uint64_t t0 = now_ms();
    while (g_regs[REG_CTRL] & 1u) {
        if (now_ms() - t0 > SHIFT_TIMEOUT_MS) {
            fprintf(stderr, "xvc_server: shift timeout (CTRL stuck busy) -- "
                            "is the debug_bridge image loaded?\n");
            return -1;
        }
    }
    *tdo = g_regs[REG_TDO];
    if (getenv("XVC_VERBOSE"))
        fprintf(stderr, "shift n=%2u tms=%08x tdi=%08x tdo=%08x\n",
                nbits, tms, tdi, *tdo);
    return 0;
}

/* ---- one client session ----------------------------------------------- */

static int handle_shift(int fd)
{
    static uint8_t tms[XVC_VECTOR_LEN], tdi[XVC_VECTOR_LEN],
                   tdo[XVC_VECTOR_LEN];
    uint32_t nbits_le;
    if (read_full(fd, &nbits_le, 4) < 0) return -1;
    uint32_t nbits  = nbits_le;         /* host is LE on both x86 & aarch64 */
    uint32_t nbytes = (nbits + 7u) / 8u;
    if (nbits == 0 || nbytes > XVC_VECTOR_LEN) {
        fprintf(stderr, "xvc_server: bad shift length %u bits\n", nbits);
        return -1;
    }
    if (read_full(fd, tms, nbytes) < 0) return -1;
    if (read_full(fd, tdi, nbytes) < 0) return -1;
    memset(tdo, 0, nbytes);

    for (uint32_t bit = 0; bit < nbits; bit += 32) {
        uint32_t chunk = nbits - bit;
        if (chunk > 32) chunk = 32;
        uint32_t byte = bit / 8;
        uint32_t tms_w = 0, tdi_w = 0, tdo_w = 0;
        for (uint32_t b = 0; b < (chunk + 7u) / 8u; b++) {
            tms_w |= (uint32_t)tms[byte + b] << (8 * b);
            tdi_w |= (uint32_t)tdi[byte + b] << (8 * b);
        }
        if (bridge_shift_word(chunk, tms_w, tdi_w, &tdo_w) < 0) return -1;
        for (uint32_t b = 0; b < (chunk + 7u) / 8u; b++)
            tdo[byte + b] = (uint8_t)(tdo_w >> (8 * b));
    }
    /* Stale-bit absorber (default on; XVC_NO_FIXUP=1 disables): the axi_jtag
     * engine emits one stale TDO bit at each Capture->Shift TAP transition
     * (measured: IDCODE arrives one position late in mixed walk+shift words,
     * dead-on in pure shift words that follow an entry). Track the TAP state
     * from the TMS stream and delete the raw TDO bit at each entry clock,
     * compacting the remainder left; trailing positions repeat the last raw
     * bit (they land in Exit1/Update where TDO is don't-care). */
    /* IR-capture spoof (default on; XVC_NO_FIXUP=1 disables): the bs_switch
     * soft TAP captures its CURRENT IR REGISTER CONTENTS on Capture-IR
     * (measured 2026-08-19: post-TLR 0x09; after loading 0x15 -> 0x15; after
     * BYPASS -> 0x3F), violating the JTAG xxxx01 rule -- hw_server's IR scan
     * then rejects the chain ("No devices detected").  Track the TAP state
     * from TMS and overwrite the first 6 TDO bits of every Shift-IR entry
     * with the TAP's own legal post-TLR capture value 0b001001.  IR capture
     * is informational to the client; DR data is never touched. */
    if (!getenv("XVC_NO_FIXUP")) {
        /* 16-state JTAG FSM: 0 TLR, 1 RTI, 2 SelDR, 3 CapDR, 4 ShiftDR,
         * 5 Exit1DR, 6 PauseDR, 7 Exit2DR, 8 UpdDR, 9 SelIR, 10 CapIR,
         * 11 ShiftIR, 12 Exit1IR, 13 PauseIR, 14 Exit2IR, 15 UpdIR */
        static const uint8_t nxt[16][2] = {
            {1,0},{1,2},{3,9},{4,5},{4,5},{6,8},{6,7},{4,8},
            {1,2},{10,0},{11,12},{11,12},{13,15},{13,14},{11,15},{1,2} };
        static const uint8_t CAP01 = 0x09;   /* 0b001001, LSB first */
        for (uint32_t in = 0; in < nbits; in++) {
            uint8_t tmsb = (tms[in / 8] >> (in % 8)) & 1u;
            int prev = g_tap;
            g_tap = nxt[g_tap][tmsb];
            if (prev == 10 && g_tap == 11) g_ircap = 0;    /* CapIR -> ShiftIR */
            else if (prev == 11 && g_ircap >= 0 && g_ircap < 6) {
                /* a Shift-IR clock (incl. the exiting one) shifts a bit */
                /* this clock shifts out capture bit `ircap` */
                uint8_t v = (CAP01 >> g_ircap) & 1u;
                if (v) tdo[in / 8] |=  (uint8_t)(1u << (in % 8));
                else   tdo[in / 8] &= (uint8_t)~(1u << (in % 8));
                g_ircap++;
                if (g_tap != 11) g_ircap = -1;   /* left Shift-IR */
            } else if (g_tap != 11 && prev != 10) g_ircap = -1;
        }
    }
    return write_full(fd, tdo, nbytes);
}

static void serve_client(int fd)
{
    g_tap = 0; g_ircap = -1;   /* fresh TAP tracking per connection */
    for (;;) {
        /* commands are "<name>:"; read up to ':' (longest name 7 chars) */
        char cmd[16];
        size_t n = 0;
        for (;;) {
            if (read_full(fd, &cmd[n], 1) < 0) return;
            if (cmd[n] == ':') { cmd[++n] = '\0'; break; }
            if (++n >= sizeof(cmd) - 1) {
                fprintf(stderr, "xvc_server: unknown command (overlong)\n");
                return;
            }
        }

        if (strcmp(cmd, "getinfo:") == 0) {
            char reply[64];
            int len = snprintf(reply, sizeof(reply),
                               "xvcServer_v1.0:%u\n", XVC_VECTOR_LEN);
            if (write_full(fd, reply, (size_t)len) < 0) return;
        } else if (strcmp(cmd, "settck:") == 0) {
            uint32_t period;                     /* ns, LE */
            if (read_full(fd, &period, 4) < 0) return;
            /* no clock control in the AXI bridge; accept and echo */
            if (write_full(fd, &period, 4) < 0) return;
        } else if (strcmp(cmd, "shift:") == 0) {
            if (handle_shift(fd) < 0) return;
        } else {
            fprintf(stderr, "xvc_server: unknown command \"%s\"\n", cmd);
            return;
        }
    }
}

/* ---- main -------------------------------------------------------------- */

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr,
            "usage: %s <bridge_phys_addr> [port]\n"
            "  e.g. %s 0xA0010000 2542\n", argv[0], argv[0]);
        return 1;
    }
    errno = 0;
    char *end = NULL;
    uint64_t phys = strtoull(argv[1], &end, 0);
    if (errno || end == argv[1] || *end) {
        fprintf(stderr, "xvc_server: bad address \"%s\"\n", argv[1]);
        return 1;
    }
    int port = (argc == 3) ? atoi(argv[2]) : 2542;
    if (port <= 0 || port > 65535) {
        fprintf(stderr, "xvc_server: bad port \"%s\"\n", argv[2]);
        return 1;
    }

    long pagesz = sysconf(_SC_PAGESIZE);
    if (pagesz <= 0) pagesz = 4096;
    uint64_t base = phys & ~((uint64_t)pagesz - 1);
    uint64_t off  = phys - base;
    if (off + 0x14 > MAP_LEN) {
        fprintf(stderr, "xvc_server: register window crosses map end\n");
        return 1;
    }

    int memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (memfd < 0) {
        perror("xvc_server: open /dev/mem (need root)");
        return 1;
    }
    g_map = mmap(NULL, MAP_LEN, PROT_READ | PROT_WRITE, MAP_SHARED,
                 memfd, (off_t)base);
    close(memfd);
    if (g_map == MAP_FAILED) {
        perror("xvc_server: mmap");
        return 1;
    }
    g_regs = (volatile uint32_t *)((uint8_t *)g_map + off);

    struct sigaction sa = { 0 };
    sa.sa_handler = on_sigint;          /* no SA_RESTART: unblock syscalls */
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    g_lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_lfd < 0) { perror("xvc_server: socket"); goto fail; }
    int one = 1;
    setsockopt(g_lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { 0 };
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons((uint16_t)port);
    if (bind(g_lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("xvc_server: bind"); goto fail;
    }
    if (listen(g_lfd, 4) < 0) { perror("xvc_server: listen"); goto fail; }

    fprintf(stderr, "xvc_server: bridge @ 0x%llx, listening on port %d\n",
            (unsigned long long)phys, port);

    /* Single client at a time, serialized (only one real XVC consumer exists,
     * and the bridge is a single shared resource -- concurrency would corrupt
     * scans).  A client killed abruptly leaves a half-open socket; without a
     * read timeout the accept loop would block on it forever and never accept
     * the next hw_server.  SO_RCVTIMEO (5 s) drops a silent peer so the loop
     * recovers.  A live XVC scan/ILA-poll sends data far more often than that. */
    while (!g_stop) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int cfd = accept(g_lfd, (struct sockaddr *)&peer, &plen);
        if (cfd < 0) {
            if (g_stop) break;
            if (errno == EINTR) continue;
            perror("xvc_server: accept");
            break;
        }
        g_cfd = cfd;
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        struct timeval rto = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &rto, sizeof(rto));
        fprintf(stderr, "xvc_server: client %s connected\n",
                inet_ntoa(peer.sin_addr));
        serve_client(cfd);
        fprintf(stderr, "xvc_server: client disconnected\n");
        close(cfd);
        g_cfd = -1;
    }

    fprintf(stderr, "xvc_server: shutting down\n");
    if (g_lfd >= 0) close(g_lfd);
    munmap(g_map, MAP_LEN);
    return 0;

fail:
    if (g_lfd >= 0) close(g_lfd);
    munmap(g_map, MAP_LEN);
    return 1;
}
