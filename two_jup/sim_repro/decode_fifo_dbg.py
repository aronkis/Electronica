#!/usr/bin/env python3
"""decode_fifo_dbg.py <hex32>... -- decode the v5 DEBUG ByteRxFifo word read at AXI 0x1B0."""
import sys
for h in sys.argv[1:]:
    v=int(h,16)
    print(f"{h}: rdyRun={(v>>24)&0xFF} ready_1={(v>>23)&1} valid_i={(v>>22)&1} ready_raw={(v>>21)&1} stateControl={(v>>20)&1} enb={(v>>19)&1} nonempty={(v>>18)&1} byp_sel={(v>>17)&1} ovf_nonzero={(v>>16)&1} wr={(v>>8)&0xFF} rd={v&0xFF}")
