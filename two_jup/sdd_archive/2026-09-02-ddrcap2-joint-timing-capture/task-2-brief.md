### Task 2: Injector part 2 — threading FTS → QPSK_Rx → Receiver → Composite, ch2/ch3 packing, sel 12–15, zips, main

**Files:**
- Modify: `two_jup/skidfix/ddrcap2_inject.py` (append)
- Modify: `two_jup/tests/test_ddrcap2_inject.py` (append)
- Test: full-tree patch on a scratch copy + Verilator lint of `TxRxComposite`; idempotency; zip verify on a copy of one `TxRxCompo_ip_v1_0.zip`

**Interfaces:**
- Consumes: Task 1 tables/helpers.
- Produces: `FTS_PORTS`, `RX_PORTS` (= `ddrcap_`+FTS names), `patch_fts`, `patch_qpsk_rx`, `patch_receiver`, `patch_composite`, `patch_zip`, `verify_zip`, `main(dir)`; CLI `ddrcap2_inject.py <dir>` printing `DDRCAP2_INJECT ...` and exit 0/1. Composite guard string `ddrcap2_slot_r`. Wire names at Composite: `Receiver_ddrcap_dc_<x>`.

- [ ] **Step 1: Append the failing tests**

```python
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
```

- [ ] **Step 2: Run → the two new tests fail (`patch_fts` undefined).**

- [ ] **Step 3: Append the threading, composite, zip and main code**

```python
FTS_PORTS = PD_PORTS + [("dc_runmax", "signed [31:0]", "sfix32_En26")] + SS_PORTS + [
    ("dc_rhctr", "[7:0]", "uint8"), ("dc_rhpush", "[4:0]", "ufix5"), ("dc_rhpop", "[4:0]", "ufix5")]
RX_PORTS = [("ddrcap_" + n, w, t) for n, w, t in FTS_PORTS]


# ---------------------------------------------------------------- Frequency_and_Time_Synchronizer.v
def patch_fts(path):
    s = open(path).read()
    if 'dc_toff' in s:
        return 'already'
    pd_tail = ("                                         .pdWitB(pdWitB));")
    ss_tail = (".beatobsPop(Symbol_Synchronizer_beatobsPop)  // ufix5\n"
               "                                                               );")
    for need in (pd_tail, ss_tail, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n",
                 "  output  signed [31:0] fs_runmax;  // sfix32_En26\n",
                 "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                 "  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'pdWitB', [n for n, _, _ in FTS_PORTS])
    s = _insert_after(s, "  output  signed [31:0] fs_runmax;  // sfix32_En26\n", decl_lines(FTS_PORTS, 'output'))
    # local wires for the two child instances
    s = _insert_after(s, "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                      decl_lines(PD_PORTS, 'wire', 'Preamble_Detector_'))
    s = _insert_after(s, "  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8\n",
                      decl_lines(SS_PORTS, 'wire', 'Symbol_Synchronizer_'))
    pd_conn = "".join(f"                                         .{n}(Preamble_Detector_{n}),\n" for n, _, _ in PD_PORTS)
    s = s.replace(pd_tail, "                                         .pdWitB(pdWitB),\n" + pd_conn.rstrip().rstrip(',') + ");", 1)
    ss_conn = "".join(f"                                                               .{n}(Symbol_Synchronizer_{n}),\n" for n, _, _ in SS_PORTS)
    s = s.replace(ss_tail, ".beatobsPop(Symbol_Synchronizer_beatobsPop),  // ufix5\n" + ss_conn.rstrip().rstrip(',') +
                  "\n                                                               );", 1)
    assigns = "\n  // DDRCAP2 pass-through\n"
    for n, _, _ in PD_PORTS:
        assigns += f"  assign {n} = Preamble_Detector_{n};\n"
    assigns += "  assign dc_runmax = Preamble_Detector_fs_runmax;\n"
    for n, _, _ in SS_PORTS:
        assigns += f"  assign {n} = Symbol_Synchronizer_{n};\n"
    assigns += ("  assign dc_rhctr = Symbol_Synchronizer_beatobsRhCtr;\n"
                "  assign dc_rhpush = Symbol_Synchronizer_beatobsPush;\n"
                "  assign dc_rhpop = Symbol_Synchronizer_beatobsPop;\n")
    s = _insert_after(s, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n", assigns)
    assert '.dc_toff(Preamble_Detector_dc_toff)' in s and '.dc_mu(Symbol_Synchronizer_dc_mu)' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- QPSK_Rx.v
def patch_qpsk_rx(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    fts_anchor = "                                                                                      .p1c_telQ(Frequency_and_Time_Synchronizer_p1c_telQ),  // int16\n"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", fts_anchor,
                 "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n",
                      decl_lines(FTS_PORTS, 'wire', 'Frequency_and_Time_Synchronizer_'))
    conn = "".join(f"                                                                                      .{n}(Frequency_and_Time_Synchronizer_{n}),\n"
                   for n, _, _ in FTS_PORTS)
    s = s.replace(fts_anchor, fts_anchor + conn, 1)
    assigns = "\n  // DDRCAP2 pass-through\n" + "".join(
        f"  assign ddrcap_{n} = Frequency_and_Time_Synchronizer_{n};\n" for n, _, _ in FTS_PORTS)
    s = _insert_before_endmodule(s, assigns)
    assert 'assign ddrcap_dc_rhpop = Frequency_and_Time_Synchronizer_dc_rhpop;' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Receiver.v
def patch_receiver(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    inst_tail = ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart)\n                                      );"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", "  wire QPSK_Rx_ddrcap_fecstart;\n", inst_tail):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire QPSK_Rx_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'QPSK_Rx_'))
    conn = "".join(f"                                      .{n}(QPSK_Rx_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(inst_tail, ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                      );", 1)
    s = _insert_before_endmodule(s, "".join(f"  assign {n} = QPSK_Rx_{n};\n" for n, _, _ in RX_PORTS))
    assert s.count('ddrcap_dc_rhpop') == 4
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- TxRxComposite.v
COMPOSITE_PRE = """
  // DDRCAP2 (ddrcap2_inject.py): sidecar slot counter + sticky interpolator-underflow
  // latch, declared BEFORE the mux that reads ddrcap2_uf_now (Verilog use-before-declare).
  reg  [1:0] ddrcap2_slot_r;
  reg        ddrcap2_uf_latch;
  wire       ddrcap2_uf_now = Receiver_ddrcap_dc_underflow | ddrcap2_uf_latch;
"""
COMPOSITE_POST = """
  // DDRCAP2 ch2/ch3 packing (spec sec 2). Sticky-latch marker semantics unchanged:
  // ddrcap_demod_mark_now / ddrcap_fec_mark_now are the same nets as before, now one bit each.
  always @(posedge clk or posedge reset)
    begin : ddrcap2_slot_process
      if (reset == 1'b1) begin
        ddrcap2_slot_r <= 2'd0;
        ddrcap2_uf_latch <= 1'b0;
      end
      else if (enb_1_2_0) begin
        if (ddrcap_valid_beat) begin
          ddrcap2_slot_r <= ddrcap2_slot_r + 2'd1;
        end
        ddrcap2_uf_latch <= ddrcap_valid_beat ? 1'b0 : ddrcap2_uf_now;
      end
    end

  wire [13:0] ddrcap2_side =
      (ddrcap2_slot_r == 2'd0) ? Receiver_ddrcap_dc_heldts[13:0] :
      (ddrcap2_slot_r == 2'd1) ? Receiver_ddrcap_dc_tref[13:0] :
      (ddrcap2_slot_r == 2'd2) ? Receiver_ddrcap_dc_runmax[31:18] :
                                 Receiver_ddrcap_dc_corrthr[31:18];

  assign ddrcap_mark_demod = {ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]};
  assign ddrcap_mark_fec   = {ddrcap2_slot_r, ddrcap2_side};
"""
MUX_I_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n      16'sd0;"
MUX_I_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[31:16] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {ddrcap2_uf_now, 4'b0000, Receiver_ddrcap_dc_countreg[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_re[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhctr[7:0], Receiver_ddrcap_dc_rhpush[4:0], 3'b000} :\n"
             "      16'sd0;")
MUX_Q_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n      16'sd0;"
MUX_Q_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[15:0] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {5'b00000, Receiver_ddrcap_dc_mu[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_im[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhpop[4:0], 11'b00000000000} :\n"
             "      16'sd0;")
MUX_V_OLD = "      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n      1'b0;"
MUX_V_NEW = ("      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corrvalid :\n"
             "      (ddrcap_sel_r == 4'd13) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd14) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd15) ? enb_1_2_0 :\n"
             "      1'b0;")
OLD_MARKS = ("  assign ddrcap_mark_demod = ddrcap_demod_mark_now ? 16'h7FFF : 16'h0000;\n"
             "  assign ddrcap_mark_fec   = ddrcap_fec_mark_now   ? 16'h7FFF : 16'h0000;\n")


def patch_composite(path):
    s = open(path).read()
    if 'ddrcap2_slot_r' in s:
        return 'already'
    recv_tail = ".ddrcap_fecstart(Receiver_ddrcap_fecstart)\n                                        );"
    for need in ("  wire Receiver_ddrcap_fecstart;\n", recv_tail, MUX_I_OLD, MUX_Q_OLD, MUX_V_OLD, OLD_MARKS,
                 "  wire signed [15:0] ddrcap_mux_i =\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    assert s.count("(ddrcap_sel_r <= 4'd8) ?") == 3, 'expected exactly 3 sel<=8 conditions'
    s = _insert_after(s, "  wire Receiver_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'Receiver_'))
    conn = "".join(f"                                        .{n}(Receiver_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(recv_tail, ".ddrcap_fecstart(Receiver_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                        );", 1)
    s = s.replace("  wire signed [15:0] ddrcap_mux_i =\n", COMPOSITE_PRE + "\n  wire signed [15:0] ddrcap_mux_i =\n", 1)
    s = s.replace(MUX_I_OLD, MUX_I_NEW, 1).replace(MUX_Q_OLD, MUX_Q_NEW, 1).replace(MUX_V_OLD, MUX_V_NEW, 1)
    s = s.replace("(ddrcap_sel_r <= 4'd8) ?", "(ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12) ?")
    s = s.replace(OLD_MARKS, COMPOSITE_POST.lstrip('\n'), 1)
    assert s.count("ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12") == 3
    assert '.ddrcap_dc_toff(Receiver_ddrcap_dc_toff)' in s and 'ddrcap2_slot_process' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- dispatch / zip / main (mirrors ddrcap_inject.py)
PATCHERS = {
    'Interpolation_Control.v': patch_interpolation_control,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer,
    'Preamble_Detector.v': patch_preamble_detector,
    'Frequency_and_Time_Synchronizer.v': patch_fts,
    'QPSK_Rx.v': patch_qpsk_rx,
    'Receiver.v': patch_receiver,
    'TxRxComposite.v': patch_composite,
}


def _patcher_for(base):
    if base in PATCHERS:
        return PATCHERS[base]
    if base.startswith('TxRxCompo_ip_src_') and base[len('TxRxCompo_ip_src_'):] in PATCHERS:
        return PATCHERS[base[len('TxRxCompo_ip_src_'):]]
    return None


EXPECTED_ZIP_MEMBERS = {
    'TxRxCompo_ip_src_Interpolation_Control.v': 'countRegOut',
    'TxRxCompo_ip_src_Symbol_Synchronizer.v': 'dc_countreg',
    'TxRxCompo_ip_src_Preamble_Detector.v': 'dc_toff',
    'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v': 'dc_rhpop',
    'TxRxCompo_ip_src_QPSK_Rx.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_Receiver.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_TxRxComposite.v': 'ddrcap2_slot_r',
}


def patch_zip(zpath):
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r'); entries = []; n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        fn = _patcher_for(os.path.basename(item.filename))
        if fn is not None:
            tmp = zpath + '.ddrcap2_tmp'; os.makedirs(tmp, exist_ok=True)
            tp = os.path.join(tmp, os.path.basename(item.filename))
            open(tp, 'wb').write(data); status = fn(tp); data = open(tp, 'rb').read()
            os.remove(tp); os.rmdir(tmp); n += 1
            print(f"    zip member {os.path.basename(item.filename):50s} {status:8s}")
        entries.append((item, data))
    zin.close()
    out = io.BytesIO(); zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close(); open(zpath, 'wb').write(out.getvalue())
    return n


def verify_zip(zpath):
    zin = zipfile.ZipFile(zpath, 'r'); found = {}
    for item in zin.infolist():
        b = os.path.basename(item.filename)
        if b in EXPECTED_ZIP_MEMBERS:
            found[b] = zin.read(item.filename).decode()
    zin.close()
    ok = True
    for b, marker in EXPECTED_ZIP_MEMBERS.items():
        if b not in found or marker not in found[b]:
            print(f"    VERIFY_FAIL {zpath}: {b} missing or lacks {marker}"); ok = False
    return ok


def main(d):
    found = set()
    for root, _, files in os.walk(d):
        if root.endswith('.ddrcap2_tmp'):
            continue
        for f in files:
            fn = _patcher_for(f)
            if fn is None:
                continue
            p = os.path.join(root, f)
            print(f"  {f:45s} {fn.__name__:28s} -> {fn(p):8s} {p}")
            found.add(f)
    nz = nv = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                zp = os.path.join(root, f); nz += 1
                print(f"  zip {zp}"); patch_zip(zp)
                if verify_zip(zp):
                    nv += 1; print(f"    VERIFY_OK {zp}")
    logical = {'Interpolation_Control', 'Symbol_Synchronizer', 'Preamble_Detector',
               'Frequency_and_Time_Synchronizer', 'QPSK_Rx', 'Receiver', 'TxRxComposite'}
    got = {f.replace('TxRxCompo_ip_src_', '').replace('.v', '') for f in found}
    missing = sorted(logical - got)
    build_tree = any(os.path.basename(r) in ('ipcore', 'vivado_ip_prj') or any(x.endswith('.xpr') for x in fs)
                     for r, _, fs in os.walk(d))
    print(f"DDRCAP2_INJECT loose={len(found)} missing={missing} zips={nz} zips_verified={nv}")
    if missing or (build_tree and nz == 0) or (nz and nv != nz) or (nz not in (0, 2)):
        print("DDRCAP2_INJECT_FAIL"); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 4: Run the tests**

Run: `cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q`
Expected: 6 passed. Lint failures name the exact port/width mismatch; fix the anchor or width in the table, never the assert.

- [ ] **Step 5: Produce the sim netlist**

```bash
cd jupiter_240k5_byte/rtl_sim && NETLIST_ONLY=1 bash build_ddrcap2_sim.sh && \
grep -c "ddrcap_dc_" s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v
```
Expected: `DDRCAP2_INJECT ... missing=[] zips=0 zips_verified=0` and a count ≥ 60.

- [ ] **Step 6: Commit**

```bash
git add two_jup/skidfix/ddrcap2_inject.py two_jup/tests/test_ddrcap2_inject.py
git commit -s -m "DDRCAP2 injector part 2: thread timing/correlator/interpolator signals to TxRxComposite, ch2/ch3 packing, sel 12-15, zip patching

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

