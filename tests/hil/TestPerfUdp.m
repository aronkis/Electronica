classdef TestPerfUdp < HilBase
    %TESTPERFUDP  L3: UDP throughput rate ladder over the RF link.
    %   Drives `link_test.sh perf` (qpsk_perf UDP ladder 25..180 kbit/s both
    %   directions + iperf3 TCP characterization), parses the per-rung server
    %   logs, and asserts the low rungs deliver cleanly while documenting the
    %   saturation knee. The link ceiling is ~149 kbit/s UDP goodput at -l 88
    %   (1 frame/datagram); rungs at/above 160k are expected to show loss.

    methods (Test, TestTags = {'L3'})
        function udpLadderDelivers(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hil_perf.log');
            [~, out] = tc.linktest('perf -w', log);
            bundle = regexp(out, 'PERF_DONE (\S+)', 'tokens', 'once');
            tc.assertNotEmpty(bundle, 'perf run produced no bundle');
            b = bundle{1};

            % parse the forward server logs across the ladder; a low rung must
            % deliver near-clean.
            lowClean = false;
            for rate = [25000 50000 75000 100000]
                f = fullfile(b, sprintf('udp_fwd_%d_srv.log', rate));
                if ~isfile(f), continue; end
                s = parse_qpsk_perf(fileread(f));
                if ~isempty(s.srv) && s.srv.rx_pkts > 0
                    lossFrac = s.srv.lost / max(1, s.srv.rx_pkts + s.srv.lost);
                    fprintf('UDP fwd %d bps: rx=%d lost=%d (%.1f%%)\n', ...
                        rate, s.srv.rx_pkts, s.srv.lost, 100*lossFrac);
                    if lossFrac < 0.10, lowClean = true; end
                end
            end
            tc.verifyTrue(lowClean, 'no low UDP rung delivered < 10% loss');
        end
    end
end
