#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
exec "$D/capture_r3.sh" B -d 600 -k -o "$D/r3cap/ballpark_rev2_20260903_143523"
