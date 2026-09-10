# Test suite — MATLAB is the primary runner

`runTests.m` is the single entry point. It discovers every `TestCase` under
`tests/`, selects by level tag, runs with JUnit-XML + TAP output into
`tests/results/` (gitignored), and exits nonzero on failure under
`matlab -batch` (CI contract).

```
matlab -batch "cd tests; runTests"          % L1 (default), target < 3 min
matlab -batch "cd tests; runTests('L2')"     % HDL gate stamps (exec: RUN_GATES=1)
matlab -batch "cd tests; runTests('L3')"     % hardware-in-loop (QPSK_HIL=1 + boards)
matlab -batch "cd tests; runTests('all')"    % everything the env permits
```

Single file during development: `mcp__matlab__run_matlab_test_file` on any
class, or `runtests('TestFrameContract')` after `addpath tests/helpers`.

## Levels

| Level | What | Needs | Time |
|---|---|---|---|
| **L1** | host-pure: C tests (`make test`), MATLAB↔C frame contract, byte-helper + decode selftests, tun/tap loopback | nothing (tun/tap tests need root — see below) | seconds |
| **L2** | HDL gate verdicts | stamp mode: nothing; exec mode: `RUN_GATES=1` (~30 min, MATLAB+Vivado) | s / 30 min |
| **L3** | RF link: tun bring-up, latency, iperf/UDP, TCP, SSH usability | `QPSK_HIL=1` + both boards up (10.0.0.148/146) | 2-3 h |

Env guards make stray runs harmless: an L3 file without `QPSK_HIL=1`
assumes-out to *Incomplete* (never touches the boards); an L2 file without
`RUN_GATES=1` only reads the existing gate stamps.

## Root-gated host tests

`TestTunLoopbackHost` and `TestTapLoopbackHost` drive a real `/dev/net/tun`
fd in network namespaces, which needs root. Without it they report
*Incomplete* (not failed), so an unprivileged L1 run stays green. To exercise
them:

```
sudo -E matlab -batch "cd tests; runTests"
```

## Dev-box toolchain note

`run_shell` prefixes `PATH` with `/usr/bin:/bin` because this dev box has a
`~/.local/bin/as` that shadows the real GNU assembler; on-board builds are
unaffected. If you invoke `make` outside the suite, do the same.

## Layout

- `runTests.m` — runner
- `Test*.m` — L1/L2 classes (host-pure + gate wrappers)
- `hil/` — L3 classes (`HilBase` provides the `QPSK_HIL` guard + hunt-bundle fixture)
- `helpers/` — `modem_paths`, `run_shell`, parsers, `latency_report_k5`
- `results/` — JUnit/TAP output (gitignored)
