#!/usr/bin/env bash
# Camera on 148 -> QPSK RF hop -> pure relay on 146 -> this PC pulls, plays, reports.
#
#   148  /dev/video0 (C270)        146  pure relay, no decode/display        PC (this script)
#    |                               ^                       |                 ^
#    | ffmpeg: MJPEG in -> H.264      | -c copy remux, no decode              | ffmpeg pull (+progress)
#    | /mpegts 400k                  |                       v                 | ffplay window
#    v                               |             tcp://0.0.0.0:5010?listen  |
#   tun0 10.66.0.2 ==RF hop==> tun0 10.66.0.1  --ethernet/LAN, NAT'd-->  10.0.0.146:5010
#
# 148 -> 146 is the PROVEN-HEALTHY RF direction (146 -> 148 is degraded), so the
# camera stays on 148 and 146 stays the RX side, same as stream_board2board.sh.
# The new hop (146 -> PC) is plain ethernet/LAN, not the RF link at all.
#
# WHY A THIRD HOP INSTEAD OF EXTENDING stream_board2board.sh
#   That script decodes AND displays on 146 (chromium + mjpeg_serve.py), because
#   146 has a desktop but its static ffmpeg has no ffplay. This script gives 146
#   a different job: no decode, no display, just an RF, remux (-c copy, no
#   re-encode) onto a TCP socket the PC can reach. All decode + display work
#   moves to the PC, which has a full ffmpeg/ffplay build (SDL2-linked, unlike
#   the boards' static build).
#
# WHY THE PC PULLS INSTEAD OF 146 PUSHING
#   This PC is WSL2 and NAT'd relative to the boards' LAN (`ip route get
#   10.0.0.146` goes out via a NAT gateway, not a shared subnet) -- outbound
#   connections work fine (same as the ssh control plane via anyssh.sh), but
#   nothing on the boards' LAN can open a connection INTO this PC. So 146
#   LISTENS (ffmpeg ... tcp://0.0.0.0:5010?listen=1) and the PC connects out.
#
# WHY ONE ffmpeg PROCESS ON THE PC, NOT A TEE OR TWO PROCESSES
#   ffmpeg's TCP listen mode serves exactly ONE client for the life of the
#   process, so only one thing can hold that connection. This script's puller
#   re-serves the same bytes to a local loopback UDP port (so ffplay has
#   something to open) while ALSO writing -progress stats to a small state
#   file -- ffmpeg reports -progress for the whole process regardless of how
#   many outputs it has, so no tee muxer or second ffmpeg is needed. ffplay
#   then displays the LOCAL re-hop, never the original TCP connection.
#
# LATENCY NUMBER IS 148 -> 146 ONLY, NOT ALL THE WAY TO THE PC's SCREEN
#   Same shape as the one-way preflight probe below, just made continuous:
#   148 timestamps a small UDP packet every LATPROBE_INT seconds, 146 computes
#   (now - sent) on arrival. This assumes 148's and 146's clocks are
#   reasonably aligned, and says nothing about the ffmpeg/ffplay delay between
#   146 and the PC -- there is no shared clock to measure that against.
#
# RF LINK QUALITY IS READ FROM PLAIN FILES ONLY, NEVER direct_reg_access
#   tail -1 /dev/shm/qpsk_tun.log and tail -1 /dev/shm/watchdog.log are
#   daemon-written and safe to read from anywhere. direct_reg_access is a
#   single contended address-latch register -- two concurrent readers have
#   corrupted each other's data before, and only lock_watchdog.sh (already
#   running in production) may touch it. Do not add a read of it here.
#
# NO PLOTTING LIBRARY, NO SEPARATE VIEWER PROCESS
#   Just an ffplay window plus one printf per tick on the console -- the same
#   style stream_board2board.sh already uses in its own monitoring loop.
#
# PROCESS CONTROL: PIDFILES AND PORTS, NEVER pkill -f on a bare substring (see
# stream_board2board.sh's header for why -- the bracket trick fails if the
# plain string also shows up elsewhere on the same command line).
set -u
D=$(cd "$(dirname "$0")" && pwd)
A=10.0.0.148; B=10.0.0.146      # ethernet (control plane for 148/146)
TA=10.66.0.2; TB=10.66.0.1      # tun0 overlay (the RF data plane)

DEV=${DEV:-/dev/video0}
SIZE=${SIZE:-1280x720}   # SIZE=320x240 if 148's CPU struggles with the encode
INFMT=${INFMT:-mjpeg}   # the C270 emits MJPEG in hardware; yuyv422 melts USB
OUTFPS=${OUTFPS:-30}    # rate cap at the ENCODER, never at the v4l2 input
# The measured tun0 throughput on this hop tops out around ~2 Mbit/s (see the
# RF: kbit/s telemetry field). Pushing BR above that doesn't get you a faster
# stream -- it queues faster than the RF link can drain, and that queue is
# EXACTLY where multi-second latency comes from (bufferbloat): raising BR to
# 5000k made this worse, not better. Keep BR comfortably under the observed
# RF: figure; raise SIZE/OUTFPS instead only if you also lower BR to match.
BR=${BR:-5000k}
GOP=${GOP:-20}          # keyframe every 2 s at 10 fps = bounded loss recovery
PORT=${PORT:-5002}              # RF video 148->146; the preflight probe uses 5001
LATPORT=${LATPORT:-5003}        # continuous latency probe, over tun0, 148->146
RELAY_PORT=${RELAY_PORT:-5010}  # 146's TCP listen port, on 146's LAN IP, for the PC to pull
LOCAL_PORT=${LOCAL_PORT:-5020}  # PC-local loopback re-hop between the puller and ffplay
POLL_INT=${POLL_INT:-1}         # telemetry report cadence, same as the existing "sleep 5"
LATPROBE_INT=${LATPROBE_INT:-2} # how often 148 sends a latency-probe packet
LOGDIR=/tmp/qpsk_stream          # shared with stream_board2board.sh's own log files
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-0} # set to 1 to skip the preflight probe (for debugging only)

CHECK_ONLY=0; STOP_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  --stop)  STOP_ONLY=1 ;;
  "")      ;;
  *) echo "usage: $0 [--check | --stop]" >&2; exit 2 ;;
esac

denoise(){ grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# Run on whichever machine owns $1. This script is always launched FROM the
# PC, so $A/$B commands normally go out over ssh (control only) and PC-role
# commands below just run directly in this shell -- is_local()/run() need no
# changes to support a third machine, they only ever check the CALLER's own
# addresses.
MYIPS=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
is_local(){ printf '%s\n' $MYIPS | grep -qx "$1"; }
run(){ local ip=$1; shift
  if is_local "$ip"; then bash -c "$*"
  else "$D/anyssh.sh" "$ip" "$*" 2>/dev/null | denoise; fi; }

# Ship script bodies as base64 rather than fighting three layers of quoting.
push(){ local ip=$1 path=$2 body=$3
  run "$ip" "echo $(printf %s "$body" | base64 -w0) | base64 -d > $path && chmod 755 $path"; }

# ------------------------------------------------------------------ shutdown --
# Every kill here is by PIDFILE, by PROCESS GROUP, or by TCP/UDP PORT -- never
# a bare pkill -f. See stream_board2board.sh's header for the incident that
# taught this lesson.
#
# 146's cleanup also has to reckon with a PREVIOUS stream_board2board.sh
# session: that script's mjpeg_serve.py never records its own PID (it is
# killed by the TCP port it serves on, 8090), and its internal ffmpeg reader
# subprocess is only reaped in mjpeg_serve.py's own SIGINT handler -- a
# SIGKILL from `fuser -k` bypasses that, leaving an orphaned ffmpeg still
# bound to udp $PORT. Free that port explicitly or the new relay's -i can't
# bind it.
CLEANUP146="P=\$(cat $LOGDIR/relay.pid 2>/dev/null)
[ -n \"\$P\" ] && { kill -TERM -\$P 2>/dev/null; kill -TERM \$P 2>/dev/null; }
rm -f $LOGDIR/relay.pid
pkill -f '[r]elay.sh' 2>/dev/null
Pl=\$(cat $LOGDIR/latprobe_rx.pid 2>/dev/null)
[ -n \"\$Pl\" ] && kill \$Pl 2>/dev/null
rm -f $LOGDIR/latprobe_rx.pid
Pc=\$(cat $LOGDIR/chromium.pid 2>/dev/null)
[ -n \"\$Pc\" ] && { kill -TERM -\$Pc 2>/dev/null; kill -TERM \$Pc 2>/dev/null; }
rm -f $LOGDIR/chromium.pid
pkill -f '[c]hromium-qpsk' 2>/dev/null
fuser -k -n tcp 8090 2>/dev/null
fuser -k -n udp $PORT 2>/dev/null
true"

stop_all(){
  run "$A" "[ -f $LOGDIR/tx.pid ] && kill \$(cat $LOGDIR/tx.pid) 2>/dev/null
[ -f $LOGDIR/latprobe_tx.pid ] && kill \$(cat $LOGDIR/latprobe_tx.pid) 2>/dev/null
rm -f $LOGDIR/tx.pid $LOGDIR/latprobe_tx.pid; true" >/dev/null 2>&1
  run "$B" "$CLEANUP146" >/dev/null 2>&1
  local P
  P=$(cat "$LOGDIR/pc.pid" 2>/dev/null)
  [ -n "$P" ] && { kill -TERM -"$P" 2>/dev/null; kill -TERM "$P" 2>/dev/null; }
  rm -f "$LOGDIR/pc.pid"
  pkill -f "[u]dp://127.0.0.1:$LOCAL_PORT" 2>/dev/null
  true
}
if [ "$STOP_ONLY" = 1 ]; then
  echo "== stopping =="
  stop_all
  echo "   148 camera stopped, 146 relay stopped, PC puller/ffplay stopped"
  exit 0
fi

echo "== topology =="
echo "   camera 148 $A ($TA)  --RF-->  relay 146 $B ($TB)  --TCP :$RELAY_PORT-->  this PC"
echo "   148/146 commands run over the ssh control plane; the PC->146 hop is a"
echo "   real ethernet/LAN TCP pull (NAT'd), separate from the tun0 RF overlay."
echo "BR = %s\n" "$BR"
echo "SIZE = %s\n" "$SIZE"
echo "OUTFPS = %s\n" "$OUTFPS"

# ------------------------------------------------------------------ hardware --
echo "== hardware =="
cam=$(run "$A" "ls $DEV >/dev/null 2>&1 && echo YES || echo NO" | tr -dc A-Z)
[ "$cam" = YES ] || die "no $DEV on 148 ($A). The camera must be on 148, the TX side.
  If it is plugged into 146, move it -- 146->148 is the degraded RF direction."
echo "   148 camera : $DEV"

for h in "$A" "$B"; do
  v=$(run "$h" "/usr/local/bin/ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3")
  [ -n "$(printf %s "$v" | tr -dc 0-9)" ] || die "no /usr/local/bin/ffmpeg on $h -- run: bash $D/install_board_media.sh $h"
  echo "   $h  ffmpeg $v"
done

FFMPEG_PC=$(command -v ffmpeg || true)
[ -n "$FFMPEG_PC" ] || die "no ffmpeg on this PC -- install it (apt-get install ffmpeg)."
echo "   PC  $("$FFMPEG_PC" -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"

FFPLAY_PC=$(command -v ffplay || true)
[ -n "$FFPLAY_PC" ] || die "no ffplay on this PC -- it ships with a full (non-static) ffmpeg
  install (apt-get install ffmpeg); the boards' static ffmpeg omits it, which
  is exactly why video is decoded here and not on 146."
echo "   PC  $("$FFPLAY_PC" -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"

# ------------------------------------------------------------------ preflight --
if [ "$SKIP_PREFLIGHT" != 1 ]; then
  echo "== preflight =="
  # tun0 loses its address on EVERY qpsk_tun restart -- see
  # stream_board2board.sh's own comment on this (bringup_r2r3.sh:197 relaunches
  # the daemon without re-addressing tun0).
  fix_tun(){ run "$1" "ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && { echo TUNOK; exit 0; }
 ip link show tun0 >/dev/null 2>&1 || { echo NOTUN; exit 1; }
 ip addr replace $2 peer $3 dev tun0 && ip link set tun0 up mtu 1516 && \
 ip route replace $3 dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
 ip -4 addr show tun0 2>/dev/null | grep -q 'inet ' && echo TUNFIXED || echo TUNBAD"; }
  for spec in "$A $TA $TB" "$B $TB $TA"; do
    set -- $spec
    case "$(fix_tun "$1" "$2" "$3")" in
      *TUNOK*)    echo "   tun0 ok on $1" ;;
      *TUNFIXED*) echo "   tun0 was unaddressed on $1 -- repaired (daemon restart drops it)" ;;
      *NOTUN*)    die "no tun0 on $1 -- qpsk_tun is not running. Arm the link ON THE BOARD:
  WATCHDOG=0 GATE_DIR=B bash /root/Electronica/two_jup/bringup_r2r3.sh r3" ;;
      *)          die "could not address tun0 on $1. Run bringup_r2r3.sh r3" ;;
    esac
  done

  # Real one-way traffic in the SAME direction the video uses (see
  # stream_board2board.sh for why dma_rx_ok/ping are both the wrong test, and
  # why a stale listener on 5001 fakes 0/100 "LINK DOWN").
  PROBE_RX='import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("'"$TB"'",5001)); s.settimeout(8)
n=0
while True:
    try: s.recv(4096); n+=1
    except Exception: break
open("/dev/shm/probe.out","w").write(str(n))'
  PROBE_TX='import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("'"$TA"'",0))
for i in range(100): s.sendto(b"X"*1000,("'"$TB"'",5001)); time.sleep(0.01)'
  run "$B" "fuser -k -n udp 5001 2>/dev/null; rm -f /dev/shm/probe.out; true" >/dev/null
  push "$B" /dev/shm/probe_rx.py "$PROBE_RX" >/dev/null
  run "$B" "setsid python3 /dev/shm/probe_rx.py >/dev/null 2>&1 < /dev/null &" >/dev/null
  sleep 1
  push "$A" /dev/shm/probe_tx.py "$PROBE_TX" >/dev/null
  run "$A" "python3 /dev/shm/probe_tx.py" >/dev/null
  sleep 10
  got=$(run "$B" 'cat /dev/shm/probe.out 2>/dev/null || echo 0' | tr -dc 0-9); : "${got:=0}"
  echo "   one-way probe 148 -> 146 : $got/100 datagrams"
  [ "$got" -ge 60 ] || die "RF hop down or badly degraded ($got/100). Re-arm ON THE BOARD:
  WATCHDOG=0 GATE_DIR=B bash /root/Electronica/two_jup/bringup_r2r3.sh r3"
fi

if [ "$CHECK_ONLY" = 1 ]; then echo "== --check passed; hardware and hop are ready =="; exit 0; fi

trap 'echo; echo "== stopping =="; stop_all; echo "   done"; exit 0' INT TERM

# -------------------------------------------------------------- relay (146) --
# Started FIRST so the TCP listener is up before the PC tries to connect, and
# before 148 sends a single packet. -c copy is a remux, not a decode -- 146
# never touches a pixel. ffmpeg's TCP listen mode serves exactly one client
# and then exits, so this is wrapped in a restart loop, exactly like the
# receiver side being "started first" in stream_board2board.sh.
RELAY="echo \$\$ > $LOGDIR/relay.pid
while :; do
  /usr/local/bin/ffmpeg -hide_banner -loglevel warning -fflags nobuffer -flags low_delay \
    -analyzeduration 500000 -probesize 500000 \
    -i 'udp://$TB:$PORT?fifo_size=1000&overrun_nonfatal=1' \
    -c copy -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 'tcp://0.0.0.0:$RELAY_PORT?listen=1'
  sleep 1
done"

# Continuous latency probe, receiver half -- same shape as PROBE_RX above,
# just kept running and overwriting a single-line file instead of counting to
# 100 and stopping. 148->146 delay only; see header comment.
LATPROBE_RX='import socket, time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("'"$TB"'", '"$LATPORT"'))
while True:
    data,_ = s.recvfrom(256)
    try:
        owd_ms = (time.time() - float(data.decode())) * 1000
        open("/dev/shm/latency_probe.out","w").write("%.1f" % owd_ms)
    except Exception:
        pass'

echo "== starting relay on 146 =="
run "$B" "mkdir -p $LOGDIR
$CLEANUP146" >/dev/null
sleep 1
push "$B" "$LOGDIR/relay.sh" "$RELAY" >/dev/null
run "$B" "setsid $LOGDIR/relay.sh > $LOGDIR/relay.log 2>&1 < /dev/null & echo '   relay listening on :$RELAY_PORT'"
push "$B" "$LOGDIR/latprobe_rx.py" "$LATPROBE_RX" >/dev/null
run "$B" "rm -f /dev/shm/latency_probe.out
setsid python3 $LOGDIR/latprobe_rx.py > $LOGDIR/latprobe_rx.log 2>&1 < /dev/null & echo \$! > $LOGDIR/latprobe_rx.pid
echo '   latency probe listening'"

# ----------------------------------------------------------------- camera (148) --
# Unchanged from stream_board2board.sh: DO NOT add -framerate to the v4l2
# input (silently encodes zero frames if it doesn't match a rate the camera
# advertises); the C270 takes ~3.9 s to deliver its first frame; pkt_size=1316
# keeps IP+UDP overhead under tun0's 1516 MTU.
TX="echo \$\$ > $LOGDIR/tx.pid
exec /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
 -f v4l2 -input_format $INFMT -video_size $SIZE -i $DEV \
 -an -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline \
 -b:v $BR -maxrate $BR -bufsize $((${BR%k}/2))k -g $GOP -r $OUTFPS -pix_fmt yuv420p \
 -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 \
 'udp://$TB:$PORT?pkt_size=1316'"

# Continuous latency probe, sender half -- same shape as PROBE_TX above, just
# looping forever at LATPROBE_INT instead of firing 100 packets once.
LATPROBE_TX='import socket, time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("'"$TA"'",0))
while True:
    s.sendto(str(time.time()).encode(), ("'"$TB"'", '"$LATPORT"'))
    time.sleep('"$LATPROBE_INT"')'

echo "== starting camera on 148 =="
run "$A" "mkdir -p $LOGDIR
[ -f $LOGDIR/tx.pid ] && kill \$(cat $LOGDIR/tx.pid) 2>/dev/null
[ -f $LOGDIR/latprobe_tx.pid ] && kill \$(cat $LOGDIR/latprobe_tx.pid) 2>/dev/null
rm -f $LOGDIR/tx.pid $LOGDIR/latprobe_tx.pid; true" >/dev/null
push "$A" "$LOGDIR/tx.sh" "$TX" >/dev/null
run "$A" "setsid $LOGDIR/tx.sh > $LOGDIR/tx.log 2>&1 < /dev/null & echo '   camera armed'"
push "$A" "$LOGDIR/latprobe_tx.py" "$LATPROBE_TX" >/dev/null
run "$A" "setsid python3 $LOGDIR/latprobe_tx.py > $LOGDIR/latprobe_tx.log 2>&1 < /dev/null & echo \$! > $LOGDIR/latprobe_tx.pid
echo '   latency probe armed'"

# --------------------------------------------------------------------- PC --
# Everything below runs directly in THIS shell -- no run()/push() needed,
# since this script is always launched from the PC itself. One small script
# file (not pushed anywhere, just written locally) launches both the puller
# and ffplay under a single setsid, so one process-group kill on pc.pid stops
# both -- same trick stream_board2board.sh uses for chromium's zygote+renderers.
#
# -progress writes to a plain state file instead of pipe:1: this script
# backgrounds the puller with a bare "&", so pipe:1 would just be this
# process's own stdout with nothing reading it inline. A small file under
# $LOGDIR is the same lightweight-state-file pattern already used for
# /dev/shm/latency_probe.out and /dev/shm/qpsk_tun.log -- not a viewer
# process, just something the monitoring loop below tails once per tick.
mkdir -p "$LOGDIR"
: > "$LOGDIR/pc_progress.log"
cat > "$LOGDIR/pc.sh" <<PCEOF
#!/usr/bin/env bash
echo \$\$ > $LOGDIR/pc.pid
# 146's relay only starts LISTENING once it has probed live camera data (its
# input must be opened/probed before ffmpeg opens the TCP output), so the
# first connection attempt here routinely loses the race and gets
# "Connection refused" -- and ffmpeg's TCP client mode does not retry on its
# own. Wrapped in the same restart-loop shape as the relay itself, so this
# self-heals both the startup race and any later relay bounce (148 restart,
# RF blip, etc).
# Video-only MPEG-TS has NO real-time reference: with no audio track, ffplay's
# master clock IS the video stream, so it just plays frames back-to-back in
# arrival order forever. If any backlog forms ANYWHERE upstream (even briefly,
# e.g. during the first few seconds while the RF link and TCP hop are still
# ramping up), nothing ever catches it back up -- it becomes a permanent,
# constant lag. Muxing in a silent audio track gives ffplay a genuine
# wall-clock reference (the sound card paces real audio samples in real time
# regardless of how fast/slow packets arrived upstream), which makes
# -framedrop meaningful: ffplay will actively discard backlogged video frames
# to stay caught up to now, instead of faithfully draining a queue that fell
# behind once.
(
  while :; do
    "$FFMPEG_PC" -hide_banner -loglevel warning -fflags nobuffer -flags low_delay \\
      -analyzeduration 500000 -probesize 500000 \\
      -i tcp://$B:$RELAY_PORT \\
      -f lavfi -i anullsrc=r=8000:cl=mono \\
      -map 0:v -map 1:a -c:v copy -c:a aac -b:a 8k \\
      -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 'udp://127.0.0.1:$LOCAL_PORT?pkt_size=1316' \\
      -progress $LOGDIR/pc_progress.log -nostats
    sleep 1
  done
) &
"$FFPLAY_PC" -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -framedrop \\
  -analyzeduration 500000 -probesize 500000 \\
  -i 'udp://127.0.0.1:$LOCAL_PORT?fifo_size=1000&overrun_nonfatal=1' &
wait
PCEOF
chmod 755 "$LOGDIR/pc.sh"
echo "== starting puller + ffplay on this PC =="
[ -f "$LOGDIR/pc.pid" ] && kill "$(cat "$LOGDIR/pc.pid")" 2>/dev/null
rm -f "$LOGDIR/pc.pid"
setsid "$LOGDIR/pc.sh" > "$LOGDIR/pc.log" 2>&1 < /dev/null &
echo "   pulling tcp://$B:$RELAY_PORT -> local udp:$LOCAL_PORT -> ffplay window"

echo
echo "== streaming =="
echo "   allow ~4 s for the C270's first frame, plus a couple seconds for the"
echo "   TCP connect + ffplay window to appear."
echo "   stop with:  bash $0 --stop     (or Ctrl-C here)"
echo

# Report from ALL THREE points. A one-ended report cannot distinguish a
# stalled camera from a hop that is dropping everything, or the PC's own
# decode from the RF link itself.
prev=0
while :; do
  sleep "$POLL_INT"
  tx=$(run "$A" "[ -f $LOGDIR/tx.pid ] && kill -0 \$(cat $LOGDIR/tx.pid) 2>/dev/null && echo UP || echo DOWN" | tr -dc A-Z)
  rxb=$(run "$B" "cat /sys/class/net/tun0/statistics/rx_bytes 2>/dev/null" | tr -dc 0-9); : "${rxb:=0}"
  rfrate=$(( (rxb - prev) * 8 / (POLL_INT*1000) )); prev=$rxb

  # qpsk_tun.log rotates between three line shapes (nakstat/rxresync/rxresync2)
  # on each write, so a bare "tail -1" often lands on the wrong one -- grep out
  # the last actual "rxresync:" line first, then pull its counters. (Field
  # names confirmed against a live log; "crc_drop"/"seq_gap" do not exist in
  # this daemon's output.)
  q=$(run "$B" "grep -a 'rxresync:' /dev/shm/qpsk_tun.log 2>/dev/null | tail -1")
  fail=$(printf %s "$q" | grep -oE 'resync_fail=[0-9]+')
  rec=$(printf %s "$q"  | grep -oE 'recovered=[0-9]+')
  lost=$(printf %s "$q" | grep -oE 'tail_lost=[0-9]+')
  wd=$(run "$B" "tail -1 /dev/shm/watchdog.log 2>/dev/null" | grep -oE 'LOCKED|NOT-LOCKED')
  lat=$(run "$B" "cat /dev/shm/latency_probe.out 2>/dev/null")

  pc_kbit="?"; pc_fps="?"
  if [ -s "$LOGDIR/pc_progress.log" ]; then
    br=$(tac "$LOGDIR/pc_progress.log" 2>/dev/null | grep -m1 '^bitrate=' | tr -dc '0-9.')
    fp=$(tac "$LOGDIR/pc_progress.log" 2>/dev/null | grep -m1 '^fps=' | cut -d= -f2)
    [ -n "$br" ] && pc_kbit=$br
    [ -n "$fp" ] && pc_fps=$fp
  fi

  printf "   camera=%-4s RF:%5dkbit/s  PC:%skbit/s %sfps  link:%s %s %s %s  lat148->146:%sms\n" \
    "$tx" "$rfrate" "$pc_kbit" "$pc_fps" "${fail:-resync_fail=?}" "${rec:-recovered=?}" "${lost:-tail_lost=?}" "${wd:-?}" "${lat:-?}"

  if [ "$tx" = DOWN ]; then
    echo "   camera side exited:";     run "$A" "tail -6 $LOGDIR/tx.log" | sed 's/^/     148 /'
    echo "   relay log:";              run "$B" "tail -6 $LOGDIR/relay.log" | sed 's/^/     146 /'
    echo "   latency probe logs:";     run "$A" "tail -3 $LOGDIR/latprobe_tx.log" | sed 's/^/     148 /'
    run "$B" "tail -3 $LOGDIR/latprobe_rx.log" | sed 's/^/     146 /'
    stop_all
    break
  fi
done
