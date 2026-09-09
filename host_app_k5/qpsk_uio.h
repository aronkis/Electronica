/* qpsk_uio.h -- UIO (userspace I/O) helpers for the interrupt-driven qpsk_tun
 * event loop. These own ONLY the /sys scan and the /dev/uioN fd ops; the DMA
 * register access (including the IRQ_PENDING W1C ack) stays in qpsk_tun.c via
 * the existing dmac register accessor. See qpsk_uio.c and Task B2.
 *
 * The UIO-exposing boot image (uio_pdrv_genirq / generic-uio nodes named
 * "qpsk_tx_dma", "qpsk_rx_dma", and an AXI GPIO "qpsk_byte_gpio") binds these
 * nodes; on a pre-UIO image they return "not present" and qpsk_tun falls back
 * to its byte-for-byte-identical polled path.
 *
 * NAME-MATCH NOTE: uio_pdrv_genirq renders the UIO name either bare
 * ("qpsk_tx_dma") or WITH the @unit-address ("qpsk_tx_dma@9d100000"); the
 * deployed kernel 6.12.77 uses the '@' form. The lookups below match either.
 */
#ifndef QPSK_UIO_H
#define QPSK_UIO_H

#include <stdint.h>

/* Scan /sys/class/uio/uio*\/name for `name` (matched either exactly or as
 * `name` immediately followed by '@<unit-address>'); on a hit open the matching
 * /dev/uioN with O_RDWR|O_CLOEXEC and return the fd. Returns -1 if no node
 * matches or the open fails. */
int qpsk_uio_open(const char *name);

/* Re-enable the device interrupt for a uio_pdrv_genirq node by writing the
 * uint32 value 1 to `fd`. Returns 0 on success, -1 on a short/failed write. */
int qpsk_uio_irq_enable(int fd);

/* Positive-presence probe for the byte_ctrl_gpio (AXI GPIO @ 0x9D300000).
 * Returns 1 ONLY on positive evidence: a /sys/class/uio node named
 * "qpsk_byte_gpio", OR a claimed region at 9d300000 in /proc/iomem. Never
 * infers presence from reading /dev/mem (a floating bus reads 0xFFFFFFFF).
 * Returns 0 otherwise. */
int qpsk_gpio_present(void);

/* Scan an /proc/iomem-format file for a "reserved" region that fully covers
 * the closed physical range [base, top]. Returns 1 iff some line of the form
 *   "<start>-<end> : reserved"   (any indent / zero-pad; hex, no 0x prefix)
 * satisfies start <= base && end >= top; 0 otherwise (absent OR too small).
 * `path` is a parameter so the parser is unit-testable with a synthetic file;
 * production passes "/proc/iomem". This backs the -DQPSK_CARVE_2MB startup
 * guard: a 2 MB-carve binary on a board whose device tree still reserves only
 * the old 1 MB ("7ff00000-7fffffff : reserved") must refuse to run, or the
 * S2MM engine scribbles kernel RAM below 0x7FE00000. */
int qpsk_iomem_reserved_covers(const char *path, uint64_t base, uint64_t top);

#endif /* QPSK_UIO_H */
