#!/usr/bin/env python3
"""t87_compare.py -- the REAL T8.7 per-event live-vs-sim state comparison.

Replaces the scaffolding compare in t87_protocol.sh step 4, which compared
packed live words against sim register values in a different order and never
aligned the two time bases (artifact: 'divergence' at the first compared
image in every event).

Method:
  1. Parse the tap ring (mode-4 telemetry) into images; each image's slot k
     was sampled at rail beat (w0 + k), where w0 is the image's word index in
     the tap file. Both rings save the trigger at index 4,194,304, so tap
     word index ~= input sample index (coarse); residual offset (ring-writer
     trigger jitter) is recovered by exact-matching the live slot-0 sequence
     (SS LF integrator, 30-bit) against the per-beat sim trace.
  2. The sim trace (interval 1, windowed) gives every subset register at
     every input sample. Compare register-by-register at the exact beats the
     live serializer sampled, from PRE frames before the trigger to POST
     frames after. Multi-slot (lo/hi) registers compare each part at its own
     beat. 2-deep pipe [0] elements are skipped (live value is a previous-
     image approximation by design).
  3. Report: alignment delta, pre-trigger match statistics (method
     validation), and every divergent (image, register) with values.

Usage: t87_compare.py <tap.iq> <simtraj.txt> <subset.txt>
                      [trig_word] [pre_frames] [post_frames]
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'jupiter_240k5_byte', 'rtl_sim'))
import tel_parse as tp

FRAME = 9064          # rail beats per frame
TRIG  = 4194304       # trigger index in both rings (16 MiB / 4)

SS = tp.SS; CS = tp.CS; AGC = tp.AGC

# (register, [(slot, word_shift, reg_lsb, mask), ...])
# live part = (word[slot] >> word_shift) & mask, placed at reg_lsb;
# sim  part = (sim_register >> reg_lsb)  & mask, placed at reg_lsb.
M30 = (1 << 30) - 1
M29 = (1 << 29) - 1
REGS = [
    (SS+'u_Loop_Filter__DOT__Delay_out1',    [(0, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay1_out1',   [(1, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay4_out1',   [(2, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay6_out1',   [(3, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay3_reg[1]', [(4, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay5_reg[1]', [(5, 0, 0, M30)]),
    (SS+'u_Loop_Filter__DOT__Delay2_reg[1]', [(6, 0, 0, 0xFFFFFFFF),
                                              (7, 0, 32, 0xFF)]),
    (SS+'u_Interpolation_Control__DOT__muReg',        [(8, 0, 0, 0x7FF)]),
    (SS+'u_Interpolation_Control__DOT__countReg',     [(8, 11, 0, 0x7FF)]),
    (SS+'u_Interpolation_Control__DOT__underflowReg', [(8, 22, 0, 0x1)]),
    (CS+'u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous_out1',
                                             [(9, 0, 0, M29)]),
    (CS+'u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1',
                                             [(10, 0, 0, 0xFFFFFFFF),
                                              (11, 0, 32, 0x7F)]),
    (CS+'u_Loop_Filter__DOT__Delay7_reg[1]', [(12, 0, 0, 0x1FFF)]),
    (CS+'u_Loop_Filter__DOT__Delay5_reg[1]', [(12, 13, 0, 0x1FFF)]),
    (CS+'u_Loop_Filter__DOT__Delay6_reg[1]', [(13, 0, 0, M29)]),
    (CS+'u_Loop_Filter__DOT__Delay2_reg[1]', [(14, 0, 0, M29)]),
    (CS+'u_Loop_Filter__DOT__Delay1_reg[1]', [(15, 0, 0, M29)]),
    (CS+'u_Loop_Filter__DOT__Delay3_reg[1]', [(16, 0, 0, 0xFFFFFFFF),
                                              (17, 0, 32, 0x7F)]),
    (AGC+'u_Loop_Filter__DOT__Delay1_out1_re', [(18, 0, 0, 0xFFFFFFFF),
                                                (19, 0, 32, 0x3)]),
    (AGC+'u_Loop_Filter__DOT__Delay1_out1_im', [(20, 0, 0, 0xFFFFFFFF),
                                                (21, 0, 32, 0x3)]),
]

def main():
    tap, traj, subset = sys.argv[1:4]
    trig = int(sys.argv[4]) if len(sys.argv) > 4 else TRIG
    pre  = int(sys.argv[5]) if len(sys.argv) > 5 else 2
    post = int(sys.argv[6]) if len(sys.argv) > 6 else 16

    names = [l.strip() for l in open(subset) if l.strip()]
    col = {n: i for i, n in enumerate(names)}

    sim = {}
    for l in open(traj):
        p = l.split()
        sim[int(p[0])] = p[1:]
    print(f'sim trace rows {len(sim)}')

    imgs = tp.find_images(tp.load_words(tap))
    sel = [(s, ws) for s, ws, ctr in imgs
           if trig - pre*FRAME - 24 <= s <= trig + post*FRAME]
    print(f'{len(sel)} images in compare span')

    # ---- fine alignment by value voting (ring-writer trigger offsets are
    # only chunk-accurate, +-64k) on three rich registers ----
    from collections import Counter, defaultdict
    votes = Counter()
    vote_regs = [(SS+'u_Loop_Filter__DOT__Delay_out1', 0),
                 (AGC+'u_Loop_Filter__DOT__Delay1_out1_re', 18),
                 (CS+'u_Loop_Filter__DOT__Unit_Delay_Enabled_Resettable_Synchronous1_out1', 10)]
    for name, slot in vote_regs:
        ci = col.get(name)
        if ci is None: continue
        byval = defaultdict(list)
        for si, row in sim.items():
            byval[int(row[ci], 16)].append(si)
        for s, ws in sel[:400]:
            v = ws[slot]
            if v == 0: continue
            for m in byval.get(v, ())[:50]:
                votes[m - (s + slot)] += 1
    if not votes:
        print('ALIGN_FAIL: no value votes at all'); return
    (bestd, best), = votes.most_common(1)
    near = sum(k for dd, k in votes.items() if abs(dd - bestd) <= 2)
    print(f'alignment: delta={bestd} votes={best} (near-peak {near}, '
          f'runner-up {votes.most_common(2)[-1] if len(votes)>1 else None})')
    # validate: exact-match rate of slot-0 anchors at bestd
    c0 = col[SS+'u_Loop_Filter__DOT__Delay_out1']
    anchor = [(s, ws[0]) for s, ws in sel[:200] if ws[0] != 0]
    m = sum(1 for s, w0 in anchor
            if (r := sim.get(s + bestd)) is not None and int(r[c0], 16) == w0)
    print(f'anchor check at delta: {m}/{len(anchor)} slot-0 exact')
    if m < len(anchor) * 6 // 10:
        print('ALIGN_WEAK -- verdicts unreliable')
    d = bestd

    # ---- per-image, per-register compare ----
    total = mism = pre_total = pre_mism = 0
    divs = []
    for s, ws in sel:
        for name, parts in REGS:
            ci = col.get(name)
            if ci is None:
                continue
            live = simv = 0
            ok = True
            for slot, wsh, lsb, mask in parts:
                r = sim.get(s + slot + d)
                if r is None:
                    ok = False; break
                live |= ((ws[slot] >> wsh) & mask) << lsb
                simv |= ((int(r[ci], 16) >> lsb) & mask) << lsb
            if not ok:
                continue
            total += 1
            if s + d < trig:
                pre_total += 1
            if live != simv:
                mism += 1
                if s + d < trig:
                    pre_mism += 1
                if len(divs) < 40:
                    divs.append((s, s - trig, name.split('__DOT__')[-1],
                                 hex(live), hex(simv)))
    print(f'compared {total} register-samples; mismatches {mism}')
    print(f'pre-trigger: {pre_mism}/{pre_total} mismatched (method check)')
    if divs:
        print('first divergences (word, rel-to-trig, reg, live, sim):')
        for v in divs[:25]:
            print('  ', v)
    else:
        print('NO DIVERGENCE: every monitored register matches sim at every '
              'compared beat across the episode span.')

if __name__ == '__main__':
    main()
