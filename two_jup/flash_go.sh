#!/bin/bash
# flash_go.sh -- rig-unit wrapper: launch_rig_unit.sh passes no positional args, so the md5 lives here.
exec bash "$(dirname "$0")/skidfix/flash_148_ddrcap2.sh" 638b36de3493
