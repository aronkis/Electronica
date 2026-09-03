# host_app_k5 -- two-radio K5 port of the QPSK host tools.
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

# Board profile: default ZynqMP (Jupiter / ADRV9002-ZCU102 byte bitstream).
# For the ZedBoard (Zynq-7000) byte design:   make BOARD=zed
BOARD   ?= zynqmp
ifeq ($(BOARD),zed)
CFLAGS  += -DQPSK_BOARD_ZED
endif

all: qpsk_tun qpsk_capture qpsk_ringwrite

qpsk_ringwrite: qpsk_ringwrite.c
	$(CC) $(CFLAGS) -o qpsk_ringwrite qpsk_ringwrite.c

qpsk_frame.o: qpsk_frame.c qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_frame.c

qpsk_ber.o: qpsk_ber.c qpsk_ber.h qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_ber.c

qpsk_seq.o: qpsk_seq.c qpsk_seq.h qpsk_frame.h
	$(CC) $(CFLAGS) -c qpsk_seq.c

qpsk_tun: qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_hw.h qpsk_ber.h qpsk_seq.h
	$(CC) $(CFLAGS) -o qpsk_tun qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o

qpsk_capture: qpsk_capture.c qpsk_hw.h
	$(CC) $(CFLAGS) -o qpsk_capture qpsk_capture.c

test_frame: test_frame.c qpsk_frame.o
	$(CC) $(CFLAGS) -o test_frame test_frame.c qpsk_frame.o

# -F path unit test: includes qpsk_tun.c (main renamed) and drives its Tx
# path against a fake in-memory DMA regfile -- no hardware needed.
test_k5: test_k5.c qpsk_tun.c qpsk_frame.o qpsk_ber.o qpsk_seq.o qpsk_frame.h qpsk_hw.h qpsk_ber.h qpsk_seq.h
	$(CC) $(CFLAGS) -o test_k5 test_k5.c qpsk_frame.o qpsk_ber.o qpsk_seq.o

# full-packet BER scorer self-test (no hardware; also `qpsk_tun -T` on-board)
test_ber: test_ber.c qpsk_ber.o qpsk_frame.o qpsk_ber.h qpsk_frame.h
	$(CC) $(CFLAGS) -o test_ber test_ber.c qpsk_ber.o qpsk_frame.o

# whitened-mode encode/decode transparency (no hardware)
test_whiten: test_whiten.c qpsk_frame.o qpsk_frame.h
	$(CC) $(CFLAGS) -o test_whiten test_whiten.c qpsk_frame.o

# -S sequence-streaming scorer self-test (no hardware)
test_seq: test_seq.c qpsk_seq.o qpsk_frame.o qpsk_seq.h qpsk_frame.h
	$(CC) $(CFLAGS) -o test_seq test_seq.c qpsk_seq.o qpsk_frame.o

test: test_frame test_k5 test_ber test_whiten test_seq
	./test_frame
	./test_k5
	./test_ber
	./test_whiten
	./test_seq

clean:
	rm -f *.o qpsk_tun qpsk_capture test_frame test_k5 test_ber test_whiten test_seq
