function floatref()
% N3 float-reference leg: bs_front_end EVM floor on the healthy R3 captures,
% two alignments each (warm-up trap: score frames 6..end only).
here = fileparts(mfilename('fullpath'));
repo = fullfile(here,'..','..');
addpath(fullfile(repo,'evm'));
addpath(fullfile(repo,'tick_repro_r3','burst_study'));
cfg = evm_config_1536k();
SPF = cfg.FrameLenSym * cfg.Sps;   % 49332
caps = { 'evm_swap_A', fullfile(repo,'two_jup','r3cap','evm_swap_A','pair.iq'); ...
         'evm_swap_B', fullfile(repo,'two_jup','r3cap','evm_swap_B','pair.iq'); ...
         'cp1_verdict2', fullfile(repo,'two_jup','r3cap','cp1_verdict2','pair.iq') };
offs = [0 80];        % alignment offsets in frames
NFR  = 50;            % window length in frames
WARM = 5;             % frames to drop at window head
out = {};
for c = 1:size(caps,1)
  for a = 1:numel(offs)
    f = fopen(caps{c,2},'rb'); fseek(f, offs(a)*SPF*4, 'bof');
    d = fread(f, 2*NFR*SPF, 'int16'); fclose(f);
    iq = complex(d(1:2:end), d(2:2:end));
    r = bs_front_end(iq, cfg, struct());
    ev = r.frameEVM; ev = ev(WARM+1:end);
    fprintf('FLOAT %s off%d nF=%d cfo=%.0f medEVM=%.3f meanEVM=%.3f p90=%.3f\n', ...
      caps{c,1}, offs(a), r.nFrames, r.coarseCFO, median(ev), mean(ev), prctile(ev,90));
    out(end+1,:) = {caps{c,1}, offs(a), r.nFrames, median(ev), mean(ev)}; %#ok<AGROW>
  end
end
save(fullfile(here,'floatref_results.mat'),'out');
end
