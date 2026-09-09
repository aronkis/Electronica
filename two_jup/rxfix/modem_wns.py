#!/usr/bin/env python3
"""modem_wns.py -- pull the MODEM CLOCK's intra-clock WNS out of a Vivado
`report_timing_summary` routed report.

  modem_wns.py <system_top_timing_summary_routed.rpt> [clock]

Why this exists (RXFIX Task 13, gate; see two_jup/comb/RXFIX_W1_TIMING.md sec 0).
`TXFIX_ROUTED_WNS` in the build log is `STATS.WNS [get_runs impl_1]`, i.e. the
design's OVERALL worst slack -- and on this board that path is a zero-logic-level
Recovery check on the ADRV9001 IDELAYCTRL reset in the `**async_default**` group,
which moves +-0.04 ns with placement and which no modem edit can influence.  The
number that gates a modem netlist change is the intra-clock WNS of
`axi_adrv9001_adc_1_clk` (8.000 ns).  Known-good calibration values from the two
banked builds:  SEQ-BIST a1ff3c876d91 = 0.227 ns, RXFIX_W1 2728dab3979a = 0.169 ns.

Prints one line:  MODEM_CLK_WNS clock=<name> wns=<ns> tns=<ns> failing=<n> total=<n>
Exit 0 if the row was found and WNS >= 0, 1 if WNS < 0, 2 if not found.
"""
import re
import sys

DEFAULT_CLK = 'axi_adrv9001_adc_1_clk'


def intra_clock_row(path, clk):
    """Return (wns, tns, failing, total) from the Intra Clock Table row for `clk`.

    The table lists a clock per line, WNS in the first numeric column; derived
    clocks are INDENTED under their generator (axi_adrv9001_adc_1_clk sits under
    rx1_dclk_out), so the name is matched after stripping.  Only the Intra Clock
    Table is scanned -- the Inter Clock and Other Path Groups tables further down
    carry the same clock name with different numbers.
    """
    inside = False
    with open(path, errors='replace') as fh:
        for line in fh:
            if 'Intra Clock Table' in line:
                inside = True
                continue
            if inside and re.search(r'\|\s*(Inter Clock Table|Other Path Groups Table|'
                                    r'User Ignored Path Table|Unconstrained Path Table)', line):
                break
            if not inside:
                continue
            s = line.rstrip('\n')
            if not s.strip() or s.lstrip().startswith(('-', '|', 'Clock')):
                continue
            name = s.strip().split()[0]
            if name != clk:
                continue
            rest = s.strip()[len(name):].split()
            if len(rest) < 4:
                return None
            return float(rest[0]), float(rest[1]), int(rest[2]), int(rest[3])
    return None


def main(argv):
    if not 2 <= len(argv) <= 3:
        print(__doc__.strip())
        return 2
    clk = argv[2] if len(argv) == 3 else DEFAULT_CLK
    row = intra_clock_row(argv[1], clk)
    if row is None:
        print(f"MODEM_CLK_WNS_NOT_FOUND clock={clk} file={argv[1]}")
        return 2
    wns, tns, failing, total = row
    print(f"MODEM_CLK_WNS clock={clk} wns={wns} tns={tns} failing={failing} total={total}")
    return 0 if wns >= 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
