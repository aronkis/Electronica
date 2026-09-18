#!/usr/bin/env bash
# Install a media stack on a Jupiter board that has NO INTERNET.
#
# WHY NOT apt:
#   146 has no default route and DNS does not resolve, so `apt install ffmpeg`
#   fails at the fetch step even though apt-cache shows a candidate. Debian's
#   ffmpeg also drags in ~100 shared-library packages, which is a miserable
#   thing to sneakernet one .deb at a time.
#
# WHAT THIS INSTALLS INSTEAD:
#   offline_pkgs/ffmpeg-*-arm64-static/ffmpeg -- ONE statically linked aarch64
#   binary (verified: --enable-gpl --enable-libx264, video4linux2 indev built
#   in). It depends on nothing on the board, not even glibc.
#
#   NOTE: the static build has NO ffplay -- upstream omits it because ffplay
#   needs SDL2, which cannot be linked statically here. The board can CAPTURE
#   and ENCODE but not display. board_webcam.py's --http mode covers viewing
#   without any player at all (any browser renders it).
#
# WHERE IT GOES:
#   /usr/local/bin, NOT /dev/shm. The relay helpers in stream_webcam.sh live in
#   /dev/shm and are lost on every reboot; a 49 MB binary should not be. The
#   rootfs has ~20 GB free, so this costs nothing.
set -u
D=$(cd "$(dirname "$0")" && pwd)
HOST=${1:-10.0.0.146}
SRC=$(ls -d "$D"/offline_pkgs/ffmpeg-*-arm64-static 2>/dev/null | head -1)
DEST=/usr/local/bin

die(){ echo "ERROR: $*" >&2; exit 1; }
denoise(){ grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq"; }

# stdin-preserving ssh (anyssh.sh redirects stdin from /dev/null, which would
# swallow the binary we are piping in).
sshin(){ IP="$1"; shift
  SSH_ASKPASS="$D/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    setsid -w ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no root@"$IP" "$@"; }

[ -n "$SRC" ] || die "no static ffmpeg found under $D/offline_pkgs.
  Fetch it on a machine WITH internet:
    mkdir -p $D/offline_pkgs && cd $D/offline_pkgs
    curl -O https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz
    tar xJf ffmpeg-release-arm64-static.tar.xz"
[ -f "$SRC/ffmpeg" ] || die "$SRC/ffmpeg missing"

echo "== target $HOST =="
arch=$("$D/anyssh.sh" "$HOST" 'uname -m' 2>/dev/null | denoise | tr -d '\r\n ')
[ "$arch" = aarch64 ] || die "board reports arch '$arch', expected aarch64"

# Skip a 24 MB transfer if the same binary is already there.
want=$(md5sum "$SRC/ffmpeg" | cut -d' ' -f1)
have=$("$D/anyssh.sh" "$HOST" "md5sum $DEST/ffmpeg 2>/dev/null | cut -d' ' -f1" \
        2>/dev/null | denoise | tr -d '\r\n ')
if [ "$want" = "$have" ]; then
  echo "  ffmpeg already installed and identical -- skipping transfer"
else
  echo "== pushing ffmpeg ($(du -h "$SRC/ffmpeg" | cut -f1) raw, ~24 MB gzipped) =="
  echo "   this takes a minute over password ssh; no progress bar is expected"
  # Write to a temp name and mv into place, so an interrupted transfer can
  # never leave a half-written binary that looks installed.
  gzip -c "$SRC/ffmpeg" \
    | sshin "$HOST" "cat > /tmp/ffmpeg.gz && gunzip -f -c /tmp/ffmpeg.gz > $DEST/.ffmpeg.new \
        && chmod 755 $DEST/.ffmpeg.new && mv -f $DEST/.ffmpeg.new $DEST/ffmpeg \
        && rm -f /tmp/ffmpeg.gz && echo PUSHED" 2>&1 | denoise
fi

echo "== pushing board_webcam.py (stdlib-only capture; no ffmpeg required) =="
B64=$(base64 -w0 "$D/board_webcam.py")
"$D/anyssh.sh" "$HOST" "echo $B64 | base64 -d > $DEST/board_webcam.py && chmod 755 $DEST/board_webcam.py && echo PUSHED" 2>&1 | denoise

echo "== verifying =="
# The probe is written to a file and PIPED IN as base64, never passed as an ssh
# argument. Passed as an argument it is one giant double-quoted string, and in
# that context a leading # does NOT start a comment -- so a prose comment that
# happens to contain a " silently ends the string, splices the rest of the
# script into shell words, and produces a syntax error dozens of lines away.
# That cost a debugging round on 2026-09-11. Piping removes the whole class.
VERIFY=$(mktemp /tmp/board_media_verify.XXXXXX)
trap 'rm -f "$VERIFY"' EXIT
cat > "$VERIFY" <<'PROBE'
DEST=/usr/local/bin
echo -n '  ffmpeg   : '; $DEST/ffmpeg -version 2>&1 | head -1 || echo MISSING
echo -n '  v4l2 in  : '; $DEST/ffmpeg -hide_banner -devices 2>&1 | grep -c video4linux2
echo -n '  libx264  : '; $DEST/ffmpeg -hide_banner -encoders 2>&1 | grep -c ' libx264 '
echo -n '  display  : '
# NOT -f xv. Measured 2026-09-10: BOTH boards answer "No X-Video adaptors
# present" -- Xorg falls back to modesetting, which exposes no Xv adaptor.
# -f fbdev works but only with -pix_fmt rgb565le (fb0 is 16 bpp) AND with
# lightdm stopped, because Xorg owns the DRM scanout -- and that kills the
# desktop. The supported route is a chromium window fed by mjpeg_serve.py;
# see stream_board2board.sh.
if pgrep -x Xorg >/dev/null; then
  printf 'Xorg up'
  if command -v chromium >/dev/null || command -v chromium-browser >/dev/null; then
    echo ' + chromium -> can show the video window'
  else
    echo ' but NO chromium -- cannot show a window'
  fi
elif [ -e /dev/fb0 ]; then
  echo "console framebuffer only ($(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)); start lightdm for a window"
else
  echo 'none -- no monitor attached, TX side only'
fi
# A board with no camera is NOT a failed install -- the receive side legitimately
# has none. The probe runs for 8s, not 3s: the C270 takes ~3.9s to deliver its
# first frame, so a 3s window reports one frame and looks like a broken 0.3 fps.
if [ -e /dev/video0 ]; then
  echo '  camera   : /dev/video0 present'
  echo '  py grab  :'; python3 $DEST/board_webcam.py --stats 8 2>&1 | sed 's/^/    /' | tail -6
else
  echo '  camera   : none -- plug the C270 in here to make this the video source'
fi
PROBE
"$D/anyssh.sh" "$HOST" "echo $(base64 -w0 "$VERIFY") | base64 -d | bash" 2>&1 | denoise

cat <<EOF

== installed ==
  $DEST/ffmpeg            static, no dependencies, survives reboot
  $DEST/board_webcam.py   stdlib capture: --stats / --http / --udp / --file

Quick check on the board:
  board_webcam.py --stats 5              measure real fps + bitrate
  board_webcam.py --http 8080            view at http://$HOST:8080/ in a browser
EOF
