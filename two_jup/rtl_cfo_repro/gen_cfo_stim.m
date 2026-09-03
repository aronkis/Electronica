function gen_cfo_stim(outDir, mode, mapPerm)
%GEN_CFO_STIM  Synthetic f1536 int16 IQ stimuli for the tap-netlist CFO sweep.
%
%   gen_cfo_stim(outDir,'calib')          -> 24 mapping-candidate 4-frame files @0 Hz
%   gen_cfo_stim(outDir,'sweep',mapPerm)  -> G1 + signed CFO sweep, 50-frame files
%
% Physics model (operator item 2, 2026-08-26): hardware CFO comes from XO
% mismatch, so a true CFO of f Hz at Fc=2 GHz implies ppm = f/2e9 and the
% SAME fractional offset on the sample clock (SRO). Coupled points apply
% both: resample by (1+ppm) (TX clock fast for +f), then rotate by +f at the
% RX sample grid. CFO-only points rotate without resampling.
%
% Format: int16 interleaved I,Q @61.44 MSPS, complex RMS scaled to 2450
% (measured from two_jup/floatgap_n3/win_d1_berleg_o{0,80}.iq: 2453/2449).
%
% mapPerm: 1x4, pair-index (2*b1+b2, 0..3) -> constellation index into
% exp(1i*(pi/4+(0:3)*pi/2)). Calibrated against the DUT BIST (the netlist's
% ROM reference), because synth_f1536_waveform's own mapping is arbitrary
% (its float scorer resolves rotation; the RTL BIST does not).

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..','..','k5_240'));
addpath(fullfile(here,'..','..','evm'));
cfg = evm_config_1536k();
R   = f1536_ref_bits();
Fs  = cfg.Fs;            % 61.44e6
Fc  = 2e9;               % carrier (link TX 2.0 GHz)
TARGET_RMS = 2450;

pairs = reshape(R.payload,2,[]).';
pidx  = 2*pairs(:,1)+pairs(:,2);       % 0..3 per symbol

    function wf = build(nFrames, perm)
        paySym = cfg.IdealConstellation(perm(pidx+1)+1).';
        oneFrame = [cfg.PreambleSymbols(:); paySym];
        assert(numel(oneFrame)==cfg.FrameLenSym);
        sym = repmat(oneFrame,nFrames,1);
        up  = upsample(sym,cfg.Sps);
        rrc = rcosdesign(cfg.Beta,cfg.RrcSpan,cfg.Sps);
        wf  = conv(up,rrc,'same');
    end

    function writeiq(wf, fname)
        s = TARGET_RMS/sqrt(mean(abs(wf).^2));
        x = wf*s;
        iq = zeros(2*numel(x),1);
        iq(1:2:end) = real(x); iq(2:2:end) = imag(x);
        nclip = sum(abs(iq)>32767);
        iq = int16(max(min(round(iq),32767),-32768));
        fid = fopen(fname,'w'); fwrite(fid,iq,'int16'); fclose(fid);
        fprintf('WROTE %s nsamp=%d rms=%.1f clip=%d\n',fname,numel(x),TARGET_RMS,nclip);
    end

if strcmp(mode,'calib')
    P = perms([0 1 2 3]);          % 24 candidates
    wfbase = [];                   %#ok<NASGU>
    for k = 1:size(P,1)
        wf = build(4, P(k,:));
        writeiq(wf, fullfile(outDir,sprintf('calib_m%02d.iq',k)));
        fprintf('CALIBMAP m%02d perm=[%d %d %d %d]\n',k,P(k,:));
    end
    return
end

assert(strcmp(mode,'sweep') && nargin==3);
NF = 51;                                  % 51 source frames; emit 50 frames of samples
NOUT = 50*cfg.FrameLenSym*cfg.Sps;        % 2466600
wf0 = build(NF, mapPerm);

% points: {tag, cfo_Hz, coupled_sro}
pts = { 'p0000_cpl',      0, true
        'p+05k_cpl',   5000, true
        'p-05k_cpl',  -5000, true
        'p+15k_cpl',  15000, true
        'p-15k_cpl', -15000, true
        'p+25k_cpl',  25000, true
        'p-25k_cpl', -25000, true
        'p+15k_cfo',  15000, false
        'p-15k_cfo', -15000, false };

n = (0:NOUT-1).';
for k = 1:size(pts,1)
    f = pts{k,2}; coupled = pts{k,3};
    if coupled && f~=0
        ppm = f/Fc;                        % TX XO fractional offset
        ti = n*(1+ppm);                    % RX sample n samples TX index ti
        y = interp1((0:numel(wf0)-1).', wf0, ti, 'spline', 0);
    else
        y = wf0(1:NOUT);
    end
    y = y .* exp(1i*2*pi*f*n/Fs);
    writeiq(y, fullfile(outDir,sprintf('stim_%s.iq',pts{k,1})));
end
end
