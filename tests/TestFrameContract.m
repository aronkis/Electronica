classdef TestFrameContract < matlab.unittest.TestCase
    %TESTFRAMECONTRACT  L1: the MATLAB<->C frame/wire contract.
    %   Guards the invariant that the offline MATLAB scorer
    %   (contract/seq_frame_bytes_k5.m, used by decode_seq_k5) produces the
    %   byte-identical wire frame that the C host app transmits
    %   (host/ qpsk_seq_expected, dumped by seq_dump). This is the pair
    %   that must never silently diverge -- a drift on either side makes every
    %   OTA BER/loss measurement wrong.
    %
    %   Also pins the frame geometry constants and the CAP_OUT BIST golden.

    properties (Constant)
        SEQS = [0 1 42 255 65535 4294967295];   % incl. wrap endpoints
        PKT  = 128;
        % C ground-truth header+CRC (bytes 1..12) for two seqs, captured
        % 2026-07-19 from seq_dump (qpsk_seq_expected). Build-independent guard.
        HDR0  = uint8([hex2dec('51') hex2dec('4b') hex2dec('40') 0 0 0 0 0 ...
                       hex2dec('9a') hex2dec('a9') hex2dec('ff') hex2dec('eb')]);
        HDR42 = uint8([hex2dec('51') hex2dec('4b') hex2dec('40') 0 hex2dec('2a') 0 0 0 ...
                       hex2dec('2a') hex2dec('45') hex2dec('f6') hex2dec('e3')]);
    end

    methods (TestClassSetup)
        function addK5(tc)
            p = modem_paths();
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(p.k5));
        end
    end

    methods (Test, TestTags = {'L1'})

        function matlabHeaderLiterals(tc)
            % MATLAB scorer must reproduce the recorded C header+CRC exactly.
            b0  = uint8(seq_frame_bytes_k5(0,  tc.PKT));
            b42 = uint8(seq_frame_bytes_k5(42, tc.PKT));
            tc.verifyEqual(b0(1:12).',  tc.HDR0,  'seq=0 header/CRC drift vs C ground-truth');
            tc.verifyEqual(b42(1:12).', tc.HDR42, 'seq=42 header/CRC drift vs C ground-truth');
        end

        function matlabMatchesCwireFormat(tc)
            % Runtime cross-check: build the C dumper, compare every byte for
            % a spread of seqs. Non-circular (two independent implementations).
            p = modem_paths();
            [rc,~] = run_shell('make -s seq_dump', 'Dir', p.host);
            tc.assumeEqual(rc, 0, 'could not build seq_dump (host toolchain)');
            seqArg = sprintf('%u ', tc.SEQS);
            [rc, out] = run_shell(sprintf('./seq_dump %d %s', tc.PKT, seqArg), 'Dir', p.host);
            tc.verifyEqual(rc, 0, 'seq_dump run failed');
            lines = strsplit(strtrim(out), newline);
            tc.verifyEqual(numel(lines), numel(tc.SEQS), 'seq_dump line count');
            for k = 1:numel(tc.SEQS)
                cbytes = uint8(sscanf(lines{k}, '%x').');
                mbytes = uint8(seq_frame_bytes_k5(tc.SEQS(k), tc.PKT)).';
                tc.verifyEqual(mbytes, cbytes, ...
                    sprintf('MATLAB vs C wire frame differ at seq=%u', tc.SEQS(k)));
            end
        end

        function crc32Contract(tc)
            % seq_crc32_k5 (zlib poly, CRC-field-zeroed) must match the CRC
            % embedded in the frame by the generator.
            for seq = tc.SEQS
                by = seq_frame_bytes_k5(seq, tc.PKT);
                embedded = uint32(by(9)) + bitshift(uint32(by(10)),8) + ...
                           bitshift(uint32(by(11)),16) + bitshift(uint32(by(12)),24);
                computed = uint32(seq_crc32_k5(by(1:76), 9:12));  % header+payload
                tc.verifyEqual(computed, embedded, ...
                    sprintf('CRC32 mismatch at seq=%u', seq));
            end
        end

        function frameGeometry(tc)
            % Pin the constants the whole link timing budget depends on.
            by = uint8(seq_frame_bytes_k5(0, tc.PKT));
            tc.verifyEqual(numel(by), 128, 'frame is 128 bytes');
            tc.verifyEqual(by(1:2).', uint8([hex2dec('51') hex2dec('4b')]), 'magic QK');
            tc.verifyEqual(by(3), uint8(64), 'payload len field = 64 (-S mode)');
            Fsym   = 240e3;
            SymPer = 1133;                       % 1120 payload + 13 Barker
            frameS = SymPer / Fsym;
            tc.verifyEqual(frameS, 4.720833333333e-3, 'AbsTol', 1e-9, ...
                'K5 frame time 1133/240k');
            fps = 1 / frameS;
            tc.verifyEqual(fps, 211.826, 'AbsTol', 1e-2, 'frames/sec');
        end

    end
end
