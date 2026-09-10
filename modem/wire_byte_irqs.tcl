# =============================================================================
# wire_byte_irqs.tcl -- wire the byte-DMA EOT interrupts (tx_byte_dma/irq,
# rx_byte_dma/irq) into the PS pl_ps_irq path for the interrupt-driven-DMA
# upgrade (workstream B). Sourced from complete_byte_t8.tcl AFTER the byte
# cells exist and are wired (BYTE_WIRE_OK) and BEFORE validate_bd_design, so
# the added IRQ nets are covered by validation.
#
#   *** BUILD-TIME-VERIFIED ONLY ***  This script cannot be exercised outside
#   Vivado (no get_bd_* stubs here). It was cross-referenced against
#   complete_byte_t8.tcl's get_bd_cells/get_bd_pins/connect_bd_net conventions
#   but the concat/PS-pin topology is only knowable when the real BD opens.
#
# DESIGN NOTES
#   - Idempotent: safe to source twice. Existing concat inputs are NEVER
#     reordered; the byte IRQs are only APPENDED at the next free indices.
#   - Lean no-op: if the byte DMA cells are absent (lean flow), it prints a
#     clear message and returns without touching the BD.
#   - GIC SPI derivation (ZynqMP, per Xilinx UG1085 + B0 recon evidence):
#       pl_ps_irq0[n]  -> GIC SPI 121 + n   (DT interrupt cell = 89  + n)
#       pl_ps_irq1[n]  -> GIC SPI 136 + n   (DT interrupt cell = 104 + n)
#     DT interrupt cell = GIC SPI - 32 (confirmed on-board: the four adi
#     axi-dmac cores use cells 106-109 -> SPI 138-141, i.e. pl_ps_irq1[2..5]).
#     So this image's existing PL DMAs already sit on the pl_ps_irq1 bank; byte
#     IRQs appended to that same concat land at pl_ps_irq1[>=6] -> SPI >=142.
#     The script derives the base from the ACTUAL pl_ps_irqN pin the concat
#     feeds; if it cannot disambiguate it prints BOTH candidates marked
#     TODO_VERIFY_ON_BUILD. The DT overlay (qpsk_byte_uio.dtso) carries
#     @TX_SPI_CELL@/@RX_SPI_CELL@ placeholders that deploy_dtb.sh substitutes
#     from the BYTE_IRQ_MAP markers this script prints -- nothing bakes a
#     guessed SPI into anything that boots.
# =============================================================================

proc wbi_msg {m} { puts "WIRE_BYTE_IRQS: $m" }

# --- 0. lean no-op guard: byte DMA cells present? --------------------------
set _tx_dma [get_bd_cells -quiet tx_byte_dma]
set _rx_dma [get_bd_cells -quiet rx_byte_dma]
if {![llength $_tx_dma] || ![llength $_rx_dma]} {
    wbi_msg "byte DMA cells (tx_byte_dma/rx_byte_dma) absent -- lean flow, IRQ wiring skipped (no-op)."
    return
}

# --- 1. locate the byte DMA irq pins ---------------------------------------
# adi axi_dmac exposes its EOT interrupt on pin "irq".
set _tx_irq [get_bd_pins -quiet tx_byte_dma/irq]
set _rx_irq [get_bd_pins -quiet rx_byte_dma/irq]
if {![llength $_tx_irq] || ![llength $_rx_irq]} {
    wbi_msg "BYTE_IRQ_FAIL: tx_byte_dma/irq or rx_byte_dma/irq pin not found -- \
cannot wire (check the axi_dmac IRQ pin name for this IP version)."
    return
}

# --- 2. find the PS and the pl_ps_irq concat -------------------------------
# The PS cell in this design is sys_ps8 (zynq_ultra_ps_e); fall back to a
# type search so a renamed PS still resolves.
set _ps [get_bd_cells -quiet sys_ps8]
if {![llength $_ps]} {
    set _ps [get_bd_cells -quiet -filter {VLNV =~ "*zynq_ultra_ps_e*"}]
}
if {![llength $_ps]} {
    wbi_msg "BYTE_IRQ_FAIL: zynq_ultra_ps_e PS cell not found."
    return
}
set _ps [lindex $_ps 0]

# Prefer the pl_ps_irq bank that already carries the adi DMAC IRQs (pl_ps_irq1
# per recon); otherwise fall back to pl_ps_irq0. We pick the first pl_ps_irqN
# pin that is already driven by a concat, else the first that exists.
set _ps_irq_pin ""
set _base_spi    ""
foreach cand {pl_ps_irq1 pl_ps_irq0} {
    set _p [get_bd_pins -quiet $_ps/$cand]
    if {![llength $_p]} { continue }
    set _net [get_bd_nets -quiet -of_objects $_p]
    if {[llength $_net] || $_ps_irq_pin eq ""} {
        set _ps_irq_pin $_p
        set _base_spi   [expr {$cand eq "pl_ps_irq1" ? 136 : 121}]
        set _bank $cand
        if {[llength $_net]} { break }   ;# a connected bank wins
    }
}
if {$_ps_irq_pin eq ""} {
    wbi_msg "BYTE_IRQ_FAIL: neither pl_ps_irq0 nor pl_ps_irq1 exists on $_ps."
    return
}

# --- 3. find (or create) the concat feeding that PS irq pin -----------------
# The PS-IRQ aggregator in this RD may be an xlconcat OR an inline_hdl ilconcat
# (Vivado 2025.1 default for the ADI Jupiter byte RD -- sys_concat_intc_1). The
# two differ: xlconcat has CONFIG.NUM_PORTS and grows; ilconcat pre-creates all
# In<k> and ties unused ones to GND. Handle both.
proc wbi_is_concat {cell} {
    if {![llength $cell]} { return 0 }
    set v [get_property -quiet VLNV $cell]
    return [expr {[string match "*xlconcat*" $v] || [string match "*ilconcat*" $v]}]
}
proc wbi_num_inputs {concat} {
    # generic input count: xlconcat CONFIG.NUM_PORTS AND ilconcat (no NUM_PORTS)
    # both expose In<k> pins -- count the ones that exist.
    set k 0
    while {[llength [get_bd_pins -quiet $concat/In$k]]} { incr k }
    return $k
}
set _concat ""
set _net [get_bd_nets -quiet -of_objects $_ps_irq_pin]
if {[llength $_net]} {
    # source of the net = the concat's dout pin -> owning cell
    foreach _pin [get_bd_pins -quiet -of_objects $_net] {
        set _cell [get_bd_cells -quiet -of_objects $_pin]
        if {[wbi_is_concat $_cell]} { set _concat $_cell; break }
    }
}
if {$_concat eq ""} {
    # No concat yet: create an xlconcat and wire it to the PS irq pin.
    set _concat [create_bd_cell -type ip \
        -vlnv [get_ipdefs -all -filter {NAME==xlconcat}] byte_irq_concat]
    set_property CONFIG.NUM_PORTS 2 $_concat
    connect_bd_net [get_bd_pins $_concat/dout] $_ps_irq_pin
    wbi_msg "created new xlconcat byte_irq_concat -> $_bank"
}
set _is_il [string match "*ilconcat*" [get_property -quiet VLNV $_concat]]
wbi_msg "PS-IRQ concat = [get_property NAME $_concat] ([get_property VLNV $_concat]); ilconcat=$_is_il"

# --- 4. idempotency: already wired? ----------------------------------------
proc wbi_input_index_of_net {concat net} {
    # return the concat In<k> index already carrying $net, or -1
    if {![llength $net]} { return -1 }
    set n [wbi_num_inputs $concat]
    for {set k 0} {$k < $n} {incr k} {
        set ip [get_bd_pins -quiet $concat/In$k]
        if {![llength $ip]} { continue }
        set inet [get_bd_nets -quiet -of_objects $ip]
        if {[llength $inet] && "$inet" eq "$net"} { return $k }
    }
    return -1
}
set _tx_net [get_bd_nets -quiet -of_objects $_tx_irq]
set _rx_net [get_bd_nets -quiet -of_objects $_rx_irq]
set _tx_idx [wbi_input_index_of_net $_concat $_tx_net]
set _rx_idx [wbi_input_index_of_net $_concat $_rx_net]

# --- 5. attach any not-yet-connected byte irq --------------------------------
# An input is FREE if it is unconnected OR driven by a constant tie-off
# (GND / inline_hdl:ilconstant / xlconstant). ilconcat pre-creates all In<k> and
# ties unused ones to a SHARED GND net, so for a free ilconcat input we REWIRE it
# (disconnect ONLY that pin from the shared tie net -- never delete the net, it
# also feeds other cells -- then connect the irq). xlconcat instead grows
# CONFIG.NUM_PORTS.
proc wbi_input_free {concat k} {
    set ip [get_bd_pins -quiet $concat/In$k]
    if {![llength $ip]} { return 0 }
    set net [get_bd_nets -quiet -of_objects $ip]
    if {![llength $net]} { return 1 }   ;# unconnected
    foreach p [get_bd_pins -quiet -of_objects $net] {
        set c [get_bd_cells -quiet -of_objects $p]
        if {[llength $c]} {
            set v [get_property -quiet VLNV $c]
            if {[string match "*constant*" $v] || [string match "*GND*" [get_property -quiet NAME $c]]} { return 1 }
        }
    }
    return 0
}
proc wbi_last_used_input {concat} {
    # highest In<k> that is genuinely driven (not a tie-off); -1 if none
    set last -1; set n [wbi_num_inputs $concat]
    for {set k 0} {$k < $n} {incr k} { if {![wbi_input_free $concat $k]} { set last $k } }
    return $last
}
# APPEND semantics: pick a free input strictly ABOVE the last used input so the
# byte irqs land at pl_ps_irq<bank>[>=lastUsed+1] (e.g. In6/In7 -> SPI 142/143),
# never a low tie-off hole (In0) that would reorder the existing SPI map.
proc wbi_next_append_input {concat after} {
    set n [wbi_num_inputs $concat]
    for {set k [expr {$after + 1}]} {$k < $n} {incr k} { if {[wbi_input_free $concat $k]} { return $k } }
    for {set k 0} {$k < $n} {incr k} { if {[wbi_input_free $concat $k]} { return $k } }
    return $n
}
proc wbi_attach {concat irqpin after is_il} {
    set k [wbi_next_append_input $concat $after]
    set n [wbi_num_inputs $concat]
    if {$k >= $n} {
        if {$is_il} { error "wire_byte_irqs: ilconcat $concat full ($n inputs) -- cannot append byte irq" }
        set_property CONFIG.NUM_PORTS [expr {$n + 1}] $concat   ;# xlconcat grow
    } elseif {$is_il} {
        # rewire a free (tie-off) ilconcat input: drop it from the shared const net
        set net [get_bd_nets -quiet -of_objects [get_bd_pins $concat/In$k]]
        if {[llength $net]} { disconnect_bd_net $net [get_bd_pins $concat/In$k] }
    }
    connect_bd_net $irqpin [get_bd_pins $concat/In$k]
    return $k
}
set _after [wbi_last_used_input $_concat]
if {$_tx_idx < 0} { set _tx_idx [wbi_attach $_concat $_tx_irq $_after $_is_il]; wbi_msg "tx_byte_dma/irq -> In$_tx_idx" } \
                  else { wbi_msg "tx_byte_dma/irq already on In$_tx_idx (kept)" }
set _after2 [expr {$_tx_idx > $_after ? $_tx_idx : $_after}]
if {$_rx_idx < 0} { set _rx_idx [wbi_attach $_concat $_rx_irq $_after2 $_is_il]; wbi_msg "rx_byte_dma/irq -> In$_rx_idx" } \
                  else { wbi_msg "rx_byte_dma/irq already on In$_rx_idx (kept)" }

# --- 6. machine-readable map (deploy_dtb.sh parses this) --------------------
# concat In<k> maps to pl_ps_irqBANK[k] -> GIC SPI = base + k ; DT cell = SPI-32.
set _tx_spi  [expr {$_base_spi + $_tx_idx}]
set _rx_spi  [expr {$_base_spi + $_rx_idx}]
set _tx_cell [expr {$_tx_spi - 32}]
set _rx_cell [expr {$_rx_spi - 32}]
puts "BYTE_IRQ_MAP bank=$_bank tx_concat_idx=$_tx_idx rx_concat_idx=$_rx_idx \
tx_gic_spi=$_tx_spi rx_gic_spi=$_rx_spi tx_spi_cell=$_tx_cell rx_spi_cell=$_rx_cell"
# Ambiguity guard: if the chosen bank was NOT already carrying nets (we could
# not confirm it from existing wiring), emit the alternate-bank candidate too.
if {![llength [get_bd_nets -quiet -of_objects $_ps_irq_pin]] || $_bank eq "pl_ps_irq0"} {
    set _alt_base [expr {$_base_spi == 136 ? 121 : 136}]
    puts "BYTE_IRQ_MAP_ALT TODO_VERIFY_ON_BUILD bank=other \
tx_gic_spi=[expr {$_alt_base + $_tx_idx}] rx_gic_spi=[expr {$_alt_base + $_rx_idx}] \
tx_spi_cell=[expr {$_alt_base + $_tx_idx - 32}] rx_spi_cell=[expr {$_alt_base + $_rx_idx - 32}]"
    wbi_msg "bank could not be confirmed from existing wiring -- VERIFY the base \
(121 vs 136) against the actual pl_ps_irqN target before substituting the DT cells."
}
wbi_msg "done (concat=[get_property NAME $_concat], width=[wbi_num_inputs $_concat])."
