# no_arm_inflight.sh -- source, then call arm_guard <who>. Refuses (exit 3) while any
# transceiver arm / bring-up / capture bring-up is running on this host, because a
# direct_reg_access read on the AXI ADC core during the ADRV9002 profile reload hangs
# the board's PS (documented double-hang 2026-08-04; four no-ping outages 08-26/27,
# RIG_NOPING_FAULT.md). The bring-up protects against the ON-BOARD watchdog; this
# protects against every nemo-side reader.
arm_guard(){ if ps -eo args | grep -qE "^(/bin/bash|bash|/bin/sh) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|capture_r3|soak_bidir)\.sh"; then
               echo "ARM_INFLIGHT -- refusing register reads ($1)"; return 3; fi; return 0; }
