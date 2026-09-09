#!/usr/bin/env python3
"""two_jup/tests/test_patch_seqbist.py -- SEQ-BIST T0b BD-patcher tests.

Pure TEXT tests: the patcher is a Tcl-source rewriter, so nothing here needs
Vivado, a board, or the RTL.  Each test copies the REAL kit's build_txfix.tcl
into a tmp dir, runs two_jup/skidfix/patch_seqbist_tcl.py on it, and asserts on
the result.

Covered:
  * idempotence -- a second run leaves the file byte-identical and prints NOOP
  * the expected BD cells / GPIO addresses appear exactly once per lineage
  * the build rails (IMPL_STRATEGY hook, routed-WNS gate, and the vendh
    IMPL_STRATEGY refusal) survive the patch
  * cnt_mux32 slots 0..15 keep EXACTLY the source-pin -> slot mapping that
    two_jup/sim_repro/resynth_probe4.tcl wired into cnt_mux16 on 148
  * slots 16..31 are rx_seq/cnt0..cnt15 in the Task-1 interface-contract order
  * the 148 patch adds no AXI slave (NUM_MI guard) and the vendh patch adds 3
  * the tx_checker / tx_starve TX-pin snoops are re-tapped after the
    traffic_gen delete+recreate on 148
  * the patcher refuses a wrong-lineage / anchorless / rail-less target

Run: python3 -m pytest two_jup/tests/test_patch_seqbist.py -v
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import pytest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PATCHER = os.path.join(REPO, "two_jup", "skidfix", "patch_seqbist_tcl.py")
KIT_SH = os.path.join(REPO, "two_jup", "skidfix", "jupiter_byte_seqbist_kit.sh")
PROBE4 = os.path.join(REPO, "two_jup", "sim_repro", "resynth_probe4.tcl")

KITS = {
    "148": os.path.join(REPO, "jupiter_byte_txfixF3_build", "build_txfix.tcl"),
    "vendh": os.path.join(REPO, "jupiter_byte_txfixF3vendh_build", "build_txfix.tcl"),
}


def run_patch(path, lineage, with_crc=None):
    cmd = [sys.executable, PATCHER, os.path.dirname(path), "--lineage", lineage]
    if with_crc is not None:
        cmd += ["--with-crc", str(with_crc)]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


@pytest.fixture(params=sorted(KITS))
def lineage(request):
    return request.param


@pytest.fixture
def kit(tmp_path, lineage):
    """A tmp dir holding a copy of the real kit's build_txfix.tcl."""
    src = KITS[lineage]
    if not os.path.isfile(src):
        pytest.skip("source kit missing: %s" % src)
    d = tmp_path / ("kit_" + lineage)
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    return dst


# --------------------------------------------------------------------------- #
# idempotence
# --------------------------------------------------------------------------- #

def test_patch_then_noop(kit, lineage):
    rc, out = run_patch(kit, lineage)
    assert rc == 0, out
    assert "SEQBIST_PATCH_OK" in out
    first = open(kit).read()

    rc, out = run_patch(kit, lineage)
    assert rc == 0, out
    assert "SEQBIST_PATCH_NOOP" in out
    assert open(kit).read() == first, "second run must be a byte-for-byte no-op"


def test_marker_once(kit, lineage):
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    assert txt.count("SEQBIST_PATCH_V1") == 2  # opening banner + closing banner
    assert txt.count("SEQBIST_WIRE_OK lineage=%s" % lineage) == 1


# --------------------------------------------------------------------------- #
# rails that must survive
# --------------------------------------------------------------------------- #

def test_build_rails_survive(kit, lineage):
    before = open(kit).read()
    assert run_patch(kit, lineage)[0] == 0
    after = open(kit).read()
    for guard in ("IMPL_STRATEGY", "TXFIX_ROUTED_WNS", "TXFIX_ROUTED_TIMING_FAIL",
                  "TXFIX_BUILD_DONE", "timing_gate.tcl", "bootgen"):
        assert after.count(guard) >= before.count(guard) >= 1, guard
    if lineage == "vendh":
        assert "TXFIX_VENDH_IMPL_STRATEGY_REFUSED" in after
        assert "ExtraNetDelay_high" in after
    else:
        assert "ExtraTimingOpt" in after


def test_block_inserted_after_anchor_and_before_generate_target(kit, lineage):
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    i_anchor = txt.index("report_ip_status -quiet")
    i_block = txt.index("=== SEQBIST: block-design patch")
    i_gen = txt.index("generate_target all [get_files system.bd]")
    i_save = txt.index("save_bd_design")
    assert i_anchor < i_block < i_save < i_gen, (i_anchor, i_block, i_save, i_gen)


# --------------------------------------------------------------------------- #
# cells / addresses per lineage
# --------------------------------------------------------------------------- #

def test_cells_appear(kit, lineage):
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    # module cells created exactly once, whatever the lineage
    for mod, inst in (("qpsk_traffic_gen_v2", "traffic_gen"),
                      ("rx_seq_checker", "rx_seq"),
                      ("cnt_mux32", "cnt_mux")):
        line = "create_bd_cell -type module -reference %s %s" % (mod, inst)
        assert txt.count(line) == 1, line
    # the three RTL files are added to the project sources
    assert txt.count("qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v") == 1


def test_addresses_148(tmp_path):
    src = KITS["148"]
    if not os.path.isfile(src):
        pytest.skip("148 kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "148")[0] == 0
    txt = open(dst).read()
    # 148 reuses the GPIOs already in the BD -> the patch assigns NO address and
    # creates NO axi_gpio, and it must guard NUM_MI against accidental growth.
    assert "assign_bd_address" not in txt.split("SEQBIST_PATCH_V1")[1].split("end SEQBIST")[0]
    assert "SEQBIST_FAIL(148) NUM_MI changed" in txt
    # the existing 4-bit select is widened to 5 bits, exactly once
    assert txt.count("CONFIG.DIN_FROM 31 CONFIG.DIN_TO 27") == 1
    assert "delete_bd_objs [get_bd_cells cnt_mux]" in txt
    assert "delete_bd_objs [get_bd_cells traffic_gen]" in txt


def test_tcl_block_is_rerunnable(kit, lineage):
    """Every create_bd_cell in the block must be guarded, so re-running the
    patched build_txfix.tcl against an already-patched project (a rebuild after
    a failed synth, Task 5's --dry -> real) does not hard-error."""
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    block = txt.split("SEQBIST_PATCH_V1", 1)[1].split("end SEQBIST", 1)[0]
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("create_bd_cell"):
            continue
        name = line.split()[-1]
        ctx = "\n".join(lines[:i + 1])
        assert ("get_bd_cells -quiet %s" % name) in ctx or "GPIO_EXISTS" in ctx, (
            "unguarded create of %s at line %d" % (name, i))
    # the vendh cross-lineage guard must probe 148-ONLY cells, never cells this
    # patch itself creates (that would refuse every re-run)
    if lineage == "vendh":
        guard = block.split("Cross-lineage guard", 1)[1].split("foreach c {", 1)[1].split("}", 1)[0]
        for c in ("traffic_gen ", "rx_seq ", "cnt_mux ", "tgen_ctrl_gpio"):
            assert c not in guard, (c, guard)
        assert "rx_checker" in guard


def test_addresses_vendh(tmp_path):
    src = KITS["vendh"]
    if not os.path.isfile(src):
        pytest.skip("vendh kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "vendh")[0] == 0
    txt = open(dst).read()
    calls = dict((m.group(1), m.group(2)) for m in
                 re.finditer(r"^sb_gpio (\S+) \S+ (0x[0-9A-Fa-f]+)\s*$", txt, re.M))
    assert calls == {"tgen_ctrl_gpio": "0x9D400000",
                     "tgen_rx_ctrl_gpio": "0x9D410000",
                     "tgen_rx_wit_gpio": "0x9D450000"}, calls
    # no tx_checker/txchk_gpio on 146 (tx_checker appears only in the
    # cross-lineage guard, which probes for it)
    assert "0x9D420000" not in txt
    assert "txchk_gpio" not in txt
    # exactly three new AXI slaves, and no partial set
    assert "partial GPIO set" in txt
    assert "$_sb_nmi0 + $_sb_gpio_added" in txt
    assert txt.count("create_bd_cell -type ip -vlnv $_sb_constdef sb_zero32") == 1


# --------------------------------------------------------------------------- #
# slot map
# --------------------------------------------------------------------------- #

SLOT_RE = re.compile(r"^sb_conn\s+(\S+)\s+cnt_mux/c(\d+)\s*$", re.M)
PROBE4_RE = re.compile(
    r"connect_bd_net(?:\s+-net\s+\[get_bd_nets -of_objects \[get_bd_pins (\S+?)\]\]"
    r"|\s+\[get_bd_pins (\S+?)\])\s+\[get_bd_pins cnt_mux/c(\d+)\]")


def probe4_slot_map():
    txt = open(PROBE4).read()
    m = {}
    for a, b, slot in PROBE4_RE.findall(txt):
        m[int(slot)] = a or b
    return m


def test_slots_0_15_unchanged_on_148(tmp_path):
    src = KITS["148"]
    if not os.path.isfile(src) or not os.path.isfile(PROBE4):
        pytest.skip("148 kit or resynth_probe4.tcl missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "148")[0] == 0

    ref = probe4_slot_map()
    assert set(ref) == set(range(16)), sorted(ref)
    got = {int(s): p for p, s in SLOT_RE.findall(open(dst).read())}
    for slot in range(16):
        assert got[slot] == ref[slot], (
            "slot %d wiring changed: %s (probe4: %s)" % (slot, got.get(slot), ref[slot]))


def test_slots_16_31_are_the_checker(kit, lineage):
    assert run_patch(kit, lineage)[0] == 0
    got = {int(s): p for p, s in SLOT_RE.findall(open(kit).read())}
    for i in range(16):
        assert got[16 + i] == "rx_seq/cnt%d" % i, (16 + i, got.get(16 + i))
    assert len([s for s in got if s >= 32]) == 0


def test_slots_0_15_tied_low_on_vendh(tmp_path):
    src = KITS["vendh"]
    if not os.path.isfile(src):
        pytest.skip("vendh kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "vendh")[0] == 0
    txt = open(dst).read()
    assert "for {set i 0} {$i < 16} {incr i} { sb_conn sb_zero32/dout cnt_mux/c$i }" in txt
    # no 148-only counter sources leaked into the vendh block
    for pin in ("traffic_gen_rx/acc_user", "rx_checker/frames", "tx_starve/ep_gt1k"):
        assert pin not in txt, pin


# --------------------------------------------------------------------------- #
# RTL port cross-check: the pin names the Tcl types vs the .v port lists
# --------------------------------------------------------------------------- #

RTL_DIR = os.path.join(REPO, "jupiter_240k5_byte", "rtl_sim")


def verilog_ports(path, module):
    """Return the set of port names in `module`'s ANSI port list."""
    txt = open(path).read()
    txt = re.sub(r"//[^\n]*", "", txt)
    # optional ANSI parameter list: module foo #( ... ) ( ports );
    m = re.search(r"\bmodule\s+%s\s*(?:#\s*\([^)]*\)\s*)?\((.*?)\)\s*;"
                  % re.escape(module), txt, re.S)
    assert m, "module %s not found in %s" % (module, path)
    ports = set()
    for decl in m.group(1).split(","):
        decl = decl.strip()
        if not decl:
            continue
        name = decl.split()[-1]
        # strip a leading direction/type/width prefix; the name is the last token
        ports.add(name)
    return ports


@pytest.mark.parametrize("lin", sorted(KITS))
def test_tcl_pin_names_match_the_rtl(tmp_path, lin):
    src = KITS[lin]
    for f in ("rx_seq_checker.v", "cnt_mux32.v", "qpsk_traffic_gen_v2.v"):
        if not os.path.isfile(os.path.join(RTL_DIR, f)):
            pytest.skip("Task-1 RTL not landed: %s" % f)
    if not os.path.isfile(src):
        pytest.skip("kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, lin)[0] == 0
    block = open(dst).read().split("SEQBIST_PATCH_V1", 1)[1].split("end SEQBIST", 1)[0]

    rtl = {
        "rx_seq": verilog_ports(os.path.join(RTL_DIR, "rx_seq_checker.v"), "rx_seq_checker"),
        "cnt_mux": verilog_ports(os.path.join(RTL_DIR, "cnt_mux32.v"), "cnt_mux32"),
        "traffic_gen": verilog_ports(
            os.path.join(RTL_DIR, "qpsk_traffic_gen_v2.v"), "qpsk_traffic_gen_v2"),
    }
    # contract sanity
    assert {"clk", "rst_n", "en", "freeze", "tgen_mode", "data", "valid", "user",
            "ready"} | {"cnt%d" % i for i in range(16)} == rtl["rx_seq"]
    assert {"clk", "sel", "q"} | {"c%d" % i for i in range(32)} == rtl["cnt_mux"]

    # every <cell>/<pin> the Tcl mentions for these three cells must be a real port
    bad = []
    for cell, ports in rtl.items():
        for pin in set(re.findall(r"\b%s/([A-Za-z_][A-Za-z0-9_]*)(?![\w$])" % cell, block)):
            if pin not in ports:
                bad.append("%s/%s" % (cell, pin))
    assert not bad, "Tcl references pins that do not exist in the RTL: %s" % sorted(bad)

    # and the pins the block wires by loop variable, spelled out
    for i in range(16):
        assert "cnt%d" % i in rtl["rx_seq"]
        assert "c%d" % (16 + i) in rtl["cnt_mux"]


# --------------------------------------------------------------------------- #
# control-bit map
# --------------------------------------------------------------------------- #

def test_control_bits(kit, lineage):
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    for name, bit in (("sb_freeze_slice", 3), ("sb_en_slice", 4), ("sb_mode_slice", 5)):
        line = "sb_bitslice %-15s tgen_rx_ctrl_gpio/gpio_io_o %d" % (name, bit)
        assert txt.count(line) == 1, line
    for dst in ("rx_seq/freeze", "rx_seq/en", "rx_seq/tgen_mode"):
        assert txt.count(dst) >= 1, dst


def test_tx_snoops_retapped_on_148(tmp_path):
    src = KITS["148"]
    if not os.path.isfile(src):
        pytest.skip("148 kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "148")[0] == 0
    txt = open(dst).read()
    assert "SEQBIST_TXSNOOP_RETAP_OK" in txt
    assert "SEQBIST_RETAP_OK captured=" in txt
    for pin in ("tx_checker/data", "tx_checker/valid", "tx_checker/first",
                "tx_checker/ready", "tx_starve/valid", "tx_starve/ready",
                "beat_ila/probe15"):
        assert pin in txt, pin


# --------------------------------------------------------------------------- #
# refusals
# --------------------------------------------------------------------------- #

def test_refuses_missing_file(tmp_path):
    rc, out = run_patch(str(tmp_path / "nope" / "build_txfix.tcl"), "148")
    assert rc == 1 and "SEQBIST_PATCH_FAIL" in out


def test_refuses_missing_anchor(tmp_path):
    d = tmp_path / "k"
    d.mkdir()
    p = str(d / "build_txfix.tcl")
    open(p, "w").write("open_project vivado_prj.xpr\nIMPL_STRATEGY TXFIX_ROUTED_WNS TXFIX_ROUTED_TIMING_FAIL\n")
    rc, out = run_patch(p, "148")
    assert rc == 1 and "anchor" in out


def test_refuses_missing_rails(tmp_path):
    d = tmp_path / "k"
    d.mkdir()
    p = str(d / "build_txfix.tcl")
    open(p, "w").write("open_project vivado_prj.xpr\nreport_ip_status -quiet\n")
    rc, out = run_patch(p, "148")
    assert rc == 1 and "required guard" in out


def test_lineage_cross_guards(kit, lineage):
    """The emitted Tcl carries a runtime guard against the wrong lineage."""
    assert run_patch(kit, lineage)[0] == 0
    txt = open(kit).read()
    if lineage == "148":
        assert "wrong lineage?" in txt and "SEQBIST_FAIL(148)" in txt
    else:
        assert "use --lineage 148" in txt


# --------------------------------------------------------------------------- #
# kit script (text-only checks; it is never executed here -- it rsyncs GBs)
# --------------------------------------------------------------------------- #

def test_kit_script_shape():
    assert os.path.isfile(KIT_SH)
    txt = open(KIT_SH).read()
    assert "jupiter_byte_seqbist_build" in txt
    assert "jupiter_byte_seqbist146_build" in txt
    assert "SEQBIST_KIT_NO_RTL" in txt          # fails loudly if Task-1 RTL absent
    assert "SEQBIST_VARIANT" in txt
    # never invokes Vivado (comments may mention it; no command may)
    cmds = [l for l in txt.splitlines() if not l.lstrip().startswith("#")]
    assert not [l for l in cmds if re.search(r"\bvivado\b(?!_prj|_ip_prj)", l)], cmds
    assert "TXFIX_ROUTED_TIMING_FAIL" in txt    # routed-WNS gate re-verified
    assert "IMPL_STRATEGY" in txt


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))


# --------------------------------------------------------------------------- #
# C-1: the traffic_gen delete must not orphan ANY consumer.
# These tests EXECUTE the emitted Tcl's capture/restore regions under tclsh with
# a stub netlist model, so the re-tap is verified semantically, not by grep.
# --------------------------------------------------------------------------- #

TCL_STUB = r"""
# minimal Vivado BD model: pins are "cell/pin", get_bd_pins returns "/cell/pin"
array set PINNET {}
array set NETPINS {}
set CELLS {}
proc _norm {p} { return [string trimleft $p /] }
proc mk_cell {name args} {
  global CELLS PINNET
  lappend CELLS $name
  foreach p $args { set PINNET($name/$p) "" }
}
proc mk_net {net args} {
  global PINNET NETPINS
  set NETPINS($net) {}
  foreach p $args { set PINNET($p) $net; lappend NETPINS($net) $p }
}
proc _strip_flags {argv flags} {
  set out {}
  foreach a $argv { if {[lsearch -exact $flags $a] < 0} { lappend out $a } }
  return $out
}
proc get_bd_cells {args} {
  global CELLS
  set a [_strip_flags $args {-quiet}]
  set r {}
  foreach n $a { if {[lsearch -exact $CELLS $n] >= 0} { lappend r "/$n" } }
  return $r
}
proc get_bd_pins {args} {
  global PINNET NETPINS
  set i [lsearch -exact $args -of_objects]
  if {$i >= 0} {
    set obj [lindex $args [expr {$i + 1}]]
    set obj [_norm [lindex $obj 0]]
    if {[info exists NETPINS($obj)]} {
      set r {} ; foreach p $NETPINS($obj) { lappend r "/$p" } ; return $r
    }
    return {}
  }
  set r {}
  foreach n [_strip_flags $args {-quiet}] {
    set n [_norm $n]
    if {[info exists PINNET($n)]} { lappend r "/$n" }
  }
  return $r
}
proc get_bd_nets {args} {
  global PINNET
  set i [lsearch -exact $args -of_objects]
  if {$i < 0} { return {} }
  set objs [lindex $args [expr {$i + 1}]]
  foreach o $objs {
    set o [_norm $o]
    if {[info exists PINNET($o)] && $PINNET($o) ne ""} { return [list $PINNET($o)] }
  }
  return {}
}
proc delete_bd_objs {objs} {
  global CELLS PINNET NETPINS
  foreach o $objs {
    set o [_norm $o]
    if {[lsearch -exact $CELLS $o] >= 0} {
      # delete the cell, its pins, and every net any of its pins was on
      foreach p [array names PINNET "$o/*"] {
        set n $PINNET($p)
        if {$n ne "" && [info exists NETPINS($n)]} {
          foreach q $NETPINS($n) { if {[info exists PINNET($q)]} { set PINNET($q) "" } }
          unset NETPINS($n)
        }
      }
      foreach p [array names PINNET "$o/*"] { unset PINNET($p) }
      set CELLS [lsearch -all -inline -not -exact $CELLS $o]
    } elseif {[info exists NETPINS($o)]} {
      foreach q $NETPINS($o) { set PINNET($q) "" }
      unset NETPINS($o)
    }
  }
}
set NETSEQ 0
proc connect_bd_net {args} {
  global PINNET NETPINS NETSEQ
  set net ""
  set pins {}
  set i 0
  while {$i < [llength $args]} {
    set a [lindex $args $i]
    if {$a eq "-net"} { set net [_norm [lindex [lindex $args [expr {$i+1}]] 0]] ; incr i 2 ; continue }
    foreach p $a { lappend pins [_norm $p] }
    incr i
  }
  if {$net eq ""} {
    foreach p $pins { if {$PINNET($p) ne ""} { set net $PINNET($p) ; break } }
  }
  if {$net eq ""} { set net "auto_net_[incr NETSEQ]" }
  if {![info exists NETPINS($net)]} { set NETPINS($net) {} }
  foreach p $pins {
    if {[lsearch -exact $NETPINS($net) $p] < 0} { lappend NETPINS($net) $p }
    set PINNET($p) $net
  }
}
proc dump_state {} {
  global PINNET
  foreach p [lsort [array names PINNET]] { puts "PIN $p = $PINNET($p)" }
}
rename exit _real_exit
proc exit {{c 0}} { puts "TCL_EXIT $c" ; _real_exit $c }
"""


def _emit_148_block(tmp_path):
    src = KITS["148"]
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(src, dst)
    assert run_patch(dst, "148")[0] == 0
    return open(dst).read().split("SEQBIST_PATCH_V1", 1)[1].split("end SEQBIST", 1)[0]


def _region(block, name):
    b = "# --8<-- SEQBIST_%s_BEGIN" % name
    e = "# --8<-- SEQBIST_%s_END" % name
    assert b in block and e in block, name
    return block.split(b, 1)[1].split(e, 1)[0]


def _procs(block):
    out = []
    for name in ("sb_conn", "sb_require_driven"):
        m = re.search(r"^proc %s \{.*?^\}$" % name, block, re.S | re.M)
        assert m, name
        out.append(m.group(0))
    return "\n".join(out)


def _run_tcl(tmp_path, script):
    p = tmp_path / "t.tcl"
    p.write_text(script)
    r = subprocess.run(["tclsh", str(p)], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


@pytest.mark.skipif(shutil.which("tclsh") is None, reason="tclsh not installed")
def test_retap_restores_every_consumer_of_a_5_consumer_net(tmp_path):
    """The live 148 net traffic_gen_dut_valid has five consumers besides the
    driver's own pin in this synthetic model (the real BD has four plus the
    driver, incl. beat_ila/probe15).  Every one must come back driven."""
    if not os.path.isfile(KITS["148"]):
        pytest.skip("148 kit missing")
    block = _emit_148_block(tmp_path)

    model = r"""
mk_cell traffic_gen dut_data dut_valid dut_first host_ready host_data host_valid host_first dut_ready ctrl gap clk resetn
mk_cell TxRxCompo_ip_0 dut_byte_data_in dut_byte_valid_in dut_byte_first_in dut_byte_ready_out
mk_cell tx_checker data valid first ready
mk_cell tx_starve valid ready
mk_cell beat_ila probe15
mk_cell future_probe in0
mk_cell byte_breakout byte_data byte_valid byte_first byte_ready
mk_net traffic_gen_dut_valid traffic_gen/dut_valid TxRxCompo_ip_0/dut_byte_valid_in \
       tx_checker/valid beat_ila/probe15 tx_starve/valid future_probe/in0
mk_net traffic_gen_dut_data  traffic_gen/dut_data  TxRxCompo_ip_0/dut_byte_data_in tx_checker/data
mk_net traffic_gen_dut_first traffic_gen/dut_first TxRxCompo_ip_0/dut_byte_first_in tx_checker/first
mk_net traffic_gen_host_ready traffic_gen/host_ready byte_breakout/byte_ready
"""
    # between capture and restore the real block deletes+recreates the cell and
    # re-does the byte_breakout <-> DUT splice; reproduce just that much.
    splice = r"""
mk_cell traffic_gen dut_data dut_valid dut_first host_ready host_data host_valid host_first dut_ready ctrl gap clk resetn
connect_bd_net [get_bd_pins traffic_gen/dut_data]  [get_bd_pins TxRxCompo_ip_0/dut_byte_data_in]
connect_bd_net [get_bd_pins traffic_gen/dut_valid] [get_bd_pins TxRxCompo_ip_0/dut_byte_valid_in]
connect_bd_net [get_bd_pins traffic_gen/dut_first] [get_bd_pins TxRxCompo_ip_0/dut_byte_first_in]
connect_bd_net [get_bd_pins traffic_gen/host_ready] [get_bd_pins byte_breakout/byte_ready]
"""
    script = "\n".join([TCL_STUB, _procs(block), model,
                        _region(block, "RETAP_CAPTURE"), splice,
                        _region(block, "RETAP_RESTORE"), "dump_state"])
    rc, out = _run_tcl(tmp_path, script)
    assert rc == 0, out
    assert "SEQBIST_FAIL" not in out, out

    # 5 consumers captured off the valid net + 2 + 2 + 1 off the others = 10
    m = re.search(r"SEQBIST_RETAP_CAPTURED n=(\d+)", out)
    assert m, out
    assert int(m.group(1)) == 10, out
    for pin in ("tx_checker/valid", "beat_ila/probe15", "tx_starve/valid",
                "future_probe/in0", "tx_checker/data", "tx_checker/first",
                "byte_breakout/byte_ready", "TxRxCompo_ip_0/dut_byte_valid_in"):
        m = re.search(r"^PIN %s = (\S+)$" % re.escape(pin), out, re.M)
        assert m and m.group(1) != "", "%s left undriven:\n%s" % (pin, out)
    # every re-tapped consumer shares the driver's net
    drv = re.search(r"^PIN traffic_gen/dut_valid = (\S+)$", out, re.M).group(1)
    for pin in ("tx_checker/valid", "beat_ila/probe15", "tx_starve/valid", "future_probe/in0"):
        assert re.search(r"^PIN %s = %s$" % (re.escape(pin), re.escape(drv)), out, re.M), out


@pytest.mark.skipif(shutil.which("tclsh") is None, reason="tclsh not installed")
def test_retap_is_a_noop_on_a_bd_with_no_traffic_gen(tmp_path):
    """The vendh first pass has no traffic_gen at all: capture must be empty and
    restore must not touch anything."""
    if not os.path.isfile(KITS["148"]):
        pytest.skip("148 kit missing")
    block = _emit_148_block(tmp_path)
    script = "\n".join([TCL_STUB, _procs(block),
                        "mk_cell byte_breakout byte_ready",
                        _region(block, "RETAP_CAPTURE"),
                        "mk_cell traffic_gen dut_data dut_valid dut_first host_ready",
                        _region(block, "RETAP_RESTORE"), "dump_state"])
    rc, out = _run_tcl(tmp_path, script)
    assert rc == 0, out
    assert "SEQBIST_RETAP_CAPTURED" not in out
    assert "SEQBIST_RETAP_OK captured=0 reconnected=0" in out


def test_beat_ila_named_on_148_and_absent_on_vendh(tmp_path):
    for lin in ("148", "vendh"):
        if not os.path.isfile(KITS[lin]):
            pytest.skip("kit missing")
        d = tmp_path / ("k" + lin)
        d.mkdir()
        dst = str(d / "build_txfix.tcl")
        shutil.copy(KITS[lin], dst)
        assert run_patch(dst, lin)[0] == 0
        block = open(dst).read().split("SEQBIST_PATCH_V1", 1)[1].split("end SEQBIST", 1)[0]
        if lin == "148":
            assert "beat_ila/probe15" in block
            assert 'sb_require_driven [list $p]' in block
        else:
            assert "beat_ila" not in block, "vendh BD has no beat_ila; do not name it"


def test_preamble_guards_cover_every_dereferenced_cell(tmp_path):
    for lin in ("148", "vendh"):
        if not os.path.isfile(KITS[lin]):
            pytest.skip("kit missing")
        d = tmp_path / ("g" + lin)
        d.mkdir()
        dst = str(d / "build_txfix.tcl")
        shutil.copy(KITS[lin], dst)
        assert run_patch(dst, lin)[0] == 0
        block = open(dst).read().split("SEQBIST_PATCH_V1", 1)[1].split("end SEQBIST", 1)[0]
        guards = " ".join(re.findall(r"foreach c \{([^}]*)\}", block))
        for cell in ("TxRxCompo_ip_0", "axi_adrv9001", "rx_rstn_inverter",
                     "axi_hpm0_lpd_interconnect"):
            assert cell in guards, (lin, cell, guards)


def test_lineage_mismatch_is_not_a_silent_noop(tmp_path):
    if not os.path.isfile(KITS["vendh"]):
        pytest.skip("vendh kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(KITS["vendh"], dst)
    assert run_patch(dst, "vendh")[0] == 0
    rc, out = run_patch(dst, "148")
    assert rc == 1, out
    assert "already patched for lineage" in out


def test_gpio_clock_warning_restored(tmp_path):
    if not os.path.isfile(KITS["vendh"]):
        pytest.skip("vendh kit missing")
    d = tmp_path / "k"
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(KITS["vendh"], dst)
    assert run_patch(dst, "vendh")[0] == 0
    txt = open(dst).read()
    assert "SEQBIST_WARN: ${newm} clock unwired" in txt


# --------------------------------------------------------------------------- #
# fix round 2: rx_seq_checker WITH_CRC as a cell property
# --------------------------------------------------------------------------- #

def _patched(tmp_path, lineage, with_crc=None, tag="w"):
    if not os.path.isfile(KITS[lineage]):
        pytest.skip("kit missing")
    d = tmp_path / (tag + lineage)
    d.mkdir()
    dst = str(d / "build_txfix.tcl")
    shutil.copy(KITS[lineage], dst)
    rc, out = run_patch(dst, lineage, with_crc)
    assert rc == 0, out
    return dst, out


@pytest.mark.parametrize("lin", sorted(KITS))
@pytest.mark.parametrize("val", (0, 1))
def test_with_crc_property_emitted(tmp_path, lin, val):
    dst, out = _patched(tmp_path, lin, val, tag="c%d" % val)
    txt = open(dst).read()
    assert "with_crc=%d" % val in out, out
    # the parameter is set on the rx_seq cell, exactly once, on BOTH lineages
    assert txt.count("set_property CONFIG.WITH_CRC $_sb_with_crc [get_bd_cells rx_seq]") == 1
    # the baked-in default
    assert txt.count("set _sb_with_crc %d" % val) == 1
    assert "set _sb_with_crc %d" % (1 - val) not in txt
    # and the build-time env override survives
    assert "::env(SEQBIST_WITH_CRC)" in txt
    assert 'SEQBIST_FAIL bad SEQBIST_WITH_CRC=' in txt


@pytest.mark.parametrize("lin", sorted(KITS))
def test_with_crc_defaults_to_1(tmp_path, lin):
    dst, out = _patched(tmp_path, lin, None, tag="d")
    txt = open(dst).read()
    assert "with_crc=1" in out
    assert "set _sb_with_crc 1" in txt
    assert "set _sb_with_crc 0" not in txt
    assert "CONFIG.WITH_CRC" in txt


@pytest.mark.parametrize("lin", sorted(KITS))
def test_with_crc_keeps_idempotence(tmp_path, lin):
    dst, _ = _patched(tmp_path, lin, 0, tag="i")
    first = open(dst).read()
    # a second run is a no-op even with a DIFFERENT --with-crc: the marker wins,
    # and the build-time env knob is the way to change it afterwards.
    rc, out = run_patch(dst, lin, 1)
    assert rc == 0 and "SEQBIST_PATCH_NOOP" in out, out
    assert open(dst).read() == first


def test_with_crc_matches_the_rtl_parameter():
    f = os.path.join(REPO, "jupiter_240k5_byte", "rtl_sim", "rx_seq_checker.v")
    if not os.path.isfile(f):
        pytest.skip("Task-1 RTL not landed")
    assert re.search(r"parameter\s+integer\s+WITH_CRC\s*=\s*1", open(f).read()), \
        "rx_seq_checker.v no longer declares WITH_CRC = 1"


def test_kit_script_threads_with_crc():
    txt = open(KIT_SH).read()
    assert 'WITH_CRC="${SEQBIST_WITH_CRC:-1}"' in txt
    assert '--with-crc "$WITH_CRC"' in txt
    assert "SEQBIST_KIT_BAD_WITH_CRC" in txt
    assert "WITH_CRC=$WITH_CRC" in txt   # recorded in SEQBIST_VARIANT
