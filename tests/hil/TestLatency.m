classdef TestLatency < HilBase
    %TESTLATENCY  L3: RF-link latency matrix + category verdict.
    %   Drives `link_test.sh lat` (payload + interval sweeps + app-level RTT),
    %   parses the ping transcripts, builds the percentile report via
    %   latency_report_k5 (writing docs into the bundle), and gates on
    %   sanity: an idle -s32 cell must be measurable and land at category C or
    %   better (loss <= 10%, p90 <= 250 ms). The detailed characterization
    %   lives in the report, not the assertions.

    methods (Test, TestTags = {'L3'})
        function latencyCategorized(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hil_lat.log');
            [~, out] = tc.linktest('lat -w', log);
            bundle = regexp(out, 'LAT_DONE (\S+)', 'tokens', 'once');
            tc.assertNotEmpty(bundle, 'lat run produced no bundle');
            b = bundle{1};

            % assemble cells from the forward payload sweep
            cells = struct('name', {}, 'rtt_ms', {}, 'sent', {});
            for s = [8 16 32 56 88 120 200]
                f = fullfile(b, sprintf('ping_fwd_s%d.log', s));
                if ~isfile(f), continue; end
                t = parse_ping(fileread(f));
                cells(end+1) = struct('name', sprintf('idle -s%d fwd', s), ...
                    'rtt_ms', t.rtt_ms, 'sent', 200); %#ok<AGROW>
            end
            tc.assertNotEmpty(cells, 'no ping cells parsed');

            rep = latency_report_k5(cells, fullfile(b, 'LINKCHAR_LATENCY.md'));
            fprintf('latency category: %s (frame %.2f ms)\n', rep.category, rep.frameMs);

            % sanity gate: idle -s32 measurable and not category D
            idleRow = rep.table(rep.table.cell == "idle -s32 fwd", :);
            tc.assertNotEmpty(idleRow, 'no idle -s32 cell');
            tc.verifyGreaterThan(idleRow.n, 0, 'idle -s32 got no replies');
            tc.verifyLessThanOrEqual(idleRow.loss_pct, 10, 'idle -s32 loss > 10%');
            tc.verifyLessThanOrEqual(idleRow.p90_ms, 250, 'idle -s32 p90 > 250 ms');
            % retire the impossible "~5 ms RTT" assumption with data
            tc.verifyGreaterThanOrEqual(idleRow.p50_ms, rep.frameMs, ...
                'RTT below one frame time is physically impossible');
        end
    end
end
