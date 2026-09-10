/* qpsk_perf.c -- control-channel-free UDP throughput / latency instrument for
 * the two-board RF link. iperf3's TCP control connection is fragile over a
 * lossy no-ARQ radio link; this tool sends only UDP data, logs results
 * locally on each board, and is harvested over the wired LAN afterwards.
 *
 * Modes:
 *   -s                 server: UDP sink; per-second RX stats; echoes back in
 *                      -e mode so the client can measure RTT.
 *   -c IP              client: paced UDP sender to IP.
 *   -e                 echo/RTT: client waits for each datagram's echo and
 *                      prints per-packet RTT CSV (implies the server runs -e).
 *   -b BPS             offered payload bit rate (default 100000).
 *   -l BYTES           UDP payload size (default 88 => 1 frame/datagram: 88+8
 *                      UDP +20 IP = 116 = the link MTU; zero fragmentation).
 *   -t SECS            duration (default 30).
 *   -p PORT            UDP port (default 5001).
 *   --selftest         fork server+client over 127.0.0.1 and self-check.
 *
 * Payload layout (network byte order where multi-byte):
 *   [0..3]  magic 'Q','P','R','F'
 *   [4..7]  seq (u32)
 *   [8..15] client send time, nanoseconds (u64)
 *   [16..]  PN9 fill (x^9+x^5+1, seed = seq&0x1FF) -- high entropy so the
 *           measurement is meaningful even without the host whitener.
 * Payload must be >= 16 bytes.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PERF_MAGIC 0x51505246u   /* 'QPRF' */
#define HDR_MIN 16

static volatile sig_atomic_t g_run = 1;

static void on_stop(int sig) { (void)sig; g_run = 0; }

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* PN9 fill: x^9 + x^5 + 1, byte at a time, seeded per packet */
static void pn9_fill(unsigned char *p, int n, uint32_t seed)
{
    uint16_t s = (uint16_t)(seed & 0x1FF);
    if (s == 0) s = 0x1FF;
    for (int i = 0; i < n; i++) {
        unsigned char b = 0;
        for (int k = 0; k < 8; k++) {
            int bit = s & 1;
            b = (unsigned char)((b << 1) | bit);
            int fb = ((s >> 0) ^ (s >> 4)) & 1;   /* x^9+x^5+1 in a 9-bit reg */
            s = (uint16_t)((s >> 1) | (fb << 8));
            s &= 0x1FF;
        }
        p[i] = b;
    }
}

static void put_hdr(unsigned char *buf, uint32_t seq, uint64_t t)
{
    uint32_t m = htonl(PERF_MAGIC);
    memcpy(buf, &m, 4);
    uint32_t s = htonl(seq);
    memcpy(buf + 4, &s, 4);
    uint32_t hi = htonl((uint32_t)(t >> 32)), lo = htonl((uint32_t)(t & 0xFFFFFFFFu));
    memcpy(buf + 8, &hi, 4);
    memcpy(buf + 12, &lo, 4);
}

static int chk_magic(const unsigned char *buf) {
    uint32_t m; memcpy(&m, buf, 4); return ntohl(m) == PERF_MAGIC;
}
static uint32_t get_seq(const unsigned char *buf) {
    uint32_t s; memcpy(&s, buf + 4, 4); return ntohl(s);
}

/* ---------------- server ---------------- */
static int run_server(int port, int echo, int quiet)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY; a.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); close(fd); return 1; }

    unsigned char buf[2048];
    uint64_t t0 = 0, tbin = 0;
    uint64_t rx_pkts = 0, rx_bytes = 0, bin_pkts = 0, bin_bytes = 0;
    int64_t last_seq = -1; uint64_t lost = 0, dup = 0, reorder = 0;

    while (g_run) {
        struct sockaddr_in src; socklen_t sl = sizeof src;
        ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (struct sockaddr *)&src, &sl);
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n < HDR_MIN || !chk_magic(buf)) continue;
        uint64_t tn = now_ns();
        if (t0 == 0) { t0 = tn; tbin = tn; }
        rx_pkts++; rx_bytes += (uint64_t)n; bin_pkts++; bin_bytes += (uint64_t)n;

        uint32_t seq = get_seq(buf);
        if (last_seq >= 0) {
            if ((int64_t)seq > last_seq + 1) lost += (uint64_t)((int64_t)seq - last_seq - 1);
            else if ((int64_t)seq == last_seq) dup++;
            else if ((int64_t)seq < last_seq) reorder++;
        }
        if ((int64_t)seq > last_seq) last_seq = seq;

        if (echo) sendto(fd, buf, (size_t)n, 0, (struct sockaddr *)&src, sl);

        if (!quiet && tn - tbin >= 1000000000ull) {
            double dt = (double)(tn - tbin) / 1e9;
            printf("PERF_SRV t=%.1f rx_pkts=%llu rx_kbps=%.1f cum_pkts=%llu lost=%llu dup=%llu\n",
                   (double)(tn - t0)/1e9, (unsigned long long)bin_pkts,
                   (double)bin_bytes * 8.0 / 1e3 / dt,
                   (unsigned long long)rx_pkts, (unsigned long long)lost, (unsigned long long)dup);
            fflush(stdout);
            tbin = tn; bin_pkts = 0; bin_bytes = 0;
        }
    }
    printf("PERF_SRV_DONE rx_pkts=%llu rx_bytes=%llu lost=%llu dup=%llu reorder=%llu\n",
           (unsigned long long)rx_pkts, (unsigned long long)rx_bytes,
           (unsigned long long)lost, (unsigned long long)dup, (unsigned long long)reorder);
    fflush(stdout);
    close(fd);
    return 0;
}

/* ---------------- client ---------------- */
static int run_client(const char *ip, int port, uint64_t bps, int len, int secs, int echo)
{
    if (len < HDR_MIN) len = HDR_MIN;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &a.sin_addr) != 1) { fprintf(stderr, "bad ip %s\n", ip); close(fd); return 1; }
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { perror("connect"); close(fd); return 1; }

    if (echo) {   /* RTT probe: bound receive so a lost echo doesn't hang */
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    }

    /* inter-packet interval from offered bit rate and payload size */
    double pps = (double)bps / (8.0 * (double)len);
    if (pps < 1e-6) pps = 1e-6;
    uint64_t interval_ns = (uint64_t)(1e9 / pps);

    unsigned char *buf = malloc((size_t)len);
    if (!buf) { close(fd); return 1; }

    uint64_t t0 = now_ns(), next = t0, deadline = t0 + (uint64_t)secs * 1000000000ull;
    uint64_t tx_pkts = 0, tx_bytes = 0, echo_ok = 0, echo_lost = 0;
    double rtt_sum = 0, rtt_min = 1e18, rtt_max = 0;

    for (uint32_t seq = 0; g_run && now_ns() < deadline; seq++) {
        uint64_t ts = now_ns();
        put_hdr(buf, seq, ts);
        pn9_fill(buf + HDR_MIN, len - HDR_MIN, seq);
        ssize_t w = send(fd, buf, (size_t)len, 0);
        if (w > 0) { tx_pkts++; tx_bytes += (uint64_t)w; }

        if (echo) {
            unsigned char rb[2048];
            ssize_t r = recv(fd, rb, sizeof rb, 0);
            if (r >= HDR_MIN && chk_magic(rb) && get_seq(rb) == seq) {
                double rtt = (double)(now_ns() - ts) / 1e3;   /* microseconds */
                echo_ok++; rtt_sum += rtt;
                if (rtt < rtt_min) rtt_min = rtt;
                if (rtt > rtt_max) rtt_max = rtt;
                printf("PERF_RTT seq=%u rtt_us=%.1f\n", seq, rtt);
            } else {
                echo_lost++;
            }
        }

        next += interval_ns;
        struct timespec tw = { .tv_sec = (time_t)(next / 1000000000ull),
                               .tv_nsec = (long)(next % 1000000000ull) };
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &tw, NULL);
    }
    double dt = (double)(now_ns() - t0) / 1e9;
    printf("PERF_CLI_DONE tx_pkts=%llu tx_bytes=%llu offered_kbps=%.1f sent_kbps=%.1f dur=%.1f\n",
           (unsigned long long)tx_pkts, (unsigned long long)tx_bytes,
           (double)bps/1e3, (double)tx_bytes*8.0/1e3/dt, dt);
    if (echo) {
        printf("PERF_RTT_SUMMARY ok=%llu lost=%llu rtt_min_us=%.1f rtt_mean_us=%.1f rtt_max_us=%.1f\n",
               (unsigned long long)echo_ok, (unsigned long long)echo_lost,
               echo_ok ? rtt_min : 0.0, echo_ok ? rtt_sum/(double)echo_ok : 0.0,
               echo_ok ? rtt_max : 0.0);
    }
    fflush(stdout);
    free(buf); close(fd);
    return 0;
}

/* ---------------- selftest ---------------- */
static int run_selftest(void)
{
    int port = 5099;
    pid_t pid = fork();
    if (pid == 0) { run_server(port, 1, 1); _exit(0); }
    usleep(200000);   /* let the server bind */
    /* 200 kbit/s, 88-byte payload, 2 s, echo/RTT on localhost */
    int rc = run_client("127.0.0.1", port, 200000, 88, 2, 1);
    kill(pid, SIGTERM); waitpid(pid, NULL, 0);
    if (rc != 0) { printf("SELFTEST FAIL client rc=%d\n", rc); return 1; }
    printf("PERF_SELFTEST PASS\n");
    return 0;
}

int main(int argc, char **argv)
{
    int server = 0, echo = 0, port = 5001, len = 88, secs = 30;
    uint64_t bps = 100000;
    const char *ip = NULL;
    /* sigaction WITHOUT SA_RESTART so recvfrom returns EINTR on stop */
    struct sigaction sa = {0};
    sa.sa_handler = on_stop;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-s")) server = 1;
        else if (!strcmp(argv[i], "-e")) echo = 1;
        else if (!strcmp(argv[i], "-c") && i+1 < argc) ip = argv[++i];
        else if (!strcmp(argv[i], "-b") && i+1 < argc) bps = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "-l") && i+1 < argc) len = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i+1 < argc) secs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-p") && i+1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--selftest")) return run_selftest();
        else { fprintf(stderr, "usage: %s {-s | -c IP} [-e] [-b bps] [-l bytes] [-t secs] [-p port] | --selftest\n", argv[0]); return 2; }
    }
    if (server)  return run_server(port, echo, 0);
    if (ip)      return run_client(ip, port, bps, len, secs, echo);
    fprintf(stderr, "specify -s or -c IP (or --selftest)\n");
    return 2;
}
