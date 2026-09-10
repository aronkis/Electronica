classdef TestParsers < matlab.unittest.TestCase
    %TESTPARSERS  L1: the L3 transcript parsers + latency report.
    %   Feeds representative tool output to parse_qpsk_perf / parse_ping /
    %   parse_iperf_json / latency_report_k5 and checks the extracted values,
    %   so the L3 characterization can trust them before a board session.

    methods (TestClassSetup)
        function addHelpers(tc)
            p = modem_paths();
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(p.helpers));
        end
    end

    methods (Test, TestTags = {'L1'})

        function qpskPerf(tc)
            txt = [ ...
                'PERF_SRV t=1.0 rx_pkts=284 rx_kbps=199.8 cum_pkts=284 lost=0 dup=0', newline, ...
                'PERF_RTT seq=0 rtt_us=41.5', newline, ...
                'PERF_RTT seq=1 rtt_us=94.2', newline, ...
                'PERF_CLI_DONE tx_pkts=569 tx_bytes=50072 offered_kbps=200.0 sent_kbps=200.0 dur=2.0', newline, ...
                'PERF_RTT_SUMMARY ok=569 lost=0 rtt_min_us=41.5 rtt_mean_us=95.4 rtt_max_us=602.6', newline, ...
                'PERF_SRV_DONE rx_pkts=569 rx_bytes=50072 lost=0 dup=0 reorder=0', newline];
            s = parse_qpsk_perf(txt);
            tc.verifyEqual(s.cli.tx_pkts, 569);
            tc.verifyEqual(s.cli.sent_kbps, 200.0, 'AbsTol', 1e-9);
            tc.verifyEqual(s.srv.rx_pkts, 569);
            tc.verifyEqual(s.srv.lost, 0);
            tc.verifyEqual(s.rtt.mean_us, 95.4, 'AbsTol', 1e-9);
            tc.verifyEqual(numel(s.rtts), 2);
            tc.verifyEqual(height(s.bins), 1);
        end

        function ping(tc)
            txt = [ ...
                '64 bytes from 10.66.0.1: icmp_seq=1 ttl=64 time=12.3 ms', newline, ...
                '64 bytes from 10.66.0.1: icmp_seq=2 ttl=64 time=15.8 ms', newline, ...
                '64 bytes from 10.66.0.1: icmp_seq=4 ttl=64 time=11.1 ms', newline];
            t = parse_ping(txt);
            tc.verifyEqual(height(t), 3, 'seq 3 was lost -> 3 rows');
            tc.verifyEqual(t.rtt_ms(2), 15.8, 'AbsTol', 1e-9);
            tc.verifyEqual(t.seq(3), 4);
        end

        function iperfUdp(tc)
            j = ['{"end":{"sum":{"bits_per_second":148900,"lost_percent":2.5,' ...
                 '"jitter_ms":3.1}}}'];
            s = parse_iperf_json(j);
            tc.verifyEqual(s.sent_kbps, 148.9, 'AbsTol', 1e-6);
            tc.verifyEqual(s.lost_percent, 2.5, 'AbsTol', 1e-9);
            tc.verifyEqual(s.jitter_ms, 3.1, 'AbsTol', 1e-9);
        end

        function latencyCategory(tc)
            % idle -s32 p90 ~ 22 ms -> category A; a loaded cell + a lossy cell
            rng(7);
            cells(1) = struct('name','idle -s32 fwd', 'rtt_ms', 10+12*rand(200,1), 'sent',200);
            cells(2) = struct('name','load90 -s32 fwd', 'rtt_ms', 30+40*rand(200,1), 'sent',200);
            cells(3) = struct('name','frag -s200 fwd', 'rtt_ms', 20+10*rand(150,1), 'sent',200);
            f = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            out = fullfile(f.Folder, 'lat.md');
            rep = latency_report_k5(cells, out);
            tc.verifyEqual(height(rep.table), 3);
            tc.verifySubstring(rep.category, 'A', 'idle p90<40 should be interactive');
            tc.verifyTrue(isfile(out), 'report file written');
            % the fragmented cell shows loss (150 of 200 arrived)
            fragRow = rep.table(rep.table.cell=="frag -s200 fwd", :);
            tc.verifyGreaterThan(fragRow.loss_pct, 20);
        end

    end
end
