#!/bin/bash
# rxchk_run.sh -- read the in-fabric RX seam checker on 148 (probe-3 image: counters muxed onto the witness
# GPIO 0x9D450008, selected by tgen_rx gap[31:28] @0x9D410008; sel 0=acc_user 1=frames 2=crc_ok 3=crc_fail
# 4=magic_bad 5=short_frm 6=orphan_w 7=acc_beats) over a DUR-s window of the NORMAL link (injector disabled)
# and reconcile with 0x104 and the daemon stats. Reads are guarded (no arm in flight).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=10.0.0.148; DUR=${DUR:-60}
. $D/sim_repro/no_arm_inflight.sh 2>/dev/null || true
rd(){ $W $B 'DM=$(command -v devmem || echo "busybox devmem"); DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  c=$($DM 0x9D410000); [ "$((c & 1))" = 0 ] || { echo "RXCHK_ABORT injector enabled ctrl=$c"; exit 3; }
  echo 0x104 > $DRA; p=$(cat $DRA)
  names="acc_user frames crc_ok crc_fail magic_bad short orphan acc_beats"; i=0; out=""
  for n in $names; do $DM 0x9D410008 32 $((i << 28)) >/dev/null; v=$($DM 0x9D450008); out="$out $n=$((v))"; i=$((i+1)); done
  $DM 0x9D410008 32 0 >/dev/null
  echo "RXCHK$out p104=$((p)) $(grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1 | grep -oE "dma_rx_ok=[0-9]+|idle_rx=[0-9]+|crc_drop=[0-9]+" | tr "\n" " ")t=$(date +%s.%N)"' 2>/dev/null; }
type arm_guard >/dev/null 2>&1 && arm_guard
A=$(rd); echo "PRE  $A"; case "$A" in *ABORT*) exit 3;; esac; sleep "$DUR"; type arm_guard >/dev/null 2>&1 && arm_guard; Z=$(rd); echo "POST $Z"
python3 - "$A" "$Z" "$DUR" <<'PY'
import sys,re
a,z,dur=sys.argv[1],sys.argv[2],float(sys.argv[3])
ka={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',a)}; kz={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',z)}
d={k:(kz[k]-ka[k])&0xFFFFFFFF for k in ka if k in kz}
fr=d.get('frames',0); ok=d.get('crc_ok',0); bad=d.get('crc_fail',0); mg=d.get('magic_bad',0)
host=d.get('dma_rx_ok',0)+d.get('idle_rx',0); hcrc=d.get('crc_drop',0)
print(f"RXCHK_DELTA {dur:.0f}s: decoder frames={fr} ({fr/dur:.0f}/s) crc_ok={ok} crc_fail={bad} magic_bad={mg} short={d.get('short',0)} orphan={d.get('orphan',0)} | seam user beats={d.get('acc_user',0)} beats={d.get('acc_beats',0)} (beats/191={d.get('acc_beats',0)/191:.1f}) | 0x104 delta={d.get('p104',0)}")
print(f"  host: delivered(dma_rx_ok+idle_rx)={host} crc_drop={hcrc} host_total={host+hcrc}")
if fr: print(f"  fabric: crc_fail/frames={100*bad/fr:.3f}%  magic_bad/frames={100*mg/fr:.3f}%  | host: crc_drop/frames={100*hcrc/fr:.3f}%  missing(frames-host_total)/frames={100*(fr-host-hcrc)/fr:.3f}%   (air comb ~8.7% queued / ~13.9% reset)")
PY
