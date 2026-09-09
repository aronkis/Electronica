#!/bin/bash
# restore_r3_go.sh -- rig-unit wrapper for `bringup_r2r3.sh r3`.
#
# WHY THIS EXISTS.  launch_rig_unit.sh's signature is <unit> <script> [env=val ...]:
# every argument after the script becomes a --setenv, NOT a positional argument.  So
# `launch_rig_unit.sh restore-t13 bringup_r2r3.sh r3` starts a unit that runs the
# bring-up with NO mode argument, and it dies on its own usage check (`line 45: 1:
# usage: bringup_r2r3.sh r2|r3`) before touching either board.  txfix_flash_go.sh
# exists for exactly the same reason; this is the same pattern for the hand-back.
exec bash "$(dirname "$0")/../bringup_r2r3.sh" r3
