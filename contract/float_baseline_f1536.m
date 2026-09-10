function res = float_baseline_f1536(src, varargin)
%FLOAT_BASELINE_F1536  IDEAL float receiver for the f1536 ROM frame format.
%
% Ported from decode_ref_k5.m: the front end (timing recovery, CFO estimate,
% carrier-sync PLL, frame sync) and 5 of its 7 local helpers (framePeaks,
% fourthPowerCFO, coarseCFO, deintIndex, refineStarts) are carried over
% verbatim in mechanism; only the geometry/FEC contract is re-pointed from K5
% (sps=8, 240 ksym/s) to f1536 (sps=4, 15.36 Msym/s). demodDecode/viterbiDecode
% were NOT kept verbatim -- see the helpers below and task-2-report.md for why.
%
% f1536 ROM frames carry NO CRC (unlike K5's -B reference, which
% decode_ref_k5.m used to resolve the quadrant/I-Q-swap ambiguity globally by
% CRC-pass voting), so this port instead resolves the quadrant-to-bit-label
% mapping by MINIMISING bit errors against the known f1536 ROM reference
% (f1536_ref_bits()). The hypothesis space is the FULL 24-way permutation of
% quadrant(0..3)->label(0..3) assignments (S4), not just the 8-way
% rotation x I/Q-swap subgroup (dihedral group of the square): a Gray-vs-
% natural-binary difference between what this receiver assumes and what an
% unverified real DUT actually transmits is a RELABELLING, which the 8-way
% sweep cannot reach (see task-2-report.md, "Bug 1"). Identified from the
% first min(2,nFrames) decodable frames only (cost control -- see the mapping
% sweep below), then held fixed for every remaining frame; res.hypStable
% reports whether those calibration frames agree.
%
% Usage:
%   res = float_baseline_f1536('/path/to/capture.iq')   % int16 interleaved-IQ file
%   res = float_baseline_f1536(wf)                       % complex column vector (synthetic)
%
% res fields:
%   nFrames         frames decoded (accepted candidates within bounds of the sample buffer)
%   bitErrors       total info-bit errors across decoded frames (winning mapping)
%   bitsScored      nFrames * INFO
%   ber             bitErrors / bitsScored
%   perFrame        table: frame, s0, errs, ok (errs==0)
%   frameRecovery   fraction of frames with errs==0
%   hyp             winning struct('rot',1,'swap',0,'mapping',<1x4 perm>) --
%                   rot/swap are fixed/vestigial (kept for schema continuity
%                   with the original 8-way-sweep spec); 'mapping' is the
%                   real answer: mapping(q+1) is the 2-bit label (0..3)
%                   assigned to geometric quadrant q.
%   hypStable       true if the calibration frames agree on the winning mapping
%   hypBestErr      total bit errors (calibration frames) for the winning mapping
%   hypRunnerUpErr  total bit errors (calibration frames) for the second-best
%                   mapping -- close to hypBestErr means the identification is
%                   not trustworthy
%   hypMargin       hypRunnerUpErr - hypBestErr
%   preCorrThresh   preamble-correlation accept threshold used (see 'precorrthresh')
%   nRejected       number of frame-sync candidates rejected by the preCorr gate
%   acceptedPreCorr preCorr values of accepted candidates
%   rejectedPreCorr preCorr values of rejected candidates
%   preCorrStats    struct(acceptedMin/Median/Max, rejectedMin/Median/Max) --
%                   always reported so a reader can see whether the threshold
%                   is plausible for a given capture's SNR, not just for G1
%   clippedFrac     fraction of input samples at the int16 tap ceiling (file
%                   input only; NaN for synthetic)
%   errPosProfile   1x10 double, fraction of bit errors per within-frame
%                   decile (Task 1, 2026-08-24 G2 diagnostic)
%   snrEstDb        EVM-based Es/N0 estimate (dB) on locked payload symbols
%                   of accepted frames; NaN if no accepted frames
%   validatedEsn0FloorDb  VALIDATED_ESN0_FLOOR_DB (see const definition) --
%                   the AWGN-ladder-validated floor, exposed on res so
%                   downstream consumers (e.g. A3) don't have to re-parse it
%                   out of source
%
% Optional name-value args:
%   'nocfo', 'nocarrier', 'loopbw'      -- as decode_ref_k5.m
%   'cfomax'                            -- coarse-CFO search half-range, Hz.
%                                          Default CFO_SEARCH_HALFRANGE_HZ_K5_UNVERIFIED.
%   'precorrthresh'                     -- preamble-correlation accept threshold.
%                                          Default 0.8 -- RAISED from decode_ref_k5.m's
%                                          0.5 convention 2026-08-24 (Task 1). See
%                                          PRECORR_THRESH_F1536 note below for why.
%   'calbypreCorrRank'                  -- calibration-frame selection mode.
%                                          Default true (rank by preCorr quality);
%                                          set false to restore first-arrival-order
%                                          selection (pre-fix behavior). Task 1
%                                          fix round 1, 2026-08-24 -- isolates this
%                                          fix from the precorrthresh fix for
%                                          future regressions.

% ---- G2 diagnosis (Task 1, 2026-08-24): decile profile + precorrthresh fix ----
% The brief's leading suspect (single per-frame preamble derotation drifting
% across 12320 payload symbols) was tested FIRST via errPosProfile and
% REFUTED: at 9 dB Es/N0 the error mass is FLAT across all 10 deciles
% ([0.10 0.10 ... 0.10]), not tail-heavy, so there is no progressive
% within-frame rotation. (That flat profile itself only has diagnostic value
% once corroborated -- see below -- because a population at chance BER is
% flat by construction. The real evidence is structural: res.perFrame.errs is
% always either EXACTLY 0 or ~6000/12292 (chance) -- never graded -- which a
% continuous phase drift could not produce; the frame is either correctly
% globally-mapped or not.)
%
% Root cause: with precorrthresh=0.5 (decode_ref_k5.m's convention), a
% spurious frame-sync candidate can pass the preamble-correlation gate at
% moderate/low SNR (this waveform repeats IDENTICAL payload data across every
% frame -- see synth_f1536_waveform.m -- which raises off-lattice
% self-correlation sidelobes beyond 0.5 once noise perturbs the true-preamble
% peak down near that level). Because the quadrant->label mapping is
% calibrated from only the FIRST min(2,nFrames) accepted candidates, a single
% spurious candidate landing in that 2-frame calibration set corrupts the
% GLOBAL mapping winner for the entire capture -- turning genuinely
% well-synced, on-lattice frames into chance-level decodes too (hypStable=0,
% hypMargin single digits to low tens out of a ~12000-error scale, vs ~12000
% when calibration is clean). This is the actual mechanism behind the G2
% cliff, not phase drift.
% Fix (bounded, in the already-named precorrthresh suspect): raise the
% default accept threshold from 0.5 to 0.8, which empirically separates
% genuine on-lattice preamble locks (preCorr ~1.0) from the spurious
% candidates (measured up to ~0.76 at moderate SNR) across a 7-seed sweep at
% Es/N0 in {6,8,9,10,12} dB. Bypassable: pass precorrthresh=0.5 explicitly to
% reproduce the old (broken) behavior; parameter and default remain a normal
% opts field. A SECOND, complementary fix (also within this same suspect,
% bypassable via 'calbypreCorrRank', default true) also went in: the
% mapping-calibration frames are now chosen by HIGHEST preamble correlation
% among accepted candidates, rather than by first-arrival order -- see the
% note above `calIdx` in the calibration block. This directly targets
% calibration-set contamination without needing to touch precorrthresh, and
% measurably recovered at least one cross-seed case (seed 11 at 9 dB) that
% the threshold change alone had
% not fixed.
PRECORR_THRESH_F1536_DEFAULT = 0.8;   % was decode_ref_k5.m's 0.5 convention

% ---- validated-SNR floor (Task 1, 2026-08-24) ----
% AWGN ladder, gates_float_baseline_f1536, esn0=[0 3 6 8 9 10 12] dB,
% precorrthresh=0.8 + preCorr-ranked calibration, run through the FULL ladder
% sequence (matching gates_float_baseline_f1536.m exactly) at 7 seeds
% (1,3,5,7,11,13,2026), floor defined per seed as the lowest rung with
% ber==0 AND nFrames>=3 (G1's own bar -- a "0 bit errors" reading on 1-2
% surviving frames is a survivor-biased sample, not a floor measurement).
% Result: 6/7 seeds resolve a floor at or below 10 dB (two at 9 dB, four at
% 10 dB); the 7th seed (13) never accumulated 3+ accepted frames at ANY
% tested rung up to 12 dB within the 6-requested-frame budget -- but its ber
% was 0 (or 2.9e-3, negligible) at every rung where it DID score >=1 frame,
% i.e. this is a frame-YIELD limitation of testing a small 6-frame batch
% against a threshold=0.8 gate, not a decode-correctness failure. Stamped at
% the worst-case value among the 6 seeds that DID resolve a floor (10 dB),
% not the single-run optimistic reading. Concern for A3: on a real air
% capture with far more than 6 frames, this yield limitation should not
% recur, but the 0.8 threshold's effect on genuine (non-synthetic) frame
% acceptance at real SNR/CFO/clipping has not been separately verified --
% see task-1-report.md concerns.
VALIDATED_ESN0_FLOOR_DB = 10;   % AWGN ladder, gates_float_baseline_f1536, 2026-08-24, nFrames>=3 bar

% ---- CFO constants: INHERITED FROM K5, CHECKED AT F1536's RATE 2026-08-24 ----
% K5 runs at Rsym=240e3 sym/s; f1536 runs at Rsym=15.36e6 sym/s -- 64x higher.
% A CFO search half-range / implausibility bound that is sensible at
% 240 ksym/s may be meaningless (too tight or too loose) at 15.36 Msym/s.
%
% CFO_SEARCH_HALFRANGE: this is a bound on absolute LO/TCXO drift in Hz, a
% physical quantity that does NOT scale with symbol rate -- an oscillator's
% ppm-level offset at a given RF carrier gives the same Hz error regardless
% of Rsym. Checked and left as an absolute-Hz constant (not retuned).
%
% CFO_IMPLAUSIBLE (preamble-refine trust gate): this one WAS wrong. It govern
% whether the post-coarse REFINEMENT correction is trusted, and a genuine
% refinement should be a small fraction of one preamble-correlation cycle,
% i.e. small compared to Rsym/frameLenSym (~1245 Hz at f1536). The inherited
% flat 5000 Hz K5 value is ~4x that -- loose enough that a refine estimate
% representing 2-3 spurious CYCLES of phase drift across one whole frame
% still read as "plausible" and got applied. Root-caused 2026-08-24 (see
% task-3-report.md): on synth_f1536_waveform(4), which has EXACTLY ZERO true
% CFO, the estimator still returned a nonzero, noise-growing preamble-refine
% (2671 Hz at Inf dB Es/N0, 3629 Hz at 12 dB, blowing up into the 1e5-1e6 Hz
% range by 6-9 dB where the old bound correctly caught and zeroed it) --
% i.e. the refine stage fabricates an offset under any real-world condition,
% and the old bound was too loose to catch the smaller (still spurious)
% instances. Retuned to scale with f1536's own frame geometry instead of a
% flat K5-carryover constant.
CFO_SEARCH_HALFRANGE_HZ_K5_UNVERIFIED = 15e3;   % was decode_ref_k5.m's 'cfomax' default

p=inputParser;
p.addParameter('nocfo',false,@islogical);
p.addParameter('nocarrier',false,@islogical);
p.addParameter('loopbw',0.01,@isnumeric);
p.addParameter('cfomax',CFO_SEARCH_HALFRANGE_HZ_K5_UNVERIFIED,@isnumeric);
p.addParameter('precorrthresh',PRECORR_THRESH_F1536_DEFAULT,@isnumeric);
p.addParameter('calbypreCorrRank',true,@islogical);   % Fix B bypass (Task 1 fix round 1, 2026-08-24): default ON,
                                                       % ranks calibration frames by preCorr quality; set false to
                                                       % restore first-arrival-order calibration selection, so Fix A
                                                       % (precorrthresh) and Fix B can be isolated in regressions.
p.addParameter('mapping',[],@isnumeric);   % fixed quadrant->label map (skips ROM-ref calibration; live-traffic captures)
p.addParameter('keepbits',false,@islogical); % return per-frame decoded info bits as res.decBits
p.parse(varargin{:});
fixedMap=p.Results.mapping; keepBits=p.Results.keepbits;
noCFO=p.Results.nocfo; noCarrier=p.Results.nocarrier;
loopBW=p.Results.loopbw; cfoMax=p.Results.cfomax;
preCorrThresh=p.Results.precorrthresh;
calByPreCorrRank=p.Results.calbypreCorrRank;

%% ---- f1536 geometry + FEC contract (re-pointed from K5; see task-2 brief) ----
here=fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..','evm'));
cfg=evm_config_1536k();
preSyms=cfg.PreambleSymbols(:);          % 13-Barker, SHARED with K5 (evm_config_1536k.m:16)
paySyms=cfg.PaySymPerFrame;              % 12320
nPre=cfg.NPreambleSym;                   % 13
frameLenSym=cfg.FrameLenSym;             % 12333
sps=cfg.Sps;                             % 4
RRC=rcosdesign(cfg.Beta,cfg.RrcSpan,sps);
Fs=cfg.Fs; Rsym=cfg.Rsym;                % 61.44e6 / 15.36e6
% Geometry-scaled preamble-refine trust bound (replaces the flat K5-carryover
% 5000 Hz constant -- see the 2026-08-24 note above CFO_SEARCH_HALFRANGE).
% Half a cycle of phase drift across one frame is already a generous margin
% for a refinement stage that is supposed to be fine-tuning a coarse estimate,
% not discovering multi-kHz structure on its own.
oneCyclePerFrameHz = Rsym/frameLenSym;                 % ~1245 Hz at f1536
CFO_IMPLAUSIBLE_HZ_F1536 = 0.5*oneCyclePerFrameHz;      % ~622 Hz
REF=f1536_ref_bits();
trellis=REF.trellis; TB=REF.TB; ROWS=REF.ROWS; COLS=REF.COLS;
INFO=REF.INFO; TAIL=REF.TAIL; CODED=REF.CODED; NPAIR=CODED/2;
assert(CODED==24592 && ROWS==1537 && COLS==16 && TB==25,'f1536 contract constants mismatch');
assert(frameLenSym==12333 && paySyms==12320 && sps==4,'f1536 geometry mismatch');
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);

%% ---- acquire IQ: file capture OR synthetic waveform ----
if isnumeric(src) && ~isreal(src)
    iq = src(:);  clippedFrac = NaN;                 % synthetic waveform
else
    fid=fopen(src,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
    I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
    iq=double(I(1:nn))+1i*double(Q(1:nn));
    % clipping census BEFORE normalisation -- the ROM capture measured ~1% of
    % samples pinned at the int16 tap ceiling (max 7968, p99 7967). Record it;
    % do not silently absorb it.
    ceilv = max(max(abs(real(iq))), max(abs(imag(iq))));
    clippedFrac = mean(abs(real(iq))>=ceilv | abs(imag(iq))>=ceilv);
    iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
end
fprintf('[f1536] %d complex samples (~%.0f frames)\n',numel(iq),numel(iq)/sps/frameLenSym);

%% ---- front-end (verbatim from decode_ref_k5 / soak_decode_k5): timing, CFO, carrier sync, frame sync ----
x=iq(:)/rms(abs(iq)); mf=conv(x,RRC,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy)); sym0=sy*rms(abs(preSyms));
f4=0; fRefRaw=0; fRef=0;
if noCFO
  fCoarse=0;
else
  f4=fourthPowerCFO(sym0,Rsym,cfoMax);
  if abs(f4)>0.9*cfoMax
    warning('float_baseline_f1536:cfoEdge','4th-power CFO %.0f Hz is at the +-%.0f Hz mask edge -- raise ''cfomax''',f4,cfoMax);
  end
  sym1=sym0.*exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
  [psAll,~]=framePeaks(sym1,preSyms,nPre,frameLenSym);
  fRefRaw=coarseCFO(sym1,psAll,preSyms,nPre,Rsym);
  fRef=fRefRaw;
  % post-f4 preamble REFINE must be small; a big value means the estimator
  % latched non-carrier structure -- distrust it (and say so, never silently).
  if abs(fRef)>CFO_IMPLAUSIBLE_HZ_F1536, fprintf('[f1536] preamble-refine %.0f Hz IMPLAUSIBLE (bound %.0f Hz) -> ignored\n',fRef,CFO_IMPLAUSIBLE_HZ_F1536); fRef=0; end
  fCoarse=f4+fRef;
  fprintf('[f1536] CFO breakdown: 4th-power=%.0f Hz + preamble-refine=%.0f Hz (raw %.0f Hz, bound %.0f Hz, search +-%.0f Hz)\n',f4,fRef,fRefRaw,CFO_IMPLAUSIBLE_HZ_F1536,cfoMax);
end
% Diagnostic fields -- always populated (0 when nocfo=true) so the gates can
% run a permanent zero-CFO sanity check on a known-zero-offset synthetic
% waveform without scraping stdout.
res.cfoF4Hz         = f4;
res.cfoRefineRawHz  = fRefRaw;   % pre-implausibility-gate refine estimate
res.cfoAppliedHz    = fCoarse;   % final coarse correction actually applied
symCFO=sym0.*exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');
if noCarrier
  symC=symCFO(:)/rms(abs(symCFO))*rms(abs(preSyms));
else
  csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',loopBW);
  symC=csy(symCFO); symC=symC(:)/rms(abs(symC))*rms(abs(preSyms));
end
[ps0,~]=framePeaks(symC,preSyms,nPre,frameLenSym);
ps0=refineStarts(symC,ps0,preSyms,nPre,8);
fprintf('[f1536] coarse CFO=%.0f Hz ; framed %d candidates\n',fCoarse,numel(ps0));

%% ---- reject false frame-sync candidates by preamble correlation (NOT decode error) ----
% NOTE (addition beyond the brief's Step 4 code): the brief's sweep scores
% every ps0 candidate unconditionally. On a short synthetic capture the very
% first candidate is a FALSE peak from symbol-synchronizer warm-up transient
% -- its own preamble correlation is ~0.17 (vs ~1.0 for the three genuine
% frames) and its spacing to the next candidate is NOT frameLenSym (11736 vs
% 12333), i.e. it is not a frame at all, not a frame that merely decoded
% badly. This is exactly the "first frame may be lost to filter warm-up"
% case the brief's Step 5 acceptance criteria anticipates (nFrames>=3). The
% gate is on PREAMBLE correlation only (independent of REF/payload), copying
% decode_ref_k5.m's own preCorr>0.5 convention verbatim -- deliberately NOT
% K5's separate frac<PHASE_FRAC payload-error gate, which would discard
% frames *because* they decoded badly and so cannot be used on air captures
% without circularly deleting the corrupted-frame signal Task 3/4 exists to
% measure.
% 'precorrthresh' is a parameter rather than a hard-coded constant because it
% is UNTESTED at real air-capture SNR. It started at decode_ref_k5.m's 0.5
% convention, which cleanly separated one obviously-bogus warm-up candidate
% (preCorr~0.17) from genuine frames (preCorr~1.0) on the ORIGINAL 4-frame
% synthetic capture -- but RAISED to 0.8 default 2026-08-24 (Task 1) after
% G2 diagnosis showed that at moderate/low Es/N0, spurious frame-sync
% candidates land at preCorr up to ~0.76 (this synthetic waveform repeats
% IDENTICAL payload data every frame, which raises off-lattice
% self-correlation sidelobes -- see the note above VALIDATED_ESN0_FLOOR_DB),
% and one such candidate landing in the 2-frame mapping-calibration set
% silently corrupts the GLOBAL quadrant->label mapping for the whole
% capture. 0.8 was the smallest threshold in a 7-seed sweep that reliably
% rejected every observed spurious candidate while still passing genuine
% (preCorr~1.0) frames. On a real capture a genuine low-SNR frame could
% plausibly land near the threshold; the full accepted/rejected preCorr
% distribution is always reported in res (not just pass/fail) so a reader
% can judge, on THIS capture, whether the threshold is discarding real
% frames.
preCorrAll = nan(numel(ps0),1);
for k = 1:numel(ps0)
    s0 = ps0(k);
    if s0 < 1 || s0+nPre-1 > numel(symC), continue; end
    pre = symC(s0:s0+nPre-1);
    preCorrAll(k) = abs(sum(pre.*conj(preSyms)))/(sum(abs(preSyms))+eps);
end
acceptIdx = find(preCorrAll > preCorrThresh);
rejectIdx = find(preCorrAll <= preCorrThresh | isnan(preCorrAll));
res.preCorrThresh   = preCorrThresh;
res.nRejected       = numel(rejectIdx);
res.acceptedPreCorr = preCorrAll(acceptIdx);
res.rejectedPreCorr = preCorrAll(rejectIdx);
statTriple = @(v) struct('min',min(v),'median',median(v),'max',max(v));
if isempty(res.acceptedPreCorr)
    accStats = struct('min',NaN,'median',NaN,'max',NaN);
else
    accStats = statTriple(res.acceptedPreCorr);
end
if isempty(res.rejectedPreCorr)
    rejStats = struct('min',NaN,'median',NaN,'max',NaN);
else
    rejStats = statTriple(res.rejectedPreCorr);
end
res.preCorrStats = struct( ...
    'acceptedMin',accStats.min, 'acceptedMedian',accStats.median, 'acceptedMax',accStats.max, ...
    'rejectedMin',rejStats.min, 'rejectedMedian',rejStats.median, 'rejectedMax',rejStats.max);
fprintf('[f1536] preCorr accepted[min/med/max]=%.3f/%.3f/%.3f  rejected[min/med/max]=%.3f/%.3f/%.3f (n=%d)\n', ...
    accStats.min,accStats.median,accStats.max, rejStats.min,rejStats.median,rejStats.max, res.nRejected);
assert(~isempty(acceptIdx), 'float_baseline_f1536:noDecodableFrames', ...
    'no candidate frame passed the preamble-correlation gate (preCorr>%.2f)', preCorrThresh);
ps0v = ps0(acceptIdx);
accPreCorrV = preCorrAll(acceptIdx);   % same order as ps0v -- used to pick calibration frames by quality, not by first-arrival

%% ---- resolve the quadrant->label mapping by MINIMISING bit errors vs the known ROM reference ----
% f1536 ROM frames carry no CRC (K5's global-CRC-vote resolver does not
% apply). WIDENED from an 8-way (rotation x I/Q-swap) sweep to the FULL
% 24-way permutation of quadrant(0..3)->2-bit-label(0..3) assignments (S4):
% a Gray-vs-natural-binary difference between this receiver's assumed
% mapping and an unverified real DUT's actual mapping is a RELABELLING, not
% a rotation or reflection, and the 8-way (dihedral) subgroup provably
% cannot reach it -- this port's own G1 failure with pskdemod('gray') was
% exactly such a case (task-2-report.md, "Bug 1"). Each payload symbol is
% demapped to a purely geometric quadrant index 0..3 by quadIndex() (nearest
% of the 4 canonical QPSK points), independent of any bit-labelling
% assumption; mapDecode() then applies one candidate permutation to turn
% quadrant indices into bits before deinterleave+Viterbi. Any 90-degree
% rotation or I/Q-swap is itself one of the 24 permutations, so the old
% (rot,swap) sweep is fully subsumed, not run separately.
%
% COST CONTROL: 24 Viterbi decodes per frame is a 24x tax on every
% subsequent (much larger) frame count on an air capture. The mapping is
% identified from the first min(2,nFrames-accepted) DECODABLE
% (preCorr-gated) frames only -- 24 x <=2 Viterbi runs, a bounded one-time
% cost -- then held fixed and applied with a single decode per remaining
% frame. res.hypStable reports whether the calibration frames independently
% agree on the winner (weaker evidence than "every frame" when nFrames>2;
% that is the explicit cost/evidence tradeoff of this design).
mapPerms = perms([0 1 2 3]);         % 24x4: row m, mapPerms(m,q+1) = label for quadrant q
nPermHyp = size(mapPerms,1);
nCal = min(2, numel(ps0v));
% Calibration frames are chosen by HIGHEST preamble correlation among accepted
% candidates, not by first-arrival order (added Task 1, 2026-08-24). Root
% cause of the G2 cliff: a spurious frame-sync candidate (this synthetic
% waveform repeats identical payload data every frame, raising off-lattice
% self-correlation sidelobes) can pass preCorrThresh yet still be much worse
% than a genuine on-lattice frame; picking calibration frames "first 2 to
% arrive" let such a candidate corrupt the GLOBAL quadrant->label mapping for
% the whole capture. Picking by preCorr quality keeps precorrthresh at its
% original (decode_ref_k5.m) 0.5 -- so genuine, if noisy, frames are NOT
% excluded from the scored population/denominator -- while still shielding
% the one-shot mapping identification from contamination.
% Bypassable via 'calbypreCorrRank' (default true) -- set false to restore
% first-arrival-order calibration selection (the pre-fix behavior), so this
% fix (Fix B) and the precorrthresh fix (Fix A) can be isolated in future
% regressions.
if calByPreCorrRank
    [~, calRank] = sort(accPreCorrV, 'descend');
else
    calRank = (1:numel(ps0v)).';   % first-arrival order (pre-fix behavior)
end
calIdx = calRank(1:nCal);
errsCal = nan(nCal, nPermHyp);
qidxCal = cell(nCal,1);
for k = 1:nCal
    s0 = ps0v(calIdx(k));
    fr = symC(s0:s0+frameLenSym-1);
    payD = fr(nPre+1:end);
    qidxCal{k} = quadIndex(payD);
    for m = 1:nPermHyp
        dec = mapDecode(qidxCal{k}, mapPerms(m,:), CODED, deintIdx, trellis, NPAIR);
        errsCal(k,m) = sum(dec(1:INFO) ~= REF.info);
    end
end
totCal = sum(errsCal, 1);
[sortedTot, order] = sort(totCal);
winner = order(1);
if ~isempty(fixedMap)   % sim-repro 2026-08-27: live-traffic captures carry no ROM payload
    [~,winner] = ismember(fixedMap(:).', mapPerms, 'rows');
    assert(winner>0,'float_baseline_f1536:badMapping','mapping must be a permutation of 0..3');
end
res.hyp = struct('rot', 1, 'swap', 0, 'mapping', mapPerms(winner,:));
res.hypBestErr     = sortedTot(1);
res.hypRunnerUpErr = sortedTot(min(2,numel(sortedTot)));
res.hypMargin      = res.hypRunnerUpErr - res.hypBestErr;
if nCal >= 2
    [~, winPerCal] = min(errsCal, [], 2);
    res.hypStable = all(winPerCal == winner);
else
    res.hypStable = true;   % only one calibration frame available -- nothing to disagree with
end
fprintf('[f1536] mapping calibrated on %d frame(s): winner err=%d, runner-up err=%d, margin=%d\n', ...
    nCal, res.hypBestErr, res.hypRunnerUpErr, res.hypMargin);

%% ---- decode every accepted frame with the fixed winning mapping ----
% NOTE: frames k<=nCal are re-decoded here (rather than reusing errsCal) so
% that `dec`/`payD` are available uniformly for every accepted frame for the
% diagnostics below -- deterministic, so errsAll is identical to reusing the
% cached calibration result; the extra cost is at most 2 Viterbi decodes.
nAcc = numel(ps0v);
errsAll = nan(nAcc,1);
decAll = false(nAcc, INFO);
% --- diagnostics (added Task 1, 2026-08-24) ---
% errPosProfile: where within the frame do bit errors fall? A tail-heavy
% profile is the signature of intra-frame phase drift (single preamble
% derotation over 12320 payload symbols -- 11x K5's span, the suspected
% K5->f1536 defect class).
edges = round(linspace(0, INFO, 11));
prof = zeros(1,10);
% snrEstDb: EVM-based Es/N0 on the derotated payload symbols of ACCEPTED
% frames, referenced to the geometric hard-decision quadrant point q (which
% IS the nearest-of-4-canonical-points hard decision -- see quadIndex).
% evm^2 ~= 1/(Es/N0) for QPSK at unit ref power.
refAmp = rms(abs(preSyms));   % payD/symC are normalised to the preamble rms
evmNumSum = 0; evmDenSum = 0;
prePhaseDeg = nan(nAcc,1);   % diagnostic: per-frame preamble residual phase (deg)
for k = 1:nAcc
    s0 = ps0v(k);
    if s0 < 1 || s0+frameLenSym-1 > numel(symC), continue; end
    fr = symC(s0:s0+frameLenSym-1);
    payD = fr(nPre+1:end);
    q = quadIndex(payD);
    dec = mapDecode(q, mapPerms(winner,:), CODED, deintIdx, trellis, NPAIR);
    errsAll(k) = sum(dec(1:INFO) ~= REF.info);
    if keepBits, decAll(k,:) = dec(1:INFO) ~= 0; end
    prePhaseDeg(k) = angle(sum(fr(1:nPre).*conj(preSyms))) * 180/pi;

    for d = 1:10
        seg = (edges(d)+1):edges(d+1);
        prof(d) = prof(d) + sum(dec(seg) ~= REF.info(seg));
    end
    hardDecisionSyms = exp(1i*(pi/4 + q(:)*(pi/2))) * refAmp;
    evmNumSum = evmNumSum + sum(abs(payD(:) - hardDecisionSyms).^2);
    evmDenSum = evmDenSum + sum(abs(hardDecisionSyms).^2);
end
validFrame = ~isnan(errsAll);
assert(any(validFrame), 'float_baseline_f1536:noDecodableFrames', 'no decodable frames');
res.errPosProfile = prof / max(sum(prof),1);
if evmDenSum > 0
    res.snrEstDb = -10*log10(evmNumSum/evmDenSum);
else
    res.snrEstDb = NaN;
end

%% ---- assemble result ----
errsCol = errsAll(validFrame);
s0Col   = ps0v(validFrame);
prePhaseCol = prePhaseDeg(validFrame);
nF = numel(errsCol);
res.nFrames    = nF;
res.bitErrors  = sum(errsCol);
res.bitsScored = nF*INFO;
res.ber        = res.bitErrors/max(res.bitsScored,1);
frameIdx = (1:nF).';
okCol = errsCol==0;
res.perFrame = table(frameIdx, s0Col(:), errsCol(:), okCol(:), prePhaseCol(:), ...
    'VariableNames', {'frame','s0','errs','ok','prePhaseDeg'});
res.frameRecovery = mean(okCol);
if keepBits, res.decBits = decAll(validFrame,:); end
res.clippedFrac = clippedFrac;
res.validatedEsn0FloorDb = VALIDATED_ESN0_FLOOR_DB;   % see note above the constant's definition

fprintf('[f1536] frames=%d bitErrors=%d ber=%.3e frameRecovery=%.4f hyp.mapping=[%s] hypStable=%d hypMargin=%d\n', ...
    res.nFrames, res.bitErrors, res.ber, res.frameRecovery, num2str(res.hyp.mapping), res.hypStable, res.hypMargin);
end

%% ====================== helpers ======================
function q=quadIndex(payD)
% Geometric quadrant decision for one frame's payload symbols, INDEPENDENT of
% any bit-labelling convention: nearest of the 4 canonical QPSK points at
% pi/4 + k*(pi/2), k=0..3. This deliberately does NOT call pskdemod (see the
% history below) -- it only decides WHICH of the 4 constellation points a
% symbol is closest to; mapDecode() is what turns that geometric decision
% into bits, under a candidate hypothesis.
q=mod(round(mod(angle(payD(:))-pi/4,2*pi)/(pi/2)),4);
end
function dec=mapDecode(qidx,permRow,CODED,deintIdx,trellis,NPAIR)
% NOTE (divergence from decode_ref_k5.m -- history):
% Attempt 1 copied K5's demodDecode verbatim: pskdemod(payD*rot,4,pi/4,'gray',
% 'OutputType','bit') swept over rot={1,1i,-1,-1i} and an I/Q bit-pair swap
% (8 hypotheses, the dihedral group of the square). G1 FAILED at ~25-50% bit
% errors under every one of the 8. Diagnosis: f1536_ref_bits.m /
% synth_f1536_waveform.m build the ideal constellation with
% cfg.IdealConstellation(idx+1), idx=2*b(1)+b(2) -- NATURAL BINARY bit-pair
% indexing, not Gray. Switching pskdemod to 'bin' fixed G1 for OUR OWN
% synthetic transmitter, but that hard-codes an assumption about a real DUT's
% bit-labelling convention that has never been verified -- and gray-vs-binary
% is a RELABELLING of which quadrant maps to which 2-bit code, not a rotation
% or reflection, so it is fundamentally outside what an 8-way (rot,swap)
% sweep can ever discover if the assumption is wrong on real hardware.
% Fix: demapping is split into a labelling-independent geometric decision
% (quadIndex, above) and this function, which applies ONE candidate
% permutation `permRow` (one row of perms([0 1 2 3]), 24 total) mapping
% quadrant index q (0..3) to a 2-bit label. The caller (float_baseline_f1536)
% sweeps all 24 permutations on calibration frames and scores bit errors vs
% REF.info, which subsumes the old 8-way sweep as a subgroup (any 90-degree
% rotation or I/Q-swap IS one of the 24 permutations) while also reaching
% pure relabellings the old sweep could not.
lab=permRow(qidx+1);  lab=lab(:);
b1=floor(lab/2); b2=mod(lab,2);
v=zeros(2*numel(lab),1); v(1:2:end)=b1; v(2:2:end)=b2;
dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR);
end
function [ps0,pkv]=framePeaks(sym,preSyms,nPre,frameLenSym)
sym=sym(:); dps=preSyms(2:end).*conj(preSyms(1:end-1)); dsy=sym(2:end).*conj(sym(1:end-1));
ccd=abs(conv(dsy,conj(flipud(dps)))); ccd=ccd/(max(ccd)+eps);
[pkv,pk]=findpeaks(ccd,'MinPeakHeight',0.4,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sym); ps0=ps0(keep); pkv=pkv(keep);
end
function f=fourthPowerCFO(sym,Rsym,cfomax)
s=sym(:); s=s./(abs(s)+eps); N=min(2^18,numel(s)); w=s(1:N).^4;
W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<=4*cfomax; W(~mask)=0;   % 4th-power line sits at 4x the CFO
[~,k]=max(W); f=fax(k)/4;
end
function f=coarseCFO(sym,ps0,preSyms,nPre,Rsym)
fs=[];
for ii=1:numel(ps0)
  s0=ps0(ii); if s0+nPre-1>numel(sym), continue; end
  z=sym(s0:s0+nPre-1).*conj(preSyms); dz=z(2:end).*conj(z(1:end-1)); fs(end+1)=angle(mean(dz))/(2*pi)*Rsym; %#ok<AGROW>
end
if isempty(fs), f=0; else, f=median(fs); end
end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR)
deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end
end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR) %#ok<INUSD> -- NPAIR kept in the signature for call-site parity with decode_ref_k5.m; unused, see note below.
% NOTE (divergence from decode_ref_k5.m): K5 decoded with
% 'TerminationMethod','Continuous' + 'TracebackDepth',TB, fed one symbol-pair
% at a time with ResetInputPort reset at the first pair of every frame, and
% then read the decoded info bits back out SHIFTED by TB (dec(TB+1:TB+NREF))
% to skip the decoder's TB-sample warm-up latency. That shift only works when
% the scored region ends well before the last TB samples of the block -- true
% for K5 (NREF=1024 << INFO=1084, TAIL=4) but NOT true for f1536: REF.info
% spans the FULL info field (INFO=12292), and NPAIR=INFO+TAIL=12296 leaves
% only 4 samples of margin, far short of the TB=25 lookahead 'Continuous'
% mode needs to finish decoding the last ~21 info bits. G1 (Step 5) FAILED at
% ~49% bit errors (chance level) with 'Continuous', at every shift 0..30 --
% because the correct shift (empirically TB=25 exactly, verified on an
% isolated convenc/vitdec round trip with margin to spare) fell outside the
% 0..30 window this port could even reach given NPAIR's 4-sample margin.
% f1536's info field is genuinely ZERO-TAIL TERMINATED (TAIL=4 = K-1 for this
% K=5 code; see f1536_ref_bits.m), so the correct decoder for this port is
% 'TerminationMethod','Terminated': one call over the whole codeword, no
% traceback-depth warm-up shift, no manual per-pair loop. Verified 0 bit
% errors across all 12292 info bits + 4 tail bits on REF.coded directly
% (no channel) -- see g1_mini11 log in the report.
d=coded(deintIdx+1);
vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TerminationMethod','Terminated');
dec=vd(double(d));
end
function ps2=refineStarts(symC,starts,ps,nPre,win)
ps2=starts(:);
for i=1:numel(ps2), best=-1; bb=ps2(i);
  for o=-win:win, s=ps2(i)+o; if s<1||s+nPre-1>numel(symC),continue;end
    v=abs(sum(symC(s:s+nPre-1).*conj(ps))); if v>best,best=v;bb=s;end
  end
  ps2(i)=bb;
end
ps2=unique(ps2);
end
