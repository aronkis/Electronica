"""Unit tests for two_jup/skidfix/txfix_inject.py (TXFIX T0a).

Modelled on test_ddrcap2_inject.py: patch + idempotency per variant, anchor
uniqueness, loud failure when an anchor is missing, cumulative markers, main()
success line, a synthetic two-member zip (no zip exists in the sim tree), and a
Verilator lint per variant.
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback')
sys.path.insert(0, os.path.join(ROOT, 'two_jup', 'skidfix'))
import txfix_inject as inj  # noqa: E402

TOUCHED = ['Data_Bits_FIFO.v', 'RAM_Frame_Status_Indicator.v',
           'Bit_Packetizer.v', 'MATLAB_Function1.v']


def _copy():
    d = tempfile.mkdtemp(prefix='txfix_')
    for f in os.listdir(SRC):
        if f.endswith('.v'):
            shutil.copy(os.path.join(SRC, f), d)
    return d


def _read(d, f):
    return open(os.path.join(d, f)).read()


# ------------------------------------------------------------------ F1
def test_f1_moves_the_clear_into_the_frame_boundary_branch():
    d = _copy()
    p = os.path.join(d, 'Data_Bits_FIFO.v')
    assert inj.patch_data_bits_fifo(p) == 'patched'
    s = open(p).read()
    assert 'TXFIX_F1' in s
    # the clear is now nested INSIDE the sampleCount==0 branch
    i_sc = s.index('if (Compare_To_Constant3_out1) begin')
    i_clr = s.index("if (Compare_To_Constant1_out1 == 1'b1) begin")
    assert i_sc < i_clr, 'the frameCount==0 clear must be inside the sampleCount==0 branch'
    # the else arm still reloads the latch from the complementary compare
    assert 'Unit_Delay_Enabled_Resettable_Synchronous_out1 <= Compare_To_Constant2_out1;' in s
    assert inj.patch_data_bits_fifo(p) == 'already'


def test_f1_relies_on_the_verified_compare_polarity_pair():
    """Compare_To_Constant2_out1 === ~Compare_To_Constant1_out1 (:248 vs :270)."""
    s = _read(SRC, 'Data_Bits_FIFO.v')
    assert "assign Compare_To_Constant1_out1 = Delay3_out1 == 2'b00;" in s
    assert "assign Compare_To_Constant2_out1 = Delay3_out1 != 2'b00;" in s


# ------------------------------------------------------------------ F2
def test_f2_saturates_framecount():
    d = _copy()
    p = os.path.join(d, 'RAM_Frame_Status_Indicator.v')
    assert inj.patch_ram_frame_status_indicator(p) == 'patched'
    s = open(p).read()
    assert 'reg fcInc;' in s and 'reg fcDec;' in s
    assert "if (fcInc && !fcDec && (frameCount != 2'b11)) begin" in s
    assert "else if (fcDec && !fcInc && (frameCount != 2'b00)) begin" in s
    assert 'frameCount_temp = frameCount_temp - 2\'b01;' not in s   # old unguarded dec gone
    assert inj.patch_ram_frame_status_indicator(p) == 'already'


# ------------------------------------------------------------------ F3
def test_f3_gates_dataready_and_saturates_count():
    d = _copy()
    bp = os.path.join(d, 'Bit_Packetizer.v')
    mf = os.path.join(d, 'MATLAB_Function1.v')
    assert inj.patch_bit_packetizer(bp) == 'patched'
    assert inj.patch_matlab_function1(mf) == 'patched'
    s = open(bp).read()
    assert 'assign dataReady = DataReadyPaceCmp_out1 & Logical_Operator2_out1;' in s
    assert 'assign dataReady = DataReadyPaceCmp_out1;' not in s
    m = open(mf).read()
    assert 'reg cntInc;' in m and 'reg cntDec;' in m
    assert "if (cntInc && !cntDec && (count != 16'b1111111111111111)) begin" in m
    assert "full_1 = count_temp > 16'b1100000001111111;" in m       # threshold untouched w/o --margin
    assert inj.patch_bit_packetizer(bp) == 'already'
    assert inj.patch_matlab_function1(mf) == 'already'


def test_f3b_margin_lowers_the_full_threshold():
    d = _copy()
    mf = os.path.join(d, 'MATLAB_Function1.v')
    assert inj.patch_matlab_function1(mf, margin=True) == 'patched'
    m = open(mf).read()
    assert "full_1 = count_temp > 16'b1100000001101111;" in m
    assert "16'b1100000001111111" not in m
    assert int('1100000001101111', 2) == 49263


# ------------------------------------------------------------------ anchors
def test_sub_requires_a_unique_anchor():
    with pytest.raises(AssertionError) as e:
        inj._sub('aXbXc', 'X', 'Y', 'dup anchor')
    assert 'occurs 2 times' in str(e.value)


def test_anchor_missing_fails_loudly():
    d = _copy()
    p = os.path.join(d, 'Data_Bits_FIFO.v')
    s = open(p).read().replace("Unit_Delay_Enabled_Resettable_Synchronous_out1 <= 1'b0;",
                               "Unit_Delay_Enabled_Resettable_Synchronous_out1 <= 1'b0;  // moved")
    open(p, 'w').write(s)
    with pytest.raises(AssertionError):
        inj.patch_data_bits_fifo(p)
    # and the file was NOT rewritten
    assert 'TXFIX_F1' not in open(p).read()


def test_patcher_dispatch_is_variant_scoped_and_prefix_aware():
    assert inj._patcher_for('Data_Bits_FIFO.v', 'F1') is inj.patch_data_bits_fifo
    assert inj._patcher_for('TxRxCompo_ip_src_Data_Bits_FIFO.v', 'F1') is inj.patch_data_bits_fifo
    # F1 must not reach the F2/F3 files
    assert inj._patcher_for('RAM_Frame_Status_Indicator.v', 'F1') is None
    assert inj._patcher_for('MATLAB_Function1.v', 'F2') is None
    assert inj._patcher_for('MATLAB_Function1.v', 'F3') is inj.patch_matlab_function1
    # sibling MATLAB_Function* modules are never dispatched to
    for other in ('MATLAB_Function.v', 'MATLAB_Function_block2.v',
                  'TxRxCompo_ip_src_MATLAB_Function_block3.v'):
        assert inj._patcher_for(other, 'F3') is None


def test_wrong_file_content_fails_rather_than_silently_patching():
    """If a differently-sourced MATLAB_Function1.v ever appeared, the anchors miss."""
    d = _copy()
    p = os.path.join(d, 'MATLAB_Function1.v')
    shutil.copy(os.path.join(SRC, 'MATLAB_Function_block2.v'), p)
    with pytest.raises(AssertionError):
        inj.patch_matlab_function1(p)


# ------------------------------------------------------------------ cumulative markers
@pytest.mark.parametrize('variant,markers', [
    ('F1', {'Data_Bits_FIFO.v': 'TXFIX_F1'}),
    ('F2', {'Data_Bits_FIFO.v': 'TXFIX_F1', 'RAM_Frame_Status_Indicator.v': 'TXFIX_F2'}),
    ('F3', {'Data_Bits_FIFO.v': 'TXFIX_F1', 'RAM_Frame_Status_Indicator.v': 'TXFIX_F2',
            'Bit_Packetizer.v': 'TXFIX_F3', 'MATLAB_Function1.v': 'TXFIX_F3'}),
])
def test_main_is_cumulative_and_reports_success(variant, markers, capsys):
    d = _copy()
    assert inj.main(d, variant) == 0
    out = capsys.readouterr().out
    assert f'TXFIX_INJECT variant={variant} loose={len(markers)} missing=[] zips=0 zips_verified=0' in out
    assert 'TXFIX_INJECT_FAIL' not in out
    for f, marker in markers.items():
        assert marker in _read(d, f), f'{f} lacks {marker}'
    # files outside the variant are untouched
    for f in TOUCHED:
        if f not in markers:
            assert _read(d, f) == _read(SRC, f), f'{f} must be untouched by {variant}'
    # idempotent at the main() level
    assert inj.main(d, variant) == 0


def test_main_rejects_an_unknown_variant(capsys):
    d = _copy()
    assert inj.main(d, 'F9') == 2
    assert 'TXFIX_INJECT_FAIL' in capsys.readouterr().out


# ------------------------------------------------------------------ zip round-trip
def _make_zip(path, variant):
    """Two-member zip using the TxRxCompo_ip_src_ member names the kit uses."""
    names = ['TxRxCompo_ip_src_' + f for f in inj.VARIANT_FILES[variant]]
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for n in names:
            z.writestr('hdl/' + n, open(os.path.join(SRC, n.replace('TxRxCompo_ip_src_', ''))).read())
        z.writestr('hdl/TxRxCompo_ip_src_MATLAB_Function_block2.v',
                   open(os.path.join(SRC, 'MATLAB_Function_block2.v')).read())
    return path


def test_synthetic_zip_patch_and_verify():
    d = tempfile.mkdtemp(prefix='txfixzip_')
    zp = _make_zip(os.path.join(d, 'TxRxCompo_ip_v1_0.zip'), 'F2')
    assert inj.patch_zip(zp, 'F2') == 2
    assert inj.verify_zip(zp, 'F2') is True
    with zipfile.ZipFile(zp) as z:
        assert 'TXFIX_F1' in z.read('hdl/TxRxCompo_ip_src_Data_Bits_FIFO.v').decode()
        assert 'TXFIX_F2' in z.read('hdl/TxRxCompo_ip_src_RAM_Frame_Status_Indicator.v').decode()
        # the unrelated member is byte-identical and still present
        assert z.read('hdl/TxRxCompo_ip_src_MATLAB_Function_block2.v').decode() == \
            _read(SRC, 'MATLAB_Function_block2.v')
    # idempotent
    assert inj.patch_zip(zp, 'F2') == 2
    assert inj.verify_zip(zp, 'F2') is True


def test_verify_zip_fails_on_an_unpatched_zip(capsys):
    d = tempfile.mkdtemp(prefix='txfixzip_')
    zp = _make_zip(os.path.join(d, 'TxRxCompo_ip_v1_0.zip'), 'F3')
    assert inj.verify_zip(zp, 'F3') is False
    assert 'VERIFY_FAIL' in capsys.readouterr().out


# ------------------------------------------------------------------ lint
LINT_TOPS = {
    'Data_Bits_FIFO.v': 'Data_Bits_FIFO',
    'RAM_Frame_Status_Indicator.v': 'RAM_Frame_Status_Indicator',
    'Bit_Packetizer.v': 'Bit_Packetizer',
    'MATLAB_Function1.v': 'MATLAB_Function1',
}


@pytest.mark.parametrize('variant', ['F1', 'F2', 'F3'])
def test_lint_per_variant(variant):
    d = _copy()
    assert inj.main(d, variant) == 0
    # lenient whole-subsystem lint
    r = subprocess.run(['verilator', '--lint-only', '-Wno-fatal', '-Wno-lint',
                        '--top-module', 'Transmitter', '-y', d,
                        os.path.join(d, 'Transmitter.v')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]
    # strict lint on each touched file
    for f in inj.VARIANT_FILES[variant]:
        r = subprocess.run(['verilator', '--lint-only', '-Wall', '-Wno-DECLFILENAME',
                            '-Wno-UNUSEDSIGNAL', '-Wno-UNUSEDPARAM', '-Wno-VARHIDDEN',
                            '--top-module', LINT_TOPS[f], '-y', d, os.path.join(d, f)],
                           capture_output=True, text=True)
        assert r.returncode == 0, f'{f}: {r.stderr[-3000:]}'
        for bad in ('LATCH', 'ALWCOMBORDER', 'CASEINCOMPLETE'):
            assert bad not in r.stderr, f'{f}: {bad} in {r.stderr[-2000:]}'


def test_lint_margin_variant():
    d = _copy()
    assert inj.main(d, 'F3', margin=True) == 0
    r = subprocess.run(['verilator', '--lint-only', '-Wall', '-Wno-DECLFILENAME',
                        '--top-module', 'MATLAB_Function1', '-y', d,
                        os.path.join(d, 'MATLAB_Function1.v')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]


# ------------------------------------------------------------------ F3 -> F3b upgrade
# Regression for the review finding: a plain `TXFIX_F3 in s` idempotence guard made
# --margin a SILENT no-op on an already-F3-patched tree, while main() still printed
# variant=F3b and verify_zip still passed.

def test_f3_then_margin_upgrades_the_threshold():
    d = _copy()
    mf = os.path.join(d, 'MATLAB_Function1.v')
    assert inj.patch_matlab_function1(mf) == 'patched'
    assert "full_1 = count_temp > 16'b1100000001111111;" in open(mf).read()
    # second call WITH margin must actually patch, not report 'already'
    assert inj.patch_matlab_function1(mf, margin=True) == 'patched'
    m = open(mf).read()
    assert "full_1 = count_temp > 16'b1100000001101111;" in m
    assert "16'b1100000001111111" not in m
    assert 'TXFIX_F3B' in m
    # and now it IS idempotent
    assert inj.patch_matlab_function1(mf, margin=True) == 'already'


def test_main_f3_then_f3_margin_on_the_same_tree(capsys):
    d = _copy()
    assert inj.main(d, 'F3') == 0
    capsys.readouterr()
    assert inj.main(d, 'F3', margin=True) == 0
    out = capsys.readouterr().out
    assert 'TXFIX_INJECT variant=F3b loose=4 missing=[] zips=0 zips_verified=0' in out
    assert 'TXFIX_INJECT_FAIL' not in out
    m = _read(d, 'MATLAB_Function1.v')
    assert "full_1 = count_temp > 16'b1100000001101111;" in m, 'F3b threshold was a silent no-op'
    assert 'TXFIX_F3B' in m
    # the other three F3 files are untouched by the margin pass
    assert 'TXFIX_F1' in _read(d, 'Data_Bits_FIFO.v')
    assert 'TXFIX_F2' in _read(d, 'RAM_Frame_Status_Indicator.v')
    assert 'TXFIX_F3' in _read(d, 'Bit_Packetizer.v')


def test_plain_f3_on_an_f3b_tree_is_refused():
    d = _copy()
    mf = os.path.join(d, 'MATLAB_Function1.v')
    assert inj.patch_matlab_function1(mf, margin=True) == 'patched'
    with pytest.raises(AssertionError) as e:
        inj.patch_matlab_function1(mf)
    assert 'TXFIX_F3B' in str(e.value)


def test_verify_zip_margin_requires_the_f3b_marker(capsys):
    d = tempfile.mkdtemp(prefix='txfixzip_')
    zp = _make_zip(os.path.join(d, 'TxRxCompo_ip_v1_0.zip'), 'F3')
    inj.patch_zip(zp, 'F3')                      # F3 without margin
    assert inj.verify_zip(zp, 'F3') is True
    assert inj.verify_zip(zp, 'F3', margin=True) is False   # must not pass as F3b
    assert 'VERIFY_FAIL' in capsys.readouterr().out
    inj.patch_zip(zp, 'F3', margin=True)         # upgrade in place
    assert inj.verify_zip(zp, 'F3', margin=True) is True


# ------------------------------------------------------------------ uneven loose copies
def test_uneven_loose_copies_fail():
    """A Vivado kit holds the same file set in three trees; a remainder = a missing copy."""
    d = _copy()
    sub = os.path.join(d, 'ipcore_partial')
    os.makedirs(sub)
    shutil.copy(os.path.join(SRC, 'Data_Bits_FIFO.v'), sub)   # 3 loose files for F2's 2
    with pytest.raises(AssertionError) as e:
        inj.main(d, 'F2')
    assert 'uneven loose copies' in str(e.value)


def test_even_loose_copies_across_two_trees_pass(capsys):
    d = _copy()
    sub = os.path.join(d, 'ipcore_full')
    os.makedirs(sub)
    for f in inj.VARIANT_FILES['F2']:
        shutil.copy(os.path.join(SRC, f), sub)
    assert inj.main(d, 'F2') == 0
    assert 'TXFIX_INJECT variant=F2 loose=4 missing=[] zips=0 zips_verified=0' in capsys.readouterr().out
