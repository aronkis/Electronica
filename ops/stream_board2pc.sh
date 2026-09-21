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
#   re-serves the same bytes to a local named pipe (so ffplay has something to
#   open) while ALSO writing -progress stats to a small state file -- ffmpeg
#   reports -progress for the whole process regardless of how many outputs it
#   has, so no tee muxer or second ffmpeg is needed. ffplay then displays the
#   LOCAL re-hop, never the original TCP connection.
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
SIZE=${SIZE:-1280x720}  # 720p30 is the measured ceiling -- see CHROMA below
INFMT=${INFMT:-mjpeg}   # the C270 emits MJPEG in hardware; yuyv422 melts USB
OUTFPS=${OUTFPS:-30}    # rate cap at the ENCODER, never at the v4l2 input
# 4:2:2 vs 4:2:0 is a THROUGHPUT knob here, not a quality one. The camera hands
# us yuvj422p; asking for yuv420p inserts a swscale pass over every frame, and
# that pass costs ~19% of the whole pipeline (measured offline on a captured
# clip: 31 fps with it, 37 fps without). Encoding 4:2:2 natively skips it.
# Measured live at 1280x720, 30 s each, on the C922:
#   422 -> 900/900 frames, dup=0,  speed 0.999x
#   420 -> 900/900 frames, dup=7,  speed 0.992x
# Both pass, but 422 is the one with headroom, and headroom is what the
# original complaint was about: a detailed/moving scene makes the JPEGs bigger
# and the decode slower, and 420 is the one that runs out first.
# Set CHROMA=420 if anything downstream ever chokes on High 4:2:2 (146 does
# -c copy so it cannot care; the PC's ffplay decodes 422 in software fine).
CHROMA=${CHROMA:-422}
case "$CHROMA" in
  422) PROFILE=high422; PIXFMT=yuvj422p ;;
  420) PROFILE=baseline; PIXFMT=yuv420p ;;
  *) echo "CHROMA must be 422 or 420, got '$CHROMA'" >&2; exit 1 ;;
esac
# CORRECTED 2026-09-16. The old note here claimed tun0 "tops out around
# ~2 Mbit/s" and that BR=5000k caused bufferbloat. That was read off the RF:
# telemetry field while it was BROKEN -- it divided the byte delta by POLL_INT
# while the loop actually took 8-12 s, inflating every figure. With that fixed,
# RF: sits at 2477-2566 kbit/s against BR=2500k: the link carries exactly what
# it is offered, with 5.3% CRC drop and no queue growth (the latency probe held
# +/-24 ms over 55 s). There is no ~2 Mbit/s ceiling.
#
# Documented R3 capacity is 12.7 Mbit/s forward / 13.7 reverse, and video runs
# 148->146 = REVERSE. Both budgets measured 2026-09-16 with a paced UDP blast
# (link) and a live 720p30 encode (board), so neither is guesswork any more:
#
#   offered   LINK delivered / CRC drop      148 ENCODER speed / q
#   2500k     (live stream) 2477-2566        0.996x  q=33
#   4000k     4028k  2.5%                    0.994x  q=31
#   6000k     6080k  1.8%                    0.995x  q=30
#   8000k     8158k  0.39%                   0.987x  q=29
#  11000k    11207k  0.27%                   0.96x   q=28  (10000k)
#
# Two counter-intuitive results worth keeping. (1) Bitrate is nearly FREE on
# the encoder: 2500k->8000k costs 0.9% of speed, because the chain is
# serialisation-limited on the single-threaded MJPEG decode (ffmpeg draws only
# ~202% CPU with ~43% of the box idle) and x264 IS multithreaded, so the extra
# encode work spills onto cores the decode can never use. Raising BR is far
# safer than raising SIZE, which lands on the decode and has no headroom at all.
# (2) CRC drops are ~constant per unit TIME (30-100 per 10 s) rather than per
# bit, so the loss PERCENTAGE falls as you use more of the link.
#
# 6000k is the sweet spot: no encoder cost vs 2500k, 3 q-points better, and
# still under half the link. 8000k is fine if you want it. Past that the q gain
# is 1 point per 2 Mbit/s while the encoder starts slipping -- not worth it.
BR=${BR:-6000k}
# bufsize = BR/VBV. Under -tune zerolatency this is not a frame-delay buffer,
# but it bounds burst size, and a burst still costs bufsize/BR seconds to get
# down the link -- so it is a real latency term worth VBV/1 seconds. It was 2
# (0.5 s), which is a lot of the glass-to-glass budget; 5 (0.2 s) is the
# compromise. Lower = tighter lag, more visible q dips on complex frames.
VBV=${VBV:-5}
# GOP is in FRAMES, but what matters for latency is SECONDS: it is the
# worst-case wait for a fresh decoder to find its first IDR, and because
# nothing downstream ever drains a backlog (see the PC block), that startup
# fill becomes permanent lag. A fixed frame count is therefore a trap -- the
# old hard-coded 20 is 0.67 s at OUTFPS=30 but a FOUR SECOND hole at OUTFPS=5,
# which is exactly how a low-fps test run ends up laggier than a high-fps one.
# Derive it from OUTFPS instead so the IDR interval stays fixed in SECONDS at
# any rate. Costs bitrate (more I-frames for the same quality), which we can
# afford: the link carries 12.7 Mbit/s and BR is 6000k.
#
# The divisor was 2 (0.5 s), then 4 (0.25 s), and is now 10 (0.10 s) because on
# a LOSSY link the IDR interval is also the SCRUB RATE, and that turned out to
# be the only encoder lever left once RESIL below was in. The reason is an
# invariant worth knowing (see RESIL for where its small print actually bites):
# the fraction of a frame that loss damages is ~= p regardless of bitrate or
# slice size, because smaller slices just means proportionally more of them.
# So you cannot tune the damage per frame down -- you can only shorten how long
# it lingers, and it lingers until the next IDR because every P-frame in
# between predicts from the damaged reference.
#
# Measured on 148 at 6000k with slice-max-size=1200, 8 s of testsrc2 (speeds
# taken while the live encoder was also running, so compare them only to each
# other, not to the ~1.13x idle figure):
#
#     GOP=15  0.50 s   q=27.0   I-frames 16   I-bit-share 14%
#     GOP=10  0.33 s   q=27.0   I-frames 24   I-bit-share 20%
#     GOP=8   0.26 s   q=27.0   I-frames 30   I-bit-share 24%   <-- the knee
#     GOP=5   0.16 s   q=28.0   I-frames 48   I-bit-share 35%
#
# q does not move until GOP=5, and CPU does not move at all (shorter GOP is
# marginally FASTER -- under -preset ultrafast an I-frame is cheaper than a
# motion-searched P-frame). Shorter also helps startup lag, since GOP is the
# worst-case wait for a fresh decoder to find its first IDR.
# Divisor 10 (0.10 s), not 4 (0.25 s), since 2026-09-17. The table above was
# taken against 2-4% loss. The link now measures 16.5% per-datagram loss in
# CLEAN windows (90.8% of 4245 s over 849 windows) and 33.5% in storms, which
# at ~19 datagrams/frame means 1-(1-0.165)^19 = 97% of frames arrive damaged.
# At that rate the IDR interval has stopped being a latency knob and is the only
# thing bounding how long corruption stays on screen: 233 ms at GOP=7, 100 ms at
# GOP=3. Modelled mean on-screen corruption over a GOP (with RESIL=600 below)
# falls from ~61% at G=7 to ~41% at G=3.
#
# This is an EXTRAPOLATION past the measured table and it is NOT free: GOP=5
# already cost 1 q-point at 35% I-bit-share, so expect q ~28-29 and roughly half
# the bitrate spent on I-frames. Affordable -- BR=6000k into a 13 Mbit/s link --
# and CPU is not a concern (shorter GOP measured marginally FASTER under
# -preset ultrafast, since an I-frame is cheaper than a motion-searched P).
# Set GOP=7 to restore the 0.25 s behaviour.
#
# Ceiling form with a floor of 3, NOT `OUTFPS / 10 > 2 ? OUTFPS / 10 : 2`:
# integer truncation there silently ships GOP=2 for every rate from 10 to 29
# fps, i.e. near-all-intra by accident at exactly the rates a test run uses.
GOP=${GOP:-$(( (OUTFPS + 9) / 10 > 3 ? (OUTFPS + 9) / 10 : 3 ))}
# Error resilience. This is the answer to "the picture falls apart when anything
# MOVES", which is not an encoder-quality problem at all -- it is the RF hop
# losing packets, measured on 2026-09-16 at 14.00% over a live 30 s window
# (19581 sent / 16841 received) and 2-4% even when the carrier is locked, with
# stochastic storms to 24-56%. See [[intermittent-carrier-lock-loss-2026-09]].
# 148's tun0 showed dropped=0 errors=0 and 146's UDP socket InErrors=0
# RcvbufErrors=0 Recv-Q=0, so none of it is host-side queueing; it is the radio.
#
# Motion does not CAUSE loss. Loss is ~constant per packet; motion raises the
# number of packets per frame, and a frame dies if ANY of its packets die:
#
#     P(frame damaged) = 1 - (1-p)^(packets per frame),  p = 3%
#     static P-frame     ~3 pkts ->  9%
#     motion P-frame    ~19 pkts -> 44%
#     I-frame           ~76 pkts -> 90%      <-- the killer
#
# That last row is why it never recovers: the I-frames that exist precisely to
# scrub out corruption are themselves ~90% likely to arrive broken.
#
# What fixes it is SLICING, and only slicing. Measured on 148, 240 frames of
# testsrc2 at the live settings, counted out of the actual bitstream (ffprobe
# does not exist on that board -- dump with `-f h264`, count NAL start codes,
# group by access-unit delimiter):
#
#                          I-frames  slices/I  biggest slice  slices/P  speed
#     neither                    16       4.0        29192 B       4.0  ~1.15x
#     slice-max-size=1200        16      52.2         1194 B      22.1   1.13x
#     + intra-refresh=1           1      63.0         1194 B      23.7   1.12x
#
# slice-max-size caps every slice BELOW the 1316 B datagram, so a lost packet
# costs a band of macroblocks the decoder resynchronises out of at the next
# slice header, instead of the whole picture: ~2 slices of 52 on an I-frame,
# ~5% of the area, against a 78-90% chance of losing the entire frame before.
# Bitrate is unchanged at 1200 (6079 vs 6066 KiB for the same clip).
#
# 600, not 1200, since 2026-09-17. The invariant above -- "damaged fraction ~= p
# regardless of slice size" -- is the S->0 LIMIT, not the whole story, and at
# S=1200 we are nowhere near it. A lost datagram of D bytes straddles D/S + 1
# slices and each one costs its FULL S bytes, so the damage is D + S, not D:
#
#     S=1316 (~unsliced)     2632 B per lost datagram    2.00 x the limit
#     S=1200 (what shipped)  2516 B                      1.91 x
#     S= 600                 1916 B                      1.46 x
#     S= 400                 1716 B                      1.30 x
#
# At the measured 16.5% clean-window loss and ~19 datagrams/frame that is 3.1
# lost datagrams per frame, so corrupted area goes 31.6% -> 24.1% of the
# picture. A ~24% relative improvement. It is not a fix and it does not touch p.
#
# 600 and not 400 because the only costs are slice-header overhead and CPU, the
# encoder measured 0.995x speed at 6000k (about 0.5% of headroom), and the
# camera was disconnected when this was chosen so the CPU cost could NOT be
# measured. Before dropping to 400, check `speed=` in /tmp/qpsk_stream/tx.log
# stays above 1.00x; if it falls below 1.00x, go back up. Above 1316 the whole
# mechanism switches off -- a slice must fit inside one datagram.
#
# DO NOT re-add intra-refresh=1. It was tried on 2026-09-16 and reverted the
# same day. The table above is the reason: cutting I-frames from 16 to 1 buys
# nothing once each I-frame is already 52 independent slices -- the 76-packet
# all-or-nothing frame that made intra-refresh look necessary does not exist
# any more. What it DOES buy is a visible vertical line sweeping left-to-right
# across the picture twice a second (once per $GOP frames, forever -- it is not
# a startup transient), because with 2-4% loss that line is the boundary
# between the part of the frame already scrubbed this sweep and the part still
# holding accumulated corruption. Users report it immediately.
#
# Set RESIL= (empty) to go back to unsliced 4-slice frames.
RESIL=${RESIL:-slice-max-size=600}
X264OPTS=""; [ -n "$RESIL" ] && X264OPTS="-x264opts $RESIL"
PORT=${PORT:-5002}              # RF video 148->146; the preflight probe uses 5001
LATPORT=${LATPORT:-5003}        # continuous latency probe, over tun0, 148->146
RELAY_PORT=${RELAY_PORT:-5010}  # 146's TCP listen port, on 146's LAN IP, for the PC to pull
LOCAL_PORT=${LOCAL_PORT:-5020}  # unused now (kept so old env overrides don't error); see FIFO below
POLL_INT=${POLL_INT:-5}         # telemetry report cadence, same as the existing "sleep 5"
LATPROBE_INT=${LATPROBE_INT:-2} # how often 148 sends a latency-probe packet
LOGDIR=/tmp/qpsk_stream          # shared with stream_board2board.sh's own log files
FIFO=${FIFO:-$LOGDIR/relay.fifo} # PC-local re-hop between the puller and ffplay: a named pipe,
                                 # not loopback UDP. UDP needs a fifo_size guess that's either too
                                 # big (multi-second buffer -> constant added delay, since a pipe's
                                 # capacity in bytes doesn't track $BR at all) or too small (drops
                                 # mid-frame TS data -> corrupted/green decode, e.g. losing part of
                                 # a keyframe). A pipe has neither failure mode: the OS pipe buffer
                                 # is small and fixed (~64KB, a couple hundred ms of video), it never
                                 # silently drops data, and a slow reader applies real backpressure
                                 # (write() blocks) instead of either dropping or queuing megabytes.
SKIP_PREFLIGHT=${SKIP_PREFLIGHT:-1} # set to 1 to skip the preflight probe (for debugging only)

# --------------------------------------------------------- TX supervision --
# Every name here MUST be declared with ${:-}: set -u is on (:60), and an unset
# variable aborts this script mid-bring-up -- with 146's relay already
# listening and only an INT/TERM trap (:377) to tear it down, i.e. no teardown.
#
# Why any of this exists. Over 128 min on 2026-09-17 the BRIO (046d:085e, on a
# SuperSpeed root port with no power switching, so the kernel's "attempt power
# cycle" is a hardware no-op) logged 10x "Failed to resubmit video URB (-19)"
# and 6 USB disconnects. ffmpeg died with each one --
# "ioctl(VIDIOC_DQBUF): No such device" -- and NOTHING restarted it, because TX
# below was a bare `exec ffmpeg` with no loop, unlike the 146 relay. Dead air
# was 83 s + 503 s = 587 s, 7.6% of the session. No encoder knob in this file
# is worth 7.6%.
TXRESTART=${TXRESTART:-1}       # 0 restores the old unsupervised bare `exec ffmpeg`
TXBACKOFF=${TXBACKOFF:-2}       # first retry delay in s; doubles per consecutive failure
TXBACKOFF_MAX=${TXBACKOFF_MAX:-30}
TXKILLWAIT=${TXKILLWAIT:-3}     # seconds to wait after TERM before SIGKILL. A wedged ffmpeg
                                # ignores TERM (measured 2026-09-17) and keeps $DEV forever.
TXSTALL_POLL=${TXSTALL_POLL:-5} # how often to check the encoder is still WRITING, not just alive
TXSTALL_STRIKES=${TXSTALL_STRIKES:-3}   # consecutive zero-output polls before SIGKILL; 0 disables
                                # NB the signal is ffmpeg's own -progress total_size, NOT
                                # /proc/PID/io -- see the watchdog comment in TX for why that
                                # counter reads 0 on a PERFECTLY HEALTHY encoder.
TXDEV=${TXDEV:-$DEV}            # node the SUPERVISOR opens. A re-enumerating BRIO can come back
                                # as a different videoN; if that bites, set TXDEV to the stable
                                # /dev/v4l/by-id/usb-046d_Logitech_BRIO_*-video-index0 path.

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
  # tx.pid is the SUPERVISOR (see TX below), not ffmpeg. A plain kill reaps the
  # supervisor and leaves the ffmpeg it backgrounded holding $DEV open, so the
  # next run dies with EBUSY on the v4l2 input. tx.sh is launched under setsid
  # (:483) so pid == pgid -- kill the group, exactly as CLEANUP146 does for
  # relay.pid at :262-263. tx.state/tx_ff.pid go with it.
  run "$A" "P=\$(cat $LOGDIR/tx.pid 2>/dev/null)
[ -n \"\$P\" ] && { kill -TERM -\$P 2>/dev/null; kill -TERM \$P 2>/dev/null; sleep 3
                  kill -KILL -\$P 2>/dev/null; kill -KILL \$P 2>/dev/null; }
H=\$(fuser $DEV 2>/dev/null | tr -d ' '); [ -n \"\$H\" ] && kill -KILL \$H 2>/dev/null
[ -f $LOGDIR/latprobe_tx.pid ] && kill \$(cat $LOGDIR/latprobe_tx.pid) 2>/dev/null
rm -f $LOGDIR/tx.pid $LOGDIR/tx_ff.pid $LOGDIR/tx.state $LOGDIR/latprobe_tx.pid; true" >/dev/null 2>&1
  run "$B" "$CLEANUP146" >/dev/null 2>&1
  local P
  P=$(cat "$LOGDIR/pc.pid" 2>/dev/null)
  [ -n "$P" ] && { kill -TERM -"$P" 2>/dev/null; kill -TERM "$P" 2>/dev/null; }
  rm -f "$LOGDIR/pc.pid"
  pkill -f "[r]elay.fifo" 2>/dev/null
  # Fallback for a MISSING or STALE pc.pid: the group kill above then hits nothing
  # and the three `bash pc.sh` shells (session leader + the puller and player
  # restart loops) survive to respawn ffmpeg/ffplay. Anchored on the full path from
  # $LOGDIR rather than a bare substring, per the header rule -- this script's own
  # argv is "bash .../ops/stream_board2pc.sh" and cannot match it, and pgrep never
  # returns itself. Skipping $$ as well costs nothing and documents the intent.
  local p
  for p in $(pgrep -f "$LOGDIR/pc\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    kill -TERM "-$p" 2>/dev/null   # pc.sh is a session leader: take the group
    kill -TERM "$p"  2>/dev/null
  done
  rm -f "$FIFO"
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

# ------------------------------------------------------------------ hardware --
echo "== hardware =="
cam=$(run "$A" "ls $DEV >/dev/null 2>&1 && echo YES || echo NO" | tr -dc A-Z)
# Not fatal any more when TXRESTART=1. The BRIO disconnected 6x in 30 min on
# 2026-09-17 with outages of 83 s and 503 s, so this gate used to make the
# script un-startable for minutes at a time over a condition the TX supervisor
# below simply waits out. Still fatal with TXRESTART=0, where nothing is
# waiting for the device.
if [ "$cam" = YES ]; then
  echo "   148 camera : $DEV"
else
  [ "$TXRESTART" = 1 ] || die "no $DEV on 148 ($A). The camera must be on 148, the TX side.
  If it is plugged into 146, move it -- 146->148 is the degraded RF direction."
  echo "   148 camera : $DEV ABSENT -- the TX supervisor will wait for re-enumeration."
  echo "                If it never appears, check it is on 148 and not 146 (146->148"
  echo "                is the degraded RF direction), and see dmesg on 148 for -19 URB errors."
fi

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

# Teardown has to survive EVERY exit path, not just Ctrl-C. pc.sh is launched under
# setsid, so it is its own session leader (pid == pgid, different from this script's
# pgid) and a terminal SIGHUP never reaches it. With only INT/TERM trapped, closing
# the terminal killed this script silently while pc.sh lived on with its restart
# loops intact, respawning ffmpeg/ffplay -- the handful of leftover processes that
# all match "stream" and have to be killed by hand before the next run. HUP covers
# that; EXIT covers die(), an unhandled error, and a normal fall-through.
# EXIT traps do not fire in subshells or command substitution (measured), so the
# only overlap to guard is INT/TERM and EXIT both firing on one teardown.
CLEANED=0
cleanup_once(){
  if [ "${CLEANED:-0}" = 1 ]; then return 0; fi
  CLEANED=1
  echo; echo "== stopping =="; stop_all; echo "   done"
}
trap 'cleanup_once; exit 0' INT TERM HUP
trap 'cleanup_once' EXIT

# -------------------------------------------------------------- relay (146) --
# Started FIRST so the TCP listener is up before the PC tries to connect, and
# before 148 sends a single packet. -c copy is a remux, not a decode -- 146
# never touches a pixel. ffmpeg's TCP listen mode serves exactly one client
# and then exits, so this is wrapped in a restart loop, exactly like the
# receiver side being "started first" in stream_board2board.sh.
RELAY="echo \$\$ > $LOGDIR/relay.pid
while :; do
  /usr/local/bin/ffmpeg -hide_banner -loglevel warning -fflags nobuffer -flags low_delay \
    -analyzeduration 0 -probesize 32768\
    -i 'udp://$TB:$PORT?fifo_size=1000&overrun_nonfatal=1' \
    -c copy -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 -max_interleave_delta 0 'tcp://0.0.0.0:$RELAY_PORT?listen=1&send_buffer_size=65536'
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
#
# The input rate is pinned by v4l2-ctl --set-parm in PRIME below instead of by
# -framerate, which does the same thing but reports what it actually got rather
# than stalling on a mismatch.
TX="#!/bin/sh
# Supervisor, not a bare exec. Measured 2026-09-17: the BRIO dropped off USB 6
# times in 30 min, ffmpeg died each time with 'ioctl(VIDIOC_DQBUF): No such
# device', and nothing restarted it -- one outage ran 503 s (8m23s) while the
# monitor loop below cheerfully printed camera=UP. 587 s of dead air in 128 min.
#
# Explicit #!/bin/sh: this file has no shebang today and relies on the ENOEXEC
# fallback in the caller's shell, so keep everything below POSIX.
#
# tx.pid is now THIS supervisor (pid == pgid, tx.sh runs under setsid below, so
# both kill sites can take the whole group). tx_ff.pid is the live ffmpeg.
# tx.state is one word for the monitor loop.
echo \$\$ > $LOGDIR/tx.pid
echo WAITCAM > $LOGDIR/tx.state
FF=
SL=
# FF is ffmpeg, SL is the current backoff sleep -- they MUST be separate. A
# shell trap is deferred until the current FOREGROUND command returns, so every
# sleep is backgrounded and wait-ed; leave one in the foreground and a --stop
# during a 30 s backoff sits there for 30 s. (Measured: 56 ms vs ~24 s.)
nap(){ sleep \$1 & SL=\$!; wait \$SL 2>/dev/null; SL=; }
# Only drop the pidfile if it is still OURS -- a bare rm would delete the
# pidfile of a newer session that had already replaced us.
droppid(){ [ \"\$(cat $LOGDIR/tx.pid 2>/dev/null)\" = \"\$\$\" ] && rm -f $LOGDIR/tx.pid $LOGDIR/tx_ff.pid $LOGDIR/tx.state; true; }
# TERM is NOT enough, measured 2026-09-17: a wedged ffmpeg (all 5 threads in
# futex_wait, holding /dev/video0, 254 bytes written in 4 minutes) ignored two
# SIGTERMs and kept the device, so every later launch died EBUSY forever.
# Always escalate.
reap(){ [ -n \"\$1\" ] || return 0
  kill -TERM \$1 2>/dev/null
  i=0; while kill -0 \$1 2>/dev/null && [ \$i -lt $TXKILLWAIT ]; do sleep 1; i=\$(( i + 1 )); done
  kill -KILL \$1 2>/dev/null; true; }
bye(){ [ -n \"\$SL\" ] && kill -TERM \$SL 2>/dev/null; reap \"\$FF\"; droppid; exit 0; }
trap bye INT TERM
d=$TXBACKOFF
while :; do
  # The node disappears entirely across a re-enumeration and returns a second
  # or two later. Wait for it rather than thrashing ffmpeg against ENODEV.
  if [ ! -e $TXDEV ]; then
    [ \"\$(cat $LOGDIR/tx.state 2>/dev/null)\" = WAITCAM ] || echo \"[\$(date +%T)] $TXDEV absent -- waiting for USB re-enumeration\"
    echo WAITCAM > $LOGDIR/tx.state
    nap 2
    continue
  fi
  # Re-prime on EVERY start. Both controls live on the USB DEVICE and are reset
  # to their defaults by the re-enumeration that follows a disconnect, so the
  # one-shot prime below is silently lost after the first dropout -- and
  # exposure_dynamic_framerate=1 measured dup=131 vs dup=0 at 1280x720.
  for c in exposure_dynamic_framerate=0 power_line_frequency=1; do
    v4l2-ctl -d $TXDEV --set-ctrl=\$c >/dev/null 2>&1
  done
  v4l2-ctl -d $TXDEV --set-parm=$OUTFPS >/dev/null 2>&1
  # Clear any FOREIGN holder of the node before opening it. This is the exact
  # failure of 2026-09-17: an orphaned ffmpeg from a previous session (PPID 1,
  # 0% CPU, wedged in futex, immune to TERM) sat on /dev/video0 and every
  # relaunch printed 'Error opening input: Device or resource busy'. The backoff
  # then doubled to its ceiling and retried that forever -- EBUSY is not a
  # transient, so waiting it out is never the answer. Nothing else on 148 opens
  # the camera, so anything holding it here is by definition debris.
  H=\$(fuser $TXDEV 2>/dev/null | tr -d ' ')
  if [ -n \"\$H\" ]; then
    echo \"[\$(date +%T)] $TXDEV held by stale pid(s) \$H -- SIGKILL (EBUSY never clears on its own)\"
    kill -KILL \$H 2>/dev/null
    nap 1
  fi
  echo ENCODING > $LOGDIR/tx.state
  t0=\$(date +%s)
  # Fresh progress file per launch: the watchdog below compares successive
  # reads, so a dead encoder's final total_size must not be inherited by its
  # replacement (that would read as 'frozen' and kill a healthy start).
  rm -f $LOGDIR/tx_progress.log
  /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
   -f v4l2 -input_format $INFMT -video_size $SIZE -i $TXDEV \
   -an -c:v libx264 -preset ultrafast -tune zerolatency -profile:v $PROFILE $X264OPTS \
   -b:v $BR -maxrate $BR -bufsize $((${BR%k}/VBV))k -g $GOP -r $OUTFPS -pix_fmt $PIXFMT \
   -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 \
   'udp://$TB:$PORT?pkt_size=1316' \
   -progress $LOGDIR/tx_progress.log -stats_period 1 -nostats &
  FF=\$!
  echo \$FF > $LOGDIR/tx_ff.pid
  # Stall watchdog. 'ffmpeg is running' is NOT 'video is flowing': on
  # 2026-09-17 the encoder held the camera and its UDP socket for 4 minutes at
  # 0% CPU with every thread in futex_wait_queue and tun0 carrying 790 bytes
  # total, while tx.state read ENCODING and the monitor line read
  # 'camera=ENCODING RF: 0kbit/s' the whole time. A process
  # that produces nothing is indistinguishable from a healthy one unless you
  # watch its OUTPUT, so watch it.
  #
  # DO NOT use /proc/PID/io for this. The first version of this watchdog polled
  # wchar and it SIGKILLed a perfectly healthy encoder every 15 s, because those
  # counters are blind to this process at BOTH ends. Measured on 148 against a
  # live encoder airing 6432 kbit/s at 196% CPU, over 4 s:
  #
  #     wchar delta 0      syscw delta 0      rchar delta 0
  #     tun0 tx_bytes delta 3216172 B
  #
  # rchar/wchar count vfs_read/vfs_write bytes only: V4L2 capture arrives in
  # mmap'd buffers (no read()) and the UDP output leaves via sendto()/sendmsg()
  # (no write()). So 'wchar frozen' is TRUE of a healthy encoder, and the
  # earlier observation of wchar=254 on the wedged one was real but did not
  # DISCRIMINATE -- both states read zero.
  #
  # ffmpeg's own -progress total_size is the honest signal: it is this
  # process's muxed output byte count, it advances only when frames actually
  # reach the muxer, and unlike tun0 tx_bytes it is not inflated by the latency
  # probe (which keeps tun0 ticking with a dead encoder and would mask a stall).
  # An empty/missing read resets the strike count, so a slow start is safe.
  last=; strikes=0
  while kill -0 \$FF 2>/dev/null; do
    nap $TXSTALL_POLL
    kill -0 \$FF 2>/dev/null || break
    cur=\$(tail -c 4000 $LOGDIR/tx_progress.log 2>/dev/null | awk -F= '/^total_size=/{v=\$2} END{print v}')
    if [ -n \"\$cur\" ] && [ \"\$cur\" = \"\$last\" ]; then strikes=\$(( strikes + 1 )); else strikes=0; fi
    last=\$cur
    if [ \$strikes -ge $TXSTALL_STRIKES ]; then
      echo \"[\$(date +%T)] encoder muxed 0 bytes for \$(( $TXSTALL_POLL * $TXSTALL_STRIKES ))s (total_size stuck at \$cur) -- SIGKILL and restart\"
      echo STALLED > $LOGDIR/tx.state
      kill -KILL \$FF 2>/dev/null
      break
    fi
  done
  wait \$FF; rc=\$?; FF=
  rm -f $LOGDIR/tx_ff.pid
  [ \"$TXRESTART\" = 1 ] || { droppid; exit \$rc; }
  # Reset the backoff after any run that actually streamed, so one bad night
  # does not leave the next clean restart waiting the full 30 s.
  [ \$(( \$(date +%s) - t0 )) -ge 60 ] && d=$TXBACKOFF
  echo RETRY > $LOGDIR/tx.state
  echo \"[\$(date +%T)] encoder exited rc=\$rc -- restarting in \${d}s\"
  nap \$d
  d=\$(( d * 2 )); [ \$d -gt $TXBACKOFF_MAX ] && d=$TXBACKOFF_MAX
done"

# Continuous latency probe, sender half -- same shape as PROBE_TX above, just
# looping forever at LATPROBE_INT instead of firing 100 packets once.
LATPROBE_TX='import socket, time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("'"$TA"'",0))
while True:
    s.sendto(str(time.time()).encode(), ("'"$TB"'", '"$LATPORT"'))
    time.sleep('"$LATPROBE_INT"')'

echo "== starting camera on 148 =="
# Group kill, for the same reason as in stop_all(): tx.pid is the supervisor,
# and a plain kill orphans its ffmpeg onto $DEV -- which then makes the v4l2
# open below fail with EBUSY, i.e. the restart this whole block exists to
# enable would fail on the very first re-run.
run "$A" "mkdir -p $LOGDIR
P=\$(cat $LOGDIR/tx.pid 2>/dev/null)
[ -n \"\$P\" ] && { kill -TERM -\$P 2>/dev/null; kill -TERM \$P 2>/dev/null; sleep 3
                  kill -KILL -\$P 2>/dev/null; kill -KILL \$P 2>/dev/null; }
# And anything else still holding the camera, recorded pid or not. On
# 2026-09-17 an orphan whose pidfile had already been removed sat on $DEV and
# made every launch fail EBUSY; without this the script cannot self-heal from
# its own previous crash.
H=\$(fuser $DEV 2>/dev/null | tr -d ' ')
[ -n \"\$H\" ] && { echo \"   clearing stale holder(s) of $DEV: \$H\"; kill -KILL \$H 2>/dev/null; sleep 1; }
[ -f $LOGDIR/latprobe_tx.pid ] && kill \$(cat $LOGDIR/latprobe_tx.pid) 2>/dev/null
rm -f $LOGDIR/tx.pid $LOGDIR/tx_ff.pid $LOGDIR/tx.state $LOGDIR/latprobe_tx.pid; true" >/dev/null

# Camera priming. Both of these are set on the DEVICE, persist until unplug,
# and are invisible in any ffmpeg log -- which is what made the C922 so
# confusing to diagnose.
#
# exposure_dynamic_framerate=1 (found set on BOTH cameras, though the UVC
# default is 0) lets the sensor lengthen its exposure past the frame interval
# in dim light and quietly deliver fewer frames. ffmpeg cannot tell the
# difference between that and a slow encoder: it just duplicates frames to fill
# the gap, so the symptom is a rising dup= count and "fps drops when I hold
# something in front of the camera" -- exactly the original report. Measured
# at 1280x720: dup=131 with it on, dup=0 with it off, same everything else.
#
# The device is busy for a moment after the kill above, and --set-parm on a
# busy node fails with EBUSY, hence the settle.
sleep 1
run "$A" "for c in exposure_dynamic_framerate=0 power_line_frequency=1; do
  v4l2-ctl -d $DEV --set-ctrl=\$c 2>&1 | sed 's/^/   /'
done
echo -n '   input rate: '; v4l2-ctl -d $DEV --set-parm=$OUTFPS 2>&1 | tail -1

# 148 has no monitor attached (card0-DP-1 reads 'disconnected'), so Xorg there
# crash-loops forever and lightdm+polkitd+dbus burn ~30% of the box respawning
# it. That is 30% stolen from the encode, and at 720p30 the encode has no 30%
# to spare. Fixed once with 'systemctl mask --now lightdm', which is persistent
# -- but a reimage brings it back, so warn rather than depend on it silently.
if pgrep -x Xorg >/dev/null 2>&1; then
  echo '   WARNING: Xorg is running on 148 and no monitor is attached.'
  echo '            It steals ~30% CPU from the encode. Fix with:'
  echo '              systemctl mask --now lightdm'
fi"

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
rm -f "$FIFO"
mkfifo "$FIFO"
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
# Once a backlog forms ANYWHERE in this chain, nothing ever drains it: every
# stage plays timestamps, and a uniformly-late stream is indistinguishable from
# an on-time one (ffplay's master clock comes from the stream's own PTS, not
# from wall clock, so -framedrop only fires on A/V desync -- never on "the
# whole stream is 3 s behind reality"). So the ONLY lever on glass-to-glass lag
# is to stop the pipeline filling in the first place: keep every buffer small.
#
# -probesize is a real term and worth keeping small, but it was NOT the big one
# -- see the audio note below for that. It is easy to over-weight because it
# hides in plain sight: it is denominated in BYTES, so its cost in SECONDS
# scales inversely with bitrate, which retrodicts the old numbers suspiciously
# well (500000 B is 1.60 s/stage at 2500 kbit/s but 0.67 s/stage at 6000 kbit/s,
# x3 stages) without actually being the cause. 32768 B is 44 ms at 6000k and
# still spans several PAT/PMT periods (the mpegts muxer emits those every
# 100 ms), so stream detection is unaffected. -analyzeduration 0 is safe for the
# same reason: the stream layout is fixed and known, there is nothing to
# discover by waiting.
#
# NO AUDIO TRACK. There used to be a silent anullsrc one here, on the theory
# that it gave ffplay a steady sound-card-paced clock instead of letting it
# free-run on jittery video-only PTS. It was measured on 2026-09-16 and it was
# THE dominant latency term in the whole pipeline -- worth 1.5-3.2 s on its own,
# more than 148, the encoder and the RF hop put together. Same TX, same 75 s,
# only the audio track differing:
#
#     with anullsrc : lag 1236 -> 4474 -> 2807 ms, ffplay vq = 3121 KB
#     video only    : lag 1304 -> 1372 ms (flat),  ffplay vq =    0 KB
#
# 3000 KB of queued video at 6000 kbit/s IS four seconds of picture sitting
# inside ffplay. The mechanism is the clock selection: ffplay makes AUDIO the
# master clock whenever an audio stream exists (its stats line says so -- "A-V:"
# with the track, "M-V:" without), and on this PC the audio device is WSLg's
# PulseAudio/RDP bridge, which has a deep buffer and is not rate-locked to
# anything. Video then gets slaved to that clock and piles up waiting for it.
#
# -framedrop cannot rescue this, and the reason is the same one as above: ffplay
# reported "A-V: -0.011" throughout, i.e. by its own reckoning it was in perfect
# sync. It was. Audio and video were equally late. -framedrop fires on A/V
# desync, and a uniformly-late stream has none. Do not add an audio track back
# to get a "better clock" -- video-master is measured flat here, 0 KB queued.
#
# -max_interleave_delta 0 is now belt-and-braces (there is only one stream left
# to interleave), but it costs nothing and guards against anyone re-adding a
# second one: the default is 10000000 us, i.e. the muxer will hold up to TEN
# SECONDS of one stream waiting for the other to catch up in DTS.
(
  while :; do
    "$FFMPEG_PC" -y -hide_banner -loglevel warning -fflags nobuffer -flags low_delay \\
      -analyzeduration 0 -probesize 32768 \\
      -i 'tcp://$B:$RELAY_PORT?recv_buffer_size=65536' \\
      -map 0:v -c:v copy \\
      -f mpegts -muxdelay 0 -muxpreload 0 -flush_packets 1 -max_interleave_delta 0 '$FIFO' \\
      -progress $LOGDIR/pc_progress.log -nostats
    sleep 1
  done
) &
# ffplay gets its own restart loop too: a named pipe has EOF semantics a UDP
# socket never did -- if the writer above bounces (relay restart, RF blip),
# ffplay sees EOF on the pipe and exits, so it needs to re-open it, same as
# the writer re-opening after its own restart.
(
  while :; do
    "$FFPLAY_PC" -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -framedrop \\
      -analyzeduration 0 -probesize 32768 \\
      -i '$FIFO'
    sleep 1
  done
) &
wait
PCEOF
chmod 755 "$LOGDIR/pc.sh"
echo "== starting puller + ffplay on this PC =="
[ -f "$LOGDIR/pc.pid" ] && kill "$(cat "$LOGDIR/pc.pid")" 2>/dev/null
rm -f "$LOGDIR/pc.pid"
setsid "$LOGDIR/pc.sh" > "$LOGDIR/pc.log" 2>&1 < /dev/null &
echo "   pulling tcp://$B:$RELAY_PORT -> local pipe -> ffplay window"

echo
echo "== streaming =="
echo "   allow ~4 s for the C270's first frame, plus a couple seconds for the"
echo "   TCP connect + ffplay window to appear."
echo "   stop with:  bash $0 --stop     (or Ctrl-C here)"
echo

# Report from ALL THREE points. A one-ended report cannot distinguish a
# stalled camera from a hop that is dropping everything, or the PC's own
# decode from the RF link itself.
prev=0; prevt=0
while :; do
  sleep "$POLL_INT"
  # tx.pid is the SUPERVISOR now, so kill -0 on it is no longer a liveness test
  # for the encoder: it would have printed camera=UP for all 503 s of the
  # 2026-09-17 outage. Report tx.state (ENCODING / WAITCAM / RETRY) instead, and
  # reserve DOWN for the supervisor itself being gone -- which keeps the
  # teardown at the bottom of this loop firing only on a real session death, so
  # a camera dropout no longer tears the whole stream down. An empty result
  # (ssh blip) is deliberately NOT mapped to DOWN; it prints as "?" below.
  tx=$(run "$A" "P=\$(cat $LOGDIR/tx.pid 2>/dev/null)
if [ -n \"\$P\" ] && kill -0 \$P 2>/dev/null; then
  S=\$(cat $LOGDIR/tx.state 2>/dev/null)
  echo \${S:-STARTING}
else
  echo DOWN
fi" | tr -dc A-Z)
  rxb=$(run "$B" "cat /sys/class/net/tun0/statistics/rx_bytes 2>/dev/null" | tr -dc 0-9); : "${rxb:=0}"
  # Rate over the REAL elapsed time, not POLL_INT. Each pass makes six
  # sequential password-ssh round trips, so a loop with POLL_INT=5 actually
  # takes 8-12 s; dividing the byte delta by 5 inflated every RF: reading by
  # that ratio and produced figures like 5760 kbit/s for a 2500k stream --
  # which makes the field useless for comparing against the documented R3
  # capacity. Millisecond clock, integer math, and a guard for the first pass.
  nowms=$(date +%s%3N)
  if [ "$prevt" -gt 0 ] && [ "$nowms" -gt "$prevt" ]; then
    rfrate=$(( (rxb - prev) * 8 / (nowms - prevt) ))
  else
    rfrate=0
  fi
  prev=$rxb; prevt=$nowms

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
  printf "BR:%-5s  SIZE:%-9s  OUTFPS:%-3s\n" "$BR" "$SIZE" "$OUTFPS"
  # %-8s, not %-4s: the field now carries ENCODING/WAITCAM/STARTING, not UP/DOWN.
  # ${tx:-?} because an ssh round-trip failure yields an empty string, and a
  # blank column reads as a stall when it only means "could not ask".
  printf "   camera=%-8s RF:%5dkbit/s  PC:%skbit/s %sfps  link:%s %s %s %s  lat148->146:%sms\n" \
    "${tx:-?}" "$rfrate" "$pc_kbit" "$pc_fps" "${fail:-resync_fail=?}" "${rec:-recovered=?}" "${lost:-tail_lost=?}" "${wd:-?}" "${lat:-?}"

  if [ "$tx" = DOWN ]; then
    echo "   camera side exited:";     run "$A" "tail -6 $LOGDIR/tx.log" | sed 's/^/     148 /'
    echo "   relay log:";              run "$B" "tail -6 $LOGDIR/relay.log" | sed 's/^/     146 /'
    echo "   latency probe logs:";     run "$A" "tail -3 $LOGDIR/latprobe_tx.log" | sed 's/^/     148 /'
    run "$B" "tail -3 $LOGDIR/latprobe_rx.log" | sed 's/^/     146 /'
    stop_all
    break
  fi
done
