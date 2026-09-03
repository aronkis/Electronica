function resolver_lookback_fix(sys, loop) %#ok<INUSD>
% resolver_lookback_fix -- fix the QPSK 4-fold Phase Ambiguity resolver for
% arbitrary (non-golden) payloads.
%
% ROOT CAUSE (proven in the free Verilator harness, rtl_sim/wrap_byte_trace.v):
%   The Phase Ambiguity Estimator correlates 8 received symbols against a fixed
%   reference = Barker preamble positions p4..p11. Its data/valid look-back into
%   the block is a fixed 40 sample-delays (Delay=32 + upstream Delay5=8). The
%   T8 rate fix moved this whole block from enb_1_4_0 to enb_1_2_0 (2x faster:
%   rail 15.36 MHz = 8 samples/symbol vs 4), so 40 samples now spans ~5 symbols
%   instead of ~10 -> the 8-symbol correlation window slid off preamble[4..11]
%   onto preamble[9..13] + PAYLOAD. That makes the phase estimate Z payload-
%   DEPENDENT, so the 4-fold ambiguity resolves to the wrong quadrant for every
%   non-golden payload (constant +90deg); golden alone happened to land on 0deg.
%
% FIX: add LB more sample-delays of look-back on ONLY the estimator's dataIn and
% validIn feeds (leaving the corrector/output paths untouched, since the
% estimate Z is a per-frame constant). LB=40 restores the ~10-symbol window so
% it re-lands on preamble[4..11] for ALL data -> data-independent, correct
% 4-fold resolve. Validated end-to-end (golden 04922282, qk 002ed28a,
% rand af0666a8; cap_in==tx_air, cap_deint==enc_coded, byte_rx correct).
%
% Idempotent. Applies to every 'Phase Ambiguity Estimation and Correction'
% subsystem in sys (both the DUT TxRxComposite copy and any sibling copy).

LB = 40;   % extra look-back sample-delays (= +5 symbols at 8 samples/symbol)

pae = find_system(sys,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','Phase Ambiguity Estimation and Correction');
assert(~isempty(pae), 'resolver_lookback_fix: no Phase Ambiguity Estimation and Correction subsystem found');

npatched = 0;
for i = 1:numel(pae)
    P   = pae{i};
    est = 'Phase Ambiguity Estimator';
    % idempotent guard
    if ~isempty(find_system(P,'SearchDepth',1,'LookUnderMasks','all', ...
            'FollowLinks','on','Name','EstDataLookback'))
        fprintf('resolver_lookback_fix: already patched -- %s\n', P);
        continue;
    end
    % confirm the expected feeders (Delay -> estimator/1 dataIn; Delay2 -> estimator/3 validIn)
    assert(~isempty(find_system(P,'SearchDepth',1,'BlockType','Delay','Name','Delay')), ...
        'resolver_lookback_fix: feeder Delay missing in %s', P);
    assert(~isempty(find_system(P,'SearchDepth',1,'BlockType','Delay','Name','Delay2')), ...
        'resolver_lookback_fix: feeder Delay2 missing in %s', P);

    % new look-back delays: clone the existing feeders so HDL-relevant settings
    % (reset, initial condition, rate) match, then set the length.
    add_block([P '/Delay'],  [P '/EstDataLookback']);
    set_param([P '/EstDataLookback'], 'DelayLength', num2str(LB));
    add_block([P '/Delay2'], [P '/EstVldLookback']);
    set_param([P '/EstVldLookback'], 'DelayLength', num2str(LB));

    % place them tidily below the estimator (cosmetic)
    pe = get_param([P '/' est],'Position');
    set_param([P '/EstDataLookback'],'Position', pe + [0 -140 -(pe(3)-pe(1))+40 -140+20]);
    set_param([P '/EstVldLookback'], 'Position', pe + [0 -100 -(pe(3)-pe(1))+40 -100+20]);

    % rewire dataIn: Delay/1 -> EstDataLookback -> estimator/1
    delete_line(P, 'Delay/1',  [est '/1']);
    add_line(P, 'Delay/1',            'EstDataLookback/1', 'autorouting','on');
    add_line(P, 'EstDataLookback/1',  [est '/1'],          'autorouting','on');

    % rewire validIn: Delay2/1 -> EstVldLookback -> estimator/3
    delete_line(P, 'Delay2/1', [est '/3']);
    add_line(P, 'Delay2/1',           'EstVldLookback/1',  'autorouting','on');
    add_line(P, 'EstVldLookback/1',   [est '/3'],          'autorouting','on');

    npatched = npatched + 1;
    fprintf('resolver_lookback_fix: patched %s (EstDataLookback/EstVldLookback len=%d)\n', P, LB);
end
fprintf('resolver_lookback_fix: DONE (%d subsystem(s) patched, LB=%d)\n', npatched, LB);
end
