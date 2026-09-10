classdef TestDecodeSelftestK5 < matlab.unittest.TestCase
    %TESTDECODESELFTESTK5  L1: synthetic end-to-end decode selftest.
    %   Converted from contract/selftest_decode_k5.m (which hardcoded the retired
    %   qpsk_variants tree). Generates synthetic air exactly per the legacy Tx
    %   contract (Barker preamble + golden payload, pi/4 QPSK, sqrt-RRC 0.5/4
    %   @ 8 sps, +400 Hz CFO, 0.37-sample fractional + 137-sample integer
    %   offset, 20 dB AWGN), runs soak_decode_k5, and gates decode integrity.
    %   Pure MATLAB (Communications Toolbox); no hardware, no Simulink. The
    %   capture is written to a temp file, not the repo.

    properties (Constant)
        NF = 5; SPS = 8; FS = 1.92e6; CFO = 400; FRAC = 0.37; PAD = 137;
        CAPG = uint32(hex2dec('04922282'));
    end

    properties
        capfile
    end

    methods (TestClassSetup)
        function addK5(tc)
            p = modem_paths();
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(p.k5));
            f = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.capfile = fullfile(f.Folder, 'selftest_k5.iq');
        end
    end

    methods (Test, TestTags = {'L1'})
        function decodeGatesPass(tc)
            tc.genSyntheticAir();
            res = soak_decode_k5(tc.capfile, 'label', 'SELFTEST');

            goldenMask = arrayfun(@(f) f.capOut==tc.CAPG && f.infoErr==0, res.perFrame);

            % gate 1: >= NF-1 frames golden (first may be lost to acquisition)
            tc.verifyGreaterThanOrEqual(res.nGolden, tc.NF-1, ...
                sprintf('only %d of %d frames golden', res.nGolden, tc.NF));
            % gate 2: zero info-bit errors on golden frames
            tc.verifyEqual(sum([res.perFrame(goldenMask).infoErr]), 0, ...
                'info-bit errors on golden frames');
            % gate 3: decoder CAP_OUT golden
            tc.verifyEqual(res.capGolden, tc.CAPG, 'decoder capGolden != 0x04922282');
            tc.verifyEqual(res.nGolden, sum(goldenMask), 'nGolden vs goldenMask mismatch');
            % gate 4: frame spacing exactly 1133 sym * 8 sps = 9064 samples
            spacing = diff(res.frameStarts) * res.sps;
            tc.assertNotEmpty(spacing, 'fewer than 2 frames detected');
            tc.verifyEqual(spacing, repmat(9064, size(spacing)), ...
                sprintf('frame spacing [%s] != 9064', num2str(spacing)));
        end
    end

    methods (Access = private)
        function genSyntheticAir(tc)
            p = modem_paths();
            G = load(fullfile(p.k5, 'golden_k5.mat'));
            payload = double(G.payload(:));
            tc.assertEqual(numel(payload), 2240, 'payload must be 2240 bits');

            barker = [1 1 1 1 1 0 0 1 1 0 1 0 1];
            preBits = [barker; barker]; preBits = preBits(:);   % I/Q-interleaved, 26 bits
            frameBits = [preBits; payload];                     % 2266 bits = 1133 symbols
            bI = frameBits(1:2:end); bQ = frameBits(2:2:end);
            frameSyms = pskmod(bI*2+bQ, 4, pi/4, 'gray');
            tc.assertEqual(numel(frameSyms), 1133);

            syms = repmat(frameSyms(:), tc.NF, 1);
            rrc = rcosdesign(0.5, 4, tc.SPS);
            txp = upfirdn(syms, rrc, tc.SPS);

            n = (0:numel(txp)-1).';
            txd = interp1(n, txp, n - tc.FRAC, 'spline', 0);
            x = [zeros(tc.PAD,1); txd; zeros(tc.PAD,1)];
            x = x .* exp(1i*2*pi*tc.CFO*(0:numel(x)-1).'/tc.FS);
            rng(1234, 'twister');
            x = awgn(x, 20, 'measured');

            x = x/max(abs(x))*0.6*32767;
            iw = zeros(2*numel(x),1,'int16');
            iw(1:2:end) = int16(round(real(x)));
            iw(2:2:end) = int16(round(imag(x)));
            fid = fopen(tc.capfile, 'w');
            tc.assertGreaterThan(fid, 0, 'cannot open temp capfile');
            fwrite(fid, iw, 'int16'); fclose(fid);
        end
    end
end
