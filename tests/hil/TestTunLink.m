classdef TestTunLink < HilBase
    %TESTTUNLINK  L3: tun0 IP link bring-up + bidirectional reachability.
    %   Drives `link_test.sh tun` (arm both boards, qpsk_tun -F, watchdog,
    %   tun0 config), then asserts the tun0 contract on both boards and that
    %   real ICMP crosses in both directions. Leaves the link UP
    %   (QPSK_KEEP_LINK) so a chained L3 session (lat/perf/ssh) reuses it
    %   without re-arming -- re-arm churn is the risk to the fragile boards.

    methods (Test, TestTags = {'L3'})
        function tunUpBothWays(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hil_tun.log');
            [~, out] = tc.linktest('tun -w', log);   % -w: whitener on both ends

            % tun0 config contract on both boards
            for spec = {tc.A_IP, tc.TUN_A; tc.B_IP, tc.TUN_B}'
                ip = spec{1}; addr = spec{2};
                [~, cfg] = tc.anyssh(ip, 'ip -o addr show tun0 2>/dev/null; ip -o link show tun0 2>/dev/null');
                tc.verifySubstring(cfg, addr, sprintf('%s tun0 missing addr %s', ip, addr));
                tc.verifySubstring(cfg, 'mtu 116', sprintf('%s tun0 MTU != 116', ip));
            end

            % bidirectional ping census (whitened link); record, gate soft
            fwd = tc.pingCensus(tc.B_IP, tc.TUN_A, 100);
            rev = tc.pingCensus(tc.A_IP, tc.TUN_B, 100);
            fprintf('tun ping: fwd %.0f%% deliver, rev %.0f%% deliver\n', ...
                fwd.deliver, rev.deliver);
            tc.verifyGreaterThan(fwd.deliver, 60, 'forward tun delivery < 60%');
            tc.verifyGreaterThan(rev.deliver, 60, 'reverse tun delivery < 60%');
        end
    end

    methods (Access = private)
        function s = pingCensus(tc, srcIp, dstTun, n)
            [~, out] = tc.anyssh(srcIp, sprintf('ping -c %d -i 0.2 -s 32 -W 2 %s 2>&1 | tail -4', n, dstTun));
            r = regexp(out, '(\d+) packets transmitted, (\d+) received', 'tokens', 'once');
            if isempty(r)
                s.deliver = 0;
            else
                s.deliver = 100 * str2double(r{2}) / max(1, str2double(r{1}));
            end
        end
    end
end
