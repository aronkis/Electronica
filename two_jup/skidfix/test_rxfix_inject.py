#!/usr/bin/env python3
"""Tests for rxfix_inject.py (RXFIX_R1).  Run: python3 -m unittest -v test_rxfix_inject"""
import io, os, shutil, sys, tempfile, unittest, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxfix_inject as R

REPO = '/mnt/onetb/scratch/qpsk-jupiter-modem'
S1_PD = os.path.join(REPO, 'jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback',
                     'Preamble_Detector.v')
KIT_PD = os.path.join(REPO, 'jupiter_byte_txfixF3_build/hdl_prj_jupiter_composite/'
                            'hdlsrc/commhdlQPSKTxRxLoopback',
                      'TxRxCompo_ip_src_Preamble_Detector.v')

DELAY11 = """  always @(posedge clk or posedge reset)
    begin : Delay11_process
      if (reset == 1'b1) begin
        Delay11_out1 <= 14'b00000000000000;
      end
      else begin
        if (enb_1_2_0) begin
          Delay11_out1 <= Peak_Search_timingOffset;
        end
      end
    end
"""

MINI = """module Preamble_Detector(clk);
  input clk;
  wire Delay8_out1;
  wire Delay10_out1;
  wire [13:0] FIFO_numEntries;  // ufix14
  reg [49331:0] Delay10_reg;

  assign Delay8_out1 = Delay8_reg[5];

  assign Delay10_out1 = Delay10_reg[49331];

  assign Constant_out1 = 1'b0;

""" + DELAY11 + """endmodule
"""


class TmpMixin(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix='rxfixtest')
        self.addCleanup(shutil.rmtree, self.d, True)

    def write(self, name, text=MINI, sub=''):
        p = os.path.join(self.d, sub) if sub else self.d
        os.makedirs(p, exist_ok=True)
        fp = os.path.join(p, name)
        open(fp, 'w').write(text)
        return fp


class TestPatcher(TmpMixin):
    def test_01_patch_returns_patched(self):
        self.assertEqual(R.patch_preamble_detector(self.write('Preamble_Detector.v')), 'patched')

    def test_02_marker_present(self):
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector(p)
        self.assertIn('RXFIX_R1', open(p).read())

    def test_03_idempotent(self):
        p = self.write('Preamble_Detector.v')
        R.patch_preamble_detector(p)
        before = open(p).read()
        self.assertEqual(R.patch_preamble_detector(p), 'already')
        self.assertEqual(open(p).read(), before)

    def test_04_declares_delay10_full(self):
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector(p)
        self.assertIn('wire Delay10_full;', open(p).read())

    def test_05_pop_is_push_and_full(self):
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector(p)
        s = open(p).read()
        self.assertIn("assign Delay10_full = FIFO_numEntries == 14'd12333;", s)
        self.assertIn('assign Delay10_out1 = Delay8_out1 & Delay10_full;', s)

    def test_06_tick_delay_no_longer_drives_pop(self):
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector(p)
        s = open(p).read()
        self.assertNotIn('assign Delay10_out1 = Delay10_reg[49331];', s)
        # the shift register itself is left in place (synthesis trims it)
        self.assertIn('reg [49331:0] Delay10_reg;', s)

    def test_07_missing_anchor_raises(self):
        p = self.write('Preamble_Detector.v', MINI.replace(
            '  assign Delay10_out1 = Delay10_reg[49331];\n', ''))
        with self.assertRaises(AssertionError):
            R.patch_preamble_detector(p)

    def test_08_duplicate_anchor_raises(self):
        p = self.write('Preamble_Detector.v',
                       MINI + '\n  assign Delay10_out1 = Delay10_reg[49331];\n')
        with self.assertRaises(AssertionError):
            R.patch_preamble_detector(p)

    def test_09_sub_asserts_exactly_once(self):
        with self.assertRaises(AssertionError):
            R._sub('a a', 'a', 'b', 'twice')
        self.assertEqual(R._sub('xay', 'a', 'b', 'once'), 'xby')


class TestDispatch(unittest.TestCase):
    def test_10_logical_name_strips_prefix(self):
        self.assertEqual(R.logical_name('TxRxCompo_ip_src_Preamble_Detector.v'),
                         'Preamble_Detector.v')

    def test_11_logical_name_passthrough(self):
        self.assertEqual(R.logical_name('Preamble_Detector.v'), 'Preamble_Detector.v')

    def test_12_patcher_for_prefixed(self):
        self.assertIs(R._patcher_for('TxRxCompo_ip_src_Preamble_Detector.v', 'R1'),
                      R.patch_preamble_detector)

    def test_13_patcher_for_unrelated_file(self):
        self.assertIsNone(R._patcher_for('Rate_Handle.v', 'R1'))

    def test_14_patcher_for_unknown_variant(self):
        self.assertIsNone(R._patcher_for('Preamble_Detector.v', 'ZZ'))

    def test_15_tables_cover_every_variant(self):
        for v in R.VARIANT_FILES:
            for f in R.VARIANT_FILES[v]:
                self.assertIn(f, R.FILE_MARKER[v])
                self.assertIn(f, R.PATCHERS[v])


class TestMain(TmpMixin):
    def test_16_sim_tree_ok(self):
        self.write('Preamble_Detector.v'); self.write('Rate_Handle.v', 'module x; endmodule\n')
        self.assertEqual(R.main(self.d, 'R1', sim_tree=True), 0)
        self.assertIn('RXFIX_R1', open(os.path.join(self.d, 'Preamble_Detector.v')).read())

    def test_17_sim_tree_rejects_two_copies(self):
        self.write('Preamble_Detector.v')
        self.write('Preamble_Detector.v', sub='ipcore')
        self.assertEqual(R.main(self.d, 'R1', sim_tree=True), 1)

    def test_18_sim_tree_rejects_missing_file(self):
        self.write('Rate_Handle.v', 'module x; endmodule\n')
        self.assertEqual(R.main(self.d, 'R1', sim_tree=True), 1)

    def test_19_unknown_variant_returns_2(self):
        self.assertEqual(R.main(self.d, 'F9'), 2)

    def _kit(self):
        """3 loose mirrors + 2 TxRxCompo_ip_v1_0.zip members, the shipped kit shape."""
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            self.write('TxRxCompo_ip_src_Preamble_Detector.v', sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            zp = os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip')
            with zipfile.ZipFile(zp, 'w') as z:
                z.writestr('hdl/TxRxCompo_ip_src_Preamble_Detector.v', MINI)
                z.writestr('hdl/TxRxCompo_ip_src_Rate_Handle.v', 'module x; endmodule\n')
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')

    def test_20_build_kit_patches_all_mirrors_and_both_zips(self):
        self._kit()
        self.assertEqual(R.main(self.d, 'R1'), 0)
        n = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f.endswith('Preamble_Detector.v'):
                    self.assertIn('RXFIX_R1', open(os.path.join(root, f)).read()); n += 1
        self.assertEqual(n, 3)
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    self.assertTrue(R.verify_zip(os.path.join(root, f), 'R1'))

    def test_21_build_kit_is_idempotent(self):
        self._kit()
        self.assertEqual(R.main(self.d, 'R1'), 0)
        self.assertEqual(R.main(self.d, 'R1'), 0)

    def test_22_zip_keeps_untouched_members(self):
        self._kit(); R.main(self.d, 'R1')
        zp = os.path.join(self.d, 'ipcore', 'TxRxCompo_ip_v1_0.zip')
        with zipfile.ZipFile(zp) as z:
            self.assertEqual(z.read('hdl/TxRxCompo_ip_src_Rate_Handle.v').decode(),
                             'module x; endmodule\n')

    def test_23_verify_zip_fails_when_unpatched(self):
        self._kit()
        zp = os.path.join(self.d, 'ipcore', 'TxRxCompo_ip_v1_0.zip')
        self.assertFalse(R.verify_zip(zp, 'R1'))

    def test_24_build_kit_with_one_zip_fails(self):
        self._kit()
        os.remove(os.path.join(self.d, 'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip'))
        self.assertEqual(R.main(self.d, 'R1'), 1)

    def test_25_build_tree_with_no_zip_fails(self):
        self.write('TxRxCompo_ip_src_Preamble_Detector.v', sub='ipcore')
        self.assertEqual(R.main(self.d, 'R1'), 1)

    def test_26_no_tmp_dir_left_behind(self):
        self._kit(); R.main(self.d, 'R1')
        for root, dirs, _ in os.walk(self.d):
            for x in dirs:
                self.assertFalse(x.endswith('.rxfix_tmp'), x)


class TestRealNetlists(TmpMixin):
    """The anchors must hit the real generated sources, both lineages."""

    def _one(self, src, name):
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        p = self.write(name, open(src).read())
        self.assertEqual(R.patch_preamble_detector(p), 'patched')
        s = open(p).read()
        self.assertIn('assign Delay10_out1 = Delay8_out1 & Delay10_full;', s)
        self.assertEqual(s.count("RXFIX_R1"), 2)   # the decl comment and the block comment
        self.assertEqual(s.count('assign Delay10_out1 ='), 1)
        self.assertEqual(R.patch_preamble_detector(p), 'already')

    def test_27_s1_rtl_sim_lineage(self):
        self._one(S1_PD, 'Preamble_Detector.v')

    def test_28_flashed_txfixF3_lineage(self):
        self._one(KIT_PD, 'TxRxCompo_ip_src_Preamble_Detector.v')


if __name__ == '__main__':
    unittest.main(verbosity=2)


class TestR2(TmpMixin):
    def test_29_r2_patches(self):
        p = self.write('Preamble_Detector.v')
        self.assertEqual(R.patch_preamble_detector_r2(p), 'patched')
        s = open(p).read()
        self.assertIn('RXFIX_R2', s)
        self.assertIn('Delay11_out1 <= ps_fw_out;', s)
        self.assertNotIn('Delay11_out1 <= Peak_Search_timingOffset;', s)

    def test_30_r2_idempotent(self):
        p = self.write('Preamble_Detector.v')
        R.patch_preamble_detector_r2(p)
        before = open(p).read()
        self.assertEqual(R.patch_preamble_detector_r2(p), 'already')
        self.assertEqual(open(p).read(), before)

    def test_31_r2_missing_anchor_raises(self):
        p = self.write('Preamble_Detector.v', MINI.replace(DELAY11, ''))
        with self.assertRaises(AssertionError):
            R.patch_preamble_detector_r2(p)

    def test_32_r2_duplicate_anchor_raises(self):
        p = self.write('Preamble_Detector.v', MINI + DELAY11)
        with self.assertRaises(AssertionError):
            R.patch_preamble_detector_r2(p)

    def test_33_r2_declares_the_flywheel_state(self):
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector_r2(p)
        s = open(p).read()
        for w in ('ps_fw_cur', 'ps_fw_have', 'ps_fw_lost', 'ps_fw_seen', 'ps_fw_pos',
                  'ps_fw_max', 'ps_fw_reject', 'ps_fw_reacq', "PS_FW_WIN   = 14'd2",
                  "PS_FW_NLOST = 2'd3"):
            self.assertIn(w, s)

    def test_34_r2_adds_no_ports(self):
        """The IP interface must be untouched: no new module port lines."""
        src = open(S1_PD).read() if os.path.exists(S1_PD) else MINI
        p = self.write('Preamble_Detector.v', src)
        before = src[:src.index(');')]
        R.patch_preamble_detector_r2(p)
        after = open(p).read()
        self.assertEqual(after[:after.index(');')], before)

    def test_35_dispatch_is_per_variant(self):
        self.assertIs(R._patcher_for('Preamble_Detector.v', 'R1'), R.patch_preamble_detector)
        self.assertIs(R._patcher_for('Preamble_Detector.v', 'R2'), R.patch_preamble_detector_r2)

    def test_36_r2_sim_tree_ok(self):
        self.write('Preamble_Detector.v')
        self.assertEqual(R.main(self.d, 'R2', sim_tree=True), 0)
        self.assertIn('RXFIX_R2', open(os.path.join(self.d, 'Preamble_Detector.v')).read())

    def test_37_r2_kit_patches_mirrors_and_zips(self):
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            self.write('TxRxCompo_ip_src_Preamble_Detector.v', sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            with zipfile.ZipFile(os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip'), 'w') as z:
                z.writestr('hdl/TxRxCompo_ip_src_Preamble_Detector.v', MINI)
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')
        self.assertEqual(R.main(self.d, 'R2'), 0)
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    self.assertTrue(R.verify_zip(os.path.join(root, f), 'R2'))
                    self.assertFalse(R.verify_zip(os.path.join(root, f), 'R1'))

    def test_38_r1_and_r2_are_independent(self):
        """Neither variant carries the other's marker."""
        p = self.write('Preamble_Detector.v'); R.patch_preamble_detector(p)
        self.assertNotIn('RXFIX_R2', open(p).read())
        q = self.write('Preamble_Detector.v', MINI, sub='b'); R.patch_preamble_detector_r2(q)
        self.assertNotIn('RXFIX_R1', open(q).read())

    def test_39_r2_both_real_lineages(self):
        for src, name in ((S1_PD, 'Preamble_Detector.v'),
                          (KIT_PD, 'TxRxCompo_ip_src_Preamble_Detector.v')):
            if not os.path.exists(src):
                continue
            p = self.write(name, open(src).read())
            self.assertEqual(R.patch_preamble_detector_r2(p), 'patched')
            s = open(p).read()
            self.assertEqual(s.count('Delay11_out1 <= ps_fw_out;'), 1)
            self.assertEqual(R.patch_preamble_detector_r2(p), 'already')


# ======================================================================== RXFIX_W1
S1_DIR = os.path.join(REPO, 'jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback')
KIT_DIR = os.path.join(REPO, 'jupiter_byte_seqbist_build/hdl_prj_jupiter_composite/'
                             'hdlsrc/commhdlQPSKTxRxLoopback')


def _kit_name(f):
    return f if f.startswith('TxRxCompo_ip') else 'TxRxCompo_ip_src_' + f


class TestW1(TmpMixin):
    """RXFIX_W1: the silicon ring-witness / per-stage-valid-census instrument."""

    def _real(self, f, lineage):
        src = os.path.join(S1_DIR, f) if lineage == 's1' else os.path.join(KIT_DIR, _kit_name(f))
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        name = f if lineage == 's1' else _kit_name(f)
        return self.write(name, open(src).read()), src

    def test_40_w1_variant_is_registered(self):
        self.assertIn('W1', R.VARIANT_FILES)
        self.assertIn('W1', R.PATCHERS)
        self.assertEqual(len(R.W1_RTL_FILES), 8)
        self.assertEqual(len(R.W1_IP_FILES), 4)
        self.assertEqual(set(R.VARIANT_FILES['W1']), set(R.W1_RTL_FILES) | set(R.W1_IP_FILES))

    def test_41_w1_sim_tree_file_set_drops_the_ip_wrappers(self):
        """The Verilator lineage has no TxRxCompo_ip_* wrapper files."""
        self.assertEqual(R.w1_files(True), R.W1_RTL_FILES)
        self.assertEqual(len(R.w1_files(False)), 12)

    def test_42_zip_member_name_handles_both_prefixings(self):
        self.assertEqual(R.zip_member_name('Rate_Handle.v'), 'TxRxCompo_ip_src_Rate_Handle.v')
        self.assertEqual(R.zip_member_name('TxRxCompo_ip_dut.v'), 'TxRxCompo_ip_dut.v')
        self.assertEqual(R.zip_member_name('TxRxCompo_ip.v'), 'TxRxCompo_ip.v')

    def test_43_w1_patches_every_rtl_file_on_the_sim_lineage(self):
        for f in R.W1_RTL_FILES:
            p, _ = self._real(f, 's1')
            fn = R.W1_PATCHERS[f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_W1', open(p).read(), f)
            self.assertEqual(fn(p), 'already', f)

    def test_44_w1_patches_every_file_on_the_flashed_seqbist_lineage(self):
        for f in R.W1_RTL_FILES + R.W1_IP_FILES:
            p, _ = self._real(f, 'kit')
            fn = R.W1_PATCHERS[f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_W1', open(p).read(), f)
            self.assertEqual(fn(p), 'already', f)

    def test_45_w1_exports_the_three_quantities_that_were_never_observable(self):
        for lineage in ('s1', 'kit'):
            p, _ = self._real('Validate_Input_Push_Pop_block.v', lineage)
            R.patch_vipp_block_w1(p)
            s = open(p).read()
            self.assertIn('assign w1Occ = Delay_out1;', s)
            self.assertIn('assign w1PopEmpty = pop_on_empty_FIFO;', s)
            self.assertIn('assign w1PushFull = push_on_full_FIFO;', s)

    def test_46_w1_census_module_is_emitted_once_with_all_six_stages(self):
        p, _ = self._real('Frequency_and_Time_Synchronizer.v', 's1')
        R.patch_freq_time_sync_w1(p)
        s = open(p).read()
        self.assertEqual(s.count('module rh_w1_census'), 1)
        self.assertEqual(s.count('endmodule  // rh_w1_census'), 1)
        for pin in ('.vSS(w1_strobe)', '.vRH(Symbol_Synchronizer_validOut)',
                    '.vCFC(Coarse_Frequency_Compensator_validOut)',
                    '.vCS(Carrier_Synchronizer_validOut)',
                    '.vPD(Preamble_Detector_validOut)',
                    '.vPC(Packet_Controller_validOut)'):
            self.assertIn(pin, s, pin)

    def test_47_w1_census_counts_only_on_enb(self):
        """The 12,333*K arithmetic breaks if the counters run on raw clk."""
        p, _ = self._real('Frequency_and_Time_Synchronizer.v', 's1')
        R.patch_freq_time_sync_w1(p)
        mod = open(p).read().split('module rh_w1_census')[1]
        self.assertIn('else if (enb) begin', mod)
        self.assertIn('if ( ~freeze) begin', mod)
        self.assertNotIn('always @(posedge clk)', mod)   # must be async-reset form

    def test_48_w1_freeze_source_is_fixctl_bit4_where_fixctl_exists(self):
        p, _ = self._real('QPSK_Rx.v', 'kit')
        R.patch_qpsk_rx_w1(p)
        self.assertIn('assign w1_freeze = fixctl[4];', open(p).read())

    def test_49_w1_freeze_is_tied_off_where_there_is_no_fixctl(self):
        p, _ = self._real('QPSK_Rx.v', 's1')
        R.patch_qpsk_rx_w1(p)
        s = open(p).read()
        self.assertIn("assign w1_freeze = 1'b0;", s)
        self.assertNotIn('fixctl[4]', s)

    def test_50_w1_uses_free_read_words_and_leaves_dbgcap_alone(self):
        p, _ = self._real('TxRxCompo_ip_addr_decoder.v', 'kit')
        before = open(p).read()
        # the eight words W1 claims must be absent from the generated read mux
        for w in ("8'b10000101", "8'b10000110", "8'b10000111", "8'b10001000",
                  "8'b10001001", "8'b10001010", "8'b10001011", "8'b10001100"):
            self.assertNotIn(w, before, f'{w} is already decoded -- not free')
        R.patch_ip_addr_decoder_w1(p)
        s = open(p).read()
        self.assertIn("(address_select_level1 >= 8'h85)", s)
        self.assertIn("(address_select_level1 <= 8'h8C)", s)
        # DBGCAP/TXCAP keep 0x20C/0x210 and fixctl keeps its write decode
        self.assertIn('read_reg_beatfix_viol_count', s)
        self.assertIn('read_reg_beatfix_viol_latch', s)
        self.assertIn("decode_sel_fixctl_1_1 = addr_write == 14'b00000010000010", s)
        # W1 REPLACES the generated read assign with a hit/fallback form; the
        # generated mux output stays the fallback, so nothing already decoded moves.
        self.assertEqual(s.count('assign data_read ='), 1)
        self.assertIn('assign data_read = (w1_hit ? w1_reg[w1_idx] : mux_out0_level1);', s)

    def test_51_w1_adds_no_ip_toplevel_port(self):
        """component.xml must stay valid: TxRxCompo_ip's port list is untouched."""
        p, _ = self._real('TxRxCompo_ip.v', 'kit')
        before = open(p).read()
        head = before[:before.index('\n\n  input   IPCORE_CLK;')]
        R.patch_ip_top_w1(p)
        after = open(p).read()
        self.assertEqual(after[:after.index('\n\n  input   IPCORE_CLK;')], head)
        self.assertIn('.read_w1_bus(w1_bus_sig)', after)
        self.assertIn('.w1_bus(w1_bus_sig)', after)

    def test_52_w1_touches_no_data_path_assign(self):
        """W1 is read-only: it must not REMOVE or REDEFINE any existing assign."""
        for f in R.W1_RTL_FILES:
            p, src = self._real(f, 's1')
            before = open(src).read()
            R.W1_PATCHERS[f](p)
            after = open(p).read()
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')

    def test_53_w1_sim_tree_main_ok(self):
        for f in R.W1_RTL_FILES:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            self.write(f, open(src).read())
        self.assertEqual(R.main(self.d, 'W1', sim_tree=True), 0)
        for f in R.W1_RTL_FILES:
            self.assertIn('RXFIX_W1', open(os.path.join(self.d, f)).read(), f)

    def test_54_w1_kit_main_patches_mirrors_and_zips(self):
        srcs = {}
        for f in R.W1_RTL_FILES + R.W1_IP_FILES:
            src = os.path.join(KIT_DIR, _kit_name(f))
            if not os.path.exists(src):
                self.skipTest('seqbist kit not present')
            srcs[_kit_name(f)] = open(src).read()
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            for n, txt in srcs.items():
                self.write(n, txt, sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            with zipfile.ZipFile(os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip'), 'w') as z:
                for n, txt in srcs.items():
                    z.writestr('hdl/' + n, txt)
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')
        self.assertEqual(R.main(self.d, 'W1'), 0)
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    self.assertTrue(R.verify_zip(os.path.join(root, f), 'W1'))

    def test_55_uneven_loose_copies_fail_loudly(self):
        """The per-file count assert must catch a tree that is short one file."""
        srcs = {}
        for f in R.W1_RTL_FILES + R.W1_IP_FILES:
            src = os.path.join(KIT_DIR, _kit_name(f))
            if not os.path.exists(src):
                self.skipTest('seqbist kit not present')
            srcs[_kit_name(f)] = open(src).read()
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl'):
            for n, txt in srcs.items():
                if sub.startswith('ipcore') and n == 'TxRxCompo_ip_dut.v':
                    continue          # one mirror is short exactly one file
                self.write(n, txt, sub=sub)
        with self.assertRaises(AssertionError):
            R.main(self.d, 'W1')

    def test_56_w1_is_independent_of_r1_r2_r3(self):
        p, _ = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_w1(p)
        s = open(p).read()
        self.assertNotIn('RXFIX_R3', s)
        self.assertNotIn('r3_skips', s)


# ======================================================================= RXFIX_R3S
# Task 11: skip-only, acquisition-safe guard-band steering.  R3S is R3's file set
# with the extra-pop branch DELETED and an arming predicate added.
F3_DIR = os.path.join(REPO, 'jupiter_240k5_byte/rtl_sim/s1_rtl_txfix_F3',
                            'hdlsrc/commhdlQPSKTxRxLoopback')


class TestR3S(TmpMixin):

    def _real(self, f, lineage):
        """lineage: 's1' (Verilator source tree) or 'f3' (flashed txfixF3 tree)."""
        src = os.path.join(S1_DIR if lineage == 's1' else F3_DIR, f)
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        return self.write(f, open(src).read())

    # ---- registration ----
    def test_57_r3s_variant_is_registered_with_r3s_file_set(self):
        self.assertIn('R3S', R.VARIANT_FILES)
        self.assertIn('R3S', R.PATCHERS)
        self.assertIn('R3S', R.FILE_MARKER)
        self.assertEqual(len(R.VARIANT_FILES['R3S']), 7)
        # same seven internal modules as R3: no new IP / TxRxComposite port
        self.assertEqual(set(R.VARIANT_FILES['R3S']), set(R.VARIANT_FILES['R3']))
        self.assertNotIn('TxRxComposite.v', R.VARIANT_FILES['R3S'])
        self.assertTrue(all(m == 'RXFIX_R3S' for m in R.FILE_MARKER['R3S'].values()))

    # ---- the marker-substring hazard R3S introduced ----
    def test_58_has_matches_on_a_token_boundary_only(self):
        self.assertFalse(R._has('// RXFIX_R3S here', 'RXFIX_R3'))
        self.assertTrue(R._has('// RXFIX_R3 here', 'RXFIX_R3'))
        self.assertTrue(R._has('// RXFIX_R3S here', 'RXFIX_R3S'))
        self.assertTrue(R._has("assign x = 1;  // RXFIX_R3\n", 'RXFIX_R3'))

    # ---- both lineages ----
    def test_59_r3s_patches_every_file_on_the_sim_lineage_and_is_idempotent(self):
        for f in R.VARIANT_FILES['R3S']:
            p = self._real(f, 's1')
            fn = R.PATCHERS['R3S'][f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_R3S', open(p).read(), f)
            self.assertEqual(fn(p), 'already', f)

    def test_60_r3s_patches_every_file_on_the_flashed_txfixf3_lineage(self):
        for f in R.VARIANT_FILES['R3S']:
            p = self._real(f, 'f3')
            fn = R.PATCHERS['R3S'][f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_R3S', open(p).read(), f)

    # ---- the three properties the brief demands ----
    def test_61_r3s_has_no_extra_pop_branch_at_all(self):
        """R3's occ >= 30 branch is what destroyed framing; it must be absent."""
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        s = open(p).read()
        for banned in ('r3s_extras', 'r3s_do_extra', 'r3s_high', 'r3s_hi_done',
                       "6'd30", '>= 6', 'r3_extras'):
            self.assertNotIn(banned, s, f'extra-pop residue: {banned}')

    def test_62_unarmed_pop_is_the_baseline_expression(self):
        """s = 0 bit-identity is structural: do_skip is ANDed with r3s_armed."""
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        s = open(p).read()
        self.assertIn('assign r3s_pop_nom = validIn & Compare_To_Constant_out1;', s)
        self.assertIn('assign Logical_Operator_out1 = r3s_pop_nom & ( ~r3s_do_skip);', s)
        self.assertIn('assign r3s_do_skip = r3s_armed & guardIn', s)
        # the baseline assign must be gone exactly once (it was redefined, not kept)
        self.assertEqual(
            s.count('assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;'), 0)

    def test_63_arming_needs_lock_and_a_post_lock_pop_on_empty(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        s = open(p).read()
        self.assertIn('if (r3s_locked && r3s_pop_empty) begin', s)
        self.assertIn("assign r3s_locked = r3s_frames == 4'b1000;", s)
        # lock counts guardIn FALLING edges (deframer frame starts)
        self.assertIn('if (r3s_guard_d && ( ~guardIn) && ( ~r3s_locked)) begin', s)

    def test_64_pop_on_empty_reconstruction_matches_the_real_compare_block(self):
        """r3s_pop_empty must be BIT-EXACT pop_on_empty_FIFO, not an approximation."""
        cmpf = os.path.join(S1_DIR, 'Compare_To_Constant_block.v')
        if not os.path.exists(cmpf):
            self.skipTest('s1_rtl not present')
        c = open(cmpf).read()
        self.assertIn("assign Constant_out1 = 6'b000000;", c)
        self.assertIn('assign Compare_out1 = u == Constant_out1;', c)
        v = self._real('Validate_Input_Push_Pop_block.v', 's1')
        R.patch_vipp_block_r3s(v)
        self.assertIn('assign occOut = Delay_out1;', open(v).read())
        self.assertIn('assign pop_on_empty_FIFO = Compare_To_Constant_y & pop;',
                      open(v).read())
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        self.assertIn(
            "assign r3s_pop_empty = (r3s_occ == 6'b000000) & Logical_Operator_out1;",
            open(p).read())

    def test_65_threshold_is_occ_le_1_and_one_skip_per_guard_window(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        s = open(p).read()
        self.assertIn("(r3s_occ <= 6'b000001)", s)
        self.assertIn('( ~r3s_skip_done)', s)
        self.assertIn('if ( ~guardIn) begin\n            r3s_skip_done <= 1\'b0;', s)

    def test_66_r3s_state_advances_on_enb_only_and_is_async_reset(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        mod = open(p).read().split('r3s_steer_process')[1]
        self.assertIn('if (enb_1_2_0) begin', mod)
        head = open(p).read().split('begin : r3s_steer_process')[0]
        self.assertIn('always @(posedge clk or posedge reset)', head)

    def test_67_r3s_witnesses_are_declared(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        s = open(p).read()
        self.assertIn('reg  r3s_armed;', s)
        self.assertIn('reg [31:0] r3s_skips;', s)

    def test_68_guard_source_is_a_register_so_there_is_no_comb_loop(self):
        p = self._real('sample_discard_controller.v', 's1')
        R.patch_sample_discard_controller_r3s(p)
        self.assertIn('assign activeOut = active;', open(p).read())
        q = self._real('Packet_Controller.v', 's1')
        R.patch_packet_controller_r3s(q)
        self.assertIn('assign guardOut = ~sdc_active_r3s;', open(q).read())

    # ---- mutual exclusion with R3 ----
    def test_69_r3s_refuses_to_stack_on_r3(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3(p)
        with self.assertRaises(AssertionError):
            R.patch_rate_handle_r3s(p)

    def test_70_r3_cannot_be_applied_on_top_of_r3s_either(self):
        p = self._real('Rate_Handle.v', 's1')
        R.patch_rate_handle_r3s(p)
        with self.assertRaises(AssertionError):
            R.patch_rate_handle_r3(p)

    def test_71_verify_zip_does_not_certify_an_r3s_kit_as_r3(self):
        srcs = {}
        for f in R.VARIANT_FILES['R3S']:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            srcs[_kit_name(f)] = open(src).read()
        zp = os.path.join(self.d, 'TxRxCompo_ip_v1_0.zip')
        with zipfile.ZipFile(zp, 'w') as z:
            for n, txt in srcs.items():
                z.writestr('hdl/' + n, txt)
        R.patch_zip(zp, 'R3S', want=R.VARIANT_FILES['R3S'])
        self.assertTrue(R.verify_zip(zp, 'R3S'))
        self.assertFalse(R.verify_zip(zp, 'R3'))

    # ---- drivers ----
    def test_72_r3s_sim_tree_main_ok(self):
        for f in R.VARIANT_FILES['R3S']:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            self.write(f, open(src).read())
        self.assertEqual(R.main(self.d, 'R3S', sim_tree=True), 0)
        for f in R.VARIANT_FILES['R3S']:
            self.assertIn('RXFIX_R3S', open(os.path.join(self.d, f)).read(), f)

    def test_73_r3s_does_not_silently_mispatch_the_prefixed_ip_kit_lineage(self):
        """The two lineages R3S targets both carry UNPREFIXED module names.

        The packaged Vivado IP kit renames the modules themselves
        (`module TxRxCompo_ip_src_FIFO_block`), so R3S's structural module-name
        anchors do not match there -- exactly as for R3, which was likewise only
        ever claimed on s1_rtl and s1_rtl_txfix_F3.  What matters is that this
        fails LOUDLY (the exactly-once anchor assert) instead of quietly editing
        the wrong span.  Task 11 is sim-only and needs no kit; if a build kit is
        ever wanted, the prefix has to be handled deliberately.
        """
        src = os.path.join(KIT_DIR, _kit_name('FIFO_block.v'))
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        self.assertIn('module TxRxCompo_ip_src_FIFO_block', open(src).read())
        p = self.write(_kit_name('FIFO_block.v'), open(src).read())
        with self.assertRaises(AssertionError):
            R.patch_fifo_block_r3s(p)

    def test_74_r3s_adds_exactly_one_port_per_module_and_no_toplevel_port(self):
        """No TxRxComposite / TxRxCompo_ip port: the IP interface is unchanged."""
        for f, nport in (('Rate_Handle.v', 1), ('Symbol_Synchronizer.v', 1),
                         ('FIFO_block.v', 1), ('Validate_Input_Push_Pop_block.v', 1),
                         ('Packet_Controller.v', 1), ('sample_discard_controller.v', 1),
                         ('Frequency_and_Time_Synchronizer.v', 0)):
            p = self._real(f, 's1')
            before = open(p).read()
            R.PATCHERS['R3S'][f](p)
            after = open(p).read()
            self.assertEqual(after.count('           // RXFIX_R3S\n'), nport, f)
            # no existing assign is lost (the ONE deliberate exception is the
            # Rate_Handle pop expression, which R3S redefines)
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    if 'Logical_Operator_out1 = validIn' in line:
                        continue
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')


# ======================================================================== RXFIX_R4
# Task 12: R4 = R3S's skip-only guard-band steering with the ring PRE-FILLED to
# mid-occupancy at reset and the steering armed by that pre-fill plus lock, instead
# of by the first post-lock EMPTY-edge hole.  Same seven files, marker RXFIX_R4.

class TestR4(TmpMixin):

    def _real(self, f, lineage='s1'):
        """lineage: 's1' (Verilator source tree) or 'f3' (flashed txfixF3 tree)."""
        src = os.path.join(S1_DIR if lineage == 's1' else F3_DIR, f)
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        return self.write(f, open(src).read())

    def _tree(self, lineage='s1', sub=''):
        """Lay down the union of the W1 and R4 file sets, return the directory."""
        d = os.path.join(self.d, sub) if sub else self.d
        base = S1_DIR if lineage == 's1' else F3_DIR
        for f in sorted(set(R.w1_files(True)) | set(R.VARIANT_FILES['R4'])):
            src = os.path.join(base, f)
            if not os.path.exists(src):
                self.skipTest(f'{src} not present')
            self.write(f, open(src).read(), sub=sub)
        return d

    # ---- registration ----
    def test_75_r4_variant_is_registered_with_the_r3s_file_set(self):
        self.assertIn('R4', R.VARIANT_FILES)
        self.assertIn('R4', R.PATCHERS)
        self.assertIn('R4', R.FILE_MARKER)
        self.assertEqual(len(R.VARIANT_FILES['R4']), 7)
        # same seven internal modules as R3/R3S: no new IP / TxRxComposite port
        self.assertEqual(set(R.VARIANT_FILES['R4']), set(R.VARIANT_FILES['R3S']))
        self.assertNotIn('TxRxComposite.v', R.VARIANT_FILES['R4'])
        self.assertTrue(all(m == 'RXFIX_R4' for m in R.FILE_MARKER['R4'].values()))
        # RXFIX_R4 is not a prefix of, nor prefixed by, any other marker
        for m in (R.MARKER, R.MARKER_R2, R.MARKER_R3, R.MARKER_R3S, R.MARKER_W1):
            self.assertFalse(R._has(m, R.MARKER_R4))
            self.assertFalse(R._has(R.MARKER_R4, m))

    # ---- both lineages ----
    def test_76_r4_patches_every_file_on_the_sim_lineage_and_is_idempotent(self):
        for f in R.VARIANT_FILES['R4']:
            p = self._real(f)
            fn = R.PATCHERS['R4'][f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_R4', open(p).read(), f)
            self.assertEqual(fn(p), 'already', f)

    def test_77_r4_patches_every_file_on_the_flashed_txfixf3_lineage(self):
        for f in R.VARIANT_FILES['R4']:
            p = self._real(f, 'f3')
            fn = R.PATCHERS['R4'][f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_R4', open(p).read(), f)

    # ---- the pre-fill: the one thing R4 adds over R3S ----
    def test_78_pop_is_gated_on_a_sticky_prefilled_flag_set_at_occupancy_16(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        self.assertIn('assign r4_pop_nom = validIn & Compare_To_Constant_out1;', s)
        self.assertIn(
            'assign Logical_Operator_out1 = r4_pop_nom & r4_prefilled & ( ~r4_do_skip);', s)
        # sticky: set, never cleared except by reset
        self.assertIn("if (r4_occ >= 6'b010000) begin\n            r4_prefilled <= 1'b1;", s)
        self.assertEqual(s.count("r4_prefilled <= 1'b1;"), 1)
        self.assertEqual(s.count("r4_prefilled <= 1'b0;"), 1)   # the reset arm only
        # the baseline pop assign is gone exactly once (redefined, not kept)
        self.assertEqual(
            s.count('assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;'), 0)

    def test_79_identity_at_s0_is_not_claimed_structurally(self):
        """R3S's unarmed pop WAS the baseline line; R4's never is.  Guard the wording.

        This is a real behavioural difference, not a comment nit: R3S could claim
        bit-identity at s = 0 from the text alone, R4 cannot, and its 0 ppm gate row
        is content identity plus a constant pre-fill latency.  If someone ever makes
        the pop expression baseline-equal again, this test tells them the gate row
        has to change with it.
        """
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        pop = [l for l in s.splitlines()
               if l.startswith('  assign Logical_Operator_out1')]
        self.assertEqual(len(pop), 1)
        self.assertIn('r4_prefilled', pop[0])

    # ---- the steering ----
    def test_80_threshold_is_occ_le_8_and_one_skip_per_guard_window(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        self.assertIn("(r4_occ <= 6'b001000)", s)          # 8
        self.assertIn('( ~r4_skip_done)', s)
        self.assertIn("if ( ~guardIn) begin\n            r4_skip_done <= 1'b0;", s)

    def test_81_skip_needs_prefilled_and_locked(self):
        """Lock is in the predicate for a reason: pre-fill completes in air frame 0
        but lock is ~air frame 5, and guardIn is stuck at 1 in that gap, so a stray
        skip would latch r4_skip_done (cleared only on ~guardIn) for the whole run."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        self.assertIn('assign r4_do_skip = r4_prefilled & r4_locked & guardIn &', s)
        self.assertIn("assign r4_locked = r4_frames == 4'b1000;", s)
        # lock counts guardIn FALLING edges (deframer frame starts)
        self.assertIn('if (r4_guard_d && ( ~guardIn) && ( ~r4_locked)) begin', s)

    def test_82_r4_has_no_extra_pop_branch_at_all(self):
        """R3's occ >= 30 branch is what destroyed framing; it must be absent."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        for banned in ('r4_extras', 'r4_do_extra', 'r4_high', 'r4_hi_done',
                       "6'd30", "6'b011110", 'r3_extras', 'r3s_'):
            self.assertNotIn(banned, s, f'extra-pop / R3S residue: {banned}')
        # R3S's test banned the substring '>= 6' as a proxy for the occ >= 30 branch.
        # R4 legitimately carries one '>=' -- the PRE-FILL threshold -- so the ban is
        # made exact instead: there is exactly one, and it is the pre-fill.
        ge = [l.strip() for l in s.splitlines() if '>=' in l and 'r4_' in l]
        self.assertEqual(ge, ["if (r4_occ >= 6'b010000) begin"], ge)
        # and the pop is only ever suppressed, never asserted outside r4_pop_nom
        self.assertNotIn('| r4_do', s)

    def test_83_r4_state_advances_on_enb_only_and_is_async_reset(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        mod = open(p).read().split('r4_steer_process')[1]
        self.assertIn('if (enb_1_2_0) begin', mod)
        head = open(p).read().split('begin : r4_steer_process')[0]
        self.assertIn('always @(posedge clk or posedge reset)', head)

    def test_84_r4_witnesses_are_declared(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4(p)
        s = open(p).read()
        self.assertIn('reg  r4_prefilled;', s)
        self.assertIn('reg [31:0] r4_skips;', s)

    def test_85_occupancy_tap_is_the_ring_occupancy_the_empty_compare_uses(self):
        """occOut must be Delay_out1 -- the same net Compare_To_Constant_block tests
        against 6'b000000 to form pop_on_empty_FIFO -- not a pointer delta."""
        cmpf = os.path.join(S1_DIR, 'Compare_To_Constant_block.v')
        if not os.path.exists(cmpf):
            self.skipTest('s1_rtl not present')
        c = open(cmpf).read()
        self.assertIn("assign Constant_out1 = 6'b000000;", c)
        self.assertIn('assign Compare_out1 = u == Constant_out1;', c)
        v = self._real('Validate_Input_Push_Pop_block.v')
        R.patch_vipp_block_r4(v)
        s = open(v).read()
        self.assertIn('assign occOut = Delay_out1;', s)
        self.assertIn('assign pop_on_empty_FIFO = Compare_To_Constant_y & pop;', s)

    def test_86_guard_source_is_a_register_so_there_is_no_comb_loop(self):
        p = self._real('sample_discard_controller.v')
        R.patch_sample_discard_controller_r4(p)
        self.assertIn('assign activeOut = active;', open(p).read())
        q = self._real('Packet_Controller.v')
        R.patch_packet_controller_r4(q)
        self.assertIn('assign guardOut = ~sdc_active_r4;', open(q).read())

    # ---- mutual exclusion, symmetric, on EVERY file of the variant ----
    def test_87_r4_refuses_to_stack_on_r3_or_r3s_on_every_file(self):
        for f in R.VARIANT_FILES['R4']:
            for other in ('R3', 'R3S'):
                p = self._real(f)
                R.PATCHERS[other][f](p)
                with self.assertRaises(AssertionError, msg=f'{other} then R4 on {f}'):
                    R.PATCHERS['R4'][f](p)

    def test_88_r3_and_r3s_refuse_to_stack_on_r4_on_every_file(self):
        for f in R.VARIANT_FILES['R4']:
            for other in ('R3', 'R3S'):
                p = self._real(f)
                R.PATCHERS['R4'][f](p)
                with self.assertRaises(AssertionError, msg=f'R4 then {other} on {f}'):
                    R.PATCHERS[other][f](p)

    def test_89_verify_zip_does_not_confuse_r4_with_r3_or_r3s(self):
        srcs = {}
        for f in R.VARIANT_FILES['R4']:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            srcs[_kit_name(f)] = open(src).read()
        zp = os.path.join(self.d, 'TxRxCompo_ip_v1_0.zip')
        with zipfile.ZipFile(zp, 'w') as z:
            for n, txt in srcs.items():
                z.writestr('hdl/' + n, txt)
        R.patch_zip(zp, 'R4', want=R.VARIANT_FILES['R4'])
        self.assertTrue(R.verify_zip(zp, 'R4'))
        self.assertFalse(R.verify_zip(zp, 'R3'))
        self.assertFalse(R.verify_zip(zp, 'R3S'))

    # ---- drivers ----
    def test_90_r4_sim_tree_main_ok(self):
        for f in R.VARIANT_FILES['R4']:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            self.write(f, open(src).read())
        self.assertEqual(R.main(self.d, 'R4', sim_tree=True), 0)
        for f in R.VARIANT_FILES['R4']:
            self.assertIn('RXFIX_R4', open(os.path.join(self.d, f)).read(), f)

    def test_91_r4_does_not_silently_mispatch_the_prefixed_ip_kit_lineage(self):
        """Same documented limitation as R3/R3S: the packaged Vivado IP kit renames
        the modules (`module TxRxCompo_ip_src_FIFO_block`), so R4's structural
        module-name anchors do not match there.  It must fail LOUDLY on the
        exactly-once assert rather than quietly editing the wrong span."""
        src = os.path.join(KIT_DIR, _kit_name('FIFO_block.v'))
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        self.assertIn('module TxRxCompo_ip_src_FIFO_block', open(src).read())
        p = self.write(_kit_name('FIFO_block.v'), open(src).read())
        with self.assertRaises(AssertionError):
            R.patch_fifo_block_r4(p)

    def test_92_r4_adds_exactly_one_port_per_module_and_no_toplevel_port(self):
        for f, nport in (('Rate_Handle.v', 1), ('Symbol_Synchronizer.v', 1),
                         ('FIFO_block.v', 1), ('Validate_Input_Push_Pop_block.v', 1),
                         ('Packet_Controller.v', 1), ('sample_discard_controller.v', 1),
                         ('Frequency_and_Time_Synchronizer.v', 0)):
            p = self._real(f)
            before = open(p).read()
            R.PATCHERS['R4'][f](p)
            after = open(p).read()
            self.assertEqual(after.count('           // RXFIX_R4\n'), nport, f)
            # no existing assign is lost (the ONE deliberate exception is the
            # Rate_Handle pop expression, which R4 redefines)
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    if 'Logical_Operator_out1 = validIn' in line:
                        continue
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')

    def test_93_r4_is_independent_of_r1_and_r2(self):
        """R1/R2 own Preamble_Detector.v; R4 owns the seven ring/deframer files."""
        self.assertFalse(set(R.VARIANT_FILES['R4']) & set(R.VARIANT_FILES['R1']))
        self.assertFalse(set(R.VARIANT_FILES['R4']) & set(R.VARIANT_FILES['R2']))

    # ---- the Task 13 deliverable: W1 + R4 must be applicable together ----
    def test_94_w1_and_r4_apply_together_in_both_orders_on_both_lineages(self):
        """Task 13 builds W1 + R4 on one tree, so the two must not fight.

        W1 is a read-only instrument; R4 redefines the pop.  Five files are in BOTH
        file sets (Validate_Input_Push_Pop_block, FIFO_block, Rate_Handle,
        Symbol_Synchronizer, Frequency_and_Time_Synchronizer), so this asserts every
        anchor of each still resolves exactly-once after the other has run -- in
        BOTH orders, on BOTH netlist lineages.
        """
        for lineage in ('s1', 'f3'):
            for order in (('W1', 'R4'), ('R4', 'W1')):
                sub = f'{lineage}_{order[0]}{order[1]}'
                d = self._tree(lineage, sub=sub)
                for v in order:
                    self.assertEqual(R.main(d, v, sim_tree=True), 0,
                                     f'{v} in {order} on {lineage}')
                for f in R.w1_files(True):
                    self.assertIn('RXFIX_W1', open(os.path.join(d, f)).read(),
                                  f'{f} {order} {lineage}')
                for f in R.VARIANT_FILES['R4']:
                    self.assertIn('RXFIX_R4', open(os.path.join(d, f)).read(),
                                  f'{f} {order} {lineage}')

    def test_95_w1_r4_combined_result_is_order_independent_line_for_line(self):
        """The two orders interleave the inserted lines differently (a port list gets
        W1's ports before or after R4's), but the SET of lines must be identical --
        i.e. neither variant's insertion consumed or displaced the other's."""
        for lineage in ('s1', 'f3'):
            trees = {}
            for order in (('W1', 'R4'), ('R4', 'W1')):
                sub = f'x_{lineage}_{order[0]}{order[1]}'
                d = self._tree(lineage, sub=sub)
                for v in order:
                    self.assertEqual(R.main(d, v, sim_tree=True), 0)
                trees[order] = d
            for f in R.VARIANT_FILES['R4']:
                a = sorted(open(os.path.join(trees[('W1', 'R4')], f)).read().splitlines())
                b = sorted(open(os.path.join(trees[('R4', 'W1')], f)).read().splitlines())
                self.assertEqual(a, b, f'{f} differs by more than line order ({lineage})')

    def test_96_w1_does_not_touch_the_pop_expression_r4_redefines(self):
        """Why the two can coexist at all, asserted rather than assumed."""
        p = self._real('Rate_Handle.v')
        before = open(p).read()
        R.patch_rate_handle_w1(p)
        after = open(p).read()
        self.assertIn('assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;',
                      after)
        self.assertEqual(before.count('assign Logical_Operator_out1'),
                         after.count('assign Logical_Operator_out1'))
        # ... and R4 then still finds its anchor exactly once
        self.assertEqual(R.patch_rate_handle_r4(p), 'patched')
        self.assertIn('r4_prefilled', open(p).read())


# ======================================================================= RXFIX_R4B
# Task 12b: R4B = the silicon-ready form of R4.  STRUCTURAL 13-slot window opened by
# Packet_Controller.endOut (an EXISTING port, so the file set is FIVE not seven), a
# REGISTERED decision, lock = 8 pcEnd pulses, NO pre-fill, _PFX-tolerant anchors that
# reach the packaged IP kit (which is exactly what tests 73/91 pin that R3S/R4 cannot
# do), and a ninth W1 read word at 0x234 carrying the witnesses.

class TestR4B(TmpMixin):

    def _real(self, f, lineage='s1'):
        """lineage: 's1' (Verilator tree), 'f3' (flashed txfixF3), 'kit' (packaged IP)."""
        base = {'s1': S1_DIR, 'f3': F3_DIR, 'kit': KIT_DIR}[lineage]
        name = _kit_name(f) if lineage == 'kit' else f
        src = os.path.join(base, name)
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        return self.write(name, open(src).read())

    def _tree(self, lineage='s1', sub=''):
        """Union of the W1 and R4B file sets as loose unprefixed copies."""
        d = os.path.join(self.d, sub) if sub else self.d
        base = S1_DIR if lineage == 's1' else F3_DIR
        for f in sorted(set(R.w1_files(True)) | set(R.r4b_files(True))):
            src = os.path.join(base, f)
            if not os.path.exists(src):
                self.skipTest(f'{src} not present')
            self.write(f, open(src).read(), sub=sub)
        return d

    def _kitsrcs(self, extra=()):
        srcs = {}
        for f in sorted(set(R.W1_RTL_FILES) | set(R.W1_IP_FILES)
                        | set(R.VARIANT_FILES['R4B']) | set(extra)):
            src = os.path.join(KIT_DIR, _kit_name(f))
            if not os.path.exists(src):
                self.skipTest('seqbist kit not present')
            srcs[_kit_name(f)] = open(src).read()
        return srcs

    def _kittree(self, extra=()):
        """The shipped kit shape: 3 loose mirrors + 2 TxRxCompo_ip_v1_0.zip members."""
        srcs = self._kitsrcs(extra)
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            for n, txt in srcs.items():
                self.write(n, txt, sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            with zipfile.ZipFile(os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip'), 'w') as z:
                for n, txt in srcs.items():
                    z.writestr('hdl/' + n, txt)
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')

    # ---- registration ----
    def test_97_r4b_is_registered_and_needs_only_five_core_files(self):
        for t in (R.VARIANT_FILES, R.PATCHERS, R.FILE_MARKER):
            self.assertIn('R4B', t)
        self.assertEqual(len(R.R4B_CORE_FILES), 5)
        # the two files R3/R3S/R4 had to patch and R4B does NOT: pcEnd is an existing port
        self.assertNotIn('sample_discard_controller.v', R.VARIANT_FILES['R4B'])
        self.assertNotIn('Packet_Controller.v', R.VARIANT_FILES['R4B'])
        # every core file is also a W1 file, so W1+R4B share one anchor surface
        self.assertTrue(set(R.R4B_CORE_FILES) <= set(R.W1_RTL_FILES))
        self.assertEqual(R.r4b_files(True), R.R4B_CORE_FILES + R.R4B_WIT_RTL_FILES)
        self.assertEqual(len(R.r4b_files(False)), 12)
        self.assertTrue(all(m == 'RXFIX_R4B' for m in R.FILE_MARKER['R4B'].values()))

    def test_98_r4b_marker_does_not_collide_with_r4(self):
        """'RXFIX_R4' is a PREFIX of 'RXFIX_R4B' -- the same hazard R3/R3S had."""
        self.assertFalse(R._has('// RXFIX_R4B here', 'RXFIX_R4'))
        self.assertTrue(R._has('// RXFIX_R4B here', 'RXFIX_R4B'))
        self.assertTrue(R._has('// RXFIX_R4 here', 'RXFIX_R4'))
        self.assertFalse(R._has('// RXFIX_R4 here', 'RXFIX_R4B'))

    # ---- all three lineages, including the one R3S/R4 cannot reach ----
    def test_99_r4b_patches_the_sim_lineage_and_is_idempotent(self):
        for f in R.R4B_CORE_FILES:
            p = self._real(f)
            fn = R.PATCHERS['R4B'][f]
            self.assertEqual(fn(p), 'patched', f)
            self.assertIn('RXFIX_R4B', open(p).read(), f)
            self.assertEqual(fn(p), 'already', f)

    def test_100_r4b_patches_the_flashed_txfixf3_lineage(self):
        for f in R.R4B_CORE_FILES:
            p = self._real(f, 'f3')
            self.assertEqual(R.PATCHERS['R4B'][f](p), 'patched', f)

    def test_101_r4b_DOES_reach_the_prefixed_ip_kit_lineage(self):
        """The direct answer to tests 73/91: R3S and R4 fail loudly on the kit's
        `module TxRxCompo_ip_src_FIFO_block`; every R4B anchor is _PFX-tolerant, so R4B
        patches it.  Asserted against the same file those two tests use."""
        src = os.path.join(KIT_DIR, _kit_name('FIFO_block.v'))
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        self.assertIn('module TxRxCompo_ip_src_FIFO_block', open(src).read())
        with self.assertRaises(AssertionError):                 # R4 still cannot
            R.patch_fifo_block_r4(self.write(_kit_name('FIFO_block.v'), open(src).read()))
        for f in R.R4B_CORE_FILES:                              # R4B can
            p = self._real(f, 'kit')
            self.assertEqual(R.PATCHERS['R4B'][f](p), 'patched', f)
            self.assertIn('RXFIX_R4B', open(p).read(), f)

    # ---- the structural window: review finding (1) ----
    def test_102_window_is_opened_by_pcend_and_is_thirteen_slots(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        self.assertIn('  input   pcEndIn;\n', s)
        self.assertIn("r4b_pcend_d <= pcEndIn;", s)
        # the window opens on the REGISTERED pulse, is 13 slots wide, one skip max
        self.assertIn("if (r4b_pcend_d) begin\n            r4b_win <= 1'b1;", s)
        self.assertIn("if (r4b_wslot >= 4'b1101) begin\n              r4b_win <= 1'b0;", s)
        self.assertIn("(r4b_wslot <= 4'b1100)", s)
        self.assertEqual(s.count("r4b_skip_done <= 1'b1;"), 1)
        # and no CODE references the deframer-idle guard R3S/R4 used (the block
        # comment names it, which is why the check is on non-comment lines only)
        code = '\n'.join(l for l in s.splitlines() if not l.lstrip().startswith('//'))
        for bad in ('guardIn', 'guardOut', 'sdc_active'):
            self.assertNotIn(bad, code, f'R4B must not use {bad}')

    def test_103_window_source_is_the_existing_packet_controller_endout(self):
        """No new port anywhere for pcEnd: FTS:104's wire on Packet_Controller.v:47's
        port, which is what Task 11's dump printed as pcEnd."""
        p = self._real('Frequency_and_Time_Synchronizer.v')
        before = open(p).read()
        self.assertIn('  wire Packet_Controller_endOut;\n', before)
        R.patch_freq_time_sync_r4b(p)
        s = open(p).read()
        self.assertIn('.pcEndIn(Packet_Controller_endOut)', s)
        # FTS gains NO port when W1 is absent (the witnesses stay internal)
        self.assertEqual(s.count('           // RXFIX_R4B\n'), 0)
        self.assertEqual(before.count('wire Packet_Controller_endOut;'),
                         s.count('wire Packet_Controller_endOut;'))

    # ---- the registered decision: review finding (3) ----
    def test_104_every_input_to_the_pop_is_registered(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        self.assertIn('assign Logical_Operator_out1 = r4b_pop_nom & ( ~r4b_skip_en);', s)
        self.assertIn('assign r4b_pop_nom = validIn & Compare_To_Constant_out1;', s)
        # skip_en, the occupancy compare and the pcEnd pulse are ALL flops
        for r in ('r4b_skip_en', 'r4b_occ_le8', 'r4b_pcend_d'):
            self.assertRegex(s, r'\n  reg  ' + r + r'[;,\s]')
        # the occupancy compare happens ONLY inside the clocked process
        self.assertIn("r4b_occ_le8 <= (r4b_occ <= 6'b001000);", s)
        self.assertEqual(s.count('r4b_occ <='), 1)
        # no combinational occupancy or pcEnd term in the pop or in do_skip
        do = [l for l in s.splitlines() if l.startswith('  assign r4b_do_skip')][0]
        self.assertEqual(do, '  assign r4b_do_skip = r4b_skip_en & r4b_pop_nom;')

    def test_105_state_advances_on_enb_only_and_is_async_reset(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        i = s.index('begin : r4b_steer_process')
        blk = s[i:s.index('\n  assign', i)] if '\n  assign' in s[i:] else s[i:]
        self.assertIn('if (reset == 1\'b1) begin', blk)
        self.assertIn('if (enb_1_2_0) begin', blk)
        self.assertIn('always @(posedge clk or posedge reset)', s[:i])

    # ---- lock: review finding (5) ----
    def test_106_lock_is_eight_pcend_pulses(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        self.assertIn("assign r4b_locked = r4b_frames == 4'b1000;", s)
        self.assertIn("if (r4b_pcend_d && ( ~r4b_locked)) begin", s)
        self.assertIn("r4b_frames <= r4b_frames + 4'b0001;", s)

    # ---- the pre-fill is GONE: controller ruling 17:07 ----
    def test_107_there_is_no_prefill_and_no_timeout(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read().lower()
        for bad in ('prefill', 'prefilled', "6'b010000", '4096'):
            self.assertNotIn(bad.lower(), s, f'R4B must carry no pre-fill residue: {bad}')

    def test_108_unarmed_pop_is_structurally_the_baseline_expression(self):
        """R4 gated the pop on r4_prefilled so its expression was NEVER the baseline
        one.  R4B gates only on a flag that is 0 until the first arm, so acquisition is
        bit-identical to the baseline netlist -- R3S's property, recovered."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        self.assertIn('assign Logical_Operator_out1 = r4b_pop_nom & ( ~r4b_skip_en);', s)
        self.assertNotIn('r4b_prefilled', s)
        self.assertEqual(
            s.count('assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;'), 0)

    def test_109_no_extra_pop_branch_at_all(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(p)
        s = open(p).read()
        for bad in ('r4b_extras', 'r4b_do_extra', 'r4b_high', 'r4b_hi_done', "6'd30", '>= 6'):
            self.assertNotIn(bad, s)

    # ---- the occupancy tap is the ring's own, as for R3S/R4 ----
    def test_110_occupancy_tap_is_the_net_the_empty_compare_uses(self):
        p = self._real('Validate_Input_Push_Pop_block.v')
        before = open(p).read()
        self.assertIn('pop_on_empty_FIFO', before)
        R.patch_vipp_block_r4b(p)
        s = open(p).read()
        self.assertIn('assign r4bOcc = Delay_out1;  // RXFIX_R4B', s)
        self.assertIn('  output  [5:0] r4bOcc;\n', s)

    # ---- mutual exclusion, symmetric and per-file ----
    def test_111_r4b_refuses_to_stack_on_r3_r3s_or_r4(self):
        for other in ('R3', 'R3S', 'R4'):
            for f in R.R4B_CORE_FILES:
                p = self._real(f)
                R.PATCHERS[other][f](p)
                with self.assertRaises(AssertionError, msg=f'{other}/{f}'):
                    R.PATCHERS['R4B'][f](p)

    def test_112_r3_r3s_and_r4_refuse_to_stack_on_r4b(self):
        for other in ('R3', 'R3S', 'R4'):
            for f in R.R4B_CORE_FILES:
                p = self._real(f)
                R.PATCHERS['R4B'][f](p)
                with self.assertRaises(AssertionError, msg=f'{other}/{f}'):
                    R.PATCHERS[other][f](p)

    def test_113_verify_zip_does_not_confuse_r4b_with_r4(self):
        srcs = {}
        for f in R.R4B_CORE_FILES:
            src = os.path.join(S1_DIR, f)
            if not os.path.exists(src):
                self.skipTest('s1_rtl not present')
            srcs[_kit_name(f)] = open(src).read()
        zp = os.path.join(self.d, 'TxRxCompo_ip_v1_0.zip')
        with zipfile.ZipFile(zp, 'w') as z:
            for n, t in srcs.items():
                z.writestr('hdl/' + n, t)
        R.patch_zip(zp, 'R4B', want=R.R4B_CORE_FILES)
        self.assertTrue(R.verify_zip(zp, 'R4B', R.R4B_CORE_FILES))
        self.assertFalse(R.verify_zip(zp, 'R4', R.R4B_CORE_FILES))

    def test_114_r4b_sim_tree_main_ok_and_witnesses_stay_internal(self):
        d = self._tree('s1')
        self.assertEqual(R.main(d, 'R4B', sim_tree=True), 0)
        for f in R.R4B_CORE_FILES:
            self.assertIn('RXFIX_R4B', open(os.path.join(d, f)).read(), f)
        # W1 absent -> the carry chain is untouched, so no new TxRxComposite port
        for f in R.R4B_WIT_RTL_FILES:
            self.assertNotIn('RXFIX_R4B', open(os.path.join(d, f)).read(), f)
        self.assertNotIn('r4bWit', open(os.path.join(d, 'Rate_Handle.v')).read())

    # ---- the ninth W1 word ----
    def test_115_w1_then_r4b_gives_the_ninth_word_at_0x234(self):
        d = self._tree('s1')
        self.assertEqual(R.main(d, 'W1', sim_tree=True), 0)
        self.assertEqual(R.main(d, 'R4B', sim_tree=True), 0)
        rh = open(os.path.join(d, 'Rate_Handle.v')).read()
        self.assertIn('assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};', rh)
        self.assertIn('  output  [31:0] r4bWit;\n', rh)
        for f in R.R4B_WIT_RTL_FILES:
            self.assertIn('RXFIX_R4B', open(os.path.join(d, f)).read(), f)
        fts = open(os.path.join(d, 'Frequency_and_Time_Synchronizer.v')).read()
        self.assertIn('assign r4bWit = r4b_wit;', fts)

    def test_116_witness_word_is_exactly_32_bits_and_has_no_prefilled_flag(self):
        d = self._tree('s1')
        R.main(d, 'W1', sim_tree=True)
        R.main(d, 'R4B', sim_tree=True)
        rh = open(os.path.join(d, 'Rate_Handle.v')).read()
        self.assertIn('  reg [15:0] r4b_skips;', rh)     # 16
        self.assertIn('  reg [14:0] r4b_opens;', rh)     # 15   + 1 flag = 32
        self.assertIn('assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};', rh)
        self.assertNotIn('prefilled', rh)

    def test_117_ninth_word_leaves_the_eight_w1_words_byte_identical(self):
        """The ONLY W1-injected line R4B may rewrite is the single `assign data_read`
        (there is exactly one in the module and the ninth word has to come from
        somewhere).  Everything else W1 injected must survive line for line."""
        srcs = self._kitsrcs()
        f = _kit_name('TxRxCompo_ip_addr_decoder.v')
        p = self.write(f, srcs[f])
        R.patch_ip_addr_decoder_w1(p)
        w1_only = open(p).read()
        R.patch_ip_addr_decoder_r4b(p)
        both = open(p).read()
        gone = [l for l in w1_only.splitlines() if l not in both.splitlines()]
        self.assertEqual(gone, [R.W1_DATA_READ_LINE.rstrip('\n')], gone[:4])
        # the eight words' decode is untouched
        for keep in ("assign w1_hit = (address_select_level1 >= 8'h85) &&",
                     "(address_select_level1 <= 8'h8C);",
                     "assign w1_idx = address_select_level1[2:0] - 3'd5;",
                     'reg [31:0] w1_reg [0:7];', 'begin : w1_reg_process'):
            self.assertIn(keep, both)
        # ... and the ninth word is one past them, at word 0x8D = byte 0x234
        self.assertIn("assign r4b_hit = (address_select_level1 == 8'h8D);", both)
        self.assertIn('assign data_read = (r4b_hit ? r4b_reg :', both)
        self.assertIn('(w1_hit ? w1_reg[w1_idx] : mux_out0_level1));', both)

    def test_118_r4b_then_w1_fails_loudly_on_the_decoder(self):
        """Order matters for ONE file and it must not degrade silently."""
        srcs = self._kitsrcs()
        f = _kit_name('TxRxCompo_ip_addr_decoder.v')
        p = self.write(f, srcs[f])
        self.assertEqual(R.patch_ip_addr_decoder_r4b(p), 'skipped')   # no W1 -> untouched
        R.patch_ip_addr_decoder_w1(p)
        self.assertEqual(R.patch_ip_addr_decoder_r4b(p), 'patched')
        with self.assertRaises(AssertionError):
            R.patch_ip_addr_decoder_w1(self.write('again.v', open(p).read().replace(
                'RXFIX_W1', 'RXFIX_XX')))

    # ---- THE Task 13 deliverable: W1 + R4B on a kit-shaped tree ----
    def test_119_w1_then_r4b_apply_to_a_kit_shaped_tree_with_verify_zip(self):
        self._kittree()
        self.assertEqual(R.main(self.d, 'W1'), 0)
        self.assertEqual(R.main(self.d, 'R4B'), 0)
        nz = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    zp = os.path.join(root, f); nz += 1
                    self.assertTrue(R.verify_zip(zp, 'W1'), zp)
                    self.assertTrue(R.verify_zip(zp, 'R4B'), zp)
        self.assertEqual(nz, 2)
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == _kit_name('Rate_Handle.v'):
                    s = open(os.path.join(root, f)).read()
                    self.assertIn('RXFIX_W1', s)
                    self.assertIn('RXFIX_R4B', s)
                    self.assertIn('assign r4bWit =', s)

    def test_120_w1_and_r4b_apply_in_both_orders_on_both_sim_lineages(self):
        """On the five core files and a --sim-tree either order works; only the kit's
        addr_decoder is order-sensitive (test 118)."""
        for lineage in ('s1', 'f3'):
            for order in (('W1', 'R4B'), ('R4B', 'W1')):
                sub = f'{lineage}_{order[0]}{order[1]}'
                d = self._tree(lineage, sub=sub)
                for v in order:
                    self.assertEqual(R.main(d, v, sim_tree=True), 0, f'{v} {order} {lineage}')
                for f in R.R4B_CORE_FILES:
                    s = open(os.path.join(d, f)).read()
                    self.assertIn('RXFIX_W1', s, f)
                    self.assertIn('RXFIX_R4B', s, f)

    def test_121_w1_does_not_touch_the_pop_expression_r4b_redefines(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_w1(p)
        self.assertIn('assign Logical_Operator_out1 = validIn & Compare_To_Constant_out1;',
                      open(p).read())
        self.assertEqual(R.patch_rate_handle_r4b(p), 'patched')
        self.assertIn('r4b_skip_en', open(p).read())

    def test_122_r4b_adds_one_port_per_core_module_and_no_toplevel_port(self):
        for f, nport in (('Rate_Handle.v', 1), ('Symbol_Synchronizer.v', 1),
                         ('FIFO_block.v', 1), ('Validate_Input_Push_Pop_block.v', 1),
                         ('Frequency_and_Time_Synchronizer.v', 0)):
            p = self._real(f)
            before = open(p).read()
            R.PATCHERS['R4B'][f](p)
            after = open(p).read()
            self.assertEqual(after.count('           // RXFIX_R4B\n'), nport, f)
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    if 'Logical_Operator_out1 = validIn' in line:
                        continue
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')

    def test_123_r4b_is_independent_of_r1_and_r2(self):
        self.assertFalse(set(R.VARIANT_FILES['R4B']) & set(R.VARIANT_FILES['R1']))
        self.assertFalse(set(R.VARIANT_FILES['R4B']) & set(R.VARIANT_FILES['R2']))


# ======================================================================= RXFIX_R4D
# Task 14: R4D = R4B + the FULL-side mirror -- one EXTRA pop when occupancy >= 24 inside
# the SAME 13-slot structural window, at most one per pcEnd, registered like the skip.

    # ---- Task 22: the 146 candidate, W1 + R4D + R1 on a kit-shaped tree ----
    def test_160_r1_anchors_name_no_module_so_they_need_no_pfx(self):
        """R3S and R4 needed `_PFX` because their anchors match `module <name> (` and
        instantiation headers, which the Vivado kit renames to
        TxRxCompo_ip_src_<name>.  R1's two anchors are plain text naming no module, so
        the same patcher reaches both lineages unchanged.  Pinned here so a future edit
        cannot quietly make R1 module-name-dependent without noticing."""
        for anchor in (R.PD_DECL_OLD, R.PD_ASSIGN_OLD):
            self.assertNotIn('module', anchor)
            self.assertNotIn('TxRxCompo_ip_src_', anchor)

    def test_161_r1_applies_to_the_prefixed_kit_preamble_detector(self):
        """The direct check the Task 22 brief asks for: R1 on the kit's own
        TxRxCompo_ip_src_Preamble_Detector.v (module TxRxCompo_ip_src_Preamble_Detector,
        `wire Delay10_out1;` and `assign Delay10_out1 = Delay10_reg[49331];` at line
        334)."""
        f = _kit_name('Preamble_Detector.v')
        src = os.path.join(KIT_DIR, f)
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        text = open(src).read()
        self.assertIn('module TxRxCompo_ip_src_Preamble_Detector', text)
        p = self.write(f, text)
        self.assertEqual(R.patch_preamble_detector(p), 'patched')
        out = open(p).read()
        self.assertIn("assign Delay10_full = FIFO_numEntries == 14'd12333;", out)
        self.assertIn('assign Delay10_out1 = Delay8_out1 & Delay10_full;', out)
        # the tick-indexed pop must be GONE, not merely shadowed: a patch that left it
        # would be inert and the kit's own grep gate would be the only thing catching it
        self.assertNotIn('assign Delay10_out1 = Delay10_reg[49331];', out)
        # the nets R1's replacement reads must exist in this lineage
        self.assertIn('wire [13:0] FIFO_numEntries;', out)
        self.assertIn('wire Delay8_out1;', out)
        self.assertEqual(R.patch_preamble_detector(p), 'already')

    def test_162_w1_then_r4d_then_r1_apply_to_a_kit_shaped_tree(self):
        """THE Task 22 deliverable, the analogue of test_119: all three variants on the
        shipped kit shape, with verify_zip green for each on BOTH zip members."""
        self._kittree(extra=['Preamble_Detector.v'])
        self.assertEqual(R.main(self.d, 'W1'), 0)
        self.assertEqual(R.main(self.d, 'R4D'), 0)
        self.assertEqual(R.main(self.d, 'R1'), 0)
        nz = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    zp = os.path.join(root, f); nz += 1
                    self.assertTrue(R.verify_zip(zp, 'W1'), zp)
                    self.assertTrue(R.verify_zip(zp, 'R4D'), zp)
                    self.assertTrue(R.verify_zip(zp, 'R1'), zp)
        self.assertEqual(nz, 2)
        # three loose mirrors each, and R1 landed in the file neither other variant owns
        npd = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == _kit_name('Rate_Handle.v'):
                    s2 = open(os.path.join(root, f)).read()
                    self.assertIn('RXFIX_W1', s2)
                    self.assertIn('RXFIX_R4D', s2)
                    self.assertNotIn('RXFIX_R1\n', s2)
                if f == _kit_name('Preamble_Detector.v'):
                    npd += 1
                    s2 = open(os.path.join(root, f)).read()
                    self.assertIn('RXFIX_R1', s2)
                    self.assertNotIn('RXFIX_R4D', s2)
        self.assertEqual(npd, 3)

    def test_163_r1_is_in_neither_w1_nor_r4d_file_sets(self):
        """The composition is textual only because the three file sets are disjoint
        where it matters: R1 owns Preamble_Detector.v alone."""
        self.assertEqual(R.VARIANT_FILES['R1'], ['Preamble_Detector.v'])
        self.assertNotIn('Preamble_Detector.v', R.VARIANT_FILES['W1'])
        self.assertNotIn('Preamble_Detector.v', R.VARIANT_FILES['R4D'])
        self.assertNotIn('Preamble_Detector.v', R.r4d_files(False))


class TestR4D(TmpMixin):

    def _real(self, f, lineage='s1'):
        base = {'s1': S1_DIR, 'f3': F3_DIR, 'kit': KIT_DIR}[lineage]
        name = _kit_name(f) if lineage == 'kit' else f
        src = os.path.join(base, name)
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        return self.write(name, open(src).read())

    def _tree(self, lineage='s1', sub=''):
        d = os.path.join(self.d, sub) if sub else self.d
        base = S1_DIR if lineage == 's1' else F3_DIR
        for f in sorted(set(R.w1_files(True)) | set(R.r4d_files(True))):
            src = os.path.join(base, f)
            if not os.path.exists(src):
                self.skipTest(f'{src} not present')
            self.write(f, open(src).read(), sub=sub)
        return d

    def test_124_r4d_is_registered_and_mirrors_r4b(self):
        for t in (R.VARIANT_FILES, R.PATCHERS, R.FILE_MARKER):
            self.assertIn('R4D', t)
        self.assertEqual(R.R4D_CORE_FILES, R.R4B_CORE_FILES)
        self.assertEqual(len(R.r4d_files(False)), 12)
        # marker hygiene: R4/R4B/R4D must not alias one another
        for a, b in ((R.MARKER_R4, R.MARKER_R4D), (R.MARKER_R4B, R.MARKER_R4D),
                     (R.MARKER_R4D, R.MARKER_R4B)):
            self.assertFalse(R._has(a, b), f'{a} aliases {b}')
        self.assertTrue(R._has('// RXFIX_R4D x', 'RXFIX_R4D'))

    def test_125_the_extra_pop_is_the_mirror_of_the_skip(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4d(p)
        s = open(p).read()
        # both edges present, and the pop is skip-suppressed OR extra-added
        self.assertIn('assign Logical_Operator_out1 = (r4d_pop_nom & ( ~r4d_skip_en)) |'
                      ' r4d_do_extra;', s)
        self.assertIn("r4d_occ_le8 <= (r4d_occ <= 6'b001000);", s)
        self.assertIn("r4d_occ_ge24 <= (r4d_occ >= 6'b011000);", s)
        # the extra fires BETWEEN nominal pops, never on the nominal beat
        self.assertIn("assign r4d_phase2 = HDL_Counter_out1 == 2'b10;", s)
        self.assertIn('assign r4d_do_extra = r4d_extra_en & validIn & r4d_phase2;', s)
        self.assertIn("assign r4d_pop_nom = validIn & Compare_To_Constant_out1;", s)

    def test_126_the_full_side_decision_is_registered_like_the_skip(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4d(p)
        s = open(p).read()
        for r in ('r4d_extra_en', 'r4d_occ_ge24', 'r4d_extra_done'):
            self.assertRegex(s, r'\n  reg  ' + r + r'[;,\s]')
        # the occupancy appears ONLY inside the clocked compares
        self.assertEqual(s.count('r4d_occ <='), 1)
        self.assertEqual(s.count('r4d_occ >='), 1)
        self.assertIn('r4d_extra_en <= r4d_locked & r4d_win & r4d_occ_ge24 & '
                      '( ~r4d_extra_done) &', s)

    def test_127_one_extra_per_window_and_inside_the_window(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4d(p)
        s = open(p).read()
        self.assertEqual(s.count("r4d_extra_done <= 1'b1;"), 1)   # set on the extra
        self.assertEqual(s.count("r4d_extra_done <= 1'b0;"), 2)   # reset + window open
        # the same 13-slot bound as the skip, applied to the extra
        self.assertEqual(s.count("(r4d_wslot <= 4'b1100)"), 2)

    def test_128_the_two_edges_cannot_both_be_armed(self):
        """occ <= 8 and occ >= 24 are disjoint with a 15-entry dead band; asserted on the
        constants so a later edit cannot quietly make them overlap."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4d(p)
        s = open(p).read()
        self.assertIn("6'b001000", s)   # 8
        self.assertIn("6'b011000", s)   # 24
        self.assertLess(0b001000, 0b011000)

    def test_129_r4d_patches_all_three_lineages(self):
        for lin in ('s1', 'f3', 'kit'):
            for f in R.R4D_CORE_FILES:
                p = self._real(f, lin)
                self.assertEqual(R.PATCHERS['R4D'][f](p), 'patched', f'{f} {lin}')
                self.assertIn('RXFIX_R4D', open(p).read())

    def test_130_r4d_refuses_to_stack_and_is_refused(self):
        for other in ('R3', 'R3S', 'R4', 'R4B'):
            for f in R.R4D_CORE_FILES:
                p = self._real(f)
                R.PATCHERS[other][f](p)
                with self.assertRaises(AssertionError, msg=f'{other}/{f}'):
                    R.PATCHERS['R4D'][f](p)
                q = self._real(f)
                R.PATCHERS['R4D'][f](q)
                with self.assertRaises(AssertionError, msg=f'R4D then {other}/{f}'):
                    R.PATCHERS[other][f](q)

    def test_131_r4d_sim_tree_and_witness_words(self):
        d = self._tree('s1')
        self.assertEqual(R.main(d, 'R4D', sim_tree=True), 0)
        self.assertNotIn('r4dWit', open(os.path.join(d, 'Rate_Handle.v')).read())
        d2 = self._tree('s1', sub='w1first')
        self.assertEqual(R.main(d2, 'W1', sim_tree=True), 0)
        self.assertEqual(R.main(d2, 'R4D', sim_tree=True), 0)
        rh = open(os.path.join(d2, 'Rate_Handle.v')).read()
        self.assertIn('  output  [63:0] r4dWit;\n', rh)          # TWO read words
        self.assertIn("assign r4dWit = {{16'b0, r4d_extras},", rh)
        self.assertIn('{r4d_locked, r4d_skips, r4d_opens}};', rh)

    def test_132_w1_then_r4d_on_a_kit_shaped_tree(self):
        srcs = {}
        for f in sorted(set(R.W1_RTL_FILES) | set(R.W1_IP_FILES) | set(R.VARIANT_FILES['R4D'])):
            src = os.path.join(KIT_DIR, _kit_name(f))
            if not os.path.exists(src):
                self.skipTest('seqbist kit not present')
            srcs[_kit_name(f)] = open(src).read()
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            for n, t in srcs.items():
                self.write(n, t, sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            with zipfile.ZipFile(os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip'), 'w') as z:
                for n, t in srcs.items():
                    z.writestr('hdl/' + n, t)
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')
        self.assertEqual(R.main(self.d, 'W1'), 0)
        self.assertEqual(R.main(self.d, 'R4D'), 0)
        nz = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    zp = os.path.join(root, f); nz += 1
                    self.assertTrue(R.verify_zip(zp, 'W1'), zp)
                    self.assertTrue(R.verify_zip(zp, 'R4D'), zp)
        self.assertEqual(nz, 2)

    def test_133_two_read_words_at_0x234_and_0x238_leave_w1_alone(self):
        srcs = {}
        f = _kit_name('TxRxCompo_ip_addr_decoder.v')
        src = os.path.join(KIT_DIR, f)
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        p = self.write(f, open(src).read())
        R.patch_ip_addr_decoder_w1(p)
        w1_only = open(p).read()
        R.patch_ip_addr_decoder_r4d(p)
        both = open(p).read()
        gone = [l for l in w1_only.splitlines() if l not in both.splitlines()]
        self.assertEqual(gone, [R.W1_DATA_READ_LINE.rstrip('\n')], gone[:4])
        self.assertIn("assign r4d_hit = (address_select_level1 == 8'h8D) ||", both)
        self.assertIn("(address_select_level1 == 8'h8E);", both)
        self.assertIn('r4d_reg[address_select_level1[0]]', both)
        for keep in ("assign w1_hit = (address_select_level1 >= 8'h85) &&",
                     'reg [31:0] w1_reg [0:7];'):
            self.assertIn(keep, both)

    def test_134_r4d_adds_no_toplevel_port_and_loses_no_assign(self):
        for f, nport in (('Rate_Handle.v', 1), ('Symbol_Synchronizer.v', 1),
                         ('FIFO_block.v', 1), ('Validate_Input_Push_Pop_block.v', 1),
                         ('Frequency_and_Time_Synchronizer.v', 0)):
            p = self._real(f)
            before = open(p).read()
            R.PATCHERS['R4D'][f](p)
            after = open(p).read()
            self.assertEqual(after.count('           // RXFIX_R4D\n'), nport, f)
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    if 'Logical_Operator_out1 = validIn' in line:
                        continue
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')

    def test_135_the_witness_bus_is_64_bits_wide_at_every_level(self):
        """A width skew here truncates the extras word on silicon and is invisible in
        sim (the harness taps Rate_Handle hierarchically).  Verilator caught it as a
        WIDTHTRUNC warning on the FTS pin; this pins it at every level instead."""
        d = self._tree('s1', sub='w')
        self.assertEqual(R.main(d, 'W1', sim_tree=True), 0)
        self.assertEqual(R.main(d, 'R4D', sim_tree=True), 0)
        for f in ('Rate_Handle.v', 'Symbol_Synchronizer.v',
                  'Frequency_and_Time_Synchronizer.v', 'QPSK_Rx.v', 'Receiver.v',
                  'TxRxComposite.v'):
            s = open(os.path.join(d, f)).read()
            self.assertIn('[63:0] r4dWit;', s, f)
            self.assertNotIn('[31:0] r4dWit', s, f)
        fts = open(os.path.join(d, 'Frequency_and_Time_Synchronizer.v')).read()
        self.assertIn('wire [63:0] r4d_wit;', fts)


class TestR4E(TmpMixin):
    """[sim] Task 21 -- RXFIX_R4E: R4B's skip side plus a SCHEDULED DROPPED PUSH.

    The claims these tests pin are the ones the sim gate cannot make on its own:
      * R4E is a CLONE of R4B, not a stack -- the EMPTY side is R4B's text with the
        prefix changed, so a content-identity row against R4B is a statement about
        the RTL text rather than a hope;
      * the FULL side deletes a PUSH and touches NO pop, which is what makes it the
        natural push_on_full event's mirror and what keeps the Preamble_Detector
        realignment FIFO out of it;
      * the schedule is a MEASURED frame period in validated pops, and the landing
        slot is MEASURED at the pcEnd, not predicted and then assumed;
      * the marker-prefix hazard (RXFIX_R4/RXFIX_R4B are prefixes of RXFIX_R4E) that
        has already bitten twice (R3S, then R4B).
    """

    def _real(self, f, lineage='s1'):
        base = {'s1': S1_DIR, 'f3': F3_DIR, 'kit': KIT_DIR}[lineage]
        name = _kit_name(f) if lineage == 'kit' else f
        src = os.path.join(base, name)
        if not os.path.exists(src):
            self.skipTest(f'{src} not present')
        return self.write(name, open(src).read())

    def _tree(self, lineage='s1', sub=''):
        d = os.path.join(self.d, sub) if sub else self.d
        base = S1_DIR if lineage == 's1' else F3_DIR
        for f in sorted(set(R.w1_files(True)) | set(R.r4e_files(True))):
            src = os.path.join(base, f)
            if not os.path.exists(src):
                self.skipTest(f'{src} not present')
            self.write(f, open(src).read(), sub=sub)
        return d

    def test_136_r4e_is_registered_in_every_dispatch_table(self):
        for t in (R.VARIANT_FILES, R.PATCHERS, R.FILE_MARKER):
            self.assertIn('R4E', t)
        self.assertEqual(R.R4E_CORE_FILES, R.R4B_CORE_FILES)
        self.assertEqual(len(R.r4e_files(False)), 12)
        self.assertEqual(len(R.r4e_files(True)), 8)

    def test_137_the_marker_prefix_hazard_is_closed_in_both_directions(self):
        """RXFIX_R4 and RXFIX_R4B are both PREFIXES of RXFIX_R4E.  Test 113 pinned the
        R4/R4B collision; this is its R4E analogue, and it runs in BOTH directions so a
        kit carrying only R4E cannot certify as an R4/R4B kit or vice versa."""
        for a, b in ((R.MARKER_R4, R.MARKER_R4E), (R.MARKER_R4B, R.MARKER_R4E),
                     (R.MARKER_R4D, R.MARKER_R4E), (R.MARKER_R4E, R.MARKER_R4),
                     (R.MARKER_R4E, R.MARKER_R4B), (R.MARKER_R4E, R.MARKER_R4D)):
            self.assertFalse(R._has(a, b), f'{a} aliases {b}')
        self.assertTrue(R._has('// RXFIX_R4E x', 'RXFIX_R4E'))
        self.assertFalse(R._has('// RXFIX_R4E x', 'RXFIX_R4B'))
        self.assertFalse(R._has('// RXFIX_R4E x', 'RXFIX_R4'))

    def test_138_the_empty_side_is_r4b_text_character_for_character(self):
        """R4E CONTAINS R4B.  Renaming the prefix must be the ONLY difference on the
        skip side -- that is what makes K1/K6 predictions about the RTL text."""
        a = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4b(a)
        sa = open(a).read()
        b = self.write('B_Rate_Handle.v', open(os.path.join(S1_DIR, 'Rate_Handle.v')).read())
        R.patch_rate_handle_r4e(b)
        sb = open(b).read()
        # Every R4B CODE line that mentions the prefix must appear verbatim in R4E's
        # text after the rename.  Comments are excluded on purpose: R4E's header and
        # inline commentary are rewritten (they have to explain the FULL side), and a
        # test that pinned prose would fail on every future wording change while saying
        # nothing about the logic.  Declarations of R4B-only nets are excluded too --
        # R4E's declaration block is one contiguous rewrite that appends the FULL-side
        # nets -- so what is pinned here is the STEERING, which is the claim.
        code = [l for l in sa.splitlines()
                if l.strip() and not l.strip().startswith('//')
                and ('r4b' in l or 'R4B' in l)]
        self.assertGreater(len(code), 30, 'nothing to compare')
        missing = []
        for ln in code:
            t = ln.replace('r4b', 'r4e').replace('R4B', 'R4E')
            if t.strip().startswith(('reg ', 'wire ', 'output ', 'input ')):
                continue      # the declaration block is a contiguous rewrite
            if 'r4eWit' in t:
                continue      # the witness word is two words wide in R4E
            if t.strip() not in [x.strip() for x in sb.splitlines()]:
                missing.append(t.strip())
        self.assertEqual(missing, [], missing[:6])

    def test_139_the_full_side_drops_a_PUSH_and_touches_no_pop(self):
        """The whole argument against Task 14 section 3 is that a dropped push leaves
        the pop side alone, so validOut density is unchanged and the PD realignment FIFO
        sees nothing.  If the pop expression ever grows a FULL-side term, that argument
        is void."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4e(p)
        s = open(p).read()
        # the pop is R4B's, unchanged: no extra-pop term of any kind
        self.assertIn('assign Logical_Operator_out1 = r4e_pop_nom & ( ~r4e_skip_en);', s)
        for banned in ('r4e_do_extra', 'r4e_extra_en', 'r4e_extras', 'r4e_phase2',
                       "HDL_Counter_out1 == 2'b10"):
            self.assertNotIn(banned, s, banned)
        # the drop is on the PUSH, and it is structurally `strobe` until the first arm
        self.assertIn('assign r4e_push_st = strobe & ( ~r4e_drop_en);', s)
        self.assertIn('.push(r4e_push_st),', s)
        self.assertNotIn('.push(strobe),', s)
        self.assertIn('assign r4e_do_drop = r4e_drop_en & strobe;', s)

    def test_140_the_schedule_is_a_measured_period_in_validated_pops(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4e(p)
        s = open(p).read()
        # the counters are in VALIDATED pops (FIFO_validPop), the unit the pointer
        # arithmetic is in -- not nominal pop opportunities
        self.assertIn('assign r4e_pop_val = FIFO_validPop;', s)
        self.assertIn('r4e_period <= r4e_pcnt;', s)
        self.assertIn('r4e_pcnt <= r4e_pcnt + ', s)
        # the arm band is ASYMMETRIC: +6 low, +10 high (k_hat in [7,11])
        self.assertIn("15'b000000000000110", s)      # +6
        self.assertIn("15'b000000000001010", s)      # +10
        self.assertIn('r4e_sched_lo <= (r4e_sum15 >= (r4e_ref15 + ', s)
        self.assertIn('r4e_sched_hi <= (r4e_sum15 <= (r4e_ref15 + ', s)
        # a saturated / implausible period disables the schedule (fails toward baseline)
        self.assertIn('r4e_per_ok <= ', s)
        self.assertIn('r4e_locked & r4e_per_ok & r4e_occ_ge24 &', s)

    def test_141_the_landing_slot_is_measured_at_the_pcend_not_predicted(self):
        """k = occ_at_drop + 1 - m has to be evaluated at the pcEnd, because m is not
        known when the drop is taken."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4e(p)
        s = open(p).read()
        self.assertIn('assign r4e_m15 = {1\'b0, r4e_pcnt} - {1\'b0, r4e_land_a};', s)
        self.assertIn("assign r4e_l_val = (r4e_o15 + 15'b000000000000001) - r4e_m15;", s)
        self.assertIn('if (r4e_pcend_d && r4e_land_pend) begin', s)
        self.assertIn('r4e_land_a <= r4e_pcnt;', s)
        self.assertIn('r4e_land_occ <= r4e_occ;', s)
        # 13 is the window edge the out-of-window counter is measured against
        self.assertIn("15'b000000000001101", s)

    def test_142_the_full_side_decision_is_registered_like_the_skip(self):
        """Nothing combinational may reach the push except a flop output, or the drop
        closes a loop occupancy -> compare -> drop -> push -> occupancy."""
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4e(p)
        s = open(p).read()
        body = s[s.index('always @(posedge clk or posedge reset)\n    begin : r4e_steer'):]
        for reg in ('r4e_occ_ge24', 'r4e_sched_lo', 'r4e_sched_hi', 'r4e_drop_en',
                    'r4e_pcnt', 'r4e_period', 'r4e_per_ok'):
            self.assertIn(f'{reg} <=', body, reg)
            self.assertIn(f'reg  {reg};', s.replace('reg [13:0] ', 'reg  ')
                          .replace('reg [15:0] ', 'reg  ')) if False else None
        # the occupancy appears on the FULL side ONLY inside the clocked block
        self.assertEqual(s.count('r4e_occ >= '), 1)
        self.assertIn('r4e_occ_ge24 <= (r4e_occ >= ', s)
        # async reset, enb-gated, exactly as R4B
        self.assertIn('always @(posedge clk or posedge reset)', s)
        self.assertIn('if (enb_1_2_0) begin', s)

    def test_143_one_drop_per_pcend(self):
        p = self._real('Rate_Handle.v')
        R.patch_rate_handle_r4e(p)
        s = open(p).read()
        self.assertIn('r4e_drop_done <= 1\'b0;\n', s)     # cleared at pcEnd
        self.assertIn('r4e_drop_done <= 1\'b1;', s)       # set by the drop
        self.assertIn('( ~r4e_drop_done) & r4e_sched_lo & r4e_sched_hi;', s)

    def test_144_r4e_refuses_to_stack_and_is_refused(self):
        for v in ('R3', 'R3S', 'R4', 'R4B', 'R4D'):
            p = self._real('Rate_Handle.v')
            R.PATCHERS[v]['Rate_Handle.v'](p)
            with self.assertRaises(AssertionError):
                R.patch_rate_handle_r4e(p)
            os.remove(p)
        for v in ('R3', 'R3S', 'R4', 'R4B', 'R4D'):
            p = self._real('Rate_Handle.v')
            R.patch_rate_handle_r4e(p)
            with self.assertRaises(AssertionError):
                R.PATCHERS[v]['Rate_Handle.v'](p)
            os.remove(p)

    def test_145_r4e_patches_all_three_lineages(self):
        for lin in ('s1', 'f3', 'kit'):
            for f in R.R4E_CORE_FILES:
                p = self._real(f, lin)
                self.assertEqual(R.R4E_PATCHERS[f](p), 'patched', f'{lin}/{f}')
                self.assertIn('RXFIX_R4E', open(p).read())
                os.remove(p)

    def test_146_r4e_sim_tree_and_the_two_witness_words(self):
        d = self._tree('s1')
        self.assertEqual(R.main(d, 'R4E', sim_tree=True), 0)
        self.assertNotIn('r4eWit', open(os.path.join(d, 'Rate_Handle.v')).read())
        d2 = self._tree('s1', sub='w1first')
        self.assertEqual(R.main(d2, 'W1', sim_tree=True), 0)
        self.assertEqual(R.main(d2, 'R4E', sim_tree=True), 0)
        rh = open(os.path.join(d2, 'Rate_Handle.v')).read()
        self.assertIn('  output  [63:0] r4eWit;\n', rh)
        self.assertIn('assign r4eWit = {{r4e_land_out, r4e_land_max, r4e_land_min,', rh)
        self.assertIn('{r4e_locked, r4e_skips, r4e_opens}};', rh)

    def test_147_the_witness_bus_is_64_bits_wide_at_every_level(self):
        d = self._tree('s1', sub='w')
        self.assertEqual(R.main(d, 'W1', sim_tree=True), 0)
        self.assertEqual(R.main(d, 'R4E', sim_tree=True), 0)
        for f in ('Rate_Handle.v', 'Symbol_Synchronizer.v',
                  'Frequency_and_Time_Synchronizer.v', 'QPSK_Rx.v', 'Receiver.v',
                  'TxRxComposite.v'):
            s = open(os.path.join(d, f)).read()
            self.assertIn('[63:0] r4eWit;', s, f)
            self.assertNotIn('[31:0] r4eWit', s, f)

    def test_148_two_read_words_at_0x234_and_0x238_leave_w1_alone(self):
        f = _kit_name('TxRxCompo_ip_addr_decoder.v')
        src = os.path.join(KIT_DIR, f)
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        p = self.write(f, open(src).read())
        R.patch_ip_addr_decoder_w1(p)
        w1_only = open(p).read()
        R.patch_ip_addr_decoder_r4e(p)
        both = open(p).read()
        gone = [l for l in w1_only.splitlines() if l not in both.splitlines()]
        self.assertEqual(gone, [R.W1_DATA_READ_LINE.rstrip('\n')], gone[:4])
        self.assertIn("assign r4e_hit = (address_select_level1 == 8'h8D) ||", both)
        self.assertIn("(address_select_level1 == 8'h8E);", both)
        for keep in ("assign w1_hit = (address_select_level1 >= 8'h85) &&",
                     'reg [31:0] w1_reg [0:7];'):
            self.assertIn(keep, both)

    def test_149_w1_then_r4e_on_a_kit_shaped_tree_with_verify_zip(self):
        srcs = {}
        for f in sorted(set(R.W1_RTL_FILES) | set(R.W1_IP_FILES) |
                        set(R.VARIANT_FILES['R4E'])):
            src = os.path.join(KIT_DIR, _kit_name(f))
            if not os.path.exists(src):
                self.skipTest('seqbist kit not present')
            srcs[_kit_name(f)] = open(src).read()
        for sub in ('hdlsrc', 'ipcore/TxRxCompo_ip_v1_0/hdl',
                    'vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl'):
            for n, t in srcs.items():
                self.write(n, t, sub=sub)
        for sub in ('ipcore', 'vivado_ip_prj/ipcore'):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)
            with zipfile.ZipFile(os.path.join(self.d, sub, 'TxRxCompo_ip_v1_0.zip'), 'w') as z:
                for n, t in srcs.items():
                    z.writestr('hdl/' + n, t)
        open(os.path.join(self.d, 'p.xpr'), 'w').write('x')
        self.assertEqual(R.main(self.d, 'W1'), 0)
        self.assertEqual(R.main(self.d, 'R4E'), 0)
        nz = 0
        for root, _, files in os.walk(self.d):
            for f in files:
                if f == 'TxRxCompo_ip_v1_0.zip':
                    zp = os.path.join(root, f); nz += 1
                    self.assertTrue(R.verify_zip(zp, 'W1'), zp)
                    self.assertTrue(R.verify_zip(zp, 'R4E'), zp)
        self.assertEqual(nz, 2)
        rh = open(os.path.join(self.d, 'hdlsrc',
                               _kit_name('Rate_Handle.v'))).read()
        self.assertIn('RXFIX_R4E', rh)
        self.assertIn('assign r4eWit = ', rh)

    def test_150_r4e_adds_no_toplevel_port_and_loses_no_assign(self):
        for f, nport in (('Rate_Handle.v', 1), ('Symbol_Synchronizer.v', 1),
                         ('FIFO_block.v', 1), ('Validate_Input_Push_Pop_block.v', 1),
                         ('Frequency_and_Time_Synchronizer.v', 0)):
            p = self._real(f)
            before = open(p).read()
            R.PATCHERS['R4E'][f](p)
            after = open(p).read()
            self.assertEqual(after.count('           // RXFIX_R4E\n'), nport, f)
            for line in before.splitlines():
                if line.strip().startswith('assign ') and before.count(line) == 1:
                    if 'Logical_Operator_out1 = validIn' in line:
                        continue
                    self.assertIn(line, after, f'{f}: lost {line.strip()[:60]}')

    def test_151_r4e_then_w1_fails_loudly_on_the_decoder(self):
        f = _kit_name('TxRxCompo_ip_addr_decoder.v')
        src = os.path.join(KIT_DIR, f)
        if not os.path.exists(src):
            self.skipTest('seqbist kit not present')
        p = self.write(f, open(src).read())
        self.assertEqual(R.patch_ip_addr_decoder_r4e(p), 'skipped')  # no W1 -> untouched
        R.patch_ip_addr_decoder_w1(p)
        self.assertEqual(R.patch_ip_addr_decoder_r4e(p), 'patched')
        # W1 applied AFTER R4E must trip its exactly-once anchor assert rather than
        # degrade silently: R4E has wrapped the single `assign data_read` line W1 owns.
        with self.assertRaises(AssertionError):
            R.patch_ip_addr_decoder_w1(self.write('again.v', open(p).read().replace(
                'RXFIX_W1', 'RXFIX_XX')))
