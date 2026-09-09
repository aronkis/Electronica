#!/usr/bin/env python3
"""[sim] Task 12 G1: SEQ-KEYED delivered-content identity between two SRO legs.

WHY NOT A ROW-KEYED diff.  Task 11's chain compared `cut -d, -f2,3,4 <p>_deliv.txt`
between the R3S leg and the banked baseline with plain `diff`.  That is keyed on ROW
INDEX, which is only valid while both runs deliver exactly the same frames in the same
order.  R4 suppresses every pop until the ring has pre-filled, so it emits no valids
during the pre-fill window where the baseline emitted some; the acquisition/lock
trajectory can therefore gain or lose a frame at the HEAD, and a row-keyed diff would
then report a wholesale mismatch even though every commonly delivered frame is
byte-identical.  That is the same class of comparator bug as Task 11's `sidx` false
alarm, in a new guise, and it is avoided here by joining on the TGEN sequence number.

`<p>_deliv.txt` (sidx,nwords,hash,user) and `<p>_seq.txt`
(sidx,nbytes,magic,seq,nbad,ok) carry one row per delivered byte-plane frame and are
written in the same order by the same driver pass -- asserted here on the sidx column
rather than assumed.

Reports, for the pair:
  * how many frames each run delivered, and how many carry the TGEN magic;
  * the number of seq values common to both, and any seq delivered by only one;
  * for every COMMON seq: whether nwords / FNV hash / user flag are all equal;
  * the per-seq sidx delta, its mode and its spread -- this IS the "constant pre-fill
    latency" the brief asks to be stated, and measuring it per-seq is what makes
    "constant" a finding rather than an assumption.

Usage:  t12_ident.py <new_prefix> <baseline_prefix>
"""
import sys, collections


def load(pfx):
    d = []
    with open(pfx + '_deliv.txt') as f:
        for ln in f:
            a = ln.strip().split(',')
            if len(a) == 4:
                d.append(dict(sidx=int(a[0]), nwords=int(a[1]), hash=a[2], user=int(a[3])))
    q = []
    with open(pfx + '_seq.txt') as f:
        for ln in f:
            if ln.startswith('#'):
                continue
            a = ln.strip().split(',')
            if len(a) == 6:
                q.append(dict(sidx=int(a[0]), nbytes=int(a[1]), magic=int(a[2]),
                              seq=int(a[3]), nbad=int(a[4]), ok=int(a[5])))
    assert len(d) == len(q), f'{pfx}: {len(d)} deliv rows vs {len(q)} seq rows'
    for i, (x, y) in enumerate(zip(d, q)):
        assert x['sidx'] == y['sidx'], f'{pfx}: row {i} sidx {x["sidx"]} != {y["sidx"]}'
        x.update(seq=y['seq'], magic=y['magic'], ok=y['ok'], nbad=y['nbad'])
    return d


def main(newp, basep):
    A = load(newp)
    B = load(basep)
    print(f'{newp}: {len(A)} delivered frames, {sum(1 for r in A if r["magic"])} with magic')
    print(f'{basep}: {len(B)} delivered frames, {sum(1 for r in B if r["magic"])} with magic')

    # index the magic-bearing frames by seq; a frame without magic has no key at all
    da = {r['seq']: r for r in A if r['magic']}
    db = {r['seq']: r for r in B if r['magic']}
    dupA = len([r for r in A if r['magic']]) - len(da)
    dupB = len([r for r in B if r['magic']]) - len(db)
    if dupA or dupB:
        print(f'  WARNING duplicate seq keys: {newp} {dupA}, {basep} {dupB}')
    common = sorted(set(da) & set(db))
    onlyA = sorted(set(da) - set(db))
    onlyB = sorted(set(db) - set(da))
    print(f'  common seq: {len(common)}   only in {newp}: {onlyA}   only in {basep}: {onlyB}')
    nomagicA = [r['sidx'] for r in A if not r['magic']]
    nomagicB = [r['sidx'] for r in B if not r['magic']]
    print(f'  frames without magic: {newp} {len(nomagicA)} at sidx {nomagicA[:6]}; '
          f'{basep} {len(nomagicB)} at sidx {nomagicB[:6]}')

    bad = [s for s in common
           if (da[s]['nwords'], da[s]['hash'], da[s]['user']) !=
              (db[s]['nwords'], db[s]['hash'], db[s]['user'])]
    print(f'  CONTENT (nwords,hash,user) equal on {len(common)-len(bad)}/{len(common)} '
          f'common seq; mismatching seq: {bad[:20]}{" ..." if len(bad) > 20 else ""}')
    for s in bad[:5]:
        print(f'    seq {s}: {newp} {da[s]["nwords"]},{da[s]["hash"]},{da[s]["user"]}  '
              f'{basep} {db[s]["nwords"]},{db[s]["hash"]},{db[s]["user"]}')

    dl = [da[s]['sidx'] - db[s]['sidx'] for s in common]
    if dl:
        c = collections.Counter(dl)
        mode, n = c.most_common(1)[0]
        print(f'  sidx delta ({newp} - {basep}) over {len(dl)} common seq: '
              f'min={min(dl)} max={max(dl)} mode={mode} ({n}/{len(dl)} frames)')
        print(f'    distribution: ' +
              ' '.join(f'{k}:{v}' for k, v in sorted(c.items())[:12]) +
              (' ...' if len(c) > 12 else ''))
        const = (min(dl) == max(dl))
        print(f'  PRE-FILL LATENCY: {"CONSTANT " + str(mode) if const else "NOT constant"}'
              f' input samples ({mode/4.0:g} symbols at 4 sps)')
    verdict = (not bad) and (not onlyA) and (not onlyB)
    print(f'T12_IDENT {"PASS" if verdict else "FAIL"} '
          f'content_equal={not bad} same_seq_set={not onlyA and not onlyB}')
    return 0 if verdict else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
