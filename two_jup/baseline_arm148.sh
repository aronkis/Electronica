#!/bin/bash
# baseline_arm148.sh -- one mode-1 arm of 148 on the CURRENT image, logged; 148 only.
D=$(cd "$(dirname "$0")" && pwd); L=$D/baseline_arm148_$(date +%Y%m%d_%H%M%S).log
{ echo "=== baseline arm $(date -Is) image=$($D/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN|cut -c1-12' 2>/dev/null | tr -d '\r')"; bash "$D/arm148_mode1.sh"; echo "=== rc=$? $(date -Is)"; } > "$L" 2>&1
