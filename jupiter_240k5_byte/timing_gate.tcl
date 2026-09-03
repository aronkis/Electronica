# timing_gate.tcl -- pre-implementation timing gate for the QPSK byte image.
#
# PURPOSE: after synthesis, before implementation, report whether the MODEM DUT
# (TxRxCompo IP, IPCORE_CLK domain) closes timing, and how the design's real
# fabric-clock constraint compares to the image's target rung (Image A 30.72 MHz
# rungs R0/R1; Image B 122.88 MHz rungs R2/R3).
#
# IMPORTANT (learned the hard way): the modem IPCORE_CLK is driven by the ADI
# generated clock axi_adrv9001_adc_1_clk (rx SSI LVDS clock / BUFGCE_DIV, ~8ns /
# 125 MHz in this RD). It is a GENERATED clock. You must NOT `create_clock` it --
# that reconstrains it as a primary clock and orphans it from its synchronous SSI
# siblings (rx1_dclk_out_DIV4_INV etc.), producing meaningless cross-clock WNS on
# the stock ADI IP (the 0.008ns-requirement artifact). So this gate does NOT
# redefine any clock: it reads the REAL post-synth timing at the design's actual
# constraints, SCOPED to the modem DUT (ignoring stock ADI IP paths, which are the
# RD's responsibility and close in every shipped image).
#
# CONTRACT: sourced from a Vivado -mode batch session that has just finished
#   synth_1. Target rung MHz from env QPSK_TARGET_MHZ (default 30.72) / argv.
#   Prints TIMING_GATE_WNS ... and, on a real modem-domain violation at the
#   design's constrained clock, TIMING_GATE_FAIL + report_timing + exit 1.
#   NB: if the modem is designed for a SLOWER rung than the RD's fabric clock
#   (e.g. f1536 @30.72 under a 125 MHz RD constraint), a real single-cycle
#   violation here is NOT closable by impl and is a plan-owner decision
#   (re-clock the fabric to the rung, or pipeline the datapath) -- report BLOCKED.

proc _tg_die {msg} { puts "TIMING_GATE_FAIL $msg"; puts "TIMING_GATE_ABORT"; exit 1 }

# --- target rung period ------------------------------------------------------
set _tg_mhz 30.72
if {[llength $argv] >= 1 && [string is double -strict [lindex $argv 0]]} {
    set _tg_mhz [lindex $argv 0]
} elseif {[info exists ::env(QPSK_TARGET_MHZ)] && [string is double -strict $::env(QPSK_TARGET_MHZ)]} {
    set _tg_mhz $::env(QPSK_TARGET_MHZ)
}
set _tg_ns [expr {1000.0 / $_tg_mhz}]
# post-synth pessimism floor: block only when clearly non-closing (post-impl WNS
# is authoritative; a small negative post-synth may still close in impl).
set _tg_floor -1.0
if {[info exists ::env(QPSK_TG_FLOOR)] && [string is double -strict $::env(QPSK_TG_FLOOR)]} {
    set _tg_floor $::env(QPSK_TG_FLOOR)
}
puts "=== TIMING_GATE: rung ${_tg_mhz} MHz (period ${_tg_ns} ns), floor ${_tg_floor} ns ==="

# --- open the synthesized netlist (no redefine) ------------------------------
if {[catch {open_run synth_1 -name synth_1} _e]} {
    if {![string match "*already*" $_e]} { _tg_die "open_run synth_1: $_e" }
}
puts "=== TIMING_GATE: clocks (real, as-synthesized -- NOT redefined) ==="
report_clocks

# --- identify the modem clock (adc_1_clk / IPCORE_CLK domain) ----------------
set _tg_clk {}
foreach _patt {*IPCORE_CLK* *adc_1_clk* *adc_1*} {
    set _nets [get_nets -quiet -hier -filter "NAME =~ $_patt"]
    if {[llength $_nets]} {
        set _c [get_clocks -quiet -of_objects $_nets]
        if {[llength $_c]} { set _tg_clk [lindex $_c 0]; break }
    }
}
if {![llength $_tg_clk]} { _tg_die "could not identify the modem (IPCORE_CLK/adc_1_clk) clock" }
set _tg_name [get_property NAME $_tg_clk]
set _tg_per  [get_property PERIOD $_tg_clk]
set _tg_realmhz [expr {1000.0 / $_tg_per}]
puts "=== TIMING_GATE: modem clock = $_tg_name  REAL period=${_tg_per}ns (~${_tg_realmhz} MHz) ==="
if {$_tg_per > $_tg_ns + 0.01} {
    puts "TIMING_GATE_NOTE: fabric clock (${_tg_realmhz} MHz) is SLOWER than the ${_tg_mhz} MHz rung -- design under-clocked for the rung."
} else {
    puts "TIMING_GATE_NOTE: fabric clock (${_tg_realmhz} MHz) is at/above the ${_tg_mhz} MHz rung; closure is checked at the real (stricter) constraint."
}

# --- MODEM-scoped worst setup slack at the real constraint -------------------
set _mcells [get_cells -hierarchical -quiet -filter {NAME =~ *TxRxCompo_ip_0*}]
if {![llength $_mcells]} { _tg_die "modem cells (TxRxCompo_ip_0) not found in netlist" }
set _mpaths [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 -to $_mcells]
if {![llength $_mpaths]} { _tg_die "no setup paths -to modem cells" }
set _mwns [get_property SLACK [lindex $_mpaths 0]]
# overall (all domains, incl stock ADI IP) for context only
set _awns [get_property SLACK [lindex [get_timing_paths -quiet -setup -max_paths 1 -nworst 1] 0]]
puts "TIMING_GATE_WNS modem_dut=${_mwns} overall=${_awns} clk=$_tg_name real_period=${_tg_per} rung_mhz=${_tg_mhz} (post-synth, real constraints)"

if {$_mwns < $_tg_floor} {
    puts "TIMING_GATE_FAIL modem_dut WNS ${_mwns}ns < floor ${_tg_floor}ns at the real ${_tg_realmhz} MHz constraint -- worst modem paths:"
    report_timing -setup -max_paths 20 -to $_mcells
    puts "TIMING_GATE_ABORT"
    exit 1
}
puts "TIMING_GATE_PASS modem_dut WNS=${_mwns}ns (post-synth; authoritative WNS is post-impl at the real ${_tg_per}ns clock)"
