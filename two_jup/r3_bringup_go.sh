#!/bin/bash
D=$(cd "$(dirname "$0")" && pwd)
exec "$D/bringup_r2r3.sh" r3
