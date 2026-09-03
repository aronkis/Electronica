#!/bin/bash
# Wait for the Path A (resolver-fix) byte build, then deploy to 148 and run the
# G2 echo gate with arbitrary payloads (should now pass with the resolver fix).
LOG=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte/build_byte_resolver.log
until grep -qE 'BYTE_IMAGE_BUILD_DONE|BYTE_IMAGE_BUILD_FAILED|FATAL' "$LOG" 2>/dev/null; do sleep 120; done
if ! grep -q 'BYTE_IMAGE_BUILD_DONE' "$LOG"; then echo "CHAIN ABORT: Path A build failed"; tail -6 "$LOG"; exit 1; fi
B=/mnt/onetb/scratch/qpsk_byte_resolver_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
echo "CHAIN: Path A build done ($(md5sum "$B" | cut -c1-12)) -> deploy 148 + G2 echo (arbitrary payloads)"
exec /mnt/onetb/scratch/qpsk_variants/two_jup/byte_echo_g2.sh "$B" 10.0.0.148
