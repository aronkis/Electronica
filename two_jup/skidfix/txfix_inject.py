#!/usr/bin/env python3
"""txfix_inject.py <netlist_dir> F1|F2|F3 [--margin] -- TX stall fix injector
(plan /home/tcollins/.claude/plans/happy-bubbling-owl.md, section "Fix variants").

Netlist patches (by design: regenerating from Simulink would overwrite them) for the
120.2 s transmit stall inside QPSK_Tx/Bit_Packetizer:

  F1  Data_Bits_FIFO.v -- the pop-enable latch
      (Unit_Delay_Enabled_Resettable_Synchronous_out1, :272-289) is cleared on ANY
      enb_1_2_0 tick where Compare_To_Constant1_out1 (Delay3_out1 == 2'b00 -> the
      delayed frameCount reads 0, :270) is high, i.e. mid-frame.  Move the clear
      inside the Compare_To_Constant3_out1 (sampleCount == 0, :220) branch so the
      latch can only change at a frame boundary.
      Nominal identity that makes this a no-op on non-defect ticks:
        Compare_To_Constant2_out1 = Delay3_out1 != 2'b00   (:248)
        Compare_To_Constant1_out1 = Delay3_out1 == 2'b00   (:270)
      => Compare_To_Constant2_out1 === ~Compare_To_Constant1_out1, so on a
      sampleCount==0 tick the patched nest assigns exactly what the original did.

  F2  F1 + RAM_Frame_Status_Indicator.v -- saturating frameCount (no 3->0 wrap and
      no 0->3 underflow).  Simultaneous push-wrap and pop-wrap remain a no-op, which
      is what the original two unguarded +/-1 statements netted to.

  F3  F2 + Bit_Packetizer.v (dataReady must be gated by ~fullRAM so a frozen pace
      toggle can no longer mean "ready") + MATLAB_Function1.v (saturating uint16
      occupancy count -- no 65535->0 wrap, no 0->65535 underflow).
      --margin (= F3b) additionally lowers the fullRAM threshold from 49279 to 49263
      (16 slots of headroom for the back-pressure latency).

Idempotent: every patcher returns 'already' when its TXFIX_F* marker is present.
Loose .v files are patched in place (basename, or the TxRxCompo_ip_src_ prefixed
name used inside the Vivado IP kit); TxRxCompo_ip_v1_0.zip members are patched and
re-verified exactly as ddrcap2_inject.py does.
"""
import sys, os, io, zipfile


def _sub(s, old, new, what):
    """Replace `old` by `new`, asserting the anchor occurs EXACTLY once."""
    n = s.count(old)
    assert n == 1, f"anchor for {what} occurs {n} times (want exactly 1): {old.strip()[:70]!r}"
    return s.replace(old, new, 1)


# ---------------------------------------------------------------- F1: Data_Bits_FIFO.v
DBF_OLD = """        if (enb_1_2_0) begin
          if (Compare_To_Constant1_out1 == 1'b1) begin
            Unit_Delay_Enabled_Resettable_Synchronous_out1 <= 1'b0;
          end
          else begin
            if (Compare_To_Constant3_out1) begin
              Unit_Delay_Enabled_Resettable_Synchronous_out1 <= Compare_To_Constant2_out1;
            end
          end
        end
"""

# NOTE on the shape of DBF_NEW's inner if/else, for anyone tempted to "simplify" it:
# both arms assign the SAME value.  Compare_To_Constant2_out1 is asserted just above to be
# `Delay3_out1 != 2'b00` while Compare_To_Constant1_out1 is `Delay3_out1 == 2'b00`, so
# Compare_To_Constant2_out1 === ~Compare_To_Constant1_out1 and the whole inner if/else is
# equivalent to the single statement `... <= Compare_To_Constant2_out1;`.  The two-branch
# shape is kept DELIBERATELY: it preserves the original netlist's statement structure line
# for line, so the F1 diff reads as "wrap the existing body in the frame-boundary guard" and
# nothing else, which is what makes the patch reviewable against the generated source.
#
# DO NOT EDIT THE PATCH TEXT BELOW.  The flashed image f6a8c3ea119c was built from exactly
# these bytes; changing them (even a comment) breaks provenance with the verified bitstream.
DBF_NEW = """        if (enb_1_2_0) begin
          // TXFIX_F1: the pop-enable latch may only change at a frame boundary
          // (Compare_To_Constant3_out1 = sampleCount==0).  The original cleared it on
          // ANY tick with Compare_To_Constant1_out1 (frameCount==0), aborting pops
          // mid-frame -- the 120.2 s transmit stall.  Nominal behaviour is unchanged
          // because Compare_To_Constant2_out1 === ~Compare_To_Constant1_out1 (both
          // compare Delay3_out1 against 2'b00).
          if (Compare_To_Constant3_out1) begin
            if (Compare_To_Constant1_out1 == 1'b1) begin
              Unit_Delay_Enabled_Resettable_Synchronous_out1 <= 1'b0;
            end
            else begin
              Unit_Delay_Enabled_Resettable_Synchronous_out1 <= Compare_To_Constant2_out1;
            end
          end
        end
"""


def patch_data_bits_fifo(path, margin=False):
    s = open(path).read()
    if 'TXFIX_F1' in s:
        return 'already'
    # guard: the two compares this fix relies on must be the expected polarity pair
    assert "assign Compare_To_Constant1_out1 = Delay3_out1 == 2'b00;" in s, \
        f'{path}: Compare_To_Constant1_out1 polarity anchor missing'
    assert "assign Compare_To_Constant2_out1 = Delay3_out1 != 2'b00;" in s, \
        f'{path}: Compare_To_Constant2_out1 polarity anchor missing'
    s = _sub(s, DBF_OLD, DBF_NEW, 'F1 pop-enable latch clear')
    open(path, 'w').write(s)
    return 'patched'


# ------------------------------------------- F2: RAM_Frame_Status_Indicator.v
FSI_DECL_OLD = "  reg [1:0] frameCount_temp;  // ufix2\n"
FSI_DECL_NEW = ("  reg [1:0] frameCount_temp;  // ufix2\n"
                "  reg fcInc;  // TXFIX_F2\n"
                "  reg fcDec;  // TXFIX_F2\n")

FSI_BODY_OLD = """    if ((pushCount == 15'b110000000111111) && push) begin
      frameCount_temp = frameCount + 2'b01;
    end
    if ((popCount == 15'b110000000111111) && pop) begin
      frameCount_temp = frameCount_temp - 2'b01;
    end
"""

FSI_BODY_NEW = """    // TXFIX_F2: saturating frameCount -- the original +1/-1 pair wrapped 3->0 on a
    // push-wrap and underflowed 0->3 on a pop-wrap.  A 3->0 wrap makes the
    // Data_Bits_FIFO pop-enable latch read frameCount==0 and abort pops.
    // Simultaneous push-wrap and pop-wrap stays a no-op, exactly as the original
    // (+1 then -1) netted to.
    fcInc = (pushCount == 15'b110000000111111) && push;
    fcDec = (popCount == 15'b110000000111111) && pop;
    if (fcInc && !fcDec && (frameCount != 2'b11)) begin
      frameCount_temp = frameCount + 2'b01;
    end
    else if (fcDec && !fcInc && (frameCount != 2'b00)) begin
      frameCount_temp = frameCount - 2'b01;
    end
"""


def patch_ram_frame_status_indicator(path, margin=False):
    s = open(path).read()
    if 'TXFIX_F2' in s:
        return 'already'
    s = _sub(s, FSI_DECL_OLD, FSI_DECL_NEW, 'F2 fcInc/fcDec declarations')
    s = _sub(s, FSI_BODY_OLD, FSI_BODY_NEW, 'F2 frameCount inc/dec pair')
    open(path, 'w').write(s)
    return 'patched'


# ------------------------------------------- F3: Bit_Packetizer.v
BP_OLD = "  assign dataReady = DataReadyPaceCmp_out1;\n"
BP_NEW = ("  // TXFIX_F3: gate dataReady with ~fullRAM (Logical_Operator2_out1, :144).  The\n"
          "  // pace counter freezes while fullRAM is high, so DataReadyPaceCmp_out1 can stick\n"
          "  // at 1 and keep the producer pushing into a full RAM.  Pausing the producer is\n"
          "  // lossless: Input_Data/MATLAB_Function_block3 hold indexCount when enable is low.\n"
          "  assign dataReady = DataReadyPaceCmp_out1 & Logical_Operator2_out1;\n")


def patch_bit_packetizer(path, margin=False):
    s = open(path).read()
    if 'TXFIX_F3' in s:
        return 'already'
    assert "assign Logical_Operator2_out1 =  ~ Data_Bits_FIFO_fullRAM;\n" in s, \
        f'{path}: Logical_Operator2_out1 = ~fullRAM anchor missing'
    s = _sub(s, BP_OLD, BP_NEW, 'F3 dataReady gate')
    open(path, 'w').write(s)
    return 'patched'


# ------------------------------------------- F3: MATLAB_Function1.v
MF1_DECL_OLD = "  reg [15:0] count_temp;  // ufix16\n"
MF1_DECL_NEW = ("  reg [15:0] count_temp;  // ufix16\n"
                "  reg cntInc;  // TXFIX_F3\n"
                "  reg cntDec;  // TXFIX_F3\n")

MF1_BODY_OLD = """    if (wr) begin
      count_temp = count + 16'b0000000000000001;
    end
    if (rd) begin
      count_temp = count_temp - 16'b0000000000000001;
    end
"""

MF1_BODY_NEW = """    // TXFIX_F3: saturating occupancy count.  The original wrapped at 65536 (and
    // underflowed at 0), which is how the fullRAM back-pressure runaway ends: the
    // producer keeps pushing until the uint16 count wraps and full_1 drops again.
    // Simultaneous wr+rd stays a no-op, exactly as the original (+1 then -1) netted.
    cntInc = wr;
    cntDec = rd;
    if (cntInc && !cntDec && (count != 16'b1111111111111111)) begin
      count_temp = count + 16'b0000000000000001;
    end
    else if (cntDec && !cntInc && (count != 16'b0000000000000000)) begin
      count_temp = count - 16'b0000000000000001;
    end
"""

MF1_THRESH_OLD = "    full_1 = count_temp > 16'b1100000001111111;\n"
MF1_THRESH_NEW = ("    // TXFIX_F3B: fullRAM threshold lowered 49279 -> 49263 (16 slots of margin for\n"
                  "    // the back-pressure latency).\n"
                  "    full_1 = count_temp > 16'b1100000001101111;\n")


def patch_matlab_function1(path, margin=False):
    """F3 (saturating count) and, with margin=True, F3b (lower fullRAM threshold).

    The two markers are distinct on purpose.  A plain `TXFIX_F3 in s` idempotence
    guard would make `--margin` a SILENT no-op on a tree that had already been
    F3-patched without it -- main() would still print variant=F3b and verify_zip
    would still pass, while the threshold stayed at 49279.  So:
      margin=True  on an F3-only tree  -> re-patch just the threshold line (F3->F3b).
      margin=False on an F3b tree      -> refuse; downgrading would need the reverse
                                          substitution and is never what the caller
                                          meant (they asked for less margin than the
                                          tree already carries).
    Note 'TXFIX_F3' is a prefix of 'TXFIX_F3B', so F3b is always tested first.
    """
    s = open(path).read()
    has_f3b = 'TXFIX_F3B' in s
    has_f3 = 'TXFIX_F3' in s          # true for an F3b tree too
    if not margin:
        assert not has_f3b, (f'{path}: already patched to F3b (TXFIX_F3B present); '
                             'refusing to report it as plain F3 -- re-inject from a clean tree')
        if has_f3:
            return 'already'
    else:
        if has_f3b:
            return 'already'
        if has_f3:
            # F3 body already in place; only the threshold is missing
            s = _sub(s, MF1_THRESH_OLD, MF1_THRESH_NEW, 'F3b fullRAM threshold margin (upgrade)')
            open(path, 'w').write(s)
            return 'patched'
    s = _sub(s, MF1_DECL_OLD, MF1_DECL_NEW, 'F3 cntInc/cntDec declarations')
    s = _sub(s, MF1_BODY_OLD, MF1_BODY_NEW, 'F3 count inc/dec pair')
    if margin:
        s = _sub(s, MF1_THRESH_OLD, MF1_THRESH_NEW, 'F3b fullRAM threshold margin')
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- dispatch tables
PATCHERS = {
    'Data_Bits_FIFO.v': patch_data_bits_fifo,
    'RAM_Frame_Status_Indicator.v': patch_ram_frame_status_indicator,
    'Bit_Packetizer.v': patch_bit_packetizer,
    'MATLAB_Function1.v': patch_matlab_function1,
}

# cumulative: F2 = F1 + ..., F3 = F2 + ...
VARIANT_FILES = {
    'F1': ['Data_Bits_FIFO.v'],
    'F2': ['Data_Bits_FIFO.v', 'RAM_Frame_Status_Indicator.v'],
    'F3': ['Data_Bits_FIFO.v', 'RAM_Frame_Status_Indicator.v',
           'Bit_Packetizer.v', 'MATLAB_Function1.v'],
}

# marker each patched file must carry afterwards (zip verification)
FILE_MARKER = {
    'Data_Bits_FIFO.v': 'TXFIX_F1',
    'RAM_Frame_Status_Indicator.v': 'TXFIX_F2',
    'Bit_Packetizer.v': 'TXFIX_F3',
    'MATLAB_Function1.v': 'TXFIX_F3',
}

SRC_PREFIX = 'TxRxCompo_ip_src_'


def logical_name(base):
    """Strip the Vivado IP kit's TxRxCompo_ip_src_ prefix, if present."""
    return base[len(SRC_PREFIX):] if base.startswith(SRC_PREFIX) else base


def _patcher_for(base, variant):
    """Return the patcher for this file basename under `variant`, else None.

    Dispatch is by exact (optionally TxRxCompo_ip_src_-prefixed) basename, so a
    MATLAB_Function1.v from another subsystem could only ever be reached if it were
    named MATLAB_Function1.v; the anchors then assert exactly-one occurrence and the
    patch fails loudly rather than silently editing the wrong module.
    """
    ln = logical_name(base)
    if ln in PATCHERS and ln in VARIANT_FILES[variant]:
        return PATCHERS[ln]
    return None


def patch_zip(zpath, variant, margin=False):
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r'); entries = []; n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        base = os.path.basename(item.filename)
        fn = _patcher_for(base, variant)
        if fn is not None:
            tmp = zpath + '.txfix_tmp'; os.makedirs(tmp, exist_ok=True)
            tp = os.path.join(tmp, base)
            open(tp, 'wb').write(data); status = fn(tp, margin); data = open(tp, 'rb').read()
            os.remove(tp); os.rmdir(tmp); n += 1
            print(f"    zip member {base:50s} {status:8s}")
        entries.append((item, data))
    zin.close()
    out = io.BytesIO(); zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close(); open(zpath, 'wb').write(out.getvalue())
    return n


def verify_zip(zpath, variant, margin=False):
    expected = {SRC_PREFIX + f: FILE_MARKER[f] for f in VARIANT_FILES[variant]}
    if margin and 'MATLAB_Function1.v' in VARIANT_FILES[variant]:
        # --margin must be verified against its OWN marker, otherwise an F3-only tree
        # would verify clean while being reported as F3b.
        expected[SRC_PREFIX + 'MATLAB_Function1.v'] = 'TXFIX_F3B'
    zin = zipfile.ZipFile(zpath, 'r'); found = {}
    for item in zin.infolist():
        b = os.path.basename(item.filename)
        if b in expected:
            found[b] = zin.read(item.filename).decode()
    zin.close()
    ok = True
    for b, marker in expected.items():
        if b not in found or marker not in found[b]:
            print(f"    VERIFY_FAIL {zpath}: {b} missing or lacks {marker}"); ok = False
    return ok


def main(d, variant, margin=False):
    if variant not in VARIANT_FILES:
        print(f"TXFIX_INJECT_FAIL unknown variant {variant!r} (want F1|F2|F3)")
        return 2
    want = VARIANT_FILES[variant]
    found = set(); nloose = 0
    for root, _, files in os.walk(d):
        if root.endswith('.txfix_tmp'):
            continue
        for f in sorted(files):
            fn = _patcher_for(f, variant)
            if fn is None:
                continue
            p = os.path.join(root, f)
            print(f"  {f:45s} {fn.__name__:34s} -> {fn(p, margin):8s} {p}")
            found.add(logical_name(f)); nloose += 1
    nz = nv = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                zp = os.path.join(root, f); nz += 1
                print(f"  zip {zp}"); patch_zip(zp, variant, margin)
                if verify_zip(zp, variant, margin):
                    nv += 1; print(f"    VERIFY_OK {zp}")
    missing = sorted(set(want) - found)
    build_tree = any(os.path.basename(r) in ('ipcore', 'vivado_ip_prj') or any(x.endswith('.xpr') for x in fs)
                     for r, _, fs in os.walk(d))
    print(f"TXFIX_INJECT variant={variant}{'b' if margin else ''} loose={nloose} "
          f"missing={missing} zips={nz} zips_verified={nv}")
    # A Vivado build kit holds the SAME set of loose copies in hdlsrc/, ipcore/ and
    # vivado_ip_prj/ipcore/, so nloose is always a whole multiple of the variant's
    # file count.  A remainder means one tree is missing a file the others have.
    assert nloose % len(want) == 0, (
        f"TXFIX_INJECT_FAIL uneven loose copies: nloose={nloose} is not a multiple of "
        f"len(want)={len(want)} for {variant} -- a netlist copy is missing a file")
    if missing or (build_tree and nz == 0) or (nz and nv != nz) or (nz not in (0, 2)):
        print("TXFIX_INJECT_FAIL"); return 1
    return 0


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--margin']
    if len(args) != 2:
        print("usage: txfix_inject.py <netlist_dir> F1|F2|F3 [--margin]")
        sys.exit(2)
    sys.exit(main(args[0], args[1], '--margin' in sys.argv[1:]))
