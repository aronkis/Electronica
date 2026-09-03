/* test_ber.c -- runs the full-packet BER scorer self-test (qpsk_ber_selftest).
 * No hardware. Same check is reachable on-board via `qpsk_tun -T`. */
#include "qpsk_ber.h"

int main(void)
{
    return qpsk_ber_selftest();
}
