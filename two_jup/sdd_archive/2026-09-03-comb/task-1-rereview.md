# Task 1 re-review (scoped, read-only) — commit d69d3e9

Reviewed `git show d69d3e9 --stat` and the full diff against the commit's own
tree (`git show d69d3e9:<path>`, not the live working tree, since
`two_jup/comb/legrun_go.sh` and `two_jup/bringup_r2r3.sh` and
`two_jup/comb/deploy_daemon_go.sh` are currently dirty with a concurrent,
out-of-scope C-1 fix that shifts their line numbers). No rig contact, no
files edited.

## Verdict: Needs fixes (one line-citation error; everything else checks out)

## (a) Findings addressed

- I-1 (magic_off not an ALIGNLOSS discriminator, ~2.3% chance floor): correct.
  1527 positions × 2^-16 ≈ 0.0233 ≈ 2.3%, matches both `qpsk_join.h` and
  README §3.3. Text is honest that it's a Poisson approximation of "at least
  one match," which is fine at this magnitude.
- I-2 (class 4 split on `first_zero_off == 0` vs `> 0`): the delivery-plane
  mechanism is correctly described for the RXQ path — `rx_q_submit()` (called
  from `rx_pump_queued`) zeroes the carve before each arm at
  `qpsk_tun.c:1461` (QPSK_RXQ_STAT, non-zerohdr branch) and `:1466` (`#else`
  branch), confirmed against `git show d69d3e9:host_app_k5/qpsk_tun.c`.
  **But the ":1203 cyclic" half of the citation is wrong** — see Finding 1
  below.
- I-3 (`HOST_CFLAGS_B='-DQPSK_RXQ_STAT'` recipe, no `-DQPSK_ARQ_NAKSTAT` via
  `HOST_CFLAGS`): correct. `capture_r3.sh:126-127` builds with `$BCF` (set
  from `HOST_CFLAGS_B` only for `$B_IP`, i.e. 146), the `case "$BCF" in
  *QPSK_RXQ_STAT*)` verify gate is at `:139-140`, and `NAKKEEP` (`:119-120`)
  already auto-detects and carries `-DQPSK_ARQ_NAKSTAT` per board from the
  deployed binary's strings, independent of `HOST_CFLAGS`.
- I-4 (`QPSK_TXLOG_USR1=1` on legs): the reasoning is internally consistent —
  `capture_r3.sh:294` (`for ip in $RX_IP $PEER_IP; do $W $ip 'pkill -USR1
  -x qpsk_tun ...'`) is the only SIGUSR1 send in the script and fires once,
  after the traffic window, so the extra 32 MiB write costs nothing there.
- I-5 (stale BLOCKER removed): correct. `qpsk_join.h` is in both deploy lists
  at the commit's own tree state — `capture_r3.sh:108` and
  `deploy_daemon_go.sh:41` — confirmed via `git show d69d3e9:<path>`.
- Minors: `QPSK_MAGOFF_NONE`/alias comment is accurate (slice ≤
  `QPSK_PKT_BYTES_MAX` = 1528 B, can't reach 0xFFFF). `QPSK_FRAMELOG` /
  SIGUSR2 claim is exact: `signal(SIGUSR2, on_usr2);` is at
  `qpsk_tun.c:3266` inside the `QPSK_FRAMELOG` block, confirmed line-for-line.
  §5.4.1's `bringup_r2r3.sh:167` citation is correct at the commit's tree
  state: line 167 is the actual launch command containing `${DAEMON_ENV:-}`
  (verified via `git show d69d3e9:two_jup/bringup_r2r3.sh`), not merely a
  comment as it appears to be in the current dirty working tree (a red
  herring from the concurrent C-1 edit). `legrun_go.sh:77`'s "wholesale
  overwrite" description is also accurate at the commit's tree state
  (`CAP_ENV+=("DAEMON_ENV=QPSK_RX_DRAIN_BUDGET=$DRAIN_RESOLVED")`), and is
  correctly flagged as Task 3's to fix, not touched here.

## (b)/(c) C logic: unchanged

All four changed files (`host_app_k5/qpsk_join.h`, `two_jup/comb/
README_hostlog.md`, and the two `sdd_archive` docs) are comment/prose-only.
In `qpsk_join.h` the diff only touches block comments above
`QPSK_MAGOFF_NONE`, `qpsk_first_magic_off()`, and `qpsk_fail_class()`; no
macro value or function body line changed.

## Finding 1 (fix required): `:1203 cyclic` mislabels the code

Both `qpsk_join.h`'s new `qpsk_fail_class` comment ("`rx_pump_queued zeroes
the carve before each arm (qpsk_tun.c:1461/1466, :1203 cyclic)`") and
`README_hostlog.md` §"Caveats you must not lose" (identical wording, "`:1203`
for the cyclic path") misidentify line 1203. `qpsk_tun.c:1203` is inside
`rx_arm()` (the legacy/default double-buffer path, taken when neither
`rx_cyclic` nor `rx_queued` is set — see the `rx_pump_frame` dispatch at
`qpsk_tun.c:1752-1759`). It is **not** part of the `rx_pump_queued` call graph
and it is **not** the `QPSK_RX_CYCLIC` ring path.

The actual cyclic-ring path is `rx_arm_cyclic()` / `rx_pump_cyclic()`
(`qpsk_tun.c:1256` / `:1314`), and its own comment states the opposite of
what's being cited: *"With the per-arm carve_zero gone, every slot holds a
valid-CRC frame after lap 1"* — i.e. the real `QPSK_RX_CYCLIC` path does
**not** zero the carve at all. `bringup_r2r3.sh` shows 148 can run
`RXCYC_A=1` (cyclic) in production, so this is not a dead mode.

Net effect: the carve-zero explanation for class-4/`first_zero_off==0` holes
is correct for the RXQ path (`:1461`/`:1466`) but the parenthetical extending
it to "the cyclic path" via `:1203` is false, and could mislead someone
scoring a cyclic-mode (148) capture into expecting the same carve-zero
signature that the queued path produces.

**Fix**: in both `host_app_k5/qpsk_join.h` (~line 102) and
`two_jup/comb/README_hostlog.md` (~line 89), either drop the `:1203 cyclic`
clause entirely, or replace it with an accurate statement — e.g. that
`rx_arm()` (`qpsk_tun.c:1203`, the legacy non-queued/non-cyclic path) also
zeroes the carve on each arm, while `rx_arm_cyclic()` (`:1256`) explicitly
does not, so the carve-zero explanation for class-4 holes does not apply to
`QPSK_RX_CYCLIC=1` captures (e.g. any leg with `RXCYC_A=1`).

No other line citation checked (`qpsk_tun.c:1461/1466`, `:3266`;
`capture_r3.sh:108/119-120/127/139-140/294`; `bringup_r2r3.sh:167`;
`deploy_daemon_go.sh:41`; `legrun_go.sh:77`) had a discrepancy.
