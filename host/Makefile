# host -- two-radio K5 port of the QPSK host tools.
#
# Two build targets:
#   host tests (x86 dev box):   make test          (test_frame + test_k5)
#   board (aarch64 Debian):     make               (plain gcc -O2 on the
#                               board itself; no exotic deps -- libc only)
# The K5 image moves tx_data_source to 0x158 (see qpsk_hw.h
# QPSK_TX_DATA_SOURCE_OFF); build against a legacy byte image with
#   make CFLAGS+='-DQPSK_TX_DATA_SOURCE_OFF=0x11Cu'
# make's builtin CC=cc masks `?=`, and `cc` is not guaranteed on the board
# images -- force gcc (a command-line `make CC=...` still overrides this)
CC      = gcc
CFLAGS  ?= -O2 -Wall -Wextra -Werror
# -I. lets modem_status/*.c and tests/*.c resolve #include "qpsk_hw.h"
# (this Makefile always runs with host/ as cwd).
CFLAGS  += -I.

# Board profile: default ZynqMP (Jupiter / ADRV9002-ZCU102 byte bitstream).
# For the ZedBoard (Zynq-7000) byte design:   make BOARD=zed
BOARD   ?= zynqmp
ifeq ($(BOARD),zed)
CFLAGS  += -DQPSK_BOARD_ZED
endif

all: qpsk_tun qpsk_capture qpsk_ringwrite qpsk_perf modem_status/modem_status

# xvc_server: Xilinx Virtual Cable daemon for the debug_bridge (AXI-to-BSCAN)
# image -- /dev/mem only, no kernel module. Not in `all`: build on demand.
xvc_server: xvc_server.c
	$(CC) $(CFLAGS) -o xvc_server xvc_server.c

# qpsk_perf: control-free UDP throughput/RTT instrument for RF-link
# characterization (libc-only; built on-board like the other tools).
qpsk_perf: qpsk_perf.c
	$(CC) $(CFLAGS) -o qpsk_perf qpsk_perf.c

qpsk_ringwrite: qpsk_ringwrite.c
	$(CC) $(CFLAGS) -o qpsk_ringwrite qpsk_ringwrite.c

qpsk_frame.o: qpsk_frame.c qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_frame.c

qpsk_ber.o: qpsk_ber.c qpsk_ber.h qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_ber.c

qpsk_seq.o: qpsk_seq.c qpsk_seq.h qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_seq.c

qpsk_uio.o: qpsk_uio.c qpsk_uio.h
	$(CC) $(CFLAGS) -c qpsk_uio.c

qpsk_tun: qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o qpsk_hw.h qpsk_ber.h qpsk_seq.h qpsk_uio.h qpsk_join.h
	$(CC) $(CFLAGS) -o qpsk_tun qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o

qpsk_capture: qpsk_capture.c qpsk_hw.h
	$(CC) $(CFLAGS) -o qpsk_capture qpsk_capture.c

# qpsk_tun_2mb: the 2 MB-carve host build for 1536 B frames (f1536 / -G). A
# target-specific CFLAGS is used deliberately: `make CFLAGS+=-DQPSK_CARVE_2MB`
# on the command line REPLACES CFLAGS and silently drops -Wall/-Werror, so the
# "2 MB config builds -Werror clean" guarantee would not actually be tested.
# Compiled straight from .c (not the shared .o) so the define never pollutes the
# default 1 MB objects. The binary's startup carve guard (qpsk_tun.c) refuses to
# run until the 2 MB qpsk dtb is deployed -- see docs/setup-prebuilt.rst Step 0.
qpsk_tun_2mb: CFLAGS += -DQPSK_CARVE_2MB
qpsk_tun_2mb: qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c qpsk_hw.h qpsk_frame.h qpsk_ber.h qpsk_seq.h qpsk_uio.h qpsk_join.h
	$(CC) $(CFLAGS) -o qpsk_tun_2mb qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c

# ref_dump: print the fixed -B reference frame as 16 uint64 words for the
# offline byte scorer. Output format is the contract in contract/decode_ref_k5.m.
ref_dump: ref_dump.c qpsk_ber.o qpsk_frame.o qpsk_ber.h qpsk_frame.h
	$(CC) $(CFLAGS) -o ref_dump ref_dump.c qpsk_ber.o qpsk_frame.o

# seq_dump: print the exact -S wire frame bytes for given seqs; the C ground
# truth that tests/TestFrameContract.m cross-checks seq_frame_bytes_k5.m against.
seq_dump: seq_dump.c qpsk_seq.o qpsk_frame.o qpsk_seq.h qpsk_frame.h
	$(CC) $(CFLAGS) -o seq_dump seq_dump.c qpsk_seq.o qpsk_frame.o

# --- host/tests/: C unit tests (not the K5-region test_modem_status, which
# lives beside the module it tests in modem_status/) ---
test_frame: tests/test_frame.c qpsk_frame.o qpsk_join.h
	$(CC) $(CFLAGS) -o test_frame tests/test_frame.c qpsk_frame.o

# -F path unit test: includes qpsk_tun.c (main renamed) and drives its Tx
# path against a fake in-memory DMA regfile -- no hardware needed.
test_k5: tests/test_k5.c qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o qpsk_frame.h qpsk_hw.h qpsk_ber.h qpsk_seq.h qpsk_uio.h qpsk_join.h
	$(CC) $(CFLAGS) -o test_k5 tests/test_k5.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o

# full-packet BER scorer self-test (no hardware; also `qpsk_tun -T` on-board)
test_ber: tests/test_ber.c qpsk_ber.o qpsk_frame.o qpsk_ber.h qpsk_frame.h
	$(CC) $(CFLAGS) -o test_ber tests/test_ber.c qpsk_ber.o qpsk_frame.o

# whitened-mode encode/decode transparency (no hardware)
test_whiten: tests/test_whiten.c qpsk_frame.o qpsk_frame.h
	$(CC) $(CFLAGS) -o test_whiten tests/test_whiten.c qpsk_frame.o

# -S sequence-streaming scorer self-test (no hardware)
test_seq: tests/test_seq.c qpsk_seq.o qpsk_frame.o qpsk_seq.h qpsk_frame.h
	$(CC) $(CFLAGS) -o test_seq tests/test_seq.c qpsk_seq.o qpsk_frame.o

test_txq: tests/test_txq.c qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o qpsk_frame.h qpsk_hw.h qpsk_ber.h qpsk_seq.h qpsk_uio.h qpsk_join.h
	$(CC) $(CFLAGS) -o test_txq tests/test_txq.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_uio.o -lm

# COMB campaign T0a: TX<->RX per-frame join + on-disk record ABI (host-only)
test_txlog: tests/test_txlog.c qpsk_frame.o qpsk_frame.h qpsk_join.h
	$(CC) $(CFLAGS) -o test_txlog tests/test_txlog.c qpsk_frame.o

# RXFIX Task 26: the RX carve re-anchor. Built with -DQPSK_CARVE_2MB so the
# synthetic carve has the DEPLOYED geometry (SLOT_BYTES 2048, 1528 B frames),
# and compiled straight from the .c files -- a target-specific CFLAGS is
# inherited by prerequisites, so building it against the shared .o objects
# would silently rebuild them with the 2 MB define (same reason qpsk_tun_2mb
# does it this way).
test_rxresync: CFLAGS += -DQPSK_CARVE_2MB
test_rxresync: tests/test_rxresync.c qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c qpsk_frame.h qpsk_hw.h qpsk_ber.h qpsk_seq.h qpsk_uio.h qpsk_join.h
	$(CC) $(CFLAGS) -o test_rxresync tests/test_rxresync.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c -lm

# --- host/modem_status/: on-board link status TUI (libc only, no curses).
# Per-board build: 148 is arm64, 146 is armhf. _FILE_OFFSET_BITS=64 is
# required on armhf where 0x9D000000 exceeds a 32-bit off_t and mmap fails
# EINVAL.
MS_HDRS = modem_status/modem_status.h modem_status/ms_src.h modem_status/ms_regmap.h modem_status/ms_collect.h modem_status/ms_delta.h modem_status/ms_health.h modem_status/ms_render.h modem_status/ms_term.h modem_status/ms_curses.h qpsk_hw.h
MS_CURSES_LIBS ?= -lncursesw -ltinfo
MS_OBJS = modem_status/ms_regmap.o modem_status/ms_collect.o modem_status/ms_delta.o modem_status/ms_health.o modem_status/ms_render.o modem_status/ms_term.o

modem_status/ms_regmap.o: modem_status/ms_regmap.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_regmap.c -o modem_status/ms_regmap.o
modem_status/ms_collect.o: modem_status/ms_collect.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_collect.c -o modem_status/ms_collect.o
modem_status/ms_delta.o: modem_status/ms_delta.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_delta.c -o modem_status/ms_delta.o
modem_status/ms_health.o: modem_status/ms_health.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_health.c -o modem_status/ms_health.o
modem_status/ms_render.o: modem_status/ms_render.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_render.c -o modem_status/ms_render.o
modem_status/ms_term.o: modem_status/ms_term.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_term.c -o modem_status/ms_term.o
modem_status/ms_curses.o: modem_status/ms_curses.c $(MS_HDRS)
	$(CC) $(CFLAGS) -c modem_status/ms_curses.c -o modem_status/ms_curses.o
modem_status/ms_src_hw.o: modem_status/ms_src_hw.c modem_status/ms_src_hw.h $(MS_HDRS)
	$(CC) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -c modem_status/ms_src_hw.c -o modem_status/ms_src_hw.o

# The TUI is ncurses (libncurses-dev on the board: present on 146, installed
# on 148 2026-09-09); --plain keeps the libc VT100 fallback. Tests never link
# ms_curses.o, so the text renderer stays golden-testable.
modem_status/modem_status: modem_status/modem_status.c modem_status/ms_src_hw.o modem_status/ms_curses.o $(MS_OBJS) $(MS_HDRS) modem_status/ms_src_hw.h
	$(CC) $(CFLAGS) -D_FILE_OFFSET_BITS=64 -o modem_status/modem_status modem_status/modem_status.c modem_status/ms_src_hw.o modem_status/ms_curses.o $(MS_OBJS) $(MS_CURSES_LIBS)

# Safety gate: the status tool must never carry the debugfs latch path or a
# writable mapping (modem_status.h contract items 1-2).
ms_safety_check: modem_status/ms_src_hw.o $(MS_OBJS)
	@! grep -l "direct_reg_access" modem_status/ms_src_hw.c modem_status/ms_collect.c modem_status/ms_render.c modem_status/modem_status.c >/dev/null || (echo "SAFETY: direct_reg_access referenced" && exit 1)
	@! grep -l "PROT_WRITE" modem_status/ms_src_hw.c modem_status/modem_status.c >/dev/null || (echo "SAFETY: PROT_WRITE referenced" && exit 1)
	@echo "ms_safety_check: ok"

modem_status/test_modem_status: modem_status/test_modem_status.c modem_status/ms_src_fake.c modem_status/ms_src_fake.h $(MS_OBJS) $(MS_HDRS)
	$(CC) $(CFLAGS) -Imodem_status -o modem_status/test_modem_status modem_status/test_modem_status.c modem_status/ms_src_fake.c $(MS_OBJS)
# convenience alias so `make test_modem_status` still works by name
.PHONY: test_modem_status
test_modem_status: modem_status/test_modem_status

test: test_frame test_k5 test_ber test_whiten test_seq test_txq test_txlog test_rxresync modem_status/test_modem_status ms_safety_check
	./test_frame
	./test_k5
	./test_ber
	./test_whiten
	./test_seq
	./test_txq
	./test_txlog
	./test_rxresync
	./modem_status/test_modem_status

clean:
	rm -f *.o qpsk_tun qpsk_tun_2mb qpsk_capture test_frame test_k5 test_ber test_whiten test_seq test_txq test_txlog test_rxresync
	rm -f modem_status/*.o modem_status/modem_status modem_status/test_modem_status
	rm -f tests/*.o
