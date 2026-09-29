# `host_app_k5/` — FROZEN legacy tree. Not the code that runs the link.

**If you are setting the rig up or changing modem behaviour, you want
[`../host/`](../host/), not this directory.**

`ops/provision.sh` builds and deploys the host application from `../host/`
(`ops/provision.sh:29`, `SRC=$D/../host`). Nothing in `ops/` reads this tree.

## The two things called `host_app_k5`

They are unrelated; the name collision is the whole reason this file exists.

| | what it is |
|---|---|
| `host_app_k5/` (here) | a **frozen pre-cleanup copy** of the host sources, kept only so the legacy harnesses below still run. |
| `/root/host_app_k5` (on a board) | the **on-board install directory**, created by `ops/provision.sh` and filled from `../host/`. Renaming it is a rig operation, not a repo rename — see `tools/check_paths.sh` note (4). |

## How far it has drifted

`host/qpsk_tun.c` is 227,708 bytes; the copy here is 162,734 — **1,297 diff
lines apart** (measured 2026-09-25). None of the FEC, RX-dphase-carry or
queued-RX work exists here. Reading this file to understand current link
behaviour will mislead you.

## Why it has not been deleted

The repo's cleanup convention (`tools/check_paths.sh:8`) records the intended
rename `host_app_k5 -> host`, alongside `two_jup -> ops`. The `two_jup -> ops`
half is unfinished, and **22 scripts still compile or deploy from this tree by
relative path**, so deleting it breaks them:

- `jupiter_240k5_byte/rtl_sim/run_tgen_tb.sh:4-5` and `run_tgen_rx_tb.sh:6-7`
  build `tgen_golden` against `../../host_app_k5/{qpsk_seq.c,qpsk_frame.c}`.
  Repointing these at `host/` would change what the RTL testbench compares
  against, so it needs a measured golden-vector re-check, not a path edit.
- ~20 harnesses under `two_jup/` (`provision.sh:18`, `test.sh:25`,
  `link_test.sh`, `capture_r3.sh`, `beat_capture*.sh`, …) use it as their
  deploy source.

Four files also exist **only** here: `cyclic_ring_sim.c`, `dma_class_test.c`,
`zed/qpsk_byte_buf.dtsi`, `zed/ZEDBOARD_DEPLOY.md`.

## Rule

Do not edit this tree to change link behaviour — the change will not reach the
boards. Edit `../host/` and re-run `ops/provision.sh <ip>`.
