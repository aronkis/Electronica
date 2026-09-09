#!/bin/bash
# ch2ify.sh <script.sh> [out.sh] -- derive the CHANNEL-2 variant of a two_jup
# harness script (accept_final.sh / seq_census.sh / error_hunt.sh / link_test.sh).
# Default output: <script>_ch2.sh
#
# Token map (proven in tone_path.sh:11 + trackB_ch2_rx_test.sh):
#   TX LO   out_altvoltage2_TX1_LO_frequency -> out_altvoltage3_TX2_LO_frequency
#   RX LO   out_altvoltage0_RX1_LO_frequency -> out_altvoltage1_RX2_LO_frequency
#   phy attrs  in_voltage0_* <-> in_voltage1_*   (SWAP: ch2 becomes the armed
#              out_voltage0_* <-> out_voltage1_*  channel, ch1 the quiesced one)
#   devices axi-adrv9002-tx-lpc -> tx2-lpc (DAC-mux debugfs regs follow the
#           modem to the tx2 core)
#
# Deliberately UNCHANGED:
#   - axi-adrv9002-rx-lpc: in the ch2+tap image the modem's debug capture STAYS
#     on the rx1 DMA (bd_ch2_tapfix; only rx-lpc exposes 4 iio channels) -- the
#     ring/capture device does NOT change.
#   - iio_readdev channel args (voltage0_i voltage0_q voltage1_i voltage1_q):
#     channel indices WITHIN the capture DMA core, not RF-channel names.
#   - modem AXI regs via iio:device0 direct_reg_access (same QPSK IP).
#   - agpio 4..7 writes (ch1 gain-table pins; harmless -- ch2 gain is pinned
#     post-lock via in_voltage1_gain_control_mode=spi).
#   - port_select VALUE stays tx_a (attr name becomes out_voltage1_port_select).
#     If ch2 Rx shows dead-air rssi at arm, sweep tx_b / port_en_mode variants
#     before concluding (plan Phase D note).
set -e
SRC=${1:?usage: ch2ify.sh <script.sh> [out.sh]}
OUT=${2:-${SRC%.sh}_ch2.sh}
test -f "$SRC" || { echo "FATAL: no $SRC" >&2; exit 1; }

sed -e 's/out_altvoltage2_TX1_LO_frequency/out_altvoltage3_TX2_LO_frequency/g' \
    -e 's/out_altvoltage0_RX1_LO_frequency/out_altvoltage1_RX2_LO_frequency/g' \
    -e 's/in_voltage0_/\x01IV\x01/g'  -e 's/in_voltage1_/in_voltage0_/g'  -e 's/\x01IV\x01/in_voltage1_/g' \
    -e 's/out_voltage0_/\x01OV\x01/g' -e 's/out_voltage1_/out_voltage0_/g' -e 's/\x01OV\x01/out_voltage1_/g' \
    -e 's/axi-adrv9002-tx-lpc/axi-adrv9002-tx2-lpc/g' \
    "$SRC" > "$OUT"

cmp -s "$SRC" "$OUT" && { echo "FATAL: $SRC has no ch1 tokens (wrong input?)" >&2; rm -f "$OUT"; exit 1; }
grep -q 'TX2_LO_frequency' "$OUT" || echo "WARN: no TX LO line rewritten (script may not arm)" >&2
chmod +x "$OUT"
echo "ch2ify: $SRC -> $OUT ($(grep -c 'voltage1_\|tx2-lpc\|rx2-lpc\|TX2_LO\|RX2_LO' "$OUT") ch2-token lines)"
