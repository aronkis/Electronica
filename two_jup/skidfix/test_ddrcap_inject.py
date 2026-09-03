#!/usr/bin/env python3
"""Regression test for ddrcap_inject.main()'s SUCCESS CRITERION.

Three separate review rounds each found, by hand, the same defect: main()
returning 0 while nothing that matters was patched. A patcher that reports
success without patching is the same class of instrument fault as a counter
that never increments -- it passes every clean run. This locks the decision
logic down so a fourth round is not needed.

It deliberately stubs the per-file patchers: what is under test is main()'s
verdict, not the Verilog edits (those are covered by the sim gate and the
golden digests). verify_zip stays LIVE, because vacuous zip verification is
exactly the bug that kept coming back.

Run: python3 two_jup/skidfix/test_ddrcap_inject.py
"""
import importlib.util, os, shutil, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('inj', os.path.join(HERE, 'ddrcap_inject.py'))
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)

for key in list(inj.PATCHERS):
    inj.PATCHERS[key] = lambda path: 'patched'

def tree(root, names, zips=0, zip_ok=False, build_marker=None, sibling_ips=0):
    hdl = os.path.join(root, 'hdlsrc')
    os.makedirs(hdl, exist_ok=True)
    for n in names:
        open(os.path.join(hdl, n), 'w').write('// stub\n')
    if build_marker == 'xpr':
        open(os.path.join(root, 'proj.xpr'), 'w').write('<project/>')
    elif build_marker:
        os.makedirs(os.path.join(root, build_marker), exist_ok=True)
    # A real build tree carries component.xml for dozens of UNRELATED cores.
    # Dispatching on the bare filename fed those to patch_component_xml, whose
    # anchor assert killed the walk mid-tree -- found only when Task 4 ran the
    # injector against a real 1.5 GB tree, because no fixture had this shape.
    for i in range(sibling_ips):
        # NB: not under vivado_ip_prj/ -- that name is itself a build-tree
        # marker, and the first version of this fixture tripped it and failed
        # for the wrong reason. Siblings live beside the IP, not inside it.
        d2 = os.path.join(root, 'library', f'other_ip_{i}')
        os.makedirs(d2, exist_ok=True)
        open(os.path.join(d2, 'component.xml'), 'w').write(
            '<spirit:component><spirit:name>unrelated</spirit:name></spirit:component>')
    for i in range(zips):
        zp = os.path.join(root, f'z{i}', 'TxRxCompo_ip_v1_0.zip')
        os.makedirs(os.path.dirname(zp), exist_ok=True)
        with zipfile.ZipFile(zp, 'w') as z:
            # zip_ok=False: members exist but carry no ddrcap ports, so the
            # live verify_zip must reject them.
            body = 'dut_ddrcap_i' if zip_ok else '// nothing'
            for n in names:
                z.writestr(f'hdl/{n}', body)
    return root

UNPREFIXED = [sorted(n)[0] for _, n in inj.EXPECTED_LOOSE_GROUPS]
PREFIXED = [sorted(n)[-1] for _, n in inj.EXPECTED_LOOSE_GROUPS]

CASES = [
    ("complete loose tree, no zips, not a build tree", dict(names=UNPREFIXED), 0),
    ("prefixed build-tree names (round 1 false-FAILed this)", dict(names=PREFIXED), 0),
    ("THE RECURRING BUG: complete loose tree + 2 zips that do NOT verify",
     dict(names=UNPREFIXED, zips=2, zip_ok=False), 1),
    ("build tree (.xpr) with zero zips", dict(names=UNPREFIXED, build_marker='xpr'), 1),
    ("build tree (ipcore/) with zero zips", dict(names=UNPREFIXED, build_marker='ipcore'), 1),
    ("empty tree", dict(names=[]), 1),
    ("partial loose tree", dict(names=UNPREFIXED[:3]), 1),
    ("REAL-TREE SHAPE: unrelated cores' component.xml alongside (T4 found this)",
     dict(names=UNPREFIXED, sibling_ips=5), 0),
    ("unrelated component.xml + non-verifying zips still fails",
     dict(names=UNPREFIXED, sibling_ips=5, zips=2, zip_ok=False), 1),
]

fails = 0
for label, kw, want in CASES:
    d = tempfile.mkdtemp(prefix='ddrcap_t_')
    try:
        tree(d, **kw)
        # Flush around the fd swap: without it Python's buffered stdout is
        # emptied into /dev/null after the swap and this test's own PASS lines
        # disappear -- a test whose results can vanish is not a test.
        sys.stdout.flush()
        out = os.dup(1); devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        try:
            rc = inj.main(d)
        finally:
            sys.stdout.flush()
            os.dup2(out, 1); os.close(out); os.close(devnull)
        ok = (rc == want)
        fails += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] rc={rc} want={want}  {label}")
    finally:
        shutil.rmtree(d, ignore_errors=True)

print(f"\nTEST_DDRCAP_INJECT {'ALL PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
