#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
exec "$D/capture_r3.sh" A -d 600 -k -o "$D/r3cap/ballpark_fwd_after_20260903_151147"
