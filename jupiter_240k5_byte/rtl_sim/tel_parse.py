#!/usr/bin/env python3
"""tel_parse.py -- T8.7 telemetry stream parser (mux mode 4, 24-slot rotation).

Usage:
  tel_parse.py traj   <rx2_capture.iq> <out_traj.txt>
      Reassemble {I<<16|Q} words, lock to the 0xA5C0FFEE marker (period 24),
      emit one line per image: "<word_index_in_stream> w0..w21 imgctr" (hex).
  tel_parse.py inject <rx2_capture.iq> <image_number> <out_inject.txt> [prefix]
      Emit an inject file (register-name hex-value lines) for sim_byte_inject
      from the chosen image. prefix defaults to the wrap_byte_taps dut path.
  tel_parse.py names  [prefix]
      Print the register names used (for validation against inject_map).

Slot layout (canary3_telemetry_overlay): see SLOTMAP below. Wide registers
split lo/hi across slots and are recombined here. 2-deep pipe arrays capture
element [1] only (element [0] reconstructs from the previous image offline;
injection of [0] uses the value of [1] one image earlier when available,
else duplicates -- a 1-beat approximation flagged in the output).
"""
import sys, struct

P = 'wrap_byte_taps__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__'
FTS = P + 'u_Frequency_and_Time_Synchronizer__DOT__'
SS  = FTS + 'u_Symbol_Synchronizer__DOT__'
CS  = FTS + 'u_Carrier_Synchronizer__DOT__'
AGC = P + 'u_Automatic_Gain_Control__DOT__'

MARKER = 0xA5C0FFEE
# live captures read the marker as 0xA5C5FFEE (+5 on hi16; data slots proven
# bit-exact via csI==csD3 5000/5000 -- marker-specific capture quirk, see
# hunt 20260714_024112_fwd analysis). Accept both.
MARKERS = {0xA5C0FFEE, 0xA5C5FFEE}
NSLOT = 24

def regs_for_image(w, prev):
    """map the 22 data words of one image (+prev image for [0] elems) to regs"""
    out = []
    def add(name, val): out.append((name, val))
    # SS loop filter
    add(SS+'u_Loop_Filter__DOT__Delay_out1',  w[0] & ((1<<30)-1))
    add(SS+'u_Loop_Filter__DOT__Delay4_out1', w[2] & ((1<<30)-1))
    add(SS+'u_Loop_Filter__DOT__Delay1_out1', w[1] & ((1<<30)-1))
    add(SS+'u_Loop_Filter__DOT__Delay6_out1', w[3] & ((1<<30)-1))
    d3, d5 = w[4] & ((1<<30)-1), w[5] & ((1<<30)-1)
    d2 = (w[7] << 32 | w[6]) & ((1<<40)-1)
    for nm, v1, wd in [('Delay3_reg', d3, 30), ('Delay5_reg', d5, 30), ('Delay2_reg', d2, 40)]:
        v0 = prev.get(nm, v1)   # element[0] from previous image where known
        add(SS+f'u_Loop_Filter__DOT__{nm}[1]', v1)
        add(SS+f'u_Loop_Filter__DOT__{nm}[0]', v0)
        prev[nm] = None  # updated by caller
    # IC
    ic = w[8]
    add(SS+'u_Interpolation_Control__DOT__muReg',       ic & 0x7FF)
    add(SS+'u_Interpolation_Control__DOT__countReg',   (ic >> 11) & 0x7FF)
    add(SS+'u_Interpolation_Control__DOT__underflowReg',(ic >> 22) & 1)
    # CS loop filter
    add(CS+'u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous_out1',  w[9] & ((1<<29)-1))
    add(CS+'u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1', (w[11] << 32 | w[10]) & ((1<<39)-1))
    add(CS+'u_Loop_Filter__DOT__Delay7_reg[1]',  w[12] & 0x1FFF)
    add(CS+'u_Loop_Filter__DOT__Delay5_reg[1]', (w[12] >> 13) & 0x1FFF)
    add(CS+'u_Loop_Filter__DOT__Delay6_reg[1]',  w[13] & ((1<<29)-1))
    add(CS+'u_Loop_Filter__DOT__Delay2_reg[1]',  w[14] & ((1<<29)-1))
    add(CS+'u_Loop_Filter__DOT__Delay1_reg[1]',  w[15] & ((1<<29)-1))
    add(CS+'u_Loop_Filter__DOT__Delay3_reg[1]', (w[17] << 32 | w[16]) & ((1<<39)-1))
    # AGC integrator (complex sfix34)
    add(AGC+'u_Loop_Filter__DOT__Delay1_out1_re', (w[19] << 32 | w[18]) & ((1<<34)-1))
    add(AGC+'u_Loop_Filter__DOT__Delay1_out1_im', (w[21] << 32 | w[20]) & ((1<<34)-1))
    return out

def load_words(path):
    d = open(path, 'rb').read()
    n = len(d) // 4
    vals = struct.unpack(f'<{2*n}h', d[:4*n])
    return [((vals[2*i] & 0xFFFF) << 16) | (vals[2*i+1] & 0xFFFF) for i in range(n)]

def find_images(w):
    # marker at slot 22: find phase with periodic markers
    best, bestn = -1, 0
    for ph in range(NSLOT):
        hits = sum(1 for k in range(ph, min(len(w), ph + 240*NSLOT), NSLOT) if w[k] in MARKERS)
        if hits > bestn: best, bestn = ph, hits
    if bestn < 3: raise SystemExit('no telemetry marker lock (is the mux in mode 4?)')
    imgs = []
    k = best
    while k + 1 < len(w):
        if w[k] in MARKERS:
            s = k - 22  # slot0 index
            if s >= 0 and s + 23 < len(w):
                imgs.append((s, w[s:s+22], w[k+1]))
        k += NSLOT
    return imgs

def main():
    mode = sys.argv[1]
    if mode == 'names':
        prev = {}
        for n, _ in regs_for_image([0]*22, prev): print(n)
        return
    w = load_words(sys.argv[2])
    imgs = find_images(w)
    sys.stderr.write(f'{len(imgs)} telemetry images locked\n')
    if mode == 'traj':
        with open(sys.argv[3], 'w') as f:
            for s, ws, ctr in imgs:
                f.write('%d %s %x\n' % (s, ' '.join('%x' % x for x in ws), ctr))
    elif mode == 'inject':
        num = int(sys.argv[3])
        s, ws, ctr = imgs[num]
        prevmap = {}
        if num > 0:
            _, pw, _ = imgs[num-1]
            prevmap = {'Delay3_reg': pw[4] & ((1<<30)-1), 'Delay5_reg': pw[5] & ((1<<30)-1),
                       'Delay2_reg': ((pw[7] << 32 | pw[6]) & ((1<<40)-1))}
        with open(sys.argv[4], 'w') as f:
            for n, v in regs_for_image(ws, prevmap):
                f.write('%s %x\n' % (n, v))
        sys.stderr.write(f'image {num} (stream word {s}, ctr {ctr}) -> {sys.argv[4]}\n')

if __name__ == '__main__':
    main()
