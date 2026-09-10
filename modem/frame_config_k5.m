function cfg = frame_config_k5()
% frame_config_k5 -- SINGLE SOURCE OF TRUTH for the modem PHY
% frame geometry and samples-per-symbol. Selected by environment variables:
%   QPSK_FRAME (default 'k5')  -- frame geometry preset
%   QPSK_SPS   (default 8)     -- samples per symbol
%
% With both env vars unset the returned struct reproduces the historical k5
% literals EXACTLY -- this is gate G0 (zero behavior change). QPSK_FRAME=f1536
% selects the large-frame (1536-byte host) geometry (Task A2). QPSK_SPS=4 is a
% supported rate rung (Task A3): sps is ORTHOGONAL to frame geometry, so the
% per-frame anchor blocks are unchanged and only cfg.Sps varies.
%
% Codegen note: getenv is guarded by coder.target so this function is safe to
% reference from MATLAB Function block code paths (e.g. the qpskByteSerializer
% default-argument branch). In codegen the defaults are used.

%#codegen

% --- env selection (interpreted MATLAB only; codegen uses the defaults) ---
frame = 'k5';
sps   = 8;
if isempty(coder.target)
    fenv = getenv('QPSK_FRAME');
    if ~isempty(fenv), frame = fenv; end
    senv = getenv('QPSK_SPS');
    if ~isempty(senv), sps = str2double(senv); end
end

% frame selection is validated by the switch below (k5 | f1536 | otherwise error).
% sps acceptance (Task A3): sps=4 is a valid rate rung for k5; f1536+sps4 is
% allowed structurally here (a combo gate validates the pairing downstream).
if sps ~= 8 && sps ~= 4
    error('frame_config_k5:unsupportedSps', ...
        'QPSK_SPS=%g is not supported (only sps=8 or sps=4)', sps);
end

cfg = struct();
switch frame
    case 'k5'
        % --- k5 geometry (historical literals -- MUST stay identical for G0) ---
        cfg.Frame            = 'k5';
        cfg.InfoBits         = 1084;   % info bits per frame (DataBits before coding)
        cfg.TailBits         = 4;      % K-1 zero tail (K=5 encoder terminate)
        cfg.CodedBits        = 2176;   % rate-1/2 coded bits = 2*(InfoBits+TailBits)
        cfg.InterleaveRows   = 136;    % block interleaver rows
        cfg.InterleaveCols   = 16;     % block interleaver cols
        cfg.FillerBits       = 64;     % PN9 filler bits appended after the coded bits
        cfg.PayloadBits      = 2240;   % DataBitsPerPacket = CodedBits + FillerBits
        cfg.WordsPerPacketRx = 16;     % byte-RX serializer WPP (first 1024 info bits)
        cfg.PayloadWords64   = 35;     % 64-bit words spanning the 2240-bit payload
        cfg.RomWords32       = 70;     % 32-bit words in the pre-coded ROM (2240 bits)
        cfg.Sps              = sps;    % samples per symbol (8 default; 4 = 2x-rate rung)
        cfg.CapGolden        = uint32(hex2dec('04922282')); % BIST cap_out golden

    case 'f1536'
        % --- f1536 large-frame geometry (1528-byte host frame -> MTU 1516) ---
        % Same K=5 [35 23] FEC + legacy interleave/ROM/CAP conventions as k5;
        % ONLY the frame geometry scales up (see contract/PACKET_F1536.txt).
        cfg.Frame            = 'f1536';
        cfg.InfoBits         = 12292;  % 192*64 + 4 (12288 usable + 4 always-zero tail-pad)
        cfg.TailBits         = 4;      % K-1 zero tail (K=5 encoder terminate)
        cfg.CodedBits        = 24592;  % = 2*(InfoBits+TailBits)
        cfg.InterleaveRows   = 1537;   % block interleaver rows (24592/16)
        cfg.InterleaveCols   = 16;     % COLS kept (legacy perms r*COLS+c / c*ROWS+r unchanged)
        cfg.FillerBits       = 48;     % PN9 filler bits appended after the coded bits
        cfg.PayloadBits      = 24640;  % = CodedBits + FillerBits = 385*64
        cfg.WordsPerPacketRx = 191;    % byte-RX serializer WPP (delivery-side; see constraint below)
        cfg.PayloadWords64   = 385;    % 64-bit words spanning the 24640-bit payload
        cfg.RomWords32       = 770;    % 32-bit words in the pre-coded ROM (24640 bits)
        cfg.Sps              = sps;    % samples per symbol (8 default; 4 = 2x-rate rung)
        % BIST cap_out golden = LSB-pack of the first 32 decoded info bits =
        % first 32 bits of 'ADI Hello World' -> SAME as k5 (message-start pack
        % is geometry-independent). Confirmed by packet_f1536.m's saved capOut.
        cfg.CapGolden        = uint32(hex2dec('04922282'));

    otherwise
        error('frame_config_k5:unknownFrame', 'unknown QPSK_FRAME=''%s''', frame);
end

% --- consistency validation (self-check; NOT an independent correctness proof) ---
% These four identities hold for EVERY valid frame geometry, so they are shared.
assert(cfg.CodedBits == 2*(cfg.InfoBits + cfg.TailBits), ...
    'frame_config_k5: CodedBits ~= 2*(InfoBits+TailBits)');
assert(cfg.CodedBits == cfg.InterleaveRows*cfg.InterleaveCols, ...
    'frame_config_k5: CodedBits ~= InterleaveRows*InterleaveCols');
assert(cfg.PayloadBits == cfg.CodedBits + cfg.FillerBits, ...
    'frame_config_k5: PayloadBits ~= CodedBits + FillerBits');
assert(cfg.PayloadBits == 64*cfg.PayloadWords64, ...
    'frame_config_k5: PayloadBits ~= 64*PayloadWords64');

% --- PER-FRAME GOLDEN ANCHORS (independent contract pins; NOT identities) ---
% The self-validation above only checks the geometry IDENTITIES, so it would
% still pass for any other internally-consistent frame. Each block below pins
% the EXACT shipped contract of one frame by literal, so every field --
% including WordsPerPacketRx, which otherwise has NO independent anchor in any
% executed gate -- is pinned independently here at the single source.
if strcmp(cfg.Frame, 'k5')
    assert(cfg.PayloadBits==2240 && cfg.CodedBits==2176 && cfg.InterleaveRows==136 ...
        && cfg.InterleaveCols==16 && cfg.InfoBits==1084 && cfg.TailBits==4 ...
        && cfg.FillerBits==64 && cfg.WordsPerPacketRx==16 && cfg.PayloadWords64==35 ...
        && cfg.RomWords32==70 && (cfg.Sps==8 || cfg.Sps==4) ...
        && cfg.CapGolden==uint32(hex2dec('04922282')), ...
        'frame_config_k5: k5 golden anchor mismatch (shipped contract drift)');
elseif strcmp(cfg.Frame, 'f1536')
    assert(cfg.PayloadBits==24640 && cfg.CodedBits==24592 && cfg.InterleaveRows==1537 ...
        && cfg.InterleaveCols==16 && cfg.InfoBits==12292 && cfg.TailBits==4 ...
        && cfg.FillerBits==48 && cfg.WordsPerPacketRx==191 && cfg.PayloadWords64==385 ...
        && cfg.RomWords32==770 && (cfg.Sps==8 || cfg.Sps==4) ...
        && cfg.CapGolden==uint32(hex2dec('04922282')), ...
        'frame_config_k5: f1536 golden anchor mismatch (shipped contract drift)');
    % f1536 byte-RX DELIVERY constraint (controller decision, option b):
    % WordsPerPacketRx is DELIVERY-side only (PayloadBits/CodedBits/interleaver/
    % goldens are unchanged). The serializer can only deliver as many words as
    % RxAlign emits before the frame boundary resets it, which is bounded by
    %   InfoBits - TailBits - RxPipelineSkipBits
    % where RxPipelineSkipBits=41 is the gated-Viterbi pipeline skip in
    % deintValid beats baked into RxAlign (fec_insert_overlay_rxonly_k5.m:
    % sk=sc+uint16(41), RXROOT E8). WPP*64 must fit under this (WPP=192 -> 12288
    % > 12247 would truncate the last word every frame; WPP=191 -> 12224 leaves
    % a 23-bit margin). The trailing 68 usable + 4 pad info bits are discarded
    % (0.55%/frame, mirroring k5's 60-bit discard). Host frame 1528 B -> MTU 1516
    % (> 1500 target). See task-A2-report.md "WPP=191 pass".
    RxPipelineSkipBits = 41;
    assert(cfg.WordsPerPacketRx*64 <= cfg.InfoBits - cfg.TailBits - RxPipelineSkipBits, ...
        'frame_config_k5: f1536 WPP*64 exceeds RxAlign per-frame deliverable (InfoBits-TailBits-%d)', RxPipelineSkipBits);
end
end
