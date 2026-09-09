import os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback')
sys.path.insert(0, os.path.join(ROOT, 'two_jup', 'skidfix'))
import ddrcap2_inject as inj

def _copy():
    d = tempfile.mkdtemp(prefix='ddrcap2_')
    for f in os.listdir(SRC):
        if f.endswith('.v'):
            shutil.copy(os.path.join(SRC, f), d)
    return d

def test_interpolation_control_exposes_countreg():
    d = _copy(); p = os.path.join(d, 'Interpolation_Control.v')
    assert inj.patch_interpolation_control(p) == 'patched'
    s = open(p).read()
    assert '           countRegOut);' in s and 'output  signed [10:0] countRegOut;' in s
    assert 'assign countRegOut = countReg;' in s
    assert inj.patch_interpolation_control(p) == 'already'

def test_symbol_synchronizer_exposes_dc_ports():
    d = _copy()
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    p = os.path.join(d, 'Symbol_Synchronizer.v')
    assert inj.patch_symbol_synchronizer(p) == 'patched'
    s = open(p).read()
    for n in ('dc_countreg', 'dc_mu', 'dc_underflow', 'dc_interp_re', 'dc_interp_im'):
        assert s.count(n) >= 3, n            # port list + decl + assign
    assert '.countRegOut(Interpolation_Control_countRegOut)' in s
    assert 'assign dc_interp_re = Delay8_out1_re;' in s

def test_preamble_detector_exposes_dc_ports():
    d = _copy(); p = os.path.join(d, 'Preamble_Detector.v')
    assert inj.patch_preamble_detector(p) == 'patched'
    s = open(p).read()
    assert 'assign dc_toff = Peak_Search_timingOffset;' in s
    assert 'assign dc_corr = Correlator_dataOut;' in s
    assert 'output  [13:0] dc_toff;' in s

def test_lint_after_source_patches():
    d = _copy()
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    inj.patch_symbol_synchronizer(os.path.join(d, 'Symbol_Synchronizer.v'))
    inj.patch_preamble_detector(os.path.join(d, 'Preamble_Detector.v'))
    r = subprocess.run(['verilator', '--lint-only', '-Wno-fatal', '-Wno-lint', '--top-module',
                        'Frequency_and_Time_Synchronizer', '-y', d,
                        os.path.join(d, 'Frequency_and_Time_Synchronizer.v')],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-2000:]

def _full(d):
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    inj.patch_symbol_synchronizer(os.path.join(d, 'Symbol_Synchronizer.v'))
    inj.patch_preamble_detector(os.path.join(d, 'Preamble_Detector.v'))
    inj.patch_fts(os.path.join(d, 'Frequency_and_Time_Synchronizer.v'))
    inj.patch_qpsk_rx(os.path.join(d, 'QPSK_Rx.v'))
    inj.patch_receiver(os.path.join(d, 'Receiver.v'))
    inj.patch_composite(os.path.join(d, 'TxRxComposite.v'))

def test_full_tree_lints_and_is_idempotent():
    d = _copy(); _full(d)
    s = open(os.path.join(d, 'TxRxComposite.v')).read()
    assert 'ddrcap2_slot_r' in s and "(ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[31:16]" in s
    assert s.count("ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12") == 3
    assert 'assign ddrcap_mark_demod = {ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]};' in s
    assert "16'h7FFF" not in s.split('ddrcap2_slot_r')[-1]    # old full-word marker assigns gone
    r = subprocess.run(['verilator', '--lint-only', '-Wno-fatal', '-Wno-lint', '--top-module', 'TxRxComposite',
                        '-y', d, os.path.join(d, 'TxRxComposite.v')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]
    # idempotent
    assert inj.patch_composite(os.path.join(d, 'TxRxComposite.v')) == 'already'
    assert inj.patch_qpsk_rx(os.path.join(d, 'QPSK_Rx.v')) == 'already'

def test_main_on_sim_tree_reports_success():
    d = _copy()
    assert inj.main(d) == 0
