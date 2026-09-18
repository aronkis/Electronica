So the real question is why R3, which your table says should give 12.7 Mbit/s at 8–10% error, is only delivering ~2Mbit/s effective throughput with a huge CRC-drop rate. Looking at the actual counters from 146:

dma_rx_ok=68293   crc_drop=117452   (63% of received frames are being dropped as corrupt)
rxresync: resync_fail=107511  recovered=17162  tail_lost=2334
watchdog: LOCKED (drstcs=0 dpkts=6243 lvl=0)

drstcs=0 rules out the known "intermittent carrier-lock loss" fault (that one shows drstcs≈dpkts). But the combination of full-rate framing/lock reported ("LOCKED") while payload is being destroyed at a ~63% CRC-drop rate is exactly the signature of the known byte-flip carrier-sync wedge I have on file: bring-up can come out "framing at rate but decoding zero/garbage payload" about 8% of the time, and — critically — the ARM GATE and lock_watchdog.sh's "LOCKED" both structurally can't detect it, because they only score framing, not CRC. That matches this situation almost exactly (severe CRC failure despite a healthy-looking watchdog).

The documented cure is a re-arm — either just re-running the board's own bring-up again (since it's probabilistic, ~92% chance of coming up clean), or if it keeps wedging, the specific canonical byte re-arm sequence (register pokes on axi-adrv9002-tx-lpc) that's already proven to take a wedged board from 0%→97.5% yield instantly.

This is a hardware re-arm action on the boards, so I want to check with you before running it — want me to run the bring-up again (WATCHDOG=0 GATE_DIR=B bash /root/Electronica/two_jup/bringup_r2r3.sh r3) to try for a clean lock, or would you rather run it yourself and we re-test the pipeline after?