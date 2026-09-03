# image_a_3072_clocks.xdc -- IMAGE A (f1536 / sps=8, rate rungs R0/R1) fabric-clock
# constraint. Re-times the modem fabric clock to the plan target 30.72 MHz.
#
# WHY: the ADI Jupiter reference design constrains the ADRV9002 LVDS SSI master
# clocks (rx1/rx2/tx1/tx2 dclk) at 2.0 ns, which makes the auto-derived generated
# clock axi_adrv9001_adc_1_clk (= dclk / 4 via BUFGCE_DIV) = 8.0 ns = 125 MHz.
# That 125 MHz default is the RD's fastest-profile constraint. Image A's modem
# worst path is the TX polyphase RRC FIR (REP_TxI/Q: an 11-deep MAC / 13x-DSP
# adder-tree cascade, ~18.6 ns) -- since pipelined via HDL Coder adder-tree
# pipelining. (The f1536 in-fabric interleaver was once suspected here via its
# perm = mod/idivide(beatIdx, ROWS=1537) division cone, but that was re-coded
# divisionless with incremental row/col counters and is off the critical path.)
# The modem is sized for the plan's 30.72 MHz fabric target, NOT 125 MHz -- it
# cannot close at 8 ns (logic alone is 12.3 ns) but closes with ~+13.8 ns
# headroom at 32.552 ns (30.72 MHz).
#
# HOW (RD-correct): scale the PRIMARY SSI dclk clocks (a create_clock override on
# the input ports) so the generated adc_1_clk auto-scales to 30.72 MHz and stays
# SYNCHRONOUS with its SSI siblings (rx1_dclk_out_DIV4_INV, the SERDES/aligner
# paths). Do NOT create_clock adc_1_clk directly -- that orphans the generated
# clock from its master and produces meaningless cross-clock WNS on the stock ADI
# rx phy/link IP (the 0.008 ns-requirement artifact). 32.552083 ns / 4 = 8.138021 ns.
#
# *** DEPLOY DISCIPLINE (LOAD-BEARING SAFETY CONSTRAINT) ***********************
# *** An Image A board may load ONLY the 1.92 Msym / 15.36 MSPS ADRV9002 LVDS  *
# *** profiles. Those run the SSI (hence adc_1_clk) at the 30.72 MHz this image *
# *** is timed for. Loading a FASTER ADRV9002 profile would clock the fabric    *
# *** above 30.72 MHz, where the f1536 interleaver arithmetic does NOT meet     *
# *** timing -> silent datapath corruption. Image A's provisioning/LVDS-profile *
# *** step MUST refuse any profile above 15.36 MSPS.                            *
# *****************************************************************************

create_clock -name rx1_dclk_out -period 8.138021 -waveform {0.0 4.069010} [get_ports rx1_dclk_in_p]
create_clock -name rx2_dclk_out -period 8.138021 -waveform {0.0 4.069010} [get_ports rx2_dclk_in_p]
create_clock -name tx1_dclk_out -period 8.138021 -waveform {0.0 4.069010} [get_ports tx1_dclk_in_p]
create_clock -name tx2_dclk_out -period 8.138021 -waveform {0.0 4.069010} [get_ports tx2_dclk_in_p]
