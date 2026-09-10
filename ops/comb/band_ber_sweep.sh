#!/bin/bash
# band_ber_sweep.sh -- RXFIX Task 65: is the 2.0 GHz failure a NOTCH or a BAND EDGE?
#
# WHY.  Tasks 62-64 have cornered the forward CRC collapse into a place no
# board-side story fits:
#   * Task 62 S3 [silicon]: 146 TX 2.000G -> 146 RX 2.00002G self-loop scores
#     ber_120b 0 over 10,015 frames, and 148's own 1.9 GHz self-loop scores 0.
#     Both boards' RF chains work AT 2.0 GHz when the path is short.
#   * Task 63 [silicon]: all four air dwells -- 1.9 GHz both directions clean,
#     2.0 GHz both directions broken, with the transmitting and receiving
#     boards EXCHANGED between the two failures.  The defect follows the band.
#   * Task 64 [silicon]: with both transmitters muted at -40 dB, the noise
#     floors are 58.1 (148) / 59.6 (146) dBFS at 2.0 GHz against 42.3 / 36.1
#     dBFS at 1.9 GHz.  The BROKEN band is 16-23 dB QUIETER.  Wanted-to-floor
#     is 27.5 / 27.9 dB on the two failing links and 14.9 / 10.6 dB on the two
#     clean ones -- the failing links have nearly TWICE the margin.
# Level, noise, interference and self-leakage are all excluded, and each board
# is proven good at 2.0 GHz in isolation.  What is left is the PATH between
# them, and the one path impairment that is band-selective, reciprocal (so it
# hits both directions), leaves total received power intact (RSSI integrates
# across 40 MHz; a null inside the band barely moves it) and can appear in a
# 32-hour window with no image change, is a FREQUENCY-SELECTIVE MULTIPATH NULL.
#
# THE DISCRIMINATOR.  A multipath null is a NOTCH: it has clean shoulders on
# BOTH sides and its centre is arbitrary.  A device, antenna or filter limit is
# an EDGE: everything past it fails and nothing beyond recovers.  One sweep of
# the forward link's centre frequency separates them.
#
# METHOD.  146 transmits at f, 148 receives at f+20 kHz (the shipped residual
# offset -- the fabric demod has a CFO dead zone at 0, so the offset is kept
# at every point).  148's transmitter and 146's receiver are PARKED together at
# 1.700 GHz for the whole sweep: they stay >= 180 MHz clear of every swept
# point, and the 1.7 GHz link they form is a free running control -- if 146
# reads ber 0 at 1.7 GHz at every point, the boards survived all 13 retunes.
# Both transmitters stay at 0 dB (shipped power): this sweep is about
# frequency, and Task 63 already swept level.
#
# PRE-REGISTERED BRANCHES, in this evaluation order:
#   K0 VOID   the c_shipped control must put 148 in 0.25-0.32 (Tasks 58/61b/62/
#             63 all read 0.2846-0.2848) AND the 1900 MHz sweep point must read
#             < 1e-4.  Either fails -> the sweep is UNINFORMATIVE, full stop.
#   K1 NOTCH  the failing points form a contiguous run with a clean point
#             (ber < 1e-4) BOTH below and above it, total width <= 80 MHz.
#             -> frequency-selective null in the link path.  The boards, the
#             images, the fabric and the host are all exonerated, and moving
#             the operating frequency out of the notch is an operator-
#             actionable repair.  Name the widest clean band measured.
#   K2 EDGE   every point at or above some f fails and no point above it
#             recovers.  -> not multipath; a device/antenna/cable limit.
#   K3 SCATTERED  failures non-contiguous.  Re-run ONCE.  If it repeats with a
#             different pattern the channel is time-varying -- which still puts
#             the defect in the path, but no single clean band can be credited
#             from one sweep.
#   K4 ALL-CLEAN  every point including 2000 MHz reads < 1e-4.  The defect has
#             cleared between 01:22 (Task 63) and now.  That is itself strong
#             evidence for a drifting channel; re-run the shipped control.
#
# DECLARED BEFORE THE RUN.  ber_120b scores only the first 120 of 2240 bits per
# frame (0x108's comparator window), so every number here is frame-START
# damage and is NOT a link BER.  rssi is dB BELOW full scale, larger = weaker,
# and it is a wideband power reading, not a level at any one frequency -- a
# flat rssi across a failing sweep point is exactly the notch signature and is
# NOT evidence the signal is healthy.  No claim about host-visible PER is made
# from this instrument; that needs legrun_go.sh.
set -u
TJ="$(cd "$(dirname "$0")/.." && pwd)"
W="$TJ/anyssh.sh"
A=10.0.0.148     # forward RECEIVER, swept
B=10.0.0.146     # forward TRANSMITTER, swept
: "${OUT:?set OUT=<run dir>}"
DRY=${DRY:-1}
DWELL=${DWELL:-8}
WINBITS=${WINBITS:-120}
PARKF=${PARKF:-1700000000}
OFF=${OFF:-20000}
FREQS=${FREQS:-"1880 1900 1920 1940 1960 1980 2000 2020 2040 2060 2080 2100"}
mkdir -p "$OUT"; L="$OUT/band_ber_sweep.log"; R="$OUT/band_ber_sweep.tsv"
log(){ echo "$(date -Is) $*" | tee -a "$L"; }
alive(){ timeout 20 $W $1 'echo up' 2>/dev/null | grep -q up; }

setlo(){ timeout 60 $W $1 "P=/sys/bus/iio/devices/iio:device2
echo $2 > \$P/out_altvoltage2_TX1_LO_frequency 2>/dev/null
echo $3 > \$P/out_altvoltage0_RX1_LO_frequency 2>/dev/null
sleep 1
echo \"txlo=\$(cat \$P/out_altvoltage2_TX1_LO_frequency 2>/dev/null) rxlo=\$(cat \$P/out_altvoltage0_RX1_LO_frequency 2>/dev/null)\"" 2>/dev/null | tail -1; }

rfstat(){ timeout 60 $W $1 "P=/sys/bus/iio/devices/iio:device2
g(){ v=\$(cat \$P/\$1 2>/dev/null | head -1 | awk '{print \$1}'); [ -n \"\$v\" ] || v=NA; echo \"\$v\"; }
echo \"txlo=\$(g out_altvoltage2_TX1_LO_frequency) rxlo=\$(g out_altvoltage0_RX1_LO_frequency) txensm=\$(g out_voltage0_ensm_mode) rxensm=\$(g in_voltage0_ensm_mode) txatt=\$(g out_voltage0_hardwaregain) rxgain=\$(g in_voltage0_hardwaregain) rssi=\$(g in_voltage0_rssi) dpow=\$(g in_voltage0_decimated_power)\"" 2>/dev/null | tail -1; }

settxatt(){ timeout 60 $W $1 "P=/sys/bus/iio/devices/iio:device2
echo $2 > \$P/out_voltage0_hardwaregain 2>/dev/null
sleep 0.5
cat \$P/out_voltage0_hardwaregain 2>/dev/null | head -1 | awk '{print \$1}'" 2>/dev/null | tail -1; }

rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

dwell(){ timeout 120 $W $1 "P=/sys/bus/iio/devices/iio:device2
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
g(){ v=\$(cat \$P/\$1 2>/dev/null | head -1 | awk '{print \$1}'); [ -n \"\$v\" ] || v=NA; echo \"\$v\"; }
p1=\$(rd 0x104); e1=\$(rd 0x108); c1=\$(rd 0x154); r1=\$(rd 0x150); t1=\$(date +%s)
s1=\$(g in_voltage0_rssi); q1=\$(g in_voltage0_hardwaregain)
sleep $DWELL
p2=\$(rd 0x104); e2=\$(rd 0x108); c2=\$(rd 0x154); r2=\$(rd 0x150); t2=\$(date +%s)
s2=\$(g in_voltage0_rssi); q2=\$(g in_voltage0_hardwaregain); w=\$(g in_voltage0_decimated_power)
echo \"p1=\$p1 p2=\$p2 e1=\$e1 e2=\$e2 c1=\$c1 c2=\$c2 r1=\$r1 r2=\$r2 dt=\$(( t2 - t1 )) rssi1=\$s1 rssi2=\$s2 rxg1=\$q1 rxg2=\$q2 dpow=\$w\"" 2>/dev/null | tail -1; }

# score <board> <raw> <stage> <forward link MHz>
score(){ python3 -c "
import re
s='''$2'''
g=dict(re.findall(r'(\w+)=(\S+)',s))
def v(k):
    x=g.get(k,'0')
    return int(x,16) if x.lower().startswith('0x') else int(x)
M=1<<32
dp=(v('p2')-v('p1'))%M; de=(v('e2')-v('e1'))%M; dt=max(1,v('dt'))
fps=dp/dt; epf=de/dp if dp else float('nan'); ber=epf/$WINBITS if dp else float('nan')
def sgn(x): return x-M if x>=(1<<31) else x
print('%s\t%s\t%s\t%d\t%d\t%.1f\t%.3f\t%.4g\t%d\t%d\t%d\t%s\t%s\t%s\t%s' % (
  '$1','$3','$4',dp,de,fps,epf,ber,sgn(v('c1')),sgn(v('c2')),(v('r2')-v('r1'))%M,
  g.get('rssi1','NA'),g.get('rssi2','NA'),g.get('rxg1','NA'),g.get('dpow','NA')))
" 2>/dev/null; }

log "=== band_ber_sweep (RXFIX Task 65) dry=$DRY out=$OUT dwell=${DWELL}s window=${WINBITS}b park=${PARKF}Hz off=${OFF}Hz ==="
log "    forward pair swept: 146 tx=f, 148 rx=f+$OFF   |   parked control link: 148 tx=$PARKF, 146 rx=$(( PARKF + OFF ))"
log "    sweep points (MHz): $FREQS"
if [ "$DRY" = 1 ]; then
  log "[dry] c_shipped  148=1900000000/2000020000 146=2000000000/1900040000 (K0 control, expect 148 ber 0.25-0.32)"
  for f in $FREQS; do log "[dry] f$f       146 tx=$(( f * 1000000 )) | 148 rx=$(( f * 1000000 + OFF )) | 148 tx=$PARKF | 146 rx=$(( PARKF + OFF ))"; done
  log "[dry] restore    txatt 0 both, shipped LOs, bringup_r2r3.sh r3 on EXIT"
  log "SWEEP_DRY_OK"; exit 0
fi
for ip in $A $B; do alive $ip || { log "SWEEP_FAIL $ip unreachable -- PHYSICAL ATTENTION"; exit 3; }; done

restore(){ log "--- restore: txatt 0 both, shipped LOs, then bringup_r2r3.sh r3 ---"
  log "  $A txatt -> $(settxatt $A 0)"; log "  $B txatt -> $(settxatt $B 0)"
  setlo $A 1900000000 2000020000 | sed "s/^/  $A /" | tee -a "$L"
  setlo $B 2000000000 1900040000 | sed "s/^/  $B /" | tee -a "$L"
  "$TJ/bringup_r2r3.sh" r3 >>"$L" 2>&1 && log "restore: BRING-UP OK" || log "restore: BRING-UP FAILED -- rig NOT in service"
  for ip in $A $B; do log "  $ip final rf: $(rfstat $ip)"; done; }
trap 'restore' EXIT

log "--- quiesce watchdog + daemons on both boards (single DRA writer) ---"
for ip in $A $B; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x qpsk_perf 2>/dev/null; sleep 1; echo quiesced' 2>/dev/null | tail -1 | sed "s/^/  $ip /" | tee -a "$L"
done

printf 'board\tstage\tfwd_MHz\tframes\terrs\tfps\terr_per_frame\tber_%sb\tcfc1\tcfc2\trstcs\trssi1\trssi2\trxgain\tdpow\n' "$WINBITS" > "$R"

# point <tag> <fwd MHz label> <148 txlo> <148 rxlo> <146 txlo> <146 rxlo>
point(){ tag=$1; mhz=$2
  log "--- $tag: 148 tx=$3 rx=$4 | 146 tx=$5 rx=$6 ---"
  log "  $A setlo: $(setlo $A $3 $4)"
  log "  $B setlo: $(setlo $B $5 $6)"
  rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A; sleep 4
  for ip in $A $B; do log "  $ip rf : $(rfstat $ip)"; done
  for ip in $A $B; do S=$(dwell $ip); log "  $ip $tag raw: $S"; score $ip "$S" "$tag" "$mhz" >> "$R"; done
  for ip in $A $B; do alive $ip || { log "SWEEP_FAIL $ip unreachable after $tag -- PHYSICAL ATTENTION"; exit 3; }; done; }

log "--- S0 as-found census (pure read) ---"
for ip in $A $B; do log "  $ip rf : $(rfstat $ip)"; done

log "--- K0 control: the shipped configuration, unmodified ---"
point c_shipped 2000 1900000000 2000020000 2000000000 1900040000

PR=$(( PARKF + OFF ))
for f in $FREQS; do
  point "f$f" "$f" "$PARKF" "$(( f * 1000000 + OFF ))" "$(( f * 1000000 ))" "$PR"
done

log "SWEEP_OK results=$R"
column -t "$R" 2>/dev/null | tee -a "$L"
