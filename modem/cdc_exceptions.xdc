# CDC exceptions for handshake-protected crossings between the async PS AXI
# domain and the ADRV9001-derived sample-clock domains.
#
# WHY THIS FILE EXISTS: the MATLAB HDL-workflow IP packaging emits ADI's
# axi_adrv9001/axi_dmac constraint files as 6-line copyright STUBS (.txt) --
# ADI's intended false-path/max-delay exception set has NEVER loaded in this
# project flow. Consequence: ~4,600 fully-timed CDC endpoints (WNS -13 ns
# storm on MathWorks sync-FIFO crossings) distorting placement until the
# genuinely-marginal up-bus config crossing (clk_pl_0 -> adc_1) broke lock on
# the lean image (WNS -1.44; working siblings -0.56 by placement luck).
# These crossings are handshake/async-FIFO protected by construction (ADI
# up_xfer_*, MathWorks fast/slow sync IPs), so skew-free bounded datapath
# delay is the correct constraint class.
set pl0  [get_clocks clk_pl_0]
set adc1 [get_clocks -quiet axi_adrv9001_adc_1_clk]
set dac1 [get_clocks -quiet axi_adrv9001_dac_1_clk]
set adc2 [get_clocks -quiet i_if_n_1]
set_max_delay -quiet -datapath_only -from $pl0  -to $adc1 10.000
set_max_delay -quiet -datapath_only -from $adc1 -to $pl0   8.000
set_max_delay -quiet -datapath_only -from $pl0  -to $dac1 10.000
set_max_delay -quiet -datapath_only -from $dac1 -to $pl0   8.000
set_max_delay -quiet -datapath_only -from $adc1 -to $dac1  8.000
set_max_delay -quiet -datapath_only -from $dac1 -to $adc1  8.000
set_max_delay -quiet -datapath_only -from $pl0  -to $adc2 10.000
set_max_delay -quiet -datapath_only -from $adc2 -to $pl0   8.000
