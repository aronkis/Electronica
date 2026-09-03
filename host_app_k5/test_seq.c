/* test_seq -- host-side unit test for the -S sequence-streaming scorer
 * (qpsk_seq.c). No hardware. */
#include <stdio.h>
#include "qpsk_seq.h"

int main(void)
{
    int rc = qpsk_seq_selftest();
    if (rc == 0)
        printf("test_seq: OK\n");
    return rc;
}
